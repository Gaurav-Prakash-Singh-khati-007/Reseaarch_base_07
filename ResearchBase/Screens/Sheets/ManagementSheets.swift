//
//  ManagementSheets.swift
//  ResearchBase
//
//  Source of truth: docs/researchbase.html (X-03, F-05, F-06, F-08, F-13, F-45, F-46, F-51)
//  Sheets for Tag & Author Manager, Author Editor, Citation Key Lock/Change,
//  Link Picker, Reminders, Practice Restore, and Migration Wizard.
//
//  Owner: Agent 62 · Features: F-05 (migration wizard), F-46 (reminders), F-51 (practice restore)
//
//  PUBLIC API (new or changed in this pass; the other sheets are unchanged)
//    RemindersSheet(onDismiss:model:)                       real settings via ReminderScheduler (Agent 32)
//    PracticeRestoreSheet(onDismiss:model:backupURL:)       real drill via RestoreDrill (Agent 49)
//    MigrationWizardSheet(model:context:profile:onFinished:onDismiss:)
//                                                           real move via SwiftDataToLibraryMigrator (Agent 28)
//    The old call styles RemindersSheet(onDismiss:) and PracticeRestoreSheet(onDismiss:) still compile;
//    without a `model` they show "library is not open" and do nothing.
//
//  Not here, on purpose
//    - Reminder timing and PDF/backup choices that the scheduler does not support are shown as text,
//      not as pickers (the scheduler fixes them: 09:00, 1 day + due date; 14, 3, 1 days).
//    - Rebuilding the PDF text index after the switch belongs to PDFTextIndexer wiring (Agents 75-77).
//

//import SwiftUI
import SwiftUI
import SwiftData

// MARK: - Manage Tags & Authors Sheet (X-03, F-08)

struct ManageTagsAuthorsSheet: View {
    let onDismiss: () -> Void
    
    @State private var tags: [(name: String, count: Int)] = [
        ("federated", 5),
        ("non-iid", 3),
        ("baseline", 1),
        ("survey", 1),
        ("vision", 1),
        ("architecture", 2),
        ("optimisation", 1)
    ]
    
    @State private var authorPairs: [(primary: String, alias: String, papers: String)] = [
        ("McMahan, H. Brendan", "McMahan, Brendan", "5 + 1 papers"),
        ("Li, Tian", "Li, T.", "1 + 2 papers"),
        ("Kairouz, Peter", "Kairouz, P.", "1 + 1 papers")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tags and authors")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            HStack(alignment: .top, spacing: 20) {
                // Tags Column
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tags")
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                    
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(tags, id: \.name) { tag in
                                HStack {
                                    Circle()
                                        .fill(RBColor.accent)
                                        .frame(width: 8, height: 8)
                                    
                                    Text(tag.name)
                                        .font(RBFont.body())
                                        .foregroundStyle(RBColor.primaryText)
                                    
                                    Spacer()
                                    
                                    Text("\(tag.count)")
                                        .font(RBFont.caption().monospaced())
                                        .foregroundStyle(RBColor.mutedText)
                                    
                                    Button("Rename") {}
                                        .buttonStyle(RBHoverPlainButtonStyle())
                                        .font(RBFont.caption())
                                        .foregroundStyle(RBColor.accent)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                
                                Divider().overlay(RBColor.border.opacity(0.5))
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
                }
                .frame(maxWidth: .infinity)
                
                // Authors Look-alike Column
                VStack(alignment: .leading, spacing: 10) {
                    Text("Authors that look the same")
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                    
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(authorPairs, id: \.primary) { pair in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(pair.primary) and \(pair.alias)")
                                                .font(RBFont.body(.semibold))
                                                .foregroundStyle(RBColor.primaryText)
                                            Text(pair.papers)
                                                .font(RBFont.caption())
                                                .foregroundStyle(RBColor.mutedText)
                                        }
                                        Spacer()
                                        
                                        Button("Merge") {
                                            authorPairs.removeAll { $0.primary == pair.primary }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        
                                        Button("Different") {
                                            authorPairs.removeAll { $0.primary == pair.primary }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.surface))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
                            }
                        }
                    }
                    
                    Text("Matching ignores accents and punctuation. Merging keeps every spelling as an alias, so search still finds the old one.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Done") { onDismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 720, height: 480)
        .background(RBColor.elevated)
    }
}

// MARK: - Edit Authors Sheet (F-08)

struct EditAuthorsSheet: View {
    let onDismiss: () -> Void
    
    struct AuthorEntry: Identifiable {
        let id = UUID()
        var family: String
        var given: String
        var suffix: String = ""
        var isOrg: Bool = false
        var orcid: String = ""
    }
    
    @State private var authors: [AuthorEntry] = [
        AuthorEntry(family: "McMahan", given: "H. Brendan"),
        AuthorEntry(family: "Moore", given: "Eider"),
        AuthorEntry(family: "Ramage", given: "Daniel"),
        AuthorEntry(family: "Hampson", given: "Seth"),
        AuthorEntry(family: "y Arcas", given: "Blaise Agüera")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Authors")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Text("").frame(width: 24)
                        Text("Family name").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Given names").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Suffix").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(width: 60)
                        Text("Org").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(width: 40)
                        Text("ORCID").font(RBFont.caption(.semibold)).foregroundStyle(RBColor.mutedText).frame(width: 160)
                    }
                    .padding(.horizontal, 8)
                    
                    Divider().overlay(RBColor.border)
                    
                    ForEach(Array(authors.enumerated()), id: \.offset) { idx, a in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12))
                                .foregroundStyle(RBColor.mutedText)
                                .frame(width: 24)
                            
                            TextField("Family", text: $authors[idx].family)
                                .textFieldStyle(.plain)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
                            
                            TextField("Given", text: $authors[idx].given)
                                .textFieldStyle(.plain)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
                            
                            TextField("", text: $authors[idx].suffix)
                                .textFieldStyle(.plain)
                                .padding(6)
                                .frame(width: 60)
                                .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
                            
                            Toggle("", isOn: $authors[idx].isOrg)
                                .labelsHidden()
                                .frame(width: 40)
                            
                            TextField("0000-0000-...", text: $authors[idx].orcid)
                                .textFieldStyle(.plain)
                                .padding(6)
                                .frame(width: 160)
                                .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
                        }
                    }
                    
                    HStack {
                        Button {
                            authors.append(AuthorEntry(family: "", given: ""))
                        } label: {
                            Label("Add author", systemImage: "plus")
                                .font(RBFont.caption(.medium))
                        }
                        .buttonStyle(.bordered)
                        
                        Text("Paste “Family, Given; Family, Given” to fill all rows at once.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.mutedText)
                        
                        Spacer()
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
                Button("Save") { onDismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 720, height: 460)
        .background(RBColor.elevated)
    }
}

// MARK: - Change Citation Key Sheet (F-13)

struct ChangeCitationKeySheet: View {
    let currentKey: String
    let onDismiss: () -> Void
    var onChangeKey: (String) -> Void = { _ in }
    
    @State private var newKey = ""
    @State private var updateDrafts = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Change citation key")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Current")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 80, alignment: .leading)
                    Text(currentKey)
                        .font(RBFont.body().monospaced())
                        .foregroundStyle(RBColor.primaryText)
                }
                
                HStack {
                    Text("New")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                        .frame(width: 80, alignment: .leading)
                    TextField(currentKey, text: $newKey)
                        .textFieldStyle(.plain)
                        .font(RBFont.body().monospaced())
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(RBColor.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RBColor.border, lineWidth: 1))
                }
                
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(RBColor.warning)
                    Text("Cited in 2 drafts. The new key will be written into both. If you already sent a paper out with the old key, nothing changes there, but regenerate its .bib.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.secondaryText)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.warning.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.warning.opacity(0.3), lineWidth: 1))
                
                Toggle("Update the 2 drafts and rebuild", isOn: $updateDrafts)
                    .font(RBFont.body())
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
                Button {
                    let k = newKey.isEmpty ? currentKey : newKey
                    onChangeKey(k)
                    onDismiss()
                } label: {
                    Text("Change key")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 520, height: 340)
        .background(RBColor.elevated)
        .onAppear {
            newKey = currentKey
        }
    }
}

// MARK: - Add Link Sheet (F-06, F-45)

struct AddLinkSheet: View {
    let onDismiss: () -> Void
    var onAddLink: (String, String) -> Void = { _, _ in }
    
    @State private var relation = "is related to"
    @State private var query = ""
    
    private let relations = [
        "is related to", "supports", "contradicts", "uses", "extends", "is derived from"
    ]
    
    private let items = [
        ("doc.text", "SCAFFOLD: Stochastic Controlled Averaging…", "Paper"),
        ("flask", "Drift under Dirichlet splits", "Experiment"),
        ("lightbulb", "Report drift norm next to accuracy", "Idea"),
        ("pencil", "Client Drift in Federated Averaging", "Draft")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add a link")
                    .font(RBFont.detail(.bold))
                    .foregroundStyle(RBColor.primaryText)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RBColor.mutedText)
                        .padding(6)
                        .background(Circle().fill(RBColor.hover))
                }
                .buttonStyle(RBHoverPlainButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(RBColor.mutedText)
                    TextField("Search papers, notes, experiments, drafts", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
                
                HStack {
                    Text("This item")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                    Picker("", selection: $relation) {
                        ForEach(relations, id: \.self) { r in
                            Text(r).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("the chosen item")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)
                }
                
                VStack(spacing: 0) {
                    ForEach(items, id: \.1) { item in
                        Button {
                            onAddLink(item.1, relation)
                            onDismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.0)
                                    .font(.system(size: 14))
                                    .foregroundStyle(RBColor.accent)
                                Text(item.1)
                                    .font(RBFont.body())
                                    .foregroundStyle(RBColor.primaryText)
                                Spacer()
                                Text(item.2)
                                    .font(RBFont.caption())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(RBColor.hover))
                            }
                            .padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RBHoverPlainButtonStyle())
                        Divider().overlay(RBColor.border.opacity(0.5))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))
                
                Text("The link shows on both items. Removing it from one side removes it from the other.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)
            }
            .padding(20)
            
            Divider().overlay(RBColor.border)
            
            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 520, height: 420)
        .background(RBColor.elevated)
    }
}

// MARK: - Shared sheet header (Agent 62 helper, used by the three sheets below)

private struct RBA62SheetHeader: View {
    let title: String
    var closeDisabled: Bool = false
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(RBFont.detail(.bold))
                .foregroundStyle(RBColor.primaryText)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RBColor.mutedText)
                    .padding(6)
                    .background(Circle().fill(RBColor.hover))
            }
            .buttonStyle(RBHoverPlainButtonStyle())
            .disabled(closeDisabled)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

private struct RBA62Notice: View {
    enum Tone { case warning, error, success }
    let text: String
    var tone: Tone = .warning

    private var color: Color {
        switch tone {
        case .warning: return RBColor.warning
        case .error:   return RBColor.error
        case .success: return RBColor.success
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            Text(text)
                .font(RBFont.caption())
                .foregroundStyle(RBColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }
}

// MARK: - Reminders Sheet (F-46)
//
// Real settings: the two switches are stored by ReminderScheduler (Agent 32) and every change
// re-syncs the reminders with macOS. The timing of reminders is fixed by the scheduler, so it is
// shown as text, not as pickers that would do nothing.

@MainActor
struct RemindersSheet: View {
    let onDismiss: () -> Void
    var model: LibraryModel? = nil

    @State private var settings = ReminderSettings()
    @State private var upcoming: [UpcomingDeadline] = []
    @State private var statusText: String?
    @State private var noticeText: String?
    @State private var errorText: String?
    @State private var working = false

    private var taskTiming: String {
        let hour = String(format: "%02d:00", ReminderScheduler.reminderHour)
        return "\(hour) on " + Self.daysPhrase(ReminderScheduler.taskDaysBefore)
    }

    private var submissionTiming: String {
        Self.daysPhrase(ReminderScheduler.submissionDaysBefore)
    }

    /// [1, 0] -> "the due date and the day before"; [14, 3, 1] -> "14 days, 3 days and 1 day before".
    private static func daysPhrase(_ days: [Int]) -> String {
        let ordered = days.sorted()
        if ordered.contains(0) {
            let parts = ordered.map { day -> String in
                day == 0 ? "the due date" : (day == 1 ? "the day before" : "\(day) days before")
            }
            return list(parts)
        }
        let parts = ordered.reversed().map { "\($0) \($0 == 1 ? "day" : "days")" }
        return list(Array(parts)) + " before"
    }

    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    var body: some View {
        VStack(spacing: 0) {
            RBA62SheetHeader(title: "Reminders", onClose: onDismiss)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    if model == nil {
                        RBA62Notice(text: "The library is not open, so reminders cannot be changed yet.")
                    }
                    if let errorText { RBA62Notice(text: errorText, tone: .error) }
                    if let noticeText { RBA62Notice(text: noticeText) }

                    HStack {
                        label("Notifications")
                        Toggle("Allow Mac notifications", isOn: enabledBinding)
                            .disabled(model == nil || working)
                        Spacer()
                    }

                    HStack(alignment: .firstTextBaseline) {
                        label("Task reminder")
                        Text(taskTiming)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.primaryText)
                        Spacer()
                    }

                    HStack(alignment: .firstTextBaseline) {
                        label("Submission deadlines")
                        Text(submissionTiming)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.primaryText)
                        Spacer()
                    }

                    HStack {
                        label("Backup problems")
                        Toggle("Tell me if a backup fails", isOn: backupBinding)
                            .disabled(model == nil || working)
                        Spacer()
                    }

                    if let statusText {
                        Text(statusText)
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    }

                    Text("Reminders are scheduled with macOS, so they still arrive when the app is closed.")
                        .font(RBFont.caption())
                        .foregroundStyle(RBColor.mutedText)

                    if model != nil {
                        Divider().overlay(RBColor.border)
                        upcomingSection
                    }
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            HStack {
                Spacer()
                Button("Done") { onDismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 520, height: 480)
        .background(RBColor.elevated)
        .onAppear { load() }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(RBFont.caption())
            .foregroundStyle(RBColor.mutedText)
            .frame(width: 140, alignment: .leading)
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coming up")
                .font(RBFont.body(.semibold))
                .foregroundStyle(RBColor.primaryText)

            if upcoming.isEmpty {
                Text("Nothing is due in the next 14 days.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            } else {
                ForEach(upcoming) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: item.kind == .task ? "checklist" : "paperplane")
                            .font(.system(size: 12))
                            .foregroundStyle(RBColor.mutedText)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(RBFont.body())
                                .foregroundStyle(RBColor.primaryText)
                                .lineLimit(1)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(Self.when(item.daysLeft))
                            .font(RBFont.caption(.medium))
                            .foregroundStyle(item.daysLeft < 0 ? RBColor.error : RBColor.secondaryText)
                    }
                }
            }
        }
    }

    private static func when(_ daysLeft: Int) -> String {
        switch daysLeft {
        case ..<0: return "\(-daysLeft) day\(daysLeft == -1 ? "" : "s") overdue"
        case 0:    return "Today"
        case 1:    return "Tomorrow"
        default:   return "In \(daysLeft) days"
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { value in
                var next = settings
                next.enabled = value
                apply(next, askPermission: value)
            }
        )
    }

    private var backupBinding: Binding<Bool> {
        Binding(
            get: { settings.backupAlerts },
            set: { value in
                var next = settings
                next.backupAlerts = value
                apply(next, askPermission: false)
            }
        )
    }

    private func load() {
        guard let model else { return }
        let scheduler = ReminderScheduler(model: model)
        do {
            settings = try scheduler.settings()
            upcoming = Array(try scheduler.upcoming(days: 14, includeOverdue: true).prefix(5))
            errorText = nil
        } catch {
            errorText = "Reminder settings could not be read: \(error.localizedDescription)"
        }
    }

    private func apply(_ next: ReminderSettings, askPermission: Bool) {
        guard let model, !working else { return }
        working = true
        errorText = nil
        noticeText = nil

        Task {
            let scheduler = ReminderScheduler(model: model)
            do {
                if askPermission { _ = await scheduler.requestPermission() }
                try scheduler.setSettings(next)
                settings = next

                let result = try await scheduler.sync()
                switch result.outcome {
                case .scheduled:
                    statusText = "\(result.scheduled) reminder\(result.scheduled == 1 ? "" : "s") scheduled with macOS."
                    if result.failed > 0 {
                        noticeText = "macOS refused \(result.failed) reminder\(result.failed == 1 ? "" : "s")."
                    }
                case .disabled:
                    statusText = "Reminders are off. Any waiting reminders were removed."
                case .notAuthorized:
                    statusText = nil
                    noticeText = "macOS has not allowed notifications for ResearchBase. Turn them on in System Settings › Notifications."
                }
                upcoming = Array(try scheduler.upcoming(days: 14, includeOverdue: true).prefix(5))
            } catch {
                errorText = "Reminders could not be updated: \(error.localizedDescription)"
                settings = (try? scheduler.settings()) ?? settings
            }
            working = false
        }
    }
}

// MARK: - Practice Restore Sheet (F-51)
//
// Runs the real RestoreDrill (Agent 49) on a backup you pick. The drill restores into a scratch
// folder and removes it again; the library itself is never touched.

@MainActor
struct PracticeRestoreSheet: View {
    let onDismiss: () -> Void
    var model: LibraryModel? = nil
    /// Start on this backup straight away (for a "Practice restore" button on a backup row).
    var backupURL: URL? = nil

    @State private var drill: RestoreDrill?
    @State private var backups: [BackupRecord] = []
    @State private var lastRecord: DrillRecord?
    @State private var started = false

    private var running: Bool { drill?.isRunning ?? false }

    var body: some View {
        VStack(spacing: 0) {
            RBA62SheetHeader(title: "Practice restore", closeDisabled: running, onClose: onDismiss)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Restores a backup into a scratch folder and checks it. Your library is not touched.")
                        .font(RBFont.body())
                        .foregroundStyle(RBColor.secondaryText)

                    if model == nil {
                        RBA62Notice(text: "The library is not open, so a practice restore cannot run yet.")
                    }

                    if let drill, running || drill.result != nil {
                        stepsView(drill)
                    }

                    if let drill, let result = drill.result, !running {
                        verdictView(result)
                    } else if !running, let lastRecord {
                        lastDrillLine(lastRecord)
                    }

                    if model != nil { backupList }
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(RBColor.surface)
        }
        .frame(width: 540, height: 580)
        .background(RBColor.elevated)
        .onAppear { prepare() }
    }

    // MARK: Pieces

    private func stepsView(_ drill: RestoreDrill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(drill.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(for: step.state)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.primaryText)
                        if let note = Self.note(for: step.state) {
                            Text(note)
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(for state: DrillStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").foregroundStyle(RBColor.mutedText)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RBColor.success)
        case .passedWithNote:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(RBColor.warning)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(RBColor.error)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(RBColor.mutedText)
        }
    }

    private static func note(for state: DrillStepState) -> String? {
        switch state {
        case .passedWithNote(let text), .failed(let text), .skipped(let text):
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    private func verdictView(_ result: DrillResult) -> some View {
        let tone: RBA62Notice.Tone
        switch result.verdict {
        case .passed:          tone = .success
        case .passedWithNotes: tone = .warning
        case .failed:          tone = .error
        case .skipped:         tone = .warning
        }

        var text = result.verdict.headline
        if case .passedWithNotes(let notes) = result.verdict, !notes.isEmpty {
            text += "\n" + notes.map { "• \($0)" }.joined(separator: "\n")
        }
        text += "\nPractised " + result.finishedAt.formatted(date: .abbreviated, time: .shortened)
            + " on " + result.backupName + ". Scratch folder removed."

        return RBA62Notice(text: text, tone: tone)
    }

    private func lastDrillLine(_ record: DrillRecord) -> some View {
        let outcome: String
        switch record.result {
        case "passed": outcome = "passed"
        case "notes":  outcome = "passed with notes"
        default:       outcome = "failed"
        }
        let when = record.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "an unknown time"
        return Text("Last practised \(when) on \(record.backupName): \(outcome).")
            .font(RBFont.caption())
            .foregroundStyle(record.succeeded ? RBColor.secondaryText : RBColor.error)
    }

    private var backupList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backups")
                .font(RBFont.body(.semibold))
                .foregroundStyle(RBColor.primaryText)

            if backups.isEmpty {
                Text("No backups were found yet. Make a backup first, then practise restoring it.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.secondaryText)
            } else {
                ForEach(backups.prefix(6)) { backup in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(backup.name)
                                .font(RBFont.body())
                                .foregroundStyle(RBColor.primaryText)
                                .lineLimit(1)
                            Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.mutedText)
                        }
                        Spacer()
                        Button("Practise restore") { start(backup.url) }
                            .disabled(running)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func prepare() {
        guard let model, drill == nil else { return }
        let made = RestoreDrill(library: model.library)
        drill = made
        backups = made.availableBackups()
        lastRecord = RestoreDrill.lastDrill(in: model.library)

        if let backupURL, !started {
            start(backupURL, using: made)
        }
    }

    private func start(_ url: URL) {
        guard let drill else { return }
        start(url, using: drill)
    }

    private func start(_ url: URL, using drill: RestoreDrill) {
        guard !drill.isRunning else { return }
        started = true
        Task {
            _ = await drill.run(backupAt: url)
            if let model { lastRecord = RestoreDrill.lastDrill(in: model.library) }
        }
    }
}

// MARK: - Migration Wizard Sheet (F-05)
//
// Walks through the one-time move from the old SwiftData store to the new library, using
// SwiftDataToLibraryMigrator (Agent 28): back up, copy, check, then switch. The migrator does the
// first three steps in one call; the switch is always a separate click, and it is blocked unless
// the check passed. Safe to run again: rows already copied are skipped.

@MainActor
struct MigrationWizardSheet: View {
    let model: LibraryModel?
    let context: ModelContext?
    var profile: ProfileStore? = nil
    var onFinished: () -> Void = {}
    let onDismiss: () -> Void

    private typealias Migrator = SwiftDataToLibraryMigrator
    private typealias MigrationProgress = SwiftDataToLibraryMigrator.Progress
    private typealias MigrationReport = SwiftDataToLibraryMigrator.Report
    private typealias MigrationStatus = SwiftDataToLibraryMigrator.Status
    private typealias LegacySummary = SwiftDataToLibraryMigrator.LegacySummary

    private enum Stage { case intro, working, check, done }

    @State private var stage: Stage = .intro
    @State private var status: MigrationStatus?
    @State private var summary: LegacySummary?
    @State private var report: MigrationReport?
    @State private var progress: MigrationProgress?
    @State private var busy = false
    @State private var errorText: String?
    @State private var searchNote: String?

    private let stepNames = ["Back up", "Copy", "Check", "Switch"]

    /// 1-based step that is current; 5 means everything is finished.
    private var currentStep: Int {
        switch stage {
        case .intro: return 1
        case .working:
            guard let phase = progress?.phase else { return 1 }
            return phase == .checking ? 3 : 2
        case .check: return 4
        case .done: return 5
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RBA62SheetHeader(title: "Move to the new library", closeDisabled: busy, onClose: onDismiss)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stepBar

                    if model == nil {
                        RBA62Notice(text: "The library is not open, so the move cannot start yet.")
                    }
                    if let errorText { RBA62Notice(text: errorText, tone: .error) }

                    switch stage {
                    case .intro:   introView
                    case .working: workingView
                    case .check:   checkView
                    case .done:    doneView
                    }
                }
                .padding(20)
            }

            Divider().overlay(RBColor.border)
            footer
        }
        .frame(width: 640, height: 600)
        .background(RBColor.elevated)
        .onAppear { load() }
    }

    // MARK: Pieces

    private var stepBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(stepNames.enumerated()), id: \.offset) { index, name in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index + 1 < currentStep ? RBColor.accent : RBColor.hover)
                        .frame(height: 6)
                    Text("\(index + 1). \(name)")
                        .font(RBFont.caption(index + 1 == currentStep ? .semibold : .regular))
                        .foregroundStyle(index + 1 == currentStep ? RBColor.primaryText : RBColor.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var introView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your current data is backed up first, then left untouched. Nothing changes until the last step.")
                .font(RBFont.body())
                .foregroundStyle(RBColor.secondaryText)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(RBColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Old data found")
                        .font(RBFont.body(.semibold))
                        .foregroundStyle(RBColor.primaryText)
                    if let summary {
                        if summary.isEmpty {
                            Text("No old data was found, so there is nothing to move.")
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        } else {
                            Text(summary.sentence + (summary.pdfFiles > 0 ? ", \(summary.pdfFiles) PDF file\(summary.pdfFiles == 1 ? "" : "s")" : ""))
                                .font(RBFont.caption())
                                .foregroundStyle(RBColor.secondaryText)
                        }
                    } else {
                        Text("The old data could not be read.")
                            .font(RBFont.caption())
                            .foregroundStyle(RBColor.secondaryText)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(RBColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RBColor.border, lineWidth: 1))

            if let status, status.state == .copied || status.state == .verified {
                RBA62Notice(text: "An earlier run already copied your data. Running again is safe: records that are already in the new library are skipped.")
            }
        }
    }

    private var workingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workingText)
                .font(RBFont.body())
                .foregroundStyle(RBColor.primaryText)

            if let progress, progress.total > 0 {
                ProgressView(value: Double(min(progress.done, progress.total)), total: Double(progress.total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }

            Text("Keep this window open. If anything fails, the new library is left unchanged.")
                .font(RBFont.caption())
                .foregroundStyle(RBColor.mutedText)
        }
    }

    private var workingText: String {
        guard let progress else { return "Backing up the old data…" }
        switch progress.phase {
        case .planning:       return "Planning the copy…"
        case .copyingFiles:   return "Copying PDF files (\(progress.done) of \(progress.total))…"
        case .writingRecords: return "Writing records (\(progress.done) of \(progress.total))…"
        case .checking:       return "Checking the new library (\(progress.done) of \(progress.total))…"
        }
    }

    private var checkView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report {
                Text(report.isSafeToSwitch
                     ? "Compare what was in the old library with the new one."
                     : "The check found a problem, so the switch is blocked.")
                    .font(RBFont.body())
                    .foregroundStyle(RBColor.secondaryText)

                VStack(spacing: 0) {
                    HStack {
                        Text("Kind").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Old").frame(width: 60, alignment: .trailing)
                        Text("New").frame(width: 60, alignment: .trailing)
                        Spacer().frame(width: 28)
                    }
                    .font(RBFont.caption(.semibold))
                    .foregroundStyle(RBColor.mutedText)
                    .padding(.vertical, 6)

                    ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                        Divider().overlay(RBColor.border)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.label)
                                    .font(RBFont.body())
                                    .foregroundStyle(RBColor.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(row.old)").frame(width: 60, alignment: .trailing)
                                Text("\(row.new)").frame(width: 60, alignment: .trailing)
                                Image(systemName: row.status == .mismatch ? "xmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(row.status == .mismatch ? RBColor.error : RBColor.success)
                                    .frame(width: 28)
                            }
                            .font(RBFont.body())
                            .foregroundStyle(RBColor.primaryText)

                            if !row.note.isEmpty && row.status != .match {
                                Text(row.note)
                                    .font(RBFont.caption())
                                    .foregroundStyle(RBColor.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                Text(report.pdfSampleSize == 0
                     ? "There were no PDFs to sample."
                     : "A sample of \(report.pdfSampleSize) PDF\(report.pdfSampleSize == 1 ? "" : "s") was re-read and \(report.pdfSampleMatched) fingerprint\(report.pdfSampleMatched == 1 ? "" : "s") matched.")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

                if let reason = report.blockingReason {
                    RBA62Notice(text: reason, tone: .error)
                }

                if !report.contentProblems.isEmpty {
                    RBA62Notice(
                        text: report.contentProblems.prefix(5).joined(separator: "\n")
                            + (report.contentProblems.count > 5 ? "\nand \(report.contentProblems.count - 5) more" : ""),
                        tone: .error)
                }

                if !report.keyChanges.isEmpty {
                    RBA62Notice(text: "\(report.keyChanges.count) citation key\(report.keyChanges.count == 1 ? "" : "s") had to change (empty, invalid or already taken). Check your drafts that cite them.")
                }

                if !report.warnings.isEmpty {
                    RBA62Notice(
                        text: report.warnings.prefix(6).joined(separator: "\n")
                            + (report.warnings.count > 6 ? "\nand \(report.warnings.count - 6) more" : ""))
                }
            }
        }
    }

    private var doneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let days = status?.legacyDaysLeft() ?? 90
            RBA62Notice(
                text: "Done. The old data is now read-only and is kept for \(days) day\(days == 1 ? "" : "s").",
                tone: .success)
            if let searchNote { RBA62Notice(text: searchNote) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch stage {
            case .intro:
                Button("Cancel") { onDismiss() }
                Button(status?.state == .notStarted || status == nil ? "Back up, copy and check" : "Back up, copy and check again") {
                    runThroughCheck()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)

            case .working:
                Text("Working…")
                    .font(RBFont.caption())
                    .foregroundStyle(RBColor.mutedText)

            case .check:
                Button("Close without switching") { onDismiss() }
                Button("Check again") { runThroughCheck() }
                Button("Switch to the new library") { switchNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(report?.isSafeToSwitch ?? false) || busy)

            case .done:
                Button("Done") { onDismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RBColor.surface)
    }

    private var canStart: Bool {
        guard model != nil, context != nil, !busy else { return false }
        if let summary, summary.isEmpty, (status?.state ?? .notStarted) == .notStarted { return false }
        return summary != nil
    }

    // MARK: Actions

    private func load() {
        guard let model else { return }
        let migrator = Migrator(model: model)
        do {
            let current = try migrator.status()
            status = current
            if current.state == .switched { stage = .done }
        } catch {
            errorText = "The migration status could not be read: \(error.localizedDescription)"
        }

        if let context {
            do {
                let capture = try WorkspaceSnapshot.capture(from: context)
                summary = Migrator.summarize(capture)
            } catch {
                errorText = "The old data could not be read: \(error.localizedDescription)"
            }
        }
    }

    private func runThroughCheck() {
        guard let model, let context, !busy else { return }
        busy = true
        errorText = nil
        progress = nil
        report = nil
        stage = .working

        Task {
            let migrator = Migrator(model: model)
            do {
                let result = try await migrator.runThroughCheck(
                    context: context,
                    profile: profile,
                    backupDirectory: nil,
                    progress: { update in
                        Task { @MainActor in progress = update }
                    }
                )
                report = result
                status = try migrator.status()
                stage = .check
            } catch {
                errorText = error.localizedDescription
                stage = .intro
            }
            busy = false
        }
    }

    private func switchNow() {
        guard let model, let report, !busy else { return }
        busy = true
        errorText = nil

        let migrator = Migrator(model: model)
        do {
            try migrator.switchToNewLibrary(report: report)
            status = try migrator.status()

            // The migrator writes no search rows; Agent 14's SearchService owns that index.
            do {
                let search = SearchService(model: model)
                try search.rebuildItems()
                try search.rebuildThoughts()
            } catch {
                searchNote = "The search index could not be rebuilt (\(error.localizedDescription)). Search may miss papers and notes until it is."
            }

            stage = .done
            onFinished()
        } catch {
            errorText = error.localizedDescription
        }
        busy = false
    }
}
