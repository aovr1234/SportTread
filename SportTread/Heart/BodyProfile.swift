import Foundation

/// What the app knows about the person's body: weight, height, age, and the heart rates that follow from them.
/// Pure Foundation (plus UserDefaults for `stored`), so the maths is tested on every build.
struct BodyProfile: Equatable {
    var weightLb = 170.0
    var heightInches: Double?
    var age: Int?
    /// A maximum heart rate the person measured themselves; used instead of the formula when set
    var measuredMaxBpm: Int?
    /// Resting heart rate: typed in, else from the last good fitness test, else Apple Health's
    var restingBpm: Int?
    /// The person's own speed scale (0 = not set): an easy walk, a fast walk, and where jogging starts
    var easyWalkMph: Double?
    var fastWalkMph: Double?
    var jogStartMph: Double?

    static let heightKey = "heightInches"
    static let ageKey = "ageYears"
    static let measuredMaxKey = "measuredMaxBpm"
    static let restingKey = "restingBpm"
    static let manualRestingKey = "manualRestingBpm"
    static let healthRestingKey = "healthRestingBpm"
    static let easyWalkKey = "easyWalkMph"
    static let fastWalkKey = "fastWalkMph"
    static let jogStartKey = "jogStartMph"

    /// Read from Setup (UserDefaults); unset values are nil.
    static var stored: BodyProfile {
        let defaults = UserDefaults.standard
        var profile = BodyProfile()
        let weight = defaults.double(forKey: "bodyWeightLb")
        if weight >= 80 { profile.weightLb = weight }
        let height = defaults.double(forKey: heightKey)
        if height >= 40 { profile.heightInches = height }
        let age = defaults.integer(forKey: ageKey)
        if age >= 10 { profile.age = age }
        let measured = defaults.integer(forKey: measuredMaxKey)
        if measured >= 120 { profile.measuredMaxBpm = measured }
        for key in [manualRestingKey, restingKey, healthRestingKey] {
            let resting = defaults.integer(forKey: key)
            if resting >= 30 {
                profile.restingBpm = resting
                break
            }
        }
        let easy = defaults.double(forKey: easyWalkKey)
        if easy >= 1 { profile.easyWalkMph = easy }
        let fast = defaults.double(forKey: fastWalkKey)
        if fast >= 1 { profile.fastWalkMph = fast }
        let jog = defaults.double(forKey: jogStartKey)
        if jog >= 2 { profile.jogStartMph = jog }
        return profile
    }

    /// Maximum heart rate: the measured one, else 208 minus 0.7 times the age (Tanaka); nil without an age.
    var maxHeartRate: Int? {
        if let measuredMaxBpm, measuredMaxBpm >= 120 { return measuredMaxBpm }
        guard let age else { return nil }
        return Int((208 - 0.7 * Double(age)).rounded())
    }

    /// Easy and fast walk, when both are set and make sense.
    var personalSpeeds: (easy: Double, fast: Double)? {
        guard let easyWalkMph, let fastWalkMph, fastWalkMph > easyWalkMph else { return nil }
        return (easyWalkMph, fastWalkMph)
    }

    /// The walking and jogging speeds the prompts and checks use: the person's own when set.
    var speedLimits: SpeedLimits {
        var limits = SpeedLimits()
        if let easyWalkMph { limits.walkLow = max(1.5, easyWalkMph - 0.3) }
        if let jogStartMph {
            limits.walkHigh = jogStartMph - 0.2
            limits.jogLow = jogStartMph
            limits.jogHigh = jogStartMph + 2.0
        }
        return limits
    }

    var zones: HeartZones? {
        maxHeartRate.map { HeartZones(maxBpm: $0, restingBpm: restingBpm) }
    }

    /// The comfortable speed of someone with no workouts yet: 3.0 mph at 5'9", scaled with the square root of
    /// the height (leg length), between 2.6 and 3.6 mph.
    static func startingSpeed(heightInches: Double?) -> Double {
        guard let height = heightInches, height >= 40 else { return 3.0 }
        let scaled = 3.0 * (height / 69).squareRoot()
        return (min(max(scaled, 2.6), 3.6) * 10).rounded() / 10
    }
}

/// The five heart-rate zones. With a resting heart rate the zones are shares of the heart-rate reserve
/// (Karvonen), otherwise shares of the maximum: Zone 1 50-60%, 2 60-70%, 3 70-80%, 4 80-90%, 5 90-100%.
struct HeartZones: Equatable {
    let maxBpm: Int
    let restingBpm: Int?

    private static let edges = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    private func bpm(at share: Double) -> Double {
        if let restingBpm, restingBpm < maxBpm {
            return Double(restingBpm) + Double(maxBpm - restingBpm) * share
        }
        return Double(maxBpm) * share
    }

    /// Lower and upper heart rate of a zone, 1 to 5.
    func range(_ zone: Int) -> ClosedRange<Double> {
        let z = min(max(zone, 1), 5)
        return bpm(at: Self.edges[z - 1])...bpm(at: Self.edges[z])
    }

    /// 0 below Zone 1, otherwise 1 to 5 (above the maximum counts as 5).
    func zone(for heartRate: Double) -> Int {
        for z in stride(from: 5, through: 1, by: -1) where heartRate >= range(z).lowerBound { return z }
        return 0
    }

    func midpoint(_ zone: Int) -> Int {
        let r = range(zone)
        return Int(((r.lowerBound + r.upperBound) / 2).rounded())
    }
}

/// The walking and jogging speed ranges used in prompts and checks.
struct SpeedLimits: Equatable {
    var walkLow = 2.5
    var walkHigh = 3.8
    var jogLow = 4.0
    var jogHigh = 6.0

    static let standard = SpeedLimits()
}

/// The resting heart rate from a minute of standing still, and which source to trust.
enum RestingHeartRate {
    /// The lowest average of 15 readings in a row (the heart is still settling at the start), nil with fewer than 15.
    static func estimate(readings: [Int]) -> Int? {
        let values = readings.filter { $0 > 0 }
        guard values.count >= 15 else { return nil }
        var best = Double.infinity
        for start in 0...(values.count - 15) {
            let mean = Double(values[start..<(start + 15)].reduce(0, +)) / 15
            best = min(best, mean)
        }
        return Int(best.rounded())
    }

    /// A standing reading more than 20 bpm above the resting rate Apple Health knows is not a resting rate.
    static func choose(measured: Int?, health: Int?) -> (bpm: Int, source: String)? {
        switch (measured, health) {
        case let (m?, h?): return m > h + 20 ? (h, "Apple Health") : (m, "measured standing")
        case let (m?, nil): return (m, "measured standing")
        case let (nil, h?): return (h, "Apple Health")
        default: return nil
        }
    }
}
