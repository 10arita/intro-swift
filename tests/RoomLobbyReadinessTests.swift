import Foundation

@main private struct RoomLobbyReadinessTests {
    static func room(players: Int = 2, phase: String = "lobby", mode: String = "applemusic",
                     totalRounds: Int = 0, ready: [String]? = nil) throws -> RoomState {
        var data: [String: Any] = [
            "id": "ABCDEF", "hostId": "host", "phase": phase, "mode": mode,
            "round": -1, "totalRounds": totalRounds, "serverNow": 0,
            "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(RoomSettings())),
            "players": (0..<players).map { index in [
                "id": index == 0 ? "host" : "guest-\(index)", "name": "Player",
                "score": 0, "lives": 3, "disqualified": false, "connected": true, "isHost": index == 0,
            ] as [String: Any] },
            "pushClosed": false, "answerProgress": "", "options": [], "activeAnswers": [],
            "pushedIds": [], "skippedIds": [], "readyIds": [], "correctPlayerIDs": [],
        ]
        if let ready { data["assetsReadyIds"] = ready }
        return try JSONDecoder().decode(RoomState.self, from: JSONSerialization.data(withJSONObject: data))
    }

    static func main() throws {
        let settings = RoomSettings()
        let enough = RoomPlaylist(name: "Music", songCount: 6)
        let short = RoomPlaylist(name: "Music", songCount: 3)
        let single = try room(players: 1)
        precondition(single.startBlockReason(localID: "host", settings: settings, playlist: enough) != nil)
        let waiting = try room()
        precondition(waiting.startBlockReason(localID: "host", settings: settings, playlist: nil) != nil)
        precondition(waiting.startBlockReason(localID: "host", settings: settings, playlist: short) != nil)
        precondition(waiting.startBlockReason(localID: "host", settings: settings, playlist: enough) == nil)
        precondition(waiting.startBlockReason(localID: "guest-1", settings: settings, playlist: enough) != nil)
        var fewerQuestions = settings
        fewerQuestions.questionCount = 3
        precondition(waiting.startBlockReason(localID: "host", settings: fewerQuestions, playlist: short) == nil)
        let prepared = try room(totalRounds: 6, ready: ["host"])
        precondition(prepared.startBlockReason(localID: "host", settings: settings, playlist: enough) != nil)
        let restored = try room(totalRounds: 6, ready: ["host", "guest-1"])
        precondition(restored.startBlockReason(localID: "host", settings: settings, playlist: nil) == nil,
                     "Prepared rooms must not depend on the host's current playlist")
        let shared = try room(mode: "shared")
        precondition(shared.startBlockReason(localID: "host", settings: settings, playlist: nil) == nil)
        let playing = try room(phase: "listening")
        precondition(playing.startBlockReason(localID: "host", settings: settings, playlist: enough) != nil)
        precondition(waiting.exitExplanation(localID: "host").contains("引き継がれます"))
        precondition(!waiting.exitExplanation(localID: "guest-1").contains("引き継がれます"))
        precondition(single.exitExplanation(localID: "host").contains("閉じられます"))
        precondition(playing.exitExplanation(localID: "guest-1").contains("最終順位"))
        let oldInvite = Data(#"{"id":"invite","fromId":"host","fromName":"Host","roomId":"ABCDEF","mode":"applemusic","createdAt":0}"#.utf8)
        let decodedInvite = try JSONDecoder().decode(RoomInvite.self, from: oldInvite)
        precondition(decodedInvite.playerCount == nil,
                     "Invitation decoding must remain compatible with older servers")
        print("Room lobby readiness tests passed")
    }
}
