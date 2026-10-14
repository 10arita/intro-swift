import Foundation

/// Resolves a small window of playlist songs concurrently and reuses completed matches.
@MainActor final class PlaylistPreparation {
    private struct CacheKey: Hashable {
        let namespace: String
        let source: Song
    }

    private struct Match {
        let song: Song?
    }

    private var matches: [CacheKey: Match] = [:]
    private let concurrency: Int

    init(concurrency: Int = 6) {
        self.concurrency = max(1, concurrency)
    }

    func songs(from source: [Song], count: Int, playedIDs: Set<String> = [],
               namespace: String, cacheMisses: Bool = true,
               progress: (Int, Int) -> Void,
               resolve: @escaping @MainActor (Song) async throws -> Song?) async throws -> [Song] {
        guard count > 0 else { return [] }
        try Task.checkCancellation()
        var sourceIDs = Set<String>()
        let unique = source.filter { sourceIDs.insert($0.id).inserted }
        // Keep the caller's shuffled order among fresh/unknown songs so that the
        // cache does not make every new game reuse the same small set of questions.
        // Known played songs remain a fallback.
        func priority(_ song: Song) -> Int {
            guard let cached = matches[CacheKey(namespace: namespace, source: song)] else { return 1 }
            guard let match = cached.song,
                  !TitleRules.characters(match.title).isEmpty else { return 3 }
            return playedIDs.contains(match.id) ? 2 : 1
        }
        let ordered = unique.enumerated().sorted {
            let left = priority($0.element), right = priority($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        let candidates = ordered

        return try await withThrowingTaskGroup(of: Song?.self) { group in
            var next = 0
            var fresh: [Song] = []
            var used: [Song] = []
            var seen = Set<String>()

            func enqueue() {
                guard next < candidates.count else { return }
                let sourceSong = candidates[next]
                next += 1
                group.addTask { @MainActor in
                    try Task.checkCancellation()
                    let key = CacheKey(namespace: namespace, source: sourceSong)
                    if let cached = self.matches[key] { return cached.song }
                    let match = try await resolve(sourceSong)
                    // A cancelled or failed lookup must remain retryable.
                    try Task.checkCancellation()
                    if match != nil || cacheMisses { self.matches[key] = Match(song: match) }
                    return match
                }
            }

            progress(0, count)
            for _ in 0..<min(concurrency, candidates.count) { enqueue() }
            while let match = try await group.next() {
                try Task.checkCancellation()
                if let match,
                   !TitleRules.characters(match.title).isEmpty, seen.insert(match.id).inserted {
                    if playedIDs.contains(match.id) { used.append(match) }
                    else { fresh.append(match) }
                }
                progress(min(count, fresh.count), count)
                if fresh.count >= count {
                    group.cancelAll()
                    break
                }
                enqueue()
            }
            try Task.checkCancellation()
            let selected = Array((fresh + used).prefix(count))
            progress(selected.count, count)
            return selected
        }
    }
}
