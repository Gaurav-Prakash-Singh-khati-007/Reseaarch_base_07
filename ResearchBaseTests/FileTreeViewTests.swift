//
//  FileTreeViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  FileTreeViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 43 (tests for FileTreeView.swift)
//  The pure tree logic, and the actions against a real DraftFolderStore in a temporary library.
//

import XCTest
@testable import ResearchBase

final class FileTreeViewTests: XCTestCase {

    typealias T = FileTreeLogic

    private func file(_ path: String, folder: Bool = false, size: Int = 1) -> StoredDraftFile {
        StoredDraftFile(path: path, isFolder: folder, size: size)
    }

    // MARK: Tree

    func testBuildNestsAndSortsFoldersFirst() {
        let tree = T.build([
            file("main.tex"), file("refs.bib"),
            file("figures", folder: true), file("figures/fig10.png"), file("figures/fig2.png"),
            file("chapters", folder: true), file("chapters/intro.tex"),
        ])
        XCTAssertEqual(tree.map(\.name), ["chapters", "figures", "main.tex", "refs.bib"])
        XCTAssertEqual(tree[1].children.map(\.name), ["fig2.png", "fig10.png"], "natural number order")
        XCTAssertTrue(tree[0].isFolder)
        XCTAssertFalse(tree[2].isFolder)
    }

    func testBuildCreatesMissingParentFolders() {
        let tree = T.build([file("a/b/c.tex")])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].path, "a")
        XCTAssertEqual(tree[0].children[0].path, "a/b")
        XCTAssertEqual(tree[0].children[0].children[0].path, "a/b/c.tex")
    }

    func testBuildEmptyAndEmptyFolder() {
        XCTAssertTrue(T.build([]).isEmpty)
        let tree = T.build([file("figures", folder: true)])
        XCTAssertTrue(tree[0].isFolder)
        XCTAssertTrue(tree[0].children.isEmpty)
    }

    func testRowsHideCollapsedFolders() {
        let tree = T.build([file("figures", folder: true), file("figures/a.png"), file("main.tex")])
        XCTAssertEqual(T.rows(tree).map(\.node.path), ["figures", "figures/a.png", "main.tex"])
        XCTAssertEqual(T.rows(tree).map(\.depth), [0, 1, 0])
        XCTAssertEqual(T.rows(tree, collapsed: ["figures"]).map(\.node.path), ["figures", "main.tex"])
    }

    // MARK: Names and paths

    func testValidateName() {
        XCTAssertNil(T.validateName("intro.tex"))
        XCTAssertNil(T.validateName("  my notes.tex  "))
        XCTAssertNotNil(T.validateName(""))
        XCTAssertNotNil(T.validateName("   "))
        XCTAssertNotNil(T.validateName("a/b.tex"))
        XCTAssertNotNil(T.validateName("a:b"))
        XCTAssertNotNil(T.validateName(".hidden"))
        XCTAssertNotNil(T.validateName(".."))
        XCTAssertNotNil(T.validateName(String(repeating: "x", count: 200)))
    }

    func testParentJoinRemap() {
        XCTAssertEqual(T.parent(of: "a/b/c.tex"), "a/b")
        XCTAssertEqual(T.parent(of: "main.tex"), "")
        XCTAssertEqual(T.join("", "x.tex"), "x.tex")
        XCTAssertEqual(T.join("a", "x.tex"), "a/x.tex")
        XCTAssertEqual(T.remap("chapters", from: "chapters", to: "parts"), "parts")
        XCTAssertEqual(T.remap("chapters/a.tex", from: "chapters", to: "parts"), "parts/a.tex")
        XCTAssertEqual(T.remap("chapters2/a.tex", from: "chapters", to: "parts"), "chapters2/a.tex")
    }

    func testFileKinds() {
        XCTAssertTrue(T.isEditableText("a/b.TEX"))
        XCTAssertTrue(T.isEditableText("refs.bib"))
        XCTAssertFalse(T.isEditableText("fig.png"))
        XCTAssertTrue(T.canBeMainFile("x.tex"))
        XCTAssertFalse(T.canBeMainFile("refs.bib"))
        XCTAssertEqual(T.importFolder(forFileNamed: "plot.PNG"), "figures")
        XCTAssertEqual(T.importFolder(forFileNamed: "fig.pdf"), "figures")
        XCTAssertEqual(T.importFolder(forFileNamed: "ieee.sty"), "")
        XCTAssertEqual(T.iconName(for: FileTreeNode(path: "f", name: "f", isFolder: true, size: 0, children: [])), "folder")
        XCTAssertEqual(T.iconName(for: FileTreeNode(path: "a.bib", name: "a.bib", isFolder: false, size: 0, children: [])), "books.vertical")
    }

    // MARK: Operations on a real store

    @MainActor
    private func makeDraft() throws -> (LibraryModel, DraftFolderStore, StoredDraft, FileTreeOperations) {
        let model = try ModelTestSupport.makeModel(self)
        addTeardownBlock { model.library.close() }
        let store = DraftFolderStore(model: model)
        store.useSystemTrash = false
        let draft = try store.create(title: "Tree test")
        return (model, store, draft, FileTreeOperations(store: store, draftID: draft.id))
    }

    @MainActor
    func testAddFileAddsTexExtensionAndRefusesBadNamesAndDuplicates() throws {
        let (_, store, draft, ops) = try makeDraft()
        XCTAssertEqual(try ops.addFile(named: "intro", inFolder: ""), "intro.tex")
        XCTAssertEqual(try ops.addFile(named: "notes.md", inFolder: "figures"), "figures/notes.md")
        XCTAssertThrowsError(try ops.addFile(named: "a/b", inFolder: "")) { XCTAssertTrue($0 is FileTreeError) }
        XCTAssertThrowsError(try ops.addFile(named: "intro.tex", inFolder: ""), "already exists")
        XCTAssertTrue(try store.files(in: draft.id).contains { $0.path == "intro.tex" })
    }

    @MainActor
    func testAddFolderAndNestedFile() throws {
        let (_, store, draft, ops) = try makeDraft()
        XCTAssertEqual(try ops.addFolder(named: "chapters", inFolder: ""), "chapters")
        XCTAssertEqual(try ops.addFile(named: "one.tex", inFolder: "chapters"), "chapters/one.tex")
        let tree = FileTreeLogic.build(try store.files(in: draft.id))
        XCTAssertEqual(tree.first { $0.name == "chapters" }?.children.map(\.name), ["one.tex"])
    }

    @MainActor
    func testRenameKeepsExtensionAndFollowsTheMainFile() throws {
        let (_, store, draft, ops) = try makeDraft()
        let main = draft.mainFile
        let renamed = try ops.rename(path: main, to: "paper")
        XCTAssertEqual(renamed, "paper.tex", "extension kept")
        XCTAssertEqual(try store.draft(id: draft.id)?.mainFile, "paper.tex")
        XCTAssertEqual(try ops.rename(path: "paper.tex", to: "paper.tex"), "paper.tex", "same name changes nothing")
    }

    @MainActor
    func testRenameFolderMovesItsFiles() throws {
        let (_, store, draft, ops) = try makeDraft()
        try ops.addFolder(named: "old", inFolder: "")
        try ops.addFile(named: "a.tex", inFolder: "old")
        XCTAssertEqual(try ops.rename(path: "old", to: "new"), "new")
        let paths = try store.files(in: draft.id).map(\.path)
        XCTAssertTrue(paths.contains("new/a.tex"))
        XCTAssertFalse(paths.contains("old/a.tex"))
    }

    @MainActor
    func testDeleteRefusesTheMainFileButDeletesOthers() throws {
        let (_, store, draft, ops) = try makeDraft()
        XCTAssertThrowsError(try ops.delete(path: draft.mainFile))
        try ops.addFile(named: "tmp.tex", inFolder: "")
        try ops.delete(path: "tmp.tex")
        XCTAssertFalse(try store.files(in: draft.id).contains { $0.path == "tmp.tex" })
    }

    @MainActor
    func testSetMainFile() throws {
        let (_, store, draft, ops) = try makeDraft()
        try ops.addFile(named: "alt.tex", inFolder: "")
        try ops.setMainFile(path: "alt.tex")
        XCTAssertEqual(try store.draft(id: draft.id)?.mainFile, "alt.tex")
        XCTAssertThrowsError(try ops.setMainFile(path: "missing.tex"))
    }

    @MainActor
    func testImportSortsPicturesIntoFiguresAndOthersToTheTop() throws {
        let (_, store, draft, ops) = try makeDraft()
        let png = try ModelTestSupport.makeFile(self, name: "plot.png", content: "x")
        let sty = try ModelTestSupport.makeFile(self, name: "my.sty", content: "y")
        let added = try ops.importFiles([png, sty])
        XCTAssertEqual(added, ["figures/plot.png", "my.sty"])
        XCTAssertTrue(try store.files(in: draft.id).contains { $0.path == "figures/plot.png" })
        XCTAssertThrowsError(try ops.importFiles([png]), "importing the same file twice is refused")
        XCTAssertEqual(try ops.importFiles([sty], intoFolder: "extra"), ["extra/my.sty"])
    }
}