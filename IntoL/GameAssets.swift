import Foundation
import UIKit
import AVFoundation
import CryptoKit

struct GameAsset: Decodable {
    let id: String
    let artworkURL: URL?
    let previewURL: URL?

    init(song: Song) {
        id = song.id
        artworkURL = song.artworkURL
        previewURL = song.previewURL
    }
}

/// Temporary, per-install cache for audio that the app is allowed to fetch directly.
/// Apple Music audio stays in MusicKit rather than being cached by the app.
@MainActor final class GameAssets {
    static let shared = GameAssets()
    private var audio: [URL: URL] = [:]
    private let images = NSCache<NSURL, UIImage>()
    private let artwork = ArtworkCache { UIImage(data: $0) != nil }

    private init() { images.totalCostLimit = 32 * 1024 * 1024 }

    func audioURL(for url: URL) -> URL { audio[url] ?? url }
    func image(for url: URL?) -> UIImage? { url.flatMap { images.object(forKey: $0 as NSURL) } }

    func loadImage(_ url: URL) async throws -> UIImage {
        if let image = image(for: url) { return image }
        let data = try await artwork.data(for: url)
        guard let image = UIImage(data: data) else {
            throw AppError.message("ジャケット画像を準備できませんでした。通信を確認してください")
        }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }

    func prepareImage(_ url: URL) async throws {
        _ = try await loadImage(url)
    }

    func prepare(_ assets: [GameAsset], progress: (Int, Int) -> Void) async throws {
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            if let artwork = asset.artworkURL { try await prepareImage(artwork) }
            if let source = asset.previewURL {
                if source.isFileURL {
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw AppError.message("音源ファイルが見つかりません")
                    }
                } else {
                    if let cached = audio[source], !FileManager.default.fileExists(atPath: cached.path) {
                        audio[source] = nil
                    }
                    if audio[source] == nil {
                        let (download, response) = try await URLSession.shared.download(from: source)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw AppError.message("音源を準備できませんでした。通信を確認してください")
                        }
                        let digest = SHA256.hash(data: Data(source.absoluteString.utf8))
                            .map { String(format: "%02x", $0) }.joined()
                        let file = FileManager.default.temporaryDirectory
                            .appendingPathComponent("intol-\(digest).\(source.pathExtension.isEmpty ? "audio" : source.pathExtension)")
                        try? FileManager.default.removeItem(at: file)
                        try FileManager.default.moveItem(at: download, to: file)
                        audio[source] = file
                    }
                }
                let playable = AVURLAsset(url: audioURL(for: source))
                guard try await playable.load(.isPlayable) else {
                    throw AppError.message("準備した音源を再生できません")
                }
            }
            progress(index + 1, assets.count)
        }
    }
}
