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
    private var pointer: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var registerWaiter: CheckedContinuation<String, Error>?
    private var counter = 0

    /// [clientKey]: the key the TV gave last time (nil the first time: the TV then asks on screen).
    public init(host: String, clientKey: String?) {
        self.host = host
        self.clientKey = clientKey
        self.session = URLSession(configuration: .ephemeral, delegate: TrustTVCertificate(host: host), delegateQueue: nil)
    }

    public var isConnected: Bool { socket != nil }

    /// Connects and registers. Returns the client key to keep (new or the same).
    @discardableResult
    public func connect() async throws -> String {
        if socket != nil, let clientKey { return clientKey }
        disconnect()
        // Newer TVs (2018+, webOS 4+) want TLS on 3001; older ones answer plain on 3000.
        var lastError: Error = TVError.offline("Couldn't reach \(host)")
        for url in ["wss://\(host):3001/", "ws://\(host):3000/"] {
            let task = session.webSocketTask(with: URL(string: url)!)
            task.maximumMessageSize = 4 * 1024 * 1024
            task.resume()
            socket = task
            receive(on: task)
            do {
                let key = try await register()
                clientKey = key
                return key
            } catch {
                lastError = error
                task.cancel(with: .goingAway, reason: nil)
                socket = nil
            }
        }
        throw lastError
    }

    public func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        pointer?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pointer = nil
        for (_, c) in pending { c.resume(throwing: TVError.offline("Disconnected")) }
        pending = [:]
        registerWaiter?.resume(throwing: TVError.offline("Disconnected"))
        registerWaiter = nil
    }

    // MARK: Commands

    public func press(_ button: Button) async throws {
        let p = try await pointerSocket()
        try await p.send(.string("type:button\nname:\(button.rawValue)\n\n"))
    }

    public func click() async throws {
        try await pointerSocket().send(.string("type:click\n\n"))
    }

    public func move(dx: Double, dy: Double, drag: Bool = false) async throws {
        try await pointerSocket().send(.string("type:move\ndx:\(Int(dx))\ndy:\(Int(dy))\ndown:\(drag ? 1 : 0)\n\n"))
    }

    public func scroll(dx: Double, dy: Double) async throws {
        try await pointerSocket().send(.string("type:scroll\ndx:\(Int(dx))\ndy:\(Int(dy))\n\n"))
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

    public func turnOff() async throws { _ = try await call("ssap://system/turnOff") }
    public func screenOff() async throws { _ = try await call("ssap://com.webos.service.tvpower/power/turnOffScreen", ["standbyMode": .string("active")]) }
    public func screenOn() async throws { _ = try await call("ssap://com.webos.service.tvpower/power/turnOnScreen", ["standbyMode": .string("active")]) }
    public func toast(_ message: String) async throws { _ = try await call("ssap://system.notifications/createToast", ["message": .string(message)]) }

    public func launch(_ appId: String, params: [String: JSONValue]? = nil) async throws {
        var p: [String: JSONValue] = ["id": .string(appId)]
        if let params { p["params"] = .object(params) }
        _ = try await call("ssap://system.launcher/launch", p)
    }

    public func openURL(_ url: URL) async throws { _ = try await call("ssap://system.launcher/open", ["target": .string(url.absoluteString)]) }

    public func insertText(_ text: String, replace: Bool = false) async throws {
        _ = try await call("ssap://com.webos.service.ime/insertText", ["text": .string(text), "replace": .number(replace ? 1 : 0)])
    }
    public func deleteCharacters(_ n: Int) async throws {
        _ = try await call("ssap://com.webos.service.ime/deleteCharacters", ["count": .number(Double(n))])
    }
    public func sendEnter() async throws { _ = try await call("ssap://com.webos.service.ime/sendEnterKey") }

    public func apps() async throws -> [App] {
        let r = try await call("ssap://com.webos.applicationManager/listLaunchPoints")
        return r["launchPoints"]?.array.compactMap { a in
            guard let id = a["id"]?.string, let title = a["title"]?.string else { return nil }
            return App(id: id, title: title, icon: a["icon"]?.string.flatMap(URL.init(string:)))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } ?? []
    }

    public func foregroundApp() async throws -> String? {
        try await call("ssap://com.webos.applicationManager/getForegroundAppInfo")["appId"]?.string
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

    public func systemInfo() async throws -> JSONValue { try await call("ssap://system/getSystemInfo") }
    public func softwareInfo() async throws -> JSONValue { try await call("ssap://com.webos.service.update/getCurrentSWInformation") }

    /// Any SSAP request (`ssap://…`).
    public func call(_ uri: String, _ payload: [String: JSONValue] = [:]) async throws -> JSONValue {
        if socket == nil { try await connect() }
        guard let socket else { throw TVError.offline("Not connected") }
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
                await self.expire(id)
            }
        }
    }

    // MARK: Internals

    private func send(_ text: String, id: String, on socket: URLSessionWebSocketTask) async {
        do { try await socket.send(.string(text)) } catch {
            pending.removeValue(forKey: id)?.resume(throwing: TVError.offline(error.localizedDescription))
            if self.socket === socket { self.socket = nil; pointer = nil }
        }
    }

    private func expire(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: TVError.offline("The TV didn't answer in time"))
    }

    private func register() async throws -> String {
        guard let socket else { throw TVError.offline("Not connected") }
        var payload: [String: JSONValue] = ["forcePairing": .bool(false), "pairingType": .string("PROMPT"), "manifest": Self.manifest]
        if let clientKey { payload["client-key"] = .string(clientKey) }
        let msg: JSONValue = .object(["type": .string("register"), "id": .string("register_0"), "payload": .object(payload)])
        let text = String(decoding: try JSONEncoder().encode(msg), as: UTF8.self)
        return try await withCheckedThrowingContinuation { c in
            registerWaiter = c
            Task {
                do { try await socket.send(.string(text)) } catch { await self.failRegister(error) }
            }
            // The TV's "Allow?" prompt waits for someone with its remote: a minute at most.
            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self.failRegister(TVError.offline("Nobody allowed the connection on the TV in time."))
            }
        }
    }

    private func failRegister(_ e: Error) {
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
                    Task { await self.handle(v) }
                }
                self.receive(on: task)
            case .failure(let e):
                Task { await self.closed(task, e) }
            }
        }
    }

    private func closed(_ task: URLSessionWebSocketTask, _ e: Error) {
        guard task === socket else { return }
        socket = nil
        pointer = nil
        failRegister(TVError.offline(e.localizedDescription))
        for (_, c) in pending { c.resume(throwing: TVError.offline("The TV closed the connection")) }
        pending = [:]
    }

    private func handle(_ v: JSONValue) {
        let type = v["type"]?.string
        let id = v["id"]?.string ?? ""
        if id == "register_0" {
            if type == "registered", let key = v["payload"]?["client-key"]?.string {
                registerWaiter?.resume(returning: key)
                registerWaiter = nil
            } else if type == "error" {
                failRegister(TVError.http(status: 403, message: v["error"]?.string ?? "The TV said no"))
            }
            // "response" with pairingType PROMPT: the TV is asking on screen; keep waiting.
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
        guard let path = r["socketPath"]?.string, let url = URL(string: path) else { throw TVError.badAnswer("No pointer socket") }
        let p = session.webSocketTask(with: url)
        p.resume()
        pointer = p
        return p
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

