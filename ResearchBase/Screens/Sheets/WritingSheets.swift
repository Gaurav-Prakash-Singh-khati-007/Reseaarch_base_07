//
//  WritingSheets.swift
//  ResearchBase
//
//  Source of truth: docs/researchbase.html (F-29, F-32, F-35, F-36, F-37, F-39, F-40, L-07, L-08, L-11)
//  Sheets for the Writing workspace: Templates, Build Settings, Insert from Experiment,
//  Diff, History, Comments, Export, Import, and New Writing Project.
//
//  Owner: Agent 63 · Features: F-32 / L-11 (templates), L-07 / L-08 (build settings),
//                              F-36 (history and diff), F-37 (comments and TODOs)
//
//  PUBLIC API (new or changed in this pass)
//    TemplatesSheet(currentTemplateID:onDismiss:onSelectTemplate:model:draftID:currentVersion:)
//        real list from TemplateStore (Agent 19); "Manage templates…" opens TemplateManagerView (Agent 44).
//        With `model` and `draftID` it saves a "Before changing template" snapshot (Agent 21)
//        BEFORE it calls onSelectTemplate(key). The sheet does not change main.tex itself.
//    BuildSettingsSheet(onDismiss:draftFolder:)
//        real settings of LatexCompiler (Agent 24), kept app-wide in LatexCompiler.Settings.stored.
//    DraftDiffSheet(onDismiss:onRestore:model:snapshotID:filePath:)
//        real comparison of one snapshot with the current file; "Restore this version" restores
//        (DraftHistoryStore) and THEN calls onRestore() so the caller can reload.
//    DraftHistorySheet(model:draftID:filePath:onRestored:onDismiss:)            new
//        snapshot list, save now, rename, compare, restore, delete.
//    DraftCommentsSheet(model:draftID:currentFile:currentLine:currentFileText:onGoTo:onChanged:onDismiss:)   new
//        comments and TODOs of a draft: add, edit, resolve, delete, find "% TODO" markers.
//    Unchanged: InsertFromExperimentSheet, ExportDraftSheet, ImportDraftSheet, NewWritingProjectSheet.
//
//  Not here, on purpose
//    - Bibliography engine and "Build on save": LatexCompiler has no such setting. Rebuilding after
//      you stop typing belongs to the Writing screen (Agent 65), so no switch is shown here.
//    - The sheets never edit main.tex, move comments or swap templates. They report the choice to the caller.
//

import SwiftUI

// MARK: - Shared helpers (Agent 63, private to this file)

private struct RBA63SheetHeader: View {
    let title: String
    var closeDisabled: Bool = false
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(RBFont.detail(.bold))
                .foregroundStyle(RBColor.primaryText)
                .lineLimit(1)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
                    .padding(6)
                    .background(Circle().fill(RBColor.hover))
            }
            .buttonStyle(RBHoverPlainButtonStyle())
            .disabled(closeDisabled)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

private struct RBA63Notice: View {
    enum Tone { case warning, error, success }
    let text: String
    var tone: Tone = .warning

    private var color: Color {
        switch tone {
        case .warning: return RBColor.warning
        case .error:   return RBColor.error
        case .success: return RBColor.success
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3), lineWidth: 1))
    }
}

private enum RBA63Dates {
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    static func display(_ text: String) -> String {
        parse(text)?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
}

private struct RBA63DiffRow: Identifiable {
    enum Kind { case same, added, removed, gap }
    let id: Int
    let kind: Kind
    let text: String
}

private enum RBA63Diff {

    /// Number of changed lines (added + removed).
    static func changedCount(_ lines: [StoredDiffLine]) -> Int {
        lines.reduce(0) { $0 + ($1.kind == .same ? 0 : 1) }
    }

    /// Only changed lines and `context` lines around them; long unchanged stretches become one gap row.
    static func collapse(_ lines: [StoredDiffLine], context: Int = 2) -> [RBA63DiffRow] {
        var keep = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.kind != .same {
            let from = max(0, index - context)
            let to = min(lines.count - 1, index + context)
            for i in from...to { keep[i] = true }
        }

        var rows: [RBA63DiffRow] = []
        var skipped = 0
        for (index, line) in lines.enumerated() {
            if keep[index] {
                if skipped > 0 {
                    rows.append(RBA63DiffRow(id: rows.count, kind: .gap,
                                             text: "\(skipped) unchanged line\(skipped == 1 ? "" : "s")"))
                    skipped = 0
                }
                let kind: RBA63DiffRow.Kind = line.kind == .added ? .added : (line.kind == .removed ? .removed : .same)
                rows.append(RBA63DiffRow(id: rows.count, kind: kind, text: line.text))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            rows.append(RBA63DiffRow(id: rows.count, kind: .gap,
                                     text: "\(skipped) unchanged line\(skipped == 1 ? "" : "s")"))
        }
        return rows
    }
}

private struct RBA63DiffView: View {
    let lines: [StoredDiffLine]

    var body: some View {
        let rows = RBA63Diff.collapse(lines)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    Text(prefix(row) + row.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(background(row))
                        .foregroundStyle(color(row))
                }
            }
            .font(RBFont.secondary().monospaced())
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
    }

    private func prefix(_ row: RBA63DiffRow) -> String {
        switch row.kind {
        case .added:   return "+ "
        case .removed: return "- "
        case .same:    return "  "
        case .gap:     return "… "
        }
    }

    private func background(_ row: RBA63DiffRow) -> Color {
        switch row.kind {
        case .added:   return RBColor.success.opacity(0.18)
        case .removed: return RBColor.error.opacity(0.16)
        default:       return Color.clear
        }
    }

    private func color(_ row: RBA63DiffRow) -> Color {
        switch row.kind {
        case .added:   return RBColor.success
        case .removed: return RBColor.error
        case .gap:     return RBColor.mutedText
        case .same:    return RBColor.primaryText
        }
    }
}

// MARK: - Templates Sheet (F-32, L-11)

@MainActor
struct TemplatesSheet: View {
    let currentTemplateID: String
    let onDismiss: () -> Void
    var onSelectTemplate: (String) -> Void = { _ in }
    var model: LibraryModel? = nil
    /// The open draft. When given (with `model`), a snapshot is saved before the template is chosen.
    var draftID: String? = nil
    /// The template version the open draft started with, if known.
    var currentVersion: String? = nil

    private struct Entry: Identifiable {
        let template: StoredTemplate
        let drafts: Int
        var id: String { template.rowID }
    }

    @State private var entries: [Entry] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var working = false
    @State private var showManager = false

    var body: some View {
        VStack(spacing: 0) {
            RBA63SheetHeader(title: "Templates", closeDisabled: working, onClose: onDismiss)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RBA63Notice(text: draftID != nil && model != nil
                        ? "Changing the template replaces the preamble and front matter of main.tex. Your text stays. A snapshot is saved first so you can go back."
                        : "Changing the template replaces the preamble and front matter of main.tex. Your text stays.")

                    if let errorText { RBA63Notice(text: errorText, tone: .error) }

                    if model == nil {
                        RBA63Notice(text: "The library is not open, so the template list cannot be shown yet.")
                    } else if loaded && entries.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(entries) { entry in card(entry) }
                        }
                    }

                    Text("Each template is versioned. A draft remembers the version it started with, so an old paper rebuilds the same way even after templates are updated.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            HStack {
                Button("Manage templates…") { showManager = true }
                    .buttonStyle(.bordered)
                    .disabled(model == nil)
                Spacer()
                Button("Close") { onDismiss() }.buttonStyle(.bordered).disabled(working)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 760, height: 520)
        .background(RBColor.elevated)
        .onAppear { reload() }
        .sheet(isPresented: $showManager) {
            if let model {
                TemplateManagerView(
                    store: TemplateStore(model: model),
                    inUseKey: currentTemplateID,
                    inUseVersion: currentVersion,
                    onClose: { showManager = false },
                    onChanged: { reload() }
                )
                .frame(width: 800, height: 580)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No templates yet")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)
            Text("Add the six built-in templates, or add your own from a folder with Manage templates.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
            Button("Add the six built-in templates") { addBuiltIns() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func isInUse(_ entry: Entry) -> Bool {
        guard entry.template.key == currentTemplateID else { return false }
        guard let currentVersion else { return true }
        return TemplateStore.compareVersions(currentVersion, entry.template.version) != .orderedAscending
    }

    private func hasNewer(_ entry: Entry) -> Bool {
        guard entry.template.key == currentTemplateID, let currentVersion else { return false }
        return TemplateStore.compareVersions(currentVersion, entry.template.version) == .orderedAscending
    }

    private func card(_ entry: Entry) -> some View {
        let t = entry.template
        let inUse = isInUse(entry)

        return Button {
            choose(entry)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(t.name)
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    if inUse {
                        Text("In use")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.success)
                    } else if hasNewer(entry) {
                        Text("Newer version")
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(RBColor.accent)
                    }
                }

                Text("class \(t.documentClass) · bibliography \(t.bst) · v\(t.version)")
                    .font(RBFont.caption().monospaced())
                    .foregroundStyle(RBColor.mutedText)
                    .lineLimit(2)

                Text(entry.drafts == 0
                     ? "No writing project started from this version yet."
                     : "\(entry.drafts) writing project\(entry.drafts == 1 ? "" : "s") started from this version.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(2)

                Text(t.needsClassFile ? "Needs class file" : "Ready")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(t.needsClassFile ? RBColor.warning : RBColor.success)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((t.needsClassFile ? RBColor.warning : RBColor.success).opacity(0.12)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(inUse ? RBColor.accent : RBColor.border, lineWidth: inUse ? 2 : 1)
            )
        }
        .buttonStyle(RBHoverPlainButtonStyle())
        .disabled(inUse || working)
    }

    private func reload() {
        guard let model else { loaded = true; return }
        let store = TemplateStore(model: model)
        do {
            let latest = try store.latestOfEach()
            entries = latest.map { template in
                Entry(template: template, drafts: (try? store.draftCount(key: template.key, version: template.version)) ?? 0)
            }
            errorText = nil
        } catch {
            errorText = "The templates could not be read: \(error.localizedDescription)"
        }
        loaded = true
    }

    private func addBuiltIns() {
        guard let model else { return }
        do {
            _ = try TemplateStore(model: model).registerBuiltIns()
            reload()
        } catch {
            errorText = "The built-in templates could not be added: \(error.localizedDescription)"
        }
    }

    private func choose(_ entry: Entry) {
        guard !working else { return }
        working = true
        errorText = nil

        if let model, let draftID {
            do {
                _ = try DraftHistoryStore(model: model)
                    .takeSnapshot(draftID: draftID, label: "Before changing template", auto: true)
            } catch {
                errorText = "The safety snapshot could not be saved, so the template was not changed: \(error.localizedDescription)"
                working = false
                return
            }
        }

        onSelectTemplate(entry.template.key)
        working = false
        onDismiss()
    }
}

// MARK: - Build Settings Sheet (L-07, L-08)

@MainActor
struct BuildSettingsSheet: View {
    let onDismiss: () -> Void
    /// The open draft's folder, used by "Clean build files". nil disables that button.
    var draftFolder: URL? = nil

    @State private var settings = LatexCompiler.Settings.stored
    @State private var installation: LatexCompiler.Installation?
    @State private var confirmShellEscape = false
    @State private var cleanMessage: String?
    @State private var errorText: String?

    private var timeoutChoices: [Double] {
        var choices = LatexCompiler.Settings.timeoutChoices
        if !choices.contains(settings.timeoutSeconds) { choices.append(settings.timeoutSeconds) }
        return choices.sorted()
    }

    private var shellEscapeBinding: Binding<Bool> {
        Binding(
            get: { settings.shellEscape },
            set: { newValue in
                if newValue { confirmShellEscape = true } else { settings.shellEscape = false }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            RBA63SheetHeader(title: "Build settings", onClose: onDismiss)

            ScrollView {
                VStack(spacing: 12) {
                    if let errorText { RBA63Notice(text: errorText, tone: .error) }

                    HStack(alignment: .firstTextBaseline) {
                        label("TeX installation")
                        installationView
                        Spacer()
                    }

                    HStack {
                        label("Engine")
                        Picker("", selection: $settings.engine) {
                            ForEach(LatexCompiler.Engine.allCases) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer()
                    }

                    if let warning = engineWarning {
                        RBA63Notice(text: warning)
                    }

                    HStack {
                        label("Clean build")
                        Toggle("Wipe the build folder before every build", isOn: $settings.cleanBuild)
                            .font(RBFont.body())
                        Spacer()
                    }

                    HStack {
                        label("Check first")
                        Toggle("Check disk space and the main file before building", isOn: $settings.runPreflight)
                            .font(RBFont.body())
                        Spacer()
                    }

                    HStack {
                        label("Shell escape")
                        HStack(spacing: 8) {
                            Toggle("Allow external commands", isOn: shellEscapeBinding)
                                .font(RBFont.body())
                            Text("Off is safer")
                                .font(RBFont.caption(.medium))
                                .foregroundStyle(RBColor.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(RBColor.warning.opacity(0.12)))
                        }
                        Spacer()
                    }

                    HStack {
                        label("Timeout")
                        Picker("", selection: $settings.timeoutSeconds) {
                            ForEach(timeoutChoices, id: \.self) { seconds in
                                Text("\(Int(seconds)) seconds").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        Spacer()
                    }

                    HStack {
                        label("Output folder")
                        Text("drafts/<draft>/\(settings.effectiveOutputFolder)/")
                            .font(RBFont.caption().monospaced())
                            .foregroundStyle(RBColor.mutedText)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            cleanNow()
                        } label: {
                            Label("Clean build files", systemImage: "trash")
                                .font(RBFont.caption(.medium))
                        }
                        .buttonStyle(.bordered)
                        .disabled(draftFolder == nil)

                        if let cleanMessage {
                            Text(cleanMessage)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        } else if draftFolder == nil {
                            Text("Open a draft to clean its build files.")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)

                    Text("These settings apply to every draft on this Mac and take effect on the next build.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            HStack {
                Spacer()
                Button("Done") { onDismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 580, height: 540)
        .background(RBColor.elevated)
        .onChange(of: settings) { _, newValue in
            LatexCompiler.Settings.stored = newValue
        }
        .task {
            let current = settings
            installation = await Task.detached { LatexCompiler.locateInstallation(settings: current) }.value
        }
        .confirmationDialog("Allow external commands?", isPresented: $confirmShellEscape) {
            Button("Allow", role: .destructive) { settings.shellEscape = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A document can then run programs on your Mac while it builds. Only turn this on for documents you trust.")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
            .frame(width: 140, alignment: .leading)
    }

    @ViewBuilder
    private var installationView: some View {
        if let installation {
            if installation.hasSystemTeX {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RBColor.success)
                    Text("TeX found").font(RBFont.caption(.medium)).foregroundStyle(RBColor.success)
                    if let folder = installation.texFolder {
                        Text(folder.path).font(RBFont.caption().monospaced()).foregroundStyle(RBColor.mutedText)
                    }
                }
            } else if installation.hasBundledEngine {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RBColor.success)
                    Text(installation.summary).font(RBFont.caption(.medium)).foregroundStyle(RBColor.success)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(RBColor.error)
                    Text(installation.summary).font(RBFont.caption(.medium)).foregroundStyle(RBColor.error)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Looking for TeX…").font(RBFont.caption()).foregroundStyle(RBColor.mutedText)
            }
        }
    }

    private var engineWarning: String? {
        guard let installation else { return nil }
        if settings.engine == .tectonic {
            return installation.hasBundledEngine ? nil : "The bundled engine (Tectonic) was not found on this Mac."
        }
        if !installation.hasSystemTeX {
            return installation.hasBundledEngine && settings.allowBundledFallback
                ? "No TeX installation was found, so builds will use the bundled engine instead."
                : "No TeX installation was found. Install MacTeX or BasicTeX, then build again."
        }
        return nil
    }

    private func cleanNow() {
        guard let draftFolder else { return }
        do {
            let removed = try LatexCompiler.cleanBuildFiles(draftFolder: draftFolder, settings: settings, includingPDF: false)
            cleanMessage = removed == 0 ? "No build files to remove." : "Removed \(removed) build file\(removed == 1 ? "" : "s")."
            errorText = nil
        } catch {
            errorText = "The build files could not be removed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Insert from Experiment Sheet (F-35)

struct InsertFromExperimentSheet: View {
    let onDismiss: () -> Void
    var onInsert: (String) -> Void = { _ in }
    
    @State private var selectedKind: String = "table"
    @State private var experimentName = "Drift under Dirichlet splits"
    
    private var generatedLaTeX: String {
        if selectedKind == "table" {
            return """
            % Generated by ResearchBase from experiment "Drift under Dirichlet splits".
            \\begin{table}[t]
              \\centering
              \\caption{Test accuracy (\\%), mean $\\pm$ standard deviation over seeds.}
              \\label{tab:e1}
              \\begin{tabular}{lcc}
                \\toprule
                Method & Test accuracy (\\%) & Seeds \\\\
                \\midrule
                FedAvg & 84.7 $\\pm$ 0.6 & 5 \\\\
                FedProx & 86.1 $\\pm$ 0.5 & 5 \\\\
                SCAFFOLD & \\textbf{88.3} $\\pm$ 0.5 & 5 \\\\
                \\bottomrule
              \\end{tabular}
            \\end{table}
            """
        } else {
            return """
            % Generated by ResearchBase from experiment "Drift under Dirichlet splits".
            \\begin{figure}[t]
              \\centering
              \\includegraphics[width=0.8\\linewidth]{figures/e1_accuracy.pdf}
              \\caption{Test accuracy over communication rounds for FedAvg, FedProx, SCAFFOLD.}
              \\label{fig:e1}
            \\end{figure}
            """
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Insert from experiment")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Picker("", selection: $experimentName) {
                        Text("Drift under Dirichlet splits").tag("Drift under Dirichlet splits")
                        Text("Pathological two-class split").tag("Pathological two-class split")
                        Text("Learning-rate sweep").tag("Learning-rate sweep")
                    }
                    .pickerStyle(.menu)
                    
                    Picker("", selection: $selectedKind) {
                        Text("Results table").tag("table")
                        Text("Accuracy figure").tag("figure")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    
                    Spacer()
                    Text("Numbers come from runs. Nothing is retyped.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
                
                // Code box
                ScrollView {
                    Text(generatedLaTeX)
                        .font(RBFont.secondary().monospaced())
                        .foregroundStyle(RBColor.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
                
                Text(selectedKind == "figure" ? "Exports figures/e1_accuracy.pdf into the draft folder at the same time." : "Best value is bold. Re-insert after more runs to refresh the table. The generated block is marked with a comment so it can be found and replaced.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
                Button {
                    onInsert(generatedLaTeX)
                    onDismiss()
                } label: {
                    Label("Insert at cursor", systemImage: "pencil")
                        .font(RBFont.secondary(.medium))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 720, height: 460)
        .background(RBColor.elevated)
    }
}

// MARK: - Draft Diff Sheet (F-36)

@MainActor
struct DraftDiffSheet: View {
    let onDismiss: () -> Void
    /// Called AFTER the restore succeeded (when `model` and `snapshotID` are given), so the caller can reload.
    var onRestore: () -> Void = {}
    var model: LibraryModel? = nil
    var snapshotID: String? = nil
    /// File inside the draft to compare. nil = the draft's main file.
    var filePath: String? = nil

    @State private var snapshot: StoredDraftSnapshot?
    @State private var lines: [StoredDiffLine] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var confirmRestore = false
    @State private var working = false

    private var changed: Int { RBA63Diff.changedCount(lines) }
    private var snapshotName: String {
        guard let snapshot else { return "an earlier version" }
        return snapshot.label.isEmpty ? "Automatic snapshot" : snapshot.label
    }

    var body: some View {
        VStack(spacing: 0) {
            RBA63SheetHeader(title: "Compare with “\(snapshotName)”", closeDisabled: working, onClose: onDismiss)

            VStack(alignment: .leading, spacing: 10) {
                if let errorText { RBA63Notice(text: errorText, tone: .error) }

                if model == nil || snapshotID == nil {
                    RBA63Notice(text: "No version was chosen to compare with.")
                } else if loaded {
                    if let snapshot {
                        Text(changed == 0
                             ? "\(RBA63Dates.display(snapshot.createdAt)) → now · no differences. Red was removed, green was added."
                             : "\(RBA63Dates.display(snapshot.createdAt)) → now · \(changed) changed line\(changed == 1 ? "" : "s"). Red was removed, green was added.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    }
                    if changed == 0 {
                        Text("This version and the current text are the same.")
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.mutedText)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        RBA63DiffView(lines: lines)
                            .frame(height: 280)
                    }
                }
            }
            .padding(20)

            Divider().overlay(RBColor.border)

            HStack {
                Spacer()
                Button("Close") { onDismiss() }.buttonStyle(.bordered).disabled(working)
                Button {
                    confirmRestore = true
                } label: {
                    Label("Restore this version", systemImage: "clock.arrow.circlepath")
                        .font(RBFont.secondary(.medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(model == nil || snapshotID == nil || working)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 720, height: 460)
        .background(RBColor.elevated)
        .onAppear { load() }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The draft folder goes back to this version. A snapshot of the current version is saved first.")
        }
    }

    private func load() {
        guard let model, let snapshotID else { loaded = true; return }
        let store = DraftHistoryStore(model: model)
        do {
            snapshot = try store.snapshot(id: snapshotID)
            lines = try store.diff(snapshotID: snapshotID, path: filePath)
            errorText = nil
        } catch {
            errorText = "The comparison could not be made: \(error.localizedDescription)"
        }
        loaded = true
    }

    private func restore() {
        guard let model, let snapshotID, !working else { return }
        working = true
        do {
            _ = try DraftHistoryStore(model: model).restore(snapshotID: snapshotID)
            working = false
            onRestore()
            onDismiss()
        } catch {
            errorText = "The version could not be restored: \(error.localizedDescription)"
            working = false
        }
    }
}

// MARK: - Draft History Sheet (F-36)

@MainActor
struct DraftHistorySheet: View {
    let model: LibraryModel?
    let draftID: String
    /// File inside the draft to compare. nil = the draft's main file.
    var filePath: String? = nil
    /// Called after a restore succeeded, so the caller can reload the draft's files.
    var onRestored: () -> Void = {}
    let onDismiss: () -> Void

    @State private var snapshots: [StoredDraftSnapshot] = []
    @State private var selectedID: String?
    @State private var lines: [StoredDiffLine] = []
    @State private var newLabel = ""
    @State private var renameText = ""
    @State private var loaded = false
    @State private var working = false
    @State private var errorText: String?
    @State private var noticeText: String?
    @State private var confirmRestore = false
    @State private var confirmDelete = false

    private var selected: StoredDraftSnapshot? { snapshots.first { $0.id == selectedID } }
    private var changed: Int { RBA63Diff.changedCount(lines) }

    private func name(_ snapshot: StoredDraftSnapshot) -> String {
        snapshot.label.isEmpty ? "Automatic" : snapshot.label
    }

    var body: some View {
        VStack(spacing: 0) {
            RBA63SheetHeader(title: "History", closeDisabled: working, onClose: onDismiss)

            VStack(alignment: .leading, spacing: 8) {
                if model == nil {
                    RBA63Notice(text: "The library is not open, so the history cannot be shown yet.")
                }
                if let errorText { RBA63Notice(text: errorText, tone: .error) }
                if let noticeText { RBA63Notice(text: noticeText, tone: .success) }
            }
            .padding(.horizontal, 20)

            HStack(alignment: .top, spacing: 16) {
                listColumn.frame(width: 260)
                detailColumn.frame(maxWidth: .infinity)
            }
            .padding(20)

            Divider().overlay(RBColor.border)

            HStack {
                Text("A snapshot is a copy of the whole draft folder. Restoring first saves the current version.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                Spacer()
                Button("Close") { onDismiss() }.buttonStyle(.bordered).disabled(working)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 880, height: 600)
        .background(RBColor.elevated)
        .onAppear { reload(select: nil) }
        .onChange(of: selectedID) { _, _ in loadDiff() }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The draft folder goes back to this version. A snapshot of the current version is saved first.")
        }
        .confirmationDialog("Delete this snapshot?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saved copy is removed. The draft itself is not changed.")
        }
    }

    // MARK: Pieces

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Label (optional)", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                Button("Save now") { saveNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model == nil || working)
            }

            if loaded && snapshots.isEmpty {
                Text("No snapshots yet. Save one before a risky change, or wait for the automatic ones.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .padding(.top, 8)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(snapshots) { snapshot in
                        Button {
                            selectedID = snapshot.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(snapshot))
                                    .font(RBFont.body(.semibold))
                                    .foregroundStyle(RBColor.primaryText)
                                    .lineLimit(1)
                                Text(RBA63Dates.display(snapshot.createdAt))
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                                Text("\(snapshot.words) words" + (snapshot.auto ? " · automatic" : ""))
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(snapshot.id == selectedID ? RBColor.accent.opacity(0.15) : RBColor.card)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(snapshot.id == selectedID ? RBColor.accent : RBColor.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(RBHoverPlainButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    TextField("Label", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                    Button("Rename") { rename() }
                        .disabled(working || renameText.trimmingCharacters(in: .whitespaces).isEmpty || renameText == selected.label)
                }

                Text(changed == 0
                     ? "\(RBA63Dates.display(selected.createdAt)) → now · no differences."
                     : "\(RBA63Dates.display(selected.createdAt)) → now · \(changed) changed line\(changed == 1 ? "" : "s"). Red was removed, green was added.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)

                if changed == 0 {
                    Text("This version and the current text are the same.")
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.mutedText)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    RBA63DiffView(lines: lines)
                        .frame(minHeight: 260, maxHeight: .infinity)
                }

                HStack {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(working)
                    Spacer()
                    Button {
                        confirmRestore = true
                    } label: {
                        Label("Restore this version", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                }
            }
        } else {
            Text(snapshots.isEmpty ? "" : "Choose a snapshot on the left to compare it with the current text.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.mutedText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func reload(select id: String?) {
        guard let model else { loaded = true; return }
        do {
            snapshots = try DraftHistoryStore(model: model).snapshots(forDraft: draftID)
            if let id, snapshots.contains(where: { $0.id == id }) {
                selectedID = id
            } else if selectedID == nil || !snapshots.contains(where: { $0.id == selectedID }) {
                selectedID = snapshots.first?.id
            }
            errorText = nil
        } catch {
            errorText = "The history could not be read: \(error.localizedDescription)"
        }
        loaded = true
        loadDiff()
    }

    private func loadDiff() {
        guard let model, let selected else { lines = []; renameText = ""; return }
        renameText = selected.label
        do {
            lines = try DraftHistoryStore(model: model).diff(snapshotID: selected.id, path: filePath)
        } catch {
            lines = []
            errorText = "The comparison could not be made: \(error.localizedDescription)"
        }
    }

    private func saveNow() {
        guard let model, !working else { return }
        working = true
        errorText = nil
        noticeText = nil
        let text = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let made = try DraftHistoryStore(model: model)
                .takeSnapshot(draftID: draftID, label: text.isEmpty ? "Saved by me" : text, auto: false)
            newLabel = ""
            noticeText = "Snapshot saved."
            reload(select: made.id)
        } catch {
            errorText = "The snapshot could not be saved: \(error.localizedDescription)"
        }
        working = false
    }

    private func rename() {
        guard let model, let selected, !working else { return }
        do {
            let updated = try DraftHistoryStore(model: model)
                .setLabel(snapshotID: selected.id, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines))
            noticeText = nil
            reload(select: updated.id)
        } catch {
            errorText = "The label could not be changed: \(error.localizedDescription)"
        }
    }

    private func restore() {
        guard let model, let selected, !working else { return }
        working = true
        errorText = nil
        do {
            _ = try DraftHistoryStore(model: model).restore(snapshotID: selected.id)
            noticeText = "Restored “\(name(selected))”. The version you had before was saved as a snapshot."
            reload(select: nil)
            onRestored()
        } catch {
            errorText = "The version could not be restored: \(error.localizedDescription)"
        }
        working = false
    }

    private func deleteSelected() {
        guard let model, let selected, !working else { return }
        working = true
        do {
            try DraftHistoryStore(model: model).remove(snapshotID: selected.id)
            noticeText = "Snapshot deleted."
            selectedID = nil
            reload(select: nil)
        } catch {
            errorText = "The snapshot could not be deleted: \(error.localizedDescription)"
        }
        working = false
    }
}

// MARK: - Draft Comments Sheet (F-37)

@MainActor
struct DraftCommentsSheet: View {
    let model: LibraryModel?
    let draftID: String
    /// The file open in the editor; new comments go here by default.
    var currentFile: String = "main.tex"
    /// The line the cursor is on; pre-fills the line number of a new comment.
    var currentLine: Int = 1
    /// Text of the open file. When given, "Find TODO markers" can add its `% TODO` lines.
    var currentFileText: String? = nil
    /// Jump to a comment in the editor.
    var onGoTo: ((_ file: String, _ line: Int) -> Void)? = nil
    var onChanged: () -> Void = {}
    let onDismiss: () -> Void

    private enum StateFilter: String, CaseIterable, Identifiable {
        case open = "Open", resolved = "Resolved", all = "All"
        var id: String { rawValue }
    }

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All kinds", comment = "Comments", todo = "TODOs"
        var id: String { rawValue }
    }

    @State private var items: [DraftComment] = []
    @State private var counts = DraftCommentCounts()
    @State private var stateFilter: StateFilter = .open
    @State private var kindFilter: KindFilter = .all
    @State private var newKind: DraftCommentKind = .comment
    @State private var newFile = ""
    @State private var newLine = ""
    @State private var newBody = ""
    @State private var editingID: String?
    @State private var editText = ""
    @State private var loaded = false
    @State private var errorText: String?
    @State private var noticeText: String?
    @State private var confirmClear = false

    private var visible: [DraftComment] {
        items.filter { item in
            switch stateFilter {
            case .open:     if item.resolved { return false }
            case .resolved: if !item.resolved { return false }
            case .all:      break
            }
            switch kindFilter {
            case .all:     return true
            case .comment: return item.kind == .comment
            case .todo:    return item.kind == .todo
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RBA63SheetHeader(title: "Comments and TODOs", onClose: onDismiss)

            VStack(alignment: .leading, spacing: 10) {
                if model == nil {
                    RBA63Notice(text: "The library is not open, so comments cannot be shown yet.")
                }
                if let errorText { RBA63Notice(text: errorText, tone: .error) }
                if let noticeText { RBA63Notice(text: noticeText, tone: .success) }

                Text("\(counts.openComments) open comment\(counts.openComments == 1 ? "" : "s"), \(counts.openTodos) open TODO\(counts.openTodos == 1 ? "" : "s"), \(counts.resolved) resolved")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)

                HStack {
                    Picker("", selection: $stateFilter) {
                        ForEach(StateFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)

                    Picker("", selection: $kindFilter) {
                        ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)

                    Spacer()

                    if currentFileText != nil {
                        Button("Find TODO markers") { findMarkers() }
                            .disabled(model == nil)
                    }
                    Button("Clear resolved") { confirmClear = true }
                        .disabled(model == nil || counts.resolved == 0)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        if loaded && visible.isEmpty {
                            Text(stateFilter == .open ? "Nothing open. Add a comment below." : "Nothing to show.")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                                .frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(visible) { item in row(item) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(20)

            Divider().overlay(RBColor.border)
            addForm
        }
        .frame(width: 680, height: 640)
        .background(RBColor.elevated)
        .onAppear {
            newFile = currentFile
            newLine = String(max(currentLine, 1))
            reload()
        }
        .confirmationDialog("Remove all resolved items?", isPresented: $confirmClear) {
            Button("Remove", role: .destructive) { clearResolved() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Resolved comments and TODOs of this draft are deleted.")
        }
    }

    // MARK: Pieces

    private func row(_ item: DraftComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.kind == .todo ? "checkmark.square" : "text.bubble")
                    .foregroundStyle(item.resolved ? RBColor.mutedText : RBColor.accent)

                if let onGoTo {
                    Button("\(item.file):\(item.line)") { onGoTo(item.file, item.line) }
                        .buttonStyle(.link)
                        .font(RBFont.caption().monospaced())
                } else {
                    Text("\(item.file):\(item.line)")
                        .font(RBFont.caption().monospaced())
                        .foregroundStyle(RBColor.mutedText)
                }

                Text(item.kind == .todo ? "TODO" : "Comment")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.secondaryText)

                if item.resolved {
                    Text("Resolved")
                        .font(RBFont.caption(.medium))
                        .foregroundStyle(RBColor.success)
                }
                Spacer()
                Text(RBA63Dates.display(item.createdAt))
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }

            if !item.anchorText.isEmpty {
                Text("“\(item.anchorText)”")
                    .font(RBFont.caption().monospaced())
                    .foregroundStyle(RBColor.mutedText)
                    .lineLimit(2)
            }

            if editingID == item.id {
                TextField("Comment", text: $editText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { saveEdit(item) }
                        .buttonStyle(.borderedProminent)
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editingID = nil }
                }
            } else {
                Text(item.body)
                    .font(RBFont.body())
                    .foregroundStyle(item.resolved ? RBColor.mutedText : RBColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(item.resolved ? "Reopen" : "Resolve") { toggle(item) }
                    Button("Edit") { editingID = item.id; editText = item.body }
                    Button("Delete", role: .destructive) { delete(item) }
                    Spacer()
                }
                .buttonStyle(.link)
                .font(RBFont.caption(.medium))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $newKind) {
                    Text("Comment").tag(DraftCommentKind.comment)
                    Text("TODO").tag(DraftCommentKind.todo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                TextField("File", text: $newFile)
                    .textFieldStyle(.roundedBorder)
                    .font(RBFont.caption().monospaced())
                TextField("Line", text: $newLine)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
            }

            HStack(spacing: 8) {
                TextField(newKind == .todo ? "What is left to do?" : "Write a comment", text: $newBody, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model == nil || newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RBColor.surface)
    }

    // MARK: Actions

    private func reload() {
        guard let model else { loaded = true; return }
        let store = DraftCommentStore(model: model)
        do {
            items = try store.comments(draftID: draftID, file: nil, kind: nil, includeResolved: true)
            counts = try store.counts(draftID: draftID)
            errorText = nil
        } catch {
            errorText = "The comments could not be read: \(error.localizedDescription)"
        }
        loaded = true
    }

    private func perform(_ work: (DraftCommentStore) throws -> Void, success: String? = nil) {
        guard let model else { return }
        do {
            try work(DraftCommentStore(model: model))
            errorText = nil
            noticeText = success
            reload()
            onChanged()
        } catch {
            noticeText = nil
            errorText = error.localizedDescription
        }
    }

    private func add() {
        let file = newFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = Int(newLine.trimmingCharacters(in: .whitespaces)), line >= 1 else {
            errorText = "The line number must be 1 or more."
            return
        }
        guard !file.isEmpty else {
            errorText = "Say which file the comment belongs to."
            return
        }
        let body = newBody
        let kind = newKind
        perform({ store in
            _ = try store.add(draftID: draftID, file: file, line: line, anchorText: "", kind: kind, body: body)
        }, success: kind == .todo ? "TODO added." : "Comment added.")
        if errorText == nil { newBody = "" }
    }

    private func toggle(_ item: DraftComment) {
        perform { store in _ = try store.setResolved(id: item.id, !item.resolved) }
    }

    private func saveEdit(_ item: DraftComment) {
        let text = editText
        perform { store in _ = try store.edit(id: item.id, body: text) }
        if errorText == nil { editingID = nil }
    }

    private func delete(_ item: DraftComment) {
        perform({ store in try store.remove(id: item.id) }, success: "Deleted.")
    }

    private func clearResolved() {
        perform({ store in _ = try store.removeResolved(draftID: draftID) }, success: "Resolved items removed.")
    }

    private func findMarkers() {
        guard let text = currentFileText else { return }
        let file = currentFile
        guard let model else { return }
        do {
            let added = try DraftCommentStore(model: model).addMissingTodoMarkers(draftID: draftID, file: file, text: text)
            errorText = nil
            noticeText = added.isEmpty
                ? "No new TODO markers found in \(file)."
                : "Added \(added.count) TODO marker\(added.count == 1 ? "" : "s") from \(file)."
            reload()
            onChanged()
        } catch {
            noticeText = nil
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Export Draft Sheet (F-40)

struct ExportDraftSheet: View {
    let onDismiss: () -> Void
    var onExport: (String) -> Void = { _ in }
    
    private let formats = [
        ("archivebox", "LaTeX project (.zip)", "main.tex, refs.bib, figures. Opens in Overleaf, arXiv upload, journal systems."),
        ("doc.text", "PDF", "The last successful build."),
        ("doc.richtext", "Word (.docx)", "Uses the citation style chosen for this draft (CSL). Equations become Word equations."),
        ("number", "Markdown", "Citations become [@key]."),
        ("character", "Plain text", "Text only, no formatting.")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            VStack(spacing: 10) {
                ForEach(formats, id: \.1) { item in
                    Button {
                        onExport(item.1)
                        onDismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.0)
                                .font(.system(size: 18))
                                .foregroundStyle(RBColor.accent)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.1)
                                    .font(RBFont.body(.semibold))
                                    .foregroundStyle(RBColor.primaryText)
                                Text(item.2)
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RBColor.border, lineWidth: 1))
                    }
                    .buttonStyle(RBHoverPlainButtonStyle())
                }
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Close") { onDismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 520, height: 420)
        .background(RBColor.elevated)
    }
}

// MARK: - Import Draft Sheet (F-40)

struct ImportDraftSheet: View {
    let onDismiss: () -> Void
    var onImport: () -> Void = {}
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import a draft")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            VStack(spacing: 14) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(RBColor.accent)
                    Text("Drop a .tex file, a .zip project or a .docx")
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(RBColor.card))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(RBColor.border)
                )
                
                Text("A .zip keeps its folder layout. A .docx is converted to LaTeX; headings, lists, tables and equations carry over, and anything that cannot be converted is listed for you to check.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(RBColor.success)
                    Text("Citations like \\cite{key} are matched to your library by key, then by DOI and title.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.primaryText)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
                Button {
                    onImport()
                    onDismiss()
                } label: {
                    Text("Import")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 520, height: 380)
        .background(RBColor.elevated)
    }
}

// MARK: - New Writing Project Sheet (F-29, F-32, F-39)

struct NewWritingProjectSheet: View {
    let onDismiss: () -> Void
    var onCreate: (String, String) -> Void = { _, _ in }
    
    @State private var title = ""
    @State private var kind = "Paper"
    @State private var template = "arXiv / plain article"
    @State private var citationStyle = "Match the template"
    @State private var project = "Drift study"
    @State private var engine = "latexmk + pdflatex"
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New writing project")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            VStack(spacing: 12) {
                HStack {
                    Text("Title").font(RBFont.caption()).foregroundStyle(RBColor.mutedText).frame(width: 100, alignment: .leading)
                    TextField("Working title", text: $title)
                        .textFieldStyle(.plain)
                        .font(RBFont.body())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
                }
                
                HStack {
                    Text("Kind").font(RBFont.caption()).foregroundStyle(RBColor.mutedText).frame(width: 100, alignment: .leading)
                    Picker("", selection: $kind) {
                        Text("Paper").tag("Paper")
                        Text("Thesis").tag("Thesis")
                        Text("Report").tag("Report")
                    }
                    .pickerStyle(.segmented)
                    Spacer()
                }
                
                HStack {
                    Text("Template").font(RBFont.caption()).foregroundStyle(RBColor.mutedText).frame(width: 100, alignment: .leading)
                    Picker("", selection: $template) {
                        Text("arXiv / plain article").tag("arXiv / plain article")
                        Text("IEEE conference").tag("IEEE conference")
                        Text("ACM (sigconf)").tag("ACM (sigconf)")
                        Text("University thesis").tag("University thesis")
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                
                HStack {
                    Text("Citation style").font(RBFont.caption()).foregroundStyle(RBColor.mutedText).frame(width: 100, alignment: .leading)
                    Picker("", selection: $citationStyle) {
                        Text("Match the template").tag("Match the template")
                        Text("APA 7th edition").tag("APA 7th edition")
                        Text("IEEE").tag("IEEE")
                        Text("ACM Reference Format").tag("ACM Reference Format")
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                
                HStack {
                    Text("Engine").font(RBFont.caption()).foregroundStyle(RBColor.mutedText).frame(width: 100, alignment: .leading)
                    Picker("", selection: $engine) {
                        Text("latexmk + pdflatex (system TeX found)").tag("latexmk + pdflatex")
                        Text("latexmk + xelatex").tag("latexmk + xelatex")
                        Text("Bundled Tectonic").tag("Bundled Tectonic")
                    }
                    .pickerStyle(.menu)
                    Spacer()
                }
                
                Text("Creates drafts/<name>/main.tex, an empty figures/ folder and a generated refs.bib.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.top, 4)
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
                Button {
                    let draftTitle = title.isEmpty ? "Untitled paper" : title
                    onCreate(draftTitle, kind)
                    onDismiss()
                } label: {
                    Text("Create")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 580, height: 420)
        .background(RBColor.elevated)
    }
}
