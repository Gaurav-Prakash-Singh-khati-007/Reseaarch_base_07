//
//  AttachmentStore.swift
//  ResearchBase
//
//  Phase 1, Step 1B (F-10)
//
//  Several files per paper (PDF, supplement, code, slides, data ...).
//
//    * A file is stored by its SHA-256 fingerprint:
//        files/<first two hex digits>/<64 hex digits>.<extension>
//      The path in the database is relative to the library folder.
//    * The same file added to many papers (or twice to one paper) is
//      stored on disk ONCE.
//    * A stored file is never overwritten. If a file with that name
//      already exists but its content does not match the fingerprint,
//      nothing is changed and `.storedFileDamaged` is thrown.
//    * The copy goes to a temporary name first and is checked before it
//      gets its real name, so a power cut leaves no half file under a real name.
//    * Removing an attachment (Trash) is Step 1C. Nothing here deletes a file.
//

import Foundation
import CryptoKit

final class AttachmentStore {

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    // MARK: Add

    /// Adds a file to an item.
    ///
    /// - Adding the same file to the same item again returns the existing attachment
    ///   (and brings it back if it was in the Trash). No second row, no second copy.
    /// - `makePrimary`: nil = the first PDF of an item becomes its primary file automatically.
    @discardableResult
    func add(
        fileAt source: URL,
        to itemID: String,
        kind: AttachmentKind = .pdf,
        label: String = "",
        makePrimary: Bool? = nil
    ) throws -> Attachment {

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw ModelError.fileMissing(source.lastPathComponent)
        }

        guard try model.items.fetch(id: itemID) != nil else {
            throw ModelError.notFound(kind: "paper", id: itemID)
        }

        // 1. Fingerprint and size of the source.
        let sha = try Self.sha256Hex(of: source)
        let attributes = try? fileManager.attributesOfItem(atPath: source.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let fileExtension = source.pathExtension.lowercased()
        let relativePath = Self.relativePath(sha256: sha, fileExtension: fileExtension)
        let destination = try model.library.url(forRelativePath: relativePath)

        // 2. Put the file on disk (outside the database transaction).
        try store(source: source, destination: destination, sha256: sha)

        // 3. Record it.
        return try model.atomically {

            let now = model.now()

            if let row = try model.database.rows(
                "SELECT * FROM attachments WHERE item_id = ? AND sha256 = ?", [.text(itemID), .text(sha)]
            ).first {
                var existing = try Self.attachment(from: row)
                if existing.deletedAt != nil {
                    try model.database.run("UPDATE attachments SET deleted_at = NULL WHERE id = ?", [.text(existing.id)])
                    try model.record("attachment", existing.id, .restore, field: "deleted_at", old: existing.deletedAt, new: nil)
                    existing.deletedAt = nil
                }
                if makePrimary == true, !existing.isPrimary {
                    try setPrimary(attachmentID: existing.id)
                    existing.isPrimary = true
                }
                return existing
            }

            let id = model.newID()

            let hasPrimary = (try model.database.scalarInt(
                "SELECT COUNT(*) FROM attachments WHERE item_id = ? AND is_primary = 1 AND deleted_at IS NULL",
                [.text(itemID)]
            ) ?? 0) > 0
            let primary = makePrimary ?? (kind == .pdf && !hasPrimary)

            try model.database.run(
                """
                INSERT INTO attachments (id, item_id, kind, is_primary, label, sha256, rel_path, original_name, bytes, added_at)
                VALUES (?, ?, ?, 0, ?, ?, ?, ?, ?, ?)
                """,
                [.text(id), .text(itemID), .text(kind.rawValue), .text(label), .text(sha),
                 .text(relativePath), .text(source.lastPathComponent), .int(bytes), .text(now)]
            )
            if primary {
                try setPrimary(attachmentID: id)
            }
            try model.record("attachment", id, .create, field: "file", new: relativePath)

            guard let row = try model.database.rows("SELECT * FROM attachments WHERE id = ?", [.text(id)]).first else {
                throw ModelError.notFound(kind: "attachment", id: id)
            }
            return try Self.attachment(from: row)
        }
    }

    // MARK: Read

    /// Files of an item: the primary file first, then oldest first.
    func attachments(of itemID: String, includeDeleted: Bool = false) throws -> [Attachment] {
        let sql = "SELECT * FROM attachments WHERE item_id = ?"
            + (includeDeleted ? "" : " AND deleted_at IS NULL")
            + " ORDER BY is_primary DESC, added_at, id"
        return try model.database.rows(sql, [.text(itemID)]).map { try Self.attachment(from: $0) }
    }

    func attachment(id: String) throws -> Attachment? {
        guard let row = try model.database.rows("SELECT * FROM attachments WHERE id = ?", [.text(id)]).first else {
            return nil
        }
        return try Self.attachment(from: row)
    }

    /// Where the file lives now. Always inside the library folder.
    func fileURL(for attachment: Attachment) throws -> URL {
        try model.library.url(forRelativePath: attachment.relativePath)
    }

    /// True when the stored file exists and its content still matches the fingerprint.
    func verify(_ attachment: Attachment) throws -> Bool {
        let url = try fileURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try Self.sha256Hex(of: url) == attachment.sha256
    }

    /// How many attachment rows (any item, any state) use this fingerprint.
    /// More than one row with ONE file on disk is the "stored once" rule at work.
    func rowCount(sha256: String) throws -> Int {
        Int(try model.database.scalarInt("SELECT COUNT(*) FROM attachments WHERE sha256 = ?", [.text(sha256)]) ?? 0)
    }

    // MARK: Primary file

    /// Makes one attachment the primary file of its item (and clears the others).
    func setPrimary(attachmentID: String) throws {
        try model.atomically {
            guard let target = try attachment(id: attachmentID) else {
                throw ModelError.notFound(kind: "attachment", id: attachmentID)
            }
            try model.database.run(
                "UPDATE attachments SET is_primary = 0 WHERE item_id = ? AND id != ? AND is_primary = 1",
                [.text(target.itemID), .text(attachmentID)]
            )
            if !target.isPrimary {
                try model.database.run("UPDATE attachments SET is_primary = 1 WHERE id = ?", [.text(attachmentID)])
                try model.record("attachment", attachmentID, .update, field: "is_primary", old: "0", new: "1")
            }
        }
    }

    // MARK: Files on disk

    /// Path under the library folder: files/ab/ab12....pdf
    static func relativePath(sha256: String, fileExtension: String) -> String {
        let folder = String(sha256.prefix(2))
        let name = fileExtension.isEmpty ? sha256 : "\(sha256).\(fileExtension)"
        return "files/\(folder)/\(name)"
    }

    /// Copies `source` to `destination` unless a correct copy is already there.
    private func store(source: URL, destination: URL, sha256: String) throws {

        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destination.path) {
            // Already stored. Make sure it is really that file, and never touch it.
            guard (try? Self.sha256Hex(of: destination)) == sha256 else {
                throw ModelError.storedFileDamaged(destination.lastPathComponent)
            }
            return
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")

        do {
            try fileManager.copyItem(at: source, to: temporary)

            guard try Self.sha256Hex(of: temporary) == sha256 else {
                // The source changed while it was being copied.
                throw ModelError.fileUnreadable(source.lastPathComponent)
            }
            try fileManager.moveItem(at: temporary, to: destination)

        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// SHA-256 of a file as 64 lower-case hex digits. Reads in 1 MB pieces.
    static func sha256Hex(of url: URL) throws -> String {

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelError.fileUnreadable(url.lastPathComponent)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                throw ModelError.fileUnreadable(url.lastPathComponent)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Row mapping

    static func attachment(from row: SQLRow) throws -> Attachment {
        guard let id = row.text("id"),
              let itemID = row.text("item_id"),
              let kindText = row.text("kind"),
              let kind = AttachmentKind(rawValue: kindText),
              let sha = row.text("sha256"),
              let path = row.text("rel_path") else {
            throw ModelError.invalidValue("attachment row")
        }
        return Attachment(
            id: id,
            itemID: itemID,
            kind: kind,
            isPrimary: (row.int("is_primary") ?? 0) != 0,
            label: row.text("label") ?? "",
            sha256: sha,
            relativePath: path,
            originalName: row.text("original_name") ?? "",
            bytes: row.int("bytes") ?? 0,
            pages: row.int("pages").map { Int($0) },
            addedAt: row.text("added_at") ?? "",
            deletedAt: row.text("deleted_at")
        )
    }
}
