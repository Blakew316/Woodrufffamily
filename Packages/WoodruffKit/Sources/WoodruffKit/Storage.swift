import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
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

    /// Writes [value] (nil or empty: removes it). True once it's done.
    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
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
            return gone
        }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        cache.writeFinished(account, value, ok: added == errSecSuccess)
        return added == errSecSuccess
        #else
        UserDefaults.standard.set(value, forKey: "kc." + account)
        cache.writeFinished(account, value, ok: true)
        return true
        #endif
    }

    public static func get(_ account: String) -> String? {
        read(account).value
    }
}

/// What each Keychain item held when this app last read or wrote it. Only this app writes these items, and every
/// write goes through `Keychain.set`, which tells this, so what's kept stays true. A read that couldn't be made (a
/// locked keychain) is never kept, nor is anything after a write that didn't go through: both are read afresh next
/// time. "Not there" is believed until a write here, or for `missingFor` seconds (ten minutes) at most, so an item
/// stored some other way can't look missing for long.
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

    init(missingFor: TimeInterval = 600) {
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

/// The family code: a random code made on the first device that syncs, and typed once on each of the family's other
/// devices (Settings → General → Sync Across Devices). The synced settings, peer messages and the Macs' alert relay
/// are sealed with a key made from it, so a pairing key heard on the Wi‑Fi no longer opens them.
///
/// It's 25 letters and digits (120 random bits and one check character), shown as five groups of five. Kept in this
/// device's Keychain only: it never travels with the synced settings.
public enum FamilyCode {
    /// The Keychain item (not one of the items that sync).
    public static let account = "family.code"
    /// Crockford's base 32: no I, L, O or U, so it reads and types without mix-ups.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let randomLength = 24

    /// What this device keeps: the code (25 characters, no dashes), when it was first made, and, for a code made here,
    /// until when it gives way to an older code found on a TV (two devices that both made one at the same moment).
    public struct Record: Codable, Equatable, Sendable {
        public var code: String
        public var created: Double
        public var provisionalUntil: Double
        public init(code: String, created: Double, provisionalUntil: Double = 0) {
            self.code = code; self.created = created; self.provisionalUntil = provisionalUntil
        }
    }

    /// A new code (25 characters, no dashes).
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()   // the system's secure random source
        let body = String((0..<randomLength).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] })
        return body + String(check(body))
    }

    /// [text] as typed (any case, spaces or dashes, O for 0, I or L for 1) as the code, or nil when it isn't one.
    public static func normalize(_ text: String) -> String? {
        var out = ""
        for ch in text.uppercased() {
            switch ch {
            case " ", "-", "\t", "\n": continue
            case "O": out.append("0")
            case "I", "L": out.append("1")
            case "U": out.append("V")
            default:
                guard alphabet.contains(ch) else { return nil }
                out.append(ch)
            }
        }
        guard out.count == randomLength + 1 else { return nil }
        let body = String(out.prefix(randomLength))
        return out.last == check(body) ? out : nil
    }

    /// "ABCDE-FGHJK-…" for showing.
    public static func formatted(_ code: String) -> String {
        var groups: [String] = []
        var s = Substring(code)
        while !s.isEmpty { groups.append(String(s.prefix(5))); s = s.dropFirst(5) }
        return groups.joined(separator: "-")
    }

    /// One check character, so a typo is caught before the code is used.
    static func check(_ body: String) -> Character {
        // Odd weights: any one wrong character changes it, and so do nearly all swaps of two neighbours.
        var sum = 0
        for (i, ch) in body.enumerated() {
            sum += (alphabet.firstIndex(of: ch) ?? 0) * (2 * i + 1)
        }
        return alphabet[sum % alphabet.count]
    }

    /// What's kept here: `ok` false when the Keychain can't be read just now (locked), so that's never taken for
    /// "no code".
    public static func load() -> (record: Record?, ok: Bool) {
        let r = Keychain.read(account)
        guard r.ok else { return (nil, false) }
        guard let text = r.value, let rec = try? JSONDecoder().decode(Record.self, from: Data(text.utf8)),
              normalize(rec.code) == rec.code else { return (nil, true) }
        return (rec, true)
    }

    /// Keeps [record] here (nil: forgets the code). True once it's saved.
    @discardableResult
    public static func save(_ record: Record?) -> Bool {
        guard let record else { return Keychain.set(nil, for: account) }
        guard let d = try? JSONEncoder().encode(record) else { return false }
        return Keychain.set(String(decoding: d, as: UTF8.self), for: account)
    }
}

#if canImport(CryptoKit)
public extension FamilyCode {
    /// The family key (32 bytes) made from [code].
    static func key(_ code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("woodruff-family-code".utf8),
                               info: Data("family-key".utf8), outputByteCount: 32)
    }

    /// The family key here, or nil when there's no code here (or it can't be read just now).
    static func savedKey() -> SymmetricKey? {
        load().record.map { key($0.code) }
    }

    /// Names the code without giving it away (8 bytes), so a device can tell which code a copy was sealed with.
    static func fingerprint(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("woodruff-family-fingerprint".utf8), using: key)).prefix(8)
    }

    /// A key for one use ([label]) made from the family key and [context] (a TV's pairing key, say).
    static func derive(_ key: SymmetricKey, _ label: String, _ context: String = "") -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(context.utf8), info: Data(label.utf8), outputByteCount: 32)
    }

    /// A short proof (hex, 16 bytes) that [message] comes from a device with the family key.
    static func tag(_ message: String, _ key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: derive(key, "woodruff-tag"))).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }
}
#endif

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
