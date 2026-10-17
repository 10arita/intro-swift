import CloudKit
import CryptoKit
import Foundation

enum CloudProfileError: LocalizedError {
    case notConfigured, signedOut, restricted, temporarilyUnavailable, accountChanged, invalidProfile

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "iCloud に接続されていません。データはこの端末だけに保存されています"
        case .signedOut: return "iCloudにサインインしてください。データは端末に保存しています"
        case .restricted: return "この端末ではiCloudの利用が制限されています"
        case .temporarilyUnavailable: return "iCloudを確認できません。時間をおいて同期してください"
        case .accountChanged: return "iCloudアカウントが変更されました。同期を再試行してください"
        case .invalidProfile: return "iCloudのデータを読み込めません。アプリの更新または設定を確認してください"
        }
    }
}

@MainActor final class CloudProfileService {
    private var container: CKContainer?
    private let recordID = CKRecord.ID(recordName: "current-user-profile")

    private func configuredContainer() throws -> CKContainer {
        guard AppConfiguration.cloudKitEnabled,
              let identifier = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String,
              identifier.hasPrefix("iCloud."), !identifier.contains("$(") else {
            throw CloudProfileError.notConfigured
        }
        if let container { return container }
        let created = CKContainer(identifier: identifier)
        container = created
        return created
    }

    func accountID() async throws -> String {
        let container = try configuredContainer()
        switch try await container.accountStatus() {
        case .available: return try await container.userRecordID().recordName
        case .noAccount: throw CloudProfileError.signedOut
        case .restricted: throw CloudProfileError.restricted
        case .couldNotDetermine, .temporarilyUnavailable: throw CloudProfileError.temporarilyUnavailable
        @unknown default: throw CloudProfileError.temporarilyUnavailable
        }
    }

    func synchronize(_ local: CloudProfile, accountID expected: String) async throws -> CloudProfile {
        let container = try configuredContainer()
        let database = container.privateCloudDatabase
        // Fetch by a fixed ID: no public records, queries, indexes, or user-discovery permission.
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
            let record: CKRecord
            do { record = try await database.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "IntoLUserProfile", recordID: recordID)
            }
            let remote = try decode(record)
            let merged = remote?.merging(local) ?? local
            let data = try merged.encoded()
            if let remote, try remote.encoded() == data {
                guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
                return merged
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defer { try? FileManager.default.removeItem(at: temporary) }
            record["payload"] = CKAsset(fileURL: temporary)
            record["schemaVersion"] = (merged.resetAt == nil ? 1 : 2) as CKRecordValue
            guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [],
                    savePolicy: .ifServerRecordUnchanged, atomically: false)
                guard let saved = result.saveResults[recordID] else { throw CloudProfileError.invalidProfile }
                _ = try saved.get()
                guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
                return merged
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Fetch the current change tag and merge again; never overwrite another device blindly.
                continue
            }
        }
        throw AppError.message("別の端末で更新されています。もう一度同期してください")
    }

    private func decode(_ record: CKRecord) throws -> CloudProfile? {
        guard record["payload"] != nil else {
            if record.recordChangeTag != nil { throw CloudProfileError.invalidProfile }
            return nil
        }
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
              let version = record["schemaVersion"] as? Int, [1, 2].contains(version) else {
            throw CloudProfileError.invalidProfile
        }
        let profile = try JSONDecoder().decode(CloudProfile.self, from: Data(contentsOf: url))
        guard profile.version == 1 else { throw CloudProfileError.invalidProfile }
        return profile
    }

    func profile(accountID expected: String) async throws -> CloudProfile? {
        let database = try configuredContainer().privateCloudDatabase
        guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
        return try decode(record)
    }

    func replaceWithDeletionMarker(_ marker: CloudProfile, accountID expected: String) async throws -> CloudProfile {
        let database = try configuredContainer().privateCloudDatabase
        for _ in 0..<3 {
            guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
            let record: CKRecord
            do { record = try await database.record(for: recordID) }
            catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: "IntoLUserProfile", recordID: recordID)
            }
            if let remote = try decode(record), let resetAt = remote.resetAt,
               resetAt >= (marker.resetAt ?? .distantPast) {
                guard remote.serverProfileID == marker.serverProfileID else { throw CloudProfileError.accountChanged }
                return remote
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try marker.encoded().write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defer { try? FileManager.default.removeItem(at: temporary) }
            record["payload"] = CKAsset(fileURL: temporary)
            record["schemaVersion"] = 2 as CKRecordValue
            guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
            do {
                let result = try await database.modifyRecords(saving: [record], deleting: [],
                    savePolicy: .ifServerRecordUnchanged, atomically: false)
                guard let saved = result.saveResults[recordID] else { throw CloudProfileError.invalidProfile }
                _ = try saved.get()
                guard try await accountID() == expected else { throw CloudProfileError.accountChanged }
                return marker
            } catch let error as CKError where error.code == .serverRecordChanged {
                continue
            }
        }
        throw AppError.message("別の端末で更新されています。もう一度削除を実行してください")
    }

    static func status(for error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .badContainer, .badDatabase, .missingEntitlement, .permissionFailure:
                return "CloudKitのコンテナ・署名・アクセス設定を確認してください。データは端末に保存しています"
            case .notAuthenticated: return CloudProfileError.signedOut.localizedDescription
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return "iCloudに接続できません。データは端末に保存し、次回の同期で再試行します"
            case .quotaExceeded: return "iCloudの空き容量を確認してください。データは端末に保存しています"
            default: break
            }
        }
        return error.localizedDescription
    }
}

enum CloudProfileCache {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudProfiles", isDirectory: true)
    }

    static var owner: String? {
        get { UserDefaults.standard.string(forKey: "cloudProfileOwner") }
        set { UserDefaults.standard.set(newValue, forKey: "cloudProfileOwner") }
    }

    private static func fileURL(owner: String?) -> URL {
        let key = SHA256.hash(data: Data((owner ?? "guest").utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    static func load(owner: String?) throws -> CloudProfile? {
        let url = fileURL(owner: owner)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CloudProfile.self, from: Data(contentsOf: url))
    }

    static func save(_ profile: CloudProfile, owner: String?) throws {
        var cached = profile
        // Server bearer credentials stay in Keychain locally; only the private CloudKit asset carries them.
        cached.serverCredentials = [:]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try cached.encoded().write(to: fileURL(owner: owner),
                                  options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(owner: String?) throws {
        let url = fileURL(owner: owner)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
