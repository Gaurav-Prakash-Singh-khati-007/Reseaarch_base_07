//
//  AddPaperSheet.swift
//  ResearchBase
//
//  Owner: Agent 57 · Features: F-15, F-16 (F-18 duplicate warning shown here)
//
//  Modal with 4 tabs: By identifier, From a PDF, Import a library, By hand.
//
//  What is real now
//    By identifier  Paste a DOI, arXiv ID or link. The details fill in on their own
//                   (about half a second after typing stops) via MetadataResolver (#5).
//                   Offline, an older saved answer is used and labelled as such.
//    From a PDF     Drop or choose a PDF. PDFMetadataReader (#6) reads page one; a DOI or
//                   arXiv ID found there is looked up through MetadataResolver. Anything
//                   found is a hint the person confirms. The file is attached on add.
//    By hand        Real form. "Edit first" from the other tabs pre-fills it.
//    Duplicates     DuplicateDetector (#8) is asked before anything is added (by DOI,
//                   arXiv ID, file fingerprint and title).
//    Import a library  UNCHANGED (preview rows are still static). F-19 wiring belongs to #53.
//
//  PUBLIC API (the original call still compiles: AddPaperSheet(onDismiss:) { title in ... })
//    AddPaperSheet(onDismiss:onAdd:model:onAdded:onOpenExisting:)
//      onDismiss        close the sheet
//      onAdd            hand-off mode ONLY (model == nil): called with the title, nothing is saved here
//      model            the open library. Nil = lookups and saving are off and the sheet says so
//      onAdded          called with the saved item (model != nil). onAdd is NOT called in that case
//      onOpenExisting   called with the id of the existing copy when the person taps "Open existing"
//      initialCollectionID  optional: the folder the footer menu starts on (default none)
//    Add to collection (footer menu): the saved paper is also put in the chosen collection,
//      in the same all-or-nothing step. Choosing none changes nothing.
//    AddPaperLogic      pure helpers (author text -> creators, year check, duplicate probe, messages,
//                       collectionChoices(_:), saveItem(model:new:pdf:collectionID:))
//
//  Reads (does not edit): MetadataResolver, PDFMetadataReader, DuplicateDetector,
//  LibraryModel, ItemStore, AttachmentStore, CitationKeyStore, ModelTypes.
//

import SwiftUI
import UniformTypeIdentifiers

enum AddPaperTab: String, CaseIterable {
    case identifier = "By identifier"
    case pdf = "From a PDF"
    case importLib = "Import a library"
    case manual = "By hand"
}

// MARK: - Pure helpers (unit-tested in AddPaperSheetTests)

enum AddPaperLogic {

    /// "Family, Given; Family, Given" -> creators. Also accepts "Given Family" and " and ".
    static func parseAuthors(_ text: String) -> [CreatorInput] {
        let normalized = text.replacingOccurrences(of: "\n", with: ";")
        var parts: [String] = []
        for chunk in normalized.split(separator: ";") {
            let pieces = chunk.components(separatedBy: " and ")
            parts.append(contentsOf: pieces)
        }
        var result: [CreatorInput] = []
        for raw in parts {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            if let comma = name.firstIndex(of: ",") {
                let family = String(name[..<comma]).trimmingCharacters(in: .whitespaces)
                let given = String(name[name.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                if !family.isEmpty { result.append(CreatorInput(family: family, given: given)) }
            } else if let space = name.lastIndex(of: " ") {
                let given = String(name[..<space]).trimmingCharacters(in: .whitespaces)
                let family = String(name[name.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                if !family.isEmpty { result.append(CreatorInput(family: family, given: given)) }
            } else {
                result.append(CreatorInput(family: name))
            }
        }
        return result
    }

    /// "Family, Given; Family, Given" for the form field.
    static func authorsText(_ creators: [CreatorInput]) -> String {
        creators.map { $0.given.isEmpty ? $0.family : "\($0.family), \($0.given)" }.joined(separator: "; ")
    }

    /// Short line for result cards: "He, Zhang, Ren, Sun" (first six, then "et al.").
    static func authorsSummary(_ creators: [CreatorInput], limit: Int = 6) -> String {
        let families = creators.map(\.family)
        if families.isEmpty { return "Unknown authors" }
        if families.count <= limit { return families.joined(separator: ", ") }
        return families.prefix(limit).joined(separator: ", ") + " et al."
    }

    /// Empty is allowed (no year). Otherwise 0...9999.
    static func parseYear(_ text: String) -> (value: Int?, isValid: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (nil, true) }
        guard let year = Int(trimmed), (0...9999).contains(year) else { return (nil, false) }
        return (year, true)
    }

    static func probe(
        title: String, doi: String?, arxivID: String?, year: Int?,
        creators: [CreatorInput], fileSHA256s: [String] = []
    ) -> DuplicateProbe {
        let first = creators.first(where: { $0.role == .author }) ?? creators.first
        return DuplicateProbe(
            doi: (doi?.isEmpty ?? true) ? nil : doi,
            arxivID: (arxivID?.isEmpty ?? true) ? nil : arxivID,
            title: title,
            year: year,
            firstAuthorFamily: first?.family,
            fileSHA256s: fileSHA256s
        )
    }

    /// True when a probe has anything to match on.
    static func isWorthChecking(_ probe: DuplicateProbe) -> Bool {
        !probe.title.trimmingCharacters(in: .whitespaces).isEmpty
            || probe.doi != nil || probe.arxivID != nil || !probe.fileSHA256s.isEmpty
    }

    static func message(for problem: PDFMetadata.Problem) -> String {
        switch problem {
        case .cannotOpen: return "This file could not be opened as a PDF. You can enter the details by hand."
        case .passwordProtected: return "This PDF is password-protected, so page one cannot be read. You can enter the details by hand."
        case .noPages: return "This PDF has no pages. You can enter the details by hand."
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Preprint when only an arXiv ID is known, otherwise article.
    /// One collection in the footer menu, in display order (parents first).
    struct CollectionChoice: Equatable, Identifiable {
        var id: String
        var name: String
        var depth: Int
    }

    /// Collections as an indented list: siblings by position then name. A collection whose
    /// parent is unknown shows at the top level, and a loop in the data cannot repeat entries.
    static func collectionChoices(_ collections: [ModelCollection]) -> [CollectionChoice] {
        let live = collections.filter { $0.deletedAt == nil }
        let known = Set(live.map(\.id))
        var children: [String?: [ModelCollection]] = [:]
        for c in live {
            let parent = c.parentID.flatMap { known.contains($0) ? $0 : nil }
            children[parent, default: []].append(c)
        }
        func order(_ a: ModelCollection, _ b: ModelCollection) -> Bool {
            a.position != b.position
                ? a.position < b.position
                : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        var result: [CollectionChoice] = []
        var seen = Set<String>()
        func walk(_ parent: String?, _ depth: Int) {
            for c in (children[parent] ?? []).sorted(by: order) where seen.insert(c.id).inserted {
                result.append(CollectionChoice(id: c.id, name: c.name, depth: depth))
                walk(c.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }

    /// Creates the paper, attaches its PDF and puts it in the chosen collection, as ONE
    /// all-or-nothing step. Any failure undoes all of it.
    static func saveItem(
        model: LibraryModel,
        new: NewItem,
        pdf: URL?,
        collectionID: String?
    ) throws -> ModelItem {
        try model.atomically {
            let created = try model.items.create(new)
            if let pdf {
                try model.attachments.add(fileAt: pdf, to: created.id)
            }
            if let collectionID {
                try model.collections.addItem(created.id, to: collectionID)
            }
            return created
        }
    }

    static func guessedType(doi: String?, arxivID: String?) -> ItemType {
        (doi?.isEmpty ?? true) && !(arxivID?.isEmpty ?? true) ? .preprint : .article
    }
}

// MARK: - Sheet

/// One line of the import preview (F-19).
struct RBImportRow: Identifiable {
    let id = UUID()
    let item: NewItem
    let isDuplicate: Bool
    var title: String { item.title }
    var year: Int? { item.year }
}

struct AddPaperSheet: View {
    let onDismiss: () -> Void
    var onAdd: (String) -> Void
    var model: LibraryModel?
    var onAdded: (ModelItem) -> Void
    var onOpenExisting: (String) -> Void
    var initialCollectionID: String?

    init(
        onDismiss: @escaping () -> Void,
        onAdd: @escaping (String) -> Void = { _ in },
        model: LibraryModel? = nil,
        onAdded: @escaping (ModelItem) -> Void = { _ in },
        onOpenExisting: @escaping (String) -> Void = { _ in },
        initialCollectionID: String? = nil
    ) {
        self.onDismiss = onDismiss
        self.onAdd = onAdd
        self.model = model
        self.onAdded = onAdded
        self.onOpenExisting = onOpenExisting
        self.initialCollectionID = initialCollectionID
        _collectionID = State(initialValue: initialCollectionID)
    }

    @State private var selectedTab: AddPaperTab = .identifier
    @State private var saveError: String? = nil
    @State private var collectionID: String? = nil
    @State private var collectionChoices: [AddPaperLogic.CollectionChoice] = []

    // Tab 1: By Identifier
    @State private var identifierInput = ""
    @State private var lookupState: LookupState = .idle
    @State private var foundPaper: ResolvedMetadata? = nil
    @State private var foundDuplicate: DuplicateMatch? = nil
    @State private var foundKey = ""
    @State private var lookupTask: Task<Void, Never>? = nil

    enum LookupState: Equatable {
        case idle
        case loading
        case noLibrary
        case error(String)
        case notFound(String)
        case found
    }

    // Tab 2: PDF Drop
    @State private var isPdfTargeted = false
    @State private var showingFileImporter = false
    @State private var pdfState: PDFReadState = .idle
    @State private var pdfPick: PDFPick? = nil
    @State private var pdfScopedURL: URL? = nil
    @State private var pdfTask: Task<Void, Never>? = nil

    enum PDFReadState: Equatable {
        case idle
        case reading(String)
        case failed(String)
        case ready
    }

    struct PDFPick {
        var url: URL
        var fileName: String
        var sha256: String?
        var info: PDFMetadata
        var resolved: ResolvedMetadata?
        /// Why the online lookup was not used (offline, not found ...). Nil when it worked or there was nothing to look up.
        var lookupNote: String?
        var duplicate: DuplicateMatch?
        var citationKey: String
    }

    // Tab 3: Import
    @State private var importSelectedFormat: String = "BibTeX"
    @State private var importRows: [RBImportRow] = []
    @State private var importSummary: String = ""
    @State private var importMessage: String?
    @State private var showingImportPicker = false

    // Tab 4: Manual Form
    @State private var manualType: ItemType = .article
    @State private var manualTitle = ""
    @State private var manualAuthors = ""
    @State private var manualVenue = ""
    @State private var manualYear = ""
    @State private var manualDOI = ""
    /// Details the form has no field for (abstract, volume, pages, arXiv ID, source link ...), kept from a lookup.
    @State private var manualCarry: ResolvedMetadata? = nil
    @State private var manualPDFURL: URL? = nil
    @State private var manualDuplicate: DuplicateMatch? = nil
    @State private var manualDuplicateAccepted = false
    @State private var manualCheckTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Text("Add a paper")
                        .font(RBFont.detail(.bold))
                        .foregroundStyle(RBColor.primaryText)
                }

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
            .padding(.bottom, 10)

            // Tab Selector
            HStack(spacing: 16) {
                ForEach(AddPaperTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.rawValue)
                                .font(RBFont.body(selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab ? RBColor.primaryText : RBColor.secondaryText)

                            Rectangle()
                                .fill(selectedTab == tab ? RBColor.accent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .overlay(alignment: .bottom) {
                Rectangle().fill(RBColor.border).frame(height: 1)
            }

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .identifier:
                        identifierTabView
                    case .pdf:
                        pdfTabView
                    case .importLib:
                        importTabView
                    case .manual:
                        manualTabView
                    }
                }
                .padding(20)
            }

            Divider()
                .overlay(RBColor.border)

            // Footer
            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.error)
                        .lineLimit(2)
                } else {
                    Text("New papers go to the Inbox unless you choose “Add to library”.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }

                Spacer()

                if model != nil, !collectionChoices.isEmpty {
                    collectionMenu
                }

                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 720, height: 540)
        .background(RBColor.elevated)
        .onChange(of: identifierInput) { _, newValue in
            scheduleLiveLookup(for: newValue)
        }
        .onChange(of: manualTitle) { _, _ in scheduleManualDuplicateCheck() }
        .onChange(of: manualDOI) { _, _ in scheduleManualDuplicateCheck() }
        .onChange(of: manualYear) { _, _ in scheduleManualDuplicateCheck() }
        .onChange(of: manualAuthors) { _, _ in scheduleManualDuplicateCheck() }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                handlePickedPDF(url, securityScoped: url.startAccessingSecurityScopedResource())
            }
        }
        .onAppear { reloadCollectionChoices() }
        .onDisappear {
            lookupTask?.cancel()
            pdfTask?.cancel()
            manualCheckTask?.cancel()
            releasePDFAccess()
        }
    }

    // MARK: - Shared: duplicates and saving

    private func findDuplicate(_ probe: DuplicateProbe) -> DuplicateMatch? {
        guard let model, AddPaperLogic.isWorthChecking(probe) else { return nil }
        // A failed check must never block adding: no answer means no warning.
        return (try? DuplicateDetector(model: model).matches(for: probe, limit: 1))?.first
    }

    private func previewKey(creators: [CreatorInput], year: Int?, title: String) -> String {
        guard let model else { return "" }
        let first = creators.first(where: { $0.role == .author }) ?? creators.first
        return (try? model.citationKeys.generate(firstCreator: first, year: year, title: title)) ?? ""
    }

    // MARK: - Add to collection

    private var selectedCollectionName: String? {
        collectionChoices.first(where: { $0.id == collectionID })?.name
    }

    private var collectionMenu: some View {
        Menu {
            Button {
                collectionID = nil
            } label: {
                if collectionID == nil {
                    Label("No collection", systemImage: "checkmark")
                } else {
                    Text("No collection")
                }
            }
            Divider()
            ForEach(collectionChoices) { choice in
                Button {
                    collectionID = choice.id
                } label: {
                    let name = String(repeating: "    ", count: choice.depth) + choice.name
                    if collectionID == choice.id {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Label(
                selectedCollectionName.map { "Add to: \($0)" } ?? "Add to collection",
                systemImage: "folder"
            )
            .font(RBFont.secondary(.medium))
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Also put the new paper in this collection")
    }

    private func reloadCollectionChoices() {
        guard let model else {
            collectionChoices = []
            return
        }
        collectionChoices = AddPaperLogic.collectionChoices((try? model.collections.all()) ?? [])
        // A folder that no longer exists is dropped instead of failing the save.
        if let id = collectionID, !collectionChoices.contains(where: { $0.id == id }) {
            collectionID = nil
        }
    }

    /// Saves in one all-or-nothing step: the paper, its PDF if given, and its collection if chosen.
    private func save(_ new: NewItem, pdf: URL?) {
        saveError = nil
        guard let model else {
            // Hand-off mode: the caller decides what to do with a title.
            onAdd(new.title)
            onDismiss()
            return
        }
        do {
            let item = try AddPaperLogic.saveItem(
                model: model, new: new, pdf: pdf, collectionID: collectionID
            )
            onAdded(item)
            onDismiss()
        } catch {
            saveError = "Nothing was saved. " + AddPaperLogic.message(for: error)
        }
    }

    private func duplicateBanner(_ match: DuplicateMatch, allowAddAnyway: Bool, addAnyway: @escaping () -> Void = {}) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RBColor.warning)
            Text(match.bannerText)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.primaryText)
            Spacer()
            Button("Open existing") {
                onOpenExisting(match.itemID)
                onDismiss()
            }
            .buttonStyle(.bordered).controlSize(.small)
            if allowAddAnyway {
                Button("Add anyway", action: addAnyway)
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.warning.opacity(0.12)))
    }

    // MARK: - Tab 1: By Identifier

    private var identifierTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(RBColor.mutedText)

                    TextField("DOI, arXiv ID or web address", text: $identifierInput)
                        .textFieldStyle(.plain)
                        .font(RBFont.body())
                        .onSubmit { performLookup() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(RBColor.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(RBColor.border, lineWidth: 1)
                )

                Button {
                    performLookup()
                } label: {
                    Text("Look up")
                        .font(RBFont.body(.medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(RBColor.accent)
                        )
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }

            // Suggestion chips
            HStack(spacing: 8) {
                Text("Try:")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                ForEach(["10.1109/CVPR.2016.90", "arXiv:1706.03762", "1602.05629"], id: \.self) { sample in
                    Button {
                        identifierInput = sample
                        performLookup()
                    } label: {
                        Text(sample)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(RBColor.hover)
                            )
                            .overlay(
                                Capsule().stroke(RBColor.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                }
            }

            // State Views
            switch lookupState {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Looking up in Crossref, arXiv and OpenAlex…")
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.secondaryText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
            case .noLibrary:
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RBColor.warning)
                    Text("The library is not open, so lookups are unavailable. You can still fill in the details by hand.")
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.primaryText)
                    Spacer()
                    Button("Enter by hand") { selectedTab = .manual }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.warning.opacity(0.1)))
            case .error(let message):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RBColor.error)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn’t look that up.")
                            .font(RBFont.body(.semibold))
                            .foregroundStyle(RBColor.primaryText)
                        Text(message + " Nothing was saved.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    }
                    Spacer()
                    Button("Try again") { performLookup() }.buttonStyle(.bordered).controlSize(.small)
                    Button("Enter by hand") { selectedTab = .manual }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.error.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.error.opacity(0.3), lineWidth: 1))
            case .notFound(let message):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RBColor.warning)
                    Text(message)
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.primaryText)
                    Spacer()
                    Button("Enter by hand") { selectedTab = .manual }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.warning.opacity(0.1)))
            case .found:
                if let p = foundPaper {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(foundSourceLabel(p), systemImage: p.isStale ? "clock.arrow.circlepath" : "checkmark.circle.fill")
                                .font(RBFont.caption(.medium))
                                .foregroundStyle(p.isStale ? RBColor.warning : RBColor.success)
                            Spacer()
                            Text(p.type.displayName)
                                .font(RBFont.caption())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(RBColor.hover))
                        }

                        Text(p.title)
                            .font(RBFont.section(.bold))
                            .foregroundStyle(RBColor.primaryText)

                        Text(foundDetailLine(p))
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.secondaryText)

                        rbJoinedText(
                            Text("Citation key ")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText),
                            Text(foundKey.isEmpty ? "—" : foundKey)
                                .font(RBFont.caption().monospaced())
                                .foregroundStyle(RBColor.primaryText),
                            Text(" · DOI \(p.doi ?? "—") · arXiv \(p.arxivID ?? "—")")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                        )

                        if let dup = foundDuplicate {
                            duplicateBanner(dup, allowAddAnyway: false)
                            HStack {
                                Spacer()
                                Button("Edit first") { editFirst(from: p, pdf: nil) }.buttonStyle(.bordered).controlSize(.small)
                                if dup.confidence == .possible {
                                    Button("Add to library") { addFound(p) }
                                        .buttonStyle(.borderedProminent).controlSize(.small)
                                } else {
                                    Button("Add anyway") { addFound(p) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        } else {
                            HStack {
                                Spacer()
                                Button("Edit first") { editFirst(from: p, pdf: nil) }.buttonStyle(.bordered).controlSize(.small)
                                Button("Add to library") { addFound(p) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                            }
                            .padding(.top, 6)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border, lineWidth: 1))
                }
            }
        }
    }

    private func foundSourceLabel(_ p: ResolvedMetadata) -> String {
        if p.isStale { return "Saved copy from \(p.fetchedAt.formatted(date: .abbreviated, time: .omitted)) (you appear to be offline)" }
        if p.fromCache { return "Found via \(p.source.displayName) (saved copy)" }
        return "Found via \(p.source.displayName)"
    }

    private func foundDetailLine(_ p: ResolvedMetadata) -> String {
        var line = AddPaperLogic.authorsSummary(p.creators)
        let tail = [p.venue, p.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        if !tail.isEmpty { line += " · " + tail }
        return line
    }

    /// Live: runs on its own half a second after typing stops, but only for text that already looks like an identifier.
    private func scheduleLiveLookup(for text: String) {
        lookupTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lookupState = .idle
            foundPaper = nil
            foundDuplicate = nil
            return
        }
        guard MetadataResolver.identify(trimmed) != nil else {
            // Still typing, or not an identifier: stay quiet until Look up / Return.
            if case .loading = lookupState { lookupState = .idle }
            return
        }
        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await runLookup(trimmed, explicit: false)
        }
    }

    private func performLookup() {
        lookupTask?.cancel()
        let trimmed = identifierInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lookupTask = Task { await runLookup(trimmed, explicit: true) }
    }

    private func runLookup(_ text: String, explicit: Bool) async {
        saveError = nil
        guard let model else {
            lookupState = .noLibrary
            return
        }
        guard MetadataResolver.identify(text) != nil else {
            if explicit {
                lookupState = .notFound(MetadataError.notRecognised(text).errorDescription ?? "That is not an identifier.")
            }
            return
        }

        lookupState = .loading
        foundPaper = nil
        foundDuplicate = nil

        do {
            let resolved = try await MetadataResolver(database: model.database).resolve(text)
            if Task.isCancelled { return }
            foundPaper = resolved
            foundKey = previewKey(creators: resolved.creators, year: resolved.year, title: resolved.title)
            foundDuplicate = findDuplicate(AddPaperLogic.probe(
                title: resolved.title, doi: resolved.doi, arxivID: resolved.arxivID,
                year: resolved.year, creators: resolved.creators
            ))
            lookupState = .found
        } catch {
            if Task.isCancelled || AddPaperLogic.isCancellation(error) { return }
            if let metadataError = error as? MetadataError, case .notFound = metadataError {
                lookupState = .notFound(AddPaperLogic.message(for: error))
            } else {
                lookupState = .error(AddPaperLogic.message(for: error))
            }
        }
    }

    private func addFound(_ p: ResolvedMetadata) {
        save(p.toNewItem(), pdf: nil)
    }

    /// Fills the By hand form from a lookup (and keeps what the form has no field for).
    private func editFirst(from p: ResolvedMetadata, pdf: URL?) {
        manualType = p.type
        manualTitle = p.title
        manualAuthors = AddPaperLogic.authorsText(p.creators)
        manualVenue = p.venue
        manualYear = p.year.map(String.init) ?? ""
        manualDOI = p.doi ?? ""
        manualCarry = p
        manualPDFURL = pdf
        manualDuplicateAccepted = false
        selectedTab = .manual
    }

    // MARK: - Tab 2: From PDF

    private var pdfTabView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 32))
                    .foregroundStyle(RBColor.accent)

                Text("Drop a PDF here or choose a file")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("The app reads page one to find the DOI or title")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)

                Button("Choose a file…") { showingFileImporter = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, pdfPick == nil && pdfState == .idle ? 36 : 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(isPdfTargeted ? RBColor.accent.opacity(0.08) : RBColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(isPdfTargeted ? RBColor.accent : RBColor.border)
            )
            .onDrop(of: [.fileURL], isTargeted: $isPdfTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async {
                            handlePickedPDF(url, securityScoped: false)
                        }
                    }
                }
                return true
            }

            switch pdfState {
            case .idle:
                pdfExplainer
            case .reading(let name):
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Reading “\(name)”…")
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.secondaryText)
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
            case .failed(let message):
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RBColor.error)
                    Text(message)
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.primaryText)
                    Spacer()
                    Button("Enter by hand") { selectedTab = .manual }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.error.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.error.opacity(0.3), lineWidth: 1))
            case .ready:
                if let pick = pdfPick { pdfResultCard(pick) }
            }
        }
    }

    private var pdfExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happens next")
                .font(RBFont.body(.semibold))
                .foregroundStyle(RBColor.primaryText)

            stepRow(icon: "checkmark.circle.fill", color: RBColor.success, text: "Found DOI on page 1: fills details from Crossref automatically.")
            stepRow(icon: "exclamationmark.triangle.fill", color: RBColor.warning, text: "No DOI found: shows the title it found on page 1 for your confirmation.")
            stepRow(icon: "eye", color: RBColor.accent, text: "Scanned pages with no text: reads them with OCR so they become searchable.")
            stepRow(icon: "doc.on.doc", color: RBColor.secondaryText, text: "Same file already in library (by SHA-256 fingerprint): offers to open it instead of a duplicate copy.")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border, lineWidth: 1))
    }

    private func pdfResultCard(_ pick: PDFPick) -> some View {
        let resolved = pick.resolved
        let title = resolved?.title ?? pick.info.title ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let resolved {
                    Label(foundSourceLabel(resolved) + " · from the DOI/arXiv ID on page 1", systemImage: "checkmark.circle.fill")
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(resolved.isStale ? RBColor.warning : RBColor.success)
                } else if pick.info.hasUsefulResult {
                    Label("Read from page 1. Please check it.", systemImage: "exclamationmark.triangle.fill")
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(RBColor.warning)
                } else {
                    Label("Nothing usable found on page 1.", systemImage: "questionmark.circle")
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(RBColor.secondaryText)
                }
                Spacer()
                Text(pick.fileName)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .lineLimit(1)
            }

            if !title.isEmpty {
                Text(title)
                    .font(RBFont.section(.bold))
                    .foregroundStyle(RBColor.primaryText)
            }

            if let resolved {
                Text(foundDetailLine(resolved))
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            } else if !pick.info.authors.isEmpty {
                Text(pick.info.authors.joined(separator: ", "))
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            }

            rbJoinedText(
                Text("Citation key ")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText),
                Text(pick.citationKey.isEmpty ? "—" : pick.citationKey)
                    .font(RBFont.caption().monospaced())
                    .foregroundStyle(RBColor.primaryText),
                Text(" · DOI \(resolved?.doi ?? pick.info.doi ?? "—") · arXiv \(resolved?.arxivID ?? pick.info.arxivID ?? "—") · \(pick.info.pageCount) pages")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            )

            if let note = pick.lookupNote {
                Text(note)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }

            if pick.info.needsOCR {
                stepRow(icon: "eye", color: RBColor.accent, text: "This looks like a scan with no text. It can be read with OCR after it is added so it becomes searchable.")
            }

            if let dup = pick.duplicate {
                duplicateBanner(dup, allowAddAnyway: false)
            }

            HStack {
                Spacer()
                Button("Edit first") { editFromPDF(pick) }.buttonStyle(.bordered).controlSize(.small)
                if !title.isEmpty {
                    if let dup = pick.duplicate, dup.confidence != .possible {
                        Button("Add anyway") { addPDF(pick) }
                            .buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button("Add to library") { addPDF(pick) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border, lineWidth: 1))
    }

    private func stepRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
            Text(text)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
        }
    }

    private func releasePDFAccess() {
        pdfScopedURL?.stopAccessingSecurityScopedResource()
        pdfScopedURL = nil
    }

    private func handlePickedPDF(_ url: URL, securityScoped: Bool) {
        pdfTask?.cancel()
        releasePDFAccess()
        saveError = nil
        pdfPick = nil

        guard url.pathExtension.lowercased() == "pdf" else {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
            pdfState = .failed("“\(url.lastPathComponent)” is not a PDF file.")
            return
        }
        if securityScoped { pdfScopedURL = url }
        pdfState = .reading(url.lastPathComponent)
        pdfTask = Task { await readPDF(url) }
    }

    private func readPDF(_ url: URL) async {
        // Page one is read off the main thread (PDFMetadataReader.read(url:) opens its own document).
        let info = await Task.detached(priority: .userInitiated) { PDFMetadataReader.read(url: url) }.value
        if Task.isCancelled { return }

        if let problem = info.problem {
            pdfState = .failed(AddPaperLogic.message(for: problem))
            return
        }

        let sha = try? AttachmentStore.sha256Hex(of: url)

        var resolved: ResolvedMetadata? = nil
        var note: String? = nil
        if let model {
            var candidates: [MetadataIdentifier] = []
            if let doi = info.doi { candidates.append(.doi(doi)) }
            if let arxiv = info.arxivID { candidates.append(.arxiv(arxiv)) }
            let resolver = MetadataResolver(database: model.database)
            for candidate in candidates {
                do {
                    resolved = try await resolver.resolve(candidate)
                    note = nil
                    break
                } catch {
                    if Task.isCancelled || AddPaperLogic.isCancellation(error) { return }
                    note = "The online lookup did not work: " + AddPaperLogic.message(for: error)
                }
            }
        } else {
            note = "The library is not open, so only what the PDF itself says is shown."
        }

        let title = resolved?.title ?? info.title ?? ""
        let creators = resolved?.creators ?? AddPaperLogic.parseAuthors(info.authors.joined(separator: "; "))
        let year = resolved?.year ?? info.year
        let probe = AddPaperLogic.probe(
            title: title, doi: resolved?.doi ?? info.doi, arxivID: resolved?.arxivID ?? info.arxivID,
            year: year, creators: creators, fileSHA256s: sha.map { [$0] } ?? []
        )

        pdfPick = PDFPick(
            url: url,
            fileName: url.lastPathComponent,
            sha256: sha,
            info: info,
            resolved: resolved,
            lookupNote: note,
            duplicate: findDuplicate(probe),
            citationKey: title.isEmpty ? "" : previewKey(creators: creators, year: year, title: title)
        )
        pdfState = .ready
    }

    private func addPDF(_ pick: PDFPick) {
        var new: NewItem
        if let resolved = pick.resolved {
            new = resolved.toNewItem()
        } else {
            new = NewItem(
                type: AddPaperLogic.guessedType(doi: pick.info.doi, arxivID: pick.info.arxivID),
                title: pick.info.title ?? "",
                creators: AddPaperLogic.parseAuthors(pick.info.authors.joined(separator: "; ")),
                year: pick.info.year,
                doi: pick.info.doi,
                arxivID: pick.info.arxivID
            )
        }
        new.sourceKind = .pdfDrop
        save(new, pdf: pick.url)
    }

    private func editFromPDF(_ pick: PDFPick) {
        if let resolved = pick.resolved {
            editFirst(from: resolved, pdf: pick.url)
            return
        }
        let stem = pick.url.deletingPathExtension().lastPathComponent
        manualType = AddPaperLogic.guessedType(doi: pick.info.doi, arxivID: pick.info.arxivID)
        manualTitle = pick.info.title ?? stem
        manualAuthors = pick.info.authors.joined(separator: "; ")
        manualVenue = ""
        manualYear = pick.info.year.map(String.init) ?? ""
        manualDOI = pick.info.doi ?? ""
        // Keep an arXiv ID the form has no field for.
        manualCarry = pick.info.arxivID.map {
            ResolvedMetadata(type: manualType, title: manualTitle, doi: pick.info.doi, arxivID: $0,
                             source: .arxiv, capturedVia: .pdfDrop)
        }
        manualPDFURL = pick.url
        manualDuplicateAccepted = false
        selectedTab = .manual
    }
    // MARK: - Tab 3: Import
    
    private var importTabView: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                importFormatCard(title: "BibTeX", ext: ".bib", icon: "chevron.left.forwardslash.chevron.right")
                importFormatCard(title: "RIS", ext: ".ris", icon: "doc.text")
                importFormatCard(title: "CSV", ext: ".csv", icon: "tablecells")
                importFormatCard(title: "Zotero", ext: "library or RDF", icon: "books.vertical")
                importFormatCard(title: "Mendeley", ext: "via BibTeX/RIS export", icon: "books.vertical")
                importFormatCard(title: "ResearchBase", ext: "older app package", icon: "archivebox")
            }
            
            HStack {
                Text("Preview before anything is saved")
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button("Choose file…") { showingImportPicker = true }
                    .disabled(model == nil)
            }
            .padding(.top, 4)

            if model == nil {
                Text("The library is not open, so nothing can be imported right now.")
                    .font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
            }

            if !importSummary.isEmpty {
                Text(importSummary).font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
            }
            if let importMessage {
                Text(importMessage).font(RBFont.caption()).foregroundStyle(RBColor.warning)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Title").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Year").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(width: 60)
                    Text("Status").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(width: 140, alignment: .trailing)
                }
                .padding(10)
                .background(RBColor.surface)

                Divider()

                if importRows.isEmpty {
                    Text("Pick a \(importSelectedFormat) file to see what it contains.")
                        .font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
                        .frame(maxWidth: .infinity).padding(16)
                } else {
                    ForEach(importRows.prefix(200)) { row in
                        importRowView(row)
                        Divider()
                    }
                    if importRows.count > 200 {
                        Text("…and \(importRows.count - 200) more")
                            .font(RBFont.caption()).foregroundStyle(RBColor.mutedText).padding(10)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))

            let newCount = importRows.filter { !$0.isDuplicate }.count
            if newCount > 0 {
                Button("Import \(newCount) new paper\(newCount == 1 ? "" : "s")") { runImport() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.data, .json, .text], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { loadImportFile(url) }
            case .failure(let error): importMessage = error.localizedDescription
            }
        }
    }

    private func importFormatCard(title: String, ext: String, icon: String) -> some View {
        Button {
            importSelectedFormat = title
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(RBColor.accent)
                Text(title)
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text(ext)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(importSelectedFormat == title ? RBColor.accent : RBColor.border, lineWidth: importSelectedFormat == title ? 2 : 1)
            )
        }
        .buttonStyle(RBHoverPlainButtonStyle())
    }
    
    private func importRowView(_ row: RBImportRow) -> some View {
        let color = row.isDuplicate ? RBColor.warning : RBColor.success
        return HStack {
            Text(row.title).font(RBFont.secondary(.medium)).foregroundStyle(RBColor.primaryText).frame(maxWidth: .infinity, alignment: .leading)
            Text(row.year.map(String.init) ?? "–").font(RBFont.caption()).foregroundStyle(RBColor.mutedText).frame(width: 60)
            Text(row.isDuplicate ? "Duplicate of existing" : "New")
                .font(RBFont.caption(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.12)))
                .frame(width: 140, alignment: .trailing)
        }
        .padding(10)
    }

    private func loadImportFile(_ url: URL) {
        importRows = []
        importSummary = ""
        importMessage = nil
        guard let model else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var items: [NewItem] = []
        var summary = ""
        do {
            switch importSelectedFormat {
            case "BibTeX":
                let r = try BibTeXImporter.parse(fileAt: url); items = r.entries.map(\.item); summary = r.summary
            case "RIS":
                let r = try RISImporter.parse(fileAt: url); items = r.entries.map(\.item); summary = r.summary
            case "CSV":
                let r = try CSVImporter.parse(fileAt: url); items = r.entries.map(\.item); summary = r.summary
            case "Zotero", "Mendeley":
                let r = try ZoteroMendeleyImporter.parse(fileAt: url); items = r.entries.map(\.item); summary = r.summary
            default:
                importMessage = "To bring in an older ResearchBase package, use Settings → Restore."
                return
            }
        } catch {
            importMessage = AppErrorText.plain(error)
            return
        }

        let detector = DuplicateDetector(model: model)
        let index = try? detector.buildIndex()
        importRows = items.map { item in
            var dup = false
            if let index {
                let probe = DuplicateProbe(
                    doi: item.doi, arxivID: item.arxivID, title: item.title,
                    year: item.year, firstAuthorFamily: item.creators.first?.family
                )
                dup = !DuplicateMatcher.matches(for: probe, in: index, limit: 1).isEmpty
            }
            return RBImportRow(item: item, isDuplicate: dup)
        }
        importSummary = summary
        if items.isEmpty { importMessage = "Nothing could be read from that file." }
    }

    private func runImport() {
        guard let model else { return }
        let toAdd = importRows.filter { !$0.isDuplicate }
        do {
            try model.atomically {
                for row in toAdd { _ = try model.items.create(row.item) }
            }
            importMessage = nil
            importSummary = "Imported \(toAdd.count) paper\(toAdd.count == 1 ? "" : "s") into the Inbox."
            importRows = []
        } catch {
            importMessage = AppErrorText.plain(error)
        }
    }

    // MARK: - Tab 4: Manual Form

    private var manualTabView: some View {
        let yearCheck = AddPaperLogic.parseYear(manualYear)
        let titleOK = !manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsConfirm = (manualDuplicate != nil) && !manualDuplicateAccepted

        return VStack(spacing: 12) {
            if let pdf = manualPDFURL {
                HStack(spacing: 8) {
                    Image(systemName: "paperclip").foregroundStyle(RBColor.accent)
                    Text("\(pdf.lastPathComponent) will be attached.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                    Spacer()
                }
            }

            HStack {
                Text("Item type")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .frame(width: 100, alignment: .leading)

                Picker("", selection: $manualType) {
                    ForEach(ItemType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                Spacer()
            }

            formRow(label: "Title", text: $manualTitle)
            formRow(label: "Authors", text: $manualAuthors, placeholder: "Family, Given; Family, Given")
            formRow(label: "Venue", text: $manualVenue)
            formRow(label: "Year", text: $manualYear)
            if !yearCheck.isValid {
                Text("Year must be a number between 0 and 9999, or empty.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            formRow(label: "DOI", text: $manualDOI, placeholder: "10.xxxx/xxxxx")

            if let dup = manualDuplicate {
                duplicateBanner(dup, allowAddAnyway: false)
            }

            HStack {
                if !titleOK {
                    Text("A title is needed.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
                Spacer()
                if needsConfirm && manualDuplicate?.confidence != .possible {
                    Button("Add anyway") {
                        manualDuplicateAccepted = true
                        addManual(year: yearCheck.value)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!titleOK || !yearCheck.isValid)
                } else {
                    Button("Add to library") {
                        addManual(year: yearCheck.value)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!titleOK || !yearCheck.isValid)
                }
            }
            .padding(.top, 10)
        }
    }

    private func addManual(year: Int?) {
        var new = manualCarry?.toNewItem() ?? NewItem(title: "")
        new.type = manualType
        new.title = manualTitle
        new.creators = AddPaperLogic.parseAuthors(manualAuthors)
        new.venue = manualVenue
        new.year = year
        let doi = manualDOI.trimmingCharacters(in: .whitespacesAndNewlines)
        new.doi = doi.isEmpty ? nil : doi
        if manualPDFURL != nil { new.sourceKind = .pdfDrop }
        save(new, pdf: manualPDFURL)
    }

    /// Looks for an existing copy half a second after the person stops typing.
    private func scheduleManualDuplicateCheck() {
        manualCheckTask?.cancel()
        manualDuplicateAccepted = false
        guard model != nil else { return }
        let creators = AddPaperLogic.parseAuthors(manualAuthors)
        let doi = manualDOI.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = AddPaperLogic.probe(
            title: manualTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            doi: doi.isEmpty ? nil : doi,
            arxivID: manualCarry?.arxivID,
            year: AddPaperLogic.parseYear(manualYear).value,
            creators: creators
        )
        guard AddPaperLogic.isWorthChecking(probe) else {
            manualDuplicate = nil
            return
        }
        manualCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            manualDuplicate = findDuplicate(probe)
        }
    }

    private func formRow(label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack {
            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .frame(width: 100, alignment: .leading)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
        }
    }
}
