import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showRecords = false
    @State private var showConnectionBenefits = false
    @State private var showAvatarSettings = false
    @State private var editingName = false
    @State private var draftName = ""
    #if DEBUG
    @State private var showChorusTool = false
    #endif
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
                    RankRecordSummary(records: model.rankRecords, catalogVersion: RankCatalog.bundledVersion)
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
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--show-developer-tools") {
                        StudioCard {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionCaption(title: "開発者ツール")
                                Button { showChorusTool = true } label: {
                                    Label("Apple Musicのサビ位置を登録", systemImage: "waveform.badge.plus")
                                }
                                .buttonStyle(StudioButtonStyle(.secondary))
                                .accessibilityIdentifier("open-chorus-tool")
                            }
                        }
                    }
                    #endif
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
        #if DEBUG
        .sheet(isPresented: $showChorusTool) { ChorusDeveloperView() }
        #endif
    }

    private var profileHeader: some View {
        HStack(spacing: 16) {
            Button { showAvatarSettings = true } label: {
                PlayerAvatarView(data: model.avatarData, size: 64)
                    .overlay(Circle().strokeBorder(Studio.line))
            }
            .buttonStyle(StudioButtonStyle(.tertiary))
            .accessibilityLabel("アイコンを設定")

            RankedProfileLabel(level: model.rankRecords.highestRankLevel, alwaysStack: editingName) {
                profileName
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }

    private var profileName: some View {
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
                    HStack(spacing: 8) {
                        Text(model.nickname).font(.title3.bold())
                            .foregroundStyle(Studio.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Studio.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioButtonStyle(.tertiary))
                .accessibilityLabel("\(model.nickname)、プレイヤー名を編集")
            }
        }
        .foregroundStyle(Studio.primary)
        .padding(.horizontal, 12)
        .background(editingName ? Studio.surface : .clear, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Studio.Radius.sm)
                .stroke(Studio.accent.opacity(0.6), lineWidth: 2)
                .padding(nameFocused ? -5 : 0)
                .opacity(nameFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : Studio.spring, value: nameFocused)
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
                    connectionRow("Apple Music", badge: model.appleMusicConnected ? "接続済み" : "接続する",
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
            .buttonStyle(StudioButtonStyle(.tertiary))
            .modifier(StudioCardSurface())

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
        guard AppConfiguration.cloudKitEnabled else { return "未接続" }
        let status = model.profileSyncStatus ?? ""
        if status.contains("接続されていません") { return "未接続" }
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
                .foregroundStyle(active ? Studio.success : Studio.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((active ? Studio.success : Studio.warning).opacity(0.1), in: Capsule())
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
                        .foregroundStyle(Studio.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Studio.accent, in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
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

