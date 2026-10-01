import Foundation
import SwiftUI
import UIKit
import AVFoundation

enum SoloStage { case preparing, countdown, listening, answering, reveal, finished }

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
    @Published var game: SoloGame? { didSet { updateBGM() } }
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
    @Published private(set) var avatarData: Data? = PlayerAvatar.load()
    var roomAvatar: String? { avatarData?.base64EncodedString() }

    func setAvatar(_ image: UIImage, crop: CGRect) throws {
        avatarData = try PlayerAvatar.save(image, crop: crop)
    }

    func removeAvatar() throws {
        try PlayerAvatar.remove()
        avatarData = nil
    }
    @Published var room: RoomState? { didSet { updateBGM() } }
    @Published var roomID: String? = UserDefaults.standard.string(forKey: "roomID")
    @Published var roomSettings = RoomSettings()
    @Published var roomAnswer = ""
    @Published var roomOptions: [String] = []
    @Published var roomSecondsLeft = 30.0
    @Published var roomError: String?
    @Published var roomNotice: String?
    @Published var friendsState: FriendsState?
    @Published var friendsLoading = false
    @Published private(set) var locallyInvitedFriendIDs: Set<String> = []
    @Published var roomPushPending = false
    @Published var roomChoicePending = false
    @Published var roomRematchPending = false
    @Published var roomPreparationStatus: String?
    @Published var roomAudioStarting = false
    @Published private(set) var roomAudioStarted = false
    @Published var quizCorpus: [String] = []
    @Published var appleMusicConnected = false
    @Published var appleMusicPlayable = false
    @Published var appleMusicPlaylists: [AppleMusicPlaylist] = []
    @Published var appleMusicSongs: [Song] = []
    @Published var selectedAppleMusicPlaylistID = ""
    private var playlistSelectionRevision = 0
    @Published var itunesTerm = ""
    @Published var itunesSongs: [Song] = []
    @Published var profileSyncStatus: String?
    @Published var bgmVolume = UserDefaults.standard.object(forKey: "bgmVolume") as? Double ?? 0.35 {
        didSet {
            UserDefaults.standard.set(bgmVolume, forKey: "bgmVolume")
            sound.bgmVolume = Float(bgmVolume)
            updateBGM()
        }
    }
    @Published var effectsVolume = UserDefaults.standard.object(forKey: "effectsVolume") as? Double ?? 0.8 {
        didSet {
            UserDefaults.standard.set(effectsVolume, forKey: "effectsVolume")
            sound.effectsVolume = Float(effectsVolume)
        }
    }
    @Published var songVolume = UserDefaults.standard.object(forKey: "songVolume") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(songVolume, forKey: "songVolume")
            player.volume = Float(songVolume)
        }
    }

    let player = PreviewPlayer()
    let sound = GameSoundPlayer()
    let rooms = RoomService()
    let appleMusic = AppleMusicService()
    private let artistTopSongs = ArtistTopSongsService()
    private var ticker: Task<Void, Never>?
    private var soloRoundTask: Task<Void, Never>?
    private var soloRoundToken = 0
    private var roomSyncTask: Task<Void, Never>?
    private var roomNoticeTask: Task<Void, Never>?
    private var roomTicker: Task<Void, Never>?
    private var scheduledRoomAudio: Task<Void, Never>?
    private var lastRoomRound: Int?
    private var lastRoomPhase: String?
    private var preparedRoomRound: Int?
    private var roomPreloadTask: Task<Void, Never>?
    private var preloadedRoomID: String?
    private var appIsActive = false
    private var gameStartHolds = 0
    private var reviewAudioPlaying = false
    private var musicTask: Task<Void, Never>?
    private var appleMusicPlaying = false
    private var appleMusicPauseTask: Task<Void, Never>?
    private var profileSaveTask: Task<Void, Never>?
    private var recordedRoomAttempts = Set<String>()
    private var recordedRoomGenres = Set<String>()
    private var chorusPositions: [String: Int] = [:]
    private var chorusLookups: [String: Task<Int?, Never>] = [:]
    private var revealAudioTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "reviews"), let decoded = try? JSONDecoder().decode([ReviewSong].self, from: data) { reviews = decoded }
        if let data = UserDefaults.standard.data(forKey: "history"), let decoded = try? JSONDecoder().decode([SoloResult].self, from: data) { history = decoded }
        if let data = UserDefaults.standard.data(forKey: "stats"), let decoded = try? JSONDecoder().decode(PlayerStats.self, from: data) { stats = decoded }
        rooms.baseURL = serverURL
        appleMusicConnected = appleMusic.isAuthorized
        Secrets.set(nil, for: "spotifyRefresh")
        UserDefaults.standard.removeObject(forKey: "spotifyAccountID")
        UserDefaults.standard.removeObject(forKey: "musicAccountProvider")
        sound.bgmVolume = Float(bgmVolume)
        sound.effectsVolume = Float(effectsVolume)
        player.volume = Float(songVolume)
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        updateBGM()
    }

    func beginGameStart() {
        gameStartHolds += 1
        updateBGM()
    }

    func finishGameStart() {
        gameStartHolds = max(0, gameStartHolds - 1)
        updateBGM()
    }

    func setReviewAudioPlaying(_ playing: Bool) {
        guard reviewAudioPlaying != playing else { return }
        reviewAudioPlaying = playing
        updateBGM()
    }

    private func updateBGM() {
        let roomAllowsBGM = room?.phase == "lobby" || room == nil
        if appIsActive && gameStartHolds == 0 && game == nil && roomAllowsBGM && !reviewAudioPlaying && bgmVolume > 0 { sound.playBGM() }
        else { sound.pauseBGM() }
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

    func connectAppleMusic() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            appleMusicPlayable = try await appleMusic.authorize()
            appleMusicConnected = true
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
                playlistSelectionRevision += 1
                selectedAppleMusicPlaylistID = ""
                appleMusicSongs = []
            }
        } catch { alert = error.localizedDescription }
    }

    func selectAppleMusicPlaylist(_ id: String) async {
        playlistSelectionRevision += 1
        let revision = playlistSelectionRevision
        selectedAppleMusicPlaylistID = id
        appleMusicSongs = []
        guard !id.isEmpty else { busy = false; return }
        busy = true
        defer { if revision == playlistSelectionRevision { busy = false } }
        do {
            let songs = try await appleMusic.songs(in: id)
            guard revision == playlistSelectionRevision, selectedAppleMusicPlaylistID == id else { return }
            appleMusicSongs = songs
            quizCorpus = appleMusicSongs.map(\.title)
        } catch {
            if revision == playlistSelectionRevision { alert = error.localizedDescription }
        }
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
        beginGameStart()
        defer { finishGameStart() }
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
        beginGameStart()
        defer { finishGameStart() }
        busy = true; defer { busy = false; preparationStatus = nil }
        do { try await launchSolo(songs: source, playlist: shared ? "共有音源" : "オリジナルデモ") }
        catch { alert = error.localizedDescription }
    }

    func startItunesSolo() async {
        let songs = itunesSongs.filter { $0.playablePreview && !TitleRules.characters($0.title).isEmpty }
        guard !songs.isEmpty else { alert = "先に試聴曲を検索してください"; return }
        guard !busy else { return }
        beginGameStart()
        defer { finishGameStart() }
        busy = true; defer { busy = false; preparationStatus = nil }
        do { try await launchSolo(songs: songs, playlist: "サビトロ · 試聴曲") }
        catch { alert = error.localizedDescription }
    }

    func startSabitroSolo() async {
        guard !appleMusicSongs.isEmpty else { alert = "先にプレイリストを選んでください"; return }
        guard !busy else { return }
        beginGameStart()
        defer { finishGameStart() }
        busy = true; defer { busy = false; preparationStatus = nil }
        rooms.baseURL = serverURL
        do {
            var matches: [Song] = []
            var seen = Set<String>()
            for song in uniqueSongs(appleMusicSongs).shuffled() {
                if let match = try await rooms.matchItunes(song), match.playablePreview,
                   !TitleRules.characters(match.title).isEmpty,
                   seen.insert(match.id).inserted { matches.append(match) }
                if matches.count == 10 { break }
            }
            guard !matches.isEmpty else { alert = "iTunes に一致する試聴曲がありません"; return }
            try await launchSolo(songs: matches, playlist: "サビトロ · " + (appleMusicPlaylists.first { $0.id == selectedAppleMusicPlaylistID }?.name ?? "Apple Music"))
        } catch { alert = error.localizedDescription }
    }

    private func launchSolo(songs source: [Song], playlist: String) async throws {
        let candidates = uniqueSongs(source)
        let limit = min(10, candidates.count)
        preparationStatus = "選択肢を準備中"
        let songs = await withArtistTopTitles(Array(candidates.shuffled().prefix(limit)))
        preparationStatus = "画像と音源を準備中 0 / \(songs.count)"
        try await GameAssets.shared.prepare(songs.map(GameAsset.init(song:))) { [weak self] ready, total in
            self?.preparationStatus = "画像と音源を準備中 \(ready) / \(total)"
        }
        if songs.first?.id.hasPrefix("applemusic:") == true {
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
                let showsCentiseconds = self?.game?.stage == .listening
                self?.tick()
                try? await Task.sleep(for: .milliseconds(showsCentiseconds ? 10 : 80))
            }
        }
    }

    private func beginRound(advancingTo nextIndex: Int? = nil) {
        guard var game else { return }
        soloRoundTask?.cancel()
        soloRoundToken += 1
        let token = soloRoundToken
        if let nextIndex { game.index = nextIndex }
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
                if song.id.hasPrefix("applemusic:") {
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
                self.sound.play(.question)
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
        if song.id.hasPrefix("applemusic:") {
            _ = chorusLookup(for: song)
        }
    }

    private func startPreparedRoundAudio(_ song: Song, offsetMS: Int = 0) async throws {
        if song.id.hasPrefix("applemusic:") {
            await appleMusicPauseTask?.value
            try Task.checkCancellation()
            appleMusicPlaying = true
            try await playAppleMusicWithRetry(song, offsetMS: offsetMS)
        } else if let url = song.previewURL {
            try player.startPrepared(url, offset: Double(offsetMS) / 1000)
        }
    }

    private func playAppleMusicWithRetry(_ song: Song, offsetMS: Int) async throws {
        do { try await appleMusic.play(song, offsetMS: offsetMS) }
        catch {
            guard RoomService.isConnectionError(error), !Task.isCancelled else { throw error }
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            try await appleMusic.play(song, offsetMS: offsetMS)
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
        game.choices = TitleRules.choices(answer: game.answer[0], prefix: "", corpus: game.current.id.hasPrefix("applemusic:") ? quizCorpus : game.songs.map(\.title), artistTopTitles: game.current.artistTopTitles ?? [], currentTitle: game.current.title)
        stats.attempts += 1
        stats.totalPushSeconds += game.pushTime
        var genre = stats.genres[game.current.genre] ?? GenreRecord()
        genre.attempts += 1
        stats.genres[game.current.genre] = genre
        persist()
        self.game = game
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        sound.play(.push)
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
                                              corpus: game.current.id.hasPrefix("applemusic:") ? quizCorpus : game.songs.map(\.title))
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
        sound.play(correct ? .correct : .incorrect)
        revealAudio(game.current)
    }

    func nextRound() {
        guard var game, game.stage == .reveal else { return }
        if game.index + 1 < game.songs.count {
            withAnimation(Studio.spring) { beginRound(advancingTo: game.index + 1) }
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
        if song.id.hasPrefix("applemusic:") {
            appleMusicPlaying = true
            let pause = appleMusicPauseTask
            musicTask = Task { [weak self] in
                guard let self else { return }
                await pause?.value
                guard !Task.isCancelled else { return }
                do { try await self.playAppleMusicWithRetry(song, offsetMS: offsetMS) }
                catch {
                    guard !Task.isCancelled else { return }
                    if self.room?.phase == "reveal", self.room?.current?.id == song.id {
                        self.roomError = RoomService.isConnectionError(error)
                            ? "Apple Music との通信が途切れました。再生を再試行してください"
                            : error.localizedDescription
                        return
                    }
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
        } else { player.pause() }
    }

    private func stopAudio() {
        revealAudioTask?.cancel(); revealAudioTask = nil
        musicTask?.cancel(); musicTask = nil
        appleMusic.stop(); appleMusicPlaying = false
        player.stop()
    }

    private func revealAudio(_ song: Song) {
        guard song.id.hasPrefix("applemusic:") else { playAudio(song); return }
        if let position = song.chorusMS ?? chorusPositions[song.id] {
            playAudio(song, offsetMS: position)
            return
        }
        let lookup = chorusLookup(for: song)
        revealAudioTask?.cancel()
        revealAudioTask = Task { [weak self] in
            let position = await lookup.value
            guard let self, !Task.isCancelled else { return }
            if self.roomID != nil {
                guard self.room?.phase == "reveal", self.room?.current?.id == song.id else { return }
            } else {
                guard self.game?.stage == .reveal, self.game?.current.id == song.id else { return }
            }
            if let position {
                self.playAudio(song, offsetMS: position)
                return
            }
            if let preview = await self.appleMusic.previewURL(for: song.id), !Task.isCancelled {
                do {
                    try await self.player.prepare(preview)
                    guard !Task.isCancelled, self.isRevealing(song) else { return }
                    self.appleMusic.stop()
                    self.appleMusicPlaying = false
                    try self.player.startPrepared(preview)
                    return
                } catch {
                    guard !Task.isCancelled, self.isRevealing(song) else { return }
                    self.player.stop()
                }
            }
            guard !Task.isCancelled, self.isRevealing(song) else { return }
            self.playAudio(song, offsetMS: self.rooms.fallbackChorus(song))
        }
    }

    private func isRevealing(_ song: Song) -> Bool {
        if roomID != nil { return room?.phase == "reveal" && room?.current?.id == song.id }
        return game?.stage == .reveal && game?.current.id == song.id
    }

    private func chorusLookup(for song: Song) -> Task<Int?, Never> {
        if let lookup = chorusLookups[song.id] { return lookup }
        let lookup: Task<Int?, Never> = Task { [weak self] in
            guard let self else { return nil }
            self.rooms.baseURL = self.serverURL
            return await self.rooms.chorus(song)
        }
        chorusLookups[song.id] = lookup
        Task { [weak self] in
            let position = await lookup.value
            if let position { self?.chorusPositions[song.id] = position }
        }
        return lookup
    }

    var totalGames: Int { stats.games }
    var totalCorrect: Int { stats.correct }
    var accuracy: Double { stats.accuracy }

    private func withArtistTopTitles(_ songs: [Song]) async -> [Song] {
        var result = songs
        for index in result.indices {
            let titles = await artistTopSongs.titles(for: result[index].artist)
            result[index].artistTopTitles = titles
        }
        return result
    }

    private func uniqueSongs(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    func createRoom(mode: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        do {
            let state = try await rooms.create(name: nickname, settings: RoomSettings(), mode: mode,
                                               badge: stats.selectedBadge, avatar: roomAvatar,
                                               deferQuestions: true)
            guard state.mode == mode else {
                _ = try? await rooms.action("leave", id: state.id)
                throw AppError.message("対戦サーバーを更新してから、この音源でルームを作成してください")
            }
            roomSettings = RoomSettings()
            enterRoom(state)
        } catch { alert = error.localizedDescription }
    }

    func rematchRoom() async {
        guard let current = room, current.phase == "finished",
              current.hostId == rooms.playerId, !roomRematchPending else { return }
        roomRematchPending = true
        defer { roomRematchPending = false }
        do {
            guard room?.id == current.id, room?.phase == "finished" else { return }
            receiveNetworkRoom(try await rooms.action("rematch", id: current.id))
            roomSettings = current.settings
        } catch {
            showRoomNotice(error.localizedDescription)
        }
    }

    func startRoom() async {
        guard let current = room, current.phase == "lobby", current.hostId == rooms.playerId,
              !busy else { return }
        let selectedSettings = roomSettings
        let selectedPlaylistSongs = appleMusicSongs
        busy = true
        defer { busy = false; preparationStatus = nil }
        do {
            var songs: [Song] = []
            var corpus: [String] = []
            if current.mode != "shared" {
                guard !selectedPlaylistSongs.isEmpty else {
                    throw AppError.message("先に Apple Music のプレイリストを選んでください")
                }
                if current.mode == "applemusic" {
                    guard appleMusicConnected, appleMusicPlayable else {
                        throw AppError.message("Apple Music のアクセス許可とサブスクリプションが必要です")
                    }
                }
                let played = Set(current.playedSongIDs ?? [])
                var fresh: [Song] = []
                var used: [Song] = []
                var seen = Set<String>()
                let candidates = uniqueSongs(selectedPlaylistSongs).shuffled()
                for (index, candidate) in candidates.enumerated() {
                    preparationStatus = "プレイリストの曲を確認中 \(index + 1) / \(candidates.count)"
                    let match: Song?
                    if current.mode == "applemusic" {
                        match = await appleMusic.catalogSongs(for: [candidate]).first
                    } else {
                        match = try await rooms.matchItunes(candidate)
                    }
                    if let match, (current.mode == "applemusic" || match.playablePreview),
                       !TitleRules.characters(match.title).isEmpty, seen.insert(match.id).inserted {
                        if played.contains(match.id) { used.append(match) }
                        else { fresh.append(match) }
                    }
                    if fresh.count >= selectedSettings.questionCount { break }
                }
                songs = Array((fresh + used).prefix(selectedSettings.questionCount))
                guard songs.count >= selectedSettings.questionCount else {
                    throw AppError.message("指定された問題数分の曲を用意できません（照合可能: \(songs.count)曲）")
                }
                songs = await withArtistTopTitles(songs)
                corpus = selectedPlaylistSongs.map(\.title)
            }
            let songData = try JSONEncoder().encode(songs)
            let songList = try JSONSerialization.jsonObject(with: songData)
            let settingsData = try JSONEncoder().encode(selectedSettings)
            let rules = try JSONSerialization.jsonObject(with: settingsData)
            guard room?.id == current.id, room?.phase == "lobby" else { return }
            receiveNetworkRoom(try await rooms.action("start", id: current.id,
                payload: ["settings": rules, "songs": songList, "corpus": corpus]))
        } catch { showRoomNotice(error.localizedDescription) }
    }

    func joinRoom(_ code: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        do {
            let state = try await rooms.join(code.trimmingCharacters(in: .whitespacesAndNewlines), name: nickname,
                                             badge: stats.selectedBadge, avatar: roomAvatar)
            if state.mode == "applemusic" {
                guard appleMusicConnected, try await appleMusic.canPlay() else {
                    _ = try? await rooms.action("leave", id: state.id)
                    throw AppError.message("このルームには Apple Music の接続とサブスクリプションが必要です")
                }
            }
            enterRoom(state)
        } catch { alert = error.localizedDescription }
    }

    func refreshFriends(reportErrors: Bool = true) async {
        guard serverConfigured else { return }
        rooms.baseURL = serverURL
        do { friendsState = try await rooms.friends() }
        catch { if reportErrors { alert = error.localizedDescription } }
    }

    func respondToFriendRequest(_ id: String, accept: Bool) async {
        guard !friendsLoading else { return }
        friendsLoading = true; defer { friendsLoading = false }
        do { friendsState = try await rooms.respondToFriendRequest(id, accept: accept) }
        catch { alert = error.localizedDescription }
    }

    func sendFriendRequest(to playerID: String) async {
        guard let id = roomID, !friendsLoading else { return }
        friendsLoading = true; defer { friendsLoading = false }
        do {
            receiveNetworkRoom(try await rooms.sendFriendRequest(roomID: id, targetID: playerID))
            roomNotice = "フレンド申請を送りました"
        }
        catch { alert = error.localizedDescription }
    }

    func inviteFriend(_ profileID: String) async {
        guard let id = roomID, room?.phase == "lobby", !friendsLoading,
              !hasInvitedFriend(profileID) else { return }
        friendsLoading = true; defer { friendsLoading = false }
        do {
            try await rooms.inviteFriend(roomID: id, profileID: profileID)
            if roomID == id { locallyInvitedFriendIDs.insert(profileID) }
            roomNotice = "招待を送りました"
        } catch { alert = error.localizedDescription }
    }

    func hasInvitedFriend(_ profileID: String) -> Bool {
        guard let roomID else { return false }
        return locallyInvitedFriendIDs.contains(profileID) ||
            friendsState?.sentInvites?.contains(where: {
                $0.roomId == roomID && $0.targetId == profileID
            }) == true
    }

    func joinInvite(_ inviteID: String) async {
        guard !busy, room == nil else { return }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        do {
            if let mode = friendsState?.invites.first(where: { $0.id == inviteID })?.mode {
                if mode == "applemusic" {
                    guard appleMusicConnected, try await appleMusic.canPlay() else {
                        throw AppError.message("このルームには Apple Music の接続とサブスクリプションが必要です")
                    }
                }
            }
            let state = try await rooms.joinInvite(inviteID, name: nickname,
                                                    badge: stats.selectedBadge, avatar: roomAvatar)
            if state.mode == "applemusic" {
                guard appleMusicConnected, try await appleMusic.canPlay() else {
                    _ = try? await rooms.action("leave", id: state.id)
                    throw AppError.message("このルームには Apple Music の接続とサブスクリプションが必要です")
                }
            }
            enterRoom(state)
            await refreshFriends()
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
        locallyInvitedFriendIDs.removeAll()
        if state.phase == "lobby", (state.gameNumber ?? 0) > 0,
           state.hostId == rooms.playerId { roomSettings = state.settings }
        roomID = state.id
        UserDefaults.standard.set(state.id, forKey: "roomID")
        room = state
        roomError = nil
        roomNoticeTask?.cancel(); roomNoticeTask = nil
        roomNotice = nil
        roomPushPending = false
        roomChoicePending = false
        preloadedRoomID = nil
        roomPreloadTask?.cancel()
        roomSyncTask?.cancel()
        roomTicker?.cancel()
        roomTicker = Task { [weak self] in
            while !Task.isCancelled {
                var showsCentiseconds = false
                if let self, let room = self.room {
                    self.roomSecondsLeft = self.remainingTime(room)
                    showsCentiseconds = room.phase == "listening" ||
                        room.phase == "answering" && !room.pushClosed &&
                        !room.isAnswering(self.rooms.playerId)
                }
                try? await Task.sleep(for: .milliseconds(showsCentiseconds ? 10 : 60))
            }
        }
        roomSyncTask = Task { [weak self] in
            var streamSupported = true
            var retrySeconds = 1
            while !Task.isCancelled {
                guard let self, let id = self.roomID else { break }
                do {
                    try await self.rooms.watchSocket(id) { [weak self] state in
                        guard let self, self.roomID == id else { return }
                        self.receiveNetworkRoom(state)
                        if self.roomError == "接続を確認しています…" { self.roomError = nil }
                    }
                } catch { /* SSE below keeps the room usable if WebSocket is unavailable. */ }
                if Task.isCancelled || self.roomID != id { break }
                if streamSupported {
                    do {
                        try await self.rooms.watch(id) { [weak self] state in
                            guard let self, self.roomID == id else { return }
                            self.receiveNetworkRoom(state)
                            if self.roomError == "接続を確認しています…" { self.roomError = nil }
                        }
                    } catch RoomStreamError.unsupported {
                        streamSupported = false
                    } catch { /* A state request below checks whether the room is reachable. */ }
                }
                if Task.isCancelled || self.roomID != id { break }
                do {
                    let state = try await self.rooms.state(id)
                    self.receiveNetworkRoom(state)
                    if self.roomError == "接続を確認しています…" { self.roomError = nil }
                } catch { self.roomError = "接続を確認しています…" }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(streamSupported ? retrySeconds : 2))
                if streamSupported { retrySeconds = min(retrySeconds * 2, 8) }
            }
        }
    }

    private func receiveNetworkRoom(_ state: RoomState) {
        if let current = room, current.id == state.id {
            if state.serverNow < current.serverNow { return }
            if state.serverNow == current.serverNow,
               let sequence = state.sequence, let currentSequence = current.sequence,
               sequence <= currentSequence { return }
        }
        receiveRoom(state)
    }

    private func receiveRoom(_ state: RoomState) {
        let old = room
        if state.phase == "lobby", (state.gameNumber ?? 0) > 0,
           state.hostId == rooms.playerId,
           (old?.gameNumber != state.gameNumber || old?.hostId != state.hostId) {
            roomSettings = state.settings
        }
        if old?.id == state.id, old?.gameNumber != state.gameNumber {
            preloadedRoomID = nil
            preparedRoomRound = nil
            roomPreloadTask?.cancel()
            roomPreparationStatus = nil
            roomError = nil
        }
        if state.phase == "countdown" &&
            (old?.id != state.id || old?.round != state.round || old?.phase != "countdown") {
            sound.play(.question)
        }
        if let old, old.id == state.id, old.round == state.round {
            let previousPushes = Set(old.pushedIds)
            for id in state.pushedIds where !previousPushes.contains(id) && id != rooms.playerId {
                sound.play(.push)
            }
            for player in state.players {
                let previous = old.player(player.id)?.currentResult
                if previous != player.currentResult {
                    if player.currentResult == "correct" { sound.play(.correct) }
                    if player.currentResult == "wrong" { sound.play(.incorrect) }
                }
            }
        }
        room = state
        if old?.round != state.round { roomNotice = nil }
        if old?.isAnswering(rooms.playerId) != true && state.isAnswering(rooms.playerId) {
            roomNotice = nil
        }
        if state.phase == "lobby", state.totalRounds > 0, preloadedRoomID != state.id,
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
                    if state.mode == "applemusic" {
                        try await self.appleMusic.prepareCatalog(assets.map(\.id))
                        if let first = assets.first { try await self.appleMusic.prepare(first.id) }
                    }
                    guard !Task.isCancelled, self.room?.id == state.id, self.room?.phase == "lobby" else { return }
                    self.receiveNetworkRoom(try await self.rooms.action("assets-ready", id: state.id))
                    self.roomPreparationStatus = "準備完了"
                    self.roomError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self.roomPreparationStatus = nil
                    self.roomError = error.localizedDescription
                }
            }
        }
        let key = "\(state.id):\(state.gameNumber ?? 0):\(state.round)"
        if state.round >= 0 && state.pushedIds.contains(rooms.playerId) && !recordedRoomAttempts.contains(key) {
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
            if state.correctPlayerIDs.contains(rooms.playerId) { record.correct += 1; stats.correct += 1 }
            stats.genres[genre] = record
            stats.awardBadges()
            persist()
        }
        if state.phase == "finished" {
            var finished = Set(UserDefaults.standard.stringArray(forKey: "finishedRoomIDs") ?? [])
            let gameKey = "\(state.id):\(state.gameNumber ?? 0)"
            if !finished.contains(gameKey) {
                finished.insert(gameKey)
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
                    if state.mode == "applemusic", let id = state.current?.id {
                        try await self.appleMusic.prepare(id)
                    } else if let url = state.current?.previewURL {
                        try await self.player.prepare(url)
                    }
                    guard self.room?.round == state.round, self.room?.phase == "preparing" else { return }
                    self.receiveNetworkRoom(try await self.rooms.action("ready", id: state.id))
                } catch {
                    if self.room?.round == state.round { self.roomError = error.localizedDescription }
                }
            }
        }
        if state.phase == "countdown" && !roomAudioStarted && scheduledRoomAudio == nil {
            let startAt = state.startAt ?? state.serverNow
            let delay = max(0, startAt - rooms.serverNowMS)
            if state.mode != "applemusic",
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
                          ["countdown", "listening", "answering"].contains(self.room?.phase ?? ""),
                          self.room?.pausedAt == nil, self.room?.questionAudioClosed == false else { return }
                    await self.startRoomAudio(state)
                    if self.room?.isAnswering(self.rooms.playerId) == true { self.pauseAudio() }
                }
            }
        }
        if ["listening", "answering"].contains(state.phase) && state.pausedAt == nil && !state.questionAudioClosed &&
           !state.isAnswering(rooms.playerId) && !roomAudioStarted && scheduledRoomAudio == nil {
            scheduledRoomAudio = Task { [weak self] in
                await self?.startRoomAudio(state)
            }
        }
        if state.pausedAt != nil && old?.pausedAt == nil {
            if !roomAudioStarting {
                scheduledRoomAudio?.cancel()
                scheduledRoomAudio = nil
            }
            pauseAudio()
        }
        if !state.settings.endless && !state.questionAudioClosed &&
           state.isAnswering(rooms.playerId) && old?.isAnswering(rooms.playerId) != true {
            pauseAudio()
        }
        if state.questionAudioClosed && old?.questionAudioClosed != true {
            pauseAudio()
            scheduledRoomAudio?.cancel()
            scheduledRoomAudio = nil
        }
        let resumedFromRelay = old?.pausedAt != nil && state.pausedAt == nil
        let finishedOwnAnswer = !state.settings.endless && old?.isAnswering(rooms.playerId) == true && !state.isAnswering(rooms.playerId)
        if (resumedFromRelay || finishedOwnAnswer) && !state.questionAudioClosed &&
           ["listening", "answering"].contains(state.phase) {
            Task { [weak self] in await self?.startRoomAudio(state) }
        }
        if state.phase == "reveal" && lastRoomPhase != "reveal" {
            scheduledRoomAudio?.cancel()
            stopAudio()
            scheduledRoomAudio = nil
            roomError = nil
            if let song = state.current?.song { revealAudio(song) }
            UINotificationFeedbackGenerator().notificationOccurred(state.correctPlayerIDs.contains(rooms.playerId) ? .success : .warning)
        }
        if state.phase == "finished" && lastRoomPhase != "finished" {
            stopAudio()
        }
        lastRoomPhase = state.phase
    }

    private func startRoomAudio(_ state: RoomState) async {
        while roomAudioStarting {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let playbackState = room, playbackState.round == state.round,
              ["countdown", "listening", "answering"].contains(playbackState.phase),
              playbackState.pausedAt == nil, !playbackState.questionAudioClosed,
              !playbackState.isAnswering(rooms.playerId),
              let current = playbackState.current else { return }
        roomAudioStarting = true
        defer { roomAudioStarting = false }
        do {
            let elapsed = max(0, rooms.serverNowMS - (playbackState.startAt ?? rooms.serverNowMS))
            if playbackState.mode == "applemusic" {
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
            if room?.pausedAt != nil || room?.questionAudioClosed == true || room?.isAnswering(rooms.playerId) == true { pauseAudio() }
            if room?.phase == "reveal" || room?.phase == "finished" { stopAudio() }
        } catch {
            guard room?.round == state.round, !Task.isCancelled else { return }
            roomAudioStarted = false
            roomError = state.mode == "applemusic" && RoomService.isConnectionError(error)
                ? "Apple Music との通信が途切れました。再生を再試行してください"
                : error.localizedDescription
        }
    }

    func remainingTime(_ state: RoomState) -> Double {
        if state.isAnswering(rooms.playerId), let deadline = state.answerDeadline {
            return max(0, (deadline - rooms.serverNowMS) / 1000)
        }
        let clock = state.pausedAt ?? rooms.serverNowMS
        return max(0, ((state.roundDeadline ?? clock) - clock) / 1000)
    }

    func beginRoomPush() {
        guard let roomID, !roomPushPending,
              room?.canPush(rooms.playerId, nowMS: rooms.serverNowMS) == true else { return }
        roomPushPending = true
        Task { [weak self] in
            guard let self, self.roomID == roomID else { return }
            await self.roomAction("push")
        }
        sound.play(.push)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func updateRoomHandicaps(_ handicaps: [String: Int]) async -> Bool {
        guard let roomID, room?.phase == "lobby", room?.hostId == rooms.playerId else { return false }
        do {
            let state = try await rooms.action("handicaps", id: roomID, payload: ["handicaps": handicaps])
            guard self.roomID == roomID else { return false }
            receiveNetworkRoom(state)
            return true
        } catch {
            showRoomNotice(error.localizedDescription)
            return false
        }
    }

    func roomAction(_ action: String, payload: [String: Any] = [:]) async {
        guard let roomID else { return }
        if action == "push" && !roomPushPending { return }
        if action == "choose" {
            guard !roomChoicePending, room?.isAnswering(rooms.playerId) == true else { return }
            roomChoicePending = true
        }
        let previousAnswer = roomAnswer
        let previousRound = room?.round
        defer {
            if action == "push" { roomPushPending = false }
            if action == "choose", self.roomID == roomID { roomChoicePending = false }
        }
        do {
            let state = try await rooms.action(action, id: roomID, payload: payload)
            guard self.roomID == roomID else { return }
            roomNotice = nil
            receiveNetworkRoom(state)
        } catch {
            guard self.roomID == roomID else { return }
            if action == "push", let failure = error as? RoomHTTPError, failure.status == 409 {
                if let state = failure.state { receiveNetworkRoom(state) }
                else if let state = try? await rooms.state(roomID), self.roomID == roomID { receiveNetworkRoom(state) }
                if room?.isAnswering(rooms.playerId) == true { return }
                let queued = room?.settings.endless == true &&
                    (room?.pushOrderIds ?? []).contains(rooms.playerId) &&
                    room?.pushedIds.contains(rooms.playerId) == false
                showRoomNotice(failure.message.contains("ハンデ") ? failure.message :
                    queued ? "PUSHを記録しました。前の人が誤答すると解答できます" :
                    "解答権は取れませんでした。ルームには残っています")
            } else if action == "choose", RoomService.isConnectionError(error) {
                if let state = try? await rooms.state(roomID), self.roomID == roomID {
                    receiveNetworkRoom(state)
                    if state.round != previousRound || !state.isAnswering(rooms.playerId) ||
                        state.answerProgress != previousAnswer { return }
                }
                showRoomNotice("通信が途切れました。接続を確認して選び直してください")
            } else {
                showRoomNotice(error.localizedDescription)
            }
        }
    }

    private func showRoomNotice(_ message: String) {
        roomNotice = message
        roomNoticeTask?.cancel()
        roomNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.roomNotice = nil
        }
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
        guard let room, ["countdown", "listening", "answering"].contains(room.phase),
              room.pausedAt == nil, !room.questionAudioClosed, !room.isAnswering(rooms.playerId) else { return }
        scheduledRoomAudio?.cancel()
        scheduledRoomAudio = nil
        roomError = nil
        receiveRoom(room)
    }

    func retryRoomRevealAudio() {
        guard let room, room.phase == "reveal", let song = room.current?.song else { return }
        roomError = nil
        stopAudio()
        revealAudio(song)
    }

    func leaveRoom() async {
        roomNoticeTask?.cancel(); roomNoticeTask = nil
        roomNotice = nil; roomPushPending = false
        roomChoicePending = false
        roomPreloadTask?.cancel(); roomPreloadTask = nil
        preloadedRoomID = nil; roomPreparationStatus = nil
        roomSyncTask?.cancel(); roomSyncTask = nil
        roomTicker?.cancel(); roomTicker = nil
        scheduledRoomAudio?.cancel()
        if let roomID { _ = try? await rooms.action("leave", id: roomID) }
        stopAudio()
        scheduledRoomAudio = nil
        room = nil; roomID = nil; rooms.clear()
        locallyInvitedFriendIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: "roomID")
        lastRoomPhase = nil; lastRoomRound = nil; preparedRoomRound = nil; roomAudioStarted = false; roomAudioStarting = false
    }
}
