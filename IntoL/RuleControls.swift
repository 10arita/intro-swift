import SwiftUI
import PhotosUI
import MediaPlayer
import CloudKit

struct RuleDialRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var prefix = ""
    var suffix = ""
    var disabled = false
    @State private var showingDial = false

    var body: some View {
        Button { showingDial = true } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(Studio.primary)
                Spacer(minLength: 8)
                Text(displayValue(value))
                    .monospacedDigit()
                    .foregroundStyle(Studio.accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(Studio.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(displayValue(value))
        .accessibilityHint("ダイヤルで変更")
        .sheet(isPresented: $showingDial) {
            NavigationStack {
                Picker(title, selection: $value) {
                    ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: step)), id: \.self) { option in
                        Text(displayValue(option)).tag(option)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(height: 190)
                .frame(maxHeight: .infinity)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完了") { showingDial = false }
                    }
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func displayValue(_ number: Int) -> String { "\(prefix)\(number)\(suffix)" }
}

struct LandingButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: disabled ? "lock.fill" : symbol)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(disabled ? Studio.secondary : Studio.accent)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
        .disabled(disabled)
        .accessibilityHint(disabled ? "サーバー設定が必要です" : "")
    }
}
