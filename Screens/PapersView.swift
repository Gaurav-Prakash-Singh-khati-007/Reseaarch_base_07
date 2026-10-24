//
//  PapersView.swift
//  ResearchBase
//
//  The Library screen: your research literature, read from the SQLite
//  library (D1). Folders are the library's collections (read-only here;
//  LibraryView owns creating, renaming and moving them).
//
//  Papers are stored data. Nothing here creates or deletes a paper;
//  add goes through AddPaperView, edit and delete stay in the paper
//  detail screen. Opening a paper still goes through NavigationRouter
//  (`NavigationTarget.paper`); a library item id is a UUID string, so it
//  maps straight onto that target.
//
//  Owner: Agent 69 · Features: F-28 (reading queue)
//  PUBLIC API (PapersView() still works with no arguments)
//    PapersView(libraryModel: LibraryModel? = nil)   // nil → \.rbA70LibraryModel
//    RBA69Logic, RBA69QueueCardState                 // pure queue helpers
//    RBA69Row, RBA69Folder, RBA69PDFState            // what a card / folder shows
//    RBA69Filters                                    // search, status, PDF, tag, sort
//    RBA69Folders.flatten(_:)                        // collections → indented list
//    RBA69Loader.rows(model:)                        // accepted papers + authors, tags, PDF state
//

import SwiftUI

struct PapersView: View {

    @EnvironmentObject private var router: NavigationRouter

    /// The library injected by the app (same key LibraryView uses).
    @Environment(\.rbA70LibraryModel) private var environmentModel

    /// Optional override (used by tests / previews).
    var libraryModel: LibraryModel? = nil

    private var model: LibraryModel? { libraryModel ?? environmentModel }

    @State private var rows: [RBA69Row] = []
    @State private var folders: [RBA69Folder] = []
    @State private var selectedFolderID: String? = nil
    @State private var folderItemIDs: Set<String>? = nil

    @State private var filters = RBA69Filters()
    @State private var showingAddPaper = false

    @State private var queueMode = false
    @State private var queuedIDs: [String] = []
    @State private var queueSeconds = 0
    @State private var notice: String?

    // MARK: - Derived

    /// Papers inside the chosen folder (all papers when no folder).
    private var scopedRows: [RBA69Row] {
        guard let ids = folderItemIDs else { return rows }
        return rows.filter { ids.contains($0.id) }
    }

    private var visibleRows: [RBA69Row] {

        let base = filters.apply(to: scopedRows)

        guard queueMode, model != nil else { return base }

        return RBA69Logic.ordered(base, id: { $0.id }, queueIDs: queuedIDs)
    }

    private var availableTags: [String] {
        RBA69Filters.allTags(in: scopedRows)
    }

    private var isFiltering: Bool {
        filters.isFiltering || selectedFolderID != nil
    }

    private var selectedFolderName: String? {
        folders.first(where: { $0.id == selectedFolderID })?.name
    }

    // MARK: - Body

    var body: some View {

        let papers = visibleRows

        VStack(spacing: 0) {

            VStack(alignment: .leading, spacing: 14) {
                header(shownCount: papers.count)

                if !rows.isEmpty {
                    searchAndSortRow
                    filterRow
                }
            }
            .rbResponsiveContentPadding([.horizontal, .top])
            .padding(.bottom, 14)

            Divider().overlay(RBColor.border)

            if model == nil {
                noLibraryState
            } else if rows.isEmpty {
                noPapersState
            } else if queueMode, queuedIDs.isEmpty {
                emptyQueueState
            } else if papers.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 250, maximum: 400),
                                spacing: 12,
                                alignment: .top
                            )
                        ],
                        spacing: 12
                    ) {
                        ForEach(papers) { row in
                            LibraryCard(
                                row: row,
                                queueState: queueState(for: row),
                                onOpen: { open(row) }
                            )
                        }
                    }
                    .rbResponsiveContentPadding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // D4: no full-window fill here; ContentView draws the theme behind us.
        .sheet(isPresented: $showingAddPaper, onDismiss: { reloadAll() }) {
            AddPaperView()
        }
        // Quick Add → Paper. Also runs on appear because ContentView
        // sets the request before this screen exists.
        .onAppear { consumeQuickAdd() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
        .task { reloadAll() }
        .onChange(of: queueMode) { reloadQueue() }
        .onChange(of: selectedFolderID) { reloadFolderScope() }
        .alert(
            "Library",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    /// Opens the existing Add Paper sheet for a `.paper` Quick Add
    /// request, then clears the request so it is handled exactly once.
    private func consumeQuickAdd() {
        guard router.pendingCreate == .paper else { return }
        router.pendingCreate = nil
        showingAddPaper = true
    }

    private func open(_ row: RBA69Row) {
        guard let id = UUID(uuidString: row.id) else {
            notice = "This item's id is not in the form the paper screen expects, so it can't be opened from here."
            return
        }
        router.open(.paper(id))
    }

    // MARK: - Loading (SQLite)

    private func reloadAll() {

        guard let model else {
            rows = []
            folders = []
            folderItemIDs = nil
            queuedIDs = []
            queueSeconds = 0
            return
        }

        do {
            rows = try RBA69Loader.rows(model: model)
        } catch {
            rows = []
            notice = "The library could not be read. (\(error.localizedDescription))"
        }

        folders = RBA69Folders.flatten((try? model.collections.all()) ?? [])

        // A folder that no longer exists falls back to "All papers".
        if let id = selectedFolderID, !folders.contains(where: { $0.id == id }) {
            selectedFolderID = nil
        }

        reloadFolderScope()
        reloadQueue()
    }

    private func reloadFolderScope() {

        guard let model, let id = selectedFolderID else {
            folderItemIDs = nil
            return
        }

        let items = (try? model.collections.items(
            in: id, includeSubfolders: true, limit: 5000
        )) ?? []

        folderItemIDs = Set(items.map(\.id))
    }

    // MARK: - Reading queue (F-28, Agent 69)

    private var readingQueue: ReadingQueueStore? {
        model.map { ReadingQueueStore(model: $0) }
    }

    private func reloadQueue() {

        guard let queue = readingQueue else {
            queuedIDs = []
            queueSeconds = 0
            return
        }

        queuedIDs = ((try? queue.queue()) ?? []).map(\.id)
        queueSeconds = (try? queue.stats().totalSeconds) ?? 0
    }

    private func queueState(for row: RBA69Row) -> RBA69QueueCardState? {

        guard model != nil else { return nil }

        let id = row.id
        let position = queuedIDs.firstIndex(of: id)
        let targets = RBA69Logic.moveTargets(position: position, count: queuedIDs.count)

        return RBA69QueueCardState(
            isQueued: position != nil,
            toggle: { toggleQueue(id) },
            moveUp: targets.up.map { index in { moveInQueue(id, to: index) } },
            moveDown: targets.down.map { index in { moveInQueue(id, to: index) } },
            moveToTop: targets.up == nil ? nil : { moveInQueue(id, to: 0) }
        )
    }

    private func toggleQueue(_ id: String) {

        guard let queue = readingQueue else { return }

        do {
            if queuedIDs.contains(id) {
                try queue.remove(itemID: id)
            } else {
                try queue.add(itemID: id)
            }
        } catch {
            notice = "This paper could not be added to the reading queue. (\(error.localizedDescription))"
        }

        reloadQueue()
    }

    private func moveInQueue(_ id: String, to index: Int) {

        do {
            try readingQueue?.move(itemID: id, toIndex: index)
        } catch {
            notice = error.localizedDescription
        }

        reloadQueue()
    }

    private var emptyQueueState: some View {

        VStack(spacing: 14) {

            Spacer()

            Image(systemName: "bookmark")
                .font(.system(size: 40))
                .foregroundStyle(RBColor.mutedText)

            Text("Your Reading Queue Is Empty")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("Right-click a paper and choose Add to Reading Queue.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Header

    private func header(shownCount: Int) -> some View {

        RBPageHeader(
            title: "Library",
            subtitle: subtitle(shownCount: shownCount)
        ) {
            addPaperButton
        }
    }

    private func subtitle(shownCount: Int) -> String {

        if queueMode, model != nil {
            return RBA69Logic.queueSubtitle(
                count: queuedIDs.count,
                totalSeconds: queueSeconds
            )
        }

        if rows.isEmpty {
            return "Your research literature"
        }

        if isFiltering {
            let scope = selectedFolderName.map { " in \($0)" } ?? ""
            return "Showing \(shownCount) of \(rows.count) items\(scope)"
        }

        return rows.count == 1
            ? "Your research literature · 1 item"
            : "Your research literature · \(rows.count) items"
    }

    private var addPaperButton: some View {

        Button {
            showingAddPaper = true
        } label: {
            Label("Add Literature", systemImage: "plus")
        }
        .buttonStyle(RBPrimaryButtonStyle())
        .disabled(model == nil)
    }

    // MARK: - Search + Sort

    private var searchAndSortRow: some View {

        HStack(spacing: 10) {

            RBSearchField(
                placeholder: "Search title, authors, venue, tags, abstract…",
                text: $filters.searchText
            )

            sortMenu
        }
    }

    private var sortMenu: some View {

        Menu {
            Picker("Sort by", selection: $filters.sort) {
                ForEach(PaperSortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuPill(
                title: filters.sort.rawValue,
                icon: "arrow.up.arrow.down",
                isActive: false
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort literature")
    }

    // MARK: - Filter Row

    private var filterRow: some View {

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {

                if !folders.isEmpty {
                    folderMenu
                }

                if model != nil {
                    RBChip(
                        text: "Reading queue \(queuedIDs.count)",
                        isSelected: queueMode
                    ) {
                        queueMode.toggle()
                    }
                }

                ForEach(PaperStatusFilter.allCases) { status in
                    statusChip(status)
                }

                Divider()
                    .frame(height: 16)
                    .overlay(RBColor.border)

                pdfMenu

                if !availableTags.isEmpty {
                    tagMenu
                }

                if isFiltering {
                    Divider()
                        .frame(height: 16)
                        .overlay(RBColor.border)

                    Button("Clear Filters") {
                        clearFilters()
                    }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.accent)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func clearFilters() {
        filters.reset()
        selectedFolderID = nil
    }

    private func statusChip(_ status: PaperStatusFilter) -> some View {

        let count = RBA69Filters.count(for: status, in: scopedRows)

        return RBChip(
            text: "\(status.libraryLabel) \(count)",
            isSelected: filters.status == status
        ) {
            filters.status = status
        }
    }

    /// Folders = the library's collections, shown as an indented list.
    private var folderMenu: some View {

        Menu {
            Button {
                selectedFolderID = nil
            } label: {
                if selectedFolderID == nil {
                    Label("All Papers", systemImage: "checkmark")
                } else {
                    Text("All Papers")
                }
            }

            Divider()

            ForEach(folders) { folder in
                Button {
                    selectedFolderID = folder.id
                } label: {
                    let name = String(repeating: "    ", count: folder.depth) + folder.name
                    if selectedFolderID == folder.id {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            menuPill(
                title: selectedFolderName ?? "Folders",
                icon: "folder",
                isActive: selectedFolderID != nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show one folder (includes its subfolders)")
    }

    private var pdfMenu: some View {

        Menu {
            Picker("PDF", selection: $filters.pdf) {
                ForEach(PaperPDFFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            menuPill(
                title: filters.pdf == .any ? "PDF" : filters.pdf.rawValue,
                icon: "doc",
                isActive: filters.pdf != .any
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by PDF availability")
    }

    private var tagMenu: some View {

        Menu {
            Button {
                filters.tag = nil
            } label: {
                if filters.tag == nil {
                    Label("All Tags", systemImage: "checkmark")
                } else {
                    Text("All Tags")
                }
            }

            Divider()

            ForEach(availableTags, id: \.self) { tag in
                Button {
                    filters.tag = tag
                } label: {
                    if filters.tag?.caseInsensitiveCompare(tag) == .orderedSame {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
        } label: {
            menuPill(
                title: filters.tag ?? "Tags",
                icon: "tag",
                isActive: filters.tag != nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by tag")
    }

    private func menuPill(
        title: String,
        icon: String,
        isActive: Bool
    ) -> some View {

        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(RBFont.secondary(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(isActive ? RBColor.accent : RBColor.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? RBColor.accent.opacity(0.14) : RBColor.card)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.field)
                .stroke(RBColor.border)
        )
    }

    // MARK: - Empty States

    /// Shown when the library database is not open.
    private var noLibraryState: some View {

        VStack(spacing: 14) {

            Spacer()

            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(RBColor.mutedText)

            Text("Library Not Available")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("The library database is not open, so papers can't be shown. Restart the app; if this stays, check Settings → Data.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Shown when the library has no literature at all.
    private var noPapersState: some View {

        VStack(spacing: 14) {

            Spacer()

            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(RBColor.mutedText)

            Text("No Literature Yet")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("Add your first paper to start building your library.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)

            addPaperButton
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    /// Shown when papers exist but the folder / search / filters hide them all.
    private var noMatchesState: some View {

        VStack(spacing: 14) {

            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(RBColor.mutedText)

            Text("No Matching Literature")
                .font(RBFont.detail(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text(selectedFolderID != nil
                 ? "None of the papers in this folder match the current search or filters."
                 : "None of your \(rows.count) items match the current search or filters.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)

            Button("Clear Filters") {
                clearFilters()
            }
            .buttonStyle(RBGhostButtonStyle())

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Library Card

/// One literature item in the grid (HTML `.lcard`): type, year and
/// venue on top, then title, authors, tags, and a footer with the
/// reading status. Everything shown is read from the SQLite library.
private struct LibraryCard: View {

    let row: RBA69Row
    /// F-28: nil when there is no library, so nothing queue-related shows.
    var queueState: RBA69QueueCardState? = nil
    let onOpen: () -> Void

    private var item: ModelItem { row.item }

    var body: some View {

        Button(action: onOpen) {

            VStack(alignment: .leading, spacing: 8) {

                topLine

                Text(item.title.isEmpty ? "Untitled paper" : item.title)
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Text(row.authors.isEmpty ? "Unknown authors" : row.authors)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)

                if !row.tags.isEmpty {
                    tagRow
                }

                Spacer(minLength: 4)

                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
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
        .contextMenu {
            if let queueState {

                Button(
                    queueState.isQueued
                        ? "Remove from Reading Queue"
                        : "Add to Reading Queue",
                    action: queueState.toggle
                )

                if queueState.isQueued {

                    if let moveToTop = queueState.moveToTop {
                        Button("Move to Top of Queue", action: moveToTop)
                    }
                    if let moveUp = queueState.moveUp {
                        Button("Move Up in Queue", action: moveUp)
                    }
                    if let moveDown = queueState.moveDown {
                        Button("Move Down in Queue", action: moveDown)
                    }
                }
            }
        }
    }

    // MARK: Top line — type on the left, year · venue on the right

    private var topLine: some View {

        HStack(spacing: 6) {

            HStack(spacing: 4) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 10))
                Text(item.type.displayName)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(yearAndVenue)
                .lineLimit(1)
        }
        .font(RBFont.label(.medium))
        .foregroundStyle(RBColor.mutedText)
    }

    private var yearAndVenue: String {

        let venue = item.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        return [
            (item.year ?? 0) > 0 ? String(item.year ?? 0) : "",
            venue
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    // MARK: Tags

    private var tagRow: some View {

        HStack(spacing: 5) {

            ForEach(Array(row.tags.prefix(3)), id: \.self) { tag in
                Text("#\(tag)")
                    .font(RBFont.label(.medium))
                    .foregroundStyle(RBColor.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RBColor.accent.opacity(0.10))
                    .clipShape(Capsule())
            }

            if row.tags.count > 3 {
                Text("+\(row.tags.count - 3)")
                    .font(RBFont.label())
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    // MARK: Footer — status badge

    private var footer: some View {

        HStack(spacing: 8) {

            RBBadge(
                text: RBA69Filters.statusLabel(item.readingStatus),
                tone: statusTone
            )

            if queueState?.isQueued == true {
                RBBadge(text: "Queued", tone: .accent, icon: "bookmark.fill")
            }

            if row.pdf == .missing {
                RBBadge(
                    text: "PDF missing",
                    tone: .warning,
                    icon: "exclamationmark.triangle.fill"
                )
            }

            Spacer(minLength: 4)
        }
    }

    private var statusTone: RBBadgeTone {
        switch item.readingStatus {
        case .unread: return .neutral
        case .reading: return .accent
        case .read: return .ok
        }
    }
}

// =============================================================
// F-28 HELPERS (Agent 69)
// =============================================================

/// What a card needs to offer queue actions.
struct RBA69QueueCardState {
    var isQueued: Bool
    var toggle: () -> Void
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var moveToTop: (() -> Void)?
}

enum RBA69Logic {

    /// Only queued items, in queue order. Unknown ids and repeats are ignored.
    static func ordered<T>(
        _ items: [T],
        id: (T) -> String,
        queueIDs: [String]
    ) -> [T] {

        var byID: [String: T] = [:]
        for item in items { byID[id(item)] = item }

        var seen = Set<String>()
        var result: [T] = []

        for queued in queueIDs where seen.insert(queued).inserted {
            if let item = byID[queued] { result.append(item) }
        }

        return result
    }

    /// Where "Move Up" / "Move Down" would put an item (nil = can't move).
    static func moveTargets(position: Int?, count: Int) -> (up: Int?, down: Int?) {

        guard let position, position >= 0, position < count else { return (nil, nil) }

        return (
            position > 0 ? position - 1 : nil,
            position < count - 1 ? position + 1 : nil
        )
    }

    static func formatDuration(seconds: Int) -> String {

        let minutes = max(0, seconds) / 60

        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }

        let hours = minutes / 60
        let rest = minutes % 60

        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func queueSubtitle(count: Int, totalSeconds: Int) -> String {

        var text: String

        switch count {
        case 0: text = "Reading queue · nothing to read"
        case 1: text = "Reading queue · 1 paper to read"
        default: text = "Reading queue · \(count) papers to read"
        }

        if totalSeconds >= 60 {
            text += " · \(formatDuration(seconds: totalSeconds)) read in total"
        }

        return text
    }
}


// =============================================================
// SQLITE-BACKED LIST (D1) — pure helpers, unit-tested
// =============================================================

/// What a PDF attachment looks like right now.
enum RBA69PDFState: Equatable {
    /// A PDF attachment exists and its file is on disk.
    case available
    /// A PDF attachment is recorded but its file cannot be found.
    case missing
    /// No PDF was ever attached.
    case none
}

/// One paper as the grid shows it.
struct RBA69Row: Identifiable, Equatable {
    var item: ModelItem
    var authors: String
    var tags: [String]
    var pdf: RBA69PDFState

    var id: String { item.id }
}

/// One collection in the folder menu, already in display order.
struct RBA69Folder: Identifiable, Equatable {
    var id: String
    var name: String
    var depth: Int
}

enum RBA69Folders {

    /// Parent first, children right after, siblings by position then name.
    /// A collection whose parent is unknown is shown as a top-level folder,
    /// and a loop in the data cannot repeat or hang the list.
    static func flatten(_ collections: [ModelCollection]) -> [RBA69Folder] {

        let live = collections.filter { $0.deletedAt == nil }
        let known = Set(live.map(\.id))

        func order(_ a: ModelCollection, _ b: ModelCollection) -> Bool {
            a.position != b.position
                ? a.position < b.position
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        var children: [String?: [ModelCollection]] = [:]
        for c in live {
            let parent = c.parentID.flatMap { known.contains($0) ? $0 : nil }
            children[parent, default: []].append(c)
        }

        var result: [RBA69Folder] = []
        var visited = Set<String>()

        func walk(_ parent: String?, depth: Int) {
            for c in (children[parent] ?? []).sorted(by: order) where visited.insert(c.id).inserted {
                result.append(RBA69Folder(id: c.id, name: c.name, depth: depth))
                walk(c.id, depth: depth + 1)
            }
        }

        walk(nil, depth: 0)
        return result
    }
}

enum RBA69Loader {

    /// Accepted (non-Inbox, non-trashed) papers, newest first, with their
    /// authors, tags and PDF state. Pages through the library so more than
    /// 200 papers are all shown (up to `cap`).
    static func rows(model: LibraryModel, cap: Int = 5000) throws -> [RBA69Row] {

        var items: [ModelItem] = []
        var offset = 0
        let page = 200

        while items.count < cap {
            let chunk = try model.items.list(reviewState: .accepted, limit: page, offset: offset)
            items += chunk
            if chunk.count < page { break }
            offset += page
        }

        return items.map { row(for: $0, model: model) }
    }

    static func row(for item: ModelItem, model: LibraryModel) -> RBA69Row {

        let creators = (try? model.creators.creators(of: item.id)) ?? []
        let authors = creators.filter { $0.role == .author }
        let names = (authors.isEmpty ? creators : authors).map { $0.creator.displayName }

        let tags = ((try? model.tags.tags(of: item.id)) ?? []).map(\.name)

        let pdfs = ((try? model.attachments.attachments(of: item.id)) ?? [])
            .filter { $0.kind == .pdf }

        var pdf: RBA69PDFState = .none
        if !pdfs.isEmpty {
            pdf = .missing
            for attachment in pdfs {
                if let url = try? model.attachments.fileURL(for: attachment),
                   FileManager.default.fileExists(atPath: url.path) {
                    pdf = .available
                    break
                }
            }
        }

        return RBA69Row(
            item: item,
            authors: names.joined(separator: "; "),
            tags: tags,
            pdf: pdf
        )
    }
}

/// Search, status, PDF, tag and sort for `RBA69Row`s. Same behaviour as the
/// old SwiftData filter, using the shared option enums (PaperListFilters.swift).
struct RBA69Filters: Equatable {

    var searchText: String = ""
    var status: PaperStatusFilter = .all
    var pdf: PaperPDFFilter = .any
    var tag: String? = nil
    var sort: PaperSortOption = .recentlyAdded

    /// Sorting alone does not count as filtering.
    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status != .all
            || pdf != .any
            || tag != nil
    }

    mutating func reset() {
        searchText = ""
        status = .all
        pdf = .any
        tag = nil
    }

    static func statusLabel(_ status: ItemReadingStatus) -> String {
        switch status {
        case .unread: return PaperStatusFilter.unread.libraryLabel
        case .reading: return PaperStatusFilter.reading.libraryLabel
        case .read: return PaperStatusFilter.read.libraryLabel
        }
    }

    static func matches(_ filter: PaperStatusFilter, _ status: ItemReadingStatus) -> Bool {
        switch filter {
        case .all: return true
        case .unread: return status == .unread
        case .reading: return status == .reading
        case .read: return status == .read
        }
    }

    static func count(for filter: PaperStatusFilter, in rows: [RBA69Row]) -> Int {
        rows.filter { matches(filter, $0.item.readingStatus) }.count
    }

    static func allTags(in rows: [RBA69Row]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in rows.flatMap(\.tags) where seen.insert(tag.lowercased()).inserted {
            result.append(tag)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func apply(to rows: [RBA69Row]) -> [RBA69Row] {

        let terms = searchText
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let filtered = rows.filter { row in

            guard Self.matches(status, row.item.readingStatus) else { return false }

            if let selected = tag {
                let has = row.tags.contains { $0.caseInsensitiveCompare(selected) == .orderedSame }
                if !has { return false }
            }

            switch pdf {
            case .any: break
            case .withPDF: if row.pdf != .available { return false }
            case .withoutPDF: if row.pdf == .available { return false }
            }

            if !terms.isEmpty {
                let haystack = Self.searchableText(for: row)
                for term in terms where !haystack.contains(term) { return false }
            }

            return true
        }

        return sorted(filtered)
    }

    private static func searchableText(for row: RBA69Row) -> String {
        [
            row.item.title,
            row.authors,
            row.item.venue,
            row.tags.joined(separator: " "),
            row.item.abstract,
            row.item.doi ?? "",
            row.item.citationKey
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func sorted(_ rows: [RBA69Row]) -> [RBA69Row] {

        func titleOrder(_ a: RBA69Row, _ b: RBA69Row) -> Bool {
            a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
        }

        func year(_ r: RBA69Row) -> Int { max(r.item.year ?? 0, 0) }

        switch sort {

        case .recentlyAdded:
            return rows.sorted {
                $0.item.addedAt != $1.item.addedAt
                    ? $0.item.addedAt > $1.item.addedAt
                    : titleOrder($0, $1)
            }

        case .recentlyOpened:
            // The library has no "last opened" column, so this uses the
            // last time the item changed (BLOCKED for a true "opened" time).
            return rows.sorted {
                $0.item.updatedAt != $1.item.updatedAt
                    ? $0.item.updatedAt > $1.item.updatedAt
                    : titleOrder($0, $1)
            }

        case .titleAZ:
            return rows.sorted(by: titleOrder)

        case .yearNewest:
            // Papers with no year go last.
            return rows.sorted {
                let a = year($0), b = year($1)
                if a != b {
                    if a == 0 { return false }
                    if b == 0 { return true }
                    return a > b
                }
                return titleOrder($0, $1)
            }

        case .yearOldest:
            return rows.sorted {
                let a = year($0), b = year($1)
                if a != b {
                    if a == 0 { return false }
                    if b == 0 { return true }
                    return a < b
                }
                return titleOrder($0, $1)
            }

        case .highestRated:
            return rows.sorted {
                $0.item.rating != $1.item.rating
                    ? $0.item.rating > $1.item.rating
                    : titleOrder($0, $1)
            }
        }
    }
}
