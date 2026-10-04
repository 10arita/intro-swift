import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

private enum MainTab { case play, review, friends, account }

private struct SystemMusicVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        MPVolumeView()
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

private struct VolumeSettingsControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            volumeSlider("BGM", value: $model.bgmVolume)
            volumeSlider("効果音", value: $model.effectsVolume)
            volumeSlider("曲（アプリ音源）", value: $model.songVolume)
            if model.appleMusicConnected {
                Divider()
                Text("Apple Music の曲（端末音量）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                SystemMusicVolumeSlider()
                    .frame(height: 30)
                    .accessibilityLabel("端末の音楽音量")
            }
        }
    }

    private func volumeSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Studio.primary)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(Studio.secondary)
            }
            Slider(value: value, in: 0...1)
                .tint(Studio.accent)
                .accessibilityLabel("\(title)の音量")
        }
    }
}

private struct GameVolumeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Studio.primary)
                .frame(width: 44, height: 44)
                .background(Studio.surface, in: Circle())
        }
        .accessibilityLabel("音量を調整")
    }
}

private struct GameVolumeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                StudioCard { VolumeSettingsControls() }
                    .padding(20)
            }
            .background(Studio.background)
            .navigationTitle("音量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shortcut = PracticeShortcutRoute.shared
    @State private var openingPractice = false
    @State private var selectedTab: MainTab = .play
    @State private var playHomeToken = 0
    @State private var startsTogether = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Group {
                    switch selectedTab {
                    case .play: PlayView(homeToken: playHomeToken, startsTogether: startsTogether)
                    case .review: ReviewView()
                    case .friends: FriendsView(onCreateRoom: {
                        startsTogether = true
                        playHomeToken += 1
                        selectedTab = .play
                    })
                    case .account: AccountView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Reserve the menu's actual height, including larger accessibility text.
                if !showingSession { tabBar }
            }
            .offset(x: showingSession && !reduceMotion ? -80 : 0)
            .opacity(showingSession ? 0 : 1)
            .allowsHitTesting(!showingSession)
            .accessibilityHidden(showingSession)
            if model.room != nil {
                RoomGameView()
                    .transition(reduceMotion ? .opacity : .offset(x: 80).combined(with: .opacity))
                    .zIndex(1)
            } else if model.game != nil {
                SoloGameView()
                    .transition(reduceMotion ? .opacity : .offset(x: 80).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .background(Studio.background)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.3), value: showingSession)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedTab)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .alert("IntoL", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task {
            model.setAppActive(scenePhase == .active)
            Task { await model.restoreRoom() }
            if model.searchSongs.isEmpty { await model.search() }
            await openRequestedPractice()
            if model.appleMusicConnected { await model.loadAppleMusicPlaylists() }
            await model.syncProfile()
            await model.refreshFriends(reportErrors: false)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, model.serverConfigured else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { break }
                await model.refreshFriends(reportErrors: false)
            }
        }
        .onChange(of: shortcut.practiceRequest) { _, _ in
            Task { await openRequestedPractice() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setAppActive(phase == .active)
            if phase == .active {
                Task {
                    await model.syncProfile()
                    await model.refreshFriends(reportErrors: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            model.cloudAccountChanged()
        }
    }

    private var showingSession: Bool { model.room != nil || model.game != nil }

    private var tabBar: some View {
        Group {
            if #available(iOS 26, *) {
                tabButtons(spacing: 0)
                    .padding(4)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } else {
                tabButtons(spacing: 0)
                    .padding(.top, 9)
                    .padding(.bottom, 4)
                    .background(Studio.surface.ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .top) { Studio.line.frame(height: 1) }
            }
        }
    }

    private func tabButtons(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            tabButton("プレイ", symbol: "waveform", tab: .play)
            tabButton("復習", symbol: "bookmark", tab: .review)
            tabButton("フレンド", symbol: "person.2", tab: .friends)
            tabButton("アカウント", symbol: "person.crop.circle", tab: .account)
        }
    }

    private func tabButton(_ title: String, symbol: String, tab: MainTab) -> some View {
        let inviteCount = (model.friendsState?.invites.count ?? 0) + (model.friendsState?.requests.count ?? 0)
        return Button {
            if tab == .play { startsTogether = false; playHomeToken += 1 }
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                    .frame(width: 60, height: 30)
                    .overlay(alignment: .topTrailing) {
                        if tab == .friends && inviteCount > 0 {
                            Text("\(inviteCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(minWidth: 16, minHeight: 16)
                                .padding(.horizontal, 3)
                                .background(Studio.accent, in: Capsule())
                                .offset(x: -2, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
                    .background {
                        if #unavailable(iOS 26), selectedTab == tab {
                            Capsule().fill(Studio.raised)
                        }
                    }
                Text(title).font(.caption2)
            }
            .foregroundStyle(selectedTab == tab ? Studio.accent : Studio.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                if #available(iOS 26, *), selectedTab == tab {
                    Capsule().fill(Studio.accent.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(tab == .friends && inviteCount > 0
            ? "\(selectedTab == tab ? "選択中、" : "")招待・申請\(inviteCount)件"
            : (selectedTab == tab ? "選択中" : ""))
    }

    @MainActor
    private func openRequestedPractice() async {
        guard !openingPractice, shortcut.practiceRequest != nil else { return }
        openingPractice = true
        defer { openingPractice = false }
        shortcut.practiceRequest = nil
        guard model.canStartSolo else {
            model.alert = "先に現在のゲームまたはルームを終了してください"
            return
        }
        model.searchTerm = ""
        await model.search()
        if !model.searchSongs.isEmpty { await model.startSolo() }
    }
}

private struct RuleDialRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var prefix = ""
    var suffix = ""
    var disabled = false
    @State private var showingDial = false

    var body: some View {
        Button { showingDial = true } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(Studio.primary)
                Spacer(minLength: 8)
                Text(displayValue(value))
                    .monospacedDigit()
                    .foregroundStyle(Studio.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(Studio.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(displayValue(value))
        .accessibilityHint("ダイヤルで変更")
        .sheet(isPresented: $showingDial) {
            NavigationStack {
                Picker(title, selection: $value) {
                    ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { option in
                        Text(displayValue(option)).tag(option)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 190)
                .frame(maxHeight: .infinity)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { showingDial = false }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func displayValue(_ number: Int) -> String { "\(prefix)\(number)\(suffix)" }
}

private struct LandingButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: disabled ? "lock.fill" : symbol)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Studio.line))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(disabled)
        .accessibilityHint(disabled ? "サーバー設定が必要です" : "")
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Studio.accent)
            .padding(.horizontal, 15)
            .frame(minHeight: 46)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Studio.line))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

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
    var body: some View {
        Canvas { context, size in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: 2 + x * max(0, size.width - 4), y: y * size.height)
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
        .accessibilityHidden(true)
    }
}

private struct WaveMark: View {
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<25, id: \.self) { i in
                Capsule()
                    .fill(i.isMultiple(of: 3) ? Studio.accent : Studio.accent.opacity(0.4))
                    .frame(width: 3, height: CGFloat([10,18,28,14,36,23,12,30,17,40,22,12,33,18,42,25,14,35,20,11,30,19,25,13,8][i]))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CountdownBar: View {
    let remaining: Double
    let total: Double
    var compact = false
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
    }
}

private struct PreparationProgressView: View {
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
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Studio.line))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Studio.background)
    }
}

private struct PushButton: View {
    let action: () -> Void
    var size: CGFloat = 256
    var pending = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                if pending {
                    ProgressView().tint(.white)
                    Text("判定中").font(.system(size: size * 0.115, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: "hand.tap.fill").font(.system(size: size * 0.105))
                    Text("PUSH").font(.system(size: size * 0.152, weight: .black, design: .rounded)).tracking(-2)
                }
            }
            .foregroundStyle(.white)
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
    }
}

private struct SkipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.5)
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? .none : Studio.spring, value: configuration.isPressed)
    }
}

private struct ChoiceGrid: View {
    let choices: [String]
    let action: (String) -> Void
    var compact = false
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button { action(choice) } label: {
                    HStack {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Studio.secondary)
                        Spacer()
                        Text(choice)
                            .font(.system(size: compact ? 30 : 38, weight: .bold, design: .rounded))
                            .foregroundStyle(Studio.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .frame(height: compact ? 68 : 94)
                    .background(Studio.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Studio.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("選択肢\(index + 1)、\(choice)")
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

private struct RevealCard: View {
    let song: Song
    let correct: Bool
    let saved: Bool
    let save: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: correct ? "checkmark.circle.fill" : "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(correct ? Studio.accent : Studio.warning)
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
            .buttonStyle(SecondaryButtonStyle())
            .disabled(saved)
            if let url = song.trackURL {
                Link(destination: url) {
                    Label("曲のリンクを開く", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.accent)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SoloGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showVolumeSettings = false

    var body: some View {
        ZStack {
            Studio.background.ignoresSafeArea()
            if let game = model.game {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack {
                            Button { model.closeGame() } label: {
                                Image(systemName: "xmark").font(.headline).foregroundStyle(Studio.primary)
                                    .frame(width: 44, height: 44).background(Studio.surface, in: Circle())
                            }
                            .accessibilityLabel("ゲームを閉じる")
                            HStack(spacing: 5) {
                                PlayerAvatarView(data: model.avatarData, size: 18)
                                Text(model.nickname)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(Studio.primary)
                            }
                            .padding(.leading, 6)
                            Spacer()
                            Text(game.stage == .finished ? "RESULT" : "ROUND \(game.index + 1) / \(game.songs.count)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(Studio.secondary)
                            GameVolumeButton { showVolumeSettings = true }
                        }
                        if game.stage == .preparing {
                            Spacer(minLength: 24)
                            SectionCaption(title: "ROUND \(game.index + 1) / \(game.songs.count)")
                            ProgressView().tint(Studio.accent).scaleEffect(1.5)
                            Text("音源を読み込み中")
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            if game.warning != nil {
                                Button("再試行") { model.retrySoloRound() }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        } else if game.stage == .countdown {
                            Spacer(minLength: 24)
                            SectionCaption(title: "ROUND \(game.index + 1) / \(game.songs.count)")
                            WaveMark()
                            Text("第\(game.index + 1)問目")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("\(max(1, Int(ceil(game.secondsLeft))))")
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.accent)
                        } else if game.stage == .listening {
                            Spacer(minLength: 4)
                            WaveMark()
                            Text("耳を澄ませて")
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("曲名が分かったら PUSH")
                                .foregroundStyle(Studio.secondary)
                            CountdownBar(remaining: game.secondsLeft, total: 30, compact: true)
                            PushButton(action: { model.push() }, size: 220)
                            Button("この曲をスキップ") { model.skip() }
                                .buttonStyle(SkipButtonStyle())
                                .padding(.top, 16)
                        } else if game.stage == .answering {
                            Spacer(minLength: 4)
                            SectionCaption(title: "SPELL THE TITLE")
                            Text(game.answered.isEmpty ? "文字を選んでください" : game.answered)
                                .font(.system(size: 35, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                                .minimumScaleFactor(0.5)
                                .lineLimit(2)
                                .accessibilityLabel(game.answered.isEmpty ? "未入力" : "入力済み: \(game.answered)")
                            Text("次の文字を選ぶ")
                                .foregroundStyle(Studio.secondary)
                            CountdownBar(remaining: game.secondsLeft, total: 5, compact: true)
                            ChoiceGrid(choices: game.choices, action: { model.choose($0) }, compact: true)
                        } else if game.stage == .reveal {
                            RevealCard(song: game.current, correct: game.wasCorrect,
                                       saved: model.reviews.contains { $0.id == game.current.id }) {
                                model.saveReview(game.current)
                            }
                            PrimaryButton(title: game.index + 1 == game.songs.count ? "結果を見る" : "次の曲へ", symbol: "arrow.right") {
                                model.nextRound()
                            }
                        } else if let result = model.lastResult {
                            ResultSummary(result: result)
                            PrimaryButton(title: "ホームへ戻る", symbol: "house") { model.closeGame() }
                        }
                        if let warning = game.warning {
                            Text(warning).font(.caption).foregroundStyle(Studio.warning)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion || game.stage == .answering ? nil : Studio.spring, value: game.stage)
                }
            }
        }
        .sheet(isPresented: $showVolumeSettings) {
            GameVolumeSettingsSheet()
                .environmentObject(model)
        }
    }
}

private struct ResultSummary: View {
    let result: SoloResult
    var body: some View {
        VStack(spacing: 24) {
            SectionCaption(title: "SESSION COMPLETE")
            Text(result.rank)
                .font(.system(size: 112, weight: .black, design: .rounded))
                .foregroundStyle(Studio.accent)
                .minimumScaleFactor(0.6)
            Text(String(format: "%.1f", result.score) + " / 100")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .foregroundStyle(Studio.primary)
            StudioCard {
                HStack {
                    stat("正解", "\(result.correct) / \(result.total)")
                    Spacer()
                    stat("平均 PUSH", String(format: "%.3f秒", result.averagePush))
                }
            }
            Text(result.playlist).font(.subheadline).foregroundStyle(Studio.secondary)
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption).foregroundStyle(Studio.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(Studio.primary)
        }
    }
}

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
                        HStack(spacing: 4) {
                            reviewSegment(false)
                            reviewSegment(true)
                        }
                        .padding(4)
                        .background(Studio.raised, in: RoundedRectangle(cornerRadius: 16))
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

    private func reviewSegment(_ value: Bool) -> some View {
        let count = model.reviews.filter { $0.learned == value }.count
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { learned = value }
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 4) {
                        Text(value ? "覚えた" : "覚えてない")
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                        countBadge(count)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(value ? "覚えた" : "覚えてない")
                        countBadge(count)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(learned == value ? Studio.accent : Studio.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
            .background(learned == value ? Studio.surface : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(StudioPressStyle())
        .background(ReviewFrameReader(key: .segment(value)))
        .modifier(ReviewTabPop(trigger: value ? learnedPop : unlearnedPop))
        .accessibilityLabel("\(value ? "覚えた" : "覚えてない")、\(count)曲")
        .accessibilityAddTraits(learned == value ? [.isSelected] : [])
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.weight(.bold).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Studio.accent.opacity(0.09), in: Capsule())
            .contentTransition(.numericText())
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
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.radius))
        .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.line))
        .clipShape(RoundedRectangle(cornerRadius: Studio.radius))
        .buttonStyle(StudioPressStyle())
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
                    .foregroundStyle(item.learned ? Studio.accent : .white)
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

private struct PlayerProfileTarget: Identifiable {
    let id: String
    let name: String
    let roomID: String?
}

private struct PlayerProfileSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: PlayerProfileTarget
    @State private var profile: PlayerProfile?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let profile {
                        StudioCard {
                            HStack(spacing: 14) {
                                PlayerAvatarView(data: nil, size: 72, encoded: profile.avatar)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name)
                                        .font(.title2.bold())
                                        .foregroundStyle(Studio.primary)
                                    if let badge = profile.badge, !badge.isEmpty {
                                        Label(badge, systemImage: "medal.fill")
                                            .font(.subheadline)
                                            .foregroundStyle(Studio.accent)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let score = profile.roomScore {
                            StudioCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    SectionCaption(title: "このルーム")
                                    HStack {
                                        profileMetric("スコア", "\(score) pt")
                                        profileMetric("正解", "\(profile.roomCorrect ?? 0) 曲")
                                        profileMetric("誤答", "\(profile.roomWrong ?? 0) 曲")
                                    }
                                }
                            }
                        }
                        if let stats = profile.stats {
                            StudioCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    SectionCaption(title: "通算記録")
                                    HStack {
                                        profileMetric("完走", "\(stats.games ?? 0) 回")
                                        profileMetric("正解", "\(stats.correct ?? 0) 曲")
                                        let attempts = stats.attempts ?? 0
                                        let accuracy = attempts == 0 ? 0 : 100 * (stats.correct ?? 0) / attempts
                                        profileMetric("正答率", "\(accuracy)%")
                                    }
                                    profileMetric("平均 PUSH", stats.averagePush.map {
                                        String(format: "%.3f秒", $0)
                                    } ?? "—")
                                    if let badges = stats.badges, !badges.isEmpty {
                                        Text("獲得称号: \(badges.sorted().joined(separator: " ・ "))")
                                            .font(.caption)
                                            .foregroundStyle(Studio.secondary)
                                    }
                                }
                            }
                        } else {
                            Text("通算記録はまだありません")
                                .font(.subheadline)
                                .foregroundStyle(Studio.secondary)
                        }
                    } else if let error {
                        StudioCard {
                            Text(error).foregroundStyle(Studio.warning)
                        }
                    } else {
                        ProgressView("プロフィールを読み込み中")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Studio.background)
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
            }
            .task {
                do {
                    if let roomID = target.roomID {
                        profile = try await model.rooms.playerProfile(roomID: roomID, targetPlayerID: target.id)
                    } else {
                        profile = try await model.rooms.playerProfile(friendID: target.id)
                    }
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func profileMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Studio.secondary)
            Text(value).font(.subheadline.bold()).foregroundStyle(Studio.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FriendsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var inRoom = false
    var onClose: (() -> Void)? = nil
    var onCreateRoom: (() -> Void)? = nil
    @State private var selectedProfile: PlayerProfileTarget?

    private var notificationCount: Int {
        (model.friendsState?.invites.count ?? 0) + (model.friendsState?.requests.count ?? 0)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("フレンド")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Button { Task { await model.refreshFriends() } } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("フレンド情報を更新")
                            .disabled(!model.serverConfigured || model.friendsLoading)
                            if inRoom {
                                Button("閉じる") { onClose?() }
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                        }
                        if let state = model.friendsState {
                            if !state.invites.isEmpty {
                                FriendNotificationBanner(title: "📩 ルーム招待が\(state.invites.count)件届いています") {
                                    ForEach(state.invites) { invite in
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(invite.fromName).font(.subheadline.bold())
                                                Text("\(invite.mode == "shared" ? "共有音源" : invite.mode == "applemusic" ? "Apple Music" : "サビトロ") のルーム")
                                                    .font(.caption).foregroundStyle(Studio.secondary)
                                            }
                                            Spacer()
                                            Button("参加") { Task { await model.joinInvite(invite.id) } }
                                                .buttonStyle(SecondaryButtonStyle())
                                                .disabled(model.busy || model.room != nil)
                                        }
                                        if invite.id != state.invites.last?.id { Divider() }
                                    }
                                    if model.room != nil {
                                        Text("別のルームに参加するには、現在のルームを退出してください")
                                            .font(.caption).foregroundStyle(Studio.secondary)
                                    }
                                }
                            }
                            if !state.requests.isEmpty {
                                FriendNotificationBanner(title: "📩 フレンド申請が\(state.requests.count)件届いています") {
                                    ForEach(state.requests) { request in
                                        HStack(spacing: 8) {
                                            Text(request.fromName).font(.subheadline.bold())
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Button("承認") { Task { await model.respondToFriendRequest(request.id, accept: true) } }
                                                .buttonStyle(SecondaryButtonStyle())
                                            Button("拒否") { Task { await model.respondToFriendRequest(request.id, accept: false) } }
                                                .foregroundStyle(Studio.secondary)
                                                .frame(minWidth: 44, minHeight: 44)
                                        }
                                        .disabled(model.friendsLoading)
                                        if request.id != state.requests.last?.id { Divider() }
                                    }
                                }
                            }
                            if !state.friends.isEmpty {
                                friendList(state)
                            } else {
                                emptyState
                                    .frame(minHeight: max(280, geometry.size.height - (notificationCount > 0 ? 260 : 130)))
                            }
                        } else if model.friendsLoading {
                            ProgressView("フレンドを読み込み中")
                                .frame(maxWidth: .infinity, minHeight: 260)
                        } else {
                            emptyState.frame(minHeight: max(280, geometry.size.height - 130))
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion ? nil : Studio.spring, value: notificationCount)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await model.refreshFriends() }
            }
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.refreshFriends() }
            .sheet(item: $selectedProfile) { target in
                PlayerProfileSheet(target: target).environmentObject(model)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Studio.accent)
                .frame(width: 104, height: 104)
                .background(Studio.raised, in: Circle())
                .accessibilityHidden(true)
            Text("対戦後にフレンド申請を送れます")
                .font(.headline)
                .foregroundStyle(Studio.primary)
                .multilineTextAlignment(.center)
            if model.room == nil, let onCreateRoom {
                PrimaryButton(title: "ルームを作成する", symbol: "plus", disabled: !model.serverConfigured, action: onCreateRoom)
                    .frame(maxWidth: 320)
            }
            if !model.serverConfigured {
                Text("フレンド機能には対戦サーバーへの接続が必要です")
                    .font(.caption)
                    .foregroundStyle(Studio.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func friendList(_ state: FriendsState) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("フレンド \(state.friends.count)人")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Studio.secondary)
                .padding(.bottom, 12)
            ForEach(state.friends) { friend in
                HStack(spacing: 12) {
                    Button {
                        selectedProfile = PlayerProfileTarget(id: friend.id, name: friend.name, roomID: nil)
                    } label: {
                        HStack(spacing: 12) {
                            PlayerAvatarView(data: nil, size: 40, encoded: friend.avatar)
                            Text(friend.name).font(.headline).foregroundStyle(Studio.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 72)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressStyle())
                    .accessibilityLabel("\(friend.name)のプロフィールを見る")
                    if model.room?.phase == "lobby" {
                        if model.room?.players.contains(where: { $0.friendProfileId == friend.id }) == true {
                            Text("参加中").font(.caption).foregroundStyle(Studio.secondary)
                        } else {
                            let invited = model.hasInvitedFriend(friend.id)
                            Button(invited ? "招待済み" : "招待") { Task { await model.inviteFriend(friend.id) } }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(model.friendsLoading || invited)
                        }
                    } else {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Studio.secondary)
                            .accessibilityHidden(true)
                    }
                }
                if friend.id != state.friends.last?.id { Divider().overlay(Studio.line) }
            }
            if model.room == nil {
                Text("ルームを作成するとフレンドを招待できます")
                    .font(.caption).foregroundStyle(Studio.secondary).padding(.top, 16)
            }
        }
    }
}

private struct FriendNotificationBanner<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) { content }.padding(.top, 12)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Studio.primary)
                .frame(minHeight: 44)
        }
        .tint(Studio.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Studio.raised, in: RoundedRectangle(cornerRadius: 16))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        .task { withAnimation(reduceMotion ? nil : Studio.spring) { appeared = true } }
    }
}

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRecords = false
    @State private var showConnectionBenefits = false
    @State private var showAvatarSettings = false
    @State private var editingName = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("アカウント")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Studio.primary)
                    profileHeader
                    Picker("表示内容", selection: $showRecords) {
                        Text("接続・設定").tag(false)
                        Text("プレイ記録").tag(true)
                    }.pickerStyle(.segmented)
                    if showRecords {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionCaption(title: "プレイ記録")
                            HStack(spacing: 20) {
                                metric("完走", "\(model.totalGames) 回")
                                metric("正答率", String(format: "%.0f%%", model.accuracy * 100))
                                metric("正解", "\(model.totalCorrect) 曲")
                            }
                            if !model.stats.badges.isEmpty {
                                Menu {
                                    ForEach(model.stats.badges.sorted(), id: \.self) { badge in
                                        Button(badge) {
                                            model.setBadge(badge)
                                        }
                                    }
                                } label: {
                                    Label(model.stats.selectedBadge ?? "称号を選ぶ", systemImage: "medal.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Studio.accent)
                                }
                            }
                            if model.stats.attempts > 0 {
                                Text(String(format: "平均 PUSH %.3f秒 ・ 解答 %d回", model.stats.averagePush, model.stats.attempts))
                                    .font(.caption)
                                    .foregroundStyle(Studio.secondary)
                            }
                            DisclosureGroup("ジャンル別の成績") {
                            ForEach(model.stats.genres.keys.sorted(), id: \.self) { genre in
                                if let record = model.stats.genres[genre], record.attempts > 0 {
                                    HStack {
                                        Text(genre)
                                        Spacer()
                                        Text("\(record.correct) / \(record.attempts)")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Studio.secondary)
                                }
                            }
                        }
                    }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 15) {
                            SectionCaption(title: "最近のプレイ")
                            if model.history.isEmpty {
                                Text("まだプレイ履歴がありません")
                                    .foregroundStyle(Studio.secondary)
                            } else {
                                ForEach(model.history) { result in
                                    HStack(spacing: 12) {
                                        Text(result.rank)
                                            .font(.system(size: 21, weight: .black, design: .rounded))
                                            .foregroundStyle(Studio.accent)
                                            .frame(width: 44, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(result.playlist).lineLimit(1).foregroundStyle(Studio.primary)
                                            Text(result.date, style: .date).font(.caption).foregroundStyle(Studio.secondary)
                                        }
                                        Spacer()
                                        Text(String(format: "%.1f", result.score))
                                            .font(.headline.monospacedDigit())
                                            .foregroundStyle(Studio.primary)
                                    }
                                    if result.id != model.history.last?.id { Divider().overlay(Studio.line) }
                                }
                            }
                        }
                    }
                    } else {
                    connectionsSection
                    StudioCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionCaption(title: "音量")
                            VolumeSettingsControls()
                        }
                    }
                    }
                }
                .padding(20)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showRecords)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Studio.background)
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: nameFocused) { _, focused in
                if !focused && editingName { finishEditingName() }
            }
            .onDisappear { if editingName { finishEditingName() } }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { finishEditingName() }
                }
            }
        }
        .sheet(isPresented: $showAvatarSettings) {
            AvatarSettingsView()
                .environmentObject(model)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 16) {
            Button { showAvatarSettings = true } label: {
                PlayerAvatarView(data: model.avatarData, size: 64)
                    .overlay(Circle().strokeBorder(Studio.line))
            }
            .buttonStyle(StudioPressStyle())
            .accessibilityLabel("アイコンを設定")

            Group {
                if editingName {
                    HStack(spacing: 8) {
                        TextField("プレイヤー名", text: $draftName)
                            .font(.title3.bold())
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { finishEditingName() }
                            .accessibilityLabel("プレイヤー名")
                            .onAppear { nameFocused = true }
                        Button(action: finishEditingName) {
                            Image(systemName: "checkmark").frame(width: 44, height: 44)
                        }
                        .foregroundStyle(Studio.accent)
                        .accessibilityLabel("プレイヤー名を保存")
                    }
                } else {
                    Button {
                        draftName = model.nickname
                        editingName = true
                    } label: {
                        HStack(spacing: 12) {
                            Text(model.nickname).font(.title3.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "pencil")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Studio.accent)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressStyle())
                    .accessibilityLabel("\(model.nickname)、プレイヤー名を編集")
                }
            }
            .foregroundStyle(Studio.primary)
            .padding(.horizontal, 12)
            .background(editingName ? Studio.surface : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Studio.accent.opacity(0.6), lineWidth: 2)
                    .padding(nameFocused ? -5 : 0)
                    .opacity(nameFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : Studio.spring, value: nameFocused)
        }
        .padding(.vertical, 12)
    }

    private func finishEditingName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != model.nickname { model.nickname = name }
        editingName = false
        nameFocused = false
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(title: "外部連携").padding(.horizontal, 16)
            VStack(spacing: 0) {
                Button {
                    Task {
                        if model.appleMusicConnected { await model.loadAppleMusicPlaylists() }
                        else { await model.connectAppleMusic() }
                    }
                } label: {
                    connectionRow("Apple Music", badge: model.appleMusicConnected ? "接続済み" : "未接続",
                                  active: model.appleMusicConnected) { AppleMusicIcon(size: 30) }
                }
                .disabled(model.busy)
                .accessibilityHint(model.appleMusicConnected ? "接続状態を更新" : "タップして接続")
                Divider().overlay(Studio.line).padding(.leading, 60)
                Button { Task { await model.syncProfile() } } label: {
                    connectionRow("iCloud", badge: cloudBadge, active: cloudSaved) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Studio.accent)
                    }
                }
                .disabled(model.profileSyncing)
                .accessibilityHint("名前、アイコン、復習、記録、音量設定を同期")
                Divider().overlay(Studio.line).padding(.horizontal, 16)
                DisclosureGroup(isExpanded: $showConnectionBenefits) {
                    VStack(alignment: .leading, spacing: 16) {
                        connectionBenefit("Apple Music",
                            description: "自分のプレイリストでイントロ・サビトロを遊べます。イントロの再生にはサブスクリプションが必要です。")
                        connectionBenefit("iCloud",
                            description: "名前・アイコン・復習リスト・プレイ記録・音量設定を保存し、同じiCloudアカウントのiPhoneで引き継げます。")
                    }
                    .padding(.bottom, 16)
                } label: {
                    Text("外部連携するとできること")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.primary)
                        .frame(minHeight: 44)
                }
                .tint(Studio.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .animation(reduceMotion ? nil : Studio.spring, value: showConnectionBenefits)
            }
            .buttonStyle(StudioPressStyle())
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 16))

            if let status = model.profileSyncStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(Studio.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func connectionBenefit(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Studio.primary)
            Text(description).font(.subheadline).foregroundStyle(Studio.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cloudSaved: Bool { model.profileSyncStatus?.hasPrefix("iCloudに保存済み") == true }

    private var cloudBadge: String {
        if model.profileSyncing { return "同期中" }
        if cloudSaved { return "同期済み" }
        guard AppConfiguration.cloudKitEnabled else { return "未設定" }
        let status = model.profileSyncStatus ?? ""
        if status.contains("サインイン") { return "未接続" }
        if status.contains("同期待ち") || status.contains("操作終了後") { return "同期待ち" }
        return "要確認"
    }

    private func connectionRow<Icon: View>(_ title: String, badge: String, active: Bool,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 14) {
            icon().frame(width: 30, height: 30).accessibilityHidden(true)
            Text(title).font(.body).foregroundStyle(Studio.primary)
                .lineLimit(title == "iCloud" ? 1 : 2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if title == "iCloud" && model.profileSyncing { ProgressView().controlSize(.small) }
            Text(badge)
                .font(.caption.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(active ? Studio.accent : Studio.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(active ? Studio.accent.opacity(0.09) : Studio.raised, in: Capsule())
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Studio.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Studio.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(Studio.primary)
        }
    }


}

private struct AvatarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoToCrop: AvatarPhoto?
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 20)
                PlayerAvatarView(data: model.avatarData, size: 128)
                    .overlay(Circle().strokeBorder(Studio.line, lineWidth: 1))
                    .accessibilityLabel(model.avatarData == nil ? "アイコン未設定" : "現在のアイコン")
                Text(model.nickname)
                    .font(.title3.bold())
                    .foregroundStyle(Studio.primary)
                Text("選んだ写真はゲーム中、名前の横に表示されます。")
                    .font(.subheadline)
                    .foregroundStyle(Studio.secondary)
                    .multilineTextAlignment(.center)
                PhotosPicker(selection: $selectedPhoto, matching: .images, preferredItemEncoding: .current) {
                    Label("写真を選ぶ・変更", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Studio.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(loading)
                if loading { ProgressView("画像を読み込み中").tint(Studio.accent) }
                if model.avatarData != nil {
                    Button("アイコンを削除", role: .destructive) {
                        do { try model.removeAvatar() }
                        catch { errorMessage = error.localizedDescription }
                    }
                    .frame(minHeight: 44)
                    .disabled(loading)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Studio.background)
            .navigationTitle("アイコン設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完了") { dismiss() } } }
            .sheet(item: $photoToCrop) { photo in
                AvatarCropView(image: photo.image)
            }
            .alert("アイコンを設定できません", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                loading = true
                defer { loading = false; self.selectedPhoto = nil }
                do {
                    guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                          !Task.isCancelled else { return }
                    guard let image = UIImage(data: data) else {
                        throw AppError.message("画像を読み込めませんでした")
                    }
                    photoToCrop = AvatarPhoto(image: image)
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
        }
    }
}

private struct AvatarPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct AvatarCropView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let image: UIImage
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var dragOrigin = CGSize.zero
    @State private var errorMessage: String?
    private let cropSize: CGFloat = 280

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 16)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cropSize, height: cropSize)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .frame(width: cropSize, height: cropSize)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Studio.accent, lineWidth: 2))
                    .gesture(DragGesture()
                        .onChanged { value in
                            offset = limitedOffset(CGSize(width: dragOrigin.width + value.translation.width,
                                                          height: dragOrigin.height + value.translation.height))
                        }
                        .onEnded { _ in dragOrigin = offset })
                    .accessibilityLabel("アイコンの切り抜き位置")
                VStack(spacing: 8) {
                    Label("拡大・縮小", systemImage: "plus.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(Studio.secondary)
                    Slider(value: $zoom, in: 1...3)
                        .tint(Studio.accent)
                        .onChange(of: zoom) { _, _ in
                            offset = limitedOffset(offset)
                            dragOrigin = offset
                        }
                }
                .frame(maxWidth: 320)
                Text("写真を動かして、丸の中に表示する範囲を選んでください。")
                    .font(.subheadline)
                    .foregroundStyle(Studio.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                PrimaryButton(title: "この範囲をアイコンにする", symbol: "checkmark") {
                    do {
                        try model.setAvatar(image, crop: cropRect)
                        dismiss()
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Studio.background)
            .navigationTitle("アイコンを切り抜く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("キャンセル") { dismiss() } } }
            .alert("アイコンを設定できません", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }
    }

    private var renderedScale: CGFloat {
        max(cropSize / image.size.width, cropSize / image.size.height) * zoom
    }

    private func limitedOffset(_ proposed: CGSize) -> CGSize {
        let maxX = max(0, (image.size.width * renderedScale - cropSize) / 2)
        let maxY = max(0, (image.size.height * renderedScale - cropSize) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private var cropRect: CGRect {
        let side = cropSize / renderedScale
        let originX = (image.size.width - side) / 2 - offset.width / renderedScale
        let originY = (image.size.height - side) / 2 - offset.height / renderedScale
        return CGRect(x: max(0, min(originX, image.size.width - side)),
                      y: max(0, min(originY, image.size.height - side)),
                      width: side, height: side)
    }
}

private struct RoomExitConfirmation: View {
    let isPresented: Bool
    let isLeaving: Bool
    let onCancel: () -> Void
    let onLeave: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture { if !isLeaving { onCancel() } }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                VStack(spacing: 24) {
                    Text("ルームを退室しますか？")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Studio.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    VStack(spacing: 12) {
                        Button(role: .destructive, action: onLeave) {
                            HStack(spacing: 10) {
                                if isLeaving { ProgressView().tint(.white) }
                                Text(isLeaving ? "退室しています…" : "退室する")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Studio.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        Button(action: onCancel) {
                            Text("キャンセル")
                                .font(.headline)
                                .foregroundStyle(Studio.accent)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Studio.raised, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .buttonStyle(StudioPressStyle())
                    .disabled(isLeaving)
                }
                .padding(24)
                .frame(maxWidth: 360)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
                .padding(24)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("room-exit-confirmation")
                .accessibilityAction(.escape) { if !isLeaving { onCancel() } }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
                .onAppear { titleFocused = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isPresented)
    }
}

struct RoomGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showVolumeSettings = false
    @State private var showFriends = false
    @State private var showHandicapSettings = false
    @State private var selectedProfile: PlayerProfileTarget?
    @State private var showLeaveConfirmation = false
    @State private var leavingRoom = false

    var body: some View {
        ZStack {
            Studio.background.ignoresSafeArea()
            if let room = model.room {
                GeometryReader { geometry in
                    let compact = geometry.size.height < 700
                    VStack(spacing: 0) {
                        HStack {
                            Button { setLeaveConfirmation(true) } label: {
                                Image(systemName: "xmark").font(.headline).foregroundStyle(Studio.primary)
                                    .frame(width: 44, height: 44).background(Studio.surface, in: Circle())
                            }
                            .accessibilityLabel("ルームを退出")
                            Spacer()
                            Text(room.id)
                                .font(.system(size: 17, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(Studio.accent)
                                .textSelection(.enabled)
                            Button { showFriends = true } label: {
                                Image(systemName: "person.2")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Studio.primary)
                                    .frame(width: 44, height: 44)
                                    .background(Studio.surface, in: Circle())
                            }
                            .accessibilityLabel("フレンドと招待")
                            GameVolumeButton { showVolumeSettings = true }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        HStack {
                            Text("プレイヤー")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Studio.secondary)
                            Spacer()
                            Text((room.pushOrderIds ?? room.pushedIds).isEmpty ? "点数順" : "PUSH順")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Studio.accent)
                                .frame(minHeight: 28)
                        }
                        .padding(.horizontal, 20)
                        compactPlayers(room)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                        VStack(spacing: compact ? 8 : 12) {
                            if room.phase == "lobby" {
                                ScrollView {
                                    lobby(room)
                                        .frame(maxWidth: .infinity)
                                        .padding(.bottom, 12)
                                }
                                .scrollBounceBehavior(.basedOnSize)
                            } else if room.phase == "preparing" {
                                roundTitle(room)
                                ProgressView().tint(Studio.accent).scaleEffect(1.5)
                                Text("音源を準備中")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(Studio.primary)
                                Text("\(room.readyIds.count) / \(room.players.count) 人の準備が完了")
                                    .foregroundStyle(Studio.secondary)
                                if model.roomError != nil {
                                    Button("準備を再試行") { model.retryRoomRound() }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                            } else if room.phase == "countdown" {
                                roundTitle(room)
                                WaveMark()
                                Text("第\(room.round + 1)問目")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Studio.primary)
                                Text("\(max(1, Int(ceil(model.roomSecondsLeft - 30))))")
                                    .font(.system(size: 42, weight: .bold, design: .rounded))
                                    .foregroundStyle(Studio.accent)
                                Text("端末の音量を確認してください")
                                    .foregroundStyle(Studio.secondary)
                                if model.roomError != nil {
                                    Button("再生を再試行") { model.retryRoomAudio() }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                            } else if ["listening", "answering"].contains(room.phase) {
                                roundTitle(room)
                                if room.isAnswering(model.rooms.playerId) {
                                    SectionCaption(title: "YOUR TURN")
                                    Text(model.roomAnswer.isEmpty ? "文字を選んでください" : model.roomAnswer)
                                        .font(.system(size: 36, weight: .bold, design: .rounded))
                                        .foregroundStyle(Studio.primary)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.65)
                                        .multilineTextAlignment(.center)
                                    CountdownBar(remaining: model.roomSecondsLeft, total: 5, compact: true)
                                    ChoiceGrid(choices: model.roomOptions, action: { choice in
                                        Task { await model.roomAction("choose", payload: ["choice": choice]) }
                                    }, compact: true)
                                    .disabled(model.roomChoicePending)
                                } else if room.phase == "answering" &&
                                            (room.settings.endless || room.pushClosed) {
                                    watchingStage(room, compact: compact)
                                } else {
                                    listeningStage(room, compact: compact)
                                }
                                skipButton(room)
                                if model.roomError != nil && room.pausedAt == nil &&
                                    !room.questionAudioClosed && !room.isAnswering(model.rooms.playerId) {
                                    Button("再生を再試行") { model.retryRoomAudio() }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                            } else if room.phase == "reveal" {
                                roomReveal(room)
                                if model.roomError != nil {
                                    Button("再生を再試行") { model.retryRoomRevealAudio() }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                                if room.hostId == model.rooms.playerId {
                                    PrimaryButton(title: "次の曲へ", symbol: "arrow.right") {
                                        Task { await model.roomAction("next") }
                                    }
                                } else {
                                    Text("ホストが次の曲に進めます")
                                        .font(.subheadline).foregroundStyle(Studio.secondary)
                                }
                            } else if room.phase == "finished" {
                                SectionCaption(title: "FINAL RESULTS")
                                Text("ゲームセット")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundStyle(Studio.primary)
                                PrimaryButton(title: "ルームに戻る", symbol: "arrow.uturn.backward",
                                              disabled: room.hostId != model.rooms.playerId || model.roomRematchPending) {
                                    Task { await model.rematchRoom() }
                                }
                                if model.roomRematchPending {
                                    ProgressView("ルームに戻っています")
                                        .tint(Studio.accent)
                                } else if room.hostId != model.rooms.playerId {
                                    Text("ホストがルームに戻ると待機画面に戻ります")
                                        .font(.subheadline).foregroundStyle(Studio.secondary)
                                }
                                PrimaryButton(title: "ホームへ戻る", symbol: "house") {
                                    Task { await model.leaveRoom() }
                                }
                            }
                            if let error = model.roomError {
                                Text(error).font(.caption).foregroundStyle(Studio.warning)
                            }
                            if let notice = model.roomNotice {
                                Text(notice)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Studio.primary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, compact ? 8 : 16)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(reduceMotion || room.isAnswering(model.rooms.playerId) ? nil : Studio.spring,
                                   value: room.phase)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.room?.phase == "lobby", let progress = model.roomStartProgress {
                PreparationProgressView(status: model.preparationStatus ?? "ゲームを準備中", progress: progress)
            }
        }
        .overlay {
            if showFriends {
                FriendsView(inRoom: true, onClose: { showFriends = false })
                    .environmentObject(model)
                    .background(Studio.background.ignoresSafeArea())
            }
        }
        .allowsHitTesting(!showLeaveConfirmation)
        .accessibilityHidden(showLeaveConfirmation)
        .overlay {
            RoomExitConfirmation(isPresented: showLeaveConfirmation, isLeaving: leavingRoom,
                                 onCancel: { setLeaveConfirmation(false) }, onLeave: confirmLeaveRoom)
        }
        .sheet(isPresented: $showVolumeSettings) {
            GameVolumeSettingsSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showHandicapSettings) {
            RoomHandicapSettingsView()
                .environmentObject(model)
        }
        .sheet(item: $selectedProfile) { target in
            PlayerProfileSheet(target: target).environmentObject(model)
        }
    }

    private func setLeaveConfirmation(_ presented: Bool) {
        guard !leavingRoom else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) {
            showLeaveConfirmation = presented
        }
    }

    private func confirmLeaveRoom() {
        guard !leavingRoom else { return }
        leavingRoom = true
        Task { @MainActor in
            await model.leaveRoom()
            leavingRoom = false
            setLeaveConfirmation(false)
        }
    }

    private func roundTitle(_ room: RoomState) -> some View {
        SectionCaption(title: "ROUND \(room.round + 1) / \(room.totalRounds)")
    }

    private func listeningStage(_ room: RoomState, compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            if !model.roomAudioStarted {
                ProgressView().tint(Studio.accent).scaleEffect(1.5)
                Text("音源を読み込み中")
                    .font(.title2.bold()).foregroundStyle(Studio.primary)
                if model.roomError != nil {
                    Button("再生を再試行") { model.retryRoomAudio() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("この曲は？")
                    .font(.system(size: compact ? 26 : 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Studio.primary)
                CountdownBar(remaining: model.roomSecondsLeft, total: 30, compact: true)
                if !room.activeAnswers.isEmpty {
                    Text("\(room.activeAnswers.compactMap { room.player($0.playerId)?.name }.joined(separator: "・")) が解答中")
                        .font(.headline)
                        .foregroundStyle(Studio.accent)
                        .lineLimit(1)
                }
                if room.settings.endless {
                    Text("エンドレスモード・誤答: \(room.pushedIds.count) / \(room.players.count)人")
                        .font(.caption).foregroundStyle(Studio.secondary)
                } else {
                    Text("解答受付: \(room.pushedIds.count) / \(room.settings.answerSlots)人（残り\(max(0, room.settings.answerSlots - room.pushedIds.count))人）")
                        .font(.caption).foregroundStyle(Studio.secondary)
                }
                if room.player(model.rooms.playerId)?.disqualified == true {
                    Text("今回は観戦中です").foregroundStyle(Studio.secondary)
                } else if room.answerStatus == "correct" {
                    Text("正解入力済みです。受付終了を待っています")
                        .foregroundStyle(Studio.accent)
                } else if room.pushedIds.contains(model.rooms.playerId) {
                    Text("この曲は解答済みです（再PUSH不可）").foregroundStyle(Studio.secondary)
                } else if room.handicapSecondsLeft(for: model.rooms.playerId, nowMS: model.rooms.serverNowMS) > 0 {
                    Text("ハンデ中・あと\(Int(ceil(room.handicapSecondsLeft(for: model.rooms.playerId, nowMS: model.rooms.serverNowMS))))秒で解答できます")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.accent)
                } else if model.roomPushPending || room.canPush(model.rooms.playerId, nowMS: model.rooms.serverNowMS) {
                    PushButton(action: { model.beginRoomPush() }, size: compact ? 142 : 180,
                               pending: model.roomPushPending)
                }
            }
        }
    }

    private func watchingStage(_ room: RoomState, compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 12) {
            Text("\(room.activeAnswers.count)人が解答中...")
                .font(.title2.bold()).foregroundStyle(Studio.primary)
            if room.settings.endless {
                Text("曲と出題タイマーは停止中")
                    .foregroundStyle(Studio.secondary)
                CountdownBar(remaining: model.roomSecondsLeft, total: 30, compact: true)
            } else if room.audioStoppedAt != nil {
                Text("30秒経過・曲は停止中。回答完了を待っています")
                    .foregroundStyle(Studio.secondary)
            } else {
                Text("PUSH受付終了。回答完了を待っています")
                    .foregroundStyle(Studio.secondary)
            }
            ForEach(room.activeAnswers) { answer in
                HStack(spacing: 10) {
                    Text(room.player(answer.playerId)?.name ?? "プレイヤー")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(answer.progress.isEmpty ? "入力待ち" : answer.progress)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .foregroundStyle(Studio.accent)
                }
                .foregroundStyle(Studio.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func roomReveal(_ room: RoomState) -> some View {
        VStack(spacing: 10) {
            if let song = room.current?.song {
                HStack(spacing: 12) {
                    Artwork(url: song.artworkURL, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(room.correctPlayerIDs.contains(model.rooms.playerId) ? "正解！" : "この曲でした")
                            .font(.title3.bold())
                            .foregroundStyle(Studio.accent)
                        Text(song.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(song.artist)
                            .font(.caption)
                            .foregroundStyle(Studio.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Studio.primary)
                HStack(spacing: 8) {
                    Button { model.saveReview(song) } label: {
                        Label(model.reviews.contains { $0.id == song.id } ? "保存済み" : "復習に保存",
                              systemImage: "bookmark")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.reviews.contains { $0.id == song.id })
                    if let url = song.trackURL {
                        Link(destination: url) {
                            Label("曲を開く", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Studio.accent)
                        }
                    }
                }
            }
            let winners = room.correctPlayerIDs.enumerated().compactMap { index, id in
                room.player(id).map { "\(index + 1)位 \($0.name)" }
            }
            Text(winners.isEmpty ? "正解者なし" : winners.joined(separator: " ・ "))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(winners.isEmpty ? Studio.secondary : Studio.accent)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    private func lobby(_ room: RoomState) -> some View {
        VStack(spacing: 10) {
            Text("みんなを待っています")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Studio.primary)
                .multilineTextAlignment(.center)
            Text("ルームコードを友だちに共有してください")
                .foregroundStyle(Studio.secondary)
            ShareLink(item: "ルームコード: \(room.id)") {
                Label("\(room.id) を共有", systemImage: "square.and.arrow.up")
                    .font(.subheadline.bold()).foregroundStyle(Studio.accent)
                    .frame(minHeight: 44)
            }
            Button { showFriends = true } label: {
                Label("フレンドを招待", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.bold()).foregroundStyle(Studio.accent)
                    .frame(minHeight: 44)
            }
            Text("ホストがゲームを開始すると、全員の準備が始まります")
                .font(.subheadline).foregroundStyle(Studio.secondary)
            let handicapped = room.players.compactMap { player -> String? in
                let seconds = room.settings.handicapSeconds(for: player.id)
                return seconds > 0 ? "\(player.name) \(seconds)秒" : nil
            }
            if !handicapped.isEmpty {
                Text("ハンデ: \(handicapped.joined(separator: "・"))")
                    .font(.subheadline)
                    .foregroundStyle(Studio.secondary)
                    .multilineTextAlignment(.center)
            }
            if room.hostId == model.rooms.playerId {
                if room.mode != "shared" {
                    if model.appleMusicConnected {
                        if model.appleMusicPlaylists.isEmpty {
                            Button("プレイリストを読み込む") { Task { await model.loadAppleMusicPlaylists() } }
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            Picker("プレイリスト", selection: $model.selectedAppleMusicPlaylistID) {
                                Text("選択してください").tag("")
                                ForEach(model.appleMusicPlaylists) { list in Text(list.name).tag(list.id) }
                            }
                            .onChange(of: model.selectedAppleMusicPlaylistID) { _, id in
                                Task { await model.selectAppleMusicPlaylist(id) }
                            }
                            .disabled(model.busy)
                        }
                        if !model.appleMusicSongs.isEmpty {
                            Text("\(model.appleMusicSongs.count)曲を読み込みました")
                                .font(.caption).foregroundStyle(Studio.secondary)
                        }
                    }
                }
                roomRules.disabled(model.busy)
                Button { showHandicapSettings = true } label: {
                    Label("ハンデを設定", systemImage: "timer")
                        .font(.subheadline.bold()).foregroundStyle(Studio.accent)
                        .frame(minHeight: 44)
                }
                if room.players.count > 1 {
                    Menu {
                        ForEach(room.players.filter { $0.id != model.rooms.playerId }) { player in
                            Button(player.name) {
                                Task { await model.roomAction("transfer", payload: ["targetId": player.id]) }
                            }
                        }
                    } label: {
                        Label("ホストを譲る", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.subheadline).foregroundStyle(Studio.accent)
                    }
                }
                PrimaryButton(title: "ゲームを開始", symbol: "play.fill", disabled: model.busy) {
                    model.beginGameStart()
                    Task {
                        await model.startRoom()
                        model.finishGameStart()
                    }
                }
            }
        }
    }

    private var roomRules: some View {
        VStack(spacing: 12) {
            RuleDialRow(title: "問題数", value: $model.roomSettings.questionCount, range: 1...50, suffix: "問")
            RuleDialRow(title: "解答権人数", value: $model.roomSettings.answerSlots, range: 1...4, suffix: "人",
                        disabled: model.roomSettings.endless)
            DisclosureGroup("ルール詳細") {
                VStack(spacing: 12) {
                    RuleDialRow(title: "勝利目標", value: $model.roomSettings.targetScore, range: 0...500, step: 10, suffix: "点")
                    RuleDialRow(title: "正解", value: $model.roomSettings.correctPoints, range: 10...50, step: 10, suffix: "点")
                    RuleDialRow(title: "1st正解", value: $model.roomSettings.firstBonus, range: 0...50, step: 10, prefix: "+", suffix: "点")
                    RuleDialRow(title: "誤答", value: $model.roomSettings.wrongPenalty, range: 0...50, step: 10, prefix: "−", suffix: "点")
                    RuleDialRow(title: "1st誤答", value: $model.roomSettings.firstWrongPenalty, range: 0...50, step: 10, prefix: "−", suffix: "点")
                    RuleDialRow(title: "ライフ", value: $model.roomSettings.lives, range: 0...10)
                    Toggle("エンドレスモード", isOn: $model.roomSettings.endless)
                    Text("0点は勝利目標なし、ライフ0は無制限です。")
                        .font(.caption).foregroundStyle(Studio.secondary)
                }
                .padding(.top, 12)
            }
            .tint(Studio.accent)
        }
        .font(.subheadline)
    }

    private func skipButton(_ room: RoomState) -> some View {
        let hasAnswered = room.answerStatus == "wrong" || room.answerStatus == "correct"
        let disqualified = room.player(model.rooms.playerId)?.disqualified == true
        return Button(hasAnswered ? "解答済み・投票不要" : disqualified ? "失格・投票不要" :
               room.skippedIds.contains(model.rooms.playerId) ? "スキップに投票済み" : "スキップに投票") {
            Task { await model.roomAction("skip") }
        }
        .buttonStyle(SkipButtonStyle())
        .disabled(hasAnswered || disqualified || room.skippedIds.contains(model.rooms.playerId))
        .padding(.top, 12)
    }

    private func compactPlayers(_ room: RoomState) -> some View {
        let pushOrder = room.pushOrderIds ?? room.pushedIds
        let scoreOrder = room.players.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.disqualified != $1.disqualified { return !$0.disqualified }
            if $0.lives != $1.lives { return $0.lives > $1.lives }
            return $0.id < $1.id
        }
        let finalRankOrder = room.players.sorted {
            if $0.disqualified != $1.disqualified { return !$0.disqualified }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.lives != $1.lives { return $0.lives > $1.lives }
            return $0.id < $1.id
        }
        let players = room.phase == "finished" ? finalRankOrder :
            pushOrder.isEmpty ? scoreOrder :
            pushOrder.compactMap { room.player($0) } + scoreOrder.filter { !pushOrder.contains($0.id) }
        return HStack(alignment: .top, spacing: 5) {
            ForEach(players) { player in
                let isAnswering = room.isAnswering(player.id)
                let isPending = player.id == model.rooms.playerId && model.roomPushPending
                let pushRank = pushOrder.firstIndex(of: player.id)
                let isQueued = room.settings.endless && room.phase == "answering" &&
                    pushRank != nil && !room.pushedIds.contains(player.id)
                let finalRank = finalRankOrder.firstIndex { $0.id == player.id }.map { $0 + 1 } ?? 0
                let rankLabel = room.phase == "finished" ? "\(finalRank)位" :
                    pushRank.map { pushRankLabel($0) } ?? (isPending ? "判定中" : "—")
                let rankColor = room.phase == "finished" ? finalRankColor(finalRank) : isPending ? Studio.accent :
                    pushRank.map { pushRankColor($0) } ?? Studio.raised
                let rankTextColor = room.phase == "finished" || pushRank == 0 || pushRank == 1 ? Studio.primary :
                    pushRank != nil || isPending ? .white : Studio.secondary
                let localAvatar = player.id == model.rooms.playerId ? model.avatarData : nil
                VStack(spacing: 4) {
                    Text(rankLabel)
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                        .foregroundStyle(rankTextColor)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(rankColor, in: RoundedRectangle(cornerRadius: 7))
                    HStack(spacing: 2) {
                        Button {
                            selectedProfile = PlayerProfileTarget(id: player.id, name: player.name, roomID: room.id)
                        } label: {
                            HStack(spacing: 3) {
                                PlayerAvatarView(data: localAvatar, size: 18, encoded: player.avatar)
                                Text(player.name)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .foregroundStyle(Studio.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(player.name)のプロフィールを見る")
                        Menu {
                            Text(player.badge ?? "称号未設定")
                            if player.friendStatus == "available" {
                                Button("フレンド申請を送る", systemImage: "person.badge.plus") {
                                    Task { await model.sendFriendRequest(to: player.id) }
                                }
                            } else if player.friendStatus == "incoming" {
                                Button("フレンド申請を確認", systemImage: "person.2") { showFriends = true }
                            } else if player.friendStatus == "outgoing" {
                                Text("フレンド申請中")
                            } else if player.friendStatus == "friend" {
                                Text("フレンド")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Studio.secondary)
                        }
                        .accessibilityLabel("\(player.name)の操作")
                        if player.isHost {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Studio.accent)
                                .accessibilityLabel("ホスト")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 18)
                    Text("\(player.score) pt")
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(player.currentResult == "correct" ? "○" : player.currentResult == "wrong" ? "×" : "−")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(player.currentResult == "correct" ? Studio.accent :
                                         player.currentResult == "wrong" ? Studio.warning : Studio.secondary)
                        .frame(height: 35)
                        .accessibilityLabel("第\(room.round + 1)問、\(player.currentResult == "correct" ? "正解" : player.currentResult == "wrong" ? "不正解" : "未判定")")
                    Text(room.settings.lives == 0 ? "♡×∞" : "♡×\(player.lives)")
                        .foregroundStyle(player.disqualified ? Studio.warning : Studio.secondary)
                        .accessibilityLabel(room.settings.lives == 0 ? "ライフ無制限" : "ライフ \(player.lives)")
                    Text(isAnswering ? "解答中" : isPending ? "PUSH判定中" : isQueued ? "解答待ち" : "PUSH")
                        .foregroundStyle(isAnswering || isPending || isQueued ? Studio.accent : Studio.secondary)
                    Text(pushTime(player))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(room.skippedIds.contains(player.id) ? "SKIP ✓" : "SKIP —")
                        .foregroundStyle(Studio.secondary)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Studio.primary)
                .padding(5)
                .frame(maxWidth: .infinity)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                    isAnswering || isPending ? Studio.accent : Studio.line,
                    lineWidth: isAnswering || isPending ? 2 : 1))
                .grayscale(player.disqualified ? 1 : 0)
                .opacity(player.disqualified ? 0.35 : player.connected ? 1 : 0.5)
                .overlay {
                    if player.disqualified {
                        Text("失格")
                            .font(.system(size: 27, weight: .black, design: .rounded))
                            .foregroundStyle(Studio.secondary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Studio.surface.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : Studio.spring, value: players.map(\.id))
    }

    private func pushRankLabel(_ index: Int) -> String {
        ["1st", "2nd", "3rd", "4th"][min(index, 3)]
    }

    private func pushRankColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.86, green: 0.74, blue: 0.45)
        case 1: return Color(red: 0.77, green: 0.79, blue: 0.82)
        default: return Studio.accent
        }
    }

    private func finalRankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.96, green: 0.87, blue: 0.66)
        case 2: return Color(red: 0.87, green: 0.89, blue: 0.92)
        case 3: return Color(red: 0.91, green: 0.78, blue: 0.69)
        default: return Studio.raised
        }
    }

    private func pushTime(_ player: RoomPlayer) -> String {
        guard let milliseconds = player.pushTimeMS else { return "—" }
        return String(format: "%.3f秒", milliseconds / 1000)
    }

}

private struct RoomHandicapSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds: [String: Int] = [:]
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let room = model.room {
                        ForEach(room.players) { player in
                            Stepper(value: Binding(
                                get: { seconds[player.id] ?? 0 },
                                set: { seconds[player.id] = $0 }), in: 0...30) {
                                HStack {
                                    Text(player.name).lineLimit(1)
                                    Spacer()
                                    Text("\(seconds[player.id] ?? 0)秒")
                                        .foregroundStyle(Studio.accent)
                                }
                            }
                            .disabled(saving)
                            .accessibilityLabel("\(player.name)のハンデ、\(seconds[player.id] ?? 0)秒")
                        }
                    }
                } header: {
                    Text("プレイヤーごとのハンデ")
                } footer: {
                    Text("各問題の再生開始から設定した秒数、PUSHして解答できません。0秒はハンデなしです。")
                }
            }
            .navigationTitle("ハンデ設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard let room = model.room else { return }
                        let playerIDs = Set(room.players.map(\.id))
                        let values = seconds.filter { playerIDs.contains($0.key) }
                        saving = true
                        Task {
                            let saved = await model.updateRoomHandicaps(values)
                            saving = false
                            if saved { dismiss() }
                            else { errorMessage = model.roomNotice ?? "ハンデを保存できませんでした" }
                        }
                    }
                    .disabled(saving || model.room?.phase != "lobby")
                }
            }
            .alert("ハンデを保存できません", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
            .onAppear { seconds = model.room?.settings.handicaps ?? [:] }
        }
    }
}
