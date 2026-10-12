import SwiftUI
import UIKit

private enum PlayParty: Hashable { case solo, together }
private enum PlayKind: Hashable { case intro, sabitro }
private enum PlayStep: Hashable {
    case home, together, mode(PlayParty), playlist(PlayKind), join
}

func playSharedAxisTransition(forward: Bool, reduceMotion: Bool) -> AnyTransition {
    if reduceMotion { return .opacity }
    return .asymmetric(
        insertion: .offset(x: forward ? 80 : -80).combined(with: .opacity),
        removal: .offset(x: forward ? -80 : 80).combined(with: .opacity))
}

struct PlayView: View {
    let homeToken: Int
    var startsTogether = false
    // Used by the offline UIExamples fixtures.
    var previewStep: String? = nil
    var onContact: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: PlayStep = .home
    @State private var movingForward = true
    @State private var creatingRoom = false

    var body: some View {
        NavigationStack {
            ZStack {
                page
                    .id(step)
                    .transition(playSharedAxisTransition(forward: movingForward, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Studio.background)
            .clipped()
            .toolbar(.hidden, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: step)
            .onChange(of: homeToken) { _, _ in resetToHome() }
            .onAppear {
                if startsTogether { step = .together }
                #if DEBUG
                switch previewStep {
                case let value? where value.hasPrefix("mode"): step = .mode(.solo)
                case let value? where value.hasPrefix("room-selection"): step = .together
                case let value? where value.hasPrefix("code"): step = .join
                case let value? where value.hasPrefix("playlist"): step = .playlist(.intro)
                default: break
                }
                #endif
            }
        }
    }

    @ViewBuilder private var page: some View {
        if step == .home {
            home
        } else {
            VStack(spacing: 0) {
                flowHeader
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(contextTitle)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Studio.secondary)
                                Text(pageTitle)
                                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                    .foregroundStyle(Studio.primary)
                                    .accessibilityAddTraits(.isHeader)
                                Text(pageDescription)
                                    .font(.subheadline)
                                    .foregroundStyle(Studio.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            stepContent
                        }
                        .padding(24)
                        .frame(maxWidth: 600, alignment: .leading)
                        // Center short steps in the available space, including above the keyboard.
                        // Taller content keeps its natural height and remains scrollable.
                        .frame(minHeight: geometry.size.height, alignment: .center)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
    }

    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    HStack {
                        Button(action: onContact) {
                            Image(systemName: "envelope")
                                .font(.title3)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(StudioButtonStyle(.tertiary))
                        .accessibilityLabel("意見・お問い合わせ")
                        .accessibilityHint("匿名で開発者に送るフォームを開きます")
                        .accessibilityIdentifier("feedback-button")
                        Spacer()
                        Text(appVersion)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Studio.secondary)
                            .accessibilityLabel("アプリのバージョン \(appVersion)")
                    }
                    Spacer(minLength: 8)
                    VStack(spacing: 16) {
                        Text("IntoL")
                            .font(.system(size: 88, weight: .black, design: .rounded))
                            .tracking(-5)
                            .foregroundStyle(Studio.primary)
                            .accessibilityAddTraits(.isHeader)
                        HomeWaveform(isActive: model.game == nil && model.room == nil)
                            .frame(maxWidth: 320)
                            .frame(height: 84)
                        Text("シンプルイントロクイズ")
                            .font(.subheadline)
                            .foregroundStyle(Studio.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(spacing: 16) {
                        PlayFlowCard(title: "ひとりで", subtitle: "じっくり腕試し",
                                     symbol: "headphones") {
                            navigate(to: .mode(.solo))
                        }
                        PlayFlowCard(title: "みんなで", subtitle: "友だちと早押し対戦",
                                     symbol: "person.2.fill", badge: "2〜4人", disabled: !model.serverConfigured) {
                            navigate(to: .together)
                        }
                    }
                }
                .padding(24)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var flowHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: goBack) {
                    Label("戻る", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(StudioButtonStyle(.tertiary))
                .foregroundStyle(Studio.primary)
                .disabled(model.busy || creatingRoom)
                Spacer()
                Text("IntoL").font(.title3.bold()).foregroundStyle(Studio.primary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Studio.background)
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .together:
            VStack(spacing: 16) {
                PlayFlowCard(title: "ルームを作る", subtitle: "友だちを招待しよう",
                             symbol: "plus", prominent: true) {
                    navigate(to: .mode(.together))
                }
                PlayFlowCard(title: "コードで参加", subtitle: "6文字のコードで合流",
                             symbol: "ticket.fill", prominent: true) {
                    navigate(to: .join)
                }
            }
        case .mode(let party):
            VStack(spacing: 16) {
                PlayFlowCard(title: "イントロ", subtitle: "曲のはじまりを聴こう",
                             symbol: "play.fill", prominent: true,
                             disabled: model.busy || creatingRoom) {
                    choose(.intro, party: party)
                }
                PlayFlowCard(title: "サビトロ", subtitle: "サビを聴いて当てよう",
                             symbol: "music.note.list", prominent: true,
                             disabled: !model.serverConfigured || model.busy || creatingRoom) {
                    choose(.sabitro, party: party)
                }
                if creatingRoom {
                    ProgressView("ルームを作成しています…")
                        .tint(Studio.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        case .playlist(let kind): SoloPlaylistSelection(kind: kind)
        case .join: RoomCodeEntryView()
        case .home: EmptyView()
        }
    }

    private var contextTitle: String {
        switch step {
        case .mode(.solo): return "ひとりで"
        case .playlist(let kind): return "ひとりで / \(kind == .intro ? "イントロ" : "サビトロ")"
        case .mode(.together): return "みんなで / ルームを作る"
        case .join: return "みんなで / コードで参加"
        default: return "みんなで"
        }
    }

    private var pageTitle: String {
        switch step {
        case .together: return "ルーム選択"
        case .mode: return "モード選択"
        case .playlist: return "プレイリストを選ぼう"
        case .join: return "ルームコードを入力"
        case .home: return ""
        }
    }

    private var pageDescription: String {
        switch step {
        case .together: return "友だちと同じ曲を聴いて、早押し対戦。"
        case .mode(.solo): return "聴きたい部分を選んで、次はプレイリストへ。"
        case .mode(.together): return "モードを選ぶとルームができあがります。\nプレイリストとルールは待機室で設定できます。"
        case .playlist(.intro): return "Apple Music のライブラリから、好きな曲で遊ぼう。"
        case .playlist(.sabitro): return "Apple Music のプレイリストにある曲を、試聴音源と照合します。"
        case .join: return "英字6桁のルームコードを入力してください。"
        case .home: return ""
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        return "v\(version)"
    }

    private func navigate(to destination: PlayStep, forward: Bool = true) {
        movingForward = forward
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.3)) {
            step = destination
        }
    }

    private func choose(_ kind: PlayKind, party: PlayParty) {
        if party == .solo {
            navigate(to: .playlist(kind))
        } else {
            guard !creatingRoom, !model.busy else { return }
            creatingRoom = true
            Task { @MainActor in
                defer { creatingRoom = false }
                await model.createRoom(mode: kind == .intro ? "applemusic" : "sabitro")
            }
        }
    }

    private func goBack() {
        switch step {
        case .together, .mode(.solo): navigate(to: .home, forward: false)
        case .mode(.together), .join: navigate(to: .together, forward: false)
        case .playlist: navigate(to: .mode(.solo), forward: false)
        case .home: break
        }
    }

    private func resetToHome() {
        guard !model.busy, !creatingRoom else { return }
        navigate(to: startsTogether ? .together : .home, forward: false)
    }
}

private struct PlayFlowCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    var badge: String? = nil
    var prominent = false
    var disabled = false
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            icon
                            Spacer()
                            chevron
                        }
                        text
                    }
                } else {
                    HStack(spacing: prominent ? 20 : 16) {
                        icon
                        text
                        chevron
                    }
                }
            }
            .padding(prominent ? 24 : 18)
            .frame(maxWidth: .infinity, minHeight: prominent ? 164 : 126, alignment: .leading)
            .modifier(StudioCardSurface(interactive: true))
            .opacity(disabled ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Studio.Radius.lg))
        }
        .buttonStyle(StudioButtonStyle(.tertiary))
        .disabled(disabled)
        .accessibilityLabel("\(title)、\(subtitle)")
        .accessibilityHint(disabled ? "現在利用できません" : "次のステップへ進む")
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: prominent ? 32 : 26, weight: .semibold))
            .foregroundStyle(Studio.accent)
            .frame(width: prominent ? 64 : 48, height: prominent ? 72 : 56)
            .background(Studio.raised, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let badge {
                Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(Studio.secondary)
            }
            Text(title).font(.system(prominent ? .title2 : .title3, design: .rounded, weight: .bold))
            Text(subtitle).font(.subheadline).foregroundStyle(Studio.secondary)
        }
        .foregroundStyle(Studio.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.subheadline.bold())
            .foregroundStyle(Studio.secondary)
            .accessibilityHidden(true)
    }
}

private struct SoloPlaylistSelection: View {
    let kind: PlayKind
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.appleMusicConnected {
                StudioCard {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 16) {
                            AppleMusicIcon(size: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("あなたの好きな曲で").font(.headline).foregroundStyle(Studio.primary)
                                Text("Apple Music のプレイリストを使います。")
                                    .font(.subheadline).foregroundStyle(Studio.secondary)
                            }
                        }
                        PrimaryButton(title: "Apple Music に接続", symbol: "arrow.right", disabled: model.busy) {
                            Task { await model.connectAppleMusic() }
                        }
                        Text(kind == .intro ? "ライブラリへのアクセスとサブスクリプションが必要です。" : "ライブラリへのアクセスが必要です。")
                            .font(.caption).foregroundStyle(Studio.secondary)
                    }
                    .padding(8)
                }
            } else {
                HStack {
                    AppleMusicIcon(size: 28)
                    Text("マイプレイリスト").font(.headline).foregroundStyle(Studio.primary)
                    Spacer()
                    Button { Task { await model.loadAppleMusicPlaylists() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .foregroundStyle(Studio.accent)
                    .disabled(model.busy)
                    .accessibilityLabel("プレイリストを再読み込み")
                }
                if model.appleMusicPlaylists.isEmpty {
                    StudioCard {
                        Text("プレイリストがありません。Apple Music で作成してから、再読み込みしてください。")
                            .font(.subheadline).foregroundStyle(Studio.secondary)
                    }
                }
                LazyVStack(spacing: 12) {
                    ForEach(model.appleMusicPlaylists) { playlist in
                        SoloPlaylistCard(playlist: playlist,
                                         selected: model.selectedAppleMusicPlaylistID == playlist.id,
                                         disabled: model.busy) {
                            Task { await model.selectAppleMusicPlaylist(playlist.id) }
                        }
                    }
                }
                if !model.appleMusicSongs.isEmpty {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(model.appleMusicSongs.count)曲を読み込みました")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Studio.secondary)
                            ForEach(model.appleMusicSongs.prefix(3)) { SongRow(song: $0) }
                            PrimaryButton(title: "プレイ開始", symbol: "play.fill",
                                          disabled: model.busy || (kind == .intro && !model.appleMusicPlayable)) {
                                Task {
                                    if kind == .intro { await model.startAppleMusicSolo() }
                                    else { await model.startSabitroSolo() }
                                }
                            }
                        }
                    }
                } else if !model.selectedAppleMusicPlaylistID.isEmpty && !model.busy {
                    Text("このプレイリストには利用できる曲がありません。別のプレイリストを選んでください。")
                        .font(.subheadline).foregroundStyle(Studio.secondary)
                }
                if kind == .intro && !model.appleMusicPlayable {
                    Text("曲の再生には Apple Music のサブスクリプションが必要です。")
                        .font(.caption).foregroundStyle(Studio.secondary)
                }
            }
            if model.busy {
                ProgressView(model.preparationStatus ?? "曲を読み込んでいます…")
                    .tint(Studio.accent).frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }
}

private struct SoloPlaylistCard: View {
    let playlist: AppleMusicPlaylist
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Artwork(url: playlist.artworkURL, size: 80)
                            Spacer()
                            selectionIndicator
                        }
                        name
                    }
                } else {
                    HStack(spacing: 20) {
                        Artwork(url: playlist.artworkURL, size: 80)
                        name
                        selectionIndicator
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.md)
                .strokeBorder(selected ? Studio.accent : Studio.line))
        }
        .buttonStyle(StudioButtonStyle(.tertiary))
        .disabled(disabled)
        .accessibilityLabel(playlist.name)
        .accessibilityValue(selected ? "選択中" : "")
    }

    private var name: some View {
        Text(playlist.name)
            .font(.headline).foregroundStyle(Studio.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectionIndicator: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Studio.accent : Studio.line)
            .font(.title3)
            .accessibilityHidden(true)
    }
}

private struct RoomCodeEntryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    @State private var code = ""
    @State private var clipboardHasText = false
    @State private var joining = false
    @State private var submittedCode: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ルームコード").font(.headline).foregroundStyle(Studio.primary)
                ZStack {
                    TextField("", text: Binding(get: { code }, set: updateCode))
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textContentType(.oneTimeCode)
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .focused($focused)
                        .disabled(joining || model.busy)
                        .frame(height: 64)
                        .accessibilityLabel("英字6文字のルームコード")
                        .accessibilityIdentifier("room-code-input")
                        .accessibilityHint("\(code.count) / 6文字。入力が揃うと自動で参加します")
                    RoomCodeBoxes(code: code,
                                  activeIndex: focused ? min(code.count, RoomCode.length - 1) : nil,
                                  hasError: errorMessage != nil)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Text("英字は自動で大文字になります")
                    .font(.caption).foregroundStyle(Studio.secondary)
            }
            if clipboardHasText && !joining {
                Button {
                    guard let text = UIPasteboard.general.string else { return }
                    paste(text)
                } label: {
                    Label("クリップボードから貼付", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Studio.accent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.sm).strokeBorder(Studio.line))
                }
                .buttonStyle(StudioButtonStyle(.tertiary))
                .disabled(model.busy)
            }
            if joining {
                ProgressView("ルームを探しています…")
                    .tint(Studio.accent).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("ルームを探しています")
            }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(Studio.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button("入力し直す") { updateCode(""); focused = true }
                            .frame(minHeight: 44)
                        if RoomCode.isValid(code) {
                            Button("再試行") { submit() }.frame(minHeight: 44)
                        }
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Studio.accent)
                    .disabled(joining || model.busy)
                    if errorMessage.contains("Apple Music"), !model.appleMusicConnected {
                        PrimaryButton(title: "Apple Music に接続", symbol: "arrow.right", disabled: model.busy) {
                            Task { await model.connectAppleMusic() }
                        }
                    }
                }
            }
        }
        .task { focused = true; refreshClipboard() }
        .onChange(of: code) { _, value in
            if RoomCode.isValid(value), submittedCode != value { submit() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshClipboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshClipboard()
        }
    }

    private func refreshClipboard() {
        // Detect availability on entry and foregrounding; read content only on the paste action.
        clipboardHasText = UIPasteboard.general.hasStrings
    }

    private func updateCode(_ value: String) {
        guard !joining else { return }
        if value.count > RoomCode.length {
            paste(value)
            return
        }
        let normalized = RoomCode.normalizedInput(value)
        if normalized != code { submittedCode = nil; errorMessage = nil }
        code = normalized
    }

    private func paste(_ text: String) {
        guard !joining else { return }
        guard let pasted = RoomCode.pastedCode(in: text) else {
            errorMessage = "英字6文字のルームコードが見つかりません。コピーした内容を確認してください。"
            return
        }
        errorMessage = nil
        submittedCode = nil
        if code == pasted { submit() }
        else { code = pasted }
    }

    private func submit() {
        guard RoomCode.isValid(code), !joining, !model.busy else { return }
        submittedCode = code
        joining = true
        errorMessage = nil
        focused = false
        let submitted = code
        Task { @MainActor in
            defer { joining = false }
            errorMessage = await model.joinRoom(submitted, reportErrors: false)
            if errorMessage != nil { focused = true }
        }
    }
}
