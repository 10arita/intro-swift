import Foundation
import Combine

enum FeedbackCategory: String, Encodable, CaseIterable, Identifiable {
    case bug
    case suggestion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bug: return "不具合・バグ"
        case .suggestion: return "ご意見・ご要望"
        }
    }

    var messagePrompt: String {
        switch self {
        case .bug: return "発生した問題や操作手順などをお聞かせください"
        case .suggestion: return "ご意見や追加してほしい機能などをお聞かせください"
        }
    }
}

/// Only the selected category, user-entered message, and app version accompany a random receipt ID.
struct FeedbackReport: Encodable, Identifiable {
    static let maximumMessageLength = 2_000
    let id: UUID
    let category: FeedbackCategory
    let message: String
    let appVersion: String
    let appBuild: String

    init(category: FeedbackCategory, message: String) {
        id = UUID()
        self.category = category
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static func isValid(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && message.utf16.count <= maximumMessageLength
    }
}

struct FeedbackReportService {
    var session: URLSession = .shared

    func send(_ report: FeedbackReport, serverURL: String) async throws {
        guard FeedbackReport.isValid(report.message) else {
            throw AppError.message("内容を1〜2,000文字で入力してください。")
        }
        try await AnonymousReportService(session: session).send(report, endpoint: "feedback", serverURL: serverURL)
    }
}

@MainActor
final class FeedbackReportModel: ObservableObject {
    @Published private(set) var presentationID: UUID?
    @Published var category: FeedbackCategory? {
        didSet {
            guard category != oldValue else { return }
            error = nil
            if let category, category != report?.category { report = nil }
        }
    }
    @Published var message = "" {
        didSet {
            guard message != oldValue else { return }
            error = nil
            report = nil
        }
    }
    @Published private(set) var sendingID: UUID?
    @Published private(set) var sentID: UUID?
    @Published private(set) var error: String?
    private var report: FeedbackReport?
    private let sender: (FeedbackReport, String) async throws -> Void

    var isSending: Bool { sendingID != nil }
    var isSent: Bool { sentID != nil }
    var canSubmit: Bool { category != nil && FeedbackReport.isValid(message) && !isSending && !isSent }

    init(sender: @escaping (FeedbackReport, String) async throws -> Void = { report, url in
        try await FeedbackReportService().send(report, serverURL: url)
    }) {
        self.sender = sender
    }

    func present() {
        guard presentationID == nil, !isSending else { return }
        presentationID = UUID()
    }

    func dismiss() {
        guard !isSending else { return }
        presentationID = nil
        category = nil
        message = ""
        report = nil
        sentID = nil
        error = nil
    }

    func submit(serverURL: String) async {
        guard presentationID != nil, canSubmit, let category else { return }
        let report = report ?? FeedbackReport(category: category, message: message)
        self.report = report
        sendingID = report.id
        error = nil
        defer { sendingID = nil }
        do {
            try await sender(report, serverURL)
            sentID = report.id
        } catch {
            self.error = "送信できませんでした。\n\(error.localizedDescription)"
        }
    }
}
