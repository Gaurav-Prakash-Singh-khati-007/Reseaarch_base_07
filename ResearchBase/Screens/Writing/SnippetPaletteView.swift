//
//  SnippetPaletteView.swift
//  ResearchBase
//
//  Owner: Agent 40 · Features: L-02
//
//  Snippet palette: insert an equation, figure, table, algorithm, theorem and more at the cursor.
//
//  This file never touches the editor. The palette only tells its caller which snippet was chosen
//  (`onInsert`). The caller puts it in the text with `LatexSnippet.insertion(...)`, which is pure:
//  it gives the new text and where the caret goes (at the `$0` mark of the snippet, so you can type
//  the caption or label straight away). Continuation lines take the indentation of the line the
//  snippet is inserted on.
//
//  PUBLIC API
//    struct LatexSnippet: Identifiable   id, name, trigger, category, body ($0 = caret)
//        insertion(into: String, selection: NSRange) -> LatexSnippetInsertion
//    struct LatexSnippetInsertion        text, selection (caret), insertedRange
//    enum LatexSnippetLibrary
//        all: [LatexSnippet]
//        snippet(forTrigger:) -> LatexSnippet?          "eq" -> Equation (for "type eq then Tab")
//        trigger(before caret: Int, in text: String) -> (snippet, range)?
//        search(_ query: String) -> [LatexSnippet]      name, trigger, category and body
//    struct SnippetPaletteView: View
//        init(onInsert: (LatexSnippet) -> Void, columns: Int = 2)
//
//  Needs nothing from other files except RBColor.
//

import AppKit
import SwiftUI

// MARK: - Snippet

enum LatexSnippetCategory: String, CaseIterable {
    case math = "Math"
    case figures = "Figures and tables"
    case structure = "Structure"
    case code = "Code and algorithms"
}

struct LatexSnippet: Identifiable, Equatable {
    let id: String
    let name: String
    /// Type this and press Tab (handled by the editor's owner, see `LatexSnippetLibrary.trigger`).
    let trigger: String
    let category: LatexSnippetCategory
    /// The text to insert. `$0` marks where the caret goes (the first one; the rest are removed).
    let body: String

    /// What the text looks like after inserting this snippet over `selection`.
    func insertion(into text: String, selection: NSRange) -> LatexSnippetInsertion {
        let ns = text as NSString
        let location = min(max(selection.location, 0), ns.length)
        let length = min(max(selection.length, 0), ns.length - location)
        let replaced = NSRange(location: location, length: length)

        // Indentation of the line the snippet starts on.
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        var indent = ""
        var i = line.location
        while i < location {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 { indent.append(Character(UnicodeScalar(c)!)) } else { break }
            i += 1
        }

        // Caret mark, then indentation of the continuation lines.
        let marker = "$0"
        var before = body
        var after = ""
        if let r = body.range(of: marker) {
            before = String(body[..<r.lowerBound])
            after = String(body[r.upperBound...]).replacingOccurrences(of: marker, with: "")
        }
        func indented(_ s: String) -> String {
            indent.isEmpty ? s : s.replacingOccurrences(of: "\n", with: "\n" + indent)
        }
        let head = indented(before)
        let full = head + indented(after)

        let newText = ns.replacingCharacters(in: replaced, with: full)
        let caret = location + (head as NSString).length
        return LatexSnippetInsertion(
            text: newText,
            selection: NSRange(location: caret, length: 0),
            insertedRange: NSRange(location: location, length: (full as NSString).length)
        )
    }
}

struct LatexSnippetInsertion: Equatable {
    let text: String
    let selection: NSRange
    let insertedRange: NSRange
}

// MARK: - Library

enum LatexSnippetLibrary {

    static let all: [LatexSnippet] = [
        LatexSnippet(id: "eq", name: "Equation", trigger: "eq", category: .math, body: #"""
        \begin{equation}
          $0
          \label{eq:}
        \end{equation}
        """#),
        LatexSnippet(id: "align", name: "Aligned equations", trigger: "align", category: .math, body: #"""
        \begin{align}
          $0 &= \label{eq:} \\
           &=
        \end{align}
        """#),
        LatexSnippet(id: "mat", name: "Matrix", trigger: "mat", category: .math, body: #"""
        \begin{bmatrix}
          $0 & \\
           &
        \end{bmatrix}
        """#),
        LatexSnippet(id: "cases", name: "Cases", trigger: "cases", category: .math, body: #"""
        f(x) =
        \begin{cases}
          $0 & \text{if } \\
           & \text{otherwise}
        \end{cases}
        """#),
        LatexSnippet(id: "fig", name: "Figure", trigger: "fig", category: .figures, body: #"""
        \begin{figure}[t]
          \centering
          \includegraphics[width=0.8\linewidth]{figures/$0}
          \caption{}
          \label{fig:}
        \end{figure}
        """#),
        LatexSnippet(id: "subfig", name: "Two figures side by side", trigger: "subfig", category: .figures, body: #"""
        \begin{figure}[t]
          \centering
          \begin{subfigure}{0.48\linewidth}
            \includegraphics[width=\linewidth]{figures/$0a.pdf}
            \caption{First}\label{fig:a}
          \end{subfigure}\hfill
          \begin{subfigure}{0.48\linewidth}
            \includegraphics[width=\linewidth]{figures/b.pdf}
            \caption{Second}\label{fig:b}
          \end{subfigure}
          \caption{Both parts.}\label{fig:ab}
        \end{figure}
        """#),
        LatexSnippet(id: "tab", name: "Table (booktabs)", trigger: "tab", category: .figures, body: #"""
        \begin{table}[t]
          \centering
          \caption{$0}
          \label{tab:}
          \begin{tabular}{lcc}
            \toprule
            Method & A & B \\
            \midrule
            Ours & 0.0 & 0.0 \\
            \bottomrule
          \end{tabular}
        \end{table}
        """#),
        LatexSnippet(id: "alg", name: "Algorithm", trigger: "alg", category: .code, body: #"""
        \begin{algorithm}[t]
          \caption{$0}
          \label{alg:}
          \begin{algorithmic}[1]
            \Require input
            \Ensure output
            \State step
          \end{algorithmic}
        \end{algorithm}
        """#),
        LatexSnippet(id: "lst", name: "Code listing", trigger: "lst", category: .code, body: #"""
        \begin{lstlisting}[language=Python,caption={},label={lst:}]
        $0
        \end{lstlisting}
        """#),
        LatexSnippet(id: "plot", name: "Plot with pgfplots", trigger: "plot", category: .figures, body: #"""
        \begin{tikzpicture}
          \begin{axis}[xlabel={$0}, ylabel={}, width=0.8\linewidth]
            \addplot coordinates {(0,0) (1,1) (2,4)};
          \end{axis}
        \end{tikzpicture}
        """#),
        LatexSnippet(id: "thm", name: "Theorem and proof", trigger: "thm", category: .structure, body: #"""
        \begin{theorem}
          $0
          \label{thm:}
        \end{theorem}
        \begin{proof}
          
        \end{proof}
        """#),
        LatexSnippet(id: "def", name: "Definition", trigger: "def", category: .structure, body: #"""
        \begin{definition}[$0]
          \label{def:}
        \end{definition}
        """#),
        LatexSnippet(id: "itemize", name: "Bulleted list", trigger: "itemize", category: .structure, body: #"""
        \begin{itemize}
          \item $0
          \item
        \end{itemize}
        """#),
        LatexSnippet(id: "enum", name: "Numbered list", trigger: "enum", category: .structure, body: #"""
        \begin{enumerate}
          \item $0
          \item
        \end{enumerate}
        """#),
    ]

    private static let byTrigger: [String: LatexSnippet] =
        Dictionary(all.map { ($0.trigger, $0) }, uniquingKeysWith: { first, _ in first })

    static func snippet(forTrigger trigger: String) -> LatexSnippet? { byTrigger[trigger] }

    /// "Type eq then Tab": the word right before the caret, when it is a trigger and stands alone
    /// (not part of a longer word or a command like `\eq`). Returns the snippet and the range to replace.
    static func trigger(before caret: Int, in text: String) -> (snippet: LatexSnippet, range: NSRange)? {
        let ns = text as NSString
        guard caret > 0, caret <= ns.length else { return nil }
        var start = caret
        while start > 0, isWordChar(ns.character(at: start - 1)) { start -= 1 }
        guard start < caret else { return nil }
        if start > 0 {
            let before = ns.character(at: start - 1)
            if before == 0x5C /* \ */ || before == 0x40 /* @ */ { return nil }
        }
        let word = ns.substring(with: NSRange(location: start, length: caret - start))
        guard let snippet = byTrigger[word] else { return nil }
        return (snippet, NSRange(location: start, length: caret - start))
    }

    /// Words of the query must all appear in the name, trigger, category or body.
    /// Trigger matches come first, then name matches.
    static func search(_ query: String) -> [LatexSnippet] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return all }
        var scored: [(Int, Int, LatexSnippet)] = []
        for (index, s) in all.enumerated() {
            let name = s.name.lowercased(), trig = s.trigger.lowercased()
            let cat = s.category.rawValue.lowercased(), body = s.body.lowercased()
            var score = 0
            var ok = true
            for w in words {
                if trig.hasPrefix(w) { score += 0 }
                else if name.contains(w) { score += 1 }
                else if cat.contains(w) { score += 2 }
                else if body.contains(w) { score += 3 }
                else { ok = false; break }
            }
            if ok { scored.append((score, index, s)) }
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { $0.2 }
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
}

// MARK: - View

struct SnippetPaletteView: View {

    var onInsert: (LatexSnippet) -> Void
    var columns: Int

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    init(onInsert: @escaping (LatexSnippet) -> Void, columns: Int = 2) {
        self.onInsert = onInsert
        self.columns = max(1, columns)
    }

    private var results: [LatexSnippet] { LatexSnippetLibrary.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(RBColor.mutedText)
                TextField("Search snippets", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = results.first { onInsert(first) } }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RBColor.inputBackground, in: RoundedRectangle(cornerRadius: 8))

            if results.isEmpty {
                Text("No snippet matches “\(query)”.")
                    .font(.callout).foregroundStyle(RBColor.mutedText)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                        ForEach(results) { snippet in
                            Button { onInsert(snippet) } label: {
                                HStack(spacing: 8) {
                                    Text(snippet.name)
                                        .font(.callout)
                                        .foregroundStyle(RBColor.primaryText)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(snippet.trigger)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(RBColor.mutedText)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(RBColor.card, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RBHoverPlainButtonStyle())
                            .help("Insert \(snippet.name). In the editor: type \(snippet.trigger), then Tab.")
                        }
                    }
                }
            }
        }
        .padding(10)
        .onAppear { searchFocused = true }
    }
}
