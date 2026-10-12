# ローカル非公開サビ位置DB

非商用の調査・確認用として、既存の手動確認600曲とSongleのサビ区間をSQLiteに保存します。

- 保存先: `.private/chorus/chorus.sqlite3`
- 集計: `.private/chorus/chorus.summary.json`
- ディレクトリの権限: `0700`、DBと集計ファイル: `0600`
- `.private/`全体をGit管理から除外。DBはアプリのリソースやサーバーのDockerイメージに含めません。
- ローカルDBをマスターとし、必要な曲情報と時刻だけをサーバー内の非公開SQLiteへ同期できます。アプリには曲ごとの開始位置だけを返し、DBファイル・移行履歴・検索結果・元のAPI応答は公開しません。既存600曲の配信用JSON・CloudKitレコードは通信失敗時の参照元として残ります。

## 移行と取得

```sh
# 既存600曲を取り込む。ネットワークアクセスは行わない。
python3 scripts/collect_songle_chorus.py

# 既存の曲名コーパスを対象に、元のチャートでアーティストを照合して取得。
python3 scripts/collect_songle_chorus.py --charts --collect

# 中断後は保存済み結果を利用して続きから取得。
python3 scripts/collect_songle_chorus.py --collect --retry-errors
```

主要曲の対象は`server/corpus/`の既存4ファイルにある1,237表記です。Unicode正規化と空白除去で同じ曲名をまとめ、2015〜2025年の年間チャートおよび2015〜2026年の週次チャートからアーティストを補います。同名でアーティストが異なる曲は別の対象です。手動確認値がある曲は取得を省略します。

取得は[Songle Widgetの公開JSON API](https://widget.songle.jp/docs/v1)の検索とサビ区間照会のみを利用します。音声・動画ファイルは取得しません。リクエストは逐次実行し、間隔を最低0.5秒空けます。429や一時的な障害では最大3回まで再試行し、`Retry-After`に従います。3曲連続でエラーになったら停止します。検索APIが404を返した場合は検索結果なしとして記録します。

`--limit 50`で1回の対象件数を絞れます。`--refresh`で完了済みの対象とAPIキャッシュを更新します。保存後にSongleの解析が訂正されることがあるため、再確認にはこのオプションを使用します。

照合処理を変更した後は`--retry-unmatched`で、保存済みの検索結果から不一致の対象を再照合できます。

## 保存内容と確認状態

`observations`は手動確認とSongle解析を別々に保持します。開始位置は原曲先頭からのミリ秒で、再生用の1.5秒の余白は差し引きません。

| テーブル・ビュー | 内容 |
| --- | --- |
| `tracks` | 曲名、アーティスト、正規化した照合キー |
| `observations` | サビ開始MS、元音源の曲長MS、取得元、確認状態、確認・取得日時、元URL、Songle URL、取得データのJSON |
| `segments` | 有効なサビ区間と繰り返し区間の開始MS・長さMS |
| `imports` | 元の600曲JSON全文、SHA-256、取り込み件数・日時 |
| `targets` | 各曲の収集状態、試行回数、エラー、検索結果、曲情報の出典 |
| `target_observations` | 対象曲と取得した録音の対応 |
| `http_cache` | 公開API・チャートの応答と取得日時。中断後の再開に利用 |
| `metadata` | スキーマ、非商用・非公開の用途、Songleのクレジットと規約URL |
| `preferred_chorus` | 手動確認値を優先した参照用ビュー。要確認候補は除外 |

手動600曲は元のアルバム・MusicKit ID・メモ等を含む全項目を`payload_json`に保持します。再取り込みは重複を作らず、古い確認日時の値で新しい値を上書きしません。

Songleは曲名とアーティストを照合し、カバー、ライブ、リミックス、短縮版を曖昧一致で採用しません。曲名を引用符で囲んだ動画タイトルや`Official Music Video`等の限定した表示上の装飾は照合できます。アーティスト未確認の曲は候補を`needs_review`として保管します。`metadata_matched`も音源の同一性を聴いて確認した状態ではなく、Apple Music等の別の録音にそのまま適用できる保証はありません。元URLと曲長を併せて確認してください。

Songle未登録や完全一致なし、サビ区間なしも`targets`に残ります。推定時刻で埋める処理はありません。1対象について最大3つの録音を保持します。

サビ区間が元音源の曲長を超える結果は採用しません。サビ以外の繰り返し区間が曲長を超える場合は、その区間を`segments`から除外し、元の区間を含むAPI応答は`payload_json`に保持します。`validationWarnings`に理由を記録し、その録音全体を`needs_review`として扱います。

## 参照例

```sh
sqlite3 .private/chorus/chorus.sqlite3 \
  'SELECT source,status,count(*) FROM observations GROUP BY source,status;'

sqlite3 .private/chorus/chorus.sqlite3 \
  'SELECT title,artist,chorus_start_ms,duration_ms,source FROM preferred_chorus LIMIT 20;'

sqlite3 .private/chorus/chorus.sqlite3 \
  'SELECT status,count(*) FROM targets GROUP BY status;'
```

## データサイズ

2026年10月12日の実測値は20,811,776バイトです。10進表記で20.81MB、2進表記で19.85MiBです。SQLiteのページサイズ4,096バイト×5,081ページとファイルサイズが一致します。空きページは16,384バイトです。

以下はテーブルと対応するインデックスを合算した使用量です。音声・動画ファイルは含みません。

| 内容 | 使用量（MB、1MB＝1,000,000バイト） |
| --- | ---: |
| API・チャート応答キャッシュ | 15.389 |
| 収集対象・検索結果 | 2.507 |
| サビ位置・取得元・保存JSON | 1.921 |
| サビ・繰り返し区間 | 0.496 |
| 既存600曲の移行元JSON | 0.332 |
| 曲情報、その他の管理情報、空き領域 | 0.168 |

件数は曲情報985件、観測値1,039件（手動600件＋Songle439件）、区間9,687件です。再取得用キャッシュが全体の約74%を占めます。

## 手動更新

`observations`の`source='manual'`の行を編集します。時刻はミリ秒です。SQL列と`payload_json`の両方を更新し、`checked_at`も実際の確認日時へ更新してください。元の600曲JSONを再取り込みしても、古い確認日時の値では新しい手動値を上書きしません。

以下の例は既存のID 1「ワタリドリ / [Alexandros]」の開始位置を60秒へ変更します。実際に聴いて確認した位置を入力してください。この手順の検証はDBの一時コピーで行い、実DBの値は変更していません。

まずターミナルでバックアップしてからDBを開きます。バックアップ先のファイル名は毎回変えると、前のバックアップを保持できます。

```sh
umask 077
chorus_db=/Users/arito/github/intro-swift/.private/chorus/chorus.sqlite3
sqlite3 "$chorus_db" ".backup '/Users/arito/github/intro-swift/.private/chorus/chorus-before-edit.sqlite3'"
sqlite3 "$chorus_db"
```

開いたSQLiteの入力欄で対象のID・取得元・曲長を確認します。

```sql
.headers on
.mode table
SELECT o.id, t.title, t.artist, o.chorus_start_ms, o.duration_ms, o.source
FROM observations o JOIN tracks t ON t.id = o.track_id
WHERE t.title LIKE '%ワタリドリ%';
```

確認した手動行を更新します。開始位置は0以上かつ曲長未満である必要があります。以下ではID 1を指定しています。

```sql
BEGIN;
UPDATE observations
SET chorus_start_ms = 60000,
    checked_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
    payload_json = json_set(
        payload_json,
        '$.chorusStartMS', 60000,
        '$.checkedAt', strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    )
WHERE id = 1 AND source = 'manual';

SELECT changes() AS updated_rows;
SELECT id, chorus_start_ms, checked_at
FROM observations WHERE id = 1;
```

更新件数が1件で値が正しければ`COMMIT;`、取り消す場合は`ROLLBACK;`を実行します。最後に`.quit`で閉じます。曲名・アーティストを直接変更する場合は正規化キーも更新する必要があるため、以下のJSON取り込みを使って新しい曲情報を登録してください。

### 曲の追加・Songleの値を手動確認値で補う

Songle由来の行を直接書き換えると、再取得時に元の値へ戻る可能性があります。元の解析結果を残し、手動の行を別に登録すると`preferred_chorus`が手動値を優先します。

Apple Musicでフル音源を聴いて確認した値を、Git管理外の`.private/chorus/manual-edits.json`に以下の形式で保存します。曲名・アーティスト・時刻・曲長・確認日時は実際の値へ置き換えてください。`recordCount`は`records`の件数と合わせます。

```json
{
  "schemaVersion": 1,
  "recordCount": 1,
  "records": [
    {
      "title": "追加する曲名",
      "artist": "アーティスト名",
      "chorusStartMS": 60000,
      "durationMS": 240000,
      "checkedAt": "2026-10-12T02:00:00Z",
      "method": "manual-apple-music"
    }
  ]
}
```

取り込みは次のコマンドで行います。位置と重複を検査し、曲名とアーティストの正規化キーを自動生成します。Songleへの問い合わせや公開DBへの反映は行いません。

```sh
python3 /Users/arito/github/intro-swift/scripts/collect_songle_chorus.py \
  --manual-catalog /Users/arito/github/intro-swift/.private/chorus/manual-edits.json
```

これらの変更はローカルSQLiteに保存されます。以下の自動同期を導入した後は、サーバー内の非公開SQLiteにも反映され、更新後のアプリが最新値を参照します。既存の配信用JSON、CloudKitの公開データは書き換えません。

## アプリへの自動反映を導入する

初回のみサーバーの再デプロイと、この変更を含むアプリの再ビルド・配布が必要です。導入後はマスターSQLiteの編集だけで反映できます。旧バージョンのアプリはCloudKit優先のため、全利用者に確実に反映するにはアプリを更新してもらってください。

### 1. サーバーを更新する

この変更を含むコードをGitHubのCoolifyが参照するブランチへ反映し、Coolifyで既存サービスを再デプロイします。ビルド基準ディレクトリ`server`、Dockerfile`server/Dockerfile`、永続ボリューム`/app/data`は既存と同じ設定です。Node.js 22.13以降が必要です。Dockerfileの`node:22-alpine`で利用できます。

Coolifyの環境変数に以下を設定します。

| 設定 | 値 |
| --- | --- |
| `DATA_DIR` | `/app/data`。既存の永続ボリュームを維持 |
| `CHORUS_SYNC_TOKEN` | `.private/chorus/sync.env`の同名の値。64文字のランダム値をローカルに生成済み。チャットやGitには貼らない |
| `CHORUS_DB_PATH` | 任意。未設定なら`/app/data/chorus/catalog.sqlite3` |

同期先DBはコンテナ内の非公開ファイルで、HTTPによるダウンロード経路はありません。管理用の`PUT /admin/chorus-sync`には上記トークンが必要です。トークンをアプリの`.env`やInfo.plistへ追加しないでください。

元の20MBのマスターDBを直接同期先として指定すると更新APIは拒否します。サーバーの同期先は別のSQLiteファイルにしてください。これは元の取込履歴や解析の証拠を消さないためです。

### 2. 初回同期する

ローカルの`.private/chorus/sync.env`は権限`0600`で作成済みです。接続先は`https://intro.apps.oucc.org`です。Coolifyへ設定したトークンと、このファイルのトークンが同じであることを確認します。

ターミナルで次を実行します。

```sh
python3 /Users/arito/github/intro-swift/scripts/sync_chorus_database.py
```

`Synchronized 948 observations`と表示されれば、既存の手動600件とSongleの照合済み348録音の同期が完了しています。以後はDBの件数に応じて表示が変わります。要確認91録音、検索結果、元API応答、MusicKit ID、移行元JSONは同期しません。

エラー時は接続先、Coolify側のトークン、永続ボリュームの書き込み権限、サーバーの再デプロイ完了を確認してください。失敗時は前回のサーバーDBを保持します。ローカルDBは読み取り専用で開くため変更しません。

### 3. 自動同期を起動する

```sh
python3 /Users/arito/github/intro-swift/scripts/sync_chorus_database.py --watch
```

このプロセスを動かしておくと、確定済みのSQLite変更を5秒ごとに確認して自動同期します。時刻の更新、手動データの追加、削除に対応します。キャッシュだけの変更や未確認データの編集では同期しません。ネットワーク障害時は再試行し、同期できた場合だけ完了を記録します。

Macの電源が切れているとき、スリープ中、このコマンドを停止したときは同期されません。再起動すると、その時点の最新DBを同期します。DBファイルの更新で再デプロイや再起動を行う必要はありません。

ターミナルを開いたままにせず、ログイン時に自動起動する場合は、上の`--watch`をCtrl+Cで停止してから次を実行します。LaunchAgentのひな形はこのMacのパスで作成済みです。

```sh
mkdir -p /Users/arito/Library/LaunchAgents
cp /Users/arito/github/intro-swift/scripts/chorus-sync.launchagent.plist.example \
  /Users/arito/Library/LaunchAgents/org.oucc.intol.chorus-sync.plist
launchctl bootstrap gui/"$(id -u)" \
  /Users/arito/Library/LaunchAgents/org.oucc.intol.chorus-sync.plist
```

ログは`.private/chorus/sync.stdout.log`と`sync.stderr.log`に保存されます。停止するときは次を実行します。

```sh
launchctl bootout gui/"$(id -u)" \
  /Users/arito/Library/LaunchAgents/org.oucc.intol.chorus-sync.plist
```

### 4. アプリを一度更新する

XcodeのIntoLターゲットでBuild番号を増やし、この変更を含むIntoLをArchiveしてTestFlight／App Store等で配布します。既存の`APP_SERVER_URL=https://intro.apps.oucc.org`を使用し、管理トークンは含めません。更新後のソロと対戦は、正解発表直前に`POST /chorus/database`で最新の開始位置を取得します。HTTPキャッシュと曲ID別の古い準備値よりサーバーSQLiteを優先します。

アプリは手動値を優先し、Songle由来の録音は曲長が再生対象と3秒以内で一致するものだけ使います。DBにない曲や削除した曲には古いCloudKit値や準備済みの位置を適用しません。必要に応じて従来のSongle照会、試聴、推定再生へ進みます。サーバーに接続できない場合やSQLiteが未導入の場合は、従来のCloudKit・同梱データを参照します。

### 5. 反映を確認する

```sh
curl --fail --silent --show-error \
  https://intro.apps.oucc.org/chorus/database \
  -H 'Content-Type: application/json' \
  -d '{"id":"applemusic:check","title":"ワタリドリ","artist":"[Alexandros]","durationMS":251760}'
```

変更前の例は`{"databaseConfigured":true,"positionMS":48681,"source":"manual_database"}`です。DBのサビ開始は50,181msで、APIは再生用に1,500msを一度だけ差し引きます。手動で60,000msへ修正した場合は、同期後に`positionMS:58500`になります。

`databaseConfigured:false`なら同期DBがまだありません。404ならこのAPIを含むサーバーへまだ更新されていません。この確認用APIには管理トークンは不要です。

ローカル検証では、サーバーと同期プロセスを動かしたままDBを編集し、新しい位置が返ること、HTTPキャッシュを使わないこと、DBファイルのURLが404になること、無認証の更新が403になること、不正データで前の値が消えないことを確認しています。iOSの取得優先順位・削除・取得元表示の検証とアプリ全体のビルドも成功しています。

## 利用範囲とクレジット

Songle / AIST — [Songle](https://songle.jp/) — Songle Widget API

[Songle ウェブサービス・API利用規約](https://api.songle.jp/terms_of_use)の「解析結果等の利用」は非商用の解析結果利用を定めています。「権利帰属」「禁止事項」はデータの再配信等を制限しています。DBファイルを公開しないことと、取得した秒数をアプリ利用者に提供することは別の条件です。本実装のAPIは曲ごとの位置だけを返しますが、この提供方法が許諾されることを確認したものではありません。Songle由来の位置を利用者へ提供する際は提供元の条件を確認してください。

検証:

```sh
python3 -m unittest discover -s tests -p 'test_songle_chorus.py' -v
```
