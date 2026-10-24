//
//  MenuBarCaptureView.swift
//  ResearchBase
//
//  Owner: Agent 47 · Features: X-02 (menu-bar mode)
//
//  Keeps capture one click away while the main window is closed:
//
//      ● Capture on
//      Add by link or DOI…        ⌥⌘N
//      Open Inbox (4)
//      Open ResearchBase
//      Pause capture
//      Quit ResearchBase
//
//  This file supplies the pieces; wiring them into the app (ResearchBaseApp,
//  ContentView) belongs to the wiring agents. What they need to do:
//
//    1. Make one model:      MenuBarCaptureModel(library: model, server: captureServer,
//                                                actions: .init(openQuickAdd: …, openInbox: …, openMainWindow: …))
//       and call `startMonitoring()` once.
//    2. Add the scene:       MenuBarCaptureScene(model: menuBarModel)   (inside `body: some Scene`)
//    3. In the app delegate: applicationShouldTerminateAfterLastWindowClosed returns
//                            `!MenuBarCaptureSettings.keepCaptureAvailable`
//    4. In Settings:         MenuBarCaptureSettingsSection(model: menuBarModel)
//
//  Rules this file follows
//    * Nothing is started on its own: no login item is registered until the person turns
//      "Open at login" on, and capture itself is started elsewhere (CaptureServer).
//    * The capture server is only read and paused/resumed here (`isPaused`); it is never
//      started, stopped or reconfigured from the menu.
//    * Reads the library for the Inbox count only. Nothing is written to it.
//    * Preferences live in UserDefaults (keys below). Both are plain on/off values.
//
//  PUBLIC API
//    enum MenuBarCaptureSettings          keys, defaults, `keepCaptureAvailable` for the app delegate
//    protocol LoginItemControlling        + SystemLoginItem (SMAppService) for the real thing
//    enum MenuBarCaptureStatus            .off, .on, .paused, .failed(String): title, symbol, canPause
//    struct MenuBarCaptureActions         openQuickAdd, openInbox, openMainWindow, quit
//    @MainActor @Observable final class MenuBarCaptureModel
//        status, inboxCount, keepCaptureAvailable, openAtLogin, loginItemMessage
//        refresh(), startMonitoring(), stopMonitoring(), togglePause(), setOpenAtLogin(_:)
//        inboxTitle, pauseTitle
//    struct MenuBarCaptureView            the menu content
//    struct MenuBarCaptureLabel           the menu-bar icon (shows the Inbox count when above 0)
//    struct MenuBarCaptureScene: Scene    MenuBarExtra, inserted only while "keep capture available" is on
//    struct MenuBarCaptureSettingsSection the two toggles + shortcut row for the Settings screen
//

import SwiftUI
import AppKit
import Observation
import ServiceManagement

// MARK: - Settings keys

enum MenuBarCaptureSettings {

    static let keepCaptureKey = "menuBar.keepCaptureAvailable"
    static let openAtLoginKey = "menuBar.openAtLogin"

    /// The menu-bar icon and "keep running with the window closed". On by default (X-02).
    static var keepCaptureAvailable: Bool {
        value(forKey: keepCaptureKey, default: true, in: .standard)
    }

    /// Never turned on for the person: the login item is only registered when they switch it on.
    static var openAtLogin: Bool {
        value(forKey: openAtLoginKey, default: false, in: .standard)
    }

    static func value(forKey key: String, default fallback: Bool, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}

// MARK: - Login item

protocol LoginItemControlling {
    /// True when the app is registered and approved to open at login.
    var isEnabled: Bool { get }
    /// True when macOS is waiting for the person to approve it in System Settings.
    var needsApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

struct SystemLoginItem: LoginItemControlling {

    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Status

enum MenuBarCaptureStatus: Equatable {
    case off
    case on
    case paused
    case failed(String)

    init(server: CaptureServerState?, isPaused: Bool) {
        switch server {
        case .none, .some(.stopped): self = .off
        case .some(.failed(let reason)): self = .failed(reason)
        case .some(.listening): self = isPaused ? .paused : .on
        }
    }

    var title: String {
        switch self {
        case .off: return "Capture off"
        case .on: return "Capture on"
        case .paused: return "Capture paused"
        case .failed: return "Capture unavailable"
        }
    }

    var detail: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }

    /// SF Symbol for the menu-bar icon.
    var symbol: String {
        switch self {
        case .on: return "books.vertical.fill"
        case .off: return "books.vertical"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// Name of the ResearchBase logo image in Assets.xcassets. nil means "use the SF Symbol above",
    /// which we keep for paused/failed so those warnings still look different from the logo.
    var logoImageName: String? {
        switch self {
        case .on, .off: return "MenuBarLogo"
        case .paused, .failed: return nil
        }
    }

    /// "Pause capture" only makes sense while capture is running or already paused.
    var canTogglePause: Bool {
        self == .on || self == .paused
    }
}

// MARK: - Actions the app supplies

struct MenuBarCaptureActions {
    /// Opens the quick add box (F-17), bringing the main window forward if it is closed.
    var openQuickAdd: () -> Void = {}
    /// Opens the Inbox screen.
    var openInbox: () -> Void = {}
    /// Brings the main window forward (re-opening it if it was closed).
    var openMainWindow: () -> Void = { NSApp.activate() }
    var quit: () -> Void = { NSApp.terminate(nil) }
}

// MARK: - Model

@MainActor
@Observable
final class MenuBarCaptureModel {

    private(set) var status: MenuBarCaptureStatus = .off
    private(set) var inboxCount = 0

    /// Shown under the "Open at login" toggle when macOS needs the person's approval, or registering failed.
    private(set) var loginItemMessage: String?

    var keepCaptureAvailable: Bool {
        didSet {
            guard keepCaptureAvailable != oldValue else { return }
            defaults.set(keepCaptureAvailable, forKey: MenuBarCaptureSettings.keepCaptureKey)
        }
    }

    private(set) var openAtLogin: Bool

    let actions: MenuBarCaptureActions

    @ObservationIgnored private let library: LibraryModel?
    @ObservationIgnored private let server: CaptureServer?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginItem: LoginItemControlling
    @ObservationIgnored private var monitor: Task<Void, Never>?

    init(
        library: LibraryModel? = nil,
        server: CaptureServer? = nil,
        actions: MenuBarCaptureActions? = nil,
        defaults: UserDefaults = .standard,
        loginItem: LoginItemControlling? = nil
    ) {
        self.library = library
        self.server = server
        let loginItem = loginItem ?? SystemLoginItem()
        self.actions = actions ?? MenuBarCaptureActions()
        self.defaults = defaults
        self.loginItem = loginItem

        keepCaptureAvailable = MenuBarCaptureSettings.value(forKey: MenuBarCaptureSettings.keepCaptureKey, default: true, in: defaults)
        // The truth is what macOS says, not what we last stored.
        openAtLogin = loginItem.isEnabled
        refresh()
    }

    // MARK: Titles

    var inboxTitle: String {
        inboxCount > 0 ? "Open Inbox (\(inboxCount))" : "Open Inbox"
    }

    var pauseTitle: String {
        status == .paused ? "Resume capture" : "Pause capture"
    }

    // MARK: Refreshing

    /// Re-reads the capture state and the Inbox count. Cheap; safe to call often.
    func refresh() {
        status = MenuBarCaptureStatus(server: server?.state, isPaused: server?.isPaused ?? false)

        if let library {
            let count = try? library.database.scalarInt(
                "SELECT COUNT(*) FROM items WHERE review_state = 'inbox' AND deleted_at IS NULL")
            inboxCount = Int(count ?? 0)
        }

        openAtLogin = loginItem.isEnabled
        if loginItem.needsApproval {
            loginItemMessage = "Approve ResearchBase in System Settings › General › Login Items."
        }
    }

    /// Keeps the menu up to date while the app runs (state every few seconds). Safe to call twice.
    func startMonitoring(every seconds: TimeInterval = 30) {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                // A cancelled sleep throws. End the loop right away: the old `try?` swallowed
                // that error and ran one last refresh after `stopMonitoring()`.
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.5) * 1_000_000_000))
                } catch {
                    return
                }
                // Cancelled just after the sleep finished normally.
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    // MARK: Actions

    /// Pauses or resumes capture. The server keeps running and answers pings while paused.
    func togglePause() {
        guard let server, status.canTogglePause else { return }
        server.isPaused.toggle()
        refresh()
    }

    /// Turns "Open at login" on or off with macOS. If macOS refuses, the switch goes back and says why.
    func setOpenAtLogin(_ enabled: Bool) {
        loginItemMessage = nil
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            loginItemMessage = "Could not change the login item: \(error.localizedDescription)"
        }
        refresh()
        defaults.set(openAtLogin, forKey: MenuBarCaptureSettings.openAtLoginKey)

        if enabled, !openAtLogin, loginItem.needsApproval { loginItem.openSystemSettings() }
    }
}

// MARK: - Menu

struct MenuBarCaptureView: View {

    let model: MenuBarCaptureModel

    var body: some View {

        // Menu-style items are plain: text, buttons and dividers.
        Text(model.status.title)
        if let detail = model.status.detail {
            Text(detail)
        }

        Divider()

        Button("Add by link or DOI…") {
            model.actions.openQuickAdd()
        }
        .keyboardShortcut("n", modifiers: [.option, .command])

        Button(model.inboxTitle) {
            model.actions.openInbox()
        }

        Button("Open ResearchBase") {
            model.actions.openMainWindow()
        }

        Divider()

        Button(model.pauseTitle) {
            model.togglePause()
        }
        .disabled(!model.status.canTogglePause)

        Divider()

        Button("Quit ResearchBase") {
            model.actions.quit()
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

struct MenuBarCaptureLabel: View {

    let model: MenuBarCaptureModel

    var body: some View {
        HStack(spacing: 3) {
            if let logo = model.status.logoImageName {
                Image(logo)
                    .renderingMode(.template)
            } else {
                Image(systemName: model.status.symbol)
            }
            if model.inboxCount > 0 {
                Text("\(model.inboxCount)")
            }
        }
        .accessibilityLabel(model.status.title + (model.inboxCount > 0 ? ", \(model.inboxCount) in Inbox" : ""))
    }
}

/// Add this to the app's scenes. The icon is present only while "keep capture available" is on.
struct MenuBarCaptureScene: Scene {

    let model: MenuBarCaptureModel

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { model.keepCaptureAvailable },
            set: { model.keepCaptureAvailable = $0 }
        )) {
            MenuBarCaptureView(model: model)
        } label: {
            MenuBarCaptureLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Settings rows

struct MenuBarCaptureSettingsSection: View {

    let model: MenuBarCaptureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            row(title: "Menu-bar mode", note: "Keep capture available when the main window is closed") {
                Toggle("", isOn: Binding(
                    get: { model.keepCaptureAvailable },
                    set: { model.keepCaptureAvailable = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            row(title: "Open at login", note: "Start ResearchBase when you log in, so capture is ready") {
                Toggle("", isOn: Binding(
                    get: { model.openAtLogin },
                    set: { model.setOpenAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if let message = model.loginItemMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(RBColor.warning)
            }

            row(title: "Quick add shortcut", note: "Opens the add box from anywhere") {
                Text("⌥ ⌘ N")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(RBColor.secondaryText)
            }
        }
        .onAppear { model.refresh() }
    }

    private func row<Control: View>(title: String, note: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(RBColor.primaryText)
                Text(note).font(.caption).foregroundStyle(RBColor.secondaryText)
            }
            Spacer()
            control()
        }
    }
}
