# IntoL App Store 正式公開に向けた調査

調査日：2026年10月14日（日本時間）  
対象：`1e6cf55` のアプリ・サーバー・素材・設定・既存資料。日本向けに有料販売、アプリ内課金、広告のいずれかを導入する前提。

**現状のまま収益化して正式公開することは勧めない。最初に音源・データの利用許諾と収益化の方法を決め、その後に審査対応と掲載準備を進める必要がある。** 特に、iTunes試聴音源のゲーム利用・保存、Apple Musicへのアクセスの収益化、Songle由来のデータ提供、歌ネットのランキング転用が重要。

「未実装」はコードで確認できなかったもの、「未確認」は契約書、Apple Developer／App Store Connect、CloudKit Console、本番運用などをこの調査で確認していないもの。許諾書がリポジトリにないことだけで、許諾を取得していないとは断定しない。本書は調査と対応案であり、アプリの機能変更や審査申請は含まない。

## 1. 優先度別の不足

P0は公開・収益化の方針を止めて解決する項目、P1は該当機能を公開する前に必要な項目、P2は公開品質と運用を整える項目。

| 優先度 | 項目 | 現状 | 完了条件 |
| --- | --- | --- | --- |
| P0 | iTunes試聴音源のクイズ利用・一時保存 | 実装あり。通常の公開条件と衝突 | サビトロと正解発表等の試聴経路を、ゲーム利用が許諾された音源へ置換するか公開版から除外。特別許諾を使う場合は用途・保存を含む書面を確保 |
| P0 | Apple Musicと収益化・演出の関係 | ゲーム進行で再生・停止・サビへ移動。収益化する部分は未決定 | Appleに具体的な料金・広告配置を確認。権利者への許諾確認と再生操作の見直しを完了 |
| P0 | Songleの商用利用・保存データの提供 | ライブAPIとSQLite経由の位置情報を利用。許諾は未確認 | 商用利用、保存、移行、アプリへの提供、表示方法について書面で承諾を得るか、その経路・由来データを除外 |
| P0 | 歌ネット由来のランク曲集 | 1000位まで取得した順位・メタデータから716曲を収録。許諾は未確認 | 商用転用・順位を基にした難易度設定等の許諾を得るか、独自に選定・評価したデータへ置換 |
| P1 | Privacy Manifest | ソースと今回のRelease成果物に `PrivacyInfo.xcprivacy` なし | 使用しているRequired Reason APIの理由を宣言し、配布バンドルへの同梱を確認 |
| P1 | プライバシーポリシー・サポート公開ページ | アプリ内のリンク・本文が見当たらない。Web公開状況は未確認 | 日本語の公開URL、アプリ内リンク、運営者と問い合わせ先を用意 |
| P1 | アカウント・関連データの削除 | サーバーの自動作成プロフィールあり。削除画面・APIなし | アプリ内で削除を開始でき、サーバー・CloudKit・端末等の関連情報に対応できる |
| P1 | ユーザー投稿への対応 | 名前と写真を他のプレイヤーへ表示。通報・ブロック・不適切内容のフィルタは見当たらない | 投稿を許すなら通報・ブロック・審査／削除の運用を実装。初版で任意投稿を制限する案も検討 |
| P1 | BGM・効果音・素材の証跡と表示 | OtoLogicタグ付き効果音あり、クレジットなし。その他MP3の出典不明 | 出典・取得時の規約・商用可否を台帳化し、必要な表示または有償ライセンスの証跡を用意 |
| P1・採用時 | 課金・広告機能 | StoreKit、広告SDK、ATTの実装が見当たらない | 販売方式を確定し、購入・復元・返金／失効処理、広告とデータ取得に必要な対応を実装 |
| P1 | 掲載情報・画像・審査用説明 | UI確認画像あり。確認したhome/account画像は368×800 | 対応するApp Storeサイズで撮影。説明、料金条件、権利申告、審査手順を揃える |
| P1・未確認 | 配布署名・CloudKit Production・実機試験 | 署名なしReleaseビルド成功。配布版の実機試験は未実施 | 署名済みArchiveの検証とTestFlight実機確認を完了 |
| P2 | 本番運用・品質 | health正常、サーバーテスト成功。負荷・バックアップ等は未確認 | 復元試験、監視、障害連絡、負荷試験、公開後の保守担当を決める |

## 2. 音楽とデータの権利

### 2.1 iTunes試聴音源：表示の追加だけでは解決しない

サビトロはApple Musicプレイリストの曲をiTunesの試聴URLに照合し、試聴音源を出題に使う。`GameAssets` は外部音源をダウンロードして一時ディレクトリに移す。正解発表ではApple Music等の再生に失敗した場合にも試聴音源を使うため、**サビトロの入口を消すだけでは対象経路が残る**。

根拠：[試聴URLの生成](/Users/arito/github/intro-swift/server/external.mjs:23)、[音源のダウンロード・保存](/Users/arito/github/intro-swift/IntoL/GameAssets.swift:46)、[正解発表の試聴フォールバック](/Users/arito/github/intro-swift/IntoL/AppModel.swift:1071)、[復習の試聴再生](/Users/arito/github/intro-swift/IntoL/ReviewView.swift:174)。

AppleのiTunes Search API文書は、試聴音源の利用を対象楽曲の販促に限定し、独立した娯楽用途やダウンロード・保存・キャッシュを認めていない。通常の販促利用でもストアへの所定のバッジとリンク、試聴音源の提供元表示が必要。無料公開でもこの用途制限は残る。[iTunes Search APIの利用条件](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/)

対応案は、ゲーム用途を含む別途許諾を得た音源、自作音源、適切な商用ライセンスの音源への置換。ストリーミングだけに変更することや「provided courtesy of iTunes」の表示だけでは、ゲーム用途の問題は解消しない。

### 2.2 Apple Music：加入者本人が再生していても確認が必要

フル音源は `ApplicationMusicPlayer` で再生し、アプリがApple Musicの音声ファイルを保存する実装は確認していない。本人の認可・サブスクリプション確認もある。一方、ゲームに合わせた自動再生・停止・サビへのシークを行い、出題画面の操作はPUSHとSKIP中心で、通常の一時停止／再開操作は見当たらない。[認可・再生条件](/Users/arito/github/intro-swift/IntoL/MusicServices.swift:79)、[再生位置の指定](/Users/arito/github/intro-swift/IntoL/MusicServices.swift:318)、[出題画面](/Users/arito/github/intro-swift/IntoL/SoloGameView.swift:71)

ガイドライン4.5.2は、利用者による再生開始と標準的な再生操作、Apple Musicアクセスの直接・間接的な収益化の禁止を定めている。また、特定の瞬間に特定曲を使うなどの複雑な統合では、MusicKitの利用に加えて権利者からの許諾が必要となり得る。[App Review Guidelines 4.5.2](https://developer.apple.com/app-store/review/guidelines/#apple-sites-and-services)

**このアプリへの判断：** Apple Musicモードを有料で解放する、問題追加を課金する、広告視聴を再生・出題の条件にする設計は、その条項に触れる強い懸念がある。Apple Musicが主要な機能であるアプリ全体の有料販売・広告収益化も、具体的な仕様をAppleに確認する必要がある。独立した機能への課金なら必ず許容される、とはこの調査では判断しない。音源の権利者の承諾とAppleのサービス利用条件は別々に確認する。

確認時には、ソロ／対戦、30秒出題、PUSH停止、正解発表のサビ再生、全員が自分の加入契約で再生する点、料金の対象、広告の配置、画像共有の仕様をまとめて提示するとよい。許諾費や対象曲数は個別条件によるため、現時点で確定額は出せない。

Apple Musicから取得したプレイリスト等の利用者データを広告ターゲティングや利用者・端末の特定に使うことも4.5.2で制限される。将来広告を導入する際に、曲の好みを広告SDKへ渡す設計は採用しない。ATTの同意は、この制限の代替にならない。

### 2.3 JASRAC・NexToneと原盤権

自分で市販曲のファイルを配信・同梱する場合には、少なくとも次の権利を整理する。

| 権利・条件 | 主な確認先・内容 |
| --- | --- |
| 楽曲の著作権 | JASRAC／NexToneの管理状況と、音楽出版社等。ゲームへの利用、複製、配信等の区分 |
| 音源の著作隣接権・原盤利用 | レコード会社・原盤権者等。商用ゲーム利用、配信、端末保存、抜粋使用 |
| 編集・演出に関する許諾 | 権利者。切り出し、ゲーム演出、必要に応じた同期・翻案等 |
| 配信サービスの契約 | Apple等。ゲームでの使用、課金、広告、API・画像の利用範囲 |
| 宣伝素材 | ジャケット・写真・曲の音声を広告、ストア画像、紹介動画に使う範囲 |

JASRACはゲーム製作での権利者との事前合意、音源利用に関する著作隣接権の別途処理を案内している。NexToneも管理状況によりゲーム録音・ゲーム配信の申請が必要としている。[JASRAC：ゲームの製作](https://www.jasrac.or.jp/users/game/)、[NexTone：ゲーム・遊技機での音楽利用](https://www.nex-tone.co.jp/copyright/users/game.html)

MusicKitで各加入者が再生する現在の形態にどの申請が必要かは、利用図を管理団体・権利者に提示して確認する。自前配信の手続きをそのまま当てはめることも、Appleの加入契約だけで全権利が処理済みとみなすことも避ける。

### 2.4 Songle：商用の承諾と保存・提供方法を確認

SongleはAPI照会だけでなく、取得したサビ位置を非公開SQLiteへ保存し、アプリへ曲ごとの位置を提供できる構成。既存資料もこの提供方法の許諾を確認したものではないと記載している。[現在のDB用途](/Users/arito/github/intro-swift/docs/private-chorus-database.md:3)、[既存資料の権利確認事項](/Users/arito/github/intro-swift/docs/private-chorus-database.md:250)

規約は、商用利用の事前の書面による承諾、API使用の明示、指定のクレジット、情報・データの再配信等の制限を含む。**DBファイルを公開しなくても、位置情報を利用者へ提供する方法の確認が必要。** 手動で確認した600曲とSongle由来のデータを出典別に区別し、後者の保存・移行・提供まで承諾の範囲に入れる。[Songleウェブサービス・API利用規約](https://api.songle.jp/terms_of_use)

許諾を使わない初版なら、ライブ照会、SQLiteのSongle由来位置、フォールバック、再生成スクリプトなどを含めて公開版の経路を整理し、独自に確認した時刻のみを利用する。独自時刻でも音源再生の権利問題は別に残る。

### 2.5 歌ネット・Billboard JAPAN由来の曲名とランキング

ランク測定は歌ネットの歴代人気順を1000位まで取得し、元順位を100位ごとの難易度として716曲を選定している。単に歌詞を表示していないだけでは、サイトのデータ転用条件を解決しない。[取得・選定の記録](/Users/arito/github/intro-swift/docs/rank-catalog-review.md:3)、[順位を難易度に使う仕様](/Users/arito/github/intro-swift/docs/rank-measurement.md:9)

歌ネットの一般利用規約は、無断での複製、改変、編集、提示、送信、頒布、販売、スクレイピング等を禁止している。許諾書を確認できないため、商用版では事前確認を最優先とする。出典リンクや「非公式」の表示だけで許諾に代えることはできない。[歌ネットご利用規約](https://www.uta-net.com/info/kiyaku.html)

Billboard JAPANからも曲名コーパスを生成している。[生成スクリプト](/Users/arito/github/intro-swift/scripts/build_jpop_corpus.py:1)。今回確認できた[CHART insight会員向け約款](https://www.billboard-japan.com/common/kiyaku/kiyaku_b.html)には営業利用・無断転用の制限があるが、**公開チャートを取得する今回の経路への適用範囲は未確認**。公開データの商用再利用条件を運営者に確認するか、別の許諾されたデータ源・独自曲集へ置換する。個々の曲名等の事実の扱いと、データベース・配列・取得先の契約条件は区別する。

## 3. 同梱素材・表示・ブランド

| 対象 | 確認結果 | 必要な対応 |
| --- | --- | --- |
| 初期6曲のWAV・`push.wav` | 生成スクリプトに自作合成・第三者サンプル不使用の記載 | 自作の根拠と権利者を記録。出題曲を拡充する場合も同様 |
| `push.mp3` | ID3にOtoLogic / Quiz-Button03-2 | 使用条件・取得元を記録し、クレジットまたは表示不要ライセンスを確認 |
| `question.mp3` | ID3にOtoLogic / Quiz-Question03-1(Low) | 同上 |
| `bgm.mp3`・`correct.mp3`・`incorrect.mp3` | 商用利用の条件を示す資料を発見できず | 作者、配布ページ、取得時の規約、ゲームへの組込みと広告使用の可否を確認 |
| Apple Musicアイコン | 公式素材を使用した旨の記録あり | 正式公開時の使い方と公式ガイドラインを照合 |
| アプリアイコン・デザイン | 1024px・透明度なしのアイコンあり | 元素材／制作履歴、権利者、第三者ロゴとの混同を確認 |
| サーバーの `ws` | MITライセンスファイルあり | 配布物で著作権表示・ライセンス文を保持。アプリ内表示の要否は配布範囲に応じて判断 |

実際の効果音プレーヤーはMP3を使用するため、自作の `push.wav` が存在するだけでは `push.mp3` の処理を済ませたことにならない。[自作音源の生成](/Users/arito/github/intro-swift/scripts/generate_demo_audio.py:1)、[MP3効果音の使用](/Users/arito/github/intro-swift/IntoL/Services.swift:212)

OtoLogicはCC BY 4.0で商用利用を許し、無料利用にはクレジットを求めている。アプリの「クレジット／ライセンス」に作者名、素材リンク、ライセンスリンク、変更がある場合は変更内容を記載する案がよい。有償のクレジット不要ライセンスを取得済みなら、その証跡で対応できる。[OtoLogic利用規約](https://otologic.jp/free/license.html)

Apple Musicの名前・アイコン・バッジは公式の使用方法に合わせ、Apple公式アプリや提携サービスと誤認させる表示を避ける。[Apple Music Identity Guidelines](https://marketing.services.apple/apple-music-identity-guidelines)。アプリ名「IntoL」の商標・類似名調査、所属団体等のサーバーを商用に使う場合の承認、共同制作者との権利帰属は未確認。

## 4. プライバシー・アカウント・ユーザー投稿

### 4.1 実際のデータ経路に合わせて文書と申告を作る

名前・写真・復習・履歴・統計・音量等は端末とCloudKit Private Databaseへ保存する。公開プロフィール要約（名前、写真、成績、最高ランク等）は別途対戦サーバーへ送る。フレンド・申請・招待・ルームもサーバーに保存する。自由記述の問い合わせとサビ報告はサーバーからDiscordへ送る。[CloudKit保存](/Users/arito/github/intro-swift/IntoL/CloudProfileService.swift:47)、[公開プロフィール送信](/Users/arito/github/intro-swift/IntoL/RoomService.swift:948)、[Discord送信と受付控え](/Users/arito/github/intro-swift/server/anonymous-reports.mjs:30)

選んだ曲の情報は、対戦サーバーへの送信、iTunes／Songleでの照合、利用者が送るサビ報告等で端末外へ伝わる。ライブラリ全体を送信すると断定するものではないが、各経路の送信内容をポリシーと画面説明へ反映する。

アプリ内のプライバシーポリシーへのリンクとApp Store ConnectのURLが必要。[App Review Guidelines 5.1.1](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage)。プライバシーポリシーには、運営者、取得項目、目的、各保存先、他プレイヤーへの表示、委託先・外部サービス、保持期間、削除・開示等の窓口、権限変更、施行日・改定方法を記載する。日本法上も、個人情報を取得する場合の利用目的の明示・通知等を実態に合わせて整える。[個人情報保護委員会：通則編](https://www.ppc.go.jp/personalinfo/legal/guidelines_tsusoku/)

App Privacyの申告候補は次のとおり。**現在の構成で「データを収集しない」と一括申告するのは適切でない。** 最終回答は本番ログ、広告SDK、利用目的まで決めてから確定する。

| 実装上の情報 | App Privacyの分類候補 | 確認点 |
| --- | --- | --- |
| UUID・表示名・プロフィールID | Identifiers → User ID | ニックネームはscreen nameの扱い。実名を別途取得するならNameも検討 |
| 他参加者へ表示するアイコン写真 | User Content → Photos or Videos | 自社サーバー保存とプロフィールIDへの関連付けあり |
| 対戦・得点・回答・成績・最高ランク | Gameplay Content / Product Interaction | 保存内容と用途で区分し、ユーザーとの関連付けを申告 |
| フレンド関係 | Contacts（social graphを含む）の候補 | 電話帳アクセスは確認していないが、アプリ内の関係データはある |
| 問い合わせ本文 | Customer Support | 匿名でも申告不要とは限らない。任意開示免除の全条件を確認 |
| 選曲・検索・聴取に関する情報 | Product Interaction / Search Historyの候補 | 自社・外部サービスでどこまで保存するか、ログも確認 |
| 広告SDK・アクセスログ | Advertising Data、識別子、診断情報等の候補 | SDK選定、IP等の保存、解析・広告目的の有無で追加 |

Appleの申告上の「収集」は、端末外へ送信し、要求処理に必要な時間を超えて開発者・パートナーがアクセス可能となる情報を指す。[App Privacyの定義と分類](https://developer.apple.com/app-store/app-privacy-details/)。CloudKit Private Databaseは通常開発者から見えないため、自社サーバーへの送信と同一視しない。端末内だけの情報、Private Database内の情報、サーバー保存を項目ごとに分ける。[CloudKit privateCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)

現在の問い合わせ画面は「匿名」「アカウント情報は含まない」と表示する一方、Discordへの保存・保持期間を示していない。利用者が本文に個人情報を書き込むこともあるので、保存先と利用目的を確認できるリンク、個人情報を不用意に記載しない案内を用意する。[現状の送信前説明](/Users/arito/github/intro-swift/IntoL/FeedbackReportViews.swift:86)

受付控えは30日を基準に枝刈りするコードがあるが、アクセス時の処理であり、保存ファイルとDiscordメッセージが30日で必ず消えることを確認したものではない。プロフィールには期限による削除処理を発見していない。保持期間を文書に書く前に、定期削除・バックアップ・Discord側の削除まで設計する。

Discord・ホスティング・広告等の外国事業者に個人データが渡る場合は、実際の契約、取扱国、委託／第三者提供の区分、同意または相当措置等を確認する。国外サービスを使うだけで一律に同意が必要と断定せず、提供の実態で判断する。[個人情報保護委員会：外国にある第三者への提供編](https://www.ppc.go.jp/personalinfo/legal/guidelines_offshore/)

### 4.2 自動作成されるプロフィールも削除対象

アプリは認証情報がないとサーバーにプロフィールを作る。[自動登録](/Users/arito/github/intro-swift/IntoL/RoomService.swift:897)。サーバーには作成・取得・更新があるが、削除APIが見当たらない。[プロフィールAPI](/Users/arito/github/intro-swift/server/index.mjs:484)

Appleは自動作成のゲストアカウントもアプリ内から削除を開始できるよう求める。[Apple：アカウント削除](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion)

実装時は、サーバーのプロフィール・写真・フレンド・申請・招待・保存済み個人記録・ルーム内データ、CloudKitプロフィール、端末キャッシュ・UserDefaults・Keychainの扱いを揃える。別端末の古いデータで削除済みプロフィールが復活しない仕組みと、処理完了・保持例外の説明も必要。Apple Accountそのものを削除する機能は不要で、このアプリのアカウントとデータを対象にする。

### 4.3 写真・名前の投稿を維持するなら対策を追加

任意の写真と名前が対戦相手・フレンドへ表示されるため、UGC対策の対象になると判断する。少人数・コード招待でも公開アプリでは想定外の利用者が参加できる。必要な対応は、不適切な名前・画像を公開する前の対策、対象を特定できる通報、ブロック、運営による削除・停止、公開連絡先。[App Review Guidelines 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)

現在のサビ相違報告・匿名意見フォームは、迷惑ユーザーの通報とブロックを実現していない。初版を簡素にするなら、運営が用意したアバターと制限した表示名にする案を検討できるが、UGCをどこまで残すかは審査説明と一致させる。

## 5. Privacy Manifestと権限

今回のソース検索・Releaseバンドル確認で `PrivacyInfo.xcprivacy` を発見できなかった。Required Reason APIの使用があるため、宣言を追加してXcodeターゲットへ含める必要がある。[Apple TN3183](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)

| APIカテゴリ | 現在の使用例 | 現実装に合う理由の候補 |
| --- | --- | --- |
| UserDefaults | [プロフィール・設定保存](/Users/arito/github/intro-swift/IntoL/AppModel.swift:54) | `CA92.1`：自アプリ専用データの読み書き |
| FileTimestamp | [画像キャッシュの更新日時による整理](/Users/arito/github/intro-swift/IntoL/ArtworkCache.swift:63) | `C617.1`：アプリコンテナ内のファイル情報 |
| SystemBootTime | [ランク測定の時間計測](/Users/arito/github/intro-swift/IntoL/AppModel.swift:613) | `35F9.1`：アプリ内イベントの経過時間・タイマー |

候補を機械的にコピーせず、全使用箇所が理由の範囲内であることを確認する。広告SDK等を追加したら、そのSDKのマニフェスト・署名・データ収集も再確認する。[Apple：APIカテゴリと認められた理由](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

`NSAppleMusicUsageDescription` は既に存在し、クイズ利用の目的を記載している。PhotosPickerによる写真選択もある。**写真ライブラリ全体への権限文言を、PhotosPicker使用だけを理由に追加する必要があるとは判断しない。** 現在未実装の追跡を導入する場合には、ATTと使用理由の追加を検討する。

## 6. 有料販売・課金・広告を採用する場合

### 販売方法ごとの作業

| 方法 | このアプリに足りないもの |
| --- | --- |
| App Storeでアプリ自体を有料販売 | Apple Musicアクセスとの関係確認、価格・利用条件、Paid Apps契約、税務・銀行情報。ダウンロード課金だけならアプリ内の購入画面は不要 |
| 非消費型の機能解放・広告削除 | StoreKit購入、購入済み権利の判定、復元、購入保留／キャンセル／返金・取消への対応、商品設定・審査用情報 |
| 自動更新サブスクリプション | 上記に加え、継続的な提供価値、更新・期限・失効の扱い、契約管理、価格・周期・自動更新・解約条件の表示 |
| 広告 | SDK選定、広告内容と年齢の適合、表示・閉じる操作、広告と音楽アクセスの関係確認、収集情報・保存先・プライバシー申告の更新 |

有料販売・IAPにはAccount HolderによるPaid Apps Agreementが必要で、税務・銀行情報も整える。現在の契約状態は未確認。[有料契約](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/)、[税務情報](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information)

日本ではiOS 26.2以降に代替決済の制度があるため、「デジタル課金はどの方式でも必ずIAPのみ」という説明は正確ではない。ただし、代替決済にはEntitlement、StoreKit API、開示画面、対象地域・OS、Apple IAPを併記する要件等がある。初版は標準のIAPを基準に設計すると実装を抑えられる。日本の代替決済を選んでも、MusicKitの収益化制限は別に残る。[日本のApp Storeの決済オプション](https://developer.apple.com/support/payment-options-on-the-app-store-in-japan)

このアプリはiOS 17以上を対象とするため、代替決済を導入するならiOS 26.2未満での購入導線も分岐して確認する。

広告があるだけでATTが必須になるわけではない。追跡またはIDFAへのアクセスを行うなら、ATTの許可前に実施しない設計にする。拒否時の動作も確認する。[Apple：User Privacy and Data Use](https://developer.apple.com/app-store/user-privacy-and-data-use/)。広告・解析による端末情報の外部送信については、日本の外部送信規律の適用対象かを確認し、該当時は送信情報・送信先・目的を通知／公表等できるようにする。[総務省：外部送信規律FAQ](https://200.180.31.150.static.iijgio.jp/main_sosiki/joho_tsusin/d_syohi/gaibusoushin_kiritsu_00002.html)

### 日本向けの取引表示

有料アプリ・課金サービスでは、販売主体とAppleの販売契約に応じ、特定商取引法に基づく表示の役割分担を確認する。自社のWeb決済を採る場合は、自社の販売ページと最終確認画面も整える。

記載候補：事業者の氏名・名称、住所・電話番号、責任者、税込価格、追加費用、支払時期・方法、提供時期、動作環境、返品・解約・返金条件、継続契約の更新条件。Apple Musicの別契約・別料金や通信料も購入判断に必要な条件として明示する。個人事業者の住所等の省略には条件があり、単に「問い合わせれば開示」と書けば足りるとは判断しない。[消費者庁：通信販売広告](https://www.no-trouble.caa.go.jp/what/mailorder/advertising.html)、[表示省略等のQ&A](https://www.no-trouble.caa.go.jp/qa/advertising.html-2)

## 7. 記載・提出すべきもの

### 7.1 アプリ内・公開Webページ

| 掲載場所 | 内容 |
| --- | --- |
| アカウント／設定 | プライバシーポリシー、利用規約、サポート、クレジット、アカウントとデータの削除 |
| 初回利用・写真設定・対戦前 | 名前・写真・成績の表示範囲、保存・同期の説明、禁止投稿・迷惑行為への対応 |
| Apple Music接続・プレイ開始前 | ライブラリアクセス、本人の有効な契約が必要なモード、対戦では各人の再生条件が必要な点 |
| 問い合わせ送信前 | 送信項目、保存先、目的、返信の有無、保持・削除の確認先 |
| 課金画面 | 購入対象、税込価格、支払・更新条件、復元・契約管理、利用規約・プライバシーへのリンク |
| サポートサイト | 運営者と連絡先、FAQ、対応環境、障害情報、返金・解約案内、必要な取引表示 |

利用規約は標準EULAの置換が常に必須という意味ではない。Appleの標準EULAに加え、このサービスの対戦・投稿・課金・停止・データ削除の条件を明確にすることが目的。[App Store Connect：アプリ情報とEULA](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)

### 7.2 App Store Connect

| 項目 | 準備・確認内容 |
| --- | --- |
| 名称・サブタイトル | 名称30文字以内、サブタイトル30文字以内。商標・類似アプリ名を確認 |
| 説明 | 4000文字以内。ソロ、2〜4人対戦、復習、記録、採用する音源方式と利用条件。許諾されていない機能は掲載しない |
| キーワード | 合計100バイト以内。第三者のブランド名等を検索目的で詰め込まない |
| プロモーションテキスト | 任意、170文字以内 |
| Copyright | 年＋実際の権利者名。Apple側で記号が付くため、権利者を正しく記載 |
| Support URL | 実際に連絡できる公開サイト。匿名で返信できない送信機能だけでは問い合わせ対応が不足する |
| Privacy Policy URL／App Privacy | 公開ポリシーと実際の取得・用途・関連付け・追跡の回答 |
| カテゴリ | Gamesを基本候補とし、実際の機能に合うMusic／Trivia等を検討 |
| 年齢制限 | 音楽の不適切表現、UGC、広告、交流機能を質問票に反映。自動的に4+と決めない |
| Content Rights | 外部曲・画像・データについて権利を持つか、適法に使えることを確認して回答 |
| 価格・販売地域 | 日本を選択。将来の海外配信は許諾地域・法対応の再確認後に広げる |
| IAP・サブスク | 採用する場合は商品情報、審査用画面・説明、販売条件 |
| 輸出コンプライアンス | `ITSAppUsesNonExemptEncryption=false` は設定済み。暗号利用の実態と免除判定を再確認 |
| バージョン・ビルド | 現在は5.3.1 / 35。既存の登録・提出履歴に合わせ、同じビルド番号を再使用しない |
| 審査連絡先・Notes | 担当者、再現手順、音源・収益化・権利資料、外部サービスの要件、課金の確認方法 |

文字数・必須フィールド等の根拠：[アプリ情報](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)、[バージョン情報](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)。年齢制限は現在4+／9+／13+／16+／18+等の体系で、質問票から算定される。[年齢制限の定義](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions)

### 7.3 スクリーンショット・プレビュー

`artifacts/home.jpg` と `account.jpg` は368×800で、公開用に撮り直しが必要。6.9インチ枠には例として1320×2868等の対応サイズがあり、6.9インチ画像を提供しない場合は6.5インチ用が必要。単なる拡大ではなく、Release相当の画面を対応端末で撮影する。現在はiPhone対象のため、iPad対応を追加しない限りiPadネイティブ用画像を一律に要求するものではない。[スクリーンショット仕様](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

候補はプレイ選択、出題・回答、対戦、結果、復習。架空のプレイヤー情報を使用し、第三者のジャケットや曲を強調した広告素材・紹介動画には、その用途の権利も確認する。紹介動画は任意。アプリアイコンは1024×1024・透明度なしを確認済み。

### 7.4 掲載説明に必ず反映したい条件

許諾と最終仕様を決めた後、次の条件を正確に記載する。

- Apple Musicを使うモードではライブラリアクセスと有効なサブスクリプションが必要。対戦でも参加者それぞれの条件を満たす必要がある。
- 対戦は2〜4人。インターネット接続・通信料・配信地域や曲の配信状況による利用制限。
- Apple Musicの料金はIntoLの購入・課金料金に含まれない。
- iCloud同期の対象と、未サインイン・通信不能時の保存範囲。
- サーバー到着順でPUSHを判定すること、音楽配信・通信・出力機器による遅延差があること。
- ランクは独自の推定値であること。現在の人気順位を難易度とする仮設定を、実測で検証するか正式版から外すかを決める。
- 有料機能と無料範囲、広告の有無、継続課金がある場合の条件。

現在の「サビトロ」は試聴音源の冒頭を使うため、必ず実際のサビになる保証はない。「サビを聴いて当てよう」という説明と提供内容を、許諾された音源方式に変更した後で揃える。[現在のサビトロ説明](/Users/arito/github/intro-swift/IntoL/PlayFlow.swift:195)

## 8. 配布・審査・運用に残る確認

### 今回確認できたこと

- Xcode 27.0（27A266a）、iOS SDK 27.0を使用。
- iOS 17.0以上、iPhone対象、Bundle ID `com.intro.IntoL`、CloudKitコンテナ `iCloud.com.intro.IntoL`。
- このMacの許可されたビルド設定にはHTTPSサーバーURLが入り、CloudKitは有効。設定済みサーバーのGET `/health` は `{"ok":true}` を返した。
- 署名なしのiPhone向けReleaseビルドに成功。
- サーバー `npm test` は108件成功。別途WebSocket統合テスト2件も成功。
- 開発用UI・サビ登録ツールの入口は `#if DEBUG` で制限されている。

2026年4月28日以降のアップロードはiOS 26 SDK以降が必要。今回のSDKはこの最低要件を満たす。最低対応OSをiOS 26へ上げる必要があるという意味ではない。[Apple：SDKの最低要件](https://developer.apple.com/jp/news/?id=ueeok6yw)

### 未確認であり、公開前に実施すること

- Apple Developerの会員・契約状態、App IDのMusicKit有効化、配布用証明書・プロファイル、署名済みArchiveのValidate／Upload。
- CloudKitのプロフィール・サビDB等の必要スキーマをProductionへ公開し、TestFlightで保存・復元する。Debugでの保存だけでは不十分。[現在の設定資料](/Users/arito/github/intro-swift/docs/cloudkit-setup.md:62)
- Apple Musicの実再生、権限拒否・未加入・更新失敗、曲の配信停止、地域差、空のプレイリスト、音源準備失敗時の再試行・中止を実機確認。
- 2〜4台で開始、途中参加、PUSH、回答、ホスト交代、招待、通信断からの復帰。Wi-Fi／モバイル通信、Bluetooth等での遅延差も確認。
- iCloud未サインイン・容量不足・オフライン・アカウント変更、2台間同期、削除後の再同期を確認。
- 小さいiPhone、対応最低OSと現在のOS、文字サイズ拡大、VoiceOver、ダークモード、視差効果を減らす、電話等の音声割り込みで確認。
- 採用する課金方式で購入・保留・復元・取消・更新・失効をSandbox／TestFlight確認。広告は追跡拒否・読み込み失敗・年齢条件も確認。
- サーバーの永続ボリューム、バックアップと復元、アクセスログと認証情報の保護、期限削除、更新・障害通知、公開負荷に合わせた制限を確認。

サーバーはプロフィール等を認証秘密値も含むJSONへ保存する。HTTPSと端末Keychainは使用されているが、本番ボリュームの権限・暗号化・バックアップへのアクセス制限、プロフィール作成等の悪用対策は運用も含めて確認が必要。これは今回脆弱性を実証したという意味ではない。[保存処理](/Users/arito/github/intro-swift/server/index.mjs:46)

審査担当者がアプリの全主要機能を確認できる手順を作る。通常の画面にはApple Musicプレイリストの入口しかなく、自作練習はApp Shortcut経由で存在する。購読不要の正式な練習入口を設ける案は有用だが、審査専用の隠し機能にしない。[通常のプレイリスト画面](/Users/arito/github/intro-swift/IntoL/PlayFlow.swift:365)、[自作練習の入口](/Users/arito/github/intro-swift/IntoL/RootView.swift:150)

Notesには、各モードの確認手順、必要な契約と機器、対戦確認方法、稼働するバックエンド、権利許諾資料、課金機能を具体的に書く。Apple Accountのパスワード共有を前提にしない。ランク測定の「ベータ版」表記が残るため、正式な完成機能として検証するかTestFlightに留めるかを決める。名前を変えるだけでは未完成の状態は解決しない。[審査ガイドライン2.1・2.2](https://developer.apple.com/app-store/review/guidelines/#performance)

## 9. 推奨する実施順

1. **公開する音源方式と販売対象を決める。** iTunes試聴ゲーム利用を置換し、MusicKitと収益化の関係をAppleへ確認する。権利関係の窓口に、再生・データ・広告の仕様を提示する。
2. **外部データと素材の許諾を揃える。** Songle、歌ネット、Billboard由来の情報、BGM・効果音・ジャケットについて、承諾・除外・置換を決める。
3. **公開アプリとして不足する導線を実装する。** Privacy Manifest、規約・ポリシー・サポート・クレジット、データ削除、UGC対応、採用する課金・広告。
4. **Productionで実機検証する。** TestFlight、CloudKit、複数台対戦、削除・課金・広告、本番運用の確認。
5. **公開情報を最終仕様で作る。** スクリーンショット、説明、料金条件、App Privacy、年齢制限、Content Rights、審査Notesを揃えて提出する。

有料版の初回公開を急ぐ場合は、**権利を自分で管理できる音源・独自曲集・独自のサビ位置を基礎に、収益化する範囲を確定する案**が最も見通しを立てやすい。MusicKit中心の現在の体験を維持する場合は、先にAppleと権利者から回答を得ることが工程の前提となる。

## 10. 検証記録と確認待ちの資料

実行した検証：

```text
xcodebuild -project IntoL.xcodeproj -scheme IntoL -configuration Release
  -destination generic/platform=iOS
  -derivedDataPath /tmp/intol-appstore-audit-20261014
  CODE_SIGNING_ALLOWED=NO build
→ BUILD SUCCEEDED

server: npm test
→ 108 tests, 108 pass, 0 fail

server: npm run test:socket
→ 2 tests, 2 pass, 0 fail

GET https://intro.apps.oucc.org/health
→ {"ok":true}
```

最初のサンドボックス内実行ではXcodeマクロ処理・ローカル待受が制限されて失敗したため、通常権限で同じ検証をやり直した。上記は再実行後の結果。署名、審査、実機再生、外部契約の適合を証明する検証ではない。

確認待ちの資料：音源・各データ提供元の契約／承諾書、MP3の出典とライセンス、課金商品の対象・価格・広告の配置、運営者と販売主体、公開サポート／ポリシーURL、App Store Connectの登録・契約・提出履歴、CloudKit Production設定、実機試験記録、バックアップ・ログ・保存期間の運用。
