import Foundation

/// A task identifies a particular recording and listening limit, not just a song title.
struct RankQuestion: Codable, Identifiable, Hashable {
    let id: String
    let recordingID: String
    let title: String
    let artist: String
    let album: String
    let catalogIDHint: String?
    let level: Int
    let difficulty: Double
    let pushLimit: Double
    let isClassic: Bool

    static func recordingKey(title: String, artist: String, album: String) -> String {
        [title, artist, album].map(normalizeMetadata).joined(separator: "\u{001F}")
    }

    static func normalizeMetadata(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    func matches(title: String, artist: String, album: String?) -> Bool {
        guard let album else { return false }
        return Self.recordingKey(title: title, artist: artist, album: album) ==
            Self.recordingKey(title: self.title, artist: self.artist, album: self.album)
    }
}

struct RankCatalog: Codable {
    static let bundledVersion = "jp-intro-2026-10-provisional-v1"
    let schemaVersion: Int
    let version: String
    let provisional: Bool
    let questions: [RankQuestion]

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "rank-catalog", withExtension: "json") else {
            throw RankError.invalidCatalog
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, !catalog.version.isEmpty,
              catalog.questions.count >= 200,
              Set(catalog.questions.map(\.id)).count == catalog.questions.count,
              Set(catalog.questions.filter { $0.level == 1 }.map(\.recordingID)).count >= 23,
              catalog.questions.allSatisfy({
                  (1...10).contains($0.level) && $0.difficulty.isFinite &&
                  [3.0, 5.0, 8.0, 12.0].contains($0.pushLimit) &&
                  !$0.id.isEmpty && !$0.recordingID.isEmpty && !$0.artist.isEmpty &&
                  !$0.album.isEmpty && !TitleRules.characters($0.title).isEmpty &&
                  $0.recordingID == RankQuestion.recordingKey(title: $0.title, artist: $0.artist, album: $0.album)
              }), (1...10).allSatisfy({ level in
                  catalog.questions.filter { $0.level == level }.count >= 20
              }) else { throw RankError.invalidCatalog }
        return catalog
    }
}

enum RankError: LocalizedError {
    case invalidCatalog, insufficientQuestions, recordingUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidCatalog: return "段位測定の曲集を読み込めませんでした。アプリを更新してください。"
        case .insufficientQuestions: return "重複と出題の偏りを避けられる曲が不足しています。測定は未完了です。時間をおいて再度お試しください。"
        case .recordingUnavailable: return "指定された録音をApple Musicで確認できませんでした。"
        }
    }
}

enum IntroRank {
    static let names = ["入門", "5級", "4級", "3級", "2級", "1級", "初段", "二段", "三段", "四段", "五段"]
    static func name(_ level: Int) -> String { names[min(10, max(0, level))] }
    static func difficulty(for level: Int) -> Double { -2.7 + Double(level - 1) * 0.6 }
    static func level(for ability: Double) -> Int {
        (1...10).filter { ability >= difficulty(for: $0) + log(0.7 / 0.3) }.count
    }
}

/// Fixed scale and prior are versioned so catalog updates cannot silently change old results.
struct RankEstimator {
    static let version = "rasch-v1"
    private static let grid = (0...120).map { -6.0 + Double($0) * 0.1 }
    private var weights = grid.map { exp(-$0 * $0 / 18) }

    static func probability(ability: Double, difficulty: Double) -> Double {
        1 / (1 + exp(-(ability - difficulty)))
    }

    mutating func observe(difficulty: Double, success: Bool) {
        guard difficulty.isFinite else { return }
        weights = zip(Self.grid, weights).map { ability, weight in
            let p = Self.probability(ability: ability, difficulty: difficulty)
            return weight * (success ? p : 1 - p)
        }
        let total = weights.reduce(0, +)
        if total > 0 { weights = weights.map { $0 / total } }
    }

    func predictedSuccess(difficulty: Double) -> Double {
        zip(Self.grid, weights).reduce(0) {
            $0 + $1.1 * Self.probability(ability: $1.0, difficulty: difficulty)
        } / weights.reduce(0, +)
    }

    func quantile(_ fraction: Double) -> Double {
        let target = weights.reduce(0, +) * fraction
        var cumulative = 0.0
        for (ability, weight) in zip(Self.grid, weights) {
            cumulative += weight
            if cumulative >= target { return ability }
        }
        return Self.grid.last!
    }

    var level: Int { IntroRank.level(for: quantile(0.5)) }
    var lowerLevel: Int { IntroRank.level(for: quantile(0.1)) }
    var upperLevel: Int { IntroRank.level(for: quantile(0.9)) }
    var adjacentConfidence: Double {
        var mass = Array(repeating: 0.0, count: 11)
        let total = weights.reduce(0, +)
        for (ability, weight) in zip(Self.grid, weights) {
            mass[IntroRank.level(for: ability)] += weight / total
        }
        return (0..<10).map { mass[$0] + mass[$0 + 1] }.max() ?? 0
    }
}

enum RankOutcome: String, Codable {
    case correct, wrong, skipped, pushTimeout, answerTimeout, invalid
    var label: String {
        switch self {
        case .correct: return "正解"
        case .wrong: return "誤答"
        case .skipped: return "スキップ"
        case .pushTimeout: return "PUSH時間切れ"
        case .answerTimeout: return "回答時間切れ"
        case .invalid: return "測定対象外"
        }
    }
}

struct RankRoundResult: Codable, Identifiable {
    var id = UUID()
    let question: RankQuestion
    let song: Song?
    let outcome: RankOutcome
    let pushTime: Double?
    let firstExposure: Bool
    let invalidReason: String?
    var success: Bool { outcome == .correct }
    var valid: Bool { outcome != .invalid }
}

struct RankResult: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let catalogVersion: String
    let estimatorVersion: String
    let provisional: Bool
    let level: Int
    let lowerLevel: Int
    let upperLevel: Int
    let ability: Double
    let rounds: [RankRoundResult]

    var comparisonKey: String { catalogVersion + ":" + estimatorVersion }
    var validRounds: [RankRoundResult] { rounds.filter(\.valid) }
    var correct: Int { validRounds.filter(\.success).count }
    var rankLabel: String { IntroRank.name(level) + "相当" }
    var rangeLabel: String {
        lowerLevel == upperLevel ? IntroRank.name(lowerLevel) :
            "\(IntroRank.name(lowerLevel))〜\(IntroRank.name(upperLevel))"
    }
    var nextGoal: String {
        level < 10 ? "\(IntroRank.name(level + 1))相当の課題を、規定時間内に安定して正解しよう。" :
            "五段相当の課題を、異なる曲でも安定して正解しよう。"
    }
}

/// A compact ledger retains first-exposure information even after results leave the 20-session history.
struct RankRecords: Codable {
    var history: [RankResult] = []
    var bestByVersion: [String: RankResult] = [:]
    var seenRecordingIDs: Set<String> = []

    private enum CodingKeys: String, CodingKey { case history, bestByVersion, seenRecordingIDs }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(history, forKey: .history)
        try values.encode(bestByVersion, forKey: .bestByVersion)
        // Stable bytes are needed for the CloudKit merge/retry comparison.
        try values.encode(seenRecordingIDs.sorted(), forKey: .seenRecordingIDs)
    }

    mutating func record(_ result: RankResult) {
        history.removeAll { $0.id == result.id }
        history.append(result)
        history = Self.sorted(history)
        retainBest(result)
        seenRecordingIDs.formUnion(result.validRounds.map { $0.question.recordingID })
    }

    private mutating func retainBest(_ result: RankResult) {
        let previous = bestByVersion[result.comparisonKey]
        if previous == nil || Self.isBetter(result, than: previous!) {
            bestByVersion[result.comparisonKey] = result
        }
    }

    private static func isBetter(_ lhs: RankResult, than rhs: RankResult) -> Bool {
        if lhs.level != rhs.level { return lhs.level > rhs.level }
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func sorted(_ results: [RankResult]) -> [RankResult] {
        Array(results.sorted {
            $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date
        }.prefix(20))
    }

    func merging(_ other: Self) -> Self {
        var merged = self
        var unique: [UUID: RankResult] = [:]
        for result in history + other.history { unique[result.id] = result }
        merged.history = Self.sorted(Array(unique.values))
        for result in other.bestByVersion.values { merged.retainBest(result) }
        for result in merged.history { merged.retainBest(result) }
        merged.seenRecordingIDs.formUnion(other.seenRecordingIDs)
        return merged
    }
}

/// Uses the source playback clock; loading, pauses and clock jumps are not listening time.
struct RankPlaybackMonitor {
    private var lastPosition = 0.0
    private var lastProgressAt: Double?

    mutating func reset(now: Double) {
        lastPosition = 0
        lastProgressAt = now
    }

    mutating func invalidReason(position: Double, playing: Bool, now: Double) -> String? {
        guard position.isFinite, position >= 0 else { return "再生位置を確認できませんでした。" }
        if position < lastPosition - 0.25 { return "音源の再生位置が変わりました。" }
        if position > lastPosition + 0.01, playing {
            lastPosition = position
            lastProgressAt = now
        }
        if now - (lastProgressAt ?? now) >= 2 {
            return "音源の再生が中断されました。"
        }
        return nil
    }
}

struct RankSession {
    static let minimumQuestions = 15
    static let maximumQuestions = 20
    let catalog: RankCatalog
    let previousRecordingIDs: Set<String>
    let previouslySeen: Set<String>
    private(set) var selected: [RankQuestion] = []
    private(set) var rounds: [RankRoundResult] = []
    private(set) var estimator = RankEstimator()

    var validCount: Int { rounds.filter(\.valid).count }
    var shouldFinish: Bool {
        validCount >= Self.maximumQuestions ||
            (validCount >= Self.minimumQuestions && estimator.adjacentConfidence >= 0.8)
    }

    mutating func nextQuestion() throws -> RankQuestion {
        guard !shouldFinish else { throw RankError.insufficientQuestions }
        let used = Set(selected.map(\.recordingID)).union(previousRecordingIDs)
        let classicCount = selected.filter(\.isClassic).count
        let artists = Dictionary(grouping: selected, by: { RankQuestion.normalizeMetadata($0.artist) })
        let candidates = catalog.questions.filter {
            !used.contains($0.recordingID) &&
                (artists[RankQuestion.normalizeMetadata($0.artist)]?.count ?? 0) < 2 &&
                (!$0.isClassic || classicCount < 2) &&
                (validCount >= 3 || $0.level == 1)
        }.shuffled()
        guard let question = candidates.min(by: {
            abs(estimator.predictedSuccess(difficulty: $0.difficulty) - 0.7) <
                abs(estimator.predictedSuccess(difficulty: $1.difficulty) - 0.7)
        }) else { throw RankError.insufficientQuestions }
        selected.append(question)
        return question
    }

    /// Called once for a reserved task. Invalid playback never updates the posterior.
    mutating func record(question: RankQuestion, song: Song?, outcome: RankOutcome,
                         pushTime: Double?, invalidReason: String? = nil) {
        guard selected.contains(where: { $0.id == question.id }),
              !rounds.contains(where: { $0.question.id == question.id }) else { return }
        let time = pushTime.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let actual: RankOutcome = outcome == .correct && (time == nil || time! > question.pushLimit)
            ? .pushTimeout : outcome
        rounds.append(.init(question: question, song: song?.portableReviewSong,
                            outcome: actual, pushTime: time,
                            firstExposure: !previouslySeen.contains(question.recordingID),
                            invalidReason: invalidReason))
        if actual != .invalid { estimator.observe(difficulty: question.difficulty, success: actual == .correct) }
    }

    func result() -> RankResult? {
        guard shouldFinish else { return nil }
        return .init(catalogVersion: catalog.version, estimatorVersion: RankEstimator.version,
                     provisional: catalog.provisional, level: estimator.level,
                     lowerLevel: estimator.lowerLevel, upperLevel: estimator.upperLevel,
                     ability: estimator.quantile(0.5), rounds: rounds)
    }
}
