#if DEBUG
import Foundation

/// Minimal OOXML workbook in a standards-compliant, uncompressed ZIP container.
/// Inline strings are always literal text; submitted notes cannot become formulas.
enum ChorusWorkbook {
    private enum Cell {
        case text(String), number(Double, style: Int = 0)
    }

    static func data(records: [ChorusAnnotation]) -> Data {
        let headers = ["名前", "アーティスト", "アルバム", "サビ開始", "サビ開始秒", "サビ開始MS", "曲長MS",
                       "catalogID", "libraryID", "storefront", "ISRC", "確認日時UTC", "確認状態", "取得方法",
                       "メモ", "プレイリスト", "元の行", "元の名前", "元のアーティスト", "musicID"]
        let formatter = ISO8601DateFormatter()
        var rows = [row(headers.map { .text($0) }, number: 1, header: true)]
        for (index, record) in records.enumerated() {
            let cells: [Cell] = [
                .text(record.title), .text(record.artist), .text(record.album),
                .number(Double(record.chorusStartMS) / 86_400_000, style: 2),
                .number(Double(record.chorusStartMS) / 1000, style: 3), .number(Double(record.chorusStartMS)),
                .number(Double(record.durationMS)), .text(record.catalogID ?? ""), .text(record.libraryID ?? ""),
                .text(record.storefront), .text(record.isrc ?? ""), .text(formatter.string(from: record.checkedAt)),
                .text("確認済み"), .text("manual-apple-music"), .text(record.notes), .text(record.playlist),
                record.sourceRow.map { .number(Double($0)) } ?? .text(""),
                .text(record.sourceTitle ?? ""), .text(record.sourceArtist ?? ""), .text(record.musicID)
            ]
            rows.append(row(cells, number: index + 2))
        }
        let lastRow = max(1, records.count + 1)
        let sheet = xml("""
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:T\(lastRow)"/>
          <sheetViews><sheetView workbookViewId="0" showGridLines="0"><pane xSplit="3" ySplit="1" topLeftCell="D2" activePane="bottomRight" state="frozen"/></sheetView></sheetViews>
          <sheetFormatPr defaultRowHeight="36"/>
          <cols><col min="1" max="3" width="38" customWidth="1"/><col min="4" max="7" width="17" customWidth="1"/><col min="8" max="11" width="20" customWidth="1"/><col min="12" max="12" width="25" customWidth="1"/><col min="13" max="14" width="24" customWidth="1"/><col min="15" max="16" width="38" customWidth="1"/><col min="17" max="17" width="12" customWidth="1"/><col min="18" max="20" width="38" customWidth="1"/></cols>
          <sheetData>\(rows.joined())</sheetData><autoFilter ref="A1:T\(lastRow)"/>
        </worksheet>
        """)
        let files: [(String, String)] = [
            ("[Content_Types].xml", xml("""
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """)),
            ("_rels/.rels", xml("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """)),
            ("xl/workbook.xml", xml("""
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="サビ位置" sheetId="1" r:id="rId1"/></sheets></workbook>
            """)),
            ("xl/_rels/workbook.xml.rels", xml("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """)),
            ("xl/worksheets/sheet1.xml", sheet),
            ("xl/styles.xml", xml("""
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <numFmts count="2"><numFmt numFmtId="164" formatCode="[m]:ss.000"/><numFmt numFmtId="165" formatCode="0.000"/></numFmts>
              <fonts count="2"><font><sz val="11"/><name val="Arial"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Arial"/></font></fonts>
              <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF374151"/><bgColor indexed="64"/></patternFill></fill></fills>
              <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
              <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
              <cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
              <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
            </styleSheet>
            """))
        ]
        return archive(files.map { ($0.0, Data($0.1.utf8)) })
    }

    private static func row(_ cells: [Cell], number: Int, header: Bool = false) -> String {
        let values = cells.enumerated().map { index, cell -> String in
            let reference = "\(String(UnicodeScalar(65 + index)!))\(number)"
            switch cell {
            case .text(let value):
                return "<c r=\"\(reference)\" t=\"inlineStr\" s=\"\(header ? 1 : 0)\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
            case .number(let value, let style):
                return "<c r=\"\(reference)\" s=\"\(style)\"><v>\(value)</v></c>"
            }
        }.joined()
        return "<row r=\"\(number)\" ht=\"\(header ? 28 : 42)\" customHeight=\"1\">\(values)</row>"
    }

    private static func escape(_ text: String) -> String {
        let legal = text.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value == 10 || scalar.value == 13 ||
                (0x20...0xD7FF).contains(scalar.value) || (0xE000...0xFFFD).contains(scalar.value) ||
                (0x10000...0x10FFFF).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(legal)).prefix(32767)
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func xml(_ body: String) -> String { "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + body }

    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return ~crc
    }

    private static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data(), central = Data()
        for (name, body) in files {
            let nameData = Data(name.utf8), checksum = crc32(body), offset = UInt32(output.count)
            output.le32(0x04034B50); output.le16(20); output.le16(0x0800); output.le16(0)
            output.le16(0); output.le16(0x0021); output.le32(checksum)
            output.le32(UInt32(body.count)); output.le32(UInt32(body.count)); output.le16(UInt16(nameData.count)); output.le16(0)
            output.append(nameData); output.append(body)
            central.le32(0x02014B50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0)
            central.le16(0); central.le16(0x0021); central.le32(checksum); central.le32(UInt32(body.count)); central.le32(UInt32(body.count))
            central.le16(UInt16(nameData.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(offset); central.append(nameData)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.le32(0x06054B50); output.le16(0); output.le16(0); output.le16(UInt16(files.count)); output.le16(UInt16(files.count))
        output.le32(UInt32(central.count)); output.le32(centralOffset); output.le16(0)
        return output
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}
#endif
