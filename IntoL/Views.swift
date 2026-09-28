import SwiftUI
import PhotosUI
import MediaPlayer

private enum MainTab { case play, review, friends, account }

private struct SystemMusicVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        return view
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
            Text("曲の音量はデモ曲・共有音源・試聴曲に適用されます。")
                .font(.caption)
                .foregroundStyle(Studio.secondary)
            if model.appleMusicConnected || model.spotifyConnected {
                Divider()
                Text("Apple Music・Spotify の曲（端末音量）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                SystemMusicVolumeSlider()
                    .frame(height: 30)
                    .accessibilityLabel("端末の音楽音量")
                Text("サービスの曲は端末音量で調整します。BGMと効果音にも影響します。")
                    .font(.caption)
                    .foregroundStyle(Studio.secondary)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch selectedTab {
            case .play: PlayView(homeToken: playHomeToken)
            case .review: ReviewView()
            case .friends: FriendsView()
            case .account: AccountView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .background(Studio.background)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedTab)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .fullScreenCover(isPresented: Binding(get: { model.game != nil }, set: { if !$0 { model.closeGame() } })) {
            SoloGameView()
        }
        .fullScreenCover(isPresented: Binding(get: { model.room != nil }, set: { _ in })) {
            RoomGameView().interactiveDismissDisabled()
        }
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
            if model.spotifyConnected { await model.loadSpotifyPlaylists() }
            await model.syncProfile()
        }
        .onChange(of: shortcut.practiceRequest) { _, _ in
            Task { await openRequestedPractice() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setAppActive(phase == .active)
        }
    }

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
        Button {
            if tab == .play { playHomeToken += 1 }
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                    .frame(width: 60, height: 30)
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
        .accessibilityValue(selectedTab == tab ? "選択中" : "")
    }

    @MainActor
    private func openRequestedPractice() async {
        guard !openingPractice, shortcut.practiceRequest != nil else { return }
        openingPractice = true
        defer { openingPractice = false }
        if model.searchSongs.isEmpty { await model.search() }
        guard shortcut.practiceRequest != nil else { return }
        shortcut.practiceRequest = nil
        if !model.searchSongs.isEmpty && model.game == nil { await model.startSolo() }
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("IntoL")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .tracking(-2)
                .foregroundStyle(Studio.primary)
            Text("MUSIC QUIZ")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Studio.accent)
            Spacer()
            Image(systemName: "waveform.path")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Studio.accent)
        }
    }
}

private enum PlayParty { case solo, together }
private enum PlayKind { case intro, sabitro }
private enum PlaySource { case demo, shared, appleMusic, spotify, itunes, spotifyPreview, join }

struct PlayView: View {
    let homeToken: Int
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var party: PlayParty?
    @State private var kind: PlayKind?
    @State private var source: PlaySource?
    @State private var roomCode = ""
    @State private var sampleID: String?

    var body: some View {
        NavigationStack {
            Group {
                if party == nil { landing }
                else { selectionFlow }
            }
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: party)
            .sensoryFeedback(.selection, trigger: source)
            .onChange(of: homeToken) { _, _ in resetToHome() }
            .onDisappear {
                if sampleID != nil { model.player.stop(); sampleID = nil }
            }
        }
    }

    private var landing: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    BrandHeader()
                    Spacer(minLength: 8)
                    VStack(alignment: .leading, spacing: 12) {
                        WaveMark()
                        Text("あの曲、\n何秒でわかる？")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(Studio.primary)
                        Text("聴いて、ひらめいて、PUSH。")
                            .font(.subheadline).foregroundStyle(Studio.secondary)
                    }
                    VStack(spacing: 12) {
                        PrimaryButton(title: "すぐに練習する", symbol: "play.fill", disabled: model.busy) {
                            startGame {
                                model.searchTerm = ""
                                await model.search()
                                await model.startSolo()
                            }
                        }
                        Text("オリジナル音源 · アカウント不要")
                            .font(.caption).foregroundStyle(Studio.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        SectionCaption(title: "遊び方を選ぶ")
                        PlayOptionButton(title: "ひとりで", subtitle: "好きな音源で、自分のペースで", symbol: "person.fill") { party = .solo }
                        PlayOptionButton(title: "みんなで", subtitle: model.serverConfigured ? "ルームを作成・参加して対戦" : "サーバー設定が必要です", symbol: "person.2.fill", disabled: !model.serverConfigured) { party = .together }
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Spacer()
                    Text(appVersion)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Studio.secondary.opacity(0.75))
                        .accessibilityLabel("アプリのバージョン \(appVersion)")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) (\(build))"
    }

    private var selectionFlow: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button(action: goBack) {
                            Label("戻る", systemImage: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Studio.accent)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(StudioPressStyle())
                        Spacer()
                        Text("IntoL").font(.title3.bold()).foregroundStyle(Studio.primary)
                    }
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index <= (source != nil ? 2 : kind != nil ? 1 : 0) ? Studio.accent : Studio.line).frame(height: 3)
                        }
                    }.accessibilityLabel("ステップ \(source != nil ? 3 : kind != nil ? 2 : 1) / 3")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectionPath)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Studio.accent)
                        Text(pageTitle)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(Studio.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pageDescription)
                            .font(.subheadline)
                            .foregroundStyle(Studio.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stepContent
                }
                .padding(.horizontal, 20)
                .padding(.bottom, party == .together && source != .join ? 88 : 20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? .none : Studio.spring, value: kind)
                .animation(reduceMotion ? .none : Studio.spring, value: source)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.preparationStatus) { _, status in
                guard status != nil, party == .together, source != .join else { return }
                withAnimation(reduceMotion ? nil : Studio.spring) {
                    scrollProxy.scrollTo("roomPreparationStatus", anchor: .bottom)
                }
            }
        }
    }

    private var selectionPath: String {
        var parts: [String] = []
        if let party { parts.append(party == .solo ? "ひとりで" : "みんなで") }
        if let kind { parts.append(kind == .intro ? "イントロ" : "サビトロ") }
        return parts.joined(separator: "  /  ")
    }

    private var pageTitle: String {
        if party == nil { return "今日はどう遊ぶ？" }
        if kind == nil { return "どんなクイズ？" }
        if source == nil { return party == .solo ? "音源を選ぶ" : "遊び方を選ぶ" }
        switch source {
        case .demo: return "オリジナル音源"
        case .shared: return "共有音源"
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .itunes: return "試聴曲を探す"
        case .spotifyPreview: return "プレイリストから探す"
        case .join: return "ルームに参加"
        case nil: return ""
        }
    }

    private var pageDescription: String {
        if party == nil { return "まずは人数を選んでください。" }
        if kind == nil { return "聴きたい部分を選んでください。" }
        if source == nil { return "使う曲や参加方法を選んでください。" }
        switch source {
        case .demo: return "アプリに入っている曲ですぐに遊べます。"
        case .shared: return "サーバーに登録された曲を使います。"
        case .appleMusic: return "Apple Music のライブラリにあるプレイリストを使います。"
        case .spotify: return "自分のプレイリストを使います。"
        case .itunes: return "iTunes の試聴音源で遊びます。"
        case .spotifyPreview: return "プレイリストの曲を iTunes の試聴音源に照合します。"
        case .join: return "友だちから届いた6文字のIDを入力します。"
        case nil: return ""
        }
    }

    @ViewBuilder private var stepContent: some View {
        if kind == nil {
            VStack(spacing: 12) {
                PlayOptionButton(title: "イントロ", subtitle: "曲の始まりを聴いて答える", symbol: "play.fill") {
                    kind = .intro
                }
                PlayOptionButton(title: "サビトロ", subtitle: model.serverConfigured ? "試聴音源を聴いて答える" : "サーバー設定が必要です", symbol: "waveform", disabled: !model.serverConfigured) {
                    kind = .sabitro
                }
            }
        } else if source == nil {
            sourceChoices
        } else {
            detailContent
        }
    }

    @ViewBuilder private var sourceChoices: some View {
        VStack(spacing: 12) {
            if party == .solo && kind == .intro {
                PlayOptionButton(title: "オリジナル音源", subtitle: "すぐに始める", symbol: "music.note") { source = .demo }
                PlayOptionButton(title: "共有音源", subtitle: model.serverConfigured ? "登録された曲で遊ぶ" : "サーバー設定が必要です", symbol: "music.note.list", disabled: !model.serverConfigured) { source = .shared }
                PlayOptionButton(title: "Apple Music", subtitle: "自分のプレイリストで遊ぶ", symbol: "music.note.list") { source = .appleMusic }
                PlayOptionButton(title: "Spotify", subtitle: model.spotifyConfigured ? "自分のプレイリストで遊ぶ" : "Spotify 設定が必要です", symbol: "music.mic", disabled: !model.spotifyConfigured) { source = .spotify }
            } else if party == .solo {
                PlayOptionButton(title: "試聴曲を検索", subtitle: "曲名やアーティストから探す", symbol: "magnifyingglass") { source = .itunes }
                PlayOptionButton(title: "Spotifyプレイリスト", subtitle: model.spotifyConfigured ? "試聴曲と照合して遊ぶ" : "Spotify 設定が必要です", symbol: "music.note.list", disabled: !model.spotifyConfigured) { source = .spotifyPreview }
            } else if kind == .intro {
                PlayOptionButton(title: "共有音源で作る", subtitle: "登録された曲で対戦", symbol: "music.note.list") { selectRoomSource(.shared) }
                PlayOptionButton(title: "Apple Musicで作る", subtitle: "全員が Apple Music で再生", symbol: "music.note.list") { selectRoomSource(.appleMusic) }
                PlayOptionButton(title: "Spotifyで作る", subtitle: model.spotifyConfigured ? "全員が Premium で再生" : "Spotify 設定が必要です", symbol: "music.mic", disabled: !model.spotifyConfigured) { selectRoomSource(.spotify) }
                PlayOptionButton(title: "ルームに参加", subtitle: "6文字のIDを入力", symbol: "person.badge.plus") { source = .join }
            } else {
                PlayOptionButton(title: "プレイリストから作る", subtitle: model.spotifyConfigured ? "iTunes の試聴曲で対戦" : "Spotify 設定が必要です", symbol: "music.note.list", disabled: !model.spotifyConfigured) { selectRoomSource(.spotifyPreview) }
                PlayOptionButton(title: "ルームに参加", subtitle: "6文字のIDを入力", symbol: "person.badge.plus") { source = .join }
            }
        }
    }

    @ViewBuilder private var detailContent: some View {
        if party == .solo {
            switch source {
            case .demo: demoContent
            case .shared: sharedContent
            case .appleMusic: appleMusicContent
            case .spotify: spotifyContent(sabitro: false)
            case .itunes: itunesContent
            case .spotifyPreview: spotifyContent(sabitro: true)
            default: EmptyView()
            }
        } else if source == .join {
            joinContent
        } else {
            roomContent
        }
    }

    private var demoContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                searchField("曲名で絞り込む", text: $model.searchTerm) { Task { await model.search() } }
                if model.searchSongs.isEmpty {
                    Text("曲が見つかりません。検索語を変えてください。")
                        .foregroundStyle(Studio.secondary)
                } else {
                    Text("\(model.searchSongs.count)曲から出題")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.secondary)
                    ForEach(model.searchSongs.prefix(3)) { song in SongRow(song: song) }
                    PrimaryButton(title: "プレイ開始", symbol: "arrow.right", disabled: model.busy) {
                        startGame { await model.startSolo() }
                    }
                    if let status = model.preparationStatus { Text(status).font(.caption).foregroundStyle(Studio.secondary) }
                }
            }
        }
    }

    private var sharedContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                if model.serverConfigured {
                    Button("曲を読み込む") { Task { await model.loadSharedSongs() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.busy)
                    if model.busy { ProgressView().tint(Studio.accent) }
                    if !model.sharedSongs.isEmpty {
                        Text("\(model.sharedSongs.count)曲を利用できます")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Studio.secondary)
                        ForEach(model.sharedSongs.prefix(3)) { song in SongRow(song: song) }
                        PrimaryButton(title: "プレイ開始", symbol: "arrow.right", disabled: model.busy) {
                            startGame { await model.startSolo(shared: true) }
                        }
                        if let status = model.preparationStatus { Text(status).font(.caption).foregroundStyle(Studio.secondary) }
                    }
                } else {
                    Text("共有音源は現在利用できません")
                        .foregroundStyle(Studio.secondary)
                }
            }
        }
    }

    @ViewBuilder private func spotifyContent(sabitro: Bool) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                playlistInput
                if !model.spotifySongs.isEmpty {
                    if sabitro {
                        PrimaryButton(title: "プレイ開始", symbol: "arrow.right", disabled: model.busy) {
                            startGame { await model.startSabitroSolo() }
                        }
                    } else {
                        PrimaryButton(title: "プレイ開始", symbol: "arrow.right", disabled: !model.spotifyPremium || model.busy) {
                            startGame { await model.startSpotifySolo() }
                        }
                        if !model.spotifyPremium {
                            Text("Spotify 音源の再生には Premium が必要です")
                                .font(.caption).foregroundStyle(Studio.secondary)
                        }
                    }
                    if let status = model.preparationStatus { Text(status).font(.caption).foregroundStyle(Studio.secondary) }
                }
            }
        }
    }

    private var appleMusicContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                appleMusicPlaylistInput
                if model.appleMusicConnected, !model.appleMusicSongs.isEmpty {
                    ForEach(model.appleMusicSongs.prefix(3)) { song in SongRow(song: song) }
                    PrimaryButton(title: "プレイ開始", symbol: "arrow.right",
                                  disabled: !model.appleMusicPlayable || model.busy) {
                        startGame { await model.startAppleMusicSolo() }
                    }
                    if let status = model.preparationStatus { Text(status).font(.caption).foregroundStyle(Studio.secondary) }
                }
            }
        }
    }

    @ViewBuilder private var appleMusicPlaylistInput: some View {
        if model.appleMusicConnected {
            if model.appleMusicPlaylists.isEmpty {
                Button("プレイリストを読み込む") { Task { await model.loadAppleMusicPlaylists() } }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Picker("プレイリスト", selection: $model.selectedAppleMusicPlaylistID) {
                    Text("選択してください").tag("")
                    ForEach(model.appleMusicPlaylists) { list in Text(list.name).tag(list.id) }
                }
                .tint(Studio.accent)
                .onChange(of: model.selectedAppleMusicPlaylistID) { _, id in
                    Task { await model.selectAppleMusicPlaylist(id) }
                }
            }
            if model.busy { ProgressView().tint(Studio.accent) }
            if !model.appleMusicSongs.isEmpty {
                Text("\(model.appleMusicSongs.count)曲を読み込みました")
                    .font(.subheadline).foregroundStyle(Studio.secondary)
            }
            if !model.appleMusicPlayable {
                Text("再生には Apple Music のサブスクリプションが必要です")
                    .font(.caption).foregroundStyle(Studio.secondary)
            }
        } else {
            HStack(spacing: 12) {
                AppleMusicIcon(size: 44)
                Text("好きなプレイリストで遊ぼう")
                    .font(.headline).foregroundStyle(Studio.primary)
            }
            Button("Apple Music に接続") { Task { await model.connectAppleMusic() } }
                .buttonStyle(SecondaryButtonStyle()).disabled(model.busy)
            Text("ライブラリへのアクセスとサブスクリプションが必要です。")
                .font(.caption).foregroundStyle(Studio.secondary)
        }
    }

    private var itunesContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                if model.serverConfigured {
                    searchField("曲名・アーティスト", text: $model.itunesTerm) { Task { await model.searchItunes() } }
                    if model.busy { ProgressView().tint(Studio.accent) }
                    if !model.itunesSongs.isEmpty {
                        Text("\(model.itunesSongs.count)曲が見つかりました")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Studio.secondary)
                        ForEach(model.itunesSongs.prefix(3)) { song in
                            HStack {
                                SongRow(song: song)
                                Button(sampleID == song.id ? "停止" : "試聴") {
                                    if sampleID == song.id { model.player.stop(); sampleID = nil }
                                    else if let url = song.previewURL { model.player.play(url); sampleID = song.id }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Studio.accent)
                                .frame(minWidth: 44, minHeight: 44)
                            }
                        }
                        PrimaryButton(title: "プレイ開始", symbol: "arrow.right", disabled: model.busy) {
                            model.player.stop()
                            sampleID = nil
                            startGame { await model.startItunesSolo() }
                        }
                        if let status = model.preparationStatus { Text(status).font(.caption).foregroundStyle(Studio.secondary) }
                    }
                } else {
                    Text("試聴曲検索は現在利用できません")
                        .foregroundStyle(Studio.secondary)
                }
            }
        }
    }

    @ViewBuilder private var playlistInput: some View {
        if model.spotifyConnected {
            Text("接続中: \(model.spotifyAccountName)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Studio.accent)
            if model.spotifyPlaylists.isEmpty {
                Button("プレイリストを読み込む") { Task { await model.loadSpotifyPlaylists() } }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Picker("プレイリスト", selection: $model.selectedPlaylistID) {
                    Text("選択してください").tag("")
                    ForEach(model.spotifyPlaylists) { list in Text(list.name).tag(list.id) }
                }
                .tint(Studio.accent)
                .onChange(of: model.selectedPlaylistID) { _, id in
                    Task { await model.selectPlaylist(id) }
                }
                if model.busy { ProgressView().tint(Studio.accent) }
                if !model.spotifySongs.isEmpty {
                    Text("\(model.spotifySongs.count)曲を読み込みました")
                        .font(.subheadline).foregroundStyle(Studio.secondary)
                }
            }
        } else if model.spotifyConfigured {
            Text("アカウントで Spotify を連携してください")
                .foregroundStyle(Studio.secondary)
        } else {
            Text("Spotify 連携は現在利用できません")
                .foregroundStyle(Studio.secondary)
        }
    }

    private var roomContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 18) {
                if model.serverConfigured {
                    if source == .spotify || source == .spotifyPreview { playlistInput }
                    if source == .appleMusic { appleMusicPlaylistInput }
                    Stepper("問題数 \(model.roomSettings.questionCount)", value: $model.roomSettings.questionCount, in: 1...50)
                    Stepper("解答権人数 \(model.roomSettings.answerSlots)人", value: $model.roomSettings.answerSlots, in: 1...4)
                        .disabled(model.roomSettings.endless)
                    DisclosureGroup("ルール詳細") {
                        VStack(spacing: 12) {
                            Stepper("勝利目標 \(model.roomSettings.targetScore)点", value: $model.roomSettings.targetScore, in: 0...500, step: 10)
                            Stepper("正解 \(model.roomSettings.correctPoints)点", value: $model.roomSettings.correctPoints, in: 10...50, step: 10)
                            Stepper("1st正解 +\(model.roomSettings.firstBonus)点", value: $model.roomSettings.firstBonus, in: 0...50, step: 10)
                            Stepper("誤答 −\(model.roomSettings.wrongPenalty)点", value: $model.roomSettings.wrongPenalty, in: 0...50, step: 10)
                            Stepper("1st誤答 −\(model.roomSettings.firstWrongPenalty)点", value: $model.roomSettings.firstWrongPenalty, in: 0...50, step: 10)
                            Stepper("ライフ \(model.roomSettings.lives)", value: $model.roomSettings.lives, in: 0...10)
                            Toggle("エンドレスモード", isOn: $model.roomSettings.endless)
                            Text("エンドレスモードでは解答権人数に関係なく、全員で曲を止めて1人ずつ解答します。")
                                .font(.caption).foregroundStyle(Studio.secondary)
                            Text("0点は勝利目標なし、ライフ0は無制限です。")
                                .font(.caption).foregroundStyle(Studio.secondary)
                        }
                        .padding(.top, 12)
                    }
                    .tint(Studio.accent)
                    PrimaryButton(title: "ルームを作る", symbol: "arrow.right",
                                  disabled: model.busy || (source == .appleMusic ? model.appleMusicSongs.isEmpty || !model.appleMusicPlayable :
                                      source != .shared && (model.spotifySongs.isEmpty || (source == .spotify && !model.spotifyPremium)))) {
                        Task { await model.createRoom() }
                    }
                    if let status = model.preparationStatus {
                        HStack(spacing: 8) {
                            ProgressView().tint(Studio.accent)
                            Text(status).font(.caption).foregroundStyle(Studio.secondary)
                        }
                        .id("roomPreparationStatus")
                    }
                    if source == .spotify && !model.spotifyPremium {
                        Text("Spotify 対戦には全員の Premium が必要です")
                            .font(.caption).foregroundStyle(Studio.secondary)
                    }
                    if source == .appleMusic && !model.appleMusicPlayable {
                        Text("Apple Music 対戦には全員のサブスクリプションが必要です")
                            .font(.caption).foregroundStyle(Studio.secondary)
                    }
                } else {
                    Text("対戦は現在利用できません")
                        .foregroundStyle(Studio.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    private var joinContent: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 16) {
                if model.serverConfigured {
                    TextField("6文字のルームID", text: $roomCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 15)
                        .frame(height: 52)
                        .background(Studio.raised, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("6文字のルームID")
                    PrimaryButton(title: "参加する", symbol: "arrow.right", disabled: roomCode.trimmingCharacters(in: .whitespacesAndNewlines).count != 6 || model.busy) {
                        Task { await model.joinRoom(roomCode) }
                    }
                } else {
                    Text("対戦は現在利用できません")
                        .foregroundStyle(Studio.secondary)
                }
            }
        }
    }

    @MainActor private func startGame(_ action: @escaping @MainActor () async -> Void) {
        model.beginGameStart()
        Task {
            defer { model.finishGameStart() }
            await action()
        }
    }

    private func searchField(_ prompt: String, text: Binding<String>, search: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            TextField(prompt, text: text)
                .submitLabel(.search)
                .onSubmit(search)
                .padding(.horizontal, 15)
                .frame(height: 52)
                .background(Studio.raised, in: RoundedRectangle(cornerRadius: 12))
            Button(action: search) {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Studio.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel("検索")
        }
    }

    private func selectRoomSource(_ value: PlaySource) {
        source = value
        switch value {
        case .shared: model.roomMode = "shared"
        case .appleMusic: model.roomMode = "applemusic"
        case .spotify: model.roomMode = "spotify"
        case .spotifyPreview: model.roomMode = "sabitro"
        default: break
        }
    }

    private func goBack() {
        model.player.stop()
        sampleID = nil
        if source != nil { source = nil }
        else if kind != nil { kind = nil }
        else { party = nil }
    }

    private func resetToHome() {
        if sampleID != nil { model.player.stop(); sampleID = nil }
        party = nil
        kind = nil
        source = nil
        roomCode = ""
    }
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

private struct PlayOptionButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Group {
                    if title.contains("Apple Music") { AppleMusicIcon() }
                    else { Image(systemName: symbol).font(.system(size: 20, weight: .semibold)) }
                }
                    .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                    .frame(width: 48, height: 48)
                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Studio.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Studio.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: disabled ? "lock.fill" : "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.radius))
            .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.line))
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(disabled)
        .accessibilityLabel("\(title)、\(subtitle)")
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

private struct SongRow: View {
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

private struct PushButton: View {
    let action: () -> Void
    var size: CGFloat = 256
    var pending = false
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Studio.line, lineWidth: 1).frame(width: size, height: size)
                Circle().strokeBorder(Studio.accent.opacity(0.35), lineWidth: 1).frame(width: size * 0.875, height: size * 0.875)
                Circle().fill(Studio.accent).frame(width: size * 0.742, height: size * 0.742)
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
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(pending)
        .accessibilityLabel(pending ? "PUSHを判定中" : "PUSH、解答する")
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
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel("選択肢\(index + 1)、\(choice)")
            }
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
                                .font(.subheadline)
                                .foregroundStyle(Studio.secondary)
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
                    .animation(reduceMotion ? .none : Studio.spring, value: game.stage)
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
                    stat("平均 PUSH", String(format: "%.1f秒", result.averagePush))
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
    @State private var learned = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("復習")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Studio.primary)
                    Text("出会った曲を、次は思い出せるように。")
                        .foregroundStyle(Studio.secondary)
                    Picker("状態", selection: $learned) {
                        Text("覚えてない").tag(false)
                        Text("覚えた").tag(true)
                    }
                    .pickerStyle(.segmented)
                    let items = model.reviews.filter { $0.learned == learned }
                    if items.isEmpty {
                        ContentUnavailableView(learned ? "まだありません" : "保存した曲はありません", systemImage: "bookmark",
                                               description: Text("正解発表の画面から曲を保存できます。"))
                            .foregroundStyle(Studio.secondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(items) { item in
                            ReviewSongRow(item: item,
                                          toggleLearned: { model.toggleLearned(item.id) },
                                          remove: { model.removeReview(item.id) })
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct ReviewSongRow: View {
    let item: ReviewSong
    let toggleLearned: () -> Void
    let remove: () -> Void

    private var musicURL: URL? {
        if let url = item.song.trackURL,
           let host = url.host, ["music.apple.com", "itunes.apple.com"].contains(host) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.host = "music.apple.com"
            return components?.url
        }
        return nil
    }

    private var searchURL: URL? {
        guard !item.song.id.hasPrefix("demo:") else { return nil }
        var components = URLComponents(string: "https://music.apple.com/jp/search")
        components?.queryItems = [URLQueryItem(name: "term", value: "\(item.song.title) \(item.song.artist)")]
        return components?.url
    }

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: item.song.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                    .lineLimit(2)
                Text(item.song.artist)
                    .font(.caption).foregroundStyle(Studio.secondary).lineLimit(1)
                if let url = musicURL ?? searchURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            AppleMusicIcon(size: 16)
                            Text(musicURL != nil ? "Apple Musicで聴く" : "Apple Musicで探す")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Studio.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                } else {
                    Text("オリジナル音源")
                        .font(.caption2).foregroundStyle(Studio.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: toggleLearned) {
                Text(item.learned ? "戻す" : "覚えた")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Studio.accent)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(item.learned ? "覚えてないに戻す" : "覚えたに変更")
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundStyle(Studio.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("\(item.song.title)を復習リストから削除")
        }
        .padding(12)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.radius))
        .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.line))
        .buttonStyle(StudioPressStyle())
    }
}

struct FriendsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var inRoomSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("フレンド")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Studio.primary)
                        Spacer()
                        Button { Task { await model.refreshFriends() } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("フレンド情報を更新")
                        .disabled(!model.serverConfigured)
                        if inRoomSheet {
                            Button("閉じる") { dismiss() }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    if !model.serverConfigured {
                        StudioCard {
                            Text("フレンド機能には対戦サーバーへの接続が必要です")
                                .foregroundStyle(Studio.secondary)
                        }
                    } else if let state = model.friendsState {
                        StudioCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionCaption(title: "ルーム招待")
                                if state.invites.isEmpty {
                                    Text("届いている招待はありません").foregroundStyle(Studio.secondary)
                                }
                                ForEach(state.invites) { invite in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(invite.fromName).font(.subheadline.bold())
                                            Text("\(invite.mode == "shared" ? "共有音源" : invite.mode == "applemusic" ? "Apple Music" : invite.mode == "spotify" ? "Spotify" : "サビトロ") のルーム")
                                                .font(.caption).foregroundStyle(Studio.secondary)
                                        }
                                        Spacer()
                                        Button("参加") { Task { await model.joinInvite(invite.id) } }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .disabled(model.busy || model.room != nil)
                                    }
                                    .frame(minHeight: 44)
                                    if invite.id != state.invites.last?.id { Divider() }
                                }
                                if model.room != nil && !state.invites.isEmpty {
                                    Text("別のルームに参加するには、現在のルームを退出してください")
                                        .font(.caption).foregroundStyle(Studio.secondary)
                                }
                            }
                        }
                        StudioCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionCaption(title: "フレンド申請")
                                if state.requests.isEmpty {
                                    Text("届いている申請はありません").foregroundStyle(Studio.secondary)
                                }
                                ForEach(state.requests) { request in
                                    HStack(spacing: 8) {
                                        Text(request.fromName).font(.subheadline.bold())
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button("承認") {
                                            Task { await model.respondToFriendRequest(request.id, accept: true) }
                                        }
                                        .buttonStyle(SecondaryButtonStyle())
                                        Button("拒否") {
                                            Task { await model.respondToFriendRequest(request.id, accept: false) }
                                        }
                                        .font(.subheadline).foregroundStyle(Studio.secondary)
                                    }
                                    .frame(minHeight: 44)
                                    .disabled(model.friendsLoading)
                                    if request.id != state.requests.last?.id { Divider() }
                                }
                            }
                        }
                        StudioCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionCaption(title: "フレンドリスト")
                                if state.friends.isEmpty {
                                    Text("同じルームのプレイヤーに申請を送ると、ここに表示されます")
                                        .foregroundStyle(Studio.secondary)
                                }
                                ForEach(state.friends) { friend in
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.crop.circle")
                                            .foregroundStyle(Studio.accent)
                                        Text(friend.name).font(.subheadline.bold())
                                        Spacer()
                                        if model.room?.phase == "lobby" {
                                            if model.room?.players.contains(where: { $0.friendProfileId == friend.id }) == true {
                                                Text("参加中").font(.caption).foregroundStyle(Studio.secondary)
                                            } else {
                                                Button("招待") { Task { await model.inviteFriend(friend.id) } }
                                                    .buttonStyle(SecondaryButtonStyle())
                                                    .disabled(model.friendsLoading)
                                            }
                                        }
                                    }
                                    .frame(minHeight: 44)
                                    if friend.id != state.friends.last?.id { Divider() }
                                }
                                if model.room == nil {
                                    Text("ルームを作成するとフレンドを招待できます")
                                        .font(.caption).foregroundStyle(Studio.secondary)
                                }
                            }
                        }
                    } else {
                        ProgressView("フレンドを読み込み中")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refreshFriends() }
            .task {
                await model.refreshFriends()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if Task.isCancelled { break }
                    await model.refreshFriends(reportErrors: false)
                }
            }
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRecords = false
    @State private var showAvatarSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("アカウント")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Studio.primary)
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
                                Text(String(format: "平均 PUSH %.1f秒 ・ 解答 %d回", model.stats.averagePush, model.stats.attempts))
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
                    StudioCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionCaption(title: "プロフィール・音楽サービス")
                            Button { showAvatarSettings = true } label: {
                                HStack(spacing: 12) {
                                    PlayerAvatarView(data: model.avatarData, size: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("アイコンを設定")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Studio.primary)
                                        Text("フォトライブラリから選択")
                                            .font(.caption)
                                            .foregroundStyle(Studio.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Studio.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("アイコンを設定")
                            field("プレイヤー名", text: $model.nickname, prompt: "プレイヤー")
                            Picker("音楽サービス", selection: $model.selectedMusicProvider) {
                                ForEach(MusicAccountProvider.allCases) { provider in
                                    Text(provider.rawValue).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("接続する音楽サービス")
                            if model.selectedMusicProvider == .appleMusic {
                                appleMusicAccount
                            } else {
                                spotifyAccount
                            }
                            if model.serverConfigured {
                                Button("記録を同期") { Task { await model.syncProfile() } }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            if let status = model.profileSyncStatus {
                                Text(status).font(.caption).foregroundStyle(Studio.secondary)
                            }
                            if model.serverConfigured {
                                Text("共有音源を使う場合は、利用できる権利を持つ音声をサーバーに登録してください。")
                                    .font(.caption)
                                    .foregroundStyle(Studio.secondary)
                            }
                        }
                    }
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
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showAvatarSettings) {
            AvatarSettingsView()
                .environmentObject(model)
        }
    }

    @ViewBuilder private var appleMusicAccount: some View {
        HStack(spacing: 10) {
            AppleMusicIcon()
            Text("Apple Music").font(.headline).foregroundStyle(Studio.primary)
            Spacer()
            Text(model.appleMusicConnected ? "接続済み" : "未接続")
                .font(.caption).foregroundStyle(Studio.secondary)
        }
        if model.appleMusicConnected {
            Text(model.appleMusicPlayable ? "Apple Music に接続中 · 再生可能" : "Apple Music に接続中 · サブスクリプションを確認してください")
                .font(.subheadline).foregroundStyle(Studio.accent)
            Button("接続状態を更新") { Task { await model.loadAppleMusicPlaylists() } }
                .buttonStyle(SecondaryButtonStyle())
        } else {
            Button("Apple Music に接続") { Task { await model.connectAppleMusic() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.busy)
            Text("iPhone の Apple Music へのアクセスを許可します。")
                .font(.caption).foregroundStyle(Studio.secondary)
        }
    }

    @ViewBuilder private var spotifyAccount: some View {
        if model.spotifyConnected {
            Text("接続中: \(model.spotifyAccountName) \(model.spotifyPremium ? "Premium" : "Free")")
                .font(.subheadline).foregroundStyle(Studio.accent)
            HStack {
                Button("再連携") { Task { await model.connectSpotify(reconnect: true) } }
                    .buttonStyle(SecondaryButtonStyle())
                Button("解除") { model.disconnectSpotify() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Text("再生にはこの iPhone の Spotify アプリを使います。")
                .font(.caption).foregroundStyle(Studio.secondary)
        } else if model.spotifyConfigured {
            Button("Spotify に接続") { Task { await model.connectSpotify() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.busy)
        } else {
            Text("Spotify の利用にはサーバーと Client ID の設定が必要です")
                .font(.caption).foregroundStyle(Studio.secondary)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Studio.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(Studio.primary)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Studio.secondary)
            TextField(prompt, text: text)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Studio.raised, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Studio.primary)
        }
    }
}

private struct AvatarSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
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
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
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
                    try model.setAvatar(data)
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
        }
    }
}

struct RoomGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("roomPlayerOrder") private var playerOrder = "score"
    @State private var showVolumeSettings = false
    @State private var showFriends = false

    var body: some View {
        ZStack {
            Studio.background.ignoresSafeArea()
            if let room = model.room {
                GeometryReader { geometry in
                    let compact = geometry.size.height < 700
                    VStack(spacing: 0) {
                        HStack {
                            Button { Task { await model.leaveRoom() } } label: {
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
                            Menu {
                                Picker("プレイヤーの並び順", selection: $playerOrder) {
                                    Text("点数順").tag("score")
                                    Text("PUSH順").tag("push")
                                }
                            } label: {
                                Label(playerOrder == "push" ? "PUSH順" : "点数順", systemImage: "arrow.left.arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Studio.accent)
                                    .frame(minHeight: 28)
                            }
                            .accessibilityLabel("プレイヤーの並び順: \(playerOrder == "push" ? "PUSH順" : "点数順")")
                        }
                        .padding(.horizontal, 20)
                        compactPlayers(room)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 12)
                        VStack(spacing: compact ? 8 : 12) {
                            if room.phase == "lobby" {
                                lobby(room)
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
                        .animation(reduceMotion ? .none : Studio.spring, value: room.phase)
                    }
                }
            }
        }
        .sheet(isPresented: $showVolumeSettings) {
            GameVolumeSettingsSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $showFriends) {
            FriendsView(inRoomSheet: true)
                .environmentObject(model)
                .presentationDetents([.large])
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
                } else if model.roomPushPending || room.canPush(model.rooms.playerId) {
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
            Text("ルームIDを友だちに共有してください")
                .foregroundStyle(Studio.secondary)
            ShareLink(item: room.id) {
                Label("\(room.id) を共有", systemImage: "square.and.arrow.up")
                    .font(.subheadline.bold())
                    .foregroundStyle(Studio.accent)
            }
            Button { showFriends = true } label: {
                Label("フレンドを招待", systemImage: "person.crop.circle.badge.plus")
                    .font(.subheadline.bold()).foregroundStyle(Studio.accent)
                    .frame(minHeight: 44)
            }
            Text("画像と音源の準備: \((room.assetsReadyIds ?? []).count) / \(room.players.count) 人")
                .font(.subheadline).foregroundStyle(Studio.secondary)
            if let status = model.roomPreparationStatus {
                Text(status).font(.caption).foregroundStyle(Studio.secondary)
            }
            if model.roomError != nil {
                Button("準備を再試行") { model.retryRoomPreload() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if room.hostId == model.rooms.playerId {
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
                PrimaryButton(title: "ゲームを始める", symbol: "play.fill",
                              disabled: (room.assetsReadyIds ?? []).count < room.players.count) {
                    model.beginGameStart()
                    Task {
                        await model.roomAction("start")
                        model.finishGameStart()
                    }
                }
            }
        }
    }

    private func skipButton(_ room: RoomState) -> some View {
        let wasWrong = room.answerStatus == "wrong"
        return Button(wasWrong ? "誤答済み・投票不要" :
               room.skippedIds.contains(model.rooms.playerId) ? "スキップに投票済み" : "スキップに投票") {
            Task { await model.roomAction("skip") }
        }
        .font(.subheadline)
        .foregroundStyle(Studio.secondary)
        .frame(minHeight: 36)
        .disabled(wasWrong || room.skippedIds.contains(model.rooms.playerId))
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
        let players = playerOrder == "push" ?
            pushOrder.compactMap { room.player($0) } + room.players.filter { !pushOrder.contains($0.id) } :
            scoreOrder
        return HStack(alignment: .top, spacing: 5) {
            ForEach(players) { player in
                let isAnswering = room.isAnswering(player.id)
                let isPending = player.id == model.rooms.playerId && model.roomPushPending
                let pushRank = pushOrder.firstIndex(of: player.id)
                let finalRank = finalRankOrder.firstIndex { $0.id == player.id }.map { $0 + 1 } ?? 0
                let rankLabel = room.phase == "finished" ? "\(finalRank)位" :
                    pushRank.map { pushRankLabel($0) } ?? (isPending ? "判定中" : "—")
                let rankColor = room.phase == "finished" || isPending ? Studio.accent :
                    pushRank.map { pushRankColor($0) } ?? Studio.raised
                let rankTextColor = room.phase != "finished" && (pushRank == 0 || pushRank == 1) ? Studio.primary :
                    pushRank != nil || isPending || room.phase == "finished" ? .white : Studio.secondary
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
                            HStack(spacing: 3) {
                                PlayerAvatarView(data: localAvatar, size: 18, encoded: player.avatar)
                                Text(player.name)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .foregroundStyle(Studio.primary)
                            }
                        }
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
                    Text(isAnswering ? "解答中" : isPending ? "PUSH判定中" : "PUSH")
                        .foregroundStyle(isAnswering || isPending ? Studio.accent : Studio.secondary)
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

    private func pushTime(_ player: RoomPlayer) -> String {
        guard let milliseconds = player.pushTimeMS else { return "—" }
        return String(format: "%.2f秒", milliseconds / 1000)
    }

}
