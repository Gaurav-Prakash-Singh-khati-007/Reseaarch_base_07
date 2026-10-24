//
//  PaperStorage.swift
//  ResearchBase
//
//  Central storage for imported research PDFs.
//

import Foundation

final class PaperStorage {

    static let shared =
        PaperStorage()

    private init() {}

    // =========================================================
    // MARK: - Papers Directory
    // =========================================================

    private var papersDirectory: URL {

        let appSupport =
            FileManager.default.urls(
                for:
                    .applicationSupportDirectory,
                in:
                    .userDomainMask
            )[0]

        let researchBaseDirectory =
            appSupport.appendingPathComponent(
                "ResearchBase",
                isDirectory: true
            )

        return researchBaseDirectory
            .appendingPathComponent(
                "Papers",
                isDirectory: true
            )
    }

    // =========================================================
    // MARK: - Prepare Storage
    // =========================================================

    func prepareStorage() throws {

        try FileManager.default.createDirectory(
            at:
                papersDirectory,

            withIntermediateDirectories:
                true,

            attributes:
                nil
        )
    }

    // =========================================================
    // MARK: - Check Managed PDF
    // =========================================================

    /// Returns true only when the supplied URL is located
    /// inside ResearchBase's managed Papers directory.
    ///
    /// This protects user-selected external files from being
    /// accidentally deleted when a PDF is replaced.
    func isManagedPaperFile(
        _ url: URL
    ) -> Bool {

        let directoryPath =
            papersDirectory
                .standardizedFileURL
                .path

        let filePath =
            url
                .standardizedFileURL
                .path

        guard filePath != directoryPath else {
            return false
        }

        let directoryPrefix =
            directoryPath.hasSuffix("/")
            ? directoryPath
            : directoryPath + "/"

        return filePath.hasPrefix(
            directoryPrefix
        )
    }

    // =========================================================
    // MARK: - Import PDF
    // =========================================================

    func importPDF(
        from sourceURL: URL
    ) throws -> URL {

        try prepareStorage()

        let hasSecurityScopedAccess =
            sourceURL
                .startAccessingSecurityScopedResource()

        defer {

            if hasSecurityScopedAccess {

                sourceURL
                    .stopAccessingSecurityScopedResource()
            }
        }

        let destinationURL =
            papersDirectory
                .appendingPathComponent(
                    "\(UUID().uuidString).pdf"
                )

        try FileManager.default.copyItem(
            at:
                sourceURL,

            to:
                destinationURL
        )

        Swift.print(
            "ResearchBase: PDF imported."
        )

        Swift.print(
            "ResearchBase: \(destinationURL.path)"
        )

        return destinationURL
    }

    // =========================================================
    // MARK: - Delete PDF
    // =========================================================

    func deletePDF(
        at url: URL
    ) throws {

        guard
            FileManager.default.fileExists(
                atPath:
                    url.path
            )
        else {
            return
        }

        try FileManager.default.removeItem(
            at:
                url
        )
    }
}
