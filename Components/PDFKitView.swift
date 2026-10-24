// Owner: Agent 67 · Features: F-26
//
// PUBLIC API (added; every existing signature is unchanged)
//   PDFKitView(..., storedHighlights: [PDFStoredHighlight] = [],
//                   onHighlight: ((PDFHighlightRequest) -> Void)? = nil,
//                   onSendToNote: ((String, Int) -> Void)? = nil)
//   PDFStoredHighlight, PDFHighlightRequest, PDFHighlightPalette,
//   PDFHighlightDrawing, PDFHighlightExport
// F-26: highlights are never written into the PDF file. The view reports a
//   request, the caller stores it (AnnotationStore) and passes it back in
//   storedHighlights, which are drawn in memory only. A marked-up copy is
//   made only through PDFHighlightExport, to a different file.

import SwiftUI
import PDFKit
import AppKit

// =============================================================
// PDF KIT VIEW
// =============================================================

struct PDFKitView: NSViewRepresentable {

    let url: URL

    /// 1-based page to open on (last-read page).
    var startPage: Int = 1

    @Binding var currentPage: Int
    @Binding var totalPages: Int
    @Binding var zoomScale: CGFloat

    @Binding var searchSelections: [PDFSelection]
    @Binding var selectedSearchIndex: Int

    @Binding var notes: [PDFNote]

    @Binding var noteSaveRequest: String?
    @Binding var noteCancelRequest: Bool

    let onAddNote: (String, Int) -> Void

    // Called when PDFKit successfully creates a note.
    let onNoteSaved: (PDFNote) -> Void

    // Called when user clicks an existing marker.
    let onNoteSelected: (PDFNote) -> Void

    // ---------------------------------------------------------
    // F-26: highlights kept in the library database
    // ---------------------------------------------------------

    /// Highlights to draw (in memory only), usually from AnnotationStore.
    var storedHighlights: [PDFStoredHighlight] = []

    /// The user chose Highlight. The caller should store it and pass it
    /// back in storedHighlights. When nil, the highlight is only drawn
    /// temporarily and is not saved anywhere.
    var onHighlight: ((PDFHighlightRequest) -> Void)? = nil

    /// "Send to Note" for the selected text (text, 1-based page).
    var onSendToNote: ((String, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // =========================================================
    // MAKE VIEW
    // =========================================================

    func makeNSView(
        context: Context
    ) -> ResearchPDFView {

        let pdfView = ResearchPDFView()

        // -----------------------------------------------------
        // Security scoped access
        // -----------------------------------------------------

        context.coordinator.isAccessingSecurityScopedResource =
            url.startAccessingSecurityScopedResource()

        // -----------------------------------------------------
        // Load PDF
        // -----------------------------------------------------

        pdfView.document =
            PDFDocument(url: url)

        pdfView.autoScales = true

        pdfView.displayMode =
            .singlePageContinuous

        pdfView.displayDirection =
            .vertical

        pdfView.backgroundColor =
            .lightGray

        pdfView.pdfURL =
            url

        // -----------------------------------------------------
        // Callbacks
        // -----------------------------------------------------

        pdfView.onAddNote =
            onAddNote

        pdfView.onNoteSaved =
            onNoteSaved

        // -----------------------------------------------------
        // Notes
        // -----------------------------------------------------

        pdfView.notes =
            notes

        pdfView.onHighlight =
            onHighlight

        pdfView.onSendToNote =
            onSendToNote

        pdfView.applyStoredHighlights(
            storedHighlights
        )

        // -----------------------------------------------------
        // Search overlay
        // -----------------------------------------------------

        let searchOverlay =
            SearchHighlightOverlay()

        searchOverlay.translatesAutoresizingMaskIntoConstraints =
            false

        pdfView.addSubview(
            searchOverlay
        )

        NSLayoutConstraint.activate([

            searchOverlay.leadingAnchor.constraint(
                equalTo:
                    pdfView.leadingAnchor
            ),

            searchOverlay.trailingAnchor.constraint(
                equalTo:
                    pdfView.trailingAnchor
            ),

            searchOverlay.topAnchor.constraint(
                equalTo:
                    pdfView.topAnchor
            ),

            searchOverlay.bottomAnchor.constraint(
                equalTo:
                    pdfView.bottomAnchor
            )
        ])

        // -----------------------------------------------------
        // Note marker overlay
        // -----------------------------------------------------

        let noteOverlay =
            NoteMarkerOverlay()

        noteOverlay.translatesAutoresizingMaskIntoConstraints =
            false

        pdfView.addSubview(
            noteOverlay
        )

        NSLayoutConstraint.activate([

            noteOverlay.leadingAnchor.constraint(
                equalTo:
                    pdfView.leadingAnchor
            ),

            noteOverlay.trailingAnchor.constraint(
                equalTo:
                    pdfView.trailingAnchor
            ),

            noteOverlay.topAnchor.constraint(
                equalTo:
                    pdfView.topAnchor
            ),

            noteOverlay.bottomAnchor.constraint(
                equalTo:
                    pdfView.bottomAnchor
            )
        ])

        noteOverlay.pdfView =
            pdfView

        noteOverlay.notes =
            notes

        noteOverlay.onOpenNote = { note in

            DispatchQueue.main.async {

                onNoteSelected(note)
            }
        }

        // -----------------------------------------------------
        // Store references
        // -----------------------------------------------------

        context.coordinator.pdfView =
            pdfView

        context.coordinator.searchOverlay =
            searchOverlay

        context.coordinator.noteOverlay =
            noteOverlay

        // -----------------------------------------------------
        // Initial document information
        // -----------------------------------------------------

        if let document =
            pdfView.document {

            totalPages =
                document.pageCount

            let target =
                max(1, min(startPage, document.pageCount))

            currentPage =
                target

            context.coordinator.lastPage =
                target

            // Jump to the last-read page once the view has a size.
            if target > 1,
               let page = document.page(at: target - 1) {

                let coordinator = context.coordinator

                coordinator.isRestoring = true

                Self.restoreWhenReady(pdfView, to: page) {
                    coordinator.isRestoring = false
                }
            }
        }

        // -----------------------------------------------------
        // Page changed
        // -----------------------------------------------------

        NotificationCenter.default.addObserver(
            context.coordinator,

            selector:
                #selector(
                    Coordinator.pageChanged
                ),

            name:
                Notification.Name.PDFViewPageChanged,

            object:
                pdfView
        )

        // -----------------------------------------------------
        // PDF view changed
        // -----------------------------------------------------

        NotificationCenter.default.addObserver(
            context.coordinator,

            selector:
                #selector(
                    Coordinator.pdfViewChanged
                ),

            name:
                NSView.boundsDidChangeNotification,

            object:
                nil
        )

        return pdfView
    }

    // =========================================================
    // UPDATE
    // =========================================================

    func updateNSView(
        _ pdfView: ResearchPDFView,
        context: Context
    ) {

        // -----------------------------------------------------
        // Keep callbacks current
        // -----------------------------------------------------

        pdfView.onAddNote =
            onAddNote

        pdfView.onNoteSaved =
            onNoteSaved

        pdfView.onHighlight =
            onHighlight

        pdfView.onSendToNote =
            onSendToNote

        // -----------------------------------------------------
        // Document
        // -----------------------------------------------------

        if pdfView.document?.documentURL != url {

            pdfView.document =
                PDFDocument(url: url)

            pdfView.pdfURL =
                url

            if let document =
                pdfView.document {

                totalPages =
                    document.pageCount

                currentPage =
                    1

                context.coordinator.lastPage =
                    1
            }
        }

        // -----------------------------------------------------
        // Stored highlights (F-26)
        // -----------------------------------------------------

        pdfView.applyStoredHighlights(
            storedHighlights
        )

        // -----------------------------------------------------
        // Synchronize notes from SwiftUI        // -----------------------------------------------------
        // Synchronize notes from SwiftUI
        // -----------------------------------------------------

        if pdfView.notes.map(\.id) !=
            notes.map(\.id) {

            pdfView.notes =
                notes
        }

        // -----------------------------------------------------
        // Save note request
        // -----------------------------------------------------

        if let noteText =
            noteSaveRequest {

            pdfView.savePendingNote(
                noteText
            )

            DispatchQueue.main.async {

                self.noteSaveRequest =
                    nil
            }
        }

        // -----------------------------------------------------
        // Cancel note request
        // -----------------------------------------------------

        if noteCancelRequest {

            pdfView.cancelPendingNote()

            DispatchQueue.main.async {

                self.noteCancelRequest =
                    false
            }
        }

        // -----------------------------------------------------
        // Page navigation
        // -----------------------------------------------------

        if currentPage !=
            context.coordinator.lastPage {

            context.coordinator.goToPage(
                currentPage
            )
        }

        // -----------------------------------------------------
        // Zoom
        // -----------------------------------------------------

        if abs(
            zoomScale -
            context.coordinator.lastZoom
        ) > 0.01 {

            context.coordinator.setZoom(
                zoomScale
            )
        }

        // -----------------------------------------------------
        // Search overlay
        // -----------------------------------------------------

        if let overlay =
            context.coordinator.searchOverlay {

            overlay.pdfView =
                pdfView

            overlay.selections =
                searchSelections

            overlay.selectedIndex =
                selectedSearchIndex

            overlay.needsDisplay =
                true
        }

        // -----------------------------------------------------
        // Note overlay
        // -----------------------------------------------------

        if let noteOverlay =
            context.coordinator.noteOverlay {

            noteOverlay.pdfView =
                pdfView

            noteOverlay.notes =
                pdfView.notes

            noteOverlay.needsDisplay =
                true
        }

        // -----------------------------------------------------
        // Search navigation
        // -----------------------------------------------------

        if !searchSelections.isEmpty &&
            selectedSearchIndex >= 0 &&
            selectedSearchIndex <
                searchSelections.count {

            let selection =
                searchSelections[
                    selectedSearchIndex
                ]

            if context.coordinator.lastSearchIndex
                != selectedSearchIndex {

                pdfView.go(
                    to: selection
                )

                context.coordinator.lastSearchIndex =
                    selectedSearchIndex

                DispatchQueue.main.async {

                    context.coordinator
                        .searchOverlay?
                        .needsDisplay = true
                }
            }

        } else {

            context.coordinator.lastSearchIndex =
                -1
        }
    }

    /// PDFView.go(to:) does nothing until the view has a size, so wait
    /// (up to about a second) before jumping.
    private static func restoreWhenReady(
        _ view: PDFView,
        to target: PDFPage,
        attempt: Int = 0,
        then completion: @escaping () -> Void
    ) {
        if view.bounds.width > 1 && view.bounds.height > 1 {
            view.go(to: target)
            completion()
            return
        }

        guard attempt < 40 else {
            view.go(to: target)
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            restoreWhenReady(view, to: target, attempt: attempt + 1, then: completion)
        }
    }

    // =========================================================
    // DISMANTLE
    // =========================================================

    static func dismantleNSView(
        _ pdfView: ResearchPDFView,
        coordinator: Coordinator
    ) {

        NotificationCenter.default.removeObserver(
            coordinator
        )

        if coordinator.isAccessingSecurityScopedResource {

            coordinator.parent.url
                .stopAccessingSecurityScopedResource()
        }
    }

    // =========================================================
    // COORDINATOR
    // =========================================================

    final class Coordinator: NSObject {

        var parent: PDFKitView

        weak var pdfView:
            ResearchPDFView?

        weak var searchOverlay:
            SearchHighlightOverlay?

        weak var noteOverlay:
            NoteMarkerOverlay?

        var lastPage = 1

        var lastZoom: CGFloat = 1.0

        var lastSearchIndex = -1

        /// True while jumping to the last-read page (ignore page-1 events).
        var isRestoring = false

        var isAccessingSecurityScopedResource =
            false

        init(
            _ parent: PDFKitView
        ) {

            self.parent =
                parent
        }

        // -----------------------------------------------------
        // Go to page
        // -----------------------------------------------------

        func goToPage(
            _ pageNumber: Int
        ) {

            guard
                let pdfView =
                    pdfView,

                let document =
                    pdfView.document
            else {
                return
            }

            guard document.pageCount > 0 else {
                return
            }

            let safePage =
                max(
                    1,
                    min(
                        pageNumber,
                        document.pageCount
                    )
                )

            guard let page =
                document.page(
                    at:
                        safePage - 1
                )
            else {
                return
            }

            pdfView.go(
                to:
                    page
            )

            lastPage =
                safePage
        }

        // -----------------------------------------------------
        // Zoom
        // -----------------------------------------------------

        func setZoom(
            _ zoom: CGFloat
        ) {

            guard
                let pdfView =
                    pdfView
            else {
                return
            }

            let safeZoom =
                max(
                    0.5,
                    min(
                        zoom,
                        3.0
                    )
                )

            pdfView.autoScales =
                false

            pdfView.scaleFactor =
                safeZoom

            lastZoom =
                safeZoom

            searchOverlay?
                .needsDisplay = true

            noteOverlay?
                .needsDisplay = true
        }

        // -----------------------------------------------------
        // Page changed
        // -----------------------------------------------------

        @objc
        func pageChanged() {

            guard
                !isRestoring,

                let pdfView =
                    pdfView,

                let page =
                    pdfView.currentPage,

                let document =
                    pdfView.document
            else {
                return
            }

            let pageIndex =
                document.index(
                    for:
                        page
                )

            let newPage =
                pageIndex + 1

            lastPage =
                newPage

            DispatchQueue.main.async {

                self.parent.currentPage =
                    newPage

                self.parent.totalPages =
                    document.pageCount

                self.searchOverlay?
                    .needsDisplay = true

                self.noteOverlay?
                    .needsDisplay = true
            }
        }

        // -----------------------------------------------------
        // PDF view changed
        // -----------------------------------------------------

        @objc
        func pdfViewChanged(
            _ notification: Notification
        ) {

            DispatchQueue.main.async {

                self.searchOverlay?
                    .needsDisplay = true

                self.noteOverlay?
                    .needsDisplay = true
            }
        }
    }
}


// =============================================================
// PDF NOTE MODEL
// =============================================================

struct PDFNote: Identifiable, Codable {

    let id: UUID

    let text: String

    let note: String

    let pageNumber: Int

    let bounds: CGRect

    init(
        id: UUID = UUID(),
        text: String,
        note: String,
        pageNumber: Int,
        bounds: CGRect
    ) {

        self.id =
            id

        self.text =
            text

        self.note =
            note

        self.pageNumber =
            pageNumber

        self.bounds =
            bounds
    }
}


// =============================================================
// PDF VIEW
// =============================================================

extension Notification.Name {
    /// Posted by the reader's Add Note shortcut (Shift-Command-N).
    static let rbReaderAddNote = Notification.Name("rbReaderAddNote")
}

final class ResearchPDFView:
    PDFView {

    private var addNoteObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let addNoteObserver {
            NotificationCenter.default.removeObserver(addNoteObserver)
            self.addNoteObserver = nil
        }
        guard window != nil else { return }
        addNoteObserver = NotificationCenter.default.addObserver(
            forName: .rbReaderAddNote, object: nil, queue: .main
        ) { [weak self] _ in
            self?.addNoteToCurrentSelection()
        }
    }

    var pdfURL: URL?

    var onAddNote:
        ((String, Int) -> Void)?

    var onNoteSaved:
        ((PDFNote) -> Void)?

    // F-26 (Agent 67)
    var onHighlight:
        ((PDFHighlightRequest) -> Void)?

    var onSendToNote:
        ((String, Int) -> Void)?

    var appliedHighlights:
        [PDFStoredHighlight] = []

    weak var appliedDocument:
        PDFDocument?

    var notes:
        [PDFNote] = []

    private var pendingNoteSelection:
        PDFSelection?

    // =========================================================
    // CONTEXT MENU
    // =========================================================

    override func menu(
        for event: NSEvent
    ) -> NSMenu? {

        guard
            let selection =
                currentSelection,

            let selectedText =
                selection.string,

            !selectedText
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .isEmpty
        else {

            return super.menu(
                for:
                    event
            )
        }

        let menu =
            NSMenu()

        // -----------------------------------------------------
        // Highlight
        // -----------------------------------------------------

        let highlightItem =
            NSMenuItem(
                title:
                    "Highlight",

                action:
                    #selector(
                        highlightCurrentSelection
                    ),

                keyEquivalent:
                    ""
            )

        highlightItem.target =
            self

        menu.addItem(
            highlightItem
        )

        // F-26: colour choices and Send to Note (Agent 67)
        let colourMenu = NSMenu()

        for name in PDFHighlightPalette.names {

            let colourItem =
                NSMenuItem(
                    title: name.capitalized,
                    action: #selector(highlightWithColour(_:)),
                    keyEquivalent: ""
                )

            colourItem.target = self
            colourItem.representedObject = name
            colourMenu.addItem(colourItem)
        }

        let colourParent =
            NSMenuItem(
                title: "Highlight Colour",
                action: nil,
                keyEquivalent: ""
            )

        colourParent.submenu = colourMenu
        menu.addItem(colourParent)

        if onSendToNote != nil {

            let sendItem =
                NSMenuItem(
                    title: "Send to Note",
                    action: #selector(sendSelectionToNote),
                    keyEquivalent: ""
                )

            sendItem.target = self
            menu.addItem(sendItem)
        }

        // -----------------------------------------------------
        // Add Note
        // -----------------------------------------------------

        let noteItem =
            NSMenuItem(
                title:
                    "Add Note",

                action:
                    #selector(
                        addNoteToCurrentSelection
                    ),

                keyEquivalent:
                    ""
            )

        noteItem.target =
            self

        menu.addItem(
            noteItem
        )

        menu.addItem(
            NSMenuItem.separator()
        )

        // -----------------------------------------------------
        // Standard PDFKit menu
        // -----------------------------------------------------

        if let standardMenu =
            super.menu(
                for:
                    event
            ) {

            for item in
                standardMenu.items {

                menu.addItem(
                    item.copy()
                        as! NSMenuItem
                )
            }
        }

        return menu
    }

    // =========================================================
    // HIGHLIGHT
    // =========================================================

    @objc
    private func highlightCurrentSelection() {

        addHighlight(colour: "yellow")
    }

    @objc
    private func highlightWithColour(
        _ sender: NSMenuItem
    ) {

        addHighlight(
            colour: (sender.representedObject as? String) ?? "yellow"
        )
    }

    @objc
    private func sendSelectionToNote() {

        guard
            let selection = currentSelection,
            let text = selection.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            let page = selection.pages.first,
            let document = document
        else {
            return
        }

        let number = document.index(for: page)

        guard number != NSNotFound else { return }

        onSendToNote?(text, number + 1)
    }

    /// F-26: the PDF file is never written here.
    private func addHighlight(
        colour: String
    ) {

        guard let selection = currentSelection else { return }

        let requests =
            highlightRequests(
                for: selection,
                colour: colour
            )

        guard !requests.isEmpty else { return }

        if let onHighlight {

            // The caller stores it and passes it back to us.
            requests.forEach(onHighlight)

        } else if let document {

            // Not wired to the database yet: show it for this session only.
            for request in requests {

                PDFHighlightDrawing.add(
                    PDFStoredHighlight(
                        id: "local-" + UUID().uuidString,
                        page: request.page,
                        color: request.color,
                        rects: request.rects
                    ),
                    to: document
                )
            }
        }

        needsDisplay = true

        currentSelection = nil
    }

    // =========================================================
    // ADD NOTE
    // =========================================================

    @objc
    private func addNoteToCurrentSelection() {

        guard
            let selection =
                currentSelection,

            let selectedText =
                selection.string,

            let document =
                document
        else {
            return
        }

        let trimmedText =
            selectedText
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !trimmedText.isEmpty else {
            return
        }

        guard
            let page =
                selection.pages.first
        else {
            return
        }

        let pageNumber =
            document.index(
                for:
                    page
            ) + 1

        // -----------------------------------------------------
        // IMPORTANT:
        // Keep this exact PDF selection alive until Save.
        // -----------------------------------------------------

        pendingNoteSelection =
            selection

        onAddNote?(
            trimmedText,
            pageNumber
        )
    }

    // =========================================================
    // SAVE NOTE
    // =========================================================

    func savePendingNote(
        _ noteText: String
    ) {

        guard
            let selection =
                pendingNoteSelection,

            let document =
                document,

            let page =
                selection.pages.first
        else {

            Swift.print(
                "❌ No pending PDF selection"
            )

            return
        }

        let trimmedNote =
            noteText
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )

        guard !trimmedNote.isEmpty else {
            return
        }

        let selectedText =
            selection.string?
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                ) ?? ""

        guard !selectedText.isEmpty else {

            Swift.print(
                "❌ Selected text is empty"
            )

            return
        }

        let bounds =
            selection.bounds(
                for:
                    page
            )

        guard !bounds.isEmpty else {

            Swift.print(
                "❌ Selection bounds are empty"
            )

            return
        }

        let pageNumber =
            document.index(
                for:
                    page
            ) + 1

        let newNote =
            PDFNote(
                text:
                    selectedText,

                note:
                    trimmedNote,

                pageNumber:
                    pageNumber,

                bounds:
                    bounds
            )

        // -----------------------------------------------------
        // Store inside PDF view.
        // -----------------------------------------------------

        notes.append(
            newNote
        )

        // -----------------------------------------------------
        // CRITICAL FIX:
        //
        // Send the new note back to SwiftUI.
        // This updates PaperReaderView.pdfNotes.
        // -----------------------------------------------------

        onNoteSaved?(
            newNote
        )

        // -----------------------------------------------------
        // Clear pending selection.
        // -----------------------------------------------------

        pendingNoteSelection =
            nil

        // -----------------------------------------------------
        // Force marker redraw.
        // -----------------------------------------------------

        needsDisplay =
            true

        Swift.print(
            "✅ Note saved successfully"
        )

        Swift.print(
            "   Page: \(pageNumber)"
        )

        Swift.print(
            "   Text: \(selectedText)"
        )
    }

    // =========================================================
    // CANCEL NOTE
    // =========================================================

    func cancelPendingNote() {

        pendingNoteSelection =
            nil
    }
}


// =============================================================
// SEARCH HIGHLIGHT OVERLAY
// =============================================================

final class SearchHighlightOverlay:
    NSView {

    weak var pdfView:
        PDFView?

    var selections:
        [PDFSelection] = []

    var selectedIndex:
        Int = -1

    override var isOpaque:
        Bool {
        false
    }

    override func hitTest(
        _ point: NSPoint
    ) -> NSView? {

        nil
    }

    override func draw(
        _ dirtyRect: NSRect
    ) {

        guard
            let pdfView =
                pdfView,

            !selections.isEmpty
        else {
            return
        }

        for (
            index,
            selection
        ) in selections.enumerated() {

            let isSelected =
                index ==
                selectedIndex

            for page in
                selection.pages {

                let pageBounds =
                    selection.bounds(
                        for:
                            page
                    )

                guard !pageBounds.isEmpty else {
                    continue
                }

                let viewRect =
                    pdfView.convert(
                        pageBounds,
                        from:
                            page
                    )

                guard !viewRect.isEmpty else {
                    continue
                }

                let rect =
                    viewRect.insetBy(
                        dx:
                            -2,
                        dy:
                            -1
                    )

                if isSelected {

                    NSColor(
                        red:
                            1.0,

                        green:
                            0.45,

                        blue:
                            0.05,

                        alpha:
                            0.45
                    ).setFill()

                } else {

                    NSColor(
                        red:
                            1.0,

                        green:
                            0.85,

                        blue:
                            0.10,

                        alpha:
                            0.40
                    ).setFill()
                }

                let path =
                    NSBezierPath(
                        roundedRect:
                            rect,

                        xRadius:
                            2,

                        yRadius:
                            2
                    )

                path.fill()

                if isSelected {

                    NSColor(
                        red:
                            1.0,

                        green:
                            0.35,

                        blue:
                            0.02,

                        alpha:
                            0.85
                    ).setStroke()

                } else {

                    NSColor(
                        red:
                            0.95,

                        green:
                            0.70,

                        blue:
                            0.05,

                        alpha:
                            0.65
                    ).setStroke()
                }

                path.lineWidth =
                    1

                path.stroke()
            }
        }
    }
}


// =============================================================
// NOTE MARKER OVERLAY
// =============================================================

final class NoteMarkerOverlay:
    NSView {

    weak var pdfView:
        PDFView?

    var notes:
        [PDFNote] = []

    var onOpenNote:
        ((PDFNote) -> Void)?

    override var isOpaque:
        Bool {
        false
    }

    // =========================================================
    // HIT TEST
    // =========================================================

    override func hitTest(
        _ point: NSPoint
    ) -> NSView? {

        guard
            let pdfView =
                pdfView
        else {
            return nil
        }

        for note in notes {

            guard
                let page =
                    pdfView.document?
                        .page(
                            at:
                                note.pageNumber - 1
                        )
            else {
                continue
            }

            let textRect =
                pdfView.convert(
                    note.bounds,
                    from:
                        page
                )

            let marker =
                markerRect(
                    for:
                        textRect,
                    page:
                        page
                )

            if marker
                .insetBy(
                    dx:
                        -8,
                    dy:
                        -8
                )
                .contains(
                    point
                ) {

                return self
            }
        }

        return nil
    }

    // =========================================================
    // CLICK MARKER
    // =========================================================

    override func mouseDown(
        with event: NSEvent
    ) {

        guard
            let pdfView =
                pdfView
        else {
            return
        }

        let point =
            convert(
                event.locationInWindow,
                from:
                    nil
            )

        for note in notes {

            guard
                let page =
                    pdfView.document?
                        .page(
                            at:
                                note.pageNumber - 1
                        )
            else {
                continue
            }

            let textRect =
                pdfView.convert(
                    note.bounds,
                    from:
                        page
                )

            let marker =
                markerRect(
                    for:
                        textRect,
                    page:
                        page
                )

            if marker
                .insetBy(
                    dx:
                        -8,
                    dy:
                        -8
                )
                .contains(
                    point
                ) {

                onOpenNote?(
                    note
                )

                return
            }
        }
    }

    // =========================================================
    // DRAW
    // =========================================================

    override func draw(
        _ dirtyRect: NSRect
    ) {

        guard
            let pdfView =
                pdfView
        else {
            return
        }

        for note in notes {

            guard
                let page =
                    pdfView.document?
                        .page(
                            at:
                                note.pageNumber - 1
                        )
            else {
                continue
            }

            let textRect =
                pdfView.convert(
                    note.bounds,
                    from:
                        page
                )

            guard !textRect.isEmpty else {
                continue
            }

            let marker =
                markerRect(
                    for:
                        textRect,
                    page:
                        page
                )

            // =================================================
            // BLUE UNDERLINE
            // =================================================

            let underline =
                NSBezierPath()

            underline.move(
                to:
                    NSPoint(
                        x:
                            textRect.minX,
                        y:
                            textRect.minY - 2
                    )
            )

            underline.line(
                to:
                    NSPoint(
                        x:
                            textRect.maxX,
                        y:
                            textRect.minY - 2
                    )
            )

            NSColor(
                red:
                    0.48,

                green:
                    0.65,

                blue:
                    0.85,

                alpha:
                    0.95
            ).setStroke()

            underline.lineWidth =
                2

            underline.stroke()

            // =================================================
            // CONNECTOR LINE
            // =================================================

            let line =
                NSBezierPath()

            line.move(
                to:
                    NSPoint(
                        x:
                            textRect.maxX,
                        y:
                            textRect.midY
                    )
            )

            line.line(
                to:
                    NSPoint(
                        x:
                            marker.minX,
                        y:
                            marker.midY
                    )
            )

            NSColor(
                red:
                    0.48,

                green:
                    0.65,

                blue:
                    0.85,

                alpha:
                    0.70
            ).setStroke()

            line.lineWidth =
                1.2

            line.stroke()

            // =================================================
            // OUTER DOT
            // =================================================

            NSColor(
                red:
                    0.48,

                green:
                    0.65,

                blue:
                    0.85,

                alpha:
                    1.0
            ).setFill()

            let circle =
                NSBezierPath(
                    ovalIn:
                        marker
                )

            circle.fill()

            // =================================================
            // INNER DOT
            // =================================================

            NSColor.white.setFill()

            let inner =
                NSBezierPath(
                    ovalIn:
                        marker.insetBy(
                            dx:
                                4,

                            dy:
                                4
                        )
                )

            inner.fill()
        }
    }

    // =========================================================
    // MARKER POSITION
    // =========================================================

    private func markerRect(
        for textRect: CGRect,
        page: PDFPage
    ) -> CGRect {

        guard
            let pdfView =
                pdfView
        else {
            return CGRect(
                x:
                    textRect.maxX + 8,

                y:
                    textRect.midY - 7,

                width:
                    14,

                height:
                    14
            )
        }

        // -----------------------------------------------------
        // Get actual visible page rectangle.
        // -----------------------------------------------------

        let pageBounds =
            page.bounds(
                for:
                    .mediaBox
            )

        let pageRect =
            pdfView.convert(
                pageBounds,
                from:
                    page
            )

        // -----------------------------------------------------
        // Normally put marker just after selected text.
        // -----------------------------------------------------

        var x =
            textRect.maxX + 8

        // -----------------------------------------------------
        // If text is near right edge, keep marker inside page.
        // -----------------------------------------------------

        let maximumX =
            pageRect.maxX - 20

        if x > maximumX {

            x =
                maximumX
        }

        // -----------------------------------------------------
        // Keep marker vertically inside page.
        // -----------------------------------------------------

        var y =
            textRect.midY - 7

        let minimumY =
            pageRect.minY + 4

        let maximumY =
            pageRect.maxY - 18

        y =
            max(
                minimumY,
                min(
                    y,
                    maximumY
                )
            )

        return CGRect(
            x:
                x,

            y:
                y,

            width:
                14,

            height:
                14
        )
    }
}


// =============================================================
// F-26: HIGHLIGHTS IN THE DATABASE, NEVER IN THE PDF (Agent 67)
// =============================================================

/// A highlight to draw. Page is 1-based; rects are in PDF page points.
struct PDFStoredHighlight: Identifiable, Equatable {
    let id: String
    let page: Int
    let color: String
    let rects: [CGRect]
}

extension PDFStoredHighlight {

    /// Library annotation -> drawable highlight (highlights only).
    init?(_ annotation: Annotation) {

        guard annotation.kind == .highlight,
              !annotation.rects.isEmpty else { return nil }

        self.init(
            id: annotation.id,
            page: annotation.page,
            color: annotation.color,
            rects: annotation.rects.map {
                CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
        )
    }
}

/// What the user asked to highlight. The caller stores it.
struct PDFHighlightRequest: Equatable {
    let page: Int
    let color: String
    let quote: String
    let rects: [CGRect]
}

enum PDFHighlightPalette {

    static let names = ["yellow", "green", "blue", "pink"]

    static func normalized(_ name: String) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return names.contains(value) ? value : "yellow"
    }

    static func color(named name: String) -> NSColor {
        switch normalized(name) {
        case "green": return NSColor(red: 0.47, green: 0.86, blue: 0.55, alpha: 0.55)
        case "blue":  return NSColor(red: 0.47, green: 0.71, blue: 1.00, alpha: 0.55)
        case "pink":  return NSColor(red: 0.94, green: 0.51, blue: 0.78, alpha: 0.55)
        default:      return NSColor(red: 1.00, green: 0.87, blue: 0.09, alpha: 0.55)
        }
    }
}

enum PDFHighlightDrawing {

    static let tagPrefix = "rb-highlight:"

    /// Draws one highlight on a document in memory.
    static func add(_ highlight: PDFStoredHighlight, to document: PDFDocument) {

        guard highlight.page >= 1,
              let page = document.page(at: highlight.page - 1) else { return }

        for rect in highlight.rects where !rect.isEmpty {

            let annotation = PDFAnnotation(
                bounds: rect,
                forType: .highlight,
                withProperties: nil
            )

            annotation.color = PDFHighlightPalette.color(named: highlight.color)
            annotation.userName = tagPrefix + highlight.id
            page.addAnnotation(annotation)
        }
    }

    /// Removes every highlight this code drew; other annotations stay.
    static func removeAll(from document: PDFDocument) {

        for index in 0..<document.pageCount {

            guard let page = document.page(at: index) else { continue }

            for annotation in page.annotations
            where annotation.userName?.hasPrefix(tagPrefix) == true {
                page.removeAnnotation(annotation)
            }
        }
    }

    /// Replaces the drawn highlights with exactly this list.
    static func apply(_ highlights: [PDFStoredHighlight], to document: PDFDocument) {

        removeAll(from: document)
        highlights.forEach { add($0, to: document) }
    }
}

enum PDFHighlightExport {

    /// Writes a marked-up COPY of the PDF. The source file is never
    /// changed, and writing over it is refused.
    @discardableResult
    static func exportMarkedUp(
        source: URL,
        highlights: [PDFStoredHighlight],
        to destination: URL
    ) -> Bool {

        guard source.standardizedFileURL != destination.standardizedFileURL,
              let document = PDFDocument(url: source) else { return false }

        PDFHighlightDrawing.apply(highlights, to: document)

        return document.write(to: destination)
    }
}

extension ResearchPDFView {

    /// Draws the given highlights (and removes ones no longer in the list).
    func applyStoredHighlights(_ highlights: [PDFStoredHighlight]) {

        guard let document else { return }

        if appliedDocument === document, appliedHighlights == highlights {
            return
        }

        PDFHighlightDrawing.apply(highlights, to: document)

        appliedDocument = document
        appliedHighlights = highlights

        needsDisplay = true
    }

    /// One request per page the selection touches, with one box per line.
    func highlightRequests(
        for selection: PDFSelection,
        colour: String
    ) -> [PDFHighlightRequest] {

        guard let document else { return [] }

        let lines = selection.selectionsByLine()

        var requests: [PDFHighlightRequest] = []

        for page in selection.pages {

            let index = document.index(for: page)

            guard index != NSNotFound else { continue }

            let onPage = lines.filter { $0.pages.contains(page) }

            var rects = onPage
                .map { $0.bounds(for: page) }
                .filter { !$0.isEmpty }

            if rects.isEmpty {

                let whole = selection.bounds(for: page)

                if !whole.isEmpty { rects = [whole] }
            }

            guard !rects.isEmpty else { continue }

            let pageText = onPage
                .compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            let quote = pageText.isEmpty
                ? (selection.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : pageText

            requests.append(
                PDFHighlightRequest(
                    page: index + 1,
                    color: PDFHighlightPalette.normalized(colour),
                    quote: quote,
                    rects: rects
                )
            )
        }

        return requests
    }
}
