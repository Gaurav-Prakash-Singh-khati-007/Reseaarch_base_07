//
//  ReferencesView.swift
//  ResearchBase
//
//  Phase 6 — References & Citation Manager
//

import SwiftUI
import SwiftData

struct ReferencesView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(
        sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)]
    )
    private var allPapers: [PaperRecord]

    @State private var searchText = ""
    @State private var selectedType: PublicationType?
    @State private var sortOption: ReferenceSortOption = .recentlyAdded
    @State private var showOnlyIncomplete = false

    @State private var showingAddReference = false
    @State private var showingAddWithPDF = false
    @State private var showingExistingPaperPicker = false
    @State private var showingReferenceOnly = false

    @State private var editingReference: PaperRecord?

    enum ReferenceSortOption: String, CaseIterable {
        case titleAZ = "Title A–Z"
        case titleZA = "Title Z–A"
        case newest = "Newest"
        case oldest = "Oldest"
        case authorAZ = "Author A–Z"
        case recentlyAdded = "Recently Added"
        case recentlyUpdated = "Recently Updated"
    }

    // =========================================================
    // MARK: - Filtered / Sorted References
    // =========================================================

    private var filteredReferences: [PaperRecord] {

        var papers = allPapers

        if let selectedType {
            papers = papers.filter {
                $0.publicationType == selectedType
            }
        }

        if showOnlyIncomplete {
            papers = papers.filter {
                !$0.missingMetadataWarnings.isEmpty
            }
        }

        let trimmed = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if !trimmed.isEmpty {
            papers = papers.filter {
                $0.title.lowercased().contains(trimmed) ||
                $0.authors.lowercased().contains(trimmed) ||
                $0.venue.lowercased().contains(trimmed) ||
                $0.citationKey.lowercased().contains(trimmed) ||
                $0.doi.lowercased().contains(trimmed)
            }
        }

        switch sortOption {

        case .titleAZ:
            papers.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }

        case .titleZA:
            papers.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedDescending
            }

        case .newest:
            papers.sort {
                $0.year > $1.year
            }

        case .oldest:
            papers.sort {
                $0.year < $1.year
            }

        case .authorAZ:
            papers.sort {
                $0.authors.localizedCaseInsensitiveCompare($1.authors)
                    == .orderedAscending
            }

        case .recentlyAdded:
            papers.sort {
                $0.addedAt > $1.addedAt
            }

        case .recentlyUpdated:
            papers.sort {
                $0.effectiveUpdatedAt > $1.effectiveUpdatedAt
            }
        }

        return papers
    }

    private var incompleteCount: Int {
        allPapers.filter {
            !$0.missingMetadataWarnings.isEmpty
        }.count
    }

    // =========================================================
    // MARK: - Body
    // =========================================================

    var body: some View {

        VStack(spacing: 0) {

            VStack(alignment: .leading, spacing: 14) {

                header

                if !allPapers.isEmpty {
                    toolbar
                    summaryBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rbResponsiveContentPadding([.horizontal, .top])
            .padding(.bottom, 14)

            Divider()
                .overlay(RBColor.border)

            if allPapers.isEmpty {
                emptyState
            } else if filteredReferences.isEmpty {
                noResultsState
            } else {
                referencesList
            }
        }
        .background(RBColor.background)

        // -----------------------------------------------------
        // Add Reference Entry Point
        // -----------------------------------------------------

        .sheet(isPresented: $showingAddReference) {
            addReferenceChooser
        }

        // -----------------------------------------------------
        // Add with PDF → From Folder
        // -----------------------------------------------------

        .sheet(isPresented: $showingAddWithPDF) {
            AddPaperView()
        }

        // -----------------------------------------------------
        // Add with PDF → Existing Library Paper
        // -----------------------------------------------------

        .sheet(isPresented: $showingExistingPaperPicker) {
            existingLibraryPaperPicker
        }

        // -----------------------------------------------------
        // Add Reference Only
        // -----------------------------------------------------

        .sheet(isPresented: $showingReferenceOnly) {
            referenceOnlyView
        }

        // -----------------------------------------------------
        // Edit Existing Reference
        // -----------------------------------------------------

        .sheet(item: $editingReference) { paper in
            ReferenceDetailView(paper: paper)
        }
    }

    // =========================================================
    // MARK: - Header
    // =========================================================

    private var header: some View {

        RBPageHeader(
            title: "References",
            subtitle: subtitle
        ) {
            Button {
                showingAddReference = true
            } label: {
                Label("Add Reference", systemImage: "plus")
            }
            .buttonStyle(RBPrimaryButtonStyle())
        }
    }

    private var subtitle: String {

        if allPapers.isEmpty {
            return "Manage bibliographic information and citations for your library."
        }

        let isFiltering =
            selectedType != nil ||
            showOnlyIncomplete ||
            !searchText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty

        if isFiltering {
            return "Showing \(filteredReferences.count) of \(allPapers.count) references"
        }

        return allPapers.count == 1
            ? "1 reference in your library"
            : "\(allPapers.count) references in your library"
    }

    // =========================================================
    // MARK: - Add Reference Chooser
    // =========================================================

    private var addReferenceChooser: some View {

        VStack(alignment: .leading, spacing: 0) {

            HStack {

                VStack(alignment: .leading, spacing: 4) {

                    Text("Add Reference")
                        .font(RBFont.detail(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Text(
                        "Choose how you want to add this bibliographic record."
                    )
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
                }

                Spacer()

                Button("Cancel") {
                    showingAddReference = false
                }
                .buttonStyle(.borderless)
            }
            .padding(24)

            Divider()
                .overlay(RBColor.border)

            VStack(spacing: 12) {

                chooserCard(
                    icon: "doc.badge.plus",
                    title: "Add with PDF",
                    subtitle: "Add a reference that has a PDF attached.",
                    action: {
                        showingAddReference = false

                        DispatchQueue.main.async {
                            showingAddWithPDF = true
                        }
                    }
                )

                chooserCard(
                    icon: "arrow.triangle.2.circlepath",
                    title: "From Existing Library Paper",
                    subtitle: "Use an existing PaperRecord without creating a duplicate.",
                    action: {
                        showingAddReference = false

                        DispatchQueue.main.async {
                            showingExistingPaperPicker = true
                        }
                    }
                )

                chooserCard(
                    icon: "text.book.closed",
                    title: "Add Reference Only",
                    subtitle: "Create bibliographic metadata without a PDF.",
                    action: {
                        showingAddReference = false

                        DispatchQueue.main.async {
                            showingReferenceOnly = true
                        }
                    }
                )
            }
            .padding(24)

            Spacer()
        }
        .frame(width: 560, height: 410)
        .background(RBColor.background)
    }

    private func chooserCard(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {

        Button(action: action) {

            HStack(spacing: 14) {

                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(RBColor.accent)
                    .frame(width: 42, height: 42)
                    .background(
                        RBColor.accent.opacity(0.12)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: RBRadius.panel)
                    )

                VStack(alignment: .leading, spacing: 4) {

                    Text(title)
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Text(subtitle)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
            }
            .padding(14)
            .background(RBColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.panel)
                    .stroke(RBColor.border)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: RBRadius.panel)
            )
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.panel)
    }

    // =========================================================
    // MARK: - Existing Library Paper Picker

    // =========================================================
    // MARK: - Existing Library Paper Picker
    // =========================================================

    private var existingLibraryPaperPicker: some View {

        VStack(alignment: .leading, spacing: 0) {

            HStack {

                VStack(alignment: .leading, spacing: 4) {

                    Text("Select Existing Paper")
                        .font(RBFont.detail(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Text(
                        "Select a paper already in your library. No duplicate PaperRecord will be created."
                    )
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
                }

                Spacer()

                Button("Cancel") {
                    showingExistingPaperPicker = false
                }
                .buttonStyle(.borderless)
            }
            .padding(24)

            Divider()
                .overlay(RBColor.border)

            if allPapers.isEmpty {

                VStack(spacing: 10) {

                    Spacer()

                    Image(systemName: "books.vertical")
                        .font(.system(size: 34))
                        .foregroundStyle(RBColor.mutedText)

                    Text("No Library Papers")
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)

                    Text(
                        "Add a paper to your Library first."
                    )
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)

                    Spacer()
                }
                .frame(maxWidth: .infinity)

            } else {

                ScrollView {

                    LazyVStack(spacing: 8) {

                        ForEach(allPapers) { paper in

                            Button {

                                showingExistingPaperPicker = false

                                DispatchQueue.main.async {
                                    editingReference = paper
                                }

                            } label: {

                                HStack(spacing: 12) {

                                    Image(
                                        systemName:
                                            paper.pdfFilePath.isEmpty
                                            ? "doc.text"
                                            : "doc.richtext"
                                    )
                                    .foregroundStyle(
                                        paper.pdfFilePath.isEmpty
                                        ? RBColor.mutedText
                                        : RBColor.accent
                                    )
                                    .frame(width: 28)

                                    VStack(
                                        alignment: .leading,
                                        spacing: 4
                                    ) {

                                        Text(
                                            paper.title.isEmpty
                                            ? "Untitled"
                                            : paper.title
                                        )
                                        .font(RBFont.body(.medium))
                                        .foregroundStyle(
                                            RBColor.primaryText
                                        )
                                        .lineLimit(2)

                                        HStack(spacing: 8) {

                                            if !paper.authors.isEmpty {
                                                Text(paper.authors)
                                            }

                                            if paper.year > 0 {
                                                Text(
                                                    String(
                                                        paper.year
                                                    )
                                                )
                                            }

                                            Text(
                                                paper.pdfFilePath.isEmpty
                                                ? "No PDF"
                                                : "PDF available"
                                            )
                                        }
                                        .font(RBFont.caption())
                                        .foregroundStyle(
                                            RBColor.secondaryText
                                        )
                                    }

                                    Spacer()

                                    Image(
                                        systemName:
                                            "chevron.right"
                                    )
                                    .font(RBFont.label(.semibold))
                                    .foregroundStyle(
                                        RBColor.mutedText
                                    )
                                }
                                .padding(12)
                                .background(RBColor.card)
                                .overlay(
                                    RoundedRectangle(
                                        cornerRadius: RBRadius.control
                                    )
                                    .stroke(RBColor.border)
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: RBRadius.control
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .rbHover(cornerRadius: RBRadius.control)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 680, height: 620)
        .background(RBColor.background)
    }

    // =========================================================
    // MARK: - Reference Only
    // =========================================================

    private var referenceOnlyView: some View {

        ReferenceOnlyEditor(
            modelContext: modelContext,
            onCancel: {
                showingReferenceOnly = false
            },
            onCreated: { paper in
                showingReferenceOnly = false

                DispatchQueue.main.async {
                    editingReference = paper
                }
            }
        )
    }

    // =========================================================
    // MARK: - Toolbar
    // =========================================================

    private var toolbar: some View {

        ScrollView(.horizontal, showsIndicators: false) {

        HStack(spacing: 10) {

            RBSearchField(
                placeholder: "Search references...",
                text: $searchText
            )
            .frame(minWidth: 180, idealWidth: 280, maxWidth: 320)

            Menu {

                Button("All") {
                    selectedType = nil
                }

                Divider()

                ForEach(
                    PublicationType.allCases,
                    id: \.self
                ) { type in

                    Button(type.rawValue) {
                        selectedType = type
                    }
                }

            } label: {

                toolbarChip(
                    icon: "line.3.horizontal.decrease.circle",
                    text:
                        selectedType?.rawValue
                        ?? "All Types",
                    highlighted: selectedType != nil,
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by publication type")

            Menu {

                ForEach(
                    ReferenceSortOption.allCases,
                    id: \.self
                ) { option in

                    Button(option.rawValue) {
                        sortOption = option
                    }
                }

            } label: {

                toolbarChip(
                    icon: "arrow.up.arrow.down",
                    text: sortOption.rawValue,
                    showsChevron: true
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort references")

            RBChip(
                text: "Incomplete only",
                isSelected: showOnlyIncomplete
            ) {
                showOnlyIncomplete.toggle()
            }

        }
        .padding(.vertical, 2)
        }
    }

    private func toolbarChip(
        icon: String,
        text: String,
        highlighted: Bool = false,
        showsChevron: Bool = false,
        tint: Color = RBColor.accent
    ) -> some View {

        HStack(spacing: 6) {

            Image(systemName: icon)

            Text(text)
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
        }
        .font(RBFont.secondary(.medium))
        .foregroundStyle(
            highlighted
            ? tint
            : RBColor.secondaryText
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            highlighted
            ? tint.opacity(0.14)
            : RBColor.hover
        )
        .clipShape(Capsule())
    }

    // =========================================================
    // MARK: - Summary Bar
    // =========================================================

    private var summaryBar: some View {

        HStack(spacing: 14) {

            Text(
                "\(allPapers.count) Reference\(allPapers.count == 1 ? "" : "s")"
            )
            .font(RBFont.secondary(.semibold))
            .foregroundStyle(RBColor.primaryText)

            if incompleteCount > 0 {

                RBBadge(
                    text: "\(incompleteCount) of \(allPapers.count) with incomplete metadata",
                    tone: .warning
                )
            }

            Spacer(minLength: 0)
        }
    }

    // =========================================================
    // MARK: - References List
    // =========================================================

    private var referencesList: some View {

        ScrollView {

            LazyVStack(spacing: 8) {

                ForEach(filteredReferences) { paper in

                    referenceRow(paper)
                }

                if !showOnlyIncomplete && !attentionReferences.isEmpty {
                    needsAttentionSection
                }
            }
            .rbResponsiveContentPadding()
        }
    }

    // Filtered references that still have missing metadata.
    private var attentionReferences: [PaperRecord] {
        filteredReferences.filter {
            !$0.missingMetadataWarnings.isEmpty
        }
    }

    private var needsAttentionSection: some View {

        VStack(alignment: .leading, spacing: 8) {

            RBSectionLabel(text: "Needs attention · incomplete metadata")
                .padding(.top, 12)

            RBCard(padding: 0) {

                VStack(spacing: 0) {

                    attentionHeaderRow

                    ForEach(attentionReferences) { paper in

                        Divider().overlay(RBColor.border)

                        attentionRow(paper)
                    }
                }
            }
        }
    }

    private var attentionHeaderRow: some View {

        HStack(spacing: 12) {

            Text("CITATION KEY")
                .frame(width: 120, alignment: .leading)

            Text("TITLE")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("AUTHORS")
                .frame(width: 140, alignment: .leading)

            Text("YEAR")
                .frame(width: 44, alignment: .leading)

            Text("TYPE")
                .frame(width: 110, alignment: .leading)
        }
        .font(RBFont.label(.semibold))
        .foregroundStyle(RBColor.mutedText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func attentionRow(
        _ paper: PaperRecord
    ) -> some View {

        Button {
            editingReference = paper
        } label: {

            HStack(alignment: .top, spacing: 12) {

                Text(paper.citationKey.isEmpty ? "—" : paper.citationKey)
                    .foregroundStyle(RBColor.mutedText)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {

                    Text(paper.title.isEmpty ? "Untitled" : paper.title)
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(
                        paper.missingMetadataWarnings
                            .joined(separator: " · ")
                    )
                    .font(RBFont.label())
                    .foregroundStyle(RBColor.warning)
                    .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(paper.authors.isEmpty ? "—" : paper.authors)
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)

                Text(paper.year > 0 ? String(paper.year) : "—")
                    .foregroundStyle(RBColor.secondaryText)
                    .frame(width: 44, alignment: .leading)

                Text(paper.publicationType.rawValue)
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
            .font(RBFont.secondary())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rbHover()
    }

    private func referenceRow(
        _ paper: PaperRecord
    ) -> some View {

        RBRow(
            isSelected: false,
            action: {
                editingReference = paper
            }
        ) {

            HStack(
                alignment: .top,
                spacing: 12
            ) {

                VStack(
                    alignment: .leading,
                    spacing: 5
                ) {

                    Text(
                        paper.title.isEmpty
                        ? "Untitled"
                        : paper.title
                    )
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                    Text(referenceMetaLine(paper))
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(1)

                    if !paper.missingMetadataWarnings.isEmpty {

                        HStack(spacing: 4) {

                            Image(systemName: "exclamationmark.triangle")

                            Text(
                                paper.missingMetadataWarnings
                                    .joined(separator: " · ")
                            )
                            .lineLimit(1)
                        }
                        .font(RBFont.label())
                        .foregroundStyle(RBColor.warning)
                    }
                }

                Spacer(minLength: 8)

                VStack(
                    alignment: .trailing,
                    spacing: 6
                ) {

                    HStack(spacing: 6) {

                        RBBadge(
                            text: paper.publicationType.rawValue,
                            tone: .neutral
                        )

                        if paper.missingMetadataWarnings.isEmpty {
                            RBBadge(text: "✓ Complete", tone: .ok)
                        } else if paper.doi.isEmpty
                                    && paper.missingMetadataWarnings.count == 1 {
                            RBBadge(text: "⚠ No DOI", tone: .warning)
                        } else {
                            RBBadge(text: "Incomplete", tone: .warning)
                        }
                    }

                    Text(
                        paper.citationKey.isEmpty
                        ? "No key"
                        : "key: \(paper.citationKey)"
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(
                        paper.citationKey.isEmpty
                        ? RBColor.mutedText
                        : RBColor.accent
                    )
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .trailing)
                }
            }
        }
    }

    /// "Authors · Year · Venue", skipping whatever is empty.
    private func referenceMetaLine(
        _ paper: PaperRecord
    ) -> String {

        var parts: [String] = []

        if !paper.authors.isEmpty {
            parts.append(paper.authors)
        }

        if paper.year > 0 {
            parts.append(String(paper.year))
        }

        if !paper.venue.isEmpty {
            parts.append(paper.venue)
        }

        return parts.isEmpty
            ? "No authors or year"
            : parts.joined(separator: " · ")
    }

    // =========================================================
    // MARK: - Empty State
    // =========================================================

    private var emptyState: some View {

        RB9EmptyState(
            icon: "link",
            title: "No References Yet",
            message: "Add references from your research library to build a reusable citation collection.",
            actionTitle: "Add Reference",
            action: {
                showingAddReference = true
            }
        )
    }

    // =========================================================
    // MARK: - No Results State
    // =========================================================

    private var noResultsState: some View {

        VStack(spacing: 12) {

            RB9InlineEmptyNote(
                icon: "magnifyingglass",
                title: "No Matching References",
                message: "Nothing matches your search or filters."
            )

            Button("Clear Filters") {
                searchText = ""
                selectedType = nil
                showOnlyIncomplete = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}


// =============================================================
// MARK: - Reference Only Editor
// =============================================================

private struct ReferenceOnlyEditor: View {

    let modelContext: ModelContext
    let onCancel: () -> Void
    let onCreated: (PaperRecord) -> Void

    @State private var title = ""
    @State private var authors = ""
    @State private var venue = ""
    @State private var year = ""

    @State private var abstractText = ""
    @State private var doi = ""
    @State private var urlString = ""
    @State private var tagsText = ""

    @State private var citationKey = ""
    @State private var publicationType: PublicationType = .journalArticle

    @State private var publisher = ""
    @State private var volume = ""
    @State private var issue = ""
    @State private var pages = ""
    @State private var edition = ""
    @State private var month = ""

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {

            header

            Divider()
                .overlay(RBColor.border)

            ScrollView {

                VStack(
                    alignment: .leading,
                    spacing: 20
                ) {

                    section(
                        title: "Basic Information"
                    ) {

                        field(
                            title: "Title",
                            text: $title
                        )

                        HStack(spacing: 12) {

                            field(
                                title: "Authors",
                                text: $authors
                            )

                            field(
                                title: "Year",
                                text: $year
                            )
                            .frame(width: 100)
                        }

                        field(
                            title: "Venue",
                            text: $venue
                        )

                        Picker(
                            "Publication Type",
                            selection: $publicationType
                        ) {

                            ForEach(
                                PublicationType.allCases,
                                id: \.self
                            ) { type in

                                Text(type.rawValue)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .foregroundStyle(
                            RBColor.primaryText
                        )
                    }

                    section(
                        title: "Citation"
                    ) {

                        field(
                            title: "Citation Key",
                            text: $citationKey
                        )

                        field(
                            title: "DOI",
                            text: $doi
                        )

                        field(
                            title: "URL",
                            text: $urlString
                        )

                        field(
                            title: "Tags",
                            text: $tagsText
                        )
                    }

                    section(
                        title: "Publication Details"
                    ) {

                        HStack(spacing: 12) {

                            field(
                                title: "Publisher",
                                text: $publisher
                            )

                            field(
                                title: "Volume",
                                text: $volume
                            )

                            field(
                                title: "Issue",
                                text: $issue
                            )
                        }

                        HStack(spacing: 12) {

                            field(
                                title: "Pages",
                                text: $pages
                            )

                            field(
                                title: "Edition",
                                text: $edition
                            )

                            field(
                                title: "Month",
                                text: $month
                            )
                        }
                    }

                    section(
                        title: "Abstract"
                    ) {

                        TextEditor(
                            text: $abstractText
                        )
                        .font(RBFont.body())
                        .foregroundStyle(
                            RBColor.primaryText
                        )
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(RBColor.card)
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: RBRadius.control
                            )
                            .stroke(RBColor.border)
                        )
                    }

                    HStack(spacing: 8) {

                        Image(systemName: "doc.text")
                            .foregroundStyle(
                                RBColor.mutedText
                            )

                        Text(
                            "This reference will be created without a PDF. You can attach a PDF later."
                        )
                        .font(RBFont.secondary())
                        .foregroundStyle(
                            RBColor.secondaryText
                        )
                    }
                    .padding(12)
                    .background(
                        RBColor.card.opacity(0.7)
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: RBRadius.control
                        )
                    )
                }
                .padding(24)
            }

            Divider()
                .overlay(RBColor.border)

            HStack {

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.borderless)

                Button("Create Reference") {
                    createReference()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    title
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
                )
            }
            .padding(20)
        }
        .frame(width: 720, height: 720)
        .background(RBColor.background)
    }

    private var header: some View {

        HStack {

            VStack(
                alignment: .leading,
                spacing: 4
            ) {

                Text("Add Reference Only")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )

                Text(
                    "Create bibliographic metadata without importing a PDF."
                )
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.secondaryText
                )
            }

            Spacer()
        }
        .padding(24)
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 12
        ) {

            Text(title)
                .font(RBFont.body(.semibold))
                .foregroundStyle(
                    RBColor.primaryText
                )

            content()
        }
    }

    private func field(
        title: String,
        text: Binding<String>
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 5
        ) {

            Text(title)
                .font(RBFont.caption())
                .foregroundStyle(
                    RBColor.secondaryText
                )

            TextField(
                title,
                text: text
            )
            .textFieldStyle(.plain)
            .font(RBFont.body())
            .foregroundStyle(
                RBColor.primaryText
            )
            .padding(9)
            .background(RBColor.card)
            .overlay(
                RoundedRectangle(
                    cornerRadius: RBRadius.control
                )
                .stroke(RBColor.border)
            )
        }
    }

    private func createReference() {

        let cleanTitle = title
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let parsedYear = Int(
            year.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) ?? 0

        let paper = PaperRecord(
            pdfFilePath: "",
            title: cleanTitle,
            authors: authors,
            venue: venue,
            year: parsedYear,
            abstractText: abstractText,
            doi: doi,
            urlString: urlString,
            tagsText: tagsText,
            statusRawValue: "Unread",
            rating: 0,
            citationKey: citationKey,
            publicationTypeRawValue:
                publicationType.rawValue,
            publisher: publisher,
            volume: volume,
            issue: issue,
            pages: pages,
            edition: edition,
            month: month,
            updatedAt: Date()
        )

        modelContext.insert(paper)

        do {

            try modelContext.save()

            onCreated(paper)

        } catch {

            print(
                "ResearchBase: Failed to create reference-only record: \(error)"
            )
        }
    }
}
