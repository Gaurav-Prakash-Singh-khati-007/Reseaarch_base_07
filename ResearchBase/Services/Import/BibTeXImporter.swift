//
//  BibTeXImporter.swift
//  ResearchBase
//
//  Owner: Agent 9 · Features: F-19
//
//  Reads BibTeX text and returns a PREVIEW of the items it would create.
//  Nothing is saved here: no database, no files. The caller shows the
//  preview, lets the person untick entries, then saves the chosen
//  `item` values with `ItemStore.create`.
//
//  PUBLIC API
//    struct BibTeXImportEntry        one parsed entry (+ its warnings)
//    struct BibTeXImportResult       entries, skipped blocks, counts
//    enum   BibTeXImporter
//      static func parse(_ text: String, reviewState: ReviewState = .inbox) -> BibTeXImportResult
//      static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> BibTeXImportResult
//
//  Rules
//    - Never throws on bad content; a broken entry becomes a `skipped` line.
//    - Handles {braced} and "quoted" values, # concatenation, @string macros,
//      @comment / @preamble (ignored), month macros, nested braces.
//    - LaTeX accents ({\"u}, \'e, \c{c}, ...) become real characters.
//    - Authors split on "and"; "Family, Given" and "Given Family" both work;
//      {Braced Name} is kept whole as an organisation.
//    - Items are made with sourceKind .import and the given review state.
//    - Fields with no column in the schema (note, keywords, ...) are not stored.
//

import Foundation

// MARK: - Result types

struct BibTeXImportEntry {
    /// 1-based position of the entry in the file, for messages.
    let index: Int
    /// The key as written in the .bib file (the library makes its own key).
    let originalKey: String
    /// The BibTeX entry type as written, lower-cased (e.g. "inproceedings").
    let bibType: String
    /// Ready for `ItemStore.create`.
    let item: NewItem
    /// Things the person should look at before saving.
    let warnings: [String]
}

struct BibTeXImportResult {
    var entries: [BibTeXImportEntry] = []
    /// Blocks that could not be read, each with a short reason.
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

enum BibTeXImporter {

    static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> BibTeXImportResult {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return parse(text, reviewState: reviewState)
    }

    static func parse(_ text: String, reviewState: ReviewState = .inbox) -> BibTeXImportResult {
        var reader = rbA9_Reader(Array(text.unicodeScalars))
        var result = BibTeXImportResult()
        var macros = rbA9_defaultMacros
        var index = 0

        while let block = reader.nextBlock() {
            switch block {
            case .skipped(let reason):
                result.skipped.append(reason)
            case .string(let name, let value):
                macros[name.lowercased()] = rbA9_expand(value, macros: macros)
            case .entry(let type, let key, let fields):
                index += 1
                let flat = fields.map { ($0.name, rbA9_expand($0.value, macros: macros)) }
                if let entry = rbA9_makeEntry(index: index, type: type, key: key,
                                              fields: flat, reviewState: reviewState) {
                    result.entries.append(entry)
                } else {
                    result.skipped.append("Entry \"\(key)\" has no title and was skipped.")
                }
            }
        }
        return result
    }
}

// MARK: - Tokenising (private)

private enum rbA9_Piece: Equatable {
    case literal(String)     // {...} or "..." or a number
    case macro(String)       // bare word, looked up in @string
}

private struct rbA9_Field {
    let name: String
    let value: [rbA9_Piece]
}

private enum rbA9_Block {
    case entry(type: String, key: String, fields: [rbA9_Field])
    case string(name: String, value: [rbA9_Piece])
    case skipped(String)
}

private let rbA9_defaultMacros: [String: String] = [
    "jan": "January", "feb": "February", "mar": "March", "apr": "April",
    "may": "May", "jun": "June", "jul": "July", "aug": "August",
    "sep": "September", "oct": "October", "nov": "November", "dec": "December"
]

private struct rbA9_Reader {
    let s: [Unicode.Scalar]
    var i = 0

    init(_ scalars: [Unicode.Scalar]) { s = scalars }

    private var atEnd: Bool { i >= s.count }
    private func peek() -> Unicode.Scalar? { i < s.count ? s[i] : nil }
    private func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }

    private mutating func skipSpace() {
        while let c = peek(), isSpace(c) { i += 1 }
    }

    /// Finds the next "@" and reads one block. Text between blocks is ignored.
    mutating func nextBlock() -> rbA9_Block? {
        while let c = peek(), c != "@" { i += 1 }
        guard !atEnd else { return nil }
        i += 1 // @
        skipSpace()

        var type = ""
        while let c = peek(), c.properties.isAlphabetic || c == "_" || c == "-" {
            type.unicodeScalars.append(c); i += 1
        }
        type = type.lowercased()
        skipSpace()

        guard let open = peek(), open == "{" || open == "(" else {
            return .skipped("An \"@\" was not followed by an entry (near character \(i)).")
        }
        let close: Unicode.Scalar = open == "{" ? "}" : ")"
        let bodyStart = i + 1
        guard let bodyEnd = findClose(from: i, open: open, close: close) else {
            i = s.count
            return .skipped("The \(type.isEmpty ? "last" : "@" + type) block is not closed.")
        }
        let body = Array(s[bodyStart..<bodyEnd])
        i = bodyEnd + 1

        switch type {
        case "comment", "preamble":
            return nextBlock()
        case "string":
            var inner = rbA9_Reader(body)
            guard let field = inner.readField() else {
                return .skipped("An @string definition could not be read.")
            }
            return .string(name: field.name, value: field.value)
        default:
            var inner = rbA9_Reader(body)
            let key = inner.readKey()
            var fields: [rbA9_Field] = []
            while let f = inner.readField() { fields.append(f) }
            return .entry(type: type, key: key, fields: fields)
        }
    }

    /// Index of the matching close, honouring nested braces and quotes-in-braces.
    private func findClose(from start: Int, open: Unicode.Scalar, close: Unicode.Scalar) -> Int? {
        var depth = 0
        var j = start
        while j < s.count {
            let c = s[j]
            if c == "\\" { j += 2; continue }
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    private mutating func readKey() -> String {
        skipSpace()
        var key = ""
        while let c = peek(), c != "," {
            key.unicodeScalars.append(c); i += 1
        }
        if peek() == "," { i += 1 }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func readField() -> rbA9_Field? {
        skipSpace()
        while peek() == "," { i += 1; skipSpace() }
        guard !atEnd else { return nil }

        var name = ""
        while let c = peek(), c != "=", c != "," {
            name.unicodeScalars.append(c); i += 1
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard peek() == "=", !name.isEmpty else {
            // A stray word with no "=": skip it.
            return i < s.count ? readField() : nil
        }
        i += 1 // =
        var pieces: [rbA9_Piece] = []
        while true {
            skipSpace()
            guard let c = peek() else { break }
            if c == "{" {
                guard let end = findClose(from: i, open: "{", close: "}") else {
                    pieces.append(.literal(String(String.UnicodeScalarView(s[(i + 1)...]))))
                    i = s.count
                    break
                }
                pieces.append(.literal(String(String.UnicodeScalarView(s[(i + 1)..<end]))))
                i = end + 1
            } else if c == "\"" {
                var j = i + 1, depth = 0
                while j < s.count {
                    if s[j] == "\\" { j += 2; continue }
                    if s[j] == "{" { depth += 1 }
                    else if s[j] == "}" { depth -= 1 }
                    else if s[j] == "\"" && depth == 0 { break }
                    j += 1
                }
                let end = min(j, s.count)
                pieces.append(.literal(String(String.UnicodeScalarView(s[(i + 1)..<end]))))
                i = min(end + 1, s.count)
            } else {
                var word = ""
                while let w = peek(), w != ",", w != "#", !isSpace(w) {
                    word.unicodeScalars.append(w); i += 1
                }
                if word.isEmpty { break }
                if word.unicodeScalars.allSatisfy({ $0.properties.numericType != nil }) {
                    pieces.append(.literal(word))
                } else {
                    pieces.append(.macro(word.lowercased()))
                }
            }
            skipSpace()
            if peek() == "#" { i += 1; continue }
            break
        }
        skipSpace()
        if peek() == "," { i += 1 }
        return rbA9_Field(name: name, value: pieces)
    }
}

private func rbA9_expand(_ pieces: [rbA9_Piece], macros: [String: String]) -> String {
    pieces.map { piece -> String in
        switch piece {
        case .literal(let t): return t
        case .macro(let name): return macros[name] ?? name
        }
    }.joined()
}

// MARK: - Cleaning text (private)

private let rbA9_accentCommands: [Character: Unicode.Scalar] = [
    "`": "\u{0300}", "'": "\u{0301}", "^": "\u{0302}", "~": "\u{0303}",
    "=": "\u{0304}", "u": "\u{0306}", ".": "\u{0307}", "\"": "\u{0308}",
    "r": "\u{030A}", "H": "\u{030B}", "v": "\u{030C}", "c": "\u{0327}",
    "k": "\u{0328}", "d": "\u{0323}", "b": "\u{0331}"
]

private let rbA9_specialLetters: [String: String] = [
    "ss": "ß", "o": "ø", "O": "Ø", "l": "ł", "L": "Ł", "ae": "æ", "AE": "Æ",
    "oe": "œ", "OE": "Œ", "aa": "å", "AA": "Å", "i": "i", "j": "j",
    "textendash": "–", "textemdash": "—", "&": "&", "%": "%", "$": "$",
    "_": "_", "#": "#", "textquoteright": "’", "textquoteleft": "‘"
]

/// Removes braces and turns LaTeX accents into characters. Keeps the words.
private func rbA9_clean(_ raw: String) -> String {
    let chars = Array(raw)
    var out = ""
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count {
            let n = chars[i + 1]
            if let mark = rbA9_accentCommands[n], !n.isLetter {
                // \"u  \"{u}  \'{e}
                var j = i + 2
                while j < chars.count, chars[j] == " " { j += 1 }
                var base: String?
                if j < chars.count, chars[j] == "{" {
                    var k = j + 1
                    var inner = ""
                    while k < chars.count, chars[k] != "}" { inner.append(chars[k]); k += 1 }
                    base = inner.replacingOccurrences(of: "\\", with: "")
                    i = k + 1
                } else if j < chars.count {
                    if chars[j] == "\\" , j + 1 < chars.count, chars[j + 1] == "i" || chars[j + 1] == "j" {
                        base = String(chars[j + 1]); i = j + 2
                    } else {
                        base = String(chars[j]); i = j + 1
                    }
                }
                if let base, let first = base.first {
                    out += (String(first) + String(mark)).precomposedStringWithCanonicalMapping
                    out += base.dropFirst()
                    continue
                }
                i += 2
                continue
            }
            if n.isLetter {
                // letter command: \c{c}, \ss, \o, \textendash
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
                if name.count == 1, let mark = rbA9_accentCommands[Character(name)] {
                    var k = j
                    while k < chars.count, chars[k] == " " { k += 1 }
                    if k < chars.count, chars[k] == "{" {
                        var m = k + 1
                        var inner = ""
                        while m < chars.count, chars[m] != "}" { inner.append(chars[m]); m += 1 }
                        if let first = inner.first {
                            out += (String(first) + String(mark)).precomposedStringWithCanonicalMapping
                            out += inner.dropFirst()
                        }
                        i = m + 1
                        continue
                    } else if k < chars.count {
                        out += (String(chars[k]) + String(mark)).precomposedStringWithCanonicalMapping
                        i = k + 1
                        continue
                    }
                }
                if let rep = rbA9_specialLetters[name] {
                    out += rep
                    i = j
                    if i < chars.count, chars[i] == " " { i += 1 }   // command swallows one space
                    continue
                }
                // Unknown command (\emph, \textbf, \url ...): drop the command, keep its argument.
                i = j
                if i < chars.count, chars[i] == " " { i += 1 }
                continue
            }
            // \& \% \_ \# \$ \{ \}
            out.append(n)
            i += 2
            continue
        }
        if c == "{" || c == "}" { i += 1; continue }
        if c == "~" { out.append(" "); i += 1; continue }
        if c == "-", i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] == "-" {
            out.append("—"); i += 3; continue
        }
        if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
            out.append("–"); i += 2; continue
        }
        out.append(c)
        i += 1
    }
    return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

// MARK: - Authors (private)

private let rbA9_particles: Set<String> = [
    "van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "la", "le",
    "ten", "ter", "zu", "dos", "das", "do", "bin", "ibn", "al", "el", "st", "mac"
]
private let rbA9_suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]

/// Splits on top-level " and " (not inside braces).
private func rbA9_splitNames(_ raw: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    let words = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace })
    for w in words {
        let word = String(w)
        if depth == 0, word == "and" {
            parts.append(current); current = ""
            continue
        }
        for ch in word {
            if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) }
        }
        current += (current.isEmpty ? "" : " ") + word
    }
    parts.append(current)
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private func rbA9_creator(from raw: String, role: CreatorRole) -> CreatorInput? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }

    // {World Health Organization} written whole in braces = organisation.
    if name.hasPrefix("{"), name.hasSuffix("}"), !name.dropFirst().dropLast().contains("{") {
        let org = rbA9_clean(name)
        if org.lowercased() == "others" { return nil }
        return CreatorInput(family: org, isOrganisation: true, role: role)
    }

    // Split on top-level commas.
    var segments: [String] = []
    var cur = ""
    var depth = 0
    for ch in name {
        if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) }
        if ch == ",", depth == 0 { segments.append(cur); cur = "" } else { cur.append(ch) }
    }
    segments.append(cur)
    let seg = segments.map { rbA9_clean($0) }.filter { !$0.isEmpty }
    guard !seg.isEmpty else { return nil }

    if seg.count >= 3 {
        // Family, Suffix, Given
        return CreatorInput(family: seg[0], given: seg[2], suffix: seg[1], role: role)
    }
    if seg.count == 2 {
        // Family, Given   (a lone suffix like "Smith, Jr." has no given name)
        if rbA9_suffixes.contains(seg[1].lowercased()) {
            return CreatorInput(family: seg[0], suffix: seg[1], role: role)
        }
        return CreatorInput(family: seg[0], given: seg[1], role: role)
    }

    // "Given Middle von Family": family = last word plus any lower-case particles before it.
    var words = seg[0].split(separator: " ").map(String.init)
    if words.count == 1 {
        return CreatorInput(family: words[0], role: role)
    }
    var suffix = ""
    if let last = words.last, rbA9_suffixes.contains(last.lowercased()), words.count > 2 {
        suffix = last
        words.removeLast()
    }
    var familyWords = [words.removeLast()]
    while let prev = words.last, rbA9_particles.contains(prev.lowercased()), !words.isEmpty, words.count > 1 {
        familyWords.insert(words.removeLast(), at: 0)
    }
    return CreatorInput(family: familyWords.joined(separator: " "),
                        given: words.joined(separator: " "), suffix: suffix, role: role)
}

private func rbA9_creators(_ raw: String?, role: CreatorRole) -> [CreatorInput] {
    guard let raw, !raw.isEmpty else { return [] }
    return rbA9_splitNames(raw)
        .compactMap { rbA9_creator(from: $0, role: role) }
        .filter { !($0.family.lowercased() == "others" && $0.given.isEmpty) }
}

// MARK: - Building an item (private)

private func rbA9_itemType(_ bib: String, fields: [String: String]) -> ItemType {
    switch bib {
    case "article":
        if (fields["archiveprefix"] ?? fields["eprinttype"] ?? "").lowercased() == "arxiv",
           (fields["journal"] ?? "").isEmpty { return .preprint }
        return .article
    case "inproceedings", "conference", "proceedings": return .conference
    case "book", "booklet": return .book
    case "inbook", "incollection": return .chapter
    case "phdthesis", "mastersthesis": return .thesis
    case "techreport", "report": return .report
    case "online", "electronic", "www", "webpage": return .webpage
    case "dataset", "data": return .dataset
    case "software", "code": return .software
    case "unpublished", "misc":
        if (fields["archiveprefix"] ?? fields["eprinttype"] ?? "").lowercased() == "arxiv"
            || fields["arxivid"] != nil { return .preprint }
        if fields["eprint"] != nil, (fields["howpublished"] ?? "").lowercased().contains("arxiv") { return .preprint }
        return bib == "misc" && fields["url"] != nil && fields["journal"] == nil ? .webpage : .article
    default: return .article
    }
}

private func rbA9_year(_ fields: [String: String]) -> (Int?, String?) {
    func firstYear(_ text: String) -> Int? {
        let scalars = Array(text.unicodeScalars)
        var run = ""
        for c in scalars + [" "] {
            if c.properties.numericType != nil, c.isASCII { run.unicodeScalars.append(c) }
            else {
                if run.count == 4, let y = Int(run) { return y }
                run = ""
            }
        }
        return nil
    }
    if let y = fields["year"], !y.isEmpty {
        if let parsed = firstYear(y) { return (parsed, nil) }
        return (nil, "Year \"\(y)\" was not understood and was left empty.")
    }
    if let d = fields["date"], !d.isEmpty {
        if let parsed = firstYear(d) { return (parsed, nil) }
        return (nil, "Date \"\(d)\" was not understood and was left empty.")
    }
    return (nil, nil)
}

private func rbA9_makeEntry(index: Int, type: String, key: String,
                            fields rawFields: [(String, String)],
                            reviewState: ReviewState) -> BibTeXImportEntry? {

    // First occurrence of a field wins; values are cleaned except raw author lists.
    var raw: [String: String] = [:]
    for (name, value) in rawFields where raw[name] == nil { raw[name] = value }
    var f: [String: String] = [:]
    for (name, value) in raw {
        f[name] = ["author", "editor", "translator"].contains(name)
            ? value.trimmingCharacters(in: .whitespacesAndNewlines)
            : rbA9_clean(value)
    }

    let title = f["title"] ?? f["booktitle"] ?? ""
    guard !title.isEmpty else { return nil }

    var warnings: [String] = []
    let itemType = rbA9_itemType(type, fields: f)

    // Creators: authors first, then editors, then translators.
    var creators = rbA9_creators(f["author"], role: .author)
    creators += rbA9_creators(f["editor"], role: .editor)
    creators += rbA9_creators(f["translator"], role: .translator)
    if raw["author"]?.lowercased().contains("and others") == true
        || raw["author"]?.lowercased().hasSuffix(" others") == true {
        warnings.append("The author list ends with \"others\"; only the named authors were imported.")
    }
    if creators.isEmpty { warnings.append("No authors were found.") }

    let (year, yearWarning) = rbA9_year(f)
    if let yearWarning { warnings.append(yearWarning) }
    if year == nil && yearWarning == nil { warnings.append("No year was found.") }

    // Venue depends on the type.
    var venue = ""
    switch itemType {
    case .article, .preprint: venue = f["journal"] ?? f["journaltitle"] ?? f["howpublished"] ?? ""
    case .conference, .chapter: venue = f["booktitle"] ?? f["journal"] ?? ""
    default: venue = f["journal"] ?? f["booktitle"] ?? ""
    }
    if itemType == .article, venue.isEmpty { warnings.append("No journal name was found.") }

    let publisher = f["publisher"] ?? f["school"] ?? f["institution"] ?? f["organization"] ?? ""

    // Identifiers
    let doi = TextNormalizer.doi(f["doi"])
    var arxiv = TextNormalizer.arxivID(f["arxivid"])
    if arxiv == nil, let eprint = f["eprint"] {
        let kind = (f["archiveprefix"] ?? f["eprinttype"] ?? "").lowercased()
        if kind == "arxiv" || kind.isEmpty && eprint.range(of: #"^\d{4}\.\d{4,5}(v\d+)?$"#, options: .regularExpression) != nil {
            arxiv = TextNormalizer.arxivID(eprint)
        }
    }
    if doi == nil && arxiv == nil && itemType != .book && itemType != .webpage {
        warnings.append("No DOI or arXiv ID; duplicates cannot be matched by identifier.")
    }

    var url = f["url"] ?? ""
    if url.isEmpty, let how = f["howpublished"], how.lowercased().hasPrefix("http") { url = how }

    var item = NewItem(title: title)
    item.type = itemType
    item.creators = creators
    item.year = year
    item.venue = venue
    item.abstract = f["abstract"] ?? ""
    item.volume = f["volume"] ?? ""
    item.issue = f["number"] ?? f["issue"] ?? ""
    item.pages = f["pages"] ?? ""
    item.publisher = publisher
    item.doi = doi
    item.arxivID = arxiv
    item.url = url
    item.sourceKind = .import
    item.sourceURL = ""
    item.reviewState = reviewState

    if !key.isEmpty, key.contains(" ") { warnings.append("The key \"\(key)\" contains a space; the library will make its own key.") }

    return BibTeXImportEntry(index: index, originalKey: key, bibType: type,
                             item: item, warnings: warnings)
}
