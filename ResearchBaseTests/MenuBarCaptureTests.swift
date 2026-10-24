//
//  MenuBarCaptureTests.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 22/10/26.
//


//
//  MenuBarCaptureTests.swift
//  ResearchBaseTests
//
//  Owner: Agent 47 · Feature: X-02
//

import XCTest
@testable import ResearchBase

@MainActor
final class MenuBarCaptureTests: XCTestCase {

    private final class FakeLoginItem: LoginItemControlling {
        var isEnabled = false
        var needsApproval = false
        var failure: Error?
        var openedSettings = 0
        /// false = macOS accepts the request but waits for approval, so `isEnabled` stays false.
        var registersImmediately = true

        func setEnabled(_ enabled: Bool) throws {
            if let failure { throw failure }
            if registersImmediately || !enabled { isEnabled = enabled }
        }
        func openSystemSettings() { openedSettings += 1 }
    }

    private struct Refused: LocalizedError { var errorDescription: String? { "refused" } }

    private func freshDefaults() -> UserDefaults {
        let name = "MenuBarCaptureTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Status

    func testStatusFollowsTheServerAndPause() {
        XCTAssertEqual(MenuBarCaptureStatus(server: nil, isPaused: false), .off)
        XCTAssertEqual(MenuBarCaptureStatus(server: .stopped, isPaused: false), .off)
        XCTAssertEqual(MenuBarCaptureStatus(server: .listening(port: 1), isPaused: false), .on)
        XCTAssertEqual(MenuBarCaptureStatus(server: .listening(port: 1), isPaused: true), .paused)
        XCTAssertEqual(MenuBarCaptureStatus(server: .failed("port busy"), isPaused: false), .failed("port busy"))

        XCTAssertEqual(MenuBarCaptureStatus.on.title, "Capture on")
        XCTAssertEqual(MenuBarCaptureStatus.paused.title, "Capture paused")
        XCTAssertEqual(MenuBarCaptureStatus.failed("x").detail, "x")
        XCTAssertNil(MenuBarCaptureStatus.on.detail)

        XCTAssertTrue(MenuBarCaptureStatus.on.canTogglePause)
        XCTAssertTrue(MenuBarCaptureStatus.paused.canTogglePause)
        XCTAssertFalse(MenuBarCaptureStatus.off.canTogglePause)
        XCTAssertFalse(MenuBarCaptureStatus.failed("x").canTogglePause)
    }

    // MARK: Inbox count and titles

    func testInboxCountOnlyCountsLiveInboxPapers() throws {
        let library = try ModelTestSupport.makeModel(self)
        defer { library.library.close() }

        let model = MenuBarCaptureModel(library: library, defaults: freshDefaults(), loginItem: FakeLoginItem())
        XCTAssertEqual(model.inboxCount, 0)
        XCTAssertEqual(model.inboxTitle, "Open Inbox")

        try ModelTestSupport.item(library, title: "Waiting one", author: "A", given: "B", state: .inbox)
        try ModelTestSupport.item(library, title: "Waiting two", author: "C", given: "D", state: .inbox)
        let trashed = try ModelTestSupport.item(library, title: "Waiting trashed", author: "E", given: "F", state: .inbox)
        try ModelTestSupport.item(library, title: "Accepted", author: "G", given: "H", state: .accepted)
        try ModelTestSupport.trash(library, itemID: trashed.id)

        model.refresh()
        XCTAssertEqual(model.inboxCount, 2)
        XCTAssertEqual(model.inboxTitle, "Open Inbox (2)")
    }

    // MARK: Pause

    func testPauseAndResumeReachTheServer() throws {
        let library = try ModelTestSupport.makeModel(self)
        defer { library.library.close() }
        let server = CaptureServer(model: library, token: CaptureServer.generateToken())
        let model = MenuBarCaptureModel(library: library, server: server, defaults: freshDefaults(), loginItem: FakeLoginItem())

        // Not listening: nothing to pause.
        XCTAssertEqual(model.status, .off)
        model.togglePause()
        XCTAssertFalse(server.isPaused)
        XCTAssertEqual(model.pauseTitle, "Pause capture")
    }

    // MARK: Preferences

    func testPreferencesDefaultsAndPersistence() {
        let defaults = freshDefaults()
        XCTAssertTrue(MenuBarCaptureSettings.value(forKey: MenuBarCaptureSettings.keepCaptureKey, default: true, in: defaults))
        XCTAssertFalse(MenuBarCaptureSettings.value(forKey: MenuBarCaptureSettings.openAtLoginKey, default: false, in: defaults))

        let model = MenuBarCaptureModel(defaults: defaults, loginItem: FakeLoginItem())
        XCTAssertTrue(model.keepCaptureAvailable, "menu-bar mode is on by default")
        XCTAssertFalse(model.openAtLogin, "no login item until the person asks for it")

        model.keepCaptureAvailable = false
        XCTAssertFalse(MenuBarCaptureSettings.value(forKey: MenuBarCaptureSettings.keepCaptureKey, default: true, in: defaults))

        let again = MenuBarCaptureModel(defaults: defaults, loginItem: FakeLoginItem())
        XCTAssertFalse(again.keepCaptureAvailable)
    }

    // MARK: Login item

    func testOpenAtLoginRegistersAndUnregisters() {
        let login = FakeLoginItem()
        let defaults = freshDefaults()
        let model = MenuBarCaptureModel(defaults: defaults, loginItem: login)

        model.setOpenAtLogin(true)
        XCTAssertTrue(login.isEnabled)
        XCTAssertTrue(model.openAtLogin)
        XCTAssertNil(model.loginItemMessage)
        XCTAssertTrue(MenuBarCaptureSettings.value(forKey: MenuBarCaptureSettings.openAtLoginKey, default: false, in: defaults))

        model.setOpenAtLogin(false)
        XCTAssertFalse(login.isEnabled)
        XCTAssertFalse(model.openAtLogin)
    }

    func testRefusedLoginItemShowsWhyAndStaysOff() {
        let login = FakeLoginItem()
        login.failure = Refused()
        let model = MenuBarCaptureModel(defaults: freshDefaults(), loginItem: login)

        model.setOpenAtLogin(true)

        XCTAssertFalse(model.openAtLogin, "the switch goes back")
        XCTAssertEqual(model.loginItemMessage, "Could not change the login item: refused")
    }

    func testLoginItemWaitingForApprovalSendsThePersonToSystemSettings() {
        let login = FakeLoginItem()
        login.needsApproval = true
        login.registersImmediately = false
        let model = MenuBarCaptureModel(defaults: freshDefaults(), loginItem: login)

        model.setOpenAtLogin(true)

        XCTAssertEqual(login.openedSettings, 1)
        XCTAssertNotNil(model.loginItemMessage)
        XCTAssertFalse(model.openAtLogin)
    }

    func testOpenAtLoginReflectsWhatMacOSSaysNotWhatWeStored() {
        let login = FakeLoginItem()
        login.isEnabled = true       // for example turned on in System Settings
        let model = MenuBarCaptureModel(defaults: freshDefaults(), loginItem: login)
        XCTAssertTrue(model.openAtLogin)

        login.isEnabled = false
        model.refresh()
        XCTAssertFalse(model.openAtLogin)
    }

    // MARK: Actions and monitoring

    func testActionsAreForwarded() {
        var calls: [String] = []
        let actions = MenuBarCaptureActions(
            openQuickAdd: { calls.append("add") }, openInbox: { calls.append("inbox") },
            openMainWindow: { calls.append("window") }, quit: { calls.append("quit") })
        let model = MenuBarCaptureModel(actions: actions, defaults: freshDefaults(), loginItem: FakeLoginItem())

        model.actions.openQuickAdd()
        model.actions.openInbox()
        model.actions.openMainWindow()
        model.actions.quit()

        XCTAssertEqual(calls, ["add", "inbox", "window", "quit"])
    }

    func testMonitoringPicksUpNewInboxPapersAndStops() async throws {
        let library = try ModelTestSupport.makeModel(self)
        defer { library.library.close() }
        let model = MenuBarCaptureModel(library: library, defaults: freshDefaults(), loginItem: FakeLoginItem())

        model.startMonitoring(every: 0.5)
        model.startMonitoring(every: 0.5)   // second call is ignored

        try ModelTestSupport.item(library, title: "Arrives later", author: "A", given: "B", state: .inbox)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(model.inboxCount, 1)

        model.stopMonitoring()
        try ModelTestSupport.item(library, title: "Arrives after stop", author: "C", given: "D", state: .inbox)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(model.inboxCount, 1, "stopped monitors do not refresh")
    }
}