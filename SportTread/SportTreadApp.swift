import SwiftUI

@main
struct SportTreadApp: App {
    @StateObject private var treadmill: TreadmillController
    @StateObject private var runner: WorkoutRunner
    @StateObject private var dataFolder: DataFolder
    @StateObject private var library: WorkoutLibrary
    @StateObject private var coach = Coach()
    @StateObject private var liveCoach = LiveCoach()
    @StateObject private var readiness = Readiness()
    @StateObject private var health = HealthTest()
    @StateObject private var heart: HeartRateMonitor
    @StateObject private var healthSaver: HealthSaver

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let launchState: String
        switch UIApplication.shared.applicationState {
        case .active: launchState = "opened by the user"
        case .inactive: launchState = "starting"
        case .background: launchState = "started in the background by iOS"
        @unknown default: launchState = "unknown"
        }
        DiagnosticsLog.shared.start(launch: launchState + (WorkoutRunner.hasSavedRun ? ", a workout was saved" : ""))
        // One Live Activity at a time: clear leftovers (the workout's own is kept if it is about to be recovered)
        LiveActivityCleanup.endStale(keepWorkout: WorkoutRunner.hasSavedRun)
        let treadmill = TreadmillController()
        let runner = WorkoutRunner(treadmill: treadmill)
        let dataFolder = DataFolder()
        let library = WorkoutLibrary(dataFolder: dataFolder)
        let heart = HeartRateMonitor()
        let saver = HealthSaver()
        treadmill.heartRateProvider = { [weak heart] in heart?.currentReading() }
        runner.onFinish = { [weak library, weak saver] entry in
            library?.record(entry)
            if let saver { Task { await saver.save(entry) } }
        }
        treadmill.onSessionEnd = { [weak library, weak saver] entry in
            library?.record(entry)
            if let saver { Task { await saver.save(entry) } }
        }
        _heart = StateObject(wrappedValue: heart)
        _healthSaver = StateObject(wrappedValue: saver)
        // Live Activity buttons (speed -/+, pause/resume, STOP) run in this process
        LiveControl.handler = { [weak treadmill, weak runner] command in
            guard let treadmill, let runner else { return }
            switch command {
            case .speedUp, .speedDown:
                let target = ((treadmill.targetSpeedNow + (command == .speedUp ? 0.5 : -0.5)) * 10).rounded() / 10
                let value = min(max(target, TreadmillController.minMph), TreadmillController.maxMph)
                if runner.isActive { runner.adjustSpeed(to: value) } else { treadmill.setSpeed(value) }
            case .pauseResume:
                if case .paused = runner.phase {
                    runner.resume()
                } else if runner.isActive {
                    runner.pause()
                } else if treadmill.isRunning {
                    treadmill.stop()
                }
            case .checkIn(let feeling):
                if runner.checkInDue { runner.answerCheckIn(feeling) }
            case .stop:
                if runner.isActive {
                    runner.pause(reason: "Stopped. Resume, or End workout to finish.")
                } else {
                    treadmill.stop()
                }
            }
        }
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
                HistoryView()
                    .tabItem { Label("History", systemImage: "chart.bar.xaxis") }
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
                    .environmentObject(liveCoach)
                    .environmentObject(heart)
                    .preferredColorScheme(.dark)
                    .tint(Theme.lime)
            }
            .environmentObject(treadmill)
            .environmentObject(runner)
            .environmentObject(dataFolder)
            .environmentObject(library)
            .environmentObject(coach)
            .environmentObject(readiness)
            .environmentObject(health)
            .environmentObject(heart)
            .environmentObject(healthSaver)
            .preferredColorScheme(.dark)
            .tint(Theme.lime)
            .task { library.reload() }
            .onChange(of: scenePhase) { _, phase in
                dlog("App \(phase == .active ? "in front" : (phase == .background ? "in the background" : "inactive"))")
            }
            .onChange(of: dataFolder.folderDescription) { library.reload() }  // folder is ready a moment after launch
        }
    }
}
