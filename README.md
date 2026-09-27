# IntoL — iPhone 向けイントロクイズ

SwiftUI 製 iOS 17+ アプリと、Coolify 用 Node.js サーバーです。`rule.md` をゲーム仕様の参考にし、個人学習と少人数のプライベート対戦向けに作成しました。画面は白と赤を基調に、プレイでは人数、イントロ・サビトロ、音源を順に選びます。下部の「プレイ」を押すと最初のロゴ画面に戻ります。

## できること

| モード | 音源 | 条件 |
| --- | --- | --- |
| ひとりで | 同梱のオリジナル音源、サーバーの共有音源、Apple Music または Spotify のプレイリスト | Apple Music は本人のサブスクリプション、Spotify は Premium と再生先が必要 |
| みんなで | ホストの Apple Music または Spotify のプレイリスト | 最大4人、全員が選んだサービスの再生条件を満たす必要があります |
| サビトロ | iTunes Search API の試聴曲を検索、または Spotify プレイリストと照合 | ひとりでも最大4人でも遊べます。対戦のホストはプレイリスト取得のため Spotify 連携が必要 |
| 共有音源対戦 | サーバー登録済み WAV | 最大4人、Spotify 不要 |

1曲30秒の PUSH、1文字5秒の4択、解答権、誤答・ライフ・得点、全員スキップ、最終順位、ソロの0〜100点と15段階ランクを実装しています。対戦サーバーが PUSH の到着順を判定します。各端末が準備完了を通知してから3秒のカウントダウンを始めます。通信や Spotify Connect の処理時間による再生ずれは残ります。

復習リストは「覚えてない」「覚えた」を各50曲、ソロ履歴は直近5回です。統計、ジャンル別正答率、8種類の称号、切断後5分以内の復帰、ホスト自動・手動交代にも対応しています。記録と進行中のルームはサーバーの `DATA_DIR` に保存します。Spotify 連携時はアカウント単位、未連携時は端末単位で記録を扱います。

文字選択肢はプレイリストと同梱の3つの曲名データ、80組の字形グループ、接頭辞、ビッグラム、同じ文字種の補充候補を使います。Spotify のソロプレイでは Apple Music 日本トップ100の曲名も使います。ルーム作成時は外部の曲名サービスを待ちません。小書き仮名と長音符はダミーに使いません。Songle でサビが見つかれば1.5秒手前から、見つからなければ曲長の32%を30〜90秒に収めた位置から Spotify で再生します。サビトロは試聴音源の冒頭から再生します。

## 先に Coolify サーバーを用意する

Spotify 認証の HTTPS コールバックと複数端末の対戦にはサーバーが必要です。Apple Music のソロプレイとデモには不要です。Apple Music 対戦を使う場合は、この変更を含むサーバーを再デプロイしてください。

1. このリポジトリを Coolify が参照できる Git リポジトリにプッシュします。
2. Coolify の **New Resource → Dockerfile** でビルド基準ディレクトリを `server`、Dockerfile をその中の `Dockerfile` にします。公開ポートは `3000`、レプリカは **1** にします。
3. HTTPS ドメインを設定し、環境変数 `PUBLIC_BASE_URL=https://あなたのドメイン` と `DATA_DIR=/app/data` を設定します。`PUBLIC_BASE_URL` の末尾に `/` を付けません。
4. **永続ボリュームをコンテナ内 `/app/data` にマウント**します。マウント先を変えた場合は `DATA_DIR` も合わせます。永続ボリュームがないと再デプロイ時に履歴と進行中ルームを失います。
5. デプロイ後、`https://あなたのドメイン/health` が `{"ok":true}` を返すことを確認します。アプリをビルドする Mac のルート `.env` に同じ HTTPS URL を `APP_SERVER_URL` として指定します。

サーバーの設定例は `server/.env.example`、アプリの設定例はルートの `.env.example` を参照してください。アプリのビルドでは `.env` から `APP_SERVER_URL` と `SPOTIFY_CLIENT_ID` だけを取り込みます。Spotify Client Secret はアプリに入れません。認証は PKCE を使用し、更新トークンは iPhone の Keychain に保存します。

## Spotify の設定

1. [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) でアプリを作成します。Redirect URI に **`https://あなたのドメイン/spotify/callback`** を完全一致で登録します。`intol://callback` は Spotify 側の登録先ではありません。サーバーが HTTPS コールバックを受け取り、アプリに戻します。
2. Development Mode ではアプリ所有者に Premium が必要です。使用する Spotify アカウントを Dashboard の **Users Management** に追加してください。現在の上限は5ユーザーです。Spotify の [Development Mode の説明](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)を参照してください。
3. ビルド前にルートの `.env` へ `SPOTIFY_CLIENT_ID` を指定します。各 iPhone では IntoL「アカウント」の「Spotify に接続」を押します。「再連携」から改めて認証できます。
4. Spotify アプリで一度曲を再生して再生先を有効にし、IntoL の「再生先を更新」でその端末を選択します。Spotify 音源の PUSH 中の一時停止とサビ出しは Connect API を使います。
5. 「プレイ」でプレイリストを選択します。2026年の Spotify API では、プレイリストの曲一覧取得は原則として自分が所有または共同編集するプレイリストに限られます。選択時に403が出る場合は自分のプレイリストを使ってください。

## Apple Music の設定

MusicKit for Swift を使います。Apple Music API の秘密鍵や手動の Developer Token はアプリに不要です。MusicKit が App ID を使って Developer Token を自動生成します。[Apple の設定手順](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)を参照してください。

1. [Apple Developer の Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) で、このアプリ用の **Explicit App ID** を作成するか既存の App ID を開き、**App Services → MusicKit** を有効にします。
2. Xcode の **Targets → IntoL → Signing & Capabilities** で自分の Team を選び、Bundle Identifier をその App ID と完全に一致させます。リポジトリ内の `com.example.IntoL` は仮の値です。署名プロファイルを更新して実機にインストールします。
3. Apple Music を利用できる Apple Account で iPhone にサインインし、Apple Music の有効なサブスクリプションを用意します。IntoL の「アカウント」で **Apple Music** を選び、「Apple Music に接続」を押してライブラリへのアクセスを許可します。許可を拒否した場合は iPhone の設定から IntoL のメディアライブラリアクセスを変更します。
4. 「プレイ」→「ひとりで」→「イントロ」→「Apple Music」からプレイリストを選びます。対戦する場合は全員がApple Musicに接続し、ホストは「みんなで」→「イントロ」→「Apple Musicで作る」を選びます。対戦では各曲を ISRC で Apple Music カタログに対応付けるため、一部の曲は除外されます。参加者の地域で再生できない曲があると、そのラウンドの準備が完了しません。

Apple Music のプレイリストはイントロクイズで利用できます。サビトロでは従来どおり iTunes 試聴音源または Spotify プレイリストとの照合を使います。Apple Music の正解発表では曲の長さから推定した位置から再生します。

## Xcode で起動・確認する

1. `cp .env.example .env` を実行し、サーバーと Spotify を使う場合は `APP_SERVER_URL` と `SPOTIFY_CLIENT_ID` を記入します。値が空欄でもデモは動きます。`.env` は Git の管理対象外です。値を変えたらアプリを再ビルドしてください。
2. [IntoL.xcodeproj](IntoL.xcodeproj) を Xcode で開きます。
3. **Targets → IntoL → Signing & Capabilities** で自分の Team を選び、`com.example.IntoL` を自分の Bundle Identifier に変えます。
4. iPhone 実機を選んで **Run**（⌘R）します。必要に応じて iPhone のデベロッパモードを有効化し、Mac を信頼します。シミュレータでもデモの画面と一部音源は確認できますが、Apple Music と Spotify の実再生は実機で確認してください。
5. まず設定なしで「プレイ」→「ひとりで」→「イントロ」→「オリジナル音源」→「プレイ開始」→ PUSH → 4択 → 結果 → 復習を確認します。
   「ショートカット」アプリから「ひとりで練習」を実行すると、同じオリジナル音源のソロ練習を直接始められます。
6. サーバーを設定したら2台の iPhone で共有音源ルーム、Apple Music ルーム、Spotify ルーム、サビトロを順に確認します。サビトロでは iTunes に一致しない曲を除外します。終了後は「アカウント」で記録の同期状態を確認します。
7. Wi-Fi を一時的に切って5分以内に戻し、同じルーム・得点・ライフに復帰することを確認します。ホストの退出と待機室の「ホストを譲る」も試せます。

署名なしの iPhone 向けビルド:

```sh
xcodebuild -project IntoL.xcodeproj -scheme IntoL -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/IntoLDerived \
  CODE_SIGNING_ALLOWED=NO build
```

サーバーのテスト:

```sh
cd server
npm test
```

ローカル起動は Node.js 22 以降で `cd server && node index.mjs` です。iPhone からアクセスする場合は HTTPS の Coolify 環境を使います。

この開発環境では iPhone 向けビルドとサーバーテストが成功しています。XcodeBuildMCP では iPhone 16 Pro (iOS 18.6) シミュレータでのビルド・起動と、デモの PUSH から正解発表まで確認できました。App Intent のビルドとショートカットのメタデータ生成も確認済みです。ただし、このシミュレータの「ショートカット」アプリでは追加したアクションを検索できず、ショートカットからの実行は未確認です。コマンドラインの `simctl` は CoreSimulator と Xcode のバージョン差により利用できません。

2026-09-27 に公開サーバーのヘルスチェックと Spotify 認証コールバック、Premium 実アカウントの認証、自分のプレイリストの曲一覧取得、Mac の Spotify Web Player へのイントロ再生、ゲーム終了時の一時停止を確認しました。離れた場所にある iPhone は再生先の一覧に表示されましたが、再生指示後も曲の開始を確認できませんでした。実機での iTunes と Songle のライブ動作は未検証です。

## 自作音源と Songle URL

自作または利用権のある WAV を `server/public/audio/` に置き、[server/catalog.json](server/catalog.json) に `id`、`title`、`artist`、`audioFile`、`durationMS`、`genre` を追加して再デプロイします。任意で `artworkURL`、`trackURL`、Songle に登録済みの元動画 `songleURL` を設定できます。ファイル名は英数字・`_`・`-` と `.wav` を使用してください。サーバーは登録済み WAV だけを配信します。初期6曲と PUSH 音は [scripts/generate_demo_audio.py](scripts/generate_demo_audio.py) で再生成できます。

## 利用条件について

個人学習用でも外部サービスの利用条件は適用されます。Spotify の [Developer Policy](https://developer.spotify.com/policy) にはトリビアクイズを含むゲーム利用の禁止、Apple の [iTunes Search API 文書](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/index.html) には試聴音源の用途制限が記されています。外部サービスの接続可否と利用条件を確認した上で使用してください。デモと自作音源の経路は外部連携なしで使えます。
