import SwiftUI

@main
struct SportTreadApp: App {
    @StateObject private var treadmill: TreadmillController
    @StateObject private var runner: WorkoutRunner
    @StateObject private var health = HealthTest()
    @StateObject private var dataFolder = DataFolder()

    init() {
        let treadmill = TreadmillController()
        _treadmill = StateObject(wrappedValue: treadmill)
        _runner = StateObject(wrappedValue: WorkoutRunner(treadmill: treadmill))
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                TreadmillView()
                    .tabItem { Label("Treadmill", systemImage: "figure.run") }
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
                    .preferredColorScheme(.dark)
                    .tint(Theme.volt)
            }
            .environmentObject(treadmill)
            .environmentObject(runner)
            .environmentObject(health)
            .environmentObject(dataFolder)
            .preferredColorScheme(.dark)
            .tint(Theme.volt)
        }
    }
}

enum Theme {
    static let volt = Color(red: 0.776, green: 1.0, blue: 0.0)  // #C6FF00
}
