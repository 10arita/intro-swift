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
        if Self.isPlayFlow(scenario)
          || scenario.hasPrefix("friends") || scenario.hasPrefix("account") {
          RootView(previewStep: scenario)
        } else if scenario.hasPrefix("solo-reveal") || scenario == "solo-answer" || scenario == "solo-result" {
          SoloGameView()
        } else if scenario.hasPrefix("rules-host") {
          RoomRuleSettingsView()
        } else if scenario.hasPrefix("rules-guest") {
          RoomRuleDetailsView(settings: model.roomSettings)
        } else {
          RoomGameView()
        }
      }
      .environmentObject(model)
      .environment(\.colorScheme, scenario.hasSuffix("-dark") ? .dark : .light)
      .environment(\.dynamicTypeSize, scenario.contains("large-text") ? .accessibility5 : .large)
    }

    private static func isPlayFlow(_ scenario: String) -> Bool {
      ["home", "mode", "room-selection", "code", "playlist"].contains {
        scenario == $0 || scenario.hasPrefix($0 + "-")
      }
    }

    @MainActor private static func makeModel(scenario: String) -> AppModel {
      let model = AppModel(serverURL: "http://127.0.0.1:1", chorusReportSender: { report, url in
        if scenario.contains("report-success") {
          try await Task.sleep(for: .seconds(2))
        } else {
          try await ChorusReportService().send(report, serverURL: url)
        }
      })
      if scenario.hasPrefix("account") { model.profileSyncStatus = CloudProfileError.notConfigured.localizedDescription }
      if scenario == "friends-request" || scenario == "friends-invite" {
        let request: [[String: Any]] = scenario == "friends-request" ? [[
          "id": "fixture-request", "fromId": "fixture-haru", "fromName": "はる",
          "roomId": "ABCDEF", "createdAt": 0,
        ]] : []
        let invites: [[String: Any]] = scenario == "friends-invite" ? [[
          "id": "fixture-invite", "fromId": "fixture-haru", "fromName": "はる",
          "roomId": "ABCDEF", "mode": "sabitro", "playerCount": 2, "createdAt": 0,
        ]] : []
        model.friendsState = try! JSONDecoder().decode(FriendsState.self,
          from: JSONSerialization.data(withJSONObject: ["friends": [], "requests": request, "invites": invites]))
      }
      let songs = ["青い空", "春風", "夜明け"].enumerated().map { index, title in
        Song(
          id: "demo:ui-\(index)", title: title, artist: "IntoL Studio", durationMS: 180_000,
          genre: "Pop")
      }
      if Self.isPlayFlow(scenario) {
        if scenario.hasPrefix("playlist"), !scenario.contains("connect") {
          model.appleMusicConnected = true
          model.appleMusicPlayable = true
          if !scenario.contains("empty") {
            model.appleMusicPlaylists = [
              AppleMusicPlaylist(id: "fixture-night", name: "夜に聴く曲"),
              AppleMusicPlaylist(id: "fixture-favorites", name: "お気に入りの曲"),
            ]
          }
          if scenario.contains("selected") {
            model.selectedAppleMusicPlaylistID = "fixture-night"
            model.appleMusicSongs = songs
          }
        }
        return model
      }
      if scenario.hasPrefix("friends") || scenario.hasPrefix("account") { return model }
      if scenario.hasPrefix("solo-reveal") || scenario == "solo-answer" || scenario == "solo-result" {
        var game = SoloGame(songs: songs, playlist: "夜に聴く曲")
        game.stage = scenario.hasPrefix("solo-reveal") ? .reveal : scenario == "solo-answer" ? .answering : .finished
        game.choices = ["青", "春", "夜", "花"]
        game.secondsLeft = 4.8
        model.game = game
        if game.stage == .reveal {
          model.recordRevealPlayback(game.current, source: .manualDatabase, startPositionMS: 48_681)
        }
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
      for index in 0..<(phase == "lobby" && !guest ? (scenario.contains("ready") ? 2 : 1) : 4) {
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
      rules.questionCount = scenario.contains("shortage") ? 6 : songs.count
      rules.handicaps = guest ? [ids[2]: 3] : nil
      if scenario.contains("unlimited") {
        rules.targetScore = 0
        rules.lives = 0
        rules.firstBonus = 0
        rules.wrongPenalty = 0
        rules.firstWrongPenalty = 0
      }
      model.roomSettings = rules
      model.appleMusicConnected = true
      model.appleMusicPlayable = true
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
        "playlist": empty ? NSNull() : ["name": "夜に聴く曲", "songCount": songs.count],
      ]
      if phase == "finished" || phase == "reveal" {
        state["current"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(songs[2]))
        state["roundSongs"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(songs))
      }
      model.room = try! JSONDecoder().decode(
        RoomState.self, from: JSONSerialization.data(withJSONObject: state))
      if phase == "reveal" {
        model.recordRevealPlayback(songs[2], source: .preview, startPositionMS: 0)
      }
      model.roomAnswer = "青"
      model.roomOptions = ["い", "の", "き", "と"]
      model.roomSecondsLeft = 4.8
      return model
    }
  }

  #Preview("ホスト待機室") { UIExamples(scenario: "lobby-host") }
  #Preview("プレイリスト未選択") { UIExamples(scenario: "lobby-empty") }
  #Preview("開始可能") { UIExamples(scenario: "lobby-ready") }
  #Preview("曲数不足") { UIExamples(scenario: "lobby-guest-shortage") }
  #Preview("待機室・大きな文字") { UIExamples(scenario: "lobby-guest-large-text") }
  #Preview("参加者・ダーク") { UIExamples(scenario: "lobby-guest-dark") }
  #Preview("ルール・制限なし") { UIExamples(scenario: "rules-host-unlimited") }
  #Preview("ルール説明・大きな文字") { UIExamples(scenario: "rules-host-unlimited-large-text") }
  #Preview("ルール詳細・ダーク") { UIExamples(scenario: "rules-guest-unlimited-dark") }
  #Preview("対戦中") { UIExamples(scenario: "answer") }
  #Preview("対戦中・ダーク") { UIExamples(scenario: "answer-dark") }
  #Preview("大きな文字") { UIExamples(scenario: "answer-large-text") }
  #Preview("報告・送信と完了") { UIExamples(scenario: "reveal-report-success") }
  #Preview("結果") { UIExamples(scenario: "result-dark") }
  #Preview("モード選択") { UIExamples(scenario: "mode") }
  #Preview("ルーム選択") { UIExamples(scenario: "room-selection") }
  #Preview("コード入力") { UIExamples(scenario: "code") }
  #Preview("Apple Music 接続") { UIExamples(scenario: "playlist-connect") }
  #Preview("プレイリスト選択") { UIExamples(scenario: "playlist") }
  #Preview("プレイリスト・曲プレビュー") { UIExamples(scenario: "playlist-selected") }
  #Preview("プレイリスト・空") { UIExamples(scenario: "playlist-empty") }
  #Preview("モード選択・大きな文字") { UIExamples(scenario: "mode-large-text") }
  #Preview("ルーム選択・ダーク") { UIExamples(scenario: "room-selection-dark") }
#endif
