import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

private struct SystemMusicVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        MPVolumeView()
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

struct VolumeSettingsControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            volumeSlider("BGM", value: $model.bgmVolume)
            volumeSlider("効果音", value: $model.effectsVolume)
            volumeSlider("曲の音量", value: $model.songVolume)
            if model.appleMusicConnected {
                Divider()
                Text("Apple Music の曲（端末音量）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Studio.primary)
                SystemMusicVolumeSlider()
                    .frame(height: 30)
                    .accessibilityLabel("端末の音楽音量")
            }
        }
    }

    private func volumeSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Studio.primary)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(Studio.secondary)
            }
            Slider(value: value, in: 0...1)
                .tint(Studio.accent)
                .accessibilityLabel("\(title)の音量")
        }
    }
}

struct GameVolumeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Studio.primary)
                .frame(width: 44, height: 44)
                .background(Studio.surface, in: Circle())
        }
        .accessibilityLabel("音量を調整")
    }
}

struct GameVolumeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                StudioCard { VolumeSettingsControls() }
                    .padding(20)
            }
            .background(Studio.background)
            .navigationTitle("音量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

