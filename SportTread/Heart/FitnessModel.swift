import Foundation

/// The guided fitness test: a warm-up, six 3-minute walking stages at rising speed (and optionally three
/// more at rising incline), a cool-down. It runs as a normal workout. All pure, tested on every build.
enum CalibrationPlan {
    struct Stage: Equatable {
        var mph: Double
        var incline: Double
        /// Seconds from the start of the workout
        var startSecond: Int
        var seconds: Int
    }

    static let warmSeconds = 180
    static let stageSeconds = 180
    static let coolSeconds = 180
    /// The test stops (and cools down) above this share of the estimated maximum heart rate
    static let stopShare = 0.92

    /// Speeds around the comfortable speed `c`: -0.8, -0.4, 0, +0.4, +0.8, +1.2 mph, kept to walking speeds
    /// (1.5 to 4.5 mph); optionally the comfortable speed at 2, 4 and 6 percent incline.
    static func levels(comfortable c: Double, withIncline: Bool) -> [(mph: Double, incline: Double)] {
        func walk(_ mph: Double) -> Double { (min(max(mph, 1.5), 4.5) * 10).rounded() / 10 }
        var result: [(mph: Double, incline: Double)] = [-0.8, -0.4, 0, 0.4, 0.8, 1.2].map { (walk(c + $0), 0.0) }
        if withIncline {
            for incline in [2.0, 4.0, 6.0] { result.append((walk(c), incline)) }
        }
        return result
    }

    static func workout(comfortable c: Double, withIncline: Bool) -> (workout: Workout, stages: [Stage]) {
        let levels = levels(comfortable: c, withIncline: withIncline)
        var steps = [WorkoutStep(label: "Warm-up", seconds: warmSeconds, mph: levels[0].mph, incline: 0)]
        var stages: [Stage] = []
        var clock = warmSeconds
        for (index, level) in levels.enumerated() {
            let label = level.incline > 0
                ? String(format: "Stage %d/%d: %.1f mph, %g%%", index + 1, levels.count, level.mph, level.incline)
                : String(format: "Stage %d/%d: %.1f mph", index + 1, levels.count, level.mph)
            steps.append(WorkoutStep(label: label, seconds: stageSeconds, mph: level.mph, incline: level.incline))
            stages.append(Stage(mph: level.mph, incline: level.incline, startSecond: clock, seconds: stageSeconds))
            clock += stageSeconds
        }
        steps.append(WorkoutStep(label: "Cool-down", seconds: coolSeconds, mph: max(1.5, ((c - 1.2) * 10).rounded() / 10), incline: 0))
        return (Workout(name: "Fitness test", summary: "Stages of rising speed to learn how your heart responds", steps: steps), stages)
    }

    /// True when the heart rate is high enough that the test should skip to the cool-down.
    static func shouldStop(bpm: Int, maxBpm: Int) -> Bool {
        Double(bpm) >= Double(maxBpm) * stopShare
    }
}

/// How the heart rate responds to speed and incline for this person, fitted from the test.
struct FitnessModel: Codable, Equatable {
    struct Point: Codable, Equatable {
        var mph: Double
        var incline: Double
        var bpm: Double
    }

    var date: Date
    var restingBpm: Int?
    var maxBpm: Int?
    /// Heart rate = base + perMph x speed + perIncline x incline (settled values)
    var base: Double
    var perMph: Double
    var perIncline: Double
    /// How well the line fits the stages, 0 to 1
    var r2: Double
    var points: [Point]
    /// Stages that were still rising when their last minute was measured (their numbers are a little low)
    var unsettled: [Int] = []

    var isNoisy: Bool { r2 < 0.9 }

    func predict(mph: Double, incline: Double = 0) -> Double {
        base + perMph * mph + perIncline * incline
    }

    /// The speed that settles at this heart rate, at the given incline.
    func mph(forBpm bpm: Double, incline: Double = 0) -> Double? {
        guard perMph > 1 else { return nil }
        return (bpm - base - perIncline * incline) / perMph
    }

    /// The incline that settles at this heart rate, at the given speed.
    func incline(forBpm bpm: Double, mph: Double) -> Double? {
        guard perIncline > 0.5 else { return nil }
        return (bpm - base - perMph * mph) / perIncline
    }

    /// Least squares: heart rate against speed, and against incline too when the incline varied.
    /// nil with fewer than 4 points, fewer than 3 different speeds, or a heart rate that doesn't rise with speed.
    static func fit(points: [Point], restingBpm: Int?, maxBpm: Int?, date: Date, unsettled: [Int] = []) -> FitnessModel? {
        guard points.count >= 4, Set(points.map { ($0.mph * 10).rounded() }).count >= 3 else { return nil }
        let useIncline = Set(points.map { ($0.incline * 2).rounded() }).count >= 2
        let columns = useIncline ? 3 : 2
        var matrix = Array(repeating: Array(repeating: 0.0, count: columns + 1), count: columns)
        for p in points {
            let row = useIncline ? [1.0, p.mph, p.incline] : [1.0, p.mph]
            for i in 0..<columns {
                for j in 0..<columns { matrix[i][j] += row[i] * row[j] }
                matrix[i][columns] += row[i] * p.bpm
            }
        }
        // Gaussian elimination with partial pivoting
        for column in 0..<columns {
            guard let pivot = (column..<columns).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-9 else { return nil }
            matrix.swapAt(column, pivot)
            for row in 0..<columns where row != column {
                let factor = matrix[row][column] / matrix[column][column]
                for k in column...columns { matrix[row][k] -= factor * matrix[column][k] }
            }
        }
        let solution = (0..<columns).map { matrix[$0][columns] / matrix[$0][$0] }
        let model = FitnessModel(
            date: date, restingBpm: restingBpm, maxBpm: maxBpm, base: solution[0], perMph: solution[1],
            perIncline: useIncline ? solution[2] : 0, r2: 0, points: points, unsettled: unsettled)
        guard model.perMph > 0 else { return nil }
        let mean = points.reduce(0) { $0 + $1.bpm } / Double(points.count)
        let total = points.reduce(0) { $0 + ($1.bpm - mean) * ($1.bpm - mean) }
        let error = points.reduce(0) { $0 + ($1.bpm - model.predict(mph: $1.mph, incline: $1.incline)) * ($1.bpm - model.predict(mph: $1.mph, incline: $1.incline)) }
        var result = model
        result.r2 = total > 0 ? max(0, 1 - error / total) : 0
        return result
    }

    // MARK: Saved model

    private static let storeKey = "fitnessModels"

    /// The fits so far, newest last (the last 12 are kept).
    static var history: [FitnessModel] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let models = try? JSONDecoder().decode([FitnessModel].self, from: data) else { return [] }
        return models
    }

    static var latest: FitnessModel? { history.last }

    static func save(_ model: FitnessModel) {
        let models = Array((history + [model]).suffix(12))
        if let data = try? JSONEncoder().encode(models) { UserDefaults.standard.set(data, forKey: storeKey) }
        if let resting = model.restingBpm { UserDefaults.standard.set(resting, forKey: BodyProfile.restingKey) }
    }
}

enum CalibrationAnalysis {
    /// The settled heart rate of each stage that was completed: the mean of its last minute. A stage whose second
    /// half of that minute is more than 3 bpm above the first is listed as unsettled (its number is a little low).
    /// Stages with fewer than 6 heart-rate samples in that minute are skipped.
    static func points(samples: [SessionSample], stages: [CalibrationPlan.Stage], elapsed: Int)
        -> (points: [FitnessModel.Point], unsettled: [Int]) {
        var points: [FitnessModel.Point] = []
        var unsettled: [Int] = []
        for (index, stage) in stages.enumerated() {
            let end = stage.startSecond + stage.seconds
            guard elapsed >= end - 5 else { continue }
            let window = samples.filter { $0.t >= end - 60 && $0.t < end }.compactMap { sample in sample.bpm.map { (sample.t, Double($0)) } }
            guard window.count >= 6 else { continue }
            let mean = window.reduce(0) { $0 + $1.1 } / Double(window.count)
            points.append(FitnessModel.Point(mph: stage.mph, incline: stage.incline, bpm: mean))
            let first = window.filter { $0.0 < end - 30 }.map { $0.1 }
            let second = window.filter { $0.0 >= end - 30 }.map { $0.1 }
            if !first.isEmpty, !second.isEmpty {
                let rise = second.reduce(0, +) / Double(second.count) - first.reduce(0, +) / Double(first.count)
                if rise > 3 { unsettled.append(index + 1) }
            }
        }
        return (points, unsettled)
    }
}
