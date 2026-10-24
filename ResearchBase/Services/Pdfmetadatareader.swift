//
//  PDFMetadataReader.swift
//  ResearchBase
//
//  Owner: Agent 6 · Features: F-16
//
//  Reads what a PDF says about itself: DOI, arXiv ID, title and authors from
//  page one and from the PDF's own info record. Also says whether the first
//  pages have any text at all (if not, the file is a scan and needs OCR, F-23).
//
//  Never throws, never touches the network, never touches the database.
//  A problem (cannot open, password, no pages) comes back inside the result
//  so the caller can fall back to manual entry. Everything found is a HINT:
//  the caller shows it for the person to confirm.
//
//  PUBLIC API
//    struct PDFMetadata            doi, arxivID, title, authors, year, pageCount,
//                                  needsOCR, problem, hasUsefulResult
//    PDFMetadata.Problem           .cannotOpen / .passwordProtected / .noPages
//    struct PDFInfoRecord          title, author, subject, keywords (the PDF info record)
//    struct PDFTextRun             text + fontSize (used to find the title)
//    enum PDFMetadataReader
//      static func read(url: URL) -> PDFMetadata
//      static func read(document: PDFDocument) -> PDFMetadata
//      static func parse(pageText:runs:info:pageCount:visibleCharacters:) -> PDFMetadata
//      static func extractDOI(from text: String) -> String?          (lower-case, no URL prefix)
//      static func extractArXivID(from text: String) -> String?      (no "arXiv:" and no version)
//      static func cleanedInfoTitle(_ raw: String?) -> String?
//      static func largestFontTitle(from runs: [PDFTextRun]) -> String?
//      static func splitAuthors(_ raw: String?) -> [String]         (names kept as written)
//
//  Threading: all types are nonisolated. read(url:) opens its own PDFDocument,
//  so it is safe to call from a background task. read(document:) must be called
//  on the thread that owns the document.
//
//  TextNormalizer is main-actor isolated, so this file keeps private copies of the
//  three small rules it needs (same results as TextNormalizer.doi / .arxivID /
//  .asciiLettersAndDigits) to stay usable from a background task.
//

import AppKit
import Foundation
import PDFKit

// MARK: - Result

nonisolated struct PDFMetadata: Equatable, Sendable {

    enum Problem: Equatable, Sendable {
        case cannotOpen
        case passwordProtected
        case noPages
    }

    /// Lower-case, no URL prefix (the form the schema wants).
    var doi: String?
    /// Without "arXiv:" and without the version suffix.
    var arxivID: String?
    var title: String?
    /// Names exactly as the PDF wrote them. Not reordered, not verified.
    var authors: [String] = []
    /// Only filled when it can be read from an arXiv ID. Never guessed from file dates.
    var year: Int?
    var pageCount: Int = 0
    /// True when the first pages hold almost no text: a scan. Hand the file to OCR (F-23).
    var needsOCR: Bool = false
    var problem: Problem?

    /// True when there is something worth pre-filling.
    var hasUsefulResult: Bool { doi != nil || arxivID != nil || title != nil }
}

/// The PDF's own info record (Title / Author / Subject / Keywords).
nonisolated struct PDFInfoRecord: Equatable, Sendable {
    var title: String?
    var author: String?
    var subject: String?
    var keywords: [String] = []
}

/// A stretch of page-one text in one font size, in reading order.
nonisolated struct PDFTextRun: Equatable, Sendable {
    var text: String
    var fontSize: Double
}

// MARK: - Reader

nonisolated enum PDFMetadataReader {

    /// Fewer visible characters than this over the first pages means "scanned".
    static let minimumTextCharacters = 50
    /// How many pages are sampled to decide whether the file has a text layer.
    static let ocrSamplePages = 3

    // MARK: Reading a file

    static func read(url: URL) -> PDFMetadata {
        guard let document = PDFDocument(url: url) else {
            var result = PDFMetadata()
            result.problem = .cannotOpen
            return result
        }
        return read(document: document)
    }

    static func read(document: PDFDocument) -> PDFMetadata {
        if document.isLocked {
            var result = PDFMetadata()
            result.problem = .passwordProtected
            return result
        }
        guard document.pageCount > 0, let firstPage = document.page(at: 0) else {
            var result = PDFMetadata()
            result.problem = .noPages
            return result
        }

        let pageText = firstPage.string ?? ""
        let runs = textRuns(from: firstPage.attributedString)

        var visible = visibleCount(pageText)
        var index = 1
        while index < min(document.pageCount, ocrSamplePages) {
            visible += visibleCount(document.page(at: index)?.string ?? "")
            index += 1
        }

        return parse(
            pageText: pageText,
            runs: runs,
            info: infoRecord(from: document),
            pageCount: document.pageCount,
            visibleCharacters: visible
        )
    }

    // MARK: Pure parsing (no PDFKit, easy to test)

    /// - Parameters:
    ///   - pageText: plain text of page one.
    ///   - runs: page-one text with font sizes, in reading order (may be empty).
    ///   - info: the PDF info record.
    ///   - visibleCharacters: non-space characters over the sampled pages;
    ///     when nil, only `pageText` is counted.
    static func parse(
        pageText: String,
        runs: [PDFTextRun],
        info: PDFInfoRecord,
        pageCount: Int,
        visibleCharacters: Int? = nil
    ) -> PDFMetadata {

        var result = PDFMetadata()
        result.pageCount = pageCount
        result.needsOCR = (visibleCharacters ?? visibleCount(pageText)) < minimumTextCharacters

        // Page one first. The info record only fills gaps.
        let infoTexts = ([info.subject] + info.keywords.map { Optional($0) }).compactMap { $0 }

        result.doi = extractDOI(from: pageText)
            ?? infoTexts.lazy.compactMap { extractDOI(from: $0) }.first

        result.arxivID = extractArXivID(from: pageText)
            ?? infoTexts.lazy.compactMap { extractArXivID(from: $0) }.first
        if let id = result.arxivID { result.year = year(fromArXivID: id) }

        // Title: an info title that really appears on page one is the best
        // evidence. Otherwise the biggest type on page one. Otherwise the
        // info title alone. Otherwise nothing: a wrong title is worse than none.
        let infoTitle = cleanedInfoTitle(info.title)
        let pageNorm = lettersAndDigits(pageText)
        if let infoTitle,
           pageNorm.contains(lettersAndDigits(infoTitle)) {
            result.title = infoTitle
        } else if let fromPage = largestFontTitle(from: runs) {
            result.title = fromPage
        } else {
            result.title = infoTitle
        }

        result.authors = splitAuthors(info.author)
        return result
    }

    // MARK: DOI

    private static let doiPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9])10\.\d{4,9}/[^\s"'<>]+"#
    )

    /// First DOI on the text, preferring one written next to the word "DOI" or a doi.org link
    /// (a one-page paper can also list the DOIs of papers it cites).
    static func extractDOI(from text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let matches = doiPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var first: String?
        for match in matches {
            guard let cleaned = cleanDOI(ns.substring(with: match.range)) else { continue }

            let start = max(0, match.range.location - 24)
            let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            if before.lowercased().contains("doi") {
                return normalizedDOI(cleaned)
            }
            if first == nil { first = cleaned }
        }
        return normalizedDOI(first)
    }

    private static func cleanDOI(_ raw: String) -> String? {
        var value = raw
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\u{2019}", "\u{201D}"]

        while let last = value.last {
            if trailing.contains(last) {
                value.removeLast()
            } else if let open = opener(for: last),
                      value.filter({ $0 == open }).count < value.filter({ $0 == last }).count {
                value.removeLast()   // a closing bracket that has no opener inside the DOI
            } else {
                break
            }
        }
        return (value.contains("/") && value.count > 8) ? value : nil
    }

    private static func opener(for closer: Character) -> Character? {
        switch closer {
        case ")": return "("
        case "]": return "["
        case "}": return "{"
        default: return nil
        }
    }

    // MARK: arXiv

    private static let arxivPatterns: [NSRegularExpression] = [
        #"arxiv:\s*(\d{4}\.\d{4,5})(?:v\d+)?"#,
        #"arxiv:\s*([a-z\-]+(?:\.[a-z]{2})?/\d{7})(?:v\d+)?"#,
        #"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})(?:v\d+)?"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func extractArXivID(from text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for pattern in arxivPatterns {
            if let match = pattern.firstMatch(in: text, range: full), match.numberOfRanges > 1 {
                return normalizedArXivID(ns.substring(with: match.range(at: 1)))
            }
        }
        return nil
    }

    /// 2101.12345 -> 2021. hep-th/9901001 -> 1999. Anything out of range -> nil.
    static func year(fromArXivID id: String) -> Int? {
        let digits: String
        if let slash = id.firstIndex(of: "/") {
            digits = String(id[id.index(after: slash)...])      // old style: YYMMNNN
        } else {
            digits = id                                          // new style: YYMM.NNNNN
        }
        guard digits.count >= 4,
              let yy = Int(digits.prefix(2)),
              let mm = Int(digits.dropFirst(2).prefix(2)),
              (1...12).contains(mm) else { return nil }

        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        let year: Int
        if id.contains("/") {
            year = yy >= 91 ? 1900 + yy : 2000 + yy
        } else {
            guard yy >= 7 else { return nil }                    // new-style IDs start in 2007
            year = 2000 + yy
        }
        return year <= thisYear + 1 ? year : nil
    }

    // MARK: Title

    /// The info-record title, or nil when it is empty, a file name, or software boilerplate.
    static func cleanedInfoTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let title = collapseSpaces(raw)
        guard title.count >= 6, title.count <= 300 else { return nil }

        let lower = title.lowercased()
        if lower.hasPrefix("untitled") || lower.hasPrefix("microsoft word") || lower.hasPrefix("microsoft powerpoint") {
            return nil
        }
        if isBoilerplate(lower) { return nil }

        // "final_paper_v3.pdf", "draft.docx"
        let fileLike = #"^[^\s]*\.(pdf|docx?|tex|dvi|ps|rtf|pages|indd|pptx?)$"#
        if lower.range(of: fileLike, options: .regularExpression) != nil { return nil }
        // one long token with underscores is a file name without extension
        if !title.contains(" "), title.contains("_") { return nil }

        return title
    }

    /// The text set in the largest type on page one, when it is clearly bigger than the body text.
    static func largestFontTitle(from runs: [PDFTextRun]) -> String? {
        func bucket(_ size: Double) -> Double { (size * 2).rounded() / 2 }

        // Body size = the size that carries the most characters.
        var charsBySize: [Double: Int] = [:]
        for run in runs {
            charsBySize[bucket(run.fontSize), default: 0] += visibleCount(run.text)
        }
        guard let body = charsBySize.max(by: { $0.value < $1.value })?.key, body > 0 else { return nil }

        // Biggest size that has real words, not a stray symbol.
        let sizes = runs.filter { visibleCount($0.text) >= 3 }.map { bucket($0.fontSize) }
        guard let biggest = sizes.max(), biggest >= body * 1.15 else { return nil }

        // First unbroken stretch at that size (a title may wrap over several lines).
        var parts: [String] = []
        var started = false
        for run in runs {
            let isTitleSize = bucket(run.fontSize) == biggest
            let hasText = visibleCount(run.text) > 0
            if isTitleSize && hasText {
                started = true
                parts.append(run.text)
            } else if started {
                if hasText { break }
                parts.append(run.text)                           // blank run between wrapped lines
            }
        }

        let joined = collapseSpaces(parts.joined().replacingOccurrences(of: "-\n", with: "-"))
        guard joined.count >= 6, joined.count <= 300, !isBoilerplate(joined.lowercased()) else { return nil }
        return joined
    }

    private static let boilerplateExact: Set<String> = [
        "abstract", "article", "research article", "original article", "review article",
        "letter", "preprint", "introduction", "contents", "title", "paper title"
    ]
    private static let boilerplatePrefixes = ["arxiv", "contents lists available", "copyright", "©"]

    private static func isBoilerplate(_ lower: String) -> Bool {
        boilerplateExact.contains(lower) || boilerplatePrefixes.contains { lower.hasPrefix($0) }
    }

    // MARK: Authors

    private static let junkAuthors: Set<String> = [
        "admin", "administrator", "user", "owner", "author", "unknown", "anonymous",
        "windows user", "pc", "default", "root", "guest"
    ]

    /// Splits an Author string on ";" (or on "and", "&" and ","). Names are kept as written:
    /// "Last, First" is not reordered because it cannot be told apart from a list reliably.
    static func splitAuthors(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var text = raw.replacingOccurrences(of: "\n", with: " ")

        let parts: [String]
        if text.contains(";") {
            parts = text.components(separatedBy: ";")
        } else {
            text = text
                .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
                .replacingOccurrences(of: " & ", with: ",")
            parts = text.components(separatedBy: ",")
        }

        var seen = Set<String>()
        var names: [String] = []
        for part in parts {
            let name = collapseSpaces(part)
            guard !name.isEmpty, name.count <= 80,
                  !name.contains("@"),
                  name.rangeOfCharacter(from: .decimalDigits) == nil,
                  !junkAuthors.contains(name.lowercased()) else { continue }
            // a single lower-case word is a user name ("jsmith"), not a person
            if !name.contains(" "), name == name.lowercased() { continue }
            if seen.insert(name.lowercased()).inserted { names.append(name) }
            if names.count >= 50 { break }
        }
        return names
    }

    // MARK: PDFKit adapters

    static func infoRecord(from document: PDFDocument) -> PDFInfoRecord {
        let attributes = document.documentAttributes ?? [:]

        var keywords: [String] = []
        if let list = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            keywords = list
        } else if let single = attributes[PDFDocumentAttribute.keywordsAttribute] as? String {
            keywords = single.components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return PDFInfoRecord(
            title: attributes[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attributes[PDFDocumentAttribute.subjectAttribute] as? String,
            keywords: keywords
        )
    }

    static func textRuns(from attributed: NSAttributedString?) -> [PDFTextRun] {
        guard let attributed, attributed.length > 0 else { return [] }
        var runs: [PDFTextRun] = []
        attributed.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let font = value as? NSFont else { return }
            runs.append(PDFTextRun(
                text: attributed.attributedSubstring(from: range).string,
                fontSize: Double(font.pointSize)
            ))
        }
        return runs
    }

    // MARK: Small helpers

    private static func visibleCount(_ text: String) -> Int {
        text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
    }

    /// Same rule as TextNormalizer.doi: lower-case, no URL prefix, empty is nil.
    private static func normalizedDOI(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
                       "http://dx.doi.org/", "doi.org/", "doi:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Same rule as TextNormalizer.arxivID: no URL or "arXiv:" prefix, empty is nil.
    private static func normalizedArXivID(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let lower = value.lowercased()
        for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "arxiv.org/abs/", "arxiv:"]
        where lower.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Same rule as TextNormalizer.asciiLettersAndDigits.
    private static func lettersAndDigits(_ text: String) -> String {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        return String(folded.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
