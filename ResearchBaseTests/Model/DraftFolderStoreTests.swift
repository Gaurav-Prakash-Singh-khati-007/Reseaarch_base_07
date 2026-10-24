//
//  DraftFolderStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  DraftFolderStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 20 · Features: F-29
//

import XCTest
@testable import ResearchBase

@MainActor
final class DraftFolderStoreTests: XCTestCase {

    private func makeStore(sink: ChangeSink? = nil) throws -> (LibraryModel, DraftFolderStore) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false      // tests must not fill the real Trash
        return (model, store)
    }

    private func exists(_ store: DraftFolderStore, _ draft: StoredDraft, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: store.folderURL(for: draft).appendingPathComponent(path).path)
    }

    // MARK: Create

    func testCreateMakesARealFolderWithTheStandardFiles() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "  Client Drift  ", templateID: "ieee", templateVersion: "1.0", wordGoal: 6000)

        XCTAssertEqual(draft.title, "Client Drift")
        XCTAssertEqual(draft.kind, .paper)
        XCTAssertEqual(draft.folder, "drafts/\(draft.id)")
        XCTAssertEqual(draft.mainFile, "main.tex")
        XCTAssertEqual(draft.templateID, "ieee")
        XCTAssertEqual(draft.templateVersion, "1.0")
        XCTAssertEqual(draft.wordGoal, 6000)
        XCTAssertEqual(draft.stage, .draft)
        XCTAssertTrue(exists(store, draft, "main.tex"))
        XCTAssertTrue(exists(store, draft, "refs.bib"))
        XCTAssertTrue(exists(store, draft, "figures"))
        XCTAssertFalse(exists(store, draft, "chapters"))
        XCTAssertEqual(try store.draft(id: draft.id), draft)
    }

    func testThesisGetsAChaptersFolderAndGivenTextIsUsed() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "My thesis", kind: .thesis, mainTex: "\\documentclass{report}")

        XCTAssertTrue(exists(store, draft, "chapters"))
        XCTAssertEqual(try store.readText(draftID: draft.id, path: "main.tex"), "\\documentclass{report}")
    }

    func testBadInputIsRefusedAndLeavesNothingBehind() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(title: "  ")) { XCTAssertEqual($0 as? ModelError, .emptyName) }
        XCTAssertThrowsError(try store.create(title: "X", wordGoal: -1))
        XCTAssertEqual(try store.count(), 0)
    }

    func testFailedChangeSinkRemovesTheNewFolder() throws {
        let (model, store) = try makeStore(sink: FailingChangeSink(failOnCall: 0))
        defer { model.library.close() }

        XCTAssertThrowsError(try store.create(title: "X"))
        XCTAssertEqual(try store.count(), 0)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: model.library.draftsURL.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: Files

    func testWriteReadAddAndImport() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")

        try store.writeText(draftID: draft.id, path: "chapters/intro.tex", text: "Hello")
        XCTAssertEqual(try store.readText(draftID: draft.id, path: "chapters/intro.tex"), "Hello")

        try store.writeText(draftID: draft.id, path: "chapters/intro.tex", text: "Changed")
        XCTAssertEqual(try store.readText(draftID: draft.id, path: "chapters/intro.tex"), "Changed")

        XCTAssertEqual(try store.addFile(draftID: draft.id, path: "notes.txt"), "notes.txt")
        XCTAssertThrowsError(try store.addFile(draftID: draft.id, path: "notes.txt"))

        let picture = try ModelTestSupport.makeFile(self, name: "accuracy.pdf", content: "pdf")
        XCTAssertEqual(try store.importFile(draftID: draft.id, from: picture), "figures/accuracy.pdf")
        XCTAssertThrowsError(try store.importFile(draftID: draft.id, from: picture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path), "the original stays")

        XCTAssertThrowsError(try store.readText(draftID: draft.id, path: "missing.tex"))
        XCTAssertThrowsError(try store.writeText(draftID: draft.id, path: "figures", text: "x"))
    }

    func testFilesListsEverythingSortedAndSkipsHiddenFiles() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        try store.addFile(draftID: draft.id, path: ".DS_Store")
        try store.addFile(draftID: draft.id, path: "figures/b.png", data: Data([1, 2, 3]))

        let listed = try store.files(in: draft.id)
        XCTAssertEqual(listed.map(\.path), ["figures", "figures/b.png", "main.tex", "refs.bib"])
        XCTAssertEqual(listed.first(where: { $0.path == "figures" })?.isFolder, true)
        XCTAssertEqual(listed.first(where: { $0.path == "figures/b.png" })?.size, 3)
    }

    func testPathsOutsideTheFolderAreRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")

        for bad in ["../secret.txt", "/etc/passwd", "~/x", "a/../b", "a//b", "", ".", "a/./b", "a\\b"] {
            XCTAssertThrowsError(try store.writeText(draftID: draft.id, path: bad, text: "x"), bad)
            XCTAssertThrowsError(try store.readText(draftID: draft.id, path: bad), bad)
        }

        // A symbolic link inside the folder that points outside must not be followed.
        let outside = try TestSupport.makeTempDirectory(self)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: store.folderURL(for: draft).appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try store.readText(draftID: draft.id, path: "escape/secret.txt"))
        XCTAssertThrowsError(try store.writeText(draftID: draft.id, path: "escape/new.txt", text: "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    func testRenameMovesTheMainFileSettingWithIt() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        try store.addFile(draftID: draft.id, path: "other.tex")
        sink.clear()

        XCTAssertThrowsError(try store.renameFile(draftID: draft.id, from: "main.tex", to: "other.tex"))
        XCTAssertThrowsError(try store.renameFile(draftID: draft.id, from: "nope.tex", to: "x.tex"))

        try store.renameFile(draftID: draft.id, from: "main.tex", to: "paper.tex")
        XCTAssertEqual(try store.draft(id: draft.id)?.mainFile, "paper.tex")
        XCTAssertTrue(exists(store, draft, "paper.tex"))
        XCTAssertFalse(exists(store, draft, "main.tex"))
        XCTAssertEqual(sink.entries(type: "draft", action: .update, field: "main_file").count, 1)

        // Renaming a normal file leaves main_file alone.
        try store.renameFile(draftID: draft.id, from: "other.tex", to: "sections/other.tex")
        XCTAssertTrue(exists(store, draft, "sections/other.tex"))
        XCTAssertEqual(try store.draft(id: draft.id)?.mainFile, "paper.tex")
    }

    func testRenamingAFolderThatHoldsTheMainFileFollowsIt() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        try store.renameFile(draftID: draft.id, from: "main.tex", to: "src/main.tex")
        try store.setMainFile(id: draft.id, to: "src/main.tex")

        try store.renameFile(draftID: draft.id, from: "src", to: "source")
        XCTAssertEqual(try store.draft(id: draft.id)?.mainFile, "source/main.tex")
    }

    func testDeleteFileRefusesTheMainFileAndItsFolders() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        try store.addFile(draftID: draft.id, path: "notes.txt")

        XCTAssertThrowsError(try store.deleteFile(draftID: draft.id, path: "main.tex"))
        try store.deleteFile(draftID: draft.id, path: "notes.txt")
        XCTAssertFalse(exists(store, draft, "notes.txt"))
        XCTAssertThrowsError(try store.deleteFile(draftID: draft.id, path: "notes.txt"))

        try store.renameFile(draftID: draft.id, from: "main.tex", to: "src/main.tex")
        try store.setMainFile(id: draft.id, to: "src/main.tex")
        XCTAssertThrowsError(try store.deleteFile(draftID: draft.id, path: "src"))
    }

    func testSetMainFileNeedsAnExistingFile() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        XCTAssertThrowsError(try store.setMainFile(id: draft.id, to: "nope.tex"))
        XCTAssertThrowsError(try store.setMainFile(id: draft.id, to: "figures"))
        try store.addFile(draftID: draft.id, path: "thesis.tex")
        XCTAssertEqual(try store.setMainFile(id: draft.id, to: "thesis.tex").mainFile, "thesis.tex")
    }

    // MARK: Settings

    func testSettersChangeOneFieldAndReportIt() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        sink.clear()

        try store.setTitle(id: draft.id, to: "B")
        try store.setKind(id: draft.id, to: .report)
        try store.setStage(id: draft.id, to: .underReview)
        try store.setEngine(id: draft.id, to: "latexmk-xelatex")
        try store.setBibStyle(id: draft.id, to: "IEEEtran")
        try store.setCSLStyle(id: draft.id, to: "apa")
        try store.setWordGoal(id: draft.id, to: 8000)
        try store.setArchived(id: draft.id, to: true)
        let after = try store.setTemplate(id: draft.id, templateID: "acm", templateVersion: "1.0")

        XCTAssertEqual(after.title, "B")
        XCTAssertEqual(after.kind, .report)
        XCTAssertEqual(after.stage, .underReview)
        XCTAssertEqual(after.engine, "latexmk-xelatex")
        XCTAssertEqual(after.bibStyle, "IEEEtran")
        XCTAssertEqual(after.cslStyle, "apa")
        XCTAssertEqual(after.wordGoal, 8000)
        XCTAssertTrue(after.archived)
        XCTAssertEqual(after.templateID, "acm")
        XCTAssertEqual(sink.entries(type: "draft", action: .update).map(\.field),
                       ["title", "kind", "stage", "engine", "bib_style", "csl_style", "word_goal",
                        "archived", "template_id", "template_version"])

        sink.clear()
        try store.setTitle(id: draft.id, to: "B")
        XCTAssertTrue(sink.entries.isEmpty)

        XCTAssertThrowsError(try store.setTitle(id: draft.id, to: " "))
        XCTAssertThrowsError(try store.setWordGoal(id: draft.id, to: -5))
        XCTAssertNil(try store.setWordGoal(id: draft.id, to: nil).wordGoal)
    }

    func testListHidesArchivedAndTrashedAndOrdersByLatestEdit() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let first = try store.create(title: "First")
        let second = try store.create(title: "Second")
        let third = try store.create(title: "Third")

        try store.setArchived(id: second.id, to: true)
        XCTAssertEqual(try store.all().map(\.id).sorted(), [first.id, third.id].sorted())
        XCTAssertEqual(try store.all(includeArchived: true).count, 3)

        Thread.sleep(forTimeInterval: 0.01)
        try store.touch(id: first.id)
        XCTAssertEqual(try store.all().first?.id, first.id)
    }

    // MARK: Trash

    func testTrashRestoreAndDeleteForever() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let draft = try store.create(title: "A")

        XCTAssertThrowsError(try store.deleteForever(id: draft.id), "must be in the Trash first")

        try store.moveToTrash(id: draft.id)
        XCTAssertNil(try store.draft(id: draft.id))
        XCTAssertNotNil(try store.draft(id: draft.id, includeDeleted: true))
        XCTAssertEqual(try store.trashed().map(\.id), [draft.id])
        XCTAssertEqual(try store.count(), 0)
        XCTAssertTrue(exists(store, draft, "main.tex"), "the folder stays while in the Trash")
        XCTAssertThrowsError(try store.setTitle(id: draft.id, to: "Nope"))

        let back = try store.restore(id: draft.id)
        XCTAssertNil(back.deletedAt)
        XCTAssertEqual(try store.count(), 1)
        XCTAssertThrowsError(try store.restore(id: draft.id))

        try store.moveToTrash(id: draft.id)
        sink.clear()
        try store.deleteForever(id: draft.id)
        XCTAssertNil(try store.draft(id: draft.id, includeDeleted: true))
        XCTAssertFalse(exists(store, draft, ""))
        XCTAssertEqual(sink.entries(type: "draft", action: .delete).count, 1)
    }

    func testDeleteForeverIsRefusedWhileASubmissionPointsAtTheDraft() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draft = try store.create(title: "A")
        try model.database.run(
            "INSERT INTO submissions (id, draft_id, venue) VALUES ('s1', ?, 'ACL')", [.text(draft.id)]
        )
        try store.moveToTrash(id: draft.id)

        XCTAssertThrowsError(try store.deleteForever(id: draft.id))
        XCTAssertNotNil(try store.draft(id: draft.id, includeDeleted: true))
        XCTAssertTrue(exists(store, draft, "main.tex"))
    }
}