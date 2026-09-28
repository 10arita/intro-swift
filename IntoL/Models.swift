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
        let mapped = title.precomposedStringWithCompatibilityMapping
        let value = mapped.replacingOccurrences(of: #"(?i)(-|\(|(?<![A-Za-z])feat(?![A-Za-z])).*$"#, with: "", options: .regularExpression).uppercased()
        return String(value.unicodeScalars.filter { scalar in
            let code = scalar.value
            return (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A)
                || (code >= 0x3040 && code <= 0x30FA) || (code >= 0x30FC && code <= 0x30FF)
                || (code >= 0x3400 && code <= 0x9FFF) || code == 0x3005 || code == 0x3006
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
    static func choices(answer: String, prefix: String, corpus: [String], artistTopTitles: [String] = [], currentTitle: String = "") -> [String] {
        let type = kind(answer)
        var distractors: [String] = []
        func add(_ candidates: [String]) {
            for char in candidates where char != answer && !forbidden.contains(char) && !distractors.contains(char) {
                distractors.append(char)
                if distractors.count == 3 { return }
            }
        }
        if prefix.isEmpty {
            add(artistTopTitles.prefix(6).filter { normalized($0) != normalized(currentTitle) }
                .compactMap { characters($0).first }.shuffled())
        } else {
            let titles = (corpus + famousTitles).map(characters)
            let used = prefix.count
            add(titles.compactMap { chars in
                chars.count > used && chars.prefix(used).joined() == prefix ? chars[used] : nil
            }.shuffled())
            if distractors.count < 3 {
                let prev = String(prefix.suffix(1))
                var frequency: [String: Int] = [:]
                for chars in titles where chars.count > 1 {
                    for index in 0..<(chars.count - 1) where chars[index] == prev {
                        frequency[chars[index + 1], default: 0] += 1
                    }
                }
                add(frequency.keys.shuffled().sorted { frequency[$0, default: 0] > frequency[$1, default: 0] })
            }
        }
        if distractors.count < 3 {
            let pools = [
                "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん",
                "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン",
                "愛光音海風春夏秋冬君夢星夜花青空雨雪月道心時人世界日明白山川新未来恋歌声虹",
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "0123456789"
            ]
            add(pools[type].map(String.init).shuffled())
        }
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
