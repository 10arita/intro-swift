import SwiftUI

struct RankMeasurementSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var catalog: RankCatalog?
    @State private var catalogError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    instruction("いくつかの問題であなたの段位を測定します")
                    instruction("設定された時間内に答えよう")
                }
                .foregroundStyle(Studio.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                AppleMusicIcon(size: 22)
                Text("Apple Musicとの連携とサブスクリプションが必要です")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
            .foregroundStyle(Studio.secondary)
            .accessibilityElement(children: .combine)
            if let catalogError {
                Text(catalogError).foregroundStyle(Studio.warning)
            }
            PrimaryButton(title: model.busy ? "測定を準備中…" : "段位を測定する", symbol: "headphones",
                          disabled: model.busy || catalog == nil || !model.canStartSolo) {
                Task { await model.startRankMeasurement() }
            }
            .accessibilityIdentifier("start-rank-measurement")
            if model.busy { ProgressView("Apple Musicの再生条件を確認中").tint(Studio.accent) }
            RankRecordSummary(records: model.rankRecords, catalogVersion: catalog?.version)
        }
        .task {
            do { catalog = try RankCatalog.load() }
            catch { catalogError = error.localizedDescription }
        }
    }

    private func instruction(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct RankResultSummary: View {
    let result: RankResult
    var best: RankResult?

    private var averagePush: String {
        let values = result.validRounds.filter(\.success).compactMap(\.pushTime)
        return values.isEmpty ? "—" : String(format: "%.3f秒", values.reduce(0, +) / Double(values.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 10) {
                Label("推定段位", systemImage: "medal.fill")
                    .font(.headline).foregroundStyle(Studio.secondary)
                Text(result.rankLabel)
                    .font(.system(.largeTitle, design: .rounded, weight: .black))
                    .foregroundStyle(Studio.accent)
                    .accessibilityIdentifier("rank-result-level")
                Text("測定幅：\(result.rangeLabel)")
                    .font(.title3.weight(.semibold)).foregroundStyle(Studio.primary)
                Text("曲との相性による揺れも含めた、今回の実力の目安です。")
                    .font(.subheadline).foregroundStyle(Studio.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            StudioCard {
                VStack(alignment: .leading, spacing: 12) {
                    metric("正解", value: "\(result.correct) / \(result.validRounds.count)")
                    metric("正解時の平均PUSH", value: averagePush)
                    if let best { metric("同じ曲集での最高記録", value: best.rankLabel) }
                    if result.rounds.contains(where: { !$0.valid }) {
                        Text("再生できなかった\(result.rounds.filter { !$0.valid }.count)問は測定対象外です。")
                            .font(.footnote).foregroundStyle(Studio.secondary)
                    }
                }
            }
            StudioCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("次の目標").font(.headline).foregroundStyle(Studio.primary)
                    Text(result.nextGoal).foregroundStyle(Studio.secondary)
                }
            }
            if result.provisional {
                Text("ベータ版・仮難易度による推定です。曲の難易度は試遊を通して調整します。")
                    .font(.footnote).foregroundStyle(Studio.secondary)
            }
            ShareLink(item: "IntoLのイントロ段位測定：\(result.rankLabel)（測定幅：\(result.rangeLabel)）\n\(result.correct)/\(result.validRounds.count)問正解\(result.provisional ? "・ベータ版" : "")\n曲集：\(result.catalogVersion)") {
                Label("結果を共有", systemImage: "square.and.arrow.up").frame(minHeight: 44)
            }
            .buttonStyle(StudioButtonStyle(.secondary))
            DisclosureGroup("曲ごとの結果") {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(result.rounds) { round in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(round.question.quizTitle).font(.headline).foregroundStyle(Studio.primary)
                            Text(round.question.artist).font(.subheadline).foregroundStyle(Studio.secondary)
                            Text(round.outcome.label + " ・ PUSH期限\(Int(round.question.pushLimit))秒" +
                                 (round.pushTime.map { String(format: " ・ %.3f秒", $0) } ?? ""))
                                .font(.footnote).foregroundStyle(Studio.secondary)
                            if let reason = round.invalidReason {
                                Text(reason).font(.footnote).foregroundStyle(Studio.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 12)
            }.foregroundStyle(Studio.primary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metric(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).foregroundStyle(Studio.secondary)
                Spacer()
                Text(value).fontWeight(.semibold).foregroundStyle(Studio.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(Studio.secondary)
                Text(value).fontWeight(.semibold).foregroundStyle(Studio.primary)
            }
        }
    }
}

struct RankRecordSummary: View {
    let records: RankRecords
    var catalogVersion: String?

    private var best: RankResult? {
        guard let catalogVersion else { return nil }
        return records.bestByVersion[catalogVersion + ":" + RankEstimator.version]
    }

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("段位測定の記録", systemImage: "medal.fill")
                    .font(.headline).foregroundStyle(Studio.primary)
                if let latest = records.history.first {
                    Text("前回：\(latest.rankLabel) ／ 測定幅：\(latest.rangeLabel)")
                        .foregroundStyle(Studio.primary)
                    if let best { Text("現在の曲集での最高：\(best.rankLabel)").foregroundStyle(Studio.accent) }
                    DisclosureGroup("最近の測定（\(records.history.count)回）") {
                        ForEach(records.history) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(result.rankLabel) ・ \(result.correct)/\(result.validRounds.count)問正解")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Studio.primary)
                                Text(result.date, style: .date).font(.footnote).foregroundStyle(Studio.secondary)
                                Text("測定幅：\(result.rangeLabel)").font(.footnote).foregroundStyle(Studio.secondary)
                                if catalogVersion != nil, result.catalogVersion != catalogVersion {
                                    Text("以前の曲集での測定").font(.footnote).foregroundStyle(Studio.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }.foregroundStyle(Studio.primary)
                } else {
                    Text("まだ測定していません。最初の1回で今の実力を確かめよう。")
                        .foregroundStyle(Studio.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }
}
