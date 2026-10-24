//
//  TemplateManagerView.swift
//  ResearchBase
//
//  Owner: Agent 44 · Features: L-11 (template manager with versions), F-32
//
//  The template manager: every writing template with all of its saved
//  versions, so an old paper rebuilds the same way later. It reads and
//  writes only through `TemplateStore` (Agent 19) and changes no draft.
//
//  What it does
//    * lists each template (by name) and, when opened, every version of it
//      (newest first) with how many writing projects started from it
//    * "New template": add a template from a folder (a .tex file and any
//      .cls / .bst files); the folder is scanned to pre-fill the fields
//    * "Add new version": save a changed template as a NEW version. Saved
//      versions never change, so old papers keep rebuilding the same way
//    * "Needs class file" switch per version (the store's setNeedsClassFile)
//    * "Remove" a version; refused while a writing project still uses it
//    * if the list is empty, "Add the six built-in templates"
//
//  PUBLIC API
//    TemplateManagerLogic            nextVersion, documentClass(in:), keyFrom, needsClassFile, scan(folder:), loadGroups(from:)
//    TemplateManagerView(store:inUseKey:inUseVersion:onClose:onChanged:)
//      store          the TemplateStore to read and write
//      inUseKey       optional: the template key of the open draft (marks "In use")
//      inUseVersion   optional: the version of the open draft
//      onClose        optional: when given, a Close button is shown and calls it
//      onChanged      called after any change (add, new version, switch, remove)
//
//  Notes
//    * Files are never copied or deleted here. `bundlePath` is stored as the
//      folder the user chose (the store keeps it as given).
//    * A new version needs a new version number; the next one is suggested.
//

import SwiftUI
import AppKit

// MARK: - Small value types used only by this screen

struct TemplateManagerVersion: Identifiable {
    let template: StoredTemplate
    let drafts: Int
    var id: String { template.rowID }
}

struct TemplateManagerGroup: Identifiable {
    let key: String
    let name: String
    let versions: [TemplateManagerVersion]   // newest first
    var id: String { key }
}

/// What a scan of a template folder found.
struct TemplateFolderScan: Equatable {
    var name: String
    var key: String
    var documentClass: String?
    var bst: String?
    var hasClassFile: Bool
}

/// The screen's logic, kept apart from the views so it can be tested.
enum TemplateManagerLogic {

    /// 1.0 -> 1.1, 2 -> 3, 1.0-beta -> 1.0-beta.1
    static func nextVersion(after version: String) -> String {
        var parts = version.split(separator: ".").map(String.init)
        if let last = parts.last, let number = Int(last) {
            parts[parts.count - 1] = String(number + 1)
            return parts.joined(separator: ".")
        }
        return version + ".1"
    }

    /// The class name from the first documentclass line, e.g. documentclass[x]{name}.
    static func documentClass(in text: String) -> String? {
        guard let range = text.range(of: "\\\\documentclass(\\[[^\\]]*\\])?\\{[^}]+\\}", options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        guard let open = match.lastIndex(of: "{"), let close = match.lastIndex(of: "}"), open < close else { return nil }
        let value = match[match.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// A key the store accepts: letters, digits, - _ .
    static func keyFrom(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            result += allowed.contains(scalar) ? String(scalar) : "-"
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Classes that every TeX install already has.
    static let standardClasses: Set<String> = ["article", "report", "book", "letter", "beamer"]

    /// A template needs its class file when the folder has no .cls and the class is not a standard one.
    static func needsClassFile(documentClass: String, hasClassFile: Bool) -> Bool {
        !hasClassFile && !standardClasses.contains(documentClass)
    }

    /// Looks into a template folder (one level, nothing is changed).
    static func scan(folder: URL) -> TemplateFolderScan {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()

        let clsFile = names.first { $0.lowercased().hasSuffix(".cls") }
        let bstFile = names.first { $0.lowercased().hasSuffix(".bst") }
        let texFile = names.first { $0.lowercased() == "main.tex" } ?? names.first { $0.lowercased().hasSuffix(".tex") }

        var documentClassName: String?
        if let texFile,
           let text = try? String(contentsOf: folder.appendingPathComponent(texFile), encoding: .utf8) {
            documentClassName = documentClass(in: text)
        }
        if documentClassName == nil, let clsFile {
            documentClassName = (clsFile as NSString).deletingPathExtension
        }

        return TemplateFolderScan(
            name: folder.lastPathComponent,
            key: keyFrom(folder.lastPathComponent),
            documentClass: documentClassName,
            bst: bstFile.map { ($0 as NSString).deletingPathExtension },
            hasClassFile: clsFile != nil
        )
    }

    /// Every template with its versions (newest first) and how many writing projects use each.
    /// Templates are ordered by name, as the store returns them.
    static func loadGroups(from store: TemplateStore) throws -> [TemplateManagerGroup] {
        let all = try store.allVersions()
        var order: [String] = []
        var byKey: [String: [StoredTemplate]] = [:]
        for template in all {
            if byKey[template.key] == nil { order.append(template.key) }
            byKey[template.key, default: []].append(template)
        }

        return try order.map { (key: String) -> TemplateManagerGroup in
            let items = byKey[key] ?? []
            let versions = try items.map { (item: StoredTemplate) -> TemplateManagerVersion in
                return TemplateManagerVersion(
                    template: item,
                    drafts: try store.draftCount(key: item.key, version: item.version)
                )
            }
            return TemplateManagerGroup(key: key, name: items.first?.name ?? key, versions: versions)
        }
    }
}

private enum TemplateEditorMode: Identifiable {
    case newTemplate
    case newVersion(StoredTemplate)

    var id: String {
        switch self {
        case .newTemplate: return "new-template"
        case .newVersion(let template): return "new-version-\(template.key)"
        }
    }
}

// MARK: - Manager

struct TemplateManagerView: View {

    let store: TemplateStore
    var inUseKey: String? = nil
    var inUseVersion: String? = nil
    var onClose: (() -> Void)? = nil
    var onChanged: () -> Void = {}

    @State private var groups: [TemplateManagerGroup] = []
    @State private var expandedKeys: Set<String> = []
    @State private var editor: TemplateEditorMode?
    @State private var removing: StoredTemplate?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    if let errorText {
                        errorBanner(errorText)
                    }

                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            groupCard(group)
                        }
                    }

                    Text("Each writing project keeps the template version it started with, so an old paper rebuilds the same way even after a template is updated. A saved version never changes; save changes as a new version.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(RBColor.background)
        .onAppear { reload() }
        .sheet(item: $editor) { mode in
            TemplateEditorSheet(
                store: store,
                mode: mode,
                onSaved: { key in
                    editor = nil
                    expandedKeys.insert(key)
                    reload()
                    onChanged()
                },
                onCancel: { editor = nil }
            )
        }
        .confirmationDialog(
            removing.map { "Remove version \($0.version) of “\($0.name)”?" } ?? "Remove this version?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove version", role: .destructive) {
                if let target = removing { remove(target) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Only the entry in this list is removed. The files in the template folder are not deleted.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Templates")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text("Versions of every writing template")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            Button("New template") { editor = .newTemplate }
                .buttonStyle(RBPrimaryButtonStyle())

            if let onClose {
                Button("Close") { onClose() }
                    .buttonStyle(RBGhostButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(RBColor.surface)
    }

    // MARK: Empty state

    private var emptyState: some View {
        RBCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("No templates yet")
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text("Add the six templates ResearchBase ships with (arXiv, IEEE, ACM, Springer, Elsevier and thesis), or add your own from a folder.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Add the six built-in templates") { addBuiltIns() }
                        .buttonStyle(RBPrimaryButtonStyle())
                    Button("New template") { editor = .newTemplate }
                        .buttonStyle(RBGhostButtonStyle())
                }
            }
        }
    }

    // MARK: Error banner

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RBColor.warning)
            Text(text)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { errorText = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
            }
            .buttonStyle(RBHoverPlainButtonStyle())
            .help("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.warning.opacity(0.3), lineWidth: 1))
    }

    // MARK: One template (collapsed row + versions)

    private func groupCard(_ group: TemplateManagerGroup) -> some View {
        let isOpen = expandedKeys.contains(group.key)
        let newest = group.versions.first?.template

        return RBCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {

                Button {
                    if isOpen { expandedKeys.remove(group.key) } else { expandedKeys.insert(group.key) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(RBColor.mutedText)
                            .frame(width: 12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(RBFont.body(.semibold))
                                .foregroundStyle(RBColor.primaryText)
                            if let newest {
                                Text("class \(newest.documentClass) · bibliography \(newest.bst.isEmpty ? "—" : newest.bst)")
                                    .font(RBFont.caption().monospaced())
                                    .foregroundStyle(RBColor.mutedText)
                            }
                        }

                        Spacer()

                        if let newest {
                            RBBadge(text: "v\(newest.version)", tone: .neutral)
                            if newest.needsClassFile {
                                RBBadge(text: "Needs class file", tone: .warning)
                            } else {
                                RBBadge(text: "Ready", tone: .ok)
                            }
                        }
                        RBBadge(text: group.versions.count == 1 ? "1 version" : "\(group.versions.count) versions", tone: .muted)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RBHoverPlainButtonStyle())

                if isOpen {
                    Divider().overlay(RBColor.border)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.versions) { info in
                            versionRow(info)
                            Divider().overlay(RBColor.border)
                        }

                        HStack {
                            if let newest {
                                Button("Add new version") { editor = .newVersion(newest) }
                                    .buttonStyle(RBGhostButtonStyle())
                            }
                            Spacer()
                            Text("key \(group.key)")
                                .font(RBFont.caption().monospaced())
                                .foregroundStyle(RBColor.mutedText)
                        }
                        .padding(14)
                    }
                }
            }
        }
    }

    // MARK: One version

    private func versionRow(_ info: TemplateManagerVersion) -> some View {
        let template = info.template
        let isInUse = template.key == inUseKey && template.version == inUseVersion
        let removable = info.drafts == 0

        return HStack(alignment: .center, spacing: 10) {

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Version \(template.version)")
                        .font(RBFont.body(.medium))
                        .foregroundStyle(RBColor.primaryText)
                    if isInUse { RBBadge(text: "In use", tone: .ok) }
                }
                Text(template.bundlePath)
                    .font(RBFont.caption().monospaced())
                    .foregroundStyle(RBColor.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(info.drafts == 0
                     ? "No writing project uses this version"
                     : (info.drafts == 1 ? "1 writing project started from this version" : "\(info.drafts) writing projects started from this version"))
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            Toggle("Needs class file", isOn: Binding(
                get: { template.needsClassFile },
                set: { setNeedsClassFile(template, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(RBFont.caption())

            Button { removing = template } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(removable ? RBColor.error : RBColor.mutedText)
            }
            .buttonStyle(RBHoverPlainButtonStyle())
            .disabled(!removable)
            .help(removable ? "Remove this version" : "Writing projects still use this version, so it cannot be removed")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func reload() {
        do {
            groups = try TemplateManagerLogic.loadGroups(from: store)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func addBuiltIns() {
        do {
            try store.registerBuiltIns()
            errorText = nil
            reload()
            onChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setNeedsClassFile(_ template: StoredTemplate, _ needs: Bool) {
        do {
            try store.setNeedsClassFile(key: template.key, version: template.version, to: needs)
            errorText = nil
            reload()
            onChanged()
        } catch {
            errorText = error.localizedDescription
            reload()
        }
    }

    private func remove(_ template: StoredTemplate) {
        do {
            try store.remove(key: template.key, version: template.version)
            errorText = nil
            reload()
            onChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Add template / add version

private struct TemplateEditorSheet: View {

    let store: TemplateStore
    let mode: TemplateEditorMode
    let onSaved: (String) -> Void     // gets the template key
    let onCancel: () -> Void

    @State private var key = ""
    @State private var name = ""
    @State private var version = "1.0"
    @State private var documentClass = ""
    @State private var bst = ""
    @State private var bundlePath = ""
    @State private var needsClassFile = false
    @State private var errorText: String?

    private var isNewVersion: Bool {
        if case .newVersion = mode { return true }
        return false
    }

    private var canSave: Bool {
        ![key, name, version, documentClass, bundlePath]
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            VStack(alignment: .leading, spacing: 3) {
                Text(isNewVersion ? "Add new version" : "New template")
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text(isNewVersion
                     ? "Saved versions never change. Your changes are saved as a new version, and writing projects keep the version they started with."
                     : "Choose the folder that holds the template's .tex file and any .cls or .bst files.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RBColor.warning)
                    Text(errorText)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.warning.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 10) {
                field("Folder") {
                    HStack {
                        Text(bundlePath.isEmpty ? "No folder chosen" : bundlePath)
                            .font(RBFont.caption().monospaced())
                            .foregroundStyle(bundlePath.isEmpty ? RBColor.mutedText : RBColor.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                            .buttonStyle(RBGhostButtonStyle())
                    }
                }

                field("Name") {
                    TextField("For example: MLSys paper", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                field("Key") {
                    TextField("Letters, digits, - _ .  (for example mlsys)", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isNewVersion)
                }

                field("Version") {
                    TextField("For example 1.1", text: $version)
                        .textFieldStyle(.roundedBorder)
                }

                field("Document class") {
                    TextField("For example IEEEtran", text: $documentClass)
                        .textFieldStyle(.roundedBorder)
                }

                field("Bibliography style") {
                    TextField("For example IEEEtran (optional)", text: $bst)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Needs class file (the .cls is not part of the TeX install)", isOn: $needsClassFile)
                    .font(RBFont.caption())
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(RBGhostButtonStyle())
                Button(isNewVersion ? "Save new version" : "Save template") { save() }
                    .buttonStyle(RBPrimaryButtonStyle())
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(RBColor.elevatedSurface)
        .onAppear { prefill() }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .frame(width: 120, alignment: .leading)
            content()
        }
    }

    // MARK: Prefill

    private func prefill() {
        guard case .newVersion(let base) = mode else { return }
        key = base.key
        name = base.name
        version = TemplateManagerLogic.nextVersion(after: base.version)
        documentClass = base.documentClass
        bst = base.bst
        bundlePath = base.bundlePath
        needsClassFile = base.needsClassFile
    }

    // MARK: Folder

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder with the template's .tex file and any .cls or .bst files"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        bundlePath = url.path
        scan(folder: url)
    }

    /// Fills in the fields that are still empty from what is in the folder.
    private func scan(folder: URL) {
        let found = TemplateManagerLogic.scan(folder: folder)

        if name.isEmpty { name = found.name }
        if key.isEmpty && !isNewVersion { key = found.key }
        if bst.isEmpty, let value = found.bst { bst = value }
        if documentClass.isEmpty, let value = found.documentClass { documentClass = value }

        needsClassFile = TemplateManagerLogic.needsClassFile(documentClass: documentClass, hasClassFile: found.hasClassFile)
    }

    // MARK: Save

    private func save() {
        do {
            let saved = try store.register(
                key: key, name: name, version: version, documentClass: documentClass,
                needsClassFile: needsClassFile, bundlePath: bundlePath, bst: bst
            )
            onSaved(saved.key)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
