import SwiftUI

struct ResultSummary: View {
  let result: SoloResult
  let playerName: String
  var body: some View {
    VStack(spacing: 24) {
      SectionCaption(title: "SESSION COMPLETE")
      ResultHero(score: result.score, solo: true, rank: result.rank)
      StudioCard {
        HStack {
          ResultMetric(title: "正解", value: "\(result.correct) / \(result.total)")
          Spacer()
          ResultMetric(title: "平均 PUSH", value: String(format: "%.3f秒", result.averagePush))
        }
      }
      Text(result.playlist).font(.subheadline).foregroundStyle(Studio.secondary)
      ResultImageShare(
        playerName: playerName, rank: result.rank,
        score: String(format: "%.1f / 100", result.score),
        playlist: result.playlist, correct: result.correct, total: result.total)
      if let rounds = result.rounds, !rounds.isEmpty {
        ResultRoundList(
          rows: rounds.map {
            ResultRoundRow(
              song: $0.song,
              outcome: $0.correct ? "correct" : $0.pushTime == nil ? "skipped" : "wrong")
          })
      }
    }
  }
}

struct RoomResultSummary: View {
  let room: RoomState
  let playerID: String
  let playerName: String
  private var player: RoomPlayer? { room.player(playerID) }
  private var rank: Int { (room.rankedPlayers.firstIndex { $0.id == playerID } ?? 0) + 1 }
  private var rows: [ResultRoundRow] {
    (room.roundSongs ?? []).enumerated().compactMap { index, current in
      guard let song = current.song else { return nil }
      let results = player?.roundResults ?? []
      return ResultRoundRow(
        song: song, outcome: index < results.count ? results[index] ?? "skipped" : "skipped")
    }
  }
  var body: some View {
    VStack(spacing: 20) {
      SectionCaption(title: "FINAL RESULTS")
      ResultHero(score: Double(player?.score ?? 0), solo: false, rank: "\(rank)位")
      Text("\(room.players.count)人で対戦 · 正解 \(player?.correctCount ?? 0)曲")
        .font(.subheadline).foregroundStyle(Studio.secondary)
      ResultImageShare(
        playerName: playerName, rank: "\(rank)位",
        score: "\(player?.score ?? 0) pt", playlist: room.playlist?.name ?? "IntoL 対戦",
        correct: player?.correctCount ?? 0, total: max(0, room.round + 1))
      if !rows.isEmpty { ResultRoundList(rows: rows) }
    }
  }
}

private struct ResultHero: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let score: Double
  let solo: Bool
  let rank: String
  @State private var displayedScore = 0.0

  var body: some View {
    VStack(spacing: 8) {
      Text(solo && displayedScore < score ? SoloResult.rank(for: displayedScore) : rank)
        .font(.system(size: 88, weight: .black, design: .rounded))
        .foregroundStyle(Studio.accent).minimumScaleFactor(0.5).lineLimit(1)
        .contentTransition(.numericText())
      Text(solo ? String(format: "%.1f / 100", displayedScore) : "\(Int(displayedScore)) pt")
        .font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
        .foregroundStyle(Studio.primary).contentTransition(.numericText(value: displayedScore))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(rank)、\(solo ? String(format: "%.1f / 100", score) : "\(Int(score))点")")
    .task(id: score) {
      guard !reduceMotion else {
        displayedScore = score
        return
      }
      do {
        for step in 1...30 {
          try Task.checkCancellation()
          let progress = Double(step) / 30
          withAnimation(.linear(duration: 0.025)) {
            displayedScore = score * (1 - pow(1 - progress, 3))
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        displayedScore = score
      } catch {}
    }
  }
}

private struct ResultMetric: View {
  let title: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.caption).foregroundStyle(Studio.secondary)
      Text(value).font(.title3.bold()).foregroundStyle(Studio.primary)
    }
  }
}

private struct ResultRoundRow {
  let song: Song
  let outcome: String
}

private struct ResultRoundList: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isExpanded = false
  let rows: [ResultRoundRow]
  var body: some View {
    StudioCard {
      VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
        Button { isExpanded.toggle() } label: {
          HStack {
            Text("曲ごとの結果").font(.headline)
            Spacer()
            Image(systemName: "chevron.down")
              .font(.subheadline.weight(.semibold))
              .rotationEffect(.degrees(isExpanded ? 180 : 0))
              .accessibilityHidden(true)
          }
          .foregroundStyle(Studio.primary)
          .frame(maxWidth: .infinity, minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result-rounds")
        .accessibilityLabel("曲ごとの結果")
        .accessibilityValue(isExpanded ? "開いています" : "閉じています")
        .accessibilityHint(isExpanded ? "曲一覧を閉じます" : "曲一覧を開きます")
        if isExpanded {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
              HStack(spacing: 12) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(Studio.secondary)
                Artwork(url: row.song.artworkURL, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                  Text(row.song.title).font(.subheadline.weight(.semibold)).foregroundStyle(
                    Studio.primary)
                  Text(row.song.artist).font(.caption).foregroundStyle(Studio.secondary)
                }
                Spacer(minLength: 4)
                Image(
                  systemName: row.outcome == "correct"
                    ? "checkmark.circle.fill"
                    : row.outcome == "wrong" ? "xmark.circle.fill" : "minus.circle"
                )
                .font(.title3).foregroundStyle(
                  row.outcome == "correct"
                    ? Studio.success : row.outcome == "wrong" ? Studio.warning : Studio.secondary
                )
                .accessibilityLabel(
                  row.outcome == "correct" ? "正解" : row.outcome == "wrong" ? "不正解" : "未解答")
              }
              .accessibilityElement(children: .combine)
              if index + 1 < rows.count { Divider() }
            }
          }
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
    }
  }
}

private struct ResultImageShare: View {
  let playerName: String
  let rank: String
  let score: String
  let playlist: String
  let correct: Int
  let total: Int
  @State private var shareImage: UIImage?
  @State private var renderFailed = false

  var body: some View {
    Group {
      if let shareImage {
        ShareLink(
          item: Image(uiImage: shareImage),
          preview: SharePreview("IntoL リザルト", image: Image(uiImage: shareImage))
        ) {
          Label("結果の画像を共有", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
      } else if renderFailed {
        Text("共有画像を作成できませんでした").font(.caption).foregroundStyle(Studio.warning)
      } else {
        ProgressView("共有画像を作成中").font(.caption).tint(Studio.accent)
      }
    }
    .task {
      let renderer = ImageRenderer(
        content: ResultShareCard(
          playerName: playerName, rank: rank, score: score,
          playlist: playlist, correct: correct, total: total
        )
        .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .large))
      renderer.scale = 2
      shareImage = renderer.uiImage
      renderFailed = shareImage == nil
    }
  }
}

private struct ResultShareCard: View {
  let playerName: String
  let rank: String
  let score: String
  let playlist: String
  let correct: Int
  let total: Int
  var body: some View {
    VStack(spacing: 20) {
      HStack {
        Text("IntoL").font(.system(size: 32, weight: .black, design: .rounded))
        Spacer()
        Text("INTRO QUIZ").font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(3)
      }
      HomeWaveform(isActive: false).frame(height: 46)
      Text(playerName).font(.system(size: 20, weight: .semibold)).lineLimit(1)
      Text(rank).font(.system(size: 100, weight: .black, design: .rounded)).foregroundStyle(
        Studio.accent)
      Text(score).font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
      Text("正解 \(correct) / \(total)曲").font(.system(size: 18, weight: .semibold))
      Text(playlist).font(.system(size: 16)).foregroundStyle(Studio.secondary).lineLimit(2)
        .multilineTextAlignment(.center)
      Spacer(minLength: 0)
      Text("耳でひらめく。文字で答える。").font(.system(size: 14)).foregroundStyle(Studio.secondary)
    }
    .foregroundStyle(Studio.primary).padding(40)
    .frame(width: 540, height: 640).background(Studio.background)
  }
}

#Preview("曲ごとの結果") {
  let song = Song(id: "preview", title: "青い空", artist: "IntoL", durationMS: 180_000, genre: "Pop")
  let result = SoloResult.make(
    playlist: "夜に聴く曲", total: 2, pushTimes: [1.25],
    rounds: [
      SoloRoundResult(song: song, correct: true, pushTime: 1.25),
      SoloRoundResult(
        song: Song(id: "preview2", title: "春風", artist: "IntoL", durationMS: 180_000, genre: "Pop"),
        correct: false, pushTime: nil),
    ])
  ScrollView { ResultSummary(result: result, playerName: "プレイヤー").padding(24) }
    .background(Studio.background)
}
