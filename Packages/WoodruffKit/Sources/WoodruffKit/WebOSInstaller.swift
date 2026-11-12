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
    static func run(_ ssh: WebOSSSH, _ command: String, stdin: URL? = nil, limit: TimeInterval = 120) async throws -> (Int32, String) {
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
            // An ssh that never ends (a TV that stopped answering half-way) is ended here: nothing waits on it for ever.
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { if p.isRunning { p.terminate() } }
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

    /// Installs [ipk] and, with [launch], opens Woodruff. [progress] gets one line per step. Throws unless the TV
    /// itself said the package was installed (it used to count a TV that said nothing as done).
    public static func install(_ ipk: URL, on ssh: WebOSSSH, launch: Bool = true, progress: @escaping @Sendable (String) -> Void) async throws {
        let dest = ssh.destination
        progress("Copying \(ipk.lastPathComponent) to \(ssh.host)…")
        let dir = (dest as NSString).deletingLastPathComponent
        var (code, out) = try await run(ssh, "mkdir -p \(dir) && cat > \(dest)", stdin: ipk)
        guard code == 0 else { throw TVError.badAnswer("Copy failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        progress("Installing…")
        (code, out) = try await run(ssh, installScript(dest: dest, launch: launch), limit: 300)
        let said = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said.contains("WOODRUFF-INSTALLED") else {
            let why = said.replacingOccurrences(of: "WOODRUFF-NOT-INSTALLED", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw TVError.badAnswer("The TV didn’t install the package: " + (why.isEmpty ? "it said nothing (ssh ended with \(code))" : String(why.suffix(700))))
        }
        progress(launch ? "Installed. Woodruff is opening on the TV." : "Installed.")
    }

    /// What runs on the TV: the install with each of the TV's two luna tools in turn (a rooted TV and one in Developer
    /// Mode don't have the same one), waiting for the TV to say "installed"; then Woodruff's service there is ended
    /// and started again, since one that's running keeps the old build until it stops; then Woodruff is opened, or
    /// its service woken. It prints what the TV said, and WOODRUFF-INSTALLED only when the TV said so.
    static func installScript(dest: String, launch: Bool) -> String {
        let dir = (dest as NSString).deletingLastPathComponent
        let payload = #"{"id":"com.ares.defaultName","ipkUrl":"\#(dest)","subscribe":true}"#
        let open = #"{"id":"\#(appId)"}"#
        let after = launch
            ? "$T -n 1 luna://com.webos.applicationManager/launch '\(open)' >/dev/null 2>&1"
            : "($T -n 1 luna://$S/ping '{}' >/dev/null 2>&1 & Q=$!; sleep 4; kill $Q 2>/dev/null)"
        // The service's name is put together on the TV, so this script's own shell isn't taken for the service.
        return """
        L=\(dir)/woodruff-install.log; ok=0; T=
        for C in luna-send-pub luna-send; do
          command -v $C >/dev/null 2>&1 || continue
          T=$C; rm -f $L
          $C -i luna://com.webos.appInstallService/dev/install '\(payload)' >$L 2>&1 &
          P=$!; i=0
          while [ $i -lt 120 ]; do
            grep -q -e '"installed"' -e errorText -e ailed -e AILED $L 2>/dev/null && break
            kill -0 $P 2>/dev/null || break
            sleep 1; i=$((i+1))
          done
          kill $P 2>/dev/null
          echo "[$C] $(tail -c 400 $L 2>/dev/null | tr '\\n' ' ')"
          if grep -q '"installed"' $L 2>/dev/null; then ok=1; break; fi
        done
        [ -n "$T" ] || echo "this TV has neither luna-send-pub nor luna-send"
        rm -f $L \(dest)
        if [ $ok != 1 ]; then echo WOODRUFF-NOT-INSTALLED; exit 1; fi
        S=\(appId).servic; S=${S}e
        for d in /proc/[0-9]*; do
          p=${d#/proc/}; [ "$p" = "$$" ] && continue
          c=$(tr '\\000' ' ' < $d/cmdline 2>/dev/null)
          case "$c" in *home-watch*) ;; *"$S"*) kill $p 2>/dev/null ;; esac
        done
        sleep 1
        \(after)
        echo WOODRUFF-INSTALLED
        """
    }
}
#endif
