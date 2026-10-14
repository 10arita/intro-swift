import Foundation

struct RoomSettings: Codable, Equatable {
    var questionCount = 6
    var answerSlots = 2
    var targetScore = 50
    var correctPoints = 10
    var firstBonus = 10
    var wrongPenalty = 10
    var firstWrongPenalty = 10
    var lives = 3
    var endless = false
    var handicaps: [String: Int]? = nil

    func handicapSeconds(for playerID: String) -> Int { handicaps?[playerID] ?? 0 }
}

struct RoomPlaylist: Codable, Equatable {
    let name: String
    let songCount: Int
}

struct RoomPlayer: Decodable, Identifiable {
    let id: String
    let name: String
    let score: Int
    let correctCount: Int?
    let wrongCount: Int?
    let roundResults: [String?]?
    let currentResult: String?
    let pushTimeMS: Double?
    let lives: Int
    let disqualified: Bool
    let connected: Bool
    let isHost: Bool
    let badge: String?
    let avatar: String?
    let friendStatus: String?
    let friendProfileId: String?
}

struct FriendEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let avatar: String?
    let highestRankLevel: Int?
}

struct FriendRequest: Decodable, Identifiable {
    let id: String
    let fromId: String
    let fromName: String
    let roomId: String
    let createdAt: Double
}

struct RoomInvite: Decodable, Identifiable {
    let id: String
    let fromId: String
    let fromName: String
    let roomId: String
    let mode: String
    let playerCount: Int?
    let createdAt: Double
}

struct SentRoomInvite: Decodable {
    let roomId: String
    let targetId: String
}

struct FriendsState: Decodable {
    let friends: [FriendEntry]
    let requests: [FriendRequest]
    let invites: [RoomInvite]
    let sentInvites: [SentRoomInvite]?
}

struct PlayerProfile: Decodable {
    struct Stats: Decodable {
        let games: Int?
        let attempts: Int?
        let correct: Int?
        let averagePush: Double?
        let selectedBadge: String?
        let badges: [String]?
    }

    let name: String
    let avatar: String?
    let badge: String?
    let stats: Stats?
    let highestRankLevel: Int?
    let roomScore: Int?
    let roomCorrect: Int?
    let roomWrong: Int?
}

struct RoomCurrent: Decodable {
    let id: String
    let previewURL: URL?
    let title: String?
    let artist: String?
    let artworkURL: URL?
    let trackURL: URL?
    let durationMS: Int?
    let genre: String?
    let songleURL: URL?
    let chorusMS: Double?
    let chorusSource: String?

    var song: Song? {
        guard let title, let artist else { return nil }
        let chorusPosition = chorusMS.flatMap { value -> Int? in
            guard value.isFinite, value >= 0 else { return nil }
            let maximum = min(Double(max(0, durationMS ?? 180_000)), 86_400_000)
            guard value.rounded() < maximum else { return nil }
            return Int(value.rounded())
        }
        return Song(id: id, title: title, artist: artist, artworkURL: artworkURL, previewURL: previewURL,
                    trackURL: trackURL,
                    durationMS: durationMS ?? 180_000, genre: genre ?? "その他", songleURL: songleURL,
                    chorusMS: chorusPosition, chorusSource: chorusSource)
    }
}

struct RoomActiveAnswer: Decodable, Identifiable {
    let playerId: String
    let progress: String
    var id: String { playerId }
}

struct RoomState: Decodable, Identifiable {
    let id: String
    let sequence: Int?
    let gameNumber: Int?
    let mode: String
    let hostId: String
    let phase: String
    let round: Int
    let totalRounds: Int
    let settings: RoomSettings
    let players: [RoomPlayer]
    let serverNow: Double
    let startAt: Double?
    let roundDeadline: Double?
    let pausedAt: Double?
    let pausedPositionMS: Double?
    let pushClosed: Bool
    let audioStoppedAt: Double?
    let answerDeadline: Double?
    let answerProgress: String
    let answerStatus: String?
    let options: [String]
    let activeAnswers: [RoomActiveAnswer]
    let pushedIds: [String]
    let pushOrderIds: [String]?
    let skippedIds: [String]
    let readyIds: [String]
    let assetsReadyIds: [String]?
    let preload: [GameAsset]?
    let playedSongIDs: [String]?
    let correctPlayerID: String?
    let correctPlayerIDs: [String]
    let current: RoomCurrent?
    let sessionToken: String?
    let supportsChoiceRetry: Bool?
    var supportsLobbyConfiguration: Bool? = nil
    var playlist: RoomPlaylist? = nil
    var roundSongs: [RoomCurrent]? = nil

    var questionAudioClosed: Bool { !settings.endless && (pushClosed || audioStoppedAt != nil) }
    var acceptsNewPlayers: Bool {
        ["lobby", "preparing", "countdown", "listening", "answering", "reveal"].contains(phase)
    }

    /// The lobby and start action share the same eligibility rules.
    func startBlockReason(localID: String, settings: RoomSettings, playlist: RoomPlaylist?) -> String? {
        guard phase == "lobby", hostId == localID else { return "ホストがゲームを開始します" }
        guard players.count >= 2 else { return "あと \(2 - players.count) 人で開始できます" }
        if totalRounds > 0 {
            if let assetsReadyIds, players.contains(where: { !assetsReadyIds.contains($0.id) }) {
                return "全員の音源の準備が終わるまでお待ちください"
            }
            return nil
        }
        guard mode != "shared" else { return nil }
        guard let playlist else { return "プレイリストを選んでください" }
        guard playlist.songCount >= settings.questionCount else {
            return "\(playlist.songCount)曲では\(settings.questionCount)問を出題できません。曲を増やすか問題数を減らしてください"
        }
        return nil
    }

    func exitExplanation(localID: String) -> String {
        let message: String
        switch phase {
        case "lobby": message = "この待機室から抜けます。"
        case "finished": message = "対戦結果の表示を終了し、ルームから抜けます。"
        default: message = "進行中のゲームから抜けます。今回の最終順位には表示されません。"
        }
        if players.count == 1 { return message + "\nあなたが退室するとルームは閉じられます。" }
        if hostId == localID { return message + "\nホストは残った参加者に自動で引き継がれます。" }
        return message
    }

    /// Read immediately before playback, after any loading, using the latest room clock.
    func questionPlaybackOffsetMS(for id: String, nowMS: Double) -> Int? {
        guard ["countdown", "listening", "answering"].contains(phase),
              pausedAt == nil, !questionAudioClosed, !isAnswering(id),
              current != nil, let startAt, nowMS.isFinite, startAt.isFinite,
              nowMS < (roundDeadline ?? startAt + 30_000) else { return nil }
        return Int(min(30_000, max(0, nowMS - startAt)))
    }

    func player(_ id: String) -> RoomPlayer? { players.first { $0.id == id } }

    var rankedPlayers: [RoomPlayer] {
        players.sorted {
            if $0.disqualified != $1.disqualified { return !$0.disqualified }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.lives != $1.lives { return $0.lives > $1.lives }
            return $0.id < $1.id
        }
    }

    /// Switch to the server's PUSH order for this round; keep unpushed players in score order.
    func statusPlayers(pendingPushPlayerID: String? = nil) -> [RoomPlayer] {
        let ranked = rankedPlayers
        guard phase != "finished" else { return ranked }
        var pushOrder = pushOrderIds ?? pushedIds
        if let pendingPushPlayerID, !pushOrder.contains(pendingPushPlayerID) {
            pushOrder.append(pendingPushPlayerID)
        }
        return ranked.enumerated().sorted { left, right in
            let leftPush = pushOrder.firstIndex(of: left.element.id)
            let rightPush = pushOrder.firstIndex(of: right.element.id)
            switch (leftPush, rightPush) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
    }

    func isAnswering(_ id: String) -> Bool { activeAnswers.contains { $0.playerId == id } }
    func handicapSecondsLeft(for id: String, nowMS: Double) -> Double {
        guard let startAt else { return 0 }
        return max(0, (startAt + Double(settings.handicapSeconds(for: id)) * 1000 - nowMS) / 1000)
    }
    func canPush(_ id: String, nowMS: Double) -> Bool {
        guard ["listening", "answering"].contains(phase), player(id)?.disqualified == false,
              !pushedIds.contains(id), handicapSecondsLeft(for: id, nowMS: nowMS) == 0 else { return false }
        return settings.endless ? activeAnswers.isEmpty : !pushClosed
    }
}

private struct RoomCatalog: Decodable { let songs: [Song] }
private struct CorpusResponse: Decodable { let titles: [String] }
private struct ChorusResponse: Decodable {
    let positionMS: Int?
    let source: String?
    let databaseConfigured: Bool?
}
private struct RoomFailure: Decodable { let error: String; let state: RoomState? }
private struct RoomSocketMessage: Decodable {
    let type: String
    let id: String?
    let state: RoomState?
    let status: Int?
    let error: String?
}
private struct PendingRoomAction {
    let continuation: CheckedContinuation<RoomState, Error>
    let sentAt: Double
}
enum RoomStreamError: Error { case unsupported }
struct RoomHTTPError: LocalizedError {
    let status: Int
    let message: String
    let state: RoomState?
    var errorDescription: String? { message }
}
struct SavedProfile: Decodable {
    let reviews: [ReviewSong]
    let history: [SoloResult]
    let stats: PlayerStats?
    let token: String?
}

@MainActor final class RoomService {
    var baseURL = ""
    private let session: URLSession
    private let databaseChorusLookup: ((Song) async -> Int?)?
    private(set) var chorusSources: [String: String] = [:]
    private var latestRoomState: RoomState?
    private(set) var serverClockOffsetMS = 0.0
    private var bestClockRTTMS = Double.infinity
    private var clockSampleAt = Date.distantPast
    var serverNowMS: Double { Date.now.timeIntervalSince1970 * 1000 + serverClockOffsetMS }
    func localDate(for serverTimeMS: Double) -> Date {
        Date(timeIntervalSince1970: (serverTimeMS - serverClockOffsetMS) / 1000)
    }
    let playerId: String
    var profileID: String
    var onProfileCredentialsChange: (() -> Void)?
    private(set) var token: String?
    private var roomSocket: URLSessionWebSocketTask?
    private var socketRoomID: String?
    private var socketReady = false
    private var supportsChoiceRetry = false
    private var pendingSocketActions: [String: PendingRoomAction] = [:]

    private func disconnectSocket() {
        roomSocket?.cancel(with: .goingAway, reason: nil)
        roomSocket = nil
        socketRoomID = nil
        socketReady = false
        let waiting = Array(pendingSocketActions.values)
        pendingSocketActions.removeAll()
        for pending in waiting { pending.continuation.resume(throwing: URLError(.networkConnectionLost)) }
    }

    init(session: URLSession = .shared, databaseChorusLookup: ((Song) async -> Int?)? = nil) {
        self.session = session
        self.databaseChorusLookup = databaseChorusLookup
        if let saved = UserDefaults.standard.string(forKey: "roomPlayerId") { playerId = saved }
        else { playerId = UUID().uuidString; UserDefaults.standard.set(playerId, forKey: "roomPlayerId") }
        // Keep the existing profile and friend graph when upgrading from account-based identity.
        profileID = UserDefaults.standard.string(forKey: "profileID") ??
            UserDefaults.standard.string(forKey: "spotifyAccountID").map { "spotify:\($0)" } ?? playerId
        UserDefaults.standard.set(profileID, forKey: "profileID")
        token = Secrets.get("roomSessionToken") ?? UserDefaults.standard.string(forKey: "roomSessionToken")
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme == "https" || (base.scheme == "http" && ["localhost", "127.0.0.1"].contains(base.host ?? "")) else {
            throw AppError.message("対戦サーバーは現在利用できません")
        }
        return base.appending(path: path)
    }

    private func sampleClock(_ state: RoomState, sentAt: Double, receivedAt: Double) {
        remember(state)
        supportsChoiceRetry = state.supportsChoiceRetry == true
        let roundTrip = receivedAt - sentAt
        if roundTrip < bestClockRTTMS || Date.now.timeIntervalSince(clockSampleAt) > 30 {
            serverClockOffsetMS = state.serverNow - (sentAt + receivedAt) / 2
            bestClockRTTMS = roundTrip
            clockSampleAt = .now
        }
    }

    private func remember(_ state: RoomState) {
        if let current = latestRoomState, current.id == state.id {
            if state.serverNow < current.serverNow { return }
            if state.serverNow == current.serverNow,
               let sequence = state.sequence, let currentSequence = current.sequence,
               sequence <= currentSequence { return }
        }
        latestRoomState = state
    }

    private func request(_ path: String, method: String = "GET", payload: [String: Any] = [:], authentication: String? = nil) async throws -> RoomState {
        var url = try endpoint(path)
        if method == "GET" { url.append(queryItems: [URLQueryItem(name: "playerId", value: playerId)]) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = path.hasSuffix("/choose") ? 2.5 : 10
        if let authentication = authentication ?? token { request.setValue("Bearer \(authentication)", forHTTPHeaderField: "Authorization") }
        if method != "GET" {
            var body = payload
            body["playerId"] = playerId
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sentAt = Date.now.timeIntervalSince1970 * 1000
        let (data, response) = try await session.data(for: request)
        let receivedAt = Date.now.timeIntervalSince1970 * 1000
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            let failure = try? JSONDecoder().decode(RoomFailure.self, from: data)
            throw RoomHTTPError(status: status, message: failure?.error ?? "ルームに接続できません (\(status))",
                                state: failure?.state)
        }
        let state = try JSONDecoder().decode(RoomState.self, from: data)
        sampleClock(state, sentAt: sentAt, receivedAt: receivedAt)
        if let sessionToken = state.sessionToken {
            token = sessionToken
            Secrets.set(sessionToken, for: "roomSessionToken")
            UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        }
        return state
    }

    func create(name: String, settings: RoomSettings, mode: String = "shared", songs: [Song] = [], corpus: [String] = [], badge: String? = nil, avatar: String? = nil, deferQuestions: Bool = false) async throws -> RoomState {
        let identity = try? await profileCredentials()
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        let settingsData = try JSONEncoder().encode(settings)
        let rule = try JSONSerialization.jsonObject(with: settingsData)
        let songData = try JSONEncoder().encode(songs)
        let songList = try JSONSerialization.jsonObject(with: songData)
        return try await request("rooms", method: "POST", payload: ["name": name, "badge": badge ?? "", "avatar": avatar ?? "", "profileId": profileID, "profileToken": identity ?? "", "settings": rule,
                                                                  "mode": mode, "songs": songList, "corpus": corpus, "deferQuestions": deferQuestions,
                                                                  "minimumPlayers": 2])
    }

    func join(_ id: String, name: String, badge: String? = nil, avatar: String? = nil) async throws -> RoomState {
        let identity = try? await profileCredentials()
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        return try await request("rooms/\(id.uppercased())/join", method: "POST", payload: ["name": name, "badge": badge ?? "", "avatar": avatar ?? "", "profileId": profileID, "profileToken": identity ?? ""])
    }

    func state(_ id: String) async throws -> RoomState { try await request("rooms/\(id)") }

    func watchSocket(_ id: String, onState: (RoomState) -> Void) async throws {
        disconnectSocket()
        var components = URLComponents(url: try endpoint("rooms/\(id)/socket"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "playerId", value: playerId)]
        guard let url = components.url else { throw AppError.message("対戦サーバーに接続できません") }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = session.webSocketTask(with: request)
        let sentAt = Date.now.timeIntervalSince1970 * 1000
        roomSocket = task
        socketRoomID = id
        socketReady = false
        task.resume()
        let openingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.roomSocket === task, self?.socketReady == false else { return }
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            openingTimeout.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if roomSocket === task { disconnectSocket() }
        }
        try await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                let envelope = try JSONDecoder().decode(RoomSocketMessage.self, from: data)
                if envelope.type == "state", let state = envelope.state {
                    remember(state)
                    if !socketReady {
                        sampleClock(state, sentAt: sentAt, receivedAt: Date.now.timeIntervalSince1970 * 1000)
                        socketReady = true
                        openingTimeout.cancel()
                    }
                    onState(state)
                } else if let messageID = envelope.id, let pending = pendingSocketActions.removeValue(forKey: messageID) {
                    if envelope.type == "result", let state = envelope.state {
                        sampleClock(state, sentAt: pending.sentAt,
                                    receivedAt: Date.now.timeIntervalSince1970 * 1000)
                        pending.continuation.resume(returning: state)
                    } else {
                        pending.continuation.resume(throwing: RoomHTTPError(
                            status: envelope.status ?? 0,
                            message: envelope.error ?? "操作に失敗しました", state: envelope.state))
                    }
                }
            }
            throw CancellationError()
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    private func socketAction(_ action: String, payload: [String: Any], task: URLSessionWebSocketTask) async throws -> RoomState {
        let messageID = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: ["type": "action", "id": messageID,
                                                               "action": action, "payload": payload])
        let message = String(decoding: body, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pendingSocketActions[messageID] = PendingRoomAction(
                continuation: continuation, sentAt: Date.now.timeIntervalSince1970 * 1000)
            Task { [weak self] in
                do { try await task.send(.string(message)) }
                catch {
                    self?.pendingSocketActions.removeValue(forKey: messageID)?.continuation.resume(throwing: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(action == "choose" ? 2 : 10))
                guard !Task.isCancelled else { return }
                if let pending = self?.pendingSocketActions.removeValue(forKey: messageID) {
                    pending.continuation.resume(throwing: URLError(.timedOut))
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
        }
    }

    func watch(_ id: String, onState: (RoomState) -> Void) async throws {
        var url = try endpoint("rooms/\(id)/events")
        url.append(queryItems: [URLQueryItem(name: "playerId", value: playerId)])
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let sentAt = Date.now.timeIntervalSince1970 * 1000
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw RoomStreamError.unsupported }
        guard status == 200 else { throw AppError.message("ルームに接続できません (\(status))") }
        var firstState = true
        // The SSE heartbeat wakes this loop so a recovered WebSocket can be retried.
        let socketRetryAt = Date.now.addingTimeInterval(60)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if Date.now >= socketRetryAt { return }
            guard line.hasPrefix("data: ") else { continue }
            let data = Data(line.dropFirst(6).utf8)
            let state = try JSONDecoder().decode(RoomState.self, from: data)
            remember(state)
            if firstState {
                sampleClock(state, sentAt: sentAt, receivedAt: Date.now.timeIntervalSince1970 * 1000)
                firstState = false
            }
            onState(state)
        }
        throw URLError(.networkConnectionLost)
    }

    func catalog() async throws -> [Song] {
        let (data, response) = try await URLSession.shared.data(from: endpoint("catalog"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("音源カタログを読み込めません") }
        return try JSONDecoder().decode(RoomCatalog.self, from: data).songs
    }
    func topSongs() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: endpoint("itunes/top"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode(CorpusResponse.self, from: data).titles
    }
    func databaseChorus(_ song: Song) async -> Int? {
        guard !song.id.hasPrefix("itunes:"), !Task.isCancelled else { return nil }
        chorusSources[song.id] = nil
        if let url = try? endpoint("chorus/database") {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(song)
            if let (data, response) = try? await session.data(for: request), !Task.isCancelled,
               (response as? HTTPURLResponse)?.statusCode == 200,
               let result = try? JSONDecoder().decode(ChorusResponse.self, from: data),
               result.databaseConfigured == true {
                chorusSources[song.id] = nil
                guard let position = result.positionMS, position >= 0,
                      song.durationMS <= 0 || position < song.durationMS,
                      ["manual_database", "songle_database", "songle"].contains(result.source ?? "") else { return nil }
                // Older servers label stored Songle positions as "songle" even on the DB-only endpoint.
                chorusSources[song.id] = result.source == "songle" ? "songle_database" : result.source
                return position
            }
        }
        guard !Task.isCancelled, let databaseChorusLookup,
              let position = await databaseChorusLookup(song), !Task.isCancelled,
              position >= 0, song.durationMS <= 0 || position < song.durationMS else { return nil }
        chorusSources[song.id] = "manual_database"
        return position
    }

    func action(_ action: String, id: String, payload: [String: Any] = [:]) async throws -> RoomState {
        var payload = payload
        if action == "choose" { payload["actionId"] = UUID().uuidString }
        let previous = latestRoomState
        do {
            if action != "leave", socketReady, socketRoomID == id, let roomSocket {
                return try await socketAction(action, payload: payload, task: roomSocket)
            }
            return try await request("rooms/\(id)/\(action)", method: "POST", payload: payload)
        }
        catch {
            guard Self.isConnectionError(error), !Task.isCancelled else { throw error }
            if action == "choose", supportsChoiceRetry {
                // The server deduplicates answers by actionId when only the acknowledgement was lost.
                return try await request("rooms/\(id)/\(action)", method: "POST", payload: payload)
            }
            guard ["start", "ready", "assets-ready"].contains(action),
                  let previous, previous.id == id else { throw error }
            return try await recoverPreparationAction(action, id: id, payload: payload,
                                                       previous: previous, originalError: error)
        }
    }

    private func preparationActionCompleted(_ action: String, previous: RoomState, current: RoomState) -> Bool {
        guard current.id == previous.id, current.gameNumber == previous.gameNumber else { return false }
        switch action {
        case "start":
            return previous.phase == "lobby" && current.phase != "lobby" && current.round >= 0
        case "ready":
            return current.round > previous.round || current.round == previous.round &&
                (current.readyIds.contains(playerId) || ["countdown", "listening", "answering", "reveal", "finished"].contains(current.phase))
        case "assets-ready":
            return (current.assetsReadyIds ?? []).contains(playerId) || current.phase != "lobby" && current.round >= 0
        default:
            return false
        }
    }

    private func recoverPreparationAction(_ action: String, id: String, payload: [String: Any],
                                          previous: RoomState, originalError: Error) async throws -> RoomState {
        if let observed = latestRoomState, preparationActionCompleted(action, previous: previous, current: observed) {
            return observed
        }
        let current: RoomState
        do { current = try await state(id) }
        catch {
            try Task.checkCancellation()
            if let observed = latestRoomState, preparationActionCompleted(action, previous: previous, current: observed) {
                return observed
            }
            throw originalError
        }
        try Task.checkCancellation()
        if let observed = latestRoomState, preparationActionCompleted(action, previous: previous, current: observed) {
            return observed
        }
        if preparationActionCompleted(action, previous: previous, current: current) { return current }
        // Never resend a start into a new game, or readiness into the next round.
        guard current.id == previous.id, current.gameNumber == previous.gameNumber,
              current.round == previous.round,
              current.phase == (action == "ready" ? "preparing" : "lobby") else { throw originalError }
        do {
            return try await request("rooms/\(id)/\(action)", method: "POST", payload: payload)
        } catch {
            guard Self.isConnectionError(error), !Task.isCancelled else { throw error }
            if let observed = latestRoomState, preparationActionCompleted(action, previous: previous, current: observed) {
                return observed
            }
            if let refreshed = try? await state(id), preparationActionCompleted(action, previous: previous, current: refreshed) {
                return refreshed
            }
            throw error
        }
    }

    static func isConnectionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain &&
            [URLError.networkConnectionLost.rawValue, URLError.timedOut.rawValue,
             URLError.notConnectedToInternet.rawValue].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== error { return isConnectionError(underlying) }
        return false
    }

    static func isExpiredSession(_ error: Error) -> Bool {
        guard let failure = error as? RoomHTTPError else { return false }
        return failure.status == 403 || failure.status == 404
    }
    func clear() {
        disconnectSocket()
        latestRoomState = nil
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
    }

    private var profileKey: String { "profileToken:\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)):\(profileID)" }
    private var profileRegistrationKey: String { "profileRegistration:\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)):\(profileID)" }
    var profileCredentialSnapshot: [String: String] {
        guard !baseURL.isEmpty, let credential = Secrets.get(profileKey) else { return [:] }
        return [baseURL.trimmingCharacters(in: .whitespacesAndNewlines): credential]
    }

    func restoreProfileIdentity(_ id: String, credentials: [String: String]) {
        if profileID != id {
            clear()
            profileID = id
            UserDefaults.standard.set(id, forKey: "profileID")
        }
        for (origin, credential) in credentials {
            Secrets.set(credential, for: "profileToken:\(origin):\(id)")
        }
    }
    private func profileCredentials() async throws -> String {
        if let existing = Secrets.get(profileKey) { return existing }
        _ = try await profile()
        guard let created = Secrets.get(profileKey) else { throw AppError.message("プロフィールを確認できません") }
        return created
    }

    private func friendRequest(_ path: String, payload: [String: Any]? = nil) async throws -> Data {
        let credential = try await profileCredentials()
        var url = try endpoint(path)
        if payload == nil { url.append(queryItems: [URLQueryItem(name: "profileId", value: profileID)]) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload.merging(["profileId": profileID]) { current, _ in current })
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let failure = try? JSONDecoder().decode(RoomFailure.self, from: data)
            throw AppError.message(failure?.error ?? "フレンド情報を取得できません (\(status))")
        }
        return data
    }

    func friends() async throws -> FriendsState {
        try JSONDecoder().decode(FriendsState.self, from: await friendRequest("friends"))
    }

    func playerProfile(friendID: String) async throws -> PlayerProfile {
        let credential = try await profileCredentials()
        var url = try endpoint("player-profile")
        url.append(queryItems: [URLQueryItem(name: "profileId", value: profileID),
                                URLQueryItem(name: "friendId", value: friendID)])
        return try await playerProfile(url: url, credential: credential)
    }

    func playerProfile(roomID: String, targetPlayerID: String) async throws -> PlayerProfile {
        guard let token else { throw AppError.message("ルームのセッションを確認できません") }
        var url = try endpoint("player-profile")
        url.append(queryItems: [URLQueryItem(name: "roomId", value: roomID),
                                URLQueryItem(name: "playerId", value: playerId),
                                URLQueryItem(name: "targetPlayerId", value: targetPlayerID)])
        return try await playerProfile(url: url, credential: token)
    }

    private func playerProfile(url: URL, credential: String) async throws -> PlayerProfile {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("プレイヤーのプロフィールを取得できません")
        }
        return try JSONDecoder().decode(PlayerProfile.self, from: data)
    }

    func respondToFriendRequest(_ id: String, accept: Bool) async throws -> FriendsState {
        let path = accept ? "friends/accept" : "friends/decline"
        return try JSONDecoder().decode(FriendsState.self,
            from: await friendRequest(path, payload: ["requestId": id]))
    }

    func sendFriendRequest(roomID: String, targetID: String) async throws -> RoomState {
        let credential = try await profileCredentials()
        _ = try await request("rooms/\(roomID)/bind-profile", method: "POST",
                              payload: ["profileId": profileID, "profileToken": credential])
        return try await action("friend-request", id: roomID, payload: ["targetId": targetID])
    }

    func inviteFriend(roomID: String, profileID targetID: String) async throws {
        let credential = try await profileCredentials()
        _ = try await request("rooms/\(roomID)/bind-profile", method: "POST",
                              payload: ["profileId": profileID, "profileToken": credential])
        _ = try await action("invite", id: roomID, payload: ["targetProfileId": targetID])
    }

    func joinInvite(_ inviteID: String, name: String, badge: String?, avatar: String?) async throws -> RoomState {
        let credential = try await profileCredentials()
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        return try await request("friends/invites/join", method: "POST", payload: [
            "profileId": profileID, "inviteId": inviteID, "name": name,
            "badge": badge ?? "", "avatar": avatar ?? ""
        ], authentication: credential)
    }
    func profile() async throws -> SavedProfile {
        let requestedID = profileID
        let requestedOrigin = baseURL
        let tokenKey = profileKey
        let registrationKey = profileRegistrationKey
        let existingToken = Secrets.get(tokenKey)
        var url = try endpoint("profile")
        url.append(queryItems: [URLQueryItem(name: "id", value: profileID)])
        var request = URLRequest(url: url)
        if let existingToken {
            request.setValue("Bearer \(existingToken)", forHTTPHeaderField: "Authorization")
        } else {
            // Persist before sending so a lost request or acknowledgement can be retried.
            let registration = Secrets.get(registrationKey) ?? UUID().uuidString
            if Secrets.get(registrationKey) == nil {
                Secrets.set(registration, for: registrationKey)
            }
            guard Secrets.get(registrationKey) == registration else {
                throw AppError.message("プロフィールの登録情報を端末に保存できません")
            }
            request.url = try endpoint("profile")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": profileID, "registrationToken": registration])
        }
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        // CloudKit account restoration can change identity while this request is in flight.
        guard profileID == requestedID, baseURL == requestedOrigin else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw AppError.message("プロフィールの同期に失敗しました (\(status))")
        }
        let saved = try JSONDecoder().decode(SavedProfile.self, from: data)
        if let token = saved.token {
            Secrets.set(token, for: tokenKey)
            guard Secrets.get(tokenKey) == token else {
                throw AppError.message("プロフィールの認証情報を端末に保存できません")
            }
            Secrets.set(nil, for: registrationKey)
            onProfileCredentialsChange?()
        }
        return saved
    }

    func legacyProfileIfAvailable() async throws -> SavedProfile? {
        guard Secrets.get(profileKey) != nil else { return nil }
        return try await profile()
    }

    func publishProfile(name: String, avatar: String?, stats: PlayerStats, highestRankLevel: Int? = nil) async throws {
        if let highestRankLevel, !(0...10).contains(highestRankLevel) {
            throw AppError.message("最高ランクが無効です")
        }
        let requestedID = profileID
        let requestedOrigin = baseURL
        let url = try endpoint("profile")
        let credential = try await profileCredentials()
        guard profileID == requestedID, baseURL == requestedOrigin else { throw CancellationError() }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Personal history/reviews and detailed statistics are managed by CloudKit.
        var summary: [String: Any] = [
            "id": requestedID, "name": name, "avatar": avatar ?? "",
            "publicStats": ["games": stats.games, "attempts": stats.attempts, "correct": stats.correct,
                            "averagePush": stats.averagePush,
                            "badges": stats.badges.sorted(), "selectedBadge": stats.selectedBadge ?? ""]
        ]
        // Omission preserves the earned badge when an older client publishes its summary.
        if let highestRankLevel { summary["highestRankLevel"] = highestRankLevel }
        request.httpBody = try JSONSerialization.data(withJSONObject: summary)
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard profileID == requestedID, baseURL == requestedOrigin else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("プロフィールを保存できません")
        }
    }
}
