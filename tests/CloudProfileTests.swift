import Foundation

@main struct CloudProfileTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func song(_ id: String) -> Song {
        Song(id: id, title: id, artist: "Artist", durationMS: 180_000, genre: "Pop")
    }

    static func capture(_ profile: inout CloudProfile, stats: PlayerStats, device: String,
                        reviews: [ReviewSong]? = nil, now: Date = .now) {
        profile.capture(nickname: profile.nickname.value, avatar: profile.avatar.value,
                        audio: profile.audio.value, reviews: reviews ?? profile.reviews,
                        history: profile.history, stats: stats, deviceID: device, now: now)
    }

    static func main() throws {
        var initialStats = PlayerStats()
        initialStats.games = 2
        initialStats.attempts = 4
        initialStats.correct = 2
        initialStats.totalPushSeconds = 20
        initialStats.genres = ["Pop": .init(attempts: 4, correct: 2)]
        let base = CloudProfile(stats: initialStats, serverProfileID: "old-profile")

        var phone = base
        var phoneStats = phone.stats
        phoneStats.games += 1; phoneStats.attempts += 1; phoneStats.correct += 1
        phoneStats.totalPushSeconds += 2
        phoneStats.genres["Pop"]!.attempts += 1; phoneStats.genres["Pop"]!.correct += 1
        capture(&phone, stats: phoneStats, device: "phone")

        var tablet = base
        var tabletStats = tablet.stats
        tabletStats.games += 1; tabletStats.attempts += 2; tabletStats.correct += 1
        tabletStats.totalPushSeconds += 7
        tabletStats.genres["Pop"]!.attempts += 2; tabletStats.genres["Pop"]!.correct += 1
        capture(&tablet, stats: tabletStats, device: "tablet")

        let combined = phone.merging(tablet)
        expect(combined.stats.games == 4 && combined.stats.attempts == 7 && combined.stats.correct == 4,
               "Independent offline games must be added exactly once")
        expect(combined.stats.totalPushSeconds == 29 && combined.stats.genres["Pop"]?.attempts == 7,
               "Speed and genre counters must preserve both devices")
        let retried = combined.merging(phone).merging(tablet).merging(combined)
        expect(retried.stats.games == combined.stats.games && retried.stats.attempts == combined.stats.attempts,
               "Retries after ambiguous network failures must not duplicate statistics")
        let retryData = try retried.encoded()
        let combinedData = try combined.encoded()
        expect(retryData == combinedData, "A retry must leave the document unchanged")

        let review = ReviewSong(song: song("one"), savedAt: Date(timeIntervalSince1970: 1))
        var deleted = CloudProfile(reviews: [review])
        let oldDevice = deleted
        capture(&deleted, stats: deleted.stats, device: "phone", reviews: [], now: Date(timeIntervalSince1970: 20))
        expect(deleted.merging(oldDevice).reviews.isEmpty, "A stale offline device must not undo a deletion")
        var readded = deleted
        capture(&readded, stats: readded.stats, device: "phone", reviews: [review], now: Date(timeIntervalSince1970: 30))
        expect(deleted.merging(readded).reviews.count == 1, "An intentional later re-add must work")

        var learned = oldDevice
        var learnedReview = review
        learnedReview.learned = true
        capture(&learned, stats: learned.stats, device: "tablet", reviews: [learnedReview], now: Date(timeIntervalSince1970: 40))
        expect(readded.merging(learned).reviews.first?.learned == true, "The newest learned state must win")
        let many = (0..<60).map { ReviewSong(song: song("song-\($0)"), savedAt: Date(timeIntervalSince1970: Double($0))) }
        let limited = CloudProfile(reviews: Array(many.prefix(30))).merging(CloudProfile(reviews: Array(many.suffix(30))))
        expect(limited.reviews.count == 50, "Each review group must retain at most 50 songs")
        var removedVisible = limited
        capture(&removedVisible, stats: removedVisible.stats, device: "phone", reviews: [], now: Date(timeIntervalSince1970: 100))
        expect(removedVisible.merging(limited).reviews.isEmpty, "Evicted reviews must not reappear after deleting visible reviews")

        var newer = base
        newer.nickname = .init(value: "New name", modifiedAt: Date(timeIntervalSince1970: 50))
        newer.avatar = .init(value: nil, modifiedAt: Date(timeIntervalSince1970: 50))
        newer.audio = .init(value: .init(bgm: 0.1, effects: 0.2, song: 0.3), modifiedAt: Date(timeIntervalSince1970: 50))
        var older = base
        older.avatar = .init(value: Data([1, 2, 3]), modifiedAt: Date(timeIntervalSince1970: 40))
        let preferences = newer.merging(older)
        expect(preferences.nickname.value == "New name" && preferences.avatar.value == nil && preferences.audio.value.bgm == 0.1,
               "Newer profile settings and avatar deletions must survive stale uploads")

        var legacy = CloudProfile(serverProfileID: "old-profile")
        legacy.importLegacy(reviews: [review], history: [], stats: initialStats, profileID: "old-profile")
        legacy.importLegacy(reviews: [review], history: [], stats: initialStats, profileID: "old-profile")
        expect(legacy.stats.games == 2 && legacy.reviews.count == 1, "Server migration must run only once")
        expect(legacy.merging(base).stats.games == 2, "A legacy baseline shared across devices must not be counted twice")

        var remoteIdentity = CloudProfile(serverProfileID: "canonical")
        remoteIdentity.serverCredentials = ["https://server.example": "remote-secret"]
        var localIdentity = CloudProfile(serverProfileID: "installation")
        localIdentity.serverCredentials = ["https://server.example": "unrelated-secret"]
        let identity = remoteIdentity.merging(localIdentity)
        expect(identity.serverProfileID == "canonical" && identity.serverCredentials["https://server.example"] == "remote-secret",
               "A second device must restore the CloudKit identity and never replace its bearer token")

        let results = (0..<8).map { i in
            SoloResult(date: Date(timeIntervalSince1970: Double(i)), playlist: "Demo", total: 1,
                       correct: 1, averagePush: 2, score: 98, rank: "S+")
        }
        var a = base; a.history = Array(results.prefix(4))
        var b = base; b.history = Array(results.suffix(5))
        let history = a.merging(b).history
        expect(history.count == 5 && history.first?.id == results.last?.id, "History must deduplicate IDs and retain the five newest results")

        let restored = try JSONDecoder().decode(CloudProfile.self, from: identity.encoded())
        expect(restored.serverProfileID == identity.serverProfileID && restored.serverCredentials == identity.serverCredentials,
               "The private CloudKit payload must round-trip with identity credentials")
        print("CloudProfile tests passed (offline merge, retry, deletion, settings, migration, identity, history)")
    }
}
