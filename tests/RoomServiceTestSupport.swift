import Foundation

// Platform-only dependencies are unused by these room transport tests.
struct GameAsset: Decodable {
    let id: String
    let artworkURL: URL?
    let previewURL: URL?
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

enum Secrets {
    static var values: [String: String] = [:]
    static func get(_ key: String) -> String? { values[key] }
    static func set(_ value: String?, for key: String) { values[key] = value }
}
