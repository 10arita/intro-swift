import SwiftUI

extension RoomState {
  var rankedPlayers: [RoomPlayer] {
    players.sorted {
      if $0.disqualified != $1.disqualified { return !$0.disqualified }
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.lives != $1.lives { return $0.lives > $1.lives }
      return $0.id < $1.id
    }
  }
}

struct RoomPlayerStandings: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let room: RoomState
  let localID: String
  let avatarData: Data?
  let pushPending: Bool
  let profile: (RoomPlayer) -> Void
  let friends: () -> Void

  var body: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: dynamicTypeSize.isAccessibilitySize ? 2 : max(1, room.players.count)), spacing: 8
    ) {
      ForEach(Array(room.rankedPlayers.enumerated()), id: \.element.id) { index, player in
        RoomPlayerTile(
          player: player, rank: index + 1,
          avatarData: player.id == localID ? avatarData : nil,
          livesUnlimited: room.settings.lives == 0,
          answering: room.isAnswering(player.id),
          pending: player.id == localID && pushPending,
          skipped: room.skippedIds.contains(player.id),
          pushRank: (room.pushOrderIds ?? room.pushedIds).firstIndex(of: player.id),
          showPushTime: room.phase == "reveal",
          profile: { profile(player) }
        )
        .contextMenu { RoomPlayerActions(player: player, friends: friends) }
      }
    }
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
    .animation(reduceMotion ? nil : Studio.spring, value: room.rankedPlayers.map(\.id))
  }
}

private struct RoomPlayerTile: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let player: RoomPlayer
  let rank: Int
  let avatarData: Data?
  let livesUnlimited: Bool
  let answering: Bool
  let pending: Bool
  let skipped: Bool
  let pushRank: Int?
  let showPushTime: Bool
  let profile: () -> Void
  @State private var scoreDelta = 0
  @State private var deltaVisible = false
  @State private var deltaRaised = false
  @State private var scoreRevision = 0

  private var rankColor: Color {
    switch rank {
    case 1: Studio.gold
    case 2: Studio.silver
    case 3: Studio.bronze
    default: Studio.raised
    }
  }

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 4) {
        Text("\(rank)位").font(.system(.subheadline, design: .rounded, weight: .bold))
          .padding(.horizontal, 6).padding(.vertical, 3).background(rankColor, in: Capsule())
        if player.isHost {
          Image(systemName: "crown.fill").font(.caption2).foregroundStyle(Studio.accent)
            .accessibilityLabel("ホスト")
        }
      }
      Button(action: profile) {
        VStack(spacing: 5) {
          PlayerAvatarView(data: avatarData, size: 32, encoded: player.avatar)
            .overlay(alignment: .bottomTrailing) {
              if skipped {
                Image(systemName: "forward.end.fill").font(.system(size: 9, weight: .bold))
                  .foregroundStyle(Studio.onAccent).padding(4).background(
                    Studio.accent, in: Circle())
              }
            }
            .overlay(alignment: .topTrailing) {
              if answering || pending || pushRank != nil {
                Image(systemName: answering ? "pencil" : pending ? "ellipsis" : "hand.tap.fill")
                  .font(.system(size: 9, weight: .bold)).foregroundStyle(Studio.accent)
                  .padding(4).background(Studio.raised, in: Circle()).offset(x: 6, y: -4)
              }
            }
          Text(player.name).font(.system(.caption, design: .rounded, weight: .bold))
            .lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(Studio.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(player.name)のプロフィールを見る")
      Text("\(player.score)")
        .font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
        .contentTransition(.numericText(value: Double(player.score)))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: player.score)
        .accessibilityLabel("\(player.score)点")
        .overlay(alignment: .top) {
          if deltaVisible {
            Text(scoreDelta > 0 ? "+\(scoreDelta)" : "\(scoreDelta)")
              .font(.subheadline.bold()).foregroundStyle(
                scoreDelta > 0 ? Studio.success : Studio.warning
              )
              .offset(y: deltaRaised && !reduceMotion ? -28 : -8)
              .opacity(deltaRaised ? 0 : 1).allowsHitTesting(false).accessibilityHidden(true)
          }
        }
      HStack(spacing: 4) {
        Text(player.currentResult == "correct" ? "○" : player.currentResult == "wrong" ? "×" : "−")
          .font(.system(.title3, design: .rounded, weight: .bold))
          .foregroundStyle(
            player.currentResult == "correct"
              ? Studio.success : player.currentResult == "wrong" ? Studio.warning : Studio.secondary
          )
        Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Studio.accent)
          .accessibilityHidden(true)
        Text(livesUnlimited ? "∞" : "\(player.lives)").font(.caption.monospacedDigit())
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(player.currentResult == "correct" ? "正解" : player.currentResult == "wrong" ? "不正解" : "未判定")、ライフ\(livesUnlimited ? "無制限" : "\(player.lives)")"
      )
      if showPushTime, let time = player.pushTimeMS {
        Text(String(format: "%.3f秒", time / 1000)).font(.caption2.monospacedDigit())
          .foregroundStyle(Studio.secondary).lineLimit(1).minimumScaleFactor(0.8)
          .accessibilityLabel("PUSH時刻 \(String(format: "%.3f", time / 1000))秒")
      }
      if player.disqualified { Text("失格").font(.caption.bold()).foregroundStyle(Studio.warning) }
    }
    .foregroundStyle(Studio.primary)
    .padding(.vertical, 8).padding(.horizontal, 4)
    .frame(maxWidth: .infinity)
    .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
    .overlay(
      RoundedRectangle(cornerRadius: Studio.Radius.sm)
        .strokeBorder(
          answering || pending ? Studio.accent : Studio.line,
          lineWidth: answering || pending ? 2 : 1)
    )
    .opacity(player.connected ? 1 : 0.65)
    .accessibilityElement(children: .contain)
    .accessibilityValue(
      "\(rank)位\(skipped ? "、スキップ投票済み" : "")\(answering ? "、解答中" : pending ? "、PUSH判定中" : pushRank.map { "、PUSH\($0 + 1)番目" } ?? "")"
    )
    .onChange(of: player.score) { old, new in
      scoreDelta = new - old
      deltaRaised = false
      deltaVisible = true
      scoreRevision += 1
    }
    .task(id: scoreRevision) {
      guard scoreRevision > 0 else { return }
      do {
        try await Task.sleep(for: .milliseconds(30))
        withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.8)) { deltaRaised = true }
        try await Task.sleep(for: .milliseconds(850))
        deltaVisible = false
      } catch {}
    }
  }
}

struct RoomPlayerActions: View {
  @EnvironmentObject private var model: AppModel
  let player: RoomPlayer
  let friends: () -> Void
  var body: some View {
    Text(player.badge ?? "称号未設定")
    if player.friendStatus == "available" {
      Button("フレンド申請を送る", systemImage: "person.badge.plus") {
        Task { await model.sendFriendRequest(to: player.id) }
      }
    } else if player.friendStatus == "incoming" {
      Button("フレンド申請を確認", systemImage: "person.2", action: friends)
    } else if player.friendStatus == "outgoing" {
      Text("フレンド申請中")
    } else if player.friendStatus == "friend" {
      Text("フレンド")
    }
  }
}
