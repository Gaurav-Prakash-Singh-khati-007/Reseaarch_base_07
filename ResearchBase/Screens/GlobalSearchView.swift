//
//  GlobalSearchView.swift
//  ResearchBase
//
//  Owner: Agent 61 · Features: F-22 (full-text results)
//  Source of truth: researchbase.html (F-22, E-02 "Search is a sidebar destination")
//
//  The Search screen. It asks SearchService (Agent 14) for ranked results and shows them
//  grouped by kind: Papers, PDF text, Notes and ideas, Drafts. Nothing here is sample data.
//
//  What it does
//    - As-you-type search (short pause after the last key), or Return to search at once.
//    - Scope chips: Everything / Papers / PDF text / Notes and ideas / Drafts.
//    - "Everything" shows the best few of each kind with real totals and a "See all" button.
//      One kind shows 50 at a time with "Show more".
//    - Search words are highlighted in titles and snippets.
//    - Search index card: real count of indexed PDFs and PDFs waiting for OCR (read only).
//    - Search tips card (only syntax that SearchService really supports).
//    - Papers still in the Inbox and anything in Trash are never shown (SearchService rule).
//
//  Not here, on purpose
//    - Experiments scope: there is no experiments table in the search index (schema is frozen
//      with fts_items, fts_pdf, fts_thought, fts_draft only).
//    - PDF hits show "Page N" but no text snippet: the index is contentless (see SearchService).
//    - Draft hits are per draft, not per file (same reason).
//    - Year / Tag / Collection filters and "Save search" belong to F-09 (Library), not F-22.
//    - "Rebuild index" button: needs PDFTextIndexer, which the app wiring (Agents 75-77) owns.
//
//  PUBLIC API
//    GlobalSearchView(model:reloadToken:onOpenItem:onOpenPDF:onOpenThought:onOpenDraft:)
//      model          the open LibraryModel (nil shows "library not open", never crashes)
//      reloadToken    change this number to re-run the search and refresh the index card
//      onOpenItem     (itemID)                       a paper result was chosen
//      onOpenPDF      (itemID, attachmentID, page)   a PDF text result was chosen
//      onOpenThought  (thoughtID, kind)              a note / idea / finding ... was chosen
//      onOpenDraft    (draftID)                      a draft result was chosen
//    Every parameter has a default, so `GlobalSearchView()` still compiles.
//    A result row whose callback is nil does nothing when clicked.
//
//  Reads (only): SearchService, LibraryModel and its database, RBColor, RBFont, RBCard, RBBadge.
//

import SwiftUI

// MARK: - Scope

enum GlobalSearchScope: String, CaseIterable, Identifiable {
    case everything, papers, pdf, notes, drafts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everything: return "Everything"
        case .papers:     return "Papers"
        case .pdf:        return "PDF text"
        case .notes:      return "Notes and ideas"
        case .drafts:     return "Drafts"
        }
    }
}

// MARK: - View

@MainActor
struct GlobalSearchView: View {

    let model: LibraryModel?
    let reloadToken: Int
    let onOpenItem: ((String) -> Void)?
    let onOpenPDF: ((_ itemID: String, _ attachmentID: String, _ page: Int) -> Void)?
    let onOpenThought: ((_ thoughtID: String, _ kind: String) -> Void)?
    let onOpenDraft: ((String) -> Void)?

    init(
        model: LibraryModel? = nil,
        reloadToken: Int = 0,
        onOpenItem: ((String) -> Void)? = nil,
        onOpenPDF: ((_ itemID: String, _ attachmentID: String, _ page: Int) -> Void)? = nil,
        onOpenThought: ((_ thoughtID: String, _ kind: String) -> Void)? = nil,
        onOpenDraft: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.reloadToken = reloadToken
        self.onOpenItem = onOpenItem
        self.onOpenPDF = onOpenPDF
        self.onOpenThought = onOpenThought
        self.onOpenDraft = onOpenDraft
    }

    // MARK: Private types

    private enum Target {
        case item(String)
        case pdf(itemID: String, attachmentID: String, page: Int)
        case thought(id: String, kind: String)
        case draft(String)
    }

    private struct ResultRow: Identifiable {
        let id: String
        let target: Target
        let title: String
        let subtitle: String
        let snippet: String
        let badge: String
    }

    private struct ResultSection: Identifiable {
        let scope: GlobalSearchScope
        var rows: [ResultRow]
        var total: Int
        var capped: Bool
        var id: String { scope.rawValue }

        var countText: String { "\(total)\(capped ? "+" : "")" }
        var hasMore: Bool { rows.count < total }
    }

    private struct SearchKey: Hashable {
        let text: String
        let scope: GlobalSearchScope
        let token: Int
    }

    private struct IndexStatus: Equatable {
        var totalPDFs: Int
        var indexedPDFs: Int
        var waitingForOCR: Int
    }

    // MARK: State

    @State private var query = ""
    @State private var scope: GlobalSearchScope = .everything
    @State private var sections: [ResultSection] = []
    @State private var terms: [String] = []
    @State private var errorText: String?
    @State private var completed: SearchKey?
    @State private var indexStatus: IndexStatus?
    @State private var loadingMore = false
    @FocusState private var searchFocused: Bool

    private static let overviewLimit = 10
    private static let pageSize = 50

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentKey: SearchKey {
        SearchKey(text: trimmedQuery, scope: scope, token: reloadToken)
    }

    // MARK: Body

    var body: some View {
        ZStack {
            RBColor.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    searchField
                    scopeChips

                    HStack(alignment: .top, spacing: 16) {
                        resultsColumn
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        sideColumn
                            .frame(width: 280)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task(id: currentKey) {
            await debouncedSearch()
        }
        .onChange(of: reloadToken) { _, _ in
            loadIndexStatus()
        }
        .onAppear {
            loadIndexStatus()
            searchFocused = true
        }
    }

    // MARK: Header, field, chips

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Search")
                .font(RBFont.title(.bold))
                .foregroundStyle(RBColor.primaryText)
            Text("Find words inside papers, PDFs, notes and drafts.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(RBColor.mutedText)

            TextField("Search everything", text: $query)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .focused($searchFocused)
                .onSubmit { performSearch() }
                .accessibilityLabel("Search")

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RBColor.mutedText)
                }
                .buttonStyle(RBHoverPlainButtonStyle())
                .accessibilityLabel("Clear search")
            }

            Text("⌘F")
                .font(RBFont.caption(.medium).monospaced())
                .foregroundStyle(RBColor.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(RBColor.hover))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.elevatedSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border, lineWidth: 1))
    }

    private var scopeChips: some View {
        HStack(spacing: 8) {
            ForEach(GlobalSearchScope.allCases) { item in
                Button {
                    scope = item
                } label: {
                    Text(item.label)
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(scope == item ? RBColor.accent : RBColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(scope == item ? RBColor.accent.opacity(0.15) : RBColor.card)
                        )
                        .overlay(
                            Capsule().stroke(scope == item ? RBColor.accent : RBColor.border, lineWidth: 1)
                        )
                }
                .buttonStyle(RBHoverPlainButtonStyle())
                .accessibilityAddTraits(scope == item ? .isSelected : [])
            }
            Spacer()
        }
    }

    // MARK: Results

    @ViewBuilder
    private var resultsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RBColor.warning)
                    Text(errorText)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.warning.opacity(0.12)))
            }

            if model == nil {
                emptyState(
                    icon: "externaldrive.badge.exclamationmark",
                    title: "The library is not open",
                    message: "Search needs the library. Open or restore a library, then try again."
                )
            } else if trimmedQuery.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "Search your whole library",
                    message: "Type a word or phrase. Search covers paper details, PDF text, notes and drafts."
                )
            } else if sections.isEmpty && completed == currentKey && errorText == nil {
                noResultsState
            } else if !sections.isEmpty {
                summaryLine
                ForEach(sections) { section in
                    sectionCard(section)
                }
            }
        }
    }

    private var summaryLine: some View {
        let shown = sections.reduce(0) { $0 + $1.total }
        let capped = sections.contains { $0.capped }
        return Text("\(shown)\(capped ? "+" : "") result\(shown == 1 ? "" : "s"), best matches first")
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
    }

    private func sectionCard(_ section: ResultSection) -> some View {
        RBCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {

                HStack(spacing: 8) {
                    Text(section.scope.label)
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                    RBBadge(text: section.countText, tone: .muted)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                ForEach(section.rows) { row in
                    Divider().overlay(RBColor.border)
                    resultButton(row)
                }

                if scope == .everything && section.hasMore {
                    Divider().overlay(RBColor.border)
                    Button {
                        scope = section.scope
                    } label: {
                        Text("See all \(section.countText) in \(section.scope.label)")
                            .font(RBFont.caption(.semibold))
                            .foregroundStyle(RBColor.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                } else if scope != .everything && section.hasMore {
                    Divider().overlay(RBColor.border)
                    Button {
                        loadMore(section.scope)
                    } label: {
                        Text(loadingMore ? "Loading…" : "Show more")
                            .font(RBFont.caption(.semibold))
                            .foregroundStyle(RBColor.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                    .disabled(loadingMore)
                }
            }
        }
    }

    private func resultButton(_ row: ResultRow) -> some View {
        Button {
            open(row.target)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(highlighted(row.title.isEmpty ? "Untitled" : row.title))
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    RBBadge(text: row.badge, tone: .neutral)
                }

                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }

                if !row.snippet.isEmpty {
                    Text(highlighted(row.snippet))
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RBHoverPlainButtonStyle())
    }

    private var noResultsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            emptyState(
                icon: "magnifyingglass",
                title: "No results for “\(trimmedQuery)”",
                message: "Try fewer words, or search everything instead of one kind."
            )
            if scope != .everything {
                Button("Search everything") { scope = .everything }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        RBCard {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(RBColor.mutedText)
                Text(title)
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text(message)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            indexCard
            tipsCard
        }
    }

    private var indexCard: some View {
        RBCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search index")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                if let status = indexStatus {
                    if status.totalPDFs == 0 {
                        Text("No PDFs in the library yet.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    } else {
                        ProgressView(value: Double(status.indexedPDFs), total: Double(status.totalPDFs))
                        Text("\(status.indexedPDFs) of \(status.totalPDFs) PDFs indexed")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    }
                    if status.waitingForOCR > 0 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(RBColor.mutedText)
                            Text("\(status.waitingForOCR) scanned PDF\(status.waitingForOCR == 1 ? "" : "s") waiting for text recognition (OCR)")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Index status is not available.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                }

                Text("Papers still in the Inbox and items in Trash are not searched.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tipsCard: some View {
        RBCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Search tips")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                tip("Use quotes for an exact phrase:", example: "\"client drift\"")
                tip("Limit a word to one field:", example: "author:mcmahan")
                tip("Other fields:", example: "title:  tag:  venue:  abstract:")
                tip("The last word matches word starts:", example: "feder → federated")
            }
        }
    }

    private func tip(_ text: String, example: String) -> some View {
        Text("\(Text(text)) \(Text(example).font(RBFont.caption().monospaced()))")
            .font(RBFont.caption())
            .foregroundStyle(RBColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Searching

    private func debouncedSearch() async {
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            return   // a newer key cancelled this one
        }
        performSearch()
    }

    private func performSearch() {

        let text = trimmedQuery
        let key = currentKey
        errorText = nil

        guard let model else {
            sections = []
            terms = []
            completed = key
            return
        }

        guard !text.isEmpty, let parsed = Self.termsParser(text) else {
            sections = []
            terms = []
            completed = key
            return
        }

        terms = parsed.terms
        let service = SearchService(model: model)

        do {
            var found: [ResultSection] = []
            let kinds: [GlobalSearchScope] = scope == .everything ? [.papers, .pdf, .notes, .drafts] : [scope]
            let limit = scope == .everything ? Self.overviewLimit : Self.pageSize

            for kind in kinds {
                let page = try fetch(kind, text: text, offset: 0, limit: limit, service: service)
                if !page.rows.isEmpty {
                    found.append(ResultSection(scope: kind, rows: page.rows, total: page.total, capped: page.capped))
                }
            }
            sections = found
        } catch {
            sections = []
            errorText = "Search could not run: \(error.localizedDescription)"
        }

        completed = key
    }

    private func loadMore(_ kind: GlobalSearchScope) {
        guard let model, let index = sections.firstIndex(where: { $0.scope == kind }) else { return }
        loadingMore = true
        defer { loadingMore = false }

        do {
            let service = SearchService(model: model)
            let offset = sections[index].rows.count
            let page = try fetch(kind, text: trimmedQuery, offset: offset, limit: Self.pageSize, service: service)
            let known = Set(sections[index].rows.map { $0.id })
            sections[index].rows.append(contentsOf: page.rows.filter { !known.contains($0.id) })
            sections[index].total = max(page.total, sections[index].rows.count)
            sections[index].capped = page.capped
        } catch {
            errorText = "Search could not load more results: \(error.localizedDescription)"
        }
    }

    private func fetch(
        _ kind: GlobalSearchScope,
        text: String,
        offset: Int,
        limit: Int,
        service: SearchService
    ) throws -> (rows: [ResultRow], total: Int, capped: Bool) {

        let options = SearchOptions(limit: limit, offset: offset, includeInbox: false)

        switch kind {
        case .papers:
            let page = try service.searchItems(text, options: options)
            return (page.hits.map(Self.row), page.total, page.totalIsCapped)
        case .pdf:
            let page = try service.searchPDF(text, options: options)
            return (page.hits.map(Self.row), page.total, page.totalIsCapped)
        case .notes:
            let page = try service.searchThoughts(text, options: options)
            return (page.hits.map(Self.row), page.total, page.totalIsCapped)
        case .drafts:
            let page = try service.searchDrafts(text, options: options)
            return (page.hits.map(Self.row), page.total, page.totalIsCapped)
        case .everything:
            return ([], 0, false)
        }
    }

    /// Same word rules as SearchService, with every column name it knows, so `author:smith`
    /// highlights "smith" and not the word "author".
    private static func termsParser(_ text: String) -> ParsedQuery? {
        let columns = SearchService.itemColumns.merging(SearchService.thoughtColumns) { first, _ in first }
        return SearchService.ftsQuery(text, columns: columns)
    }

    // MARK: Hit → row

    private static func row(_ hit: ItemHit) -> ResultRow {
        ResultRow(
            id: "item:\(hit.itemID)",
            target: .item(hit.itemID),
            title: hit.title,
            subtitle: hit.year.map { String($0) } ?? "",
            snippet: hit.snippet,
            badge: "Paper"
        )
    }

    private static func row(_ hit: PDFHit) -> ResultRow {
        ResultRow(
            id: "pdf:\(hit.attachmentID):\(hit.page)",
            target: .pdf(itemID: hit.itemID, attachmentID: hit.attachmentID, page: hit.page),
            title: hit.itemTitle,
            subtitle: "Page \(hit.page)",
            snippet: "",
            badge: "PDF text"
        )
    }

    private static func row(_ hit: ThoughtHit) -> ResultRow {
        ResultRow(
            id: "thought:\(hit.thoughtID)",
            target: .thought(id: hit.thoughtID, kind: hit.kind),
            title: hit.title,
            subtitle: "",
            snippet: hit.snippet,
            badge: hit.kind.capitalized
        )
    }

    private static func row(_ hit: DraftHit) -> ResultRow {
        ResultRow(
            id: "draft:\(hit.draftID)",
            target: .draft(hit.draftID),
            title: hit.title,
            subtitle: "",
            snippet: "",
            badge: "Draft"
        )
    }

    // MARK: Open

    private func open(_ target: Target) {
        switch target {
        case .item(let id):
            onOpenItem?(id)
        case .pdf(let itemID, let attachmentID, let page):
            onOpenPDF?(itemID, attachmentID, page)
        case .thought(let id, let kind):
            onOpenThought?(id, kind)
        case .draft(let id):
            onOpenDraft?(id)
        }
    }

    // MARK: Highlighting

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)

        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex,
                  let found = text.range(of: term,
                                         options: [.caseInsensitive, .diacriticInsensitive],
                                         range: from..<text.endIndex) {

                let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                let upper = text.distance(from: text.startIndex, to: found.upperBound)
                let start = result.index(result.startIndex, offsetByCharacters: lower)
                let end = result.index(result.startIndex, offsetByCharacters: upper)
                result[start..<end].backgroundColor = RBColor.accent.opacity(0.28)
                from = found.upperBound
            }
        }
        return result
    }

    // MARK: Index status (read only)

    private func loadIndexStatus() {
        guard let model else {
            indexStatus = nil
            return
        }

        let database = model.database
        let base = """
            FROM attachments a JOIN items i ON i.id = a.item_id
            WHERE a.kind = 'pdf' AND a.deleted_at IS NULL AND i.deleted_at IS NULL
            """

        do {
            let total = Int(try database.scalarInt("SELECT COUNT(*) \(base)", []) ?? 0)
            let pending = Int(try database.scalarInt("SELECT COUNT(*) \(base) AND a.indexed_at IS NULL", []) ?? 0)
            let queued = Int(try database.scalarInt(
                "SELECT COUNT(*) \(base) AND a.indexed_at IS NOT NULL AND a.ocr_state = 'queued'", []) ?? 0)
            indexStatus = IndexStatus(totalPDFs: total, indexedPDFs: max(total - pending, 0), waitingForOCR: queued)
        } catch {
            indexStatus = nil
        }
    }
}
