#if DEBUG
  import SwiftUI

  /// Offline fixtures for Xcode previews and Simulator layout checks.
  struct UIExamples: View {
    let scenario: String
    @StateObject private var model: AppModel

    init(scenario: String) {
      self.scenario = scenario
      _model = StateObject(wrappedValue: Self.makeModel(scenario: scenario))
    }

    var body: some View {
      Group {
        if scenario == "solo-answer" || scenario == "solo-result" {
          SoloGameView()
        } else {
          RoomGameView()
        }
      }
      .environmentObject(model)
      .environment(\.colorScheme, scenario.hasSuffix("-dark") ? .dark : .light)
      .environment(\.dynamicTypeSize, scenario.contains("large-text") ? .accessibility5 : .large)
    }

    @MainActor private static func makeModel(scenario: String) -> AppModel {
      let model = AppModel()
      let songs = ["青い空", "春風", "夜明け"].enumerated().map { index, title in
        Song(
          id: "demo:ui-\(index)", title: title, artist: "IntoL Studio", durationMS: 180_000,
          genre: "Pop")
      }
      if scenario == "solo-answer" || scenario == "solo-result" {
        var game = SoloGame(songs: songs, playlist: "夜に聴く曲")
        game.stage = scenario == "solo-answer" ? .answering : .finished
        game.choices = ["青", "春", "夜", "花"]
        game.secondsLeft = 4.8
        model.game = game
        model.lastResult = SoloResult.make(
          playlist: game.playlist, total: 3, pushTimes: [1.2, 2.4],
          rounds: songs.enumerated().map {
            SoloRoundResult(
              song: $0.element, correct: $0.offset < 2,
              pushTime: $0.offset < 2 ? 1.2 : nil)
          })
        return model
      }
      let guest = scenario.contains("guest")
      let empty = scenario.contains("empty")
      let phase =
        scenario.contains("answer")
        ? "answering"
        : scenario.contains("result")
          ? "finished" : scenario.contains("reveal") ? "reveal" : "lobby"
      let localID = model.rooms.playerId
      let hostID = guest ? "fixture-host" : localID
      let ids = [localID, "fixture-b", "fixture-c", "fixture-d"]
      let names = [model.nickname, "はる", "あおい", "ゆう"]
      var players: [[String: Any]] = []
      for index in 0..<(phase == "lobby" && !guest ? 1 : 4) {
        var player: [String: Any] = [
          "id": ids[index], "name": names[index], "lives": 3,
          "disqualified": false, "connected": true,
        ]
        player["score"] = phase == "lobby" ? 0 : [40, 30, 20, 10][index]
        player["correctCount"] = 2
        player["wrongCount"] = 1
        player["roundResults"] = ["correct", "correct", "wrong"]
        if phase != "lobby" && !(phase == "answering" && (index == 0 || index == 3)) {
          player["currentResult"] = index < 2 ? "correct" : "wrong"
        }
        if phase != "lobby" && !(phase == "answering" && index == 3) {
          player["pushTimeMS"] = [1234, 1567, 2345, 3456][index]
        }
        player["isHost"] = index == (guest ? 1 : 0)
        players.append(player)
      }
      var rules = model.roomSettings
      rules.handicaps = guest ? [ids[2]: 3] : nil
      model.roomSettings = rules
      model.appleMusicConnected = true
      model.appleMusicPlaylists = [AppleMusicPlaylist(id: "fixture", name: "夜に聴く曲")]
      if !empty {
        model.selectedAppleMusicPlaylistID = "fixture"
        model.appleMusicSongs = songs
      }
      var state: [String: Any] = [
        "id": "ABCDEF", "mode": "applemusic", "hostId": guest ? ids[1] : hostID,
        "phase": phase, "round": phase == "lobby" ? -1 : 2, "totalRounds": phase == "lobby" ? 0 : 3,
        "gameNumber": 0,
        "settings": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)),
        "players": players, "serverNow": Date.now.timeIntervalSince1970 * 1000, "pushClosed": true,
        "answerProgress": "青", "options": ["い", "の", "き", "と"],
        "activeAnswers": phase == "answering" ? [["playerId": localID, "progress": "青"]] : [],
        "pushedIds": phase == "lobby" ? [] : Array(ids.prefix(phase == "answering" ? 3 : 4)),
        "skippedIds": phase == "lobby" ? [] : [ids[3]],
        "readyIds": [], "correctPlayerIDs": phase == "reveal" ? [localID, ids[1]] : [],
        "supportsLobbyConfiguration": false,
        "playlist": empty ? NSNull() : ["name": "夜に聴く曲", "songCount": 3],
      ]
      if phase == "finished" || phase == "reveal" {
        state["current"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(songs[2]))
        state["roundSongs"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(songs))
      }
      model.room = try! JSONDecoder().decode(
        RoomState.self, from: JSONSerialization.data(withJSONObject: state))
      model.roomAnswer = "青"
      model.roomOptions = ["い", "の", "き", "と"]
      model.roomSecondsLeft = 4.8
      return model
    }
  }

  #Preview("ホスト待機室") { UIExamples(scenario: "lobby-host") }
  #Preview("プレイリスト未選択") { UIExamples(scenario: "lobby-empty") }
  #Preview("参加者・ダーク") { UIExamples(scenario: "lobby-guest-dark") }
  #Preview("対戦中") { UIExamples(scenario: "answer") }
  #Preview("対戦中・ダーク") { UIExamples(scenario: "answer-dark") }
  #Preview("大きな文字") { UIExamples(scenario: "answer-large-text") }
  #Preview("結果") { UIExamples(scenario: "result-dark") }
#endif
