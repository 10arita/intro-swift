import Foundation
import Security
import MusicKit

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

struct AppleMusicPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    var artworkURL: URL? = nil
}

private struct AppleMusicLibrarySongResponse: Decodable {
    struct Item: Decodable {
        struct Attributes: Decodable {
            struct PlayParams: Decodable { let catalogId: String? }
            let playParams: PlayParams?
        }
        struct Relationships: Decodable {
            struct Catalog: Decodable {
                struct Item: Decodable { let id: String }
                let data: [Item]?
            }
            let catalog: Catalog?
        }
        let attributes: Attributes?
        let relationships: Relationships?
    }
    let data: [Item]

    var catalogID: String? {
        data.first?.attributes?.playParams?.catalogId ?? data.first?.relationships?.catalog?.data?.first?.id
    }
}

@MainActor final class AppleMusicService {
    private let player = ApplicationMusicPlayer.shared
    private var playlistsByID: [String: MusicKit.Playlist] = [:]
    private var songsByID: [String: MusicKit.Song] = [:]
    private var playRequest = 0
    private var queuedSongID: String?
    private var topTitlesByArtist: [String: [String]] = [:]

    var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }
    var isPlaying: Bool { player.state.playbackStatus == .playing }
    var hasEnded: Bool {
        player.state.playbackStatus == .stopped ||
        (player.state.playbackStatus == .paused && duration > 0 && currentTime >= duration - 0.1)
    }
    var currentTime: TimeInterval {
        let value = player.playbackTime
        return value.isFinite ? max(0, value) : 0
    }
    var duration: TimeInterval {
        guard let queuedSongID, let value = songsByID[queuedSongID]?.duration, value.isFinite else { return 0 }
        return max(0, value)
    }

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
        return items.map {
            AppleMusicPlaylist(id: String(describing: $0.id), name: $0.name,
                               artworkURL: $0.artwork?.url(width: 300, height: 300))
        }
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
            guard !Task.isCancelled else { return result }
            guard let librarySong = songsByID[song.id],
                  let catalogSong = await catalogMatch(for: librarySong) else { continue }
            guard !Task.isCancelled else { return result }
            let id = "applemusic:\(catalogSong.id)"
            songsByID[id] = catalogSong
            result.append(Song(id: id, title: catalogSong.title, artist: catalogSong.artistName,
                               artworkURL: catalogSong.artwork?.url(width: 300, height: 300),
                               previewURL: nil, trackURL: catalogSong.url,
                               durationMS: Int((catalogSong.duration ?? 180) * 1000),
                               genre: catalogSong.genreNames.first ?? song.genre))
        }
        return result
    }

    private func catalogMatch(for librarySong: MusicKit.Song) async -> MusicKit.Song? {
        guard !Task.isCancelled else { return nil }
        func exact(_ candidate: MusicKit.Song) -> Bool {
            guard isCatalogID(String(describing: candidate.id)), candidate.playParameters != nil else { return false }
            func key(_ text: String) -> String {
                text.precomposedStringWithCompatibilityMapping.lowercased()
                    .replacingOccurrences(of: #"[\p{P}\p{S}\s]"#, with: "", options: .regularExpression)
            }
            guard key(candidate.title) == key(librarySong.title),
                  key(candidate.artistName) == key(librarySong.artistName) else { return false }
            if let sourceDuration = librarySong.duration, let matchDuration = candidate.duration {
                return abs(sourceDuration - matchDuration) <= 3
            }
            return true
        }
        let libraryID = String(describing: librarySong.id)
        if isCatalogID(libraryID), let song = try? await catalogSong(for: "applemusic:\(libraryID)"), exact(song) {
            return song
        }
        guard !Task.isCancelled else { return nil }
        if let catalogID = await associatedCatalogID(for: libraryID), isCatalogID(catalogID),
           !Task.isCancelled,
           let song = try? await catalogSong(for: "applemusic:\(catalogID)"), exact(song) {
            return song
        }
        guard !Task.isCancelled else { return nil }
        if let isrc = librarySong.isrc {
            let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: Optional(isrc))
            if let song = try? await request.response().items.first(where: exact) { return song }
        }
        return nil
    }

    private func associatedCatalogID(for libraryID: String) async -> String? {
        var url = URL(string: "https://api.music.apple.com/v1/me/library/songs/")!.appending(path: libraryID)
        url.append(queryItems: [URLQueryItem(name: "include", value: "catalog")])
        guard let response = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response(),
              let song = try? JSONDecoder().decode(AppleMusicLibrarySongResponse.self, from: response.data) else { return nil }
        return song.catalogID
    }

    private func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) }
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
        // Solo games use songs returned by the user's library playlist. Their IDs
        // are library IDs, so querying the catalog with one can fail even though
        // the original Song is playable. Room songs use catalog IDs and are fetched
        // here when they are not already cached.
        let item: MusicKit.Song
        if let cached = songsByID[songID] { item = cached }
        else { item = try await catalogSong(for: songID) }
        guard initialRequest == playRequest, !Task.isCancelled else { throw CancellationError() }
        playRequest += 1
        let currentRequest = playRequest
        queuedSongID = nil
        player.stop()
        player.queue = [item]
        try await player.prepareToPlay()
        guard currentRequest == playRequest, !Task.isCancelled else { throw CancellationError() }
        queuedSongID = songID
    }

    private func catalogSong(for songID: String) async throws -> MusicKit.Song {
        try Task.checkCancellation()
        guard songID.hasPrefix("applemusic:") else { throw AppError.message("Apple Music の曲IDが無効です") }
        let id = String(songID.dropFirst("applemusic:".count))
        let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let item = try await request.response().items.first, item.playParameters != nil else {
            throw AppError.message("この Apple Music の曲は再生できません")
        }
        try Task.checkCancellation()
        return item
    }

    private func playableSong(for songID: String) async throws -> MusicKit.Song {
        if let cached = songsByID[songID] { return cached }
        guard songID.hasPrefix("applemusic:") else { throw AppError.message("Apple Music の曲IDが無効です") }
        let id = String(songID.dropFirst("applemusic:".count))
        if isCatalogID(id), let catalog = try? await catalogSong(for: songID) {
            songsByID[songID] = catalog
            return catalog
        }
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        if let library = try? await request.response().items.first, library.playParameters != nil {
            songsByID[songID] = library
            return library
        }
        let catalog = try await catalogSong(for: songID)
        songsByID[songID] = catalog
        return catalog
    }

    /// Never substitute another recording or a preview clip in the common rank bank.
    func rankSong(for question: RankQuestion) async throws -> Song {
        func matches(_ item: MusicKit.Song) -> Bool {
            item.playParameters != nil && question.matches(title: item.title, artist: item.artistName, album: item.albumTitle)
        }
        var resolved: MusicKit.Song?
        if let hint = question.catalogIDHint,
           let hinted = try? await catalogSong(for: "applemusic:" + hint), matches(hinted) {
            resolved = hinted
        }
        if resolved == nil {
            try Task.checkCancellation()
            var request = MusicCatalogSearchRequest(term: question.title + " " + question.artist, types: [MusicKit.Song.self])
            request.limit = 25
            let response = try await request.response()
            resolved = response.songs.first(where: matches)
        }
        try Task.checkCancellation()
        guard let item = resolved, let duration = item.duration, duration > question.pushLimit else {
            throw RankError.recordingUnavailable
        }
        let id = "applemusic:" + String(describing: item.id)
        songsByID[id] = item
        return Song(id: id, title: item.title, artist: item.artistName,
                    artworkURL: item.artwork?.url(width: 600, height: 600),
                    previewURL: nil, trackURL: item.url,
                    durationMS: Int(duration * 1000), genre: item.genreNames.first ?? "J-Pop")
    }

    func previewURL(for songID: String) async -> URL? {
        guard let item = try? await playableSong(for: songID) else { return nil }
        if let url = item.previewAssets?.compactMap(\.url).first { return url }
        guard let catalog = await catalogMatch(for: item) else { return nil }
        return catalog.previewAssets?.compactMap(\.url).first
    }

    func prepareCatalog(_ songIDs: [String]) async throws {
        guard isAuthorized, try await MusicSubscription.current.canPlayCatalogContent else {
            throw AppError.message("Apple Music のアクセス許可とサブスクリプションが必要です")
        }
        for id in songIDs where songsByID[id] == nil {
            songsByID[id] = try await catalogSong(for: id)
        }
    }

    func play(_ song: Song, offsetMS: Int = 0, offsetProvider: (() throws -> Int)? = nil) async throws {
        let initialRequest = playRequest
        let item = try await playableSong(for: song.id)
        guard initialRequest == playRequest, !Task.isCancelled else { throw CancellationError() }
        playRequest += 1
        let request = playRequest
        if queuedSongID != song.id {
            queuedSongID = nil
            player.stop()
            player.queue = [item]
            try await player.prepareToPlay()
            guard request == playRequest, !Task.isCancelled else { throw CancellationError() }
            queuedSongID = song.id
        }
        guard request == playRequest, !Task.isCancelled else { return }
        player.playbackTime = TimeInterval(max(0, try offsetProvider?() ?? offsetMS)) / 1000
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

    func seek(to time: TimeInterval) async throws {
        guard queuedSongID != nil, time.isFinite, duration > 0 else { return }
        let request = playRequest
        let target = min(max(0, time), duration)
        player.playbackTime = target
        if target < duration { try await player.play() }
        if request == playRequest && Task.isCancelled { player.stop() }
    }

    func stop() {
        playRequest += 1
        queuedSongID = nil
        player.stop()
    }
}
