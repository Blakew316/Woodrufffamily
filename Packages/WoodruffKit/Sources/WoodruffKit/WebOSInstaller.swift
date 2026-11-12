import Foundation

/// How the Mac reaches an LG TV's shell to install Woodruff (webosbrew Developer Mode, or a rooted TV).
public struct WebOSSSH: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case developerMode, root
        public var label: String { self == .root ? "Rooted (root, port 22)" : "Developer Mode (prisoner, port 9922)" }
    }
    public var host: String
    public var mode: Mode
    /// Private key file; empty = try ~/.ssh/tv_webos, webos_tv, lgtv_webos, then the ssh agent.
    public var keyPath: String

    public init(host: String, mode: Mode = .developerMode, keyPath: String = "") {
        self.host = host; self.mode = mode; self.keyPath = keyPath
    }

    public var user: String { mode == .root ? "root" : "prisoner" }
    public var port: Int { mode == .root ? 22 : 9922 }
    var destination: String { mode == .root ? "/tmp/woodruff.ipk" : "/media/developer/temp/woodruff.ipk" }
}

#if os(macOS)
/// Pushes a webOS package to an LG TV exactly as `webos/tools/install.sh --ssh` does:
/// copy the .ipk over SSH, install it with appInstallService, open the app.
public enum WebOSInstaller {
    public static let appId = "com.woodruff.family"

    static func keyArgs(_ ssh: WebOSSSH) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ssh.keyPath.isEmpty
            ? ["\(home)/.ssh/tv_webos", "\(home)/.ssh/webos_tv", "\(home)/.ssh/lgtv_webos"]
            : [(ssh.keyPath as NSString).expandingTildeInPath]
        if let k = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { return ["-i", k] }
        return []
    }

    static func baseArgs(_ ssh: WebOSSSH) -> [String] {
        ["-o", "StrictHostKeyChecking=accept-new", "-o", "HostKeyAlgorithms=+ssh-rsa", "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
         "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"] + keyArgs(ssh) + ["-p", String(ssh.port), "\(ssh.user)@\(ssh.host)"]
    }

    /// Runs ssh with [command], [stdin] fed from a file. Returns (exit code, output).
    static func run(_ ssh: WebOSSSH, _ command: String, stdin: URL? = nil) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = baseArgs(ssh) + [command]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var input: FileHandle?
            if let stdin {
                guard let h = try? FileHandle(forReadingFrom: stdin) else { cont.resume(throwing: TVError.badAnswer("Can't read the package")); return }
                p.standardInput = h
                input = h
            }
            do { try p.run() } catch {
                try? input?.close()
                cont.resume(throwing: error)
                return
            }
            // The output is read while ssh runs, not after: one that filled the pipe (64 KB) waited for ever to
            // write the rest, and never exited. The package file is closed once it's done (it used to stay open).
            let handle = input
            DispatchQueue.global(qos: .userInitiated).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                try? handle?.close()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Checks the TV answers on SSH (Developer Mode's Dev Mode Status must be on).
    public static func test(_ ssh: WebOSSSH) async -> String? {
        do {
            let (code, out) = try await run(ssh, "echo ok")
            return code == 0 ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return error.localizedDescription }
    }

    /// Installs [ipk] and, with [launch], opens Woodruff. [progress] gets one line per step.
    public static func install(_ ipk: URL, on ssh: WebOSSSH, launch: Bool = true, progress: @escaping @Sendable (String) -> Void) async throws {
        let dest = ssh.destination
        progress("Copying \(ipk.lastPathComponent) to \(ssh.host)…")
        let dir = (dest as NSString).deletingLastPathComponent
        var (code, out) = try await run(ssh, "mkdir -p \(dir) && cat > \(dest)", stdin: ipk)
        guard code == 0 else { throw TVError.badAnswer("Copy failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        progress("Installing…")
        let payload = #"{"id":"com.ares.defaultName","ipkUrl":"\#(dest)","subscribe":true}"#
        let open = #"{"id":"\#(appId)"}"#
        let cmd = "luna-send-pub -w 30000 -i luna://com.webos.appInstallService/dev/install '\(payload)' 2>/dev/null | grep -m1 -E 'installed|failed|errorText'; rm -f \(dest)" + (launch ? "; luna-send-pub -n 1 luna://com.webos.applicationManager/launch '\(open)' >/dev/null" : "")
        (code, out) = try await run(ssh, cmd)
        let said = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.contains("failed") || said.contains("errorText") { throw TVError.badAnswer("The TV refused the package: \(said)") }
        progress(said.contains("installed") ? (launch ? "Installed. Woodruff is opening on the TV." : "Installed.") : "Sent. \(said)")
    }
}
#endif
