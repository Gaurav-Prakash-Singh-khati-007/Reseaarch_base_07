//
//  CitationStyle.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


//
//  CitationFormatter.swift
//  ResearchBase
//
//  Phase 6 — References & Citation Manager
//
//  Pure, stateless helpers for:
//    - suggesting a default citation key
//    - making a suggested key unique against existing keys
//    - formatting APA-like and IEEE-like citation text
//
//  These are intentionally simple. They establish a citation
//  formattinag architecture that can be expanded later (Phase 10
//  Writing Workspace, BibTeX export, etc.) rather than trying to
//  be a fully correct implementation of either style guide.
//
//  F-34 (Agent 52): the hook to CSL. See "CSL hook" at the end of this file.
//  APA and IEEE text from `citation(for:style:)` is unchanged. Harvard, Nature
//  and Chicago, and every `csl…` function below, use CSLEngine (Agent 23).
//

import Foundation

enum CitationStyle: String, CaseIterable, Identifiable {
    case apa = "APA"
    case ieee = "IEEE"
    // F-34: formatted by the CSL engine (CSLEngine.swift).
    case harvard = "Harvard"
    case nature = "Nature"
    case chicago = "Chicago"

    var id: String { rawValue }
}

enum CitationFormatter {

    // =========================================================
    // MARK: - Citation Key Generation
    // =========================================================

    nonisolated private static let titleStopWords: Set<String> = [
        "a", "an", "the", "of", "on", "in", "to", "for", "and",
        "or", "is", "are", "with", "from", "by", "at", "as",
        "into", "using", "toward", "towards", "via"
    ]

    /// Builds a suggested (not-guaranteed-unique) citation key from
    /// the first author's surname, the year, and a keyword from the
    /// title. Example: "vaswani2017attention".
    nonisolated static func suggestedCitationKey(
        authors: String,
        year: Int,
        title: String
    ) -> String {

        let surname = firstAuthorSurname(from: authors)
        let yearPart = year > 0 ? String(year) : ""
        let keyword = firstTitleKeyword(from: title)

        let combined = "\(surname)\(yearPart)\(keyword)"

        let sanitized = sanitize(combined)

        return sanitized.isEmpty ? "reference" : sanitized
    }

    /// Given a suggested base key and the set of citation keys already
    /// used by other references, returns a key guaranteed not to
    /// collide with an existing one by appending "a", "b", "c", etc.
    /// This does not guarantee global uniqueness beyond this library,
    /// only within the provided set.
    nonisolated static func uniqueCitationKey(
        base: String,
        existingKeys: Set<String>
    ) -> String {

        let baseKey = base.isEmpty ? "reference" : base

        guard existingKeys.contains(baseKey) else {
            return baseKey
        }

        var suffixIndex = 0

        while true {

            let suffix = suffixLetter(for: suffixIndex)
            let candidate = "\(baseKey)\(suffix)"

            if !existingKeys.contains(candidate) {
                return candidate
            }

            suffixIndex += 1
        }
    }

    /// Converts 0, 1, 2, ... into "a", "b", "c", ... "z", "aa", "ab", ...
    nonisolated private static func suffixLetter(for index: Int) -> String {

        var n = index
        var letters = ""

        repeat {
            let remainder = n % 26
            let scalar = UnicodeScalar(UInt8(97 + remainder))
            letters = String(Character(scalar)) + letters
            n = n / 26 - 1
        } while n >= 0

        return letters
    }

    nonisolated private static func firstAuthorSurname(from authorsString: String) -> String {

        let trimmed = authorsString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "unknown"
        }

        let bySemicolon =
            trimmed
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let firstAuthorToken: String

        if bySemicolon.count > 1 {

            firstAuthorToken = bySemicolon[0]

        } else {

            // No semicolons. A single comma most likely means
            // "Surname, Given Name" for one author. Multiple commas
            // most likely means a comma-separated list of full names.
            let byComma =
                trimmed
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            if byComma.count == 2 {
                firstAuthorToken = "\(byComma[0]), \(byComma[1])"
            } else {
                firstAuthorToken = byComma.first ?? trimmed
            }
        }

        if firstAuthorToken.contains(",") {

            let parts = firstAuthorToken.split(separator: ",")

            return String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)

        } else {

            let words = firstAuthorToken.split(separator: " ")

            return String(words.last ?? Substring(firstAuthorToken))
        }
    }

    nonisolated private static func firstTitleKeyword(from title: String) -> String {

        let words =
            title
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }

        let keyword =
            words.first {
                $0.count > 3 && !titleStopWords.contains($0)
            }
            ?? words.first
            ?? ""

        return keyword
    }

    nonisolated private static func sanitize(_ text: String) -> String {

        text
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
    }

    // =========================================================
    // MARK: - Author Formatting
    // =========================================================

    /// Splits a free-text authors string into individual author
    /// name strings. Handles ";"-separated lists (preferred) and
    /// falls back to a heuristic for comma-separated input.
    private static func splitAuthors(_ authorsString: String) -> [String] {

        let trimmed = authorsString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return []
        }

        if trimmed.contains(";") {

            return trimmed
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let commaComponents =
            trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

        // Exactly one comma with no semicolons most likely means a
        // single "Surname, Given Name" author rather than two authors.
        if commaComponents.count == 2 {
            return ["\(commaComponents[0]), \(commaComponents[1])"]
        }

        return commaComponents
    }

    /// "Surname, G." — used by APA-style formatting.
    private static func surnameCommaInitial(_ name: String) -> String {

        if name.contains(",") {

            let parts =
                name.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            let surname = parts.first ?? name
            let givenInitial = parts.count > 1 ? String(parts[1].prefix(1)) : ""

            return givenInitial.isEmpty ? surname : "\(surname), \(givenInitial)."

        } else {

            let words = name.split(separator: " ").map(String.init)

            guard let surname = words.last else {
                return name
            }

            let givenInitial = words.count > 1 ? String(words[0].prefix(1)) : ""

            return givenInitial.isEmpty ? surname : "\(surname), \(givenInitial)."
        }
    }

    /// "G. Surname" — used by IEEE-style formatting.
    private static func initialSpaceSurname(_ name: String) -> String {

        if name.contains(",") {

            let parts =
                name.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            let surname = parts.first ?? name
            let givenInitial = parts.count > 1 ? String(parts[1].prefix(1)) : ""

            return givenInitial.isEmpty ? surname : "\(givenInitial). \(surname)"

        } else {

            let words = name.split(separator: " ").map(String.init)

            guard let surname = words.last else {
                return name
            }

            let givenInitial = words.count > 1 ? String(words[0].prefix(1)) : ""

            return givenInitial.isEmpty ? surname : "\(givenInitial). \(surname)"
        }
    }

    private static func formattedAuthorList(
        _ authorsString: String,
        formatter: (String) -> String
    ) -> String {

        let names = splitAuthors(authorsString)

        guard !names.isEmpty else {
            return ""
        }

        let formatted = names.map(formatter)

        if formatted.count > 3 {
            return formatted.prefix(3).joined(separator: ", ") + ", et al."
        }

        return formatted.joined(separator: ", ")
    }

    // =========================================================
    // MARK: - Citation Text
    // =========================================================

    /// An APA-like citation. This is a reasonable approximation
    /// for a beginner-friendly reference manager, not a guarantee
    /// of exact APA formatting — especially when metadata (venue,
    /// authors, year) is incomplete.
    static func apaCitation(for paper: PaperRecord) -> String {

        let authorsPart = formattedAuthorList(paper.authors, formatter: { surnameCommaInitial($0) })

        let yearPart = paper.year > 0 ? "(\(paper.year))." : "(n.d.)."

        let trimmedTitle = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titlePart = trimmedTitle.isEmpty ? "Untitled." : titleEndingWithPeriod(trimmedTitle)

        var leading = [authorsPart, yearPart, titlePart]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let venuePart = paper.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        if !venuePart.isEmpty {
            leading += " \(venuePart)."
        }

        return leading
    }

    /// An IEEE-like citation. Same caveat as `apaCitation`: it is a
    /// foundation for future expansion, not an exact implementation
    /// of the IEEE style guide.
    static func ieeeCitation(for paper: PaperRecord) -> String {

        let authorsPart = formattedAuthorList(paper.authors, formatter: { initialSpaceSurname($0) })

        let trimmedTitle = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titlePart = trimmedTitle.isEmpty ? "\"Untitled,\"" : "\"\(trimmedTitle),\""

        let venuePart = paper.venue.trimmingCharacters(in: .whitespacesAndNewlines)

        let yearPart = paper.year > 0 ? String(paper.year) : "n.d."

        var pieces: [String] = []

        if !authorsPart.isEmpty {
            pieces.append(authorsPart)
        }

        pieces.append(titlePart)

        if !venuePart.isEmpty {
            pieces.append(venuePart)
        }

        pieces.append(yearPart)

        return pieces.joined(separator: ", ") + "."
    }

    static func citation(for paper: PaperRecord, style: CitationStyle) -> String {

        switch style {

        case .apa:
            return apaCitation(for: paper)

        case .ieee:
            return ieeeCitation(for: paper)

        case .harvard, .nature, .chicago:
            // F-34: these styles come from the CSL engine. If it cannot format
            // the entry, fall back to the plain APA-like text so nothing is blank.
            return cslBibliographyEntry(for: paper, style: style) ?? apaCitation(for: paper)
        }
    }

    private static func titleEndingWithPeriod(_ title: String) -> String {

        if title.hasSuffix(".") || title.hasSuffix("?") || title.hasSuffix("!") {
            return title
        }

        return "\(title)."
    }
}

 
// MARK: - CSL hook (F-34, Agent 52)
//
//  PUBLIC API
//    CitationStyle.cslID / .bstName / .displayName / .isNumeric / .cslStyle
//    CitationStyleChoice                     one entry of a style picker (built in or imported)
//    CitationFormatter.availableStyles()     the built-in CSL styles, for a picker
//    CitationFormatter.loadCSLStyle(from:)   an imported .csl file
//    CitationFormatter.cslReference(for:)    PaperRecord -> CSLReference
//    CitationFormatter.cslBibliographyEntry(for:style:format:)
//    CitationFormatter.cslBibliography(for:style:format:)        a whole list
//    CitationFormatter.cslInTextCitation(for:style:format:numbers:locators:)
//    The same three for the SQLite layer: ModelItem + [ItemCreator]
//
//  Rules: formatting only. Nothing is saved, no file is read or written here, and
//  an entry that CSL cannot format returns nil so the caller can fall back.
 
extension CitationStyle {
 
    /// The id of the built-in CSL style that formats this style.
    var cslID: String {
        switch self {
        case .apa: return "apa"
        case .ieee: return "ieee"
        case .harvard: return "harvard"
        case .nature: return "nature"
        case .chicago: return "chicago"
        }
    }
 
    /// The .bst name LaTeX uses for this style (for the draft's bibliography style).
    var bstName: String {
        CSLEngine.bstName(forStyleID: cslID)
    }
 
    /// Long name for pickers, for example "Harvard (author-date)".
    var displayName: String {
        CSLEngine.builtInStyles.first { $0.id == cslID }?.name ?? rawValue
    }
 
    /// The parsed CSL style, or nil if it cannot be read.
    var cslStyle: CSLStyle? {
        CSLEngine.builtIn(cslID)
    }
 
    /// Numeric styles (IEEE, Nature) cite with numbers and need `numbers` in `cslInTextCitation`.
    var isNumeric: Bool {
        cslStyle?.isNumeric ?? false
    }
}
 
/// One row of a style picker: a built-in style or one the person imported from a .csl file.
struct CitationStyleChoice: Identifiable, Equatable {
    let id: String
    let name: String
    /// The .bst name for LaTeX.
    let bstName: String
    let isNumeric: Bool
    /// False for the styles that ship with ResearchBase.
    let isImported: Bool
}
 
extension CitationFormatter {
 
    // MARK: Styles
 
    /// The styles that ship with ResearchBase, in picker order.
    static func availableStyles() -> [CitationStyleChoice] {
        CSLEngine.builtInStyles.map { built in
            CitationStyleChoice(
                id: built.id,
                name: built.name,
                bstName: built.bst,
                isNumeric: CSLEngine.builtIn(built.id)?.isNumeric ?? false,
                isImported: false
            )
        }
    }
 
    /// Reads a .csl file the person imported. Throws `CSLEngineError` for a file that is not CSL.
    static func loadCSLStyle(from data: Data) throws -> CSLStyle {
        try CSLStyle.parse(data)
    }
 
    /// A picker row for an imported style.
    static func choice(for style: CSLStyle) -> CitationStyleChoice {
        CitationStyleChoice(
            id: style.id,
            name: style.title.isEmpty ? style.id : style.title,
            bstName: style.bibtexStyleName,
            isNumeric: style.isNumeric,
            isImported: true
        )
    }
 
    // MARK: PaperRecord (current SwiftData library)
 
    static func cslType(for type: PublicationType) -> String {
        switch type {
        case .journalArticle: return "article-journal"
        case .conferencePaper, .workshopPaper: return "paper-conference"
        case .book: return "book"
        case .bookChapter: return "chapter"
        case .thesis: return "thesis"
        case .technicalReport: return "report"
        case .preprint: return "article"
        case .website: return "webpage"
        case .other: return "article-journal"
        }
    }
 
    /// Turns the free-text authors string ("A. Smith; B. Jones" or "Smith, A.") into names.
    static func cslNames(from authors: String) -> [CSLName] {
        splitAuthors(authors).map { text -> CSLName in
            if text.contains(",") {
                let parts = text.split(separator: ",", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return CSLName(family: parts[0], given: parts.count > 1 ? parts[1] : "")
            }
            let words = text.split(separator: " ").map(String.init)
            guard words.count > 1, let family = words.last else {
                return CSLName(family: text)
            }
            return CSLName(family: family, given: words.dropLast().joined(separator: " "))
        }
    }
 
    static func cslReference(for paper: PaperRecord) -> CSLReference {
        let key = paper.citationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var reference = CSLReference(id: key.isEmpty ? paper.id.uuidString : key)
        reference.type = cslType(for: paper.publicationType)
        reference.title = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
        reference.authors = cslNames(from: paper.authors)
        reference.year = paper.year > 0 ? paper.year : nil
        reference.month = paper.month
        reference.volume = paper.volume
        reference.issue = paper.issue
        reference.page = paper.pages
        reference.edition = paper.edition
        reference.doi = paper.doi
        reference.url = paper.urlString
        reference.abstract = paper.abstractText
 
        // For a book the "venue" is the publisher, for everything else it is the container.
        let venue = paper.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        if paper.publicationType == .book {
            reference.publisher = paper.publisher.isEmpty ? venue : paper.publisher
        } else {
            reference.containerTitle = venue
            reference.publisher = paper.publisher
        }
        return reference
    }
 
    /// One formatted bibliography entry, or nil when the style has no bibliography or gives nothing.
    static func cslBibliographyEntry(
        for paper: PaperRecord,
        style: CSLStyle,
        format: CSLOutputFormat = .plain
    ) -> String? {
        firstNonEmpty(CSLEngine(style: style, format: format).bibliography([cslReference(for: paper)]))
    }
 
    static func cslBibliographyEntry(
        for paper: PaperRecord,
        style: CitationStyle,
        format: CSLOutputFormat = .plain
    ) -> String? {
        guard let cslStyle = style.cslStyle else { return nil }
        return cslBibliographyEntry(for: paper, style: cslStyle, format: format)
    }
 
    /// A whole bibliography, sorted the way the style says (entries the style cannot format are left out).
    static func cslBibliography(
        for papers: [PaperRecord],
        style: CSLStyle,
        format: CSLOutputFormat = .plain
    ) -> [String] {
        CSLEngine(style: style, format: format)
            .bibliography(papers.map { cslReference(for: $0) })
            .filter { !$0.isEmpty }
    }
 
    /// The in-text citation for one or more papers, for example "(Vaswani et al., 2017)" or "[1]".
    /// - Parameters:
    ///   - numbers: reference id -> citation number. Needed by numeric styles. When it is
    ///     empty, papers are numbered 1, 2, 3 in the order given.
    ///   - locators: reference id -> page or section, for example "p. 5".
    static func cslInTextCitation(
        for papers: [PaperRecord],
        style: CSLStyle,
        format: CSLOutputFormat = .plain,
        numbers: [String: Int] = [:],
        locators: [String: String] = [:]
    ) -> String {
        let references = papers.map { cslReference(for: $0) }
        return inTextCitation(references, style: style, format: format, numbers: numbers, locators: locators)
    }
 
    // MARK: ModelItem (the SQLite library)
 
    static func cslReference(for item: ModelItem, creators: [ItemCreator]) -> CSLReference {
        CSLReference(item: item, creators: creators)
    }
 
    static func cslBibliographyEntry(
        for item: ModelItem,
        creators: [ItemCreator],
        style: CSLStyle,
        format: CSLOutputFormat = .plain
    ) -> String? {
        firstNonEmpty(CSLEngine(style: style, format: format).bibliography([CSLReference(item: item, creators: creators)]))
    }
 
    static func cslInTextCitation(
        for item: ModelItem,
        creators: [ItemCreator],
        style: CSLStyle,
        format: CSLOutputFormat = .plain,
        number: Int? = nil,
        locator: String = ""
    ) -> String {
        let reference = CSLReference(item: item, creators: creators)
        return inTextCitation(
            [reference], style: style, format: format,
            numbers: [reference.id: number ?? 1],
            locators: locator.isEmpty ? [:] : [reference.id: locator]
        )
    }
 
    // MARK: Shared
 
    private static func inTextCitation(
        _ references: [CSLReference],
        style: CSLStyle,
        format: CSLOutputFormat,
        numbers: [String: Int],
        locators: [String: String]
    ) -> String {
        var numbering = numbers
        if numbering.isEmpty {
            for (index, reference) in references.enumerated() where numbering[reference.id] == nil {
                numbering[reference.id] = index + 1
            }
        }
        let items = references.map { CSLCitationItem($0, locator: locators[$0.id] ?? "") }
        return CSLEngine(style: style, format: format)
            .citation(items, numbers: numbering, allReferences: references)
    }
 
    private static func firstNonEmpty(_ entries: [String]) -> String? {
        entries.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
