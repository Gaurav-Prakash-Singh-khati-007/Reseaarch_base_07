//
//  DocumentImporter.swift
//  ResearchBase
//
//  Owner: Agent 34 · Features: F-40
//
//  Brings an existing draft into ResearchBase as a LaTeX project:
//    .tex   one file; the files it uses next to it (figures, .bib, \input files) come along
//    .zip   a whole LaTeX project; its folder layout is kept
//    .docx  a Word document, converted to LaTeX: headings, bold/italic, lists, tables,
//           footnotes, links, pictures and equations carry over; anything that cannot be
//           converted is listed in `issues` so you can check it.
//  This file does not use the database. The caller (the writing screens) creates the
//  draft, then asks this importer to write the project files into the draft folder.
//
//  PUBLIC API
//    Types
//      DocumentImportKind            tex, zip, docx
//      DocumentImportIssueLevel      note, warning
//      DocumentImportIssue           one thing to check: level, message, location
//      DocumentImportResult          kind, title, author, mainFile, files, issues, wordCount
//      DocumentImportError           plain-words errors (LocalizedError)
//    DocumentImporter()
//      static let supportedExtensions                       ["tex", "zip", "docx"]
//      static func kind(of: URL) -> DocumentImportKind?
//      preview(_ url: URL) throws -> DocumentImportResult   converts in a temporary place; writes nothing to the draft
//      importDocument(from:into:overwrite:) throws -> DocumentImportResult
//                                                           writes the project files into `destination`
//      static func escapeLatex(_:) -> String
//
//  Notes
//    * `files` and `mainFile` are paths relative to the destination folder. When
//      `mainFile` is not "main.tex" (a zip with another main file), call
//      DraftFolderStore.setMainFile with it.
//    * `overwrite: false` refuses (and changes nothing) if any file to be written already
//      exists. A new draft already has main.tex and refs.bib, so pass `overwrite: true` there.
//      Overwritten files are put back if the copy fails half-way.
//    * A .docx has no LaTeX class of its own: the result uses \documentclass{article}.
//      Word citations (Zotero, Mendeley, EndNote) stay as plain text; they are not turned
//      into \cite.
//    * Zip files are opened with the Mac's own `ditto` tool (the app is not sandboxed).
//      Hidden files, __MACOSX, symbolic links and build leftovers (.aux, .log, ...) are skipped.
//    * Call from a background task for large files.
//

import Foundation

// MARK: - Public types

nonisolated enum DocumentImportKind: String, Equatable {
    case tex, zip, docx
}

nonisolated enum DocumentImportIssueLevel: Equatable {
    case note
    case warning
}

nonisolated struct DocumentImportIssue: Equatable {
    let level: DocumentImportIssueLevel
    let message: String
    /// The file the message is about, when there is one.
    let location: String?
}

nonisolated struct DocumentImportResult: Equatable {
    let kind: DocumentImportKind
    let title: String
    let author: String?
    /// Relative to the destination folder.
    let mainFile: String
    /// Every file written (or that would be written), relative to the destination folder.
    let files: [String]
    let issues: [DocumentImportIssue]
    let wordCount: Int
}

nonisolated enum DocumentImportError: Error, LocalizedError, Equatable {
    case unsupportedType(String)
    case fileMissing(String)
    case unreadable(String)
    case notAWordDocument
    case noTexFile
    case tooLarge
    case wouldOverwrite(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return "“.\(ext)” files cannot be imported. Use a .tex file, a .zip project or a .docx. For an older .doc, open it in Word and save it as .docx first."
        case .fileMissing(let name):
            return "“\(name)” could not be found."
        case .unreadable(let name):
            return "“\(name)” could not be read. It may be damaged."
        case .notAWordDocument:
            return "This file is not a Word document (.docx). Open it in Word and save it as .docx again."
        case .noTexFile:
            return "The .zip has no .tex file in it, so there is nothing to import."
        case .tooLarge:
            return "The project is larger than 3 GB once unpacked, so it was not imported."
        case .wouldOverwrite(let name):
            return "“\(name)” already exists in the draft folder. Nothing was imported."
        case .toolFailed(let message):
            return "The zip file could not be opened" + (message.isEmpty ? "." : ": \(message)")
        }
    }
}

// MARK: - Importer

nonisolated final class DocumentImporter {

    init() {}

    static let supportedExtensions = ["tex", "zip", "docx"]

    private static let sizeLimit = 3_000_000_000

    static func kind(of url: URL) -> DocumentImportKind? {
        DocumentImportKind(rawValue: url.pathExtension.lowercased())
    }

    // MARK: Entry points

    /// Converts into a temporary folder and reports what an import would do. Nothing is written to a draft.
    func preview(_ url: URL) throws -> DocumentImportResult {
        try withStaging { staging in
            try convert(url, into: staging)
        }
    }

    /// Writes the project files into `destination` (created if missing).
    @discardableResult
    func importDocument(from url: URL, into destination: URL, overwrite: Bool = false) throws -> DocumentImportResult {
        try withStaging { staging in
            let result = try convert(url, into: staging)
            try Self.commit(staging: staging, files: result.files, to: destination, overwrite: overwrite)
            return result
        }
    }

    // MARK: Staging and commit

    private func withStaging<T>(_ body: (URL) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("RBImport-\(UUID().uuidString)", isDirectory: true)
        let staging = base.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        return try body(staging)
    }

    /// Copies the staged files into the destination. If anything fails, files that were
    /// added are removed again and files that were replaced are put back.
    private static func commit(staging: URL, files: [String], to destination: URL, overwrite: Bool) throws {
        let fileManager = FileManager.default

        if !overwrite {
            for file in files where fileManager.fileExists(atPath: destination.appendingPathComponent(file).path) {
                throw DocumentImportError.wouldOverwrite(file)
            }
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let backup = fileManager.temporaryDirectory.appendingPathComponent("RBImportBackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: backup) }

        var created: [URL] = []
        var replaced: [(original: URL, saved: URL)] = []

        do {
            for file in files {
                let target = destination.appendingPathComponent(file)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

                if fileManager.fileExists(atPath: target.path) {
                    let saved = backup.appendingPathComponent(file)
                    try fileManager.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: target, to: saved)
                    replaced.append((original: target, saved: saved))
                }
                try fileManager.copyItem(at: staging.appendingPathComponent(file), to: target)
                created.append(target)
            }
        } catch {
            for url in created { try? fileManager.removeItem(at: url) }
            for item in replaced { try? fileManager.moveItem(at: item.saved, to: item.original) }
            throw error
        }
    }

    /// Every regular file in the staging folder, relative, sorted.
    private static func stagedFiles(_ staging: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        let rootPath = staging.resolvingSymlinksInPath().path
        var found: [String] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPath + "/") else { continue }
            found.append(String(full.dropFirst(rootPath.count + 1)))
        }
        return found.sorted()
    }

    // MARK: Conversion

    private func convert(_ url: URL, into staging: URL) throws -> DocumentImportResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentImportError.fileMissing(url.lastPathComponent)
        }
        guard let kind = Self.kind(of: url) else {
            throw DocumentImportError.unsupportedType(url.pathExtension)
        }
        switch kind {
        case .tex: return try convertTex(url, into: staging)
        case .zip: return try convertZip(url, into: staging)
        case .docx: return try convertDocx(url, into: staging)
        }
    }

    // MARK: .tex

    private func convertTex(_ url: URL, into staging: URL) throws -> DocumentImportResult {
        let fileManager = FileManager.default
        var issues: [DocumentImportIssue] = []

        let read = try Self.readTex(url)
        if read.latin1 {
            issues.append(DocumentImportIssue(
                level: .note,
                message: "The file is not UTF-8 text. It was read as Latin-1 and saved as UTF-8; check accented letters.",
                location: url.lastPathComponent
            ))
        }
        try Data(read.text.utf8).write(to: staging.appendingPathComponent("main.tex"))

        // The files this file uses, when they sit next to it.
        let baseDir = url.deletingLastPathComponent()
        try followReferences(startText: read.text, owner: url.lastPathComponent, baseDir: baseDir, issues: &issues) { match in
            let source = baseDir.appendingPathComponent(match)
            let target = staging.appendingPathComponent(match)
            if fileManager.fileExists(atPath: target.path) { return }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
        }

        let title = Self.texTitle(in: read.text) ?? url.deletingPathExtension().lastPathComponent
        return DocumentImportResult(
            kind: .tex,
            title: title,
            author: nil,
            mainFile: "main.tex",
            files: Self.stagedFiles(staging),
            issues: Self.unique(issues),
            wordCount: Self.approxWords(read.text)
        )
    }

    // MARK: .zip

    private func convertZip(_ url: URL, into staging: URL) throws -> DocumentImportResult {
        let fileManager = FileManager.default
        var issues: [DocumentImportIssue] = []

        let scratch = staging.deletingLastPathComponent().appendingPathComponent("unzipped", isDirectory: true)
        try Self.unzip(url, to: scratch)
        let root = Self.projectRoot(in: scratch)
        let rootPath = root.resolvingSymlinksInPath().path

        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw DocumentImportError.unreadable(url.lastPathComponent) }

        var kept: [String] = []
        var skippedBuild = 0
        var skippedOther = 0
        var total = 0

        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { skippedOther += 1; continue }
            if values?.isDirectory == true {
                if item.lastPathComponent == "__MACOSX" { walker.skipDescendants() }
                continue
            }
            let full = item.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPath + "/") else { skippedOther += 1; continue }
            let relative = String(full.dropFirst(rootPath.count + 1))

            if Self.isBuildLeftover(relative) { skippedBuild += 1; continue }

            total += values?.fileSize ?? 0
            if total > Self.sizeLimit { throw DocumentImportError.tooLarge }
            kept.append(relative)
        }

        let texFiles = kept.filter { $0.lowercased().hasSuffix(".tex") }.sorted()
        guard !texFiles.isEmpty else { throw DocumentImportError.noTexFile }

        // Which .tex file starts the document?
        let starters = texFiles.filter { (Self.readLossy(root.appendingPathComponent($0)) ?? "").contains("\\documentclass") }
        let main: String
        if let exact = starters.first(where: { $0.lowercased() == "main.tex" }) {
            main = exact
        } else if !starters.isEmpty {
            main = starters.sorted { left, right in
                let l = left.split(separator: "/").count
                let r = right.split(separator: "/").count
                return l != r ? l < r : left < right
            }[0]
            if starters.count > 1 {
                issues.append(DocumentImportIssue(
                    level: .note,
                    message: "Several files look like a main file (\(starters.prefix(4).joined(separator: ", "))). \(main) was chosen; change the main file in the draft settings if that is wrong.",
                    location: main
                ))
            }
        } else {
            main = texFiles.first(where: { $0.lowercased() == "main.tex" }) ?? texFiles[0]
            issues.append(DocumentImportIssue(
                level: .warning,
                message: "No .tex file starts a document (none has \\documentclass). \(main) was chosen as the main file; check it.",
                location: main
            ))
        }

        // Copy everything, keeping the folder layout.
        for relative in kept {
            let source = root.appendingPathComponent(relative)
            let target = staging.appendingPathComponent(relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
        }

        // Anything the main file uses that is not in the zip?
        let mainText = Self.readLossy(root.appendingPathComponent(main)) ?? ""
        let mainDir = root.appendingPathComponent(main).deletingLastPathComponent()
        try followReferences(startText: mainText, owner: main, baseDir: mainDir, issues: &issues) { _ in }

        if skippedBuild > 0 {
            issues.append(DocumentImportIssue(
                level: .note,
                message: "\(skippedBuild) build file\(skippedBuild == 1 ? "" : "s") (.aux, .log and similar) were left out. They are rebuilt on the next build.",
                location: nil
            ))
        }
        if skippedOther > 0 {
            issues.append(DocumentImportIssue(
                level: .warning,
                message: "\(skippedOther) item\(skippedOther == 1 ? "" : "s") (links to other places) were not imported.",
                location: nil
            ))
        }

        var words = 0
        for relative in texFiles { words += Self.approxWords(Self.readLossy(root.appendingPathComponent(relative)) ?? "") }

        let title = Self.texTitle(in: mainText) ?? url.deletingPathExtension().lastPathComponent
        return DocumentImportResult(
            kind: .zip,
            title: title,
            author: nil,
            mainFile: main,
            files: Self.stagedFiles(staging),
            issues: Self.unique(issues),
            wordCount: words
        )
    }

    // MARK: .docx

    private func convertDocx(_ url: URL, into staging: URL) throws -> DocumentImportResult {
        let fileManager = FileManager.default

        let scratch = staging.deletingLastPathComponent().appendingPathComponent("docx", isDirectory: true)
        do {
            try Self.unzip(url, to: scratch)
        } catch {
            throw DocumentImportError.notAWordDocument
        }

        let converter = DocxConverter(root: scratch)
        let latex = try converter.convert()

        try Data(latex.utf8).write(to: staging.appendingPathComponent("main.tex"))

        var issues = converter.issues
        for image in converter.images {
            let target = staging.appendingPathComponent(image.name)
            do {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: image.source, to: target)
            } catch {
                issues.append(DocumentImportIssue(
                    level: .warning,
                    message: "The picture “\(image.source.lastPathComponent)” could not be copied into \(image.name).",
                    location: image.name
                ))
            }
        }

        let title = converter.title ?? url.deletingPathExtension().lastPathComponent
        return DocumentImportResult(
            kind: .docx,
            title: title,
            author: converter.author,
            mainFile: "main.tex",
            files: Self.stagedFiles(staging),
            issues: Self.unique(issues),
            wordCount: Self.approxWords(latex)
        )
    }

    // MARK: References inside .tex files

    fileprivate enum RefKind {
        case figure, input, bib, bst, cls, sty

        var warnsIfMissing: Bool {
            switch self {
            case .figure, .input, .bib: return true
            case .bst, .cls, .sty: return false      // usually standard files that ship with LaTeX
            }
        }
    }

    fileprivate struct Ref {
        let kind: RefKind
        let names: [String]
    }

    fileprivate static func references(in text: String) -> [Ref] {
        let source = withoutComments(text)
        var result: [Ref] = []

        func split(_ list: String) -> [String] {
            list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        for group in regexCaptures(#"\\includegraphics\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#, in: source) {
            result.append(Ref(kind: .figure, names: split(group[0])))
        }
        for group in regexCaptures(#"\\(?:input|include)\s*\{([^}]*)\}"#, in: source) {
            result.append(Ref(kind: .input, names: split(group[0])))
        }
        for group in regexCaptures(#"\\(?:bibliography|addbibresource)\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#, in: source) {
            result.append(Ref(kind: .bib, names: split(group[0])))
        }
        for group in regexCaptures(#"\\bibliographystyle\s*\{([^}]*)\}"#, in: source) {
            result.append(Ref(kind: .bst, names: split(group[0])))
        }
        for group in regexCaptures(#"\\documentclass\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#, in: source) {
            result.append(Ref(kind: .cls, names: split(group[0])))
        }
        for group in regexCaptures(#"\\usepackage\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#, in: source) {
            result.append(Ref(kind: .sty, names: split(group[0])))
        }
        return result
    }

    fileprivate static func candidates(_ relative: String, kind: RefKind) -> [String] {
        let hasExtension = !(relative as NSString).pathExtension.isEmpty
        switch kind {
        case .figure:
            return hasExtension ? [relative] : [".png", ".pdf", ".jpg", ".jpeg"].map { relative + $0 }
        case .input:
            return hasExtension ? [relative] : [relative + ".tex"]
        case .bib:
            return hasExtension ? [relative] : [relative + ".bib"]
        case .bst:
            return hasExtension ? [relative] : [relative + ".bst"]
        case .cls:
            return [relative + ".cls"]
        case .sty:
            return [relative + ".sty"]
        }
    }

    /// A path that stays inside its folder, or nil.
    fileprivate static func safeRelative(_ name: String) -> String? {
        var path = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0"), !path.contains("\\") else { return nil }
        let parts = path.components(separatedBy: "/")
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return path
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let folderPath = folder.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(folderPath + "/")
    }

    /// Walks the files a .tex file uses (and the ones those use). `onFound` is called once for each
    /// file that exists next to `baseDir`; files that are missing are listed in `issues`.
    private func followReferences(
        startText: String,
        owner: String,
        baseDir: URL,
        issues: inout [DocumentImportIssue],
        onFound: (String) throws -> Void
    ) throws {
        var visited = Set<String>()
        var queue: [(text: String, owner: String)] = [(startText, owner)]
        var processed = 0

        while !queue.isEmpty && processed < 60 {
            let item = queue.removeFirst()
            processed += 1

            for ref in Self.references(in: item.text) {
                for name in ref.names {
                    guard let relative = Self.safeRelative(name) else {
                        issues.append(DocumentImportIssue(
                            level: .warning,
                            message: "“\(name)” (used in \(item.owner)) has a path that is not allowed, so it was not imported.",
                            location: item.owner
                        ))
                        continue
                    }
                    let match = Self.candidates(relative, kind: ref.kind).first { candidate in
                        let url = baseDir.appendingPathComponent(candidate)
                        return FileManager.default.fileExists(atPath: url.path) && Self.isInside(url, baseDir)
                    }
                    guard let found = match else {
                        if ref.kind.warnsIfMissing {
                            issues.append(DocumentImportIssue(
                                level: .warning,
                                message: "“\(relative)” is used in \(item.owner) but was not found next to the file. Add it to the draft folder.",
                                location: item.owner
                            ))
                        }
                        continue
                    }
                    if !visited.insert(found).inserted { continue }
                    try onFound(found)

                    if ref.kind == .input, let text = Self.readLossy(baseDir.appendingPathComponent(found)) {
                        queue.append((text, found))
                    }
                }
            }
        }
    }

    // MARK: Small helpers

    fileprivate static func withoutComments(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<!\\)%[^\n]*"#, with: "", options: .regularExpression)
    }

    private static func texTitle(in text: String) -> String? {
        guard let raw = regexCaptures(#"\\title\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#, in: withoutComments(text)).first?.first else {
            return nil
        }
        var cleaned = raw.replacingOccurrences(of: #"\\[A-Za-z]+\*?"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[{}\\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func readTex(_ url: URL) throws -> (text: String, latin1: Bool) {
        guard let data = try? Data(contentsOf: url) else { throw DocumentImportError.unreadable(url.lastPathComponent) }
        if var text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return (text, false)
        }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, true) }
        throw DocumentImportError.unreadable(url.lastPathComponent)
    }

    fileprivate static func readLossy(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func isBuildLeftover(_ relative: String) -> Bool {
        let name = (relative as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".synctex.gz") { return true }
        let junk: Set<String> = ["aux", "log", "out", "toc", "lof", "lot", "fls", "fdb_latexmk", "blg"]
        return junk.contains((name as NSString).pathExtension)
    }

    private static func unique(_ issues: [DocumentImportIssue]) -> [DocumentImportIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert("\($0.level)|\($0.message)").inserted }
    }

    /// If the zip holds one single folder (common), the project is inside it.
    private static func projectRoot(in folder: URL) -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        )) ?? []
        let visible = entries.filter { $0.lastPathComponent != "__MACOSX" }
        if visible.count == 1,
           let values = try? visible[0].resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           values.isDirectory == true, values.isSymbolicLink != true {
            return visible[0]
        }
        return folder
    }

    /// Runs the Mac's `ditto` tool to open a zip.
    private static func unzip(_ zip: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DocumentImportError.toolFailed("the zip tool could not be started")
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DocumentImportError.toolFailed(message)
        }
    }

    // MARK: Text helpers

    /// Makes plain text safe to put in a LaTeX file.
    static func escapeLatex(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += #"\textbackslash{}"#
            case "&": out += #"\&"#
            case "%": out += #"\%"#
            case "$": out += #"\$"#
            case "#": out += "\\#"
            case "_": out += #"\_"#
            case "{": out += #"\{"#
            case "}": out += #"\}"#
            case "~": out += #"\textasciitilde{}"#
            case "^": out += #"\textasciicircum{}"#
            case "\u{00A0}": out += "~"
            case "\u{2009}", "\u{202F}": out += #"\,"#
            case "\u{00AD}": out += #"\-"#
            case "\u{2011}": out += "-"
            case "\u{200B}", "\u{FEFF}": break
            case "\n", "\r", "\t", "\r\n": out += " "
            default: out.append(character)
            }
        }
        return out
    }

    /// Approximate words in LaTeX source (comments, commands and citation keys are not counted).
    fileprivate static func approxWords(_ text: String) -> Int {
        var total = 0
        for line in text.components(separatedBy: "\n") {
            var work = line
            if let comment = work.range(of: #"(?<!\\)%"#, options: .regularExpression) {
                work = String(work[..<comment.lowerBound])
            }
            work = work.replacingOccurrences(
                of: #"\\(?:begin|end|cite[A-Za-z]*|ref|eqref|label|usepackage|documentclass|bibliography|bibliographystyle|include|input|includegraphics|href)\*?(?:\[[^\]]*\])*\{[^}]*\}"#,
                with: " ", options: .regularExpression
            )
            work = work.replacingOccurrences(of: #"\\[A-Za-z]+\*?"#, with: " ", options: .regularExpression)
            work = work.replacingOccurrences(of: #"[{}\[\]$&~^_\\]"#, with: " ", options: .regularExpression)
            total += work.split(whereSeparator: { $0.isWhitespace })
                .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
                .count
        }
        return total
    }
}

// MARK: - Regex helper

/// The groups of every match, in order (group 0, the whole match, is left out).
nonisolated private func regexCaptures(_ pattern: String, in text: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
        (1..<match.numberOfRanges).map { index in
            match.range(at: index).location == NSNotFound ? "" : ns.substring(with: match.range(at: index))
        }
    }
}

// MARK: - XML tree

nonisolated private final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func child(_ name: String) -> XNode? {
        children.first { $0.name == name }
    }

    func attr(_ name: String) -> String? {
        attrs[name]
    }

    func descendants(named target: String) -> [XNode] {
        var found: [XNode] = []
        for child in children {
            if child.name == target { found.append(child) }
            found.append(contentsOf: child.descendants(named: target))
        }
        return found
    }
}

nonisolated private final class XTreeBuilder: NSObject, XMLParserDelegate {
    private var root: XNode?
    private var stack: [XNode] = []

    static func parse(_ data: Data, name: String) throws -> XNode {
        let builder = XTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw DocumentImportError.unreadable(name)
        }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XNode(name: elementName, attrs: attributeDict)
        if let top = stack.last { top.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

// MARK: - Word to LaTeX

nonisolated private struct Fmt: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var sup = false
    var sub = false
}

nonisolated private struct Seg {
    var text: String
    var fmt: Fmt
    var raw: Bool
}

nonisolated private final class DocxConverter {

    struct Field {
        var instr = ""
        var inResult = false
        var skip = false
    }

    let root: URL
    var issues: [DocumentImportIssue] = []
    private(set) var title: String?
    private(set) var author: String?
    private(set) var images: [(source: URL, name: String)] = []

    private var noted = Set<String>()
    private var styleNameById: [String: String] = [:]
    private var styleBase: [String: String] = [:]
    private var numFormats: [String: [Int: String]] = [:]
    private var rels: [String: (target: String, external: Bool)] = [:]
    private var footnotes: [String: XNode] = [:]
    private var endnotes: [String: XNode] = [:]

    private var body: [String] = []
    private var listStack: [String] = []
    private var abstractParagraphs: [String] = []
    private var fieldStack: [Field] = []
    private var emitToc = false
    private var usedImageNames = Set<String>()

    private var equationCount = 0
    private var mathApproximate = false
    private var inEquationArray = 0

    private var oddCharacters: [Character] = []

    init(root: URL) {
        self.root = root
    }

    private var isSkipping: Bool {
        fieldStack.contains { $0.skip }
    }

    // MARK: Entry

    func convert() throws -> String {
        guard let document = try load("word/document.xml"), let bodyNode = document.child("w:body") else {
            throw DocumentImportError.notAWordDocument
        }

        loadStyles()
        loadNumbering()
        loadRelationships()
        loadNotes()
        loadCoreProperties()

        blocks(in: bodyNode)
        closeLists()

        if let comments = (try? load("word/comments.xml")) ?? nil {
            let count = comments.children.filter { $0.name == "w:comment" }.count
            if count > 0 {
                note(.note, "The document has \(count) comment\(count == 1 ? "" : "s"). Comments are not imported.")
            }
        }
        if !oddCharacters.isEmpty {
            let list = oddCharacters.map { "“\($0)”" }.joined(separator: " ")
            note(.note, "Some characters (\(list)) may not show with pdfLaTeX. Use XeLaTeX or LuaLaTeX as the build engine, or write them in math mode.")
        }

        var out = "\\documentclass[11pt]{article}\n"
        out += "\\usepackage{amsmath,amssymb}\n"
        out += "\\usepackage{graphicx}\n"
        out += "\\usepackage[hidelinks]{hyperref}\n"

        if let title {
            out += "\\title{\(DocumentImporter.escapeLatex(title))}\n"
            out += "\\author{\(DocumentImporter.escapeLatex(author ?? ""))}\n"
            out += "\\date{}\n"
        }
        out += "\\begin{document}\n"
        if title != nil { out += "\\maketitle\n" }
        if !abstractParagraphs.isEmpty {
            out += "\\begin{abstract}\n" + abstractParagraphs.joined(separator: "\n\n") + "\n\\end{abstract}\n"
        }
        out += "\n" + body.joined(separator: "\n\n") + "\n"
        out += "\n\\end{document}\n"
        return out
    }

    // MARK: Loading parts

    private func load(_ path: String) throws -> XNode? {
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw DocumentImportError.unreadable(path) }
        return try XTreeBuilder.parse(data, name: path)
    }

    private func loadStyles() {
        guard let styles = (try? load("word/styles.xml")) ?? nil else { return }
        for style in styles.children where style.name == "w:style" {
            guard let id = style.attr("w:styleId") else { continue }
            if let name = style.child("w:name")?.attr("w:val") { styleNameById[id] = name.lowercased() }
            if let base = style.child("w:basedOn")?.attr("w:val") { styleBase[id] = base }
        }
    }

    private func loadNumbering() {
        guard let numbering = (try? load("word/numbering.xml")) ?? nil else { return }

        var abstractFormats: [String: [Int: String]] = [:]
        for abstract in numbering.children where abstract.name == "w:abstractNum" {
            guard let id = abstract.attr("w:abstractNumId") else { continue }
            var levels: [Int: String] = [:]
            for level in abstract.children where level.name == "w:lvl" {
                if let index = Int(level.attr("w:ilvl") ?? ""), let format = level.child("w:numFmt")?.attr("w:val") {
                    levels[index] = format
                }
            }
            abstractFormats[id] = levels
        }
        for num in numbering.children where num.name == "w:num" {
            guard let numId = num.attr("w:numId"), let abstractId = num.child("w:abstractNumId")?.attr("w:val") else { continue }
            numFormats[numId] = abstractFormats[abstractId] ?? [:]
        }
    }

    private func loadRelationships() {
        guard let relationships = (try? load("word/_rels/document.xml.rels")) ?? nil else { return }
        for item in relationships.children where item.name == "Relationship" {
            guard let id = item.attr("Id"), let target = item.attr("Target") else { continue }
            rels[id] = (target: target, external: item.attr("TargetMode") == "External")
        }
    }

    private func loadNotes() {
        if let node = (try? load("word/footnotes.xml")) ?? nil {
            for note in node.children where note.name == "w:footnote" {
                if let id = note.attr("w:id"), note.attr("w:type") == nil { footnotes[id] = note }
            }
        }
        if let node = (try? load("word/endnotes.xml")) ?? nil {
            for note in node.children where note.name == "w:endnote" {
                if let id = note.attr("w:id"), note.attr("w:type") == nil { endnotes[id] = note }
            }
        }
    }

    private func loadCoreProperties() {
        guard let core = (try? load("docProps/core.xml")) ?? nil else { return }
        let coreTitle = core.child("dc:title")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let creator = core.child("dc:creator")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !coreTitle.isEmpty { title = coreTitle }
        if !creator.isEmpty { author = creator }
    }

    // MARK: Notes (one message per kind)

    private func note(_ level: DocumentImportIssueLevel, _ message: String) {
        issues.append(DocumentImportIssue(level: level, message: message, location: "main.tex"))
    }

    private func noteOnce(_ key: String, _ level: DocumentImportIssueLevel, _ message: String) {
        if noted.insert(key).inserted { note(level, message) }
    }

    // MARK: Styles

    /// The style's own name, its id, and the names of the styles it is based on.
    private func styleChain(_ id: String?) -> [String] {
        var result: [String] = []
        var current = id
        var hops = 0
        while let styleId = current, hops < 6 {
            if let name = styleNameById[styleId] { result.append(name) }
            result.append(styleId.lowercased())
            current = styleBase[styleId]
            hops += 1
        }
        return result
    }

    private func headingLevel(_ chain: [String], paragraphProperties: XNode?) -> Int? {
        for name in chain {
            if let level = regexCaptures(#"^heading\s*([1-9])$"#, in: name).first?.first, let number = Int(level) {
                return number
            }
        }
        if let outline = paragraphProperties?.child("w:outlineLvl")?.attr("w:val"), let level = Int(outline), level < 9 {
            return level + 1
        }
        return nil
    }

    // MARK: Blocks

    private func blocks(in container: XNode) {
        for node in container.children {
            switch node.name {
            case "w:p":
                handleParagraph(node)
            case "w:tbl":
                handleTable(node)
            case "w:sdt":
                if let content = node.child("w:sdtContent") { blocks(in: content) }
            case "w:ins", "w:customXml", "w:moveTo":
                if node.name == "w:ins" { noteTracked() }
                blocks(in: node)
            case "w:del", "w:moveFrom":
                noteTracked()
            case "mc:AlternateContent":
                if let choice = node.child("mc:Choice") { blocks(in: choice) }
            case "w:sectPr":
                if node.child("w:headerReference") != nil || node.child("w:footerReference") != nil {
                    noteOnce("headers", .note, "Page headers and footers are not imported.")
                }
            default:
                break
            }
        }
    }

    private func noteTracked() {
        noteOnce("tracked", .note, "The document has tracked changes. Insertions were kept and deletions were left out, as if every change was accepted.")
    }

    private func plainText(_ node: XNode) -> String {
        switch node.name {
        case "w:t": return node.text
        case "w:del", "w:instrText", "w:delText": return ""
        case "w:tab": return " "
        default: return node.children.map { plainText($0) }.joined()
        }
    }

    private func handleParagraph(_ paragraph: XNode) {
        let properties = paragraph.child("w:pPr")
        let chain = styleChain(properties?.child("w:pStyle")?.attr("w:val"))

        let inline = renderInline(paragraph.children)

        if emitToc {
            closeLists()
            body.append(#"\tableofcontents"#)
            emitToc = false
            noteOnce("toc", .note, "The table of contents was replaced by \\tableofcontents; LaTeX builds it again.")
        }

        let trimmed = Self.stripEdgeBreaks(inline)
        if trimmed.isEmpty { return }

        if chain.contains("title") {
            let heading = plainText(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty { title = heading }
            return
        }
        if chain.contains("abstract") {
            abstractParagraphs.append(trimmed)
            return
        }

        // Headings
        if let level = headingLevel(chain, paragraphProperties: properties) {
            closeLists()
            let commands = ["section", "subsection", "subsubsection", "paragraph", "subparagraph"]
            let command = commands[min(level, commands.count) - 1]
            let heading = trimmed.replacingOccurrences(of: #"\\"#, with: " ")
            let plain = plainText(paragraph).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let unnumbered: Set<String> = ["references", "bibliography", "acknowledgements", "acknowledgments", "abstract"]
            body.append("\\\(command)\(unnumbered.contains(plain) ? "*" : ""){\(heading)}")
            return
        }

        // List items
        if let numPr = properties?.child("w:numPr"),
           let numId = numPr.child("w:numId")?.attr("w:val"), numId != "0" {
            listItem(trimmed, numId: numId, level: Int(numPr.child("w:ilvl")?.attr("w:val") ?? "0") ?? 0)
            return
        }

        closeLists()

        let alignment = properties?.child("w:jc")?.attr("w:val")
        let isImageOnly = trimmed.hasPrefix(#"\includegraphics"#) && !trimmed.contains(" ") && !trimmed.contains("\n")

        if chain.contains(where: { $0 == "quote" || $0 == "intense quote" || $0 == "block text" }) {
            body.append("\\begin{quote}\n\(trimmed)\n\\end{quote}")
        } else if chain.contains("caption") {
            body.append("\\begin{center}\n\\small \(trimmed)\n\\end{center}")
        } else if isImageOnly || alignment == "center" {
            body.append("\\begin{center}\n\(trimmed)\n\\end{center}")
        } else if alignment == "right" {
            body.append("\\begin{flushright}\n\(trimmed)\n\\end{flushright}")
        } else {
            body.append(trimmed)
        }
    }

    // MARK: Lists

    private func listItem(_ text: String, numId: String, level: Int) {
        let format = numFormats[numId]?[level]
        let environment = (format == nil || format == "bullet" || format == "none") ? "itemize" : "enumerate"

        var target = min(max(level, 0), 3) + 1
        if level > 3 { noteOnce("deeplist", .note, "Lists nested more than four levels deep were flattened to four.") }
        if target > listStack.count + 1 { target = listStack.count + 1 }

        while listStack.count > target { closeOneList() }
        if listStack.count == target, listStack.last != environment { closeOneList() }
        while listStack.count < target {
            body.append("\\begin{\(environment)}")
            listStack.append(environment)
        }
        body.append("\\item \(text)")
    }

    private func closeOneList() {
        guard let environment = listStack.popLast() else { return }
        body.append("\\end{\(environment)}")
    }

    private func closeLists() {
        while !listStack.isEmpty { closeOneList() }
    }

    // MARK: Tables

    private func handleTable(_ table: XNode) {
        closeLists()

        var rows: [[(text: String, span: Int)]] = []
        for row in table.children where row.name == "w:tr" {
            var cells: [(text: String, span: Int)] = []
            for cell in row.children where cell.name == "w:tc" {
                let span = Int(cell.child("w:tcPr")?.child("w:gridSpan")?.attr("w:val") ?? "1") ?? 1
                if cell.child("w:tcPr")?.child("w:vMerge") != nil {
                    noteOnce("vmerge", .warning, "A table has cells merged across rows. Check that table; merged cells are approximate.")
                }
                if cell.children.contains(where: { $0.name == "w:tbl" }) {
                    noteOnce("nested", .warning, "A table inside a table was flattened. Check that table.")
                }
                let parts = cell.children.filter { $0.name == "w:p" }.map { paragraph in
                    Self.stripEdgeBreaks(renderInline(paragraph.children))
                }.filter { !$0.isEmpty }
                cells.append((text: parts.joined(separator: " "), span: max(span, 1)))
            }
            if !cells.isEmpty { rows.append(cells) }
        }

        let columns = rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 0
        if columns == 0 { return }

        let column = "p{\\dimexpr 0.9\\linewidth/\(columns)-2\\tabcolsep\\relax}"
        var lines = ["\\begin{center}", "\\begin{tabular}{|" + String(repeating: column + "|", count: columns) + "}", "\\hline"]

        for row in rows {
            var cells: [String] = []
            var used = 0
            for cell in row {
                if cell.span > 1 {
                    cells.append("\\multicolumn{\(cell.span)}{|p{\\dimexpr 0.9\\linewidth*\(cell.span)/\(columns)-2\\tabcolsep\\relax}|}{\(cell.text)}")
                } else {
                    cells.append(cell.text)
                }
                used += cell.span
            }
            while used < columns { cells.append(""); used += 1 }
            lines.append(cells.joined(separator: " & ") + " \\\\ \\hline")
        }
        lines.append("\\end{tabular}")
        lines.append("\\end{center}")
        body.append(lines.joined(separator: "\n"))
    }

    // MARK: Inline text

    private func renderInline(_ nodes: [XNode]) -> String {
        var segments: [Seg] = []
        collect(nodes, &segments)
        return render(segments)
    }

    private func raw(_ text: String) -> Seg {
        Seg(text: text, fmt: Fmt(), raw: true)
    }

    private func collect(_ nodes: [XNode], _ segments: inout [Seg]) {
        for node in nodes {
            switch node.name {
            case "w:r":
                run(node, &segments)

            case "w:hyperlink":
                var inner: [Seg] = []
                collect(node.children, &inner)
                let text = render(inner)
                if let id = node.attr("r:id"), let rel = rels[id], rel.external, !text.isEmpty {
                    segments.append(raw("\\href{\(Self.escapeURL(rel.target))}{\(text)}"))
                } else {
                    segments.append(contentsOf: inner)
                }

            case "w:fldSimple":
                let instruction = (node.attr("w:instr") ?? "").trimmingCharacters(in: .whitespaces).uppercased()
                if instruction.hasPrefix("TOC") {
                    emitToc = true
                } else {
                    noteCitationField(instruction)
                    collect(node.children, &segments)
                }

            case "w:ins", "w:moveTo":
                if node.name == "w:ins" { noteTracked() }
                collect(node.children, &segments)

            case "w:smartTag", "w:customXml":
                collect(node.children, &segments)

            case "w:sdt":
                if let content = node.child("w:sdtContent") { collect(content.children, &segments) }

            case "mc:AlternateContent":
                if let choice = node.child("mc:Choice") { collect(choice.children, &segments) }

            case "w:del", "w:moveFrom":
                noteTracked()

            case "m:oMathPara":
                if !isSkipping {
                    let text = displayMath(node)
                    if !text.isEmpty { segments.append(raw(text)) }
                }

            case "m:oMath":
                if !isSkipping {
                    let text = equation(node)
                    if !text.isEmpty { segments.append(raw("$" + text + "$")) }
                }

            default:
                break
            }
        }
    }

    private func on(_ node: XNode?) -> Bool {
        guard let node else { return false }
        let value = node.attr("w:val")?.lowercased()
        return !(value == "0" || value == "false" || value == "off")
    }

    private func run(_ run: XNode, _ segments: inout [Seg]) {
        var format = Fmt()

        if let properties = run.child("w:rPr") {
            format.bold = on(properties.child("w:b"))
            format.italic = on(properties.child("w:i"))
            if let underline = properties.child("w:u") {
                format.underline = (underline.attr("w:val") ?? "single") != "none"
            }
            if let align = properties.child("w:vertAlign")?.attr("w:val") {
                if align == "superscript" { format.sup = true }
                if align == "subscript" { format.sub = true }
            }
            if properties.child("w:strike") != nil || properties.child("w:dstrike") != nil {
                noteOnce("strike", .note, "Struck-through text lost its strikethrough.")
            }
            if let styleId = properties.child("w:rStyle")?.attr("w:val") {
                let names = styleChain(styleId)
                if names.contains("strong") { format.bold = true }
                if names.contains("emphasis") { format.italic = true }
            }
        }
        runChildren(run.children, format, &segments)
    }

    private func runChildren(_ children: [XNode], _ format: Fmt, _ segments: inout [Seg]) {
        for child in children {
            switch child.name {
            case "w:t":
                if !isSkipping { segments.append(Seg(text: text(child.text), fmt: format, raw: false)) }

            case "w:tab":
                if !isSkipping { segments.append(Seg(text: " ", fmt: format, raw: false)) }

            case "w:noBreakHyphen":
                if !isSkipping { segments.append(Seg(text: "-", fmt: format, raw: false)) }

            case "w:br", "w:cr":
                if !isSkipping {
                    let type = child.attr("w:type")
                    if type == "page" {
                        segments.append(raw(#"\newpage "#))
                    } else if type != "column" {
                        segments.append(raw(#"\\ "#))
                    }
                }

            case "w:fldChar":
                fieldChar(child)

            case "w:instrText":
                if !fieldStack.isEmpty {
                    var field = fieldStack[fieldStack.count - 1]
                    if !field.inResult {
                        field.instr += child.text
                        fieldStack[fieldStack.count - 1] = field
                    }
                }

            case "w:footnoteReference", "w:endnoteReference":
                if !isSkipping { noteReference(child, &segments) }

            case "w:drawing":
                if !isSkipping { drawing(child, &segments) }

            case "w:pict", "w:object":
                if !isSkipping {
                    noteOnce("pict", .warning, "An old-style picture or embedded object was not imported. Add it to figures/ by hand.")
                }

            case "mc:AlternateContent":
                if let choice = child.child("mc:Choice") { runChildren(choice.children, format, &segments) }

            default:
                break
            }
        }
    }

    /// Escapes text and remembers characters pdfLaTeX may not show.
    private func text(_ value: String) -> String {
        for character in value {
            guard let scalar = character.unicodeScalars.first?.value else { continue }
            let unusual = scalar >= 0x0370 && !(0x2000...0x206F).contains(scalar) && !(0x20A0...0x20CF).contains(scalar)
            if unusual, oddCharacters.count < 8, !oddCharacters.contains(character) {
                oddCharacters.append(character)
            }
        }
        return DocumentImporter.escapeLatex(value)
    }

    private func render(_ segments: [Seg]) -> String {
        var output = ""
        var buffer = ""
        var current: Fmt?

        func flush() {
            if let format = current, !buffer.isEmpty {
                output += Self.wrap(buffer, format)
            }
            buffer = ""
            current = nil
        }

        for segment in segments {
            if segment.raw {
                flush()
                output += segment.text
            } else if current == segment.fmt {
                buffer += segment.text
            } else {
                flush()
                current = segment.fmt
                buffer = segment.text
            }
        }
        flush()
        return output
    }

    private static func wrap(_ text: String, _ format: Fmt) -> String {
        if format == Fmt() { return text }
        let leading = String(text.prefix { $0 == " " })
        let trailing = String(text.reversed().prefix { $0 == " " })
        let core = text.trimmingCharacters(in: .whitespaces)
        if core.isEmpty { return text }

        var result = core
        if format.sub { result = "\\textsubscript{\(result)}" }
        if format.sup { result = "\\textsuperscript{\(result)}" }
        if format.underline { result = "\\underline{\(result)}" }
        if format.italic { result = "\\textit{\(result)}" }
        if format.bold { result = "\\textbf{\(result)}" }
        return leading + result + trailing
    }

    /// A line break at the very start or end of a paragraph would be an error in LaTeX.
    private static func stripEdgeBreaks(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"^(?:\\\\\s*)+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?:\s*\\\\)+$"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "&", with: "\\&")
    }

    // MARK: Fields

    private func fieldChar(_ node: XNode) {
        let type = node.attr("w:fldCharType") ?? ""
        switch type {
        case "begin":
            fieldStack.append(Field())
        case "separate":
            if !fieldStack.isEmpty {
                var field = fieldStack[fieldStack.count - 1]
                field.inResult = true
                let instruction = field.instr.trimmingCharacters(in: .whitespaces).uppercased()
                if instruction.hasPrefix("TOC") {
                    field.skip = true
                    emitToc = true
                }
                noteCitationField(instruction)
                fieldStack[fieldStack.count - 1] = field
            }
        case "end":
            if !fieldStack.isEmpty { fieldStack.removeLast() }
        default:
            break
        }
    }

    private func noteCitationField(_ instruction: String) {
        for marker in ["ZOTERO", "MENDELEY", "EN.CITE", "CITAVI", "CSL_CITATION"] where instruction.contains(marker) {
            noteOnce("citations", .warning,
                     "Citations made with a reference manager stay as plain text. They are not turned into \\cite commands; re-insert them from your library.")
            return
        }
    }

    // MARK: Footnotes and pictures

    private func noteReference(_ node: XNode, _ segments: inout [Seg]) {
        guard let id = node.attr("w:id") else { return }
        let isEndnote = node.name == "w:endnoteReference"
        guard let note = isEndnote ? endnotes[id] : footnotes[id] else { return }

        let parts = note.children.filter { $0.name == "w:p" }.map { paragraph in
            Self.stripEdgeBreaks(renderInline(paragraph.children))
        }.filter { !$0.isEmpty }

        if isEndnote { noteOnce("endnotes", .note, "Endnotes were converted to footnotes.") }
        segments.append(raw("\\footnote{\(parts.joined(separator: " "))}"))
    }

    private func drawing(_ node: XNode, _ segments: inout [Seg]) {
        if let blip = node.descendants(named: "a:blip").first,
           let id = blip.attr("r:embed") ?? blip.attr("r:link"),
           let rel = rels[id], !rel.external {

            var source: URL
            if rel.target.hasPrefix("/") {
                source = root.appendingPathComponent(String(rel.target.dropFirst()))
            } else {
                source = root.appendingPathComponent("word").appendingPathComponent(rel.target)
            }
            source = source.standardizedFileURL

            let rootPath = root.resolvingSymlinksInPath().path
            guard source.resolvingSymlinksInPath().path.hasPrefix(rootPath + "/"),
                  FileManager.default.fileExists(atPath: source.path) else {
                noteOnce("missingpic", .warning, "A picture could not be found inside the Word file and was not imported.")
                return
            }

            let name = uniqueImageName(for: source.lastPathComponent)
            images.append((source: source, name: "figures/" + name))

            let ext = (name as NSString).pathExtension.lowercased()
            if !["png", "jpg", "jpeg", "pdf"].contains(ext) {
                issues.append(DocumentImportIssue(
                    level: .warning,
                    message: "The picture “\(name)” is a .\(ext) file, which LaTeX cannot show. Convert it to PNG or PDF and replace figures/\(name).",
                    location: "figures/\(name)"
                ))
            }
            segments.append(raw("\\includegraphics[width=0.8\\linewidth]{figures/\(name)}"))
        } else if !node.descendants(named: "w:txbxContent").isEmpty {
            noteOnce("textbox", .warning, "A text box was not imported (LaTeX has no text boxes). Its text is missing from the document.")
        } else {
            noteOnce("shape", .warning, "A drawing or shape was not imported.")
        }
    }

    private func uniqueImageName(for original: String) -> String {
        let cleaned = String(original.map { character -> Character in
            (character.isLetter && character.isASCII) || character.isNumber || "-_.".contains(character) ? character : "_"
        })
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = cleaned
        var counter = 2
        while !usedImageNames.insert(candidate.lowercased()).inserted {
            candidate = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    // MARK: Equations (Word's math, OMML, to LaTeX)

    private static let mathSymbols: [Character: String] = [
        "α": #"\alpha"#, "β": #"\beta"#, "γ": #"\gamma"#, "δ": #"\delta"#, "ε": #"\epsilon"#, "ζ": #"\zeta"#,
        "η": #"\eta"#, "θ": #"\theta"#, "ι": #"\iota"#, "κ": #"\kappa"#, "λ": #"\lambda"#, "μ": #"\mu"#,
        "ν": #"\nu"#, "ξ": #"\xi"#, "π": #"\pi"#, "ρ": #"\rho"#, "σ": #"\sigma"#, "τ": #"\tau"#,
        "υ": #"\upsilon"#, "φ": #"\phi"#, "ϕ": #"\varphi"#, "χ": #"\chi"#, "ψ": #"\psi"#, "ω": #"\omega"#,
        "Γ": #"\Gamma"#, "Δ": #"\Delta"#, "Θ": #"\Theta"#, "Λ": #"\Lambda"#, "Ξ": #"\Xi"#, "Π": #"\Pi"#,
        "Σ": #"\Sigma"#, "Φ": #"\Phi"#, "Ψ": #"\Psi"#, "Ω": #"\Omega"#,
        "±": #"\pm"#, "∓": #"\mp"#, "×": #"\times"#, "÷": #"\div"#, "·": #"\cdot"#, "∙": #"\cdot"#,
        "∗": #"\ast"#, "∘": #"\circ"#, "≤": #"\leq"#, "≥": #"\geq"#, "≠": #"\neq"#, "≈": #"\approx"#,
        "≡": #"\equiv"#, "∼": #"\sim"#, "≃": #"\simeq"#, "∝": #"\propto"#, "∞": #"\infty"#, "∂": #"\partial"#,
        "∇": #"\nabla"#, "∈": #"\in"#, "∉": #"\notin"#, "⊂": #"\subset"#, "⊆": #"\subseteq"#,
        "⊃": #"\supset"#, "⊇": #"\supseteq"#, "∪": #"\cup"#, "∩": #"\cap"#, "∅": #"\emptyset"#,
        "∀": #"\forall"#, "∃": #"\exists"#, "¬": #"\neg"#, "∧": #"\wedge"#, "∨": #"\vee"#,
        "→": #"\to"#, "←": #"\leftarrow"#, "↔": #"\leftrightarrow"#, "⇒": #"\Rightarrow"#,
        "⇐": #"\Leftarrow"#, "⇔": #"\Leftrightarrow"#, "↦": #"\mapsto"#, "…": #"\ldots"#, "⋯": #"\cdots"#,
        "⋮": #"\vdots"#, "⋱": #"\ddots"#, "−": "-", "≪": #"\ll"#, "≫": #"\gg"#, "⊥": #"\perp"#,
        "∥": #"\parallel"#, "∠": #"\angle"#, "°": #"^{\circ}"#, "ℓ": #"\ell"#, "′": "'",
        "ℝ": #"\mathbb{R}"#, "ℕ": #"\mathbb{N}"#, "ℤ": #"\mathbb{Z}"#, "ℚ": #"\mathbb{Q}"#, "ℂ": #"\mathbb{C}"#,
        "∑": #"\sum"#, "∏": #"\prod"#, "∫": #"\int"#
    ]

    private static let mathFunctions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "log", "ln", "exp", "lim", "max", "min", "det", "dim", "gcd", "sup", "inf", "arg", "deg", "ker"
    ]

    private static let naryOperators: [String: String] = [
        "∑": #"\sum"#, "∏": #"\prod"#, "∐": #"\coprod"#, "∫": #"\int"#, "∬": #"\iint"#, "∭": #"\iiint"#,
        "∮": #"\oint"#, "⋃": #"\bigcup"#, "⋂": #"\bigcap"#, "⋁": #"\bigvee"#, "⋀": #"\bigwedge"#
    ]

    private static let accents: [String: String] = [
        "\u{0302}": #"\hat"#, "^": #"\hat"#, "\u{030C}": #"\check"#, "\u{0301}": #"\acute"#,
        "\u{0300}": #"\grave"#, "\u{0303}": #"\tilde"#, "~": #"\tilde"#, "\u{0304}": #"\bar"#,
        "¯": #"\bar"#, "\u{0305}": #"\overline"#, "\u{0307}": #"\dot"#, "\u{0308}": #"\ddot"#,
        "\u{20D7}": #"\vec"#, "→": #"\vec"#
    ]

    private func delimiter(_ value: String) -> String {
        switch value {
        case "": return "."
        case "(", ")", "[", "]", "|", "/": return value
        case "{": return #"\{"#
        case "}": return #"\}"#
        case "‖": return #"\|"#
        case "⟨", "〈": return #"\langle"#
        case "⟩", "〉": return #"\rangle"#
        case "⌊": return #"\lfloor"#
        case "⌋": return #"\rfloor"#
        case "⌈": return #"\lceil"#
        case "⌉": return #"\rceil"#
        default: return "."
        }
    }

    private func equation(_ node: XNode) -> String {
        mathApproximate = false
        let result = math(node).trimmingCharacters(in: .whitespacesAndNewlines)
        equationCount += 1
        if mathApproximate {
            issues.append(DocumentImportIssue(
                level: .warning,
                message: "Equation \(equationCount) may not have converted completely. Check it in the PDF.",
                location: "main.tex"
            ))
        }
        return result
    }

    private func displayMath(_ node: XNode) -> String {
        let lines = node.children.filter { $0.name == "m:oMath" }.map { equation($0) }.filter { !$0.isEmpty }
        if lines.isEmpty { return "" }
        if lines.count == 1 { return "\\[ \(lines[0]) \\]" }
        return "\\begin{gather*} " + lines.joined(separator: " \\\\ ") + " \\end{gather*}"
    }

    private func math(_ node: XNode) -> String {
        node.children.map { mathNode($0) }.joined()
    }

    private func mathNode(_ node: XNode) -> String {

        func part(_ name: String) -> String {
            node.child(name).map { math($0) } ?? ""
        }

        switch node.name {
        case "m:r":
            return mathRun(node)

        case "m:f":
            let type = node.child("m:fPr")?.child("m:type")?.attr("m:val")
            let numerator = part("m:num")
            let denominator = part("m:den")
            if type == "lin" { return "{\(numerator)}/{\(denominator)}" }
            if type == "noBar" { return "\\binom{\(numerator)}{\(denominator)}" }
            return "\\frac{\(numerator)}{\(denominator)}"

        case "m:sSup":
            return "{\(part("m:e"))}^{\(part("m:sup"))}"

        case "m:sSub":
            return "{\(part("m:e"))}_{\(part("m:sub"))}"

        case "m:sSubSup":
            return "{\(part("m:e"))}_{\(part("m:sub"))}^{\(part("m:sup"))}"

        case "m:sPre":
            return "{}_{\(part("m:sub"))}^{\(part("m:sup"))}{\(part("m:e"))}"

        case "m:rad":
            let hidden = node.child("m:radPr")?.child("m:degHide")?.attr("m:val")
            let degree = part("m:deg").trimmingCharacters(in: .whitespaces)
            if hidden == "1" || hidden == "true" || degree.isEmpty { return "\\sqrt{\(part("m:e"))}" }
            return "\\sqrt[\(degree)]{\(part("m:e"))}"

        case "m:nary":
            let properties = node.child("m:naryPr")
            let character = properties?.child("m:chr")?.attr("m:val") ?? "∫"
            let op = Self.naryOperators[character] ?? "\\int"
            let hideSub = properties?.child("m:subHide")?.attr("m:val")
            let hideSup = properties?.child("m:supHide")?.attr("m:val")
            let sub = part("m:sub").trimmingCharacters(in: .whitespaces)
            let sup = part("m:sup").trimmingCharacters(in: .whitespaces)
            var out = op
            if !sub.isEmpty, hideSub != "1", hideSub != "true" { out += "_{\(sub)}" }
            if !sup.isEmpty, hideSup != "1", hideSup != "true" { out += "^{\(sup)}" }
            return out + " " + part("m:e")

        case "m:d":
            let properties = node.child("m:dPr")
            let begin = properties?.child("m:begChr").map { $0.attr("m:val") ?? "" } ?? "("
            let end = properties?.child("m:endChr").map { $0.attr("m:val") ?? "" } ?? ")"
            let separator = properties?.child("m:sepChr").map { $0.attr("m:val") ?? "" } ?? "|"
            let separatorText = separator == "|" ? " \\mid " : (separator.isEmpty ? " " : separator + " ")
            let inner = node.children.filter { $0.name == "m:e" }.map { math($0) }.joined(separator: separatorText)
            return "\\left\(delimiter(begin)) \(inner) \\right\(delimiter(end))"

        case "m:func":
            return part("m:fName") + " " + part("m:e")

        case "m:acc":
            let character = node.child("m:accPr")?.child("m:chr")?.attr("m:val") ?? "\u{0302}"
            let command = Self.accents[character] ?? "\\hat"
            return "\(command){\(part("m:e"))}"

        case "m:bar":
            let position = node.child("m:barPr")?.child("m:pos")?.attr("m:val")
            return position == "top" ? "\\overline{\(part("m:e"))}" : "\\underline{\(part("m:e"))}"

        case "m:limLow":
            let base = part("m:e")
            let limit = part("m:lim")
            if base.contains("\\lim") { return "\\lim_{\(limit)}" }
            return "\\underset{\(limit)}{\(base)}"

        case "m:limUpp":
            return "\\overset{\(part("m:lim"))}{\(part("m:e"))}"

        case "m:m":
            let rows = node.children.filter { $0.name == "m:mr" }.map { row in
                row.children.filter { $0.name == "m:e" }.map { math($0) }.joined(separator: " & ")
            }
            return "\\begin{matrix} " + rows.joined(separator: " \\\\ ") + " \\end{matrix}"

        case "m:eqArr":
            inEquationArray += 1
            let rows = node.children.filter { $0.name == "m:e" }.map { math($0) }
            inEquationArray -= 1
            return "\\begin{aligned} " + rows.joined(separator: " \\\\ ") + " \\end{aligned}"

        case "m:e", "m:num", "m:den", "m:sub", "m:sup", "m:deg", "m:lim", "m:fName",
             "m:oMath", "m:box", "m:phant", "m:borderBox":
            return math(node)

        case "m:groupChr":
            mathApproximate = true
            return math(node)

        default:
            if node.name.hasPrefix("m:") && node.name.hasSuffix("Pr") { return "" }
            mathApproximate = true
            return math(node)
        }
    }

    private func mathRun(_ node: XNode) -> String {
        let value = node.children.filter { $0.name == "m:t" }.map { $0.text }.joined()
        if value.isEmpty { return "" }

        let properties = node.child("m:rPr")
        if let normal = properties?.child("m:nor"), normal.attr("m:val") != "0" {
            return "\\text{\(DocumentImporter.escapeLatex(value))}"
        }
        if Self.mathFunctions.contains(value) { return "\\" + value + " " }

        var converted = mathText(value)
        let style = properties?.child("m:sty")?.attr("m:val")
        if style == "p", value.count > 1, value.allSatisfy({ $0.isLetter && $0.isASCII }) {
            converted = "\\mathrm{\(value)}"
        } else if style == "b" || style == "bi" {
            converted = "\\mathbf{\(converted)}"
        }
        return converted
    }

    private func mathText(_ value: String) -> String {
        var out = ""
        for character in value {
            if let symbol = Self.mathSymbols[character] {
                out += symbol + " "
                continue
            }
            switch character {
            case "%": out += "\\%"
            case "&": out += inEquationArray > 0 ? "&" : "\\&"
            case "#": out += "\\#"
            case "_": out += "\\_"
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "$": out += "\\$"
            case "\\": out += "\\backslash "
            case " ", "\u{00A0}": break
            default: out.append(character)
            }
        }
        return out
    }
}
