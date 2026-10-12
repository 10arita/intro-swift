import Foundation

private final class ArtworkProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var reply: (Int, Data)?

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    static func respond(status: Int = 200, data: Data?) {
        lock.lock(); defer { lock.unlock() }
        reply = data.map { (status, $0) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let reply = Self.reply
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            if let (status, data) = reply {
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            }
        }
    }

    override func stopLoading() {}
}

@main private struct ArtworkCacheTests {
    static let image = Data("valid artwork fixture".utf8)

    static func expectFailure(_ cache: ArtworkCache, url: URL) async {
        do {
            _ = try await cache.data(for: url)
            preconditionFailure("Invalid artwork must not be returned or cached")
        } catch {}
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func cache(_ name: String) -> ArtworkCache {
            ArtworkCache(directory: directory.appendingPathComponent(name), session: session,
                         isValidImage: { $0 == image })
        }
        let url = URL(string: "https://artwork.test/cover.jpg?size=300")!
        ArtworkProtocol.respond(data: image)
        let first = cache("relaunch")
        let downloaded = try await first.data(for: url)
        precondition(downloaded == image && ArtworkProtocol.requestCount == 1)
        ArtworkProtocol.respond(data: nil)
        let reloaded = try await cache("relaunch").data(for: url)
        precondition(reloaded == image && ArtworkProtocol.requestCount == 1,
                     "A cold launch must display saved artwork while the network is unavailable")

        // A broken entry is retried, and an offline failure must not poison the next request.
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("relaunch"),
                                                                 includingPropertiesForKeys: nil)
        try Data("broken".utf8).write(to: files[0])
        let recovery = cache("relaunch")
        await expectFailure(recovery, url: url)
        ArtworkProtocol.respond(data: image)
        let recovered = try await recovery.data(for: url)
        precondition(recovered == image && ArtworkProtocol.requestCount == 3,
                     "Corruption and transient failures must recover without restarting")

        let simultaneous = cache("simultaneous")
        let before = ArtworkProtocol.requestCount
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await simultaneous.data(for: url) } }
            for try await data in group { precondition(data == image) }
        }
        precondition(ArtworkProtocol.requestCount == before + 1,
                     "Background artwork, list rows, and preloading must share a single request")

        let cancelled = cache("cancelled")
        let abandoned = Task { try await cancelled.data(for: url) }
        while ArtworkProtocol.requestCount < before + 2 { await Task.yield() }
        abandoned.cancel()
        let visible = try await cancelled.data(for: url)
        precondition(visible == image && ArtworkProtocol.requestCount == before + 2,
                     "Removing one view must not cancel artwork needed by another view")
        _ = try await abandoned.value

        let invalid = cache("invalid")
        ArtworkProtocol.respond(status: 404, data: image)
        await expectFailure(invalid, url: url)
        ArtworkProtocol.respond(data: Data("not an image".utf8))
        await expectFailure(invalid, url: url)
        ArtworkProtocol.respond(status: 201, data: image)
        let valid = try await invalid.data(for: url)
        precondition(valid == image, "All successful HTTP statuses with decodable artwork must work")

        // Preserve the complete source URL, so different sizes/tokens cannot collide.
        ArtworkProtocol.respond(data: nil)
        await expectFailure(cache("relaunch"), url: URL(string: "https://artwork.test/cover.jpg?size=600")!)

        let localURL = directory.appendingPathComponent("local-cover")
        try image.write(to: localURL)
        let local = try await cache("local").data(for: localURL)
        precondition(local == image, "Device-local artwork must not require an HTTP response")
        try FileManager.default.removeItem(at: localURL)
        let localReloaded = try await cache("local").data(for: localURL)
        precondition(localReloaded == image, "A cached snapshot must survive removal of a temporary source file")
        print("Artwork cache tests passed (offline relaunch, corruption, retry, shared requests, cancellation, HTTP validation, local artwork)")
    }
}
