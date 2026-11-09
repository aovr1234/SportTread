import SwiftUI

@main
struct SportTreadApp: App {
    @StateObject private var treadmill = TreadmillController()
    @StateObject private var health = HealthTest()
    @StateObject private var dataFolder = DataFolder()

    var body: some Scene {
        WindowGroup {
            TabView {
                TreadmillView()
                    .tabItem { Label("Treadmill", systemImage: "figure.run") }
                ContentView()
                    .tabItem { Label("Setup", systemImage: "gearshape") }
            }
            .environmentObject(treadmill)
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
