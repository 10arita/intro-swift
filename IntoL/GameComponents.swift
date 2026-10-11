import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct SongRow: View {
    let song: Song
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: song.artworkURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(Studio.primary)
                Text(song.artist).font(.caption).lineLimit(1).foregroundStyle(Studio.secondary)
            }
            Spacer()
            Image(systemName: "waveform").foregroundStyle(Studio.accent).font(.caption)
        }
    }
}

struct HomeWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var isActive = true

    var body: some View {
        Group {
            if reduceMotion || !isActive || scenePhase != .active {
                HomeWaveformDrawing(amplitude: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 1.4
                    HomeWaveformDrawing(amplitude: 0.88 + 0.12 * sin(phase))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HomeWaveformDrawing: View {
    let amplitude: Double
    var body: some View {
        Canvas { context, size in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: 2 + x * max(0, size.width - 4),
                        y: (0.58 + (y - 0.58) * amplitude) * size.height)
            }
            var path = Path()
            path.move(to: point(0, 0.58))
            path.addLine(to: point(0.20, 0.58))
            path.addCurve(to: point(0.34, 0.58),
                          control1: point(0.25, 0.35), control2: point(0.28, 0.35))
            path.addLine(to: point(0.40, 0.58))
            path.addLine(to: point(0.43, 0.66))
            path.addLine(to: point(0.47, 0.08))
            path.addLine(to: point(0.52, 0.88))
            path.addLine(to: point(0.57, 0.58))
            path.addLine(to: point(0.63, 0.58))
            path.addCurve(to: point(0.78, 0.58),
                          control1: point(0.67, 0.29), control2: point(0.73, 0.29))
            path.addLine(to: point(1, 0.58))
            context.stroke(path, with: .color(Studio.accent),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct WaveMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var isPlaying = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isPlaying || reduceMotion || scenePhase != .active)) { timeline in
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<25, id: \.self) { i in
                    let base = Double([10,18,28,14,36,23,12,30,17,40,22,12,33,18,42,25,14,35,20,11,30,19,25,13,8][i])
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 6 + Double(i) * 0.7
                    Capsule()
                        .fill(i.isMultiple(of: 3) ? Studio.accent : Studio.accent.opacity(0.5))
                        .frame(width: 3, height: isPlaying && !reduceMotion ? base * (0.45 + 0.55 * abs(sin(phase))) : base)
                }
            }
            .frame(height: 44)
        }
        .accessibilityHidden(true)
    }
}

struct CountdownBar: View {
    let remaining: Double
    let total: Double
    var compact = false
    var hapticsEnabled = true
    private var wholeSeconds: Int { Int(ceil(max(0, remaining))) }
    var body: some View {
        VStack(spacing: compact ? 4 : 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: total == 30 ? "%.2f" : "%.1f", remaining))
                    .font(.system(size: compact ? 34 : 56, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(remaining < 5 ? Studio.warning : Studio.primary)
                Text("SEC").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Studio.secondary)
                Spacer()
            }
            GeometryReader { geometry in
                Capsule().fill(Studio.raised)
                    .overlay(alignment: .leading) {
                        Capsule().fill(remaining < 5 ? Studio.warning : Studio.accent)
                            .frame(width: max(0, geometry.size.width * min(1, remaining / total)))
                    }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("残り時間 \(String(format: total == 30 ? "%.2f" : "%.1f", remaining))秒")
        .sensoryFeedback(.impact(weight: .light), trigger: wholeSeconds) { old, new in
            hapticsEnabled && (1...5).contains(new) && new < old
        }
    }
}

struct PreparationProgressView: View {
    let status: String
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Studio.primary)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: min(1, max(0, progress)))
                .progressViewStyle(.linear)
                .tint(Studio.accent)
                .environment(\.layoutDirection, .leftToRight)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)
                .accessibilityLabel("ゲームの準備")
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.md).strokeBorder(Studio.line))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Studio.background)
    }
}

struct PushButton: View {
    let action: () -> Void
    var size: CGFloat = 256
    var pending = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                if pending {
                    ProgressView().tint(Studio.onAccent)
                    Text("判定中").font(.system(size: size * 0.115, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "hand.tap.fill").font(.system(size: size * 0.105))
                    Text("PUSH").font(.system(size: size * 0.152, weight: .black, design: .rounded)).tracking(-2)
                }
            }
            .foregroundStyle(Studio.onAccent)
        }
        .buttonStyle(PushButtonStyle(size: size, pending: pending))
        .disabled(pending)
        .accessibilityLabel(pending ? "PUSHを判定中" : "PUSH、解答する")
    }
}

private struct PushButtonStyle: ButtonStyle {
    let size: CGFloat
    let pending: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || pending
        let faceSize = size * 0.742
        let depth = size * 0.03

        return ZStack {
            Circle().strokeBorder(Studio.line, lineWidth: 1)
            Circle().strokeBorder(Studio.accent.opacity(0.35), lineWidth: 1)
                .frame(width: size * 0.875, height: size * 0.875)
            Circle().fill(Studio.accent)
                .brightness(-0.22)
                .frame(width: faceSize, height: faceSize)
                .offset(y: depth / 2)
            configuration.label
                .frame(width: faceSize, height: faceSize)
                .background(Studio.accent, in: Circle())
                .brightness(pressed ? -0.08 : 0)
                .shadow(color: Studio.accent.opacity(pressed ? 0.10 : 0.25),
                        radius: pressed ? 1 : depth, x: 0, y: pressed ? 1 : depth)
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
                .offset(y: reduceMotion ? -depth / 2 : (pressed ? depth / 2 : -depth / 2))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .animation(reduceMotion ? nil : (pressed ? .easeOut(duration: 0.08) :
            .spring(response: 0.22, dampingFraction: 0.72)), value: pressed)
        .sensoryFeedback(.impact(weight: .heavy), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

struct RevealCard: View {
    let song: Song
    let correct: Bool
    let saved: Bool
    let save: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: correct ? "checkmark.circle.fill" : "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(correct ? Studio.success : Studio.secondary)
            Text(correct ? "正解！" : "この曲でした")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(Studio.primary)
            Artwork(url: song.artworkURL, size: 144)
            VStack(spacing: 6) {
                Text(song.title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Studio.primary)
                    .multilineTextAlignment(.center)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundStyle(Studio.secondary)
            }
            Button(action: save) {
                Label(saved ? "復習リストに保存済み" : "復習リストに追加", systemImage: saved ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(StudioButtonStyle(.secondary))
            .disabled(saved)
            if let url = song.trackURL {
                Link(destination: url) {
                    Label("曲のリンクを開く", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.accent)
                }
            }
            ChorusReportButton(song: song)
        }
        .frame(maxWidth: .infinity)
        .modifier(RevealSurface(song: song, correct: correct))
    }
}
