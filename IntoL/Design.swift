// Hallmark · native app · studio-dark · acid-lime accent
// Pre-emit critique: philosophy 5, hierarchy 5, execution 4, specificity 5, restraint 4, variety 4.
import SwiftUI
enum Studio {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.075)
    static let surface = Color(red: 0.105, green: 0.118, blue: 0.130)
    static let raised = Color(red: 0.155, green: 0.170, blue: 0.180)
    static let line = Color.white.opacity(0.12)
    static let primary = Color(red: 0.94, green: 0.95, blue: 0.91)
    static let secondary = Color(red: 0.59, green: 0.62, blue: 0.62)
    static let accent = Color(red: 0.84, green: 0.96, blue: 0.45)
    static let warning = Color(red: 0.98, green: 0.55, blue: 0.42)
    static let radius: CGFloat = 24
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.88)
}

struct StudioCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.radius))
            .overlay(RoundedRectangle(cornerRadius: Studio.radius).strokeBorder(Studio.line))
    }
}

struct PrimaryButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Studio.background)
            .padding(.horizontal, 22)
            .frame(height: 60)
            .background(disabled ? Studio.secondary : Studio.accent, in: RoundedRectangle(cornerRadius: 19))
        }
        .disabled(disabled)
        .accessibilityAddTraits(.isButton)
    }
}

struct SectionCaption: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(Studio.secondary)
    }
}

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 72

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                ZStack {
                    Studio.raised
                    Image(systemName: "music.note").foregroundStyle(Studio.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
    }
}
