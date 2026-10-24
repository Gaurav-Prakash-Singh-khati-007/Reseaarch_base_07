//
//  MergeDuplicatesSheet.swift
//  ResearchBase
//
//  Owner: Agent 59 · Features: F-18 (real merge)
//  Source of truth: docs/researchbase.html (F-18, F-13, F-12, Merge duplicates)
//  Compares two copies side-by-side with a choice per field, then merges them.
//
//  What a merge does (all in ONE all-or-nothing step, recorded in the change log so History can undo it)
//    * The copy "In your library" is the one that survives. Its citation key is kept.
//    * Each field you pick "New copy" for is written onto the survivor (authors included).
//    * Tags, folders, links and files (that the survivor does not already have, by fingerprint)
//      of the new copy are added to the survivor. Rating, queue flag and reading status keep the higher value.
//    * The new copy goes to the Trash. Nothing is deleted for good.
//    * If drafts cite the NEW copy's key, the merge is refused (their citations would end up in the Trash).
//
//  PUBLIC API (the original call still compiles: MergeDuplicatesSheet(existingTitle:newTitle:onDismiss:onMerge:))
//    MergeDuplicatesSheet(existingTitle:newTitle:existingID:newID:model:onDismiss:onMerge:onMerged:onKeepBoth:)
//      model + both ids set   real merge; onMerged(MergeSummary) is called, onMerge is NOT
//      otherwise              hand-off mode: only the two titles are shown and Merge calls onMerge()
//      onKeepBoth             called when the person taps "Keep both" (nothing is changed)
//    ItemMerger(model:)       @MainActor. preview(existingID:newID:) throws -> MergePreview
//                                         merge(existingID:newID:choices:) throws -> MergeSummary
//                             (reusable by the Inbox row action)
//    MergeLogic               pure helpers (field rows, default choices, applying choices, summary text)
//    MergeFieldKey / MergeChoice / MergeField / MergePreview / MergeSummary / ItemMergeError
//
//  Reads (does not edit): LibraryModel, ItemStore, CreatorStore, AttachmentStore, LinkStore,
//  DuplicateDetector, ModelTypes, ChangeSink. Raw SQL only touches item_tags, collection_items,
//  attachments and items.deleted_at, on tables that already exist.
//

import SwiftUI

// MARK: - Vocabulary

enum MergeChoice: Equatable {
    case existing
    case new
}

enum MergeFieldKey: String, CaseIterable {
    case title, authors, venue, year, doi, arxivID
    case type, abstract, url, volume, issue, pages, publisher

    var label: String {
        switch self {
        case .title: return "Title"
        case .authors: return "Authors"
        case .venue: return "Venue"
        case .year: return "Year"
        case .doi: return "DOI"
        case .arxivID: return "arXiv ID"
        case .type: return "Item type"
        case .abstract: return "Abstract"
        case .url: return "Web address"
        case .volume: return "Volume"
        case .issue: return "Issue"
        case .pages: return "Pages"
        case .publisher: return "Publisher"
        }
    }

    /// Shown even when both copies agree.
    var alwaysShown: Bool {
        switch self {
        case .title, .authors, .venue, .year, .doi, .arxivID: return true
        default: return false
        }
    }
}

struct MergeField: Identifiable, Equatable {
    var key: MergeFieldKey
    var existing: String
    var new: String
    var choice: MergeChoice

    var id: String { key.rawValue }
    var isSame: Bool { existing == new }
}

struct MergePreview {
    var existing: ModelItem
    var new: ModelItem
    var existingCreators: [ItemCreator]
    var newCreators: [ItemCreator]
    var fields: [MergeField]
    var matchedBy: [DuplicateReason]
    var tagsToAdd: Int
    var foldersToAdd: Int
    var linksToMove: Int
    var filesToMove: Int
    var filesAlreadyThere: Int
    /// Drafts that cite the NEW copy. Above zero, the merge is refused.
    var draftsCitingNew: Int
}

struct MergeSummary: Equatable {
    var survivorID: String
    var trashedID: String
    var fieldsChanged: [MergeFieldKey]
    var tagsAdded: Int
    var foldersAdded: Int
    var linksMoved: Int
    var filesMoved: Int
}

enum ItemMergeError: LocalizedError, Equatable {
    case sameItem
    case citedByDrafts(count: Int, key: String)

    var errorDescription: String? {
        switch self {
        case .sameItem:
            return "These are the same paper, so there is nothing to merge."
        case .citedByDrafts(let count, let key):
            return "\(count == 1 ? "A draft cites" : "\(count) drafts cite") the new copy as “\(key)”. Change those citations to the copy in your library first, then merge. Nothing was changed."
        }
    }
}

// MARK: - Pure helpers (unit-tested in MergeDuplicatesSheetTests)

enum MergeLogic {

    static func authorsText(_ creators: [ItemCreator]) -> String {
        creators.map { $0.creator.displayName }.joined(separator: "; ")
    }

    static func value(_ key: MergeFieldKey, of item: ModelItem, creators: [ItemCreator]) -> String {
        switch key {
        case .title: return item.title
        case .authors: return authorsText(creators)
        case .venue: return item.venue
        case .year: return item.year.map(String.init) ?? ""
        case .doi: return item.doi ?? ""
        case .arxivID: return item.arxivID ?? ""
        case .type: return item.type.displayName
        case .abstract: return item.abstract
        case .url: return item.url
        case .volume: return item.volume
        case .issue: return item.issue
        case .pages: return item.pages
        case .publisher: return item.publisher
        }
    }

    /// Keep the library's value, unless it is empty and the new copy has one.
    static func defaultChoice(existing: String, new: String) -> MergeChoice {
        let a = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = new.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty && !b.isEmpty ? .new : .existing
    }

    /// The rows the sheet shows: the key rows always, the others only when the copies differ.
    static func fields(
        existing: ModelItem, existingCreators: [ItemCreator],
        new: ModelItem, newCreators: [ItemCreator]
    ) -> [MergeField] {
        MergeFieldKey.allCases.compactMap { key in
            let a = value(key, of: existing, creators: existingCreators)
            let b = value(key, of: new, creators: newCreators)
            guard key.alwaysShown || a != b else { return nil }
            return MergeField(key: key, existing: a, new: b, choice: defaultChoice(existing: a, new: b))
        }
    }

    /// Copies onto `item` every field the person chose "New copy" for (authors are handled by the caller).
    static func apply(_ choices: [MergeFieldKey: MergeChoice], from other: ModelItem, to item: inout ModelItem) {
        for (key, choice) in choices where choice == .new {
            switch key {
            case .title:
                if !other.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.title = other.title }
            case .authors: break
            case .venue: item.venue = other.venue
            case .year: item.year = other.year
            case .doi: item.doi = other.doi
            case .arxivID: item.arxivID = other.arxivID
            case .type: item.type = other.type
            case .abstract: item.abstract = other.abstract
            case .url: item.url = other.url
            case .volume: item.volume = other.volume
            case .issue: item.issue = other.issue
            case .pages: item.pages = other.pages
            case .publisher: item.publisher = other.publisher
            }
        }
    }

    /// Higher rating, in-queue if either was, the furthest reading status.
    static func mergeStatus(from other: ModelItem, to item: inout ModelItem) {
        func rank(_ s: ItemReadingStatus) -> Int {
            switch s {
            case .unread: return 0
            case .reading: return 1
            case .read: return 2
            }
        }
        item.rating = max(item.rating, other.rating)
        item.inQueue = item.inQueue || other.inQueue
        if rank(other.readingStatus) > rank(item.readingStatus) { item.readingStatus = other.readingStatus }
    }

    /// "DOI and identical file" -> "Matched by DOI and identical file."
    static func matchedText(_ reasons: [DuplicateReason]) -> String {
        let names = reasons.sorted().map(\.displayName)
        switch names.count {
        case 0: return "These look like the same paper."
        case 1: return "Matched by \(names[0])."
        default: return "Matched by " + names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") + "."
        }
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// "2 tags, 1 folder and 3 links will be added" or nil when there is nothing to combine.
    static func combineText(tags: Int, folders: Int, links: Int, files: Int) -> String? {
        var parts: [String] = []
        if tags > 0 { parts.append(plural(tags, "tag", "tags")) }
        if folders > 0 { parts.append(plural(folders, "folder", "folders")) }
        if links > 0 { parts.append(plural(links, "link", "links")) }
        if files > 0 { parts.append(plural(files, "file", "files")) }
        guard !parts.isEmpty else { return nil }
        let joined = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "Will be added to the kept copy: \(joined)."
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - The merge itself

@MainActor
final class ItemMerger {

    private let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Preview

    func preview(existingID: String, newID: String) throws -> MergePreview {
        guard existingID != newID else { throw ItemMergeError.sameItem }
        guard let existing = try model.items.fetch(id: existingID) else {
            throw ModelError.notFound(kind: "paper", id: existingID)
        }
        guard let new = try model.items.fetch(id: newID) else {
            throw ModelError.notFound(kind: "paper", id: newID)
        }

        let existingCreators = try model.creators.creators(of: existingID)
        let newCreators = try model.creators.creators(of: newID)

        let matched = (try? DuplicateDetector(model: model).reasons(between: existingID, and: newID)) ?? []
        let plan = try movePlan(existingID: existingID, newID: newID)

        return MergePreview(
            existing: existing,
            new: new,
            existingCreators: existingCreators,
            newCreators: newCreators,
            fields: MergeLogic.fields(
                existing: existing, existingCreators: existingCreators,
                new: new, newCreators: newCreators
            ),
            matchedBy: matched,
            tagsToAdd: plan.tagIDs.count,
            foldersToAdd: plan.folderIDs.count,
            linksToMove: plan.links.count,
            filesToMove: plan.attachments.count,
            filesAlreadyThere: plan.duplicateFiles,
            draftsCitingNew: try draftCount(citing: newID)
        )
    }

    // MARK: Merge

    @discardableResult
    func merge(existingID: String, newID: String, choices: [MergeFieldKey: MergeChoice]) throws -> MergeSummary {

        guard existingID != newID else { throw ItemMergeError.sameItem }

        return try model.atomically {

            guard let existing = try model.items.fetch(id: existingID) else {
                throw ModelError.notFound(kind: "paper", id: existingID)
            }
            guard let new = try model.items.fetch(id: newID) else {
                throw ModelError.notFound(kind: "paper", id: newID)
            }

            let cited = try draftCount(citing: newID)
            if cited > 0 { throw ItemMergeError.citedByDrafts(count: cited, key: new.citationKey) }

            let newCreators = try model.creators.creators(of: newID)
            let plan = try movePlan(existingID: existingID, newID: newID)
            let now = model.now()

            // 1. The new copy goes to the Trash first, so its identifiers are free for the kept copy.
            try model.database.run(
                "UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ?",
                [.text(now), .text(now), .text(newID)]
            )
            try model.record("item", newID, .delete, field: "deleted_at", old: nil, new: now)

            // 2. Tags and folders.
            for tagID in plan.tagIDs {
                try model.database.run(
                    "INSERT OR IGNORE INTO item_tags (item_id, tag_id) VALUES (?, ?)",
                    [.text(existingID), .text(tagID)]
                )
            }
            for folderID in plan.folderIDs {
                try model.database.run(
                    "INSERT OR IGNORE INTO collection_items (collection_id, item_id) VALUES (?, ?)",
                    [.text(folderID), .text(existingID)]
                )
            }

            // 3. Links: re-point each one at the kept copy (add dedupes), then drop the old one.
            let newEnd = LinkEnd(.item, newID)
            let keptEnd = LinkEnd(.item, existingID)
            var linksMoved = 0
            for entry in plan.links {
                let link = entry.link
                if entry.other != keptEnd {
                    let from = link.from == newEnd ? keptEnd : link.from
                    let to = link.to == newEnd ? keptEnd : link.to
                    try model.links.add(from: from, to: to, rel: link.rel, note: link.note)
                    linksMoved += 1
                }
                try model.links.remove(linkID: link.id)
            }

            // 4. Files the kept copy does not have yet (annotations follow their file).
            let hadPrimary = (try model.database.scalarInt(
                "SELECT COUNT(*) FROM attachments WHERE item_id = ? AND is_primary = 1 AND deleted_at IS NULL",
                [.text(existingID)]
            ) ?? 0) > 0
            for attachment in plan.attachments {
                try model.database.run(
                    "UPDATE attachments SET item_id = ?, is_primary = 0 WHERE id = ?",
                    [.text(existingID), .text(attachment.id)]
                )
                try model.record("attachment", attachment.id, .update, field: "item_id", old: newID, new: existingID)
            }
            if !hadPrimary, let firstPDF = plan.attachments.first(where: { $0.kind == .pdf }) {
                try model.attachments.setPrimary(attachmentID: firstPDF.id)
            }

            // 5. Fields. Each changed field is recorded by ItemStore.update with old and new value.
            var fieldsChanged: [MergeFieldKey] = []
            for (key, choice) in choices where choice == .new {
                let before = MergeLogic.value(key, of: existing, creators: try model.creators.creators(of: existingID))
                let after = MergeLogic.value(key, of: new, creators: newCreators)
                if before != after { fieldsChanged.append(key) }
            }
            fieldsChanged.sort { $0.rawValue < $1.rawValue }

            try model.items.update(id: existingID) { item in
                MergeLogic.apply(choices, from: new, to: &item)
                MergeLogic.mergeStatus(from: new, to: &item)
            }
            if choices[.authors] == .new {
                let inputs = newCreators.map { slot in
                    CreatorInput(
                        family: slot.creator.family, given: slot.creator.given, suffix: slot.creator.suffix,
                        isOrganisation: slot.creator.isOrganisation, orcid: slot.creator.orcid, role: slot.role
                    )
                }
                try model.creators.setCreators(itemID: existingID, inputs)
            }

            // 6. One entry that says what moved, so History can show and undo the merge.
            let snapshot = LibraryModel.json([
                "kept": existingID,
                "trashed": newID,
                "tags": plan.tagIDs,
                "folders": plan.folderIDs,
                "links": plan.links.map { $0.link.id },
                "files": plan.attachments.map { $0.id },
                "fields": fieldsChanged.map(\.rawValue)
            ] as [String: Any])
            try model.record("item", newID, .merge, field: "merged_into", old: snapshot, new: existingID)

            return MergeSummary(
                survivorID: existingID,
                trashedID: newID,
                fieldsChanged: fieldsChanged,
                tagsAdded: plan.tagIDs.count,
                foldersAdded: plan.folderIDs.count,
                linksMoved: linksMoved,
                filesMoved: plan.attachments.count
            )
        }
    }

    // MARK: Helpers

    private struct MovePlan {
        var tagIDs: [String]
        var folderIDs: [String]
        var links: [LinkedEntry]
        var attachments: [Attachment]
        var duplicateFiles: Int
    }

    private func movePlan(existingID: String, newID: String) throws -> MovePlan {

        let tagIDs = try model.database.rows(
            """
            SELECT tag_id FROM item_tags WHERE item_id = ?
              AND tag_id NOT IN (SELECT tag_id FROM item_tags WHERE item_id = ?)
            ORDER BY tag_id
            """,
            [.text(newID), .text(existingID)]
        ).compactMap { $0.text("tag_id") }

        let folderIDs = try model.database.rows(
            """
            SELECT collection_id FROM collection_items WHERE item_id = ?
              AND collection_id NOT IN (SELECT collection_id FROM collection_items WHERE item_id = ?)
            ORDER BY collection_id
            """,
            [.text(newID), .text(existingID)]
        ).compactMap { $0.text("collection_id") }

        let links = try model.links.links(for: LinkEnd(.item, newID))

        // Any file the kept copy already has (same fingerprint, even one in its trash) is not moved.
        let keptHashes = Set(
            try model.attachments.attachments(of: existingID, includeDeleted: true).map { $0.sha256.lowercased() }
        )
        var movable: [Attachment] = []
        var duplicates = 0
        for attachment in try model.attachments.attachments(of: newID) {
            if keptHashes.contains(attachment.sha256.lowercased()) {
                duplicates += 1
            } else {
                movable.append(attachment)
            }
        }

        return MovePlan(tagIDs: tagIDs, folderIDs: folderIDs, links: links, attachments: movable, duplicateFiles: duplicates)
    }

    private func draftCount(citing itemID: String) throws -> Int {
        Int(try model.database.scalarInt(
            "SELECT COUNT(DISTINCT draft_id) FROM draft_citations WHERE item_id = ?",
            [.text(itemID)]
        ) ?? 0)
    }
}

// MARK: - Sheet

struct MergeDuplicatesSheet: View {
    var existingTitle: String
    var newTitle: String
    var existingID: String?
    var newID: String?
    var model: LibraryModel?
    let onDismiss: () -> Void
    var onMerge: () -> Void
    var onMerged: (MergeSummary) -> Void
    var onKeepBoth: () -> Void

    init(
        existingTitle: String = "",
        newTitle: String = "",
        existingID: String? = nil,
        newID: String? = nil,
        model: LibraryModel? = nil,
        onDismiss: @escaping () -> Void,
        onMerge: @escaping () -> Void = {},
        onMerged: @escaping (MergeSummary) -> Void = { _ in },
        onKeepBoth: @escaping () -> Void = {}
    ) {
        self.existingTitle = existingTitle
        self.newTitle = newTitle
        self.existingID = existingID
        self.newID = newID
        self.model = model
        self.onDismiss = onDismiss
        self.onMerge = onMerge
        self.onMerged = onMerged
        self.onKeepBoth = onKeepBoth
    }

    @State private var preview: MergePreview? = nil
    @State private var fields: [MergeField] = []
    @State private var loadError: String? = nil
    @State private var mergeError: String? = nil

    private var isRealMerge: Bool { model != nil && existingID != nil && newID != nil }

    /// Hand-off mode shows only the two titles, as there is nothing to read the rest from.
    private var shownFields: [MergeField] {
        if isRealMerge { return fields }
        return [MergeField(key: .title, existing: existingTitle, new: newTitle, choice: .existing)]
    }

    private var citedBlock: String? {
        guard let preview, preview.draftsCitingNew > 0 else { return nil }
        return ItemMergeError.citedByDrafts(count: preview.draftsCitingNew, key: preview.new.citationKey).errorDescription
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Merge two copies")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let loadError {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RBColor.error)
                            Text(loadError)
                                .font(RBFont.body())
                                .foregroundStyle(RBColor.primaryText)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.error.opacity(0.1)))
                    } else {
                        Text(introText + " Pick the value to keep for each field. Notes, tags, links and files from both copies are combined.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)

                        if let blocked = citedBlock {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RBColor.warning)
                                Text(blocked)
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.primaryText)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.warning.opacity(0.12)))
                        }

                        table

                        if let combine = combineLine {
                            Text(combine)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        }

                        // Banner
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(RBColor.accent)

                            Text(bannerText)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.accent.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.accent.opacity(0.2), lineWidth: 1))
                    }
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            // Footer
            HStack(spacing: 10) {
                if let mergeError {
                    Label(mergeError, systemImage: "exclamationmark.triangle.fill")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.error)
                        .lineLimit(2)
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button("Keep both") {
                    onKeepBoth()
                    onDismiss()
                }
                .buttonStyle(.bordered)

                Button {
                    performMerge()
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.accent))
                        .opacity(canMerge ? 1 : 0.4)
                }
                .buttonStyle(RBHoverPlainButtonStyle())
                .disabled(!canMerge)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 720, height: 480)
        .background(RBColor.elevated)
        .onAppear { loadPreview() }
    }

    // MARK: Pieces

    private var introText: String {
        if let preview { return MergeLogic.matchedText(preview.matchedBy) }
        return "These look like the same paper."
    }

    private var bannerText: String {
        let key = preview?.existing.citationKey
        let keyPart = key.map { "The citation key “\($0)” is kept" } ?? "The citation key is kept"
        return "\(keyPart), so drafts citing it keep working. The new copy moves to the Trash. You can undo the merge from History."
    }

    private var combineLine: String? {
        guard let preview else { return nil }
        return MergeLogic.combineText(
            tags: preview.tagsToAdd, folders: preview.foldersToAdd,
            links: preview.linksToMove, files: preview.filesToMove
        )
    }

    private var canMerge: Bool {
        if !isRealMerge { return true }
        return preview != nil && citedBlock == nil && loadError == nil
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Field")
                    .frame(width: 90, alignment: .leading)
                Text("In your library")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("New copy")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(RBFont.caption(.semibold))
            .foregroundStyle(RBColor.mutedText)
            .padding(10)
            .background(RBColor.surface)

            Divider().overlay(RBColor.border)

            ForEach(Array(shownFields.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top) {
                    Text(row.key.label)
                        .font(RBFont.caption(.semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 90, alignment: .leading)

                    if row.isSame {
                        Text(row.existing.isEmpty ? "—" : row.existing)
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.secondaryText)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Same in both")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        choiceButton(row: row, index: index, side: .existing, text: row.existing)
                        choiceButton(row: row, index: index, side: .new, text: row.new)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Divider().overlay(RBColor.border.opacity(0.5))
            }

            if let preview {
                HStack(alignment: .top) {
                    Text("Files")
                        .font(RBFont.caption(.semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 90, alignment: .leading)
                    Text(filesText(preview))
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border, lineWidth: 1))
    }

    private func filesText(_ p: MergePreview) -> String {
        var parts: [String] = []
        if p.filesToMove > 0 { parts.append("\(MergeLogic.plural(p.filesToMove, "file", "files")) from the new copy will be added") }
        if p.filesAlreadyThere > 0 { parts.append("\(MergeLogic.plural(p.filesAlreadyThere, "file is", "files are")) identical to ones you already have") }
        return parts.isEmpty ? "No files on the new copy." : parts.joined(separator: "; ") + "."
    }

    private func choiceButton(row: MergeField, index: Int, side: MergeChoice, text: String) -> some View {
        let selected = row.choice == side
        return Button {
            guard isRealMerge, fields.indices.contains(index) else { return }
            fields[index].choice = side
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? RBColor.accent : RBColor.mutedText)
                Text(text.isEmpty ? "—" : text)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
            }
        }
        .buttonStyle(RBHoverPlainButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func loadPreview() {
        guard let model, let existingID, let newID else { return }
        do {
            let loaded = try ItemMerger(model: model).preview(existingID: existingID, newID: newID)
            preview = loaded
            fields = loaded.fields
        } catch {
            loadError = MergeLogic.message(for: error)
        }
    }

    private func performMerge() {
        mergeError = nil
        guard isRealMerge, let model, let existingID, let newID else {
            // Hand-off mode: the caller does the merging.
            onMerge()
            onDismiss()
            return
        }
        var choices: [MergeFieldKey: MergeChoice] = [:]
        for field in fields { choices[field.key] = field.choice }
        do {
            let summary = try ItemMerger(model: model).merge(existingID: existingID, newID: newID, choices: choices)
            onMerged(summary)
            onDismiss()
        } catch {
            mergeError = MergeLogic.message(for: error)
        }
    }
}
