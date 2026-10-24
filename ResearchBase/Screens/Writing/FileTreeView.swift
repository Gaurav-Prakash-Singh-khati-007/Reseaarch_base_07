//
//  FileTreeView.swift
//  ResearchBase
//
//  Owner: Agent 43 · Features: L-12
//
//  The project file tree of a draft: main.tex, chapters, figures, refs.bib. Add a file or folder,
//  rename, delete (to the Mac's Trash, with a question first), make a .tex file the main file,
//  import files (button or drag-and-drop), show in Finder.
//
//  All work on disk goes through Agent 20's DraftFolderStore. This file never touches the files
//  itself. The caller learns what happened through `onEvent` (open the file in the editor, follow
//  a rename, close a deleted file ...).
//
//  Layers
//    1. `FileTreeLogic`        pure: build the tree, rows, names, icons, path remapping.
//    2. `FileTreeOperations`   the actions, on top of DraftFolderStore. Testable with a real store.
//    3. `FileTreeView`         the SwiftUI view.
//
//  PUBLIC API
//    struct FileTreeNode               path, name, isFolder, size, children
//    struct FileTreeRow                node, depth
//    enum   FileTreeEvent              opened(path) added(path) renamed(from:to:) deleted(path)
//                                      mainFileChanged(path) imported([path])
//    enum   FileTreeError              invalidName(String)
//    enum   FileTreeLogic
//        build(_ files: [StoredDraftFile]) -> [FileTreeNode]
//        rows(_ nodes:, collapsed: Set<String>) -> [FileTreeRow]
//        validateName(_:) -> String?            nil = fine, else the reason
//        parent(of:) -> String                  "" at the top
//        join(_ folder:, _ name:) -> String
//        remap(_ path:, from:, to:) -> String   follows a rename (also for files inside a folder)
//        iconName(for:) / isEditableText(_:) / canBeMainFile(_:) / importFolder(forFileNamed:)
//    struct FileTreeOperations         init(store: DraftFolderStore, draftID: String)
//        addFile(named:inFolder:) throws -> String
//        addFolder(named:inFolder:) throws -> String
//        rename(path:to:) throws -> String
//        delete(path:) throws
//        setMainFile(path:) throws
//        importFiles(_:intoFolder:) throws -> [String]
//    struct FileTreeView: View
//        init(store: DraftFolderStore, draftID: String, selection: Binding<String?>,
//             reloadToken: Int = 0, onEvent: ((FileTreeEvent) -> Void)? = nil)
//          Change `reloadToken` after something else changed the folder (for example a build or a
//          file written by the editor) to refresh the list.
//
//  Reads (only): DraftFolderStore (Agent 20), StoredDraft / StoredDraftFile, ModelError, RBColor.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Types

struct FileTreeNode: Identifiable, Equatable {
    let path: String
    let name: String
    let isFolder: Bool
    let size: Int
    let children: [FileTreeNode]
    var id: String { path }
}

struct FileTreeRow: Identifiable, Equatable {
    let node: FileTreeNode
    let depth: Int
    var id: String { node.path }
}

enum FileTreeEvent: Equatable {
    case opened(String)
    case added(String)
    case renamed(from: String, to: String)
    case deleted(String)
    case mainFileChanged(String)
    case imported([String])
}

enum FileTreeError: LocalizedError, Equatable {
    case invalidName(String)
    var errorDescription: String? {
        switch self {
        case .invalidName(let reason): return reason
        }
    }
}

// MARK: - Logic (pure)

enum FileTreeLogic {

    static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// Folders first, then files; each group by name the way Finder sorts ("fig2" before "fig10").
    static func build(_ files: [StoredDraftFile]) -> [FileTreeNode] {
        var items: [String: StoredDraftFile] = [:]
        var folders = Set<String>()
        for file in files {
            items[file.path] = file
            if file.isFolder { folders.insert(file.path) }
            var up = parent(of: file.path)
            while !up.isEmpty { folders.insert(up); up = parent(of: up) }
        }
        var childrenOf: [String: [String]] = [:]
        for path in Set(items.keys).union(folders) {
            childrenOf[parent(of: path), default: []].append(path)
        }

        func ordered(_ paths: [String]) -> [String] {
            paths.sorted { a, b in
                let aFolder = folders.contains(a), bFolder = folders.contains(b)
                if aFolder != bFolder { return aFolder }
                let an = (a as NSString).lastPathComponent, bn = (b as NSString).lastPathComponent
                return an.localizedStandardCompare(bn) == .orderedAscending
            }
        }
        func make(_ path: String) -> FileTreeNode {
            FileTreeNode(
                path: path,
                name: (path as NSString).lastPathComponent,
                isFolder: folders.contains(path),
                size: items[path]?.size ?? 0,
                children: ordered(childrenOf[path] ?? []).map(make)
            )
        }
        return ordered(childrenOf[""] ?? []).map(make)
    }

    /// The visible lines. Folders listed in `collapsed` hide their contents.
    static func rows(_ nodes: [FileTreeNode], collapsed: Set<String> = []) -> [FileTreeRow] {
        var out: [FileTreeRow] = []
        func walk(_ list: [FileTreeNode], depth: Int) {
            for node in list {
                out.append(FileTreeRow(node: node, depth: depth))
                if node.isFolder, !collapsed.contains(node.path) { walk(node.children, depth: depth + 1) }
            }
        }
        walk(nodes, depth: 0)
        return out
    }

    /// nil = the name is fine. Otherwise the reason, in words for the person.
    static func validateName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "Type a name." }
        if clean == "." || clean == ".." { return "That name is not allowed." }
        if clean.hasPrefix(".") { return "Names cannot start with a dot (such files are hidden)." }
        if clean.contains("/") || clean.contains(":") || clean.contains("\\") {
            return "Names cannot contain / : or \\."
        }
        if clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "That name has characters that are not allowed."
        }
        if clean.count > 120 { return "That name is too long." }
        return nil
    }

    /// If `path` is `from` or inside it, the same place after `from` became `to`.
    static func remap(_ path: String, from: String, to: String) -> String {
        if path == from { return to }
        if path.hasPrefix(from + "/") { return to + String(path.dropFirst(from.count)) }
        return path
    }

    private static let textExtensions: Set<String> =
        ["tex", "bib", "sty", "cls", "bst", "txt", "md", "cfg", "bbx", "cbx", "def", "ltx", "latex", "clo", "dtx"]
    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "svg", "eps", "tif", "tiff", "pdf", "webp", "heic"]

    static func isEditableText(_ path: String) -> Bool {
        textExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func canBeMainFile(_ path: String) -> Bool {
        ["tex", "ltx", "latex"].contains((path as NSString).pathExtension.lowercased())
    }

    static func iconName(for node: FileTreeNode) -> String {
        if node.isFolder { return "folder" }
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "tex", "ltx", "latex": return "doc.text"
        case "bib": return "books.vertical"
        case "pdf": return "doc.richtext"
        case "sty", "cls", "bst", "bbx", "cbx", "def", "clo", "dtx": return "puzzlepiece"
        case _ where imageExtensions.contains(ext): return "photo"
        default: return "doc"
        }
    }

    /// Where a dropped or imported file goes: pictures and PDFs to figures/, everything else to the top.
    static func importFolder(forFileNamed name: String) -> String {
        imageExtensions.contains((name as NSString).pathExtension.lowercased()) ? "figures" : ""
    }
}

// MARK: - Operations

struct FileTreeOperations {

    let store: DraftFolderStore
    let draftID: String

    init(store: DraftFolderStore, draftID: String) {
        self.store = store
        self.draftID = draftID
    }

    private func checked(_ name: String) throws -> String {
        if let reason = FileTreeLogic.validateName(name) { throw FileTreeError.invalidName(reason) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new empty file. A name without an extension becomes ".tex". Returns the path.
    @discardableResult
    func addFile(named name: String, inFolder folder: String) throws -> String {
        var clean = try checked(name)
        if (clean as NSString).pathExtension.isEmpty { clean += ".tex" }
        return try store.addFile(draftID: draftID, path: FileTreeLogic.join(folder, clean))
    }

    @discardableResult
    func addFolder(named name: String, inFolder folder: String) throws -> String {
        let clean = try checked(name)
        let path = FileTreeLogic.join(folder, clean)
        try store.createFolder(draftID: draftID, path: path)
        return path
    }

    /// Renames inside the same folder. A file keeps its extension when the new name has none.
    /// The main file follows (DraftFolderStore does that). Returns the new path.
    @discardableResult
    func rename(path: String, to newName: String) throws -> String {
        var clean = try checked(newName)
        let oldName = (path as NSString).lastPathComponent
        let oldExt = (oldName as NSString).pathExtension
        let isFolder = isFolderOnDisk(path)
        if !isFolder, (clean as NSString).pathExtension.isEmpty, !oldExt.isEmpty { clean += "." + oldExt }
        let target = FileTreeLogic.join(FileTreeLogic.parent(of: path), clean)
        guard target != path else { return path }
        try store.renameFile(draftID: draftID, from: path, to: target)
        return target
    }

    /// Goes to the Mac's Trash (unless the store was told otherwise). The main file is refused by the store.
    func delete(path: String) throws {
        try store.deleteFile(draftID: draftID, path: path)
    }

    func setMainFile(path: String) throws {
        try store.setMainFile(id: draftID, to: path)
    }

    /// Copies files in. `intoFolder` nil = pictures and PDFs to figures/, the rest to the top.
    /// A file that already exists stops the import with the store's message; earlier ones stay.
    @discardableResult
    func importFiles(_ urls: [URL], intoFolder: String? = nil) throws -> [String] {
        var added: [String] = []
        for url in urls {
            let folder = intoFolder ?? FileTreeLogic.importFolder(forFileNamed: url.lastPathComponent)
            added.append(try store.importFile(draftID: draftID, from: url, toFolder: folder))
        }
        return added
    }

    private func isFolderOnDisk(_ path: String) -> Bool {
        ((try? store.files(in: draftID)) ?? []).first { $0.path == path }?.isFolder ?? false
    }
}

// MARK: - View

private struct NamePrompt: Identifiable {
    enum Kind { case newFile(folder: String), newFolder(folder: String), rename(path: String) }
    let id = UUID()
    let kind: Kind
    let title: String
    let initial: String
    let button: String
}

struct FileTreeView: View {

    let store: DraftFolderStore
    let draftID: String
    @Binding var selection: String?
    var reloadToken: Int
    var onEvent: ((FileTreeEvent) -> Void)?

    @State private var nodes: [FileTreeNode] = []
    @State private var mainFile = ""
    @State private var collapsed = Set<String>()
    @State private var prompt: NamePrompt?
    @State private var pendingDelete: String?
    @State private var errorMessage: String?
    @State private var dropTargeted = false

    init(
        store: DraftFolderStore,
        draftID: String,
        selection: Binding<String?>,
        reloadToken: Int = 0,
        onEvent: ((FileTreeEvent) -> Void)? = nil
    ) {
        self.store = store
        self.draftID = draftID
        self._selection = selection
        self.reloadToken = reloadToken
        self.onEvent = onEvent
    }

    private var operations: FileTreeOperations { FileTreeOperations(store: store, draftID: draftID) }
    private var rows: [FileTreeRow] { FileTreeLogic.rows(nodes, collapsed: collapsed) }

    /// New files go into the selected folder, or next to the selected file.
    private var targetFolder: String {
        guard let selection else { return "" }
        if let row = rows.first(where: { $0.node.path == selection }), row.node.isFolder { return selection }
        return FileTreeLogic.parent(of: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                Text("This draft has no files yet.")
                    .font(.callout).foregroundStyle(RBColor.mutedText).padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in rowView(row) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(RBColor.surface)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(RBColor.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(2).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .task(id: "\(draftID)#\(reloadToken)") { reload() }
        .sheet(item: $prompt) { p in
            NamePromptSheet(prompt: p) { text in apply(p, text) }
        }
        .alert("Delete “\(((pendingDelete ?? "") as NSString).lastPathComponent)”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) { if let path = pendingDelete { delete(path) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It moves to the Trash, so you can put it back from there.")
        }
        .alert("That did not work", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Text("Files").font(.callout.weight(.semibold)).foregroundStyle(RBColor.primaryText)
            Spacer()
            Menu {
                Button("New file…") { prompt = NamePrompt(kind: .newFile(folder: targetFolder), title: "New file", initial: "untitled.tex", button: "Create") }
                Button("New folder…") { prompt = NamePrompt(kind: .newFolder(folder: targetFolder), title: "New folder", initial: "folder", button: "Create") }
                Divider()
                Button("Import files…") { importWithPanel() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a file or folder")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func rowView(_ row: FileTreeRow) -> some View {
        let node = row.node
        let isSelected = selection == node.path
        return HStack(spacing: 4) {
            if node.isFolder {
                Image(systemName: collapsed.contains(node.path) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: FileTreeLogic.iconName(for: node))
                .foregroundStyle(node.isFolder ? RBColor.accent : RBColor.secondaryText)
                .frame(width: 16)
            Text(node.name)
                .font(.callout)
                .foregroundStyle(RBColor.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.path == mainFile {
                Text("main")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(RBColor.onAccent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RBColor.accent, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(isSelected ? RBColor.selected : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { tap(node) }
        .contextMenu { contextMenu(for: node) }
    }

    @ViewBuilder
    private func contextMenu(for node: FileTreeNode) -> some View {
        let folder = node.isFolder ? node.path : FileTreeLogic.parent(of: node.path)
        Button("New file here…") { prompt = NamePrompt(kind: .newFile(folder: folder), title: "New file", initial: "untitled.tex", button: "Create") }
        Button("New folder here…") { prompt = NamePrompt(kind: .newFolder(folder: folder), title: "New folder", initial: "folder", button: "Create") }
        Divider()
        Button("Rename…") { prompt = NamePrompt(kind: .rename(path: node.path), title: "Rename", initial: node.name, button: "Rename") }
        if !node.isFolder, FileTreeLogic.canBeMainFile(node.path), node.path != mainFile {
            Button("Set as main file") { run { try operations.setMainFile(path: node.path); mainFile = node.path; onEvent?(.mainFileChanged(node.path)) } }
        }
        Button("Show in Finder") { revealInFinder(node.path) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = node.path }
            .disabled(node.path == mainFile || mainFile.hasPrefix(node.path + "/"))
    }

    // MARK: Actions

    private func tap(_ node: FileTreeNode) {
        selection = node.path
        if node.isFolder {
            if collapsed.contains(node.path) { collapsed.remove(node.path) } else { collapsed.insert(node.path) }
        } else if FileTreeLogic.isEditableText(node.path) {
            onEvent?(.opened(node.path))
        }
    }

    private func run(_ work: () throws -> Void) {
        do { try work() } catch { errorMessage = error.localizedDescription }
        reload()
    }

    private func apply(_ prompt: NamePrompt, _ text: String) {
        run {
            switch prompt.kind {
            case .newFile(let folder):
                let path = try operations.addFile(named: text, inFolder: folder)
                collapsed.remove(folder)
                selection = path
                onEvent?(.added(path))
                if FileTreeLogic.isEditableText(path) { onEvent?(.opened(path)) }
            case .newFolder(let folder):
                let path = try operations.addFolder(named: text, inFolder: folder)
                collapsed.remove(folder)
                selection = path
                onEvent?(.added(path))
            case .rename(let path):
                let new = try operations.rename(path: path, to: text)
                guard new != path else { return }
                if let current = selection { selection = FileTreeLogic.remap(current, from: path, to: new) }
                collapsed = Set(collapsed.map { FileTreeLogic.remap($0, from: path, to: new) })
                onEvent?(.renamed(from: path, to: new))
            }
        }
    }

    private func delete(_ path: String) {
        run {
            try operations.delete(path: path)
            if let current = selection, current == path || current.hasPrefix(path + "/") { selection = nil }
            onEvent?(.deleted(path))
        }
    }

    private func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose files to copy into this draft. Pictures and PDFs go to figures/."
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        run {
            let added = try operations.importFiles(urls)
            if !added.isEmpty { onEvent?(.imported(added)) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let wanted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !wanted.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in wanted {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { importURLs(urls) }
        return true
    }

    private func revealInFinder(_ path: String) {
        guard let draft = try? store.draft(id: draftID) else { return }
        let url = store.folderURL(for: draft).appendingPathComponent(path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func reload() {
        do {
            nodes = FileTreeLogic.build(try store.files(in: draftID))
            mainFile = (try store.draft(id: draftID))?.mainFile ?? ""
        } catch {
            nodes = []
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Name prompt

private struct NamePromptSheet: View {
    let prompt: NamePrompt
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(prompt: NamePrompt, onDone: @escaping (String) -> Void) {
        self.prompt = prompt
        self.onDone = onDone
        self._text = State(initialValue: prompt.initial)
    }

    private var problem: String? { FileTreeLogic.validateName(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.title).font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            Text(problem ?? " ").font(.caption).foregroundStyle(RBColor.error).frame(height: 14)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(prompt.button, action: commit).keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func commit() {
        guard problem == nil else { return }
        let value = text
        dismiss()
        onDone(value)
    }
}
