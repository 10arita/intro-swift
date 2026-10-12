import CloudKit
import MediaPlayer
import PhotosUI
import SwiftUI

private struct RoomExitConfirmation: View {
  let isPresented: Bool
  let isLeaving: Bool
  let explanation: String
  let onCancel: () -> Void
  let onLeave: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AccessibilityFocusState private var titleFocused: Bool

  var body: some View {
    ZStack {
      if isPresented {
        Color.black.opacity(0.32)
          .ignoresSafeArea()
          .onTapGesture { if !isLeaving { onCancel() } }
          .accessibilityHidden(true)
          .transition(.opacity)
        VStack(spacing: 24) {
          Text("ルームを退室しますか？")
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(Studio.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($titleFocused)
          Text(explanation)
            .font(.subheadline).foregroundStyle(Studio.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
          VStack(spacing: 12) {
            Button(role: .cancel, action: onCancel) {
              Text("キャンセル").frame(maxWidth: .infinity)
            }
              .buttonStyle(StudioButtonStyle(.primary))
              .keyboardShortcut(.cancelAction)
            Button(role: .destructive, action: onLeave) {
              HStack(spacing: 10) {
                if isLeaving { ProgressView().tint(Studio.accent) }
                Text(isLeaving ? "退室しています…" : "退室する")
                  .font(.headline)
              }
              .foregroundStyle(Studio.accent)
              .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(StudioButtonStyle(.destructive))
          }
          .disabled(isLeaving)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.lg))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-exit-confirmation")
        .accessibilityAction(.escape) { if !isLeaving { onCancel() } }
        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
        .onAppear { titleFocused = true }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(isPresented)
  }
}

struct RoomGameView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showVolumeSettings = false
  @State private var showFriends = false
  @State private var showHandicapSettings = false
  @State private var selectedProfile: PlayerProfileTarget?
  @State private var showLeaveConfirmation = false
  @State private var leavingRoom = false

  var body: some View {
    ZStack {
      Studio.background.ignoresSafeArea()
      if let room = model.room {
        GeometryReader { geometry in
          let compact = geometry.size.height < 700
          VStack(spacing: 0) {
            HStack {
              Button {
                setLeaveConfirmation(true)
              } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Studio.primary)
                  .frame(width: 44, height: 44).background(Studio.surface, in: Circle())
              }
              .accessibilityLabel("ルームを退出")
              Spacer()
              if room.phase != "lobby" {
                Text(room.id)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Studio.secondary)
                .textSelection(.enabled)
                Button {
                  showFriends = true
                } label: {
                  Image(systemName: "person.2")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Studio.primary)
                    .frame(width: 44, height: 44)
                    .background(Studio.surface, in: Circle())
                }
                .accessibilityLabel("フレンドと招待")
              }
              GameVolumeButton { showVolumeSettings = true }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            ScrollView {
              VStack(spacing: 0) {
                if room.phase != "lobby" {
                  Text("プレイヤー").font(.caption.weight(.semibold)).foregroundStyle(Studio.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 20)
                  RoomPlayerStandings(
                    room: room, localID: model.rooms.playerId,
                    avatarData: model.avatarData, pushPending: model.roomPushPending,
                    pendingPushTimeMS: model.roomPendingPushTimeMS,
                    profile: { player in
                      selectedProfile = PlayerProfileTarget(
                        id: player.id, name: player.name, roomID: room.id)
                    }, friends: { showFriends = true }
                  )
                  .padding(.horizontal, 16).padding(.vertical, 8)
                }
                VStack(spacing: compact ? 8 : 12) {
                  if room.phase == "lobby" {
                    RoomLobbyView(
                      room: room, invite: { showFriends = true },
                      handicap: { showHandicapSettings = true },
                      profile: { player in
                        selectedProfile = PlayerProfileTarget(
                          id: player.id, name: player.name, roomID: room.id)
                      }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                  } else if room.phase == "preparing" {
                    roundTitle(room)
                    ProgressView().tint(Studio.accent).scaleEffect(1.5)
                    Text("音源を準備中")
                      .font(.system(size: 30, weight: .bold, design: .rounded))
                      .foregroundStyle(Studio.primary)
                    Text("\(room.readyIds.count) / \(room.players.count) 人の準備が完了")
                      .foregroundStyle(Studio.secondary)
                    if model.roomError != nil {
                      Button("準備を再試行") { model.retryRoomRound() }
                        .buttonStyle(StudioButtonStyle(.secondary))
                    }
                  } else if room.phase == "countdown" {
                    roundTitle(room)
                    WaveMark()
                    Text("第\(room.round + 1)問目")
                      .font(.system(size: 32, weight: .bold, design: .rounded))
                      .foregroundStyle(Studio.primary)
                    Text("\(max(1, Int(ceil(model.roomSecondsLeft - 30))))")
                      .font(.system(size: 42, weight: .bold, design: .rounded))
                      .foregroundStyle(Studio.accent)
                    Text("端末の音量を確認してください")
                      .foregroundStyle(Studio.secondary)
                    if model.roomError != nil {
                      Button("再生を再試行") { model.retryRoomAudio() }
                        .buttonStyle(StudioButtonStyle(.secondary))
                    }
                  } else if ["listening", "answering"].contains(room.phase)
                    || model.roomChoiceFeedback != nil
                  {
                    roundTitle(room)
                    if room.isAnswering(model.rooms.playerId) || model.roomChoiceFeedback != nil {
                      SectionCaption(title: "YOUR TURN")
                      AnswerText(
                        answer: model.roomChoiceFeedback?.answerBeforeChoice ?? model.roomAnswer)
                      CountdownBar(
                        remaining: model.roomSecondsLeft, total: 5, compact: true,
                        hapticsEnabled: !model.roomChoicePending && model.roomChoiceFeedback == nil)
                      ChoiceGrid(
                        choices: model.roomOptions,
                        action: { choice in
                          Task { await model.roomAction("choose", payload: ["choice": choice]) }
                        }, compact: true, feedback: model.roomChoiceFeedback
                      )
                      .disabled(model.roomChoicePending || model.roomChoiceFeedback != nil)
                    } else if room.phase == "answering"
                      && (room.settings.endless || room.pushClosed)
                    {
                      watchingStage(room, compact: compact)
                    } else {
                      listeningStage(room, compact: compact)
                    }
                    skipButton(room)
                    if model.roomError != nil && room.pausedAt == nil && !room.questionAudioClosed
                      && !room.isAnswering(model.rooms.playerId)
                    {
                      Button("再生を再試行") { model.retryRoomAudio() }
                        .buttonStyle(StudioButtonStyle(.secondary))
                    }
                  } else if room.phase == "reveal" {
                    roomReveal(room)
                    if model.roomError != nil {
                      Button("再生を再試行") { model.retryRoomRevealAudio() }
                        .buttonStyle(StudioButtonStyle(.secondary))
                    }
                    if room.hostId == model.rooms.playerId {
                      PrimaryButton(title: "次の曲へ", symbol: "arrow.right") {
                        Task { await model.roomAction("next") }
                      }
                    } else {
                      Text("ホストが次の曲に進めます")
                        .font(.subheadline).foregroundStyle(Studio.secondary)
                    }
                  } else if room.phase == "finished" {
                    RoomResultSummary(
                      room: room, playerID: model.rooms.playerId, playerName: model.nickname
                    )
                    .padding(.bottom, 12)
                    PrimaryButton(
                      title: "ルームに戻る", symbol: "arrow.uturn.backward",
                      disabled: room.hostId != model.rooms.playerId || model.roomRematchPending
                    ) {
                      Task { await model.rematchRoom() }
                    }
                    if model.roomRematchPending {
                      ProgressView("ルームに戻っています")
                        .tint(Studio.accent)
                    } else if room.hostId != model.rooms.playerId {
                      Text("ホストがルームに戻ると待機画面に戻ります")
                        .font(.subheadline).foregroundStyle(Studio.secondary)
                    }
                    PrimaryButton(title: "ホームへ戻る", symbol: "house") {
                      Task { await model.leaveRoom() }
                    }
                  }
                  if let error = model.roomError {
                    Text(error).font(.caption).foregroundStyle(Studio.warning)
                  }
                  if let notice = model.roomNotice {
                    Text(notice)
                      .font(.subheadline.weight(.semibold))
                      .foregroundStyle(Studio.primary)
                      .multilineTextAlignment(.center)
                      .padding(.horizontal, 12)
                      .padding(.vertical, 8)
                      .background(
                        Studio.raised, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
                  }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, compact ? 8 : 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
              }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
              if room.phase == "lobby" {
                LinearGradient(colors: [Studio.background.opacity(0), Studio.background],
                               startPoint: .top, endPoint: .bottom)
                  .frame(height: 24).allowsHitTesting(false).accessibilityHidden(true)
              }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
              if room.phase == "lobby" { lobbyFooter(room) }
            }
            .animation(
              reduceMotion || room.isAnswering(model.rooms.playerId) ? nil : Studio.spring,
              value: room.phase)
          }
        }
      }
    }
    .modifier(ChoiceFeedbackPresentation(feedback: model.roomChoiceFeedback))
    .overlay {
      if showFriends {
        FriendsView(inRoom: true, onClose: { showFriends = false })
          .environmentObject(model)
          .background(Studio.background.ignoresSafeArea())
      }
    }
    .allowsHitTesting(!showLeaveConfirmation)
    .accessibilityElement(children: .contain)
    .accessibilityHidden(showLeaveConfirmation)
    .overlay {
      RoomExitConfirmation(
        isPresented: showLeaveConfirmation, isLeaving: leavingRoom,
        explanation: model.room?.exitExplanation(localID: model.rooms.playerId) ?? "",
        onCancel: { setLeaveConfirmation(false) }, onLeave: confirmLeaveRoom)
    }
    .modifier(ChorusReportPresentation())
    .sheet(isPresented: $showVolumeSettings) {
      GameVolumeSettingsSheet()
        .environmentObject(model)
    }
    .sheet(isPresented: $showHandicapSettings) {
      RoomHandicapSettingsView()
        .environmentObject(model)
    }
    .sheet(item: $selectedProfile) { target in
      PlayerProfileSheet(target: target).environmentObject(model)
    }
  }

  private func lobbyFooter(_ room: RoomState) -> some View {
    VStack(spacing: 8) {
      if room.hostId == model.rooms.playerId {
        if let progress = model.roomStartProgress {
          PreparationProgressView(status: model.preparationStatus ?? "ゲームを準備中", progress: progress)
        }
        RoomLobbyStartButton()
      } else {
        HStack(spacing: 10) {
          if reduceMotion { Image(systemName: "hourglass").accessibilityHidden(true) }
          else { ProgressView().tint(Studio.secondary).accessibilityHidden(true) }
          Text("ホストの開始を待っています…")
            .font(.subheadline).foregroundStyle(Studio.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      }
    }
    .frame(maxWidth: 560).padding(.horizontal, 20).padding(.vertical, 12)
    .frame(maxWidth: .infinity).background(Studio.background)
  }

  private func setLeaveConfirmation(_ presented: Bool) {
    guard !leavingRoom else { return }
    withAnimation(
      reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)
    ) {
      showLeaveConfirmation = presented
    }
  }

  private func confirmLeaveRoom() {
    guard !leavingRoom else { return }
    leavingRoom = true
    Task { @MainActor in
      await model.leaveRoom()
      leavingRoom = false
      setLeaveConfirmation(false)
    }
  }

  private func roundTitle(_ room: RoomState) -> some View {
    SectionCaption(title: "ROUND \(room.round + 1) / \(room.totalRounds)")
  }

  private func listeningStage(_ room: RoomState, compact: Bool) -> some View {
    VStack(spacing: compact ? 8 : 12) {
      if !model.roomAudioStarted {
        ProgressView().tint(Studio.accent).scaleEffect(1.5)
        Text("音源を読み込み中")
          .font(.title2.bold()).foregroundStyle(Studio.primary)
        if model.roomError != nil {
          Button("再生を再試行") { model.retryRoomAudio() }
            .buttonStyle(StudioButtonStyle(.secondary))
        }
      } else {
        WaveMark(isPlaying: room.pausedAt == nil && !room.questionAudioClosed)
        Text("この曲は？")
          .font(.system(size: compact ? 26 : 30, weight: .bold, design: .rounded))
          .foregroundStyle(Studio.primary)
        CountdownBar(
          remaining: model.roomSecondsLeft, total: 30, compact: true,
          hapticsEnabled: room.pausedAt == nil && !room.questionAudioClosed)
        if !room.activeAnswers.isEmpty {
          Text(
            "\(room.activeAnswers.compactMap { room.player($0.playerId)?.name }.joined(separator: "・")) が解答中"
          )
          .font(.headline)
          .foregroundStyle(Studio.accent)
          .lineLimit(1)
        }
        if room.settings.endless {
          Text("エンドレスモード・誤答: \(room.pushedIds.count) / \(room.players.count)人")
            .font(.caption).foregroundStyle(Studio.secondary)
        } else {
          Text(
            "解答受付: \(room.pushedIds.count) / \(room.settings.answerSlots)人（残り\(max(0, room.settings.answerSlots - room.pushedIds.count))人）"
          )
          .font(.caption).foregroundStyle(Studio.secondary)
        }
        if room.player(model.rooms.playerId)?.disqualified == true {
          Text("今回は観戦中です").foregroundStyle(Studio.secondary)
        } else if room.answerStatus == "correct" {
          Text("正解入力済みです。受付終了を待っています")
            .foregroundStyle(Studio.accent)
        } else if room.pushedIds.contains(model.rooms.playerId) {
          Text("この曲は解答済みです（再PUSH不可）").foregroundStyle(Studio.secondary)
        } else if room.handicapSecondsLeft(
          for: model.rooms.playerId, nowMS: model.rooms.serverNowMS) > 0
        {
          Text(
            "ハンデ中・あと\(Int(ceil(room.handicapSecondsLeft(for: model.rooms.playerId, nowMS: model.rooms.serverNowMS))))秒で解答できます"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Studio.accent)
        } else if model.roomPushPending
          || room.canPush(model.rooms.playerId, nowMS: model.rooms.serverNowMS)
        {
          PushButton(
            action: { model.beginRoomPush() }, size: compact ? 142 : 180,
            pending: model.roomPushPending)
        }
      }
    }
  }

  private func watchingStage(_ room: RoomState, compact: Bool) -> some View {
    VStack(spacing: compact ? 8 : 12) {
      Text("\(room.activeAnswers.count)人が解答中...")
        .font(.title2.bold()).foregroundStyle(Studio.primary)
      if room.settings.endless {
        Text("曲と出題タイマーは停止中")
          .foregroundStyle(Studio.secondary)
        CountdownBar(
          remaining: model.roomSecondsLeft, total: 30, compact: true,
          hapticsEnabled: room.pausedAt == nil && !room.questionAudioClosed)
      } else if room.audioStoppedAt != nil {
        Text("30秒経過・曲は停止中。回答完了を待っています")
          .foregroundStyle(Studio.secondary)
      } else {
        Text("PUSH受付終了。回答完了を待っています")
          .foregroundStyle(Studio.secondary)
      }
      ForEach(room.activeAnswers) { answer in
        HStack(spacing: 10) {
          Text(room.player(answer.playerId)?.name ?? "プレイヤー")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Spacer(minLength: 0)
          Text(answer.progress.isEmpty ? "入力待ち" : answer.progress)
            .font(.subheadline.bold())
            .lineLimit(1)
            .foregroundStyle(Studio.accent)
        }
        .foregroundStyle(Studio.primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
      }
    }
  }

  private func roomReveal(_ room: RoomState) -> some View {
    VStack(spacing: 10) {
      if let song = room.current?.song {
        HStack(spacing: 12) {
          Artwork(url: song.artworkURL, size: 88)
          VStack(alignment: .leading, spacing: 4) {
            Text(room.correctPlayerIDs.contains(model.rooms.playerId) ? "正解！" : "この曲でした")
              .font(.title3.bold())
              .foregroundStyle(
                room.correctPlayerIDs.contains(model.rooms.playerId)
                  ? Studio.success : Studio.primary)
            Text(song.title)
              .font(.headline)
              .lineLimit(2)
            Text(song.artist)
              .font(.caption)
              .foregroundStyle(Studio.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Studio.primary)
        HStack(spacing: 8) {
          Button {
            model.saveReview(song)
          } label: {
            Label(
              model.reviews.contains { $0.id == song.id } ? "保存済み" : "復習に保存",
              systemImage: "bookmark")
          }
          .buttonStyle(StudioButtonStyle(.secondary))
          .disabled(model.reviews.contains { $0.id == song.id })
          if let url = song.trackURL {
            Link(destination: url) {
              Label("曲を開く", systemImage: "arrow.up.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Studio.accent)
            }
          }
        }
        ChorusReportButton(song: song)
      }
      let winners = room.correctPlayerIDs.enumerated().compactMap { index, id in
        room.player(id).map { "\(index + 1)位 \($0.name)" }
      }
      Text(winners.isEmpty ? "正解者なし" : winners.joined(separator: " ・ "))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(winners.isEmpty ? Studio.secondary : Studio.success)
        .lineLimit(2)
        .minimumScaleFactor(0.85)
    }
    .modifier(
      RevealSurface(
        song: room.current?.song,
        correct: room.correctPlayerIDs.contains(model.rooms.playerId)))
  }

  private func skipButton(_ room: RoomState) -> some View {
    let hasAnswered = room.answerStatus == "wrong" || room.answerStatus == "correct"
    let disqualified = room.player(model.rooms.playerId)?.disqualified == true
    return Button(
      hasAnswered
        ? "解答済み・投票不要"
        : disqualified
          ? "失格・投票不要" : room.skippedIds.contains(model.rooms.playerId) ? "スキップに投票済み" : "スキップに投票"
    ) {
      Task { await model.roomAction("skip") }
    }
    .buttonStyle(StudioButtonStyle(.tertiary))
    .disabled(hasAnswered || disqualified || room.skippedIds.contains(model.rooms.playerId))
    .padding(.top, 12)
  }

}
