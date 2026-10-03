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
                "artist": "歌手", "durationMS": 180_000, "chorusMS": position])
            let current = try JSONDecoder().decode(RoomCurrent.self, from: data)
            precondition(current.song?.chorusMS == (position == 0 ? 0 : position == 63_500.4 ? 63_500 : nil))
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
            precondition(RevealMetadataProtocol.requests.count == 1)
        }
        service.baseURL = "https://room.test"
        RevealMetadataProtocol.requests = []
        RevealMetadataProtocol.replies = [["positionMS": NSNull()]]
        let missing = await service.chorus(fullSong)
        precondition(missing == nil && RevealMetadataProtocol.requests.count == 1,
                     "A missing server chorus must allow the client to move on to a preview")
        RevealMetadataProtocol.requests = []
        RevealMetadataProtocol.replies = [["positionMS": 0]]
        let zero = await service.chorus(fullSong)
        precondition(zero == 0, "A chorus at the beginning must retain highest priority")

        var matched = song("itunes:123")
        matched.previewURL = previewURL
        RevealMetadataProtocol.replies = [["song": try JSONSerialization.jsonObject(with: JSONEncoder().encode(matched))]]
        let preview = try await service.matchItunes(fullSong)
        precondition(preview?.previewURL == previewURL,
                     "Shared recordings can use a matched iTunes excerpt as their second choice")
    }

    @MainActor static func main() async throws {
        try await priorityForEveryFullAudioSource()
        try await failuresTryTheNextSource()
        try await previewOnlyNeverSeeksUsingFullSongMetadata()
        try await obsoleteLookupsNeverStartPlayback()
        try await positionsStayWithinTheAudio()
        try await metadataHandlesZeroAndInvalidPositions()
        print("Reveal audio tests passed (all sources, priority, failures, preview excerpts, cancellation, short audio)")
    }
}
