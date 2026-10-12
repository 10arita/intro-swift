import Foundation

private final class RevealMetadataProtocol: URLProtocol {
    static var replies: [Any] = []
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
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
    static let previewURL = URL(string: "https://audio.test/preview.m4a")!

    static func song(_ id: String, chorusMS: Int? = nil) -> Song {
        Song(id: id, title: "青い空", artist: "歌手",
             previewURL: id.hasPrefix("applemusic:") ? nil : previewURL,
             durationMS: 180_000, genre: "Pop", chorusMS: chorusMS)
    }

    @MainActor static func priorityForEveryFullAudioSource() async throws {
        // Both solo and room reveals call this same playback pipeline.
        for id in ["applemusic:123", "shared:recording", "demo:aoi"] {
            for known in [false, true] {
                var events: [String] = []
                try await RevealAudioPlayback.play(song(id, chorusMS: known ? 63_500 : nil), chorus: {
                    events.append("songle")
                    return 63_500
                }, preview: {
                    preconditionFailure("A usable Songle position must take priority over a preview")
                }, playFullAudio: { position in
                    precondition(position == 63_500)
                    events.append("full")
                }, playPreview: { _ in preconditionFailure("Preview must not play") }, isCurrent: { true })
                precondition(events == (known ? ["full"] : ["songle", "full"]))
            }
            var events: [String] = []
            try await RevealAudioPlayback.play(song(id), chorus: {
                events.append("songle"); return nil
            }, preview: {
                events.append("preview lookup"); return previewURL
            }, playFullAudio: { _ in preconditionFailure("Preview must precede duration estimation") },
               playPreview: { url in
                precondition(url == previewURL); events.append("preview")
            }, isCurrent: { true })
            precondition(events == ["songle", "preview lookup", "preview"])

            events = []
            try await RevealAudioPlayback.play(song(id), chorus: {
                events.append("songle"); return nil
            }, preview: {
                events.append("preview lookup"); return nil
            }, playFullAudio: { position in
                precondition(position == nil); events.append("duration")
            }, playPreview: { _ in preconditionFailure("There is no preview") }, isCurrent: { true })
            precondition(events == ["songle", "preview lookup", "duration"])
        }
    }

    @MainActor static func databaseAlwaysPrecedesSongleAndCachedMetadata() async throws {
        for id in ["applemusic:123", "shared:recording", "demo:aoi"] {
            var events: [String] = []
            try await RevealAudioPlayback.play(song(id, chorusMS: 63_500), databaseChorus: {
                events.append("database"); return 48_681
            }, chorus: { preconditionFailure("Songle must not override the manual database") },
               preview: { preconditionFailure("Registered full audio must precede previews") },
               playFullAudio: { position in
                precondition(position == 48_681); events.append("full")
            }, playPreview: { _ in }, isCurrent: { true })
            precondition(events == ["database", "full"], "Cached Songle metadata must also yield to the database")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevealMetadataProtocol.self]
        let service = RoomService(session: URLSession(configuration: configuration), databaseChorusLookup: { _ in 48_681 })
        service.baseURL = "https://room.test"
        RevealMetadataProtocol.replies = [["databaseConfigured": false, "positionMS": NSNull()]]
        let position = await service.chorus(song("applemusic:123"))
        precondition(position == 48_681, "Database lookup must precede the room server and direct Songle")
        try await RevealAudioPlayback.play(song("itunes:123"), databaseChorus: {
            preconditionFailure("Full-song database positions cannot seek preview excerpts")
        }, chorus: { nil }, preview: { previewURL }, playFullAudio: { _ in }, playPreview: { _ in }, isCurrent: { true })
        var current = true
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: {
                current = false; return 48_681
            }, chorus: { preconditionFailure("An obsolete database lookup must cancel") }, preview: { nil },
               playFullAudio: { _ in preconditionFailure("An obsolete database lookup must not play") },
               playPreview: { _ in }, isCurrent: { current })
            preconditionFailure("Cancellation must propagate after database lookup")
        } catch is CancellationError { }
    }

    @MainActor static func failuresTryTheNextSource() async throws {
        for previewFails in [false, true] {
            var events: [String] = []
            try await RevealAudioPlayback.play(song("applemusic:123", chorusMS: 63_500), chorus: { nil },
                preview: { previewURL }, playFullAudio: { position in
                    if position != nil {
                        events.append("chorus failed")
                        throw URLError(.networkConnectionLost)
                    }
                    events.append("duration")
                }, playPreview: { _ in
                    events.append("preview")
                    if previewFails { throw URLError(.badServerResponse) }
                }, stopPlayback: { events.append("stop") }, isCurrent: { true })
            precondition(events == (previewFails ? ["chorus failed", "stop", "preview", "stop", "duration"]
                                                : ["chorus failed", "stop", "preview"]))
        }
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), chorus: { nil }, preview: { nil },
                playFullAudio: { _ in throw URLError(.notConnectedToInternet) }, playPreview: { _ in }, isCurrent: { true })
            preconditionFailure("The final playback failure must be shown to the user")
        } catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
    }

    @MainActor static func previewOnlyNeverSeeksUsingFullSongMetadata() async throws {
        let excerpt = song("itunes:123", chorusMS: 63_500)
        try await RevealAudioPlayback.play(excerpt, chorus: {
            preconditionFailure("Songle's full-song timestamp cannot be used with a preview excerpt")
        }, preview: { excerpt.previewURL }, playFullAudio: { _ in
            preconditionFailure("The full recording is unavailable in preview-only mode")
        }, playPreview: { url in precondition(url == previewURL) }, isCurrent: { true })
        do {
            try await RevealAudioPlayback.play(excerpt, chorus: { nil }, preview: { excerpt.previewURL },
                playFullAudio: { _ in preconditionFailure("Do not seek past the end of a preview") },
                playPreview: { _ in throw URLError(.badServerResponse) }, isCurrent: { true })
            preconditionFailure("Preview failures must remain visible")
        } catch let error as URLError { precondition(error.code == .badServerResponse) }
    }

    @MainActor static func obsoleteLookupsNeverStartPlayback() async throws {
        for obsoleteDuringChorus in [true, false] {
            var current = true
            do {
                try await RevealAudioPlayback.play(song("applemusic:123"), chorus: {
                    if obsoleteDuringChorus { current = false }
                    return obsoleteDuringChorus ? 63_500 : nil
                }, preview: { current = false; return previewURL }, playFullAudio: { _ in
                    preconditionFailure("An obsolete reveal must never play")
                }, playPreview: { _ in preconditionFailure("An obsolete reveal must never play") }, isCurrent: { current })
                preconditionFailure("Leaving the reveal must cancel playback")
            } catch is CancellationError { }
        }
        var release: CheckedContinuation<Int?, Never>?
        let playback = Task { @MainActor in
            try await RevealAudioPlayback.play(song("applemusic:123"), chorus: {
                await withCheckedContinuation { release = $0 }
            }, preview: { preconditionFailure("A cancelled reveal must not fall back") },
               playFullAudio: { _ in preconditionFailure("A cancelled reveal must not play") },
               playPreview: { _ in preconditionFailure("A cancelled reveal must not play") }, isCurrent: { true })
        }
        while release == nil { await Task.yield() }
        playback.cancel()
        release!.resume(returning: 63_500)
        do { try await playback.value; preconditionFailure("Cancellation must propagate") }
        catch is CancellationError { }
    }

    @MainActor static func positionsStayWithinTheAudio() async throws {
        precondition(RevealAudioPlayback.fallbackPosition(durationMS: 180_000) == 56_100)
        precondition(RevealAudioPlayback.fallbackPosition(durationMS: 181_234) == 56_495)
        precondition(RevealAudioPlayback.fallbackPosition(durationMS: 30_000) == 25_000)
        precondition(RevealAudioPlayback.fallbackPosition(durationMS: 3000) == 0)
        precondition(RevealAudioPlayback.fallbackPosition(durationMS: 0) == 56_100)
        precondition(RevealAudioPlayback.validChorus(0, durationMS: 180_000) == 0)
        for invalid in [-1, 180_000, Int.max] {
            try await RevealAudioPlayback.play(song("applemusic:123", chorusMS: invalid), chorus: { invalid },
                preview: { previewURL }, playFullAudio: { _ in preconditionFailure("Invalid positions must not outrank previews") },
                playPreview: { _ in }, isCurrent: { true })
        }
    }

    @MainActor static func metadataHandlesZeroAndInvalidPositions() async throws {
        for position in [0.0, 63_500.4, -1, 180_000, 1e100] {
            let data = try JSONSerialization.data(withJSONObject: ["id": "applemusic:123", "title": "青い空",
                "artist": "歌手", "durationMS": 180_000, "chorusMS": position, "chorusSource": "songle"])
            let current = try JSONDecoder().decode(RoomCurrent.self, from: data)
            precondition(current.song?.chorusMS == (position == 0 ? 0 : position == 63_500.4 ? 63_500 : nil))
            precondition(current.song?.chorusSource == "songle")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevealMetadataProtocol.self]
        let service = RoomService(session: URLSession(configuration: configuration))
        var fullSong = song("shared:recording")
        fullSong.songleURL = URL(string: "https://www.youtube.com/watch?v=recording")
        // An unconfigured solo session talks directly to Songle.
        for start in [1000.0, 65_000, -1, 180_000, 1e100] {
            RevealMetadataProtocol.requests = []
            RevealMetadataProtocol.replies = [["chorusSegments": [["isChorus": true, "repeats": [["start": start]]]]]]
            let position = await service.chorus(fullSong)
            precondition(position == (start == 1000 ? 0 : start == 65_000 ? 63_500 : nil))
            if position != nil { precondition(service.chorusSources[fullSong.id] == "songle") }
            precondition(RevealMetadataProtocol.requests.count == 1)
        }
        service.baseURL = "https://room.test"
        RevealMetadataProtocol.requests = []
        RevealMetadataProtocol.replies = [["databaseConfigured": false, "positionMS": NSNull()], ["positionMS": NSNull()]]
        let missing = await service.chorus(fullSong)
        precondition(missing == nil && RevealMetadataProtocol.requests.count == 2,
                     "A missing server chorus must allow the client to move on to a preview")
        RevealMetadataProtocol.requests = []
        RevealMetadataProtocol.replies = [["databaseConfigured": false, "positionMS": NSNull()], ["positionMS": 0]]
        let zero = await service.chorus(fullSong)
        precondition(zero == 0, "A chorus at the beginning must retain highest priority")

        var matched = song("itunes:123")
        matched.previewURL = previewURL
        RevealMetadataProtocol.replies = [["song": try JSONSerialization.jsonObject(with: JSONEncoder().encode(matched))]]
        let preview = try await service.matchItunes(fullSong)
        precondition(preview?.previewURL == previewURL,
                     "Shared recordings can use a matched iTunes excerpt as their second choice")
    }

    @MainActor static func reportsOnlyTheSourceThatActuallyStarted() async throws {
        for route in [RevealPlaybackSource.manualDatabase, .songleDatabase, .songMetadata, .songle, .preview, .estimated] {
            let usesDatabase = route == .manualDatabase || route == .songleDatabase
            var started: [(RevealPlaybackSource, Int?)] = []
            try await RevealAudioPlayback.play(song("applemusic:123", chorusMS: route == .songMetadata ? 50_000 : nil),
                databaseChorus: { usesDatabase ? 48_681 : nil }, databaseSource: { route },
                chorus: { route == .songle ? 63_500 : nil },
                preview: { route == .preview ? previewURL : nil }, playFullAudio: { _ in },
                playPreview: { _ in }, didStartPlayback: { started.append(($0, $1)) }, isCurrent: { true })
            precondition(started.count == 1 && started[0].0 == route)
            precondition(started[0].1 == (usesDatabase ? 48_681 : route == .songMetadata ? 50_000
                : route == .songle ? 63_500 : route == .preview ? 0 : nil))
        }
        var started: [RevealPlaybackSource] = []
        for source in [RevealPlaybackSource.manualDatabase, .songleDatabase] {
            started = []
            try await RevealAudioPlayback.play(song("applemusic:123"), databaseChorus: { 48_681 }, databaseSource: { source },
                chorus: { nil }, preview: { previewURL }, playFullAudio: { _ in throw URLError(.badServerResponse) },
                playPreview: { _ in }, didStartPlayback: { source, _ in started.append(source) }, isCurrent: { true })
            precondition(started == [.preview], "A failed DB attempt must be reported as the successful preview")
        }
        started = []
        do {
            try await RevealAudioPlayback.play(song("applemusic:123"), chorus: { nil }, preview: { nil },
                playFullAudio: { _ in throw URLError(.badServerResponse) }, playPreview: { _ in },
                didStartPlayback: { source, _ in started.append(source) }, isCurrent: { true })
            preconditionFailure("Failed playback should throw")
        } catch { precondition(started.isEmpty, "No reportable source exists when playback fails") }
        var supplied = song("applemusic:123", chorusMS: 48_681)
        for source in [RevealPlaybackSource.manualDatabase, .songleDatabase] {
            supplied.chorusSource = source.rawValue
            try await RevealAudioPlayback.play(supplied, chorus: { nil }, preview: { nil }, playFullAudio: { _ in },
                playPreview: { _ in }, didStartPlayback: { actual, _ in precondition(actual == source) }, isCurrent: { true })
        }
        let service = RoomService(databaseChorusLookup: { _ in 48_681 })
        _ = await service.chorus(supplied)
        precondition(service.chorusSources[supplied.id] == "manual_database", "Prefetched DB timestamps retain their source")
    }

    @MainActor static func liveDatabaseOverridesCloudAndOldPositions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevealMetadataProtocol.self]
        var cloudCalls = 0
        let service = RoomService(session: URLSession(configuration: configuration), databaseChorusLookup: { _ in
            cloudCalls += 1; return 10_000
        })
        service.baseURL = "https://room.test"
        let current = song("applemusic:123", chorusMS: 10_000)
        for (position, source, expectedSource) in [(48_500, "manual_database", "manual_database"),
            (78_500, "manual_database", "manual_database"), (0, "songle_database", "songle_database"),
            (68_500, "songle", "songle_database")] {
            RevealMetadataProtocol.requests = []
            RevealMetadataProtocol.replies = [["databaseConfigured": true, "positionMS": position, "source": source]]
            let result = await service.databaseChorus(current)
            precondition(result == position && cloudCalls == 0)
            precondition(service.chorusSources[current.id] == expectedSource)
            precondition(service.databaseIsAuthoritative(for: current))
            precondition(RevealMetadataProtocol.requests.count == 1)
            precondition(RevealMetadataProtocol.requests[0].url!.path == "/chorus/database")
            precondition(RevealMetadataProtocol.requests[0].cachePolicy == .reloadIgnoringLocalCacheData)
        }
        RevealMetadataProtocol.replies = [["databaseConfigured": true, "positionMS": NSNull(), "source": NSNull()]]
        let removed = await service.databaseChorus(current)
        precondition(removed == nil && cloudCalls == 0, "A deleted DB row must not fall back to an old CloudKit row")
        var sought: Int?
        try await RevealAudioPlayback.play(current, databaseChorus: { nil }, databaseIsAuthoritative: { true },
            chorus: { 70_000 }, preview: { nil }, playFullAudio: { sought = $0 }, playPreview: { _ in }, isCurrent: { true })
        precondition(sought == 70_000, "A deleted DB row must not resurrect old room metadata")
        var source: RevealPlaybackSource?
        try await RevealAudioPlayback.play(current, databaseChorus: { 70_000 }, databaseSource: { .songleDatabase },
            chorus: { nil }, preview: { nil }, playFullAudio: { _ in }, playPreview: { _ in },
            didStartPlayback: { started, _ in source = started }, isCurrent: { true })
        precondition(source == .songleDatabase, "Songle positions in SQLite must be reported as DB playback")
        RevealMetadataProtocol.replies = [["databaseConfigured": false, "positionMS": NSNull()]]
        let fallback = await service.databaseChorus(current)
        precondition(fallback == 10_000 && cloudCalls == 1 && !service.databaseIsAuthoritative(for: current))
        RevealMetadataProtocol.requests = []
        let preview = await service.databaseChorus(song("itunes:123"))
        precondition(preview == nil && RevealMetadataProtocol.requests.isEmpty)
    }

    @MainActor static func databaseMissDoesNotMislabelLiveSongle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevealMetadataProtocol.self]
        let service = RoomService(session: URLSession(configuration: configuration))
        service.baseURL = "https://room.test"
        let current = song("applemusic:123")
        for source in [RevealPlaybackSource.songleDatabase, .songle] {
            RevealMetadataProtocol.requests = []
            RevealMetadataProtocol.replies = [
                ["databaseConfigured": true, "positionMS": NSNull(), "source": NSNull()],
                ["databaseConfigured": true, "positionMS": 63_500, "source": source.rawValue]
            ]
            var started: RevealPlaybackSource?
            try await RevealAudioPlayback.play(current, chorus: { await service.chorus(current) },
                preview: { nil }, playFullAudio: { position in precondition(position == 63_500) },
                playPreview: { _ in preconditionFailure("Full audio must play") },
                chorusSource: { RevealPlaybackSource(rawValue: service.chorusSources[current.id]!)! },
                didStartPlayback: { actual, _ in started = actual }, isCurrent: { true })
            precondition(started == source, "DB configuration alone must not classify a live Songle lookup as DB")
            precondition(RevealMetadataProtocol.requests.map { $0.url!.path } == ["/chorus/database", "/chorus"])
        }
    }

    @MainActor static func main() async throws {
        try await priorityForEveryFullAudioSource()
        try await databaseAlwaysPrecedesSongleAndCachedMetadata()
        try await failuresTryTheNextSource()
        try await previewOnlyNeverSeeksUsingFullSongMetadata()
        try await obsoleteLookupsNeverStartPlayback()
        try await positionsStayWithinTheAudio()
        try await metadataHandlesZeroAndInvalidPositions()
        try await reportsOnlyTheSourceThatActuallyStarted()
        try await liveDatabaseOverridesCloudAndOldPositions()
        try await databaseMissDoesNotMislabelLiveSongle()
        print("Reveal audio tests passed (all sources, priority, failures, preview excerpts, cancellation, short audio)")
    }
}
