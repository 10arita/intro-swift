import Foundation

enum RevealPlaybackSource: String, Codable {
    case manualDatabase = "manual_database"
    case songMetadata = "song_metadata"
    case songle
    case preview = "itunes_preview"
    case estimated = "duration_estimate"
}

/// Database and Songle positions refer to the full recording, never to an iTunes excerpt.
@MainActor enum RevealAudioPlayback {
    static func hasFullAudio(_ song: Song) -> Bool {
        !song.id.hasPrefix("itunes:") && (song.id.hasPrefix("applemusic:") || song.previewURL != nil)
    }

    static func validChorus(_ positionMS: Int?, durationMS: Int) -> Int? {
        guard let positionMS, positionMS >= 0,
              durationMS <= 0 || positionMS < durationMS else { return nil }
        return positionMS
    }

    static func fallbackPosition(durationMS: Int) -> Int {
        let duration = Double(durationMS > 0 ? durationMS : 180_000)
        let estimated = min(90_000, max(30_000, duration * 0.32)) - 1500
        // Keep at least five seconds audible, including short original recordings.
        return Int(max(0, min(estimated, duration - 5000)).rounded())
    }

    static func play(_ song: Song,
                     databaseChorus: () async -> Int? = { nil },
                     chorus: () async -> Int?,
                     preview: () async -> URL?,
                     playFullAudio: (Int?) async throws -> Void,
                     playPreview: (URL) async throws -> Void,
                     stopPlayback: () -> Void = {},
                     chorusSource: () -> RevealPlaybackSource = { .songle },
                     didStartPlayback: (RevealPlaybackSource, Int?) -> Void = { _, _ in },
                     isCurrent: () -> Bool) async throws {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        let fullAudio = hasFullAudio(song)
        if fullAudio {
            let manual = await databaseChorus()
            try checkCurrent()
            let known = validChorus(song.chorusMS, durationMS: song.durationMS)
            let database = validChorus(manual, durationMS: song.durationMS)
            var position = database ?? known
            var source: RevealPlaybackSource = database != nil ? .manualDatabase
                : RevealPlaybackSource(rawValue: song.chorusSource ?? "") ?? .songMetadata
            if position == nil {
                position = await chorus()
                source = chorusSource()
            }
            try checkCurrent()
            if let position = validChorus(position, durationMS: song.durationMS) {
                do {
                    try await playFullAudio(position)
                    try checkCurrent()
                    didStartPlayback(source, position)
                    return
                } catch {
                    if error is CancellationError { throw error }
                    try checkCurrent()
                    stopPlayback()
                }
            }
        }
        let previewURL = await preview()
        try checkCurrent()
        if let previewURL {
            do {
                try await playPreview(previewURL)
                try checkCurrent()
                didStartPlayback(.preview, 0)
                return
            } catch {
                if error is CancellationError { throw error }
                try checkCurrent()
                stopPlayback()
                if !fullAudio { throw error }
            }
        }
        guard fullAudio else { throw AppError.message("この曲の試聴音源を再生できません") }
        // nil asks the player to estimate from the actual full audio duration.
        try await playFullAudio(nil)
        try checkCurrent()
        didStartPlayback(.estimated, nil)
    }
}
