//
//  WorkspaceRestoreService.swift
//  ResearchBase
//
//  Phase 13 — Restore & Data Safety
//
//  Replaces the CURRENT workspace with the contents of a `.researchbase`
//  package. This is the dangerous sibling of Import, so every step is
//  ordered to keep the person's data safe:
//
//    1. Validate      the package is read and checksum-verified
//                     (WorkspaceBackupService.loadPackage).
//    2. Safety backup the current workspace is backed up to
//                     Application Support/ResearchBase/Backups and the
//                     backup is checked against the live counts. If it
//                     cannot be made, the restore STOPS and nothing has
//                     been touched.
//    3. Confirm       the caller must pass `userConfirmed: true`. The
//                     Settings screen asks the person first; the
//                     service refuses to run without it.
//    4. Clear         every record is deleted and saved. The PDF files
//                     of the old papers are NOT deleted yet.
//    5. Restore       the package is loaded with the same code path as
//                     Import (WorkspaceImportService), so there is no
//                     second, different way of reading a backup. PDFs
//                     are staged into managed storage first and records
//                     are created and saved once.
//    6. Verify        the record counts of the restored workspace are
//                     compared with the backup's manifest.
//    7. Clean up      only now are the old managed PDF files deleted.
//
//  If step 5 fails, the workspace is emptied again and the safety
//  backup is imported, which puts back what was there before. The
//  put-back is only reported as successful when the record counts match
//  the safety backup. If it cannot be confirmed, the error says so
//  plainly and gives the safety backup's location so the person can
//  import it by hand. Nothing is ever reported as restored unless it
//  was.
//
//  Old PDF files are deleted only after the workspace they belonged to
//  has been replaced (success) or put back and verified (rollback).
//  If a rollback cannot be verified, they are left alone.
//
//  The theme stored in the backup is returned as `themeToApply`. This
//  service does not change the theme itself, because only
//  AppearanceSettings can also refresh the UI.
//
//  Two notifications are posted, because open screens may hold records
//  that are about to be deleted:
//    .workspaceWillRestore   before anything is deleted. ContentView
//                            must close open papers/sheets and go back
//                            to a screen that holds no records.
//    .workspaceDidRestore    after the restore finished or was rolled
//                            back.
//

import Foundation
import SwiftData

// MARK: - Notifications

extension Notification.Name {

    /// Posted just before the workspace is cleared.
    static let workspaceWillRestore = Notification.Name(
        "ResearchBase.workspaceWillRestore"
    )

    /// Posted when a restore has finished (or was rolled back).
    static let workspaceDidRestore = Notification.Name(
        "ResearchBase.workspaceDidRestore"
    )
}

// MARK: - Errors

enum WorkspaceRestoreError: LocalizedError {

    case notConfirmed
    case emptyBackup
    case couldNotSavePendingChanges(String)
    case safetyBackupFailed(String)
    case couldNotClearWorkspace(String)

    /// The restore failed and the previous workspace was put back and
    /// its record counts were checked against the safety backup.
    case failedRolledBack(String, safetyBackup: URL?)

    /// The restore failed and the previous workspace could NOT be
    /// confirmed as put back. The safety backup (if any) still holds
    /// it.
    case failedNotRolledBack(String, safetyBackup: URL?)

    var errorDescription: String? {
        switch self {

        case .notConfirmed:
            return "The restore was not confirmed, so nothing was changed."

        case .emptyBackup:
            return "This backup contains no records. Restoring it would only erase your workspace, so nothing was changed."

        case .couldNotSavePendingChanges(let detail):
            return "Your unsaved changes could not be saved before restoring, so nothing was changed. \(detail)"

        case .safetyBackupFailed(let detail):
            return "A safety backup of your current workspace could not be made, so the restore was stopped and nothing was changed. \(detail)"

        case .couldNotClearWorkspace(let detail):
            return "The current workspace could not be cleared, so nothing was changed. \(detail)"

        case .failedRolledBack(let detail, let backup):

            var text = "The restore failed, and your previous workspace was put back. \(detail)"

            if let backup = backup {
                text += " A safety backup is also at: \(backup.path)"
            }

            return text

        case .failedNotRolledBack(let detail, let backup):

            var text = "The restore failed and your previous workspace could not be confirmed as put back. \(detail)"

            if let backup = backup {
                text += " Your previous workspace is safe in this backup: \(backup.path). Use Import to bring it back."
            }

            return text
        }
    }
}

// MARK: - Preview

/// One line of the "current vs backup" table.
struct WorkspaceRestoreRow: Identifiable {

    let label: String

    /// Records of this type in the workspace right now. They will be
    /// removed.
    let current: Int

    /// Records of this type in the backup. They will replace them.
    let inBackup: Int

    var id: String { label }
}

/// What a restore would do. Built without changing anything.
struct WorkspaceRestorePreview {

    let package: LoadedWorkspacePackage

    let rows: [WorkspaceRestoreRow]

    let currentRecordCount: Int
    let backupRecordCount: Int

    /// Papers in the workspace right now that have a PDF file.
    let currentPDFCount: Int

    /// PDF files stored in the backup.
    let backupPDFCount: Int

    /// PDF problems found while verifying the package.
    let pdfProblems: [String]

    /// The theme saved in the backup, if it is one this app knows.
    let themeInBackup: RBThemeID?

    /// Folder the safety backup will be written to.
    let safetyBackupFolder: URL

    /// False when the workspace is empty, so there is nothing to
    /// protect.
    let safetyBackupWillBeMade: Bool

    /// Things to know that do not stop the restore.
    let warnings: [String]

    var canRestore: Bool {
        backupRecordCount > 0
    }

    var createdAt: Date {
        package.manifest.createdAt
    }

    var appVersion: String {
        package.manifest.appVersion
    }
}

// MARK: - Result

struct WorkspaceRestoreResult {

    /// What was created (same shape as an import).
    let imported: WorkspaceImportResult

    /// The safety backup of the previous workspace. Nil only when the
    /// workspace was empty, so there was nothing to back up.
    let safetyBackupURL: URL?

   
    /// AppearanceSettings.select so the UI refreshes.
    let themeToApply: RBThemeID?

    /// caller through ProfileStore.setDisplayName,
    /// AppearanceSettings.commitTextScale and
    /// AppearanceSettings.commitAccent(hex:).
    let displayNameToApply: String?
    let textScaleToApply: Double?
    let accentHexToApply: String?
    /// Everything the person should know about.
    let warnings: [String]

    var summary: String {

        var text = "Restored \(imported.createdTotal) record"
        if imported.createdTotal != 1 { text += "s" }

        text += " and \(imported.pdfsCopied) PDF file"
        if imported.pdfsCopied != 1 { text += "s" }

        text += "."

        return text
    }
}

// MARK: - Service

enum WorkspaceRestoreService {

    /// The order record types are listed in, matching the backup's
    /// count names.
    private static let labelOrder: [String] = [
        "Papers",
        "PDF Annotations",
        "Research Notes",
        "Literature Reviews",
        "Literature Themes",
        "Findings",
        "Comparison Entries",
        "Syntheses",
        "Research Gaps",
        "Research Problems",
        "Research Ideas",
        "Experiments",
        "Experiment Runs",
        "Run Metrics",
        "Baseline Metrics",
        "Writing Documents",
        "Writing Sections",
        "Projects",
        "Tasks"
    ]

    // MARK: Preview

    /// Reads and verifies the package and compares it with the current
    /// workspace. Read-only.
    ///
    /// Throws `WorkspaceBackupError` when the package cannot be used.
    @MainActor
    static func preview(
        packageAt url: URL,
        context: ModelContext
    ) async throws -> WorkspaceRestorePreview {

        let package = try await loadVerified(url)

        let capture = try WorkspaceSnapshot.capture(from: context)
        let currentCounts = capture.snapshot.entityCounts
        let backupCounts = package.manifest.entityCounts

        // Rows

        var labels = labelOrder

        let known = Set(labelOrder)
        let extra = Set(currentCounts.keys)
            .union(backupCounts.keys)
            .subtracting(known)

        labels.append(contentsOf: extra.sorted())

        var rows: [WorkspaceRestoreRow] = []

        for label in labels {

            let current = currentCounts[label] ?? 0
            let inBackup = backupCounts[label] ?? 0

            if current == 0 && inBackup == 0 { continue }

            rows.append(
                WorkspaceRestoreRow(
                    label: label,
                    current: current,
                    inBackup: inBackup
                )
            )
        }

        let currentTotal = currentCounts.values.reduce(0, +)
        let backupTotal = backupCounts.values.reduce(0, +)

        let currentPDFs = capture.snapshot.papers
            .filter { $0.pdfState == "included" }
            .count

        // Theme

        var theme: RBThemeID?

        if let raw = package.settings?.theme {
            theme = RBThemeID(rawValue: raw)
        }

        // Warnings

        var warnings: [String] = []

        if backupTotal == 0 {
            warnings.append(
                "This backup contains no records. It cannot be restored."
            )
        }

        if !capture.missingPDFTitles.isEmpty {
            warnings.append(
                "\(capture.missingPDFTitles.count) paper(s) in your current workspace already have no PDF file on disk, so no PDF can be saved for them in the safety backup."
            )
        }

        if !package.pdfProblems.isEmpty {
            warnings.append(
                "\(package.pdfProblems.count) PDF problem(s) were found in this backup. Those papers will come back without their PDF. Your current PDF files are kept in the safety backup."
            )
        }

        let missingAtBackup = package.manifest.papersWithMissingPDF.count

        if missingAtBackup > 0 {
            warnings.append(
                "\(missingAtBackup) paper(s) had no PDF file when this backup was made, so they will come back without a PDF."
            )
        }

        return WorkspaceRestorePreview(
            package: package,
            rows: rows,
            currentRecordCount: currentTotal,
            backupRecordCount: backupTotal,
            currentPDFCount: currentPDFs,
            backupPDFCount: package.manifest.pdfFiles.count,
            pdfProblems: package.pdfProblems,
            themeInBackup: theme,
            safetyBackupFolder: WorkspaceBackupService.automaticBackupsDirectory,
            safetyBackupWillBeMade: currentTotal > 0,
            warnings: warnings
        )
    }

    // MARK: Restore

    /// Replaces the workspace with the package described by `preview`.
    ///
    /// `userConfirmed` must be true. The caller (Settings) is
    /// responsible for actually asking the person; the service will
    /// not run without it.
    @MainActor
    static func restore(
        preview: WorkspaceRestorePreview,
        userConfirmed: Bool,
        context: ModelContext,
        profile: ProfileStore? = nil
    ) async throws -> WorkspaceRestoreResult {

        guard userConfirmed else {
            throw WorkspaceRestoreError.notConfirmed
        }

        let url = preview.package.url

        // 1. Validate again. The package may have changed since the
        //    preview was made.

        let package = try await loadVerified(url)

        let backupTotal = package.manifest.entityCounts.values.reduce(0, +)

        guard backupTotal > 0 else {
            throw WorkspaceRestoreError.emptyBackup
        }

        // 2. Save pending edits so they are part of the safety backup
        //    and can never be lost by a rollback.

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                throw WorkspaceRestoreError.couldNotSavePendingChanges(
                    error.localizedDescription
                )
            }
        }

        // 3. Safety backup of the current workspace.

        let before = try WorkspaceSnapshot.capture(from: context)

        var safety: WorkspaceBackupResult?

        if before.snapshot.totalRecordCount > 0 {

            do {
                let folder = WorkspaceBackupService.automaticBackupsDirectory

                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )

                let name = WorkspaceBackupService.suggestedFileName(
                    prefix: "ResearchBase Safety Backup",
                    date: Date()
                )

                let made = try await WorkspaceBackupService.createBackup(
                    context: context,
                    to: folder.appendingPathComponent(name),
                    profile: profile
                )
                // The backup must describe exactly what is in the
                // workspace right now.

                guard made.manifest.entityCounts == before.snapshot.entityCounts else {
                    throw WorkspaceBackupError.verificationFailed(
                        "The safety backup's record counts do not match the workspace."
                    )
                }

                safety = made

            } catch {
                throw WorkspaceRestoreError.safetyBackupFailed(
                    error.localizedDescription
                )
            }
        }

        // Old managed PDF files, remembered so they can be removed
        // after a successful restore or a verified rollback (and only
        // then).

        let oldPDFPaths: [String]

        do {
            oldPDFPaths = try context
                .fetch(FetchDescriptor<PaperRecord>())
                .map { $0.pdfFilePath }
                .filter { !$0.isEmpty }
        } catch {
            throw WorkspaceRestoreError.couldNotClearWorkspace(
                error.localizedDescription
            )
        }

        // 4. Tell the UI to let go of records, then clear.

        NotificationCenter.default.post(name: .workspaceWillRestore, object: nil)

        // Give SwiftUI a moment to close screens that hold records.

        try? await Task.sleep(nanoseconds: 300_000_000)

        do {
            try clearWorkspace(in: context)
        } catch {

            context.rollback()

            NotificationCenter.default.post(name: .workspaceDidRestore, object: nil)

            throw WorkspaceRestoreError.couldNotClearWorkspace(
                error.localizedDescription
            )
        }

        // 5. Restore, using the same code Import uses.

        let imported: WorkspaceImportResult

        do {
            let importPreview = try await WorkspaceImportService.preview(
                packageAt: url,
                context: context
            )

            imported = try await WorkspaceImportService.performImport(
                preview: importPreview,
                context: context
            )

        } catch {

            let detail = error.localizedDescription

            let putBack = await rollBack(context: context, safety: safety)

            // The old PDF files are only removed when the previous
            // workspace is confirmed back, because until then they
            // are the only live copies of those PDFs.

            if putBack {
                _ = removeOldPDFs(oldPDFPaths, context: context)
            }

            NotificationCenter.default.post(name: .workspaceDidRestore, object: nil)

            if putBack {
                throw WorkspaceRestoreError.failedRolledBack(
                    detail,
                    safetyBackup: safety?.packageURL
                )
            }

            throw WorkspaceRestoreError.failedNotRolledBack(
                detail,
                safetyBackup: safety?.packageURL
            )
        }

        // 6. Verify against the backup's manifest.

        var warnings = imported.warnings

        if let after = try? WorkspaceSnapshot.capture(from: context) {

            let expected = package.manifest.entityCounts
            let actual = after.snapshot.entityCounts

            var differences: [String] = []

            for label in labelOrder {

                let want = expected[label] ?? 0
                let have = actual[label] ?? 0

                if want != have {
                    differences.append("\(label): backup \(want), workspace \(have)")
                }
            }

            if !differences.isEmpty {

                var text = "After the restore some record counts differ from the backup (\(differences.joined(separator: "; "))). See the import notes above for the reason."

                if let backup = safety?.packageURL {
                    text += " Your previous workspace is safe in the safety backup at: \(backup.path)"
                }

                warnings.append(text)
            }

        } else {
            warnings.append(
                "The restored workspace could not be re-read to verify its record counts."
            )
        }

        // 7. Only now remove the old PDF files.

        warnings.append(
            contentsOf: removeOldPDFs(oldPDFPaths, context: context)
        )

        // Theme

        var theme: RBThemeID?

        if let raw = package.settings?.theme {
            theme = RBThemeID(rawValue: raw)
        }

        // Phase 14 preferences. Missing or unusable values become nil
        // so nothing is overwritten or cleared.

        let backupSettings = package.settings

        var nameToApply: String?

        if let raw = backupSettings?.displayName {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { nameToApply = trimmed }
        }

        var scaleToApply: Double?

        if let raw = backupSettings?.textScale, raw.isFinite {
            scaleToApply = raw
        }

        NotificationCenter.default.post(name: .workspaceDidRestore, object: nil)

        return WorkspaceRestoreResult(
            imported: imported,
            safetyBackupURL: safety?.packageURL,
            themeToApply: theme,
            displayNameToApply: nameToApply,
            textScaleToApply: scaleToApply,
            accentHexToApply: backupSettings?.accentOverrideHex,
            warnings: warnings
        )
    }

    // MARK: Loading

    private static func loadVerified(
        _ url: URL
    ) async throws -> LoadedWorkspacePackage {

        try await Task.detached(priority: .userInitiated) {
            try WorkspaceBackupService.loadPackage(at: url, verifyPDFs: true)
        }.value
    }

    // MARK: Clearing

    /// Deletes every record and saves once. Children are deleted
    /// before their owners, so the delete rules never have to remove
    /// something that is already gone.
    ///
    /// Only records are removed here. PDF files are not touched.
    @MainActor
    private static func clearWorkspace(in context: ModelContext) throws {

        try deleteAll(RunMetric.self, in: context)
        try deleteAll(BaselineMetric.self, in: context)
        try deleteAll(ExperimentRun.self, in: context)
        try deleteAll(WritingSection.self, in: context)

        try deleteAll(LiteratureTheme.self, in: context)
        try deleteAll(LiteratureFinding.self, in: context)
        try deleteAll(LiteratureComparisonEntry.self, in: context)
        try deleteAll(LiteratureSynthesis.self, in: context)
        try deleteAll(PDFNoteRecord.self, in: context)

        try deleteAll(LiteratureReview.self, in: context)
        try deleteAll(Experiment.self, in: context)
        try deleteAll(WritingDocument.self, in: context)
        try deleteAll(ResearchTask.self, in: context)
        try deleteAll(ResearchProject.self, in: context)

        try deleteAll(ResearchIdea.self, in: context)
        try deleteAll(ResearchProblem.self, in: context)
        try deleteAll(ResearchGap.self, in: context)
        try deleteAll(ResearchNote.self, in: context)
        try deleteAll(PaperRecord.self, in: context)

        try context.save()
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext
    ) throws {

        let items = try context.fetch(FetchDescriptor<T>())

        for item in items {
            context.delete(item)
        }
    }

    // MARK: Rollback

    /// Puts the previous workspace back after a failed restore.
    /// Returns true only when the workspace is back as it was: the
    /// safety backup was imported AND the record counts match the
    /// safety backup's manifest.
    @MainActor
    private static func rollBack(
        context: ModelContext,
        safety: WorkspaceBackupResult?
    ) async -> Bool {

        // Drop anything half-done, then make sure the workspace is
        // empty before the safety backup is imported.

        context.rollback()

        do {
            try clearWorkspace(in: context)
        } catch {
            context.rollback()
            return false
        }

        // Nothing was there before: an empty workspace is the correct
        // "before" state.

        guard let safety = safety else { return true }

        do {
            let importPreview = try await WorkspaceImportService.preview(
                packageAt: safety.packageURL,
                context: context
            )

            _ = try await WorkspaceImportService.performImport(
                preview: importPreview,
                context: context
            )

        } catch {
            return false
        }

        // "Put back" is only claimed when it can be shown.

        guard let after = try? WorkspaceSnapshot.capture(from: context) else {
            return false
        }

        return after.snapshot.entityCounts == safety.manifest.entityCounts
    }

    // MARK: Old PDF files

    /// Deletes the PDF files that belonged to the replaced papers.
    /// Only files inside ResearchBase's managed Papers folder are
    /// removed, and never a file the current papers use. A file that
    /// cannot be removed is reported, not hidden.
    @MainActor
    private static func removeOldPDFs(
        _ paths: [String],
        context: ModelContext
    ) -> [String] {

        var stillUsed = Set<String>()

        if let papers = try? context.fetch(FetchDescriptor<PaperRecord>()) {
            for paper in papers where !paper.pdfFilePath.isEmpty {
                stillUsed.insert(paper.pdfFilePath)
            }
        }

        var failed = 0

        for path in Set(paths) {

            if stillUsed.contains(path) { continue }

            let fileURL = URL(fileURLWithPath: path)

            guard PaperStorage.shared.isManagedPaperFile(fileURL) else {
                continue
            }

            do {
                try PaperStorage.shared.deletePDF(at: fileURL)
            } catch {
                failed += 1
            }
        }

        if failed > 0 {
            return [
                "\(failed) old PDF file(s) from the replaced workspace could not be removed. They are harmless and are also in the safety backup."
            ]
        }

        return []
    }
}
