//
//  TaskStore.swift
//  ResearchBase
//
//  Phase 13B — Tasks
//
//  All task data logic lives here, separate from ResearchDataStore
//  (whose modelContext is private and whose file is already very
//  large). Like ResearchDataStore, it is a plain class that views
//  create on demand from their modelContext:
//
//      let store = TaskStore(modelContext: modelContext)
//
//  Views still use @Query to display tasks and refresh automatically.
//  This class is for changes (create, edit, complete, reopen, delete)
//  and for the pure filter/sort rules the Tasks screen uses.
//

import Foundation
import SwiftData

// MARK: - Filter

enum TaskFilter: String, CaseIterable, Identifiable {

    case all = "All"
    case today = "Today"
    case upcoming = "Upcoming"
    case completed = "Completed"

    var id: String { rawValue }
}


// MARK: - Sort

enum TaskSort: String, CaseIterable, Identifiable {

    case dueDate = "Due Date"
    case priority = "Priority"
    case newest = "Newest"
    case title = "Title"

    var id: String { rawValue }
}


// MARK: - Task Store

final class TaskStore {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }


    // MARK: - Fetch

    func fetchTasks() throws -> [ResearchTask] {
        let descriptor = FetchDescriptor<ResearchTask>()
        return try modelContext.fetch(descriptor)
    }


    // MARK: - Create

    /// Creates and saves a new task. The title is trimmed; an empty
    /// title after trimming is rejected by returning nil so callers
    /// never persist a nameless task.
    @discardableResult
    func createTask(
        title: String,
        descriptionText: String = "",
        priority: ResearchTaskPriority = .medium,
        dueDate: Date? = nil,
        project: ResearchProject? = nil,
        papers: [PaperRecord] = [],
        problems: [ResearchProblem] = [],
        ideas: [ResearchIdea] = [],
        experiments: [Experiment] = [],
        writingDocuments: [WritingDocument] = []
    ) throws -> ResearchTask? {

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let task = ResearchTask(
            title: trimmed,
            descriptionText: descriptionText,
            priorityRawValue: priority.rawValue,
            dueDate: dueDate,
            project: project,
            papers: papers,
            problems: problems,
            ideas: ideas,
            experiments: experiments,
            writingDocuments: writingDocuments
        )

        modelContext.insert(task)
        try modelContext.save()

        return task
    }


    // MARK: - Save Edits

    /// Saves changes made directly to a task's properties (the editor
    /// edits the model). Updates `updatedAt`.
    func saveChanges(to task: ResearchTask) throws {
        task.title = task.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        task.touch()
        try modelContext.save()
    }


    // MARK: - Complete / Reopen

    func complete(_ task: ResearchTask) throws {
        task.markCompleted()
        try modelContext.save()
    }

    func reopen(_ task: ResearchTask) throws {
        task.reopen()
        try modelContext.save()
    }

    /// Completes an open task or reopens a completed one.
    func toggleCompletion(_ task: ResearchTask) throws {
        if task.isCompleted {
            try reopen(task)
        } else {
            try complete(task)
        }
    }


    // MARK: - Delete

    /// Deletes only the task. Linked projects and research objects are
    /// untouched.
    func delete(_ task: ResearchTask) throws {
        modelContext.delete(task)
        try modelContext.save()
    }


    // MARK: - Filtering and Sorting (pure functions)

    /// Applies filter, search text and sort in one pass.
    ///
    /// Filter rules:
    /// - All: every task, completed or not.
    /// - Today: not completed, and due today or overdue.
    /// - Upcoming: not completed, due after today.
    /// - Completed: completed tasks only.
    ///
    /// Tasks with no due date appear under All (and Completed once
    /// done), but not under Today or Upcoming.
    static func apply(
        filter: TaskFilter,
        sort: TaskSort,
        searchText: String,
        to tasks: [ResearchTask]
    ) -> [ResearchTask] {

        let filtered = tasks.filter { task in
            matches(filter: filter, task: task)
                && matches(searchText: searchText, task: task)
        }

        return sorted(filtered, by: sort)
    }

    static func matches(filter: TaskFilter, task: ResearchTask) -> Bool {

        switch filter {

        case .all:
            return true

        case .today:
            guard !task.isCompleted, let due = task.dueDate else {
                return false
            }
            return Calendar.current.startOfDay(for: due)
                <= Calendar.current.startOfDay(for: Date())

        case .upcoming:
            guard !task.isCompleted, let due = task.dueDate else {
                return false
            }
            return Calendar.current.startOfDay(for: due)
                > Calendar.current.startOfDay(for: Date())

        case .completed:
            return task.isCompleted
        }
    }

    static func matches(searchText: String, task: ResearchTask) -> Bool {

        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else { return true }

        return task.title.localizedCaseInsensitiveContains(query)
            || task.descriptionText.localizedCaseInsensitiveContains(query)
            || (task.project?.name.localizedCaseInsensitiveContains(query)
                ?? false)
    }

    static func sorted(
        _ tasks: [ResearchTask],
        by sort: TaskSort
    ) -> [ResearchTask] {

        switch sort {

        case .dueDate:
            // Earliest due first; tasks without a due date last.
            return tasks.sorted { a, b in
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?):
                    if x != y { return x < y }
                    return a.createdAt > b.createdAt
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return a.createdAt > b.createdAt
                }
            }

        case .priority:
            // High first, then earliest due date, then newest.
            return tasks.sorted { a, b in
                if a.priority.rank != b.priority.rank {
                    return a.priority.rank > b.priority.rank
                }
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?) where x != y:
                    return x < y
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return a.createdAt > b.createdAt
                }
            }

        case .newest:
            return tasks.sorted { $0.createdAt > $1.createdAt }

        case .title:
            return tasks.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title)
                    == .orderedAscending
            }
        }
    }


    // MARK: - Counts

    /// Number of tasks matching each filter (ignores search text).
    static func counts(for tasks: [ResearchTask]) -> [TaskFilter: Int] {
        var result: [TaskFilter: Int] = [:]
        for filter in TaskFilter.allCases {
            result[filter] = tasks.filter {
                matches(filter: filter, task: $0)
            }.count
        }
        return result
    }
}
