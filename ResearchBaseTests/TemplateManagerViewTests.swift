//
//  TemplateManagerViewTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  TemplateManagerViewTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 44 · Features: L-11, F-32
//
//  Tests the logic behind TemplateManagerView (TemplateManagerLogic): version
//  numbers, reading a template folder, keys, and loading templates with
//  their versions and draft counts. The SwiftUI views themselves are not tested.
//

import XCTest
@testable import ResearchBase

@MainActor
final class TemplateManagerViewTests: XCTestCase {

    // MARK: Helpers

    private func makeStore() throws -> (LibraryModel, TemplateStore) {
        let model = try ModelTestSupport.makeModel(self)
        return (model, TemplateStore(model: model))
    }

    /// A fresh temporary parent folder, removed after the test.
    private func makeTempParent() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemplateManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent
    }

    /// Makes a folder called `name` inside a temporary parent, with the given files.
    private func makeFolder(named name: String, files: [String: String]) throws -> URL {
        let folder = try makeTempParent().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (fileName, content) in files {
            try content.write(to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
        return folder
    }

    // MARK: Next version

    func testNextVersionCountsUpTheLastNumber() {
        XCTAssertEqual(TemplateManagerLogic.nextVersion(after: "1.0"), "1.1")
        XCTAssertEqual(TemplateManagerLogic.nextVersion(after: "2"), "3")
        XCTAssertEqual(TemplateManagerLogic.nextVersion(after: "1.9"), "1.10")
        XCTAssertEqual(TemplateManagerLogic.nextVersion(after: "2.3.4"), "2.3.5")
    }

    func testNextVersionOfANonNumberAddsAPart() {
        XCTAssertEqual(TemplateManagerLogic.nextVersion(after: "1.0-beta"), "1.0-beta.1")
    }

    func testNextVersionIsNewerAccordingToTheStore() {
        for version in ["1.0", "1.9", "2", "3.1.4"] {
            let next = TemplateManagerLogic.nextVersion(after: version)
            XCTAssertEqual(TemplateStore.compareVersions(next, version), .orderedDescending, "\(next) should be newer than \(version)")
        }
    }

    // MARK: \documentclass

    func testDocumentClassIsReadWithAndWithoutOptions() {
        XCTAssertEqual(TemplateManagerLogic.documentClass(in: "\\documentclass{article}\n"), "article")
        XCTAssertEqual(TemplateManagerLogic.documentClass(in: "% header\n\\documentclass[a4paper, 11pt]{IEEEtran}\n\\begin{document}"), "IEEEtran")
    }

    func testDocumentClassTakesTheFirstOne() {
        let text = "\\documentclass{report}\n\\documentclass{book}\n"
        XCTAssertEqual(TemplateManagerLogic.documentClass(in: text), "report")
    }

    func testDocumentClassIsNilWhenThereIsNone() {
        XCTAssertNil(TemplateManagerLogic.documentClass(in: "no class here"))
        XCTAssertNil(TemplateManagerLogic.documentClass(in: ""))
        XCTAssertNil(TemplateManagerLogic.documentClass(in: "\\documentclass{}"))
    }

    // MARK: Keys

    func testKeyFromAFolderNameIsLowercaseAndSafe() {
        XCTAssertEqual(TemplateManagerLogic.keyFrom("MLSys 2027"), "mlsys-2027")
        XCTAssertEqual(TemplateManagerLogic.keyFrom("My Paper (v2)!"), "my-paper--v2")
        XCTAssertEqual(TemplateManagerLogic.keyFrom("already_ok-1.2"), "already_ok-1.2")
        XCTAssertEqual(TemplateManagerLogic.keyFrom("---"), "")
    }

    func testAKeyFromAFolderNameIsAcceptedByTheStore() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let key = TemplateManagerLogic.keyFrom("Conference Paper (2027)")
        let saved = try store.register(key: key, name: "Conference Paper", version: "1.0",
                                       documentClass: "article", bundlePath: "/tmp/conference")
        XCTAssertEqual(saved.key, key)
    }

    // MARK: Needs class file

    func testNeedsClassFileOnlyForNonStandardClassesWithoutACls() {
        XCTAssertFalse(TemplateManagerLogic.needsClassFile(documentClass: "article", hasClassFile: false))
        XCTAssertFalse(TemplateManagerLogic.needsClassFile(documentClass: "report", hasClassFile: false))
        XCTAssertTrue(TemplateManagerLogic.needsClassFile(documentClass: "llncs", hasClassFile: false))
        XCTAssertFalse(TemplateManagerLogic.needsClassFile(documentClass: "llncs", hasClassFile: true))
    }

    // MARK: Folder scan

    func testScanReadsClassBibliographyStyleAndName() throws {
        let folder = try makeFolder(named: "My Template", files: [
            "main.tex": "\\documentclass[conference]{IEEEtran}\n\\begin{document}\\end{document}\n",
            "IEEEtran.bst": "% bst"
        ])

        let found = TemplateManagerLogic.scan(folder: folder)

        XCTAssertEqual(found.name, "My Template")
        XCTAssertEqual(found.key, "my-template")
        XCTAssertEqual(found.documentClass, "IEEEtran")
        XCTAssertEqual(found.bst, "IEEEtran")
        XCTAssertFalse(found.hasClassFile)
    }

    func testScanPrefersMainTexOverOtherTexFiles() throws {
        let folder = try makeFolder(named: "two-files", files: [
            "appendix.tex": "\\documentclass{article}\n",
            "main.tex": "\\documentclass{acmart}\n"
        ])

        XCTAssertEqual(TemplateManagerLogic.scan(folder: folder).documentClass, "acmart")
    }

    func testScanFallsBackToTheClassFileName() throws {
        let folder = try makeFolder(named: "only-class", files: ["llncs.cls": "% class"])

        let found = TemplateManagerLogic.scan(folder: folder)

        XCTAssertEqual(found.documentClass, "llncs")
        XCTAssertTrue(found.hasClassFile)
        XCTAssertNil(found.bst)
    }

    func testScanOfAnEmptyFolderFindsNothing() throws {
        let folder = try makeFolder(named: "empty", files: [:])

        let found = TemplateManagerLogic.scan(folder: folder)

        XCTAssertNil(found.documentClass)
        XCTAssertNil(found.bst)
        XCTAssertFalse(found.hasClassFile)
        XCTAssertEqual(found.key, "empty")
    }

    func testScanOfAMissingFolderDoesNotCrash() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        let found = TemplateManagerLogic.scan(folder: missing)

        XCTAssertNil(found.documentClass)
        XCTAssertFalse(found.hasClassFile)
    }

    func testScanResultCanBeSavedAsATemplate() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }
        let folder = try makeFolder(named: "Workshop Paper", files: [
            "main.tex": "\\documentclass{llncs}\n",
            "splncs04.bst": "% bst"
        ])

        let found = TemplateManagerLogic.scan(folder: folder)
        let saved = try store.register(
            key: found.key, name: found.name, version: "1.0",
            documentClass: found.documentClass ?? "",
            needsClassFile: TemplateManagerLogic.needsClassFile(
                documentClass: found.documentClass ?? "", hasClassFile: found.hasClassFile),
            bundlePath: folder.path, bst: found.bst ?? ""
        )

        XCTAssertEqual(saved.key, "workshop-paper")
        XCTAssertEqual(saved.documentClass, "llncs")
        XCTAssertEqual(saved.bst, "splncs04")
        XCTAssertTrue(saved.needsClassFile)
    }

    // MARK: Loading the list

    func testLoadGroupsOfAnEmptyStoreIsEmpty() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertTrue(try TemplateManagerLogic.loadGroups(from: store).isEmpty)
    }

    func testLoadGroupsListsEachTemplateOnceByName() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }
        try store.registerBuiltIns()

        let groups = try TemplateManagerLogic.loadGroups(from: store)

        XCTAssertEqual(groups.map(\.key), ["acm", "arxiv", "elsevier", "ieee", "springer", "thesis"])
        XCTAssertTrue(groups.allSatisfy { $0.versions.count == 1 })
        XCTAssertEqual(groups.first { $0.key == "ieee" }?.name, "IEEE conference")
    }

    func testLoadGroupsPutsTheNewestVersionFirst() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }
        try store.registerBuiltIns()
        try store.register(key: "ieee", name: "IEEE conference", version: "1.10",
                           documentClass: "IEEEtran", bundlePath: "bundled/ieee/1.10", bst: "IEEEtran")
        try store.register(key: "ieee", name: "IEEE conference", version: "1.2",
                           documentClass: "IEEEtran", bundlePath: "bundled/ieee/1.2", bst: "IEEEtran")

        let groups = try TemplateManagerLogic.loadGroups(from: store)
        let ieee = try XCTUnwrap(groups.first { $0.key == "ieee" })

        XCTAssertEqual(ieee.versions.map { $0.template.version }, ["1.10", "1.2", "1.0"])
        XCTAssertEqual(groups.count, 6, "a new version does not add a template")
    }

    func testLoadGroupsCountsDraftsPerVersion() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }
        try store.registerBuiltIns()
        try store.register(key: "ieee", name: "IEEE conference", version: "1.1",
                           documentClass: "IEEEtran", bundlePath: "bundled/ieee/1.1", bst: "IEEEtran")
        let draftID = try ModelTestSupport.insertDraft(model)
        try model.database.run(
            "UPDATE drafts SET template_id = 'ieee', template_version = '1.0' WHERE id = ?", [.text(draftID)]
        )

        let groups = try TemplateManagerLogic.loadGroups(from: store)
        let ieee = try XCTUnwrap(groups.first { $0.key == "ieee" })
        let drafts = Dictionary(uniqueKeysWithValues: ieee.versions.map { ($0.template.version, $0.drafts) })

        XCTAssertEqual(drafts["1.0"], 1)
        XCTAssertEqual(drafts["1.1"], 0)
        XCTAssertEqual(groups.first { $0.key == "acm" }?.versions.first?.drafts, 0)
    }

    func testLoadGroupsSeesNeedsClassFileChangesAndRemovals() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }
        try store.registerBuiltIns()
        try store.setNeedsClassFile(key: "springer", version: "1.0", to: false)
        try store.remove(key: "thesis", version: "1.0")

        let groups = try TemplateManagerLogic.loadGroups(from: store)

        XCTAssertEqual(groups.first { $0.key == "springer" }?.versions.first?.template.needsClassFile, false)
        XCTAssertNil(groups.first { $0.key == "thesis" }, "a template with no versions left is not listed")
    }
}