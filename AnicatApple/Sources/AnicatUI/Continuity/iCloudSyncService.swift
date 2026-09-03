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

    // MARK: - Local Keychain & Config File (Zero-Login OAuth Token Persistence)

    private var configJSONURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AniCat", isDirectory: true).appendingPathComponent("config.json")
    }

    private var configTOMLURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AniCat", isDirectory: true).appendingPathComponent("config.toml")
    }

    /// Saves the AniList OAuth token to local Keychain and persists to ~/Library/Application Support/AniCat/config.json.
    public func saveAniListToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }

        // Remove existing Keychain items before adding
        deleteAniListTokenFromKeychain()

        // 1. Primary: Local Keychain (kSecAttrSynchronizable: false avoids errSecMissingEntitlement -34018)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false
        ]

        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: tokenAccount,
                kSecAttrSynchronizable as String: false
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        }
        let keychainSuccess = (status == errSecSuccess)
        if !keychainSuccess {
            print("[iCloudSyncService] Local keychain write returned status: \(status)")
        }

        // 2. Persist to ~/Library/Application Support/AniCat/config.json (matching Tauri config.rs)
        saveTokenToConfigFile(trimmed)
        saveTokenToTOMLFile(trimmed)

        return keychainSuccess || (loadTokenFromConfigFile() != nil)
    }

    /// Reads the AniList OAuth token from local Keychain, falling back to config.json or config.toml.
    public func getAniListToken() -> String? {
        // 1. Check local Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: false
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Fallback: Check config.json
        if let token = loadTokenFromConfigFile(), !token.isEmpty {
            // Restore to keychain for fast access
            _ = saveTokenToKeychain(token)
            return token
        }

        // 3. Fallback: Check config.toml (migrated from Tauri)
        if let token = loadTokenFromTOMLFile(), !token.isEmpty {
            // Save to both keychain and config.json
            _ = saveAniListToken(token)
            return token
        }

        return nil
    }

    public func deleteAniListToken() {
        deleteAniListTokenFromKeychain()
        removeTokenFromConfigFile()
        removeTokenFromTOMLFile()
    }

    private func saveTokenToKeychain(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        deleteAniListTokenFromKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false
        ]
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: tokenAccount,
                kSecAttrSynchronizable as String: false
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        }
        return status == errSecSuccess
    }

    private func deleteAniListTokenFromKeychain() {
        let localQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecAttrSynchronizable as String: false
        ]
        SecItemDelete(localQuery as CFDictionary)

        let syncQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: tokenAccount,
            kSecAttrSynchronizable as String: true
        ]
        SecItemDelete(syncQuery as CFDictionary)
    }

    private func saveTokenToConfigFile(_ token: String) {
        let fileURL = configJSONURL
        var json: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = obj
        }
        var apiDict = json["api"] as? [String: Any] ?? [:]
        apiDict["anilist_token"] = token
        json["api"] = apiDict
        json["anilist_token"] = token

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadTokenFromConfigFile() -> String? {
        let fileURL = configJSONURL
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let token = json["anilist_token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let api = json["api"] as? [String: Any] {
            if let token = api["anilist_token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let token = api["token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return token.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let anilist = json["anilist"] as? [String: Any],
           let token = anilist["token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func removeTokenFromConfigFile() {
        let fileURL = configJSONURL
        guard let existingData = try? Data(contentsOf: fileURL),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            return
        }
        json.removeValue(forKey: "anilist_token")
        if var apiDict = json["api"] as? [String: Any] {
            apiDict.removeValue(forKey: "anilist_token")
            apiDict.removeValue(forKey: "token")
            json["api"] = apiDict
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadTokenFromTOMLFile() -> String? {
        let fileURL = configTOMLURL
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: #"anilist_token\s*=\s*"([^"]+)""#) else {
            return nil
        }
        let nsString = contents as NSString
        let range = NSRange(location: 0, length: nsString.length)
        if let match = regex.firstMatch(in: contents, options: [], range: range),
           match.numberOfRanges > 1 {
            let tokenRange = match.range(at: 1)
            let token = nsString.substring(with: tokenRange).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
        return nil
    }

    private func saveTokenToTOMLFile(_ token: String) {
        let fileURL = configTOMLURL
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        guard let regex = try? NSRegularExpression(pattern: #"anilist_token\s*=\s*"[^"]*""#) else {
            return
        }
        let range = NSRange(location: 0, length: (contents as NSString).length)
        if regex.firstMatch(in: contents, options: [], range: range) != nil {
            let updated = regex.stringByReplacingMatches(in: contents, options: [], range: range, withTemplate: "anilist_token = \"\(token)\"")
            try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func removeTokenFromTOMLFile() {
        let fileURL = configTOMLURL
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        guard let regex = try? NSRegularExpression(pattern: #"anilist_token\s*=\s*"[^"]*""#) else {
            return
        }
        let range = NSRange(location: 0, length: (contents as NSString).length)
        let updated = regex.stringByReplacingMatches(in: contents, options: [], range: range, withTemplate: "anilist_token = \"\"")
        try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
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
