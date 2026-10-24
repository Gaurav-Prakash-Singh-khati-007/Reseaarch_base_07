import SwiftUI
import AppKit
import SwiftData
import Combine

// MARK: - Navigation Router (Phase 12)

/// Carries a single pending "go to this record" request from search
/// results or "Related Research" rows to wherever it needs to be
/// handled. Any view can call `router.open(_:)` to request
/// navigation; ContentView observes `pendingTarget` to decide which
/// sidebar screen to show (and to open a Paper directly, exactly like
/// clicking one in the Library today), and the destination screen
/// itself observes the same value to select the specific item and
/// clear it once done — so the same target is never re-applied on a
/// later, unrelated screen change.
final class NavigationRouter: ObservableObject {

    @Published var pendingTarget: NavigationTarget?

    /// A search query handed to the Search screen (e.g. typed into the
    /// Home search bar). GlobalSearchView consumes and clears it.
    @Published var pendingSearchQuery: String?

    /// Phase 14 — a request to CREATE a new item of this kind. Unlike
    /// `pendingTarget` ("go to an existing item"), ContentView only
    /// switches screens for it; the destination screen consumes it
    /// and clears it after creating the item.
    @Published var pendingCreate: QuickAddKind?

    /// Phase 14 — goes up by one on every `requestCreate` call.
    /// ContentView watches this (not `pendingCreate`) to navigate, so
    /// choosing the same Quick Add item twice in a row still navigates
    /// even while the first request has not been consumed yet.
    @Published private(set) var createRequestCount = 0

    func open(_ target: NavigationTarget) {
        pendingTarget = target
    }

    /// Phase 14 — records what the user wants to create. Creates
    /// nothing itself and does not clear the request.
    func requestCreate(_ kind: QuickAddKind) {
        pendingCreate = kind
        createRequestCount += 1
    }
}

private struct RBWindowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1400
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {

    /// Phase 14 — UserDefaults key holding the user's MANUAL
    /// collapsed/expanded preference. Only written by the user's own
    /// toggle (footer control or ⌘B), never by the narrow-window rule.
    private static let sidebarHiddenKey = "sidebar.hidden"

    @State private var windowWidth: CGFloat = 1400

    /// The SAVED manual preference: true = the whole sidebar is hidden
    /// (⌘B). Written only by the user's own toggle.
    @State private var sidebarHidden: Bool =
        UserDefaults.standard.bool(forKey: "sidebar.hidden")

    /// Reader focus ("Full Page"): blurs the sidebar and top strip
    /// while a PDF is open.
    @State private var readerFocus = false

    @State private var selectedScreen: ResearchScreen = .home
    @State private var selectedPaper: PaperRecord?
    /// Agent 77 — id of the SQLite library paper that is open (D1). Set together with
    /// `selectedPaper` when the paper also exists in SwiftData; alone when it exists only in SQLite.
    @State private var selectedLibraryItemID: String?
    @State private var showingPDFReader = false
    /// True only when the app itself put the window into full screen for reading,
    /// so closing the reader never leaves full screen the person chose on their own.
    @State private var enteredFullScreenForReading = false

    @State private var showingCommandPalette = false
    @State private var showingQuickAdd = false
    @State private var windowStatus: AppWindowStatus = .normal

    @StateObject private var router = NavigationRouter()

    // Phase 13D — the selected theme. Its `refreshToken` changes on
    // every theme change (including one made by Restore), and the
    // sidebar and detail area are rebuilt when it does.
    @EnvironmentObject private var appearance: AppearanceSettings

    // Phase 14 — drives the first-launch welcome sheet.
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var libraryHost: LibraryHost
    // Only tasks that are not completed are loaded: the sidebar badge just needs that count.
    // "Completed" must match ResearchTaskStatus.completed.rawValue.
    @Query(filter: #Predicate<ResearchTask> { $0.statusRawValue != "Completed" })
    private var rbOpenTasks: [ResearchTask]
    @State private var rbInboxCount = 0

    @Environment(\.modelContext) private var modelContext
    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    /// Identity of the detail area. It changes with the theme so
    /// every screen rebuilds with the new palette, EXCEPT Settings:
    /// Settings keeps a fixed identity so a theme change made by a
    /// Restore (or by the theme picker) does not destroy its state,
    /// which would wipe the "Restore finished" message and the
    /// safety-backup path. Settings repaints itself instead (it
    /// observes `appearance` and applies the token to its content).
    private var detailIdentity: String {
        if selectedScreen == .settings && selectedPaper == nil {
            return "settings-stable"
        }
        return appearance.refreshToken.uuidString
    }

    /// True below 860pt: the sidebar is always the 58pt rail.
    private var isNarrow: Bool {
        windowWidth < RBBreakpoint.compact
    }

    /// Whether the sidebar in the layout is the narrow icon rail
    /// (narrow windows only; the sidebar is otherwise full width).
    private var isRail: Bool {
        isNarrow
    }

    /// Layout-only part of the window: the sidebar + detail area, overlays,
    /// sizing, theme, and toolbar tinting.
    /// Separated so the Swift type-checker can handle each half independently.
    private var chromeView: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                // "Hidden" (⌘B) now means the narrow icon rail, never nothing:
                // the icons stay visible so you can still switch screens.
                SidebarView(
                    selectedScreen: $selectedScreen,
                    isCollapsed: isRail || sidebarHidden,
                    inboxCount: rbInboxCount,
                    openTaskCount: rbOpenTasks.count
                )
                .id(appearance.refreshToken)
                // Focus mode: blur, dim, and block clicks.
                .rbFocusDimmed(readerFocus)

                VStack(spacing: 0) {
                    WindowBannersView(
                        status: windowStatus,
                        onRetry: { windowStatus = .normal },
                        onFreeSpace: { selectedScreen = .settings }
                    )

                    detailContent
                        .id(detailIdentity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    WindowStatusBar(
                        status: windowStatus,
                        themeName: appearance.theme.displayName
                    )
                }
            }

            if showingCommandPalette {
                CommandPaletteSheet(
                    onDismiss: { showingCommandPalette = false },
                    onSelectCommand: { cmd in
                        handleCommand(cmd)
                    },
                    model: libraryHost.model,
                    onOpenPaper: { id in openLibraryItem(id) },
                    onSearchAll: { query in openSearch(with: query) }
                )
            }

            if showingQuickAdd {
                QuickAddSheet(
                    onDismiss: { showingQuickAdd = false },
                    onSubmit: { input in
                        selectedScreen = .inbox
                    },
                    model: libraryHost.model
                )
            }
        }
        .rbWindowBackground()
        // Smallest supported window (fits half-screen tiling). Below
        // `compactWindowWidth` the sidebar auto-collapses; every screen's
        // list + detail panes fit in this width even with it open.
        .frame(minWidth: 700, idealWidth: 1100, minHeight: 560, idealHeight: 760)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RBWindowWidthKey.self,
                    value: proxy.size.width
                )
            }
        )
        .onPreferenceChange(RBWindowWidthKey.self) { newWidth in
            windowWidth = newWidth
        }
        // Follows the selected theme.
        .rbApplyThemeColorScheme()
        .toolbarBackground(
            readerFocus
                ? RBColor.sidebar.opacity(RBFocus.dimOpacity)
                : RBColor.sidebar,
            for: .windowToolbar
        )
        .toolbarColorScheme(appearance.theme.colorScheme, for: .windowToolbar)
    }

    /// Event-handling modifiers that react to state changes.
    /// Split from `chromeView` so the Swift type-checker can handle each
    /// computed property in reasonable time.
    private var chromeWithEvents: some View {
        chromeView
        // Clicking a different sidebar item should always return to
        // that screen, even if a paper was open.
        .onChange(of: selectedScreen) {
            selectedPaper = nil
            selectedLibraryItemID = nil
            showingPDFReader = false
            readerFocus = false
        }
        // Focus mode ends when the reader closes or another paper opens.
        .onChange(of: showingPDFReader) {
            if !showingPDFReader { readerFocus = false }
            rbSetReadingFullScreen(showingPDFReader)
        }
        .onChange(of: selectedPaper?.id) {
            readerFocus = false
        }
        // Phase 12 — react to any navigation request raised by search
        // results or "Related Research" rows anywhere in the app.
        .onChange(of: router.pendingTarget) { _, target in
            guard let target else { return }
            handle(target)
        }
        // Phase 14 — a Quick Add request switches to the screen that
        // hosts that kind of item.
        .onChange(of: router.createRequestCount) {
            handleCreateRequest()
        }
        // Sidebar Inbox badge: real count, refreshed on launch and on every screen change.
        .onAppear { rbRefreshInboxCount() }
        .onChange(of: selectedScreen) { rbRefreshInboxCount() }
        // X-02 — menu-bar item asks for the Inbox or the Quick Add box.
        .onReceive(NotificationCenter.default.publisher(for: .rbOpenInbox)) { _ in
            selectedPaper = nil
            showingPDFReader = false
            selectedScreen = .inbox
        }
        .onReceive(NotificationCenter.default.publisher(for: .rbOpenQuickAdd)) { _ in
            showingQuickAdd = true
        }
        // Phase 13I — Restore deletes every record. Let go of anything
        // that could point at one before that happens.
        .onReceive(
            NotificationCenter.default.publisher(for: .workspaceWillRestore)
        ) { _ in
            releaseAllRecords()
            selectedScreen = .settings
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .workspaceDidRestore)
        ) { _ in
            releaseAllRecords()
        }
        .environmentObject(router)
    }

    var body: some View {
        chromeWithEvents
        // Phase 14 — first-launch welcome. The sheet is shown whenever
        // the welcome has not been completed (this also covers
        // `profile.showWelcomeAgain()`). The setter is a no-op, so
        // nothing but "Get started" can close it.
        .sheet(
            isPresented: Binding(
                get: { !profile.hasCompletedWelcome },
                set: { _ in }
            )
        ) {
            WelcomeSheetView()
                .environmentObject(profile)
                .environmentObject(appearance)
                .rbApplyThemeColorScheme()
        }
        // Global ⌘K shortcut -> Command Palette
        .background {
            Button("") { showingCommandPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Global ⌥⌘N shortcut -> Quick Add
        .background {
            Button("") { showingQuickAdd.toggle() }
                .keyboardShortcut("n", modifiers: EventModifiers([.option, .command]))
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Global ⌘B shortcut: hide / show the whole sidebar (saved). Nothing in focus mode.
        .background {
            Button("") { toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Option+⌘F -> reader focus on/off (only works in the PDF reader).
        .background {
            Button("") { toggleFocus() }
                .keyboardShortcut("f", modifiers: EventModifiers([.option, .command]))
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Esc -> closes palette/quickadd, or leaves focus mode.
        .background {
            if readerFocus || showingCommandPalette || showingQuickAdd {
                Button("") { handleEscape() }
                    .keyboardShortcut(.escape, modifiers: EventModifiers())
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    /// ⌘B: hides or shows the whole sidebar and remembers the choice.
    /// Does nothing in reader focus mode.
    private func toggleSidebar() {
        if readerFocus { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            sidebarHidden.toggle()
        }
        UserDefaults.standard.set(sidebarHidden, forKey: Self.sidebarHiddenKey)
    }

    /// Esc: close the top-most modal first, otherwise leave focus mode.
    private func handleEscape() {
        if showingCommandPalette {
            showingCommandPalette = false
        } else if showingQuickAdd {
            showingQuickAdd = false
        } else if readerFocus {
            setFocus(false)
        }
    }

    private func rbRefreshInboxCount() {
        rbInboxCount = (try? libraryHost.model?.items.count(reviewState: .inbox)) ?? 0
    }

    private func handleCommand(_ cmd: String) {
        switch cmd {
        case "library":
            selectedScreen = .library
        case "writing":
            selectedScreen = .writing
        case "search":
            openSearch(with: nil)
        case "quickAdd":
            showingQuickAdd = true
        case "addPaper":
            selectedScreen = .library
        case "buildDraft":
            selectedScreen = .writing
        case "insertCitation":
            selectedScreen = .writing
        case "integrityCheck":
            libraryHost.runIntegrityCheckNow()
        case "backupNow":
            libraryHost.backupNow()
        case "switchTheme":
            if let idx = RBThemeID.allCases.firstIndex(of: appearance.theme) {
                let next = RBThemeID.allCases[(idx + 1) % RBThemeID.allCases.count]
                appearance.select(next)
            }
        case "trash":
            selectedScreen = .trash
        default:
            break
        }
    }

    /// Reading hides the macOS menu bar and the window's title bar by using full screen.
    /// Move the pointer to the top edge to bring them back temporarily.
    private func rbSetReadingFullScreen(_ reading: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if reading, !isFull {
            enteredFullScreenForReading = true
            window.toggleFullScreen(nil)
        } else if !reading, isFull, enteredFullScreenForReading {
            enteredFullScreenForReading = false
            window.toggleFullScreen(nil)
        } else if !reading {
            enteredFullScreenForReading = false
        }
    }

    private func toggleFocus() {
        setFocus(!readerFocus)
    }

    /// Turns reader focus on or off. It can only be turned on while a
    /// PDF is open.
    private func setFocus(_ on: Bool) {
        if on {
            guard selectedPaper != nil, showingPDFReader else { return }
        }
        withAnimation(RBFocus.animation) {
            readerFocus = on
        }
    }

    /// Forgets every open record and pending request. Used around a
    /// restore, when the records they refer to are deleted.
    private func releaseAllRecords() {
        selectedPaper = nil
        selectedLibraryItemID = nil
        showingPDFReader = false
        router.pendingTarget = nil
        router.pendingSearchQuery = nil
        router.pendingCreate = nil
    }

    /// Phase 14 — shows the screen that hosts `router.pendingCreate`.
    /// Leaves `pendingCreate` set so that screen can see the request.
    private func handleCreateRequest() {
        guard let kind = router.pendingCreate else { return }
        selectedPaper = nil
        showingPDFReader = false
        selectedScreen = kind.screen
    }

    /// Switches to the Search screen, optionally pre-filling the query.
    private func openSearch(with query: String?) {
        // ⌘K leaves reader focus first,
        readerFocus = false
        selectedPaper = nil
        showingPDFReader = false
        router.pendingSearchQuery = query
        selectedScreen = .search
    }

    @ViewBuilder
    private var detailContent: some View {
        if let paper = selectedPaper {
            if showingPDFReader {
                pdfReaderView(paperRecord: paper)
            } else {
                PaperDetailView(
                    paperRecord: paper,
                    onBack: {
                        selectedPaper = nil
                        selectedLibraryItemID = nil
                        showingPDFReader = false
                    },
                    onOpenPDF: {
                        showingPDFReader = true
                    },
                    // D1: a migrated paper keeps its id, so the SQLite copy is found by it.
                    // If SQLite has no such item, the screen reads the PaperRecord as before.
                    libraryModel: libraryHost.model,
                    libraryItemID: selectedLibraryItemID ?? paper.id.uuidString,
                    onOpenLibraryItem: { id in openLibraryItem(id) }
                )
            }
        } else {
            screenView
        }
    }

    @ViewBuilder
    private var screenView: some View {
        switch selectedScreen {
        case .home:
            HomeView(
                onSearch: { query in openSearch(with: query) },
                onOpenItem: { id in openLibraryItem(id) }
            )

        case .search:
            GlobalSearchView(model: libraryHost.model)

        case .inbox:
            InboxView(
                model: libraryHost.model,
                captureState: libraryHost.captureServer?.state ?? .stopped,
                watchedFolderPath: libraryHost.inboxWatcher?.folderURL.path,
                onOpenSettings: { selectedScreen = .settings }
            )

        // D3: Library is the collections browser; Papers is the SQLite paper list.
        case .library:
            LibraryView(
                onSelectPaper: { record in
                    selectedLibraryItemID = record.id.uuidString
                    selectedPaper = record
                    showingPDFReader = false
                },
                onSelectItem: { id in openLibraryItem(id) }
            )

        case .papers:
            PapersView(libraryModel: libraryHost.model)

        case .knowledge:
            KnowledgeView()

        case .literatureReview:
            LiteratureReviewView()

        case .researchIdeas:
            ResearchIdeasView()

        case .experiments:
            ExperimentsView()

        case .results:
            ResultsView()

        case .writing:
            WritingView()

        case .references:
            ReferencesView()

        case .submissions:
            SubmissionsView(model: libraryHost.model, onOpenDraft: { _ in
                selectedScreen = .writing
            })

        case .projects:
            ProjectsView()

        case .tasks:
            TasksView()

        case .timeline:
            TimelineView(onOpenItem: { id in openLibraryItem(id) })

        case .trash:
            TrashView(model: libraryHost.model)

        case .settings:
            SettingsView()
        }
    }

    /// The paper's primary PDF in the SQLite library, if it is there and on disk.
    private func libraryPDF(
        for record: PaperRecord
    ) -> (model: LibraryModel, url: URL, attachmentID: String)? {
        guard let model = libraryHost.model else { return nil }
        let itemID = selectedLibraryItemID ?? record.id.uuidString
        guard let file = RBA68Logic.files(model: model, itemID: itemID).first(where: { $0.kind == .pdf }),
              let url = try? model.attachments.fileURL(for: file),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (model, url, file.id)
    }

    @ViewBuilder
    private func pdfReaderView(paperRecord: PaperRecord) -> some View {
        // Papers in the library keep their PDF inside the library folder, so
        // look there first. The path stored on the record is only the old way.
        let fromLibrary = libraryPDF(for: paperRecord)
        let pdfURL = fromLibrary?.url ?? URL(fileURLWithPath: paperRecord.pdfFilePath)

        if FileManager.default.fileExists(atPath: pdfURL.path) {
            // The reader has its own top bar with a Back button, so the
            // extra "Back to Paper" bar that sat here is gone.
            PaperReaderView(
                paper: makePaper(from: paperRecord),
                pdfURL: pdfURL,
                onBack: {
                    showingPDFReader = false
                },
                isFocus: readerFocus,
                onToggleFocus: toggleFocus,
                annotationStore: fromLibrary.map { AnnotationStore(model: $0.model) },
                attachmentID: fromLibrary?.attachmentID
            )
        } else {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(RBColor.warning)

                Text("PDF file could not be found.")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text(paperRecord.pdfFilePath)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                Button {
                    showingPDFReader = false
                } label: {
                    Label(
                        "Back to Paper",
                        systemImage: "chevron.left"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            // D4: no solid fill; the window gradient shows through.
        }
    }

    private func makePaper(from record: PaperRecord) -> Paper {
        Paper(
            id: record.id,
            title: record.title,
            authors: record.authors,
            venue: record.venue,
            year: record.year,
            tags: record.tags,
            status: record.readingStatus,
            rating: record.rating,
            abstractText: record.abstractText,
            doi: record.doi,
            urlString: record.urlString,
            pdfFilePath: record.pdfFilePath,
            addedAt: record.addedAt,
            lastOpenedAt: record.lastOpenedAt
        )
    }

    // MARK: - Opening a paper (Agent 77, D1)

    /// Opens one paper by its library id. A paper that also exists in SwiftData (every migrated
    /// paper keeps its id) opens in the full detail screen; one that exists only in SQLite
    /// opens in the library quick view. Clicks from Home, Timeline, Library, Papers, the
    /// command palette and Related Research all end up here.
    private func openLibraryItem(_ id: String) {
        showingPDFReader = false
        readerFocus = false

        var record: PaperRecord?
        if let uuid = UUID(uuidString: id) {
            do {
                record = try store.fetchPapers().first { $0.id == uuid }
            } catch {
                Swift.print("ResearchBase: Failed to resolve paper navigation target: \(error)")
            }
        }

        let inLibrary = (try? libraryHost.model?.items.fetch(id: id)) ?? nil
        if record == nil && inLibrary == nil { return }

        // A paper that exists only in the SQLite library (for example one
        // imported straight from a PDF) has no PaperRecord, so it used to open
        // the stripped-down quick view: no reading workflow, findings, gaps,
        // notes, Edit Reference or Copy Citation. Give it a PaperRecord with
        // the same id so every paper opens the same full PaperDetailView.
        // PaperDetailView reads title, authors, PDF etc. from SQLite whenever
        // the item exists, so these fields are only placeholders.
        if record == nil, let item = inLibrary, let uuid = UUID(uuidString: id) {
            let stub = PaperRecord(
                id: uuid,
                pdfFilePath: "",
                title: item.title,
                authors: "",
                venue: item.venue,
                year: item.year ?? 0
            )
            modelContext.insert(stub)
            do {
                try modelContext.save()
                record = stub
            } catch {
                Swift.print("ResearchBase: Could not create detail record for library item: \(error)")
                modelContext.delete(stub)
            }
        }

        // Every paper opens the one full detail page. If its record could not
        // be made there is nothing to open, so stay where we are.
        guard let record else { return }

        selectedPaper = record
        selectedLibraryItemID = id
    }

    // MARK: - Navigation (Phase 12)

    /// Resolves a pending navigation request. `.paper` opens directly
    /// in this view's own detail pane, exactly like clicking a paper
    /// in the Library, and clears the request immediately since
    /// nothing else needs to consume it. Every other case switches to
    /// that target's sidebar screen and leaves `router.pendingTarget`
    /// set — the destination screen reads it to select the specific
    /// item and clears it when done.
    private func handle(_ target: NavigationTarget) {

        switch target {
        case .paper(let id):
            router.pendingTarget = nil
            openLibraryItem(id.uuidString)

        default:
            selectedPaper = nil
            showingPDFReader = false
            selectedScreen = target.screen
        }
    }
}

enum ResearchScreen {
    case home
    case search
    case inbox
    case library
    case papers
    case knowledge
    case literatureReview
    case researchIdeas
    case experiments
    case results
    case writing
    case references
    case submissions
    case projects
    case tasks
    case timeline
    case trash
    case settings
}
