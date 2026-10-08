import Foundation

@main private struct GameRecoveryTests {
    static func snapshot(_ ledger: RoomStatisticsLedger, stats: PlayerStats) throws -> CloudProfile {
        var profile = CloudProfile(stats: stats, serverProfileID: "recovery-player")
        profile.roomStatisticsByDevice = ["phone": ledger]
        return try JSONDecoder().decode(CloudProfile.self, from: profile.encoded())
    }

    static func statisticsSurviveRestart() throws {
        var ledger = RoomStatisticsLedger()
        var stats = PlayerStats()
        var event = RoomStatsEvent(gameID: "server:room:1:player", round: 0,
                                  pushed: true, pushTimeMS: 1_234, genre: "Pop")
        precondition(ledger.record(event, stats: &stats))
        precondition(stats.attempts == 1 && stats.correct == 0 && stats.totalPushSeconds == 1.234,
                     "Use the accepted PUSH time, independent of when the snapshot is received")
        let pushed = try snapshot(ledger, stats: stats)
        ledger = pushed.roomStatisticsByDevice!["phone"]!
        stats = pushed.stats
        precondition(!ledger.record(event, stats: &stats), "Restoring a pushed round must not add an attempt")
        event.result = "correct"
        precondition(ledger.record(event, stats: &stats))
        let revealed = try snapshot(ledger, stats: stats)
        ledger = revealed.roomStatisticsByDevice!["phone"]!
        stats = revealed.stats
        precondition(!ledger.record(event, stats: &stats), "Restoring a reveal must not add a correct answer")
        precondition(stats.attempts == 1 && stats.correct == 1 && stats.genres["Pop"]?.correct == 1)
        event.finished = true
        precondition(ledger.record(event, stats: &stats))
        let finished = try snapshot(ledger, stats: stats)
        ledger = finished.roomStatisticsByDevice!["phone"]!
        stats = finished.stats
        precondition(!ledger.record(event, stats: &stats) && stats.games == 1)
        precondition(ledger.record(.init(gameID: "server:room:2:player", round: 0,
                                       pushed: true, pushTimeMS: 500, result: "wrong", genre: "Pop"), stats: &stats))
        precondition(stats.attempts == 2 && stats.correct == 1 && stats.genres["Pop"]?.attempts == 2)

        var legacy = RoomStatisticsLedger()
        var legacyStats = PlayerStats()
        legacyStats.games = 3
        precondition(legacy.record(.init(gameID: "legacy", round: -1, finished: true,
                                        previouslyFinished: true), stats: &legacyStats))
        precondition(legacyStats.games == 3, "Old finished-game markers must migrate without double counting")
    }

    static func ledgerMergesWithoutLosingDeduplication() throws {
        var local = RoomStatisticsLedger(), remote = RoomStatisticsLedger()
        var a = PlayerStats(), b = PlayerStats()
        let first = RoomStatsEvent(gameID: "game-a", round: 0, pushed: true, pushTimeMS: 1000, result: "correct")
        let second = RoomStatsEvent(gameID: "game-b", round: 1, pushed: true, pushTimeMS: 2000, result: "wrong")
        var pushed = first
        pushed.result = nil
        local.record(pushed, stats: &a)
        remote = local
        b = a
        remote.record(first, stats: &b)
        remote.record(second, stats: &b)
        var phone = try snapshot(local, stats: a)
        var other = try snapshot(remote, stats: b)
        other.counters = ["phone": b]
        phone.counters = ["phone": a]
        let merged = phone.merging(other)
        var ledger = merged.roomStatisticsByDevice!["phone"]!
        var stats = merged.stats
        precondition(stats.attempts == 2 && stats.correct == 1 && stats.totalPushSeconds == 3)
        precondition(!ledger.record(first, stats: &stats) && !ledger.record(second, stats: &stats),
                     "A stale cloud payload must preserve both sets of recorded rounds")
        let encoded = try merged.encoded()
        let retried = try merged.merging(phone).merging(other).encoded()
        precondition(encoded == retried,
                     "Repeated ledger merges must leave the profile payload unchanged")

        let legacy = CloudProfile(serverProfileID: "legacy")
        let restored = try JSONDecoder().decode(CloudProfile.self, from: legacy.encoded())
        precondition(restored.roomStatisticsByDevice == nil, "Profiles without a ledger remain readable")
    }

    static func demoReviewsUseCurrentBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources/Audio")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test." + UUID().uuidString, "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let audio = resources.appendingPathComponent("aoi.wav")
        try Data([0]).write(to: audio)
        let bundle = Bundle(url: root)!
        let oldURL = URL(fileURLWithPath: "/old-installation/IntoL.app/Audio/aoi.wav")
        let song = Song(id: "demo:aoi", title: "青い航路", artist: "IntoL Sessions",
                        previewURL: oldURL, durationMS: 30_000, genre: "オリジナル")
        var profile = CloudProfile(reviews: [.init(song: song)])
        precondition(profile.reviewEntries[song.id]?.value?.song.previewURL == nil)
        // Simulate a payload saved by an older installation.
        profile.reviewEntries[song.id]?.value?.song.previewURL = oldURL
        precondition(profile.reviews[0].song.previewURL == nil)
        profile.capture(nickname: profile.nickname.value, avatar: nil, audio: profile.audio.value,
                        reviews: profile.reviews, history: [], stats: profile.stats, deviceID: "phone")
        precondition(profile.reviewEntries[song.id]?.value?.song.previewURL == nil)
        let restored = try JSONDecoder().decode(CloudProfile.self, from: profile.encoded())
        precondition(DemoCatalog.previewURL(for: restored.reviews[0].song, bundle: bundle) == audio,
                     "Restore demo audio from this installation rather than a saved absolute path")
        var remote = song
        remote.id = "itunes:123"
        remote.previewURL = URL(string: "https://example.test/preview.m4a")
        precondition(remote.portableReviewSong.previewURL == remote.previewURL)
        precondition(DemoCatalog.previewURL(for: remote, bundle: bundle) == remote.previewURL)
    }

    @MainActor static func preparationCancellation() async {
        for replace in [false, true] {
            let preparation = RoomPreparationTask()
            var release: CheckedContinuation<Void, Never>?
            var obsoleteReady = false, replacementReady = false
            let completion = Task { @MainActor in
                await withCheckedContinuation { finished in
                    preparation.start {
                        await withCheckedContinuation { release = $0 }
                        if !Task.isCancelled { obsoleteReady = true }
                        finished.resume()
                    }
                }
            }
            while release == nil { await Task.yield() }
            if replace {
                await withCheckedContinuation { finished in
                    preparation.start { replacementReady = true; finished.resume() }
                }
            } else { preparation.cancel() }
            release!.resume()
            await completion.value
            precondition(!obsoleteReady && replacementReady == replace,
                         "Cancelled or replaced preparation must not send readiness after completing")
        }
    }

    @MainActor static func sessionGuards() {
        precondition(GameSessionAvailability.canStartSolo(gameActive: false, roomActive: false, roomID: nil))
        precondition(!GameSessionAvailability.canStartSolo(gameActive: true, roomActive: false, roomID: nil))
        precondition(!GameSessionAvailability.canStartSolo(gameActive: false, roomActive: true, roomID: "ROOM"))
        precondition(!GameSessionAvailability.canStartSolo(gameActive: false, roomActive: false, roomID: "RESTORING"))
        for status in [403, 404] {
            precondition(RoomService.isExpiredSession(RoomHTTPError(status: status, message: "参加していません", state: nil)))
        }
        precondition(!RoomService.isExpiredSession(RoomHTTPError(status: 500, message: "再試行", state: nil)))
        precondition(!RoomService.isExpiredSession(URLError(.networkConnectionLost)))
    }

    static func lateJoinPlayback() throws {
        let rules = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RoomSettings()))
        let base: [String: Any] = [
            "id": "ABCDEF", "mode": "shared", "hostId": "host", "phase": "listening", "round": 1,
            "totalRounds": 6, "settings": rules, "players": [], "serverNow": 15_000,
            "startAt": 10_000, "roundDeadline": 40_000, "pushClosed": false,
            "answerProgress": "", "options": [], "activeAnswers": [], "pushedIds": [],
            "skippedIds": [], "readyIds": [], "correctPlayerIDs": [],
            "current": ["id": "song", "previewURL": "https://example.test/song.wav"]
        ]
        func room(_ changes: [String: Any] = [:]) throws -> RoomState {
            try JSONDecoder().decode(RoomState.self, from: JSONSerialization.data(
                withJSONObject: base.merging(changes) { _, new in new }))
        }
        let listening = try room()
        precondition(listening.questionPlaybackOffsetMS(for: "guest", nowMS: 15_000) == 5_000)
        precondition(listening.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == 8_000,
                     "Loading for three seconds must seek to the current position, not the join position")
        precondition(listening.questionPlaybackOffsetMS(for: "guest", nowMS: 40_000) == nil,
                     "Do not start question audio if loading outlasts the question")
        let countdown = try room(["phase": "countdown"])
        precondition(countdown.questionPlaybackOffsetMS(for: "guest", nowMS: 9_000) == 0)
        let paused = try room(["phase": "answering", "pausedAt": 15_000])
        precondition(paused.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == nil)
        let resumed = try room(["startAt": 13_000, "roundDeadline": 43_000])
        precondition(resumed.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == 5_000,
                     "A relay pause during loading must be reflected in the resumed position")
        let answering = try room(["phase": "answering", "activeAnswers": [["playerId": "host", "progress": "青"]]])
        precondition(answering.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == 8_000)
        precondition(answering.questionPlaybackOffsetMS(for: "host", nowMS: 18_000) == nil)
        let closed = try room(["pushClosed": true])
        precondition(closed.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == nil)
        let missingStart = try room(["startAt": NSNull()])
        precondition(missingStart.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == nil)
        for phase in ["lobby", "preparing", "countdown", "listening", "answering", "reveal", "finished"] {
            let state = try room(["phase": phase])
            precondition(state.acceptsNewPlayers == (phase != "finished"))
            if ["lobby", "preparing", "reveal", "finished"].contains(phase) {
                precondition(state.questionPlaybackOffsetMS(for: "guest", nowMS: 18_000) == nil)
            }
        }
    }

    @MainActor static func main() async throws {
        try statisticsSurviveRestart()
        try ledgerMergesWithoutLosingDeduplication()
        try demoReviewsUseCurrentBundle()
        await preparationCancellation()
        sessionGuards()
        try lateJoinPlayback()
        print("Game recovery tests passed (statistics restart, accepted PUSH time, cloud merge, portable demos, cancellation, session guards, late-join playback)")
    }
}
