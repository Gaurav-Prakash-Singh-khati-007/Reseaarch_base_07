//
//  ResearchTask.swift
//  ResearchBase
//
//  Phase 13B — Tasks
//
//  Introduces ResearchTask. This is the only new model type Phase 13
//  adds to the persistence layer, and it is purely additive: no
//  existing model changes, so existing data migrates automatically.
//
//  A task can point at a project and at existing research objects, but
//  it never owns them and never deletes them. This follows the same
//  "plain, unidirectional link — references but never owns" pattern
//  as ResearchProject, Experiment and WritingDocument: no
//  @Relationship macro on these properties, so nothing on
//  ResearchProject, PaperRecord, ResearchProblem, ResearchIdea,
//  Experiment or WritingDocument needs to change.
//
//  Deleting a task removes only the task. Deleting a linked project
//  or research object simply drops it from the task's links.
//

import Foundation
import SwiftData

// MARK: - Task Status

enum ResearchTaskStatus: String, CaseIterable, Codable, Identifiable {

    case todo = "To Do"
    case inProgress = "In Progress"
    case completed = "Completed"

    var id: String { rawValue }
}


// MARK: - Task Priority

enum ResearchTaskPriority: String, CaseIterable, Codable, Identifiable {

    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    /// Higher number = more urgent. Used for sorting.
    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}


// MARK: - Research Task

@Model
final class ResearchTask {

    var id: UUID

    var title: String
    var descriptionText: String

    var statusRawValue: String
    var priorityRawValue: String

    /// Optional due date. Compared by calendar day, not by time.
    var dueDate: Date?

    var createdAt: Date
    var updatedAt: Date

    /// Set when the task is completed, cleared when it is reopened.
    /// This is a real event, so the Timeline can show it.
    var completedDate: Date?

    // ---------------------------------------------------------
    // Research Links
    // ---------------------------------------------------------
    //
    // Plain, unidirectional references — no @Relationship macro and
    // no delete rule to configure. A task never owns any of these.

    var project: ResearchProject?

    var papers: [PaperRecord] = []
    var problems: [ResearchProblem] = []
    var ideas: [ResearchIdea] = []
    var experiments: [Experiment] = []
    var writingDocuments: [WritingDocument] = []


    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        title: String,
        descriptionText: String = "",
        statusRawValue: String = ResearchTaskStatus.todo.rawValue,
        priorityRawValue: String = ResearchTaskPriority.medium.rawValue,
        dueDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedDate: Date? = nil,
        project: ResearchProject? = nil,
        papers: [PaperRecord] = [],
        problems: [ResearchProblem] = [],
        ideas: [ResearchIdea] = [],
        experiments: [Experiment] = [],
        writingDocuments: [WritingDocument] = []
    ) {
        self.id = id
        self.title = title
        self.descriptionText = descriptionText
        self.statusRawValue = statusRawValue
        self.priorityRawValue = priorityRawValue
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedDate = completedDate
        self.project = project
        self.papers = papers
        self.problems = problems
        self.ideas = ideas
        self.experiments = experiments
        self.writingDocuments = writingDocuments
    }


    // MARK: - Typed Accessors

    var status: ResearchTaskStatus {
        get { ResearchTaskStatus(rawValue: statusRawValue) ?? .todo }
        set { statusRawValue = newValue.rawValue }
    }

    var priority: ResearchTaskPriority {
        get { ResearchTaskPriority(rawValue: priorityRawValue) ?? .medium }
        set { priorityRawValue = newValue.rawValue }
    }


    // MARK: - State

    var isCompleted: Bool {
        status == .completed
    }

    /// True when the task is not completed and its due day is before
    /// today.
    var isOverdue: Bool {
        guard !isCompleted, let dueDate else { return false }
        return Calendar.current.startOfDay(for: dueDate)
            < Calendar.current.startOfDay(for: Date())
    }

    var isDueToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }

    /// Total number of linked research objects (not counting the
    /// project). Arithmetic only.
    var linkedResearchCount: Int {
        papers.count
            + problems.count
            + ideas.count
            + experiments.count
            + writingDocuments.count
    }


    // MARK: - Actions

    /// Marks the task completed and records when.
    func markCompleted(at date: Date = Date()) {
        status = .completed
        completedDate = date
        updatedAt = date
    }

    /// Reopens a completed task and clears its completion date.
    func reopen(at date: Date = Date()) {
        status = .todo
        completedDate = nil
        updatedAt = date
    }

    /// Records that the task was edited.
    func touch(at date: Date = Date()) {
        updatedAt = date
    }
}
