import Foundation
import SwiftUI
import UIKit
import AVFoundation

enum SoloStage { case preparing, countdown, listening, answering, reveal, finished }

enum MusicAccountProvider: String, CaseIterable, Identifiable {
    case appleMusic = "Apple Music"
    case spotify = "Spotify"
    var id: String { rawValue }
}

struct SoloGame {
    var songs: [Song]
    var playlist: String
    var index = 0
    var stage: SoloStage = .preparing
    var startedAt = Date()
    var deadline = Date()
    var pushTime = 0.0
    var letterIndex = 0
    var choices: [String] = []
    var answered = ""
    var wasCorrect = false
    var correctPushTimes: [Double] = []
    var secondsLeft = 30.0
    var warning: String?
    var current: Song { songs[index] }
    var answer: [String] { TitleRules.characters(current.title) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var searchTerm = ""
    @Published var searchSongs: [Song] = []
    @Published var sharedSongs: [Song] = []
    @Published var game: SoloGame?
    @Published var lastResult: SoloResult?
    @Published var reviews: [ReviewSong] = []
    @Published var history: [SoloResult] = []
    @Published var stats = PlayerStats()
    @Published var busy = false
    @Published var preparationStatus: String?
    @Published var alert: String?
    let serverURL = AppConfiguration.serverURL
    var serverConfigured: Bool { !serverURL.isEmpty }
    @Published var nickname = UserDefaults.standard.string(forKey: "nickname") ?? "プレイヤー" {
        didSet { UserDefaults.standard.set(nickname, forKey: "nickname") }
    }
    @Published var room: RoomState?
    @Published var roomID: String? = UserDefaults.standard.string(forKey: "roomID")
    @Published var roomSettings = RoomSettings()
    @Published var roomAnswer = ""
    @Published var roomOptions: [String] = []
    @Published var roomSecondsLeft = 30.0
    @Published var roomError: String?
    @Published var roomPreparationStatus: String?
    @Published var roomAudioStarting = false
    @Published private(set) var roomAudioStarted = false
    let spotifyClientID = AppConfiguration.spotifyClientID
    var spotifyConfigured: Bool { serverConfigured && !spotifyClientID.isEmpty }
    @Published var spotifyConnected = false
    @Published var spotifyPremium = false
    @Published var spotifyAccountName = ""
    @Published var spotifyPlaylists: [SpotifyPlaylist] = []
    @Published var spotifySongs: [Song] = []
    @Published var quizCorpus: [String] = []
    @Published var selectedPlaylistID = ""
    @Published var selectedMusicProvider: MusicAccountProvider =
        MusicAccountProvider(rawValue: UserDefaults.standard.string(forKey: "musicAccountProvider") ?? "") ?? .appleMusic {
        didSet { UserDefaults.standard.set(selectedMusicProvider.rawValue, forKey: "musicAccountProvider") }
    }
    @Published var appleMusicConnected = false
    @Published var appleMusicPlayable = false
    @Published var appleMusicPlaylists: [AppleMusicPlaylist] = []
    @Published var appleMusicSongs: [Song] = []
    @Published var selectedAppleMusicPlaylistID = ""
    @Published var roomMode = "shared"
    @Published var itunesTerm = ""
    @Published var itunesSongs: [Song] = []
    @Published var profileSyncStatus: String?

    let player = PreviewPlayer()
    let rooms = RoomService()
    let spotify = SpotifyService()
    let appleMusic = AppleMusicService()
    private let artistTopSongs = ArtistTopSongsService()
    private var ticker: Task<Void, Never>?
    private var soloRoundTask: Task<Void, Never>?
    private var soloRoundToken = 0
    private var roomPoller: Task<Void, Never>?
    private var roomTicker: Task<Void, Never>?
    private var scheduledRoomAudio: Task<Void, Never>?
    private var lastRoomRound: Int?
    private var lastRoomPhase: String?
    private var preparedRoomRound: Int?
    private var roomPreloadTask: Task<Void, Never>?
    private var preloadedRoomID: String?
    private var pushCue: AVAudioPlayer?
    private var musicTask: Task<Void, Never>?
    private var spotifyPlaying = false
    private var spotifyPauseTask: Task<Void, Never>?
    private var appleMusicPlaying = false
    private var appleMusicPauseTask: Task<Void, Never>?
    private var profileSaveTask: Task<Void, Never>?
    private var recordedRoomAttempts = Set<String>()
    private var recordedRoomGenres = Set<String>()
    private var chorusPositions: [String: Int] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "reviews"), let decoded = try? JSONDecoder().decode([ReviewSong].self, from: data) { reviews = decoded }
        if let data = UserDefaults.standard.data(forKey: "history"), let decoded = try? JSONDecoder().decode([SoloResult].self, from: data) { history = decoded }
        if let data = UserDefaults.standard.data(forKey: "stats"), let decoded = try? JSONDecoder().decode(PlayerStats.self, from: data) { stats = decoded }
        rooms.baseURL = serverURL
        spotify.serverURL = serverURL
        spotify.clientID = spotifyClientID
        spotifyConnected = spotifyConfigured && spotify.isConnected
        appleMusicConnected = appleMusic.isAuthorized
        if UserDefaults.standard.string(forKey: "musicAccountProvider") == nil && spotifyConnected {
            selectedMusicProvider = .spotify
        }
        if let url = Bundle.main.url(forResource: "push", withExtension: "wav", subdirectory: "Audio") {
            pushCue = try? AVAudioPlayer(contentsOf: url)
            pushCue?.prepareToPlay()
        }
    }

    func search() async {
        searchSongs = DemoCatalog.search(searchTerm)
        if searchSongs.isEmpty { alert = "一致するデモ曲がありません" }
    }

    func loadSharedSongs() async {
        rooms.baseURL = serverURL
        busy = true; defer { busy = false }
        do { sharedSongs = try await rooms.catalog() }
        catch { alert = error.localizedDescription }
    }

    func connectSpotify(reconnect: Bool = false) async {
        busy = true; defer { busy = false }
        spotify.serverURL = serverURL
        spotify.clientID = spotifyClientID
        do {
            try await spotify.connect(forceDialog: reconnect)
            spotifyConnected = true
            selectedMusicProvider = .spotify
            let account = try await spotify.account()
            spotifyPremium = account.isPremium
            spotifyAccountName = account.display_name ?? account.id
            rooms.baseURL = serverURL
            await loadSpotifyPlaylists()
            await syncProfile()
        } catch { alert = error.localizedDescription }
    }

    func disconnectSpotify() {
        spotify.disconnect()
        rooms.profileID = rooms.playerId
        UserDefaults.standard.removeObject(forKey: "spotifyAccountID")
        spotifyConnected = false; spotifyPremium = false; spotifyAccountName = ""
        spotifyPlaylists = []; spotifySongs = []
    }

    func loadSpotifyPlaylists() async {
        guard spotifyConnected else { return }
        do {
            spotify.serverURL = serverURL
            let account = try await spotify.account()
            spotifyPremium = account.isPremium
            spotifyAccountName = account.display_name ?? account.id
            spotifyPlaylists = try await spotify.playlists()
            rooms.baseURL = serverURL
            do { try await rooms.linkSpotify(accessToken: spotify.bearerToken()) }
            catch { profileSyncStatus = "Spotify 記録の連携を再試行してください" }
        } catch { alert = error.localizedDescription }
    }

    func selectPlaylist(_ id: String) async {
        guard let playlist = spotifyPlaylists.first(where: { $0.id == id }) else { return }
        selectedPlaylistID = id
        busy = true; defer { busy = false }
        do {
            spotifySongs = try await spotify.songs(in: playlist)
            rooms.baseURL = serverURL
            quizCorpus = spotifySongs.map(\.title) + ((try? await rooms.topSongs()) ?? [])
        }
        catch { alert = error.localizedDescription }
    }

    func connectAppleMusic() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            appleMusicPlayable = try await appleMusic.authorize()
            appleMusicConnected = true
            selectedMusicProvider = .appleMusic
            appleMusicPlaylists = try await appleMusic.playlists()
        } catch {
            appleMusicConnected = appleMusic.isAuthorized
            alert = error.localizedDescription
        }
    }

    func loadAppleMusicPlaylists() async {
        guard appleMusic.isAuthorized else {
            appleMusicConnected = false
            appleMusicPlayable = false
            appleMusicPlaylists = []
            appleMusicSongs = []
            return
        }
        do {
            appleMusicConnected = true
            appleMusicPlayable = try await appleMusic.canPlay()
            appleMusicPlaylists = try await appleMusic.playlists()
            if !appleMusicPlaylists.contains(where: { $0.id == selectedAppleMusicPlaylistID }) {
                selectedAppleMusicPlaylistID = ""
                appleMusicSongs = []
            }
        } catch { alert = error.localizedDescription }
    }

    func selectAppleMusicPlaylist(_ id: String) async {
        guard !id.isEmpty, !busy else { return }
        selectedAppleMusicPlaylistID = id
        appleMusicSongs = []
        busy = true; defer { busy = false }
        do {
            appleMusicSongs = try await appleMusic.songs(in: id)
            quizCorpus = appleMusicSongs.map(\.title)
        } catch { alert = error.localizedDescription }
    }

    func startAppleMusicSolo() async {
        guard appleMusicConnected, appleMusicPlayable else {
            alert = "Apple Music の再生にはアクセス許可と有効なサブスクリプションが必要です"
            return
        }
        guard !appleMusicSongs.isEmpty else { alert = "先にプレイリストを選んでください"; return }
        quizCorpus = appleMusicSongs.map(\.title)
        let name = appleMusicPlaylists.first { $0.id == selectedAppleMusicPlaylistID }?.name ?? "Apple Music"
        guard !busy else { return }
        busy = true; defer { busy = false; preparationStatus = nil }
        do { try await launchSolo(songs: appleMusicSongs, playlist: "Apple Music · \(name)") }
        catch { alert = error.localizedDescription }
    }

    func searchItunes() async {
        rooms.baseURL = serverURL
        busy = true; defer { busy = false }
        do { itunesSongs = try await rooms.searchItunes(itunesTerm) }
        catch { alert = error.localizedDescription }
    }

    func startSolo(shared: Bool = false) async {
        let source = shared ? sharedSongs : searchSongs
        guard !source.isEmpty else { alert = shared ? "先に共有音源を読み込んでください" : "デモ曲がありません"; return }
        guard !busy else { return }
        busy = true; defer { busy = false; preparationStatus = nil }
        do { try await launchSolo(songs: source, playlist: shared ? "共有音源" : "オリジナルデモ") }
        catch { alert = error.localizedDescription }
    }

    func startItunesSolo() async {
        let songs = itunesSongs.filter { $0.playablePreview && !TitleRules.characters($0.title).isEmpty }
        guard !songs.isEmpty else { alert = "先に試聴曲を検索してください"; return }
        guard !busy else { return }
        busy = true; defer { busy = false; preparationStatus = nil }
        do { try await launchSolo(songs: songs, playlist: "サビトロ · 試聴曲") }
        catch { alert = error.localizedDescription }
    }

    func startSabitroSolo() async {
        guard !spotifySongs.isEmpty else { alert = "先にプレイリストを選んでください"; return }
        guard !busy else { return }
        busy = true; defer { busy = false; preparationStatus = nil }
        rooms.baseURL = serverURL
        do {
            var matches: [Song] = []
            for song in spotifySongs.shuffled() {
                if let match = try await rooms.matchItunes(song), match.playablePreview,
                   !TitleRules.characters(match.title).isEmpty { matches.append(match) }
                if matches.count == 10 { break }
            }
            guard !matches.isEmpty else { alert = "iTunes に一致する試聴曲がありません"; return }
            try await launchSolo(songs: matches, playlist: "サビトロ · " + (spotifyPlaylists.first { $0.id == selectedPlaylistID }?.name ?? "Spotify"))
        } catch { alert = error.localizedDescription }
    }

    func startSpotifySolo() async {
        guard spotifyPremium else { alert = "ひとりで Spotify の音源を再生するには Premium が必要です"; return }
        guard !spotifySongs.isEmpty else { alert = "先にプレイリストを選んでください"; return }
        quizCorpus = spotifySongs.map(\.title)
        guard !busy else { return }
        busy = true; defer { busy = false; preparationStatus = nil }
        rooms.baseURL = serverURL
        var selected = Array(spotifySongs.shuffled().prefix(10))
        for index in selected.indices {
            if let match = try? await rooms.matchItunes(selected[index]) { selected[index].genre = match.genre }
        }
        do { try await launchSolo(songs: selected, playlist: spotifyPlaylists.first { $0.id == selectedPlaylistID }?.name ?? "Spotify") }
        catch { alert = error.localizedDescription }
    }

    private func launchSolo(songs source: [Song], playlist: String) async throws {
        let limit = min(10, source.count)
        preparationStatus = "選択肢を準備中"
        let songs = await withArtistTopTitles(Array(source.shuffled().prefix(limit)))
        preparationStatus = "画像と音源を準備中 0 / \(songs.count)"
        try await GameAssets.shared.prepare(songs.map(GameAsset.init(song:))) { [weak self] ready, total in
            self?.preparationStatus = "画像と音源を準備中 \(ready) / \(total)"
        }
        if songs.first?.id.hasPrefix("spotify:") == true {
            try await spotify.preparePlayback()
        } else if songs.first?.id.hasPrefix("applemusic:") == true {
            try await appleMusic.prepareCatalog(songs.map(\.id))
            if let first = songs.first { try await appleMusic.prepare(first.id) }
        }
        try Task.checkCancellation()
        lastResult = nil
        game = SoloGame(songs: songs, playlist: playlist)
        beginRound()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func beginRound() {
        guard var game else { return }
        soloRoundTask?.cancel()
        soloRoundToken += 1
        let token = soloRoundToken
        let song = game.current
        game.stage = .preparing
        game.secondsLeft = 30
        game.letterIndex = 0
        game.answered = ""
        game.wasCorrect = false
        game.warning = nil
        self.game = game
        stopAudio()
        soloRoundTask = Task { [weak self] in
            guard let self else { return }
            do {
                if song.id.hasPrefix("spotify:") {
                    try await self.spotify.preparePlayback()
                } else if song.id.hasPrefix("applemusic:") {
                    try await self.appleMusic.prepare(song.id)
                } else if let url = song.previewURL {
                    try await self.player.prepare(url)
                } else { throw AppError.message("この曲の音源がありません") }
                try Task.checkCancellation()
                guard self.soloRoundToken == token, var current = self.game else { return }
                current.stage = .countdown
                current.deadline = .now.addingTimeInterval(2)
                current.secondsLeft = 2
                self.game = current
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                guard self.soloRoundToken == token, var starting = self.game else { return }
                starting.stage = .preparing
                self.game = starting
                try await self.startPreparedRoundAudio(song)
                try Task.checkCancellation()
                guard self.soloRoundToken == token, var playing = self.game else { return }
                playing.stage = .listening
                playing.startedAt = .now
                playing.deadline = .now.addingTimeInterval(30)
                playing.secondsLeft = 30
                self.game = playing
            } catch {
                guard self.soloRoundToken == token, !Task.isCancelled, var current = self.game else { return }
                self.stopAudio()
                current.stage = .preparing
                current.warning = error.localizedDescription
                self.game = current
            }
        }
        if song.id.hasPrefix("spotify:") {
            Task { [weak self] in
                guard let self else { return }
                self.rooms.baseURL = self.serverURL
                self.chorusPositions[song.id] = await self.rooms.chorus(song)
            }
        }
    }

    private func startPreparedRoundAudio(_ song: Song, offsetMS: Int = 0) async throws {
        if song.id.hasPrefix("spotify:") {
            await spotifyPauseTask?.value
            try Task.checkCancellation()
            spotifyPlaying = true
            try await spotify.play(song, offsetMS: offsetMS)
        } else if song.id.hasPrefix("applemusic:") {
            await appleMusicPauseTask?.value
            try Task.checkCancellation()
            appleMusicPlaying = true
            try await appleMusic.play(song, offsetMS: offsetMS)
        } else if let url = song.previewURL {
            try player.startPrepared(url, offset: Double(offsetMS) / 1000)
        }
    }

    private func tick() {
        guard var game else { return }
        switch game.stage {
        case .countdown:
            game.secondsLeft = max(0, game.deadline.timeIntervalSinceNow)
            self.game = game
        case .listening, .answering:
            game.secondsLeft = max(0, game.deadline.timeIntervalSinceNow)
            if game.secondsLeft <= 0 {
                self.game = game
                reveal(correct: false)
            } else { self.game = game }
        default: break
        }
    }

    func retrySoloRound() {
        guard game?.stage == .preparing, game?.warning != nil else { return }
        beginRound()
    }

    func push() {
        guard var game, game.stage == .listening else { return }
        game.pushTime = min(30, Date.now.timeIntervalSince(game.startedAt))
        game.stage = .answering
        game.letterIndex = 0
        game.deadline = .now.addingTimeInterval(5)
        game.secondsLeft = 5
        game.choices = TitleRules.choices(answer: game.answer[0], prefix: "", corpus: game.current.id.hasPrefix("spotify:") || game.current.id.hasPrefix("applemusic:") ? quizCorpus : game.songs.map(\.title), artistTopTitles: game.current.artistTopTitles ?? [])
        stats.attempts += 1
        stats.totalPushSeconds += game.pushTime
        var genre = stats.genres[game.current.genre] ?? GenreRecord()
        genre.attempts += 1
        stats.genres[game.current.genre] = genre
        persist()
        self.game = game
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        playPushCue()
        pauseAudio()
    }

    func choose(_ choice: String) {
        guard var game, game.stage == .answering else { return }
        guard choice == game.answer[game.letterIndex] else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            reveal(correct: false)
            return
        }
        game.answered += choice
        game.letterIndex += 1
        UISelectionFeedbackGenerator().selectionChanged()
        if game.letterIndex == game.answer.count {
            self.game = game
            reveal(correct: true)
        } else {
            game.choices = TitleRules.choices(answer: game.answer[game.letterIndex], prefix: game.answered,
                                              corpus: game.current.id.hasPrefix("spotify:") || game.current.id.hasPrefix("applemusic:") ? quizCorpus : game.songs.map(\.title))
            game.deadline = .now.addingTimeInterval(5)
            game.secondsLeft = 5
            self.game = game
        }
    }

    func skip() { reveal(correct: false) }

    private func reveal(correct: Bool) {
        guard var game, game.stage == .listening || game.stage == .answering else { return }
        game.stage = .reveal
        game.wasCorrect = correct
        if correct {
            game.correctPushTimes.append(game.pushTime)
            stats.correct += 1
            var genre = stats.genres[game.current.genre] ?? GenreRecord()
            genre.correct += 1
            stats.genres[game.current.genre] = genre
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        stats.awardBadges()
        persist()
        self.game = game
        stopAudio()
        revealAudio(game.current)
    }

    func nextRound() {
        guard var game, game.stage == .reveal else { return }
        if game.index + 1 < game.songs.count {
            game.index += 1
            self.game = game
            withAnimation(Studio.spring) { beginRound() }
        } else {
            let result = SoloResult.make(playlist: game.playlist, total: game.songs.count, pushTimes: game.correctPushTimes)
            game.stage = .finished
            self.game = game
            lastResult = result
            history.insert(result, at: 0)
            history = Array(history.prefix(5))
            stats.games += 1
            stats.awardBadges()
            persist()
            stopAudio()
        }
    }

    func closeGame() {
        soloRoundTask?.cancel(); soloRoundTask = nil; soloRoundToken += 1
        ticker?.cancel(); ticker = nil
        stopAudio()
        game = nil
    }

    func saveReview(_ song: Song) {
        guard !reviews.contains(where: { $0.id == song.id }) else { return }
        reviews.insert(ReviewSong(song: song), at: 0)
        trimReviews()
        persist()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func toggleLearned(_ id: String) {
        guard let index = reviews.firstIndex(where: { $0.id == id }) else { return }
        reviews[index].learned.toggle()
        trimReviews()
        persist()
    }

    func removeReview(_ id: String) { reviews.removeAll { $0.id == id }; persist() }

    private func trimReviews() {
        let unknown = reviews.filter { !$0.learned }.sorted { $0.savedAt > $1.savedAt }.prefix(50)
        let known = reviews.filter(\.learned).sorted { $0.savedAt > $1.savedAt }.prefix(50)
        reviews = Array(unknown) + Array(known)
    }

    func setBadge(_ badge: String) {
        guard stats.badges.contains(badge) else { return }
        stats.selectedBadge = badge
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(true, forKey: "profileDirty")
        UserDefaults.standard.set(try? JSONEncoder().encode(reviews), forKey: "reviews")
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history")
        UserDefaults.standard.set(try? JSONEncoder().encode(stats), forKey: "stats")
        guard !serverURL.isEmpty else { return }
        profileSaveTask?.cancel()
        profileSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            self.rooms.baseURL = self.serverURL
            do {
                try await self.rooms.saveProfile(reviews: self.reviews, history: self.history, stats: self.stats)
                UserDefaults.standard.set(false, forKey: "profileDirty")
                self.profileSyncStatus = "サーバーに保存済み"
            } catch { self.profileSyncStatus = "同期を再試行してください" }
        }
    }

    func syncProfile() async {
        guard !serverURL.isEmpty else { return }
        rooms.baseURL = serverURL
        do {
            let saved = try await rooms.profile()
            if UserDefaults.standard.bool(forKey: "profileDirty") || saved.stats == nil {
                try await rooms.saveProfile(reviews: reviews, history: history, stats: stats)
                UserDefaults.standard.set(false, forKey: "profileDirty")
            } else if let stored = saved.stats {
                reviews = saved.reviews
                history = saved.history
                stats = stored
                UserDefaults.standard.set(try? JSONEncoder().encode(reviews), forKey: "reviews")
                UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history")
                UserDefaults.standard.set(try? JSONEncoder().encode(stats), forKey: "stats")
            }
            profileSyncStatus = "サーバーに保存済み"
        } catch { profileSyncStatus = "同期できません: \(error.localizedDescription)" }
    }

    private func playAudio(_ song: Song, offsetMS: Int = 0) {
        musicTask?.cancel()
        if song.id.hasPrefix("spotify:") {
            spotifyPlaying = true
            let pause = spotifyPauseTask
            musicTask = Task { [weak self] in
                guard let self else { return }
                await pause?.value
                guard !Task.isCancelled else { return }
                do { try await self.spotify.play(song, offsetMS: offsetMS) }
                catch {
                    guard !Task.isCancelled else { return }
                    if var game = self.game, game.current.id == song.id {
                        game.warning = error.localizedDescription
                        self.game = game
                    } else {
                        self.alert = error.localizedDescription
                    }
                }
            }
        } else if song.id.hasPrefix("applemusic:") {
            appleMusicPlaying = true
            let pause = appleMusicPauseTask
            musicTask = Task { [weak self] in
                guard let self else { return }
                await pause?.value
                guard !Task.isCancelled else { return }
                do { try await self.appleMusic.play(song, offsetMS: offsetMS) }
                catch {
                    guard !Task.isCancelled else { return }
                    if var game = self.game, game.current.id == song.id {
                        game.warning = error.localizedDescription
                        self.game = game
                    } else { self.alert = error.localizedDescription }
                }
            }
        } else if let url = song.previewURL {
            player.play(url, offset: Double(offsetMS) / 1000)
        }
    }

    private func pauseAudio() {
        let active = musicTask ?? (roomID == nil ? soloRoundTask : scheduledRoomAudio)
        if appleMusicPlaying {
            let previous = appleMusicPauseTask
            appleMusicPauseTask = Task { [weak self] in
                await previous?.value
                await active?.value
                self?.appleMusic.pause()
            }
        } else if spotifyPlaying {
            let previous = spotifyPauseTask
            spotifyPauseTask = Task { [weak self] in
                await previous?.value
                await active?.value
                guard let self else { return }
                try? await self.spotify.pause()
            }
        }
        else { player.pause() }
    }

    private func stopAudio() {
        let play = musicTask ?? (roomID == nil ? soloRoundTask : scheduledRoomAudio)
        musicTask?.cancel(); musicTask = nil
        appleMusic.stop(); appleMusicPlaying = false
        if spotifyPlaying {
            let previous = spotifyPauseTask
            spotifyPauseTask = Task { [weak self] in
                await previous?.value
                await play?.value
                guard let self else { return }
                try? await self.spotify.pause()
            }
            spotifyPlaying = false
        }
        player.stop()
    }

    private func revealAudio(_ song: Song) {
        guard song.id.hasPrefix("spotify:") || song.id.hasPrefix("applemusic:") else { playAudio(song); return }
        let estimated = max(0, min(90_000, max(30_000, Int(Double(song.durationMS) * 0.32))) - 1500)
        playAudio(song, offsetMS: song.chorusMS ?? chorusPositions[song.id] ?? estimated)
    }

    var totalGames: Int { stats.games }
    var totalCorrect: Int { stats.correct }
    var accuracy: Double { stats.accuracy }

    private func withArtistTopTitles(_ songs: [Song]) async -> [Song] {
        var result: [Song]
        if songs.first?.id.hasPrefix("spotify:") == true {
            result = await spotify.withArtistTopTitles(songs)
        } else if songs.first?.id.hasPrefix("applemusic:") == true {
            result = await appleMusic.withArtistTopTitles(songs)
        } else {
            result = songs
        }
        for index in result.indices where result[index].artistTopTitles?.isEmpty != false {
            let titles = await artistTopSongs.titles(for: result[index].artist)
            if !titles.isEmpty { result[index].artistTopTitles = titles }
        }
        return result
    }

    func createRoom() async {
        guard !busy else { return }
        busy = true; defer { busy = false; preparationStatus = nil }
        rooms.baseURL = serverURL
        do {
            var songs: [Song] = []
            var corpus: [String] = []
            if roomMode == "shared" {
                songs = sharedSongs.isEmpty ? try await rooms.catalog() : sharedSongs
            } else if roomMode == "applemusic" {
                guard appleMusicConnected, appleMusicPlayable else {
                    throw AppError.message("Apple Music 対戦にはアクセス許可とサブスクリプションが必要です")
                }
                guard !appleMusicSongs.isEmpty else { throw AppError.message("先に Apple Music のプレイリストを選んでください") }
                for candidate in appleMusicSongs.shuffled() {
                    songs += await appleMusic.catalogSongs(for: [candidate])
                    if songs.count == roomSettings.questionCount { break }
                }
                guard songs.count == roomSettings.questionCount else {
                    throw AppError.message("指定された問題数分の Apple Music の曲を用意できません")
                }
                corpus = appleMusicSongs.map(\.title)
            } else if roomMode != "shared" {
                guard !spotifySongs.isEmpty else { throw AppError.message("先に Spotify プレイリストを選んでください") }
                if roomMode == "spotify" && !spotifyPremium { throw AppError.message("Spotify 対戦には Premium が必要です") }
                if roomMode == "sabitro" {
                    for song in spotifySongs.shuffled() {
                        if let match = try await rooms.matchItunes(song) { songs.append(match) }
                        if songs.count == roomSettings.questionCount { break }
                    }
                    guard songs.count == roomSettings.questionCount else {
                        throw AppError.message("指定された問題数分の試聴曲を用意できません")
                    }
                } else {
                    guard spotifySongs.count >= roomSettings.questionCount else {
                        throw AppError.message("プレイリストの曲数が問題数より少なくなっています")
                    }
                    songs = Array(spotifySongs.shuffled().prefix(roomSettings.questionCount))
                }
                corpus = spotifySongs.map(\.title)
            }
            preparationStatus = "選択肢を準備中"
            songs = await withArtistTopTitles(songs)
            let state = try await rooms.create(name: nickname, settings: roomSettings, mode: roomMode,
                                               songs: songs, corpus: corpus, badge: stats.selectedBadge)
            guard state.mode == roomMode else {
                _ = try? await rooms.action("leave", id: state.id)
                throw AppError.message("対戦サーバーを更新してから、この音源でルームを作成してください")
            }
            enterRoom(state)
        } catch { alert = error.localizedDescription }
    }

    func joinRoom(_ code: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        do {
            let state = try await rooms.join(code.trimmingCharacters(in: .whitespacesAndNewlines), name: nickname,
                                             badge: stats.selectedBadge)
            if state.mode == "spotify" {
                guard spotifyConnected, (try await spotify.account()).isPremium else {
                    _ = try? await rooms.action("leave", id: state.id)
                    throw AppError.message("このルームには Spotify Premium の連携が必要です")
                }
            } else if state.mode == "applemusic" {
                guard appleMusicConnected, try await appleMusic.canPlay() else {
                    _ = try? await rooms.action("leave", id: state.id)
                    throw AppError.message("このルームには Apple Music の接続とサブスクリプションが必要です")
                }
            }
            enterRoom(state)
        } catch { alert = error.localizedDescription }
    }

    func restoreRoom() async {
        guard serverConfigured, let roomID, room == nil else { return }
        rooms.baseURL = serverURL
        for _ in 0..<100 {
            guard self.roomID == roomID, room == nil else { return }
            do {
                var state = try await rooms.state(roomID)
                if state.phase == "lobby", (state.assetsReadyIds ?? []).contains(rooms.playerId) {
                    state = try await rooms.action("assets-unready", id: roomID)
                }
                enterRoom(state)
                return
            }
            catch {
                if error.localizedDescription.contains("ルームが見つかりません") ||
                    error.localizedDescription.contains("セッションを確認できません") {
                    self.roomID = nil
                    UserDefaults.standard.removeObject(forKey: "roomID")
                    rooms.clear()
                    return
                }
                roomError = "ルームへの再接続を試しています…"
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func enterRoom(_ state: RoomState) {
        roomID = state.id
        UserDefaults.standard.set(state.id, forKey: "roomID")
        room = state
        roomError = nil
        preloadedRoomID = nil
        roomPreloadTask?.cancel()
        roomPoller?.cancel()
        roomTicker?.cancel()
        roomTicker = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let room = self.room {
                    self.roomSecondsLeft = self.remainingTime(room)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        roomPoller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let id = self.roomID else { break }
                do {
                    let state = try await self.rooms.state(id)
                    self.receiveRoom(state)
                    if self.roomError == "接続を確認しています…" { self.roomError = nil }
                } catch { self.roomError = "接続を確認しています…" }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func receiveRoom(_ state: RoomState) {
        let old = room
        room = state
        if state.phase == "lobby", preloadedRoomID != state.id,
           !(state.assetsReadyIds ?? []).contains(rooms.playerId) {
            preloadedRoomID = state.id
            roomPreloadTask?.cancel()
            roomPreloadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let assets = state.preload, assets.count == state.totalRounds else {
                        throw AppError.message("対戦サーバーを更新してから開始してください")
                    }
                    self.roomPreparationStatus = "画像と音源を準備中 0 / \(assets.count)"
                    try await GameAssets.shared.prepare(assets) { [weak self] ready, total in
                        self?.roomPreparationStatus = "画像と音源を準備中 \(ready) / \(total)"
                    }
                    if state.mode == "spotify" {
                        try await self.spotify.preparePlayback()
                    } else if state.mode == "applemusic" {
                        try await self.appleMusic.prepareCatalog(assets.map(\.id))
                        if let first = assets.first { try await self.appleMusic.prepare(first.id) }
                    }
                    guard !Task.isCancelled, self.room?.id == state.id, self.room?.phase == "lobby" else { return }
                    self.receiveRoom(try await self.rooms.action("assets-ready", id: state.id))
                    self.roomPreparationStatus = "準備完了"
                    self.roomError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.roomPreparationStatus = nil
                    self.roomError = error.localizedDescription
                }
            }
        }
        let key = "\(state.id):\(state.round)"
        if state.round >= 0 && state.answeringPlayerID == rooms.playerId && !recordedRoomAttempts.contains(key) {
            recordedRoomAttempts.insert(key)
            stats.attempts += 1
            stats.totalPushSeconds += max(0, min(30, (state.serverNow - (state.startAt ?? state.serverNow)) / 1000))
            persist()
        }
        if state.phase == "reveal" && state.pushedIds.contains(rooms.playerId) && !recordedRoomGenres.contains(key) {
            recordedRoomGenres.insert(key)
            let genre = state.current?.genre ?? "その他"
            var record = stats.genres[genre] ?? GenreRecord()
            record.attempts += 1
            if state.correctPlayerID == rooms.playerId { record.correct += 1; stats.correct += 1 }
            stats.genres[genre] = record
            stats.awardBadges()
            persist()
        }
        if state.phase == "finished" {
            var finished = Set(UserDefaults.standard.stringArray(forKey: "finishedRoomIDs") ?? [])
            if !finished.contains(state.id) {
                finished.insert(state.id)
                UserDefaults.standard.set(Array(finished.suffix(100)), forKey: "finishedRoomIDs")
                stats.games += 1
                stats.awardBadges()
                persist()
            }
        }
        roomOptions = state.options
        roomAnswer = state.answerProgress
        roomSecondsLeft = remainingTime(state)
        if state.round != lastRoomRound {
            stopAudio()
            roomAudioStarted = false
            roomAudioStarting = false
            scheduledRoomAudio?.cancel()
            scheduledRoomAudio = nil
            lastRoomRound = state.round
        }
        if state.phase == "preparing" && preparedRoomRound != state.round {
            preparedRoomRound = state.round
            Task { [weak self] in
                guard let self else { return }
                do {
                    if state.mode == "spotify" {
                        try await self.spotify.preparePlayback()
                    } else if state.mode == "applemusic", let id = state.current?.id {
                        try await self.appleMusic.prepare(id)
                    } else if let url = state.current?.previewURL {
                        try await self.player.prepare(url)
                    }
                    guard self.room?.round == state.round, self.room?.phase == "preparing" else { return }
                    self.receiveRoom(try await self.rooms.action("ready", id: state.id))
                } catch {
                    if self.room?.round == state.round { self.roomError = error.localizedDescription }
                }
            }
        }
        if state.phase == "countdown" && !roomAudioStarted && scheduledRoomAudio == nil {
            let startAt = state.startAt ?? state.serverNow
            let delay = max(0, startAt - rooms.serverNowMS)
            if state.mode != "spotify", state.mode != "applemusic",
               let preview = state.current?.previewURL,
               GameAssets.shared.audioURL(for: preview).isFileURL, delay > 100 {
                do {
                    try player.schedule(preview, at: rooms.localDate(for: startAt))
                    roomAudioStarted = true
                    roomError = nil
                } catch { roomError = error.localizedDescription }
            } else {
                scheduledRoomAudio = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(Int(delay))) }
                    catch { return }
                    guard let self, !Task.isCancelled, !self.roomAudioStarted,
                          self.room?.round == state.round,
                          ["countdown", "listening", "answering"].contains(self.room?.phase ?? "") else { return }
                    await self.startRoomAudio(state)
                    if self.room?.answeringPlayerID == self.rooms.playerId && !state.settings.endless {
                        self.pauseAudio()
                    }
                }
            }
        }
        if state.phase == "listening" && !roomAudioStarted && scheduledRoomAudio == nil {
            scheduledRoomAudio = Task { [weak self] in
                await self?.startRoomAudio(state)
            }
        }
        if state.phase == "answering" && state.answeringPlayerID == rooms.playerId && old?.answeringPlayerID != rooms.playerId && !state.settings.endless {
            pauseAudio()
        }
        if state.phase == "listening" && old?.phase == "answering" && old?.answeringPlayerID == rooms.playerId && !state.settings.endless {
            Task { [weak self] in await self?.startRoomAudio(state) }
        }
        if state.phase == "reveal" && lastRoomPhase != "reveal" {
            scheduledRoomAudio?.cancel()
            stopAudio()
            scheduledRoomAudio = nil
            if let song = state.current?.song { revealAudio(song) }
            UINotificationFeedbackGenerator().notificationOccurred(state.correctPlayerID == rooms.playerId ? .success : .warning)
        }
        if state.phase == "finished" && lastRoomPhase != "finished" {
            stopAudio()
        }
        lastRoomPhase = state.phase
    }

    private func startRoomAudio(_ state: RoomState) async {
        guard let current = state.current else { return }
        guard !roomAudioStarting else { return }
        roomAudioStarting = true
        defer { roomAudioStarting = false }
        do {
            let elapsed = max(0, rooms.serverNowMS - (state.startAt ?? rooms.serverNowMS))
            if state.mode == "spotify" || state.mode == "applemusic" {
                try await startPreparedRoundAudio(Song(id: current.id, title: "", artist: "", artworkURL: nil,
                    previewURL: nil, trackURL: nil, durationMS: 180_000, genre: "その他"), offsetMS: Int(elapsed))
            } else if let preview = current.previewURL {
                do { try player.startPrepared(preview, offset: elapsed / 1000) }
                catch {
                    try await player.prepare(preview)
                    try player.startPrepared(preview, offset: elapsed / 1000)
                }
            } else { throw AppError.message("この曲の音源がありません") }
            guard room?.round == state.round else { return }
            roomAudioStarted = true
            roomError = nil
        } catch {
            guard room?.round == state.round, !Task.isCancelled else { return }
            roomError = error.localizedDescription
        }
    }

    func remainingTime(_ state: RoomState) -> Double {
        let target = state.phase == "answering" && state.answeringPlayerID == rooms.playerId ? state.answerDeadline : state.roundDeadline
        return max(0, ((target ?? rooms.serverNowMS) - rooms.serverNowMS) / 1000)
    }

    func roomAction(_ action: String, payload: [String: Any] = [:]) async {
        guard let roomID else { return }
        if action == "push" { playPushCue(); UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        do { receiveRoom(try await rooms.action(action, id: roomID, payload: payload)) }
        catch { alert = error.localizedDescription }
    }

    func retryRoomPreload() {
        guard let room, room.phase == "lobby" else { return }
        preloadedRoomID = nil
        roomError = nil
        receiveRoom(room)
    }

    func retryRoomRound() {
        guard let room, room.phase == "preparing" else { return }
        preparedRoomRound = nil
        roomError = nil
        receiveRoom(room)
    }

    func retryRoomAudio() {
        guard let room, ["countdown", "listening"].contains(room.phase) else { return }
        scheduledRoomAudio?.cancel()
        scheduledRoomAudio = nil
        roomError = nil
        receiveRoom(room)
    }

    private func playPushCue() {
        pushCue?.currentTime = 0
        pushCue?.play()
    }

    func leaveRoom() async {
        roomPreloadTask?.cancel(); roomPreloadTask = nil
        preloadedRoomID = nil; roomPreparationStatus = nil
        roomPoller?.cancel(); roomPoller = nil
        roomTicker?.cancel(); roomTicker = nil
        scheduledRoomAudio?.cancel()
        if let roomID { _ = try? await rooms.action("leave", id: roomID) }
        stopAudio()
        scheduledRoomAudio = nil
        room = nil; roomID = nil; rooms.clear()
        UserDefaults.standard.removeObject(forKey: "roomID")
        lastRoomPhase = nil; lastRoomRound = nil; preparedRoomRound = nil; roomAudioStarted = false; roomAudioStarting = false
    }
}
