import Foundation

struct Song: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var previewURL: URL?
    var trackURL: URL?
    var durationMS: Int
    var genre: String
    var songleURL: URL? = nil
    var chorusMS: Int? = nil
    var artistTopTitles: [String]? = nil

    var playablePreview: Bool { previewURL != nil }
}

enum TitleRules {
    static let famousTitles: [String] = {
        ["famousSongs", "famousSongsJapaneseExpansion", "famousSongsJpop2015Plus", "famousSongsChart2015Plus"]
            .flatMap { name -> [String] in
                guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                      let data = try? Data(contentsOf: url),
                      let titles = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                return titles
            }
    }()

    static func normalized(_ title: String) -> String {
        var value = title.replacingOccurrences(of: #"\([^)]*\)|（[^）]*）"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\s+(feat\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
        value = value.precomposedStringWithCompatibilityMapping.uppercased()
        return String(value.unicodeScalars.filter { scalar in
            let code = scalar.value
            return (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A)
                || (code >= 0x3040 && code <= 0x30FF) || (code >= 0x3400 && code <= 0x9FFF)
                || code == 0x3005 || code == 0x3006 || code == 0x30FC
        }.map(Character.init))
    }

    static func characters(_ title: String) -> [String] {
        normalized(title).map(String.init)
    }

    static func kind(_ char: String) -> Int {
        let n = char.unicodeScalars.first?.value ?? 0
        if n >= 0x3040 && n <= 0x309F { return 0 }
        if n >= 0x30A0 && n <= 0x30FF { return 1 }
        if n >= 0x3400 && n <= 0x9FFF || n == 0x3005 || n == 0x3006 { return 2 }
        if n >= 0x41 && n <= 0x5A { return 3 }
        return 4
    }

    private static let forbidden = Set("っゃゅょぁぃぅぇぉゎッャュョァィゥェォヮー".map(String.init))
    private static let similar: [String: [String]] = {
        let groups = [
            "日目白田", "未末朱本", "大犬太天", "土士王工", "人入八", "青清晴静", "花華芽草", "歌唄謡語", "空突穹室", "夜液衣夢",
            "木本末未", "口日目四", "山出岳岩", "川州順", "水永氷泉", "火灯炎災", "金針銀鉄", "月用明朋", "雨雪雲雷", "心必思忘",
            "春奏泰", "夏復憂", "秋愁愈", "冬寒終", "朝潮嘲", "風鳳凰", "海毎梅", "光先元", "星屋室", "恋変愛",
            "道導首", "音暗韻", "声聖聞", "新親薪", "時待持", "間問門", "夢薫募", "愛受優", "君群郡", "花化華",
            "高髙亮", "島鳥嶋", "楽薬栗", "白自百", "赤赦赫", "青責清", "黒墨黙", "深探採", "遠運達", "近折所",
            "笑咲啖", "泣涙流", "走起赴", "飛非悲", "舞無夢", "知和矢", "手毛才", "足是定", "目貝見", "耳取聞",
            "思恩忠", "空室窓", "石右岩", "林森木", "糸系紫", "魚漁鮮", "言計詩", "女好妥", "子字学", "力刀功",
            "夜液掖", "友反双", "雪雲雷", "花草葉", "地池他", "声唄歌", "虹紅江", "春椿秋", "時詩持", "道運遠"
        ]
        var result: [String: [String]] = [:]
        for group in groups {
            let characters = group.map(String.init)
            for value in characters { result[value, default: []].append(contentsOf: characters.filter { $0 != value }) }
        }
        return result
    }()

    static func choices(answer: String, prefix: String, corpus: [String], artistTopTitles: [String] = []) -> [String] {
        let type = kind(answer)
        var candidates: [String] = []
        var preferred: [String] = []
        let corpus = corpus + famousTitles
        if prefix.isEmpty {
            for char in artistTopTitles.prefix(7).compactMap({ characters($0).first }).shuffled()
                where char != answer && !forbidden.contains(char) && !preferred.contains(char) {
                preferred.append(char)
                if preferred.count == 3 { break }
            }
            candidates += corpus.compactMap { characters($0).first }
        } else {
            candidates += similar[answer] ?? []
            candidates += corpus.compactMap { title in
                let chars = characters(title)
                let used = prefix.map(String.init).count
                return chars.count > used && chars.prefix(used).joined() == prefix ? chars[used] : nil
            }
            let prev = String(prefix.suffix(1))
            candidates += corpus.flatMap { title -> [String] in
                let chars = characters(title)
                guard chars.count > 1 else { return [] }
                return (0..<(chars.count - 1)).compactMap { chars[$0] == prev ? chars[$0 + 1] : nil }
            }
        }
        let pools = [
            "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん",
            "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン",
            "愛光音海風春夏秋冬君夢星夜花青空雨雪月道心時人世界日明白山川新未来恋歌声虹",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "0123456789"
        ]
        if type == 2 {
            candidates += (0..<1200).compactMap { UnicodeScalar(0x4E00 + $0).map { String(Character($0)) } }.shuffled()
        }
        candidates += pools[type].map(String.init).shuffled()
        let fallback = Array(NSOrderedSet(array: candidates.filter { $0 != answer && kind($0) == type
            && !forbidden.contains($0) && !preferred.contains($0) })).compactMap { $0 as? String }
        let distractors = preferred + fallback
        return ([answer] + distractors.prefix(3)).shuffled()
    }
}

struct SoloResult: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let playlist: String
    let total: Int
    let correct: Int
    let averagePush: Double
    let score: Double
    let rank: String

    static func make(playlist: String, total: Int, pushTimes: [Double]) -> SoloResult {
        let correct = pushTimes.count
        let average = correct == 0 ? 0 : pushTimes.reduce(0, +) / Double(correct)
        let accuracy = total == 0 ? 0 : Double(correct) / Double(total)
        let speed = correct == 0 ? 0 : max(0, 1 - average / 30)
        let score = 100 * accuracy * (0.75 + 0.25 * speed)
        let thresholds: [(Double, String)] = [(98,"S+"),(92,"S"),(88,"S-"),(84,"A+"),(80,"A"),(76,"A-"),(72,"B+"),(68,"B"),(64,"B-"),(60,"C+"),(56,"C"),(52,"C-"),(40,"D"),(20,"E")]
        return SoloResult(date: .now, playlist: playlist, total: total, correct: correct, averagePush: average, score: score, rank: thresholds.first { score >= $0.0 }?.1 ?? "F")
    }
}

struct ReviewSong: Codable, Identifiable {
    var song: Song
    var learned = false
    var savedAt = Date()
    var id: String { song.id }
}

struct GenreRecord: Codable {
    var attempts = 0
    var correct = 0
}

struct PlayerStats: Codable {
    var games = 0
    var attempts = 0
    var correct = 0
    var totalPushSeconds = 0.0
    var genres: [String: GenreRecord] = [:]
    var badges: Set<String> = []
    var selectedBadge: String? = nil

    var accuracy: Double { attempts == 0 ? 0 : Double(correct) / Double(attempts) }
    var averagePush: Double { attempts == 0 ? 0 : totalPushSeconds / Double(attempts) }

    mutating func awardBadges() {
        if games >= 1 { badges.insert("はじめの一歩") }
        if games >= 10 { badges.insert("常連プレイヤー") }
        if games >= 50 { badges.insert("歴戦のイントロ戦士") }
        if games >= 100 { badges.insert("クイズレジェンド") }
        if attempts >= 10 && averagePush <= 5 { badges.insert("早押し名人") }
        if attempts >= 25 && averagePush <= 3 { badges.insert("電光石火") }
        if attempts >= 20 && accuracy >= 0.8 { badges.insert("正答率エース") }
        if genres.values.contains(where: { $0.attempts >= 10 && Double($0.correct) / Double($0.attempts) >= 0.9 }) {
            badges.insert("ジャンルマスター")
        }
        if selectedBadge == nil { selectedBadge = badges.sorted().first }
    }
}
