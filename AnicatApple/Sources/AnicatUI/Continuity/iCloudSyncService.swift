import Foundation
import Security

/// The AniList token's three homes, in the order they are read. The name
/// is historical: this once also wrapped `NSUbiquitousKeyValueStore` for
/// resume positions, which nothing ever called and which needs an iCloud
/// entitlement neither app target carries -- on iOS the store logged a
/// missing-entitlement complaint at every launch for a feature that did
/// not exist. The token itself never went through iCloud.
public final class iCloudSyncService: @unchecked Sendable {
    public static let shared = iCloudSyncService()

    private let serviceName = "com.anicat.auth"
    private let tokenAccount = "anilist_oauth_token"

    private init() {}

    // MARK: - Local Keychain & Config File (Zero-Login OAuth Token Persistence)

    private var configJSONURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Anicat", isDirectory: true).appendingPathComponent("config.json")
    }

    private var configTOMLURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Anicat", isDirectory: true).appendingPathComponent("config.toml")
    }

    /// Saves the AniList OAuth token to local Keychain and persists to ~/Library/Application Support/Anicat/config.json.
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

        // 2. Persist to ~/Library/Application Support/Anicat/config.json (matching Tauri config.rs)
        saveTokenToConfigFile(trimmed)
        saveTokenToTOMLFile(trimmed)

        return keychainSuccess || (loadTokenFromConfigFile() != nil)
    }

    /// Reads the AniList OAuth token, preferring the config file over the Keychain.
    ///
    /// The Keychain used to be the first stop. That item is access-controlled to
    /// the code signature that created it, and a debug binary is re-signed on
    /// every `swift build` — so each launch presented macOS with an app it did
    /// not recognise and popped "Anicat wants to use your confidential information
    /// stored in \"com.anicat.auth\"" every time. Reading the config file first
    /// (which `saveAniListToken` always writes) skips the Keychain at startup and
    /// the prompt with it; the Keychain stays as a last-resort fallback only.
    public func getAniListToken() -> String? {
        restrictTokenFiles()
        // 1. Config file first
        if let token = loadTokenFromConfigFile(), !token.isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Fallback: config.toml (migrated from Tauri)
        if let token = loadTokenFromTOMLFile(), !token.isEmpty {
            _ = saveAniListToken(token)
            return token
        }

        // 3. Last resort: local Keychain
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

        return nil
    }

    public func deleteAniListToken() {
        deleteAniListTokenFromKeychain()
        removeTokenFromConfigFile()
        removeTokenFromTOMLFile()
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
            writePrivate(data, to: fileURL)
        }
    }

    /// Writes `data` over `url` so the file is never readable by anyone but
    /// the owner, not even for an instant.
    ///
    /// The token is a bearer credential for the owner's AniList account.
    /// `Data.write(options: .atomic)` renames a fresh temp file into place at
    /// the umask default (0644), and every rewrite of `config.toml` did
    /// exactly that: a measured install had a live token in a world-readable
    /// file. The temp file is created 0600 and renamed, so the final path
    /// never has another mode.
    private func writePrivate(_ data: Data, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(
            atPath: tmp.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    /// Tightens files an older build wrote at 0644. Runs on every read of the
    /// token, because a file that already exists is not rewritten until the
    /// next sign-in, which may never come.
    private func restrictTokenFiles() {
        for url in [configJSONURL, configTOMLURL] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
            writePrivate(data, to: fileURL)
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
            writePrivate(Data(updated.utf8), to: fileURL)
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
        writePrivate(Data(updated.utf8), to: fileURL)
    }
}
