//
//  ReferenceDetailView.swift
//  ResearchBase
//
//  Phase 6 — References & Citation Manager
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct ReferenceDetailView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Environment(\.rbA70LibraryModel) private var rbLibraryModel

    let paper: PaperRecord

    // Core bibliographic fields
    @State private var title: String
    @State private var authors: String
    @State private var venue: String
    @State private var yearText: String
    @State private var doi: String
    @State private var urlString: String
    @State private var abstractText: String
    @State private var tagsText: String

    // Phase 6 reference fields
    @State private var citationKey: String
    @State private var publicationType: PublicationType
    @State private var publisher: String
    @State private var volume: String
    @State private var issue: String
    @State private var pages: String
    @State private var edition: String
    @State private var month: String

    @State private var selectedCitationStyle: CitationStyle = .apa

    @State private var showingDeleteConfirm = false
    @State private var showingPDFImporter = false
    @State private var showingReplacePDFConfirm = false

    @State private var errorMessage: String?
    @State private var copiedMessage: String?

    init(paper: PaperRecord) {

        self.paper = paper

        _title = State(initialValue: paper.title)
        _authors = State(initialValue: paper.authors)
        _venue = State(initialValue: paper.venue)
        _yearText = State(
            initialValue: paper.year > 0
                ? String(paper.year)
                : ""
        )

        _doi = State(initialValue: paper.doi)
        _urlString = State(initialValue: paper.urlString)
        _abstractText = State(initialValue: paper.abstractText)
        _tagsText = State(initialValue: paper.tagsText)

        _citationKey = State(initialValue: paper.citationKey)
        _publicationType = State(initialValue: paper.publicationType)
        _publisher = State(initialValue: paper.publisher)
        _volume = State(initialValue: paper.volume)
        _issue = State(initialValue: paper.issue)
        _pages = State(initialValue: paper.pages)
        _edition = State(initialValue: paper.edition)
        _month = State(initialValue: paper.month)
    }

    // MARK: - PDF State

    private var pdfURL: URL? {

        guard !paper.pdfFilePath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: paper.pdfFilePath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return url
    }

    private var hasPDF: Bool {
        pdfURL != nil
    }

    /// A throwaway record used only for citation preview.
    private func makeScratchRecord(year: Int) -> PaperRecord {

        PaperRecord(
            pdfFilePath: paper.pdfFilePath,
            title: title,
            authors: authors,
            venue: venue,
            year: year
        )
    }

    var body: some View {

        VStack(spacing: 0) {

            header

            Divider()
                .overlay(RBColor.border)

            ScrollView {

                VStack(
                    alignment: .leading,
                    spacing: 24
                ) {

                    metadataStatus

                    pdfSection

                    coreFieldsSection

                    citationKeySection

                    publicationTypeSection

                    additionalDetailsSection

                    linksSection

                    abstractSection

                    tagsSection

                    citationPreviewSection
                }
                .padding(RBLayout.pageSide)
            }

            Divider()
                .overlay(RBColor.border)

            footer
        }
        .frame(
            minWidth: 600,
            idealWidth: 780,
            maxWidth: 780,
            minHeight: 480,
            idealHeight: 760,
            maxHeight: 860
        )
        .background(RBColor.background)

        // Attach / replace PDF
        .fileImporter(
            isPresented: $showingPDFImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in

            handlePDFImport(result)
        }

        .alert(
            "Replace PDF?",
            isPresented: $showingReplacePDFConfirm
        ) {

            Button("Cancel", role: .cancel) {}

            Button("Choose New PDF") {
                showingPDFImporter = true
            }

        } message: {

            Text(
                "The existing PDF will be replaced on this PaperRecord. Existing research notes and PDF annotations will remain attached to the paper."
            )
        }

        .alert(
            "Delete Reference?",
            isPresented: $showingDeleteConfirm
        ) {

            Button("Cancel", role: .cancel) {}

            Button(
                "Delete",
                role: .destructive
            ) {
                deleteReference()
            }

        } message: {

            Text(
                "This removes \"\(paper.title)\" from your library, including its PDF annotations. Research notes linked to it will be unlinked, not deleted. The PDF file itself will NOT be deleted from disk."
            )
        }

        .alert(
            "Could Not Save Reference",
            isPresented: Binding(
                get: {
                    errorMessage != nil
                },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {

            Button("OK") {
                errorMessage = nil
            }

        } message: {

            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {

        RBPageHeader(
            title: "Edit Reference",
            subtitle:
                title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                ? "Bibliographic details for this reference."
                : title
        ) {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                RBColor.secondaryText
            )
        }
        .padding(.horizontal, RBLayout.pageSide)
        .padding(.vertical, RBLayout.pageTop)
    }

    // MARK: - Metadata Status

    /// Live check against the fields being edited (same four fields
    /// the prototype tracks: authors, year, venue, DOI).
    private var liveMissingFields: [String] {

        var missing: [String] = []

        func isBlank(_ value: String) -> Bool {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if isBlank(authors) { missing.append("authors") }

        if isBlank(yearText) || yearText
            .trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            missing.append("year")
        }

        if isBlank(venue) { missing.append("venue") }
        if isBlank(doi) { missing.append("DOI") }

        return missing
    }

    private var metadataStatus: some View {

        HStack(spacing: 8) {

            if liveMissingFields.isEmpty {
                RBBadge(text: "✓ Metadata complete", tone: .ok)
            } else {
                RBBadge(
                    text: "⚠ Missing: "
                        + liveMissingFields.joined(separator: ", "),
                    tone: .warning
                )
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - PDF Section

    private var pdfSection: some View {

        VStack(
            alignment: .leading,
            spacing: 12
        ) {

            HStack {

                sectionTitle("PDF")

                Spacer()

                if hasPDF {

                    Button {
                        if let url = pdfURL {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {

                        Label(
                            "Open PDF",
                            systemImage: "book.pages"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }

            RBCard(padding: 14) {
            HStack(spacing: 14) {

                Image(
                    systemName:
                        hasPDF
                        ? "doc.richtext"
                        : "doc.text"
                )
                .font(RBFont.title())
                .foregroundStyle(
                    hasPDF
                    ? RBColor.accent
                    : RBColor.mutedText
                )
                .frame(
                    width: 46,
                    height: 46
                )
                .background(
                    hasPDF
                    ? RBColor.accent.opacity(0.12)
                    : RBColor.card
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: RBRadius.panel
                    )
                )

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {

                    Text(
                        hasPDF
                        ? "PDF attached"
                        : "No PDF attached"
                    )
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(
                        RBColor.primaryText
                    )

                    if hasPDF {

                        Text(
                            pdfURL?.lastPathComponent
                            ?? "PDF available"
                        )
                        .font(RBFont.caption())
                        .foregroundStyle(
                            RBColor.secondaryText
                        )
                        .lineLimit(1)

                    } else {

                        Text(
                            "This reference is metadata-only. Attach a PDF whenever you have one."
                        )
                        .font(RBFont.caption())
                        .foregroundStyle(
                            RBColor.secondaryText
                        )
                    }
                }

                Spacer()

                Button {

                    if hasPDF {
                        showingReplacePDFConfirm = true
                    } else {
                        showingPDFImporter = true
                    }

                } label: {

                    Label(
                        hasPDF
                        ? "Replace PDF"
                        : "Attach PDF",
                        systemImage:
                            hasPDF
                            ? "arrow.triangle.2.circlepath"
                            : "paperclip"
                    )
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
            }
        }
    }

    // MARK: - Core Fields

    private var coreFieldsSection: some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {

            sectionTitle("Bibliographic Information")

            field(
                "Title",
                text: $title
            )

            field(
                "Authors",
                text: $authors
            )

            HStack(spacing: 16) {

                field(
                    "Venue / Journal / Conference",
                    text: $venue
                )

                field(
                    "Year",
                    text: $yearText
                )
                .frame(width: 120)
            }
        }
    }

    // MARK: - Citation Key

    private var citationKeySection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            sectionTitle("Citation Key")

            HStack(spacing: 10) {

                TextField(
                    "e.g. vaswani2017attention",
                    text: $citationKey
                )
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RBColor.inputBackground)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: RBRadius.field
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: RBRadius.field
                    )
                    .stroke(RBColor.border)
                )
                .foregroundStyle(
                    RBColor.primaryText
                )
                .font(RBFont.body())

                Button {

                    generateCitationKey()

                } label: {

                    Label(
                        "Generate",
                        systemImage: "wand.and.stars"
                    )
                }
                .buttonStyle(.bordered)
            }

            Text(
                "Citation keys are stored on the same PaperRecord and can be edited freely."
            )
            .font(RBFont.caption())
            .foregroundStyle(
                RBColor.mutedText
            )
        }
    }

    // MARK: - Publication Type

    private var publicationTypeSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            sectionTitle("Publication Type")

            Picker(
                "",
                selection: $publicationType
            ) {

                ForEach(
                    PublicationType.allCases,
                    id: \.self
                ) { type in

                    Text(type.rawValue)
                        .tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 280)
        }
    }

    // MARK: - Additional Details

    private var additionalDetailsSection: some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {

            sectionTitle("Additional Details")

            Text(
                "Optional — fill in whatever is relevant for this publication type."
            )
            .font(RBFont.caption())
            .foregroundStyle(
                RBColor.mutedText
            )

            HStack(spacing: 16) {

                field(
                    "Publisher",
                    text: $publisher
                )

                field(
                    "Edition",
                    text: $edition
                )
                .frame(width: 140)
            }

            HStack(spacing: 16) {

                field(
                    "Volume",
                    text: $volume
                )
                .frame(minWidth: 90, maxWidth: .infinity)

                field(
                    "Issue",
                    text: $issue
                )
                .frame(minWidth: 90, maxWidth: .infinity)

                field(
                    "Pages",
                    text: $pages
                )
                .frame(minWidth: 90, maxWidth: .infinity)

                field(
                    "Month",
                    text: $month
                )
                .frame(minWidth: 90, maxWidth: .infinity)
            }
        }
    }

    // MARK: - Links

    private var linksSection: some View {

        VStack(
            alignment: .leading,
            spacing: 14
        ) {

            sectionTitle("Links")

            HStack(
                alignment: .bottom,
                spacing: 10
            ) {

                field(
                    "DOI",
                    text: $doi
                )

                Button {

                    openDOI()

                } label: {

                    Label(
                        "Open",
                        systemImage: "arrow.up.right.square"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    doi
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
                )
            }

            HStack(
                alignment: .bottom,
                spacing: 10
            ) {

                field(
                    "URL",
                    text: $urlString
                )

                Button {

                    openURLString()

                } label: {

                    Label(
                        "Open",
                        systemImage: "arrow.up.right.square"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    urlString
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
                )
            }
        }
    }

    // MARK: - Abstract

    private var abstractSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            sectionTitle("Abstract")

            TextEditor(
                text: $abstractText
            )
            .font(RBFont.body())
            .foregroundStyle(
                RBColor.primaryText
            )
            .frame(minHeight: 130)
            .padding(8)
            .background(RBColor.inputBackground)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
                .stroke(RBColor.border)
            )
        }
    }

    // MARK: - Tags

    private var tagsSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            sectionTitle("Tags")

            field(
                "Tags",
                text: $tagsText
            )

            Text(
                "Separate multiple tags with commas."
            )
            .font(RBFont.caption())
            .foregroundStyle(
                RBColor.mutedText
            )
        }
    }

    // MARK: - Citation Preview

    private var citationPreviewSection: some View {

        VStack(
            alignment: .leading,
            spacing: 10
        ) {

            HStack {

                sectionTitle("Citation")

                Spacer()

                HStack(spacing: 6) {

                    ForEach(
                        CitationStyle.allCases
                    ) { style in

                        RBChip(
                            text: style.rawValue,
                            isSelected: selectedCitationStyle == style
                        ) {
                            selectedCitationStyle = style
                        }
                    }
                }
            }

            RBCard(padding: 14) {

                Text(currentPreviewCitation)
                    .font(RBFont.body())
                    .foregroundStyle(
                        RBColor.secondaryText
                    )
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            }

            HStack(spacing: 10) {

                Button {

                    copyCitation()

                } label: {

                    Label(
                        "Copy Citation",
                        systemImage: "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)

                Button {

                    copyCitationKey()

                } label: {

                    Label(
                        "Copy Citation Key",
                        systemImage: "number"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    citationKey
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
                )

                if let copiedMessage {

                    Text(copiedMessage)
                        .font(RBFont.caption())
                        .foregroundStyle(
                            RBColor.success
                        )
                }

                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {

        HStack {

            Button(
                role: .destructive
            ) {

                showingDeleteConfirm = true

            } label: {

                Text("Delete Reference")
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(
                RBColor.error
            )

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)

            Button("Save Changes") {
                save()
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(
                title
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            )
        }
        .padding(.horizontal, RBLayout.pageSide)
        .padding(.vertical, 18)
    }

    // MARK: - Helpers

    private func sectionTitle(
        _ title: String
    ) -> some View {

        RBSectionLabel(text: title)
    }

    private func field(
        _ label: String,
        text: Binding<String>
    ) -> some View {

        VStack(
            alignment: .leading,
            spacing: 7
        ) {

            Text(label.uppercased())
                .font(RBFont.label(.medium))
                .foregroundStyle(
                    RBColor.mutedText
                )

            TextField(
                "",
                text: text
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RBColor.inputBackground)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: RBRadius.field
                )
                .stroke(RBColor.border)
            )
            .foregroundStyle(
                RBColor.primaryText
            )
        }
    }

    private var currentPreviewCitation: String {

        let year = Int(
            yearText
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        ) ?? 0

        let scratch = makeScratchRecord(
            year: year
        )

        return CitationFormatter.citation(
            for: scratch,
            style: selectedCitationStyle
        )
    }

    // MARK: - Citation Actions

    private func generateCitationKey() {

        do {

            let suggestion =
                try ResearchDataStore(
                    modelContext: modelContext
                )
                .suggestCitationKey(
                    for: paper
                )

            citationKey = suggestion

        } catch {

            errorMessage =
                error.localizedDescription
        }
    }

    private func copyCitation() {

        let pasteboard =
            NSPasteboard.general

        pasteboard.clearContents()

        pasteboard.setString(
            currentPreviewCitation,
            forType: .string
        )

        showCopiedMessage(
            "Citation copied."
        )
    }

    private func copyCitationKey() {

        let pasteboard =
            NSPasteboard.general

        pasteboard.clearContents()

        pasteboard.setString(
            citationKey,
            forType: .string
        )

        showCopiedMessage(
            "Citation key copied."
        )
    }

    private func showCopiedMessage(
        _ text: String
    ) {

        copiedMessage = text

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2
        ) {

            if copiedMessage == text {
                copiedMessage = nil
            }
        }
    }

    // MARK: - URL Actions

    private func openDOI() {

        let trimmed =
            doi.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmed.isEmpty else {
            return
        }

        let doiURLString =
            trimmed
                .lowercased()
                .hasPrefix("http")
            ? trimmed
            : "https://doi.org/\(trimmed)"

        if let url = URL(
            string: doiURLString
        ) {

            NSWorkspace.shared.open(url)
        }
    }

    private func openURLString() {

        let trimmed =
            urlString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed)
        else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    // MARK: - PDF Actions

    private func handlePDFImport(
        _ result: Result<[URL], Error>
    ) {

        switch result {

        case .success(let urls):

            guard let sourceURL = urls.first else {
                return
            }

            attachPDF(
                from: sourceURL
            )

        case .failure(let error):

            errorMessage =
                error.localizedDescription
        }
    }

    private func attachPDF(
        from sourceURL: URL
    ) {

        do {

            let importedURL =
                try PaperStorage.shared.importPDF(
                    from: sourceURL
                )

            let previousPath =
                paper.pdfFilePath

            // IMPORTANT:
            // We update the existing PaperRecord.
            // No new PaperRecord is created.
            paper.pdfFilePath =
                importedURL.path

            paper.updatedAt = Date()

            try modelContext.save()

            // Only remove the old PDF after the new
            // PaperRecord path has been persisted.
            if
                !previousPath.isEmpty,
                previousPath != importedURL.path
            {

                let oldURL =
                    URL(
                        fileURLWithPath:
                            previousPath
                    )

                let storagePath =
                    PaperStorage.shared
                        .isManagedPaperFile(
                            oldURL
                        )

                if storagePath {

                    try? PaperStorage.shared
                        .deletePDF(
                            at: oldURL
                        )
                }
            }

        } catch {

            errorMessage =
                "Could not attach PDF: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func save() {

        let trimmedTitle =
            title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmedTitle.isEmpty else {
            return
        }

        let parsedYear =
            Int(
                yearText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            ) ?? 0

        do {

            try ResearchDataStore(
                modelContext: modelContext
            )
            .updateReferenceMetadata(
                paper,
                title: trimmedTitle,
                authors: authors.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                venue: venue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                year: parsedYear,
                doi: doi.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                urlString: urlString.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                citationKey: citationKey.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                publicationType: publicationType,
                publisher: publisher.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                volume: volume.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                issue: issue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                pages: pages.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                edition: edition.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                month: month.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )

            // These two fields are part of the canonical
            // PaperRecord but are not part of the Phase 6
            // metadata helper signature.
            paper.abstractText =
                abstractText

            paper.tagsText =
                tagsText

            paper.updatedAt =
                Date()

            try modelContext.save()

            dismiss()

        } catch {

            errorMessage =
                error.localizedDescription
        }
    }

    // MARK: - Delete

    private func deleteReference() {

        do {

            let id = paper.id.uuidString

            // SQLite first: if it fails, nothing has been deleted yet.
            try rbTrashLibraryItem(id: id)

            try ResearchDataStore(
                modelContext: modelContext
            )
            .deletePaper(paper)

            dismiss()

        } catch {

            errorMessage =
                error.localizedDescription
        }
    }

    /// Soft delete in the SQLite library (same as the Inbox). Does nothing
    /// when the library is not open or the paper is not in it.
    private func rbTrashLibraryItem(id: String) throws {

        guard let model = rbLibraryModel else { return }

        try model.atomically {
            let now = model.now()
            try model.database.run(
                "UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                [.text(now), .text(now), .text(id)]
            )
            try model.record("item", id, .delete, field: "deleted_at", old: nil, new: now)
        }
    }
}
