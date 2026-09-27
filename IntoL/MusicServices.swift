import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import MusicKit

struct SpotifyPlaylist: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let images: [SpotifyImage]?
    var artworkURL: URL? { images?.first?.url }
}

struct SpotifyImage: Decodable, Hashable { let url: URL? }
struct SpotifyDevice: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let type: String
    let is_active: Bool
    let is_restricted: Bool
}
struct SpotifyAccount: Decodable {
    let id: String
    let account_id: String?
    let display_name: String?
    let product: String?
    var isPremium: Bool { product == "premium" }
}

enum Secrets {
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "IntoL", kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "IntoL", kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

@MainActor final class SpotifyService: NSObject, ASWebAuthenticationPresentationContextProviding {
    var clientID = AppConfiguration.spotifyClientID
    var serverURL = ""
    var deviceID: String? { didSet { UserDefaults.standard.set(deviceID, forKey: "spotifyDeviceID") } }
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    var isConnected: Bool { Secrets.get("spotifyRefresh") != nil }

    override init() {
        deviceID = UserDefaults.standard.string(forKey: "spotifyDeviceID")
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
    }

    private var redirectURI: String {
        serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/spotify/callback"
    }

    func connect(forceDialog: Bool = false) async throws {
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty, URL(string: redirectURI)?.scheme == "https" else {
            throw AppError.message("Spotify 連携は現在利用できません")
        }
        let verifier = Data((0..<64).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = UUID().uuidString
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: client), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge), .init(name: "state", value: state),
            .init(name: "scope", value: "playlist-read-private playlist-read-collaborative user-read-private user-read-playback-state user-modify-playback-state"),
            .init(name: "show_dialog", value: forceDialog ? "true" : "false")
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "intol") { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? AppError.message("Spotify 認証を完了できません")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            if !session.start() { continuation.resume(throwing: AppError.message("Spotify 認証画面を開けません")) }
        }
        authSession = nil
        let params = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { params.first { $0.name == key }?.value }
        guard value("state") == state, let code = value("code") else {
            throw AppError.message(value("error") ?? "Spotify の認証情報を確認できません")
        }
        try await tokenRequest(["grant_type": "authorization_code", "code": code,
                                "redirect_uri": redirectURI, "code_verifier": verifier])
    }

    func disconnect() {
        accessToken = nil; expiresAt = .distantPast
        Secrets.set(nil, for: "spotifyRefresh")
        deviceID = nil
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }
    private func tokenRequest(_ fields: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = ([URLQueryItem(name: "client_id", value: clientID.trimmingCharacters(in: .whitespacesAndNewlines))] + fields.map { URLQueryItem(name: $0.key, value: $0.value) })
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.message("Spotify トークンを取得できません。Client ID と Redirect URI を確認してください")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.access_token
        expiresAt = .now.addingTimeInterval(TimeInterval(max(60, token.expires_in - 60)))
        if let refresh = token.refresh_token { Secrets.set(refresh, for: "spotifyRefresh") }
    }

    private func validToken() async throws -> String {
        if let accessToken, expiresAt > .now { return accessToken }
        guard let refresh = Secrets.get("spotifyRefresh") else { throw AppError.message("Spotify に接続してください") }
        try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
        return accessToken!
    }
    func bearerToken() async throws -> String { try await validToken() }

    private func api(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            if status == 401 { accessToken = nil; expiresAt = .distantPast }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
            throw AppError.message("Spotify API エラー \(status): \(detail.map(String.init(describing:)) ?? "再接続または再生デバイスを確認してください")")
        }
        return data
    }

    func account() async throws -> SpotifyAccount { try JSONDecoder().decode(SpotifyAccount.self, from: try await api("me")) }

    func playlists() async throws -> [SpotifyPlaylist] {
        struct Page: Decodable { let items: [SpotifyPlaylist]; let total: Int }
        var result: [SpotifyPlaylist] = []
        for offset in stride(from: 0, to: 200, by: 50) {
            let page = try JSONDecoder().decode(Page.self, from: try await api("me/playlists?limit=50&offset=\(offset)"))
            result += page.items
            if result.count >= page.total { break }
        }
        return result
    }

    func songs(in playlist: SpotifyPlaylist) async throws -> [Song] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Track: Decodable {
                    struct Artist: Decodable { let name: String }
                    struct Album: Decodable { let images: [SpotifyImage]? }
                    let id: String?
                    let name: String
                    let artists: [Artist]?
                    let album: Album?
                    let duration_ms: Int?
                    let external_urls: [String: String]?
                    let type: String?
                }
                let item: Track?
                let track: Track?
            }
            let items: [Item]
            let total: Int
        }
        var result: [Song] = []
        for offset in stride(from: 0, to: 250, by: 50) {
            let page = try JSONDecoder().decode(Page.self, from: try await api("playlists/\(playlist.id)/items?limit=50&offset=\(offset)"))
            result += page.items.compactMap { entry in
                guard let track = entry.item ?? entry.track, let id = track.id,
                      track.type == nil || track.type == "track",
                      !TitleRules.normalized(track.name).isEmpty else { return nil }
                return Song(id: "spotify:\(id)", title: track.name,
                            artist: track.artists?.map(\.name).joined(separator: ", ") ?? "",
                            artworkURL: track.album?.images?.first?.url, previewURL: nil,
                            trackURL: URL(string: track.external_urls?["spotify"] ?? "https://open.spotify.com/track/\(id)"),
                            durationMS: track.duration_ms ?? 180_000, genre: "その他")
            }
            if offset + 50 >= page.total { break }
        }
        return Array(Dictionary(grouping: result, by: \.id).values.compactMap(\.first))
    }

    func devices() async throws -> [SpotifyDevice] {
        struct Response: Decodable { let devices: [SpotifyDevice] }
        return try JSONDecoder().decode(Response.self, from: try await api("me/player/devices")).devices.filter { !$0.is_restricted }
    }

    func play(_ song: Song, offsetMS: Int = 0) async throws {
        guard song.id.hasPrefix("spotify:") else { return }
        let devices = try await devices()
        let selected = devices.first { $0.id == deviceID } ?? devices.first { $0.is_active } ?? devices.first
        guard let selected else { throw AppError.message("Spotify アプリで曲を再生し、設定から再生先を選んでください") }
        deviceID = selected.id
        if !selected.is_active {
            _ = try await api("me/player", method: "PUT", body: ["device_ids": [selected.id], "play": false])
            try await Task.sleep(for: .milliseconds(800))
        }
        _ = try await api("me/player/play?device_id=\(selected.id)", method: "PUT",
                          body: ["uris": ["spotify:track:\(song.id.dropFirst(8))"], "position_ms": max(0, offsetMS)])
        struct PlaybackState: Decodable {
            struct Item: Decodable { let id: String? }
            struct Device: Decodable { let id: String }
            let is_playing: Bool
            let item: Item?
            let device: Device?
        }
        let trackID = String(song.id.dropFirst(8))
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(500))
            if let data = try? await api("me/player"),
               let state = try? JSONDecoder().decode(PlaybackState.self, from: data),
               state.is_playing, state.item?.id == trackID, state.device?.id == selected.id {
                return
            }
        }
        throw AppError.message("選択した再生先で曲の開始を確認できません。Spotifyでその再生先を有効にし、再生先を更新してください")
    }

    func pause() async throws {
        guard let deviceID else { return }
        _ = try await api("me/player/pause?device_id=\(deviceID)", method: "PUT")
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct AppleMusicPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor final class AppleMusicService {
    private let player = ApplicationMusicPlayer.shared
    private var playlistsByID: [String: MusicKit.Playlist] = [:]
    private var songsByID: [String: MusicKit.Song] = [:]
    private var playRequest = 0
    private var preparedSongID: String?

    var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }

    func authorize() async throws -> Bool {
        guard await MusicAuthorization.request() == .authorized else {
            throw AppError.message("Apple Music へのアクセスを許可してください。拒否した場合は iPhone の設定から変更できます")
        }
        return try await MusicSubscription.current.canPlayCatalogContent
    }

    func canPlay() async throws -> Bool {
        guard isAuthorized else { return false }
        return try await MusicSubscription.current.canPlayCatalogContent
    }

    func playlists() async throws -> [AppleMusicPlaylist] {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.limit = 0
        let items = try await request.response().items
        playlistsByID = Dictionary(uniqueKeysWithValues: items.map { (String(describing: $0.id), $0) })
        return items.map { AppleMusicPlaylist(id: String(describing: $0.id), name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func songs(in playlistID: String) async throws -> [Song] {
        guard let playlist = playlistsByID[playlistID] else {
            throw AppError.message("Apple Music のプレイリストを読み込み直してください")
        }
        let detailed = try await playlist.with(.tracks, preferredSource: .library)
        guard var tracks = detailed.tracks else { return [] }
        while tracks.hasNextBatch {
            guard let next = try await tracks.nextBatch() else { break }
            tracks += next
        }
        var results: [Song] = []
        for track in tracks {
            guard case .song(let item) = track, item.playParameters != nil,
                  !TitleRules.characters(item.title).isEmpty else { continue }
            let id = "applemusic:\(item.id)"
            songsByID[id] = item
            results.append(Song(id: id, title: item.title, artist: item.artistName,
                                artworkURL: item.artwork?.url(width: 300, height: 300),
                                previewURL: nil, trackURL: item.url,
                                durationMS: Int((item.duration ?? 180) * 1000),
                                genre: item.genreNames.first ?? "その他"))
        }
        return results
    }

    func catalogSongs(for source: [Song]) async -> [Song] {
        var result: [Song] = []
        for song in source {
            guard let librarySong = songsByID[song.id], let isrc = librarySong.isrc else { continue }
            do {
                let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: Optional(isrc))
                guard let catalogSong = try await request.response().items.first,
                      catalogSong.playParameters != nil else { continue }
                let id = "applemusic:\(catalogSong.id)"
                guard id.range(of: #"^applemusic:[0-9]+$"#, options: .regularExpression) != nil else { continue }
                songsByID[id] = catalogSong
                result.append(Song(id: id, title: catalogSong.title, artist: catalogSong.artistName,
                                   artworkURL: catalogSong.artwork?.url(width: 300, height: 300),
                                   previewURL: nil, trackURL: catalogSong.url,
                                   durationMS: Int((catalogSong.duration ?? 180) * 1000),
                                   genre: catalogSong.genreNames.first ?? song.genre))
            } catch { continue }
        }
        return result
    }

    func prepare(_ songID: String) async throws {
        let initialRequest = playRequest
        guard isAuthorized, try await MusicSubscription.current.canPlayCatalogContent else {
            throw AppError.message("Apple Music のアクセス許可とサブスクリプションが必要です")
        }
        let item = try await catalogSong(for: songID)
        guard initialRequest == playRequest, !Task.isCancelled else { throw CancellationError() }
        playRequest += 1
        let currentRequest = playRequest
        player.stop()
        player.queue = [item]
        try await player.prepareToPlay()
        if currentRequest == playRequest { preparedSongID = songID }
    }

    private func catalogSong(for songID: String) async throws -> MusicKit.Song {
        guard songID.hasPrefix("applemusic:") else { throw AppError.message("Apple Music の曲IDが無効です") }
        let id = String(songID.dropFirst("applemusic:".count))
        let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let item = try await request.response().items.first, item.playParameters != nil else {
            throw AppError.message("この Apple Music の曲は再生できません")
        }
        songsByID[songID] = item
        return item
    }

    func play(_ song: Song, offsetMS: Int = 0) async throws {
        let initialRequest = playRequest
        let item: MusicKit.Song
        if let cached = songsByID[song.id] { item = cached }
        else { item = try await catalogSong(for: song.id) }
        guard initialRequest == playRequest, !Task.isCancelled else { throw CancellationError() }
        playRequest += 1
        let request = playRequest
        if preparedSongID != song.id {
            player.stop()
            player.queue = [item]
            try await player.prepareToPlay()
        }
        preparedSongID = nil
        guard request == playRequest, !Task.isCancelled else { return }
        player.playbackTime = TimeInterval(max(0, offsetMS)) / 1000
        try await player.play()
        if request == playRequest && Task.isCancelled { player.stop() }
    }

    func pause() { player.pause() }

    func stop() {
        playRequest += 1
        preparedSongID = nil
        player.stop()
    }
}
