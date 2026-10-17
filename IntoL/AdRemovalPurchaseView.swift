import SwiftUI

struct AdRemovalPurchaseView: View {
    @EnvironmentObject private var store: AdRemovalStore

    var body: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionCaption(title: "広告の削除")
                Text("一度の購入で、このアプリ内の広告を削除します。Apple Musicの契約は含まれません。")
                    .foregroundStyle(Studio.secondary)
                if !store.entitlementResolved {
                    ProgressView("購入情報を確認しています…")
                } else if store.adsRemoved {
                    Label("広告削除を購入済み", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Studio.success)
                } else if let product = store.product {
                    Button("\(product.displayPrice)で広告を削除") { Task { await store.purchase() } }
                        .buttonStyle(StudioButtonStyle(.primary))
                        .disabled(store.isWorking)
                        .accessibilityIdentifier("purchase-ad-removal")
                } else {
                    Button("商品を再読み込み") { Task { await store.loadProduct() } }
                        .buttonStyle(StudioButtonStyle(.secondary))
                        .disabled(store.isWorking)
                }
                Button("購入を復元") { Task { await store.restore() } }
                    .frame(minHeight: 44)
                    .disabled(store.isWorking)
                    .accessibilityIdentifier("restore-ad-removal")
                if store.isWorking { ProgressView("確認しています…") }
                if let message = store.message {
                    Text(message).font(.footnote).foregroundStyle(Studio.secondary)
                        .accessibilityIdentifier("ad-removal-message")
                }
            }
        }
        .task { await store.loadProduct() }
    }
}
