import SwiftUI

struct AppInformationView: View {
    @ScaledMetric(relativeTo: .subheadline) private var linkIconWidth: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if AppConfiguration.supportURL != nil || AppConfiguration.supportFormURL != nil || supportEmailURL != nil {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionCaption(title: "サポート")
                            if let url = AppConfiguration.supportURL {
                                externalLink("サポートページ", symbol: "questionmark.circle", destination: url)
                                    .accessibilityIdentifier("app-information-support")
                            }
                            if let url = AppConfiguration.supportFormURL {
                                externalLink("お問い合わせフォーム", symbol: "envelope", destination: url)
                                    .accessibilityIdentifier("app-information-contact")
                            }
                            if let url = supportEmailURL {
                                externalLink(AppConfiguration.supportEmail, symbol: "envelope", destination: url)
                            }
                        }
                    }
                }
                if AppConfiguration.privacyPolicyURL != nil || AppConfiguration.termsURL != nil {
                    StudioCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionCaption(title: "ポリシー")
                            if let url = AppConfiguration.privacyPolicyURL {
                                externalLink("プライバシーポリシー", symbol: "hand.raised", destination: url)
                            }
                            if let url = AppConfiguration.termsURL {
                                externalLink("利用規約", symbol: "doc.text", destination: url)
                            }
                        }
                    }
                }
                StudioCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCaption(title: "クレジット")
                        if !AppConfiguration.operatorName.isEmpty { Text("運営者：\(AppConfiguration.operatorName)") }
                        Text(soundCredit)
                            .tint(Studio.accent)
                            .frame(minHeight: 44, alignment: .leading)
                        Text("Apple MusicはApple Inc.の商標です。IntoLはApple Inc.が提供・推奨するアプリではありません。")
                            .font(.footnote).foregroundStyle(Studio.secondary)
                    }
                }
            }
            .foregroundStyle(Studio.primary)
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Studio.background)
        .navigationTitle("このアプリについて")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var soundCredit: AttributedString {
        var provider = AttributedString("OtoLogic")
        provider.link = URL(string: "https://otologic.jp/")
        provider.underlineStyle = .single
        return AttributedString("効果音の一部：") + provider
    }

    private var supportEmailURL: URL? {
        guard !AppConfiguration.supportEmail.isEmpty else { return nil }
        return URL(string: "mailto:\(AppConfiguration.supportEmail)")
    }

    private func externalLink(_ title: String, symbol: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(Studio.accent)
                    .frame(width: linkIconWidth)
                    .accessibilityHidden(true)
                Text(title)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(Studio.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(StudioButtonStyle(.secondary))
        .accessibilityHint(destination.scheme == "mailto" ? "メールアプリを開きます" : "外部ページを開きます")
    }
}
