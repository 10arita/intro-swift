import SwiftUI

struct ProfileDeletionTarget: Codable {
    let profileID: String
    let origin: String
    let credential: String
}

struct ProfileDeletionRequest: Codable {
    static let storageKey = "pendingProfileDeletion"
    let targets: [ProfileDeletionTarget]
    let cloudAccountID: String?
    let replacement: CloudProfile

    static func load() throws -> Self? {
        guard let value = Secrets.get(storageKey), let data = value.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func store() throws {
        let value = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        Secrets.set(value, for: Self.storageKey)
        guard Secrets.get(Self.storageKey) == value else {
            throw AppError.message("削除の受付情報を端末に保存できませんでした。時間をおいて再試行してください")
        }
    }
}

struct AccountDeletionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("アカウントとデータの削除")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                StudioCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("名前・アイコン・復習・履歴・成績・音量設定と、サーバー上のプロフィール・フレンド関係・申請・招待を削除します。")
                        Text("iCloud同期を利用している場合は、iCloudの個人データも消去します。古い端末の記録が再び取り込まれないよう、個人の記録を含まない削除マーカーを残します。")
                        Text("Apple AccountとApple Musicの契約は削除・解約されません。匿名で送信したご意見や報告はアカウントと結び付いていないため、この操作では削除されません。")
                            .foregroundStyle(Studio.secondary)
                        Text("削除は取り消せません。通信に失敗した場合は、この画面で再試行してください。")
                            .foregroundStyle(Studio.secondary)
                    }
                }
                if model.accountDeletionCompleted {
                    Label("アカウントと関連データを削除しました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Studio.success)
                        .accessibilityIdentifier("account-deletion-completed")
                } else {
                    if let error = model.accountDeletionError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("account-deletion-error")
                    }
                    if model.isDeletingAccount {
                        ProgressView("データを削除しています…")
                            .accessibilityIdentifier("account-deletion-progress")
                    } else {
                        Button(role: .destructive) {
                            if model.accountDeletionPending { Task { await model.deleteAccount() } }
                            else { confirming = true }
                        } label: {
                            Text(model.accountDeletionPending ? "削除を再試行" : "アカウントとデータを削除")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(StudioButtonStyle(.secondary))
                        .foregroundStyle(.red)
                        .disabled(!model.canDeleteAccount)
                        .accessibilityIdentifier("delete-account")
                        if !model.canDeleteAccount {
                            Text("プレイや同期が終わってから削除できます。")
                                .font(.footnote).foregroundStyle(Studio.secondary)
                        }
                    }
                }
            }
            .foregroundStyle(Studio.primary)
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Studio.background)
        .navigationTitle("データの削除")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("アカウントと関連データを削除しますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("削除する", role: .destructive) { Task { await model.deleteAccount() } }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("削除したプロフィール・記録・フレンド関係は元に戻せません。Apple Musicの契約は継続します。")
        }
    }
}
