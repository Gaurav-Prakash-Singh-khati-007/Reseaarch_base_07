//
//  DuplicateDetector.swift
//  ResearchBase
//
//  Owner: Agent 8 · Features: F-18
//
//  Finds likely duplicates of a paper that is about to be added (or already is
//  in the library). It compares, in this order of strength:
//    1. DOI                       (same DOI)
//    2. file fingerprint          (same SHA-256 as an attached file)
//    3. arXiv ID                  (same arXiv ID, version ignored)
//    4. normalised title          (same title once case, accents, punctuation,
//                                  a leading "The", and a trailing "(arXiv ...)" are ignored)
//    5. very similar title        (typo-level differences, or the same main title with a subtitle)
//  Titles are only weighed together with the first author and the year, so
//  two different works that share a title are not reported as sure duplicates.
//
//  This file only FINDS. It never merges, deletes or edits anything. The merge
//  itself is the merge sheet's job (#59). Reads the database only.
//
//  PUBLIC API
//    enum DuplicateReason                .sameDOI / .sameArXivID / .sameFile / .sameTitle / .similarTitle
//    enum DuplicateConfidence            .certain / .likely / .possible
//    struct DuplicateProbe               what to look for (doi, arxivID, title, year, firstAuthorFamily, fileSHA256s)
//    struct DuplicateMatch               itemID, title, reasons, confidence, isInInbox, isTrashed,
//                                        bannerText, matchedByText
//    struct DuplicateIndex               a snapshot of the library to match against (build once per batch)
//    enum DuplicateMatcher               pure matching, no database, safe on any thread
//      static func matches(for:in:limit:) -> [DuplicateMatch]
//      static func titleKey(_:) -> String
//    final class DuplicateDetector       main actor, reads through LibraryModel
//      init(model:)
//      func buildIndex(includeTrashed:) throws -> DuplicateIndex
//      func matches(for:includeTrashed:limit:) throws -> [DuplicateMatch]
//      func matches(for:in:limit:) -> [DuplicateMatch]
//      func probe(forItem:) throws -> DuplicateProbe
//      func duplicates(of itemID:includeTrashed:limit:) throws -> [DuplicateMatch]
//      func reasons(between:and:) throws -> [DuplicateReason]       (for the merge sheet)
//      func fileFingerprint(of url: URL) throws -> String           (same value the library stores)
//
//  Uses finished code: LibraryModel / LibraryDatabase (read-only SQL), ItemStore.fetch,
//  AttachmentStore.sha256Hex. TextNormalizer is main-actor isolated, so the pure
//  matcher keeps its own small copy of the DOI / arXiv rules.
//

import Foundation

// MARK: - Vocabulary

/// Ordered strongest first.
nonisolated enum DuplicateReason: Int, Equatable, Comparable, Sendable {
    case sameDOI = 0
    case sameFile
    case sameArXivID
    case sameTitle
    case similarTitle

    static func < (a: DuplicateReason, b: DuplicateReason) -> Bool { a.rawValue < b.rawValue }

    var displayName: String {
        switch self {
        case .sameDOI: return "DOI"
        case .sameArXivID: return "arXiv ID"
        case .sameFile: return "identical file"
        case .sameTitle: return "title"
        case .similarTitle: return "similar title"
        }
    }
}

nonisolated enum DuplicateConfidence: Int, Equatable, Comparable, Sendable {
    case possible = 0
    case likely
    case certain

    static func < (a: DuplicateConfidence, b: DuplicateConfidence) -> Bool { a.rawValue < b.rawValue }
}

/// What to look for. Fill what you know; every field is optional except the title may be empty.
nonisolated struct DuplicateProbe: Equatable, Sendable {
    var doi: String?
    var arxivID: String?
    var title: String
    var year: Int?
    /// Family name of the first author (or first editor), as written.
    var firstAuthorFamily: String?
    /// SHA-256 of any file that comes with the paper (see `DuplicateDetector.fileFingerprint`).
    var fileSHA256s: [String]
    /// An item that must not match itself.
    var excludingItemID: String?

    init(
        doi: String? = nil,
        arxivID: String? = nil,
        title: String = "",
        year: Int? = nil,
        firstAuthorFamily: String? = nil,
        fileSHA256s: [String] = [],
        excludingItemID: String? = nil
    ) {
        self.doi = doi
        self.arxivID = arxivID
        self.title = title
        self.year = year
        self.firstAuthorFamily = firstAuthorFamily
        self.fileSHA256s = fileSHA256s
        self.excludingItemID = excludingItemID
    }
}

nonisolated struct DuplicateMatch: Equatable, Sendable {
    var itemID: String
    var title: String
    /// Strongest first. Never empty.
    var reasons: [DuplicateReason]
    var confidence: DuplicateConfidence
    /// The existing copy is still waiting in the Inbox.
    var isInInbox: Bool
    /// The existing copy is in the Trash (only returned when asked for).
    var isTrashed: Bool

    /// "DOI", "DOI and identical file", "title" ...
    var matchedByText: String {
        let names = reasons.map(\.displayName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    /// Text for the banner: "Already in your library (matched by DOI)."
    var bannerText: String {
        let lead: String
        switch confidence {
        case .certain, .likely: lead = isTrashed ? "In your Trash" : "Already in your library"
        case .possible: lead = isTrashed ? "Possibly in your Trash" : "Possible duplicate"
        }
        return "\(lead) (matched by \(matchedByText))."
    }
}

// MARK: - The index

/// A snapshot of the library's titles, identifiers and file fingerprints.
/// Build it once, then match many papers against it (a 500-entry import builds one).
nonisolated struct DuplicateIndex: Sendable {

    struct Entry: Sendable {
        var id: String
        var title: String
        var titleKey: String
        var mainKey: String?          // the part before a subtitle, when there is one
        var words: [String]           // distinct words of 4+ letters in the title key
        var year: Int?
        var firstAuthor: String?      // letters and digits only, lower-case
        var doi: String?
        var arxivID: String?
        var isInbox: Bool
        var isTrashed: Bool

        init(
            id: String, title: String, year: Int?, firstAuthorFamily: String?,
            doi: String?, arxivID: String?, isInbox: Bool = false, isTrashed: Bool = false
        ) {
            self.id = id
            self.title = title
            self.titleKey = DuplicateMatcher.titleKey(title)
            self.mainKey = DuplicateMatcher.mainTitleKey(title)
            self.words = DuplicateMatcher.significantWords(self.titleKey)
            self.year = year
            self.firstAuthor = DuplicateMatcher.authorKey(firstAuthorFamily)
            self.doi = DuplicateMatcher.normalizedDOI(doi)
            self.arxivID = DuplicateMatcher.normalizedArXivID(arxivID)
            self.isInbox = isInbox
            self.isTrashed = isTrashed
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var byDOI: [String: [Int]] = [:]
    private(set) var byArXiv: [String: [Int]] = [:]
    private(set) var byFile: [String: [Int]] = [:]
    private(set) var byTitleKey: [String: [Int]] = [:]
    private(set) var byWord: [String: [Int]] = [:]

    /// - Parameter fileHashes: item id -> SHA-256 of each of its files.
    init(entries: [Entry], fileHashes: [String: [String]] = [:]) {
        self.entries = entries
        for (index, entry) in entries.enumerated() {
            if let doi = entry.doi { byDOI[doi, default: []].append(index) }
            if let arxiv = entry.arxivID { byArXiv[arxiv, default: []].append(index) }
            if !entry.titleKey.isEmpty { byTitleKey[entry.titleKey, default: []].append(index) }
            for word in entry.words { byWord[word, default: []].append(index) }
            for hash in fileHashes[entry.id] ?? [] {
                byFile[hash.lowercased(), default: []].append(index)
            }
        }
    }
}

// MARK: - Pure matching

nonisolated enum DuplicateMatcher {

    /// Titles whose key is shorter than this (or one word) only match when the first author agrees.
    static let shortTitleLength = 12
    /// "Long enough to be specific by itself."
    static let longTitleLength = 25
    static let similarityThreshold = 0.9

    // MARK: Entry point

    static func matches(for probe: DuplicateProbe, in index: DuplicateIndex, limit: Int = 10) -> [DuplicateMatch] {

        let doi = normalizedDOI(probe.doi)
        let arxiv = normalizedArXivID(probe.arxivID)
        let key = titleKey(probe.title)
        let mainKey = mainTitleKey(probe.title)
        let author = authorKey(probe.firstAuthorFamily)

        var reasons: [Int: Set<DuplicateReason>] = [:]
        var candidates = Set<Int>()

        // 1-3: identifiers and files go straight through their dictionaries.
        if let doi {
            for i in index.byDOI[doi] ?? [] { reasons[i, default: []].insert(.sameDOI) }
        }
        if let arxiv {
            for i in index.byArXiv[arxiv] ?? [] { reasons[i, default: []].insert(.sameArXivID) }
        }
        for hash in probe.fileSHA256s {
            for i in index.byFile[hash.lowercased()] ?? [] { reasons[i, default: []].insert(.sameFile) }
        }

        // 4-5: titles. Candidates are exact key matches plus items that share enough words.
        if !key.isEmpty {
            candidates.formUnion(index.byTitleKey[key] ?? [])

            let words = significantWords(key)
            var hits: [Int: Int] = [:]
            for word in words {
                for i in index.byWord[word] ?? [] { hits[i, default: 0] += 1 }
            }
            for (i, count) in hits {
                let smaller = min(words.count, index.entries[i].words.count)
                if count >= min(2, smaller), count * 2 >= smaller { candidates.insert(i) }
            }
        }

        var found: [Int: (reasons: Set<DuplicateReason>, titleConfidence: DuplicateConfidence?)] = [:]
        for (i, set) in reasons { found[i] = (set, nil) }

        for i in candidates {
            let entry = index.entries[i]
            if entry.id == probe.excludingItemID { continue }

            let exact = entry.titleKey == key
            let similar = !exact && isSimilar(key, entry.titleKey, probeMain: mainKey, entryMain: entry.mainKey)
            guard exact || similar else { continue }

            let authorState = compareAuthors(author, entry.firstAuthor)
            let yearState = compareYears(probe.year, entry.year)
            let long = key.count >= longTitleLength
            let short = key.count < shortTitleLength || !key.contains(" ")

            guard var confidence = titleConfidence(
                exact: exact, author: authorState, year: yearState, long: long, short: short
            ) else { continue }

            // Two different DOIs (or two different arXiv IDs) mean two different records.
            if let a = doi, let b = entry.doi, a != b { confidence = min(confidence, .possible) }
            if let a = arxiv, let b = entry.arxivID, a != b { confidence = min(confidence, .possible) }

            var entryReasons = found[i]?.reasons ?? []
            entryReasons.insert(exact ? .sameTitle : .similarTitle)
            found[i] = (entryReasons, confidence)
        }

        // Build the answer.
        var result: [DuplicateMatch] = []
        for (i, value) in found {
            let entry = index.entries[i]
            if entry.id == probe.excludingItemID { continue }

            let hasStrongReason = value.reasons.contains { $0 <= .sameArXivID }
            let confidence: DuplicateConfidence = hasStrongReason ? .certain : (value.titleConfidence ?? .possible)

            result.append(DuplicateMatch(
                itemID: entry.id,
                title: entry.title,
                reasons: value.reasons.sorted(),
                confidence: confidence,
                isInInbox: entry.isInbox,
                isTrashed: entry.isTrashed
            ))
        }

        result.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.reasons[0] != $1.reasons[0] { return $0.reasons[0] < $1.reasons[0] }
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.itemID < $1.itemID : order == .orderedAscending
        }
        return Array(result.prefix(max(0, limit)))
    }

    // MARK: Title rules

    private enum Agreement { case agree, differ, unknown }

    private static func compareAuthors(_ a: String?, _ b: String?) -> Agreement {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return .unknown }
        if a == b { return .agree }
        // "vandenberg" vs "berg": one family name contained in the other
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count >= 3, long.contains(short) { return .agree }
        return .differ
    }

    private static func compareYears(_ a: Int?, _ b: Int?) -> Agreement {
        guard let a, let b else { return .unknown }
        return abs(a - b) <= 1 ? .agree : .differ     // a preprint and its paper often differ by a year
    }

    private static func titleConfidence(
        exact: Bool, author: Agreement, year: Agreement, long: Bool, short: Bool
    ) -> DuplicateConfidence? {

        // "Introduction", "Preface": only worth reporting when the first author matches too.
        if short, author != .agree { return nil }

        if author == .differ {
            return (exact && long && year != .differ) ? .possible : nil
        }
        if exact {
            if year == .differ { return .possible }
            return (author == .agree || long) ? .likely : .possible
        }
        // similar, not identical
        return (author == .agree && year != .differ) ? .likely : .possible
    }

    private static func isSimilar(_ a: String, _ b: String, probeMain: String?, entryMain: String?) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }

        // Same main title, one or both with a subtitle ("Attention Is All You Need: A Survey").
        let mainA = probeMain ?? a
        let mainB = entryMain ?? b
        if (probeMain != nil || entryMain != nil), mainA == mainB, isSpecific(mainA) { return true }

        // Lengths far apart cannot be typo-level different.
        let longer = Double(max(a.count, b.count)), shorter = Double(min(a.count, b.count))
        if shorter / longer < 0.75 { return false }

        return dice(a, b) >= similarityThreshold
    }

    private static func isSpecific(_ key: String) -> Bool {
        key.count >= 15 && key.split(separator: " ").count >= 3
    }

    /// Sørensen–Dice on character pairs: 1.0 identical, 0.0 nothing in common.
    static func dice(_ a: String, _ b: String) -> Double {
        func pairs(_ s: String) -> [String: Int] {
            let chars = Array(s)
            guard chars.count >= 2 else { return [:] }
            var counts: [String: Int] = [:]
            for i in 0..<(chars.count - 1) { counts[String([chars[i], chars[i + 1]]), default: 0] += 1 }
            return counts
        }
        let x = pairs(a), y = pairs(b)
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total > 0 else { return 0 }
        var shared = 0
        for (pair, count) in x { shared += min(count, y[pair] ?? 0) }
        return Double(2 * shared) / Double(total)
    }

    // MARK: Normalising

    /// Lower-case, accents folded, "&" read as "and", punctuation gone, spaces collapsed,
    /// a leading "the / a / an" dropped, trailing "(...)" or "[...]" groups dropped.
    static func titleKey(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Title (arXiv 1812.06127)" -> "Title"
        while let range = text.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression) {
            let stripped = String(text[text.startIndex..<range.lowerBound])
            if stripped.isEmpty { break }
            text = stripped
        }

        text = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")

        var cleaned = ""
        for scalar in text.unicodeScalars {
            cleaned.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        var words = cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1, ["the", "a", "an"].contains(words[0]) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// Key of the part before a subtitle (": ", " - ", an en or em dash). Nil when there is no subtitle.
    static func mainTitleKey(_ title: String) -> String? {
        guard let range = title.range(of: #"\s*[:–—]\s+|\s+-\s+"#, options: .regularExpression) else { return nil }
        let main = titleKey(String(title[title.startIndex..<range.lowerBound]))
        return main.isEmpty ? nil : main
    }

    static func significantWords(_ key: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for word in key.split(separator: " ") where word.count >= 4 {
            if seen.insert(String(word)).inserted { words.append(String(word)) }
        }
        return words
    }

    static func authorKey(_ family: String?) -> String? {
        guard let family else { return nil }
        let folded = family
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        let key = String(folded.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        return key.isEmpty ? nil : key
    }

    // Private copies of TextNormalizer.doi / .arxivID (TextNormalizer is main-actor isolated).

    static func normalizedDOI(_ text: String?) -> String? {
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

    static func normalizedArXivID(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let lower = value.lowercased()
        for prefix in ["https://arxiv.org/abs/", "http://arxiv.org/abs/", "arxiv.org/abs/", "arxiv:"]
        where lower.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        // 1706.03762v5 and 1706.03762 are the same paper
        if let range = value.range(of: #"v\d+$"#, options: .regularExpression) {
            value.removeSubrange(range)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Detector (reads the library)

final class DuplicateDetector {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Index

    /// Reads titles, identifiers, first authors and file fingerprints in three queries.
    /// Items in the Trash are left out unless `includeTrashed` is true.
    func buildIndex(includeTrashed: Bool = false) throws -> DuplicateIndex {

        let itemRows = try model.database.rows(
            "SELECT id, title, year, doi, arxiv_id, review_state, deleted_at FROM items"
                + (includeTrashed ? "" : " WHERE deleted_at IS NULL")
        )

        // First author of each item; an editor stands in when there is no author.
        var firstAuthor: [String: (family: String, isAuthor: Bool)] = [:]
        let creatorRows = try model.database.rows(
            """
            SELECT ic.item_id AS item_id, ic.role AS role, c.family AS family
            FROM item_creators ic JOIN creators c ON c.id = ic.creator_id
            WHERE ic.position = 0 AND ic.role IN ('author', 'editor')
            """
        )
        for row in creatorRows {
            guard let itemID = row.text("item_id"), let family = row.text("family") else { continue }
            let isAuthor = row.text("role") == "author"
            if let existing = firstAuthor[itemID], existing.isAuthor || !isAuthor { continue }
            firstAuthor[itemID] = (family, isAuthor)
        }

        var entries: [DuplicateIndex.Entry] = []
        var known = Set<String>()
        entries.reserveCapacity(itemRows.count)
        for row in itemRows {
            guard let id = row.text("id"), let title = row.text("title") else { continue }
            known.insert(id)
            entries.append(DuplicateIndex.Entry(
                id: id,
                title: title,
                year: row.int("year").map { Int($0) },
                firstAuthorFamily: firstAuthor[id]?.family,
                doi: row.text("doi"),
                arxivID: row.text("arxiv_id"),
                isInbox: row.text("review_state") == ReviewState.inbox.rawValue,
                isTrashed: row.text("deleted_at") != nil
            ))
        }

        var fileHashes: [String: [String]] = [:]
        let fileRows = try model.database.rows(
            "SELECT item_id, sha256 FROM attachments WHERE deleted_at IS NULL"
        )
        for row in fileRows {
            guard let itemID = row.text("item_id"), known.contains(itemID),
                  let hash = row.text("sha256") else { continue }
            fileHashes[itemID, default: []].append(hash)
        }

        return DuplicateIndex(entries: entries, fileHashes: fileHashes)
    }

    // MARK: Matching

    /// Builds a fresh index and matches one probe. For many papers, build the index once instead.
    func matches(for probe: DuplicateProbe, includeTrashed: Bool = false, limit: Int = 10) throws -> [DuplicateMatch] {
        DuplicateMatcher.matches(for: probe, in: try buildIndex(includeTrashed: includeTrashed), limit: limit)
    }

    func matches(for probe: DuplicateProbe, in index: DuplicateIndex, limit: Int = 10) -> [DuplicateMatch] {
        DuplicateMatcher.matches(for: probe, in: index, limit: limit)
    }

    // MARK: Items already in the library

    /// A probe built from a stored item and its files. Excludes the item itself.
    func probe(forItem itemID: String) throws -> DuplicateProbe {
        guard let item = try model.items.fetch(id: itemID, includeDeleted: true) else {
            throw ModelError.notFound(kind: "paper", id: itemID)
        }

        let authorRows = try model.database.rows(
            """
            SELECT c.family AS family, ic.role AS role
            FROM item_creators ic JOIN creators c ON c.id = ic.creator_id
            WHERE ic.item_id = ? AND ic.position = 0 AND ic.role IN ('author', 'editor')
            ORDER BY CASE ic.role WHEN 'author' THEN 0 ELSE 1 END
            """,
            [.text(itemID)]
        )
        let hashRows = try model.database.rows(
            "SELECT sha256 FROM attachments WHERE item_id = ? AND deleted_at IS NULL", [.text(itemID)]
        )

        return DuplicateProbe(
            doi: item.doi,
            arxivID: item.arxivID,
            title: item.title,
            year: item.year,
            firstAuthorFamily: authorRows.first?.text("family"),
            fileSHA256s: hashRows.compactMap { $0.text("sha256") },
            excludingItemID: itemID
        )
    }

    /// Other items that look like copies of this one (the Inbox "possible duplicate" banner).
    func duplicates(of itemID: String, includeTrashed: Bool = false, limit: Int = 10) throws -> [DuplicateMatch] {
        try matches(for: try probe(forItem: itemID), includeTrashed: includeTrashed, limit: limit)
    }

    /// Why two specific items look alike, strongest first. Empty when nothing matches.
    /// The merge sheet uses it for "Matched by title and identical file".
    func reasons(between firstID: String, and secondID: String) throws -> [DuplicateReason] {
        let found = try matches(for: try probe(forItem: firstID), includeTrashed: true, limit: Int.max)
        return found.first(where: { $0.itemID == secondID })?.reasons ?? []
    }

    // MARK: Files

    /// SHA-256 of a file, exactly as the library stores it, so a dropped PDF can be compared
    /// before it is imported. Put the result in `DuplicateProbe.fileSHA256s`.
    func fileFingerprint(of url: URL) throws -> String {
        try AttachmentStore.sha256Hex(of: url)
    }
}
