import CloudKit
import Foundation

@MainActor final class CloudChorusDatabase {
    static let shared = CloudChorusDatabase()
    static let recordName = "manual-chorus-catalog-v1"
    private var entries = ManualChorusCatalog.bundled()?.index ?? [:]
    private var refresh: Task<ManualChorusCatalog?, Never>?
    private var lastAttempt = Date.distantPast
    private let cacheURL: URL

    private init() {
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("manual-chorus-cloud-v1.json")
        if let data = try? Data(contentsOf: cacheURL), let catalog = try? ManualChorusCatalog.decode(data) {
            entries = catalog.index
        }
    }

    func revealPosition(for song: Song) async -> Int? {
        guard !song.id.hasPrefix("itunes:"), !Task.isCancelled else { return nil }
        if lastAttempt.timeIntervalSinceNow < -900, refresh == nil {
            lastAttempt = Date()
            refresh = Task { await Self.fetchCatalog() }
        }
        if let pending = refresh {
            if let catalog = await pending.value { entries = catalog.index }
            refresh = nil
        }
        guard !Task.isCancelled else { return nil }
        return ManualChorusCatalog.revealPosition(for: song, index: entries)
    }

    private static func fetchCatalog() async -> ManualChorusCatalog? {
        guard AppConfiguration.cloudKitEnabled,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String,
              identifier.hasPrefix("iCloud."), !identifier.contains("$(") else { return nil }
        let operation = CKFetchRecordsOperation(recordIDs: [CKRecord.ID(recordName: recordName)])
        operation.desiredKeys = ["payload", "schemaVersion"]
        operation.configuration.timeoutIntervalForRequest = 3
        operation.configuration.timeoutIntervalForResource = 4
        let state = ChorusFetchCompletion()
        let data: Data? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                operation.perRecordResultBlock = { _, result in
                    guard let record = try? result.get(), record["schemaVersion"] as? Int == 1,
                          let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
                          let data = try? Data(contentsOf: url) else { state.finish(nil); return }
                    state.finish(data)
                }
                operation.fetchRecordsResultBlock = { _ in state.finish(nil) }
                CKContainer(identifier: identifier).publicCloudDatabase.add(operation)
            }
        } onCancel: { operation.cancel(); state.finish(nil) }
        guard let data, let catalog = try? ManualChorusCatalog.decode(data) else { return nil }
        try? data.write(to: shared.cacheURL, options: .atomic)
        return catalog
    }
}

private final class ChorusFetchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var completed = false

    func install(_ value: CheckedContinuation<Data?, Never>) {
        lock.lock()
        if completed { lock.unlock(); value.resume(returning: nil); return }
        continuation = value
        lock.unlock()
    }

    func finish(_ data: Data?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(returning: data)
    }
}
