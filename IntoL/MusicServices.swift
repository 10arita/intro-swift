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
    let remote = SpotifyRemote()
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    private var artistIDByTrack: [String: String] = [:]
    private var topTitlesByArtist: [String: [String]] = [:]
    var isConnected: Bool { Secrets.get("spotifyRefresh") != nil }

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
            .init(name: "scope", value: "playlist-read-private playlist-read-collaborative user-read-private app-remote-control"),
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
        remote.disconnect()
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
        if path.hasPrefix("search?") { request.timeoutInterval = 6 }
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
            throw AppError.message("Spotify API エラー \(status): \(detail.map(String.init(describing:)) ?? "再接続してください")")
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
                    struct Artist: Decodable { let id: String?; let name: String }
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
                if let artistID = track.artists?.first?.id { artistIDByTrack["spotify:\(id)"] = artistID }
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

    func withArtistTopTitles(_ songs: [Song]) async -> [Song] {
        struct Page: Decodable {
            struct Track: Decodable {
                struct Artist: Decodable { let id: String }
                let name: String
                let artists: [Artist]
            }
            struct Tracks: Decodable { let items: [Track] }
            let tracks: Tracks
        }
        var result = songs
        for index in result.indices {
            guard let artistID = artistIDByTrack[result[index].id] else { continue }
            if let cached = topTitlesByArtist[artistID] {
                result[index].artistTopTitles = cached
                continue
            }
            let name = result[index].artist.components(separatedBy: ",").first ?? result[index].artist
            var query = URLComponents()
            query.queryItems = [.init(name: "q", value: "artist:\"\(name)\""),
                                .init(name: "type", value: "track"),
                                .init(name: "market", value: "JP"), .init(name: "limit", value: "10")]
            guard let data = try? await api("search?\(query.percentEncodedQuery ?? "")"),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { continue }
            var titles: [String] = []
            var seen = Set<String>()
            for track in page.tracks.items where track.artists.contains(where: { $0.id == artistID }) {
                let key = TitleRules.normalized(track.name)
                if !key.isEmpty && seen.insert(key).inserted { titles.append(track.name) }
                if titles.count == 7 { break }
            }
            topTitlesByArtist[artistID] = titles
            result[index].artistTopTitles = titles
        }
        return result
    }

    func preparePlayback() async throws {
        try await remote.prepare(clientID: clientID, accessToken: try await validToken())
    }

    func handleRemoteCallback(_ url: URL) -> Bool { remote.handleCallback(url) }

    func play(_ song: Song, offsetMS: Int = 0) async throws {
        guard song.id.hasPrefix("spotify:") else { return }
        try await preparePlayback()
        try await remote.play(uri: "spotify:track:\(song.id.dropFirst(8))", offsetMS: offsetMS)
    }

    func pause() async throws {
        try await remote.pause()
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
    private var topTitlesByArtist: [String: [String]] = [:]

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

    func withArtistTopTitles(_ songs: [Song]) async -> [Song] {
        var result = songs
        for index in result.indices {
            let item: MusicKit.Song
            if let cached = songsByID[result[index].id] { item = cached }
            else if let fetched = try? await catalogSong(for: result[index].id) { item = fetched }
            else { continue }
            guard let detailed = try? await item.with(.artists),
                  let artist = detailed.artists?.first else { continue }
            let artistID = String(describing: artist.id)
            if let cached = topTitlesByArtist[artistID] {
                result[index].artistTopTitles = cached
                continue
            }
            guard let ranked = try? await artist.with(.topSongs), let topSongs = ranked.topSongs else { continue }
            var titles: [String] = []
            var seen = Set<String>()
            for song in topSongs {
                let key = TitleRules.normalized(song.title)
                if !key.isEmpty && seen.insert(key).inserted { titles.append(song.title) }
                if titles.count == 7 { break }
            }
            topTitlesByArtist[artistID] = titles
            result[index].artistTopTitles = titles
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

    func prepareCatalog(_ songIDs: [String]) async throws {
        guard isAuthorized, try await MusicSubscription.current.canPlayCatalogContent else {
            throw AppError.message("Apple Music のアクセス許可とサブスクリプションが必要です")
        }
        for id in songIDs where songsByID[id] == nil {
            _ = try await catalogSong(for: id)
        }
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
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard request == playRequest else { throw CancellationError() }
            if player.state.playbackStatus == .playing { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw AppError.message("Apple Music の再生開始を確認できません。接続を確認して再試行してください")
    }

    func pause() { player.pause() }

    func stop() {
        playRequest += 1
        preparedSongID = nil
        player.stop()
    }
}
