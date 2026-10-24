import SwiftUI
import SwiftData

// ═══════════════════════════════════════════════════════════════
//  Owner: Agent 70 · Features: F-09, F-24
//
//  PUBLIC API
//    EnvironmentValues.rbA70LibraryModel: LibraryModel?   (inject to switch on SQLite mode)
//    LibraryView(onSelectPaper:onSelectItem:)             (onSelectItem optional)
//    RBA70LibraryLogic  (pure paging / folder / meta helpers, tested)
//    RBA70LibraryBrowser(model:onSelectItem:)
// ═══════════════════════════════════════════════════════════════

private struct RBA70LibraryModelKey: EnvironmentKey {
    static let defaultValue: LibraryModel? = nil
}

extension EnvironmentValues {
    var rbA70LibraryModel: LibraryModel? {
        get { self[RBA70LibraryModelKey.self] }
        set { self[RBA70LibraryModelKey.self] = newValue }
    }
}

// MARK: - Logic (no UI, unit tested)

enum RBA70LibraryLogic {

    static let pageSize = 50

    enum Scope: Hashable {
        case all
        case folder(String)
        case saved(String)
    }

    struct FolderRow: Equatable, Identifiable {
        let collection: ModelCollection
        let depth: Int
        var id: String { collection.id }
    }

    struct RowMeta: Equatable {
        var authors: String
        var tags: [String]
    }

    struct Page {
        var items: [ModelItem]
        var nextOffset: Int
        var hasMore: Bool
    }

    static func flattenFolders(_ model: LibraryModel) throws -> [FolderRow] {
        var rows: [FolderRow] = []
        func walk(_ parent: String?, _ depth: Int) throws {
            guard depth < 32 else { return }
            for collection in try model.collections.children(of: parent) {
                rows.append(FolderRow(collection: collection, depth: depth))
                try walk(collection.id, depth + 1)
            }
        }
        try walk(nil, 0)
        return rows
    }

    static func page(
        model: LibraryModel,
        scope: Scope,
        query: String,
        offset: Int
    ) throws -> Page {

        let want = pageSize + 1
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if !text.isEmpty {
            let service = SearchService(model: model)
            let found = try service.searchItems(
                text,
                options: SearchOptions(limit: want, offset: offset, includeInbox: false)
            )
            let hits = Array(found.hits.prefix(pageSize))
            return Page(
                items: try service.items(for: hits),
                nextOffset: offset + hits.count,
                hasMore: found.hits.count > pageSize
            )
        }

        let fetched: [ModelItem]
        switch scope {
        case .all:
            fetched = try model.items.list(reviewState: .accepted, limit: want, offset: offset)
        case .folder(let id):
            fetched = try model.collections.items(in: id, includeSubfolders: true, limit: want, offset: offset)
        case .saved(let id):
            fetched = try model.savedSearches.items(matching: id, limit: want, offset: offset)
        }

        let items = Array(fetched.prefix(pageSize))
        return Page(items: items, nextOffset: offset + items.count, hasMore: fetched.count > pageSize)
    }

    static func meta(model: LibraryModel, for items: [ModelItem]) -> [String: RowMeta] {
        var result: [String: RowMeta] = [:]
        for item in items {
            let people = ((try? model.creators.creators(of: item.id)) ?? [])
                .filter { $0.role == .author }
                .map { $0.creator.family }
            let shown = people.prefix(3).joined(separator: ", ")
            let authors = people.count > 3 ? shown + " et al." : shown
            let tags = ((try? model.tags.tags(of: item.id)) ?? []).map { $0.name }
            result[item.id] = RowMeta(authors: authors, tags: tags)
        }
        return result
    }

    static func rules(forText raw: String) -> [SearchRule]? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ["title", "abstract", "venue"].map {
            SearchRule(field: $0, op: "contains", value: .text(text))
        }
    }
}

// MARK: - Browser (SQLite mode)

struct RBA70LibraryBrowser: View {

    let model: LibraryModel
    var onSelectItem: ((String) -> Void)?

    private enum NameRequest: Equatable {
        case newFolder(parent: String?)
        case renameFolder(id: String)
        case saveSearch

        var title: String {
            switch self {
            case .newFolder: return "New collection"
            case .renameFolder: return "Rename collection"
            case .saveSearch: return "Save search"
            }
        }
        var confirm: String {
            switch self {
            case .newFolder: return "Create"
            case .renameFolder: return "Rename"
            case .saveSearch: return "Save"
            }
        }
    }

    private struct ReloadKey: Hashable {
        let scope: RBA70LibraryLogic.Scope
        let query: String
        let token: Int
    }

    @State private var folders: [RBA70LibraryLogic.FolderRow] = []
    @State private var savedSearches: [SavedSearch] = []
    @State private var scope: RBA70LibraryLogic.Scope = .all
    @State private var searchText = ""
    @State private var items: [ModelItem] = []
    @State private var meta: [String: RBA70LibraryLogic.RowMeta] = [:]
    @State private var nextOffset = 0
    @State private var hasMore = false
    @State private var totalAccepted = 0
    @State private var errorText: String?
    @State private var nameRequest: NameRequest?
    @State private var nameDraft = ""
    @State private var refreshToken = 0
    @State private var showingAddPaper = false

    private var reloadKey: ReloadKey {
        ReloadKey(scope: scope, query: searchText, token: refreshToken)
    }

    private var scopeTitle: String {
        switch scope {
        case .all:
            return "Research Library"
        case .folder(let id):
            return folders.first { $0.id == id }?.collection.name ?? "Collection"
        case .saved(let id):
            return savedSearches.first { $0.id == id }?.name ?? "Saved search"
        }
    }

    var body: some View {

        HStack(spacing: 0) {

            sidebar
                .frame(width: 230)

            Divider().overlay(RBColor.border)

            VStack(spacing: 0) {
                header
                if let errorText {
                    Text(errorText)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.warning)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().overlay(RBColor.border)
                list
                footer
            }
        }
        .sheet(isPresented: $showingAddPaper) { AddPaperView() }
        .alert(
            nameRequest?.title ?? "",
            isPresented: Binding(
                get: { nameRequest != nil },
                set: { if !$0 { nameRequest = nil } }
            )
        ) {
            TextField("Name", text: $nameDraft)
            Button(nameRequest?.confirm ?? "OK") { commitName() }
            Button("Cancel", role: .cancel) { nameRequest = nil }
        }
        .onAppear { refreshSidebar() }
        .task(id: reloadKey) {
            if !searchText.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            reload()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {

                sidebarRow(title: "All papers", icon: "books.vertical", depth: 0,
                           selected: scope == .all) { scope = .all }

                HStack {
                    Text("COLLECTIONS")
                        .font(RBFont.label(.medium))
                        .foregroundStyle(RBColor.mutedText)
                    Spacer()
                    Button {
                        nameDraft = ""
                        nameRequest = .newFolder(parent: nil)
                    } label: {
                        Image(systemName: "plus").foregroundStyle(RBColor.secondaryText)
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                }
                .padding(.top, 14)
                .padding(.horizontal, 8)

                ForEach(folders) { row in
                    sidebarRow(title: row.collection.name, icon: "folder", depth: row.depth,
                               selected: scope == .folder(row.id)) { scope = .folder(row.id) }
                        .contextMenu {
                            Button("New subcollection") {
                                nameDraft = ""
                                nameRequest = .newFolder(parent: row.id)
                            }
                            Button("Rename") {
                                nameDraft = row.collection.name
                                nameRequest = .renameFolder(id: row.id)
                            }
                        }
                }

                Text("SAVED SEARCHES")
                    .font(RBFont.label(.medium))
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.top, 14)
                    .padding(.horizontal, 8)

                ForEach(savedSearches, id: \.id) { saved in
                    sidebarRow(title: saved.name, icon: "line.3.horizontal.decrease.circle", depth: 0,
                               selected: scope == .saved(saved.id)) { scope = .saved(saved.id) }
                        .contextMenu {
                            Button("Delete saved search", role: .destructive) { deleteSaved(saved.id) }
                        }
                }
            }
            .padding(12)
        }
        .background(RBColor.surface)
    }

    private func sidebarRow(
        title: String,
        icon: String,
        depth: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {

        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(selected ? RBColor.accent : RBColor.mutedText)
                Text(title)
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(selected ? RBColor.primaryText : RBColor.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(8 + depth * 14))
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(selected ? RBColor.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(RBHoverPlainButtonStyle())
    }

    // MARK: Header and footer

    private var header: some View {

        HStack(spacing: 12) {

            VStack(alignment: .leading, spacing: 4) {
                Text(scopeTitle)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)
                Text("\(totalAccepted) papers in your library")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RBColor.mutedText)
                TextField("Search papers...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(RBColor.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 150, idealWidth: 240, maxWidth: 240)
            .background(RBColor.card)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border))

            if RBA70LibraryLogic.rules(forText: searchText) != nil {
                Button {
                    nameDraft = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    nameRequest = .saveSearch
                } label: {
                    Label("Save search", systemImage: "bookmark")
                }
            }

            Button { showingAddPaper = true } label: {
                Label("Add Paper", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var footer: some View {

        let shown = items.count
        let text: String
        if searchText.isEmpty && scope == .all {
            text = "Showing \(shown) of \(totalAccepted)" + (hasMore ? " · loads as you scroll" : "")
        } else {
            text = "Showing \(shown)" + (hasMore ? " · loads as you scroll" : "")
        }

        return Text(text)
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {

        if items.isEmpty {

            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "books.vertical")
                    .font(.system(size: 42))
                    .foregroundStyle(RBColor.mutedText)
                Text(searchText.isEmpty && scope == .all ? "Your research library is empty" : "No papers found")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text(searchText.isEmpty && scope == .all
                     ? "Add your first research paper to get started."
                     : "Try another search, collection or saved search.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity)

        } else {

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(items, id: \.id) { item in
                        row(item)
                            .onAppear {
                                if item.id == items.last?.id { loadMore() }
                            }
                    }
                }
                .rbResponsiveContentPadding()
            }
        }
    }

    private func row(_ item: ModelItem) -> some View {

        let info = meta[item.id]
        let authors = info?.authors ?? ""

        return Button {
            onSelectItem?(item.id)
        } label: {
            HStack(alignment: .top, spacing: 16) {

                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(RBColor.surface)
                    Image(systemName: "doc.richtext")
                        .font(RBFont.detail())
                        .foregroundStyle(RBColor.accent)
                }
                .frame(width: 52, height: 64)

                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title)
                        .font(RBFont.section(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(2)
                    Text(authors.isEmpty ? "Unknown authors" : authors)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                    HStack(spacing: 8) {
                        if !item.venue.isEmpty { Text(item.venue) }
                        if let year = item.year {
                            Text("•").foregroundStyle(RBColor.mutedText)
                            Text(String(year))
                        }
                        Text("•").foregroundStyle(RBColor.mutedText)
                        Text(item.readingStatus.rawValue.capitalized)
                            .foregroundStyle(statusColor(item.readingStatus))
                    }
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)

                    if let tags = info?.tags, !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags.prefix(4), id: \.self) { tag in
                                Text(tag)
                                    .font(RBFont.label(.medium))
                                    .foregroundStyle(RBColor.secondaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(RBColor.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if item.rating > 0 {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { index in
                                Image(systemName: index <= item.rating ? "star.fill" : "star")
                                    .font(RBFont.label())
                                    .foregroundStyle(index <= item.rating ? RBColor.warning : RBColor.mutedText)
                            }
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
            }
            .padding(18)
            .background(RBColor.card)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RBHoverPlainButtonStyle())
        .contextMenu {
            Menu("Add to collection") {
                ForEach(folders) { folder in
                    Button(String(repeating: "  ", count: folder.depth) + folder.collection.name) {
                        addToFolder(item.id, folder.id)
                    }
                }
            }
            .disabled(folders.isEmpty)

            if case .folder(let folderID) = scope {
                Button("Remove from this collection") { removeFromFolder(item.id, folderID) }
            }
        }
    }

    private func statusColor(_ status: ItemReadingStatus) -> Color {
        switch status {
        case .unread: return RBColor.mutedText
        case .reading: return RBColor.warning
        case .read: return RBColor.accent
        }
    }

    // MARK: Data

    private func refreshSidebar() {
        do {
            folders = try RBA70LibraryLogic.flattenFolders(model)
            savedSearches = try model.savedSearches.all()
            totalAccepted = try model.items.count(reviewState: .accepted)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reload() {
        do {
            let page = try RBA70LibraryLogic.page(model: model, scope: scope, query: searchText, offset: 0)
            items = page.items
            meta = RBA70LibraryLogic.meta(model: model, for: page.items)
            nextOffset = page.nextOffset
            hasMore = page.hasMore
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadMore() {
        guard hasMore else { return }
        do {
            let page = try RBA70LibraryLogic.page(model: model, scope: scope, query: searchText, offset: nextOffset)
            items.append(contentsOf: page.items)
            meta.merge(RBA70LibraryLogic.meta(model: model, for: page.items)) { _, new in new }
            nextOffset = page.nextOffset
            hasMore = page.hasMore
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func commitName() {
        guard let request = nameRequest else { return }
        let name = nameDraft
        nameRequest = nil
        do {
            switch request {
            case .newFolder(let parent):
                _ = try model.collections.create(name: name, parentID: parent)
            case .renameFolder(let id):
                _ = try model.collections.rename(id: id, to: name)
            case .saveSearch:
                guard let rules = RBA70LibraryLogic.rules(forText: searchText) else { return }
                let saved = try model.savedSearches.create(name: name, rules: rules, matchAll: false)
                searchText = ""
                scope = .saved(saved.id)
            }
            errorText = nil
            refreshSidebar()
            refreshToken += 1
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteSaved(_ id: String) {
        do {
            try model.savedSearches.remove(id: id)
            if scope == .saved(id) { scope = .all }
            refreshSidebar()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addToFolder(_ itemID: String, _ folderID: String) {
        do { try model.collections.addItem(itemID, to: folderID); errorText = nil }
        catch { errorText = error.localizedDescription }
    }

    private func removeFromFolder(_ itemID: String, _ folderID: String) {
        do {
            try model.collections.removeItem(itemID, from: folderID)
            refreshToken += 1
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct LibraryView: View {

    @Environment(\.modelContext)
    private var modelContext

    @Environment(\.rbA70LibraryModel)
    private var rbA70Model

    @Query(
        sort: [
            SortDescriptor(
                \PaperRecord.addedAt,
                order: .reverse
            )
        ]
    )
    private var paperRecords: [PaperRecord]

    @State private var searchText = ""
    @State private var selectedFilter = "All"

    @State private var showingAddPaper = false

    // Sends the selected paper to ContentView
    let onSelectPaper: (PaperRecord) -> Void

    /// Used only in SQLite mode (when a LibraryModel is injected).
    var onSelectItem: ((String) -> Void)? = nil

    private let filters = [
        "All",
        "Unread",
        "Reading",
        "Read"
    ]


    // =========================================================
    // FILTERED PAPERS
    // =========================================================

    private var filteredPapers: [PaperRecord] {

        paperRecords.filter { paper in

            let trimmedSearch =
                searchText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            let matchesSearch: Bool

            if trimmedSearch.isEmpty {

                matchesSearch = true

            } else {

                let query =
                    trimmedSearch.lowercased()

                matchesSearch =
                    paper.title
                        .lowercased()
                        .contains(query)
                    ||
                    paper.authors
                        .lowercased()
                        .contains(query)
                    ||
                    paper.venue
                        .lowercased()
                        .contains(query)
                    ||
                    paper.tagsText
                        .lowercased()
                        .contains(query)
            }


            let matchesFilter: Bool

            if selectedFilter == "All" {

                matchesFilter = true

            } else {

                matchesFilter =
                    paper.statusRawValue ==
                    selectedFilter
            }


            return matchesSearch &&
                   matchesFilter
        }
    }


    // =========================================================
    // BODY
    // =========================================================

    var body: some View {

        if let model = rbA70Model {

            RBA70LibraryBrowser(
                model: model,
                onSelectItem: onSelectItem
            )

        } else {

            legacyBody
        }
    }

    private var legacyBody: some View {

        VStack(
            spacing: 0
        ) {

            header

            filterBar

            Divider()
                .overlay(
                    RBColor.border
                )


            if filteredPapers.isEmpty {

                emptyState

            } else {

                ScrollView {

                    LazyVStack(
                        spacing: 12
                    ) {

                        ForEach(
                            filteredPapers
                        ) { paper in

                            paperCard(
                                paper
                            )
                        }
                    }
                    .rbResponsiveContentPadding()
                }
            }
        }
        .sheet(
            isPresented:
                $showingAddPaper
        ) {

            AddPaperView()
        }
        .onAppear {

            diagnosticFetch()
        }
        .onChange(
            of: paperRecords.count
        ) { _, newCount in

            Swift.print(
                "ResearchBase: @Query paper count changed to \(newCount)"
            )

            for record in paperRecords {

                Swift.print(
                    "ResearchBase: @Query found = \(record.title)"
                )
            }
        }
    }


    // =========================================================
    // DIAGNOSTIC FETCH
    // =========================================================

    private func diagnosticFetch() {

        let descriptor =
            FetchDescriptor<PaperRecord>()

        do {

            let records =
                try modelContext.fetch(
                    descriptor
                )

            Swift.print(
                "ResearchBase: Library fetch count = \(records.count)"
            )

            for record in records {

                Swift.print(
                    "ResearchBase: Library found = \(record.title)"
                )

                Swift.print(
                    "ResearchBase: PDF = \(record.pdfFilePath)"
                )

                Swift.print(
                    "ResearchBase: Status = \(record.statusRawValue)"
                )

                Swift.print(
                    "ResearchBase: Added = \(record.addedAt)"
                )
            }

        } catch {

            Swift.print(
                "ResearchBase: Library fetch FAILED = \(error)"
            )
        }
    }


    // =========================================================
    // HEADER
    // =========================================================

    private var header: some View {

        HStack {

            VStack(
                alignment: .leading,
                spacing: 4
            ) {

                Text(
                    "Research Library"
                )
                .font(
                    .system(
                        size: 30,
                        weight: .semibold
                    )
                )
                .foregroundStyle(
                    RBColor.primaryText
                )

                Text(
                    "\(paperRecords.count) papers in your library"
                )
                .font(RBFont.body())
                .foregroundStyle(
                    RBColor.secondaryText
                )
            }

            Spacer()


            Button {

                showingAddPaper = true

            } label: {

                Label(
                    "Add Paper",
                    systemImage: "plus"
                )
            }
            .buttonStyle(
                .borderedProminent
            )
        }
        .padding(
            .horizontal,
            28
        )
        .padding(
            .vertical,
            24
        )
    }


    // =========================================================
    // FILTER BAR
    // =========================================================

    private var filterBar: some View {

        HStack(
            spacing: 8
        ) {

            ForEach(
                filters,
                id: \.self
            ) { filter in

                Button {

                    selectedFilter =
                        filter

                } label: {

                    Text(filter)
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(
                            selectedFilter == filter
                            ? RBColor.primaryText
                            : RBColor.secondaryText
                        )
                        .padding(
                            .horizontal,
                            12
                        )
                        .padding(
                            .vertical,
                            7
                        )
                        .background(
                            selectedFilter == filter
                            ? RBColor.hover
                            : Color.clear
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 7
                            )
                        )
                }
                .buttonStyle(
                    .plain
                )
            }


            Spacer()


            HStack(
                spacing: 8
            ) {

                Image(
                    systemName:
                        "magnifyingglass"
                )
                .foregroundStyle(
                    RBColor.mutedText
                )

                TextField(
                    "Search papers...",
                    text: $searchText
                )
                .textFieldStyle(
                    .plain
                )
                .foregroundStyle(
                    RBColor.primaryText
                )
            }
            .padding(
                .horizontal,
                12
            )
            .padding(
                .vertical,
                8
            )
            .frame(
                minWidth: 150,
                idealWidth: 250,
                maxWidth: 250
            )
            .background(
                RBColor.card
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 8
                )
                .stroke(
                    RBColor.border
                )
            )
        }
        .padding(
            .horizontal,
            24
        )
        .padding(
            .bottom,
            16
        )
    }


    // =========================================================
    // PAPER CARD
    // =========================================================

    private func paperCard(
        _ paper: PaperRecord
    ) -> some View {

        Button {

            onSelectPaper(
                paper
            )

        } label: {

            HStack(
                alignment: .top,
                spacing: 16
            ) {

                ZStack {

                    RoundedRectangle(
                        cornerRadius: 9
                    )
                    .fill(
                        RBColor.surface
                    )

                    Image(
                        systemName:
                            "doc.richtext"
                    )
                    .font(RBFont.detail())
                    .foregroundStyle(
                        RBColor.accent
                    )
                }
                .frame(
                    width: 52,
                    height: 64
                )


                VStack(
                    alignment: .leading,
                    spacing: 7
                ) {

                    Text(
                        paper.title
                    )
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )
                    .lineLimit(2)


                    Text(
                        paper.authors.isEmpty
                        ? "Unknown authors"
                        : paper.authors
                    )
                    .font(RBFont.secondary())
                    .foregroundStyle(
                        RBColor.secondaryText
                    )


                    HStack(
                        spacing: 8
                    ) {

                        if !paper.venue.isEmpty {

                            Text(
                                paper.venue
                            )
                        }

                        if paper.year > 0 {

                            Text("•")
                                .foregroundStyle(
                                    RBColor.mutedText
                                )

                            Text(
                                String(
                                    paper.year
                                )
                            )
                        }

                        Text("•")
                            .foregroundStyle(
                                RBColor.mutedText
                            )

                        Text(
                            paper.statusRawValue
                        )
                        .foregroundStyle(
                            statusColor(
                                paper.readingStatus
                            )
                        )
                    }
                    .font(RBFont.caption())
                    .foregroundStyle(
                        RBColor.secondaryText
                    )


                    if !paper.tags.isEmpty {

                        HStack(
                            spacing: 6
                        ) {

                            ForEach(
                                paper.tags.prefix(4),
                                id: \.self
                            ) { tag in

                                Text(tag)
                                    .font(RBFont.label(.medium))
                                    .foregroundStyle(
                                        RBColor.secondaryText
                                    )
                                    .padding(
                                        .horizontal,
                                        7
                                    )
                                    .padding(
                                        .vertical,
                                        4
                                    )
                                    .background(
                                        RBColor.surface
                                    )
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 5
                                        )
                                    )
                            }
                        }
                    }
                }


                Spacer()


                VStack(
                    alignment: .trailing,
                    spacing: 8
                ) {

                    if paper.rating > 0 {

                        HStack(
                            spacing: 2
                        ) {

                            ForEach(
                                1...5,
                                id: \.self
                            ) { index in

                                Image(
                                    systemName:
                                        index <= paper.rating
                                        ? "star.fill"
                                        : "star"
                                )
                                .font(RBFont.label())
                                .foregroundStyle(
                                    index <= paper.rating
                                    ? RBColor.warning
                                    : RBColor.mutedText
                                )
                            }
                        }
                    }


                    Image(
                        systemName:
                            "chevron.right"
                    )
                    .font(RBFont.caption())
                    .foregroundStyle(
                        RBColor.mutedText
                    )
                }
            }
            .padding(18)
            .background(
                RBColor.card
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: 10
                )
                .stroke(
                    RBColor.border
                )
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 10
                )
            )
        }
        .buttonStyle(
            .plain
        )
    }


    // =========================================================
    // EMPTY STATE
    // =========================================================

    private var emptyState: some View {

        VStack(
            spacing: 16
        ) {

            Spacer()


            Image(
                systemName:
                    "books.vertical"
            )
            .font(
                .system(size: 42)
            )
            .foregroundStyle(
                RBColor.mutedText
            )


            Text(
                searchText.isEmpty &&
                selectedFilter == "All"
                ? "Your research library is empty"
                : "No papers found"
            )
            .font(RBFont.detail(.semibold))
            .foregroundStyle(
                RBColor.primaryText
            )


            Text(
                searchText.isEmpty &&
                selectedFilter == "All"
                ? "Add your first research paper to get started."
                : "Try changing your search or filter."
            )
            .font(RBFont.body())
            .foregroundStyle(
                RBColor.secondaryText
            )


            if searchText.isEmpty &&
                selectedFilter == "All" {

                Button("Add Paper") {

                    showingAddPaper = true
                }
                .buttonStyle(
                    .borderedProminent
                )
            }


            Spacer()
        }
        .frame(
            maxWidth: .infinity
        )
    }


    // =========================================================
    // STATUS COLOR
    // =========================================================

    private func statusColor(
        _ status: ReadingStatus
    ) -> Color {

        switch status {

        case .unread:

            return RBColor.secondaryText

        case .reading:

            return RBColor.accent

        case .read:

            return RBColor.success
        }
    }
}
