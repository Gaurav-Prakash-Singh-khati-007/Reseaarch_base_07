//
//  SubmissionsView.swift
//  ResearchBase
//
//  Source of truth: docs/researchbase.html (F-38, F-46, SubmissionsView)
//  Submission tracking: venues, deadlines, stages, and reviewer replies.
//
//  Owner: Agent 64 · Features: F-38
//
//  PUBLIC API
//    SubmissionsView(model:onOpenDraft:onOpenDraftID:onChanged:)
//        model           the open library. nil shows a "library not open" notice and no sample data.
//        onOpenDraft     unchanged: called with the draft's TITLE (kept so existing callers still work).
//        onOpenDraftID   new: called with the draft's id. Prefer this one.
//        onChanged       new: called after any change, so Home can refresh its upcoming deadlines (F-46).
//    Screen types kept from before: SubmissionStage (new case: .published), ReviewerCommentStatus,
//        ReviewerCommentModel (id is now the database id; new field: round), SubmissionModel
//        (new fields: draftID, submittedAt, decisionAt).
//    RBA64Logic   pure helpers (days text, stage progress, LaTeX escaping, response letter). Internal so tests reach them.
//
//  Data comes from SubmissionStore (Agent 18). Drafts are read with DraftFolderStore (Agent 20), only to list
//  titles and to save the response letter into the draft folder. No sample data is left in this file.
//
//  Not here, on purpose
//    - No setter exists for a comment's "changed in" line reference, so it can be set when a comment is added
//      and is read-only afterwards.
//    - A submission without a linked draft cannot export a response letter; the screen says so.
//

import SwiftUI

// MARK: - Screen types

enum SubmissionStage: String, CaseIterable {
    case planned = "Planned"
    case submitted = "Submitted"
    case underReview = "Under review"
    case revision = "Revision"
    case accepted = "Accepted"
    case rejected = "Rejected"
    case published = "Published"

    var color: Color {
        switch self {
        case .planned: return RBColor.mutedText
        case .submitted, .underReview: return RBColor.warning
        case .revision: return RBColor.accent
        case .accepted, .published: return RBColor.success
        case .rejected: return RBColor.error
        }
    }

    init(_ stored: StoredSubmissionStage) {
        switch stored {
        case .planned: self = .planned
        case .submitted: self = .submitted
        case .underReview: self = .underReview
        case .revision: self = .revision
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        case .published: self = .published
        }
    }

    var stored: StoredSubmissionStage {
        switch self {
        case .planned: return .planned
        case .submitted: return .submitted
        case .underReview: return .underReview
        case .revision: return .revision
        case .accepted: return .accepted
        case .rejected: return .rejected
        case .published: return .published
        }
    }
}

enum ReviewerCommentStatus: String, CaseIterable {
    case addressed = "addressed"
    case open = "open"
    case disagree = "disagree"

    var label: String {
        switch self {
        case .addressed: return "Addressed"
        case .open: return "Open"
        case .disagree: return "Respectfully disagree"
        }
    }

    var color: Color {
        switch self {
        case .addressed: return RBColor.success
        case .open: return RBColor.warning
        case .disagree: return RBColor.accent
        }
    }

    init(_ stored: StoredReviewState) {
        switch stored {
        case .open: self = .open
        case .addressed: self = .addressed
        case .disagree: self = .disagree
        }
    }

    var stored: StoredReviewState {
        switch self {
        case .open: return .open
        case .addressed: return .addressed
        case .disagree: return .disagree
        }
    }
}

struct ReviewerCommentModel: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var reviewer: String
    var comment: String
    var reply: String
    var status: ReviewerCommentStatus
    var draftLineRef: String
    var round: Int = 1
}

struct SubmissionModel: Identifiable, Equatable {
    let id: String
    var venue: String
    var draftName: String
    /// "yyyy-MM-dd" (or full ISO-8601). Empty means no deadline.
    var deadline: String
    var stage: SubmissionStage
    var round: Int
    var reviewerComments: [ReviewerCommentModel]
    var url: String = ""
    var notes: String = ""
    var draftID: String? = nil
    var submittedAt: String? = nil
    var decisionAt: String? = nil
}

extension SubmissionModel {
    init(stored: StoredSubmission, draftTitle: String?, comments: [StoredReviewComment]) {
        self.init(
            id: stored.id,
            venue: stored.venue,
            draftName: draftTitle ?? "No draft linked",
            deadline: stored.deadline ?? "",
            stage: SubmissionStage(stored.stage),
            round: comments.map(\.round).max() ?? 0,
            reviewerComments: comments.map { item in
                ReviewerCommentModel(
                    id: item.id, reviewer: item.reviewer, comment: item.comment, reply: item.reply,
                    status: ReviewerCommentStatus(item.state), draftLineRef: item.draftLineRef, round: item.round
                )
            },
            url: stored.url,
            notes: stored.notes,
            draftID: stored.draftID,
            submittedAt: stored.submittedAt,
            decisionAt: stored.decisionAt
        )
    }
}

// MARK: - Pure logic (internal so tests can reach it)

enum RBA64Logic {

    /// The steps shown in the progress bar. Rejected is shown as its own chip.
    static let stageOrder: [SubmissionStage] = [.planned, .submitted, .underReview, .revision, .accepted, .published]

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Accepts "2026-10-15" or full ISO-8601. Anything else gives nil.
    static func parseDay(_ text: String, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.count == 10, let day = dayFormatter(calendar).date(from: trimmed) { return day }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        dayFormatter(calendar).string(from: date)
    }

    /// Whole calendar days from today to the deadline. Negative = in the past. nil = no readable date.
    static func daysUntil(_ deadline: String, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let target = parseDay(deadline, calendar: calendar) else { return nil }
        return calendar.dateComponents([.day],
                                       from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: target)).day
    }

    static func daysText(_ deadline: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let trimmed = deadline.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No deadline" }
        guard let days = daysUntil(trimmed, now: now, calendar: calendar) else { return trimmed }
        switch days {
        case 0: return "today"
        case 1: return "in 1 day"
        case -1: return "1 day ago"
        case let d where d > 1: return "in \(d) days"
        default: return "\(-days) days ago"
        }
    }

    /// How far along the progress bar a stage is. Rejected stops after "Under review".
    static func progressIndex(_ stage: SubmissionStage) -> Int {
        switch stage {
        case .planned: return 0
        case .submitted: return 1
        case .underReview: return 2
        case .revision: return 3
        case .accepted: return 4
        case .published: return 5
        case .rejected: return 2
        }
    }

    static func isStageActive(_ stage: SubmissionStage, current: SubmissionStage) -> Bool {
        guard let index = stageOrder.firstIndex(of: stage) else { return false }
        return index <= progressIndex(current)
    }

    /// Escapes text so it is safe inside LaTeX body text.
    static func latexEscape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += #"\textbackslash{}"#
            case "&": out += #"\&"#
            case "%": out += #"\%"#
            case "$": out += #"\$"#
            case "#": out += "\\#"
            case "_": out += #"\_"#
            case "{": out += #"\{"#
            case "}": out += #"\}"#
            case "~": out += #"\textasciitilde{}"#
            case "^": out += #"\textasciicircum{}"#
            default: out.append(character)
            }
        }
        return out
    }

    /// A response-to-reviewers letter for one round (the latest by default), grouped by reviewer.
    static func responseLetter(venue: String, comments: [ReviewerCommentModel], round: Int? = nil) -> String {
        let useRound = round ?? comments.map(\.round).max() ?? 1
        let inRound = comments.filter { $0.round == useRound }

        var reviewers: [String] = []
        for item in inRound where !reviewers.contains(item.reviewer) { reviewers.append(item.reviewer) }

        let oneLineVenue = venue.replacingOccurrences(of: "\n", with: " ")
        var lines: [String] = [
            "% Response to reviewers for \(oneLineVenue), round \(useRound). Generated by ResearchBase.",
            #"\documentclass[11pt]{article}"#,
            #"\usepackage[utf8]{inputenc}"#,
            #"\usepackage[margin=1in]{geometry}"#,
            #"\begin{document}"#,
            "",
            #"\section*{Response to the reviewers}"#,
            #"\noindent\textbf{Venue:} \#(latexEscape(oneLineVenue)) \\"#,
            #"\textbf{Round:} \#(useRound)"#,
            "",
            "We thank the reviewers for their comments. Each comment is quoted below, followed by our reply.",
        ]

        for (reviewerIndex, reviewer) in reviewers.enumerated() {
            lines.append("")
            lines.append(#"\subsection*{\#(latexEscape(reviewer))}"#)
            let mine = inRound.filter { $0.reviewer == reviewer }
            for (commentIndex, item) in mine.enumerated() {
                lines.append("")
                lines.append(#"\paragraph{Comment \#(reviewerIndex + 1).\#(commentIndex + 1).}"#)
                lines.append(#"\begin{quote}"#)
                lines.append(latexEscape(item.comment))
                lines.append(#"\end{quote}"#)
                let reply = item.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if reply.isEmpty {
                    lines.append(#"\noindent\textbf{Reply.} \textit{(No reply written yet.)}"#)
                } else {
                    lines.append(#"\noindent\textbf{Reply.} \#(latexEscape(reply))"#)
                }
                if !item.draftLineRef.isEmpty {
                    lines.append("")
                    lines.append(#"\noindent\textit{Changed in \#(latexEscape(item.draftLineRef)).}"#)
                }
            }
        }

        lines.append("")
        lines.append(#"\end{document}"#)
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Screen

struct SubmissionsView: View {

    private struct DraftChoice: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let model: LibraryModel?
    var onOpenDraft: ((String) -> Void)?
    var onOpenDraftID: ((String) -> Void)?
    var onChanged: () -> Void

    init(
        model: LibraryModel? = nil,
        onOpenDraft: ((String) -> Void)? = nil,
        onOpenDraftID: ((String) -> Void)? = nil,
        onChanged: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onOpenDraft = onOpenDraft
        self.onOpenDraftID = onOpenDraftID
        self.onChanged = onChanged
    }

    @State private var submissions: [SubmissionModel] = []
    @State private var draftChoices: [DraftChoice] = []
    @State private var selectedSubmissionID: String?
    @State private var loaded = false
    @State private var showDetail = false
    @State private var errorText: String?
    @State private var toastMessage: String?

    @State private var showingNewSubmissionSheet = false
    @State private var confirmDelete = false

    // Details being edited (saved with "Save details")
    @State private var venueText = ""
    @State private var urlText = ""
    @State private var notesText = ""

    // Reply text not saved yet, by comment id
    @State private var replyEdits: [String: String] = [:]

    // New comment form
    @State private var newReviewer = ""
    @State private var newComment = ""
    @State private var newLineRef = ""

    private var selectedSubmission: SubmissionModel? {
        submissions.first { $0.id == selectedSubmissionID }
    }

    var body: some View {
        RBMasterDetail(
            masterMin: 240,
            masterIdeal: 320,
            showDetail: $showDetail,
            backTitle: "Submissions"
        ) {
            listPane
        } detail: {
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RBColor.background)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { reload(); loadBuffers() }
        .onChange(of: selectedSubmissionID) { _, _ in loadBuffers() }
        .sheet(isPresented: $showingNewSubmissionSheet) {
            NewSubmissionSheet(
                drafts: draftChoices.map { ($0.id, $0.title) },
                onCancel: { showingNewSubmissionSheet = false },
                onCreate: { new in createSubmission(new) }
            )
        }
        .confirmationDialog("Delete this submission?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The submission and its reviewer comments are removed. The draft itself is not changed.")
        }
    }

    // MARK: List pane

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            RBListPaneHeader(
                title: "Submissions",
                subtitle: "Deadlines, status and reviewer replies."
            ) {
                Button {
                    showingNewSubmissionSheet = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .help("New submission")
                .disabled(model == nil)
                .opacity(model == nil ? 0.5 : 1)
            }

            Divider().overlay(RBColor.border)

            if model == nil {
                listNotice("The library is not open, so submissions cannot be shown yet.")
            } else if loaded && submissions.isEmpty {
                listNotice("No submissions yet. Press New to track a venue and its deadline.")
            }

            RBListColumn {
                ForEach(submissions) { sub in
                    RB9RowCard(
                        isSelected: selectedSubmissionID == sub.id,
                        action: {
                            selectedSubmissionID = sub.id
                            showDetail = true
                        }
                    ) {
                        row(sub)
                    }
                }
            }
        }
        .rbListPaneBackground()
    }

    private func listNotice(_ text: String) -> some View {
        Text(text)
            .font(RBFont.caption())
            .foregroundStyle(RBColor.secondaryText)
            .padding(RBListPaneMetrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ sub: SubmissionModel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sub.venue)
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                    .lineLimit(1)
                Text(sub.draftName)
                    .font(RBFont.secondary())
                    .foregroundStyle(RBColor.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(sub.stage.rawValue)
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(sub.stage.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(sub.stage.color.opacity(0.12)))
                Text(RBA64Logic.daysText(sub.deadline))
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let sub = selectedSubmission {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorText { errorBanner(errorText) }
                    header(sub)
                    progressBar(sub)
                    detailsForm(sub)

                    Divider().overlay(RBColor.border)

                    commentsHeader(sub)
                    if sub.reviewerComments.isEmpty {
                        emptyCommentsView
                    } else {
                        VStack(spacing: 12) {
                            ForEach(sub.reviewerComments) { item in
                                reviewerCommentCard(item)
                            }
                        }
                    }
                    addCommentForm
                }
                .padding(24)
            }
            .background(RBColor.background)
        } else {
            VStack(spacing: 10) {
                if let errorText { errorBanner(errorText).frame(maxWidth: 420) }
                RB9DetailPlaceholder(
                    icon: "paperplane",
                    text: model == nil ? "Open a library to see submissions" : "Select a submission to see its details."
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RBColor.background)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RBColor.error)
            Text(text)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: RBRadius.field).fill(RBColor.error.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.field).stroke(RBColor.error.opacity(0.3), lineWidth: 1))
    }

    private func header(_ sub: SubmissionModel) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sub.venue)
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Text("\(sub.draftName) · deadline \(sub.deadline.isEmpty ? "not set" : sub.deadline) (\(RBA64Logic.daysText(sub.deadline)))")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            }

            Spacer()

            Button {
                openDraft(sub)
            } label: {
                Label("Open draft", systemImage: "pencil")
                    .font(RBFont.secondary(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(sub.draftID == nil)

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(RBFont.secondary(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func progressBar(_ sub: SubmissionModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(RBA64Logic.stageOrder, id: \.self) { stage in
                    let active = RBA64Logic.isStageActive(stage, current: sub.stage)
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(active ? RBColor.accent : RBColor.hover)
                            .frame(height: 6)
                        Text(stage.rawValue)
                            .font(RBFont.caption(stage == sub.stage ? .bold : .regular))
                            .foregroundStyle(stage == sub.stage ? RBColor.primaryText : RBColor.mutedText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if sub.stage == .rejected {
                Text("Rejected")
                    .font(RBFont.caption(.medium))
                    .foregroundStyle(RBColor.error)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(RBColor.error.opacity(0.12)))
            }
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func detailsForm(_ sub: SubmissionModel) -> some View {
        let dirty = venueText != sub.venue || urlText != sub.url || notesText != sub.notes

        return VStack(alignment: .leading, spacing: 10) {
            formRow("Venue") {
                TextField("Venue", text: $venueText)
                    .textFieldStyle(.roundedBorder)
            }

            formRow("Stage") {
                Picker("", selection: stageBinding(sub)) {
                    ForEach(SubmissionStage.allCases, id: \.self) { stage in
                        Text(stage.rawValue).tag(stage)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            formRow("Draft") {
                Picker("", selection: draftBinding(sub)) {
                    Text("No draft").tag(String?.none)
                    ForEach(draftChoices) { draft in
                        Text(draft.title).tag(String?.some(draft.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            formRow("Deadline") {
                Toggle("", isOn: hasDeadlineBinding(sub))
                    .labelsHidden()
                if !sub.deadline.isEmpty {
                    DatePicker("", selection: deadlineBinding(sub), displayedComponents: .date)
                        .labelsHidden()
                }
            }

            formRow("Link") {
                TextField("Submission page or portal URL", text: $urlText)
                    .textFieldStyle(.roundedBorder)
            }

            formRow("Notes") {
                TextField("Notes", text: $notesText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }

            if sub.submittedAt != nil || sub.decisionAt != nil {
                formRow("Dates") {
                    Text(datesLine(sub))
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                }
            }

            HStack {
                Spacer()
                Button("Save details") { saveDetails(sub) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!dirty || venueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func datesLine(_ sub: SubmissionModel) -> String {
        var parts: [String] = []
        if let submitted = sub.submittedAt { parts.append("submitted \(String(submitted.prefix(10)))") }
        if let decided = sub.decisionAt { parts.append("decision \(String(decided.prefix(10)))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Comments

    private func commentsHeader(_ sub: SubmissionModel) -> some View {
        HStack {
            Text("Reviewer comments\(sub.round > 0 ? " · round \(sub.round)" : "")")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Spacer()

            if !sub.reviewerComments.isEmpty {
                Button {
                    exportLetter(sub)
                } label: {
                    Label("Export response letter", systemImage: "arrow.down.doc")
                        .font(RBFont.secondary(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sub.draftID == nil)
                .help(sub.draftID == nil ? "Link a draft first. The letter is saved into the draft folder." : "")
            }
        }
    }

    private func replyBinding(_ item: ReviewerCommentModel) -> Binding<String> {
        Binding(
            get: { replyEdits[item.id] ?? item.reply },
            set: { replyEdits[item.id] = $0 }
        )
    }

    private func reviewerCommentCard(_ item: ReviewerCommentModel) -> some View {
        let replyIsDirty = (replyEdits[item.id] ?? item.reply) != item.reply

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.reviewer)
                    .font(RBFont.body(.semibold))
                    .foregroundStyle(RBColor.primaryText)
                Text("round \(item.round)")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                Spacer()

                Picker("", selection: statusBinding(item)) {
                    ForEach(ReviewerCommentStatus.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .foregroundStyle(item.status.color)
            }

            Text(item.comment)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)
                .padding(.vertical, 2)

            TextField("Your reply", text: replyBinding(item), axis: .vertical)
                .textFieldStyle(.plain)
                .font(RBFont.body())
                .padding(8)
                .background(RoundedRectangle(cornerRadius: RBRadius.page).fill(RBColor.surface))
                .overlay(RoundedRectangle(cornerRadius: RBRadius.page).stroke(RBColor.border, lineWidth: 1))

            HStack(spacing: 10) {
                if replyIsDirty {
                    Button("Save reply") { saveReply(item) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Discard") { replyEdits[item.id] = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer()
                Button("Delete comment", role: .destructive) { deleteComment(item) }
                    .buttonStyle(.link)
                    .font(RBFont.caption(.medium))
            }

            if !item.draftLineRef.isEmpty {
                HStack(spacing: 6) {
                    Text("Changed in")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                    Text(item.draftLineRef)
                        .font(RBFont.caption(.medium).monospaced())
                        .foregroundStyle(RBColor.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(RBColor.accent.opacity(0.1)))
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: RBRadius.panel).fill(RBColor.card))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.panel).stroke(RBColor.border, lineWidth: 1))
    }

    private var addCommentForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a reviewer comment")
                .font(RBFont.caption(.medium))
                .foregroundStyle(RBColor.secondaryText)

            HStack(spacing: 8) {
                TextField("Reviewer (for example Reviewer 1)", text: $newReviewer)
                    .textFieldStyle(.roundedBorder)
                TextField("Changed in (optional, main.tex:41)", text: $newLineRef)
                    .textFieldStyle(.roundedBorder)
                    .font(RBFont.caption().monospaced())
            }

            HStack(alignment: .top, spacing: 8) {
                TextField("Paste the comment", text: $newComment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                Button("Add") { addComment() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        newReviewer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: RBRadius.panel).fill(RBColor.surface))
        .overlay(RoundedRectangle(cornerRadius: RBRadius.panel).stroke(RBColor.border, lineWidth: 1))
    }

    private var emptyCommentsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(RBColor.mutedText)

            Text("No reviews yet")
                .font(RBFont.section(.semibold))
                .foregroundStyle(RBColor.primaryText)

            Text("When reviews arrive, paste each comment below and write your reply next to it.")
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = toastMessage {
            Text(toast)
                .font(RBFont.secondary())
                .foregroundStyle(RBColor.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.primaryText))
                .shadow(radius: 10)
                .padding(.bottom, 20)
                .transition(.opacity)
        }
    }

    // MARK: Bindings that save at once

    private func stageBinding(_ sub: SubmissionModel) -> Binding<SubmissionStage> {
        Binding(
            get: { sub.stage },
            set: { newStage in
                perform { store in _ = try store.setStage(id: sub.id, to: newStage.stored) }
            }
        )
    }

    private func draftBinding(_ sub: SubmissionModel) -> Binding<String?> {
        Binding(
            get: { sub.draftID },
            set: { newID in
                perform { store in _ = try store.setDraft(id: sub.id, to: newID) }
            }
        )
    }

    private func hasDeadlineBinding(_ sub: SubmissionModel) -> Binding<Bool> {
        Binding(
            get: { !sub.deadline.isEmpty },
            set: { on in
                let value: String? = on ? RBA64Logic.dayString(Date()) : nil
                perform { store in _ = try store.setDeadline(id: sub.id, to: value) }
            }
        )
    }

    private func deadlineBinding(_ sub: SubmissionModel) -> Binding<Date> {
        Binding(
            get: { RBA64Logic.parseDay(sub.deadline) ?? Date() },
            set: { date in
                let value = RBA64Logic.dayString(date)
                perform { store in _ = try store.setDeadline(id: sub.id, to: value) }
            }
        )
    }

    private func statusBinding(_ item: ReviewerCommentModel) -> Binding<ReviewerCommentStatus> {
        Binding(
            get: { item.status },
            set: { newStatus in
                perform { store in _ = try store.setState(commentID: item.id, to: newStatus.stored) }
            }
        )
    }

    // MARK: Actions

    private func reload() {
        guard let model else { loaded = true; return }
        do {
            let store = SubmissionStore(model: model)
            let drafts = try DraftFolderStore(model: model).all(includeArchived: true)
            draftChoices = drafts.map { DraftChoice(id: $0.id, title: $0.title) }
            let titles = Dictionary(uniqueKeysWithValues: draftChoices.map { ($0.id, $0.title) })

            submissions = try store.all().map { stored in
                SubmissionModel(
                    stored: stored,
                    draftTitle: stored.draftID.flatMap { titles[$0] },
                    comments: try store.comments(forSubmission: stored.id)
                )
            }

            if selectedSubmissionID == nil || !submissions.contains(where: { $0.id == selectedSubmissionID }) {
                selectedSubmissionID = submissions.first?.id
            }
            errorText = nil
        } catch {
            errorText = "The submissions could not be read: \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Fills the edit boxes from the selected submission. Runs on first load and when the selection changes,
    /// never after a save, so text you are still typing is not thrown away.
    private func loadBuffers() {
        venueText = selectedSubmission?.venue ?? ""
        urlText = selectedSubmission?.url ?? ""
        notesText = selectedSubmission?.notes ?? ""
        replyEdits = [:]
        newReviewer = ""
        newComment = ""
        newLineRef = ""
    }

    /// Runs one store change, then reloads the list and tells the caller.
    @discardableResult
    private func perform(_ work: (SubmissionStore) throws -> Void, success: String? = nil) -> Bool {
        guard let model else { return false }
        do {
            try work(SubmissionStore(model: model))
            errorText = nil
            if let success { showToast(success) }
            let keepEdits = replyEdits
            reload()
            replyEdits = keepEdits.filter { entry in
                submissions.flatMap(\.reviewerComments).contains { $0.id == entry.key && $0.reply != entry.value }
            }
            onChanged()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func createSubmission(_ new: NewSubmission) -> String? {
        guard let model else { return "The library is not open." }
        do {
            let created = try SubmissionStore(model: model).create(new)
            selectedSubmissionID = created.id
            reload()
            showToast("Submission added.")
            onChanged()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func saveDetails(_ sub: SubmissionModel) {
        let venue = venueText
        let url = urlText
        let notes = notesText
        perform({ store in
            if venue != sub.venue { _ = try store.setVenue(id: sub.id, to: venue) }
            if url != sub.url { _ = try store.setURL(id: sub.id, to: url) }
            if notes != sub.notes { _ = try store.setNotes(id: sub.id, to: notes) }
        }, success: "Details saved.")
    }

    private func deleteSelected() {
        guard let sub = selectedSubmission else { return }
        selectedSubmissionID = nil
        perform({ store in try store.remove(id: sub.id) }, success: "Submission deleted.")
    }

    private func addComment() {
        guard let sub = selectedSubmission else { return }
        let reviewer = newReviewer
        let text = newComment
        let ref = newLineRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = perform({ store in
            _ = try store.addComment(submissionID: sub.id, reviewer: reviewer, comment: text, draftLineRef: ref)
        }, success: "Comment added.")
        if added {
            newComment = ""
            newLineRef = ""
        }
    }

    private func saveReply(_ item: ReviewerCommentModel) {
        let text = replyEdits[item.id] ?? item.reply
        perform({ store in _ = try store.setReply(commentID: item.id, to: text) }, success: "Reply saved.")
    }

    private func deleteComment(_ item: ReviewerCommentModel) {
        perform({ store in try store.removeComment(id: item.id) }, success: "Comment deleted.")
    }

    private func openDraft(_ sub: SubmissionModel) {
        guard let draftID = sub.draftID else {
            showToast("Link a draft to this submission first.")
            return
        }
        onOpenDraftID?(draftID)
        onOpenDraft?(sub.draftName)
        showToast("Opened draft “\(sub.draftName)”")
    }

    /// Saves response-letter.tex into the linked draft's folder. Never overwrites: a second export
    /// becomes response-letter-2.tex, and so on.
    private func exportLetter(_ sub: SubmissionModel) {
        guard let model, let draftID = sub.draftID else {
            showToast("Link a draft to this submission first.")
            return
        }
        let letter = RBA64Logic.responseLetter(venue: sub.venue, comments: sub.reviewerComments)
        let data = Data(letter.utf8)
        let drafts = DraftFolderStore(model: model)

        var lastError: Error?
        for attempt in 1...20 {
            let name = attempt == 1 ? "response-letter.tex" : "response-letter-\(attempt).tex"
            do {
                let saved = try drafts.addFile(draftID: draftID, path: name, data: data)
                errorText = nil
                showToast("Saved \(saved) in the draft folder with comments and replies.")
                return
            } catch ModelError.invalidValue(let reason) where reason.hasSuffix("already exists") {
                lastError = ModelError.invalidValue(reason)
                continue
            } catch {
                errorText = "The response letter could not be saved: \(error.localizedDescription)"
                return
            }
        }
        errorText = "The response letter could not be saved: \(lastError?.localizedDescription ?? "too many earlier copies")"
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            if toastMessage == message { toastMessage = nil }
        }
    }
}

// MARK: - New submission sheet

private struct NewSubmissionSheet: View {
    let drafts: [(id: String, title: String)]
    let onCancel: () -> Void
    /// Returns an error text, or nil when it worked (the caller then closes nothing; this sheet closes itself).
    let onCreate: (NewSubmission) -> String?

    @State private var venue = ""
    @State private var draftID: String? = nil
    @State private var hasDeadline = true
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var stage: SubmissionStage = .planned
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New submission")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                if let errorText {
                    Text(errorText)
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.error)
                }

                field("Venue") {
                    TextField("For example MLSys 2027", text: $venue)
                        .textFieldStyle(.roundedBorder)
                }

                field("Draft") {
                    Picker("", selection: $draftID) {
                        Text("No draft yet").tag(String?.none)
                        ForEach(drafts, id: \.id) { draft in
                            Text(draft.title).tag(String?.some(draft.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                field("Deadline") {
                    Toggle("", isOn: $hasDeadline).labelsHidden()
                    if hasDeadline {
                        DatePicker("", selection: $deadline, displayedComponents: .date)
                            .labelsHidden()
                    }
                }

                field("Stage") {
                    Picker("", selection: $stage) {
                        ForEach(SubmissionStage.allCases, id: \.self) { stage in
                            Text(stage.rawValue).tag(stage)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(20)

            Divider().overlay(RBColor.border)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(.bordered)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(venue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 480, height: 380)
        .background(RBColor.elevated)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
                .frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func create() {
        let new = NewSubmission(
            venue: venue,
            draftID: draftID,
            deadline: hasDeadline ? RBA64Logic.dayString(deadline) : nil,
            stage: stage.stored
        )
        if let problem = onCreate(new) {
            errorText = problem
        } else {
            onCancel()
        }
    }
}
