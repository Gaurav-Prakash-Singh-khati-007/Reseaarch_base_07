//
//  TrashView.swift
//  ResearchBase
//
//  Owner: Agent 56 · Features: F-11 (real Trash, restore, undo, delete for good), F-12
//  Source of truth: docs/researchbase.html
//
//  PUBLIC API
//    TrashView(model:)            `TrashView()` still compiles; with no model the Trash is empty
//                                 (no sample data). ContentView (#77) passes the open LibraryModel.
//    TrashItemModel, TrashEntity  the row model (new fields have defaults)
//
//  What it lists: papers (items), notes/ideas (thoughts) and writing projects (drafts) whose
//  `deleted_at` is set. Restore clears `deleted_at` and offers Undo. "Delete for good" asks first,
//  removes the record and everything that hangs off it in one transaction, and sends a PDF to the
//  Mac's Trash only when no other paper uses the same file. Writing projects go through
//  DraftFolderStore.deleteForever. Experiment runs live outside the SQLite library and are not listed.
//  Nothing is removed automatically after 30 days: an expired item shows "Due now" and waits for you.
//
//  Nothing is hard-deleted immediately. Deleted items wait in Trash for 30 days.
//

import SwiftUI

enum TrashEntity: String, Equatable {
    case paper, thought, draft
    
    /// Fixed list: these names are the only table names ever put into SQL here.
    var table: String {
        switch self {
        case .paper: return "items"
        case .thought: return "thoughts"
        case .draft: return "drafts"
        }
    }
    
    var recordType: String {
        switch self {
        case .paper: return "item"
        case .thought: return "thought"
        case .draft: return "draft"
        }
    }
}

struct TrashItemModel: Identifiable, Equatable {
    var kind: String
    var title: String
    var deletedWhen: String
    var daysRemaining: Int
    var entity: TrashEntity = .paper
    var recordID: String = ""
    var deletedAtISO: String = ""
    
    var id: String { "\(entity.rawValue):\(recordID)" }
}

struct TrashView: View {
    let model: LibraryModel?
    
    init(model: LibraryModel? = nil) {
        self.model = model
    }
    
    @State private var items: [TrashItemModel] = []
    @State private var pendingDelete: TrashItemModel?
    @State private var undoAction: (@MainActor () -> Void)?
    @State private var lastSignature = ""
    
    @State private var showingEmptyTrashConfirmation = false
    @State private var toastMessage: String?
    
    var body: some View {
        ZStack {
            RBColor.background
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerView
                    
                    if items.isEmpty {
                        emptyStateView
                    } else {
                        trashTableView
                        
                        Text("Restoring brings back the item with its tags, links and files. PDFs are only removed from disk when no other item uses them.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                            .padding(.top, 4)
                    }
                }
                .rbResponsiveContentPadding()
                .frame(maxWidth: 1250)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if let toast = toastMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text(toast)
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.background)
                        
                        if undoAction != nil {
                            Button("Undo") {
                                undoLast()
                            }
                            .font(RBFont.secondary(.semibold))
                            .foregroundStyle(RBColor.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(RBColor.primaryText)
                    )
                    .shadow(radius: 10)
                    .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
        .task(id: model.map { ObjectIdentifier($0) }) {
            rbA56_reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let model, rbA56_signature(model) != lastSignature {
                    rbA56_reload()
                }
            }
        }
        .confirmationDialog(
            "Delete for good?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete for good", role: .destructive) {
                rbA56_deleteForever(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("“\(item.title)” will be removed for good. This cannot be undone.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $showingEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                rbA56_emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(items.count) \(items.count == 1 ? "item" : "items") will be removed for good, with their tags, links and notes. A PDF is removed only if no other paper uses it. This cannot be undone.")
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trash")
                    .font(RBFont.title(.bold))
                    .foregroundStyle(RBColor.primaryText)
                
                Text("Deleted items stay here for 30 days. Nothing is lost until you empty it.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }
            
            Spacer()
            
            if !items.isEmpty {
                Button(role: .destructive) {
                    showingEmptyTrashConfirmation = true
                } label: {
                    Label("Empty Trash", systemImage: "trash")
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.error)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    // MARK: - Trash Table
    
    private var trashTableView: some View {
        VStack(spacing: 0) {
            // Table Header
            HStack(spacing: 12) {
                Text("Kind")
                    .frame(width: 120, alignment: .leading)
                Text("Item")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Deleted")
                    .frame(width: 120, alignment: .leading)
                Text("Removed for good in")
                    .frame(width: 150, alignment: .leading)
                Text("")
                    .frame(width: 190, alignment: .trailing)
            }
            .font(RBFont.caption(.semibold))
            .foregroundStyle(RBColor.mutedText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RBColor.surface)
            
            Divider()
                .overlay(RBColor.border)
            
            // Table Rows
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Text(item.kind)
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(RBColor.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(RBColor.hover)
                        )
                        .frame(width: 120, alignment: .leading)
                    
                    Text(item.title)
                        .font(RBFont.body(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text(item.deletedWhen)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 120, alignment: .leading)
                    
                    Text(Self.rbA56_remainingText(item.daysRemaining))
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 150, alignment: .leading)
                    
                    HStack(spacing: 8) {
                        Button {
                            rbA56_restore(item)
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                                .font(RBFont.caption(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button(role: .destructive) {
                            pendingDelete = item
                        } label: {
                            Text("Delete for good")
                                .font(RBFont.caption(.medium))
                                .foregroundStyle(RBColor.error)
                        }
                        .buttonStyle(RBHoverPlainButtonStyle())
                    }
                    .frame(width: 190, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                
                Divider()
                    .overlay(RBColor.border.opacity(0.5))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(RBColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(RBColor.border, lineWidth: 1)
        )
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 40))
                .foregroundStyle(RBColor.mutedText)
            
            Text(model == nil ? "No library open" : "Trash is empty")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
            
            Text("Items you delete wait here for 30 days, so you can always get them back.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    @MainActor
    private func showToast(_ msg: String, undo: (@MainActor () -> Void)? = nil) {
        toastMessage = msg
        undoAction = undo
        let seconds: UInt64 = undo == nil ? 4 : 8
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if toastMessage == msg {
                toastMessage = nil
                undoAction = nil
            }
        }
    }
    
    @MainActor
    private func undoLast() {
        let action = undoAction
        toastMessage = nil
        undoAction = nil
        action?()
    }
}

// MARK: - Data: loading, restore, delete for good (Agent 56)

extension TrashView {
    
    private static let rbA56_retentionDays = 30
    
    // MARK: Loading
    
    @MainActor
    private func rbA56_reload() {
        guard let model else {
            items = []
            return
        }
        do {
            var rows: [TrashItemModel] = []
            
            for row in try model.database.rows("SELECT id, title, deleted_at FROM items WHERE deleted_at IS NOT NULL") {
                guard let id = row.text("id"), let deleted = row.text("deleted_at") else { continue }
                rows.append(Self.rbA56_make(.paper, id, "Paper", row.text("title") ?? "Untitled", deleted))
            }
            for row in try model.database.rows("SELECT id, kind, title, deleted_at FROM thoughts WHERE deleted_at IS NOT NULL") {
                guard let id = row.text("id"), let deleted = row.text("deleted_at") else { continue }
                let kind = (row.text("kind") ?? "note").capitalized
                rows.append(Self.rbA56_make(.thought, id, kind, row.text("title") ?? "Untitled", deleted))
            }
            for draft in try DraftFolderStore(model: model).trashed() {
                guard let deleted = draft.deletedAt else { continue }
                rows.append(Self.rbA56_make(.draft, draft.id, "Writing", draft.title, deleted))
            }
            
            rows.sort { $0.deletedAtISO != $1.deletedAtISO ? $0.deletedAtISO > $1.deletedAtISO : $0.id < $1.id }
            items = rows
            lastSignature = rbA56_signature(model)
        } catch {
            showToast("Could not read the Trash: \(error.localizedDescription)")
        }
    }
    
    /// Cheap change check for the 3-second poll.
    @MainActor
    private func rbA56_signature(_ model: LibraryModel) -> String {
        let sql = """
        SELECT
          (SELECT COUNT(*) FROM items WHERE deleted_at IS NOT NULL) AS a,
          (SELECT COUNT(*) FROM thoughts WHERE deleted_at IS NOT NULL) AS b,
          (SELECT COUNT(*) FROM drafts WHERE deleted_at IS NOT NULL) AS c,
          (SELECT MAX(deleted_at) FROM items) AS x,
          (SELECT MAX(deleted_at) FROM thoughts) AS y,
          (SELECT MAX(deleted_at) FROM drafts) AS z
        """
        guard let row = try? model.database.rows(sql).first else { return "" }
        return [row.int("a"), row.int("b"), row.int("c")].map { String($0 ?? 0) }.joined(separator: "|")
            + "|" + [row.text("x"), row.text("y"), row.text("z")].map { $0 ?? "" }.joined(separator: "|")
    }
    
    private static func rbA56_make(
        _ entity: TrashEntity, _ id: String, _ kind: String, _ title: String, _ deletedAt: String
    ) -> TrashItemModel {
        var row = TrashItemModel(
            kind: kind,
            title: title,
            deletedWhen: "",
            daysRemaining: rbA56_retentionDays
        )
        row.entity = entity
        row.recordID = id
        row.deletedAtISO = deletedAt
        if let date = rbA56_date(deletedAt) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            row.deletedWhen = Date().timeIntervalSince(date) < 60
                ? "Just now"
                : formatter.localizedString(for: date, relativeTo: Date())
            let days = Calendar.current.dateComponents(
                [.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: Date())
            ).day ?? 0
            row.daysRemaining = max(0, rbA56_retentionDays - days)
        }
        return row
    }
    
    private static func rbA56_date(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
    
    fileprivate static func rbA56_remainingText(_ days: Int) -> String {
        switch days {
        case 0: return "Due now"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }
    
    // MARK: Restore (F-11)
    
    @MainActor
    private func rbA56_restore(_ item: TrashItemModel) {
        guard let model else { return }
        do {
            try rbA56_setDeleted(item, to: nil, model: model)
            rbA56_reload()
            showToast("Restored “\(item.title)” with its notes, tags and links.", undo: {
                // Undo puts it back in the Trash with its original deleted date, so the 30 days keep counting.
                _ = try? rbA56_setDeleted(item, to: item.deletedAtISO, model: model)
                rbA56_reload()
            })
        } catch {
            showToast("Could not restore: \(error.localizedDescription)")
        }
    }
    
    /// Sets or clears `deleted_at`. The table name comes from a fixed list, never from user text.
    @MainActor
    private func rbA56_setDeleted(_ item: TrashItemModel, to value: String?, model: LibraryModel) throws {
        try model.atomically {
            let now = model.now()
            try model.database.run(
                "UPDATE \(item.entity.table) SET deleted_at = ?, updated_at = ? WHERE id = ?",
                [LibraryModel.text(value), .text(now), .text(item.recordID)]
            )
            try model.record(
                item.entity.recordType, item.recordID,
                value == nil ? .restore : .delete,
                field: "deleted_at",
                old: value == nil ? item.deletedAtISO : nil,
                new: value
            )
        }
    }
    
    // MARK: Delete for good
    
    @MainActor
    private func rbA56_deleteForever(_ item: TrashItemModel) {
        guard let model else { return }
        do {
            let files = try rbA56_purge(item, model: model)
            rbA56_removeFiles(files, model: model)
            rbA56_reload()
            showToast("Deleted for good.")
        } catch {
            rbA56_reload()
            showToast("“\(item.title)” was kept in the Trash: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func rbA56_emptyTrash() {
        guard let model else { return }
        var removed = 0
        var kept: [String] = []
        var files: [PurgedFile] = []
        for item in items {
            do {
                files += try rbA56_purge(item, model: model)
                removed += 1
            } catch {
                kept.append(item.title)
            }
        }
        rbA56_removeFiles(files, model: model)
        rbA56_reload()
        if kept.isEmpty {
            showToast("Trash emptied.")
        } else {
            showToast("Removed \(removed). \(kept.count) could not be removed and stay in the Trash.")
        }
    }
    
    struct PurgedFile {
        var sha256: String
        var relativePath: String
    }
    
    /// Removes one Trash record for good, in ONE transaction. If anything still points at it the
    /// database refuses, the whole change is undone and the record stays in the Trash.
    /// Returns the files that belonged to a paper; the caller removes them once nothing else uses them.
    @MainActor
    private func rbA56_purge(_ item: TrashItemModel, model: LibraryModel) throws -> [PurgedFile] {
        switch item.entity {
        case .draft:
            try DraftFolderStore(model: model).deleteForever(id: item.recordID)
            return []
            
        case .thought:
            try model.atomically {
                try Self.rbA56_requireInTrash("thoughts", item.recordID, model: model)
                try model.database.run(
                    "DELETE FROM links WHERE (from_type = 'thought' AND from_id = ?) OR (to_type = 'thought' AND to_id = ?)",
                    [.text(item.recordID), .text(item.recordID)]
                )
                try model.database.run("DELETE FROM thoughts WHERE id = ? AND deleted_at IS NOT NULL", [.text(item.recordID)])
                try model.record("thought", item.recordID, .delete, field: "thought",
                                 old: LibraryModel.json(["title": item.title, "kind": item.kind]), new: nil)
            }
            return []
            
        case .paper:
            return try model.atomically {
                let id = item.recordID
                try Self.rbA56_requireInTrash("items", id, model: model)
                
                let files = try model.database.rows(
                    "SELECT sha256, rel_path FROM attachments WHERE item_id = ?", [.text(id)]
                ).compactMap { row -> PurgedFile? in
                    guard let sha = row.text("sha256"), let path = row.text("rel_path") else { return nil }
                    return PurgedFile(sha256: sha, relativePath: path)
                }
                
                let db = model.database
                try db.run("DELETE FROM annotations WHERE attachment_id IN (SELECT id FROM attachments WHERE item_id = ?)", [.text(id)])
                try db.run("DELETE FROM attachments WHERE item_id = ?", [.text(id)])
                try db.run("DELETE FROM item_creators WHERE item_id = ?", [.text(id)])
                try db.run("DELETE FROM item_tags WHERE item_id = ?", [.text(id)])
                try db.run("DELETE FROM collection_items WHERE item_id = ?", [.text(id)])
                try db.run("UPDATE draft_citations SET item_id = NULL WHERE item_id = ?", [.text(id)])
                try db.run(
                    "DELETE FROM links WHERE (from_type = 'item' AND from_id = ?) OR (to_type = 'item' AND to_id = ?)",
                    [.text(id), .text(id)]
                )
                try db.run("DELETE FROM items WHERE id = ? AND deleted_at IS NOT NULL", [.text(id)])
                try model.record("item", id, .delete, field: "item",
                                 old: LibraryModel.json(["title": item.title]), new: nil)
                return files
            }
        }
    }
    
    @MainActor
    private static func rbA56_requireInTrash(_ table: String, _ id: String, model: LibraryModel) throws {
        let count = try model.database.scalarInt(
            "SELECT COUNT(*) FROM \(table) WHERE id = ? AND deleted_at IS NOT NULL", [.text(id)]
        ) ?? 0
        guard count > 0 else { throw ModelError.notFound(kind: "Trash record", id: id) }
    }
    
    /// A PDF leaves the disk only when no remaining attachment uses the same file. It goes to the
    /// Mac's Trash, not straight to oblivion.
    @MainActor
    private func rbA56_removeFiles(_ files: [PurgedFile], model: LibraryModel) {
        for file in files {
            guard (try? model.attachments.rowCount(sha256: file.sha256)) == 0,
                  let url = try? model.library.url(forRelativePath: file.relativePath),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
