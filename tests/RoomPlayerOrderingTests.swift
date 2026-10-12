import Foundation

@main private struct RoomPlayerOrderingTests {
    static func room(phase: String = "listening", pushOrder: [String]? = nil,
                     pushed: [String] = []) throws -> RoomState {
        var data: [String: Any] = [
            "id": "ABCDEF", "hostId": "a", "phase": phase, "mode": "applemusic",
            "round": 2, "totalRounds": 6, "serverNow": 0,
            "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(RoomSettings())),
            "players": ["d", "b", "a", "c"].map { id in [
                "id": id, "name": id,
                "score": ["a": 40, "b": 30, "c": 30, "d": 100][id]!,
                "lives": id == "b" ? 2 : 3,
                "pushTimeMS": id == "b" ? 500 : 2_000,
                "disqualified": id == "d", "connected": true, "isHost": id == "a",
            ] as [String: Any] },
            "pushClosed": false, "answerProgress": "", "options": [], "activeAnswers": [],
            "pushedIds": pushed, "skippedIds": [], "readyIds": [], "correctPlayerIDs": [],
        ]
        if let pushOrder { data["pushOrderIds"] = pushOrder }
        return try JSONDecoder().decode(RoomState.self, from: JSONSerialization.data(withJSONObject: data))
    }

    static func main() throws {
        let scoreOrder = ["a", "c", "b", "d"]
        let initial = try room(pushOrder: [])
        precondition(initial.rankedPlayers.map(\.id) == scoreOrder,
                     "Score ties use lives and disqualified players stay last")
        precondition(initial.statusPlayers().map(\.id) == scoreOrder,
                     "Before any PUSH, tiles use score order even if times remain in an older snapshot")
        precondition(initial.statusPlayers(pendingPushPlayerID: "c").map(\.id) == ["c", "a", "b", "d"],
                     "The local tile moves immediately while its first PUSH is pending")

        let answering = try room(phase: "answering", pushOrder: ["d", "b"], pushed: ["b"])
        precondition(answering.statusPlayers().map(\.id) == ["d", "b", "a", "c"],
                     "Use server arrival order, including rejected attempts, rather than timestamps or score")
        precondition(answering.statusPlayers(pendingPushPlayerID: "a").map(\.id) == ["d", "b", "a", "c"],
                     "Pending local PUSH follows server-confirmed attempts")
        precondition(answering.statusPlayers(pendingPushPlayerID: "b").map(\.id) == ["d", "b", "a", "c"],
                     "A received local PUSH must not duplicate or move its tile")
        precondition(answering.rankedPlayers.map(\.id) == scoreOrder,
                     "Reordering tiles must not change actual score ranks")

        let reveal = try room(phase: "reveal", pushOrder: ["b", "a"])
        precondition(reveal.statusPlayers().map(\.id) == ["b", "a", "c", "d"])
        let nextRound = try room(phase: "countdown", pushOrder: [])
        precondition(nextRound.statusPlayers().map(\.id) == scoreOrder,
                     "Clearing the previous round's PUSH order restores score order")
        let finished = try room(phase: "finished", pushOrder: ["b", "a"])
        precondition(finished.statusPlayers(pendingPushPlayerID: "c").map(\.id) == scoreOrder,
                     "Final results always show the score rankings")

        let olderServer = try room(pushed: ["b", "a"])
        precondition(olderServer.statusPlayers().map(\.id) == ["b", "a", "c", "d"],
                     "Servers without pushOrderIds fall back to accepted PUSH order")
        let duplicateOrDeparted = try room(pushOrder: ["departed", "b", "b", "a"])
        precondition(duplicateOrDeparted.statusPlayers().map(\.id) == ["b", "a", "c", "d"],
                     "Departed players and repeated IDs must not add duplicate tiles")
        print("Room player ordering tests passed")
    }
}
