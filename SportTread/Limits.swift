import Foundation

/// The treadmill's working range. Plain constants so the pure workout code (and its build-time
/// tests) doesn't need the Bluetooth controller.
enum TreadmillLimits {
    static let minMph = 0.5
    static let maxMph = 10.0
    static let maxIncline = 10.0
}
