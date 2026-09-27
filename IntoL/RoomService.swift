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
    let pushTimeMS: Double?
    let lives: Int
    let disqualified: Bool
    let connected: Bool
    let isHost: Bool
    let badge: String?
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
    let chorusMS: Int?

    var song: Song? {
        guard let title, let artist else { return nil }
        return Song(id: id, title: title, artist: artist, artworkURL: artworkURL, previewURL: previewURL,
                    trackURL: trackURL,
                    durationMS: durationMS ?? 180_000, genre: genre ?? "その他", songleURL: songleURL,
                    chorusMS: chorusMS)
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
    let skippedIds: [String]
    let readyIds: [String]
    let assetsReadyIds: [String]?
    let preload: [GameAsset]?
    let correctPlayerID: String?
    let correctPlayerIDs: [String]
    let current: RoomCurrent?
    let sessionToken: String?

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
private struct RoomFailure: Decodable { let error: String; let state: RoomState? }
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
        request.timeoutInterval = 10
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

    func create(name: String, settings: RoomSettings, mode: String = "shared", songs: [Song] = [], corpus: [String] = [], badge: String? = nil) async throws -> RoomState {
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        let settingsData = try JSONEncoder().encode(settings)
        let rule = try JSONSerialization.jsonObject(with: settingsData)
        let songData = try JSONEncoder().encode(songs)
        let songList = try JSONSerialization.jsonObject(with: songData)
        return try await request("rooms", method: "POST", payload: ["name": name, "badge": badge ?? "", "settings": rule,
                                                                  "mode": mode, "songs": songList, "corpus": corpus])
    }

    func join(_ id: String, name: String, badge: String? = nil) async throws -> RoomState {
        token = nil
        Secrets.set(nil, for: "roomSessionToken")
        UserDefaults.standard.removeObject(forKey: "roomSessionToken")
        return try await request("rooms/\(id.uppercased())/join", method: "POST", payload: ["name": name, "badge": badge ?? ""])
    }

    func state(_ id: String) async throws -> RoomState { try await request("rooms/\(id)") }

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
        for try await line in bytes.lines {
            try Task.checkCancellation()
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
        var request: URLRequest
        do { request = URLRequest(url: try endpoint("chorus")) } catch { return fallbackChorus(song) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(song)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ChorusResponse.self, from: data) else { return fallbackChorus(song) }
        return decoded.positionMS
    }
    private func fallbackChorus(_ song: Song) -> Int {
        max(0, min(90_000, max(30_000, Int(Double(song.durationMS) * 0.32))) - 1500)
    }
    func action(_ action: String, id: String, payload: [String: Any] = [:]) async throws -> RoomState {
        try await request("rooms/\(id)/\(action)", method: "POST", payload: payload)
    }
    func clear() { token = nil; Secrets.set(nil, for: "roomSessionToken"); UserDefaults.standard.removeObject(forKey: "roomSessionToken") }

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
