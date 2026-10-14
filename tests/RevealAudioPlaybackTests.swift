import Foundation

private final class RevealMetadataProtocol: URLProtocol {
    static var replies: [Any] = []
    static var requests: [URLRequest] = []
    static var failure: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        precondition(!Self.replies.isEmpty, "Unexpected metadata request: \(request.url!)")
        let data = try! JSONSerialization.data(withJSONObject: Self.replies.removeFirst())
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main private struct RevealAudioPlaybackTests {
    static let audioURL = URL(string: "https://audio.test/full.wav")!

    static func song(_ id: String, chorusMS: Int? = nil) -> Song {
        Song(id: id, title: "青い空", artist: "歌手",
             previewURL: id.hasPrefix("applemusic:") ? nil : audioURL,
             durationMS: 180_000, genre: "Pop", chorusMS: chorusMS)
    }

    @MainActor static func databaseThenDurationForEveryFullAudioSource() async throws {
        // Solo and room reveals share this pipeline. Old metadata never becomes a third route.
        for id in ["applemusic:123", "shared:recording", "demo:aoi"] {
            for source in [RevealPlaybackSource.manualDatabase, .songleDatabase] {
                for position in [0, 48_681] {
                    var events: [String] = []
                    try await RevealAudioPlayback.play(song(id, chorusMS: 63_500), databaseChorus: {
                        events.append("database"); return position
                    }, databaseSource: { source }, playFullAudio: { actual in
                        precondition(actual == position); events.append("full")
                    }, didStartPlayback: { actual, offset in
                        precondition(actual == source && offset == position); events.append("report")
                    }, isCurrent: { true })
                    precondition(events == ["database", "full", "report"])
                }
            }
            for legacySource in [nil, "songle", "song_metadata", "manual_database", "songle_database"] as [String?] {
                var supplied = song(id, chorusMS: 63_500)
                supplied.chorusSource = legacySource
                var events: [String] = []
                try await RevealAudioPlayback.play(supplied, databaseChorus: {
                    events.append("database miss"); return nil
                }, playFullAudio: { position in
                    precondition(position == nil); events.append("duration")
                }, didStartPlayback: { source, position in
                    precondition(source == .estimated && position == nil)
                }, isCurrent: { true })
                precondition(events == ["database miss", "duration"], "A DB miss must not reuse old song metadata")
            }
        }
    }

    @MainActor static func failuresGoStraightToDuration() async throws {
        for source in [RevealPlaybackSource.manualDatabase, .songleDatabase] {
            var events: [String] = []
            var reports: [RevealPlaybackSource] = []
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: { 48_681 },
                databaseSource: { source }, playFullAudio: { position in
                    if position != nil {
                        events.append("database playback failed")
                        throw URLError(.badServerResponse)
                    }
                    events.append("duration")
                }, stopPlayback: { events.append("stop") },
                didStartPlayback: { source, _ in reports.append(source) }, isCurrent: { true })
            precondition(events == ["database playback failed", "stop", "duration"])
            precondition(reports == [.estimated], "Only the successful route can be reported")
        }
        var reports: [RevealPlaybackSource] = []
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), playFullAudio: { _ in
                throw URLError(.notConnectedToInternet)
            }, didStartPlayback: { source, _ in reports.append(source) }, isCurrent: { true })
            preconditionFailure("Final playback failures must remain visible")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        precondition(reports.isEmpty)
    }

    @MainActor static func previewExcerptsCannotBeRevealed() async throws {
        for id in ["itunes:123", "shared:missing-audio"] {
            var current = song(id, chorusMS: 63_500)
            if id.hasPrefix("shared:") { current.previewURL = nil }
            do {
                try await RevealAudioPlayback.play(current, databaseChorus: {
                    preconditionFailure("Unsupported audio must not query DB or external services")
                }, playFullAudio: { _ in preconditionFailure("Preview-only audio must not play") }, isCurrent: { true })
                preconditionFailure("A full recording is required")
            } catch let error as AppError { precondition(error.localizedDescription == "この曲のフル音源を再生できません") }
        }
    }

    @MainActor static func cancellationNeverStartsOrFallsBack() async throws {
        var current = false
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: {
                preconditionFailure("An obsolete reveal must not query DB")
            }, playFullAudio: { _ in preconditionFailure("An obsolete reveal must not play") }, isCurrent: { current })
            preconditionFailure("An obsolete reveal must cancel")
        } catch is CancellationError { }
        current = true
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: {
                current = false; return 48_681
            }, playFullAudio: { _ in preconditionFailure("An obsolete lookup must not play") }, isCurrent: { current })
            preconditionFailure("Cancellation after DB lookup must propagate")
        } catch is CancellationError { }

        var release: CheckedContinuation<Int?, Never>?
        let playback = Task { @MainActor in
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: {
                await withCheckedContinuation { release = $0 }
            }, playFullAudio: { _ in preconditionFailure("A cancelled lookup must not play") }, isCurrent: { true })
        }
        while release == nil { await Task.yield() }
        playback.cancel()
        release!.resume(returning: 48_681)
        do { try await playback.value; preconditionFailure("Task cancellation must propagate") }
        catch is CancellationError { }

        var attempts = 0
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: { 48_681 }, playFullAudio: { _ in
                attempts += 1; throw CancellationError()
            }, stopPlayback: { preconditionFailure("Cancellation must not enter fallback") }, isCurrent: { true })
            preconditionFailure("Playback cancellation must propagate")
        } catch is CancellationError { }
        precondition(attempts == 1)
    }

    @MainActor static func positionsStayWithinTheAudio() async throws {
        for (duration, expected) in [(180_000, 56_100), (181_234, 56_495), (30_000, 25_000),
                                    (3000, 0), (0, 56_100), (600_000, 88_500)] {
            precondition(RevealAudioPlayback.fallbackPosition(durationMS: duration) == expected)
        }
        precondition(RevealAudioPlayback.validChorus(0, durationMS: 180_000) == 0)
        for invalid in [-1, 180_000, Int.max] {
            try await RevealAudioPlayback.play(song("applemusic:123", chorusMS: invalid), databaseChorus: { invalid },
                playFullAudio: { position in precondition(position == nil, "Invalid DB positions must use duration estimation") },
                isCurrent: { true })
        }
        for position in [0.0, 63_500.4, -1, 180_000, 1e100] {
            let data = try JSONSerialization.data(withJSONObject: ["id": "applemusic:123", "title": "青い空",
                "artist": "歌手", "durationMS": 180_000, "chorusMS": position, "chorusSource": "songle"])
            let current = try JSONDecoder().decode(RoomCurrent.self, from: data)
            precondition(current.song?.chorusMS == (position == 0 ? 0 : position == 63_500.4 ? 63_500 : nil))
        }
    }

    @MainActor static func databaseLookupNeverQueriesLiveSongleOrPreviews() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevealMetadataProtocol.self]
        var localCalls = 0
        let service = RoomService(session: URLSession(configuration: configuration), databaseChorusLookup: { _ in
            localCalls += 1; return 10_000
        })
        var current = song("applemusic:123", chorusMS: 63_500)
        current.songleURL = URL(string: "https://www.youtube.com/watch?v=old-songle")
        RevealMetadataProtocol.requests = []
        let local = await service.databaseChorus(current)
        precondition(local == 10_000 && localCalls == 1 && RevealMetadataProtocol.requests.isEmpty)
        service.baseURL = "https://room.test"
        for (position, source, expectedSource) in [(48_500, "manual_database", "manual_database"),
            (78_500, "manual_database", "manual_database"), (0, "songle_database", "songle_database"),
            (68_500, "songle", "songle_database")] {
            RevealMetadataProtocol.requests = []
            RevealMetadataProtocol.replies = [["databaseConfigured": true, "positionMS": position, "source": source]]
            let result = await service.databaseChorus(current)
            precondition(result == position && localCalls == 1)
            precondition(service.chorusSources[current.id] == expectedSource)
            precondition(RevealMetadataProtocol.requests.map { $0.url!.path } == ["/chorus/database"])
            precondition(RevealMetadataProtocol.requests[0].cachePolicy == .reloadIgnoringLocalCacheData)
        }
        for reply: [String: Any] in [
            ["databaseConfigured": true, "positionMS": NSNull(), "source": NSNull()],
            ["databaseConfigured": true, "positionMS": -1, "source": "manual_database"],
            ["databaseConfigured": true, "positionMS": 180_000, "source": "songle_database"],
            ["databaseConfigured": true, "positionMS": 48_681, "source": "song_metadata"]
        ] {
            RevealMetadataProtocol.requests = []
            RevealMetadataProtocol.replies = [reply]
            let missing = await service.databaseChorus(current)
            precondition(missing == nil && localCalls == 1, "Authoritative DB misses must not resurrect local or cached positions")
            precondition(service.chorusSources[current.id] == nil)
            precondition(RevealMetadataProtocol.requests.map { $0.url!.path } == ["/chorus/database"])
        }
        RevealMetadataProtocol.replies = [["databaseConfigured": false, "positionMS": NSNull()]]
        let fallback = await service.databaseChorus(current)
        precondition(fallback == 10_000 && localCalls == 2)
        precondition(service.chorusSources[current.id] == "manual_database")
        RevealMetadataProtocol.failure = URLError(.notConnectedToInternet)
        let offline = await service.databaseChorus(current)
        precondition(offline == 10_000 && localCalls == 3)
        RevealMetadataProtocol.failure = nil
        let missingService = RoomService(session: URLSession(configuration: configuration))
        RevealMetadataProtocol.requests = []
        let missing = await missingService.databaseChorus(current)
        precondition(missing == nil && RevealMetadataProtocol.requests.isEmpty,
                     "Without a server or local DB match, never query Songle or iTunes")
        let excerpt = await service.databaseChorus(song("itunes:123"))
        precondition(excerpt == nil && RevealMetadataProtocol.requests.isEmpty)
    }

    @MainActor static func main() async throws {
        try await databaseThenDurationForEveryFullAudioSource()
        try await failuresGoStraightToDuration()
        try await previewExcerptsCannotBeRevealed()
        try await cancellationNeverStartsOrFallsBack()
        try await positionsStayWithinTheAudio()
        try await databaseLookupNeverQueriesLiveSongleOrPreviews()
        print("Reveal audio tests passed (DB only, duration fallback, stale metadata, failures, cancellation, no external lookups)")
    }
}
