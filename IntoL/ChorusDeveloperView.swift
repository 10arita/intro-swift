#if DEBUG
import SwiftUI
import MusicKit
import UniformTypeIdentifiers

struct ChorusDeveloperView: View {
    let allowsDismissal: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tool: ChorusDeveloperModel
    @State private var importing = false
    @State private var choosingSource = false
    @State private var songFilter = ""
    @State private var scrubPosition: Double?

    init(preview: Bool = false, allowsDismissal: Bool = true) {
        self.allowsDismissal = allowsDismissal
        _tool = State(initialValue: ChorusDeveloperModel(preview: preview))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    connectionSection
                    if let error = tool.errorMessage {
                        Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    }
                    if let status = tool.statusMessage {
                        Section { Text(status).font(.subheadline).accessibilityIdentifier("chorus-status") }
                    }
                    if tool.displaySong != nil { playerSection.id("chorus-player"); markerSection }
                    exportSection
                    sourceSection
                    if tool.isConnected { catalogSection; songsSection.id("chorus-candidates") }
                }
                .onChange(of: tool.selectedSong?.id) { _, id in
                    scrubPosition = nil
                    if id != nil { proxy.scrollTo("chorus-player", anchor: .top) }
                }
                .onChange(of: tool.songs.map(\.id)) { _, songs in
                    if tool.selectedSource != nil, tool.selectedSong == nil, !songs.isEmpty {
                        proxy.scrollTo("chorus-candidates", anchor: .top)
                    }
                }
            }
            .navigationTitle("サビ位置登録")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: tool.searchTerm) { _, _ in songFilter = "" }
            .toolbar {
                if allowsDismissal {
                    ToolbarItem(placement: .confirmationAction) { Button("閉じる") { tool.stop(); dismiss() } }
                }
            }
            .overlay { if tool.isBusy { ProgressView().padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .sheet(isPresented: $choosingSource) { ChorusSourcePicker(tool: tool) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .tabSeparatedText], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { tool.importFile(url) }
                case .failure(let error): tool.errorMessage = error.localizedDescription
                }
            }
            .task {
                tool.loadSavedWork()
                while !Task.isCancelled {
                    if scenePhase == .active { tool.refreshPlayback() }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                }
            }
            .onDisappear { tool.stop() }
        }
    }

    private var connectionSection: some View {
        Section {
            Text("Apple Musicを聴きながらサビの開始時刻を登録します。提出ごとにXLSXを自動更新します。")
                .font(.subheadline)
            Button(tool.isConnected ? "Apple Musicの接続・プレイリストを更新" : "Apple Musicに接続") { Task { await tool.connect() } }
                .disabled(tool.isBusy || tool.isPreview)
                .accessibilityIdentifier("chorus-connect")
            if tool.isPreview { Text("画面確認用です。再生・保存は行いません。").font(.caption) }
        } header: { Text("開発者用・Debug限定") }
    }

    private var playerSection: some View {
        Section("再生中の曲") {
            if let song = tool.displaySong {
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.headline)
                    Text(song.artistName)
                    Text(song.albumTitle ?? "アルバム情報なし").font(.caption).foregroundStyle(.secondary)
                    Text("ID: \(String(describing: song.id))").font(.caption2).textSelection(.enabled)
                    if let saved = tool.selectedAnnotation {
                        ChorusSubmittedLabel()
                            .accessibilityIdentifier("chorus-current-submitted")
                        Text("保存済みのサビ：\(Self.time(Double(saved.chorusStartMS) / 1000, precision: true))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let source = tool.selectedSource {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TXT：\(source.title) / \(source.artist)").font(.caption)
                        Text("\(source.album) ・ \(source.durationSeconds.map { Self.time(Double($0)) } ?? "曲長不明")").font(.caption)
                        Text("アルバムやライブ版など、同じ録音か確認してください。").font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Text(Self.time(scrubPosition ?? tool.positionSeconds)).monospacedDigit()
                        .accessibilityIdentifier("chorus-playback-time")
                    Spacer()
                    Text(Self.time(tool.durationSeconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { scrubPosition ?? tool.positionSeconds }, set: { scrubPosition = $0 }), in: 0...max(1, tool.durationSeconds), onEditingChanged: { editing in
                    if !editing, let target = scrubPosition { tool.seek(to: target); scrubPosition = nil }
                })
                .disabled(!tool.ownsPlayback || tool.isBusy)
                .accessibilityLabel("再生位置")
                HStack {
                    seekButton(-5); seekButton(-1)
                    Button { Task { await tool.togglePlayback() } } label: {
                        Image(systemName: tool.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(tool.isPlaying ? "一時停止" : "再生")
                    .disabled(!tool.ownsPlayback || tool.isBusy)
                    seekButton(1); seekButton(5)
                }
                .buttonStyle(.bordered)
                Button("45秒付近へ移動") { tool.seek(to: min(45, max(0, tool.durationSeconds - 5))) }
                    .disabled(!tool.ownsPlayback || tool.isBusy)
                Button("現在位置をサビにする") { tool.capture() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tool.canCapture)
                    .accessibilityIdentifier("chorus-capture")
            }
        }
    }

    private func seekButton(_ seconds: Int) -> some View {
        Button(seconds > 0 ? "+\(seconds)" : "\(seconds)") { tool.seek(to: tool.positionSeconds + Double(seconds)) }
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!tool.ownsPlayback || tool.isBusy)
            .accessibilityLabel(seconds > 0 ? "\(seconds)秒進む" : "\(-seconds)秒戻る")
    }

    private var markerSection: some View {
        Section("サビ開始位置") {
            if let start = tool.chorusStartMS {
                Text(Self.time(Double(start) / 1000, precision: true))
                    .font(.title2.bold().monospacedDigit()).accessibilityIdentifier("chorus-marker")
                HStack {
                    markerButton(-1000, "−1秒"); markerButton(-100, "−0.1")
                    markerButton(100, "+0.1"); markerButton(1000, "+1秒")
                }
                .buttonStyle(.bordered)
                Button("1.5秒前から確認再生") { Task { await tool.previewMarker() } }
                    .disabled(!tool.ownsPlayback || tool.isBusy)
                Toggle("この録音版とサビ開始を聴いて確認した", isOn: $tool.recordingConfirmed)
                    .disabled(tool.isBusy || !tool.ownsPlayback)
                    .accessibilityIdentifier("chorus-confirm")
            } else { Text("再生位置をサビにすると、ここで微調整できます。").foregroundStyle(.secondary) }
            TextField("メモ（録音版や境界の補足）", text: $tool.notes, axis: .vertical)
            if tool.hasNextTrackContext {
                Button("提出して次の未提出曲へ") { Task { await tool.submitAndAdvance() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tool.canSubmit)
                    .accessibilityIdentifier("chorus-submit-next")
                Button("提出してこの曲に留まる") { tool.submit() }
                    .disabled(!tool.canSubmit)
                    .accessibilityIdentifier("chorus-submit")
            } else {
                Button("提出してXLSXを更新") { tool.submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!tool.canSubmit)
                    .accessibilityIdentifier("chorus-submit")
            }
            Text("サビの実時刻を保存します。1.5秒の前倒しは保存値には含めません。").font(.caption).foregroundStyle(.secondary)
            if tool.hasNextTrackContext {
                Button("次の未提出曲へ") { Task { await tool.nextTrack() } }
                    .disabled(tool.isBusy || tool.isPreview)
                    .accessibilityIdentifier("chorus-next")
            }
        }
    }

    private func markerButton(_ delta: Int, _ title: String) -> some View {
        Button(title) { tool.adjustMarker(delta) }.disabled(tool.isBusy || !tool.ownsPlayback)
    }

    private var exportSection: some View {
        Section("保存・書き出し") {
            LabeledContent("提出済み", value: "\(tool.records.count)曲")
            if let url = tool.exportURL {
                ShareLink(item: url) { Label("最新のXLSXを共有・ファイルに保存", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("chorus-share")
            }
            Button("XLSXを再生成") { tool.rebuildWorkbook() }.disabled(!tool.canWrite || tool.isBusy)
            Text("提出内容は端末に残ります。アプリを閉じても再開できます。共有からMacへのAirDropやファイル保存ができます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourceSection: some View {
        Section("IntoL.txtから作業") {
            Button("Apple Musicの書き出しTXTを取り込む") { importing = true }
                .disabled(!tool.canWrite || tool.isBusy)
                .accessibilityIdentifier("chorus-import")
            if !tool.importedSongs.isEmpty {
                LabeledContent("取り込み済み", value: "\(tool.importedSongs.count)曲")
                Button("TXTの曲を選ぶ") { choosingSource = true }.disabled(tool.isBusy)
                if let source = tool.selectedSource {
                    Text("対象：\(source.title) / \(source.artist)").font(.caption)
                    if tool.sourceIsSubmitted(source) { ChorusSubmittedLabel() }
                }
                Button("次の未提出曲を検索") { Task { await tool.nextSource() } }.disabled(tool.isBusy)
            }
        }
    }

    private var catalogSection: some View {
        Section("Apple Musicから選ぶ") {
            Picker("プレイリスト", selection: $tool.selectedPlaylistID) {
                Text("選択してください").tag("")
                ForEach(tool.playlists) { playlist in Text(playlist.name).tag(String(describing: playlist.id)) }
            }.disabled(tool.isBusy)
                .onChange(of: tool.selectedPlaylistID) { _, id in
                    songFilter = ""
                    Task { await tool.loadPlaylist(id) }
                }
            TextField("曲名とアーティストで検索", text: $tool.searchTerm).submitLabel(.search)
                .onSubmit { Task { await tool.search() } }
            Button("候補を検索") { Task { await tool.search() } }.disabled(tool.isBusy || tool.searchTerm.isEmpty)
        }
    }

    private var songsSection: some View {
        Section("曲・検索候補（\(tool.songs.count)曲）") {
            TextField("候補を絞り込む", text: $songFilter)
            ForEach(tool.songs.filter { songFilter.isEmpty || "\($0.title) \($0.artistName)".localizedCaseInsensitiveContains(songFilter) }) { song in
                Button { Task { await tool.select(song) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).foregroundStyle(.primary)
                            Text(song.artistName).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(song.albumTitle ?? "") ・ \(Self.time(song.duration ?? 0))").font(.caption).foregroundStyle(.secondary)
                            if tool.annotation(for: song) != nil { ChorusSubmittedLabel() }
                        }
                        Spacer()
                        Image(systemName: tool.selectedSong?.id == song.id ? "speaker.wave.2.fill" : "play.circle")
                    }
                }.disabled(tool.isBusy)
            }
        }
    }

    private static func time(_ seconds: Double, precision: Bool = false) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        return String(format: precision ? "%d:%06.3f" : "%d:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
    }
}

private struct ChorusSourcePicker: View {
    let tool: ChorusDeveloperModel
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var onlyPending = true

    var body: some View {
        NavigationStack {
            List {
                Toggle("未提出だけ表示", isOn: $onlyPending)
                ForEach(tool.importedSongs.filter { song in
                    (!onlyPending || !tool.sourceIsSubmitted(song)) &&
                    (filter.isEmpty || "\(song.title) \(song.artist)".localizedCaseInsensitiveContains(filter))
                }) { song in
                    Button {
                        dismiss()
                        Task { await tool.chooseSource(song) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(song.title); Text(song.artist).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if tool.sourceIsSubmitted(song) { ChorusSubmittedLabel() }
                        }
                    }
                }
            }
            .searchable(text: $filter, prompt: "名前・アーティスト")
            .navigationTitle("TXTの曲を選ぶ")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

private struct ChorusSubmittedLabel: View {
    var body: some View {
        Label("提出済み", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
    }
}

#Preview { ChorusDeveloperView(preview: true) }
#endif
