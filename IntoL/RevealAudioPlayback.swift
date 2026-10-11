import Foundation

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
            var position = validChorus(manual, durationMS: song.durationMS) ?? known
            if position == nil { position = await chorus() }
            try checkCurrent()
            if let position = validChorus(position, durationMS: song.durationMS) {
                do {
                    try await playFullAudio(position)
                    try checkCurrent()
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
    }
}
