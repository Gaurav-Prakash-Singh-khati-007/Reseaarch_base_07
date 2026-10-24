//
//  SafetyBatchTracker.swift
//  ResearchBase
//
//  Phase 1, Step 1C-1 (F-12)
//
//  Remembers which `batch_id` the next change belongs to. One user action
//  (for example "merge two tags") may report many changes; they all get the
//  same batch id so Undo can take them back together.
//
//  Batches can nest. The outermost `begin` decides the id; inner calls join it.
//

import Foundation

final class SafetyBatchTracker {

    /// The id of the open batch, or nil when none is open.
    private(set) var currentID: String?

    private var depth = 0

    var isOpen: Bool { depth > 0 }

    /// Opens a batch (or joins the open one) and returns the batch id in force.
    @discardableResult
    func begin(id: String = UUID().uuidString) -> String {
        if depth == 0 { currentID = id }
        depth += 1
        return currentID ?? id
    }

    /// Closes one level. An extra `end` with nothing open does nothing.
    func end() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 { currentID = nil }
    }
}
