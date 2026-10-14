import SwiftUI

struct RoomRevealSurface: ViewModifier {
  let room: RoomState
  func body(content: Content) -> some View {
    if let song = room.current?.song {
      content.modifier(RevealSurface(song: song))
    } else {
      content
    }
  }
}

struct RevealSurface: ViewModifier {
  let song: Song?
  func body(content: Content) -> some View {
    content
      .padding(20)
      .background {
        GeometryReader { geometry in
          Artwork(url: song?.artworkURL, size: max(geometry.size.width, geometry.size.height))
            .blur(radius: 30)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(Studio.surface.opacity(0.86))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.lg))
      .overlay(RoundedRectangle(cornerRadius: Studio.Radius.lg).strokeBorder(Studio.line))
  }
}
