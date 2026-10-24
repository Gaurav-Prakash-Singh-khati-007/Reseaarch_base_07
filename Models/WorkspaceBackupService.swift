//
//  WorkspaceBackupService.swift
//  ResearchBase
//
//  Phase 13 — Backup
//
//  Creates, reads and verifies `.researchbase` workspace packages.
//
//  Package layout (a folder):
//    manifest.json    format version, counts, checksums, PDF list
//    workspace.json   the WorkspaceSnapshot (all research records)
//    settings.json    the settings that really exist (theme)
//    Papers/          one PDF per paper, named <paperID>.pdf
//
//  Safety rules:
//  - Reads the database, never changes it.
//  - Builds the package in a temporary folder, verifies it, and only
//    then moves it to the chosen location. A failed backup never
//    leaves a half-written package at the destination.
//  - Success is reported only after the written package has been read
//    back and its checksums matched. A backup that cannot be verified
//    throws instead of reporting success.
//  - PDFs that are missing on disk are listed honestly in the result
//    and in the manifest; they are not silently skipped.
//
//  `loadPackage` is shared with Import and Restore, so all three
//  agree on what a valid package is.
//

import Foundation
import SwiftData
import CryptoKit

// MARK: - Errors

nonisolated enum WorkspaceBackupError: LocalizedError {

    case notAPackage
    case missingFile(String)
    case unreadable(String)
    case unsupportedVersion(found: Int)
    case checksumMismatch(String)
    case inconsistent(String)
    case unsafeFileName(String)
    case writeFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {

        case .notAPackage:
            return "This is not a ResearchBase backup folder."

        case .missingFile(let name):
            return "The backup is incomplete: \(name) is missing."

        case .unreadable(let detail):
            return "The backup could not be read. \(detail)"

        case .unsupportedVersion(let found):
            if found > WorkspaceFormat.currentVersion {
                return "This backup was made by a newer version of ResearchBase (format \(found)). Update the app to open it."
            }
            return "This backup uses an old format (\(found)) that this version can no longer read."

        case .checksumMismatch(let name):
            return "\(name) does not match its recorded checksum. The backup may be damaged or was edited."

        case .inconsistent(let detail):
            return "The backup is inconsistent. \(detail)"

        case .unsafeFileName(let name):
            return "The backup contains an unsafe file name (\(name)) and was rejected."

        case .writeFailed(let detail):
            return "The backup could not be written. \(detail)"

        case .verificationFailed(let detail):
            return "The backup was written but failed verification, so it was not kept. \(detail)"
        }
    }
}

// MARK: - Results

nonisolated struct WorkspaceBackupResult {

    let packageURL: URL
    let manifest: WorkspaceManifest

    /// Total size of the package on disk, in bytes.
    let totalBytes: Int64

    var pdfCount: Int { manifest.pdfFiles.count }

    /// Papers that had a PDF path but no file, so no PDF was saved.
    var papersWithMissingPDF: [String] { manifest.papersWithMissingPDF }
}

/// A package that has been read and verified.
nonisolated struct LoadedWorkspacePackage {

    let url: URL
    let manifest: WorkspaceManifest
    let snapshot: WorkspaceSnapshot
    let settings: WorkspaceSettingsDTO?

    /// Non-fatal PDF problems (missing or damaged files). The records
    /// themselves are still usable; the affected papers just come back
    /// without their PDF.
    let pdfProblems: [String]

    /// The PDF file inside the package for a paper, if it is present
    /// and was not reported as a problem.
    func pdfURL(for paper: PaperDTO) -> URL? {

        guard let name = paper.pdfFileName else { return nil }

        let fileURL = url
            .appendingPathComponent(WorkspaceFormat.papersFolderName, isDirectory: true)
            .appendingPathComponent(name)

        guard FileManager.default.fileExists(atPath: fileURL.path),
              !damagedPDFNames.contains(name)
        else { return nil }

        return fileURL
    }

    /// File names that failed their checksum or size check.
    let damagedPDFNames: Set<String>
}

// MARK: - Service

nonisolated enum WorkspaceBackupService {

    // MARK: Locations

    /// Where automatic safety backups (made before a restore) live.
    static var automaticBackupsDirectory: URL {

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return appSupport
            .appendingPathComponent("ResearchBase", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// A readable default file name, e.g.
    /// "ResearchBase Backup 2026-09-28 14-05.researchbase".
    static func suggestedFileName(
        prefix: String = "ResearchBase Backup",
        date: Date = Date()
    ) -> String {

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"

        return "\(prefix) \(formatter.string(from: date)).\(WorkspaceFormat.packageExtension)"
    }

    // MARK: Create

    /// Backs up the whole workspace to `destination`.
    ///
    /// The database is read on the main actor. Copying PDFs and
    /// writing files happen off the main actor so the UI stays
    /// responsive.
    @MainActor
    static func createBackup(
        context: ModelContext,
        to destination: URL,
        profile: ProfileStore? = nil
    ) async throws -> WorkspaceBackupResult {

        let capture = try WorkspaceSnapshot.capture(from: context)

        // Phase 14: text size and accent come from the same stores
        // AppearanceSettings mirrors. The name comes from ProfileStore;
        // without one (nil), no name is written.
        let settings = WorkspaceSettingsDTO(
            theme: RBThemeStore.currentID.rawValue,
            displayName: profile?.displayName,
            textScale: RBTextScale.current,
            accentOverrideHex: RBThemeStore.accentOverrideHex
        )

        let target = normalizedDestination(destination)
        let snapshot = capture.snapshot
        let sources = capture.pdfSources
        let missing = capture.missingPDFTitles

        return try await Task.detached(priority: .userInitiated) {
            try writePackage(
                snapshot: snapshot,
                settings: settings,
                pdfSources: sources,
                missingPDFTitles: missing,
                destination: target
            )
        }.value
    }

    /// Makes sure the destination ends in `.researchbase`.
    private static func normalizedDestination(_ url: URL) -> URL {

        if url.pathExtension.lowercased() == WorkspaceFormat.packageExtension {
            return url
        }

        return url.appendingPathExtension(WorkspaceFormat.packageExtension)
    }

    // MARK: Write

    private static func writePackage(
        snapshot: WorkspaceSnapshot,
        settings: WorkspaceSettingsDTO,
        pdfSources: [WorkspaceSnapshot.Capture.PDFSource],
        missingPDFTitles: [String],
        destination: URL
    ) throws -> WorkspaceBackupResult {

        let fm = FileManager.default

        let staging = fm.temporaryDirectory
            .appendingPathComponent(
                "ResearchBase-Backup-\(UUID().uuidString)",
                isDirectory: true
            )

        let papersFolder = staging.appendingPathComponent(
            WorkspaceFormat.papersFolderName,
            isDirectory: true
        )

        do {
            try fm.createDirectory(
                at: papersFolder,
                withIntermediateDirectories: true
            )
        } catch {
            throw WorkspaceBackupError.writeFailed(error.localizedDescription)
        }

        // Whatever happens, do not leave the staging folder behind.
        // After a successful move it no longer exists, which is fine.
        defer { try? fm.removeItem(at: staging) }

        let encoder = WorkspaceJSON.makeEncoder()

        // workspace.json

        let workspaceData: Data

        do {
            workspaceData = try encoder.encode(snapshot)

            try workspaceData.write(
                to: staging.appendingPathComponent(WorkspaceFormat.workspaceFileName),
                options: .atomic
            )
        } catch {
            throw WorkspaceBackupError.writeFailed(error.localizedDescription)
        }

        let workspaceHash = sha256Hex(of: workspaceData)

        // Papers/

        var pdfEntries: [WorkspaceManifest.PDFFileEntry] = []

        for source in pdfSources {

            let destinationFile = papersFolder
                .appendingPathComponent(source.packageFileName)

            do {
                try fm.copyItem(at: source.sourceURL, to: destinationFile)

                let hash = try sha256Hex(ofFileAt: destinationFile)
                let size = try fileSize(at: destinationFile)

                pdfEntries.append(
                    WorkspaceManifest.PDFFileEntry(
                        paperID: source.paperID,
                        fileName: source.packageFileName,
                        byteCount: size,
                        sha256: hash
                    )
                )

            } catch {
                // A PDF that was there a moment ago could not be
                // copied. Fail the whole backup rather than quietly
                // producing one that lacks a file it claims to have.
                throw WorkspaceBackupError.writeFailed(
                    "Could not copy a PDF (\(source.sourceURL.lastPathComponent)): \(error.localizedDescription)"
                )
            }
        }

        // settings.json

        do {
            let settingsData = try encoder.encode(settings)

            try settingsData.write(
                to: staging.appendingPathComponent(WorkspaceFormat.settingsFileName),
                options: .atomic
            )
        } catch {
            throw WorkspaceBackupError.writeFailed(error.localizedDescription)
        }

        // manifest.json (written last, so its presence means the rest
        // of the package was written)

        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceFormat.currentVersion,
            oldestReadableVersion: WorkspaceFormat.oldestReadableVersion,
            appName: "ResearchBase",
            appVersion: appVersionString(),
            createdAt: Date(),
            entityCounts: snapshot.entityCounts,
            workspaceSHA256: workspaceHash,
            pdfFiles: pdfEntries,
            papersWithMissingPDF: missingPDFTitles
        )

        do {
            let manifestData = try encoder.encode(manifest)

            try manifestData.write(
                to: staging.appendingPathComponent(WorkspaceFormat.manifestFileName),
                options: .atomic
            )
        } catch {
            throw WorkspaceBackupError.writeFailed(error.localizedDescription)
        }

        // Verify what was actually written, before it goes anywhere
        // the user will trust it.

        do {
            let loaded = try loadPackage(at: staging, verifyPDFs: true)

            if !loaded.pdfProblems.isEmpty {
                throw WorkspaceBackupError.verificationFailed(
                    loaded.pdfProblems.joined(separator: " ")
                )
            }

            if loaded.snapshot.entityCounts != snapshot.entityCounts {
                throw WorkspaceBackupError.verificationFailed(
                    "Record counts changed while writing."
                )
            }
        } catch let error as WorkspaceBackupError {
            switch error {
            case .verificationFailed:
                throw error
            default:
                throw WorkspaceBackupError.verificationFailed(
                    error.localizedDescription
                )
            }
        }

        // Move into place.

        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            throw WorkspaceBackupError.writeFailed(error.localizedDescription)
        }

        // Final check that the manifest is readable where it now lives.

        guard fm.fileExists(
            atPath: destination
                .appendingPathComponent(WorkspaceFormat.manifestFileName).path
        ) else {
            throw WorkspaceBackupError.verificationFailed(
                "The backup is not at the chosen location."
            )
        }

        return WorkspaceBackupResult(
            packageURL: destination,
            manifest: manifest,
            totalBytes: directorySize(at: destination)
        )
    }

    // MARK: Load / Verify

    /// Reads and verifies a package. Throws for anything that makes the
    /// package unusable (not a package, unsupported version, damaged
    /// workspace.json, inconsistent counts, unsafe file names).
    /// Missing or damaged PDFs are not fatal; they are returned in
    /// `pdfProblems` so the caller can report them.
    ///
    /// Read-only. Creates and changes nothing.
    static func loadPackage(
        at url: URL,
        verifyPDFs: Bool = true
    ) throws -> LoadedWorkspacePackage {

        let fm = FileManager.default

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WorkspaceBackupError.notAPackage
        }

        let decoder = WorkspaceJSON.makeDecoder()

        // manifest

        let manifestURL = url.appendingPathComponent(WorkspaceFormat.manifestFileName)

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw WorkspaceBackupError.notAPackage
        }

        let manifest: WorkspaceManifest

        do {
            manifest = try decoder.decode(
                WorkspaceManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw WorkspaceBackupError.unreadable(
                "manifest.json could not be decoded (\(error.localizedDescription))."
            )
        }

        guard manifest.appName == "ResearchBase" else {
            throw WorkspaceBackupError.notAPackage
        }

        guard manifest.formatVersion <= WorkspaceFormat.currentVersion,
              manifest.formatVersion >= WorkspaceFormat.oldestReadableVersion
        else {
            throw WorkspaceBackupError.unsupportedVersion(
                found: manifest.formatVersion
            )
        }

        // workspace.json

        let workspaceURL = url.appendingPathComponent(WorkspaceFormat.workspaceFileName)

        guard fm.fileExists(atPath: workspaceURL.path) else {
            throw WorkspaceBackupError.missingFile(WorkspaceFormat.workspaceFileName)
        }

        let workspaceData: Data

        do {
            workspaceData = try Data(contentsOf: workspaceURL)
        } catch {
            throw WorkspaceBackupError.unreadable(error.localizedDescription)
        }

        guard sha256Hex(of: workspaceData) == manifest.workspaceSHA256 else {
            throw WorkspaceBackupError.checksumMismatch(WorkspaceFormat.workspaceFileName)
        }

        let snapshot: WorkspaceSnapshot

        do {
            snapshot = try decoder.decode(WorkspaceSnapshot.self, from: workspaceData)
        } catch {
            throw WorkspaceBackupError.unreadable(
                "workspace.json could not be decoded (\(error.localizedDescription))."
            )
        }

        guard snapshot.entityCounts == manifest.entityCounts else {
            throw WorkspaceBackupError.inconsistent(
                "The record counts in the manifest do not match workspace.json."
            )
        }

        // settings.json (optional; a damaged settings file must not
        // block getting research data back)

        var settings: WorkspaceSettingsDTO?

        let settingsURL = url.appendingPathComponent(WorkspaceFormat.settingsFileName)

        if fm.fileExists(atPath: settingsURL.path) {
            settings = try? decoder.decode(
                WorkspaceSettingsDTO.self,
                from: Data(contentsOf: settingsURL)
            )
        }

        // File names must be plain names inside Papers/. This rejects
        // anything that tries to point outside the package.

        for entry in manifest.pdfFiles {
            guard isPlainFileName(entry.fileName) else {
                throw WorkspaceBackupError.unsafeFileName(entry.fileName)
            }
        }

        for paper in snapshot.papers {
            if let name = paper.pdfFileName, !isPlainFileName(name) {
                throw WorkspaceBackupError.unsafeFileName(name)
            }
        }

        // PDFs

        var problems: [String] = []
        var damaged = Set<String>()

        let papersFolder = url.appendingPathComponent(
            WorkspaceFormat.papersFolderName,
            isDirectory: true
        )

        let entriesByName = Dictionary(
            manifest.pdfFiles.map { ($0.fileName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for paper in snapshot.papers {

            guard let name = paper.pdfFileName else { continue }

            let title = paper.title.isEmpty ? "Untitled paper" : paper.title

            guard let entry = entriesByName[name] else {
                problems.append("\"\(title)\": its PDF is not listed in the manifest.")
                damaged.insert(name)
                continue
            }

            let fileURL = papersFolder.appendingPathComponent(name)

            guard fm.fileExists(atPath: fileURL.path) else {
                problems.append("\"\(title)\": its PDF file is missing from the backup.")
                damaged.insert(name)
                continue
            }

            if verifyPDFs {

                do {
                    let size = try fileSize(at: fileURL)
                    let hash = try sha256Hex(ofFileAt: fileURL)

                    if size != entry.byteCount || hash != entry.sha256 {

                        problems.append("\"\(title)\": its PDF is damaged (checksum mismatch).")
                        damaged.insert(name)
                    }
                } catch {
                    problems.append("\"\(title)\": its PDF could not be read.")
                    damaged.insert(name)
                }
            }
        }

        return LoadedWorkspacePackage(
            url: url,
            manifest: manifest,
            snapshot: snapshot,
            settings: settings,
            pdfProblems: problems,
            damagedPDFNames: damaged
        )
    }

    // MARK: Helpers

    /// True for a simple file name with no folders and no `..`.
    static func isPlainFileName(_ name: String) -> Bool {

        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("\0")
        else { return false }

        return true
    }

    private static func appVersionString() -> String {

        let info = Bundle.main.infoDictionary

        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String

        if let build { return "\(version) (\(build))" }

        return version
    }

    private static func fileSize(at url: URL) throws -> Int64 {

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directorySize(at url: URL) -> Int64 {

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0

        for case let fileURL as URL in enumerator {

            let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )

            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }

        return total
    }

    private static func sha256Hex(of data: Data) -> String {

        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Streams the file, so large PDFs are not loaded into memory.
    private static func sha256Hex(ofFileAt url: URL) throws -> String {

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {

            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()

            if chunk.isEmpty { break }

            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
