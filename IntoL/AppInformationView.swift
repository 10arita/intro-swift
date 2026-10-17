import SwiftUI

struct AppInformationView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StudioCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCaption(title: "音楽に親しむために")
                        Text("IntoLは、曲との出会いや復習を通じて、音楽をもっと身近に感じるためのアプリです。")
                        Text("Apple Musicの再生にはアクセス許可と有効なサブスクリプションが必要です。対戦では参加者それぞれに必要です。Apple Musicの料金と通信料は別途かかります。")
                            .foregroundStyle(Studio.secondary)
                    }
                }
                StudioCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionCaption(title: "データの取り扱い")
                        information("端末とiCloud", "名前・アイコン・復習・履歴・成績・音量設定を端末に保存します。iCloud同期を利用する場合は、同じApple AccountのCloudKit Private Databaseにも保存します。")
                        information("対戦とフレンド", "プロフィールの識別子、名前、アイコン、成績の概要、フレンド関係、申請・招待、対戦中の操作をサーバーで扱います。名前・アイコン・成績は対戦相手やフレンドに表示されます。")
                        information("Apple Music", "選んだプレイリストの曲を読み込み、本人の契約で再生します。対戦では選んだ曲の情報をサーバーへ送信します。Apple Musicの音声ファイルをアプリが保存・配布することはありません。")
                        information("曲情報の照合", "選択肢を作るためにアーティスト名をiTunesの検索APIへ送信します。正解発表では、曲名・アーティスト名などを使ってサーバーのサビ位置データベースと照合します。")
                        information("ご意見・サビ位置の報告", "送信した本文や曲情報はサーバーを経由して運営者のDiscordに届きます。本文に氏名・住所・連絡先などを書き込まないでください。アプリ内の匿名送信には個別返信できません。")
                        information("削除", "アカウント画面からプロフィールと関連データの削除を開始できます。Apple AccountやApple Musicの契約は削除・解約されません。")
                        if let url = AppConfiguration.privacyPolicyURL {
                            Link("プライバシーポリシー", destination: url)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                }
                StudioCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCaption(title: "ご利用について")
                        Text("他の人を傷つける名前・画像の設定、なりすまし、迷惑行為、不正な操作はお控えください。音楽や画像を無断で録音・転載しないでください。")
                        Text("曲の配信状況、契約、地域、通信環境によって利用できる機能が変わります。対戦の再生開始や操作には端末・通信による遅延差があります。")
                            .foregroundStyle(Studio.secondary)
                        if let url = AppConfiguration.termsURL {
                            Link("利用規約", destination: url).frame(minHeight: 44, alignment: .leading)
                        }
                    }
                }
                StudioCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionCaption(title: "サポート・クレジット")
                        if !AppConfiguration.operatorName.isEmpty { Text("運営者：\(AppConfiguration.operatorName)") }
                        if let url = AppConfiguration.supportURL {
                            Link("サポートページ", destination: url).frame(minHeight: 44, alignment: .leading)
                        }
                        if let url = AppConfiguration.supportFormURL {
                            Link("お問い合わせフォーム", destination: url).frame(minHeight: 44, alignment: .leading)
                        }
                        if AppConfiguration.supportFormURL != nil || AppConfiguration.supportURL != nil {
                            Text("お問い合わせにはGoogleフォームを利用します。返信を希望する場合のみメールアドレスをご入力ください。内容と返信先・返信メールは対応完了後90日間保存し、その後削除します。アプリのアカウント削除とは別に管理します。")
                                .foregroundStyle(Studio.secondary)
                        }
                        if !AppConfiguration.supportEmail.isEmpty,
                           let url = URL(string: "mailto:\(AppConfiguration.supportEmail)") {
                            Link(AppConfiguration.supportEmail, destination: url)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        Text("返信不要のご意見は、ホーム画面左上のメールアイコンから匿名で送信できます。")
                            .foregroundStyle(Studio.secondary)
                        Text("効果音の一部：OtoLogic（CC BY 4.0）")
                        Link("OtoLogic", destination: URL(string: "https://otologic.jp/")!)
                            .frame(minHeight: 44, alignment: .leading)
                        Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/deed.ja")!)
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

    private func information(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(Studio.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
