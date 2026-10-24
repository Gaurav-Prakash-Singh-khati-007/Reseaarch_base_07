//
//  DraftHistoryStore.swift
//  ResearchBase
//
//  Owner: Agent 21 · Features: F-36
//
//  Draft history: snapshots of a draft's whole folder, side-by-side differences
//  and restore. A snapshot is a zipped copy of the draft folder; the zip file
//  sits in the library under drafts/.history/<draftID>/<snapshotID>.zip (a hidden
//  folder, so the draft folders themselves stay clean for Overleaf and TeXShop)
//  and its path is stored in `draft_snapshots.bundle_path`.
//
//  PUBLIC API
//    Types
//      StoredDraftSnapshot        one row of `draft_snapshots`
//      StoredDiffKind             same, removed, added
//      StoredDiffLine             one line of a comparison
//    DraftHistoryStore(model: LibraryModel)
//      takeSnapshot(draftID:label:auto:) throws -> StoredDraftSnapshot
//      takeAutomaticSnapshotIfDue(draftID:now:minimumMinutes:) throws -> StoredDraftSnapshot?
//          every 30 minutes of editing (default); nil when nothing was edited or it is too soon
//      snapshots(forDraft:) throws -> [StoredDraftSnapshot]      newest first
//      snapshot(id:) throws -> StoredDraftSnapshot?
//      count(forDraft:) throws -> Int
//      setLabel(snapshotID:to:) throws -> StoredDraftSnapshot
//      fileText(snapshotID:path:) throws -> String               one file as it was in the snapshot
//      diff(snapshotID:path:) throws -> [StoredDiffLine]         snapshot version → current file (default: main file)
//      restore(snapshotID:) throws -> StoredDraftSnapshot        puts the old folder back; returns the safety snapshot taken first
//      remove(snapshotID:) throws
//      removeAll(forDraft:) throws -> Int                        also use after a draft is deleted forever
//      pruneAutomatic(forDraft:keepLatest:) throws -> Int        drops the oldest unlabeled automatic snapshots
//      DraftHistoryStore.diffLines(old:new:) -> [StoredDiffLine]
//      DraftHistoryStore.countWords(inLatex:) -> Int
//
//  Notes
//    * Callers take a labeled snapshot before risky steps, for example
//      takeSnapshot(draftID:, label: "Before changing template", auto: true)
//      before a template change, or label "Before submission" before sending.
//    * Zipping and unzipping use the Mac's own `ditto` tool (the app is not sandboxed).
//      For a draft with very large figures, call from a background task.
//    * The whole folder is zipped, so figures and build output inside the draft
//      folder are included.
//    * Word counts are approximate (LaTeX commands, comments and citation keys are
//      not counted); they are only for the history list.
//    * restore saves a safety snapshot of the current folder first, checks that the old
//      version still has the draft's main file, then swaps the folders. If anything
//      fails the current folder is put back. It also moves `drafts.updated_at`
//      (the only write this file makes to the drafts table).
//    * Snapshot rows have no `deleted_at`; removing one deletes its zip and reports
//      the old values to the change sink.
//    * This file does not use DraftFolderStore; it reads the drafts table and the
//      folder itself, so the two do not depend on each other.
//    * Names start with "Stored" to stay clear of types the screens already use.
//

import Foundation

// MARK: - Types

struct StoredDraftSnapshot: Equatable, Identifiable {
    let id: String
    let draftID: String
    /// Empty for a plain automatic snapshot (show "Automatic").
    let label: String
    let auto: Bool
    let words: Int
    /// Relative to the library folder: "drafts/.history/<draftID>/<id>.zip".
    let bundlePath: String
    let createdAt: String
}

enum StoredDiffKind: Equatable {
    case same, removed, added
}

struct StoredDiffLine: Equatable {
    let kind: StoredDiffKind
    let text: String
}

// MARK: - Store

final class DraftHistoryStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    private var root: URL { model.library.root }

    private func historyFolder(_ draftID: String) -> URL {
        model.library.draftsURL
            .appendingPathComponent(".history", isDirectory: true)
            .appendingPathComponent(draftID, isDirectory: true)
    }

    // MARK: Take

    /// Saves a zipped copy of the draft's folder.
    @discardableResult
    func takeSnapshot(draftID: String, label: String = "", auto: Bool = false) throws -> StoredDraftSnapshot {

        let info = try draftInfo(draftID)
        let folder = root.appendingPathComponent(info.folder, isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.path) else { throw ModelError.fileMissing(info.folder) }

        let id = model.newID()
        let relative = "drafts/.history/\(draftID)/\(id).zip"
        let zip = root.appendingPathComponent(relative)
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.countWords(inFolder: folder)

        try fileManager.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.ditto(["-c", "-k", "--norsrc", "--noextattr", "--noqtn", folder.path, zip.path])

        do {
            return try model.atomically {
                let now = model.now()
                try model.database.run(
                    """
                    INSERT INTO draft_snapshots (id, draft_id, label, auto, words, bundle_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(id), .text(draftID), .text(cleanLabel), LibraryModel.bool(auto),
                     .int(Int64(words)), .text(relative), .text(now)]
                )
                let created = StoredDraftSnapshot(
                    id: id, draftID: draftID, label: cleanLabel, auto: auto,
                    words: words, bundlePath: relative, createdAt: now
                )
                try model.record("draft_snapshot", id, .create, field: "snapshot", new: Self.snapshotJSON(created))
                return created
            }
        } catch {
            try? fileManager.removeItem(at: zip)     // no row, so no zip either
            throw error
        }
    }

    /// The automatic snapshot: taken when the draft was edited since the last snapshot AND
    /// at least `minimumMinutes` have passed (default 30). A draft with no snapshot yet gets one.
    /// Returns nil when nothing was taken.
    @discardableResult
    func takeAutomaticSnapshotIfDue(
        draftID: String,
        now: Date = Date(),
        minimumMinutes: Int = 30
    ) throws -> StoredDraftSnapshot? {

        let info = try draftInfo(draftID)

        if let last = try snapshots(forDraft: draftID).first {
            guard let lastDate = Self.parse(last.createdAt), let edited = Self.parse(info.updatedAt) else { return nil }
            if edited <= lastDate { return nil }                                           // nothing edited since
            if now.timeIntervalSince(lastDate) < Double(minimumMinutes) * 60 { return nil } // too soon
        }
        return try takeSnapshot(draftID: draftID, label: "", auto: true)
    }

    // MARK: Read

    /// Newest first.
    func snapshots(forDraft draftID: String) throws -> [StoredDraftSnapshot] {
        try model.database.rows(
            "SELECT * FROM draft_snapshots WHERE draft_id = ? ORDER BY created_at DESC, rowid DESC",
            [.text(draftID)]
        ).map { try Self.snapshot(from: $0) }
    }

    func snapshot(id: String) throws -> StoredDraftSnapshot? {
        guard let row = try model.database.rows("SELECT * FROM draft_snapshots WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.snapshot(from: row)
    }

    func count(forDraft draftID: String) throws -> Int {
        Int(try model.database.scalarInt(
            "SELECT COUNT(*) FROM draft_snapshots WHERE draft_id = ?", [.text(draftID)]
        ) ?? 0)
    }

    /// One file as it was when the snapshot was taken.
    func fileText(snapshotID: String, path: String) throws -> String {
        let snap = try require(snapshotID)
        return try withExtracted(snap) { folder in
            let url = try Self.fileURL(in: folder, path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.fileMissing(path) }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                throw ModelError.fileUnreadable(path)
            }
            return text
        }
    }

    /// Compares a file in the snapshot with the same file now (default: the draft's main file).
    /// A file that is missing on one side counts as empty on that side.
    func diff(snapshotID: String, path: String? = nil) throws -> [StoredDiffLine] {
        let snap = try require(snapshotID)
        let info = try draftInfo(snap.draftID)
        let file = path ?? info.mainFile

        let current = root.appendingPathComponent(info.folder, isDirectory: true)
        let currentURL = try Self.fileURL(in: current, path: file)
        let currentText = try Self.readTextIfPresent(currentURL, name: file)

        let oldText: String? = try withExtracted(snap) { folder in
            try Self.readTextIfPresent(try Self.fileURL(in: folder, path: file), name: file)
        }

        if oldText == nil && currentText == nil { throw ModelError.fileMissing(file) }
        return Self.diffLines(old: oldText ?? "", new: currentText ?? "")
    }

    // MARK: Edit

    /// For naming a snapshot ("Sent to supervisor"). An empty label goes back to "Automatic".
    @discardableResult
    func setLabel(snapshotID: String, to label: String) throws -> StoredDraftSnapshot {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return try model.atomically {
            let existing = try require(snapshotID)
            if existing.label == clean { return existing }

            try model.database.run("UPDATE draft_snapshots SET label = ? WHERE id = ?", [.text(clean), .text(snapshotID)])
            try model.record("draft_snapshot", snapshotID, .update, field: "label", old: existing.label, new: clean)

            return StoredDraftSnapshot(
                id: existing.id, draftID: existing.draftID, label: clean, auto: existing.auto,
                words: existing.words, bundlePath: existing.bundlePath, createdAt: existing.createdAt
            )
        }
    }

    // MARK: Restore

    /// Puts the draft folder back the way it was in the snapshot. A safety snapshot of the
    /// current folder is saved first and returned, so the restore itself can be undone.
    @discardableResult
    func restore(snapshotID: String) throws -> StoredDraftSnapshot {

        let snap = try require(snapshotID)
        let info = try draftInfo(snap.draftID)
        let fileManager = FileManager.default

        let zip = root.appendingPathComponent(snap.bundlePath)
        guard fileManager.fileExists(atPath: zip.path) else { throw ModelError.fileMissing(snap.bundlePath) }

        // Work area beside the history zips: same drive, so the swap below is a rename.
        let work = model.library.draftsURL
            .appendingPathComponent(".history", isDirectory: true)
            .appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        var keepWork = false      // set if putting the old folder back fails: then its copy must not be deleted
        defer { if !keepWork { try? fileManager.removeItem(at: work) } }

        // 1. Unpack and check BEFORE touching anything.
        let restored = work.appendingPathComponent("restored", isDirectory: true)
        try Self.ditto(["-x", "-k", zip.path, restored.path])

        let mainURL = try Self.fileURL(in: restored, path: info.mainFile)
        guard fileManager.fileExists(atPath: mainURL.path) else {
            throw ModelError.invalidValue("that version has no \(info.mainFile), which is this draft's main file")
        }

        // 2. Safety snapshot of the current folder.
        let shown = snap.label.isEmpty ? "an earlier version" : "“\(snap.label)”"
        let safety = try takeSnapshot(draftID: snap.draftID, label: "Before restoring \(shown)", auto: true)

        // 3. Swap the folders; put the current one back if anything goes wrong.
        let folder = root.appendingPathComponent(info.folder, isDirectory: true)
        let previous = work.appendingPathComponent("previous", isDirectory: true)

        try fileManager.moveItem(at: folder, to: previous)
        do {
            try fileManager.moveItem(at: restored, to: folder)
        } catch {
            do { try fileManager.moveItem(at: previous, to: folder) } catch { keepWork = true }
            throw error
        }

        do {
            try model.atomically {
                try model.database.run("UPDATE drafts SET updated_at = ? WHERE id = ?",
                                       [.text(model.now()), .text(snap.draftID)])
                try model.record("draft_snapshot", snap.id, .restore, field: "folder", old: safety.id, new: snap.id)
            }
        } catch {
            // Undo the swap.
            do {
                try fileManager.moveItem(at: folder, to: restored)
                try fileManager.moveItem(at: previous, to: folder)
            } catch {
                keepWork = true
            }
            throw error
        }

        return safety
    }

    // MARK: Remove

    /// Deletes one snapshot (row and zip).
    func remove(snapshotID: String) throws {
        let existing: StoredDraftSnapshot = try model.atomically {
            let found = try require(snapshotID)
            try model.database.run("DELETE FROM draft_snapshots WHERE id = ?", [.text(snapshotID)])
            try model.record("draft_snapshot", snapshotID, .delete, field: "snapshot",
                             old: Self.snapshotJSON(found), new: nil)
            return found
        }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(existing.bundlePath))
    }

    /// Deletes every snapshot of a draft, and the draft's history folder. Returns how many were removed.
    /// Use after a draft is deleted forever (its rows go automatically, its zips do not).
    @discardableResult
    func removeAll(forDraft draftID: String) throws -> Int {
        let removed: [StoredDraftSnapshot] = try model.atomically {
            let all = try snapshots(forDraft: draftID)
            for item in all {
                try model.database.run("DELETE FROM draft_snapshots WHERE id = ?", [.text(item.id)])
                try model.record("draft_snapshot", item.id, .delete, field: "snapshot",
                                 old: Self.snapshotJSON(item), new: nil)
            }
            return all
        }
        try? FileManager.default.removeItem(at: historyFolder(draftID))
        return removed.count
    }

    /// Keeps the newest `keepLatest` automatic snapshots without a label and deletes the older ones.
    /// Named snapshots and the ones taken before a template change, restore or submission are never touched.
    @discardableResult
    func pruneAutomatic(forDraft draftID: String, keepLatest: Int = 50) throws -> Int {
        guard keepLatest >= 0 else { throw ModelError.invalidValue("keepLatest cannot be negative") }
        let plain = try snapshots(forDraft: draftID).filter { $0.auto && $0.label.isEmpty }
        let doomed = Array(plain.dropFirst(keepLatest))
        for item in doomed { try remove(snapshotID: item.id) }
        return doomed.count
    }

    // MARK: Differences

    /// Line-by-line comparison (the same idea as the mockup): common lines are "same",
    /// lines only in `old` are "removed", lines only in `new` are "added".
    /// Huge changes (more than about 16 million line pairs after trimming) are shown as one removed block and one added block.
    static func diffLines(old: String, new: String) -> [StoredDiffLine] {

        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }

        let midA = Array(a[prefix..<(a.count - suffix)])
        let midB = Array(b[prefix..<(b.count - suffix)])

        var result: [StoredDiffLine] = a[0..<prefix].map { StoredDiffLine(kind: .same, text: $0) }

        let n = midA.count
        let m = midB.count

        if n * m > 16_000_000 {
            result += midA.map { StoredDiffLine(kind: .removed, text: $0) }
            result += midB.map { StoredDiffLine(kind: .added, text: $0) }
        } else {
            // Longest-common-subsequence table, filled from the end.
            let width = m + 1
            var table = [Int32](repeating: 0, count: (n + 1) * width)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i * width + j] = midA[i] == midB[j]
                            ? table[(i + 1) * width + (j + 1)] + 1
                            : max(table[(i + 1) * width + j], table[i * width + (j + 1)])
                    }
                }
            }
            var i = 0
            var j = 0
            while i < n && j < m {
                if midA[i] == midB[j] {
                    result.append(StoredDiffLine(kind: .same, text: midA[i]))
                    i += 1
                    j += 1
                } else if table[(i + 1) * width + j] >= table[i * width + (j + 1)] {
                    result.append(StoredDiffLine(kind: .removed, text: midA[i]))
                    i += 1
                } else {
                    result.append(StoredDiffLine(kind: .added, text: midB[j]))
                    j += 1
                }
            }
            while i < n { result.append(StoredDiffLine(kind: .removed, text: midA[i])); i += 1 }
            while j < m { result.append(StoredDiffLine(kind: .added, text: midB[j])); j += 1 }
        }

        let tail = a[(a.count - suffix)...]
        result += tail.map { StoredDiffLine(kind: .same, text: $0) }
        return result
    }

    // MARK: Words

    /// Approximate words in LaTeX source: comments, commands and citation/label keys are not counted.
    static func countWords(inLatex text: String) -> Int {
        var total = 0
        for line in text.components(separatedBy: "\n") {
            var work = line
            if let comment = work.range(of: "(?<!\\\\)%", options: .regularExpression) {
                work = String(work[..<comment.lowerBound])
            }
            work = work.replacingOccurrences(
                of: "\\\\(?:begin|end|cite[A-Za-z]*|ref|eqref|label|usepackage|documentclass|bibliography|bibliographystyle|include|input|includegraphics)\\*?(?:\\[[^\\]]*\\])*\\{[^}]*\\}",
                with: " ", options: .regularExpression
            )
            work = work.replacingOccurrences(of: "\\\\[A-Za-z]+\\*?", with: " ", options: .regularExpression)
            work = work.replacingOccurrences(of: "[{}\\[\\]$&~^_\\\\]", with: " ", options: .regularExpression)
            total += work.split(whereSeparator: { $0.isWhitespace })
                .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
                .count
        }
        return total
    }

    private static func countWords(inFolder folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let url as URL in walker where url.pathExtension.lowercased() == "tex" {
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                total += countWords(inLatex: text)
            }
        }
        return total
    }

    // MARK: Helpers

    private func require(_ id: String) throws -> StoredDraftSnapshot {
        guard let found = try snapshot(id: id) else { throw ModelError.notFound(kind: "snapshot", id: id) }
        return found
    }

    /// What this file needs to know about a draft that is not in the Trash.
    private func draftInfo(_ draftID: String) throws -> (folder: String, mainFile: String, updatedAt: String) {
        guard let row = try model.database.rows(
            "SELECT folder, main_file, updated_at FROM drafts WHERE id = ? AND deleted_at IS NULL", [.text(draftID)]
        ).first, let folder = row.text("folder"), let updatedAt = row.text("updated_at") else {
            throw ModelError.notFound(kind: "draft", id: draftID)
        }
        return (folder, row.text("main_file") ?? "main.tex", updatedAt)
    }

    /// Unpacks a snapshot into a temporary folder, runs `body` on it, and always cleans up.
    private func withExtracted<T>(_ snap: StoredDraftSnapshot, _ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let zip = root.appendingPathComponent(snap.bundlePath)
        guard fileManager.fileExists(atPath: zip.path) else { throw ModelError.fileMissing(snap.bundlePath) }

        let temp = fileManager.temporaryDirectory.appendingPathComponent("RBHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temp) }

        let folder = temp.appendingPathComponent("snapshot", isDirectory: true)
        try Self.ditto(["-x", "-k", zip.path, folder.path])
        return try body(folder)
    }

    /// The text of a file, or nil when the file does not exist.
    private static func readTextIfPresent(_ url: URL, name: String) throws -> String? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { throw ModelError.invalidValue("\(name) is a folder") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ModelError.fileUnreadable(name)
        }
        return text
    }

    /// "chapters/intro.tex" inside `folder`, or a refusal for anything that could leave it.
    private static func fileURL(in folder: URL, path: String) throws -> URL {
        let parts = path.components(separatedBy: "/")
        guard !path.isEmpty,
              !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0"), !path.contains("\\"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModelError.invalidValue("path “\(path)” is not allowed")
        }
        var url = folder
        for part in parts { url = url.appendingPathComponent(part) }

        let rootPath = folder.resolvingSymlinksInPath().path
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != folder.path {
            probe = probe.deletingLastPathComponent()
        }
        let real = probe.resolvingSymlinksInPath().path
        guard real == rootPath || real.hasPrefix(rootPath + "/") else {
            throw ModelError.invalidValue("path “\(path)” is outside the draft folder")
        }
        return url
    }

    /// Runs the Mac's `ditto` tool (zip and unzip).
    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ModelError.invalidValue("the zip tool could not be started")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ModelError.invalidValue("the zip tool failed" + (message.isEmpty ? "" : ": \(message)"))
        }
    }

    private static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Rows and snapshots

    static func snapshot(from row: SQLRow) throws -> StoredDraftSnapshot {
        guard let id = row.text("id"),
              let draftID = row.text("draft_id"),
              let bundlePath = row.text("bundle_path"),
              let createdAt = row.text("created_at") else {
            throw ModelError.invalidValue("snapshot row")
        }
        return StoredDraftSnapshot(
            id: id,
            draftID: draftID,
            label: row.text("label") ?? "",
            auto: (row.int("auto") ?? 1) != 0,
            words: Int(row.int("words") ?? 0),
            bundlePath: bundlePath,
            createdAt: createdAt
        )
    }

    private static func snapshotJSON(_ item: StoredDraftSnapshot) -> String {
        LibraryModel.json([
            "id": item.id,
            "draft_id": item.draftID,
            "label": item.label,
            "auto": item.auto ? 1 : 0,
            "words": item.words,
            "bundle_path": item.bundlePath,
            "created_at": item.createdAt
        ] as [String: Any])
    }
}
