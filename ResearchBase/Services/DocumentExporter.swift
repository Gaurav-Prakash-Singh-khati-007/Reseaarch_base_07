//
//  DocumentExporter.swift
//  ResearchBase
//
//  Owner: Agent 35 · Features: F-40 (export .tex project, PDF, Word, Markdown, plain text)
//
//  Turns a draft (a real folder of LaTeX files) into a file someone else can open.
//
//    .latexZip    the whole project as one .zip (main.tex, refs.bib, figures, chapters...).
//                 Build leftovers (.aux, .log, build folders) are left out; .bbl is kept for arXiv.
//    .pdf         a copy of the last successful build. Never compiles anything itself.
//    .docx        Word. Headings, lists, tables, footnotes, PNG/JPEG figures and equations
//                 (real Word equations) carry over; citations and the reference list use
//                 the citation formatter given at init.
//    .markdown    citations become [@key]; equations stay as $...$ / $$...$$.
//    .plainText   text only, no formatting.
//
//  How it reads LaTeX: \input / \include are expanded, comments dropped, then the text between
//  \begin{document} and \end{document} is converted. It understands the usual paper
//  vocabulary; anything it cannot convert is flattened to text and listed in
//  `ExportReport.warnings` so the person can check it. It does not run a TeX engine.
//
//  Citations: the exporter does not know CSL. Give it a `CitationProvider` (for example one
//  backed by CSLEngine); without one, `libraryCitations(model:)` gives a plain
//  "Author, Year" fallback read from the library by citation key.
//
//  Files are written to a temporary name first and moved into place, so a failed export
//  never leaves half a file at the destination.
//
//  PUBLIC API
//    ExportFormat                     latexZip | pdf | docx | markdown | plainText   (+ fileExtension, title)
//    CitationText                     key, author, year, inline, reference
//    typealias CitationProvider       (String) -> CitationText?
//    ExportReport                     outputURL, format, warnings, citedKeys
//    DocumentExportError              LocalizedError
//    DocumentExporter(citations:)
//      export(draftID:model:format:to:overwrite:)                         -> ExportReport
//      export(folder:mainFile:title:format:to:overwrite:pdfURL:)         -> ExportReport
//      static libraryCitations(model:)                                    -> CitationProvider
//      static suggestedFileName(title:format:)                            -> String
//      static findLastBuild(folder:mainFile:)                             -> URL?
//

import Foundation

// MARK: - Public types

enum ExportFormat: String, CaseIterable, Equatable {
    case latexZip, pdf, docx, markdown, plainText

    var fileExtension: String {
        switch self {
        case .latexZip: return "zip"
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .markdown: return "md"
        case .plainText: return "txt"
        }
    }

    var title: String {
        switch self {
        case .latexZip: return "LaTeX project (.zip)"
        case .pdf: return "PDF"
        case .docx: return "Word (.docx)"
        case .markdown: return "Markdown"
        case .plainText: return "Plain text"
        }
    }
}

struct CitationText: Equatable {
    var key: String
    /// "Smith", "Smith and Lee", "Smith et al."
    var author: String
    var year: String
    /// What goes between brackets: "Smith et al., 2020".
    var inline: String
    /// One entry of the reference list.
    var reference: String
}

typealias CitationProvider = (String) -> CitationText?

struct ExportReport: Equatable {
    var outputURL: URL
    var format: ExportFormat
    /// Things that could not be converted exactly. Shown to the person to check.
    var warnings: [String]
    /// Citation keys used in the text, in order of first use.
    var citedKeys: [String]
}

enum DocumentExportError: LocalizedError, Equatable {
    case folderMissing(String)
    case mainFileMissing(String)
    case noBuild
    case destinationExists(String)
    case unreadable(String)
    case tooLarge
    case draftNotFound(String)

    var errorDescription: String? {
        switch self {
        case .folderMissing(let path): return "The draft folder was not found: \(path)"
        case .mainFileMissing(let name): return "The main file \(name) was not found in the draft."
        case .noBuild: return "There is no successful PDF build yet. Build the draft first."
        case .destinationExists(let name): return "\(name) already exists."
        case .unreadable(let name): return "\(name) could not be read."
        case .tooLarge: return "The project is too large for a .zip file."
        case .draftNotFound(let id): return "Draft \(id) was not found."
        }
    }
}

// MARK: - Exporter

final class DocumentExporter {

    private let citations: CitationProvider

    init(citations: @escaping CitationProvider = { _ in nil }) {
        self.citations = citations
    }

    // MARK: Entry points

    /// Exports a draft stored in the library. `destination` nil = a new file in the library's exports folder.
    @discardableResult
    func export(
        draftID: String,
        model: LibraryModel,
        format: ExportFormat,
        to destination: URL? = nil,
        overwrite: Bool = false
    ) throws -> ExportReport {

        guard let row = try model.database.rows(
            "SELECT title, folder, main_file FROM drafts WHERE id = ? AND deleted_at IS NULL", [.text(draftID)]
        ).first, let folderPath = row.text("folder") else {
            throw DocumentExportError.draftNotFound(draftID)
        }

        let title = row.text("title") ?? "Draft"
        let folder = try model.library.url(forRelativePath: folderPath)

        let target = try destination ?? Self.freshURL(
            in: model.library.exportsURL, name: Self.suggestedFileName(title: title, format: format))

        return try export(
            folder: folder, mainFile: row.text("main_file") ?? "main.tex", title: title,
            format: format, to: target, overwrite: overwrite)
    }

    /// Exports any draft folder. Used by the library version above and directly by tests.
    @discardableResult
    func export(
        folder: URL,
        mainFile: String = "main.tex",
        title: String,
        format: ExportFormat,
        to destination: URL,
        overwrite: Bool = false,
        pdfURL: URL? = nil
    ) throws -> ExportReport {

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DocumentExportError.folderMissing(folder.path)
        }
        if FileManager.default.fileExists(atPath: destination.path), !overwrite {
            throw DocumentExportError.destinationExists(destination.lastPathComponent)
        }

        var warnings: [String] = []
        var cited: [String] = []

        switch format {

        case .latexZip:
            try Self.writeAtomically(to: destination) { temp in
                try Self.writeProjectZip(folder: folder, mainFile: mainFile, to: temp)
            }

        case .pdf:
            guard let source = pdfURL ?? Self.findLastBuild(folder: folder, mainFile: mainFile) else {
                throw DocumentExportError.noBuild
            }
            try Self.writeAtomically(to: destination) { temp in
                try? FileManager.default.removeItem(at: temp)
                try FileManager.default.copyItem(at: source, to: temp)
            }

        case .docx, .markdown, .plainText:
            let converter = LatexConverter(folder: folder, citations: citations)
            let document = try converter.convert(mainFile: mainFile, fallbackTitle: title)

            let data: Data
            switch format {
            case .docx: data = try DocxWriter(document: document, folder: folder).data()
            case .markdown: data = Data(MarkdownWriter(document: document).render().utf8)
            default: data = Data(TextWriter(document: document).render().utf8)
            }

            try Self.writeAtomically(to: destination) { temp in try data.write(to: temp) }

            warnings = document.context.warnings
            cited = document.context.cited
        }

        return ExportReport(outputURL: destination, format: format, warnings: warnings, citedKeys: cited)
    }

    // MARK: Helpers

    static func suggestedFileName(title: String, format: ExportFormat) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\0").union(.controlCharacters)
        var name = title.components(separatedBy: bad).joined(separator: " ")
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "Draft" }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name + "." + format.fileExtension
    }

    /// The newest PDF the last build left behind, or nil. Looks in build/, .build/, out/, output/ and the draft folder.
    static func findLastBuild(folder: URL, mainFile: String) -> URL? {
        let base = (mainFile as NSString).deletingPathExtension
        let candidates = ["build", ".build", "out", "output", "_build", ""].map { directory -> URL in
            let parent = directory.isEmpty ? folder : folder.appendingPathComponent(directory, isDirectory: true)
            return parent.appendingPathComponent(base + ".pdf")
        }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        return existing.max { modified($0) < modified($1) }
    }

    /// Plain "Author, Year" citations read from the library by citation key (a fallback when no CSL formatter is given).
    static func libraryCitations(model: LibraryModel) -> CitationProvider {
        return { key in
            guard let item = try? model.database.rows(
                """
                SELECT id, title, venue, year, volume, issue, pages, doi FROM items
                WHERE lower(citation_key) = lower(?) AND deleted_at IS NULL
                """, [.text(key)]).first,
                  let itemID = item.text("id") else { return nil }

            let creators = (try? model.database.rows(
                """
                SELECT c.family AS family, c.given AS given FROM item_creators ic
                JOIN creators c ON c.id = ic.creator_id
                WHERE ic.item_id = ? AND ic.role = 'author' ORDER BY ic.position
                """, [.text(itemID)])) ?? []

            let families = creators.compactMap { $0.text("family") }
            let author: String
            switch families.count {
            case 0: author = item.text("title") ?? key
            case 1: author = families[0]
            case 2: author = families[0] + " and " + families[1]
            default: author = families[0] + " et al."
            }

            let year = item.int("year").map { String($0) } ?? "n.d."

            let names = creators.map { row -> String in
                let family = row.text("family") ?? ""
                let initials = (row.text("given") ?? "").split(whereSeparator: { $0 == " " || $0 == "-" })
                    .compactMap { $0.first.map { "\($0)." } }.joined(separator: " ")
                return initials.isEmpty ? family : "\(family), \(initials)"
            }

            var reference = names.isEmpty ? "" : names.joined(separator: ", ") + " "
            reference += "(\(year)). \(item.text("title") ?? key)."
            if let venue = item.text("venue"), !venue.isEmpty {
                reference += " \(venue)"
                if let volume = item.text("volume"), !volume.isEmpty {
                    reference += ", \(volume)"
                    if let issue = item.text("issue"), !issue.isEmpty { reference += "(\(issue))" }
                }
                if let pages = item.text("pages"), !pages.isEmpty { reference += ", \(pages)" }
                reference += "."
            }
            if let doi = item.text("doi"), !doi.isEmpty { reference += " https://doi.org/\(doi)" }

            return CitationText(key: key, author: author, year: year, inline: "\(author), \(year)", reference: reference)
        }
    }

    // MARK: File writing

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func freshURL(in folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Runs `write` against a temporary file next to the destination, then moves it into place.
    private static func writeAtomically(to destination: URL, _ write: (URL) throws -> Void) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".export-\(UUID().uuidString).part")
        do {
            try write(temp)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try manager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? manager.removeItem(at: temp)
            throw error
        }
    }

    // MARK: LaTeX project zip

    private static let skippedExtensions: Set<String> = [
        "aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "blg", "bcf", "run.xml",
        "synctex", "synctex.gz", "nav", "snm", "vrb", "idx", "ilg", "ind", "ds_store"
    ]
    private static let skippedFolders: Set<String> = ["build", ".build", "_build", "out", "output", "auxil", "__macosx"]

    private static func writeProjectZip(folder: URL, mainFile: String, to temp: URL) throws {

        let mainURL = folder.appendingPathComponent(mainFile)
        guard FileManager.default.fileExists(atPath: mainURL.path) else {
            throw DocumentExportError.mainFileMissing(mainFile)
        }

        let builtPDF = (mainFile as NSString).deletingPathExtension + ".pdf"
        var entries: [(name: String, url: URL)] = []

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: []) else {
            throw DocumentExportError.folderMissing(folder.path)
        }

        let rootPath = folder.resolvingSymlinksInPath().path

        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))

            if name.hasPrefix(".") || values?.isSymbolicLink == true {
                if values?.isDirectory == true { walker.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                if skippedFolders.contains(name.lowercased()) { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let lower = name.lowercased()
            if skippedExtensions.contains((lower as NSString).pathExtension) || lower.hasSuffix(".synctex.gz") || lower.hasSuffix(".run.xml") { continue }

            var relative = url.resolvingSymlinksInPath().path
            if relative.hasPrefix(rootPath) { relative = String(relative.dropFirst(rootPath.count)) }
            relative = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            if relative == builtPDF { continue }          // the compiled PDF is not part of the source
            entries.append((relative, url))
        }

        entries.sort { $0.name < $1.name }

        let writer = try ZipWriter(url: temp)
        for entry in entries {
            guard let data = try? Data(contentsOf: entry.url) else { throw DocumentExportError.unreadable(entry.name) }
            try writer.add(name: entry.name, data: data, modified: modified(entry.url))
        }
        try writer.finish()
    }
}

// MARK: - ZIP writer (stored, no compression)

/// Smallest valid .zip writer: every file stored as-is, UTF-8 names, CRC-32 checked.
/// Word and every unzip tool read it. Used for the LaTeX project and the .docx package.
final class ZipWriter {

    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var position: UInt64 = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func add(name: String, data: Data, modified: Date = Date()) throws {

        guard data.count < Int(UInt32.max) / 2, position < UInt64(UInt32.max) / 2, entries.count < 60_000 else {
            throw DocumentExportError.tooLarge
        }

        let nameBytes = Array(name.utf8)
        let (dosTime, dosDate) = Self.dosStamp(modified)
        let entry = Entry(name: nameBytes, crc: Self.crc32(data), size: UInt32(data.count),
                          offset: UInt32(position), dosTime: dosTime, dosDate: dosDate)

        var header = Data()
        header.appendLE(UInt32(0x04034b50))
        header.appendLE(UInt16(20))               // version needed
        header.appendLE(UInt16(0x0800))           // flags: names are UTF-8
        header.appendLE(UInt16(0))                // method: stored
        header.appendLE(dosTime)
        header.appendLE(dosDate)
        header.appendLE(entry.crc)
        header.appendLE(entry.size)               // compressed size
        header.appendLE(entry.size)               // uncompressed size
        header.appendLE(UInt16(nameBytes.count))
        header.appendLE(UInt16(0))                // extra length
        header.append(contentsOf: nameBytes)

        try write(header)
        try write(data)
        entries.append(entry)
    }

    func finish() throws {

        let directoryStart = position
        var directory = Data()

        for entry in entries {
            directory.appendLE(UInt32(0x02014b50))
            directory.appendLE(UInt16(0x031E))     // made by: Unix, spec 3.0
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(entry.dosTime)
            directory.appendLE(entry.dosDate)
            directory.appendLE(entry.crc)
            directory.appendLE(entry.size)
            directory.appendLE(entry.size)
            directory.appendLE(UInt16(entry.name.count))
            directory.appendLE(UInt16(0))          // extra
            directory.appendLE(UInt16(0))          // comment
            directory.appendLE(UInt16(0))          // disk
            directory.appendLE(UInt16(0))          // internal attributes
            directory.appendLE(UInt32(0o100644) << 16)   // regular file, rw-r--r--
            directory.appendLE(entry.offset)
            directory.append(contentsOf: entry.name)
        }

        try write(directory)

        var end = Data()
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(directory.count))
        end.appendLE(UInt32(directoryStart))
        end.appendLE(UInt16(0))
        try write(end)

        try handle.close()
    }

    private func write(_ data: Data) throws {
        handle.write(data)
        position += UInt64(data.count)
    }

    private static func dosStamp(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year: Int = max((parts.year ?? 1980) - 1980, 0)
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = (parts.second ?? 0) / 2
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | second
        let stamp: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: stamp))
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1) }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }
    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}

// MARK: - Document model (what the LaTeX is turned into before writing)

fileprivate enum CiteKind { case paren, text, author, year, silent }

fileprivate indirect enum Inline {
    case text(String)
    case bold([Inline])
    case italic([Inline])
    case mono([Inline])
    case math(String)
    case cite(CiteKind, [String])
    case ref(String, paren: Bool)
    case footnote([Inline])
    case link(String, [Inline])
    case lineBreak
}

fileprivate struct TableCell {
    var content: [Inline]
    var span: Int
}

fileprivate indirect enum Block {
    case heading(level: Int, number: String?, text: [Inline])
    case paragraph([Inline])
    case math(tex: String, number: Int?)
    case list(ordered: Bool, items: [[Block]])
    case table(caption: [Inline]?, number: Int?, rows: [[TableCell]])
    case figure(path: String, caption: [Inline]?, number: Int?)
    case code(String)
    case quote([Block])
    case abstract([Block])
    case references
}

/// Shared by the converter and the writers: labels, citations, warnings.
fileprivate final class ExportContext {

    var warnings: [String] = []
    var cited: [String] = []
    var labels: [String: String] = [:]

    private let provider: CitationProvider
    private var cache: [String: CitationText] = [:]
    private var missing: Set<String> = []

    init(provider: @escaping CitationProvider) {
        self.provider = provider
    }

    func warn(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    func citation(_ key: String) -> CitationText? {
        if !cited.contains(key) { cited.append(key) }
        if let known = cache[key] { return known }
        if missing.contains(key) { return nil }
        if let found = provider(key) {
            cache[key] = found
            return found
        }
        missing.insert(key)
        warn("Citation key “\(key)” was not found in the library.")
        return nil
    }

    /// "(Smith, 2020; Lee, 2019)", "Smith (2020)", ...
    func citationText(_ kind: CiteKind, _ keys: [String]) -> String {
        let found = keys.map { ($0, citation($0)) }
        switch kind {
        case .silent: return ""
        case .paren: return "(" + found.map { $0.1?.inline ?? $0.0 }.joined(separator: "; ") + ")"
        case .text: return found.map { $0.1.map { "\($0.author) (\($0.year))" } ?? $0.0 }.joined(separator: ", ")
        case .author: return found.map { $0.1?.author ?? $0.0 }.joined(separator: ", ")
        case .year: return found.map { $0.1?.year ?? $0.0 }.joined(separator: ", ")
        }
    }

    func referenceNumber(_ label: String, paren: Bool) -> String {
        guard let number = labels[label] else {
            warn("Reference “\(label)” could not be resolved.")
            return "??"
        }
        return paren ? "(\(number))" : number
    }

    /// Reference list entries for the cited keys, alphabetical.
    func referenceList() -> [String] {
        cited.compactMap { cache[$0]?.reference }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

fileprivate struct LatexDocument {
    var title: String
    var authors: [String]
    var date: String?
    var blocks: [Block]
    var context: ExportContext
}

// MARK: - Low-level scanning helpers

fileprivate enum LX {

    static func hasPrefix(_ c: [Character], _ i: Int, _ s: String) -> Bool {
        let chars = Array(s)
        guard i >= 0, i + chars.count <= c.count else { return false }
        for k in 0..<chars.count where c[i + k] != chars[k] { return false }
        return true
    }

    static func find(_ c: [Character], _ s: String, from: Int) -> Int? {
        var i = max(from, 0)
        while i < c.count {
            if hasPrefix(c, i, s) { return i }
            i += 1
        }
        return nil
    }

    static func isLetter(_ ch: Character) -> Bool {
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch == "@"
    }

    /// `i` is at a backslash. Name is letters (with optional *) or a single symbol.
    static func commandName(_ c: [Character], _ i: Int) -> (name: String, end: Int) {
        var j = i + 1
        guard j < c.count else { return ("", j) }
        if isLetter(c[j]) {
            var name = ""
            while j < c.count, isLetter(c[j]) { name.append(c[j]); j += 1 }
            if j < c.count, c[j] == "*" { name.append("*"); j += 1 }
            return (name, j)
        }
        return (String(c[j]), j + 1)
    }

    static func matching(_ c: [Character], _ open: Int, _ o: Character = "{", _ cl: Character = "}") -> Int? {
        var depth = 0
        var j = open
        while j < c.count {
            let ch = c[j]
            if ch == "\\" { j += 2; continue }
            if ch == o { depth += 1 } else if ch == cl {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    static func skipSpaces(_ c: [Character], _ i: Int) -> Int {
        var j = i
        while j < c.count, c[j] == " " || c[j] == "\t" || c[j] == "\n" { j += 1 }
        return j
    }

    /// `[ ... ]` right after spaces, if present.
    static func optionalArg(_ c: [Character], _ i: Int) -> (value: String?, end: Int) {
        let j = skipSpaces(c, i)
        guard j < c.count, c[j] == "[", let close = matching(c, j, "[", "]") else { return (nil, i) }
        return (String(c[(j + 1)..<close]), close + 1)
    }

    /// `{ ... }` right after spaces, if present.
    static func group(_ c: [Character], _ i: Int) -> (value: String, end: Int)? {
        let j = skipSpaces(c, i)
        guard j < c.count, c[j] == "{", let close = matching(c, j) else { return nil }
        return (String(c[(j + 1)..<close]), close + 1)
    }

    /// Skips any `[..]` and up to `count` `{..}` arguments.
    static func skipArgs(_ c: [Character], _ i: Int, groups count: Int) -> Int {
        var j = i
        var taken = 0
        while true {
            let optional = optionalArg(c, j)
            if optional.value != nil { j = optional.end; continue }
            if taken < count, let g = group(c, j) { j = g.end; taken += 1; continue }
            return j
        }
    }

    /// Where `\end{name}` closing the environment that started before `from` is.
    static func environmentEnd(_ c: [Character], name: String, from: Int) -> (innerEnd: Int, after: Int)? {
        let begin = "\\begin{\(name)}"
        let end = "\\end{\(name)}"
        var depth = 1
        var j = from
        while j < c.count {
            if c[j] == "\\" {
                if hasPrefix(c, j, begin) { depth += 1; j += begin.count; continue }
                if hasPrefix(c, j, end) {
                    depth -= 1
                    if depth == 0 { return (j, j + end.count) }
                    j += end.count
                    continue
                }
                j += 2
                continue
            }
            j += 1
        }
        return nil
    }

    /// Splits at `\\` (rows) or `&` (cells), only outside braces.
    static func split(_ text: String, rows: Bool) -> [String] {
        let c = Array(text)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                if rows, i + 1 < c.count, c[i + 1] == "\\", depth == 0 {
                    parts.append(current); current = ""
                    i += 2
                    let optional = optionalArg(c, i)
                    if optional.value != nil { i = optional.end }
                    continue
                }
                current.append(ch)
                if i + 1 < c.count { current.append(c[i + 1]) }
                i += 2
                continue
            }
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
            if !rows, ch == "&", depth == 0 {
                parts.append(current); current = ""
                i += 1
                continue
            }
            current.append(ch)
            i += 1
        }
        parts.append(current)
        return parts
    }

    /// First `\name[opt]{arg}` in the text.
    static func argument(of name: String, in text: String) -> String? {
        let c = Array(text)
        var from = 0
        while let i = find(c, "\\" + name, from: from) {
            let end = i + name.count + 1
            if end < c.count, isLetter(c[end]) { from = end; continue }
            let afterOptional = optionalArg(c, end).end
            if let g = group(c, afterOptional) { return g.value }
            from = end
        }
        return nil
    }

    /// Removes `\name{...}` (with its argument) from the text.
    static func removing(_ name: String, from text: String) -> String {
        let c = Array(text)
        var out = ""
        var i = 0
        while i < c.count {
            if hasPrefix(c, i, "\\" + name), i + name.count + 1 < c.count, !isLetter(c[i + name.count + 1]),
               let g = group(c, i + name.count + 1) {
                i = g.end
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out
    }
}

// MARK: - LaTeX -> document model

fileprivate final class LatexConverter {

    private let folder: URL
    private let context: ExportContext

    private var counters = [0, 0, 0, 0, 0]
    private var figureCount = 0
    private var tableCount = 0
    private var equationCount = 0
    private var hasChapters = false
    private var appendix = false
    private var warnedCommands: Set<String> = []

    init(folder: URL, citations: @escaping CitationProvider) {
        self.folder = folder
        self.context = ExportContext(provider: citations)
    }

    // MARK: Entry

    func convert(mainFile: String, fallbackTitle: String) throws -> LatexDocument {

        guard let source = loadFile(mainFile, depth: 0) else {
            throw DocumentExportError.mainFileMissing(mainFile)
        }

        var body = source
        if let begin = source.range(of: "\\begin{document}") {
            body = String(source[begin.upperBound...])
            if let end = body.range(of: "\\end{document}", options: .backwards) {
                body = String(body[..<end.lowerBound])
            }
        }

        hasChapters = body.contains("\\chapter")

        let rawTitle = LX.argument(of: "title", in: source)
        let rawAuthor = LX.argument(of: "author", in: source)
        let rawDate = LX.argument(of: "date", in: source)

        var title = fallbackTitle
        if let rawTitle {
            let cleaned = plain(parseInlines(LX.removing("thanks", from: rawTitle)))
            if !cleaned.isEmpty { title = cleaned }
        }

        var authors: [String] = []
        if let rawAuthor {
            var text = LX.removing("thanks", from: rawAuthor)
            text = LX.removing("inst", from: text)
            for separator in ["\\and", "\\And", "\\\\"] { text = text.replacingOccurrences(of: separator, with: "\n") }
            authors = text.split(separator: "\n").map { plain(parseInlines(String($0))) }.filter { !$0.isEmpty }
        }

        var date: String?
        if let rawDate {
            let cleaned = plain(parseInlines(rawDate))
            if !cleaned.isEmpty { date = cleaned }
        }

        var blocks = parseBlocks(body)

        let hasMarker = blocks.contains { if case .references = $0 { return true } else { return false } }
        if !context.cited.isEmpty, !hasMarker { blocks.append(.references) }

        // Make sure every cited key is looked up (also those cited inside figure or table captions).
        for key in context.cited { _ = context.citation(key) }

        return LatexDocument(title: title, authors: authors, date: date, blocks: blocks, context: context)
    }

    // MARK: Reading files

    private func loadFile(_ relative: String, depth: Int) -> String? {

        var path = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if (path as NSString).pathExtension.isEmpty { path += ".tex" }
        guard !path.hasPrefix("/"), !path.contains("..") else { return nil }

        guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { return nil }

        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return expandInputs(stripComments(text), depth: depth)
    }

    private func stripComments(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var escaped = false
            for ch in line {
                if escaped { kept.append(ch); escaped = false; continue }
                if ch == "\\" { kept.append(ch); escaped = true; continue }
                if ch == "%" { break }
                kept.append(ch)
            }
            lines.append(kept)
        }
        return lines.joined(separator: "\n")
    }

    private func expandInputs(_ text: String, depth: Int) -> String {

        let c = Array(text)
        var out = ""
        var i = 0

        while i < c.count {
            if c[i] == "\\" {
                let (name, end) = LX.commandName(c, i)
                if ["input", "include", "subfile"].contains(name), let g = LX.group(c, end) {
                    if depth < 8, let inner = loadFile(g.value, depth: depth + 1) {
                        out += "\n\n" + inner + "\n\n"
                    } else {
                        context.warn("The file “\(g.value)” could not be included.")
                    }
                    i = g.end
                    continue
                }
                out.append(contentsOf: c[i..<end])
                i = end
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out
    }

    // MARK: Blocks

    private static let skipWithArgs: [String: Int] = [
        "bibliographystyle": 1, "pagestyle": 1, "thispagestyle": 1, "setlength": 2, "usepackage": 1,
        "documentclass": 1, "newcommand": 2, "renewcommand": 2, "providecommand": 2, "def": 0,
        "graphicspath": 1, "hypersetup": 1, "addbibresource": 1, "vspace": 1, "vspace*": 1, "hspace": 1,
        "vskip": 0, "setcounter": 2, "addtocounter": 2, "label": 1, "title": 1, "author": 1, "date": 1,
        "thanks": 1, "bigskip": 0, "medskip": 0, "smallskip": 0, "maketitle": 0, "tableofcontents": 0,
        "listoffigures": 0, "listoftables": 0, "newpage": 0, "clearpage": 0, "pagebreak": 0, "centering": 0,
        "raggedright": 0, "raggedleft": 0, "noindent": 0, "indent": 0, "frontmatter": 0, "mainmatter": 0,
        "backmatter": 0, "pagenumbering": 1, "linespread": 1, "newtheorem": 2, "newtheorem*": 2,
        "bibliographystyle*": 1, "captionsetup": 1, "geometry": 1, "fancyhf": 0, "lhead": 1, "rhead": 1,
        "cfoot": 1, "lfoot": 1, "rfoot": 1, "DeclareMathOperator": 2, "setcounter*": 2
    ]

    private static let theoremLike: [String: String] = [
        "theorem": "Theorem", "lemma": "Lemma", "proposition": "Proposition", "corollary": "Corollary",
        "definition": "Definition", "remark": "Remark", "example": "Example", "proof": "Proof",
        "claim": "Claim", "assumption": "Assumption", "conjecture": "Conjecture", "note": "Note"
    ]

    private static let passThrough: Set<String> = [
        "center", "flushleft", "flushright", "minipage", "small", "footnotesize", "large", "sloppypar",
        "spacing", "adjustbox", "samepage", "tiny", "scriptsize", "normalsize", "Large", "doublespace",
        "singlespace", "subfigure", "wrapfigure", "multicols", "frame", "algorithm", "algorithmic", "resizebox"
    ]

    private func parseBlocks(_ text: String) -> [Block] {

        let c = Array(text)
        var blocks: [Block] = []
        var paragraph = ""
        var i = 0

        func flush() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = ""
            if !trimmed.isEmpty { blocks.append(.paragraph(parseInlines(trimmed))) }
        }

        while i < c.count {
            let ch = c[i]

            if ch == "\n" {
                var j = i + 1
                while j < c.count, c[j] == " " || c[j] == "\t" { j += 1 }
                if j < c.count, c[j] == "\n" {
                    flush()
                    i = j
                } else {
                    paragraph.append("\n")
                    i += 1
                }
                continue
            }

            if ch == "$", i + 1 < c.count, c[i + 1] == "$" {
                if let close = LX.find(c, "$$", from: i + 2) {
                    flush()
                    blocks.append(contentsOf: displayMath(String(c[(i + 2)..<close]), numbered: false, allLines: false))
                    i = close + 2
                    continue
                }
            }

            guard ch == "\\" else {
                paragraph.append(ch)
                i += 1
                continue
            }

            let (name, end) = LX.commandName(c, i)

            switch name {

            case "begin":
                guard let g = LX.group(c, end) else { paragraph.append("\\begin"); i = end; continue }
                flush()
                i = parseEnvironment(c, name: g.value, after: g.end, into: &blocks)

            case "[":
                if let close = LX.find(c, "\\]", from: end) {
                    flush()
                    blocks.append(contentsOf: displayMath(String(c[end..<close]), numbered: false, allLines: false))
                    i = close + 2
                } else {
                    paragraph.append("\\["); i = end
                }

            case "chapter", "chapter*", "section", "section*", "subsection", "subsection*",
                 "subsubsection", "subsubsection*", "paragraph", "paragraph*", "subparagraph", "part", "part*":
                flush()
                i = parseHeading(c, name: name, after: end, into: &blocks)

            case "appendix":
                flush()
                appendix = true
                counters = [0, 0, 0, 0, 0]
                i = end

            case "bibliography", "printbibliography":
                flush()
                blocks.append(.references)
                i = LX.skipArgs(c, end, groups: 1)

            case "item":
                paragraph.append("\\item")
                i = end

            default:
                if let count = Self.skipWithArgs[name] {
                    i = LX.skipArgs(c, end, groups: count)
                } else {
                    paragraph.append(contentsOf: c[i..<end])
                    i = end
                }
            }
        }

        flush()
        return blocks
    }

    // MARK: Headings

    private func parseHeading(_ c: [Character], name: String, after: Int, into blocks: inout [Block]) -> Int {

        let starred = name.hasSuffix("*")
        let base = starred ? String(name.dropLast()) : name

        var j = LX.optionalArg(c, after).end
        guard let g = LX.group(c, j) else { return after }
        j = g.end

        var level: Int
        switch base {
        case "part", "chapter": level = 1
        case "section": level = hasChapters ? 2 : 1
        case "subsection": level = hasChapters ? 3 : 2
        case "subsubsection": level = hasChapters ? 4 : 3
        default: level = hasChapters ? 5 : 4
        }
        level = min(level, 5)

        var number: String?
        if !starred, base != "paragraph", base != "subparagraph", base != "part" {
            number = nextHeadingNumber(level: level)
        }

        // A \label right after the heading names this number.
        let k = LX.skipSpaces(c, j)
        if LX.hasPrefix(c, k, "\\label{"), let label = LX.group(c, k + 6) {
            if let number { context.labels[label.value] = number }
            j = label.end
        }

        blocks.append(.heading(level: level, number: number, text: parseInlines(g.value)))
        return j
    }

    private func nextHeadingNumber(level: Int) -> String {
        counters[level - 1] += 1
        for deeper in level..<counters.count { counters[deeper] = 0 }

        var parts: [String] = []
        for index in 0..<level {
            let value = counters[index]
            if index == 0, appendix, let scalar = UnicodeScalar(64 + max(value, 1)) {
                parts.append(String(Character(scalar)))
            } else {
                parts.append(String(value))
            }
        }
        return parts.joined(separator: ".")
    }

    // MARK: Environments

    private func parseEnvironment(_ c: [Character], name: String, after: Int, into blocks: inout [Block]) -> Int {

        // Arguments that follow \begin{name}
        var j = after
        var args: [String] = []
        let optional = LX.optionalArg(c, j)
        if optional.value != nil { j = optional.end }

        let groupCount: Int
        switch name {
        case "tabular", "longtable", "minipage", "multicols", "adjustbox", "tabular*", "tabularx", "wrapfigure": groupCount = name.hasSuffix("*") || name == "tabularx" ? 2 : 1
        default: groupCount = 0
        }
        for _ in 0..<groupCount {
            if let g = LX.group(c, j) { args.append(g.value); j = g.end }
        }
        if name == "theorem" || Self.theoremLike[name] != nil {
            let more = LX.optionalArg(c, j)
            if more.value != nil { j = more.end }
        }

        guard let close = LX.environmentEnd(c, name: name, from: j) else {
            context.warn("The environment “\(name)” is not closed.")
            return c.count
        }

        let inner = String(c[j..<close.innerEnd])

        switch name {

        case "abstract":
            blocks.append(.abstract(parseBlocks(inner)))

        case "itemize", "enumerate", "description":
            blocks.append(parseList(inner, ordered: name == "enumerate", description: name == "description"))

        case "equation", "equation*", "displaymath", "math":
            blocks.append(contentsOf: displayMath(inner, numbered: !name.hasSuffix("*") && name != "displaymath" && name != "math", allLines: false))

        case "align", "align*", "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*",
             "flalign", "flalign*", "alignat", "alignat*":
            blocks.append(contentsOf: displayMath(inner, numbered: !name.hasSuffix("*"), allLines: true))

        case "figure", "figure*":
            blocks.append(contentsOf: parseFigure(inner))

        case "table", "table*":
            blocks.append(parseTableFloat(inner))

        case "tabular", "tabular*", "tabularx", "longtable":
            blocks.append(.table(caption: nil, number: nil, rows: parseTable(inner)))

        case "verbatim", "Verbatim", "lstlisting", "minted":
            blocks.append(.code(inner.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))))

        case "quote", "quotation":
            blocks.append(.quote(parseBlocks(inner)))

        case "thebibliography":
            break

        default:
            if let label = Self.theoremLike[name] ?? Self.theoremLike[name.replacingOccurrences(of: "*", with: "")] {
                var inside = parseBlocks(inner)
                let prefix: [Inline] = [.bold([.text(label + ".")]), .text(" ")]
                if let first = inside.first, case .paragraph(let inlines) = first {
                    inside[0] = .paragraph(prefix + inlines)
                } else {
                    inside.insert(.paragraph(prefix), at: 0)
                }
                blocks.append(contentsOf: inside)
            } else {
                if !Self.passThrough.contains(name) {
                    context.warn("The environment “\(name)” was flattened to plain text.")
                }
                blocks.append(contentsOf: parseBlocks(inner))
            }
        }

        return close.after
    }

    private func parseList(_ inner: String, ordered: Bool, description: Bool) -> Block {

        let c = Array(inner)
        var items: [[Block]] = []
        var current: String?
        var label: String?
        var depth = 0
        var i = 0

        func close() {
            guard let text = current else { return }
            var blocks = parseBlocks(text)
            if let label, !label.isEmpty {
                let prefix: [Inline] = [.bold(parseInlines(label)), .text(" ")]
                if let first = blocks.first, case .paragraph(let inlines) = first {
                    blocks[0] = .paragraph(prefix + inlines)
                } else {
                    blocks.insert(.paragraph(prefix), at: 0)
                }
            }
            items.append(blocks)
            current = nil
            label = nil
        }

        while i < c.count {
            if c[i] == "\\" {
                if LX.hasPrefix(c, i, "\\begin{") { depth += 1 }
                if LX.hasPrefix(c, i, "\\end{") { depth -= 1 }
                if depth == 0, LX.hasPrefix(c, i, "\\item"), i + 5 >= c.count || !LX.isLetter(c[i + 5]) {
                    close()
                    current = ""
                    var j = i + 5
                    let optional = LX.optionalArg(c, j)
                    if let value = optional.value { label = description ? value : nil; j = optional.end }
                    i = j
                    continue
                }
                if current != nil, i + 1 < c.count {
                    current!.append(c[i]); current!.append(c[i + 1])
                    i += 2
                    continue
                }
                i += 2
                continue
            }
            if current != nil { current!.append(c[i]) }
            i += 1
        }
        close()

        return .list(ordered: ordered, items: items)
    }

    // MARK: Math blocks

    private func displayMath(_ raw: String, numbered: Bool, allLines: Bool) -> [Block] {

        var text = raw
        for wrapper in ["aligned", "split", "gathered", "alignedat"] {
            text = text.replacingOccurrences(of: "\\begin{\(wrapper)}", with: "")
            text = text.replacingOccurrences(of: "\\end{\(wrapper)}", with: "")
        }

        let lines = LX.split(text, rows: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [Block] = []

        for (index, line) in lines.enumerated() {
            var tex = line.replacingOccurrences(of: "&", with: " ")
            var label: String?
            var suppressed = false

            let chars = Array(tex)
            if let l = LX.find(chars, "\\label{", from: 0), let g = LX.group(chars, l + 6) {
                label = g.value
                tex = LX.removing("label", from: tex)
            }
            for marker in ["\\nonumber", "\\notag"] where tex.contains(marker) {
                suppressed = true
                tex = tex.replacingOccurrences(of: marker, with: "")
            }

            let wantsNumber = numbered && !suppressed && (allLines || index == lines.count - 1)

            var number: Int?
            if wantsNumber {
                equationCount += 1
                number = equationCount
                if let label { context.labels[label] = String(equationCount) }
            }
            result.append(.math(tex: tex.trimmingCharacters(in: .whitespacesAndNewlines), number: number))
        }
        return result
    }

    // MARK: Figures and tables

    private func caption(in inner: String) -> [Inline]? {
        let c = Array(inner)
        var last: String?
        var from = 0
        while let i = LX.find(c, "\\caption", from: from) {
            let end = i + 8
            let afterOptional = LX.optionalArg(c, end).end
            if let g = LX.group(c, afterOptional) { last = g.value; from = g.end } else { from = end }
        }
        return last.map { parseInlines($0) }
    }

    private func firstLabel(in inner: String) -> String? {
        let c = Array(inner)
        guard let i = LX.find(c, "\\label{", from: 0), let g = LX.group(c, i + 6) else { return nil }
        return g.value
    }

    private func parseFigure(_ inner: String) -> [Block] {

        figureCount += 1
        if let label = firstLabel(in: inner) { context.labels[label] = String(figureCount) }

        let c = Array(inner)
        var paths: [String] = []
        var from = 0
        while let i = LX.find(c, "\\includegraphics", from: from) {
            let afterOptional = LX.optionalArg(c, i + 16).end
            if let g = LX.group(c, afterOptional) { paths.append(g.value.trimmingCharacters(in: .whitespaces)); from = g.end } else { from = i + 16 }
        }

        let figureCaption = caption(in: inner)

        if paths.isEmpty {
            context.warn("Figure \(figureCount) has no image to export.")
            guard let figureCaption else { return [] }
            return [Block.figure(path: "", caption: figureCaption, number: figureCount)]
        }

        return paths.enumerated().map { (index: Int, path: String) -> Block in
            let last = index == paths.count - 1
            return Block.figure(path: path, caption: last ? figureCaption : nil, number: last ? figureCount : nil)
        }
    }

    private func parseTableFloat(_ inner: String) -> Block {

        tableCount += 1
        if let label = firstLabel(in: inner) { context.labels[label] = String(tableCount) }

        let c = Array(inner)
        var rows: [[TableCell]] = []

        for name in ["tabularx", "tabular*", "tabular", "longtable"] {
            if let start = LX.find(c, "\\begin{\(name)}", from: 0) {
                var j = start + name.count + 8
                let optional = LX.optionalArg(c, j)
                if optional.value != nil { j = optional.end }
                for _ in 0..<((name == "tabularx" || name == "tabular*") ? 2 : 1) {
                    if let g = LX.group(c, j) { j = g.end }
                }
                if let close = LX.environmentEnd(c, name: name, from: j) {
                    rows = parseTable(String(c[j..<close.innerEnd]))
                }
                break
            }
        }

        if rows.isEmpty { context.warn("Table \(tableCount) could not be converted.") }
        return .table(caption: caption(in: inner), number: tableCount, rows: rows)
    }

    private func parseTable(_ inner: String) -> [[TableCell]] {

        var text = inner
        for rule in ["\\hline", "\\toprule", "\\midrule", "\\bottomrule", "\\endhead", "\\endfirsthead",
                     "\\endfoot", "\\endlastfoot", "\\addlinespace", "\\noalign{}"] {
            text = text.replacingOccurrences(of: rule, with: "")
        }
        text = LX.removing("cline", from: text)
        text = LX.removing("cmidrule", from: text)

        var rows: [[TableCell]] = []

        for rowText in LX.split(text, rows: true) {
            if rowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            var cells: [TableCell] = []

            for cellText in LX.split(rowText, rows: false) {
                var content = cellText.trimmingCharacters(in: .whitespacesAndNewlines)
                var span = 1

                let c = Array(content)
                if LX.hasPrefix(c, 0, "\\multicolumn"), let n = LX.group(c, 12), LX.group(c, n.end) != nil,
                   let specEnd = LX.group(c, n.end), let body = LX.group(c, specEnd.end) {
                    span = max(Int(n.value.trimmingCharacters(in: .whitespaces)) ?? 1, 1)
                    content = body.value
                } else if LX.hasPrefix(c, 0, "\\multirow"), let rows = LX.group(c, 9), let width = LX.group(c, rows.end),
                          let body = LX.group(c, width.end) {
                    content = body.value
                }
                cells.append(TableCell(content: parseInlines(content), span: span))
            }
            rows.append(cells)
        }
        return rows
    }
}

// MARK: - Inline text

extension LatexConverter {

    fileprivate static let accents: [Character: String] = [
        "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}", "~": "\u{0303}",
        "=": "\u{0304}", ".": "\u{0307}", "c": "\u{0327}", "v": "\u{030C}", "u": "\u{0306}", "H": "\u{030B}"
    ]

    fileprivate static let specialLetters: [String: String] = [
        "ss": "ß", "o": "ø", "O": "Ø", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "l": "ł", "L": "Ł",
        "i": "ı", "j": "ȷ", "aa": "å", "AA": "Å"
    ]

    fileprivate static let citeKinds: [String: CiteKind] = [
        "cite": .paren, "citep": .paren, "parencite": .paren, "autocite": .paren, "footcite": .paren,
        "citealp": .paren, "citet": .text, "textcite": .text, "citealt": .text, "citeauthor": .author,
        "citeyear": .year, "citeyearpar": .year, "nocite": .silent, "Cite": .paren, "Citep": .paren, "Citet": .text
    ]

    fileprivate static let refNames: Set<String> = ["ref", "eqref", "autoref", "cref", "Cref", "vref", "pageref", "nameref"]

    fileprivate static let styleWrappers: [String: (([Inline]) -> Inline)?] = [
        "textbf": { .bold($0) }, "textit": { .italic($0) }, "emph": { .italic($0) }, "textsl": { .italic($0) },
        "texttt": { .mono($0) }, "textsc": nil, "textrm": nil, "textsf": nil, "underline": nil, "mbox": nil,
        "hbox": nil, "text": nil, "textnormal": nil, "uppercase": nil, "MakeUppercase": nil, "textup": nil,
        "bfseries": nil, "mathrm": nil, "mathbf": { .bold($0) }, "mathit": { .italic($0) }
    ]

    fileprivate static let fontSwitches: [(String, (([Inline]) -> Inline)?)] = [
        ("\\bfseries", { .bold($0) }), ("\\bf", { .bold($0) }), ("\\itshape", { .italic($0) }), ("\\it", { .italic($0) }),
        ("\\em", { .italic($0) }), ("\\slshape", { .italic($0) }), ("\\sl", { .italic($0) }), ("\\ttfamily", { .mono($0) }),
        ("\\tt", { .mono($0) }), ("\\scshape", nil), ("\\sc", nil), ("\\rmfamily", nil), ("\\rm", nil), ("\\sffamily", nil),
        ("\\sf", nil), ("\\small", nil), ("\\large", nil), ("\\Large", nil), ("\\LARGE", nil), ("\\footnotesize", nil),
        ("\\normalsize", nil), ("\\tiny", nil), ("\\scriptsize", nil), ("\\huge", nil), ("\\Huge", nil), ("\\centering", nil)
    ]

    fileprivate static let ignoredInline: [String: Int] = [
        "noindent": 0, "indent": 0, "centering": 0, "raggedright": 0, "small": 0, "large": 0, "Large": 0,
        "footnotesize": 0, "normalsize": 0, "bfseries": 0, "itshape": 0, "relax": 0, "vspace": 1, "vspace*": 1,
        "hspace": 1, "hspace*": 1, "vskip": 0, "smallskip": 0, "medskip": 0, "bigskip": 0, "label": 1, "index": 1,
        "newpage": 0, "clearpage": 0, "pagebreak": 0, "protect": 0, "xspace": 0, "ignorespaces": 0, "hfill": 0, "vfill": 0
    ]

    fileprivate func parseInlines(_ text: String) -> [Inline] {

        let c = Array(text)
        var out: [Inline] = []
        var buffer = ""
        var i = 0

        func flush() {
            if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
        }

        while i < c.count {
            let ch = c[i]

            switch ch {

            case "\\":
                let (name, end) = LX.commandName(c, i)
                i = end

                switch name {

                case "\\":
                    flush(); out.append(.lineBreak)
                    i = LX.optionalArg(c, i).end

                case "&", "%", "$", "#", "_", "{", "}":
                    buffer.append(name)
                case " ", ",", ";", ":", "quad", "qquad", "enspace", "thinspace", "space":
                    buffer.append(" ")
                case "!", "-", "/", "@", "|":
                    break
                case "ldots", "dots", "textellipsis", "cdots":
                    buffer.append("…")
                case "textbackslash": buffer.append("\\")
                case "textasciitilde": buffer.append("~")
                case "textasciicircum": buffer.append("^")
                case "LaTeX": buffer.append("LaTeX")
                case "TeX": buffer.append("TeX")
                case "today": buffer.append(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none))
                case "textendash": buffer.append("–")
                case "textemdash": buffer.append("—")
                case "textquotedblleft": buffer.append("“")
                case "textquotedblright": buffer.append("”")
                case "textquoteleft": buffer.append("‘")
                case "textquoteright": buffer.append("’")
                case "textdegree": buffer.append("°")
                case "texttimes": buffer.append("×")
                case "newline", "linebreak":
                    flush(); out.append(.lineBreak)

                case "(":
                    if let close = LX.find(c, "\\)", from: i) {
                        flush(); out.append(.math(String(c[i..<close]))); i = close + 2
                    }

                case "ensuremath":
                    if let g = LX.group(c, i) { flush(); out.append(.math(g.value)); i = g.end }

                case "footnote", "footnotetext":
                    let afterOptional = LX.optionalArg(c, i).end
                    if let g = LX.group(c, afterOptional) {
                        flush(); out.append(.footnote(parseInlines(g.value))); i = g.end
                    }

                case "url":
                    if let g = LX.group(c, i) { flush(); out.append(.link(g.value, [.text(g.value)])); i = g.end }

                case "href":
                    if let target = LX.group(c, i), let label = LX.group(c, target.end) {
                        flush(); out.append(.link(target.value, parseInlines(label.value))); i = label.end
                    }

                case "includegraphics":
                    i = LX.skipArgs(c, i, groups: 1)

                default:
                    if let kind = Self.citeKinds[name] {
                        var j = LX.optionalArg(c, i).end
                        j = LX.optionalArg(c, j).end
                        if let g = LX.group(c, j) {
                            let keys = g.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            for key in keys { _ = context.citation(key) }   // register now so the reference list is added
                            flush(); out.append(.cite(kind, keys)); i = g.end
                        }
                    } else if Self.refNames.contains(name) {
                        if let g = LX.group(c, i) {
                            flush(); out.append(.ref(g.value.trimmingCharacters(in: .whitespaces), paren: name == "eqref")); i = g.end
                        }
                    } else if let wrapper = Self.styleWrappers[name] {
                        if let g = LX.group(c, i) {
                            let inner = parseInlines(g.value)
                            flush()
                            if let wrap = wrapper { out.append(wrap(inner)) } else { out.append(contentsOf: inner) }
                            i = g.end
                        }
                    } else if let skip = Self.ignoredInline[name] {
                        i = LX.skipArgs(c, i, groups: skip)
                    } else if name.count == 1, let first = name.first, !LX.isLetter(first), let accent = Self.accents[first] {
                        // \'e  \"{o}  \~n ...
                        var letter = ""
                        if i < c.count, c[i] == "{", let g = LX.group(c, i) {
                            letter = g.value; i = g.end
                        } else if i < c.count, c[i] != "\\" {
                            letter = String(c[i]); i += 1
                        }
                        buffer.append((String(letter.prefix(1)) + accent + String(letter.dropFirst())).precomposedStringWithCanonicalMapping)
                    } else if ["c", "v", "u", "H"].contains(name), let accent = Self.accents[Character(name)] {
                        // \c c   \v{s} ...
                        let j = LX.skipSpaces(c, i)
                        var letter = ""
                        if j < c.count, c[j] == "{", let g = LX.group(c, j) {
                            letter = g.value; i = g.end
                        } else if j < c.count {
                            letter = String(c[j]); i = j + 1
                        }
                        buffer.append((String(letter.prefix(1)) + accent + String(letter.dropFirst())).precomposedStringWithCanonicalMapping)
                    } else if let letter = Self.specialLetters[name] {
                        buffer.append(letter)
                        if i < c.count, c[i] == "{", i + 1 < c.count, c[i + 1] == "}" { i += 2 }
                    } else if let g = LX.group(c, i), name.count > 1 {
                        // unknown command with an argument: keep the argument's text
                        context.warn("The command \\\(name) is not supported; its text was kept.")
                        flush(); out.append(contentsOf: parseInlines(g.value)); i = g.end
                    } else if name.count > 1 {
                        context.warn("The command \\\(name) is not supported and was dropped.")
                    }
                }

            case "$":
                var j = i + 1
                let double = j < c.count && c[j] == "$"
                if double { j += 1 }
                var close: Int?
                var k = j
                while k < c.count {
                    if c[k] == "\\" { k += 2; continue }
                    if c[k] == "$" { close = k; break }
                    k += 1
                }
                if let close {
                    flush(); out.append(.math(String(c[j..<close])))
                    i = close + (double ? 2 : 1)
                } else {
                    buffer.append("$"); i += 1
                }

            case "{":
                if let close = LX.matching(c, i) {
                    var inner = String(c[(i + 1)..<close])
                    var wrap: (([Inline]) -> Inline)?
                    let trimmed = inner.trimmingCharacters(in: .whitespaces)
                    for (switchName, wrapper) in Self.fontSwitches where trimmed.hasPrefix(switchName) {
                        let after = trimmed.dropFirst(switchName.count).first
                        if after == nil || !LX.isLetter(after!) {
                            inner = String(trimmed.dropFirst(switchName.count))
                            wrap = wrapper
                            break
                        }
                    }
                    let parsed = parseInlines(inner)
                    flush()
                    if let wrap { out.append(wrap(parsed)) } else { out.append(contentsOf: parsed) }
                    i = close + 1
                } else {
                    i += 1
                }

            case "}":
                i += 1

            case "~":
                buffer.append("\u{00A0}"); i += 1

            case "-":
                var dashes = 0
                while i < c.count, c[i] == "-" { dashes += 1; i += 1 }
                buffer.append(dashes >= 3 ? "—" : (dashes == 2 ? "–" : String(repeating: "-", count: dashes)))

            case "`":
                if i + 1 < c.count, c[i + 1] == "`" { buffer.append("“"); i += 2 } else { buffer.append("‘"); i += 1 }

            case "'":
                if i + 1 < c.count, c[i + 1] == "'" { buffer.append("”"); i += 2 } else { buffer.append("’"); i += 1 }

            case "\n", "\t":
                buffer.append(" "); i += 1

            default:
                buffer.append(ch); i += 1
            }
        }

        flush()
        return out
    }

    /// Plain text of inlines (titles, authors).
    fileprivate func plain(_ inlines: [Inline]) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case .text(let t): result += t
            case .bold(let x), .italic(let x), .mono(let x), .footnote(let x): result += x.isEmpty ? "" : (inline.isFootnote ? "" : plain(x))
            case .math(let m): result += m
            case .link(_, let x): result += plain(x)
            case .cite, .ref: break
            case .lineBreak: result += " "
            }
        }
        return result.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }
}

fileprivate extension Inline {
    var isFootnote: Bool {
        if case .footnote = self { return true }
        return false
    }
}

// MARK: - Math (LaTeX -> tree -> Word equation or plain text)

fileprivate enum MathStyle { case italic, upright, bold }

fileprivate indirect enum MathNode {
    case run(String, MathStyle)
    case frac([MathNode], [MathNode])
    case script(base: [MathNode], sub: [MathNode]?, sup: [MathNode]?)
    case sqrt(degree: [MathNode]?, body: [MathNode])
    case nary(chr: String, sub: [MathNode]?, sup: [MathNode]?, body: [MathNode])
    case accent(String, [MathNode])
    case delim(open: String, close: String, body: [MathNode])
    case matrix(rows: [[[MathNode]]], open: String, close: String)
}

fileprivate final class MathParser {

    private let c: [Character]
    private var i = 0
    private let warn: (String) -> Void

    init(_ tex: String, warn: @escaping (String) -> Void) {
        self.c = Array(tex)
        self.warn = warn
    }

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "propto": "∝", "ll": "≪", "gg": "≫",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅", "infty": "∞", "partial": "∂",
        "nabla": "∇", "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "prime": "′", "circ": "∘", "bullet": "∙",
        "star": "⋆", "ast": "∗", "oplus": "⊕", "otimes": "⊗", "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉",
        "lfloor": "⌊", "rfloor": "⌋", "mid": "|", "parallel": "∥", "perp": "⊥", "angle": "∠", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "degree": "°", "top": "⊤", "bot": "⊥", "triangle": "△", "square": "□",
        "lbrace": "{", "rbrace": "}", "{": "{", "}": "}", "|": "‖", "%": "%", "&": "&", "$": "$", "#": "#", "_": "_"
    ]

    static let functionNames: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "log", "ln", "lg", "exp", "max", "min", "lim",
        "sup", "inf", "det", "dim", "arg", "gcd", "deg", "ker", "Pr", "argmax", "argmin", "limsup", "liminf", "mod", "softmax"
    ]

    static let bigOperators: [String: (chr: String, limits: Bool)] = [
        "sum": ("∑", true), "prod": ("∏", true), "coprod": ("∐", true), "int": ("∫", false), "iint": ("∬", false),
        "iiint": ("∭", false), "oint": ("∮", false), "bigcup": ("⋃", true), "bigcap": ("⋂", true),
        "bigoplus": ("⨁", true), "bigotimes": ("⨂", true), "bigvee": ("⋁", true), "bigwedge": ("⋀", true)
    ]

    static let accents: [String: String] = [
        "hat": "\u{0302}", "widehat": "\u{0302}", "bar": "\u{0305}", "overline": "\u{0305}", "vec": "\u{20D7}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}", "dot": "\u{0307}", "ddot": "\u{0308}", "check": "\u{030C}", "breve": "\u{0306}"
    ]

    static let blackboard: [Character: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "E": "𝔼", "P": "ℙ", "H": "ℍ", "F": "𝔽", "1": "𝟙"
    ]

    static let matrixDelimiters: [String: (String, String)] = [
        "matrix": ("", ""), "pmatrix": ("(", ")"), "bmatrix": ("[", "]"), "Bmatrix": ("{", "}"),
        "vmatrix": ("|", "|"), "Vmatrix": ("‖", "‖"), "cases": ("{", ""), "array": ("", "")
    ]

    // MARK: Parsing

    func parse() -> [MathNode] {
        i = 0
        var nodes: [MathNode] = []
        while i < c.count {
            nodes.append(contentsOf: parseSequence())
            if i < c.count { i += 1 }   // stray } or \right
        }
        return nodes
    }

    private func parseSequence() -> [MathNode] {
        var nodes: [MathNode] = []
        while i < c.count {
            if c[i] == "}" { break }
            if LX.hasPrefix(c, i, "\\right") || LX.hasPrefix(c, i, "\\end") { break }
            if c[i] == "&" { i += 1; continue }
            nodes.append(contentsOf: parseAtomWithScripts())
        }
        return nodes
    }

    private func skipSpaces() {
        while i < c.count, c[i] == " " || c[i] == "\n" || c[i] == "\t" { i += 1 }
    }

    private func parseAtomWithScripts() -> [MathNode] {

        skipSpaces()
        guard i < c.count else { return [] }

        // Big operators take their own limits and the next atom as the body.
        if c[i] == "\\" {
            let (name, end) = LX.commandName(c, i)
            if let op = Self.bigOperators[name] {
                i = end
                var sub: [MathNode]?
                var sup: [MathNode]?
                readScripts(sub: &sub, sup: &sup)
                skipSpaces()
                var body: [MathNode] = []
                if i < c.count, c[i] != "}", !LX.hasPrefix(c, i, "\\right") { body = parseAtomWithScripts() }
                return [.nary(chr: op.chr, sub: sub, sup: sup, body: body)]
            }
        }

        let base = parsePrimary()
        var sub: [MathNode]?
        var sup: [MathNode]?
        readScripts(sub: &sub, sup: &sup)

        if sub == nil, sup == nil { return base }
        return [.script(base: base, sub: sub, sup: sup)]
    }

    private func readScripts(sub: inout [MathNode]?, sup: inout [MathNode]?) {
        while true {
            skipSpaces()
            guard i < c.count else { return }
            if c[i] == "^", sup == nil {
                i += 1
                sup = parseScriptArgument()
            } else if c[i] == "_", sub == nil {
                i += 1
                sub = parseScriptArgument()
            } else if c[i] == "'" {
                i += 1
                sup = (sup ?? []) + [.run("′", .upright)]
            } else {
                return
            }
        }
    }

    private func parseScriptArgument() -> [MathNode] {
        skipSpaces()
        guard i < c.count else { return [] }
        if c[i] == "{" { return parseGroup() }
        if c[i] == "\\" { return parsePrimary() }
        let ch = c[i]
        i += 1
        return [.run(String(ch), ch.isLetter ? .italic : .upright)]
    }

    private func parseGroup() -> [MathNode] {
        guard i < c.count, c[i] == "{" else { return [] }
        i += 1
        let inner = parseSequence()
        if i < c.count, c[i] == "}" { i += 1 }
        return inner
    }

    private func groupText() -> String {
        skipSpaces()
        guard i < c.count, c[i] == "{", let close = LX.matching(c, i) else { return "" }
        let text = String(c[(i + 1)..<close])
        i = close + 1
        return text
    }

    private func parsePrimary() -> [MathNode] {

        skipSpaces()
        guard i < c.count else { return [] }
        let ch = c[i]

        if ch == "{" { return parseGroup() }

        if ch == "\\" { return parseCommand() }

        if ch.isNumber {
            var digits = ""
            while i < c.count, c[i].isNumber || c[i] == "." && i + 1 < c.count && c[i + 1].isNumber {
                digits.append(c[i]); i += 1
            }
            return [.run(digits, .upright)]
        }

        i += 1
        if ch.isLetter { return [.run(String(ch), .italic)] }
        if ch == "~" { return [.run(" ", .upright)] }
        return [.run(String(ch), .upright)]
    }

    private func parseCommand() -> [MathNode] {

        let (name, end) = LX.commandName(c, i)
        i = end

        switch name {

        case "frac", "dfrac", "tfrac", "cfrac":
            let numerator = parseArgument()
            let denominator = parseArgument()
            return [.frac(numerator, denominator)]

        case "binom", "dbinom", "tbinom":
            let top = parseArgument()
            let bottom = parseArgument()
            return [.delim(open: "(", close: ")", body: [.frac(top, bottom)])]

        case "sqrt":
            skipSpaces()
            var degree: [MathNode]?
            if i < c.count, c[i] == "[", let close = LX.matching(c, i, "[", "]") {
                degree = MathParser(String(c[(i + 1)..<close]), warn: warn).parse()
                i = close + 1
            }
            return [.sqrt(degree: degree, body: parseArgument())]

        case "left":
            skipSpaces()
            let open = readDelimiter()
            let body = parseSequence()
            var close = ""
            if LX.hasPrefix(c, i, "\\right") {
                i += 6
                skipSpaces()
                close = readDelimiter()
            }
            return [.delim(open: open, close: close, body: body)]

        case "right":
            return []

        case "text", "textrm", "mathrm", "operatorname", "mbox", "textnormal", "mathsf", "textsf", "mathtt":
            return [.run(groupOrToken(), .upright)]

        case "textbf", "mathbf", "boldsymbol", "bm", "mathbfit":
            return [.run(groupOrToken(), .bold)]

        case "mathit", "textit", "mathcal", "mathscr", "mathfrak":
            return parseArgument()

        case "mathbb":
            let letters = groupOrToken()
            return [.run(letters.map { Self.blackboard[$0] ?? String($0) }.joined(), .upright)]

        case "begin":
            return parseEnvironment()

        case "\\":
            return [.run(" ", .upright)]

        case ",", ";", ":", "!", " ", "quad", "qquad", "enspace", "thinspace", "space":
            return [.run(" ", .upright)]

        case "label":
            _ = groupText()
            return []

        case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "big", "Big", "bigg", "Bigg", "nonumber", "notag":
            return []

        default:
            break
        }

        if let accent = Self.accents[name] {
            return [.accent(accent, parseArgument())]
        }
        if let symbol = Self.symbols[name] {
            let isGreekLower = name.first.map { $0.isLowercase } ?? false
            let greek = symbol.unicodeScalars.first.map { $0.value >= 0x3B1 && $0.value <= 0x3C9 || $0.value == 0x3D5 || $0.value == 0x3F5 } ?? false
            return [.run(symbol, isGreekLower && greek ? .italic : .upright)]
        }
        if Self.functionNames.contains(name) {
            return [.run(name, .upright)]
        }

        warn("The equation command \\\(name) is not supported; its name was kept as text.")
        return [.run(name, .upright)]
    }

    private func parseArgument() -> [MathNode] {
        skipSpaces()
        guard i < c.count else { return [] }
        if c[i] == "{" { return parseGroup() }
        return parsePrimary()
    }

    private func groupOrToken() -> String {
        skipSpaces()
        guard i < c.count else { return "" }
        if c[i] == "{" { return groupText() }
        let ch = c[i]
        i += 1
        return String(ch)
    }

    private func readDelimiter() -> String {
        guard i < c.count else { return "" }
        if c[i] == "\\" {
            let (name, end) = LX.commandName(c, i)
            i = end
            return Self.symbols[name] ?? (name == "|" ? "‖" : "")
        }
        let ch = c[i]
        i += 1
        return ch == "." ? "" : String(ch)
    }

    private func parseEnvironment() -> [MathNode] {

        let name = groupText()
        guard let close = LX.environmentEnd(c, name: name, from: i) else {
            warn("The equation environment “\(name)” is not closed.")
            return []
        }

        var inner = String(c[i..<close.innerEnd])
        i = close.after

        guard let delimiters = Self.matrixDelimiters[name] else {
            warn("The equation environment “\(name)” is not supported; its content was kept as plain math.")
            return MathParser(inner, warn: warn).parse()
        }

        if name == "array", inner.hasPrefix("{"), let g = LX.group(Array(inner), 0) {
            inner = String(inner.dropFirst(g.end))
        }

        let rows = LX.split(inner, rows: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { row in LX.split(row, rows: false).map { MathParser($0, warn: warn).parse() } }

        return [.matrix(rows: rows, open: delimiters.0, close: delimiters.1)]
    }
}

fileprivate enum MathOutput {

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: Word (OMML)

    static func omml(_ nodes: [MathNode]) -> String {
        nodes.map { ommlNode($0) }.joined()
    }

    private static func wrap(_ tag: String, _ nodes: [MathNode]?) -> String {
        "<m:\(tag)>" + omml(nodes ?? []) + "</m:\(tag)>"
    }

    private static func ommlNode(_ node: MathNode) -> String {
        switch node {

        case .run(let text, let style):
            let properties: String
            switch style {
            case .italic: properties = ""
            case .upright: properties = "<m:rPr><m:sty m:val=\"p\"/></m:rPr>"
            case .bold: properties = "<m:rPr><m:sty m:val=\"b\"/></m:rPr>"
            }
            return "<m:r>\(properties)<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/></w:rPr><m:t xml:space=\"preserve\">\(escape(text))</m:t></m:r>"

        case .frac(let numerator, let denominator):
            return "<m:f>" + wrap("num", numerator) + wrap("den", denominator) + "</m:f>"

        case .script(let base, let sub, let sup):
            if sub != nil, sup != nil {
                return "<m:sSubSup>" + wrap("e", base) + wrap("sub", sub) + wrap("sup", sup) + "</m:sSubSup>"
            }
            if sup != nil { return "<m:sSup>" + wrap("e", base) + wrap("sup", sup) + "</m:sSup>" }
            return "<m:sSub>" + wrap("e", base) + wrap("sub", sub) + "</m:sSub>"

        case .sqrt(let degree, let body):
            let properties = degree == nil ? "<m:radPr><m:degHide m:val=\"1\"/></m:radPr>" : "<m:radPr/>"
            return "<m:rad>\(properties)" + wrap("deg", degree) + wrap("e", body) + "</m:rad>"

        case .nary(let chr, let sub, let sup, let body):
            var properties = "<m:chr m:val=\"\(chr)\"/><m:limLoc m:val=\"\(chr == "∫" || chr == "∬" || chr == "∭" || chr == "∮" ? "subSup" : "undOvr")\"/>"
            if sub == nil { properties += "<m:subHide m:val=\"1\"/>" }
            if sup == nil { properties += "<m:supHide m:val=\"1\"/>" }
            return "<m:nary><m:naryPr>\(properties)</m:naryPr>" + wrap("sub", sub) + wrap("sup", sup) + wrap("e", body) + "</m:nary>"

        case .accent(let mark, let body):
            let chr = accentCharacter(mark)
            return "<m:acc><m:accPr><m:chr m:val=\"\(chr)\"/></m:accPr>" + wrap("e", body) + "</m:acc>"

        case .delim(let open, let close, let body):
            return "<m:d><m:dPr><m:begChr m:val=\"\(escape(open))\"/><m:endChr m:val=\"\(escape(close))\"/></m:dPr>" + wrap("e", body) + "</m:d>"

        case .matrix(let rows, let open, let close):
            var matrix = "<m:m>"
            for row in rows {
                matrix += "<m:mr>" + row.map { wrap("e", $0) }.joined() + "</m:mr>"
            }
            matrix += "</m:m>"
            if open.isEmpty, close.isEmpty { return matrix }
            return "<m:d><m:dPr><m:begChr m:val=\"\(escape(open))\"/><m:endChr m:val=\"\(escape(close))\"/></m:dPr><m:e>\(matrix)</m:e></m:d>"
        }
    }

    private static func accentCharacter(_ combining: String) -> String {
        switch combining {
        case "\u{0302}": return "^"
        case "\u{0305}": return "¯"
        case "\u{20D7}": return "→"
        case "\u{0303}": return "~"
        case "\u{0307}": return "˙"
        case "\u{0308}": return "¨"
        case "\u{030C}": return "ˇ"
        default: return "˘"
        }
    }

    // MARK: Plain text

    private static let spacedOperators: Set<String> = [
        "+", "-", "=", "<", ">", "×", "±", "∓", "≤", "≥", "≠", "≈", "≡", "∼", "≃", "→", "←", "↔", "⇒", "⇐", "⇔", "↦",
        "∈", "∉", "∋", "⊂", "⊃", "⊆", "⊇", "∪", "∩", "∧", "∨", "∝", "≪", "≫", "∘", "⊕", "⊗", "÷"
    ]

    static func plain(_ nodes: [MathNode]) -> String {
        let text = nodes.map { plainNode($0) }.joined()
        var out = ""
        var lastWasSpace = false
        for ch in text {
            if ch == " " {
                if !lastWasSpace { out.append(ch) }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func wrapped(_ nodes: [MathNode]) -> String {
        let text = plain(nodes)
        return text.count <= 1 ? text : "(\(text))"
    }

    private static func plainNode(_ node: MathNode) -> String {
        switch node {
        case .run(let text, _):
            if spacedOperators.contains(text) { return " \(text) " }
            return text == "," ? ", " : text
        case .frac(let n, let d): return wrapped(n) + "/" + wrapped(d)
        case .script(let base, let sub, let sup):
            var text = plain(base)
            if let sub { text += "_" + wrapped(sub) }
            if let sup { text += "^" + wrapped(sup) }
            return text
        case .sqrt(let degree, let body): return (degree.map { plain($0) } ?? "") + "√(" + plain(body) + ")"
        case .nary(let chr, let sub, let sup, let body):
            var text = chr
            if let sub { text += "_" + wrapped(sub) }
            if let sup { text += "^" + wrapped(sup) }
            return body.isEmpty ? text : text + " " + plain(body)
        case .accent(let mark, let body): return plain(body) + mark
        case .delim(let open, let close, let body): return open + plain(body) + close
        case .matrix(let rows, let open, let close):
            return open + rows.map { $0.map { plain($0) }.joined(separator: ", ") }.joined(separator: "; ") + close
        }
    }
}

// MARK: - Shared text helpers

fileprivate func collapseSpaces(_ text: String) -> String {
    var out = ""
    var lastWasSpace = false
    for ch in text {
        if ch == " " || ch == "\t" || ch == "\n" {
            if !lastWasSpace { out.append(" ") }
            lastWasSpace = true
        } else {
            out.append(ch)
            lastWasSpace = false
        }
    }
    return out
}

fileprivate func parseMath(_ tex: String, _ context: ExportContext) -> [MathNode] {
    MathParser(tex, warn: { context.warn($0) }).parse()
}

// MARK: - Plain text

fileprivate final class TextWriter {

    private let document: LatexDocument
    private var context: ExportContext { document.context }
    private var notes: [String] = []

    init(document: LatexDocument) {
        self.document = document
    }

    func render() -> String {

        var parts: [String] = []

        parts.append(document.title)
        if !document.authors.isEmpty { parts.append(document.authors.joined(separator: ", ")) }
        if let date = document.date { parts.append(date) }

        parts.append(contentsOf: blocks(document.blocks, indent: ""))

        if !notes.isEmpty {
            parts.append("Notes\n" + notes.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n") + "\n"
    }

    private func blocks(_ list: [Block], indent: String) -> [String] {
        var out: [String] = []
        for block in list {
            switch block {

            case .heading(_, let number, let text):
                out.append(indent + ((number.map { $0 + " " } ?? "") + inline(text)))

            case .paragraph(let text):
                out.append(indent + inline(text))

            case .math(let tex, let number):
                let line = MathOutput.plain(parseMath(tex, context))
                out.append(indent + "    " + line + (number.map { "    (\($0))" } ?? ""))

            case .list(let ordered, let items):
                for (index, item) in items.enumerated() {
                    let marker = ordered ? "\(index + 1). " : "- "
                    let inner = blocks(item, indent: "")
                    if let first = inner.first {
                        out.append(indent + marker + first)
                        out.append(contentsOf: inner.dropFirst().map { indent + "   " + $0 })
                    }
                }

            case .table(let caption, let number, let rows):
                if let caption { out.append(indent + "Table \(number.map { String($0) } ?? ""). " + inline(caption)) }
                out.append(rows.map { $0.map { inline($0.content) }.joined(separator: "\t") }.joined(separator: "\n"))

            case .figure(let path, let caption, let number):
                var line = "[Figure"
                if let number { line += " \(number)" }
                line += path.isEmpty ? "]" : ": \(path)]"
                if let caption { line += " " + inline(caption) }
                out.append(indent + line)

            case .code(let code):
                out.append(code)

            case .quote(let inner):
                out.append(contentsOf: blocks(inner, indent: indent + "    "))

            case .abstract(let inner):
                out.append(indent + "Abstract")
                out.append(contentsOf: blocks(inner, indent: indent))

            case .references:
                let references = context.referenceList()
                if !references.isEmpty {
                    out.append(indent + "References")
                    out.append(references.map { indent + $0 }.joined(separator: "\n"))
                }
            }
        }
        return out
    }

    private func inline(_ list: [Inline]) -> String {
        var out = ""
        for item in list {
            switch item {
            case .text(let text): out += text
            case .bold(let x), .italic(let x), .mono(let x): out += inline(x)
            case .math(let tex): out += MathOutput.plain(parseMath(tex, context))
            case .cite(let kind, let keys): out += context.citationText(kind, keys)
            case .ref(let label, let paren): out += context.referenceNumber(label, paren: paren)
            case .footnote(let x):
                notes.append(inline(x))
                out += "[\(notes.count)]"
            case .link(let url, let x):
                let text = inline(x)
                out += text == url ? text : "\(text) (\(url))"
            case .lineBreak: out += "\n"
            }
        }
        return collapseSpaces(out).replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Markdown

fileprivate final class MarkdownWriter {

    private let document: LatexDocument
    private var context: ExportContext { document.context }
    private var notes: [String] = []

    init(document: LatexDocument) {
        self.document = document
    }

    func render() -> String {

        var parts: [String] = ["# " + escape(document.title)]
        if !document.authors.isEmpty { parts.append("*" + escape(document.authors.joined(separator: ", ")) + "*") }
        if let date = document.date { parts.append(escape(date)) }

        parts.append(contentsOf: blocks(document.blocks))

        if !notes.isEmpty {
            parts.append(notes.enumerated().map { "[^\($0.offset + 1)]: \($0.element)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private func blocks(_ list: [Block]) -> [String] {
        var out: [String] = []
        for block in list {
            switch block {

            case .heading(let level, _, let text):
                out.append(String(repeating: "#", count: min(level + 1, 6)) + " " + inline(text))

            case .paragraph(let text):
                out.append(inline(text))

            case .math(let tex, let number):
                out.append("$$\n" + tex + (number.map { " \\tag{\($0)}" } ?? "") + "\n$$")

            case .list(let ordered, let items):
                var lines: [String] = []
                for (index, item) in items.enumerated() {
                    let marker = ordered ? "\(index + 1). " : "- "
                    let pad = String(repeating: " ", count: marker.count)
                    let inner = blocks(item).joined(separator: "\n\n")
                    let split = inner.split(separator: "\n", omittingEmptySubsequences: false)
                    for (n, line) in split.enumerated() {
                        lines.append(n == 0 ? marker + line : (line.isEmpty ? "" : pad + line))
                    }
                }
                out.append(lines.joined(separator: "\n"))

            case .table(let caption, let number, let rows):
                if let caption { out.append("**Table \(number.map { String($0) } ?? "").** " + inline(caption)) }
                out.append(table(rows))

            case .figure(let path, let caption, let number):
                let text = caption.map { inline($0) } ?? ""
                var line = path.isEmpty ? "" : "![\(text)](\(path.replacingOccurrences(of: " ", with: "%20")))"
                if let number, !text.isEmpty { line += (line.isEmpty ? "" : "\n\n") + "*Figure \(number).* \(text)" }
                if !line.isEmpty { out.append(line) }

            case .code(let code):
                out.append("```\n" + code + "\n```")

            case .quote(let inner):
                out.append(blocks(inner).joined(separator: "\n\n").split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> " + $0 }.joined(separator: "\n"))

            case .abstract(let inner):
                out.append("**Abstract**")
                out.append(contentsOf: blocks(inner))

            case .references:
                let references = context.referenceList()
                if !references.isEmpty {
                    out.append("## References")
                    out.append(references.map { "- " + escape($0) }.joined(separator: "\n"))
                }
            }
        }
        return out
    }

    private func table(_ rows: [[TableCell]]) -> String {
        guard !rows.isEmpty else { return "" }
        let width = rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 1

        func line(_ row: [TableCell]) -> String {
            var cells: [String] = []
            for cell in row {
                cells.append(inline(cell.content).replacingOccurrences(of: "\n", with: " "))
                for _ in 1..<max(cell.span, 1) { cells.append("") }
            }
            while cells.count < width { cells.append("") }
            return "| " + cells.joined(separator: " | ") + " |"
        }

        var lines = [line(rows[0]), "|" + String(repeating: " --- |", count: width)]
        for row in rows.dropFirst() { lines.append(line(row)) }
        return lines.joined(separator: "\n")
    }

    private func inline(_ list: [Inline]) -> String {
        var out = ""
        for item in list {
            switch item {
            case .text(let text): out += escape(text)
            case .bold(let x): out += "**" + inline(x) + "**"
            case .italic(let x): out += "*" + inline(x) + "*"
            case .mono(let x): out += "`" + inline(x).replacingOccurrences(of: "\\", with: "") + "`"
            case .math(let tex): out += "$" + tex.trimmingCharacters(in: .whitespaces) + "$"
            case .cite(let kind, let keys):
                _ = keys.map { context.citation($0) }
                let at = keys.map { "@" + $0 }
                switch kind {
                case .paren: out += "[" + at.joined(separator: "; ") + "]"
                case .text, .author: out += at.joined(separator: "; ")
                case .year: out += "[" + keys.map { "-@" + $0 }.joined(separator: "; ") + "]"
                case .silent: break
                }
            case .ref(let label, let paren): out += context.referenceNumber(label, paren: paren)
            case .footnote(let x):
                notes.append(inline(x))
                out += "[^\(notes.count)]"
            case .link(let url, let x): out += "[" + inline(x) + "](" + url + ")"
            case .lineBreak: out += "  \n"
            }
        }
        return collapseSpaces(out).replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Word (.docx)

fileprivate final class DocxWriter {

    private let document: LatexDocument
    private let folder: URL
    private var context: ExportContext { document.context }

    private var footnotes: [String] = []
    private var images: [(id: String, name: String, data: Data)] = []
    private var hyperlinks: [(id: String, url: String)] = []
    private var orderedLists = 0
    private var drawingCount = 0

    private static let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" "
        + "xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" "
        + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""

    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    init(document: LatexDocument, folder: URL) {
        self.document = document
        self.folder = folder
    }

    // MARK: Package

    func data() throws -> Data {

        var body = ""
        body += paragraph(style: "Title", runs: run(document.title))
        if !document.authors.isEmpty {
            body += paragraph(style: "Author", runs: run(document.authors.joined(separator: ", ")))
        }
        if let date = document.date {
            body += paragraph(style: "Author", runs: run(date))
        }
        body += blocks(document.blocks, level: 0)
        body += "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr>"

        let documentXML = Self.header + "<w:document \(Self.ns)><w:body>\(body)</w:body></w:document>"

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }

        let zip = try ZipWriter(url: temp)
        try zip.add(name: "[Content_Types].xml", data: Data(contentTypes().utf8))
        try zip.add(name: "_rels/.rels", data: Data(rootRelationships().utf8))
        try zip.add(name: "docProps/core.xml", data: Data(coreProperties().utf8))
        try zip.add(name: "word/document.xml", data: Data(documentXML.utf8))
        try zip.add(name: "word/_rels/document.xml.rels", data: Data(documentRelationships().utf8))
        try zip.add(name: "word/styles.xml", data: Data(Self.styles.utf8))
        try zip.add(name: "word/numbering.xml", data: Data(numbering().utf8))
        try zip.add(name: "word/settings.xml", data: Data(Self.settings.utf8))
        try zip.add(name: "word/footnotes.xml", data: Data(footnotesXML().utf8))
        for image in images { try zip.add(name: "word/media/\(image.name)", data: image.data) }
        try zip.finish()

        return try Data(contentsOf: temp)
    }

    private func contentTypes() -> String {
        let main = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        return Self.header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/word/document.xml" ContentType="\(main).document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="\(main).styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="\(main).numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="\(main).settings+xml"/>\
        <Override PartName="/word/footnotes.xml" ContentType="\(main).footnotes+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """
    }

    private func rootRelationships() -> String {
        Self.header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        </Relationships>
        """
    }

    private func documentRelationships() -> String {
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var xml = Self.header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        xml += "<Relationship Id=\"rIdStyles\" Type=\"\(base)/styles\" Target=\"styles.xml\"/>"
        xml += "<Relationship Id=\"rIdNumbering\" Type=\"\(base)/numbering\" Target=\"numbering.xml\"/>"
        xml += "<Relationship Id=\"rIdSettings\" Type=\"\(base)/settings\" Target=\"settings.xml\"/>"
        xml += "<Relationship Id=\"rIdFootnotes\" Type=\"\(base)/footnotes\" Target=\"footnotes.xml\"/>"
        for image in images {
            xml += "<Relationship Id=\"\(image.id)\" Type=\"\(base)/image\" Target=\"media/\(image.name)\"/>"
        }
        for link in hyperlinks {
            xml += "<Relationship Id=\"\(link.id)\" Type=\"\(base)/hyperlink\" Target=\"\(MathOutput.escape(link.url))\" TargetMode=\"External\"/>"
        }
        return xml + "</Relationships>"
    }

    private func coreProperties() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return Self.header + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(MathOutput.escape(document.title))</dc:title>\
        <dc:creator>\(MathOutput.escape(document.authors.joined(separator: ", ")))</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created>\
        </cp:coreProperties>
        """
    }

    private func footnotesXML() -> String {
        var xml = Self.header + "<w:footnotes \(Self.ns)>"
        xml += "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote>"
        xml += "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
        xml += footnotes.joined()
        return xml + "</w:footnotes>"
    }

    private func numbering() -> String {

        func level(_ index: Int, format: String, text: String) -> String {
            let left = 720 * (index + 1)
            return "<w:lvl w:ilvl=\"\(index)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }

        var xml = Self.header + "<w:numbering \(Self.ns)>"
        xml += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        xml += level(0, format: "bullet", text: "•") + level(1, format: "bullet", text: "–") + level(2, format: "bullet", text: "•")
        xml += "</w:abstractNum>"
        xml += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        xml += level(0, format: "decimal", text: "%1.") + level(1, format: "lowerLetter", text: "%2.") + level(2, format: "lowerRoman", text: "%3.")
        xml += "</w:abstractNum>"
        xml += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for n in 0..<orderedLists {
            xml += "<w:num w:numId=\"\(n + 2)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return xml + "</w:numbering>"
    }

    // MARK: Paragraph and run helpers

    private func paragraph(style: String? = nil, properties: String = "", runs: String) -> String {
        var pPr = ""
        if let style { pPr += "<w:pStyle w:val=\"\(style)\"/>" }
        pPr += properties
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs + "</w:p>"
    }

    private func run(_ text: String, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> String {
        var rPr = ""
        if mono { rPr += "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" }
        if bold { rPr += "<w:b/>" }
        if italic { rPr += "<w:i/>" }
        let props = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
        return "<w:r>\(props)<w:t xml:space=\"preserve\">\(MathOutput.escape(text))</w:t></w:r>"
    }

    private func runs(_ list: [Inline], bold: Bool = false, italic: Bool = false, mono: Bool = false) -> String {
        var xml = ""
        for item in list {
            switch item {

            case .text(let text):
                let cleaned = collapseSpaces(text)
                if !cleaned.isEmpty { xml += run(cleaned, bold: bold, italic: italic, mono: mono) }

            case .bold(let x): xml += runs(x, bold: true, italic: italic, mono: mono)
            case .italic(let x): xml += runs(x, bold: bold, italic: true, mono: mono)
            case .mono(let x): xml += runs(x, bold: bold, italic: italic, mono: true)

            case .math(let tex):
                xml += "<m:oMath>" + MathOutput.omml(parseMath(tex, context)) + "</m:oMath>"

            case .cite(let kind, let keys):
                let text = context.citationText(kind, keys)
                if !text.isEmpty { xml += run(text, bold: bold, italic: italic, mono: mono) }

            case .ref(let label, let paren):
                xml += run(context.referenceNumber(label, paren: paren), bold: bold, italic: italic, mono: mono)

            case .footnote(let x):
                let id = footnotes.count + 1
                footnotes.append(
                    "<w:footnote w:id=\"\(id)\"><w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr>"
                    + "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r>"
                    + run(" ") + runs(x) + "</w:p></w:footnote>")
                xml += "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(id)\"/></w:r>"

            case .link(let url, let x):
                let id = "rIdLink\(hyperlinks.count + 1)"
                hyperlinks.append((id, url))
                let inner = collapseSpaces(plainText(x))
                xml += "<w:hyperlink r:id=\"\(id)\"><w:r><w:rPr><w:rStyle w:val=\"Hyperlink\"/></w:rPr><w:t xml:space=\"preserve\">\(MathOutput.escape(inner))</w:t></w:r></w:hyperlink>"

            case .lineBreak:
                xml += "<w:r><w:br/></w:r>"
            }
        }
        return xml
    }

    private func plainText(_ list: [Inline]) -> String {
        var out = ""
        for item in list {
            switch item {
            case .text(let t): out += t
            case .bold(let x), .italic(let x), .mono(let x), .footnote(let x): out += plainText(x)
            case .math(let m): out += m
            case .link(_, let x): out += plainText(x)
            case .cite(let kind, let keys): out += context.citationText(kind, keys)
            case .ref(let label, let paren): out += context.referenceNumber(label, paren: paren)
            case .lineBreak: out += " "
            }
        }
        return out
    }

    // MARK: Blocks

    private func blocks(_ list: [Block], level: Int) -> String {
        var xml = ""
        for block in list { xml += self.block(block, level: level) }
        return xml
    }

    private func block(_ block: Block, level: Int) -> String {

        switch block {

        case .heading(let depth, let number, let text):
            let prefix = number.map { run($0 + "  ") } ?? ""
            return paragraph(style: "Heading\(min(max(depth, 1), 5))", runs: prefix + runs(text))

        case .paragraph(let text):
            return paragraph(runs: runs(text))

        case .math(let tex, let number):
            var tabs = "<w:tabs><w:tab w:val=\"center\" w:pos=\"4680\"/><w:tab w:val=\"right\" w:pos=\"9360\"/></w:tabs>"
            tabs += "<w:spacing w:before=\"120\" w:after=\"120\"/>"
            var content = "<w:r><w:tab/></w:r><m:oMath>" + MathOutput.omml(parseMath(tex, context)) + "</m:oMath>"
            if let number { content += "<w:r><w:tab/></w:r>" + run("(\(number))") }
            return paragraph(properties: tabs, runs: content)

        case .list(let ordered, let items):
            var numId = 1
            if ordered {
                orderedLists += 1
                numId = orderedLists + 1
            }
            var xml = ""
            for item in items { xml += listItem(item, numId: numId, level: level) }
            return xml

        case .table(let caption, let number, let rows):
            var xml = ""
            if let caption {
                xml += paragraph(style: "Caption", properties: "<w:keepNext/>",
                                 runs: run("Table \(number.map { String($0) } ?? ""). ", bold: true) + runs(caption))
            }
            return xml + table(rows)

        case .figure(let path, let caption, let number):
            var xml = path.isEmpty ? "" : figureImage(path)
            if let caption {
                xml += paragraph(style: "Caption", runs: run("Figure \(number.map { String($0) } ?? ""). ", bold: true) + runs(caption))
            }
            return xml

        case .code(let code):
            return code.split(separator: "\n", omittingEmptySubsequences: false)
                .map { paragraph(style: "Code", runs: run(String($0))) }.joined()

        case .quote(let inner):
            return inner.map { item -> String in
                if case .paragraph(let text) = item { return paragraph(style: "Quote", runs: runs(text)) }
                return self.block(item, level: level)
            }.joined()

        case .abstract(let inner):
            var xml = paragraph(style: "AbstractTitle", runs: run("Abstract"))
            for item in inner {
                if case .paragraph(let text) = item { xml += paragraph(style: "Abstract", runs: runs(text)) } else { xml += self.block(item, level: level) }
            }
            return xml

        case .references:
            let references = context.referenceList()
            if references.isEmpty { return "" }
            return paragraph(style: "Heading1", runs: run("References"))
                + references.map { paragraph(style: "Reference", runs: run($0)) }.joined()
        }
    }

    private func listItem(_ item: [Block], numId: Int, level: Int) -> String {
        var xml = ""
        var first = true
        for block in item {
            if first, case .paragraph(let text) = block {
                let numPr = "<w:numPr><w:ilvl w:val=\"\(min(level, 2))\"/><w:numId w:val=\"\(numId)\"/></w:numPr>"
                xml += paragraph(style: "ListParagraph", properties: numPr, runs: runs(text))
            } else {
                xml += self.block(block, level: level + 1)
            }
            first = false
        }
        return xml
    }

    private func table(_ rows: [[TableCell]]) -> String {

        guard !rows.isEmpty else { return "" }
        let width = max(rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 1, 1)

        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(9000 / width)\"/>", count: width)
        xml += "</w:tblGrid>"

        for row in rows {
            xml += "<w:tr>"
            var used = 0
            for cell in row {
                let span = min(max(cell.span, 1), width - used)
                if span < 1 { break }
                used += span
                let spanXML = span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : ""
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/>\(spanXML)</w:tcPr>" + paragraph(runs: runs(cell.content)) + "</w:tc>"
            }
            while used < width {
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"0\" w:type=\"auto\"/></w:tcPr><w:p/></w:tc>"
                used += 1
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p/>"
    }

    // MARK: Pictures

    private func figureImage(_ path: String) -> String {

        var names = [path]
        if (path as NSString).pathExtension.isEmpty { names += ["png", "jpg", "jpeg"].map { path + "." + $0 } }

        var found: (url: URL, data: Data)?
        for name in names where !name.hasPrefix("/") && !name.contains("..") {
            let url = folder.appendingPathComponent(name.hasPrefix("./") ? String(name.dropFirst(2)) : name)
            if let data = try? Data(contentsOf: url) { found = (url, data); break }
        }

        guard let (url, data) = found else {
            let base = (path as NSString).pathExtension.isEmpty ? path : (path as NSString).deletingPathExtension
            let vector = ["pdf", "eps", "svg"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent(base + "." + $0).path) }
            if vector {
                context.warn("The figure “\(path)” is a PDF or vector file and was not embedded.")
                return paragraph(properties: "<w:jc w:val=\"center\"/>", runs: run("[Figure not embedded: \(path)]", italic: true))
            }
            context.warn("The figure file “\(path)” was not found.")
            return paragraph(properties: "<w:jc w:val=\"center\"/>", runs: run("[Figure not found: \(path)]", italic: true))
        }

        guard let picture = Self.pictureInfo(data) else {
            context.warn("The figure “\(path)” is not a PNG or JPEG file and was not embedded.")
            return paragraph(properties: "<w:jc w:val=\"center\"/>", runs: run("[Figure not embedded: \(path)]", italic: true))
        }

        drawingCount += 1
        let id = "rIdImg\(drawingCount)"
        images.append((id, "image\(drawingCount).\(picture.ext)", data))

        // 96 dpi, at most 6 inches wide.
        let maxWidth = 5_486_400
        var cx = max(picture.width, 1) * 9525
        var cy = max(picture.height, 1) * 9525
        if cx > maxWidth {
            cy = cy * maxWidth / cx
            cx = maxWidth
        }
        let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let drawing = """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:docPr id="\(drawingCount)" name="Picture \(drawingCount)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingCount)" name="\(MathOutput.escape(url.lastPathComponent))"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(id)" xmlns:a="\(aNS)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
        return paragraph(properties: "<w:keepNext/><w:jc w:val=\"center\"/>", runs: drawing)
    }

    /// Width, height and file extension of a PNG or JPEG, read from its header.
    static func pictureInfo(_ data: Data) -> (width: Int, height: Int, ext: String)? {

        let bytes = [UInt8](data.prefix(1 << 16))

        if bytes.count > 24, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            func be32(_ at: Int) -> Int {
                var value = 0
                for k in 0..<4 { value = value * 256 + Int(bytes[at + k]) }
                return value
            }
            let width = be32(16)
            let height = be32(20)
            return (width, height, "png")
        }

        if bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            var i = 2
            while i + 9 < bytes.count {
                guard bytes[i] == 0xFF else { i += 1; continue }
                let marker = bytes[i + 1]
                if marker == 0xFF { i += 1; continue }
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                let length = Int(bytes[i + 2]) * 256 + Int(bytes[i + 3])
                let isFrame = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
                if isFrame {
                    let height = Int(bytes[i + 5]) * 256 + Int(bytes[i + 6])
                    let width = Int(bytes[i + 7]) * 256 + Int(bytes[i + 8])
                    return (width, height, "jpg")
                }
                i += 2 + max(length, 2)
            }
        }
        return nil
    }

    // MARK: Fixed parts

    private static let settings = header
        + "<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        + "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr></w:settings>"

    private static func style(_ id: String, _ name: String, type: String = "paragraph", based: String? = "Normal",
                              next: String? = nil, pPr: String = "", rPr: String = "") -> String {
        var xml = "<w:style w:type=\"\(type)\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/>"
        if let based { xml += "<w:basedOn w:val=\"\(based)\"/>" }
        if let next { xml += "<w:next w:val=\"\(next)\"/>" }
        xml += "<w:qFormat/>"
        if !pPr.isEmpty { xml += "<w:pPr>\(pPr)</w:pPr>" }
        if !rPr.isEmpty { xml += "<w:rPr>\(rPr)</w:rPr>" }
        return xml + "</w:style>"
    }

    private static let styles: String = {
        var xml = DocxWriter.header + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        xml += "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Times New Roman\" w:hAnsi=\"Times New Roman\" w:cs=\"Times New Roman\" w:eastAsia=\"Times New Roman\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"en-US\"/></w:rPr></w:rPrDefault>"
        xml += "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
        xml += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        xml += DocxWriter.style("Title", "Title", next: "Normal", pPr: "<w:spacing w:before=\"240\" w:after=\"120\"/><w:jc w:val=\"center\"/>", rPr: "<w:b/><w:sz w:val=\"36\"/>")
        xml += DocxWriter.style("Author", "Author", pPr: "<w:jc w:val=\"center\"/>", rPr: "<w:sz w:val=\"24\"/>")
        let sizes = [32, 28, 24, 22, 22]
        for (index, size) in sizes.enumerated() {
            let italic = index >= 3 ? "<w:i/>" : ""
            xml += DocxWriter.style("Heading\(index + 1)", "heading \(index + 1)", next: "Normal",
                         pPr: "<w:keepNext/><w:keepLines/><w:spacing w:before=\"\(index == 0 ? 360 : 240)\" w:after=\"80\"/><w:outlineLvl w:val=\"\(index)\"/>",
                         rPr: "<w:b/>\(italic)<w:sz w:val=\"\(size)\"/>")
        }
        xml += DocxWriter.style("Quote", "Quote", pPr: "<w:ind w:left=\"720\" w:right=\"720\"/>", rPr: "<w:i/>")
        xml += DocxWriter.style("Caption", "caption", pPr: "<w:spacing w:before=\"60\" w:after=\"200\"/><w:jc w:val=\"center\"/>", rPr: "<w:sz w:val=\"20\"/>")
        xml += DocxWriter.style("Code", "Code", pPr: "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:ind w:left=\"360\"/>", rPr: "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/>")
        xml += DocxWriter.style("ListParagraph", "List Paragraph", pPr: "<w:spacing w:after=\"60\"/>")
        xml += DocxWriter.style("AbstractTitle", "Abstract Title", next: "Abstract", pPr: "<w:spacing w:before=\"200\" w:after=\"60\"/><w:jc w:val=\"center\"/>", rPr: "<w:b/>")
        xml += DocxWriter.style("Abstract", "Abstract", pPr: "<w:ind w:left=\"720\" w:right=\"720\"/><w:jc w:val=\"both\"/>", rPr: "<w:sz w:val=\"20\"/>")
        xml += DocxWriter.style("Reference", "Reference", pPr: "<w:ind w:left=\"360\" w:hanging=\"360\"/><w:spacing w:after=\"80\"/>")
        xml += DocxWriter.style("FootnoteText", "footnote text", pPr: "<w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>", rPr: "<w:sz w:val=\"20\"/>")
        xml += "<w:style w:type=\"character\" w:styleId=\"FootnoteReference\"><w:name w:val=\"footnote reference\"/><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
        xml += "<w:style w:type=\"table\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:basedOn w:val=\"TableNormal\"/><w:tblPr><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            xml += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"808080\"/>"
        }
        xml += "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
        xml += "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/></w:tblPr></w:style>"
        return xml + "</w:styles>"
    }()
}
