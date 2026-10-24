//
//  RestoreDrillTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 49 · Features: F-51
//  Real backups are made with BackupScheduler in a temporary library, then practised.
//  Free space and the clock are faked. Nothing touches the real library or disk.
//
import XCTest
import SwiftData
import CryptoKit
import CoreGraphics
@testable import ResearchBase
@MainActor
final class RestoreDrillTests: XCTestCase {

    // MARK: Fakes and helpers

    private final class FreeSpace: @unchecked Sendable {
        var bytes: Int64?
        init(_ bytes: Int64?) { self.bytes = bytes }
    }

    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private let gb: Int64 = 1_000_000_000
    private let mb: Int64 = 1_000_000

    private struct Rig {
        let library: Library
        let scheduler: BackupScheduler
        let drill: RestoreDrill
        let root: URL
        let scratch: URL
        let drillSpace: FreeSpace
        let clock: Clock
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeRig(context: ModelContext? = nil) throws -> Rig {

        let root = try TestSupport.makeTempDirectory(self)
        let library = try Library.open(at: root.appendingPathComponent("lib", isDirectory: true))
        addTeardownBlock { library.close() }

        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let clock = Clock(utc.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10))!)
        let backupSpace = FreeSpace(50 * gb)
        let drillSpace = FreeSpace(50 * gb)

        let scheduler = BackupScheduler(
            library: library,
            diskGuard: DiskGuard(capacity: { _ in backupSpace.bytes }),
            runIntegrityCheck: false,
            calendar: utc,
            now: { clock.date }
        )

        let drill = RestoreDrill(
            library: library,
            context: context,
            diskGuard: DiskGuard(lowBytes: 2 * gb, criticalBytes: 500 * mb, capacity: { _ in drillSpace.bytes }),
            scratchParent: scratch,
            integrityDepth: .quick,
            pdfSampler: { $0 },
            now: { clock.date }
        )

        return Rig(library: library, scheduler: scheduler, drill: drill, root: root, scratch: scratch, drillSpace: drillSpace, clock: clock)
    }

    private func addItem(_ library: Library, id: String = "i1", key: String = "doe2026a") throws {
        let stamp = "2026-01-01T00:00:00.000Z"
        _ = try library.database.run(
            "INSERT INTO items (id, item_type, title, citation_key, year, added_at, updated_at) VALUES (?, 'article', 'A Study', ?, 2026, ?, ?)",
            [.text(id), .text(key), .text(stamp), .text(stamp)]
        )
    }

    /// A real one-page PDF, so PDFKit can open it.
    private func makePDFData() -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Writes the PDF into the library the way the app stores it and records it. Returns its relative path.
    @discardableResult
    private func addPDF(_ library: Library, itemID: String = "i1") throws -> String {
        let data = makePDFData()
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let relative = "files/\(sha.prefix(2))/\(sha).pdf"
        let url = library.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        _ = try library.database.run(
            "INSERT INTO attachments (id, item_id, kind, is_primary, sha256, rel_path, original_name, bytes, added_at) VALUES ('a1', ?, 'pdf', 1, ?, ?, 'paper.pdf', ?, '2026-01-01T00:00:00.000Z')",
            [.text(itemID), .text(sha), .text(relative), .int(Int64(data.count))]
        )
        return relative
    }

    private func makeBackup(_ rig: Rig) async throws -> URL {
        guard case .completed(let summary) = await rig.scheduler.backupNow() else {
            XCTFail("the test backup must complete")
            throw CancellationError()
        }
        return summary.primaryURL
    }

    private func scratchIsEmpty(_ rig: Rig) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: rig.scratch.path)) ?? []).isEmpty
    }

    private func state(_ result: DrillResult, _ id: DrillStepID) -> DrillStepState? {
        result.steps.first(where: { $0.id == id })?.state
    }

    private func itemCount(_ library: Library) throws -> Int64 {
        try library.database.scalarInt("SELECT COUNT(*) FROM items") ?? -1
    }

    // MARK: Good backups

    func testGoodBackupPassesEveryStepAndCleansUp() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        try addPDF(rig.library)
        let backup = try await makeBackup(rig)

        let result = await rig.drill.run(backupAt: backup)

        XCTAssertTrue(result.verdict.isPass, "\(result.verdict) \(result.steps)")
        XCTAssertEqual(state(result, .unpack), .passed)
        XCTAssertEqual(state(result, .openDatabase), .passed)
        XCTAssertEqual(state(result, .counts), .passed)
        XCTAssertEqual(state(result, .pdfs), .passed)
        XCTAssertTrue(result.steps.first(where: { $0.id == .counts })?.title.contains("1 papers") == true)
        XCTAssertTrue(scratchIsEmpty(rig), "the scratch folder is always removed")
        XCTAssertFalse(rig.drill.isRunning)
        XCTAssertEqual(rig.drill.result, result)
    }

    func testEmptyLibraryBackupPassesAndSkipsPDFs() async throws {
        let rig = try makeRig()
        let backup = try await makeBackup(rig)

        let result = await rig.drill.run(backupAt: backup)

        XCTAssertTrue(result.verdict.isPass, "\(result.verdict)")
        if case .skipped = state(result, .pdfs) { } else { XCTFail("no PDFs means the PDF step is skipped") }
    }

    func testLiveLibraryIsOnlyReadAndStaysTheSame() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let backup = try await makeBackup(rig)

        let before = try itemCount(rig.library)
        _ = await rig.drill.run(backupAt: backup)

        XCTAssertEqual(try itemCount(rig.library), before)
        let recorded = try rig.library.database.scalarText("SELECT value FROM meta WHERE key = 'last_restore_drill_result'")
        XCTAssertTrue(["passed", "notes"].contains(recorded ?? ""), "recorded: \(recorded ?? "nothing")")
    }

    func testLibraryThatGrewSinceTheBackupIsANoteNotAFailure() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let backup = try await makeBackup(rig)

        try addItem(rig.library, id: "i2", key: "roe2026b")
        let result = await rig.drill.run(backupAt: backup)

        XCTAssertTrue(result.verdict.isPass, "\(result.verdict)")
        if case .passedWithNote(let text) = state(result, .counts) {
            XCTAssertTrue(text.contains("changed since this backup"))
        } else {
            XCTFail("expected a note on the counts step")
        }
    }

    // MARK: Bad backups

    func testDamagedDatabaseFailsAtOpenAndIsReported() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let backup = try await makeBackup(rig)

        try Data("this is not a database".utf8).write(to: backup.appendingPathComponent("library.sqlite"))

        let result = await rig.drill.run(backupAt: backup)

        guard case .failed = result.verdict else { return XCTFail("expected a failure, got \(result.verdict)") }
        if case .failed = state(result, .openDatabase) { } else { XCTFail("the open step should fail") }
        if case .skipped = state(result, .integrity) { } else { XCTFail("later steps are marked as not reached") }
        XCTAssertTrue(scratchIsEmpty(rig))
        XCTAssertEqual(RestoreDrill.lastDrill(in: rig.library)?.result, "failed")
        XCTAssertEqual(try itemCount(rig.library), 1, "the live library is untouched")
    }

    func testChangedPDFContentFails() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let relative = try addPDF(rig.library)
        let backup = try await makeBackup(rig)

        // Same length, different content: the size check passes, the fingerprint must not.
        let file = backup.appendingPathComponent(relative)
        let length = try Data(contentsOf: file).count
        try Data(count: length).write(to: file)

        let result = await rig.drill.run(backupAt: backup)

        guard case .failed = result.verdict else { return XCTFail("expected a failure, got \(result.verdict)") }
        XCTAssertTrue(scratchIsEmpty(rig))
    }

    func testMissingPDFFails() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let relative = try addPDF(rig.library)
        let backup = try await makeBackup(rig)

        try FileManager.default.removeItem(at: backup.appendingPathComponent(relative))

        let result = await rig.drill.run(backupAt: backup)
        guard case .failed = result.verdict else { return XCTFail("expected a failure, got \(result.verdict)") }
    }

    func testFolderThatIsNotABackupFails() async throws {
        let rig = try makeRig()
        let stranger = rig.root.appendingPathComponent("Holiday Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)

        let result = await rig.drill.run(backupAt: stranger)

        guard case .failed(let reason) = result.verdict else { return XCTFail("expected a failure") }
        XCTAssertTrue(reason.contains("not a ResearchBase backup"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path), "the folder is only read")
    }

    func testMissingBackupFolderFails() async throws {
        let rig = try makeRig()
        let result = await rig.drill.run(backupAt: rig.root.appendingPathComponent("gone", isDirectory: true))
        guard case .failed = result.verdict else { return XCTFail("expected a failure") }
    }

    // MARK: Low disk

    func testLowDiskSkipsWithoutCopyingAndIsNotRecorded() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let backup = try await makeBackup(rig)

        rig.drillSpace.bytes = 100 * mb
        let result = await rig.drill.run(backupAt: backup)

        guard case .skipped(let reason) = result.verdict else { return XCTFail("expected skipped, got \(result.verdict)") }
        XCTAssertTrue(reason.contains("not enough disk space"))
        XCTAssertTrue(scratchIsEmpty(rig))
        XCTAssertNil(RestoreDrill.lastDrill(in: rig.library), "a drill that did not run is not recorded")

        // Room again: it runs and passes.
        rig.drillSpace.bytes = 50 * gb
        let second = await rig.drill.run(backupAt: backup)
        XCTAssertTrue(second.verdict.isPass)
    }

    // MARK: Recording and listing

    func testLastDrillIsRecordedAndOverdueFollowsIt() async throws {
        let rig = try makeRig()
        try addItem(rig.library)
        let backup = try await makeBackup(rig)

        XCTAssertNil(RestoreDrill.lastDrill(in: rig.library))
        XCTAssertTrue(RestoreDrill.isOverdue(in: rig.library, now: rig.clock.date))

        _ = await rig.drill.run(backupAt: backup)

        let record = try XCTUnwrap(RestoreDrill.lastDrill(in: rig.library))
        XCTAssertTrue(record.succeeded)
        XCTAssertEqual(record.backupName, backup.lastPathComponent)
        XCTAssertLessThan(abs(try XCTUnwrap(record.at).timeIntervalSince(rig.clock.date)), 1)

        XCTAssertFalse(RestoreDrill.isOverdue(in: rig.library, now: rig.clock.date.addingTimeInterval(10 * 86_400)))
        XCTAssertTrue(RestoreDrill.isOverdue(in: rig.library, now: rig.clock.date.addingTimeInterval(31 * 86_400)))
    }

    func testAvailableBackupsListsNewestFirst() async throws {
        let rig = try makeRig()
        let first = try await makeBackup(rig)
        rig.clock.date = rig.clock.date.addingTimeInterval(86_400)
        let second = try await makeBackup(rig)

        let names = rig.drill.availableBackups().map(\.name)
        XCTAssertEqual(names, [second.lastPathComponent, first.lastPathComponent])
    }

    func testStepsStartPendingAndEndWithNoPendingLeft() async throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.drill.steps.count, DrillStepID.allCases.count)
        XCTAssertTrue(rig.drill.steps.allSatisfy { $0.state == .pending })

        let backup = try await makeBackup(rig)
        let result = await rig.drill.run(backupAt: backup)

        XCTAssertFalse(result.steps.contains { $0.state == .pending || $0.state == .running })
    }

    // MARK: Earlier workspace packages

    func testBareWorkspacePackageNeedsAContextOtherwiseItIsSkipped() async throws {
        let context = try TestSupport.makeContext()
        let rig = try makeRig()

        let package = rig.root.appendingPathComponent("Old.researchbase", isDirectory: true)
        _ = try await WorkspaceBackupService.createBackup(context: context, to: package)

        let result = await rig.drill.run(backupAt: package)

        guard case .skipped = result.verdict else { return XCTFail("expected skipped without a workspace, got \(result.verdict)") }
        XCTAssertNil(RestoreDrill.lastDrill(in: rig.library))
    }

    func testBareWorkspacePackagePassesWithAContext() async throws {
        let context = try TestSupport.makeContext()
        let rig = try makeRig(context: context)

        let package = rig.root.appendingPathComponent("Old.researchbase", isDirectory: true)
        _ = try await WorkspaceBackupService.createBackup(context: context, to: package)

        let result = await rig.drill.run(backupAt: package)

        XCTAssertTrue(result.verdict.isPass, "\(result.verdict) \(result.steps)")
        if case .skipped = state(result, .openDatabase) { } else { XCTFail("database steps do not apply to a bare package") }
        XCTAssertTrue(scratchIsEmpty(rig))
    }
}
