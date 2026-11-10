import SwiftUI

/// Coach tab: pick how long (and optionally type, intensity, a note); the coach creates the workout.
struct CreateWorkoutView: View {
    @EnvironmentObject private var coach: Coach
    @EnvironmentObject private var library: WorkoutLibrary
    @EnvironmentObject private var readiness: Readiness
    @State private var request = WorkoutRequest()
    @AppStorage(WorkoutRunner.checkInKey) private var checkInMinutes = 0
    @State private var created: Workout?

    private let quickMinutes = [15, 20, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Form {
                ReadinessSection()
                PlanSection(created: $created)

                Section("How long?") {
                    HStack(spacing: 8) {
                        ForEach(quickMinutes, id: \.self) { minutes in
                            chip("\(minutes)", selected: request.minutes == minutes) { request.minutes = minutes }
                        }
                    }
                    Stepper("\(request.minutes) minutes", value: $request.minutes, in: 10...90, step: 5)
                }

                Section("What kind?") {
                    Picker("Type", selection: $request.kind) {
                        ForEach(WorkoutRequest.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Intensity", selection: $request.intensity) {
                        ForEach(WorkoutRequest.Intensity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Check-ins during workouts", selection: $checkInMinutes) {
                        Text("Off").tag(0)
                        Text("Every 5 min").tag(5)
                        Text("Every 10 min").tag(10)
                    }
                } footer: {
                    Text("\"How's it feeling?\" Hard eases off right away; Easy offers a harder rest.")
                }

                Section {
                    TextField("e.g. knees are sore, or push me today", text: $request.notes, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Anything else? (optional)")
                }

                Section {
                    Button {
                        Task {
                            created = await coach.create(request, history: library.history,
                                                         readiness: readiness.level, readinessNote: readiness.coachSummary)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .symbolEffect(.pulse, isActive: coach.isWorking)
                            Text(coach.isWorking ? "Creating…" : "Create workout")
                        }
                    }
                    .buttonStyle(SportButtonStyle(kind: .go))
                    .disabled(coach.isWorking)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(footer)
                }
            }
            .listRowBackground(glassRow)
            .sportList()
            .navigationTitle("Coach")
            .navigationDestination(item: $created) { workout in
                WorkoutDetailView(workout: workout, isNew: true)
            }
        }
    }

    private var footer: String {
        let source = "Apple Intelligence: \(Coach.appleIntelligenceStatus)."
        return request.kind == .recommend
            ? "Recommend picks the type from your recent workouts. \(source)"
            : source
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)), in: Capsule())
                .foregroundStyle(selected ? .black : .primary)
        }
        .buttonStyle(.plain)
    }
}
