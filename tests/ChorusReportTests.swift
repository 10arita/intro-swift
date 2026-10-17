import Foundation

private final class ChorusReportProtocol: URLProtocol {
    static var status = 200
    static var reply = Data()
    static var failure: Error?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main private struct ChorusReportTests {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChorusReportProtocol.self]
        let service = ChorusReportService(session: URLSession(configuration: configuration))
        let song = Song(id: "applemusic:123", title: "青い空", artist: "歌手", durationMS: 180_000, genre: "J-Pop")
        let report = ChorusReport(song: song, source: .manualDatabase, startPositionMS: 48_681, playMode: "solo")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        precondition(Set(body.keys) == ["id", "song", "playback", "playMode", "appVersion", "appBuild"])
        let track = body["song"] as! [String: Any]
        precondition(Set(track.keys) == ["id", "title", "artist", "durationMS", "genre"])
        let playback = body["playback"] as! [String: Any]
        precondition(playback["source"] as? String == "manual_database")
        precondition(playback["startPositionMS"] as? Int == 48_681)
        precondition(playback["audioSource"] as? String == "apple_music")
        let estimated = ChorusReport(song: song, source: .estimated, startPositionMS: 56_100, playMode: "room")
        precondition(estimated.playback.source == .estimated && estimated.playback.audioSource == "apple_music")
        for source in [RevealPlaybackSource.manualDatabase, .songleDatabase] {
            let report = ChorusReport(song: song, source: source, startPositionMS: 63_500, playMode: "room")
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
            let playback = body["playback"] as! [String: Any]
            precondition(playback["source"] as? String == source.rawValue)
            precondition(playback["audioSource"] as? String == "apple_music")
            precondition(playback["startPositionMS"] as? Int == 63_500)
        }

        ChorusReportProtocol.reply = Data(#"{"delivered":true}"#.utf8)
        try await service.send(report, serverURL: "https://quiz.test")
        let request = ChorusReportProtocol.requests.last!
        precondition(request.url?.path == "/chorus-reports" && request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        try await service.send(report, serverURL: "https://quiz.test")
        precondition(ChorusReportProtocol.requests[0].httpBody == ChorusReportProtocol.requests[1].httpBody,
                     "Retries retain the anonymous report ID")

        for (status, reply) in [(200, #"{"delivered":false}"#), (200, #"{}"#), (503, #"{"error":"受付は停止中です"}"#)] {
            ChorusReportProtocol.status = status
            ChorusReportProtocol.reply = Data(reply.utf8)
            do { try await service.send(report, serverURL: "https://quiz.test"); preconditionFailure("Delivery must be confirmed") }
            catch { if status == 503 { precondition(error.localizedDescription == "受付は停止中です") } }
        }
        let requestCount = ChorusReportProtocol.requests.count
        do { try await service.send(report, serverURL: ""); preconditionFailure("Missing configuration cannot send") }
        catch { precondition(ChorusReportProtocol.requests.count == requestCount) }
        ChorusReportProtocol.failure = URLError(.notConnectedToInternet)
        do { try await service.send(report, serverURL: "https://quiz.test"); preconditionFailure("Offline requests must fail") }
        catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        try await testFeedbackService(session: service.session)
        await testFeedbackModel()
        print("Chorus and feedback report tests passed (anonymous payload, receipts, validation, retry IDs, errors, state)")
    }

    @MainActor private static func testFeedbackService(session: URLSession) async throws {
        ChorusReportProtocol.failure = nil
        ChorusReportProtocol.status = 200
        ChorusReportProtocol.reply = Data(#"{"delivered":true}"#.utf8)
        let service = FeedbackReportService(session: session)
        let report = FeedbackReport(category: .suggestion, message: "  ご意見です。\n改善をお願いします。  ")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        precondition(Set(body.keys) == ["id", "category", "message", "appVersion", "appBuild"])
        precondition(body["category"] as? String == "suggestion")
        precondition(report.message == "ご意見です。\n改善をお願いします。")
        for text in ["", " \n\t", String(repeating: "あ", count: 2_001), String(repeating: "🎵", count: 1_001)] {
            precondition(!FeedbackReport.isValid(text))
        }
        precondition(FeedbackReport.isValid(String(repeating: "あ", count: 2_000)))
        precondition(FeedbackReport.isValid(String(repeating: "🎵", count: 1_000)))
        try await service.send(report, serverURL: "https://quiz.test")
        let request = ChorusReportProtocol.requests.last!
        precondition(request.url?.path == "/feedback" && request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        try await service.send(report, serverURL: "https://quiz.test")
        precondition(request.httpBody == ChorusReportProtocol.requests.last!.httpBody)
        let bugReport = FeedbackReport(category: .bug, message: "画面が動かなくなりました")
        try await service.send(bugReport, serverURL: "https://quiz.test")
        let bugBody = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bugReport)) as! [String: Any]
        precondition(bugBody["category"] as? String == "bug")
        for (status, reply) in [(200, #"{"delivered":false}"#), (200, #"{}"#), (503, #"{"error":"受付は停止中です"}"#)] {
            ChorusReportProtocol.status = status
            ChorusReportProtocol.reply = Data(reply.utf8)
            do { try await service.send(report, serverURL: "https://quiz.test"); preconditionFailure("Receipt required") }
            catch { if status == 503 { precondition(error.localizedDescription == "受付は停止中です") } }
        }
        let requestCount = ChorusReportProtocol.requests.count
        for url in ["", "http://quiz.test"] {
            do { try await service.send(report, serverURL: url); preconditionFailure("Unsafe or missing configuration") }
            catch { precondition(ChorusReportProtocol.requests.count == requestCount) }
        }
        do { try await service.send(FeedbackReport(category: .bug, message: " "), serverURL: "https://quiz.test"); preconditionFailure("Empty message") }
        catch { precondition(ChorusReportProtocol.requests.count == requestCount) }
        ChorusReportProtocol.failure = URLError(.notConnectedToInternet)
        do { try await service.send(report, serverURL: "https://quiz.test"); preconditionFailure("Offline") }
        catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
    }

    @MainActor private static func testFeedbackModel() async {
        var attempts: [FeedbackReport] = []
        var shouldFail = true
        let model = FeedbackReportModel { report, url in
            precondition(url == "https://quiz.test")
            attempts.append(report)
            if shouldFail { throw URLError(.notConnectedToInternet) }
        }
        model.present()
        precondition(model.category == nil && !model.canSubmit)
        model.message = "問い合わせ"
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts.isEmpty && !model.canSubmit, "A category must be explicitly selected")
        model.category = .bug
        model.message = " \n "
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts.isEmpty && !model.canSubmit)
        model.message = "問い合わせ"
        await model.submit(serverURL: "https://quiz.test")
        precondition(model.error != nil && model.category == .bug && model.message == "問い合わせ" && model.canSubmit)
        precondition(attempts[0].category == .bug)
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts[0].id == attempts[1].id, "Retries keep the same receipt ID")
        model.category = nil
        precondition(model.message == "問い合わせ" && model.error == nil && !model.canSubmit)
        model.category = .bug
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts[2].id == attempts[1].id, "Reselecting the same category keeps the retry receipt")
        model.category = .suggestion
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts[3].category == .suggestion && attempts[3].id != attempts[2].id,
                     "Changed categories need a fresh receipt and retain the message")
        model.category = .suggestion
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts[3].id == attempts[4].id, "Unchanged categories keep the retry receipt")
        model.message = "内容を修正した問い合わせ"
        precondition(model.error == nil)
        shouldFail = false
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts[5].id != attempts[4].id, "Edited content needs a fresh receipt")
        precondition(model.isSent && !model.canSubmit)
        await model.submit(serverURL: "https://quiz.test")
        precondition(attempts.count == 6)
        model.dismiss()
        precondition(model.presentationID == nil && model.category == nil && model.message.isEmpty && !model.isSent)
        model.present()
        precondition(model.category == nil && !model.canSubmit, "Reopening starts at category selection")
        model.dismiss()

        var release: CheckedContinuation<Void, Never>?
        var sends = 0
        let pending = FeedbackReportModel { _, _ in
            sends += 1
            await withCheckedContinuation { release = $0 }
        }
        pending.present()
        pending.category = .bug
        pending.message = "送信中の問い合わせ"
        let sending = Task { await pending.submit(serverURL: "https://quiz.test") }
        while release == nil { await Task.yield() }
        precondition(pending.isSending)
        let presentationID = pending.presentationID
        pending.dismiss()
        pending.present()
        precondition(pending.presentationID == presentationID, "Sending modal cannot be dismissed or replaced")
        await pending.submit(serverURL: "https://quiz.test")
        precondition(sends == 1, "Repeated taps cannot start a second delivery")
        release?.resume()
        await sending.value
        precondition(pending.isSent && !pending.isSending)
    }
}
