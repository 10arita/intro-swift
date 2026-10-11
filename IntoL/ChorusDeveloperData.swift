#if DEBUG
import Foundation

enum ChorusDeveloperError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct ChorusSourceSong: Codable, Identifiable, Equatable {
    let row: Int
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int?
    var id: Int { row }
}

/// Apple Music exports UTF-16 TSV. Quoted fields may contain tabs and newlines.
enum ChorusSourceImport {
    static func songs(from data: Data) throws -> [ChorusSourceSong] {
        guard data.count <= 20_000_000 else {
            throw ChorusDeveloperError.message("TXTファイルが大きすぎます（上限20MB）")
        }
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard let text = String(data: data, encoding: hasUTF16BOM ? .utf16 : .utf8) else {
            throw ChorusDeveloperError.message("UTF-16またはUTF-8のApple Music書き出しTXTを選んでください")
        }
        let rows = try tsv(text)
        guard let header = rows.first,
              let titleColumn = header.firstIndex(of: "名前"),
              let artistColumn = header.firstIndex(of: "アーティスト") else {
            throw ChorusDeveloperError.message("TXTに「名前」と「アーティスト」の列がありません")
        }
        let albumColumn = header.firstIndex(of: "アルバム")
        let durationColumn = header.firstIndex(of: "時間")
        var result: [ChorusSourceSong] = []
        for (index, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy({ $0.isEmpty }) { continue }
            guard row.indices.contains(titleColumn), row.indices.contains(artistColumn),
                  !row[titleColumn].isEmpty, !row[artistColumn].isEmpty else {
                throw ChorusDeveloperError.message("元の\(index + 2)行目の名前またはアーティストが空です")
            }
            func field(_ column: Int?) -> String {
                guard let column, row.indices.contains(column) else { return "" }
                return row[column]
            }
            result.append(ChorusSourceSong(row: index + 2, title: row[titleColumn], artist: row[artistColumn],
                                          album: field(albumColumn), durationSeconds: Int(field(durationColumn))))
        }
        guard !result.isEmpty else { throw ChorusDeveloperError.message("TXTに曲がありません") }
        return result
    }

    private static func tsv(_ text: String) throws -> [[String]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let character = normalized[index]
            let next = normalized.index(after: index)
            if character == "\"" {
                if quoted, next < normalized.endIndex, normalized[next] == "\"" {
                    field.append("\""); index = normalized.index(after: next); continue
                } else if quoted || field.isEmpty { quoted.toggle() }
                else { field.append(character) }
            } else if !quoted && (character == "\t" || character == "\n") {
                row.append(field); field = ""
                if character == "\n" { rows.append(row); row = [] }
            } else { field.append(character) }
            index = next
        }
        guard !quoted else { throw ChorusDeveloperError.message("TXTの引用符が閉じられていません") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

struct ChorusAnnotation: Codable, Identifiable, Equatable {
    let musicID: String
    let catalogID: String?
    let libraryID: String?
    let storefront: String
    let isrc: String?
    let title: String
    let artist: String
    let album: String
    let durationMS: Int
    let chorusStartMS: Int
    let checkedAt: Date
    let notes: String
    let playlist: String
    let sourceRow: Int?
    let sourceTitle: String?
    let sourceArtist: String?
    var id: String { "\(storefront):\(catalogID ?? musicID)" }

    func validate() throws {
        guard !musicID.isEmpty, !storefront.isEmpty, !title.isEmpty, !artist.isEmpty,
              durationMS > 0, chorusStartMS >= 0, chorusStartMS < durationMS else {
            throw ChorusDeveloperError.message("曲情報またはサビ位置が無効です。曲長以内の開始位置を確認してください")
        }
    }
}

struct ChorusDeveloperSession: Codable {
    var schemaVersion = 1
    var records: [ChorusAnnotation] = []
    var importedSongs: [ChorusSourceSong] = []
}

enum ChorusSubmissionProgress {
    static func annotation(musicID: String, catalogID: String? = nil, storefront: String,
                           records: [ChorusAnnotation]) -> ChorusAnnotation? {
        records.first {
            $0.storefront == storefront &&
                ($0.musicID == musicID || $0.libraryID == musicID || $0.catalogID == musicID ||
                 (catalogID != nil && $0.catalogID == catalogID))
        }
    }

    static func isSubmitted(_ source: ChorusSourceSong, records: [ChorusAnnotation]) -> Bool {
        records.contains {
            $0.sourceRow == source.row && $0.sourceTitle == source.title && $0.sourceArtist == source.artist
        }
    }

    /// Continue in list order, wrapping once and skipping submitted recordings.
    static func nextPending<Item: Identifiable>(in items: [Item], after currentID: Item.ID?,
                                               isSubmitted: (Item) -> Bool) -> Item? {
        guard !items.isEmpty else { return nil }
        let start = currentID.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        for offset in 0..<items.count {
            let item = items[(start + offset) % items.count]
            if !isSubmitted(item) { return item }
        }
        return nil
    }
}

/// JSON is the durable source of truth. XLSX is regenerated on each submission.
final class ChorusDeveloperStore {
    let directory: URL
    var workbookURL: URL { directory.appendingPathComponent("chorus-positions.xlsx") }
    private var sessionURL: URL { directory.appendingPathComponent("session-v1.json") }
    private(set) var session = ChorusDeveloperSession()

    init(directory: URL) { self.directory = directory }

    func load() throws {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return }
        let decoded = try JSONDecoder().decode(ChorusDeveloperSession.self, from: Data(contentsOf: sessionURL))
        guard decoded.schemaVersion == 1 else {
            throw ChorusDeveloperError.message("保存データのバージョンが未対応です。元のファイルはそのまま保持しています")
        }
        for record in decoded.records { try record.validate() }
        session = decoded
    }

    func importSongs(_ songs: [ChorusSourceSong]) throws {
        var updated = session
        updated.importedSongs = songs
        try persist(updated)
    }

    func submit(_ record: ChorusAnnotation) throws {
        try record.validate()
        var updated = session
        if let index = updated.records.firstIndex(where: { $0.id == record.id }) {
            updated.records[index] = record
        } else { updated.records.append(record) }
        updated.records.sort {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
        }
        try persist(updated)
        try exportWorkbook()
    }

    func exportWorkbook() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ChorusWorkbook.data(records: session.records).write(to: workbookURL, options: .atomic)
    }

    private func persist(_ updated: ChorusDeveloperSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: sessionURL, options: .atomic)
        session = updated
    }
}
#endif
