//
//  CSVImporter.swift
//  ResearchBase
//
//  Owner: Agent 11 · Features: F-19
//
//  Reads CSV text (a spreadsheet, a Zotero or Mendeley CSV export, or
//  ResearchBase's own papers.csv) and returns a PREVIEW of the items it
//  would create. Nothing is saved here: no database, no files. The caller
//  shows the preview, lets the person untick rows, then saves the chosen
//  `item` values with `ItemStore.create`.
//
//  PUBLIC API
//    struct CSVImportEntry           one parsed row (+ its warnings)
//    struct CSVImportResult          entries, skipped rows, column report, summary
//    enum   CSVImporter
//      static func parse(_ text: String, reviewState: ReviewState = .inbox) -> CSVImportResult
//      static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> CSVImportResult
//
//  Rules
//    - Never throws on bad content; a bad row becomes a `skipped` line.
//    - Delimiter is found from the header row: comma, semicolon or tab.
//    - Quotes, doubled quotes, line breaks inside quotes and a byte-order mark work.
//    - Columns are matched by name, ignoring case, spaces and punctuation
//      ("Publication Title", "publication_title" and "PublicationTitle" are the same).
//      Columns that are not recognised are listed in `ignoredColumns`.
//    - A leading apostrophe that ResearchBase's own export adds in front of
//      "=", "+", "-" or "@" (formula protection) is removed again.
//    - Authors may be separated by ";", " and ", line breaks, or commas
//      ("Family, Given" or "Given Family, Given Family").
//    - Items are made with sourceKind .import and the given review state.
//

import Foundation

// MARK: - Result types

struct CSVImportEntry {
    /// Row number in the file, counting the header as row 1 (matches a spreadsheet).
    let row: Int
    /// Ready for `ItemStore.create`.
    let item: NewItem
    /// Things the person should look at before saving.
    let warnings: [String]
}

struct CSVImportResult {
    var entries: [CSVImportEntry] = []
    /// Rows (or the whole file) that could not be read, each with a short reason.
    var skipped: [String] = []
    /// Header names that were used.
    var recognisedColumns: [String] = []
    /// Header names that were not used (tags, ratings, dates added ...).
    var ignoredColumns: [String] = []

    var entryCount: Int { entries.count }
    var warningCount: Int { entries.reduce(0) { $0 + $1.warnings.count } }

    /// One line for the preview header, e.g. "12 entries, 2 with warnings, 1 skipped".
    var summary: String {
        var parts = ["\(entryCount) \(entryCount == 1 ? "entry" : "entries")"]
        let withWarnings = entries.filter { !$0.warnings.isEmpty }.count
        if withWarnings > 0 { parts.append("\(withWarnings) with warnings") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Importer

enum CSVImporter {

    static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> CSVImportResult {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parse(text, reviewState: reviewState)
    }

    static func parse(_ text: String, reviewState: ReviewState = .inbox) -> CSVImportResult {
        var result = CSVImportResult()

        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }

        let delimiter = rbA11_delimiter(body)
        let (rows, unclosed) = rbA11_rows(body, delimiter: delimiter)
        if unclosed { result.skipped.append("A quoted value is never closed; the end of the file was read as part of it.") }

        guard let header = rows.first else { return result }
        let columns = rbA11_columns(header)

        guard columns[.title] != nil else {
            result.skipped.append("No title column was found. Name one column \"Title\".")
            result.ignoredColumns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return result
        }

        let used = Set(columns.values)
        for (i, name) in header.enumerated() {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.isEmpty { continue }
            if used.contains(i) { result.recognisedColumns.append(n) } else { result.ignoredColumns.append(n) }
        }

        for (offset, cells) in rows.dropFirst().enumerated() {
            let rowNumber = offset + 2
            if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            if let entry = rbA11_makeEntry(row: rowNumber, cells: cells, columns: columns,
                                           headerCount: header.count, reviewState: reviewState) {
                result.entries.append(entry)
            } else {
                result.skipped.append("Row \(rowNumber) has no title and was skipped.")
            }
        }
        return result
    }
}

// MARK: - Reading CSV (private)

/// Picks the delimiter that appears most in the first line (outside quotes).
private func rbA11_delimiter(_ text: String) -> Character {
    var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
    var inQuotes = false
    for ch in text {
        if ch == "\"" { inQuotes.toggle(); continue }
        if !inQuotes, ch == "\n" || ch == "\r" || ch == "\r\n" { break }
        if !inQuotes, counts[ch] != nil { counts[ch]! += 1 }
    }
    let best = counts.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }
    guard let best, best.value > 0 else { return "," }
    return best.key
}

/// Splits CSV text into rows of cells. Returns true as the second value
/// when a quote was still open at the end.
private func rbA11_rows(_ text: String, delimiter: Character) -> ([[String]], Bool) {
    var rows: [[String]] = []
    var row: [String] = []
    var cell = ""
    var inQuotes = false
    var wasQuoted = false

    func endCell() { row.append(cell); cell = ""; wasQuoted = false }
    func endRow() { endCell(); rows.append(row); row = [] }

    let chars = Array(text)
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if inQuotes {
            if ch == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                else { inQuotes = false }
            } else {
                cell.append(ch)
            }
        } else if ch == "\"" && (cell.isEmpty || !wasQuoted) && cell.trimmingCharacters(in: .whitespaces).isEmpty {
            inQuotes = true
            wasQuoted = true
            cell = ""
        } else if ch == delimiter {
            endCell()
        } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
            endRow()
        } else {
            cell.append(ch)
        }
        i += 1
    }
    if !cell.isEmpty || !row.isEmpty { endRow() }
    return (rows, inQuotes)
}

// MARK: - Column matching (private)

private enum rbA11_Field: Hashable {
    case title, authors, editors, year, type, venue, publisher, volume, issue
    case pages, doi, url, abstract, arxiv
}

/// Aliases in priority order. Compared after `rbA11_key`.
private let rbA11_aliases: [(rbA11_Field, [String])] = [
    (.title, ["title", "papertitle", "articletitle", "documenttitle", "name"]),
    (.authors, ["authors", "author", "creators", "authorsnames"]),
    (.editors, ["editors", "editor"]),
    (.year, ["year", "publicationyear", "yearpublished", "pubyear", "issued", "date", "publicationdate"]),
    (.type, ["publicationtype", "itemtype", "type", "documenttype", "entrytype", "referencetype"]),
    (.venue, ["venue", "journal", "publicationtitle", "journaltitle", "sourcetitle", "source", "booktitle", "proceedingstitle", "containertitle"]),
    (.publisher, ["publisher", "institution", "school", "university"]),
    (.volume, ["volume"]),
    (.issue, ["issue", "number"]),
    (.pages, ["pages", "page", "pagerange"]),
    (.doi, ["doi"]),
    (.url, ["url", "link", "website", "weblink"]),
    (.abstract, ["abstract", "abstractnote", "summary"]),
    (.arxiv, ["arxivid", "arxiv", "eprint"])
]

/// "Publication Title" / "publication_title" -> "publicationtitle"
private func rbA11_key(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
}

private func rbA11_columns(_ header: [String]) -> [rbA11_Field: Int] {
    let keys = header.map(rbA11_key)
    var map: [rbA11_Field: Int] = [:]
    for (field, aliases) in rbA11_aliases {
        for alias in aliases {
            if let index = keys.firstIndex(of: alias), !map.values.contains(index) {
                map[field] = index
                break
            }
        }
    }
    return map
}

// MARK: - Cell cleaning and names (private)

private func rbA11_clean(_ text: String) -> String {
    var t = text
    // Undo ResearchBase's own formula protection ("'=SUM" was written for "=SUM").
    if t.hasPrefix("'"), let second = t.dropFirst().first, "=+-@\t\r".contains(second) {
        t.removeFirst()
    }
    return t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func rbA11_firstYear(_ text: String) -> Int? {
    var run = ""
    for c in text + " " {
        if c.isASCII, c.isNumber { run.append(c) }
        else {
            if run.count == 4, let y = Int(run) { return y }
            run = ""
        }
    }
    return nil
}

private func rbA11_wordCount(_ s: String) -> Int {
    s.split(separator: " ").count
}

private func rbA11_person(_ raw: String, role: CreatorRole) -> CreatorInput? {
    let name = rbA11_clean(raw)
    guard !name.isEmpty else { return nil }
    let lower = name.lowercased()
    if lower == "others" || lower == "et al." || lower == "et al" { return nil }

    if let comma = name.firstIndex(of: ",") {
        let family = name[..<comma].trimmingCharacters(in: .whitespaces)
        let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        if !family.isEmpty { return CreatorInput(family: family, given: given, role: role) }
    }
    let words = name.split(separator: " ").map(String.init)
    if words.count == 1 { return CreatorInput(family: words[0], role: role) }
    return CreatorInput(family: words.last ?? name,
                        given: words.dropLast().joined(separator: " "), role: role)
}

/// Returns the people and whether the comma-separated list was ambiguous.
private func rbA11_people(_ raw: String, role: CreatorRole) -> ([CreatorInput], Bool) {
    let text = raw.replacingOccurrences(of: "\r\n", with: ";")
        .replacingOccurrences(of: "\n", with: ";")
        .replacingOccurrences(of: "\r", with: ";")
    var names: [String]
    var ambiguous = false

    if text.contains(";") {
        names = text.components(separatedBy: ";")
    } else if text.contains(" and ") {
        names = text.components(separatedBy: " and ")
    } else {
        let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count <= 1 {
            names = [text]
        } else if parts.count == 2 {
            // "Smith, Jane" is one person; "Jane Smith, John Doe" is two.
            names = (rbA11_wordCount(parts[0]) >= 2 && rbA11_wordCount(parts[1]) >= 2) ? parts : [text]
        } else if parts.allSatisfy({ rbA11_wordCount($0) >= 2 }) {
            names = parts
        } else {
            names = parts
            ambiguous = true
        }
    }
    return (names.compactMap { rbA11_person($0, role: role) }, ambiguous)
}

// MARK: - Building an item (private)

private func rbA11_type(_ raw: String) -> ItemType? {
    switch rbA11_key(raw) {
    case "journalarticle", "article", "journal", "magazinearticle", "newspaperarticle", "jour": return .article
    case "preprint", "unpublished", "workingpaper": return .preprint
    case "conferencepaper", "conference", "workshoppaper", "proceedingspaper", "inproceedings", "cpaper": return .conference
    case "book", "edited book", "editedbook": return .book
    case "bookchapter", "booksection", "chapter", "incollection", "inbook": return .chapter
    case "thesis", "phdthesis", "mastersthesis", "dissertation": return .thesis
    case "technicalreport", "report", "techreport": return .report
    case "website", "webpage", "webpagearticle", "online", "electronic", "web": return .webpage
    case "dataset", "data": return .dataset
    case "software", "computerprogram", "code": return .software
    default: return nil
    }
}

private func rbA11_makeEntry(row: Int, cells: [String], columns: [rbA11_Field: Int],
                             headerCount: Int, reviewState: ReviewState) -> CSVImportEntry? {

    func cell(_ field: rbA11_Field) -> String {
        guard let i = columns[field], i < cells.count else { return "" }
        return cells[i]
    }
    func text(_ field: rbA11_Field) -> String { rbA11_clean(cell(field)) }

    let title = text(.title)
    guard !title.isEmpty else { return nil }

    var warnings: [String] = []
    if cells.count > headerCount {
        warnings.append("This row has \(cells.count - headerCount) more cell(s) than the header; the extra cells were ignored.")
    }

    // People
    var creators: [CreatorInput] = []
    let (authors, ambiguous) = rbA11_people(cell(.authors), role: .author)
    creators += authors
    if ambiguous { warnings.append("The author list could not be split with certainty; check the names.") }
    creators += rbA11_people(cell(.editors), role: .editor).0
    if authors.isEmpty { warnings.append("No authors were found.") }

    // Year
    var year: Int?
    let yearText = text(.year)
    if yearText.isEmpty { warnings.append("No year was found.") }
    else if let y = rbA11_firstYear(yearText) { year = y }
    else { warnings.append("Year \"\(yearText)\" was not understood and was left empty.") }

    // Identifiers
    let doi = TextNormalizer.doi(text(.doi))
    var arxiv = TextNormalizer.arxivID(text(.arxiv))
    let url = text(.url)
    if arxiv == nil, url.lowercased().contains("arxiv.org/abs/") { arxiv = TextNormalizer.arxivID(url) }

    // Type
    let typeText = text(.type)
    var type: ItemType = arxiv != nil ? .preprint : .article
    if !typeText.isEmpty {
        if let t = rbA11_type(typeText) { type = t }
        else { warnings.append("Type \"\(typeText)\" was not recognised; imported as \(type.displayName.lowercased()).") }
    }

    if type == .article, text(.venue).isEmpty { warnings.append("No journal name was found.") }
    if doi == nil && arxiv == nil && type != .book && type != .webpage {
        warnings.append("No DOI or arXiv ID; duplicates cannot be matched by identifier.")
    }

    var item = NewItem(title: title)
    item.type = type
    item.creators = creators
    item.year = year
    item.venue = text(.venue)
    item.abstract = text(.abstract)
    item.volume = text(.volume)
    item.issue = text(.issue)
    item.pages = text(.pages).replacingOccurrences(of: "--", with: "–")
    item.publisher = text(.publisher)
    item.doi = doi
    item.arxivID = arxiv
    item.url = url
    item.sourceKind = .import
    item.sourceURL = ""
    item.reviewState = reviewState

    return CSVImportEntry(row: row, item: item, warnings: warnings)
}
