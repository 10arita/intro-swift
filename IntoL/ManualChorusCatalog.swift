import Foundation

struct ManualChorusEntry: Codable {
    let title: String
    let artist: String
    let album: String
    let durationMS: Int
    let chorusStartMS: Int
    let checkedAt: String
    let musicID: String
    let catalogID: String?
    let libraryID: String?
    let storefront: String?
}

struct ManualChorusCatalog: Decodable {
    let schemaVersion: Int
    let recordCount: Int
    let records: [ManualChorusEntry]

    static func normalized(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.uppercased(with: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    static func key(title: String, artist: String) -> String {
        // Do not use quiz TitleRules: it strips Live / Remix / version suffixes.
        "\(normalized(title))\u{0}\(normalized(artist))"
    }

    static func decode(_ data: Data) throws -> ManualChorusCatalog {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.recordCount == catalog.records.count,
              catalog.records.allSatisfy({
                  !normalized($0.title).isEmpty && !normalized($0.artist).isEmpty &&
                      $0.durationMS > 0 && $0.chorusStartMS >= 0 && $0.chorusStartMS < $0.durationMS
              }) else { throw NSError(domain: "IntoL.ChorusCatalog", code: 1) }
        return catalog
    }

    var index: [String: ManualChorusEntry] {
        var result: [String: ManualChorusEntry] = [:]
        for entry in records {
            let key = Self.key(title: entry.title, artist: entry.artist)
            if let previous = result[key], previous.checkedAt > entry.checkedAt { continue }
            result[key] = entry
        }
        return result
    }

    static func revealPosition(for song: Song, index: [String: ManualChorusEntry]) -> Int? {
        guard !song.id.hasPrefix("itunes:"),
              let entry = index[key(title: song.title, artist: song.artist)],
              song.durationMS <= 0 || entry.chorusStartMS < song.durationMS else { return nil }
        // The database stores the actual boundary. Apply the lead-in exactly once here.
        return max(0, entry.chorusStartMS - 1500)
    }

    static func bundled() -> ManualChorusCatalog? {
        guard let url = Bundle.main.url(forResource: "manual-chorus", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }
}
