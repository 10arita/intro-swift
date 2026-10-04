import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct RoomHandicapSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds: [String: Int] = [:]
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let room = model.room {
                        ForEach(room.players) { player in
                            Stepper(value: Binding(
                                get: { seconds[player.id] ?? 0 },
                                set: { seconds[player.id] = $0 }), in: 0...30) {
                                HStack {
                                    Text(player.name).lineLimit(1)
                                    Spacer()
                                    Text("\(seconds[player.id] ?? 0)秒")
                                        .foregroundStyle(Studio.accent)
                                }
                            }
                            .disabled(saving)
                            .accessibilityLabel("\(player.name)のハンデ、\(seconds[player.id] ?? 0)秒")
                        }
                    }
                } header: {
                    Text("プレイヤーごとのハンデ")
                } footer: {
                    Text("各問題の再生開始から設定した秒数、PUSHして解答できません。0秒はハンデなしです。")
                }
            }
            .navigationTitle("ハンデ設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard let room = model.room else { return }
                        let playerIDs = Set(room.players.map(\.id))
                        let values = seconds.filter { playerIDs.contains($0.key) }
                        saving = true
                        Task {
                            let saved = await model.updateRoomHandicaps(values)
                            saving = false
                            if saved { dismiss() }
                            else { errorMessage = model.roomNotice ?? "ハンデを保存できませんでした" }
                        }
                    }
                    .disabled(saving || model.room?.phase != "lobby")
                }
            }
            .alert("ハンデを保存できません", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
            .onAppear { seconds = model.room?.settings.handicaps ?? [:] }
        }
    }
}
