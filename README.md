# Woodruff Family for iPhone, iPad and Mac

One native app for every TV in the house. It replaces the bookmarked phone page: it's the remote for every TV,
shows what's playing and how each TV is doing, sends messages, manages Family Memories and the Drive library,
and pushes updates to every TV.

It talks to the TVs exactly as the phone page does, through the `/api` routes of
[woodrufffiles](https://github.com/Blakew316/woodrufffiles) (Android TV / Google TV) and
[woodrufffiles-webos](https://github.com/Blakew316/woodrufffiles-webos) (LG). The TVs need no changes.

## What it does

| | |
|---|---|
| **TVs** | Every TV at a glance: on/off, what's playing (with a live progress bar), Woodruff on screen, version, health, updates waiting. Actions for all TVs at once: Play/Pause, Mute, Home, Update All. Each TV's page has its live picture (Android), now-playing controls, its whole health report with a fix for each problem (sign in, check for updates, open Woodruff to install, copy the crash report), Link Again, the Smoothness Report and Wake-on-LAN. |
| **Remote** | Siri-Remote layout: clickpad (tap, swipe, hold to repeat, hold OK for Menu), Back, Home, Play/Pause, Mute, volume that repeats while held, Netflix and YouTube. Type into the TV's text box from the keyboard. Pick any TV, or **Every TV at Once**. On the Mac the keyboard is a remote too (arrows, Return, Esc, Space, H, M, +/−). |
| **LG direct control** | Optional, per LG TV: the app connects to the TV's own LG remote service, so the remote works in **every app** (Netflix included), not just Woodruff. It also types into any on-screen keyboard, switches apps and inputs, changes channels, turns the screen or TV off, and turns it on with Wake-on-LAN. The TV asks once to allow it. |
| **Send** | An announcement to TV screens (every TV or chosen ones) and phones, or pinned on every TV's Home. Photos & Files on the TV's storage: browse, play, set as background, use for the slideshow, save, upload, new folder, delete. Open a link on the TV. Start the slideshow. |
| **Memories** | Family Memories in a grid. Add from Photos: each photo is shrunk to the TV's size, keeps when it was taken, and uploads one at a time. Full-screen viewer with zoom; **Show on TV** follows as you swipe. Share, delete, set as background, slideshow. |
| **Watch** | Movies and TV Shows from the TV's Google Drive: Continue Watching, Recently Added, grids with sort, genre, unwatched and search, title pages with seasons and episodes. **Play On** any TV, **Watch Together on All TVs**, mark watched, remove from Continue Watching. |
| **Updates** | The newest release of each TV app (from GitHub) next to each TV's version. Android TVs: **Update** asks a TV to check now; it installs once nobody's watching. LG TVs: the **Mac** app downloads the newest `.ipk` and installs it over SSH (Developer Mode or rooted), the same steps as `tools/install.sh --ssh`. |
| **Settings** | This device's name and lock-screen alerts, recent messages, paired TVs, and each TV's connections: Google Drive keys and sign-in, TMDB posters, Nest cameras and doorbell alerts, mail accounts, weather, the Away From Home (Tailscale) link, Shortcuts links and the last crash. |
| **Mac extras** | A menu-bar icon showing every TV's state with Play/Pause and Mute, a TVs menu with keyboard shortcuts, and notifications. |
| **Alerts** | Announcements sent to this device, and a TV going offline or needing attention, arrive as notifications. |

## Pairing

The app finds Woodruff TVs on the Wi-Fi by itself (Bonjour `_woodruff._tcp`). To pair, scan the QR code on a
TV's **Phone connection** screen (iPhone), paste its link (`http://…/?k=…`), or pick the TV from the list and
type its key. **Pairing one TV is enough**: every TV linked to it appears too, and is controlled through it.
Pair a second TV so the rest stay reachable when the first is off.

## Build and install

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
