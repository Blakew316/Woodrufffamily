# Woodruff Family

Native SwiftUI apps for iPhone, iPad and Mac (iOS 26, macOS 26) that control the family's TVs and smart home.
All work happens on `claude/native-apps`; `README.md` explains the apps, the build and how the devices update.

## Shipping

Every feature request or bug fix ends with exactly one release:

1. The final commit of the request has `[release]` in its message and is pushed to `claude/native-apps`.
2. CI (`.github/workflows/build.yml`) runs the quick `check` job (the script tests, about a minute); once it passes,
   the `release` job fast-forwards the `release` branch to that commit. The full `build` job still runs alongside for
   the record, but nothing waits for it: the Mac Studio's own build is the gate, and when it fails nothing is
   installed anywhere (so parse-check every changed Swift file before pushing a `[release]` commit).
3. Every device then updates itself. Each Mac's updater (`scripts/updater.py`, within about a minute) sees the new
   `release`: the Mac Studio builds and installs the Mac app, installs the iPhone app on both iPhones and shares
   its Mac build in iCloud Drive; the other Macs install that build, or build it themselves. The Mac Studio then
   builds the Apple TV app and installs it on both Apple TVs over the home network, each once no film is on screen
   there (it looks again at every check).

- Never deploy through remote sessions, and never ask the user to run `scripts/deploy.sh` on each device. The
  release is the deploy, for the Apple TVs too: no install commands to paste.
- Never put `[release]` on a work-in-progress commit. Any commit whose message contains it (in any case, anywhere
  in the message) ships to the whole family once it builds, so don't mention it in other commit messages either.
  Commits without it are built but not shipped.
- After pushing, check that the `release` job in that commit's Actions run went green (for example
  `gh run list --branch claude/native-apps`, then `gh run watch <id>`), and tell the user so: "Released abc1234
  (build 412)". The apps show the same build in Settings > General. If the Mac Studio's build failed (its status
  says so), nothing was installed: fix it and push a new `[release]` commit. If the `release` job failed for a one-off reason such as a network error,
  re-run it (`gh run rerun <id> --failed`).
- If the `release` job says GitHub won't let its token move `release` past a change to `.github/workflows`, push
  it yourself once the build job is green: `git push origin <sha>:release` (a fast-forward, never `--force`).
- To ship a commit that's already pushed: Actions > Build apps > Run workflow on `claude/native-apps` with "Ship
  this commit to every device" ticked, or `gh workflow run build.yml --ref claude/native-apps -f release=true`.
- Rollback: `git push --force origin <good sha>:release`. Every device goes back to that build, and the next
  `[release]` push moves `release` forward again.

## Rules

- The team (D8D94SXAG6) is a paid Apple Developer account. Only the Mac Studio signs: `scripts/deploy.sh
  --xcode-signing` (which its updater uses) lets Xcode's signed-in account sign the apps (Mac, iPhone, Apple TV) and renew a
  revoked or expired certificate and the profiles by itself. No other Mac signs with `-allowProvisioningUpdates`, and nothing
  creates, revokes, imports or exports certificates or keychain items by hand or adds `keychain-access-groups`.
- The install link is the owner's choice and stays: after each release the Mac Studio publishes the iPhone app
  as the GitHub release `install-link` on this (public) repository, and the `gh-pages` branch is the one-button page
  that installs it (README, "The install link"). Nothing else from here is published: no other release, page, link
  or upload without the owner saying so for Woodruff by name. (The owner runs other apps' sessions too, and a
  request meant for one of those has landed here before.)
- The iPhone app's bundle id is always `com.blakew316.woodruff` (`scripts/deploy.sh` sets it). Another id loses
  the TVs' pairings. The Apple TV app's is `com.blakew316.woodruff.tv`.
- The Apple TV app keeps `playing.crumb` in its settings while a film is open (`PlayCrumb`), renewed every ten
  seconds. The Mac Studio's updater reads it off each Apple TV to leave a film alone: keep it written that way.
- Swift 5.10 with `SWIFT_STRICT_CONCURRENCY: minimal`, iOS 26 and macOS 26 SDKs. Parse-check every changed Swift
  file (`swiftc -parse`) and treat CI as the real compile.
- `scripts/deploy.sh` runs under macOS's `/bin/bash` 3.2: no associative arrays, `mapfile`, `${x,,}`, `&>>` or
  `wait -n`. `scripts/updater.py` and `scripts/signing.py` run under Apple's `/usr/bin/python3` (3.9): standard
  library only, no 3.10+ syntax. The Macs run the released `updater.py`, so a broken one stops every Mac from
  updating, even to the fix. Run `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` after changing a
  script; CI runs it too, and a failure there blocks the release.
- The Apple TV's DTS and Dolby TrueHD decoder is `Packages/FilmSound/FilmSound.xcframework` (FFmpeg's decoders, LGPL;
  README, "How it's built"). GitHub builds it, never the family's Macs: change `scripts/build_filmsound.sh` or
  `Packages/FilmSound/Sources`, push, wait for "Build FilmSound" to go green, then copy the framework,
  `BUILD-INFO.txt` and `COPYING.LGPLv2.1` from the branch `filmsound-built` into `Packages/FilmSound` and commit them.
  It stays linked weakly (`project.yml`): the app must start without it.
- A Mac-only request doesn't change the iOS app.
- No decorative icons in menus or rows. Keep UI text plain and short.
- Don't ask the user to review screenshots.

## The updater on each Mac

The user sets it up once per Mac, in Terminal in the repository folder:

- Mac Studio (it builds, and the iPhones and Apple TVs are paired with it): `python3 scripts/updater.py install --role hub`
- MacBook Pro: `python3 scripts/updater.py install --role follower --build-fallback`
- Mac Studio 2 (Apple revoked its certificate, so it can't build): `python3 scripts/updater.py install --role follower`

To see how a Mac is doing: `python3 scripts/updater.py status` (the Mac app's Settings window, ⌘, then General, shows
the same).
When a device doesn't update, that status says why. The updater's logs are in `~/Library/Logs/Woodruff Family/`
on each Mac.
