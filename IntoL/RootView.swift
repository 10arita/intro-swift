import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit
import AVFoundation

private enum MainTab: Hashable { case play, review, friends, account }

struct RootView: View {
    var previewStep: String? = nil
    @StateObject private var feedback: FeedbackReportModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shortcut = PracticeShortcutRoute.shared
    @State private var openingPractice = false
    @State private var selectedTab: MainTab = .play
    @State private var playHomeToken = 0
    @State private var startsTogether = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(previewStep: String? = nil,
         feedbackReportSender: @escaping (FeedbackReport, String) async throws -> Void = { report, url in
             try await FeedbackReportService().send(report, serverURL: url)
         }) {
        self.previewStep = previewStep
        _feedback = StateObject(wrappedValue: FeedbackReportModel(sender: feedbackReportSender))
    }

    var body: some View {
        ZStack {
            mainTabs
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
        .modifier(FeedbackReportPresentation(feedback: feedback))
        .alert("IntoL", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task {
            guard previewStep == nil else { return }
            model.setAppActive(scenePhase == .active)
            Task { await model.restoreRoom() }
            if model.searchSongs.isEmpty { await model.search() }
            await openRequestedPractice()
            if model.appleMusicConnected { await model.loadAppleMusicPlaylists() }
            await model.syncProfile()
            await model.refreshFriends(reportErrors: false)
        }
        .task(id: scenePhase) {
            guard previewStep == nil, scenePhase == .active, model.serverConfigured else { return }
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
            guard previewStep == nil else { return }
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
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               type == AVAudioSession.InterruptionType.began.rawValue {
                model.invalidateRankRound("音声の割り込みが発生しました。")
            }
        }
        .onAppear {
            #if DEBUG
            if previewStep?.hasPrefix("friends") == true { selectedTab = .friends }
            if previewStep?.hasPrefix("account") == true { selectedTab = .account }
            #endif
        }
    }

    private var showingSession: Bool { model.room != nil || model.game != nil }

    private var mainTabs: some View {
        // Standard tab bars adopt Liquid Glass on iOS 26 and retain the system
        // appearance on earlier versions, including accessibility adaptations.
        TabView(selection: tabSelection) {
            PlayView(homeToken: playHomeToken, startsTogether: startsTogether, previewStep: previewStep,
                     onContact: feedback.present)
                .tabItem { Label("プレイ", systemImage: "waveform") }
                .tag(MainTab.play)

            ReviewView()
                .tabItem { Label("復習", systemImage: "bookmark") }
                .tag(MainTab.review)

            FriendsView(onCreateRoom: {
                startsTogether = true
                playHomeToken += 1
                selectedTab = .play
            }, automaticallyRefresh: previewStep == nil)
                .tabItem { Label("フレンド", systemImage: "person.2") }
                .badge(inviteCount)
                .tag(MainTab.friends)

            AccountView()
                .tabItem { Label("アカウント", systemImage: "person.crop.circle") }
                .tag(MainTab.account)
        }
        .tint(Studio.accent)
    }

    private var inviteCount: Int {
        (model.friendsState?.invites.count ?? 0) + (model.friendsState?.requests.count ?? 0)
    }

    private var tabSelection: Binding<MainTab> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == .play {
                startsTogether = false
                playHomeToken += 1
            }
            selectedTab = tab
        })
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

