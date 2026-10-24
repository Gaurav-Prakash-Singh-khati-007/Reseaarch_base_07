//
//  ResearchIdeasView.swift
//  ResearchBase
//
//  Phase 8 — Research Problems & Ideas
//
//  A single workspace with three tabs — Gaps, Problems, Ideas —
//  that lets a researcher move from a documented research gap,
//  to a specific research problem, to a proposed research idea,
//  without leaving this screen. Uses a manual HStack for the
//  list/detail split (as established in Literature Review)
//  rather than a nested NavigationSplitView.
//

import SwiftUI
import SwiftData

// MARK: - Workspace Tab

enum ResearchWorkspaceTab: String, CaseIterable {
    case ideas = "Ideas"
    case problems = "Problems"
    case gaps = "Gaps"
    case thoughts = "All thoughts"

    var icon: String {
        switch self {
        case .ideas: return "lightbulb"
        case .problems: return "questionmark.circle"
        case .gaps: return "puzzlepiece.extension"
        case .thoughts: return "square.stack.3d.up"
        }
    }
}

// MARK: - Sort Option

enum ResearchSortOption: String, CaseIterable, Identifiable {
    case titleAZ = "Title A–Z"
    case titleZA = "Title Z–A"
    case newest = "Newest"
    case oldest = "Oldest"
    case recentlyUpdated = "Recently Updated"

    var id: String { rawValue }
}

// MARK: - Generic Link Diffing Helper

/// Applies the difference between a picker's resulting id-set and
/// the currently linked items, calling `link`/`unlink` only for
/// the items that actually changed. Shared by the Gaps, Problems
/// and Ideas workspaces below.
fileprivate func rbApplyLinks<T: Identifiable>(
    newIDs: Set<T.ID>,
    current: [T],
    all: [T],
    link: (T) throws -> Void,
    unlink: (T) throws -> Void,
    onError: (String) -> Void
) {
    let currentIDs = Set(current.map { $0.id })

    let toLink = all.filter { newIDs.contains($0.id) && !currentIDs.contains($0.id) }
    let toUnlink = current.filter { !newIDs.contains($0.id) }

    do {
        for item in toLink {
            try link(item)
        }
        for item in toUnlink {
            try unlink(item)
        }
    } catch {
        onError(error.localizedDescription)
    }
}

// MARK: - Status Colors

fileprivate func rbStatusColor(_ status: ResearchGapStatus) -> Color {
    switch status {
    case .identified: return RBColor.accent
    case .investigating: return RBColor.warning
    case .validated, .addressed: return RBColor.success
    case .archived: return RBColor.mutedText
    }
}

fileprivate func rbStatusColor(_ status: ResearchProblemStatus) -> Color {
    switch status {
    case .draft: return RBColor.mutedText
    case .exploring: return RBColor.warning
    case .defined, .active: return RBColor.accent
    case .resolved: return RBColor.success
    case .archived: return RBColor.mutedText
    }
}

fileprivate func rbStatusColor(_ status: ResearchIdeaStatus) -> Color {
    switch status {
    case .draft: return RBColor.mutedText
    case .exploring, .promising: return RBColor.warning
    case .selected, .testing: return RBColor.accent
    case .implemented: return RBColor.success
    case .rejected, .archived: return RBColor.error
    }
}

// MARK: - Shared Small Components

fileprivate struct RBStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(RBFont.label(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

fileprivate struct RBTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(RBFont.label(.semibold))
                .tracking(0.6)
                .foregroundStyle(RBColor.mutedText)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .padding(10)
                .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
        }
    }
}

fileprivate struct RBTextEditor: View {
    let label: String
    @Binding var text: String
    var minHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(RBFont.label(.semibold))
                .tracking(0.6)
                .foregroundStyle(RBColor.mutedText)

            TextEditor(text: $text)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight)
                .padding(6)
                .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
        }
    }
}

fileprivate struct RBDetailHeader: View {
    let title: String
    let statusText: String
    let statusColor: Color
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                RBStatusPill(text: statusText, color: statusColor)
            }

            Spacer()

            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
    }
}

fileprivate struct RBDetailSection: View {
    let title: String
    let text: String

    var body: some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(RBFont.label(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(RBColor.mutedText)

                Text(text)
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

fileprivate struct RBLinkRow: View {
    let title: String
    let subtitle: String
    let onUnlink: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onUnlink) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(RBColor.mutedText)
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
        }
        .padding(10)
        .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }
}

fileprivate struct RBEvidenceHeader: View {
    let title: String
    let onLink: () -> Void

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(RBFont.label(.semibold))
                .tracking(0.6)
                .foregroundStyle(RBColor.mutedText)

            Spacer()

            Button(action: onLink) {
                Label("Link", systemImage: "plus")
                    .font(RBFont.caption(.medium))
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(RBColor.accent)
        }
    }
}

fileprivate struct RBRowCard<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    let content: Content

    init(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.action = action
        self.content = content()
    }

    var body: some View {
        // Kit row: hover, selected look and border all come from RBRow
        RBRow(isSelected: isSelected, action: action) {
            content
        }
    }
}

fileprivate struct RBEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(RBColor.accent)

            Text(title)
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text(message)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button(action: action) {
                Label(actionTitle, systemImage: "plus")
            }
            .buttonStyle(RBPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

fileprivate struct RBDetailPlaceholder: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(RBColor.mutedText)

            Text(text)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
    }
}

/// The look of one dropdown in the filter bar (the HTML <select>):
/// text on the left, a small arrow on the right, fills its column.
fileprivate struct RBSelectLabel: View {
    let text: String
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)

            Spacer(minLength: 4)

            Image(systemName: "chevron.down")
                .font(.system(size: 8))
        }
        .font(RBFont.caption(.medium))
        .foregroundStyle(isActive ? RBColor.accent : RBColor.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RBColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.field)
                .stroke(RBColor.border)
        )
    }
}

@ViewBuilder
fileprivate func rbFilterMenu<T: CaseIterable & RawRepresentable & Hashable>(
    label: String,
    selection: Binding<T?>,
    allCases: [T]
) -> some View where T.RawValue == String {
    Menu {
        Button("All") { selection.wrappedValue = nil }

        Divider()

        ForEach(allCases, id: \.self) { option in
            Button {
                selection.wrappedValue = option
            } label: {
                if selection.wrappedValue == option {
                    Label(option.rawValue, systemImage: "checkmark")
                } else {
                    Text(option.rawValue)
                }
            }
        }
    } label: {
        RBSelectLabel(text: label, isActive: selection.wrappedValue != nil)
    }
    .menuStyle(.borderlessButton)
    .frame(maxWidth: .infinity)
    .rbHover(cornerRadius: RBRadius.field)
}

fileprivate func rbSortMenu(selection: Binding<ResearchSortOption>) -> some View {
    Menu {
        ForEach(ResearchSortOption.allCases) { option in
            Button {
                selection.wrappedValue = option
            } label: {
                if selection.wrappedValue == option {
                    Label(option.rawValue, systemImage: "checkmark")
                } else {
                    Text(option.rawValue)
                }
            }
        }
    } label: {
        // Shows the current sort, like the HTML dropdown
        RBSelectLabel(text: selection.wrappedValue.rawValue)
    }
    .menuStyle(.borderlessButton)
    .frame(maxWidth: .infinity)
    .rbHover(cornerRadius: RBRadius.field)
}

fileprivate func rbSort<T>(
    _ items: [T],
    option: ResearchSortOption,
    title: (T) -> String,
    createdAt: (T) -> Date,
    updatedAt: (T) -> Date
) -> [T] {
    switch option {
    case .titleAZ:
        return items.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
    case .titleZA:
        return items.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedDescending }
    case .newest:
        return items.sorted { createdAt($0) > createdAt($1) }
    case .oldest:
        return items.sorted { createdAt($0) < createdAt($1) }
    case .recentlyUpdated:
        return items.sorted { updatedAt($0) > updatedAt($1) }
    }
}


// ═══════════════════════════════════════════════════════════════
//  Owner: Agent 72 · Features: F-44 (one kind of thought item), F-45 (where used)
//
//  PUBLIC API
//    ResearchWorkspaceTab.thoughts            new "All thoughts" tab (SQLite library only)
//    RBA72ThoughtsLogic                       load / create / save / trash / restore / link helpers (tested)
//    RBA72ThoughtDraft                        editable copy of a Thought
//    RBA72ThoughtsWorkspace(model:openNewRequest:)
//    The tab shows only when `\.rbA70LibraryModel` (declared in LibraryView.swift) is injected.
//    The old Ideas / Problems / Gaps tabs (SwiftData) are untouched.
// ═══════════════════════════════════════════════════════════════

// MARK: - Agent 72 logic (no UI, unit tested)

struct RBA72ThoughtDraft: Equatable {
    var title: String
    var body: String
    var kind: ThoughtKind
    var status: ThoughtStatus
    var priority: Int
    var evidence: String
    var question: String

    init(_ t: Thought) {
        title = t.title
        body = t.body
        kind = t.kind
        status = t.status
        priority = t.priority
        evidence = t.evidence
        question = t.question
    }

    static let empty = RBA72ThoughtDraft(
        Thought(id: "", kind: .note, title: "", body: "", status: .open, priority: 0,
                evidence: "", question: "", createdAt: "", updatedAt: "", deletedAt: nil)
    )

    /// Every field is copied, so changing the kind never drops evidence or question.
    func apply(to t: inout Thought) {
        t.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.body = body
        t.kind = kind
        t.status = status
        t.priority = priority
        t.evidence = evidence
        t.question = question
    }
}

enum RBA72ThoughtsLogic {

    static func kindLabel(_ kind: ThoughtKind) -> String { kind.rawValue.capitalized }
    static func statusLabel(_ status: ThoughtStatus) -> String { status.rawValue.capitalized }

    /// With text: full-text search (best match first). Without: the list, newest or highest priority first.
    static func load(
        model: LibraryModel,
        kind: ThoughtKind?,
        status: ThoughtStatus?,
        byPriority: Bool,
        query: String
    ) throws -> [Thought] {

        let store = ThoughtStore(model: model)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return try store.list(kind: kind, status: status, sort: byPriority ? .priority : .recent, limit: 200)
        }

        let hits = try SearchService(model: model).searchThoughts(text, options: SearchOptions(limit: 200)).hits
        var result: [Thought] = []
        for hit in hits {
            guard let thought = try store.fetch(id: hit.thoughtID) else { continue }
            if let kind, thought.kind != kind { continue }
            if let status, thought.status != status { continue }
            result.append(thought)
        }
        return result
    }

    static func counts(model: LibraryModel) -> [ThoughtKind: Int] {
        (try? ThoughtStore(model: model).countsByKind()) ?? [:]
    }

    @discardableResult
    static func create(model: LibraryModel, kind: ThoughtKind, title: String) throws -> Thought {
        let thought = try ThoughtStore(model: model).create(NewThought(kind: kind, title: title))
        try? SearchService(model: model).indexThought(id: thought.id)
        return thought
    }

    @discardableResult
    static func save(model: LibraryModel, id: String, draft: RBA72ThoughtDraft) throws -> Thought {
        let saved = try ThoughtStore(model: model).update(id: id) { draft.apply(to: &$0) }
        try? SearchService(model: model).indexThought(id: id)
        return saved
    }

    static func trash(model: LibraryModel, id: String) throws {
        try ThoughtStore(model: model).trash(id: id)
    }

    static func restore(model: LibraryModel, id: String) throws {
        try ThoughtStore(model: model).restore(id: id)
    }

    /// Papers to pick from when linking: search results, or the newest accepted papers.
    static func paperChoices(model: LibraryModel, query: String) -> [ModelItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return (try? model.items.list(reviewState: .accepted, limit: 30)) ?? []
        }
        let service = SearchService(model: model)
        guard let page = try? service.searchItems(text, options: SearchOptions(limit: 30)) else { return [] }
        return (try? service.items(for: page.hits)) ?? []
    }

    @discardableResult
    static func linkPaper(model: LibraryModel, thoughtID: String, itemID: String) throws -> ModelLink {
        try ThoughtStore(model: model).link(thoughtID: thoughtID, to: LinkEnd(.item, itemID))
    }
}

// MARK: - Agent 72 workspace (SQLite thoughts)

struct RBA72ThoughtsWorkspace: View {

    let model: LibraryModel
    @Binding var openNewRequest: Bool

    @State private var thoughts: [Thought] = []
    @State private var counts: [ThoughtKind: Int] = [:]
    @State private var kindFilter: ThoughtKind?
    @State private var statusFilter: ThoughtStatus?
    @State private var byPriority = false
    @State private var searchText = ""

    @State private var selectedID: String?
    @State private var original: Thought?
    @State private var draft = RBA72ThoughtDraft.empty

    @State private var errorText: String?
    @State private var undoID: String?
    @State private var linkToken = 0
    @State private var showingPaperPicker = false
    @State private var confirmingTrash = false

    @State private var showingNew = false
    @State private var newTitle = ""

    private struct ReloadKey: Hashable {
        let kind: ThoughtKind?
        let status: ThoughtStatus?
        let byPriority: Bool
        let query: String
    }

    private var reloadKey: ReloadKey {
        ReloadKey(kind: kindFilter, status: statusFilter, byPriority: byPriority, query: searchText)
    }

    private var isDirty: Bool {
        guard let original else { return false }
        return RBA72ThoughtDraft(original) != draft
    }

    var body: some View {

        HStack(spacing: 0) {

            listPane
                .frame(width: 340)

            Divider().overlay(RBColor.border)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RBColor.background)
        .task(id: reloadKey) {
            if !searchText.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            reload()
        }
        .onAppear {
            if openNewRequest { startNew() }
        }
        .onChange(of: openNewRequest) { _, wants in
            if wants { startNew() }
        }
        .alert("New thought", isPresented: $showingNew) {
            TextField("Title", text: $newTitle)
            Button("Create") { createNew() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(kindFilter.map { "It will be saved as a \(RBA72ThoughtsLogic.kindLabel($0).lowercased())." }
                 ?? "It will be saved as a note. You can change the kind any time.")
        }
        .sheet(isPresented: $showingPaperPicker) {
            RBA72PaperPicker(model: model) { itemID in
                linkSelected(to: itemID)
            }
        }
        .confirmationDialog("Move this thought to the Trash?", isPresented: $confirmingTrash) {
            Button("Move to Trash", role: .destructive) { trashSelected() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: List pane

    private var listPane: some View {

        VStack(spacing: 0) {

            RBListPaneHeader(
                title: "Thoughts",
                subtitle: RBListPaneMetrics.count(counts.values.reduce(0, +), "thought")
            ) {
                Button { startNew() } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New thought")
            }

            RBSearchField(placeholder: "Search thoughts...", text: $searchText)
                .rbListPaneInset()

            VStack(alignment: .leading, spacing: 8) {

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        RBChip(text: "All \(counts.values.reduce(0, +))", isSelected: kindFilter == nil) {
                            kindFilter = nil
                        }
                        ForEach(ThoughtKind.allCases, id: \.self) { kind in
                            RBChip(text: "\(RBA72ThoughtsLogic.kindLabel(kind)) \(counts[kind] ?? 0)",
                                   isSelected: kindFilter == kind) {
                                kindFilter = (kindFilter == kind) ? nil : kind
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Menu {
                        Button("All statuses") { statusFilter = nil }
                        ForEach(ThoughtStatus.allCases, id: \.self) { status in
                            Button(RBA72ThoughtsLogic.statusLabel(status)) { statusFilter = status }
                        }
                    } label: {
                        Text(statusFilter.map { RBA72ThoughtsLogic.statusLabel($0) } ?? "All statuses")
                            .font(RBFont.caption(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Toggle("By priority", isOn: $byPriority)
                        .toggleStyle(.checkbox)
                        .font(RBFont.caption())
                        .disabled(!searchText.isEmpty)
                }
            }
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if let errorText {
                Text(errorText)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.warning)
                    .rbListPaneInset(bottom: 0)
                    .padding(.top, 8)
            }

            if thoughts.isEmpty {
                Spacer()
                Text(searchText.isEmpty ? "No thoughts yet. Notes, findings, gaps, problems and ideas all live here."
                                        : "No thoughts match.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, RBListPaneMetrics.inset)
                Spacer()
            } else {
                RBListColumn {
                    ForEach(thoughts, id: \.id) { thought in
                        row(thought)
                    }
                }
            }

            if let undoID {
                HStack {
                    Text("Moved to Trash")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                    Spacer()
                    Button("Undo") { undoTrash(undoID) }
                        .buttonStyle(.plain)
                        .foregroundStyle(RBColor.accent)
                }
                .padding(10)
                .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
                .padding(RBListPaneMetrics.listPadding)
            }
        }
        .rbListPaneBackground()
    }

    private func row(_ thought: Thought) -> some View {

        let selected = thought.id == selectedID

        return Button { select(thought.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(thought.title)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    RBStatusPill(text: RBA72ThoughtsLogic.kindLabel(thought.kind), color: RBColor.accent)
                    Text(RBA72ThoughtsLogic.statusLabel(thought.status))
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                    if thought.priority > 0 {
                        Text("P\(thought.priority)")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.warning)
                    }
                }
            }
            .padding(12)
            .background(selected ? RBColor.selectedTint : RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
            .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(selected ? RBColor.accent.opacity(0.6) : RBColor.border))
        }
        .buttonStyle(.plain)
        .rbHover(cornerRadius: RBRadius.field)
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {

        if selectedID == nil {

            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 38))
                    .foregroundStyle(RBColor.mutedText)
                Text("Select a thought, or press + to write a new one.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }

        } else {

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    HStack(spacing: 10) {
                        Text("Thought")
                            .font(RBFont.section(.semibold))
                            .foregroundStyle(RBColor.primaryText)
                        Spacer()
                        Button("Revert") { if let original { draft = RBA72ThoughtDraft(original) } }
                            .disabled(!isDirty)
                        Button("Save") { _ = saveCurrent() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isDirty)
                        Button(role: .destructive) { confirmingTrash = true } label: {
                            Image(systemName: "trash")
                        }
                    }

                    RBTextField(label: "Title", text: $draft.title)

                    HStack(spacing: 16) {
                        Picker("Kind", selection: $draft.kind) {
                            ForEach(ThoughtKind.allCases, id: \.self) { kind in
                                Text(RBA72ThoughtsLogic.kindLabel(kind)).tag(kind)
                            }
                        }
                        Picker("Status", selection: $draft.status) {
                            ForEach(ThoughtStatus.allCases, id: \.self) { status in
                                Text(RBA72ThoughtsLogic.statusLabel(status)).tag(status)
                            }
                        }
                        Stepper("Priority \(draft.priority)", value: $draft.priority, in: 0...5)
                    }

                    if draft.kind == .gap || !draft.evidence.isEmpty {
                        RBTextEditor(label: "Evidence", text: $draft.evidence, minHeight: 70)
                    }
                    if draft.kind == .problem || !draft.question.isEmpty {
                        RBTextField(label: "Research question", text: $draft.question)
                    }

                    RBTextEditor(label: "Notes (Markdown)", text: $draft.body, minHeight: 180)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("WHERE IS THIS USED?")
                                .font(RBFont.label(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(RBColor.mutedText)
                            Spacer()
                            Button { showingPaperPicker = true } label: {
                                Label("Link a paper", systemImage: "link")
                            }
                        }
                        if let id = selectedID {
                            WhereUsedPanel(
                                model: model,
                                end: LinkEnd(.thought, id),
                                reloadToken: linkToken,
                                allowsUnlink: true,
                                onChanged: { linkToken += 1 }
                            )
                        }
                    }
                }
                .padding(RBLayout.pageSide)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        do {
            thoughts = try RBA72ThoughtsLogic.load(
                model: model, kind: kindFilter, status: statusFilter,
                byPriority: byPriority, query: searchText
            )
            counts = RBA72ThoughtsLogic.counts(model: model)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func select(_ id: String) {
        guard id != selectedID else { return }
        if isDirty, !saveCurrent() { return }
        do {
            guard let thought = try ThoughtStore(model: model).fetch(id: id) else { return }
            selectedID = id
            original = thought
            draft = RBA72ThoughtDraft(thought)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @discardableResult
    private func saveCurrent() -> Bool {
        guard let id = selectedID else { return true }
        do {
            let saved = try RBA72ThoughtsLogic.save(model: model, id: id, draft: draft)
            original = saved
            draft = RBA72ThoughtDraft(saved)
            errorText = nil
            reload()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func startNew() {
        openNewRequest = false
        newTitle = ""
        showingNew = true
    }

    private func createNew() {
        if isDirty, !saveCurrent() { return }
        do {
            let thought = try RBA72ThoughtsLogic.create(model: model, kind: kindFilter ?? .note, title: newTitle)
            selectedID = thought.id
            original = thought
            draft = RBA72ThoughtDraft(thought)
            errorText = nil
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func trashSelected() {
        guard let id = selectedID else { return }
        do {
            try RBA72ThoughtsLogic.trash(model: model, id: id)
            selectedID = nil
            original = nil
            draft = .empty
            undoID = id
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func undoTrash(_ id: String) {
        do {
            try RBA72ThoughtsLogic.restore(model: model, id: id)
            undoID = nil
            reload()
            select(id)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func linkSelected(to itemID: String) {
        guard let id = selectedID else { return }
        do {
            try RBA72ThoughtsLogic.linkPaper(model: model, thoughtID: id, itemID: itemID)
            linkToken += 1
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

fileprivate struct RBA72PaperPicker: View {

    let model: LibraryModel
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ModelItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link a paper")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            TextField("Search papers...", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(results, id: \.id) { item in
                        Button {
                            onPick(item.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(item.title)
                                    .font(RBFont.body())
                                    .foregroundStyle(RBColor.primaryText)
                                    .lineLimit(2)
                                Spacer()
                                if let year = item.year {
                                    Text(String(year))
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.secondaryText)
                                }
                            }
                            .padding(10)
                            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .background(RBColor.page)
        .task(id: query) {
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            results = RBA72ThoughtsLogic.paperChoices(model: model, query: query)
        }
    }
}

// MARK: - Root View

struct ResearchIdeasView: View {

    @EnvironmentObject private var router: NavigationRouter

    @State private var selectedTab: ResearchWorkspaceTab = .ideas

    // Agent 72 — the "All thoughts" tab needs the SQLite library.
    @Environment(\.rbA70LibraryModel) private var rbA70Model

    private var visibleTabs: [ResearchWorkspaceTab] {
        ResearchWorkspaceTab.allCases.filter { $0 != .thoughts || rbA70Model != nil }
    }

    // Cross-tab navigation: when a problem/idea is created from a
    // gap/problem elsewhere in this workspace, the target tab
    // picks it up here and opens it for editing.
    @State private var pendingProblemID: UUID?
    @State private var pendingIdeaID: UUID?
    @State private var pendingGapID: UUID?

    // Phase 14 — Quick Add. Names the workspace that should open its
    // existing New sheet. The workspace clears it once it has opened
    // the sheet, so the same Quick Add item works again next time.
    @State private var pendingNewTab: ResearchWorkspaceTab?

    private func newRequestBinding(for tab: ResearchWorkspaceTab) -> Binding<Bool> {
        Binding(
            get: { pendingNewTab == tab },
            set: { if !$0 && pendingNewTab == tab { pendingNewTab = nil } }
        )
    }

    /// Phase 14 — consumes ONLY .gap / .problem / .idea. Selects the
    /// matching workspace tab, asks it to open its existing New
    /// sheet, then clears the router request.
    private func consumeQuickAdd() {
        let tab: ResearchWorkspaceTab
        switch router.pendingCreate {
        case .gap: tab = .gaps
        case .problem: tab = .problems
        case .idea: tab = .ideas
        default: return
        }

        selectedTab = tab
        pendingNewTab = tab
        router.pendingCreate = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider().overlay(RBColor.border)

            Group {
                switch selectedTab {
                case .gaps:
                    ResearchGapsWorkspace(
                        pendingSelectID: $pendingGapID,
                        openNewRequest: newRequestBinding(for: .gaps),
                        onProblemCreated: { problemID in
                            pendingProblemID = problemID
                            selectedTab = .problems
                        }
                    )

                case .problems:
                    ResearchProblemsWorkspace(
                        pendingSelectID: $pendingProblemID,
                        openNewRequest: newRequestBinding(for: .problems),
                        onIdeaCreated: { ideaID in
                            pendingIdeaID = ideaID
                            selectedTab = .ideas
                        }
                    )

                case .ideas:
                    ResearchIdeasWorkspace(
                        pendingSelectID: $pendingIdeaID,
                        openNewRequest: newRequestBinding(for: .ideas)
                    )

                case .thoughts:
                    if let model = rbA70Model {
                        RBA72ThoughtsWorkspace(
                            model: model,
                            openNewRequest: newRequestBinding(for: .thoughts)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .onAppear { consumeQuickAdd() }
        .onChange(of: router.createRequestCount) { consumeQuickAdd() }
        .onChange(of: router.pendingTarget) { _, target in
            switch target {
            case .researchGap(let id):
                pendingGapID = id
                selectedTab = .gaps
                router.pendingTarget = nil

            case .researchProblem(let id):
                pendingProblemID = id
                selectedTab = .problems
                router.pendingTarget = nil

            case .researchIdea(let id):
                pendingIdeaID = id
                selectedTab = .ideas
                router.pendingTarget = nil

            default:
                break
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(visibleTabs, id: \.self) { tab in
                tabButton(tab)
            }

            Spacer()
        }
        .padding(.horizontal, RBLayout.pageSide)
        .padding(.top, RBLayout.pageTop)
        .padding(.bottom, 12)
    }

    private func tabButton(_ tab: ResearchWorkspaceTab) -> some View {
        // Kit chip: it already has hover and the selected look
        RBChip(
            text: tab.rawValue,
            isSelected: selectedTab == tab,
            action: { selectedTab = tab }
        )
    }
}


// MARK: =====================================================
// MARK: - GAPS WORKSPACE
// MARK: =====================================================

struct ResearchGapsWorkspace: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Query(sort: [SortDescriptor(\LiteratureFinding.updatedAt, order: .reverse)])
    private var allFindings: [LiteratureFinding]

    @Binding var pendingSelectID: UUID?
    @Binding var openNewRequest: Bool
    var onProblemCreated: (UUID) -> Void

    @State private var searchText = ""
    @State private var typeFilter: ResearchGapType?
    @State private var statusFilter: ResearchGapStatus?
    @State private var sortOption: ResearchSortOption = .recentlyUpdated

    @State private var selectedGapID: UUID?
    @State private var showDetail = false
    @State private var relatedGapGroups: [UUID: [ResearchDataStore.RelatedGroup]] = [:]

    @State private var showingNewSheet = false
    @State private var editingGap: ResearchGap?
    @State private var deletingGap: ResearchGap?
    @State private var showingPaperPicker = false
    @State private var showingFindingPicker = false
    @State private var errorMessage: String?

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var filteredGaps: [ResearchGap] {
        var result = allGaps

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.descriptionText.localizedCaseInsensitiveContains(query) ||
                $0.evidence.localizedCaseInsensitiveContains(query)
            }
        }

        if let typeFilter {
            result = result.filter { $0.gapType == typeFilter }
        }

        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }

        return rbSort(
            result,
            option: sortOption,
            title: { $0.title },
            createdAt: { $0.createdAt },
            updatedAt: { $0.updatedAt }
        )
    }

    /// Phase 14 — Quick Add: opens the existing New Gap sheet.
    private func consumeNewRequest() {
        guard openNewRequest else { return }
        openNewRequest = false
        showingNewSheet = true
    }

    private var selectedGap: ResearchGap? {
        guard let selectedGapID else { return nil }
        return allGaps.first { $0.id == selectedGapID }
    }

    var body: some View {
        RBMasterDetail(
            masterMin: 240,
            masterIdeal: 320,
            showDetail: $showDetail,
            backTitle: "Back"
        ) {
            listPane
        } detail: {
            Group {
                if let selectedGap {
                    detailPane(for: selectedGap)
                } else {
                    RBDetailPlaceholder(icon: "puzzlepiece.extension", text: "Select a research gap to see its details.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectFirstIfNeeded()
            handlePendingSelect()
            consumeNewRequest()
        }
        .onChange(of: allGaps.count) {
            selectFirstIfNeeded()
        }
        .onChange(of: pendingSelectID) {
            handlePendingSelect()
        }
        .onChange(of: openNewRequest) { consumeNewRequest() }
        .sheet(isPresented: $showingNewSheet) {
            ResearchGapFormSheet(gap: nil) { result in
                createGap(result)
            }
        }
        .sheet(item: $editingGap) { gap in
            ResearchGapFormSheet(gap: gap) { result in
                updateGap(gap, with: result)
            }
        }
        .sheet(isPresented: $showingPaperPicker) {
            if let selectedGap {
                ResearchLinkPickerView(
                    navTitle: "Link Papers",
                    items: allPapers,
                    linkedIDs: linkedPaperIDsBinding(for: selectedGap),
                    emptyMessage: "Your library is empty. Add papers first.",
                    title: { $0.title },
                    subtitle: { $0.authors },
                    matches: { paper, q in
                        paper.title.localizedCaseInsensitiveContains(q) ||
                        paper.authors.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .sheet(isPresented: $showingFindingPicker) {
            if let selectedGap {
                ResearchLinkPickerView(
                    navTitle: "Link Literature Findings",
                    items: allFindings,
                    linkedIDs: linkedFindingIDsBinding(for: selectedGap),
                    emptyMessage: "No literature findings yet. Add findings from a Literature Review first.",
                    title: { $0.title },
                    subtitle: { $0.review?.title ?? "" },
                    matches: { finding, q in
                        finding.title.localizedCaseInsensitiveContains(q) ||
                        finding.content.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Research Gap?",
            isPresented: Binding(get: { deletingGap != nil }, set: { if !$0 { deletingGap = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Gap", role: .destructive) {
                if let deletingGap {
                    delete(deletingGap)
                }
            }
            Button("Cancel", role: .cancel) { deletingGap = nil }
        } message: {
            Text("Linked papers, findings, problems and ideas will not be deleted — only this gap is removed.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: List Pane

    private var listPane: some View {
        VStack(spacing: 0) {
            RBListPaneHeader(
                title: "Research Gaps",
                subtitle: RBListPaneMetrics.count(allGaps.count, "gap")
            ) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New gap")
            }

            RBSearchField(placeholder: "Search gaps…", text: $searchText)
                .rbListPaneInset()

            // Two dropdowns per row, wrapping like the HTML filter bar
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
                spacing: 8
            ) {
                rbFilterMenu(label: typeFilter?.rawValue ?? "All types", selection: $typeFilter, allCases: ResearchGapType.allCases)
                rbFilterMenu(label: statusFilter?.rawValue ?? "All statuses", selection: $statusFilter, allCases: ResearchGapStatus.allCases)
                rbSortMenu(selection: $sortOption)
            }
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if allGaps.isEmpty {
                RBEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No Research Gaps Yet",
                    message: "Research gaps help you record unanswered questions, limitations, contradictions, and unexplored areas identified from the literature.",
                    actionTitle: "Create Research Gap",
                    action: { showingNewSheet = true }
                )
            } else if filteredGaps.isEmpty {
                noResultsState
            } else {
                RBListColumn {
                    ForEach(filteredGaps, id: \.id) { gap in
                        RBRowCard(isSelected: selectedGapID == gap.id, action: { selectedGapID = gap.id; showDetail = true }) {
                            gapRowContent(gap)
                        }
                    }
                }
            }
        }
        .rbListPaneBackground()
    }

    private var noResultsState: some View {
        VStack {
            Spacer()
            Text("No gaps match your search or filters.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gapRowContent(_ gap: ResearchGap) -> some View {
        // Same row shape as the HTML. Status and type badges stack on the right
        // so no information is lost.
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(gap.title)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                if !gap.descriptionText.isEmpty {
                    Text(gap.descriptionText)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                RBStatusPill(text: gap.status.rawValue, color: rbStatusColor(gap.status))
                    .fixedSize()
                RBStatusPill(text: gap.gapType.rawValue, color: RBColor.mutedText)
                    .fixedSize()
            }
        }
    }

    // MARK: Detail Pane

    private func detailPane(for gap: ResearchGap) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RBDetailHeader(
                    title: gap.title,
                    statusText: gap.status.rawValue,
                    statusColor: rbStatusColor(gap.status),
                    onEdit: { editingGap = gap },
                    onDelete: { deletingGap = gap }
                )

                RBStatusPill(text: gap.gapType.rawValue, color: RBColor.accent)

                RBDetailSection(title: "Description", text: gap.descriptionText)
                RBDetailSection(title: "Evidence", text: gap.evidence)
                RBDetailSection(title: "Significance", text: gap.significance)

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(title: "Supporting Papers", onLink: { showingPaperPicker = true })

                    if gap.papers.isEmpty {
                        Text("No papers linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(gap.papers, id: \.id) { paper in
                            RBLinkRow(
                                title: paper.title,
                                subtitle: paper.authors,
                                onUnlink: { unlink(paper: paper, from: gap) }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(title: "Supporting Findings", onLink: { showingFindingPicker = true })

                    if gap.findings.isEmpty {
                        Text("No literature findings linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(gap.findings, id: \.id) { finding in
                            RBLinkRow(
                                title: finding.title,
                                subtitle: finding.review?.title ?? "",
                                onUnlink: { unlink(finding: finding, from: gap) }
                            )
                        }
                    }
                }

                if !gap.linkedProblems.isEmpty {
                    RBDetailSection(
                        title: "Used In Research Problems",
                        text: gap.linkedProblems.map { $0.title }.joined(separator: "\n")
                    )
                }

                RelatedResearchView(
                    groups: relatedGapGroups[gap.id] ?? [],
                    onNavigate: { router.open($0) }
                )

                HStack {
                    Spacer()

                    Button {
                        createProblem(from: gap)
                    } label: {
                        Label(
                            "Create Research Problem from this Gap",
                            systemImage: "arrow.turn.down.right"
                        )
                        .font(RBFont.secondary(.medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
        .task(id: gap.id) {
            loadRelated(gap)
        }
    }

    // MARK: Actions

    private func selectFirstIfNeeded() {
        if selectedGapID == nil {
            selectedGapID = allGaps.first?.id
        }
    }

    private func handlePendingSelect() {
        guard let targetID = pendingSelectID else { return }

        selectedGapID = targetID

        if let gap = allGaps.first(where: { $0.id == targetID }) {
            editingGap = gap
            showDetail = true
        }

        pendingSelectID = nil
    }

    private func loadRelated(_ gap: ResearchGap) {
        do {
            relatedGapGroups[gap.id] = try store.relatedResearch(for: gap)
        } catch {
            relatedGapGroups[gap.id] = []
            Swift.print(
                "ResearchBase: Failed to load related research for gap: \(error)"
            )
        }
    }

    private func createGap(_ result: ResearchGapFormResult) {
        do {
            let gap = try store.createResearchGap(
                title: result.title,
                description: result.description,
                gapType: result.gapType,
                status: result.status,
                evidence: result.evidence,
                significance: result.significance
            )
            selectedGapID = gap.id
            showDetail = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateGap(_ gap: ResearchGap, with result: ResearchGapFormResult) {
        do {
            try store.updateResearchGap(
                gap,
                title: result.title,
                description: result.description,
                gapType: result.gapType,
                status: result.status,
                evidence: result.evidence,
                significance: result.significance
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ gap: ResearchGap) {
        do {
            if selectedGapID == gap.id {
                selectedGapID = nil
                showDetail = false
            }
            try store.deleteResearchGap(gap)
            deletingGap = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(paper: PaperRecord, from gap: ResearchGap) {
        do {
            try store.unlinkPaperFromGap(paper, from: gap)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(finding: LiteratureFinding, from gap: ResearchGap) {
        do {
            try store.unlinkFindingFromGap(finding, from: gap)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createProblem(from gap: ResearchGap) {
        do {
            let problem = try store.createResearchProblem(fromGap: gap)
            onProblemCreated(problem.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func linkedPaperIDsBinding(for gap: ResearchGap) -> Binding<Set<PaperRecord.ID>> {
        Binding(
            get: { Set(gap.papers.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: gap.papers,
                    all: allPapers,
                    link: { try store.linkPaperToGap($0, to: gap) },
                    unlink: { try store.unlinkPaperFromGap($0, from: gap) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private func linkedFindingIDsBinding(for gap: ResearchGap) -> Binding<Set<LiteratureFinding.ID>> {
        Binding(
            get: { Set(gap.findings.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: gap.findings,
                    all: allFindings,
                    link: { try store.linkFindingToGap($0, to: gap) },
                    unlink: { try store.unlinkFindingFromGap($0, from: gap) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }
}

// MARK: - Gap Form

struct ResearchGapFormResult {
    var title: String
    var description: String
    var gapType: ResearchGapType
    var status: ResearchGapStatus
    var evidence: String
    var significance: String
}

struct ResearchGapFormSheet: View {
    let gap: ResearchGap?
    let onSave: (ResearchGapFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var gapType: ResearchGapType
    @State private var status: ResearchGapStatus
    @State private var evidence: String
    @State private var significance: String

    init(gap: ResearchGap?, onSave: @escaping (ResearchGapFormResult) -> Void) {
        self.gap = gap
        self.onSave = onSave
        _title = State(initialValue: gap?.title ?? "")
        _description = State(initialValue: gap?.descriptionText ?? "")
        _gapType = State(initialValue: gap?.gapType ?? .other)
        _status = State(initialValue: gap?.status ?? .identified)
        _evidence = State(initialValue: gap?.evidence ?? "")
        _significance = State(initialValue: gap?.significance ?? "")
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(gap == nil ? "New Research Gap" : "Edit Research Gap")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Save") {
                    onSave(
                        ResearchGapFormResult(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description,
                            gapType: gapType,
                            status: status,
                            evidence: evidence,
                            significance: significance
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
                    RBTextField(
                        label: "Title",
                        text: $title,
                        placeholder: "e.g. Limited efficient approaches for long-sequence processing"
                    )

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GAP TYPE")
                                .font(RBFont.label(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(RBColor.mutedText)

                            Picker("", selection: $gapType) {
                                ForEach(ResearchGapType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("STATUS")
                                .font(RBFont.label(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(RBColor.mutedText)

                            Picker("", selection: $status) {
                                ForEach(ResearchGapStatus.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        Spacer()
                    }

                    RBTextEditor(label: "Description", text: $description, minHeight: 90)
                    RBTextEditor(label: "Evidence", text: $evidence, minHeight: 90)
                    RBTextEditor(label: "Significance", text: $significance, minHeight: 70)
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 640)
        .background(RBColor.background)
    }
}


// MARK: =====================================================
// MARK: - PROBLEMS WORKSPACE
// MARK: =====================================================

struct ResearchProblemsWorkspace: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]

    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Binding var pendingSelectID: UUID?
    @Binding var openNewRequest: Bool
    var onIdeaCreated: (UUID) -> Void

    @State private var searchText = ""
    @State private var statusFilter: ResearchProblemStatus?
    @State private var sortOption: ResearchSortOption = .recentlyUpdated

    @State private var selectedProblemID: UUID?
    @State private var showDetail = false
    @State private var relatedProblemGroups: [UUID: [ResearchDataStore.RelatedGroup]] = [:]

    @State private var showingNewSheet = false
    @State private var editingProblem: ResearchProblem?
    @State private var deletingProblem: ResearchProblem?
    @State private var showingGapPicker = false
    @State private var showingPaperPicker = false
    @State private var errorMessage: String?

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var filteredProblems: [ResearchProblem] {
        var result = allProblems

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.problemStatement.localizedCaseInsensitiveContains(query) ||
                $0.researchQuestion.localizedCaseInsensitiveContains(query)
            }
        }

        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }

        return rbSort(
            result,
            option: sortOption,
            title: { $0.title },
            createdAt: { $0.createdAt },
            updatedAt: { $0.updatedAt }
        )
    }

    /// Phase 14 — Quick Add: opens the existing New Problem sheet.
    private func consumeNewRequest() {
        guard openNewRequest else { return }
        openNewRequest = false
        showingNewSheet = true
    }

    private var selectedProblem: ResearchProblem? {
        guard let selectedProblemID else { return nil }
        return allProblems.first { $0.id == selectedProblemID }
    }

    var body: some View {
        RBMasterDetail(
            masterMin: 240,
            masterIdeal: 320,
            showDetail: $showDetail,
            backTitle: "Back"
        ) {
            listPane
        } detail: {
            Group {
                if let selectedProblem {
                    detailPane(for: selectedProblem)
                } else {
                    RBDetailPlaceholder(
                        icon: "questionmark.circle",
                        text: "Select a research problem to see its details."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectFirstIfNeeded()
            consumeNewRequest()
        }
        .onChange(of: allProblems.count) { selectFirstIfNeeded() }
        .onChange(of: pendingSelectID) { handlePendingSelect() }
        .onChange(of: openNewRequest) { consumeNewRequest() }
        .sheet(isPresented: $showingNewSheet) {
            ResearchProblemFormSheet(problem: nil) { result in
                createProblem(result)
            }
        }
        .sheet(item: $editingProblem) { problem in
            ResearchProblemFormSheet(problem: problem) { result in
                updateProblem(problem, with: result)
            }
        }
        .sheet(isPresented: $showingGapPicker) {
            if let selectedProblem {
                ResearchLinkPickerView(
                    navTitle: "Link Research Gaps",
                    items: allGaps,
                    linkedIDs: linkedGapIDsBinding(for: selectedProblem),
                    emptyMessage: "No research gaps yet. Create a gap first.",
                    title: { $0.title },
                    subtitle: { $0.gapType.rawValue },
                    matches: { gap, q in gap.title.localizedCaseInsensitiveContains(q) }
                )
            }
        }
        .sheet(isPresented: $showingPaperPicker) {
            if let selectedProblem {
                ResearchLinkPickerView(
                    navTitle: "Link Papers",
                    items: allPapers,
                    linkedIDs: linkedPaperIDsBinding(for: selectedProblem),
                    emptyMessage: "Your library is empty. Add papers first.",
                    title: { $0.title },
                    subtitle: { $0.authors },
                    matches: { paper, q in
                        paper.title.localizedCaseInsensitiveContains(q) ||
                        paper.authors.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Research Problem?",
            isPresented: Binding(
                get: { deletingProblem != nil },
                set: { if !$0 { deletingProblem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Problem", role: .destructive) {
                if let deletingProblem {
                    delete(deletingProblem)
                }
            }

            Button("Cancel", role: .cancel) {
                deletingProblem = nil
            }
        } message: {
            Text("Linked gaps, papers and research ideas will not be deleted — only this problem is removed.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: List Pane

    private var listPane: some View {
        VStack(spacing: 0) {
            RBListPaneHeader(
                title: "Research Problems",
                subtitle: RBListPaneMetrics.count(allProblems.count, "problem")
            ) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New problem")
            }

            RBSearchField(placeholder: "Search problems…", text: $searchText)
                .rbListPaneInset()

            // Two dropdowns per row, wrapping like the HTML filter bar
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
                spacing: 8
            ) {
                rbFilterMenu(
                    label: statusFilter?.rawValue ?? "All statuses",
                    selection: $statusFilter,
                    allCases: ResearchProblemStatus.allCases
                )

                rbSortMenu(selection: $sortOption)
            }
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if allProblems.isEmpty {
                RBEmptyState(
                    icon: "questionmark.circle",
                    title: "No Research Problems Yet",
                    message: "Research problems convert a documented gap into a specific question worth investigating.",
                    actionTitle: "Create Research Problem",
                    action: { showingNewSheet = true }
                )
            } else if filteredProblems.isEmpty {
                noResultsState
            } else {
                RBListColumn {
                    ForEach(filteredProblems, id: \.id) { problem in
                        RBRowCard(
                            isSelected: selectedProblemID == problem.id,
                            action: { selectedProblemID = problem.id; showDetail = true }
                        ) {
                            problemRowContent(problem)
                        }
                    }
                }
            }
        }
        .rbListPaneBackground()
    }

    private var noResultsState: some View {
        VStack {
            Spacer()

            Text("No problems match your search or filters.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func problemRowContent(_ problem: ResearchProblem) -> some View {
        // Same row shape as the HTML: text on the left, status badge on the right
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(problem.title)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                if !problem.problemStatement.isEmpty {
                    Text(problem.problemStatement)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            RBStatusPill(
                text: problem.status.rawValue,
                color: rbStatusColor(problem.status)
            )
            .fixedSize()
        }
    }

    // MARK: Detail Pane

    private func detailPane(for problem: ResearchProblem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RBDetailHeader(
                    title: problem.title,
                    statusText: problem.status.rawValue,
                    statusColor: rbStatusColor(problem.status),
                    onEdit: { editingProblem = problem },
                    onDelete: { deletingProblem = problem }
                )

                RBDetailSection(
                    title: "Problem Statement",
                    text: problem.problemStatement
                )

                RBDetailSection(
                    title: "Background",
                    text: problem.background
                )

                RBDetailSection(
                    title: "Motivation",
                    text: problem.motivation
                )

                RBDetailSection(
                    title: "Significance",
                    text: problem.significance
                )

                RBDetailSection(
                    title: "Research Question",
                    text: problem.researchQuestion
                )

                RBDetailSection(
                    title: "Objectives",
                    text: problem.objectives
                )

                RBDetailSection(
                    title: "Hypotheses",
                    text: problem.hypotheses
                )

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(
                        title: "Supporting Gaps",
                        onLink: { showingGapPicker = true }
                    )

                    if problem.gaps.isEmpty {
                        Text("No research gaps linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(problem.gaps, id: \.id) { gap in
                            RBLinkRow(
                                title: gap.title,
                                subtitle: gap.gapType.rawValue,
                                onUnlink: { unlink(gap: gap, from: problem) }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(
                        title: "Supporting Papers",
                        onLink: { showingPaperPicker = true }
                    )

                    if problem.papers.isEmpty {
                        Text("No papers linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(problem.papers, id: \.id) { paper in
                            RBLinkRow(
                                title: paper.title,
                                subtitle: paper.authors,
                                onUnlink: { unlink(paper: paper, from: problem) }
                            )
                        }
                    }
                }

                if !problem.linkedIdeas.isEmpty {
                    RBDetailSection(
                        title: "Addressed By Research Ideas",
                        text: problem.linkedIdeas.map { $0.title }.joined(separator: "\n")
                    )
                }

                RelatedResearchView(
                    groups: relatedProblemGroups[problem.id] ?? [],
                    onNavigate: { router.open($0) }
                )

                HStack {
                    Spacer()

                    Button {
                        createIdea(from: problem)
                    } label: {
                        Label(
                            "Create Research Idea from this Problem",
                            systemImage: "arrow.turn.down.right"
                        )
                        .font(RBFont.secondary(.medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
        .task(id: problem.id) {
            loadRelated(problem)
        }
    }

    // MARK: Actions

    private func selectFirstIfNeeded() {
        if selectedProblemID == nil {
            selectedProblemID = allProblems.first?.id
        }
    }

    private func handlePendingSelect() {
        guard let targetID = pendingSelectID else { return }

        selectedProblemID = targetID

        if let problem = allProblems.first(where: { $0.id == targetID }) {
            editingProblem = problem
            showDetail = true
        }

        pendingSelectID = nil
    }

    private func loadRelated(_ problem: ResearchProblem) {
        do {
            relatedProblemGroups[problem.id] = try store.relatedResearch(for: problem)
        } catch {
            relatedProblemGroups[problem.id] = []

            Swift.print(
                "ResearchBase: Failed to load related research for problem: \(error)"
            )
        }
    }

    private func createProblem(_ result: ResearchProblemFormResult) {
        do {
            let problem = try store.createResearchProblem(
                title: result.title,
                problemStatement: result.problemStatement,
                background: result.background,
                motivation: result.motivation,
                significance: result.significance,
                researchQuestion: result.researchQuestion,
                objectives: result.objectives,
                hypotheses: result.hypotheses,
                status: result.status
            )

            selectedProblemID = problem.id
            showDetail = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateProblem(
        _ problem: ResearchProblem,
        with result: ResearchProblemFormResult
    ) {
        do {
            try store.updateResearchProblem(
                problem,
                title: result.title,
                problemStatement: result.problemStatement,
                background: result.background,
                motivation: result.motivation,
                significance: result.significance,
                researchQuestion: result.researchQuestion,
                objectives: result.objectives,
                hypotheses: result.hypotheses,
                status: result.status
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ problem: ResearchProblem) {
        do {
            if selectedProblemID == problem.id {
                selectedProblemID = nil
                showDetail = false
            }

            try store.deleteResearchProblem(problem)
            deletingProblem = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(gap: ResearchGap, from problem: ResearchProblem) {
        do {
            try store.unlinkGapFromProblem(gap, from: problem)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(paper: PaperRecord, from problem: ResearchProblem) {
        do {
            try store.unlinkPaperFromProblem(paper, from: problem)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createIdea(from problem: ResearchProblem) {
        do {
            let idea = try store.createResearchIdea(fromProblem: problem)
            onIdeaCreated(idea.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func linkedGapIDsBinding(
        for problem: ResearchProblem
    ) -> Binding<Set<ResearchGap.ID>> {
        Binding(
            get: { Set(problem.gaps.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: problem.gaps,
                    all: allGaps,
                    link: { try store.linkGapToProblem($0, to: problem) },
                    unlink: { try store.unlinkGapFromProblem($0, from: problem) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private func linkedPaperIDsBinding(
        for problem: ResearchProblem
    ) -> Binding<Set<PaperRecord.ID>> {
        Binding(
            get: { Set(problem.papers.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: problem.papers,
                    all: allPapers,
                    link: { try store.linkPaperToProblem($0, to: problem) },
                    unlink: { try store.unlinkPaperFromProblem($0, from: problem) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }
}

// MARK: - Problem Form

struct ResearchProblemFormResult {
    var title: String
    var problemStatement: String
    var background: String
    var motivation: String
    var significance: String
    var researchQuestion: String
    var objectives: String
    var hypotheses: String
    var status: ResearchProblemStatus
}

struct ResearchProblemFormSheet: View {
    let problem: ResearchProblem?
    let onSave: (ResearchProblemFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var problemStatement: String
    @State private var background: String
    @State private var motivation: String
    @State private var significance: String
    @State private var researchQuestion: String
    @State private var objectives: String
    @State private var hypotheses: String
    @State private var status: ResearchProblemStatus

    init(
        problem: ResearchProblem?,
        onSave: @escaping (ResearchProblemFormResult) -> Void
    ) {
        self.problem = problem
        self.onSave = onSave
        _title = State(initialValue: problem?.title ?? "")
        _problemStatement = State(initialValue: problem?.problemStatement ?? "")
        _background = State(initialValue: problem?.background ?? "")
        _motivation = State(initialValue: problem?.motivation ?? "")
        _significance = State(initialValue: problem?.significance ?? "")
        _researchQuestion = State(initialValue: problem?.researchQuestion ?? "")
        _objectives = State(initialValue: problem?.objectives ?? "")
        _hypotheses = State(initialValue: problem?.hypotheses ?? "")
        _status = State(initialValue: problem?.status ?? .draft)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(problem == nil ? "New Research Problem" : "Edit Research Problem")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .rbHover(cornerRadius: RBRadius.field)
                    .foregroundStyle(RBColor.secondaryText)

                Button("Save") {
                    onSave(
                        ResearchProblemFormResult(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            problemStatement: problemStatement,
                            background: background,
                            motivation: motivation,
                            significance: significance,
                            researchQuestion: researchQuestion,
                            objectives: objectives,
                            hypotheses: hypotheses,
                            status: status
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
                    RBTextField(
                        label: "Title",
                        text: $title,
                        placeholder: "e.g. Reducing inference cost for long-sequence transformers"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("STATUS")
                            .font(RBFont.label(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(RBColor.mutedText)

                        Picker("", selection: $status) {
                            ForEach(ResearchProblemStatus.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    RBTextEditor(
                        label: "Problem Statement",
                        text: $problemStatement,
                        minHeight: 90
                    )

                    RBTextEditor(
                        label: "Research Question",
                        text: $researchQuestion,
                        minHeight: 70
                    )

                    RBTextEditor(
                        label: "Background",
                        text: $background,
                        minHeight: 80
                    )

                    RBTextEditor(
                        label: "Motivation",
                        text: $motivation,
                        minHeight: 70
                    )

                    RBTextEditor(
                        label: "Significance",
                        text: $significance,
                        minHeight: 70
                    )

                    RBTextEditor(
                        label: "Objectives",
                        text: $objectives,
                        minHeight: 80
                    )

                    RBTextEditor(
                        label: "Hypotheses",
                        text: $hypotheses,
                        minHeight: 80
                    )
                }
                .padding(24)
            }
        }
        .frame(width: 600, height: 700)
        .background(RBColor.background)
    }
}


// MARK: =====================================================
// MARK: - IDEAS WORKSPACE
// MARK: =====================================================

struct ResearchIdeasWorkspace: View {

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var router: NavigationRouter

    @Query(sort: [SortDescriptor(\ResearchIdea.updatedAt, order: .reverse)])
    private var allIdeas: [ResearchIdea]

    @Query(sort: [SortDescriptor(\ResearchProblem.updatedAt, order: .reverse)])
    private var allProblems: [ResearchProblem]

    @Query(sort: [SortDescriptor(\ResearchGap.updatedAt, order: .reverse)])
    private var allGaps: [ResearchGap]

    @Query(sort: [SortDescriptor(\PaperRecord.addedAt, order: .reverse)])
    private var allPapers: [PaperRecord]

    @Query(sort: [SortDescriptor(\ResearchNote.updatedAt, order: .reverse)])
    private var allNotes: [ResearchNote]

    @Binding var pendingSelectID: UUID?
    @Binding var openNewRequest: Bool

    @State private var searchText = ""
    @State private var statusFilter: ResearchIdeaStatus?
    @State private var problemFilterID: UUID?
    @State private var gapFilterID: UUID?
    @State private var sortOption: ResearchSortOption = .recentlyUpdated

    @State private var selectedIdeaID: UUID?
    @State private var showDetail = false
    @State private var relatedIdeaGroups: [UUID: [ResearchDataStore.RelatedGroup]] = [:]

    @State private var showingNewSheet = false
    @State private var editingIdea: ResearchIdea?
    @State private var deletingIdea: ResearchIdea?
    @State private var showingProblemPicker = false
    @State private var showingGapPicker = false
    @State private var showingPaperPicker = false
    @State private var showingNotePicker = false
    @State private var errorMessage: String?

    private var store: ResearchDataStore {
        ResearchDataStore(modelContext: modelContext)
    }

    private var filteredIdeas: [ResearchIdea] {
        var result = allIdeas

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.summary.localizedCaseInsensitiveContains(query) ||
                $0.descriptionText.localizedCaseInsensitiveContains(query) ||
                $0.proposedApproach.localizedCaseInsensitiveContains(query)
            }
        }

        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }

        if let problemFilterID {
            result = result.filter { idea in
                idea.problems.contains { $0.id == problemFilterID }
            }
        }

        if let gapFilterID {
            result = result.filter { idea in
                idea.gaps.contains { $0.id == gapFilterID }
            }
        }

        return rbSort(
            result,
            option: sortOption,
            title: { $0.title },
            createdAt: { $0.createdAt },
            updatedAt: { $0.updatedAt }
        )
    }

    /// Phase 14 — Quick Add: opens the existing New Idea sheet.
    private func consumeNewRequest() {
        guard openNewRequest else { return }
        openNewRequest = false
        showingNewSheet = true
    }

    private var selectedIdea: ResearchIdea? {
        guard let selectedIdeaID else { return nil }
        return allIdeas.first { $0.id == selectedIdeaID }
    }

    var body: some View {
        RBMasterDetail(
            masterMin: 240,
            masterIdeal: 320,
            showDetail: $showDetail,
            backTitle: "Back"
        ) {
            listPane
        } detail: {
            Group {
                if let selectedIdea {
                    detailPane(for: selectedIdea)
                } else {
                    RBDetailPlaceholder(
                        icon: "lightbulb",
                        text: "Select a research idea to see its details."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectFirstIfNeeded()
            consumeNewRequest()
        }
        .onChange(of: allIdeas.count) { selectFirstIfNeeded() }
        .onChange(of: pendingSelectID) { handlePendingSelect() }
        .onChange(of: openNewRequest) { consumeNewRequest() }
        .sheet(isPresented: $showingNewSheet) {
            ResearchIdeaFormSheet(idea: nil) { result in
                createIdea(result)
            }
        }
        .sheet(item: $editingIdea) { idea in
            ResearchIdeaFormSheet(idea: idea) { result in
                updateIdea(idea, with: result)
            }
        }
        .sheet(isPresented: $showingProblemPicker) {
            if let selectedIdea {
                ResearchLinkPickerView(
                    navTitle: "Link Research Problems",
                    items: allProblems,
                    linkedIDs: linkedProblemIDsBinding(for: selectedIdea),
                    emptyMessage: "No research problems yet. Create a problem first.",
                    title: { $0.title },
                    subtitle: { $0.status.rawValue },
                    matches: { problem, q in
                        problem.title.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .sheet(isPresented: $showingGapPicker) {
            if let selectedIdea {
                ResearchLinkPickerView(
                    navTitle: "Link Research Gaps",
                    items: allGaps,
                    linkedIDs: linkedGapIDsBinding(for: selectedIdea),
                    emptyMessage: "No research gaps yet. Create a gap first.",
                    title: { $0.title },
                    subtitle: { $0.gapType.rawValue },
                    matches: { gap, q in
                        gap.title.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .sheet(isPresented: $showingPaperPicker) {
            if let selectedIdea {
                ResearchLinkPickerView(
                    navTitle: "Link Papers",
                    items: allPapers,
                    linkedIDs: linkedPaperIDsBinding(for: selectedIdea),
                    emptyMessage: "Your library is empty. Add papers first.",
                    title: { $0.title },
                    subtitle: { $0.authors },
                    matches: { paper, q in
                        paper.title.localizedCaseInsensitiveContains(q) ||
                        paper.authors.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .sheet(isPresented: $showingNotePicker) {
            if let selectedIdea {
                ResearchLinkPickerView(
                    navTitle: "Link Research Notes",
                    items: allNotes,
                    linkedIDs: linkedNoteIDsBinding(for: selectedIdea),
                    emptyMessage: "No research notes yet. Add notes from Knowledge first.",
                    title: { $0.title },
                    subtitle: { $0.noteType.rawValue },
                    matches: { note, q in
                        note.title.localizedCaseInsensitiveContains(q) ||
                        note.content.localizedCaseInsensitiveContains(q)
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Research Idea?",
            isPresented: Binding(
                get: { deletingIdea != nil },
                set: { if !$0 { deletingIdea = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Idea", role: .destructive) {
                if let deletingIdea {
                    delete(deletingIdea)
                }
            }

            Button("Cancel", role: .cancel) {
                deletingIdea = nil
            }
        } message: {
            Text("Linked problems, gaps, papers and notes will not be deleted — only this idea is removed.")
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: List Pane

    private var listPane: some View {
        VStack(spacing: 0) {
            RBListPaneHeader(
                title: "Research Ideas",
                subtitle: RBListPaneMetrics.count(allIdeas.count, "idea")
            ) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New idea")
            }

            RBSearchField(placeholder: "Search ideas…", text: $searchText)
                .rbListPaneInset()

            // Two dropdowns per row, wrapping like the HTML filter bar
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())],
                spacing: 8
            ) {
                rbFilterMenu(
                    label: statusFilter?.rawValue ?? "All statuses",
                    selection: $statusFilter,
                    allCases: ResearchIdeaStatus.allCases
                )

                problemFilterMenu
                gapFilterMenu

                rbSortMenu(selection: $sortOption)
            }
            .rbListPaneInset(bottom: 12)

            Divider().overlay(RBColor.border)

            if allIdeas.isEmpty {
                RBEmptyState(
                    icon: "lightbulb",
                    title: "No Research Ideas Yet",
                    message: "Research ideas capture a proposed approach or direction for addressing a research problem.",
                    actionTitle: "Create Research Idea",
                    action: { showingNewSheet = true }
                )
            } else if filteredIdeas.isEmpty {
                noResultsState
            } else {
                RBListColumn {
                    ForEach(filteredIdeas, id: \.id) { idea in
                        RBRowCard(
                            isSelected: selectedIdeaID == idea.id,
                            action: { selectedIdeaID = idea.id; showDetail = true }
                        ) {
                            ideaRowContent(idea)
                        }
                    }
                }
            }
        }
        .rbListPaneBackground()
    }

    private var problemFilterMenu: some View {
        Menu {
            Button("All Problems") {
                problemFilterID = nil
            }

            Divider()

            ForEach(allProblems, id: \.id) { problem in
                Button {
                    problemFilterID = problem.id
                } label: {
                    if problemFilterID == problem.id {
                        Label(problem.title, systemImage: "checkmark")
                    } else {
                        Text(problem.title)
                    }
                }
            }
        } label: {
            RBSelectLabel(
                text: problemFilterID == nil
                    ? "All problems"
                    : (allProblems.first { $0.id == problemFilterID }?.title ?? "All problems"),
                isActive: problemFilterID != nil
            )
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
        .rbHover(cornerRadius: RBRadius.field)
    }

    private var gapFilterMenu: some View {
        Menu {
            Button("All Gaps") {
                gapFilterID = nil
            }

            Divider()

            ForEach(allGaps, id: \.id) { gap in
                Button {
                    gapFilterID = gap.id
                } label: {
                    if gapFilterID == gap.id {
                        Label(gap.title, systemImage: "checkmark")
                    } else {
                        Text(gap.title)
                    }
                }
            }
        } label: {
            RBSelectLabel(
                text: gapFilterID == nil
                    ? "All gaps"
                    : (allGaps.first { $0.id == gapFilterID }?.title ?? "All gaps"),
                isActive: gapFilterID != nil
            )
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
        .rbHover(cornerRadius: RBRadius.field)
    }

    private var noResultsState: some View {
        VStack {
            Spacer()

            Text("No ideas match these filters.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ideaRowContent(_ idea: ResearchIdea) -> some View {
        // HTML row: title and summary on the left, status badge on the right
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(idea.title)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)

                Text(idea.summary.isEmpty ? "No summary" : idea.summary)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            RBStatusPill(
                text: idea.status.rawValue,
                color: rbStatusColor(idea.status)
            )
            .fixedSize()
        }
    }

    // MARK: Detail Pane
    // Mirrors the Idea Detail layout from the Phase 8 spec:
    // Summary → Research Problem → Proposed Approach →
    // Expected Contribution → Novelty → Supporting Evidence →
    // Limitations.

    private func detailPane(for idea: ResearchIdea) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RBDetailHeader(
                    title: idea.title,
                    statusText: idea.status.rawValue,
                    statusColor: rbStatusColor(idea.status),
                    onEdit: { editingIdea = idea },
                    onDelete: { deletingIdea = idea }
                )

                RBDetailSection(
                    title: "Summary",
                    text: idea.summary
                )

                if !idea.problems.isEmpty {
                    RBDetailSection(
                        title: "Research Problem",
                        text: idea.problems.map { $0.title }.joined(separator: "\n")
                    )
                }

                RBDetailSection(
                    title: "Proposed Approach",
                    text: idea.proposedApproach
                )

                RBDetailSection(
                    title: "Expected Contribution",
                    text: idea.expectedContribution
                )

                // Novelty is always shown as the researcher's own
                // claim, never as a system-verified fact.
                if !idea.novelty
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {

                    VStack(alignment: .leading, spacing: 6) {
                        Text("NOVELTY (RESEARCHER'S CLAIM)")
                            .font(RBFont.label(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(RBColor.mutedText)

                        Text(idea.novelty)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                RBDetailSection(
                    title: "Assumptions",
                    text: idea.assumptions
                )

                RBDetailSection(
                    title: "Limitations",
                    text: idea.limitations
                )

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(
                        title: "Supporting Problems",
                        onLink: { showingProblemPicker = true }
                    )

                    if idea.problems.isEmpty {
                        Text("No research problems linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(idea.problems, id: \.id) { problem in
                            RBLinkRow(
                                title: problem.title,
                                subtitle: problem.status.rawValue,
                                onUnlink: {
                                    unlink(problem: problem, from: idea)
                                }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(
                        title: "Supporting Gaps",
                        onLink: { showingGapPicker = true }
                    )

                    if idea.gaps.isEmpty {
                        Text("No research gaps linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(idea.gaps, id: \.id) { gap in
                            RBLinkRow(
                                title: gap.title,
                                subtitle: gap.gapType.rawValue,
                                onUnlink: {
                                    unlink(gap: gap, from: idea)
                                }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(
                        title: "Supporting Papers",
                        onLink: { showingPaperPicker = true }
                    )

                    if idea.papers.isEmpty {
                        Text("No papers linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(idea.papers, id: \.id) { paper in
                            RBLinkRow(
                                title: paper.title,
                                subtitle: paper.authors,
                                onUnlink: {
                                    unlink(paper: paper, from: idea)
                                }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    RBEvidenceHeader(
                        title: "Related Notes",
                        onLink: { showingNotePicker = true }
                    )

                    if idea.notes.isEmpty {
                        Text("No research notes linked yet.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.mutedText)
                    } else {
                        ForEach(idea.notes, id: \.id) { note in
                            RBLinkRow(
                                title: note.title,
                                subtitle: note.noteType.rawValue,
                                onUnlink: {
                                    unlink(note: note, from: idea)
                                }
                            )
                        }
                    }
                }

                RelatedResearchView(
                    groups: relatedIdeaGroups[idea.id] ?? [],
                    onNavigate: { router.open($0) }
                )
            }
            .rbResponsiveContentPadding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RBColor.background)
        .task(id: idea.id) {
            loadRelated(idea)
        }
    }

    // MARK: Actions

    private func selectFirstIfNeeded() {
        if selectedIdeaID == nil {
            selectedIdeaID = allIdeas.first?.id
        }
    }

    private func handlePendingSelect() {
        guard let targetID = pendingSelectID else { return }

        selectedIdeaID = targetID

        if let idea = allIdeas.first(where: { $0.id == targetID }) {
            editingIdea = idea
            showDetail = true
        }

        pendingSelectID = nil
    }

    private func loadRelated(_ idea: ResearchIdea) {
        do {
            relatedIdeaGroups[idea.id] = try store.relatedResearch(for: idea)
        } catch {
            relatedIdeaGroups[idea.id] = []

            Swift.print(
                "ResearchBase: Failed to load related research for idea: \(error)"
            )
        }
    }

    private func createIdea(_ result: ResearchIdeaFormResult) {
        do {
            let idea = try store.createResearchIdea(
                title: result.title,
                summary: result.summary,
                description: result.description,
                proposedApproach: result.proposedApproach,
                expectedContribution: result.expectedContribution,
                novelty: result.novelty,
                assumptions: result.assumptions,
                limitations: result.limitations,
                status: result.status
            )

            selectedIdeaID = idea.id
            showDetail = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateIdea(
        _ idea: ResearchIdea,
        with result: ResearchIdeaFormResult
    ) {
        do {
            try store.updateResearchIdea(
                idea,
                title: result.title,
                summary: result.summary,
                description: result.description,
                proposedApproach: result.proposedApproach,
                expectedContribution: result.expectedContribution,
                novelty: result.novelty,
                assumptions: result.assumptions,
                limitations: result.limitations,
                status: result.status
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ idea: ResearchIdea) {
        do {
            if selectedIdeaID == idea.id {
                selectedIdeaID = nil
                showDetail = false
            }

            try store.deleteResearchIdea(idea)
            deletingIdea = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(problem: ResearchProblem, from idea: ResearchIdea) {
        do {
            try store.unlinkProblemFromIdea(problem, from: idea)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(gap: ResearchGap, from idea: ResearchIdea) {
        do {
            try store.unlinkGapFromIdea(gap, from: idea)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(paper: PaperRecord, from idea: ResearchIdea) {
        do {
            try store.unlinkPaperFromIdea(paper, from: idea)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlink(note: ResearchNote, from idea: ResearchIdea) {
        do {
            try store.unlinkNoteFromIdea(note, from: idea)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func linkedProblemIDsBinding(
        for idea: ResearchIdea
    ) -> Binding<Set<ResearchProblem.ID>> {
        Binding(
            get: { Set(idea.problems.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: idea.problems,
                    all: allProblems,
                    link: { try store.linkProblemToIdea($0, to: idea) },
                    unlink: { try store.unlinkProblemFromIdea($0, from: idea) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private func linkedGapIDsBinding(
        for idea: ResearchIdea
    ) -> Binding<Set<ResearchGap.ID>> {
        Binding(
            get: { Set(idea.gaps.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: idea.gaps,
                    all: allGaps,
                    link: { try store.linkGapToIdea($0, to: idea) },
                    unlink: { try store.unlinkGapFromIdea($0, from: idea) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private func linkedPaperIDsBinding(
        for idea: ResearchIdea
    ) -> Binding<Set<PaperRecord.ID>> {
        Binding(
            get: { Set(idea.papers.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: idea.papers,
                    all: allPapers,
                    link: { try store.linkPaperToIdea($0, to: idea) },
                    unlink: { try store.unlinkPaperFromIdea($0, from: idea) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }

    private func linkedNoteIDsBinding(
        for idea: ResearchIdea
    ) -> Binding<Set<ResearchNote.ID>> {
        Binding(
            get: { Set(idea.notes.map { $0.id }) },
            set: { newValue in
                rbApplyLinks(
                    newIDs: newValue,
                    current: idea.notes,
                    all: allNotes,
                    link: { try store.linkNoteToIdea($0, to: idea) },
                    unlink: { try store.unlinkNoteFromIdea($0, from: idea) },
                    onError: { errorMessage = $0 }
                )
            }
        )
    }
}

// MARK: - Idea Form

struct ResearchIdeaFormResult {
    var title: String
    var summary: String
    var description: String
    var proposedApproach: String
    var expectedContribution: String
    var novelty: String
    var assumptions: String
    var limitations: String
    var status: ResearchIdeaStatus
}

struct ResearchIdeaFormSheet: View {
    let idea: ResearchIdea?
    let onSave: (ResearchIdeaFormResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var summary: String
    @State private var description: String
    @State private var proposedApproach: String
    @State private var expectedContribution: String
    @State private var novelty: String
    @State private var assumptions: String
    @State private var limitations: String
    @State private var status: ResearchIdeaStatus

    init(
        idea: ResearchIdea?,
        onSave: @escaping (ResearchIdeaFormResult) -> Void
    ) {
        self.idea = idea
        self.onSave = onSave
        _title = State(initialValue: idea?.title ?? "")
        _summary = State(initialValue: idea?.summary ?? "")
        _description = State(initialValue: idea?.descriptionText ?? "")
        _proposedApproach = State(initialValue: idea?.proposedApproach ?? "")
        _expectedContribution = State(initialValue: idea?.expectedContribution ?? "")
        _novelty = State(initialValue: idea?.novelty ?? "")
        _assumptions = State(initialValue: idea?.assumptions ?? "")
        _limitations = State(initialValue: idea?.limitations ?? "")
        _status = State(initialValue: idea?.status ?? .draft)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(idea == nil ? "New Research Idea" : "Edit Research Idea")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .rbHover(cornerRadius: RBRadius.field)
                .foregroundStyle(RBColor.secondaryText)

                Button("Save") {
                    onSave(
                        ResearchIdeaFormResult(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            summary: summary,
                            description: description,
                            proposedApproach: proposedApproach,
                            expectedContribution: expectedContribution,
                            novelty: novelty,
                            assumptions: assumptions,
                            limitations: limitations,
                            status: status
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
                    RBTextField(
                        label: "Title",
                        text: $title,
                        placeholder: "e.g. Sparse attention for long-sequence inference"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("STATUS")
                            .font(RBFont.label(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(RBColor.mutedText)

                        Picker("", selection: $status) {
                            ForEach(ResearchIdeaStatus.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    RBTextEditor(
                        label: "Summary",
                        text: $summary,
                        minHeight: 70
                    )

                    RBTextEditor(
                        label: "Description",
                        text: $description,
                        minHeight: 90
                    )

                    RBTextEditor(
                        label: "Proposed Approach",
                        text: $proposedApproach,
                        minHeight: 90
                    )

                    RBTextEditor(
                        label: "Expected Contribution",
                        text: $expectedContribution,
                        minHeight: 80
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("NOVELTY")
                                .font(RBFont.label(.semibold))
                                .tracking(0.6)
                                .foregroundStyle(RBColor.mutedText)

                            Text("— your own claim, not verified by ResearchBase")
                                .font(RBFont.label())
                                .foregroundStyle(RBColor.mutedText)
                        }

                        TextEditor(text: $novelty)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.primaryText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 70)
                            .padding(6)
                            .background(RBColor.card, in: RoundedRectangle(cornerRadius: RBRadius.field))
                            .overlay(
                                RoundedRectangle(cornerRadius: RBRadius.field)
                                    .stroke(RBColor.border)
                            )
                    }

                    RBTextEditor(
                        label: "Assumptions",
                        text: $assumptions,
                        minHeight: 70
                    )

                    RBTextEditor(
                        label: "Limitations",
                        text: $limitations,
                        minHeight: 70
                    )
                }
                .padding(24)
            }
        }
        .frame(width: 600, height: 720)
        .background(RBColor.background)
    }
}
