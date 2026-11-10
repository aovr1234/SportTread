import SwiftUI

/// Coach tab sections: today's readiness and the training plan.
struct ReadinessSection: View {
    @EnvironmentObject private var readiness: Readiness

    var body: some View {
        Section {
            if let level = readiness.level, let score = readiness.score {
                HStack(spacing: 14) {
                    ZStack {
                        RingProgress(progress: Double(score) / 100, lineWidth: 8)
                        Text("\(score)").font(.headline.monospacedDigit())
                    }
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(level.rawValue).font(.headline).foregroundStyle(color(level))
                        Text(readiness.details.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text(readiness.status).font(.subheadline).foregroundStyle(.secondary)
            }
            Button(readiness.level == nil ? "Check readiness" : "Refresh") {
                Task { await readiness.refresh() }
            }
        } header: {
            Text("Readiness today")
        } footer: {
            Text("From resting heart rate, HRV and sleep that your watch or Oura records in Apple Health (read only). On \"Take it easy\" days the coach makes workouts easy.")
        }
        .listRowBackground(glassRow)
        .task { if readiness.level == nil { await readiness.refresh() } }
    }

    private func color(_ level: Readiness.Level) -> Color {
        switch level {
        case .ready: Theme.lime
        case .moderate: Theme.cyan
        case .easy: .orange
        }
    }
}

struct PlanSection: View {
    @EnvironmentObject private var library: WorkoutLibrary
    @EnvironmentObject private var coach: Coach
    @EnvironmentObject private var readiness: Readiness
    @Binding var created: Workout?
    @State private var settingUp = false
    @State private var confirmingEnd = false

    var body: some View {
        Section {
            if let plan = library.plan, let week = plan.week() {
                let done = plan.done(in: week, history: library.history)
                let next = plan.nextRequest(week: week, doneThisWeek: done)
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.goal.rawValue).font(.headline)
                    Text("Week \(week) of \(plan.weeks) · \(min(done, plan.perWeek)) of \(plan.perWeek) workouts done")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    GradientBar(progress: (Double(week - 1) + Double(min(done, plan.perWeek)) / Double(plan.perWeek)) / Double(plan.weeks))
                }
                .padding(.vertical, 4)
                if done < plan.perWeek {
                    LabeledContent("Next", value: "\(next.minutes) min \(next.intensity.rawValue.lowercased()) \(next.kind.rawValue.lowercased())")
                    Button {
                        Task {
                            created = await coach.create(next, history: library.history,
                                                         readiness: readiness.level, readinessNote: readiness.coachSummary)
                        }
                    } label: {
                        Label(coach.isWorking ? "Creating…" : "Create this workout", systemImage: "sparkles")
                    }
                    .disabled(coach.isWorking)
                } else {
                    Label("This week's workouts are done. Nice.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.lime)
                }
                Button("End plan", role: .destructive) { confirmingEnd = true }
            } else {
                if let plan = library.plan {
                    Text(plan.week() == nil && Date() > plan.weekStart(plan.weeks + 1)
                         ? "Your \(plan.weeks)-week plan is complete."
                         : "Your plan starts \(plan.start.formatted(date: .abbreviated, time: .omitted)).")
                        .foregroundStyle(.secondary)
                }
                Button {
                    settingUp = true
                } label: {
                    Label("Start a plan", systemImage: "calendar.badge.plus")
                }
            }
        } header: {
            Text("Plan")
        }
        .listRowBackground(glassRow)
        .sheet(isPresented: $settingUp) { PlanSetupView() }
        .confirmationDialog("End this plan?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End plan", role: .destructive) { library.setPlan(nil) }
        }
    }
}

private struct PlanSetupView: View {
    @EnvironmentObject private var library: WorkoutLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var goal = TrainingPlan.Goal.fitter
    @State private var weeks = 6
    @State private var perWeek = 3
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            Form {
                Picker("Goal", selection: $goal) {
                    ForEach(TrainingPlan.Goal.allCases) { Text($0.rawValue).tag($0) }
                }
                Stepper("\(weeks) weeks", value: $weeks, in: 4...12)
                Stepper("\(perWeek) workouts a week", value: $perWeek, in: 2...5)
                Stepper("\(minutes) minutes to start", value: $minutes, in: 15...60, step: 5)
                Section {
                    Text("Weeks 1–2 are easy, every 4th week is lighter, the last third is harder, and workouts get a little longer each week. The coach creates each workout when you're ready for it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .sportList()
            .navigationTitle("New plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        library.setPlan(TrainingPlan(goal: goal, weeks: weeks, perWeek: perWeek, minutes: minutes, start: Date()))
                        dismiss()
                    }
                }
            }
        }
    }
}
