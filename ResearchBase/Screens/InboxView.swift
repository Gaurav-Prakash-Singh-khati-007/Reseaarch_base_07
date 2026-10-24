//
//  InboxView.swift
//  ResearchBase
//
//  Owner: Agent 55 · Features: F-20, F-17 (drop / Open with), F-18 (display), F-14, F-23, X-01 (status)
//  Source of truth: docs/researchbase.html
//
//  PUBLIC API
//    InboxView(model:captureState:watchedFolderPath:onOpenSettings:)
//        every argument is optional, so `InboxView()` still compiles. With no `model`
//        the Inbox is empty (no sample data). ContentView (#77) passes the open
//        LibraryModel, the CaptureServer state and the inbox folder path.
//    InboxIntake (main actor)            what a drop / "Open with" handler can call
//        addPDF(at:model:)               -> .added(itemID:) / .duplicate(existingTitle:)
//        addText(_:model:)               DOI, arXiv ID, link or plain title -> new Inbox item
//        addBibTeX(at:model:) / addRIS(at:model:)   -> (added, skipped)
//    InboxItemModel, InboxVia, InboxMetaStatus   unchanged names; new fields have defaults
//
//  Uses: ItemStore, CreatorStore, AttachmentStore (finished), MetadataResolver (#5),
//  PDFMetadataReader (#6), DuplicateDetector (#8), OCRService (#13), CaptureServerState (#30),
//  InboxFolderWatcher.title(fromFileName:) (#31), BibTeXImporter / RISImporter (#9, #10).
//  Moving an item to the Trash is a soft delete (items.deleted_at) written here; no other
//  file is touched and no schema is changed.
//  New papers wait here until the researcher reviews and accepts them.
//

import SwiftUI
import UniformTypeIdentifiers

enum InboxVia: String, CaseIterable {
    case browser
    case inboxFolder = "inbox_folder"
    case quickAdd = "quick_add"
    case drop
    
    var label: String {
        switch self {
        case .browser: return "Browser"
        case .inboxFolder: return "Inbox folder"
        case .quickAdd: return "Quick add"
        case .drop: return "Dropped"
        }
    }
    
    var iconName: String {
        switch self {
        case .browser: return "globe"
        case .inboxFolder: return "folder"
        case .quickAdd: return "sparkles"
        case .drop: return "arrow.up.doc"
        }
    }
}

enum InboxMetaStatus {
    case ok
    case ocr
    case lookup
    case failed
    
    var label: String {
        switch self {
        case .ok: return "Details found"
        case .ocr: return "Scanned · OCR queued"
        case .lookup: return "Looking up…"
        case .failed: return "No details found · edit by hand"
        }
    }
}

struct InboxItemModel: Identifiable, Equatable {
    let id: String
    var via: InboxVia
    var title: String
    var source: String
    var when: String
    var isDuplicate: Bool
    var metaStatus: InboxMetaStatus
    var authors: String
    var year: Int?
    var hasPDF: Bool
    var duplicateMatchTitle: String?
    var duplicateMatchID: String? = nil
    var duplicateLead: String = "Already in your library as"
    var duplicateReason: String? = nil
}

struct InboxView: View {
    let model: LibraryModel?
    var captureState: CaptureServerState
    var watchedFolderPath: String?
    var onOpenSettings: () -> Void

    init(
        model: LibraryModel? = nil,
        captureState: CaptureServerState = .stopped,
        watchedFolderPath: String? = nil,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.model = model
        self.captureState = captureState
        self.watchedFolderPath = watchedFolderPath
        self.onOpenSettings = onOpenSettings
    }

    @State private var items: [InboxItemModel] = []
    
    @State private var showingAddPaperSheet = false
    @State private var showingQuickAddSheet = false
    @State private var showingMergeSheet = false
    @State private var mergeTargetItem: InboxItemModel?
    @State private var toastMessage: String?
    @State private var isDropTargeted = false
    @State private var editTarget: InboxItemModel?
    @State private var undoAction: (@MainActor () -> Void)?
    @State private var busy: [String: InboxMetaStatus] = [:]
    @State private var keepBoth: Set<String> = []
    @State private var inspected: Set<String> = []
    @State private var lastSignature = ""
    
    var body: some View {
        ZStack {
            RBColor.background
                .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerView
                    captureStatusCard
                    dropZoneView
                    
                    if !items.isEmpty {
                        sortingHeader
                        itemsListView
                    } else {
                        emptyStateView
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
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(RBColor.primaryText)
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 15, x: 0, y: 8)
                    .padding(.bottom, 24)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: toastMessage)
            }
        }
        .sheet(isPresented: $showingAddPaperSheet) {
            AddPaperSheet(
                onDismiss: { showingAddPaperSheet = false },
                onAdd: { title in acceptPaper(title: title) },
                model: model,
                onAdded: { item in
                    rbA55_reload()
                    if item.reviewState == .inbox {
                        showToast("Added “\(item.title)” to the Inbox.")
                    } else {
                        showToast("Added “\(item.title)” to your Library. It is not in the Inbox because it is already accepted.")
                    }
                }
            )
        }
        .sheet(isPresented: $showingQuickAddSheet) {
            QuickAddSheet(onDismiss: { showingQuickAddSheet = false }) { input in
                addItemFromInput(input)
            }
        }
        .sheet(item: $editTarget) { target in
            RBA55EditSheet(
                draft: rbA55_draft(for: target.id),
                onSave: { draft in
                    editTarget = nil
                    rbA55_saveEdit(draft)
                },
                onCancel: { editTarget = nil }
            )
        }
        .task(id: model.map { ObjectIdentifier($0) }) {
            rbA55_reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let model, rbA55_signature(model) != lastSignature {
                    rbA55_reload()
                }
            }
        }
        .sheet(isPresented: $showingMergeSheet) {
            MergeDuplicatesSheet(
                existingTitle: mergeTargetItem?.duplicateMatchTitle ?? "Existing Paper",
                newTitle: mergeTargetItem?.title ?? "New Copy",
                onDismiss: { showingMergeSheet = false },
                onMerge: {
                    if let item = mergeTargetItem {
                        rbA55_merge(item)
                    }
                }
            )
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inbox")
                    .font(RBFont.title(.bold))
                    .foregroundStyle(RBColor.primaryText)
                
                Text("New papers wait here until you accept them.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Button {
                    showingAddPaperSheet = true
                } label: {
                    Label("Add paper", systemImage: "plus")
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(RBColor.accent)
                        )
                }
                .buttonStyle(RBHoverPlainButtonStyle())
                
                Button {
                    showingQuickAddSheet = true
                } label: {
                    Label("Quick add", systemImage: "sparkles")
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(RBColor.elevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(RBColor.border, lineWidth: 1)
                        )
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
        }
    }
    
    // MARK: - Capture Status Card (X-01)
    
    private var rbA55_captureChip: (text: String, icon: String, color: Color, detail: String, address: String?) {
        switch captureState {
        case .listening(let port):
            return ("Capture on", "checkmark.circle.fill", RBColor.success,
                    "Listening for the browser extension", "127.0.0.1:\(port)")
        case .stopped:
            return ("Capture off", "pause.circle.fill", RBColor.mutedText,
                    "The browser extension cannot send papers right now", nil)
        case .failed(let reason):
            return ("Capture problem", "exclamationmark.triangle.fill", RBColor.warning, reason, nil)
        }
    }
    
    private var captureStatusCard: some View {
        let chip = rbA55_captureChip
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: chip.icon)
                    .font(.system(size: 11))
                Text(chip.text)
                    .font(RBFont.caption(.medium))
            }
            .foregroundStyle(chip.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(chip.color.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(chip.color.opacity(0.3), lineWidth: 1)
            )
            
            if let address = chip.address {
                Text(address)
                    .font(RBFont.secondary().monospaced())
                    .foregroundStyle(RBColor.primaryText)
            }
            
            Text(chip.detail)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
            
            Spacer()
            
            if let folder = watchedFolderPath {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Watching \(folder)")
                        .font(RBFont.caption())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(RBColor.mutedText)
            }
            
            Button("Settings") {
                onOpenSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(RBColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(RBColor.border, lineWidth: 1)
        )
    }
    
    // MARK: - Dropzone (F-17)
    
    private var dropZoneView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: 26))
                .foregroundStyle(RBColor.accent)
            
            HStack(spacing: 4) {
                Text("Drop PDFs, .bib, .ris or links here")
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
            }
            
            Text("They are added to the inbox, checked for duplicates and filled in automatically.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? RBColor.accent.opacity(0.08) : RBColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundStyle(isDropTargeted ? RBColor.accent : RBColor.border)
        )
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTargeted) { providers in
            rbA55_handleDrop(providers)
        }
    }
    
    // MARK: - Sorting Header
    
    private var sortingHeader: some View {
        HStack {
            Text("\(items.count) to sort")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
            
            Spacer()
            
            Button {
                rbA55_acceptAll()
            } label: {
                Label("Accept all without problems", systemImage: "checkmark")
                    .font(RBFont.secondary(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    // MARK: - Items List
    
    private var itemsListView: some View {
        VStack(spacing: 12) {
            ForEach(items) { item in
                inboxItemCard(item)
            }
        }
    }
    
    private func inboxItemCard(_ item: InboxItemModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: item.via.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(RBColor.accent)
                    .frame(width: 24, height: 24)
                    .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                    
                    Text("\(item.authors)\(item.year != nil ? " · \(item.year!)" : "")")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                    
                    // Chips Row
                    HStack(spacing: 8) {
                        Text(item.via.label)
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(RBColor.elevated)
                            )
                            .overlay(
                                Capsule().stroke(RBColor.border, lineWidth: 1)
                            )
                        
                        Text("\(item.source) · \(item.when)")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                        
                        // Metadata status chip
                        metadataStatusChip(item.metaStatus)
                        
                        // PDF chip
                        Text(item.hasPDF ? "PDF attached" : "No PDF")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(RBColor.hover)
                            )
                    }
                    .padding(.top, 4)
                    
                    // Duplicate Warning Banner (F-18)
                    if item.isDuplicate, let dupTitle = item.duplicateMatchTitle {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(RBColor.warning)
                            
                            rbJoinedText(
                                Text(item.duplicateLead + " ")
                                    .font(RBFont.secondary())
                                    .foregroundStyle(RBColor.primaryText),
                                Text(dupTitle)
                                    .font(RBFont.secondary(.semibold))
                                    .foregroundStyle(RBColor.primaryText),
                                Text(" (matched by \(item.duplicateReason ?? "title")).")
                                    .font(RBFont.secondary())
                                    .foregroundStyle(RBColor.primaryText)
                            )
                            
                            Spacer()
                            
                            Button("Compare and merge") {
                                mergeTargetItem = item
                                showingMergeSheet = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button("Keep both") {
                                rbA55_keepBoth(item)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(RBColor.warning.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(RBColor.warning.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.top, 6)
                    }
                }
                
                Spacer()
                
                // Action Buttons
                VStack(spacing: 6) {
                    Button {
                        rbA55_accept(item)
                    } label: {
                        Text("Accept")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(Color.white)
                            .frame(width: 64)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(RBColor.accent)
                            )
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                    
                    Button {
                        editTarget = item
                    } label: {
                        Text("Edit")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.primaryText)
                            .frame(width: 64)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(RBColor.elevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(RBColor.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                    
                    Button {
                        rbA55_discard(item)
                    } label: {
                        Text("Discard")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.error)
                            .frame(width: 64)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(RBColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(RBColor.border, lineWidth: 1)
            )
        }
    }
    
    @ViewBuilder
    private func metadataStatusChip(_ status: InboxMetaStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .ok:
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text(status.label)
            case .ocr:
                Image(systemName: "eye")
                    .font(.system(size: 9))
                Text(status.label)
            case .lookup:
                ProgressView()
                    .controlSize(.mini)
                Text(status.label)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 9))
                Text(status.label)
            }
        }
        .font(RBFont.caption())
        .foregroundStyle(Self.rbA55_statusColor(status))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Self.rbA55_statusColor(status).opacity(0.12))
        )
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(RBColor.mutedText)
            
            Text(model == nil ? "No library open" : "Inbox is empty")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
            
            Text("Papers you capture from the browser, drop here or add by link wait here until you accept them.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            
            Button {
                showingAddPaperSheet = true
            } label: {
                Label("Add paper", systemImage: "plus")
                    .font(RBFont.body(.medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(RBColor.accent)
                    )
            }
            .buttonStyle(RBHoverPlainButtonStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    @MainActor
    private func acceptPaper(title: String) {
        // "Add paper" sheet: a paper typed in by hand goes straight into the library.
        guard let model else { showToast("Open a library first."); return }
        do {
            var new = NewItem(title: title)
            new.sourceKind = .manual
            new.reviewState = .accepted
            _ = try model.items.create(new)
            showToast("Accepted “\(title)” into your library.")
        } catch {
            showToast("Could not add the paper: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func addItemFromInput(_ input: String) {
        // Quick add (F-17): DOI, arXiv ID, link or a plain title.
        guard let model else { showToast("Open a library first."); return }
        do {
            let (item, identifier) = try InboxIntake.addText(input, model: model)
            guard let identifier else {
                rbA55_reload()
                showToast("Added to Inbox.")
                return
            }
            busy[item.id] = .lookup
            inspected.insert(item.id)
            rbA55_reload()
            showToast("Added to Inbox. Looking up the details…")
            Task { await rbA55_resolve(identifier, itemID: item.id) }
        } catch {
            showToast("Could not add that: \(error.localizedDescription)")
        }
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

// MARK: - Data: loading, enrichment, actions (Agent 55)

extension InboxView {
    
    // MARK: Loading
    
    @MainActor
    private func rbA55_reload() {
        guard let model else {
            items = []
            return
        }
        do {
            let detector = DuplicateDetector(model: model)
            let index = try detector.buildIndex(includeTrashed: false)
            let inbox = try model.items.list(reviewState: .inbox, limit: 500)
            items = inbox.map { rbA55_row($0, model: model, detector: detector, index: index) }
            lastSignature = rbA55_signature(model)
            rbA55_startEnrichment(for: inbox, model: model)
        } catch {
            showToast("Could not read the Inbox: \(error.localizedDescription)")
        }
    }
    
    /// Cheap change check, so the 3-second poll does not rebuild the duplicate index every time.
    @MainActor
    private func rbA55_signature(_ model: LibraryModel) -> String {
        let sql = "SELECT COUNT(*) AS c, MAX(updated_at) AS u FROM items WHERE review_state = 'inbox' AND deleted_at IS NULL"
        guard let row = try? model.database.rows(sql).first else { return "" }
        return "\(row.int("c") ?? 0)|\(row.text("u") ?? "")"
    }
    
    @MainActor
    private func rbA55_row(
        _ item: ModelItem,
        model: LibraryModel,
        detector: DuplicateDetector,
        index: DuplicateIndex
    ) -> InboxItemModel {
        
        let creators = (try? model.creators.creators(of: item.id)) ?? []
        let files = (try? model.attachments.attachments(of: item.id)) ?? []
        let pdf = files.first(where: { $0.kind == .pdf })
        let status = busy[item.id] ?? .ok
        
        let authorRoles = creators.filter { $0.role == .author }
        let named = (authorRoles.isEmpty ? creators : authorRoles).map { $0.creator.family }
        var authors: String
        if status == .lookup {
            authors = "Looking up…"
        } else if named.isEmpty {
            authors = "(not found yet)"
        } else {
            authors = named.prefix(6).joined(separator: ", ") + (named.count > 6 ? " et al." : "")
        }
        
        var source = item.sourceURL
        if source.isEmpty, let pdf {
            source = item.sourceKind == .inboxFolder ? "inbox/\(pdf.originalName)" : pdf.originalName
        }
        if source.isEmpty { source = "Added by hand" }
        
        var row = InboxItemModel(
            id: item.id,
            via: Self.rbA55_via(item.sourceKind),
            title: item.title,
            source: source,
            when: Self.rbA55_when(item.capturedAt ?? item.addedAt),
            isDuplicate: false,
            metaStatus: status,
            authors: authors,
            year: item.year,
            hasPDF: pdf != nil,
            duplicateMatchTitle: nil
        )
        
        if !keepBoth.contains(item.id),
           let probe = try? detector.probe(forItem: item.id),
           let hit = detector.matches(for: probe, in: index, limit: 3).first(where: { $0.itemID != item.id }) {
            row.isDuplicate = true
            row.duplicateMatchTitle = hit.title
            row.duplicateMatchID = hit.itemID
            row.duplicateReason = hit.matchedByText
            switch hit.confidence {
            case .certain, .likely:
                row.duplicateLead = hit.isInInbox ? "Also waiting in your Inbox as" : "Already in your library as"
            case .possible:
                row.duplicateLead = "Possibly the same as"
            }
        }
        return row
    }
    
    private static func rbA55_via(_ kind: SourceKind) -> InboxVia {
        switch kind {
        case .browser: return .browser
        case .inboxFolder: return .inboxFolder
        case .pdfDrop, .import: return .drop
        case .manual, .doi, .arxiv, .url: return .quickAdd
        }
    }
    
    private static func rbA55_when(_ iso: String) -> String {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return "" }
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private static func rbA55_statusColor(_ status: InboxMetaStatus) -> Color {
        switch status {
        case .ok: return RBColor.success
        case .ocr, .failed: return RBColor.warning
        case .lookup: return RBColor.accent
        }
    }
    
    // MARK: Enrichment: PDF reading, OCR (F-23), lookup (F-15 / F-16)
    
    @MainActor
    private func rbA55_setStatus(_ id: String, _ status: InboxMetaStatus?) {
        busy[id] = status
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].metaStatus = status ?? .ok
            if status == .lookup { items[i].authors = "Looking up…" }
        }
    }
    
    /// Looks at every Inbox paper that has a PDF but no authors yet. Each paper is inspected once per session.
    @MainActor
    private func rbA55_startEnrichment(for inbox: [ModelItem], model: LibraryModel) {
        for item in inbox where !inspected.contains(item.id) {
            inspected.insert(item.id)
            let hasAuthors = !((try? model.creators.creators(of: item.id))?.isEmpty ?? true)
            guard !hasAuthors,
                  let pdf = (try? model.attachments.attachments(of: item.id))?.first(where: { $0.kind == .pdf }),
                  let url = try? model.attachments.fileURL(for: pdf) else { continue }
            let id = item.id
            let fileTitle = InboxFolderWatcher.title(fromFileName: pdf.originalName)
            Task { await rbA55_enrich(itemID: id, pdfURL: url, fileTitle: fileTitle) }
        }
    }
    
    @MainActor
    private func rbA55_enrich(itemID: String, pdfURL: URL, fileTitle: String) async {
        guard let model else { return }
        
        // 1. What the PDF says about itself (never throws, no network).
        let meta = await Task.detached(priority: .utility) { PDFMetadataReader.read(url: pdfURL) }.value
        var doi = meta.doi
        var arxiv = meta.arxivID
        var ocrFoundNothing = false
        
        // 2. A scan has no text: read page one with OCR and look for an identifier there.
        if meta.needsOCR {
            rbA55_setStatus(itemID, .ocr)
            if let result = try? await OCRService().readPages(pdfAt: pdfURL, pages: [1]) {
                let text = result.fullText
                doi = doi ?? PDFMetadataReader.extractDOI(from: text)
                arxiv = arxiv ?? PDFMetadataReader.extractArXivID(from: text)
                ocrFoundNothing = (doi == nil && arxiv == nil)
            } else {
                // OCR could not run: leave it marked as scanned, the person can still edit by hand.
                return
            }
        }
        
        // 3. Ask the internet (or the cache) for the full record.
        let identifier: MetadataIdentifier? = doi.map { .doi($0) } ?? arxiv.map { .arxiv($0) }
        if let identifier {
            rbA55_setStatus(itemID, .lookup)
            do {
                let resolved = try await MetadataResolver(library: model.library).resolve(identifier)
                try rbA55_apply(resolved, to: itemID)
                rbA55_setStatus(itemID, nil)
            } catch {
                rbA55_applyHints(meta, doi: doi, arxiv: arxiv, itemID: itemID, fileTitle: fileTitle)
                rbA55_setStatus(itemID, .failed)
            }
        } else if meta.title != nil || !meta.authors.isEmpty {
            rbA55_applyHints(meta, doi: nil, arxiv: nil, itemID: itemID, fileTitle: fileTitle)
            rbA55_setStatus(itemID, nil)
        } else {
            rbA55_setStatus(itemID, ocrFoundNothing || meta.problem != nil ? .failed : nil)
        }
        rbA55_reload()
    }
    
    @MainActor
    private func rbA55_resolve(_ identifier: MetadataIdentifier, itemID: String) async {
        guard let model else { return }
        do {
            let resolved = try await MetadataResolver(library: model.library).resolve(identifier)
            try rbA55_apply(resolved, to: itemID)
            rbA55_setStatus(itemID, nil)
        } catch {
            rbA55_setStatus(itemID, .failed)
            showToast((error as? LocalizedError)?.errorDescription ?? "Could not look that up. Fill the details in by hand.")
        }
        rbA55_reload()
    }
    
    /// Writes a lookup result onto the paper. Empty answers never overwrite what is already there.
    @MainActor
    private func rbA55_apply(_ r: ResolvedMetadata, to id: String) throws {
        guard let model else { return }
        try model.atomically {
            try model.items.update(id: id) { m in
                m.type = r.type
                if !r.title.isEmpty { m.title = r.title }
                if let year = r.year { m.year = year }
                if !r.venue.isEmpty { m.venue = r.venue }
                if !r.abstract.isEmpty { m.abstract = r.abstract }
                if !r.volume.isEmpty { m.volume = r.volume }
                if !r.issue.isEmpty { m.issue = r.issue }
                if !r.pages.isEmpty { m.pages = r.pages }
                if !r.publisher.isEmpty { m.publisher = r.publisher }
                if let doi = r.doi { m.doi = doi }
                if let arxiv = r.arxivID { m.arxivID = arxiv }
                if !r.url.isEmpty { m.url = r.url }
                if !r.language.isEmpty { m.language = r.language }
            }
            if !r.creators.isEmpty {
                try model.creators.setCreators(itemID: id, r.creators)
            }
        }
    }
    
    /// PDF hints are only a guess, so they are used only while the paper still carries its file-name title.
    @MainActor
    private func rbA55_applyHints(_ meta: PDFMetadata, doi: String?, arxiv: String?, itemID: String, fileTitle: String) {
        guard let model, let current = try? model.items.fetch(id: itemID), current.title == fileTitle else { return }
        do {
            try model.atomically {
                try model.items.update(id: itemID) { m in
                    if let title = meta.title, !title.isEmpty { m.title = title }
                    if let year = meta.year { m.year = year }
                    if m.doi == nil { m.doi = doi }
                    if m.arxivID == nil { m.arxivID = arxiv }
                }
                let people = meta.authors.map { Self.rbA55_creator(fromName: $0) }
                if !people.isEmpty { try model.creators.setCreators(itemID: itemID, people) }
            }
        } catch {
            // A hint that cannot be saved is simply dropped; the paper stays as it was.
        }
    }
    
    // MARK: Names
    
    private static func rbA55_creator(fromName raw: String) -> CreatorInput {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = name.firstIndex(of: ",") {
            let family = name[..<comma].trimmingCharacters(in: .whitespaces)
            let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return CreatorInput(family: family, given: given)
        }
        let words = name.split(separator: " ").map(String.init)
        guard words.count > 1, let last = words.last else { return CreatorInput(family: name) }
        return CreatorInput(family: last, given: words.dropLast().joined(separator: " "))
    }
    
    private static func rbA55_parseAuthors(_ text: String) -> [CreatorInput] {
        text.replacingOccurrences(of: "\n", with: ";")
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { rbA55_creator(fromName: $0) }
    }
    
    // MARK: Drop and Open with (F-17)
    
    @MainActor
    private func rbA55_handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in rbA55_handleDropped(urls: [url]) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                accepted = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in addItemFromInput(text) }
                }
            }
        }
        return accepted
    }
    
    @MainActor
    private func rbA55_handleDropped(urls: [URL]) {
        guard let model else { showToast("Open a library first."); return }
        var added = 0
        var duplicates: [String] = []
        var skipped = 0
        var unsupported = 0
        var problem: String?
        
        for url in urls {
            if !url.isFileURL {
                addItemFromInput(url.absoluteString)
                continue
            }
            do {
                switch url.pathExtension.lowercased() {
                case "pdf":
                    switch try InboxIntake.addPDF(at: url, model: model) {
                    case .added: added += 1
                    case .duplicate(let title): duplicates.append(title)
                    }
                case "bib":
                    let result = try InboxIntake.addBibTeX(at: url, model: model)
                    added += result.added
                    skipped += result.skipped
                case "ris":
                    let result = try InboxIntake.addRIS(at: url, model: model)
                    added += result.added
                    skipped += result.skipped
                default:
                    unsupported += 1
                }
            } catch {
                problem = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        
        rbA55_reload()
        if let problem {
            showToast("Could not add \(problem)")
        } else if let first = duplicates.first, added == 0 {
            showToast("Already in your library as “\(first)”. Not added again.")
        } else if added > 0 {
            var message = "Added \(added) to Inbox."
            if !duplicates.isEmpty { message += " \(duplicates.count) already in your library." }
            if skipped > 0 { message += " \(skipped) could not be read." }
            showToast(message)
        } else if unsupported > 0 {
            showToast("Only PDFs, .bib and .ris files can be dropped here.")
        }
    }
    
    // MARK: Accept, discard, merge (F-18)
    
    @MainActor
    private func rbA55_accept(_ item: InboxItemModel) {
        guard let model else { return }
        do {
            try model.items.update(id: item.id) { $0.reviewState = .accepted }
            rbA55_reload()
            showToast("Accepted into your library.", undo: {
                _ = try? model.items.update(id: item.id) { $0.reviewState = .inbox }
                rbA55_reload()
            })
        } catch {
            showToast("Could not accept: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func rbA55_acceptAll() {
        guard let model else { return }
        let ids = items.filter { !$0.isDuplicate && $0.metaStatus == .ok }.map(\.id)
        guard !ids.isEmpty else {
            showToast("Nothing to accept without problems.")
            return
        }
        do {
            try model.atomically {
                for id in ids { try model.items.update(id: id) { $0.reviewState = .accepted } }
            }
            rbA55_reload()
            showToast("Accepted \(ids.count) papers without problems.", undo: {
                _ = try? model.atomically {
                    for id in ids { try model.items.update(id: id) { $0.reviewState = .inbox } }
                }
                rbA55_reload()
            })
        } catch {
            showToast("Could not accept: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func rbA55_discard(_ item: InboxItemModel) {
        guard let model else { return }
        do {
            try rbA55_trash(item.id, model: model)
            rbA55_reload()
            showToast("Moved to Trash.", undo: {
                _ = try? rbA55_untrash(item.id, model: model)
                rbA55_reload()
            })
        } catch {
            showToast("Could not move to Trash: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func rbA55_keepBoth(_ item: InboxItemModel) {
        keepBoth.insert(item.id)
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].isDuplicate = false
        }
        showToast("Kept both copies.")
    }
    
    /// Merge = the existing paper gets this copy's files, then this copy goes to the Trash (undoable).
    @MainActor
    private func rbA55_merge(_ item: InboxItemModel) {
        guard let model, let existingID = item.duplicateMatchID else {
            showToast("The matching paper could not be found.")
            return
        }
        do {
            try model.atomically {
                for file in try model.attachments.attachments(of: item.id) {
                    let url = try model.attachments.fileURL(for: file)
                    try model.attachments.add(fileAt: url, to: existingID, kind: file.kind, label: file.label)
                }
                try rbA55_trash(item.id, model: model)
                try model.record("item", item.id, .merge, field: "merged_into", new: existingID)
            }
            rbA55_reload()
            showToast("Merged with existing paper.", undo: {
                _ = try? rbA55_untrash(item.id, model: model)
                rbA55_reload()
            })
        } catch {
            showToast("Could not merge: \(error.localizedDescription)")
        }
    }
    
    // Soft delete: the paper stays in the database with a deleted date (the Trash screen lists these).
    @MainActor
    private func rbA55_trash(_ id: String, model: LibraryModel) throws {
        try model.atomically {
            let now = model.now()
            try model.database.run(
                "UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                [.text(now), .text(now), .text(id)]
            )
            try model.record("item", id, .delete, field: "deleted_at", old: nil, new: now)
        }
    }
    
    @MainActor
    private func rbA55_untrash(_ id: String, model: LibraryModel) throws {
        try model.atomically {
            try model.database.run(
                "UPDATE items SET deleted_at = NULL, updated_at = ? WHERE id = ?",
                [.text(model.now()), .text(id)]
            )
            try model.record("item", id, .restore, field: "deleted_at", old: nil, new: nil)
        }
    }
    
    // MARK: Edit (fix details by hand)
    
    @MainActor
    private func rbA55_draft(for id: String) -> RBA55EditDraft {
        var draft = RBA55EditDraft(id: id)
        guard let model, let item = try? model.items.fetch(id: id) else { return draft }
        draft.title = item.title
        draft.year = item.year.map(String.init) ?? ""
        draft.venue = item.venue
        draft.doi = item.doi ?? ""
        let people = (try? model.creators.creators(of: id)) ?? []
        draft.authors = people.map { $0.creator.displayName }.joined(separator: "; ")
        return draft
    }
    
    @MainActor
    private func rbA55_saveEdit(_ draft: RBA55EditDraft) {
        guard let model else { return }
        let yearText = draft.year.trimmingCharacters(in: .whitespaces)
        let year = Int(yearText)
        guard yearText.isEmpty || year != nil else {
            showToast("The year must be a number.")
            return
        }
        do {
            try model.atomically {
                try model.items.update(id: draft.id) { m in
                    m.title = draft.title
                    m.year = year
                    m.venue = draft.venue.trimmingCharacters(in: .whitespacesAndNewlines)
                    let doi = draft.doi.trimmingCharacters(in: .whitespacesAndNewlines)
                    m.doi = doi.isEmpty ? nil : doi
                }
                try model.creators.setCreators(itemID: draft.id, Self.rbA55_parseAuthors(draft.authors))
            }
            busy[draft.id] = nil
            rbA55_reload()
            showToast("Saved.")
        } catch {
            showToast("Could not save: \(error.localizedDescription)")
        }
    }
}

// MARK: - Edit sheet (private to this file)

struct RBA55EditDraft: Identifiable, Equatable {
    var id: String
    var title = ""
    var authors = ""
    var year = ""
    var venue = ""
    var doi = ""
}

private struct RBA55EditSheet: View {
    @State var draft: RBA55EditDraft
    let onSave: (RBA55EditDraft) -> Void
    let onCancel: () -> Void
    
    init(draft: RBA55EditDraft, onSave: @escaping (RBA55EditDraft) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }
    
    private var canSave: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit details")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
            
            TextField("Title", text: $draft.title)
            TextField("Authors (Family, Given; Family, Given)", text: $draft.authors)
            HStack {
                TextField("Year", text: $draft.year)
                    .frame(width: 90)
                TextField("Venue", text: $draft.venue)
            }
            TextField("DOI", text: $draft.doi)
            
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 4)
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 480)
        .background(RBColor.background)
    }
}

// MARK: - Intake (used by the drop zone and by an app-level "Open with" handler)

enum InboxIntakeOutcome: Equatable {
    case added(itemID: String)
    case duplicate(existingTitle: String)
}

@MainActor
enum InboxIntake {
    
    /// A PDF becomes an Inbox paper with the file attached, in one transaction.
    /// A file that is already in the library (same SHA-256) is reported, never added twice.
    static func addPDF(at url: URL, model: LibraryModel) throws -> InboxIntakeOutcome {
        let sha = try AttachmentStore.sha256Hex(of: url)
        let detector = DuplicateDetector(model: model)
        let probe = DuplicateProbe(title: "", fileSHA256s: [sha])
        if let hit = try detector.matches(for: probe, limit: 1).first, hit.reasons.contains(.sameFile) {
            return .duplicate(existingTitle: hit.title)
        }
        
        let title = InboxFolderWatcher.title(fromFileName: url.lastPathComponent)
        var new = NewItem(title: title.isEmpty ? "Untitled PDF" : title)
        new.sourceKind = .pdfDrop
        new.sourceURL = url.path
        new.reviewState = .inbox
        
        return try model.atomically {
            let item = try model.items.create(new)
            try model.attachments.add(fileAt: url, to: item.id, kind: .pdf)
            return .added(itemID: item.id)
        }
    }
    
    /// DOI, arXiv ID, link or plain title. Returns what was recognised so the caller can look it up.
    static func addText(_ text: String, model: LibraryModel) throws -> (item: ModelItem, identifier: MetadataIdentifier?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var new = NewItem(title: trimmed)
        new.reviewState = .inbox
        new.sourceURL = trimmed
        
        let identifier = MetadataResolver.identify(trimmed)
        switch identifier {
        case .doi(let doi)?:
            new.doi = doi
            new.title = doi
            new.sourceKind = .doi
        case .arxiv(let id)?:
            new.arxivID = id
            new.title = "arXiv:\(id)"
            new.sourceKind = .arxiv
        case .url(let link)?:
            new.url = link.absoluteString
            new.title = link.absoluteString
            new.sourceKind = .url
        case nil:
            new.sourceKind = .manual
            new.sourceURL = ""
        }
        return (try model.items.create(new), identifier)
    }
    
    static func addBibTeX(at url: URL, model: LibraryModel) throws -> (added: Int, skipped: Int) {
        let result = try BibTeXImporter.parse(fileAt: url, reviewState: .inbox)
        let added = try create(result.entries.map(\.item), model: model)
        return (added, result.skipped.count)
    }
    
    static func addRIS(at url: URL, model: LibraryModel) throws -> (added: Int, skipped: Int) {
        let result = try RISImporter.parse(fileAt: url, reviewState: .inbox)
        let added = try create(result.entries.map(\.item), model: model)
        return (added, result.skipped.count)
    }
    
    private static func create(_ entries: [NewItem], model: LibraryModel) throws -> Int {
        try model.atomically {
            for entry in entries {
                var item = entry
                item.reviewState = .inbox
                try model.items.create(item)
            }
            return entries.count
        }
    }
}
