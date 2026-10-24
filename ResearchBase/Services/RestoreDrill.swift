//
//  RestoreDrill.swift
//  ResearchBase
//
//  Owner: Agent 49 · Features: F-51 (restore drill / "Practice restore")
//
//  Restores a backup into a scratch folder and checks it, so you know your backups
//  work BEFORE you need one. The live library is never touched.
//
//  WHAT A DRILL DOES (the steps the sheet shows, in order)
//    1. Unpack      copies the backup into a scratch folder (checks free space first)
//    2. Open        opens the restored library.sqlite the way the app would
//    3. Integrity   runs IntegrityChecker on the restored copy (deep by default)
//    4. Counts      the restored copy must match the backup's own record of itself
//                   (backup-info.json). It is also compared with your live library;
//                   a library that has grown since the backup is normal, so that is
//                   reported as a note, not as a failure.
//    5. PDFs        opens up to 10 random PDFs: file present, SHA-256 matches the
//                   database, PDFKit can open it and finds pages
//    6. Earlier workspace   the legacy.researchbase package inside the backup (old
//                   SwiftData content) is read and checksum-verified through
//                   WorkspaceRestoreService.preview. Needs a ModelContext.
//    The scratch folder is always removed afterwards, also after a failure.
//
//  A drill can also be run on a bare .researchbase package (for example one the
//  restore screen made as a safety backup). Then only step 6 applies.
//
//  SAFETY RULES
//    - The live library is only READ. The only writes to it are three small
//      bookkeeping rows in `meta` (last_restore_drill_at, last_restore_drill_result,
//      last_restore_drill_backup). No schema change.
//    - The backup being practised is only read. Everything is done on a copy.
//    - Not enough free space for the scratch copy -> the drill is SKIPPED and says so.
//      A skipped drill is not recorded as a pass or a failure.
//    - A failed drill is shown as a banner and logged: a backup that cannot be
//      restored is exactly what the person needs to hear about.
//    - It never calls WorkspaceRestoreService.restore. Only `preview`, which is read-only.
//
//  PUBLIC API
//  ----------
//  DrillStepID / DrillStepState / DrillStep      what the sheet shows, one row per step
//  DrillVerdict                                  .passed .passedWithNotes([..]) .failed(..) .skipped(..)
//                                                  isPass, headline
//  DrillResult                                   backupName, backupDate, startedAt, finishedAt, steps, verdict
//  DrillRecord                                   what Settings shows: at, result, backupName
//  RestoreDrill                                  @MainActor @Observable
//    init(library:context:diskGuard:scratchParent:integrityDepth:pdfSampleSize:pdfSampler:now:)
//    .steps, .isRunning, .result
//    .run(backupAt:) async -> DrillResult        backup folder (BackupScheduler) or .researchbase package
//    .availableBackups(in:) -> [BackupRecord]    newest first; default folder: the library's backups folder
//    RestoreDrill.lastDrill(in:) -> DrillRecord? when it last ran and how it went
//    RestoreDrill.isOverdue(in:now:everyDays:)   true when no drill ran in the last 30 days
//
//  Wiring note (not my files): SettingsView lists `availableBackups()` with a "Practice restore"
//  button per row, shows `steps` and `result?.verdict.headline` in the sheet, and shows
//  `lastDrill(in:)` ("Practised today at 14:…"). ManagementSheets (#62) hosts the sheet.
//
//  Uses only finished code: Library, LibraryDatabase, DiskGuard, IntegrityChecker, AppLogger,
//  WorkspaceRestoreService (preview only), BackupScheduler (listing and the backup layout it writes).
//

import Foundation
import Observation
import CryptoKit
import PDFKit
import SwiftData

// MARK: - Steps

nonisolated enum DrillStepID: String, CaseIterable, Identifiable, Sendable {
    case unpack
    case openDatabase
    case integrity
    case counts
    case pdfs
    case earlierWorkspace

    var id: String { rawValue }

    /// Title while the step has not finished.
    var pendingTitle: String {
        switch self {
        case .unpack: return "Unpack the backup"
        case .openDatabase: return "Open the restored database"
        case .integrity: return "Integrity check"
        case .counts: return "Counts match your library"
        case .pdfs: return "Open random PDFs"
        case .earlierWorkspace: return "Read the earlier workspace data"
        }
    }
}

enum DrillStepState: Equatable {
    case pending
    case running
    case passed
    /// Passed, with something worth knowing.
    case passedWithNote(String)
    case failed(String)
    case skipped(String)
}

struct DrillStep: Identifiable, Equatable {
    let id: DrillStepID
    var title: String
    var state: DrillStepState
}

// MARK: - Result

enum DrillVerdict: Equatable {
    case passed
    case passedWithNotes([String])
    case failed(String)
    case skipped(String)

    var isPass: Bool {
        switch self {
        case .passed, .passedWithNotes: return true
        case .failed, .skipped: return false
        }
    }

    var headline: String {
        switch self {
        case .passed:
            return "This backup can be restored."
        case .passedWithNotes:
            return "This backup can be restored, with notes."
        case .failed(let reason):
            return "This backup could not be restored. \(reason)"
        case .skipped(let reason):
            return "The practice restore did not run. \(reason)"
        }
    }
}

struct DrillResult: Equatable {
    let backupName: String
    let backupDate: Date?
    let startedAt: Date
    let finishedAt: Date
    let steps: [DrillStep]
    let verdict: DrillVerdict
}

struct DrillRecord: Equatable {
    let at: Date?
    /// "passed", "notes" or "failed".
    let result: String
    let backupName: String

    var succeeded: Bool { result == "passed" || result == "notes" }
}

nonisolated enum RestoreDrillError: LocalizedError {
    case drillFailed(String)

    var errorDescription: String? {
        switch self {
        case .drillFailed(let detail):
            return "The practice restore failed. \(detail)"
        }
    }
}

// MARK: - Drill

@MainActor
@Observable
final class RestoreDrill {

    private(set) var steps: [DrillStep] = RestoreDrill.freshSteps()
    private(set) var isRunning = false
    private(set) var result: DrillResult?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let context: ModelContext?
    @ObservationIgnored private let diskGuard: DiskGuard
    @ObservationIgnored private let scratchParent: URL
    @ObservationIgnored private let integrityDepth: IntegrityDepth
    @ObservationIgnored private let pdfSampleSize: Int
    @ObservationIgnored private let pdfSampler: (@MainActor ([String]) -> [String])?
    @ObservationIgnored private let now: @MainActor () -> Date

    private enum Keys {
        static let at = "last_restore_drill_at"
        static let result = "last_restore_drill_result"
        static let backup = "last_restore_drill_backup"
    }

    private static let category = "restore-drill"

    private enum Kind {
        case sqliteBackup
        case legacyPackage
        case unknown
    }

    init(
        library: Library,
        context: ModelContext? = nil,
        diskGuard: DiskGuard = DiskGuard(),
        scratchParent: URL? = nil,
        integrityDepth: IntegrityDepth = .deep,
        pdfSampleSize: Int = 10,
        pdfSampler: (@MainActor ([String]) -> [String])? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.library = library
        self.context = context
        self.diskGuard = diskGuard
        self.scratchParent = scratchParent ?? FileManager.default.temporaryDirectory
        self.integrityDepth = integrityDepth
        self.pdfSampleSize = max(pdfSampleSize, 1)
        self.pdfSampler = pdfSampler
        self.now = now
    }

    private static func freshSteps() -> [DrillStep] {
        DrillStepID.allCases.map { DrillStep(id: $0, title: $0.pendingTitle, state: .pending) }
    }

    // MARK: Listing

    func availableBackups(in directory: URL? = nil) -> [BackupRecord] {
        BackupScheduler.listBackups(in: directory ?? library.backupsURL)
    }

    // MARK: Run

    /// Practises restoring `backup` (a backup folder made by BackupScheduler, or a .researchbase package).
    @discardableResult
    func run(backupAt backup: URL) async -> DrillResult {

        let started = now()
        let name = backup.lastPathComponent
        let backupDate = BackupNaming.date(fromFolderName: name)

        guard !isRunning else {
            return DrillResult(
                backupName: name, backupDate: backupDate, startedAt: started, finishedAt: started,
                steps: steps, verdict: .skipped("A practice restore is already running.")
            )
        }

        isRunning = true
        defer { isRunning = false }

        steps = Self.freshSteps()
        result = nil

        let scratch = scratchParent.appendingPathComponent("RBDrill-\(UUID().uuidString)", isDirectory: true)
        var verdict: DrillVerdict

        do {
            verdict = try await perform(backup: backup, scratch: scratch)
        } catch is CancellationError {
            verdict = .skipped("The practice restore was stopped before it finished.")
        } catch {
            verdict = .failed(AppErrorText.plain(error))
        }

        // The scratch folder never outlives the drill.
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: scratch)
        }.value

        // Steps that were never reached say so, instead of staying "pending" forever.
        for index in steps.indices {
            switch steps[index].state {
            case .pending, .running:
                let reason: String
                if case .skipped = verdict { reason = "Not run." } else { reason = "Not reached because an earlier step failed." }
                steps[index].state = .skipped(reason)
            default:
                break
            }
        }

        let finished = now()
        let outcome = DrillResult(
            backupName: name, backupDate: backupDate, startedAt: started, finishedAt: finished,
            steps: steps, verdict: verdict
        )
        result = outcome

        record(outcome)
        return outcome
    }

    // MARK: Steps

    private func perform(backup: URL, scratch: URL) async throws -> DrillVerdict {

        let fm = FileManager.default
        var notes: [String] = []

        // 0. What is it?
        let kind = Self.kind(of: backup)
        guard kind != .unknown else {
            let message = "This is not a ResearchBase backup (there is no library.sqlite in it)."
            set(.unpack, .failed(message))
            return .failed(message)
        }

        // 1. Unpack into scratch (room first).
        set(.unpack, .running)

        let size = await Task.detached(priority: .utility) { Self.folderSize(backup) }.value

        do {
            try diskGuard.ensureRoom(for: size, at: scratchParent)
        } catch let error as DiskGuardError {
            let message = error.errorDescription ?? "There is not enough disk space for a practice restore."
            set(.unpack, .skipped(message))
            return .skipped(message)
        }

        let restoredRoot = scratch.appendingPathComponent(
            kind == .legacyPackage ? "restored.\(WorkspaceFormat.packageExtension)" : "restored",
            isDirectory: true
        )

        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: backup, to: restoredRoot)
            }.value
        } catch {
            return fail(.unpack, "The backup could not be copied: \(AppErrorText.plain(error))")
        }

        set(.unpack, .passed, title: "Unpacked backup (\(DiskGuard.formatBytes(size)))")

        try Task.checkCancellation()

        // Legacy-only package: only the last step applies.
        if kind == .legacyPackage {
            for id in [DrillStepID.openDatabase, .integrity, .counts, .pdfs] {
                set(id, .skipped("Not part of this kind of backup."))
            }
            guard context != nil else {
                let message = "Reading an earlier workspace package needs the app's workspace, which was not available."
                set(.earlierWorkspace, .skipped(message))
                return .skipped(message)
            }
            if let failure = await checkEarlierWorkspace(at: restoredRoot, notes: &notes) { return failure }
            return notes.isEmpty ? .passed : .passedWithNotes(notes)
        }

        // 2. Open the restored database.
        set(.openDatabase, .running)

        let expectedItems = Self.expectedItemCount(inBackupAt: restoredRoot)

        let restored: Library
        do {
            restored = try Library.open(at: restoredRoot, createIfMissing: false)
        } catch {
            return fail(.openDatabase, "The restored database could not be opened: \(AppErrorText.plain(error))")
        }
        defer { restored.close() }

        set(.openDatabase, .passed)
        try Task.checkCancellation()

        // 3. Integrity check on the restored copy.
        set(.integrity, .running)

        let report: IntegrityReport
        do {
            report = try await IntegrityChecker.run(on: restored, depth: integrityDepth, recordResult: false, now: now())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fail(.integrity, "The integrity check could not run: \(AppErrorText.plain(error))")
        }

        if !report.isHealthy {
            let first = report.issues.first(where: { $0.severity == .error })?.title ?? "see the library check for details"
            return fail(.integrity, "\(report.errorCount) \(report.errorCount == 1 ? "problem" : "problems") found in the restored copy, for example: \(first).")
        }
        if report.warningCount > 0 {
            let note = "\(report.warningCount) \(report.warningCount == 1 ? "warning" : "warnings") in the integrity check of the restored copy."
            set(.integrity, .passedWithNote(note))
            notes.append(note)
        } else {
            set(.integrity, .passed)
        }

        try Task.checkCancellation()

        // 4. Counts.
        set(.counts, .running)

        let restoredItems: Int64
        let restoredLinks: Int64
        let liveItems: Int64
        let liveLinks: Int64
        do {
            restoredItems = try restored.database.scalarInt("SELECT COUNT(*) FROM items") ?? 0
            restoredLinks = try restored.database.scalarInt("SELECT COUNT(*) FROM links") ?? 0
            liveItems = try library.database.scalarInt("SELECT COUNT(*) FROM items") ?? 0
            liveLinks = try library.database.scalarInt("SELECT COUNT(*) FROM links") ?? 0
        } catch {
            return fail(.counts, "The records could not be counted: \(AppErrorText.plain(error))")
        }

        if let expectedItems, expectedItems != restoredItems {
            return fail(.counts, "The backup says it holds \(expectedItems) papers, but the restored copy has \(restoredItems).")
        }

        if restoredItems == liveItems && restoredLinks == liveLinks {
            set(.counts, .passed, title: "Counts match your library: \(restoredItems.formatted()) papers, \(restoredLinks.formatted()) links")
        } else {
            // A library grows between backups. That is normal, so it is information, not a failure.
            set(
                .counts,
                .passedWithNote("Your library has changed since this backup: it had \(restoredItems.formatted()) papers and \(restoredLinks.formatted()) links, and has \(liveItems.formatted()) and \(liveLinks.formatted()) now."),
                title: "Restored copy: \(restoredItems.formatted()) papers, \(restoredLinks.formatted()) links"
            )
        }

        try Task.checkCancellation()

        // 5. PDFs.
        set(.pdfs, .running)
        if let failure = await checkPDFs(in: restored) { return failure }

        try Task.checkCancellation()

        // 6. Earlier workspace (SwiftData package), if the backup holds one.
        let legacyURL = restoredRoot.appendingPathComponent("legacy.\(WorkspaceFormat.packageExtension)", isDirectory: true)
        if fm.fileExists(atPath: legacyURL.path) {
            if context == nil {
                let note = "The earlier workspace data in this backup was not checked."
                set(.earlierWorkspace, .skipped(note))
                notes.append(note)
            } else if let failure = await checkEarlierWorkspace(at: legacyURL, notes: &notes) {
                return failure
            }
        } else {
            set(.earlierWorkspace, .skipped("This backup holds no earlier workspace data."))
        }

        return notes.isEmpty ? .passed : .passedWithNotes(notes)
    }

    // MARK: PDFs

    private nonisolated struct PDFJob: Sendable {
        let url: URL
        let sha256: String
        let relativePath: String
    }

    /// nil when the step passed or had nothing to check; otherwise the failing verdict.
    private func checkPDFs(in restored: Library) async -> DrillVerdict? {

        let rows: [SQLRow]
        do {
            rows = try restored.database.rows(
                "SELECT rel_path, sha256 FROM attachments WHERE kind = 'pdf' AND deleted_at IS NULL ORDER BY id"
            )
        } catch {
            return fail(.pdfs, "The PDF list could not be read: \(AppErrorText.plain(error))")
        }

        var byPath: [String: String] = [:]
        for row in rows {
            if let path = row.text("rel_path") { byPath[path] = row.text("sha256") ?? "" }
        }

        guard !byPath.isEmpty else {
            set(.pdfs, .skipped("This backup holds no PDFs."), title: "No PDFs to open in this backup")
            return nil
        }

        let all = byPath.keys.sorted()
        let chosen = pdfSampler?(all) ?? Array(all.shuffled().prefix(pdfSampleSize))
        let picked = Array(chosen.prefix(pdfSampleSize))

        var jobs: [PDFJob] = []
        var problems: [String] = []

        for path in picked {
            guard let url = try? restored.url(forRelativePath: path) else {
                problems.append("\(path) (path not allowed)")
                continue
            }
            jobs.append(PDFJob(url: url, sha256: byPath[path] ?? "", relativePath: path))
        }

        let hashProblems = await Task.detached(priority: .utility) { Self.hashProblems(jobs) }.value
        problems.append(contentsOf: hashProblems)

        // PDFKit must really be able to open what passed the hash check.
        for job in jobs where !hashProblems.contains(where: { $0.hasPrefix(job.relativePath) }) {
            guard let document = PDFDocument(url: job.url), document.pageCount > 0 else {
                problems.append("\(job.relativePath) (could not be opened as a PDF)")
                continue
            }
        }

        if !problems.isEmpty {
            let shown = problems.prefix(3).joined(separator: "; ")
            let more = problems.count > 3 ? " and \(problems.count - 3) more" : ""
            return fail(.pdfs, "\(problems.count) of \(picked.count) PDFs failed: \(shown)\(more).")
        }

        set(.pdfs, .passed, title: "Opened \(picked.count) random \(picked.count == 1 ? "PDF" : "PDFs")")
        return nil
    }

    /// Missing file or wrong SHA-256, as readable lines starting with the relative path.
    private nonisolated static func hashProblems(_ jobs: [PDFJob]) -> [String] {

        var problems: [String] = []

        for job in jobs {
            guard FileManager.default.fileExists(atPath: job.url.path) else {
                problems.append("\(job.relativePath) (file is missing)")
                continue
            }
            do {
                let actual = try sha256Hex(ofFileAt: job.url)
                if !job.sha256.isEmpty, actual != job.sha256.lowercased() {
                    problems.append("\(job.relativePath) (content does not match its fingerprint)")
                }
            } catch {
                problems.append("\(job.relativePath) (could not be read)")
            }
        }

        return problems
    }

    // MARK: Earlier workspace

    /// nil when the step passed; otherwise the failing verdict.
    private func checkEarlierWorkspace(at package: URL, notes: inout [String]) async -> DrillVerdict? {

        guard let context else {
            set(.earlierWorkspace, .skipped("Not checked."))
            return nil
        }

        set(.earlierWorkspace, .running)

        do {
            let preview = try await WorkspaceRestoreService.preview(packageAt: package, context: context)

            if !preview.pdfProblems.isEmpty {
                let first = preview.pdfProblems.first ?? ""
                return fail(.earlierWorkspace, "\(preview.pdfProblems.count) PDF \(preview.pdfProblems.count == 1 ? "problem" : "problems") in the earlier workspace data, for example: \(first)")
            }

            if preview.backupRecordCount == 0 {
                set(.earlierWorkspace, .passed, title: "Earlier workspace data is readable (it holds no records)")
            } else {
                set(.earlierWorkspace, .passed, title: "Earlier workspace data is readable: \(preview.backupRecordCount.formatted()) records")
            }
            if !preview.warnings.isEmpty {
                let note = "Earlier workspace data: \(preview.warnings.joined(separator: " "))"
                set(.earlierWorkspace, .passedWithNote(note))
                notes.append(note)
            }
            return nil

        } catch {
            return fail(.earlierWorkspace, "The earlier workspace data could not be read: \(AppErrorText.plain(error))")
        }
    }

    // MARK: Recording

    private func record(_ outcome: DrillResult) {

        let code: String
        switch outcome.verdict {
        case .passed:
            code = "passed"
            AppLogger.shared.info("Practice restore passed for \(outcome.backupName).", category: Self.category)
        case .passedWithNotes(let notes):
            code = "notes"
            AppLogger.shared.warning(
                "Practice restore passed for \(outcome.backupName), with notes: \(notes.joined(separator: " "))",
                category: Self.category
            )
        case .failed(let reason):
            code = "failed"
            AppLogger.shared.error(
                RestoreDrillError.drillFailed("\(outcome.backupName): \(reason)"),
                context: "Practice restore failed",
                category: Self.category,
                show: true
            )
        case .skipped(let reason):
            AppLogger.shared.warning("Practice restore skipped: \(reason)", category: Self.category)
            return   // A drill that did not run says nothing about the backup.
        }

        Self.metaSet(library, Keys.at, Library.nowISO(outcome.finishedAt))
        Self.metaSet(library, Keys.result, code)
        Self.metaSet(library, Keys.backup, outcome.backupName)
    }

    /// When the last drill ran and how it went. nil when none was ever recorded.
    static func lastDrill(in library: Library) -> DrillRecord? {

        guard let code = metaGet(library, Keys.result) else { return nil }

        return DrillRecord(
            at: metaGet(library, Keys.at).flatMap(parseISO),
            result: code,
            backupName: metaGet(library, Keys.backup) ?? ""
        )
    }

    /// True when no drill has run in the last `everyDays` days (default 30).
    static func isOverdue(in library: Library, now: Date = Date(), everyDays: Int = 30) -> Bool {
        guard let at = lastDrill(in: library)?.at else { return true }
        return now.timeIntervalSince(at) >= Double(everyDays) * 86_400
    }

    // MARK: Small helpers

    private func set(_ id: DrillStepID, _ state: DrillStepState, title: String? = nil) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = state
        if let title { steps[index].title = title }
    }

    /// Marks the step failed and returns the failing verdict.
    private func fail(_ id: DrillStepID, _ message: String) -> DrillVerdict {
        set(id, .failed(message))
        return .failed(message)
    }

    private static func kind(of url: URL) -> Kind {

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unknown
        }
        if fm.fileExists(atPath: url.appendingPathComponent(Library.databaseFileName).path) {
            return .sqliteBackup
        }
        if url.pathExtension.lowercased() == WorkspaceFormat.packageExtension {
            return .legacyPackage
        }
        return .unknown
    }

    /// `items_in_copy` from backup-info.json, when the backup has one.
    private static func expectedItemCount(inBackupAt root: URL) -> Int64? {
        guard
            let data = try? Data(contentsOf: root.appendingPathComponent("backup-info.json")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let count = object["items_in_copy"] as? NSNumber
        else {
            return nil
        }
        return count.int64Value
    }

    private nonisolated static func folderSize(_ url: URL) -> Int64 {

        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func metaGet(_ library: Library, _ key: String) -> String? {
        (try? library.database.scalarText("SELECT value FROM meta WHERE key = ?", [.text(key)])) ?? nil
    }

    private static func metaSet(_ library: Library, _ key: String, _ value: String) {
        do {
            _ = try library.database.run(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                [.text(key), .text(value)]
            )
        } catch {
            AppLogger.shared.warning(
                "Could not save restore drill result \(key): \(AppErrorText.technical(error))",
                category: category
            )
        }
    }

    private static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
