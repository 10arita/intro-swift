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
            .onAppear { if startsTogether { step = .together } }
        }
    }

    @ViewBuilder private var page: some View {
        if step == .home {
            home
        } else {
            VStack(spacing: 0) {
                flowHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(contextTitle)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Studio.accent)
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
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    Text(appVersion)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Studio.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("アプリのバージョン \(appVersion)")
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
                        PlayFlowCard(title: "ひとりで", subtitle: "好きなプレイリストで、じっくり腕試し。",
                                     symbol: "headphones", badge: "SOLO", emphasized: true) {
                            navigate(to: .mode(.solo))
                        }
                        PlayFlowCard(title: "みんなで", subtitle: "ルームを作って、友だちと早押し対戦。",
                                     symbol: "person.2.fill", badge: "2–4 PLAYERS", disabled: !model.serverConfigured) {
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
                .foregroundStyle(Studio.accent)
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
                PlayFlowCard(title: "ルームを作る", subtitle: "モードを選んで、みんなを招待。",
                             symbol: "plus", badge: "HOST", emphasized: true) {
                    navigate(to: .mode(.together))
                }
                PlayFlowCard(title: "コードで参加", subtitle: "届いた6文字のコードで合流。",
                             symbol: "ticket.fill", badge: "JOIN") {
                    navigate(to: .join)
                }
            }
        case .mode(let party):
            VStack(spacing: 16) {
                PlayFlowCard(title: "イントロ", subtitle: "曲のはじまりで、曲名を当てよう。",
                             symbol: "play.fill", badge: "INTRO", emphasized: true,
                             disabled: model.busy || creatingRoom) {
                    choose(.intro, party: party)
                }
                PlayFlowCard(title: "サビトロ", subtitle: "おなじみのサビから、早押しクイズ。",
                             symbol: "waveform", badge: "SABITRO",
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
    let badge: String
    var emphasized = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(emphasized && !disabled ? Studio.onAccent : Studio.accent)
                .frame(width: 64, height: 64)
                .background(emphasized && !disabled ? Studio.onAccent.opacity(0.12) : Studio.raised,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.md))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(badge).font(.caption2.weight(.bold)).tracking(1.4)
                    Text(title).font(.system(.title3, design: .rounded, weight: .bold))
                    Text(subtitle)
                        .font(.subheadline)
                        .opacity(emphasized && !disabled ? 0.9 : 1)
                }
                .foregroundStyle(emphasized && !disabled ? Studio.onAccent : Studio.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(emphasized && !disabled ? Studio.onAccent : Studio.accent)
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
            .background(emphasized && !disabled ? Studio.accent : Studio.surface,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.lg).strokeBorder(emphasized && !disabled ? .clear : Studio.line))
            .opacity(disabled ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Studio.Radius.lg))
        }
        .buttonStyle(StudioButtonStyle(.tertiary))
        .disabled(disabled)
        .accessibilityLabel("\(title)、\(subtitle)")
        .accessibilityHint(disabled ? "現在利用できません" : "次のステップへ進む")
    }
}

private struct SoloPlaylistSelection: View {
    let kind: PlayKind
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !model.appleMusicConnected {
                StudioCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            AppleMusicIcon(size: 48)
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
                        Button {
                            Task { await model.selectAppleMusicPlaylist(playlist.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "music.note.list")
                                    .font(.title2).foregroundStyle(Studio.accent)
                                    .frame(width: 56, height: 64)
                                    .background(Studio.raised, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
                                Text(playlist.name)
                                    .font(.headline).foregroundStyle(Studio.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: model.selectedAppleMusicPlaylistID == playlist.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedAppleMusicPlaylistID == playlist.id ? Studio.accent : Studio.line)
                                    .font(.title3)
                            }
                            .padding(16)
                            .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
                            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.md)
                                .strokeBorder(model.selectedAppleMusicPlaylistID == playlist.id ? Studio.accent : Studio.line))
                        }
                        .buttonStyle(StudioButtonStyle(.tertiary))
                        .disabled(model.busy)
                        .accessibilityLabel(playlist.name)
                        .accessibilityValue(model.selectedAppleMusicPlaylistID == playlist.id ? "選択中" : "")
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
