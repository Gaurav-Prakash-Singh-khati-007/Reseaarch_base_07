//
//  BibValidator.swift
//  ResearchBase
//
//  Owner: Agent 25 · Features: L-06
//
//  The .bib view's checker. Give it the text of a refs.bib and it returns the
//  entries it found plus a list of problems, each with a line number so the
//  view can mark the gutter and jump to the spot.
//
//  What it flags
//    errors     things that break a LaTeX build: an entry that is never closed,
//               a missing, illegal or duplicate citation key, an undefined @string name.
//    warnings   things that build but give a wrong or blank reference: a missing
//               required field (per entry type), an empty field, a repeated field,
//               an odd year or DOI, an author list with commas or a dangling "and",
//               an unescaped % or & or unbalanced $, a crossref to nothing,
//               an unknown entry type.
//    info       things worth knowing: a DOI stored as a link, an entry nothing cites.
//    cited keys optional: pass the keys a draft cites and each one that is not in the
//               file is an error, each entry nobody cites is info.
//
//  Pure text in, plain values out. No database, no other agent's code, and
//  nothing is changed or "fixed"; the checker only reports.
//
//  PUBLIC API
//    BibValidator.validate(_ text: String, citedKeys: Set<String>? = nil) -> BibValidationReport
//    BibValidator.validateFile(at url: URL, citedKeys: Set<String>? = nil) throws -> BibValidationReport
//    BibValidator.requiredFieldGroups(for entryType: String) -> [[String]]
//        each inner list is "any one of these"; [] for types with no required fields
//    BibValidator.isKnownEntryType(_ type: String) -> Bool
//    BibValidationReport   entries, issues, counts, summary, isClean, isBuildable,
//                          issues(forKey:), issues(onLine:), worstSeverityByLine
//    BibEntry              type, key, fields, line, endLine, status, missingFields, value(of:), has(_:)
//    BibField              name, value, line, usesMacro
//    BibIssue              id, severity, kind, message, suggestion, entryKey, field, line
//    BibIssueSeverity      info < warning < error
//    BibIssueKind          what sort of problem
//    BibEntryStatus        ok / incomplete / broken
//
//  Lines are 1-based. An issue about the file as a whole (a cited key that is
//  not in it) has line 0.
//

import Foundation

// MARK: - Result types

enum BibIssueSeverity: Int, Comparable {
    case info = 0
    case warning = 1
    case error = 2

    static func < (lhs: BibIssueSeverity, rhs: BibIssueSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum BibIssueKind: String {
    case syntax
    case missingKey
    case invalidKey
    case duplicateKey
    case unknownType
    case missingField
    case emptyField
    case duplicateField
    case badYear
    case badDOI
    case badAuthors
    case specialCharacter
    case undefinedString
    case missingCrossref
    case citedKeyMissing
    case uncitedEntry
}

enum BibEntryStatus: Equatable {
    /// Nothing to fix.
    case ok
    /// Builds, but something is missing or odd (a warning).
    case incomplete
    /// Will break the build or cannot be used (an error).
    case broken
}

struct BibField: Equatable {
    /// Lower-cased.
    let name: String
    /// The text between the outer braces or quotes. Several pieces joined with # are joined without the #.
    let value: String
    let line: Int
    /// The value used an @string name (such as `jan`, or a macro the file defines).
    let usesMacro: Bool
}

struct BibEntry: Equatable {

    /// Lower-cased, without the @.
    let type: String
    let key: String
    let fields: [BibField]
    /// Line of the @.
    let line: Int
    /// Line of the closing brace.
    let endLine: Int

    /// Filled in by `validate`.
    var status: BibEntryStatus = .ok
    /// One name per unsatisfied required field (the first choice when several would do). Filled in by `validate`.
    var missingFields: [String] = []

    func value(of name: String) -> String? {
        let wanted = name.lowercased()
        return fields.first { $0.name == wanted }?.value
    }

    func has(_ name: String) -> Bool {
        let wanted = name.lowercased()
        return fields.contains { $0.name == wanted }
    }
}

struct BibIssue: Identifiable, Equatable {

    /// Same problem, same id, from one check to the next.
    let id: String
    let severity: BibIssueSeverity
    let kind: BibIssueKind
    let message: String
    let suggestion: String
    let entryKey: String?
    let field: String?
    /// 1-based; 0 when the problem is about the file as a whole.
    let line: Int
}

struct BibValidationReport {

    let entries: [BibEntry]
    /// By line, then worst first. Whole-file problems (line 0) come last.
    let issues: [BibIssue]

    var entryCount: Int { entries.count }
    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    var infoCount: Int { issues.filter { $0.severity == .info }.count }

    /// No errors and no warnings. (Info notes do not count.)
    var isClean: Bool { errorCount == 0 && warningCount == 0 }

    /// No errors. Warnings still let the build go through.
    var isBuildable: Bool { errorCount == 0 }

    func issues(forKey key: String) -> [BibIssue] {
        let wanted = key.lowercased()
        return issues.filter { $0.entryKey?.lowercased() == wanted }
    }

    func issues(onLine line: Int) -> [BibIssue] {
        issues.filter { $0.line == line }
    }

    /// For colouring a gutter: the worst problem on each line.
    var worstSeverityByLine: [Int: BibIssueSeverity] {
        var result: [Int: BibIssueSeverity] = [:]
        for issue in issues where issue.line > 0 {
            if let existing = result[issue.line], existing >= issue.severity { continue }
            result[issue.line] = issue.severity
        }
        return result
    }

    /// One line for a banner.
    var summary: String {

        let entryText = "\(entryCount) \(entryCount == 1 ? "entry" : "entries")"

        if errorCount == 0 && warningCount == 0 {
            if infoCount == 0 { return "\(entryText), nothing to fix." }
            return "\(entryText), nothing to fix (\(infoCount) \(infoCount == 1 ? "note" : "notes"))."
        }

        var parts: [String] = []
        if errorCount > 0 { parts.append("\(errorCount) \(errorCount == 1 ? "error" : "errors")") }
        if warningCount > 0 { parts.append("\(warningCount) \(warningCount == 1 ? "warning" : "warnings")") }
        return parts.joined(separator: ", ") + " in \(entryText)."
    }
}

// MARK: - Validator

enum BibValidator {

    static func validate(_ text: String, citedKeys: Set<String>? = nil) -> BibValidationReport {

        var parser = BibParser(text: text)
        parser.run()

        var checker = BibChecker(entries: parser.entries, issues: parser.issues)
        checker.run(citedKeys: citedKeys)

        return BibValidationReport(entries: checker.entries, issues: checker.finishedIssues())
    }

    static func validateFile(at url: URL, citedKeys: Set<String>? = nil) throws -> BibValidationReport {

        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""

        return validate(text, citedKeys: citedKeys)
    }

    /// Each inner list is "any one of these satisfies it".
    static func requiredFieldGroups(for entryType: String) -> [[String]] {
        requirements[entryType.lowercased()] ?? []
    }

    static func isKnownEntryType(_ type: String) -> Bool {
        let lowered = type.lowercased()
        return requirements[lowered] != nil || otherKnownTypes.contains(lowered)
    }

    private static let inproceedings: [[String]] = [
        ["author"], ["title"], ["booktitle"], ["year", "date"]
    ]
    private static let thesis: [[String]] = [
        ["author"], ["title"], ["school", "institution"], ["year", "date"]
    ]
    private static let report: [[String]] = [
        ["author"], ["title"], ["institution"], ["year", "date"]
    ]
    private static let dataset: [[String]] = [
        ["author", "editor"], ["title"], ["year", "date"]
    ]

    /// Standard BibTeX requirements, with the BibLaTeX spellings accepted as alternatives
    /// (`date` for `year`, `journaltitle` for `journal`).
    private static let requirements: [String: [[String]]] = [
        "article": [["author"], ["title"], ["journal", "journaltitle"], ["year", "date"]],
        "book": [["author", "editor"], ["title"], ["publisher"], ["year", "date"]],
        "booklet": [["title"]],
        "inbook": [["author", "editor"], ["title"], ["chapter", "pages"], ["publisher"], ["year", "date"]],
        "incollection": [["author"], ["title"], ["booktitle"], ["publisher"], ["year", "date"]],
        "inproceedings": inproceedings,
        "conference": inproceedings,
        "manual": [["title"]],
        "mastersthesis": thesis,
        "phdthesis": thesis,
        "thesis": thesis,
        "misc": [],
        "online": [["author", "editor"], ["title"], ["year", "date"], ["url"]],
        "electronic": [["author", "editor"], ["title"], ["year", "date"], ["url"]],
        "proceedings": [["title"], ["year", "date"]],
        "techreport": report,
        "report": report,
        "unpublished": [["author"], ["title"], ["note"]],
        "dataset": dataset,
        "software": dataset,
        "patent": [["author"], ["title"], ["number"], ["year", "date"]],
        "periodical": [["editor"], ["title"], ["year", "date"]]
    ]

    private static let otherKnownTypes: Set<String> = [
        "collection", "mvbook", "mvcollection", "mvproceedings", "mvreference", "inreference",
        "reference", "suppbook", "suppcollection", "suppperiodical", "bookinbook", "letter",
        "music", "audio", "video", "movie", "image", "artwork", "performance", "review",
        "standard", "set", "xdata", "commentary", "jurisdiction", "legislation", "legal",
        "customa", "customb", "customc", "customd", "custome", "customf", "www"
    ]
}

// MARK: - Checker (rules applied to parsed entries)

private struct BibChecker {

    var entries: [BibEntry]
    private(set) var issues: [BibIssue]

    private var worst: [Int: BibIssueSeverity] = [:]
    private var missing: [Int: [String]] = [:]

    init(entries: [BibEntry], issues: [BibIssue]) {
        self.entries = entries
        self.issues = issues
    }

    // MARK: Adding issues

    private mutating func add(
        _ kind: BibIssueKind,
        _ severity: BibIssueSeverity,
        _ message: String,
        _ suggestion: String = "",
        entry index: Int? = nil,
        key: String? = nil,
        field: String? = nil,
        line: Int
    ) {
        issues.append(BibIssue(
            id: "",
            severity: severity,
            kind: kind,
            message: message,
            suggestion: suggestion,
            entryKey: key ?? index.map { entries[$0].key },
            field: field,
            line: line
        ))

        if let index {
            worst[index] = max(worst[index] ?? .info, severity)
        }
    }

    /// Sorts, and gives every issue a stable id.
    func finishedIssues() -> [BibIssue] {

        let sorted = issues.sorted { lhs, rhs in
            let l = lhs.line == 0 ? Int.max : lhs.line
            let r = rhs.line == 0 ? Int.max : rhs.line
            if l != r { return l < r }
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.message < rhs.message
        }

        var counts: [String: Int] = [:]
        var result: [BibIssue] = []

        for issue in sorted {
            let base = "\(issue.kind.rawValue)|\(issue.line)|\(issue.entryKey ?? "")|\(issue.field ?? "")"
            let n = counts[base, default: 0]
            counts[base] = n + 1

            result.append(BibIssue(
                id: n == 0 ? base : "\(base)|\(n)",
                severity: issue.severity,
                kind: issue.kind,
                message: issue.message,
                suggestion: issue.suggestion,
                entryKey: issue.entryKey,
                field: issue.field,
                line: issue.line
            ))
        }

        return result
    }

    // MARK: Running

    mutating func run(citedKeys: Set<String>?) {

        // First entry with each key (lower-cased), for duplicates and crossref lookups.
        var firstByKey: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where !entry.key.isEmpty {
            let lowered = entry.key.lowercased()
            if firstByKey[lowered] == nil { firstByKey[lowered] = index }
        }

        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())

        for index in entries.indices {
            checkType(index)
            checkKey(index, firstByKey: firstByKey)
            checkFields(index, thisYear: thisYear)
            checkRequired(index, firstByKey: firstByKey)
        }

        if let cited = citedKeys {
            checkCited(cited)
        }

        for index in entries.indices {
            switch worst[index] ?? .info {
            case .error: entries[index].status = .broken
            case .warning: entries[index].status = .incomplete
            case .info: entries[index].status = .ok
            }
            entries[index].missingFields = missing[index] ?? []
        }
    }

    // MARK: Rules · type and key

    private mutating func checkType(_ index: Int) {

        let entry = entries[index]

        if !BibValidator.isKnownEntryType(entry.type) {
            add(.unknownType, .warning,
                "“@\(entry.type)” is not an entry type BibTeX or BibLaTeX knows.",
                "Use a standard type such as @article, @inproceedings, @book or @misc.",
                entry: index, line: entry.line)
        }
    }

    private mutating func checkKey(_ index: Int, firstByKey: [String: Int]) {

        let entry = entries[index]

        guard !entry.key.isEmpty else {
            add(.missingKey, .error,
                "This entry has no citation key.",
                "Write the key right after the opening brace, for example @article{smith2020word,",
                entry: index, line: entry.line)
            return
        }

        if let bad = Self.firstIllegalKeyCharacter(entry.key) {
            add(.invalidKey, .error,
                "The key “\(entry.key)” contains \(Self.describe(bad)), which BibTeX does not allow in keys.",
                "Use letters, digits and - _ : . only.",
                entry: index, line: entry.line)
        } else if entry.key.unicodeScalars.contains(where: { !$0.isASCII }) {
            add(.invalidKey, .warning,
                "The key “\(entry.key)” contains accented or non-English letters, which BibTeX handles badly.",
                "Use plain letters and digits in keys.",
                entry: index, line: entry.line)
        }

        if let first = firstByKey[entry.key.lowercased()], first != index {
            let other = entries[first]
            let message = other.key == entry.key
                ? "The key “\(entry.key)” is already used by the entry on line \(other.line)."
                : "The key “\(entry.key)” differs only by letter case from “\(other.key)” on line \(other.line); BibTeX treats them as the same."

            add(.duplicateKey, .error, message, "Give each entry its own key.", entry: index, line: entry.line)
        }
    }

    private static func firstIllegalKeyCharacter(_ key: String) -> Character? {
        let illegal = Set("\"#%'(),={}\\~")
        return key.first { illegal.contains($0) || $0.isWhitespace }
    }

    private static func describe(_ character: Character) -> String {
        if character == " " { return "a space" }
        if character.isWhitespace { return "a tab or line break" }
        return "the character “\(character)”"
    }

    // MARK: Rules · required fields

    private mutating func checkRequired(_ index: Int, firstByKey: [String: Int]) {

        let entry = entries[index]

        var parent: BibEntry?

        if let reference = entry.value(of: "crossref"), !Self.isBlank(reference) {
            let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let parentIndex = firstByKey[wanted] {
                parent = entries[parentIndex]
            } else {
                add(.missingCrossref, .warning,
                    "This entry points to “\(reference)” with crossref, but no entry has that key.",
                    "Add the parent entry or remove the crossref field.",
                    entry: index, field: "crossref", line: Self.fieldLine(entry, "crossref"))
            }
        }

        var unsatisfied: [String] = []

        for group in BibValidator.requiredFieldGroups(for: entry.type) {

            let satisfied = group.contains { name in
                if let own = entry.value(of: name), !Self.isBlank(own) { return true }
                if let inherited = parent?.value(of: name), !Self.isBlank(inherited) { return true }
                return false
            }

            if satisfied { continue }

            unsatisfied.append(group[0])

            let blankOnes = group.filter { name in
                entry.has(name) && Self.isBlank(entry.value(of: name) ?? "")
            }

            if let name = blankOnes.first {
                add(.emptyField, .warning,
                    "The required field “\(name)” is empty.",
                    "Fill it in, or remove the field if you do not have it.",
                    entry: index, field: name, line: Self.fieldLine(entry, name))
            } else {
                let quoted = group.map { "“\($0)”" }
                let list = quoted.count == 1
                    ? quoted[0]
                    : quoted.dropLast().joined(separator: ", ") + " or " + quoted[quoted.count - 1]

                add(.missingField, .warning,
                    "A @\(entry.type) entry needs \(list), and it is missing.",
                    "Add \(group[0]) = {…} to this entry.",
                    entry: index, field: group[0], line: entry.line)
            }
        }

        missing[index] = unsatisfied
    }

    private static func fieldLine(_ entry: BibEntry, _ name: String) -> Int {
        entry.fields.first { $0.name == name }?.line ?? entry.line
    }

    /// Empty once braces and white space are ignored, so `{}` and `{{ }}` count as empty.
    private static func isBlank(_ value: String) -> Bool {
        !value.contains { $0 != "{" && $0 != "}" && !$0.isWhitespace }
    }

    // MARK: Rules · field values

    private mutating func checkFields(_ index: Int, thisYear: Int) {

        let entry = entries[index]
        var seen = Set<String>()
        let required = Set(BibValidator.requiredFieldGroups(for: entry.type).flatMap { $0 })

        for field in entry.fields {

            if !seen.insert(field.name).inserted {
                add(.duplicateField, .warning,
                    "The field “\(field.name)” appears more than once; BibTeX uses only the first.",
                    "Delete the repeated field.",
                    entry: index, field: field.name, line: field.line)
                continue
            }

            // An empty required field is reported with the missing-field rule.
            if Self.isBlank(field.value) {
                if !required.contains(field.name) {
                    add(.emptyField, .warning,
                        "The field “\(field.name)” is empty.",
                        "Fill it in or delete the field.",
                        entry: index, field: field.name, line: field.line)
                }
                continue
            }

            switch field.name {
            case "year": checkYear(field, index: index, thisYear: thisYear)
            case "date": checkDate(field, index: index)
            case "doi": checkDOI(field, index: index)
            case "author", "editor": checkPeople(field, index: index)
            default: break
            }

            if Self.textFields.contains(field.name) {
                checkSpecialCharacters(field, index: index)
            }
        }
    }

    private static let wordYears: [String] = [
        "in press", "forthcoming", "n.d.", "submitted", "to appear", "unpublished", "in preparation"
    ]

    private mutating func checkYear(_ field: BibField, index: Int, thisYear: Int) {

        let text = Self.plain(field.value)

        if field.usesMacro { return }

        if Self.wordYears.contains(text.lowercased()) { return }

        guard Self.matches("^\\d{4}[a-z]?$", text) else {
            add(.badYear, .warning,
                "The year “\(text)” is not a four-digit year.",
                "Write the year as four digits, for example 2024.",
                entry: index, field: "year", line: field.line)
            return
        }

        if let year = Int(text.prefix(4)), year < 1400 || year > thisYear + 5 {
            add(.badYear, .warning,
                "The year \(year) looks wrong.",
                "Check it against the paper.",
                entry: index, field: "year", line: field.line)
        }
    }

    private mutating func checkDate(_ field: BibField, index: Int) {

        if field.usesMacro { return }

        let text = Self.plain(field.value)

        if !Self.matches("^\\d{4}(-\\d{2}(-\\d{2})?)?([/-].*)?$", text) {
            add(.badYear, .warning,
                "The date “\(text)” does not start with a four-digit year.",
                "BibLaTeX dates look like 2024, 2024-05 or 2024-05-17.",
                entry: index, field: "date", line: field.line)
        }
    }

    private mutating func checkDOI(_ field: BibField, index: Int) {

        let text = Self.plain(field.value)
        let lowered = text.lowercased()

        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("doi:") {
            add(.badDOI, .info,
                "The DOI is stored with a prefix (“\(text)”).",
                "Store the bare DOI, such as 10.1038/nature12373, so every style can link it.",
                entry: index, field: "doi", line: field.line)
            return
        }

        if !Self.matches("^10\\.\\d{4,9}/\\S+$", text) {
            add(.badDOI, .warning,
                "“\(text)” does not look like a DOI.",
                "A DOI starts with 10. followed by digits, a slash and a suffix.",
                entry: index, field: "doi", line: field.line)
        }
    }

    private mutating func checkPeople(_ field: BibField, index: Int) {

        // Only plain text can be judged. Braced names such as {World Health Organization} are fine.
        let text = Self.plain(field.value)

        if text.contains(";") {
            add(.badAuthors, .warning,
                "The \(field.name) list uses semicolons. BibTeX needs the word “and” between people.",
                "Write names as: Smith, Jane and Lee, Wei",
                entry: index, field: field.name, line: field.line)
            return
        }

        let outer = field.value

        // Names inside braces (organisations) hide their commas and "and".
        let stripped = Self.removeBracedGroups(outer)

        let words = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        if words.first == "and" || words.last == "and" {
            add(.badAuthors, .warning,
                "The \(field.name) list starts or ends with “and”.",
                "Put “and” only between two people.",
                entry: index, field: field.name, line: field.line)
            return
        }

        for pair in zip(words, words.dropFirst()) where pair.0 == "and" && pair.1 == "and" {
            add(.badAuthors, .warning,
                "The \(field.name) list has “and and” with nobody between.",
                "Delete the extra “and”.",
                entry: index, field: field.name, line: field.line)
            return
        }

        let people = Self.splitOnAnd(stripped)

        if people.count == 1 {
            let commas = stripped.filter { $0 == "," }.count
            if commas >= 2 {
                add(.badAuthors, .warning,
                    "The \(field.name) list may use commas between people. BibTeX reads “A, B, C” as one person.",
                    "Write names as: Smith, Jane and Lee, Wei",
                    entry: index, field: field.name, line: field.line)
            }
        }
    }

    /// Fields where prose is written and a bare % or & breaks LaTeX.
    private static let textFields: Set<String> = [
        "title", "booktitle", "journal", "journaltitle", "publisher", "note", "address",
        "school", "institution", "series", "howpublished", "organization", "subtitle",
        "author", "editor"
    ]

    private mutating func checkSpecialCharacters(_ field: BibField, index: Int) {

        let value = field.value
        var previous: Character = " "
        var dollars = 0
        var badCharacter: Character?

        for character in value {
            if previous != "\\" {
                if character == "%" || character == "&" {
                    if badCharacter == nil { badCharacter = character }
                }
                if character == "$" { dollars += 1 }
            }
            previous = character
        }

        if let bad = badCharacter {
            add(.specialCharacter, .warning,
                "The \(field.name) contains an unescaped “\(bad)”, which LaTeX treats as a command.",
                "Write \\\(bad) instead.",
                entry: index, field: field.name, line: field.line)
        }

        if dollars % 2 == 1 {
            add(.specialCharacter, .warning,
                "The \(field.name) has a $ without a matching $, so the maths is not closed.",
                "Close the formula, or write \\$ for a dollar sign.",
                entry: index, field: field.name, line: field.line)
        }
    }

    // MARK: Rules · cited keys

    private mutating func checkCited(_ cited: Set<String>) {

        let present = Set(entries.map { $0.key.lowercased() })
        let citedLowered = Set(cited.map { $0.lowercased() })

        for key in cited.sorted() where !present.contains(key.lowercased()) {
            add(.citedKeyMissing, .error,
                "The draft cites “\(key)”, but refs.bib has no entry with that key.",
                "Add the paper to the draft's references, or fix the key in the draft.",
                key: key, line: 0)
        }

        for (index, entry) in entries.enumerated()
        where !entry.key.isEmpty && !citedLowered.contains(entry.key.lowercased()) {
            add(.uncitedEntry, .info,
                "Nothing in the draft cites “\(entry.key)”.",
                "It will not appear in the bibliography unless the draft cites it.",
                entry: index, line: entry.line)
        }
    }

    // MARK: Text helpers

    /// Value with braces removed and white space collapsed.
    private static func plain(_ value: String) -> String {
        value
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func removeBracedGroups(_ value: String) -> String {

        var result = ""
        var depth = 0

        for character in value {
            if character == "{" { depth += 1; continue }
            if character == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }

        return result
    }

    private static func splitOnAnd(_ value: String) -> [String] {

        var people: [[String]] = [[]]

        for word in value.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if word == "and" {
                people.append([])
            } else {
                people[people.count - 1].append(word)
            }
        }

        return people.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Parser (text -> entries, with syntax problems)

private struct BibParser {

    private let b: [UInt8]
    private let n: Int
    private let lineStarts: [Int]

    private(set) var entries: [BibEntry] = []
    private(set) var issues: [BibIssue] = []
    private var macros: [String: String] = [:]

    private static let months: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    init(text: String) {

        b = Array(text.utf8)
        n = b.count

        var starts = [0]
        for (offset, byte) in b.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        lineStarts = starts
    }

    // MARK: Byte helpers

    private func line(at offset: Int) -> Int {

        var low = 0
        var high = lineStarts.count - 1

        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }

        return low + 1
    }

    private func string(_ from: Int, _ to: Int) -> String {
        guard from < to else { return "" }
        return String(decoding: b[from..<to], as: UTF8.self)
    }

    private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
    private func isLetter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private func isNameByte(_ c: UInt8) -> Bool {
        isLetter(c) || isDigit(c) || c == 0x5F || c == 0x2D || c == 0x3A || c == 0x2E || c == 0x2B
    }

    private func isLineStart(_ offset: Int) -> Bool {
        var p = offset - 1
        while p >= 0, b[p] == 0x20 || b[p] == 0x09 { p -= 1 }
        return p < 0 || b[p] == 0x0A
    }

    private func skipSpace(_ p: inout Int) {
        while p < n, isSpace(b[p]) { p += 1 }
    }

    private mutating func report(_ message: String, _ suggestion: String = "", key: String? = nil, field: String? = nil, line: Int, kind: BibIssueKind = .syntax) {
        issues.append(BibIssue(
            id: "",
            severity: .error,
            kind: kind,
            message: message,
            suggestion: suggestion,
            entryKey: key,
            field: field,
            line: line
        ))
    }

    /// Index just after the `}` that closes the `{` at `p`, or nil when it never closes.
    private func matchBrace(from p: Int) -> Int? {

        var depth = 0
        var q = p

        while q < n {
            if b[q] == 0x7B { depth += 1 }
            if b[q] == 0x7D {
                depth -= 1
                if depth == 0 { return q + 1 }
            }
            q += 1
        }

        return nil
    }

    // MARK: Main loop

    mutating func run() {

        var i = (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) ? 3 : 0
        var recovering = false

        while i < n {

            guard let at = nextAt(from: i) else { break }

            // After a broken entry, only believe an @ that starts a line.
            if recovering && !isLineStart(at) {
                i = at + 1
                continue
            }

            var j = at + 1
            let typeStart = j
            while j < n, isLetter(b[j]) { j += 1 }

            guard j > typeStart else { i = at + 1; continue }

            let type = string(typeStart, j).lowercased()

            var k = j
            skipSpace(&k)

            guard k < n, b[k] == 0x7B || b[k] == 0x28 else { i = at + 1; continue }

            let close: UInt8 = b[k] == 0x7B ? 0x7D : 0x29

            switch type {

            case "comment":
                i = (b[k] == 0x7B ? matchBrace(from: k) : nil) ?? (k + 1)

            case "preamble":
                if b[k] == 0x7B, let end = matchBrace(from: k) {
                    i = end
                } else {
                    report("The @preamble starting here is never closed.", line: line(at: at))
                    recovering = true
                    i = at + 1
                }

            case "string":
                if let end = parseString(open: k, close: close, startLine: line(at: at)) {
                    i = end
                    recovering = false
                } else {
                    recovering = true
                    i = at + 1
                }

            default:
                if let end = parseEntry(type: type, at: at, open: k, close: close) {
                    i = end
                    recovering = false
                } else {
                    recovering = true
                    i = at + 1
                }
            }
        }
    }

    private func nextAt(from start: Int) -> Int? {
        var p = start
        while p < n {
            if b[p] == 0x40 { return p }
            p += 1
        }
        return nil
    }

    // MARK: @string

    private mutating func parseString(open: Int, close: UInt8, startLine: Int) -> Int? {

        var p = open + 1
        skipSpace(&p)

        let nameStart = p
        while p < n, isNameByte(b[p]) { p += 1 }
        let name = string(nameStart, p).lowercased()

        skipSpace(&p)

        guard p < n, b[p] == 0x3D, !name.isEmpty else {
            report("This @string is not written as name = \"value\".", line: startLine)
            return nil
        }

        p += 1

        guard let value = parseValue(&p, close: close, key: nil, field: name) else { return nil }

        macros[name] = value.text

        skipSpace(&p)
        if p < n, b[p] == 0x2C { p += 1; skipSpace(&p) }

        guard p < n, b[p] == close else {
            report("The @string starting here is never closed.", line: startLine)
            return nil
        }

        return p + 1
    }

    // MARK: Entries

    private mutating func parseEntry(type: String, at: Int, open: Int, close: UInt8) -> Int? {

        let startLine = line(at: at)

        var p = open + 1
        let keyStart = p

        while p < n, b[p] != 0x2C, b[p] != close { p += 1 }

        guard p < n else {
            report("The entry “@\(type){” starting here is never closed.", "Add the closing brace.", line: startLine)
            return nil
        }

        let key = string(keyStart, p).trimmingCharacters(in: .whitespacesAndNewlines)

        if b[p] == 0x2C { p += 1 }

        var fields: [BibField] = []

        while true {

            while p < n, isSpace(b[p]) || b[p] == 0x2C { p += 1 }

            guard p < n else {
                report("The entry “@\(type){\(key)” starting here is never closed.", "Add the closing brace.", key: key, line: startLine)
                return nil
            }

            if b[p] == close {
                p += 1
                break
            }

            let nameStart = p
            let fieldLine = line(at: nameStart)

            while p < n, isNameByte(b[p]) { p += 1 }

            if p == nameStart {
                let stray = Character(Unicode.Scalar(b[p]))
                report("Unexpected “\(stray)” in the entry “\(key)”.", "Check the commas and braces around here.", key: key, line: fieldLine)
                guard skipField(&p, close: close) else {
                    report("The entry “@\(type){\(key)” starting here is never closed.", key: key, line: startLine)
                    return nil
                }
                continue
            }

            let name = string(nameStart, p).lowercased()

            skipSpace(&p)

            guard p < n, b[p] == 0x3D else {
                report("The field “\(name)” has no “=” after it.", "Write it as \(name) = {value},", key: key, field: name, line: fieldLine)
                guard skipField(&p, close: close) else {
                    report("The entry “@\(type){\(key)” starting here is never closed.", key: key, line: startLine)
                    return nil
                }
                continue
            }

            p += 1

            guard let value = parseValue(&p, close: close, key: key, field: name) else {
                return nil
            }

            fields.append(BibField(name: name, value: value.text, line: fieldLine, usesMacro: value.usesMacro))

            skipSpace(&p)

            if p < n, b[p] == 0x2C {
                p += 1
            } else if p < n, b[p] != close {
                report("A comma is missing after the field “\(name)”.", "Put a comma at the end of the line.", key: key, field: name, line: fieldLine)
            }
        }

        entries.append(BibEntry(
            type: type,
            key: key,
            fields: fields,
            line: startLine,
            endLine: line(at: max(p - 1, 0))
        ))

        return p
    }

    /// Skips to the next comma or the closing delimiter outside braces. False when the file ends first.
    private func skipField(_ p: inout Int, close: UInt8) -> Bool {

        var depth = 0

        while p < n {
            let c = b[p]
            if c == 0x7B { depth += 1 }
            else if c == 0x7D {
                if depth == 0 && close == 0x7D { return true }
                depth = max(0, depth - 1)
            }
            else if depth == 0 && (c == 0x2C || c == close) { return true }
            p += 1
        }

        return false
    }

    // MARK: Values

    private struct ParsedValue {
        var text: String
        var usesMacro: Bool
    }

    /// One value: pieces of {…}, "…", digits or @string names, joined with #.
    /// Returns nil (after reporting) when the file ends inside the value.
    private mutating func parseValue(_ p: inout Int, close: UInt8, key: String?, field: String) -> ParsedValue? {

        var text = ""
        var usesMacro = false

        while true {

            skipSpace(&p)

            guard p < n else {
                report("The field “\(field)” is never finished.", "Check for a missing brace or quote.", key: key, field: field, line: line(at: n - 1))
                return nil
            }

            let c = b[p]

            if c == 0x7B {

                guard let end = matchBrace(from: p) else {
                    report("A “{” opened here is never closed.", "Add the missing “}”.", key: key, field: field, line: line(at: p))
                    return nil
                }

                text += string(p + 1, end - 1)
                p = end

            } else if c == 0x22 {

                var q = p + 1
                var depth = 0

                while q < n {
                    if b[q] == 0x7B { depth += 1 }
                    else if b[q] == 0x7D { depth = max(0, depth - 1) }
                    else if b[q] == 0x22 && depth == 0 { break }
                    q += 1
                }

                guard q < n else {
                    report("A quote opened here is never closed.", "Add the closing quote.", key: key, field: field, line: line(at: p))
                    return nil
                }

                text += string(p + 1, q)
                p = q + 1

            } else if isDigit(c) {

                let start = p
                while p < n, isDigit(b[p]) { p += 1 }
                text += string(start, p)

            } else if isNameByte(c) {

                let start = p
                let startLine = line(at: p)
                while p < n, isNameByte(b[p]) { p += 1 }
                let name = string(start, p).lowercased()

                usesMacro = true

                if let expansion = macros[name] {
                    text += expansion
                } else if Self.months.contains(name) {
                    text += name
                } else {
                    report(
                        "“\(name)” is used as a value but no @string defines it.",
                        "Put the value in braces, like {\(name)}, or define it with @string.",
                        key: key, field: field, line: startLine, kind: .undefinedString
                    )
                }

            } else {

                report("Unexpected “\(Character(Unicode.Scalar(c)))” where the value of “\(field)” should be.", "Values go in braces, like {text}.", key: key, field: field, line: line(at: p))
                guard skipField(&p, close: close) else { return nil }
                return ParsedValue(text: text, usesMacro: usesMacro)
            }

            skipSpace(&p)

            if p < n, b[p] == 0x23 {
                p += 1
                continue
            }

            return ParsedValue(text: text, usesMacro: usesMacro)
        }
    }
}
