//
//  AddPaperView.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AddPaperView: View {

    @Environment(\.dismiss)
    private var dismiss

    @Environment(\.modelContext)
    private var modelContext

    /// Gives access to the SQLite library, which holds the lookup cache
    /// used when auto-filling details from a DOI or arXiv ID.
    @EnvironmentObject private var libraryHost: LibraryHost

    @State private var sourceURL: URL?

    @State private var title = ""
    @State private var authors = ""
    @State private var venue = ""
    @State private var year = ""

    @State private var abstractText = ""
    @State private var doi = ""
    @State private var urlString = ""
    @State private var tagsText = ""

    @State private var status: ReadingStatus = .unread
    @State private var rating = 0

    @State private var showingImporter = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    // PDF auto-fill: the same details the Zotero / identifier paths give.
    private enum ReadState: Equatable {
        case idle
        case reading
        case done(String)   // where the details came from
        case note(String)   // partial result or a problem, in plain words
    }

    @State private var readState: ReadState = .idle
    @State private var readTask: Task<Void, Never>?
    /// What auto-fill last wrote into each field. A field is only
    /// overwritten while it is empty or still holds that value, so
    /// anything the person typed is never lost.
    @State private var autoValues: [String: String] = [:]
    @State private var scopedURL: URL?
    @State private var isFetching = false

    var body: some View {

        VStack(spacing: 0) {

            header

            Divider()
                .overlay(RBColor.border)

            ScrollView {

                VStack(alignment: .leading, spacing: 24) {

                    pdfSection

                    metadataSection

                    detailsSection

                    organizationSection
                }
                .padding(28)
            }

            Divider()
                .overlay(RBColor.border)

            footer
        }
        .frame(
            width: 760,
            height: 720
        )
        .background(RBColor.background)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in

            switch result {

            case .success(let urls):

                guard let url = urls.first else {
                    return
                }

                sourceURL = url
                adoptPDF(url)

            case .failure(let error):

                errorMessage =
                    error.localizedDescription
            }
        }
        .onDisappear {
            readTask?.cancel()
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
        .alert(
            "Could Not Add Paper",
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

            Text(
                errorMessage ?? ""
            )
        }
    }

    // MARK: Header

    private var header: some View {

        HStack {

            VStack(alignment: .leading, spacing: 4) {

                Text("Add Literature")
                    .font(RBFont.detail(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Text("Add a paper to your research literature.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)
            .foregroundStyle(RBColor.secondaryText)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    // MARK: PDF

    private var pdfSection: some View {

        VStack(alignment: .leading, spacing: 12) {

            sectionTitle("PDF")

            HStack(spacing: 16) {

                Image(systemName: "doc.richtext")
                    .font(.system(size: 28))
                    .foregroundStyle(RBColor.accent)

                VStack(alignment: .leading, spacing: 4) {

                    if let sourceURL {

                        Text(
                            sourceURL.lastPathComponent
                        )
                        .font(RBFont.body(.medium))
                        .foregroundStyle(RBColor.primaryText)

                        Text("PDF selected")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.success)

                    } else {

                        Text("No PDF selected")
                            .font(RBFont.body(.medium))
                            .foregroundStyle(RBColor.primaryText)

                        Text("Choose the PDF you want to add.")
                            .font(RBFont.secondary())
                            .foregroundStyle(RBColor.secondaryText)
                    }
                }

                Spacer()

                Button(
                    sourceURL == nil
                    ? "Choose PDF"
                    : "Change PDF"
                ) {
                    showingImporter = true
                }
                .buttonStyle(RBPrimaryButtonStyle())
            }
            .padding(18)
            .background(RBColor.card)
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.panel)
                    .stroke(RBColor.border)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: RBRadius.panel)
            )

            readStatusView
        }
    }

    @ViewBuilder
    private var readStatusView: some View {
        switch readState {
        case .idle:
            EmptyView()
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the PDF and looking up its details…")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            }
        case .done(let source):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(RBColor.success)
                Text("Details filled in from \(source). Check them before adding.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            }
        case .note(let text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(RBColor.warning)
                Text(text)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            }
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {

        VStack(alignment: .leading, spacing: 14) {

            sectionTitle("Bibliographic Information")

            field("Title", text: $title)

            field("Authors", text: $authors)

            HStack(spacing: 16) {

                field(
                    "Venue / Journal / Conference",
                    text: $venue
                )

                field(
                    "Year",
                    text: $year
                )
                .frame(width: 120)
            }

            field(
                "Abstract",
                text: $abstractText,
                axis: .vertical
            )
            .frame(minHeight: 100)
        }
    }

    // MARK: Details

    private var detailsSection: some View {

        VStack(alignment: .leading, spacing: 14) {

            sectionTitle("Reference Details")

            HStack(alignment: .bottom, spacing: 12) {

                field(
                    "DOI or arXiv ID",
                    text: $doi
                )

                Button {
                    fetchFromIdentifier()
                } label: {
                    if isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Fetch details")
                    }
                }
                .buttonStyle(RBGhostButtonStyle())
                .disabled(
                    isFetching ||
                    MetadataResolver.identify(doi) == nil
                )
                .help("Look the DOI or arXiv ID up and fill in the fields above")
            }

            field(
                "URL",
                text: $urlString
            )
        }
    }

    // MARK: Organization

    private var organizationSection: some View {

        VStack(alignment: .leading, spacing: 14) {

            sectionTitle("Organization")

            field(
                "Tags",
                text: $tagsText
            )

            HStack(spacing: 20) {

                VStack(alignment: .leading, spacing: 8) {

                    Text("Reading Status")
                        .font(RBFont.secondary())
                        .foregroundStyle(
                            RBColor.secondaryText
                        )

                    Picker(
                        "",
                        selection: $status
                    ) {

                        ForEach(
                            ReadingStatus.allCases,
                            id: \.self
                        ) { status in

                            Text(status.libraryLabel)
                                .tag(status)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: 8) {

                    Text("Rating")
                        .font(RBFont.secondary())
                        .foregroundStyle(
                            RBColor.secondaryText
                        )

                    Stepper(
                        "\(rating) / 5",
                        value: $rating,
                        in: 0...5
                    )
                    .frame(width: 130)
                }

                Spacer()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {

        HStack {

            if sourceURL == nil {

                Text("Select a PDF to continue.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.warning)

            } else {

                Text("The PDF will be copied into ResearchBase.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .rbHover(cornerRadius: RBRadius.field)

            Button("Add Literature") {
                savePaper()
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(
                sourceURL == nil ||
                title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty ||
                isSaving
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: Helpers

    private func sectionTitle(
        _ title: String
    ) -> some View {

        Text(title)
            .font(RBFont.section(.semibold))
            .foregroundStyle(RBColor.primaryText)
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        axis: Axis = .horizontal
    ) -> some View {

        VStack(alignment: .leading, spacing: 7) {

            Text(label)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            TextField("", text: text, axis: axis)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RBColor.card)
                .overlay(
                    RoundedRectangle(cornerRadius: RBRadius.field)
                        .stroke(RBColor.border)
                )
                .foregroundStyle(RBColor.primaryText)
        }
    }

    // MARK: PDF auto-fill

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `value` into a field only if the field is empty or still
    /// holds what auto-fill wrote last time.
    private func fill(_ key: String, _ value: String?, _ field: Binding<String>) {
        guard let value = value.map(trimmed), !value.isEmpty else { return }
        let current = trimmed(field.wrappedValue)
        if current.isEmpty || current == autoValues[key] {
            field.wrappedValue = value
            autoValues[key] = value
        }
    }

    private func apply(_ resolved: ResolvedMetadata) {
        fill("title", resolved.title, $title)
        fill("authors", AddPaperLogic.authorsText(resolved.creators), $authors)
        fill("venue", resolved.venue, $venue)
        fill("year", resolved.year.map(String.init), $year)
        fill("abstract", resolved.abstract, $abstractText)
        fill("doi", resolved.doi ?? resolved.arxivID, $doi)

        let link: String
        if !resolved.url.isEmpty {
            link = resolved.url
        } else if let d = resolved.doi {
            link = "https://doi.org/\(d)"
        } else if let a = resolved.arxivID {
            link = "https://arxiv.org/abs/\(a)"
        } else {
            link = ""
        }
        fill("url", link, $urlString)
    }

    private func makeResolver() -> MetadataResolver? {
        if let database = libraryHost.model?.library.database {
            return MetadataResolver(database: database)
        }
        // No library open: an in-memory database still lets lookups work.
        guard let memory = try? LibraryDatabase.inMemory() else { return nil }
        return MetadataResolver(database: memory)
    }

    private func adoptPDF(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil

        // The file name is only a placeholder until something better is found.
        fill("title", url.deletingPathExtension().lastPathComponent, $title)

        readTask?.cancel()
        readState = .reading
        readTask = Task { await readPDF(url) }
    }

    private func readPDF(_ url: URL) async {

        // Page one is read off the main thread.
        let info = await Task.detached(priority: .userInitiated) {
            PDFMetadataReader.read(url: url)
        }.value

        if Task.isCancelled { return }

        if let problem = info.problem {
            readState = .note(AddPaperLogic.message(for: problem))
            return
        }

        // 1. What the PDF says about itself.
        fill("title", info.title, $title)
        fill("authors", info.authors.joined(separator: "; "), $authors)
        fill("year", info.year.map(String.init), $year)
        fill("doi", info.doi ?? info.arxivID, $doi)

        // 2. Look the identifier up for the full record.
        let identifier: MetadataIdentifier? =
            info.doi.map { .doi($0) } ?? info.arxivID.map { .arxiv($0) }

        guard let identifier else {
            if info.needsOCR {
                readState = .note("This PDF looks like a scan, so no text could be read. Please enter the details by hand.")
            } else if info.title != nil {
                readState = .note("No DOI or arXiv ID found in the PDF. The title and authors were read from page one; please check them and add the rest.")
            } else {
                readState = .note("Nothing reliable could be read from this PDF. Please enter the details by hand.")
            }
            return
        }

        guard let resolver = makeResolver() else {
            readState = .note("Details were read from the PDF, but the lookup is unavailable right now.")
            return
        }

        do {
            let resolved = try await resolver.resolve(identifier)
            if Task.isCancelled { return }
            apply(resolved)
            readState = .done(resolved.fromCache ? "\(resolved.source.displayName) (saved copy)" : resolved.source.displayName)
        } catch {
            if AddPaperLogic.isCancellation(error) { return }
            readState = .note("Details were read from the PDF, but the lookup failed: \(AddPaperLogic.message(for: error))")
        }
    }

    /// The "Fetch details" button next to the DOI field.
    private func fetchFromIdentifier() {
        let text = trimmed(doi)
        guard MetadataResolver.identify(text) != nil,
              let resolver = makeResolver() else { return }

        isFetching = true

        Task {
            defer { isFetching = false }
            do {
                apply(try await resolver.resolve(text))
                errorMessage = nil
            } catch {
                if AddPaperLogic.isCancellation(error) { return }
                errorMessage = AddPaperLogic.message(for: error)
            }
        }
    }

    // MARK: Save

    private func savePaper() {

        guard let sourceURL else {
            return
        }

        isSaving = true

        do {

            let managedURL =
                try PaperStorage.shared.importPDF(
                    from: sourceURL
                )

            let parsedYear =
                Int(
                    year.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                ) ?? 0

            let tags =
                tagsText
                    .split(separator: ",")
                    .map {
                        $0.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    }
                    .filter {
                        !$0.isEmpty
                    }

            _ = try ResearchDataStore(
                modelContext: modelContext
            )
            .createPaper(
                pdfURL: managedURL,
                title: title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                authors: authors.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                venue: venue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                year: parsedYear,
                abstractText: abstractText,
                doi: doi,
                urlString: urlString,
                tags: tags,
                status: status,
                rating: rating
            )

            dismiss()

        } catch {

            isSaving = false

            errorMessage =
                error.localizedDescription
        }
    }
}
