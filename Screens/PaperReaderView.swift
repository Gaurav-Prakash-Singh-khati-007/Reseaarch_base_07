// Owner: Agent 66 · Features: F-26, F-27
//
// PUBLIC API (added; every existing signature is unchanged)
//   PaperReaderView(... , annotationStore: AnnotationStore? = nil, attachmentID: String? = nil)
//   RBA66OutlineEntry, RBA66Logic   (pure helpers, unit-tested)
// F-26 here: the reader lists and deletes highlights kept in the library
//   database (AnnotationStore). It never writes to the PDF file.
// F-27 here: outline sidebar, "back at page N" offer, highlights panel.
// BLOCKED: see the handoff report (PDFKitView highlight flow, Library wiring).

import SwiftUI
import PDFKit
import SwiftData

struct PaperReaderView: View {

    let paper: Paper
    let pdfURL: URL
    let onBack: () -> Void

    /// True while ContentView's reader focus mode is on.
    var isFocus: Bool = false
    /// Turns focus mode on or off (ContentView owns the state).
    var onToggleFocus: () -> Void = {}

    /// F-26: where highlights live (the SQLite library). nil until the app
    /// wiring (#76) passes it in; the reader then shows an empty state.
    var annotationStore: AnnotationStore? = nil
    /// The library attachment id of this PDF (nil = not linked yet).
    var attachmentID: String? = nil

    @Environment(\.modelContext)
    private var modelContext

    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 0
    @State private var zoomScale: CGFloat = 1.0
    @State private var document: PDFDocument?

    /// Page thumbnails are hidden until you ask for them (Option-Command-P).
    @State private var showThumbnails = false

    // F-27: outline, resume offer, stored highlights
    @State private var showOutline = false
    @State private var outlineEntries: [RBA66OutlineEntry] = []
    @State private var resumeOfferPage: Int?
    @State private var showStoredAnnotations = false
    @State private var storedAnnotations: [Annotation] = []

    // =========================================================
    // SWIFTDATA
    // =========================================================

    @State private var persistentPaper: PaperRecord?

    // =========================================================
    // SEARCH
    // =========================================================

    @State private var isSearchVisible = false
    @State private var searchText = ""
    @State private var searchSelections: [PDFSelection] = []
    @State private var selectedSearchIndex: Int = -1

    // =========================================================
    // NOTES
    // =========================================================

    @State private var pdfNotes: [PDFNote] = []

    @State private var showAnnotationPanel = false

    @State private var selectedAnnotationText = ""
    @State private var selectedAnnotationPage = 1
    @State private var annotationText = ""

    @State private var selectedNote: PDFNote?

    @State private var noteSaveRequest: String?
    @State private var noteCancelRequest = false

    // =========================================================
    // DELETE CONFIRMATION
    // =========================================================

    @State private var showDeleteConfirmation = false
    @State private var isDeletingNote = false

    // =========================================================
    // NOTE SAVE MESSAGE
    // =========================================================

    @State private var showNoteSavedMessage = false

    var body: some View {

        ZStack {

            VStack(spacing: 0) {

                topBar

                // Reading progress (page / total pages).
                RBProgressBar(
                    value: totalPages > 0
                        ? Double(currentPage) / Double(totalPages)
                        : 0,
                    height: 4
                )

                if isSearchVisible {
                    searchBar
                }

                Divider()
                    .overlay(RBColor.border)

                HStack(spacing: 0) {

                    if showOutline {

                        outlineSidebar

                        Divider()
                            .overlay(RBColor.border)
                    }

                    if showThumbnails {

                        thumbnailSidebar

                        Divider()
                            .overlay(RBColor.border)
                    }

                    PDFKitView(
                        url: pdfURL,

                        // Open where you stopped last time.
                        startPage: ReaderPositionStore.page(for: pdfURL),

                        currentPage: $currentPage,

                        totalPages: $totalPages,

                        zoomScale: $zoomScale,

                        searchSelections: $searchSelections,

                        selectedSearchIndex: $selectedSearchIndex,

                        notes: $pdfNotes,

                        noteSaveRequest: $noteSaveRequest,

                        noteCancelRequest: $noteCancelRequest,

                        // -------------------------------------------------
                        // New note
                        // -------------------------------------------------

                        onAddNote: { text, page in

                            selectedNote = nil

                            selectedAnnotationText = text
                            selectedAnnotationPage = page
                            annotationText = ""

                            withAnimation(
                                .easeInOut(duration: 0.2)
                            ) {
                                showAnnotationPanel = true
                            }
                        },

                        // -------------------------------------------------
                        // Note successfully saved
                        // -------------------------------------------------

                        onNoteSaved: { note in

                            DispatchQueue.main.async {

                                // -----------------------------------------
                                // Add to visible notes
                                // -----------------------------------------

                                pdfNotes.append(note)

                                // -----------------------------------------
                                // Save permanently to SwiftData
                                // -----------------------------------------

                                if let persistentPaper {

                                    let store =
                                        ResearchDataStore(
                                            modelContext:
                                                modelContext
                                        )

                                    do {

                                        try store.saveNote(
                                            note,
                                            to:
                                                persistentPaper
                                        )

                                        Swift.print(
                                            "ResearchBase: Note saved to SwiftData."
                                        )

                                    } catch {

                                        Swift.print(
                                            "ResearchBase: Failed to save note: \(error)"
                                        )
                                    }
                                }

                                // -----------------------------------------
                                // Close panel
                                // -----------------------------------------

                                showAnnotationPanel = false

                                selectedNote = nil
                                selectedAnnotationText = ""
                                selectedAnnotationPage = 1
                                annotationText = ""

                                // -----------------------------------------
                                // Show confirmation
                                // -----------------------------------------

                                showNoteSavedMessage = true

                                DispatchQueue.main.asyncAfter(
                                    deadline:
                                        .now() + 2
                                ) {

                                    withAnimation {
                                        showNoteSavedMessage =
                                            false
                                    }
                                }
                            }
                        },

                        // -------------------------------------------------
                        // Existing note clicked
                        // -------------------------------------------------

                        onNoteSelected: { note in

                            DispatchQueue.main.async {

                                selectedNote = note

                                selectedAnnotationText =
                                    note.text

                                selectedAnnotationPage =
                                    note.pageNumber

                                annotationText =
                                    note.note

                                withAnimation(
                                    .easeInOut(duration: 0.2)
                                ) {
                                    showAnnotationPanel =
                                        true
                                }
                            }
                        }
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

                    // -------------------------------------------------
                    // Annotation panel
                    // -------------------------------------------------

                    if showStoredAnnotations {

                        Divider()
                            .overlay(RBColor.border)

                        storedAnnotationsPanel
                            .frame(width: 270)
                    }

                    if showAnnotationPanel {

                        Divider()
                            .overlay(RBColor.border)

                        annotationPanel
                            .frame(minWidth: 240, idealWidth: 300, maxWidth: 320)
                            .transition(
                                .move(edge: .trailing)
                            )
                    }
                }

                Divider()
                    .overlay(RBColor.border)

                bottomBar
            }

            // =========================================================
            // SAVE CONFIRMATION
            // =========================================================

            if showNoteSavedMessage {

                VStack {

                    HStack(spacing: 9) {

                        Image(
                            systemName:
                                "checkmark.circle.fill"
                        )
                        .foregroundStyle(
                            RBColor.success
                        )

                        Text("Note saved")
                            .font(RBFont.secondary(.semibold))
                            .foregroundStyle(
                                RBColor.primaryText
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(
                            cornerRadius: RBRadius.field
                        )
                        .fill(
                            RBColor.card
                        )
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: RBRadius.field
                        )
                        .stroke(
                            RBColor.border,
                            lineWidth: 1
                        )
                    )
                    .shadow(
                        color:
                            .black.opacity(0.25),
                        radius: 10,
                        y: 5
                    )

                    Spacer()
                }
                .padding(.top, 68)
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                )
            }
        }
        // D4: no solid fill; ContentView draws the theme gradient.
        .rbApplyThemeColorScheme()
        .overlay(alignment: .bottom) { resumeToast }

        // Option-Command-P -> show / hide page thumbnails.
        .background {
            Button("") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showThumbnails.toggle()
                }
            }
            .keyboardShortcut("p", modifiers: EventModifiers([.option, .command]))
            .opacity(0)
            .allowsHitTesting(false)
        }

        // Option-Command-O -> show / hide the outline.
        .background {
            Button("") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOutline.toggle()
                }
            }
            .keyboardShortcut("o", modifiers: EventModifiers([.option, .command]))
            .opacity(0)
            .allowsHitTesting(false)
        }

        // Remember the page you are on, so the PDF reopens there.
        .onChange(of: currentPage) { _, newPage in
            guard totalPages > 0 else { return }
            ReaderPositionStore.save(page: newPage, for: pdfURL)
        }

        // =========================================================
        // DELETE CONFIRMATION
        // =========================================================

        .alert(
            "Delete Note?",
            isPresented:
                $showDeleteConfirmation
        ) {

            Button(
                "Cancel",
                role: .cancel
            ) {
                isDeletingNote = false
            }

            Button(
                "Delete",
                role: .destructive
            ) {

                deleteSelectedNote()
            }

        } message: {

            Text(
                "This note will be permanently removed from this paper."
            )
        }

        // =========================================================
        // APPEAR
        // =========================================================

        .onAppear {

            loadDocument()
            loadPersistentData()
            loadOutline()
            loadStoredAnnotations()
            offerResume()
        }

        // =========================================================
        // SEARCH
        // =========================================================

        .onChange(
            of: searchText
        ) { _, newValue in

            performSearch(
                newValue
            )
        }
    }

    // =============================================================
    // DOCUMENT
    // =============================================================

    private func loadDocument() {

        document =
            PDFDocument(
                url: pdfURL
            )

        if let document {

            totalPages =
                document.pageCount
        }
    }

    // =============================================================
    // SWIFTDATA
    // =============================================================

    private func loadPersistentData() {

        let store =
            ResearchDataStore(
                modelContext:
                    modelContext
            )

        do {

            let storedPaper =
                try store.getOrCreatePaper(
                    pdfURL:
                        pdfURL,
                    paper:
                        paper
                )

            persistentPaper =
                storedPaper

            // ---------------------------------------------------------
            // PHASE 4
            // ---------------------------------------------------------
            // Record when this paper was opened.
            // ---------------------------------------------------------

            do {

                try store.updateLastOpened(
                    storedPaper
                )

                Swift.print(
                    "ResearchBase: Last opened time updated."
                )

            } catch {

                Swift.print(
                    "ResearchBase: Failed to update last opened time: \(error)"
                )
            }

            // ---------------------------------------------------------
            // Load saved notes
            // ---------------------------------------------------------

            pdfNotes =
                store.loadNotes(
                    for:
                        storedPaper
                )

            Swift.print(
                "ResearchBase: Loaded \(pdfNotes.count) saved note(s)."
            )

        } catch {

            Swift.print(
                "ResearchBase: Failed to load persistent data: \(error)"
            )
        }
    }

    // =============================================================
    // F-26 / F-27 (Agent 66)
    // =============================================================

    private func loadOutline() {
        guard let document else { outlineEntries = []; return }
        outlineEntries = RBA66Logic.flattenOutline(
            root: document.outlineRoot,
            document: document
        )
    }

    private func loadStoredAnnotations() {
        storedAnnotations = RBA66Logic.loadAnnotations(
            store: annotationStore,
            attachmentID: attachmentID
        )
    }

    /// Offer to start over when the PDF reopened on a later page.
    private func offerResume() {
        guard let page = RBA66Logic.resumeOffer(
            saved: ReaderPositionStore.page(for: pdfURL),
            total: totalPages
        ) else { return }

        resumeOfferPage = page

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            withAnimation { resumeOfferPage = nil }
        }
    }

    private func goTo(_ page: Int) {
        guard totalPages > 0 else { return }
        currentPage = min(max(1, page), totalPages)
    }

    private func deleteStoredAnnotation(_ annotation: Annotation) {
        guard let annotationStore else { return }
        do {
            try annotationStore.trash(id: annotation.id)
        } catch {
            Swift.print("ResearchBase: Could not remove highlight: \(error)")
        }
        loadStoredAnnotations()
    }

    private func rbA66ToolButton(
        title: String,
        icon: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(RBFont.secondary(.medium))
            .foregroundStyle(isOn ? RBColor.accent : RBColor.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .fill(isOn ? RBColor.selectedTint : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.field)
        .help(help)
    }

    private var outlineSidebar: some View {

        let current = RBA66Logic.currentEntryID(
            outlineEntries,
            page: currentPage
        )

        return VStack(alignment: .leading, spacing: 0) {

            Text("OUTLINE")
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if outlineEntries.isEmpty {

                Text("This PDF has no outline.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.horizontal, 12)

            } else {

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(outlineEntries) { entry in
                            Button {
                                goTo(entry.page)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.title)
                                        .font(RBFont.secondary())
                                        .foregroundStyle(
                                            entry.id == current
                                                ? RBColor.accent
                                                : RBColor.primaryText
                                        )
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    Spacer(minLength: 4)

                                    Text("\(entry.page)")
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.mutedText)
                                }
                                .padding(.leading, CGFloat(8 + entry.depth * 12))
                                .padding(.trailing, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: RBRadius.field)
                                        .fill(entry.id == current
                                              ? RBColor.selectedTint
                                              : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .rbHover(cornerRadius: RBRadius.field)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 220)
        .background(RBColor.card)
    }

    private var storedAnnotationsPanel: some View {

        VStack(alignment: .leading, spacing: 0) {

            Text("HIGHLIGHTS")
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if annotationStore == nil || attachmentID == nil {

                Text("Highlights are saved in your library once this PDF is linked to it. The PDF file itself is never changed.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.horizontal, 12)

            } else if storedAnnotations.isEmpty {

                Text("No highlights yet.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.horizontal, 12)

            } else {

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(storedAnnotations, id: \.id) { annotation in
                            HStack(alignment: .top, spacing: 8) {

                                Circle()
                                    .fill(RBA66Logic.swatch(annotation.color))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 4)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Page \(annotation.page)")
                                        .font(RBFont.caption(.medium))
                                        .foregroundStyle(RBColor.mutedText)

                                    if !annotation.quote.isEmpty {
                                        Text(annotation.quote)
                                            .font(RBFont.secondary())
                                            .foregroundStyle(RBColor.primaryText)
                                            .lineLimit(4)
                                    }

                                    if !annotation.comment.isEmpty {
                                        Text(annotation.comment)
                                            .font(RBFont.caption())
                                            .foregroundStyle(RBColor.secondaryText)
                                            .lineLimit(6)
                                    }
                                }

                                Spacer(minLength: 0)

                                Button {
                                    deleteStoredAnnotation(annotation)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(RBColor.mutedText)
                                }
                                .buttonStyle(.plain)
                                .help("Remove highlight")
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: RBRadius.field)
                                    .fill(RBColor.card)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { goTo(annotation.page) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer(minLength: 0)
        }
        .background(RBColor.surface)
    }

    @ViewBuilder
    private var resumeToast: some View {

        if let page = resumeOfferPage {

            HStack(spacing: 10) {

                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(RBColor.accent)

                Text("Back at page \(page), where you stopped.")
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.primaryText)

                Button("Start from page 1") {
                    goTo(1)
                    withAnimation { resumeOfferPage = nil }
                }
                .buttonStyle(.plain)
                .font(RBFont.secondary(.semibold))
                .foregroundStyle(RBColor.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .fill(RBColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(RBColor.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            .padding(.bottom, 56)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // =============================================================
    // TOP BAR
    // =============================================================

    private var topBar: some View {

        HStack(spacing: 14) {

            Button {

                onBack()

            } label: {

                HStack(spacing: 7) {

                    Image(
                        systemName:
                            "chevron.left"
                    )

                    Text("Back")
                }
                .font(RBFont.secondary(.medium))
                .foregroundStyle(
                    RBColor.secondaryText
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)

            Divider()
                .frame(height: 20)
                .overlay(RBColor.border)

            VStack(
                alignment: .leading,
                spacing: 2
            ) {

                Text(
                    paper.title
                )
                .font(RBFont.body(.semibold))
                .foregroundStyle(
                    RBColor.primaryText
                )
                .lineLimit(1)

                Text(
                    "\(paper.venue) • \(paper.year)"
                )
                .font(RBFont.label())
                .foregroundStyle(
                    RBColor.mutedText
                )
            }

            Spacer()

            // -------------------------------------------------
            // Note count
            // -------------------------------------------------

            if !pdfNotes.isEmpty {

                RBBadge(
                    text: "\(pdfNotes.count) \(pdfNotes.count == 1 ? "Note" : "Notes")",
                    tone: .accent,
                    icon: "note.text"
                )
            }

            // -------------------------------------------------
            // Page position + thumbnails toggle
            // -------------------------------------------------

            if totalPages > 0 {
                Text("Page \(currentPage) of \(totalPages)")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.mutedText)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showThumbnails.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                    Text("Pages")
                }
                .font(RBFont.secondary(.medium))
                .foregroundStyle(
                    showThumbnails ? RBColor.accent : RBColor.secondaryText
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .fill(showThumbnails ? RBColor.selectedTint : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .help(showThumbnails
                  ? "Hide page thumbnails (⌥⌘P)"
                  : "Show page thumbnails (⌥⌘P)")

            rbA66ToolButton(
                title: "Outline",
                icon: "list.bullet.indent",
                isOn: showOutline,
                help: showOutline ? "Hide outline (⌥⌘O)" : "Show outline (⌥⌘O)"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showOutline.toggle()
                }
            }

            rbA66ToolButton(
                title: storedAnnotations.isEmpty
                    ? "Highlights"
                    : "Highlights (\(storedAnnotations.count))",
                icon: "highlighter",
                isOn: showStoredAnnotations,
                help: "Highlights stored in your library. The PDF file is never changed."
            ) {
                loadStoredAnnotations()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showStoredAnnotations.toggle()
                }
            }

            // -------------------------------------------------
            // Full Page (focus mode)
            // -------------------------------------------------

            Button {
                onToggleFocus()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: isFocus
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )

                    Text(isFocus ? "Exit Full Page" : "Full Page")
                }
                .font(RBFont.secondary(.medium))
                .foregroundStyle(
                    isFocus ? RBColor.accent : RBColor.secondaryText
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .fill(isFocus ? RBColor.selectedTint : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .help(isFocus ? "Exit Full Page (Esc)" : "Full Page (⌥⌘F)")

            Button {

                isSearchVisible.toggle()

                if !isSearchVisible {

                    searchText = ""
                    searchSelections = []
                    selectedSearchIndex = -1
                }

            } label: {

                Image(
                    systemName:
                        isSearchVisible
                        ? "xmark"
                        : "magnifyingglass"
                )
                .frame(
                    width: 30,
                    height: 30
                )
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                isSearchVisible
                ? RBColor.accent
                : RBColor.secondaryText
            )

            RBBadge(text: "PDF", tone: .accent)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    // =============================================================
    // SEARCH BAR
    // =============================================================

    private var searchBar: some View {

        HStack(spacing: 10) {

            Image(
                systemName:
                    "magnifyingglass"
            )
            .foregroundStyle(
                RBColor.mutedText
            )

            TextField(
                "Search in PDF...",
                text:
                    $searchText
            )
            .textFieldStyle(.plain)
            .font(RBFont.body())
            .foregroundStyle(
                RBColor.primaryText
            )

            if !searchText.isEmpty {

                Text(
                    searchSelections.isEmpty
                    ? "No results"
                    : "\(selectedSearchIndex + 1) of \(searchSelections.count)"
                )
                .font(RBFont.caption(.medium))
                .foregroundStyle(
                    searchSelections.isEmpty
                    ? RBColor.error
                    : RBColor.secondaryText
                )

                Divider()
                    .frame(height: 20)
                    .overlay(RBColor.border)

                Button {

                    previousSearchResult()

                } label: {

                    Image(
                        systemName:
                            "chevron.up"
                    )
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(
                    searchSelections.isEmpty
                    ? RBColor.mutedText
                    : RBColor.primaryText
                )
                .disabled(
                    searchSelections.isEmpty
                )

                Button {

                    nextSearchResult()

                } label: {

                    Image(
                        systemName:
                            "chevron.down"
                    )
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(
                    searchSelections.isEmpty
                    ? RBColor.mutedText
                    : RBColor.primaryText
                )
                .disabled(
                    searchSelections.isEmpty
                )
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(
            RBColor.sidebar
        )
    }

    // =============================================================
    // SEARCH
    // =============================================================

    private func performSearch(
        _ query: String
    ) {

        guard
            let document
        else {
            return
        }

        let trimmedQuery =
            query.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard !trimmedQuery.isEmpty else {

            searchSelections = []
            selectedSearchIndex = -1

            return
        }

        let results =
            document.findString(
                trimmedQuery,
                withOptions:
                    .caseInsensitive
            )

        searchSelections =
            results

        selectedSearchIndex =
            results.isEmpty
            ? -1
            : 0
    }

    private func previousSearchResult() {

        guard
            !searchSelections.isEmpty
        else {
            return
        }

        if selectedSearchIndex <= 0 {

            selectedSearchIndex =
                searchSelections.count - 1

        } else {

            selectedSearchIndex -= 1
        }
    }

    private func nextSearchResult() {

        guard
            !searchSelections.isEmpty
        else {
            return
        }

        if selectedSearchIndex >=
            searchSelections.count - 1 {

            selectedSearchIndex =
                0

        } else {

            selectedSearchIndex += 1
        }
    }

    // =============================================================
    // THUMBNAILS
    // =============================================================

    private var thumbnailSidebar: some View {

        VStack(spacing: 0) {

            HStack {

                Text("PAGES")
                    .font(RBFont.label(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(
                        RBColor.mutedText
                    )

                Spacer()

                Text(
                    "\(totalPages)"
                )
                .font(RBFont.label())
                .foregroundStyle(
                    RBColor.mutedText
                )
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            Divider()
                .overlay(RBColor.border)

            ScrollView {

                LazyVStack(spacing: 12) {

                    if let document {

                        ForEach(
                            0..<document.pageCount,
                            id: \.self
                        ) { index in

                            if let page =
                                document.page(
                                    at: index
                                ) {

                                thumbnailItem(
                                    page:
                                        page,
                                    pageNumber:
                                        index + 1
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 150)
        .background(
            RBColor.sidebar
        )
    }

    private func thumbnailItem(
        page: PDFPage,
        pageNumber: Int
    ) -> some View {

        Button {

            currentPage =
                pageNumber

        } label: {

            VStack(spacing: 6) {

                ZStack(
                    alignment:
                        .topTrailing
                ) {

                    PDFThumbnailView(
                        page:
                            page,

                        isSelected:
                            currentPage ==
                            pageNumber
                    )
                    .frame(
                        width: 110,
                        height: 145
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 5
                        )
                    )

                    if pdfNotes.contains(
                        where: {
                            $0.pageNumber ==
                            pageNumber
                        }
                    ) {

                        Image(
                            systemName:
                                "note.text.circle.fill"
                        )
                        .font(RBFont.section())
                        .foregroundStyle(
                            RBColor.accent
                        )
                        .background(
                            Circle()
                                .fill(
                                    RBColor.sidebar
                                )
                        )
                        .padding(4)
                    }
                }

                HStack(spacing: 4) {

                    Text(
                        "\(pageNumber)"
                    )

                    if pdfNotes.contains(
                        where: {
                            $0.pageNumber ==
                            pageNumber
                        }
                    ) {

                        Circle()
                            .fill(
                                RBColor.accent
                            )
                            .frame(
                                width: 5,
                                height: 5
                            )
                    }
                }
                .font(
                    .system(
                        size: 10,
                        weight:
                            currentPage ==
                            pageNumber
                            ? .semibold
                            : .regular
                    )
                )
                .foregroundStyle(
                    currentPage ==
                    pageNumber
                    ? RBColor.accent
                    : RBColor.mutedText
                )
            }
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.field)
    }

    // =============================================================
    // ANNOTATION PANEL
    // =============================================================

    private var annotationPanel: some View {

        VStack(
            alignment: .leading,
            spacing: 0
        ) {

            // -----------------------------------------------------
            // PANEL HEADER
            // -----------------------------------------------------

            HStack {

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text(
                        selectedNote == nil
                        ? "New Annotation"
                        : "Annotation"
                    )
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )

                    Text(
                        "Page \(selectedAnnotationPage)"
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(
                        RBColor.mutedText
                    )
                }

                Spacer()

                Button {

                    closeAnnotationPanel()

                } label: {

                    Image(
                        systemName:
                            "xmark"
                    )
                    .frame(
                        width: 26,
                        height: 26
                    )
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(
                    RBColor.secondaryText
                )
            }
            .padding(16)

            Divider()
                .overlay(RBColor.border)

            // -----------------------------------------------------
            // CONTENT
            // -----------------------------------------------------

            ScrollView {

                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {

                        Text(
                            "SELECTED PASSAGE"
                        )
                        .font(RBFont.label(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(
                            RBColor.mutedText
                        )

                        Text(
                            selectedAnnotationText
                        )
                        .font(RBFont.secondary())
                        .foregroundStyle(
                            RBColor.secondaryText
                        )
                        .lineSpacing(3)
                        .padding(12)
                        .frame(
                            maxWidth:
                                .infinity,
                            alignment:
                                    .leading
                            )
                            .background(
                                RoundedRectangle(
                                    cornerRadius: RBRadius.field
                                )
                                .fill(
                                    RBColor.card
                                )
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: RBRadius.field
                                )
                            .stroke(
                                RBColor.border,
                                lineWidth: 1
                            )
                        )
                    }

                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {

                        Text("YOUR NOTE")
                            .font(RBFont.label(.semibold))
                            .tracking(0.7)
                            .foregroundStyle(
                                RBColor.mutedText
                            )

                        TextEditor(
                            text:
                                $annotationText
                        )
                        .font(RBFont.body())
                        .foregroundStyle(
                            RBColor.primaryText
                        )
                        .scrollContentBackground(
                            .hidden
                        )
                        .padding(8)
                        .frame(
                            minHeight: 150
                        )
                        .background(
                            RoundedRectangle(
                                cornerRadius: RBRadius.field
                            )
                            .fill(
                                RBColor.card
                            )
                        )
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: RBRadius.field
                            )
                            .stroke(
                                RBColor.border,
                                lineWidth: 1
                            )
                        )
                    }
                }
                .padding(16)
            }

            Divider()
                .overlay(RBColor.border)

            // -----------------------------------------------------
            // ACTIONS
            // -----------------------------------------------------

            HStack(spacing: 10) {

                if selectedNote != nil {

                    Button {

                        showDeleteConfirmation =
                            true

                    } label: {

                        Image(
                            systemName:
                                "trash"
                        )
                        .frame(
                            width: 34,
                            height: 34
                        )
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(
                        RBColor.error
                    )
                    .help("Delete Note")
                }

                Button {

                    closeAnnotationPanel()

                } label: {

                    Text("Cancel")
                        .frame(
                            maxWidth:
                                .infinity
                        )
                }
                .buttonStyle(
                    AnnotationSecondaryButtonStyle()
                )

                Button {

                    saveAnnotation()

                } label: {

                    Text(
                        selectedNote == nil
                        ? "Save Note"
                        : "Save Changes"
                    )
                    .frame(
                        maxWidth:
                            .infinity
                    )
                }
                .buttonStyle(
                    AnnotationPrimaryButtonStyle()
                )
                .disabled(
                    annotationText
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )
                        .isEmpty
                )
            }
            .padding(16)
        }
        .background(
            RBColor.sidebar
        )
    }

    // =============================================================
    // SAVE / UPDATE
    // =============================================================

    private func saveAnnotation() {

        let trimmedNote =
            annotationText
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !trimmedNote.isEmpty else {
            return
        }

        // =========================================================
        // UPDATE EXISTING NOTE
        // =========================================================

        if let selectedNote {

            let store =
                ResearchDataStore(
                    modelContext:
                        modelContext
                )

            do {

                try store.updateNote(
                    selectedNote,
                    newText:
                        trimmedNote
                )

                // -------------------------------------------------
                // Update visible note
                // -------------------------------------------------

                if let index =
                    pdfNotes.firstIndex(
                        where: {
                            $0.id ==
                            selectedNote.id
                        }
                    ) {

                    let updatedNote =
                        PDFNote(
                            id:
                                selectedNote.id,
                            text:
                                selectedNote.text,
                            note:
                                trimmedNote,
                            pageNumber:
                                selectedNote.pageNumber,
                            bounds:
                                selectedNote.bounds
                        )

                    pdfNotes[index] =
                        updatedNote

                    self.selectedNote =
                        updatedNote
                }

                Swift.print(
                    "ResearchBase: Note updated successfully."
                )

                closeAnnotationPanel()

                showNoteSavedMessage =
                    true

                DispatchQueue.main.asyncAfter(
                    deadline:
                        .now() + 2
                ) {

                    withAnimation {
                        showNoteSavedMessage =
                            false
                    }
                }

            } catch {

                Swift.print(
                    "ResearchBase: Failed to update note: \(error)"
                )
            }

            return
        }

        // =========================================================
        // CREATE NEW NOTE
        // =========================================================

        noteSaveRequest =
            trimmedNote
    }

    // =============================================================
    // DELETE NOTE
    // =============================================================

    private func deleteSelectedNote() {

        guard let noteToDelete = selectedNote else {
            return
        }

        isDeletingNote = true

        let store =
            ResearchDataStore(
                modelContext:
                    modelContext
            )

        do {

            // -----------------------------------------------------
            // Delete permanently from SwiftData
            // -----------------------------------------------------

            try store.deleteNote(
                noteToDelete
            )

            // -----------------------------------------------------
            // Remove from visible reader
            // -----------------------------------------------------

            pdfNotes.removeAll {
                $0.id ==
                noteToDelete.id
            }

            Swift.print(
                "ResearchBase: Note deleted successfully."
            )

            // -----------------------------------------------------
            // Clean annotation state
            // -----------------------------------------------------

            noteCancelRequest = true

            selectedNote = nil

            selectedAnnotationText = ""
            selectedAnnotationPage = 1
            annotationText = ""

            isDeletingNote = false

            withAnimation(
                .easeInOut(duration: 0.2)
            ) {

                showAnnotationPanel = false
            }

        } catch {

            Swift.print(
                "ResearchBase: Failed to delete note: \(error)"
            )

            isDeletingNote = false
        }
    }

    // =============================================================
    // CLOSE
    // =============================================================

    private func closeAnnotationPanel() {

        noteCancelRequest = true

        withAnimation(
            .easeInOut(duration: 0.2)
        ) {

            showAnnotationPanel = false
        }

        selectedNote = nil

        selectedAnnotationText = ""
        selectedAnnotationPage = 1
        annotationText = ""
    }

    // =============================================================
    // BOTTOM BAR
    // =============================================================

    private var bottomBar: some View {

        HStack(spacing: 14) {

            Button {

                if currentPage > 1 {

                    currentPage -= 1
                }

            } label: {

                Image(
                    systemName:
                        "chevron.left"
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                currentPage > 1
                ? RBColor.primaryText
                : RBColor.mutedText
            )
            .disabled(
                currentPage <= 1
            )

            Text(
                "Page \(currentPage) / \(max(totalPages, 1))"
            )
            .font(RBFont.caption(.medium))
            .foregroundStyle(
                RBColor.secondaryText
            )
            .frame(minWidth: 80)

            Button {

                if currentPage < totalPages {

                    currentPage += 1
                }

            } label: {

                Image(
                    systemName:
                        "chevron.right"
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                currentPage < totalPages
                ? RBColor.primaryText
                : RBColor.mutedText
            )
            .disabled(
                currentPage >= totalPages
            )

            Divider()
                .frame(height: 20)
                .overlay(RBColor.border)

            Button {

                zoomScale =
                    max(
                        0.5,
                        zoomScale - 0.1
                    )

            } label: {

                Image(
                    systemName:
                        "minus"
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                RBColor.primaryText
            )

            Text(
                "\(Int(zoomScale * 100))%"
            )
            .font(RBFont.caption(.medium))
            .foregroundStyle(
                RBColor.secondaryText
            )
            .frame(width: 45)

            Button {

                zoomScale =
                    min(
                        3.0,
                        zoomScale + 0.1
                    )

            } label: {

                Image(
                    systemName:
                        "plus"
                )
                .frame(
                    width: 28,
                    height: 28
                )
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                RBColor.primaryText
            )

            Spacer()

            HStack(spacing: 7) {

                Image(
                    systemName:
                        "doc.text"
                )
                .foregroundStyle(
                    RBColor.mutedText
                )

                Text(
                    "PDF Reader"
                )
                .font(RBFont.caption(.medium))
                .foregroundStyle(
                    RBColor.secondaryText
                )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(
            RBColor.sidebar
        )
    }
}


// =============================================================
// BUTTON STYLES
// =============================================================

struct AnnotationPrimaryButtonStyle:
    ButtonStyle {

    func makeBody(
        configuration: Configuration
    ) -> some View {

        configuration.label
            .font(RBFont.secondary(.semibold))
            .foregroundStyle(
                RBColor.onAccent
            )
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
                .fill(
                    RBColor.accent
                )
            )
            .opacity(
                configuration.isPressed
                ? 0.75
                : 1
            )
    }
}


struct AnnotationSecondaryButtonStyle:
    ButtonStyle {

    func makeBody(
        configuration: Configuration
    ) -> some View {

        configuration.label
            .font(RBFont.secondary(.medium))
            .foregroundStyle(
                RBColor.secondaryText
            )
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
                .fill(
                    RBColor.card
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
                .stroke(
                    RBColor.border,
                    lineWidth: 1
                )
            )
            .opacity(
                configuration.isPressed
                ? 0.75
                : 1
            )
    }
}


// =============================================================
// LAST-READ PAGE
// =============================================================

/// Remembers the last page you were on, per PDF file.
/// Kept in UserDefaults (not SwiftData), so no database change is needed.
enum ReaderPositionStore {

    private static func key(for url: URL) -> String {
        "rb.lastReadPage." + url.standardizedFileURL.path
    }

    /// 1-based page to open on (1 if nothing saved).
    static func page(for url: URL) -> Int {
        let saved = UserDefaults.standard.integer(forKey: key(for: url))
        return max(1, saved)
    }

    static func save(page: Int, for url: URL) {
        UserDefaults.standard.set(max(1, page), forKey: key(for: url))
    }
}


// =============================================================
// F-26 / F-27 HELPERS (Agent 66)
// =============================================================

struct RBA66OutlineEntry: Identifiable, Equatable {
    let id: Int
    let title: String
    /// 1-based page.
    let page: Int
    let depth: Int
}

enum RBA66Logic {

    /// The PDF outline as one flat list in reading order.
    static func flattenOutline(
        root: PDFOutline?,
        document: PDFDocument,
        maxEntries: Int = 2000
    ) -> [RBA66OutlineEntry] {

        guard let root else { return [] }

        var result: [RBA66OutlineEntry] = []

        func walk(_ node: PDFOutline, depth: Int) {
            guard depth <= 8 else { return }
            for index in 0..<node.numberOfChildren {
                guard result.count < maxEntries,
                      let child = node.child(at: index) else { continue }

                if let page = child.destination?.page {
                    let number = document.index(for: page) + 1
                    let title = (child.label ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(
                        RBA66OutlineEntry(
                            id: result.count,
                            title: title.isEmpty ? "Untitled" : title,
                            page: number,
                            depth: depth
                        )
                    )
                }
                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        return result
    }

    /// The outline entry the reader is currently inside.
    static func currentEntryID(
        _ entries: [RBA66OutlineEntry],
        page: Int
    ) -> Int? {
        entries
            .filter { $0.page <= page }
            .max { ($0.page, $0.id) < ($1.page, $1.id) }?
            .id
    }

    /// The page to mention in "Back at page N", or nil when there is
    /// nothing worth offering (first page, or a page that no longer exists).
    static func resumeOffer(saved: Int, total: Int) -> Int? {
        guard total > 1, saved > 1, saved <= total else { return nil }
        return saved
    }

    static func normalizedColorName(_ name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["yellow", "green", "blue", "pink"].contains(value) ? value : "yellow"
    }

    static func swatch(_ name: String) -> Color {
        switch normalizedColorName(name) {
        case "green": return Color(red: 0.47, green: 0.86, blue: 0.55)
        case "blue":  return Color(red: 0.47, green: 0.71, blue: 1.00)
        case "pink":  return Color(red: 0.94, green: 0.51, blue: 0.78)
        default:      return Color(red: 1.00, green: 0.87, blue: 0.09)
        }
    }

    /// Highlights for one PDF, in reading order. Empty when not linked.
    static func loadAnnotations(
        store: AnnotationStore?,
        attachmentID: String?
    ) -> [Annotation] {
        guard let store, let attachmentID else { return [] }
        return (try? store.list(attachmentID: attachmentID)) ?? []
    }
}
