import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Direct control of an LG webOS TV over LG's own "SSAP" WebSocket (the protocol LG's ThinQ remote uses).
///
/// Woodruff's own `/api/key` only reaches Woodruff while it's on screen (webOS gives one app no keys in
/// another). Paired this way the phone or Mac is a full remote everywhere: arrows, OK, Back, Home, volume,
/// channels, typing, apps, inputs, power off, and a pointer. The TV asks once ("Allow this device?") and
/// hands back a client key that's kept for next time.
public actor LGRemote {
    public enum Button: String, CaseIterable, Sendable {
        case up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT", enter = "ENTER", back = "BACK"
        case home = "HOME", menu = "MENU", exit = "EXIT", info = "INFO", dash = "DASH"
        case play = "PLAY", pause = "PAUSE", stop = "STOP", rewind = "REWIND", fastForward = "FASTFORWARD"
        case volumeUp = "VOLUMEUP", volumeDown = "VOLUMEDOWN", mute = "MUTE"
        case channelUp = "CHANNELUP", channelDown = "CHANNELDOWN", guide = "GUIDE", qmenu = "QMENU"
        case red = "RED", green = "GREEN", yellow = "YELLOW", blue = "BLUE"
        case n0 = "0", n1 = "1", n2 = "2", n3 = "3", n4 = "4", n5 = "5", n6 = "6", n7 = "7", n8 = "8", n9 = "9"
    }

    public struct App: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var icon: URL?
    }

    public let host: String
    public private(set) var clientKey: String?
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    /// The TV has accepted this device on `socket` (requests sent before that are refused).
    private var registered = false
    private var pointer: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var registerWaiter: CheckedContinuation<String, Error>?
    /// Which registration the waiter belongs to, so a timeout left over from an earlier one never fails it.
    private var registration = 0
    /// The TV is showing "Allow this device?" for the registration under way.
    private var prompting = false
    /// A connection being made, shared by everyone who needs one meanwhile (two key presses at once used to
    /// open two, or send on one the TV hadn't accepted yet).
    private var connecting: Task<String, Error>?
    /// The address that worked last time (TLS on 3001, or plain on 3000), tried first next time.
    private var preferred: String?
    private var counter = 0
    /// Told the key whenever the TV gives one other than the key this connection had (it forgot this device and asked
    /// "Allow?" again, or none was kept here), so the app keeps it: kept only here, the TV asked again every time the
    /// app opened.
    private let onNewKey: (@Sendable (String) -> Void)?

    /// [clientKey]: the key the TV gave last time (nil the first time: the TV then asks on screen).
    public init(host: String, clientKey: String?, onNewKey: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.clientKey = clientKey
        self.onNewKey = onNewKey
        self.session = URLSession(configuration: .ephemeral, delegate: TrustTVCertificate(host: host), delegateQueue: nil)
    }

    /// A session holds its delegate (and its sockets) until it's invalidated: without this, every remote replaced in
    /// `Fleet.lg(for:)` (a new sign-in, a new address) left its session and connections behind for good.
    deinit {
        session.invalidateAndCancel()
    }

    /// Connects and registers. Returns the client key to keep (new or the same).
    @discardableResult
    public func connect() async throws -> String {
        if socket != nil, registered, let clientKey { return clientKey }
        if let running = connecting { return try await running.value }
        let t = Task { try await self.openConnection() }
        connecting = t
        let result = await t.result
        if connecting == t { connecting = nil }
        return try result.get()
    }

    /// Opens a socket and registers on it: newer TVs (2018+, webOS 4+) want TLS on 3001; older ones answer plain
    /// on 3000.
    private func openConnection() async throws -> String {
        closeSocket(TVError.offline("Reconnecting"))
        var lastError: Error = TVError.offline("Couldn't reach \(host)")
        var urls = ["wss://\(host):3001/", "ws://\(host):3000/"]
        if let preferred, let i = urls.firstIndex(of: preferred), i > 0 { urls.swapAt(0, i) }
        for url in urls {
            try Task.checkCancellation()
            guard let u = URL(string: url) else { continue }
            let task = session.webSocketTask(with: u)
            task.maximumMessageSize = 4 * 1024 * 1024
            task.resume()
            socket = task
            registered = false
            receive(on: task)
            do {
                let key = try await register(on: task)
                guard socket === task else { throw TVError.offline("Disconnected") }
                let given = key != clientKey
                clientKey = key
                registered = true
                preferred = url
                if given { onNewKey?(key) }
                return key
            } catch {
                lastError = error
                task.cancel(with: .goingAway, reason: nil)
                if socket === task { socket = nil; registered = false }
                // Nothing answered at all (the TV is off or away): the other port won't either.
                if let e = error as? TVError, e == Self.noAnswer(host) { break }
            }
        }
        throw lastError
    }

    private static func noAnswer(_ host: String) -> TVError { .offline("\(host) didn't answer. Is the TV on?") }

    public func disconnect() {
        connecting?.cancel()
        connecting = nil
        closeSocket(TVError.offline("Disconnected"))
    }

    /// Ends the socket and the pointer socket, and fails everything waiting on them.
    private func closeSocket(_ e: Error) {
        socket?.cancel(with: .goingAway, reason: nil)
        pointer?.cancel(with: .goingAway, reason: nil)
        socket = nil
        registered = false
        pointer = nil
        for (_, c) in pending { c.resume(throwing: e) }
        pending = [:]
        registerWaiter?.resume(throwing: e)
        registerWaiter = nil
    }

    // MARK: Commands

    public func press(_ button: Button) async throws {
        try await sendPointer("type:button\nname:\(button.rawValue)\n\n")
    }

    public func click() async throws {
        try await sendPointer("type:click\n\n")
    }

    public func move(dx: Double, dy: Double, drag: Bool = false) async throws {
        try await sendPointer("type:move\ndx:\(Int(dx))\ndy:\(Int(dy))\ndown:\(drag ? 1 : 0)\n\n")
    }

    public func scroll(dx: Double, dy: Double) async throws {
        try await sendPointer("type:scroll\ndx:\(Int(dx))\ndy:\(Int(dy))\n\n")
    }

    public func volumeUp() async throws { _ = try await call("ssap://audio/volumeUp") }
    public func volumeDown() async throws { _ = try await call("ssap://audio/volumeDown") }
    public func setMute(_ on: Bool) async throws { _ = try await call("ssap://audio/setMute", ["mute": .bool(on)]) }
    public func setVolume(_ v: Int) async throws { _ = try await call("ssap://audio/setVolume", ["volume": .number(Double(max(0, min(100, v))))]) }

    public func volume() async throws -> (level: Int, muted: Bool) {
        let r = try await call("ssap://audio/getVolume")
        let level = r["volume"]?.int ?? r["volumeStatus"]?["volume"]?.int ?? 0
        let muted = r["muted"]?.bool ?? r["volumeStatus"]?["muteStatus"]?.bool ?? false
        return (level, muted)
    }

    public func turnOff() async throws {
        do {
            // Not `call`: asking again after the connection drops would only find the TV already off.
            _ = try await request("ssap://system/turnOff", [:])
        } catch let e as TVError where e == Self.connectionLost || e == Self.timedOut {
            // Going off, the TV often closes the connection before it answers: that's it doing what was asked,
            // not a failure to show.
        }
    }
    public func screenOff() async throws {
        do {
            _ = try await call("ssap://com.webos.service.tvpower/power/turnOffScreen", ["standbyMode": .string("active")])
        } catch let e as TVError where e.status == 400 {
            // webOS 4 keeps it under another name.
            _ = try await call("ssap://com.webos.service.tv.power/turnOffScreen", ["standbyMode": .string("active")])
        }
    }

    public func launch(_ appId: String, params: [String: JSONValue]? = nil) async throws {
        var p: [String: JSONValue] = ["id": .string(appId)]
        if let params { p["params"] = .object(params) }
        _ = try await call("ssap://system.launcher/launch", p)
    }

    public func openURL(_ url: URL) async throws { _ = try await call("ssap://system.launcher/open", ["target": .string(url.absoluteString)]) }

    public func insertText(_ text: String, replace: Bool = false) async throws {
        _ = try await call("ssap://com.webos.service.ime/insertText", ["text": .string(text), "replace": .number(replace ? 1 : 0)])
    }
    public func sendEnter() async throws { _ = try await call("ssap://com.webos.service.ime/sendEnterKey") }

    public func apps() async throws -> [App] {
        let r = try await call("ssap://com.webos.applicationManager/listLaunchPoints")
        return r["launchPoints"]?.array.compactMap { a in
            guard let id = a["id"]?.string, let title = a["title"]?.string else { return nil }
            return App(id: id, title: title, icon: a["icon"]?.string.flatMap(URL.init(string:)))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } ?? []
    }

    public func inputs() async throws -> [App] {
        let r = try await call("ssap://tv/getExternalInputList")
        return r["devices"]?.array.compactMap { d in
            guard let id = d["id"]?.string else { return nil }
            return App(id: id, title: d["label"]?.string ?? id, icon: d["icon"]?.string.flatMap(URL.init(string:)))
        } ?? []
    }
    public func switchInput(_ id: String) async throws { _ = try await call("ssap://tv/switchInput", ["inputId": .string(id)]) }

    /// The TV's network MAC address (for Wake-on-LAN), when it says.
    public func macAddress() async -> String? {
        guard let r = try? await call("ssap://com.webos.service.connectionmanager/getinfo") else { return nil }
        return r["wiredInfo"]?["macAddress"]?.string ?? r["wifiInfo"]?["macAddress"]?.string
    }

    /// Any SSAP request (`ssap://…`).
    public func call(_ uri: String, _ payload: [String: JSONValue] = [:]) async throws -> JSONValue {
        let wasOpen = socket != nil && registered
        do {
            return try await request(uri, payload)
        } catch let e as TVError where wasOpen && e == Self.connectionLost {
            // The connection had gone without saying so (the TV restarted, the app was asleep): the first tap after
            // that used to fail. Connect again and ask once more.
            return try await request(uri, payload)
        }
    }

    private static let connectionLost = TVError.offline("The connection to the TV dropped. Try again.")

    private func request(_ uri: String, _ payload: [String: JSONValue]) async throws -> JSONValue {
        if socket == nil || !registered { try await connect() }
        guard let socket, registered else { throw TVError.offline("Not connected") }
        counter += 1
        let id = "req_\(counter)"
        var msg: [String: JSONValue] = ["type": .string("request"), "id": .string(id), "uri": .string(uri)]
        if !payload.isEmpty { msg["payload"] = .object(payload) }
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(msg)), as: UTF8.self)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
            pending[id] = c
            Task { await self.send(text, id: id, on: socket) }
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self.expire(id, on: socket)
            }
        }
    }

    // MARK: Internals

    private func send(_ text: String, id: String, on task: URLSessionWebSocketTask) async {
        do { try await task.send(.string(text)) } catch {
            pending.removeValue(forKey: id)?.resume(throwing: Self.connectionLost)
            // The socket is gone: let it go (and everything waiting on it), so the next request connects afresh.
            drop(task, Self.connectionLost)
        }
    }

    private static let timedOut = TVError.offline("The TV didn't answer in time")

    private func expire(_ id: String, on task: URLSessionWebSocketTask) {
        guard let c = pending.removeValue(forKey: id) else { return }
        c.resume(throwing: Self.timedOut)
        // No answer in ten seconds: the connection has gone without saying so (the TV slept, the Wi‑Fi dropped).
        // Start again next time rather than keep asking on a dead one.
        drop(task, TVError.offline("The TV stopped answering"))
    }

    /// Ends [task] if it's still the socket in use, failing what's waiting on it.
    private func drop(_ task: URLSessionWebSocketTask, _ e: Error) {
        guard task === socket else { return }
        closeSocket(e)
    }

    private func register(on task: URLSessionWebSocketTask) async throws -> String {
        var payload: [String: JSONValue] = ["forcePairing": .bool(false), "pairingType": .string("PROMPT"), "manifest": Self.manifest]
        if let clientKey { payload["client-key"] = .string(clientKey) }
        let msg: JSONValue = .object(["type": .string("register"), "id": .string("register_0"), "payload": .object(payload)])
        let text = String(decoding: try JSONEncoder().encode(msg), as: UTF8.self)
        registration += 1
        let n = registration
        let paired = clientKey != nil
        prompting = false
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            // Never two waiting: an older one (there shouldn't be any) is let go first.
            registerWaiter?.resume(throwing: TVError.offline("Reconnecting"))
            registerWaiter = c
            Task {
                do { try await task.send(.string(text)) } catch { await self.failRegister(error, registration: n) }
            }
            // Paired before, a TV that's there answers in a moment; one that's off never does, so it isn't waited
            // on long. The first time (or when it asks again on screen), whoever has the TV's remote gets a minute
            // to press Allow.
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self.registerTimedOut(n, giveUp: false, paired: paired)
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                await self.registerTimedOut(n, giveUp: true, paired: paired)
            }
        }
    }

    private func registerTimedOut(_ n: Int, giveUp: Bool, paired: Bool) {
        guard n == registration, registerWaiter != nil else { return }
        if giveUp {
            failRegister(TVError.offline("Nobody allowed the connection on the TV in time."), registration: n)
        } else if paired && !prompting {
            failRegister(Self.noAnswer(host), registration: n)
        }
    }

    /// Fails the registration waiting (only [registration]'s, when one is named).
    private func failRegister(_ e: Error, registration n: Int? = nil) {
        if let n, n != registration { return }
        registerWaiter?.resume(throwing: e)
        registerWaiter = nil
    }

    private nonisolated func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let m):
                var data: Data?
                switch m {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    Task { await self.handle(v, from: task) }
                }
                self.receive(on: task)
            case .failure(let e):
                Task { await self.closed(task, e) }
            }
        }
    }

    private func closed(_ task: URLSessionWebSocketTask, _ e: Error) {
        guard task === socket else { return }
        closeSocket(registered ? Self.connectionLost : TVError.offline(e.localizedDescription))
    }

    private func handle(_ v: JSONValue, from task: URLSessionWebSocketTask) {
        let type = v["type"]?.string
        let id = v["id"]?.string ?? ""
        if id == "register_0" {
            // Only the socket being registered speaks for the registration (not one let go a moment ago).
            guard task === socket else { return }
            if type == "registered", let key = v["payload"]?["client-key"]?.string {
                registerWaiter?.resume(returning: key)
                registerWaiter = nil
            } else if type == "error" {
                failRegister(TVError.http(status: 403, message: v["error"]?.string ?? "The TV said no"))
            } else if v["payload"]?["pairingType"]?.string == "PROMPT" {
                // The TV answered and may be asking on screen ("Allow this device?"): wait for whoever has its remote.
                prompting = true
            }
            return
        }
        guard let c = pending.removeValue(forKey: id) else { return }
        if type == "error" || v["payload"]?["returnValue"]?.bool == false {
            let m = v["error"]?.string ?? v["payload"]?["errorText"]?.string ?? "The TV refused that"
            c.resume(throwing: TVError.http(status: 400, message: m))
        } else {
            c.resume(returning: v["payload"] ?? .null)
        }
    }

    private func pointerSocket() async throws -> URLSessionWebSocketTask {
        if let pointer { return pointer }
        let r = try await call("ssap://com.webos.service.networkinput/getPointerInputSocket")
        // Another press opened one while this one waited.
        if let pointer { return pointer }
        guard let path = r["socketPath"]?.string, let url = URL(string: path) else { throw TVError.badAnswer("No pointer socket") }
        let p = session.webSocketTask(with: url)
        p.resume()
        pointer = p
        receivePointer(on: p)
        return p
    }

    /// Sends one message on the pointer socket (every key, click and move goes this way). A pointer socket that
    /// has gone (the TV closed it) used to fail every key until the app restarted: now a new one is opened and the
    /// key sent again.
    private func sendPointer(_ text: String) async throws {
        let p = try await pointerSocket()
        do {
            try await p.send(.string(text))
        } catch {
            if pointer === p { pointer = nil }
            p.cancel(with: .goingAway, reason: nil)
            try await pointerSocket().send(.string(text))
        }
    }

    /// Watches the pointer socket only to notice it closing, so the next key opens a new one straight away.
    private nonisolated func receivePointer(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.receivePointer(on: task)
            case .failure: Task { await self.pointerClosed(task) }
            }
        }
    }

    private func pointerClosed(_ task: URLSessionWebSocketTask) {
        if pointer === task { pointer = nil }
    }

    /// LG's published sample-app manifest (the one every open-source LG remote sends).
    static let manifest: JSONValue = {
        let json = #"""
        {"manifestVersion":1,"appVersion":"1.1","signed":{"created":"20140509","appId":"com.lge.test","vendorId":"com.lge",
        "localizedAppNames":{"":"LG Remote App","ko-KR":"리모컨 앱","zxx-XX":"ЛГ Rэмotэ AПП"},"localizedVendorNames":{"":"LG Electronics"},
        "permissions":["TEST_SECURE","CONTROL_INPUT_TEXT","CONTROL_MOUSE_AND_KEYBOARD","READ_INSTALLED_APPS","READ_LGE_SDX","READ_NOTIFICATIONS","SEARCH","WRITE_SETTINGS","WRITE_NOTIFICATION_ALERT","CONTROL_POWER","READ_CURRENT_CHANNEL","READ_RUNNING_APPS","READ_UPDATE_INFO","UPDATE_FROM_REMOTE_APP","READ_LGE_TV_INPUT_EVENTS","READ_TV_CURRENT_TIME"],
        "serial":"2f930e2d2cfe083771f68e4fe7bb07"},
        "permissions":["LAUNCH","LAUNCH_WEBAPP","APP_TO_APP","CLOSE","TEST_OPEN","TEST_PROTECTED","CONTROL_AUDIO","CONTROL_DISPLAY","CONTROL_INPUT_JOYSTICK","CONTROL_INPUT_MEDIA_RECORDING","CONTROL_INPUT_MEDIA_PLAYBACK","CONTROL_INPUT_TV","CONTROL_POWER","READ_APP_STATUS","READ_CURRENT_CHANNEL","READ_INPUT_DEVICE_LIST","READ_NETWORK_STATE","READ_RUNNING_APPS","READ_TV_CHANNEL_LIST","WRITE_NOTIFICATION_TOAST","READ_POWER_STATE","READ_COUNTRY_INFO","READ_SETTINGS","CONTROL_TV_SCREEN","CONTROL_TV_STANBY","CONTROL_FAVORITE_GROUP","CONTROL_USER_INFO","CHECK_BLUETOOTH_DEVICE","CONTROL_BLUETOOTH","CONTROL_TIMER_INFO","STB_INTERNAL_CONNECTION","CONTROL_RECORDING","READ_RECORDING_STATE","WRITE_RECORDING_LIST","READ_RECORDING_LIST","READ_RECORDING_SCHEDULE","WRITE_RECORDING_SCHEDULE","READ_STORAGE_DEVICE_LIST","READ_TV_PROGRAM_INFO","CONTROL_BOX_CHANNEL","READ_TV_ACR_AUTH_TOKEN","READ_TV_CONTENT_STATE","READ_TV_CURRENT_TIME","ADD_LAUNCHER_CHANNEL","SET_CHANNEL_SKIP","RELEASE_CHANNEL_SKIP","CONTROL_CHANNEL_BLOCK","DELETE_SELECT_CHANNEL","CONTROL_CHANNEL_GROUP","SCAN_TV_CHANNELS","CONTROL_TV_POWER","CONTROL_WOL"],
        "signatures":[{"signatureVersion":1,"signature":"eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw=="}]}
        """#
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
    }()
}

/// LG TVs present a self-signed certificate on 3001: trust it for that one host only.
final class TrustTVCertificate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security) && !os(Linux)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}

