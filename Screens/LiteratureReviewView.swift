import SwiftUI
import SwiftData
import AppKit

struct LiteratureReviewView: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter
    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    @Query(
        sort: [
            SortDescriptor(
                \LiteratureReview.updatedAt,
                order: .reverse
            )
        ]
    )
    private var reviews: [LiteratureReview]

    @State private var selectedReviewID: UUID?
    @State private var showDetail = false
    @State private var relatedGroups: [UUID: [ResearchDataStore.RelatedGroup]] = [:]
    @State private var reviewSearchText = ""
    @State private var showingNewReviewSheet = false
    @State private var showingDeleteReviewConfirmation = false

    private var filteredReviews: [LiteratureReview] {
        let query = reviewSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            return reviews
        }

        return reviews.filter { review in
            review.title.localizedCaseInsensitiveContains(query) ||
            review.descriptionText.localizedCaseInsensitiveContains(query) ||
            review.researchQuestion.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedReview: LiteratureReview? {
        guard let selectedReviewID else {
            return nil
        }

        return reviews.first {
            $0.id == selectedReviewID
        }
    }

    var body: some View {
        RBMasterDetail(
            masterMin: 220,
            masterIdeal: 260,
            showDetail: $showDetail,
            backTitle: "Reviews"
        ) {
            reviewSidebar
        } detail: {
            Group {
                if let selectedReview {
                    LiteratureReviewWorkspace(
                        review: selectedReview,
                        onDelete: {
                            deleteReview(selectedReview)
                        }
                    )
                } else {
                    literatureReviewEmptyState
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .clipped()
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(RBColor.background)
        .onAppear {
            selectInitialReviewIfNeeded()
            prepareForQuickAddFinding()
        }
        .onChange(of: reviews.count) {
            selectInitialReviewIfNeeded()
        }
        .onChange(of: router.createRequestCount) {
            prepareForQuickAddFinding()
        }
        .sheet(
            isPresented: $showingNewReviewSheet
        ) {
            NewLiteratureReviewSheet {
                title,
                description,
                question in

                createReview(
                    title: title,
                    description: description,
                    question: question
                )
            }
        }
        .confirmationDialog(
            "Delete Literature Review?",
            isPresented: $showingDeleteReviewConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "Delete Review",
                role: .destructive
            ) {
                if let selectedReview {
                    deleteReview(selectedReview)
                }
            }

            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: {
            Text(
                "The review, its themes, findings, comparison entries, and synthesis will be deleted. Your papers and PDFs will not be deleted."
            )
        }
    }

    // MARK: - Review Sidebar

    private var reviewSidebar: some View {
        VStack(spacing: 0) {

            RBListPaneHeader(
                title: "Literature Reviews",
                subtitle: RBListPaneMetrics.count(reviews.count, "review")
            ) {
                Button {
                    showingNewReviewSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("Create Literature Review")
            }

            RBSearchField(
                placeholder: "Search title, description, question…",
                text: $reviewSearchText
            )
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if reviews.isEmpty {

                RB9EmptyState(
                    icon: "books.vertical",
                    title: "No Literature Reviews",
                    message: "Create your first review to begin comparing papers.",
                    actionTitle: "Create Review",
                    action: { showingNewReviewSheet = true }
                )

            } else if filteredReviews.isEmpty {

                VStack {
                    Spacer()
                    Text("No reviews match your search.")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.mutedText)
                    Spacer()
                }
                .frame(maxWidth: .infinity)

            } else {

                RBListColumn {
                    ForEach(filteredReviews) { review in
                        RB9RowCard(
                            isSelected: selectedReviewID == review.id,
                            action: {
                                selectedReviewID = review.id
                                showDetail = true
                            }
                        ) {
                            ReviewSidebarRow(
                                review: review
                            )
                        }
                        .contextMenu {
                            Button(
                                role: .destructive
                            ) {
                                selectedReviewID = review.id
                                showingDeleteReviewConfirmation = true
                            } label: {
                                Label(
                                    "Delete Review",
                                    systemImage: "trash"
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(
            minWidth: 220,
            idealWidth: 260,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .rbListPaneBackground()
    }

    // MARK: - Empty State

    private var literatureReviewEmptyState: some View {
        VStack(spacing: 16) {

            Image(
                systemName: "books.vertical"
            )
            .font(
                .system(size: 48)
            )
            .foregroundStyle(RBColor.secondaryText)

            Text("Literature Review")
                .font(RBFont.detail(.semibold))

            Text(
                reviews.isEmpty
                ? "Create a literature review to organize papers, themes, findings, comparisons, and synthesis."
                : "Select a literature review from the sidebar."
            )
            .foregroundStyle(RBColor.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            if reviews.isEmpty {
                Button("Create Literature Review") {
                    showingNewReviewSheet = true
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .padding(40)
    }

    // MARK: - Selection

    private func selectInitialReviewIfNeeded() {
        if let selectedReviewID,
           reviews.contains(
                where: {
                    $0.id == selectedReviewID
                }
           ) {
            return
        }

        selectedReviewID = reviews.first?.id
    }

    // MARK: - Quick Add (Phase 14)

    /// Quick Add → Finding. A finding always belongs to a review and is
    /// created by `FindingsSection.createFinding()`, which consumes the
    /// request itself. This only makes sure that section can be
    /// reached. With no reviews there is nothing to attach a finding
    /// to, so the existing New Review sheet opens instead and the
    /// request is cleared here.
    private func prepareForQuickAddFinding() {
        guard router.pendingCreate == .finding else { return }

        if reviews.isEmpty {
            router.pendingCreate = nil
            showingNewReviewSheet = true
            return
        }

        selectInitialReviewIfNeeded()
        // Reveal the workspace when stacked (no-op when wide).
        showDetail = true
    }

    // MARK: - Persistence

    private func createReview(
        title: String,
        description: String,
        question: String
    ) {
        let trimmedTitle = title
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let review = LiteratureReview(
            title: trimmedTitle.isEmpty
                ? "Untitled Literature Review"
                : trimmedTitle,
            descriptionText: description
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
            researchQuestion: question
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        )

        modelContext.insert(review)

        do {
            try modelContext.save()
            selectedReviewID = review.id
            showDetail = true
        } catch {
            print(
                "ResearchBase: Failed to create literature review: \(error)"
            )
        }
    }

    private func deleteReview(
        _ review: LiteratureReview
    ) {
        let wasSelected =
            selectedReviewID == review.id

        modelContext.delete(review)

        do {
            try modelContext.save()

            if wasSelected {
                selectedReviewID = nil
                showDetail = false

                DispatchQueue.main.async {
                    selectedReviewID = reviews.first?.id
                }
            }
        } catch {
            print(
                "ResearchBase: Failed to delete literature review: \(error)"
            )
        }
    }
}

// MARK: - Small Helpers

/// "1 paper" / "3 papers". Used for the count lines in this file.
private func reviewCount(_ count: Int, _ singular: String) -> String {
    "\(count) \(singular)\(count == 1 ? "" : "s")"
}

// MARK: - Sidebar Row

private struct ReviewSidebarRow: View {

    let review: LiteratureReview

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 5
        ) {
            Text(
                review.title.isEmpty
                ? "Untitled Review"
                : review.title
            )
            .font(RBFont.body(.semibold))
            .lineLimit(2)

            // One line like the HTML: counts and the last-updated date
            Text(
                [
                    reviewCount(review.papers.count, "paper"),
                    reviewCount(review.themes.count, "theme"),
                    reviewCount(review.findings.count, "finding"),
                    review.updatedAt.formatted(
                        .dateTime.day().month(.abbreviated).year()
                    )
                ].joined(separator: " · ")
            )
            .font(RBFont.caption())
            .foregroundStyle(RBColor.secondaryText)
            .lineLimit(2)
        }
    }
}

// MARK: - Workspace

private struct LiteratureReviewWorkspace: View {

    @EnvironmentObject private var router: NavigationRouter

    @Bindable var review: LiteratureReview

    let onDelete: () -> Void

    @State private var selectedSection: ReviewSection = .overview
    @State private var showingPaperPicker = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {

            header

            sectionPicker

            ScrollView {
                sectionContent
                    .padding(.horizontal, RBLayout.pageSide)
                    .padding(.top, 12)
                    .padding(.bottom, RBLayout.pageBottom)
                    .frame(
                        maxWidth: 1100,
                        alignment: .top
                    )
                    .frame(maxWidth: .infinity)
            }
        }
        .background(RBColor.background)
        // Phase 14 — Quick Add → Finding: show the Findings section.
        // FindingsSection consumes the request and clears it.
        .onAppear {
            if router.pendingCreate == .finding {
                selectedSection = .findings
            }
        }
        .onChange(of: router.createRequestCount) {
            if router.pendingCreate == .finding {
                selectedSection = .findings
            }
        }
        .sheet(
            isPresented: $showingPaperPicker
        ) {
            LiteratureReviewPaperPicker(
                review: review
            )
        }
        .confirmationDialog(
            "Delete Literature Review?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "Delete Review",
                role: .destructive
            ) {
                onDelete()
            }

            Button(
                "Cancel",
                role: .cancel
            ) {}
        } message: {
            Text(
                "The review and its review-specific material will be deleted. Papers, PDFs, notes, and annotations will remain."
            )
        }
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            narrowHeader
        }
        .padding(.horizontal, RBLayout.pageSide)
        .padding(.top, RBLayout.pageTop)
        .padding(.bottom, 8)
        .clipped()
    }

    private var titleText: some View {
        Text(
            review.title.isEmpty
            ? "Untitled Literature Review"
            : review.title
        )
        .font(RBFont.detail(.semibold))
        .lineLimit(2)
    }

    // One line of counts, like the HTML: "3 papers · 2 themes · ..."
    private var statLine: some View {
        Text(
            [
                reviewCount(review.papers.count, "paper"),
                reviewCount(review.themes.count, "theme"),
                reviewCount(review.findings.count, "finding"),
                reviewCount(review.comparisonEntries.count, "comparison")
            ].joined(separator: " · ")
        )
    }

    private var headerActions: some View {
        HStack(spacing: 14) {
            Button {
                showingPaperPicker = true
            } label: {
                Label(
                    "Add Papers",
                    systemImage: "plus"
                )
            }
            .buttonStyle(RBPrimaryButtonStyle())

            Menu {
                Button {
                    selectedSection = .overview
                } label: {
                    Label(
                        "Overview",
                        systemImage: ReviewSection.overview.icon
                    )
                }

                Divider()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(
                        "Delete Review",
                        systemImage: "trash"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            // Kit hover for the "..." menu
            .rbHover()
        }
    }

    private var wideHeader: some View {
        HStack(spacing: 14) {
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                titleText

                statLine
                    .font(RBFont.secondary(.regular))
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            headerActions
        }
    }

    private var narrowHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleText

            // Wraps onto two lines when the window is narrow
            statLine
                .font(RBFont.secondary(.regular))
                .foregroundStyle(RBColor.secondaryText)
                .lineLimit(2)

            HStack {
                Spacer()
                headerActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Section Picker

    private var sectionPicker: some View {
        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {
            HStack(spacing: 4) {

                ForEach(
                    ReviewSection.allCases
                ) { section in

                    // Kit chip: it already has hover and the selected look
                    RBChip(
                        text: section.rawValue,
                        isSelected: selectedSection == section,
                        action: {
                            selectedSection = section
                        }
                    )
                }
            }
            .padding(.horizontal, RBLayout.pageSide)
            .padding(.vertical, 8)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {

        case .overview:
            OverviewSection(
                review: review
            )

        case .papers:
            PapersSection(
                review: review
            )

        case .themes:
            ThemesSection(
                review: review
            )

        case .findings:
            FindingsSection(
                review: review
            )

        case .comparison:
            ComparisonSection(
                review: review
            )

        case .synthesis:
            SynthesisSection(
                review: review
            )
        }
    }
}

// MARK: - Review Sections

private enum ReviewSection:
    String,
    CaseIterable,
    Identifiable {

    case overview = "Overview"
    case papers = "Papers"
    case themes = "Themes"
    case findings = "Findings"
    case comparison = "Comparison"
    case synthesis = "Synthesis"

    var id: String {
        rawValue
    }

    var icon: String {
        switch self {

        case .overview:
            return "rectangle.grid.2x2"

        case .papers:
            return "doc.text"

        case .themes:
            return "tag"

        case .findings:
            return "lightbulb"

        case .comparison:
            return "rectangle.split.3x1"

        case .synthesis:
            return "text.alignleft"
        }
    }
}

// MARK: - Overview

private struct OverviewSection: View {

    @Environment(\.modelContext) private var modelContext

    @Bindable var review: LiteratureReview

    @State private var savedMessage = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 22
        ) {

            VStack(
                alignment: .leading,
                spacing: 18
            ) {

                FormField("Title") {
                    TextField(
                        "Literature review title",
                        text: $review.title
                    )
                    .textFieldStyle(.roundedBorder)
                }

                FormField("Research Question") {
                    TextEditor(
                        text: $review.researchQuestion
                    )
.rbTextEditorStyle(minHeight: 90)

                    Text(
                        "A good question is specific, answerable from the literature, and names what you compare."
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                }

                FormField("Description") {
                    TextEditor(
                        text: $review.descriptionText
                    )
.rbTextEditorStyle(minHeight: 140)
                }

                HStack {

                    Button {
                        save()
                    } label: {
                        Label(
                            "Save",
                            systemImage: "checkmark"
                        )
                    }
                    .buttonStyle(RBPrimaryButtonStyle())

                    if savedMessage {
                        Label(
                            "Saved",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                    }

                    Spacer()
                }
            }

            // Stat tiles. They wrap onto more rows when the window is narrow.
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 140),
                        spacing: 14
                    )
                ],
                spacing: 14
            ) {

                OverviewMetricCard(
                    title: "Papers",
                    value: "\(review.papers.count)",
                    icon: "doc.text"
                )

                OverviewMetricCard(
                    title: "Themes",
                    value: "\(review.themes.count)",
                    icon: "tag"
                )

                OverviewMetricCard(
                    title: "Findings",
                    value: "\(review.findings.count)",
                    icon: "lightbulb"
                )

                OverviewMetricCard(
                    title: "Comparison",
                    value: "\(review.comparisonEntries.count)",
                    icon: "rectangle.split.3x1"
                )
            }

            // Created / Updated, side by side like the HTML
            HStack(
                alignment: .top,
                spacing: 40
            ) {
                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    RBSectionLabel(text: "Created")

                    Text(
                        review.createdAt.formatted(
                            .dateTime.day().month(.abbreviated).year()
                        )
                    )
                    .font(RBFont.body(.regular))
                }

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    RBSectionLabel(text: "Updated")

                    Text(
                        review.updatedAt.formatted(
                            .dateTime.day().month(.abbreviated).year()
                        )
                    )
                    .font(RBFont.body(.regular))
                }
            }
        }
    }

    private func save() {
        review.updatedAt = Date()

        do {
            try modelContext.save()

            savedMessage = true

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.5
            ) {
                savedMessage = false
            }

        } catch {
            print(
                "ResearchBase: Failed to save literature review: \(error)"
            )
        }
    }
}

// MARK: - Papers

private struct PapersSection: View {

    @Environment(\.modelContext) private var modelContext

    let review: LiteratureReview

    @State private var searchText = ""
    @State private var publicationFilter = "All"
    @State private var sortOption: LiteratureReviewPaperSortOption = .title
    @State private var showingPaperPicker = false

    private var publicationTypes: [String] {
        let values = Set(
            review.papers.map {
                $0.publicationType.rawValue
            }
        )

        return ["All"] +
            values
                .filter {
                    !$0.isEmpty &&
                    $0 != "All"
                }
                .sorted()
    }

    private func matchesSearch(
        _ paper: PaperRecord
    ) -> Bool {

        let query = searchText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        if query.isEmpty {
            return true
        }

        return paper.title.localizedCaseInsensitiveContains(query) ||
            paper.authors.localizedCaseInsensitiveContains(query) ||
            paper.venue.localizedCaseInsensitiveContains(query) ||
            paper.citationKey.localizedCaseInsensitiveContains(query)
    }

    private func matchesPublicationType(
        _ paper: PaperRecord
    ) -> Bool {

        if publicationFilter == "All" {
            return true
        }

        return paper.publicationType.rawValue ==
            publicationFilter
    }

    private var filteredPapers: [PaperRecord] {

        let candidates =
            review.papers.filter { paper in
                matchesSearch(paper) &&
                matchesPublicationType(paper)
            }

        switch sortOption {

        case .title:
            return candidates.sorted {
                $0.title.localizedCaseInsensitiveCompare(
                    $1.title
                ) == .orderedAscending
            }

        case .yearNewest:
            return candidates.sorted {
                $0.year > $1.year
            }

        case .yearOldest:
            return candidates.sorted {
                $0.year < $1.year
            }

        case .recentlyUpdated:
            return candidates.sorted {
                $0.effectiveUpdatedAt >
                    $1.effectiveUpdatedAt
            }
        }
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {

            HStack {

                SectionHeader(
                    title: "Papers",
                    subtitle: "Manage the papers included in this literature review."
                )

                Spacer()

                Button {
                    showingPaperPicker = true
                } label: {
                    Label(
                        "Add Papers",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {

                HStack(spacing: 7) {
                    Image(
                        systemName: "magnifyingglass"
                    )
                    .foregroundStyle(RBColor.secondaryText)

                    TextField(
                        "Search title, author, venue, citation key",
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                }
                .padding(9)
                .background(RBColor.background)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: RBRadius.field
                    )
                )

                Picker(
                    "Publication Type",
                    selection: $publicationFilter
                ) {
                    ForEach(
                        publicationTypes,
                        id: \.self
                    ) { type in
                        Text(type)
                            .tag(type)
                    }
                }
                .controlSize(.regular)

                Picker(
                    "Sort",
                    selection: $sortOption
                ) {
                    ForEach(
                        LiteratureReviewPaperSortOption.allCases
                    ) { option in
                        Text(option.rawValue)
                            .tag(option)
                    }
                }
                .controlSize(.regular)
            }

            if filteredPapers.isEmpty {

                EmptySectionCard(
                    icon: "doc.text",
                    title: review.papers.isEmpty
                        ? "No Papers Added"
                        : "No Matching Papers",
                    message: review.papers.isEmpty
                        ? "Add existing papers from your ResearchBase library."
                        : "Try a different search or filter."
                )

            } else {

                VStack(spacing: 0) {

                    ForEach(
                        filteredPapers
                    ) { paper in

                        LiteratureReviewPaperRow(
                            paper: paper,
                            removeAction: {
                                removePaper(paper)
                            }
                        )

                        if paper.id !=
                            filteredPapers.last?.id {
                            Divider()
                        }
                    }
                }
                .background(RBColor.card)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: RBRadius.panel
                    )
                )
            }
        }
        .sheet(
            isPresented: $showingPaperPicker
        ) {
            LiteratureReviewPaperPicker(
                review: review
            )
        }
    }

    private func removePaper(
        _ paper: PaperRecord
    ) {
        review.papers.removeAll {
            $0.id == paper.id
        }

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to remove paper from review: \(error)"
            )
        }
    }
}

private enum LiteratureReviewPaperSortOption:
    String,
    CaseIterable,
    Identifiable {

    case title = "Title"
    case yearNewest = "Year — Newest"
    case yearOldest = "Year — Oldest"
    case recentlyUpdated = "Recently Updated"

    var id: String {
        rawValue
    }
}

// MARK: - Themes

private struct ThemesSection: View {

    @Environment(\.modelContext) private var modelContext

    let review: LiteratureReview

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {

            HStack {

                SectionHeader(
                    title: "Themes",
                    subtitle: "Group papers around recurring concepts, methods, or topics."
                )

                Spacer()

                Button {
                    createTheme()
                } label: {
                    Label(
                        "New Theme",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            if review.themes.isEmpty {

                EmptySectionCard(
                    icon: "tag",
                    title: "No Themes Yet",
                    message: "Create themes to organize related papers."
                )

            } else {

                LazyVStack(spacing: 14) {

                    ForEach(
                        review.themes.sorted {
                            $0.createdAt < $1.createdAt
                        }
                    ) { theme in

                        ThemeCard(
                            theme: theme,
                            review: review,
                            deleteAction: {
                                deleteTheme(theme)
                            }
                        )
                    }
                }
            }
        }
    }

    private func createTheme() {

        let theme = LiteratureTheme(
            name: "New Theme",
            review: review
        )

        modelContext.insert(theme)

        if !review.themes.contains(
            where: {
                $0.id == theme.id
            }
        ) {
            review.themes.append(theme)
        }

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to create theme: \(error)"
            )
        }
    }

    private func deleteTheme(
        _ theme: LiteratureTheme
    ) {

        review.themes.removeAll {
            $0.id == theme.id
        }

        modelContext.delete(theme)

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to delete theme: \(error)"
            )
        }
    }
}

// MARK: - Theme Card

private struct ThemeCard: View {

    @Environment(\.modelContext) private var modelContext

    @Bindable var theme: LiteratureTheme

    let review: LiteratureReview
    let deleteAction: () -> Void

    @State private var showingPaperPicker = false
    @State private var savedMessage = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            HStack {

                Image(
                    systemName: "tag.fill"
                )
                .foregroundStyle(
                    RBColor.accent
                )

                TextField(
                    "Theme name",
                    text: $theme.name
                )
                .font(RBFont.body(.semibold))
                .textFieldStyle(.plain)

                Spacer()

                Button {
                    save()
                } label: {
                    Image(
                        systemName: "checkmark"
                    )
                }
                .buttonStyle(.borderless)
                .help("Save Theme")

                Button(
                    role: .destructive
                ) {
                    deleteAction()
                } label: {
                    Image(
                        systemName: "trash"
                    )
                }
                .buttonStyle(.borderless)
                .help("Delete Theme")
            }

            TextEditor(
                text: $theme.descriptionText
            )
.rbTextEditorStyle(minHeight: 80)

            HStack {

                Text("Linked Papers")
                    .font(RBFont.secondary(.semibold))

                Spacer()

                Button {
                    showingPaperPicker = true
                } label: {
                    Label(
                        "Add Papers",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
            }

            if theme.papers.isEmpty {

                Text(
                    "No papers linked to this theme."
                )
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)

            } else {

                ForEach(
                    theme.papers.sorted {
                        $0.title.localizedCaseInsensitiveCompare(
                            $1.title
                        ) == .orderedAscending
                    }
                ) { paper in

                    HStack(spacing: 8) {

                        Image(
                            systemName: "doc.text"
                        )
                        .foregroundStyle(RBColor.secondaryText)

                        VStack(
                            alignment: .leading,
                            spacing: 2
                        ) {

                            Text(
                                paper.title.isEmpty
                                ? "Untitled Paper"
                                : paper.title
                            )
                            .lineLimit(1)

                            Text(
                                paper.authors.isEmpty
                                ? "Unknown author"
                                : paper.authors
                            )
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                            .lineLimit(1)
                        }

                        Spacer()

                        if paper.pdfFilePath.isEmpty {

                            Text("No PDF")
                                .font(RBFont.label())
                                .foregroundStyle(RBColor.secondaryText)

                        } else {

                            Image(
                                systemName: "doc.richtext"
                            )
                            .foregroundStyle(RBColor.secondaryText)
                        }

                        Button {
                            theme.papers.removeAll {
                                $0.id == paper.id
                            }

                            save()
                        } label: {
                            Image(
                                systemName: "minus.circle"
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }

            if savedMessage {
                Text("Saved")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }
        }
        .padding(18)
        .background(RBColor.card)
        .clipShape(
            RoundedRectangle(
                cornerRadius: RBRadius.panel
            )
        )
        .sheet(
            isPresented: $showingPaperPicker
        ) {
            ThemePaperPicker(
                theme: theme,
                review: review
            )
        }
    }

    private func save() {

        theme.updatedAt = Date()
        review.updatedAt = Date()

        do {
            try modelContext.save()

            savedMessage = true

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.2
            ) {
                savedMessage = false
            }

        } catch {
            print(
                "ResearchBase: Failed to save theme: \(error)"
            )
        }
    }
}

// MARK: - Findings

private struct FindingsSection: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    let review: LiteratureReview

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {

            HStack {

                SectionHeader(
                    title: "Findings",
                    subtitle: "Record important findings and connect them to supporting papers."
                )

                Spacer()

                Button {
                    createFinding()
                } label: {
                    Label(
                        "New Finding",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            if review.findings.isEmpty {

                EmptySectionCard(
                    icon: "lightbulb",
                    title: "No Findings Yet",
                    message: "Capture important findings as you read the literature."
                )

            } else {

                LazyVStack(spacing: 14) {

                    ForEach(
                        review.findings.sorted {
                            $0.createdAt < $1.createdAt
                        }
                    ) { finding in

                        FindingCard(
                            finding: finding,
                            review: review,
                            deleteAction: {
                                deleteFinding(finding)
                            }
                        )
                    }
                }
            }
        }
        // Phase 14 — Quick Add → Finding. Also runs on appear because
        // the workspace switches to this section just before it exists.
        .onAppear { consumeQuickAdd() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
    }

    /// Runs the same `createFinding()` the New Finding button runs,
    /// once, then clears the request.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .finding else { return }
        router.pendingCreate = nil
        createFinding()
    }

    private func createFinding() {

        let finding = LiteratureFinding(
            title: "New Finding",
            review: review
        )

        modelContext.insert(finding)

        if !review.findings.contains(
            where: {
                $0.id == finding.id
            }
        ) {
            review.findings.append(finding)
        }

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to create finding: \(error)"
            )
        }
    }

    private func deleteFinding(
        _ finding: LiteratureFinding
    ) {

        review.findings.removeAll {
            $0.id == finding.id
        }

        modelContext.delete(finding)

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to delete finding: \(error)"
            )
        }
    }
}

// MARK: - Finding Card

private struct FindingCard: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter
    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    @Bindable var finding: LiteratureFinding

    let review: LiteratureReview
    let deleteAction: () -> Void

    @State private var showingPaperPicker = false
    @State private var relatedGroups: [ResearchDataStore.RelatedGroup] = []

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            HStack {

                Image(
                    systemName: "lightbulb.fill"
                )
                .foregroundStyle(RBColor.warning)

                TextField(
                    "Finding title",
                    text: $finding.title
                )
                .font(RBFont.body(.semibold))
                .textFieldStyle(.plain)

                Spacer()

                Button {
                    save()
                } label: {
                    Image(
                        systemName: "checkmark"
                    )
                }
                .buttonStyle(.borderless)

                Button(
                    role: .destructive
                ) {
                    deleteAction()
                } label: {
                    Image(
                        systemName: "trash"
                    )
                }
                .buttonStyle(.borderless)
            }

            TextEditor(
                text: $finding.content
            )
.rbTextEditorStyle(minHeight: 130)

            HStack {

                Text("Supporting Papers")
                    .font(RBFont.secondary(.semibold))

                Spacer()

                Button {
                    showingPaperPicker = true
                } label: {
                    Label(
                        "Add Papers",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
            }

            if finding.supportingPapers.isEmpty {

                Text(
                    "No supporting papers linked."
                )
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)

            } else {

                ForEach(
                    finding.supportingPapers.sorted {
                        $0.title.localizedCaseInsensitiveCompare(
                            $1.title
                        ) == .orderedAscending
                    }
                ) { paper in

                    HStack(spacing: 8) {

                        Image(
                            systemName: "doc.text"
                        )

                        Text(
                            paper.title.isEmpty
                            ? "Untitled Paper"
                            : paper.title
                        )
                        .lineLimit(1)

                        Spacer()

                        if paper.pdfFilePath.isEmpty {
                            Text("No PDF")
                                .font(RBFont.label())
                                .foregroundStyle(RBColor.secondaryText)
                        }

                        Button {
                            finding.supportingPapers.removeAll {
                                $0.id == paper.id
                            }

                            save()
                        } label: {
                            Image(
                                systemName: "minus.circle"
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                    .foregroundStyle(.primary)
                    .padding(.vertical, 3)
                }
            }

            // MARK: Related Research

            RelatedResearchView(
                groups: relatedGroups,
                onNavigate: { destination in
                    router.open(destination)
                }
            )
        }
        .padding(18)
        .background(RBColor.card)
        .clipShape(
            RoundedRectangle(
                cornerRadius: RBRadius.panel
            )
        )
        .sheet(
            isPresented: $showingPaperPicker
        ) {
            FindingPaperPicker(
                finding: finding,
                review: review
            )
        }
        .task(id: finding.id) {
            loadRelatedGroups(for: finding)
        }
    }

    private func save() {

        finding.updatedAt = Date()
        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to save finding: \(error)"
            )
        }
    }

    private func loadRelatedGroups(
        for finding: LiteratureFinding
    ) {
        do {
            relatedGroups = try store.relatedResearch(
                for: finding
            )
        } catch {
            relatedGroups = []

            Swift.print(
                "ResearchBase: Failed to load related research: \(error)"
            )
        }
    }
}

// MARK: - Comparison

private struct ComparisonSection: View {

    @Environment(\.modelContext) private var modelContext

    let review: LiteratureReview

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {

            HStack {

                SectionHeader(
                    title: "Comparison",
                    subtitle: "Compare methods, datasets, findings, and notes across papers."
                )

                Spacer()

                Button {
                    createComparisonEntry()
                } label: {
                    Label(
                        "Add Comparison",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            if review.comparisonEntries.isEmpty {

                EmptySectionCard(
                    icon: "rectangle.split.3x1",
                    title: "No Comparisons Yet",
                    message: "Create comparison entries for the papers in this review."
                )

            } else {

                LazyVStack(spacing: 14) {

                    ForEach(
                        review.comparisonEntries.sorted {
                            $0.createdAt < $1.createdAt
                        }
                    ) { entry in

                        ComparisonCard(
                            entry: entry,
                            review: review,
                            deleteAction: {
                                deleteComparison(entry)
                            }
                        )
                    }
                }
            }
        }
    }

    private func createComparisonEntry() {

        let entry = LiteratureComparisonEntry(
            review: review
        )

        modelContext.insert(entry)

        if !review.comparisonEntries.contains(
            where: {
                $0.id == entry.id
            }
        ) {
            review.comparisonEntries.append(entry)
        }

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to create comparison entry: \(error)"
            )
        }
    }

    private func deleteComparison(
        _ entry: LiteratureComparisonEntry
    ) {

        review.comparisonEntries.removeAll {
            $0.id == entry.id
        }

        modelContext.delete(entry)

        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to delete comparison entry: \(error)"
            )
        }
    }
}

// MARK: - Comparison Card

private struct ComparisonCard: View {

    @Environment(\.modelContext) private var modelContext

    @Bindable var entry: LiteratureComparisonEntry

    let review: LiteratureReview
    let deleteAction: () -> Void

    @State private var showingPaperPicker = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            HStack {

                Image(
                    systemName: "rectangle.split.3x1"
                )
                .foregroundStyle(
                    RBColor.accent
                )

                Text(
                    entry.paper?.title ??
                    "Unlinked Paper"
                )
                .font(RBFont.body(.semibold))
                .lineLimit(1)

                Spacer()

                Button {
                    showingPaperPicker = true
                } label: {
                    Label(
                        "Link Paper",
                        systemImage: "link"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    save()
                } label: {
                    Image(
                        systemName: "checkmark"
                    )
                }
                .buttonStyle(.borderless)

                Button(
                    role: .destructive
                ) {
                    deleteAction()
                } label: {
                    Image(
                        systemName: "trash"
                    )
                }
                .buttonStyle(.borderless)
            }

            ComparisonField(
                title: "Method",
                text: $entry.method,
                minHeight: 70
            )

            ComparisonField(
                title: "Dataset",
                text: $entry.dataset,
                minHeight: 70
            )

            ComparisonField(
                title: "Main Finding",
                text: $entry.mainFinding,
                minHeight: 90
            )

            ComparisonField(
                title: "Notes",
                text: $entry.notes,
                minHeight: 80
            )

            if let paper = entry.paper {

                HStack(spacing: 8) {

                    Image(
                        systemName: "checkmark.circle.fill"
                    )
                    .foregroundStyle(RBColor.success)

                    Text(
                        paper.title.isEmpty
                        ? "Untitled Paper"
                        : paper.title
                    )
                    .font(RBFont.caption())
                    .lineLimit(1)

                    Spacer()

                    if paper.pdfFilePath.isEmpty {

                        Text("No PDF")
                            .font(RBFont.label())
                            .foregroundStyle(RBColor.secondaryText)

                    } else {

                        Text("PDF attached")
                            .font(RBFont.label())
                            .foregroundStyle(RBColor.secondaryText)
                    }

                    Button {
                        entry.paper = nil
                        save()
                    } label: {
                        Image(
                            systemName: "xmark.circle"
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(18)
        .background(RBColor.card)
        .clipShape(
            RoundedRectangle(
                cornerRadius: RBRadius.panel
            )
        )
        .sheet(
            isPresented: $showingPaperPicker
        ) {
            ComparisonPaperPicker(
                entry: entry,
                review: review
            )
        }
    }

    private func save() {

        entry.updatedAt = Date()
        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to save comparison entry: \(error)"
            )
        }
    }
}

// MARK: - Synthesis

private struct SynthesisSection: View {

    @Environment(\.modelContext) private var modelContext

    let review: LiteratureReview

    @State private var savedMessage = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 18
        ) {

            HStack {

                SectionHeader(
                    title: "Synthesis",
                    subtitle: "Bring the literature together into a structured synthesis."
                )

                Spacer()

                if review.synthesis == nil {

                    Button {
                        createSynthesis()
                    } label: {
                        Label(
                            "Create Synthesis",
                            systemImage: "plus"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let synthesis = review.synthesis {

                SynthesisEditor(
                    synthesis: synthesis,
                    review: review,
                    savedMessage: $savedMessage
                )

            } else {

                EmptySectionCard(
                    icon: "text.alignleft",
                    title: "No Synthesis Yet",
                    message: "Create a synthesis when you are ready to consolidate the literature."
                )
            }
        }
    }

    private func createSynthesis() {

        let synthesis = LiteratureSynthesis(
            review: review
        )

        modelContext.insert(synthesis)

        review.synthesis = synthesis
        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to create synthesis: \(error)"
            )
        }
    }
}

// MARK: - Synthesis Editor

private struct SynthesisEditor: View {

    @Environment(\.modelContext) private var modelContext

    @Bindable var synthesis: LiteratureSynthesis

    let review: LiteratureReview

    @Binding var savedMessage: Bool

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {

            SynthesisField(
                title: "Common Approaches",
                placeholder: "What approaches appear repeatedly across the literature?",
                text: $synthesis.commonApproaches,
                minHeight: 100
            )

            SynthesisField(
                title: "Major Findings",
                placeholder: "What are the major findings across the included studies?",
                text: $synthesis.majorFindings,
                minHeight: 120
            )

            SynthesisField(
                title: "Areas of Agreement",
                placeholder: "Where do studies agree?",
                text: $synthesis.areasOfAgreement,
                minHeight: 100
            )

            SynthesisField(
                title: "Areas of Disagreement",
                placeholder: "Where do studies disagree or produce different results?",
                text: $synthesis.areasOfDisagreement,
                minHeight: 100
            )

            SynthesisField(
                title: "Methodological Differences",
                placeholder: "How do methods, datasets, evaluation procedures, or assumptions differ?",
                text: $synthesis.methodologicalDifferences,
                minHeight: 110
            )

            SynthesisField(
                title: "Limitations Across the Literature",
                placeholder: "What limitations recur across the included studies?",
                text: $synthesis.limitationsAcrossLiterature,
                minHeight: 110
            )

            SynthesisField(
                title: "Overall Summary",
                placeholder: "Write the overall synthesis of the literature.",
                text: $synthesis.overallSummary,
                minHeight: 150
            )

            HStack {

                Button {
                    save()
                } label: {
                    Label(
                        "Save Synthesis",
                        systemImage: "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)

                if savedMessage {
                    Label(
                        "Saved",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                }

                Spacer()

                Text(
                    "Updated \(synthesis.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    private func save() {

        synthesis.updatedAt = Date()
        review.updatedAt = Date()

        do {
            try modelContext.save()

            savedMessage = true

            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.5
            ) {
                savedMessage = false
            }

        } catch {
            print(
                "ResearchBase: Failed to save synthesis: \(error)"
            )
        }
    }
}

// MARK: - Literature Review Paper Picker

private struct LiteratureReviewPaperPicker: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(
        sort: [
            SortDescriptor(
                \PaperRecord.title,
                order: .forward
            )
        ]
    )
    private var allPapers: [PaperRecord]

    let review: LiteratureReview

    @State private var searchText = ""
    @State private var publicationFilter = "All"

    private var availablePapers: [PaperRecord] {

        let query =
            searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        return allPapers.filter { paper in

            let notAlreadyAdded =
                !review.papers.contains {
                    $0.id == paper.id
                }

            let matchesSearch: Bool

            if query.isEmpty {

                matchesSearch = true

            } else {

                matchesSearch =
                    paper.title.localizedCaseInsensitiveContains(query) ||
                    paper.authors.localizedCaseInsensitiveContains(query) ||
                    paper.venue.localizedCaseInsensitiveContains(query) ||
                    paper.citationKey.localizedCaseInsensitiveContains(query)
            }

            let matchesType =
                publicationFilter == "All" ||
                paper.publicationType.rawValue ==
                publicationFilter

            return notAlreadyAdded &&
                matchesSearch &&
                matchesType
        }
    }

    private var publicationTypes: [String] {

        let types = Set(
            allPapers.map {
                $0.publicationType.rawValue
            }
        )

        return ["All"] +
            types
                .filter {
                    !$0.isEmpty &&
                    $0 != "All"
                }
                .sorted()
    }

    var body: some View {
        VStack(spacing: 0) {

            HStack {

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {

                    Text(
                        "Add Papers to Review"
                    )
                    .font(RBFont.detail(.semibold))

                    Text(
                        "Select existing ResearchBase papers. No new PaperRecord will be created."
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            HStack(spacing: 10) {

                HStack(spacing: 7) {

                    Image(
                        systemName: "magnifyingglass"
                    )
                    .foregroundStyle(RBColor.secondaryText)

                    TextField(
                        "Search papers",
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                }
                .padding(9)
                .background(RBColor.background)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: RBRadius.field
                    )
                )

                Picker(
                    "Type",
                    selection: $publicationFilter
                ) {
                    ForEach(
                        publicationTypes,
                        id: \.self
                    ) { type in
                        Text(type)
                            .tag(type)
                    }
                }
                .controlSize(.regular)
            }
            .padding()

            Divider()

            if availablePapers.isEmpty {

                VStack(spacing: 10) {

                    Spacer()

                    Image(
                        systemName: "doc.text.magnifyingglass"
                    )
                    .font(
                        .system(size: 36)
                    )
                    .foregroundStyle(RBColor.secondaryText)

                    Text(
                        allPapers.isEmpty
                        ? "No Papers in Library"
                        : "No Available Papers"
                    )
                    .font(RBFont.body(.semibold))

                    Text(
                        allPapers.isEmpty
                        ? "Add papers to your ResearchBase library first."
                        : "All matching papers are already part of this review."
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)

                    Spacer()
                }
                .frame(maxWidth: .infinity)

            } else {

                List {
                    ForEach(
                        availablePapers
                    ) { paper in

                        Button {
                            addPaper(paper)
                        } label: {
                            LiteratureReviewPickerRow(
                                paper: paper
                            )
                        }
                        .buttonStyle(.plain)
                        .rbHover(cornerRadius: RBRadius.field)
                    }
                }
            }
        }
        .frame(
            minWidth: 760,
            minHeight: 560
        )
    }

    private func addPaper(
        _ paper: PaperRecord
    ) {

        guard !review.papers.contains(
            where: {
                $0.id == paper.id
            }
        ) else {
            return
        }

        review.papers.append(paper)
        review.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print(
                "ResearchBase: Failed to add paper to review: \(error)"
            )
        }
    }
}

// MARK: - Theme Paper Picker

private struct ThemePaperPicker: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let theme: LiteratureTheme
    let review: LiteratureReview

    @State private var searchText = ""

    private var availablePapers: [PaperRecord] {

        let query =
            searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        return review.papers.filter { paper in

            let notAdded =
                !theme.papers.contains {
                    $0.id == paper.id
                }

            if query.isEmpty {
                return notAdded
            }

            let titleMatches =
                paper.title.localizedCaseInsensitiveContains(
                    query
                )

            let authorMatches =
                paper.authors.localizedCaseInsensitiveContains(
                    query
                )

            return notAdded &&
                (titleMatches || authorMatches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            HStack {

                Text("Add Papers to Theme")
                    .font(RBFont.detail(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            TextField(
                "Search papers in this review",
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .padding()

            Divider()

            List {
                ForEach(
                    availablePapers
                ) { paper in

                    Button {

                        theme.papers.append(
                            paper
                        )

                        theme.updatedAt = Date()
                        review.updatedAt = Date()

                        do {
                            try modelContext.save()
                        } catch {
                            print(
                                "ResearchBase: Failed to link theme paper: \(error)"
                            )
                        }

                    } label: {
                        LiteratureReviewPickerRow(
                            paper: paper
                        )
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                }
            }
        }
        .frame(
            minWidth: 650,
            minHeight: 500
        )
    }
}

// MARK: - Finding Paper Picker

private struct FindingPaperPicker: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let finding: LiteratureFinding
    let review: LiteratureReview

    @State private var searchText = ""

    private var availablePapers: [PaperRecord] {

        let query =
            searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        return review.papers.filter { paper in

            let notAdded =
                !finding.supportingPapers.contains {
                    $0.id == paper.id
                }

            if query.isEmpty {
                return notAdded
            }

            let titleMatches =
                paper.title.localizedCaseInsensitiveContains(
                    query
                )

            let authorMatches =
                paper.authors.localizedCaseInsensitiveContains(
                    query
                )

            return notAdded &&
                (titleMatches || authorMatches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            HStack {

                Text(
                    "Add Supporting Papers"
                )
                .font(RBFont.detail(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            TextField(
                "Search papers in this review",
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .padding()

            Divider()

            List {
                ForEach(
                    availablePapers
                ) { paper in

                    Button {

                        finding.supportingPapers.append(
                            paper
                        )

                        finding.updatedAt = Date()
                        review.updatedAt = Date()

                        do {
                            try modelContext.save()
                        } catch {
                            print(
                                "ResearchBase: Failed to link finding paper: \(error)"
                            )
                        }

                    } label: {
                        LiteratureReviewPickerRow(
                            paper: paper
                        )
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                }
            }
        }
        .frame(
            minWidth: 650,
            minHeight: 500
        )
    }
}

// MARK: - Comparison Paper Picker

private struct ComparisonPaperPicker: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let entry: LiteratureComparisonEntry
    let review: LiteratureReview

    @State private var searchText = ""

    private var availablePapers: [PaperRecord] {

        let query =
            searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        return review.papers.filter { paper in

            if query.isEmpty {
                return true
            }

            return paper.title.localizedCaseInsensitiveContains(query) ||
                paper.authors.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            HStack {

                Text(
                    "Link Comparison to Paper"
                )
                .font(RBFont.detail(.semibold))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            TextField(
                "Search papers in this review",
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .padding()

            Divider()

            List {
                ForEach(
                    availablePapers
                ) { paper in

                    Button {

                        entry.paper = paper
                        entry.updatedAt = Date()
                        review.updatedAt = Date()

                        do {
                            try modelContext.save()
                        } catch {
                            print(
                                "ResearchBase: Failed to link comparison paper: \(error)"
                            )
                        }

                        dismiss()

                    } label: {
                        LiteratureReviewPickerRow(
                            paper: paper
                        )
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                }
            }
        }
        .frame(
            minWidth: 650,
            minHeight: 500
        )
    }
}

// MARK: - New Review Sheet

private struct NewLiteratureReviewSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var researchQuestion = ""

    let createAction: (
        String,
        String,
        String
    ) -> Void

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 20
        ) {

            Text("New Literature Review")
                .font(RBFont.detail(.semibold))

            FormField("Title") {
                TextField(
                    "e.g. Deep Learning for Network Intrusion Detection",
                    text: $title
                )
                .textFieldStyle(
                    .roundedBorder
                )
            }

            FormField("Research Question") {
                TextEditor(
                    text: $researchQuestion
                )
.rbTextEditorStyle(minHeight: 80)
            }

            FormField("Description") {
                TextEditor(
                    text: $description
                )
.rbTextEditorStyle(minHeight: 110)
            }

            Spacer()

            HStack {

                Spacer()

                Button("Cancel") {
                    dismiss()
                }

                Button("Create Review") {

                    createAction(
                        title,
                        description,
                        researchQuestion
                    )

                    dismiss()
                }
                .buttonStyle(
                    .borderedProminent
                )
            }
        }
        .padding(24)
        .frame(
            minWidth: 620,
            minHeight: 520
        )
    }
}

// MARK: - Reusable Views

private struct SectionHeader: View {

    let title: String
    let subtitle: String

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 4
        ) {

            Text(title)
                .font(RBFont.section(.semibold))

            Text(subtitle)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
        }
    }
}

private struct OverviewMetricCard: View {

    let title: String
    let value: String
    let icon: String

    var body: some View {
        // Kit card. The HTML tile is a number over a label, so no icon
        // is drawn (`icon` stays in the init because other code may pass it).
        RBCard(padding: 16) {
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                Text(value)
                    .font(RBFont.detail(.bold))

                Text(title)
                    .font(RBFont.secondary(.regular))
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

private struct FormField<Content: View>: View {

    let title: String
    let content: Content

    init(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {
            // Kit label: small uppercase, like the HTML ("TITLE")
            RBSectionLabel(text: title)

            content
        }
    }
}

private struct ComparisonField: View {

    let title: String
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 6
        ) {

            Text(title)
                .font(RBFont.caption(.semibold))
                .foregroundStyle(RBColor.secondaryText)

            TextEditor(
                text: $text
            )
.rbTextEditorStyle(minHeight: minHeight)
        }
    }
}

private struct SynthesisField: View {

    let title: String
    let placeholder: String

    @Binding var text: String

    let minHeight: CGFloat

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 7
        ) {

            Text(title)
                .font(RBFont.body(.semibold))

            ZStack(
                alignment: .topLeading
            ) {

                TextEditor(
                    text: $text
                )
.rbTextEditorStyle(minHeight: minHeight)

                if text.isEmpty {

                    Text(placeholder)
                        .foregroundStyle(RBColor.mutedText)
                        .padding(
                            .horizontal,
                            15
                        )
                        .padding(
                            .vertical,
                            10
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(16)
        .background(RBColor.card)
        .clipShape(
            RoundedRectangle(
                cornerRadius: RBRadius.panel
            )
        )
    }
}

private struct EmptySectionCard: View {

    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {

            Image(
                systemName: icon
            )
            .font(
                .system(size: 34)
            )
            .foregroundStyle(RBColor.secondaryText)

            Text(title)
                .font(RBFont.body(.semibold))

            Text(message)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 250
        )
        .background(RBColor.card)
        .clipShape(
            RoundedRectangle(
                cornerRadius: RBRadius.panel
            )
        )
    }
}

// MARK: - Paper Rows

private struct LiteratureReviewPaperRow: View {

    let paper: PaperRecord
    let removeAction: () -> Void

    private var documentColor: Color {
        paper.pdfFilePath.isEmpty
            ? RBColor.secondaryText
            : RBColor.accent
    }

    var body: some View {
        HStack(spacing: 14) {

            Image(
                systemName:
                    paper.pdfFilePath.isEmpty
                    ? "doc.text"
                    : "doc.richtext"
            )
            .font(RBFont.section())
            .foregroundStyle(documentColor)
            .frame(
                minWidth: 30,
                maxWidth: 30
            )

            VStack(
                alignment: .leading,
                spacing: 4
            ) {

                Text(
                    paper.title.isEmpty
                    ? "Untitled Paper"
                    : paper.title
                )
                .font(RBFont.body(.semibold))
                .lineLimit(2)

                HStack(spacing: 8) {

                    if !paper.authors.isEmpty {
                        Text(paper.authors)
                            .lineLimit(1)
                    }

                    if paper.year > 0 {
                        Text("• \(paper.year)")
                    }

                    if !paper.venue.isEmpty {
                        Text("• \(paper.venue)")
                            .lineLimit(1)
                    }
                }
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)

                HStack(spacing: 8) {

                    if !paper.citationKey.isEmpty {
                        Text(paper.citationKey)
                            .font(RBFont.label().monospaced())
                            .foregroundStyle(RBColor.secondaryText)
                    }

                    if paper.pdfFilePath.isEmpty {

                        Text("No PDF attached")
                            .font(RBFont.label())
                            .foregroundStyle(RBColor.warning)

                    } else {

                        Text("PDF attached")
                            .font(RBFont.label())
                            .foregroundStyle(RBColor.success)
                    }
                }
            }

            Spacer()

            Button(
                role: .destructive
            ) {
                removeAction()
            } label: {
                Image(
                    systemName: "minus.circle"
                )
            }
            .buttonStyle(.borderless)
            .help("Remove from Review")
        }
        .padding(14)
    }
}

private struct LiteratureReviewPickerRow: View {

    let paper: PaperRecord

    private var documentColor: Color {
        paper.pdfFilePath.isEmpty
            ? RBColor.secondaryText
            : RBColor.accent
    }

    var body: some View {
        HStack(spacing: 12) {

            Image(
                systemName:
                    paper.pdfFilePath.isEmpty
                    ? "doc.text"
                    : "doc.richtext"
            )
            .foregroundStyle(documentColor)

            VStack(
                alignment: .leading,
                spacing: 3
            ) {

                Text(
                    paper.title.isEmpty
                    ? "Untitled Paper"
                    : paper.title
                )
                .font(RBFont.body(.semibold))
                .lineLimit(2)

                Text(
                    paper.authors.isEmpty
                    ? "Unknown author"
                    : paper.authors
                )
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .lineLimit(1)

                HStack(spacing: 7) {

                    if paper.year > 0 {
                        Text("\(paper.year)")
                    }

                    if !paper.venue.isEmpty {
                        Text("• \(paper.venue)")
                            .lineLimit(1)
                    }

                    if paper.pdfFilePath.isEmpty {
                        Text("• No PDF")
                    }
                }
                .font(RBFont.label())
                .foregroundStyle(RBColor.mutedText)
            }

            Spacer()

            Image(
                systemName: "plus.circle"
            )
            .foregroundStyle(
                RBColor.accent
            )
        }
        .padding(.vertical, 5)
    }
}
