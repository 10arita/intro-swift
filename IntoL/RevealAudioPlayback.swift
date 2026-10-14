import Foundation

enum RevealPlaybackSource: String, Codable {
    case manualDatabase = "manual_database"
    case songleDatabase = "songle_database"
    case estimated = "duration_estimate"
}

/// Reveal playback uses only database positions or an estimate from the full recording's duration.
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
                     databaseSource: () -> RevealPlaybackSource = { .manualDatabase },
                     playFullAudio: (Int?) async throws -> Void,
                     stopPlayback: () -> Void = {},
                     didStartPlayback: (RevealPlaybackSource, Int?) -> Void = { _, _ in },
                     isCurrent: () -> Bool) async throws {
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
        }
        try checkCurrent()
        guard hasFullAudio(song) else { throw AppError.message("この曲のフル音源を再生できません") }
        let database = await databaseChorus()
        try checkCurrent()
        if let position = validChorus(database, durationMS: song.durationMS) {
            let source = databaseSource()
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
        // nil asks the player to estimate from the actual full audio duration.
        try await playFullAudio(nil)
        try checkCurrent()
        didStartPlayback(.estimated, nil)
    }
}
