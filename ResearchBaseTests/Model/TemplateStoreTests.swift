//
//  TemplateStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  TemplateStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 19 · Features: F-32, L-11
//

import XCTest
@testable import ResearchBase

@MainActor
final class TemplateStoreTests: XCTestCase {

    private func makeStore(sink: ChangeSink? = nil) throws -> (LibraryModel, TemplateStore) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        return (model, TemplateStore(model: model))
    }

    @discardableResult
    private func ieee(_ store: TemplateStore, version: String = "1.0", name: String = "IEEE conference") throws -> StoredTemplate {
        try store.register(key: "ieee", name: name, version: version, documentClass: "IEEEtran",
                           bundlePath: "bundled/ieee/\(version)", bst: "IEEEtran")
    }

    // MARK: Register

    func testRegisterStoresATemplateWithComposedRowID() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let saved = try ieee(store)

        XCTAssertEqual(saved.rowID, "ieee@1.0")
        XCTAssertEqual(try store.template(key: "ieee", version: "1.0"), saved)
        XCTAssertEqual(try ModelTestSupport.count(model, "templates", where: "id = 'ieee@1.0'"), 1)
    }

    func testSameVersionSameContentReturnsExistingAndDifferentContentIsRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let first = try ieee(store)
        XCTAssertEqual(try ieee(store), first)
        XCTAssertEqual(try ModelTestSupport.count(model, "templates"), 1)

        XCTAssertThrowsError(try ieee(store, name: "IEEE (changed)"))
        XCTAssertEqual(try store.template(key: "ieee", version: "1.0")?.name, "IEEE conference")
    }

    func testBadInputIsRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.register(key: "ie@ee", name: "X", version: "1", documentClass: "a", bundlePath: "p"))
        XCTAssertThrowsError(try store.register(key: "ieee", name: "X", version: "1 0", documentClass: "a", bundlePath: "p"))
        XCTAssertThrowsError(try store.register(key: "ieee", name: " ", version: "1", documentClass: "a", bundlePath: "p")) {
            XCTAssertEqual($0 as? ModelError, .emptyName)
        }
        XCTAssertThrowsError(try store.register(key: "ieee", name: "X", version: "1", documentClass: "", bundlePath: "p"))
        XCTAssertThrowsError(try store.register(key: "ieee", name: "X", version: "1", documentClass: "a", bundlePath: ""))
        XCTAssertEqual(try ModelTestSupport.count(model, "templates"), 0)
    }

    func testBuiltInsAreSixAndSafeToRepeat() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertEqual(try store.registerBuiltIns().count, 6)
        XCTAssertEqual(try store.registerBuiltIns().count, 6)
        XCTAssertEqual(try ModelTestSupport.count(model, "templates"), 6)
        XCTAssertEqual(try store.template(key: "springer", version: "1.0")?.needsClassFile, true)
        XCTAssertEqual(try store.template(key: "ieee", version: "1.0")?.needsClassFile, false)
    }

    // MARK: Versions

    func testVersionsLatestAndResolve() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let v1 = try ieee(store, version: "1.0")
        let v2 = try ieee(store, version: "1.10")
        let v15 = try ieee(store, version: "1.2")

        XCTAssertEqual(try store.versions(of: "ieee").map(\.version), ["1.10", "1.2", "1.0"])
        XCTAssertEqual(try store.latest(key: "ieee"), v2)
        XCTAssertEqual(try store.resolve(key: "ieee", version: "1.0"), v1)
        XCTAssertEqual(try store.resolve(key: "ieee", version: "1.2"), v15)
        XCTAssertEqual(try store.resolve(key: "ieee", version: nil), v2)
        XCTAssertNil(try store.resolve(key: "ieee", version: "9.9"))
        XCTAssertNil(try store.latest(key: "missing"))
        XCTAssertEqual(try store.newerVersion(than: v1), v2)
        XCTAssertNil(try store.newerVersion(than: v2))
    }

    func testLatestOfEachGivesOneRowPerTemplate() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        try ieee(store, version: "1.0")
        let newest = try ieee(store, version: "2.0")
        try store.registerBuiltIns()

        let list = try store.latestOfEach()
        XCTAssertEqual(list.count, 6)
        XCTAssertEqual(list.filter { $0.key == "ieee" }, [newest])
        XCTAssertEqual(try store.allVersions().count, 7)
    }

    func testCompareVersions() {
        XCTAssertEqual(TemplateStore.compareVersions("1.2", "1.10"), .orderedAscending)
        XCTAssertEqual(TemplateStore.compareVersions("2", "1.9.9"), .orderedDescending)
        XCTAssertEqual(TemplateStore.compareVersions("1.0", "1"), .orderedSame)
    }

    // MARK: Edit and remove

    func testSetNeedsClassFile() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        try store.registerBuiltIns()
        sink.clear()

        let ready = try store.setNeedsClassFile(key: "springer", version: "1.0", to: false)
        XCTAssertFalse(ready.needsClassFile)
        XCTAssertEqual(sink.entries(type: "template", action: .update, field: "needs_class_file").count, 1)

        sink.clear()
        _ = try store.setNeedsClassFile(key: "springer", version: "1.0", to: false)
        XCTAssertTrue(sink.entries.isEmpty)

        XCTAssertThrowsError(try store.setNeedsClassFile(key: "nope", version: "1.0", to: true))
    }

    func testRemoveIsRefusedWhileADraftUsesThatVersion() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        try ieee(store, version: "1.0")
        try ieee(store, version: "2.0")

        let draftID = try ModelTestSupport.insertDraft(model)
        try model.database.run(
            "UPDATE drafts SET template_id = 'ieee', template_version = '1.0' WHERE id = ?", [.text(draftID)]
        )
        XCTAssertEqual(try store.draftCount(key: "ieee", version: "1.0"), 1)
        XCTAssertEqual(try store.draftCount(key: "ieee", version: "2.0"), 0)

        XCTAssertThrowsError(try store.remove(key: "ieee", version: "1.0"))
        XCTAssertNotNil(try store.template(key: "ieee", version: "1.0"))

        try store.remove(key: "ieee", version: "2.0")
        XCTAssertNil(try store.template(key: "ieee", version: "2.0"))
        XCTAssertThrowsError(try store.remove(key: "ieee", version: "2.0"))
    }

    func testRemoveReportsOldValuesToTheChangeSink() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        try ieee(store)
        sink.clear()
        try store.remove(key: "ieee", version: "1.0")

        let deletes = sink.entries(type: "template", action: .delete)
        XCTAssertEqual(deletes.count, 1)
        XCTAssertNotNil(deletes.first?.oldValue)
    }

    func testFailedChangeSinkUndoesRegister() throws {
        let (model, store) = try makeStore(sink: FailingChangeSink(failOnCall: 0))
        defer { model.library.close() }

        XCTAssertThrowsError(try ieee(store))
        XCTAssertEqual(try ModelTestSupport.count(model, "templates"), 0)
    }
}