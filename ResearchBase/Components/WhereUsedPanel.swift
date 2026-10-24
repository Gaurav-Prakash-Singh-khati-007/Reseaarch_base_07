//
//  WhereUsedPanel.swift
//  ResearchBase
//
//  Owner: Agent 45 · Features: F-45 ("Where is this used?" panel)
//
//  A panel for any record (paper, note, experiment, draft, project, task...)
//  that lists everything linked to it: the drafts, projects, tasks,
//  experiments, papers, notes and ideas that use it, or that it uses.
//  Everything comes from the one link table (`LinkStore`), seen from both
//  sides. Records in the Trash (or gone) are hidden and counted.
//
//  PUBLIC API
//    WhereUsedPanel(model:end:reloadToken:allowsUnlink:onOpen:onChanged:)
//      model          the open LibraryModel
//      end            the record to ask about, e.g. LinkEnd(.item, paperID)
//      reloadToken    change it to make the panel reload (after the parent adds a link)
//      allowsUnlink   shows a "remove link" button per row (default false)
//      onOpen         optional: called with the other record when a row is clicked
//      onChanged      called after a link is removed
//
//    WhereUsedLogic (no views; used by the panel and by the tests)
//      load(for:model:includeTrashed:) throws -> WhereUsedResult
//      relationText(_:direction:)      -> String   ("Uses", "Used by", "Cited by"...)
//    WhereUsedResult { groups, hiddenCount, totalCount }
//    WhereUsedGroup  { kind, entries }   WhereUsedGroupKind (drafts, projects, tasks,
//                                          experiments, papers, notes, reviews, collections)
//    WhereUsedEntry  { linkID, other, direction, rel, relationText, title, subtitle, isTrashed }
//
//  Notes
//    * Read-only apart from "remove link", which uses LinkStore.remove.
//    * Adding links is done elsewhere (the link picker); this panel only shows them.
//

import SwiftUI

// MARK: - Value types

enum WhereUsedGroupKind: Int, CaseIterable, Equatable {
    case drafts, projects, tasks, experiments, papers, notes, reviews, collections

    init(_ type: LinkEntity) {
        switch type {
        case .draft: self = .drafts
        case .project: self = .projects
        case .task: self = .tasks
        case .experiment: self = .experiments
        case .item: self = .papers
        case .thought: self = .notes
        case .review: self = .reviews
        case .collection: self = .collections
        }
    }

    var title: String {
        switch self {
        case .drafts: return "Drafts"
        case .projects: return "Projects"
        case .tasks: return "Tasks"
        case .experiments: return "Experiments"
        case .papers: return "Papers"
        case .notes: return "Notes and ideas"
        case .reviews: return "Literature reviews"
        case .collections: return "Collections"
        }
    }

    var symbol: String {
        switch self {
        case .drafts: return "doc.text"
        case .projects: return "folder"
        case .tasks: return "checkmark.square"
        case .experiments: return "testtube.2"
        case .papers: return "doc"
        case .notes: return "note.text"
        case .reviews: return "books.vertical"
        case .collections: return "tray.full"
        }
    }
}

struct WhereUsedEntry: Identifiable, Equatable {
    let linkID: String
    let other: LinkEnd
    let direction: LinkDirection
    let rel: LinkRel
    let relationText: String
    let title: String
    /// For notes and ideas: Note, Finding, Gap, Problem or Idea. Empty otherwise.
    let subtitle: String
    let isTrashed: Bool

    var id: String { linkID }
}

struct WhereUsedGroup: Identifiable, Equatable {
    let kind: WhereUsedGroupKind
    let entries: [WhereUsedEntry]

    var id: Int { kind.rawValue }
}

struct WhereUsedResult: Equatable {
    var groups: [WhereUsedGroup]
    /// Linked records that are in the Trash or no longer exist (not listed).
    var hiddenCount: Int

    var totalCount: Int { groups.reduce(0) { $0 + $1.entries.count } }
}

// MARK: - Logic

enum WhereUsedLogic {

    /// Everything linked to `end`, from both sides, grouped by kind of record.
    /// Groups follow the order of `WhereUsedGroupKind`; inside a group the oldest link comes first.
    static func load(for end: LinkEnd, model: LibraryModel, includeTrashed: Bool = false) throws -> WhereUsedResult {

        var entries: [WhereUsedEntry] = []
        var hidden = 0

        for linked in try model.links.links(for: end) {
            let info = try describe(linked.other, model: model)

            if info.isTrashed && !includeTrashed {
                hidden += 1
                continue
            }

            entries.append(WhereUsedEntry(
                linkID: linked.link.id,
                other: linked.other,
                direction: linked.direction,
                rel: linked.link.rel,
                relationText: relationText(linked.link.rel, direction: linked.direction),
                title: info.title,
                subtitle: info.subtitle,
                isTrashed: info.isTrashed
            ))
        }

        let groups = WhereUsedGroupKind.allCases.compactMap { kind -> WhereUsedGroup? in
            let inGroup = entries.filter { WhereUsedGroupKind($0.other.type) == kind }
            return inGroup.isEmpty ? nil : WhereUsedGroup(kind: kind, entries: inGroup)
        }

        return WhereUsedResult(groups: groups, hiddenCount: hidden)
    }

    /// How the link reads from the point of view of the record the panel is about.
    static func relationText(_ rel: LinkRel, direction: LinkDirection) -> String {
        let outgoing = direction == .outgoing
        switch rel {
        case .related: return "Related"
        case .cites: return outgoing ? "Cites" : "Cited by"
        case .supports: return outgoing ? "Supports" : "Supported by"
        case .contradicts: return outgoing ? "Contradicts" : "Contradicted by"
        case .uses: return outgoing ? "Uses" : "Used by"
        case .extends: return outgoing ? "Extends" : "Extended by"
        case .partOf: return outgoing ? "Part of" : "Contains"
        case .derivedFrom: return outgoing ? "Derived from" : "Source of"
        }
    }

    // MARK: Looking up the other end

    private struct Described {
        let title: String
        let subtitle: String
        let isTrashed: Bool
    }

    private static func describe(_ end: LinkEnd, model: LibraryModel) throws -> Described {

        if end.type == .thought {
            guard let thought = try ThoughtStore(model: model).fetch(id: end.id, includeDeleted: true) else {
                return Described(title: "Missing record", subtitle: "", isTrashed: true)
            }
            return Described(
                title: thought.title.isEmpty ? "Untitled" : thought.title,
                subtitle: thought.kind.rawValue.capitalized,
                isTrashed: thought.deletedAt != nil
            )
        }

        // Both the table and the column come from fixed lists, never from user text.
        let titleColumn: String
        switch end.type {
        case .item, .task, .draft, .review: titleColumn = "title"
        case .experiment, .project, .collection: titleColumn = "name"
        case .thought: titleColumn = "title"
        }

        let rows = try model.database.rows(
            "SELECT \(titleColumn) AS shown_title, deleted_at FROM \(end.type.table) WHERE id = ?",
            [.text(end.id)]
        )
        guard let row = rows.first else {
            return Described(title: "Missing record", subtitle: "", isTrashed: true)
        }

        let title = row.text("shown_title") ?? ""
        return Described(
            title: title.isEmpty ? "Untitled" : title,
            subtitle: "",
            isTrashed: row.text("deleted_at") != nil
        )
    }
}

// MARK: - Panel

struct WhereUsedPanel: View {

    let model: LibraryModel
    let end: LinkEnd
    var reloadToken: Int = 0
    var allowsUnlink: Bool = false
    var onOpen: ((LinkEnd) -> Void)? = nil
    var onChanged: () -> Void = {}

    @State private var result = WhereUsedResult(groups: [], hiddenCount: 0)
    @State private var errorText: String?
    @State private var unlinking: WhereUsedEntry?

    private struct LoadKey: Hashable {
        let end: LinkEnd
        let token: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 8) {
                Text("Where is this used?")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                if result.totalCount > 0 {
                    RBBadge(text: "\(result.totalCount)", tone: .muted)
                }
                Spacer()
            }

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

            if result.groups.isEmpty {
                RBCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not used anywhere yet")
                            .font(RBFont.body(.semibold))
                            .foregroundStyle(RBColor.primaryText)
                        Text("When a draft, note, task, project or experiment links to this, it shows up here.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(result.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        RBSectionLabel(text: group.kind.title)
                        ForEach(group.entries) { entry in
                            entryRow(entry, kind: group.kind)
                        }
                    }
                }
            }

            if result.hiddenCount > 0 {
                Text(result.hiddenCount == 1
                     ? "1 linked record is in the Trash or no longer exists, so it is not listed."
                     : "\(result.hiddenCount) linked records are in the Trash or no longer exist, so they are not listed.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: LoadKey(end: end, token: reloadToken)) { reload() }
        .confirmationDialog(
            unlinking.map { "Remove the link to “\($0.title)”?" } ?? "Remove this link?",
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove link", role: .destructive) {
                if let target = unlinking { unlink(target) }
                unlinking = nil
            }
            Button("Cancel", role: .cancel) { unlinking = nil }
        } message: {
            Text("Only the link is removed. Both records stay as they are.")
        }
    }

    // MARK: Row

    private func entryRow(_ entry: WhereUsedEntry, kind: WhereUsedGroupKind) -> some View {
        HStack(spacing: 6) {
            if let onOpen {
                RBRow(action: { onOpen(entry.other) }) {
                    rowContent(entry, kind: kind, showsChevron: true)
                }
            } else {
                rowContent(entry, kind: kind, showsChevron: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RBColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
                    .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
            }

            if allowsUnlink {
                Button { unlinking = entry } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                }
                .buttonStyle(RBHoverPlainButtonStyle())
                .help("Remove link")
            }
        }
    }

    private func rowContent(_ entry: WhereUsedEntry, kind: WhereUsedGroupKind, showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13))
                .foregroundStyle(RBColor.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(2)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
            }

            Spacer(minLength: 8)

            if entry.isTrashed {
                RBBadge(text: "In Trash", tone: .warning)
            }
            RBBadge(text: entry.relationText, tone: .neutral)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        do {
            result = try WhereUsedLogic.load(for: end, model: model)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func unlink(_ entry: WhereUsedEntry) {
        do {
            try model.links.remove(linkID: entry.linkID)
            reload()
            onChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
