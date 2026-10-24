//
//  ThesisAssembler.swift
//  ResearchBase
//
//  Owner: Agent 36 · Features: F-39 (thesis mode: several chapters in one master document)
//
//  A thesis is one master file (main.tex) that pulls in one file per chapter
//  (chapters/introduction.tex, chapters/method.tex ...). This service reads that
//  structure, lets the app show the chapters, and REWRITES main.tex when the
//  person drags chapters into a new order, adds a chapter, takes one out, or
//  chooses to build only some chapters. The LaTeX build itself is Agent 24's job;
//  here only the files change.
//
//  PUBLIC API
//    enum   ThesisInclude          .include | .input | .inline
//    struct ThesisChapter          id, title, path, command, inAppendix, exists, words
//    struct ThesisSlot             id + inAppendix: one place in the new order
//    struct ThesisIssue            severity, message, chapterID
//    struct ThesisLayout           chapters, unlisted, issues, usesMarkers, buildOnly, canRearrange
//    struct ThesisNewFile          path + text of a file the plan will create
//    struct ThesisPlan             newMain, newFiles, idMap, summary, mainChanged, createdChapterID
//    struct ThesisCommitReport     createdFiles, idMap
//    enum   ThesisError            LocalizedError
//    struct ThesisAssembler
//      init(chapterFolder: String = "chapters", defaultCommand: ThesisInclude = .include)
//      scan(folder:mainFile:)                        -> ThesisLayout      (reads only)
//      plan(folder:mainFile:order:)                  -> ThesisPlan        (writes nothing)
//      planNewChapter(title:folder:mainFile:)        -> ThesisPlan        (writes nothing)
//      planBuildScope(only:folder:mainFile:)         -> ThesisPlan        (writes nothing)
//      commit(_:folder:mainFile:)                    -> ThesisCommitReport
//      apply(order:folder:mainFile:)                 -> ThesisCommitReport  (plan + commit)
//      static location(draftID:model:)               -> (folder, mainFile, title, kind)
//      static slug(_:) / static wordCount(_:)
//
//  How chapters are found (in the part between \begin{document} and \end{document})
//    - \include{...} lines (any path) and \input{chapters/...} lines are chapters.
//    - A \chapter{...} written straight in main.tex is an "inline" chapter. The first
//      time the order is changed, every inline chapter is moved, word for word, into
//      its own file under chapters/. Text before the first chapter (title page,
//      \chapter*{Declaration}, contents ...) and after the last (bibliography,
//      \end{document}) is never touched.
//    - \appendix splits main chapters from appendix chapters. Appendix chapters
//      always come last, after one generated \appendix line.
//    - The chapter list is written between two marker comments, so it can be
//      rewritten again and again without guessing.
//
//  Safety rules
//    - A plan changes nothing; commit writes new chapter files first (never over an
//      existing file), then main.tex in one atomic step.
//    - A chapter taken out of the thesis only leaves main.tex; its file stays.
//    - Lines that sit BETWEEN chapters and are not chapter lines (for example a
//      \part{...} or \cleardoublepage) would be lost, so the plan stops with an error
//      that names them. Nothing is changed in that case.
//    - Line endings (LF or CRLF) and a missing final newline are kept.
//    - No database access except `location(draftID:model:)`, which only reads.
//

import Foundation

// MARK: - Public types

enum ThesisInclude: String, Equatable {
    case include, input
    /// Written straight in main.tex (no file yet).
    case inline
}

struct ThesisChapter: Equatable, Identifiable {
    /// "chapters/introduction" for a file, "inline:1" for a chapter written inside main.tex.
    var id: String
    var title: String
    /// Path of the .tex file relative to the draft folder; nil for inline chapters.
    var path: String?
    var command: ThesisInclude
    var inAppendix: Bool
    /// The file was found (always true for inline chapters).
    var exists: Bool
    /// Approximate word count of the chapter text.
    var words: Int
}

struct ThesisSlot: Equatable {
    var id: String
    var inAppendix: Bool = false
}

struct ThesisIssue: Equatable {
    enum Severity: Equatable { case info, warning, problem }
    var severity: Severity
    var message: String
    var chapterID: String? = nil
}

struct ThesisLayout {
    /// Chapters that are part of the thesis, in order (main chapters, then appendix chapters).
    var chapters: [ThesisChapter]
    /// .tex files in the chapters folder that main.tex does not use.
    var unlisted: [ThesisChapter]
    var issues: [ThesisIssue]
    /// The chapter list is already inside ResearchBase's marker comments.
    var usesMarkers: Bool
    /// Chapters chosen for a partial build (\includeonly), nil = build everything.
    var buildOnly: [String]?
    /// False when something in main.tex has to be fixed by hand first.
    var canRearrange: Bool

    var hasInlineChapters: Bool { chapters.contains { $0.command == .inline } }
}

struct ThesisNewFile: Equatable {
    var path: String
    var text: String
}

struct ThesisPlan: Equatable {
    var newMain: String
    var newFiles: [ThesisNewFile]
    /// Old chapter id -> new id, for chapters that were inline and are now files.
    var idMap: [String: String]
    /// Plain-words lines describing what will change.
    var summary: [String]
    var mainChanged: Bool
    /// Set by `planNewChapter`.
    var createdChapterID: String?
}

struct ThesisCommitReport: Equatable {
    var createdFiles: [String]
    var idMap: [String: String]
    var mainChanged: Bool
}

enum ThesisError: LocalizedError, Equatable {
    case mainFileMissing(String)
    case unreadable(String)
    case noDocumentBody
    case linesBetweenChapters([String])
    case unknownChapter(String)
    case duplicateChapter(String)
    case notAFileChapter(String)
    case emptyTitle
    case fileExists(String)
    case draftNotFound(String)

    var errorDescription: String? {
        switch self {
        case .mainFileMissing(let name):
            return "The main file \(name) was not found in the draft."
        case .unreadable(let name):
            return "\(name) could not be read as text."
        case .noDocumentBody:
            return "main.tex has no \\begin{document} and \\end{document}, so the chapters cannot be found."
        case .linesBetweenChapters(let lines):
            return "These lines sit between chapters and would be lost: "
                + lines.joined(separator: "; ")
                + ". Move them into a chapter file or outside the chapter list, then try again."
        case .unknownChapter(let id):
            return "The chapter “\(id)” is not part of this thesis."
        case .duplicateChapter(let id):
            return "The chapter “\(id)” appears more than once."
        case .notAFileChapter(let id):
            return "“\(id)” is not an \\include chapter in its own file, so it cannot be built on its own."
        case .emptyTitle:
            return "A chapter needs a title."
        case .fileExists(let path):
            return "\(path) already exists and was not overwritten."
        case .draftNotFound(let id):
            return "Draft \(id) was not found."
        }
    }
}

// MARK: - Assembler

struct ThesisAssembler {

    let chapterFolder: String
    let defaultCommand: ThesisInclude

    init(chapterFolder: String = "chapters", defaultCommand: ThesisInclude = .include) {
        self.chapterFolder = chapterFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.defaultCommand = defaultCommand == .input ? .input : .include
    }

    // MARK: Library lookup

    /// Where a draft lives on disk. Reads only.
    static func location(draftID: String, model: LibraryModel) throws
        -> (folder: URL, mainFile: String, title: String, kind: String) {

        guard let row = try model.database.rows(
            "SELECT title, folder, main_file, kind FROM drafts WHERE id = ? AND deleted_at IS NULL",
            [.text(draftID)]
        ).first, let folderPath = row.text("folder") else {
            throw ThesisError.draftNotFound(draftID)
        }
        let folder = try model.library.url(forRelativePath: folderPath)
        return (folder, row.text("main_file") ?? "main.tex", row.text("title") ?? "Thesis", row.text("kind") ?? "thesis")
    }

    // MARK: Scan

    func scan(folder: URL, mainFile: String = "main.tex") throws -> ThesisLayout {
        let context = try load(folder: folder, mainFile: mainFile)
        return ThesisLayout(
            chapters: context.chapters,
            unlisted: context.unlisted,
            issues: context.issues,
            usesMarkers: context.parsed.usesMarkers,
            buildOnly: context.parsed.buildOnly,
            canRearrange: context.parsed.strays.isEmpty && context.duplicateID == nil)
    }

    // MARK: Plans

    /// The thesis as it should be: chapters in this order. Chapters left out of `order`
    /// leave main.tex but keep their files. Appendix slots are placed last.
    func plan(folder: URL, mainFile: String = "main.tex", order: [ThesisSlot]) throws -> ThesisPlan {
        let context = try load(folder: folder, mainFile: mainFile)
        return try makePlan(context, folder: folder, slots: order, extra: [])
    }

    /// Adds a new, empty chapter file at the end of the main chapters.
    func planNewChapter(title: String, folder: URL, mainFile: String = "main.tex") throws -> ThesisPlan {

        let clean = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !clean.isEmpty else { throw ThesisError.emptyTitle }

        let context = try load(folder: folder, mainFile: mainFile)

        var used = rbA36_existingChapterFiles(folder: folder, chapterFolder: chapterFolder)
        for chapter in context.chapters { if let path = chapter.path { used.insert(path.lowercased()) } }
        let path = rbA36_uniquePath(base: Self.slug(clean), folder: chapterFolder, used: &used)
        let id = rbA36_normalisedID(path)

        let text = "\\chapter{\(rbA36_escapeLatex(clean))}\n\\label{ch:\(Self.slug(clean))}\n\n"
        var slots = context.chapters.map { ThesisSlot(id: $0.id, inAppendix: $0.inAppendix) }
        let at = slots.lastIndex(where: { !$0.inAppendix }).map { $0 + 1 } ?? 0
        slots.insert(ThesisSlot(id: id, inAppendix: false), at: at)

        var plan = try makePlan(context, folder: folder, slots: slots, extra: [ThesisNewFile(path: path, text: text)])
        plan.createdChapterID = id
        plan.summary.insert("Adds the chapter “\(clean)” as \(path).", at: 0)
        return plan
    }

    /// Build only these chapters (\includeonly), or everything when `only` is nil.
    func planBuildScope(only: [String]?, folder: URL, mainFile: String = "main.tex") throws -> ThesisPlan {

        let context = try load(folder: folder, mainFile: mainFile)
        let parsed = context.parsed
        var lines = parsed.source.lines
        var summary: [String] = []

        if let only {
            for id in only {
                guard let n = context.ids.firstIndex(of: id) else { throw ThesisError.unknownChapter(id) }
                guard parsed.entries[n].kind == .include else { throw ThesisError.notAFileChapter(id) }
            }
        }

        let block: [String]? = only.map { ids in
            [rbA36_scopeStart, "\\includeonly{\(ids.joined(separator: ","))}", rbA36_scopeEnd]
        }

        if let range = parsed.scopeRange {
            if let block { lines.replaceSubrange(range, with: block) }
            else { lines.removeSubrange(range) }
        } else if let block {
            var insert = block
            if parsed.beginIndex > 0, !lines[parsed.beginIndex - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insert.insert("", at: 0)
            }
            lines.insert(contentsOf: insert, at: parsed.beginIndex)
        }

        if let only { summary.append("Builds only: " + only.joined(separator: ", ") + ".") }
        else if parsed.scopeRange != nil { summary.append("Builds the whole thesis again.") }

        var source = parsed.source
        source.lines = lines
        let newMain = source.render()
        return ThesisPlan(newMain: newMain, newFiles: [], idMap: [:], summary: summary,
                          mainChanged: newMain != context.text, createdChapterID: nil)
    }

    // MARK: Commit

    /// Writes the plan: new chapter files first (never over an existing file), then main.tex in one step.
    @discardableResult
    func commit(_ plan: ThesisPlan, folder: URL, mainFile: String = "main.tex") throws -> ThesisCommitReport {

        let manager = FileManager.default

        for file in plan.newFiles {
            let url = folder.appendingPathComponent(file.path)
            if manager.fileExists(atPath: url.path) { throw ThesisError.fileExists(file.path) }
        }

        var created: [String] = []
        for file in plan.newFiles {
            let url = folder.appendingPathComponent(file.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try Data(file.text.utf8).write(to: url, options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw ThesisError.fileExists(file.path)
            }
            created.append(file.path)
        }

        if plan.mainChanged {
            try Data(plan.newMain.utf8).write(to: folder.appendingPathComponent(mainFile), options: .atomic)
        }
        return ThesisCommitReport(createdFiles: created, idMap: plan.idMap, mainChanged: plan.mainChanged)
    }

    /// Plan and commit in one step.
    @discardableResult
    func apply(order: [ThesisSlot], folder: URL, mainFile: String = "main.tex") throws -> ThesisCommitReport {
        try commit(try plan(folder: folder, mainFile: mainFile, order: order), folder: folder, mainFile: mainFile)
    }

    // MARK: Small public helpers

    /// "Results & Discussion" -> "results-discussion". Never empty.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var out = ""
        var lastDash = true
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if out.count > 40 { out = String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return out.isEmpty ? "chapter" : out
    }

    /// Rough number of words in LaTeX text: comments and commands are ignored.
    static func wordCount(_ latex: String) -> Int {
        var text = latex.split(separator: "\n", omittingEmptySubsequences: false)
            .map { rbA36_code(String($0)) }.joined(separator: "\n")
        text = text.replacingOccurrences(of: "\\\\[A-Za-z@]+\\*?", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "[{}\\\\$&~^_]", with: " ", options: .regularExpression)
        return text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}

// MARK: - Loading (private)

private struct rbA36_Context {
    var text: String
    var parsed: rbA36_Parsed
    /// Chapters in main.tex order (parallel to `parsed.entries`).
    var chapters: [ThesisChapter]
    var ids: [String]
    var unlisted: [ThesisChapter]
    var issues: [ThesisIssue]
    var duplicateID: String?
}

extension ThesisAssembler {

    fileprivate func load(folder: URL, mainFile: String) throws -> rbA36_Context {

        let manager = FileManager.default
        let mainURL = folder.appendingPathComponent(mainFile)
        guard manager.fileExists(atPath: mainURL.path) else { throw ThesisError.mainFileMissing(mainFile) }
        guard let data = try? Data(contentsOf: mainURL), let text = String(data: data, encoding: .utf8) else {
            throw ThesisError.unreadable(mainFile)
        }

        let parsed = try rbA36_parse(text, chapterFolder: chapterFolder)

        var chapters: [ThesisChapter] = []
        var ids: [String] = []
        var issues: [ThesisIssue] = []
        var seen: [String: Int] = [:]
        var duplicate: String?
        var inlineCount = 0

        for entry in parsed.entries {
            switch entry.kind {

            case .inline:
                inlineCount += 1
                let id = "inline:\(inlineCount)"
                chapters.append(ThesisChapter(
                    id: id, title: entry.title.isEmpty ? "Chapter \(inlineCount)" : entry.title, path: nil,
                    command: .inline, inAppendix: entry.inAppendix, exists: true,
                    words: Self.wordCount(entry.inlineLines.joined(separator: "\n"))))
                ids.append(id)

            case .include, .input:
                let written = entry.path ?? ""
                var id = rbA36_normalisedID(written)
                seen[id, default: 0] += 1
                if seen[id]! > 1 {
                    duplicate = duplicate ?? id
                    issues.append(ThesisIssue(severity: .problem, message: "The chapter “\(id)” is used more than once.", chapterID: id))
                    id += "#\(seen[id]!)"
                }

                let url = rbA36_fileURL(folder: folder, written: written)
                var title = ThesisAssembler.rbA36_humanise(id)
                var words = 0
                if let url, let body = try? String(contentsOf: url, encoding: .utf8) {
                    words = Self.wordCount(body)
                    if let found = rbA36_firstChapterTitle(in: body) { title = found.isEmpty ? title : found }
                    else {
                        issues.append(ThesisIssue(
                            severity: .warning,
                            message: "\(written) has no \\chapter command, so it does not start a new chapter.", chapterID: id))
                    }
                } else if url == nil {
                    issues.append(ThesisIssue(
                        severity: .problem, message: "The file for “\(written)” was not found.", chapterID: id))
                }
                if written.lowercased().hasSuffix(".tex") {
                    issues.append(ThesisIssue(
                        severity: .warning,
                        message: "\\\(entry.kind.rawValue){\(written)}: leave out the .tex ending.", chapterID: id))
                }

                chapters.append(ThesisChapter(
                    id: id, title: title, path: rbA36_filePath(written), command: entry.kind,
                    inAppendix: entry.inAppendix, exists: url != nil, words: words))
                ids.append(id)
            }
        }

        // Files in the chapters folder that main.tex does not use.
        var unlisted: [ThesisChapter] = []
        let listed = Set(ids)
        for name in ((try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent(chapterFolder).path)) ?? []).sorted()
        where name.lowercased().hasSuffix(".tex") && !name.hasPrefix(".") {
            let relative = "\(chapterFolder)/\(name)"
            let id = rbA36_normalisedID(relative)
            if listed.contains(id) { continue }
            let body = (try? String(contentsOf: folder.appendingPathComponent(relative), encoding: .utf8)) ?? ""
            var title = ThesisAssembler.rbA36_humanise(id)
            if let found = rbA36_firstChapterTitle(in: body), !found.isEmpty { title = found }
            unlisted.append(ThesisChapter(id: id, title: title, path: relative, command: defaultCommand,
                                          inAppendix: false, exists: true, words: Self.wordCount(body)))
        }

        if inlineCount > 0 {
            issues.append(ThesisIssue(
                severity: .info,
                message: "\(inlineCount) chapter\(inlineCount == 1 ? " is" : "s are") written inside main.tex. "
                    + "They are moved into files in \(chapterFolder)/ the first time you change the chapters."))
        }
        for stray in parsed.strays {
            issues.append(ThesisIssue(
                severity: .problem,
                message: "Line \(stray.index + 1) (\(stray.text.trimmingCharacters(in: .whitespaces))) sits between chapters. "
                    + "Move it into a chapter file or outside the chapter list before reordering."))
        }
        if !unlisted.isEmpty {
            issues.append(ThesisIssue(
                severity: .info,
                message: "\(unlisted.count) file\(unlisted.count == 1 ? "" : "s") in \(chapterFolder)/ "
                    + "\(unlisted.count == 1 ? "is" : "are") not part of the thesis."))
        }
        if let only = parsed.buildOnly {
            issues.append(ThesisIssue(severity: .info, message: "Building only: " + only.joined(separator: ", ") + "."))
        }

        return rbA36_Context(text: text, parsed: parsed, chapters: chapters, ids: ids,
                             unlisted: unlisted, issues: issues, duplicateID: duplicate)
    }

    fileprivate static func rbA36_humanise(_ id: String) -> String {
        let base = (id as NSString).lastPathComponent
        let words = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return base }
        return String(first).uppercased() + words.dropFirst()
    }

    fileprivate func makePlan(_ context: rbA36_Context, folder: URL, slots: [ThesisSlot], extra: [ThesisNewFile]) throws -> ThesisPlan {

        let parsed = context.parsed

        if !parsed.strays.isEmpty {
            throw ThesisError.linesBetweenChapters(parsed.strays.map {
                "line \($0.index + 1): \($0.text.trimmingCharacters(in: .whitespaces))"
            })
        }
        if let duplicate = context.duplicateID { throw ThesisError.duplicateChapter(duplicate) }

        var entryByID: [String: Int] = [:]
        for (n, id) in context.ids.enumerated() { entryByID[id] = n }
        var otherKnown = Set(context.unlisted.map(\.id))
        for file in extra { otherKnown.insert(rbA36_normalisedID(file.path)) }

        var seen = Set<String>()
        for slot in slots {
            guard entryByID[slot.id] != nil || otherKnown.contains(slot.id) else { throw ThesisError.unknownChapter(slot.id) }
            guard seen.insert(slot.id).inserted else { throw ThesisError.duplicateChapter(slot.id) }
        }

        // Inline chapters always become files, so no text can be lost.
        var used = rbA36_existingChapterFiles(folder: folder, chapterFolder: chapterFolder)
        for chapter in context.chapters { if let path = chapter.path { used.insert(path.lowercased()) } }
        for file in extra { used.insert(file.path.lowercased()) }

        var newFiles = extra
        var idMap: [String: String] = [:]
        var movedTitles: [String] = []
        for (n, entry) in parsed.entries.enumerated() where entry.kind == .inline {
            let title = entry.title.isEmpty ? "chapter" : entry.title
            let path = rbA36_uniquePath(base: Self.slug(title), folder: chapterFolder, used: &used)
            newFiles.append(ThesisNewFile(path: path, text: entry.inlineLines.joined(separator: "\n") + "\n"))
            idMap[context.ids[n]] = rbA36_normalisedID(path)
            movedTitles.append(entry.title.isEmpty ? "Chapter \(n + 1)" : entry.title)
        }

        struct Placed {
            var command: ThesisInclude
            var raw: String?
            var path: String
            var leading: [String]
            var inAppendix: Bool
        }

        var placed: [Placed] = []
        for slot in slots {
            if let n = entryByID[slot.id] {
                let entry = parsed.entries[n]
                if entry.kind == .inline {
                    placed.append(Placed(command: defaultCommand, raw: nil, path: idMap[slot.id] ?? slot.id,
                                         leading: entry.leading, inAppendix: slot.inAppendix))
                } else {
                    placed.append(Placed(command: entry.kind, raw: entry.rawLine, path: entry.path ?? slot.id,
                                         leading: entry.leading, inAppendix: slot.inAppendix))
                }
            } else {
                placed.append(Placed(command: defaultCommand, raw: nil, path: slot.id, leading: [], inAppendix: slot.inAppendix))
            }
        }

        let ordered = placed.filter { !$0.inAppendix } + placed.filter { $0.inAppendix }

        var block: [String] = [rbA36_chaptersStart]
        var appendixOpen = false
        for item in ordered {
            if item.inAppendix, !appendixOpen { block.append("\\appendix"); appendixOpen = true }
            block.append(contentsOf: item.leading)
            block.append(item.raw ?? "\\\(item.command.rawValue){\(item.path)}")
        }
        block.append(contentsOf: parsed.trailingComments)
        block.append(rbA36_chaptersEnd)

        var lines = parsed.source.lines
        if let start = parsed.regionStart {
            lines.replaceSubrange(start..<parsed.regionEnd, with: block)
        } else if !ordered.isEmpty || !newFiles.isEmpty {
            var insert = block
            let at = parsed.insertAt
            if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert.insert("", at: 0) }
            if at < lines.count, !lines[at].trimmingCharacters(in: .whitespaces).isEmpty { insert.append("") }
            lines.insert(contentsOf: insert, at: at)
        }

        var source = parsed.source
        source.lines = lines
        let newMain = source.render()

        // Plain-words summary.
        var summary: [String] = []
        if !movedTitles.isEmpty {
            summary.append("Moves \(movedTitles.count) chapter\(movedTitles.count == 1 ? "" : "s") written inside main.tex "
                + "into files in \(chapterFolder)/: " + movedTitles.joined(separator: ", ") + ".")
        }
        let kept = Set(slots.map(\.id))
        let removed = context.chapters.filter { !kept.contains($0.id) }
        if !removed.isEmpty {
            summary.append("Takes \(removed.count) chapter\(removed.count == 1 ? "" : "s") out of the thesis (the files are kept): "
                + removed.map(\.title).joined(separator: ", ") + ".")
        }
        let before = context.chapters.map(\.id).map { idMap[$0] ?? $0 }
        let after = ordered.map { rbA36_normalisedID($0.path) }
        if before != after, removed.isEmpty, movedTitles.isEmpty { summary.append("Changes the order of the chapters.") }
        let wasAppendix = Set(context.chapters.filter(\.inAppendix).map { idMap[$0.id] ?? $0.id })
        let nowAppendix = Set(ordered.filter(\.inAppendix).map { rbA36_normalisedID($0.path) })
        if wasAppendix != nowAppendix { summary.append("Changes which chapters are appendices.") }

        return ThesisPlan(newMain: newMain, newFiles: newFiles, idMap: idMap, summary: summary,
                          mainChanged: newMain != context.text, createdChapterID: nil)
    }
}

// MARK: - Parsing main.tex (private)

private let rbA36_chaptersStart = "% >>> ResearchBase thesis chapters (generated: change the order in the app, not here) >>>"
private let rbA36_chaptersEnd = "% <<< ResearchBase thesis chapters <<<"
private let rbA36_scopeStart = "% >>> ResearchBase build scope (generated: chosen in the app) >>>"
private let rbA36_scopeEnd = "% <<< ResearchBase build scope <<<"

private struct rbA36_Source {
    var lines: [String]
    var crlf: Bool
    var trailingNewline: Bool

    init(text: String) {
        var t = text
        crlf = t.contains("\r\n")
        if crlf { t = t.replacingOccurrences(of: "\r\n", with: "\n") }
        trailingNewline = t.hasSuffix("\n")
        var parts = t.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if trailingNewline, parts.last == "" { parts.removeLast() }
        lines = parts
    }

    func render() -> String {
        let eol = crlf ? "\r\n" : "\n"
        return lines.joined(separator: eol) + (trailingNewline ? eol : "")
    }
}

private struct rbA36_Entry {
    var kind: ThesisInclude
    var path: String?
    var rawLine: String?
    var title: String
    var inlineLines: [String]
    var inAppendix: Bool
    var leading: [String]
}

private struct rbA36_Parsed {
    var source: rbA36_Source
    var beginIndex: Int
    var endIndex: Int
    var regionStart: Int?
    var regionEnd: Int
    var insertAt: Int
    var entries: [rbA36_Entry]
    var trailingComments: [String]
    var strays: [(index: Int, text: String)]
    var usesMarkers: Bool
    var buildOnly: [String]?
    var scopeRange: Range<Int>?
}

private enum rbA36_Kind: Equatable {
    case blank, comment, beginDocument, endDocument, appendix, boundary
    case include(String)
    case input(String)
    case chapter(starred: Bool, title: String)
    case other
}

/// The part of a line before an unescaped %.
private func rbA36_code(_ line: String) -> String {
    var out = ""
    var escaped = false
    for ch in line {
        if escaped { out.append(ch); escaped = false; continue }
        if ch == "\\" { out.append(ch); escaped = true; continue }
        if ch == "%" { break }
        out.append(ch)
    }
    return out
}

private func rbA36_matching(_ c: [Character], _ start: Int) -> Int? {
    var depth = 0
    var j = start
    while j < c.count {
        let ch = c[j]
        if ch == "\\" { j += 2; continue }
        if ch == "{" { depth += 1 }
        else if ch == "}" {
            depth -= 1
            if depth == 0 { return j }
        }
        j += 1
    }
    return nil
}

/// `\name{arg}` and nothing else on the line.
private func rbA36_soleArgument(_ code: String, _ name: String) -> String? {
    let prefix = "\\" + name
    guard code.hasPrefix(prefix) else { return nil }
    let rest = Array(code.dropFirst(prefix.count))
    var i = 0
    if i < rest.count, rest[i].isLetter { return nil }
    while i < rest.count, rest[i] == " " { i += 1 }
    guard i < rest.count, rest[i] == "{", let close = rbA36_matching(rest, i) else { return nil }
    let tail = String(rest[(close + 1)...]).trimmingCharacters(in: .whitespaces)
    guard tail.isEmpty else { return nil }
    return String(rest[(i + 1)..<close]).trimmingCharacters(in: .whitespaces)
}

private func rbA36_plainTitle(_ raw: String) -> String {
    var s = raw
    s = s.replacingOccurrences(of: "\\\\([&%$#_])", with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\\\[A-Za-z@]+\\*?", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
    return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

private func rbA36_chapterKind(_ code: String) -> rbA36_Kind? {
    let prefix = "\\chapter"
    guard code.hasPrefix(prefix) else { return nil }
    let rest = Array(code.dropFirst(prefix.count))
    var i = 0
    if i < rest.count, rest[i].isLetter { return nil }
    var starred = false
    if i < rest.count, rest[i] == "*" { starred = true; i += 1 }
    while i < rest.count, rest[i] == " " { i += 1 }
    if i < rest.count, rest[i] == "[" {
        while i < rest.count, rest[i] != "]" { i += 1 }
        i += 1
    }
    while i < rest.count, rest[i] == " " { i += 1 }
    var title = ""
    if i < rest.count, rest[i] == "{", let close = rbA36_matching(rest, i) {
        title = rbA36_plainTitle(String(rest[(i + 1)..<close]))
    }
    return .chapter(starred: starred, title: title)
}

private func rbA36_classify(_ line: String) -> rbA36_Kind {
    let code = rbA36_code(line).trimmingCharacters(in: .whitespaces)
    if code.isEmpty { return line.trimmingCharacters(in: .whitespaces).isEmpty ? .blank : .comment }
    if code.contains("\\begin{document}") { return .beginDocument }
    if code.contains("\\end{document}") { return .endDocument }
    if let path = rbA36_soleArgument(code, "include") { return .include(path) }
    if let path = rbA36_soleArgument(code, "input") { return .input(path) }
    if code == "\\appendix" { return .appendix }
    for token in ["\\bibliography", "\\printbibliography", "\\backmatter", "\\begin{thebibliography}", "\\printindex"]
    where code.contains(token) { return .boundary }
    if let chapter = rbA36_chapterKind(code) { return chapter }
    return .other
}

private func rbA36_firstChapterTitle(in text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if case .chapter(_, let title) = rbA36_classify(String(line)) { return title }
    }
    return nil
}

private func rbA36_parse(_ text: String, chapterFolder: String) throws -> rbA36_Parsed {

    let source = rbA36_Source(text: text)
    let lines = source.lines

    guard let begin = lines.firstIndex(where: { rbA36_code($0).contains("\\begin{document}") }),
          let end = lines.lastIndex(where: { rbA36_code($0).contains("\\end{document}") }), end > begin else {
        throw ThesisError.noDocumentBody
    }

    // Generated blocks written by an earlier run.
    var markerStart: Int?
    var markerEnd: Int?
    for i in (begin + 1)..<end {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if markerStart == nil, t.hasPrefix("% >>> ResearchBase thesis chapters") { markerStart = i }
        else if markerStart != nil, markerEnd == nil, t.hasPrefix("% <<< ResearchBase thesis chapters") { markerEnd = i }
    }
    if markerEnd == nil { markerStart = nil }

    var scopeRange: Range<Int>?
    var buildOnly: [String]?
    var scopeStart: Int?
    for i in 0..<begin {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if scopeStart == nil, t.hasPrefix("% >>> ResearchBase build scope") { scopeStart = i }
        else if let s = scopeStart, t.hasPrefix("% <<< ResearchBase build scope") {
            scopeRange = s..<(i + 1)
            for k in (s + 1)..<i {
                if let arg = rbA36_soleArgument(rbA36_code(lines[k]).trimmingCharacters(in: .whitespaces), "includeonly") {
                    buildOnly = arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            }
            break
        }
    }

    let scanStart = markerStart.map { $0 + 1 } ?? (begin + 1)
    let stopAt = markerEnd ?? end

    var entries: [rbA36_Entry] = []
    var strays: [(index: Int, text: String)] = []
    var pending: [String] = []
    var inAppendix = false
    var regionStart: Int? = markerStart
    var lastEnd = scanStart
    var openChapter: (entry: Int, start: Int)?
    var stoppedAt = stopAt

    func closeInline(at index: Int) {
        guard let current = openChapter else { return }
        var chunk = Array(lines[current.start..<index])
        while let last = chunk.last, last.trimmingCharacters(in: .whitespaces).isEmpty { chunk.removeLast() }
        entries[current.entry].inlineLines = chunk
        lastEnd = current.start + chunk.count
        openChapter = nil
    }

    var index = scanStart
    scanLoop: while index < stopAt {
        let line = lines[index]
        let kind = rbA36_classify(line)

        switch kind {

        case .blank:
            break

        case .comment:
            if openChapter == nil, regionStart != nil { pending.append(line) }

        case .appendix:
            if regionStart == nil { regionStart = index }
            closeInline(at: index)
            inAppendix = true

        case .boundary:
            closeInline(at: index)
            stoppedAt = index
            break scanLoop

        case .include(let path):
            if regionStart == nil { regionStart = index }
            closeInline(at: index)
            entries.append(rbA36_Entry(kind: .include, path: path, rawLine: line, title: "", inlineLines: [],
                                       inAppendix: inAppendix, leading: pending))
            pending = []
            lastEnd = index + 1

        case .input(let path) where path.hasPrefix(chapterFolder + "/"):
            if regionStart == nil { regionStart = index }
            closeInline(at: index)
            entries.append(rbA36_Entry(kind: .input, path: path, rawLine: line, title: "", inlineLines: [],
                                       inAppendix: inAppendix, leading: pending))
            pending = []
            lastEnd = index + 1

        case .chapter(let starred, let title) where regionStart != nil || !starred:
            if regionStart == nil { regionStart = index }
            closeInline(at: index)
            entries.append(rbA36_Entry(kind: .inline, path: nil, rawLine: nil, title: title, inlineLines: [],
                                       inAppendix: inAppendix, leading: pending))
            pending = []
            openChapter = (entries.count - 1, index)

        default:
            // Other text: part of an inline chapter, front matter before the list, or a stray line.
            if openChapter == nil, regionStart != nil { strays.append((index, line)) }
        }
        index += 1
    }
    closeInline(at: stoppedAt)

    // A thesis with no chapters yet: the list goes before the first appendix / bibliography / end.
    var insertAt = end
    for i in (begin + 1)..<end {
        let k = rbA36_classify(lines[i])
        if k == .appendix || k == .boundary { insertAt = i; break }
    }

    let usesMarkers = markerStart != nil
    if entries.isEmpty, !usesMarkers { regionStart = nil }

    let regionEnd = usesMarkers ? (markerEnd! + 1) : lastEnd
    let trailing = usesMarkers ? pending : []

    // Lines after the last chapter are not "between chapters" unless markers hold the list.
    let lostStrays = usesMarkers ? strays : strays.filter { $0.index < lastEnd }

    return rbA36_Parsed(
        source: source, beginIndex: begin, endIndex: end, regionStart: regionStart, regionEnd: regionEnd,
        insertAt: insertAt, entries: entries, trailingComments: trailing, strays: lostStrays,
        usesMarkers: usesMarkers, buildOnly: buildOnly, scopeRange: scopeRange)
}

// MARK: - Files and names (private)

/// "./chapters/intro.tex" -> "chapters/intro"
private func rbA36_normalisedID(_ written: String) -> String {
    var s = written.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("./") { s = String(s.dropFirst(2)) }
    if s.lowercased().hasSuffix(".tex") { s = String(s.dropLast(4)) }
    return s
}

/// The path to show for a chapter written as `written`.
private func rbA36_filePath(_ written: String) -> String {
    let id = rbA36_normalisedID(written)
    return id + ".tex"
}

private func rbA36_fileURL(folder: URL, written: String) -> URL? {
    let id = rbA36_normalisedID(written)
    guard !id.isEmpty, !id.hasPrefix("/"), !id.contains("..") else { return nil }
    let url = folder.appendingPathComponent(id + ".tex")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// Lower-cased relative paths of the .tex files in the chapters folder.
private func rbA36_existingChapterFiles(folder: URL, chapterFolder: String) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(chapterFolder).path)) ?? []
    return Set(names.map { "\(chapterFolder)/\($0)".lowercased() })
}

private func rbA36_uniquePath(base: String, folder: String, used: inout Set<String>) -> String {
    var candidate = "\(folder)/\(base).tex"
    var number = 2
    while used.contains(candidate.lowercased()) {
        candidate = "\(folder)/\(base)-\(number).tex"
        number += 1
    }
    used.insert(candidate.lowercased())
    return candidate
}

private func rbA36_escapeLatex(_ text: String) -> String {
    var out = ""
    for ch in text {
        switch ch {
        case "\\": out += "\\textbackslash{}"
        case "&", "%", "$", "#", "_", "{", "}": out += "\\" + String(ch)
        case "~": out += "\\textasciitilde{}"
        case "^": out += "\\textasciicircum{}"
        default: out.append(ch)
        }
    }
    return out
}
