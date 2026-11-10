import SwiftUI
import AuthenticationServices
import WoodruffKit

/// Settings → Watch: where Watch's films and shows come from. "TV" is how it has always worked (on the home Wi‑Fi);
/// "Google Drive" is the app's own library, read straight from Drive, which works anywhere. Watch itself looks the
/// same either way.
struct WatchSettingsView: View {
    @Environment(Fleet.self) private var fleet
    #if os(tvOS)
    private let webAuth = TVWebAuth()
    #else
    @Environment(\.webAuthenticationSession) private var webAuth
    #endif
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
    /// What Save Keys just kept.
    @State private var saved: String?

    var body: some View {
        Form {
            // None of these three on Apple TV. Library did nothing there (it reads Drive whenever it's signed in), yet
            // the choice travelled to the family's phones; it plays right here; and it can keep no downloads (an
            // Apple TV app may only write in Caches, not where they're kept).
            #if !os(tvOS)
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
                // The app's own link: on the Mac the page opens beside Settings' list like the others (a plain
                // navigation link put it over the whole window, with no bar and no way back).
                PageLink("Downloads") { DownloadsView() }
            } footer: {
                Text("Films and episodes kept on this device, to watch with no connection.")
            }
            #endif

            Section {
                if signedIn {
                    LabeledContent("Status", value: "Signed in")
                    if let e = GoogleDrive.email { LabeledContent("Account", value: e) }
                    LabeledContent("Titles", value: library.busy ? "Reading Drive…" : "\(library.titleCount)")
                    if let u = library.updated {
                        LabeledContent("Updated", value: u.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Read Drive Again") {
                        #if os(tvOS)
                        guard !library.busy else { return }
                        #endif
                        Task { await library.refresh(force: true) }
                    }
                    // Not on Apple TV: a button the remote is on that's switched off loses the focus, which jumped
                    // somewhere else on the page while Drive was read (a press meanwhile does nothing).
                    #if !os(tvOS)
                    .disabled(library.busy)
                    #endif
                    Button("Sign Out", role: .destructive) {
                        GoogleDrive.signOut()
                        library.signedOut()
                        signedIn = false
                        source = "tv"
                    }
                } else {
                    #if os(tvOS)
                    // Apple TV has no Sign In: Google's page needs a browser, so the button was refused every time. It
                    // gets the family's sign-in instead (the words under this say so), which Check Again fetches now
                    // rather than at the settings' next round. (It's also a row the remote can be on: with the keys
                    // already here, nothing else on this page would be.)
                    LabeledContent("Status", value: "Not signed in")
                    Button {
                        guard !busy else { return }
                        busy = true
                        Task {
                            await SettingsSync.shared.syncNow()
                            refreshState()
                            busy = false
                        }
                    } label: {
                        HStack { Text("Check Again"); if busy { Spacer(); ProgressView() } }
                    }
                    #else
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack { Text("Sign In to Google Drive"); if busy { Spacer(); ProgressView() } }
                    }
                    .disabled(busy || !hasKeys)
                    #endif
                    if !hasKeys {
                        Button("Copy Sign-In Keys from the TV") { Task { await copyKeys() } }
                            .disabled(busy || fleet.hubClient() == nil)
                    }
                }
                if let e = library.error, signedIn { Text(e).foregroundStyle(Palette.attention) }
                if let m = message { Text(m).foregroundStyle(Palette.attention) }
            } header: { Text("Google Drive") } footer: {
                #if os(tvOS)
                Text(signedIn ? "Read-only: the app can’t change anything in your Drive. It reads the “Movies” and “TV Shows” folders, as the TVs do, and shares where you are in each title with the TVs."
                              : "Sign in on your iPhone or Mac. This Apple TV gets the sign-in from the family.")
                #else
                Text("Read-only: the app can’t change anything in your Drive. It reads the “Movies” and “TV Shows” folders, as the TVs do, and shares where you are in each title with the TVs. Google shows a warning once because this app isn’t published: choose Advanced, then Continue.")
                #endif
            }

            Section {
                LabeledContent("TMDB", value: hasTMDB ? "On" : "Off")
                LabeledContent("Google sign-in keys", value: hasKeys ? "Added" : "Not added")
                // Not on Apple TV: long keys typed a letter at a time with the remote. They come from the family.
                #if !os(tvOS)
                Button(showKeys ? "Hide" : "Enter Keys by Hand") { showKeys.toggle() }
                if showKeys {
                    TextField("Google Client ID", text: $clientID).autocorrectionDisabled()
                    SecureField("Google Client Secret", text: $secret)
                    SecureField("TMDB Key", text: $tmdbKey)
                    Button("Save Keys") { saveKeys() }
                        .disabled(!canSaveGoogle && blank(tmdbKey))
                    if let saved { Text(saved).font(.footnote).foregroundStyle(.secondary) }
                }
                #endif
            } header: { Text("Keys") } footer: {
                #if os(tvOS)
                Text("The same keys the TVs use. This Apple TV gets them from the family. TMDB gives the posters, stories and episode names.")
                #else
                Text("The same keys the TVs use: copied from the TV on the home Wi‑Fi, or typed in. TMDB gives the posters, stories and episode names.")
                #endif
            }
        }
        .familyFormStyle()
        .navigationTitle("Watch")
        .inlineTitle()
        .onAppear { refreshState() }
    }

    private func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The Google keys go in as a pair (an ID without its secret can't sign in).
    private var canSaveGoogle: Bool { !blank(clientID) && !blank(secret) }

    private func saveKeys() {
        var kept: [String] = []
        if canSaveGoogle {
            let wasSignedIn = GoogleDrive.signedIn
            GoogleDrive.setKeys(id: clientID, secret: secret)
            kept.append("Google")
            // Other keys end the sign-in made with the old ones: the TV's library until Drive is signed in again.
            if wasSignedIn && !GoogleDrive.signedIn {
                library.signedOut()
                source = "tv"
            }
        }
        if !blank(tmdbKey) {
            Keychain.set(tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "tmdb.key")
            kept.append("TMDB")
        }
        secret = ""; tmdbKey = ""
        refreshState()
        saved = kept.isEmpty ? nil : "Saved the \(kept.joined(separator: " and ")) keys."
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
            if let t = (try? await c.sharedKey("tmdb"))?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { Keychain.set(t, for: "tmdb.key") }
            refreshState()
            #if os(tvOS)
            // Apple TV has nowhere to type them: entered on an iPhone or Mac, they come with the family's settings.
            if !hasKeys { message = "The TV didn’t share its Google keys. Enter them on your iPhone or Mac." }
            #else
            if !hasKeys { message = "The TV didn’t share its Google keys. Enter them by hand below." }
            #endif
        } catch {
            #if os(tvOS)
            message = "The TV didn’t share its keys (\(error.localizedDescription)). Enter them on your iPhone or Mac."
            #else
            message = "The TV didn’t share its keys (\(error.localizedDescription)). Enter them by hand below."
            #endif
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
