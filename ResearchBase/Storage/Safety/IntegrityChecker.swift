//
//  IntegrityChecker.swift
//  ResearchBase
//
//  Owner: Agent 4 · Features: F-48, F-55
//
//  F-48  Integrity check: finds missing PDFs, damaged files, broken links,
//        orphaned files, missing draft folders and database problems.
//        Runs at launch (quick) and weekly (deep).
//  F-55  Self-test and recovery info: a short list of "does this Mac still
//        run everything the library needs?" checks for after a macOS update,
//        plus versions and plain-language rebuild notes.
//
//  READ-ONLY. Nothing here repairs, moves or deletes a user's data.
//  The only writes are small bookkeeping rows in the `meta` table
//  (`last_integrity_at`, `last_integrity_result`, `last_deep_integrity_at`,
//  `last_selftest_at`, `last_selftest_os`). No schema change.
//
//  PUBLIC API
//    Integrity check (F-48)
//      IntegrityChecker.run(on:depth:recordResult:now:) async throws -> IntegrityReport
//      IntegrityChecker.runForLaunch(on:now:) async throws -> IntegrityReport
//          quick check; becomes a deep check when the last deep one is older than a week
//      IntegrityChecker.isDeepCheckDue(in:now:) -> Bool
//      IntegrityChecker.lastRun(in:) -> IntegrityLastRun?
//          for Settings: when it last ran and how it went, without running it again
//      IntegrityChecker.deepCheckInterval            (7 days)
//    Self-test and recovery (F-55)
//      IntegrityChecker.runSelfTest(on:recordResult:) async -> IntegritySelfTestReport
//      IntegrityChecker.macOSChangedSinceLastSelfTest(in:) -> Bool
//      IntegrityChecker.recoveryInfo(for:) -> LibraryRecoveryInfo
//      IntegrityChecker.currentMacOSVersion          (String)
//    Value types
//      IntegrityDepth, IntegritySeverity, IntegrityCategory, IntegrityIssue,
//      IntegrityReport, IntegrityLastRun, IntegrityLastResult,
//      IntegritySelfTestStatus, IntegritySelfTestCheck, IntegritySelfTestReport,
//      LibraryRecoveryInfo, LibraryBackupFileInfo, LibraryTableCount
//
//  Both `run` and `runSelfTest` are async and give the main actor back every
//  few hundred files, so a big library does not freeze the window. Cancel the
//  surrounding Task to stop a check early (`run` then throws CancellationError).
//
//  Uses only finished code: Library, LibraryDatabase, LibraryMigrations.
//

import Foundation
import CryptoKit
import PDFKit
import SQLite3
import Vision

// MARK: - Result types (F-48)

enum IntegrityDepth: Equatable {
    /// Fast enough for every launch: quick_check, foreign keys, file existence and size, links, orphans.
    case quick
    /// Adds the full database check, the search-index check and a SHA-256 of every attachment.
    case deep
}

enum IntegritySeverity: Int, Comparable {
    case info = 0
    case warning = 1
    case error = 2

    static func < (lhs: IntegritySeverity, rhs: IntegritySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum IntegrityCategory: String, CaseIterable {
    case database
    case foreignKeys
    case searchIndex
    case missingFile
    case damagedFile
    case orphanedFile
    case brokenLink
    case draftFolder

    var title: String {
        switch self {
        case .database:     return "Database"
        case .foreignKeys:  return "Broken relationships"
        case .searchIndex:  return "Search index"
        case .missingFile:  return "Missing files"
        case .damagedFile:  return "Changed or damaged files"
        case .orphanedFile: return "Unused files"
        case .brokenLink:   return "Broken links"
        case .draftFolder:  return "Draft folders"
        }
    }
}

struct IntegrityIssue: Identifiable, Equatable {

    /// Stable between runs for the same problem, so a screen can keep its selection.
    let id: String
    let severity: IntegritySeverity
    let category: IntegrityCategory

    /// One plain-language line.
    let title: String
    let detail: String

    /// What the person can do about it. Never promises a button that may not exist.
    let suggestion: String

    let entityType: String?
    let entityID: String?

    /// Relative to the library folder when it is a file.
    let path: String?

    init(
        id: String,
        severity: IntegritySeverity,
        category: IntegrityCategory,
        title: String,
        detail: String,
        suggestion: String = "",
        entityType: String? = nil,
        entityID: String? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.suggestion = suggestion
        self.entityType = entityType
        self.entityID = entityID
        self.path = path
    }
}

struct IntegrityReport {

    let depth: IntegrityDepth
    let startedAt: Date
    let finishedAt: Date

    /// The problems, worst first. At most `IntegrityChecker.maxIssuesPerCategory`
    /// per category are listed; the counts below are always the true totals.
    let issues: [IntegrityIssue]

    let errorCount: Int
    let warningCount: Int
    let infoCount: Int

    /// True number of problems per category (before the list was capped).
    let totals: [IntegrityCategory: Int]

    let attachmentsChecked: Int
    let linksChecked: Int
    let filesOnDisk: Int

    /// No errors. Warnings (unused files, a stale link) do not make the library unhealthy.
    var isHealthy: Bool { errorCount == 0 }

    var isClean: Bool { errorCount == 0 && warningCount == 0 }

    var wasTruncated: Bool {
        totals.values.reduce(0, +) > issues.count
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    func issues(in category: IntegrityCategory) -> [IntegrityIssue] {
        issues.filter { $0.category == category }
    }

    /// One or two sentences for a banner.
    var summary: String {
        if isClean {
            return "No problems found. Checked \(attachmentsChecked) attached files and \(linksChecked) links."
        }

        var parts: [String] = []
        if errorCount > 0 {
            parts.append("\(errorCount) \(errorCount == 1 ? "problem needs" : "problems need") attention")
        }
        if warningCount > 0 {
            parts.append("\(warningCount) \(warningCount == 1 ? "thing is" : "things are") worth a look")
        }
        return parts.joined(separator: " and ") + "."
    }
}

enum IntegrityLastResult: String {
    case ok
    case warnings
    case errors
    case unknown
}

struct IntegrityLastRun: Equatable {
    /// When any check last ran.
    let at: Date?
    let result: IntegrityLastResult
    /// When a deep check last ran.
    let deepAt: Date?
}

// MARK: - Result types (F-55)

enum IntegritySelfTestStatus: Equatable {
    case pass
    case warning
    case fail
}

struct IntegritySelfTestCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let status: IntegritySelfTestStatus
    let detail: String
}

struct LibraryBackupFileInfo: Equatable {
    let name: String
    let bytes: Int64?
    let modified: Date?
}

struct LibraryTableCount: Equatable {
    let table: String
    let count: Int
}

struct LibraryRecoveryInfo {

    // Versions
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let sqliteVersion: String

    // Library
    let libraryPath: String
    let schemaVersionOnDisk: Int?
    let schemaVersionSupported: Int
    let databaseBytes: Int64?
    let walBytes: Int64?
    let createdAt: String?
    let lastBackupAt: String?
    let lastIntegrityAt: String?
    let lastSelfTestAt: String?

    /// Newest first, at most ten.
    let recentBackups: [LibraryBackupFileInfo]

    /// Total rows per main table (trashed rows included).
    let recordCounts: [LibraryTableCount]

    /// Plain-language notes for the day something goes wrong.
    let rebuildNotes: [String]
}

struct IntegritySelfTestReport {

    let ranAt: Date
    let checks: [IntegritySelfTestCheck]
    let recovery: LibraryRecoveryInfo

    /// macOS differed from the last recorded self-test when this one started.
    let macOSChangedSinceLastTest: Bool

    var failedChecks: [IntegritySelfTestCheck] { checks.filter { $0.status == .fail } }
    var warningChecks: [IntegritySelfTestCheck] { checks.filter { $0.status == .warning } }

    var passed: Bool { failedChecks.isEmpty }
    var isAllClear: Bool { failedChecks.isEmpty && warningChecks.isEmpty }

    var summary: String {
        if isAllClear {
            return "Everything the library needs is working on this Mac."
        }
        if passed {
            let n = warningChecks.count
            return "The library works. \(n) \(n == 1 ? "check has a note" : "checks have notes")."
        }
        let n = failedChecks.count
        return "\(n) \(n == 1 ? "check failed" : "checks failed"). Do not edit the library by hand; see the notes below."
    }
}

// MARK: - Checker

enum IntegrityChecker {

    // MARK: Settings

    static let deepCheckInterval: TimeInterval = 7 * 24 * 60 * 60
    static let maxIssuesPerCategory = 500

    private static let metaLastIntegrityAt = "last_integrity_at"
    private static let metaLastIntegrityResult = "last_integrity_result"
    private static let metaLastDeepIntegrityAt = "last_deep_integrity_at"
    private static let metaLastSelfTestAt = "last_selftest_at"
    private static let metaLastSelfTestOS = "last_selftest_os"

    /// Which table each kind of link end lives in (see `links` in the schema).
    private static let linkTables: [(type: String, table: String)] = [
        ("item", "items"),
        ("thought", "thoughts"),
        ("experiment", "experiments"),
        ("draft", "drafts"),
        ("project", "projects"),
        ("task", "tasks"),
        ("review", "reviews"),
        ("collection", "collections")
    ]

    private static let searchTables = ["fts_items", "fts_pdf", "fts_thought", "fts_draft"]

    // MARK: F-48 · Running the check

    /// Runs the integrity check. Never changes user data.
    ///
    /// - Parameter recordResult: writes `last_integrity_at` and `last_integrity_result`
    ///   (and `last_deep_integrity_at` for a deep check) to `meta`.
    static func run(
        on library: Library,
        depth: IntegrityDepth = .quick,
        recordResult: Bool = true,
        now: Date = Date()
    ) async throws -> IntegrityReport {

        let started = Date()
        let collector = Collector()

        try await guarded("database", collector) {
            checkDatabase(library, depth: depth, collector)
        }

        try await guarded("relationships", collector) {
            checkForeignKeys(library, collector)
        }

        if depth == .deep {
            try await guarded("search index", collector) {
                checkSearchIndex(library, collector)
            }
        }

        try await guarded("attachments", collector) {
            try await checkAttachments(library, depth: depth, collector)
        }

        try await guarded("unused files", collector) {
            try await checkOrphanFiles(library, collector)
        }

        try await guarded("links", collector) {
            try await checkLinks(library, collector)
        }

        try await guarded("drafts", collector) {
            try await checkDrafts(library, collector)
        }

        let report = collector.makeReport(depth: depth, startedAt: started, finishedAt: Date())

        if recordResult {
            // Bookkeeping must never turn a finished check into a failure.
            record(report, in: library, at: now)
        }

        return report
    }

    /// What the app should call at launch: quick every time, deep once a week.
    static func runForLaunch(on library: Library, now: Date = Date()) async throws -> IntegrityReport {
        let depth: IntegrityDepth = isDeepCheckDue(in: library, now: now) ? .deep : .quick
        return try await run(on: library, depth: depth, recordResult: true, now: now)
    }

    static func isDeepCheckDue(in library: Library, now: Date = Date()) -> Bool {
        guard
            let text = metaValue(metaLastDeepIntegrityAt, in: library),
            let last = parseISO(text)
        else {
            return true
        }
        return now.timeIntervalSince(last) >= deepCheckInterval
    }

    /// For a status line in Settings. Nil when no check has ever been recorded.
    static func lastRun(in library: Library) -> IntegrityLastRun? {

        guard let text = metaValue(metaLastIntegrityAt, in: library) else { return nil }

        let result = metaValue(metaLastIntegrityResult, in: library)
            .flatMap(IntegrityLastResult.init(rawValue:)) ?? .unknown

        return IntegrityLastRun(
            at: parseISO(text),
            result: result,
            deepAt: metaValue(metaLastDeepIntegrityAt, in: library).flatMap { parseISO($0) }
        )
    }

    // MARK: F-55 · Self-test and recovery info

    static var currentMacOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// True when the macOS version differs from the one recorded by the last self-test
    /// (or no self-test was ever recorded). Lets the app suggest running it.
    static func macOSChangedSinceLastSelfTest(in library: Library) -> Bool {
        guard let recorded = metaValue(metaLastSelfTestOS, in: library) else { return true }
        return recorded != currentMacOSVersion
    }

    /// Runs every self-test check. Does not change user data.
    static func runSelfTest(on library: Library, recordResult: Bool = true) async -> IntegritySelfTestReport {

        let osChanged = macOSChangedSinceLastSelfTest(in: library)
        var checks: [IntegritySelfTestCheck] = []

        checks.append(selfTestSchemaVersion(library))
        checks.append(selfTestTables(library))
        checks.append(selfTestJournalMode(library))
        checks.append(selfTestForeignKeys(library))
        checks.append(selfTestDatabaseWritable(library))
        await Task.yield()
        checks.append(selfTestSearchEngine())
        checks.append(selfTestFolders(library))
        checks.append(selfTestFolderWritable(library))
        checks.append(selfTestFreeSpace(library))
        await Task.yield()
        checks.append(selfTestPDFEngine())
        checks.append(selfTestTextRecognition())
        checks.append(selfTestQuickIntegrity(library))

        let ranAt = Date()

        if recordResult {
            let stamp = Library.nowISO(ranAt)
            writeMeta(metaLastSelfTestAt, stamp, in: library)
            writeMeta(metaLastSelfTestOS, currentMacOSVersion, in: library)
        }

        return IntegritySelfTestReport(
            ranAt: ranAt,
            checks: checks,
            recovery: recoveryInfo(for: library),
            macOSChangedSinceLastTest: osChanged
        )
    }

    /// Versions, sizes, backups and rebuild notes. Reads only.
    static func recoveryInfo(for library: Library) -> LibraryRecoveryInfo {

        let bundle = Bundle.main
        let supported = LibraryMigrations.all.last?.version ?? 0

        let counts: [LibraryTableCount] = [
            "items", "attachments", "creators", "tags", "collections", "thoughts",
            "drafts", "experiments", "links", "projects", "tasks"
        ].compactMap { table in
            guard let count = try? library.database.scalarInt("SELECT COUNT(*) FROM \(table)") else {
                return nil
            }
            return LibraryTableCount(table: table, count: Int(count))
        }

        return LibraryRecoveryInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            macOSVersion: currentMacOSVersion,
            sqliteVersion: String(cString: sqlite3_libversion()),
            libraryPath: library.root.path,
            schemaVersionOnDisk: try? library.schemaVersion,
            schemaVersionSupported: supported,
            databaseBytes: fileSize(library.databaseURL),
            walBytes: fileSize(URL(fileURLWithPath: library.databaseURL.path + "-wal")),
            createdAt: try? library.createdAt,
            lastBackupAt: metaValue("last_backup_at", in: library),
            lastIntegrityAt: metaValue(metaLastIntegrityAt, in: library),
            lastSelfTestAt: metaValue(metaLastSelfTestAt, in: library),
            recentBackups: listBackups(in: library),
            recordCounts: counts,
            rebuildNotes: rebuildNotes(schemaVersion: supported)
        )
    }

    // MARK: - F-48 checks

    // Database file ------------------------------------------------------

    private static func checkDatabase(_ library: Library, depth: IntegrityDepth, _ c: Collector) {

        let pragma = depth == .deep ? "integrity_check" : "quick_check"

        let rows: [SQLRow]
        do {
            rows = try library.database.rows("PRAGMA \(pragma)")
        } catch {
            c.add(IntegrityIssue(
                id: "db|\(pragma)|failed",
                severity: .error,
                category: .database,
                title: "The database could not be checked",
                detail: error.localizedDescription,
                suggestion: "Quit ResearchBase and restore from the newest backup. Keep the current library folder aside; do not delete it."
            ))
            return
        }

        let messages = rows.compactMap { $0.text(pragma) }

        if messages == ["ok"] || messages.isEmpty { return }

        for (index, message) in messages.prefix(50).enumerated() {
            c.add(IntegrityIssue(
                id: "db|\(pragma)|\(index)",
                severity: .error,
                category: .database,
                title: "The database reports damage",
                detail: message,
                suggestion: "Quit ResearchBase and restore from the newest backup. Keep the current library folder aside; do not delete it."
            ))
        }
    }

    // Foreign keys -------------------------------------------------------

    private static func checkForeignKeys(_ library: Library, _ c: Collector) {

        let rows: [SQLRow]
        do {
            rows = try library.database.rows("PRAGMA foreign_key_check")
        } catch {
            c.add(IntegrityIssue(
                id: "fk|failed",
                severity: .error,
                category: .foreignKeys,
                title: "Relationships between records could not be checked",
                detail: error.localizedDescription
            ))
            return
        }

        // One issue per (table, parent), with a count.
        var groups: [String: (table: String, parent: String, count: Int)] = [:]

        for row in rows {
            let table = row.text("table") ?? "unknown"
            let parent = row.text("parent") ?? "unknown"
            let key = "\(table)|\(parent)"
            var group = groups[key] ?? (table: table, parent: parent, count: 0)
            group.count += 1
            groups[key] = group
        }

        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }

            c.add(IntegrityIssue(
                id: "fk|\(key)",
                severity: .error,
                category: .foreignKeys,
                title: "\(group.count) \(group.count == 1 ? "record in" : "records in") \(group.table) point to a missing \(group.parent) record",
                detail: "Table \(group.table) refers to rows of \(group.parent) that no longer exist.",
                suggestion: "Restore from a backup made before the problem appeared."
            ), weight: group.count)
        }
    }

    // Full-text search ---------------------------------------------------

    private static func checkSearchIndex(_ library: Library, _ c: Collector) {

        for name in searchTables {
            do {
                // FTS5's own consistency check. It reads the index and changes nothing.
                try library.database.run("INSERT INTO \(name)(\(name)) VALUES('integrity-check')")
            } catch {
                c.add(IntegrityIssue(
                    id: "fts|\(name)",
                    severity: .warning,
                    category: .searchIndex,
                    title: "The search index \(name) did not pass its check",
                    detail: error.localizedDescription,
                    suggestion: "The search index is built from your records, so it can be rebuilt. No papers or notes are lost."
                ))
            }
        }
    }

    // Attached files -----------------------------------------------------

    private static func checkAttachments(
        _ library: Library,
        depth: IntegrityDepth,
        _ c: Collector
    ) async throws {

        let rows = try library.database.rows(
            """
            SELECT a.id AS id, a.item_id AS item_id, a.kind AS kind, a.label AS label,
                   a.original_name AS original_name, a.rel_path AS rel_path,
                   a.bytes AS bytes, a.sha256 AS sha256, i.title AS title
            FROM attachments a
            LEFT JOIN items i ON i.id = a.item_id
            WHERE a.deleted_at IS NULL
            ORDER BY a.id
            """
        )

        c.attachmentsChecked = rows.count

        let fileManager = FileManager.default
        var processed = 0

        for row in rows {

            processed += 1
            if processed % 100 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }

            let id = row.text("id") ?? ""
            let relPath = row.text("rel_path") ?? ""
            let isPDF = row.text("kind") == "pdf"
            let noun = isPDF ? "PDF" : "Attached file"
            let name = displayName(row)

            let url: URL
            do {
                url = try library.url(forRelativePath: relPath)
            } catch {
                c.add(IntegrityIssue(
                    id: "att|path|\(id)",
                    severity: .error,
                    category: .missingFile,
                    title: "\(noun) has an invalid location",
                    detail: "\(name): the stored location “\(relPath)” is not inside the library folder.",
                    suggestion: "Re-attach the file to the paper.",
                    entityType: "attachment",
                    entityID: id,
                    path: relPath
                ))
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

            guard exists, !isDirectory.boolValue else {
                c.add(IntegrityIssue(
                    id: "att|missing|\(id)",
                    severity: .error,
                    category: .missingFile,
                    title: "\(noun) is missing",
                    detail: "\(name) should be at \(relPath), but the file is not there.",
                    suggestion: "Restore the file from a backup, or attach it to the paper again.",
                    entityType: "attachment",
                    entityID: id,
                    path: relPath
                ))
                continue
            }

            let actualSize = fileSize(url)

            if let expected = row.int("bytes"), let actualSize, actualSize != expected {
                c.add(IntegrityIssue(
                    id: "att|size|\(id)",
                    severity: .error,
                    category: .damagedFile,
                    title: "\(noun) has changed size",
                    detail: "\(name) was \(formatBytes(expected)) when it was added and is now \(formatBytes(actualSize)).",
                    suggestion: "Restore the original file from a backup.",
                    entityType: "attachment",
                    entityID: id,
                    path: relPath
                ))
                continue
            }

            guard depth == .deep, let expectedHash = row.text("sha256")?.lowercased(), !expectedHash.isEmpty else {
                continue
            }

            do {
                let actualHash = try sha256Hex(of: url)
                if actualHash != expectedHash {
                    c.add(IntegrityIssue(
                        id: "att|hash|\(id)",
                        severity: .error,
                        category: .damagedFile,
                        title: "\(noun) content has changed",
                        detail: "\(name) no longer matches the fingerprint taken when it was added.",
                        suggestion: "Restore the original file from a backup.",
                        entityType: "attachment",
                        entityID: id,
                        path: relPath
                    ))
                }
            } catch {
                c.add(IntegrityIssue(
                    id: "att|unreadable|\(id)",
                    severity: .error,
                    category: .damagedFile,
                    title: "\(noun) could not be read",
                    detail: "\(name): \(error.localizedDescription)",
                    suggestion: "Check the file's permissions, or restore it from a backup.",
                    entityType: "attachment",
                    entityID: id,
                    path: relPath
                ))
            }
        }
    }

    // Files nobody uses --------------------------------------------------

    private static func checkOrphanFiles(_ library: Library, _ c: Collector) async throws {

        let filesRoot = library.filesURL.resolvingSymlinksInPath()

        guard FileManager.default.fileExists(atPath: filesRoot.path) else { return }

        // Every attachment row counts, trashed ones too: a trashed file may still be restored.
        var referenced = Set<String>()
        for row in try library.database.rows("SELECT rel_path FROM attachments") {
            if let rel = row.text("rel_path"), let url = try? library.url(forRelativePath: rel) {
                referenced.insert(url.resolvingSymlinksInPath().path)
            }
        }

        let files = listRegularFiles(under: filesRoot)
        c.filesOnDisk = files.count

        var processed = 0
        let prefixLength = filesRoot.path.count + 1

        for file in files {

            processed += 1
            if processed % 200 == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }

            if referenced.contains(file.url.path) { continue }

            let relative = "files/" + String(file.url.path.dropFirst(prefixLength))

            c.add(IntegrityIssue(
                id: "orphan|\(relative)",
                severity: .warning,
                category: .orphanedFile,
                title: "A file in the library is not used by any paper",
                detail: "\(relative) (\(formatBytes(file.bytes))) is stored in the library but no attachment points to it.",
                suggestion: "Keep it if you are unsure. It is safe to delete only if you do not need it.",
                path: relative
            ))
        }
    }

    // Links --------------------------------------------------------------

    private static func checkLinks(_ library: Library, _ c: Collector) async throws {

        c.linksChecked = Int(try library.database.scalarInt("SELECT COUNT(*) FROM links") ?? 0)

        if c.linksChecked == 0 { return }

        // link id -> (row, which ends are missing)
        var broken: [String: (row: SQLRow, ends: Set<String>)] = [:]

        func note(_ row: SQLRow, end: String) {
            let id = row.text("id") ?? ""
            var entry = broken[id] ?? (row: row, ends: Set<String>())
            entry.ends.insert(end)
            broken[id] = entry
        }

        let knownTypes = linkTables.map { "'\($0.type)'" }.joined(separator: ", ")

        // Types the app does not know about.
        let unknown = try library.database.rows(
            """
            SELECT id, from_type, from_id, to_type, to_id, rel FROM links
            WHERE from_type NOT IN (\(knownTypes)) OR to_type NOT IN (\(knownTypes))
            """
        )
        for row in unknown {
            note(row, end: "type")
        }

        // Ends that point at nothing. A trashed record still exists, so its links are fine.
        for entry in linkTables {

            for end in ["from", "to"] {

                let rows = try library.database.rows(
                    """
                    SELECT l.id AS id, l.from_type AS from_type, l.from_id AS from_id,
                           l.to_type AS to_type, l.to_id AS to_id, l.rel AS rel
                    FROM links l
                    WHERE l.\(end)_type = ?
                      AND NOT EXISTS (SELECT 1 FROM \(entry.table) t WHERE t.id = l.\(end)_id)
                    """,
                    [.text(entry.type)]
                )

                for row in rows { note(row, end: end) }

                try Task.checkCancellation()
                await Task.yield()
            }
        }

        for linkID in broken.keys.sorted() {

            guard let entry = broken[linkID] else { continue }

            let row = entry.row
            let from = "\(row.text("from_type") ?? "?") \(shortID(row.text("from_id")))"
            let to = "\(row.text("to_type") ?? "?") \(shortID(row.text("to_id")))"
            let relation = row.text("rel") ?? "related"

            let which: String
            if entry.ends.contains("type") {
                which = "It refers to a kind of record this version of ResearchBase does not know."
            } else if entry.ends == ["from", "to"] {
                which = "Both records are gone."
            } else if entry.ends.contains("from") {
                which = "The starting record is gone."
            } else {
                which = "The record it points to is gone."
            }

            c.add(IntegrityIssue(
                id: "link|\(linkID)",
                severity: .warning,
                category: .brokenLink,
                title: "A link points to something that no longer exists",
                detail: "\(from) → \(to) (\(relation)). \(which)",
                suggestion: "The link can be removed; nothing else depends on it.",
                entityType: "link",
                entityID: linkID
            ))
        }
    }

    // Drafts -------------------------------------------------------------

    private static func checkDrafts(_ library: Library, _ c: Collector) async throws {

        let fileManager = FileManager.default

        let drafts = try library.database.rows(
            "SELECT id, title, folder, main_file, deleted_at FROM drafts ORDER BY id"
        )

        var knownFolderNames = Set<String>()

        for row in drafts {

            let id = row.text("id") ?? ""
            let title = row.text("title") ?? "Untitled draft"
            let folder = row.text("folder") ?? ""
            let mainFile = row.text("main_file") ?? "main.tex"

            if let last = folder.split(separator: "/").last {
                knownFolderNames.insert(String(last))
            }

            // A draft in the trash may have had its folder tidied away; only live drafts must be whole.
            guard row["deleted_at"].isNull else { continue }

            guard let folderURL = try? library.url(forRelativePath: folder) else {
                c.add(IntegrityIssue(
                    id: "draft|path|\(id)",
                    severity: .error,
                    category: .draftFolder,
                    title: "A draft has an invalid folder",
                    detail: "“\(title)” stores the location “\(folder)”, which is not inside the library folder.",
                    entityType: "draft",
                    entityID: id
                ))
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                c.add(IntegrityIssue(
                    id: "draft|folder|\(id)",
                    severity: .error,
                    category: .draftFolder,
                    title: "A draft's folder is missing",
                    detail: "“\(title)” should be in \(folder), but that folder is not there.",
                    suggestion: "Restore the folder from a backup or from one of the draft's saved versions.",
                    entityType: "draft",
                    entityID: id,
                    path: folder
                ))
                continue
            }

            let mainURL = folderURL.appendingPathComponent(mainFile)
            if !fileManager.fileExists(atPath: mainURL.path) {
                c.add(IntegrityIssue(
                    id: "draft|main|\(id)",
                    severity: .warning,
                    category: .draftFolder,
                    title: "A draft's main file is missing",
                    detail: "“\(title)” has no \(mainFile) in its folder.",
                    suggestion: "Restore it from a saved version of the draft or from a backup.",
                    entityType: "draft",
                    entityID: id,
                    path: folder
                ))
            }
        }

        // Saved versions whose zip is gone.
        let snapshots = try library.database.rows(
            "SELECT s.id AS id, s.bundle_path AS bundle_path, d.title AS title FROM draft_snapshots s LEFT JOIN drafts d ON d.id = s.draft_id ORDER BY s.id"
        )

        for (index, row) in snapshots.enumerated() {

            if index % 200 == 199 {
                try Task.checkCancellation()
                await Task.yield()
            }

            let id = row.text("id") ?? ""
            let bundle = row.text("bundle_path") ?? ""

            guard let url = try? library.url(forRelativePath: bundle) else { continue }

            if !fileManager.fileExists(atPath: url.path) {
                c.add(IntegrityIssue(
                    id: "draft|snapshot|\(id)",
                    severity: .warning,
                    category: .draftFolder,
                    title: "A saved version of a draft is missing",
                    detail: "The saved copy of “\(row.text("title") ?? "a draft")” should be at \(bundle).",
                    suggestion: "Restore it from a backup, or ignore it if you no longer need that version.",
                    entityType: "draft_snapshot",
                    entityID: id,
                    path: bundle
                ))
            }
        }

        // Draft folders that no draft owns.
        let draftsRoot = library.draftsURL

        if let entries = try? fileManager.contentsOfDirectory(
            at: draftsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {

                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory == true else { continue }

                let name = entry.lastPathComponent
                if knownFolderNames.contains(name) { continue }

                c.add(IntegrityIssue(
                    id: "draft|orphan|\(name)",
                    severity: .info,
                    category: .draftFolder,
                    title: "A folder in drafts/ does not belong to any draft",
                    detail: "drafts/\(name) has no matching draft in the library.",
                    suggestion: "Keep it if it holds writing you want. Nothing in the app uses it.",
                    path: "drafts/\(name)"
                ))
            }
        }
    }

    // MARK: - F-55 self-test checks

    private static func selfTestSchemaVersion(_ library: Library) -> IntegritySelfTestCheck {

        let supported = LibraryMigrations.all.last?.version ?? 0

        do {
            let onDisk = try library.schemaVersion

            if onDisk == supported {
                return .init(id: "schema", title: "Library format", status: .pass,
                             detail: "Format \(onDisk), the version this app expects.")
            }
            if onDisk > supported {
                return .init(id: "schema", title: "Library format", status: .fail,
                             detail: "The library is format \(onDisk) but this app understands up to \(supported). Update ResearchBase.")
            }
            return .init(id: "schema", title: "Library format", status: .fail,
                         detail: "The library is format \(onDisk) but should be \(supported). It did not finish updating.")
        } catch {
            return .init(id: "schema", title: "Library format", status: .fail, detail: error.localizedDescription)
        }
    }

    private static func selfTestTables(_ library: Library) -> IntegritySelfTestCheck {

        let expected = expectedTableNames()

        do {
            let rows = try library.database.rows("SELECT name FROM sqlite_master WHERE type = 'table'")
            let present = Set(rows.compactMap { $0.text("name") })
            let missing = expected.filter { !present.contains($0) }.sorted()

            if missing.isEmpty {
                return .init(id: "tables", title: "Library tables", status: .pass,
                             detail: "All \(expected.count) tables are present.")
            }
            return .init(id: "tables", title: "Library tables", status: .fail,
                         detail: "Missing: \(missing.joined(separator: ", ")).")
        } catch {
            return .init(id: "tables", title: "Library tables", status: .fail, detail: error.localizedDescription)
        }
    }

    private static func selfTestJournalMode(_ library: Library) -> IntegritySelfTestCheck {

        do {
            let mode = (try library.database.scalarText("PRAGMA journal_mode") ?? "").lowercased()

            if mode == "wal" {
                return .init(id: "wal", title: "Crash-safe writing (WAL)", status: .pass,
                             detail: "Write-ahead logging is on.")
            }
            return .init(id: "wal", title: "Crash-safe writing (WAL)", status: .warning,
                         detail: "The database is in “\(mode)” mode instead of WAL. Closing and reopening the library should fix this.")
        } catch {
            return .init(id: "wal", title: "Crash-safe writing (WAL)", status: .fail, detail: error.localizedDescription)
        }
    }

    private static func selfTestForeignKeys(_ library: Library) -> IntegritySelfTestCheck {

        do {
            let on = try library.database.scalarInt("PRAGMA foreign_keys") ?? 0

            if on == 1 {
                return .init(id: "foreign-keys", title: "Relationship rules", status: .pass,
                             detail: "The database enforces relationships between records.")
            }
            return .init(id: "foreign-keys", title: "Relationship rules", status: .warning,
                         detail: "The database is not enforcing relationships on this connection.")
        } catch {
            return .init(id: "foreign-keys", title: "Relationship rules", status: .fail, detail: error.localizedDescription)
        }
    }

    private static func selfTestDatabaseWritable(_ library: Library) -> IntegritySelfTestCheck {

        do {
            // Takes the write lock and releases it. Writes nothing.
            try library.database.transaction { }
            return .init(id: "db-write", title: "Database accepts changes", status: .pass,
                         detail: "The database can be written to.")
        } catch {
            return .init(id: "db-write", title: "Database accepts changes", status: .fail,
                         detail: "The database could not be locked for writing: \(error.localizedDescription)")
        }
    }

    private static func selfTestSearchEngine() -> IntegritySelfTestCheck {

        do {
            let scratch = try LibraryDatabase.inMemory()
            defer { scratch.close() }

            try scratch.exec(
                "CREATE VIRTUAL TABLE probe USING fts5(text, tokenize='unicode61 remove_diacritics 2')"
            )
            try scratch.run("INSERT INTO probe(text) VALUES (?)", [.text("Café résumé naïve")])

            let hits = try scratch.scalarInt("SELECT COUNT(*) FROM probe WHERE probe MATCH 'cafe'") ?? 0

            if hits == 1 {
                return .init(id: "fts5", title: "Full-text search engine", status: .pass,
                             detail: "SQLite \(String(cString: sqlite3_libversion())) with FTS5 finds accented words.")
            }
            return .init(id: "fts5", title: "Full-text search engine", status: .fail,
                         detail: "FTS5 is present but did not find an accented word. Search may miss results.")
        } catch {
            return .init(id: "fts5", title: "Full-text search engine", status: .fail,
                         detail: "FTS5 is not available: \(error.localizedDescription)")
        }
    }

    private static func selfTestFolders(_ library: Library) -> IntegritySelfTestCheck {

        let missing = Library.subfolderNames.filter { name in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: library.root.appendingPathComponent(name).path,
                isDirectory: &isDirectory
            )
            return !(exists && isDirectory.boolValue)
        }

        if missing.isEmpty {
            return .init(id: "folders", title: "Library folders", status: .pass,
                         detail: "files, inbox, drafts, backups and exports are all there.")
        }
        return .init(id: "folders", title: "Library folders", status: .warning,
                     detail: "Missing: \(missing.joined(separator: ", ")). They are recreated the next time the library opens.")
    }

    private static func selfTestFolderWritable(_ library: Library) -> IntegritySelfTestCheck {

        let probe = library.root.appendingPathComponent(".rb-selftest-\(UUID().uuidString)")

        do {
            let payload = Data("researchbase".utf8)
            try payload.write(to: probe, options: .atomic)
            let back = try Data(contentsOf: probe)
            try FileManager.default.removeItem(at: probe)

            if back == payload {
                return .init(id: "folder-write", title: "Library folder is writable", status: .pass,
                             detail: "A test file was written, read back and removed.")
            }
            return .init(id: "folder-write", title: "Library folder is writable", status: .fail,
                         detail: "A test file was read back differently from what was written.")
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return .init(id: "folder-write", title: "Library folder is writable", status: .fail,
                         detail: "Could not write in the library folder: \(error.localizedDescription)")
        }
    }

    private static func selfTestFreeSpace(_ library: Library) -> IntegritySelfTestCheck {

        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey

        guard
            let values = try? library.root.resourceValues(forKeys: [key]),
            let free = values.volumeAvailableCapacityForImportantUsage
        else {
            return .init(id: "disk", title: "Free disk space", status: .warning,
                         detail: "macOS did not report how much space is free.")
        }

        let text = formatBytes(free)

        if free < 100 * 1_000_000 {
            return .init(id: "disk", title: "Free disk space", status: .fail,
                         detail: "Only \(text) is free. Saving may fail. Free some space first.")
        }
        if free < 1_000_000_000 {
            return .init(id: "disk", title: "Free disk space", status: .warning,
                         detail: "\(text) is free, which is getting low.")
        }
        return .init(id: "disk", title: "Free disk space", status: .pass, detail: "\(text) is free.")
    }

    private static func selfTestPDFEngine() -> IntegritySelfTestCheck {

        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)

        guard
            let data = document.dataRepresentation(),
            let reopened = PDFDocument(data: data),
            reopened.pageCount == 1
        else {
            return .init(id: "pdfkit", title: "PDF engine (PDFKit)", status: .fail,
                         detail: "A test PDF could not be created and opened again. The reader may not work.")
        }

        return .init(id: "pdfkit", title: "PDF engine (PDFKit)", status: .pass,
                     detail: "A test PDF was created and opened again.")
    }

    private static func selfTestTextRecognition() -> IntegritySelfTestCheck {

        do {
            let languages = try VNRecognizeTextRequest().supportedRecognitionLanguages()

            if languages.isEmpty {
                return .init(id: "vision", title: "Text recognition for scanned PDFs", status: .warning,
                             detail: "macOS reports no recognition languages. Scanned PDFs cannot be made searchable.")
            }
            return .init(id: "vision", title: "Text recognition for scanned PDFs", status: .pass,
                         detail: "\(languages.count) recognition languages available.")
        } catch {
            return .init(id: "vision", title: "Text recognition for scanned PDFs", status: .warning,
                         detail: "Text recognition is not available: \(error.localizedDescription)")
        }
    }

    private static func selfTestQuickIntegrity(_ library: Library) -> IntegritySelfTestCheck {

        do {
            let rows = try library.database.rows("PRAGMA quick_check")
            let messages = rows.compactMap { $0.text("quick_check") }

            if messages == ["ok"] || messages.isEmpty {
                return .init(id: "quick-check", title: "Database structure", status: .pass,
                             detail: "SQLite's quick check found no damage.")
            }
            return .init(id: "quick-check", title: "Database structure", status: .fail,
                         detail: messages.prefix(3).joined(separator: " · "))
        } catch {
            return .init(id: "quick-check", title: "Database structure", status: .fail, detail: error.localizedDescription)
        }
    }

    // MARK: - Recovery notes

    private static func rebuildNotes(schemaVersion: Int) -> [String] {
        [
            "Your papers' files live in the files folder inside the library folder, named by their content fingerprint. ResearchBase never rewrites them, so they stay intact even if library.sqlite is damaged.",
            "Backups are in the backups folder. If the database is damaged, quit ResearchBase, keep the damaged library folder aside (do not delete it), and restore from the newest backup that was verified.",
            "library.sqlite travels with its -wal and -shm files. Copy all three together, or quit the app first, so a copy is never half-written.",
            "The search index is built from your records. After a restore or a macOS update it can be rebuilt, so a search problem never means lost data.",
            "After a macOS update, run this self-test. If the SQLite or PDF checks fail, do not edit the library by hand; check for a ResearchBase update first.",
            "Do not move, rename or edit files inside the library folder while the app is open.",
            "This library is format \(schemaVersion). A library made by a newer version of ResearchBase is never opened or changed by an older one."
        ]
    }

    // MARK: - Helpers

    /// Runs one check. A failing check becomes an issue; it never stops the others.
    private static func guarded(
        _ what: String,
        _ collector: Collector,
        _ body: () async throws -> Void
    ) async throws {

        try Task.checkCancellation()

        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            collector.add(IntegrityIssue(
                id: "check|\(what)|failed",
                severity: .error,
                category: .database,
                title: "The \(what) check could not finish",
                detail: error.localizedDescription,
                suggestion: "Run the check again. If it keeps failing, restore from the newest backup."
            ))
        }

        await Task.yield()
    }

    private static func record(_ report: IntegrityReport, in library: Library, at now: Date) {

        let stamp = Library.nowISO(now)
        let result: IntegrityLastResult = report.errorCount > 0 ? .errors : (report.warningCount > 0 ? .warnings : .ok)

        writeMeta(metaLastIntegrityAt, stamp, in: library)
        writeMeta(metaLastIntegrityResult, result.rawValue, in: library)

        if report.depth == .deep {
            writeMeta(metaLastDeepIntegrityAt, stamp, in: library)
        }
    }

    private static func metaValue(_ key: String, in library: Library) -> String? {
        try? library.database.scalarText("SELECT value FROM meta WHERE key = ?", [.text(key)])
    }

    private static func writeMeta(_ key: String, _ value: String, in library: Library) {
        _ = try? library.database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
            [.text(key), .text(value)]
        )
    }

    private static func parseISO(_ text: String) -> Date? {

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func shortID(_ id: String?) -> String {
        guard let id else { return "?" }
        return String(id.prefix(8))
    }

    private static func displayName(_ row: SQLRow) -> String {

        let title = row.text("title") ?? ""
        let label = row.text("label") ?? ""
        let original = row.text("original_name") ?? ""
        let file = !label.isEmpty ? label : original

        switch (title.isEmpty, file.isEmpty) {
        case (false, false): return "“\(title)” (\(file))"
        case (false, true):  return "“\(title)”"
        case (true, false):  return file
        case (true, true):   return "An attachment"
        }
    }

    /// Streams the file, so a large PDF never has to fit in memory.
    private static func sha256Hex(of url: URL) throws -> String {

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Plain loop kept out of async code on purpose (NSEnumerator is not available inside async functions).
    private static func listRegularFiles(under root: URL) -> [(url: URL, bytes: Int64)] {

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [(url: URL, bytes: Int64)] = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            result.append((url.resolvingSymlinksInPath(), Int64(values?.fileSize ?? 0)))
        }

        return result
    }

    private static func listBackups(in library: Library) -> [LibraryBackupFileInfo] {

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: library.backupsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let infos: [LibraryBackupFileInfo] = entries.map { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            let bytes: Int64? = values?.isRegularFile == true ? values?.fileSize.map(Int64.init) : nil
            return LibraryBackupFileInfo(name: url.lastPathComponent, bytes: bytes, modified: values?.contentModificationDate)
        }

        return infos
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .prefix(10)
            .map { $0 }
    }

    /// Table names, read from the version 1 schema text so this list can never drift from it.
    private static func expectedTableNames() -> [String] {

        guard let regex = try? NSRegularExpression(pattern: #"CREATE (?:VIRTUAL )?TABLE (\w+)"#) else {
            return []
        }

        let text = LibrarySchemaV1.sql
        let range = NSRange(text.startIndex..., in: text)

        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Collector

    private final class Collector {

        var attachmentsChecked = 0
        var linksChecked = 0
        var filesOnDisk = 0

        private var issues: [IntegrityIssue] = []
        private var listedCounts: [IntegrityCategory: Int] = [:]
        private var totals: [IntegrityCategory: Int] = [:]
        private var errors = 0
        private var warnings = 0
        private var infos = 0

        /// `weight` lets one issue stand for several problems (a count of broken rows).
        func add(_ issue: IntegrityIssue, weight: Int = 1) {

            totals[issue.category, default: 0] += weight

            switch issue.severity {
            case .error:   errors += weight
            case .warning: warnings += weight
            case .info:    infos += weight
            }

            let listed = listedCounts[issue.category, default: 0]
            if listed < IntegrityChecker.maxIssuesPerCategory {
                issues.append(issue)
                listedCounts[issue.category] = listed + 1
            }
        }

        func makeReport(depth: IntegrityDepth, startedAt: Date, finishedAt: Date) -> IntegrityReport {

            let sorted = issues.enumerated().sorted { lhs, rhs in
                if lhs.element.severity != rhs.element.severity {
                    return lhs.element.severity > rhs.element.severity
                }
                return lhs.offset < rhs.offset
            }.map { $0.element }

            return IntegrityReport(
                depth: depth,
                startedAt: startedAt,
                finishedAt: finishedAt,
                issues: sorted,
                errorCount: errors,
                warningCount: warnings,
                infoCount: infos,
                totals: totals,
                attachmentsChecked: attachmentsChecked,
                linksChecked: linksChecked,
                filesOnDisk: filesOnDisk
            )
        }
    }
}
