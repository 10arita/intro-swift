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
                              sendingText: "メッセージを送信しています…", successText: "送信ありがとうございます",
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
            Text("ご意見送信フォーム")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Studio.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused(titleFocus)
            categorySelection
            messageContent
            Button("キャンセル", role: .cancel) { feedback.dismiss() }
                .buttonStyle(StudioButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("feedback-cancel")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
    }

    private var categorySelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("種別（必須）")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Studio.primary)
            ForEach(FeedbackCategory.allCases) { category in
                let selected = feedback.category == category
                Button { feedback.category = category } label: {
                    HStack(spacing: 12) {
                        Text(category.title)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(FeedbackCategoryButtonStyle(isSelected: selected))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("feedback-category-\(category.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var messageContent: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("詳細メッセージ").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $feedback.message)
                        .font(.subheadline)
                        .foregroundStyle(Studio.primary)
                        .multilineTextAlignment(.leading)
                        .scrollContentBackground(.hidden)
                        .focused($messageFocused)
                        .padding(8)
                        .accessibilityLabel("詳細メッセージ")
                        .accessibilityIdentifier("feedback-message")
                    if feedback.message.isEmpty {
                        Text(feedback.category?.messagePrompt ?? "ご意見やお困りのことをお聞かせください")
                            .font(.subheadline)
                            .foregroundStyle(Studio.secondary)
                            .multilineTextAlignment(.leading)
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
                    "種別・入力内容・アプリのバージョンを送ります",
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
            Button {
                messageFocused = false
                Task { await feedback.submit(serverURL: model.serverURL) }
            } label: {
                Text("匿名で送信する").frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioButtonStyle(.primary))
            .disabled(!feedback.canSubmit)
            .accessibilityIdentifier("feedback-confirm")
        }
    }
}

private struct FeedbackCategoryButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : Studio.primary)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(isSelected ? Color.black : Studio.surface,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Studio.Radius.md)
                    .strokeBorder(isSelected ? Studio.primary : Studio.line)
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
