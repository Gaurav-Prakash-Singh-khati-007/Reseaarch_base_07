//
//  LatexEditorView.swift
//  ResearchBase
//
//  Owner: Agent 39 · Features: F-30, L-03
//
//  The LaTeX source editor: syntax colouring (Agent 33's LatexHighlighter), outline, find and
//  replace (the system find bar, ⌘F), spell check, word count, and autocomplete:
//    \cite{   -> searches the library (key, authors, title, year)
//    \ref{    -> lists the \label{} names of the draft
//
//  Two layers:
//    1. Pure logic (`LatexAutocomplete`, `LatexOutline`, `LatexTextStats`, `LatexCitationSource`).
//       No UI, easy to test. Offsets are UTF-16, like every Cocoa text range.
//    2. `LatexEditorView` (SwiftUI) around an NSTextView.
//
//  The editor only edits the string it is given. Saving the file is the caller's job (WritingView).
//  It reads the library, it never writes to it.
//
//  PUBLIC API
//    struct LatexEditorView: View
//        init(text: Binding<String>, model: LibraryModel? = nil, libraryRevision: Int = 0,
//             extraLabels: [LatexLabel] = [], jump: LatexEditorJump? = nil,
//             fontSize: CGFloat = 13, showsOutline: Bool = true)
//          model            nil = no library: \cite is coloured plainly and has no suggestions
//          libraryRevision  change it to make the editor reload the citation keys
//          extraLabels      labels that live in other files of the draft (for \ref{ })
//          jump             a new LatexEditorJump (new id) moves the caret and scrolls to the line
//    struct LatexEditorJump: Equatable        id, line (1-based), column (1-based, optional)
//    struct LatexCitationCandidate            key, title, authors, year
//    struct LatexLabel                        name, line, context
//    struct LatexCompletionContext            kind, command, prefix, replacementRange
//    struct LatexOutlineEntry                 depth, command, title, line, location
//    enum   LatexAutocomplete
//        completionContext(in:caret:) -> LatexCompletionContext?
//        citationKey(in:caret:) -> String?            the \cite key the caret is inside
//        labels(in:) -> [LatexLabel]
//        citationSuggestions(prefix:candidates:limit:) -> [LatexCitationCandidate]
//        referenceSuggestions(prefix:labels:limit:) -> [LatexLabel]
//        definedCommands(in:) / definedEnvironments(in:)   names the draft defines itself
//        nameSuggestions(for:in:installedPackages:)        fixed lists + the draft's own names
//    final class LatexInstalledPackages         packages found in the TeX install (background, once)
//    enum   LatexOutline        entries(in:) -> [LatexOutlineEntry]
//    enum   LatexTextStats      wordCount(in:) -> Int   (approximate, see the function)
//                               position(of:in:) -> (line, column)
//    enum   LatexCitationSource load(from: LibraryModel) throws -> [LatexCitationCandidate]
//
//  Reads (only): LatexHighlighter (Agent 33), LibraryModel and its database, RBColor.
//

import AppKit
import SwiftUI

// MARK: - Data types

struct LatexCitationCandidate: Equatable {
    let key: String
    let title: String
    /// Family names of the authors, in order.
    let authors: [String]
    let year: Int?

    /// "McMahan et al., 2017 · Communication-Efficient Learning …"
    var summary: String {
        var who = ""
        switch authors.count {
        case 0: who = ""
        case 1: who = authors[0]
        case 2: who = "\(authors[0]) & \(authors[1])"
        default: who = "\(authors[0]) et al."
        }
        let when = year.map(String.init) ?? "n.d."
        let head = who.isEmpty ? when : "\(who), \(when)"
        return title.isEmpty ? head : "\(head) · \(title)"
    }
}

struct LatexLabel: Equatable {
    let name: String
    /// 1-based line of the \label, 0 when it comes from another file.
    let line: Int
    /// The text of that line, trimmed and shortened.
    let context: String
}

enum LatexCompletionKind: Equatable {
    case citation
    case reference
    /// `\begin{` + environment name.
    case environment
    /// `\end{` + environment name (open environments come first).
    case endEnvironment
    /// `\usepackage{` + package name.
    case package
    /// `\` + two or more letters: a command name.
    case command
}

struct LatexCompletionContext: Equatable {
    let kind: LatexCompletionKind
    /// The command without the backslash and star: "cite", "ref", "eqref" ...
    let command: String
    /// What has been typed of the current key (after `{` or the last comma).
    let prefix: String
    /// The part of the text a chosen suggestion replaces (UTF-16).
    let replacementRange: NSRange
}

struct LatexOutlineEntry: Equatable, Identifiable {
    /// part 0, chapter 1, section 2, subsection 3, subsubsection 4, paragraph 5.
    let depth: Int
    let command: String
    let title: String
    let line: Int
    let location: Int
    var id: Int { location }
}

/// Moves the caret to a line. A new `id` is a new request, so jumping to the same line twice works.
struct LatexEditorJump: Equatable {
    let id: UUID
    let line: Int
    let column: Int?

    init(line: Int, column: Int? = nil, id: UUID = UUID()) {
        self.id = id
        self.line = line
        self.column = column
    }
}

// MARK: - Autocomplete (pure)

enum LatexAutocomplete {

    private static let referenceCommands: Set<String> = [
        "ref", "cref", "Cref", "eqref", "autoref", "pageref", "nameref", "vref", "Vref",
        "cpageref", "Cpageref"
    ]

    private static let citeRegex = try! NSRegularExpression(
        pattern: #"^(?:(?:no)?cite|(?:paren|text|auto|foot|smart|super)cite|cites)[A-Za-z]*$"#
    )

    /// `\command` with optional `[..]` arguments, ending right before the `{`.
    private static let commandBeforeBrace = try! NSRegularExpression(
        pattern: #"\\([A-Za-z]+)\*?(?:\[[^\]]*\]){0,2}$"#
    )

    private static let labelRegex = try! NSRegularExpression(pattern: #"\\label\{([^{}\n]*)\}"#)

    static func kind(ofCommand name: String) -> LatexCompletionKind? {
        if referenceCommands.contains(name) { return .reference }
        switch name {
        case "begin": return .environment
        case "end": return .endEnvironment
        case "usepackage", "RequirePackage": return .package
        default: break
        }
        let whole = NSRange(location: 0, length: (name as NSString).length)
        if citeRegex.firstMatch(in: name, options: [], range: whole) != nil { return .citation }
        return nil
    }

    // MARK: Where is the caret?

    private struct Argument {
        let kind: LatexCompletionKind
        let command: String
        /// From the start of the current key to the caret.
        let prefixRange: NSRange
        /// The whole current key (to the next comma or `}`), spaces trimmed.
        let fullRange: NSRange
    }

    /// Finds out whether the caret is inside the `{...}` argument of a \cite or \ref command.
    /// Arguments never cross a line end (the highlighter works the same way).
    private static func argument(in text: String, caret: Int) -> Argument? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }

        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let lineStart = line.location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart)) as NSString

        // The last `{` before the caret with no `}` after it.
        var open = -1
        var index = before.length - 1
        while index >= 0 {
            let c = before.character(at: index)
            if c == 0x7D /* } */ { return nil }
            if c == 0x7B /* { */ { open = index; break }
            index -= 1
        }
        guard open >= 0 else { return nil }

        // A commented-out line is not a citation.
        if isCommented(location: lineStart + open, lineStart: lineStart, in: ns) { return nil }

        let head = before.substring(to: open)
        let headRange = NSRange(location: 0, length: (head as NSString).length)
        guard let match = commandBeforeBrace.firstMatch(in: head, options: [], range: headRange) else { return nil }
        let command = (head as NSString).substring(with: match.range(at: 1))
        guard let kind = kind(ofCommand: command) else { return nil }

        // Start of the current key: after `{` or the last comma, skipping spaces.
        var keyStart = open + 1
        var scan = open + 1
        while scan < before.length {
            if before.character(at: scan) == 0x2C /* , */ { keyStart = scan + 1 }
            scan += 1
        }
        while keyStart < before.length, isSpace(before.character(at: keyStart)) { keyStart += 1 }
        let prefixRange = NSRange(location: lineStart + keyStart, length: before.length - keyStart)

        // End of the current key: the next comma or `}` on the same line.
        var end = caret
        let lineEnd = NSMaxRange(line)
        while end < lineEnd {
            let c = ns.character(at: end)
            if c == 0x2C || c == 0x7D || c == 0x0A || c == 0x0D { break }
            end += 1
        }
        var trimmedEnd = end
        while trimmedEnd > prefixRange.location, isSpace(ns.character(at: trimmedEnd - 1)) { trimmedEnd -= 1 }
        let fullRange = NSRange(location: prefixRange.location, length: max(0, trimmedEnd - prefixRange.location))

        return Argument(kind: kind, command: command, prefixRange: prefixRange, fullRange: fullRange)
    }

    /// Set when the caret is inside `\cite{ ... }` or `\ref{ ... }`.
    static func completionContext(in text: String, caret: Int) -> LatexCompletionContext? {
        guard let arg = argument(in: text, caret: caret) else { return commandContext(in: text, caret: caret) }
        let prefix = (text as NSString).substring(with: arg.prefixRange)
        return LatexCompletionContext(kind: arg.kind, command: arg.command, prefix: prefix,
                                      replacementRange: arg.prefixRange)
    }

    // MARK: Commands, environments, packages

    /// Set when the caret is right after `\` and at least two letters (not in a comment).
    static func commandContext(in text: String, caret: Int) -> LatexCompletionContext? {
        let ns = text as NSString
        guard caret >= 2, caret <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        var start = caret
        while start > line.location, isASCIILetter(ns.character(at: start - 1)) { start -= 1 }
        guard caret - start >= 2, start > line.location, ns.character(at: start - 1) == 0x5C /* \ */ else { return nil }
        // `\\name` is a line break followed by text, not a command.
        if start - 1 > line.location, ns.character(at: start - 2) == 0x5C { return nil }
        if isCommented(location: start - 1, lineStart: line.location, in: ns) { return nil }
        let range = NSRange(location: start, length: caret - start)
        return LatexCompletionContext(kind: .command, command: "", prefix: ns.substring(with: range), replacementRange: range)
    }

    private static func isASCIILetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    /// Environments opened with \begin{x} and not yet closed before `caret`, innermost first.
    static func openEnvironments(in text: String, before caret: Int) -> [String] {
        let ns = text as NSString
        let end = min(max(caret, 0), ns.length)
        let head = ns.substring(to: end)
        guard let regex = try? NSRegularExpression(pattern: #"\\(begin|end)\{([A-Za-z*]+)\}"#) else { return [] }
        var stack: [String] = []
        let headNS = head as NSString
        regex.enumerateMatches(in: head, options: [], range: NSRange(location: 0, length: headNS.length)) { match, _, _ in
            guard let match else { return }
            let line = headNS.lineRange(for: NSRange(location: match.range.location, length: 0))
            if isCommented(location: match.range.location, lineStart: line.location, in: headNS) { return }
            let name = headNS.substring(with: match.range(at: 2))
            if headNS.substring(with: match.range(at: 1)) == "begin" {
                stack.append(name)
            } else if let index = stack.lastIndex(of: name) {
                stack.removeSubrange(index...)
            }
        }
        return stack.reversed()
    }

    /// Names that start with `prefix` (case-insensitive), shortest first, then alphabetical.
    static func nameSuggestions(prefix: String, in names: [String], limit: Int = 40) -> [String] {
        let lower = prefix.lowercased()
        let hits = lower.isEmpty ? names : names.filter { $0.lowercased().hasPrefix(lower) }
        return Array(hits.sorted { ($0.count, $0) < ($1.count, $1) }.prefix(limit))
    }

    /// What a list offers for a command / environment / package context.
    ///
    /// Besides the fixed lists it offers what the draft defines itself
    /// (\newcommand, \newenvironment, \newtheorem ...), and, for \usepackage,
    /// the packages found in the TeX install. `installedPackages` is empty by
    /// default so tests do not depend on the machine; the editor passes
    /// `LatexInstalledPackages.shared.packageNames`.
    static func nameSuggestions(
        for context: LatexCompletionContext,
        in text: String,
        installedPackages: [String] = []
    ) -> [String] {
        switch context.kind {
        case .command:
            let own = definedCommands(in: text).filter { $0 != context.prefix }
            return nameSuggestions(prefix: context.prefix, in: merged(commandNames, own))
        case .environment:
            return nameSuggestions(prefix: context.prefix,
                                   in: merged(environmentNames, definedEnvironments(in: text)))
        case .package:
            return nameSuggestions(prefix: context.prefix, in: merged(packageNames, installedPackages))
        case .endEnvironment:
            let open = openEnvironments(in: text, before: context.replacementRange.location)
            let lower = context.prefix.lowercased()
            let matchingOpen = open.filter { lower.isEmpty || $0.lowercased().hasPrefix(lower) }
            // An \end{ with nothing open still offers the usual names.
            let rest = nameSuggestions(prefix: context.prefix,
                                       in: merged(environmentNames, definedEnvironments(in: text)))
                .filter { !matchingOpen.contains($0) }
            return matchingOpen + (matchingOpen.isEmpty ? rest : [])
        case .citation, .reference: return []
        }
    }

    /// `base` followed by the names of `extra` it does not have yet.
    private static func merged(_ base: [String], _ extra: [String]) -> [String] {
        if extra.isEmpty { return base }
        var seen = Set(base)
        var out = base
        for name in extra where seen.insert(name).inserted { out.append(name) }
        return out
    }

    // MARK: Names the draft defines

    private static let definedCommandRegexes: [NSRegularExpression] = [
        #"\\(?:new|renew|provide)command\*?\s*\{?\s*\\([A-Za-z]+)"#,
        #"\\(?:Declare|Provide)(?:Robust|Document)?Command\*?\s*\{?\s*\\([A-Za-z]+)"#,
        #"\\DeclareMathOperator\*?\s*\{?\s*\\([A-Za-z]+)"#,
        #"\\(?:def|gdef|edef|xdef|let)\s*\\([A-Za-z]+)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let definedEnvironmentRegexes: [NSRegularExpression] = [
        #"\\(?:re)?newenvironment\*?\s*\{([A-Za-z*]+)\}"#,
        #"\\newtheorem\*?\s*\{([A-Za-z*]+)\}"#,
        #"\\declaretheorem(?:\[[^\]]*\])?\s*\{([A-Za-z*]+)\}"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Command names (no backslash) the draft defines, grouped by kind of definition.
    /// Commented-out definitions are skipped.
    static func definedCommands(in text: String) -> [String] {
        capturedNames(definedCommandRegexes, in: text)
    }

    /// Environment names the draft defines (\newenvironment, \newtheorem ...).
    static func definedEnvironments(in text: String) -> [String] {
        capturedNames(definedEnvironmentRegexes, in: text)
    }

    private static func capturedNames(_ regexes: [NSRegularExpression], in text: String) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var out: [String] = []
        for regex in regexes {
            regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let line = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
                if isCommented(location: match.range.location, lineStart: line.location, in: ns) { return }
                let name = ns.substring(with: match.range(at: 1))
                if seen.insert(name).inserted { out.append(name) }
            }
        }
        return out
    }

    /// Text typed after a chosen command name, and how far back the caret goes ("{}" -> 1).
    static let commandTemplates: [String: (suffix: String, caretBack: Int)] = {
        var map: [String: (String, Int)] = [:]
        for name in ["section", "subsection", "subsubsection", "paragraph", "chapter", "part", "textbf", "textit",
                     "texttt", "emph", "underline", "label", "ref", "eqref", "cite", "citep", "citet", "footnote",
                     "caption", "includegraphics", "input", "include", "usepackage", "documentclass", "title",
                     "author", "textsc", "mathbf", "mathrm", "mathcal", "mathbb", "sqrt", "url", "href", "hat",
                     "bar", "vec", "tilde", "text", "begin", "end", "bibliography", "bibliographystyle",
                     "textsuperscript", "textsubscript", "newcommand", "item"] where name != "item" {
            map[name] = ("{}", 1)
        }
        map["frac"] = ("{}{}", 3)
        map["dfrac"] = ("{}{}", 3)
        map["textcolor"] = ("{}{}", 3)
        map["item"] = (" ", 0)
        return map
    }()

    static let commandNames: [String] = [
        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "lambda", "mu", "nu",
        "pi", "rho", "sigma", "tau", "phi", "varphi", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda",
        "Sigma", "Phi", "Psi", "Omega", "author", "title", "date", "maketitle", "abstract", "chapter", "section",
        "subsection", "subsubsection", "paragraph", "subparagraph", "part", "appendix", "tableofcontents",
        "listoffigures", "listoftables", "label", "ref", "eqref", "autoref", "cref", "Cref", "pageref", "cite",
        "citep", "citet", "citeauthor", "citeyear", "nocite", "bibliography", "bibliographystyle", "printbibliography",
        "addbibresource", "footnote", "caption", "centering", "includegraphics", "input", "include", "usepackage",
        "documentclass", "newcommand", "renewcommand", "providecommand", "newenvironment", "newtheorem",
        "textbf", "textit", "texttt", "textsc", "textrm", "textsf", "textnormal", "emph", "underline", "mathbf",
        "mathrm", "mathcal", "mathbb", "mathit", "mathsf", "mathtt", "boldsymbol", "frac", "dfrac", "tfrac", "sqrt",
        "sum", "prod", "int", "oint", "lim", "infty", "partial", "nabla", "cdot", "cdots", "ldots", "dots", "times",
        "div", "pm", "mp", "leq", "geq", "neq", "approx", "equiv", "sim", "simeq", "propto", "subset", "subseteq",
        "supset", "in", "notin", "cup", "cap", "forall", "exists", "neg", "land", "lor", "rightarrow", "leftarrow",
        "Rightarrow", "Leftarrow", "leftrightarrow", "Leftrightarrow", "mapsto", "to", "left", "right", "big",
        "Big", "bigg", "overline", "underline", "hat", "tilde", "bar", "vec", "dot", "ddot", "widehat", "widetilde",
        "operatorname", "argmax", "argmin", "min", "max", "sup", "inf", "log", "ln", "exp", "sin", "cos", "tan",
        "hline", "toprule", "midrule", "bottomrule", "cline", "multicolumn", "multirow", "newline", "linebreak",
        "pagebreak", "newpage", "clearpage", "vspace", "hspace", "noindent", "indent", "quad", "qquad", "par",
        "item", "hfill", "vfill", "url", "href", "textcolor", "color", "colorbox", "fbox", "mbox", "parbox",
        "begin", "end", "text", "textsuperscript", "textsubscript", "today", "thanks", "tiny", "scriptsize",
        "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge", "setlength", "setcounter",
        "addtocounter", "pagestyle", "thispagestyle", "pagenumbering", "geometry", "hypersetup", "lstinline",
        "verb", "paragraphs", "bibitem", "index", "glossary", "acronym", "mathrm", "ensuremath", "xspace",
        "lVert", "rVert", "langle", "rangle", "lceil", "rceil", "lfloor", "rfloor", "binom", "choose", "tag",
        "nonumber", "notag", "intertext", "shortintertext", "substack", "underbrace", "overbrace", "stackrel",
        "xrightarrow", "xleftarrow", "mathop", "mathbin", "mathrel", "limits", "nolimits"
    ].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

    static let environmentNames: [String] = [
        "document", "abstract", "itemize", "enumerate", "description", "equation", "equation*", "align", "align*",
        "aligned", "alignat", "gather", "gather*", "multline", "multline*", "split", "eqnarray", "cases", "figure",
        "figure*", "table", "table*", "tabular", "tabularx", "longtable", "array", "matrix", "pmatrix", "bmatrix",
        "vmatrix", "Vmatrix", "smallmatrix", "center", "flushleft", "flushright", "quote", "quotation", "verse",
        "verbatim", "lstlisting", "minted", "theorem", "lemma", "proposition", "corollary", "definition", "example",
        "remark", "proof", "algorithm", "algorithmic", "minipage", "subfigure", "tikzpicture", "frame", "thebibliography",
        "appendix", "wrapfigure", "sidewaystable", "sidewaysfigure", "tcolorbox", "titlepage", "filecontents", "math",
        "displaymath", "subequations", "block", "columns", "column"
    ]

    static let packageNames: [String] = [
        "amsmath", "amssymb", "amsthm", "amsfonts", "mathtools", "graphicx", "xcolor", "hyperref", "cleveref",
        "natbib", "biblatex", "babel", "inputenc", "fontenc", "geometry", "fancyhdr", "setspace", "booktabs", "tabularx",
        "longtable", "multirow", "array", "caption", "subcaption", "float", "placeins", "enumitem", "listings", "minted",
        "algorithm", "algorithmic", "algorithm2e", "algpseudocode", "tikz", "pgfplots", "siunitx", "microtype", "lmodern",
        "times", "mathptmx", "newtxtext", "newtxmath", "csquotes", "url", "doi", "authblk", "titlesec", "titling",
        "tocloft", "appendix", "etoolbox", "xspace", "ifthen", "soul", "ulem", "cancel", "bm", "bbm", "dsfont", "physics",
        "braket", "xfrac", "nicefrac", "textcomp", "gensymb", "pdfpages", "lipsum", "blindtext", "todonotes", "comment",
        "verbatim", "fancyvrb", "tcolorbox", "wrapfig", "rotating", "lscape", "pdflscape", "adjustbox", "epstopdf", "svg",
        "glossaries", "makeidx", "imakeidx", "datetime2", "cite", "balance", "multicol", "stfloats", "epsfig", "subfig",
        "colortbl", "makecell", "threeparttable", "diagbox", "tablefootnote", "relsize", "mdframed", "framed", "calc"
    ]

    /// The citation key the caret is in or next to (`\cite{a, b|c}` -> "bc"), nil outside \cite.
    static func citationKey(in text: String, caret: Int) -> String? {
        guard let arg = argument(in: text, caret: caret), arg.kind == .citation, arg.fullRange.length > 0 else { return nil }
        return (text as NSString).substring(with: arg.fullRange)
    }

    // MARK: Labels

    /// Every `\label{name}` that is not commented out, in order.
    static func labels(in text: String) -> [LatexLabel] {
        let ns = text as NSString
        var found: [LatexLabel] = []
        var seen = Set<String>()
        labelRegex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let line = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
            if isCommented(location: match.range.location, lineStart: line.location, in: ns) { return }
            let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            var context = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if context.count > 70 { context = String(context.prefix(70)) + "…" }
            let lineNumber = lineNumberOf(location: match.range.location, in: ns)
            found.append(LatexLabel(name: name, line: lineNumber, context: context))
        }
        return found
    }

    // MARK: Ranking

    /// Library papers that match what was typed. Every typed word must appear somewhere in the key,
    /// the authors, the title or the year. Key matches come first. An empty prefix gives the newest papers.
    static func citationSuggestions(
        prefix: String, candidates: [LatexCitationCandidate], limit: Int = 30
    ) -> [LatexCitationCandidate] {
        let words = prefix.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else {
            return Array(candidates.sorted {
                ($0.year ?? 0, $1.key) > ($1.year ?? 0, $0.key)
            }.prefix(limit))
        }

        var scored: [(score: Int, candidate: LatexCitationCandidate)] = []
        for candidate in candidates {
            let key = candidate.key.lowercased()
            let authors = candidate.authors.joined(separator: " ").lowercased()
            let title = candidate.title.lowercased()
            let year = candidate.year.map(String.init) ?? ""

            var total = 0
            var allMatch = true
            for word in words {
                if key.hasPrefix(word) { total += 0 }
                else if key.contains(word) { total += 2 }
                else if authors.hasPrefix(word) || authors.contains(" " + word) { total += 3 }
                else if year.hasPrefix(word) { total += 4 }
                else if title.contains(word) { total += 5 }
                else if authors.contains(word) { total += 6 }
                else { allMatch = false; break }
            }
            if allMatch { scored.append((total, candidate)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.candidate.key.lowercased() < b.candidate.key.lowercased()
        }
        return Array(scored.prefix(limit).map { $0.candidate })
    }

    /// Labels that match what was typed: names that start with it first, then names that contain it.
    static func referenceSuggestions(prefix: String, labels: [LatexLabel], limit: Int = 50) -> [LatexLabel] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return Array(labels.prefix(limit)) }
        let starts = labels.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = labels.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix(needle) && name.contains(needle)
        }
        return Array((starts + contains).prefix(limit))
    }

    // MARK: Small helpers

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    /// True when an unescaped `%` comes before `location` on its line.
    static func isCommented(location: Int, lineStart: Int, in ns: NSString) -> Bool {
        var index = lineStart
        while index < location {
            let c = ns.character(at: index)
            if c == 0x5C /* \ */ { index += 2; continue }
            if c == 0x25 /* % */ { return true }
            index += 1
        }
        return false
    }

    static func lineNumberOf(location: Int, in ns: NSString) -> Int {
        var line = 1
        var index = 0
        let stop = min(location, ns.length)
        while index < stop {
            if ns.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }
}

// MARK: - Installed packages

/// The LaTeX packages found in the TeX install, for `\usepackage{` suggestions.
///
/// Loaded once, in the background, from the `ls-R` file lists of the TeX
/// trees (the same lists TeX itself uses). Until it finishes, or when no TeX
/// install is found, `packageNames` is empty and the editor uses its fixed
/// list. Reads only; nothing is written.
nonisolated final class LatexInstalledPackages: @unchecked Sendable {

    static let shared = LatexInstalledPackages()

    private let lock = NSLock()
    private var loaded: [String] = []
    private var started = false

    /// Empty until the background scan has finished.
    var packageNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    /// Starts the scan the first time it is called; later calls do nothing.
    func loadIfNeeded() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let names = Self.discover()
            lock.lock(); loaded = names; lock.unlock()
        }
    }

    /// Package names (no `.sty`) from the text of an `ls-R` file. Only files
    /// inside a `tex/latex` folder count, so internal and non-LaTeX styles
    /// are left out. Sorted, without duplicates.
    static func parseListing(_ text: String) -> [String] {
        var names = Set<String>()
        var inLatex = false
        text.enumerateLines { line, _ in
            if line.hasPrefix("./") && line.hasSuffix(":") {
                inLatex = line.contains("/tex/latex/") || line.hasSuffix("/tex/latex:")
            } else if inLatex, line.hasSuffix(".sty") {
                let name = String(line.dropLast(4))
                guard !name.isEmpty, !name.hasPrefix("."),
                      name.range(of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression) != nil
                else { return }
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// The TeX trees to read: asks kpsewhich, falling back to the usual folders.
    static func roots() -> [URL] {
        let fm = FileManager.default
        var paths: [String] = []

        if let kpse = LatexCompiler.locateInstallation().kpsewhich {
            for variable in ["TEXMFDIST", "TEXMFLOCAL", "TEXMFHOME"] {
                guard let out = run(kpse, ["-var-value=\(variable)"], timeout: 10) else { continue }
                for piece in out.split(whereSeparator: { $0 == ":" || $0 == "\n" }) {
                    let cleaned = piece
                        .replacingOccurrences(of: "!!", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "{} \t\r"))
                    if cleaned.hasPrefix("/") { paths.append(cleaned) }
                }
            }
        }

        if paths.isEmpty {
            paths.append("/Library/TeX/Root/texmf-dist")
            let base = "/usr/local/texlive"
            for year in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                paths.append("\(base)/\(year)/texmf-dist")
            }
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func discover() -> [String] {
        var all = Set<String>()
        for root in roots() {
            let listing = root.appendingPathComponent("ls-R")
            guard let text = (try? String(contentsOf: listing, encoding: .utf8))
                    ?? (try? String(contentsOf: listing, encoding: .isoLatin1)) else { continue }
            all.formUnion(parseListing(text))
        }
        return all.sorted()
    }

    /// Runs a small tool and returns what it printed, or nil if it failed or took too long.
    private static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Outline (pure)

enum LatexOutline {

    private static let regex = try! NSRegularExpression(
        pattern: #"^[ \t]*\\(part|chapter|section|subsection|subsubsection|paragraph)\*?(?:\[[^\]\n]*\])?\{([^}\n]*)\}"#,
        options: [.anchorsMatchLines]
    )

    private static let depths: [String: Int] = [
        "part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4, "paragraph": 5
    ]

    static func entries(in text: String) -> [LatexOutlineEntry] {
        let ns = text as NSString
        var out: [LatexOutlineEntry] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let command = ns.substring(with: match.range(at: 1))
            let title = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            out.append(LatexOutlineEntry(
                depth: depths[command] ?? 2,
                command: command,
                title: title.isEmpty ? "(untitled)" : title,
                line: LatexAutocomplete.lineNumberOf(location: match.range.location, in: ns),
                location: match.range.location
            ))
        }
        return out
    }
}

// MARK: - Counting (pure)

enum LatexTextStats {

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let comments = regex(#"(?<!\\)%[^\n]*"#)
    private static let mathEnvironments = regex(
        #"\\begin\{(equation|align|gather|multline|eqnarray|displaymath|math|verbatim|lstlisting|tikzpicture)\*?\}.*?\\end\{\1\*?\}"#,
        [.dotMatchesLineSeparators]
    )
    private static let displayMath = regex(#"\$\$.*?\$\$|\\\[.*?\\\]|\\\(.*?\\\)"#, [.dotMatchesLineSeparators])
    private static let inlineMath = regex(#"(?<!\\)\$[^$\n]*(?<!\\)\$"#)
    /// Commands whose argument is not prose.
    private static let silentCommands = regex(
        #"\\(?:(?:no)?cite[A-Za-z]*|[cC]?ref|eqref|autoref|pageref|nameref|label|input|include|includegraphics|usepackage|documentclass|bibliography|bibliographystyle|begin|end|url|href)\*?(?:\[[^\]\n]*\])*(?:\{[^}\n]*\})?"#
    )
    private static let otherCommands = regex(#"\\[A-Za-z@]+\*?(?:\[[^\]\n]*\])?|\\."#)

    /// Words of the text as a reader sees them: comments, preamble, formulas, citations and
    /// commands are left out. Approximate (like TeXcount), good enough for a live count.
    static func wordCount(in text: String) -> Int {
        var work = text

        func strip(_ re: NSRegularExpression, with replacement: String = " ") {
            let range = NSRange(location: 0, length: (work as NSString).length)
            work = re.stringByReplacingMatches(in: work, options: [], range: range, withTemplate: replacement)
        }

        strip(comments)
        if let begin = work.range(of: "\\begin{document}") {
            work = String(work[begin.upperBound...])
        }
        if let end = work.range(of: "\\end{document}") {
            work = String(work[..<end.lowerBound])
        }
        strip(mathEnvironments)
        strip(displayMath)
        strip(inlineMath)
        strip(silentCommands)
        strip(otherCommands)
        work = work.replacingOccurrences(of: "{", with: " ").replacingOccurrences(of: "}", with: " ")

        var count = 0
        work.enumerateSubstrings(in: work.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// 1-based line and column of a UTF-16 offset.
    static func position(of location: Int, in text: String) -> (line: Int, column: Int) {
        let ns = text as NSString
        let clamped = min(max(location, 0), ns.length)
        let line = LatexAutocomplete.lineNumberOf(location: clamped, in: ns)
        let lineStart = ns.lineRange(for: NSRange(location: clamped, length: 0)).location
        return (line, clamped - lineStart + 1)
    }

    /// UTF-16 offset of a 1-based line and column (clamped to the text).
    static func location(line: Int, column: Int?, in text: String) -> Int {
        let ns = text as NSString
        var current = 1
        var index = 0
        while current < line, index < ns.length {
            if ns.character(at: index) == 0x0A { current += 1 }
            index += 1
        }
        guard index < ns.length else { return ns.length }
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let offset = max(0, (column ?? 1) - 1)
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, [0x0A, 0x0D].contains(ns.character(at: contentEnd - 1)) { contentEnd -= 1 }
        return min(lineRange.location + offset, contentEnd)
    }
}

// MARK: - Library source

enum LatexCitationSource {

    /// Every paper in the library that has a citation key (Trash excluded). Two queries, read only.
    static func load(from model: LibraryModel) throws -> [LatexCitationCandidate] {
        let itemRows = try model.database.rows(
            "SELECT id, citation_key, title, year FROM items WHERE deleted_at IS NULL AND citation_key <> ''"
        )
        guard !itemRows.isEmpty else { return [] }

        let creatorRows = try model.database.rows(
            """
            SELECT ic.item_id AS item_id, c.family AS family
            FROM item_creators ic JOIN creators c ON c.id = ic.creator_id
            WHERE ic.role = 'author'
            ORDER BY ic.item_id, ic.position
            """
        )
        var authors: [String: [String]] = [:]
        for row in creatorRows {
            guard let id = row.text("item_id"), let family = row.text("family"), !family.isEmpty else { continue }
            authors[id, default: []].append(family)
        }

        return itemRows.compactMap { row in
            guard let id = row.text("id"), let key = row.text("citation_key"), !key.isEmpty else { return nil }
            return LatexCitationCandidate(
                key: key,
                title: row.text("title") ?? "",
                authors: authors[id] ?? [],
                year: row.int("year").map { Int($0) }
            )
        }
    }
}

// MARK: - The view

struct LatexEditorView: View {

    @Binding var text: String
    var model: LibraryModel?
    var libraryRevision: Int
    var extraLabels: [LatexLabel]
    var jump: LatexEditorJump?
    var fontSize: CGFloat
    /// Called whenever the caret moves (UTF-16 offset), so a parent can insert at the cursor.
    var onCaretChange: ((Int) -> Void)?

    @State private var showsOutline: Bool
    @State private var spellCheck = false
    @State private var candidates: [LatexCitationCandidate] = []
    @State private var libraryLoaded = false
    @State private var outline: [LatexOutlineEntry] = []
    @State private var words = 0
    @State private var caret = 0
    @State private var controller = LatexEditorController()

    init(
        text: Binding<String>,
        model: LibraryModel? = nil,
        libraryRevision: Int = 0,
        extraLabels: [LatexLabel] = [],
        jump: LatexEditorJump? = nil,
        fontSize: CGFloat = 13,
        showsOutline: Bool = true,
        onCaretChange: ((Int) -> Void)? = nil
    ) {
        self._text = text
        self.model = model
        self.libraryRevision = libraryRevision
        self.extraLabels = extraLabels
        self.jump = jump
        self.fontSize = fontSize
        self.onCaretChange = onCaretChange
        self._showsOutline = State(initialValue: showsOutline)
    }

    /// nil = no library, so \cite is not checked.
    private var knownKeys: Set<String>? {
        guard model != nil, libraryLoaded else { return nil }
        return Set(candidates.map(\.key))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if showsOutline {
                    outlinePane
                    Divider()
                }
                LatexTextViewRepresentable(
                    text: $text,
                    knownKeys: knownKeys,
                    candidates: candidates,
                    extraLabels: extraLabels,
                    spellCheck: spellCheck,
                    fontSize: fontSize,
                    jump: jump,
                    controller: controller,
                    onCaret: { caret = $0; onCaretChange?($0) }
                )
            }
            Divider()
            statusBar
        }
        .background(RBColor.card)
        .task(id: libraryRevision) { reloadLibrary() }
        .task(id: text) {
            // Wait a moment so typing stays smooth, then refresh outline and word count.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            outline = LatexOutline.entries(in: text)
            words = LatexTextStats.wordCount(in: text)
        }
    }

    // MARK: Pieces

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { showsOutline.toggle() } label: { Label("Outline", systemImage: "list.bullet.indent") }
                .help("Show or hide the outline")
            Button { controller.showFind(replace: false) } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Find (⌘F)")
            Button { controller.showFind(replace: true) } label: { Label("Replace", systemImage: "arrow.left.arrow.right") }
                .help("Find and replace")
            Toggle(isOn: $spellCheck) { Label("Spelling", systemImage: "textformat.abc.dottedunderline") }
                .toggleStyle(.button)
                .help("Check spelling while typing")
            Spacer()
            Button { controller.complete() } label: { Label("Cite", systemImage: "quote.opening") }
                .help("Search the library for a citation key (type \\cite{ or press ⌥⎋)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RBColor.surface)
    }

    private var outlinePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RBColor.mutedText)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            if outline.isEmpty {
                Text("No sections yet. Add \\section{…} and they show here.")
                    .font(.caption)
                    .foregroundStyle(RBColor.mutedText)
                    .padding(10)
                Spacer(minLength: 0)
            } else {
                let base = outline.map(\.depth).min() ?? 0
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(outline) { entry in
                            Button {
                                controller.select(location: entry.location)
                            } label: {
                                Text(entry.title)
                                    .font(.callout.weight(entry.depth == base ? .semibold : .regular))
                                    .foregroundStyle(RBColor.primaryText)
                                    .lineLimit(1)
                                    .padding(.leading, CGFloat(entry.depth - base) * 12 + 10)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(RBHoverPlainButtonStyle())
                            .help("Line \(entry.line)")
                        }
                    }
                }
            }
        }
        .frame(width: 200)
        .background(RBColor.surface)
    }

    private var statusBar: some View {
        let place = LatexTextStats.position(of: caret, in: text)
        return HStack(spacing: 12) {
            Text("Ln \(place.line), Col \(place.column)")
            Text("\(words) words")
            Spacer()
            Text(citationNote)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(RBColor.mutedText)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RBColor.surface)
    }

    /// What the caret is on, when it is on a \cite key.
    private var citationNote: String {
        guard let key = LatexAutocomplete.citationKey(in: text, caret: caret) else { return "" }
        guard model != nil, libraryLoaded else { return key }
        if let hit = candidates.first(where: { $0.key == key }) { return hit.summary }
        return "Not in your library: \(key)"
    }

    private func reloadLibrary() {
        guard let model else {
            candidates = []
            libraryLoaded = false
            return
        }
        do {
            candidates = try LatexCitationSource.load(from: model)
            libraryLoaded = true
        } catch {
            // The editor still works without the library; \cite is then not checked.
            candidates = []
            libraryLoaded = false
        }
    }
}

// MARK: - Controller (lets the toolbar and outline reach the text view)

final class LatexEditorController {
    fileprivate weak var textView: NSTextView?

    func showFind(replace: Bool) {
        guard let textView else { return }
        let action: NSTextFinder.Action = replace ? .showReplaceInterface : .showFindInterface
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.window?.makeFirstResponder(textView)
        textView.performTextFinderAction(item)
    }

    func select(location: Int) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let line = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: line.location, length: 0))
        textView.scrollRangeToVisible(line)
        textView.showFindIndicator(for: NSRange(location: line.location, length: max(0, line.length - 1)))
    }

    func complete() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.complete(nil)
    }
}

// MARK: - The NSTextView

/// An NSTextView whose "user completion" works on the current \cite / \ref key.
final class LatexNSTextView: NSTextView {

    /// True while a chosen suggestion is being typed in, so it does not open the list again.
    var isInsertingCompletion = false

    override var rangeForUserCompletion: NSRange {
        if let context = LatexAutocomplete.completionContext(in: string, caret: selectedRange().location),
           selectedRange().length == 0 {
            return context.replacementRange
        }
        return super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal flag: Bool) {
        isInsertingCompletion = flag
        // Remember what is being completed before the text changes.
        let context = flag ? LatexAutocomplete.completionContext(in: string, caret: selectedRange().location) : nil
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag, movement != NSCancelTextMovement, let context {
            finishCompletion(word, context: context)
        }
        if flag {
            // The text change from the insert is already reported; allow typing to open the list again.
            DispatchQueue.main.async { [weak self] in self?.isInsertingCompletion = false }
        }
    }
}

extension LatexNSTextView {

    /// After a name was chosen: put the braces / the matching \end in, and park the caret inside.
    fileprivate func finishCompletion(_ word: String, context: LatexCompletionContext) {
        let ns = string as NSString
        let caret = selectedRange().location
        let nextChar: unichar? = caret < ns.length ? ns.character(at: caret) : nil

        switch context.kind {
        case .command:
            guard let template = LatexAutocomplete.commandTemplates[word] else { return }
            // `\section{Intro}`: braces already there, leave the text alone.
            if template.suffix.hasPrefix("{"), nextChar == 0x7B { return }
            insertText(template.suffix, replacementRange: NSRange(location: caret, length: 0))
            setSelectedRange(NSRange(location: caret + (template.suffix as NSString).length - template.caretBack, length: 0))

        case .environment:
            // Already closed (`\begin{itemize}`): nothing to add.
            if nextChar == 0x7D { return }
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            let lineText = ns.substring(with: line)
            let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
            let inner = indent + "  "
            let insertion = "}\n\(inner)\n\(indent)\\end{\(word)}"
            insertText(insertion, replacementRange: NSRange(location: caret, length: 0))
            let inside = caret + ("}\n\(inner)" as NSString).length
            setSelectedRange(NSRange(location: inside, length: 0))

        case .endEnvironment, .package:
            if nextChar != 0x7D {
                insertText("}", replacementRange: NSRange(location: caret, length: 0))
            }

        case .citation, .reference:
            break
        }
    }
}

// MARK: - SwiftUI wrapper

private struct LatexTextViewRepresentable: NSViewRepresentable {

    @Binding var text: String
    let knownKeys: Set<String>?
    let candidates: [LatexCitationCandidate]
    let extraLabels: [LatexLabel]
    let spellCheck: Bool
    let fontSize: CGFloat
    let jump: LatexEditorJump?
    let controller: LatexEditorController
    let onCaret: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(RBColor.card)

        let textView = LatexNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Source code, not prose: nothing may change what the user typed.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = NSColor(RBColor.card)
        textView.insertionPointColor = NSColor(RBColor.accent)
        textView.delegate = context.coordinator

        scroll.documentView = textView
        controller.textView = textView
        context.coordinator.textView = textView

        context.coordinator.theme = LatexHighlightTheme.make(size: fontSize)
        textView.font = context.coordinator.theme.font
        textView.typingAttributes = context.coordinator.theme.baseAttributes
        context.coordinator.load(text, into: textView)
        // Look for installed packages in the background (once) for \usepackage{ suggestions.
        LatexInstalledPackages.shared.loadIfNeeded()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? LatexNSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        controller.textView = textView

        var repaint = false

        if coordinator.theme.font.pointSize != fontSize {
            coordinator.theme = LatexHighlightTheme.make(size: fontSize)
            textView.font = coordinator.theme.font
            textView.typingAttributes = coordinator.theme.baseAttributes
            repaint = true
        }
        if coordinator.paintedKeys != knownKeys {
            repaint = true
        }
        // The text was changed from outside (file reloaded, undo of a restore ...).
        if textView.string != text {
            coordinator.load(text, into: textView)
            repaint = false
        }
        if repaint { coordinator.paintAll(textView) }

        if textView.isContinuousSpellCheckingEnabled != spellCheck {
            textView.isContinuousSpellCheckingEnabled = spellCheck
        }

        if let jump, coordinator.lastJumpID != jump.id {
            coordinator.lastJumpID = jump.id
            let location = LatexTextStats.location(line: jump.line, column: jump.column, in: textView.string)
            DispatchQueue.main.async {
                controller.select(location: location)
                textView.setSelectedRange(NSRange(location: location, length: 0))
            }
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: LatexTextViewRepresentable
        weak var textView: LatexNSTextView?
        var theme = LatexHighlightTheme.make()
        var lastJumpID: UUID?
        /// The key set the text is coloured with now.
        var paintedKeys: Set<String>?

        private var pendingEdit: NSRange?
        private var lastEditWasInsertion = false
        private var isLoading = false

        init(_ parent: LatexTextViewRepresentable) { self.parent = parent }

        /// Replaces the whole text without telling the binding, and paints it.
        func load(_ text: String, into textView: NSTextView) {
            isLoading = true
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            paintAll(textView)
            isLoading = false
        }

        func paintAll(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            paintedKeys = parent.knownKeys
            LatexHighlighter.apply(to: storage, range: nil, theme: theme, knownCitationKeys: parent.knownKeys)
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            let replacement = replacementString ?? ""
            pendingEdit = NSRange(location: range.location, length: (replacement as NSString).length)
            lastEditWasInsertion = !replacement.isEmpty
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView = notification.object as? LatexNSTextView,
                  let storage = textView.textStorage else { return }

            parent.text = textView.string

            // Only the lines that were touched are coloured again.
            let edited = pendingEdit ?? NSRange(location: textView.selectedRange().location, length: 0)
            pendingEdit = nil
            LatexHighlighter.apply(to: storage, range: edited, theme: theme, knownCitationKeys: parent.knownKeys)
            textView.typingAttributes = theme.baseAttributes

            // Open the suggestion list while typing inside \cite{ } or \ref{ }.
            guard lastEditWasInsertion, !textView.isInsertingCompletion else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, !textView.isInsertingCompletion else { return }
                let caret = textView.selectedRange()
                guard caret.length == 0,
                      let context = LatexAutocomplete.completionContext(in: textView.string, caret: caret.location),
                      !self.words(for: context, in: textView.string).isEmpty else { return }
                textView.complete(nil)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onCaret(textView.selectedRange().location)
        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let caret = textView.selectedRange().location
            guard let context = LatexAutocomplete.completionContext(in: textView.string, caret: caret) else { return [] }
            let result = self.words(for: context, in: textView.string)
            index?.pointee = result.isEmpty ? -1 : 0
            return result
        }

        /// The strings the list offers: library keys for \cite, label names for \ref.
        private func words(for context: LatexCompletionContext, in text: String) -> [String] {
            switch context.kind {
            case .command, .environment, .endEnvironment, .package:
                return LatexAutocomplete.nameSuggestions(
                    for: context, in: text,
                    installedPackages: LatexInstalledPackages.shared.packageNames)
            case .citation:
                return LatexAutocomplete
                    .citationSuggestions(prefix: context.prefix, candidates: parent.candidates)
                    .map(\.key)
            case .reference:
                let own = LatexAutocomplete.labels(in: text)
                let ownNames = Set(own.map(\.name))
                let merged = own + parent.extraLabels.filter { !ownNames.contains($0.name) }
                return LatexAutocomplete
                    .referenceSuggestions(prefix: context.prefix, labels: merged)
                    .map(\.name)
            }
        }
    }
}
