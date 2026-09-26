import Foundation
import AVFoundation

enum AppConfiguration {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "AppConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            return [:]
        }
        return values
    }()

    static var serverURL: String { values["APP_SERVER_URL"] ?? "" }
    static var spotifyClientID: String { values["SPOTIFY_CLIENT_ID"] ?? "" }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

@MainActor final class PreviewPlayer: ObservableObject {
    private var player: AVPlayer?
    private var preparedURL: URL?
    @Published private(set) var playing = false

    func play(_ url: URL, offset: Double = 0) {
        if preparedURL != url { stop(); player = AVPlayer(url: url) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        preparedURL = url
        if offset > 0 { player?.seek(to: CMTime(seconds: offset, preferredTimescale: 600)) }
        player?.play()
        playing = true
    }

    func prepare(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw AppError.message("音源を準備できません") }
        stop()
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        preparedURL = url
    }

    func pause() { player?.pause(); playing = false }
    func resume() { player?.play(); playing = true }
    func stop() { player?.pause(); player = nil; preparedURL = nil; playing = false }
}
