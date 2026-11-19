import Foundation

/// What the app knows about the person's body: weight, height, age, and the heart rates that follow from them.
/// Pure Foundation (plus UserDefaults for `stored`), so the maths is tested on every build.
struct BodyProfile: Equatable {
    var weightLb = 170.0
    var heightInches: Double?
    var age: Int?
    /// A maximum heart rate the person measured themselves; used instead of the formula when set
    var measuredMaxBpm: Int?
    /// Resting heart rate from the last fitness test
    var restingBpm: Int?

    static let heightKey = "heightInches"
    static let ageKey = "ageYears"
    static let measuredMaxKey = "measuredMaxBpm"
    static let restingKey = "restingBpm"

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
        let resting = defaults.integer(forKey: restingKey)
        if resting >= 30 { profile.restingBpm = resting }
        return profile
    }

    /// Maximum heart rate: the measured one, else 208 minus 0.7 times the age (Tanaka); nil without an age.
    var maxHeartRate: Int? {
        if let measuredMaxBpm, measuredMaxBpm >= 120 { return measuredMaxBpm }
        guard let age else { return nil }
        return Int((208 - 0.7 * Double(age)).rounded())
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
