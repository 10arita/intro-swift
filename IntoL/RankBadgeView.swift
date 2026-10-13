import SwiftUI

/// Vector artwork shared by personal and public profiles; no image download is needed.
struct RankBadgeView: View {
    let level: Int
    @ScaledMetric(relativeTo: .headline) private var diameter: CGFloat = 32

    init(level: Int, size: CGFloat = 32) {
        self.level = level
        _diameter = ScaledMetric(wrappedValue: size, relativeTo: .headline)
    }

    private var palette: String {
        switch level {
        case 1...2: return "Bronze"
        case 3...4: return "Blue"
        case 5...6: return "Violet"
        case 7...8: return "Gold"
        case 9...10: return "Champion"
        default: return "Neutral"
        }
    }

    var body: some View {
        if IntroRank.names.indices.contains(level) {
            let ink = Color("RankBadge\(palette)Ink")
            let name = IntroRank.name(level)
            Text(name)
                .font(.system(size: diameter * (name.count == 1 ? 0.55 : 0.44),
                              weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
                .frame(width: diameter, height: diameter)
                .background(Color("RankBadge\(palette)Surface"), in: Circle())
                .overlay(Circle().strokeBorder(ink, lineWidth: diameter * 0.047))
                .overlay {
                    if level == 10 {
                        Circle().inset(by: diameter * 0.095)
                            .stroke(ink, lineWidth: diameter * 0.025)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel("ランク測定の最高記録、\(name)相当")
                .accessibilityIdentifier("highest-rank-badge")
        }
    }
}

/// Preserve the full name and badge when the horizontal arrangement no longer fits.
struct RankedProfileLabel<Name: View>: View {
    let level: Int?
    let alwaysStack: Bool
    private let name: Name

    init(level: Int?, alwaysStack: Bool = false, @ViewBuilder name: () -> Name) {
        self.level = level
        self.alwaysStack = alwaysStack
        self.name = name()
    }

    var body: some View {
        if let level, IntroRank.names.indices.contains(level) {
            if alwaysStack {
                stacked(level: level)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        name.fixedSize(horizontal: true, vertical: true)
                        RankBadgeView(level: level)
                    }
                    stacked(level: level)
                }
            }
        } else {
            name
        }
    }

    private func stacked(level: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            name.fixedSize(horizontal: false, vertical: true)
            RankBadgeView(level: level)
        }
    }
}

#if DEBUG
struct RankBadgeGalleryView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], spacing: 22) {
                    ForEach(IntroRank.names.indices, id: \.self) { level in
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                RankBadgeView(level: level, size: 64)
                                RankBadgeView(level: level)
                            }
                            Text(IntroRank.name(level))
                                .font(.caption).foregroundStyle(Studio.primary)
                        }
                    }
                }
                .padding(20)
            }
            .background(Studio.background)
            .navigationTitle("ランクバッジ")
        }
    }
}

#Preview("ランクバッジ") {
    RankBadgeGalleryView()
}
#endif
