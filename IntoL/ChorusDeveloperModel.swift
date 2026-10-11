#if DEBUG
import Foundation
import MusicKit
import Observation

struct ChorusPlayingSongSummary {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let duration: Double
}

@MainActor @Observable
final class ChorusDeveloperModel {
    var playlists: [MusicKit.Playlist] = []
    var songs: [MusicKit.Song] = []
    var importedSongs: [ChorusSourceSong] = []
    var records: [ChorusAnnotation] = []
    var selectedSong: MusicKit.Song?
    var selectedSource: ChorusSourceSong?
    var playlistName = ""
    var selectedPlaylistID = ""
    var searchTerm = ""
    var notes = ""
    var chorusStartMS: Int?
    var recordingConfirmed = false
    var positionSeconds: Double = 0
    var isPlaying = false
    var isBusy = false
    var isConnected = false
    var errorMessage: String?
    var statusMessage: String?
    var exportURL: URL?
    private(set) var isReady = false
    private(set) var canWrite = false
    private(set) var isPlaylistLoaded = false
    let isPreview: Bool
    private let previewSong: ChorusPlayingSongSummary?
    @ObservationIgnored private let player = ApplicationMusicPlayer.shared
    @ObservationIgnored private let store: ChorusDeveloperStore
    @ObservationIgnored private var preparedEntryID: String?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var storefront = ""
    @ObservationIgnored private var selectedCatalogID: String?
    private var catalogIDsByMusicID: [String: String] = [:]

    init(preview: Bool = false) {
        isPreview = preview
        previewSong = preview ? ChorusPlayingSongSummary(id: "preview-only", title: "テスト音源（画面確認用）",
                                                        artistName: "IntoL", albumTitle: "開発者ツールのプレビュー", duration: 270) : nil
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = ChorusDeveloperStore(directory: documents.appendingPathComponent("ChorusDeveloper", isDirectory: true))
        if preview {
            positionSeconds = 72.3
            chorusStartMS = 72_300
            storefront = "jp"
            let source = ChorusSourceSong(row: 2, title: "テスト音源（画面確認用）", artist: "IntoL",
                                          album: "開発者ツールのプレビュー", durationSeconds: 270)
            importedSongs = [source, ChorusSourceSong(row: 3, title: "次の未提出曲（画面確認用）", artist: "IntoL",
                                                      album: "開発者ツールのプレビュー", durationSeconds: 240)]
            selectedSource = source
            records = [ChorusAnnotation(musicID: "preview-only", catalogID: nil, libraryID: nil, storefront: "jp", isrc: nil,
                                        title: source.title, artist: source.artist, album: source.album, durationMS: 270_000,
                                        chorusStartMS: 72_300, checkedAt: Date(), notes: "", playlist: "TXTから検索",
                                        sourceRow: source.row, sourceTitle: source.title, sourceArtist: source.artist)]
        }
    }

    var displaySong: ChorusPlayingSongSummary? {
        guard let selectedSong else { return previewSong }
        return ChorusPlayingSongSummary(id: String(describing: selectedSong.id), title: selectedSong.title,
                                        artistName: selectedSong.artistName, albumTitle: selectedSong.albumTitle,
                                        duration: selectedSong.duration ?? 0)
    }
    var durationSeconds: Double { displaySong?.duration ?? 0 }
    var ownsPlayback: Bool {
        guard !isPreview, isReady, let preparedEntryID else { return false }
        return player.queue.currentEntry?.id == preparedEntryID
    }
    var canCapture: Bool {
        ownsPlayback && !isBusy && (player.state.playbackStatus == .playing || player.state.playbackStatus == .paused)
    }
    var canSubmit: Bool {
        guard canWrite, canCapture, recordingConfirmed, let chorusStartMS else { return false }
        return chorusStartMS >= 0 && Double(chorusStartMS) < durationSeconds * 1000
    }
    var selectedAnnotation: ChorusAnnotation? {
        guard let song = displaySong else { return nil }
        return ChorusSubmissionProgress.annotation(musicID: song.id, catalogID: selectedCatalogID,
                                                   storefront: storefront, records: records)
    }
    var hasNextTrackContext: Bool { selectedSource != nil || isPlaylistLoaded }

    func annotation(for song: MusicKit.Song) -> ChorusAnnotation? {
        let id = String(describing: song.id)
        return ChorusSubmissionProgress.annotation(musicID: id, catalogID: catalogIDsByMusicID[id],
                                                   storefront: storefront, records: records)
    }

    func loadSavedWork() {
        guard !isPreview else { return }
        do {
            try store.load()
            records = store.session.records
            importedSongs = store.session.importedSongs
            canWrite = true
            if !records.isEmpty { rebuildWorkbook() }
        } catch {
            canWrite = false
            errorMessage = "保存データを読み込めません。上書きを止めています：\(error.localizedDescription)"
        }
    }

    func connect() async {
        await perform {
            guard await MusicAuthorization.request() == .authorized else {
                throw ChorusDeveloperError.message("設定アプリでIntoLのApple Musicアクセスを許可してください")
            }
            guard try await MusicSubscription.current.canPlayCatalogContent else {
                throw ChorusDeveloperError.message("フル再生にはApple Musicのサブスクリプションが必要です")
            }
            self.storefront = try await MusicDataRequest.currentCountryCode
            var request = MusicLibraryRequest<MusicKit.Playlist>()
            request.limit = 0
            self.playlists = Array(try await request.response().items).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            self.isConnected = true
            self.statusMessage = "Apple Musicに接続しました。プレイリスト、TXT、曲検索から選べます。"
        }
    }

    func loadPlaylist(_ id: String) async {
        guard !id.isEmpty, let playlist = playlists.first(where: { String(describing: $0.id) == id }) else { return }
        await perform {
            self.clearPlayback()
            self.selectedSource = nil
            self.playlistName = playlist.name
            self.songs = []
            self.isPlaylistLoaded = false
            let detailed = try await playlist.with(.tracks, preferredSource: .library)
            guard var tracks = detailed.tracks else { return }
            while tracks.hasNextBatch {
                try Task.checkCancellation()
                guard let next = try await tracks.nextBatch() else { break }
                tracks += next
            }
            var seen = Set<MusicItemID>()
            self.songs = tracks.compactMap { track in
                guard case .song(let song) = track, seen.insert(song.id).inserted else { return nil }
                return song
            }.sorted {
                $0.artistName.localizedStandardCompare($1.artistName) == .orderedAscending ||
                    ($0.artistName == $1.artistName && $0.title.localizedStandardCompare($1.title) == .orderedAscending)
            }
            self.isPlaylistLoaded = true
            self.statusMessage = "\(self.songs.count)曲を読み込みました"
        }
    }

    func search() async {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        await perform {
            self.clearPlayback()
            self.songs = []
            self.isPlaylistLoaded = false
            self.playlistName = self.selectedSource == nil ? "カタログ検索" : "TXTから検索"
            var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
            request.limit = 25
            self.songs = Array(try await request.response().songs)
            self.statusMessage = self.songs.isEmpty ? "候補がありません。検索語を変えてください" : "録音版を確認して候補を選んでください"
        }
    }

    func importFile(_ url: URL) {
        guard canWrite, !isBusy else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try ChorusSourceImport.songs(from: Data(contentsOf: url))
            try store.importSongs(imported)
            clearPlayback()
            selectedSource = nil
            songs = []
            isPlaylistLoaded = false
            importedSongs = imported
            statusMessage = "\(imported.count)曲を取り込みました。曲を選ぶとApple Musicで候補を検索します。"
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseSource(_ song: ChorusSourceSong) async {
        guard !isBusy else { return }
        clearPlayback()
        songs = []
        isPlaylistLoaded = false
        selectedSource = song
        selectedPlaylistID = ""
        searchTerm = "\(song.title) \(song.artist)"
        if isConnected { await search() }
        else { statusMessage = "Apple Musicに接続してから候補を検索してください" }
    }

    func sourceIsSubmitted(_ song: ChorusSourceSong) -> Bool {
        ChorusSubmissionProgress.isSubmitted(song, records: records)
    }

    func nextSource() async {
        guard !isBusy, !importedSongs.isEmpty else { return }
        if let next = ChorusSubmissionProgress.nextPending(in: importedSongs, after: selectedSource?.id, isSubmitted: sourceIsSubmitted) {
            await chooseSource(next)
        }
        else { statusMessage = "TXTの全曲を提出済みです" }
    }

    func nextTrack() async {
        guard !isBusy, !isPreview else { return }
        if selectedSource != nil { await nextSource(); return }
        guard isPlaylistLoaded else { return }
        if let next = ChorusSubmissionProgress.nextPending(in: songs, after: selectedSong?.id, isSubmitted: { annotation(for: $0) != nil }) {
            await select(next)
        } else { statusMessage = "このプレイリストの全曲を提出済みです" }
    }

    func submitAndAdvance() async {
        guard submit() else { return }
        let receipt = statusMessage
        await nextTrack()
        if let receipt, let nextStatus = statusMessage, receipt != nextStatus {
            statusMessage = "\(receipt)\n\(nextStatus)"
        }
    }

    func select(_ song: MusicKit.Song) async {
        await perform {
            guard let duration = song.duration, duration.isFinite, duration > 0, song.playParameters != nil else {
                throw ChorusDeveloperError.message("この曲はフル再生できないか、曲長を取得できません")
            }
            self.clearPlayback()
            let requestID = self.operationID
            self.selectedSong = song
            let linkedID = await self.catalogID(for: song)
            guard self.operationID == requestID, !Task.isCancelled else { throw CancellationError() }
            self.selectedCatalogID = linkedID
            if let linkedID { self.catalogIDsByMusicID[String(describing: song.id)] = linkedID }
            let saved = self.selectedAnnotation
            self.chorusStartMS = saved?.chorusStartMS
            self.notes = saved?.notes ?? ""
            self.player.state.shuffleMode = .off
            self.player.state.repeatMode = MusicPlayer.RepeatMode.none
            if #available(iOS 18.0, *) { self.player.transition = .none }
            self.player.queue = [song]
            if #available(iOS 26.4, *) { self.player.queue.affectsListeningHistory = false }
            try await self.player.prepareToPlay()
            guard self.operationID == requestID, !Task.isCancelled else { throw CancellationError() }
            guard let entry = self.player.queue.currentEntry else {
                throw ChorusDeveloperError.message("再生キューを確認できません。曲を選び直してください")
            }
            self.preparedEntryID = entry.id
            defer {
                if self.operationID != requestID, self.player.queue.currentEntry?.id == entry.id { self.player.stop() }
            }
            self.player.playbackTime = Double(max(0, (saved?.chorusStartMS ?? 1500) - 1500)) / 1000
            try await self.player.play()
            guard self.operationID == requestID, !Task.isCancelled else { throw CancellationError() }
            self.isReady = true
            self.refreshPlayback()
            self.statusMessage = saved == nil ? "サビ位置で「現在位置をサビにする」を押してください" : "保存済み位置を読み込みました。訂正して再提出できます。"
        }
    }

    func refreshPlayback() {
        guard ownsPlayback else {
            if isReady { isReady = false; recordingConfirmed = false }
            isPlaying = false
            return
        }
        let time = player.playbackTime
        if time.isFinite { positionSeconds = min(max(0, time), durationSeconds) }
        isPlaying = player.state.playbackStatus == .playing
    }

    func togglePlayback() async {
        guard ownsPlayback else { return }
        if player.state.playbackStatus == .playing { player.pause(); refreshPlayback(); return }
        await perform { try await self.player.play(); self.refreshPlayback() }
    }

    func seek(to time: Double) {
        guard ownsPlayback, !isBusy, time.isFinite else { return }
        player.playbackTime = min(max(0, time), max(0, durationSeconds - 0.001))
        refreshPlayback()
    }

    func capture() {
        guard canCapture else { return }
        // Sample directly when tapped; do not use the last timer tick or the pause completion time.
        let time = player.playbackTime
        guard time.isFinite, time >= 0, time < durationSeconds else { return }
        player.pause()
        chorusStartMS = min(Int((time * 1000).rounded()), Int(durationSeconds * 1000) - 1)
        recordingConfirmed = false
        refreshPlayback()
        statusMessage = "開始位置を記録しました。微調整して直前から聴き直してください。"
    }

    func adjustMarker(_ deltaMS: Int) {
        guard let start = chorusStartMS, !isBusy else { return }
        chorusStartMS = min(max(0, start + deltaMS), max(0, Int(durationSeconds * 1000) - 1))
        recordingConfirmed = false
    }

    func previewMarker() async {
        guard ownsPlayback, let start = chorusStartMS else { return }
        await perform {
            self.player.playbackTime = Double(max(0, start - 1500)) / 1000
            try await self.player.play()
            self.refreshPlayback()
        }
    }

    @discardableResult func submit() -> Bool {
        guard canSubmit, let song = selectedSong, let chorusStartMS else { return false }
        let musicID = String(describing: song.id)
        let isLibraryID = !Self.isCatalogID(musicID)
        let previous = selectedAnnotation
        let record = ChorusAnnotation(musicID: musicID, catalogID: selectedCatalogID, libraryID: isLibraryID ? musicID : previous?.libraryID,
                                      storefront: storefront, isrc: song.isrc, title: song.title, artist: song.artistName,
                                      album: song.albumTitle ?? "", durationMS: Int(durationSeconds * 1000), chorusStartMS: chorusStartMS,
                                      checkedAt: Date(), notes: notes, playlist: playlistName, sourceRow: selectedSource?.row ?? previous?.sourceRow,
                                      sourceTitle: selectedSource?.title ?? previous?.sourceTitle,
                                      sourceArtist: selectedSource?.artist ?? previous?.sourceArtist)
        do {
            try store.submit(record)
            records = store.session.records
            exportURL = store.workbookURL
            statusMessage = "提出しました。\(records.count)曲分のXLSXを更新しました。"
            if record.catalogID == nil { statusMessage! += " カタログIDが未取得のため、共通DBへの登録前に曲の対応付けが必要です。" }
            errorMessage = nil
            return true
        } catch {
            records = store.session.records
            // Never offer a stale workbook as the latest export after a failed rebuild.
            exportURL = nil
            errorMessage = store.session.records.contains(record) ? "記録は端末に保存済みです。XLSX更新に失敗しました。「XLSXを再生成」で再試行してください：\(error.localizedDescription)" : error.localizedDescription
            return false
        }
    }

    func rebuildWorkbook() {
        guard canWrite, !isPreview else { return }
        do {
            try store.exportWorkbook()
            exportURL = store.workbookURL
            errorMessage = nil
        } catch { exportURL = nil; errorMessage = "XLSXを生成できません：\(error.localizedDescription)" }
    }

    func stop() { clearPlayback() }

    private func clearPlayback() {
        operationID = UUID()
        if let preparedEntryID, player.queue.currentEntry?.id == preparedEntryID { player.stop() }
        else if let selectedSong, player.queue.currentEntry?.item?.id == selectedSong.id { player.stop() }
        preparedEntryID = nil
        selectedCatalogID = nil
        isReady = false
        isPlaying = false
        positionSeconds = 0
        selectedSong = nil
        chorusStartMS = nil
        notes = ""
        recordingConfirmed = false
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy, !isPreview else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    private static func isCatalogID(_ id: String) -> Bool { !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) } }

    /// Use Apple's explicit library-to-catalog relationship, without fuzzy title matching.
    private func catalogID(for song: MusicKit.Song) async -> String? {
        let id = String(describing: song.id)
        if Self.isCatalogID(id) { return id }
        var url = URL(string: "https://api.music.apple.com/v1/me/library/songs/")!.appending(path: id)
        url.append(queryItems: [URLQueryItem(name: "include", value: "catalog")])
        guard let response = try? await MusicDataRequest(urlRequest: URLRequest(url: url)).response(),
              let object = try? JSONDecoder().decode(ChorusCatalogLinkResponse.self, from: response.data),
              let linked = object.catalogID, Self.isCatalogID(linked) else { return nil }
        return linked
    }
}

private struct ChorusCatalogLinkResponse: Decodable {
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
    var catalogID: String? { data.first?.attributes?.playParams?.catalogId ?? data.first?.relationships?.catalog?.data?.first?.id }
}
#endif
