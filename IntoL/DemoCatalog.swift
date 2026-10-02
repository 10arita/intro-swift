import Foundation

/// Original synthetic clips bundled for testing the game without music-service credentials.
enum DemoCatalog {
    private static let entries: [(String, String, String)] = [
        ("yoake", "夜明けの線", "IntoL Sessions"),
        ("kaze", "風の手紙", "IntoL Sessions"),
        ("aoi", "青い航路", "IntoL Sessions"),
        ("haru", "春の輪郭", "IntoL Sessions"),
        ("tsuki", "月と街", "IntoL Sessions"),
        ("hikari", "光の庭", "IntoL Sessions")
    ]

    static var songs: [Song] {
        entries.compactMap { file, title, artist in
            guard let url = Bundle.main.url(forResource: file, withExtension: "wav", subdirectory: "Audio") else { return nil }
            return Song(id: "demo:\(file)", title: title, artist: artist, artworkURL: nil,
                        previewURL: url, trackURL: nil,
                        durationMS: 30_000, genre: "オリジナル")
        }
    }

    static func search(_ term: String) -> [Song] {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return songs }
        return songs.filter { $0.title.localizedCaseInsensitiveContains(term) || $0.artist.localizedCaseInsensitiveContains(term) }
    }

    static func previewURL(for song: Song, bundle: Bundle = .main) -> URL? {
        guard song.id.hasPrefix("demo:") else { return song.previewURL }
        let name = String(song.id.dropFirst("demo:".count))
        guard entries.contains(where: { $0.0 == name }) else { return nil }
        return bundle.url(forResource: name, withExtension: "wav", subdirectory: "Audio")
    }
}
