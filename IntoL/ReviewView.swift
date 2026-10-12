import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var reviewPlayer = PreviewPlayer()
    @State private var learned = false
    @State private var activeSongID: String?
    @State private var loadingSongID: String?
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackMonitor: Task<Void, Never>?
    @State private var playbackError: String?
    @State private var usesAppleMusic = false
    @State private var playbackPosition: TimeInterval = 0
    @State private var playbackDuration: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var isSeeking = false
    @State private var seekTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [ReviewFrame: CGRect] = [:]
    @State private var flights: [ReviewFlight] = []
    @State private var learnedPop = 0
    @State private var unlearnedPop = 0

    private var items: [ReviewSong] { model.reviews.filter { $0.learned == learned } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("復習")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Studio.primary)
                            .accessibilityAddTraits(.isHeader)
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("出会った曲を、次は思い出せるように。")
                                .foregroundStyle(Studio.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        reviewSegments
                        Text("左にスワイプして削除")
                            .font(.caption)
                            .foregroundStyle(Studio.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .fixedSize(horizontal: false, vertical: true)

                    List {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ReviewSongRow(item: item,
                                          isPlaying: activeSongID == item.id && loadingSongID == nil,
                                          isLoading: loadingSongID == item.id,
                                          playbackPosition: $playbackPosition,
                                          playbackDuration: playbackDuration,
                                          isScrubbing: $isScrubbing,
                                          seek: { seekPlayback(to: $0) },
                                          togglePlayback: { togglePlayback(item.song) },
                                          toggleLearned: { moveReview(item) })
                                .modifier(ReviewEntrance(index: index))
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button("削除", role: .destructive) { removeReview(item) }
                                }
                                .accessibilityAction(named: "復習リストから削除") { removeReview(item) }
                        }
                    }
                    .id(learned)
                    .transition(.identity)
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.bottom, 16, for: .scrollContent)
                    .environment(\.defaultMinListRowHeight, 0)
                    .overlay {
                        if items.isEmpty {
                            ContentUnavailableView(learned ? "まだありません" : "保存した曲はありません", systemImage: "bookmark",
                                                   description: Text("正解発表の画面から曲を保存できます。"))
                                .foregroundStyle(Studio.secondary)
                        }
                    }
                }
                ForEach(flights) { flight in
                    ReviewFlyingArtwork(flight: flight) { finishFlight(flight) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: "review")
            .onPreferenceChange(ReviewFramePreference.self) { frames = $0 }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: learned) { _, _ in stopPlayback() }
            .onChange(of: reduceMotion) { _, enabled in
                if enabled { flights.removeAll() }
            }
            .onDisappear { stopPlayback(); flights.removeAll() }
            .alert("曲を再生できません", isPresented: Binding(
                get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
                    Button("OK", role: .cancel) { playbackError = nil }
                } message: { Text(playbackError ?? "") }
        }
    }

    private var reviewSegments: some View {
        // The native segmented picker owns Liquid Glass and slide-to-select interaction.
        Picker("復習の表示", selection: $learned) {
            reviewSegmentTitle(false).tag(false)
            reviewSegmentTitle(true).tag(true)
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .labelsHidden()
        .accessibilityIdentifier("review-filter")
        .background {
            // Native picker labels do not host SwiftUI geometry readers. Keep
            // invisible destination frames behind its two equal-width segments.
            HStack(spacing: 0) {
                Color.clear.background(ReviewFrameReader(key: .segment(false)))
                Color.clear.background(ReviewFrameReader(key: .segment(true)))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .modifier(ReviewTabPop(trigger: learnedPop + unlearnedPop))
    }

    private func reviewSegmentTitle(_ value: Bool) -> some View {
        let title = value ? "覚えた" : "覚えてない"
        let count = model.reviews.filter { $0.learned == value }.count
        return Text("\(title) \(count)")
            .accessibilityLabel("\(title)、\(count)曲")
    }

    private func moveReview(_ item: ReviewSong) {
        guard model.reviews.contains(where: { $0.id == item.id && $0.learned == item.learned }) else { return }
        if activeSongID == item.id { stopPlayback() }
        // Persist immediately. The decoration is independent of data, including when the tab is closed mid-flight.
        if !reduceMotion, let start = frames[.artwork(item.id)], let target = frames[.segment(!item.learned)] {
            flights.append(ReviewFlight(song: item.song, learned: !item.learned, start: start,
                                       destination: CGPoint(x: target.midX, y: target.midY)))
        } else {
            popSegment(!item.learned)
        }
        withAnimation(reduceMotion ? nil : Studio.spring) { model.toggleLearned(item.id) }
    }

    private func removeReview(_ item: ReviewSong) {
        if activeSongID == item.id { stopPlayback() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { model.removeReview(item.id) }
    }

    private func finishFlight(_ flight: ReviewFlight) {
        flights.removeAll { $0.id == flight.id }
        popSegment(flight.learned)
    }

    private func popSegment(_ value: Bool) {
        if value { learnedPop += 1 } else { unlearnedPop += 1 }
    }

    @MainActor private func togglePlayback(_ song: Song) {
        if activeSongID == song.id { stopPlayback(); return }
        stopPlayback()
        activeSongID = song.id
        reviewPlayer.volume = Float(model.songVolume)
        if let url = DemoCatalog.previewURL(for: song) {
            reviewPlayer.play(url)
            monitorPlayback(song.id, appleMusic: false)
            return
        }
        guard song.id.hasPrefix("applemusic:") else {
            activeSongID = nil
            playbackError = "この曲の音源は利用できません"
            return
        }
        loadingSongID = song.id
        playbackTask = Task {
            do {
                let canPlay = (try? await model.appleMusic.authorize()) ?? false
                try Task.checkCancellation()
                if canPlay {
                    monitorPlayback(song.id, appleMusic: true)
                    do { try await model.appleMusic.play(song) }
                    catch {
                        try Task.checkCancellation()
                        guard let preview = await model.appleMusic.previewURL(for: song.id) else { throw error }
                        try Task.checkCancellation()
                        model.setReviewAudioPlaying(false)
                        reviewPlayer.play(preview)
                        monitorPlayback(song.id, appleMusic: false)
                    }
                } else if let preview = await model.appleMusic.previewURL(for: song.id) {
                    try Task.checkCancellation()
                    reviewPlayer.play(preview)
                    monitorPlayback(song.id, appleMusic: false)
                } else {
                    throw AppError.message("Apple Music のサブスクリプション、またはこの曲の試聴音源が必要です")
                }
                if !Task.isCancelled, activeSongID == song.id { loadingSongID = nil }
            } catch {
                guard !Task.isCancelled, activeSongID == song.id else { return }
                loadingSongID = nil
                activeSongID = nil
                playbackMonitor?.cancel()
                playbackMonitor = nil
                model.setReviewAudioPlaying(false)
                playbackError = error.localizedDescription
            }
        }
    }

    @MainActor private func monitorPlayback(_ songID: String, appleMusic: Bool) {
        playbackMonitor?.cancel()
        usesAppleMusic = appleMusic
        playbackMonitor = Task {
            var started = false
            while !Task.isCancelled && activeSongID == songID {
                let audible = appleMusic ? model.appleMusic.isPlaying : reviewPlayer.isActuallyPlaying
                model.setReviewAudioPlaying(audible || (started && (isScrubbing || isSeeking)))
                playbackDuration = appleMusic ? model.appleMusic.duration : reviewPlayer.duration
                if !isScrubbing && !isSeeking {
                    let currentTime = appleMusic ? model.appleMusic.currentTime : reviewPlayer.currentTime
                    playbackPosition = min(currentTime, playbackDuration)
                }
                let ended = appleMusic ? started && model.appleMusic.hasEnded && loadingSongID == nil : reviewPlayer.hasEnded
                if !isScrubbing && !isSeeking && ended {
                    stopPlayback()
                    return
                }
                started = started || audible
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    @MainActor private func seekPlayback(to time: TimeInterval) {
        guard let songID = activeSongID, loadingSongID == nil, time.isFinite, playbackDuration > 0 else { return }
        seekTask?.cancel()
        let target = min(max(0, time), playbackDuration)
        playbackPosition = target
        isSeeking = true
        seekTask = Task {
            guard !Task.isCancelled, activeSongID == songID else { return }
            do {
                if usesAppleMusic { try await model.appleMusic.seek(to: target) }
                else { await reviewPlayer.seek(to: target) }
            } catch {
                guard !Task.isCancelled, activeSongID == songID else { return }
                stopPlayback()
                playbackError = error.localizedDescription
                return
            }
            guard !Task.isCancelled, activeSongID == songID else { return }
            isSeeking = false
            seekTask = nil
        }
    }

    @MainActor private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackMonitor?.cancel()
        playbackMonitor = nil
        seekTask?.cancel()
        seekTask = nil
        reviewPlayer.stop()
        model.appleMusic.stop()
        model.setReviewAudioPlaying(false)
        activeSongID = nil
        loadingSongID = nil
        usesAppleMusic = false
        playbackPosition = 0
        playbackDuration = 0
        isScrubbing = false
        isSeeking = false
    }
}

private enum ReviewFrame: Hashable {
    case artwork(String)
    case segment(Bool)
}

private struct ReviewFramePreference: PreferenceKey {
    static var defaultValue: [ReviewFrame: CGRect] { [:] }
    static func reduce(value: inout [ReviewFrame: CGRect], nextValue: () -> [ReviewFrame: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ReviewFrameReader: View {
    let key: ReviewFrame
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ReviewFramePreference.self,
                                   value: [key: geometry.frame(in: .named("review"))])
        }
    }
}

private struct ReviewEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 18)
            .task {
                guard !appeared else { return }
                if !reduceMotion {
                    do { try await Task.sleep(for: .milliseconds(min(index, 7) * 45)) }
                    catch { return }
                }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) { appeared = true }
            }
    }
}

private struct ReviewTabPop: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(popped && !reduceMotion ? 1.07 : 1)
            .sensoryFeedback(.success, trigger: trigger)
            .task(id: trigger) {
                guard trigger > 0, !reduceMotion else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { popped = true }
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { popped = false }
            }
    }
}

private struct ReviewFlight: Identifiable {
    let id = UUID()
    let song: Song
    let learned: Bool
    let start: CGRect
    let destination: CGPoint
}

private struct ReviewFlyingArtwork: View {
    let flight: ReviewFlight
    let onArrival: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        Artwork(url: flight.song.artworkURL, size: flight.start.width)
            .modifier(ReviewFlightMotion(start: CGPoint(x: flight.start.midX, y: flight.start.midY),
                                        end: flight.destination, progress: progress))
            .task {
                withAnimation(.easeInOut(duration: 0.52)) { progress = 1 }
                do { try await Task.sleep(for: .milliseconds(520)) }
                catch { return }
                onArrival()
            }
    }
}

private struct ReviewFlightMotion: AnimatableModifier {
    let start: CGPoint
    let end: CGPoint
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - progress * 0.82)
            .opacity(1 - progress * progress * 0.7)
            .position(x: start.x + (end.x - start.x) * progress,
                      y: start.y + (end.y - start.y) * progress - sin(progress * .pi) * 48)
    }
}

private struct ReviewSongRow: View {
    let item: ReviewSong
    let isPlaying: Bool
    let isLoading: Bool
    @Binding var playbackPosition: TimeInterval
    let playbackDuration: TimeInterval
    @Binding var isScrubbing: Bool
    let seek: (TimeInterval) -> Void
    let togglePlayback: () -> Void
    let toggleLearned: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var playbackActive: Bool { isPlaying || isLoading }

    var body: some View {
        VStack(spacing: 8) {
            songControls
            if playbackActive {
                ReviewSeekBar(songTitle: item.song.title, position: $playbackPosition,
                              duration: playbackDuration, isScrubbing: $isScrubbing,
                              isLoading: isLoading, seek: seek)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.md).strokeBorder(Studio.line))
        .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.md))
        .buttonStyle(StudioButtonStyle(.tertiary))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: playbackActive)
    }

    private var songControls: some View {
        HStack(spacing: 10) {
            Artwork(url: item.song.artworkURL, size: 48)
                .background(ReviewFrameReader(key: .artwork(item.id)))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                    .lineLimit(2)
                Text(item.song.artist)
                    .font(.caption).foregroundStyle(Studio.secondary).lineLimit(1)
                if DemoCatalog.previewURL(for: item.song) != nil || item.song.id.hasPrefix("applemusic:") {
                    Button(action: togglePlayback) {
                        HStack(spacing: 4) {
                            if isLoading { ProgressView().controlSize(.mini) }
                            else { Image(systemName: isPlaying ? "stop.fill" : "play.fill") }
                            Text(isLoading ? "読み込み中" : isPlaying ? "停止" : "アプリ内で再生")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Studio.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(item.song.title)を\(isPlaying || isLoading ? "停止" : "再生")")
                } else {
                    Text("再生できる音源がありません")
                        .font(.caption2).foregroundStyle(Studio.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggleLearned) {
                Image(systemName: item.learned ? "arrow.uturn.backward" : "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(item.learned ? Studio.accent : Studio.onAccent)
                    .frame(width: 44, height: 44)
                    .background(item.learned ? Studio.raised : Studio.accent, in: Circle())
            }
            .accessibilityLabel(item.learned ? "\(item.song.title)を覚えてないに戻す" : "\(item.song.title)を覚えたに変更")

        }
    }
}

private struct ReviewSeekBar: View {
    let songTitle: String
    @Binding var position: TimeInterval
    let duration: TimeInterval
    @Binding var isScrubbing: Bool
    let isLoading: Bool
    let seek: (TimeInterval) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(
                get: { min(max(0, position), duration > 0 ? duration : 1) },
                set: {
                    position = $0
                    // Accessibility adjustments do not begin a drag gesture.
                    if !isScrubbing { seek($0) }
                }), in: 0...(duration > 0 ? duration : 1), onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { seek(position) }
                })
                .tint(Studio.accent)
                .frame(minHeight: 44)
                .disabled(isLoading || duration <= 0)
                .accessibilityLabel("\(songTitle)の再生位置")
                .accessibilityValue("\(timeLabel(position)) / \(timeLabel(duration))")
            HStack {
                Text(timeLabel(position))
                Spacer()
                Text(duration > 0 ? timeLabel(duration) : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Studio.secondary)
            .accessibilityHidden(true)
        }
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let seconds = Int(max(0, time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

