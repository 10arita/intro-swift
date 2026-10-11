# 手動サビDBの登録・更新

Apple Musicを聴いて確認した実際のサビ開始位置を保存し、正解発表のフル楽曲再生で最優先に使います。登録値はミリ秒単位の実時刻です。再生時に一度だけ1.5秒差し引き、曲の冒頭より前には戻しません。

## CloudKitの保存形式

| 項目 | 値 |
| --- | --- |
| Container | `iCloud.com.intro.IntoL` |
| Database / Zone | Public Database / `_defaultZone` |
| Record Type | `IntoLChorusCatalog` |
| Record Name | `manual-chorus-catalog-v1` |
| `payload` | Asset：`server/manual-chorus.json` |
| `schemaVersion` | Int(64)：`1` |
| `recordCount` | Int(64)：現在は`600` |

600曲の曲情報・確認日時・サビ位置を一つのJSON Assetとして保存します。個人プロフィール用のPrivate Databaseとは別のレコードです。アプリは固定Record Nameで取得するため、Query用のインデックスは不要です。`_world`にはこのRecord TypeのRead権限が必要です。

2026年10月12日に添付の`chorus-positions.xlsx`の600行を取り込み、DevelopmentとProductionの両方で保存済みの固定レコードを確認しました。除外行・重複キーは0件です。Assetは324,692バイト、カタログのSHA-256は`b861003290fa69669ab36bafeadfe9abd5f031b4595d46409c8a708f1864a0dc`です。ソースXLSXと全600行の曲名・アーティスト・アルバム・サビ開始MS・曲長MS・確認日時・MusicKit IDを照合しています。実機のCloudKit Asset取得とApple Musicの正解発表再生は別途確認してください。

## アルバム違いの照合と再生の優先順位

曲名とアーティストをUnicode NFKCで正規化し、大文字・小文字、空白、全角・半角の表記差を吸収します。アルバム名と曲IDは照合条件に入れません。アルバムやシングル、ベスト盤などで曲IDが変わっても、同じ曲名・アーティストなら同じサビ開始時刻を使います。

Live・Remixなど曲名にある版情報は保持し、別アーティストの同名曲にも適用しません。版情報がタイトルにない別録音までは自動判別できません。提出値が再生対象の曲長を超える場合は採用しません。

正解発表の順序は次のとおりです。

1. CloudKitのサビDB（通信失敗時は取得済みキャッシュ、なければ同梱データ）。既存のSongleの値や曲ID別キャッシュより優先。
2. 未登録の場合のみ、従来のSongleの値・取得処理。
3. 試聴音源の冒頭。
4. フル音源の長さから推定した位置。

iTunesの試聴音源にはフル楽曲の時刻を適用しません。アプリは初回参照時と15分以上経過した次の参照時にCloudKitを更新し、並行参照では一つの取得処理を共有します。取得のタイムアウトはリクエスト3秒・リソース4秒です。`APP_CLOUDKIT_ENABLED=false`の場合も同梱データを使えます。

サーバーも`server/manual-chorus.json`を最優先に使い、登録済みならSongleへ問い合わせません。サーバーはCloudKitを直接読まず、デプロイ時のJSONを使います。CloudKitへの更新だけで新しい曲をアプリに配信できますが、同梱データ・サーバーのデータも更新する場合は再ビルド・再デプロイしてください。

## XLSXからの更新

```sh
python3 scripts/import_chorus_workbook.py /path/to/chorus-positions.xlsx server/manual-chorus.json
sh scripts/test_manual_chorus.sh
sh scripts/test_reveal_audio.sh
cd server
npm test
```

Pythonには`openpyxl`が必要です。変換時に確認済み・手動提出の行、数値の整数ミリ秒、曲長の範囲、曲名とアーティストの重複を検査します。不正な行があれば出力を更新せず停止します。元のXLSXは変更しません。カタログには元のXLSXのSHA-256と行番号も残します。IDは文字列で保持します。

CloudKit Consoleで対象環境のPublic Databaseを開き、上記の固定レコードの`payload`を生成したJSONに置き換え、`recordCount`を更新して保存します。新規作成時はRecord Nameを必ず上記の値にしてください。初回はDevelopmentでRecord Typeと3フィールドを作り、本番へスキーマを公開します。スキーマ公開でレコードはコピーされないため、DevelopmentとProductionの両方にデータを保存してください。

更新後はConsoleのRecord Detailsで名前・Type・Assetサイズ・件数を読み戻します。実機では、同じ曲名・アーティストで別アルバムの曲を正解発表し、登録した時刻の1.5秒手前から再生することを確認してください。
