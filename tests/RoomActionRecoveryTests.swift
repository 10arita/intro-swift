import Foundation

private final class TestRoomProtocol: URLProtocol {
    struct Reply {
        var state: [String: Any]?
        var error: Error?
        var status = 200
        var held = false
    }
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static var bodies: [[String: Any]] = []
    static var onRequest: ((URLRequest, [String: Any]) -> Void)?
    static var releaseReply: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        Self.bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
        Self.onRequest?(request, Self.bodies.last!)
        precondition(!Self.replies.isEmpty, "Unexpected request: \(request.url!)")
        let reply = Self.replies.removeFirst()
        if reply.held {
            Self.releaseReply = { [self] in finish(reply) }
        } else { finish(reply) }
    }
    private func finish(_ reply: Reply) {
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.state!))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main private struct RoomActionRecoveryTests {
    static func snapshot(phase: String, round: Int = -1, game: Int = 0, playerID: String,
                         ready: Bool = false, assetsReady: Bool = false) -> [String: Any] {
        ["id": "ABCDEF", "gameNumber": game, "mode": "applemusic", "hostId": playerID,
         "phase": phase, "round": round, "totalRounds": round < 0 ? 0 : 6,
         "settings": ["questionCount": 6, "answerSlots": 2, "targetScore": 50, "correctPoints": 10,
                      "firstBonus": 10, "wrongPenalty": 10, "firstWrongPenalty": 10, "lives": 3, "endless": false],
         "players": [], "serverNow": Date.now.timeIntervalSince1970 * 1000,
         "pushClosed": false, "answerProgress": "", "options": [], "activeAnswers": [], "pushedIds": [],
         "skippedIds": [], "readyIds": ready ? [playerID] : [],
         "assetsReadyIds": assetsReady ? [playerID] : [], "correctPlayerIDs": []]
    }

    @MainActor static func makeService() -> RoomService {
        Secrets.values = [:]
        TestRoomProtocol.requests = []
        TestRoomProtocol.replies = []
        TestRoomProtocol.bodies = []
        TestRoomProtocol.onRequest = nil
        TestRoomProtocol.releaseReply = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestRoomProtocol.self]
        let service = RoomService(session: URLSession(configuration: configuration))
        service.baseURL = "https://room.test"
        return service
    }

    @MainActor static func seed(_ service: RoomService, phase: String, round: Int = -1) async throws {
        TestRoomProtocol.replies = [.init(state: snapshot(phase: phase, round: round, playerID: service.playerId))]
        _ = try await service.state("ABCDEF")
        TestRoomProtocol.requests = []
        TestRoomProtocol.bodies = []
    }

    @MainActor static func main() async throws {
        try await lostAcknowledgement()
        try await requestLostBeforeStart()
        try await retryAcknowledgementLost()
        try await readinessRecovery()
        try await doNotRetryNewGameOrUnsafeAction()
        try await realFailuresRemainVisible()
        try await answerRetryKeepsActionID()
        try await profileRegistrationRecovery()
        try await obsoleteProfileResponse()
        try await publicRankPublication()
        try await expiredSessionErrors()
        print("Room action recovery tests passed")
    }

    @MainActor static func lostAcknowledgement() async throws {
        let service = makeService()
        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "preparing", round: 0, playerID: service.playerId))]
        let state = try await service.action("start", id: "ABCDEF", payload: ["songs": [["id": "applemusic:123"]]])
        precondition(state.phase == "preparing")
        precondition(TestRoomProtocol.requests.map(\.httpMethod) == ["POST", "GET"],
                     "A successful start must not be sent again after a lost acknowledgement")
    }

    @MainActor static func requestLostBeforeStart() async throws {
        let service = makeService()
        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "lobby", playerID: service.playerId)),
            .init(state: snapshot(phase: "preparing", round: 0, playerID: service.playerId))]
        let state = try await service.action("start", id: "ABCDEF", payload: ["songs": [["id": "applemusic:123"]]])
        precondition(state.phase == "preparing")
        precondition(TestRoomProtocol.requests.map(\.httpMethod) == ["POST", "GET", "POST"])
        let posts = TestRoomProtocol.requests.filter { $0.httpMethod == "POST" }
        precondition(posts[0].url == posts[1].url)
        precondition(NSDictionary(dictionary: TestRoomProtocol.bodies[0]).isEqual(to: TestRoomProtocol.bodies[2]),
                     "Retry must use the already prepared songs and the same settings")
    }

    @MainActor static func retryAcknowledgementLost() async throws {
        let service = makeService()
        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "lobby", playerID: service.playerId)),
            .init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "countdown", round: 0, playerID: service.playerId))]
        let state = try await service.action("start", id: "ABCDEF")
        precondition(state.phase == "countdown" && TestRoomProtocol.requests.count == 4)
    }

    @MainActor static func readinessRecovery() async throws {
        let service = makeService()
        try await seed(service, phase: "preparing", round: 0)
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "countdown", round: 0, playerID: service.playerId, ready: true))]
        let ready = try await service.action("ready", id: "ABCDEF")
        precondition(ready.phase == "countdown" && TestRoomProtocol.requests.count == 2)

        try await seed(service, phase: "preparing", round: 0)
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "preparing", round: 0, playerID: service.playerId)),
            .init(state: snapshot(phase: "countdown", round: 0, playerID: service.playerId, ready: true))]
        let retried = try await service.action("ready", id: "ABCDEF")
        precondition(retried.phase == "countdown" && TestRoomProtocol.requests.count == 3)

        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "lobby", playerID: service.playerId, assetsReady: true))]
        let assets = try await service.action("assets-ready", id: "ABCDEF")
        precondition(assets.assetsReadyIds?.contains(service.playerId) == true && TestRoomProtocol.requests.count == 2)

        try await seed(service, phase: "preparing", round: 0)
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "preparing", round: 1, playerID: service.playerId))]
        let advanced = try await service.action("ready", id: "ABCDEF")
        precondition(advanced.round == 1 && TestRoomProtocol.requests.count == 2,
                     "Old readiness must not be sent to the next round")
    }

    @MainActor static func doNotRetryNewGameOrUnsafeAction() async throws {
        let service = makeService()
        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "lobby", game: 1, playerID: service.playerId))]
        do { _ = try await service.action("start", id: "ABCDEF"); preconditionFailure("A new game must not be started") }
        catch { precondition(RoomService.isConnectionError(error)) }
        precondition(TestRoomProtocol.requests.count == 2)

        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "lobby", playerID: service.playerId)),
            .init(error: URLError(.networkConnectionLost)),
            .init(state: snapshot(phase: "lobby", playerID: service.playerId))]
        do { _ = try await service.action("start", id: "ABCDEF"); preconditionFailure("Unsuccessful retry must remain a failure") }
        catch { precondition(RoomService.isConnectionError(error)) }
        precondition(TestRoomProtocol.requests.count == 4, "Recovery must stop after one retry")

        try await seed(service, phase: "listening", round: 0)
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost))]
        do { _ = try await service.action("next", id: "ABCDEF"); preconditionFailure("Unsafe actions must not be replayed") }
        catch { precondition(RoomService.isConnectionError(error)) }
        precondition(TestRoomProtocol.requests.count == 1)
    }

    @MainActor static func realFailuresRemainVisible() async throws {
        let service = makeService()
        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)), .init(error: URLError(.notConnectedToInternet))]
        do { _ = try await service.action("start", id: "ABCDEF"); preconditionFailure("Unconfirmed starts must remain failures") }
        catch { precondition(RoomService.isConnectionError(error)) }
        precondition(TestRoomProtocol.requests.count == 2)

        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(state: ["error": "ホストのみ開始できます"], status: 403)]
        do { _ = try await service.action("start", id: "ABCDEF"); preconditionFailure("Server rejections must not be hidden") }
        catch let error as RoomHTTPError { precondition(error.status == 403) }
        precondition(TestRoomProtocol.requests.count == 1)

        try await seed(service, phase: "lobby")
        TestRoomProtocol.replies = [.init(error: URLError(.cancelled))]
        do { _ = try await service.action("start", id: "ABCDEF"); preconditionFailure("Cancelled requests must not be retried") }
        catch { precondition((error as NSError).code == URLError.cancelled.rawValue) }
        precondition(TestRoomProtocol.requests.count == 1)
    }

    @MainActor static func answerRetryKeepsActionID() async throws {
        let service = makeService()
        var answering = snapshot(phase: "answering", round: 0, playerID: service.playerId)
        answering["supportsChoiceRetry"] = true
        TestRoomProtocol.replies = [.init(state: answering)]
        _ = try await service.state("ABCDEF")
        TestRoomProtocol.requests = []
        TestRoomProtocol.bodies = []
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)), .init(state: answering)]
        _ = try await service.action("choose", id: "ABCDEF", payload: ["choice": "花"])
        precondition(TestRoomProtocol.requests.map(\.httpMethod) == ["POST", "POST"])
        let first = TestRoomProtocol.bodies[0]["actionId"] as? String
        let retry = TestRoomProtocol.bodies[1]["actionId"] as? String
        precondition(first != nil && first == retry, "Answer retry must preserve the server's deduplication key")
    }

    @MainActor static func profileRegistrationRecovery() async throws {
        let service = makeService()
        let key = "profileRegistration:\(service.baseURL):\(service.profileID)"
        TestRoomProtocol.onRequest = { request, body in
            guard request.httpMethod == "POST" else { return }
            precondition(body["registrationToken"] as? String == Secrets.get(key),
                         "Registration credentials must be durable before sending the request")
        }
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost))]
        do { _ = try await service.profile(); preconditionFailure("The lost response must remain a connection error") }
        catch { precondition(RoomService.isConnectionError(error)) }
        let registration = Secrets.get(key)!
        let firstBody = TestRoomProtocol.bodies[0]
        // Recreate the service to simulate restarting after the server committed registration.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestRoomProtocol.self]
        let restored = RoomService(session: URLSession(configuration: configuration))
        restored.baseURL = service.baseURL
        precondition(restored.profileID == service.profileID)
        TestRoomProtocol.replies = [.init(state: ["reviews": [], "history": [], "token": registration])]
        _ = try await restored.profile()
        precondition(NSDictionary(dictionary: firstBody).isEqual(to: TestRoomProtocol.bodies[1]),
                     "Registration retries must preserve identity and the original credential")
        precondition(Secrets.get(key) == nil && restored.profileCredentialSnapshot[service.baseURL] == registration)
        TestRoomProtocol.replies = [.init(state: ["reviews": [], "history": []])]
        _ = try await restored.profile()
        precondition(TestRoomProtocol.requests.last?.httpMethod == "GET")
        precondition(TestRoomProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(registration)")
    }

    @MainActor static func expiredSessionErrors() async throws {
        let service = makeService()
        for status in [403, 404] {
            TestRoomProtocol.replies = [.init(state: ["error": "参加していません"], status: status)]
            do { _ = try await service.state("ABCDEF"); preconditionFailure("Expired membership must fail") }
            catch { precondition(RoomService.isExpiredSession(error), "Session expiry must use HTTP status, not message text") }
        }
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost))]
        do { _ = try await service.state("ABCDEF"); preconditionFailure("Network failure must fail") }
        catch { precondition(!RoomService.isExpiredSession(error)) }
    }

    @MainActor static func publicRankPublication() async throws {
        let service = makeService()
        let credentialKey = "profileToken:\(service.baseURL):\(service.profileID)"
        Secrets.set("rank-token", for: credentialKey)
        TestRoomProtocol.replies = [.init(state: [:])]
        try await service.publishProfile(name: "Rank player", avatar: nil, stats: PlayerStats())
        precondition(TestRoomProtocol.bodies.last?["highestRankLevel"] == nil, "Unmeasured or legacy publications omit the rank")
        for level in 0...10 {
            TestRoomProtocol.replies = [.init(state: [:])]
            try await service.publishProfile(name: "Rank player", avatar: nil, stats: PlayerStats(), highestRankLevel: level)
            precondition(TestRoomProtocol.bodies.last?["highestRankLevel"] as? Int == level)
            precondition(TestRoomProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer rank-token")
            precondition(TestRoomProtocol.bodies.last?["rankRecords"] == nil, "Only the badge summary is published")
        }
        let beforeInvalid = TestRoomProtocol.requests.count
        for invalid in [-1, 11] {
            do {
                try await service.publishProfile(name: "Rank player", avatar: nil, stats: PlayerStats(), highestRankLevel: invalid)
                preconditionFailure("Invalid rank publication must fail")
            } catch { precondition(!(error is CancellationError)) }
        }
        precondition(TestRoomProtocol.requests.count == beforeInvalid, "Invalid ranks never leave the client")
        let old = try JSONDecoder().decode(PlayerProfile.self, from: Data(#"{"name":"Old player"}"#.utf8))
        precondition(old.highestRankLevel == nil, "An older server's response remains readable")
        TestRoomProtocol.replies = [.init(state: ["name": "Rank player", "highestRankLevel": 0])]
        let measuredF = try await service.playerProfile(friendID: "friend-rank")
        precondition(measuredF.highestRankLevel == 0, "Measured F must remain different from unmeasured")
        TestRoomProtocol.replies = [.init(error: URLError(.networkConnectionLost)), .init(state: [:])]
        do {
            try await service.publishProfile(name: "Rank player", avatar: nil, stats: PlayerStats(), highestRankLevel: 8)
            preconditionFailure("A publication failure must be visible to its caller")
        } catch { precondition(RoomService.isConnectionError(error)) }
        try await service.publishProfile(name: "Rank player", avatar: nil, stats: PlayerStats(), highestRankLevel: 8)
        precondition(Secrets.get(credentialKey) == "rank-token", "Publication retries retain the profile identity")
        TestRoomProtocol.replies = [.init(state: [:], held: true)]
        let pending = Task { @MainActor in
            try await service.publishProfile(name: "Rank player", avatar: nil, stats: PlayerStats(), highestRankLevel: 8)
        }
        while TestRoomProtocol.releaseReply == nil { await Task.yield() }
        service.restoreProfileIdentity("replacement-rank-profile", credentials: [:])
        TestRoomProtocol.releaseReply!()
        do { try await pending.value; preconditionFailure("An obsolete publication cannot complete for the new profile") }
        catch is CancellationError { }
    }

    @MainActor static func obsoleteProfileResponse() async throws {
        for changeOrigin in [false, true] {
            let service = makeService()
            let originalKey = "profileRegistration:\(service.baseURL):\(service.profileID)"
            TestRoomProtocol.replies = [.init(state: ["reviews": [], "history": [], "token": "old-account-token"], held: true)]
            let pending = Task { @MainActor in try await service.profile() }
            while TestRoomProtocol.releaseReply == nil { await Task.yield() }
            if changeOrigin { service.baseURL = "https://replacement.test" }
            else { service.restoreProfileIdentity("replacement-profile", credentials: [:]) }
            TestRoomProtocol.releaseReply!()
            do {
                _ = try await pending.value
                preconditionFailure("An obsolete profile response must not be applied")
            } catch is CancellationError { }
            precondition(service.profileCredentialSnapshot.isEmpty,
                         "An old response must never install its bearer token for a different account or server")
            precondition(Secrets.get(originalKey) != nil,
                         "Keep the original registration credential for a future retry of that identity")
        }
    }
}
