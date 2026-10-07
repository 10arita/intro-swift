# サビ位置データベースの実現性調査

調査日: 2026-10-05

## 結論

数万曲のサビ開始時刻をCloudKitに事前登録し、正解発表時に取得する構成は、技術的・容量的には実現可能です。ただし、音源取得・解析・結果利用の権利は別途必要です。

今回の音源取得元は「Apple Musicなどの配信サービス」を想定しています。この前提のまま、フル音源をPythonへ取り出して大量解析する計画は実施可能と判断できません。Apple Musicの契約・公開APIは、この用途の音源取得を認めているものではありません。購読者向けオフライン再生も、解析用ファイルの取得許諾にはなりません。

そのため、今回は調査と設計までとし、配信音源の取得、解析コードの実装、CloudKitへの登録は開始していません。以下のいずれかが確保できれば、具体的な実装へ進めます。

- 解析と派生した時刻データのアプリ利用を許諾された、対象曲と同じ録音・編集版のフル音源。
- 一括取得、継続保存、アプリへの提供を許諾されたサビ時刻データ。

## CloudKitの容量と運用

全利用者が参照するサビ時刻は、既存プロフィールのPrivate Databaseとは別に、同じコンテナのPublic Databaseへ保存します。Public Databaseのデータはアプリ側の割当容量を使用します。[Public Databaseの仕様](https://developer.apple.com/documentation/cloudkit/ckcontainer/publicclouddatabase)

1曲あたりのデータを仮に1KBとすれば、3万曲で約30MB、5万曲で約50MB、10万曲で約100MBです。これは設計上の概算で、CloudKitのレコード管理・インデックスなどの容量は含みません。音声ファイルを保存しない構成なら、数万曲という件数自体は大きな障害になりません。

AppleはPublic Dataについて最大1PBまでの容量を案内しています。ただし、これは現在のコンテナに最初からその容量が割り当てられるという意味ではありません。実際の容量・転送量・リクエスト枠と費用条件は、対象コンテナのCloudKit Consoleで確認する必要があります。この調査では当該アカウントの枠を確認していません。[CloudKit概要](https://developer.apple.com/icloud/cloudkit/)

AppleのWeb Services Referenceでは、1リクエストの最大操作数は200、音声Assetを除く1レコードは最大1MBです。インポートは100〜200件単位に分け、制限エラーの待機時間に従って再試行します。これらの数値はアーカイブ仕様なので、実際のサービスの応答にも対応する実装にします。[Data Size Limits](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html)

CloudKitの契約では、Public Databaseへの構造化データ保存は認められていますが、侵害データの保存や過大な負荷は禁止されています。容量が足りることだけで、登録対象データの利用が許可されるわけではありません。[Apple Developer Program License Agreement: Attachment 6](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

## 音源・データ取得の制約

### Apple Music

MusicKitの契約にはコンテンツのダウンロード・アップロード・改変等に制限があります。Pythonによる一括解析に使うフル音源の取得経路として採用できません。MusicKit経由での再生と、解析用音声データへのアクセスは別です。[Apple Developer Program License Agreement: 3.3.6 D](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

公開Song属性には曲長、ISRC、試聴URLなどがありますが、サビ開始時刻やフル音声データを取得する属性はありません。Previewオブジェクトにも、試聴部分が原曲の何秒目から始まるかを示す属性はありません。試聴部分で見つけた位置を、そのまま原曲の再生位置へ変換することはできません。[Songs.Attributes](https://developer.apple.com/documentation/applemusicapi/songs/attributes-data.dictionary)、[Preview](https://developer.apple.com/documentation/applemusicapi/preview)

別途、MusicKit再生にはユーザーによる開始、フル曲再生、標準再生操作、他コンテンツとの同期などの条件があります。この調査はサビDBの実現性に関するもので、現在のクイズ全体がAppleの条件・審査要件に適合することを確認したものではありません。

### 他のサービス

SpotifyのDeveloper Policyもコンテンツ解析を制限しています。YouTube APIのDeveloper Policiesは、事前の書面による承諾がない音声・映像のダウンロードや保存等を禁止しています。配信元を変更するだけでは、正規の大量解析経路を確保したことにはなりません。[Spotify Developer Policy](https://developer.spotify.com/policy)、[YouTube Developer Policies](https://developers.google.com/youtube/terms/developer-policies)

### Songle

現在のアプリとサーバーはSongle APIからサビ時刻を照会しています。Songleの公開規約には、商用利用に事前の書面による承諾を求める条件、データの再配信等を制限する条件、利用APIの明示に関する条件があります。

したがって「APIで読めるので、数万曲分をコピーしてPublic Databaseから配信できる」とは判断しません。採用する場合は、一括取得、保存期間、CloudKit経由の提供、商用利用、表示・クレジットの条件を提供元に確認します。元音源とApple Music版の長さ・編集の違いも検証が必要です。[Songle ウェブサービス・API利用規約](https://api.songle.jp/terms_of_use)

### 著作権法上の情報解析

日本の著作権法には非享受目的の情報解析等に関する規定がありますが、目的や利用態様によって適用は変わります。この規定を理由に、配信サービスの契約や技術的な制限を無視して取得できるとは判断しません。対象音源の解析、結果の利用・提供について許諾された経路を前提にします。[文化庁: AIと著作権に関する考え方の非享受目的の説明](https://www.bunka.go.jp/seisaku/bunkashingikai/chosakuken/workingteam/r06_01/pdf/94080501_16.pdf)

## 利用条件が整った場合の実装方針

### 1. 曲と録音版を確定する

入力は、ローカルの許諾音源のパス、Apple MusicカタログID、ストアフロント、ISRC、曲長、利用許諾の参照情報を持つマニフェストにします。購読ライブラリ内のIDを、カタログIDと同一視しません。

ライブ版、MV、リマスター、ラジオ編集版などを曲名だけで対応付けると、サビ時刻がずれます。ISRCも照合の手掛かりとし、同じ編集版であることと曲長・開始位置を確認します。確認できない対応は自動登録対象から外します。

### 2. Pythonでサビ候補を解析する

librosa等による音楽特徴量と反復構造の解析を初期候補にします。繰り返しの強さだけではAメロとサビを区別できないため、検出値を確定値と扱いません。

まず代表的な100〜300曲で、人手の正解に対する開始時刻の誤差・採用率・処理時間を評価します。反復が少ない曲、サビのない曲、判定が曖昧な曲は未検出として扱います。品質基準を満たした方法だけを数万曲へ拡張します。機械による評価スコアを、検証済みの正解確率と混同しません。

処理状況と結果はローカルSQLiteに記録します。音源のハッシュ、解析バージョン、成功・失敗・要確認状態を保存し、中断後に再開できるようにします。ワーカー数は実測したCPU・メモリ消費に合わせます。

### 3. 時刻メタデータだけをCloudKitへ登録する

新規Record Typeの例は `IntoLChorusPosition` です。

| フィールド | 内容 |
| --- | --- |
| `catalogID` / `storefront` | 対象のApple Music曲と地域 |
| `isrc` / `durationMS` | 録音版の照合用情報 |
| `chorusStartMS` / `chorusEndMS` | 原曲内のサビ区間 |
| `qualityScore` / `reviewStatus` | 解析品質と確認状態 |
| `analysisVersion` / `schemaVersion` | 再解析・互換性の管理 |
| `sourceReference` / `updatedAt` | 出典と更新日時 |

音源本体、試聴ファイル、認証情報、ローカル音源パスはPublic Databaseへ登録しません。詳細な許諾書や権利管理記録は非公開で保持します。

固定Record IDを用いて重複を防ぎ、変更済みの結果だけを登録します。Public Databaseは一般利用者に読み取りだけを許可し、登録・修正は管理用スクリプトに限定します。Server-to-Server Keyの秘密鍵は管理環境だけで保持します。[Server-to-Server認証](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html)

バッチごとの成功・失敗を記録し、部分失敗と通信断から再開します。Productionにはスキーマ公開後、データを別途投入します。Developmentのデータがスキーマ公開に伴って自動移行する前提にはしません。

### 4. 正解発表に組み込む

既存の `RoomService.chorus(_:)` と `RevealAudioPlayback.play` を接続点にします。現在はSongle由来の再生位置、試聴、曲長からの推定という経路があり、ソロ・対戦は同じ正解発表の再生処理を使っています。

CloudKitにある確認済みのサビ時刻を優先して取得し、1.5秒の助走は再生時に差し引きます。DBには助走を差し引く前の原曲時刻を保存し、既存の `chorusMS` が再生位置として使われている点に注意して変換します。

端末で結果をキャッシュし、準備中の先読みには短いタイムアウトを設けます。未登録・オフライン・照合不一致・低品質時も、既存の試聴や推定再生へ進めます。Songleを残す場合は、その利用条件を確認してから採用します。

フル曲の時刻を試聴音源へ適用しない既存の制約は維持します。サビ時刻は曲長内にあることを検証し、取り消された正解発表や別の問題の音声を遅れて開始しないことを確認します。

## 次に確定すること

必要なのはCloudKitの容量増加ではなく、対象曲の許諾音源または保存・提供が許諾された時刻データの取得元です。それを確定した後、少量での品質評価、再開可能なバッチ処理、CloudKit登録、アプリ側参照の順で実装します。
