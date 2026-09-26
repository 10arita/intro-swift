import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var shortcut = PracticeShortcutRoute.shared
    @State private var openingPractice = false

    var body: some View {
        TabView {
            PlayView()
                .tabItem { Label("プレイ", systemImage: "waveform") }
            ReviewView()
                .tabItem { Label("復習", systemImage: "bookmark") }
            AccountView()
                .tabItem { Label("アカウント", systemImage: "person.crop.circle") }
        }
        .tint(Studio.accent)
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
            Text("INTRO QUIZ")
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

struct PlayView: View {
    @EnvironmentObject private var model: AppModel
    @State private var roomCode = ""
    @State private var sampleID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    BrandHeader()
                        .padding(.top, 18)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("曲が流れたら、\n答えは指先で。")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(Studio.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("イントロを聴いて PUSH。曲名を1文字ずつ選ぼう。")
                            .font(.subheadline)
                            .foregroundStyle(Studio.secondary)
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionCaption(title: "QUICK PLAY")
                            Text("オリジナル音源で試す")
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            HStack(spacing: 10) {
                                TextField("デモ曲名を検索", text: $model.searchTerm)
                                    .textInputAutocapitalization(.never)
                                    .submitLabel(.search)
                                    .onSubmit { Task { await model.search() } }
                                    .padding(.horizontal, 15)
                                    .frame(height: 48)
                                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: 13))
                                    .accessibilityLabel("楽曲の検索語")
                                Button { Task { await model.search() } } label: {
                                    Image(systemName: "magnifyingglass")
                                        .font(.headline)
                                        .foregroundStyle(Studio.background)
                                        .frame(width: 48, height: 48)
                                        .background(Studio.accent, in: RoundedRectangle(cornerRadius: 13))
                                }
                                .accessibilityLabel("検索")
                            }
                            if model.busy { ProgressView().tint(Studio.accent) }
                            else if !model.searchSongs.isEmpty {
                                HStack {
                                    Text("\(model.searchSongs.count)曲のデモ音源")
                                        .font(.caption)
                                        .foregroundStyle(Studio.secondary)
                                    Spacer()
                                    Text("ORIGINAL AUDIO")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Studio.accent)
                                }
                                ForEach(model.searchSongs.prefix(3)) { song in
                                    SongRow(song: song)
                                }
                                PrimaryButton(title: "ひとりで練習", symbol: "arrow.up.right", disabled: model.searchSongs.isEmpty) {
                                    model.startSolo()
                                }
                            }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 15) {
                            SectionCaption(title: "YOUR MUSIC")
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("共有音源で練習")
                                        .font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(Studio.primary)
                                    Text("Coolify のサーバーに登録した曲を使います")
                                        .font(.caption)
                                        .foregroundStyle(Studio.secondary)
                                }
                                Spacer()
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(Studio.accent)
                            }
                            if model.serverConfigured {
                                Button("カタログを読む") { Task { await model.loadSharedSongs() } }
                                    .buttonStyle(SecondaryButtonStyle())
                                if !model.sharedSongs.isEmpty {
                                    Text("\(model.sharedSongs.count)曲を利用できます")
                                        .font(.caption).foregroundStyle(Studio.accent)
                                    ForEach(model.sharedSongs.prefix(3)) { song in SongRow(song: song) }
                                    PrimaryButton(title: "共有音源でひとり", symbol: "play.fill") {
                                        model.startSolo(shared: true)
                                    }
                                }
                            } else {
                                Text("共有音源は現在利用できません")
                                    .font(.caption).foregroundStyle(Studio.secondary)
                            }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 15) {
                            SectionCaption(title: "SPOTIFY LIBRARY")
                            Text("自分のプレイリストで練習")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            if model.spotifyConnected {
                                Text(model.spotifyAccountName + (model.spotifyPremium ? " · Premium" : " · Free"))
                                    .font(.caption).foregroundStyle(Studio.accent)
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
                                    if !model.spotifySongs.isEmpty {
                                        Text("\(model.spotifySongs.count)曲を読み込みました")
                                            .font(.caption).foregroundStyle(Studio.secondary)
                                        ForEach(model.spotifySongs.prefix(2)) { song in SongRow(song: song) }
                                        PrimaryButton(title: "Spotify でひとり", symbol: "play.fill",
                                                      disabled: !model.spotifyPremium || model.busy) {
                                            Task { await model.startSpotifySolo() }
                                        }
                                    }
                                }
                            } else if model.spotifyConfigured {
                                Text("アカウントで Spotify を連携してください")
                                    .font(.subheadline).foregroundStyle(Studio.secondary)
                            } else {
                                Text("Spotify 連携は現在利用できません")
                                    .font(.subheadline).foregroundStyle(Studio.secondary)
                            }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 15) {
                            SectionCaption(title: "ITUNES PREVIEW")
                            Text("試聴曲を探す")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            if model.serverConfigured {
                                HStack {
                                    TextField("曲名・アーティスト", text: $model.itunesTerm)
                                        .submitLabel(.search)
                                        .onSubmit { Task { await model.searchItunes() } }
                                        .padding(12)
                                        .background(Studio.raised, in: RoundedRectangle(cornerRadius: 12))
                                    Button("検索") { Task { await model.searchItunes() } }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                                ForEach(model.itunesSongs.prefix(3)) { song in
                                    HStack {
                                        SongRow(song: song)
                                        Button(sampleID == song.id ? "停止" : "試聴") {
                                            if sampleID == song.id { model.player.stop(); sampleID = nil }
                                            else if let url = song.previewURL { model.player.play(url); sampleID = song.id }
                                        }
                                        .font(.caption.bold())
                                        .foregroundStyle(Studio.accent)
                                    }
                                }
                            } else {
                                Text("試聴曲検索は現在利用できません")
                                    .font(.caption).foregroundStyle(Studio.secondary)
                            }
                        }
                    }
                    StudioCard {
                        VStack(alignment: .leading, spacing: 15) {
                            SectionCaption(title: "PLAY TOGETHER")
                            Text("みんなで早押し")
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .foregroundStyle(Studio.primary)
                            Text("最大4人。各自の端末で同じ曲を聴き、最初の PUSH を競います。")
                                .font(.subheadline)
                                .foregroundStyle(Studio.secondary)
                            if model.serverConfigured {
                                Picker("出題音源", selection: $model.roomMode) {
                                    Text("共有音源").tag("shared")
                                    Text("Spotify Premium").tag("spotify")
                                    Text("サビトロ · iTunes").tag("sabitro")
                                }
                                .pickerStyle(.menu)
                                .tint(Studio.accent)
                                Text(model.roomMode == "shared" ? "共有音源カタログから出題" :
                                     model.roomMode == "spotify" ? "全員の Spotify Premium で同じ曲を再生" :
                                     "選択したプレイリストを iTunes の試聴音源に照合")
                                    .font(.caption).foregroundStyle(Studio.accent)
                                HStack {
                                    Stepper("問題数 \(model.roomSettings.questionCount)", value: $model.roomSettings.questionCount, in: 1...50)
                                        .font(.subheadline)
                                }
                                Stepper("解答権 \(model.roomSettings.answerSlots)人", value: $model.roomSettings.answerSlots, in: 1...4)
                                    .font(.subheadline)
                                DisclosureGroup("ルール詳細") {
                                    VStack(spacing: 12) {
                                        Stepper("勝利目標 \(model.roomSettings.targetScore)点", value: $model.roomSettings.targetScore, in: 0...500)
                                        Stepper("正解 \(model.roomSettings.correctPoints)点", value: $model.roomSettings.correctPoints, in: 1...50)
                                        Stepper("1st正解 +\(model.roomSettings.firstBonus)点", value: $model.roomSettings.firstBonus, in: 0...50)
                                        Stepper("誤答 −\(model.roomSettings.wrongPenalty)点", value: $model.roomSettings.wrongPenalty, in: 0...50)
                                        Stepper("1st誤答 −\(model.roomSettings.firstWrongPenalty)点", value: $model.roomSettings.firstWrongPenalty, in: 0...50)
                                        Stepper("ライフ \(model.roomSettings.lives)", value: $model.roomSettings.lives, in: 0...10)
                                        Toggle("エンドレス", isOn: $model.roomSettings.endless)
                                        Text("オンにすると解答中も手元の音源を再生します。")
                                            .font(.caption2).foregroundStyle(Studio.secondary)
                                        Text("0点は勝利目標なし、ライフ0は無制限です。")
                                            .font(.caption2).foregroundStyle(Studio.secondary)
                                    }
                                    .font(.subheadline)
                                    .padding(.top, 12)
                                }
                                .tint(Studio.accent)
                                PrimaryButton(title: "ルームを作る", symbol: "plus") {
                                    Task { await model.createRoom() }
                                }
                                HStack(spacing: 10) {
                                    TextField("6文字のルームID", text: $roomCode)
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                        .padding(.horizontal, 15)
                                        .frame(height: 48)
                                        .background(Studio.raised, in: RoundedRectangle(cornerRadius: 13))
                                    Button("参加") { Task { await model.joinRoom(roomCode) } }
                                        .buttonStyle(SecondaryButtonStyle())
                                        .disabled(roomCode.count != 6)
                                }
                            } else {
                                Text("対戦は現在利用できません")
                                    .font(.caption).foregroundStyle(Studio.secondary)
                            }
                        }
                    }
                    Text("デモ音源は IntoL 制作のオリジナル曲です。共有音源はサーバーのカタログから読み込みます。")
                        .font(.caption2)
                        .foregroundStyle(Studio.secondary)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Studio.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Studio.primary)
            .padding(.horizontal, 15)
            .frame(height: 46)
            .background(Studio.raised, in: RoundedRectangle(cornerRadius: 13))
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
                Circle().fill(Studio.surface).frame(width: 190, height: 190)
                    .overlay(Circle().strokeBorder(Studio.accent, lineWidth: 2))
                VStack(spacing: 1) {
                    Image(systemName: "hand.tap.fill").font(.system(size: 27))
                    Text("PUSH").font(.system(size: 39, weight: .black, design: .rounded)).tracking(-2)
                }
                .foregroundStyle(Studio.accent)
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
