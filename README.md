# Woodruff Family for iPhone, iPad and Mac

One native app for every TV in the house. It replaces the bookmarked phone page: it's the remote for every TV,
shows what's playing and how each TV is doing, sends messages, manages Family Memories and the Drive library,
and pushes updates to every TV.

It talks to the TVs exactly as the phone page does, through the `/api` routes of
[woodrufffiles](https://github.com/Blakew316/woodrufffiles) (Android TV / Google TV) and
[woodrufffiles-webos](https://github.com/Blakew316/woodrufffiles-webos) (LG). The TVs need no changes.

## What it does

It looks and works like the Woodruff phone page, rebuilt natively with Liquid Glass (iOS 26 and macOS 26 Tahoe):
the same five sections, as tabs on iPhone and a sidebar on the Mac.

| | |
|---|---|
| **Remote** | One remote for every TV. The TV name at the top switches TVs, or **All TVs** sends each key to every TV that's on. Round clickpad (tap, swipe, hold to repeat, hold OK for Menu), Back, Home, Play/Pause, Mute, a volume rocker that repeats while held, Netflix and YouTube, and typing into the TV's text box. On LG TVs connected directly it reaches every app, not just Woodruff. On the Mac, the keyboard is the remote. |
| **Watch** | Movies and TV Shows from the TV's Google Drive, like the Apple TV app: a featured billboard, Continue Watching, Recently Added, grids with sort/genre/unwatched, search, title sheets with seasons and episodes. Play on the remote's TV, **Play On** any TV, or **Watch Together on All TVs**. What's playing rides above the tab bar with ↺10, Play/Pause and 30↻. |
| **Send** | A message to TV screens and phones, or kept on every TV's Home; Photos & Files on the TV; Open a Link; Start Photo Slideshow. |
| **Memories** | Family Memories edge to edge. Add from Photos (shrunk to the TV's size, keeping when each was taken). Full-screen viewer; **Show on TV** follows as you swipe. |
| **Settings** | Five rows (and Send, on iPhone, where it has no tab). **TVs**: every TV's state, what's playing and health (each TV's page has its screen, controls, every problem with its fix, sign-ins, updates, Link Again, LG direct control), **Software Update** (every TV's version against the newest release, Update All, and Check Now, which has every TV look for itself too; the Mac installs LG updates over SSH), and Pause, Mute or Woodruff Home on all of them. **Smart Home**: speakers, lights, cameras, devices and the Wi‑Fi, each renamed, given its room and signed in on its own page. **Notifications**: this device's alerts, the doorbell and cameras, Instant iPhone Alerts (set up on a Mac), recent messages. **Accounts**: what the TVs sign in to: Google Drive, Movie Posters, Nest Cameras, Mail. **General**: Away From Home, Shortcuts, Sync Across Devices, the TV's last crash (and the Mac's key click). |

Try it without a TV: run with the launch argument `-demo YES` (sample TVs, library and photos). Every CI run
screenshots each screen this way, light and dark, on the `screenshots` branch.

## Pairing

The app finds Woodruff TVs on the Wi-Fi by itself (Bonjour `_woodruff._tcp`). To pair, scan the QR code on a
TV's **Phone connection** screen (iPhone), paste its link (`http://…/?k=…`), or pick the TV from the list and
type its key. **Pairing one TV is enough**: every TV linked to it appears too, and is controlled through it.
Pair a second TV so the rest stay reachable when the first is off.

## Build and install

**For the family's own Macs and iPhones, don't follow these steps:** use `scripts/deploy.sh` (see
[Deploying to the family's devices](#deploying-to-the-familys-devices)). The family iPhones always keep the bundle
identifier `com.blakew316.woodruff` (another one loses the TV pairings), and nobody needs to sign in to Xcode
(Xcode's automatic signing is what made new certificates and broke the other Macs' signing).

You need a Mac with Xcode 16 or newer and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/Blakew316/Woodrufffamily && cd Woodrufffamily
git checkout claude/native-apps
xcodegen generate
open WoodruffFamily.xcodeproj
```

**iPhone (by cable):** plug the iPhone in and unlock it. In Xcode:
1. Choose the **WoodruffFamily** scheme and your iPhone.
2. Under the target's **Signing & Capabilities**, pick your team (Xcode → Settings → Accounts → add your Apple ID) and change the bundle identifier to something unique, e.g. `com.yourname.woodruff`.
3. Press **Run**.

The first time, turn on Developer Mode on the iPhone (Settings → Privacy & Security), and trust your Apple ID
under Settings → General → VPN & Device Management. With a free Apple ID the app has to be reinstalled every
7 days; a paid developer account makes that a year.

**Mac:** choose the **WoodruffFamilyMac** scheme and **My Mac**, then press Run, or copy the built app to /Applications.

Every push builds both apps on GitHub's macOS runners (`.github/workflows/build.yml`): it runs WoodruffKit's tests
and builds the iOS app for the simulator and for devices (unsigned), and the Mac app. Builds are attached to each run.

## Deploying to the family's devices

`scripts/deploy.sh` updates the checkout to the newest `claude/native-apps`, builds, and installs with the signing
certificate and provisioning profiles already on that Mac. Run it in Terminal from the repository folder:

- On each Mac: `scripts/deploy.sh mac`. It quits Woodruff Family, replaces `/Applications/Woodruff Family.app` with
  the new build (only once that build's signature checks out) and opens it again.
- On the Mac the iPhones are paired with: `scripts/deploy.sh mac iphone`. It also signs the iPhone app with the
  profiles Xcode already made there and installs it on every paired iPhone (unlock them so it can open).
- Add `--expect <commit>` to stop unless the checkout is at that commit.

**A Mac whose certificate Apple revoked** can't sign a build, but it can run one another Mac signed, because the Mac
app needs no profile. On a Mac that can sign, add `share`: `scripts/deploy.sh --expect <commit> mac share` (with
`iphone` too if that's the iPhones' Mac). After installing, it puts a zip of the build and a manifest in iCloud
Drive, in "Woodruff Family builds", replacing the previous one. Then, on the Mac that can't sign, run
`scripts/deploy.sh --expect <commit> mac-shared`. It waits up to 20 minutes for that commit's zip to arrive and
checks it against the manifest and its signature. It installs the zip only if it's signed by a certificate with the
same name and team as the installed app, which is what lets the new app read the TVs' pairings from the keychain.
Both Macs need iCloud Drive on, with the same Apple ID.

The first time on a Mac whose checkout doesn't have `scripts/deploy.sh` (or `share` and `mac-shared`) yet, get it with
`git fetch origin claude/native-apps && git checkout claude/native-apps && git pull --ff-only origin claude/native-apps`
in the repository folder, then run it as above.

It never asks for an Apple ID, never makes, imports, revokes or changes certificates or profiles, and never runs
`-allowProvisioningUpdates`, so one Mac's deploy can't break another's signing. When the iPhone profiles or that
Mac's signing certificate expire, or the certificate is revoked, it says so and skips what it can't sign; only then
does someone need to sign in to Xcode once on that Mac. The same goes for an iPhone the profiles don't list yet.
The current iPhone profiles expire on November 4, 2027; each Mac's certificate has its own date, and the summary
shows both (it warns 30 days ahead). The summary also says what was installed where and with which identity and
profiles; the logs stay in a temporary folder.

## How it's built

- `Packages/WoodruffKit`: everything that isn't UI (shared by both apps, unit-tested with `swift test`).
  - `Transport.swift`: HTTP to a TV. The key goes in the URL, the `tvx` cookie and `X-Tvx`, so both Android and webOS accept it.
  - `Models.swift`: the TVs' JSON, field for field.
  - `TVClient.swift`: every route. A TV paired here is called directly; a linked TV goes through its hub's `/api/tvs/*` relays.
  - `Fleet.swift`: the observable state: paired hubs, every TV merged from all hubs, polling, health, inbox, releases, LG remotes.
  - `Discovery.swift`: Bonjour browsing and Wake-on-LAN. `LGRemote.swift`: LG's SSAP WebSocket remote.
  - `Releases.swift`: GitHub releases and version numbers. `WebOSInstaller.swift`: SSH install on LG TVs (Mac).
- `App/Shared`: the SwiftUI screens, the same on iPhone (tabs), iPad and Mac (sidebar). `App/iOS`: the QR scanner. `App/macOS`: the menu bar and commands.
- `project.yml`: the Xcode project (XcodeGen), so there's no `.xcodeproj` to merge.
