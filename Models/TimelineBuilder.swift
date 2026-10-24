//
//  TimelineBuilder.swift
//  ResearchBase
//
//  Phase 13C — Timeline
//
//  Builds Timeline events from timestamps that are actually stored on
//  existing records. Nothing here is invented or hardcoded.
//
//  What the data supports, and what it does not:
//  - Every record has a creation time, so "created/added" events are
//    real and complete.
//  - Records also keep their latest update time. That is only the
//    LAST edit, not a history of edits, so "updated" events are
//    optional (off by default) and show at most one per record.
//  - Experiment runs have real start and completion times.
//  - A task's completion date is a real event.
//  - Deletions are not recorded anywhere, so deleted items simply
//    disappear from the Timeline.
//
//  The Timeline screen states this limit to the user rather than
//  presenting the data as a full audit trail.
//

import Foundation

// MARK: - Event Kind

enum TimelineEventKind: String, CaseIterable, Identifiable {

    case paper = "Papers"
    case note = "Notes"
    case finding = "Findings"
    case gap = "Gaps"
    case problem = "Problems"
    case idea = "Ideas"
    case experiment = "Experiments"
    case writing = "Writing"
    case project = "Projects"
    case task = "Tasks"

    var id: String { rawValue }

    /// Same symbols the rest of the app uses for these record types.
    var iconName: String {
        switch self {
        case .paper: return "doc.text"
        case .note: return "note.text"
        case .finding: return "text.magnifyingglass"
        case .gap: return "puzzlepiece"
        case .problem: return "questionmark.circle"
        case .idea: return "lightbulb"
        case .experiment: return "flask"
        case .writing: return "pencil"
        case .project: return "square.grid.2x2"
        case .task: return "checkmark.square"
        }
    }
}


// MARK: - Event

struct TimelineEvent: Identifiable, Hashable {

    /// Unique per record and action, e.g. "paper-<uuid>-added".
    let id: String

    let date: Date
    let kind: TimelineEventKind

    /// What happened, e.g. "Paper added" or "Task completed".
    let action: String

    /// Title of the record the event is about.
    let title: String

    /// Where tapping the event goes. Nil if it cannot be opened.
    let target: NavigationTarget?
}


// MARK: - Day Group

struct TimelineDay: Identifiable {
    let day: Date
    let events: [TimelineEvent]

    var id: Date { day }
}


// MARK: - Builder

enum TimelineBuilder {

    /// An "updated" event is only produced when the last update is
    /// clearly after creation, so a record is not reported as updated
    /// just because it was saved right after being created.
    static let updateThreshold: TimeInterval = 60

    static func buildEvents(
        papers: [PaperRecord],
        notes: [ResearchNote],
        findings: [LiteratureFinding],
        gaps: [ResearchGap],
        problems: [ResearchProblem],
        ideas: [ResearchIdea],
        experiments: [Experiment],
        writingDocuments: [WritingDocument],
        projects: [ResearchProject],
        tasks: [ResearchTask],
        includeUpdates: Bool
    ) -> [TimelineEvent] {

        var events: [TimelineEvent] = []

        func add(
            _ kind: TimelineEventKind,
            key: String,
            action: String,
            title: String,
            date: Date,
            target: NavigationTarget?
        ) {
            events.append(
                TimelineEvent(
                    id: "\(kind.rawValue)-\(key)",
                    date: date,
                    kind: kind,
                    action: action,
                    title: displayTitle(title),
                    target: target
                )
            )
        }

        func isMeaningfulUpdate(_ updated: Date, since created: Date) -> Bool {
            updated.timeIntervalSince(created) > updateThreshold
        }

        // Papers
        for paper in papers {
            add(.paper, key: "\(paper.id)-added", action: "Paper added",
                title: paper.title, date: paper.addedAt,
                target: .paper(paper.id))

            if includeUpdates,
               let updated = paper.updatedAt,
               isMeaningfulUpdate(updated, since: paper.addedAt) {
                add(.paper, key: "\(paper.id)-updated", action: "Paper updated",
                    title: paper.title, date: updated,
                    target: .paper(paper.id))
            }
        }

        // Notes
        for note in notes {
            add(.note, key: "\(note.id)-created", action: "Note created",
                title: note.title, date: note.createdAt,
                target: .researchNote(note.id))

            if includeUpdates,
               isMeaningfulUpdate(note.updatedAt, since: note.createdAt) {
                add(.note, key: "\(note.id)-updated", action: "Note updated",
                    title: note.title, date: note.updatedAt,
                    target: .researchNote(note.id))
            }
        }

        // Findings
        for finding in findings {
            add(.finding, key: "\(finding.id)-created", action: "Finding created",
                title: finding.title, date: finding.createdAt,
                target: .literatureFinding(finding.id))

            if includeUpdates,
               isMeaningfulUpdate(finding.updatedAt, since: finding.createdAt) {
                add(.finding, key: "\(finding.id)-updated", action: "Finding updated",
                    title: finding.title, date: finding.updatedAt,
                    target: .literatureFinding(finding.id))
            }
        }

        // Gaps
        for gap in gaps {
            add(.gap, key: "\(gap.id)-created", action: "Research gap created",
                title: gap.title, date: gap.createdAt,
                target: .researchGap(gap.id))

            if includeUpdates,
               isMeaningfulUpdate(gap.updatedAt, since: gap.createdAt) {
                add(.gap, key: "\(gap.id)-updated", action: "Research gap updated",
                    title: gap.title, date: gap.updatedAt,
                    target: .researchGap(gap.id))
            }
        }

        // Problems
        for problem in problems {
            add(.problem, key: "\(problem.id)-created", action: "Research problem created",
                title: problem.title, date: problem.createdAt,
                target: .researchProblem(problem.id))

            if includeUpdates,
               isMeaningfulUpdate(problem.updatedAt, since: problem.createdAt) {
                add(.problem, key: "\(problem.id)-updated", action: "Research problem updated",
                    title: problem.title, date: problem.updatedAt,
                    target: .researchProblem(problem.id))
            }
        }

        // Ideas
        for idea in ideas {
            add(.idea, key: "\(idea.id)-created", action: "Research idea created",
                title: idea.title, date: idea.createdAt,
                target: .researchIdea(idea.id))

            if includeUpdates,
               isMeaningfulUpdate(idea.updatedAt, since: idea.createdAt) {
                add(.idea, key: "\(idea.id)-updated", action: "Research idea updated",
                    title: idea.title, date: idea.updatedAt,
                    target: .researchIdea(idea.id))
            }
        }

        // Experiments (and their runs)
        for experiment in experiments {
            add(.experiment, key: "\(experiment.id)-created", action: "Experiment created",
                title: experiment.name, date: experiment.createdAt,
                target: .experiment(experiment.id))

            if includeUpdates,
               isMeaningfulUpdate(experiment.updatedAt, since: experiment.createdAt) {
                add(.experiment, key: "\(experiment.id)-updated", action: "Experiment updated",
                    title: experiment.name, date: experiment.updatedAt,
                    target: .experiment(experiment.id))
            }

            for run in experiment.runs {
                if let started = run.startedAt {
                    add(.experiment, key: "\(run.id)-started",
                        action: "Run \(run.runNumber) started",
                        title: experiment.name, date: started,
                        target: .experiment(experiment.id))
                }

                if let completed = run.completedAt {
                    add(.experiment, key: "\(run.id)-completed",
                        action: "Run \(run.runNumber) completed",
                        title: experiment.name, date: completed,
                        target: .experiment(experiment.id))
                }
            }
        }

        // Writing
        for document in writingDocuments {
            add(.writing, key: "\(document.id)-created", action: "Writing document created",
                title: document.title, date: document.createdAt,
                target: .writingDocument(document.id))

            if includeUpdates,
               isMeaningfulUpdate(document.updatedAt, since: document.createdAt) {
                add(.writing, key: "\(document.id)-updated", action: "Writing document updated",
                    title: document.title, date: document.updatedAt,
                    target: .writingDocument(document.id))
            }
        }

        // Projects
        for project in projects {
            add(.project, key: "\(project.id)-created", action: "Project created",
                title: project.name, date: project.createdAt,
                target: .project(project.id))

            if includeUpdates,
               isMeaningfulUpdate(project.updatedAt, since: project.createdAt) {
                add(.project, key: "\(project.id)-updated", action: "Project updated",
                    title: project.name, date: project.updatedAt,
                    target: .project(project.id))
            }
        }

        // Tasks. Completion is a real, recorded event. No separate
        // "updated" event is produced for tasks, because completing a
        // task also updates it and would duplicate the entry.
        for task in tasks {
            add(.task, key: "\(task.id)-created", action: "Task created",
                title: task.title, date: task.createdAt,
                target: .task(task.id))

            if let completed = task.completedDate {
                add(.task, key: "\(task.id)-completed", action: "Task completed",
                    title: task.title, date: completed,
                    target: .task(task.id))
            }
        }

        // Newest first. Ties are broken by id so the order is stable.
        return events.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
    }

    // MARK: Grouping

    /// Groups newest-first events by calendar day, keeping order.
    static func groupByDay(_ events: [TimelineEvent]) -> [TimelineDay] {

        var order: [Date] = []
        var buckets: [Date: [TimelineEvent]] = [:]

        for event in events {
            let day = Calendar.current.startOfDay(for: event.date)

            if buckets[day] == nil {
                order.append(day)
            }
            buckets[day, default: []].append(event)
        }

        return order.map { TimelineDay(day: $0, events: buckets[$0] ?? []) }
    }

    // MARK: Helpers

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
