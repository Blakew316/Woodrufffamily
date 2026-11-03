import Foundation
#if canImport(Security)
import Security
#endif

/// Secrets (pairing keys, LG client keys, the GitHub token) in the Keychain; everything else in UserDefaults.
public enum Keychain {
    static let service = "com.woodruff.family"

    public static func set(_ value: String?, for account: String) {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        #else
        UserDefaults.standard.set(value, forKey: "kc." + account)
        #endif
    }

    public static func get(_ account: String) -> String? {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #else
        return UserDefaults.standard.string(forKey: "kc." + account)
        #endif
    }
}

/// A Codable value kept in UserDefaults as JSON.
public enum Saved {
    public static func load<T: Decodable>(_ key: String, as: T.Type = T.self) -> T? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    public static func save<T: Encodable>(_ key: String, _ value: T) {
        if let d = try? JSONEncoder().encode(value) { UserDefaults.standard.set(d, forKey: key) }
    }
}
