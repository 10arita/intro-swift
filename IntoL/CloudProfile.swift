import Foundation

struct ProfileValue<Value: Codable & Equatable>: Codable {
    var value: Value
    var modifiedAt: Date

    func merging(_ other: Self) -> Self {
        other.modifiedAt > modifiedAt ? other : self
    }
}

struct ProfileAudioSettings: Codable, Equatable {
    var bgm: Double = 0.35
    var effects: Double = 0.8
    var song: Double = 1
}

struct ProfileReview: Codable {
    // A nil value is a deletion marker, so an offline device cannot resurrect a removed song.
    var value: ReviewSong?
    var modifiedAt: Date
}

struct CloudProfile: Codable {
    var version = 1
    var nickname: ProfileValue<String>
    var avatar: ProfileValue<Data?>
    var audio: ProfileValue<ProfileAudioSettings>
    var selectedBadge: ProfileValue<String?>
    var reviewEntries: [String: ProfileReview]
    var history: [SoloResult]
    // Optional for decoding profiles written before rank measurement existed.
    var rankRecords: RankRecords? = nil
    // Each installation only increments its own counters. Repeated uploads are idempotent.
    var counters: [String: PlayerStats]
    var roomStatisticsByDevice: [String: RoomStatisticsLedger]? = nil
    var serverProfileID: String
    var serverCredentials: [String: String] = [:]
    var importedLegacyProfiles: Set<String> = []

    init(nickname: String = "プレイヤー", avatar: Data? = nil,
         audio: ProfileAudioSettings = .init(), reviews: [ReviewSong] = [],
         history: [SoloResult] = [], stats: PlayerStats = .init(), serverProfileID: String = UUID().uuidString) {
        // Existing CloudKit values take precedence over untouched installation defaults.
        self.nickname = .init(value: nickname, modifiedAt: .distantPast)
        self.avatar = .init(value: avatar, modifiedAt: .distantPast)
        self.audio = .init(value: audio, modifiedAt: .distantPast)
        selectedBadge = .init(value: stats.selectedBadge, modifiedAt: .distantPast)
        reviewEntries = [:]
        for review in reviews { reviewEntries[review.id] = .init(value: review.portable, modifiedAt: review.savedAt) }
        self.history = history
        counters = ["legacy:\(serverProfileID)": stats]
        self.serverProfileID = serverProfileID
    }

    var reviews: [ReviewSong] {
        let portable: [ReviewSong] = reviewEntries.values.compactMap { $0.value?.portable }
        let items = portable.sorted {
            $0.savedAt == $1.savedAt ? $0.id < $1.id : $0.savedAt > $1.savedAt
        }
        return Array(items.filter { !$0.learned }.prefix(50)) + Array(items.filter(\.learned).prefix(50))
    }

    var stats: PlayerStats {
        var result = PlayerStats()
        for item in counters.values {
            result.games += item.games
            result.attempts += item.attempts
            result.correct += item.correct
            result.totalPushSeconds += item.totalPushSeconds
            result.badges.formUnion(item.badges)
            for (genre, value) in item.genres {
                result.genres[genre, default: .init()].attempts += value.attempts
                result.genres[genre, default: .init()].correct += value.correct
            }
        }
        result.awardBadges()
        if let badge = selectedBadge.value, result.badges.contains(badge) { result.selectedBadge = badge }
        return result
    }

    mutating func capture(nickname: String, avatar: Data?, audio: ProfileAudioSettings,
                          reviews: [ReviewSong], history: [SoloResult], stats: PlayerStats,
                          deviceID: String, now: Date = .now) {
        let reviews = reviews.map(\.portable)
        if self.nickname.value != nickname { self.nickname = .init(value: nickname, modifiedAt: now) }
        if self.avatar.value != avatar { self.avatar = .init(value: avatar, modifiedAt: now) }
        if self.audio.value != audio { self.audio = .init(value: audio, modifiedAt: now) }
        if selectedBadge.value != stats.selectedBadge {
            selectedBadge = .init(value: stats.selectedBadge, modifiedAt: now)
        }
        let visible = Set(self.reviews.map(\.id))
        let incoming = Set(reviews.map(\.id))
        for id in visible.subtracting(incoming) { reviewEntries[id] = .init(value: nil, modifiedAt: now) }
        for review in reviews {
            let old = reviewEntries[review.id]?.value
            if old?.learned != review.learned || old?.song != review.song || old?.savedAt != review.savedAt {
                reviewEntries[review.id] = .init(value: review, modifiedAt: now)
            }
        }
        self.history = history
        let before = self.stats
        var local = counters[deviceID] ?? PlayerStats()
        local.games += max(0, stats.games - before.games)
        local.attempts += max(0, stats.attempts - before.attempts)
        local.correct += max(0, stats.correct - before.correct)
        local.totalPushSeconds += max(0, stats.totalPushSeconds - before.totalPushSeconds)
        local.badges.formUnion(stats.badges)
        for (genre, value) in stats.genres {
            let previous = before.genres[genre] ?? GenreRecord()
            local.genres[genre, default: .init()].attempts += max(0, value.attempts - previous.attempts)
            local.genres[genre, default: .init()].correct += max(0, value.correct - previous.correct)
        }
        counters[deviceID] = local
    }

    // The receiving profile is the server's current version, including its canonical identity.
    func merging(_ local: Self) -> Self {
        var result = self
        result.nickname = nickname.merging(local.nickname)
        result.avatar = avatar.merging(local.avatar)
        result.audio = audio.merging(local.audio)
        result.selectedBadge = selectedBadge.merging(local.selectedBadge)
        result.rankRecords = (rankRecords ?? .init()).merging(local.rankRecords ?? .init())
        for (id, entry) in local.reviewEntries {
            if let existing = result.reviewEntries[id] {
                if entry.modifiedAt > existing.modifiedAt { result.reviewEntries[id] = entry }
            } else { result.reviewEntries[id] = entry }
        }
        var results: [UUID: SoloResult] = [:]
        for item in local.history + history { results[item.id] = item }
        result.history = Array(results.values.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }.prefix(5))
        for (id, item) in local.counters {
            result.counters[id] = Self.maximum(result.counters[id] ?? .init(), item)
        }
        for (id, ledger) in local.roomStatisticsByDevice ?? [:] {
            var ledgers = result.roomStatisticsByDevice ?? [:]
            ledgers[id] = (ledgers[id] ?? .init()).merging(ledger)
            result.roomStatisticsByDevice = ledgers
        }
        if serverProfileID == local.serverProfileID {
            result.serverCredentials.merge(local.serverCredentials) { current, _ in current }
        }
        result.importedLegacyProfiles.formUnion(local.importedLegacyProfiles)
        result.enforceReviewLimit()
        return result
    }

    private mutating func enforceReviewLimit() {
        let retained = Set(reviews.map(\.id))
        let date = reviewEntries.values.map(\.modifiedAt).max() ?? .distantPast
        for (id, entry) in reviewEntries where entry.value != nil && !retained.contains(id) {
            reviewEntries[id] = .init(value: nil, modifiedAt: date)
        }
    }

    mutating func importLegacy(reviews: [ReviewSong], history: [SoloResult], stats: PlayerStats?, profileID: String) {
        guard !importedLegacyProfiles.contains(profileID) else { return }
        let legacy = CloudProfile(reviews: reviews, history: history, stats: stats ?? .init(), serverProfileID: profileID)
        self = merging(legacy)
        importedLegacyProfiles.insert(profileID)
    }

    private static func maximum(_ lhs: PlayerStats, _ rhs: PlayerStats) -> PlayerStats {
        var result = lhs
        result.games = max(lhs.games, rhs.games)
        result.attempts = max(lhs.attempts, rhs.attempts)
        result.correct = max(lhs.correct, rhs.correct)
        result.totalPushSeconds = max(lhs.totalPushSeconds, rhs.totalPushSeconds)
        result.badges.formUnion(rhs.badges)
        for (genre, value) in rhs.genres {
            let previous = result.genres[genre] ?? .init()
            result.genres[genre] = .init(attempts: max(previous.attempts, value.attempts),
                                       correct: max(previous.correct, value.correct))
        }
        return result
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case version, nickname, avatar, audio, selectedBadge, reviewEntries, history, counters
        case serverProfileID, serverCredentials, importedLegacyProfiles, roomStatisticsByDevice
        case rankRecords
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(nickname, forKey: .nickname)
        try values.encode(avatar, forKey: .avatar)
        try values.encode(audio, forKey: .audio)
        try values.encode(selectedBadge, forKey: .selectedBadge)
        try values.encode(reviewEntries, forKey: .reviewEntries)
        try values.encode(history, forKey: .history)
        try values.encodeIfPresent(rankRecords, forKey: .rankRecords)
        try values.encode(counters, forKey: .counters)
        try values.encodeIfPresent(roomStatisticsByDevice, forKey: .roomStatisticsByDevice)
        try values.encode(serverProfileID, forKey: .serverProfileID)
        try values.encode(serverCredentials, forKey: .serverCredentials)
        try values.encode(importedLegacyProfiles.sorted(), forKey: .importedLegacyProfiles)
    }
}
