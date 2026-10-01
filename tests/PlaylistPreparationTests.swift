import Foundation

@MainActor private final class Resolver {
    enum Failure: Error { case unavailable }
    var calls: [String] = []
    var active = 0
    var peak = 0
    var cancelled = 0
    var delay: [String: Int] = [:]
    var results: [String: Song] = [:]
    var missing = Set<String>()
    var failing = Set<String>()

    func resolve(_ song: Song) async throws -> Song? {
        calls.append(song.id)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: .milliseconds(delay[song.id] ?? 10)) }
        catch { cancelled += 1; throw error }
        if failing.contains(song.id) { throw Failure.unavailable }
        return missing.contains(song.id) ? nil : results[song.id] ?? song
    }
}

@main private struct PlaylistPreparationTests {
    static func song(_ id: String, title: String = "花火", preview: Bool = false) -> Song {
        Song(id: id, title: title, artist: "Artist", previewURL: preview ? URL(string: "https://example.com/\(id).m4a") : nil,
             durationMS: 180_000, genre: "Pop")
    }

    @MainActor static func main() async throws {
        try await concurrencyAndEarlyExit()
        try await cacheAndMetadataChanges()
        try await freshSongsAndDeduplication()
        try await missesAndFailures()
        try await cancellation()
        print("Playlist preparation tests passed")
    }

    @MainActor static func concurrencyAndEarlyExit() async throws {
        let preparation = PlaylistPreparation(concurrency: 3)
        let resolver = Resolver()
        let source = (0..<100).map { song(String($0)) }
        resolver.delay["2"] = 1000
        var progress: [Int] = []
        let songs = try await preparation.songs(from: source, count: 2, namespace: "applemusic",
            progress: { ready, total in
                precondition(total == 2)
                progress.append(ready)
            }, resolve: resolver.resolve)
        precondition(songs.count == 2)
        precondition(resolver.peak == 3, "Lookups must overlap within the concurrency limit")
        precondition(resolver.calls.count < source.count, "Stop scanning once enough fresh songs are ready")
        precondition(resolver.cancelled > 0, "Outstanding lookups should be cancelled")
        precondition(resolver.active == 0)
        precondition(progress.first == 0 && progress.last == 2 && progress == progress.sorted())
    }

    @MainActor static func cacheAndMetadataChanges() async throws {
        let preparation = PlaylistPreparation(concurrency: 2)
        let resolver = Resolver()
        let source = [song("a"), song("b")]
        let first = try await preparation.songs(from: source, count: 2, namespace: "applemusic",
            progress: { _, _ in }, resolve: resolver.resolve)
        let calls = resolver.calls.count
        let retry = try await preparation.songs(from: source.reversed(), count: 2, namespace: "applemusic",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(Set(first.map(\.id)) == Set(retry.map(\.id)))
        precondition(resolver.calls.count == calls, "A completed preparation must reuse its matches")
        _ = try await preparation.songs(from: [song("a", title: "青空")], count: 1, namespace: "applemusic",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(resolver.calls.count == calls + 1, "Changed song metadata must be resolved again")
        _ = try await preparation.songs(from: source, count: 2, namespace: "itunes:other-server",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(resolver.calls.count == calls + 3, "Provider caches must stay independent")
    }

    @MainActor static func freshSongsAndDeduplication() async throws {
        let preparation = PlaylistPreparation(concurrency: 3)
        let resolver = Resolver()
        resolver.results["library-a"] = song("catalog-a")
        resolver.results["library-duplicate"] = song("catalog-a")
        resolver.delay["fresh-b"] = 30
        resolver.delay["fresh-c"] = 50
        let source = [song("library-a"), song("library-a"), song("library-duplicate"), song("fresh-b"), song("fresh-c")]
        let fresh = try await preparation.songs(from: source, count: 2, playedIDs: ["catalog-a"], namespace: "applemusic",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(Set(fresh.map(\.id)) == ["fresh-b", "fresh-c"], "Fresh catalog IDs must take priority over played IDs")
        precondition(resolver.calls.filter { $0 == "library-a" }.count == 1)
        let fallback = try await preparation.songs(from: source, count: 3, playedIDs: ["catalog-a"], namespace: "applemusic",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(fallback.count == 3 && fallback.last?.id == "catalog-a")
        precondition(Set(fallback.map(\.id)).count == 3, "Distinct library IDs may resolve to the same catalog song")
    }

    @MainActor static func missesAndFailures() async throws {
        let preparation = PlaylistPreparation(concurrency: 2)
        let resolver = Resolver()
        resolver.missing = ["missing"]
        let source = [song("missing"), song("no-preview"), song("valid", preview: true), song("invalid", title: "♪", preview: true)]
        let result = try await preparation.songs(from: source, count: 2, namespace: "itunes", requiresPreview: true,
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(result.map(\.id) == ["valid"])
        let calls = resolver.calls.count
        _ = try await preparation.songs(from: source, count: 2, namespace: "itunes", requiresPreview: true,
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(resolver.calls.count == calls, "Completed no-match results should not trigger another scan")

        resolver.failing = ["retry"]
        do {
            _ = try await preparation.songs(from: [song("retry")], count: 1, namespace: "itunes",
                progress: { _, _ in }, resolve: resolver.resolve)
            preconditionFailure("Network failures must be reported")
        } catch Resolver.Failure.unavailable { }
        resolver.failing = []
        let recovered = try await preparation.songs(from: [song("retry")], count: 1, namespace: "itunes",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(recovered.count == 1 && resolver.calls.filter { $0 == "retry" }.count == 2)

        // MusicKit currently treats failed catalog lookups as no match. Do not cache those misses.
        _ = try await preparation.songs(from: [song("missing")], count: 1, namespace: "applemusic", cacheMisses: false,
            progress: { _, _ in }, resolve: resolver.resolve)
        resolver.missing = []
        let retried = try await preparation.songs(from: [song("missing")], count: 1, namespace: "applemusic", cacheMisses: false,
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(retried.count == 1)
    }

    @MainActor static func cancellation() async throws {
        let preparation = PlaylistPreparation(concurrency: 2)
        let resolver = Resolver()
        resolver.delay = ["a": 1000, "b": 1000]
        let source = [song("a"), song("b")]
        let task = Task { @MainActor in
            try await preparation.songs(from: source, count: 2, namespace: "applemusic",
                progress: { _, _ in }, resolve: resolver.resolve)
        }
        while resolver.calls.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled preparation must not return songs") }
        catch is CancellationError { }
        precondition(resolver.active == 0)
        resolver.delay = [:]
        let retry = try await preparation.songs(from: source, count: 2, namespace: "applemusic",
            progress: { _, _ in }, resolve: resolver.resolve)
        precondition(retry.count == 2, "Cancelled matches must be retried")
    }
}
