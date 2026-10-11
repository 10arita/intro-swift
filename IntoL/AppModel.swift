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
    var roundResults: [SoloRoundResult] = []
    var secondsLeft = 30.0
    var warning: String?
    var current: Song { songs[index] }
    var answer: [String] { TitleRules.characters(current.title) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var searchTerm = ""
    @Published var searchSongs: [Song] = []
    @Published var sharedSongs: [Song] = []
    @Published var game: SoloGame? { didSet { updateBGM(); if game == nil { scheduleProfileSync() } } }
    @Published var lastResult: SoloResult?
    @Published private(set) var soloChoiceFeedback: ChoiceFeedback?
    @Published private(set) var soloChoicePending = false
    @Published private(set) var roomChoiceFeedback: ChoiceFeedback?
    @Published var reviews: [ReviewSong] = []
    @Published var history: [SoloResult] = []
    @Published var stats = PlayerStats()
    @Published var busy = false { didSet { if !busy { scheduleProfileSync() } } }
    @Published var preparationStatus: String?
    @Published var roomStartProgress: Double?
    @Published var alert: String?
    let serverURL: String
    var serverConfigured: Bool { !serverURL.isEmpty }
    @Published var nickname = UserDefaults.standard.string(forKey: "nickname") ?? "プレイヤー" {
        didSet { UserDefaults.standard.set(nickname, forKey: "nickname"); persist() }
    }
    @Published private(set) var avatarData: Data? = PlayerAvatar.load()
    var roomAvatar: String? { avatarData?.base64EncodedString() }

    func setAvatar(_ image: UIImage, crop: CGRect) throws {
        avatarData = try PlayerAvatar.save(image, crop: crop)
        persist()
    }

    func removeAvatar() throws {
        try PlayerAvatar.remove()
        avatarData = nil
        persist()
    }
    @Published var room: RoomState? { didSet { updateBGM(); if room == nil { scheduleProfileSync() } } }
    @Published var roomID: String? = UserDefaults.standard.string(forKey: "roomID") {
        didSet { if roomID == nil { scheduleProfileSync() } }
    }
    @Published var roomSettings = RoomSettings()
    @Published private(set) var roomLobbySyncing = false
    @Published var roomAnswer = ""
    @Published var roomOptions: [String] = []
    @Published var roomSecondsLeft = 30.0
    @Published var roomError: String?
    @Published var roomNotice: String?
    @Published var friendsState: FriendsState?
    @Published var friendsLoading = false
    @Published private(set) var locallyInvitedFriendIDs: Set<String> = []
    @Published var roomPushPending = false
    @Published private(set) var roomPendingPushTimeMS: Double?
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
    @Published private(set) var profileSyncing = false
    @Published var bgmVolume = UserDefaults.standard.object(forKey: "bgmVolume") as? Double ?? 0.35 {
        didSet {
            UserDefaults.standard.set(bgmVolume, forKey: "bgmVolume")
            sound.bgmVolume = Float(bgmVolume)
            updateBGM()
            persist()
        }
    }
    @Published var effectsVolume = UserDefaults.standard.object(forKey: "effectsVolume") as? Double ?? 0.8 {
        didSet {
            UserDefaults.standard.set(effectsVolume, forKey: "effectsVolume")
            sound.effectsVolume = Float(effectsVolume)
            persist()
        }
    }
    @Published var songVolume = UserDefaults.standard.object(forKey: "songVolume") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(songVolume, forKey: "songVolume")
            player.volume = Float(songVolume)
            persist()
        }
    }

    let player = PreviewPlayer()
    let sound = GameSoundPlayer()
    let rooms = RoomService(databaseChorusLookup: { await CloudChorusDatabase.shared.revealPosition(for: $0) })
    let appleMusic = AppleMusicService()
    private let artistTopSongs = ArtistTopSongsService()
    private let playlistPreparation = PlaylistPreparation()
    private struct PreparedRoomSongs {
        let roomID: String
        let gameNumber: Int?
        let source: [Song]
        let count: Int
        let playedIDs: Set<String>
        let songs: [Song]
    }
    private var preparedRoomSongs: PreparedRoomSongs?
    private var ticker: Task<Void, Never>?
    private var soloRoundTask: Task<Void, Never>?
    private var soloChoiceTask: Task<Void, Never>?
    private var roomChoiceFeedbackTask: Task<Void, Never>?
    private var pendingRoomChoice: (choice: String, choices: [String], answer: String)?
    private var soloRoundToken = 0
    private var roomSyncTask: Task<Void, Never>?
    private var roomLobbySyncTask: Task<Void, Never>?
    private var roomLobbyRevision = 0
    private var roomLobbySyncID = UUID()
    private var roomNoticeTask: Task<Void, Never>?
    private var roomTicker: Task<Void, Never>?
    private var scheduledRoomAudio: Task<Void, Never>?
    private var lastRoomRound: Int?
    private var lastRoomPhase: String?
    private var preparedRoomRound: Int?
    private var roomPreloadTask: Task<Void, Never>?
    private let roomRoundPreparation = RoomPreparationTask()
    private var roomAudioRevision = 0
    private var leavingRoomID: String?
    private var preloadedRoomID: String?
    private var appIsActive = false
    private var gameStartHolds = 0
    private var reviewAudioPlaying = false
    private var appleMusicPlaying = false
    private var appleMusicPauseTask: Task<Void, Never>?
    private var profileSaveTask: Task<Void, Never>?
    private let cloudProfiles = CloudProfileService()
    private var cloudProfile: CloudProfile?
    private var applyingProfile = false
    private var profileSyncAgain = false
    private var profileAccountRevision = 0
    private var profileCacheReadable = true
    private var profileDeviceID: String = {
        if let saved = Secrets.get("cloudProfileDeviceID") { return saved }
        let created = UUID().uuidString
        Secrets.set(created, for: "cloudProfileDeviceID")
        return created
    }()
    private var roomStatistics = RoomStatisticsLedger()
    private var chorusPositions: [String: Int] = [:]
    private var chorusLookups: [String: Task<Int?, Never>] = [:]
    private var revealAudioTask: Task<Void, Never>?
    @Published private(set) var revealReport: ChorusReport?
    @Published private(set) var chorusReportDraft: ChorusReport?
    @Published private(set) var chorusReportSendingID: UUID?
    @Published private(set) var chorusReportSentID: UUID?
    @Published private(set) var chorusReportError: String?
    private let chorusReportSender: (ChorusReport, String) async throws -> Void

    func presentChorusReport(for song: Song) {
        guard let report = revealReport, report.song.id == song.id,
              chorusReportSentID != report.id, chorusReportSendingID == nil else { return }
        chorusReportError = nil
        chorusReportDraft = report
    }

    func dismissChorusReport() {
        guard chorusReportSendingID == nil else { return }
        chorusReportDraft = nil
        chorusReportError = nil
    }

    func submitChorusReport() async {
        guard let report = chorusReportDraft, chorusReportSendingID == nil,
              chorusReportSentID != report.id else { return }
        chorusReportSendingID = report.id
        chorusReportError = nil
        defer { chorusReportSendingID = nil }
        do {
            try await chorusReportSender(report, serverURL)
            chorusReportSentID = report.id
        } catch {
            guard chorusReportDraft?.id == report.id else { return }
            chorusReportError = "送信できませんでした。\n\(error.localizedDescription)"
        }
    }

    func recordRevealPlayback(_ song: Song, source: RevealPlaybackSource, startPositionMS: Int) {
        revealReport = ChorusReport(song: song, source: source, startPositionMS: startPositionMS,
                                   playMode: room != nil ? "room" : "solo")
    }

    init(serverURL: String = AppConfiguration.serverURL,
         chorusReportSender: @escaping (ChorusReport, String) async throws -> Void = { report, url in
             try await ChorusReportService().send(report, serverURL: url)
         }) {
        self.serverURL = serverURL
        self.chorusReportSender = chorusReportSender
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
        do {
            if let cached = try CloudProfileCache.load(owner: CloudProfileCache.owner) {
                cloudProfile = cached
                try applyProfile(cached)
            } else {
                // Keychain can survive uninstalling the app. Start a fresh counter stream when its cache is gone.
                profileDeviceID = UUID().uuidString
                Secrets.set(profileDeviceID, for: "cloudProfileDeviceID")
                var initial = CloudProfile(nickname: nickname, avatar: avatarData, audio: profileAudio,
                    reviews: reviews, history: history, stats: stats, serverProfileID: rooms.profileID)
                initial.roomStatisticsByDevice = [profileDeviceID: roomStatistics]
                if UserDefaults.standard.bool(forKey: "profileDirty") {
                    // The old app treated dirty local data as authoritative, including removed reviews.
                    initial.importedLegacyProfiles.insert(rooms.profileID)
                }
                cloudProfile = initial
                try CloudProfileCache.save(initial, owner: CloudProfileCache.owner)
                UserDefaults.standard.removeObject(forKey: "profileDirty")
            }
        } catch {
            profileCacheReadable = false
            profileSyncStatus = "端末のプロフィールを読み込めません: \(error.localizedDescription)"
        }
        rooms.onProfileCredentialsChange = { [weak self] in self?.scheduleProfileSync() }
        if profileSyncStatus == nil {
            profileSyncStatus = AppConfiguration.cloudKitEnabled ? "端末に保存済み・iCloud同期待ち" : CloudProfileError.notConfigured.localizedDescription
        }
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
        if gameStartHolds == 0 { scheduleProfileSync() }
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
            let matches = try await playlistPreparation.songs(from: appleMusicSongs.shuffled(), count: 10,
                namespace: "itunes:\(serverURL)", requiresPreview: true,
                progress: { [weak self] ready, total in
                    self?.preparationStatus = "出題曲を準備中 \(ready) / \(total)"
                }, resolve: { [rooms] song in try await rooms.matchItunes(song) })
            guard !matches.isEmpty else { alert = "iTunes に一致する試聴曲がありません"; return }
            try await launchSolo(songs: matches, playlist: "サビトロ · " + (appleMusicPlaylists.first { $0.id == selectedAppleMusicPlaylistID }?.name ?? "Apple Music"))
        } catch is CancellationError { }
        catch { alert = error.localizedDescription }
    }

    private func launchSolo(songs source: [Song], playlist: String) async throws {
        guard canStartSolo else { throw AppError.message("先に現在のゲームまたはルームを終了してください") }
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
        guard canStartSolo else { throw AppError.message("先に現在のゲームまたはルームを終了してください") }
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
        if RevealAudioPlayback.hasFullAudio(song) {
            _ = chorusLookup(for: song)
        }
    }

    private func startPreparedRoundAudio(_ song: Song, offsetMS: Int = 0,
                                         offsetProvider: (() throws -> Int)? = nil) async throws {
        if song.id.hasPrefix("applemusic:") {
            await appleMusicPauseTask?.value
            try Task.checkCancellation()
            appleMusicPlaying = true
            try await playAppleMusicWithRetry(song, offsetMS: offsetMS, offsetProvider: offsetProvider)
        } else if let url = song.previewURL {
            try player.startPrepared(url, offset: Double(try offsetProvider?() ?? offsetMS) / 1000)
        }
    }

    private func playAppleMusicWithRetry(_ song: Song, offsetMS: Int,
                                         offsetProvider: (() throws -> Int)? = nil) async throws {
        do { try await appleMusic.play(song, offsetMS: offsetMS, offsetProvider: offsetProvider) }
        catch {
            guard RoomService.isConnectionError(error), !Task.isCancelled else { throw error }
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            try await appleMusic.play(song, offsetMS: offsetMS, offsetProvider: offsetProvider)
        }
    }

    private func tick() {
        guard var game else { return }
        switch game.stage {
        case .countdown:
            game.secondsLeft = max(0, game.deadline.timeIntervalSinceNow)
            self.game = game
        case .listening, .answering:
            if soloChoicePending { return }
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
        sound.play(.push)
        pauseAudio()
    }

    func choose(_ choice: String) {
        guard let game, game.stage == .answering, !soloChoicePending,
              game.choices.contains(choice) else { return }
        soloChoicePending = true
        soloChoiceFeedback = ChoiceFeedback(choice: choice, correct: choice == game.answer[game.letterIndex], choices: game.choices)
        let round = game.index
        let token = soloRoundToken
        soloChoiceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, self.soloRoundToken == token, self.game?.index == round,
                  self.game?.stage == .answering else { return }
            self.soloChoicePending = false
            self.soloChoiceFeedback = nil
            self.commitSoloChoice(choice)
        }
    }

    private func commitSoloChoice(_ choice: String) {
        guard var game, game.stage == .answering else { return }
        guard choice == game.answer[game.letterIndex] else {
            reveal(correct: false)
            return
        }
        game.answered += choice
        game.letterIndex += 1
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
        game.roundResults.append(SoloRoundResult(song: game.current.portableReviewSong, correct: correct,
            pushTime: game.stage == .answering ? game.pushTime : nil))
        game.stage = .reveal
        game.wasCorrect = correct
        if correct {
            game.correctPushTimes.append(game.pushTime)
            stats.correct += 1
            var genre = stats.genres[game.current.genre] ?? GenreRecord()
            genre.correct += 1
            stats.genres[game.current.genre] = genre
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
            let result = SoloResult.make(playlist: game.playlist, total: game.songs.count, pushTimes: game.correctPushTimes, rounds: game.roundResults)
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
        soloChoiceTask?.cancel(); soloChoiceTask = nil
        soloChoicePending = false; soloChoiceFeedback = nil
        soloRoundTask?.cancel(); soloRoundTask = nil; soloRoundToken += 1
        ticker?.cancel(); ticker = nil
        stopAudio()
        game = nil
    }

    func saveReview(_ song: Song) {
        guard !reviews.contains(where: { $0.id == song.id }) else { return }
        reviews.insert(ReviewSong(song: song.portableReviewSong), at: 0)
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
        guard !applyingProfile else { return }
        saveLegacyProfileCache()
        guard profileCacheReadable, var profile = cloudProfile else { return }
        profile.capture(nickname: nickname, avatar: avatarData, audio: profileAudio,
                        reviews: reviews, history: history, stats: stats, deviceID: profileDeviceID)
        var ledgers = profile.roomStatisticsByDevice ?? [:]
        ledgers[profileDeviceID] = roomStatistics
        profile.roomStatisticsByDevice = ledgers
        cloudProfile = profile
        if saveLocalProfile() { profileSyncStatus = "端末に保存済み・iCloud同期待ち" }
        scheduleProfileSync()
    }

    private var profileAudio: ProfileAudioSettings {
        .init(bgm: bgmVolume, effects: effectsVolume, song: songVolume)
    }

    private func saveLegacyProfileCache() {
        UserDefaults.standard.set(try? JSONEncoder().encode(reviews), forKey: "reviews")
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history")
        UserDefaults.standard.set(try? JSONEncoder().encode(stats), forKey: "stats")
    }

    @discardableResult private func saveLocalProfile() -> Bool {
        saveLegacyProfileCache()
        guard let cloudProfile else { return false }
        do {
            try CloudProfileCache.save(cloudProfile, owner: CloudProfileCache.owner)
            return true
        } catch {
            profileSyncStatus = "端末への保存に失敗しました: \(error.localizedDescription)"
            return false
        }
    }

    private var canSyncProfile: Bool {
        game == nil && room == nil && roomID == nil && !busy && gameStartHolds == 0
    }

    private func scheduleProfileSync() {
        guard !applyingProfile, profileCacheReadable, cloudProfile != nil else { return }
        if profileSyncing { profileSyncAgain = true; return }
        profileSaveTask?.cancel()
        profileSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            self.profileSaveTask = nil
            await self.syncProfile()
        }
    }

    func syncProfile() async {
        guard profileCacheReadable else { return }
        guard !profileSyncing else { profileSyncAgain = true; return }
        guard canSyncProfile else {
            profileSyncStatus = "端末に保存済み・操作終了後にiCloudへ同期します"
            return
        }
        profileSyncing = true
        profileSyncAgain = false
        let revision = profileAccountRevision
        defer {
            profileSyncing = false
            if profileSyncAgain { scheduleProfileSync() }
        }
        rooms.baseURL = serverURL
        var migrationPending = false
        do {
            let owner = try await cloudProfiles.accountID()
            guard revision == profileAccountRevision, canSyncProfile else { return }
            if let previousOwner = CloudProfileCache.owner, previousOwner != owner {
                let replacement = try CloudProfileCache.load(owner: owner) ?? CloudProfile()
                try applyProfile(replacement)
                cloudProfile = replacement
                friendsState = nil
                locallyInvitedFriendIDs = []
            }
            // Claim guest data only for the first account; later accounts get isolated caches.
            CloudProfileCache.owner = owner
            guard var local = cloudProfile else { return }
            if !local.importedLegacyProfiles.contains(rooms.profileID), !serverURL.isEmpty {
                let identity = rooms.profileID
                do {
                    if let saved = try await rooms.legacyProfileIfAvailable() {
                        local.importLegacy(reviews: saved.reviews, history: saved.history,
                                           stats: saved.stats, profileID: identity)
                    } else { local.importedLegacyProfiles.insert(identity) }
                } catch { migrationPending = true }
                guard revision == profileAccountRevision, canSyncProfile else { return }
                // Include edits made while the legacy request was in flight.
                if let current = cloudProfile { local = local.merging(current) }
            }
            local.serverCredentials = rooms.profileCredentialSnapshot
            cloudProfile = local
            try applyProfile(local)
            guard saveLocalProfile() else { return }
            profileSyncStatus = "iCloudに同期中…"
            let saved = try await cloudProfiles.synchronize(local, accountID: owner)
            guard revision == profileAccountRevision, canSyncProfile else { return }
            let merged = saved.merging(cloudProfile ?? local)
            let needsUpload = try merged.encoded() != saved.encoded()
            try applyProfile(merged)
            cloudProfile = merged
            guard saveLocalProfile() else { return }
            profileSyncAgain = profileSyncAgain || needsUpload
            profileSyncStatus = needsUpload ? "端末に保存済み・iCloud同期待ち" : "iCloudに保存済み"
            if migrationPending { profileSyncStatus = "iCloudに保存済み・旧サーバーの記録は次回取り込みます" }
        } catch is CancellationError {
            profileSyncStatus = "端末に保存済み・iCloud同期待ち"
        } catch {
            profileSyncStatus = CloudProfileService.status(for: error)
        }
        // Only the public-facing summary is copied to the room server for friend/profile screens.
        if revision == profileAccountRevision, canSyncProfile, !serverURL.isEmpty {
            do { try await rooms.publishProfile(name: nickname, avatar: roomAvatar, stats: stats) }
            catch { /* CloudKit success and offline play do not depend on the room server. */ }
        }
    }

    func cloudAccountChanged() {
        profileAccountRevision += 1
        profileSyncStatus = "iCloudアカウントを確認しています"
        scheduleProfileSync()
    }

    private func applyProfile(_ profile: CloudProfile) throws {
        guard profile.avatar.value == nil || (profile.avatar.value!.count <= PlayerAvatar.maximumBytes &&
            UIImage(data: profile.avatar.value!) != nil) else { throw CloudProfileError.invalidProfile }
        if avatarData != profile.avatar.value { try PlayerAvatar.store(profile.avatar.value) }
        applyingProfile = true
        defer { applyingProfile = false }
        nickname = profile.nickname.value
        avatarData = profile.avatar.value
        reviews = profile.reviews
        history = profile.history
        stats = profile.stats
        roomStatistics = profile.roomStatisticsByDevice?[profileDeviceID] ?? .init()
        bgmVolume = min(1, max(0, profile.audio.value.bgm))
        effectsVolume = min(1, max(0, profile.audio.value.effects))
        songVolume = min(1, max(0, profile.audio.value.song))
        rooms.restoreProfileIdentity(profile.serverProfileID, credentials: profile.serverCredentials)
    }

    private func pauseAudio() {
        let active = revealAudioTask ?? (roomID == nil ? soloRoundTask : scheduledRoomAudio)
        if appleMusicPlaying {
            let previous = appleMusicPauseTask
            appleMusicPauseTask = Task { [weak self] in
                await previous?.value
                await active?.value
                guard !Task.isCancelled else { return }
                self?.appleMusic.pause()
            }
        } else { player.pause() }
    }

    private func stopAudio() {
        revealAudioTask?.cancel(); revealAudioTask = nil
        revealReport = nil
        chorusReportDraft = nil
        chorusReportError = nil
        appleMusicPauseTask?.cancel(); appleMusicPauseTask = nil
        stopAudioPlayers()
    }

    private func stopAudioPlayers() {
        appleMusic.stop(); appleMusicPlaying = false
        player.stop()
    }

    private func revealAudio(_ song: Song) {
        revealAudioTask?.cancel()
        revealReport = nil
        chorusReportDraft = nil
        chorusReportError = nil
        revealAudioTask = Task { [weak self] in
            guard let self else { return }
            var playbackStartMS = 0
            do {
                try await RevealAudioPlayback.play(song, databaseChorus: {
                    await self.rooms.databaseChorus(song)
                }, chorus: {
                    if let cached = RevealAudioPlayback.validChorus(self.chorusPositions[song.id], durationMS: song.durationMS) {
                        return cached
                    }
                    return await self.chorusLookup(for: song).value
                }, preview: {
                    if song.id.hasPrefix("itunes:") { return song.previewURL }
                    if song.id.hasPrefix("applemusic:") {
                        if let preview = song.previewURL { return preview }
                        if let preview = await self.appleMusic.previewURL(for: song.id) { return preview }
                    }
                    guard !Task.isCancelled else { return nil }
                    return try? await self.rooms.matchItunes(song)?.previewURL
                }, playFullAudio: { position in
                    playbackStartMS = try await self.playRevealFullAudio(song, positionMS: position)
                }, playPreview: { preview in
                    self.appleMusic.stop()
                    self.appleMusicPlaying = false
                    try await self.player.prepare(preview)
                    try Task.checkCancellation()
                    guard self.isRevealing(song) else { throw CancellationError() }
                    try await self.player.startPreparedAndWait(preview)
                }, stopPlayback: { self.stopAudioPlayers() }, chorusSource: {
                    RevealPlaybackSource(rawValue: self.rooms.chorusSources[song.id] ?? "") ?? .songle
                }, didStartPlayback: { source, _ in
                    self.recordRevealPlayback(song, source: source,
                                              startPositionMS: source == .preview ? 0 : playbackStartMS)
                }, isCurrent: { self.isRevealing(song) })
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.isRevealing(song) else { return }
                self.stopAudioPlayers()
                if self.roomID != nil { self.roomError = error.localizedDescription }
                else if var game = self.game {
                    game.warning = error.localizedDescription
                    self.game = game
                }
            }
        }
    }

    private func playRevealFullAudio(_ song: Song, positionMS: Int?) async throws -> Int {
        try Task.checkCancellation()
        guard isRevealing(song) else { throw CancellationError() }
        let duration: TimeInterval
        if song.id.hasPrefix("applemusic:") {
            await appleMusicPauseTask?.value
            try Task.checkCancellation()
            player.stop()
            try await appleMusic.prepare(song.id)
            duration = appleMusic.duration
        } else {
            guard let url = song.previewURL else { throw AppError.message("この曲の音源がありません") }
            appleMusic.stop()
            appleMusicPlaying = false
            try await player.prepare(url)
            duration = player.duration
        }
        try Task.checkCancellation()
        guard isRevealing(song) else { throw CancellationError() }
        let durationMS = duration > 0 ? Int(min(duration * 1000, 86_400_000)) : song.durationMS
        if let positionMS, RevealAudioPlayback.validChorus(positionMS, durationMS: durationMS) == nil {
            throw AppError.message("サビ位置が音源の長さを超えています")
        }
        let offset = positionMS ?? RevealAudioPlayback.fallbackPosition(durationMS: durationMS)
        if song.id.hasPrefix("applemusic:") {
            appleMusicPlaying = true
            try await playAppleMusicWithRetry(song, offsetMS: offset)
        } else if let url = song.previewURL {
            try await player.startPreparedAndWait(url, offset: Double(offset) / 1000)
        }
        return offset
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

    private func withArtistTopTitles(_ songs: [Song], progress: ((Int, Int) -> Void)? = nil) async -> [Song] {
        let artists = Array(Set(songs.map(\.artist)))
        progress?(0, songs.count)
        let titles = await withTaskGroup(of: (String, [String]).self) { group in
            var next = 0
            var result: [String: [String]] = [:]
            func enqueue() {
                guard next < artists.count, !Task.isCancelled else { return }
                let artist = artists[next]
                next += 1
                group.addTask { [artistTopSongs] in
                    (artist, await artistTopSongs.titles(for: artist))
                }
            }
            for _ in 0..<min(6, artists.count) { enqueue() }
            for await (artist, titles) in group {
                result[artist] = titles
                progress?(songs.filter { result[$0.artist] != nil }.count, songs.count)
                enqueue()
            }
            return result
        }
        return songs.map { song in
            var enriched = song
            enriched.artistTopTitles = titles[song.artist] ?? []
            return enriched
        }
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

    var selectedRoomPlaylist: RoomPlaylist? {
        guard !selectedAppleMusicPlaylistID.isEmpty,
              let playlist = appleMusicPlaylists.first(where: { $0.id == selectedAppleMusicPlaylistID }) else { return nil }
        return RoomPlaylist(name: String(playlist.name.prefix(60)), songCount: appleMusicSongs.count)
    }

    var roomStartBlockReason: String? {
        guard let room else { return "ルームに参加してください" }
        if let reason = room.startBlockReason(localID: rooms.playerId, settings: roomSettings, playlist: selectedRoomPlaylist) {
            return reason
        }
        if room.mode == "applemusic", !appleMusicConnected || !appleMusicPlayable {
            return "Apple Music に接続し、サブスクリプションを確認してください"
        }
        return nil
    }

    /// Serialize lobby updates so a slower request cannot overwrite a newer selection.
    func scheduleRoomLobbySync() {
        guard let current = room, current.phase == "lobby", current.totalRounds == 0,
              current.hostId == rooms.playerId, current.supportsLobbyConfiguration == true else { return }
        roomLobbyRevision += 1
        guard roomLobbySyncTask == nil else { return }
        roomLobbySyncing = true
        let syncID = UUID()
        roomLobbySyncID = syncID
        roomLobbySyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.roomLobbySyncID == syncID {
                    self.roomLobbySyncTask = nil
                    self.roomLobbySyncing = false
                }
            }
            while !Task.isCancelled {
                let revision = self.roomLobbyRevision
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                if revision != self.roomLobbyRevision { continue }
                guard self.roomID == current.id, self.room?.phase == "lobby",
                      self.room?.gameNumber == current.gameNumber,
                      self.room?.hostId == self.rooms.playerId else { return }
                do {
                    let rules = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self.roomSettings))
                    let playlist: Any = try self.selectedRoomPlaylist.map {
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                    } ?? NSNull()
                    let state = try await self.rooms.action("lobby-config", id: current.id,
                        payload: ["settings": rules, "playlist": playlist])
                    guard !Task.isCancelled, self.roomID == current.id else { return }
                    self.receiveNetworkRoom(state)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.showRoomNotice("設定を共有できませんでした。接続を確認してください")
                }
                if revision == self.roomLobbyRevision { return }
            }
        }
    }

    func startRoom() async {
        guard let current = room, current.phase == "lobby", current.hostId == rooms.playerId,
              !busy, roomStartBlockReason == nil else { return }
        // Complete pending metadata updates before the room leaves the lobby.
        await roomLobbySyncTask?.value
        guard room?.id == current.id, room?.gameNumber == current.gameNumber,
              room?.phase == "lobby", room?.hostId == rooms.playerId,
              !busy, roomStartBlockReason == nil else { return }
        let selectedSettings = roomSettings
        let selectedPlaylistSongs = appleMusicSongs
        let selectedPlaylist = selectedRoomPlaylist
        // Each question has a song-matching step and a choices step, followed by the start request.
        let preparationSteps = Double(current.totalRounds == 0 && current.mode != "shared"
            ? selectedSettings.questionCount * 2 + 1 : 1)
        roomStartProgress = 0
        preparationStatus = "ゲームの準備を開始しています"
        busy = true
        defer { busy = false; preparationStatus = nil; roomStartProgress = nil }
        do {
            // Restored rooms already have their questions. Starting them must not
            // resolve the playlist again or depend on its current selection.
            if current.totalRounds > 0 {
                preparationStatus = "ゲームを開始中"
                let started = try await rooms.action("start", id: current.id)
                roomStartProgress = 1
                receiveNetworkRoom(started)
                return
            }
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
                if let prepared = preparedRoomSongs, prepared.roomID == current.id,
                   prepared.gameNumber == current.gameNumber, prepared.source == selectedPlaylistSongs,
                   prepared.count == selectedSettings.questionCount, prepared.playedIDs == played {
                    songs = prepared.songs
                } else {
                    songs = try await playlistPreparation.songs(from: selectedPlaylistSongs.shuffled(),
                        count: selectedSettings.questionCount, playedIDs: played,
                        namespace: current.mode == "applemusic" ? "applemusic" : "itunes:\(serverURL)",
                        requiresPreview: current.mode != "applemusic", cacheMisses: current.mode != "applemusic",
                        progress: { [weak self] ready, total in
                            self?.preparationStatus = "出題曲を準備中 \(ready) / \(total)"
                            self?.roomStartProgress = Double(ready) / preparationSteps
                        }, resolve: { [appleMusic, rooms] candidate in
                            if current.mode == "applemusic" {
                                return await appleMusic.catalogSongs(for: [candidate]).first
                            }
                            return try await rooms.matchItunes(candidate)
                        })
                    guard songs.count >= selectedSettings.questionCount else {
                        throw AppError.message("指定された問題数分の曲を用意できません（照合可能: \(songs.count)曲）")
                    }
                    preparationStatus = "選択肢を準備中"
                    songs = await withArtistTopTitles(songs) { [weak self] ready, total in
                        self?.preparationStatus = "選択肢を準備中 \(ready) / \(total)"
                        self?.roomStartProgress = Double(selectedSettings.questionCount + ready) / preparationSteps
                    }
                    try Task.checkCancellation()
                    preparedRoomSongs = PreparedRoomSongs(roomID: current.id, gameNumber: current.gameNumber,
                        source: selectedPlaylistSongs, count: selectedSettings.questionCount,
                        playedIDs: played, songs: songs)
                }
                corpus = selectedPlaylistSongs.map(\.title)
            }
            let songData = try JSONEncoder().encode(songs)
            let songList = try JSONSerialization.jsonObject(with: songData)
            let settingsData = try JSONEncoder().encode(selectedSettings)
            let rules = try JSONSerialization.jsonObject(with: settingsData)
            try Task.checkCancellation()
            guard room?.id == current.id, room?.phase == "lobby", room?.gameNumber == current.gameNumber,
                  room?.hostId == rooms.playerId else { return }
            if let reason = roomStartBlockReason { throw AppError.message(reason) }
            preparationStatus = "ゲームを開始中"
            roomStartProgress = (preparationSteps - 1) / preparationSteps
            let started = try await rooms.action("start", id: current.id,
                payload: ["settings": rules, "songs": songList, "corpus": corpus,
                          "playlist": try selectedPlaylist.map {
                              try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                          } ?? NSNull()])
            roomStartProgress = 1
            receiveNetworkRoom(started)
            preparedRoomSongs = nil
        } catch is CancellationError { }
        catch {
            guard room?.id == current.id, room?.gameNumber == current.gameNumber,
                  room?.phase == "lobby", !Task.isCancelled else { return }
            showRoomNotice(RoomService.isConnectionError(error)
                ? "ゲームの開始を確認できません。接続を確認して再試行してください"
                : error.localizedDescription)
        }
    }

    @discardableResult
    func joinRoom(_ code: String, reportErrors: Bool = true) async -> String? {
        guard !busy else { return "処理中です。少し待ってから再試行してください" }
        guard let normalized = RoomCode.pastedCode(in: code) else {
            let message = "ルームコードは英字6文字で入力してください"
            if reportErrors { alert = message }
            return message
        }
        busy = true; defer { busy = false }
        rooms.baseURL = serverURL
        do {
            let state = try await rooms.join(normalized, name: nickname,
                                             badge: stats.selectedBadge, avatar: roomAvatar)
            if state.mode == "applemusic" {
                guard appleMusicConnected, try await appleMusic.canPlay() else {
                    _ = try? await rooms.action("leave", id: state.id)
                    throw AppError.message("このルームには Apple Music の接続とサブスクリプションが必要です")
                }
            }
            enterRoom(state)
            return nil
        } catch {
            if reportErrors { alert = error.localizedDescription }
            return error.localizedDescription
        }
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
        guard let id = roomID, room?.acceptsNewPlayers == true,
              (room?.players.count ?? 4) < 4, !friendsLoading,
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
                guard !Task.isCancelled, self.roomID == roomID else { return }
                if RoomService.isExpiredSession(error) {
                    clearLocalRoom()
                    return
                }
                roomError = "ルームへの再接続を試しています…"
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func enterRoom(_ state: RoomState) {
        leavingRoomID = nil
        roomRoundPreparation.cancel()
        roomAudioRevision += 1
        lastRoomPhase = nil
        lastRoomRound = nil
        preparedRoomRound = nil
        roomAudioStarted = false
        roomAudioStarting = false
        scheduledRoomAudio?.cancel()
        scheduledRoomAudio = nil
        preparedRoomSongs = nil
        locallyInvitedFriendIDs.removeAll()
        if state.phase == "lobby", state.hostId == rooms.playerId { roomSettings = state.settings }
        roomID = state.id
        UserDefaults.standard.set(state.id, forKey: "roomID")
        room = state
        roomError = nil
        roomNoticeTask?.cancel(); roomNoticeTask = nil
        roomNotice = nil
        roomPushPending = false
        roomPendingPushTimeMS = nil
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
                } catch {
                    guard !Task.isCancelled, self.roomID == id else { break }
                    if RoomService.isExpiredSession(error) {
                        self.clearLocalRoom()
                        break
                    }
                    self.roomError = "接続を確認しています…"
                }
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(streamSupported ? retrySeconds : 2))
                if streamSupported { retrySeconds = min(retrySeconds * 2, 8) }
            }
        }
        receiveRoom(state)
    }

    private func receiveNetworkRoom(_ state: RoomState) {
        guard !Task.isCancelled, roomID == state.id, leavingRoomID != state.id else { return }
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
        if old?.id != state.id || old?.gameNumber != state.gameNumber || old?.round != state.round {
            roomPendingPushTimeMS = nil
        }
        if let old, old.id == state.id, old.gameNumber == state.gameNumber, old.round == state.round,
           let pending = pendingRoomChoice {
            let result = state.player(rooms.playerId)?.currentResult
            let previousResult = old.player(rooms.playerId)?.currentResult
            let advanced = state.answerProgress.count > old.answerProgress.count
            if advanced || result != previousResult && (result == "correct" || result == "wrong") {
                pendingRoomChoice = nil
                roomChoiceFeedback = ChoiceFeedback(choice: pending.choice,
                    correct: advanced || result == "correct", choices: pending.choices, answerBeforeChoice: pending.answer)
                roomChoiceFeedbackTask?.cancel()
                roomChoiceFeedbackTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    self?.roomChoiceFeedback = nil
                }
            }
        }
        if state.phase == "lobby",
           state.hostId == rooms.playerId,
           (old?.gameNumber != state.gameNumber || old?.hostId != state.hostId) {
            roomSettings = state.settings
        }
        if old?.id == state.id, old?.gameNumber != state.gameNumber {
            roomRoundPreparation.cancel()
            lastRoomRound = nil
            lastRoomPhase = nil
            preparedRoomSongs = nil
            preloadedRoomID = nil
            preparedRoomRound = nil
            roomPreloadTask?.cancel()
            roomPreparationStatus = nil
            roomError = nil
        }
        if state.phase == "countdown" &&
            (old?.id != state.id || old?.round != state.round || old?.phase != "countdown") {
            if old?.id == state.id, old?.gameNumber == state.gameNumber,
               old?.round == state.round, old?.phase == "preparing" { roomError = nil }
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
                    guard !Task.isCancelled, self.room?.id == state.id,
                          self.room?.gameNumber == state.gameNumber, self.room?.phase == "lobby" else { return }
                    self.roomPreparationStatus = nil
                    self.roomError = RoomService.isConnectionError(error)
                        ? "画像と音源の準備中に通信が途切れました。接続を確認して再試行してください"
                        : error.localizedDescription
                }
            }
        }
        let gameKey = "\(state.id):\(state.gameNumber ?? 0)"
        let disclosed = state.phase == "reveal" || state.phase == "finished"
        let event = RoomStatsEvent(gameID: "\(serverURL):\(gameKey):\(rooms.playerId)", round: state.round,
            pushed: state.pushedIds.contains(rooms.playerId), pushTimeMS: state.player(rooms.playerId)?.pushTimeMS,
            result: disclosed ? (state.correctPlayerIDs.contains(rooms.playerId) ? "correct" : "wrong") : nil,
            genre: state.current?.genre, finished: state.phase == "finished",
            previouslyFinished: (UserDefaults.standard.stringArray(forKey: "finishedRoomIDs") ?? []).contains(gameKey))
        if roomStatistics.record(event, stats: &stats) { persist() }
        roomOptions = state.options
        roomAnswer = state.answerProgress
        roomSecondsLeft = remainingTime(state)
        if state.round != lastRoomRound {
            roomRoundPreparation.cancel()
            preparedRoomRound = nil
            roomAudioRevision += 1
            stopAudio()
            roomAudioStarted = false
            roomAudioStarting = false
            scheduledRoomAudio?.cancel()
            scheduledRoomAudio = nil
            lastRoomRound = state.round
            lastRoomPhase = nil
        }
        if state.phase == "preparing" && preparedRoomRound != state.round {
            preparedRoomRound = state.round
            roomRoundPreparation.start { [weak self] in
                guard let self else { return }
                do {
                    if state.mode == "applemusic", let id = state.current?.id {
                        try await self.appleMusic.prepare(id)
                    } else if let url = state.current?.previewURL {
                        try await self.player.prepare(url)
                    }
                    try Task.checkCancellation()
                    guard self.matchesRoomRound(state), self.room?.phase == "preparing" else { return }
                    let ready = try await self.rooms.action("ready", id: state.id)
                    try Task.checkCancellation()
                    guard self.matchesRoomRound(state) else { return }
                    self.receiveNetworkRoom(ready)
                } catch {
                    guard !Task.isCancelled, self.room?.id == state.id,
                          self.room?.gameNumber == state.gameNumber, self.room?.round == state.round,
                          self.room?.phase == "preparing" else { return }
                    self.roomError = RoomService.isConnectionError(error)
                        ? "音源の準備中に通信が途切れました。接続を確認して再試行してください"
                        : error.localizedDescription
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
            scheduledRoomAudio?.cancel()
            scheduledRoomAudio = Task { [weak self] in await self?.startRoomAudio(state) }
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
        let revision = roomAudioRevision
        while roomAudioStarting {
            guard !Task.isCancelled, matchesRoomRound(state), roomAudioRevision == revision else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, matchesRoomRound(state), roomAudioRevision == revision,
              let playbackState = room,
              ["countdown", "listening", "answering"].contains(playbackState.phase),
              playbackState.pausedAt == nil, !playbackState.questionAudioClosed,
              !playbackState.isAnswering(rooms.playerId),
              let current = playbackState.current else { return }
        roomAudioStarting = true
        defer { if roomAudioRevision == revision { roomAudioStarting = false } }
        func playbackOffset() throws -> Int {
            try Task.checkCancellation()
            guard matchesRoomRound(state), roomAudioRevision == revision,
                  let offset = room?.questionPlaybackOffsetMS(for: rooms.playerId, nowMS: rooms.serverNowMS) else {
                throw CancellationError()
            }
            return offset
        }
        do {
            if playbackState.mode == "applemusic" {
                try await startPreparedRoundAudio(Song(id: current.id, title: "", artist: "", artworkURL: nil,
                    previewURL: nil, trackURL: nil, durationMS: 180_000, genre: "その他"), offsetProvider: playbackOffset)
            } else if let preview = current.previewURL {
                do { try player.startPrepared(preview, offset: Double(try playbackOffset()) / 1000) }
                catch {
                    if error is CancellationError { throw error }
                    try await player.prepare(preview)
                    try player.startPrepared(preview, offset: Double(try playbackOffset()) / 1000)
                }
            } else { throw AppError.message("この曲の音源がありません") }
            guard !Task.isCancelled, matchesRoomRound(state), roomAudioRevision == revision else { return }
            roomAudioStarted = true
            roomError = nil
            if room?.pausedAt != nil || room?.questionAudioClosed == true || room?.isAnswering(rooms.playerId) == true { pauseAudio() }
            if room?.phase == "reveal" || room?.phase == "finished" { stopAudio() }
        } catch {
            if error is CancellationError { return }
            guard matchesRoomRound(state), roomAudioRevision == revision, !Task.isCancelled else { return }
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
        let nowMS = rooms.serverNowMS
        guard let roomID, let room, !roomPushPending,
              room.canPush(rooms.playerId, nowMS: nowMS) else { return }
        roomPendingPushTimeMS = max(0, min(30_000, nowMS - (room.startAt ?? nowMS)))
        roomPushPending = true
        Task { [weak self] in
            guard let self, self.roomID == roomID else { return }
            await self.roomAction("push")
        }
        sound.play(.push)
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
            guard !roomChoicePending, roomChoiceFeedback == nil,
                  room?.isAnswering(rooms.playerId) == true,
                  let choice = payload["choice"] as? String, roomOptions.contains(choice) else { return }
            roomChoicePending = true
            pendingRoomChoice = (choice, roomOptions, roomAnswer)
        }
        let previousAnswer = roomAnswer
        let previousRound = room?.round
        defer {
            if action == "push", self.roomID == roomID {
                roomPushPending = false
                roomPendingPushTimeMS = nil
            }
            if action == "choose", self.roomID == roomID {
                roomChoicePending = false
                pendingRoomChoice = nil
            }
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
        roomRoundPreparation.cancel()
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

    var canStartSolo: Bool {
        GameSessionAvailability.canStartSolo(gameActive: game != nil, roomActive: room != nil, roomID: roomID)
    }

    private func matchesRoomRound(_ state: RoomState) -> Bool {
        roomID == state.id && leavingRoomID != state.id &&
            room?.gameNumber == state.gameNumber && room?.round == state.round
    }

    private func cancelRoomWork() {
        roomChoiceFeedbackTask?.cancel(); roomChoiceFeedbackTask = nil
        roomChoiceFeedback = nil; pendingRoomChoice = nil
        roomLobbySyncTask?.cancel(); roomLobbySyncTask = nil
        roomLobbySyncID = UUID()
        roomLobbySyncing = false
        roomRoundPreparation.cancel()
        roomAudioRevision += 1
        preparedRoomSongs = nil
        roomNoticeTask?.cancel(); roomNoticeTask = nil
        roomNotice = nil; roomPushPending = false
        roomPendingPushTimeMS = nil
        roomChoicePending = false
        roomPreloadTask?.cancel(); roomPreloadTask = nil
        preloadedRoomID = nil; roomPreparationStatus = nil
        roomSyncTask?.cancel(); roomSyncTask = nil
        roomTicker?.cancel(); roomTicker = nil
        scheduledRoomAudio?.cancel()
        stopAudio()
        scheduledRoomAudio = nil
        roomAudioStarting = false
    }

    private func clearLocalRoom() {
        cancelRoomWork()
        room = nil; roomID = nil; rooms.clear()
        leavingRoomID = nil
        locallyInvitedFriendIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: "roomID")
        lastRoomPhase = nil; lastRoomRound = nil; preparedRoomRound = nil; roomAudioStarted = false; roomAudioStarting = false
        roomError = nil
        scheduleProfileSync()
    }

    func leaveRoom() async {
        guard let departingRoomID = roomID, leavingRoomID != departingRoomID else { return }
        leavingRoomID = departingRoomID
        cancelRoomWork()
        _ = try? await rooms.action("leave", id: departingRoomID)
        guard roomID == departingRoomID else { return }
        clearLocalRoom()
    }
}
