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
    private var filePlayer: AVAudioPlayer?
    private var preparedURL: URL?
    @Published private(set) var playing = false
    var volume: Float = 1 {
        didSet { player?.volume = volume; filePlayer?.volume = volume }
    }

    func play(_ url: URL, offset: Double = 0) {
        let source = GameAssets.shared.audioURL(for: url)
        if preparedURL != url {
            stop()
            if source.isFileURL {
                filePlayer = try? AVAudioPlayer(contentsOf: source)
                filePlayer?.volume = volume
                filePlayer?.prepareToPlay()
            } else {
                player = AVPlayer(url: source)
                player?.volume = volume
            }
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        preparedURL = url
        if let filePlayer {
            filePlayer.currentTime = max(0, offset)
            playing = filePlayer.play()
            return
        }
        if offset > 0 { player?.seek(to: CMTime(seconds: offset, preferredTimescale: 600)) }
        player?.play()
        playing = true
    }

    func prepare(_ url: URL) async throws {
        let asset = AVURLAsset(url: GameAssets.shared.audioURL(for: url))
        guard try await asset.load(.isPlayable) else { throw AppError.message("音源を準備できません") }
        try Task.checkCancellation()
        stop()
        if asset.url.isFileURL {
            let local = try AVAudioPlayer(contentsOf: asset.url)
            local.volume = volume
            guard local.prepareToPlay() else { throw AppError.message("音源を準備できません") }
            filePlayer = local
        } else {
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player?.volume = volume
        }
        preparedURL = url
    }

    func startPrepared(_ url: URL, offset: Double = 0) throws {
        guard preparedURL == url else { throw AppError.message("音源の読み込みが完了していません") }
        play(url, offset: offset)
        guard playing else { throw AppError.message("音源を再生できません") }
    }

    func schedule(_ url: URL, at date: Date) throws {
        guard preparedURL == url, let filePlayer else { throw AppError.message("音源の読み込みが完了していません") }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        filePlayer.currentTime = 0
        guard filePlayer.play(atTime: filePlayer.deviceCurrentTime + max(0.05, date.timeIntervalSinceNow)) else {
            throw AppError.message("音源の再生を予約できません")
        }
        playing = true
    }

    func pause() { player?.pause(); filePlayer?.pause(); playing = false }
    func resume() { player?.play(); filePlayer?.play(); playing = true }
    func stop() { player?.pause(); filePlayer?.stop(); player = nil; filePlayer = nil; preparedURL = nil; playing = false }
}

@MainActor final class GameSoundPlayer {
    enum Cue: String { case push, correct, incorrect, question }

    private let bgm: AVAudioPlayer?
    private var effects: [AVAudioPlayer] = []
    var bgmVolume: Float = 0.35 {
        didSet { bgm?.volume = bgmVolume }
    }
    var effectsVolume: Float = 0.8 {
        didSet { effects.forEach { $0.volume = effectsVolume } }
    }

    init() {
        if let url = Bundle.main.url(forResource: "bgm", withExtension: "mp3", subdirectory: "Audio") {
            bgm = try? AVAudioPlayer(contentsOf: url)
            bgm?.numberOfLoops = -1
            bgm?.volume = bgmVolume
            bgm?.prepareToPlay()
        } else { bgm = nil }
    }

    private func activate() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func playBGM() {
        guard let bgm, bgmVolume > 0, !bgm.isPlaying else { return }
        activate()
        bgm.volume = bgmVolume
        bgm.play()
    }

    func pauseBGM() {
        if bgm?.isPlaying == true { bgm?.pause() }
    }

    func play(_ cue: Cue) {
        guard effectsVolume > 0,
              let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "mp3", subdirectory: "Audio"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        activate()
        effects.removeAll { !$0.isPlaying }
        player.volume = effectsVolume
        player.prepareToPlay()
        effects.append(player)
        player.play()
    }
}

@MainActor final class ArtistTopSongsService {
    private var titlesByArtist: [String: [String]] = [:]

    func titles(for artist: String) async -> [String] {
        let name = artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = TitleRules.normalized(name)
        guard !key.isEmpty else { return [] }
        if let cached = titlesByArtist[key] { return cached }
        struct Result: Decodable {
            struct Item: Decodable {
                let artistId: Int?
                let artistName: String?
                let trackName: String?
            }
            let results: [Item]
        }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: name), .init(name: "country", value: "JP"),
            .init(name: "media", value: "music"), .init(name: "entity", value: "song"),
            .init(name: "limit", value: "50")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try? JSONDecoder().decode(Result.self, from: data).results else { return [] }
        let matching = items.filter { TitleRules.normalized($0.artistName ?? "") == key }
        guard let artistID = matching.first?.artistId else { return [] }
        var titles: [String] = []
        var seen = Set<String>()
        for item in matching where item.artistId == artistID {
            guard let title = item.trackName else { continue }
            let normalized = TitleRules.normalized(title)
            if !normalized.isEmpty && seen.insert(normalized).inserted { titles.append(title) }
            if titles.count == 6 { break }
        }
        titlesByArtist[key] = titles
        return titles
    }
}
