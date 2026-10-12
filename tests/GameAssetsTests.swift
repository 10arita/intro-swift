import Foundation

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

@main struct GameAssetsTests {
    @MainActor static func main() async throws {
        let source = URL(string: CommandLine.arguments[1])!
        let asset = GameAsset(song: Song(id: "test:audio", title: "Test", artist: "Test",
                                         previewURL: source, durationMS: 30_000, genre: "Test"))
        do {
            try await GameAssets.shared.prepare([asset]) { _, _ in }
            throw AppError.message("Corrupt audio must fail validation")
        } catch {
            guard GameAssets.shared.audioURL(for: source) == source else {
                throw AppError.message("Corrupt audio is still cached; retry cannot recover")
            }
        }
        try await GameAssets.shared.prepare([asset]) { _, _ in }
        guard GameAssets.shared.audioURL(for: source).isFileURL else {
            throw AppError.message("A retry must download and cache valid audio")
        }
        print("Audio cache recovery passed: corrupt HTTP 200 audio evicted; valid retry prepared")
    }
}
