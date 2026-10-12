import Foundation
import Combine

/// Only the user-entered message and app version accompany a random receipt ID.
struct FeedbackReport: Encodable, Identifiable {
    static let maximumMessageLength = 2_000
    let id: UUID
    let message: String
    let appVersion: String
    let appBuild: String

    init(message: String) {
        id = UUID()
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
    var canSubmit: Bool { FeedbackReport.isValid(message) && !isSending && !isSent }

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
        message = ""
        report = nil
        sentID = nil
        error = nil
    }

    func submit(serverURL: String) async {
        guard presentationID != nil, canSubmit else { return }
        let report = report ?? FeedbackReport(message: message)
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
