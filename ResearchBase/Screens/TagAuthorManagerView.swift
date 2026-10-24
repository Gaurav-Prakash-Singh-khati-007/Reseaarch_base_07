//
//  TagAuthorManagerView.swift
//  ResearchBase
//
//  Owner: Agent 46 · Features: X-03 (tag and author manager), F-08
//
//  One place to tidy tags and authors: rename, recolour, and merge
//  duplicates. It works only through `TagStore` and `CreatorStore`.
//
//  What it does
//    Tags      list with paper counts, search, new tag, rename, recolour,
//              "Merge into…" (all papers move to the other tag)
//    Authors   "Authors that look the same" (CreatorStore.lookalikes) with
//              Merge / Swap / Different people, then every author with
//              paper counts, search, "Edit…" (family, given, suffix,
//              organisation, ORCID) and "Merge into…"
//
//  PUBLIC API
//    TagAuthorManagerView(model:onClose:onChanged:)
//      model       the open LibraryModel
//      onClose     optional: when given, a Done button is shown and calls it
//      onChanged   called after any change (so other screens can refresh)
//
//    TagAuthorLogic (no views; used by the view and by the tests)
//      palette, color(for:), filterTags, filterAuthors, pairKey,
//      visibleLookalikes, suggestedKeeper, paperCountText, isValidORCID
//
//  Notes
//    * BLOCKED (schema is frozen): the schema has no place to keep an old
//      author spelling as an alias, so after a merge the old spelling is
//      gone and search no longer finds it. The screen does not promise aliases.
//    * BLOCKED (same reason): "Different people" is remembered only until the
//      window closes. There is no table to store it.
//    * Tags cannot be deleted: TagStore has no delete. Merge a tag away instead.
//    * Counts are papers that are not in the Trash (as the stores count them).
//

import SwiftUI

// MARK: - Logic

struct TagSwatch: Identifiable, Equatable {
    let name: String
    let hex: String
    var id: String { hex }
}

enum TagAuthorLogic {

    /// Colours offered in the tag colour menu ("#RRGGBB", accepted by TagStore.setColor).
    static let palette: [TagSwatch] = [
        TagSwatch(name: "Red", hex: "#E5484D"),
        TagSwatch(name: "Orange", hex: "#F76B15"),
        TagSwatch(name: "Yellow", hex: "#E5B800"),
        TagSwatch(name: "Green", hex: "#30A46C"),
        TagSwatch(name: "Teal", hex: "#12A594"),
        TagSwatch(name: "Blue", hex: "#3E63DD"),
        TagSwatch(name: "Purple", hex: "#8E4EC6"),
        TagSwatch(name: "Pink", hex: "#D6409F"),
        TagSwatch(name: "Gray", hex: "#8B8D98")
    ]

    /// The colour for a stored tag colour: "" (none), "#RRGGBB", or a colour word. nil = no colour.
    static func color(for stored: String) -> Color? {
        let text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
            return Color(hex: digits)
        }

        switch text.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        default: return nil
        }
    }

    /// Tags whose name contains the search text (ignoring case and accents). Empty search = all.
    static func filterTags(_ usage: [TagUsage], query: String) -> [TagUsage] {
        let wanted = TextNormalizer.norm(query)
        if wanted.isEmpty { return usage }
        return usage.filter { TextNormalizer.norm($0.tag.name).contains(wanted) }
    }

    /// Authors whose name (or ORCID) contains the search text. Empty search = all.
    static func filterAuthors(_ usage: [CreatorUsage], query: String) -> [CreatorUsage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = TextNormalizer.norm(trimmed)
        if wanted.isEmpty && trimmed.isEmpty { return usage }
        return usage.filter { entry in
            if !wanted.isEmpty && entry.creator.norm.contains(wanted) { return true }
            if let orcid = entry.creator.orcid, !trimmed.isEmpty, orcid.lowercased().contains(trimmed.lowercased()) { return true }
            return false
        }
    }

    /// A key for a pair of authors that is the same whichever one comes first.
    static func pairKey(_ first: String, _ second: String) -> String {
        [first, second].sorted().joined(separator: "|")
    }

    /// The look-alike pairs the user has not dismissed.
    static func visibleLookalikes(_ all: [CreatorLookalike], dismissed: Set<String>) -> [CreatorLookalike] {
        all.filter { !dismissed.contains(pairKey($0.first.creator.id, $0.second.creator.id)) }
    }

    /// Which author of a pair to keep by default: the one on more papers;
    /// on a tie the one with the fuller given name; on a tie the first.
    static func suggestedKeeper(_ pair: CreatorLookalike) -> (keep: CreatorUsage, drop: CreatorUsage) {
        let a = pair.first
        let b = pair.second
        if a.itemCount != b.itemCount {
            return a.itemCount > b.itemCount ? (a, b) : (b, a)
        }
        if a.creator.given.count != b.creator.given.count {
            return a.creator.given.count > b.creator.given.count ? (a, b) : (b, a)
        }
        return (a, b)
    }

    static func paperCountText(_ count: Int) -> String {
        switch count {
        case 0: return "Not used"
        case 1: return "1 paper"
        default: return "\(count) papers"
        }
    }

    /// Empty, or four groups of four like 0000-0000-0000-0000 (the last character may be X).
    static func isValidORCID(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return true }
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 4, groups.allSatisfy({ $0.count == 4 }) else { return false }
        for (index, group) in groups.enumerated() {
            for (position, character) in group.enumerated() {
                let isLast = index == 3 && position == 3
                if character.isASCII && character.isNumber { continue }
                if isLast && (character == "X" || character == "x") { continue }
                return false
            }
        }
        return true
    }
}

// MARK: - Small private types

private struct MergeCandidate: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

private struct MergeRequest: Identifiable {
    enum Kind: String { case tag, author }

    let kind: Kind
    let sourceID: String
    let sourceTitle: String
    let sourceCount: Int
    let candidates: [MergeCandidate]

    var id: String { kind.rawValue + sourceID }
}

private struct EditAuthorRequest: Identifiable {
    let creator: Creator
    var id: String { creator.id }
}

private enum ManagerTab: String, CaseIterable {
    case tags = "Tags"
    case authors = "Authors"
}

// MARK: - Manager

struct TagAuthorManagerView: View {

    let model: LibraryModel
    var onClose: (() -> Void)? = nil
    var onChanged: () -> Void = {}

    @State private var tab: ManagerTab = .tags
    @State private var query = ""

    @State private var tagUsage: [TagUsage] = []
    @State private var authorUsage: [CreatorUsage] = []
    @State private var lookalikes: [CreatorLookalike] = []

    @State private var dismissedPairs: Set<String> = []
    @State private var swappedPairs: Set<String> = []

    @State private var newTagName = ""
    @State private var renamingTagID: String?
    @State private var renameText = ""

    @State private var mergeRequest: MergeRequest?
    @State private var editRequest: EditAuthorRequest?

    @State private var errorText: String?
    @State private var noticeText: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(RBColor.border)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(ManagerTab.allCases, id: \.self) { item in
                        RBChip(text: item.rawValue, isSelected: tab == item) {
                            tab = item
                            query = ""
                            renamingTagID = nil
                        }
                    }
                    Spacer()
                }
                RBSearchField(placeholder: tab == .tags ? "Search tags" : "Search authors", text: $query)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorText { banner(errorText, isError: true) }
                    if let noticeText { banner(noticeText, isError: false) }

                    if tab == .tags { tagsContent } else { authorsContent }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(RBColor.background)
        .onAppear { reload() }
        .sheet(item: $mergeRequest) { request in
            MergePickerSheet(
                request: request,
                onMerge: { targetID in
                    mergeRequest = nil
                    performMerge(request, into: targetID)
                },
                onCancel: { mergeRequest = nil }
            )
        }
        .sheet(item: $editRequest) { request in
            AuthorEditSheet(
                creator: request.creator,
                onSave: { edited in
                    editRequest = nil
                    saveAuthor(edited)
                },
                onCancel: { editRequest = nil }
            )
        }
    }

    // MARK: Header and banners

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tags and authors")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text("Merge duplicates, rename and recolour")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }
            Spacer()
            if let onClose {
                Button("Done") { onClose() }
                    .buttonStyle(RBPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(RBColor.surface)
    }

    private func banner(_ text: String, isError: Bool) -> some View {
        let tone = isError ? RBColor.warning : RBColor.success
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tone)
            Text(text)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                if isError { errorText = nil } else { noticeText = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
            }
            .buttonStyle(RBHoverPlainButtonStyle())
            .help("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tone.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tone.opacity(0.3), lineWidth: 1))
    }

    // MARK: Tags

    private var tagsContent: some View {
        let shown = TagAuthorLogic.filterTags(tagUsage, query: query)

        return VStack(alignment: .leading, spacing: 10) {

            HStack(spacing: 8) {
                TextField("New tag", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createTag() }
                Button("Add tag") { createTag() }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if tagUsage.isEmpty {
                emptyCard("No tags yet", "Add a tag above, or tag a paper in the library.")
            } else if shown.isEmpty {
                emptyCard("No matching tags", "Try a different search.")
            } else {
                VStack(spacing: 6) {
                    ForEach(shown, id: \.tag.id) { usage in
                        tagRow(usage)
                    }
                }
            }

            Text("To remove a tag, merge it into another one. Merging moves every paper to the other tag; the other tag keeps its name and colour.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tagRow(_ usage: TagUsage) -> some View {
        let tag = usage.tag
        let isRenaming = renamingTagID == tag.id

        return HStack(spacing: 10) {

            Menu {
                ForEach(TagAuthorLogic.palette) { swatch in
                    Button(swatch.name) { setColor(tag, swatch.hex) }
                }
                Divider()
                Button("No colour") { setColor(tag, "") }
            } label: {
                Circle()
                    .fill(TagAuthorLogic.color(for: tag.color) ?? RBColor.mutedText.opacity(0.35))
                    .frame(width: 12, height: 12)
                    .padding(4)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Change colour")

            if isRenaming {
                TextField("Tag name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(tag) }
                    .onExitCommand { renamingTagID = nil }
                Button("Save") { commitRename(tag) }
                    .buttonStyle(RBPrimaryButtonStyle())
                Button("Cancel") { renamingTagID = nil }
                    .buttonStyle(RBGhostButtonStyle())
            } else {
                Text(tag.name)
                    .font(RBFont.body(.medium))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)
                Spacer()
                RBBadge(text: TagAuthorLogic.paperCountText(usage.itemCount), tone: .muted)
                Button("Rename") {
                    renameText = tag.name
                    renamingTagID = tag.id
                }
                .buttonStyle(RBGhostButtonStyle())
                Button("Merge into…") { askMerge(tag: usage) }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(tagUsage.count < 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RBColor.card)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }

    // MARK: Authors

    private var authorsContent: some View {
        let pairs = TagAuthorLogic.visibleLookalikes(lookalikes, dismissed: dismissedPairs)
        let shown = TagAuthorLogic.filterAuthors(authorUsage, query: query)

        return VStack(alignment: .leading, spacing: 14) {

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    RBSectionLabel(text: "Authors that look the same")

                    if pairs.isEmpty {
                        emptyCard("No look-alike authors", "Spellings like “Li, Tian” and “Li, T.” would show up here.")
                    } else {
                        ForEach(pairs, id: \.first.creator.id) { pair in
                            lookalikeCard(pair)
                        }
                    }

                    Text("Matching ignores accents and punctuation. Merging moves every paper to the author you keep and removes the other spelling. “Different people” hides a pair until you close this window.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                RBSectionLabel(text: "All authors")

                if authorUsage.isEmpty {
                    emptyCard("No authors yet", "Authors appear here when you add papers.")
                } else if shown.isEmpty {
                    emptyCard("No matching authors", "Try a different search.")
                } else {
                    ForEach(shown, id: \.creator.id) { usage in
                        authorRow(usage)
                    }
                }
            }
        }
    }

    private func lookalikeCard(_ pair: CreatorLookalike) -> some View {
        let key = TagAuthorLogic.pairKey(pair.first.creator.id, pair.second.creator.id)
        let suggested = TagAuthorLogic.suggestedKeeper(pair)
        let swapped = swappedPairs.contains(key)
        let keep = swapped ? suggested.drop : suggested.keep
        let drop = swapped ? suggested.keep : suggested.drop

        return RBCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Keep")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                                .frame(width: 52, alignment: .leading)
                            Text(keep.creator.displayName)
                                .font(RBFont.body(.semibold))
                                .foregroundStyle(RBColor.primaryText)
                            Text(TagAuthorLogic.paperCountText(keep.itemCount))
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        }
                        HStack(spacing: 6) {
                            Text("Merge in")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                                .frame(width: 52, alignment: .leading)
                            Text(drop.creator.displayName)
                                .font(RBFont.body())
                                .foregroundStyle(RBColor.primaryText)
                            Text(TagAuthorLogic.paperCountText(drop.itemCount))
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button("Merge") { mergeAuthors(drop: drop.creator, into: keep.creator) }
                        .buttonStyle(RBPrimaryButtonStyle())
                    Button {
                        if swapped { swappedPairs.remove(key) } else { swappedPairs.insert(key) }
                    } label: {
                        Label("Swap", systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(RBGhostButtonStyle())
                    .help("Keep the other spelling instead")
                    Button("Different people") { dismissedPairs.insert(key) }
                        .buttonStyle(RBGhostButtonStyle())
                }
            }
        }
    }

    private func authorRow(_ usage: CreatorUsage) -> some View {
        let creator = usage.creator

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(creator.displayName)
                        .font(RBFont.body(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .lineLimit(1)
                    if creator.isOrganisation { RBBadge(text: "Organisation", tone: .neutral) }
                }
                if let orcid = creator.orcid {
                    Text("ORCID \(orcid)")
                        .font(RBFont.caption().monospaced())
                        .foregroundStyle(RBColor.mutedText)
                }
            }
            Spacer()
            RBBadge(text: TagAuthorLogic.paperCountText(usage.itemCount), tone: .muted)
            Button("Edit…") { editRequest = EditAuthorRequest(creator: creator) }
                .buttonStyle(RBGhostButtonStyle())
            Button("Merge into…") { askMerge(author: usage) }
                .buttonStyle(RBGhostButtonStyle())
                .disabled(authorUsage.count < 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RBColor.card)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.field))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.border))
    }

    private func emptyCard(_ title: String, _ detail: String) -> some View {
        RBCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text(detail)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        do {
            tagUsage = try model.tags.usage()
            authorUsage = try model.creators.allWithUsage()
            lookalikes = try model.creators.lookalikes()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func changed(_ message: String? = nil) {
        errorText = nil
        noticeText = message
        reload()
        onChanged()
    }

    private func createTag() {
        do {
            let created = try model.tags.create(name: newTagName)
            newTagName = ""
            changed("Added the tag “\(created.name)”.")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func commitRename(_ tag: Tag) {
        do {
            let renamed = try model.tags.rename(id: tag.id, to: renameText)
            renamingTagID = nil
            changed(renamed.name == tag.name ? nil : "Renamed “\(tag.name)” to “\(renamed.name)”.")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setColor(_ tag: Tag, _ hex: String) {
        do {
            try model.tags.setColor(id: tag.id, to: hex)
            changed()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func askMerge(tag usage: TagUsage) {
        mergeRequest = MergeRequest(
            kind: .tag,
            sourceID: usage.tag.id,
            sourceTitle: usage.tag.name,
            sourceCount: usage.itemCount,
            candidates: tagUsage
                .filter { $0.tag.id != usage.tag.id }
                .map { MergeCandidate(id: $0.tag.id, title: $0.tag.name, count: $0.itemCount) }
        )
    }

    private func askMerge(author usage: CreatorUsage) {
        mergeRequest = MergeRequest(
            kind: .author,
            sourceID: usage.creator.id,
            sourceTitle: usage.creator.displayName,
            sourceCount: usage.itemCount,
            candidates: authorUsage
                .filter { $0.creator.id != usage.creator.id }
                .map { MergeCandidate(id: $0.creator.id, title: $0.creator.displayName, count: $0.itemCount) }
        )
    }

    private func performMerge(_ request: MergeRequest, into targetID: String) {
        let targetTitle = request.candidates.first { $0.id == targetID }?.title ?? "the other one"
        do {
            switch request.kind {
            case .tag:
                try model.tags.merge(request.sourceID, into: targetID)
                changed("Merged the tag “\(request.sourceTitle)” into “\(targetTitle)”.")
            case .author:
                try model.creators.merge(request.sourceID, into: targetID)
                changed("Merged “\(request.sourceTitle)” into “\(targetTitle)”.")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func mergeAuthors(drop: Creator, into keep: Creator) {
        do {
            try model.creators.merge(drop.id, into: keep.id)
            changed("Merged “\(drop.displayName)” into “\(keep.displayName)”.")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveAuthor(_ edited: Creator) {
        do {
            try model.creators.update(id: edited.id) { creator in
                creator.family = edited.family
                creator.given = edited.given
                creator.suffix = edited.suffix
                creator.isOrganisation = edited.isOrganisation
                creator.orcid = edited.orcid
            }
            changed("Saved “\(edited.displayName)”.")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Merge picker

private struct MergePickerSheet: View {

    let request: MergeRequest
    let onMerge: (String) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selectedID: String?

    private var shown: [MergeCandidate] {
        let wanted = TextNormalizer.norm(query)
        if wanted.isEmpty { return request.candidates }
        return request.candidates.filter { TextNormalizer.norm($0.title).contains(wanted) }
    }

    private var noun: String { request.kind == .tag ? "tag" : "author" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            VStack(alignment: .leading, spacing: 3) {
                Text("Merge “\(request.sourceTitle)” into…")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text("Choose the \(noun) to keep. All \(TagAuthorLogic.paperCountText(request.sourceCount).lowercased()) of “\(request.sourceTitle)” move to it, and “\(request.sourceTitle)” is removed.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            RBSearchField(placeholder: "Search \(noun)s", text: $query)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(shown) { candidate in
                        RBRow(isSelected: selectedID == candidate.id, action: { selectedID = candidate.id }) {
                            HStack {
                                Text(candidate.title)
                                    .font(RBFont.body(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                Spacer()
                                Text(TagAuthorLogic.paperCountText(candidate.count))
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.secondaryText)
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("Nothing matches.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(height: 260)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(RBGhostButtonStyle())
                Button("Merge") {
                    if let selectedID { onMerge(selectedID) }
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(selectedID == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(RBColor.elevatedSurface)
    }
}

// MARK: - Author editor

private struct AuthorEditSheet: View {

    let creator: Creator
    let onSave: (Creator) -> Void
    let onCancel: () -> Void

    @State private var family: String
    @State private var given: String
    @State private var suffix: String
    @State private var isOrganisation: Bool
    @State private var orcid: String

    init(creator: Creator, onSave: @escaping (Creator) -> Void, onCancel: @escaping () -> Void) {
        self.creator = creator
        self.onSave = onSave
        self.onCancel = onCancel
        _family = State(initialValue: creator.family)
        _given = State(initialValue: creator.given)
        _suffix = State(initialValue: creator.suffix)
        _isOrganisation = State(initialValue: creator.isOrganisation)
        _orcid = State(initialValue: creator.orcid ?? "")
    }

    private var orcidIsValid: Bool { TagAuthorLogic.isValidORCID(orcid) }

    private var canSave: Bool {
        !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && orcidIsValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text("Edit author")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
            Text("Every paper that uses this author shows the new spelling.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)

            VStack(alignment: .leading, spacing: 10) {
                field(isOrganisation ? "Organisation" : "Family name") {
                    TextField("", text: $family).textFieldStyle(.roundedBorder)
                }
                if !isOrganisation {
                    field("Given names") {
                        TextField("", text: $given).textFieldStyle(.roundedBorder)
                    }
                    field("Suffix") {
                        TextField("For example Jr.", text: $suffix).textFieldStyle(.roundedBorder)
                    }
                }
                field("ORCID") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("0000-0000-0000-0000", text: $orcid).textFieldStyle(.roundedBorder)
                        if !orcidIsValid {
                            Text("An ORCID looks like 0000-0000-0000-0000.")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.warning)
                        }
                    }
                }
                Toggle("This is an organisation", isOn: $isOrganisation)
                    .font(RBFont.caption())
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(RBGhostButtonStyle())
                Button("Save") { save() }
                    .buttonStyle(RBPrimaryButtonStyle())
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(RBColor.elevatedSurface)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .frame(width: 110, alignment: .leading)
                .padding(.top, 5)
            content()
        }
    }

    private func save() {
        var edited = creator
        edited.family = family
        edited.given = isOrganisation ? "" : given
        edited.suffix = isOrganisation ? "" : suffix
        edited.isOrganisation = isOrganisation
        let trimmed = orcid.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.orcid = trimmed.isEmpty ? nil : trimmed
        onSave(edited)
    }
}
