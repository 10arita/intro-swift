import Foundation
import SwiftUI
import UIKit
import AVFoundation

enum SoloStage { case listening, answering, reveal, finished }

struct SoloGame {
    var songs: [Song]
    var playlist: String
    var index = 0
    var stage: SoloStage = .listening
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
    let spotifyClientID = AppConfiguration.spotifyClientID
    var spotifyConfigured: Bool { serverConfigured && !spotifyClientID.isEmpty }
    @Published var spotifyConnected = false
    @Published var spotifyPremium = false
    @Published var spotifyAccountName = ""
    @Published var spotifyPlaylists: [SpotifyPlaylist] = []
    @Published var spotifySongs: [Song] = []
    @Published var quizCorpus: [String] = []
    @Published var spotifyDevices: [SpotifyDevice] = []
    @Published var selectedPlaylistID = ""
    @Published var roomMode = "shared"
    @Published var itunesTerm = ""
    @Published var itunesSongs: [Song] = []
    @Published var profileSyncStatus: String?

    let player = PreviewPlayer()
    let rooms = RoomService()
    let spotify = SpotifyService()
    private var ticker: Task<Void, Never>?
    private var roomPoller: Task<Void, Never>?
    private var roomTicker: Task<Void, Never>?
    private var roomReceivedAt = Date()
    private var scheduledRoomAudio: Task<Void, Never>?
    private var lastRoomRound: Int?
    private var lastRoomPhase: String?
    private var roomAudioStarted = false
    private var preparedRoomRound: Int?
    private var pushCue: AVAudioPlayer?
    private var musicTask: Task<Void, Never>?
    private var spotifyPlaying = false
    private var spotifyPauseTask: Task<Void, Never>?
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
            let account = try await spotify.account()
            spotifyPremium = account.isPremium
            spotifyAccountName = account.display_name ?? account.id
            rooms.baseURL = serverURL
            await loadSpotifyPlaylists()
            await loadSpotifyDevices()
            await syncProfile()
        } catch { alert = error.localizedDescription }
    }

    func disconnectSpotify() {
        spotify.disconnect()
        rooms.profileID = rooms.playerId
        UserDefaults.standard.removeObject(forKey: "spotifyAccountID")
        spotifyConnected = false; spotifyPremium = false; spotifyAccountName = ""
        spotifyPlaylists = []; spotifySongs = []; spotifyDevices = []
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

    func loadSpotifyDevices() async {
        guard spotifyConnected else { return }
        do { spotifyDevices = try await spotify.devices() }
        catch { alert = error.localizedDescription }
    }

    func searchItunes() async {
        rooms.baseURL = serverURL
        busy = true; defer { busy = false }
        do { itunesSongs = try await rooms.searchItunes(itunesTerm) }
        catch { alert = error.localizedDescription }
    }

    func startSolo(shared: Bool = false) {
        let source = shared ? sharedSongs : searchSongs
        guard !source.isEmpty else { alert = shared ? "先に共有音源を読み込んでください" : "デモ曲がありません"; return }
        launchSolo(songs: source, playlist: shared ? "共有音源" : "オリジナルデモ")
    }

    func startSpotifySolo() async {
        guard spotifyPremium else { alert = "ひとりで Spotify の音源を再生するには Premium が必要です"; return }
        guard !spotifySongs.isEmpty else { alert = "先にプレイリストを選んでください"; return }
        guard !busy else { return }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        var selected = Array(spotifySongs.shuffled().prefix(10))
        for index in selected.indices {
            if let match = try? await rooms.matchItunes(selected[index]) { selected[index].genre = match.genre }
        }
        launchSolo(songs: selected, playlist: spotifyPlaylists.first { $0.id == selectedPlaylistID }?.name ?? "Spotify")
    }

    private func launchSolo(songs source: [Song], playlist: String) {
        let limit = min(10, source.count)
        let songs = Array(source.shuffled().prefix(limit))
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
        game.stage = .listening
        game.startedAt = .now
        game.deadline = .now.addingTimeInterval(30)
        game.secondsLeft = 30
        game.letterIndex = 0
        game.answered = ""
        game.wasCorrect = false
        game.warning = nil
        self.game = game
        stopAudio()
        playAudio(game.current)
        if game.current.id.hasPrefix("spotify:") {
            let song = game.current
            Task { [weak self] in
                guard let self else { return }
                self.rooms.baseURL = self.serverURL
                self.chorusPositions[song.id] = await self.rooms.chorus(song)
            }
        }
    }

    private func tick() {
        guard var game else { return }
        switch game.stage {
        case .listening, .answering:
            game.secondsLeft = max(0, game.deadline.timeIntervalSinceNow)
            if game.secondsLeft <= 0 {
                self.game = game
                reveal(correct: false)
            } else { self.game = game }
        default: break
        }
    }

    func push() {
        guard var game, game.stage == .listening else { return }
        game.pushTime = min(30, Date.now.timeIntervalSince(game.startedAt))
        game.stage = .answering
        game.letterIndex = 0
        game.deadline = .now.addingTimeInterval(5)
        game.secondsLeft = 5
        game.choices = TitleRules.choices(answer: game.answer[0], prefix: "", corpus: game.current.id.hasPrefix("spotify:") ? quizCorpus : game.songs.map(\.title))
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
                                              corpus: game.current.id.hasPrefix("spotify:") ? quizCorpus : game.songs.map(\.title))
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
                catch { if !Task.isCancelled { self.alert = error.localizedDescription } }
            }
        } else if let url = song.previewURL {
            player.play(url, offset: Double(offsetMS) / 1000)
        }
    }

    private func pauseAudio() {
        if spotifyPlaying {
            let previous = spotifyPauseTask
            let play = musicTask
            spotifyPauseTask = Task { [weak self] in
                await previous?.value
                await play?.value
                guard let self else { return }
                try? await self.spotify.pause()
            }
        }
        else { player.pause() }
    }

    private func stopAudio() {
        musicTask?.cancel(); musicTask = nil
        if spotifyPlaying { pauseAudio(); spotifyPlaying = false }
        player.stop()
    }

    private func revealAudio(_ song: Song) {
        guard song.id.hasPrefix("spotify:") else { playAudio(song); return }
        let estimated = max(0, min(90_000, max(30_000, Int(Double(song.durationMS) * 0.32))) - 1500)
        playAudio(song, offsetMS: song.chorusMS ?? chorusPositions[song.id] ?? estimated)
    }

    var totalGames: Int { stats.games }
    var totalCorrect: Int { stats.correct }
    var accuracy: Double { stats.accuracy }

    func createRoom() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        do {
            var songs: [Song] = []
            var corpus: [String] = []
            if roomMode != "shared" {
                guard !spotifySongs.isEmpty else { throw AppError.message("先に Spotify プレイリストを選んでください") }
                if roomMode == "spotify" && !spotifyPremium { throw AppError.message("Spotify 対戦には Premium が必要です") }
                if roomMode == "sabitro" {
                    for song in spotifySongs.shuffled().prefix(roomSettings.questionCount) {
                        if let match = try await rooms.matchItunes(song) { songs.append(match) }
                    }
                    guard !songs.isEmpty else { throw AppError.message("iTunes に一致する試聴曲がありません") }
                } else {
                    songs = Array(spotifySongs.shuffled().prefix(roomSettings.questionCount))
                    for index in songs.indices {
                        if let match = try? await rooms.matchItunes(songs[index]) { songs[index].genre = match.genre }
                    }
                }
                corpus = spotifySongs.map(\.title)
                corpus += (try? await rooms.topSongs()) ?? []
            }
            let state = try await rooms.create(name: nickname, settings: roomSettings, mode: roomMode,
                                               songs: songs, corpus: corpus, badge: stats.selectedBadge)
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
            }
            enterRoom(state)
        } catch { alert = error.localizedDescription }
    }

    func restoreRoom() async {
        guard serverConfigured, let roomID, room == nil else { return }
        rooms.baseURL = serverURL
        for _ in 0..<100 {
            guard self.roomID == roomID, room == nil else { return }
            do { enterRoom(try await rooms.state(roomID)); return }
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
        roomPoller?.cancel()
        roomTicker?.cancel()
        roomTicker = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let room = self.room {
                    self.roomSecondsLeft = max(0, self.remainingTime(room) - Date.now.timeIntervalSince(self.roomReceivedAt))
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
                    self.roomError = nil
                } catch { self.roomError = "接続を確認しています…" }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func receiveRoom(_ state: RoomState) {
        let old = room
        room = state
        roomReceivedAt = .now
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
                        guard !(try await self.spotify.devices()).isEmpty else {
                            throw AppError.message("Spotify アプリを開き、再生先を有効にしてください")
                        }
                    } else if let url = state.current?.previewURL {
                        try await self.player.prepare(url)
                    }
                    guard self.room?.round == state.round, self.room?.phase == "preparing" else { return }
                    self.receiveRoom(try await self.rooms.action("ready", id: state.id))
                } catch { self.roomError = error.localizedDescription }
            }
        }
        if state.phase == "countdown" && !roomAudioStarted && scheduledRoomAudio == nil {
            let delay = max(0, (state.startAt ?? state.serverNow) - state.serverNow)
            scheduledRoomAudio = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay)))
                guard let self, !Task.isCancelled, !self.roomAudioStarted,
                      self.room?.round == state.round,
                      self.room?.phase == "countdown" || self.room?.phase == "listening" || self.room?.phase == "answering" else { return }
                self.startRoomAudio(state)
                if self.room?.answeringPlayerID == self.rooms.playerId && !state.settings.endless {
                    self.pauseAudio()
                }
            }
        }
        if state.phase == "listening" && !roomAudioStarted {
            startRoomAudio(state)
        }
        if state.phase == "answering" && state.answeringPlayerID == rooms.playerId && old?.answeringPlayerID != rooms.playerId && !state.settings.endless {
            pauseAudio()
        }
        if state.phase == "listening" && old?.phase == "answering" && old?.answeringPlayerID == rooms.playerId && !state.settings.endless {
            startRoomAudio(state)
        }
        if state.phase == "reveal" && lastRoomPhase != "reveal" {
            scheduledRoomAudio?.cancel(); scheduledRoomAudio = nil
            stopAudio()
            if let song = state.current?.song { revealAudio(song) }
            UINotificationFeedbackGenerator().notificationOccurred(state.correctPlayerID == rooms.playerId ? .success : .warning)
        }
        if state.phase == "finished" && lastRoomPhase != "finished" {
            stopAudio()
        }
        lastRoomPhase = state.phase
    }

    private func startRoomAudio(_ state: RoomState) {
        guard let current = state.current else { return }
        let elapsed = max(0, (state.serverNow - (state.startAt ?? state.serverNow)) / 1000)
        if state.mode == "spotify" {
            playAudio(Song(id: current.id, title: "", artist: "", artworkURL: nil,
                           previewURL: nil, trackURL: nil, durationMS: 180_000, genre: "その他"),
                      offsetMS: Int(elapsed * 1000))
        } else if let preview = current.previewURL { player.play(preview, offset: elapsed) }
        roomAudioStarted = true
    }

    func remainingTime(_ state: RoomState) -> Double {
        let target = state.phase == "answering" && state.answeringPlayerID == rooms.playerId ? state.answerDeadline : state.roundDeadline
        return max(0, ((target ?? state.serverNow) - state.serverNow) / 1000)
    }

    func roomAction(_ action: String, payload: [String: Any] = [:]) async {
        guard let roomID else { return }
        if action == "push" { playPushCue(); UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        do { receiveRoom(try await rooms.action(action, id: roomID, payload: payload)) }
        catch { alert = error.localizedDescription }
    }

    private func playPushCue() {
        pushCue?.currentTime = 0
        pushCue?.play()
    }

    func leaveRoom() async {
        roomPoller?.cancel(); roomPoller = nil
        roomTicker?.cancel(); roomTicker = nil
        scheduledRoomAudio?.cancel(); scheduledRoomAudio = nil
        if let roomID { _ = try? await rooms.action("leave", id: roomID) }
        stopAudio()
        room = nil; roomID = nil; rooms.clear()
        UserDefaults.standard.removeObject(forKey: "roomID")
        lastRoomPhase = nil; lastRoomRound = nil; preparedRoomRound = nil; roomAudioStarted = false
    }
}
