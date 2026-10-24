//
//  TemplateStore.swift
//  ResearchBase
//
//  Owner: Agent 19 · Features: F-32, L-11
//
//  Writing templates with versions. A draft remembers the template and the
//  version it started with (`drafts.template_id` + `drafts.template_version`),
//  so an old paper rebuilds the same way even after a template is updated.
//  This file only keeps the template list (the `templates` table). It does
//  not copy files and does not change any draft.
//
//  PUBLIC API
//    Types
//      StoredTemplate            one version of one template
//    TemplateStore(model: LibraryModel)
//      register(key:name:version:documentClass:needsClassFile:bundlePath:bst:) throws -> StoredTemplate
//      registerBuiltIns() throws -> [StoredTemplate]          the six shipped templates (version 1.0), safe to call every launch
//      template(key:version:) throws -> StoredTemplate?
//      latest(key:) throws -> StoredTemplate?
//      resolve(key:version:) throws -> StoredTemplate?        a draft's template: exact version, or the latest when version is nil
//      versions(of key:) throws -> [StoredTemplate]           newest first
//      latestOfEach() throws -> [StoredTemplate]              one row per template (its newest version), by name
//      allVersions() throws -> [StoredTemplate]
//      newerVersion(than:) throws -> StoredTemplate?          a newer version of the same template, if any
//      draftCount(key:version:) throws -> Int                 drafts that started from that version
//      setNeedsClassFile(key:version:to:) throws -> StoredTemplate
//      remove(key:version:) throws                            refused while a draft uses that version
//      TemplateStore.compareVersions(_:_:) -> ComparisonResult
//
//  Notes
//    * Versions never change once saved. Registering the same key and version
//      again with the same content returns the existing row; with different
//      content it is refused. Make a new version instead.
//    * The schema makes `templates.id` the primary key, so two versions of one
//      template cannot share an id. The row id is therefore "<key>@<version>"
//      (for example "ieee@1.0"). The draft columns keep the plain key and
//      version. `StoredTemplate.key` and `.version` are what other code uses;
//      `.rowID` is only for the database.
//    * `bundlePath` is stored as given. Where the template files really live
//      (app resources, or a folder the user added) is decided by the caller.
//    * Names start with "Stored" to stay clear of types the screens already use.
//

import Foundation

// MARK: - Type

struct StoredTemplate: Equatable, Identifiable {
    let key: String
    let version: String
    let name: String
    let documentClass: String
    let needsClassFile: Bool
    let bundlePath: String
    let bst: String

    /// The database row id: "<key>@<version>".
    var rowID: String { "\(key)@\(version)" }

    var id: String { rowID }
}

// MARK: - Store

final class TemplateStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Register

    /// Saves one version of a template. The same key + version with the same content
    /// returns the existing row; with different content it is refused (versions never change).
    @discardableResult
    func register(
        key: String,
        name: String,
        version: String,
        documentClass: String,
        needsClassFile: Bool = false,
        bundlePath: String,
        bst: String = ""
    ) throws -> StoredTemplate {

        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentClass = documentClass.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundlePath = bundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let bst = bst.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { throw ModelError.emptyName }
        guard Self.isValidPart(key) else { throw ModelError.invalidValue("template key (use letters, digits, - _ .)") }
        guard Self.isValidPart(version) else { throw ModelError.invalidValue("template version (use letters, digits, - _ .)") }
        guard !documentClass.isEmpty else { throw ModelError.invalidValue("document class is empty") }
        guard !bundlePath.isEmpty else { throw ModelError.invalidValue("template folder is empty") }

        let wanted = StoredTemplate(
            key: key, version: version, name: name, documentClass: documentClass,
            needsClassFile: needsClassFile, bundlePath: bundlePath, bst: bst
        )

        return try model.atomically {

            if let existing = try template(key: key, version: version) {
                if existing == wanted { return existing }
                throw ModelError.invalidValue(
                    "version \(version) of “\(existing.name)” already exists with different content. Save it as a new version"
                )
            }

            try model.database.run(
                """
                INSERT INTO templates (id, name, version, document_class, needs_class_file, bundle_path, bst)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(wanted.rowID), .text(name), .text(version), .text(documentClass),
                 LibraryModel.bool(needsClassFile), .text(bundlePath), .text(bst)]
            )
            try model.record("template", wanted.rowID, .create, field: "template", new: Self.snapshot(wanted))
            return wanted
        }
    }

    /// The six templates the app ships with (version 1.0). Safe to call on every launch:
    /// ones that already exist are left exactly as they are.
    @discardableResult
    func registerBuiltIns() throws -> [StoredTemplate] {
        let builtIns: [(key: String, name: String, documentClass: String, bst: String, needsClassFile: Bool)] = [
            ("arxiv", "arXiv / plain article", "article", "plainnat", false),
            ("ieee", "IEEE conference", "IEEEtran", "IEEEtran", false),
            ("acm", "ACM (sigconf)", "acmart", "ACM-Reference-Format", false),
            ("springer", "Springer LNCS", "llncs", "splncs04", true),
            ("elsevier", "Elsevier (review)", "elsarticle", "elsarticle-num", false),
            ("thesis", "University thesis", "report", "plainnat", false)
        ]
        return try model.atomically {
            var result: [StoredTemplate] = []
            for item in builtIns {
                if let existing = try template(key: item.key, version: "1.0") {
                    result.append(existing)
                    continue
                }
                result.append(try register(
                    key: item.key, name: item.name, version: "1.0", documentClass: item.documentClass,
                    needsClassFile: item.needsClassFile, bundlePath: "bundled/\(item.key)/1.0", bst: item.bst
                ))
            }
            return result
        }
    }

    // MARK: Read

    func template(key: String, version: String) throws -> StoredTemplate? {
        let rowID = "\(key)@\(version)"
        guard let row = try model.database.rows("SELECT * FROM templates WHERE id = ?", [.text(rowID)]).first else {
            return nil
        }
        return try Self.template(from: row)
    }

    /// Newest version first.
    func versions(of key: String) throws -> [StoredTemplate] {
        try allVersions().filter { $0.key == key }
    }

    func latest(key: String) throws -> StoredTemplate? {
        try versions(of: key).first
    }

    /// What a draft should build with: its exact version, or the newest when it has none.
    func resolve(key: String, version: String?) throws -> StoredTemplate? {
        if let version, !version.isEmpty { return try template(key: key, version: version) }
        return try latest(key: key)
    }

    /// Every version of every template, by name, newest version first within a template.
    func allVersions() throws -> [StoredTemplate] {
        try model.database.rows("SELECT * FROM templates").map { try Self.template(from: $0) }
            .sorted { a, b in
                if a.key != b.key {
                    let byName = a.name.localizedCaseInsensitiveCompare(b.name)
                    if byName != .orderedSame { return byName == .orderedAscending }
                    return a.key < b.key
                }
                return Self.compareVersions(a.version, b.version) == .orderedDescending
            }
    }

    /// One row per template: its newest version. For the template picker.
    func latestOfEach() throws -> [StoredTemplate] {
        var seen = Set<String>()
        var result: [StoredTemplate] = []
        for item in try allVersions() where !seen.contains(item.key) {
            seen.insert(item.key)
            result.append(item)
        }
        return result
    }

    /// A newer version of the same template, if one exists (for "a newer version is available").
    func newerVersion(than current: StoredTemplate) throws -> StoredTemplate? {
        guard let newest = try latest(key: current.key) else { return nil }
        return Self.compareVersions(newest.version, current.version) == .orderedDescending ? newest : nil
    }

    /// Drafts (also those in the Trash) that started from this exact version.
    func draftCount(key: String, version: String) throws -> Int {
        Int(try model.database.scalarInt(
            "SELECT COUNT(*) FROM drafts WHERE template_id = ? AND template_version = ?",
            [.text(key), .text(version)]
        ) ?? 0)
    }

    // MARK: Edit and remove

    /// "Add class file": marks whether the template still needs its .cls file.
    @discardableResult
    func setNeedsClassFile(key: String, version: String, to needs: Bool) throws -> StoredTemplate {
        try model.atomically {
            guard let existing = try template(key: key, version: version) else {
                throw ModelError.notFound(kind: "template", id: "\(key)@\(version)")
            }
            if existing.needsClassFile == needs { return existing }

            try model.database.run(
                "UPDATE templates SET needs_class_file = ? WHERE id = ?",
                [LibraryModel.bool(needs), .text(existing.rowID)]
            )
            try model.record("template", existing.rowID, .update, field: "needs_class_file",
                             old: needs ? "0" : "1", new: needs ? "1" : "0")

            return StoredTemplate(
                key: existing.key, version: existing.version, name: existing.name,
                documentClass: existing.documentClass, needsClassFile: needs,
                bundlePath: existing.bundlePath, bst: existing.bst
            )
        }
    }

    /// Removes one version. Refused while any draft started from it, because that
    /// draft could no longer rebuild the same way. The schema has no `deleted_at`
    /// for templates, so the old values go to the change sink first.
    func remove(key: String, version: String) throws {
        try model.atomically {
            guard let existing = try template(key: key, version: version) else {
                throw ModelError.notFound(kind: "template", id: "\(key)@\(version)")
            }
            let users = try draftCount(key: key, version: version)
            if users > 0 {
                throw ModelError.invalidValue(
                    "\(users) writing project\(users == 1 ? "" : "s") still use version \(version) of “\(existing.name)”"
                )
            }
            try model.database.run("DELETE FROM templates WHERE id = ?", [.text(existing.rowID)])
            try model.record("template", existing.rowID, .delete, field: "template",
                             old: Self.snapshot(existing), new: nil)
        }
    }

    // MARK: Versions

    /// Compares dotted versions part by part: 1.2 < 1.10 < 2. Parts that are not
    /// numbers are compared as text (numbers inside them still count as numbers).
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map(String.init)
        let right = b.split(separator: ".").map(String.init)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "0"
            let r = index < right.count ? right[index] : "0"
            if let li = Int(l), let ri = Int(r) {
                if li != ri { return li < ri ? .orderedAscending : .orderedDescending }
            } else {
                let result = l.compare(r, options: .numeric)
                if result != .orderedSame { return result }
            }
        }
        return .orderedSame
    }

    // MARK: Helpers

    /// Keys and versions go into the row id "<key>@<version>", so "@" and spaces are not allowed.
    private static func isValidPart(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        }
    }

    static func template(from row: SQLRow) throws -> StoredTemplate {
        guard let rowID = row.text("id"),
              let name = row.text("name"),
              let version = row.text("version"),
              let documentClass = row.text("document_class"),
              let bundlePath = row.text("bundle_path") else {
            throw ModelError.invalidValue("template row")
        }
        // Row ids are "<key>@<version>". A row written some other way (no "@") uses the whole id as its key.
        let key = rowID.firstIndex(of: "@").map { String(rowID[rowID.startIndex..<$0]) } ?? rowID

        return StoredTemplate(
            key: key,
            version: version,
            name: name,
            documentClass: documentClass,
            needsClassFile: (row.int("needs_class_file") ?? 0) != 0,
            bundlePath: bundlePath,
            bst: row.text("bst") ?? ""
        )
    }

    private static func snapshot(_ item: StoredTemplate) -> String {
        LibraryModel.json([
            "id": item.rowID,
            "name": item.name,
            "version": item.version,
            "document_class": item.documentClass,
            "needs_class_file": item.needsClassFile ? 1 : 0,
            "bundle_path": item.bundlePath,
            "bst": item.bst
        ] as [String: Any])
    }
}
