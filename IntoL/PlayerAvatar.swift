import ImageIO
import SwiftUI
import UIKit

enum PlayerAvatar {
    private static let fileName = "player-avatar.jpg"

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    static func save(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary) else {
            throw AppError.message("画像を読み込めませんでした")
        }
        let image = UIImage(cgImage: thumbnail)
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: format)
        let cropped = renderer.image { _ in
            image.draw(in: CGRect(x: -origin.x * 80 / side, y: -origin.y * 80 / side,
                                  width: image.size.width * 80 / side,
                                  height: image.size.height * 80 / side))
        }
        guard let jpeg = cropped.jpegData(compressionQuality: 0.65), jpeg.count <= 12_000 else {
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
