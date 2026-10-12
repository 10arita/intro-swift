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
    static func main() async throws {
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
        let preview = ChorusReport(song: song, source: .preview, startPositionMS: 0, playMode: "room")
        precondition(preview.playback.audioSource == "itunes_preview")
        for source in [RevealPlaybackSource.songleDatabase, .songle] {
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
        print("Chorus report tests passed (anonymous payload, playback provenance, receipt, retry ID, errors)")
    }
}
