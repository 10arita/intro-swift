# CloudKitの設定と動作確認

アプリ側の実装は追加済みです。Apple Developer側の登録・署名・本番スキーマの公開は、以下の手順で行ってください。設定前は `APP_CLOUDKIT_ENABLED=false` として端末保存を使います。

## 保存される情報

| 保存先 | 内容 |
| --- | --- |
| CloudKitのPrivate Database | 名前、アイコン、復習曲と「覚えた」の状態、ソロ履歴（直近5回）、統計・ジャンル別成績・称号、音量設定、対戦サーバーのプロフィールIDと認証情報 |
| 端末 | 上記データのキャッシュと未同期の変更。サーバーの認証情報はKeychainに保存 |
| 対戦サーバー | ルーム、対戦の状態とセッション、フレンド関係・申請・招待、フレンドや対戦相手に表示する名前・アイコン・成績の要約 |

CloudKitのPrivate Databaseは本人のiCloudアカウントに属します。別端末も同じiCloudアカウントで同期すると、プロフィールと対戦サーバーの認証情報を復元でき、サーバーに残っているフレンド関係を利用できます。異なるiCloudアカウントでは端末キャッシュを分けます。iCloudからサインアウトしている間は最後に使ったプロフィールを端末で利用できますが、CloudKitへアップロードしません。[AppleのPrivate Databaseの説明](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase)

対戦中のPUSH・回答・準備完了・状態通知は既存の認証付きWebSocketで処理します。SSE/HTTPのフォールバックも維持しています。CloudKit同期はプレイ・ルーム参加・その他の読み込み操作が終わってから行います。ルームの進行やフレンド関係の判定は引き続きサーバーが担当するため、Coolifyは必要です。

## 1. Apple DeveloperとXcodeでCloudKitを有効にする

1. **Apple Developer Programに加入しているTeam**を用意します。Xcodeのアカウント設定に開発者アカウントを登録してください。無料のPersonal TeamではCloudKitコンテナを用意できません。
2. `IntoL.xcodeproj` を開き、**Targets → IntoL → Signing & Capabilities** で正しいTeamとBundle Identifierを確認します。現在のリポジトリのBundle Identifierは `com.intro.IntoL` です。ご自身の登録済みApp IDと一致させてください。
3. [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) の対象App IDで **iCloud（CloudKit）** を有効にします。Apple Musicを使う場合はMusicKitも有効なままにします。
4. Xcodeの **Signing & Capabilities → iCloud** で **CloudKit** をチェックします。iCloud項目が表示されていなければ **+ Capability → iCloud** で追加します。
5. **Containers** で `iCloud.com.intro.IntoL` を作成して選択し、対象App IDと関連付けます。Bundle Identifierを変更した場合は `iCloud.<新しいBundle Identifier>` を使ってください。
6. **Build Settings → CLOUDKIT_CONTAINER_IDENTIFIER** と選択したコンテナIDを一致させます。既定値は `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` です。独自のコンテナを選ぶ場合はDebug/Release両方の値を変更してください。この値を `IntoL/Info.plist` と `IntoL/IntoL.entitlements` の両方が参照します。Xcodeがentitlementsを具体的なIDで書き換えた場合も、両方が同じIDであることを確認してください。
7. Automatic Signingで署名プロファイルを更新します。署名エラーの場合は、App IDでiCloudが有効か、選択コンテナがTeamに属しApp IDに関連付いているかを確認してください。

追加済みのentitlementsは `com.apple.developer.icloud-services = [CloudKit]` と `com.apple.developer.icloud-container-identifiers` です。この実装はフォアグラウンドで取得・保存するため、Push NotificationsやBackground Modesの追加は不要です。CloudKit用のAPI Token・秘密鍵・サーバー側のApple認証設定も不要です。[AppleのCloudKit有効化手順](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app)

## 2. アプリの同期を有効にする

ルートの `.env` に以下を追加または変更します。

```dotenv
APP_CLOUDKIT_ENABLED=true
```

`.env` がなければ `.env.example` をコピーしてください。既存の `APP_SERVER_URL` はそのまま使います。変更後はアプリを再ビルドします。この値は公開設定としてアプリに組み込まれます。

## 3. Development環境で最初の保存を行う

1. iPhoneをiCloudにサインインさせ、iCloudの設定でIntoLの利用が許可されていることを確認します。最初のスキーマ作成は開発者のiCloudアカウントを使うと確認しやすくなります。
2. XcodeからDebugビルドを実機にインストールします。既存の記録を移行する端末では、アプリを削除せず更新してください。
3. IntoLの **アカウント → iCloudに同期** を押し、**「iCloudに保存済み」** と表示されることを確認します。名前やアイコンの変更、復習やゲームの記録、音量設定の変更でも同期が予約されます。アプリが前面に戻ったときにも再試行します。
4. [CloudKit Console](https://icloud.developer.apple.com/) の **CloudKit Database** で対象コンテナと **Development** を選び、Record Typesに以下が作られたことを確認します。データは **Private Database / Default Zone** のレコードです。

| 項目 | 値・型 |
| --- | --- |
| Record Type | `IntoLUserProfile` |
| Record Name | `current-user-profile`（各iCloudユーザーのPrivate Databaseに1件） |
| `payload` | `Asset`：JSONデータ。認証情報も含むのでPublic Databaseに置かないでください |
| `schemaVersion` | `Int64`：現在は `1` |

Developmentでは最初の保存でスキーマが作成されます。必要ならConsoleで上記Record Typeとフィールドを先に作っても構いません。固定Record IDで取得するため、Query用のインデックス追加や公開レコードの権限設定は不要です。

旧サーバーの復習・履歴・統計は、既存のプロフィール認証情報が端末に残っている場合に一度だけ取り込みます。サーバーが一時的に利用できなければ、CloudKitに端末データを保存し、旧記録は次の同期で取り込みます。旧サーバー側の記録は削除しません。初回同期を確認するまでは、アプリの削除やサーバーの永続ボリュームの削除を避けてください。

## 4. 対戦サーバーを更新する

今回の変更を含む `server` をCoolifyで再デプロイしてください。新しく追加した公開プロフィール要約の保存に必要です。`DATA_DIR` の永続ボリュームを維持してください。WebSocketの接続先、認証、ゲーム操作の形式は変更していません。CloudKit用の環境変数をCoolifyへ追加する必要はありません。

## 5. TestFlight / App Storeの前にProductionへスキーマを公開する

CloudKit Consoleの **Development → Deploy Schema Changes** で、`IntoLUserProfile` と2つのフィールドを **Production** に公開します。Developmentのレコード自体はProductionにコピーされません。公開後にTestFlightでも同期を確認してください。Xcodeからの開発用署名と配布用署名ではCloudKitの環境が分かれるため、Debugで保存できただけでは配布版の確認は完了しません。[Appleのスキーマ公開手順](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)

## 実機で確認すること

- 同じiCloudアカウントの2台で同期し、名前・アイコン・復習・成績・音量設定が復元されること。
- 片方の端末をオフラインにして遊び、オンラインへ戻した後に同期し、統計が二重加算されないこと。
- 復習曲を削除して同期した後、古いデータを持つ別端末から同期しても復活しないこと。
- 別のiCloudアカウントへ切り替えて同期し、前のアカウントの記録が移らないこと。
- 2台でルーム作成・参加・PUSH・回答・切断後の復帰・フレンド招待が従来どおり動くこと。

この開発作業では署名なしのiPhone向けビルド、同期データの統合テスト、サーバーとWebSocketのテストを実行しています。Apple Developer側の設定と署名済み実機でのCloudKitへの保存・復元は、設定完了後に実施してください。
