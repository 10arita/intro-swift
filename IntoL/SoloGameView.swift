import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct SoloGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showVolumeSettings = false

    var body: some View {
        ZStack {
            Studio.background.ignoresSafeArea()
            if let game = model.game {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Button { model.closeGame() } label: {
                                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Studio.primary)
                                    .frame(width: 44, height: 44).background(Studio.surface, in: Circle())
                            }
                            .accessibilityLabel("ゲームを閉じる")
                            HStack(spacing: 5) {
                                PlayerAvatarView(data: model.avatarData, size: 18)
                                Text(model.nickname)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(Studio.primary)
                            }
                            .padding(.leading, 6)
                            Spacer()
                            Text(game.stage == .finished ? "RESULT" : game.progressLabel)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(Studio.secondary)
                            GameVolumeButton { showVolumeSettings = true }
                        }
                        if game.stage == .preparing {
                            Spacer(minLength: 24)
                            SectionCaption(title: game.progressLabel)
                            if game.warning == nil {
                                ProgressView().tint(Studio.accent).scaleEffect(1.5)
                            } else {
                                Image(systemName: "pause.circle").font(.largeTitle).foregroundStyle(Studio.secondary)
                                    .accessibilityHidden(true)
                            }
                            Text(game.warning == nil ? "音源を読み込み中" : (game.rankSession == nil ? "音源を確認できません" : "測定を一時停止"))
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            if game.warning != nil {
                                Button(game.rankSession == nil ? "再試行" : "別の曲で続ける") { model.retrySoloRound() }
                                    .buttonStyle(StudioButtonStyle(.secondary))
                                    .accessibilityIdentifier("retry-solo-round")
                            }
                        } else if game.stage == .countdown {
                            Spacer(minLength: 24)
                            SectionCaption(title: game.progressLabel)
                            WaveMark()
                            Text("第\(game.index + 1)問目")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("\(max(1, Int(ceil(game.secondsLeft))))")
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.accent)
                        } else if game.stage == .listening {
                            Spacer(minLength: 4)
                            WaveMark(isPlaying: game.warning == nil)
                            Text("耳を澄ませて")
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("曲名が分かったら PUSH")
                                .foregroundStyle(Studio.secondary)
                            if game.rankSession != nil {
                                Text("PUSH期限 \(Int(game.listenLimit))秒")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Studio.primary)
                            }
                            CountdownBar(remaining: game.secondsLeft, total: game.listenLimit, compact: true)
                            PushButton(action: { model.push() }, size: 220)
                            Button("この曲をスキップ") { model.skip() }
                                .buttonStyle(StudioButtonStyle(.tertiary))
                                .padding(.top, 16)
                        } else if game.stage == .answering {
                            Spacer(minLength: 4)
                            SectionCaption(title: "SPELL THE TITLE")
                            AnswerText(answer: game.answered)
                            Text("次の文字を選ぶ")
                                .foregroundStyle(Studio.secondary)
                            CountdownBar(remaining: game.secondsLeft, total: 5, compact: true, hapticsEnabled: !model.soloChoicePending)
                            ChoiceGrid(choices: game.choices, action: { model.choose($0) }, compact: true, feedback: model.soloChoiceFeedback)
                                .disabled(model.soloChoicePending)
                        } else if game.stage == .reveal {
                            RevealCard(song: game.current, correct: game.wasCorrect,
                                       saved: model.reviews.contains { $0.id == game.current.id }) {
                                model.saveReview(game.current)
                            }
                            PrimaryButton(title: (game.rankSession?.shouldFinish ?? (game.index + 1 == game.songs.count)) ? "結果を見る" : "次の曲へ", symbol: "arrow.right") {
                                model.nextRound()
                            }
                        } else if let result = model.lastRankResult, game.rankSession != nil {
                            RankResultSummary(result: result, best: model.rankRecords.bestByVersion[result.comparisonKey])
                            PrimaryButton(title: "ホームへ戻る", symbol: "house") { model.closeGame() }
                        } else if let result = model.lastResult {
                            ResultSummary(result: result, playerName: model.nickname)
                            PrimaryButton(title: "ホームへ戻る", symbol: "house") { model.closeGame() }
                        }
                        if let warning = game.warning {
                            Text(warning).font(.caption).foregroundStyle(Studio.warning)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion || game.stage == .answering ? nil : Studio.spring, value: game.stage)
                }
            }
        }
        .modifier(ChoiceFeedbackPresentation(feedback: model.soloChoiceFeedback))
        .modifier(ChorusReportPresentation())
        .sheet(isPresented: $showVolumeSettings) {
            GameVolumeSettingsSheet()
                .environmentObject(model)
        }
    }
}
