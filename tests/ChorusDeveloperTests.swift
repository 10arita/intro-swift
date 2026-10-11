import Foundation

@main private struct ChorusDeveloperTests {
    static func annotation(id: String = "001234", catalogID: String? = "001234", start: Int = 0,
                           duration: Int = 270_000, storefront: String = "jp") -> ChorusAnnotation {
        ChorusAnnotation(musicID: id, catalogID: catalogID, libraryID: id.hasPrefix("i.") ? id : nil,
                         storefront: storefront, isrc: "JPTEST000001", title: "=1+1", artist: "アーティスト & <歌> 😀",
                         album: "アルバム \"引用\"", durationMS: duration, chorusStartMS: start,
                         checkedAt: Date(timeIntervalSince1970: 1_700_000_000), notes: "=HYPERLINK(\"test\")\nメモ\u{1}",
                         playlist: "IntoL", sourceRow: 2, sourceTitle: "元の名前", sourceArtist: "元の歌手")
    }

    static func reject(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected failure") } catch { }
    }

    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = ChorusDeveloperStore(directory: output.appendingPathComponent("store"))
        try store.load()
        precondition(store.session.records.isEmpty)
        for bad in [annotation(start: -1), annotation(start: 270_000), annotation(duration: 0), annotation(storefront: "")] {
            reject { try store.submit(bad) }
        }
        precondition(store.session.records.isEmpty)
        try store.submit(annotation(start: 0))
        precondition(FileManager.default.fileExists(atPath: store.workbookURL.path), "Submission must automatically create XLSX")
        try store.submit(annotation(start: 72_345))
        precondition(store.session.records.count == 1 && store.session.records[0].chorusStartMS == 72_345,
                     "Resubmission must replace the same recording")
        try store.submit(annotation(id: "i.library", start: 73_000))
        precondition(store.session.records.count == 1, "Linked library and catalog recordings must share one annotation")
        try store.submit(annotation(id: "001234", start: 72_345))
        try store.submit(annotation(id: "other", catalogID: "999999", start: 0, storefront: "us"))
        precondition(store.session.records.count == 2, "Storefronts and recordings must remain distinct")
        let restored = ChorusDeveloperStore(directory: store.directory)
        try restored.load()
        precondition(restored.session.records == store.session.records, "Records must survive a fresh store instance")
        try Data(contentsOf: store.workbookURL).write(to: output.appendingPathComponent("records.xlsx"))
        try ChorusWorkbook.data(records: []).write(to: output.appendingPathComponent("empty.xlsx"))
        let bulk = (0..<600).map { annotation(id: "\($0)", catalogID: "\($0)", start: 72_345) }
        let started = Date()
        try ChorusWorkbook.data(records: bulk).write(to: output.appendingPathComponent("bulk.xlsx"))
        print(String(format: "600-record XLSX generated in %.3f seconds", Date().timeIntervalSince(started)))

        let tsv = "名前\tアーティスト\tアルバム\t時間\r\n\"曲\t名\"\t歌手\t\"アルバム\"\"引用\"\"\"\t270\r\n\"曲\n続き\"\t別の歌手\t盤\t66\r\n"
        let parsed = try ChorusSourceImport.songs(from: Data(tsv.utf8))
        precondition(parsed.count == 2 && parsed[0].row == 2 && parsed[1].row == 3)
        precondition(parsed[0].title == "曲\t名" && parsed[0].album == "アルバム\"引用\"")
        precondition(parsed[1].title == "曲\n続き" && parsed[1].durationSeconds == 66)
        let unicode = try ChorusSourceImport.songs(from: tsv.data(using: .utf16)!)
        precondition(unicode == parsed, "UTF-16 and UTF-8 imports must preserve identical content")
        reject { _ = try ChorusSourceImport.songs(from: Data("曲名\t歌手\n曲\t歌手".utf8)) }
        reject { _ = try ChorusSourceImport.songs(from: Data("名前\tアーティスト\n\"未完了".utf8)) }
        reject { _ = try ChorusSourceImport.songs(from: Data("名前\tアーティスト\n\t歌手".utf8)) }
        try store.importSongs(parsed)
        precondition(store.session.records.count == 2)
        let importedStore = ChorusDeveloperStore(directory: store.directory)
        try importedStore.load()
        precondition(importedStore.session.importedSongs == parsed)

        let failedExport = ChorusDeveloperStore(directory: output.appendingPathComponent("failed-export"))
        try FileManager.default.createDirectory(at: failedExport.workbookURL, withIntermediateDirectories: true)
        reject { try failedExport.submit(annotation()) }
        let recovered = ChorusDeveloperStore(directory: failedExport.directory)
        try recovered.load()
        precondition(recovered.session.records.count == 1, "A workbook failure must not lose the submitted record")

        let corruptDirectory = output.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptURL = corruptDirectory.appendingPathComponent("session-v1.json")
        let original = Data("not-json".utf8)
        try original.write(to: corruptURL)
        reject { try ChorusDeveloperStore(directory: corruptDirectory).load() }
        let preserved = try Data(contentsOf: corruptURL)
        precondition(preserved == original, "Loading corrupt data must not overwrite it")

        if CommandLine.arguments.count > 2 {
            let actual = try ChorusSourceImport.songs(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            precondition(actual.count == 597)
            precondition(Set(actual.map(\.row)).count == 597)
            try JSONEncoder().encode(actual).write(to: output.appendingPathComponent("actual-import.json"))
            print("IntoL.txt: 597 songs imported successfully")
        }
        print("Chorus developer persistence, validation, TSV, and XLSX generation tests passed")
    }
}
