import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

private enum MainTab { case play, review, friends, account }

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
                                .foregroundStyle(Studio.onAccent)
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

