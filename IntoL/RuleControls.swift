import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

enum RoomRule: String {
    case questionCount, answerSlots, endless, targetScore, correctPoints
    case firstBonus, wrongPenalty, firstWrongPenalty, lives

    var title: String {
        switch self {
        case .questionCount: "問題数"
        case .answerSlots: "解答権人数"
        case .endless: "エンドレスモード"
        case .targetScore: "勝利目標"
        case .correctPoints: "正解"
        case .firstBonus: "1st正解"
        case .wrongPenalty: "誤答"
        case .firstWrongPenalty: "1st誤答"
        case .lives: "ライフ"
        }
    }

    var explanation: String {
        switch self {
        case .questionCount:
            "1回の対戦で出題する曲数です。プレイリストには、設定した問題数以上の曲が必要です。"
        case .answerSlots:
            "1問につきPUSHして解答できる人数です。通常モードでは、枠が空いていれば複数人が同時に解答できます。エンドレスモードでは、この人数制限は適用されません。"
        case .endless:
            "解答権人数の制限をなくし、PUSHした順に1人ずつ解答します。解答中は全員の曲と出題タイマーが止まります。誤答・時間切れの後は、次の人の解答か曲の再生に進みます。正解が出ると、その問題を終了します。"
        case .targetScore:
            "いずれかのプレイヤーがこの得点に達すると、その問題の終了後に対戦を終了します。"
        case .correctPoints:
            "曲名を最後まで正しく解答したプレイヤーに加算する基本の得点です。"
        case .firstBonus:
            "その問題の正解者の中で、最初にPUSHしたプレイヤーに加算するボーナスです。「正解」の得点に上乗せします。"
        case .wrongPenalty:
            "誤答や解答の時間切れで減点する得点です。ライフの減少は別に適用されます。"
        case .firstWrongPenalty:
            "その問題で最初にPUSHしたプレイヤーが誤答・時間切れになった場合の追加の減点です。「誤答」の減点に上乗せします。"
        case .lives:
            "各プレイヤーの初期ライフです。誤答や解答の時間切れで1つ減り、なくなると失格になります。"
        }
    }

    func displayValue(_ number: Int) -> String {
        switch self {
        case .questionCount: "\(number)問"
        case .answerSlots: "\(number)人"
        case .endless: number == 0 ? "オフ" : "オン"
        case .targetScore: number == 0 ? "制限なし" : "\(number)点"
        case .correctPoints: "\(number)点"
        case .firstBonus: "+\(number)点"
        case .wrongPenalty, .firstWrongPenalty: "−\(number)点"
        case .lives: number == 0 ? "制限なし" : "\(number)"
        }
    }
}

struct RoomRuleLabel: View {
    let rule: RoomRule
    let onHelp: (RoomRule) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(rule.title).foregroundStyle(Studio.primary)
            RoomRuleHelpButton(rule: rule, onHelp: onHelp)
        }
    }
}

private struct RoomRuleHelpButton: View {
    let rule: RoomRule
    let onHelp: (RoomRule) -> Void

    var body: some View {
        Button { onHelp(rule) } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Studio.secondary.opacity(0.65))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(rule.title)の説明")
        .accessibilityIdentifier("room-rule-help-\(rule.rawValue)")
    }
}

struct RoomRuleHelpPresentation: ViewModifier {
    @Binding var rule: RoomRule?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(rule == nil)
            .accessibilityHidden(rule != nil)
            .overlay {
                ZStack {
                    if let rule {
                        Color.black.opacity(0.25)
                            .ignoresSafeArea()
                            .onTapGesture { self.rule = nil }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        RoomRuleExplanation(rule: rule) { self.rule = nil }
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : Studio.spring, value: rule)
            }
            .interactiveDismissDisabled(rule != nil)
    }
}

private struct RoomRuleExplanation: View {
    let rule: RoomRule
    let onClose: () -> Void
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 20) {
                explanationText
                closeButton
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 20) {
                ScrollView {
                    explanationText
                }
                .scrollBounceBehavior(.basedOnSize)
                closeButton
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.lg))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-rule-explanation")
        .accessibilityAction(.escape, onClose)
        .onAppear { titleFocused = true }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Text("閉じる").frame(maxWidth: .infinity)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
        .keyboardShortcut(.cancelAction)
    }

    private var explanationText: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(rule.title)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Studio.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Text(rule.explanation)
                .font(.subheadline)
                .foregroundStyle(Studio.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RuleDialRow: View {
    let rule: RoomRule
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var disabled = false
    var valueLabel: String?
    let onHelp: (RoomRule) -> Void
    @State private var showingDial = false

    var body: some View {
        HStack(spacing: 0) {
            Button { showingDial = true } label: {
                Text(rule.title)
                    .foregroundStyle(Studio.primary)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityHidden(true)
            RoomRuleHelpButton(rule: rule, onHelp: onHelp)
            Button { showingDial = true } label: {
                HStack(spacing: 12) {
                    Spacer(minLength: 8)
                    Text(valueLabel ?? rule.displayValue(value))
                        .monospacedDigit()
                        .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(Studio.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(rule.title)
            .accessibilityValue(valueLabel ?? rule.displayValue(value))
            .accessibilityHint("ダイヤルで変更")
        }
        .sheet(isPresented: $showingDial) {
            NavigationStack {
                Picker(rule.title, selection: $value) {
                    ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { option in
                        Text(rule.displayValue(option)).tag(option)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 190)
                .frame(maxHeight: .infinity)
                .navigationTitle(rule.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { showingDial = false }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

struct LandingButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: disabled ? "lock.fill" : symbol)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
        .disabled(disabled)
        .accessibilityHint(disabled ? "サーバー設定が必要です" : "")
    }
}
