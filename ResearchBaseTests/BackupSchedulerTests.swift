//
//  BackupSchedulerTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  BackupSchedulerTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 48 · Features: F-49, F-50
//  Every test uses a temporary library and folders. Free disk space and the
//  clock are faked, so no test fills a real disk or waits for 03:00.
//

import XCTest
@testable import ResearchBase

@MainActor
final class BackupSchedulerTests: XCTestCase {

    // MARK: Fakes and helpers

    private final class Clock: @unchecked Sendable {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private final class FreeSpace: @unchecked Sendable {
        var bytes: Int64?
        init(_ bytes: Int64?) { self.bytes = bytes }
    }

    private let gb: Int64 = 1_000_000_000
    private let mb: Int64 = 1_000_000

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Whole-second date in UTC.
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: 0))!
    }

    private struct Rig {
        let scheduler: BackupScheduler
        let library: Library
        let root: URL
        let clock: Clock
        let free: FreeSpace
    }

    private func makeRig(
        retention: BackupRetention = BackupRetention(),
        integrity: Bool = false,
        start: Date? = nil
    ) throws -> Rig {

        let root = try TestSupport.makeTempDirectory(self)
        let library = try Library.open(at: root.appendingPathComponent("lib", isDirectory: true))
        addTeardownBlock { library.close() }

        let clock = Clock(start ?? date(2026, 10, 22, 10, 0))
        let free = FreeSpace(50 * gb)
        let guardWithFakeSpace = DiskGuard(lowBytes: 2 * gb, criticalBytes: 500 * mb, capacity: { _ in free.bytes })

        let scheduler = BackupScheduler(
            library: library,
            diskGuard: guardWithFakeSpace,
            retention: retention,
            runIntegrityCheck: integrity,
            calendar: utc,
            now: { clock.date }
        )

        return Rig(scheduler: scheduler, library: library, root: root, clock: clock, free: free)
    }

    private func addItem(_ library: Library, id: String = "i1", key: String = "doe2026a", title: String = "A Study") throws {
        let stamp = "2026-01-01T00:00:00.000Z"
        _ = try library.database.run(
            "INSERT INTO items (id, item_type, title, citation_key, year, added_at, updated_at) VALUES (?, 'article', ?, ?, 2026, ?, ?)",
            [.text(id), .text(title), .text(key), .text(stamp), .text(stamp)]
        )
    }

    private func backupFolders(in url: URL) -> [String] {
        BackupScheduler.listBackups(in: url).map(\.name)
    }

    private func leftovers(in url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasPrefix(".rbtmp-") }
    }

    // MARK: Pure rules

    func testRetentionKeepsRecentDaysWeeksAndMonths() {
        let retention = BackupRetention()
        let newest = date(2026, 10, 22, 3, 0)

        let dates = (0..<400).map { newest.addingTimeInterval(-Double($0) * 86_400) }
        let kept = retention.keep(dates, calendar: utc)

        XCTAssertTrue(kept.contains(newest))
        for offset in 0..<7 {
            XCTAssertTrue(kept.contains(dates[offset]), "day \(offset) should be kept")
        }
        XCTAssertLessThanOrEqual(kept.count, 7 + 4 + 12)
        XCTAssertGreaterThanOrEqual(kept.count, 12)
        XCTAssertFalse(kept.contains(dates[399]), "a backup more than a year old is rotated away")
    }

    func testRetentionKeepsNewestOfEachDayWhenSeveralExist() {
        let morning = date(2026, 10, 22, 3, 0)
        let evening = date(2026, 10, 22, 21, 0)
        let kept = BackupRetention(daily: 1, weekly: 0, monthly: 0).keep([morning, evening], calendar: utc)
        XCTAssertEqual(kept, [evening])
    }

    func testDailyScheduleDueRules() {
        let now = date(2026, 10, 22, 10, 0)
        let schedule = BackupSchedule.daily

        XCTAssertTrue(schedule.isDue(lastSuccess: nil, lastAttempt: nil, now: now, calendar: utc))
        XCTAssertFalse(schedule.isDue(lastSuccess: date(2026, 10, 22, 3, 30), lastAttempt: nil, now: now, calendar: utc))
        XCTAssertTrue(schedule.isDue(lastSuccess: date(2026, 10, 21, 12, 0), lastAttempt: nil, now: now, calendar: utc))
        XCTAssertFalse(BackupSchedule.off.isDue(lastSuccess: nil, lastAttempt: nil, now: now, calendar: utc))
    }

    func testFailedAttemptWaitsBeforeRetrying() {
        let now = date(2026, 10, 22, 10, 0)
        let lastSuccess = date(2026, 10, 20, 3, 0)

        XCTAssertFalse(BackupSchedule.daily.isDue(
            lastSuccess: lastSuccess, lastAttempt: now.addingTimeInterval(-600), now: now, calendar: utc))
        XCTAssertTrue(BackupSchedule.daily.isDue(
            lastSuccess: lastSuccess, lastAttempt: now.addingTimeInterval(-7_200), now: now, calendar: utc))
    }

    func testSixHourScheduleDueRules() {
        let now = date(2026, 10, 22, 10, 0)
        XCTAssertFalse(BackupSchedule.everySixHours.isDue(
            lastSuccess: now.addingTimeInterval(-5 * 3600), lastAttempt: nil, now: now, calendar: utc))
        XCTAssertTrue(BackupSchedule.everySixHours.isDue(
            lastSuccess: now.addingTimeInterval(-6 * 3600), lastAttempt: nil, now: now, calendar: utc))
    }

    func testBackupFolderNamesRoundTripAndRejectStrangers() {
        let d = date(2026, 10, 22, 3, 0)
        let name = BackupNaming.folderName(for: d)
        XCTAssertEqual(BackupNaming.date(fromFolderName: name), d)
        XCTAssertNil(BackupNaming.date(fromFolderName: "My Notes"))
        XCTAssertNil(BackupNaming.date(fromFolderName: name + ".zip"))
        XCTAssertNil(BackupNaming.date(fromFolderName: "ResearchBase Backup latest"))
    }

    func testStatusBarText() {
        var status = BackupStatus()
        let now = date(2026, 10, 22, 10, 0)
        XCTAssertEqual(status.statusBarText(now: now, calendar: utc), "No backup yet")

        status.lastResult = .ok
        status.lastBackupAt = date(2026, 10, 22, 3, 0)
        XCTAssertTrue(status.statusBarText(now: now, calendar: utc).hasPrefix("Backed up today"))

        status.lastBackupAt = date(2026, 10, 21, 3, 0)
        XCTAssertTrue(status.statusBarText(now: now, calendar: utc).hasPrefix("Backed up yesterday"))

        status.lastResult = .skipped
        XCTAssertEqual(status.statusBarText(now: now, calendar: utc), "Backup skipped")
    }

    // MARK: F-49 backups

    func testBackupNowWritesAVerifiedCopyAndRecordsTheDate() async throws {
        let rig = try makeRig()
        try addItem(rig.library)

        let outcome = await rig.scheduler.backupNow()

        guard case .completed(let summary) = outcome else {
            return XCTFail("expected a completed backup, got \(outcome)")
        }

        XCTAssertEqual(summary.copies, 1)
        XCTAssertTrue(summary.warnings.isEmpty)

        let copy = summary.primaryURL.appendingPathComponent("library.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.primaryURL.appendingPathComponent("backup-info.json").path))

        let opened = try LibraryDatabase(path: copy.path, readOnly: true, create: false)
        defer { opened.close() }
        XCTAssertEqual(try opened.scalarInt("SELECT COUNT(*) FROM items"), 1)

        XCTAssertEqual(rig.scheduler.status.lastResult, .ok)
        let recorded = try XCTUnwrap(rig.scheduler.status.lastBackupAt)
        XCTAssertLessThan(abs(recorded.timeIntervalSince(rig.clock.date)), 1)

        XCTAssertTrue(leftovers(in: summary.primaryURL.deletingLastPathComponent()).isEmpty)
    }

    func testBackupCopiesPDFsAndDrafts() async throws {
        let rig = try makeRig()

        let pdf = rig.library.filesURL.appendingPathComponent("ab/abcd.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4 test".utf8).write(to: pdf)

        let draft = rig.library.draftsURL.appendingPathComponent("d1/main.tex")
        try FileManager.default.createDirectory(at: draft.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\\documentclass{article}".utf8).write(to: draft)

        guard case .completed(let summary) = await rig.scheduler.backupNow() else {
            return XCTFail("backup should complete")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.primaryURL.appendingPathComponent("files/ab/abcd.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.primaryURL.appendingPathComponent("drafts/d1/main.tex").path))
    }

    func testLowDiskSkipsAndKeepsTheLastGoodDate() async throws {
        let rig = try makeRig()

        rig.free.bytes = 100 * mb
        let outcome = await rig.scheduler.backupNow()

        guard case .skipped(let reason) = outcome else {
            return XCTFail("expected skipped, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("not enough disk space"))
        XCTAssertTrue(backupFolders(in: rig.library.backupsURL).isEmpty)
        XCTAssertEqual(rig.scheduler.status.lastResult, .skipped)
        XCTAssertNil(rig.scheduler.status.lastBackupAt)
        XCTAssertEqual(rig.scheduler.status.statusBarText(now: rig.clock.date, calendar: utc), "Backup skipped")

        // Space comes back: the next backup works and the date is recorded.
        rig.free.bytes = 50 * gb
        rig.clock.date = rig.clock.date.addingTimeInterval(7_200)
        guard case .completed = await rig.scheduler.backupNow() else {
            return XCTFail("backup should complete once there is room")
        }
        XCTAssertNotNil(rig.scheduler.status.lastBackupAt)
        XCTAssertEqual(rig.scheduler.status.lastResult, .ok)
    }

    func testSecondLocationGetsACopy() async throws {
        let rig = try makeRig()
        let second = rig.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        rig.scheduler.setSecondLocation(second)
        XCTAssertTrue(rig.scheduler.status.secondLocationConnected)

        guard case .completed(let summary) = await rig.scheduler.backupNow() else {
            return XCTFail("backup should complete")
        }

        XCTAssertEqual(summary.copies, 2)
        let secondFolder = second.appendingPathComponent(BackupScheduler.secondLocationSubfolder, isDirectory: true)
        XCTAssertEqual(backupFolders(in: secondFolder), [summary.folderName])
        XCTAssertEqual(rig.scheduler.secondLocationBackups().count, 1)
        XCTAssertEqual(rig.scheduler.status.copies, 2)
    }

    func testMissingSecondLocationIsAWarningAndIsNeverCreated() async throws {
        let rig = try makeRig()
        let gone = rig.root.appendingPathComponent("Volumes-Backup", isDirectory: true)

        rig.scheduler.setSecondLocation(gone)
        XCTAssertFalse(rig.scheduler.status.secondLocationConnected)

        guard case .completed(let summary) = await rig.scheduler.backupNow() else {
            return XCTFail("the first copy must still be made")
        }

        XCTAssertEqual(summary.copies, 1)
        XCTAssertFalse(summary.warnings.isEmpty)
        XCTAssertEqual(rig.scheduler.status.lastResult, .warnings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "an unplugged drive's folder must not be recreated")
    }

    func testRemovingTheSecondLocation() async throws {
        let rig = try makeRig()
        let second = rig.root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        rig.scheduler.setSecondLocation(second)
        rig.scheduler.setSecondLocation(nil)

        XCTAssertNil(rig.scheduler.status.secondLocationPath)
        guard case .completed(let summary) = await rig.scheduler.backupNow() else {
            return XCTFail("backup should complete")
        }
        XCTAssertEqual(summary.copies, 1)
        XCTAssertTrue(summary.warnings.isEmpty)
    }

    func testRotationRemovesOldBackupsButNeverStrangers() async throws {
        let rig = try makeRig(retention: BackupRetention(daily: 2, weekly: 0, monthly: 0))
        let directory = rig.library.backupsURL
        let fm = FileManager.default

        for daysAgo in 1...4 {
            let old = rig.clock.date.addingTimeInterval(-Double(daysAgo) * 86_400)
            try fm.createDirectory(
                at: directory.appendingPathComponent(BackupNaming.folderName(for: old), isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let stranger = directory.appendingPathComponent("My Notes", isDirectory: true)
        try fm.createDirectory(at: stranger, withIntermediateDirectories: true)

        guard case .completed(let summary) = await rig.scheduler.backupNow() else {
            return XCTFail("backup should complete")
        }

        XCTAssertEqual(summary.prunedCount, 3)
        XCTAssertEqual(backupFolders(in: directory).count, 2)
        XCTAssertTrue(backupFolders(in: directory).contains(summary.folderName))
        XCTAssertTrue(fm.fileExists(atPath: stranger.path))
    }

    func testRunIfDueOnlyRunsWhenDue() async throws {
        let rig = try makeRig()

        let first = await rig.scheduler.runIfDue()
        XCTAssertNotNil(first, "no backup yet, so one is due")

        rig.clock.date = rig.clock.date.addingTimeInterval(600)
        let second = await rig.scheduler.runIfDue()
        XCTAssertNil(second, "a backup was just made")

        rig.scheduler.schedule = .off
        rig.clock.date = rig.clock.date.addingTimeInterval(3 * 86_400)
        let third = await rig.scheduler.runIfDue()
        XCTAssertNil(third, "off means off")
    }

    func testSettingsSurviveReopeningTheScheduler() async throws {
        let rig = try makeRig()
        rig.scheduler.schedule = .everySixHours
        rig.scheduler.notifyOnFailure = false
        _ = await rig.scheduler.backupNow()

        let again = BackupScheduler(library: rig.library, calendar: utc, now: { rig.clock.date })
        XCTAssertEqual(again.schedule, .everySixHours)
        XCTAssertFalse(again.notifyOnFailure)
        XCTAssertNotNil(again.status.lastBackupAt)
        XCTAssertEqual(again.status.lastResult, .ok)
    }

    func testLegacyPackageFailureIsAWarningNotALostBackup() async throws {
        let root = try TestSupport.makeTempDirectory(self)
        let library = try Library.open(at: root.appendingPathComponent("lib", isDirectory: true))
        addTeardownBlock { library.close() }

        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

        let scheduler = BackupScheduler(
            library: library,
            diskGuard: DiskGuard(capacity: { _ in 50_000_000_000 }),
            legacyPackageWriter: { _ in throw Boom() },
            runIntegrityCheck: false,
            calendar: utc
        )

        guard case .completed(let summary) = await scheduler.backupNow() else {
            return XCTFail("the database copy must still be kept")
        }
        XCTAssertTrue(summary.warnings.contains { $0.contains("earlier workspace") })
        XCTAssertEqual(scheduler.status.lastResult, .warnings)
    }

    // MARK: F-50 export everything

    func testExportEverythingWritesOpenFormats() async throws {
        let rig = try makeRig()
        let stamp = "2026-01-01T00:00:00.000Z"
        let db = rig.library.database

        try addItem(rig.library)
        _ = try db.run("INSERT INTO creators (id, family, given, norm) VALUES ('c1', 'Doe', 'Jane', 'doe jane')")
        _ = try db.run("INSERT INTO item_creators (item_id, creator_id, role, position) VALUES ('i1', 'c1', 'author', 0)")
        _ = try db.run(
            "INSERT INTO thoughts (id, kind, title, body, created_at, updated_at) VALUES ('t1', 'note', 'Idea: scaling', 'Body of the note', ?, ?)",
            [.text(stamp), .text(stamp)]
        )
        _ = try db.run(
            "INSERT INTO thoughts (id, kind, title, body, created_at, updated_at, deleted_at) VALUES ('t2', 'note', 'Gone', 'x', ?, ?, ?)",
            [.text(stamp), .text(stamp), .text(stamp)]
        )

        let pdf = rig.library.filesURL.appendingPathComponent("ab/abcd.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4 test".utf8).write(to: pdf)
        _ = try db.run(
            "INSERT INTO attachments (id, item_id, kind, is_primary, sha256, rel_path, bytes, added_at) VALUES ('a1', 'i1', 'pdf', 1, 'abcd', 'files/ab/abcd.pdf', 13, ?)",
            [.text(stamp)]
        )

        let parent = rig.root.appendingPathComponent("Documents", isDirectory: true)
        let result = try await rig.scheduler.exportEverything(to: parent)
        let fm = FileManager.default

        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.noteCount, 1)
        XCTAssertEqual(result.pdfCount, 1)
        XCTAssertTrue(result.folder.lastPathComponent.hasPrefix("ResearchBase Export 2026-10-2"))
        XCTAssertTrue(fm.fileExists(atPath: result.folder.appendingPathComponent("README.txt").path))

        // library.json
        let jsonData = try Data(contentsOf: result.folder.appendingPathComponent("library.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let tables = try XCTUnwrap(root["tables"] as? [String: Any])
        XCTAssertEqual((tables["items"] as? [Any])?.count, 1)
        XCTAssertNil(tables["fts_items"], "search indexes are not exported")

        // references.bib
        let bib = try String(contentsOf: result.folder.appendingPathComponent("references.bib"), encoding: .utf8)
        XCTAssertTrue(bib.contains("@article{doe2026a,"))
        XCTAssertTrue(bib.contains("author = {Doe, Jane}"))
        XCTAssertTrue(bib.contains("year = {2026}"))

        // notes (deleted ones are left out)
        let noteFolder = result.folder.appendingPathComponent("notes/note")
        let noteFiles = try fm.contentsOfDirectory(atPath: noteFolder.path)
        XCTAssertEqual(noteFiles.count, 1)
        let note = try String(contentsOf: noteFolder.appendingPathComponent(noteFiles[0]), encoding: .utf8)
        XCTAssertTrue(note.contains("Body of the note"))
        XCTAssertTrue(note.hasPrefix("---\n"))

        // PDFs get readable names
        XCTAssertTrue(fm.fileExists(atPath: result.folder.appendingPathComponent("pdfs/doe2026a.pdf").path))

        // The reminder moves forward.
        XCTAssertNotNil(rig.scheduler.exportReminder.lastExportAt)
        XCTAssertFalse(rig.scheduler.isExportDue)
        XCTAssertTrue(leftovers(in: parent).isEmpty)
    }

    func testSecondExportOnTheSameDayGetsItsOwnFolder() async throws {
        let rig = try makeRig()
        let parent = rig.root.appendingPathComponent("Documents", isDirectory: true)

        let first = try await rig.scheduler.exportEverything(to: parent)
        let second = try await rig.scheduler.exportEverything(to: parent)

        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.folder.path))
    }

    func testExportReminderBecomesDueAfterAMonth() async throws {
        let rig = try makeRig()
        _ = try await rig.scheduler.exportEverything(to: rig.root.appendingPathComponent("Documents", isDirectory: true))

        XCTAssertFalse(rig.scheduler.isExportDue)

        rig.clock.date = rig.clock.date.addingTimeInterval(32 * 86_400)
        XCTAssertTrue(rig.scheduler.isExportDue)

        rig.scheduler.setExportReminder(enabled: false)
        XCTAssertFalse(rig.scheduler.isExportDue)
    }

    func testExportStopsCleanlyWhenThereIsNoRoom() async throws {
        let rig = try makeRig()
        rig.free.bytes = 100 * mb
        let parent = rig.root.appendingPathComponent("Documents", isDirectory: true)

        do {
            _ = try await rig.scheduler.exportEverything(to: parent)
            XCTFail("expected a disk space error")
        } catch let error as DiskGuardError {
            XCTAssertTrue(error.errorDescription?.contains("not enough disk space") == true)
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertTrue(entries.isEmpty, "nothing half-written is left behind")
    }
}