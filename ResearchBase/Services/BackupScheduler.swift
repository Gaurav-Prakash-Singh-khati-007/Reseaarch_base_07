//
//  BackupScheduler.swift
//  ResearchBase
//
//  Owner: Agent 48 · Features: F-49, F-50
//
//  F-49  Automatic backups. A full copy of the library on a schedule, kept
//        as a single copy that each new verified backup replaces, with an optional
//        second copy on another disk and a visible "last backup" date.
//        A file that has not changed since the previous backup is shared with
//        it (a hard link), so extra copies cost almost no extra disk space.
//  F-50  "Export everything". An open-format copy of the whole library that
//        can be read without this app: library.json, references.bib, notes as
//        Markdown, drafts as folders and every PDF with a readable name.
//
//  WHAT ONE BACKUP IS
//    A folder  "ResearchBase Backup yyyy-MM-dd HH-mm-ss"  containing
//      library.sqlite       a consistent copy made with VACUUM INTO (the live
//                           file is only read), checked after writing
//      files/  drafts/      copies of the PDFs and draft folders
//      legacy.researchbase  the old SwiftData workspace package, only when the
//                           app passes a `legacyPackageWriter` (see below)
//      backup-info.json     date, sizes, schema version, SHA-256 of library.sqlite
//    It is built in a hidden temporary folder and renamed into place last, so
//    a crash or a full disk never leaves a half-written backup that looks real.
//
//  SAFETY RULES
//    - Read-only on the library. The only writes are small bookkeeping rows
//      in `meta` (keys below). No schema change.
//    - Not enough free space -> the backup is SKIPPED, says so, and keeps the
//      older copies (DiskGuard).
//    - Old copies are only pruned after a new backup was written and verified,
//      and NOT when the quick integrity check (IntegrityChecker) found
//      problems, so a good older copy is never rotated away by a damaged one.
//    - Only folders whose names match the backup naming are ever deleted.
//    - A second location that is not connected is a warning, not a failure.
//      The chosen folder is never created, so an unmounted drive's mount point
//      is never recreated on the system disk.
//
//  META KEYS (existing `meta` table)
//    backup_schedule, backup_second_location_path, backup_second_location_bookmark,
//    backup_notify_on_failure, last_backup_at (last SUCCESS), last_backup_attempt_at,
//    last_backup_result, last_backup_detail, last_backup_bytes, last_backup_copies,
//    last_export_at, export_remind_monthly
//
//  HONEST LIMIT
//    Backups run while ResearchBase is running (a check on launch after
//    a short delay, then every 15 minutes). A missed 03:00 is made up at the
//    next launch. Nothing runs while the app is closed.
//
//  PUBLIC API
//  ----------
//  BackupSchedule              .daily (03:00) / .everySixHours / .off ; isDue(...), nextRun(...)
//  BackupRetention             daily 7 · weekly 4 · monthly 12 ; keep(_ dates:, calendar:) -> Set<Date>
//  BackupNaming                folderName(for:), date(fromFolderName:)
//  BackupRecord                url, name, date
//  BackupLastResult            .never .ok .warnings .skipped .failed
//  BackupStatus                lastBackupAt, lastResult, detail, copies, second-location info,
//                              statusBarText(now:) for the window status bar
//  BackupSummary / BackupOutcome   what one run produced
//  ExportReminderState         lastExportAt, remindMonthly, nextDue, isDue(now:)
//  ExportEverythingResult      folder, counts, bytes, warnings
//  BackupSchedulerError        plain-language LocalizedError
//  BackupScheduler             @MainActor @Observable
//    init(library:diskGuard:primaryDirectory:retention:legacyPackageWriter:
//         legacyExportWriter:runIntegrityCheck:calendar:now:onProblem:)
//    .status, .isRunning, .isExporting, .schedule, .notifyOnFailure, .exportReminder, .isExportDue
//    .start(initialDelay:checkEvery:), .stop()
//    .runIfDue() async -> BackupOutcome?
//    .backupNow() async -> BackupOutcome
//    .existingBackups() -> [BackupRecord], .secondLocationBackups() -> [BackupRecord]
//    .setSecondLocation(_ url: URL?)   nil removes it
//    .setExportReminder(enabled:)
//    .exportEverything(to:) async throws -> ExportEverythingResult
//    .refreshStatus()
//    BackupScheduler.makeLegacyPackageWriter(context:profile:)   ready-made closure for the app wiring
//    BackupScheduler.makeLegacyExportWriter(context:profile:)    same for the export
//
//  Wiring note for the later agents (not done here, not my files): ResearchBaseApp creates one
//  BackupScheduler after opening the Library and calls start(); SettingsView binds to
//  `schedule`, `status`, `setSecondLocation`, `backupNow`, `exportEverything`; the status bar
//  shows `status.statusBarText(now:)`.
//
//  Uses only finished code: Library, LibraryDatabase, DiskGuard, IntegrityChecker, AppLogger,
//  WorkspaceBackupService, WorkspaceExportService (only through the closures the app passes in).
//

import Foundation
import Observation
import CryptoKit
import SwiftData

// MARK: - Schedule

nonisolated enum BackupSchedule: String, CaseIterable, Identifiable, Sendable {

    case daily
    case everySixHours
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Every day at 03:00"
        case .everySixHours: return "Every 6 hours"
        case .off: return "Off (not recommended)"
        }
    }

    static let dailyHour = 3
    static let sixHours: TimeInterval = 6 * 3600

    /// After a backup that did not succeed, wait this long before trying again.
    static let retryDelay: TimeInterval = 3600

    func isDue(
        lastSuccess: Date?,
        lastAttempt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {

        guard self != .off else { return false }

        // A recent attempt that did not succeed: do not hammer the disk.
        if let attempt = lastAttempt,
           attempt > (lastSuccess ?? .distantPast),
           now.timeIntervalSince(attempt) < Self.retryDelay {
            return false
        }

        guard let last = lastSuccess else { return true }

        switch self {

        case .daily:
            let trigger = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: Self.dailyHour, minute: 0, second: 0),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .backward
            )
            guard let trigger else { return now.timeIntervalSince(last) >= 24 * 3600 }
            return last < trigger

        case .everySixHours:
            return now.timeIntervalSince(last) >= Self.sixHours

        case .off:
            return false
        }
    }

    /// When the next automatic backup is planned. nil when off.
    func nextRun(lastSuccess: Date?, now: Date, calendar: Calendar = .current) -> Date? {

        switch self {
        case .off:
            return nil
        case .daily:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: Self.dailyHour, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        case .everySixHours:
            guard let last = lastSuccess else { return now }
            return max(now, last.addingTimeInterval(Self.sixHours))
        }
    }
}

// MARK: - Retention

nonisolated struct BackupRetention: Equatable, Sendable {

    var daily: Int = 7
    var weekly: Int = 4
    var monthly: Int = 12

    /// The dates to keep: the newest backup of each of the last `daily` days that
    /// have one, of the last `weekly` weeks that have one, and of the last
    /// `monthly` months that have one. The newest backup is always kept.
    func keep(_ dates: [Date], calendar: Calendar = .current) -> Set<Date> {

        let newestFirst = dates.sorted(by: >)
        var kept = Set<Date>()

        func pick(limit: Int, key: (Date) -> String) {
            var seen = Set<String>()
            for date in newestFirst {
                let k = key(date)
                if seen.contains(k) { continue }
                if seen.count >= limit { break }
                seen.insert(k)
                kept.insert(date)
            }
        }

        pick(limit: max(daily, 1)) { date in
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return "d\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        }

        pick(limit: weekly) { date in
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return "w\(c.yearForWeekOfYear ?? 0)-\(c.weekOfYear ?? 0)"
        }

        pick(limit: monthly) { date in
            let c = calendar.dateComponents([.year, .month], from: date)
            return "m\(c.year ?? 0)-\(c.month ?? 0)"
        }

        return kept
    }
}

// MARK: - Names

nonisolated enum BackupNaming {

    static let prefix = "ResearchBase Backup "

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }

    static func folderName(for date: Date) -> String {
        prefix + formatter().string(from: date)
    }

    /// nil unless the name is exactly a backup folder name this file would write.
    /// This is what keeps pruning away from anything else in the folder.
    static func date(fromFolderName name: String) -> Date? {
        guard name.hasPrefix(prefix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count))
        guard stamp.count == 19 else { return nil }
        return formatter().date(from: stamp)
    }
}

nonisolated struct BackupRecord: Equatable, Identifiable, Sendable {
    let url: URL
    let name: String
    let date: Date
    var id: URL { url }
}

// MARK: - Status

enum BackupLastResult: String, Sendable {
    case never
    case ok
    case warnings
    case skipped
    case failed
}

struct BackupStatus: Equatable {

    var lastBackupAt: Date?
    var lastAttemptAt: Date?
    var lastResult: BackupLastResult = .never
    var detail: String = ""
    var lastBytes: Int64?
    /// Copies of the most recent backup that exist right now (1 or 2).
    var copies: Int = 0
    var secondLocationPath: String?
    var secondLocationConnected: Bool = false

    /// Short text for the window status bar.
    func statusBarText(now: Date = Date(), calendar: Calendar = .current) -> String {

        switch lastResult {
        case .skipped:
            return "Backup skipped"
        case .failed:
            return "Backup failed"
        case .never:
            return "No backup yet"
        case .ok, .warnings:
            guard let at = lastBackupAt else { return "No backup yet" }
            let time = DateFormatter()
            time.locale = Locale.current
            time.dateFormat = "HH:mm"
            if calendar.isDate(at, inSameDayAs: now) {
                return "Backed up today \(time.string(from: at))"
            }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(at, inSameDayAs: yesterday) {
                return "Backed up yesterday \(time.string(from: at))"
            }
            let day = DateFormatter()
            day.locale = Locale.current
            day.setLocalizedDateFormatFromTemplate("d MMM")
            return "Backed up \(day.string(from: at))"
        }
    }
}

struct BackupSummary: Equatable {
    let date: Date
    let folderName: String
    let primaryURL: URL
    let secondURL: URL?
    let bytes: Int64
    let copies: Int
    let warnings: [String]
    let prunedCount: Int
}

enum BackupOutcome: Equatable {
    case completed(BackupSummary)
    case skipped(reason: String)
    case failed(message: String)
}

// MARK: - Export reminder

struct ExportReminderState: Equatable {

    var remindMonthly: Bool
    var lastExportAt: Date?
    /// One month after the last export (or after the library was created).
    var nextDue: Date?

    func isDue(now: Date = Date()) -> Bool {
        guard remindMonthly, let nextDue else { return false }
        return now >= nextDue
    }
}

struct ExportEverythingResult: Equatable {
    let folder: URL
    let itemCount: Int
    let noteCount: Int
    let pdfCount: Int
    let draftFolderCount: Int
    let bytes: Int64
    let warnings: [String]
}

// MARK: - Errors

nonisolated enum BackupSchedulerError: LocalizedError {

    case alreadyRunning
    case verificationFailed(String)
    case copyFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A backup or export is already running."
        case .verificationFailed(let detail):
            return "The backup was written but did not pass its check, so it was not kept. \(detail)"
        case .copyFailed(let detail):
            return "The copy could not be completed. \(detail)"
        case .exportFailed(let detail):
            return "The export could not be completed. \(detail)"
        }
    }
}

// MARK: - Scheduler

@MainActor
@Observable
final class BackupScheduler {

    /// Writes the old SwiftData workspace package to the given URL.
    typealias PackageWriter = @MainActor (URL) async throws -> Void
    /// Writes one old-workspace export format to the given URL.
    typealias ExportWriter = @MainActor (WorkspaceExportFormat, URL) async throws -> Void

    // MARK: Observable state

    private(set) var status = BackupStatus()
    private(set) var isRunning = false
    private(set) var isExporting = false
    private(set) var exportReminder = ExportReminderState(remindMonthly: true, lastExportAt: nil, nextDue: nil)

    var schedule: BackupSchedule = .daily {
        didSet {
            guard schedule != oldValue else { return }
            Self.metaSet(library, Keys.schedule, schedule.rawValue)
        }
    }

    var notifyOnFailure: Bool = true {
        didSet {
            guard notifyOnFailure != oldValue else { return }
            Self.metaSet(library, Keys.notify, notifyOnFailure ? "1" : "0")
        }
    }

    var isExportDue: Bool { exportReminder.isDue(now: now()) }

    // MARK: Collaborators

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let diskGuard: DiskGuard
    @ObservationIgnored private let primaryDirectory: URL
    @ObservationIgnored private let retention: BackupRetention
    @ObservationIgnored private let legacyPackageWriter: PackageWriter?
    @ObservationIgnored private let legacyExportWriter: ExportWriter?
    @ObservationIgnored private let runIntegrityCheck: Bool
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let onProblem: (@MainActor (String) -> Void)?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var announcedExportDue = false

    private enum Keys {
        static let schedule = "backup_schedule"
        static let secondPath = "backup_second_location_path"
        static let secondBookmark = "backup_second_location_bookmark"
        static let notify = "backup_notify_on_failure"
        static let lastAt = "last_backup_at"
        static let lastAttempt = "last_backup_attempt_at"
        static let lastResult = "last_backup_result"
        static let lastDetail = "last_backup_detail"
        static let lastBytes = "last_backup_bytes"
        static let lastCopies = "last_backup_copies"
        static let lastExport = "last_export_at"
        static let remindExport = "export_remind_monthly"
    }

    static let secondLocationSubfolder = "ResearchBase Backups"
    private static let category = "backup"

    // MARK: Init

    init(
        library: Library,
        diskGuard: DiskGuard = DiskGuard(),
        primaryDirectory: URL? = nil,
        retention: BackupRetention = BackupRetention(daily: 1, weekly: 0, monthly: 0),
        legacyPackageWriter: PackageWriter? = nil,
        legacyExportWriter: ExportWriter? = nil,
        runIntegrityCheck: Bool = true,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() },
        onProblem: (@MainActor (String) -> Void)? = nil
    ) {
        self.library = library
        self.diskGuard = diskGuard
        self.primaryDirectory = primaryDirectory ?? library.backupsURL
        self.retention = retention
        self.legacyPackageWriter = legacyPackageWriter
        self.legacyExportWriter = legacyExportWriter
        self.runIntegrityCheck = runIntegrityCheck
        self.calendar = calendar
        self.now = now
        self.onProblem = onProblem

        if let raw = Self.metaGet(library, Keys.schedule), let saved = BackupSchedule(rawValue: raw) {
            self.schedule = saved
        }
        if let raw = Self.metaGet(library, Keys.notify) {
            self.notifyOnFailure = (raw != "0")
        }

        refreshStatus()
    }

    // MARK: Running on a schedule

    /// Checks shortly after launch (so it does not compete with start-up), then
    /// every `checkEvery` seconds. A backup missed while the app was closed is made up here.
    func start(initialDelay: TimeInterval = 60, checkEvery: TimeInterval = 900) {

        guard loopTask == nil else { return }

        loopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                guard let scheduler = self else { return }
                await scheduler.tick()
                try? await Task.sleep(for: .seconds(checkEvery))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func tick() async {
        _ = await runIfDue()
        announceExportIfDue()
    }

    /// Runs a backup only when the schedule says one is due. nil when nothing was due.
    @discardableResult
    func runIfDue() async -> BackupOutcome? {

        let current = now()
        guard schedule.isDue(
            lastSuccess: status.lastBackupAt,
            lastAttempt: status.lastAttemptAt,
            now: current,
            calendar: calendar
        ) else {
            return nil
        }

        return await backupNow()
    }

    private func announceExportIfDue() {
        refreshExportReminder()
        if isExportDue, !announcedExportDue {
            announcedExportDue = true
            AppLogger.shared.info(
                "A monthly “export everything” is due. Settings > Backup has the button.",
                category: Self.category
            )
        }
    }

    // MARK: Back up now (F-49)

    @discardableResult
    func backupNow() async -> BackupOutcome {

        guard !isRunning, !isExporting else {
            return .skipped(reason: BackupSchedulerError.alreadyRunning.errorDescription ?? "Already running.")
        }

        isRunning = true
        defer { isRunning = false }

        let started = now()

        do {
            let summary = try await performBackup(started: started)
            recordSuccess(summary)
            return .completed(summary)

        } catch let error as DiskGuardError {

            // Low disk: skipped, said so, older copies untouched.
            let message = error.errorDescription ?? "There is not enough disk space for a backup."
            recordNonSuccess(.skipped, detail: message, at: started)
            surface(error, context: "Backup skipped")
            return .skipped(reason: message)

        } catch is CancellationError {

            recordNonSuccess(.skipped, detail: "The backup was stopped before it finished.", at: started)
            return .skipped(reason: "The backup was stopped before it finished.")

        } catch {

            let message = AppErrorText.plain(error)
            recordNonSuccess(.failed, detail: message, at: started)
            surface(error, context: "Backup failed")
            return .failed(message: message)
        }
    }

    private func surface(_ error: Error, context: String) {
        AppLogger.shared.error(error, context: context, category: Self.category, show: notifyOnFailure)
        if notifyOnFailure {
            onProblem?("\(context). \(AppErrorText.plain(error))")
        }
    }

    // MARK: The backup itself

    private func performBackup(started: Date) async throws -> BackupSummary {

        let fm = FileManager.default
        var warnings: [String] = []

        try fm.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        diskGuard.removeStaleTemporaryFiles(in: primaryDirectory, olderThan: 3600, recursive: false)

        // 1. Room for it? (skip, do not fail, when there is not)
        let databaseURL = library.databaseURL
        let filesURL = library.filesURL
        let draftsURL = library.draftsURL

        let estimate = await Task.detached(priority: .utility) {
            Self.fileSize(databaseURL) + Self.folderSize(filesURL) + Self.folderSize(draftsURL)
        }.value

        try diskGuard.ensureRoom(for: estimate, at: primaryDirectory)

        // 2. Is the live library healthy? Decides whether old copies may be rotated away.
        var healthy = true
        if runIntegrityCheck {
            do {
                let report = try await IntegrityChecker.run(
                    on: library, depth: .quick, recordResult: false, now: started
                )
                if !report.isHealthy {
                    healthy = false
                    warnings.append(
                        "The library check found \(report.errorCount) \(report.errorCount == 1 ? "problem" : "problems"). The backup was made, and older backups were kept."
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                healthy = false
                warnings.append("The library check could not run, so older backups were kept.")
                AppLogger.shared.warning(
                    "Integrity check before backup failed: \(AppErrorText.technical(error))",
                    category: Self.category
                )
            }
        }

        // 3. Build in a hidden folder.
        var backupDate = started
        var name = BackupNaming.folderName(for: backupDate)
        while fm.fileExists(atPath: primaryDirectory.appendingPathComponent(name).path) {
            backupDate = backupDate.addingTimeInterval(1)
            name = BackupNaming.folderName(for: backupDate)
        }

        let staging = primaryDirectory.appendingPathComponent(
            "\(DiskGuard.temporaryPrefix)\(UUID().uuidString)", isDirectory: true
        )
        let finalURL = primaryDirectory.appendingPathComponent(name, isDirectory: true)

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            // 3a. Database copy (reads the live file only).
            let copyURL = staging.appendingPathComponent(Library.databaseFileName)
            try library.database.exec("VACUUM INTO '\(Self.sqlQuoted(copyURL.path))'")

            let (sourceItems, copyItems) = try Self.verifyDatabaseCopy(
                at: copyURL, against: library.database
            )

            // 3b. PDFs and draft folders (off the main actor). Files that are the same as in
            //     the newest earlier backup are linked to it instead of copied again.
            let diskGuardCopy = diskGuard
            let previousBackup = Self.listBackups(in: primaryDirectory).first?.url
            let previousFiles = previousBackup?.appendingPathComponent("files", isDirectory: true)
            let previousDrafts = previousBackup?.appendingPathComponent("drafts", isDirectory: true)
            try await Task.detached(priority: .utility) {
                try Self.copyIfPresent(from: filesURL, to: staging.appendingPathComponent("files", isDirectory: true), reusing: previousFiles, diskGuard: diskGuardCopy)
                try Self.copyIfPresent(from: draftsURL, to: staging.appendingPathComponent("drafts", isDirectory: true), reusing: previousDrafts, diskGuard: diskGuardCopy)
            }.value

            // 3c. Old SwiftData workspace, until the migration has moved it over.
            if let legacyPackageWriter {
                do {
                    try await legacyPackageWriter(staging.appendingPathComponent("legacy.researchbase", isDirectory: true))
                } catch {
                    warnings.append("The earlier workspace data could not be included: \(AppErrorText.plain(error))")
                    AppLogger.shared.warning(
                        "Legacy workspace backup failed: \(AppErrorText.technical(error))",
                        category: Self.category
                    )
                }
            }

            // 3d. Info file.
            let schemaVersion = try library.schemaVersion
            let sha = try Self.sha256Hex(ofFileAt: copyURL)
            let info: [String: Any] = [
                "format": 1,
                "created_at": Library.nowISO(backupDate),
                "schema_version": schemaVersion,
                "library_sqlite_sha256": sha,
                "items_in_library": sourceItems,
                "items_in_copy": copyItems,
                "includes_legacy_workspace": fm.fileExists(atPath: staging.appendingPathComponent("legacy.researchbase").path)
            ]
            let infoData = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            try infoData.write(to: staging.appendingPathComponent("backup-info.json"), options: .atomic)

            // 3e. Move into place, last.
            try fm.moveItem(at: staging, to: finalURL)

        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        let totalBytes = await Task.detached(priority: .utility) { Self.folderSize(finalURL) }.value

        // 4. Second location (a problem here is a warning only).
        var secondURL: URL?
        var copies = 1

        switch await copyToSecondLocation(finalURL, name: name, bytes: totalBytes) {
        case .copied(let url):
            secondURL = url
            copies = 2
        case .notConfigured:
            break
        case .skipped(let message):
            warnings.append(message)
        }

        // 5. Rotate old copies, only after a good new one exists and the library is healthy.
        var pruned = 0
        if healthy {
            pruned += prune(in: primaryDirectory, keeping: finalURL)
            if let secondDir = secondURL?.deletingLastPathComponent() {
                pruned += prune(in: secondDir, keeping: secondURL)
            }
        }

        return BackupSummary(
            date: backupDate,
            folderName: name,
            primaryURL: finalURL,
            secondURL: secondURL,
            bytes: totalBytes,
            copies: copies,
            warnings: warnings,
            prunedCount: pruned
        )
    }

    // MARK: Second location (F-49)

    private enum SecondCopyResult {
        case notConfigured
        case copied(URL)
        case skipped(String)
    }

    /// The chosen folder as a URL, with security-scoped access started when a bookmark was stored.
    private func resolveSecondLocation() -> (url: URL, scoped: Bool)? {

        if let encoded = Self.metaGet(library, Keys.secondBookmark),
           let data = Data(base64Encoded: encoded) {

            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let scoped = url.startAccessingSecurityScopedResource()
                if stale,
                   let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    Self.metaSet(library, Keys.secondBookmark, fresh.base64EncodedString())
                }
                return (url, scoped)
            }
        }

        if let path = Self.metaGet(library, Keys.secondPath), !path.isEmpty {
            return (URL(fileURLWithPath: path, isDirectory: true), false)
        }

        return nil
    }

    private static func isUsableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    private func copyToSecondLocation(_ source: URL, name: String, bytes: Int64) async -> SecondCopyResult {

        guard let location = resolveSecondLocation() else { return .notConfigured }
        defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }

        // The chosen folder itself must already exist. Never create it: if the drive
        // is unplugged, creating its mount point would fill the system disk instead.
        guard Self.isUsableFolder(location.url) else {
            return .skipped("The second backup location (\(location.url.path)) is not connected, so only one copy was made.")
        }

        let directory = location.url.appendingPathComponent(Self.secondLocationSubfolder, isDirectory: true)
        let diskGuardCopy = diskGuard
        let previousSecond = Self.listBackups(in: directory).first(where: { $0.name != name })?.url

        do {
            let copied = try await Task.detached(priority: .utility) {
                try Self.copyBackup(from: source, intoDirectory: directory, name: name, bytes: bytes, reusing: previousSecond, diskGuard: diskGuardCopy)
            }.value
            return .copied(copied)
        } catch {
            AppLogger.shared.warning(
                "Second backup copy failed: \(AppErrorText.technical(error))",
                category: Self.category
            )
            return .skipped("The copy on the second location failed: \(AppErrorText.plain(error)) Only one copy was made.")
        }
    }

    /// Chooses (or with nil, removes) the second location. The folder must exist.
    func setSecondLocation(_ url: URL?) {

        guard let url else {
            Self.metaDelete(library, Keys.secondPath)
            Self.metaDelete(library, Keys.secondBookmark)
            refreshStatus()
            return
        }

        Self.metaSet(library, Keys.secondPath, url.path)

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let data = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            Self.metaSet(library, Keys.secondBookmark, data.base64EncodedString())
        } else {
            // Not sandboxed, or the bookmark could not be made: the plain path is enough then.
            Self.metaDelete(library, Keys.secondBookmark)
        }

        refreshStatus()
    }

    // MARK: Listing and pruning

    func existingBackups() -> [BackupRecord] {
        Self.listBackups(in: primaryDirectory)
    }

    func secondLocationBackups() -> [BackupRecord] {

        guard let location = resolveSecondLocation() else { return [] }
        defer { if location.scoped { location.url.stopAccessingSecurityScopedResource() } }

        guard Self.isUsableFolder(location.url) else { return [] }
        return Self.listBackups(
            in: location.url.appendingPathComponent(Self.secondLocationSubfolder, isDirectory: true)
        )
    }

    nonisolated static func listBackups(in directory: URL) -> [BackupRecord] {

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { url in
            guard
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let date = BackupNaming.date(fromFolderName: url.lastPathComponent)
            else {
                return nil
            }
            return BackupRecord(url: url, name: url.lastPathComponent, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Removes the backups the retention rule does not keep. Never touches a folder
    /// whose name is not a backup name, and never touches `keeping`.
    private func prune(in directory: URL, keeping: URL?) -> Int {

        let records = Self.listBackups(in: directory)
        let keep = retention.keep(records.map(\.date), calendar: calendar)

        var removed = 0
        for record in records where !keep.contains(record.date) {
            if let keeping, record.url.standardizedFileURL == keeping.standardizedFileURL { continue }
            do {
                try FileManager.default.removeItem(at: record.url)
                removed += 1
            } catch {
                AppLogger.shared.warning(
                    "Could not remove old backup \(record.name): \(AppErrorText.technical(error))",
                    category: Self.category
                )
            }
        }
        return removed
    }

    // MARK: Status bookkeeping

    private func recordSuccess(_ summary: BackupSummary) {

        let result: BackupLastResult = summary.warnings.isEmpty ? .ok : .warnings
        let detail = summary.warnings.joined(separator: " ")

        Self.metaSet(library, Keys.lastAt, Library.nowISO(summary.date))
        Self.metaSet(library, Keys.lastAttempt, Library.nowISO(summary.date))
        Self.metaSet(library, Keys.lastResult, result.rawValue)
        Self.metaSet(library, Keys.lastDetail, detail)
        Self.metaSet(library, Keys.lastBytes, String(summary.bytes))
        Self.metaSet(library, Keys.lastCopies, String(summary.copies))

        if !summary.warnings.isEmpty {
            AppLogger.shared.warning("Backup finished with notes: \(detail)", category: Self.category)
            if notifyOnFailure { onProblem?("Backup finished, with a note. \(detail)") }
        } else {
            AppLogger.shared.info(
                "Backup finished: \(DiskGuard.formatBytes(summary.bytes)), \(summary.copies) \(summary.copies == 1 ? "copy" : "copies"), \(summary.prunedCount) old removed.",
                category: Self.category
            )
        }

        refreshStatus()
    }

    /// A skipped or failed run: `last_backup_at` (the last SUCCESS) is left alone.
    private func recordNonSuccess(_ result: BackupLastResult, detail: String, at date: Date) {
        Self.metaSet(library, Keys.lastAttempt, Library.nowISO(date))
        Self.metaSet(library, Keys.lastResult, result.rawValue)
        Self.metaSet(library, Keys.lastDetail, detail)
        refreshStatus()
    }

    /// Re-reads everything the status shows. Cheap; safe to call when Settings opens.
    func refreshStatus() {

        var next = BackupStatus()
        next.lastBackupAt = Self.metaGet(library, Keys.lastAt).flatMap(Self.parseISO)
        next.lastAttemptAt = Self.metaGet(library, Keys.lastAttempt).flatMap(Self.parseISO)
        next.lastResult = Self.metaGet(library, Keys.lastResult).flatMap(BackupLastResult.init(rawValue:)) ?? .never
        next.detail = Self.metaGet(library, Keys.lastDetail) ?? ""
        next.lastBytes = Self.metaGet(library, Keys.lastBytes).flatMap { Int64($0) }
        next.copies = Self.metaGet(library, Keys.lastCopies).flatMap { Int($0) } ?? 0

        if let location = resolveSecondLocation() {
            next.secondLocationPath = location.url.path
            next.secondLocationConnected = Self.isUsableFolder(location.url)
            if location.scoped { location.url.stopAccessingSecurityScopedResource() }
        }

        status = next
        refreshExportReminder()
    }

    // MARK: Export everything (F-50)

    func setExportReminder(enabled: Bool) {
        Self.metaSet(library, Keys.remindExport, enabled ? "1" : "0")
        announcedExportDue = false
        refreshExportReminder()
    }

    private func refreshExportReminder() {

        let remind = Self.metaGet(library, Keys.remindExport) != "0"
        let last = Self.metaGet(library, Keys.lastExport).flatMap(Self.parseISO)
        let created = (try? library.createdAt).flatMap { $0 }.flatMap(Self.parseISO)

        let base = last ?? created
        let due = base.flatMap { calendar.date(byAdding: .month, value: 1, to: $0) }

        exportReminder = ExportReminderState(remindMonthly: remind, lastExportAt: last, nextDue: due)
    }

    /// Writes an open-format copy of the whole library into a new folder inside `parent`
    /// (default: the Documents folder), e.g. "ResearchBase Export 2026-10-22".
    func exportEverything(to parent: URL? = nil) async throws -> ExportEverythingResult {

        guard !isRunning, !isExporting else { throw BackupSchedulerError.alreadyRunning }

        isExporting = true
        defer { isExporting = false }

        let fm = FileManager.default
        let exportDate = now()

        let parentURL = parent
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? library.exportsURL

        let scoped = parentURL.startAccessingSecurityScopedResource()
        defer { if scoped { parentURL.stopAccessingSecurityScopedResource() } }

        try fm.createDirectory(at: parentURL, withIntermediateDirectories: true)

        // Room for it?
        let filesURL = library.filesURL
        let draftsURL = library.draftsURL
        let databaseURL = library.databaseURL
        let estimate = await Task.detached(priority: .utility) {
            Self.fileSize(databaseURL) + Self.folderSize(filesURL) + Self.folderSize(draftsURL)
        }.value

        do {
            try diskGuard.ensureRoom(for: estimate, at: parentURL)
        } catch {
            AppLogger.shared.error(error, context: "Export skipped", category: Self.category, show: true)
            throw error
        }

        // Unique folder name.
        let day = Self.dayStamp(exportDate)
        var folderName = "ResearchBase Export \(day)"
        var suffix = 2
        while fm.fileExists(atPath: parentURL.appendingPathComponent(folderName).path) {
            folderName = "ResearchBase Export \(day) \(suffix)"
            suffix += 1
        }

        let staging = parentURL.appendingPathComponent(
            "\(DiskGuard.temporaryPrefix)\(UUID().uuidString)", isDirectory: true
        )
        let finalURL = parentURL.appendingPathComponent(folderName, isDirectory: true)

        var warnings: [String] = []

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)

            // library.json: every table, as plain JSON.
            let (json, tableCount) = try Self.libraryJSON(from: library.database, exportedAt: exportDate, schemaVersion: library.schemaVersion)
            try json.write(to: staging.appendingPathComponent("library.json"), options: .atomic)

            // references.bib
            let bib = try Self.bibTeX(from: library.database)
            try Data(bib.text.utf8).write(to: staging.appendingPathComponent("references.bib"), options: .atomic)
            warnings.append(contentsOf: bib.warnings)

            // notes/ as Markdown
            let notes = try Self.writeNotes(from: library.database, into: staging.appendingPathComponent("notes", isDirectory: true))

            // pdfs/ with readable names (copy list built here, copied off the main actor)
            let plan = try Self.pdfCopyPlan(library: library)
            let pdfFolder = staging.appendingPathComponent("pdfs", isDirectory: true)
            let diskGuardCopy = diskGuard
            let pdfResult = try await Task.detached(priority: .utility) {
                try Self.copyPlannedPDFs(plan, into: pdfFolder, diskGuard: diskGuardCopy)
            }.value
            warnings.append(contentsOf: pdfResult.warnings)

            // drafts/ as folders
            let draftCount = try await Task.detached(priority: .utility) { () -> Int in
                let target = staging.appendingPathComponent("drafts", isDirectory: true)
                try Self.copyIfPresent(from: draftsURL, to: target, diskGuard: diskGuardCopy)
                let kids = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
                return kids.filter { !$0.hasPrefix(".") }.count
            }.value

            // Old SwiftData content, until the migration has moved it over.
            if let legacyExportWriter {
                let legacyFolder = staging.appendingPathComponent("legacy", isDirectory: true)
                try fm.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
                let jobs: [(WorkspaceExportFormat, String)] = [
                    (.json, "workspace.json"),
                    (.bibtex, "references.bib"),
                    (.markdown, "summary.md")
                ]
                for (format, fileName) in jobs {
                    do {
                        try await legacyExportWriter(format, legacyFolder.appendingPathComponent(fileName))
                    } catch let error as WorkspaceExportError {
                        if case .nothingToExport = error { continue }
                        warnings.append("Earlier workspace \(fileName) could not be written: \(AppErrorText.plain(error))")
                    } catch {
                        warnings.append("Earlier workspace \(fileName) could not be written: \(AppErrorText.plain(error))")
                    }
                }
                if ((try? fm.contentsOfDirectory(atPath: legacyFolder.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: legacyFolder)
                }
            }

            // README
            let readme = Self.readmeText(
                exportDate: exportDate,
                tableCount: tableCount,
                itemCount: bib.entryCount,
                noteCount: notes,
                pdfCount: pdfResult.copied
            )
            try Data(readme.utf8).write(to: staging.appendingPathComponent("README.txt"), options: .atomic)

            try fm.moveItem(at: staging, to: finalURL)

            let bytes = await Task.detached(priority: .utility) { Self.folderSize(finalURL) }.value

            Self.metaSet(library, Keys.lastExport, Library.nowISO(exportDate))
            announcedExportDue = false
            refreshExportReminder()

            AppLogger.shared.info(
                "Export everything finished: \(bib.entryCount) items, \(notes) notes, \(pdfResult.copied) PDFs, \(DiskGuard.formatBytes(bytes)).",
                category: Self.category
            )

            return ExportEverythingResult(
                folder: finalURL,
                itemCount: bib.entryCount,
                noteCount: notes,
                pdfCount: pdfResult.copied,
                draftFolderCount: draftCount,
                bytes: bytes,
                warnings: warnings
            )

        } catch {
            try? fm.removeItem(at: staging)
            AppLogger.shared.error(error, context: "Export failed", category: Self.category, show: true)
            throw error
        }
    }

    // MARK: Ready-made closures for the app wiring

    /// Use as `legacyPackageWriter:` while content still lives in SwiftData.
    static func makeLegacyPackageWriter(context: ModelContext, profile: ProfileStore? = nil) -> PackageWriter {
        { url in
            _ = try await WorkspaceBackupService.createBackup(context: context, to: url, profile: profile)
        }
    }

    /// Use as `legacyExportWriter:` while content still lives in SwiftData.
    static func makeLegacyExportWriter(context: ModelContext, profile: ProfileStore? = nil) -> ExportWriter {
        { format, url in
            _ = try await WorkspaceExportService.export(format: format, context: context, to: url, profile: profile)
        }
    }
}

// MARK: - Private helpers (file system, SQL, text)

extension BackupScheduler {

    // MARK: meta

    fileprivate static func metaGet(_ library: Library, _ key: String) -> String? {
        (try? library.database.scalarText("SELECT value FROM meta WHERE key = ?", [.text(key)])) ?? nil
    }

    fileprivate static func metaSet(_ library: Library, _ key: String, _ value: String) {
        do {
            _ = try library.database.run(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                [.text(key), .text(value)]
            )
        } catch {
            AppLogger.shared.warning(
                "Could not save backup setting \(key): \(AppErrorText.technical(error))",
                category: "backup"
            )
        }
    }

    fileprivate static func metaDelete(_ library: Library, _ key: String) {
        _ = try? library.database.run("DELETE FROM meta WHERE key = ?", [.text(key)])
    }

    fileprivate static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    fileprivate static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    fileprivate static func sqlQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: Files

    nonisolated fileprivate static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated fileprivate static func folderSize(_ url: URL) -> Int64 {

        let fm = FileManager.default
        guard let walker = fm.enumerator(
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
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    nonisolated fileprivate static func copyIfPresent(from source: URL, to destination: URL, reusing previous: URL? = nil, diskGuard: DiskGuard) throws {

        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }

        try diskGuard.ensureRoom(for: folderSize(source), at: destination.deletingLastPathComponent())
        try copyTree(from: source, to: destination, reusing: previous)
    }

    /// Copies a folder. A file that has the same size and modification time as the file at the
    /// same place in `previous` is hard-linked to it instead of copied, so it takes no extra
    /// disk space. If linking is not possible (another disk, for example) the file is copied.
    nonisolated fileprivate static func copyTree(from source: URL, to destination: URL, reusing previous: URL?) throws {

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        for entry in entries {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            let old = previous?.appendingPathComponent(entry.lastPathComponent)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])

            if values?.isSymbolicLink == true {
                try fm.copyItem(at: entry, to: target)
            } else if values?.isDirectory == true {
                try copyTree(from: entry, to: target, reusing: old)
            } else if let old, isUnchanged(entry, old), (try? fm.linkItem(at: old, to: target)) != nil {
                continue
            } else {
                try fm.copyItem(at: entry, to: target)
            }
        }
    }

    /// True when both are regular files with the same size and (to the millisecond) the same
    /// modification time. When in doubt this says false, and the file is simply copied.
    nonisolated fileprivate static func isUnchanged(_ a: URL, _ b: URL) -> Bool {

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        guard
            let x = try? a.resourceValues(forKeys: keys),
            let y = try? b.resourceValues(forKeys: keys),
            x.isRegularFile == true, y.isRegularFile == true,
            let sizeA = x.fileSize, let sizeB = y.fileSize, sizeA == sizeB,
            let dateA = x.contentModificationDate, let dateB = y.contentModificationDate
        else {
            return false
        }

        return abs(dateA.timeIntervalSince(dateB)) < 0.001
    }

    /// Copies a finished backup folder into `directory`, all or nothing.
    nonisolated fileprivate static func copyBackup(
        from source: URL,
        intoDirectory directory: URL,
        name: String,
        bytes: Int64,
        reusing previous: URL? = nil,
        diskGuard: DiskGuard
    ) throws -> URL {

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try diskGuard.ensureRoom(for: bytes, at: directory)

        let temp = directory.appendingPathComponent("\(DiskGuard.temporaryPrefix)\(UUID().uuidString)", isDirectory: true)
        let final = directory.appendingPathComponent(name, isDirectory: true)

        do {
            try copyTree(from: source, to: temp, reusing: previous)

            let copied = folderSize(temp)
            guard copied == bytes else {
                throw BackupSchedulerError.copyFailed("The copy is \(copied) bytes but should be \(bytes).")
            }

            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: temp, to: final)
            return final

        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    fileprivate static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Verify the database copy

    /// Opens the copy read-only, runs `quick_check`, and compares the item count with the live library.
    fileprivate static func verifyDatabaseCopy(at url: URL, against live: LibraryDatabase) throws -> (live: Int64, copy: Int64) {

        let copy: LibraryDatabase
        do {
            copy = try LibraryDatabase(path: url.path, readOnly: true, create: false)
        } catch {
            throw BackupSchedulerError.verificationFailed("The copy could not be opened.")
        }
        defer { copy.close() }

        let check = try copy.scalarText("PRAGMA quick_check") ?? "no answer"
        guard check == "ok" else {
            throw BackupSchedulerError.verificationFailed("The database check said: \(check).")
        }

        let liveItems = try live.scalarInt("SELECT COUNT(*) FROM items") ?? 0
        let copyItems = try copy.scalarInt("SELECT COUNT(*) FROM items") ?? 0
        guard liveItems == copyItems else {
            throw BackupSchedulerError.verificationFailed("The copy has \(copyItems) items but the library has \(liveItems).")
        }

        return (liveItems, copyItems)
    }

    // MARK: Export: library.json

    fileprivate static func jsonValue(_ value: SQLValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .int(let v): return NSNumber(value: v)
        case .double(let v): return v.isFinite ? NSNumber(value: v) : NSNull()
        case .text(let v): return v
        case .blob(let v): return v.base64EncodedString()
        }
    }

    fileprivate static func libraryJSON(
        from database: LibraryDatabase,
        exportedAt: Date,
        schemaVersion: Int
    ) throws -> (data: Data, tableCount: Int) {

        let names = try database.rows(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'fts_%'
              AND name <> 'lookup_cache'
            ORDER BY name
            """
        ).compactMap { $0.text("name") }

        var tables: [String: Any] = [:]
        for name in names {
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let rows = try database.rows("SELECT * FROM \(quoted)")
            tables[name] = rows.map { row in
                row.columns.mapValues(jsonValue)
            }
        }

        let document: [String: Any] = [
            "format": "researchbase-library-export",
            "format_version": 1,
            "exported_at": Library.nowISO(exportedAt),
            "schema_version": schemaVersion,
            "note": "Every table of library.sqlite as plain JSON. Times are UTC ISO-8601. Ids are UUID text.",
            "tables": tables
        ]

        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return (data, names.count)
    }

    // MARK: Export: references.bib

    fileprivate static func bibTeX(from database: LibraryDatabase) throws -> (text: String, entryCount: Int, warnings: [String]) {

        let items = try database.rows(
            """
            SELECT * FROM items
            WHERE deleted_at IS NULL AND review_state = 'accepted'
            ORDER BY citation_key, id
            """
        )

        let creatorRows = try database.rows(
            """
            SELECT ic.item_id AS item_id, ic.role AS role, ic.position AS position,
                   c.family AS family, c.given AS given, c.suffix AS suffix, c.is_org AS is_org
            FROM item_creators ic JOIN creators c ON c.id = ic.creator_id
            ORDER BY ic.item_id, ic.role, ic.position
            """
        )

        var byItem: [String: [SQLRow]] = [:]
        for row in creatorRows {
            if let id = row.text("item_id") { byItem[id, default: []].append(row) }
        }

        func name(_ row: SQLRow) -> String {
            let family = row.text("family") ?? ""
            let given = row.text("given") ?? ""
            let suffix = row.text("suffix") ?? ""
            if row.int("is_org") == 1 { return "{\(bibSafe(family))}" }
            var text = bibSafe(family)
            if !suffix.isEmpty { text += ", " + bibSafe(suffix) }
            if !given.isEmpty { text += ", " + bibSafe(given) }
            return text
        }

        var warnings: [String] = []
        var usedKeys = Set<String>()
        var out = "% ResearchBase export. One entry per library item.\n\n"

        for item in items {

            let id = item.text("id") ?? ""
            var key = item.text("citation_key") ?? ""
            if key.isEmpty { key = "item" + String(id.prefix(8)) }
            if usedKeys.contains(key) {
                var n = 2
                while usedKeys.contains("\(key)-\(n)") { n += 1 }
                warnings.append("Citation key \(key) is used twice; the second entry is \(key)-\(n).")
                key = "\(key)-\(n)"
            }
            usedKeys.insert(key)

            let type = item.text("item_type") ?? "article"
            let entryType: String
            switch type {
            case "article": entryType = "article"
            case "conference": entryType = "inproceedings"
            case "book": entryType = "book"
            case "chapter": entryType = "incollection"
            case "thesis": entryType = "phdthesis"
            case "report": entryType = "techreport"
            default: entryType = "misc"
            }

            var fields: [(String, String)] = []
            func add(_ field: String, _ value: String?) {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                fields.append((field, bibSafe(value)))
            }

            let people = byItem[id] ?? []
            let authors = people.filter { $0.text("role") == "author" }.map(name)
            let editors = people.filter { $0.text("role") == "editor" }.map(name)
            if !authors.isEmpty { fields.append(("author", authors.joined(separator: " and "))) }
            if !editors.isEmpty { fields.append(("editor", editors.joined(separator: " and "))) }

            add("title", item.text("title"))

            let venue = item.text("venue")
            switch entryType {
            case "article": add("journal", venue)
            case "inproceedings", "incollection": add("booktitle", venue)
            case "phdthesis": add("school", venue)
            case "techreport": add("institution", venue)
            default: add("howpublished", venue)
            }

            if let year = item.int("year") { fields.append(("year", String(year))) }
            add("month", item.text("month"))
            add("volume", item.text("volume"))
            add("number", item.text("issue"))
            add("pages", item.text("pages"))
            add("publisher", item.text("publisher"))
            add("edition", item.text("edition"))
            add("doi", item.text("doi"))
            if let arxiv = item.text("arxiv_id"), !arxiv.isEmpty {
                fields.append(("eprint", bibSafe(arxiv)))
                fields.append(("archivePrefix", "arXiv"))
            }
            add("url", item.text("url"))
            add("abstract", item.text("abstract"))

            out += "@\(entryType){\(key.filter { !$0.isWhitespace && $0 != "," && $0 != "{" && $0 != "}" }),\n"
            out += fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
            out += "\n}\n\n"
        }

        return (out, items.count, warnings)
    }

    /// Makes a value safe inside a `{...}` BibTeX field: braces must balance; `& % # _` are escaped.
    fileprivate static func bibSafe(_ text: String) -> String {

        var depth = 0
        var balanced = true
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1; if depth < 0 { balanced = false; break } }
        }
        if depth != 0 { balanced = false }

        var out = ""
        for character in text {
            switch character {
            case "{", "}":
                if balanced { out.append(character) }
            case "&", "%", "#", "_":
                out.append("\\"); out.append(character)
            case "\n", "\r":
                out.append(" ")
            default:
                out.append(character)
            }
        }
        return out
    }

    // MARK: Export: notes as Markdown

    fileprivate static func safeFileName(_ text: String, fallback: String = "untitled") -> String {

        let banned = CharacterSet(charactersIn: "/\\:?*\"<>|\u{0}").union(.controlCharacters)
        var cleaned = text.unicodeScalars.map { banned.contains($0) ? "-" : String($0) }.joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func yamlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    fileprivate static func writeNotes(from database: LibraryDatabase, into folder: URL) throws -> Int {

        let rows = try database.rows(
            "SELECT * FROM thoughts WHERE deleted_at IS NULL ORDER BY kind, created_at, id"
        )

        let fm = FileManager.default
        if !rows.isEmpty { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }

        var count = 0
        for row in rows {

            let kind = row.text("kind") ?? "note"
            let title = row.text("title") ?? ""
            let id = row.text("id") ?? UUID().uuidString

            let kindFolder = folder.appendingPathComponent(kind, isDirectory: true)
            try fm.createDirectory(at: kindFolder, withIntermediateDirectories: true)

            var text = "---\n"
            text += "title: \(yamlQuoted(title))\n"
            text += "kind: \(kind)\n"
            text += "status: \(row.text("status") ?? "open")\n"
            text += "priority: \(row.int("priority") ?? 0)\n"
            text += "created: \(row.text("created_at") ?? "")\n"
            text += "updated: \(row.text("updated_at") ?? "")\n"
            text += "id: \(id)\n---\n\n"
            text += "# \(title)\n\n"
            text += (row.text("body") ?? "") + "\n"
            if let evidence = row.text("evidence"), !evidence.isEmpty {
                text += "\n## Evidence\n\n\(evidence)\n"
            }
            if let question = row.text("question"), !question.isEmpty {
                text += "\n## Question\n\n\(question)\n"
            }

            let fileName = "\(safeFileName(title)) (\(id.prefix(8))).md"
            try Data(text.utf8).write(to: kindFolder.appendingPathComponent(fileName), options: .atomic)
            count += 1
        }

        return count
    }

    // MARK: Export: PDFs with readable names

    nonisolated fileprivate struct PDFCopyJob: Sendable {
        let source: URL
        let fileName: String
    }

    fileprivate static func pdfCopyPlan(library: Library) throws -> [PDFCopyJob] {

        let rows = try library.database.rows(
            """
            SELECT a.rel_path AS rel_path, a.original_name AS original_name, a.label AS label,
                   a.kind AS kind, a.is_primary AS is_primary, i.citation_key AS citation_key
            FROM attachments a JOIN items i ON i.id = a.item_id
            WHERE a.deleted_at IS NULL AND i.deleted_at IS NULL
            ORDER BY i.citation_key, a.is_primary DESC, a.added_at, a.id
            """
        )

        var used = Set<String>()
        var jobs: [PDFCopyJob] = []

        for row in rows {
            guard let relative = row.text("rel_path"),
                  let source = try? library.url(forRelativePath: relative) else { continue }

            let key = safeFileName(row.text("citation_key") ?? "", fallback: "item")
            let original = row.text("original_name") ?? ""
            let ext = (original as NSString).pathExtension.isEmpty
                ? (relative as NSString).pathExtension
                : (original as NSString).pathExtension

            var base = key
            let label = row.text("label") ?? ""
            if row.int("is_primary") != 1 {
                let extra = label.isEmpty ? (row.text("kind") ?? "file") : label
                base += " - " + safeFileName(extra, fallback: "file")
            }

            var candidate = ext.isEmpty ? base : "\(base).\(ext)"
            var n = 2
            while used.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                n += 1
            }
            used.insert(candidate.lowercased())
            jobs.append(PDFCopyJob(source: source, fileName: candidate))
        }

        return jobs
    }

    nonisolated fileprivate static func copyPlannedPDFs(
        _ jobs: [PDFCopyJob],
        into folder: URL,
        diskGuard: DiskGuard
    ) throws -> (copied: Int, warnings: [String]) {

        let fm = FileManager.default
        var copied = 0
        var missing = 0
        var warnings: [String] = []

        if !jobs.isEmpty { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }

        for job in jobs {
            guard fm.fileExists(atPath: job.source.path) else {
                missing += 1
                if missing <= 10 { warnings.append("A file is missing on disk and was not exported: \(job.fileName)") }
                continue
            }
            try diskGuard.ensureRoom(for: fileSize(job.source), at: folder)
            try fm.copyItem(at: job.source, to: folder.appendingPathComponent(job.fileName))
            copied += 1
        }

        if missing > 10 { warnings.append("\(missing - 10) more files were missing on disk.") }
        return (copied, warnings)
    }

    // MARK: Export: README

    fileprivate static func readmeText(
        exportDate: Date,
        tableCount: Int,
        itemCount: Int,
        noteCount: Int,
        pdfCount: Int
    ) -> String {
        """
        ResearchBase export, \(dayStamp(exportDate))
        ==========================================

        This folder is a copy of your whole library in open formats. You can read
        everything in it without ResearchBase, today and in ten years.

        library.json   Every table of the library as plain JSON (\(tableCount) tables).
                       Times are UTC. Ids are UUID text. Attachments point to PDFs by
                       the same file names used in the pdfs/ folder.
        references.bib All \(itemCount) library items as BibTeX, using your citation keys.
        notes/         \(noteCount) notes, findings, gaps, problems and ideas as Markdown,
                       one file each, in a folder per kind.
        pdfs/          \(pdfCount) PDF and attachment files, named after the citation key.
        drafts/        Every draft as a real folder (main.tex, refs.bib, figures/ ...).
                       Open them with any LaTeX editor.
        legacy/        Only present when content from before the library move existed.

        To restore a library from this folder you need a backup (library.sqlite),
        not this export. This export is for reading and for moving to other tools.
        """
    }
}
