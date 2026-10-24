//
//  ResetServiceTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 24/10/26.
//


//
//  ResetServiceTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 80. Every test works in temp folders with a private
//  UserDefaults suite and fake Keychain/notification hooks. Nothing here
//  can touch real ResearchBase data.
//

import XCTest
@testable import ResearchBase

final class ResetServiceTests: XCTestCase {

    // MARK: Helpers

    private struct Sandbox {
        let root: URL
        let locations: ResetService.Locations
        let suite: String
        var support: URL { locations.applicationSupport }
        var docs: URL { locations.documents }
        var library: URL { docs.appendingPathComponent(ResetService.libraryFolderName, isDirectory: true) }
        var appData: URL { support.appendingPathComponent(ResetService.supportFolderName, isDirectory: true) }
    }

    private var secretsDeleted = 0
    private var notificationsCleared = 0

    private func makeSandbox() throws -> Sandbox {
        let root = try TestSupport.makeTempDirectory(self)
        let fm = FileManager.default
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let saved = root.appendingPathComponent("Saved", isDirectory: true)
        for url in [support, docs, caches.deletingLastPathComponent(), saved.deletingLastPathComponent()] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let suite = "rb.tests.reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        secretsDeleted = 0
        notificationsCleared = 0
        let locations = ResetService.Locations(
            applicationSupport: support,
            documents: docs,
            caches: caches.appendingPathComponent("com.test.rb", isDirectory: true),
            savedState: saved.appendingPathComponent("com.test.rb.savedState", isDirectory: true),
            bundleID: "com.test.rb",
            defaults: defaults,
            defaultsDomain: suite,
            deleteSecrets: { [unowned self] in self.secretsDeleted += 2; return 2 },
            clearNotifications: { [unowned self] in self.notificationsCleared += 1 }
        )
        return Sandbox(root: root, locations: locations, suite: suite)
    }

    @discardableResult
    private func write(_ url: URL, bytes: Int = 10) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func fill(_ box: Sandbox) throws {
        try write(box.library.appendingPathComponent("library.sqlite"))
        try write(box.library.appendingPathComponent("library.sqlite-wal"))
        try write(box.library.appendingPathComponent("files/ab/paper.pdf"), bytes: 500)
        try write(box.library.appendingPathComponent("backups/2026-10-01/library.sqlite"))
        try write(box.support.appendingPathComponent("default.store"))
        try write(box.support.appendingPathComponent("default.store-shm"))
        try write(box.support.appendingPathComponent("default.store-wal"))
        try write(box.appData.appendingPathComponent("Papers/old.pdf"))
        try write(box.appData.appendingPathComponent("Backups/pre-change.researchbase"))
        try write(box.locations.caches.appendingPathComponent("blob"))
        try write(box.locations.savedState.appendingPathComponent("windows.plist"))
        // Another app's data in the same parent folders must survive.
        try write(box.support.appendingPathComponent("OtherApp/data.db"))
        try write(box.docs.appendingPathComponent("My Thesis.pdf"))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Names

    @MainActor
    func testLibraryFolderNameMatchesTheLibrary() {
        XCTAssertEqual(ResetService.libraryFolderName, Library.folderName)
        XCTAssertTrue(Library.subfolderNames.contains(ResetService.libraryBackupsFolderName))
    }

    // MARK: Erase

    func testEraseKeepsBackupsByDefault() throws {
        let box = try makeSandbox()
        try fill(box)

        let outcome = ResetService.erase(keepBackups: true, locations: box.locations)

        XCTAssertFalse(exists(box.library.appendingPathComponent("library.sqlite")))
        XCTAssertFalse(exists(box.library.appendingPathComponent("library.sqlite-wal")))
        XCTAssertFalse(exists(box.library.appendingPathComponent("files")))
        XCTAssertTrue(exists(box.library.appendingPathComponent("backups/2026-10-01/library.sqlite")))

        XCTAssertFalse(exists(box.support.appendingPathComponent("default.store")))
        XCTAssertFalse(exists(box.support.appendingPathComponent("default.store-shm")))
        XCTAssertFalse(exists(box.support.appendingPathComponent("default.store-wal")))

        XCTAssertFalse(exists(box.appData.appendingPathComponent("Papers")))
        XCTAssertTrue(exists(box.appData.appendingPathComponent("Backups/pre-change.researchbase")))

        XCTAssertFalse(exists(box.locations.caches))
        XCTAssertFalse(exists(box.locations.savedState))

        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertEqual(outcome.secretsRemoved, 2)
        XCTAssertEqual(notificationsCleared, 1)
        XCTAssertTrue(outcome.summary.contains("backups were kept"))
    }

    func testEraseWithoutKeepingBackupsRemovesThem() throws {
        let box = try makeSandbox()
        try fill(box)

        let outcome = ResetService.erase(keepBackups: false, locations: box.locations)

        XCTAssertFalse(exists(box.library))
        XCTAssertFalse(exists(box.appData))
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertTrue(outcome.summary.contains("Backups were erased too"))
    }

    func testEraseNeverTouchesOtherFiles() throws {
        let box = try makeSandbox()
        try fill(box)

        _ = ResetService.erase(keepBackups: false, locations: box.locations)

        XCTAssertTrue(exists(box.support.appendingPathComponent("OtherApp/data.db")))
        XCTAssertTrue(exists(box.docs.appendingPathComponent("My Thesis.pdf")))
        XCTAssertTrue(exists(box.support))
        XCTAssertTrue(exists(box.docs))
    }

    func testEraseOnEmptyMachineIsFine() throws {
        let box = try makeSandbox()
        let outcome = ResetService.erase(keepBackups: true, locations: box.locations)
        XCTAssertTrue(outcome.removedLabels.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.summary.contains("Nothing needed to be erased"))
    }

    // MARK: Flag handling

    func testNoFlagMeansNothingHappens() throws {
        let box = try makeSandbox()
        try fill(box)

        let ran = ResetService.performPendingEraseIfNeeded(locations: box.locations)

        XCTAssertFalse(ran)
        XCTAssertTrue(exists(box.library.appendingPathComponent("library.sqlite")))
    }

    func testFreshFlagErasesAndClearsItself() throws {
        let box = try makeSandbox()
        try fill(box)
        let d = box.locations.defaults
        d.set(true, forKey: ResetService.pendingEraseKey)
        d.set(Date(), forKey: ResetService.requestedAtKey)
        d.set(true, forKey: ResetService.keepBackupsKey)
        d.set(0.8, forKey: "rb.latex.treeWidth")

        let ran = ResetService.performPendingEraseIfNeeded(locations: box.locations)

        XCTAssertTrue(ran)
        XCTAssertFalse(exists(box.library.appendingPathComponent("library.sqlite")))
        XCTAssertFalse(d.bool(forKey: ResetService.pendingEraseKey))
        XCTAssertNil(d.object(forKey: "rb.latex.treeWidth"), "settings must be reset")
        XCTAssertTrue((d.string(forKey: ResetService.summaryKey) ?? "").contains("Erased"))

        // A second launch does nothing.
        XCTAssertFalse(ResetService.performPendingEraseIfNeeded(locations: box.locations))
    }

    func testStaleFlagIsIgnoredAndCleared() throws {
        let box = try makeSandbox()
        try fill(box)
        let d = box.locations.defaults
        d.set(true, forKey: ResetService.pendingEraseKey)
        d.set(Date().addingTimeInterval(-3600), forKey: ResetService.requestedAtKey)

        let ran = ResetService.performPendingEraseIfNeeded(locations: box.locations)

        XCTAssertFalse(ran)
        XCTAssertTrue(exists(box.library.appendingPathComponent("library.sqlite")))
        XCTAssertFalse(d.bool(forKey: ResetService.pendingEraseKey))
    }

    func testFlagWithNoDateIsIgnored() throws {
        let box = try makeSandbox()
        try fill(box)
        box.locations.defaults.set(true, forKey: ResetService.pendingEraseKey)

        XCTAssertFalse(ResetService.performPendingEraseIfNeeded(locations: box.locations))
        XCTAssertTrue(exists(box.library.appendingPathComponent("library.sqlite")))
    }

    func testFlagFromTheFutureIsIgnored() throws {
        let box = try makeSandbox()
        try fill(box)
        let d = box.locations.defaults
        d.set(true, forKey: ResetService.pendingEraseKey)
        d.set(Date().addingTimeInterval(3600), forKey: ResetService.requestedAtKey)

        XCTAssertFalse(ResetService.performPendingEraseIfNeeded(locations: box.locations))
        XCTAssertTrue(exists(box.library.appendingPathComponent("library.sqlite")))
    }

    func testKeepBackupsFlagIsHonoured() throws {
        let box = try makeSandbox()
        try fill(box)
        let d = box.locations.defaults
        d.set(true, forKey: ResetService.pendingEraseKey)
        d.set(Date(), forKey: ResetService.requestedAtKey)
        d.set(false, forKey: ResetService.keepBackupsKey)

        XCTAssertTrue(ResetService.performPendingEraseIfNeeded(locations: box.locations))
        XCTAssertFalse(exists(box.library))
        XCTAssertFalse(exists(box.appData))
    }

    // MARK: Preview

    func testPlannedItemsListSizesAndKeepRules() throws {
        let box = try makeSandbox()
        try fill(box)

        let keeping = ResetService.plannedItems(keepBackups: true, locations: box.locations)
        let wiping = ResetService.plannedItems(keepBackups: false, locations: box.locations)

        let libraryKeeping = try XCTUnwrap(keeping.first { $0.url.lastPathComponent == ResetService.libraryFolderName })
        let libraryWiping = try XCTUnwrap(wiping.first { $0.url.lastPathComponent == ResetService.libraryFolderName })
        XCTAssertEqual(libraryKeeping.keeping, [ResetService.libraryBackupsFolderName])
        XCTAssertTrue(libraryWiping.keeping.isEmpty)
        XCTAssertGreaterThan(libraryWiping.bytes, libraryKeeping.bytes)
        XCTAssertTrue(exists(box.library.appendingPathComponent("library.sqlite")), "a preview must delete nothing")
    }

    // MARK: Path safety

    func testIsStrictlyInside() {
        let parent = URL(fileURLWithPath: "/tmp/rb-parent", isDirectory: true)
        XCTAssertTrue(ResetService.isStrictlyInside(parent.appendingPathComponent("a"), parent: parent))
        XCTAssertFalse(ResetService.isStrictlyInside(parent, parent: parent))
        XCTAssertFalse(ResetService.isStrictlyInside(URL(fileURLWithPath: "/tmp/other"), parent: parent))
        XCTAssertFalse(ResetService.isStrictlyInside(URL(fileURLWithPath: "/tmp/rb-parent-sibling"), parent: parent))
        XCTAssertFalse(ResetService.isStrictlyInside(URL(fileURLWithPath: "/tmp"), parent: URL(fileURLWithPath: "/")))
    }
}