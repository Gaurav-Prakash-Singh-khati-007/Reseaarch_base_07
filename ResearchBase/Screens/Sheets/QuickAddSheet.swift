//
//  QuickAddSheet.swift
//  ResearchBase
//
//  Owner: Agent 58 · Features: F-15, F-17 (quick add)
//  Source of truth: docs/researchbase.html (F-17, F-20, Quick add modal)
//  Global shortcut: ⌥⌘N
//
//  Paste a DOI, arXiv ID or link (one per line), or drop PDFs. The sheet closes at once
//  and the paper goes to the INBOX; details are looked up in the background (MetadataResolver, #5).
//  Nothing is ever lost: if the lookup fails (offline, not found) the paper is still saved to the
//  Inbox with the pasted text as its title and the identifier filled in, and the caller is told why.
//  Dropped PDFs are read on page one (PDFMetadataReader, #6), looked up by their DOI/arXiv ID when
//  they have one, and attached. Files that are not PDFs are refused with a pointer to the importer.
//
//  PUBLIC API (the original call still compiles: QuickAddSheet(onDismiss:) { input in ... })
//    QuickAddSheet(onDismiss:onSubmit:model:onResult:)
//      onSubmit   hand-off mode ONLY (model == nil): the pasted text or dropped file name, nothing is saved here
//      model      the open library. Nil = hand-off mode
//      onResult   called once per paper with a QuickAddOutcome (model != nil). onSubmit is NOT called then
//    enum QuickAddOutcome        .added(ModelItem, note: String?) / .failed(String)
//    QuickAddService             @MainActor: add(input:model:) async -> [QuickAddOutcome]
//                                            add(pdf:model:) async -> QuickAddOutcome
//                                (reusable by the menu-bar and Open-with paths)
//    QuickAddLogic               pure helpers (line splitting, fallback item)
//
//  Reads (does not edit): MetadataResolver, PDFMetadataReader, LibraryModel, ItemStore,
//  AttachmentStore, ModelTypes.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Result of one quick add

enum QuickAddOutcome {
    /// Saved to the Inbox. `note` says what did not go perfectly (offline copy, no details found ...).
    case added(ModelItem, note: String?)
    /// Nothing was saved for this paper.
    case failed(String)
}

// MARK: - Pure helpers

enum QuickAddLogic {

    /// One paper per non-empty line.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// What is saved when the lookup is not possible: the pasted text is the title, the identifier is kept.
    static func fallbackItem(for text: String, identifier: MetadataIdentifier?) -> NewItem {
        var item = NewItem(title: text)
        item.reviewState = .inbox
        switch identifier {
        case .doi(let doi)?:
            item.doi = doi
        case .arxiv(let id)?:
            item.arxivID = id
            item.type = .preprint
        case .url(let url)?:
            item.url = url.absoluteString
        case nil:
            break
        }
        if let identifier {
            item.sourceKind = identifier.sourceKind
            item.sourceURL = identifier.sourceURLText
        }
        return item
    }

    /// Names as the PDF wrote them ("Kaiming He" or "He, Kaiming") -> creators. Never guesses beyond that.
    static func creators(fromPDFNames names: [String]) -> [CreatorInput] {
        names.compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return nil }
            if let comma = name.firstIndex(of: ",") {
                let family = String(name[..<comma]).trimmingCharacters(in: .whitespaces)
                let given = String(name[name.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                return family.isEmpty ? nil : CreatorInput(family: family, given: given)
            }
            if let space = name.lastIndex(of: " ") {
                return CreatorInput(
                    family: String(name[name.index(after: space)...]),
                    given: String(name[..<space]).trimmingCharacters(in: .whitespaces)
                )
            }
            return CreatorInput(family: name)
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

// MARK: - Background work

@MainActor
enum QuickAddService {

    /// Pasted text: one Inbox paper per line.
    static func add(input: String, model: LibraryModel) async -> [QuickAddOutcome] {
        let resolver = MetadataResolver(database: model.database)
        var outcomes: [QuickAddOutcome] = []

        for line in QuickAddLogic.lines(input) {
            let identifier = MetadataResolver.identify(line)
            var new: NewItem
            var note: String? = nil

            if let identifier {
                do {
                    let resolved = try await resolver.resolve(identifier)
                    new = resolved.toNewItem()
                    if resolved.isStale { note = "You appear to be offline, so a saved copy of the details was used." }
                } catch {
                    if QuickAddLogic.isCancellation(error) { continue }
                    new = QuickAddLogic.fallbackItem(for: line, identifier: identifier)
                    note = "Saved without details. " + QuickAddLogic.message(for: error)
                }
            } else {
                new = QuickAddLogic.fallbackItem(for: line, identifier: nil)
                note = "Not a DOI, arXiv ID or link, so it was saved with that text as the title."
            }

            new.reviewState = .inbox
            do {
                outcomes.append(.added(try model.items.create(new), note: note))
            } catch {
                outcomes.append(.failed("“\(line)” was not saved. " + QuickAddLogic.message(for: error)))
            }
        }
        return outcomes
    }

    /// A dropped file. Only PDFs are taken.
    static func add(pdf url: URL, model: LibraryModel) async -> QuickAddOutcome {
        guard url.pathExtension.lowercased() == "pdf" else {
            return .failed("“\(url.lastPathComponent)” is not a PDF. Use Add paper → Import a library for .bib, .ris and .csv files.")
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let info = await Task.detached(priority: .userInitiated) { PDFMetadataReader.read(url: url) }.value
        let stem = url.deletingPathExtension().lastPathComponent
        var note: String? = nil
        var new: NewItem? = nil

        if let problem = info.problem {
            switch problem {
            case .passwordProtected: note = "This PDF is password-protected, so page one could not be read."
            case .cannotOpen: note = "This file could not be read as a PDF."
            case .noPages: note = "This PDF has no pages."
            }
        } else {
            var candidates: [MetadataIdentifier] = []
            if let doi = info.doi { candidates.append(.doi(doi)) }
            if let arxiv = info.arxivID { candidates.append(.arxiv(arxiv)) }
            let resolver = MetadataResolver(database: model.database)
            for candidate in candidates {
                do {
                    new = try await resolver.resolve(candidate).toNewItem()
                    note = nil
                    break
                } catch {
                    if QuickAddLogic.isCancellation(error) { return .failed("Cancelled.") }
                    note = "The online lookup did not work. " + QuickAddLogic.message(for: error)
                }
            }
            if new == nil, info.title != nil || info.doi != nil || info.arxivID != nil {
                new = NewItem(
                    type: info.doi == nil && info.arxivID != nil ? .preprint : .article,
                    title: info.title ?? stem,
                    year: info.year,
                    doi: info.doi,
                    arxivID: info.arxivID
                )
                new?.creators = QuickAddLogic.creators(fromPDFNames: info.authors)
                note = (note ?? "") + " Details come from the PDF itself; please check them."
            }
            if info.needsOCR {
                note = (note.map { $0 + " " } ?? "") + "This looks like a scan; it still needs OCR to become searchable."
            }
        }

        var item = new ?? NewItem(title: stem)
        item.reviewState = .inbox
        item.sourceKind = .pdfDrop

        do {
            let saved: ModelItem = try model.atomically {
                let created = try model.items.create(item)
                try model.attachments.add(fileAt: url, to: created.id)
                return created
            }
            return .added(saved, note: note?.trimmingCharacters(in: .whitespaces))
        } catch {
            return .failed("“\(url.lastPathComponent)” was not saved. " + QuickAddLogic.message(for: error))
        }
    }
}

// MARK: - Sheet

struct QuickAddSheet: View {
    let onDismiss: () -> Void
    let onSubmit: (String) -> Void
    var model: LibraryModel?
    var onResult: (QuickAddOutcome) -> Void

    init(
        onDismiss: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void = { _ in },
        model: LibraryModel? = nil,
        onResult: @escaping (QuickAddOutcome) -> Void = { _ in }
    ) {
        self.onDismiss = onDismiss
        self.onSubmit = onSubmit
        self.model = model
        self.onResult = onResult
    }

    @State private var input = ""
    @State private var isTargeted = false
    @FocusState private var isFocused: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                        .foregroundStyle(RBColor.accent)
                    
                    TextField("Paste a DOI, arXiv ID or link, or drop a PDF", text: $input)
                        .textFieldStyle(.plain)
                        .font(RBFont.section())
                        .foregroundStyle(RBColor.primaryText)
                        .focused($isFocused)
                        .onSubmit {
                            submit()
                        }
                    
                    if !input.isEmpty {
                        Button {
                            submit()
                        } label: {
                            Text("Add")
                                .font(RBFont.body(.medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(RBColor.accent)
                                )
                        }
                        .buttonStyle(RBHoverPlainButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                
                HStack(spacing: 4) {
                    Text("Goes to the Inbox, looked up in the background.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                    
                    Text("Global shortcut:")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                    
                    HStack(spacing: 2) {
                        Text("⌥")
                        Text("⌘")
                        Text("N")
                    }
                    .font(RBFont.caption(.semibold).monospaced())
                    .foregroundStyle(RBColor.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(RBColor.hover)
                    )
                    
                    Text("works even when the app is in the background.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .frame(width: 580)
            .background(RBColor.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isTargeted ? RBColor.accent : RBColor.border, lineWidth: isTargeted ? 2 : 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 30, x: 0, y: 15)
            .padding(.top, 110)
            .frame(maxHeight: .infinity, alignment: .top)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard !providers.isEmpty else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            DispatchQueue.main.async {
                                handleDropped(url)
                            }
                        }
                    }
                }
                return true
            }
        }
        .onAppear {
            isFocused = true
        }
    }
    
    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let model else {
            onSubmit(trimmed)
            onDismiss()
            return
        }
        // Close now; the lookup carries on in the background and reports each paper when it is saved.
        let report = onResult
        onDismiss()
        Task {
            for outcome in await QuickAddService.add(input: trimmed, model: model) {
                report(outcome)
            }
        }
    }

    private func handleDropped(_ url: URL) {
        guard let model else {
            onSubmit(url.lastPathComponent)
            onDismiss()
            return
        }
        let report = onResult
        onDismiss()
        Task { report(await QuickAddService.add(pdf: url, model: model)) }
    }
}
