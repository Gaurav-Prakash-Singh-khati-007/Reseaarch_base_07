//
//  PaperDetailView.swift
//  ResearchBase
//
//  Phase 6 — Reference/PDF lifecycle support
//  Phase 13 — Papers workspace: status/rating, delete, annotation list,
//  real research connections (PapersResearchConnectionsView)
//
//  Owner: Agent 68 · Features: F-10, F-21, F-25, F-45
//  D1: when libraryModel + libraryItemID are passed and the item exists in the
//  SQLite library, title, authors, venue, year, tags, status, rating, abstract,
//  DOI, citation key, type and PDF are read from SQLite, and status, rating and
//  delete are written to SQLite. Without them the screen reads the PaperRecord as before.
//  Notes, findings, gaps and PDF annotations still come from the PaperRecord (BLOCKED, see report).
//  PUBLIC API (added; the existing init call stays valid)
//    PaperDetailView(..., libraryModel: LibraryModel? = nil,
//                         libraryItemID: String? = nil,
//                         onOpenLibraryItem: ((String) -> Void)? = nil)
//    RBA68Logic (pure helpers, unit-tested)
//  F-21 works today (DOI / arXiv ID from the paper, checked only when the
//  person presses the button). F-10, F-25 and F-45 need the SQLite library:
//  they appear once the app wiring (#76) passes libraryModel + libraryItemID.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct PaperDetailView: View {

    @Environment(\.modelContext)
    private var modelContext

    @EnvironmentObject
    private var router: NavigationRouter

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    let paperRecord: PaperRecord
    let onBack: () -> Void
    let onOpenPDF: () -> Void

    // F-10 / F-25 / F-45 (Agent 68): the SQLite library. nil until wired.
    var libraryModel: LibraryModel? = nil
    var libraryItemID: String? = nil
    /// Called with a library item id when a related paper is clicked.
    var onOpenLibraryItem: ((String) -> Void)? = nil

    // Agent 68
    @State private var versionResult: PublishedVersionResult?
    @State private var isCheckingVersion = false
    @State private var libraryFiles: [Attachment] = []
    @State private var showingAttachmentImporter = false
    @State private var attachmentError: String?
    @State private var citationGraph: CitationGraph?
    @State private var relatedByCitations: [CitationRelated] = []
    @State private var whereUsedToken = 0
    @State private var sqlFields: RBA68Fields?

    @State private var showingNewNote = false
    @State private var editingNote: ResearchNote?
    @State private var showingReferenceEditor = false
    @State private var showingPDFImporter = false
    @State private var showingReplacePDFConfirm = false

    @State private var copiedCitationMessage: String?
    @State private var errorMessage: String?

    @State private var showingDeleteConfirm = false
    @State private var actionErrorMessage: String?

    /// Used to find the manuscripts that have this paper in their
    /// research context ("Cited in my papers").
    @Query(sort: [SortDescriptor(\WritingDocument.updatedAt, order: .reverse)])
    private var allDocuments: [WritingDocument]

    private var paper: Paper {

        Paper(
            id: paperRecord.id,
            title: fields.title,
            authors: fields.authors,
            venue: fields.venue,
            year: fields.year,
            tags: fields.tags,
            status: fields.status,
            rating: fields.rating,
            abstractText: fields.abstractText,
            doi: fields.doi,
            urlString: fields.urlString,
            pdfFilePath: paperRecord.pdfFilePath,
            addedAt: paperRecord.addedAt,
            lastOpenedAt: paperRecord.lastOpenedAt
        )
    }

    private var pdfURL: URL? {

        if usesLibrary,
           let model = libraryModel,
           let file = libraryFiles.first(where: { $0.kind == .pdf }),
           let url = try? model.attachments.fileURL(for: file),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if usesLibrary { return nil }

        guard !paperRecord.pdfFilePath.isEmpty else {
            return nil
        }

        let url =
            URL(
                fileURLWithPath:
                    paperRecord.pdfFilePath
            )

        guard
            FileManager.default.fileExists(
                atPath: url.path
            )
        else {
            return nil
        }

        return url
    }

    private var hasPDF: Bool {
        pdfURL != nil
    }

    private var sortedResearchNotes: [ResearchNote] {

        paperRecord.researchNotes.sorted {
            $0.updatedAt > $1.updatedAt
        }
    }

    /// What the screen shows: the SQLite item when it is available, else the legacy record.
    private var fields: RBA68Fields {
        sqlFields ?? RBA68Fields(record: paperRecord)
    }

    /// True when the SQLite item is loaded, so reads and writes go to SQLite (D1).
    private var usesLibrary: Bool {
        libraryModel != nil && libraryItemID != nil && sqlFields != nil
    }

    private func reloadFields() {
        guard let model = libraryModel, let id = libraryItemID else {
            sqlFields = nil
            return
        }
        sqlFields = RBA68Logic.fields(model: model, itemID: id)
        if sqlFields != nil { libraryFiles = RBA68Logic.files(model: model, itemID: id) }
    }

    /// Attach a PDF: into the library when it is the source of truth, else the legacy way.
    private func startAttachPDF() {
        if usesLibrary {
            showingAttachmentImporter = true
        } else {
            showingPDFImporter = true
        }
    }

    var body: some View {

        detailContent
            .task(id: libraryItemID ?? "") { reloadFields() }
    }

    // MARK: - Detail Content

    private var detailContent: some View {

        VStack(spacing: 0) {

            topBar

            Divider()
                .overlay(RBColor.border)

            ScrollView {

                VStack(
                    alignment: .leading,
                    spacing: 28
                ) {

                    headerSection

                    publishedVersionSection

                    libraryInsightSections

                    metadataSection

                    referenceSection

                    abstractSection

                    researchNotesSection


                    libraryPanels
                    PapersResearchConnectionsView(
                        paperRecord: paperRecord,
                        onNavigate: {
                            router.open($0)
                        }
                    )

                    notesSection
                }
                .rbResponsiveContentPadding()
            }
        }
        .frame(
            minWidth: 560,
            minHeight: 500
        )
        // D4: no full-window fill; ContentView draws the theme behind this screen.

        .sheet(
            isPresented: $showingNewNote
        ) {

            NoteEditorView(
                note: nil,
                preselectedPaper: paperRecord
            )
        }

        .sheet(
            item: $editingNote
        ) { note in

            NoteEditorView(
                note: note,
                preselectedPaper: nil
            )
        }

        .sheet(
            isPresented: $showingReferenceEditor,
            onDismiss: {
                leaveIfPaperWasDeleted()
            }
        ) {

            if usesLibrary,
               let model = libraryModel,
               let itemID = libraryItemID {

                // Library papers are edited in (and saved to) the SQLite library.
                RBLibraryReferenceEditor(
                    model: model,
                    itemID: itemID,
                    onSaved: { reloadFields() }
                )

            } else {

                ReferenceDetailView(
                    paper: paperRecord
                )
            }
        }

        .fileImporter(
            isPresented: $showingPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in

            handlePDFImport(result)
        }

        .alert(
            "Replace PDF?",
            isPresented:
                $showingReplacePDFConfirm
        ) {

            Button(
                "Cancel",
                role: .cancel
            ) {}

            Button("Choose New PDF") {
                showingPDFImporter = true
            }

        } message: {

            Text(
                "The existing PDF will be replaced on this PaperRecord. Research notes and PDF annotations remain attached to the same PaperRecord."
            )
        }

        .alert(
            "Could Not Attach PDF",
            isPresented: Binding(
                get: {
                    errorMessage != nil
                },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {

            Button("OK") {
                errorMessage = nil
            }

        } message: {

            Text(errorMessage ?? "")
        }

        .alert(
            "Delete Paper?",
            isPresented: $showingDeleteConfirm
        ) {

            Button(
                "Cancel",
                role: .cancel
            ) {}

            Button(
                "Delete Paper",
                role: .destructive
            ) {
                deletePaper()
            }

        } message: {

            Text(
                "This removes \"\(fields.title)\" from your library, including its PDF annotations. Research notes, tasks, projects and other items that link to it are kept and simply lose the link. The PDF file itself is not deleted from disk."
            )
        }

        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: {
                    actionErrorMessage != nil
                },
                set: {
                    if !$0 {
                        actionErrorMessage = nil
                    }
                }
            )
        ) {

            Button("OK") {
                actionErrorMessage = nil
            }

        } message: {

            Text(actionErrorMessage ?? "")
        }
    }

    // MARK: - Published version / retraction (F-21, Agent 68)

    @ViewBuilder
    private var publishedVersionSection: some View {

        let query = RBA68Logic.query(
            doi: fields.doi,
            urlString: fields.urlString
        )

        if query.doi != nil || query.arxivID != nil {

            VStack(alignment: .leading, spacing: 8) {

                HStack(spacing: 10) {

                    if let result = versionResult {

                        let badge = RBA68Logic.versionBadge(result)

                        RBBadge(
                            text: badge.title,
                            tone: RBA68Logic.tone(for: badge.kind),
                            icon: RBA68Logic.icon(for: badge.kind)
                        )
                    }

                    Spacer()

                    Button(
                        isCheckingVersion
                            ? "Checking…"
                            : (versionResult == nil
                               ? "Check for published version"
                               : "Check again")
                    ) {
                        checkPublishedVersion(query)
                    }
                    .disabled(isCheckingVersion)
                }

                if let result = versionResult {

                    Text(result.summaryLine)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                } else {

                    Text("Only the DOI or arXiv ID is sent to Crossref, arXiv and OpenAlex, and only when you press the button.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
            }
        }
    }

    private func checkPublishedVersion(_ query: PublishedVersionQuery) {

        isCheckingVersion = true

        Task {
            let result = await PublishedVersionChecker().check(query)

            await MainActor.run {
                versionResult = result
                isCheckingVersion = false
            }
        }
    }

    // MARK: - Library panels (F-10, F-25, F-45, Agent 68)

    @ViewBuilder
    private var libraryPanels: some View {

        if let model = libraryModel, let itemID = libraryItemID {

            VStack(alignment: .leading, spacing: 28) {

                libraryFilesSection(model: model, itemID: itemID)

                relatedPapersSection

                WhereUsedPanel(
                    model: model,
                    end: LinkEnd(.item, itemID),
                    reloadToken: whereUsedToken,
                    onOpen: onOpenLibraryItem == nil
                        ? nil
                        : { end in
                            if end.type == .item {
                                onOpenLibraryItem?(end.id)
                            }
                        }
                )
            }
            .task(id: itemID) {
                reloadLibraryPanels(model: model, itemID: itemID)
            }
        }
    }

    private func reloadLibraryPanels(model: LibraryModel, itemID: String) {

        libraryFiles = RBA68Logic.files(model: model, itemID: itemID)

        let related = RBA68Logic.loadRelated(model: model, itemID: itemID)
        citationGraph = related.graph
        relatedByCitations = related.related

        whereUsedToken += 1
    }

    private func libraryFilesSection(
        model: LibraryModel,
        itemID: String
    ) -> some View {

        VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 8) {

                Text("Files")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                RBBadge(text: "\(libraryFiles.count)", tone: .muted)

                Spacer()

                Button("Add file…") {
                    showingAttachmentImporter = true
                }
            }

            if libraryFiles.isEmpty {

                Text("No files attached yet. Add the PDF, supplements, code or slides.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)

            } else {

                RBCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(libraryFiles, id: \.id) { file in
                            libraryFileRow(file, model: model, itemID: itemID)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingAttachmentImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            addLibraryFiles(result, model: model, itemID: itemID)
        }
        .alert(
            "Could Not Add File",
            isPresented: Binding(
                get: { attachmentError != nil },
                set: { if !$0 { attachmentError = nil } }
            )
        ) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private func libraryFileRow(
        _ file: Attachment,
        model: LibraryModel,
        itemID: String
    ) -> some View {

        HStack(spacing: 10) {

            Image(systemName: RBA68Logic.symbol(for: file.kind))
                .foregroundStyle(RBColor.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {

                Text(RBA68Logic.displayName(file))
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)

                Text(RBA68Logic.detailLine(file))
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }

            Spacer()

            if file.isPrimary {
                RBBadge(text: "Primary", tone: .accent)
            } else {
                Button("Make primary") {
                    do {
                        try model.attachments.setPrimary(attachmentID: file.id)
                    } catch {
                        attachmentError = error.localizedDescription
                    }
                    reloadLibraryPanels(model: model, itemID: itemID)
                }
                .buttonStyle(.plain)
                .font(RBFont.caption(.medium))
                .foregroundStyle(RBColor.accent)
            }

            Button("Open") {
                do {
                    NSWorkspace.shared.open(
                        try model.attachments.fileURL(for: file)
                    )
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        }
    }

    private func addLibraryFiles(
        _ result: Result<[URL], Error>,
        model: LibraryModel,
        itemID: String
    ) {

        guard case .success(let urls) = result else { return }

        for url in urls {

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                try model.attachments.add(
                    fileAt: url,
                    to: itemID,
                    kind: RBA68Logic.kind(forFileExtension: url.pathExtension)
                )
            } catch {
                attachmentError = error.localizedDescription
            }
        }

        reloadLibraryPanels(model: model, itemID: itemID)
    }

    @ViewBuilder
    private var relatedPapersSection: some View {

        VStack(alignment: .leading, spacing: 10) {

            Text("Related papers")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            let cites = citationGraph?.cites.inLibrary ?? []
            let citedBy = citationGraph?.citedBy.inLibrary ?? []

            if cites.isEmpty, citedBy.isEmpty, relatedByCitations.isEmpty {

                RBCard {
                    Text("No links to other papers in your library yet. When papers in your library cite each other, they show up here.")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.mutedText)
                }

            } else {

                RBCard {
                    VStack(alignment: .leading, spacing: 12) {

                        relatedGroup("Cites", refs: cites.map { ($0, nil) })

                        relatedGroup("Cited by", refs: citedBy.map { ($0, nil) })

                        relatedGroup(
                            "Related by shared references",
                            refs: relatedByCitations.map { ($0.ref, $0.shared) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relatedGroup(
        _ title: String,
        refs: [(CitationLibraryRef, Int?)]
    ) -> some View {

        if !refs.isEmpty {

            VStack(alignment: .leading, spacing: 6) {

                Text("\(title) (\(refs.count))")
                    .font(RBFont.label())
                    .foregroundStyle(RBColor.mutedText)

                ForEach(refs, id: \.0.itemID) { ref, shared in

                    Button {
                        onOpenLibraryItem?(ref.itemID)
                    } label: {
                        HStack(spacing: 8) {
                            Text(RBA68Logic.refLine(ref))
                                .font(RBFont.secondary())
                                .foregroundStyle(
                                    onOpenLibraryItem == nil
                                        ? RBColor.primaryText
                                        : RBColor.accent
                                )
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if let shared {
                                RBBadge(text: "\(shared) shared", tone: .muted)
                            }

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpenLibraryItem == nil)
                }
            }
        }
    }

    // MARK: - Top Bar
    // MARK: - Top Bar

    private var topBar: some View {

        HStack {

            Button {

                onBack()

            } label: {

                Label(
                    "Library",
                    systemImage: "chevron.left"
                )
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                RBColor.secondaryText
            )

            Spacer()

            Button {

                showingNewNote = true

            } label: {

                Label(
                    "Add Research Note",
                    systemImage:
                        "note.text.badge.plus"
                )
            }
            .buttonStyle(RBGhostButtonStyle())

            Button {

                if hasPDF {
                    onOpenPDF()
                } else {
                    startAttachPDF()
                }

            } label: {

                Label(
                    hasPDF
                    ? "Open PDF Reader"
                    : "Attach PDF",
                    systemImage:
                        hasPDF
                        ? "book.pages"
                        : "paperclip"
                )
            }
            .buttonStyle(RBPrimaryButtonStyle())

            if hasPDF && !usesLibrary {

                Button {

                    showingReplacePDFConfirm = true

                } label: {

                    Image(
                        systemName:
                            "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(RBGhostButtonStyle())
                .help("Replace PDF")
            }

            Button {

                showingDeleteConfirm = true

            } label: {

                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .tint(RBColor.error)
            .help("Delete Paper")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Header

    private var headerSection: some View {

        VStack(
            alignment: .leading,
            spacing: 12
        ) {

            Text(
                paper.title.isEmpty
                ? "Untitled"
                : paper.title
            )
            .font(RBFont.title(.semibold))
            .foregroundStyle(
                RBColor.primaryText
            )

            // Every paper shows the same rows. When a value is missing the
            // row stays and shows a muted placeholder, so papers with little
            // information look the same as papers with a lot.
            Text(
                paper.authors.isEmpty
                ? "No authors"
                : paper.authors
            )
            .font(RBFont.body())
            .foregroundStyle(
                paper.authors.isEmpty
                ? RBColor.mutedText
                : RBColor.secondaryText
            )

            HStack(spacing: 10) {

                Text(
                    paper.venue.isEmpty
                    ? "No venue"
                    : paper.venue
                )
                .foregroundStyle(
                    paper.venue.isEmpty
                    ? RBColor.mutedText
                    : RBColor.secondaryText
                )

                Text("•")

                Text(
                    paper.year > 0
                    ? String(paper.year)
                    : "No year"
                )
                .foregroundStyle(
                    paper.year > 0
                    ? RBColor.secondaryText
                    : RBColor.mutedText
                )

                Text("•")

                Text(
                    hasPDF
                    ? "PDF available"
                    : "Reference only"
                )
                .foregroundStyle(
                    hasPDF
                    ? RBColor.accent
                    : RBColor.warning
                )
            }
            .font(RBFont.secondary())
            .foregroundStyle(
                RBColor.secondaryText
            )

            readingControls

            if fields.tags.isEmpty {

                Text("No tags")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RBColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

            } else {

                HStack(spacing: 6) {

                    ForEach(
                        fields.tags,
                        id: \.self
                    ) { tag in

                        Text("#\(tag)")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(
                                RBColor.secondaryText
                            )
                            .padding(
                                .horizontal,
                                8
                            )
                            .padding(
                                .vertical,
                                4
                            )
                            .background(RBColor.surface)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: 6
                                )
                            )
                    }
                }
            }
        }
    }

    // MARK: - Library Insight (workflow, findings, gaps, citations)

    /// Manuscripts of yours that have this paper in their research context.
    private var citingDocuments: [WritingDocument] {
        allDocuments.filter { document in
            document.papers.contains { $0.id == paperRecord.id }
        }
    }

    private var sortedFindings: [LiteratureFinding] {
        paperRecord.literatureFindings.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sortedGaps: [ResearchGap] {
        paperRecord.linkedResearchGaps.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var libraryInsightSections: some View {

        VStack(alignment: .leading, spacing: 18) {
            workflowSection
            findingsSection
            gapsSection
            citedSection
        }
    }

    // Reading workflow: a tick means "done / has some".
    private var workflowSection: some View {

        VStack(alignment: .leading, spacing: 8) {

            RBSectionLabel(text: "Reading workflow")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    workflowChip("Added", done: true)
                    workflowChip("Read", done: fields.status == .read)
                    workflowChip(
                        "Highlights \(paperRecord.notes.count)",
                        done: !paperRecord.notes.isEmpty
                    )
                    workflowChip(
                        "Notes \(paperRecord.researchNotes.count)",
                        done: !paperRecord.researchNotes.isEmpty
                    )
                    workflowChip(
                        "Findings \(paperRecord.literatureFindings.count)",
                        done: !paperRecord.literatureFindings.isEmpty
                    )
                    workflowChip(
                        "Gaps \(paperRecord.linkedResearchGaps.count)",
                        done: !paperRecord.linkedResearchGaps.isEmpty
                    )
                }
            }
        }
    }

    private func workflowChip(_ text: String, done: Bool) -> some View {

        Text("\(done ? "✓" : "○") \(text)")
            .font(RBFont.caption(.medium))
            .foregroundStyle(done ? RBColor.accent : RBColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(done ? RBColor.accent.opacity(0.10) : RBColor.card)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(RBColor.border))
    }

    private var findingsSection: some View {

        VStack(alignment: .leading, spacing: 8) {

            RBSectionLabel(text: "Findings extracted")

            RBCard {
                if sortedFindings.isEmpty {
                    insightEmptyNote(
                        "No findings yet. Findings link to a paper from a Literature Review."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sortedFindings, id: \.id) { finding in
                            insightRow(
                                mark: "◆",
                                text: finding.title.isEmpty
                                    ? finding.content
                                    : finding.title,
                                trailing: nil
                            ) {
                                router.open(.literatureFinding(finding.id))
                            }
                        }
                    }
                }
            }
        }
    }

    private var gapsSection: some View {

        VStack(alignment: .leading, spacing: 8) {

            RBSectionLabel(text: "Research gaps identified")

            RBCard {
                if sortedGaps.isEmpty {
                    insightEmptyNote("No gaps linked yet.")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sortedGaps, id: \.id) { gap in
                            insightRow(
                                mark: "◇",
                                text: gap.title,
                                trailing: "→ Research Ideas"
                            ) {
                                router.open(.researchGap(gap.id))
                            }
                        }
                    }
                }
            }
        }
    }

    private var citedSection: some View {

        VStack(alignment: .leading, spacing: 8) {

            RBSectionLabel(text: "Cited in my papers")

            if citingDocuments.isEmpty {
                insightEmptyNote(
                    "Not cited yet. Link it from a paper's research context."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(citingDocuments, id: \.id) { document in
                            RBChip(
                                text: "▤ " + (
                                    document.title.isEmpty
                                        ? "Untitled document"
                                        : document.title
                                )
                            ) {
                                router.open(.writingDocument(document.id))
                            }
                        }
                    }
                }
            }
        }
    }

    private func insightRow(
        mark: String,
        text: String,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {

        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(mark) \(text)")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                if let trailing {
                    Text(trailing)
                        .font(RBFont.label())
                        .foregroundStyle(RBColor.mutedText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.sidebarItem)
    }

    private func insightEmptyNote(_ text: String) -> some View {

        Text(text)
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Reading Status + Rating

    private var readingControls: some View {

        HStack(spacing: 16) {

            Picker(
                "Status",
                selection: Binding(
                    get: {
                        fields.status
                    },
                    set: {
                        setStatus($0)
                    }
                )
            ) {

                ForEach(
                    ReadingStatus.allCases,
                    id: \.self
                ) { status in

                    Text(status.libraryLabel)
                        .tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            HStack(spacing: 2) {

                ForEach(
                    1...5,
                    id: \.self
                ) { index in

                    Button {

                        // Tapping the current rating clears it.
                        setRating(
                            fields.rating == index
                            ? 0
                            : index
                        )

                    } label: {

                        Image(
                            systemName:
                                index <= fields.rating
                                ? "star.fill"
                                : "star"
                        )
                        .font(RBFont.body())
                        .foregroundStyle(
                            index <= fields.rating
                            ? RBColor.warning
                            : RBColor.mutedText
                        )
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .help("Rate \(index)")
                }
            }

            Spacer()
        }
    }

    private func setStatus(
        _ status: ReadingStatus
    ) {

        guard status != fields.status else {
            return
        }

        if usesLibrary, let model = libraryModel, let id = libraryItemID {
            do {
                _ = try ReadingQueueStore(model: model)
                    .setStatus(itemID: id, RBA68Logic.itemStatus(status))
                reloadFields()
            } catch {
                actionErrorMessage =
                    "Could not save your change: \(error.localizedDescription)"
            }
            return
        }

        paperRecord.statusRawValue = status.rawValue
        paperRecord.updatedAt = Date()
        saveChanges()
    }

    private func setRating(
        _ rating: Int
    ) {

        let value = max(0, min(rating, 5))

        if usesLibrary, let model = libraryModel, let id = libraryItemID {
            do {
                _ = try model.items.update(id: id) { $0.rating = value }
                reloadFields()
            } catch {
                actionErrorMessage =
                    "Could not save your change: \(error.localizedDescription)"
            }
            return
        }

        paperRecord.rating = value
        paperRecord.updatedAt = Date()
        saveChanges()
    }

    private func saveChanges() {

        do {
            try modelContext.save()
        } catch {
            actionErrorMessage =
                "Could not save your change: \(error.localizedDescription)"
        }
    }

    // MARK: - Metadata

    private var metadataSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text("File Info")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(
                    RBColor.primaryText
                )

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                metadataRow(
                    label: "PDF",
                    value:
                        hasPDF
                        ? (
                            pdfURL?.path
                            ?? "PDF available"
                        )
                        : "No PDF attached"
                )

                metadataRow(
                    label: "Research Notes",
                    value:
                        "\(paperRecord.researchNotes.count)"
                )

                metadataRow(
                    label: "Annotations",
                    value:
                        "\(paperRecord.notes.count)"
                )
            }
            .padding(18)
            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.panel))
            .overlay(
                RoundedRectangle(
                    cornerRadius: RBRadius.panel
                )
                .stroke(RBColor.border)
            )

            if !hasPDF {

                HStack(spacing: 10) {

                    Image(
                        systemName: "paperclip"
                    )
                    .foregroundStyle(
                        RBColor.warning
                    )

                    Text(
                        "This reference has no PDF. Attach one to read and annotate it."
                    )
                    .font(RBFont.secondary())
                    .foregroundStyle(
                        RBColor.secondaryText
                    )

                    Spacer()

                    Button("Attach PDF") {
                        startAttachPDF()
                    }
                    .buttonStyle(
                        .borderedProminent
                    )
                }
                .padding(14)
                .background(
                    RBColor.warning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: RBRadius.panel)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: RBRadius.panel
                    )
                    .stroke(
                        RBColor.warning.opacity(0.25)
                    )
                )
            }
        }
    }

    private func metadataRow(
        label: String,
        value: String
    ) -> some View {

        HStack(
            alignment: .top,
            spacing: 16
        ) {

            Text(label)
                .font(RBFont.secondary())
                .foregroundStyle(
                    RBColor.mutedText
                )
                .frame(
                    width: 120,
                    alignment: .leading
                )

            Text(value)
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.primaryText
                )
                .textSelection(.enabled)

            Spacer()
        }
    }

    // MARK: - Reference / Citation

    private var referenceSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack {

                Text("Reference")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )

                Spacer()

                Button {

                    showingReferenceEditor = true

                } label: {

                    Label(
                        "Edit Reference",
                        systemImage: "pencil"
                    )
                }
                .buttonStyle(.bordered)
                .help("Edit this reference")
            }

            VStack(
                alignment: .leading,
                spacing: 8
            ) {

                metadataRow(
                    label: "Citation Key",
                    value:
                        fields.citationKey.isEmpty
                        ? "Not set"
                        : fields.citationKey
                )

                metadataRow(
                    label: "Publication Type",
                    value:
                        fields.typeLabel
                )

                metadataRow(
                    label: "DOI",
                    value:
                        fields.doi.isEmpty
                        ? "Not set"
                        : fields.doi
                )

                if !fields.missingWarnings.isEmpty {

                    metadataRow(
                        label: "Missing",
                        value:
                            fields.missingWarnings
                                .joined(
                                    separator: ", "
                                )
                    )
                }
            }
            .padding(18)
            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.panel))
            .overlay(
                RoundedRectangle(
                    cornerRadius: RBRadius.panel
                )
                .stroke(RBColor.border)
            )

            HStack(spacing: 10) {

                Menu {

                    ForEach(
                        CitationStyle.allCases
                    ) { style in

                        Button(style.rawValue) {
                            copyCitation(style: style)
                        }
                    }

                } label: {

                    Label(
                        "Copy Citation",
                        systemImage: "doc.on.doc"
                    )
                }
                .fixedSize()

                if !fields.citationKey.isEmpty {

                    Button {

                        copyText(
                            fields.citationKey,
                            message: "Citation key copied."
                        )

                    } label: {

                        Label(
                            "Copy Key",
                            systemImage: "key"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                if let copiedCitationMessage {

                    Text(copiedCitationMessage)
                        .font(RBFont.caption())
                        .foregroundStyle(
                            RBColor.success
                        )
                }
            }
        }
    }

    private func copyCitation(
        style: CitationStyle
    ) {

        copyText(
            CitationFormatter.citation(
                for: paperRecord,
                style: style
            ),
            message: "\(style.rawValue) citation copied."
        )
    }

    private func copyText(
        _ text: String,
        message: String
    ) {

        let pasteboard =
            NSPasteboard.general

        pasteboard.clearContents()

        pasteboard.setString(
            text,
            forType: .string
        )

        copiedCitationMessage = message

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2
        ) {

            copiedCitationMessage = nil
        }
    }

    // MARK: - Abstract

    private var abstractSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            Text("Abstract")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(
                    RBColor.primaryText
                )

            if fields.abstractText.isEmpty {

                Text(
                    "No abstract added yet."
                )
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.mutedText
                )

            } else {

                Text(
                    fields.abstractText
                )
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.secondaryText
                )
                .lineSpacing(4)
            }
        }
        .padding(18)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.panel))
        .overlay(
            RoundedRectangle(
                cornerRadius: RBRadius.panel
            )
            .stroke(RBColor.border)
        )
    }

    // MARK: - Research Notes

    private var researchNotesSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack {

                Text("Research Notes")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )

                Spacer()

                Text(
                    "\(sortedResearchNotes.count)"
                )
                .font(RBFont.secondary())
                .foregroundStyle(
                    RBColor.secondaryText
                )
            }

            if sortedResearchNotes.isEmpty {

                Text(
                    "No research notes yet. Use \"Add Research Note\" above to capture concepts, findings, methods, definitions, or research gaps from this paper."
                )
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.mutedText
                )
                .padding(18)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.panel))
                .overlay(
                    RoundedRectangle(
                        cornerRadius: RBRadius.panel
                    )
                    .stroke(RBColor.border)
                )

            } else {

                VStack(spacing: 8) {

                    ForEach(
                        sortedResearchNotes
                    ) { note in

                        Button {

                            editingNote = note

                        } label: {

                            HStack(
                                alignment: .top
                            ) {

                                VStack(
                                    alignment: .leading,
                                    spacing: 4
                                ) {

                                    Text(note.title)
                                        .font(RBFont.body(.medium))
                                        .foregroundStyle(
                                            RBColor.primaryText
                                        )
                                        .lineLimit(1)

                                    if !note.content.isEmpty {

                                        Text(note.content)
                                            .font(RBFont.secondary())
                                            .foregroundStyle(
                                                RBColor.secondaryText
                                            )
                                            .lineLimit(2)
                                    }
                                }

                                Spacer()

                                Text(
                                    note.noteType.rawValue
                                )
                                .font(RBFont.label(.medium))
                                .foregroundStyle(
                                    RBColor.accent
                                )
                                .padding(
                                    .horizontal,
                                    8
                                )
                                .padding(
                                    .vertical,
                                    4
                                )
                                .background(
                                    RBColor.accent
                                        .opacity(0.12)
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 6
                                    )
                                )
                            }
                            .padding(14)
                            .background(
                                RBColor.card,
                                in: RoundedRectangle(cornerRadius: RBRadius.field)
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: RBRadius.field
                                )
                                .stroke(
                                    RBColor.border
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                    }
                }
            }
        }
    }

    // MARK: - PDF Annotations

    private var sortedAnnotations: [PDFNoteRecord] {

        paperRecord.notes.sorted {
            if $0.pageNumber != $1.pageNumber {
                return $0.pageNumber < $1.pageNumber
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private var notesSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack {

                Text("Annotations")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )

                Spacer()

                Text(
                    "\(paperRecord.notes.count)"
                )
                .font(RBFont.secondary())
                .foregroundStyle(
                    RBColor.secondaryText
                )
            }

            if paperRecord.notes.isEmpty {

                Text(
                    hasPDF
                    ? "No annotations yet. Open the PDF to highlight text and add notes."
                    : "Annotations become available after attaching a PDF."
                )
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.secondaryText
                )

            } else {

                Text(
                    "Highlights and notes saved with this paper. Open the PDF to search, navigate pages, zoom and edit them."
                )
                .font(RBFont.secondary())
                .foregroundStyle(
                    RBColor.mutedText
                )

                VStack(spacing: 8) {

                    ForEach(
                        sortedAnnotations
                    ) { annotation in

                        annotationRow(annotation)
                    }
                }
            }
        }
    }

    private func annotationRow(
        _ annotation: PDFNoteRecord
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 6
        ) {

            Text("Page \(annotation.pageNumber)")
                .font(RBFont.label(.semibold))
                .foregroundStyle(RBColor.accent)

            if !annotation.text.isEmpty {

                Text(annotation.text)
                    .font(RBFont.secondary())
                    .foregroundStyle(
                        RBColor.primaryText
                    )
                    .lineLimit(4)
            }

            if !annotation.note.isEmpty {

                Text(annotation.note)
                    .font(RBFont.secondary())
                    .foregroundStyle(
                        RBColor.secondaryText
                    )
                    .lineLimit(4)
            }
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(
            RoundedRectangle(
                cornerRadius: RBRadius.field
            )
            .stroke(RBColor.border)
        )
    }

    // MARK: - Delete

    private func deletePaper() {

        do {

            if usesLibrary, let model = libraryModel, let id = libraryItemID {
                // Soft delete: the paper stays in the database with a deleted date.
                try RBA68Logic.trash(model: model, itemID: id)
            } else {
                try store.deletePaper(paperRecord)
            }

            onBack()

        } catch {

            actionErrorMessage =
                "Could not delete the paper: \(error.localizedDescription)"
        }
    }

    /// The Edit Reference sheet can delete this paper. When it closes,
    /// leave this screen instead of showing a paper that no longer
    /// exists.
    private func leaveIfPaperWasDeleted() {

        if usesLibrary, let model = libraryModel, let itemID = libraryItemID {
            if (try? model.items.fetch(id: itemID)) == nil { onBack() }
            return
        }

        let id = paperRecord.id

        let stillExists =
            ((try? store.fetchPapers()) ?? [])
                .contains { $0.id == id }

        if !stillExists {
            onBack()
        }
    }

    // MARK: - PDF Import

    private func handlePDFImport(
        _ result: Result<[URL], Error>
    ) {

        switch result {

        case .success(let urls):

            guard let sourceURL = urls.first else {
                return
            }

            attachPDF(
                from: sourceURL
            )

        case .failure(let error):

            errorMessage =
                error.localizedDescription
        }
    }

    private func attachPDF(
        from sourceURL: URL
    ) {

        do {

            let importedURL =
                try PaperStorage.shared.importPDF(
                    from: sourceURL
                )

            let previousPath =
                paperRecord.pdfFilePath

            // IMPORTANT:
            // Modify the existing PaperRecord.
            // Never create another PaperRecord.
            paperRecord.pdfFilePath =
                importedURL.path

            paperRecord.updatedAt =
                Date()

            try modelContext.save()

            // Delete the old managed PDF only after
            // the new path has been successfully persisted.
            if
                !previousPath.isEmpty,
                previousPath != importedURL.path
            {

                let oldURL =
                    URL(
                        fileURLWithPath:
                            previousPath
                    )

                if PaperStorage.shared
                    .isManagedPaperFile(oldURL)
                {

                    try? PaperStorage.shared
                        .deletePDF(
                            at: oldURL
                        )
                }
            }

        } catch {

            errorMessage =
                "Could not attach PDF: \(error.localizedDescription)"
        }
    }
}


// =============================================================
// HELPERS (Agent 68)
// =============================================================

struct RBA68VersionBadge: Equatable {

    enum Kind: Equatable {
        case retracted, concern, published, clear, notChecked
    }

    let kind: Kind
    let title: String
}

struct RBA68Related {
    var graph: CitationGraph?
    var related: [CitationRelated]
}

/// The bibliographic fields this screen shows, from SQLite or from the legacy record.
struct RBA68Fields: Equatable {
    var title: String
    var authors: String
    var venue: String
    var year: Int
    var tags: [String]
    var status: ReadingStatus
    var rating: Int
    var abstractText: String
    var doi: String
    var urlString: String
    var citationKey: String
    var typeLabel: String

    init(
        title: String, authors: String, venue: String, year: Int, tags: [String],
        status: ReadingStatus, rating: Int, abstractText: String, doi: String,
        urlString: String, citationKey: String, typeLabel: String
    ) {
        self.title = title; self.authors = authors; self.venue = venue; self.year = year
        self.tags = tags; self.status = status; self.rating = rating
        self.abstractText = abstractText; self.doi = doi; self.urlString = urlString
        self.citationKey = citationKey; self.typeLabel = typeLabel
    }

    init(record: PaperRecord) {
        self.init(
            title: record.title, authors: record.authors, venue: record.venue,
            year: record.year, tags: record.tags, status: record.readingStatus,
            rating: record.rating, abstractText: record.abstractText, doi: record.doi,
            urlString: record.urlString, citationKey: record.citationKey,
            typeLabel: record.publicationType.rawValue
        )
    }

    /// Short notes about incomplete bibliographic data.
    var missingWarnings: [String] {
        var warnings: [String] = []
        if authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("Missing authors") }
        if year <= 0 { warnings.append("Missing year") }
        if venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("Missing venue") }
        if doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("Missing DOI") }
        return warnings
    }
}

enum RBA68Logic {

    // MARK: F-21

    /// Only an arXiv URL or "arXiv:" text counts as an arXiv ID.
    static func arxivID(fromURLString text: String) -> String? {
        let lower = text.lowercased()
        guard lower.contains("arxiv.org/abs/") || lower.hasPrefix("arxiv:") else { return nil }
        return PublishedVersionChecker.normalizedArXivID(
            lower.contains("arxiv.org/abs/")
                ? String(text[text.range(of: "arxiv.org/abs/", options: .caseInsensitive)!.upperBound...])
                : text
        )
    }

    static func query(doi: String, urlString: String) -> PublishedVersionQuery {
        PublishedVersionQuery(
            doi: PublishedVersionChecker.normalizedDOI(doi),
            arxivID: arxivID(fromURLString: urlString)
        )
    }

    static func versionBadge(_ result: PublishedVersionResult) -> RBA68VersionBadge {

        guard result.status == .checked else {
            return RBA68VersionBadge(kind: .notChecked, title: "Not checked")
        }

        switch result.retraction {
        case .retracted:
            return RBA68VersionBadge(kind: .retracted, title: "Retracted")
        case .expressionOfConcern:
            return RBA68VersionBadge(kind: .concern, title: "Expression of concern")
        case .noneFound, .unknown:
            break
        }

        if result.publishedDOI != nil {
            return RBA68VersionBadge(kind: .published, title: "Published version found")
        }

        return RBA68VersionBadge(kind: .clear, title: "No problems found")
    }

    static func tone(for kind: RBA68VersionBadge.Kind) -> RBBadgeTone {
        switch kind {
        case .retracted: return .error
        case .concern: return .warning
        case .published: return .accent
        case .clear: return .ok
        case .notChecked: return .muted
        }
    }

    static func icon(for kind: RBA68VersionBadge.Kind) -> String {
        switch kind {
        case .retracted: return "exclamationmark.octagon.fill"
        case .concern: return "exclamationmark.triangle.fill"
        case .published: return "arrow.up.forward.circle.fill"
        case .clear: return "checkmark.seal.fill"
        case .notChecked: return "questionmark.circle"
        }
    }

    // MARK: D1 — read the paper from SQLite

    static func itemStatus(_ status: ReadingStatus) -> ItemReadingStatus {
        switch status {
        case .unread: return .unread
        case .reading: return .reading
        case .read: return .read
        }
    }

    static func readingStatus(_ status: ItemReadingStatus) -> ReadingStatus {
        switch status {
        case .unread: return .unread
        case .reading: return .reading
        case .read: return .read
        }
    }

    /// nil when the item is not in the library (or is in the Trash).
    static func fields(model: LibraryModel, itemID: String) -> RBA68Fields? {
        guard let item = try? model.items.fetch(id: itemID) else { return nil }

        let creators = (try? model.creators.creators(of: itemID)) ?? []
        let authors = creators.filter { $0.role == .author }
        let names = (authors.isEmpty ? creators : authors).map { $0.creator.displayName }
        let tags = ((try? model.tags.tags(of: itemID)) ?? []).map(\.name)

        return RBA68Fields(
            title: item.title,
            authors: names.joined(separator: "; "),
            venue: item.venue,
            year: item.year ?? 0,
            tags: tags,
            status: readingStatus(item.readingStatus),
            rating: item.rating,
            abstractText: item.abstract,
            doi: item.doi ?? "",
            urlString: item.url,
            citationKey: item.citationKey,
            typeLabel: item.type.displayName
        )
    }

    /// Soft delete (same as the Inbox): the Trash screen lists it and can restore it.
    static func trash(model: LibraryModel, itemID: String) throws {
        try model.atomically {
            let now = model.now()
            try model.database.run(
                "UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                [.text(now), .text(now), .text(itemID)]
            )
            try model.record("item", itemID, .delete, field: "deleted_at", old: nil, new: now)
        }
    }

    // MARK: F-10

    /// Files of one paper: primary first, then oldest first.
    static func files(model: LibraryModel, itemID: String) -> [Attachment] {
        let all = (try? model.attachments.attachments(of: itemID)) ?? []
        return all.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            return $0.addedAt < $1.addedAt
        }
    }

    static func kind(forFileExtension ext: String) -> AttachmentKind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "py", "ipynb", "swift", "js", "ts", "java", "cpp", "c", "rs", "go", "r", "m", "sh": return .code
        case "ppt", "pptx", "key": return .slides
        case "csv", "tsv", "json", "xlsx", "xls", "parquet", "npy", "npz": return .data
        case "html", "htm", "webarchive": return .snapshot
        default: return .supplement
        }
    }

    static func symbol(for kind: AttachmentKind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .supplement: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .slides: return "rectangle.on.rectangle"
        case .data: return "tablecells"
        case .snapshot: return "globe"
        case .other: return "paperclip"
        }
    }

    static func displayName(_ file: Attachment) -> String {
        let label = file.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { return label }
        return file.originalName.isEmpty ? "Untitled file" : file.originalName
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func detailLine(_ file: Attachment) -> String {
        var parts = [file.kind.rawValue.capitalized, formatBytes(file.bytes)]
        if let pages = file.pages, pages > 0 {
            parts.append("\(pages) \(pages == 1 ? "page" : "pages")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: F-25

    /// What the paper cites, what cites it, and papers that share
    /// references. Library only: nothing is sent anywhere.
    @MainActor
    static func loadRelated(model: LibraryModel, itemID: String) -> RBA68Related {

        let service = CitationGraphService(model: model, isOnlineEnabled: { false })

        return RBA68Related(
            graph: try? service.localGraph(for: itemID),
            related: (try? service.relatedByCitations(itemID: itemID, limit: 10)) ?? []
        )
    }

    static func refLine(_ ref: CitationLibraryRef) -> String {
        guard let year = ref.year else { return ref.title }
        return "\(ref.title) (\(year))"
    }
}


// MARK: - Reference editor for papers in the SQLite library

/// Edit Reference for a paper that lives in the SQLite library. Everything is
/// saved to the library (title, authors, venue, year, DOI, arXiv ID, link,
/// abstract, type and citation key), so papers imported with little
/// information can be completed by hand.
struct RBLibraryReferenceEditor: View {

    let model: LibraryModel
    let itemID: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var authorsText = ""
    @State private var venue = ""
    @State private var yearText = ""
    @State private var doi = ""
    @State private var arxivID = ""
    @State private var link = ""
    @State private var abstractText = ""
    @State private var type: ItemType = .article
    @State private var citationKey = ""

    @State private var originalKey = ""
    @State private var originalAuthors: [String: Creator] = [:]
    @State private var otherCreators: [CreatorInput] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {

        VStack(spacing: 0) {

            HStack {
                Text("Edit Reference")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
            }
            .padding(20)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    field("Title") {
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Authors (one per line: Family, Given)") {
                        TextEditor(text: $authorsText)
                            .font(RBFont.body())
                            .frame(height: 90)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(RBColor.border)
                            )
                    }

                    field("Type") {
                        Picker("Type", selection: $type) {
                            ForEach(ItemType.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        field("Venue / journal") {
                            TextField("Venue", text: $venue)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("Year") {
                            TextField("Year", text: $yearText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        field("DOI") {
                            TextField("10.xxxx/…", text: $doi)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("arXiv ID") {
                            TextField("2312.10997", text: $arxivID)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    field("Link") {
                        TextField("https://…", text: $link)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Citation key") {
                        HStack {
                            TextField("Citation key", text: $citationKey)
                                .textFieldStyle(.roundedBorder)
                            Button("Generate") { generateKey() }
                                .buttonStyle(RBGhostButtonStyle())
                        }
                    }

                    field("Abstract") {
                        TextEditor(text: $abstractText)
                            .font(RBFont.body())
                            .frame(height: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(RBColor.border)
                            )
                    }

                    if let errorText {
                        Text(errorText)
                            .font(RBFont.secondary(.medium))
                            .foregroundStyle(RBColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(RBGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(RBPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded)
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 620)
        .task { load() }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(RBFont.caption(.medium))
                .foregroundStyle(RBColor.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Load

    private func load() {
        guard !loaded else { return }
        do {
            guard let item = try model.items.fetch(id: itemID) else {
                errorText = "This paper is no longer in the library."
                return
            }
            title = item.title
            venue = item.venue
            yearText = (item.year ?? 0) > 0 ? String(item.year ?? 0) : ""
            doi = item.doi ?? ""
            arxivID = item.arxivID ?? ""
            link = item.url
            abstractText = item.abstract
            type = item.type
            citationKey = item.citationKey
            originalKey = item.citationKey

            var lines: [String] = []
            var originals: [String: Creator] = [:]
            var others: [CreatorInput] = []
            for entry in try model.creators.creators(of: itemID) {
                let person = entry.creator
                if entry.role == .author {
                    lines.append(person.displayName)
                    originals[person.displayName.lowercased()] = person
                } else {
                    others.append(CreatorInput(
                        family: person.family, given: person.given,
                        suffix: person.suffix, isOrganisation: person.isOrganisation,
                        orcid: person.orcid, role: entry.role
                    ))
                }
            }
            authorsText = lines.joined(separator: "\n")
            originalAuthors = originals
            otherCreators = others
            loaded = true
        } catch {
            errorText = AppErrorText.plain(error)
        }
    }

    // MARK: Authors

    private func authorInputs() -> [CreatorInput] {
        authorsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                // A line that was not changed keeps everything it had (suffix, ORCID, organisation).
                if let old = originalAuthors[line.lowercased()] {
                    return CreatorInput(
                        family: old.family, given: old.given, suffix: old.suffix,
                        isOrganisation: old.isOrganisation, orcid: old.orcid, role: .author
                    )
                }
                if let comma = line.firstIndex(of: ",") {
                    let family = line[..<comma].trimmingCharacters(in: .whitespaces)
                    let given = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    return CreatorInput(family: family, given: given, role: .author)
                }
                let words = line.split(separator: " ").map(String.init)
                if words.count <= 1 {
                    return CreatorInput(family: line, role: .author)
                }
                return CreatorInput(
                    family: words.last ?? line,
                    given: words.dropLast().joined(separator: " "),
                    role: .author
                )
            }
    }

    private func generateKey() {
        do {
            let year = Int(yearText.trimmingCharacters(in: .whitespaces))
            citationKey = try model.citationKeys.generate(
                firstCreator: authorInputs().first,
                year: year,
                title: title
            )
        } catch {
            errorText = AppErrorText.plain(error)
        }
    }

    // MARK: Save

    private func save() {
        errorText = nil

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorText = "The title cannot be empty."
            return
        }

        var year: Int?
        let yearTrimmed = yearText.trimmingCharacters(in: .whitespaces)
        if !yearTrimmed.isEmpty {
            guard let value = Int(yearTrimmed), (0...9999).contains(value) else {
                errorText = "Year must be a number such as 2023."
                return
            }
            year = value == 0 ? nil : value
        }

        func orNil(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        do {
            try model.items.update(id: itemID) { item in
                item.title = cleanTitle
                item.type = type
                item.venue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
                item.year = year
                item.doi = orNil(doi)
                item.arxivID = orNil(arxivID)
                item.url = link.trimmingCharacters(in: .whitespacesAndNewlines)
                item.abstract = abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            try model.creators.setCreators(itemID: itemID, authorInputs() + otherCreators)

            let newKey = citationKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newKey.isEmpty, newKey != originalKey {
                try model.citationKeys.change(itemID: itemID, to: newKey, confirmed: false)
            }

            onSaved()
            dismiss()
        } catch {
            errorText = AppErrorText.plain(error)
        }
    }
}
