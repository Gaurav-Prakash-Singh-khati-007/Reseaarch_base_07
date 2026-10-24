//
//  ChangeSink.swift
//  ResearchBase
//
//  Phase 1, Step 1B  (the hook Step 1C fills in)
//
//  Every write in the data model reports what it did to a `ChangeSink`.
//  Step 1B ships only `NullChangeSink` (does nothing). Step 1C supplies a
//  sink that writes the `changes` table with a `batch_id`, which is what
//  makes history and undo possible. Because the model already reports
//  every change, 1C does not have to rewrite the model.
//
//  Two kinds of removal exist here, and the sink must be able to undo both:
//    * rows that have no `deleted_at` in schema.sql (links, tag
//      assignments, folder membership, creator lists, tags, creators):
//      the removal is reported with the old value, so it can be restored;
//    * merges: reported with action `.merge` and the merged-away record.
//

import Foundation

enum ChangeAction: String, Equatable {
    case create, update, delete, restore, merge
    case importRecord = "import"
}

protocol ChangeSink: AnyObject {

    /// Called inside the same transaction as the change itself. If the
    /// sink throws, the whole change is undone.
    func record(
        entityType: String,
        entityID: String,
        action: ChangeAction,
        field: String?,
        oldValue: String?,
        newValue: String?
    ) throws
}

final class NullChangeSink: ChangeSink {
    func record(
        entityType: String,
        entityID: String,
        action: ChangeAction,
        field: String?,
        oldValue: String?,
        newValue: String?
    ) throws {}
}
