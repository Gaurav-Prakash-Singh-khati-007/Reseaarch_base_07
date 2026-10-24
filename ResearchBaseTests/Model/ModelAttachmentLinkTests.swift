//
//  ModelAttachmentLinkTests.swift
//  ResearchBaseTests
//
//  Phase 1, Step 1B (F-10, F-06): files stored by fingerprint, and the one link table.
//

import XCTest
@testable import ResearchBase

@MainActor
final class ModelAttachmentLinkTests: XCTestCase {

    private let helloSHA = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    /// Every real file under files/ (hidden temp files included).
    private func storedFiles(_ model: LibraryModel) -> [String] {
        var found: [String] = []
        let base = model.library.filesURL
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(url.lastPathComponent)
            }
        }
        return found
    }

    // MARK: Attachments

    func testFileIsStoredByFingerprintWithARelativePath() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let source = try ModelTestSupport.makeFile(self)

        let attachment = try model.attachments.add(fileAt: source, to: item.id)

        XCTAssertEqual(attachment.sha256, helloSHA)
        XCTAssertEqual(attachment.relativePath, "files/2c/\(helloSHA).pdf")
        XCTAssertEqual(attachment.originalName, "hello.pdf")
        XCTAssertEqual(attachment.bytes, 5)
        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertTrue(attachment.isPrimary, "the first PDF becomes the primary file")

        let stored = try model.attachments.fileURL(for: attachment)
        XCTAssertEqual(try Data(contentsOf: stored), Data("hello".utf8))
        XCTAssertTrue(try model.attachments.verify(attachment))
    }

    func testTheSameFileIsStoredOnceNoMatterHowOften() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let one = try ModelTestSupport.item(model, title: "One", author: "A")
        let two = try ModelTestSupport.item(model, title: "Two", author: "B")

        let first = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self), to: one.id)
        let again = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "renamed.pdf"), to: one.id)
        let other = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "copy.pdf"), to: two.id)

        XCTAssertEqual(first.id, again.id, "same file, same paper: the same attachment")
        XCTAssertEqual(try model.attachments.attachments(of: one.id).count, 1)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertEqual(try model.attachments.rowCount(sha256: helloSHA), 2)
        XCTAssertEqual(storedFiles(model), ["\(helloSHA).pdf"], "one copy on disk for two papers")
    }

    func testPrimaryFileRules() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)

        let supplement = try model.attachments.add(
            fileAt: try ModelTestSupport.makeFile(self, name: "data.csv", content: "a,b"), to: item.id, kind: .data)
        XCTAssertFalse(supplement.isPrimary, "only a PDF becomes primary automatically")

        let pdf = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "a.pdf", content: "pdf one"), to: item.id)
        let pdf2 = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "b.pdf", content: "pdf two"), to: item.id)
        XCTAssertTrue(pdf.isPrimary)
        XCTAssertFalse(pdf2.isPrimary)

        try model.attachments.setPrimary(attachmentID: pdf2.id)
        let list = try model.attachments.attachments(of: item.id)
        XCTAssertEqual(list.first?.id, pdf2.id, "primary file first")
        XCTAssertEqual(list.filter { $0.isPrimary }.count, 1)
        XCTAssertEqual(list.count, 3)
    }

    func testAStoredFileIsNeverOverwritten() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let attachment = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self), to: item.id)
        let stored = try model.attachments.fileURL(for: attachment)

        // Damage the stored copy.
        try Data("damaged".utf8).write(to: stored)
        XCTAssertFalse(try model.attachments.verify(attachment))

        let other = try ModelTestSupport.item(model, title: "Other", author: "Z")
        XCTAssertThrowsError(try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "again.pdf"), to: other.id)) {
            guard case .storedFileDamaged = ($0 as? ModelError) else { return XCTFail("expected storedFileDamaged") }
        }
        XCTAssertEqual(try Data(contentsOf: stored), Data("damaged".utf8), "the stored file was left exactly as it was")
        XCTAssertEqual(try ModelTestSupport.count(model, "attachments"), 1)
    }

    func testMissingFileOrItemChangesNothingAndLeavesNoTempFile() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")

        XCTAssertThrowsError(try model.attachments.add(fileAt: gone, to: item.id)) {
            guard case .fileMissing = ($0 as? ModelError) else { return XCTFail("expected fileMissing") }
        }
        XCTAssertThrowsError(try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self), to: "no-such-item")) {
            guard case .notFound = ($0 as? ModelError) else { return XCTFail("expected notFound") }
        }

        XCTAssertEqual(try ModelTestSupport.count(model, "attachments"), 0)
        XCTAssertTrue(storedFiles(model).isEmpty)
    }

    func testAddingAgainBringsBackAnAttachmentThatWasInTheTrash() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let first = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self), to: item.id)
        try model.database.run("UPDATE attachments SET deleted_at = ? WHERE id = ?", [.text(Library.nowISO()), .text(first.id)])
        XCTAssertTrue(try model.attachments.attachments(of: item.id).isEmpty)

        let back = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self), to: item.id)

        XCTAssertEqual(back.id, first.id)
        XCTAssertNil(back.deletedAt)
        XCTAssertEqual(sink.entries(type: "attachment", action: .restore).count, 1)
        XCTAssertEqual(try ModelTestSupport.count(model, "attachments"), 1)
    }

    func testRelativePathsStayInsideTheLibrary() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let item = try ModelTestSupport.item(model)
        let attachment = try model.attachments.add(fileAt: try ModelTestSupport.makeFile(self, name: "noext", content: "x"), to: item.id)

        XCTAssertFalse(attachment.relativePath.hasPrefix("/"))
        XCTAssertFalse(attachment.relativePath.contains(".."))
        XCTAssertTrue(try model.attachments.fileURL(for: attachment).path.hasPrefix(model.library.root.path))
        XCTAssertFalse(attachment.relativePath.hasSuffix("."), "a file without an extension has no trailing dot")
    }

    // MARK: Links

    func testALinkIsOneRowSeenFromBothSides() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = try ModelTestSupport.item(model, title: "A", author: "A")
        let b = try ModelTestSupport.item(model, title: "B", author: "B")
        let from = LinkEnd(.item, a.id)
        let to = LinkEnd(.item, b.id)

        let link = try model.links.add(from: from, to: to, rel: .cites, note: "see section 3")

        let fromA = try model.links.links(for: from)
        XCTAssertEqual(fromA.count, 1)
        XCTAssertEqual(fromA.first?.direction, .outgoing)
        XCTAssertEqual(fromA.first?.other, to)

        let fromB = try model.links.links(for: to)
        XCTAssertEqual(fromB.first?.direction, .incoming)
        XCTAssertEqual(fromB.first?.other, from)
        XCTAssertEqual(fromB.first?.link.id, link.id)

        XCTAssertEqual(try ModelTestSupport.count(model, "links"), 1)
        XCTAssertEqual(try model.links.usedBy(to), [from])
        XCTAssertTrue(try model.links.usedBy(from).isEmpty)
    }

    func testAddingTheSameLinkTwiceReturnsTheFirst() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let a = LinkEnd(.item, try ModelTestSupport.item(model, title: "A", author: "A").id)
        let b = LinkEnd(.item, try ModelTestSupport.item(model, title: "B", author: "B").id)

        let first = try model.links.add(from: a, to: b, rel: .supports)
        sink.clear()
        let second = try model.links.add(from: a, to: b, rel: .supports)

        XCTAssertEqual(first, second)
        XCTAssertTrue(sink.entries.isEmpty)
        XCTAssertEqual(try ModelTestSupport.count(model, "links"), 1)

        // A different relation, and the opposite direction of a directed relation, are different links.
        _ = try model.links.add(from: a, to: b, rel: .contradicts)
        _ = try model.links.add(from: b, to: a, rel: .supports)
        XCTAssertEqual(try ModelTestSupport.count(model, "links"), 3)
        XCTAssertEqual(try model.links.links(for: a, rel: .supports).count, 2)
    }

    func testRelatedWorksBothWaysWithoutADuplicate() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = LinkEnd(.item, try ModelTestSupport.item(model, title: "A", author: "A").id)
        let b = LinkEnd(.item, try ModelTestSupport.item(model, title: "B", author: "B").id)

        let first = try model.links.add(from: a, to: b)
        let reverse = try model.links.add(from: b, to: a)

        XCTAssertEqual(first.id, reverse.id)
        XCTAssertEqual(try ModelTestSupport.count(model, "links"), 1)
        XCTAssertEqual(try model.links.count(for: a), 1)
    }

    func testAnyKindOfRecordCanBeLinkedAndWhereUsedFindsThemAll() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let paper = LinkEnd(.item, try ModelTestSupport.item(model).id)
        let thought = LinkEnd(.thought, try ModelTestSupport.insertThought(model))
        let experiment = LinkEnd(.experiment, try ModelTestSupport.insertExperiment(model))
        let draft = LinkEnd(.draft, try ModelTestSupport.insertDraft(model))
        let project = LinkEnd(.project, try ModelTestSupport.insertProject(model))
        let folder = LinkEnd(.collection, try model.collections.create(name: "F").id)

        try model.links.add(from: thought, to: paper, rel: .supports)
        try model.links.add(from: experiment, to: paper, rel: .uses)
        try model.links.add(from: draft, to: paper, rel: .cites)
        try model.links.add(from: project, to: paper, rel: .partOf)
        try model.links.add(from: folder, to: paper)

        XCTAssertEqual(Set(try model.links.usedBy(paper)), [thought, experiment, draft, project, folder])
        XCTAssertEqual(try model.links.count(for: paper), 5)
    }

    func testBadLinksAreRefused() throws {

        let model = try ModelTestSupport.makeModel(self)
        defer { model.library.close() }

        let a = LinkEnd(.item, try ModelTestSupport.item(model).id)

        XCTAssertThrowsError(try model.links.add(from: a, to: a)) {
            XCTAssertEqual($0 as? ModelError, .linkToSelf)
        }
        XCTAssertThrowsError(try model.links.add(from: a, to: LinkEnd(.thought, "ghost"))) {
            XCTAssertEqual($0 as? ModelError, .linkTargetMissing(type: "thought", id: "ghost"))
        }
        XCTAssertThrowsError(try model.links.add(from: LinkEnd(.draft, "ghost"), to: a))
        XCTAssertEqual(try ModelTestSupport.count(model, "links"), 0)
    }

    func testNoteAndRemoveAreReportedSoTheyCanBeUndone() throws {

        let sink = RecordingChangeSink()
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        defer { model.library.close() }

        let a = LinkEnd(.item, try ModelTestSupport.item(model, title: "A", author: "A").id)
        let b = LinkEnd(.item, try ModelTestSupport.item(model, title: "B", author: "B").id)
        let link = try model.links.add(from: a, to: b, rel: .extends)

        XCTAssertEqual(try model.links.setNote(linkID: link.id, to: "builds on this").note, "builds on this")
        XCTAssertEqual(sink.entries(type: "link", field: "note").last?.oldValue, "")

        sink.clear()
        try model.links.remove(linkID: link.id)

        XCTAssertNil(try model.links.link(id: link.id))
        XCTAssertNotNil(try model.items.fetch(id: a.id), "removing a link never removes a paper")
        let removal = try XCTUnwrap(sink.entries(type: "link", action: .delete).first)
        XCTAssertTrue(try XCTUnwrap(removal.oldValue).contains("extends"))
        XCTAssertThrowsError(try model.links.remove(linkID: link.id))
    }
}
