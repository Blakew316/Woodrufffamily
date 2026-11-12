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
| **Remote** | One remote for every TV. The TV name at the top switches TVs, or **All TVs** sends each key to every TV that's on. Round clickpad (tap, swipe, hold to repeat, hold OK for Menu), Back, Home, Play/Pause, Mute, a volume rocker that repeats while held, Netflix and YouTube, and typing into the TV's text box. On LG TVs connected directly, and on Google TV and Android TV sets paired with the Android TV remote (the TV's page, Remote for Every App: the TV shows a code), it reaches every app, not just Woodruff, and Power turns the TV on and off. On the Mac, the keyboard is the remote. |
| **Watch** | Movies and TV Shows from the TV's Google Drive, like the Apple TV app: a featured billboard, Continue Watching, Recently Added, grids with sort/genre/unwatched, search, title sheets with seasons and episodes. Play on the remote's TV, **Play On** any TV, or **Watch Together on All TVs**. What's playing rides above the tab bar with ↺10, Play/Pause and 30↻. |
| **Send** | A message to TV screens and phones, or kept on every TV's Home; Photos & Files on the TV; Open a Link; Start Photo Slideshow. |
| **Memories** | Family Memories edge to edge. Add from Photos (shrunk to the TV's size, keeping when each was taken). Full-screen viewer; **Show on TV** follows as you swipe. |
| **Settings** | Five rows (and Send, on iPhone, where it has no tab). **TVs**: every TV's state, what's playing and health (each TV's page has its screen, controls, every problem with its fix, sign-ins, updates, Link Again, LG direct control), **Software Update** (every TV's version against the newest release, Update All, and Check Now, which has every TV look for itself too; the Mac installs LG updates over SSH), and Pause, Mute or Woodruff Home on all of them. **Smart Home**: speakers, lights, cameras, devices and the Wi‑Fi, each renamed, given its room and signed in on its own page. **Notifications**: this device's alerts, the doorbell and cameras, Instant iPhone Alerts (set up on a Mac), recent messages. **Accounts**: what the TVs sign in to: Google Drive, Movie Posters, Nest Cameras, Mail. **General**: Away From Home, Shortcuts, Sync Across Devices, the TV's last crash (and the Mac's key click). |

Try it without a TV: run with the launch argument `-demo YES` (sample TVs, library and photos).

## Pairing

The app finds Woodruff TVs on the Wi-Fi by itself (Bonjour `_woodruff._tcp`). To pair, scan the QR code on a
TV's **Phone connection** screen (iPhone), paste its link (`http://…/?k=…`), or pick the TV from the list and
type its key. **Pairing one TV is enough**: every TV linked to it appears too, and is controlled through it.
Pair a second TV so the rest stay reachable when the first is off.

## Build and install

**For the family's own Macs and iPhones, don't follow these steps:** they update themselves (see
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

Every push builds both apps on GitHub's macOS runners (`.github/workflows/build.yml`): it checks the deploy
scripts (`deploy.sh`'s syntax and the tests in `scripts/tests`), runs WoodruffKit's tests and builds the iOS app for
the simulator and for devices (unsigned), and the Mac app. Builds are attached to each run. When the commit is a
release, it then ships it to every device (see below).

## Deploying to the family's devices

The family's Macs, iPhones and Apple TVs update themselves. Once each Mac is set up, nobody has to run anything on
them, and nothing needs a remote session.

**How a release happens.** A commit pushed to `claude/native-apps` with `[release]` in its message is a release.
CI builds and tests it, and only if all of that works does it move the `release` branch to that commit. Commits
without `[release]` are built but not shipped. To ship a commit that's already pushed, open **Build apps** in the
repository's Actions tab, choose **Run workflow** and tick **Ship this commit to every device**. To go back to an
earlier build, move `release` back to it: `git push --force origin <commit>:release`.

**What each Mac does.** Every 5 minutes, and when its user logs in, each Mac's updater (`scripts/updater.py`)
looks at `release` and brings that Mac up to date when it isn't. `scripts/deploy.sh` does every build:

- **The Mac Studio** builds and installs the Mac app, and shares that build in iCloud Drive for the other Macs. It
  also builds and signs the iPhone app once, and installs it on each iPhone paired with it; and the Apple TV app
  once, for each Apple TV paired with it.
- **Mac Studio 2** can't sign (Apple revoked its certificate), so it installs the build the Mac Studio shared. It
  depends on iCloud Drive: it needs iCloud Drive on, with the same Apple ID as the Mac Studio, and it gets each
  update only once the Mac Studio has shared it.
- **The MacBook Pro** installs the Mac Studio's build too. If none it can use has arrived 30 minutes after it first
  saw the release, it builds its own.

A Mac doesn't replace Woodruff Family while someone is using it (the app is in front and the keyboard or mouse was
used in the last 2 minutes). It waits, but no longer than 30 minutes after it first saw the release. A Mac on
battery below 30% puts off building; installing a shared build still goes ahead.

**The iPhones** get each release from the Mac Studio when they're on the home Wi-Fi while the Mac Studio is awake.
The Mac Studio keeps trying until both have it, and it doesn't open the app on them. So keep the Mac Studio awake
with its user logged in (a locked screen is fine).

**The Apple TVs** get each release from the Mac Studio too, over the home network (no cable, awake or asleep).
Installing closes the app on an Apple TV, so the Mac Studio first asks each one whether a film is on screen (the app
keeps a note of the film in its settings, renewed every ten seconds), and leaves that Apple TV alone until the film
is closed or the app is put away, looking again at every check. It doesn't open the app afterwards, so an Apple TV
that's asleep stays asleep; one with the app open on a page other than a film sees it close, and has the new build
when it's opened again. An Apple TV already on the build (installed by hand) is left as it is, and one is called up
to date once it says itself that it has the build. The Apple TVs are paired with the Mac Studio once, in Xcode's
Devices window, as the iPhones are.

**Settings → General** shows which build a device has ("Build 412 · e7d8293"). On a Mac, the app's own Settings
window (Woodruff Family > Settings…, ⌘,) has the rest under General: the remote's key click, and how its updates are
going (on the Mac Studio, each iPhone's and Apple TV's too), with **Check for Updates Now** (**Check for Updates…** in the Woodruff
Family menu does the same). Its Notifications tab has the alerts that Mac shows.

**Setting up a Mac (once).** In Terminal, in the repository folder, run the line for that Mac:

```sh
python3 scripts/updater.py install --role hub                        # the Mac Studio
python3 scripts/updater.py install --role follower --build-fallback  # the MacBook Pro
python3 scripts/updater.py install --role follower                   # Mac Studio 2
```

On Mac Studio 2 and the MacBook Pro, which install the Mac Studio's build from iCloud Drive, also give Python Full
Disk Access (System Settings > Privacy & Security > Full Disk Access, add `Python.app` from
`python3 -c 'import sys; print(sys.executable)'`'s framework). macOS lets Terminal read iCloud Drive but not the
updater when it runs by itself; without this, `status` says so and the Mac waits until someone runs it by hand.

It saves its settings, adds a LaunchAgent for that Mac's user
(`~/Library/LaunchAgents/com.woodruff.family.updater.plist`), starts it and says what it did. If the checkout
doesn't have `scripts/updater.py` yet, get it first with
`git fetch origin claude/native-apps && git checkout claude/native-apps && git pull --ff-only origin claude/native-apps`.

On a Mac with the updater:

- `python3 scripts/updater.py status` says what `release` is at, what this Mac has and, on the Mac Studio, what
  each iPhone and Apple TV has, with the end of its log. Add `--json` for the status file the app reads.
- `python3 scripts/updater.py now` checks right away instead of waiting up to 5 minutes.
- `python3 scripts/updater.py uninstall` stops it on that Mac. Add `--purge` to also delete its status, kept builds
  and logs.

**Logs** are in `~/Library/Logs/Woodruff Family/`: `updater.log` says what the updater did and why, and there's a
`deploy-<time>.log` for each update (the newest 10 are kept).

**Signing.** Nothing here asks for an Apple ID, makes, imports, revokes or changes certificates or profiles, or runs
`-allowProvisioningUpdates`, so one Mac's update can't break another's signing. When the iPhone profiles or a Mac's
signing certificate expire, or the certificate is revoked, the update says so and skips what it can't sign; only
then does someone need to sign in to Xcode once on that Mac. The same goes for an iPhone the profiles don't list
yet. The current iPhone profiles expire on November 4, 2027; each Mac's certificate has its own date, and
`deploy.sh` warns 30 days ahead.

Woodruff Home Helper (Apple Home on the Macs) is development-signed by the Mac Studio, so it opens only on Macs
registered under Devices at developer.apple.com. A Mac that isn't registered skips the shared helper; once it's
registered, the Mac Studio's next build includes it.

### Adding an iPhone or iPad

The app runs on iPhone and iPad (iOS and iPadOS 26). To add one:

1. Plug it into the Mac Studio, unlock it and tap Trust. In Xcode, Window → Devices and Simulators, select it, tick
   "Connect via network" and copy its Identifier.
2. On the device, turn on Settings → Privacy & Security → Developer Mode (it restarts).
3. Register it at developer.apple.com → Certificates, IDs & Profiles → Devices → + (platform iOS, its Identifier).
4. The next release's iPhone build includes it, and the Mac Studio installs the app on it from then on. Check for
   Updates Now alone doesn't: the build it reuses was signed before the device was registered.
5. In the app: Settings → General → Sync Across Devices → Enter Family Code.

### Updates away from home (TestFlight)

The Mac Studio installs the iPhone app directly only while a phone is on the home Wi‑Fi. So that every iPhone and
iPad updates anywhere, on Wi‑Fi or cellular, it also archives each release and uploads it to TestFlight
(`scripts/deploy.sh --xcode-signing testflight`, run by its updater). Set up once:

1. At [App Store Connect](https://appstoreconnect.apple.com) choose Apps, +, New App: iOS, name Woodruff Family,
   bundle ID `com.blakew316.woodruff`, any SKU.
2. In the app's TestFlight tab, add an internal testing group and add each family member's Apple Account (they must
   be users of the team in Users and Access).
3. On each iPhone and iPad, install TestFlight from the App Store, accept the invite, open Woodruff Family there,
   and turn on Automatic Updates.

The camera alerts' notification extension (`com.blakew316.woodruff.notifications`) needs the App Groups capability
with `group.com.woodruff.family` on its identifier at developer.apple.com (Identifiers, the id, App Groups,
Configure). Without it the build leaves the group off the extension alone: alerts then show the small picture the
Mac puts in the push, but can't fetch the full clip.

The widgets (`com.blakew316.woodruff.widgets`) need Push Notifications on their identifier, which Xcode's signing on
the Mac Studio normally turns on by itself (else at developer.apple.com: Identifiers, the id, Push Notifications). A
moment after an alert from a camera they show (the doorbell and the driveway), the Mac Studio then sends a push that
has iOS reload the camera widgets, even with Woodruff closed. Without it the build leaves push off the widgets alone:
they then update from the alert itself, which iOS can put off once a widget has used its reloads for the day.

Until the app exists in App Store Connect the upload says "Not Set Up" in the Mac app's Settings window (⌘,) under
General and is tried again every 6 hours (or at Check for Updates Now). To turn uploads off, add `"testflight": false` to the
updater's `config.json`. TestFlight builds use Apple's production push service, so Instant iPhone Alerts need a push
key enabled for Sandbox & Production.

### By hand

`scripts/deploy.sh` is what the updater runs. It also works by hand, in Terminal from the repository folder:

- `scripts/deploy.sh mac` updates the checkout to the newest `claude/native-apps`, builds the Mac app and replaces
  `/Applications/Woodruff Family.app` with it (only once the new build's signature checks out).
- `scripts/deploy.sh mac iphone`, on the Mac the iPhones are paired with, also signs the iPhone app with the
  profiles already there and installs it on every paired iPhone.
- `scripts/deploy.sh --xcode-signing tv`, on the Mac Studio, builds the Apple TV app and installs it on every Apple
  TV paired with it, at once (it doesn't ask about a film: that's the updater's care), and opens it there.
- `share` (with `mac`) then puts a zip of the build and a manifest in iCloud Drive, in "Woodruff Family builds", for
  a Mac that can't sign. On that Mac, `scripts/deploy.sh mac-shared` waits up to 20 minutes for the zip of the
  commit it's at (give both Macs the same `--expect <commit>`), and installs it only if it matches the manifest and
  is signed by a certificate with the same name and team as the installed app, which is what lets the new app read
  the TVs' pairings from the keychain.
- `--expect <commit>` stops unless the checkout is at that commit. `--branch <name>` deploys `origin/<name>`,
  checked out detached, instead of the newest `claude/native-apps`.

The updater keeps each Mac on the `release` build, so on a Mac that has it, deploy that by hand:
`scripts/deploy.sh --branch release mac`. `scripts/deploy.sh --help` lists every option. A run by hand ends with a
summary of what was installed where, and names the temporary folder its logs are in.

## How it's built

- `Packages/WoodruffKit`: everything that isn't UI (shared by both apps, unit-tested with `swift test`).
  - `Transport.swift`: HTTP to a TV. The key goes in the URL, the `tvx` cookie and `X-Tvx`, so both Android and webOS accept it.
  - `Models.swift`: the TVs' JSON, field for field.
  - `TVClient.swift`: every route. A TV paired here is called directly; a linked TV goes through its hub's `/api/tvs/*` relays.
  - `Fleet.swift`: the observable state: paired hubs, every TV merged from all hubs, polling, health, inbox, releases, LG remotes.
  - `Discovery.swift`: Bonjour browsing and Wake-on-LAN. `LGRemote.swift`: LG's SSAP WebSocket remote.
  - `Releases.swift`: GitHub releases and version numbers. `WebOSInstaller.swift`: SSH install on LG TVs (Mac).
  - `FilmRuns.swift`, `FilmTrack.swift`, `FilmPlayer.swift`, `FilmIndexFile.swift`: the app's own film player (Apple TV).
    Apple's player can't play a film whose sound and picture are stored far apart: it hops between the two hundreds of
    times a second and stops every twenty seconds or so. This one has Apple's reader say where each sample is, reads each
    track straight on from its own place (as the Android TVs' player does) and hands the samples to Apple's decoders on
    one clock. The film's index is kept in a small file on the device, so it's read from Google once. `swift test` plays
    three small films with it on a Mac. `App/TV/TVFilmScreen.swift` is its screen, laid out as Apple's player's, and
    `App/TV/TVFilmPlayer.swift` runs a film on it. It has the films Apple's player stutters on, or every film
    (Settings, Watch on the Apple TV). On a Mac, `open -a "Woodruff Family" --args -filmCheck "own:<film>"` plays a film
    with it and writes how it went to `~/Library/Logs/Woodruff Family/film-check.log`.
- `App/Shared`: the SwiftUI screens, the same on iPhone (tabs), iPad and Mac (sidebar). `AndroidTVRemote.swift` is Android's
  own TV remote protocol (v2, as Google's TV remote app): pairing on port 6467, keys on 6466, over TLS with one client
  certificate built into the app (so a TV paired once takes every family device), the TV's certificate pinned per address. `App/iOS`: the QR scanner. `App/macOS`: the menu bar and commands.
- `project.yml`: the Xcode project (XcodeGen), so there's no `.xcodeproj` to merge.
- `scripts`: `updater.py`, the updater on each Mac; `deploy.sh`, which builds, signs and installs; `signing.py`, its
  signing checks; and their tests in `scripts/tests`.
