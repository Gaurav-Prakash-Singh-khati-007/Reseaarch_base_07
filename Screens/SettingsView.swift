//
//  SettingsView.swift
//  ResearchBase
//
//  Owner: Agent 75 · Features: F-49, F-50, F-51, F-56, X-04, F-48, F-55
//
//  PUBLIC API
//    SettingsView                         the Settings screen (unchanged signature)
//    EnvironmentValues.rbA75Library: LibraryModel?
//        NEW. The open library. Batch 4 may set `.environment(\.rbA75Library, model)`;
//        `rbA74Library` / `rbA65Library` are accepted too, so any one of the three is enough.
//    EnvironmentValues.rbA75BackupScheduler: BackupScheduler?
//        NEW. The app's one BackupScheduler (Batch 4 creates it and starts it). While nil, the
//        two backup cards say so and the other new cards still work.
//    RBA75Text, RBA75Secrets              pure helpers behind the new cards (end of this file)
//    RBA75EraseLogic                      the typed word for "Erase everything" (tested)
//
//  Data card: "Erase everything and start fresh". The user types ERASE, then the card calls
//  ResetService.scheduleEraseAndRelaunch() (D6, file ResetService.swift by Agent 80). The erase
//  itself runs at the next launch, before the library opens. This file needs ResetService.swift
//  to exist to build. It also uses ResetService.eraseSummary (static String) from D6.
//  Appearance: the theme picker lists every RBThemeID case and wraps onto several lines, so
//  the additive themes from D5 appear without any change here.
//
//  New cards (all hidden or explained while no library is open; Keys needs no library):
//    Library and storage   X-04   folder, size bar, chips, free space, Reveal in Finder
//    Automatic backups     F-49   status, schedule, second copy, Back Up Now
//    Export everything     F-50   open-format copy, monthly reminder
//    Practice restore      F-51   restore a backup into a scratch folder and check it
//    Library health        F-48 / F-55   integrity check, self-test, recovery info
//    Keys and tokens       F-56   optional API keys, stored in the macOS Keychain only
//
//  Phase 13E — Settings
//
//  The one screen that reaches the Phase 13 data-safety services:
//
//    Appearance       theme picker (AppearanceSettings)
//    Backup           WorkspaceBackupService.createBackup
//    Export           WorkspaceExportService (5 formats)
//    Import           WorkspaceImportService  (adds, never replaces)
//    Restore          WorkspaceRestoreService (replaces, with a
//                     safety backup and a typed confirmation)
//    Safety backups   the automatic backups Restore makes
//
//  Rules this screen follows:
//  - It holds NO SwiftData records, only plain values (previews,
//    results, text). A restore deletes every record, and this is the
//    screen ContentView switches to while that happens.
//  - Only one operation runs at a time. Every button is disabled while
//    one is running.
//  - Nothing is reported as done unless the service returned success.
//    Every warning a service returns is shown, not hidden.
//  - Import and Restore always show a preview first. Restore also
//    needs the word RESTORE typed before its button works.
//  - It observes AppearanceSettings, so it repaints when a restore
//    applies the saved theme. ContentView does not rebuild this
//    screen on a theme change, so a restore result stays visible.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

// MARK: - Small value types

private enum SettingsSection: Hashable {
    case backup
    case export
    case importing
    case restore
}

private enum SettingsBusy: Equatable {

    case backingUp
    case exporting
    case readingImport
    case importing
    case readingRestore
    case restoring
    case libraryBackup
    case exportingEverything
    case practiceRestore
    case integrityCheck
    case selfTest

    var label: String {
        switch self {
        case .backingUp: return "Creating and verifying the backup…"
        case .exporting: return "Exporting…"
        case .readingImport: return "Reading and verifying the backup…"
        case .importing: return "Importing…"
        case .readingRestore: return "Reading and verifying the backup…"
        case .restoring: return "Restoring. Please do not quit ResearchBase…"
        case .libraryBackup: return "Backing up the library and checking the copy…"
        case .exportingEverything: return "Exporting everything in open formats…"
        case .practiceRestore: return "Practising a restore in a scratch folder. Your library is not touched…"
        case .integrityCheck: return "Checking the library…"
        case .selfTest: return "Running the self-test…"
        }
    }
}

/// What to show after an operation. Plain text only.
private struct SettingsOutcome {

    var succeeded: Bool
    var title: String
    var details: [String] = []
    var notes: [String] = []

    static func success(
        _ title: String,
        details: [String] = [],
        notes: [String] = []
    ) -> SettingsOutcome {
        SettingsOutcome(succeeded: true, title: title, details: details, notes: notes)
    }

    static func failure(_ message: String) -> SettingsOutcome {
        SettingsOutcome(succeeded: false, title: message)
    }
}

private struct SafetyBackupItem: Identifiable {

    let url: URL
    let date: Date?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

// MARK: - File panels

@MainActor
private enum SettingsPanels {

    static func chooseSaveLocation(
        suggestedName: String,
        fileExtension: String,
        message: String
    ) -> URL? {

        let panel = NSSavePanel()
        panel.message = message
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK else { return nil }

        return panel.url
    }

    /// A `.researchbase` package is a folder.
    static func choosePackage(message: String) -> URL? {

        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK else { return nil }

        return panel.url
    }
}

// MARK: - View

struct SettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.rbA75Library) private var rbA75Library
    @Environment(\.rbA74Library) private var rbA74Library
    @Environment(\.rbA65Library) private var rbA65Library
    @Environment(\.rbA75BackupScheduler) private var rbA75Scheduler

    private var rbA75Model: LibraryModel? { rbA75Library ?? rbA74Library ?? rbA65Library }

    /// Observed so the screen repaints when the theme changes.
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var pendingTextScale: Double = RBTextScale.current

    
    @EnvironmentObject private var profile: ProfileStore

    @State private var busy: SettingsBusy?
    @State private var outcomes: [SettingsSection: SettingsOutcome] = [:]

    @State private var exportFormat: WorkspaceExportFormat = .workspacePackage

    @State private var importPreview: WorkspaceImportPreview?

    @State private var restorePreview: WorkspaceRestorePreview?
    @State private var restoreConfirmation = ""

    @State private var safetyBackups: [SafetyBackupItem] = []
    @State private var safetyBackupError: String?

    private let restorePhrase = "RESTORE"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                header

                if let busy {
                    busyBanner(busy)
                }

                appearanceCard
                backupCard
                exportCard
                importCard
                restoreCard
                safetyBackupsCard

                RBA75Cards(
                    model: rbA75Model,
                    scheduler: rbA75Scheduler,
                    context: modelContext,
                    busy: $busy
                )

                RBA75EraseCard(isBusy: busy != nil)
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rbResponsiveContentPadding()
        }
        // Rebuilds only the content below this view (not this view's
        // own @State), so colors refresh on a theme change while a
        // running operation's result is kept.
        .id(appearance.refreshToken)
        .onAppear { refreshSafetyBackups() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(RBFont.title(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("Appearance, backups and moving your research safely.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)
        }
    }

    private func busyBanner(_ operation: SettingsBusy) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            Text(operation.label)
                .font(RBFont.body(.medium))
                .foregroundStyle(RBColor.primaryText)

            Spacer()
        }
        .padding(12)
        .background(RBColor.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.control)
                .stroke(RBColor.border)
        )
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        SettingsCard(
            title: "Appearance",
            systemImage: "paintpalette",
            subtitle: "Choose how ResearchBase looks. The choice is remembered."
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(RBThemeID.allCases) { theme in
                    RBChip(
                        text: theme.displayName,
                        isSelected: appearance.themeBinding.wrappedValue == theme
                    ) {
                        appearance.themeBinding.wrappedValue = theme
                    }
                }
            }
            .disabled(busy != nil)

            Divider().overlay(RBColor.border)

            fontControls
        }
    }

    // MARK: Appearance: font

    /// Typeface and text size. Size is applied when the slider is
    /// released (a rebuild while dragging would be far too heavy).
    @ViewBuilder
    private var fontControls: some View {

        VStack(alignment: .leading, spacing: 10) {

            RBSectionLabel(text: "Font")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(RBFontFamily.allCases) { family in
                    RBChip(
                        text: family.displayName,
                        isSelected: appearance.fontFamily == family
                    ) {
                        appearance.commitFontFamily(family)
                    }
                }
            }
        }
        .disabled(busy != nil)

        VStack(alignment: .leading, spacing: 8) {

            HStack {
                RBSectionLabel(text: "Text size")
                Spacer()
                Text("\(Int((pendingTextScale * 100).rounded()))%")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.secondaryText)

                Button("Reset") {
                    pendingTextScale = RBTextScale.default
                    appearance.resetTextScale()
                }
                .buttonStyle(RBGhostButtonStyle())
            }

            Slider(
                value: $pendingTextScale,
                in: RBTextScale.range
            ) { editing in
                if !editing { appearance.commitTextScale(pendingTextScale) }
            }

            // Live sample at the size being dragged, in the chosen family.
            RBCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attention Is All You Need")
                        .font(appearance.fontFamily.font(size: 15 * pendingTextScale, weight: .semibold))
                        .foregroundStyle(RBColor.primaryText)
                    Text("Vaswani et al. · NeurIPS 2017 · The quick brown fox 0123456789")
                        .font(appearance.fontFamily.font(size: 12 * pendingTextScale, weight: .regular))
                        .foregroundStyle(RBColor.secondaryText)
                }
            }
        }
        .disabled(busy != nil)
    }

    // MARK: Backup

    private var backupCard: some View {
        SettingsCard(
            title: "Backup",
            systemImage: "externaldrive",
            subtitle: "Save every record and every PDF into one .researchbase folder. The backup is read back and checked before it is reported as done."
        ) {
            Button("Create Backup…") { runBackup() }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(busy != nil)

            outcomeView(.backup)
        }
    }

    private func runBackup() {

        guard busy == nil else { return }

        guard let destination = SettingsPanels.chooseSaveLocation(
            suggestedName: WorkspaceBackupService.suggestedFileName(),
            fileExtension: WorkspaceFormat.packageExtension,
            message: "Choose where to save the backup."
        ) else { return }

        perform(.backingUp, .backup) {

            let result = try await WorkspaceBackupService.createBackup(
                context: modelContext,
                to: destination,
                profile: profile
            )

            let total = result.manifest.entityCounts.values.reduce(0, +)

            var notes: [String] = []

            let missing = result.papersWithMissingPDF

            if !missing.isEmpty {
                notes.append(
                    "The PDF file could not be found for \(missing.count) paper(s), so no PDF was saved for: \(missing.prefix(5).joined(separator: ", "))\(missing.count > 5 ? " and more" : "")."
                )
            }

            return .success(
                "Backup created and verified.",
                details: [
                    "\(total) records and \(result.pdfCount) PDF files",
                    "Size: \(byteText(result.totalBytes))",
                    "Saved to: \(result.packageURL.path)"
                ],
                notes: notes
            )
        }
    }

    // MARK: Export

    private var exportCard: some View {
        SettingsCard(
            title: "Export",
            systemImage: "square.and.arrow.up",
            subtitle: "Write your research out as a file another tool can read."
        ) {
            Picker("Format", selection: $exportFormat) {
                ForEach(WorkspaceExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            Text(exportFormat.detail)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.mutedText)

            Button("Export…") { runExport() }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(busy != nil)

            outcomeView(.export)
        }
    }

    private func runExport() {

        guard busy == nil else { return }

        let format = exportFormat

        guard let destination = SettingsPanels.chooseSaveLocation(
            suggestedName: WorkspaceExportService.suggestedFileName(for: format),
            fileExtension: format.fileExtension,
            message: "Choose where to save the export."
        ) else { return }

        perform(.exporting, .export) {

            let result = try await WorkspaceExportService.export(
                format: format,
                context: modelContext,
                to: destination,
                profile: profile
            )
            return .success(
                "Exported \(result.format.title).",
                details: [
                    result.summary,
                    "Size: \(byteText(result.byteCount))",
                    "Saved to: \(result.url.path)"
                ],
                notes: result.warnings
            )
        }
    }

    // MARK: Import

    private var importCard: some View {
        SettingsCard(
            title: "Import",
            systemImage: "square.and.arrow.down",
            subtitle: "Add the contents of a backup to your current workspace. Nothing is replaced or deleted, and records you already have are kept exactly as they are."
        ) {
            if let preview = importPreview {
                importPreviewView(preview)
            } else {
                Button("Choose Backup to Import…") { chooseImport() }
                    .buttonStyle(RBPrimaryButtonStyle())
                    .disabled(busy != nil)
            }

            outcomeView(.importing)
        }
    }

    private func importPreviewView(_ preview: WorkspaceImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("Backup made \(dateText(preview.createdAt)) with ResearchBase \(preview.appVersion).")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            countTable(
                headers: ["Type", "In backup", "New", "Already here"],
                rows: preview.rows.map {
                    [$0.label, "\($0.inPackage)", "\($0.newCount)", "\($0.existingCount)"]
                }
            )

            Text("\(preview.newRecordCount) new record(s) will be added. \(preview.existingRecordCount) already in your workspace will be skipped. \(preview.pdfsToCopy) PDF file(s) will be copied.")
                .font(RBFont.secondary(.medium))
                .foregroundStyle(RBColor.primaryText)

            noteList(
                "PDF problems",
                preview.pdfProblems,
                total: preview.pdfProblems.count
            )

            noteList(
                "Links that would be skipped",
                preview.referenceProblems,
                total: preview.referenceProblemCount
            )

            noteList(
                "Things to know",
                preview.warnings,
                total: preview.warnings.count
            )

            SettingsActionRow {

                Button(
                    preview.canImport
                    ? "Import \(preview.newRecordCount) New Record(s)"
                    : "Nothing New to Import"
                ) {
                    runImport(preview)
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(!preview.canImport || busy != nil)

                Button("Cancel") { importPreview = nil }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(busy != nil)
            }
        }
    }

    private func chooseImport() {

        guard busy == nil else { return }

        guard let url = SettingsPanels.choosePackage(
            message: "Choose a .researchbase backup to import."
        ) else { return }

        importPreview = nil

        perform(.readingImport, .importing) {

            importPreview = try await WorkspaceImportService.preview(
                packageAt: url,
                context: modelContext
            )

            return nil
        }
    }

    private func runImport(_ preview: WorkspaceImportPreview) {

        perform(.importing, .importing) {

            // The preview is finished with either way.
            defer { importPreview = nil }

            let result = try await WorkspaceImportService.performImport(
                preview: preview,
                context: modelContext
            )

            var details = [
                result.summary,
                "\(result.relationshipsLinked) link(s) between records were set."
            ]

            for row in result.rows where row.created > 0 || row.skippedExisting > 0 {
                details.append(
                    "\(row.label): \(row.created) added, \(row.skippedExisting) already here"
                )
            }

            var notes: [String] = []

            if result.skippedRelationshipCount > 0 {
                notes.append("\(result.skippedRelationshipCount) link(s) were skipped:")
                notes.append(contentsOf: limited(
                    result.skippedRelationships,
                    total: result.skippedRelationshipCount
                ))
            }

            if result.droppedRecordCount > 0 {
                notes.append("\(result.droppedRecordCount) record(s) were not imported because their owner was missing:")
                notes.append(contentsOf: limited(
                    result.droppedRecords,
                    total: result.droppedRecordCount
                ))
            }

            notes.append(contentsOf: result.warnings)

            return .success("Import finished.", details: details, notes: notes)
        }
    }

    // MARK: Restore

    private var restoreCard: some View {
        SettingsCard(
            title: "Restore",
            systemImage: "arrow.counterclockwise",
            subtitle: "Replace your whole workspace with a backup. Your current workspace is saved as a safety backup first; if that fails, nothing is changed.",
            isWarning: true
        ) {
            if let preview = restorePreview {
                restorePreviewView(preview)
            } else {
                Button("Choose Backup to Restore…") { chooseRestore() }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(busy != nil)
            }

            outcomeView(.restore)
        }
    }

    private func restorePreviewView(_ preview: WorkspaceRestorePreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("Backup made \(dateText(preview.createdAt)) with ResearchBase \(preview.appVersion).")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)

            countTable(
                headers: ["Type", "Now", "In backup"],
                rows: preview.rows.map {
                    [$0.label, "\($0.current)", "\($0.inBackup)"]
                }
            )

            Text("\(preview.currentRecordCount) current record(s) will be replaced by \(preview.backupRecordCount) from the backup. PDF files: \(preview.currentPDFCount) now, \(preview.backupPDFCount) in the backup.")
                .font(RBFont.secondary(.medium))
                .foregroundStyle(RBColor.primaryText)

            if preview.safetyBackupWillBeMade {
                Text("A safety backup of your current workspace will be saved first, in: \(preview.safetyBackupFolder.path)")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
                    .textSelection(.enabled)
            }

            if let theme = preview.themeInBackup {
                Text("The \(theme.displayName) theme saved in the backup will be applied.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
            }

            noteList(
                "PDF problems",
                preview.pdfProblems,
                total: preview.pdfProblems.count
            )

            noteList(
                "Things to know",
                preview.warnings,
                total: preview.warnings.count
            )

            if preview.canRestore {

                Text("Type \(restorePhrase) to confirm.")
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.error)

                TextField(restorePhrase, text: $restoreConfirmation)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .disabled(busy != nil)
            }

            SettingsActionRow {

                Button("Replace My Workspace") { runRestore(preview) }
                    .buttonStyle(.borderedProminent)
                    .tint(RBColor.error)
                    .disabled(!canRunRestore(preview))

                Button("Cancel") {
                    restorePreview = nil
                    restoreConfirmation = ""
                }
                .buttonStyle(RBGhostButtonStyle())
                .disabled(busy != nil)
            }
        }
    }

    private func canRunRestore(_ preview: WorkspaceRestorePreview) -> Bool {

        guard busy == nil, preview.canRestore else { return false }

        let typed = restoreConfirmation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return typed == restorePhrase
    }

    private func chooseRestore() {

        guard busy == nil else { return }

        guard let url = SettingsPanels.choosePackage(
            message: "Choose the .researchbase backup to restore."
        ) else { return }

        restorePreview = nil
        restoreConfirmation = ""

        perform(.readingRestore, .restore) {

            restorePreview = try await WorkspaceRestoreService.preview(
                packageAt: url,
                context: modelContext
            )

            return nil
        }
    }

    private func runRestore(_ preview: WorkspaceRestorePreview) {

        // The typed word is checked again here, not only by the
        // button, so this can never run without it.
        guard canRunRestore(preview) else { return }

        perform(.restoring, .restore) {

            defer {
                restorePreview = nil
                restoreConfirmation = ""
            }

            let result = try await WorkspaceRestoreService.restore(
                preview: preview,
                userConfirmed: true,
                context: modelContext,
                profile: profile
            )

            var details = [result.summary]

            if let theme = result.themeToApply {
                appearance.select(theme)
                details.append("Theme: \(theme.displayName)")
            }

            // Phase 14. Only values present in the backup are applied.
            if let name = result.displayNameToApply {
                profile.setDisplayName(name)
                details.append("Name: \(name)")
            }

            if let scale = result.textScaleToApply {
                appearance.commitTextScale(scale)
            }

            if let hex = result.accentHexToApply {
                appearance.commitAccent(hex: hex)
            }

            if let backup = result.safetyBackupURL {
                details.append("Your previous workspace is saved in: \(backup.path)")
            }

            return .success(
                "Restore finished.",
                details: details,
                notes: result.warnings
            )
        }
    }

    // MARK: Safety backups

    private var safetyBackupsCard: some View {
        SettingsCard(
            title: "Safety Backups",
            systemImage: "lifepreserver",
            subtitle: "Made automatically before every restore. To use one, choose it under Import or Restore. They include all PDFs, so they can be large; move old ones to the Trash when you no longer need them."
        ) {
            if safetyBackups.isEmpty {
                Text("No safety backups yet.")
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(safetyBackups) { item in
                        safetyBackupRow(item)
                    }
                }
            }

            if let message = safetyBackupError {
                Text(message)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.error)
            }

            SettingsActionRow {
                Button("Open Backups Folder") { openBackupsFolder() }
                    .buttonStyle(RBGhostButtonStyle())

                Button("Refresh") { refreshSafetyBackups() }
                    .buttonStyle(RBGhostButtonStyle())
            }
        }
    }

    private func safetyBackupRow(_ item: SafetyBackupItem) -> some View {
        // Wide: name on the left, buttons on the right. Narrow: the
        // buttons drop below the name instead of being clipped.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                safetyBackupInfo(item)
                Spacer(minLength: 10)
                safetyBackupActions(item)
            }

            VStack(alignment: .leading, spacing: 8) {
                safetyBackupInfo(item)
                safetyBackupActions(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RBColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.control))
    }

    private func safetyBackupInfo(_ item: SafetyBackupItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(RBFont.secondary(.medium))
                .foregroundStyle(RBColor.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if let date = item.date {
                Text(dateText(date))
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    private func safetyBackupActions(_ item: SafetyBackupItem) -> some View {
        HStack(spacing: 8) {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            .buttonStyle(RBGhostButtonStyle())

            Button("Move to Trash") { trash(item) }
                .buttonStyle(RBGhostButtonStyle())
                .disabled(busy != nil)
        }
    }

    private func refreshSafetyBackups() {

        let folder = WorkspaceBackupService.automaticBackupsDirectory

        guard FileManager.default.fileExists(atPath: folder.path) else {
            safetyBackups = []
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            let items = urls
                .filter { $0.pathExtension.lowercased() == WorkspaceFormat.packageExtension }
                .map { url -> SafetyBackupItem in
                    let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    )
                    return SafetyBackupItem(
                        url: url,
                        date: values?.contentModificationDate
                    )
                }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

            safetyBackups = items
            safetyBackupError = nil

        } catch {
            safetyBackups = []
            safetyBackupError = "The safety backups could not be listed. \(error.localizedDescription)"
        }
    }

    private func openBackupsFolder() {

        let folder = WorkspaceBackupService.automaticBackupsDirectory

        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        NSWorkspace.shared.open(folder)
    }

    /// Moves to the Trash, so it can still be recovered.
    private func trash(_ item: SafetyBackupItem) {

        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            safetyBackupError = nil
        } catch {
            safetyBackupError = "\"\(item.name)\" could not be moved to the Trash. \(error.localizedDescription)"
        }

        refreshSafetyBackups()
    }

    // MARK: Running operations

    /// Runs one operation at a time. `work` returns what to show, or
    /// nil for a step that shows a preview instead. If it throws, the
    /// error's own description is shown.
    private func perform(
        _ operation: SettingsBusy,
        _ section: SettingsSection,
        work: @escaping @MainActor () async throws -> SettingsOutcome?
    ) {

        guard busy == nil else { return }

        busy = operation
        outcomes[section] = nil

        Task { @MainActor in

            do {
                outcomes[section] = try await work()
            } catch {
                outcomes[section] = .failure(error.localizedDescription)
            }

            busy = nil

            refreshSafetyBackups()
        }
    }

    // MARK: Result display

    @ViewBuilder
    private func outcomeView(_ section: SettingsSection) -> some View {

        if let outcome = outcomes[section] {

            VStack(alignment: .leading, spacing: 8) {

                HStack(alignment: .top, spacing: 8) {

                    Image(
                        systemName: outcome.succeeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(outcome.succeeded ? RBColor.success : RBColor.error)

                    Text(outcome.title)
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                ForEach(Array(outcome.details.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !outcome.notes.isEmpty {

                    VStack(alignment: .leading, spacing: 4) {

                        Text("Please note")
                            .font(RBFont.secondary(.semibold))
                            .foregroundStyle(RBColor.warning)

                        ForEach(Array(outcome.notes.enumerated()), id: \.offset) { _, line in
                            Text("• " + line)
                                .font(RBFont.secondary())
                                .foregroundStyle(RBColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RBColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.control))
        }
    }

    /// A titled list of messages. Shows the first few and says how
    /// many more there are. Hidden when there is nothing to show.
    @ViewBuilder
    private func noteList(
        _ title: String,
        _ items: [String],
        total: Int
    ) -> some View {

        if total > 0 || !items.isEmpty {

            VStack(alignment: .leading, spacing: 3) {

                Text("\(title) (\(max(total, items.count)))")
                    .font(RBFont.secondary(.semibold))
                    .foregroundStyle(RBColor.warning)

                ForEach(
                    Array(limited(items, total: total).enumerated()),
                    id: \.offset
                ) { _, line in
                    Text("• " + line)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func countTable(headers: [String], rows: [[String]]) -> some View {

        Grid(
            alignment: .leadingFirstTextBaseline,
            horizontalSpacing: 20,
            verticalSpacing: 5
        ) {

            GridRow {
                ForEach(headers.indices, id: \.self) { column in
                    Text(headers[column])
                        .font(RBFont.caption(.semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .gridColumnAlignment(column == 0 ? .leading : .trailing)
                }
            }

            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        Text(rows[row][column])
                            .font(RBFont.secondary())
                            .foregroundStyle(
                                column == 0
                                ? RBColor.primaryText
                                : RBColor.secondaryText
                            )
                    }
                }
            }
        }
    }

    // MARK: Text helpers

    /// The first messages, plus "…and N more" when the list is cut.
    private func limited(
        _ items: [String],
        total: Int,
        shown: Int = 5
    ) -> [String] {

        var lines = Array(items.prefix(shown))

        let hidden = max(total, items.count) - lines.count

        if hidden > 0 {
            lines.append("…and \(hidden) more.")
        }

        return lines
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Card

private struct SettingsCard<Content: View>: View {

    let title: String
    let systemImage: String
    let subtitle: String
    let isWarning: Bool
    let content: Content

    init(
        title: String,
        systemImage: String,
        subtitle: String,
        isWarning: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.isWarning = isWarning
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 10) {

                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isWarning ? RBColor.error : RBColor.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                Text(title)
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .accessibilityAddTraits(.isHeader)
            }

            Text(subtitle)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RBColor.card)
        .clipShape(RoundedRectangle(cornerRadius: RBRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: RBRadius.card)
                .stroke(isWarning ? RBColor.error.opacity(0.35) : RBColor.border)
        )
    }
}


// MARK: - Action Row

/// A row of buttons that sits side by side when there is room and
/// stacks vertically when there is not, so nothing is clipped in a
/// narrow window.
private struct SettingsActionRow<Content: View>: View {

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content
            }

            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}


// MARK: - Phase 3 · Agent 75 — storage, backups, practice restore, health, keys
//
//  Owner: Agent 75 · Features: F-49, F-50, F-51, F-56, X-04, F-48, F-55
//
//  Everything below is new and private to this file, apart from the environment keys and the
//  pure helpers (internal, so ResultsView-style tests can reach them). Nothing outside this file
//  was edited. Each card reads its service exactly as Agents 2, 4, 29, 48 and 49 declared it.

// MARK: Environment

struct RBA75LibraryKey: EnvironmentKey {
    static var defaultValue: LibraryModel? { nil }
}

struct RBA75BackupSchedulerKey: EnvironmentKey {
    static var defaultValue: BackupScheduler? { nil }
}

extension EnvironmentValues {
    var rbA75Library: LibraryModel? {
        get { self[RBA75LibraryKey.self] }
        set { self[RBA75LibraryKey.self] = newValue }
    }

    var rbA75BackupScheduler: BackupScheduler? {
        get { self[RBA75BackupSchedulerKey.self] }
        set { self[RBA75BackupSchedulerKey.self] = newValue }
    }
}

// MARK: Pure helpers

enum RBA75Level: Equatable {
    case good, warning, bad, neutral
}

struct RBA75Line: Equatable {
    var text: String
    var level: RBA75Level
}

/// What to show after an action. Plain text only.
struct RBA75Result: Equatable {
    var succeeded: Bool
    var title: String
    var details: [String] = []
}

enum RBA75Text {

    /// "today 14:05", "yesterday 09:30", "12 Oct 2026", or "never".
    static func when(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "never" }

        let time = DateFormatter()
        time.locale = Locale.current
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"

        if calendar.isDate(date, inSameDayAs: now) { return "today \(time.string(from: date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time.string(from: date))"
        }
        let day = DateFormatter()
        day.locale = Locale.current
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "d MMM yyyy"
        return day.string(from: date)
    }

    static func backupLine(_ status: BackupStatus, now: Date = Date(), calendar: Calendar = .current) -> RBA75Line {
        let base = status.statusBarText(now: now, calendar: calendar)
        let detail = status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status.lastResult {
        case .ok:
            return RBA75Line(text: base, level: .good)
        case .warnings:
            return RBA75Line(text: detail.isEmpty ? base + " (with warnings)" : base + ". " + detail, level: .warning)
        case .skipped:
            return RBA75Line(text: detail.isEmpty ? base : base + ". " + detail, level: .warning)
        case .failed:
            return RBA75Line(text: detail.isEmpty ? base : base + ". " + detail, level: .bad)
        case .never:
            return RBA75Line(text: "No backup yet. Use Back Up Now to make the first one.", level: .warning)
        }
    }

    static func secondLocationLine(_ status: BackupStatus) -> RBA75Line {
        guard let path = status.secondLocationPath, !path.isEmpty else {
            return RBA75Line(text: "No second copy. A copy on another disk protects you if this Mac fails.", level: .neutral)
        }
        if status.secondLocationConnected {
            return RBA75Line(text: "Second copy: \(path)", level: .good)
        }
        return RBA75Line(text: "Second copy: \(path) is not connected, so only the copy on this Mac was made.", level: .warning)
    }

    static func integrityLine(_ last: IntegrityLastRun?, now: Date = Date(), calendar: Calendar = .current) -> RBA75Line {
        guard let last, last.at != nil else {
            return RBA75Line(text: "The library has not been checked yet.", level: .neutral)
        }
        let when = Self.when(last.at, now: now, calendar: calendar)
        switch last.result {
        case .ok: return RBA75Line(text: "Last checked \(when). No problems found.", level: .good)
        case .warnings: return RBA75Line(text: "Last checked \(when). Some things are worth a look.", level: .warning)
        case .errors: return RBA75Line(text: "Last checked \(when). Problems need attention.", level: .bad)
        case .unknown: return RBA75Line(text: "Last checked \(when).", level: .neutral)
        }
    }

    static func drillLine(_ record: DrillRecord?, overdue: Bool, now: Date = Date(), calendar: Calendar = .current) -> RBA75Line {
        guard let record, record.at != nil else {
            return RBA75Line(text: "You have never practised a restore. Do one to know your backups work before you need one.", level: .warning)
        }
        let when = Self.when(record.at, now: now, calendar: calendar)
        if !record.succeeded {
            return RBA75Line(text: "The last practice restore (\(when)) failed for \(record.backupName). Make a new backup and try again.", level: .bad)
        }
        if overdue {
            return RBA75Line(text: "Last practised \(when), more than 30 days ago. Practise again.", level: .warning)
        }
        return RBA75Line(text: "Practised \(when) on \(record.backupName). It could be restored.", level: .good)
    }

    static func backupResult(_ outcome: BackupOutcome) -> RBA75Result {
        switch outcome {
        case .completed(let summary):
            var details = ["\(StorageBreakdown.format(summary.bytes)) · \(summary.copies) \(summary.copies == 1 ? "copy" : "copies")"]
            if summary.prunedCount > 0 {
                details.append("\(summary.prunedCount) older \(summary.prunedCount == 1 ? "backup was" : "backups were") removed by the rotation.")
            }
            details.append(contentsOf: summary.warnings)
            return RBA75Result(succeeded: true, title: "Backup finished: \(summary.folderName)", details: details)
        case .skipped(let reason):
            return RBA75Result(succeeded: false, title: "Backup skipped. \(reason)")
        case .failed(let message):
            return RBA75Result(succeeded: false, title: "Backup failed. \(message)")
        }
    }

    static func exportResult(_ result: ExportEverythingResult) -> RBA75Result {
        let counts = "\(result.itemCount) items · \(result.noteCount) notes · \(result.pdfCount) PDFs · \(result.draftFolderCount) drafts"
        return RBA75Result(
            succeeded: true,
            title: "Exported to \(result.folder.lastPathComponent)",
            details: [counts + " · " + StorageBreakdown.format(result.bytes)] + result.warnings
        )
    }
}

struct RBA75SecretRow: Identifiable, Equatable {
    let name: SecretName
    var title: String
    var isSet: Bool
    /// "••••a1b2". Never the whole key.
    var masked: String?
    var error: String?

    var id: String { name.rawValue }
}

enum RBA75Secrets {

    static func rows(in store: any SecretStore, names: [SecretName] = SecretName.all) -> [RBA75SecretRow] {
        names.map { name in
            do {
                let value = try store.read(name)
                return RBA75SecretRow(name: name, title: name.displayName, isSet: value != nil,
                                      masked: value.map { SecretMask.masked($0) }, error: nil)
            } catch {
                return RBA75SecretRow(name: name, title: name.displayName, isSet: false, masked: nil,
                                      error: error.localizedDescription)
            }
        }
    }

    /// Spaces and line breaks around a pasted key are removed. An empty key is refused.
    static func save(_ value: String, for name: SecretName, in store: any SecretStore) throws {
        try store.save(value, for: name)
    }

    static func remove(_ name: SecretName, in store: any SecretStore) throws {
        try store.delete(name)
    }
}

// MARK: Shared small views

@MainActor
private func rbA75Run(_ busy: Binding<SettingsBusy?>, _ operation: SettingsBusy, work: @escaping @MainActor () async -> Void) {
    guard busy.wrappedValue == nil else { return }
    busy.wrappedValue = operation
    Task { @MainActor in
        await work()
        busy.wrappedValue = nil
    }
}

private struct RBA75LineView: View {

    let line: RBA75Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(line.text)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch line.level {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .neutral: return "info.circle"
        }
    }

    private var color: Color {
        switch line.level {
        case .good: return RBColor.success
        case .warning: return RBColor.warning
        case .bad: return RBColor.error
        case .neutral: return RBColor.mutedText
        }
    }
}

private struct RBA75ResultView: View {

    let result: RBA75Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RBA75LineView(line: RBA75Line(text: result.title, level: result.succeeded ? .good : .bad))
            ForEach(Array(result.details.enumerated()), id: \.offset) { _, detail in
                Text(detail)
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
    }
}

// MARK: Container

private struct RBA75Cards: View {

    let model: LibraryModel?
    let scheduler: BackupScheduler?
    let context: ModelContext
    @Binding var busy: SettingsBusy?

    var body: some View {
        if let model {
            RBA75StorageCard(library: model.library, busy: $busy)
            RBA75BackupCard(scheduler: scheduler, busy: $busy)
            RBA75ExportCard(scheduler: scheduler, busy: $busy)
            RBA75DrillCard(library: model.library, context: context, busy: $busy)
            RBA75HealthCard(library: model.library, busy: $busy)
        } else {
            SettingsCard(
                title: "Library",
                systemImage: "internaldrive",
                subtitle: "The library is not open in this window, so storage, backups, practice restore and health checks are not available yet."
            ) { EmptyView() }
        }
        RBA75SecretsCard(busy: $busy)
    }
}

// MARK: Library and storage (X-04)

private struct RBA75StorageCard: View {

    let library: Library
    @Binding var busy: SettingsBusy?

    @State private var breakdown: StorageBreakdown?
    @State private var measuring = false

    private static let palette: [Color] = [
        RBColor.accent, RBColor.accentSecondary, RBColor.success, RBColor.warning, RBColor.secondaryText, RBColor.mutedText, RBColor.border
    ]

    private func color(_ category: StorageCategory) -> Color {
        Self.palette[category.barOrder % Self.palette.count]
    }

    var body: some View {
        SettingsCard(
            title: "Library and storage",
            systemImage: "internaldrive",
            subtitle: "Where your library lives and what takes the space. Looking at this never changes a file."
        ) {
            if let breakdown {
                Text(breakdown.displayPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RBColor.secondaryText)
                    .textSelection(.enabled)

                if !breakdown.exists {
                    RBA75LineView(line: RBA75Line(text: "The library folder is not there. Check that its disk is connected.", level: .bad))
                } else {
                    sizeBar(breakdown)
                    chips(breakdown)

                    Text(summary(breakdown))
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…")
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.secondaryText)
                }
            }

            SettingsActionRow {
                Button("Reveal in Finder") { StorageReveal.reveal(library.root) }
                    .buttonStyle(RBGhostButtonStyle())
                Button("Measure Again") { Task { await measure() } }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(measuring)
            }
        }
        .task { await measure() }
    }

    private func sizeBar(_ b: StorageBreakdown) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(b.segments, id: \.category) { segment in
                    color(segment.category)
                        .frame(width: max(2, geo.size.width * segment.fraction))
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 10)
        .background(RBColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    private func chips(_ b: StorageBreakdown) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(b.entries.filter { $0.bytes > 0 }, id: \.category) { entry in
                HStack(spacing: 6) {
                    Circle().fill(color(entry.category)).frame(width: 8, height: 8)
                    Text(b.chipText(entry.category))
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                }
            }
        }
    }

    private func summary(_ b: StorageBreakdown) -> String {
        var text = "Total \(StorageBreakdown.format(b.totalBytes)) in \(b.totalFiles) files"
        if let free = b.freeBytes { text += " · \(StorageBreakdown.format(free)) free on this disk" }
        return text
    }

    private func measure() async {
        measuring = true
        await Task.yield()
        breakdown = StorageBreakdown.measure(library: library)
        measuring = false
    }
}

// MARK: Automatic backups (F-49)

private struct RBA75BackupCard: View {

    let scheduler: BackupScheduler?
    @Binding var busy: SettingsBusy?

    @State private var result: RBA75Result?

    var body: some View {
        SettingsCard(
            title: "Automatic backups",
            systemImage: "clock.arrow.circlepath",
            subtitle: "A full copy of the library on a schedule, kept as rotating copies: 3 daily, 2 weekly and 3 monthly. Files that did not change are shared between copies, so extra copies use very little extra space. Backups run while ResearchBase is open; one missed overnight is made up at the next launch."
        ) {
            if let scheduler {
                content(scheduler)
            } else {
                RBA75LineView(line: RBA75Line(text: "Automatic backups are not running in this window yet.", level: .warning))
            }
        }
    }

    @ViewBuilder
    private func content(_ scheduler: BackupScheduler) -> some View {
        RBA75LineView(line: RBA75Text.backupLine(scheduler.status))
        RBA75LineView(line: RBA75Text.secondLocationLine(scheduler.status))

        Picker("Schedule", selection: Binding(get: { scheduler.schedule }, set: { scheduler.schedule = $0 })) {
            ForEach(BackupSchedule.allCases) { Text($0.title).tag($0) }
        }
        .frame(maxWidth: 320)
        .disabled(busy != nil)

        if scheduler.schedule == .off {
            RBA75LineView(line: RBA75Line(text: "Backups are off. Nothing protects the library from a disk failure.", level: .bad))
        }

        Toggle("Tell me when a backup fails", isOn: Binding(get: { scheduler.notifyOnFailure }, set: { scheduler.notifyOnFailure = $0 }))
            .toggleStyle(.switch)

        SettingsActionRow {
            Button("Back Up Now") {
                rbA75Run($busy, .libraryBackup) {
                    result = RBA75Text.backupResult(await scheduler.backupNow())
                    scheduler.refreshStatus()
                }
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(busy != nil || scheduler.isRunning || scheduler.isExporting)

            Button("Choose Second Location…") {
                if let url = SettingsPanels.choosePackage(message: "Choose a folder on another disk for a second copy of every backup.") {
                    scheduler.setSecondLocation(url)
                }
            }
            .buttonStyle(RBGhostButtonStyle())
            .disabled(busy != nil)

            if scheduler.status.secondLocationPath != nil {
                Button("Remove Second Location") { scheduler.setSecondLocation(nil) }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(busy != nil)
            }
        }

        if let result { RBA75ResultView(result: result) }
    }
}

// MARK: Export everything (F-50)

private struct RBA75ExportCard: View {

    let scheduler: BackupScheduler?
    @Binding var busy: SettingsBusy?

    @State private var result: RBA75Result?
    @State private var exportedFolder: URL?

    var body: some View {
        SettingsCard(
            title: "Export everything",
            systemImage: "square.and.arrow.up.on.square",
            subtitle: "A copy in open formats that can be read without this app: library.json, references.bib, notes as Markdown, drafts as folders, and every PDF with a readable name."
        ) {
            if let scheduler {
                content(scheduler)
            } else {
                RBA75LineView(line: RBA75Line(text: "Export is not available in this window yet.", level: .warning))
            }
        }
    }

    @ViewBuilder
    private func content(_ scheduler: BackupScheduler) -> some View {
        let reminder = scheduler.exportReminder

        RBA75LineView(line: RBA75Line(
            text: reminder.lastExportAt == nil ? "You have not exported yet." : "Last export: \(RBA75Text.when(reminder.lastExportAt)).",
            level: reminder.lastExportAt == nil ? .neutral : .good
        ))

        if scheduler.isExportDue {
            RBA75LineView(line: RBA75Line(text: "A monthly export is due.", level: .warning))
        }

        Toggle("Remind me to export every month", isOn: Binding(
            get: { scheduler.exportReminder.remindMonthly },
            set: { scheduler.setExportReminder(enabled: $0) }
        ))
        .toggleStyle(.switch)

        SettingsActionRow {
            Button("Export Everything…") {
                guard let parent = SettingsPanels.choosePackage(message: "Choose where to put the export folder.") else { return }
                rbA75Run($busy, .exportingEverything) {
                    do {
                        let done = try await scheduler.exportEverything(to: parent)
                        exportedFolder = done.folder
                        result = RBA75Text.exportResult(done)
                    } catch {
                        exportedFolder = nil
                        result = RBA75Result(succeeded: false, title: error.localizedDescription)
                    }
                }
            }
            .buttonStyle(RBPrimaryButtonStyle())
            .disabled(busy != nil || scheduler.isRunning || scheduler.isExporting)

            if let exportedFolder {
                Button("Show in Finder") { StorageReveal.reveal(exportedFolder) }
                    .buttonStyle(RBGhostButtonStyle())
            }
        }

        if let result { RBA75ResultView(result: result) }
    }
}

// MARK: Practice restore (F-51)

private struct RBA75DrillCard: View {

    let library: Library
    let context: ModelContext
    @Binding var busy: SettingsBusy?

    @State private var backups: [BackupRecord] = []
    @State private var last: DrillRecord?
    @State private var overdue = true
    @State private var drill: RestoreDrill?
    @State private var showingSheet = false

    var body: some View {
        SettingsCard(
            title: "Practice restore",
            systemImage: "checkmark.shield",
            subtitle: "Restores a backup into a scratch folder and checks it, so you know your backups work before you need one. Your library is only read, and the scratch folder is removed afterwards."
        ) {
            RBA75LineView(line: RBA75Text.drillLine(last, overdue: overdue))

            if backups.isEmpty {
                Text("No backups yet. Make one under Automatic backups first.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            } else {
                VStack(spacing: 8) {
                    ForEach(backups.prefix(5)) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.name)
                                    .font(RBFont.body(.medium))
                                    .foregroundStyle(RBColor.primaryText)
                                Text(RBA75Text.when(backup.date))
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                            }
                            Spacer()
                            Button("Practice Restore") { start(backup) }
                                .buttonStyle(RBGhostButtonStyle())
                                .disabled(busy != nil)
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $showingSheet) {
            if let drill {
                RBA75DrillSheet(drill: drill) {
                    showingSheet = false
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        backups = BackupScheduler.listBackups(in: library.backupsURL)
        last = RestoreDrill.lastDrill(in: library)
        overdue = RestoreDrill.isOverdue(in: library)
    }

    private func start(_ backup: BackupRecord) {
        let run = RestoreDrill(library: library, context: context)
        drill = run
        showingSheet = true
        rbA75Run($busy, .practiceRestore) {
            _ = await run.run(backupAt: backup.url)
            refresh()
        }
    }
}

private struct RBA75DrillSheet: View {

    let drill: RestoreDrill
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Practice restore")
                .font(RBFont.title(.semibold))
                .foregroundStyle(RBColor.primaryText)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(drill.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon(step.state)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(RBFont.body(.medium))
                                .foregroundStyle(RBColor.primaryText)
                            if let note = note(step.state) {
                                Text(note)
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let result = drill.result {
                Divider().overlay(RBColor.border)
                RBA75LineView(line: RBA75Line(text: result.verdict.headline, level: level(result.verdict)))
                if case .passedWithNotes(let notes) = result.verdict {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                            .padding(.leading, 24)
                    }
                }
            }

            HStack {
                Spacer()
                Button(drill.isRunning ? "Running…" : "Done", action: onClose)
                    .buttonStyle(RBPrimaryButtonStyle())
                    .disabled(drill.isRunning)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(RBColor.elevatedSurface)
        .interactiveDismissDisabled(drill.isRunning)
    }

    @ViewBuilder
    private func icon(_ state: DrillStepState) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(RBColor.mutedText)
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(RBColor.success)
        case .passedWithNote: Image(systemName: "checkmark.circle").foregroundStyle(RBColor.warning)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(RBColor.error)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(RBColor.mutedText)
        }
    }

    private func note(_ state: DrillStepState) -> String? {
        switch state {
        case .passedWithNote(let text), .failed(let text), .skipped(let text): return text
        case .pending, .running, .passed: return nil
        }
    }

    private func level(_ verdict: DrillVerdict) -> RBA75Level {
        switch verdict {
        case .passed: return .good
        case .passedWithNotes: return .warning
        case .failed: return .bad
        case .skipped: return .neutral
        }
    }
}

// MARK: Library health (F-48, F-55)

private struct RBA75HealthCard: View {

    let library: Library
    @Binding var busy: SettingsBusy?

    @State private var lastRun: IntegrityLastRun?
    @State private var report: IntegrityReport?
    @State private var selfTest: IntegritySelfTestReport?
    @State private var recovery: LibraryRecoveryInfo?
    @State private var macChanged = false
    @State private var errorText: String?

    private let shownIssues = 8

    var body: some View {
        SettingsCard(
            title: "Library health",
            systemImage: "stethoscope",
            subtitle: "Looks for missing or changed PDFs, broken links, unused files and database problems, and checks that this Mac still runs everything the library needs. Checks only read; they never repair, move or delete anything."
        ) {
            RBA75LineView(line: RBA75Text.integrityLine(lastRun))

            if macChanged {
                RBA75LineView(line: RBA75Line(text: "macOS has changed since the last self-test. Run the self-test to be sure everything still works.", level: .warning))
            }

            SettingsActionRow {
                Button("Quick Check") { check(.quick) }
                    .buttonStyle(RBPrimaryButtonStyle())
                    .disabled(busy != nil)
                Button("Deep Check") { check(.deep) }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(busy != nil)
                Button("Run Self-Test") { runSelfTest() }
                    .buttonStyle(RBGhostButtonStyle())
                    .disabled(busy != nil)
            }

            if let errorText { RBA75LineView(line: RBA75Line(text: errorText, level: .bad)) }
            if let report { reportView(report) }
            if let selfTest { selfTestView(selfTest) }
            if let recovery { recoveryView(recovery) }
        }
        .onAppear(perform: refresh)
    }

    // MARK: Parts

    private func reportView(_ report: IntegrityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RBA75LineView(line: RBA75Line(
                text: (report.depth == .deep ? "Deep check: " : "Quick check: ") + report.summary,
                level: report.isClean ? .good : (report.isHealthy ? .warning : .bad)
            ))

            ForEach(report.issues.prefix(shownIssues)) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .font(RBFont.body(.medium))
                        .foregroundStyle(issue.severity == .error ? RBColor.error : RBColor.primaryText)
                    if !issue.detail.isEmpty {
                        Text(issue.detail)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !issue.suggestion.isEmpty {
                        Text(issue.suggestion)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RBColor.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: RBRadius.control))
            }

            if report.issues.count > shownIssues {
                Text("…and \(report.issues.count - shownIssues) more.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
            if report.wasTruncated {
                Text("Some categories had too many problems to list in full.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    private func selfTestView(_ test: IntegritySelfTestReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RBA75LineView(line: RBA75Line(
                text: "Self-test: " + test.summary,
                level: test.isAllClear ? .good : (test.passed ? .warning : .bad)
            ))
            ForEach(test.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: check.status == .pass ? "checkmark" : (check.status == .warning ? "exclamationmark" : "xmark"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(check.status == .pass ? RBColor.success : (check.status == .warning ? RBColor.warning : RBColor.error))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title)
                            .font(RBFont.caption(.semibold))
                            .foregroundStyle(RBColor.primaryText)
                        if !check.detail.isEmpty {
                            Text(check.detail)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func recoveryView(_ info: LibraryRecoveryInfo) -> some View {
        DisclosureGroup("Recovery info") {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    Text("ResearchBase \(info.appVersion) (\(info.appBuild)) · macOS \(info.macOSVersion) · SQLite \(info.sqliteVersion)")
                    Text("Library: \(info.libraryPath)")
                    if let onDisk = info.schemaVersionOnDisk {
                        Text("Schema version \(onDisk) (this app supports \(info.schemaVersionSupported))")
                    }
                    if !info.recordCounts.isEmpty {
                        Text(info.recordCounts.map { "\($0.count) \($0.table)" }.joined(separator: " · "))
                    }
                }
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .textSelection(.enabled)

                ForEach(Array(info.rebuildNotes.enumerated()), id: \.offset) { _, note in
                    Text("• " + note)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
        .font(RBFont.body(.medium))
        .foregroundStyle(RBColor.primaryText)
    }

    // MARK: Work

    private func refresh() {
        lastRun = IntegrityChecker.lastRun(in: library)
        macChanged = IntegrityChecker.macOSChangedSinceLastSelfTest(in: library)
        recovery = IntegrityChecker.recoveryInfo(for: library)
    }

    private func check(_ depth: IntegrityDepth) {
        rbA75Run($busy, .integrityCheck) {
            errorText = nil
            do {
                report = try await IntegrityChecker.run(on: library, depth: depth)
            } catch {
                errorText = "The check could not finish: \(error.localizedDescription)"
            }
            refresh()
        }
    }

    private func runSelfTest() {
        rbA75Run($busy, .selfTest) {
            errorText = nil
            selfTest = await IntegrityChecker.runSelfTest(on: library)
            refresh()
        }
    }
}

// MARK: Keys and tokens (F-56)

private struct RBA75SecretsCard: View {

    @Binding var busy: SettingsBusy?

    /// The real Keychain. Secrets are never written anywhere else.
    private let store: any SecretStore = KeychainStore.shared

    @State private var rows: [RBA75SecretRow] = []
    @State private var entries: [String: String] = [:]
    @State private var message: RBA75Result?

    var body: some View {
        SettingsCard(
            title: "Keys and tokens",
            systemImage: "key",
            subtitle: "Optional keys for faster or fuller lookups. They are kept in the macOS Keychain on this Mac only, and never in the library, backups or exports."
        ) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row.title)
                            .font(RBFont.body(.medium))
                            .foregroundStyle(RBColor.primaryText)
                        Spacer()
                        if let error = row.error {
                            Text(error)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.error)
                        } else {
                            Text(row.isSet ? "Saved \(row.masked ?? "")" : "Not set")
                                .font(RBFont.caption())
                                .foregroundStyle(row.isSet ? RBColor.success : RBColor.mutedText)
                        }
                    }

                    HStack(spacing: 8) {
                        SecureField(row.isSet ? "Paste a new key to replace it" : "Paste key", text: entry(row))
                            .textFieldStyle(.roundedBorder)
                        Button("Save") { save(row) }
                            .buttonStyle(RBGhostButtonStyle())
                            .disabled(busy != nil || (entries[row.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if row.isSet {
                            Button("Remove") { remove(row) }
                                .buttonStyle(RBGhostButtonStyle())
                                .disabled(busy != nil)
                        }
                    }
                }
            }

            if let message { RBA75ResultView(result: message) }
        }
        .onAppear(perform: reload)
    }

    private func entry(_ row: RBA75SecretRow) -> Binding<String> {
        Binding(get: { entries[row.id] ?? "" }, set: { entries[row.id] = $0 })
    }

    private func reload() {
        rows = RBA75Secrets.rows(in: store)
    }

    private func save(_ row: RBA75SecretRow) {
        do {
            try RBA75Secrets.save(entries[row.id] ?? "", for: row.name, in: store)
            message = RBA75Result(succeeded: true, title: "\(row.title) saved to the Keychain.")
        } catch {
            message = RBA75Result(succeeded: false, title: error.localizedDescription)
        }
        entries[row.id] = nil        // never keep a pasted key in memory longer than needed
        reload()
    }

    private func remove(_ row: RBA75SecretRow) {
        do {
            try RBA75Secrets.remove(row.name, in: store)
            message = RBA75Result(succeeded: true, title: "\(row.title) removed.")
        } catch {
            message = RBA75Result(succeeded: false, title: error.localizedDescription)
        }
        entries[row.id] = nil
        reload()
    }
}


// MARK: - Erase everything and start fresh

enum RBA75EraseLogic {

    /// The word the user must type before the erase button works.
    static let phrase = "ERASE"

    static func isConfirmed(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == phrase
    }
}

private struct RBA75EraseCard: View {

    let isBusy: Bool

    @State private var typed = ""
    @State private var scheduled = false
    @State private var message: String?
    @State private var lastSummary = ""

    var body: some View {
        SettingsCard(
            title: "Data",
            systemImage: "trash",
            subtitle: "Erase everything and start fresh: your papers, notes, drafts, submissions, backups made by the app, settings and saved keys. ResearchBase then restarts as if it were new. This cannot be undone. Make a backup first (see Backup above).",
            isWarning: true
        ) {
            VStack(alignment: .leading, spacing: 12) {

                Text("Type \(RBA75EraseLogic.phrase) to confirm.")
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.error)

                TextField(RBA75EraseLogic.phrase, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .disabled(isBusy || scheduled)

                Button {
                    erase()
                } label: {
                    Label("Erase everything and start fresh", systemImage: "trash")
                        .foregroundStyle(canErase ? RBColor.error : RBColor.mutedText)
                }
                .buttonStyle(RBGhostButtonStyle())
                .disabled(!canErase)

                if let message {
                    Text(message)
                        .font(RBFont.secondary(.medium))
                        .foregroundStyle(RBColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !lastSummary.isEmpty {
                    Text("Last erase: \(lastSummary)")
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { lastSummary = ResetService.eraseSummary }
    }

    private var canErase: Bool {
        !isBusy && !scheduled && RBA75EraseLogic.isConfirmed(typed)
    }

    private func erase() {
        guard canErase else { return }
        scheduled = true
        typed = ""
        message = "Erasing on restart. ResearchBase is closing and will reopen with a clean start."
        ResetService.scheduleEraseAndRelaunch()
        let summary = ResetService.eraseSummary
        if !summary.isEmpty { lastSummary = summary }
    }
}
