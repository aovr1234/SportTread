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

    /// The history name of a test (left out of the comfortable-speed calculation and the coach's recent workouts)
    static let workoutName = "Fitness test"
    static let warmSeconds = 180
    static let stageSeconds = 180
    static let coolSeconds = 180
    /// The test stops (and cools down) above this share of the estimated maximum heart rate
    static let stopShare = 0.92

    /// Speeds around the comfortable speed `c`: -0.8, -0.4, 0, +0.4, +0.8, +1.2 mph, kept to walking speeds
    /// (1.5 to 4.5 mph); optionally the comfortable speed at 2, 4 and 6 percent incline.
    /// With the person's own easy walk and jog speed, the six stages are spread evenly from a little below the easy
    /// walk to a little below the speed where jogging starts, so walking stays walking.
    static func levels(comfortable c: Double, withIncline: Bool, easy: Double? = nil, jogStart: Double? = nil)
        -> [(mph: Double, incline: Double)] {
        func walk(_ mph: Double) -> Double { (min(max(mph, 1.5), 4.5) * 10).rounded() / 10 }
        var result: [(mph: Double, incline: Double)]
        if let easy, let jogStart {
            let low = max(1.5, easy - 0.2)
            let high = min(4.5, max(jogStart - 0.2, low + 1.0))
            result = (0..<6).map { (walk(low + (high - low) * Double($0) / 5), 0.0) }
        } else {
            result = [-0.8, -0.4, 0, 0.4, 0.8, 1.2].map { (walk(c + $0), 0.0) }
        }
        if withIncline {
            for incline in [2.0, 4.0, 6.0] { result.append((walk(c), incline)) }
        }
        return result
    }

    static func workout(comfortable c: Double, withIncline: Bool, easy: Double? = nil, jogStart: Double? = nil)
        -> (workout: Workout, stages: [Stage]) {
        let levels = levels(comfortable: c, withIncline: withIncline, easy: easy, jogStart: jogStart)
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
        return (Workout(name: workoutName, summary: "Stages of rising speed to learn how your heart responds", steps: steps), stages)
    }

    /// True when the heart rate is high enough that the test should skip to the cool-down.
    static func shouldStop(bpm: Int, maxBpm: Int) -> Bool {
        Double(bpm) >= Double(maxBpm) * stopShare
    }
}

/// Decides when a heart rate is high enough to stop the test: over the line for 3 seconds in a row, or 8 seconds
/// when it jumped more than 25 bpm in the last 10 seconds (probably the armband slipping). Readings of 0 are ignored.
struct StopGuard {
    private var window: [(at: Date, bpm: Int)] = []
    private var aboveSince: Date?

    mutating func update(bpm: Int, at time: Date, maxBpm: Int) -> Bool {
        guard bpm > 0 else { return false }
        window.append((time, bpm))
        window.removeAll { time.timeIntervalSince($0.at) > 10 }
        guard Double(bpm) >= Double(maxBpm) * CalibrationPlan.stopShare else {
            aboveSince = nil
            return false
        }
        let since = aboveSince ?? time
        aboveSince = since
        let lowest = window.map { $0.bpm }.min() ?? bpm
        let needed: TimeInterval = bpm - lowest > 25 ? 8 : 3
        return time.timeIntervalSince(since) >= needed
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
    /// Where the resting heart rate came from ("Apple Health", "measured standing")
    var restingSource: String?

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

    /// Saves a test result. Only a good fit is kept, and only a good fit sets the resting heart rate the zones use.
    static func save(_ model: FitnessModel) {
        guard !model.isNoisy else { return }
        let models = Array((history + [model]).suffix(12))
        if let data = try? JSONEncoder().encode(models) { UserDefaults.standard.set(data, forKey: storeKey) }
        if let resting = model.restingBpm { UserDefaults.standard.set(resting, forKey: BodyProfile.restingKey) }
    }

    /// Clears the saved results and the resting heart rate they set.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        UserDefaults.standard.removeObject(forKey: BodyProfile.restingKey)
    }
}

enum CalibrationAnalysis {
    /// When a stage really started and ended, on the workout clock (a skip to the cool-down or a pause moves them).
    struct Window: Equatable {
        var index: Int
        var mph: Double
        var incline: Double
        var start: Int
        var end: Int
    }

    /// The settled heart rate of each stage: the mean of its last minute. A stage shorter than 90 s is left out; a
    /// stage that was mostly jogging is left out of the walking line and listed in `jogStages`; a stage whose second
    /// half of that minute is more than 3 bpm above the first is listed as unsettled (its number is a little low).
    /// A stage with fewer than 6 heart-rate samples in that minute is skipped.
    static func points(samples: [SessionSample], windows: [Window])
        -> (points: [FitnessModel.Point], unsettled: [Int], jogStages: [Int]) {
        var points: [FitnessModel.Point] = []
        var unsettled: [Int] = []
        var jogStages: [Int] = []
        for window in windows {
            guard window.end - window.start >= 90 else { continue }
            let inStage = samples.filter { $0.t >= window.start && $0.t < window.end }
            if !inStage.isEmpty, Double(inStage.filter { $0.jog == true }.count) / Double(inStage.count) >= 0.4 {
                jogStages.append(window.index)
                continue
            }
            let lastMinute = inStage.filter { $0.t >= window.end - 60 }.compactMap { sample in sample.bpm.map { (sample.t, Double($0)) } }
            guard lastMinute.count >= 6 else { continue }
            let mean = lastMinute.reduce(0) { $0 + $1.1 } / Double(lastMinute.count)
            points.append(FitnessModel.Point(mph: window.mph, incline: window.incline, bpm: mean))
            let first = lastMinute.filter { $0.0 < window.end - 30 }.map { $0.1 }
            let second = lastMinute.filter { $0.0 >= window.end - 30 }.map { $0.1 }
            if !first.isEmpty, !second.isEmpty {
                let rise = second.reduce(0, +) / Double(second.count) - first.reduce(0, +) / Double(first.count)
                if rise > 3 { unsettled.append(window.index) }
            }
        }
        return (points, unsettled, jogStages)
    }

    /// The same on the planned schedule: the stages that were finished by `elapsed`.
    static func points(samples: [SessionSample], stages: [CalibrationPlan.Stage], elapsed: Int)
        -> (points: [FitnessModel.Point], unsettled: [Int]) {
        var windows: [Window] = []
        for (index, stage) in stages.enumerated() where elapsed >= stage.startSecond + stage.seconds - 5 {
            windows.append(Window(index: index + 1, mph: stage.mph, incline: stage.incline,
                                  start: stage.startSecond, end: stage.startSecond + stage.seconds))
        }
        let result = points(samples: samples, windows: windows)
        return (result.points, result.unsettled)
    }
}
