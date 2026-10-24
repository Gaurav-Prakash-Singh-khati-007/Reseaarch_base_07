//
//  DraftFolderStore.swift
//  ResearchBase
//
//  Owner: Agent 20 · Features: F-29
//
//  Each draft is a real folder on disk (ResearchBase Library/drafts/<id>/ with
//  main.tex, refs.bib, figures/ and, for a thesis, chapters/), so it opens in
//  Overleaf, TeXShop or VS Code. This file keeps the `drafts` table and does
//  the safe file work inside a draft's folder: list, read, write, add, rename,
//  delete. It also serves the file tree (L-12) and the writing screens.
//
//  PUBLIC API
//    Types
//      StoredDraftKind            paper, thesis, report, chapter, other
//      StoredDraftStage           draft, submitted, underReview, revision, accepted, published
//      StoredDraft                one row of `drafts`
//      StoredDraftFile            one file or folder inside a draft folder
//    DraftFolderStore(model: LibraryModel)
//      var useSystemTrash: Bool                       true = deleted files go to the Mac's Trash (default)
//      create(title:kind:templateID:templateVersion:mainTex:bibStyle:cslStyle:engine:wordGoal:) throws -> StoredDraft
//      draft(id:includeDeleted:) throws -> StoredDraft?
//      all(includeArchived:) throws -> [StoredDraft]  newest edit first, not in the Trash
//      trashed() throws -> [StoredDraft]
//      count() throws -> Int
//      folderURL(for: StoredDraft) -> URL
//      setTitle / setKind / setStage / setEngine / setBibStyle / setCSLStyle / setWordGoal / setArchived
//      setTemplate(id:templateID:templateVersion:) / setMainFile(id:to:)
//      files(in:) throws -> [StoredDraftFile]
//      readText(draftID:path:) throws -> String
//      writeText(draftID:path:text:) throws                 saved in one step, so a crash never leaves half a file
//      addFile(draftID:path:data:) throws -> String         refuses to overwrite
//      importFile(draftID:from:toFolder:) throws -> String  copies a file in (for example a figure)
//      createFolder(draftID:path:) throws
//      renameFile(draftID:from:to:) throws                  also moves `main_file` if you rename it
//      deleteFile(draftID:path:) throws                     refuses the main file
//      moveToTrash(id:) / restore(id:) / deleteForever(id:)
//      touch(id:) throws                                    marks the draft as just edited
//
//  Notes
//    * Paths are always relative to the draft's folder, like "chapters/intro.tex".
//      Absolute paths, "..", and anything that would reach outside the folder
//      (even through a symbolic link) are refused.
//    * Text changes inside files are not reported to the change sink (they are not
//      database changes); the draft's `updated_at` is moved instead. History
//      snapshots belong to DraftHistoryStore.
//    * moveToTrash keeps the folder on disk. deleteForever only works on a draft that
//      is already in the Trash and refuses while a submission still points at it.
//      History snapshot files (draft_snapshots) are not touched here.
//    * refs.bib is created empty; filling it is the job of the bibliography code.
//    * Names start with "Stored" to stay clear of types the screens already use.
//

import Foundation

// MARK: - Types

enum StoredDraftKind: String, CaseIterable, Equatable {
    case paper, thesis, report, chapter, other
}

enum StoredDraftStage: String, CaseIterable, Equatable {
    case draft
    case submitted
    case underReview = "under_review"
    case revision
    case accepted
    case published

    var label: String {
        switch self {
        case .draft: return "Draft"
        case .submitted: return "Submitted"
        case .underReview: return "Under review"
        case .revision: return "Revision"
        case .accepted: return "Accepted"
        case .published: return "Published"
        }
    }
}

struct StoredDraft: Equatable, Identifiable {
    let id: String
    let title: String
    let kind: StoredDraftKind
    /// Relative to the library folder: "drafts/<id>".
    let folder: String
    let mainFile: String
    let templateID: String?
    let templateVersion: String?
    let engine: String
    let bibStyle: String
    let cslStyle: String
    let stage: StoredDraftStage
    let wordGoal: Int?
    let archived: Bool
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
}

struct StoredDraftFile: Equatable, Identifiable {
    /// Relative to the draft folder, like "figures/accuracy.pdf".
    let path: String
    let isFolder: Bool
    let size: Int

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Store

final class DraftFolderStore {

    unowned let model: LibraryModel

    /// Deleted files go to the Mac's Trash so they can be put back. Tests switch this off.
    var useSystemTrash = true

    init(model: LibraryModel) {
        self.model = model
    }

    private static let starterTex = """
    \\documentclass{article}
    \\begin{document}

    \\end{document}
    """

    // MARK: Create

    @discardableResult
    func create(
        title: String,
        kind: StoredDraftKind = .paper,
        templateID: String? = nil,
        templateVersion: String? = nil,
        mainTex: String? = nil,
        bibStyle: String = "plainnat",
        cslStyle: String = "ieee",
        engine: String = "latexmk-pdflatex",
        wordGoal: Int? = nil
    ) throws -> StoredDraft {

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw ModelError.emptyName }
        if let wordGoal, wordGoal < 0 { throw ModelError.invalidValue("word goal cannot be negative") }

        let id = model.newID()
        let folderPath = "drafts/\(id)"
        let folder = model.library.root.appendingPathComponent(folderPath, isDirectory: true)
        let fileManager = FileManager.default

        // Files first; if anything fails afterwards the new folder is removed again.
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: folder.appendingPathComponent("figures", isDirectory: true),
                                            withIntermediateDirectories: true)
            if kind == .thesis {
                try fileManager.createDirectory(at: folder.appendingPathComponent("chapters", isDirectory: true),
                                                withIntermediateDirectories: true)
            }
            let text = (mainTex?.isEmpty == false) ? mainTex! : Self.starterTex
            try Data(text.utf8).write(to: folder.appendingPathComponent("main.tex"), options: .atomic)
            try Data().write(to: folder.appendingPathComponent("refs.bib"), options: .atomic)

            return try model.atomically {
                let now = model.now()
                try model.database.run(
                    """
                    INSERT INTO drafts (id, title, kind, folder, main_file, template_id, template_version, engine,
                                        bib_style, csl_style, stage, word_goal, archived, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 'main.tex', ?, ?, ?, ?, ?, 'draft', ?, 0, ?, ?)
                    """,
                    [.text(id), .text(cleanTitle), .text(kind.rawValue), .text(folderPath),
                     LibraryModel.text(templateID), LibraryModel.text(templateVersion), .text(engine),
                     .text(bibStyle), .text(cslStyle), LibraryModel.int(wordGoal), .text(now), .text(now)]
                )
                guard let created = try draft(id: id) else { throw ModelError.notFound(kind: "draft", id: id) }
                try model.record("draft", id, .create, field: "draft", new: Self.snapshot(created))
                return created
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    // MARK: Read

    func draft(id: String, includeDeleted: Bool = false) throws -> StoredDraft? {
        let sql = "SELECT * FROM drafts WHERE id = ?" + (includeDeleted ? "" : " AND deleted_at IS NULL")
        guard let row = try model.database.rows(sql, [.text(id)]).first else { return nil }
        return try Self.draft(from: row)
    }

    /// Not in the Trash, newest edit first.
    func all(includeArchived: Bool = false) throws -> [StoredDraft] {
        var sql = "SELECT * FROM drafts WHERE deleted_at IS NULL"
        if !includeArchived { sql += " AND archived = 0" }
        sql += " ORDER BY updated_at DESC, id"
        return try model.database.rows(sql).map { try Self.draft(from: $0) }
    }

    func trashed() throws -> [StoredDraft] {
        try model.database.rows("SELECT * FROM drafts WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, id")
            .map { try Self.draft(from: $0) }
    }

    func count() throws -> Int {
        Int(try model.database.scalarInt("SELECT COUNT(*) FROM drafts WHERE deleted_at IS NULL") ?? 0)
    }

    func folderURL(for draft: StoredDraft) -> URL {
        model.library.root.appendingPathComponent(draft.folder, isDirectory: true)
    }

    // MARK: Edit

    @discardableResult
    func setTitle(id: String, to title: String) throws -> StoredDraft {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ModelError.emptyName }
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "title", column: "title", value: .text(clean), old: existing.title, new: clean)
        }
    }

    @discardableResult
    func setKind(id: String, to kind: StoredDraftKind) throws -> StoredDraft {
        try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "kind", column: "kind", value: .text(kind.rawValue),
                              old: existing.kind.rawValue, new: kind.rawValue)
        }
    }

    @discardableResult
    func setStage(id: String, to stage: StoredDraftStage) throws -> StoredDraft {
        try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "stage", column: "stage", value: .text(stage.rawValue),
                              old: existing.stage.rawValue, new: stage.rawValue)
        }
    }

    @discardableResult
    func setEngine(id: String, to engine: String) throws -> StoredDraft {
        let clean = engine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ModelError.invalidValue("engine is empty") }
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "engine", column: "engine", value: .text(clean), old: existing.engine, new: clean)
        }
    }

    @discardableResult
    func setBibStyle(id: String, to style: String) throws -> StoredDraft {
        let clean = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ModelError.invalidValue("bibliography style is empty") }
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "bib_style", column: "bib_style", value: .text(clean),
                              old: existing.bibStyle, new: clean)
        }
    }

    @discardableResult
    func setCSLStyle(id: String, to style: String) throws -> StoredDraft {
        let clean = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ModelError.invalidValue("citation style is empty") }
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "csl_style", column: "csl_style", value: .text(clean),
                              old: existing.cslStyle, new: clean)
        }
    }

    /// Pass nil to clear the goal.
    @discardableResult
    func setWordGoal(id: String, to goal: Int?) throws -> StoredDraft {
        if let goal, goal < 0 { throw ModelError.invalidValue("word goal cannot be negative") }
        return try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "word_goal", column: "word_goal", value: LibraryModel.int(goal),
                              old: existing.wordGoal.map(String.init), new: goal.map(String.init))
        }
    }

    @discardableResult
    func setArchived(id: String, to archived: Bool) throws -> StoredDraft {
        try model.atomically {
            let existing = try require(id)
            return try change(existing, field: "archived", column: "archived", value: LibraryModel.bool(archived),
                              old: existing.archived ? "1" : "0", new: archived ? "1" : "0")
        }
    }

    /// Which template (and version) the draft started from. Pass nil for both to clear.
    @discardableResult
    func setTemplate(id: String, templateID: String?, templateVersion: String?) throws -> StoredDraft {
        try model.atomically {
            let existing = try require(id)
            if existing.templateID == templateID && existing.templateVersion == templateVersion { return existing }

            try model.database.run(
                "UPDATE drafts SET template_id = ?, template_version = ?, updated_at = ? WHERE id = ?",
                [LibraryModel.text(templateID), LibraryModel.text(templateVersion), .text(model.now()), .text(id)]
            )
            if existing.templateID != templateID {
                try model.record("draft", id, .update, field: "template_id", old: existing.templateID, new: templateID)
            }
            if existing.templateVersion != templateVersion {
                try model.record("draft", id, .update, field: "template_version",
                                 old: existing.templateVersion, new: templateVersion)
            }
            return try require(id)
        }
    }

    /// The file the build starts from. It must exist inside the folder.
    @discardableResult
    func setMainFile(id: String, to path: String) throws -> StoredDraft {
        try model.atomically {
            let existing = try require(id)
            let url = try resolve(existing, path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
                throw ModelError.fileMissing(path)
            }
            return try change(existing, field: "main_file", column: "main_file", value: .text(path),
                              old: existing.mainFile, new: path)
        }
    }

    /// Marks the draft as just edited (the list shows newest edits first).
    func touch(id: String) throws {
        _ = try require(id)
        try model.database.run("UPDATE drafts SET updated_at = ? WHERE id = ?", [.text(model.now()), .text(id)])
    }

    // MARK: Files

    /// Everything in the draft folder (hidden files skipped), sorted by path.
    func files(in draftID: String) throws -> [StoredDraftFile] {
        let draft = try require(draftID)
        let root = folderURL(for: draft)
        guard FileManager.default.fileExists(atPath: root.path) else { throw ModelError.fileMissing(draft.folder) }

        let rootPath = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [StoredDraftFile] = []
        for case let url as URL in walker {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            found.append(StoredDraftFile(
                path: String(full.dropFirst(rootPath.count + 1)),
                isFolder: values?.isDirectory ?? false,
                size: values?.fileSize ?? 0
            ))
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func readText(draftID: String, path: String) throws -> String {
        let draft = try require(draftID)
        let url = try resolve(draft, path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.fileMissing(path) }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ModelError.fileUnreadable(path)
        }
        return text
    }

    /// Saves text to a file in one step (written beside it, then swapped in), creating
    /// the file and any missing folders. Moves the draft's `updated_at`.
    func writeText(draftID: String, path: String, text: String) throws {
        let draft = try require(draftID)
        let url = try resolve(draft, path)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            throw ModelError.invalidValue("\(path) is a folder")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        try touch(id: draftID)
    }

    /// Adds a new file (empty unless `data` is given). Refuses to overwrite. Returns the path.
    @discardableResult
    func addFile(draftID: String, path: String, data: Data = Data()) throws -> String {
        let draft = try require(draftID)
        let url = try resolve(draft, path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ModelError.invalidValue("\(path) already exists")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try touch(id: draftID)
        return path
    }

    /// Copies a file from anywhere into a folder of the draft (default figures/). The original is untouched.
    /// Refuses to overwrite. Returns the new path.
    @discardableResult
    func importFile(draftID: String, from source: URL, toFolder folder: String = "figures") throws -> String {
        let draft = try require(draftID)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ModelError.fileMissing(source.lastPathComponent)
        }
        let path = folder.isEmpty ? source.lastPathComponent : "\(folder)/\(source.lastPathComponent)"
        let target = try resolve(draft, path)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ModelError.invalidValue("\(path) already exists")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        try touch(id: draftID)
        return path
    }

    func createFolder(draftID: String, path: String) throws {
        let draft = try require(draftID)
        let url = try resolve(draft, path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ModelError.invalidValue("\(path) already exists")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try touch(id: draftID)
    }

    /// Renames or moves a file or folder inside the draft. If it is (or contains) the main
    /// file, `main_file` follows it. Refuses to overwrite.
    func renameFile(draftID: String, from oldPath: String, to newPath: String) throws {
        try model.atomically {
            let draft = try require(draftID)
            let source = try resolve(draft, oldPath)
            let target = try resolve(draft, newPath)
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: source.path) else { throw ModelError.fileMissing(oldPath) }
            guard !fileManager.fileExists(atPath: target.path) else {
                throw ModelError.invalidValue("\(newPath) already exists")
            }

            var newMain: String? = nil
            if draft.mainFile == oldPath {
                newMain = newPath
            } else if draft.mainFile.hasPrefix(oldPath + "/") {
                newMain = newPath + String(draft.mainFile.dropFirst(oldPath.count))
            }

            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: target)

            do {
                if let newMain {
                    try model.database.run("UPDATE drafts SET main_file = ?, updated_at = ? WHERE id = ?",
                                           [.text(newMain), .text(model.now()), .text(draftID)])
                    try model.record("draft", draftID, .update, field: "main_file", old: draft.mainFile, new: newMain)
                } else {
                    try touch(id: draftID)
                }
            } catch {
                try? fileManager.moveItem(at: target, to: source)   // put it back
                throw error
            }
        }
    }

    /// Deletes a file or folder inside the draft. The main file cannot be deleted.
    func deleteFile(draftID: String, path: String) throws {
        let draft = try require(draftID)
        let url = try resolve(draft, path)

        guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.fileMissing(path) }
        if draft.mainFile == path || draft.mainFile.hasPrefix(path + "/") {
            throw ModelError.invalidValue("the main file cannot be deleted")
        }
        try discard(url)
        try touch(id: draftID)
    }

    // MARK: Trash

    /// Puts the draft in the Trash. Its folder stays where it is.
    func moveToTrash(id: String) throws {
        try model.atomically {
            let existing = try require(id)
            let now = model.now()
            try model.database.run("UPDATE drafts SET deleted_at = ?, updated_at = ? WHERE id = ?",
                                   [.text(now), .text(now), .text(id)])
            try model.record("draft", id, .delete, field: "deleted_at", old: existing.deletedAt, new: now)
        }
    }

    @discardableResult
    func restore(id: String) throws -> StoredDraft {
        try model.atomically {
            guard let existing = try draft(id: id, includeDeleted: true), let was = existing.deletedAt else {
                throw ModelError.notFound(kind: "draft", id: id)
            }
            try model.database.run("UPDATE drafts SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                                   [.text(model.now()), .text(id)])
            try model.record("draft", id, .restore, field: "deleted_at", old: was, new: nil)
            return try require(id)
        }
    }

    /// Removes a draft that is already in the Trash: the row (with its citations, snapshots
    /// and comments) and then its folder. Refused while a submission still points at it.
    func deleteForever(id: String) throws {
        let existing: StoredDraft = try model.atomically {
            guard let found = try draft(id: id, includeDeleted: true), found.deletedAt != nil else {
                throw ModelError.notFound(kind: "draft", id: id)
            }
            let submissions = Int(try model.database.scalarInt(
                "SELECT COUNT(*) FROM submissions WHERE draft_id = ?", [.text(id)]
            ) ?? 0)
            if submissions > 0 {
                throw ModelError.invalidValue(
                    "\(submissions) submission\(submissions == 1 ? "" : "s") still refer to this writing project"
                )
            }
            try model.database.run("DELETE FROM drafts WHERE id = ?", [.text(id)])
            try model.record("draft", id, .delete, field: "draft", old: Self.snapshot(found), new: nil)
            return found
        }

        // The row is gone. A folder that cannot be removed is left alone rather than failing here.
        let folder = folderURL(for: existing)
        if FileManager.default.fileExists(atPath: folder.path) {
            try? discard(folder)
        }
    }

    // MARK: Helpers

    private func require(_ id: String) throws -> StoredDraft {
        guard let found = try draft(id: id) else { throw ModelError.notFound(kind: "draft", id: id) }
        return found
    }

    /// Writes one column and moves `updated_at`. `column` always comes from a fixed list in this file.
    private func change(
        _ existing: StoredDraft,
        field: String,
        column: String,
        value: SQLValue,
        old: String?,
        new: String?
    ) throws -> StoredDraft {
        if old == new { return existing }
        try model.database.run("UPDATE drafts SET \(column) = ?, updated_at = ? WHERE id = ?",
                               [value, .text(model.now()), .text(existing.id)])
        try model.record("draft", existing.id, .update, field: field, old: old, new: new)
        return try require(existing.id)
    }

    private func discard(_ url: URL) throws {
        if useSystemTrash {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // Not possible here (for example on a drive without a Trash): fall through to a plain delete.
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Turns "chapters/intro.tex" into a real URL inside the draft folder, or refuses.
    private func resolve(_ draft: StoredDraft, _ path: String) throws -> URL {
        let parts = path.components(separatedBy: "/")
        guard !path.isEmpty,
              !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0"), !path.contains("\\"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModelError.invalidValue("path “\(path)” is not allowed")
        }

        let root = folderURL(for: draft)
        var url = root
        for part in parts { url = url.appendingPathComponent(part) }

        // Even through a symbolic link, the real location must stay inside the folder.
        let rootPath = root.resolvingSymlinksInPath().path
        let fileManager = FileManager.default
        var probe = url
        while !fileManager.fileExists(atPath: probe.path) && probe.path != root.path {
            probe = probe.deletingLastPathComponent()
        }
        let real = probe.resolvingSymlinksInPath().path
        guard real == rootPath || real.hasPrefix(rootPath + "/") else {
            throw ModelError.invalidValue("path “\(path)” is outside the draft folder")
        }
        return url
    }

    // MARK: Rows and snapshots

    static func draft(from row: SQLRow) throws -> StoredDraft {
        guard let id = row.text("id"),
              let title = row.text("title"),
              let kindText = row.text("kind"), let kind = StoredDraftKind(rawValue: kindText),
              let folder = row.text("folder"),
              let stageText = row.text("stage"), let stage = StoredDraftStage(rawValue: stageText),
              let createdAt = row.text("created_at"),
              let updatedAt = row.text("updated_at") else {
            throw ModelError.invalidValue("draft row")
        }
        return StoredDraft(
            id: id,
            title: title,
            kind: kind,
            folder: folder,
            mainFile: row.text("main_file") ?? "main.tex",
            templateID: row.text("template_id"),
            templateVersion: row.text("template_version"),
            engine: row.text("engine") ?? "latexmk-pdflatex",
            bibStyle: row.text("bib_style") ?? "plainnat",
            cslStyle: row.text("csl_style") ?? "ieee",
            stage: stage,
            wordGoal: row.int("word_goal").map { Int($0) },
            archived: (row.int("archived") ?? 0) != 0,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: row.text("deleted_at")
        )
    }

    private static func snapshot(_ item: StoredDraft) -> String {
        LibraryModel.json([
            "id": item.id,
            "title": item.title,
            "kind": item.kind.rawValue,
            "folder": item.folder,
            "main_file": item.mainFile,
            "template_id": item.templateID ?? NSNull(),
            "template_version": item.templateVersion ?? NSNull(),
            "engine": item.engine,
            "bib_style": item.bibStyle,
            "csl_style": item.cslStyle,
            "stage": item.stage.rawValue,
            "word_goal": item.wordGoal ?? NSNull(),
            "archived": item.archived ? 1 : 0,
            "created_at": item.createdAt,
            "updated_at": item.updatedAt,
            "deleted_at": item.deletedAt ?? NSNull()
        ] as [String: Any])
    }
}
