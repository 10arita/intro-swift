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
                                Image(systemName: "xmark").font(.headline).foregroundStyle(Studio.primary)
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
                            Text(game.stage == .finished ? "RESULT" : "ROUND \(game.index + 1) / \(game.songs.count)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(Studio.secondary)
                            GameVolumeButton { showVolumeSettings = true }
                        }
                        if game.stage == .preparing {
                            Spacer(minLength: 24)
                            SectionCaption(title: "ROUND \(game.index + 1) / \(game.songs.count)")
                            ProgressView().tint(Studio.accent).scaleEffect(1.5)
                            Text("音源を読み込み中")
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            if game.warning != nil {
                                Button("再試行") { model.retrySoloRound() }
                                    .buttonStyle(StudioButtonStyle(.secondary))
                            }
                        } else if game.stage == .countdown {
                            Spacer(minLength: 24)
                            SectionCaption(title: "ROUND \(game.index + 1) / \(game.songs.count)")
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
                            CountdownBar(remaining: game.secondsLeft, total: 30, compact: true)
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
                            PrimaryButton(title: game.index + 1 == game.songs.count ? "結果を見る" : "次の曲へ", symbol: "arrow.right") {
                                model.nextRound()
                            }
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
        .sheet(isPresented: $showVolumeSettings) {
            GameVolumeSettingsSheet()
                .environmentObject(model)
        }
    }
}
