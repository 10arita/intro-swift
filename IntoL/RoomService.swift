import Foundation

struct RoomSettings: Codable {
    var questionCount = 6
    var answerSlots = 2
    var targetScore = 50
    var correctPoints = 10
    var firstBonus = 10
    var wrongPenalty = 10
    var firstWrongPenalty = 10
    var lives = 3
    var endless = false
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

    var song: Song? {
        guard let title, let artist else { return nil }
        let chorusPosition = chorusMS.flatMap { value -> Int? in
            guard value.isFinite else { return nil }
            let maximum = min(Double(max(0, durationMS ?? 180_000)), 86_400_000)
            return Int(max(0, min(maximum, value)).rounded())
        }
        return Song(id: id, title: title, artist: artist, artworkURL: artworkURL, previewURL: previewURL,
                    trackURL: trackURL,
                    durationMS: durationMS ?? 180_000, genre: genre ?? "その他", songleURL: songleURL,
                    chorusMS: chorusPosition)
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
    let correctPlayerID: String?
    let correctPlayerIDs: [String]
    let current: RoomCurrent?
    let sessionToken: String?
    let supportsChoiceRetry: Bool?

    var questionAudioClosed: Bool { !settings.endless && (pushClosed || audioStoppedAt != nil) }

    func player(_ id: String) -> RoomPlayer? { players.first { $0.id == id } }
    func isAnswering(_ id: String) -> Bool { activeAnswers.contains { $0.playerId == id } }
    func canPush(_ id: String) -> Bool {
        guard ["listening", "answering"].contains(phase), player(id)?.disqualified == false,
              !pushedIds.contains(id) else { return false }
        return settings.endless ? activeAnswers.isEmpty : !pushClosed
    }
}

private struct RoomCatalog: Decodable { let songs: [Song] }
private struct ItunesMatch: Decodable { let song: Song? }
private struct CorpusResponse: Decodable { let titles: [String] }
private struct ChorusResponse: Decodable { let positionMS: Int }
private struct SongleSearchEntry: Decodable {
    struct Artist: Decodable { let name: String }
    let title: String
    let artist: Artist?
    let duration: Double?
    let permalink: URL?
    let url: URL?
}
private struct SongleChorusMap: Decodable {
    struct Segment: Decodable {
        struct Repeat: Decodable { let start: Double }
        let isChorus: Bool
        let repeats: [Repeat]
    }
    let chorusSegments: [Segment]
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
    private(set) var serverClockOffsetMS = 0.0
    private var bestClockRTTMS = Double.infinity
    private var clockSampleAt = Date.distantPast
    var serverNowMS: Double { Date.now.timeIntervalSince1970 * 1000 + serverClockOffsetMS }
    func localDate(for serverTimeMS: Double) -> Date {
        Date(timeIntervalSince1970: (serverTimeMS - serverClockOffsetMS) / 1000)
    }
    let playerId: String
    var profileID: String
    private(set) var token: String?
    private var itunesMatches: [String: ItunesMatch] = [:]
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

    init() {
        if let saved = UserDefaults.standard.string(forKey: "roomPlayerId") { playerId = saved }
        else { playerId = UUID().uuidString; UserDefaults.standard.set(playerId, forKey: "roomPlayerId") }
        profileID = UserDefaults.standard.string(forKey: "spotifyAccountID").map { "spotify:\($0)" } ?? playerId
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
        supportsChoiceRetry = state.supportsChoiceRetry == true
        let roundTrip = receivedAt - sentAt
        if roundTrip < bestClockRTTMS || Date.now.timeIntervalSince(clockSampleAt) > 30 {
            serverClockOffsetMS = state.serverNow - (sentAt + receivedAt) / 2
            bestClockRTTMS = roundTrip
            clockSampleAt = .now
        }
    }

    private func request(_ path: String, method: String = "GET", payload: [String: Any] = [:]) async throws -> RoomState {
        var url = try endpoint(path)
        if method == "GET" { url.append(queryItems: [URLQueryItem(name: "playerId", value: playerId)]) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = path.hasSuffix("/choose") ? 2.5 : 10
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if method != "GET" {
            var body = payload
            body["playerId"] = playerId
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sentAt = Date.now.timeIntervalSince1970 * 1000
        let (data, response) = try await URLSession.shared.data(for: request)
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

    func create(name: String, settings: RoomSettings, mode: String = "shared", songs: [Song] = [], corpus: [String] = [], badge: String? = nil, avatar: String? = nil) async throws -> RoomState {
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        let settingsData = try JSONEncoder().encode(settings)
        let rule = try JSONSerialization.jsonObject(with: settingsData)
        let songData = try JSONEncoder().encode(songs)
        let songList = try JSONSerialization.jsonObject(with: songData)
        return try await request("rooms", method: "POST", payload: ["name": name, "badge": badge ?? "", "avatar": avatar ?? "", "settings": rule,
                                                                  "mode": mode, "songs": songList, "corpus": corpus])
    }

    func join(_ id: String, name: String, badge: String? = nil, avatar: String? = nil) async throws -> RoomState {
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        return try await request("rooms/\(id.uppercased())/join", method: "POST", payload: ["name": name, "badge": badge ?? "", "avatar": avatar ?? ""])
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
        let task = URLSession.shared.webSocketTask(with: request)
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
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
    func searchItunes(_ term: String) async throws -> [Song] {
        var url = try endpoint("itunes/search")
        url.append(queryItems: [URLQueryItem(name: "term", value: term)])
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("iTunes 検索に失敗しました") }
        return try JSONDecoder().decode(RoomCatalog.self, from: data).songs
    }
    func matchItunes(_ song: Song) async throws -> Song? {
        if let cached = itunesMatches[song.id] { return cached.song }
        var request = URLRequest(url: try endpoint("itunes/match"))
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(song)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.message("iTunes 照合に失敗しました") }
        let match = try JSONDecoder().decode(ItunesMatch.self, from: data)
        itunesMatches[song.id] = match
        return match.song
    }
    func topSongs() async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: endpoint("itunes/top"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return try JSONDecoder().decode(CorpusResponse.self, from: data).titles
    }
    func chorus(_ song: Song) async -> Int {
        guard !song.id.hasPrefix("itunes:") else { return 0 }
        if let url = try? endpoint("chorus") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 16
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(song)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(ChorusResponse.self, from: data) {
                return decoded.positionMS
            }
        }
        return await songleChorus(song) ?? fallbackChorus(song)
    }
    private func songleChorus(_ song: Song) async -> Int? {
        var source = song.songleURL
        if source == nil {
            guard var search = URLComponents(string: "https://widget.songle.jp/api/v1/songs/search.json") else { return nil }
            search.queryItems = [URLQueryItem(name: "q", value: "\(song.title) \(song.artist)".trimmingCharacters(in: .whitespaces))]
            guard let url = search.url, let entries: [SongleSearchEntry] = await songleResponse(url) else { return nil }
            let title = TitleRules.normalized(song.title)
            let artist = TitleRules.normalized(song.artist.components(separatedBy: ",").first ?? song.artist)
            let matches = entries.filter { entry in
                TitleRules.normalized(entry.title) == title &&
                    (artist.isEmpty || TitleRules.normalized(entry.artist?.name ?? "").contains(artist))
            }
            let closest = matches.min {
                abs(($0.duration ?? Double(song.durationMS)) - Double(song.durationMS)) <
                    abs(($1.duration ?? Double(song.durationMS)) - Double(song.durationMS))
            }
            source = closest?.permalink ?? closest?.url
        }
        guard var source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { return nil }
        if ["songle.jp", "www.songle.jp"].contains(source.host?.lowercased() ?? "") {
            guard let path = URLComponents(url: source, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                  path.hasPrefix("/songs/"),
                  let original = String(path.dropFirst("/songs/".count)).removingPercentEncoding,
                  let decoded = URL(string: "https://\(original)") else { return nil }
            source = decoded
        }
        guard let parts = URLComponents(url: source, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(),
              ["www.youtube.com", "youtube.com", "youtu.be", "www.nicovideo.jp", "www.niconico.jp"].contains(host),
              parts.port == nil, parts.user == nil, parts.password == nil else { return nil }
        var chorus = URLComponents(string: "https://widget.songle.jp/api/v1/song/chorus.json")!
        chorus.queryItems = [URLQueryItem(name: "url", value:
            host + parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? ""))]
        guard let url = chorus.url, let map: SongleChorusMap = await songleResponse(url),
              let start = map.chorusSegments.first(where: \.isChorus)?.repeats.first?.start,
              start.isFinite else { return nil }
        return max(0, min(max(0, song.durationMS - 5000), Int((start - 1500).rounded())))
    }
    private func songleResponse<Value: Decodable>(_ url: URL) async -> Value? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
    private func fallbackChorus(_ song: Song) -> Int {
        max(0, min(90_000, max(30_000, Int(Double(song.durationMS) * 0.32))) - 1500)
    }
    func action(_ action: String, id: String, payload: [String: Any] = [:]) async throws -> RoomState {
        var payload = payload
        if action == "choose" { payload["actionId"] = UUID().uuidString }
        if action != "leave", socketReady, socketRoomID == id, let roomSocket {
            do { return try await socketAction(action, payload: payload, task: roomSocket) }
            catch {
                guard action == "choose", supportsChoiceRetry, Self.isConnectionError(error),
                      !Task.isCancelled else { throw error }
                // The server uses actionId to return the current state if the socket
                // processed this answer before its acknowledgement was lost.
                return try await request("rooms/\(id)/\(action)", method: "POST", payload: payload)
            }
        }
        do { return try await request("rooms/\(id)/\(action)", method: "POST", payload: payload) }
        catch {
            guard action == "choose", supportsChoiceRetry, Self.isConnectionError(error),
                  !Task.isCancelled else { throw error }
            return try await request("rooms/\(id)/\(action)", method: "POST", payload: payload)
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
    func clear() {
        disconnectSocket()
        supportsChoiceRetry = false
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
    }

    private var profileKey: String { "profileToken:\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)):\(profileID)" }
    func linkSpotify(accessToken: String) async throws {
        var request = URLRequest(url: try endpoint("profile/link"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("Spotify プロフィールを連携できません")
        }
        struct Linked: Decodable { let id: String; let token: String }
        let linked = try JSONDecoder().decode(Linked.self, from: data)
        profileID = linked.id
        UserDefaults.standard.set(String(linked.id.dropFirst("spotify:".count)), forKey: "spotifyAccountID")
        Secrets.set(linked.token, for: profileKey)
    }
    func profile() async throws -> SavedProfile {
        let existingToken = Secrets.get(profileKey)
        var url = try endpoint("profile")
        url.append(queryItems: [URLQueryItem(name: "id", value: profileID)])
        var request = URLRequest(url: url)
        if let existingToken {
            request.setValue("Bearer \(existingToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.url = try endpoint("profile")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": profileID])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw AppError.message("プロフィールの同期に失敗しました (\(status))")
        }
        let saved = try JSONDecoder().decode(SavedProfile.self, from: data)
        if let token = saved.token { Secrets.set(token, for: profileKey) }
        return saved
    }

    func saveProfile(reviews: [ReviewSong], history: [SoloResult], stats: PlayerStats) async throws {
        if Secrets.get(profileKey) == nil { _ = try await profile() }
        var request = URLRequest(url: try endpoint("profile"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(Secrets.get(profileKey) ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let id: String
            let reviews: [ReviewSong]
            let history: [SoloResult]
            let stats: PlayerStats
        }
        request.httpBody = try JSONEncoder().encode(Body(id: profileID, reviews: reviews, history: history, stats: stats))
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("プロフィールを保存できません")
        }
    }
}
