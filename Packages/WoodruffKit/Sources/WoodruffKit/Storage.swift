import Foundation
#if canImport(Security)
import Security
#endif

/// Secrets (pairing keys, LG client keys, the GitHub token) in the Keychain; everything else in UserDefaults.
public enum Keychain {
    static let service = "com.woodruff.family"
    /// Goes up with every write, so a watcher knows when to read again (writes all happen in this app).
    nonisolated(unsafe) public private(set) static var generation = 0
    /// Every item as last read or written here, so the same few aren't fetched again and again (see `KeychainCache`).
    static let cache = KeychainCache()

    /// A read that tells "not there" apart from "couldn't read just now" (a locked keychain): `ok` is false
    /// only for the latter, so a hiccup is never mistaken for a sign-out.
    public static func read(_ account: String) -> (value: String?, ok: Bool) {
        let kept = cache.value(account)
        if kept.hit { return (kept.value, true) }
        let stamp = cache.readStarted()
        let found = fetch(account)
        // Only an answer is kept: a read that couldn't be made is made again next time.
        if found.ok { cache.readFinished(account, found.value, since: stamp) }
        return found
    }

    /// The Keychain itself (`read` keeps what this finds).
    static func fetch(_ account: String) -> (value: String?, ok: Bool) {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return (nil, true) }
        guard status == errSecSuccess, let d = out as? Data else { return (nil, false) }
        return (String(data: d, encoding: .utf8), true)
        #else
        return (UserDefaults.standard.string(forKey: "kc." + account), true)
        #endif
    }

    public static func set(_ value: String?, for account: String) {
        // Nothing kept for it is handed out while it's written; what's there afterwards is kept only once the
        // write has gone through (one that didn't is read afresh next time).
        cache.writeStarted(account)
        defer { generation &+= 1 }
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let deleted = SecItemDelete(q as CFDictionary)
        let gone = deleted == errSecSuccess || deleted == errSecItemNotFound
        guard let value, !value.isEmpty else {
            cache.writeFinished(account, nil, ok: gone)
            return
        }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        cache.writeFinished(account, value, ok: added == errSecSuccess)
        #else
        UserDefaults.standard.set(value, forKey: "kc." + account)
        cache.writeFinished(account, value, ok: true)
        #endif
    }

    public static func get(_ account: String) -> String? {
        read(account).value
    }
}

/// What each Keychain item held when this app last read or wrote it. Only this app writes these items, and every
/// write goes through `Keychain.set`, which tells this, so what's kept stays true. A read that couldn't be made (a
/// locked keychain) is never kept, nor is anything after a write that didn't go through: both are read afresh next
/// time. "Not there" is believed only for `missingFor` seconds, so a stored item can never look missing for long.
final class KeychainCache: @unchecked Sendable {
    private struct Entry {
        var value: String?
        var at: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Goes up with every write: a read that began before one never keeps what it found (it may be the old value).
    private var writes = 0
    let missingFor: TimeInterval

    init(missingFor: TimeInterval = 30) {
        self.missingFor = missingFor
    }

    /// What's kept for [account] (`hit` false: it has to be read; `value` nil with `hit`: known not to be there).
    func value(_ account: String, now: Date = Date()) -> (hit: Bool, value: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[account] else { return (false, nil) }
        if e.value == nil && now.timeIntervalSince(e.at) >= missingFor {
            entries[account] = nil
            return (false, nil)
        }
        return (true, e.value)
    }

    /// Taken just before reading the Keychain, and handed back to `readFinished`.
    func readStarted() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    /// Keeps what a read found ([value] nil: not there), unless a write came in while it was reading.
    func readFinished(_ account: String, _ value: String?, since stamp: Int, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard writes == stamp else { return }
        entries[account] = Entry(value: value, at: now)
    }

    /// A write to [account] is about to begin: nothing kept for it is handed out until it's done.
    func writeStarted(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        writes &+= 1
        entries[account] = nil
    }

    /// The write is done: what's there now is [value] when it went through ([ok]); otherwise it's read afresh.
    func writeFinished(_ account: String, _ value: String?, ok: Bool, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        writes &+= 1
        entries[account] = ok ? Entry(value: value, at: now) : nil
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
