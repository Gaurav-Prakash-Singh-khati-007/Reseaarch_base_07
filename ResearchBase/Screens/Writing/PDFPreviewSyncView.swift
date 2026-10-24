//
//  PDFPreviewSyncView.swift
//  ResearchBase
//
//  Owner: Agent 42 · Features: F-33 (preview), L-09
//
//  Shows the compiled PDF of a draft and jumps between source and PDF with SyncTeX:
//    * source -> PDF : give a `PDFForwardRequest` (file, line); the PDF scrolls there and flashes.
//    * PDF -> source : click a place in the PDF; `onJumpToSource` is called
//                      with the file and line (use it to move the editor's caret).
//
//  The PDF is read into memory, so a rebuild that rewrites the file never breaks the open view.
//  After a rebuild the same page and place stay on screen. If the last build failed, the previous
//  good PDF is shown under a "last good build" notice.
//
//  SyncTeX is run through the `synctex` tool found by LatexCompiler (Installation.synctex).
//  Without it, the PDF still shows and the jump is simply off (the toolbar says so).
//
//  PUBLIC API
//    struct PDFForwardRequest: Equatable     id, file (draft-relative), line, column
//    struct SyncTeXRect: Equatable           page (1-based), x, y, width, height  (points, origin top-left)
//    struct SyncTeXSource: Equatable         file, line, column
//    enum   SyncTeX                          (pure)
//        parseView(_ output: String) -> [SyncTeXRect]
//        parseEdit(_ output: String) -> SyncTeXSource?
//        draftRelativePath(_ path: String, draftFolder: URL?) -> String
//        pdfKitRect(for: SyncTeXRect, pageHeight: CGFloat) -> CGRect     origin bottom-left
//    struct SyncTeXClient                    init(executable: URL, pdfURL: URL, draftFolder: URL?)
//        forward(file:line:column:) async -> [SyncTeXRect]
//        reverse(page:x:y:) async -> SyncTeXSource?
//    struct PDFPreviewSyncView: View
//        init(pdfURL: URL?, stalePDFURL: URL? = nil, draftFolder: URL? = nil,
//             synctexExecutable: URL? = nil, forward: PDFForwardRequest? = nil,
//             onJumpToSource: ((SyncTeXSource) -> Void)? = nil)
//          pass BuildResult.pdfURL, .stalePDFURL and Installation.synctex from LatexCompiler.
//
//  Reads (only): LatexCompiler.runCommand (Agent 24), RBColor.
//

import AppKit
import PDFKit
import SwiftUI

// MARK: - Types

struct PDFForwardRequest: Equatable {
    let id: UUID
    /// Path inside the draft folder, e.g. "main.tex" or "sections/intro.tex".
    let file: String
    let line: Int
    let column: Int

    init(file: String, line: Int, column: Int = 0, id: UUID = UUID()) {
        self.id = id
        self.file = file
        self.line = line
        self.column = column
    }
}

/// A box on a PDF page, in PDF points with the origin at the TOP-left (what SyncTeX uses).
struct SyncTeXRect: Equatable {
    let page: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct SyncTeXSource: Equatable {
    let file: String
    let line: Int
    let column: Int?
}

// MARK: - SyncTeX (pure parts)

enum SyncTeX {

    /// Output of `synctex view`: one record per `Page:` line.
    static func parseView(_ output: String) -> [SyncTeXRect] {
        var rects: [SyncTeXRect] = []
        var page: Int?
        var values: [String: Double] = [:]

        func flush() {
            if let page, let h = values["h"], let v = values["v"] {
                let width = values["W"] ?? 0
                let height = values["H"] ?? 0
                // `v` is the baseline: the box runs from v - H down to v.
                rects.append(SyncTeXRect(page: page, x: h, y: v - height, width: width, height: height))
            }
            page = nil
            values = [:]
        }

        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            switch key {
            case "Page":
                flush()
                page = Int(value.trimmingCharacters(in: .whitespaces))
            case "h", "v", "W", "H":
                values[key] = Double(value.trimmingCharacters(in: .whitespaces))
            default:
                break
            }
        }
        flush()
        return rects
    }

    /// Output of `synctex edit`: the first `Input:` / `Line:` / `Column:` group.
    static func parseEdit(_ output: String) -> SyncTeXSource? {
        var file: String?
        var line: Int?
        var column: Int?
        for raw in output.split(whereSeparator: \.isNewline) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Input:") {
                // A second Input: starts the next record; only the first one is wanted.
                if file != nil { break }
                file = String(text.dropFirst("Input:".count))
            } else if text.hasPrefix("Line:"), line == nil {
                line = Int(text.dropFirst("Line:".count).trimmingCharacters(in: .whitespaces))
            } else if text.hasPrefix("Column:"), column == nil {
                if let c = Int(text.dropFirst("Column:".count).trimmingCharacters(in: .whitespaces)), c >= 0 { column = c }
            }
        }
        guard let file, !file.isEmpty, let line, line > 0 else { return nil }
        return SyncTeXSource(file: file, line: line, column: column)
    }

    /// "/…/Draft/./sections/a.tex" -> "sections/a.tex". Paths outside the draft only lose a leading "./".
    static func draftRelativePath(_ path: String, draftFolder: URL?) -> String {
        if let folder = draftFolder {
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            let full = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/"), full.hasPrefix(root + "/") { return String(full.dropFirst(root.count + 1)) }
            // The temp-folder alias /var <-> /private/var.
            let plain = URL(fileURLWithPath: path).standardizedFileURL.path
            let plainRoot = folder.standardizedFileURL.path
            if path.hasPrefix("/"), plain.hasPrefix(plainRoot + "/") { return String(plain.dropFirst(plainRoot.count + 1)) }
        }
        var result = path
        while result.hasPrefix("./") { result.removeFirst(2) }
        return result
    }

    /// PDFKit counts from the bottom-left, SyncTeX from the top-left.
    static func pdfKitRect(for rect: SyncTeXRect, pageHeight: CGFloat) -> CGRect {
        CGRect(x: rect.x, y: pageHeight - (rect.y + rect.height), width: rect.width, height: rect.height)
    }
}

// MARK: - SyncTeX (runs the tool)

struct SyncTeXClient {

    let executable: URL
    let pdfURL: URL
    let draftFolder: URL?
    var timeout: TimeInterval = 10

    init(executable: URL, pdfURL: URL, draftFolder: URL?) {
        self.executable = executable
        self.pdfURL = pdfURL
        self.draftFolder = draftFolder
    }

    /// Where is this source line in the PDF? Tries the absolute path first, then the relative one.
    func forward(file: String, line: Int, column: Int = 0) async -> [SyncTeXRect] {
        var candidates: [String] = []
        if let draftFolder, !file.hasPrefix("/") {
            candidates.append(draftFolder.appendingPathComponent(file).path)
        }
        candidates.append(file)

        for candidate in candidates {
            let outcome = await LatexCompiler.runCommand(
                executable: executable,
                arguments: ["view", "-i", "\(max(line, 1)):\(max(column, 0)):\(candidate)", "-o", pdfURL.path],
                workingDirectory: draftFolder ?? pdfURL.deletingLastPathComponent(),
                timeout: timeout
            )
            let rects = SyncTeX.parseView(outcome.output)
            if !rects.isEmpty { return rects }
        }
        return []
    }

    /// Which source line is at this place of the PDF? `x`, `y` in points from the top-left, `page` from 1.
    func reverse(page: Int, x: Double, y: Double) async -> SyncTeXSource? {
        let outcome = await LatexCompiler.runCommand(
            executable: executable,
            arguments: ["edit", "-o", "\(max(page, 1)):\(x):\(y):\(pdfURL.path)"],
            workingDirectory: draftFolder ?? pdfURL.deletingLastPathComponent(),
            timeout: timeout
        )
        guard let source = SyncTeX.parseEdit(outcome.output) else { return nil }
        return SyncTeXSource(
            file: SyncTeX.draftRelativePath(source.file, draftFolder: draftFolder),
            line: source.line, column: source.column
        )
    }
}

// MARK: - Controller (toolbar -> PDFView)

final class PDFPreviewController {
    fileprivate weak var pdfView: PDFView?

    func zoomIn() { pdfView?.autoScales = false; pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.autoScales = false; pdfView?.zoomOut(nil) }
    func fitWidth() { pdfView?.autoScales = true }
    func nextPage() { pdfView?.goToNextPage(nil) }
    func previousPage() { pdfView?.goToPreviousPage(nil) }
}

// MARK: - The view

struct PDFPreviewSyncView: View {

    var pdfURL: URL?
    var stalePDFURL: URL?
    var draftFolder: URL?
    var synctexExecutable: URL?
    var forward: PDFForwardRequest?
    var onJumpToSource: ((SyncTeXSource) -> Void)?

    @State private var controller = PDFPreviewController()
    @State private var page = 0
    @State private var pageCount = 0

    init(
        pdfURL: URL?,
        stalePDFURL: URL? = nil,
        draftFolder: URL? = nil,
        synctexExecutable: URL? = nil,
        forward: PDFForwardRequest? = nil,
        onJumpToSource: ((SyncTeXSource) -> Void)? = nil
    ) {
        self.pdfURL = pdfURL
        self.stalePDFURL = stalePDFURL
        self.draftFolder = draftFolder
        self.synctexExecutable = synctexExecutable
        self.forward = forward
        self.onJumpToSource = onJumpToSource
    }

    private var shownURL: URL? { pdfURL ?? stalePDFURL }
    private var showingStale: Bool { pdfURL == nil && stalePDFURL != nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if showingStale {
                Label("The last build failed. This is the last good PDF.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(RBColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RBColor.surface)
            }
            if let url = shownURL {
                PDFKitSyncRepresentable(
                    url: url,
                    draftFolder: draftFolder,
                    synctex: synctexExecutable,
                    forward: forward,
                    controller: controller,
                    onJump: onJumpToSource,
                    onPage: { index, count in page = index; pageCount = count }
                )
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(RBColor.mutedText)
                    Text("No PDF yet").font(.headline).foregroundStyle(RBColor.primaryText)
                    Text("Press Build to compile the draft.").font(.callout).foregroundStyle(RBColor.mutedText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(RBColor.card)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text("Preview").font(.callout.weight(.semibold)).foregroundStyle(RBColor.primaryText)
            Spacer()
            Text(syncHint).font(.caption).foregroundStyle(RBColor.mutedText).lineLimit(1)
            if pageCount > 0 {
                Button { controller.previousPage() } label: { Image(systemName: "chevron.up") }
                    .disabled(page <= 1)
                Text("\(page) / \(pageCount)").font(.caption.monospacedDigit()).foregroundStyle(RBColor.mutedText)
                Button { controller.nextPage() } label: { Image(systemName: "chevron.down") }
                    .disabled(page >= pageCount)
            }
            Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button { controller.fitWidth() } label: { Image(systemName: "arrow.left.and.right") }.help("Fit to width")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RBColor.surface)
    }

    private var syncHint: String {
        if shownURL == nil { return "" }
        return synctexExecutable == nil ? "Jump to source is off: SyncTeX not found" : "Click the PDF to jump to the source"
    }
}

// MARK: - PDFView

/// A PDFView that reports a plain click (not a drag) as "jump to source".
/// Dragging still selects text; ⌘-click and double-click keep working.
final class SyncPDFView: PDFView {

    var onSyncClick: ((PDFPage, CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        // PDFView tracks the whole press inside this call, so when it returns the
        // mouse has been released; comparing the two points tells a click from a drag.
        super.mouseDown(with: event)
        let end = window?.currentEvent?.locationInWindow ?? start
        guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }

        let local = convert(start, from: nil)
        if let page = page(for: local, nearest: false) {
            onSyncClick?(page, convert(local, to: page))
        }
    }
}

private struct PDFKitSyncRepresentable: NSViewRepresentable {

    let url: URL
    let draftFolder: URL?
    let synctex: URL?
    let forward: PDFForwardRequest?
    let controller: PDFPreviewController
    let onJump: ((SyncTeXSource) -> Void)?
    let onPage: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(RBColor.surface)
        controller.pdfView = view
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: SyncPDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        controller.pdfView = view
        c.loadIfChanged(into: view)

        if let forward, c.lastForwardID != forward.id {
            c.lastForwardID = forward.id
            c.runForward(forward, in: view)
        }
    }

    final class Coordinator: NSObject {

        var parent: PDFKitSyncRepresentable?
        var lastForwardID: UUID?
        private var loadedURL: URL?
        private var loadedStamp: Date?
        private weak var view: SyncPDFView?

        func attach(to view: SyncPDFView) {
            self.view = view
            view.onSyncClick = { [weak self] page, point in self?.runReverse(page: page, point: point) }
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func pageChanged() { reportPage() }

        private func reportPage() {
            guard let view, let doc = view.document else { parent?.onPage(0, 0); return }
            let index = view.currentPage.map { doc.index(for: $0) + 1 } ?? 1
            parent?.onPage(index, doc.pageCount)
        }

        /// Loads the file when it is a new file or was rewritten, and keeps the reader's place.
        func loadIfChanged(into view: SyncPDFView) {
            guard let url = parent?.url else { return }
            let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if url == loadedURL, stamp == loadedStamp, view.document != nil { return }

            let sameFile = url == loadedURL
            let place = sameFile ? view.currentDestination : nil
            let pageIndex = place?.page.flatMap { view.document?.index(for: $0) }

            guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
                // Half-written file: try again on the next update.
                return
            }
            loadedURL = url
            loadedStamp = stamp
            view.document = document

            if let place, let pageIndex, pageIndex < document.pageCount, let page = document.page(at: pageIndex) {
                view.go(to: PDFDestination(page: page, at: place.point))
            }
            DispatchQueue.main.async { [weak self] in self?.reportPage() }
        }

        // MARK: Source -> PDF

        func runForward(_ request: PDFForwardRequest, in view: SyncPDFView) {
            guard let parent, let tool = parent.synctex else { return }
            let client = SyncTeXClient(executable: tool, pdfURL: parent.url, draftFolder: parent.draftFolder)
            Task { @MainActor [weak view] in
                let rects = await client.forward(file: request.file, line: request.line, column: request.column)
                guard let view, let first = rects.first,
                      let document = view.document, first.page >= 1, first.page <= document.pageCount,
                      let page = document.page(at: first.page - 1) else { return }

                let height = page.bounds(for: .mediaBox).height
                let box = SyncTeX.pdfKitRect(for: first, pageHeight: height)
                view.go(to: PDFDestination(page: page, at: CGPoint(x: max(0, box.minX - 20), y: box.maxY + 60)))
                Self.flash(box, on: page, in: view)
            }
        }

        /// A yellow highlight that fades away after a moment.
        @MainActor private static func flash(_ box: CGRect, on page: PDFPage, in view: PDFView) {
            let pad = box.insetBy(dx: -2, dy: -2)
            let mark = PDFAnnotation(bounds: pad, forType: .highlight, withProperties: nil)
            mark.color = NSColor.systemYellow.withAlphaComponent(0.5)
            page.addAnnotation(mark)
            view.setNeedsDisplay(view.bounds)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak page, weak view] in
                page?.removeAnnotation(mark)
                view?.setNeedsDisplay(view?.bounds ?? .zero)
            }
        }

        // MARK: PDF -> source

        private func runReverse(page: PDFPage, point: CGPoint) {
            guard let parent, let tool = parent.synctex, let document = page.document,
                  let onJump = parent.onJump else { return }
            let client = SyncTeXClient(executable: tool, pdfURL: parent.url, draftFolder: parent.draftFolder)
            let index = document.index(for: page) + 1
            let height = page.bounds(for: .mediaBox).height
            Task { @MainActor in
                if let source = await client.reverse(page: index, x: Double(point.x), y: Double(height - point.y)) {
                    onJump(source)
                }
            }
        }
    }
}
