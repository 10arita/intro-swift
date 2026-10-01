import SwiftUI
import UIKit

enum PlayerAvatar {
    private static let fileName = "player-avatar.jpg"
    static let maximumBytes = 64_000

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    static func save(_ image: UIImage, crop: CGRect) throws -> Data {
        guard image.size.width > 0, image.size.height > 0,
              crop.width > 0, crop.height > 0,
              crop.minX >= 0, crop.minY >= 0,
              crop.maxX <= image.size.width + 0.01,
              crop.maxY <= image.size.height + 0.01 else {
            throw AppError.message("切り抜く範囲が無効です")
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        var jpeg: Data?
        for pixels in [384, 320, 256] {
            let side = CGFloat(pixels)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            let cropped = renderer.image { _ in
                let scale = side / crop.width
                image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                                      width: image.size.width * scale,
                                      height: image.size.height * scale))
            }
            for quality in [0.88, 0.78, 0.68] {
                if let data = cropped.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                    jpeg = data
                    break
                }
            }
            if jpeg != nil { break }
        }
        guard let jpeg else {
            throw AppError.message("画像をアイコン用に変換できませんでした")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try jpeg.write(to: fileURL, options: .atomic)
        return jpeg
    }

    static func remove() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static func store(_ data: Data?) throws {
        guard let data else { try remove(); return }
        guard data.count <= maximumBytes, UIImage(data: data) != nil else {
            throw AppError.message("保存されたアイコンの画像が無効です")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct PlayerAvatarView: View {
    let data: Data?
    var size: CGFloat = 24
    var encoded: String? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.52))
                    .foregroundStyle(Studio.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Studio.raised)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear(perform: updateImage)
        .onChange(of: data) { _, _ in updateImage() }
        .onChange(of: encoded) { _, _ in updateImage() }
    }

    private func updateImage() {
        let imageData = encoded.flatMap { Data(base64Encoded: $0) } ?? data
        image = imageData.flatMap(UIImage.init(data:))
    }
}
