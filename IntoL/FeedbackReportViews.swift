import SwiftUI

struct FeedbackReportPresentation: ViewModifier {
    @ObservedObject var feedback: FeedbackReportModel

    func body(content: Content) -> some View {
        content.modifier(AnonymousReportPresentation(presentationID: feedback.presentationID,
                                                    dismiss: feedback.dismiss) {
            if let id = feedback.presentationID {
                FeedbackReportConfirmation(feedback: feedback, presentationID: id)
            }
        })
    }
}

private struct FeedbackReportConfirmation: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feedback: FeedbackReportModel
    @FocusState private var messageFocused: Bool
    @ScaledMetric(relativeTo: .subheadline) private var messageHeight: CGFloat = 120
    let presentationID: UUID

    private var phase: AnonymousReportPhase {
        if feedback.isSent { return .sent }
        return feedback.isSending ? .sending : .confirmation
    }

    var body: some View {
        AnonymousReportDialog(phase: phase, identifierPrefix: "feedback",
                              sendingText: "お問い合わせを送信しています…", successText: "送信ありがとうございます",
                              dismiss: {
                                  guard feedback.presentationID == presentationID else { return }
                                  feedback.dismiss()
                              }) { titleFocus in
            confirmationContent(titleFocus: titleFocus)
        }
    }

    private func confirmationContent(titleFocus: AccessibilityFocusState<Bool>.Binding) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Studio.accent)
                .accessibilityHidden(true)
            Text("意見・お問い合わせ")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Studio.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(titleFocus)
            VStack(alignment: .leading, spacing: 8) {
                Text("内容").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $feedback.message)
                        .font(.subheadline)
                        .foregroundStyle(Studio.primary)
                        .multilineTextAlignment(.leading)
                        .scrollContentBackground(.hidden)
                        .focused($messageFocused)
                        .padding(8)
                        .accessibilityLabel("意見・お問い合わせの内容")
                        .accessibilityIdentifier("feedback-message")
                    if feedback.message.isEmpty {
                        Text("ご意見やお困りのことをお聞かせください")
                            .font(.subheadline)
                            .foregroundStyle(Studio.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: min(messageHeight, 240))
                .background(Studio.background, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Studio.Radius.sm).stroke(Studio.line, lineWidth: 1)
                }
                Text("\(feedback.message.utf16.count) / \(FeedbackReport.maximumMessageLength)文字")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(feedback.message.utf16.count > FeedbackReport.maximumMessageLength
                                     ? Studio.warning : Studio.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("feedback-character-count")
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach([
                    "匿名で開発者に送信します",
                    "入力内容とアプリのバージョンを送ります",
                    "アカウント情報は含みません。個別の返信はできません"
                ], id: \.self) { explanation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        Text(explanation).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Studio.secondary)
            .multilineTextAlignment(.leading)
            if let error = feedback.error {
                Text(error).font(.footnote).foregroundStyle(Studio.warning)
                    .accessibilityIdentifier("feedback-error")
            }
            VStack(spacing: 12) {
                Button {
                    messageFocused = false
                    Task { await feedback.submit(serverURL: model.serverURL) }
                } label: {
                    Text("匿名で送信する").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .disabled(!feedback.canSubmit)
                .accessibilityIdentifier("feedback-confirm")
                Button("キャンセル", role: .cancel) { feedback.dismiss() }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("feedback-cancel")
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
    }
}
