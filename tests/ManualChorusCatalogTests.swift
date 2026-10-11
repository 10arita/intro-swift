import Foundation

@main private struct ManualChorusCatalogTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let catalog = try ManualChorusCatalog.decode(data)
        precondition(catalog.records.count == 600 && catalog.index.count == 600)
        let index = catalog.index
        for record in catalog.records {
            // A compilation uses another catalog ID; album is deliberately not part of song identity.
            let song = Song(id: "applemusic:another-album-id", title: record.title, artist: record.artist,
                            durationMS: record.durationMS, genre: "")
            precondition(ManualChorusCatalog.revealPosition(for: song, index: index) == max(0, record.chorusStartMS - 1500))
            var other = song
            other.artist += "別の歌手"
            precondition(ManualChorusCatalog.revealPosition(for: other, index: index) == nil)
            other = song; other.title += " (Live)"
            precondition(ManualChorusCatalog.revealPosition(for: other, index: index) == nil)
            other = song; other.id = "itunes:preview"
            precondition(ManualChorusCatalog.revealPosition(for: other, index: index) == nil)
            if record.chorusStartMS > 0 {
                other = song; other.durationMS = record.chorusStartMS
                precondition(ManualChorusCatalog.revealPosition(for: other, index: index) == nil)
            }
        }
        precondition(ManualChorusCatalog.normalized("Ｓｕｂｔｉｔｌｅ　") == "SUBTITLE")
        precondition(ManualChorusCatalog.normalized("レイニー ブルー") == ManualChorusCatalog.normalized("レイニーブルー"))
        let malformed = data.replacingJSONValue("schemaVersion", with: 2)
        do { _ = try ManualChorusCatalog.decode(malformed); preconditionFailure("Unknown schemas must fail") } catch { }
        print("600 recordings verified: album-independent identity, lead-in, different artists, Live versions, previews, and bounds")
    }
}

private extension Data {
    func replacingJSONValue(_ key: String, with value: Int) -> Data {
        var object = try! JSONSerialization.jsonObject(with: self) as! [String: Any]
        object[key] = value
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
