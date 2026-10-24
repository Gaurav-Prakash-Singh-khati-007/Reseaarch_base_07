//
//  PDFNoteStorage.swift
//  ResearchBase
//
//  Created by Gaurav Khati on 27/09/26.
//


import Foundation

enum PDFNoteStorage {

    // =========================================================
    // FILE URL
    // =========================================================

    static func storageURL(
        for pdfURL: URL
    ) -> URL {

        pdfURL.appendingPathExtension(
            "researchbase-notes.json"
        )
    }

    // =========================================================
    // LOAD
    // =========================================================

    static func loadNotes(
        for pdfURL: URL
    ) -> [PDFNote] {

        let fileURL =
            storageURL(
                for: pdfURL
            )

        guard
            FileManager.default.fileExists(
                atPath: fileURL.path
            )
        else {

            return []
        }

        do {

            let data =
                try Data(
                    contentsOf: fileURL
                )

            let decoder =
                JSONDecoder()

            let notes =
                try decoder.decode(
                    [PDFNote].self,
                    from: data
                )

            return notes

        } catch {

            Swift.print(
                "❌ Could not load PDF notes:"
            )

            Swift.print(
                error.localizedDescription
            )

            return []
        }
    }

    // =========================================================
    // SAVE
    // =========================================================

    static func saveNotes(
        _ notes: [PDFNote],
        for pdfURL: URL
    ) {

        let fileURL =
            storageURL(
                for: pdfURL
            )

        do {

            let encoder =
                JSONEncoder()

            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys
            ]

            let data =
                try encoder.encode(
                    notes
                )

            try data.write(
                to: fileURL,
                options: .atomic
            )

            Swift.print(
                "✅ PDF notes saved:"
            )

            Swift.print(
                fileURL.path
            )

        } catch {

            Swift.print(
                "❌ Could not save PDF notes:"
            )

            Swift.print(
                error.localizedDescription
            )
        }
    }
}
