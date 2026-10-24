import SwiftUI
import SwiftData
import Combine
 
@main
struct ResearchBaseApp: App {

    // Stops a second copy of the app from staying open.
    @NSApplicationDelegateAdaptor(SingleInstanceDelegate.self)
    private var singleInstanceDelegate

    // Phase 13D — one shared appearance object for the whole app.
    // ContentView observes it to rebuild the UI when the theme changes.
    @StateObject private var appearance = AppearanceSettings()

    // Phase 14 — one shared profile (name, photo, welcome state).
    @StateObject private var profile = ProfileStore()

    // Batch 4 — opens the SQLite library once and starts the background
    // services (logger, backups, capture server, inbox watcher, menu bar).
    @StateObject private var libraryHost = LibraryHost()

    /// Finishes an "Erase everything and start fresh" that was asked for in
    /// Settings. Settings only sets a flag and relaunches, because the library
    /// and the SwiftData store cannot be deleted while they are open. This is
    /// the second half: it must run before anything above is created, and the
    /// `@StateObject` objects are created lazily, after this `init`, so
    /// it runs in time. Without this call the erase button did nothing.
    init() {
        // The relaunch can start while the old copy is still closing. Leave the
        // request for the real launch in that case (it expires after 10 minutes).
        let bundleID = Bundle.main.bundleIdentifier
        let myPID = ProcessInfo.processInfo.processIdentifier
        let otherCopyRunning = bundleID.map { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .contains { $0.processIdentifier != myPID }
        } ?? false

        if !otherCopyRunning {
            ResetService.performPendingEraseIfNeeded()
        }
    }

    var body: some Scene {
        // One window only: `Window` (unlike `WindowGroup`) has no
        // File > New Window and cannot be duplicated.
        Window("ResearchBase", id: "main") {
            ContentView()
                .environmentObject(appearance)
                .environmentObject(profile)
                .environmentObject(libraryHost)
                .environment(\.rbA65Library, libraryHost.model)
                .environment(\.rbA70LibraryModel, libraryHost.model)
                .environment(\.rbA74Library, libraryHost.model)
                .environment(\.rbA75Library, libraryHost.model)
                .environment(\.rbA75BackupScheduler, libraryHost.backupScheduler)
        }
        .modelContainer(
            for: [
                // Existing models
                PaperRecord.self,
                PDFNoteRecord.self,
                ResearchNote.self,
 
                // Phase 7 — Literature Review models
                LiteratureReview.self,
                LiteratureTheme.self,
                LiteratureFinding.self,
                LiteratureComparisonEntry.self,
                LiteratureSynthesis.self,
 
                // Phase 8 — Research Gaps / Problems / Ideas
                ResearchGap.self,
                ResearchProblem.self,
                ResearchIdea.self,
 
                // Phase 9 — Experiments & Results
                Experiment.self,
                ExperimentRun.self,
                RunMetric.self,
                BaselineMetric.self,

                // Phase 10 — Research Writing Workspace
                WritingDocument.self,
                WritingSection.self,

                // Phase 11 — Research Projects
                ResearchProject.self,

                // Phase 13B — Tasks (new model; additive, so existing
                // data migrates automatically)
                ResearchTask.self
            ]
        )
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)

        // X-02 — menu-bar item (shown only while "keep capture available" is on).
        MenuBarCaptureScene(model: libraryHost.menuBar)
    }
}


// MARK: - Single Instance

/// If another copy of ResearchBase is already running, bring that copy
/// to the front and quit this one.
final class SingleInstanceDelegate: NSObject, NSApplicationDelegate {

    /// X-02 — with the menu-bar item on, closing the window keeps capture running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarCaptureSettings.keepCaptureAvailable
    }

    func applicationWillFinishLaunching(_ notification: Notification) {

        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let myPID = ProcessInfo.processInfo.processIdentifier

        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }

        if let existing = others.first {
            existing.activate()
            NSApp.terminate(nil)
        }
    }
}


// MARK: - Library host (Batch 4 wiring)

extension Notification.Name {
    static let rbOpenInbox = Notification.Name("rb.openInbox")
    static let rbOpenQuickAdd = Notification.Name("rb.openQuickAdd")
    static let rbAttachmentAdded = Notification.Name("rb.attachmentAdded")
}

/// Opens the SQLite `Library` at launch and owns everything that runs
/// beside it. Lives in this file because the main target is not
/// folder-synchronized (a new file would need project.pbxproj edits).
@MainActor
final class LibraryHost: ObservableObject {

    private(set) var model: LibraryModel?
    private(set) var backupScheduler: BackupScheduler?
    private(set) var captureServer: CaptureServer?
    private(set) var inboxWatcher: InboxFolderWatcher?
    /// Reads the text of PDFs into the search index, in the background.
    private(set) var pdfIndexer: PDFTextIndexer?
    let menuBar: MenuBarCaptureModel

    /// Plain-language reason the library could not be opened, if it could not.
    @Published private(set) var openError: String?


    init() {
        AppLogger.shared.info("Launching ResearchBase", category: "app")

        var opened: LibraryModel?
        do {
            let root = Self.libraryRoot()
            let library = try Library.open(at: root)
            let sink = SafetySQLChangeSink(database: library.database)
            opened = LibraryModel(library: library, changeSink: sink)
        } catch {
            openError = AppErrorText.plain(error)
            AppLogger.shared.error(error, context: "Opening the library", show: true)
        }
        model = opened

        var server: CaptureServer?
        if let model = opened {
            let library = model.library

            // F-22 — search. Papers are indexed as they change (LibraryModel.record).
            // Once, fill the index with everything that is already in the library.
            let indexMarker = "search.autoindex.v1"
            let alreadyDone: String? = try? model.database.scalarText(
                "SELECT value FROM meta WHERE key = ?", [.text(indexMarker)]
            )
            if alreadyDone == nil {
                do {
                    try model.search.rebuildItems()
                    try model.search.rebuildThoughts()
                    try model.database.run(
                        "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                        [.text(indexMarker), .text("1")]
                    )
                } catch {
                    AppLogger.shared.error(error, context: "Building the search index", show: false)
                }
            }

            // F-22 — words inside PDFs. Runs now for anything not indexed yet, and again
            // each time a file is added.
            let indexer = PDFTextIndexer(model: model)
            pdfIndexer = indexer
            indexer.start()
            NotificationCenter.default.addObserver(
                forName: .rbAttachmentAdded, object: nil, queue: .main
            ) { [weak indexer] _ in
                // Let the save that added the file finish first.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    indexer?.start()
                }
            }

            // F-49 / F-50 — scheduled backups.
            let scheduler = BackupScheduler(library: library, onProblem: { text in
                AppLogger.shared.warning(text, category: "backup")
            })
            scheduler.start()
            backupScheduler = scheduler

            // X-01 — capture endpoint. Token lives in the Keychain (F-56).
            let token = Self.captureToken()
            let s = CaptureServer(model: model, token: token)
            do { try s.start() } catch {
                AppLogger.shared.error(error, context: "Starting the capture server", show: false)
            }
            captureServer = s
            server = s

            // F-20 — watch the inbox folder (also scans once for files dropped while closed).
            let watcher = InboxFolderWatcher(model: model)
            watcher.start()
            inboxWatcher = watcher

            // F-48 — integrity check on launch (quick; deep when the last deep one is a week old).
            Task {
                do {
                    let report = try await IntegrityChecker.runForLaunch(on: library)
                    AppLogger.shared.info("Integrity check finished: \(report.issues.count) issue(s)", category: "integrity")
                } catch {
                    AppLogger.shared.error(error, context: "Integrity check", show: false)
                }
            }
        }

        // X-02 — menu-bar model. Actions reach ContentView through notifications.
        let actions = MenuBarCaptureActions(
            openQuickAdd: {
                NSApp.activate()
                NotificationCenter.default.post(name: .rbOpenQuickAdd, object: nil)
            },
            openInbox: {
                NSApp.activate()
                NotificationCenter.default.post(name: .rbOpenInbox, object: nil)
            }
        )
        menuBar = MenuBarCaptureModel(library: opened, server: server, actions: actions)
        menuBar.startMonitoring()
    }

    /// Command palette: "Integrity check". Result goes to the log; problems raise the error banner.
    func runIntegrityCheckNow() {
        guard let library = model?.library else { return }
        Task {
            do {
                let report = try await IntegrityChecker.run(on: library, depth: .deep, recordResult: true)
                AppLogger.shared.info("Integrity check: \(report.summary)", category: "integrity")
                if !report.isClean {
                    AppErrorCenter.shared.show(title: "Integrity check", message: report.summary)
                } else {
                    AppErrorCenter.shared.show(title: "Integrity check", message: "No problems found.")
                }
            } catch {
                AppLogger.shared.error(error, context: "Integrity check", show: true)
            }
        }
    }

    /// Command palette: "Backup now".
    func backupNow() {
        guard let scheduler = backupScheduler else { return }
        Task {
            let outcome = await scheduler.backupNow()
            AppLogger.shared.info("Backup finished: \(String(describing: outcome))", category: "backup")
        }
    }

    /// `~/Documents/ResearchBase Library`
    static func libraryRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return docs.appendingPathComponent(Library.folderName, isDirectory: true)
    }

    /// The browser-capture token is only used between this app and the browser extension on this
    /// Mac (127.0.0.1). It is kept in the app's preferences, not the Keychain: every Xcode build
    /// is signed differently, and macOS asks for the Keychain password again after each build.
    /// API keys the person types in Settings still go to the Keychain.
    private static func captureToken() -> String {
        let defaults = UserDefaults.standard
        let key = "rb.captureToken"
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = CaptureServer.generateToken()
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
