//
//  WritingView.swift
//  ResearchBase
//
//  Owner: Agent 65 · Features: F-29, F-30, F-31, F-32, F-33, F-36, F-37, F-39, F-40
//
//  PUBLIC API
//    WritingView                               the Papers screen (unchanged signature)
//    WritingDocumentDetailView, WritingDocumentFormSheet, WritingDocumentMetadataFormSheet,
//    WritingSectionFormSheet, WritingSectionEditorView, WritingTableSheet,
//    WritingEquationSheet, WritingFormatSheet   (unchanged)
//    EnvironmentValues.rbA65Library: LibraryModel?
//        NEW. The open library. Batch 4 must set `.environment(\.rbA65Library, model)`.
//        While nil, the "LaTeX Projects" strip is hidden and the screen works as before.
//
//  Phase 10 — Research Writing Workspace
//
//  STEP 3 — Writing document list/workspace shell.
//  STEP 4 — "+ New Document" creation.
//  STEP 5 — Document and section navigation.
//  STEP 6 — Writing editor (plain long-form text, not LaTeX-only).
//  STEP 7 — Document management (metadata edit, status, search,
//           sort, filter, delete, last modified, word count).
//  STEP 8 — Citations, using the existing PaperRecord relationship
//           (document.papers) — no WritingCitation model.
//  STEP 9 — References, generated from linked PaperRecords via the
//           existing CitationFormatter (Phase 6) infrastructure.
//  STEP 10/11 — Research Context panel (WritingResearchContextView,
//           its own file) for browsing/linking Problems, Ideas,
//           Gaps, Experiments, Papers, Notes and Findings while
//           writing, and inserting a plain-text reference for any of
//           them — including a specific Experiment run — into
//           whichever section is currently open. Nothing inserted
//           here is ever a claim of novelty, significance,
//           superiority, validity or correctness; that's always the
//           researcher's own writing.
//
//  Lists existing WritingDocuments in the same manual-HStack
//  list/detail split-pane layout already used by Literature Review,
//  Research Ideas, Experiments and Results (Phase 7/8/9) — reusing
//  the RB9* shared atoms from ExperimentSharedUI.swift rather than
//  introducing new visual primitives.
//
//  Selecting a document now shows a real detail workspace
//  (WritingDocumentDetailView, below): a section list pane on the
//  left and, on the right, either the section editor
//  (WritingSectionEditorView) or a placeholder until a section is
//  selected/created.
//
//  Phase 3 (Agent 65): LaTeX projects. Each project is a real folder
//  (DraftFolderStore) with an editor, build + PDF preview, templates,
//  history, comments/TODOs, thesis chapters, import and export.
//  See "Phase 3 · Agent 65" below.
//

import SwiftUI
import SwiftData
import AppKit
import CoreText
import UniformTypeIdentifiers

// MARK: - Status Colors

func rbWritingStatusColor(_ status: WritingDocumentStatus) -> Color {
    switch status {
    case .draft: return RBColor.mutedText
    case .inProgress: return RBColor.accent
    case .review: return RBColor.warning
    case .completed: return RBColor.success
    case .archived: return RBColor.mutedText
    }
}


/// Phase 14 — color for a lifecycle stage (Papers screen).
func rbWritingStageColor(_ stage: WritingDocumentStage) -> Color {
    switch stage {
    case .draft: return RBColor.mutedText
    case .submitted, .underReview: return RBColor.warning
    case .revision: return RBColor.error
    case .accepted, .published: return RBColor.success
    }
}


// MARK: - Sort Option (Step 7)

enum WritingSortOption: String, CaseIterable, Identifiable {
    case updatedDesc = "Last Updated"
    case titleAZ = "Title A–Z"
    case createdDesc = "Newest"
    case wordCountDesc = "Word Count"

    var id: String { rawValue }
}


// MARK: - Manuscript Filters (Phase 14 — Papers screen)

/// The type chips on the Papers screen. Only three chips exist in the
/// prototype; the other document types (Thesis Chapter, Literature
/// Review, Conference Paper, Journal Paper, Custom) still show under
/// "All types".
enum ManuscriptTypeFilter: String, CaseIterable, Identifiable {
    case all = "All types"
    case researchPaper = "Research Paper"
    case thesis = "Thesis"
    case technicalReport = "Technical Report"

    var id: String { rawValue }

    func matches(_ type: WritingDocumentType) -> Bool {
        switch self {
        case .all: return true
        case .researchPaper: return type == .researchPaper
        case .thesis: return type == .thesis
        case .technicalReport: return type == .technicalReport
        }
    }
}


// MARK: - Root View (Papers)

struct WritingView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\WritingDocument.updatedAt, order: .reverse)])
    private var allDocuments: [WritingDocument]

    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]

    @Query(sort: [SortDescriptor(\ResearchIdea.updatedAt, order: .reverse)])
    private var allIdeas: [ResearchIdea]

    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]

    @Query(sort: [SortDescriptor(\Experiment.updatedAt, order: .reverse)])
    private var allExperiments: [Experiment]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Query(sort: [SortDescriptor(\ResearchNote.updatedAt, order: .reverse)])
    private var allNotes: [ResearchNote]

    @Query(sort: [SortDescriptor(\LiteratureFinding.updatedAt, order: .reverse)])
    private var allFindings: [LiteratureFinding]

    @State private var selectedDocumentID: UUID?
    @State private var selectedSectionID: UUID?

    /// true = the manuscript workspace is showing; false = the Papers list.
    @State private var showDetail = false
    @State private var showingNewSheet = false
    @State private var errorMessage: String?

    @State private var relatedGroups: [ResearchDataStore.RelatedGroup] = []

    // Search / stage tabs / type chips / sort
    @State private var searchText = ""
    @State private var stageFilter: WritingDocumentStage?          // nil = All
    @State private var typeFilter: ManuscriptTypeFilter = .all
    @State private var sortOption: WritingSortOption = .updatedDesc
    @State private var showArchived = false

    // Phase 3 (Agent 65) - LaTeX projects (real draft folders)
    @Environment(\.rbA65Library) private var rbA65Library
    @State private var rbA65Drafts: [StoredDraft] = []
    @State private var rbA65OpenDraftID: String?
    @State private var rbA65ShowingNewProject = false
    @State private var rbA65ShowingImporter = false
    @State private var rbA65IsImporting = false

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var selectedDocument: WritingDocument? {
        guard let selectedDocumentID else { return nil }
        return allDocuments.first { $0.id == selectedDocumentID }
    }

    private var archivedCount: Int {
        allDocuments.filter { $0.isArchived }.count
    }

    /// Archived manuscripts are hidden unless "Show archived" is on,
    /// because an archived document is no longer a stage of its own.
    private var filteredSortedDocuments: [WritingDocument] {
        var docs = allDocuments

        if !showArchived {
            docs = docs.filter { !$0.isArchived }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            docs = docs.filter { $0.title.lowercased().contains(query) }
        }

        if let stageFilter {
            docs = docs.filter { $0.stage == stageFilter }
        }

        docs = docs.filter { typeFilter.matches($0.documentType) }

        switch sortOption {
        case .updatedDesc:
            docs.sort { $0.updatedAt > $1.updatedAt }
        case .titleAZ:
            docs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .createdDesc:
            docs.sort { $0.createdAt > $1.createdAt }
        case .wordCountDesc:
            docs.sort { $0.totalWordCount > $1.totalWordCount }
        }

        return docs
    }

    private var hasActiveFilters: Bool {
        stageFilter != nil
            || typeFilter != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if let id = rbA65OpenDraftID, let library = rbA65Library {
                RBA65DraftWorkspace(model: library, draftID: id) {
                    rbA65OpenDraftID = nil
                    rbA65Reload()
                }
            } else if showDetail, let document = selectedDocument {
                workspace(for: document)
            } else {
                papersPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // D4: no solid fill; ContentView draws the theme gradient.
        .onAppear { consumeQuickAdd() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
        .onChange(of: selectedDocumentID) { selectedSectionID = nil }
        .task(id: showDetail ? selectedDocument?.id : nil) {
            guard showDetail, let document = selectedDocument else {
                relatedGroups = []
                return
            }

            relatedGroups = store.relatedResearch(for: document)
        }
        .onChange(of: router.pendingTarget) { _, target in
            if case .writingDocument(let id) = target {
                selectedDocumentID = id
                showDetail = true
                router.pendingTarget = nil
            }
        }
        .sheet(isPresented: $showingNewSheet) {
            WritingDocumentFormSheet(
                allProblems: allProblems,
                allIdeas: allIdeas,
                allGaps: allGaps,
                allExperiments: allExperiments
            ) { result in
                createDocument(result)
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Workspace wrapper (existing detail view, unchanged inside)

    private func workspace(for document: WritingDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showDetail = false
                } label: {
                    Label("Papers", systemImage: "chevron.left")
                        .font(RBFont.secondary(.medium))
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.accent)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider().overlay(RBColor.border)

            WritingDocumentDetailView(
                document: document,
                selectedSectionID: $selectedSectionID,
                allProblems: allProblems,
                allIdeas: allIdeas,
                allGaps: allGaps,
                allExperiments: allExperiments,
                allPapers: allPapers,
                allNotes: allNotes,
                allFindings: allFindings,
                store: store,
                onError: { errorMessage = $0 },
                onDeleted: {
                    selectedDocumentID = nil
                    selectedSectionID = nil
                    showDetail = false
                }
            )

            RelatedResearchDrawer(
                groups: relatedGroups,
                onNavigate: { router.open($0) }
            )
        }
        // Same identity trick as before, so all @State in the detail
        // view resets when a different document is opened.
        .id(document.id)
    }

    // MARK: Papers page

    private var papersPage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader

                rbA65ProjectsStrip

                if !allDocuments.isEmpty {
                    searchAndSortRow
                    stageTabs
                    typeChips

                    if archivedCount > 0 {
                        Button {
                            showArchived.toggle()
                        } label: {
                            Text(showArchived
                                 ? "Hide archived (\(archivedCount))"
                                 : "Show archived (\(archivedCount))")
                                .font(RBFont.caption(.medium))
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                        .foregroundStyle(RBColor.accent)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            if allDocuments.isEmpty {
                RB9EmptyState(
                    icon: "pencil",
                    title: "No Documents Yet",
                    message: "Turn your research into a structured paper, thesis or technical report.",
                    actionTitle: "New Document",
                    action: { showingNewSheet = true }
                )
            } else if filteredSortedDocuments.isEmpty {
                RB9InlineEmptyNote(
                    icon: "magnifyingglass",
                    title: hasActiveFilters ? "No Papers Match" : "No Papers Here",
                    message: hasActiveFilters
                        ? "Nothing matches this stage, type or search. Try another tab or clear the filters."
                        : "Archived documents are hidden. Use “Show archived” to see them."
                )
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredSortedDocuments, id: \.id) { document in
                            ManuscriptCard(document: document) {
                                selectedDocumentID = document.id
                                showDetail = true
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Papers")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("Your manuscripts, theses and reports")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
            }

            Spacer(minLength: 12)

            Button {
                showingNewSheet = true
            } label: {
                Label("New Document", systemImage: "plus")
            }
            .buttonStyle(RBPrimaryButtonStyle())
        }
    }

    private var searchAndSortRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(RBColor.mutedText)

                TextField("Search papers...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.primaryText)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RBColor.mutedText)
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 360)
            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))

            rb9SortMenu(selection: $sortOption, allCases: WritingSortOption.allCases)

            Spacer(minLength: 0)
        }
    }

    private var stageTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ManuscriptChip(title: "All", isOn: stageFilter == nil) {
                    stageFilter = nil
                }

                ForEach(WritingDocumentStage.allCases) { stage in
                    ManuscriptChip(
                        title: stage == .draft ? "Drafts" : stage.rawValue,
                        isOn: stageFilter == stage
                    ) {
                        stageFilter = stage
                    }
                }
            }
        }
    }

    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ManuscriptTypeFilter.allCases) { filter in
                    ManuscriptChip(title: filter.rawValue, isOn: typeFilter == filter) {
                        typeFilter = filter
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// Quick Add → Writing. Opens the New Document sheet and clears the
    /// request so it is handled exactly once.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .writing else { return }
        router.pendingCreate = nil
        showingNewSheet = true
    }

    private func createDocument(_ result: WritingDocumentFormResult) {
        do {
            let linkedProblems = allProblems.filter { $0.id == result.problemID }
            let linkedIdeas = allIdeas.filter { $0.id == result.ideaID }
            let linkedGaps = allGaps.filter { $0.id == result.gapID }
            let linkedExperiments = allExperiments.filter { $0.id == result.experimentID }

            let document =
                try store.createWritingDocument(
                    title: result.title,
                    documentType: result.documentType,
                    problems: linkedProblems,
                    ideas: linkedIdeas,
                    gaps: linkedGaps,
                    experiments: linkedExperiments
                )

            try store.createDefaultSections(
                for: document,
                matching: result.documentType
            )

            // Phase 14: the format chosen in the sheet. The stage is
            // left unset, so it reads as Draft from the new document's
            // status, like any other new document.
            if let format = result.format {
                document.format = format
                try modelContext.save()
            }

            selectedDocumentID = document.id
            showDetail = true

        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


// MARK: - Manuscript Chip / Card (Phase 14 — private to this file)

private struct ManuscriptChip: View {

    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(RBFont.secondary(.medium))
                .foregroundStyle(isOn ? RBColor.onAccent : RBColor.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? RBColor.accent : RBColor.card, in: Capsule())
                .overlay(Capsule().stroke(isOn ? Color.clear : RBColor.border))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: 999)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}


private struct ManuscriptCard: View {

    let document: WritingDocument
    let onOpen: () -> Void

    private var stage: WritingDocumentStage { document.stage }
    private var stageColor: Color { rbWritingStageColor(stage) }

    private var showsProgress: Bool {
        stage == .draft || stage == .revision
    }

    private var subtitle: String {
        if let format = document.format {
            return "\(document.documentType.rawValue) · \(format.rawValue)"
        }
        return document.documentType.rawValue
    }

    private var venueText: String {
        let venue = (document.venue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return venue.isEmpty ? "No venue" : venue
    }

    private var citationCount: Int { document.papers.count }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(stageColor)
                    .frame(width: 5)

                VStack(alignment: .leading, spacing: 12) {
                    titleRow
                    lifecycleBar

                    if showsProgress {
                        progressRow
                    }

                    metaRow
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RBColor.card)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.panel)
                    .stroke(RBColor.border)
            )
            .contentShape(RoundedRectangle(cornerRadius: RBRadius.panel))
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.panel, border: true)
    }

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title.isEmpty ? "Untitled Document" : document.title)
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                if document.isArchived {
                    RB9StatusPill(text: "Archived", color: RBColor.mutedText)
                }
                RB9StatusPill(text: stage.rawValue, color: stageColor)
            }
        }
    }

    /// Six segments, one per stage: earlier stages filled, the current
    /// stage in its own color, later stages empty.
    private var lifecycleBar: some View {
        let stages = WritingDocumentStage.allCases
        let current = stages.firstIndex(of: stage) ?? 0

        return HStack(spacing: 4) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, _ in
                Capsule()
                    .fill(
                        index < current
                            ? RBColor.accent.opacity(0.5)
                            : (index == current ? stageColor : RBColor.border)
                    )
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lifecycle: \(stage.rawValue)")
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(RBColor.border)
                    Capsule()
                        .fill(RBColor.accent)
                        .frame(width: proxy.size.width * CGFloat(document.progress) / 100)
                }
            }
            .frame(height: 6)

            Text("\(document.progress)% complete")
                .font(RBFont.caption(.semibold))
                .foregroundStyle(RBColor.primaryText)
                .fixedSize()
        }
    }

    private var metaRow: some View {
        let words = document.totalWordCount

        return HStack(spacing: 14) {
            Text("Updated \(document.updatedAt.formatted(date: .abbreviated, time: .omitted))")
            Text(venueText).lineLimit(1)
            Text("\(words.formatted()) word\(words == 1 ? "" : "s")")
            Text("\(citationCount) citation\(citationCount == 1 ? "" : "s")")

            Spacer(minLength: 8)

            Text("Open manuscript →")
                .font(RBFont.caption(.semibold))
                .foregroundStyle(RBColor.accent)
        }
        .font(RBFont.caption())
        .foregroundStyle(RBColor.mutedText)
        .lineLimit(1)
    }
}


// MARK: - Writing Document Form (Step 4; Phase 14 adds Format)

struct WritingDocumentFormResult {
    var title: String
    var documentType: WritingDocumentType
    var format: WritingDocumentFormat?      // nil = choose later
    var problemID: UUID?
    var ideaID: UUID?
    var gapID: UUID?
    var experimentID: UUID?
}

struct WritingDocumentFormSheet: View {

    let allProblems: [ResearchProblem]
    let allIdeas: [ResearchIdea]
    let allGaps: [ResearchGap]
    let allExperiments: [Experiment]
    let onCreate: (WritingDocumentFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var documentType: WritingDocumentType = .researchPaper
    @State private var format: WritingDocumentFormat? = nil
    @State private var problemID: UUID?
    @State private var ideaID: UUID?
    @State private var gapID: UUID?
    @State private var experimentID: UUID?

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Document")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Create") {
                    onCreate(
                        WritingDocumentFormResult(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            documentType: documentType,
                            format: format,
                            problemID: problemID,
                            ideaID: ideaID,
                            gapID: gapID,
                            experimentID: experimentID
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    RB9TextField(
                        label: "Title",
                        text: $title,
                        placeholder: "e.g. Detecting Network Intrusions with Transformers"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        RB9SectionLabel(text: "Document Type")

                        Picker("", selection: $documentType) {
                            ForEach(WritingDocumentType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        RB9SectionLabel(text: "Format")

                        Picker("", selection: $format) {
                            Text("Choose later").tag(WritingDocumentFormat?.none)
                            ForEach(WritingDocumentFormat.allCases) { option in
                                Text(option.rawValue).tag(Optional(option))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Divider().overlay(RBColor.border)

                    RB9SectionLabel(text: "Optional Initial Links")

                    Text("Attach existing research you already have — nothing is duplicated, only linked.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)

                    problemPicker
                    ideaPicker
                    gapPicker
                    experimentPicker
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 740)
        .background(RBColor.background)
    }

    // MARK: Optional Link Pickers

    private var problemPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            RB9SectionLabel(text: "Research Problem")

            if allProblems.isEmpty {
                noneAvailableNote
            } else {
                Picker("", selection: $problemID) {
                    Text("None").tag(UUID?.none)
                    ForEach(allProblems, id: \.id) { problem in
                        Text(problem.title).tag(Optional(problem.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var ideaPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            RB9SectionLabel(text: "Research Idea")

            if allIdeas.isEmpty {
                noneAvailableNote
            } else {
                Picker("", selection: $ideaID) {
                    Text("None").tag(UUID?.none)
                    ForEach(allIdeas, id: \.id) { idea in
                        Text(idea.title).tag(Optional(idea.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var gapPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            RB9SectionLabel(text: "Research Gap")

            if allGaps.isEmpty {
                noneAvailableNote
            } else {
                Picker("", selection: $gapID) {
                    Text("None").tag(UUID?.none)
                    ForEach(allGaps, id: \.id) { gap in
                        Text(gap.title).tag(Optional(gap.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var experimentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            RB9SectionLabel(text: "Experiment")

            if allExperiments.isEmpty {
                noneAvailableNote
            } else {
                Picker("", selection: $experimentID) {
                    Text("None").tag(UUID?.none)
                    ForEach(allExperiments, id: \.id) { experiment in
                        Text(experiment.name).tag(Optional(experiment.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var noneAvailableNote: some View {
        Text("None available yet")
            .font(RBFont.secondary())
            .foregroundStyle(RBColor.mutedText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }
}


// MARK: - Document Detail (Steps 5–11 container)

struct WritingDocumentDetailView: View {

    let document: WritingDocument

    @Binding var selectedSectionID: UUID?

    let allProblems: [ResearchProblem]
    let allIdeas: [ResearchIdea]
    let allGaps: [ResearchGap]
    let allExperiments: [Experiment]
    let allPapers: [PaperRecord]
    let allNotes: [ResearchNote]
    let allFindings: [LiteratureFinding]

    let store: ResearchDataStore
    let onError: (String) -> Void
    let onDeleted: () -> Void

    @State private var showingEditMetadata = false
    @State private var showingAddSection = false
    @State private var showingContextPanel = false
    @State private var sectionPendingDelete: WritingSection?
    @State private var showingDeleteDocumentConfirm = false
    @State private var showSectionDetail = false

    // Phase 14 (Agent 6) - workspace shell, UI-only, never persisted.
    // `paneWidth` is measured by the workspace GeometryReader and drives
    // the RBBreakpoint layout switches. `showInfoOverlay` is only used
    // below RBBreakpoint.infoOverlay.
    @State private var paneWidth: CGFloat = 1200
    @State private var showInfoOverlay = false

    // Phase 14 — UI-only: whether the Sections pane is shown. Separate
    // from `showSectionDetail`, which only drives the narrow stacked
    // Sections → Editor navigation. Never persisted.
    @State private var showSections = true

    // Phase 14 — plain-text export of the current document.
    @State private var showingTextExporter = false
    @State private var exportDocument = WritingPlainTextDocument(text: "")

    // Phase 14 (Agent 15) — PDF / DOCX / ODT export of the current document.
    @State private var showingFormatExporter = false
    @State private var formatExportFormat: WritingExportFormat = .pdf
    @State private var formatExportDocument = WritingBinaryExportDocument(data: Data())

    // Phase 14 (Agent 8) — manuscript toolbar. UI-only flags, never persisted.
    @State private var showingTableSheet = false
    @State private var showingEquationSheet = false
    @State private var showingFormatSheet = false
    @State private var showingExportDialog = false

    // Needed only to save `document.format` (same call the New Document
    // flow above already uses).
    @Environment(\.modelContext) private var modelContext

    private var selectedSection: WritingSection? {
        guard let selectedSectionID else { return nil }
        return document.orderedSections.first { $0.id == selectedSectionID }
    }

    /// The section editor (or placeholder). Shared by the side-by-side /
    /// stacked layout and the Sections-hidden layout.
    private var sectionEditorPane: some View {
        Group {
            if let selectedSection {
                WritingSectionEditorView(
                    section: selectedSection,
                    document: document,
                    allPapers: allPapers,
                    store: store,
                    onError: onError
                )
                .id(selectedSection.id)
            } else {
                RB9DetailPlaceholder(
                    icon: "doc.text",
                    text: document.sections.isEmpty
                        ? "No sections yet. Click “Add Section” to start writing."
                        : "Select a section to start writing."
                )
            }
        }
        // Page-style editor: the editor sits on the surface color as a
        // bordered card instead of running edge to edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.panel)
                .stroke(RBColor.border)
        )
        .padding(16)
        .background(RBColor.surface)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
                .background {
                    // Separate view from the text exporter below: two
                    // fileExporter modifiers on one view can conflict.
                    Color.clear
                        .fileExporter(
                            isPresented: $showingFormatExporter,
                            document: formatExportDocument,
                            contentType: formatExportFormat.contentType,
                            defaultFilename: "\(document.plainTextFilename).\(formatExportFormat.fileExtension)"
                        ) { result in
                            if case .failure(let error) = result,
                               (error as? CocoaError)?.code != .userCancelled {
                                onError("Couldn't export the document: \(error.localizedDescription)")
                            }
                        }
                }

            Divider().overlay(RBColor.border)

            // Phase 14 (Agent 6): outline | editor | info. The selected
            // section is never touched by hiding the outline, so showing
            // it again restores the same selection.
            GeometryReader { proxy in
                workspaceColumns(width: proxy.size.width)
                    .onChange(of: proxy.size.width, initial: true) { _, newWidth in
                        paneWidth = newWidth
                    }
            }
        }
        // D4: no solid fill; ContentView draws the theme gradient.
        .onAppear { selectFirstSectionIfNeeded() }
        .onChange(of: document.sections.count) { selectFirstSectionIfNeeded() }
        .fileExporter(
            isPresented: $showingTextExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: document.plainTextFilename
        ) { result in
            if case .failure(let error) = result,
               (error as? CocoaError)?.code != .userCancelled {
                onError("Couldn't export the document: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $showingEditMetadata) {
            WritingDocumentMetadataFormSheet(document: document) { title, type, status in
                updateMetadata(title: title, documentType: type, status: status)
            }
        }
        .sheet(isPresented: $showingAddSection) {
            WritingSectionFormSheet { title, type in
                addSection(title: title, type: type)
            }
        }
        .sheet(isPresented: $showingContextPanel) {
            WritingResearchContextView(
                document: document,
                allProblems: allProblems,
                allIdeas: allIdeas,
                allGaps: allGaps,
                allExperiments: allExperiments,
                allPapers: allPapers,
                allNotes: allNotes,
                allFindings: allFindings,
                store: store,
                onInsertText: { insertIntoSelectedSection($0) },
                onError: onError
            )
        }
        .alert(
            "Delete Section?",
            isPresented: Binding(
                get: { sectionPendingDelete != nil },
                set: { if !$0 { sectionPendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { sectionPendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let section = sectionPendingDelete {
                    deleteSection(section)
                }
                sectionPendingDelete = nil
            }
        } message: {
            Text("This removes “\(sectionPendingDelete?.title ?? "")” and its content. This can't be undone.")
        }
        .alert("Delete Document?", isPresented: $showingDeleteDocumentConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteDocument() }
        } message: {
            Text("This deletes “\(document.title)” and all of its sections. Linked research — problems, ideas, gaps, experiments, papers, notes and findings — is never deleted, only unlinked.")
        }
    }

    // MARK: Header (Step 7 — metadata, status, delete)

    private var headerTitleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(document.title)
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                statusMenu
                RB9StatusPill(text: document.documentType.rawValue, color: RBColor.mutedText)
                savedIndicator
            }

            ViewThatFits(in: .horizontal) {
                headerMetaRow
                VStack(alignment: .leading, spacing: 4) {
                    headerMetaLabels
                }
            }
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
        }
    }

    private var headerMetaRow: some View {
        HStack(spacing: 12) {
            headerMetaLabels
        }
    }

    @ViewBuilder
    private var headerMetaLabels: some View {
        Label(
            "\(document.orderedSections.count) section\(document.orderedSections.count == 1 ? "" : "s")",
            systemImage: "list.bullet"
        )
        .fixedSize()
        Label(
            "\(document.totalWordCount) word\(document.totalWordCount == 1 ? "" : "s")",
            systemImage: "textformat"
        )
        .fixedSize()
        Label(
            "Updated \(document.updatedAt.formatted(date: .abbreviated, time: .omitted))",
            systemImage: "clock"
        )
        .fixedSize()
    }

    private var headerActionButtons: some View {
        HStack(spacing: 8) {
            if isInfoOverlay {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showInfoOverlay.toggle()
                    }
                } label: {
                    Label(
                        showInfoOverlay ? "Hide Info" : "Show Info",
                        systemImage: "sidebar.right"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help(showInfoOverlay ? "Hide Info" : "Show Info")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSections.toggle()
                }
            } label: {
                Label(
                    showSections ? "Hide Sections" : "Show Sections",
                    systemImage: "sidebar.left"
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help(showSections ? "Hide Sections" : "Show Sections")

            Menu {
                Button("Export as Text") {
                    exportDocument = WritingPlainTextDocument(
                        text: document.plainTextRepresentation()
                    )
                    showingTextExporter = true
                }

                Button("Export as PDF") { exportFormatted(.pdf) }
                Button("Export as DOCX") { exportFormatted(.docx) }
                Button("Export as ODT") { exportFormatted(.odt) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Export")

            Button {
                showingContextPanel = true
            } label: {
                Label("Research Context", systemImage: "books.vertical")
                    .font(RBFont.secondary(.medium))
            }
            .buttonStyle(.bordered)

            Button("Edit") { showingEditMetadata = true }
                .buttonStyle(.bordered)

            Button(role: .destructive) {
                showingDeleteDocumentConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .fixedSize()
    }

    private var detailHeader: some View {
        // Wide: title block left, buttons right. Narrow: buttons drop
        // below the title instead of squeezing the text into slivers.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                headerTitleBlock
                Spacer(minLength: 12)
                headerActionButtons
            }

            VStack(alignment: .leading, spacing: 12) {
                headerTitleBlock
                headerActionButtons
            }
        }
        .padding(20)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(WritingDocumentStatus.allCases) { status in
                Button {
                    updateStatus(status)
                } label: {
                    if document.status == status {
                        Label(status.rawValue, systemImage: "checkmark")
                    } else {
                        Text(status.rawValue)
                    }
                }
            }
        } label: {
            RB9StatusPill(text: document.status.rawValue, color: rbWritingStatusColor(document.status))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Workspace Shell (Phase 14, Agent 6)

    private var isInfoOverlay: Bool { paneWidth < RBBreakpoint.infoOverlay }

    /// Normal width: outline | editor | info.
    /// Below RBBreakpoint.outlineStrip the outline becomes a strip above
    /// the editor. Below RBBreakpoint.infoOverlay the info panel becomes
    /// an overlay that the header's Info button shows and hides.
    private func workspaceColumns(width: CGFloat) -> some View {
        let overlay = width < RBBreakpoint.infoOverlay
        let strip = width < RBBreakpoint.outlineStrip

        return ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                if showSections && !strip {
                    sectionListPane
                        .frame(width: RBLayout.outlineWidth)

                    Divider().overlay(RBColor.border)
                }

                VStack(spacing: 0) {
                    if showSections && strip {
                        outlineStrip

                        Divider().overlay(RBColor.border)
                    }

                    sectionEditorPane

                    // Phase 14 (Agent 8): bottom manuscript toolbar.
                    if selectedSection != nil {
                        Divider().overlay(RBColor.border)

                        manuscriptToolbar
                    }
                }

                if !overlay {
                    Divider().overlay(RBColor.border)

                    infoPanel
                        .frame(width: RBLayout.infoWidth)
                }
            }

            if overlay && showInfoOverlay {
                HStack(spacing: 0) {
                    Divider().overlay(RBColor.border)

                    infoPanel
                        .frame(width: RBLayout.infoWidth)
                }
                .transition(.move(edge: .trailing))
            }
        }
        .clipped()
    }

    /// Only what the data supports: a section is "filled" when it has
    /// words. A References section is filled once papers are linked,
    /// because its text is generated from them, not typed.
    private func sectionHasContent(_ section: WritingSection) -> Bool {
        section.sectionType == .references
            ? !document.papers.isEmpty
            : section.wordCount > 0
    }

    private func sectionMarkView(_ section: WritingSection) -> some View {
        let filled = sectionHasContent(section)

        return Image(systemName: filled ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 11))
            .foregroundStyle(filled ? RBColor.success : RBColor.mutedText)
            .accessibilityLabel(filled ? "Has content" : "Empty")
    }

    /// Narrow layout: the outline as a horizontal strip. Move and Delete
    /// are in each chip's context menu, since the strip has no room for
    /// the row buttons.
    private var outlineStrip: some View {
        let sections = document.orderedSections

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    let isSelected = selectedSectionID == section.id

                    Button {
                        selectedSectionID = section.id
                    } label: {
                        HStack(spacing: 6) {
                            sectionMarkView(section)

                            Text(section.title.isEmpty ? "Untitled Section" : section.title)
                                .font(RBFont.secondary(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isSelected ? RBColor.accent : RBColor.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? RBColor.accent.opacity(0.13) : RBColor.card,
                            in: RoundedRectangle(cornerRadius: RBRadius.control)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: RBRadius.control)
                                .stroke(isSelected ? RBColor.accent.opacity(0.6) : RBColor.border)
                        )
                    }
                    .buttonStyle(.plain)
                    .rbHover(border: false)
                    .contextMenu {
                        Button("Move Earlier") { moveSection(section, direction: -1) }
                            .disabled(index == 0)
                        Button("Move Later") { moveSection(section, direction: 1) }
                            .disabled(index == sections.count - 1)

                        Divider()

                        Button("Delete Section", role: .destructive) {
                            sectionPendingDelete = section
                        }
                    }
                }

                Button {
                    showingAddSection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(7)
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.accent)
                .help("Add Section")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(RBColor.surface)
    }

    private var savedIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(RBColor.success)
                .frame(width: 6, height: 6)

            Text("Saved")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
        }
        .help("Changes are saved as you make them. Last updated \(document.updatedAt.formatted(date: .abbreviated, time: .shortened)).")
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(RBColor.mutedText)

            Spacer(minLength: 8)

            Text(value)
                .foregroundStyle(RBColor.primaryText)
                .multilineTextAlignment(.trailing)
        }
        .font(RBFont.secondary())
    }

    /// Right-hand info panel. Shows only what the document already
    /// stores: stage, progress, counts, format, venue, submission note
    /// and research links. Figures, Tables and the structure check from
    /// the prototype are not shown, because nothing tracks them yet.
    private var infoPanel: some View {
        let stages = WritingDocumentStage.allCases
        let currentIndex = stages.firstIndex(of: document.stage) ?? 0
        let stageColor = rbWritingStageColor(document.stage)
        let venue = (document.venue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (document.submissionNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 8) {
                    RB9SectionLabel(text: "Stage")

                    RB9StatusPill(text: document.stage.rawValue, color: stageColor)

                    HStack(spacing: 4) {
                        ForEach(Array(stages.enumerated()), id: \.offset) { index, _ in
                            Capsule()
                                .fill(
                                    index < currentIndex
                                        ? RBColor.accent.opacity(0.5)
                                        : (index == currentIndex ? stageColor : RBColor.border)
                                )
                                .frame(height: 4)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Lifecycle: \(document.stage.rawValue)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    RB9SectionLabel(text: "Progress")

                    HStack(spacing: 8) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(RBColor.border)
                                Capsule()
                                    .fill(RBColor.accent)
                                    .frame(width: proxy.size.width * CGFloat(document.progress) / 100)
                            }
                        }
                        .frame(height: 6)

                        Text("\(document.progress)%")
                            .font(RBFont.caption(.semibold))
                            .foregroundStyle(RBColor.primaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    RB9SectionLabel(text: "Manuscript")

                    infoRow("Words", document.totalWordCount.formatted())
                    infoRow("Sections", "\(document.sections.count)")
                    infoRow("Citations", "\(document.papers.count)")
                    infoRow("Type", document.documentType.rawValue)
                    infoRow("Format", document.format?.rawValue ?? "Not chosen yet")
                }

                VStack(alignment: .leading, spacing: 6) {
                    RB9SectionLabel(text: "Publication")

                    infoRow("Venue", venue.isEmpty ? "No venue" : venue)

                    if !note.isEmpty {
                        infoRow("Submission", note)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    RB9SectionLabel(text: "Research Links")

                    infoRow("Problems", "\(document.problems.count)")
                    infoRow("Ideas", "\(document.ideas.count)")
                    infoRow("Gaps", "\(document.gaps.count)")
                    infoRow("Experiments", "\(document.experiments.count)")
                    infoRow("Notes", "\(document.notes.count)")
                    infoRow("Findings", "\(document.findings.count)")

                    Button {
                        showingContextPanel = true
                    } label: {
                        Label("Open Research Context", systemImage: "books.vertical")
                            .font(RBFont.secondary(.medium))
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RBColor.surface)
    }

    // MARK: Manuscript Toolbar (Phase 14, Agent 8)

    private var manuscriptToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                RBSectionLabel(text: "Insert")

                RBChip(text: "Table", isSelected: false) {
                    showingTableSheet = true
                }

                RBChip(text: "Equation", isSelected: false) {
                    showingEquationSheet = true
                }

                Divider()
                    .frame(height: 16)
                    .overlay(RBColor.border)

                RBChip(
                    text: "Format · \(document.format?.rawValue ?? "Not chosen")",
                    isSelected: false
                ) {
                    showingFormatSheet = true
                }

                RBChip(text: "Export", isSelected: false) {
                    showingExportDialog = true
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(RBColor.surface)
        .sheet(isPresented: $showingTableSheet) {
            WritingTableSheet(number: nextTableNumber) { block in
                insertBlockIntoSelectedSection(block)
            }
        }
        .sheet(isPresented: $showingEquationSheet) {
            WritingEquationSheet(number: nextEquationNumber) { block in
                insertBlockIntoSelectedSection(block)
            }
        }
        .sheet(isPresented: $showingFormatSheet) {
            WritingFormatSheet(current: document.format) { format in
                applyFormat(format)
            }
        }
        .confirmationDialog(
            "Export “\(document.plainTextFilename)”",
            isPresented: $showingExportDialog,
            titleVisibility: .visible
        ) {
            Button("Export as Text") { exportPlainText() }
            Button("Export as PDF") { exportFormatted(.pdf) }
            Button("Export as DOCX") { exportFormatted(.docx) }
            Button("Export as ODT") { exportFormatted(.odt) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Counts lines like "Table 3: …" across every section, so the
    /// next inserted table gets the next number. Plain text only.
    private var nextTableNumber: Int {
        countNumberedLines(prefix: "Table ") + 1
    }

    /// Counts lines starting with "$$" (inserted equations) the same way.
    private var nextEquationNumber: Int {
        document.orderedSections
            .flatMap { $0.content.components(separatedBy: "\n") }
            .filter { $0.hasPrefix("$$") }
            .count + 1
    }

    private func countNumberedLines(prefix: String) -> Int {
        document.orderedSections
            .flatMap { $0.content.components(separatedBy: "\n") }
            .filter { line in
                line.hasPrefix(prefix)
                    && line.dropFirst(prefix.count).first?.isNumber == true
            }
            .count
    }

    /// Like `insertIntoSelectedSection`, but for multi-line blocks:
    /// puts a blank line before the block and a newline after it.
    private func insertBlockIntoSelectedSection(_ block: String) {
        guard let section = selectedSection else {
            onError("Select a section in the editor first.")
            return
        }

        let separator: String
        if section.content.isEmpty || section.content.hasSuffix("\n\n") {
            separator = ""
        } else if section.content.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }

        section.content += separator + block + "\n"

        do {
            try store.updateWritingSection(section, title: section.title, content: section.content)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func applyFormat(_ format: WritingDocumentFormat) {
        document.format = format

        do {
            try modelContext.save()
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Same plain-text export the header's Export menu uses.
    private func exportPlainText() {
        exportDocument = WritingPlainTextDocument(
            text: document.plainTextRepresentation()
        )
        showingTextExporter = true
    }

    // MARK: Section List Pane (Step 5)

    private var sectionListPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Paper Outline")
                    .font(RBFont.secondary(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button {
                    showingAddSection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(RBColor.border)

            if document.orderedSections.isEmpty {
                RB9InlineEmptyNote(
                    icon: "list.bullet",
                    title: "No Sections",
                    message: "Add a section to begin structuring this document."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(document.orderedSections.enumerated()), id: \.element.id) { index, section in
                            sectionRow(section, index: index, count: document.orderedSections.count)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(RBColor.surface)
    }

    private func sectionRow(_ section: WritingSection, index: Int, count: Int) -> some View {
        let isSelected = selectedSectionID == section.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionMarkView(section)

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title.isEmpty ? "Untitled Section" : section.title)
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(1)

                    Text("\(section.sectionType.rawValue) · \(section.wordCount)w")
                        .font(RBFont.label())
                        .foregroundStyle(RBColor.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                VStack(spacing: 2) {
                    Button {
                        moveSection(section, direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .disabled(index == 0)

                    Button {
                        moveSection(section, direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .disabled(index == count - 1)
                }
                .font(.system(size: 9))
                .foregroundStyle(RBColor.mutedText)

                Button {
                    sectionPendingDelete = section
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.error.opacity(0.8))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? RBColor.accent.opacity(0.13) : RBColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.field)
                .stroke(isSelected ? RBColor.accent.opacity(0.6) : RBColor.border)
        )
        .contentShape(Rectangle())
        .rbHover(border: false)
        .onTapGesture {
            selectedSectionID = section.id
            showSectionDetail = true
        }
    }

    // MARK: Actions

    private func selectFirstSectionIfNeeded() {
        if selectedSectionID == nil || !document.sections.contains(where: { $0.id == selectedSectionID }) {
            selectedSectionID = document.orderedSections.first?.id
        }
    }

    private func addSection(title: String, type: WritingSectionType) {
        do {
            let newSection =
                try store.createWritingSection(
                    title: title,
                    sectionType: type,
                    content: "",
                    order: document.sections.count,
                    for: document
                )
            selectedSectionID = newSection.id
            showSectionDetail = true
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func deleteSection(_ section: WritingSection) {
        do {
            try store.deleteWritingSection(section)
            if selectedSectionID == section.id {
                selectedSectionID = nil
                showSectionDetail = false
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func moveSection(_ section: WritingSection, direction: Int) {
        var ordered = document.orderedSections
        guard let currentIndex = ordered.firstIndex(where: { $0.id == section.id }) else { return }

        let targetIndex = currentIndex + direction
        guard ordered.indices.contains(targetIndex) else { return }

        ordered.swapAt(currentIndex, targetIndex)

        do {
            try store.reorderWritingSections(ordered, in: document)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func updateMetadata(
        title: String,
        documentType: WritingDocumentType,
        status: WritingDocumentStatus
    ) {
        do {
            try store.updateWritingDocument(
                document,
                title: title,
                documentType: documentType,
                status: status
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func updateStatus(_ status: WritingDocumentStatus) {
        do {
            try store.updateWritingDocument(
                document,
                title: document.title,
                documentType: document.documentType,
                status: status
            )
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Phase 14 (Agent 15) — builds the PDF/DOCX/ODT bytes for the
    /// current document, then opens the native save panel.
    private func exportFormatted(_ format: WritingExportFormat) {
        let content = WritingExportContent(document: document)

        guard let data = WritingExportBuilder.data(for: content, format: format) else {
            onError("Couldn't create the \(format.label) file.")
            return
        }

        formatExportFormat = format
        formatExportDocument = WritingBinaryExportDocument(data: data)
        showingFormatExporter = true
    }

    private func deleteDocument() {
        do {
            try store.deleteWritingDocument(document)
            onDeleted()
        } catch {
            onError(error.localizedDescription)
        }
    }

    /// Step 10/11 — inserts a plain-text reference marker (from the
    /// Research Context panel) into whichever section is currently
    /// open in the editor. Mutates the same `WritingSection` instance
    /// the editor is bound to, so the change appears immediately.
    private func insertIntoSelectedSection(_ text: String) {
        guard let section = selectedSection else {
            onError("Select a section in the editor first, then insert from Research Context.")
            return
        }

        let needsSeparator =
            !section.content.isEmpty &&
            !section.content.hasSuffix("\n") &&
            !section.content.hasSuffix(" ")

        section.content += (needsSeparator ? " " : "") + text

        do {
            try store.updateWritingSection(section, title: section.title, content: section.content)
        } catch {
            onError(error.localizedDescription)
        }
    }
}


// MARK: - Document Metadata Form (Step 7)

struct WritingDocumentMetadataFormSheet: View {

    let document: WritingDocument
    let onSave: (String, WritingDocumentType, WritingDocumentStatus) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var documentType: WritingDocumentType
    @State private var status: WritingDocumentStatus

    init(
        document: WritingDocument,
        onSave: @escaping (String, WritingDocumentType, WritingDocumentStatus) -> Void
    ) {
        self.document = document
        self.onSave = onSave
        _title = State(initialValue: document.title)
        _documentType = State(initialValue: document.documentType)
        _status = State(initialValue: document.status)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Document")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Save") {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), documentType, status)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RB9TextField(label: "Title", text: $title)

                    VStack(alignment: .leading, spacing: 6) {
                        RB9SectionLabel(text: "Document Type")
                        Picker("", selection: $documentType) {
                            ForEach(WritingDocumentType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        RB9SectionLabel(text: "Status")
                        Picker("", selection: $status) {
                            ForEach(WritingDocumentStatus.allCases) { status in
                                Text(status.rawValue).tag(status)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 460, height: 380)
        .background(RBColor.background)
    }
}


// MARK: - Add Section Form (Step 5)

struct WritingSectionFormSheet: View {

    let onCreate: (String, WritingSectionType) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var sectionType: WritingSectionType = .custom

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Section")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Add") {
                    onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), sectionType)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().overlay(RBColor.border)

            VStack(alignment: .leading, spacing: 16) {
                RB9TextField(
                    label: "Section Title",
                    text: $title,
                    placeholder: "e.g. Ablation Study"
                )

                VStack(alignment: .leading, spacing: 6) {
                    RB9SectionLabel(text: "Section Type")
                    Picker("", selection: $sectionType) {
                        ForEach(WritingSectionType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            .padding(24)
        }
        .frame(width: 420, height: 260)
        .background(RBColor.background)
    }
}


// MARK: - Section Editor (Step 6, 8, 9)

struct WritingSectionEditorView: View {

    @Bindable var section: WritingSection
    let document: WritingDocument
    let allPapers: [PaperRecord]
    let store: ResearchDataStore
    let onError: (String) -> Void

    @State private var showingPaperPicker = false
    @State private var citationStyle: CitationStyle = .apa
    @State private var isCitationsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Divider().overlay(RBColor.border)

            TextEditor(text: $section.content)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .scrollContentBackground(.hidden)
                .padding(16)
                .background(RBColor.background)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: section.content) { persistSection() }

            Divider().overlay(RBColor.border)

            citationsAndReferences
        }
        .background(RBColor.background)
        .sheet(isPresented: $showingPaperPicker) {
            PaperLinkPickerView(linkedPapers: paperBinding)
        }
    }

    // MARK: Header — title + type + word count (Step 5/6)

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Section Title", text: $section.title)
                .textFieldStyle(.plain)
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
                .onChange(of: section.title) { persistSection() }

            HStack(spacing: 10) {
                Picker("", selection: $section.sectionType) {
                    ForEach(WritingSectionType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: section.sectionType) { persistSection() }

                Text("\(section.wordCount) word\(section.wordCount == 1 ? "" : "s")")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                Spacer()
            }
        }
        .padding(16)
    }

    // MARK: Citations & References (Step 8, 9)

    private var citationsAndReferences: some View {
        DisclosureGroup("Citations & References", isExpanded: $isCitationsExpanded) {
            VStack(alignment: .leading, spacing: 14) {

                // Step 8 — cited papers, insertable into this section
                HStack {
                    RB9SectionLabel(text: "Cited Papers")
                    Spacer()
                    Button {
                        showingPaperPicker = true
                    } label: {
                        Label("Manage", systemImage: "plus")
                            .font(RBFont.caption(.medium))
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.accent)
                }

                if document.papers.isEmpty {
                    Text("No papers linked to this document yet. Click “Manage” to link some from your library.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                } else {
                    ForEach(document.papers, id: \.id) { paper in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(paper.title)
                                    .font(RBFont.secondary(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                    .lineLimit(1)
                                Text(paper.authors.isEmpty ? "Unknown authors" : paper.authors)
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Insert") { insertCitation(paper) }
                                .buttonStyle(.plain)
                                .rbHover(cornerRadius: RBRadius.field)
                                .font(RBFont.label(.medium))
                                .foregroundStyle(RBColor.accent)
                        }
                        .padding(8)
                        .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
                    }
                }

                Divider().overlay(RBColor.border)

                // Step 9 — generated references
                HStack {
                    RB9SectionLabel(text: "References")
                    Spacer()
                    Picker("", selection: $citationStyle) {
                        ForEach(CitationStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                if document.papers.isEmpty {
                    Text("References generate automatically once papers are linked above.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(
                            document.papers.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
                            id: \.id
                        ) { paper in
                            Text(CitationFormatter.citation(for: paper, style: citationStyle))
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(maxHeight: isCitationsExpanded ? 320 : nil)
        .background(RBColor.surface)
    }

    private var paperBinding: Binding<[PaperRecord]> {
        Binding(
            get: { document.papers },
            set: { newValue in
                rb9ApplyLinks(
                    newIDs: Set(newValue.map(\.id)),
                    current: document.papers,
                    all: allPapers,
                    link: { try store.linkPaperToWritingDocument($0, to: document) },
                    unlink: { try store.unlinkPaperFromWritingDocument($0, from: document) },
                    onError: onError
                )
            }
        )
    }

    private func insertCitation(_ paper: PaperRecord) {
        let marker: String =
            paper.citationKey.trimmingCharacters(in: .whitespaces).isEmpty
                ? "[\(paper.title), \(paper.year)]"
                : "[\(paper.citationKey)]"

        let needsSeparator =
            !section.content.isEmpty &&
            !section.content.hasSuffix("\n") &&
            !section.content.hasSuffix(" ")

        section.content += (needsSeparator ? " " : "") + marker
        persistSection()
    }

    private func persistSection() {
        do {
            try store.updateWritingSection(section, title: section.title, content: section.content)
        } catch {
            onError(error.localizedDescription)
        }
    }
}


// MARK: - Insert Tool Sheets (Phase 14)

private extension View {
    /// Shared look for the text fields in the tool sheets.
    func writingToolInput() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RBColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.field)
                    .stroke(RBColor.border)
            )
            .foregroundStyle(RBColor.primaryText)
    }
}

/// Insert Table. Builds a plain-text table (pipe-separated rows) and
/// hands it back; nothing is stored anywhere except the section text.
struct WritingTableSheet: View {

    let number: Int
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    // First row is the header row.
    @State private var cells: [[String]] = [
        ["Column 1", "Column 2", "Column 3"],
        ["", "", ""],
        ["", "", ""]
    ]

    private var isEmpty: Bool {
        cells.allSatisfy { row in
            row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Table")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("Inserted as plain text into the open section. It will be Table \(number).")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)

            VStack(alignment: .leading, spacing: 6) {
                RBSectionLabel(text: "Caption")

                TextField("e.g. Accuracy by client split", text: $caption)
                    .writingToolInput()
            }

            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(cells.indices, id: \.self) { row in
                        GridRow {
                            ForEach(cells[row].indices, id: \.self) { column in
                                TextField("", text: $cells[row][column])
                                    .writingToolInput()
                                    .frame(minWidth: 110)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            HStack(spacing: 8) {
                RBChip(text: "+ Row", isSelected: false) {
                    cells.append(Array(repeating: "", count: cells[0].count))
                }

                RBChip(text: "+ Column", isSelected: false) {
                    for row in cells.indices {
                        cells[row].append(row == 0 ? "Column \(cells[0].count + 1)" : "")
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Insert table") {
                    onInsert(makeBlock())
                    dismiss()
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(RBColor.background)
    }

    /// "Table 1: caption", then a pipe table with a header separator.
    private func makeBlock() -> String {
        // A "|" or a line break inside a cell would break the table.
        func clean(_ text: String) -> String {
            text
                .replacingOccurrences(of: "|", with: "/")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        let trimmedCaption = clean(caption)
        var lines: [String] = [
            trimmedCaption.isEmpty ? "Table \(number)" : "Table \(number): \(trimmedCaption)"
        ]

        for (index, row) in cells.enumerated() {
            lines.append("| " + row.map(clean).joined(separator: " | ") + " |")

            if index == 0 {
                lines.append("| " + row.map { _ in "---" }.joined(separator: " | ") + " |")
            }
        }

        return lines.joined(separator: "\n")
    }
}

/// Insert Equation. LaTeX is stored as plain text ("$$ … $$ (n)").
/// The preview shows the text as typed; it does not render LaTeX.
struct WritingEquationSheet: View {

    let number: Int
    let onInsert: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var latex = ""

    private var cleaned: String {
        latex
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Equation")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("LaTeX text, inserted into the open section. It will be numbered (\(number)).")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)

            VStack(alignment: .leading, spacing: 6) {
                RBSectionLabel(text: "LaTeX")

                TextField("e.g. E = mc^2", text: $latex)
                    .writingToolInput()
            }

            VStack(alignment: .leading, spacing: 6) {
                RBSectionLabel(text: "Preview (plain text)")

                RBCard(padding: 14) {
                    Text(cleaned.isEmpty ? "Your equation appears here." : cleaned)
                        .font(RBFont.body())
                        .foregroundStyle(
                            cleaned.isEmpty ? RBColor.mutedText : RBColor.primaryText
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            HStack {
                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Insert equation") {
                    onInsert("$$ \(cleaned) $$   (\(number))")
                    dismiss()
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(cleaned.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(RBColor.background)
    }
}

/// Change Format. Uses the document's existing `format`
/// (WritingDocumentFormat), the same value the New Document sheet and
/// the info panel already show. Text, sections and citations are not touched.
struct WritingFormatSheet: View {

    let current: WritingDocumentFormat?
    let onApply: (WritingDocumentFormat) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selected: WritingDocumentFormat?

    init(
        current: WritingDocumentFormat?,
        onApply: @escaping (WritingDocumentFormat) -> Void
    ) {
        self.current = current
        self.onApply = onApply
        _selected = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Format")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("\(current?.rawValue ?? "Not chosen yet") → \(selected?.rawValue ?? "…"). Text, figures, tables and citations stay exactly as they are.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)

            HStack(spacing: 8) {
                ForEach(WritingDocumentFormat.allCases) { option in
                    RBChip(
                        text: option.rawValue,
                        isSelected: selected == option
                    ) {
                        selected = option
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Apply format") {
                    if let selected {
                        onApply(selected)
                    }
                    dismiss()
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(selected == nil || selected == current)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(RBColor.background)
    }
}


// MARK: - Plain Text Export (Phase 14)

extension WritingDocument {


    /// Readable plain-text form of this document: title, type and
    /// status, then every section (title, blank line, content) in the
    /// researcher-defined order. No IDs, dates or UI state. Always
    /// returns a valid string, even for a document with no sections.
    func plainTextRepresentation() -> String {
        let documentTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        var blocks: [String] = [
            documentTitle.isEmpty ? "Untitled Document" : documentTitle,
            "Type: \(documentType.rawValue)\nStatus: \(status.rawValue)"
        ]

        for section in orderedSections {
            let sectionTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = section.content.trimmingCharacters(in: .whitespacesAndNewlines)

            var block = sectionTitle.isEmpty ? "Untitled Section" : sectionTitle
            if !body.isEmpty {
                block += "\n\n" + body
            }
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Suggested save name, based on the title. Characters that are
    /// invalid in file names are replaced. The `.txt` extension comes
    /// from the exporter's content type.
    var plainTextFilename: String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Document" : cleaned
    }
}

/// Minimal write-only file wrapper so `fileExporter` can save the
/// text. It holds only a String; it is not a data model.
struct WritingPlainTextDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}


// MARK: - Document Export Formats: PDF / DOCX / ODT (Phase 14, Agent 15)
//
// Document-level export of the CURRENT Writing document only — not
// related to WorkspaceExportService (workspace backup). Uses Apple
// frameworks only (CoreText/CoreGraphics for PDF) plus a tiny
// stored-ZIP writer for the two package formats (DOCX and ODT are
// both ZIP packages of XML parts). No third-party dependency.

enum WritingExportFormat: CaseIterable {
    case pdf
    case docx
    case odt

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "DOCX"
        case .odt: return "ODT"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .odt: return "odt"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf:
            return .pdf
        case .docx:
            return UTType("org.openxmlformats.wordprocessingml.document")
                ?? UTType(filenameExtension: "docx")
                ?? .data
        case .odt:
            return UTType("org.oasis-open.opendocument.text")
                ?? UTType(filenameExtension: "odt")
                ?? .data
        }
    }
}


/// Neutral, format-independent copy of what gets exported: the same
/// content as `plainTextRepresentation()` (title, type, status, then
/// sections in `orderedSections` order). No IDs, dates or UI state.
struct WritingExportContent {

    struct Section {
        let title: String
        let paragraphs: [String]   // one entry per line; "" = blank line
    }

    let title: String
    let meta: [String]
    let sections: [Section]

    init(document: WritingDocument) {
        let documentTitle = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = documentTitle.isEmpty ? "Untitled Document" : documentTitle
        meta = [
            "Type: \(document.documentType.rawValue)",
            "Status: \(document.status.rawValue)"
        ]

        sections = document.orderedSections.map { section in
            let sectionTitle = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = section.content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\t", with: "    ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return Section(
                title: sectionTitle.isEmpty ? "Untitled Section" : sectionTitle,
                paragraphs: body.isEmpty
                    ? []
                    : body.components(separatedBy: "\n")
            )
        }
    }
}


enum WritingExportBuilder {

    static func data(for content: WritingExportContent, format: WritingExportFormat) -> Data? {
        switch format {
        case .pdf: return pdfData(for: content)
        case .docx: return docxData(for: content)
        case .odt: return odtData(for: content)
        }
    }

    // MARK: PDF (CoreText, US Letter, 1" margins, multi-page)

    private static func pdfData(for content: WritingExportContent) -> Data? {

        let text = NSMutableAttributedString()
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let gray = CGColor(gray: 0.4, alpha: 1)

        func append(_ string: String, font: NSFont, gray isGray: Bool = false) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if isGray { attributes[colorKey] = gray }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        let body = NSFont.systemFont(ofSize: 11)
        let small = NSFont.systemFont(ofSize: 10)
        let heading = NSFont.boldSystemFont(ofSize: 15)
        let titleFont = NSFont.boldSystemFont(ofSize: 22)

        append(content.title + "\n", font: titleFont)
        for line in content.meta {
            append(line + "\n", font: small, gray: true)
        }

        for section in content.sections {
            append("\n", font: body)
            append(section.title + "\n", font: heading)
            for paragraph in section.paragraphs {
                append(paragraph + "\n", font: body)
            }
        }

        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 72
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageWidth - margin * 2,
            height: pageHeight - margin * 2
        )

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let info = [kCGPDFContextTitle as String: content.title] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info) else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let total = text.length
        var location = 0

        repeat {
            context.beginPDFPage(nil)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                CGPath(rect: textRect, transform: nil),
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)

            context.endPDFPage()

            // Safety: never loop forever if nothing fit on a page.
            if visible.length == 0 { break }
            location += visible.length
        } while location < total

        context.closePDF()
        return pdfData as Data
    }

    // MARK: DOCX (Office Open XML package)

    private static func docxData(for content: WritingExportContent) -> Data? {

        func paragraph(
            _ text: String,
            bold: Bool = false,
            size: Int? = nil,
            color: String? = nil,
            before: Int = 0,
            after: Int = 120
        ) -> String {
            let spacing = #"<w:pPr><w:spacing w:before="\#(before)" w:after="\#(after)"/></w:pPr>"#
            if text.isEmpty { return "<w:p>\(spacing)</w:p>" }

            var runProperties = ""
            if bold { runProperties += "<w:b/>" }
            if let color { runProperties += #"<w:color w:val="\#(color)"/>"# }
            if let size { runProperties += #"<w:sz w:val="\#(size)"/>"# }
            let rPr = runProperties.isEmpty ? "" : "<w:rPr>\(runProperties)</w:rPr>"

            return #"<w:p>\#(spacing)<w:r>\#(rPr)<w:t xml:space="preserve">\#(xmlEscaped(text))</w:t></w:r></w:p>"#
        }

        var body = paragraph(content.title, bold: true, size: 44)
        for line in content.meta {
            body += paragraph(line, size: 20, color: "666666", after: 0)
        }
        for section in content.sections {
            body += paragraph(section.title, bold: true, size: 30, before: 360)
            for text in section.paragraphs {
                body += paragraph(text)
            }
        }

        let documentXML = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\#(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """#

        let contentTypes = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """#

        let relationships = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """#

        return WritingZipWriter.archive([
            .init(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(name: "_rels/.rels", data: Data(relationships.utf8)),
            .init(name: "word/document.xml", data: Data(documentXML.utf8))
        ])
    }

    // MARK: ODT (OpenDocument package; `mimetype` must be first + stored)

    private static func odtData(for content: WritingExportContent) -> Data? {

        func paragraph(_ style: String, _ text: String) -> String {
            if text.isEmpty { return #"<text:p text:style-name="\#(style)"/>"# }
            return #"<text:p text:style-name="\#(style)">\#(odtEscaped(text))</text:p>"#
        }

        var body = paragraph("RBTitle", content.title)
        for line in content.meta {
            body += paragraph("RBMeta", line)
        }
        for section in content.sections {
            body += paragraph("RBHeading", section.title)
            for text in section.paragraphs {
                body += paragraph("RBBody", text)
            }
        }

        let contentXML = #"""
        <?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.2"><office:automatic-styles><style:style style:name="RBTitle" style:family="paragraph"><style:paragraph-properties fo:margin-bottom="0.08in"/><style:text-properties fo:font-size="22pt" fo:font-weight="bold"/></style:style><style:style style:name="RBMeta" style:family="paragraph"><style:text-properties fo:font-size="10pt" fo:color="#666666"/></style:style><style:style style:name="RBHeading" style:family="paragraph"><style:paragraph-properties fo:margin-top="0.25in" fo:margin-bottom="0.08in"/><style:text-properties fo:font-size="15pt" fo:font-weight="bold"/></style:style><style:style style:name="RBBody" style:family="paragraph"><style:paragraph-properties fo:margin-bottom="0.08in"/></style:style></office:automatic-styles><office:body><office:text>\#(body)</office:text></office:body></office:document-content>
        """#

        let manifest = #"""
        <?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """#

        return WritingZipWriter.archive([
            .init(name: "mimetype", data: Data("application/vnd.oasis.opendocument.text".utf8)),
            .init(name: "META-INF/manifest.xml", data: Data(manifest.utf8)),
            .init(name: "content.xml", data: Data(contentXML.utf8))
        ])
    }

    // MARK: XML helpers

    /// Escapes XML special characters and drops characters XML 1.0
    /// forbids (control characters; tabs/newlines were handled earlier).
    private static func xmlEscaped(_ string: String) -> String {
        var result = ""
        for scalar in string.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// ODT collapses runs of spaces, so leading/repeated spaces are
    /// written as `<text:s text:c="n"/>` to preserve them.
    private static func odtEscaped(_ string: String) -> String {
        let characters = Array(string)
        var result = ""
        var index = 0

        while index < characters.count {
            if characters[index] == " " {
                var end = index
                while end < characters.count && characters[end] == " " { end += 1 }
                var count = end - index

                if index > 0 {
                    result += " "
                    count -= 1
                }
                if count > 0 {
                    result += #"<text:s text:c="\#(count)"/>"#
                }
                index = end
            } else {
                result += xmlEscaped(String(characters[index]))
                index += 1
            }
        }
        return result
    }
}


/// Minimal ZIP writer using the "stored" (uncompressed) method,
/// which every DOCX/ODT reader accepts. Entries are written in the
/// order given, so ODT's `mimetype` can be first, as its spec requires.
enum WritingZipWriter {

    struct Entry {
        let name: String
        let data: Data
    }

    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var central = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)
            let dosDate: UInt16 = 0x0021   // 1980-01-01

            // Local file header
            output.appendLE32(0x04034b50)
            output.appendLE16(20)          // version needed
            output.appendLE16(0)           // flags
            output.appendLE16(0)           // method: stored
            output.appendLE16(0)           // time
            output.appendLE16(dosDate)
            output.appendLE32(crc)
            output.appendLE32(size)        // compressed size
            output.appendLE32(size)        // uncompressed size
            output.appendLE16(UInt16(name.count))
            output.appendLE16(0)           // extra length
            output.append(name)
            output.append(entry.data)

            // Central directory record
            central.appendLE32(0x02014b50)
            central.appendLE16(20)         // version made by
            central.appendLE16(20)         // version needed
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(0)
            central.appendLE16(dosDate)
            central.appendLE32(crc)
            central.appendLE32(size)
            central.appendLE32(size)
            central.appendLE16(UInt16(name.count))
            central.appendLE16(0)          // extra
            central.appendLE16(0)          // comment
            central.appendLE16(0)          // disk number
            central.appendLE16(0)          // internal attributes
            central.appendLE32(0)          // external attributes
            central.appendLE32(offset)
            central.append(name)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)

        // End of central directory
        output.appendLE32(0x06054b50)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(UInt16(entries.count))
        output.appendLE16(UInt16(entries.count))
        output.appendLE32(UInt32(central.count))
        output.appendLE32(centralOffset)
        output.appendLE16(0)

        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            if value & 1 == 1 {
                value = 0xEDB88320 ^ (value >> 1)
            } else {
                value = value >> 1
            }
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}


// MARK: - Phase 3 · Agent 65 — LaTeX projects (F-29 … F-33, F-36, F-37, F-39, F-40)
//
//  Owner: Agent 65 · Features: F-29, F-30, F-31, F-32, F-33, F-36, F-37, F-39, F-40
//
//  PUBLIC API (added by Agent 65, all in this file)
//    EnvironmentValues.rbA65Library: LibraryModel?
//        The open library. ContentView / ResearchBaseApp (Batch 4) must set it:
//            .environment(\.rbA65Library, libraryModel)
//        While it is nil, the "LaTeX Projects" strip is hidden and the existing
//        section-based Papers screen works exactly as before.
//
//  Everything else here is private to this file. Nothing outside this file was edited.

struct RBA65LibraryKey: EnvironmentKey {
    static var defaultValue: LibraryModel? { nil }
}

extension EnvironmentValues {
    var rbA65Library: LibraryModel? {
        get { self[RBA65LibraryKey.self] }
        set { self[RBA65LibraryKey.self] = newValue }
    }
}

private enum RBA65Sheet: String, Identifiable {
    case templates, history, comments, chapters, export
    var id: String { rawValue }
}

// MARK: Papers page: projects strip, create, import

private extension WritingView {

    func rbA65Reload() {
        guard let model = rbA65Library else {
            rbA65Drafts = []
            return
        }
        do {
            rbA65Drafts = try DraftFolderStore(model: model).all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// F-40 import: .tex / .zip / .docx becomes a new project folder.
    /// Reading the file is the slow part, so it runs in the background and the window stays usable.
    func rbA65Import(_ url: URL) {
        guard let model = rbA65Library else { return }
        guard !rbA65IsImporting else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        let store = DraftFolderStore(model: model)

        // The new project folder is made first, on the main thread (it uses the library).
        let draft: StoredDraft
        do {
            let fallbackTitle = url.deletingPathExtension().lastPathComponent
            draft = try store.create(title: fallbackTitle.isEmpty ? "Imported draft" : fallbackTitle, kind: .paper)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            return
        }

        let destination = store.folderURL(for: draft)
        rbA65IsImporting = true

        Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                rbA65IsImporting = false
            }

            do {
                // Background: read the file and write the project files.
                let result = try await Task.detached(priority: .userInitiated) {
                    try DocumentImporter().importDocument(from: url, into: destination, overwrite: true)
                }.value

                // Back on the main thread: update the library and the screen.
                if result.mainFile != draft.mainFile {
                    _ = try store.setMainFile(id: draft.id, to: result.mainFile)
                }

                let importedTitle = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !importedTitle.isEmpty {
                    _ = try store.setTitle(id: draft.id, to: importedTitle)
                }

                rbA65Reload()
                rbA65OpenDraftID = draft.id

                if !result.issues.isEmpty {
                    let lines = result.issues.prefix(5).map { "• \($0.message)" }.joined(separator: "\n")
                    errorMessage = "Imported. Please check \(result.issues.count) thing(s):\n\(lines)"
                }
            } catch {
                try? store.moveToTrash(id: draft.id)
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    var rbA65ProjectsStrip: some View {
        if let model = rbA65Library {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RB9SectionLabel(text: "LaTeX Projects")
                    Spacer()

                    Button(rbA65IsImporting ? "Importing…" : "Import…") { rbA65ShowingImporter = true }
                        .buttonStyle(.bordered)
                        .disabled(rbA65IsImporting)

                    Button {
                        rbA65ShowingNewProject = true
                    } label: {
                        Label("New LaTeX Project", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                if rbA65Drafts.isEmpty {
                    Text("Each project is a real folder (main.tex, refs.bib, figures/) that also opens in Overleaf or TeXShop.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(rbA65Drafts) { draft in
                                Button {
                                    rbA65OpenDraftID = draft.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(draft.title)
                                            .font(RBFont.secondary(.semibold))
                                            .foregroundStyle(RBColor.primaryText)
                                            .lineLimit(1)
                                        Text("\(draft.kind.rawValue.capitalized) · \(draft.stage.label)")
                                            .font(RBFont.caption())
                                            .foregroundStyle(RBColor.mutedText)
                                    }
                                    .padding(12)
                                    .frame(width: 210, alignment: .leading)
                                    .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.panel))
                                    .overlay(RoundedRectangle(cornerRadius: RBRadius.panel).stroke(RBColor.border))
                                }
                                .buttonStyle(.plain)
                                .rbHover(cornerRadius: RBRadius.panel, border: true)
                            }
                        }
                    }
                }
            }
            .onAppear { rbA65Reload() }
            .sheet(isPresented: $rbA65ShowingNewProject) {
                RBA65NewProjectSheet(model: model) { id in
                    rbA65Reload()
                    rbA65OpenDraftID = id
                }
            }
            .fileImporter(
                isPresented: $rbA65ShowingImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "tex") ?? .plainText,
                    .zip,
                    UTType(filenameExtension: "docx") ?? .data
                ]
            ) { result in
                switch result {
                case .success(let url): rbA65Import(url)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: New project sheet (F-29, F-32)

private struct RBA65NewProjectSheet: View {

    let model: LibraryModel
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind: StoredDraftKind = .paper
    @State private var templates: [StoredTemplate] = []
    @State private var templateRow = ""
    @State private var errorText: String?

    private var chosen: StoredTemplate? { templates.first { $0.rowID == templateRow } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New LaTeX Project")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            RB9TextField(label: "Title", text: $title, placeholder: "e.g. Federated Learning under Non-IID Data")

            VStack(alignment: .leading, spacing: 6) {
                RB9SectionLabel(text: "Kind")
                Picker("", selection: $kind) {
                    ForEach(StoredDraftKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                RB9SectionLabel(text: "Template")
                Picker("", selection: $templateRow) {
                    Text("None (plain article)").tag("")
                    ForEach(templates) { Text("\($0.name) \($0.version)").tag($0.rowID) }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let chosen, chosen.needsClassFile {
                    Text("This template needs its class file. Add it from the file tree after creating the project.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.warning)
                }
            }

            if let errorText {
                Text(errorText).font(RBFont.caption()).foregroundStyle(RBColor.error)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(RBColor.secondaryText)
                Button("Create") { create() }
                    .buttonStyle(RBPrimaryButtonStyle())
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(RBColor.background)
        .onAppear {
            let store = TemplateStore(model: model)
            _ = try? store.registerBuiltIns()
            templates = (try? store.latestOfEach()) ?? []
        }
    }

    private func create() {
        do {
            let draft = try DraftFolderStore(model: model).create(
                title: title,
                kind: kind,
                templateID: chosen?.key,
                templateVersion: chosen?.version,
                mainTex: chosen.flatMap { Self.mainTex(of: $0) }
            )
            onCreated(draft.id)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// The template's first .tex file when `bundlePath` is a real folder on disk;
    /// otherwise the built-in starter for that template key.
    private static func mainTex(of template: StoredTemplate) -> String? {
        let folder = URL(fileURLWithPath: template.bundlePath, isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
           let tex = names.sorted().first(where: { $0.lowercased().hasSuffix(".tex") }),
           let text = try? String(contentsOf: folder.appendingPathComponent(tex), encoding: .utf8) {
            return text
        }
        return RBA65TemplateStarters.starter(forKey: template.key)
    }
}

// MARK: Workspace (F-29 folder, F-30 editor, F-31 live citations, F-33 build + preview)

private struct RBA65DraftWorkspace: View {

    let model: LibraryModel
    let draftID: String
    let onClose: () -> Void

    @State private var draft: StoredDraft?
    @State private var filePath: String?
    @State private var treeSelection: String?
    @State private var text = ""
    @State private var savedText = ""
    @State private var reloadToken = 0
    @State private var jump: LatexEditorJump?
    @State private var editorCaret: Int?
    @State private var forward: PDFForwardRequest?

    @State private var compiler = LatexCompiler()
    @State private var building = false
    @State private var result: LatexCompiler.BuildResult?
    @State private var initialPDF: URL?
    @State private var synctex: URL?
    @State private var showPreview = true
    /// File tree visible? Toggled by the header button and ⌘⌥B.
    @State private var showTree = true
    @AppStorage("rb.latex.treeWidth") private var treeWidth: Double = 220
    @AppStorage("rb.latex.previewWidth") private var previewWidth: Double = 420
    @State private var showDiagnostics = true

    @State private var bibIssues: [BibIssue] = []
    @State private var openCounts = DraftCommentCounts()
    @State private var showSnippets = false
    @State private var sheet: RBA65Sheet?
    @State private var errorText: String?

    private var folders: DraftFolderStore { DraftFolderStore(model: model) }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(RBColor.border)

            HStack(spacing: 0) {
                if showTree {
                    FileTreeView(
                        store: folders,
                        draftID: draftID,
                        selection: $treeSelection,
                        reloadToken: reloadToken,
                        onEvent: handleTree
                    )
                    .frame(width: CGFloat(treeWidth))

                    RBA65ResizeHandle(width: $treeWidth, range: 140...420, defaultWidth: 220, direction: 1)
                }

                VStack(spacing: 0) {
                    editorArea

                    if !bibIssues.isEmpty {
                        Divider().overlay(RBColor.border)
                        bibPanel
                    }

                    if let result, showDiagnostics, !result.diagnostics.isEmpty {
                        Divider().overlay(RBColor.border)
                        diagnosticsPanel(result)
                    }
                }
                .frame(minWidth: 240, maxWidth: .infinity)

                if showPreview {
                    RBA65ResizeHandle(width: $previewWidth, range: 240...900, defaultWidth: 420, direction: -1)

                    PDFPreviewSyncView(
                        pdfURL: result?.pdfURL,
                        stalePDFURL: result?.stalePDFURL ?? initialPDF,
                        draftFolder: draft.map { folders.folderURL(for: $0) },
                        synctexExecutable: synctex,
                        forward: forward,
                        onJumpToSource: { source in
                            openFile(source.file)
                            jump = LatexEditorJump(line: source.line, column: source.column.map { $0 + 1 })
                        }
                    )
                    .frame(width: CGFloat(previewWidth))
                }
            }
        }
        // D4: no solid fill; ContentView draws the theme gradient.
        // ⌘R builds the open project (never cancels; the Build button does that).
        .background {
            Button("") { if !building { Task { await build() } } }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear(perform: load)
        .task(id: text) { await autosave() }
        .sheet(item: $sheet) { which in
            sheetContent(which)
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
        ) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    saveNow()
                    onClose()
                } label: {
                    Label("Papers", systemImage: "chevron.left")
                        .font(RBFont.secondary(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RBColor.accent)

                Text(draft?.title ?? "")
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)

                if let draft {
                    Menu(draft.stage.label) {
                        ForEach(StoredDraftStage.allCases, id: \.self) { stage in
                            Button(stage.label) { setStage(stage) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Menu(LatexCompiler.Engine(storageValue: draft.engine).displayName) {
                        ForEach(LatexCompiler.Engine.allCases) { engine in
                            Button(engine.displayName) { setEngine(engine) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text(text == savedText ? "Saved" : "Saving…")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                Spacer(minLength: 12)

                Button {
                    if building { compiler.cancel() } else { Task { await build() } }
                } label: {
                    Label(building ? "Cancel" : "Build", systemImage: building ? "stop.fill" : "hammer")
                }
                .buttonStyle(.borderedProminent)
                .help(building ? "Cancel the build" : "Build the project (⌘R)")

                if let result {
                    Text(result.ok ? "OK" : "\(result.errorCount) error\(result.errorCount == 1 ? "" : "s")")
                        .font(RBFont.caption(.semibold))
                        .foregroundStyle(result.ok ? RBColor.success : RBColor.error)
                }

                Button { withAnimation(.easeInOut(duration: 0.15)) { showTree.toggle() } } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .help(showTree ? "Hide file tree (⌘⌥B)" : "Show file tree (⌘⌥B)")

                Button { showPreview.toggle() } label: { Image(systemName: "rectangle.righthalf.inset.filled") }
                    .buttonStyle(.bordered)
                    .help(showPreview ? "Hide PDF preview" : "Show PDF preview")

                Button { showSnippets = true } label: { Label("Snippets", systemImage: "text.badge.plus") }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showSnippets) {
                        SnippetPaletteView(onInsert: insertSnippet)
                            .frame(width: 520, height: 420)
                    }

                Button { sheet = .templates } label: { Label("Templates", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)

                Button { sheet = .history } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.bordered)

                Button { sheet = .comments } label: {
                    Label(openCounts.openTotal > 0 ? "Comments (\(openCounts.openTotal))" : "Comments", systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)

                if draft?.kind == .thesis {
                    Button { sheet = .chapters } label: { Label("Chapters", systemImage: "list.number") }
                        .buttonStyle(.bordered)
                }

                Button { sheet = .export } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: Editor + panels

    @ViewBuilder
    private var editorArea: some View {
        if filePath != nil {
            LatexEditorView(
                text: $text,
                model: model,
                libraryRevision: reloadToken,
                jump: jump,
                onCaretChange: { editorCaret = $0 }
            )
        } else {
            RB9DetailPlaceholder(
                icon: "doc.text",
                text: treeSelection == nil
                    ? "Choose a file in the project tree."
                    : "This file can’t be edited here. It stays in the project folder."
            )
        }
    }

    private func diagnosticsPanel(_ build: LatexCompiler.BuildResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(build.ok ? "Build succeeded" : "Build failed")
                    .font(RBFont.secondary(.semibold))
                    .foregroundStyle(build.ok ? RBColor.success : RBColor.error)
                Text("\(build.errorCount) errors · \(build.warningCount) warnings")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                Spacer()
                Button("Hide") { showDiagnostics = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(RBColor.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(build.diagnostics) { item in
                        Button { jumpTo(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: item.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(item.severity == .error ? RBColor.error : RBColor.warning)
                                    if let place = item.location {
                                        Text(place).font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText)
                                    }
                                    Text(item.message)
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.primaryText)
                                        .multilineTextAlignment(.leading)
                                }
                                if let help = item.help {
                                    Text(help)
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.mutedText)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 160)
        }
        .background(RBColor.surface)
    }

    /// L-06: problems found in the open .bib file.
    private var bibPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(bibIssues) { issue in
                    Button {
                        if issue.line > 0 { jump = LatexEditorJump(line: issue.line) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? RBColor.error : RBColor.warning)
                            Text(issue.line > 0 ? "line \(issue.line)" : "file")
                                .font(RBFont.caption(.semibold))
                                .foregroundStyle(RBColor.mutedText)
                            Text(issue.message)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.primaryText)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 120)
        .background(RBColor.surface)
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ which: RBA65Sheet) -> some View {
        switch which {
        case .templates:
            RBA65TemplatesSheet(model: model, draft: draft) {
                reloadDraft()
                reloadFromDisk()
            }
        case .history:
            RBA65HistorySheet(model: model, draftID: draftID, currentFile: filePath) {
                reloadDraft()
                reloadFromDisk()
            }
        case .comments:
            RBA65CommentsSheet(model: model, draftID: draftID, currentFile: filePath ?? draft?.mainFile ?? "main.tex") { file, line in
                openFile(file)
                jump = LatexEditorJump(line: line)
            } onChanged: {
                refreshCounts()
            }
        case .chapters:
            RBA65ChaptersSheet(model: model, draftID: draftID) {
                reloadToken += 1
                reloadFromDisk()
            }
        case .export:
            RBA65ExportSheet(model: model, draft: draft) { reloadDraft() }
        }
    }

    // MARK: Loading and saving

    private func load() {
        do {
            guard let found = try folders.draft(id: draftID) else {
                errorText = "This project is no longer in the library."
                return
            }
            draft = found
            initialPDF = DocumentExporter.findLastBuild(
                folder: folders.folderURL(for: found),
                mainFile: found.mainFile
            )
            refreshCounts()
            // Find SyncTeX now, so jumping from the PDF works before the first build.
            var settings = LatexCompiler.Settings.stored
            settings.engine = LatexCompiler.Engine(storageValue: found.engine)
            synctex = LatexCompiler.locateInstallation(settings: settings).synctex
            openFile(found.mainFile)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reloadDraft() {
        draft = try? folders.draft(id: draftID)
    }

    /// Re-reads the open file after something else changed the folder (restore, chapter reorder).
    private func reloadFromDisk() {
        let path = filePath ?? draft?.mainFile
        savedText = text            // never write the old text back over the new file
        filePath = nil
        if let path { openFile(path) }
        reloadToken += 1
    }

    private func openFile(_ path: String) {
        saveNow()

        guard FileTreeLogic.isEditableText(path) else {
            filePath = nil
            text = ""
            savedText = ""
            treeSelection = path
            bibIssues = []
            return
        }

        do {
            let content = try folders.readText(draftID: draftID, path: path)
            filePath = path
            text = content
            savedText = content
            treeSelection = path
            refreshBib()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func autosave() async {
        guard filePath != nil, text != savedText else { return }
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        saveNow()
    }

    private func saveNow() {
        guard let path = filePath, text != savedText else { return }

        do {
            try folders.writeText(draftID: draftID, path: path, text: text)
            savedText = text

            // F-36: an automatic snapshot every 30 minutes of editing.
            _ = try? DraftHistoryStore(model: model).takeAutomaticSnapshotIfDue(draftID: draftID)

            // F-37: "% TODO" and \todo{} markers become TODO items.
            if path.hasSuffix(".tex") {
                _ = try? DraftCommentStore(model: model).addMissingTodoMarkers(draftID: draftID, file: path, text: text)
                refreshCounts()
            }

            refreshBib()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshBib() {
        guard let path = filePath, path.hasSuffix(".bib") else {
            bibIssues = []
            return
        }
        bibIssues = BibValidator.validate(text).issues
    }

    private func refreshCounts() {
        openCounts = (try? DraftCommentStore(model: model).counts(draftID: draftID)) ?? DraftCommentCounts()
    }

    // MARK: Actions

    private func handleTree(_ event: FileTreeEvent) {
        switch event {
        case .opened(let path), .added(let path):
            openFile(path)
        case .renamed(let from, let to):
            _ = try? DraftCommentStore(model: model).renameFile(draftID: draftID, from: from, to: to)
            if let current = filePath { filePath = FileTreeLogic.remap(current, from: from, to: to) }
            reloadDraft()
        case .deleted(let path):
            if let current = filePath, current == path || current.hasPrefix(path + "/") {
                filePath = nil
                text = ""
                savedText = ""
            }
        case .mainFileChanged:
            reloadDraft()
        case .imported:
            reloadToken += 1
        }
    }

    private func setStage(_ stage: StoredDraftStage) {
        do { draft = try folders.setStage(id: draftID, to: stage) }
        catch { errorText = error.localizedDescription }
    }

    private func setEngine(_ engine: LatexCompiler.Engine) {
        do { draft = try folders.setEngine(id: draftID, to: engine.storageValue) }
        catch { errorText = error.localizedDescription }
    }

    private func insertSnippet(_ snippet: LatexSnippet) {
        // Insert at the caret the editor last reported (end of file if it never reported one).
        let length = (text as NSString).length
        let at = min(editorCaret ?? length, length)
        text = snippet.insertion(into: text, selection: NSRange(location: at, length: 0)).text
        showSnippets = false
    }

    private func jumpTo(_ item: LatexCompiler.Diagnostic) {
        guard let file = item.file, let line = item.line else { return }
        openFile(file)
        jump = LatexEditorJump(line: line)
        forward = PDFForwardRequest(file: file, line: line)
    }

    private func build() async {
        guard let draft else { return }
        saveNow()
        building = true
        showDiagnostics = true

        var settings = LatexCompiler.Settings.stored
        settings.engine = LatexCompiler.Engine(storageValue: draft.engine)

        let keys = (try? LatexCitationSource.load(from: model)).map { Set($0.map(\.key)) }
        let output = await compiler.build(
            draftFolder: folders.folderURL(for: draft),
            mainFile: draft.mainFile,
            settings: settings,
            libraryCitationKeys: keys
        )

        synctex = LatexCompiler.locateInstallation(settings: settings).synctex
        result = output
        building = false
        reloadToken += 1   // the build may have written files the tree should show
    }
}

// MARK: Template starters

/// Real starting text for the six built-in templates (the bundled folders are not shipped).
enum RBA65TemplateStarters {

    static func starter(forKey key: String) -> String? {
        switch key {
        case "arxiv": return arxiv
        case "ieee": return ieee
        case "acm": return acm
        case "springer": return springer
        case "elsevier": return elsevier
        case "thesis": return thesis
        default: return nil
        }
    }

    private static let arxiv = """
    \\documentclass[11pt]{article}
    \\usepackage[utf8]{inputenc}
    \\usepackage[T1]{fontenc}
    \\usepackage{amsmath,amssymb}
    \\usepackage{graphicx}
    \\usepackage[numbers]{natbib}
    \\usepackage[colorlinks=true,allcolors=blue]{hyperref}

    \\title{Your Title Here}
    \\author{Author One \\and Author Two}
    \\date{\\today}

    \\begin{document}
    \\maketitle

    \\begin{abstract}
    Write a short summary of the problem, method and main result.
    \\end{abstract}

    \\section{Introduction}
    Start here. Cite related work with \\citep{key}.

    \\section{Method}

    \\section{Experiments}

    \\section{Conclusion}

    \\bibliographystyle{plainnat}
    \\bibliography{references}
    \\end{document}
    """

    private static let ieee = """
    \\documentclass[conference]{IEEEtran}
    \\usepackage{amsmath,amssymb}
    \\usepackage{graphicx}
    \\usepackage{cite}

    \\begin{document}
    \\title{Your Title Here}
    \\author{\\IEEEauthorblockN{Author One}
    \\IEEEauthorblockA{Department, University\\\\
    City, Country\\\\
    email@example.com}}
    \\maketitle

    \\begin{abstract}
    Write a short summary of the problem, method and main result.
    \\end{abstract}

    \\begin{IEEEkeywords}
    keyword one, keyword two
    \\end{IEEEkeywords}

    \\section{Introduction}
    Start here. Cite related work with \\cite{key}.

    \\section{Method}

    \\section{Results}

    \\section{Conclusion}

    \\bibliographystyle{IEEEtran}
    \\bibliography{references}
    \\end{document}
    """

    private static let acm = """
    \\documentclass[sigconf]{acmart}

    \\begin{document}
    \\title{Your Title Here}
    \\author{Author One}
    \\affiliation{\\institution{University}\\city{City}\\country{Country}}
    \\email{email@example.com}

    \\begin{abstract}
    Write a short summary of the problem, method and main result.
    \\end{abstract}

    \\begin{CCSXML}
    <ccs2012></ccs2012>
    \\end{CCSXML}
    \\keywords{keyword one, keyword two}

    \\maketitle

    \\section{Introduction}
    Start here. Cite related work with \\cite{key}.

    \\section{Method}

    \\section{Evaluation}

    \\section{Conclusion}

    \\bibliographystyle{ACM-Reference-Format}
    \\bibliography{references}
    \\end{document}
    """

    private static let springer = """
    % Needs llncs.cls (add it to the project from the file tree).
    \\documentclass[runningheads]{llncs}
    \\usepackage{graphicx}
    \\usepackage{amsmath,amssymb}

    \\begin{document}
    \\title{Your Title Here}
    \\author{Author One\\inst{1}}
    \\institute{University, City, Country\\\\\\email{email@example.com}}
    \\maketitle

    \\begin{abstract}
    Write a short summary of the problem, method and main result.
    \\keywords{keyword one \\and keyword two}
    \\end{abstract}

    \\section{Introduction}
    Start here. Cite related work with \\cite{key}.

    \\section{Method}

    \\section{Conclusion}

    \\bibliographystyle{splncs04}
    \\bibliography{references}
    \\end{document}
    """

    private static let elsevier = """
    \\documentclass[review,3p]{elsarticle}
    \\usepackage{amsmath,amssymb}
    \\usepackage{graphicx}
    \\usepackage{lineno}
    \\modulolinenumbers[5]

    \\journal{Journal Name}

    \\begin{document}
    \\begin{frontmatter}
    \\title{Your Title Here}
    \\author[inst1]{Author One}
    \\affiliation[inst1]{organization={University},city={City},country={Country}}

    \\begin{abstract}
    Write a short summary of the problem, method and main result.
    \\end{abstract}

    \\begin{keyword}
    keyword one \\sep keyword two
    \\end{keyword}
    \\end{frontmatter}

    \\linenumbers

    \\section{Introduction}
    Start here. Cite related work with \\cite{key}.

    \\section{Method}

    \\section{Conclusion}

    \\bibliographystyle{elsarticle-num}
    \\bibliography{references}
    \\end{document}
    """

    private static let thesis = """
    \\documentclass[12pt,a4paper,oneside]{report}
    \\usepackage[utf8]{inputenc}
    \\usepackage[T1]{fontenc}
    \\usepackage{amsmath,amssymb}
    \\usepackage{graphicx}
    \\usepackage[numbers]{natbib}
    \\usepackage[colorlinks=true,allcolors=blue]{hyperref}
    \\usepackage{setspace}
    \\onehalfspacing

    \\title{Your Thesis Title}
    \\author{Your Name}
    \\date{\\today}

    \\begin{document}
    \\maketitle

    \\begin{abstract}
    Write a short summary of the thesis.
    \\end{abstract}

    \\tableofcontents

    \\chapter{Introduction}
    Start here. Cite related work with \\citep{key}.

    \\chapter{Background}

    \\chapter{Method}

    \\chapter{Results}

    \\chapter{Conclusion}

    \\bibliographystyle{plainnat}
    \\bibliography{references}
    \\end{document}
    """
}

// MARK: Resize handle (file tree / PDF preview)

/// A thin draggable divider. Drag to resize, double-click to reset.
/// `direction` is +1 when the pane being sized is on the handle's left, -1 when on its right.
private struct RBA65ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    let direction: Double

    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? RBColor.accent.opacity(0.6) : RBColor.border)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = startWidth ?? width
                        startWidth = base
                        let proposed = base + Double(value.translation.width) * direction
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { width = defaultWidth }
            .help("Drag to resize, double-click to reset")
    }
}

// MARK: Templates (F-32, L-11)

private struct RBA65TemplatesSheet: View {

    let model: LibraryModel
    let draft: StoredDraft?
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var templates: [StoredTemplate] = []
    @State private var note: String?
    @State private var refresh = 0

    private var store: TemplateStore { TemplateStore(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Templates")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }

            if let draft {
                HStack(spacing: 8) {
                    Text("This project: \(draft.templateID.map { "\($0) \(draft.templateVersion ?? "")" } ?? "no template")")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)

                    Spacer()

                    Menu("Use template…") {
                        ForEach(templates) { template in
                            Button("\(template.name) \(template.version)") { apply(template, to: draft) }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()

                    Menu("Start main file from…") {
                        ForEach(templates) { template in
                            Button("\(template.name) \(template.version)") { startMain(from: template, in: draft) }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Replaces the main .tex file with this template's starter. A snapshot is saved first, so History can bring the old text back.")
                }

                if let key = draft.templateID,
                   let current = try? store.resolve(key: key, version: draft.templateVersion),
                   let newer = try? store.newerVersion(than: current) {
                    Text("Version \(newer.version) of this template is available. A snapshot is saved before you switch.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.warning)
                }
            }

            if let note {
                Text(note).font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
            }

            Divider().overlay(RBColor.border)

            TemplateManagerView(
                store: store,
                inUseKey: draft?.templateID,
                inUseVersion: draft?.templateVersion,
                onClose: nil,
                onChanged: { templates = (try? store.latestOfEach()) ?? []; refresh += 1 }
            )
            .id(refresh)
        }
        .padding(20)
        .frame(width: 760, height: 640)
        .background(RBColor.background)
        .onAppear { templates = (try? store.latestOfEach()) ?? [] }
    }

    /// Writes the template's starter into the main file. Snapshot first, so nothing is lost.
    private func startMain(from template: StoredTemplate, in draft: StoredDraft) {
        guard let starter = RBA65TemplateStarters.starter(forKey: template.key) else {
            note = "There is no starter text for \(template.name)."
            return
        }
        do {
            _ = try DraftHistoryStore(model: model).takeSnapshot(
                draftID: draft.id,
                label: "Before starting from \(template.name)",
                auto: true
            )
            try DraftFolderStore(model: model).writeText(draftID: draft.id, path: draft.mainFile, text: starter)
            note = "\(draft.mainFile) now starts from \(template.name). The previous text is in History."
            onApplied()
        } catch {
            note = error.localizedDescription
        }
    }

    private func apply(_ template: StoredTemplate, to draft: StoredDraft) {
        do {
            _ = try DraftHistoryStore(model: model).takeSnapshot(
                draftID: draft.id,
                label: "Before changing template",
                auto: true
            )
            _ = try DraftFolderStore(model: model).setTemplate(
                id: draft.id,
                templateID: template.key,
                templateVersion: template.version
            )
            note = "Template set to \(template.name) \(template.version). Your files were not changed; copy the new class file in yourself if it needs one."
            onApplied()
        } catch {
            note = error.localizedDescription
        }
    }
}

// MARK: History (F-36)

private struct RBA65HistorySheet: View {

    let model: LibraryModel
    let draftID: String
    let currentFile: String?
    let onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [StoredDraftSnapshot] = []
    @State private var selected: StoredDraftSnapshot?
    @State private var lines: [StoredDiffLine] = []
    @State private var label = ""
    @State private var confirmRestore = false
    @State private var message: String?

    private var store: DraftHistoryStore { DraftHistoryStore(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Draft History")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                TextField("Label (optional)", text: $label)
                    .textFieldStyle(.roundedBorder)
                Button("Save snapshot") { takeSnapshot() }
                    .buttonStyle(.borderedProminent)
            }

            if let message {
                Text(message).font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
            }

            HStack(alignment: .top, spacing: 12) {
                List(snapshots, selection: Binding(get: { selected?.id }, set: { select($0) })) { snap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.label.isEmpty ? "Automatic" : snap.label)
                            .font(RBFont.secondary(.medium))
                        Text("\(snap.createdAt.prefix(16).replacingOccurrences(of: "T", with: " ")) · \(snap.words) words")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                    }
                    .tag(snap.id)
                }
                .frame(width: 240)

                VStack(alignment: .leading, spacing: 8) {
                    if selected == nil {
                        Text("Select a snapshot to compare it with the current \(currentFile ?? "main file").")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(prefix(line) + line.text)
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(tint(line))
                                }
                            }
                        }

                        HStack {
                            Text("Red = only in the snapshot. Green = only in the current file.")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                            Spacer()
                            Button("Delete snapshot", role: .destructive) { removeSelected() }
                                .buttonStyle(.bordered)
                            Button("Restore this version") { confirmRestore = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(20)
        .frame(width: 860, height: 560)
        .background(RBColor.background)
        .onAppear(perform: reload)
        .confirmationDialog(
            "Restore this version?",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The whole project folder goes back to this snapshot. A safety snapshot of the current state is saved first.")
        }
    }

    private func prefix(_ line: StoredDiffLine) -> String {
        switch line.kind {
        case .same: return "  "
        case .removed: return "- "
        case .added: return "+ "
        }
    }

    private func tint(_ line: StoredDiffLine) -> Color {
        switch line.kind {
        case .same: return .clear
        case .removed: return RBColor.error.opacity(0.15)
        case .added: return RBColor.success.opacity(0.15)
        }
    }

    private func reload() {
        snapshots = (try? store.snapshots(forDraft: draftID)) ?? []
    }

    private func select(_ id: String?) {
        guard let id, let snap = snapshots.first(where: { $0.id == id }) else {
            selected = nil
            lines = []
            return
        }
        selected = snap
        do {
            lines = try store.diff(snapshotID: snap.id, path: currentFile)
            message = nil
        } catch {
            lines = []
            message = error.localizedDescription
        }
    }

    private func takeSnapshot() {
        do {
            _ = try store.takeSnapshot(draftID: draftID, label: label.trimmingCharacters(in: .whitespacesAndNewlines), auto: false)
            label = ""
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func removeSelected() {
        guard let selected else { return }
        do {
            try store.remove(snapshotID: selected.id)
            self.selected = nil
            lines = []
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore() {
        guard let selected else { return }
        do {
            _ = try store.restore(snapshotID: selected.id)
            onRestored()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: Comments and TODOs (F-37)

private struct RBA65CommentsSheet: View {

    let model: LibraryModel
    let draftID: String
    let currentFile: String
    let onJump: (String, Int) -> Void
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var items: [DraftComment] = []
    @State private var newBody = ""
    @State private var newLine = "1"
    @State private var newKind: DraftCommentKind = .comment
    @State private var message: String?

    private var store: DraftCommentStore { DraftCommentStore(model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Comments and TODOs")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Picker("", selection: $newKind) {
                    Text("Comment").tag(DraftCommentKind.comment)
                    Text("TODO").tag(DraftCommentKind.todo)
                }
                .labelsHidden()
                .fixedSize()

                Text("\(currentFile) line")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                TextField("1", text: $newLine)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

                TextField("What needs attention?", text: $newBody)
                    .textFieldStyle(.roundedBorder)

                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let message {
                Text(message).font(RBFont.caption()).foregroundStyle(RBColor.error)
            }

            if items.isEmpty {
                Text("Nothing unresolved.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
                Spacer(minLength: 0)
            } else {
                List(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.kind == .todo ? "checklist" : "text.bubble")
                            .foregroundStyle(item.kind == .todo ? RBColor.warning : RBColor.accent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.body).font(RBFont.secondary())
                            Text("\(item.file):\(item.line)")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                        }

                        Spacer()

                        Button("Go") { onJump(item.file, item.line); dismiss() }
                            .buttonStyle(.bordered)
                        Button("Resolve") { resolve(item) }
                            .buttonStyle(.bordered)
                        Button(role: .destructive) { remove(item) } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 520)
        .background(RBColor.background)
        .onAppear(perform: reload)
    }

    private func reload() {
        items = (try? store.unresolved(draftID: draftID)) ?? []
        onChanged()
    }

    private func add() {
        guard let line = Int(newLine.trimmingCharacters(in: .whitespaces)), line >= 1 else {
            message = "Line must be a number starting at 1."
            return
        }
        do {
            _ = try store.add(draftID: draftID, file: currentFile, line: line, kind: newKind, body: newBody.trimmingCharacters(in: .whitespacesAndNewlines))
            newBody = ""
            message = nil
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func resolve(_ item: DraftComment) {
        do { _ = try store.setResolved(id: item.id, true); reload() }
        catch { message = error.localizedDescription }
    }

    private func remove(_ item: DraftComment) {
        do { try store.remove(id: item.id); reload() }
        catch { message = error.localizedDescription }
    }
}

// MARK: Thesis chapters (F-39)

private struct RBA65ChaptersSheet: View {

    let model: LibraryModel
    let draftID: String
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var layout: ThesisLayout?
    @State private var newTitle = ""
    @State private var message: String?

    private let assembler = ThesisAssembler()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Thesis Chapters")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }

            if let layout {
                ForEach(Array(layout.issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message)
                        .font(RBFont.caption())
                        .foregroundStyle(issue.severity == .problem ? RBColor.error : RBColor.warning)
                }

                List {
                    ForEach(Array(layout.chapters.enumerated()), id: \.element.id) { index, chapter in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").foregroundStyle(RBColor.mutedText).frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title).font(RBFont.secondary(.medium))
                                Text("\(chapter.words) words\(chapter.inAppendix ? " · appendix" : "")\(chapter.exists ? "" : " · file missing")")
                                    .font(RBFont.caption())
                                    .foregroundStyle(chapter.exists ? RBColor.mutedText : RBColor.error)
                            }

                            Spacer()

                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.bordered)
                                .disabled(index == 0 || !layout.canRearrange)
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.bordered)
                                .disabled(index == layout.chapters.count - 1 || !layout.canRearrange)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("New chapter title", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                Button("Add chapter") { addChapter() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let message {
                Text(message).font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .background(RBColor.background)
        .onAppear(perform: reload)
    }

    private func location() throws -> (folder: URL, mainFile: String) {
        let loc = try ThesisAssembler.location(draftID: draftID, model: model)
        return (loc.folder, loc.mainFile)
    }

    private func reload() {
        do {
            let loc = try location()
            layout = try assembler.scan(folder: loc.folder, mainFile: loc.mainFile)
        } catch {
            message = error.localizedDescription
        }
    }

    private func move(_ index: Int, by offset: Int) {
        guard var chapters = layout?.chapters else { return }
        let target = index + offset
        guard chapters.indices.contains(target) else { return }
        chapters.swapAt(index, target)

        do {
            _ = try DraftHistoryStore(model: model).takeSnapshot(draftID: draftID, label: "Before reordering chapters", auto: true)
            let loc = try location()
            _ = try assembler.apply(
                order: chapters.map { ThesisSlot(id: $0.id, inAppendix: $0.inAppendix) },
                folder: loc.folder,
                mainFile: loc.mainFile
            )
            message = nil
            reload()
            onChanged()
        } catch {
            message = error.localizedDescription
        }
    }

    private func addChapter() {
        do {
            let loc = try location()
            let plan = try assembler.planNewChapter(title: newTitle, folder: loc.folder, mainFile: loc.mainFile)
            _ = try DraftHistoryStore(model: model).takeSnapshot(draftID: draftID, label: "Before adding a chapter", auto: true)
            _ = try assembler.commit(plan, folder: loc.folder, mainFile: loc.mainFile)
            newTitle = ""
            message = nil
            reload()
            onChanged()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: Export and citation style (F-34 name hook, F-40)

private struct RBA65ExportSheet: View {

    let model: LibraryModel
    let draft: StoredDraft?
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .latexZip
    @State private var styleID = ""
    @State private var report: ExportReport?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                RB9SectionLabel(text: "Format")
                Picker("", selection: $format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if format == .pdf {
                    Text("PDF exports the last successful build. Build the project first.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                RB9SectionLabel(text: "Citation style")
                Picker("", selection: $styleID) {
                    ForEach(CSLEngine.builtInStyles, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: styleID) { applyStyle() }

                Text("Sets the .bst name used by LaTeX. Word and Markdown exports still use the plain “Author, Year” fallback.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }

            if let report {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved to \(report.outputURL.lastPathComponent) · \(report.citedKeys.count) cited key(s)")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.success)
                    ForEach(Array(report.warnings.prefix(6).enumerated()), id: \.offset) { _, warning in
                        Text("• \(warning)").font(RBFont.caption()).foregroundStyle(RBColor.warning)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.outputURL]) }
                        .buttonStyle(.bordered)
                }
            }

            if let message {
                Text(message).font(RBFont.caption()).foregroundStyle(RBColor.error)
            }

            HStack {
                Spacer()
                Button("Export…") { export() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(RBColor.background)
        .onAppear { styleID = draft?.cslStyle ?? "" }
    }

    private func applyStyle() {
        guard let draft, !styleID.isEmpty, styleID != draft.cslStyle else { return }
        do {
            let store = DraftFolderStore(model: model)
            _ = try store.setCSLStyle(id: draft.id, to: styleID)
            _ = try store.setBibStyle(id: draft.id, to: CSLEngine.bstName(forStyleID: styleID))
            onChanged()
        } catch {
            message = error.localizedDescription
        }
    }

    private func export() {
        guard let draft else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = DocumentExporter.suggestedFileName(title: draft.title, format: format)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let exporter = DocumentExporter(citations: DocumentExporter.libraryCitations(model: model))
            report = try exporter.export(draftID: draft.id, model: model, format: format, to: url, overwrite: true)
            message = nil
        } catch {
            report = nil
            message = error.localizedDescription
        }
    }
}

// MARK: - Binary Export Document (Phase 14, Agent 15)

/// Write-only file wrapper for the binary formats above. Holds only
/// the already-built bytes; not a data model.
struct WritingBinaryExportDocument: FileDocument {

    static var readableContentTypes: [UTType] {
        WritingExportFormat.allCases.map(\.contentType)
    }
    static var writableContentTypes: [UTType] {
        WritingExportFormat.allCases.map(\.contentType)
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
