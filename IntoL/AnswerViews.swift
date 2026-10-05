import SwiftUI

struct AnswerText: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  let answer: String
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.55, paused: reduceMotion || scenePhase != .active)) {
      context in
      let visible =
        reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.55).isMultiple(of: 2)
      (Text(answer).foregroundColor(Studio.primary)
        + Text("＿").foregroundColor(Studio.accent.opacity(visible ? 1 : 0)))
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5)
        .frame(maxWidth: .infinity, minHeight: 48)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(answer.isEmpty ? "未入力、最初の文字を選んでください" : "入力済み: \(answer)、次の文字を選んでください")
  }
}

struct ChoiceGrid: View {
  let choices: [String]
  let action: (String) -> Void
  var compact = false
  var feedback: ChoiceFeedback? = nil
  private var displayedChoices: [String] { feedback?.choices ?? choices }

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12
    ) {
      ForEach(Array(displayedChoices.enumerated()), id: \.offset) { _, choice in
        let incorrect = feedback?.choice == choice && feedback?.correct == false
        let color = Studio.warning
        Button {
          action(choice)
        } label: {
          Text(choice)
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .foregroundStyle(incorrect ? color : Studio.primary)
            .frame(maxWidth: .infinity, minHeight: compact ? 68 : 94)
            .padding(.vertical, 4)
            .background(
              incorrect ? color.opacity(0.14) : Studio.surface,
              in: RoundedRectangle(cornerRadius: Studio.Radius.lg)
            )
            .overlay(
              RoundedRectangle(cornerRadius: Studio.Radius.lg)
                .strokeBorder(incorrect ? color : Studio.line, lineWidth: incorrect ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
              if incorrect {
                Image(systemName: "xmark.circle.fill")
                .font(.subheadline).foregroundStyle(color).padding(8).accessibilityHidden(true)
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("選択肢、\(choice)")
      }
    }
    .disabled(feedback != nil)
    .animation(nil, value: displayedChoices)
  }
}

struct ChoiceFeedbackPresentation: ViewModifier {
  let feedback: ChoiceFeedback?
  func body(content: Content) -> some View {
    content
      .overlay {
        if let feedback, !feedback.correct {
          RoundedRectangle(cornerRadius: Studio.Radius.lg).strokeBorder(
            Studio.warning.opacity(0.65), lineWidth: 4
          )
          .padding(6).allowsHitTesting(false).accessibilityHidden(true)
        }
      }
      .sensoryFeedback(trigger: feedback?.id) { _, new in
        guard new != nil, let feedback else { return nil }
        return feedback.correct ? .success : .error
      }
  }
}

#Preview("回答中") {
  VStack(spacing: 20) {
    AnswerText(answer: "青い")
    ChoiceGrid(choices: ["空", "花", "鳥", "海"], action: { _ in }, compact: true)
  }
  .padding(24).background(Studio.background)
}

#Preview("正誤フィードバック") {
  VStack(spacing: 24) {
    ChoiceGrid(
      choices: ["空", "花", "鳥", "海"], action: { _ in }, compact: true,
      feedback: ChoiceFeedback(choice: "空", correct: true, choices: ["空", "花", "鳥", "海"]))
    ChoiceGrid(
      choices: ["空", "花", "鳥", "海"], action: { _ in }, compact: true,
      feedback: ChoiceFeedback(choice: "海", correct: false, choices: ["空", "花", "鳥", "海"]))
  }
  .padding(24).background(Studio.background)
}
