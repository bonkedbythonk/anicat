import Foundation
import Security

public final class iCloudSyncService: @unchecked Sendable {
    public static let shared = iCloudSyncService()

    private let kvStore = NSUbiquitousKeyValueStore.default
    private let serviceName = "com.anicat.auth"
    private let tokenAccount = "anilist_oauth_token"

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            self?.handleRemoteStoreChange()
        }
        kvStore.synchronize()
    }

    // MARK: - iCloud Keychain (Zero-Login OAuth Token Sync)

    /// Saves the AniList OAuth token to encrypted iCloud Keychain.
    /// Accessible immediately by iPhone, iPad, and Mac signed into the same Apple ID.
    public func saveAniListToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        // Remove existing item before adding
        deleteAniListToken()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true // Syncs across iCloud Keychain!
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Reads the AniList OAuth token from iCloud Keychain.
    public func getAniListToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        return token
    }

    public func deleteAniListToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecAttrSynchronizable as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Ubiquitous Key-Value Store (Resume History & Preferences)

    public func saveResumePosition(catalogId: Int64, episode: Int, positionSeconds: Double) {
        let key = "resume_\(catalogId)_\(episode)"
        kvStore.set(positionSeconds, forKey: key)
        kvStore.synchronize()
    }

    public func getResumePosition(catalogId: Int64, episode: Int) -> Double? {
        let key = "resume_\(catalogId)_\(episode)"
        let val = kvStore.double(forKey: key)
        return val > 0 ? val : nil
    }

    public func setSetting<T>(_ value: T, forKey key: String) {
        kvStore.set(value, forKey: key)
        kvStore.synchronize()
    }

    public func getSetting<T>(forKey key: String) -> T? {
        kvStore.object(forKey: key) as? T
    }

    private func handleRemoteStoreChange() {
        print("[iCloudSync] Remote settings / resume markers updated from another Apple device.")
    }
}
