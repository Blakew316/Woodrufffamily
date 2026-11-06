import SwiftUI
import AuthenticationServices
import WoodruffKit

/// Settings → Watch: where Watch's films and shows come from. "TV" is how it has always worked (on the home Wi‑Fi);
/// "Google Drive" is the app's own library, read straight from Drive, which works anywhere. Watch itself looks the
/// same either way.
struct WatchSettingsView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.webAuthenticationSession) private var webAuth
    @AppStorage("watch.source") private var source = "tv"
    @AppStorage("watch.playOn") private var playOn = "tv"
    private let library = DriveLibrary.shared

    @State private var signedIn = GoogleDrive.signedIn
    @State private var hasKeys = GoogleDrive.hasKeys
    @State private var hasTMDB = TMDB.key != nil
    @State private var busy = false
    @State private var message: String?
    @State private var clientID = GoogleDrive.clientID ?? ""
    @State private var secret = ""
    @State private var tmdbKey = ""
    @State private var showKeys = false

    var body: some View {
        Form {
            Section {
                Picker("Library", selection: $source) {
                    Text("TV").tag("tv")
                    Text("Google Drive").tag("drive")
                }
                .disabled(!signedIn && source == "tv")
            } footer: {
                Text(signedIn ? "TV reads the library from the TV on the home Wi‑Fi. Google Drive reads it straight from Drive, at home or away. Watch looks the same either way."
                              : "Sign in to Google Drive below to choose Google Drive, which works at home or away.")
            }

            Section {
                Picker("Play Button Plays On", selection: $playOn) {
                    Text("TV").tag("tv")
                    Text(PhonePlayback.deviceName).tag("here")
                }
            } footer: {
                Text(playOn == "here" ? "Play opens the film or episode here, from where it was left off. Play On… still sends it to a TV."
                                      : "Play sends the film or episode to the TV the remote is on.")
            }

            Section {
                if signedIn {
                    LabeledContent("Status", value: "Signed in")
                    LabeledContent("Titles", value: library.busy ? "Reading Drive…" : "\(library.titleCount)")
                    if let u = library.updated {
                        LabeledContent("Updated", value: u.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Read Drive Again") { Task { await library.refresh(force: true) } }
                        .disabled(library.busy)
                    Button("Sign Out", role: .destructive) {
                        GoogleDrive.signOut()
                        library.signedOut()
                        signedIn = false
                        source = "tv"
                    }
                } else {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack { Text("Sign In to Google Drive"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(busy || !hasKeys)
                    if !hasKeys {
                        Button("Copy Sign-In Keys from the TV") { Task { await copyKeys() } }
                            .disabled(busy || fleet.hubClient() == nil)
                    }
                }
                if let e = library.error, signedIn { Text(e).foregroundStyle(Palette.attention) }
                if let m = message { Text(m).foregroundStyle(Palette.attention) }
            } header: { Text("Google Drive") } footer: {
                Text("Read-only: the app can’t change anything in your Drive. It reads the “Movies” and “TV Shows” folders, as the TVs do, and shares where you are in each title with the TVs. Google shows a warning once because this app isn’t published: choose Advanced, then Continue.")
            }

            Section {
                LabeledContent("TMDB", value: hasTMDB ? "On" : "Off")
                LabeledContent("Google sign-in keys", value: hasKeys ? "Added" : "Not added")
                Button(showKeys ? "Hide" : "Enter Keys by Hand") { showKeys.toggle() }
                if showKeys {
                    TextField("Google Client ID", text: $clientID).autocorrectionDisabled()
                    SecureField("Google Client Secret", text: $secret)
                    SecureField("TMDB Key", text: $tmdbKey)
                    Button("Save Keys") {
                        if !clientID.isEmpty && !secret.isEmpty { GoogleDrive.setKeys(id: clientID, secret: secret) }
                        if !tmdbKey.isEmpty { Keychain.set(tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "tmdb.key") }
                        secret = ""; tmdbKey = ""
                        refreshState()
                    }
                    .disabled(clientID.isEmpty && tmdbKey.isEmpty)
                }
            } header: { Text("Keys") } footer: {
                Text("The same keys the TVs use: copied from the TV on the home Wi‑Fi, or typed in. TMDB gives the posters, stories and episode names.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Watch")
        .inlineTitle()
        .onAppear { refreshState() }
    }

    private func refreshState() {
        signedIn = GoogleDrive.signedIn
        hasKeys = GoogleDrive.hasKeys
        hasTMDB = TMDB.key != nil
        clientID = GoogleDrive.clientID ?? clientID
    }

    /// The Google and TMDB keys from the TV (paired, on the home Wi‑Fi).
    private func copyKeys() async {
        guard let c = fleet.hubClient() else { message = "Connect to the TV on the home Wi‑Fi first."; return }
        busy = true; message = nil
        defer { busy = false }
        do {
            if let g = try await c.sharedKey("google") {
                let parts = g.split(separator: "\n", maxSplits: 1).map(String.init)
                if parts.count == 2 { GoogleDrive.setKeys(id: parts[0], secret: parts[1]) }
            }
            if let t = try? await c.sharedKey("tmdb"), !t.isEmpty { Keychain.set(t, for: "tmdb.key") }
            refreshState()
            if !hasKeys { message = "The TV didn’t share its Google keys. Enter them by hand below." }
        } catch {
            message = "The TV didn’t share its keys (\(error.localizedDescription)). Enter them by hand below."
        }
    }

    private func signIn() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            let attempt = try GoogleDrive.begin()
            let callback = try await webAuth.authenticate(using: attempt.url, callbackURLScheme: "woodruff")
            try await GoogleDrive.finish(attempt, callback: callback)
            refreshState()
            source = "drive"
            await library.refresh(force: true)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // Closed without signing in.
        } catch {
            message = error.localizedDescription
        }
    }
}
