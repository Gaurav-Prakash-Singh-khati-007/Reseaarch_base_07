//
//  CSLEngine.swift
//  ResearchBase
//
//  Owner: Agent 23 · Features: F-34 (more citation styles, CSL)
//
//  A small Citation Style Language (CSL 1.0.2) interpreter. It reads a .csl
//  file and formats in-text citations and bibliography entries. It does not
//  touch the database or any other file in the project.
//
//  PUBLIC API
//    struct CSLName                       one person or organisation
//    struct CSLReference                  plain input record
//      init(item: ModelItem, creators: [ItemCreator])
//    enum CSLOutputFormat                 .plain, .markdown, .html
//    struct CSLCitationItem               reference + optional locator / prefix / suffix
//    final class CSLStyle                 a parsed style
//      static func parse(_ data: Data) throws -> CSLStyle
//      var title, id, isNumeric, bibtexStyleName
//    enum CSLEngineError
//    struct CSLEngine
//      init(style: CSLStyle, format: CSLOutputFormat = .plain)
//      init(styleXML: Data, format: CSLOutputFormat = .plain) throws
//      func citation(_ items: [CSLCitationItem], numbers: [String: Int] = [:],
//                    allReferences: [CSLReference] = []) -> String
//      func bibliography(_ refs: [CSLReference]) -> [String]
//      static let builtInStyles: [BuiltInStyle]   apa, ieee, harvard, nature, chicago
//      static func builtIn(_ id: String) -> CSLStyle?
//      static func bstName(forStyleID id: String) -> String   .bst name for LaTeX
//
//  Supported CSL: style/info, macro, citation/bibliography layout, group,
//  text (variable, macro, value, term), names (name, et-al, label, substitute),
//  date (parts), number, label, choose (type, variable, is-numeric, position,
//  disambiguate, locator, match any/all/none), sort, affixes, prefix/suffix,
//  quotes, font-style/weight, text-case, strip-periods, delimiter,
//  year-suffix disambiguation, collapse of numeric ranges. Locale terms are
//  built in for en-US; an in-file <locale> overrides them.
//  Not supported: other languages, citation-number ranges by `collapse`
//  other than numeric, cs:intext, hyperlink output.
//

import Foundation

// MARK: - Input types

struct CSLName: Equatable {
    var family: String
    var given: String = ""
    var suffix: String = ""
    var isOrganisation: Bool = false
}

struct CSLReference: Equatable {
    var id: String
    /// CSL type: article-journal, paper-conference, book, chapter, thesis,
    /// report, webpage, dataset, software, article (preprint).
    var type: String = "article-journal"
    var title: String = ""
    var containerTitle: String = ""
    var authors: [CSLName] = []
    var editors: [CSLName] = []
    var translators: [CSLName] = []
    var year: Int?
    var month: String = ""
    var volume: String = ""
    var issue: String = ""
    var page: String = ""
    var publisher: String = ""
    var edition: String = ""
    var doi: String = ""
    var url: String = ""
    var arxivID: String = ""
    var abstract: String = ""
    var accessedYear: Int?

    init(id: String) { self.id = id }

    init(item: ModelItem, creators: [ItemCreator]) {
        self.id = item.citationKey.isEmpty ? item.id : item.citationKey
        switch item.type {
        case .article: type = "article-journal"
        case .preprint: type = "article"
        case .conference: type = "paper-conference"
        case .book: type = "book"
        case .chapter: type = "chapter"
        case .thesis: type = "thesis"
        case .report: type = "report"
        case .webpage: type = "webpage"
        case .dataset: type = "dataset"
        case .software: type = "software"
        }
        title = item.title
        containerTitle = item.venue
        year = item.year
        month = item.month
        volume = item.volume
        issue = item.issue
        page = item.pages
        publisher = item.publisher
        edition = item.edition
        doi = item.doi ?? ""
        url = item.url
        arxivID = item.arxivID ?? ""
        abstract = item.abstract
        func name(_ c: Creator) -> CSLName {
            CSLName(family: c.family, given: c.given, suffix: c.suffix, isOrganisation: c.isOrganisation)
        }
        let sorted = creators.sorted { $0.position < $1.position }
        authors = sorted.filter { $0.role == .author }.map { name($0.creator) }
        editors = sorted.filter { $0.role == .editor }.map { name($0.creator) }
        translators = sorted.filter { $0.role == .translator }.map { name($0.creator) }
    }
}

struct CSLCitationItem: Equatable {
    var reference: CSLReference
    var locator: String = ""
    var label: String = "page"
    var prefix: String = ""
    var suffix: String = ""
    init(_ reference: CSLReference, locator: String = "", label: String = "page", prefix: String = "", suffix: String = "") {
        self.reference = reference
        self.locator = locator
        self.label = label
        self.prefix = prefix
        self.suffix = suffix
    }
}

enum CSLOutputFormat { case plain, markdown, html }

enum CSLEngineError: Error, Equatable {
    case notXML(String)
    case notCSL
    case missingLayout
}

// MARK: - XML tree

final class CSLNode {
    let name: String
    var attrs: [String: String]
    var children: [CSLNode] = []
    var text = ""
    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }
    func child(_ n: String) -> CSLNode? { children.first { $0.name == n } }
    func kids(_ n: String) -> [CSLNode] { children.filter { $0.name == n } }
    subscript(_ key: String) -> String? { attrs[key] }
}

private final class CSLXMLBuilder: NSObject, XMLParserDelegate {
    var root: CSLNode?
    private var stack: [CSLNode] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = CSLNode(name: elementName, attrs: attributeDict)
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

// MARK: - Style

final class CSLStyle {
    let root: CSLNode
    var macros: [String: CSLNode] = [:]
    var terms: [String: String] = CSLStyle.defaultTerms
    let citationLayout: CSLNode
    let bibliographyLayout: CSLNode?
    let citation: CSLNode
    let bibliography: CSLNode?

    var title: String { root.child("info")?.child("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var id: String { root.child("info")?.child("id")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var isNumeric: Bool { root.child("info")?.kids("category").contains { $0["citation-format"] == "numeric" } ?? false }
    /// Value of `<style default-locale>` style option: the class decides in-text vs note.
    var bibtexStyleName: String { CSLEngine.bstName(forStyleID: id) }

    init(root: CSLNode, citation: CSLNode, layout: CSLNode, bibliography: CSLNode?, bibLayout: CSLNode?) {
        self.root = root
        self.citation = citation
        self.citationLayout = layout
        self.bibliography = bibliography
        self.bibliographyLayout = bibLayout
    }

    static func parse(_ data: Data) throws -> CSLStyle {
        let builder = CSLXMLBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw CSLEngineError.notXML(parser.parserError?.localizedDescription ?? "invalid XML")
        }
        guard let root = builder.root, root.name == "style" else { throw CSLEngineError.notCSL }
        guard let citation = root.child("citation"), let layout = citation.child("layout") else {
            throw CSLEngineError.missingLayout
        }
        let bib = root.child("bibliography")
        let style = CSLStyle(root: root, citation: citation, layout: layout, bibliography: bib, bibLayout: bib?.child("layout"))
        for m in root.kids("macro") { if let n = m["name"] { style.macros[n] = m } }
        for loc in root.kids("locale") {
            if let lang = loc["xml:lang"], !lang.lowercased().hasPrefix("en") { continue }
            for t in loc.child("terms")?.kids("term") ?? [] {
                guard let n = t["name"] else { continue }
                let form = t["form"] ?? "long"
                let value: String
                if t.child("single") != nil { value = t.child("single")?.text ?? "" } else { value = t.text }
                style.terms[form == "long" ? n : "\(n)|\(form)"] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let multiple = t.child("multiple") {
                    style.terms["\(n)|\(form)|plural"] = multiple.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return style
    }

    static let defaultTerms: [String: String] = [
        "and": "and", "and|symbol": "&", "et-al": "et al.", "in": "in", "accessed": "accessed",
        "available at": "available at", "retrieved": "retrieved", "at": "at", "from": "from",
        "editor": "editor", "editor|plural": "editors", "editor|short": "ed.", "editor|short|plural": "eds.",
        "translator": "translator", "translator|short": "trans.",
        "page": "page", "page|plural": "pages", "page|short": "p.", "page|short|plural": "pp.",
        "volume": "volume", "volume|short": "vol.", "volume|short|plural": "vols.",
        "issue": "issue", "issue|short": "no.", "edition": "edition", "edition|short": "ed.",
        "no date": "n.d.", "no date|short": "n.d.", "online": "online",
        "ordinal": "th", "ordinal-01": "st", "ordinal-02": "nd", "ordinal-03": "rd",
        "month-01": "January", "month-02": "February", "month-03": "March", "month-04": "April",
        "month-05": "May", "month-06": "June", "month-07": "July", "month-08": "August",
        "month-09": "September", "month-10": "October", "month-11": "November", "month-12": "December",
        "month-01|short": "Jan.", "month-02|short": "Feb.", "month-03|short": "Mar.", "month-04|short": "Apr.",
        "month-05|short": "May", "month-06|short": "Jun.", "month-07|short": "Jul.", "month-08|short": "Aug.",
        "month-09|short": "Sep.", "month-10|short": "Oct.", "month-11|short": "Nov.", "month-12|short": "Dec.",
        "open-quote": "\u{201C}", "close-quote": "\u{201D}",
        "open-inner-quote": "\u{2018}", "close-inner-quote": "\u{2019}",
    ]
}

// MARK: - Engine

struct CSLEngine {

    struct BuiltInStyle: Equatable {
        let id: String
        let name: String
        let bst: String
        let xml: String
    }

    let style: CSLStyle
    let format: CSLOutputFormat

    init(style: CSLStyle, format: CSLOutputFormat = .plain) {
        self.style = style
        self.format = format
    }

    init(styleXML: Data, format: CSLOutputFormat = .plain) throws {
        self.style = try CSLStyle.parse(styleXML)
        self.format = format
    }

    // MARK: Public

    /// One in-text citation for one or more items. `numbers` maps reference id to
    /// its citation number (needed by numeric styles; ignored otherwise).
    func citation(_ items: [CSLCitationItem], numbers: [String: Int] = [:], allReferences: [CSLReference] = []) -> String {
        guard !items.isEmpty else { return "" }
        let layout = style.citationLayout
        var ctx = Context(engine: self, mode: .citation, numbers: numbers)
        ctx.disambiguateYears(allRefs: allReferences.isEmpty ? items.map(\.reference) : allReferences)

        var parts: [String] = []
        for (i, it) in items.enumerated() {
            ctx.ref = it.reference
            ctx.locator = it.locator
            ctx.locatorLabel = it.label
            ctx.position = i == 0 ? "first" : "subsequent"
            var s = renderLayout(layout, ctx: &ctx)
            if !it.prefix.isEmpty { s = it.prefix + " " + s }
            if !it.suffix.isEmpty { s += " " + it.suffix }
            parts.append(s)
        }
        var out: String
        if style.isNumeric, style.citation["collapse"] == "citation-number" {
            out = collapseNumeric(parts, items: items, numbers: numbers, layout: layout)
        } else {
            out = parts.joined(separator: layout["delimiter"] ?? "")
        }
        return wrapAffixes(out, node: layout, wrapDelimiter: false)
    }

    /// Bibliography entries, sorted and numbered according to the style.
    func bibliography(_ refs: [CSLReference]) -> [String] {
        guard let bib = style.bibliography, let layout = style.bibliographyLayout else { return [] }
        var ordered = refs
        if let sort = bib.child("sort") {
            ordered = sorted(refs, by: sort)
        } else if style.isNumeric == false, let sort = style.citation.child("sort") {
            ordered = sorted(refs, by: sort)
        }
        var ctx = Context(engine: self, mode: .bibliography, numbers: [:])
        if style.isNumeric {
            // Numeric styles number in the order of the supplied list unless sorted by the style.
            for (i, r) in ordered.enumerated() { ctx.numbers[r.id] = i + 1 }
        }
        ctx.disambiguateYears(allRefs: ordered)
        let subsequentSub = bib["subsequent-author-substitute"]
        var previousAuthors = ""
        var result: [String] = []
        for r in ordered {
            ctx.ref = r
            ctx.position = "first"
            var s = renderLayout(layout, ctx: &ctx)
            if let sub = subsequentSub {
                let a = r.authors.map { $0.family + $0.given }.joined()
                if !a.isEmpty, a == previousAuthors, let range = s.range(of: authorsText(r, ctx: &ctx)) {
                    s.replaceSubrange(range, with: sub)
                }
                previousAuthors = a
            }
            s = wrapAffixes(s, node: layout, wrapDelimiter: false)
            result.append(s.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    /// The `.bst` file name to use for a style when the draft is built with BibTeX.
    static func bstName(forStyleID id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("ieee") { return "IEEEtran" }
        if lower.contains("nature") { return "naturemag" }
        if lower.contains("harvard") { return "agsm" }
        if lower.contains("apa") { return "apalike" }
        if lower.contains("chicago") { return "chicago" }
        if lower.contains("acm") { return "ACM-Reference-Format" }
        if lower.contains("springer") { return "spbasic" }
        return "plainnat"
    }

    // MARK: Rendering context

    enum Mode { case citation, bibliography }

    struct Context {
        let engine: CSLEngine
        let mode: Mode
        var numbers: [String: Int]
        var ref = CSLReference(id: "")
        var locator = ""
        var locatorLabel = "page"
        var position = "first"
        var yearSuffix: [String: String] = [:]
        var inSubstitute = false
        var suppressedVars: Set<String> = []

        init(engine: CSLEngine, mode: Mode, numbers: [String: Int]) {
            self.engine = engine
            self.mode = mode
            self.numbers = numbers
        }

        /// a, b, c... for references with the same first-author family and year.
        mutating func disambiguateYears(allRefs: [CSLReference]) {
            var groups: [String: [CSLReference]] = [:]
            var seen = Set<String>()
            for r in allRefs where !seen.contains(r.id) {
                seen.insert(r.id)
                let key = (r.authors.first?.family.lowercased() ?? "") + "|" + (r.year.map(String.init) ?? "")
                groups[key, default: []].append(r)
            }
            for (_, g) in groups where g.count > 1 {
                for (i, r) in g.sorted(by: { $0.title.lowercased() < $1.title.lowercased() }).enumerated() {
                    yearSuffix[r.id] = Context.letters(i)
                }
            }
        }

        static func letters(_ index: Int) -> String {
            var n = index, s = ""
            repeat {
                s = String(UnicodeScalar(UInt8(97 + n % 26))) + s
                n = n / 26 - 1
            } while n >= 0
            return s
        }
    }

    // MARK: Node walk

    /// A layout's own delimiter separates citations, not the pieces inside one.
    private func renderLayout(_ node: CSLNode, ctx: inout Context) -> String {
        node.children.map { render($0, ctx: &ctx) }.filter { !$0.isEmpty }.joined()
    }

    /// Joins pieces with a delimiter. A delimiter that starts with "." does not
    /// double a period the previous piece already ends with ("G." + ". " -> "G. ").
    private func joinPieces(_ pieces: [String], delimiter: String) -> String {
        var out = ""
        for (i, p) in pieces.enumerated() {
            if i == 0 { out = p; continue }
            var d = delimiter
            if d.hasPrefix("."), out.hasSuffix(".") { d.removeFirst() }
            out += d + p
        }
        return out
    }

    private func renderChildren(_ node: CSLNode, ctx: inout Context) -> String {
        var pieces: [String] = []
        for c in node.children {
            let r = render(c, ctx: &ctx)
            if !r.isEmpty { pieces.append(r) }
        }
        return joinPieces(pieces, delimiter: node["delimiter"] ?? "")
    }

    private func render(_ node: CSLNode, ctx: inout Context) -> String {
        switch node.name {
        case "text": return renderText(node, ctx: &ctx)
        case "group": return renderGroup(node, ctx: &ctx)
        case "choose": return renderChoose(node, ctx: &ctx)
        case "names": return renderNames(node, ctx: &ctx)
        case "date": return renderDate(node, ctx: &ctx)
        case "number": return renderNumber(node, ctx: &ctx)
        case "label": return renderLabel(node, ctx: &ctx)
        default: return ""
        }
    }

    private func renderGroup(_ node: CSLNode, ctx: inout Context) -> String {
        // A group disappears when it calls variables and every one of them is empty.
        var calledVariable = false
        var anyFilled = false
        var pieces: [String] = []
        for c in node.children {
            let isVar = (c.name == "text" && c["variable"] != nil) || c.name == "names" || c.name == "date" || c.name == "number"
            let r = render(c, ctx: &ctx)
            if isVar || c.name == "text" && c["macro"] != nil {
                if isVar { calledVariable = true }
                if !r.isEmpty { anyFilled = true }
            }
            if c.name == "group" || c.name == "choose" {
                if !r.isEmpty { anyFilled = true }
                calledVariable = true
            }
            if !r.isEmpty { pieces.append(r) }
        }
        if calledVariable && !anyFilled { return "" }
        if pieces.isEmpty { return "" }
        return decorate(joinPieces(pieces, delimiter: node["delimiter"] ?? ""), node: node)
    }

    private func renderText(_ node: CSLNode, ctx: inout Context) -> String {
        var s = ""
        if let m = node["macro"], let macro = style.macros[m] {
            s = renderChildren(macro, ctx: &ctx)
        } else if let v = node["variable"] {
            s = variable(v, form: node["form"], ctx: ctx)
            if v == "title" || v == "container-title" || v == "publisher" { /* plain text */ }
        } else if let v = node["value"] {
            s = v
        } else if let t = node["term"] {
            s = term(t, form: node["form"], plural: node["plural"] == "true")
        }
        if s.isEmpty { return "" }
        return decorate(s, node: node)
    }

    private func renderLabel(_ node: CSLNode, ctx: inout Context) -> String {
        guard let v = node["variable"] else { return "" }
        let value: String
        let name: String
        switch v {
        case "locator": value = ctx.locator; name = ctx.locatorLabel
        case "page": value = ctx.ref.page; name = "page"
        case "volume": value = ctx.ref.volume; name = "volume"
        case "issue": value = ctx.ref.issue; name = "issue"
        case "edition": value = ctx.ref.edition; name = "edition"
        default: return ""
        }
        if value.isEmpty { return "" }
        let plural: Bool
        switch node["plural"] ?? "contextual" {
        case "always": plural = true
        case "never": plural = false
        default: plural = value.contains("-") || value.contains("\u{2013}") || value.contains(",") || value.contains("&")
        }
        var t = term(name, form: node["form"], plural: plural)
        if node["strip-periods"] == "true" { t = t.replacingOccurrences(of: ".", with: "") }
        return decorate(t, node: node)
    }

    private func renderNumber(_ node: CSLNode, ctx: inout Context) -> String {
        guard let v = node["variable"] else { return "" }
        var raw: String
        switch v {
        case "citation-number": raw = ctx.numbers[ctx.ref.id].map(String.init) ?? ""
        case "volume": raw = ctx.ref.volume
        case "issue": raw = ctx.ref.issue
        case "page": raw = ctx.ref.page
        case "edition": raw = ctx.ref.edition
        case "locator": raw = ctx.locator
        default: raw = ""
        }
        if raw.isEmpty { return "" }
        if node["form"] == "ordinal", let n = Int(raw) { raw = ordinal(n) }
        return decorate(raw, node: node)
    }

    private func ordinal(_ n: Int) -> String {
        let mod100 = n % 100, mod10 = n % 10
        if (11...13).contains(mod100) { return "\(n)\(term("ordinal", form: nil, plural: false))" }
        switch mod10 {
        case 1: return "\(n)\(term("ordinal-01", form: nil, plural: false))"
        case 2: return "\(n)\(term("ordinal-02", form: nil, plural: false))"
        case 3: return "\(n)\(term("ordinal-03", form: nil, plural: false))"
        default: return "\(n)\(term("ordinal", form: nil, plural: false))"
        }
    }

    // MARK: Variables

    private func variable(_ name: String, form: String?, ctx: Context) -> String {
        let r = ctx.ref
        switch name {
        case "title", "title-short":
            return r.title
        case "container-title": return r.containerTitle
        case "publisher": return r.publisher
        case "volume": return r.volume
        case "issue": return r.issue
        case "page":
            return pageRange(r.page, form: form)
        case "page-first": return r.page.split(whereSeparator: { "-\u{2013}\u{2014}".contains($0) }).first.map(String.init) ?? ""
        case "edition": return r.edition
        case "DOI": return r.doi
        case "URL": return r.url
        case "number": return r.arxivID
        case "locator": return ctx.locator
        case "citation-number": return ctx.numbers[r.id].map(String.init) ?? ""
        case "citation-label": return r.id
        case "year-suffix": return ctx.yearSuffix[r.id] ?? ""
        case "abstract": return r.abstract
        case "genre": return r.type == "thesis" ? "Thesis" : ""
        default: return ""
        }
    }

    private func pageRange(_ s: String, form: String?) -> String {
        let normal = s.replacingOccurrences(of: "--", with: "\u{2013}").replacingOccurrences(of: "-", with: "\u{2013}")
        return normal
    }

    private func term(_ name: String, form: String?, plural: Bool) -> String {
        let f = (form == nil || form == "long") ? nil : form
        var keys: [String] = []
        if let f = f {
            if plural { keys.append("\(name)|\(f)|plural") }
            keys.append("\(name)|\(f)")
        }
        if plural { keys.append("\(name)|long|plural"); keys.append("\(name)|plural") }
        keys.append(name)
        for k in keys { if let v = style.terms[k], !v.isEmpty { return v } }
        return ""
    }

    // MARK: choose

    private func renderChoose(_ node: CSLNode, ctx: inout Context) -> String {
        for branch in node.children where branch.name == "if" || branch.name == "else-if" {
            if conditionHolds(branch, ctx: ctx) { return renderChildren(branch, ctx: &ctx) }
        }
        if let e = node.child("else") { return renderChildren(e, ctx: &ctx) }
        return ""
    }

    private func variableIsSet(_ name: String, ctx: Context) -> Bool {
        switch name {
        case "author": return !ctx.ref.authors.isEmpty
        case "editor": return !ctx.ref.editors.isEmpty
        case "translator": return !ctx.ref.translators.isEmpty
        case "issued": return ctx.ref.year != nil
        case "accessed": return ctx.ref.accessedYear != nil
        default: return !variable(name, form: nil, ctx: ctx).isEmpty
        }
    }

    private func conditionHolds(_ node: CSLNode, ctx: Context) -> Bool {
        let match = node["match"] ?? "all"
        var results: [Bool] = []
        func tokens(_ k: String) -> [String]? { node[k]?.split(separator: " ").map(String.init) }
        if let types = tokens("type") { results.append(contentsOf: types.map { $0 == ctx.ref.type }) }
        if let vars = tokens("variable") { results.append(contentsOf: vars.map { variableIsSet($0, ctx: ctx) }) }
        if let nums = tokens("is-numeric") {
            results.append(contentsOf: nums.map { v in
                let s = variable(v, form: nil, ctx: ctx)
                return !s.isEmpty && s.allSatisfy { $0.isNumber }
            })
        }
        if let pos = tokens("position") { results.append(contentsOf: pos.map { $0 == ctx.position || ($0 == "subsequent" && ctx.position != "first") }) }
        if let loc = tokens("locator") { results.append(contentsOf: loc.map { _ in !ctx.locator.isEmpty }) }
        if let dis = tokens("disambiguate") { results.append(contentsOf: dis.map { $0 == "true" ? ctx.yearSuffix[ctx.ref.id] != nil : ctx.yearSuffix[ctx.ref.id] == nil }) }
        if results.isEmpty { return false }
        switch match {
        case "any": return results.contains(true)
        case "none": return !results.contains(true)
        default: return !results.contains(false)
        }
    }

    // MARK: names

    private func people(for role: String, ctx: Context) -> [CSLName] {
        switch role {
        case "author": return ctx.ref.authors
        case "editor": return ctx.ref.editors
        case "translator": return ctx.ref.translators
        default: return []
        }
    }

    private func renderNames(_ node: CSLNode, ctx: inout Context) -> String {
        let roles = (node["variable"] ?? "").split(separator: " ").map(String.init)
        var list: [CSLName] = []
        var usedRole = ""
        for r in roles {
            let p = people(for: r, ctx: ctx)
            if !p.isEmpty { list = p; usedRole = r; break }
        }
        if list.isEmpty {
            if let sub = node.child("substitute") {
                for c in sub.children {
                    var inner = ctx
                    inner.inSubstitute = true
                    let r: String
                    if c.name == "names", c.child("name") == nil, let nameNode = node.child("name") {
                        let copy = CSLNode(name: "names", attrs: c.attrs)
                        copy.children = [nameNode] + c.children
                        r = renderNames(copy, ctx: &inner)
                    } else {
                        r = render(c, ctx: &inner)
                    }
                    if !r.isEmpty { return r }
                }
            }
            return ""
        }
        let nameNode = node.child("name")
        var out = formatNameList(list, nameNode: nameNode, etAl: node.child("et-al"), ctx: ctx)
        if let lab = node.child("label") {
            let plural = list.count > 1
            let t = term(usedRole, form: lab["form"], plural: plural)
            let labelText = decorate(lab["strip-periods"] == "true" ? t.replacingOccurrences(of: ".", with: "") : t, node: lab)
            if !labelText.isEmpty {
                let before = node.children.firstIndex { $0 === lab } ?? 0
                let nameIdx = node.children.firstIndex { $0.name == "name" } ?? 0
                out = before < nameIdx ? labelText + out : out + labelText
            }
        }
        return decorate(out, node: node)
    }

    private func authorsText(_ r: CSLReference, ctx: inout Context) -> String {
        // Used for subsequent-author-substitute: the rendered first names block.
        let nameNode = style.bibliographyLayout.flatMap { findNames($0, macros: style.macros) }
        var c = ctx
        c.ref = r
        return formatNameList(r.authors, nameNode: nameNode?.child("name"), etAl: nameNode?.child("et-al"), ctx: c)
    }

    private func findNames(_ node: CSLNode, macros: [String: CSLNode], depth: Int = 0) -> CSLNode? {
        if depth > 6 { return nil }
        for c in node.children {
            if c.name == "names" { return c }
            if c.name == "text", let m = c["macro"], let mm = macros[m], let f = findNames(mm, macros: macros, depth: depth + 1) { return f }
            if let f = findNames(c, macros: macros, depth: depth + 1) { return f }
        }
        return nil
    }

    private func formatNameList(_ names: [CSLName], nameNode: CSLNode?, etAl: CSLNode?, ctx: Context) -> String {
        // Inherit name options from <citation> / <bibliography> / <style>.
        func opt(_ key: String) -> String? {
            nameNode?[key]
                ?? (ctx.mode == .citation ? style.citation[key] : style.bibliography?[key])
                ?? style.root[key]
        }
        let and = opt("and")
        let delimiter = opt("delimiter") ?? ", "
        let nameAsSort = opt("name-as-sort-order")
        let sortSeparator = opt("sort-separator") ?? ", "
        let initializeWith = opt("initialize-with")
        let form = opt("form") ?? "long"
        let delimiterPrecedes = opt("delimiter-precedes-last") ?? "contextual"
        let etAlMin = Int(opt("et-al-min") ?? "") ?? Int.max
        let etAlUse = Int(opt("et-al-use-first") ?? "") ?? 1
        let etAlSubsequentMin = Int(opt("et-al-subsequent-min") ?? "")
        let etAlSubsequentUse = Int(opt("et-al-subsequent-use-first") ?? "")

        var min = etAlMin, use = etAlUse
        if ctx.position != "first", let m = etAlSubsequentMin { min = m; use = etAlSubsequentUse ?? use }

        var shown = names
        var truncated = false
        if names.count >= min && names.count > use {
            shown = Array(names.prefix(use))
            truncated = true
        }
        let formatted: [String] = shown.enumerated().map { i, n in
            formatOne(n, form: form, asSort: nameAsSort == "all" || (nameAsSort == "first" && i == 0),
                      sortSeparator: sortSeparator, initializeWith: initializeWith,
                      initializeStrip: nameNode?["initialize"] == "false" ? false : true)
        }
        var out: String
        if truncated {
            let etAlTerm = term(etAl?["term"] ?? "et-al", form: nil, plural: false)
            let tail = etAl.map { decorate(etAlTerm, node: $0) } ?? etAlTerm
            let precede = delimiterPrecedes == "always" || (delimiterPrecedes != "never" && formatted.count > 1)
            out = formatted.joined(separator: delimiter) + (precede ? delimiter : " ") + tail
        } else if formatted.count >= 2, let and = and {
            let word = and == "symbol" ? term("and", form: "symbol", plural: false) : term("and", form: nil, plural: false)
            let head = formatted.dropLast().joined(separator: delimiter)
            let precede: Bool
            switch delimiterPrecedes {
            case "always": precede = true
            case "never": precede = false
            case "after-inverted-name": precede = nameAsSort != nil
            default: precede = formatted.count > 2
            }
            out = head + (precede ? delimiter.trimmingCharacters(in: .whitespaces) + " " : " ") + word + " " + formatted.last!
        } else {
            out = formatted.joined(separator: delimiter)
        }
        return out
    }

    private func formatOne(_ n: CSLName, form: String, asSort: Bool, sortSeparator: String,
                           initializeWith: String?, initializeStrip: Bool) -> String {
        if n.isOrganisation || n.given.isEmpty { return n.family }
        if form == "short" { return n.family }
        var given = n.given
        if let w = initializeWith {
            given = given.split(whereSeparator: { $0 == " " || $0 == "-" }).compactMap { part -> String? in
                guard let c = part.first else { return nil }
                let cleaned = part.replacingOccurrences(of: ".", with: "")
                // Keep single-letter parts, shorten others.
                return cleaned.count >= 1 ? String(c).uppercased() + w : nil
            }.joined()
            if w.hasSuffix(" ") { given = given.trimmingCharacters(in: .whitespaces) }
            else { given = given.replacingOccurrences(of: w + w, with: w) }
        }
        let family = n.suffix.isEmpty ? n.family : n.family
        if asSort {
            return n.suffix.isEmpty ? "\(family)\(sortSeparator)\(given)" : "\(family)\(sortSeparator)\(given)\(sortSeparator)\(n.suffix)"
        }
        return n.suffix.isEmpty ? "\(given) \(family)" : "\(given) \(family) \(n.suffix)"
    }

    // MARK: date

    private func renderDate(_ node: CSLNode, ctx: inout Context) -> String {
        guard node["variable"] == "issued" || node["variable"] == "accessed" else { return "" }
        let year = node["variable"] == "accessed" ? ctx.ref.accessedYear : ctx.ref.year
        guard let y = year else { return "" }
        var parts: [String] = []
        let month = monthNumber(ctx.ref.month)
        let partNodes = node.kids("date-part")
        let wantMonth = partNodes.isEmpty ? node["form"] == "text" : partNodes.contains { $0["name"] == "month" }
        let wantYear = partNodes.isEmpty ? true : partNodes.contains { $0["name"] == "year" }
        if partNodes.isEmpty {
            if wantMonth, let m = month { parts.append(term("month-\(String(format: "%02d", m))", form: nil, plural: false)) }
            parts.append(String(y))
        } else {
            for p in partNodes {
                switch p["name"] ?? "" {
                case "year":
                    if wantYear { parts.append(decorate(String(y), node: p)) }
                case "month":
                    if let m = month {
                        let f = p["form"] ?? "long"
                        let t = f == "numeric" ? String(m) : term("month-\(String(format: "%02d", m))", form: f == "long" ? nil : f, plural: false)
                        parts.append(decorate(p["strip-periods"] == "true" ? t.replacingOccurrences(of: ".", with: "") : t, node: p))
                    }
                default: break
                }
            }
        }
        var s = parts.joined(separator: node.kids("date-part").isEmpty ? " " : " ")
        if node["variable"] == "issued", let sfx = ctx.yearSuffix[ctx.ref.id], style.citation["disambiguate-add-year-suffix"] == "true", !containsYearSuffixVariable() {
            s += sfx
        }
        return decorate(s, node: node)
    }

    private func containsYearSuffixVariable() -> Bool {
        func scan(_ n: CSLNode) -> Bool {
            if n.name == "text", n["variable"] == "year-suffix" { return true }
            if n.name == "text", let m = n["macro"], let mm = style.macros[m], scan(mm) { return true }
            return n.children.contains(where: scan)
        }
        return scan(style.citationLayout) || (style.bibliographyLayout.map(scan) ?? false)
    }

    private func monthNumber(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(t), (1...12).contains(n) { return n }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if t.count >= 3, let i = names.firstIndex(of: String(t.prefix(3))) { return i + 1 }
        return nil
    }

    // MARK: sort

    private func sorted(_ refs: [CSLReference], by sort: CSLNode) -> [CSLReference] {
        let ctxBase = Context(engine: self, mode: .bibliography, numbers: [:])
        func key(_ r: CSLReference, _ k: CSLNode) -> String {
            var c = ctxBase
            c.ref = r
            if let m = k["macro"], let macro = style.macros[m] {
                return renderChildren(macro, ctx: &c).lowercased()
            }
            if let v = k["variable"] {
                if v == "issued" { return String(format: "%06d", r.year ?? 0) }
                return variable(v, form: nil, ctx: c).lowercased()
            }
            return ""
        }
        let keys = sort.kids("key")
        return refs.enumerated().sorted { a, b in
            for k in keys {
                let ka = key(a.element, k), kb = key(b.element, k)
                if ka == kb { continue }
                return k["sort"] == "descending" ? ka > kb : ka < kb
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: numeric collapse

    private func collapseNumeric(_ parts: [String], items: [CSLCitationItem], numbers: [String: Int], layout: CSLNode) -> String {
        let delimiter = layout["delimiter"] ?? ", "
        let nums = items.compactMap { numbers[$0.reference.id] }
        guard nums.count == items.count, items.allSatisfy({ $0.locator.isEmpty }) else {
            return parts.joined(separator: delimiter)
        }
        let order = Array(zip(nums, parts)).sorted { $0.0 < $1.0 }
        var out: [String] = []
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && order[j + 1].0 == order[j].0 + 1 { j += 1 }
            if j - i >= 2 {
                out.append("\(order[i].1)\u{2013}\(order[j].1)")
            } else {
                for k in i...j { out.append(order[k].1) }
            }
            i = j + 1
        }
        return out.joined(separator: delimiter)
    }

    // MARK: decoration

    private func decorate(_ text: String, node: CSLNode) -> String {
        var s = text
        if node["strip-periods"] == "true" && node.name == "text" { s = s.replacingOccurrences(of: ".", with: "") }
        switch node["text-case"] {
        case "lowercase": s = s.lowercased()
        case "uppercase": s = s.uppercased()
        case "capitalize-first": s = s.prefix(1).uppercased() + s.dropFirst()
        case "capitalize-all": s = s.capitalized
        case "title": s = titleCase(s)
        case "sentence": s = s.prefix(1).uppercased() + s.dropFirst().lowercased()
        default: break
        }
        if node["quotes"] == "true" {
            s = term("open-quote", form: nil, plural: false) + s + term("close-quote", form: nil, plural: false)
        }
        s = applyFont(s, node: node)
        return wrapAffixes(s, node: node, wrapDelimiter: false)
    }

    private func wrapAffixes(_ s: String, node: CSLNode, wrapDelimiter: Bool) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        if let p = node["prefix"] { out = p + out }
        if let x = node["suffix"] {
            // Do not double a period the text already ends with.
            if x.hasPrefix("."), out.hasSuffix(".") { out += x.dropFirst() } else { out += x }
        }
        return out
    }

    private func applyFont(_ s: String, node: CSLNode) -> String {
        var out = s
        if node["font-style"] == "italic" {
            switch format {
            case .plain: break
            case .markdown: out = "*\(out)*"
            case .html: out = "<i>\(out)</i>"
            }
        }
        if node["font-weight"] == "bold" {
            switch format {
            case .plain: break
            case .markdown: out = "**\(out)**"
            case .html: out = "<b>\(out)</b>"
            }
        }
        if node["font-variant"] == "small-caps", format == .html { out = "<span style=\"font-variant:small-caps\">\(out)</span>" }
        return out
    }

    private func titleCase(_ s: String) -> String {
        let small: Set<String> = ["a", "an", "the", "of", "in", "on", "for", "and", "or", "to", "at", "by", "with", "from", "as", "but", "nor"]
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { i, w in
            let lower = w.lowercased()
            if i > 0 && small.contains(lower) { return lower }
            if w == w.uppercased() && w.count > 1 { return w }   // keep acronyms
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Built-in styles (F-34: Nature, Harvard, Chicago and others)

extension CSLEngine {

    static func builtIn(_ id: String) -> CSLStyle? {
        guard let s = builtInStyles.first(where: { $0.id == id }) else { return nil }
        return try? CSLStyle.parse(Data(s.xml.utf8))
    }

    private static let common = """
      <macro name="author-ap"><names variable="author"><name and="symbol" initialize-with=". " name-as-sort-order="all" delimiter=", " delimiter-precedes-last="always" et-al-min="8" et-al-use-first="6"/><substitute><names variable="editor"/><text variable="title" font-style="italic"/></substitute></names></macro>
      <macro name="author-short"><names variable="author"><name form="short" and="symbol" et-al-min="3" et-al-use-first="1" delimiter=", "/><substitute><names variable="editor"/><text variable="title" quotes="true"/></substitute></names></macro>
      <macro name="year"><choose><if variable="issued"><date variable="issued"><date-part name="year"/></date><text variable="year-suffix"/></if><else><text term="no date" form="short"/></else></choose></macro>
      <macro name="doi"><choose><if variable="DOI"><text variable="DOI" prefix="https://doi.org/"/></if><else-if variable="URL"><text variable="URL"/></else-if></choose></macro>
    """

    static let builtInStyles: [BuiltInStyle] = [

        BuiltInStyle(id: "apa", name: "APA (7th, simplified)", bst: "apalike", xml: """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>APA (simplified)</title><id>researchbase/apa</id></info>
          \(common)
          <macro name="container"><choose><if type="article-journal"><group delimiter=", "><text variable="container-title" font-style="italic"/><group><text variable="volume" font-style="italic"/><text variable="issue" prefix="(" suffix=")"/></group><text variable="page"/></group></if><else-if type="chapter paper-conference"><group delimiter=" "><text term="in"/><text variable="container-title" font-style="italic"/><text variable="page" prefix="(pp. " suffix=")"/></group></else-if><else><text variable="publisher"/></else></choose></macro>
          <citation et-al-min="3" et-al-use-first="1" disambiguate-add-year-suffix="true"><sort><key macro="author-short"/><key variable="issued"/></sort>
            <layout prefix="(" suffix=")" delimiter="; "><group delimiter=", "><text macro="author-short"/><text macro="year"/><group delimiter=" "><label variable="locator" form="short"/><text variable="locator"/></group></group></layout></citation>
          <bibliography hanging-indent="true" et-al-min="8" et-al-use-first="6" disambiguate-add-year-suffix="true"><sort><key macro="author-ap"/><key variable="issued"/></sort>
            <layout><group delimiter=". " suffix="."><text macro="author-ap"/><group prefix="(" suffix=")"><text macro="year"/></group><text variable="title"/><text macro="container"/></group><text macro="doi" prefix=" "/></layout></bibliography>
        </style>
        """),

        BuiltInStyle(id: "ieee", name: "IEEE", bst: "IEEEtran", xml: """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>IEEE</title><id>researchbase/ieee</id><category citation-format="numeric"/></info>
          <macro name="author-ie"><names variable="author"><name initialize-with=". " and="text" delimiter=", " delimiter-precedes-last="never" et-al-min="7" et-al-use-first="1"/><substitute><names variable="editor"/></substitute></names></macro>
          <macro name="container"><choose><if type="article-journal"><group delimiter=", "><text variable="container-title" font-style="italic"/><group delimiter=" "><label variable="volume" form="short"/><text variable="volume"/></group><group delimiter=" "><label variable="issue" form="short"/><text variable="issue"/></group><group delimiter=" "><label variable="page" form="short"/><text variable="page"/></group><date variable="issued"><date-part name="year"/></date></group></if><else-if type="paper-conference chapter"><group delimiter=", "><text term="in" suffix=" "/><text variable="container-title" font-style="italic"/><date variable="issued"><date-part name="year"/></date><group delimiter=" "><label variable="page" form="short"/><text variable="page"/></group></group></else-if><else><group delimiter=", "><text variable="publisher"/><date variable="issued"><date-part name="year"/></date></group></else></choose></macro>
          <citation collapse="citation-number"><sort><key variable="citation-number"/></sort><layout prefix="[" suffix="]" delimiter=", "><text variable="citation-number"/></layout></citation>
          <bibliography entry-spacing="0"><layout suffix="."><text variable="citation-number" prefix="[" suffix="] "/><group delimiter=", "><text macro="author-ie"/><text variable="title" quotes="true"/><text macro="container"/></group></layout></bibliography>
        </style>
        """),

        BuiltInStyle(id: "harvard", name: "Harvard (author-date)", bst: "agsm", xml: """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>Harvard (simplified)</title><id>researchbase/harvard</id></info>
          <macro name="author-h"><names variable="author"><name and="text" initialize-with="." name-as-sort-order="all" delimiter=", " delimiter-precedes-last="never" sort-separator=", " et-al-min="4" et-al-use-first="3"/><substitute><names variable="editor"/><text variable="title"/></substitute></names></macro>
          <macro name="author-short"><names variable="author"><name form="short" and="text" delimiter=", " et-al-min="4" et-al-use-first="1"/><substitute><names variable="editor"/><text variable="title"/></substitute></names></macro>
          <macro name="year"><choose><if variable="issued"><date variable="issued"><date-part name="year"/></date><text variable="year-suffix"/></if><else><text term="no date" form="short"/></else></choose></macro>
          <macro name="container"><choose><if type="article-journal"><group delimiter=", "><text variable="container-title" font-style="italic"/><group delimiter=" "><text variable="volume"/><text variable="issue" prefix="(" suffix=")"/></group><group delimiter=" "><label variable="page" form="short"/><text variable="page"/></group></group></if><else-if type="paper-conference chapter"><group delimiter=" "><text term="in"/><text variable="container-title" font-style="italic"/></group></else-if><else><text variable="publisher"/></else></choose></macro>
          <citation disambiguate-add-year-suffix="true"><sort><key macro="author-short"/><key variable="issued"/></sort>
            <layout prefix="(" suffix=")" delimiter="; "><group delimiter=", "><group delimiter=" "><text macro="author-short"/><text macro="year"/></group><group delimiter=" "><label variable="locator" form="short"/><text variable="locator"/></group></group></layout></citation>
          <bibliography hanging-indent="true" disambiguate-add-year-suffix="true"><sort><key macro="author-h"/><key variable="issued"/></sort>
            <layout suffix="."><group delimiter=" "><text macro="author-h"/><text macro="year" prefix="(" suffix=")"/></group><text variable="title" quotes="true" prefix=", "/><text macro="container" prefix=", "/><text macro="doi" prefix=". Available at: "/></layout></bibliography>
        </style>
        """),

        BuiltInStyle(id: "nature", name: "Nature", bst: "naturemag", xml: """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>Nature</title><id>researchbase/nature</id><category citation-format="numeric"/></info>
          <macro name="author-n"><names variable="author"><name initialize-with=". " and="symbol" delimiter=", " delimiter-precedes-last="never" name-as-sort-order="all" et-al-min="6" et-al-use-first="1"/><substitute><names variable="editor"/></substitute></names></macro>
          <macro name="container"><choose><if type="article-journal"><group delimiter=" "><text variable="container-title" font-style="italic"/><text variable="volume" font-weight="bold"/></group><text variable="page" prefix=", "/></if><else><text variable="publisher"/></else></choose></macro>
          <macro name="year"><date variable="issued" prefix="(" suffix=")"><date-part name="year"/></date></macro>
          <citation collapse="citation-number"><sort><key variable="citation-number"/></sort><layout vertical-align="sup" delimiter=","><text variable="citation-number"/></layout></citation>
          <bibliography><layout suffix="."><text variable="citation-number" suffix=". "/><group delimiter=" "><text macro="author-n"/><text variable="title" suffix="."/><group><text macro="container"/></group><text macro="year"/></group></layout></bibliography>
        </style>
        """),

        BuiltInStyle(id: "chicago", name: "Chicago (author-date)", bst: "chicago", xml: """
        <style xmlns="http://purl.org/net/xbiblio/csl" class="in-text" version="1.0">
          <info><title>Chicago author-date (simplified)</title><id>researchbase/chicago</id></info>
          <macro name="author-c"><names variable="author"><name and="text" name-as-sort-order="first" sort-separator=", " delimiter=", " delimiter-precedes-last="always" et-al-min="11" et-al-use-first="7"/><substitute><names variable="editor"/><text variable="title"/></substitute></names></macro>
          <macro name="author-short"><names variable="author"><name form="short" and="text" delimiter=", " et-al-min="4" et-al-use-first="1"/><substitute><names variable="editor"/><text variable="title"/></substitute></names></macro>
          <macro name="year"><choose><if variable="issued"><date variable="issued"><date-part name="year"/></date><text variable="year-suffix"/></if><else><text term="no date" form="short"/></else></choose></macro>
          <macro name="container"><choose><if type="article-journal"><group delimiter=" "><text variable="container-title" font-style="italic"/><group><text variable="volume"/><text variable="issue" prefix=", no. "/></group></group><text variable="page" prefix=": "/></if><else-if type="chapter paper-conference"><group delimiter=" "><text term="in"/><text variable="container-title" font-style="italic"/></group></else-if><else><text variable="publisher"/></else></choose></macro>
          <citation disambiguate-add-year-suffix="true"><sort><key macro="author-short"/><key variable="issued"/></sort>
            <layout prefix="(" suffix=")" delimiter="; "><group delimiter=", "><group delimiter=" "><text macro="author-short"/><text macro="year"/></group><group delimiter=" "><text variable="locator"/></group></group></layout></citation>
          <bibliography hanging-indent="true" subsequent-author-substitute="\u{2014}\u{2014}\u{2014}" disambiguate-add-year-suffix="true"><sort><key macro="author-c"/><key variable="issued"/></sort>
            <layout suffix="."><group delimiter=". "><text macro="author-c"/><text macro="year"/><text variable="title" quotes="true"/><text macro="container"/></group><text macro="doi" prefix=". "/></layout></bibliography>
        </style>
        """),
    ]
}
