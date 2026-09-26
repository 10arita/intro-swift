import SwiftUI

private enum MainTab { case play, review, account }

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shortcut = PracticeShortcutRoute.shared
    @State private var openingPractice = false
    @State private var selectedTab: MainTab = .play
    @State private var playHomeToken = 0

    var body: some View {
        Group {
            switch selectedTab {
            case .play: PlayView(homeToken: playHomeToken)
            case .review: ReviewView()
            case .account: AccountView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .background(Studio.background)
        .fullScreenCover(isPresented: Binding(get: { model.game != nil }, set: { if !$0 { model.closeGame() } })) {
            SoloGameView()
        }
        .fullScreenCover(isPresented: Binding(get: { model.room != nil }, set: { if !$0 { Task { await model.leaveRoom() } } })) {
            RoomGameView()
        }
        .alert("IntoL", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task {
            Task { await model.restoreRoom() }
            if model.searchSongs.isEmpty { await model.search() }
            await openRequestedPractice()
            if model.spotifyConnected { await model.loadSpotifyPlaylists(); await model.loadSpotifyDevices() }
            await model.syncProfile()
        }
        .onChange(of: shortcut.practiceRequest) { _, _ in
            Task { await openRequestedPractice() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("プレイ", symbol: "waveform", tab: .play)
            tabButton("復習", symbol: "bookmark", tab: .review)
            tabButton("アカウント", symbol: "person.crop.circle", tab: .account)
        }
        .padding(.top, 9)
        .padding(.bottom, 4)
        .background(Studio.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Studio.line.frame(height: 1) }
    }

    private func tabButton(_ title: String, symbol: String, tab: MainTab) -> some View {
        Button {
            if tab == .play { playHomeToken += 1 }
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                Text(title).font(.caption2)
            }
            .foregroundStyle(selectedTab == tab ? Studio.accent : Studio.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
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
        if !model.searchSongs.isEmpty && model.game == nil { model.startSolo() }
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
private enum PlaySource { case demo, shared, spotify, itunes, spotifyPreview, join }

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
            .onChange(of: homeToken) { _, _ in resetToHome() }
            .onDisappear {
                if sampleID != nil { model.player.stop(); sampleID = nil }
            }
        }
    }

    private var landing: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    Spacer(minLength: 48)
                    VStack(spacing: 4) {
                        Text("IntoL")
                            .font(.system(size: 78, weight: .black, design: .rounded))
                            .tracking(-4)
                            .foregroundStyle(Studio.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("MUSIC QUIZ")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(Studio.accent)
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 12) {
                        LandingButton(title: "ひとりで", symbol: "person.fill") { party = .solo }
                        LandingButton(title: "みんなで", symbol: "person.2.fill", disabled: !model.serverConfigured) {
                            party = .together
                        }
                    }
                    .frame(maxWidth: 340)
                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 24)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var selectionFlow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BrandHeader()
                    .padding(.top, 18)
                Button(action: goBack) {
                    Label("戻る", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 8) {
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
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? .none : Studio.spring, value: kind)
            .animation(reduceMotion ? .none : Studio.spring, value: source)
        }
        .scrollDismissesKeyboard(.interactively)
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
                PlayOptionButton(title: "Spotify", subtitle: model.spotifyConfigured ? "自分のプレイリストで遊ぶ" : "Spotify 設定が必要です", symbol: "music.mic", disabled: !model.spotifyConfigured) { source = .spotify }
            } else if party == .solo {
                PlayOptionButton(title: "試聴曲を検索", subtitle: "曲名やアーティストから探す", symbol: "magnifyingglass") { source = .itunes }
                PlayOptionButton(title: "Spotifyプレイリスト", subtitle: model.spotifyConfigured ? "試聴曲と照合して遊ぶ" : "Spotify 設定が必要です", symbol: "music.note.list", disabled: !model.spotifyConfigured) { source = .spotifyPreview }
            } else if kind == .intro {
                PlayOptionButton(title: "共有音源で作る", subtitle: "登録された曲で対戦", symbol: "music.note.list") { selectRoomSource(.shared) }
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
                    PrimaryButton(title: "プレイ開始", symbol: "arrow.right") { model.startSolo() }
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
                        PrimaryButton(title: "プレイ開始", symbol: "arrow.right") { model.startSolo(shared: true) }
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
                            Task { await model.startSabitroSolo() }
                        }
                    } else {
                        PrimaryButton(title: "プレイ開始", symbol: "arrow.right", disabled: !model.spotifyPremium || model.busy) {
                            Task { await model.startSpotifySolo() }
                        }
                        if !model.spotifyPremium {
                            Text("Spotify 音源の再生には Premium が必要です")
                                .font(.caption).foregroundStyle(Studio.secondary)
                        }
                    }
                }
            }
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
                            model.startItunesSolo()
                        }
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
                    Stepper("問題数 \(model.roomSettings.questionCount)", value: $model.roomSettings.questionCount, in: 1...50)
                    Stepper("解答権 \(model.roomSettings.answerSlots)人", value: $model.roomSettings.answerSlots, in: 1...4)
                    DisclosureGroup("ルール詳細") {
                        VStack(spacing: 12) {
                            Stepper("勝利目標 \(model.roomSettings.targetScore)点", value: $model.roomSettings.targetScore, in: 0...500)
                            Stepper("正解 \(model.roomSettings.correctPoints)点", value: $model.roomSettings.correctPoints, in: 1...50)
                            Stepper("1st正解 +\(model.roomSettings.firstBonus)点", value: $model.roomSettings.firstBonus, in: 0...50)
                            Stepper("誤答 −\(model.roomSettings.wrongPenalty)点", value: $model.roomSettings.wrongPenalty, in: 0...50)
                            Stepper("1st誤答 −\(model.roomSettings.firstWrongPenalty)点", value: $model.roomSettings.firstWrongPenalty, in: 0...50)
                            Stepper("ライフ \(model.roomSettings.lives)", value: $model.roomSettings.lives, in: 0...10)
                            Toggle("エンドレス", isOn: $model.roomSettings.endless)
                            Text("0点は勝利目標なし、ライフ0は無制限です。")
                                .font(.caption).foregroundStyle(Studio.secondary)
                        }
                        .padding(.top, 12)
                    }
                    .tint(Studio.accent)
                    PrimaryButton(title: "ルームを作る", symbol: "arrow.right",
                                  disabled: model.busy || (source != .shared && model.spotifySongs.isEmpty) || (source == .spotify && !model.spotifyPremium)) {
                        Task { await model.createRoom() }
                    }
                    if source == .spotify && !model.spotifyPremium {
                        Text("Spotify 対戦には全員の Premium が必要です")
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
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                    .frame(width: 48, height: 48)
                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.title3, design: .rounded, weight: .bold))
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
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
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
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f", remaining))
                    .font(.system(size: 56, weight: .light, design: .rounded))
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
        .accessibilityLabel("残り時間 \(Int(remaining.rounded(.up)))秒")
    }
}

private struct PushButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Studio.line, lineWidth: 1).frame(width: 256, height: 256)
                Circle().strokeBorder(Studio.accent.opacity(0.35), lineWidth: 1).frame(width: 224, height: 224)
                Circle().fill(Studio.accent).frame(width: 190, height: 190)
                VStack(spacing: 1) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 27))
                    Text("PUSH").font(.system(size: 39, weight: .black, design: .rounded)).tracking(-2)
                }
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityLabel("PUSH、解答する")
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
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundStyle(Studio.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 94)
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
        VStack(spacing: 22) {
            Image(systemName: correct ? "checkmark.circle.fill" : "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(correct ? Studio.accent : Studio.warning)
            Text(correct ? "正解！" : "この曲でした")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(Studio.primary)
            Artwork(url: song.artworkURL, size: 190)
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

    var body: some View {
        ZStack {
            Studio.background.ignoresSafeArea()
            if let game = model.game {
                ScrollView {
                    VStack(spacing: 28) {
                        HStack {
                            Button { model.closeGame() } label: {
                                Image(systemName: "xmark").font(.headline).foregroundStyle(Studio.primary)
                                    .frame(width: 44, height: 44).background(Studio.surface, in: Circle())
                            }
                            Spacer()
                            Text(game.stage == .finished ? "RESULT" : "ROUND \(game.index + 1) / \(game.songs.count)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(Studio.secondary)
                        }
                        if game.stage == .listening {
                            Spacer(minLength: 30)
                            WaveMark()
                            Text("耳を澄ませて")
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("曲名が分かったら PUSH")
                                .foregroundStyle(Studio.secondary)
                            CountdownBar(remaining: game.secondsLeft, total: 30)
                            PushButton { model.push() }
                            Button("この曲をスキップ") { model.skip() }
                                .font(.subheadline)
                                .foregroundStyle(Studio.secondary)
                        } else if game.stage == .answering {
                            Spacer(minLength: 26)
                            SectionCaption(title: "SPELL THE TITLE")
                            Text(game.answered + String(repeating: "•", count: max(0, game.answer.count - game.letterIndex)))
                                .font(.system(size: 35, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                                .minimumScaleFactor(0.5)
                                .lineLimit(2)
                                .accessibilityLabel("\(game.letterIndex)文字入力済み、全\(game.answer.count)文字")
                            Text("\(game.letterIndex + 1)文字目を選ぶ")
                                .foregroundStyle(Studio.secondary)
                            CountdownBar(remaining: game.secondsLeft, total: 5)
                            ChoiceGrid(choices: game.choices) { model.choose($0) }
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
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        ForEach(items) { item in
                            StudioCard {
                                HStack(spacing: 13) {
                                    Artwork(url: item.song.artworkURL, size: 66)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.song.title).font(.headline).foregroundStyle(Studio.primary).lineLimit(2)
                                        Text(item.song.artist).font(.caption).foregroundStyle(Studio.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 2)
                                }
                                HStack(spacing: 16) {
                                    Button(learned ? "覚えてないに戻す" : "覚えた") { model.toggleLearned(item.id) }
                                        .foregroundStyle(Studio.accent)
                                    if let url = item.song.trackURL {
                                        Link("曲を開く", destination: url).foregroundStyle(Studio.primary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { model.removeReview(item.id) } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .padding(.top, 12)
                            }
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

struct AccountView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("アカウント")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Studio.primary)
                    StudioCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionCaption(title: "PLAY RECORD")
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
                    StudioCard {
                        VStack(alignment: .leading, spacing: 15) {
                            SectionCaption(title: "RECENT SESSIONS")
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
                    StudioCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionCaption(title: "SETTINGS")
                            field("プレイヤー名", text: $model.nickname, prompt: "プレイヤー")
                            if model.spotifyConnected {
                                Text("接続中: \(model.spotifyAccountName) \(model.spotifyPremium ? "Premium" : "Free")")
                                    .font(.subheadline).foregroundStyle(Studio.accent)
                                HStack {
                                    Button("再連携") { Task { await model.connectSpotify(reconnect: true) } }
                                        .buttonStyle(SecondaryButtonStyle())
                                    Button("解除") { model.disconnectSpotify() }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                                Button("再生先を更新") { Task { await model.loadSpotifyDevices() } }
                                    .buttonStyle(SecondaryButtonStyle())
                                if !model.spotifyDevices.isEmpty {
                                    Picker("Spotify 再生先", selection: Binding(
                                        get: { model.spotify.deviceID ?? "" },
                                        set: { model.spotify.deviceID = $0 })) {
                                        Text("自動選択").tag("")
                                        ForEach(model.spotifyDevices) { device in
                                            Text("\(device.name) · \(device.type)").tag(device.id)
                                        }
                                    }
                                    .tint(Studio.accent)
                                }
                            } else if model.spotifyConfigured {
                                Button("Spotify に接続") { Task { await model.connectSpotify() } }
                                    .buttonStyle(SecondaryButtonStyle())
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
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
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

struct RoomGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Studio.background.ignoresSafeArea()
            if let room = model.room {
                ScrollView {
                    VStack(spacing: 24) {
                        HStack {
                            Button { Task { await model.leaveRoom() } } label: {
                                Image(systemName: "xmark").font(.headline).foregroundStyle(Studio.primary)
                                    .frame(width: 44, height: 44).background(Studio.surface, in: Circle())
                            }
                            Spacer()
                            Text(room.id)
                                .font(.system(size: 17, weight: .bold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(Studio.accent)
                                .textSelection(.enabled)
                        }
                        if room.phase == "lobby" {
                            lobby(room)
                        } else if room.phase == "preparing" {
                            Spacer(minLength: 70)
                            ProgressView().tint(Studio.accent).scaleEffect(1.5)
                            Text("音源を準備中")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("\(room.readyIds.count) / \(room.players.count) 人の準備が完了")
                                .foregroundStyle(Studio.secondary)
                            players(room)
                        } else if room.phase == "countdown" {
                            Spacer(minLength: 70)
                            WaveMark()
                            Text("まもなく開始")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("端末の音量を確認してください")
                                .foregroundStyle(Studio.secondary)
                            players(room)
                        } else if room.phase == "listening" {
                            roundTitle(room)
                            WaveMark()
                            Text("この曲は？")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            CountdownBar(remaining: model.roomSecondsLeft, total: 30)
                            let me = room.player(model.rooms.playerId)
                            if me?.disqualified == true {
                                Text("今回は観戦中です").foregroundStyle(Studio.secondary)
                            } else if room.pushedIds.contains(model.rooms.playerId) {
                                Text("この曲の解答権は使用済みです").foregroundStyle(Studio.secondary)
                            } else {
                                PushButton { Task { await model.roomAction("push") } }
                            }
                            skipButton(room)
                            players(room)
                        } else if room.phase == "answering" {
                            roundTitle(room)
                            if room.answeringPlayerID == model.rooms.playerId {
                                SectionCaption(title: "YOUR TURN")
                                Text(model.roomAnswer + "•••")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundStyle(Studio.primary)
                                CountdownBar(remaining: model.roomSecondsLeft, total: 5)
                                ChoiceGrid(choices: model.roomOptions) { choice in
                                    Task { await model.roomAction("choose", payload: ["choice": choice]) }
                                }
                            } else {
                                Spacer(minLength: 50)
                                WaveMark()
                                Text("\(room.player(room.answeringPlayerID ?? "")?.name ?? "プレイヤー")が解答中")
                                    .font(.title2.bold())
                                    .foregroundStyle(Studio.primary)
                                Text("音を聴きながら待とう")
                                    .foregroundStyle(Studio.secondary)
                            }
                            skipButton(room)
                            players(room)
                        } else if room.phase == "reveal" {
                            if let song = room.current?.song {
                                RevealCard(song: song, correct: room.correctPlayerID == model.rooms.playerId,
                                           saved: model.reviews.contains { $0.id == song.id }) { model.saveReview(song) }
                            }
                            if let winner = room.player(room.correctPlayerID ?? "") {
                                Text("\(winner.name) が正解")
                                    .font(.headline).foregroundStyle(Studio.accent)
                            }
                            players(room)
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
                            players(room, ranked: true)
                            PrimaryButton(title: "ホームへ戻る", symbol: "house") {
                                Task { await model.leaveRoom() }
                            }
                        }
                        if let error = model.roomError {
                            Text(error).font(.caption).foregroundStyle(Studio.warning)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion ? .none : Studio.spring, value: room.phase)
                }
            }
        }
    }

    private func roundTitle(_ room: RoomState) -> some View {
        SectionCaption(title: "ROUND \(room.round + 1) / \(room.totalRounds)")
    }

    private func lobby(_ room: RoomState) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 30)
            WaveMark()
            Text("みんなを待っています")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Studio.primary)
                .multilineTextAlignment(.center)
            Text("ルームIDを友だちに共有してください")
                .foregroundStyle(Studio.secondary)
            ShareLink(item: room.id) {
                Label("\(room.id) を共有", systemImage: "square.and.arrow.up")
                    .font(.subheadline.bold())
                    .foregroundStyle(Studio.accent)
            }
            players(room)
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
                PrimaryButton(title: "ゲームを始める", symbol: "play.fill") {
                    Task { await model.roomAction("start") }
                }
            }
        }
    }

    private func skipButton(_ room: RoomState) -> some View {
        Button(room.skippedIds.contains(model.rooms.playerId) ? "スキップに投票済み" : "スキップに投票") {
            Task { await model.roomAction("skip") }
        }
        .font(.subheadline)
        .foregroundStyle(Studio.secondary)
        .disabled(room.skippedIds.contains(model.rooms.playerId))
    }

    private func players(_ room: RoomState, ranked: Bool = false) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 15) {
                SectionCaption(title: ranked ? "RANKING" : "PLAYERS")
                ForEach(Array((ranked ? room.players.sorted { $0.score > $1.score } : room.players).enumerated()), id: \.element.id) { index, player in
                    HStack(spacing: 12) {
                        Menu {
                            Text(player.badge ?? "称号未設定")
                        } label: {
                            Text(ranked ? "\(index + 1)" : String(player.name.prefix(1)))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.background)
                                .frame(width: 36, height: 36)
                                .background(Studio.accent, in: Circle())
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(player.name).lineLimit(1)
                                if player.isHost { Image(systemName: "crown.fill").font(.caption2).foregroundStyle(Studio.accent) }
                            }
                            .foregroundStyle(Studio.primary)
                            Text(player.disqualified ? "観戦中" : room.settings.lives == 0 ? "ライフ ∞" : "ライフ \(player.lives)")
                                .font(.caption2)
                                .foregroundStyle(Studio.secondary)
                        }
                        Spacer()
                        Text("\(player.score) pt")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Studio.primary)
                    }
                    .opacity(player.connected ? 1 : 0.5)
                }
            }
        }
    }
}
