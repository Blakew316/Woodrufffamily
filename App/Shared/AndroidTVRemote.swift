import Foundation
import Network
import Security
import CryptoKit
import WoodruffKit

/// The phone and Mac as a real remote for the family's Google TV and Android TV sets, through Android's own
/// "Android TV Remote" service (protocol v2, the one Google's TV remote app uses): arrows, OK, Back, Home, volume,
/// mute, play/pause and power reach whatever app is on screen, not only Woodruff.
///
/// Pairing happens once per TV, on port 6467: the TV shows a 6-character code, typed here. Every family device
/// presents the same client certificate (`ATVClientIdentity`), so the TV trusts them all once one has paired, and
/// the TV's own certificate is pinned (its SHA-256 per address, in `atvRemote.paired`, which travels with
/// SettingsSync). Keys go over one TLS connection per TV, on port 6466, kept open while the TV pings it.
@Observable @MainActor
final class AndroidTVRemote {
    static let shared = AndroidTVRemote()
    /// [TV address: SHA-256 of its certificate, hex] in UserDefaults (JSON), synced to every family device.
    static let pairedKey = "atvRemote.paired"
    static let serviceName = "com.woodruff.family"
    static let clientName = "Woodruff Family"

    /// Woodruff's key names → Android key codes (KEYCODE_*).
    static let keyCodes: [String: Int] = [
        "up": 19, "down": 20, "left": 21, "right": 22, "ok": 23,
        "back": 4, "home": 3,
        "volup": 24, "voldown": 25, "mute": 164,
        "playpause": 85, "power": 26,
    ]

    private(set) var paired: [String: String]
    @ObservationIgnored private var sessions: [String: ATVSession] = [:]
    /// Pairings under way: the TV is showing its code on this connection.
    @ObservationIgnored private var pairings: [String: ATVLink] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        paired = Self.loadPaired()
        // A pairing made on another family device arrives through SettingsSync, straight into UserDefaults.
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPaired() }
        }
    }

    static func handles(_ key: String) -> Bool { keyCodes[key] != nil }

    func isPaired(host: String) -> Bool { paired[host] != nil }

    /// Whether a pairing with [host] is waiting for its code.
    func isPairing(host: String) -> Bool { pairings[host]?.isOpen == true }

    // MARK: Pairing

    /// Asks the TV to pair: it shows a 6-character code (typed into `finishPairing`).
    func startPairing(host: String) async throws {
        guard Self.isLocal(host) else { throw ATVError.notLocal }
        guard let me = ATVClientIdentity.shared else { throw ATVError.noIdentity }
        cancelPairing(host: host)
        // Not pinned: the code the TV shows is what proves it's the TV (it goes into the secret, with its certificate).
        let link = ATVLink(host: host, port: 6467, identity: me.identity, pin: nil)
        pairings[host] = link
        do {
            try await link.open(timeout: 6)
            link.send(ATVMessages.pairingRequest(service: Self.serviceName, client: Self.clientName))
            guard try await Self.answer(link).has(11) else { throw ATVError.badAnswer }       // pairing_request_ack
            link.send(ATVMessages.pairingOptions())
            guard try await Self.answer(link).has(20) else { throw ATVError.badAnswer }       // options
            link.send(ATVMessages.pairingConfiguration())
            guard try await Self.answer(link).has(31) else { throw ATVError.badAnswer }       // configuration_ack
        } catch {
            link.close()
            if pairings[host] === link { pairings[host] = nil }
            throw error
        }
    }

    /// Sends the code the TV shows. A mistyped code can be typed again; the TV keeps showing it.
    func finishPairing(host: String, code: String) async throws {
        guard let link = pairings[host], link.isOpen else { throw ATVError.pairingEnded }
        guard let me = ATVClientIdentity.shared else { throw ATVError.noIdentity }
        let typed = code.uppercased().filter { !$0.isWhitespace }
        guard let codeBytes = ATVWire.hexBytes(typed), codeBytes.count == 3 else { throw ATVError.codeFormat }
        guard let serverDER = link.peer.certificate,
              let serverCert = SecCertificateCreateWithData(nil, Data(serverDER) as CFData),
              let server = ATVCrypto.publicNumbers(serverCert) else { throw ATVError.badAnswer }
        let input = ATVWire.secretInput(clientModulus: me.modulus, clientExponent: me.exponent,
                                        serverModulus: server.modulus, serverExponent: server.exponent, code: codeBytes)
        let secret = Array(SHA256.hash(data: Data(input)))
        // The code's first byte is the hash's first byte: a mistyped code (or a TV that isn't the one on screen)
        // never gets as far as the TV.
        guard secret.first == codeBytes[0] else { throw ATVError.wrongCode }
        link.send(ATVMessages.pairingSecret(secret))
        do {
            guard try await Self.answer(link).has(41) else { throw ATVError.badAnswer }       // secret_ack
        } catch {
            link.close()
            if pairings[host] === link { pairings[host] = nil }
            // The TV turned the code down: this pairing is over (its code can't be typed again).
            throw (error as? ATVError) == .wrongCode ? ATVError.codeRefused : error
        }
        let pairingPrint = link.peer.fingerprint
        link.close()
        if pairings[host] === link { pairings[host] = nil }

        // The remote port's certificate is the one pinned. It's normally the same as the pairing port's; if it isn't,
        // the one seen right after this pairing (which the code just proved) is kept.
        sessions[host]?.close()
        sessions[host] = nil
        let session = ATVSession(host: host, pin: nil, identity: me.identity)
        var pin = pairingPrint
        do {
            try await session.connectNow()
            if let p = session.seenFingerprint { pin = p }
            sessions[host] = session
        } catch {
            session.close()
        }
        guard let pin else { throw ATVError.badAnswer }
        session.pin = pin
        var all = Self.loadPaired()
        all[host] = pin
        save(all)
    }

    func cancelPairing(host: String) {
        pairings[host]?.close()
        pairings[host] = nil
    }

    func forget(host: String) {
        sessions[host]?.close()
        sessions[host] = nil
        var all = Self.loadPaired()
        all[host] = nil
        save(all)
    }

    /// One answer during pairing; anything but OK (a wrong secret, a refused pairing) ends it.
    private static func answer(_ link: ATVLink) async throws -> ATVMessage {
        let raw = try await link.next(timeout: 10)
        guard let m = ATVMessage(raw) else { throw ATVError.badAnswer }
        let status = m.uint(2) ?? 0
        if status == 402 { throw ATVError.wrongCode }
        guard status == 200 else { throw ATVError.refused }
        return m
    }

    // MARK: Keys

    /// One key on the TV at [host] (Woodruff's names: "up", "ok", "volup", "power"…).
    func press(host: String, key: String) async throws {
        guard let code = Self.keyCodes[key] else { throw ATVError.unknownKey }
        try await session(for: host).press(code)
    }

    /// Types [text] into the TV's selected text box (only while the TV has one open).
    func type(host: String, text: String) async throws {
        guard !text.isEmpty else { return }
        try await session(for: host).type(text)
    }

    private func session(for host: String) throws -> ATVSession {
        guard let pin = paired[host] else { throw ATVError.notPaired }
        guard Self.isLocal(host) else { throw ATVError.notLocal }
        guard let me = ATVClientIdentity.shared else { throw ATVError.noIdentity }
        if let s = sessions[host], s.pin == pin, !s.ended { return s }
        sessions[host]?.close()
        let s = ATVSession(host: host, pin: pin, identity: me.identity)
        sessions[host] = s
        return s
    }

    // MARK: Saved pairings

    private static func loadPaired() -> [String: String] {
        Saved.load(pairedKey, as: [String: String].self) ?? [:]
    }

    private func save(_ all: [String: String]) {
        if all.isEmpty { UserDefaults.standard.removeObject(forKey: Self.pairedKey) } else { Saved.save(Self.pairedKey, all) }
        reloadPaired()
    }

    private func reloadPaired() {
        let now = Self.loadPaired()
        guard now != paired else { return }
        paired = now
        // A TV paired again elsewhere (a new certificate): its connection here starts over with the new pin.
        for (host, s) in sessions where now[host] != s.pin {
            s.close()
            sessions[host] = nil
        }
    }

    /// Only addresses on this network: the TV's own certificate is self-signed, so it's trusted (pinned) only here.
    nonisolated static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { return false }
        for suffix in [".local", ".lan", ".home", ".home.arpa", ".internal"] where h.hasSuffix(suffix) { return true }
        if h.contains(":") { return h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 1 { return true }   // a bare name on this network ("livingroom-tv")
        let p = parts.compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (p[0], p[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true   // carrier-grade NAT ranges some mesh routers hand out
        default: return false
        }
    }
}

extension Fleet {
    /// Where an Android TV answers on the Wi‑Fi (nil for LG and other TVs, or when no address is known), preferring
    /// an address that's paired with the Android TV remote.
    func androidAddress(for tv: FleetTV) -> String? {
        guard platform(of: tv) == .android else { return nil }
        var seen: [String] = []
        for h in [hub(tv.id)?.connection.base.host, extras[tv.id]?.lastHost, tv.foundAt?.host] {
            if let h, !h.isEmpty, !seen.contains(h) { seen.append(h) }
        }
        return seen.first { AndroidTVRemote.shared.isPaired(host: $0) } ?? seen.first { AndroidTVRemote.isLocal($0) }
    }

    /// The paired Android TV remote address for [tv], when keys should go that way.
    func androidRemoteHost(for tv: FleetTV) -> String? {
        guard let h = androidAddress(for: tv), AndroidTVRemote.shared.isPaired(host: h) else { return nil }
        return h
    }
}

enum ATVError: LocalizedError, Equatable {
    case noIdentity, notLocal, notPaired, noAnswer, closed, refused, identityChanged, badAnswer
    case pairingEnded, codeFormat, wrongCode, codeRefused, unknownKey, busy
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noIdentity: return "This device’s remote certificate couldn’t be loaded."
        case .notLocal: return "The TV has to be on this Wi‑Fi."
        case .notPaired: return "Pair the remote in the TV’s settings first."
        case .noAnswer: return "The TV didn’t answer. Is it on this Wi‑Fi?"
        case .closed: return "The TV closed the connection."
        case .refused: return "The TV turned the remote down. Pair it again in the TV’s settings."
        case .identityChanged: return "This TV isn’t the one that was paired. Pair it again in the TV’s settings."
        case .badAnswer: return "The TV answered in a way Woodruff doesn’t understand."
        case .pairingEnded: return "Pairing ended. Press Pair again."
        case .codeFormat: return "The code is 6 letters and numbers, like 4A7F2C."
        case .wrongCode: return "That code didn’t match. Check it and try again."
        case .codeRefused: return "The TV didn’t take that code. Press Pair again for a new one."
        case .unknownKey: return "The TV has no such key."
        case .busy: return "Still waiting for the TV. Try again in a moment."
        case .network(let m): return m
        }
    }
}

// MARK: - Client certificate

/// The family's one remote certificate: RSA-2048, self-signed, the same on every device (so a TV paired once trusts
/// them all). It's only ever shown to the family's TVs.
final class ATVClientIdentity {
    let identity: SecIdentity
    let modulus: [UInt8]
    let exponent: [UInt8]

    private init(identity: SecIdentity, modulus: [UInt8], exponent: [UInt8]) {
        self.identity = identity; self.modulus = modulus; self.exponent = exponent
    }

    static let shared: ATVClientIdentity? = load()

    private static func load() -> ATVClientIdentity? {
        guard let p12 = Data(base64Encoded: p12Base64.joined()) else { return nil }
        var options: [String: Any] = [kSecImportExportPassphrase as String: "woodruff"]
        #if os(macOS)
        // Kept in memory: nothing is added to the Mac's keychain.
        options[kSecImportToMemoryOnly as String] = true
        #endif
        var items: CFArray?
        guard SecPKCS12Import(p12 as CFData, options as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]], let found = list.first?[kSecImportItemIdentity as String] else { return nil }
        let identity = found as! SecIdentity
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
              let numbers = ATVCrypto.publicNumbers(cert) else { return nil }
        return ATVClientIdentity(identity: identity, modulus: numbers.modulus, exponent: numbers.exponent)
    }

    /// PKCS#12 (password "woodruff"; 3DES and SHA-1 MAC, which every Apple OS imports): CN=Woodruff Family,
    /// valid 2020–2060.
    private static let p12Base64 = [
        "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",
    ]
}

enum ATVCrypto {
    /// SHA-256 of a certificate (DER), lowercase hex.
    static func fingerprint(_ der: [UInt8]) -> String {
        SHA256.hash(data: Data(der)).map { String(format: "%02x", $0) }.joined()
    }

    /// The RSA modulus and exponent of a certificate's public key.
    static func publicNumbers(_ cert: SecCertificate) -> (modulus: [UInt8], exponent: [UInt8])? {
        guard let key = SecCertificateCopyKey(cert) else { return nil }
        var error: Unmanaged<CFError>?
        // An RSA public key comes out as PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
        guard let der = SecKeyCopyExternalRepresentation(key, &error) as Data? else { return nil }
        return ATVWire.rsaPublicKey([UInt8](der))
    }
}

/// What the TV's certificate turned out to be on one connection, written from Network's TLS queue.
final class ATVPeer: @unchecked Sendable {
    private let lock = NSLock()
    private let pin: String?
    private var der: [UInt8]?
    private var seen: String?
    private var wrong = false

    init(pin: String?) { self.pin = pin }

    var certificate: [UInt8]? { lock.lock(); defer { lock.unlock() }; return der }
    var fingerprint: String? { lock.lock(); defer { lock.unlock() }; return seen }
    var mismatch: Bool { lock.lock(); defer { lock.unlock() }; return wrong }

    /// Accepts the TV's self-signed certificate: any during pairing (the code proves it), else only the pinned one.
    func check(_ trust: SecTrust) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let bytes = [UInt8](SecCertificateCopyData(leaf) as Data)
        let fp = ATVCrypto.fingerprint(bytes)
        lock.lock(); defer { lock.unlock() }
        der = bytes
        seen = fp
        wrong = pin != nil && pin != fp
        return !wrong
    }
}

// MARK: - One connection

/// One TLS connection to a TV port: messages framed by a varint length, both ways.
@MainActor
final class ATVLink {
    let host: String
    let port: UInt16
    let peer: ATVPeer
    private let connection: NWConnection
    private var buffer: [UInt8] = []
    private var inbox: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var waiterToken = 0
    private var opener: CheckedContinuation<Void, Error>?
    private(set) var isOpen = false
    private(set) var closed = false
    private var closeError: Error?
    /// Set: every message goes here (the remote). Unset: messages wait for `next` (pairing).
    var onMessage: (([UInt8]) -> Void)?
    var onClose: ((Error) -> Void)?

    init(host: String, port: UInt16, identity: SecIdentity, pin: String?) {
        self.host = host
        self.port = port
        let peer = ATVPeer(pin: pin)
        self.peer = peer
        let tls = Self.tls(identity: identity, peer: peer)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.prohibitedInterfaceTypes = [.cellular]
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 6466, using: params)
    }

    /// TLS with the family's client certificate. Only these connections, to a TV on this network, take a self-signed
    /// certificate (see `ATVPeer.check`). Built outside the main actor: the check runs on Network's own queue.
    nonisolated private static func tls(identity: SecIdentity, peer: ATVPeer) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let me = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, me) }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            complete(peer.check(sec_trust_copy_ref(trust).takeRetainedValue()))
        }, DispatchQueue.global(qos: .userInitiated))
        return tls
    }

    /// Connects (TCP and TLS).
    func open(timeout: Double) async throws {
        if isOpen { return }
        if closed { throw closeError ?? ATVError.closed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            opener = c
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.changed(state) }
            }
            connection.start(queue: .main)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.opener != nil else { return }
                self.finish(ATVError.noAnswer)
            }
        }
    }

    /// The next message (pairing).
    func next(timeout: Double) async throws -> [UInt8] {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { throw closeError ?? ATVError.closed }
        // One question at a time: a second waiter would leave the first waiting for ever.
        if waiter != nil { throw ATVError.busy }
        waiterToken += 1
        let token = waiterToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.waiterToken == token, let w = self.waiter else { return }
            self.waiter = nil
            w.resume(throwing: ATVError.noAnswer)
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], Error>) in waiter = c }
    }

    /// Sends one message without waiting (answers, in order).
    func send(_ message: [UInt8]) {
        guard !closed else { return }
        connection.send(content: Data(ATVWire.frame(message)), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish(ATVError.network(error.localizedDescription)) }
        })
    }

    /// Sends one message and waits until it's on its way (a key: a dead connection shows here).
    func sendAndWait(_ message: [UInt8]) async throws {
        if closed || !isOpen { throw closeError ?? ATVError.closed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(ATVWire.frame(message)), completion: .contentProcessed { error in
                if let error { c.resume(throwing: ATVError.network(error.localizedDescription)) } else { c.resume() }
            })
        }
    }

    func close() { finish(ATVError.closed) }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isOpen = true
            opener?.resume()
            opener = nil
            receive()
        case .waiting(let e), .failed(let e):
            finish(describe(e))
        case .cancelled:
            finish(ATVError.closed)
        default:
            break
        }
    }

    private func describe(_ e: NWError) -> Error {
        if peer.mismatch { return ATVError.identityChanged }
        switch e {
        case .tls: return port == 6466 ? ATVError.refused : ATVError.network(e.localizedDescription)
        case .posix(let code) where code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ETIMEDOUT || code == .EHOSTDOWN:
            return ATVError.noAnswer
        default: return ATVError.network(e.localizedDescription)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(contentsOf: data)
                    self.drain()
                }
                guard !self.closed else { return }
                if let error { self.finish(self.describe(error)) }
                else if isComplete { self.finish(ATVError.closed) }
                else { self.receive() }
            }
        }
    }

    private func drain() {
        while !closed {
            switch ATVWire.unframe(&buffer) {
            case .message(let m): deliver(m)
            case .incomplete: return
            case .corrupt: finish(ATVError.badAnswer); return
            }
        }
    }

    private func deliver(_ m: [UInt8]) {
        if let onMessage { onMessage(m) }
        else if let w = waiter { waiter = nil; w.resume(returning: m) }
        else { inbox.append(m) }
    }

    private func finish(_ e: Error) {
        guard !closed else { return }
        closed = true
        isOpen = false
        closeError = e
        opener?.resume(throwing: e)
        opener = nil
        waiter?.resume(throwing: e)
        waiter = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(e)
        onMessage = nil
        onClose = nil
    }
}

// MARK: - The remote connection to one TV

/// Port 6466: the TV says what it supports (RemoteConfigure), asks us to be active (RemoteSetActive), says it's ready
/// (RemoteStart), and pings every 5 seconds. Keys are RemoteKeyInject. One per TV, opened again when it drops.
@MainActor
final class ATVSession {
    let host: String
    /// The certificate this TV must show (nil: any, right after pairing, to learn it).
    var pin: String?
    private let identity: SecIdentity
    private var link: ATVLink?
    private var ready = false
    private var connecting: Task<ATVLink, Error>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var readyToken = 0
    private var watchdog: Task<Void, Never>?
    private var lastHeard = Date()
    /// After a failed connection, keys go the other way at once for a while (not each waiting for a timeout).
    private var failedUntil: Date?
    private var lastError: Error?
    private var features: UInt64 = ATVMessages.wantedFeatures
    private var imeCounter = 0
    private var fieldCounter = 0
    /// The TV is on (RemoteStart).
    private(set) var isOn = false
    private(set) var seenFingerprint: String?
    /// Closed for good (`close`).
    private(set) var ended = false

    init(host: String, pin: String?, identity: SecIdentity) {
        self.host = host; self.pin = pin; self.identity = identity
    }

    /// Connects now (right after pairing).
    func connectNow() async throws {
        failedUntil = nil
        _ = try await readyLink()
    }

    func press(_ code: Int) async throws {
        try await sendKeyed(ATVMessages.key(code))
    }

    func type(_ text: String) async throws {
        try await sendKeyed(ATVMessages.text(text, imeCounter: imeCounter, fieldCounter: fieldCounter))
    }

    /// Sends on the open connection; once more on a new one if the old one had quietly died.
    private func sendKeyed(_ message: [UInt8]) async throws {
        if let until = failedUntil, Date() < until { throw lastError ?? ATVError.noAnswer }
        let hadLink = ready && link?.isOpen == true
        let l = try await readyLink()
        do {
            try await l.sendAndWait(message)
        } catch {
            dropLink(error)
            guard hadLink else { throw error }
            let fresh = try await readyLink()
            try await fresh.sendAndWait(message)
        }
    }

    private func readyLink() async throws -> ATVLink {
        if ended { throw ATVError.closed }
        if ready, let l = link, l.isOpen { return l }
        if let running = connecting { return try await running.value }
        let t = Task { try await self.connect() }
        connecting = t
        let result = await t.result
        if connecting == t { connecting = nil }
        switch result {
        case .success(let l):
            failedUntil = nil
            return l
        case .failure(let e):
            failedUntil = Date().addingTimeInterval(15)
            lastError = e
            throw e
        }
    }

    private func connect() async throws -> ATVLink {
        dropLink(ATVError.closed)
        let l = ATVLink(host: host, port: 6466, identity: identity, pin: pin)
        link = l
        ready = false
        l.onMessage = { [weak self, weak l] m in
            guard let self, let l, self.link === l else { return }
            self.handle(m, on: l)
        }
        l.onClose = { [weak self, weak l] e in
            guard let self, let l, self.link === l else { return }
            self.dropLink(e)
        }
        try await l.open(timeout: 4)
        // Closed here while it was connecting (the TV forgotten, or paired again): the new link goes too.
        if ended { l.close(); throw ATVError.closed }
        seenFingerprint = l.peer.fingerprint
        lastHeard = Date()
        do {
            try await waitReady(timeout: 6)
        } catch ATVError.closed where !ended {
            // TLS went through, then the TV hung up before saying anything: it doesn't know this device.
            throw ATVError.refused
        }
        guard !ended, link === l, l.isOpen else { l.close(); throw ATVError.closed }
        startWatchdog()
        return l
    }

    private func waitReady(timeout: Double) async throws {
        if ready { return }
        readyToken += 1
        let token = readyToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, self.readyToken == token, let w = self.readyWaiter else { return }
            self.readyWaiter = nil
            w.resume(throwing: ATVError.noAnswer)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyWaiter = c }
    }

    private func markReady() {
        ready = true
        readyWaiter?.resume()
        readyWaiter = nil
    }

    private func handle(_ raw: [UInt8], on l: ATVLink) {
        guard let m = ATVMessage(raw) else { return }
        lastHeard = Date()
        if let cfg = m.message(1) {                       // remote_configure
            let supported = cfg.uint(1) ?? 0
            features = supported == 0 ? ATVMessages.wantedFeatures : (ATVMessages.wantedFeatures & supported)
            l.send(ATVMessages.configure(features: features, package: AndroidTVRemote.serviceName))
        } else if m.has(2) {                              // remote_set_active
            l.send(ATVMessages.setActive(features: features))
            // Ready once the TV says RemoteStart; some never do, so a moment later counts too.
            Task { [weak self, weak l] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self, let l, self.link === l, l.isOpen else { return }
                self.markReady()
            }
        } else if let ping = m.message(8) {               // remote_ping_request
            l.send(ATVMessages.pingResponse(ping.int(1) ?? 0))
        } else if let start = m.message(40) {            // remote_start
            isOn = (start.uint(1) ?? 0) != 0
            markReady()
        } else if let edit = m.message(21) {             // remote_ime_batch_edit: the TV's text box counters
            imeCounter = edit.int(1) ?? 0
            fieldCounter = edit.int(2) ?? 0
        }
    }

    /// The TV pings every 5 seconds; 16 seconds without a word means the connection is gone.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastHeard) > 16 {
                    self.dropLink(ATVError.noAnswer)
                    return
                }
            }
        }
    }

    private func dropLink(_ e: Error) {
        let l = link
        link = nil
        ready = false
        readyWaiter?.resume(throwing: e)
        readyWaiter = nil
        watchdog?.cancel()
        watchdog = nil
        l?.close()
    }

    /// For good: this session is done with (a connection still being made is closed as soon as it's made).
    func close() {
        ended = true
        connecting?.cancel()
        connecting = nil
        dropLink(ATVError.closed)
    }
}

// MARK: - Wire format (pure)

/// The messages, from polo.proto (pairing) and remotemessage.proto (remote).
enum ATVMessages {
    /// PING | KEY | IME | POWER | VOLUME | APP_LINK (as androidtvremote2 asks; the TV keeps the ones it has).
    static let wantedFeatures: UInt64 = 1 | 2 | 4 | 32 | 64 | 512

    /// OuterMessage { protocol_version 2, status OK, … }.
    private static func outer(_ body: (inout ATVWriter) -> Void) -> [UInt8] {
        var w = ATVWriter()
        w.uint(1, 2)
        w.uint(2, 200)
        body(&w)
        return w.bytes
    }

    /// Hexadecimal, 6 symbols.
    private static func encoding(_ w: inout ATVWriter) {
        w.uint(1, 3)
        w.uint(2, 6)
    }

    static func pairingRequest(service: String, client: String) -> [UInt8] {
        outer { $0.message(10) { $0.string(1, service); $0.string(2, client) } }
    }

    static func pairingOptions() -> [UInt8] {
        outer { $0.message(20) { $0.message(1, encoding); $0.uint(3, 1) } }   // input encodings, preferred role INPUT
    }

    static func pairingConfiguration() -> [UInt8] {
        outer { $0.message(30) { $0.message(1, encoding); $0.uint(2, 1) } }   // encoding, client role INPUT
    }

    static func pairingSecret(_ secret: [UInt8]) -> [UInt8] {
        outer { $0.message(40) { $0.blob(1, secret) } }
    }

    static func configure(features: UInt64, package: String) -> [UInt8] {
        var w = ATVWriter()
        w.message(1) {
            $0.uint(1, features)
            $0.message(2) { d in
                d.uint(3, 1)
                d.string(4, "1")
                d.string(5, package)
                d.string(6, "1.0.0")
            }
        }
        return w.bytes
    }

    static func setActive(features: UInt64) -> [UInt8] {
        var w = ATVWriter()
        w.message(2) { $0.uint(1, features) }
        return w.bytes
    }

    static func pingResponse(_ value: Int) -> [UInt8] {
        var w = ATVWriter()
        w.message(9) { if value != 0 { $0.int(1, value) } }
        return w.bytes
    }

    /// RemoteKeyInject { key_code, direction SHORT }.
    static func key(_ code: Int) -> [UInt8] {
        var w = ATVWriter()
        w.message(10) { $0.int(1, code); $0.uint(2, 3) }
        return w.bytes
    }

    /// RemoteImeBatchEdit, as androidtvremote2's send_text.
    static func text(_ text: String, imeCounter: Int, fieldCounter: Int) -> [UInt8] {
        let end = text.unicodeScalars.count - 1   // as Python counts it
        var w = ATVWriter()
        w.message(21) {
            if imeCounter != 0 { $0.int(1, imeCounter) }
            if fieldCounter != 0 { $0.int(2, fieldCounter) }
            $0.message(3) { e in
                e.int(1, 1)
                e.message(2) { o in
                    if end != 0 { o.int(1, end); o.int(2, end) }
                    o.string(3, text)
                }
            }
        }
        return w.bytes
    }
}

/// Protobuf, written by hand: varints and length-delimited fields are all these messages use.
struct ATVWriter {
    private(set) var bytes: [UInt8] = []

    private mutating func tag(_ field: Int, _ wire: UInt64) { bytes += ATVWire.varint(UInt64(field) << 3 | wire) }

    mutating func uint(_ field: Int, _ v: UInt64) { tag(field, 0); bytes += ATVWire.varint(v) }
    /// int32/enum: negative numbers take ten bytes, as protobuf writes them.
    mutating func int(_ field: Int, _ v: Int) { uint(field, UInt64(bitPattern: Int64(v))) }
    mutating func blob(_ field: Int, _ b: [UInt8]) { tag(field, 2); bytes += ATVWire.varint(UInt64(b.count)); bytes += b }
    mutating func string(_ field: Int, _ s: String) { blob(field, Array(s.utf8)) }
    mutating func message(_ field: Int, _ build: (inout ATVWriter) -> Void) {
        var w = ATVWriter()
        build(&w)
        blob(field, w.bytes)
    }
}

/// A parsed protobuf message: each field's values in order (the last one counts, as protobuf reads them).
struct ATVMessage {
    enum Value { case varint(UInt64), bytes([UInt8]), fixed }
    private(set) var fields: [(Int, Value)] = []

    init?(_ b: [UInt8]) {
        var i = 0
        while i < b.count {
            guard let k = ATVWire.readVarint(b, i) else { return nil }
            i = k.next
            let key = k.value
            let field = Int(truncatingIfNeeded: key >> 3)
            guard field > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let v = ATVWire.readVarint(b, i) else { return nil }
                fields.append((field, .varint(v.value))); i = v.next
            case 1:
                guard i + 8 <= b.count else { return nil }
                fields.append((field, .fixed)); i += 8
            case 2:
                guard let l = ATVWire.readVarint(b, i), l.value <= UInt64(b.count - l.next) else { return nil }
                let end = l.next + Int(l.value)
                fields.append((field, .bytes(Array(b[l.next..<end])))); i = end
            case 5:
                guard i + 4 <= b.count else { return nil }
                fields.append((field, .fixed)); i += 4
            default:
                return nil
            }
        }
    }

    func has(_ field: Int) -> Bool { fields.contains { $0.0 == field } }

    func uint(_ field: Int) -> UInt64? {
        for (f, v) in fields.reversed() where f == field { if case .varint(let x) = v { return x } }
        return nil
    }

    func int(_ field: Int) -> Int? { uint(field).map { Int(Int32(truncatingIfNeeded: $0)) } }

    func data(_ field: Int) -> [UInt8]? {
        for (f, v) in fields.reversed() where f == field { if case .bytes(let x) = v { return x } }
        return nil
    }

    func string(_ field: Int) -> String? { data(field).map { String(decoding: $0, as: UTF8.self) } }

    func message(_ field: Int) -> ATVMessage? { data(field).flatMap { ATVMessage($0) } }
}

enum ATVWire {
    enum Frame: Equatable { case message([UInt8]), incomplete, corrupt }

    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// A varint at [start]: its value and where the next thing starts; nil if it isn't all there (or is too long).
    static func readVarint(_ b: [UInt8], _ start: Int) -> (value: UInt64, next: Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < b.count, shift < 64 {
            let byte = b[i]
            value |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (value, i) }
            shift += 7
        }
        return nil
    }

    /// A message with its varint length in front.
    static func frame(_ message: [UInt8]) -> [UInt8] { varint(UInt64(message.count)) + message }

    /// Takes the first whole message off [buffer], if it's all there.
    static func unframe(_ buffer: inout [UInt8]) -> Frame {
        guard !buffer.isEmpty else { return .incomplete }
        guard let head = readVarint(buffer, 0) else {
            // Ten bytes and still no end: no length is that long.
            return buffer.count >= 10 ? .corrupt : .incomplete
        }
        guard head.value <= 1 << 20 else { return .corrupt }
        let start = head.next
        let end = start + Int(head.value)
        guard buffer.count >= end else { return .incomplete }
        let m = Array(buffer[start..<end])
        buffer.removeFirst(end)
        return .message(m)
    }

    /// "4A7F2C" → [0x4A, 0x7F, 0x2C]; nil for anything that isn't whole hex bytes.
    static func hexBytes(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    /// PKCS#1 RSAPublicKey (SEQUENCE { INTEGER modulus, INTEGER exponent }) → the two numbers, big-endian, without
    /// leading zero bytes.
    static func rsaPublicKey(_ der: [UInt8]) -> (modulus: [UInt8], exponent: [UInt8])? {
        var i = 0
        func length() -> Int? {
            guard i < der.count else { return nil }
            let first = der[i]; i += 1
            if first < 0x80 { return Int(first) }
            let n = Int(first & 0x7F)
            guard n >= 1, n <= 4, i + n <= der.count else { return nil }
            var len = 0
            for _ in 0..<n { len = len << 8 | Int(der[i]); i += 1 }
            return len
        }
        func integer() -> [UInt8]? {
            guard i < der.count, der[i] == 0x02 else { return nil }
            i += 1
            guard let len = length(), len > 0, i + len <= der.count else { return nil }
            var v = Array(der[i..<(i + len)])
            i += len
            while v.count > 1 && v[0] == 0 { v.removeFirst() }
            return v
        }
        guard der.first == 0x30 else { return nil }
        i = 1
        guard let seqLen = length(), i + seqLen <= der.count, let n = integer(), let e = integer() else { return nil }
        return (n, e)
    }

    /// What's hashed (SHA-256) for the pairing secret, as androidtvremote2 does: the client's modulus and exponent,
    /// the TV's modulus and exponent (each as big-endian bytes without leading zeros), then the code after its
    /// first byte (the first byte is the hash's own first byte, a check).
    static func secretInput(clientModulus: [UInt8], clientExponent: [UInt8], serverModulus: [UInt8], serverExponent: [UInt8],
                            code: [UInt8]) -> [UInt8] {
        clientModulus + clientExponent + serverModulus + serverExponent + Array(code.dropFirst())
    }
}

// MARK: - End wire format
