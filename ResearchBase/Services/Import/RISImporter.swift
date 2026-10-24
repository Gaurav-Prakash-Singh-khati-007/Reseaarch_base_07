//
//  RISImporter.swift
//  ResearchBase
//
//  Owner: Agent 10 · Features: F-19
//
//  Reads RIS text (EndNote, Mendeley, Zotero, publisher "export citation")
//  and returns a PREVIEW of the items it would create. Nothing is saved
//  here: no database, no files. The caller shows the preview, lets the
//  person untick entries, then saves the chosen `item` values with
//  `ItemStore.create`.
//
//  PUBLIC API
//    struct RISImportEntry           one parsed record (+ its warnings)
//    struct RISImportResult          entries, skipped records, counts, summary
//    enum   RISImporter
//      static func parse(_ text: String, reviewState: ReviewState = .inbox) -> RISImportResult
//      static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> RISImportResult
//
//  Rules
//    - Never throws on bad content; a broken record becomes a `skipped` line.
//    - A record runs from "TY  - " to "ER  - ". A record with no ER line at
//      the end of the file is still read, with a warning.
//    - Lines that do not start with a tag continue the previous value.
//    - Names: "Family, Given" (and "Family, Given, Suffix"). With no comma,
//      several words are read as "Given Family"; one word is a family name.
//    - Items are made with sourceKind .import and the given review state.
//    - Fields with no column in the schema (keywords, ISSN, notes ...) are not stored.
//

import Foundation

// MARK: - Result types

struct RISImportEntry {
    /// 1-based position of the record in the file, for messages.
    let index: Int
    /// The RIS type code as written, upper-cased (e.g. "JOUR").
    let risType: String
    /// The ID tag of the record, if it had one (the library makes its own key).
    let originalID: String
    /// Ready for `ItemStore.create`.
    let item: NewItem
    /// Things the person should look at before saving.
    let warnings: [String]
}

struct RISImportResult {
    var entries: [RISImportEntry] = []
    /// Records that could not be read, each with a short reason.
    var skipped: [String] = []

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

enum RISImporter {

    static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> RISImportResult {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parse(text, reviewState: reviewState)
    }

    static func parse(_ text: String, reviewState: ReviewState = .inbox) -> RISImportResult {
        var result = RISImportResult()
        var records: [rbA10_Record] = []
        var current: rbA10_Record?
        var lastTag: String?
        var lineNumber = 0

        // Normalise line endings and drop a byte-order mark.
        var cleaned = text
        if cleaned.hasPrefix("\u{FEFF}") { cleaned.removeFirst() }
        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let text = String(line)

            if let (tag, value) = rbA10_splitLine(text) {
                if tag == "TY" {
                    if let open = current {
                        // TY with no ER before it: keep what we have.
                        var r = open
                        r.missingEnd = true
                        records.append(r)
                    }
                    current = rbA10_Record(type: value.uppercased(), line: lineNumber)
                    lastTag = nil
                } else if tag == "ER" {
                    if let open = current { records.append(open) }
                    current = nil
                    lastTag = nil
                } else if current != nil {
                    current?.add(tag, value)
                    lastTag = tag
                }
            } else if current != nil, let tag = lastTag {
                let extra = text.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty { current?.append(to: tag, extra) }
            }
        }
        if var open = current {
            open.missingEnd = true
            records.append(open)
        }

        var index = 0
        for record in records {
            index += 1
            if let entry = rbA10_makeEntry(index: index, record: record, reviewState: reviewState) {
                result.entries.append(entry)
            } else {
                result.skipped.append("Record \(index) (line \(record.line)) has no title and was skipped.")
            }
        }
        return result
    }
}

// MARK: - Reading lines (private)

private struct rbA10_Record {
    let type: String
    let line: Int
    var missingEnd = false
    /// Values per tag, in file order.
    var values: [String: [String]] = [:]

    init(type: String, line: Int) {
        self.type = type
        self.line = line
    }

    mutating func add(_ tag: String, _ value: String) {
        values[tag, default: []].append(value)
    }

    /// Adds a continuation line to the last value of a tag.
    mutating func append(to tag: String, _ extra: String) {
        guard var list = values[tag], !list.isEmpty else { return }
        list[list.count - 1] += " " + extra
        values[tag] = list
    }

    func first(_ tags: String...) -> String? {
        for tag in tags {
            if let v = values[tag]?.first(where: { !$0.isEmpty }) { return v }
        }
        return nil
    }

    func all(_ tags: String...) -> [String] {
        tags.flatMap { values[$0] ?? [] }.filter { !$0.isEmpty }
    }
}

/// "TY  - JOUR" -> ("TY", "JOUR"). Tag is two characters (letter + letter/digit).
/// Also accepts "TY - JOUR" and "TY  -JOUR". Returns nil for any other line.
private func rbA10_splitLine(_ line: String) -> (String, String)? {
    let chars = Array(line)
    guard chars.count >= 4 else { return nil }
    let t1 = chars[0], t2 = chars[1]
    guard t1.isASCII, t1.isUppercase, t2.isASCII, t2.isUppercase || t2.isNumber else { return nil }
    var i = 2
    while i < chars.count, chars[i] == " " { i += 1 }
    guard i < chars.count, chars[i] == "-", i >= 3 || chars.count == 2 || i > 2 else { return nil }
    i += 1
    let value = String(chars[i...]).trimmingCharacters(in: .whitespaces)
    return (String([t1, t2]), value)
}

// MARK: - Cleaning and names (private)

private func rbA10_clean(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private let rbA10_suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]

private func rbA10_creator(_ raw: String, role: CreatorRole) -> CreatorInput? {
    let name = rbA10_clean(raw)
    guard !name.isEmpty else { return nil }
    if name.lowercased() == "others" || name.lowercased() == "et al." || name.lowercased() == "et al" { return nil }

    let parts = name.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    if parts.count >= 3 {
        // Family, Given, Suffix  (RIS order)
        return CreatorInput(family: parts[0], given: parts[1], suffix: parts[2], role: role)
    }
    if parts.count == 2 {
        if rbA10_suffixes.contains(parts[1].lowercased()) {
            return CreatorInput(family: parts[0], suffix: parts[1], role: role)
        }
        return CreatorInput(family: parts[0], given: parts[1], role: role)
    }
    let words = name.split(separator: " ").map(String.init)
    if words.count == 1 { return CreatorInput(family: words[0], role: role) }
    return CreatorInput(family: words.last ?? name,
                        given: words.dropLast().joined(separator: " "), role: role)
}

private func rbA10_creators(_ raws: [String], role: CreatorRole) -> [CreatorInput] {
    raws.compactMap { rbA10_creator($0, role: role) }
}

// MARK: - Building an item (private)

private func rbA10_itemType(_ code: String, hasArxiv: Bool) -> ItemType {
    switch code {
    case "JOUR", "JFULL", "MGZN", "NEWS", "EJOUR", "ABST": return .article
    case "CONF", "CPAPER", "CONFPRO": return .conference
    case "BOOK", "EBOOK", "EDBOOK", "SER": return .book
    case "CHAP", "ECHAP": return .chapter
    case "THES": return .thesis
    case "RPRT": return .report
    case "ELEC", "WEB", "BLOG", "ICOMM": return .webpage
    case "DATA": return .dataset
    case "COMP": return .software
    case "UNPB", "GEN", "INPR", "PAMP": return hasArxiv ? .preprint : (code == "UNPB" || code == "INPR" ? .preprint : .article)
    default: return hasArxiv ? .preprint : .article
    }
}

private func rbA10_firstYear(_ text: String) -> Int? {
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

private func rbA10_makeEntry(index: Int, record r: rbA10_Record, reviewState: ReviewState) -> RISImportEntry? {

    guard let rawTitle = r.first("TI", "T1", "CT"), !rbA10_clean(rawTitle).isEmpty else { return nil }
    let title = rbA10_clean(rawTitle)

    var warnings: [String] = []
    if r.missingEnd { warnings.append("This record has no \"ER\" end line; it was read up to the next record or the end of the file.") }

    // Identifiers
    var doi = TextNormalizer.doi(r.first("DO"))
    let urlRaw = r.first("UR", "L2") ?? ""
    if doi == nil {
        if let m = r.first("M3"), m.lowercased().hasPrefix("10.") || m.lowercased().contains("doi") { doi = TextNormalizer.doi(m) }
        else if urlRaw.lowercased().contains("doi.org/") { doi = TextNormalizer.doi(urlRaw) }
    }
    var arxiv: String?
    if urlRaw.lowercased().contains("arxiv.org/abs/") { arxiv = TextNormalizer.arxivID(urlRaw) }
    if arxiv == nil, let d = doi, d.hasPrefix("10.48550/arxiv.") {
        arxiv = String(d.dropFirst("10.48550/arxiv.".count))
    }
    let type = rbA10_itemType(r.type, hasArxiv: arxiv != nil)

    // Creators: authors, then editors, then translators.
    var creators = rbA10_creators(r.all("AU", "A1"), role: .author)
    creators += rbA10_creators(r.all("A2", "ED"), role: .editor)
    creators += rbA10_creators(r.all("A4"), role: .translator)
    if creators.isEmpty { warnings.append("No authors were found.") }

    // Year: PY / Y1 / DA, "2020/05/12/" or "2020".
    var year: Int?
    if let py = r.first("PY", "Y1", "DA", "Y2") {
        year = rbA10_firstYear(py)
        if year == nil { warnings.append("Year \"\(py)\" was not understood and was left empty.") }
    } else {
        warnings.append("No year was found.")
    }

    // Venue: T2 is the container (journal, proceedings, book title); JO/JF/JA are journal names.
    var venue = ""
    switch type {
    case .article, .preprint: venue = r.first("JO", "JF", "T2", "J2", "JA") ?? ""
    case .conference, .chapter: venue = r.first("T2", "BT", "JO", "JF") ?? ""
    default: venue = r.first("T2", "JO", "JF") ?? ""
    }
    if type == .article, venue.isEmpty { warnings.append("No journal name was found.") }

    // Pages: SP and EP, or a whole range in SP.
    var pages = ""
    if let sp = r.first("SP") {
        if let ep = r.first("EP"), !ep.isEmpty, ep != sp, !sp.contains("-"), !sp.contains("–") {
            pages = "\(sp)–\(ep)"
        } else {
            pages = sp.replacingOccurrences(of: "--", with: "–")
        }
    }

    var url = urlRaw
    if url.lowercased().contains("doi.org/") && doi != nil && r.all("UR").count > 1 {
        url = r.all("UR").first { !$0.lowercased().contains("doi.org/") } ?? urlRaw
    }

    if doi == nil && arxiv == nil && type != .book && type != .webpage {
        warnings.append("No DOI or arXiv ID; duplicates cannot be matched by identifier.")
    }

    var item = NewItem(title: title)
    item.type = type
    item.creators = creators
    item.year = year
    item.venue = rbA10_clean(venue)
    item.abstract = rbA10_clean(r.first("AB", "N2") ?? "")
    item.volume = rbA10_clean(r.first("VL") ?? "")
    item.issue = rbA10_clean(r.first("IS", "CP") ?? "")
    item.pages = pages
    item.publisher = rbA10_clean(r.first("PB") ?? "")
    item.doi = doi
    item.arxivID = arxiv
    item.url = url
    item.sourceKind = .import
    item.sourceURL = ""
    item.reviewState = reviewState

    return RISImportEntry(index: index, risType: r.type, originalID: r.first("ID") ?? "",
                          item: item, warnings: warnings)
}
