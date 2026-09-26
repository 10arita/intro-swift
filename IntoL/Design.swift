import SwiftUI
enum Studio {
    static let background = Color(red: 0.99, green: 0.98, blue: 0.98)
    static let surface = Color.white
    static let raised = Color(red: 0.97, green: 0.94, blue: 0.94)
    static let line = Color(red: 0.90, green: 0.85, blue: 0.85)
    static let primary = Color(red: 0.16, green: 0.12, blue: 0.12)
    static let secondary = Color(red: 0.39, green: 0.34, blue: 0.34)
    static let accent = Color(red: 0.73, green: 0.08, blue: 0.13)
    static let warning = Color(red: 0.62, green: 0.08, blue: 0.12)
    static let radius: CGFloat = 20
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
                Text(title).font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(disabled ? Studio.secondary : .white)
            .padding(.horizontal, 22)
            .frame(minHeight: 60)
            .background(disabled ? Studio.raised : Studio.accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(disabled)
        .buttonStyle(.plain)
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
