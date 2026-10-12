import Foundation
import CryptoKit

/// Artwork bytes are shared by preloading and every artwork view, including after a relaunch.
actor ArtworkCache {
    private let directory: URL
    private let session: URLSession
    private let isValidImage: @Sendable (Data) -> Bool
    private let memory = NSCache<NSURL, NSData>()
    private var requests: [URL: Task<Data, Error>] = [:]
    private let diskLimit = 64 * 1024 * 1024

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IntoLArtwork", isDirectory: true),
         session: URLSession = .shared, isValidImage: @escaping @Sendable (Data) -> Bool) {
        self.directory = directory
        self.session = session
        self.isValidImage = isValidImage
        memory.totalCostLimit = 16 * 1024 * 1024
    }

    func data(for url: URL) async throws -> Data {
        if let data = memory.object(forKey: url as NSURL) { return data as Data }
        let file = cacheURL(for: url)
        if let data = try? Data(contentsOf: file), isValidImage(data) {
            memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return data
        }
        // An incomplete or corrupt disk entry must never prevent a fresh download.
        try? FileManager.default.removeItem(at: file)
        if let request = requests[url] { return try await request.value }
        let request = Task {
            let data: Data
            if url.isFileURL {
                data = try Data(contentsOf: url)
            } else {
                let (download, response) = try await session.data(from: url)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                data = download
            }
            guard isValidImage(data) else { throw URLError(.cannotDecodeContentData) }
            memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            // Cache write failures should not hide an image that was successfully fetched.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            trimDiskCache()
            return data
        }
        requests[url] = request
        defer { requests[url] = nil }
        return try await request.value
    }

    private func cacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("image")
    }

    private func trimDiskCache() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.filter { $0.pathExtension == "image" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where size > diskLimit {
            if (try? FileManager.default.removeItem(at: url)) != nil { size -= bytes }
        }
    }
}
