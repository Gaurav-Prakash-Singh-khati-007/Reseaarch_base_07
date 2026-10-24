//
//  ZoteroMendeleyImporter.swift
//  ResearchBase
//
//  Owner: Agent 12 · Features: F-19
//
//  Reads library exports from Zotero and Mendeley and returns a PREVIEW of
//  the items they would create. Nothing is saved here: no library database,
//  no PDF copying. The caller shows the preview, lets the person untick
//  items, then saves the chosen `item` values with `ItemStore.create`
//  (and may attach the files named in `attachmentHints`).
//
//  Formats (found automatically, see `detectFormat`)
//    .zoteroLibrary    zotero.sqlite, or the Zotero data folder that holds it
//    .zoteroRDF        File > Export Library > "Zotero RDF"
//    .cslJSON          "CSL JSON" export from Zotero (also other tools)
//    .mendeleyLibrary  the Mendeley Desktop database (a .sqlite file)
//  Mendeley's "BibTeX" and "RIS" exports are read by the BibTeX / RIS importers.
//  The newer Mendeley Reference Manager keeps its data in the cloud; export
//  BibTeX or RIS from it instead.
//
//  PUBLIC API
//    enum   ZoteroMendeleyFormat
//    struct ZMImportEntry            one parsed item (+ warnings, tags, file hints)
//    struct ZMImportResult           format, entries, skipped, counts, summary
//    enum   ZMImportError            file-level problems only (LocalizedError)
//    enum   ZoteroMendeleyImporter
//      static func detectFormat(fileAt:) throws -> ZoteroMendeleyFormat
//      static func parse(fileAt:reviewState:) throws -> ZMImportResult
//      static func parse(cslJSON:reviewState:) -> ZMImportResult
//      static func parse(zoteroRDF:baseURL:reviewState:) -> ZMImportResult
//
//  Rules
//    - Databases are opened READ-ONLY on a temporary copy, so a running
//      Zotero or Mendeley is never disturbed and never modified.
//    - Items in Zotero's trash and Mendeley's pending deletions are left out.
//    - Notes and attachments are not items; attachments become `attachmentHints`
//      (absolute paths where they can be worked out, otherwise as written).
//    - Content problems never throw; a bad item becomes a `skipped` line.
//    - Items are made with sourceKind .import and the given review state.
//    - Fields with no column in the schema (notes, collections, ratings ...)
//      are not stored. Tags are returned for the caller to use if it wants.
//

import Foundation
import SQLite3

// MARK: - Public types

enum ZoteroMendeleyFormat: String, Equatable {
    case zoteroLibrary, zoteroRDF, cslJSON, mendeleyLibrary

    var displayName: String {
        switch self {
        case .zoteroLibrary: return "Zotero library"
        case .zoteroRDF: return "Zotero RDF"
        case .cslJSON: return "CSL JSON"
        case .mendeleyLibrary: return "Mendeley library"
        }
    }
}

struct ZMImportEntry {
    /// 1-based position in the export, for messages.
    let index: Int
    /// The id the source app gave this item (Zotero key, Mendeley id, CSL id).
    let sourceID: String
    let format: ZoteroMendeleyFormat
    /// Ready for `ItemStore.create`.
    let item: NewItem
    /// Things the person should look at before saving.
    let warnings: [String]
    /// Tags from the source app (not stored by the importer).
    let tags: [String]
    /// Files the source app had for this item, e.g. PDFs. May not exist on disk.
    let attachmentHints: [String]
    /// Folder paths the item was in, e.g. "Energy/HPC" (Zotero collections). Parent first.
    var collections: [String] = []
}

struct ZMImportResult {
    var format: ZoteroMendeleyFormat?
    var entries: [ZMImportEntry] = []
    /// Items (or the whole file) that could not be read, each with a short reason.
    var skipped: [String] = []

    var entryCount: Int { entries.count }
    var warningCount: Int { entries.reduce(0) { $0 + $1.warnings.count } }

    /// One line for the preview header, e.g. "Zotero library: 120 entries, 3 with warnings".
    var summary: String {
        var parts = ["\(entryCount) \(entryCount == 1 ? "entry" : "entries")"]
        let withWarnings = entries.filter { !$0.warnings.isEmpty }.count
        if withWarnings > 0 { parts.append("\(withWarnings) with warnings") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        let text = parts.joined(separator: ", ")
        if let format { return "\(format.displayName): \(text)" }
        return text
    }
}

enum ZMImportError: LocalizedError, Equatable {
    case unreadable(String)
    case unrecognisedFormat
    case cannotOpenDatabase(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why):
            return "The file could not be read. \(why)"
        case .unrecognisedFormat:
            return "This file is not a Zotero library, Zotero RDF, CSL JSON or Mendeley Desktop database."
        case .cannotOpenDatabase(let why):
            return "The library database could not be opened. \(why)"
        }
    }
}

// MARK: - Importer

enum ZoteroMendeleyImporter {

    // MARK: Detect

    static func detectFormat(fileAt url: URL) throws -> ZoteroMendeleyFormat {
        let target = rbA12_resolve(url)
        let head = try rbA12_readHead(target)

        if head.starts(with: Array("SQLite format 3".utf8)) {
            let tables = try rbA12_withCopy(of: target) { db in try rbA12_tableNames(db) }
            if tables.contains("itemdatavalues") && tables.contains("itemtypes") { return .zoteroLibrary }
            if tables.contains("documents") && tables.contains("documentcontributors") { return .mendeleyLibrary }
            throw ZMImportError.unrecognisedFormat
        }

        let text = String(decoding: head, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if text.hasPrefix("[") || text.hasPrefix("{") { return .cslJSON }
        if text.hasPrefix("<"), text.contains("rdf:RDF") || text.contains("RDF") { return .zoteroRDF }
        throw ZMImportError.unrecognisedFormat
    }

    // MARK: Parse a file

    static func parse(fileAt url: URL, reviewState: ReviewState = .inbox) throws -> ZMImportResult {
        let target = rbA12_resolve(url)
        let format = try detectFormat(fileAt: url)

        switch format {
        case .cslJSON:
            let data = try rbA12_read(target)
            return parse(cslJSON: data, reviewState: reviewState)

        case .zoteroRDF:
            let data = try rbA12_read(target)
            return parse(zoteroRDF: data, baseURL: target.deletingLastPathComponent(), reviewState: reviewState)

        case .zoteroLibrary:
            let dataDir = target.deletingLastPathComponent()
            return try rbA12_withCopy(of: target) { db in
                let (drafts, skipped) = try rbA12_zoteroDrafts(db, dataDir: dataDir)
                return rbA12_assemble(drafts, skipped: skipped, format: .zoteroLibrary, reviewState: reviewState)
            }

        case .mendeleyLibrary:
            return try rbA12_withCopy(of: target) { db in
                let (drafts, skipped) = try rbA12_mendeleyDrafts(db)
                return rbA12_assemble(drafts, skipped: skipped, format: .mendeleyLibrary, reviewState: reviewState)
            }
        }
    }

    // MARK: Parse data

    static func parse(cslJSON data: Data, reviewState: ReviewState = .inbox) -> ZMImportResult {
        let (drafts, skipped) = rbA12_cslDrafts(data)
        return rbA12_assemble(drafts, skipped: skipped, format: .cslJSON, reviewState: reviewState)
    }

    static func parse(zoteroRDF data: Data, baseURL: URL? = nil, reviewState: ReviewState = .inbox) -> ZMImportResult {
        let (drafts, skipped) = rbA12_rdfDrafts(data, baseURL: baseURL)
        return rbA12_assemble(drafts, skipped: skipped, format: .zoteroRDF, reviewState: reviewState)
    }
}

// MARK: - Files and databases (private)

/// A folder is taken to be a Zotero data folder.
private func rbA12_resolve(_ url: URL) -> URL {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        return url.appendingPathComponent("zotero.sqlite")
    }
    return url
}

private func rbA12_read(_ url: URL) throws -> Data {
    do { return try Data(contentsOf: url) }
    catch { throw ZMImportError.unreadable(error.localizedDescription) }
}

private func rbA12_readHead(_ url: URL) throws -> [UInt8] {
    do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        return [UInt8](data)
    } catch {
        throw ZMImportError.unreadable(error.localizedDescription)
    }
}

private final class rbA12_DB {

    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error."
            sqlite3_close(handle)
            throw ZMImportError.cannotOpenDatabase(message)
        }
    }

    deinit { sqlite3_close(handle) }

    /// Each row as column name -> text. NULL columns are left out.
    func query(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error."
            throw ZMImportError.cannotOpenDatabase(message)
        }
        defer { sqlite3_finalize(statement) }

        let count = sqlite3_column_count(statement)
        var names: [String] = []
        for i in 0..<count { names.append(String(cString: sqlite3_column_name(statement, i))) }

        var rows: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for i in 0..<count where sqlite3_column_type(statement, i) != SQLITE_NULL {
                if let text = sqlite3_column_text(statement, i) {
                    row[names[Int(i)]] = String(cString: text)
                }
            }
            rows.append(row)
        }
        return rows
    }
}

/// Lower-cased table names.
private func rbA12_tableNames(_ db: rbA12_DB) throws -> Set<String> {
    Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"]?.lowercased() })
}

/// Copies the database (and its -wal / -shm files) to a temporary folder,
/// opens the copy read-only, runs `body`, then deletes the copy.
private func rbA12_withCopy<T>(of url: URL, _ body: (rbA12_DB) throws -> T) throws -> T {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        throw ZMImportError.unreadable("There is no file at \(url.path).")
    }
    let folder = fm.temporaryDirectory.appendingPathComponent("rbA12-\(UUID().uuidString)", isDirectory: true)
    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("library.sqlite")
        try fm.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        defer { try? fm.removeItem(at: folder) }
        let db = try rbA12_DB(path: copy.path)
        return try body(db)
    } catch let error as ZMImportError {
        try? fm.removeItem(at: folder)
        throw error
    } catch {
        try? fm.removeItem(at: folder)
        throw ZMImportError.unreadable(error.localizedDescription)
    }
}

// MARK: - Shared draft and finishing (private)

private struct rbA12_Draft {
    var sourceID = ""
    var typeLabel = ""
    var type: ItemType?
    var title = ""
    var abstract = ""
    var venue = ""
    var volume = ""
    var issue = ""
    var pages = ""
    var publisher = ""
    var doi: String?
    var arxiv: String?
    var url = ""
    var dateText = ""
    var year: Int?
    var creators: [CreatorInput] = []
    var tags: [String] = []
    var attachments: [String] = []
    var collections: [String] = []
}

private func rbA12_clean(_ text: String?) -> String {
    (text ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func rbA12_firstYear(_ text: String) -> Int? {
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

/// "arXiv:2301.12345 [cs.CL]" -> "2301.12345"
private func rbA12_arxivValue(_ raw: String?) -> String? {
    guard let raw else { return nil }
    guard let id = TextNormalizer.arxivID(raw) else { return nil }
    let first = id.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? id
    return first.isEmpty ? nil : first
}

private func rbA12_assemble(_ drafts: [rbA12_Draft], skipped: [String],
                            format: ZoteroMendeleyFormat, reviewState: ReviewState) -> ZMImportResult {
    var result = ZMImportResult()
    result.format = format
    result.skipped = skipped
    var index = 0
    for draft in drafts {
        index += 1
        if let entry = rbA12_finish(index: index, draft: draft, format: format, reviewState: reviewState) {
            result.entries.append(entry)
        } else {
            let label = draft.sourceID.isEmpty ? "Item \(index)" : "Item \(draft.sourceID)"
            result.skipped.append("\(label) has no title and was skipped.")
        }
    }
    return result
}

private func rbA12_finish(index: Int, draft d: rbA12_Draft, format: ZoteroMendeleyFormat,
                          reviewState: ReviewState) -> ZMImportEntry? {

    let title = rbA12_clean(d.title)
    guard !title.isEmpty else { return nil }

    var warnings: [String] = []

    let url = rbA12_clean(d.url)
    let doi = TextNormalizer.doi(d.doi)
    var arxiv = rbA12_arxivValue(d.arxiv)
    if arxiv == nil, url.lowercased().contains("arxiv.org/abs/") { arxiv = rbA12_arxivValue(url) }
    if arxiv == nil, let doi, doi.hasPrefix("10.48550/arxiv.") {
        arxiv = String(doi.dropFirst("10.48550/arxiv.".count))
    }

    let type: ItemType
    if let t = d.type {
        type = t
    } else {
        type = arxiv != nil ? .preprint : .article
        if !d.typeLabel.isEmpty {
            warnings.append("Type \"\(d.typeLabel)\" was not recognised; imported as \(type.displayName.lowercased()).")
        }
    }

    if d.creators.isEmpty { warnings.append("No authors were found.") }

    var year = d.year
    if year == nil {
        let dateText = rbA12_clean(d.dateText)
        if dateText.isEmpty { warnings.append("No year was found.") }
        else if let y = rbA12_firstYear(dateText) { year = y }
        else { warnings.append("Date \"\(dateText)\" was not understood and was left empty.") }
    }

    let venue = rbA12_clean(d.venue)
    if type == .article, venue.isEmpty { warnings.append("No journal name was found.") }
    if doi == nil && arxiv == nil && type != .book && type != .webpage {
        warnings.append("No DOI or arXiv ID; duplicates cannot be matched by identifier.")
    }

    var item = NewItem(title: title)
    item.type = type
    item.creators = d.creators
    item.year = year
    item.venue = venue
    item.abstract = rbA12_clean(d.abstract)
    item.volume = rbA12_clean(d.volume)
    item.issue = rbA12_clean(d.issue)
    item.pages = rbA12_clean(d.pages).replacingOccurrences(of: "--", with: "–")
    item.publisher = rbA12_clean(d.publisher)
    item.doi = doi
    item.arxivID = arxiv
    item.url = url
    item.sourceKind = .import
    item.sourceURL = ""
    item.reviewState = reviewState

    var seenTags = Set<String>()
    let tags = d.tags.map { rbA12_clean($0) }.filter { !$0.isEmpty && seenTags.insert($0.lowercased()).inserted }
    var seenFiles = Set<String>()
    let files = d.attachments.filter { !$0.isEmpty && seenFiles.insert($0).inserted }

    return ZMImportEntry(index: index, sourceID: d.sourceID, format: format, item: item,
                         warnings: warnings, tags: tags, attachmentHints: files,
                         collections: d.collections)
}

// MARK: - CSL JSON (private)

private func rbA12_str(_ value: Any?) -> String {
    switch value {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case let a as [Any]: return a.map { rbA12_str($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
    default: return ""
    }
}

private func rbA12_cslType(_ raw: String) -> ItemType? {
    switch raw {
    case "article-journal", "article-magazine", "article-newspaper", "entry-encyclopedia", "entry-dictionary", "entry": return .article
    case "article", "manuscript": return .preprint
    case "paper-conference": return .conference
    case "book": return .book
    case "chapter": return .chapter
    case "thesis": return .thesis
    case "report": return .report
    case "webpage", "post-weblog", "post": return .webpage
    case "dataset": return .dataset
    case "software": return .software
    default: return nil
    }
}

private func rbA12_cslPeople(_ value: Any?, role: CreatorRole) -> [CreatorInput] {
    guard let list = value as? [[String: Any]] else { return [] }
    var out: [CreatorInput] = []
    for p in list {
        let family = rbA12_clean(rbA12_str(p["family"]))
        let given = rbA12_clean(rbA12_str(p["given"]))
        let literal = rbA12_clean(rbA12_str(p["literal"]))
        let suffix = rbA12_clean(rbA12_str(p["suffix"]))
        let nonDropping = rbA12_clean(rbA12_str(p["non-dropping-particle"]))
        let dropping = rbA12_clean(rbA12_str(p["dropping-particle"]))

        if family.isEmpty, !literal.isEmpty {
            out.append(CreatorInput(family: literal, isOrganisation: true, role: role))
        } else if !family.isEmpty {
            let fullFamily = [nonDropping, family].filter { !$0.isEmpty }.joined(separator: " ")
            let fullGiven = [given, dropping].filter { !$0.isEmpty }.joined(separator: " ")
            out.append(CreatorInput(family: fullFamily, given: fullGiven, suffix: suffix, role: role))
        } else if !given.isEmpty {
            out.append(CreatorInput(family: given, role: role))
        }
    }
    return out
}

private func rbA12_cslDate(_ value: Any?) -> (Int?, String) {
    if let dict = value as? [String: Any] {
        if let parts = dict["date-parts"] as? [Any], let first = parts.first as? [Any], let y = first.first {
            if let year = Int(rbA12_str(y)), (0...9999).contains(year) { return (year, "") }
        }
        let raw = rbA12_str(dict["raw"]).isEmpty ? rbA12_str(dict["literal"]) : rbA12_str(dict["raw"])
        return (nil, raw)
    }
    return (nil, rbA12_str(value))
}

private func rbA12_cslDrafts(_ data: Data) -> ([rbA12_Draft], [String]) {
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        return ([], ["The file is not valid JSON."])
    }
    var objects: [[String: Any]] = []
    if let array = json as? [[String: Any]] { objects = array }
    else if let dict = json as? [String: Any] {
        if let items = dict["items"] as? [[String: Any]] { objects = items }
        else { objects = [dict] }
    }
    guard !objects.isEmpty else { return ([], ["No CSL items were found."]) }

    var drafts: [rbA12_Draft] = []
    for o in objects {
        var d = rbA12_Draft()
        d.sourceID = rbA12_str(o["id"])
        d.title = rbA12_str(o["title"])
        d.abstract = rbA12_str(o["abstract"])
        d.venue = rbA12_str(o["container-title"])
        d.volume = rbA12_str(o["volume"])
        d.issue = rbA12_str(o["issue"])
        d.pages = rbA12_str(o["page"])
        d.publisher = rbA12_str(o["publisher"])
        d.doi = rbA12_str(o["DOI"])
        d.url = rbA12_str(o["URL"])
        let typeRaw = rbA12_str(o["type"])
        d.type = rbA12_cslType(typeRaw)
        if d.type == nil { d.typeLabel = typeRaw }

        let (year, raw) = rbA12_cslDate(o["issued"])
        d.year = year
        d.dateText = raw
        if year == nil, raw.isEmpty { d.dateText = rbA12_str(o["year"]) }

        d.creators = rbA12_cslPeople(o["author"], role: .author)
            + rbA12_cslPeople(o["editor"], role: .editor)
            + rbA12_cslPeople(o["translator"], role: .translator)

        if rbA12_str(o["archive"]).lowercased() == "arxiv" {
            d.arxiv = rbA12_str(o["archive_location"]).isEmpty ? rbA12_str(o["number"]) : rbA12_str(o["archive_location"])
        }
        drafts.append(d)
    }
    return (drafts, [])
}

// MARK: - Zotero RDF (private)

private final class rbA12_Node {
    let name: String
    var attrs: [String: String]
    var text = ""
    var children: [rbA12_Node] = []

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func child(_ names: String...) -> rbA12_Node? {
        for c in children where names.contains(c.name) { return c }
        return nil
    }

    func childList(_ name: String) -> [rbA12_Node] { children.filter { $0.name == name } }

    func descendants(_ name: String) -> [rbA12_Node] {
        var out: [rbA12_Node] = []
        for c in children {
            if c.name == name { out.append(c) }
            out += c.descendants(name)
        }
        return out
    }

    /// Own text plus the text of everything below.
    func allText() -> [String] {
        var out: [String] = []
        if !text.isEmpty { out.append(text) }
        for c in children { out += c.allText() }
        return out
    }

    func firstText(_ names: String...) -> String {
        for c in children where names.contains(c.name) {
            let t = c.allText().first ?? ""
            if !t.isEmpty { return t }
        }
        return ""
    }
}

private final class rbA12_XMLBuilder: NSObject, XMLParserDelegate {
    var root: rbA12_Node?
    private var stack: [rbA12_Node] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = rbA12_Node(name: elementName, attrs: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if let node = stack.popLast() {
            node.text = rbA12_clean(node.text)
        }
    }
}

private func rbA12_rdfType(_ raw: String) -> ItemType? {
    switch raw {
    case "journalArticle", "magazineArticle", "newspaperArticle", "encyclopediaArticle", "dictionaryEntry": return .article
    case "conferencePaper": return .conference
    case "book": return .book
    case "bookSection": return .chapter
    case "thesis": return .thesis
    case "report": return .report
    case "webpage", "blogPost", "forumPost": return .webpage
    case "dataset": return .dataset
    case "computerProgram": return .software
    case "preprint", "manuscript": return .preprint
    default: return nil
    }
}

private func rbA12_rdfPeople(_ container: rbA12_Node?, role: CreatorRole) -> [CreatorInput] {
    guard let container else { return [] }
    var out: [CreatorInput] = []
    // Document order matters, so walk the list items.
    func visit(_ node: rbA12_Node) {
        if node.name == "foaf:Person" {
            let family = node.firstText("foaf:surname")
            let given = node.firstText("foaf:givenName", "foaf:givenname", "foaf:firstName")
            if !family.isEmpty { out.append(CreatorInput(family: family, given: given, role: role)) }
            else if !given.isEmpty { out.append(CreatorInput(family: given, role: role)) }
            return
        }
        if node.name == "foaf:Organization" {
            let name = node.firstText("foaf:name")
            if !name.isEmpty { out.append(CreatorInput(family: name, isOrganisation: true, role: role)) }
            return
        }
        for c in node.children { visit(c) }
    }
    visit(container)
    return out
}

private func rbA12_rdfDrafts(_ data: Data, baseURL: URL?) -> ([rbA12_Draft], [String]) {
    let builder = rbA12_XMLBuilder()
    let parser = XMLParser(data: data)
    parser.delegate = builder
    parser.shouldResolveExternalEntities = false
    let ok = parser.parse()
    guard let root = builder.root else { return ([], ["The file is not valid XML."]) }
    var skipped: [String] = []
    if !ok { skipped.append("The XML has errors; the part that could be read was used.") }

    // Look-ups by rdf:about for attachments and referenced parents.
    var byAbout: [String: rbA12_Node] = [:]
    for n in root.children { if let about = n.attrs["rdf:about"] { byAbout[about] = n } }

    func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") || path.contains("://") { return path }
        if let baseURL { return baseURL.appendingPathComponent(path).path }
        return path
    }

    var drafts: [rbA12_Draft] = []
    for node in root.children {
        guard let typeNode = node.child("z:itemType") else { continue }
        let typeName = typeNode.text
        if ["attachment", "note", "annotation"].contains(typeName) { continue }

        var d = rbA12_Draft()
        d.sourceID = node.attrs["rdf:about"] ?? ""
        d.type = rbA12_rdfType(typeName)
        if d.type == nil { d.typeLabel = typeName }
        d.title = node.firstText("dc:title")
        d.abstract = node.firstText("dcterms:abstract")
        d.dateText = node.firstText("dc:date")
        d.volume = node.firstText("prism:volume")
        d.issue = node.firstText("prism:number")
        d.pages = node.firstText("bib:pages", "prism:pageRange", "z:pages")

        // Publisher: a plain string or <foaf:Organization><foaf:name>.
        if let pub = node.child("dc:publisher") {
            let name = pub.descendants("foaf:name").first?.text ?? pub.text
            d.publisher = name
        }

        // Container (journal, proceedings, book) and the volume / issue / pages kept there.
        for part in node.childList("dcterms:isPartOf") {
            var holders = part.children
            if let ref = part.attrs["rdf:resource"], let target = byAbout[ref] { holders.append(target) }
            for holder in holders {
                if holder.name == "bib:Series" { continue }
                if d.venue.isEmpty { d.venue = holder.firstText("dc:title") }
                if d.volume.isEmpty { d.volume = holder.firstText("prism:volume") }
                if d.issue.isEmpty { d.issue = holder.firstText("prism:number") }
                if d.pages.isEmpty { d.pages = holder.firstText("bib:pages", "prism:pageRange", "z:pages") }
            }
        }

        // Identifiers: "DOI 10.x" text and URLs.
        for ident in node.childList("dc:identifier") {
            for t in ident.allText() {
                let lower = t.lowercased()
                if lower.hasPrefix("doi:") || lower.hasPrefix("doi ") {
                    let rest = t.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                    if d.doi == nil, !rest.isEmpty { d.doi = rest }
                } else if lower.hasPrefix("http") {
                    if d.url.isEmpty { d.url = t }
                } else if lower.hasPrefix("10."), d.doi == nil {
                    d.doi = t
                }
            }
        }

        d.creators = rbA12_rdfPeople(node.child("bib:authors"), role: .author)
            + rbA12_rdfPeople(node.child("bib:editors"), role: .editor)
            + rbA12_rdfPeople(node.child("z:translators"), role: .translator)

        for subject in node.childList("dc:subject") { d.tags += subject.allText() }

        for link in node.childList("link:link") {
            guard let ref = link.attrs["rdf:resource"], let att = byAbout[ref],
                  let file = att.child("rdf:resource")?.attrs["rdf:resource"], !file.isEmpty else { continue }
            d.attachments.append(resolvePath(file))
        }
        drafts.append(d)
    }
    return (drafts, skipped)
}

// MARK: - Zotero library (private)

private func rbA12_zoteroType(_ raw: String) -> ItemType? { rbA12_rdfType(raw) }

private func rbA12_zoteroRole(_ raw: String) -> CreatorRole {
    switch raw {
    case "editor", "seriesEditor": return .editor
    case "translator": return .translator
    default: return .author
    }
}

/// Reads "Key: value" lines from Zotero's Extra field.
private func rbA12_extraValue(_ extra: String?, _ key: String) -> String? {
    guard let extra else { return nil }
    for line in extra.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() {
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
    }
    return nil
}

private func rbA12_zoteroDrafts(_ db: rbA12_DB, dataDir: URL) throws -> ([rbA12_Draft], [String]) {

    let items = try db.query("""
        SELECT i.itemID AS id, i."key" AS itemKey, t.typeName AS typeName
        FROM items i JOIN itemTypes t ON t.itemTypeID = i.itemTypeID
        WHERE t.typeName NOT IN ('attachment', 'note', 'annotation')
          AND i.itemID NOT IN (SELECT itemID FROM deletedItems)
        ORDER BY i.itemID
        """)

    var fields: [String: [String: String]] = [:]
    for r in try db.query("""
        SELECT d.itemID AS id, f.fieldName AS field, v.value AS value
        FROM itemData d
        JOIN fields f ON f.fieldID = d.fieldID
        JOIN itemDataValues v ON v.valueID = d.valueID
        """) {
        if let id = r["id"], let field = r["field"], let value = r["value"] { fields[id, default: [:]][field] = value }
    }

    var people: [String: [CreatorInput]] = [:]
    for r in try db.query("""
        SELECT ic.itemID AS id, ct.creatorType AS role, c.firstName AS given, c.lastName AS family, c.fieldMode AS mode
        FROM itemCreators ic
        JOIN creators c ON c.creatorID = ic.creatorID
        JOIN creatorTypes ct ON ct.creatorTypeID = ic.creatorTypeID
        ORDER BY ic.itemID, ic.orderIndex
        """) {
        guard let id = r["id"] else { continue }
        let family = rbA12_clean(r["family"])
        let given = rbA12_clean(r["given"])
        let role = rbA12_zoteroRole(r["role"] ?? "author")
        if r["mode"] == "1" {
            if !family.isEmpty { people[id, default: []].append(CreatorInput(family: family, isOrganisation: true, role: role)) }
        } else if !family.isEmpty {
            people[id, default: []].append(CreatorInput(family: family, given: given, role: role))
        } else if !given.isEmpty {
            people[id, default: []].append(CreatorInput(family: given, role: role))
        }
    }

    // Tags and attachments are optional; an older library may lack the tables.
    var tags: [String: [String]] = [:]
    for r in (try? db.query("SELECT it.itemID AS id, t.name AS name FROM itemTags it JOIN tags t ON t.tagID = it.tagID")) ?? [] {
        if let id = r["id"], let name = r["name"] { tags[id, default: []].append(name) }
    }

    var files: [String: [String]] = [:]
    for r in (try? db.query("""
        SELECT a.parentItemID AS id, i."key" AS attKey, a.path AS path
        FROM itemAttachments a JOIN items i ON i.itemID = a.itemID
        WHERE a.parentItemID IS NOT NULL AND a.path IS NOT NULL
        """)) ?? [] {
        guard let id = r["id"], let path = r["path"], !path.isEmpty else { continue }
        if path.hasPrefix("storage:"), let key = r["attKey"] {
            let name = String(path.dropFirst("storage:".count))
            files[id, default: []].append(
                dataDir.appendingPathComponent("storage").appendingPathComponent(key).appendingPathComponent(name).path)
        } else if path.hasPrefix("/") {
            files[id, default: []].append(path)
        } else if !path.hasPrefix("attachments:") {
            files[id, default: []].append(path)
        }
    }

    // Zotero collections (folders), including sub-folders, as paths like "Parent/Child".
    var folderNames: [String: String] = [:]
    var folderParent: [String: String] = [:]
    var deletedFolders = Set<String>()
    for r in (try? db.query("SELECT collectionID AS id FROM deletedCollections")) ?? [] {
        if let id = r["id"] { deletedFolders.insert(id) }
    }
    for r in (try? db.query("SELECT collectionID AS id, collectionName AS name, parentCollectionID AS parent FROM collections")) ?? [] {
        guard let id = r["id"], let name = r["name"], !deletedFolders.contains(id) else { continue }
        folderNames[id] = rbA12_clean(name)
        if let parent = r["parent"], !parent.isEmpty { folderParent[id] = parent }
    }
    func folderPath(_ id: String) -> String? {
        var parts: [String] = []
        var current: String? = id
        var guardCount = 0
        while let c = current, guardCount < 30 {
            guard let name = folderNames[c], !name.isEmpty else { break }
            parts.insert(name.replacingOccurrences(of: "/", with: "-"), at: 0)
            current = folderParent[c]
            guardCount += 1
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
    var folders: [String: [String]] = [:]
    for r in (try? db.query("SELECT collectionID AS cid, itemID AS id FROM collectionItems")) ?? [] {
        if let cid = r["cid"], let id = r["id"], let path = folderPath(cid) { folders[id, default: []].append(path) }
    }

    var drafts: [rbA12_Draft] = []
    for item in items {
        guard let id = item["id"] else { continue }
        let f = fields[id] ?? [:]
        let typeName = item["typeName"] ?? ""

        var d = rbA12_Draft()
        d.sourceID = item["itemKey"] ?? id
        d.type = rbA12_zoteroType(typeName)
        if d.type == nil { d.typeLabel = typeName }
        d.title = f["title"] ?? ""
        d.abstract = f["abstractNote"] ?? ""
        func pick(_ keys: [String]) -> String {
            for k in keys { if let v = f[k], !v.isEmpty { return v } }
            return ""
        }
        d.venue = pick(["publicationTitle", "proceedingsTitle", "bookTitle", "websiteTitle", "blogTitle", "encyclopediaTitle"])
        if d.venue.isEmpty, typeName == "preprint" { d.venue = pick(["repository"]) }
        d.volume = f["volume"] ?? ""
        d.issue = f["issue"] ?? ""
        d.pages = f["pages"] ?? ""
        d.publisher = pick(["publisher", "university", "institution"])
        if d.publisher.isEmpty, typeName == "dataset" { d.publisher = pick(["repository"]) }
        d.dateText = f["date"] ?? ""
        d.url = f["url"] ?? ""
        d.doi = f["DOI"] ?? rbA12_extraValue(f["extra"], "DOI")
        d.arxiv = rbA12_extraValue(f["extra"], "arXiv")
        if d.arxiv == nil, (f["archiveID"] ?? "").lowercased().hasPrefix("arxiv:") { d.arxiv = f["archiveID"] }
        if d.arxiv == nil, (f["repository"] ?? "").lowercased() == "arxiv" { d.arxiv = f["archiveID"] }
        d.creators = people[id] ?? []
        d.tags = tags[id] ?? []
        d.attachments = files[id] ?? []
        d.collections = folders[id] ?? []
        drafts.append(d)
    }
    return (drafts, [])
}

// MARK: - Mendeley Desktop library (private)

private func rbA12_mendeleyType(_ raw: String) -> ItemType? {
    switch raw.lowercased() {
    case "journalarticle", "magazinearticle", "newspaperarticle", "encyclopediaarticle": return .article
    case "conferenceproceedings", "conferencepaper": return .conference
    case "book", "editedbook": return .book
    case "booksection": return .chapter
    case "thesis": return .thesis
    case "report": return .report
    case "webpage": return .webpage
    case "workingpaper", "manuscript": return .preprint
    case "computerprogram", "software": return .software
    case "generic": return .article
    default: return nil
    }
}

private func rbA12_mendeleyDrafts(_ db: rbA12_DB) throws -> ([rbA12_Draft], [String]) {

    let rows = try db.query("SELECT * FROM Documents ORDER BY rowid")

    var people: [String: [CreatorInput]] = [:]
    for r in try db.query("""
        SELECT documentId AS id, contribution AS role, firstNames AS given, lastName AS family
        FROM DocumentContributors ORDER BY documentId, rowid
        """) {
        guard let id = r["id"] else { continue }
        let role = (r["role"] ?? "").lowercased()
        let creatorRole: CreatorRole = role.contains("editor") ? .editor : role.contains("translat") ? .translator : .author
        let family = rbA12_clean(r["family"])
        let given = rbA12_clean(r["given"])
        if !family.isEmpty { people[id, default: []].append(CreatorInput(family: family, given: given, role: creatorRole)) }
        else if !given.isEmpty { people[id, default: []].append(CreatorInput(family: given, role: creatorRole)) }
    }

    var tags: [String: [String]] = [:]
    for r in (try? db.query("SELECT documentId AS id, tag AS name FROM DocumentTags")) ?? [] {
        if let id = r["id"], let name = r["name"] { tags[id, default: []].append(name) }
    }

    var files: [String: [String]] = [:]
    for r in (try? db.query("""
        SELECT df.documentId AS id, f.localUrl AS url
        FROM DocumentFiles df JOIN Files f ON f.hash = df.hash
        """)) ?? [] {
        guard let id = r["id"], let raw = r["url"], !raw.isEmpty else { continue }
        let path = URL(string: raw).flatMap { $0.isFileURL ? $0.path : nil } ?? raw
        files[id, default: []].append(path)
    }

    var drafts: [rbA12_Draft] = []
    for raw in rows {
        // Column names differ a little between versions, so look them up in lower case.
        var r: [String: String] = [:]
        for (k, v) in raw { r[k.lowercased()] = v }

        let pending = (r["deletionpending"] ?? "").lowercased()
        if pending == "true" || pending == "1" { continue }
        guard let id = r["id"] else { continue }

        var d = rbA12_Draft()
        d.sourceID = r["uuid"] ?? id
        let typeName = r["type"] ?? ""
        d.type = rbA12_mendeleyType(typeName)
        if d.type == nil { d.typeLabel = typeName }
        d.title = r["title"] ?? ""
        d.abstract = r["abstract"] ?? ""
        d.venue = r["publication"] ?? ""
        d.volume = r["volume"] ?? ""
        d.issue = r["issue"] ?? ""
        d.pages = r["pages"] ?? ""
        d.publisher = r["publisher"] ?? r["institution"] ?? ""
        d.doi = r["doi"]
        d.arxiv = r["arxiv"]
        d.url = (r["websites"] ?? "").split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == " " }).first.map(String.init) ?? ""
        if let y = r["year"], let year = Int(y.trimmingCharacters(in: .whitespaces)), (1...9999).contains(year) {
            d.year = year
        }
        d.creators = people[id] ?? []
        d.tags = tags[id] ?? []
        d.attachments = files[id] ?? []
        drafts.append(d)
    }
    return (drafts, [])
}
