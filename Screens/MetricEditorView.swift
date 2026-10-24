//
//  MetricEditorView.swift
//  ResearchBase
//
//  Phase 9 — Experiments & Results
//
//  A single metric add/edit sheet, reused both for a run's own
//  metrics (via ExperimentRunEditorView) and for an experiment's
//  baseline metrics (via ExperimentDetailView's Results tab). The
//  metric list itself (Accuracy, F1, MAE, ...) is only a set of
//  convenience suggestions — any custom name can be typed.
//

import SwiftUI

// MARK: - Result

struct MetricEditorResult: Identifiable {
    /// Set when editing a metric that already exists in the store,
    /// so the caller can tell an edit apart from a brand-new metric
    /// when reconciling a run's in-memory metric list on save.
    var existingID: UUID? = nil

    var name: String
    var value: Double
    var unit: String
    var higherIsBetter: Bool

    var id: UUID { existingID ?? UUID() }
}

// MARK: - Editor

struct MetricEditorView: View {

    let navTitle: String
    let initial: MetricEditorResult?
    let onSave: (MetricEditorResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var valueText: String
    @State private var unit: String
    @State private var higherIsBetter: Bool

    init(
        navTitle: String,
        initial: MetricEditorResult?,
        onSave: @escaping (MetricEditorResult) -> Void
    ) {
        self.navTitle = navTitle
        self.initial = initial
        self.onSave = onSave
        _name = State(initialValue: initial?.name ?? "")
        _valueText = State(initialValue: initial.map { rb9FormatMetricValue($0.value) } ?? "")
        _unit = State(initialValue: initial?.unit ?? "")
        _higherIsBetter = State(initialValue: initial?.higherIsBetter ?? true)
    }

    private var parsedValue: Double? {
        Double(valueText.trimmingCharacters(in: .whitespaces))
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedValue != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(navTitle)
                    .font(RBFont.section(.semibold))
                    .foregroundStyle(RBColor.primaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(RBGhostButtonStyle())

                Button("Save") {
                    guard let value = parsedValue else { return }
                    onSave(
                        MetricEditorResult(
                            existingID: initial?.existingID,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            value: value,
                            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                            higherIsBetter: higherIsBetter
                        )
                    )
                    dismiss()
                }
                .buttonStyle(RBPrimaryButtonStyle())
                .disabled(!isValid)
            }
            .padding(20)

            Divider().overlay(RBColor.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if initial == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            RB9SectionLabel(text: "Common Metrics")

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(CommonMetricName.all, id: \.self) { suggestion in
                                        RBChip(text: suggestion) { name = suggestion }
                                    }
                                }
                            }
                        }
                    }

                    RB9TextField(label: "Metric Name", text: $name, placeholder: "e.g. Accuracy")
                    RB9TextField(label: "Value", text: $valueText, placeholder: "e.g. 89.7")
                    RB9TextField(label: "Unit", text: $unit, placeholder: "e.g. %, ms (optional)")

                    Toggle("Higher is better", isOn: $higherIsBetter)
                        .toggleStyle(.switch)
                        .font(RBFont.secondary())
                        .foregroundStyle(RBColor.primaryText)

                    Text("Used only to work out which run is numerically best for this metric — it never implies the result is significant.")
                        .font(RBFont.label())
                        .foregroundStyle(RBColor.mutedText)
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 440)
        .background(RBColor.elevatedSurface)
    }
}
