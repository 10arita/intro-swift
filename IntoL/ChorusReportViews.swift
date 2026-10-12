import SwiftUI

struct ChorusReportButton: View {
    @EnvironmentObject private var model: AppModel
    let song: Song

    private var report: ChorusReport? {
        guard model.revealReport?.song.id == song.id else { return nil }
        return model.revealReport
    }
    private var sent: Bool { report != nil && model.chorusReportSentID == report?.id }

    var body: some View {
        Button { model.presentChorusReport(for: song) } label: {
            Label(sent ? "サビ位置の相違を報告済み" : "サビ位置の相違を報告する",
                  systemImage: sent ? "checkmark.circle" : "flag")
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(StudioButtonStyle(.tertiary))
        .disabled(report == nil || sent || model.chorusReportSendingID != nil)
        .accessibilityIdentifier("chorus-report-button")
        .accessibilityHint(report == nil ? "正解曲の再生開始後に報告できます" : "匿名報告の確認を開きます")
    }
}

struct ChorusReportPresentation: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(model.chorusReportDraft == nil)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(model.chorusReportDraft != nil)
            .overlay {
                ZStack {
                    if let report = model.chorusReportDraft {
                        Color.black.opacity(0.32)
                            .ignoresSafeArea()
                            .onTapGesture { model.dismissChorusReport() }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        ChorusReportConfirmation(report: report)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                    }
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Studio.spring,
                       value: model.chorusReportDraft?.id)
    }
}

private struct ChorusReportConfirmation: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleFocused: Bool
    let report: ChorusReport
    private enum Phase { case confirmation, sending, sent }
    private var phase: Phase {
        if model.chorusReportSentID == report.id { return .sent }
        return model.chorusReportSendingID == report.id ? .sending : .confirmation
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            currentContent
            ScrollView { currentContent }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: 360)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.lg))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("chorus-report-confirmation")
        .accessibilityAction(.escape) { model.dismissChorusReport() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
        .task(id: phase) {
            titleFocused = true
            guard phase == .sent else { return }
            let drawingDuration = reduceMotion ? 0 : ChorusReportTiming.circle + ChorusReportTiming.check
            do {
                try await Task.sleep(for: .seconds(drawingDuration + ChorusReportTiming.successHold))
            } catch { return }
            guard !Task.isCancelled, model.chorusReportDraft?.id == report.id,
                  model.chorusReportSentID == report.id else { return }
            model.dismissChorusReport()
        }
    }

    @ViewBuilder private var currentContent: some View {
        switch phase {
        case .confirmation:
            confirmationContent
        case .sending:
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Studio.accent)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("報告を送信しています…")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Studio.primary)
                    .accessibilityFocused($titleFocused)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 210)
            .padding(24)
            .accessibilityIdentifier("chorus-report-sending")
        case .sent:
            VStack(spacing: 20) {
                ChorusReportSuccessMark()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("ご報告ありがとうございます")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Studio.primary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(24)
            .accessibilityIdentifier("chorus-report-success")
        }
    }

    private var confirmationContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "flag.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Studio.accent)
                .accessibilityHidden(true)
            Text("サビ位置の相違を報告しますか？")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(Studio.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            VStack(spacing: 4) {
                Text(report.song.title).font(.headline).foregroundStyle(Studio.primary)
                Text(report.song.artist).font(.subheadline).foregroundStyle(Studio.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach([
                    "匿名で開発者に送信します",
                    "曲情報・再生方法・開始位置を送ります",
                    "名前やアカウント情報は含みません"
                ], id: \.self) { explanation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").accessibilityHidden(true)
                        Text(explanation)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Studio.secondary)
            .multilineTextAlignment(.leading)
            if let error = model.chorusReportError {
                Text(error).font(.footnote).foregroundStyle(Studio.warning)
                    .accessibilityIdentifier("chorus-report-error")
            }
            VStack(spacing: 12) {
                Button {
                    Task { await model.submitChorusReport() }
                } label: {
                    Text("匿名で報告する").frame(maxWidth: .infinity)
                }
                .buttonStyle(StudioButtonStyle(.primary))
                .accessibilityIdentifier("chorus-report-confirm")
                Button("キャンセル", role: .cancel) { model.dismissChorusReport() }
                    .buttonStyle(StudioButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("chorus-report-cancel")
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
    }
}

private enum ChorusReportTiming {
    static let circle = 0.55
    static let check = 0.22
    static let successHold = 1.5
}

private struct ChorusReportSuccessMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var circleProgress: CGFloat = 0
    @State private var checkProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(Studio.success.opacity(0.10)).padding(4)
                .opacity(circleProgress)
            ClockwiseReportCircle()
                .trim(from: 0, to: circleProgress)
                .stroke(Studio.success, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ReportCheckmark()
                .trim(from: 0, to: checkProgress)
                .stroke(Studio.success, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
        .task(id: reduceMotion) {
            if reduceMotion {
                circleProgress = 1
                checkProgress = 1
                return
            }
            circleProgress = 0
            checkProgress = 0
            withAnimation(.easeInOut(duration: ChorusReportTiming.circle)) { circleProgress = 1 }
            do { try await Task.sleep(for: .seconds(ChorusReportTiming.circle)) } catch { return }
            withAnimation(.easeOut(duration: ChorusReportTiming.check)) { checkProgress = 1 }
        }
    }
}

/// Starts at twelve o'clock and follows top → right → bottom → left → top.
private struct ClockwiseReportCircle: Shape {
    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: 4, dy: 4)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2
        let control = radius * 0.55228475
        return Path { path in
            path.move(to: CGPoint(x: center.x, y: center.y - radius))
            path.addCurve(to: CGPoint(x: center.x + radius, y: center.y),
                          control1: CGPoint(x: center.x + control, y: center.y - radius),
                          control2: CGPoint(x: center.x + radius, y: center.y - control))
            path.addCurve(to: CGPoint(x: center.x, y: center.y + radius),
                          control1: CGPoint(x: center.x + radius, y: center.y + control),
                          control2: CGPoint(x: center.x + control, y: center.y + radius))
            path.addCurve(to: CGPoint(x: center.x - radius, y: center.y),
                          control1: CGPoint(x: center.x - control, y: center.y + radius),
                          control2: CGPoint(x: center.x - radius, y: center.y + control))
            path.addCurve(to: CGPoint(x: center.x, y: center.y - radius),
                          control1: CGPoint(x: center.x - radius, y: center.y - control),
                          control2: CGPoint(x: center.x - control, y: center.y - radius))
        }
    }
}

private struct ReportCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.51))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.69))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.34))
        }
    }
}
