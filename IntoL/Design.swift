import SwiftUI
enum Studio {
    static let background = Color("StudioBackground")
    static let surface = Color("StudioSurface")
    static let raised = Color("StudioRaised")
    static let line = Color("StudioLine")
    static let primary = Color("StudioPrimary")
    static let secondary = Color("StudioSecondary")
    static let accent = Color("StudioAccent")
    static let onAccent = Color("StudioOnAccent")
    static let warning = Color("StudioWarning")
    static let success = Color("StudioSuccess")
    static let gold = Color("StudioGold")
    static let silver = Color("StudioSilver")
    static let bronze = Color("StudioBronze")
    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
    }
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.88)
}

struct StudioCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: Studio.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Studio.Radius.md).strokeBorder(Studio.line))
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
        }
        .disabled(disabled)
        .buttonStyle(StudioButtonStyle(.primary))
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
        Group {
            if let image = GameAssets.shared.image(for: url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
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
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Studio.Radius.md))
        .accessibilityHidden(true)
    }
}

/// Shared, interruptible feedback; accessibility settings disable spatial motion.
struct StudioButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, tertiary }
    let role: Role
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(_ role: Role) { self.role = role }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(role == .primary ? .headline : .subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(isEnabled ? (role == .primary ? Studio.onAccent : Studio.accent) : Studio.secondary)
            .padding(.horizontal, role == .primary ? 22 : role == .secondary ? 15 : 0)
            .frame(minHeight: role == .primary ? 52 : 44)
            .background {
                if role != .tertiary {
                    RoundedRectangle(cornerRadius: Studio.Radius.md)
                        .fill(!isEnabled ? Studio.raised : role == .primary ? Studio.accent : Studio.surface)
                }
            }
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: Studio.Radius.md).strokeBorder(Studio.line)
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(!isEnabled ? 0.65 : configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct AppleMusicIcon: View {
    var size: CGFloat = 36
    var body: some View {
        Image("AppleMusicIcon")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct RoomCodeBoxes: View {
    let code: String
    var activeIndex: Int? = nil
    var hasError = false
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<RoomCode.length, id: \.self) { index in
                let characters = Array(code)
                let active = index == activeIndex
                Text(index < characters.count ? String(characters[index]) : "")
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(Studio.primary)
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .background(index < characters.count ? Studio.raised : Studio.surface,
                                in: RoundedRectangle(cornerRadius: Studio.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Studio.Radius.sm)
                        .strokeBorder(hasError ? Studio.warning : active ? Studio.accent : Studio.line,
                                      lineWidth: active || hasError ? 2 : 1))
            }
        }
    }
}
