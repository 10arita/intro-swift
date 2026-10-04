import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct PlayerProfileTarget: Identifiable {
    let id: String
    let name: String
    let roomID: String?
}

struct PlayerProfileSheet: View {
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
                                                .buttonStyle(StudioButtonStyle(.secondary))
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
                                                .buttonStyle(StudioButtonStyle(.secondary))
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
                    .buttonStyle(StudioButtonStyle(.tertiary))
                    .accessibilityLabel("\(friend.name)のプロフィールを見る")
                    if model.room?.phase == "lobby" {
                        if model.room?.players.contains(where: { $0.friendProfileId == friend.id }) == true {
                            Text("参加中").font(.caption).foregroundStyle(Studio.secondary)
                        } else {
                            let invited = model.hasInvitedFriend(friend.id)
                            Button(invited ? "招待済み" : "招待") { Task { await model.inviteFriend(friend.id) } }
                                .buttonStyle(StudioButtonStyle(.secondary))
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
        .background(Studio.raised, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        .task { withAnimation(reduceMotion ? nil : Studio.spring) { appeared = true } }
    }
}

