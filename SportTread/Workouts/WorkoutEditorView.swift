import SwiftUI

/// Create or edit a workout: name, description and steps (label, duration, speed, incline),
/// with add, delete and reorder. Saving is blocked while any step is outside the safety limits.
struct WorkoutEditorView: View {
    /// The saved workout being edited; nil when creating a new one or editing a copy.
    let original: Workout?
    var onSaved: () -> Void = {}

    @EnvironmentObject private var library: WorkoutLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var workout: Workout
    @State private var saveError: String?

    init(workout: Workout, original: Workout?, onSaved: @escaping () -> Void = {}) {
        self.original = original
        self.onSaved = onSaved
        _workout = State(initialValue: workout)
    }

    static let blank = Workout(
        name: "My workout",
        summary: "",
        steps: [
            WorkoutStep(label: "Warm-up", seconds: 180, mph: 2.5, incline: 0),
            WorkoutStep(label: "Main", seconds: 600, mph: 3.0, incline: 1),
            WorkoutStep(label: "Cool-down", seconds: 180, mph: 2.5, incline: 0),
        ])

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $workout.name)
                        .font(.headline)
                    TextField("Description (optional)", text: $workout.summary, axis: .vertical)
                        .lineLimit(1...3)
                    LabeledContent("Total", value: durationText(workout.totalSeconds))
                }
                .listRowBackground(glassRow)

                Section {
                    WorkoutProfile(workout: workout, height: 70, showAxes: false)
                        .listRowBackground(Color.clear)
                }

                Section("Steps") {
                    ForEach($workout.steps) { $step in
                        StepEditorRow(step: $step)
                    }
                    .onDelete { workout.steps.remove(atOffsets: $0) }
                    .onMove { workout.steps.move(fromOffsets: $0, toOffset: $1) }
                    Button {
                        let last = workout.steps.last
                        let insertAt = max(0, workout.steps.count - (last?.label.lowercased().contains("cool") == true ? 1 : 0))
                        workout.steps.insert(
                            WorkoutStep(label: "Step \(workout.steps.count + 1)", seconds: 120,
                                        mph: workout.steps[safe: insertAt - 1]?.mph ?? 3.0,
                                        incline: workout.steps[safe: insertAt - 1]?.incline ?? 0),
                            at: insertAt)
                    } label: {
                        Label("Add step", systemImage: "plus.circle.fill")
                    }
                }
                .listRowBackground(glassRow)

                if !workout.problems.isEmpty || saveError != nil {
                    Section("Fix before saving") {
                        ForEach(workout.problems, id: \.self) { Text($0).foregroundStyle(.orange) }
                        if let saveError { Text(saveError).foregroundStyle(.orange) }
                    }
                    .listRowBackground(glassRow)
                }
            }
            .sportList()
            .navigationTitle(original == nil ? "New workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!workout.problems.isEmpty || workout.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    EditButton()
                }
            }
        }
    }

    private func save() {
        do {
            if let original {
                try library.update(original, with: workout)
            } else {
                try library.save(workout)
            }
            onSaved()
            dismiss()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

private struct StepEditorRow: View {
    @Binding var step: WorkoutStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Label", text: $step.label).font(.subheadline.weight(.semibold))
            Stepper(value: $step.seconds, in: 30...3600, step: 30) {
                Label(durationText(step.seconds), systemImage: "clock").font(.subheadline.monospacedDigit())
            }
            Stepper(value: $step.mph, in: TreadmillController.minMph...TreadmillController.maxMph, step: 0.1) {
                Label(String(format: "%.1f mph", step.mph), systemImage: "speedometer").font(.subheadline.monospacedDigit())
            }
            Stepper(value: $step.incline, in: 0...TreadmillController.maxIncline, step: 0.5) {
                Label(String(format: "%.1f%%", step.incline), systemImage: "arrow.up.right").font(.subheadline.monospacedDigit())
            }
        }
        .padding(.vertical, 4)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
