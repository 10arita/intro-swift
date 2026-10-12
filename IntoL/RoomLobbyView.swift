import SwiftUI

struct RoomLobbyView: View {
  @EnvironmentObject private var model: AppModel
  let room: RoomState
  let invite: () -> Void
  let handicap: () -> Void
  let profile: (RoomPlayer) -> Void
  @State private var showingRules = false
  @State private var showingSettings = false

  private var isHost: Bool { room.hostId == model.rooms.playerId }
  private var canEdit: Bool { isHost && room.totalRounds == 0 }
  private var settings: RoomSettings { canEdit ? model.roomSettings : room.settings }
  private var playlist: RoomPlaylist? { canEdit ? model.selectedRoomPlaylist : room.playlist }

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 8) {
        Text("対戦待機室")
          .font(.system(.title2, design: .rounded, weight: .bold))
          .foregroundStyle(Studio.primary)
        Text(room.players.count >= 4 ? "満員です · 開始を待っています" : "待機中 · あと\(4 - room.players.count)人参加できます")
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
        .disabled(room.players.count >= 4)
        if room.players.count >= 4 {
          Text("満員です。これ以上招待できません")
            .font(.caption).foregroundStyle(Studio.secondary)
        }
      }
      .foregroundStyle(Studio.primary)
      StudioCard {
        DisclosureGroup(isExpanded: $showingSettings) {
          VStack(alignment: .leading, spacing: 10) {
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
            if room.totalRounds == 0, let playlist, playlist.songCount < settings.questionCount {
              Label("\(settings.questionCount)問に対して\(playlist.songCount)曲です。曲を増やすか問題数を減らしてください", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Studio.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack(alignment: .top) {
              LobbySettingLabel(
                title: "ルール", symbol: "slider.horizontal.3",
                value:
                  "\(settings.questionCount)問 · ライフ\(RoomRule.lives.displayValue(settings.lives)) · \(settings.endless ? "エンドレス" : "解答権\(settings.answerSlots)人")"
              )
              Button(canEdit ? "変更" : "詳細") { showingRules = true }
                .buttonStyle(StudioButtonStyle(.tertiary))
                .frame(minWidth: 44)
                .disabled(model.busy)
                .accessibilityLabel(canEdit ? "対戦ルールを変更" : "対戦ルールの詳細")
            }
            Divider()
            HStack(alignment: .top) {
              LobbySettingLabel(title: "ハンデ", symbol: "timer", value: handicapSummary)
              if isHost {
                Button("変更", action: handicap)
                  .buttonStyle(StudioButtonStyle(.tertiary))
                  .frame(minWidth: 44)
                  .disabled(model.busy)
                  .accessibilityLabel("プレイヤーのハンデを変更")
              }
            }
          }
          .padding(.top, 12)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("対戦の設定").font(.headline)
              Spacer()
              if !isHost {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(Studio.secondary)
                  .accessibilityLabel("ホストの設定")
              } else if model.roomLobbySyncing {
                ProgressView().controlSize(.small).accessibilityLabel("設定を共有中")
              }
            }
            Text("\(playlist?.name ?? (room.mode == "shared" ? "IntoL デモ" : "プレイリスト未選択")) · \(settings.questionCount)問 · ライフ\(RoomRule.lives.displayValue(settings.lives))")
              .font(.subheadline).foregroundStyle(Studio.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if room.totalRounds == 0, let playlist, playlist.songCount < settings.questionCount {
              Label("曲数が足りません（\(playlist.songCount)曲）", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Studio.warning)
            }
          }
        }
        .foregroundStyle(Studio.primary)
        .tint(Studio.secondary)
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
      }
    }
    .sheet(isPresented: $showingRules) {
      if canEdit {
        RoomRuleSettingsView().environmentObject(model)
      } else {
        RoomRuleDetailsView(settings: settings)
      }
    }
    .task { model.scheduleRoomLobbySync() }
    .onAppear { showingSettings = playlist == nil && room.mode != "shared" }
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
    VStack(spacing: 8) {
      if !model.busy, let reason = model.roomStartBlockReason {
        Text(reason).font(.caption).foregroundStyle(Studio.secondary)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      PrimaryButton(
        title: model.busy ? "ゲームを準備中" : "ゲームを開始",
        symbol: "play.fill", disabled: model.busy || model.roomStartBlockReason != nil
      ) {
        model.beginGameStart()
        Task {
          await model.startRoom()
          model.finishGameStart()
        }
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
      Image(systemName: symbol).frame(width: 20).foregroundStyle(Studio.secondary).accessibilityHidden(
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let code: String
  @State private var copied = false
  var body: some View {
    VStack(spacing: 12) {
      SectionCaption(title: "ルームコード")
      Text(code)
        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
        .tracking(6)
        .foregroundStyle(Studio.primary)
        .lineLimit(1).minimumScaleFactor(0.6)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Studio.raised, in: Capsule())
        .accessibilityLabel("ルームコード \(code.map(String.init).joined(separator: " "))")
        .accessibilityIdentifier("lobby-room-code")
      let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
      layout {
        Button {
          UIPasteboard.general.string = code
          copied = true
        } label: {
          Label(copied ? "コピー済み" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
        .accessibilityIdentifier("copy-room-code")
        ShareLink(item: "IntoLでイントロ対戦しよう！\nルームコード: \(code)") {
          Label("共有", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
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
              VStack(spacing: 6) {
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
                Text(player.id == localID ? "あなた" : player.isHost ? "ホスト" : "参加者")
                  .font(.caption2.weight(.semibold)).foregroundStyle(Studio.secondary)
              }
              .frame(maxWidth: .infinity, minHeight: 96)
            }
            .buttonStyle(.plain)
            .contextMenu { RoomPlayerActions(player: player, friends: friends) }
            .accessibilityLabel("\(player.name)\(player.id == localID ? "、あなた" : "")\(player.isHost ? "、ホスト" : "")のプロフィール")
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
            index < room.players.count && room.players[index].id == localID ? Studio.secondary : Studio.line,
            style: StrokeStyle(lineWidth: index < room.players.count && room.players[index].id == localID ? 2 : 1,
                               dash: index < room.players.count ? [] : [5, 4])))
      }
    }
  }
}

struct RoomRuleDetailsView: View {
  @Environment(\.dismiss) private var dismiss
  let settings: RoomSettings
  @State private var ruleHelp: RoomRule?

  var body: some View {
    NavigationStack {
      List {
        Section("出題") {
          ruleRow(.questionCount, settings.questionCount)
          ruleRow(.answerSlots, settings.answerSlots, valueLabel: settings.endless ? "制限なし" : nil)
          ruleRow(.endless, settings.endless ? 1 : 0)
        }
        Section("得点とライフ") {
          ruleRow(.targetScore, settings.targetScore)
          ruleRow(.correctPoints, settings.correctPoints)
          ruleRow(.firstBonus, settings.firstBonus)
          ruleRow(.wrongPenalty, settings.wrongPenalty)
          ruleRow(.firstWrongPenalty, settings.firstWrongPenalty)
          ruleRow(.lives, settings.lives)
        }
        .listRowBackground(Studio.background)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Studio.background)
      .environment(\.defaultMinListRowHeight, 52)
      .navigationTitle("対戦ルール")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("完了") { dismiss() }
        }
      }
    }
    .modifier(RoomRuleHelpPresentation(rule: $ruleHelp))
  }

  private func ruleRow(_ rule: RoomRule, _ value: Int, valueLabel: String? = nil) -> some View {
    HStack {
      RoomRuleLabel(rule: rule) { ruleHelp = $0 }
      Spacer(minLength: 8)
      Text(valueLabel ?? rule.displayValue(value)).monospacedDigit().foregroundStyle(Studio.secondary)
    }
    .listRowBackground(Studio.background)
    .accessibilityElement(children: .contain)
  }
}

struct RoomRuleSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var ruleHelp: RoomRule?
  var body: some View {
    NavigationStack {
      Form {
        Section("出題") {
          RuleDialRow(
            rule: .questionCount, value: $model.roomSettings.questionCount, range: 1...50,
            onHelp: showHelp)
          RuleDialRow(
            rule: .answerSlots, value: $model.roomSettings.answerSlots, range: 1...4,
            disabled: model.roomSettings.endless,
            valueLabel: model.roomSettings.endless ? "制限なし" : nil, onHelp: showHelp)
          HStack {
            RoomRuleLabel(rule: .endless, onHelp: showHelp)
            Spacer(minLength: 8)
            Toggle("エンドレスモード", isOn: $model.roomSettings.endless).labelsHidden()
          }
        }
        Section("得点とライフ") {
          RuleDialRow(
            rule: .targetScore, value: $model.roomSettings.targetScore, range: 0...500, step: 10,
            onHelp: showHelp)
          RuleDialRow(
            rule: .correctPoints, value: $model.roomSettings.correctPoints, range: 10...50, step: 10,
            onHelp: showHelp)
          RuleDialRow(
            rule: .firstBonus, value: $model.roomSettings.firstBonus, range: 0...50, step: 10,
            onHelp: showHelp)
          RuleDialRow(
            rule: .wrongPenalty, value: $model.roomSettings.wrongPenalty, range: 0...50, step: 10,
            onHelp: showHelp)
          RuleDialRow(
            rule: .firstWrongPenalty, value: $model.roomSettings.firstWrongPenalty, range: 0...50, step: 10,
            onHelp: showHelp)
          RuleDialRow(rule: .lives, value: $model.roomSettings.lives, range: 0...10,
            onHelp: showHelp)
        }
      }
      .disabled(model.room?.phase != "lobby" || model.room?.hostId != model.rooms.playerId)
      .tint(Studio.accent)
      .navigationTitle("対戦ルール")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完了") { dismiss() } } }
    }
    .modifier(RoomRuleHelpPresentation(rule: $ruleHelp))
  }

  private func showHelp(_ rule: RoomRule) { ruleHelp = rule }
}
