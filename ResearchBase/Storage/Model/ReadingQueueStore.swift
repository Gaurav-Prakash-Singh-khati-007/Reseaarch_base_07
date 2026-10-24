//
//  ReadingQueueStore.swift
//  ResearchBase
//
//  Owner: Agent 16 · Features: F-28 (reading queue, reading status, reading time)
//
//  The to-read list, a paper's reading status, and reading time / last page.
//
//  Where things live (the schema is frozen):
//    * `items.in_queue`, `items.reading_status`  -> changed through `ItemStore.update`,
//      so every change is validated and reported to the change sink.
//    * `items.reading_seconds`, `items.last_page` -> updated here with plain SQL.
//      They change every few seconds while reading, so they are NOT reported to
//      the change sink and do NOT touch `updated_at`.
//    * The ORDER of the queue has no column. It is kept as a JSON list of item ids
//      in `meta` under the key `reading_queue.order`. Queued items missing from
//      that list (for example after a restore) sort after it, oldest added first.
//
//  Rules:
//    * Trashed items and items still in the Inbox are never shown in the queue or counted.
//    * Marking a paper "read" takes it off the queue, unless `keepInQueue: true`.
//    * Reading time is stored as a total only; there is no per-day table, so
//      "time read this week" cannot be answered (see report: BLOCKED).
//
//  PUBLIC API
//    ReadingQueueStore(model:)
//      add(itemID:) / remove(itemID:) / move(itemID:toIndex:)
//      queue() -> [ModelItem]            in queue order
//      queueCount() -> Int
//      isQueued(itemID:) -> Bool
//      setStatus(itemID:_:keepInQueue:) -> ModelItem
//      recordReading(itemID:seconds:page:) -> adds time, remembers the page, unread -> reading
//      readingSeconds(itemID:) / lastPage(itemID:)
//      stats() -> ReadingStats
//      readCount(since:) -> Int          papers marked read since a date (needs the SQL change log)
//    ReadingStats                       unread, reading, read, queued, totalSeconds
//

import Foundation

struct ReadingStats: Equatable {
    var unread: Int
    var reading: Int
    var read: Int
    var queued: Int
    var totalSeconds: Int

    var total: Int { unread + reading + read }
}

final class ReadingQueueStore {

    static let orderKey = "reading_queue.order"
    /// One report of reading time may not claim more than a day.
    static let maxSecondsPerReport = 86_400

    unowned let model: LibraryModel

    init(model: LibraryModel) {
        self.model = model
    }

    private var db: LibraryDatabase { model.database }

    // MARK: Queue

    func add(itemID: String) throws {
        try model.atomically {
            guard let item = try model.items.fetch(id: itemID) else {
                throw ModelError.notFound(kind: "paper", id: itemID)
            }
            if !item.inQueue {
                try model.items.update(id: itemID) { $0.inQueue = true }
            }
            var order = try storedOrder()
            order.removeAll { $0 == itemID }
            order.append(itemID)
            try saveOrder(order)
        }
    }

    func remove(itemID: String) throws {
        try model.atomically {
            guard let item = try model.items.fetch(id: itemID) else {
                throw ModelError.notFound(kind: "paper", id: itemID)
            }
            if item.inQueue {
                try model.items.update(id: itemID) { $0.inQueue = false }
            }
            var order = try storedOrder()
            order.removeAll { $0 == itemID }
            try saveOrder(order)
        }
    }

    /// Moves a queued paper to a new position (0 = first). Out-of-range positions clamp to the ends.
    func move(itemID: String, toIndex: Int) throws {
        try model.atomically {
            var ids = try queue().map(\.id)
            guard let from = ids.firstIndex(of: itemID) else {
                throw ModelError.notFound(kind: "queued paper", id: itemID)
            }
            ids.remove(at: from)
            ids.insert(itemID, at: min(max(toIndex, 0), ids.count))
            try saveOrder(ids)
        }
    }

    /// The reading queue, in order. Trash and Inbox items are left out.
    func queue() throws -> [ModelItem] {

        let items = try db.rows(
            "SELECT * FROM items WHERE in_queue = 1 AND deleted_at IS NULL AND review_state = 'accepted' ORDER BY added_at, id"
        ).map { try ItemStore.item(from: $0) }

        let position = Dictionary(uniqueKeysWithValues: try storedOrder().enumerated().map { ($1, $0) })

        // Stable: listed ids by saved position, the rest after them in added_at order.
        return items.enumerated().sorted { left, right in
            let l = position[left.element.id] ?? Int.max
            let r = position[right.element.id] ?? Int.max
            return l != r ? l < r : left.offset < right.offset
        }.map(\.element)
    }

    func queueCount() throws -> Int {
        Int(try db.scalarInt(
            "SELECT COUNT(*) FROM items WHERE in_queue = 1 AND deleted_at IS NULL AND review_state = 'accepted'") ?? 0)
    }

    func isQueued(itemID: String) throws -> Bool {
        (try db.scalarInt("SELECT in_queue FROM items WHERE id = ? AND deleted_at IS NULL", [.text(itemID)]) ?? 0) != 0
    }

    // MARK: Status

    /// Sets unread / reading / read. "Read" also takes the paper off the queue unless `keepInQueue` is true.
    @discardableResult
    func setStatus(itemID: String, _ status: ItemReadingStatus, keepInQueue: Bool = false) throws -> ModelItem {
        try model.atomically {
            guard try model.items.fetch(id: itemID) != nil else {
                throw ModelError.notFound(kind: "paper", id: itemID)
            }
            let updated = try model.items.update(id: itemID) {
                $0.readingStatus = status
                if status == .read && !keepInQueue { $0.inQueue = false }
            }
            if !updated.inQueue {
                var order = try storedOrder()
                if order.contains(itemID) {
                    order.removeAll { $0 == itemID }
                    try saveOrder(order)
                }
            }
            return updated
        }
    }

    // MARK: Reading time and place

    /// Adds reading time and remembers the page. An unread paper becomes "reading".
    /// Trashed papers are ignored. Does not touch `updated_at` and is not reported to the change sink.
    func recordReading(itemID: String, seconds: Int, page: Int? = nil) throws {

        guard (0...Self.maxSecondsPerReport).contains(seconds) else { throw ModelError.invalidValue("reading time") }
        if let page, page < 1 { throw ModelError.invalidValue("page") }

        try model.atomically {
            guard let item = try model.items.fetch(id: itemID) else {
                throw ModelError.notFound(kind: "paper", id: itemID)
            }
            try db.run(
                "UPDATE items SET reading_seconds = reading_seconds + ?, last_page = COALESCE(?, last_page) WHERE id = ?",
                [.int(Int64(seconds)), LibraryModel.int(page), .text(itemID)]
            )
            if item.readingStatus == .unread {
                try model.items.update(id: itemID) { $0.readingStatus = .reading }
            }
        }
    }

    func readingSeconds(itemID: String) throws -> Int {
        Int(try db.scalarInt("SELECT reading_seconds FROM items WHERE id = ?", [.text(itemID)]) ?? 0)
    }

    /// The page to reopen at. 1 when never read.
    func lastPage(itemID: String) throws -> Int {
        Int(try db.scalarInt("SELECT last_page FROM items WHERE id = ?", [.text(itemID)]) ?? 1)
    }

    // MARK: Stats

    func stats() throws -> ReadingStats {

        var stats = ReadingStats(unread: 0, reading: 0, read: 0, queued: 0, totalSeconds: 0)

        let rows = try db.rows(
            """
            SELECT reading_status AS status, COUNT(*) AS n, SUM(reading_seconds) AS seconds, SUM(in_queue) AS queued
            FROM items WHERE deleted_at IS NULL AND review_state = 'accepted' GROUP BY reading_status
            """)

        for row in rows {
            let n = Int(row.int("n") ?? 0)
            switch row.text("status") {
            case "unread": stats.unread = n
            case "reading": stats.reading = n
            case "read": stats.read = n
            default: break
            }
            stats.queued += Int(row.int("queued") ?? 0)
            stats.totalSeconds += Int(row.int("seconds") ?? 0)
        }
        return stats
    }

    /// Papers marked "read" since `date`, counted from the change log (needs the SQL change sink
    /// that the app uses; with a null sink the answer is 0). A paper counts once.
    func readCount(since date: Date) throws -> Int {
        Int(try db.scalarInt(
            """
            SELECT COUNT(DISTINCT c.entity_id) FROM changes c JOIN items i ON i.id = c.entity_id
            WHERE c.entity_type = 'item' AND c.field = 'reading_status' AND c.new_value = 'read'
              AND c.at >= ? AND i.deleted_at IS NULL AND i.reading_status = 'read'
            """, [.text(Library.nowISO(date))]) ?? 0)
    }

    // MARK: Private

    private func storedOrder() throws -> [String] {
        guard let json = try db.scalarText("SELECT value FROM meta WHERE key = ?", [.text(Self.orderKey)]),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    private func saveOrder(_ ids: [String]) throws {
        guard let data = try? JSONEncoder().encode(ids), let json = String(data: data, encoding: .utf8) else { return }
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(Self.orderKey), .text(json)])
    }
}
