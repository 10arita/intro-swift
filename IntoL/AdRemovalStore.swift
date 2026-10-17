import Combine
import StoreKit

@MainActor final class AdRemovalStore: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var adsRemoved = false
    @Published private(set) var entitlementResolved = false
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    private var updatesTask: Task<Void, Never>?
    private var entitlementRevision = 0

    var isEnabled: Bool {
        AppConfiguration.monetizationEnabled && !AppConfiguration.adRemovalProductID.isEmpty
    }
    var shouldShowAds: Bool { isEnabled && entitlementResolved && !adsRemoved }

    deinit { updatesTask?.cancel() }

    func start() async {
        guard isEnabled else { return }
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled, let self else { return }
                    guard case .verified(let transaction) = result,
                          transaction.productID == AppConfiguration.adRemovalProductID else { continue }
                    await self.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
        await refreshEntitlements()
    }

    func loadProduct() async {
        guard isEnabled, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            product = try await Product.products(for: [AppConfiguration.adRemovalProductID])
                .first { $0.id == AppConfiguration.adRemovalProductID && $0.type == .nonConsumable }
            if product == nil { message = "商品を読み込めませんでした。時間をおいて再試行してください。" }
        } catch is CancellationError { return }
        catch { message = "商品を読み込めませんでした。接続を確認して再試行してください。" }
    }

    func purchase() async {
        guard isEnabled, !isWorking, entitlementResolved, let product, !adsRemoved else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      transaction.productID == AppConfiguration.adRemovalProductID,
                      transaction.productType == .nonConsumable else {
                    message = "購入情報を確認できませんでした。「購入を復元」から再確認してください。"
                    return
                }
                entitlementRevision += 1
                adsRemoved = transaction.revocationDate == nil && !transaction.isUpgraded
                entitlementResolved = true
                await transaction.finish()
                message = adsRemoved ? "広告を削除しました。" : "この購入は現在有効ではありません。"
            case .pending:
                message = "購入は承認待ちです。承認後に自動で反映します。"
            case .userCancelled:
                break
            @unknown default:
                message = "購入を完了できませんでした。もう一度お試しください。"
            }
        } catch is CancellationError { return }
        catch { message = "購入を完了できませんでした。接続を確認して再試行してください。" }
    }

    func restore() async {
        guard isEnabled, !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = adsRemoved ? "購入を復元しました。" : "有効な広告削除の購入は見つかりませんでした。"
        } catch is CancellationError { return }
        catch { message = "購入を復元できませんでした。時間をおいて再試行してください。" }
    }

    private func refreshEntitlements() async {
        entitlementRevision += 1
        let revision = entitlementRevision
        var entitled = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == AppConfiguration.adRemovalProductID,
               transaction.productType == .nonConsumable,
               transaction.revocationDate == nil, !transaction.isUpgraded {
                entitled = true
            }
        }
        guard revision == entitlementRevision else { return }
        adsRemoved = entitled
        entitlementResolved = true
    }
}
