//
//  SwiftDataToLibraryMigrator.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 21/10/26.
//


//
//  SwiftDataToLibraryMigrator.swift
//  ResearchBase
//
//  Owner: Agent 28 · Features: F-05 (one-time migration wizard)
//
//  Copies everything in the old SwiftData store into the new SQLite
//  library, checks that the counts match, and records that the old data
//  is now read-only for 90 days. It never changes or deletes the old
//  data, and it never hard-deletes anything.
//
//  The wizard steps in researchbase.html map to these calls:
//
//      1. Back up   backUp(context:)    calls PreChangeBackup.make FIRST
//      2. Copy      copy(_:backup:)     files first, then ONE transaction
//      3. Check     check(_:)           counts, field values, PDF fingerprints
//      4. Switch    switchToNewLibrary(report:)
//
//  PUBLIC API
//    SwiftDataToLibraryMigrator(model: LibraryModel, clock:)
//    static summarize(_ capture) -> LegacySummary      "214 papers, 61 notes ..."
//    static needsMigration(summary:status:) -> Bool
//    status() throws -> Status                         state, dates, keep-until
//    backUp(context:profile:directory:) async throws -> PreChangeBackupResult
//    copy(_ capture, backup:, progress:) async throws -> CopyResult
//    check(_ capture, pdfSampleSize:) throws -> Report  rows for the "Check" table
//    switchToNewLibrary(report:) throws
//    runThroughCheck(context:profile:backupDirectory:progress:) async throws -> Report
//    Types: LegacySummary, State, Status, Progress, CheckRow, KeyChange,
//           CopyResult, Report, MigrationError
//
//  How the old data is read
//    The migrator reads only `WorkspaceSnapshot.Capture` (the plain,
//    Codable copy of SwiftData that backup already uses). It never
//    touches the @Model classes. `runThroughCheck` makes the capture.
//
//  Rules this file follows (playbook section 1, AGENTS.md section 4)
//    * Schema is frozen. Where the old data has a field the new tables
//      have no column for, the text is folded into a readable Markdown
//      section, and anything else is kept in the `changes` table
//      (action "import", field "legacy") and listed in `Report.warnings`.
//    * Old UUIDs are kept, so links and citation keys still point at the
//      same records.
//    * Safe to run twice: rows that already exist are skipped, never
//      overwritten. After the switch, `copy` refuses to run.
//    * All-or-nothing: PDFs are copied first (content-addressed, so
//      re-using them is harmless), then every record goes in ONE
//      transaction. If anything fails the database is unchanged, and the
//      files and draft folders this run created are removed again.
//    * No FTS rows are written here. SearchService (Agent 14) owns the
//      full-text index and must be asked to rebuild it after the switch.
//

import Foundation
import CryptoKit
import SwiftData

final class SwiftDataToLibraryMigrator {

    // MARK: - Constants

    /// The old data stays read-only for this many days after the switch.
    static let keepLegacyDays = 90

    /// Every `meta` key this file writes starts with this.
    static let metaPrefix = "swiftdata_migration_"

    /// Used in the backup's file name.
    static let backupReason = "storage migration"

    // MARK: - State

    let model: LibraryModel
    private let clock: () -> Date

    init(model: LibraryModel, clock: @escaping () -> Date = { Date() }) {
        self.model = model
        self.clock = clock
    }

    // MARK: - Public types

    /// What the "Old data found" card shows.
    struct LegacySummary: Equatable {
        let papers: Int
        let notes: Int
        /// Findings, gaps, problems and ideas.
        let otherThoughts: Int
        let experiments: Int
        let drafts: Int
        let pdfFiles: Int
        let totalRecords: Int

        var isEmpty: Bool { totalRecords == 0 }

        /// "214 papers, 61 notes, 9 experiments, 3 drafts"
        var sentence: String {
            var parts: [String] = []
            func add(_ count: Int, _ one: String, _ many: String) {
                if count > 0 { parts.append("\(count) \(count == 1 ? one : many)") }
            }
            add(papers, "paper", "papers")
            add(notes, "note", "notes")
            add(otherThoughts, "finding, gap, problem or idea", "findings, gaps, problems and ideas")
            add(experiments, "experiment", "experiments")
            add(drafts, "draft", "drafts")
            return parts.joined(separator: ", ")
        }
    }

    enum State: String, Equatable {
        case notStarted = "not_started"
        case copied
        case verified
        case switched
    }

    /// Where the migration stands, read from the library's `meta` table.
    struct Status: Equatable {
        let state: State
        let copiedAt: String?
        let verifiedAt: String?
        let switchedAt: String?
        let keepLegacyUntil: String?
        let backupPath: String?

        /// True once the switch is done. The app must not write to the old store any more.
        var legacyIsReadOnly: Bool { state == .switched }

        /// Whole days left in the 90-day window, or nil before the switch.
        func legacyDaysLeft(now: Date = Date()) -> Int? {
            guard let text = keepLegacyUntil,
                  let until = SwiftDataToLibraryMigrator.parseISO(text) else { return nil }
            let seconds = until.timeIntervalSince(now)
            return max(0, Int((seconds / 86_400).rounded(.up)))
        }
    }

    enum Phase: String, Equatable {
        case planning, copyingFiles, writingRecords, checking
    }

    struct Progress: Equatable {
        let phase: Phase
        let done: Int
        let total: Int
    }

    /// One line of the Check table (Kind / Old / New).
    struct CheckRow: Equatable {

        enum RowStatus: Equatable {
            /// Old and new are the same.
            case match
            /// New is what it should be, and it differs from old for a stated reason (see `note`).
            case explained
            /// New is not what it should be. The switch is blocked.
            case mismatch
        }

        let label: String
        let old: Int
        /// What the new library should hold, after the skips listed in `note`.
        let expected: Int
        let new: Int
        let note: String

        var status: RowStatus {
            if new != expected { return .mismatch }
            return old == new ? .match : .explained
        }
    }

    /// A citation key that had to change (it was empty-looking, invalid, or already taken).
    struct KeyChange: Equatable {
        let paperID: String
        let title: String
        let oldKey: String
        let newKey: String
    }

    struct CopyResult: Equatable {
        /// New rows written, by kind: "paper", "note", "finding", "gap", "problem", "idea",
        /// "review", "theme", "experiment", "run", "metric", "baseline", "draft",
        /// "submission", "project", "task", "annotation", "pdf", "link".
        var inserted: [String: Int]
        /// Rows that were already in the library and were left alone.
        var alreadyPresent: Int
        /// PDF files newly written into files/.
        var pdfFilesStored: Int
        var warnings: [String]
        var keyChanges: [KeyChange]

        var totalInserted: Int { inserted.values.reduce(0, +) }
    }

    struct Report {
        let rows: [CheckRow]
        /// Field-by-field differences between the old data and what is stored (first 50).
        let contentProblems: [String]
        let pdfSampleSize: Int
        let pdfSampleMatched: Int
        /// Things the person should read before switching.
        let warnings: [String]
        let keyChanges: [KeyChange]

        var isSafeToSwitch: Bool {
            rows.allSatisfy { $0.status != .mismatch }
                && contentProblems.isEmpty
                && pdfSampleMatched == pdfSampleSize
        }

        /// Plain words for why the switch is blocked, or nil when it is not.
        var blockingReason: String? {
            if let row = rows.first(where: { $0.status == .mismatch }) {
                return "“\(row.label)” does not match: expected \(row.expected) in the new library, found \(row.new)."
            }
            if let problem = contentProblems.first {
                return problem
            }
            if pdfSampleMatched != pdfSampleSize {
                return "\(pdfSampleSize - pdfSampleMatched) of \(pdfSampleSize) sampled PDFs did not match their fingerprint."
            }
            return nil
        }
    }

    enum MigrationError: LocalizedError, Equatable {
        case backupMissing
        case backupOutOfDate
        case alreadySwitched
        case nothingCopied
        case notSafeToSwitch(String)
        case pdfUnreadable(String)
        case pdfChangedWhileCopying(String)

        var errorDescription: String? {
            switch self {
            case .backupMissing:
                return "The safety backup is missing, so nothing was changed. Back up again."
            case .backupOutOfDate:
                return "Your data changed after the backup was made, so nothing was changed. Back up again."
            case .alreadySwitched:
                return "The move to the new library is already done. Nothing was changed."
            case .nothingCopied:
                return "Nothing has been copied yet, so there is nothing to switch to."
            case .notSafeToSwitch(let reason):
                return "The new library is not ready to switch to. \(reason)"
            case .pdfUnreadable(let title):
                return "The PDF for “\(title)” could not be read, so nothing was changed. Locate or remove that PDF, then try again."
            case .pdfChangedWhileCopying(let title):
                return "The PDF for “\(title)” changed while it was being copied, so nothing was changed. Try again."
            }
        }
    }

    // MARK: - Before the wizard

    /// Counts for the "Old data found" card.
    static func summarize(_ capture: WorkspaceSnapshot.Capture) -> LegacySummary {
        let s = capture.snapshot
        return LegacySummary(
            papers: s.papers.count,
            notes: s.notes.count,
            otherThoughts: s.findings.count + s.gaps.count + s.problems.count + s.ideas.count,
            experiments: s.experiments.count,
            drafts: s.writingDocuments.count,
            pdfFiles: capture.pdfSources.count,
            totalRecords: s.totalRecordCount
        )
    }

    /// The card is shown when there is old data and the switch has not happened.
    static func needsMigration(summary: LegacySummary, status: Status) -> Bool {
        !summary.isEmpty && status.state != .switched
    }

    /// Where the migration stands (reads `meta`).
    func status() throws -> Status {
        let rows = try model.database.rows("SELECT key, value FROM meta")
        var values: [String: String] = [:]
        for row in rows {
            if let key = row.text("key"), let value = row.text("value"), key.hasPrefix(Self.metaPrefix) {
                values[String(key.dropFirst(Self.metaPrefix.count))] = value
            }
        }
        return Status(
            state: State(rawValue: values["state"] ?? "") ?? .notStarted,
            copiedAt: values["copied_at"],
            verifiedAt: values["verified_at"],
            switchedAt: values["switched_at"],
            keepLegacyUntil: values["keep_legacy_until"],
            backupPath: values["backup_path"]
        )
    }

    // MARK: - Step 1: Back up

    /// Makes and verifies a full backup of the OLD data. `copy` will not run without its result.
    func backUp(
        context: ModelContext,
        profile: ProfileStore? = nil,
        directory: URL? = nil
    ) async throws -> PreChangeBackupResult {
        try await PreChangeBackup.make(
            reason: Self.backupReason,
            context: context,
            profile: profile,
            directory: directory
        )
    }

    // MARK: - Step 2: Copy

    /// Copies the old data into the library.
    ///
    /// - `backup`: the result of `backUp`. It must still be on disk and must describe exactly the
    ///   data in `capture`; otherwise nothing is changed.
    /// - Safe to call again: records that are already there are skipped, not overwritten.
    func copy(
        _ capture: WorkspaceSnapshot.Capture,
        backup: PreChangeBackupResult,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> CopyResult {

        guard FileManager.default.fileExists(atPath: backup.packageURL.path) else {
            throw MigrationError.backupMissing
        }
        guard backup.entityCounts == capture.snapshot.entityCounts else {
            throw MigrationError.backupOutOfDate
        }
        if try status().state == .switched {
            throw MigrationError.alreadySwitched
        }

        progress?(Progress(phase: .planning, done: 0, total: 1))
        let existing = try loadExisting()
        let plan = Self.makePlan(capture, existing: existing)
        progress?(Progress(phase: .planning, done: 1, total: 1))

        // Files first, outside the transaction. They are named by fingerprint, so a file that was
        // copied by an earlier or failed run is simply reused.
        var createdPaths: [URL] = []
        let staged = try await stagePDFs(capture, plan: plan, created: &createdPaths, progress: progress)
        let pdfFilesStored = createdPaths.count

        // Records second: all or nothing.
        var outcome = ApplyOutcome()
        do {
            try model.inSafetyBatch {
                try applyPlan(plan, staged: staged, backup: backup, outcome: &outcome, created: &createdPaths, progress: progress)
            }
        } catch {
            // The database rolled back. Remove what this run put on disk.
            for url in createdPaths.reversed() {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        return CopyResult(
            inserted: outcome.inserted,
            alreadyPresent: outcome.alreadyPresent,
            pdfFilesStored: pdfFilesStored,
            warnings: plan.warnings + outcome.warnings,
            keyChanges: plan.keyChanges
        )
    }

    // MARK: - Step 3: Check

    /// Compares the old data with the library. Writes nothing except, when everything is fine,
    /// the "verified" mark in `meta`.
    func check(
        _ capture: WorkspaceSnapshot.Capture,
        pdfSampleSize: Int = 20,
        progress: ((Progress) -> Void)? = nil
    ) throws -> Report {

        progress?(Progress(phase: .checking, done: 0, total: 1))

        let existing = try loadExisting()
        let plan = Self.makePlan(capture, existing: existing)
        let old = plan.oldCounts

        var rows: [CheckRow] = []

        func addRow(_ label: String, groups: [String], oldGroups: [String]? = nil) throws {
            let oldCount = (oldGroups ?? groups).reduce(0) { $0 + (old[$1] ?? 0) }
            let planned = plan.rows.filter { groups.contains($0.group) }
            var present = 0
            for row in planned {
                if try exists(row.table, id: row.id) { present += 1 }
            }
            rows.append(CheckRow(
                label: label, old: oldCount, expected: planned.count, new: present,
                note: plan.skipNote(groups: groups)
            ))
        }

        try addRow("Papers", groups: ["paper"])

        // Authors and tags live in their own tables.
        var authorsNew = 0
        var tagsNew = 0
        for row in plan.rows where row.group == "paper" {
            authorsNew += Int(try model.database.scalarInt(
                "SELECT COUNT(*) FROM item_creators WHERE item_id = ?", [.text(row.id)]) ?? 0)
            tagsNew += Int(try model.database.scalarInt(
                "SELECT COUNT(*) FROM item_tags WHERE item_id = ?", [.text(row.id)]) ?? 0)
        }
        rows.append(CheckRow(label: "Authors on papers", old: plan.authorCount, expected: plan.authorCount, new: authorsNew, note: ""))
        rows.append(CheckRow(label: "Tags on papers", old: plan.tagCount, expected: plan.tagCount, new: tagsNew, note: ""))

        // PDFs, counted per paper.
        var papersWithPDF = Set<UUID>()
        for source in capture.pdfSources { papersWithPDF.insert(source.paperID) }
        var pdfNew = 0
        for paperID in papersWithPDF {
            let count = try model.database.scalarInt(
                "SELECT COUNT(*) FROM attachments WHERE item_id = ? AND kind = 'pdf' AND deleted_at IS NULL",
                [.text(paperID.uuidString)]) ?? 0
            if count > 0 { pdfNew += 1 }
        }
        rows.append(CheckRow(
            label: "PDF files (by fingerprint)", old: papersWithPDF.count, expected: papersWithPDF.count,
            new: pdfNew, note: ""))

        try addRow("PDF highlights", groups: ["annotation"])
        try addRow("Notes, findings, gaps, problems, ideas", groups: ["note", "finding", "gap", "problem", "idea"])
        try addRow("Literature reviews", groups: ["review"])
        try addRow("Review themes", groups: ["theme"])

        // Comparison entries become cells; count the (review, paper) pairs.
        var pairsNew = 0
        for pair in plan.comparisonPairs {
            let found = try model.database.scalarInt(
                "SELECT 1 FROM review_cells WHERE review_id = ? AND item_id = ? LIMIT 1",
                [.text(pair.reviewID), .text(pair.itemID)])
            if found != nil { pairsNew += 1 }
        }
        rows.append(CheckRow(
            label: "Comparison entries", old: old["comparison"] ?? 0, expected: plan.comparisonPairs.count,
            new: pairsNew, note: plan.skipNote(groups: ["comparison"])))

        try addRow("Experiments", groups: ["experiment"])
        try addRow("Experiment runs", groups: ["run"])
        try addRow("Run metrics and baselines", groups: ["metric", "baseline"])
        try addRow("Writing documents", groups: ["draft"])

        // Sections live inside each draft's main.tex.
        var sectionsNew = 0
        var folderProblems: [String] = []
        for draft in plan.drafts {
            let mainFile = try? model.library.url(forRelativePath: draft.folder + "/" + draft.mainFile)
            if let mainFile, FileManager.default.fileExists(atPath: mainFile.path) {
                sectionsNew += draft.sectionCount
            } else {
                folderProblems.append("The draft “\(draft.title)” has no \(draft.mainFile) in its folder.")
            }
        }
        rows.append(CheckRow(
            label: "Writing sections", old: old["section"] ?? 0, expected: plan.sectionsPlanned,
            new: sectionsNew, note: plan.skipNote(groups: ["section"])))

        try addRow("Projects", groups: ["project"])
        try addRow("Tasks", groups: ["task"])

        var linksNew = 0
        for link in plan.links {
            if try linkExists(link) { linksNew += 1 }
        }
        rows.append(CheckRow(
            label: "Links between items", old: plan.edgesOld, expected: plan.links.count,
            new: linksNew, note: plan.linkNote))

        // Field-by-field: every value that was written must still be what the old data says.
        var problems = folderProblems
        for row in plan.rows {
            guard let found = try model.database.rows(
                "SELECT * FROM \(row.table) WHERE id = ?", [.text(row.id)]
            ).first else { continue }   // a missing row is already a count mismatch

            for (name, expected) in row.columns where found[name] != expected {
                problems.append("The \(row.group) “\(row.title)” differs from the old data in “\(name)”.")
                break
            }
            if problems.count >= 50 { break }
        }

        // Re-read a sample of PDFs and compare fingerprints (old file, stored file, recorded value).
        let sample = capture.pdfSources
            .sorted { $0.paperID.uuidString < $1.paperID.uuidString }
            .prefix(max(0, pdfSampleSize))
        var matched = 0
        for source in sample {
            let stored = try model.database.rows(
                """
                SELECT sha256, rel_path FROM attachments
                WHERE item_id = ? AND kind = 'pdf' AND deleted_at IS NULL
                ORDER BY is_primary DESC, added_at, id LIMIT 1
                """,
                [.text(source.paperID.uuidString)]
            ).first
            guard let recorded = stored?.text("sha256"), let relative = stored?.text("rel_path") else { continue }
            let storedURL = try model.library.url(forRelativePath: relative)
            if let before = try? AttachmentStore.sha256Hex(of: source.sourceURL),
               let after = try? AttachmentStore.sha256Hex(of: storedURL),
               before == after, after == recorded {
                matched += 1
            }
        }

        let report = Report(
            rows: rows,
            contentProblems: Array(problems.prefix(50)),
            pdfSampleSize: sample.count,
            pdfSampleMatched: matched,
            warnings: plan.warnings,
            keyChanges: plan.keyChanges
        )

        if report.isSafeToSwitch {
            let current = try status().state
            if current == .copied || current == .verified {
                try model.database.transaction {
                    try setMeta("state", State.verified.rawValue)
                    try setMeta("verified_at", Library.nowISO(clock()))
                }
            }
        }

        progress?(Progress(phase: .checking, done: 1, total: 1))
        return report
    }

    // MARK: - Step 4: Switch

    /// Records that the new library is now the one in use and that the old data is read-only for
    /// 90 days. Refuses unless the check passed. Calling it again after the switch does nothing.
    func switchToNewLibrary(report: Report) throws {

        let current = try status()
        if current.state == .switched { return }
        if current.state == .notStarted { throw MigrationError.nothingCopied }
        guard report.isSafeToSwitch, current.state == .verified else {
            throw MigrationError.notSafeToSwitch(
                report.blockingReason ?? "Run the check again first.")
        }

        let now = clock()
        let until = now.addingTimeInterval(TimeInterval(Self.keepLegacyDays) * 86_400)

        try model.database.transaction {
            try setMeta("state", State.switched.rawValue)
            try setMeta("switched_at", Library.nowISO(now))
            try setMeta("keep_legacy_until", Library.nowISO(until))
        }
    }

    // MARK: - Steps 1 to 3 in one call

    /// Back up, copy and check. Stops before the switch, which is the person's choice.
    func runThroughCheck(
        context: ModelContext,
        profile: ProfileStore? = nil,
        backupDirectory: URL? = nil,
        progress: ((Progress) -> Void)? = nil
    ) async throws -> Report {
        let backup = try await backUp(context: context, profile: profile, directory: backupDirectory)
        let capture = try WorkspaceSnapshot.capture(from: context)
        _ = try await copy(capture, backup: backup, progress: progress)
        return try check(capture, progress: progress)
    }

    // MARK: - Reading what is already in the library

    private struct Existing {
        /// Citation key of every item already in the library (any state), by item id.
        var keysByID: [String: String]

        var lowerKeys: Set<String> {
            Set(keysByID.values.map { $0.lowercased() })
        }
    }

    private func loadExisting() throws -> Existing {
        var keys: [String: String] = [:]
        for row in try model.database.rows("SELECT id, citation_key FROM items") {
            if let id = row.text("id"), let key = row.text("citation_key") { keys[id] = key }
        }
        return Existing(keysByID: keys)
    }

    private func exists(_ table: String, id: String) throws -> Bool {
        // `table` always comes from this file's fixed list, never from user text.
        try model.database.scalarInt("SELECT 1 FROM \(table) WHERE id = ?", [.text(id)]) != nil
    }

    private func linkExists(_ link: PlannedLink) throws -> Bool {
        try model.database.scalarInt(
            """
            SELECT 1 FROM links
            WHERE from_type = ? AND from_id = ? AND to_type = ? AND to_id = ? AND rel = ?
            """,
            [.text(link.fromType), .text(link.fromID), .text(link.toType), .text(link.toID), .text(link.rel)]
        ) != nil
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try model.database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
            [.text(Self.metaPrefix + key), .text(value)]
        )
    }

    // MARK: - Copying PDFs (outside the transaction)

    private struct StagedPDF {
        let paperID: String
        let sha256: String
        let relativePath: String
        let bytes: Int64
        let originalName: String
        let addedAt: String
    }

    private func stagePDFs(
        _ capture: WorkspaceSnapshot.Capture,
        plan: Plan,
        created: inout [URL],
        progress: ((Progress) -> Void)?
    ) async throws -> [StagedPDF] {

        let sources = capture.pdfSources.sorted { $0.paperID.uuidString < $1.paperID.uuidString }
        var staged: [StagedPDF] = []
        var confirmed = Set<String>()   // relative paths that are on disk and verified

        for (index, source) in sources.enumerated() {

            let paperID = source.paperID.uuidString
            let title = plan.paperTitles[paperID] ?? "a paper"

            let sha: String
            do {
                sha = try AttachmentStore.sha256Hex(of: source.sourceURL)
            } catch {
                throw MigrationError.pdfUnreadable(title)
            }

            let relative = AttachmentStore.relativePath(
                sha256: sha, fileExtension: source.sourceURL.pathExtension.lowercased())

            if !confirmed.contains(relative) {
                if try storeFile(source.sourceURL, relative: relative, sha256: sha, title: title) {
                    created.append(try model.library.url(forRelativePath: relative))
                }
                confirmed.insert(relative)
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: source.sourceURL.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            staged.append(StagedPDF(
                paperID: paperID,
                sha256: sha,
                relativePath: relative,
                bytes: bytes,
                originalName: source.sourceURL.lastPathComponent,
                addedAt: plan.paperAddedAt[paperID] ?? Library.nowISO(clock())
            ))

            progress?(Progress(phase: .copyingFiles, done: index + 1, total: sources.count))
            await Task.yield()
        }

        return staged
    }

    /// Puts one file in files/ unless a correct copy is already there. True when it wrote a file.
    private func storeFile(_ source: URL, relative: String, sha256: String, title: String) throws -> Bool {

        let fileManager = FileManager.default
        let destination = try model.library.url(forRelativePath: relative)

        if fileManager.fileExists(atPath: destination.path) {
            guard (try? AttachmentStore.sha256Hex(of: destination)) == sha256 else {
                throw ModelError.storedFileDamaged(relative)
            }
            return false
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")

        do {
            try fileManager.copyItem(at: source, to: temporary)
            guard try AttachmentStore.sha256Hex(of: temporary) == sha256 else {
                throw MigrationError.pdfChangedWhileCopying(title)
            }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        return true
    }

    // MARK: - Writing the records (one transaction)

    private struct ApplyOutcome {
        var inserted: [String: Int] = [:]
        var alreadyPresent = 0
        var warnings: [String] = []

        mutating func bump(_ group: String) {
            inserted[group, default: 0] += 1
        }
    }

    private func applyPlan(
        _ plan: Plan,
        staged: [StagedPDF],
        backup: PreChangeBackupResult,
        outcome: inout ApplyOutcome,
        created: inout [URL],
        progress: ((Progress) -> Void)?
    ) throws {

        var newDraftIDs = Set<String>()
        var step = 0
        let totalSteps = plan.rows.count + staged.count + plan.links.count

        // 1. Records, in an order that keeps every foreign key satisfied.
        for row in plan.rows {

            step += 1
            if step % 25 == 0 {
                progress?(Progress(phase: .writingRecords, done: step, total: totalSteps))
            }

            // Annotations need their attachment, so they come after the PDFs.
            if row.group == "annotation" { continue }

            if try exists(row.table, id: row.id) {
                outcome.alreadyPresent += 1
                continue
            }

            try insert(row)
            outcome.bump(row.group)
            try model.record(row.entityType, row.id, .importRecord, field: "legacy", old: nil, new: row.legacy ?? Self.sourceMark)

            if row.group == "paper", let extras = plan.extras[row.id] {
                try model.creators.setCreators(itemID: row.id, extras.creators)
                for name in extras.tags {
                    let tag = try model.tags.findOrCreate(name: name)
                    try model.tags.assign(tagID: tag.id, to: row.id)
                }
            }
            if row.group == "draft" { newDraftIDs.insert(row.id) }
        }

        // 2. PDFs: one primary attachment per paper, pointing at the file already in files/.
        for pdf in staged {

            step += 1
            let known = try model.database.scalarInt(
                "SELECT 1 FROM attachments WHERE item_id = ? AND sha256 = ?",
                [.text(pdf.paperID), .text(pdf.sha256)])
            if known != nil {
                outcome.alreadyPresent += 1
                continue
            }

            let id = Self.stableID("attachment|\(pdf.paperID)|\(pdf.sha256)")
            let hasPrimary = try model.database.scalarInt(
                "SELECT 1 FROM attachments WHERE item_id = ? AND is_primary = 1 AND deleted_at IS NULL",
                [.text(pdf.paperID)]) != nil

            try model.database.run(
                """
                INSERT INTO attachments (id, item_id, kind, is_primary, label, sha256, rel_path, original_name, bytes, added_at)
                VALUES (?, ?, 'pdf', ?, '', ?, ?, ?, ?, ?)
                """,
                [.text(id), .text(pdf.paperID), .int(hasPrimary ? 0 : 1), .text(pdf.sha256),
                 .text(pdf.relativePath), .text(pdf.originalName), .int(pdf.bytes), .text(pdf.addedAt)]
            )
            try model.record("attachment", id, .importRecord, field: "file", old: nil, new: pdf.relativePath)
            outcome.bump("pdf")
        }

        // 3. Review columns and comparison cells.
        for column in plan.columns {
            if try exists("review_columns", id: column.id) { continue }
            try model.database.run(
                "INSERT INTO review_columns (id, review_id, name, position) VALUES (?, ?, ?, ?)",
                [.text(column.id), .text(column.reviewID), .text(column.name), .int(Int64(column.position))]
            )
        }
        for cell in plan.cells {
            let known = try model.database.scalarInt(
                "SELECT 1 FROM review_cells WHERE review_id = ? AND item_id = ? AND column_id = ?",
                [.text(cell.reviewID), .text(cell.itemID), .text(cell.columnID)])
            if known != nil { continue }
            try model.database.run(
                "INSERT INTO review_cells (review_id, item_id, column_id, value) VALUES (?, ?, ?, ?)",
                [.text(cell.reviewID), .text(cell.itemID), .text(cell.columnID), .text(cell.value)]
            )
        }

        // 4. Highlights, attached to the paper's PDF.
        for row in plan.rows where row.group == "annotation" {

            if try exists(row.table, id: row.id) {
                outcome.alreadyPresent += 1
                continue
            }
            guard let attachmentID = try model.database.scalarText(
                """
                SELECT id FROM attachments
                WHERE item_id = ? AND kind = 'pdf' AND deleted_at IS NULL
                ORDER BY is_primary DESC, added_at, id LIMIT 1
                """,
                [.text(row.ownerID)]
            ) else {
                // The check step reports this as a count mismatch, so it cannot go unnoticed.
                outcome.warnings.append("A highlight on “\(row.title)” could not be attached to a PDF.")
                continue
            }

            var placed = row
            placed.insertOnly = [("attachment_id", .text(attachmentID))]
            try insert(placed)
            outcome.bump("annotation")
        }

        // 5. Links.
        for link in plan.links {
            step += 1
            if try linkExists(link) {
                outcome.alreadyPresent += 1
                continue
            }
            try model.database.run(
                """
                INSERT INTO links (id, from_type, from_id, to_type, to_id, rel, note, created_at)
                VALUES (?, ?, ?, ?, ?, ?, '', ?)
                """,
                [.text(link.id), .text(link.fromType), .text(link.fromID), .text(link.toType),
                 .text(link.toID), .text(link.rel), .text(link.createdAt)]
            )
            outcome.bump("link")
        }

        // 6. Draft folders (the text of a draft lives in real files).
        for draft in plan.drafts where newDraftIDs.contains(draft.id) {
            try writeDraftFiles(draft, created: &created, warnings: &outcome.warnings)
        }

        // 7. Remember where the migration stands.
        let counts = LibraryModel.json(backup.entityCounts)
        try setMeta("state", State.copied.rawValue)
        try setMeta("copied_at", Library.nowISO(clock()))
        try setMeta("backup_path", backup.packageURL.path)
        try setMeta("old_counts", counts)
        progress?(Progress(phase: .writingRecords, done: totalSteps, total: totalSteps))
    }

    private static let sourceMark = "{\"source\":\"swiftdata\"}"

    private func insert(_ row: PlannedRow) throws {
        let all = row.columns + row.insertOnly
        let names = all.map { $0.0 }.joined(separator: ", ")
        let marks = Array(repeating: "?", count: all.count).joined(separator: ", ")
        // Plain INSERT on purpose: unlike INSERT OR IGNORE it never swallows a CHECK or NOT NULL
        // failure, so a wrong mapping stops the whole copy instead of silently dropping a row.
        try model.database.run(
            "INSERT INTO \(row.table) (\(names)) VALUES (\(marks))",
            all.map { $0.1 }
        )
    }

    private func writeDraftFiles(_ draft: PlannedDraft, created: inout [URL], warnings: inout [String]) throws {

        let fileManager = FileManager.default
        let folder = try model.library.url(forRelativePath: draft.folder)

        if fileManager.fileExists(atPath: folder.path) {
            warnings.append("The folder for the draft “\(draft.title)” already existed and was left as it is.")
            return
        }

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        created.append(folder)

        for sub in ["figures", "chapters"] {
            try fileManager.createDirectory(
                at: folder.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        for file in draft.files {
            try Data(file.contents.utf8).write(
                to: folder.appendingPathComponent(file.name), options: .atomic)
        }
    }

    // MARK: - The plan (pure: reads the old data, writes nothing)

    private struct PlannedRow {
        let table: String
        /// "paper", "note", "run" ... used for counts and messages.
        let group: String
        let id: String
        /// What the change history calls this kind of record.
        let entityType: String
        let title: String
        /// Values that are compared again in the check step.
        var columns: [(String, SQLValue)]
        /// Values that are written but not compared (citation key, attachment id).
        var insertOnly: [(String, SQLValue)] = []
        /// For highlights: the paper that owns the PDF.
        var ownerID: String = ""
        /// Old-only data, as JSON, for the change history.
        var legacy: String? = nil
    }

    private struct PlannedExtras {
        var creators: [CreatorInput]
        var tags: [String]
    }

    private struct PlannedColumn {
        let id: String
        let reviewID: String
        let name: String
        let position: Int
    }

    private struct PlannedCell {
        let reviewID: String
        let itemID: String
        let columnID: String
        let value: String
    }

    private struct PlannedLink {
        let id: String
        let fromType: String
        let fromID: String
        let toType: String
        let toID: String
        let rel: String
        let createdAt: String
    }

    private struct PlannedDraft {
        let id: String
        let title: String
        let folder: String
        let mainFile: String
        let sectionCount: Int
        let files: [(name: String, contents: String)]
    }

    private struct ComparisonPair: Hashable {
        let reviewID: String
        let itemID: String
    }

    private struct Plan {
        var rows: [PlannedRow] = []
        var extras: [String: PlannedExtras] = [:]
        var columns: [PlannedColumn] = []
        var cells: [PlannedCell] = []
        var comparisonPairs: [ComparisonPair] = []
        var links: [PlannedLink] = []
        var drafts: [PlannedDraft] = []

        var warnings: [String] = []
        var keyChanges: [KeyChange] = []

        /// What the old store holds, by kind.
        var oldCounts: [String: Int] = [:]
        /// Old records that cannot be copied, by kind and reason.
        var skipped: [String: [String: Int]] = [:]

        var authorCount = 0
        var tagCount = 0
        var sectionsPlanned = 0

        var edgesOld = 0
        var edgesDangling = 0
        var edgesDuplicate = 0
        var edgesWithoutHome = 0

        var paperTitles: [String: String] = [:]
        var paperAddedAt: [String: String] = [:]

        mutating func skip(_ group: String, _ reason: String) {
            skipped[group, default: [:]][reason, default: 0] += 1
        }

        func skipNote(groups: [String]) -> String {
            var parts: [String] = []
            for group in groups {
                for (reason, count) in (skipped[group] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    parts.append("\(count) \(reason)")
                }
            }
            return parts.joined(separator: "; ")
        }

        var linkNote: String {
            var parts: [String] = []
            if edgesDangling > 0 { parts.append("\(edgesDangling) pointed at records that no longer exist") }
            if edgesDuplicate > 0 { parts.append("\(edgesDuplicate) were repeats") }
            if edgesWithoutHome > 0 { parts.append("\(edgesWithoutHome) theme-to-paper links have no place in the new library") }
            return parts.joined(separator: "; ")
        }
    }

    // MARK: Building the plan

    private static func makePlan(_ capture: WorkspaceSnapshot.Capture, existing: Existing) -> Plan {

        let s = capture.snapshot
        var plan = Plan()

        // ---- Old counts ------------------------------------------------------------------------
        plan.oldCounts = [
            "paper": s.papers.count, "annotation": s.annotations.count,
            "note": s.notes.count, "finding": s.findings.count, "gap": s.gaps.count,
            "problem": s.problems.count, "idea": s.ideas.count,
            "review": s.reviews.count, "theme": s.themes.count, "comparison": s.comparisonEntries.count,
            "experiment": s.experiments.count, "run": s.runs.count, "metric": s.metrics.count,
            "baseline": s.baselineMetrics.count, "draft": s.writingDocuments.count,
            "section": s.writingSections.count, "project": s.projects.count, "task": s.tasks.count
        ]

        // ---- Sets of ids that exist (to drop references to records that are gone) -------------
        let paperIDs = Set(s.papers.map { $0.id })
        let reviewIDs = Set(s.reviews.map { $0.id })
        let experimentIDs = Set(s.experiments.map { $0.id })
        let runIDs = Set(s.runs.map { $0.id })
        let docIDs = Set(s.writingDocuments.map { $0.id })
        let projectIDs = Set(s.projects.map { $0.id })
        let taskIDs = Set(s.tasks.map { $0.id })
        var thoughtIDs = Set<UUID>()
        for n in s.notes { thoughtIDs.insert(n.id) }
        for f in s.findings { thoughtIDs.insert(f.id) }
        for g in s.gaps { thoughtIDs.insert(g.id) }
        for p in s.problems { thoughtIDs.insert(p.id) }
        for i in s.ideas { thoughtIDs.insert(i.id) }

        var papersWithPDF = Set<UUID>()
        for source in capture.pdfSources where paperIDs.contains(source.paperID) {
            papersWithPDF.insert(source.paperID)
        }

        // ---- Papers -----------------------------------------------------------------------------
        let papers = s.papers.sorted {
            $0.addedAt == $1.addedAt ? $0.id.uuidString < $1.id.uuidString : $0.addedAt < $1.addedAt
        }

        var taken = existing.lowerKeys
        var keyByPaper: [String: String] = [:]
        var emptyTitles = 0
        var ambiguousAuthors = 0

        for p in papers {

            let id = p.id.uuidString
            let parsed = parseAuthors(p.authors)
            if parsed.ambiguous { ambiguousAuthors += 1 }

            var title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                title = "Untitled paper"
                emptyTitles += 1
            }

            let year: SQLValue = (p.year > 0 && p.year <= 9999) ? .int(Int64(p.year)) : .null
            let doi = TextNormalizer.doi(p.doi)
            let arxiv = arxivID(fromURL: p.urlString)

            var insertOnly: [(String, SQLValue)] = []

            if let key = existing.keysByID[id] {
                keyByPaper[id] = key
            } else {
                let oldKey = p.citationKey.trimmingCharacters(in: .whitespacesAndNewlines)
                var key = ""

                if CitationKeyGenerator.isValid(oldKey), !taken.contains(oldKey.lowercased()) {
                    key = oldKey
                } else {
                    let base = CitationKeyGenerator.isValid(oldKey)
                        ? oldKey
                        : CitationKeyGenerator.base(
                            firstCreator: parsed.creators.first,
                            year: p.year > 0 ? p.year : nil,
                            title: title)
                    key = firstFreeKey(base, taken: taken)
                    if !oldKey.isEmpty {
                        plan.keyChanges.append(KeyChange(paperID: id, title: title, oldKey: oldKey, newKey: key))
                    }
                }
                taken.insert(key.lowercased())
                keyByPaper[id] = key
                insertOnly = [("citation_key", .text(key))]
            }

            let status = ["unread", "reading", "read"].contains(p.statusRawValue.lowercased())
                ? p.statusRawValue.lowercased() : "unread"

            let columns: [(String, SQLValue)] = [
                ("id", .text(id)),
                ("item_type", .text(itemType(for: p.publicationTypeRawValue).rawValue)),
                ("title", .text(title)),
                ("abstract", .text(p.abstractText)),
                ("venue", .text(p.venue)),
                ("year", year),
                ("month", .text(p.month)),
                ("volume", .text(p.volume)),
                ("issue", .text(p.issue)),
                ("pages", .text(p.pages)),
                ("publisher", .text(p.publisher)),
                ("edition", .text(p.edition)),
                ("doi", LibraryModel.text(doi)),
                ("arxiv_id", LibraryModel.text(arxiv)),
                ("url", .text(p.urlString)),
                ("key_locked", .int(0)),
                ("reading_status", .text(status)),
                ("in_queue", .int(0)),
                ("rating", .int(Int64(min(max(p.rating, 0), 5)))),
                ("language", .text("")),
                ("source_url", .text("")),
                ("source_kind", .text(SourceKind.import.rawValue)),
                ("captured_at", .null),
                ("review_state", .text(ReviewState.accepted.rawValue)),
                ("added_at", .text(iso(p.addedAt))),
                ("updated_at", .text(iso(p.updatedAt ?? p.addedAt)))
            ]

            plan.rows.append(PlannedRow(
                table: "items", group: "paper", id: id, entityType: "item", title: title,
                columns: columns, insertOnly: insertOnly,
                legacy: legacyJSON([
                    ("authors", p.authors),
                    ("publicationType", p.publicationTypeRawValue),
                    ("readingStatus", p.statusRawValue),
                    ("lastOpenedAt", p.lastOpenedAt.map { iso($0) })
                ])
            ))

            plan.extras[id] = PlannedExtras(creators: parsed.creators, tags: uniqueTags(p.tagsText))
            plan.authorCount += parsed.creators.count
            plan.tagCount += uniqueTags(p.tagsText).count
            plan.paperTitles[id] = title
            plan.paperAddedAt[id] = iso(p.addedAt)
        }

        if emptyTitles > 0 {
            plan.warnings.append("\(emptyTitles) papers had no title and are called “Untitled paper”.")
        }
        if ambiguousAuthors > 0 {
            plan.warnings.append("The authors of \(ambiguousAuthors) papers were split at commas and may need a look. The original text is kept in each paper’s history.")
        }
        if !capture.missingPDFTitles.isEmpty {
            let shown = capture.missingPDFTitles.prefix(10).map { "“\($0)”" }.joined(separator: ", ")
            let more = capture.missingPDFTitles.count > 10 ? " and \(capture.missingPDFTitles.count - 10) more" : ""
            plan.warnings.append("These papers had a PDF path but the file was not found, so they were copied without a PDF: \(shown)\(more).")
        }

        // ---- Highlights ------------------------------------------------------------------------
        for a in s.annotations.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            guard let paperID = a.paperID, paperIDs.contains(paperID) else {
                plan.skip("annotation", "highlights not attached to any paper")
                continue
            }
            guard papersWithPDF.contains(paperID) else {
                plan.skip("annotation", "highlights on papers whose PDF is missing")
                continue
            }

            let rect: [Double] = [a.boundsX, a.boundsY, a.boundsWidth, a.boundsHeight].map { $0.isFinite ? $0 : 0 }
            let columns: [(String, SQLValue)] = [
                ("id", .text(a.id.uuidString)),
                ("kind", .text("highlight")),
                ("color", .text("yellow")),
                ("page", .int(Int64(max(a.pageNumber, 1)))),
                ("rects_json", .text(LibraryModel.json([rect]))),
                ("quote", .text(a.text)),
                ("comment", .text(a.note)),
                ("created_at", .text(iso(a.createdAt))),
                ("updated_at", .text(iso(a.updatedAt)))
            ]
            plan.rows.append(PlannedRow(
                table: "annotations", group: "annotation", id: a.id.uuidString, entityType: "annotation",
                title: plan.paperTitles[paperID.uuidString] ?? "a paper",
                columns: columns, ownerID: paperID.uuidString))
        }

        // ---- Thoughts: notes, findings, gaps, problems, ideas ----------------------------------
        for n in s.notes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            plan.rows.append(thought(
                group: "note", id: n.id, kind: "note", title: n.title, body: n.content, status: "open",
                created: n.createdAt, updated: n.updatedAt,
                legacy: legacyJSON([("noteType", n.typeRawValue), ("tags", n.tagsText)])))
        }

        for f in s.findings.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            plan.rows.append(thought(
                group: "finding", id: f.id, kind: "finding", title: f.title, body: f.content, status: "open",
                created: f.createdAt, updated: f.updatedAt, legacy: nil))
        }

        for g in s.gaps.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            plan.rows.append(thought(
                group: "gap", id: g.id, kind: "gap", title: g.title,
                body: markdown(g.descriptionText, [("Significance", g.significance)]),
                status: gapStatus(g.statusRawValue),
                created: g.createdAt, updated: g.updatedAt, evidence: g.evidence,
                legacy: legacyJSON([("gapType", g.gapTypeRawValue), ("status", g.statusRawValue)])))
        }

        for p in s.problems.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            plan.rows.append(thought(
                group: "problem", id: p.id, kind: "problem", title: p.title,
                body: markdown(p.problemStatement, [
                    ("Background", p.background), ("Motivation", p.motivation),
                    ("Significance", p.significance), ("Objectives", p.objectives),
                    ("Hypotheses", p.hypotheses)
                ]),
                status: problemStatus(p.statusRawValue),
                created: p.createdAt, updated: p.updatedAt, question: p.researchQuestion,
                legacy: legacyJSON([("status", p.statusRawValue)])))
        }

        for i in s.ideas.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            plan.rows.append(thought(
                group: "idea", id: i.id, kind: "idea", title: i.title,
                body: markdown(i.summary, [
                    ("Description", i.descriptionText), ("Proposed approach", i.proposedApproach),
                    ("Expected contribution", i.expectedContribution), ("Novelty", i.novelty),
                    ("Assumptions", i.assumptions), ("Limitations", i.limitations)
                ]),
                status: ideaStatus(i.statusRawValue),
                created: i.createdAt, updated: i.updatedAt,
                legacy: legacyJSON([("status", i.statusRawValue)])))
        }

        // ---- Literature reviews ----------------------------------------------------------------
        var synthesisByReview: [UUID: [String]] = [:]
        for syn in s.syntheses.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let reviewID = syn.reviewID, reviewIDs.contains(reviewID) else {
                plan.skip("review", "syntheses not attached to a review")
                continue
            }
            synthesisByReview[reviewID, default: []].append(markdown(syn.overallSummary, [
                ("Common approaches", syn.commonApproaches), ("Major findings", syn.majorFindings),
                ("Areas of agreement", syn.areasOfAgreement), ("Areas of disagreement", syn.areasOfDisagreement),
                ("Methodological differences", syn.methodologicalDifferences),
                ("Limitations across the literature", syn.limitationsAcrossLiterature)
            ]))
        }

        for r in s.reviews.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let synthesis = markdown("", [("Description", r.descriptionText)])
                + (r.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n")
                + (synthesisByReview[r.id] ?? []).filter { !$0.isEmpty }.joined(separator: "\n\n")
            let columns: [(String, SQLValue)] = [
                ("id", .text(r.id.uuidString)),
                ("title", .text(nonEmpty(r.title, "Untitled review"))),
                ("question", .text(r.researchQuestion)),
                ("synthesis", .text(synthesis.trimmingCharacters(in: .whitespacesAndNewlines))),
                ("created_at", .text(iso(r.createdAt))),
                ("updated_at", .text(iso(r.updatedAt)))
            ]
            plan.rows.append(PlannedRow(
                table: "reviews", group: "review", id: r.id.uuidString, entityType: "review",
                title: nonEmpty(r.title, "Untitled review"), columns: columns))
        }

        var themeOrder: [UUID: Int] = [:]
        for t in s.themes.sorted(by: {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }) {
            guard let reviewID = t.reviewID, reviewIDs.contains(reviewID) else {
                plan.skip("theme", "themes not attached to a review")
                continue
            }
            let position = themeOrder[reviewID, default: 0]
            themeOrder[reviewID] = position + 1
            let columns: [(String, SQLValue)] = [
                ("id", .text(t.id.uuidString)),
                ("review_id", .text(reviewID.uuidString)),
                ("name", .text(nonEmpty(t.name, "Untitled theme"))),
                ("summary", .text(t.descriptionText)),
                ("position", .int(Int64(position)))
            ]
            plan.rows.append(PlannedRow(
                table: "review_themes", group: "theme", id: t.id.uuidString, entityType: "theme",
                title: nonEmpty(t.name, "Untitled theme"), columns: columns,
                legacy: legacyJSON([("paperIDs", t.paperIDs.map { $0.uuidString })])))
        }

        // Comparison entries become cells of the review's comparison matrix.
        var cellText: [ComparisonPair: [String]] = [:]
        for e in s.comparisonEntries.sorted(by: {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }) {
            guard let reviewID = e.reviewID, reviewIDs.contains(reviewID),
                  let paperID = e.paperID, paperIDs.contains(paperID) else {
                plan.skip("comparison", "entries not attached to both a review and a paper")
                continue
            }
            let pair = ComparisonPair(reviewID: reviewID.uuidString, itemID: paperID.uuidString)
            cellText[pair, default: []].append("\(e.method)\u{1F}\(e.dataset)\u{1F}\(e.mainFinding)\u{1F}\(e.notes)")
        }
        let columnNames = ["Method", "Dataset", "Main finding", "Notes"]
        var reviewsWithCells = Set<String>()
        for pair in cellText.keys.sorted(by: { ($0.reviewID, $0.itemID) < ($1.reviewID, $1.itemID) }) {
            plan.comparisonPairs.append(pair)
            reviewsWithCells.insert(pair.reviewID)
        }
        for reviewID in reviewsWithCells.sorted() {
            for (index, name) in columnNames.enumerated() {
                plan.columns.append(PlannedColumn(
                    id: stableID("review_column|\(reviewID)|\(name)"),
                    reviewID: reviewID, name: name, position: index))
            }
        }
        for pair in plan.comparisonPairs {
            let entries = (cellText[pair] ?? []).map { $0.components(separatedBy: "\u{1F}") }
            for (index, name) in columnNames.enumerated() {
                let value = entries
                    .map { index < $0.count ? $0[index] : "" }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                plan.cells.append(PlannedCell(
                    reviewID: pair.reviewID, itemID: pair.itemID,
                    columnID: stableID("review_column|\(pair.reviewID)|\(name)"), value: value))
            }
        }

        // ---- Experiments -----------------------------------------------------------------------
        for e in s.experiments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            var objective = e.objective.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = e.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty {
                objective = objective.isEmpty ? description : objective + "\n\n" + description
            }

            var environment: [String: Any] = [:]
            if !e.hardware.isEmpty { environment["hardware"] = e.hardware }
            if !e.operatingEnvironment.isEmpty { environment["operating_environment"] = e.operatingEnvironment }
            if !e.framework.isEmpty { environment["framework"] = e.framework }

            var config: [String: Any] = [:]
            if !e.model.isEmpty { config["model"] = e.model }
            if !e.optimizer.isEmpty { config["optimizer"] = e.optimizer }
            if !e.learningRate.isEmpty { config["learning_rate"] = e.learningRate }
            if let epochs = e.epochs { config["epochs"] = epochs }
            if let batch = e.batchSize { config["batch_size"] = batch }
            if let seed = e.seed { config["seed"] = seed }

            let bestRun: SQLValue = {
                if let best = e.bestRunID, runIDs.contains(best) { return .text(best.uuidString) }
                return .null
            }()

            let columns: [(String, SQLValue)] = [
                ("id", .text(e.id.uuidString)),
                ("name", .text(nonEmpty(e.name, "Untitled experiment"))),
                ("status", .text(experimentStatus(e.statusRawValue))),
                ("objective", .text(objective)),
                ("hypothesis", .text(e.hypothesis)),
                ("interpretation", .text(e.resultsInterpretation)),
                ("conclusion", .text(e.resultsConclusion)),
                ("code_repo", .text(e.codeRepository)),
                ("dataset", .text(e.dataset)),
                ("dataset_version", .text(e.datasetVersion)),
                ("split_spec", .text(e.trainValidationTestSplit)),
                ("environment_json", .text(LibraryModel.json(environment))),
                ("config_json", .text(LibraryModel.json(config))),
                ("best_run_id", bestRun),
                ("created_at", .text(iso(e.createdAt))),
                ("updated_at", .text(iso(e.updatedAt)))
            ]
            plan.rows.append(PlannedRow(
                table: "experiments", group: "experiment", id: e.id.uuidString, entityType: "experiment",
                title: nonEmpty(e.name, "Untitled experiment"), columns: columns,
                legacy: legacyJSON([("status", e.statusRawValue)])))
        }

        // Runs with the same configuration text are repeats of one "setting".
        var settingNumbers: [UUID: [String: Int]] = [:]
        let orderedRuns = s.runs.sorted {
            if $0.runNumber != $1.runNumber { return $0.runNumber < $1.runNumber }
            return $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
        var validRunIDs = Set<UUID>()
        for r in orderedRuns {
            guard let experimentID = r.experimentID, experimentIDs.contains(experimentID) else {
                plan.skip("run", "runs not attached to an experiment")
                continue
            }
            let configuration = r.configuration.trimmingCharacters(in: .whitespacesAndNewlines)
            var setting = "default"
            if !configuration.isEmpty {
                var numbers = settingNumbers[experimentID] ?? [:]
                if numbers[configuration] == nil { numbers[configuration] = numbers.count + 1 }
                settingNumbers[experimentID] = numbers
                setting = "setting-\(numbers[configuration] ?? 1)"
            }
            let runConfig: [String: Any] = configuration.isEmpty ? [:] : ["configuration": configuration]
            validRunIDs.insert(r.id)

            let columns: [(String, SQLValue)] = [
                ("id", .text(r.id.uuidString)),
                ("experiment_id", .text(experimentID.uuidString)),
                ("setting", .text(setting)),
                ("run_number", .int(Int64(r.runNumber))),
                ("seed", LibraryModel.int(r.seed)),
                ("status", .text(runStatus(r.statusRawValue))),
                ("started_at", LibraryModel.text(r.startedAt.map { iso($0) })),
                ("completed_at", LibraryModel.text(r.completedAt.map { iso($0) })),
                ("config_json", .text(LibraryModel.json(runConfig))),
                ("notes", .text(r.notes))
            ]
            plan.rows.append(PlannedRow(
                table: "runs", group: "run", id: r.id.uuidString, entityType: "run",
                title: "run \(r.runNumber)", columns: columns))
        }

        for m in s.metrics.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let runID = m.runID, validRunIDs.contains(runID) else {
                plan.skip("metric", "metrics not attached to a run")
                continue
            }
            let columns: [(String, SQLValue)] = [
                ("id", .text(m.id.uuidString)),
                ("run_id", .text(runID.uuidString)),
                ("name", .text(m.name)),
                ("value", .double(m.value.isFinite ? m.value : 0)),
                ("unit", .text(m.unit)),
                ("higher_is_better", .int(m.higherIsBetter ? 1 : 0))
            ]
            plan.rows.append(PlannedRow(
                table: "metrics", group: "metric", id: m.id.uuidString, entityType: "metric",
                title: m.name, columns: columns))
        }

        for b in s.baselineMetrics.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let experimentID = b.experimentID, experimentIDs.contains(experimentID) else {
                plan.skip("baseline", "baselines not attached to an experiment")
                continue
            }
            let columns: [(String, SQLValue)] = [
                ("id", .text(b.id.uuidString)),
                ("experiment_id", .text(experimentID.uuidString)),
                ("name", .text(b.name)),
                ("value", .double(b.value.isFinite ? b.value : 0)),
                ("unit", .text(b.unit)),
                ("higher_is_better", .int(b.higherIsBetter ? 1 : 0))
            ]
            plan.rows.append(PlannedRow(
                table: "baselines", group: "baseline", id: b.id.uuidString, entityType: "baseline",
                title: b.name, columns: columns))
        }

        // ---- Writing documents -----------------------------------------------------------------
        var sectionsByDoc: [UUID: [WritingSectionDTO]] = [:]
        for section in s.writingSections {
            guard let docID = section.documentID, docIDs.contains(docID) else {
                plan.skip("section", "sections not attached to a document")
                continue
            }
            sectionsByDoc[docID, default: []].append(section)
        }

        var submissionRows: [PlannedRow] = []

        for d in s.writingDocuments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {

            let id = d.id.uuidString
            let title = nonEmpty(d.title, "Untitled draft")
            let sections = (sectionsByDoc[d.id] ?? []).sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            plan.sectionsPlanned += sections.count

            let stage = draftStage(d.stageRawValue)
            let archived = d.archivedFlag ?? (d.statusRawValue == "Archived")
            let folder = "drafts/\(id)"

            let columns: [(String, SQLValue)] = [
                ("id", .text(id)),
                ("title", .text(title)),
                ("kind", .text(draftKind(d.documentTypeRawValue))),
                ("folder", .text(folder)),
                ("main_file", .text("main.tex")),
                ("stage", .text(stage)),
                ("archived", .int(archived ? 1 : 0)),
                ("created_at", .text(iso(d.createdAt))),
                ("updated_at", .text(iso(d.updatedAt)))
            ]
            plan.rows.append(PlannedRow(
                table: "drafts", group: "draft", id: id, entityType: "draft", title: title, columns: columns,
                legacy: legacyJSON([
                    ("documentType", d.documentTypeRawValue), ("status", d.statusRawValue),
                    ("stage", d.stageRawValue), ("format", d.formatRawValue),
                    ("progressPercent", d.progressPercent)
                ])))

            // The text becomes real files: main.tex, plus refs.bib for the papers it cites.
            var cited: [(key: String, paper: PaperDTO)] = []
            var seenCited = Set<UUID>()
            for paperID in d.paperIDs where seenCited.insert(paperID).inserted {
                if let paper = papers.first(where: { $0.id == paperID }),
                   let key = keyByPaper[paperID.uuidString] {
                    cited.append((key, paper))
                }
            }
            var files: [(name: String, contents: String)] = [
                ("main.tex", mainTex(title: title, sections: sections, citedKeys: cited.map { $0.key }))
            ]
            if !cited.isEmpty {
                files.append(("refs.bib", cited.map { bibEntry(key: $0.key, paper: $0.paper) }.joined(separator: "\n")))
            }
            plan.drafts.append(PlannedDraft(
                id: id, title: title, folder: folder, mainFile: "main.tex",
                sectionCount: sections.count, files: files))

            // Where the old document kept its submission details, the new library has a table.
            let venue = (d.venue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (d.submissionNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !venue.isEmpty || !note.isEmpty || stage != "draft" {
                let submissionID = stableID("submission|\(id)")
                let submissionColumns: [(String, SQLValue)] = [
                    ("id", .text(submissionID)),
                    ("draft_id", .text(id)),
                    ("venue", .text(venue)),
                    ("stage", .text(stage == "draft" ? "planned" : stage)),
                    ("notes", .text(note))
                ]
                submissionRows.append(PlannedRow(
                    table: "submissions", group: "submission", id: submissionID, entityType: "submission",
                    title: title, columns: submissionColumns))
            }
        }
        plan.rows.append(contentsOf: submissionRows)

        // ---- Projects and tasks ----------------------------------------------------------------
        for p in s.projects.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let columns: [(String, SQLValue)] = [
                ("id", .text(p.id.uuidString)),
                ("name", .text(nonEmpty(p.name, "Untitled project"))),
                ("description", .text(p.descriptionText)),
                ("status", .text(projectStatus(p.statusRawValue))),
                ("created_at", .text(iso(p.createdAt))),
                ("updated_at", .text(iso(p.updatedAt)))
            ]
            plan.rows.append(PlannedRow(
                table: "projects", group: "project", id: p.id.uuidString, entityType: "project",
                title: nonEmpty(p.name, "Untitled project"), columns: columns,
                legacy: legacyJSON([("status", p.statusRawValue)])))
        }

        var tasksWithoutProject = 0
        for t in s.tasks.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var projectValue: SQLValue = .null
            if let projectID = t.projectID {
                if projectIDs.contains(projectID) {
                    projectValue = .text(projectID.uuidString)
                } else {
                    tasksWithoutProject += 1
                }
            }
            let columns: [(String, SQLValue)] = [
                ("id", .text(t.id.uuidString)),
                ("project_id", projectValue),
                ("title", .text(nonEmpty(t.title, "Untitled task"))),
                ("notes", .text(t.descriptionText)),
                ("status", .text(taskStatus(t.statusRawValue))),
                ("priority", .text(taskPriority(t.priorityRawValue))),
                ("due_at", LibraryModel.text(t.dueDate.map { iso($0) })),
                ("completed_at", LibraryModel.text(t.completedDate.map { iso($0) })),
                ("created_at", .text(iso(t.createdAt))),
                ("updated_at", .text(iso(t.updatedAt)))
            ]
            plan.rows.append(PlannedRow(
                table: "tasks", group: "task", id: t.id.uuidString, entityType: "task",
                title: nonEmpty(t.title, "Untitled task"), columns: columns,
                legacy: legacyJSON([("status", t.statusRawValue)])))
        }
        if tasksWithoutProject > 0 {
            plan.warnings.append("\(tasksWithoutProject) tasks pointed at a project that no longer exists and were copied without one.")
        }

        // ---- Links: one table for every relationship -------------------------------------------
        var known: [LinkEntity: Set<UUID>] = [
            .item: paperIDs, .thought: thoughtIDs, .experiment: experimentIDs, .draft: docIDs,
            .project: projectIDs, .task: taskIDs, .review: reviewIDs
        ]
        known[.collection] = []

        var seenEdges = Set<String>()
        let linkTime = Library.nowISO(Date(timeIntervalSince1970: 0))

        func link(_ fromType: LinkEntity, _ from: UUID, _ toType: LinkEntity, _ to: UUID, _ rel: LinkRel) {
            plan.edgesOld += 1
            guard known[fromType]?.contains(from) == true, known[toType]?.contains(to) == true else {
                plan.edgesDangling += 1
                return
            }
            let key = "\(fromType.rawValue)|\(from.uuidString)|\(toType.rawValue)|\(to.uuidString)|\(rel.rawValue)"
            guard seenEdges.insert(key).inserted else {
                plan.edgesDuplicate += 1
                return
            }
            plan.links.append(PlannedLink(
                id: stableID("link|" + key),
                fromType: fromType.rawValue, fromID: from.uuidString,
                toType: toType.rawValue, toID: to.uuidString,
                rel: rel.rawValue, createdAt: linkTime))
        }

        for n in s.notes {
            for paper in n.paperIDs { link(.thought, n.id, .item, paper, .related) }
        }
        for r in s.reviews {
            for paper in r.paperIDs { link(.review, r.id, .item, paper, .related) }
        }
        for t in s.themes {
            // A theme has no row type of its own in links, so its papers cannot be expressed.
            plan.edgesOld += t.paperIDs.count
            plan.edgesWithoutHome += t.paperIDs.count
        }
        for f in s.findings {
            if let review = f.reviewID { link(.thought, f.id, .review, review, .partOf) }
            for paper in f.supportingPaperIDs { link(.item, paper, .thought, f.id, .supports) }
            for gap in f.gapIDs { link(.thought, f.id, .thought, gap, .related) }
        }
        for g in s.gaps {
            for paper in g.paperIDs { link(.thought, g.id, .item, paper, .related) }
        }
        for p in s.problems {
            for gap in p.gapIDs { link(.thought, p.id, .thought, gap, .derivedFrom) }
            for paper in p.paperIDs { link(.thought, p.id, .item, paper, .related) }
        }
        for i in s.ideas {
            for problem in i.problemIDs { link(.thought, i.id, .thought, problem, .derivedFrom) }
            for gap in i.gapIDs { link(.thought, i.id, .thought, gap, .derivedFrom) }
            for paper in i.paperIDs { link(.thought, i.id, .item, paper, .related) }
            for note in i.noteIDs { link(.thought, i.id, .thought, note, .related) }
        }
        for e in s.experiments {
            for idea in e.ideaIDs { link(.experiment, e.id, .thought, idea, .derivedFrom) }
            for problem in e.problemIDs { link(.experiment, e.id, .thought, problem, .derivedFrom) }
            for gap in e.gapIDs { link(.experiment, e.id, .thought, gap, .derivedFrom) }
            for paper in e.paperIDs { link(.experiment, e.id, .item, paper, .related) }
            for note in e.noteIDs { link(.experiment, e.id, .thought, note, .related) }
        }
        for d in s.writingDocuments {
            for problem in d.problemIDs { link(.draft, d.id, .thought, problem, .related) }
            for idea in d.ideaIDs { link(.draft, d.id, .thought, idea, .related) }
            for gap in d.gapIDs { link(.draft, d.id, .thought, gap, .related) }
            for note in d.noteIDs { link(.draft, d.id, .thought, note, .related) }
            for finding in d.findingIDs { link(.draft, d.id, .thought, finding, .related) }
            for experiment in d.experimentIDs { link(.draft, d.id, .experiment, experiment, .uses) }
            for paper in d.paperIDs { link(.draft, d.id, .item, paper, .cites) }
        }
        for p in s.projects {
            for paper in p.paperIDs { link(.item, paper, .project, p.id, .partOf) }
            for note in p.noteIDs { link(.thought, note, .project, p.id, .partOf) }
            for finding in p.findingIDs { link(.thought, finding, .project, p.id, .partOf) }
            for gap in p.gapIDs { link(.thought, gap, .project, p.id, .partOf) }
            for problem in p.problemIDs { link(.thought, problem, .project, p.id, .partOf) }
            for idea in p.ideaIDs { link(.thought, idea, .project, p.id, .partOf) }
            for experiment in p.experimentIDs { link(.experiment, experiment, .project, p.id, .partOf) }
            for doc in p.writingDocumentIDs { link(.draft, doc, .project, p.id, .partOf) }
        }
        for t in s.tasks {
            if let project = t.projectID { link(.task, t.id, .project, project, .partOf) }
            for paper in t.paperIDs { link(.task, t.id, .item, paper, .related) }
            for problem in t.problemIDs { link(.task, t.id, .thought, problem, .related) }
            for idea in t.ideaIDs { link(.task, t.id, .thought, idea, .related) }
            for experiment in t.experimentIDs { link(.task, t.id, .experiment, experiment, .related) }
            for doc in t.writingDocumentIDs { link(.task, t.id, .draft, doc, .related) }
        }

        // ---- Warnings for things the new tables have no place for ------------------------------
        let notesWithExtras = s.notes.filter {
            !$0.tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        if !s.notes.isEmpty {
            plan.warnings.append("Note types\(notesWithExtras > 0 ? " and tags" : "") have no column in the new library. They are kept in each note’s history.")
        }
        if !s.themes.isEmpty && plan.edgesWithoutHome > 0 {
            plan.warnings.append("The papers listed under review themes have no place in the new library. They are kept in each theme’s history.")
        }
        for (group, reasons) in plan.skipped.sorted(by: { $0.key < $1.key }) {
            for (reason, count) in reasons.sorted(by: { $0.key < $1.key }) {
                plan.warnings.append("\(count) \(reason) were not copied. They stay in the old data, which is kept read-only.")
                _ = group
            }
        }

        return plan
    }

    // MARK: - Mapping helpers (old raw values to new values)

    private static func thought(
        group: String, id: UUID, kind: String, title: String, body: String, status: String,
        created: Date, updated: Date, evidence: String = "", question: String = "", legacy: String?
    ) -> PlannedRow {
        let shown = nonEmpty(title, "Untitled \(kind)")
        let columns: [(String, SQLValue)] = [
            ("id", .text(id.uuidString)),
            ("kind", .text(kind)),
            ("title", .text(shown)),
            ("body", .text(body)),
            ("status", .text(status)),
            ("priority", .int(0)),
            ("evidence", .text(evidence)),
            ("question", .text(question)),
            ("created_at", .text(iso(created))),
            ("updated_at", .text(iso(updated)))
        ]
        return PlannedRow(
            table: "thoughts", group: group, id: id.uuidString, entityType: "thought", title: shown,
            columns: columns, legacy: legacy)
    }

    private static func itemType(for raw: String) -> ItemType {
        switch raw {
        case "Journal Article": return .article
        case "Conference Paper", "Workshop Paper": return .conference
        case "Book": return .book
        case "Book Chapter": return .chapter
        case "Thesis": return .thesis
        case "Technical Report": return .report
        case "Preprint": return .preprint
        case "Website": return .webpage
        default: return .article
        }
    }

    private static func gapStatus(_ raw: String) -> String {
        switch raw {
        case "Investigating", "Validated": return "exploring"
        case "Addressed": return "done"
        case "Archived": return "dropped"
        default: return "open"
        }
    }

    private static func problemStatus(_ raw: String) -> String {
        switch raw {
        case "Exploring", "Defined", "Active": return "exploring"
        case "Resolved": return "done"
        case "Archived": return "dropped"
        default: return "open"
        }
    }

    private static func ideaStatus(_ raw: String) -> String {
        switch raw {
        case "Exploring", "Promising", "Selected", "Testing": return "exploring"
        case "Implemented": return "done"
        case "Rejected", "Archived": return "dropped"
        default: return "open"
        }
    }

    private static func experimentStatus(_ raw: String) -> String {
        switch raw {
        case "Running": return "running"
        case "Completed", "Analyzing": return "completed"
        case "Archived": return "archived"
        default: return "planned"
        }
    }

    private static func runStatus(_ raw: String) -> String {
        switch raw {
        case "Running": return "running"
        case "Completed": return "completed"
        case "Failed": return "failed"
        default: return "planned"
        }
    }

    private static func draftKind(_ raw: String) -> String {
        switch raw {
        case "Research Paper", "Conference Paper", "Journal Paper": return "paper"
        case "Thesis Chapter": return "chapter"
        case "Thesis": return "thesis"
        case "Literature Review", "Technical Report": return "report"
        default: return "other"
        }
    }

    private static func draftStage(_ raw: String?) -> String {
        switch raw ?? "" {
        case "Submitted": return "submitted"
        case "Under Review": return "under_review"
        case "Revision": return "revision"
        case "Accepted": return "accepted"
        case "Published": return "published"
        default: return "draft"
        }
    }

    private static func projectStatus(_ raw: String) -> String {
        switch raw {
        case "Planning": return "planning"
        case "On Hold": return "on_hold"
        case "Completed": return "completed"
        case "Archived": return "archived"
        default: return "active"
        }
    }

    private static func taskStatus(_ raw: String) -> String {
        switch raw {
        case "In Progress": return "doing"
        case "Completed": return "done"
        default: return "todo"
        }
    }

    private static func taskPriority(_ raw: String) -> String {
        switch raw {
        case "Low": return "low"
        case "High": return "high"
        default: return "medium"
        }
    }

    private static func iso(_ date: Date) -> String {
        Library.nowISO(date)
    }

    static func parseISO(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func nonEmpty(_ text: String, _ fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Main text first, then each non-empty extra field under its own Markdown heading.
    /// Nothing the person wrote is dropped; the fields only get a visible label.
    private static func markdown(_ main: String, _ sections: [(String, String)]) -> String {
        var blocks: [String] = []
        let lead = main.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lead.isEmpty { blocks.append(lead) }
        for (heading, text) in sections {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { blocks.append("## \(heading)\n\n\(body)") }
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Old-only data as compact JSON, or nil when there is none.
    private static func legacyJSON(_ pairs: [(String, Any?)]) -> String? {
        var dictionary: [String: Any] = [:]
        for (key, value) in pairs {
            guard let value else { continue }
            if let text = value as? String,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let list = value as? [String], list.isEmpty { continue }
            dictionary[key] = value
        }
        guard !dictionary.isEmpty else { return nil }
        return LibraryModel.json(dictionary)
    }

    private static func uniqueTags(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    /// base, then base+a ... base+z, then base-2, base-3 ... (the same order CitationKeyStore uses).
    private static func firstFreeKey(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base.lowercased()) { return base }
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            let candidate = base + String(letter)
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        var number = 2
        while true {
            let candidate = "\(base)-\(number)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            number += 1
        }
    }

    private static func arxivID(fromURL url: String) -> String? {
        let lower = url.lowercased()
        guard let range = lower.range(of: "arxiv.org/abs/") else { return nil }
        let tail = lower[range.upperBound...]
        let end = tail.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == " " }) ?? tail.endIndex
        let id = String(tail[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }

    /// A real UUID computed from text, so the same input always gives the same id.
    /// Used where the old data had no id (attachments, links, review columns, submissions)
    /// so a second run finds what the first run wrote.
    static func stableID(_ seed: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid.uuidString
    }

    // MARK: - Authors

    struct ParsedAuthors: Equatable {
        var creators: [CreatorInput]
        /// True when the names were split at commas and could be wrong.
        var ambiguous: Bool
    }

    /// Turns the old free-text authors field into people.
    ///
    /// Semicolons are the reliable separator. Without them, " and " and " & " split names.
    /// Otherwise commas are used: "Family, Given" is one person, "Smith, J., Lee, K." is two
    /// (initials after each surname), and a plain comma list is split but flagged as ambiguous.
    static func parseAuthors(_ raw: String) -> ParsedAuthors {

        var text = collapse(raw)
        guard !text.isEmpty else { return ParsedAuthors(creators: [], ambiguous: false) }

        if !text.contains(";") {
            text = text.replacingOccurrences(of: " and ", with: ";", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " & ", with: ";")
        }

        var names: [String] = []
        var ambiguous = false

        if text.contains(";") {
            names = splitAndTrim(text, ";")
        } else {
            let parts = splitAndTrim(text, ",")
            if parts.count <= 1 {
                names = parts
            } else if parts.count == 2 {
                names = parts[0].contains(" ") ? parts : ["\(parts[0]), \(parts[1])"]
            } else if parts.count % 2 == 0,
                      stride(from: 1, to: parts.count, by: 2).allSatisfy({ looksLikeInitials(parts[$0]) }) {
                names = stride(from: 0, to: parts.count, by: 2).map { "\(parts[$0]), \(parts[$0 + 1])" }
            } else {
                names = parts
                ambiguous = true
            }
        }

        return ParsedAuthors(creators: names.compactMap { creator(fromName: $0) }, ambiguous: ambiguous)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func splitAndTrim(_ text: String, _ separator: Character) -> [String] {
        text.split(separator: separator)
            .map { collapse(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func looksLikeInitials(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).map(String.init)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { $0.count <= 2 && $0.allSatisfy { $0.isUppercase } }
    }

    private static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]

    private static let nameParticles: Set<String> = [
        "van", "von", "de", "der", "den", "del", "della", "di", "da", "dos", "das", "du",
        "la", "le", "bin", "ibn", "al", "el", "ter", "ten", "st"
    ]

    private static let organisationWords: Set<String> = [
        "university", "institute", "laboratory", "consortium", "collaboration", "group", "team",
        "association", "society", "committee", "organization", "organisation", "foundation",
        "corporation", "department", "ministry", "inc", "ltd", "llc", "gmbh"
    ]

    private static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
    }

    private static func creator(fromName name: String) -> CreatorInput? {

        let text = collapse(name)
        guard !text.isEmpty else { return nil }

        let lowered = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if lowered == "et al" || lowered == "others" {
            return CreatorInput(family: "others")
        }

        // "Family, Given" and "Family, Jr., Given"
        if text.contains(",") {
            let parts = splitAndTrim(text, ",")
            guard let family = parts.first, !family.isEmpty else { return nil }
            var rest = Array(parts.dropFirst())
            var suffix = ""
            if rest.count >= 2, nameSuffixes.contains(bare(rest[0])) {
                suffix = rest.removeFirst()
            }
            return CreatorInput(family: family, given: rest.joined(separator: " "), suffix: suffix)
        }

        let words = text.split(separator: " ").map(String.init)
        if words.count == 1 {
            return CreatorInput(family: text)
        }
        if words.contains(where: { organisationWords.contains(bare($0)) }) {
            return CreatorInput(family: text, isOrganisation: true)
        }

        // "Given Family", keeping lower-case particles with the family name ("van der Berg").
        var core = words
        var suffix = ""
        if core.count > 2, let last = core.last, nameSuffixes.contains(bare(last)) {
            suffix = last
            core.removeLast()
        }
        var familyStart = core.count - 1
        while familyStart > 1, nameParticles.contains(bare(core[familyStart - 1])) {
            familyStart -= 1
        }
        return CreatorInput(
            family: core[familyStart...].joined(separator: " "),
            given: core[..<familyStart].joined(separator: " "),
            suffix: suffix)
    }

    // MARK: - LaTeX and BibTeX text for migrated drafts

    /// Escapes the characters LaTeX treats as commands. Text that already contains LaTeX commands
    /// (a backslash followed by letters) is left exactly as it is.
    static func latexBody(_ text: String) -> String {
        if text.range(of: #"\\[A-Za-z]+"#, options: .regularExpression) != nil { return text }
        return latexEscaped(text)
    }

    static func latexEscaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\\": result += "\\textbackslash{}"
            case "&": result += "\\&"
            case "%": result += "\\%"
            case "$": result += "\\$"
            case "#": result += "\\#"
            case "_": result += "\\_"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "~": result += "\\textasciitilde{}"
            case "^": result += "\\textasciicircum{}"
            default: result.append(character)
            }
        }
        return result
    }

    private static func mainTex(title: String, sections: [WritingSectionDTO], citedKeys: [String]) -> String {

        var lines: [String] = [
            "\\documentclass[11pt]{article}",
            "\\usepackage[utf8]{inputenc}"
        ]
        if !citedKeys.isEmpty { lines.append("\\usepackage{natbib}") }
        lines.append("\\title{\(latexEscaped(title))}")
        lines.append("\\date{}")
        lines.append("\\begin{document}")
        lines.append("\\maketitle")
        lines.append("")

        for section in sections {
            let heading = nonEmpty(section.title, "Untitled section")
            let body = latexBody(section.content.trimmingCharacters(in: .whitespacesAndNewlines))
            if section.sectionTypeRawValue == "Abstract" {
                lines.append("\\begin{abstract}")
                lines.append(body)
                lines.append("\\end{abstract}")
            } else {
                lines.append("\\section{\(latexEscaped(heading))}")
                lines.append(body)
            }
            lines.append("")
        }

        if !citedKeys.isEmpty {
            lines.append("\\nocite{\(citedKeys.joined(separator: ","))}")
            lines.append("\\bibliographystyle{plainnat}")
            lines.append("\\bibliography{refs}")
            lines.append("")
        }

        lines.append("\\end{document}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A conservative BibTeX entry. The real refs.bib writer (Writing screen) regenerates this file
    /// from the library; this one only has to be good enough to build the migrated draft.
    private static func bibEntry(key: String, paper: PaperDTO) -> String {

        let type = itemType(for: paper.publicationTypeRawValue)
        let entryType: String
        var venueField = ""

        switch type {
        case .article: entryType = "article"; venueField = "journal"
        case .conference: entryType = "inproceedings"; venueField = "booktitle"
        case .chapter: entryType = "incollection"; venueField = "booktitle"
        case .book: entryType = "book"
        case .report: entryType = "techreport"
        default: entryType = "misc"
        }

        let authors = parseAuthors(paper.authors).creators.map { creator -> String in
            if creator.family == "others" { return "others" }
            if creator.isOrganisation { return "{\(creator.family)}" }
            let family = creator.family.contains(" ") ? "{\(creator.family)}" : creator.family
            if creator.given.isEmpty { return family }
            return creator.suffix.isEmpty ? "\(family), \(creator.given)" : "\(family), \(creator.suffix), \(creator.given)"
        }

        var fields: [(String, String)] = []
        if !authors.isEmpty { fields.append(("author", authors.joined(separator: " and "))) }
        fields.append(("title", "{\(bibEscaped(paper.title))}"))
        if paper.year > 0 { fields.append(("year", String(paper.year))) }
        if !venueField.isEmpty, !paper.venue.isEmpty { fields.append((venueField, bibEscaped(paper.venue))) }
        if !paper.volume.isEmpty { fields.append(("volume", bibEscaped(paper.volume))) }
        if !paper.issue.isEmpty { fields.append(("number", bibEscaped(paper.issue))) }
        if !paper.pages.isEmpty {
            var pages = paper.pages.replacingOccurrences(of: "–", with: "--").replacingOccurrences(of: "—", with: "--")
            if pages.contains("-") && !pages.contains("--") { pages = pages.replacingOccurrences(of: "-", with: "--") }
            fields.append(("pages", pages))
        }
        if !paper.publisher.isEmpty { fields.append(("publisher", bibEscaped(paper.publisher))) }
        if let doi = TextNormalizer.doi(paper.doi) { fields.append(("doi", doi)) }
        if !paper.urlString.isEmpty { fields.append(("url", paper.urlString)) }

        let body = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(entryType){\(key),\n\(body)\n}\n"
    }

    /// Escapes & % $ # _ unless they already have a backslash in front.
    private static func bibEscaped(_ text: String) -> String {
        var result = ""
        var previous: Character = " "
        for character in text {
            if "&%$#_".contains(character), previous != "\\" { result += "\\" }
            result.append(character)
            previous = character
        }
        return result
    }
}