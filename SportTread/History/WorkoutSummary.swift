import Foundation

/// One reading of the treadmill, taken every 5 seconds of moving time.
struct SessionSample: Codable, Hashable {
    var t: Int          // seconds of moving time
    var mph: Double
    var incline: Double
    /// Heart rate at that moment, when a sensor was connected
    var bpm: Int? = nil
    /// True when the person said they were jogging at that moment
    var jog: Bool? = nil
}

/// Collects a sample every 5 seconds while a workout or treadmill session runs.
struct SampleLog: Codable {
    private(set) var samples: [SessionSample] = []
    private var lastT = -5

    mutating func reset() {
        samples = []
        lastT = -5
    }

    mutating func add(elapsed: TimeInterval, mph: Double, incline: Double, bpm: Int? = nil, jog: Bool = false) {
        let t = Int(elapsed)
        guard t - lastT >= 5 else { return }
        lastT = t
        samples.append(SessionSample(t: t, mph: (mph * 100).rounded() / 100, incline: (incline * 10).rounded() / 10, bpm: bpm, jog: jog ? true : nil))
    }
}

/// The numbers shown on the finished screen and in History. Everything is worked out by code from
/// the treadmill's own readings; nothing here comes from the AI.
struct WorkoutSummary: Codable, Hashable {
    var miles: Double
    var movingSeconds: Int
    var avgMph: Double
    var topMph: Double
    var avgIncline: Double
    var topIncline: Double
    /// Climb simulated by the incline, in feet (distance × incline %, added up)
    var elevationFeet: Double
    /// ACSM equations from speed, incline and body weight; an estimate
    var calories: Int
    var weightLb: Double
    /// Heart rate over the session, when a sensor was connected
    var avgBpm: Int? = nil
    var peakBpm: Int? = nil
    /// Seconds in heart-rate zones 1 to 5 (when a sensor and a maximum heart rate were known)
    var zoneSeconds: [Int]? = nil
    /// Readings for the chart (at most `maxSamples`)
    var samples: [SessionSample]

    static let maxSamples = 120
    static let defaultWeightLb = 170.0
    static let weightKey = "bodyWeightLb"
    /// Setup switch: calories are left to Apple Fitness on the watch when off
    static let showCaloriesKey = "showCalories"

    /// Body weight set in Setup (pounds), or the default.
    static var storedWeightLb: Double {
        let value = UserDefaults.standard.double(forKey: weightKey)
        return value >= 80 ? value : defaultWeightLb
    }

    /// Pace in seconds per mile; nil when there is no distance yet.
    var paceSeconds: Int? {
        avgMph >= 0.1 ? Int((3600 / avgMph).rounded()) : nil
    }

    static func paceText(_ seconds: Int?) -> String {
        guard let seconds else { return "–" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// ACSM metabolic equations (ml of oxygen per kg per minute): walking up to 4.5 mph, running above.
    static func oxygenUse(mph: Double, inclinePercent: Double) -> Double {
        guard mph > 0 else { return 3.5 }
        let metersPerMinute = mph * 26.8224
        let grade = max(0, inclinePercent) / 100
        if mph <= 4.5 {
            return 0.1 * metersPerMinute + 1.8 * metersPerMinute * grade + 3.5
        }
        return 0.2 * metersPerMinute + 0.9 * metersPerMinute * grade + 3.5
    }

    /// Builds the summary. `miles` and `movingSeconds` are the treadmill's own totals; the samples give
    /// the incline, elevation, calories and the chart.
    static func make(samples: [SessionSample], miles: Double, movingSeconds: Int, weightLb: Double,
                     zones: HeartZones? = nil) -> WorkoutSummary {
        let step = 5.0
        var topMph = 0.0
        var topIncline = 0.0
        var inclineSum = 0.0
        var movingSamples = 0
        var elevation = 0.0
        var kcal = 0.0
        let kg = weightLb * 0.45359237
        var zoneTime = [0, 0, 0, 0, 0]
        for sample in samples {
            if let zones, let bpm = sample.bpm, bpm > 0 {
                let zone = zones.zone(for: Double(bpm))
                if zone >= 1 { zoneTime[zone - 1] += Int(step) }
            }
            topMph = max(topMph, sample.mph)
            topIncline = max(topIncline, sample.incline)
            guard sample.mph > 0 else { continue }
            movingSamples += 1
            inclineSum += sample.incline
            let stepMiles = sample.mph * step / 3600
            elevation += stepMiles * 5280 * max(0, sample.incline) / 100
            let perMinute = oxygenUse(mph: sample.mph, inclinePercent: sample.incline) * kg / 1000 * 5  // kcal per minute
            kcal += perMinute * step / 60
        }
        let avgMph = movingSeconds > 0 ? miles / (Double(movingSeconds) / 3600) : 0
        let beats = samples.compactMap(\.bpm).filter { $0 > 0 }
        return WorkoutSummary(
            miles: miles, movingSeconds: movingSeconds, avgMph: avgMph, topMph: topMph,
            avgIncline: movingSamples > 0 ? inclineSum / Double(movingSamples) : 0,
            topIncline: topIncline, elevationFeet: elevation, calories: Int(kcal.rounded()),
            weightLb: weightLb,
            avgBpm: beats.isEmpty ? nil : Int((Double(beats.reduce(0, +)) / Double(beats.count)).rounded()),
            peakBpm: beats.max(),
            zoneSeconds: zones == nil || beats.isEmpty ? nil : zoneTime,
            samples: thinned(samples))
    }

    /// Keeps the chart data small: every n-th sample when there are more than `maxSamples`.
    static func thinned(_ samples: [SessionSample]) -> [SessionSample] {
        guard samples.count > maxSamples else { return samples }
        let stride = Int((Double(samples.count) / Double(maxSamples)).rounded(.up))
        return samples.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
    }

    /// Time of each completed mile, from the samples (only whole miles).
    func splits() -> [Int] {
        var result: [Int] = []
        var distance = 0.0
        var nextMile = 1.0
        var previousT = 0
        var lastMileT = 0
        for sample in samples {
            let dt = Double(max(0, sample.t - previousT))
            distance += sample.mph * dt / 3600
            previousT = sample.t
            while distance >= nextMile {
                result.append(sample.t - lastMileT)
                lastMileT = sample.t
                nextMile += 1
            }
        }
        return result
    }
}
