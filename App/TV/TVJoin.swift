import SwiftUI
import Network
import CoreImage
import CoreImage.CIFilterBuiltins
import WoodruffKit

/// Connecting this Apple TV to the family. It listens on the Wi‑Fi and is announced there (so the iPhone and Mac
/// apps list it under Settings → TVs → Apple TVs), and shows a QR code. Either way the family's code comes here and
/// the settings sync brings every TV, key and sign-in:
/// - the QR code (woodruff://join), opened in Woodruff with the iPhone's camera, carries a one-time token: taken at once;
/// - Connect in the iPhone or Mac app asks first, here on the TV screen ("Allow" with the remote).
@Observable @MainActor
final class TVJoin {
    static let shared = TVJoin()
    static let serviceType = "_woodruffatv._tcp"

    private(set) var link: URL?
    private(set) var message: String?
    /// A device asking to connect this Apple TV (its name), waiting for Allow on the screen.
    private(set) var asking: String?
    @ObservationIgnored private var waiting: (code: String, connection: NWConnection)?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var base: String?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    /// This Apple TV's own id (kept), and its name as the iPhone lists it.
    nonisolated static var id: String {
        if let s = UserDefaults.standard.string(forKey: "atv.id") { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: "atv.id")
        return s
    }
    nonisolated static var name: String {
        let s = UserDefaults.standard.string(forKey: "atv.name") ?? ""
        return s.isEmpty ? "Apple TV" : s
    }

    func start() {
        guard listener == nil, let l = try? NWListener(using: .tcp, on: .any) else { return }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.serve(c) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, case .ready = state, let port = self.listener?.port?.rawValue, let ip = Self.address() else { return }
                self.base = "http://\(ip):\(port)"
                var c = URLComponents()
                c.scheme = "woodruff"; c.host = "join"
                c.queryItems = [URLQueryItem(name: "u", value: self.base), URLQueryItem(name: "t", value: self.token)]
                self.link = c.url
                self.announce()
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// Announced on the Wi‑Fi with what the apps show: its name, build, address, and which family it's in (the
    /// family code's fingerprint, never the code).
    func announce() {
        guard let listener, let base else { return }
        var txt = NWTXTRecord()
        txt["id"] = Self.id
        txt["name"] = Self.name
        txt["u"] = base
        txt["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        txt["fp"] = Self.familyPrint() ?? ""
        listener.service = NWListener.Service(name: Self.name, type: Self.serviceType, domain: nil, txtRecord: txt)
    }

    static func familyPrint() -> String? {
        guard let code = FamilyCode.load().record?.code else { return nil }
        return FamilyCode.fingerprint(FamilyCode.key(code)).map { String(format: "%02x", $0) }.joined()
    }

    /// Allow (or not) the device asking.
    func answer(_ allow: Bool) {
        guard let w = waiting else { return }
        waiting = nil
        asking = nil
        if allow { take(w.code, reply: w.connection) } else { reply(w.connection, "403 Forbidden", ["ok": false, "error": "Not allowed on the Apple TV."]) }
    }

    // MARK: One request: POST /join

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    /// Reads until the whole request (its headers and Content-Length of body) is here.
    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var all = got
                if let data { all.append(data) }
                if let request = Self.complete(all) {
                    self.handle(request, c)
                } else if done || error != nil || all.count > 65_536 {
                    self.reply(c, "400 Bad Request", ["ok": false])
                } else {
                    self.read(c, all)
                }
            }
        }
    }

    /// The body, once the request is all here.
    private static func complete(_ d: Data) -> Data? {
        guard let split = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<split.lowerBound], as: UTF8.self).lowercased()
        var length = 0
        for line in head.components(separatedBy: "\r\n") where line.hasPrefix("content-length:") {
            length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = d[split.upperBound...]
        return body.count >= length ? Data(body) : nil
    }

    private func handle(_ body: Data, _ c: NWConnection) {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = json["code"] as? String, !code.isEmpty else {
            reply(c, "400 Bad Request", ["ok": false, "error": "No family code came."])
            return
        }
        if json["t"] as? String == token {
            take(code, reply: c)
            return
        }
        // Without the QR code's token: asked on the screen first. One at a time.
        if let w = waiting { reply(w.connection, "409 Conflict", ["ok": false, "error": "Another device asked at the same moment."]) }
        let from = (json["from"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A device"
        waiting = (code, c)
        asking = from
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if self.waiting?.connection === c {
                self.waiting = nil
                self.asking = nil
                self.reply(c, "408 Request Timeout", ["ok": false, "error": "Nobody allowed it on the Apple TV in time."])
            }
        }
    }

    private func take(_ code: String, reply c: NWConnection) {
        if let problem = SettingsSync.shared.enter(code: code) {
            message = problem
            reply(c, "409 Conflict", ["ok": false, "error": problem])
        } else {
            message = "Connected. The family’s TVs and settings are coming over."
            announce()
            reply(c, "200 OK", ["ok": true, "name": Self.name])
        }
    }

    private func reply(_ c: NWConnection, _ status: String, _ body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    /// This Apple TV's address on the Wi‑Fi or Ethernet (IPv4).
    private static func address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                if name == "en0" { break }
            }
        }
        return found
    }
}

/// The QR code to scan with the iPhone's camera, and the other way in (the iPhone app's Settings → TVs).
struct ConnectPhoneCard: View {
    private let join = TVJoin.shared

    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            if let link = join.link, let img = Self.qr(link.absoluteString) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                    .padding(18)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ProgressView().frame(width: 336, height: 336)
            }
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect Your iPhone").font(.title2.bold()).foregroundStyle(.white)
                Text("Point your iPhone’s camera at this code and open it in Woodruff. Or in Woodruff on your iPhone, go to Settings → TVs and choose Connect next to \(TVJoin.name).")
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your TVs, keys and settings come over by themselves.")
                    .font(.headline.weight(.regular))
                    .foregroundStyle(.white.opacity(0.75))
                if let m = join.message { Text(m).font(.headline).foregroundStyle(IconPalette.ice) }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .padding(50)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
    }

    static func qr(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
