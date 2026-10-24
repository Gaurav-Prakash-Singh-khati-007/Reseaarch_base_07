//
//  PreChangeBackup.swift
//  ResearchBase
//
//  Phase 0 (F-01) — Backup before anything changes
//
//  Any code that is about to change the user's data in a way that is
//  hard to undo (a storage migration, a bulk edit, a merge of many
//  papers, an import that replaces records) must call
//  `PreChangeBackup.make` FIRST and must not continue if it throws.
//
//  What "made" means here:
//    1. A full `.researchbase` package is written to
//       Application Support/ResearchBase/Backups (or a folder the
//       caller passes in, which tests use).
//    2. The package is read back and every checksum is verified
//       (this is already done by WorkspaceBackupService).
//    3. The workspace is captured again, and its record counts must
//       still equal the backup's. If anything changed while the
//       backup was running, the backup is not trusted and this throws.
//
//  This file reads the database and never changes it. It only adds
//  files to the backups folder and, in `prune`, removes OLD
//  pre-change backups it made itself.
//

import Foundation
import SwiftData

// MARK: - Errors

enum PreChangeBackupError: LocalizedError {

    case couldNotCreateFolder(String)
    case backupFailed(String)
    case workspaceChangedDuringBackup

    var errorDescription: String? {
        switch self {

        case .couldNotCreateFolder(let detail):
            return "The backup folder could not be created. Nothing was changed. \(detail)"

        case .backupFailed(let detail):
            return "A safety backup could not be made, so nothing was changed. \(detail)"

        case .workspaceChangedDuringBackup:
            return "Your data changed while the backup was running, so the backup was not trusted. Nothing was changed. Try again."
        }
    }
}

// MARK: - Result

struct PreChangeBackupResult {

    /// The verified backup package.
    let packageURL: URL

    /// What the backup contains, per record type.
    let entityCounts: [String: Int]

    /// Total records in the backup.
    var totalRecords: Int { entityCounts.values.reduce(0, +) }

    /// True when the workspace had no records. The backup is still
    /// valid; it just has nothing in it.
    var workspaceWasEmpty: Bool { totalRecords == 0 }

    /// PDFs that were saved into the backup.
    let pdfCount: Int

    /// Papers whose PDF was already missing before the backup, so it
    /// could not be saved. Shown to the person, never hidden.
    let papersWithMissingPDF: [String]
}

// MARK: - Service

enum PreChangeBackup {

    /// Every package this service makes starts with this, so `prune`
    /// can tell them apart from backups the person made by hand and
    /// from the safety backups Restore makes.
    static let filePrefix = "Before "

    /// How many pre-change backups are kept by default.
    static let defaultKeepCount = 20

    // MARK: Make

    /// Makes and verifies a backup. Throws if it cannot be trusted.
    ///
    /// - Parameter reason: short words for the file name, e.g.
    ///   "storage migration". Only letters, numbers, spaces and
    ///   hyphens are kept.
    @MainActor
    static func make(
        reason: String,
        context: ModelContext,
        profile: ProfileStore? = nil,
        directory: URL? = nil,
        date: Date = Date()
    ) async throws -> PreChangeBackupResult {

        // The default folder is looked up here, not in the parameter list,
        // because a default value cannot reach a main-actor property.
        let directory = directory ?? WorkspaceBackupService.automaticBackupsDirectory

        // Pending edits must be in the database before it is read,
        // otherwise the backup would miss them.

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                throw PreChangeBackupError.backupFailed(
                    "Pending changes could not be saved first. \(error.localizedDescription)"
                )
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PreChangeBackupError.couldNotCreateFolder(
                error.localizedDescription
            )
        }

        let name = WorkspaceBackupService.suggestedFileName(
            prefix: filePrefix + safeWords(reason),
            date: date
        )

        let destination = uniqueURL(
            for: directory.appendingPathComponent(name)
        )

        let made: WorkspaceBackupResult

        do {
            made = try await WorkspaceBackupService.createBackup(
                context: context,
                to: destination,
                profile: profile
            )
        } catch {
            throw PreChangeBackupError.backupFailed(error.localizedDescription)
        }

        // Read the package back from disk, as a restore would.

        let loaded: LoadedWorkspacePackage

        do {
            loaded = try WorkspaceBackupService.loadPackage(
                at: made.packageURL,
                verifyPDFs: true
            )
        } catch {
            try? FileManager.default.removeItem(at: made.packageURL)
            throw PreChangeBackupError.backupFailed(error.localizedDescription)
        }

        guard loaded.pdfProblems.isEmpty else {
            try? FileManager.default.removeItem(at: made.packageURL)
            throw PreChangeBackupError.backupFailed(
                loaded.pdfProblems.joined(separator: " ")
            )
        }

        // The live data must still be exactly what was backed up.

        let now: [String: Int]

        do {
            now = try WorkspaceSnapshot.capture(from: context).snapshot.entityCounts
        } catch {
            try? FileManager.default.removeItem(at: made.packageURL)
            throw PreChangeBackupError.backupFailed(error.localizedDescription)
        }

        guard now == loaded.manifest.entityCounts else {
            try? FileManager.default.removeItem(at: made.packageURL)
            throw PreChangeBackupError.workspaceChangedDuringBackup
        }

        return PreChangeBackupResult(
            packageURL: made.packageURL,
            entityCounts: loaded.manifest.entityCounts,
            pdfCount: loaded.manifest.pdfFiles.count,
            papersWithMissingPDF: loaded.manifest.papersWithMissingPDF
        )
    }

    // MARK: Prune

    /// Removes the OLDEST pre-change backups, keeping the newest
    /// `keeping`. Only packages whose name starts with `filePrefix`
    /// and ends in `.researchbase` are ever touched. Returns what was
    /// removed. At least one backup always stays, even if `keeping`
    /// is 0 or negative.
    @discardableResult
    static func prune(
        in directory: URL = WorkspaceBackupService.automaticBackupsDirectory,
        keeping: Int = defaultKeepCount
    ) -> [URL] {

        let keepCount = max(keeping, 1)
        let fm = FileManager.default

        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let ours = items.filter {
            $0.lastPathComponent.hasPrefix(filePrefix)
                && $0.pathExtension.lowercased() == WorkspaceFormat.packageExtension
        }

        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }

        // Newest first; ties broken by name so the order is stable.
        let sorted = ours.sorted {
            let a = modified($0), b = modified($1)
            return a == b ? $0.lastPathComponent > $1.lastPathComponent : a > b
        }

        guard sorted.count > keepCount else { return [] }

        var removed: [URL] = []

        for url in sorted.dropFirst(keepCount) {
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                // Leave it. A backup that cannot be removed is harmless.
                continue
            }
        }

        return removed
    }

    // MARK: Helpers

    /// Keeps letters, numbers, spaces and hyphens, so the reason can
    /// never put a "/" or other odd character in a file name.
    static func safeWords(_ text: String) -> String {

        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -"))

        let cleaned = String(
            text.unicodeScalars.filter { allowed.contains($0) }
        )
        .trimmingCharacters(in: .whitespaces)

        return cleaned.isEmpty ? "change" : String(cleaned.prefix(40))
    }

    /// If a package with this name exists (two backups in the same
    /// second), adds " 2", " 3", … so nothing is overwritten.
    private static func uniqueURL(for url: URL) -> URL {

        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else { return url }

        let base = url.deletingPathExtension()
        let ext = url.pathExtension

        var n = 2

        while true {
            let candidate = URL(fileURLWithPath: "\(base.path) \(n)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
