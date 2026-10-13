import Foundation

@main struct RankMeasurementTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func testCatalog(_ bank: RankCatalog) throws {
        expect(bank.questions.count >= 200 && Set(bank.questions.map(\.recordingID)).count == bank.questions.count,
               "The reviewed bank contains distinct pinned recordings")
        expect(bank.questions.filter(\.isClassic).count > 10, "Reviewed additions restore selected pre-2010 songs")
        expect(bank.version == RankCatalog.bundledVersion && bank.provisional, "Popularity-based difficulties remain provisional")
        for level in 1...10 {
            expect(bank.questions.filter { $0.level == level }.count >= 20, "Each level needs a usable pool")
            let tasks = bank.questions.filter { $0.level == level }
            let modern = tasks.filter { !$0.isClassic }
            let artists = Dictionary(grouping: modern, by: { $0.artistKey })
            expect(artists.values.reduce(0) { $0 + min(2, $1.count) } >= 20,
                   "Every tier retains enough modern candidates under the artist cap")
        }
        let q = bank.questions[0]
        expect(q.matches(title: q.title, artist: q.artist, album: q.album), "Exact recording matches")
        expect(!q.matches(title: q.title, artist: q.artist, album: "Live"), "Different recordings cannot be substituted")
        expect(!q.matches(title: q.title + " (Live)", artist: q.artist, album: q.album), "Version suffixes remain significant")
        expect(!q.matches(title: q.title, artist: "Cover Artist", album: q.album), "A cover is not the original")
        expect(!q.matches(title: q.title, artist: q.artist, album: nil), "Unknown recording metadata is rejected")
        var localized = q
        localized.answerTitle = "出典の曲名"
        localized.artistGroupID = "source-artist"
        expect(localized.quizTitle == "出典の曲名", "Provider subtitles do not change the title used for answers")
        expect(localized.matches(title: q.title, artist: q.artist, album: q.album), "Recording matching still uses provider metadata")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(localized)) as! [String: Any]
        legacy.removeValue(forKey: "answerTitle")
        legacy.removeValue(forKey: "artistGroupID")
        let decoded = try JSONDecoder().decode(RankQuestion.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(decoded.quizTitle == q.title && decoded.artistKey == RankQuestion.normalizeMetadata(q.artist),
               "Old history entries retain their original answer and artist grouping")

        let aliases = Array(bank.questions.filter { $0.level == 1 }.prefix(3)).enumerated().map { index, q in
            RankQuestion(id: q.id, recordingID: q.recordingID, title: q.title, artist: "Provider credit \(index)",
                         album: q.album, catalogIDHint: nil, level: 1, difficulty: q.difficulty,
                         pushLimit: q.pushLimit, isClassic: false, artistGroupID: "one-performer")
        }
        let aliasBank = RankCatalog(schemaVersion: 1, version: bank.version, provisional: true, questions: aliases)
        var grouped = RankSession(catalog: aliasBank, previousRecordingIDs: [], previouslySeen: [])
        for _ in 0..<2 {
            let task = try grouped.nextQuestion()
            grouped.record(question: task, song: nil, outcome: .wrong, pushTime: 1)
        }
        do { _ = try grouped.nextQuestion(); preconditionFailure("Provider credit aliases must not bypass the artist cap") }
        catch RankError.insufficientQuestions { }
        var invalid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bank)) as! [String: Any]
        invalid["questions"] = Array(bank.questions.prefix(10)).map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        do {
            _ = try RankCatalog.decode(JSONSerialization.data(withJSONObject: invalid))
            preconditionFailure("Incomplete banks must not silently produce ranks")
        } catch RankError.invalidCatalog { }
    }

    static func simulate(_ bank: RankCatalog, success: (Int, RankQuestion) -> Bool) throws -> RankResult {
        var session = RankSession(catalog: bank, previousRecordingIDs: [], previouslySeen: [])
        while !session.shouldFinish {
            let question = try session.nextQuestion()
            let index = session.validCount
            expect(index >= 3 || question.level == 1, "The first three valid questions must be easy")
            session.record(question: question, song: nil, outcome: success(index, question) ? .correct : .wrong, pushTime: 0.5)
            expect(session.validCount >= 15 || !session.shouldFinish, "One mistake must not terminate measurement")
        }
        expect((15...20).contains(session.validCount), "Measurement has a bounded length")
        let result = session.result()!
        expect(Set(result.rounds.map { $0.question.recordingID }).count == result.rounds.count, "Recordings cannot repeat")
        expect(result.rounds.filter { $0.question.isClassic }.count <= 2, "Classics are capped")
        let artists = Dictionary(grouping: result.rounds, by: { $0.question.artistKey })
        expect(artists.values.allSatisfy { $0.count <= 2 }, "An artist cannot dominate the test")
        expect(result.lowerLevel <= result.level && result.level <= result.upperLevel, "The estimate lies in its interval")
        return result
    }

    static func testInference(_ bank: RankCatalog) throws {
        let perfect = try simulate(bank) { _, _ in true }
        let zero = try simulate(bank) { _, _ in false }
        let boundary = try simulate(bank) { n, _ in n % 4 != 0 }
        let oneMiss = try simulate(bank) { n, _ in n != 2 }
        expect(perfect.ability > boundary.ability && boundary.ability > zero.ability, "Ability changes with observed performance")
        expect(perfect.rounds.dropFirst(3).contains { $0.question.level >= 8 }, "Strong players reach the hardest pool")
        expect(zero.level == 0, "No successful recognition cannot award a passing rank")
        expect(oneMiss.level >= perfect.level - 2, "One unknown song does not collapse a strong result")
        let uninformative = RankCatalog(schemaVersion: bank.schemaVersion, version: bank.version, provisional: true,
                                       questions: bank.questions.map {
            RankQuestion(id: $0.id, recordingID: $0.recordingID, title: $0.title, artist: $0.artist,
                         album: $0.album, catalogIDHint: nil, level: $0.level, difficulty: 100,
                         pushLimit: $0.pushLimit, isClassic: $0.isClassic)
        })
        let uncertain = try simulate(uninformative) { _, _ in false }
        expect(uncertain.validRounds.count == 20, "Uncertain boundaries continue to the maximum")

        var session = RankSession(catalog: bank, previousRecordingIDs: [], previouslySeen: [])
        let q = try session.nextQuestion()
        let original = session.estimator.quantile(0.5)
        expect(session.result() == nil, "A partial measurement has no final result")
        session.record(question: q, song: nil, outcome: .invalid, pushTime: nil, invalidReason: "Playback failed")
        expect(session.validCount == 0 && session.estimator.quantile(0.5) == original, "Invalid playback adds no evidence")
        session.record(question: q, song: nil, outcome: .correct, pushTime: 1)
        expect(session.rounds.count == 1, "Duplicate callback cannot change the outcome")
        let replacement = try session.nextQuestion()
        expect(replacement.level == 1 && replacement.recordingID != q.recordingID, "Invalid warmups are replaced with another easy recording")
        session.record(question: replacement, song: nil, outcome: .correct, pushTime: replacement.pushLimit + 0.001)
        expect(session.rounds.last?.outcome == .pushTimeout, "Late recognition cannot count as correct")
        let nonfinite = try session.nextQuestion()
        session.record(question: nonfinite, song: nil, outcome: .correct, pushTime: .nan)
        expect(session.rounds.last?.outcome == .pushTimeout, "An invalid clock cannot award credit")
        let next = try session.nextQuestion()
        session.record(question: next, song: nil, outcome: .correct, pushTime: next.pushLimit)
        expect(session.rounds.last?.success == true, "A PUSH exactly on the limit is accepted")
        expect(session.rounds.filter(\.valid).allSatisfy(\.firstExposure), "Initial measurements retain first-exposure flags")
        var seen = RankSession(catalog: bank, previousRecordingIDs: [], previouslySeen: Set(bank.questions.map(\.recordingID)))
        let seenTask = try seen.nextQuestion()
        seen.record(question: seenTask, song: nil, outcome: .wrong, pushTime: 1)
        expect(seen.rounds.first?.firstExposure == false, "Repeated exposure is excluded from first-attempt calibration data")

        let used = Set(perfect.rounds.map { $0.question.recordingID })
        var replay = RankSession(catalog: bank, previousRecordingIDs: used, previouslySeen: used)
        for _ in 0..<20 {
            if replay.shouldFinish { break }
            let item = try replay.nextQuestion()
            expect(!used.contains(item.recordingID), "The previous session is excluded")
            replay.record(question: item, song: nil, outcome: .wrong, pushTime: 1)
        }
        var exhausted = RankSession(catalog: bank, previousRecordingIDs: Set(bank.questions.map(\.recordingID)), previouslySeen: [])
        do { _ = try exhausted.nextQuestion(); preconditionFailure("An exhausted pool must fail") }
        catch RankError.insufficientQuestions { }
        expect(exhausted.result() == nil, "An incomplete session has no rank")
        let easy = bank.questions.filter { $0.level == 1 }
        var afterTwentyEasy = RankSession(catalog: bank,
                                          previousRecordingIDs: Set(easy.prefix(20).map(\.recordingID)), previouslySeen: [])
        for _ in 0..<3 {
            let task = try afterTwentyEasy.nextQuestion()
            expect(task.level == 1, "Even twenty previous easy tracks leave three fresh warmups")
            afterTwentyEasy.record(question: task, song: nil, outcome: .wrong, pushTime: 1)
        }
    }

    static func testAudioClock() {
        var clock = RankPlaybackMonitor()
        clock.reset(now: 100)
        expect(clock.invalidReason(position: 0, playing: false, now: 101) == nil, "Brief startup buffering is tolerated")
        expect(clock.invalidReason(position: 0.5, playing: true, now: 101.5) == nil, "Source playback advances the clock")
        expect(clock.invalidReason(position: 0.5, playing: false, now: 103.6) != nil, "A pause or stalled source invalidates the question")
        clock.reset(now: 110)
        _ = clock.invalidReason(position: 3, playing: true, now: 110.2)
        expect(clock.invalidReason(position: 1, playing: true, now: 110.3) != nil, "A seek cannot shorten listening time")
        expect(clock.invalidReason(position: .nan, playing: true, now: 110.4) != nil, "Invalid player positions are rejected")
    }

    static func testPersistence(_ bank: RankCatalog) throws {
        let perfect = try simulate(bank) { _, _ in true }
        let low = try simulate(bank) { _, _ in false }
        var left = RankRecords(), right = RankRecords()
        left.record(perfect)
        for i in 0..<23 {
            var result = low
            result.id = UUID()
            result.date = perfect.date.addingTimeInterval(Double(i + 1))
            if i % 2 == 0 { left.record(result) } else { right.record(result) }
        }
        let merged = left.merging(right)
        expect(merged.history.count == 20, "Only 20 recent measurements are retained")
        expect(!merged.history.contains { $0.id == perfect.id }, "The older best can leave recent history")
        expect(merged.bestByVersion[perfect.comparisonKey]?.id == perfect.id, "All-time best survives history trimming")
        expect(merged.merging(right).history.count == 20, "Repeated sync does not duplicate results")
        let encode: (RankRecords) throws -> Data = { records in
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return try encoder.encode(records)
        }
        let forward = try encode(left.merging(right)), reverse = try encode(right.merging(left))
        expect(forward == reverse, "Independent devices merge deterministically")
        let repeated = try encode(merged.merging(merged)), once = try encode(merged)
        expect(repeated == once, "Sync is idempotent")
        var changedVersion = low
        // Build a different-scale result without mutating an existing version's best.
        changedVersion = RankResult(catalogVersion: "new-bank", estimatorVersion: low.estimatorVersion,
                                    provisional: false, level: low.level, lowerLevel: low.lowerLevel,
                                    upperLevel: low.upperLevel, ability: low.ability, rounds: low.rounds)
        var updated = merged
        updated.record(changedVersion)
        expect(updated.bestByVersion.count == 2, "Best records are separated by scale version")

        var profile = CloudProfile(history: [SoloResult.make(playlist: "Old", total: 1, pushTimes: [2])])
        let legacy = try JSONDecoder().decode(CloudProfile.self, from: profile.encoded())
        expect(legacy.rankRecords == nil && legacy.history.count == 1, "Old profiles remain readable")
        profile.rankRecords = left
        var remote = legacy
        remote.rankRecords = right
        let restored = try JSONDecoder().decode(CloudProfile.self, from: profile.merging(remote).encoded())
        expect(restored.rankRecords?.history.count == 20 && restored.history.count == 1, "Cloud profile preserves both histories")
        expect(restored.rankRecords?.bestByVersion[perfect.comparisonKey]?.level == perfect.level, "Cloud roundtrip preserves best rank")
        expect(restored.stats.games == 0 && restored.stats.attempts == 0, "Rank measurements do not alter normal-play counters")
    }

    static func testHighestRank() throws {
        let names = ["F", "E", "D", "C", "C+", "B", "B+", "A", "A+", "S", "S+"]
        expect(IntroRank.names == names, "Rank measurement has the agreed eleven ranks in ascending order")
        func result(_ level: Int, catalog: String = "old-catalog", date: Date = .now) -> RankResult {
            RankResult(date: date, catalogVersion: catalog, estimatorVersion: "old-estimator", provisional: true,
                       level: level, lowerLevel: level, upperLevel: level, ability: 0, rounds: [])
        }
        var records = RankRecords()
        expect(records.highestRankLevel == nil, "An unmeasured profile has no badge")
        for level in names.indices {
            records.record(result(level))
            expect(records.highestRankLevel == level, "Every measured rank, including F, can earn a badge")
            expect(result(level).rankLabel == names[level] + "相当", "Stored numeric levels use the new display names")
        }
        let best = result(10, date: Date(timeIntervalSince1970: 1))
        records = RankRecords()
        records.record(best)
        for index in 0..<25 {
            records.record(result(3, catalog: "new-catalog", date: Date(timeIntervalSince1970: Double(index + 2))))
        }
        expect(records.history.count == 20 && !records.history.contains { $0.id == best.id }, "Recent history can trim the best result")
        expect(records.highestRankLevel == 10, "The earned badge spans catalogs and survives history trimming")
        var remote = RankRecords()
        remote.record(result(8, catalog: "another-catalog"))
        var localProfile = CloudProfile(), remoteProfile = CloudProfile()
        localProfile.rankRecords = records; remoteProfile.rankRecords = remote
        let restored = try JSONDecoder().decode(CloudProfile.self, from: localProfile.merging(remoteProfile).encoded())
        expect(restored.rankRecords?.highestRankLevel == 10, "Cloud merging and decoding retain the highest badge")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as! [String: Any]
        expect(encoded["highestRankLevel"] == nil, "The badge is derived without changing the saved record schema")
        var corrupted = remote
        corrupted.record(result(99))
        expect(corrupted.highestRankLevel == 8, "Invalid stored levels must not become earned badges")
        expect(result(10).nextGoal.contains("S+相当"), "The final goal uses the new highest rank name")
    }

    static func main() throws {
        let bank = try RankCatalog.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        try testCatalog(bank)
        try testInference(bank)
        testAudioClock()
        try testPersistence(bank)
        try testHighestRank()
        print("Rank measurement tests passed (catalog, adaptation, limits, exclusions, invalid audio, legacy/cloud records)")
    }
}
