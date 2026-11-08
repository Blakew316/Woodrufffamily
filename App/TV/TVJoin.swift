import SwiftUI
import Network
import CoreImage
import CoreImage.CIFilterBuiltins
import WoodruffKit

/// Connecting this Apple TV to the family from an iPhone: the Apple TV listens on the Wi‑Fi and shows a QR code; the
/// iPhone's camera opens it in Woodruff (woodruff://join), which sends the family's code here. With it the settings
/// sync brings every TV, key and sign-in, as on any new device. Only a request carrying the code's one-time token
/// is taken.
@Observable @MainActor
final class TVJoin {
    static let shared = TVJoin()

    private(set) var link: URL?
    private(set) var message: String?
    private var listener: NWListener?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    func start() {
        guard listener == nil, let l = try? NWListener(using: .tcp, on: .any) else { return }
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in self?.serve(c) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, case .ready = state, let port = self.listener?.port?.rawValue, let ip = Self.address() else { return }
                var c = URLComponents()
                c.scheme = "woodruff"; c.host = "join"
                c.queryItems = [URLQueryItem(name: "u", value: "http://\(ip):\(port)"), URLQueryItem(name: "t", value: self.token)]
                self.link = c.url
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// One request: POST /join with {"t": token, "code": family code}.
    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                var status = "400 Bad Request", body = "{\"ok\":false}"
                if let split = text.range(of: "\r\n\r\n"),
                   let json = try? JSONSerialization.jsonObject(with: Data(text[split.upperBound...].utf8)) as? [String: Any],
                   json["t"] as? String == self.token, let code = json["code"] as? String {
                    if let problem = SettingsSync.shared.enter(code: code) {
                        self.message = problem
                        body = "{\"ok\":false,\"error\":\(Self.quoted(problem))}"
                    } else {
                        self.message = "Connected. The family’s TVs and settings are coming over."
                        status = "200 OK"; body = "{\"ok\":true}"
                    }
                }
                let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    private static func quoted(_ s: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
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

/// The QR code to scan with the iPhone's camera, and what it does.
struct ConnectPhoneCard: View {
    private let join = TVJoin.shared

    var body: some View {
        HStack(alignment: .center, spacing: 50) {
            if let link = join.link, let img = Self.qr(link.absoluteString) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView().frame(width: 332, height: 332)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect Your iPhone").font(.title2.bold())
                Text("Point your iPhone’s camera at this code and open it in Woodruff. Your TVs, keys and settings come over by themselves.")
                    .foregroundStyle(.secondary)
                if let m = join.message { Text(m).font(.headline) }
            }
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear { join.start() }
    }

    static func qr(_ text: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
