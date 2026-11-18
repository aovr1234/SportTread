import AppIntents
import Foundation

/// What the Live Activity buttons can ask the app to do.
enum LiveCommand: Equatable {
    case speedUp, speedDown, pauseResume, stop
    case checkIn(String)
}

/// The app sets `handler` when it launches. The Live Activity buttons run these intents inside the app's
/// own process (that is what LiveActivityIntent means), so the handler has the treadmill and the workout.
/// The widget extension only draws the buttons and never calls the handler.
@MainActor
enum LiveControl {
    static var handler: (@MainActor (LiveCommand) -> Void)?
}

struct LiveSpeedUpIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Speed up"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveControl.handler?(.speedUp)
        return .result()
    }
}

struct LiveSpeedDownIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Slow down"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveControl.handler?(.speedDown)
        return .result()
    }
}

struct LivePauseResumeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveControl.handler?(.pauseResume)
        return .result()
    }
}

struct LiveCheckInIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer the check-in"

    @Parameter(title: "Feeling")
    var feeling: String

    init() {}

    init(feeling: String) {
        self.feeling = feeling
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveControl.handler?(.checkIn(feeling))
        return .result()
    }
}

struct LiveStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop the belt"
    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        LiveControl.handler?(.stop)
        return .result()
    }
}
