//
//  CommandPaletteSheet.swift
//  ResearchBase
//
//  Owner: Agent 60 · Features: command palette (E-02) with real paper search (F-22)
//  Source of truth: docs/researchbase.html (E-02, Command palette)
//  Global shortcut ⌘K opens this overlay anywhere in the app.
//
//  What it does now
//    * Commands are ranked (exact, starts with, word starts with, contains, keyword, letters in order),
//      so "back" finds "Back up now" and "theme" finds "Switch theme".
//    * With the library open, paper titles are searched as you type (SearchService.suggestTitles, #14)
//      and shown under the commands. Inbox papers and the Trash are not offered.
//    * Last row: "Search everything for …" (full text, F-22).
//    * Keyboard: ↑ ↓ move, Return runs the highlighted row, Esc closes.
//
//  PUBLIC API (the original call still compiles: CommandPaletteSheet(onDismiss:onSelectCommand:))
//    CommandPaletteSheet(onDismiss:onSelectCommand:model:onOpenPaper:onSearchAll:)
//      onSelectCommand   called with the same ids as before: library, writing, search, quickAdd, addPaper,
//                        buildDraft, insertCitation, integrityCheck, backupNow, switchTheme, trash
//      model             the open library. Nil = commands only (no paper results)
//      onOpenPaper       called with the item id. If nil: onSelectCommand("paper:<id>") instead
//      onSearchAll       called with the typed text. If nil: onSelectCommand("search") instead
//    CommandPaletteItem   unchanged, plus an optional `keywords` list
//    PaletteLogic         pure ranking helpers
//
//  Reads (does not edit): SearchService, LibraryModel.
//

import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id = UUID()
    let title: String
    let iconName: String
    let shortcut: String
    var keywords: [String] = []
    let action: () -> Void
}

// MARK: - Pure ranking (unit-tested in CommandPaletteSheetTests)

enum PaletteLogic {

    /// Lower is better, nil = no match. Every word of the query must match somewhere.
    static func rank(title: String, keywords: [String] = [], query: String) -> Int? {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return 0 }

        let lowerTitle = title.lowercased()
        let lowerKeywords = keywords.map { $0.lowercased() }
        var worst = 0
        for token in tokens {
            guard let score = rank(token: token, title: lowerTitle, keywords: lowerKeywords) else { return nil }
            worst = max(worst, score)
        }
        // A query that is exactly the title beats everything.
        if lowerTitle == query.lowercased().trimmingCharacters(in: .whitespaces) { return 0 }
        return worst
    }

    private static func rank(token: String, title: String, keywords: [String]) -> Int? {
        if title == token { return 0 }
        if title.hasPrefix(token) { return 1 }
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(token) }) { return 2 }
        if title.contains(token) { return 3 }
        if keywords.contains(where: { $0.hasPrefix(token) }) { return 4 }
        if keywords.contains(where: { $0.contains(token) }) { return 5 }
        if token.count >= 3, isSubsequence(token, of: title) { return 6 }
        return nil
    }

    /// "bld" is a subsequence of "build current draft".
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }

    /// Best first; ties keep the original order.
    static func filter(_ commands: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return commands }
        let ranked: [(offset: Int, rank: Int, item: CommandPaletteItem)] = commands.enumerated().compactMap { offset, item in
            guard let rank = rank(title: item.title, keywords: item.keywords, query: trimmed) else { return nil }
            return (offset, rank, item)
        }
        return ranked
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.item)
    }

    /// Papers are only searched for two letters or more.
    static func shouldSearchPapers(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    /// Wraps around at both ends.
    static func moved(_ index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }

    static func paperSubtitle(year: Int?) -> String {
        year.map { "Paper · \($0)" } ?? "Paper"
    }
}

// MARK: - Sheet

private enum PaletteRow: Identifiable {
    case command(CommandPaletteItem)
    case paper(ItemHit)
    case searchAll(String)

    var id: String {
        switch self {
        case .command(let item): return "cmd:\(item.id.uuidString)"
        case .paper(let hit): return "paper:\(hit.itemID)"
        case .searchAll: return "search-all"
        }
    }
}

struct CommandPaletteSheet: View {
    let onDismiss: () -> Void
    let onSelectCommand: (String) -> Void
    var model: LibraryModel?
    var onOpenPaper: ((String) -> Void)?
    var onSearchAll: ((String) -> Void)?

    init(
        onDismiss: @escaping () -> Void,
        onSelectCommand: @escaping (String) -> Void,
        model: LibraryModel? = nil,
        onOpenPaper: ((String) -> Void)? = nil,
        onSearchAll: ((String) -> Void)? = nil
    ) {
        self.onDismiss = onDismiss
        self.onSelectCommand = onSelectCommand
        self.model = model
        self.onOpenPaper = onOpenPaper
        self.onSearchAll = onSearchAll
    }

    @State private var query = ""
    @State private var paperHits: [ItemHit] = []
    @State private var selected = 0
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Scrim
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 0) {
                // Search Input Header
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(RBColor.mutedText)

                    TextField("Type a command or a paper title", text: $query)
                        .textFieldStyle(.plain)
                        .font(RBFont.section())
                        .foregroundStyle(RBColor.primaryText)
                        .focused($isFocused)
                        .onSubmit { runSelected() }
                        .onKeyPress(.downArrow) {
                            selected = PaletteLogic.moved(selected, by: 1, count: rows.count)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            selected = PaletteLogic.moved(selected, by: -1, count: rows.count)
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            onDismiss()
                            return .handled
                        }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(RBColor.mutedText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(RBColor.elevatedSurface)

                Divider()
                    .overlay(RBColor.border)

                // Results
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if rows.isEmpty {
                                Text("No command or paper matches “\(query)”.")
                                    .font(RBFont.body())
                                    .foregroundStyle(RBColor.mutedText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }

                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if let heading = sectionHeading(at: index) {
                                    Text(heading)
                                        .font(RBFont.caption(.semibold))
                                        .foregroundStyle(RBColor.mutedText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.top, index == 0 ? 2 : 8)
                                }
                                rowView(row, isSelected: index == selected)
                                    .id(row.id)
                                    .onTapGesture { run(row) }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selected) { _, newValue in
                        if rows.indices.contains(newValue) {
                            proxy.scrollTo(rows[newValue].id)
                        }
                    }
                }
            }
            .frame(width: 580)
            .background(RBColor.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(RBColor.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 30, x: 0, y: 15)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            isFocused = true
        }
        .onChange(of: query) { _, newValue in
            selected = 0
            scheduleSearch(for: newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: Rows

    private var rows: [PaletteRow] {
        var result: [PaletteRow] = PaletteLogic.filter(allCommands, query: query).map { .command($0) }
        result.append(contentsOf: paperHits.map { .paper($0) })
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if PaletteLogic.shouldSearchPapers(trimmed) {
            result.append(.searchAll(trimmed))
        }
        return result
    }

    /// A small heading above the first command and the first paper.
    private func sectionHeading(at index: Int) -> String? {
        let all = rows
        guard all.indices.contains(index) else { return nil }
        let hasPapers = !paperHits.isEmpty
        switch all[index] {
        case .command:
            guard hasPapers || PaletteLogic.shouldSearchPapers(query) else { return nil }
            return index == 0 ? "Commands" : nil
        case .paper:
            if index > 0, case .paper = all[index - 1] { return nil }
            return "Papers"
        case .searchAll:
            return nil
        }
    }

    private func rowView(_ row: PaletteRow, isSelected: Bool) -> some View {
        let icon: String
        let title: String
        let detail: String
        switch row {
        case .command(let item):
            icon = item.iconName; title = item.title; detail = item.shortcut
        case .paper(let hit):
            icon = "doc.text"; title = hit.title; detail = PaletteLogic.paperSubtitle(year: hit.year)
        case .searchAll(let text):
            icon = "text.magnifyingglass"; title = "Search everything for “\(text)”"; detail = ""
        }
        let isShortcut: Bool = { if case .command = row { return true } else { return false } }()

        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(RBColor.primaryText)
                .frame(width: 22)

            Text(title)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .lineLimit(1)

            Spacer()

            if !detail.isEmpty {
                Text(detail)
                    .font(isShortcut ? RBFont.label(.medium).monospaced() : RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .padding(.horizontal, isShortcut ? 6 : 0)
                    .padding(.vertical, isShortcut ? 2 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isShortcut ? RBColor.hover : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isShortcut ? RBColor.border : Color.clear, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? RBColor.accent.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .rbHover(cornerRadius: 8)
    }

    // MARK: Actions

    private func runSelected() {
        let all = rows
        guard all.indices.contains(selected) else { return }
        run(all[selected])
    }

    private func run(_ row: PaletteRow) {
        switch row {
        case .command(let item):
            item.action()
        case .paper(let hit):
            if let onOpenPaper {
                onOpenPaper(hit.itemID)
            } else {
                onSelectCommand("paper:\(hit.itemID)")
            }
        case .searchAll(let text):
            if let onSearchAll {
                onSearchAll(text)
            } else {
                onSelectCommand("search")
            }
        }
        onDismiss()
    }

    /// As you type: waits a moment so fast typing does one search, not ten.
    private func scheduleSearch(for text: String) {
        searchTask?.cancel()
        guard let model, PaletteLogic.shouldSearchPapers(text) else {
            paperHits = []
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            // A failed search just shows no papers; the palette must never get in the way.
            let hits = (try? SearchService(model: model).suggestTitles(prefix: trimmed, limit: 6)) ?? []
            if Task.isCancelled { return }
            paperHits = hits
            selected = min(selected, max(rows.count - 1, 0))
        }
    }

    private var allCommands: [CommandPaletteItem] {
        [
            CommandPaletteItem(title: "Go to Library", iconName: "books.vertical", shortcut: "⌘2", keywords: ["papers", "collection"]) {
                onSelectCommand("library")
            },
            CommandPaletteItem(title: "Go to Writing", iconName: "pencil", shortcut: "⌘5", keywords: ["drafts", "latex", "paper"]) {
                onSelectCommand("writing")
            },
            CommandPaletteItem(title: "Go to Search", iconName: "magnifyingglass", shortcut: "⌘F", keywords: ["find", "full text"]) {
                onSelectCommand("search")
            },
            CommandPaletteItem(title: "Quick add paper", iconName: "sparkles", shortcut: "⌥⌘N", keywords: ["doi", "arxiv", "link", "paste"]) {
                onSelectCommand("quickAdd")
            },
            CommandPaletteItem(title: "Add paper…", iconName: "plus", shortcut: "⌘N", keywords: ["new", "import", "pdf"]) {
                onSelectCommand("addPaper")
            },
            CommandPaletteItem(title: "Build current draft", iconName: "play.fill", shortcut: "⌘B", keywords: ["compile", "latex", "pdf"]) {
                onSelectCommand("buildDraft")
            },
            CommandPaletteItem(title: "Insert citation", iconName: "link", shortcut: "⌘⇧K", keywords: ["cite", "reference", "bibliography"]) {
                onSelectCommand("insertCitation")
            },
            CommandPaletteItem(title: "Run integrity check", iconName: "shield.checkerboard", shortcut: "", keywords: ["verify", "repair", "database", "health"]) {
                onSelectCommand("integrityCheck")
            },
            CommandPaletteItem(title: "Back up now", iconName: "arrow.down.doc", shortcut: "", keywords: ["backup", "save", "export", "copy"]) {
                onSelectCommand("backupNow")
            },
            CommandPaletteItem(title: "Switch theme", iconName: "paintpalette", shortcut: "", keywords: ["dark", "light", "appearance", "mode"]) {
                onSelectCommand("switchTheme")
            },
            CommandPaletteItem(title: "Show Trash", iconName: "trash", shortcut: "", keywords: ["deleted", "restore", "bin"]) {
                onSelectCommand("trash")
            }
        ]
    }
}
