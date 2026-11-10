import SwiftUI

@main
struct SportTreadApp: App {
    @StateObject private var treadmill: TreadmillController
    @StateObject private var runner: WorkoutRunner
    @StateObject private var dataFolder: DataFolder
    @StateObject private var library: WorkoutLibrary
    @StateObject private var coach = Coach()
    @StateObject private var health = HealthTest()

    init() {
        let treadmill = TreadmillController()
        let runner = WorkoutRunner(treadmill: treadmill)
        let dataFolder = DataFolder()
        let library = WorkoutLibrary(dataFolder: dataFolder)
        runner.onFinish = { [weak library] entry in library?.record(entry) }
        treadmill.onSessionEnd = { [weak library] entry in library?.record(entry) }
        _treadmill = StateObject(wrappedValue: treadmill)
        _runner = StateObject(wrappedValue: runner)
        _dataFolder = StateObject(wrappedValue: dataFolder)
        _library = StateObject(wrappedValue: library)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                TreadmillView()
                    .tabItem { Label("Treadmill", systemImage: "figure.run") }
                CreateWorkoutView()
                    .tabItem { Label("Coach", systemImage: "sparkles") }
                WorkoutsView()
                    .tabItem { Label("Workouts", systemImage: "list.bullet.rectangle") }
                ContentView()
                    .tabItem { Label("Setup", systemImage: "gearshape") }
            }
            .fullScreenCover(isPresented: Binding(
                get: { runner.phase != .idle },
                set: { if !$0 { runner.dismiss() } }
            )) {
                WorkoutLiveView()
                    .environmentObject(treadmill)
                    .environmentObject(runner)
                    .environmentObject(library)
                    .preferredColorScheme(.dark)
                    .tint(Theme.lime)
            }
            .environmentObject(treadmill)
            .environmentObject(runner)
            .environmentObject(dataFolder)
            .environmentObject(library)
            .environmentObject(coach)
            .environmentObject(health)
            .preferredColorScheme(.dark)
            .tint(Theme.lime)
            .task { library.reload() }
            .onChange(of: dataFolder.folderDescription) { library.reload() }  // folder is ready a moment after launch
        }
    }
}
