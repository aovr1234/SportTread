import WatchConnectivity

/// Receives live heart rate from the watch app.
final class PhoneWatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var heartRate: Double?
    @Published var lastUpdate: Date?
    @Published var state = "Connecting to watch…"

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            state = "Watch connectivity not supported"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let text: String
        if activationState != .activated {
            text = "Watch link failed: \(error?.localizedDescription ?? "not activated")"
        } else if !session.isPaired {
            text = "No Apple Watch paired"
        } else if !session.isWatchAppInstalled {
            text = "Watch app not installed. Install it from the Watch app on this iPhone."
        } else {
            text = "Watch app installed"
        }
        DispatchQueue.main.async { self.state = text }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        self.session(session, activationDidCompleteWith: session.activationState, error: nil)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    private func handle(_ payload: [String: Any]) {
        guard let bpm = payload["hr"] as? Double else { return }
        DispatchQueue.main.async {
            self.heartRate = bpm
            self.lastUpdate = Date()
        }
    }
}
