import Foundation
import Network
import CryptoKit
import Observation
import WoodruffKit
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Notification.Name {
    /// Settings from another of the family's devices were just taken in. `userInfo["keys"]` lists the UserDefaults
    /// and Keychain names that changed ([String]), for anything that keeps its own copy of one in memory.
    static let woodruffSettingsSynced = Notification.Name("WoodruffSettingsSynced")
}

/// Keeps everything the family sets (API keys, sign-ins, app keys, the paired TVs, names, rooms, the Home layout and
/// favourites, TV names, hidden alerts, alert choices, the Macs' tile sizes) the same on every iPhone and Mac.
///
/// Two ways, so it always gets there:
/// 1. **Kept on the TVs.** Every device keeps an encrypted copy of all of it on each TV it's paired with
///    (one small file). On opening, coming back, every 12 seconds, and right after any change, each device
///    reads every TV's copy at once, takes anything newer, and writes back to each TV whose copy is behind. The
///    TVs are always on, so a change reaches a device that was closed, away, or asleep the next time it opens.
/// 2. **Straight across the Wi‑Fi.** Devices open at the same time also hand changes to each other directly,
///    so they show within a couple of seconds.
/// The newest change to each item wins (entry by entry for lists of names and rooms, part by part for the Home
/// layout); a sign-out on one device signs out the others.
///
/// Both are sealed with the family code (`FamilyCode`): made on the first device to sync, kept in each device's
/// Keychain, and typed in once on every other device. A TV's pairing key (which its own requests carry on the
/// Wi‑Fi) is mixed in for the TVs' copies but never opens them alone.
@Observable @MainActor
final class SettingsSync {
    static let shared = SettingsSync()
    static let service = "_woodruffsync._tcp"
    /// The family's paired TVs (id → address, pairing key and name), so a TV paired on one device is paired on all.
    /// The settings here keep only addresses and names; the keys are in the Keychain (`saveFamilyPairings`).
    static let familyPairingsKey = "familyPairings"

    /// Keychain items that travel.
    static let keychainKeys = [
        "govee.key",
        "st.client", "st.secret", "st.access", "st.refresh", "st.expires", "st.token",
        "nest.project", "nest.client", "nest.secret", "nest.access", "nest.refresh", "nest.expires", "nest.scopes", "nest.subscription",
        "github.token", "dreo.email", "dreo.password", "deco.host", "deco.password",
        "cync.email", "cync.access", "cync.refresh", "cync.authorize", "cync.user", "cync.expires",
        "gdrive.client", "gdrive.secret", "gdrive.refresh", "gdrive.access", "gdrive.expires", "gdrive.scopes", "gdrive.email", "tmdb.key",
        "apns.key", "apns.keyid", "apns.team",
        // Google Photos and Calendar, signed in here and handed to the TVs (GoogleGrants).
        "gphotos.refresh", "gphotos.scopes", "gphotos.at", "gcal.refresh", "gcal.scopes", "gcal.at",
    ]
    /// Saved settings that travel (JSON in UserDefaults). Home's layout ("homeLayout": the tiles' order and sizes,
    /// Favorites, the room bar, what's hidden) is not one of them: each device keeps its own, so arranging Home on
    /// one changes nothing on the others.
    static let dataKeys = ["smartNames", "smartRooms", "smartExtraRooms", "goveeManualIPs", "extras", "hiddenAlerts", "pushTokens", "diagnostics",
                           "familyPairings", "atvRemote.paired", "smartSceneColors", "sonosRooms",
                           "scenes", "nestCameras"]
    /// Plain preferences that travel (property-list values in UserDefaults): alert choices, the remote's click, and
    /// Now Playing on the Lock Screen.
    static let valueKeys = ["watch.source", "nest.alert.person", "nest.alert.motion", "nest.alert.doorbell", "notifyFleet", "liveActivity", "remoteClick", "sonosSeed",
                            "scenes.filled", "vehicle.cameras", "vehicle.test", "vehicle.minConfidence", "vehicle.minChanged",
                            "vehicle.maxChanged", "watch.cellularDownloads", "camera.native", "cameraShare.hosts"]

    /// Saved settings kept entry by entry (one TV's name, one light's room, one paired TV), so two devices changing
    /// different entries at the same time both keep their change.
    static let entryKeys: Set<String> = ["ud:smartNames", "ud:smartRooms", "ud:extras", "ud:hiddenAlerts", "ud:pushTokens", "ud:diagnostics",
                                         "ud:familyPairings", "ud:atvRemote.paired", "ud:smartSceneColors"]

    /// "Saved on Living Room, Master Bedroom" for Settings.
    private(set) var status = "Not synced yet"
    private(set) var lastSynced: Date?
    /// The family code here, for Settings ("ABCDE-FGHJK-…"); nil when this device doesn't have it yet.
    private(set) var familyCode: String?
    /// The TVs keep the family's settings sealed with a code this device doesn't have: it's typed in here.
    private(set) var needsCode = false
    /// Some TVs keep settings sealed with another (older) family code than this device's.
    private(set) var otherCode = false

    static let enterCodeStatus = "Enter the family code from another device to sync."

    /// The family code as read here (see `currentFamily`).
    private struct Family {
        var record: FamilyCode.Record
        var key: SymmetricKey
        var fp: Data
        /// Seals what goes straight across the Wi‑Fi.
        var peerKey: SymmetricKey
        var created: UInt64 { UInt64(max(0, record.created)) }
    }
    @ObservationIgnored private var familyKept: Family?
    /// The codes the TVs' copies were sealed with at the last round (fingerprint → when the code was made), so a code
    /// typed in is checked against them.
    @ObservationIgnored private var seenCodes: [Data: UInt64] = [:]
    /// TVs whose copy from before the family code has been read (once) and replaced: never read the old way again.
    @ObservationIgnored private var legacyRead: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sync.legacyRead") ?? [])

    @ObservationIgnored private let me: String = {
        if let s = UserDefaults.standard.string(forKey: "sync.id") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "sync.id")
        return s
    }()
    @ObservationIgnored private var stamps: [String: Double] = (UserDefaults.standard.dictionary(forKey: "sync.stamps") as? [String: Double]) ?? [:]
    @ObservationIgnored private var entryStamps: [String: [String: Double]] =
        (UserDefaults.standard.dictionary(forKey: "sync.entryStamps") as? [String: [String: Double]]) ?? [:]
    /// Each key's value as last seen here, as text. A key that's missing hasn't been readable yet.
    @ObservationIgnored private var last: [String: String] = [:]
    @ObservationIgnored private weak var fleet: Fleet?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Something may have changed here since the last look (a saved setting or a keychain write).
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var seenGeneration = -1
    @ObservationIgnored private var lastLook = Date.distantPast
    @ObservationIgnored private var lastKeychainLook = Date.distantPast
    /// When the loop last started a round with the TVs.
    @ObservationIgnored private var lastTVRound = Date.distantPast
    /// The stamps as last written to UserDefaults (written again only when they've changed).
    @ObservationIgnored private var savedStamps: [String: Double]?
    @ObservationIgnored private var savedEntryStamps: [String: [String: Double]]?
    /// The TVs' copies as last read, so a round that finds the same bytes again does none of it twice: each TV's
    /// sealed copy with what it opened to, what each opened copy holds, and how things stood here when each was last
    /// merged in (changes noticed, settings kept).
    @ObservationIgnored private var openedBefore: [String: (box: Data, fp: Data, plain: Data)] = [:]
    @ObservationIgnored private var parsedBefore: [Data: [String: [String: Any]]] = [:]
    @ObservationIgnored private var mergedBefore: [Data: (changes: Int, kept: Int)] = [:]
    /// Changes noticed here so far, and whether a TV is still to get the latest of them.
    @ObservationIgnored private var changes = 0
    @ObservationIgnored private var unsaved = false
    /// Keys of a sign-in being tried here (see `settling`).
    @ObservationIgnored private var held: Set<String> = []
    /// The TVs paired here at the last look (tells one paired or forgotten here from one that came from the family).
    @ObservationIgnored private var hubsSeen: [String: Hub] = [:]
    /// `followAddresses`: when it last looked, the family's addresses this device has put right already, and whether
    /// an address from the family's list is being tried now.
    @ObservationIgnored private var addressLook = Date.distantPast
    @ObservationIgnored private var addressTold: [String: String] = [:]
    @ObservationIgnored private var addressTrying = false
    /// The app has been in the background since the last wake.
    @ObservationIgnored private var wasAway = false
    /// The starting point has been taken (`prepare`).
    @ObservationIgnored private var prepared = false

    // Kept on the TVs.
    @ObservationIgnored private var tvRun: Task<Void, Never>?
    @ObservationIgnored private var tvAgain = false
    /// Each "ud:" key's saved bytes and their text, as last read (the same bytes aren't parsed again).
    @ObservationIgnored private var parsed: [String: (Data, String)] = [:]
    @ObservationIgnored private var pushSoon: Task<Void, Never>?
    @ObservationIgnored private var folders: [String: String] = [:]
    /// Rounds in a row each TV couldn't be asked, and rounds its copy was listed but wouldn't come.
    @ObservationIgnored private var misses: [String: Int] = [:]
    @ObservationIgnored private var stuck: [String: Int] = [:]
    @ObservationIgnored private var runs = 0

    // Straight across the Wi‑Fi.
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerReady = false
    @ObservationIgnored private var listenTry = 0
    @ObservationIgnored private var listenFailures = 0
    @ObservationIgnored private var listenStarted = Date.distantPast
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browseTry = 0
    @ObservationIgnored private var peers: [String: NWEndpoint] = [:]
    #if os(iOS) || os(tvOS)
    @ObservationIgnored private var backgroundTasks: [UIBackgroundTaskIdentifier] = []
    #endif

    /// Takes what's here as the app opens as the starting point, before anything else at launch can write a setting
    /// that travels: whatever is written after this (a sign-in renewed as the app opens, a TV paired from a link, a
    /// TV's first answer) is a change made here, stamped as new and sent on once `start` runs. Taken later, such a
    /// write would count as old, and could lose to the family's older copy (a renewed sign-in put back to the one
    /// before it, which no longer works). Safe to call again: the starting point is taken once.
    func prepare(_ fleet: Fleet) {
        guard !prepared, !Demo.isOn else { return }
        prepared = true
        self.fleet = fleet
        _ = currentFamily()
        _ = loadFamilyPairings()   // keys still in the settings from before move to the Keychain
        seedPairings(fleet)
        last = snapshot(keychain: true)
        lastKeychainLook = Date()
        seenGeneration = Keychain.generation
        // Settings from before syncing began count as old: they fill in what's missing elsewhere but never
        // replace anything set on another device (a new device mustn't overwrite the family's names and rooms).
        for (k, v) in last where stamps[k] == nil && !v.isEmpty { stamps[k] = 1 }
        saveStamps()
        watch()
        watchSignIns()
    }

    /// Starts syncing: the other devices on the Wi‑Fi, the TVs' copies, and noticing changes here (a couple of seconds
    /// into launch, so the TVs are asked first). Everything changed since `prepare` is stamped as new on the first look.
    func start(_ fleet: Fleet) {
        guard loop == nil, !Demo.isOn else { return }
        prepare(fleet)
        listen()
        browse()
        lastTVRound = Date()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                // Only looks when something was saved (or every 30 s regardless), so it costs nothing at rest.
                if self.dirty || Keychain.generation != self.seenGeneration || Date().timeIntervalSince(self.lastLook) > 30 {
                    // The ten-minute look at the Keychain: its items are read in the background first. One that isn't
                    // there is asked of the Keychain afresh each time (a few milliseconds each, dozens of them, on the
                    // main thread): read here, the look finds them at hand.
                    if Date().timeIntervalSince(self.lastKeychainLook) > 600 {
                        let keys = self.allKeys().compactMap { $0.hasPrefix("kc:") ? String($0.dropFirst(3)) : nil }
                        await Task.detached(priority: .utility) { for k in keys { _ = Keychain.read(k) } }.value
                    }
                    self.check()
                }
                // Every 12 seconds while the app is in use, every minute while it isn't (the Mac's window hidden), apart,
                // so a TV taking its time never holds up noticing changes here. (A change made here goes at once.)
                // A round still running is left to finish: the next starts after it, once the time has passed.
                let every: TimeInterval = (self.fleet?.isActive ?? true) ? 12 : 60
                if self.tvRun == nil, Date().timeIntervalSince(self.lastTVRound) >= every - 0.1 {
                    self.lastTVRound = Date()
                    Task { await self.syncTVs() }
                }
            }
        }
        Task { await syncTVs() }
    }

    /// Back to the front: read the TVs' copies, look for the other devices again, swap everything.
    func wake() {
        guard loop != nil else { return }
        // Back from the background (where the system may have quietly closed it), or not listening: listen
        // afresh. The other devices then see this one appear and hand it everything they have.
        if wasAway || listener == nil || (!listenerReady && Date().timeIntervalSince(listenStarted) > 5) {
            listenFailures = 0
            listen()
        }
        wasAway = false
        browse()
        check()
        broadcast()
        // A round already running reads the TVs (another straight after it is only for a change made here).
        if tvRun == nil { Task { await syncTVs() } }
    }

    func syncNow() async { check(); await syncTVs(); broadcast() }

    private func watch() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            // The widgets' shared copy (another suite) isn't the family's settings.
            if let d = note.object as? UserDefaults, d !== UserDefaults.standard { return }
            MainActor.assumeIsolated { self?.dirty = true }
        })
        #if os(iOS) || os(tvOS)
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leaving() }
        })
        #elseif os(macOS)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wokeUp() }
        })
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// Into the background: whatever was just changed goes onto the TVs now, with a little time asked for to finish.
    private func leaving() {
        wasAway = true
        guard loop != nil else { return }
        check()
        guard unsaved else { return }
        let id = holdBackground()
        Task {
            await syncTVs()
            endBackground(id)
        }
    }

    private func holdBackground() -> UIBackgroundTaskIdentifier {
        let id = UIApplication.shared.beginBackgroundTask(withName: "Woodruff settings sync") { [weak self] in
            MainActor.assumeIsolated { self?.endBackground(nil) }
        }
        if id != .invalid { backgroundTasks.append(id) }
        return id
    }

    /// Ends [id] (nil: every one still held).
    private func endBackground(_ id: UIBackgroundTaskIdentifier?) {
        let ending = backgroundTasks.filter { id == nil || $0 == id }
        backgroundTasks.removeAll { id == nil || $0 == id }
        for t in ending { UIApplication.shared.endBackgroundTask(t) }
    }
    #endif

    #if os(macOS)
    /// The Mac woke from sleep: once the Wi‑Fi is back, listen and look again, and swap everything.
    private func wokeUp() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard loop != nil else { return }
            listenFailures = 0
            listen()
            wake()
        }
    }
    #endif

    // MARK: What's here

    /// The current value as text, or nil when it can't be read just now (a locked keychain): then the last
    /// known value stands, so a hiccup never reads as a sign-out.
    private func canonical(_ key: String) -> String? {
        let name = String(key.dropFirst(3))
        if key.hasPrefix("kc:") {
            let r = Keychain.read(name)
            return r.ok ? (r.value ?? "") : nil
        }
        guard let obj = UserDefaults.standard.object(forKey: name) else { return "" }
        if name == Self.familyPairingsKey {
            // With each TV's key from the Keychain (the settings keep only addresses and names).
            guard let list = loadFamilyPairings() else { return nil }
            guard let d = try? JSONEncoder().encode(list), let o = try? JSONSerialization.jsonObject(with: d) else { return "" }
            return SyncMerge.canonical(o) ?? ""
        }
        if key.hasPrefix("ud:") {
            guard let d = obj as? Data else { parsed[key] = nil; return "" }
            if let p = parsed[key], p.0 == d { return p.1 }
            guard let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { parsed[key] = nil; return "" }
            let text = SyncMerge.canonical(o) ?? ""
            parsed[key] = (d, text)
            return text
        }
        return SyncMerge.canonical(obj) ?? ""
    }

    /// Every key that travels, including each LG TV's sign-in (so a TV paired on one device works on all).
    private func allKeys() -> [String] {
        var out = Self.keychainKeys.map { "kc:" + $0 } + Self.dataKeys.map { "ud:" + $0 } + Self.valueKeys.map { "uv:" + $0 }
        var lg = Set((fleet?.tvs ?? []).map { "kc:lg.\($0.id)" })
        for k in stamps.keys where k.hasPrefix("kc:lg.") { lg.insert(k) }
        out += lg.sorted()
        return out
    }

    /// What's here now. A key that can't be read just now keeps its last value; one never readable yet is left
    /// out until it can be (so a keychain that was locked at launch never reads as a change when it opens).
    /// The keychain is read only after a write to it (every write goes through `Keychain`) or now and then.
    private func snapshot(keychain: Bool) -> [String: String] {
        var out: [String: String] = [:]
        for k in allKeys() {
            if let old = last[k], settling(k) || (!keychain && k.hasPrefix("kc:")) {
                out[k] = old
                if settling(k) { held.insert(k) }
                continue
            }
            if let v = canonical(k) ?? last[k] { out[k] = v }
        }
        return out
    }

    /// An item's age: its stamp, or never if it has no value and no stamp.
    private func stamp(_ k: String) -> Double { stamps[k] ?? ((last[k] ?? "").isEmpty ? 0 : 1) }

    /// A sign-in being tried here right now. Dreo and the Deco keep a new password while they try it and take it
    /// away again if it doesn't work: what they hold meanwhile isn't the family's, so it neither goes out nor
    /// gets replaced until the try is over.
    private func settling(_ k: String) -> Bool {
        (k.hasPrefix("kc:dreo.") && Dreo.shared.busy) || (k.hasPrefix("kc:deco.") && DecoWifi.shared.busy)
    }

    /// Notes a sign-in starting there the moment it does (a quick failure could otherwise come and go between looks).
    private func watchSignIns() {
        withObservationTracking {
            _ = Dreo.shared.busy
            _ = DecoWifi.shared.busy
        } onChange: { [weak self] in
            Task { @MainActor in self?.signInsChanged() }
        }
    }

    private func signInsChanged() {
        if Dreo.shared.busy { held.formUnion(["kc:dreo.email", "kc:dreo.password"]) }
        if DecoWifi.shared.busy { held.formUnion(["kc:deco.host", "kc:deco.password"]) }
        watchSignIns()
    }

    /// Notices changes made here, stamps them, and sends them on.
    private func check() {
        // The Keychain is read again only after a write to it (every write goes through `Keychain`, which bumps its
        // generation), while an item that travels has never been readable yet (a keychain locked at launch), and every
        // 10 minutes regardless.
        let readKeychain = Keychain.generation != seenGeneration || keychainUnread() || Date().timeIntervalSince(lastKeychainLook) > 600
        dirty = false
        seenGeneration = Keychain.generation
        lastLook = Date()
        if readKeychain { lastKeychainLook = lastLook }
        notePairings()
        var now = snapshot(keychain: readKeychain)
        // A sign-in tried here that didn't work (Dreo and the Deco take the password away again when it fails) is this
        // device's own business, not the family's: nothing of it goes out (no wrong address, no sign-out for
        // everyone), and this device goes back to the family's sign-in, which keeps working here.
        for prefix in ["kc:dreo.", "kc:deco."] {
            let tried = held.filter { $0.hasPrefix(prefix) && !settling($0) }
            guard tried.contains(where: { (now[$0] ?? "").isEmpty && !(last[$0] ?? "").isEmpty }) else { continue }
            for k in tried {
                if let old = last[k], now[k] != old { write(k, old); now[k] = old }
            }
        }
        var changed = false
        var stamped = false
        let t = SyncMerge.stampNow()
        for (k, v) in now where last[k] != v {
            if let old = last[k] {
                stamps[k] = t
                if Self.entryKeys.contains(k) {
                    entryStamps[k] = SyncMerge.stampEntries(old: old, new: v, stamps: entryStamps[k] ?? [:], now: t)
                }
                changed = true
            } else if !v.isEmpty && stamps[k] == nil {
                stamps[k] = 1   // a key that just started travelling (a newly added TV) counts as old
                stamped = true
            }
        }
        held = held.filter { settling($0) }
        last = now
        if changed || stamped { saveStamps() }
        guard changed else { return }
        changes += 1
        unsaved = true
        broadcast()
        // Onto the TVs straight away (a moment later, so a burst of edits goes as one).
        pushSoon?.cancel()
        pushSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncTVs()
        }
    }

    /// An item that travels hasn't been readable yet (it's left out of `last` until it is).
    private func keychainUnread() -> Bool {
        allKeys().contains { $0.hasPrefix("kc:") && last[$0] == nil }
    }

    /// Written only when they changed: this runs after every TV's copy is read, and each write is a change to the
    /// settings here (which sends `check` looking again).
    private func saveStamps() {
        if savedStamps != stamps {
            UserDefaults.standard.set(stamps, forKey: "sync.stamps")
            savedStamps = stamps
        }
        if savedEntryStamps != entryStamps {
            UserDefaults.standard.set(entryStamps, forKey: "sync.entryStamps")
            savedEntryStamps = entryStamps
        }
    }

    // MARK: The paired TVs

    /// One paired TV as the family's list keeps it (and as it travels, sealed, in the synced settings).
    private struct FamilyHub: Codable, Equatable {
        var base: String
        var key: String
        var name: String
    }

    /// One paired TV as the settings here keep it: its address and name. Its key is in the Keychain
    /// (`familyKeyAccount`); `key` is only there in a list from before that (moved on the next read), or when the
    /// Keychain wouldn't take it.
    private struct FamilyHubSaved: Codable {
        var base: String
        var name: String
        var key: String?
    }

    /// Where the family's list keeps a TV's key. Not one of the Keychain items that sync on their own: it travels
    /// inside the family's list.
    private static func familyKeyAccount(_ id: String) -> String { "family.hub." + id }

    /// The family's list, keys and all; nil when a key can't be read just now (a locked Keychain).
    private func loadFamilyPairings() -> [String: FamilyHub]? {
        guard let saved = Saved.load(Self.familyPairingsKey, as: [String: FamilyHubSaved].self) else { return [:] }
        var out: [String: FamilyHub] = [:]
        var move = false
        for (id, s) in saved {
            if let k = s.key, !k.isEmpty {
                move = true
                out[id] = FamilyHub(base: s.base, key: k, name: s.name)
                continue
            }
            let r = Keychain.read(Self.familyKeyAccount(id))
            guard r.ok else { return nil }
            out[id] = FamilyHub(base: s.base, key: r.value ?? "", name: s.name)
        }
        // Keys from before they were kept in the Keychain go there now, out of the settings.
        if move { saveFamilyPairings(out) }
        return out
    }

    /// Keeps the family's list: addresses and names in the settings, keys in the Keychain.
    private func saveFamilyPairings(_ list: [String: FamilyHub]) {
        let before = Saved.load(Self.familyPairingsKey, as: [String: FamilyHubSaved].self) ?? [:]
        var saved: [String: FamilyHubSaved] = [:]
        for (id, f) in list {
            let account = Self.familyKeyAccount(id)
            let kept: Bool
            if f.key.isEmpty {
                kept = Keychain.get(account) == nil || Keychain.set(nil, for: account, now: true)
            } else {
                // (Written before answering: a key the Keychain wouldn't take has to stay in the settings.)
                kept = Keychain.get(account) == f.key || Keychain.set(f.key, for: account, now: true)
            }
            // Only a key the Keychain wouldn't take stays in the settings (so it's never lost).
            saved[id] = FamilyHubSaved(base: f.base, name: f.name, key: kept || f.key.isEmpty ? nil : f.key)
        }
        for id in before.keys where list[id] == nil { Keychain.set(nil, for: Self.familyKeyAccount(id)) }
        Saved.save(Self.familyPairingsKey, saved)
    }

    /// The first time: the family's list starts as the TVs paired here (as old, so it fills in and never replaces).
    private func seedPairings(_ fleet: Fleet) {
        hubsSeen = Dictionary(fleet.hubs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard UserDefaults.standard.object(forKey: Self.familyPairingsKey) == nil else { return }
        var list: [String: FamilyHub] = [:]
        for h in fleet.hubs where !h.connection.key.isEmpty {
            list[h.id] = FamilyHub(base: h.connection.base.absoluteString, key: h.connection.key, name: h.name)
        }
        saveFamilyPairings(list)
    }

    /// A TV paired (or paired again) here since the last look goes into the family's list, and one forgotten here
    /// comes out of it; from there it reaches every device.
    /// A TV's address in the family's list and the one this device talks to it at, kept together. A TV that moved was
    /// followed only by the devices that heard it at its new address: the list kept the old one (only a new key ever
    /// changed an entry), and a device that didn't hear the TV there went on calling the old address, with the TV
    /// and every TV it passes on "not answering" on that device for good.
    /// - This device reaches the TV at a home address the list doesn't have: the list takes it (once per address the
    ///   list had: two devices that each reach a TV at an address of their own never write it back and forth).
    /// - This device's address has stopped answering and the list has another home address: tried (`adoptAddress`).
    private func followAddresses() {
        guard let fleet, !addressTrying, Date().timeIntervalSince(addressLook) > 30 else { return }
        addressLook = Date()
        guard var list = loadFamilyPairings() else { return }
        var changed = false
        var tries: [(String, URL)] = []
        for h in fleet.hubs where !h.connection.key.isEmpty {
            guard let f = list[h.id], f.key == h.connection.key, f.base != h.connection.base.absoluteString,
                  let theirs = URL(string: f.base),
                  Fleet.isHomeAddress(h.connection.base.host), Fleet.isHomeAddress(theirs.host) else { continue }
            if fleet.isAnswering(h.id), fleet.tv(h.id)?.online == true {
                guard addressTold[h.id] != f.base else { continue }
                addressTold[h.id] = f.base
                list[h.id] = FamilyHub(base: h.connection.base.absoluteString, key: h.connection.key, name: f.name)
                changed = true
            } else if !fleet.isAnswering(h.id) {
                tries.append((h.id, theirs))
            }
        }
        if changed { saveFamilyPairings(list) }
        guard !tries.isEmpty else { return }
        addressTrying = true
        Task {
            for (id, base) in tries { await fleet.adoptAddress(base, forHub: id) }
            self.addressTrying = false
        }
    }

    private func notePairings() {
        followAddresses()
        guard let fleet else { return }
        let now = Dictionary(fleet.hubs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard now != hubsSeen, var list = loadFamilyPairings() else { return }
        let before = list
        for (id, h) in now where !h.connection.key.isEmpty {
            let was = hubsSeen[id]
            guard was == nil || was?.connection.key != h.connection.key || was?.addedAt != h.addedAt else { continue }
            list[id] = FamilyHub(base: h.connection.base.absoluteString, key: h.connection.key, name: h.name)
        }
        // Forgetting every TV here (starting over) isn't the family forgetting them: only one forgotten while others
        // stay comes out of the list.
        if !now.isEmpty {
            for id in hubsSeen.keys where now[id] == nil { list[id] = nil }
        }
        hubsSeen = now
        if list != before { saveFamilyPairings(list) }
    }

    /// The family's list changed on another device: a TV paired there is paired here too (with the same key), one
    /// forgotten there is forgotten here, and one paired again there with a new key takes the new key here.
    private func applyPairings() {
        guard let fleet, let list = loadFamilyPairings() else { return }
        var add: [Hub] = []
        var renew: [Hub] = []
        for (id, f) in list where !f.key.isEmpty {
            if let have = fleet.hub(id) {
                // At the address this device already uses (it may reach the TV another way).
                if have.connection.key != f.key { renew.append(Hub(id: id, name: have.name, connection: TVConnection(base: have.connection.base, key: f.key))) }
            } else if let base = URL(string: f.base) {
                add.append(Hub(id: id, name: f.name, connection: TVConnection(base: base, key: f.key)))
            }
        }
        let gone = fleet.hubs.map(\.id).filter { list[$0] == nil }
        let selected = fleet.selectedID
        // Never down to no TVs from here: the family's settings are read through them.
        if !gone.isEmpty && gone.count < fleet.hubs.count + add.count {
            for id in gone { fleet.unpair(id) }
        }
        for h in renew { fleet.unpair(h.id) }
        if !add.isEmpty || !renew.isEmpty { fleet.restorePairings(add + renew) }
        if let selected, fleet.selectedID != selected, fleet.hub(selected) != nil || fleet.tv(selected) != nil { fleet.selectedID = selected }
        hubsSeen = Dictionary(fleet.hubs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The new TVs learn this phone or Mac (for announcements to it).
        if !add.isEmpty || !renew.isEmpty { Task { await fleet.sayHelloEverywhere() } }
    }

    // MARK: Taking newer settings in

    /// Takes whatever is newer in [items]; returns whether ours has anything newer than theirs.
    /// [checked]: `check` has just run (a TV round looks once, not once per TV).
    @discardableResult
    private func apply(_ items: [String: [String: Any]], checked: Bool = false) -> Bool {
        if !checked { check() }   // a change made here a moment ago is stamped before anything is compared
        let before = last
        var written: Set<String> = []
        var oursNewer = false
        for (k, item) in items where k.hasPrefix("kc:") || k.hasPrefix("ud:") || k.hasPrefix("uv:") {
            guard last[k] != nil || k.hasPrefix("kc:lg.") else { continue }   // not something this version keeps (or can read yet)
            guard !settling(k) else { continue }                               // a sign-in being tried here: once it's over
            let t = (item["t"] as? NSNumber)?.doubleValue ?? 0
            let v = item["v"] as? String ?? ""
            let local = last[k] ?? ""
            let mine = stamp(k)

            if Self.entryKeys.contains(k) {
                let theirs = (item["e"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
                let ours = entryStamps[k] ?? [:]
                let l = local.isEmpty ? "{}" : local
                let r = v.isEmpty ? "{}" : v
                let m = SyncMerge.mergeEntries(local: l, localStamps: ours, remote: r, remoteStamps: theirs)
                let mergedValue = m.value == "{}" && local.isEmpty ? "" : m.value
                if mergedValue != local { write(k, mergedValue); last[k] = mergedValue; written.insert(k) }
                entryStamps[k] = m.stamps
                stamps[k] = max(mine, t)
                if m.value != r || m.stamps != theirs { oursNewer = true }
                continue
            }

            // Newer wins. On a tie with different values (two old copies), every device picks the same one.
            let takeTheirs = t > mine || (t == mine && v != local && (local.isEmpty || (!v.isEmpty && v > local)))
            if takeTheirs {
                if v != local { write(k, v); last[k] = v; written.insert(k) }
                stamps[k] = t
            } else if v != local {
                oursNewer = true
            }
        }
        for (k, v) in last where items[k] == nil && !v.isEmpty { oursNewer = true }
        saveStamps()
        if !written.isEmpty { reload(written, was: before) }
        return oursNewer
    }

    private func write(_ k: String, _ v: String) {
        let key = String(k.dropFirst(3))
        if k == "ud:" + Self.familyPairingsKey {
            // Keys into the Keychain, addresses and names into the settings.
            let o = SyncMerge.object(v) as? [String: Any] ?? [:]
            var list: [String: FamilyHub] = [:]
            for (id, e) in o {
                guard let e = e as? [String: Any] else { continue }
                list[id] = FamilyHub(base: e["base"] as? String ?? "", key: e["key"] as? String ?? "", name: e["name"] as? String ?? "")
            }
            saveFamilyPairings(list)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        } else if k.hasPrefix("kc:") {
            Keychain.set(v.isEmpty ? nil : v, for: key)
        } else if v.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if k.hasPrefix("ud:") {
            UserDefaults.standard.set(Data(v.utf8), forKey: key)
        } else if let o = SyncMerge.object(v) {
            UserDefaults.standard.set(o, forKey: key)
        }
    }

    /// Only the parts that read what changed pick it up (a synced token refresh doesn't restart everything).
    /// [before]: the values from just before they were taken in.
    private func reload(_ keys: Set<String>, was before: [String: String]) {
        func any(_ prefixes: [String]) -> Bool { keys.contains { k in prefixes.contains { k.hasPrefix($0) } } }
        if any(["ud:smartNames", "ud:smartRooms", "ud:smartExtraRooms", "ud:goveeManualIPs", "ud:smartSceneColors", "ud:sonosRooms"]) { SmartHome.shared.reloadSaved() }
        if keys.contains("ud:scenes") { SceneStore.shared.reload() }
        if any(["kc:gphotos.", "kc:gcal."]), let fleet { Task { await GoogleGrants.handOut(fleet) } }
        if keys.contains("ud:nestCameras") { NestCameras.shared.reloadSaved() }
        if keys.contains("ud:familyPairings") { applyPairings() }
        if any(["ud:extras", "ud:hiddenAlerts", "kc:lg."]) { fleet?.reloadSynced() }
        if keys.contains("ud:pushTokens") { PushRelay.shared.reloadTokens() }
        if any(["kc:apns."]) { PushRelay.shared.keysChanged() }
        #if os(macOS)
        if keys.contains("uv:vehicle.cameras") { VehicleWatch.shared.start() }
        #endif
        #if os(macOS)
        // Another device's crash and freeze reports: into this Mac's log of everyone's.
        if keys.contains("ud:diagnostics") { Diagnostics.shared.writeFamilyLog() }
        #endif
        // What the reloads saved back is the same settings (anything else they changed counts as a change made here).
        for k in keys { if let v = canonical(k) { last[k] = v } }
        NotificationCenter.default.post(name: .woodruffSettingsSynced, object: nil, userInfo: ["keys": keys.map { String($0.dropFirst(3)) }.sorted()])

        // Sign-ins: only a new account or key (not a routine token refresh from another device) restarts a service,
        // and a sign-out on another device signs this one out too.
        func has(_ k: String) -> Bool { !(last[k] ?? "").isEmpty }
        func had(_ k: String) -> Bool { !(before[k] ?? "").isEmpty }
        let goveeKey = keys.contains("kc:govee.key")
        let stIn = (has("kc:st.refresh") || has("kc:st.token"))
            && (any(["kc:st.client", "kc:st.secret", "kc:st.token"]) || (keys.contains("kc:st.refresh") && !had("kc:st.refresh")))
        let stOut = (had("kc:st.refresh") || had("kc:st.token")) && !has("kc:st.refresh") && !has("kc:st.token")
        let nestIn = has("kc:nest.refresh")
            && (any(["kc:nest.project", "kc:nest.client", "kc:nest.secret", "kc:nest.scopes"]) || (keys.contains("kc:nest.refresh") && !had("kc:nest.refresh")))
        let nestOut = had("kc:nest.refresh") && !has("kc:nest.refresh")
        let dreoIn = any(["kc:dreo."]) && has("kc:dreo.email") && has("kc:dreo.password")
        let dreoOut = had("kc:dreo.email") && had("kc:dreo.password") && !(has("kc:dreo.email") && has("kc:dreo.password"))
        // Cync: a new sign-in elsewhere (not a token refresh) starts it here; a sign-out there signs this one out.
        let cyncIn = keys.contains("kc:cync.authorize") && has("kc:cync.authorize") && has("kc:cync.access")
        let cyncOut = had("kc:cync.authorize") && !has("kc:cync.authorize")
        let decoIn = any(["kc:deco."]) && has("kc:deco.password")
        let decoOut = had("kc:deco.password") && !has("kc:deco.password")
        let github = keys.contains("kc:github.token")
        if stOut { SmartThings.shared.signOut() }
        if nestOut { NestCameras.shared.signOut() }
        if dreoOut { Dreo.shared.signOut() }
        if cyncOut { Cync.shared.signOut() }
        if cyncIn { Cync.shared.start() }
        if decoOut { DecoWifi.shared.signOut() }
        if nestIn { NestCameras.shared.start() }   // loads the cameras and keeps them up to date
        guard goveeKey || stIn || dreoIn || decoIn || github else { return }
        let tvs = self.fleet
        Task {
            if goveeKey { await SmartHome.shared.refreshCloud() }
            if stIn { await SmartThings.shared.refresh(full: true) }
            if dreoIn { Dreo.shared.start(); await Dreo.shared.refresh(full: true) }
            if decoIn { DecoWifi.shared.start(); await DecoWifi.shared.refresh() }
            if github { await tvs?.checkReleases() }
        }
    }

    private func items() -> [String: Any] {
        var items: [String: Any] = [:]
        for (k, v) in last {
            let t = stamp(k)
            if v.isEmpty && t == 0 { continue }   // never set anywhere: nothing to say
            var item: [String: Any] = ["v": v, "t": t]
            if Self.entryKeys.contains(k), let e = entryStamps[k], !e.isEmpty { item["e"] = e }
            items[k] = item
        }
        return items
    }

    // MARK: 1. Kept on the TVs

    /// One TV's copy as read.
    private struct TVCopy: Sendable {
        var folder: String
        /// The copy's file as it came (sealed); nil when there's none yet or it didn't come (it's replaced).
        var raw: Data?
        /// A file is there (one that can't be read is replaced).
        var exists: Bool
    }

    /// A copy sealed with a family code starts with this, the code's fingerprint (8 bytes) and when the code was made
    /// (8 bytes, seconds). A copy from before the family code is only the sealed box.
    private static let copyMagic = Data("WFS2".utf8)

    private struct CopyHead {
        var fp: Data
        var created: UInt64
        var box: Data
    }

    private static func head(_ raw: Data) -> CopyHead? {
        let b = [UInt8](raw)
        guard b.count > 20 + 28, Data(b[0..<4]) == copyMagic else { return nil }
        var t: UInt64 = 0
        for x in b[12..<20] { t = t << 8 | UInt64(x) }
        return CopyHead(fp: Data(b[4..<12]), created: t, box: Data(b[20...]))
    }

    private static func sealCopy(_ plain: Data, _ fam: Family, with key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.seal(plain, using: key).combined else { return nil }
        var out = copyMagic
        out.append(fam.fp)
        let t = fam.created
        for i in (0..<8).reversed() { out.append(UInt8(truncatingIfNeeded: t >> UInt64(i * 8))) }
        out.append(box)
        return out
    }

    private static func open(_ d: Data, _ key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Whether a copy's code is older than this device's (the older code is the family's; on the same second, the
    /// lower fingerprint), so every device settles on the same one.
    private static func older(_ h: CopyHead, than fam: Family) -> Bool {
        h.created != fam.created ? h.created < fam.created : h.fp.lexicographicallyPrecedes(fam.fp)
    }

    /// A TV's copy is sealed with a key made from the family code and the TV's pairing key: the pairing key alone
    /// (which the TV's own requests carry) no longer opens it.
    private func storeKey(_ hub: Hub, _ fam: Family) -> SymmetricKey {
        FamilyCode.derive(fam.key, "woodruff-settings-store", hub.connection.key)
    }

    /// How copies were sealed before the family code (read once from each TV, then replaced).
    private func legacyStoreKey(_ hub: Hub) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("woodruff-settings-store:\(hub.connection.key)".utf8)))
    }

    // MARK: The family code

    /// The family code here, read again only when it changed. `ok` false when the Keychain can't be read just now
    /// (then the code last read, if any, is used).
    private func currentFamily() -> (family: Family?, ok: Bool) {
        let l = FamilyCode.load()
        guard l.ok else { return (familyKept, false) }
        guard let rec = l.record else {
            familyKept = nil
            showCode(nil)
            return (nil, true)
        }
        if let f = familyKept, f.record == rec { return (f, true) }
        let key = FamilyCode.key(rec.code)
        let f = Family(record: rec, key: key, fp: FamilyCode.fingerprint(key), peerKey: FamilyCode.derive(key, "woodruff-settings-sync"))
        familyKept = f
        showCode(rec.code)
        return (f, true)
    }

    private func showCode(_ code: String?) {
        let shown = code.map { FamilyCode.formatted($0) }
        if familyCode != shown { familyCode = shown }
    }

    /// The first device to sync since the family code came makes it. For ten minutes it gives way to an older one
    /// found on a TV (another device made one at the same moment).
    private func makeCode() -> Family? {
        let now = Date().timeIntervalSince1970.rounded(.down)
        guard FamilyCode.save(FamilyCode.Record(code: FamilyCode.generate(), created: now, provisionalUntil: now + 600)) else { return nil }
        return currentFamily().family
    }

    /// Takes the family code typed in here (from another device's Settings). Nil once it's taken; otherwise what's
    /// wrong with it.
    func enter(code text: String) -> String? {
        guard let code = FamilyCode.normalize(text) else { return "That isn’t a family code. Check it and try again." }
        let fp = FamilyCode.fingerprint(FamilyCode.key(code))
        // Checked against the codes the TVs' copies were sealed with, when there are any.
        if !seenCodes.isEmpty && seenCodes[fp] == nil { return "That code doesn’t match your TVs. Check it on another device." }
        let created = seenCodes[fp].map { Double($0) } ?? Date().timeIntervalSince1970.rounded(.down)
        guard FamilyCode.save(FamilyCode.Record(code: code, created: created)) else { return "The code couldn’t be saved. Try again." }
        _ = currentFamily()
        needsCode = false
        otherCode = false
        status = "Syncing…"
        Task { await syncNow() }
        return nil
    }

    /// Reads every TV's copy, takes what's newer, and writes back to each TV whose copy is behind. One round at a
    /// time; asked during one (a change made here), another follows straight after it.
    func syncTVs() async {
        if let running = tvRun {
            tvAgain = true
            await running.value
            return
        }
        let run = Task { await self.syncTVsOnce() }
        tvRun = run
        await run.value
        tvRun = nil
        if tvAgain {
            tvAgain = false
            await syncTVs()
        }
    }

    private func syncTVsOnce() async {
        guard let fleet, !fleet.hubs.isEmpty else { return }
        #if os(iOS) || os(tvOS)
        // Time to finish is asked for only away from the front (going there, `leaving` asks for its own).
        let bg = UIApplication.shared.applicationState == .active ? nil : holdBackground()
        defer { if let bg { endBackground(bg) } }
        #endif
        runs += 1
        let hubs = fleet.hubs
        // 1. Every TV's copy, all at once (one that's off never holds up the others).
        var copies: [String: TVCopy] = [:]
        await withTaskGroup(of: (String, TVCopy?).self) { g in
            for hub in hubs {
                g.addTask {
                    let copy = await self.read(hub)
                    return (hub.id, copy)
                }
            }
            for await (id, copy) in g {
                if let copy { copies[id] = copy }
            }
        }
        // Which family code each copy is sealed with (none: from before the family code).
        var heads: [String: CopyHead] = [:]
        for (id, copy) in copies {
            if let raw = copy.raw, let h = Self.head(raw) { heads[id] = h }
        }
        if !heads.isEmpty {
            seenCodes = [:]
            for h in heads.values { seenCodes[h.fp] = min(seenCodes[h.fp] ?? h.created, h.created) }
        }
        let here = currentFamily()
        guard here.ok else { return }   // the Keychain can't be read just now: next round
        if here.family == nil {
            // No code here. The TVs already keep the family's settings sealed with one: it's typed in from another
            // device. None does yet: this is the first device to sync since the family code came, and makes it.
            guard heads.isEmpty else {
                needsCode = true
                status = Self.enterCodeStatus
                return
            }
            guard copies.values.contains(where: { $0.raw != nil || !$0.exists }) else {
                status = "Can’t reach a TV right now. Changes are kept here and saved when one answers."
                return
            }
        }
        guard let fam = here.family ?? makeCode() else { return }
        needsCode = false
        // Another device made a code at the same moment as this one: the newer code gives way (and this device is
        // given the family's code like any other).
        let foreign = heads.filter { $0.value.fp != fam.fp }
        if fam.record.provisionalUntil > Date().timeIntervalSince1970, foreign.values.contains(where: { Self.older($0, than: fam) }) {
            FamilyCode.save(nil)
            _ = currentFamily()
            needsCode = true
            status = Self.enterCodeStatus
            return
        }
        // 2. Whatever is newer in any of them comes in. A change made here a moment ago is stamped first (once),
        //    and copies that are the same bytes are read and taken in once. A copy from before the family code is
        //    read once from each TV (it holds the family's settings until then), then replaced.
        check()
        var remote: [String: [String: [String: Any]]] = [:]
        var opened: [Data: [String: [String: Any]]] = [:]
        var ours: Set<String> = []
        // (A copy that's the same bytes as last round isn't decrypted, parsed and merged in all over again: this runs
        // every 12 seconds on the main thread, and nearly every round finds each TV's copy just as it was.)
        let quiet = !Dreo.shared.busy && !DecoWifi.shared.busy
        // Which settings are kept here now (the same number, and the same ones).
        let shape = last.keys.reduce(last.count) { $0 &+ $1.hashValue }
        for hub in hubs {
            guard let raw = copies[hub.id]?.raw else { continue }
            let plain: Data?
            if let h = heads[hub.id] {
                if h.fp != fam.fp {
                    plain = nil
                } else if let kept = openedBefore[hub.id], kept.box == h.box, kept.fp == fam.fp {
                    plain = kept.plain
                } else {
                    plain = Self.open(h.box, storeKey(hub, fam))
                    openedBefore[hub.id] = plain.map { (box: h.box, fp: fam.fp, plain: $0) }
                }
                if plain != nil { ours.insert(hub.id) }
            } else {
                plain = legacyRead.contains(hub.id) ? nil : Self.open(raw, legacyStoreKey(hub))
            }
            guard let plain else { continue }
            if let its = opened[plain] { remote[hub.id] = its; continue }
            let its: [String: [String: Any]]
            if let kept = parsedBefore[plain] {
                its = kept
            } else {
                guard let read = Self.copyItems(plain) else { continue }
                its = read
                if parsedBefore.count > 6 { parsedBefore = [:] }
                parsedBefore[plain] = read
            }
            opened[plain] = its
            remote[hub.id] = its
            // Merged in again only if something could come of it: the same copy was already taken in, nothing has
            // changed here since (no change noticed, no setting become readable), and no sign-in is being tried here
            // (its keys are left alone until it's over, then taken in).
            if quiet, let done = mergedBefore[plain], done.changes == changes, done.kept == shape { continue }
            apply(its, checked: true)
            if mergedBefore.count > 6 { mergedBefore = [:] }
            // (Kept only if taking it in left the settings kept here as they were: otherwise once more next round.)
            let after = last.keys.reduce(last.count) { $0 &+ $1.hashValue }
            mergedBefore[plain] = quiet && after == shape ? (changes: changes, kept: shape) : nil
        }
        // 3. Each TV whose copy is behind gets everything from here (keeping anything this version doesn't know,
        //    and anything the copy has newer), sealed with the family code. A copy sealed with an older family code
        //    than this device's is left alone (this device is given that code).
        let changesWritten = changes
        let mine = items()
        var current: Set<String> = []
        var pending: [(Hub, TVCopy, Data)] = []
        var elsewhere: [String] = []
        for hub in hubs {
            // (One the family forgot meanwhile isn't written to.)
            guard let copy = copies[hub.id], fleet.hub(hub.id) != nil else { continue }
            if let h = foreign[hub.id], Self.older(h, than: fam) { elsewhere.append(hub.name); continue }
            let its = remote[hub.id]
            var out = mine
            for (k, item) in its ?? [:] where out[k] == nil || Self.stampOf(item) > Self.stampOf(out[k]) { out[k] = item }
            if ours.contains(hub.id), let its, !Self.behind(its, out) { current.insert(hub.id); continue }
            guard let plain = try? JSONSerialization.data(withJSONObject: ["v": 2, "from": me, "items": out]),
                  let sealed = Self.sealCopy(plain, fam, with: storeKey(hub, fam)) else { continue }
            pending.append((hub, copy, sealed))
        }
        await withTaskGroup(of: (String, Bool).self) { g in
            for (hub, copy, sealed) in pending {
                g.addTask {
                    let ok = await self.store(sealed, on: hub, copy)
                    return (hub.id, ok)
                }
            }
            for await (id, ok) in g where ok { current.insert(id) }
        }
        // These TVs' copies are sealed with the family code now: a copy from before it is never read from them again.
        if !current.isSubset(of: legacyRead) {
            legacyRead.formUnion(current)
            UserDefaults.standard.set(legacyRead.sorted(), forKey: "sync.legacyRead")
        }
        otherCode = !elsewhere.isEmpty
        let saved = hubs.filter { current.contains($0.id) }.map(\.name)
        if saved.isEmpty {
            status = elsewhere.isEmpty ? "Can’t reach a TV right now. Changes are kept here and saved when one answers."
                : "Your TVs use another family code. Enter the code from another device."
        } else {
            lastSynced = Date()
            status = "Saved on \(saved.joined(separator: ", "))"
            if !elsewhere.isEmpty { status += ". \(elsewhere.joined(separator: ", ")) use\(elsewhere.count == 1 ? "s" : "") another family code." }
            if changes == changesWritten { unsaved = false }
        }
    }

    /// One TV's copy, or nil when the TV can't be asked just now (it's left alone this round).
    private func read(_ hub: Hub) async -> TVCopy? {
        // One that looks off and hasn't answered the last few rounds is only tried every fourth round.
        let off = fleet?.tv(hub.id)?.online != true
        if off && (misses[hub.id] ?? 0) >= 2 && runs % 4 != 0 { return nil }
        let c = TVClient(hub: hub, routeID: "this")
        let wait: TimeInterval = off ? 5 : 10
        guard let dir = await folder(c, wait: wait) else {
            misses[hub.id, default: 0] += 1
            return nil
        }
        let path = dir + "/settings.wsync"
        if let got = try? await c.t.data("GET", "/api/download", query: ["path": path], contentType: nil, timeout: wait) {
            misses[hub.id] = nil
            stuck[hub.id] = nil
            return TVCopy(folder: dir, raw: got.0, exists: true)
        }
        // Nothing came: no copy there yet (a new TV, or the first device to sync), or a hiccup. The folder says which.
        guard let listing = try? await c.t.get("/api/list", ["path": dir], as: FolderListing.self, timeout: wait) else {
            folders[hub.id] = nil   // gone (the TV was reset?) or unreachable: look for it, or make it, next time
            misses[hub.id, default: 0] += 1
            return nil
        }
        misses[hub.id] = nil
        if listing.files.contains(where: { $0.name == "settings.wsync" }) {
            // It's there but didn't come: next round. One that never comes is replaced.
            let n = (stuck[hub.id] ?? 0) + 1
            stuck[hub.id] = n
            return n >= 3 ? TVCopy(folder: dir, raw: nil, exists: true) : nil
        }
        stuck[hub.id] = nil
        return TVCopy(folder: dir, raw: nil, exists: false)
    }

    private static func copyItems(_ plain: Data) -> [String: [String: Any]]? {
        guard let o = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        return o["items"] as? [String: [String: Any]]
    }

    private static func stampOf(_ item: Any?) -> Double {
        ((item as? [String: Any])?["t"] as? NSNumber)?.doubleValue ?? 0
    }

    private static func entryStampsOf(_ item: [String: Any]) -> [String: Double] {
        (item["e"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Whether a TV's copy lacks anything of [ours], or has it older or different (compared as values and numbers,
    /// not as text, so a copy that's the same never reads as behind).
    private static func behind(_ theirs: [String: [String: Any]], _ ours: [String: Any]) -> Bool {
        for (k, o) in ours {
            guard let mine = o as? [String: Any], let t = theirs[k] else { return true }
            if (mine["v"] as? String ?? "") != (t["v"] as? String ?? "") { return true }
            if stampOf(mine) != stampOf(t) || entryStampsOf(mine) != entryStampsOf(t) { return true }
        }
        return false
    }

    /// Puts [sealed] on [hub] as its copy. True once it's there.
    private func store(_ sealed: Data, on hub: Hub, _ copy: TVCopy) async -> Bool {
        let c = TVClient(hub: hub, routeID: "this")
        let dir = copy.folder
        let path = dir + "/settings.wsync"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).wsync")
        guard (try? sealed.write(to: tmp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        if copy.exists { try? await c.delete(path) }
        guard let name = await Self.within(25, { try await c.upload(file: tmp, to: dir, name: "settings.wsync") }) else {
            folders[hub.id] = nil   // look for (or make) the folder again next time
            return false
        }
        if name == "settings.wsync" { return true }
        // The old copy was still there and the TV saved this one beside it: clear both and try once more.
        try? await c.delete(dir + "/" + name)
        try? await c.delete(path)
        guard let again = await Self.within(25, { try await c.upload(file: tmp, to: dir, name: "settings.wsync") }) else { return false }
        if again == "settings.wsync" { return true }
        try? await c.delete(dir + "/" + again)
        return false
    }

    /// [work]'s answer, or nil when it fails or takes longer than [seconds] (it's then called off), so a TV that
    /// went away mid-write never holds up the next round.
    nonisolated private static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { try? await work() }
            g.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await g.next()
            g.cancelAll()
            return first ?? nil
        }
    }

    /// Where the copy lives on a TV: a hidden folder at the top of its built-in storage.
    private func folder(_ c: TVClient, wait: TimeInterval) async -> String? {
        if let f = folders[c.hub.id] { return f }
        // Built-in storage, never a USB drive that might be unplugged.
        guard let roots = try? await c.t.get("/api/roots", as: [StorageRoot].self, timeout: wait),
              let root = (roots.first(where: { $0.removable != true }) ?? roots.first)?.path else { return nil }
        for name in [".woodruff", "Woodruff Settings"] {
            let f = root.hasSuffix("/") ? root + name : root + "/" + name
            if (try? await c.t.get("/api/list", ["path": f], as: FolderListing.self, timeout: wait)) == nil { try? await c.mkdir(in: root, name: name) }
            if (try? await c.t.get("/api/list", ["path": f], as: FolderListing.self, timeout: wait)) != nil { folders[c.hub.id] = f; return f }
        }
        return nil
    }

    // MARK: 2. Straight across the Wi‑Fi

    /// Everything from here, sealed with the family code (nothing goes without one), and that code's fingerprint.
    private func payload() -> Data? {
        guard let fam = currentFamily().family,
              let plain = try? JSONSerialization.data(withJSONObject: ["from": me, "items": items()]),
              let sealed = try? AES.GCM.seal(plain, using: fam.peerKey).combined else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["fp": fam.fp.base64EncodedString(), "box": sealed.base64EncodedString()])
    }

    private func broadcast() {
        // No other device around: nothing to seal (one that appears is handed everything then, in `browse`).
        guard !peers.isEmpty, let data = payload() else { return }
        for ep in peers.values { send(data, to: ep) }
    }

    private func send(_ data: Data, to ep: NWEndpoint) {
        let c = NWConnection(to: ep, using: .tcp)
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: c.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { c.cancel() }
            })
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: .main)
        // Never left hanging on a device that went away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { c.cancel() }
    }

    private func listen() {
        listener?.cancel()
        listener = nil
        listenerReady = false
        listenTry += 1
        listenStarted = Date()
        let attempt = listenTry
        guard let l = try? NWListener(using: .tcp) else { listenFailed(attempt); return }
        l.service = NWListener.Service(name: me, type: Self.service)
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            // Whatever hasn't arrived in 20 seconds isn't coming.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { c.cancel() }
            self?.receive(c, Data())
        }
        l.stateUpdateHandler = { [weak self] s in
            let state: Int
            switch s {
            case .ready: state = 1
            case .failed: state = 2
            default: state = 0
            }
            Task { @MainActor in self?.listenerChanged(state, attempt) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func listenerChanged(_ state: Int, _ attempt: Int) {
        guard attempt == listenTry else { return }   // news of a listener since replaced
        if state == 1 { listenerReady = true; listenFailures = 0 }
        if state == 2 { listenFailed(attempt) }
    }

    /// The listener stopped (the network went away, the app slept): start it again shortly, waiting a little longer
    /// each time it fails in a row.
    private func listenFailed(_ attempt: Int) {
        guard attempt == listenTry else { return }
        listener?.cancel()
        listener = nil
        listenerReady = false
        listenFailures += 1
        let wait = UInt64(min(60, 2 << min(listenFailures, 5)))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard let self, self.loop != nil, self.listenTry == attempt, self.listener == nil else { return }
            self.listen()
        }
    }

    nonisolated private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if done || error != nil || buf.count > 4 << 20 {
                c.cancel()
                let final = buf
                Task { @MainActor in self?.handle(final) }
            } else {
                self?.receive(c, buf)
            }
        }
    }

    /// Settings from another device, taken only when they're sealed with this device's family code.
    private func handle(_ data: Data) {
        guard let fam = currentFamily().family,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fp = (o["fp"] as? String).flatMap({ Data(base64Encoded: $0) }), fp == fam.fp,
              let raw = (o["box"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let plain = Self.open(raw, fam.peerKey),
              let p = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              (p["from"] as? String) != me, let items = p["items"] as? [String: [String: Any]] else { return }
        if apply(items) { broadcast() }
    }

    private func browse() {
        browser?.cancel()
        browser = nil
        browseTry += 1
        let attempt = browseTry
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, attempt == self.browseTry else { return }
                var found: [String: NWEndpoint] = [:]
                for r in results {
                    if case let .service(name, _, _, _) = r.endpoint, name != self.me { found[name] = r.endpoint }
                }
                let fresh = found.keys.filter { self.peers[$0] == nil }
                self.peers = found
                // A device that just appeared gets everything from here at once.
                if !fresh.isEmpty, let data = self.payload() { for n in fresh { if let ep = found[n] { self.send(data, to: ep) } } }
            }
        }
        b.stateUpdateHandler = { [weak self] s in
            guard case .failed = s else { return }
            Task { @MainActor in self?.browserFailed(attempt) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// The search for the other devices stopped: start it again shortly.
    private func browserFailed(_ attempt: Int) {
        guard attempt == browseTry else { return }
        browser?.cancel()
        browser = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.loop != nil, self.browseTry == attempt, self.browser == nil else { return }
            self.browse()
        }
    }
}
