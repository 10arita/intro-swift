import SwiftUI

struct RoomPlayerStandings: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let room: RoomState
  let localID: String
  let avatarData: Data?
  let pushPending: Bool
  let pendingPushTimeMS: Double?
  let profile: (RoomPlayer) -> Void
  let friends: () -> Void

  private var displayedPlayers: [RoomPlayer] {
    room.statusPlayers(pendingPushPlayerID: pushPending ? localID : nil)
  }

  var body: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: dynamicTypeSize.isAccessibilitySize ? 2 : max(1, room.players.count)), spacing: 8
    ) {
      ForEach(displayedPlayers) { player in
        RoomPlayerTile(
          player: player, rank: (room.rankedPlayers.firstIndex { $0.id == player.id } ?? 0) + 1,
          avatarData: player.id == localID ? avatarData : nil,
          livesUnlimited: room.settings.lives == 0,
          answering: room.isAnswering(player.id),
          pending: player.id == localID && pushPending,
          skipped: room.skippedIds.contains(player.id),
          pushRank: (room.pushOrderIds ?? room.pushedIds).firstIndex(of: player.id),
          pushTimeMS: player.pushTimeMS ?? (player.id == localID ? pendingPushTimeMS : nil),
          profile: { profile(player) }
        )
        .contextMenu { RoomPlayerActions(player: player, friends: friends) }
      }
    }
    .frame(maxWidth: 560)
    .frame(maxWidth: .infinity)
    .animation(reduceMotion ? nil : Studio.spring, value: displayedPlayers.map(\.id))
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
  let pushTimeMS: Double?
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
              if player.currentResult == "correct" || player.currentResult == "wrong" {
                Image(systemName: player.currentResult == "correct" ? "circle" : "xmark")
                  .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                  .frame(width: 20, height: 20)
                  .background(
                    player.currentResult == "correct" ? Studio.correctBadge : Studio.wrongBadge,
                    in: Circle())
                  .offset(x: 6, y: -4)
                  .accessibilityHidden(true)
              } else if answering || pending || pushRank != nil {
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
        "\(player.currentResult == "correct" ? "正解" : player.currentResult == "wrong" ? "不正解" : "未判定")、ライフ\(livesUnlimited ? "制限なし" : "\(player.lives)")"
      )
      Text(String(format: "%.3f秒", (pushTimeMS ?? 0) / 1000)).font(.caption2.monospacedDigit())
        .foregroundStyle(Studio.secondary).lineLimit(1).minimumScaleFactor(0.8)
        .opacity(pushTimeMS == nil ? 0 : 1)
        .accessibilityLabel("PUSH時刻 \(String(format: "%.3f", (pushTimeMS ?? 0) / 1000))秒")
        .accessibilityHidden(pushTimeMS == nil)
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
