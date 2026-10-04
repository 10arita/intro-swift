import SwiftUI

struct RoomLobbyView: View {
  @EnvironmentObject private var model: AppModel
  let room: RoomState
  let invite: () -> Void
  let handicap: () -> Void
  let profile: (RoomPlayer) -> Void
  @State private var showingRules = false

  private var isHost: Bool { room.hostId == model.rooms.playerId }
  private var canEdit: Bool { isHost && room.totalRounds == 0 }
  private var settings: RoomSettings { canEdit ? model.roomSettings : room.settings }
  private var playlist: RoomPlaylist? { canEdit ? model.selectedRoomPlaylist : room.playlist }

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 8) {
        Text(isHost ? "みんなを待っています" : "対戦待機室")
          .font(.system(.title2, design: .rounded, weight: .bold))
          .foregroundStyle(Studio.primary)
        Text(isHost ? "コードを共有して、友だちを招待しよう" : "ホストが開始するまでお待ちください")
          .font(.subheadline).foregroundStyle(Studio.secondary)
          .multilineTextAlignment(.center)
      }
      RoomInvitationCard(code: room.id)
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("参加プレイヤー").font(.headline)
          Spacer()
          Text("\(room.players.count) / 4人").font(.subheadline.monospacedDigit())
            .foregroundStyle(Studio.secondary)
        }
        LobbyPlayerSlots(
          room: room, localID: model.rooms.playerId,
          avatarData: model.avatarData, profile: profile, friends: invite)
        Button(action: invite) {
          Label("フレンドを招待", systemImage: "person.crop.circle.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
        .disabled(room.players.count == 4)
      }
      .foregroundStyle(Studio.primary)
      StudioCard {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text("対戦の設定").font(.headline)
            Spacer()
            if !isHost {
              Label("ホストの設定", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(Studio.secondary)
            } else if model.roomLobbySyncing {
              ProgressView().controlSize(.small).accessibilityLabel("設定を共有中")
            }
          }
          if canEdit && room.mode != "shared" {
            DisclosureGroup {
              if !model.appleMusicConnected {
                Button("Apple Music に接続") { Task { await model.connectAppleMusic() } }
                  .buttonStyle(StudioButtonStyle(.secondary))
              } else if model.appleMusicPlaylists.isEmpty {
                Button("プレイリストを読み込む") { Task { await model.loadAppleMusicPlaylists() } }
                  .buttonStyle(StudioButtonStyle(.secondary))
              } else {
                Picker("プレイリスト", selection: $model.selectedAppleMusicPlaylistID) {
                  Text("選択してください").tag("")
                  ForEach(model.appleMusicPlaylists) { list in Text(list.name).tag(list.id) }
                }
                .pickerStyle(.menu)
                .onChange(of: model.selectedAppleMusicPlaylistID) { _, id in
                  Task { await model.selectAppleMusicPlaylist(id) }
                }
              }
            } label: {
              LobbySettingLabel(
                title: "プレイリスト", symbol: "music.note.list",
                value: playlist?.name ?? "未選択")
            }
            .disabled(model.busy)
          } else {
            LobbySettingLabel(
              title: "プレイリスト", symbol: "music.note.list",
              value: room.mode == "shared" ? "IntoL デモ" : playlist?.name ?? "ホストが選択中")
          }
          if let playlist, playlist.songCount > 0 {
            Text("\(playlist.songCount)曲").font(.caption).foregroundStyle(Studio.secondary)
          }
          Divider()
          HStack(alignment: .top) {
            LobbySettingLabel(
              title: "ルール", symbol: "slider.horizontal.3",
              value:
                "\(settings.questionCount)問 · \(settings.endless ? "エンドレス" : "解答権\(settings.answerSlots)人")"
            )
            if canEdit {
              Button("変更") { showingRules = true }
                .buttonStyle(StudioButtonStyle(.tertiary))
                .disabled(model.busy)
                .accessibilityLabel("対戦ルールを変更")
            }
          }
          RoomRuleSummary(settings: settings)
          Divider()
          HStack(alignment: .top) {
            LobbySettingLabel(title: "ハンデ", symbol: "timer", value: handicapSummary)
            if isHost {
              Button("変更", action: handicap)
                .buttonStyle(StudioButtonStyle(.tertiary))
                .disabled(model.busy)
                .accessibilityLabel("プレイヤーのハンデを変更")
            }
          }
        }
        .foregroundStyle(Studio.primary)
        .tint(Studio.accent)
      }
      if isHost {
        if room.players.count > 1 {
          Menu {
            ForEach(room.players.filter { $0.id != model.rooms.playerId }) { player in
              Button(player.name) {
                Task { await model.roomAction("transfer", payload: ["targetId": player.id]) }
              }
            }
          } label: {
            Label("ホストを譲る", systemImage: "person.crop.circle.badge.checkmark")
          }
          .buttonStyle(StudioButtonStyle(.tertiary))
          .disabled(model.busy)
        }
      } else {
        Label("ホストがゲームを開始します", systemImage: "hourglass")
          .font(.subheadline).foregroundStyle(Studio.secondary)
      }
    }
    .sheet(isPresented: $showingRules) { RoomRuleSettingsView().environmentObject(model) }
    .task { model.scheduleRoomLobbySync() }
    .onChange(of: model.roomSettings) { _, _ in model.scheduleRoomLobbySync() }
    .onChange(of: model.selectedRoomPlaylist) { _, _ in model.scheduleRoomLobbySync() }
    .onChange(of: room.hostId) { _, _ in model.scheduleRoomLobbySync() }
  }

  private var handicapSummary: String {
    let values = room.players.compactMap { player -> String? in
      let seconds = room.settings.handicapSeconds(for: player.id)
      return seconds > 0 ? "\(player.name) \(seconds)秒" : nil
    }
    return values.isEmpty ? "なし" : values.joined(separator: " · ")
  }
}

struct RoomLobbyStartButton: View {
  @EnvironmentObject private var model: AppModel
  var body: some View {
    PrimaryButton(
      title: model.busy ? "ゲームを準備中" : model.roomPlaylistReady ? "ゲームを開始" : "プレイリストを選んでください",
      symbol: "play.fill", disabled: model.busy || !model.roomPlaylistReady
    ) {
      model.beginGameStart()
      Task {
        await model.startRoom()
        model.finishGameStart()
      }
    }
  }
}

private struct LobbySettingLabel: View {
  let title: String
  let symbol: String
  let value: String
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).frame(width: 20).foregroundStyle(Studio.accent).accessibilityHidden(
        true)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.caption).foregroundStyle(Studio.secondary)
        Text(value).font(.subheadline.weight(.semibold)).fixedSize(
          horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

struct RoomInvitationCard: View {
  let code: String
  @State private var copied = false
  var body: some View {
    VStack(spacing: 12) {
      SectionCaption(title: "ROOM CODE")
      Button {
        UIPasteboard.general.string = code
        copied = true
      } label: {
        RoomCodeBoxes(code: code).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("ルームコード \(code.map(String.init).joined(separator: " "))")
      .accessibilityHint("タップでコピー")
      .accessibilityIdentifier("lobby-room-code")
      HStack(spacing: 16) {
        Label(copied ? "コピーしました" : "タップでコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
          .font(.caption).foregroundStyle(copied ? Studio.success : Studio.secondary)
        Spacer(minLength: 0)
        ShareLink(item: "IntoLでイントロ対戦しよう！\nルームコード: \(code)") {
          Label("共有", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(StudioButtonStyle(.tertiary))
      }
    }
    .sensoryFeedback(.success, trigger: copied) { _, new in new }
    .task(id: copied) {
      guard copied else { return }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      copied = false
    }
  }
}

private struct LobbyPlayerSlots: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let room: RoomState
  let localID: String
  let avatarData: Data?
  let profile: (RoomPlayer) -> Void
  let friends: () -> Void
  var body: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 8
    ) {
      ForEach(0..<4, id: \.self) { index in
        VStack(spacing: 10) {
          if index < room.players.count {
            let player = room.players[index]
            Button {
              profile(player)
            } label: {
              VStack(spacing: 10) {
                PlayerAvatarView(
                  data: player.id == localID ? avatarData : nil, size: 52, encoded: player.avatar
                )
                .overlay(alignment: .bottomTrailing) {
                  if player.isHost {
                    Image(systemName: "crown.fill").font(.caption2)
                      .foregroundStyle(Studio.accent).padding(4)
                      .background(Studio.surface, in: Circle())
                  }
                }
                Text(player.name).font(.caption.weight(.semibold)).lineLimit(2)
                  .foregroundStyle(Studio.primary)
              }
              .frame(maxWidth: .infinity, minHeight: 96)
            }
            .buttonStyle(.plain)
            .contextMenu { RoomPlayerActions(player: player, friends: friends) }
            .accessibilityLabel("\(player.name)\(player.isHost ? "、ホスト" : "")のプロフィール")
          } else {
            Image(systemName: "person.badge.plus")
              .font(.title2).foregroundStyle(Studio.secondary)
              .frame(width: 52, height: 52)
            Text("招待待ち").font(.caption).foregroundStyle(Studio.secondary)
          }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(
          index < room.players.count ? Studio.surface : Studio.background,
          in: RoundedRectangle(cornerRadius: Studio.Radius.md)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Studio.Radius.md).strokeBorder(
            Studio.line,
            style: StrokeStyle(lineWidth: 1, dash: index < room.players.count ? [] : [5, 4])))
      }
    }
  }
}

private struct RoomRuleSummary: View {
  let settings: RoomSettings
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        "勝利目標 \(settings.targetScore == 0 ? "なし" : "\(settings.targetScore)点") · ライフ \(settings.lives == 0 ? "無制限" : "\(settings.lives)")"
      )
      Text("正解 \(settings.correctPoints)点 · 1st正解 +\(settings.firstBonus)点")
      Text("誤答 −\(settings.wrongPenalty)点 · 1st誤答 −\(settings.firstWrongPenalty)点")
    }
    .font(.caption).foregroundStyle(Studio.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct RoomRuleSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("出題") {
          RuleDialRow(
            title: "問題数", value: $model.roomSettings.questionCount, range: 1...50, suffix: "問")
          RuleDialRow(
            title: "解答権人数", value: $model.roomSettings.answerSlots, range: 1...4, suffix: "人",
            disabled: model.roomSettings.endless)
          Toggle("エンドレスモード", isOn: $model.roomSettings.endless)
        }
        Section("得点とライフ") {
          RuleDialRow(
            title: "勝利目標", value: $model.roomSettings.targetScore, range: 0...500, step: 10,
            suffix: "点")
          RuleDialRow(
            title: "正解", value: $model.roomSettings.correctPoints, range: 10...50, step: 10,
            suffix: "点")
          RuleDialRow(
            title: "1st正解", value: $model.roomSettings.firstBonus, range: 0...50, step: 10,
            prefix: "+", suffix: "点")
          RuleDialRow(
            title: "誤答", value: $model.roomSettings.wrongPenalty, range: 0...50, step: 10,
            prefix: "−", suffix: "点")
          RuleDialRow(
            title: "1st誤答", value: $model.roomSettings.firstWrongPenalty, range: 0...50, step: 10,
            prefix: "−", suffix: "点")
          RuleDialRow(title: "ライフ", value: $model.roomSettings.lives, range: 0...10)
          Text("勝利目標0点は目標なし、ライフ0は無制限です。")
            .font(.caption).foregroundStyle(Studio.secondary)
        }
      }
      .disabled(model.room?.phase != "lobby" || model.room?.hostId != model.rooms.playerId)
      .tint(Studio.accent)
      .navigationTitle("対戦ルール")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完了") { dismiss() } } }
    }
  }
}
