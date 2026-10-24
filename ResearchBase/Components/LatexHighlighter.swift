//
//  LatexHighlighter.swift
//  ResearchBase
//
//  Owner: Agent 33 · Features: L-01
//
//  LaTeX syntax colouring: comments, math, commands, environments (\begin{x} \end{x}),
//  brackets, and the arguments of \cite and \ref. Citation keys that are not in the
//  library get a dotted underline (F-31 "missing keys are flagged").
//
//  Two layers:
//    1. `tokens(in:)`     pure: finds the pieces. No colours, no UI. Easy to test.
//    2. `apply(to:)`      colours an NSMutableAttributedString / NSTextStorage using a theme
//                         built from the app palette (RBColor), so it follows the chosen theme.
//
//  Every rule works inside one line (comments, `$...$`, `{...}` never cross a line end), so
//  after an edit only the lines that were touched need to be coloured again:
//  `apply(to:range:)` does exactly that.
//
//  PUBLIC API
//    enum LatexTokenKind { comment, math, command, bracket, environmentName, reference,
//                          citationKnown, citationMissing, argument }
//    struct LatexToken { kind, range (UTF-16 NSRange) }
//    struct LatexHighlightTheme   .make(size:)  attributes(for:)  baseAttributes
//    enum LatexHighlighter
//        tokens(in:range:knownCitationKeys:) -> [LatexToken]
//        apply(to:range:theme:knownCitationKeys:)
//        lineRange(covering:in:) -> NSRange
//
//  `knownCitationKeys`: pass the citation keys of the library to flag missing ones; pass nil
//  to colour every \cite argument as a plain reference.
//

import AppKit
import SwiftUI

// MARK: - Tokens

enum LatexTokenKind: Equatable, CaseIterable {
    /// `% to the end of the line`
    case comment
    /// `$x$` and `$$x$$`
    case math
    /// `\section`, `\begin`, `\\`, `\%` ...
    case command
    /// `{ } [ ]`
    case bracket
    /// `equation` in `\begin{equation}`
    case environmentName
    /// Argument of \ref, \cref, \eqref ... (and of \cite when no library keys were given)
    case reference
    /// A \cite key that is in the library.
    case citationKnown
    /// A \cite key that is not in the library.
    case citationMissing
    /// Argument of \label, \input, \usepackage, \documentclass, \includegraphics ...
    case argument
}

struct LatexToken: Equatable {
    let kind: LatexTokenKind
    /// UTF-16 range in the text, like every Cocoa text range.
    let range: NSRange
}

// MARK: - Theme

struct LatexHighlightTheme {

    var font: NSFont
    var strongFont: NSFont
    var emphasisFont: NSFont

    var text: NSColor
    var comment: NSColor
    var command: NSColor
    var math: NSColor
    var bracket: NSColor
    var environmentName: NSColor
    var reference: NSColor
    var citationKnown: NSColor
    var citationMissing: NSColor
    var argument: NSColor

    /// Colours follow the current app theme (`--accent`, `--ok`, `--warn` ... of the HTML).
    static func make(size: CGFloat = 13) -> LatexHighlightTheme {
        let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let strong = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        let emphasis = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        return LatexHighlightTheme(
            font: regular, strongFont: strong, emphasisFont: emphasis,
            text: NSColor(RBColor.primaryText),
            comment: NSColor(RBColor.mutedText),
            command: NSColor(RBColor.accent),
            math: NSColor(RBColor.success),
            bracket: NSColor(RBColor.secondaryText),
            environmentName: NSColor(RBColor.warning),
            reference: NSColor(RBColor.accentSecondary),
            citationKnown: NSColor(RBColor.accentSecondary),
            citationMissing: NSColor(RBColor.error),
            argument: NSColor(RBColor.secondaryText)
        )
    }

    /// Attributes of ordinary text (also what a re-coloured line is reset to).
    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: text]
    }

    func attributes(for kind: LatexTokenKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .comment: return [.foregroundColor: comment, .font: emphasisFont]
        case .math: return [.foregroundColor: math]
        case .command: return [.foregroundColor: command, .font: strongFont]
        case .bracket: return [.foregroundColor: bracket]
        case .environmentName: return [.foregroundColor: environmentName, .font: strongFont]
        case .reference: return [.foregroundColor: reference]
        case .citationKnown: return [.foregroundColor: citationKnown]
        case .citationMissing:
            return [.foregroundColor: citationMissing,
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: citationMissing]
        case .argument: return [.foregroundColor: argument]
        }
    }

    /// Keys a re-colouring clears before it paints again.
    static let resettableKeys: [NSAttributedString.Key] = [.underlineStyle, .underlineColor]
}

// MARK: - Highlighter

enum LatexHighlighter {

    /// Same alternatives, in the same order, as `TEX_RE` in researchbase.html (plus \nocite):
    /// 1 comment, 2 math, 3 \begin/\end, 4 commands with a {argument}, 5 other commands, 6 brackets.
    private static let pattern = #"(%[^\n]*)|(\$\$?[^$\n]*\$\$?)|(\\(?:begin|end)\{[^}\n]*\})|(\\(?:(?:no)?cite[a-z]*|ref|cref|Cref|eqref|autoref|label|input|include|includegraphics|usepackage|documentclass|bibliography|bibliographystyle)\*?(?:\[[^\]\n]*\])?\{[^}\n]*\})|(\\[A-Za-z@]+\*?|\\.)|([{}\[\]])"#

    private static let regex: NSRegularExpression = {
        // The pattern is a constant; failing here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: [])
    }()

    // MARK: Find the pieces

    /// The coloured pieces of `text`, in order and never overlapping. `range` limits the search
    /// (it is widened to whole lines); nil = the whole text.
    static func tokens(
        in text: String,
        range: NSRange? = nil,
        knownCitationKeys: Set<String>? = nil
    ) -> [LatexToken] {

        let ns = text as NSString
        let target = lineRange(covering: range ?? NSRange(location: 0, length: ns.length), in: ns)
        guard target.length > 0 else { return [] }

        var found: [LatexToken] = []

        regex.enumerateMatches(in: text, options: [], range: target) { match, _, _ in
            guard let match else { return }
            let whole = match.range
            if match.range(at: 1).location != NSNotFound {
                found.append(LatexToken(kind: .comment, range: whole))
            } else if match.range(at: 2).location != NSNotFound {
                found.append(LatexToken(kind: .math, range: whole))
            } else if match.range(at: 3).location != NSNotFound {
                appendEnvironment(whole, in: ns, to: &found)
            } else if match.range(at: 4).location != NSNotFound {
                appendCommandWithArgument(whole, in: ns, known: knownCitationKeys, to: &found)
            } else if match.range(at: 5).location != NSNotFound {
                found.append(LatexToken(kind: .command, range: whole))
            } else {
                found.append(LatexToken(kind: .bracket, range: whole))
            }
        }
        return found
    }

    /// `\begin{name}`: command, `{`, name, `}`.
    private static func appendEnvironment(_ whole: NSRange, in ns: NSString, to out: inout [LatexToken]) {
        let open = ns.range(of: "{", options: [], range: whole)
        guard open.location != NSNotFound else {
            out.append(LatexToken(kind: .command, range: whole))
            return
        }
        let end = NSMaxRange(whole)
        out.append(LatexToken(kind: .command, range: NSRange(location: whole.location, length: open.location - whole.location)))
        out.append(LatexToken(kind: .bracket, range: open))
        let nameStart = NSMaxRange(open)
        if end - 1 > nameStart {
            out.append(LatexToken(kind: .environmentName, range: NSRange(location: nameStart, length: end - 1 - nameStart)))
        }
        out.append(LatexToken(kind: .bracket, range: NSRange(location: end - 1, length: 1)))
    }

    /// `\cite*[opt]{a, b}`: command, optional `[...]`, `{`, argument, `}`.
    private static func appendCommandWithArgument(
        _ whole: NSRange, in ns: NSString, known: Set<String>?, to out: inout [LatexToken]
    ) {
        let end = NSMaxRange(whole)

        // Command name: backslash, letters or @, optional star.
        var cursor = whole.location + 1
        while cursor < end, isCommandLetter(ns.character(at: cursor)) { cursor += 1 }
        if cursor < end, ns.character(at: cursor) == 0x2A /* * */ { cursor += 1 }
        let name = ns.substring(with: NSRange(location: whole.location, length: cursor - whole.location))
        out.append(LatexToken(kind: .command, range: NSRange(location: whole.location, length: cursor - whole.location)))

        // Optional argument.
        if cursor < end, ns.character(at: cursor) == 0x5B /* [ */ {
            let close = ns.range(of: "]", options: [], range: NSRange(location: cursor, length: end - cursor))
            if close.location != NSNotFound {
                out.append(LatexToken(kind: .bracket, range: NSRange(location: cursor, length: 1)))
                out.append(LatexToken(kind: .bracket, range: close))
                cursor = NSMaxRange(close)
            }
        }

        // Braced argument: the match always ends with "}".
        guard cursor < end, ns.character(at: cursor) == 0x7B /* { */ else { return }
        out.append(LatexToken(kind: .bracket, range: NSRange(location: cursor, length: 1)))
        let argStart = cursor + 1
        let argRange = NSRange(location: argStart, length: max(0, end - 1 - argStart))
        defer { out.append(LatexToken(kind: .bracket, range: NSRange(location: end - 1, length: 1))) }
        guard argRange.length > 0 else { return }

        let bare = name.hasSuffix("*") ? String(name.dropLast()) : name
        if bare.hasPrefix("\\cite") || bare.hasPrefix("\\nocite") {
            appendCitationKeys(argRange, in: ns, known: known, to: &out)
        } else if ["\\ref", "\\cref", "\\Cref", "\\eqref", "\\autoref"].contains(bare) {
            out.append(LatexToken(kind: .reference, range: argRange))
        } else {
            out.append(LatexToken(kind: .argument, range: argRange))
        }
    }

    /// One token per key of `a, b, c`; spaces around a key are not part of it.
    private static func appendCitationKeys(
        _ argRange: NSRange, in ns: NSString, known: Set<String>?, to out: inout [LatexToken]
    ) {
        guard let known else {
            out.append(LatexToken(kind: .reference, range: argRange))
            return
        }
        var keyStart = argRange.location
        let end = NSMaxRange(argRange)
        var index = argRange.location

        func flush(upTo stop: Int) {
            var lo = keyStart, hi = stop
            while lo < hi, isSpace(ns.character(at: lo)) { lo += 1 }
            while hi > lo, isSpace(ns.character(at: hi - 1)) { hi -= 1 }
            guard hi > lo else { return }
            let range = NSRange(location: lo, length: hi - lo)
            let key = ns.substring(with: range)
            out.append(LatexToken(kind: key == "*" || known.contains(key) ? .citationKnown : .citationMissing, range: range))
        }

        while index < end {
            if ns.character(at: index) == 0x2C /* , */ {
                flush(upTo: index)
                keyStart = index + 1
            }
            index += 1
        }
        flush(upTo: end)
    }

    private static func isCommandLetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x40
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D
    }

    // MARK: Colour

    /// Colours `storage`. With `range`, only the lines that touch it are repainted (use the edited
    /// range after a keystroke); nil = everything. Only attributes are changed, never the text,
    /// and attributes this file does not own (paragraph style, comment markers) are kept.
    static func apply(
        to storage: NSMutableAttributedString,
        range: NSRange? = nil,
        theme: LatexHighlightTheme? = nil,
        knownCitationKeys: Set<String>? = nil
    ) {
        let theme = theme ?? LatexHighlightTheme.make()
        let text = storage.string
        let ns = text as NSString
        let wanted = range.map { NSIntersectionRange($0, NSRange(location: 0, length: ns.length)) }
            ?? NSRange(location: 0, length: ns.length)
        let target = lineRange(covering: wanted, in: ns)
        guard target.length > 0 else { return }

        storage.beginEditing()
        for key in LatexHighlightTheme.resettableKeys {
            storage.removeAttribute(key, range: target)
        }
        storage.addAttributes(theme.baseAttributes, range: target)
        for token in tokens(in: text, range: target, knownCitationKeys: knownCitationKeys) {
            storage.addAttributes(theme.attributes(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }

    /// `range` widened to whole lines (an empty range inside a line gives that line).
    static func lineRange(covering range: NSRange, in ns: NSString) -> NSRange {
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let location = min(max(range.location, 0), length)
        let clipped = NSRange(location: location, length: min(max(range.length, 0), length - location))
        return ns.lineRange(for: clipped)
    }
}
