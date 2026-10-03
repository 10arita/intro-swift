import Foundation

@main private struct RoomCodeTests {
    static func main() {
        precondition(RoomCode.normalizedInput("gkpzqy") == "GKPZQY")
        precondition(RoomCode.normalizedInput("ｇｋｐｚｑｙ") == "GKPZQY")
        precondition(RoomCode.normalizedInput("g1k-p zqy!") == "GKPZQY")
        precondition(RoomCode.isValid("GKPZQY"))
        for invalid in ["", "GKPZQ", "GKPZQYA", "gkpzqy", "123456", "GKＰZQY"] {
            precondition(!RoomCode.isValid(invalid), "Reject invalid room code: \(invalid)")
        }
        for text in ["GKPZQY", " gkpzqy\n", "G K P Z Q Y", "ルームコード: GKPZQY",
                     "一緒に遊ぼう！\nルームコード：ＧＫＰＺＱＹ\nIntoLで参加してね", "Room code: gkpzqy"] {
            precondition(RoomCode.pastedCode(in: text) == "GKPZQY", "Parse invitation: \(text)")
        }
        for invalid in ["123456", "GKPZQYA", "GKPZQY1", "ルームコード: GKPZQYA",
                        "ルームコード: GKPZQY1", "ルームコード: GKPZQ", "関係のない文章", "ROOM CODE: GKP-ZQY"] {
            precondition(RoomCode.pastedCode(in: invalid) == nil, "Do not truncate invalid paste: \(invalid)")
        }
        print("Room code tests passed")
    }
}
