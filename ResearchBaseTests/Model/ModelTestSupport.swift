//
//  ModelTestSupport.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1B: shared helpers for the data-model tests.
//  Every test builds its own library in a temporary folder that is
//  removed afterwards. Nothing touches the real library or old store.
//

import XCTest
@testable import ResearchBase

// MARK: - Change sinks for tests

/// Remembers every change the model reports.
final class RecordingChangeSink: ChangeSink {

    struct Entry: Equatable {
        let entityType: String
        let entityID: String
        let action: ChangeAction
        let field: String?
        let oldValue: String?
        let newValue: String?
    }

    private(set) var entries: [Entry] = []

    func record(
        entityType: String,
        entityID: String,
        action: ChangeAction,
        field: String?,
        oldValue: String?,
        newValue: String?
    ) throws {
        entries.append(Entry(
            entityType: entityType, entityID: entityID, action: action,
            field: field, oldValue: oldValue, newValue: newValue
        ))
    }

    func entries(type: String, action: ChangeAction? = nil, field: String? = nil) -> [Entry] {
        entries.filter {
            $0.entityType == type
                && (action == nil || $0.action == action)
                && (field == nil || $0.field == field)
        }
    }

    func clear() { entries.removeAll() }
}

/// Fails on the Nth call (0 = the first call) to prove a failed write changes nothing.
final class FailingChangeSink: ChangeSink {

    struct Failure: Error {}

    private var calls = 0
    private let failOnCall: Int

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func record(
        entityType: String,
        entityID: String,
        action: ChangeAction,
        field: String?,
        oldValue: String?,
        newValue: String?
    ) throws {
        defer { calls += 1 }
        if calls == failOnCall { throw Failure() }
    }
}

// MARK: - Helpers

@MainActor
enum ModelTestSupport {

    /// A new empty library in a temp folder. The caller closes it: `defer { model.library.close() }`.
    static func makeModel(_ test: XCTestCase, sink: ChangeSink? = nil) throws -> LibraryModel {
        let folder = try TestSupport.makeTempDirectory(test)
            .appendingPathComponent(Library.folderName, isDirectory: true)
        let library = try Library.open(at: folder)
        return LibraryModel(library: library, changeSink: sink)
    }

    /// A quick item with one first author.
    @discardableResult
    static func item(
        _ model: LibraryModel,
        title: String = "Communication-Efficient Learning of Deep Networks",
        author: String = "McMahan",
        given: String = "Brendan",
        year: Int? = 2017,
        type: ItemType = .conference,
        state: ReviewState = .accepted
    ) throws -> ModelItem {
        try model.items.create(NewItem(
            type: type,
            title: title,
            creators: author.isEmpty ? [] : [CreatorInput(family: author, given: given)],
            year: year,
            reviewState: state
        ))
    }

    static func count(_ model: LibraryModel, _ table: String, where clause: String = "1") throws -> Int {
        Int(try model.database.scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(clause)") ?? 0)
    }

    /// Puts an item in the Trash by hand (Step 1C builds the real Trash).
    static func trash(_ model: LibraryModel, itemID: String) throws {
        try model.database.run(
            "UPDATE items SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(itemID)]
        )
    }

    // Rows in other tables that links and keys point at.

    static func insertThought(_ model: LibraryModel, id: String = UUID().uuidString) throws -> String {
        let now = Library.nowISO()
        try model.database.run(
            "INSERT INTO thoughts (id, kind, title, created_at, updated_at) VALUES (?, 'note', 'A note', ?, ?)",
            [.text(id), .text(now), .text(now)]
        )
        return id
    }

    static func insertExperiment(_ model: LibraryModel, id: String = UUID().uuidString) throws -> String {
        let now = Library.nowISO()
        try model.database.run(
            "INSERT INTO experiments (id, name, created_at, updated_at) VALUES (?, 'Run it', ?, ?)",
            [.text(id), .text(now), .text(now)]
        )
        return id
    }

    static func insertDraft(_ model: LibraryModel, id: String = UUID().uuidString) throws -> String {
        let now = Library.nowISO()
        try model.database.run(
            "INSERT INTO drafts (id, title, kind, folder, created_at, updated_at) VALUES (?, 'My paper', 'paper', ?, ?, ?)",
            [.text(id), .text("drafts/\(id)"), .text(now), .text(now)]
        )
        return id
    }

    static func insertProject(_ model: LibraryModel, id: String = UUID().uuidString) throws -> String {
        let now = Library.nowISO()
        try model.database.run(
            "INSERT INTO projects (id, name, created_at, updated_at) VALUES (?, 'Thesis', ?, ?)",
            [.text(id), .text(now), .text(now)]
        )
        return id
    }

    static func cite(_ model: LibraryModel, draftID: String, itemID: String?, key: String, line: Int = 1) throws {
        try model.database.run(
            "INSERT INTO draft_citations (draft_id, item_id, citation_key, file, line) VALUES (?, ?, ?, 'main.tex', ?)",
            [.text(draftID), LibraryModel.text(itemID), .text(key), .int(Int64(line))]
        )
    }

    /// Writes a small file and returns its URL.
    static func makeFile(_ test: XCTestCase, name: String = "hello.pdf", content: String = "hello") throws -> URL {
        let folder = try TestSupport.makeTempDirectory(test)
        let url = folder.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
}
