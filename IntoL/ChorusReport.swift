import Foundation

/// An explicit allowlist keeps profile, room, and device identifiers out of reports.
struct ChorusReport: Encodable, Identifiable {
    struct Track: Encodable {
        let id: String
        let title: String
        let artist: String
        let durationMS: Int
        let genre: String
        let trackURL: URL?
    }

    struct Playback: Encodable {
        let source: RevealPlaybackSource
        let audioSource: String
        let startPositionMS: Int
    }

    let id: UUID
    let song: Track
    let playback: Playback
    let playMode: String
    let appVersion: String
    let appBuild: String

    init(song: Song, source: RevealPlaybackSource, startPositionMS: Int, playMode: String) {
        id = UUID()
        self.song = Track(id: song.id, title: song.title, artist: song.artist,
                          durationMS: song.durationMS, genre: song.genre, trackURL: song.trackURL)
        playback = Playback(source: source,
                            audioSource: source == .preview ? "itunes_preview"
                                : song.id.hasPrefix("applemusic:") ? "apple_music" : "full_audio",
                            startPositionMS: startPositionMS)
        self.playMode = playMode
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

struct ChorusReportService {
    var session: URLSession = .shared

    func send(_ report: ChorusReport, serverURL: String) async throws {
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https" || (base.scheme == "http" && ["localhost", "127.0.0.1"].contains(base.host ?? "")) else {
            throw AppError.message("報告サーバーに接続できません。しばらくしてから再試行してください。")
        }
        var request = URLRequest(url: base.appending(path: "chorus-reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(report)
        // This endpoint deliberately uses neither room nor profile authentication.
        let (data, response) = try await session.data(for: request)
        struct Receipt: Decodable { let delivered: Bool }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.delivered else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw AppError.message(message ?? "報告を送信できませんでした。再試行してください。")
        }
    }
}
