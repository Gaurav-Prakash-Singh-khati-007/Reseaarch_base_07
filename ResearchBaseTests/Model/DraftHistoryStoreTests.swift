//
//  DraftHistoryStoreTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 20/10/26.
//


//
//  DraftHistoryStoreTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 21 · Features: F-36
//

import XCTest
@testable import ResearchBase

@MainActor
final class DraftHistoryStoreTests: XCTestCase {

    private func makeStore(sink: ChangeSink? = nil) throws -> (LibraryModel, DraftHistoryStore) {
        let model = try ModelTestSupport.makeModel(self, sink: sink)
        return (model, DraftHistoryStore(model: model))
    }

    /// A draft row plus a real folder with a main.tex.
    private func makeDraft(_ model: LibraryModel, text: String = "Line one\nLine two\n") throws -> String {
        let id = try ModelTestSupport.insertDraft(model)
        let folder = model.library.root.appendingPathComponent("drafts/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent("main.tex"))
        return id
    }

    private func folder(_ model: LibraryModel, _ id: String) -> URL {
        model.library.root.appendingPathComponent("drafts/\(id)", isDirectory: true)
    }

    private func write(_ model: LibraryModel, _ id: String, _ path: String, _ text: String) throws {
        let url = folder(model, id).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ model: LibraryModel, _ id: String, _ path: String) -> String? {
        try? String(contentsOf: folder(model, id).appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Take

    func testSnapshotMakesARowAndAZipOutsideTheDraftFolder() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model, text: "Hello brave new world\n")
        let snap = try store.takeSnapshot(draftID: draftID, label: "  Sent to supervisor ")

        XCTAssertEqual(snap.label, "Sent to supervisor")
        XCTAssertFalse(snap.auto)
        XCTAssertEqual(snap.words, 4)
        XCTAssertEqual(snap.bundlePath, "drafts/.history/\(draftID)/\(snap.id).zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.library.root.appendingPathComponent(snap.bundlePath).path))
        XCTAssertEqual(try store.snapshot(id: snap.id), snap)
        XCTAssertEqual(try store.count(forDraft: draftID), 1)

        // The draft folder itself is not changed.
        let inside = try FileManager.default.contentsOfDirectory(atPath: folder(model, draftID).path)
        XCTAssertEqual(inside, ["main.tex"])
    }

    func testSnapshotOfMissingDraftOrFolderIsRefused() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        XCTAssertThrowsError(try store.takeSnapshot(draftID: "nope"))

        let id = try ModelTestSupport.insertDraft(model)      // row, but no folder on disk
        XCTAssertThrowsError(try store.takeSnapshot(draftID: id))
        XCTAssertEqual(try store.count(forDraft: id), 0)
    }

    func testFailedChangeSinkLeavesNoZipBehind() throws {
        let (model, store) = try makeStore(sink: FailingChangeSink(failOnCall: 0))
        defer { model.library.close() }

        let draftID = try makeDraft(model)
        XCTAssertThrowsError(try store.takeSnapshot(draftID: draftID))
        XCTAssertEqual(try store.count(forDraft: draftID), 0)

        let zips = (try? FileManager.default.contentsOfDirectory(
            atPath: model.library.draftsURL.appendingPathComponent(".history/\(draftID)").path)) ?? []
        XCTAssertTrue(zips.isEmpty)
    }

    func testSnapshotsAreListedNewestFirstAndCanBeRenamed() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model)
        let first = try store.takeSnapshot(draftID: draftID, label: "one")
        let second = try store.takeSnapshot(draftID: draftID, label: "two")

        XCTAssertEqual(try store.snapshots(forDraft: draftID).map(\.id), [second.id, first.id])

        XCTAssertEqual(try store.setLabel(snapshotID: first.id, to: "  Final  ").label, "Final")
        XCTAssertEqual(try store.setLabel(snapshotID: first.id, to: "").label, "")
        XCTAssertThrowsError(try store.setLabel(snapshotID: "nope", to: "x"))
    }

    // MARK: Automatic snapshots

    func testAutomaticSnapshotOnlyWhenEditedAndEnoughTimePassed() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model)

        // No snapshot yet: one is taken.
        let first = try store.takeAutomaticSnapshotIfDue(draftID: draftID)
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.auto, true)
        XCTAssertEqual(first?.label, "")

        // Not edited since: nothing.
        XCTAssertNil(try store.takeAutomaticSnapshotIfDue(draftID: draftID, now: Date().addingTimeInterval(7200)))

        // Edited, but only a minute later: too soon.
        let edited = Library.nowISO(Date().addingTimeInterval(10))
        try model.database.run("UPDATE drafts SET updated_at = ? WHERE id = ?", [.text(edited), .text(draftID)])
        XCTAssertNil(try store.takeAutomaticSnapshotIfDue(draftID: draftID, now: Date().addingTimeInterval(60)))

        // Edited and 31+ minutes later: taken.
        XCTAssertNotNil(try store.takeAutomaticSnapshotIfDue(draftID: draftID, now: Date().addingTimeInterval(3600)))
        XCTAssertEqual(try store.count(forDraft: draftID), 2)
    }

    // MARK: Compare

    func testDiffShowsRemovedAddedAndSameLines() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model, text: "alpha\nbeta\ngamma")
        let snap = try store.takeSnapshot(draftID: draftID)

        try write(model, draftID, "main.tex", "alpha\nBETA\ngamma\ndelta")

        let lines = try store.diff(snapshotID: snap.id)
        XCTAssertEqual(lines, [
            StoredDiffLine(kind: .same, text: "alpha"),
            StoredDiffLine(kind: .removed, text: "beta"),
            StoredDiffLine(kind: .added, text: "BETA"),
            StoredDiffLine(kind: .same, text: "gamma"),
            StoredDiffLine(kind: .added, text: "delta")
        ])

        XCTAssertEqual(try store.fileText(snapshotID: snap.id, path: "main.tex"), "alpha\nbeta\ngamma")
    }

    func testDiffOfAFileThatOnlyExistsNowIsAllAdded() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model)
        let snap = try store.takeSnapshot(draftID: draftID)
        try write(model, draftID, "chapters/new.tex", "x")

        XCTAssertEqual(try store.diff(snapshotID: snap.id, path: "chapters/new.tex").filter { $0.kind == .added }.count, 1)
        XCTAssertThrowsError(try store.diff(snapshotID: snap.id, path: "missing.tex"))
        XCTAssertThrowsError(try store.diff(snapshotID: snap.id, path: "../x"))
        XCTAssertThrowsError(try store.fileText(snapshotID: snap.id, path: "/etc/passwd"))
    }

    func testDiffLinesHandlesEmptyAndIdenticalText() {
        XCTAssertEqual(DraftHistoryStore.diffLines(old: "a", new: "a"), [StoredDiffLine(kind: .same, text: "a")])
        XCTAssertEqual(DraftHistoryStore.diffLines(old: "", new: "x"), [
            StoredDiffLine(kind: .removed, text: ""),
            StoredDiffLine(kind: .added, text: "x")
        ])
        XCTAssertEqual(DraftHistoryStore.diffLines(old: "a\nb", new: "a").map(\.kind), [.same, .removed])
    }

    func testCountWordsIgnoresCommentsAndCommands() {
        let source = """
        \\documentclass{article}
        \\begin{document}
        % a whole comment line
        Hello \\textbf{brave} world, see \\cite{key2020}. 50% done % trailing
        \\end{document}
        """
        // "50%" starts a LaTeX comment, so the line counts: Hello, brave, world, see, 50 = 5
        XCTAssertEqual(DraftHistoryStore.countWords(inLatex: source), 5)
    }

    // MARK: Restore

    func testRestorePutsTheOldFolderBackAfterASafetySnapshot() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let draftID = try makeDraft(model, text: "original")
        try write(model, draftID, "figures/a.txt", "figure")
        let old = try store.takeSnapshot(draftID: draftID, label: "Good version")

        try write(model, draftID, "main.tex", "ruined")
        try write(model, draftID, "extra.tex", "new file")
        try FileManager.default.removeItem(at: folder(model, draftID).appendingPathComponent("figures"))
        sink.clear()

        let safety = try store.restore(snapshotID: old.id)

        XCTAssertEqual(read(model, draftID, "main.tex"), "original")
        XCTAssertEqual(read(model, draftID, "figures/a.txt"), "figure")
        XCTAssertNil(read(model, draftID, "extra.tex"), "files added after the snapshot are gone")

        XCTAssertEqual(safety.label, "Before restoring “Good version”")
        XCTAssertTrue(safety.auto)
        XCTAssertEqual(try store.fileText(snapshotID: safety.id, path: "main.tex"), "ruined")
        XCTAssertEqual(try store.fileText(snapshotID: safety.id, path: "extra.tex"), "new file")
        XCTAssertEqual(try store.count(forDraft: draftID), 2)
        XCTAssertEqual(sink.entries(type: "draft_snapshot", action: .restore).count, 1)

        // The restore itself can be undone.
        try store.restore(snapshotID: safety.id)
        XCTAssertEqual(read(model, draftID, "main.tex"), "ruined")

        // No work folders are left behind.
        let hidden = try FileManager.default.contentsOfDirectory(
            atPath: model.library.draftsURL.appendingPathComponent(".history").path)
        XCTAssertEqual(hidden, [draftID])
    }

    func testRestoreIsRefusedWhenTheOldVersionLacksTheMainFile() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model, text: "original")
        let old = try store.takeSnapshot(draftID: draftID)

        // The draft's main file is now one that did not exist back then.
        try write(model, draftID, "paper.tex", "newer")
        try model.database.run("UPDATE drafts SET main_file = 'paper.tex' WHERE id = ?", [.text(draftID)])

        XCTAssertThrowsError(try store.restore(snapshotID: old.id))
        XCTAssertEqual(read(model, draftID, "paper.tex"), "newer", "nothing was changed")
        XCTAssertEqual(try store.count(forDraft: draftID), 1, "and no safety snapshot was kept")
    }

    func testRestoreWithMissingZipChangesNothing() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model, text: "original")
        let old = try store.takeSnapshot(draftID: draftID)
        try FileManager.default.removeItem(at: model.library.root.appendingPathComponent(old.bundlePath))
        try write(model, draftID, "main.tex", "current")

        XCTAssertThrowsError(try store.restore(snapshotID: old.id))
        XCTAssertEqual(read(model, draftID, "main.tex"), "current")
    }

    // MARK: Remove and prune

    func testRemoveDeletesRowAndZipAndReportsIt() throws {
        let sink = RecordingChangeSink()
        let (model, store) = try makeStore(sink: sink)
        defer { model.library.close() }

        let draftID = try makeDraft(model)
        let snap = try store.takeSnapshot(draftID: draftID)
        sink.clear()

        try store.remove(snapshotID: snap.id)

        XCTAssertNil(try store.snapshot(id: snap.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.library.root.appendingPathComponent(snap.bundlePath).path))
        XCTAssertEqual(sink.entries(type: "draft_snapshot", action: .delete).count, 1)
        XCTAssertThrowsError(try store.remove(snapshotID: snap.id))
    }

    func testRemoveAllClearsTheDraftsHistory() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model)
        try store.takeSnapshot(draftID: draftID)
        try store.takeSnapshot(draftID: draftID)

        XCTAssertEqual(try store.removeAll(forDraft: draftID), 2)
        XCTAssertEqual(try store.count(forDraft: draftID), 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: model.library.draftsURL.appendingPathComponent(".history/\(draftID)").path))
    }

    func testPruneOnlyRemovesOldPlainAutomaticSnapshots() throws {
        let (model, store) = try makeStore()
        defer { model.library.close() }

        let draftID = try makeDraft(model)
        let named = try store.takeSnapshot(draftID: draftID, label: "Sent to supervisor", auto: false)
        let before = try store.takeSnapshot(draftID: draftID, label: "Before changing template", auto: true)
        let oldest = try store.takeSnapshot(draftID: draftID, label: "", auto: true)
        let middle = try store.takeSnapshot(draftID: draftID, label: "", auto: true)
        let newest = try store.takeSnapshot(draftID: draftID, label: "", auto: true)

        XCTAssertEqual(try store.pruneAutomatic(forDraft: draftID, keepLatest: 2), 1)

        let left = Set(try store.snapshots(forDraft: draftID).map(\.id))
        XCTAssertEqual(left, [named.id, before.id, middle.id, newest.id])
        XCTAssertFalse(left.contains(oldest.id))
        XCTAssertThrowsError(try store.pruneAutomatic(forDraft: draftID, keepLatest: -1))
    }
}