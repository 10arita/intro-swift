import SwiftUI

struct RoomRevealSurface: ViewModifier {
  let room: RoomState
  let playerID: String
  func body(content: Content) -> some View {
    if let song = room.current?.song {
      content.modifier(RevealSurface(song: song, correct: room.correctPlayerIDs.contains(playerID)))
    } else {
      content
    }
  }
}

struct RevealSurface: ViewModifier {
  let song: Song?
  let correct: Bool
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
      .overlay { if correct { CelebrationConfetti() } }
      .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.lg))
      .overlay(RoundedRectangle(cornerRadius: Studio.Radius.lg).strokeBorder(Studio.line))
  }
}

private struct CelebrationConfetti: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt = Date.now
  @State private var active = false
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { timeline in
      Canvas { context, size in
        guard active, !reduceMotion else { return }
        let progress = min(1, max(0, timeline.date.timeIntervalSince(startedAt) / 2.2))
        for index in 0..<36 {
          let seed = Double(index)
          let x = (seed * 0.618).truncatingRemainder(dividingBy: 1) * size.width
          let delay = (seed * 0.137).truncatingRemainder(dividingBy: 0.28)
          let travel = max(0, (progress - delay) / (1 - delay))
          guard travel > 0 else { continue }
          var particle = context
          particle.opacity = max(0, 1 - travel)
          particle.translateBy(
            x: x + sin(travel * 7 + seed) * 16, y: -12 + travel * (size.height + 24))
          particle.rotate(by: .radians(travel * 9 + seed))
          let colors = [Studio.success, Studio.accent, Studio.gold]
          particle.fill(
            Path(CGRect(x: -3, y: -5, width: 6, height: 10)), with: .color(colors[index % 3]))
        }
      }
    }
    .allowsHitTesting(false).accessibilityHidden(true)
    .task {
      guard !reduceMotion else { return }
      startedAt = .now
      active = true
      do { try await Task.sleep(for: .milliseconds(2300)) } catch { return }
      active = false
    }
  }
}
