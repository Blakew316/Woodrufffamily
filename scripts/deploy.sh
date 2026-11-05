#!/bin/bash
#
# Deploy Woodruff Family to this Mac and/or the iPhones paired with it, signed with what's already here.
#
#   scripts/deploy.sh [options] [mac] [share] [mac-shared] [iphone]      (no part named: mac)
#
#   mac      Build the Mac app signed with this Mac's own "Apple Development" identity (it needs no profile),
#            quit the running Woodruff Family, copy the new one over /Applications/Woodruff Family.app,
#            check its signature and open it.
#   share    After mac, the new build; alone, the installed app when it's this commit's build: put a zip of it and a
#            manifest in iCloud Drive ("Woodruff Family builds"),
#            replacing the one shared before, for a Mac whose certificate Apple revoked.
#   mac-shared   Instead of building: wait (up to 20 minutes, or --wait) for the zip another Mac shared for this commit,
#            check it against its manifest and its signature, check it's signed under the same certificate name
#            as the installed app (so the TVs stay signed in), then install and open it like mac does.
#   iphone   Build the iPhone app unsigned, sign a copy with codesign and the provisioning profiles Xcode
#            already made on this Mac, and install it on every iPhone paired with this Mac.
#
#   --expect <commit>   Stop before building unless the checkout is that commit (a prefix is enough).
#   --branch <name>     Deploy origin/<name>, checked out detached, instead of the newest claude/native-apps.
#   --wait <seconds>    mac-shared: how long to wait for the shared zip (default 1200; 0 looks once).
#   --keep-iphone <dir> iphone: once the signed copy verifies, keep it as <dir>/Woodruff Family.app, with
#                       <dir>/build.json (commit, build, signed_at, identity, app profile, devices).
#   --no-launch         iphone: don't open the app on the iPhones after installing it.
#   --results <file>    Append one line per outcome, tab-separated: part (mac, share, mac-shared, iphone-build,
#                       iphone), status (installed, ok, waiting, failed, skipped), target (the commit, or the
#                       iPhone's UDID for iphone) and detail. mac-shared says waiting, not failed, while the zip
#                       isn't there or doesn't match its manifest yet. scripts/updater.py reads these.
#
# First it updates the checkout (git fetch, checkout claude/native-apps, pull --ff-only; with --branch, fetch that
# branch and check out origin/<name> detached; if that brought a new deploy.sh, it runs the new one) and runs
# xcodegen. Every build carries its commit (WOODRUFF_COMMIT, the Info.plist key WoodruffCommit) and build number
# (CURRENT_PROJECT_VERSION, the commit count). To quit the running Mac app it posts the Darwin notification
# com.woodruff.family.mac.quit-for-update (the app quits itself), then asks with AppleScript, then sends SIGTERM.
#
# With --xcode-signing (the Mac Studio, the one Mac that signs since the team became a paid account) Xcode signs both
# apps itself with its signed-in account (-allowProvisioningUpdates): it renews a revoked or expired certificate and
# the profiles on its own. Without it, it never runs -allowProvisioningUpdates or -authenticationKey*, never contacts
# Apple's developer services, never asks for an Apple ID (or anything else), and never creates, imports, revokes,
# deletes or changes a
# certificate, key, profile, keychain or keychain search list. When the iPhone profiles or a signing certificate
# expire (or a certificate is revoked) it says so and skips what can't be signed; only then does someone need to
# sign in to Xcode once on this Mac. It warns 30 days ahead.
#
# It deletes nothing but its own temporary folder, at most once a stale generated
# build/Build/Products/Release/Woodruff Family.app, (share) the older zips and manifests it shared in
# iCloud Drive's "Woodruff Family builds" folder, and (--keep-iphone) the copy it kept in that folder before.
# Logs stay in a temporary folder named at the end.
# The exit status is 0 only if everything asked for worked; iPhone problems never stop the Mac part.
#
# Written for macOS's /bin/bash 3.2: no associative arrays, mapfile, ${x,,}, &>> or wait -n.

set -u
unset CDPATH   # an exported CDPATH would make `cd scripts/..` print the folder and spoil ROOT

TEAM="D8D94SXAG6"
# An App Store Connect API key (AuthKey_<KEYID>.p8, and issuer.txt with its Issuer ID) lets Xcode's automatic signing
# make and renew the profiles without the account signed in to Xcode, which command-line builds often can't use
# ("No Accounts"). Optional: without it, Xcode's signed-in account is used as before.
ASC_DIR="$HOME/Library/Application Support/Woodruff Family/AppStoreConnect"
BRANCH="claude/native-apps"
IPHONE_BUNDLE_ID="com.blakew316.woodruff"          # always this id on the iPhones
IPHONE_WIDGETS_ID="com.blakew316.woodruff.widgets"
MAC_BUNDLE_ID="com.woodruff.family.mac"
HOMEKIT="com.apple.developer.homekit"
APP_NAME="Woodruff Family"
MAC_INSTALLED="/Applications/Woodruff Family.app"
# The small Mac Catalyst app that reads Apple Home for the Mac app (a Mac app can't use HomeKit itself).
HELPER_NAME="Woodruff Home Helper"
HELPER_INSTALLED="/Applications/$HELPER_NAME.app"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
SHARE_DIR="$ICLOUD/Woodruff Family builds"
SHARE_WAIT=1200   # seconds mac-shared waits for the zip to arrive (--wait)
QUIT_NOTIFICATION="com.woodruff.family.mac.quit-for-update"   # the Mac app quits itself when this is posted

DETACH=0          # --branch: check out origin/$BRANCH detached instead of pulling claude/native-apps
BRANCH_OPT=""     # "--branch <name> " for the commands this suggests
KEEP_IPHONE=""    # --keep-iphone
IPHONE_FALLBACK=""   # set while the iPhone is signed with this Mac's own profiles after Xcode couldn't
XCODE_SIGNING=0   # --xcode-signing: Xcode's automatic signing with its signed-in (paid) account
LAUNCH_IPHONE=1   # 0 with --no-launch
RESULTS=""        # --results
EXPECT=""         # --expect
DO_MAC=0
DO_SHARE=0
DO_MAC_SHARED=0
DO_IPHONE=0
MAC_PART="mac"    # the --results part a Mac install reports as: mac or mac-shared
COMMIT=""         # the checkout's full commit, once it's updated
BUILD_NUMBER=""   # its commit count, CURRENT_PROJECT_VERSION
VERSION_SETTINGS=()

ROOT=""
MAC_OK=0
SIGNING=""
TMPROOT=""
LOGDIR=""
WORK=""
FAILED=0
LAST_PROBLEM=""
HEAD_DESC="(not updated)"
SUMMARY=()
IPHONE_UDIDS=()
IPHONE_NAMES=()

say()     { printf '%s\n' "$*"; }
step()    { printf '\n==> %s\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*"; }
problem() { FAILED=1; LAST_PROBLEM="$*"; printf 'PROBLEM: %s\n' "$*"; }
note()    { SUMMARY+=("$*"); }
indent()  { sed 's/^/    /'; }
signing() { python3 -I "$SIGNING" "$@"; }

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [options] [mac] [share] [mac-shared] [iphone]      (no part named: mac)
  mac                 build, sign and install the Mac app in /Applications on this Mac
  share               share this Mac's build in iCloud Drive (with mac the new one, alone the installed one)
  mac-shared          install the build another Mac shared for this commit instead of building one here
  iphone              build, sign and install the iPhone app on every iPhone paired with this Mac
  --expect <commit>   stop before building unless the checkout is at that commit (a prefix is enough)
  --branch <name>     deploy origin/<name>, checked out detached, instead of the newest claude/native-apps
  --wait <seconds>    mac-shared: how long to wait for the shared build (default 1200; 0 looks once)
  --keep-iphone <dir> iphone: keep the signed app as <dir>/Woodruff Family.app, with <dir>/build.json
  --no-launch         iphone: don't open the app on the iPhones after installing it
  --xcode-signing     let Xcode sign with its signed-in account (renews revoked certificates and profiles)
  --results <file>    append one tab-separated line per outcome: part, status, target, detail
It uses only the certificates and profiles already on this Mac; it never asks for an Apple ID.
EOF
}

# One --results line: $1 part, $2 status, $3 target (empty: this commit), $4 detail (tabs and newlines become
# spaces). Nothing without --results.
result() {
  local target=${3:-}
  [ -n "$RESULTS" ] || return 0
  if [ -z "$target" ]; then
    target=${COMMIT:-$EXPECT}
  fi
  if ! printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$target" "$(printf '%s' "${4:-}" | tr '\t\r\n' '   ')" \
    >>"$RESULTS" 2>/dev/null; then
    warn "couldn't add the $1 result to $RESULTS"
  fi
  return 0
}

# Nothing was built: every part asked for failed, for the reason of the last PROBLEM.
nothing_built() {
  local why=${LAST_PROBLEM:-nothing was built}
  note "Nothing was built or installed."
  if [ "$DO_MAC" -eq 1 ]; then result mac failed "" "$why"; fi
  if [ "$DO_SHARE" -eq 1 ]; then result share failed "" "$why"; fi
  if [ "$DO_MAC_SHARED" -eq 1 ]; then result mac-shared failed "" "$why"; fi
  if [ "$DO_IPHONE" -eq 1 ]; then result iphone-build failed "" "$why"; fi
  return 0
}

# $1 as an absolute path (a relative one is taken from the folder this was run in).
absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# Runs "$@" (stdin /dev/null, output appended to log $2) but stops waiting for it after $1 seconds: an AppleScript
# that waits for an Automation permission nobody answers mustn't hold up the deploy.
bounded() {
  local limit=$1 log=$2 pid start=$SECONDS
  shift 2
  "$@" </dev/null >>"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      kill "$pid" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null
}

# The distinct lines of file $2 that match extended regex $1, at most $3 of them, indented.
show_matches() {
  grep -E -- "$1" "$2" 2>/dev/null | awk '!seen[$0]++' | head -n "$3" | indent
}

show_build() {  # $1 = xcodebuild log
  if grep -q '\*\* BUILD SUCCEEDED \*\*' "$1" 2>/dev/null; then
    say "    BUILD SUCCEEDED"
  elif grep -q '\*\* BUILD FAILED \*\*' "$1" 2>/dev/null; then
    say "    BUILD FAILED"
  else
    say "    (xcodebuild printed neither BUILD SUCCEEDED nor BUILD FAILED)"
  fi
  show_matches 'error:' "$1" 40
  say "    log: $1"
}

build_succeeded() {  # $1 = xcodebuild status, $2 = its log, $3 = the product it should have made
  [ "$1" -eq 0 ] && grep -q '\*\* BUILD SUCCEEDED \*\*' "$2" 2>/dev/null && [ -d "$3" ]
}

asc_key_args() {  # adds the API key to "sign" when there is one (see ASC_DIR)
  local key id issuer
  for key in "$ASC_DIR"/AuthKey_*.p8; do
    [ -f "$key" ] || continue
    id=$(basename "$key" .p8)
    id=${id#AuthKey_}
    issuer=$(tr -d ' \t\r\n' <"$ASC_DIR/issuer.txt" 2>/dev/null)
    if [ -n "$issuer" ]; then
      sign+=(-authenticationKeyPath "$key" -authenticationKeyID "$id" -authenticationKeyIssuerID "$issuer")
      say "    signing with the App Store Connect key $id"
    fi
    return 0
  done
  return 0
}

hints() {  # $1 = a log; plain-English hints for failures seen before
  [ -f "$1" ] || return 0
  if grep -q 'errSecInternalComponent' "$1"; then
    say "    hint: the keychain is locked (signing over SSH?). Run this in Terminal on that Mac."
  fi
  if grep -qiE 'agree to the (Xcode|license)|license agreement' "$1"; then
    say "    hint: open Xcode once on this Mac to accept its license, then run this again."
  fi
  if grep -qiE 'requires a provisioning profile|No profiles for' "$1"; then
    say "    hint: the build now wants a provisioning profile, and this script never makes one."
  fi
  if grep -q 'No Accounts' "$1"; then
    say "    hint: sign in to Xcode once on this Mac (Xcode > Settings > Accounts > +, Apple ID of team D8D94SXAG6)."
  fi
  if grep -qi 'developer mode' "$1"; then
    say "    hint: turn on Developer Mode on the iPhone (Settings > Privacy & Security > Developer Mode)."
  fi
}

# A build or verify that failed because WoodruffMacWidgets.appex inside the generated app has a stale signature.
stale_widget_signature() {
  # Includes the wording Xcode 26 uses when the embedded widget was signed by another certificate.
  grep -E -B 3 -A 3 'code object is not signed at all|a sealed resource is missing or invalid|invalid signature|not signed with the same certificate as the parent app' \
    "$1" 2>/dev/null | grep -q 'WoodruffMacWidgets\.appex'
}

# Xcode refuses this Mac's own certificate (revoked by Apple, usually because another Mac made a new one).
revoked_certificate() {
  grep -q 'Signing certificate is invalid' "$1" 2>/dev/null
}

identity_count() {
  security find-identity -v -p codesigning </dev/null 2>&1 | tail -1 | sed 's/^[[:space:]]*//'
}

# Warns when a signing certificate has less than 30 days left. $1 = whose, $2 = expiry (ISO), $3 = days left.
certificate_warning() {
  case "$3" in
    '' | *[!0-9-]* | -) return 0 ;;
  esac
  if [ "$3" -lt 30 ]; then
    warn "$1 signing certificate expires on ${2%%T*}. After that someone needs to sign in to Xcode once on"
    warn "this Mac to get a new one; until then this keeps working."
  fi
}

# "valid until 2027-11-04" for a certificate's expiry (ISO), or "expiry unknown".
valid_until() {
  if [ -n "$1" ]; then printf 'valid until %s\n' "${1%%T*}"; else printf 'expiry unknown\n'; fi
}

cleanup() {  # removes only the iPhone signing folder this run made
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    case "$(basename "$WORK")" in
      woodruff-iphone.*) rm -rf "$WORK" ;;
    esac
  fi
  WORK=""
}

device_name() {  # $1 = UDID
  local i=0
  while [ "$i" -lt "${#IPHONE_UDIDS[@]}" ]; do
    if [ "${IPHONE_UDIDS[$i]}" = "$1" ]; then
      printf '%s\n' "${IPHONE_NAMES[$i]:-$1}"
      return 0
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$1"
}

# ------------------------------------------------------------------------------------- checkout and project

update_checkout() {  # $1 = the --expect commit, or ""
  local log="$LOGDIR/git.log" head head_lc expect_lc ref="refs/remotes/origin/$BRANCH"
  export GIT_TERMINAL_PROMPT=0
  if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "${GIT_SSH:-}" ] && [ -z "$(git config --get core.sshCommand 2>/dev/null)" ]; then
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes"   # never a passphrase or host-key prompt
  fi
  if [ "$DETACH" -eq 1 ]; then
    step "Updating the checkout to origin/$BRANCH"
    if ! git fetch origin "+refs/heads/$BRANCH:$ref" </dev/null >>"$log" 2>&1; then
      if grep -qi "couldn't find remote ref" "$log"; then
        problem "origin has no branch $BRANCH (--branch $BRANCH), so nothing was built"
      else
        problem "git fetch of $BRANCH failed, so nothing was built:"
        tail -n 5 "$log" | indent
      fi
      return 1
    fi
    if ! git rev-parse --verify --quiet "$ref^{commit}" </dev/null >/dev/null 2>&1; then
      problem "origin/$BRANCH isn't a commit here even after fetching it (--branch $BRANCH), so nothing was built"
      return 1
    fi
    if ! git checkout --detach "$ref" </dev/null >>"$log" 2>&1; then
      problem "git checkout --detach origin/$BRANCH failed (local changes in the way?), so nothing was built:"
      tail -n 5 "$log" | indent
      return 1
    fi
  else
    step "Updating the checkout to the newest $BRANCH"
    if ! git fetch origin "$BRANCH" </dev/null >>"$log" 2>&1; then
      problem "git fetch failed, so nothing was built:"
      tail -n 5 "$log" | indent
      return 1
    fi
    if ! git checkout "$BRANCH" </dev/null >>"$log" 2>&1; then
      problem "git checkout $BRANCH failed, so nothing was built:"
      tail -n 5 "$log" | indent
      return 1
    fi
    if ! git pull --ff-only --no-rebase origin "$BRANCH" </dev/null >>"$log" 2>&1; then
      problem "git pull --ff-only failed (local commits or changes in the way?), so nothing was built:"
      tail -n 5 "$log" | indent
      return 1
    fi
  fi
  head=$(git rev-parse HEAD 2>/dev/null)
  COMMIT=$(printf '%s' "$head" | tr 'A-F' 'a-f')
  BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null)
  case "$BUILD_NUMBER" in
    '' | *[!0-9]*) BUILD_NUMBER="" ;;
  esac
  case "$COMMIT" in
    '' | *[!0-9a-f]*) COMMIT="" ;;
  esac
  # Into every build: the Info.plist's WoodruffCommit and CFBundleVersion ("Build N · abc1234" in Settings).
  VERSION_SETTINGS=()
  if [ -n "$COMMIT" ]; then VERSION_SETTINGS+=("WOODRUFF_COMMIT=$COMMIT"); fi
  if [ -n "$BUILD_NUMBER" ]; then VERSION_SETTINGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER"); fi
  HEAD_DESC=$(git log -1 --format='%h %s' 2>/dev/null)
  say "    at $HEAD_DESC${BUILD_NUMBER:+ (build $BUILD_NUMBER)}"
  if [ -n "$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    warn "the checkout has local changes; they're in this build too"
  fi
  if [ -n "$1" ]; then
    head_lc=$(printf '%s' "$head" | tr 'A-F' 'a-f')
    expect_lc=$(printf '%s' "$1" | tr 'A-F' 'a-f')
    case "$head_lc" in
      "$expect_lc"*) say "    matches --expect $1" ;;
      *)
        problem "the checkout is at ${head:-an unknown commit}, not $1 (--expect), so nothing was built"
        return 1
        ;;
    esac
  fi
  return 0
}

generate_project() {
  local log="$LOGDIR/xcodegen.log"
  step "Generating the Xcode project"
  if ! command -v xcodegen >/dev/null 2>&1; then
    problem "xcodegen isn't installed (brew install xcodegen), so nothing was built"
    return 1
  fi
  if ! xcodegen generate </dev/null >"$log" 2>&1; then
    problem "xcodegen generate failed, so nothing was built:"
    tail -n 8 "$log" | indent
    return 1
  fi
  say "    WoodruffFamily.xcodeproj generated"
  return 0
}

# ------------------------------------------------------------------------------------------------- the Mac

mac_failed() {  # $1 = what happened, $2 = a log to look at (optional), $3 = the --results status (failed)
  problem "$1"
  if [ -n "${2:-}" ]; then hints "$2"; fi
  note "Mac: NOT installed: $1"
  result "$MAC_PART" "${3:-failed}" "" "$1"
  return 1
}

# Removes the one generated product a stale widget signature can spoil, and nothing else.
remove_stale_mac_product() {
  local product="$ROOT/build/Build/Products/Release/Woodruff Family.app"
  [ -n "$ROOT" ] || return 1
  [ -d "$product" ] || return 0
  rm -rf "$product"
}

deploy_mac() {
  local pick="$LOGDIR/mac-identity.json" product="$ROOT/build/Build/Products/Release/$APP_NAME.app"
  local identity name why cert_expires cert_days attempt=1 log vlog status built sha12
  local -a sign

  MAC_PART="mac"
  if [ "$XCODE_SIGNING" -eq 1 ]; then
    identity="Xcode automatic signing"
    name="team $TEAM"
    cert_expires=""
    sign=(CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
    asc_key_args
    step "Mac: signing with Xcode's account (team $TEAM)"
  else
    step "Mac: choosing the signing identity"
    if ! signing pick-mac --team "$TEAM" --app "$MAC_INSTALLED" >"$pick" 2>"$LOGDIR/mac-identity.log"; then
      indent <"$pick"
      indent <"$LOGDIR/mac-identity.log"
      mac_failed "no signing identity for the Mac app on this Mac (nothing was changed)"
      return 1
    fi
    identity=$(signing get "$pick" identity)
    name=$(signing get "$pick" name)
    why=$(signing get "$pick" reason)
    cert_expires=$(signing get "$pick" identity_expires 2>/dev/null)
    cert_days=$(signing get "$pick" identity_days_left 2>/dev/null)
    say "    $identity  $name ($why)"
    say "    certificate $(valid_until "$cert_expires")"
    certificate_warning "this Mac's" "$cert_expires" "$cert_days"
    sign=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "PROVISIONING_PROFILE_SPECIFIER=")
  fi

  while :; do
    log="$LOGDIR/mac-build-$attempt.log"
    step "Mac: building (Release)"
    xcodebuild -project WoodruffFamily.xcodeproj -scheme WoodruffFamilyMac -destination 'platform=macOS' \
      -configuration Release -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" "${sign[@]}" \
      ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} build </dev/null >"$log" 2>&1
    status=$?
    show_build "$log"
    built=0
    if build_succeeded "$status" "$log" "$product"; then
      vlog="$LOGDIR/mac-verify-build-$attempt.log"
      if codesign --verify --deep --strict --verbose=2 "$product" </dev/null >"$vlog" 2>&1; then
        say "    the new build's signature verifies"
        built=1
      else
        say "    the new build's signature doesn't verify:"
        show_matches '.' "$vlog" 12
        log=$vlog
      fi
    fi
    if [ "$built" -eq 1 ]; then
      break
    fi
    if [ "$attempt" -eq 1 ] && stale_widget_signature "$log"; then
      say "    That's a stale WoodruffMacWidgets.appex signature: removing only the generated"
      say "    build/Build/Products/Release/$APP_NAME.app and building once more."
      if ! remove_stale_mac_product; then
        mac_failed "couldn't remove the stale $product"
        return 1
      fi
      attempt=2
      continue
    fi
    if revoked_certificate "$log"; then
      sha12=$(git rev-parse --short=12 HEAD 2>/dev/null)
      mac_failed "this Mac's signing certificate was revoked by Apple, so it can't sign builds any more (log $log); $MAC_INSTALLED wasn't touched. Instead of signing in here: run scripts/deploy.sh ${BRANCH_OPT}--expect $sha12 mac share on a Mac that can sign, then scripts/deploy.sh ${BRANCH_OPT}--expect $sha12 mac-shared here (README: Deploying)." "$log"
      return 1
    fi
    mac_failed "the Mac app didn't build or verify (log $log); $MAC_INSTALLED wasn't touched" "$log"
    return 1
  done

  install_mac "$product" "signed by $identity ($name), certificate $(valid_until "$cert_expires")"
  status=$?
  # The Apple Home helper too (only Xcode's signing can give it Apple Home); a failure here leaves the Mac app as
  # it is, without Apple Home's devices.
  if [ "$status" -eq 0 ] && [ "$XCODE_SIGNING" -eq 1 ]; then
    build_install_helper "${sign[@]}"
  fi
  return $status
}

# Puts the Apple Home helper in /Applications: quits the running one, swaps the new one in, starts it (the first time
# macOS asks once to allow access to Home), and shares it in iCloud Drive for the other Macs. $1 = a staged copy.
put_helper() {
  local new=$1 hlog="$LOGDIR/helper-install.log" staged="${HELPER_INSTALLED%.app}.new.app"
  pkill -U "$(id -u)" -x "$HELPER_NAME" >/dev/null 2>&1
  rm -rf "$staged"
  if ! ditto "$new" "$staged" </dev/null >>"$hlog" 2>&1; then
    warn "couldn't copy $HELPER_NAME into /Applications (log $hlog)"
    rm -rf "$staged"
    return 1
  fi
  rm -rf "$HELPER_INSTALLED"
  if ! mv "$staged" "$HELPER_INSTALLED" 2>>"$hlog"; then
    warn "couldn't put $HELPER_NAME in /Applications (log $hlog)"
    return 1
  fi
  open -g -j "$HELPER_INSTALLED" </dev/null >/dev/null 2>&1
  say "    $HELPER_NAME installed in /Applications (Apple Home on this Mac)"
  return 0
}

build_install_helper() {  # "$@" = the signing settings
  local hlog="$LOGDIR/helper-build.log" product="$ROOT/build-helper/Build/Products/Release-maccatalyst/$HELPER_NAME.app"
  step "Mac: building $HELPER_NAME (Apple Home on the Macs)"
  # From scratch: built on top of the last one, Xcode can put a new profile in without signing again ("a sealed
  # resource is missing or invalid"). It's small, so this takes seconds.
  rm -rf "$ROOT/build-helper/Build/Products"
  xcodebuild -project WoodruffFamily.xcodeproj -scheme WoodruffHomeHelper -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -configuration Release -derivedDataPath build-helper DEVELOPMENT_TEAM="$TEAM" "$@" \
    ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} build </dev/null >"$hlog" 2>&1
  if [ ! -d "$product" ] || ! codesign --verify --deep --strict "$product" </dev/null >>"$hlog" 2>&1; then
    show_build "$hlog"
    warn "$HELPER_NAME didn't build (log $hlog): the Mac app works, without Apple Home's devices"
    return 1
  fi
  put_helper "$product" || return 1
  # How many Macs its signing profile lets it open on (a Mac registered since is added at Xcode's next profile).
  local macs
  macs=$(security cms -D -i "$product/Contents/embedded.provisionprofile" 2>/dev/null |
    plutil -extract ProvisionedDevices raw -o - - 2>/dev/null)
  [ -n "$macs" ] && say "    its signing profile lists $macs Mac(s), the Macs it opens on"
  # For the Macs that install the shared build.
  # A new name each time: macOS lets only the app that made a file in iCloud Drive change it (one made from Terminal
  # can't be replaced by the updater), and the other Macs take the newest.
  local sha12 shared
  sha12=$(git rev-parse --short=12 HEAD 2>/dev/null)
  shared="$SHARE_DIR/$HELPER_NAME ${sha12:-$(date +%s)}.zip"
  if mkdir -p "$SHARE_DIR" 2>/dev/null && ditto -c -k --sequesterRsrc --keepParent "$HELPER_INSTALLED" "$LOGDIR/helper.zip" </dev/null >>"$hlog" 2>&1 &&
    cp "$LOGDIR/helper.zip" "$shared" 2>>"$hlog"; then
    say "    shared as Woodruff Family builds/$(basename "$shared")"
    local f
    for f in "$SHARE_DIR/$HELPER_NAME"*.zip; do
      [ "$f" = "$shared" ] || rm -f "$f" 2>/dev/null
    done
  else
    warn "$HELPER_NAME wasn't shared in iCloud Drive (log $hlog): the other Macs keep the one they have"
  fi
  return 0
}

# 0 when this Mac can open the helper $1: its development profile lists the Macs it runs on, and macOS refuses (with
# a message each time it's started) on any other.
helper_runs_here() {
  local prof="$1/Contents/embedded.provisionprofile" plist udid
  [ -f "$prof" ] || return 0
  plist=$(security cms -D -i "$prof" 2>/dev/null) || return 0
  case "$plist" in *ProvisionsAllDevices*) return 0 ;; esac
  udid=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ {print $2; exit}')
  [ -n "$udid" ] || return 0
  case "$plist" in *"<string>$udid</string>"*) return 0 ;; esac
  return 1
}

# On a Mac that installs the shared build: the helper the Mac Studio shared, when there is one newer than this one's.
install_shared_helper() {
  local zip="" f unz="$LOGDIR/helper-shared" hlog="$LOGDIR/helper-install.log"
  # The newest one shared ("Woodruff Home Helper <commit>.zip", or the older plain name); downloaded first if iCloud
  # only has a placeholder.
  if command -v brctl >/dev/null 2>&1; then
    for f in "$SHARE_DIR/.$HELPER_NAME"*.zip.icloud; do
      [ -e "$f" ] || continue
      f=${f%.icloud}
      brctl download "$SHARE_DIR/${f##*/.}" </dev/null >/dev/null 2>&1
    done
  fi
  for f in "$SHARE_DIR/$HELPER_NAME"*.zip; do
    [ -f "$f" ] || continue
    if [ -z "$zip" ] || [ "$f" -nt "$zip" ]; then zip=$f; fi
  done
  [ -n "$zip" ] || return 0
  # Only a newer one than the one installed from there last (so the running helper isn't restarted every check).
  local stamp="$HOME/Library/Application Support/Woodruff Family/helper-installed.stamp"
  local refused="$HOME/Library/Application Support/Woodruff Family/helper-refused.stamp"
  # One installed that this Mac won't open: taken out, so the Mac app doesn't keep trying to start it.
  if [ -d "$HELPER_INSTALLED" ] && ! helper_runs_here "$HELPER_INSTALLED"; then
    pkill -U "$(id -u)" -x "$HELPER_NAME" >/dev/null 2>&1
    rm -rf "$HELPER_INSTALLED"
    rm -f "$stamp"
  fi
  if [ -d "$HELPER_INSTALLED" ] && [ -f "$stamp" ] && [ ! "$zip" -nt "$stamp" ]; then return 0; fi
  if [ -f "$refused" ] && [ ! "$zip" -nt "$refused" ]; then return 0; fi
  step "Mac: installing $HELPER_NAME (Apple Home on this Mac)"
  rm -rf "$unz"
  mkdir -p "$unz"
  if ! ditto -x -k "$zip" "$unz" </dev/null >>"$hlog" 2>&1 || [ ! -d "$unz/$HELPER_NAME.app" ] ||
    ! codesign --verify --deep --strict "$unz/$HELPER_NAME.app" </dev/null >>"$hlog" 2>&1; then
    warn "the shared $HELPER_NAME couldn't be used (log $hlog)"
    rm -rf "$unz"
    return 1
  fi
  if ! helper_runs_here "$unz/$HELPER_NAME.app"; then
    warn "$HELPER_NAME isn't installed here: this Mac isn't in its signing profile (register it under Devices at developer.apple.com; the Mac Studio's next build includes it)"
    mkdir -p "$(dirname "$refused")" && touch "$refused"
    rm -rf "$unz"
    return 0
  fi
  rm -f "$refused"
  if put_helper "$unz/$HELPER_NAME.app"; then
    mkdir -p "$(dirname "$stamp")" && touch "$stamp"
  fi
  rm -rf "$unz"
}

gone_within() {  # $1 = seconds: 0 once Woodruff Family isn't running any more
  local waited=0
  while pgrep -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; do
    if [ "$waited" -ge "$1" ]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}

# Quits the running Mac app, 10 seconds for each way of asking: the Darwin notification the app listens for (this
# needs no Automation permission, so it works from the updater's LaunchAgent), then AppleScript, then SIGTERM.
quit_mac_app() {  # $1 = log
  if command -v notifyutil >/dev/null 2>&1; then
    say "    asking the running $APP_NAME to quit"
    notifyutil -p "$QUIT_NOTIFICATION" </dev/null >>"$1" 2>&1
    if gone_within 10; then return 0; fi
  fi
  say "    quitting the running $APP_NAME"
  bounded 15 "$1" osascript -e 'quit app "Woodruff Family"'
  if gone_within 10; then return 0; fi
  if command -v pkill >/dev/null 2>&1; then
    say "    it's still running: sending it SIGTERM"
    pkill -TERM -U "$(id -u)" -x "$APP_NAME" </dev/null >>"$1" 2>&1
    if gone_within 10; then return 0; fi
  fi
  return 1
}

# Set by scripts/updater.py: until that time (seconds since 1970) a deploy doesn't quit the app while someone is
# using it, since the build before this can take a while. updater.py wait-idle returns once nobody is.
wait_until_idle() {
  local until=${WOODRUFF_DEPLOY_IDLE_UNTIL:-}
  case "$until" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ -f "$ROOT/scripts/updater.py" ] || return 0
  python3 -I "$ROOT/scripts/updater.py" wait-idle --until "$until" </dev/null 2>&1 | indent
  return 0
}

# Quits the running app, copies the checked build $1 over $MAC_INSTALLED, checks that copy and opens it.
# $2 = the "signed by ..." line for the summary. 0 once it's copied; MAC_OK=1 when it also verifies and runs.
install_mac() {
  local product=$1 signed=$2 bid ilog="$LOGDIR/mac-install.log" vlog="$LOGDIR/mac-verify-installed.log"
  local waited verified=1 running=0 staged old
  local -a open_flags

  bid=$(signing bundle-id "$product" 2>/dev/null)
  if [ "$bid" != "$MAC_BUNDLE_ID" ]; then
    mac_failed "the new build is '$bid', not $MAC_BUNDLE_ID; $MAC_INSTALLED wasn't touched"
    return 1
  fi

  # Only now, with a verified new build, is the installed app quit and replaced.
  step "Mac: installing"
  if pgrep -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then
    wait_until_idle
  fi
  if pgrep -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then
    if ! quit_mac_app "$ilog"; then
      mac_failed "$APP_NAME didn't quit when asked (notification, AppleScript, then SIGTERM), so it wasn't replaced (the new build is $product)"
      return 1
    fi
  fi
  # A fresh copy next to it, then swapped in: copying over the old bundle would keep files the new build doesn't
  # have (going back to an older build), and the signature check would fail.
  staged="${MAC_INSTALLED%.app}.new.app"
  old="${MAC_INSTALLED%.app}.old.app"
  rm -rf "$staged" "$old"
  if ! ditto "$product" "$staged" </dev/null >>"$ilog" 2>&1; then
    tail -n 5 "$ilog" | indent
    rm -rf "$staged"
    mac_failed "copying the new build next to $MAC_INSTALLED failed; $MAC_INSTALLED wasn't touched (the new build is $product)"
    return 1
  fi
  if [ -e "$MAC_INSTALLED" ] && ! mv "$MAC_INSTALLED" "$old" 2>>"$ilog"; then
    rm -rf "$staged"
    mac_failed "couldn't move the old $MAC_INSTALLED aside, so it wasn't replaced (the new build is $product)"
    return 1
  fi
  if ! mv "$staged" "$MAC_INSTALLED" 2>>"$ilog"; then
    if [ -e "$old" ]; then mv "$old" "$MAC_INSTALLED" 2>>"$ilog"; fi
    mac_failed "couldn't put the new build in place, so the old one is back (the new build is $product)"
    return 1
  fi
  rm -rf "$old"
  if codesign --verify --deep --strict --verbose=2 "$MAC_INSTALLED" </dev/null >"$vlog" 2>&1; then
    say "    $MAC_INSTALLED verifies"
  else
    verified=0
    problem "$MAC_INSTALLED doesn't verify after copying:"
    show_matches '.' "$vlog" 12
    say "    (\"file added\" means files from the old version are still inside it: drag $product"
    say "    into Applications and choose Replace)"
  fi
  # From the updater (in the background): opened without coming to the front over whatever someone is doing.
  if [ -n "${WOODRUFF_DEPLOY_BACKGROUND:-}" ]; then
    open_flags=(-g)
  else
    open_flags=()
  fi
  if ! open ${open_flags[@]+"${open_flags[@]}"} "$MAC_INSTALLED" </dev/null >>"$ilog" 2>&1; then
    tail -n 3 "$ilog" | indent
  fi
  waited=0
  while [ "$waited" -lt 20 ]; do
    if pgrep -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then
      running=1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$running" -eq 1 ]; then
    say "    $APP_NAME is running"
  else
    problem "$APP_NAME didn't start after installing"
  fi

  if [ "$verified" -eq 1 ] && [ "$running" -eq 1 ]; then
    MAC_OK=1
    note "Mac: installed $MAC_INSTALLED and it's running"
    result "$MAC_PART" installed "" "installed and running, $signed"
  elif [ "$verified" -eq 1 ]; then
    note "Mac: installed $MAC_INSTALLED, but it DIDN'T START"
    result "$MAC_PART" installed "" "installed, but it didn't start, $signed"
  else
    note "Mac: installed $MAC_INSTALLED, but its signature DOESN'T VERIFY (log $vlog)"
    result "$MAC_PART" failed "" "copied to $MAC_INSTALLED, but its signature doesn't verify (log $vlog)"
  fi
  note "     $signed"
  return 0
}


# Shares the Mac app just installed here in iCloud Drive, for a Mac that can't sign (mac-shared there).
# WoodruffCommit of the installed Mac app (empty for a build from before it was recorded).
installed_commit() {
  python3 -I -c 'import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        print(plistlib.load(handle).get("WoodruffCommit") or "")
except Exception:
    print("")' "$MAC_INSTALLED/Contents/Info.plist" 2>/dev/null
}

# share without mac: shares the Mac app installed here, when it's this commit's build and verifies.
share_installed() {
  local head have
  head=$(git rev-parse HEAD 2>/dev/null)
  have=$(installed_commit)
  step "Mac: sharing the installed build"
  if [ -z "$have" ] || [ "$have" != "$head" ]; then
    problem "the installed Mac app is ${have:-an older build}, not this commit's ($head), so it wasn't shared"
    note "Mac: NOT shared in iCloud Drive (the installed app isn't this commit's build)"
    result share failed "$head" "the installed app isn't this commit's build"
    return 1
  fi
  if ! codesign --verify --deep --strict "$MAC_INSTALLED" </dev/null >/dev/null 2>&1; then
    problem "$MAC_INSTALLED doesn't verify, so it wasn't shared"
    note "Mac: NOT shared in iCloud Drive (the installed app doesn't verify)"
    result share failed "$head" "the installed app doesn't verify"
    return 1
  fi
  MAC_OK=1
  share_mac
}

share_mac() {
  local head sha12 subject f zip="$LOGDIR/share.zip" manifest="$LOGDIR/share.json" slog="$LOGDIR/mac-share.log"
  step "Mac: sharing this build in iCloud Drive"
  if [ "$MAC_OK" -ne 1 ]; then
    problem "the Mac app wasn't installed and running here, so it wasn't shared"
    note "Mac: NOT shared in iCloud Drive (the install here didn't work)"
    result share skipped "" "not shared: the Mac app wasn't installed and running here"
    return 1
  fi
  if [ ! -d "$ICLOUD" ]; then
    problem "iCloud Drive isn't on for this Mac's user ($ICLOUD is missing), so the build wasn't shared"
    note "Mac: NOT shared in iCloud Drive (iCloud Drive is off here)"
    result share failed "" "not shared: iCloud Drive is off for this Mac's user"
    return 1
  fi
  head=$(git rev-parse HEAD 2>/dev/null)
  sha12=$(printf '%s' "$head" | cut -c1-12)
  subject=$(git log -1 --format=%s 2>/dev/null)
  if [ -z "$sha12" ] || ! mkdir -p "$SHARE_DIR" 2>>"$slog"; then
    problem "couldn't make $SHARE_DIR, so the build wasn't shared"
    note "Mac: NOT shared in iCloud Drive"
    result share failed "" "not shared: couldn't make $SHARE_DIR"
    return 1
  fi
  if ! ditto -c -k --sequesterRsrc --keepParent "$MAC_INSTALLED" "$zip" </dev/null >>"$slog" 2>&1 ||
    ! signing share-manifest --app "$MAC_INSTALLED" --zip "$zip" --commit "$head" --subject "$subject" \
      --out "$manifest" 2>>"$slog"; then
    tail -n 5 "$slog" | indent
    problem "couldn't zip $MAC_INSTALLED for sharing (log $slog)"
    note "Mac: NOT shared in iCloud Drive"
    result share failed "" "not shared: couldn't zip $MAC_INSTALLED (log $slog)"
    return 1
  fi
  # The zip first, the manifest last. iCloud may deliver them in either order; mac-shared checks one against the
  # other and waits until they match.
  if ! cp "$zip" "$SHARE_DIR/$APP_NAME $sha12.zip" 2>>"$slog" ||
    ! cp "$manifest" "$SHARE_DIR/$APP_NAME $sha12.json" 2>>"$slog"; then
    tail -n 5 "$slog" | indent
    problem "couldn't copy the zip into $SHARE_DIR (log $slog)"
    note "Mac: NOT shared in iCloud Drive"
    result share failed "" "not shared: couldn't copy the zip into $SHARE_DIR (log $slog)"
    return 1
  fi
  for f in "$SHARE_DIR/$APP_NAME "*.zip "$SHARE_DIR/$APP_NAME "*.json; do
    case "$f" in
      *" $sha12.zip" | *" $sha12.json") ;;
      *) if [ -f "$f" ]; then rm -f "$f"; fi ;;
    esac
  done
  rm -f "$zip"
  say "    Woodruff Family builds/$APP_NAME $sha12.zip ($(du -h "$SHARE_DIR/$APP_NAME $sha12.zip" 2>/dev/null | cut -f1 | tr -d ' '))"
  note "Mac: shared this build in iCloud Drive (Woodruff Family builds/$APP_NAME $sha12.zip); on a Mac"
  note "     that can't sign, install it with: scripts/deploy.sh ${BRANCH_OPT}--expect $sha12 mac-shared"
  result share ok "" "shared in iCloud Drive as Woodruff Family builds/$APP_NAME $sha12.zip"
  return 0
}

# Installs the build another Mac shared in iCloud Drive for this commit (share there) instead of building one:
# for a Mac whose own certificate Apple revoked. The installed app is replaced only by a zip that matches its
# manifest, verifies, and is signed by a certificate with the installed app's name and this team.
seconds_words() {  # "20 minutes" or "45 seconds"
  if [ "$1" -ge 120 ]; then printf '%s minutes\n' $(($1 / 60)); else printf '%s seconds\n' "$1"; fi
}

deploy_mac_shared() {
  local head sha12 name zip manifest copy="$LOGDIR/shared.zip" meta="$LOGDIR/shared.json"
  local check="$LOGDIR/shared-check.json" clog="$LOGDIR/shared-check.log" unz="$LOGDIR/shared"
  local product waited=0 got=0 final=0 pause built_on vlog="$LOGDIR/mac-verify-shared.log" new_sha1 new_cn new_team
  local old_cn status why i
  MAC_PART="mac-shared"
  step "Mac: installing the build another Mac shared in iCloud Drive"
  if [ ! -d "$ICLOUD" ]; then
    mac_failed "iCloud Drive isn't on for this Mac's user ($ICLOUD is missing), so there's no shared build; $MAC_INSTALLED wasn't touched"
    return 1
  fi
  head=$(git rev-parse HEAD 2>/dev/null)
  sha12=$(printf '%s' "$head" | cut -c1-12)
  name="$APP_NAME $sha12"
  zip="$SHARE_DIR/$name.zip"
  manifest="$SHARE_DIR/$name.json"
  if [ "$SHARE_WAIT" -gt 0 ]; then
    say "    waiting for Woodruff Family builds/$name.zip (up to $(seconds_words "$SHARE_WAIT"))"
  else
    say "    looking for Woodruff Family builds/$name.zip"
  fi
  while :; do
    # With Optimize Mac Storage a file iCloud hasn't brought down yet is only a placeholder (.NAME.icloud), so it
    # isn't there by its own name until it's asked for: ask every time round, before looking.
    if command -v brctl >/dev/null 2>&1; then
      brctl download "$manifest" </dev/null >/dev/null 2>&1
      brctl download "$zip" </dev/null >/dev/null 2>&1
      if [ ! -f "$zip" ] && [ -e "$SHARE_DIR/.$name.zip.icloud" ]; then
        i=0   # it's on its way down: give it up to a minute
        while [ "$i" -lt 30 ] && [ ! -f "$zip" ]; do sleep 2; i=$((i + 1)); done
      fi
    fi
    if [ -f "$manifest" ] && [ -f "$zip" ]; then
      if cp "$manifest" "$meta" 2>"$clog" && cp "$zip" "$copy" 2>>"$clog"; then
        signing check-share --manifest "$meta" --zip "$copy" --commit "$head" --team "$TEAM" >"$check" 2>>"$clog"
        status=$?
        if [ "$status" -eq 0 ]; then
          got=1
          break
        fi
        if [ "$status" -eq 3 ]; then   # it can never be used: waiting won't help
          final=1
          break
        fi
      fi
    fi
    if [ "$waited" -ge "$SHARE_WAIT" ]; then
      break
    fi
    pause=15
    if [ $((SHARE_WAIT - waited)) -lt "$pause" ]; then pause=$((SHARE_WAIT - waited)); fi
    sleep "$pause"
    waited=$((waited + pause))
    if [ $((waited % 120)) -eq 0 ]; then
      say "    still waiting ($((waited / 60)) minutes)"
    fi
  done
  if [ "$got" -ne 1 ]; then
    if [ -s "$clog" ]; then tail -n 3 "$clog" | indent; fi
    rm -f "$copy"
    if [ "$final" -eq 1 ]; then
      why=$(tail -n 1 "$clog" 2>/dev/null)
      if [ -z "$why" ]; then why="The shared build of $sha12 can't be used."; fi
      mac_failed "${why%.}; $MAC_INSTALLED wasn't touched"
    elif [ "$SHARE_WAIT" -gt 0 ]; then
      mac_failed "no complete build of $sha12 arrived in iCloud Drive (Woodruff Family builds) within $(seconds_words "$SHARE_WAIT"); a Mac that can sign shares one with scripts/deploy.sh ${BRANCH_OPT}--expect $sha12 mac share. $MAC_INSTALLED wasn't touched" "" waiting
    else
      mac_failed "no complete build of $sha12 is in iCloud Drive (Woodruff Family builds) yet; a Mac that can sign shares one with scripts/deploy.sh ${BRANCH_OPT}--expect $sha12 mac share. $MAC_INSTALLED wasn't touched" "" waiting
    fi
    return 1
  fi
  built_on=$(signing get "$check" built_on 2>/dev/null)
  say "    $name.zip from ${built_on:-another Mac} matches its manifest"

  rm -rf "$unz"
  if ! mkdir -p "$unz" || ! ditto -x -k "$copy" "$unz" </dev/null >"$LOGDIR/shared-unzip.log" 2>&1; then
    tail -n 5 "$LOGDIR/shared-unzip.log" | indent
    rm -rf "$unz" "$copy"
    mac_failed "couldn't unzip the shared build; $MAC_INSTALLED wasn't touched"
    return 1
  fi
  rm -f "$copy"
  product="$unz/$APP_NAME.app"
  if [ ! -d "$product" ]; then
    rm -rf "$unz"
    mac_failed "the shared zip has no $APP_NAME.app inside; $MAC_INSTALLED wasn't touched"
    return 1
  fi
  # This family's own build, copied by iCloud Drive: no download warning when it opens.
  xattr -dr com.apple.quarantine "$product" </dev/null >/dev/null 2>&1
  if ! codesign --verify --deep --strict --verbose=2 "$product" </dev/null >"$vlog" 2>&1; then
    show_matches '.' "$vlog" 12
    rm -rf "$unz"
    mac_failed "the shared build's signature doesn't verify (log $vlog); $MAC_INSTALLED wasn't touched"
    return 1
  fi
  if ! signing signer --app "$product" >"$LOGDIR/shared-signer.json" 2>>"$clog"; then
    rm -rf "$unz"
    mac_failed "can't tell which certificate signed the shared build; $MAC_INSTALLED wasn't touched"
    return 1
  fi
  new_sha1=$(signing get "$LOGDIR/shared-signer.json" sha1 2>/dev/null)
  new_cn=$(signing get "$LOGDIR/shared-signer.json" cn 2>/dev/null)
  new_team=$(signing get "$LOGDIR/shared-signer.json" team 2>/dev/null)
  if [ "$new_team" != "$TEAM" ]; then
    rm -rf "$unz"
    mac_failed "the shared build is signed for team '${new_team:-unknown}', not $TEAM; $MAC_INSTALLED wasn't touched"
    return 1
  fi
  # The keychain gives the TVs' pairings to an app signed by a certificate with the same name and team as the
  # app that saved them. A build signed under another name would sign this Mac out of every TV: not installed.
  if [ -d "$MAC_INSTALLED" ] && signing signer --app "$MAC_INSTALLED" >"$LOGDIR/installed-signer.json" 2>/dev/null; then
    old_cn=$(signing get "$LOGDIR/installed-signer.json" cn 2>/dev/null)
    if [ -n "$old_cn" ] && [ "$old_cn" != "$new_cn" ]; then
      rm -rf "$unz"
      mac_failed "the shared build is signed by '$new_cn' but the installed app by '$old_cn', and installing it would sign this Mac out of the TVs, so $MAC_INSTALLED wasn't touched"
      return 1
    fi
  fi
  say "    signed by $new_sha1 ($new_cn), the installed app's certificate name"
  install_mac "$product" "signed by $new_sha1 ($new_cn) on ${built_on:-another Mac}, shared in iCloud Drive"
  status=$?
  if [ "$status" -eq 0 ]; then install_shared_helper; fi
  if [ "$MAC_OK" -eq 1 ]; then
    rm -rf "$unz"
  fi
  return $status
}

# ---------------------------------------------------------------------------------------------- the iPhones

iphone_failed() {  # $1 = what happened, $2 = a log to show the end of (optional), $3 = --results status (failed)
  problem "$1"
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    tail -n 8 "$2" | indent
    hints "$2"
  fi
  note "iPhone: NOT installed: $1"
  result iphone-build "${3:-failed}" "" "$1${2:+ (log $2)}"
  return 1
}

# Keeps the signed iPhone app $1 as $KEEP_IPHONE/Woodruff Family.app with $KEEP_IPHONE/build.json, so it can be
# installed later without building again (scripts/updater.py). Replaces only the copy kept there before.
# $2 identity, $3 the app profile's UUID, $4 its expiry, $5 the iPhones JSON, then the UDIDs it's signed for.
keep_iphone() {
  local copy=$1 identity=$2 uuid=$3 expires=$4 devs=$5 kept="$KEEP_IPHONE/$APP_NAME.app" klog="$LOGDIR/iphone-keep.log"
  shift 5
  rm -f "$KEEP_IPHONE/build.json"
  if ! mkdir -p "$KEEP_IPHONE" 2>>"$klog" || { [ -e "$kept" ] && ! rm -rf "$kept"; } ||
    ! ditto "$copy" "$kept" </dev/null >>"$klog" 2>&1 ||
    ! codesign --verify --deep --strict --verbose=2 "$kept" </dev/null >>"$klog" 2>&1 ||
    ! signing kept-build --commit "$COMMIT" --build "$BUILD_NUMBER" --identity "$identity" \
      --app-profile-uuid "$uuid" --app-profile-expires "$expires" --devices "$devs" --device "$@" \
      --out "$KEEP_IPHONE/build.json" 2>>"$klog"; then
    tail -n 5 "$klog" | indent
    problem "couldn't keep the signed iPhone app in $KEEP_IPHONE (log $klog)"
    return 1
  fi
  say "    kept in $kept"
  return 0
}

sign_frameworks() {  # $1 = .app or .appex, $2 = identity, $3 = log
  local item
  [ -d "$1/Frameworks" ] || return 0
  for item in "$1/Frameworks/"*; do
    [ -e "$item" ] || continue
    codesign --force --sign "$2" --timestamp=none "$item" </dev/null >>"$3" 2>&1 || return 1
  done
  return 0
}

deploy_iphone() {
  local devs="$LOGDIR/iphones.json" pick="$LOGDIR/iphone-signing.json" plog="$LOGDIR/iphone-signing.log"
  local -a targets usable sign
  local udid name i status identity identity_name cert_expires cert_days app_profile app_uuid app_expires app_days
  local widgets_profile widgets_uuid widgets_expires widgets_days log product copy appex slog vlog
  local bid item ilog llog installed=0 kept why variant ents

  step "iPhone: the iPhones paired with this Mac"
  if ! signing devices >"$devs" 2>"$LOGDIR/iphones.log"; then
    indent <"$LOGDIR/iphones.log"
    iphone_failed "couldn't list the iPhones (xcrun devicectl list devices)"
    return 1
  fi
  # One value per line; bash 3.2 has no mapfile, so split on newlines with globbing off.
  set -f
  IFS=$'\n'
  # shellcheck disable=SC2207
  IPHONE_UDIDS=($(signing get "$devs" '*.udid'))
  # shellcheck disable=SC2207
  IPHONE_NAMES=($(signing get "$devs" '*.name'))
  IFS=$' \t\n'
  set +f
  if [ "${#IPHONE_UDIDS[@]}" -eq 0 ]; then
    iphone_failed "no iPhone is paired with this Mac (xcrun devicectl list devices shows none)" "" skipped
    return 1
  fi
  i=0
  while [ "$i" -lt "${#IPHONE_UDIDS[@]}" ]; do
    say "    ${IPHONE_NAMES[$i]:-?}  ${IPHONE_UDIDS[$i]}"
    i=$((i + 1))
  done
  targets=("${IPHONE_UDIDS[@]}")

  if [ "$XCODE_SIGNING" -eq 1 ]; then
    identity="Xcode automatic signing"
    identity_name="team $TEAM"
    cert_expires=""
    app_uuid="managed by Xcode"
    app_expires=""
    widgets_uuid="managed by Xcode"
    widgets_expires=""
  else
    step "iPhone: choosing the signing identity and profiles"
    signing pick-ios --team "$TEAM" --app-id "$IPHONE_BUNDLE_ID" --widgets-id "$IPHONE_WIDGETS_ID" \
      --need-entitlement "$HOMEKIT" --device "${targets[@]}" >"$pick" 2>"$plog"
    status=$?
    if [ "$status" -ne 0 ]; then
      problem "$(signing get "$pick" problem 2>/dev/null || echo "signing.py pick-ios failed (log $plog)")"
      indent <"$pick"
      indent <"$plog"
      set -f
      IFS=$'\n'
      # shellcheck disable=SC2207
      usable=($(signing get "$pick" 'usable_devices.*' 2>/dev/null))
      IFS=$' \t\n'
      set +f
      if [ "$status" -ne 2 ] || [ "${#usable[@]}" -eq 0 ]; then
        note "iPhone: NOT installed: $(signing get "$pick" problem 2>/dev/null || echo "see $plog")"
        result iphone-build failed "" "$(signing get "$pick" problem 2>/dev/null || echo "signing.py pick-ios failed (log $plog)")"
        return 1
      fi
      for udid in "${IPHONE_UDIDS[@]}"; do
        case " ${usable[*]} " in
          *" $udid "*) ;;
          *)
            note "iPhone: NOT installed on $(device_name "$udid") ($udid): the provisioning profiles don't list it"
            result iphone skipped "$udid" "$(device_name "$udid"): not installed, the provisioning profiles don't list it"
            ;;
        esac
      done
      say "    Going on with the iPhones the profiles do list: ${usable[*]}"
      if ! signing pick-ios --team "$TEAM" --app-id "$IPHONE_BUNDLE_ID" --widgets-id "$IPHONE_WIDGETS_ID" \
        --need-entitlement "$HOMEKIT" --device "${usable[@]}" >"$pick" 2>"$plog"; then
        indent <"$pick"
        iphone_failed "no identity and profiles fit even those iPhones"
        return 1
      fi
      targets=("${usable[@]}")
    fi
    identity=$(signing get "$pick" identity)
    identity_name=$(signing get "$pick" identity_name)
    cert_expires=$(signing get "$pick" identity_expires 2>/dev/null)
    cert_days=$(signing get "$pick" identity_days_left 2>/dev/null)
    app_profile=$(signing get "$pick" app.path)
    app_uuid=$(signing get "$pick" app.uuid)
    app_expires=$(signing get "$pick" app.expires)
    app_days=$(signing get "$pick" app.days_left)
    widgets_profile=$(signing get "$pick" widgets.path)
    widgets_uuid=$(signing get "$pick" widgets.uuid)
    widgets_expires=$(signing get "$pick" widgets.expires)
    widgets_days=$(signing get "$pick" widgets.days_left)
    if [ -z "$identity" ] || [ ! -f "$app_profile" ] || [ ! -f "$widgets_profile" ]; then
      iphone_failed "signing.py pick-ios gave an incomplete answer (see $pick)"
      return 1
    fi
    say "    identity:        $identity  $identity_name"
    say "                     certificate $(valid_until "$cert_expires")"
    say "    app profile:     $app_uuid (expires ${app_expires%%T*})"
    say "    widgets profile: $widgets_uuid (expires ${widgets_expires%%T*})"
    if [ "${app_days:-0}" -lt 30 ] || [ "${widgets_days:-0}" -lt 30 ]; then
      warn "the iPhone profiles expire soon (${app_expires%%T*} / ${widgets_expires%%T*}). After that someone needs to"
      warn "sign in to Xcode once on this Mac to renew them; until then this keeps working."
    fi
    certificate_warning "the iPhone profiles'" "$cert_expires" "$cert_days"
  fi

  if [ "$XCODE_SIGNING" -eq 1 ]; then
    step "iPhone: building (Release, signed by Xcode's account, team $TEAM)"
    sign=(CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
    asc_key_args
  else
    step "iPhone: building (Release, unsigned)"
    sign=(CODE_SIGNING_ALLOWED=NO)
  fi
  log="$LOGDIR/iphone-build.log"
  product="$ROOT/build/Build/Products/Release-iphoneos/$APP_NAME.app"
  xcodebuild -project WoodruffFamily.xcodeproj -scheme WoodruffFamily -destination 'generic/platform=iOS' \
    -configuration Release -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" \
    WOODRUFF_BUNDLE_ID="$IPHONE_BUNDLE_ID" "${sign[@]}" \
    ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} build </dev/null >"$log" 2>&1
  status=$?
  show_build "$log"
  # Xcode couldn't sign with everything: drop only what Apple refused, so the iPhones still update. First without
  # the widgets' app group (not registered on the account yet; the Home Screen widgets then say to open the app)
  # but with push, then with neither.
  for variant in push basic; do
    if [ "$XCODE_SIGNING" -ne 1 ] || build_succeeded "$status" "$log" "$product"; then break; fi
    case "$variant" in
      push) warn "the iPhone build with the widgets' app group failed; building it again without the app group" ;;
      basic) warn "the iPhone build with push failed too; building it again without push" ;;
    esac
    case "$variant" in
      push) ents=App/iOS/WoodruffFamilyPush.entitlements ;;
      basic) ents=App/iOS/WoodruffFamilyBasic.entitlements ;;
    esac
    log="$LOGDIR/iphone-build-$variant.log"
    xcodebuild -project WoodruffFamily.xcodeproj -scheme WoodruffFamily -destination 'generic/platform=iOS' \
      -configuration Release -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" \
      WOODRUFF_BUNDLE_ID="$IPHONE_BUNDLE_ID" "${sign[@]}" \
      WOODRUFF_ENTITLEMENTS="$ents" WOODRUFF_WIDGET_ENTITLEMENTS= \
      ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} build </dev/null >"$log" 2>&1
    status=$?
    show_build "$log"
  done
  if [ "$XCODE_SIGNING" -eq 1 ] && ! build_succeeded "$status" "$log" "$product" && [ -z "$IPHONE_FALLBACK" ]; then
    # Xcode couldn't sign (no Apple account in Xcode > Settings > Accounts, or its profiles lack something): sign
    # with this Mac's own certificate and profiles instead, so the iPhones still update.
    hints "$log"
    if grep -q 'No Accounts' "$log" 2>/dev/null; then
      warn "Xcode isn't signed in to an Apple account on this Mac (Xcode > Settings > Accounts), so it can't sign the"
      warn "iPhone app by itself; signing it with this Mac's own certificate and profiles instead."
    else
      warn "Xcode couldn't sign the iPhone app; signing it with this Mac's own certificate and profiles instead."
    fi
    IPHONE_FALLBACK=1
    XCODE_SIGNING=0
    deploy_iphone
    status=$?
    XCODE_SIGNING=1
    IPHONE_FALLBACK=""
    return "$status"
  fi
  if ! build_succeeded "$status" "$log" "$product"; then
    hints "$log"
    problem "the iPhone app didn't build"
    note "iPhone: NOT installed: the build failed (log $log)"
    result iphone-build failed "" "the iPhone app didn't build (log $log)"
    return 1
  fi

  if [ "$XCODE_SIGNING" -eq 1 ]; then
    copy=$product   # Xcode signed it already
  else
    step "iPhone: signing a copy"
    WORK=$(mktemp -d "$TMPROOT/woodruff-iphone.XXXXXX") || WORK=""
    if [ -z "$WORK" ]; then
      iphone_failed "couldn't make a temporary folder in $TMPROOT"
      return 1
    fi
    copy="$WORK/$APP_NAME.app"
    appex="$copy/PlugIns/WoodruffWidgets.appex"
    slog="$LOGDIR/iphone-sign.log"
    if ! ditto "$product" "$copy" </dev/null >>"$slog" 2>&1; then
      iphone_failed "copying the build to $WORK failed" "$slog"
      return 1
    fi
    bid=$(signing bundle-id "$copy" 2>>"$slog")
    if [ "$bid" != "$IPHONE_BUNDLE_ID" ]; then
      iphone_failed "the built app is '$bid', not $IPHONE_BUNDLE_ID"
      return 1
    fi
    if [ ! -d "$appex" ]; then
      iphone_failed "the built app has no PlugIns/WoodruffWidgets.appex"
      return 1
    fi
    bid=$(signing bundle-id "$appex" 2>>"$slog")
    if [ "$bid" != "$IPHONE_WIDGETS_ID" ]; then
      iphone_failed "the built widgets are '$bid', not $IPHONE_WIDGETS_ID"
      return 1
    fi
    for item in "$copy/PlugIns/"*; do
      if [ -e "$item" ] && [ "$item" != "$appex" ]; then
        iphone_failed "the built app has PlugIns/$(basename "$item"), which no profile here can sign"
        return 1
      fi
    done
    say "    $IPHONE_BUNDLE_ID with $IPHONE_WIDGETS_ID"

    if ! signing entitlements --profile "$app_profile" --kind app --bundle-id "$IPHONE_BUNDLE_ID" \
      --out "$WORK/APP.plist" 2>>"$slog"; then
      iphone_failed "the app's entitlements aren't allowed by profile $app_uuid" "$slog"
      return 1
    fi
    if ! signing entitlements --profile "$widgets_profile" --kind widget --bundle-id "$IPHONE_WIDGETS_ID" \
      --out "$WORK/WIDGET.plist" 2>>"$slog"; then
      iphone_failed "the widgets' entitlements aren't allowed by profile $widgets_uuid" "$slog"
      return 1
    fi
    # Copies of the profiles go into the signed copy; the profile folders are only read.
    if ! cp "$widgets_profile" "$appex/embedded.mobileprovision" 2>>"$slog" ||
      ! cp "$app_profile" "$copy/embedded.mobileprovision" 2>>"$slog"; then
      iphone_failed "couldn't copy the profiles into the app" "$slog"
      return 1
    fi
    if ! sign_frameworks "$appex" "$identity" "$slog" || ! sign_frameworks "$copy" "$identity" "$slog"; then
      iphone_failed "signing the frameworks failed" "$slog"
      return 1
    fi
    if ! codesign --force --sign "$identity" --entitlements "$WORK/WIDGET.plist" --generate-entitlement-der \
      --timestamp=none "$appex" </dev/null >>"$slog" 2>&1; then
      iphone_failed "signing WoodruffWidgets.appex failed" "$slog"
      return 1
    fi
    if ! codesign --force --sign "$identity" --entitlements "$WORK/APP.plist" --generate-entitlement-der \
      --timestamp=none "$copy" </dev/null >>"$slog" 2>&1; then
      iphone_failed "signing the app failed" "$slog"
      return 1
    fi
  fi
  vlog="$LOGDIR/iphone-verify.log"
  if ! codesign --verify --deep --strict --verbose=2 "$copy" </dev/null >"$vlog" 2>&1; then
    iphone_failed "the signed app doesn't verify" "$vlog"
    return 1
  fi
  say "    signed and verified"
  kept=""
  if [ -n "$KEEP_IPHONE" ]; then
    if keep_iphone "$copy" "$identity" "$app_uuid" "$app_expires" "$devs" "${targets[@]}"; then
      kept=", kept in $KEEP_IPHONE"
    else
      kept=", but couldn't be kept in $KEEP_IPHONE"
    fi
  fi
  result iphone-build ok "" "signed by $identity ($identity_name), app profile $app_uuid (expires ${app_expires%%T*})$kept"

  step "iPhone: installing"
  for udid in "${targets[@]}"; do
    name=$(device_name "$udid")
    ilog="$LOGDIR/iphone-install-$udid.log"
    llog="$LOGDIR/iphone-launch-$udid.log"
    say "    $name ($udid): installing"
    if ! xcrun devicectl device install app --device "$udid" --timeout 300 "$copy" </dev/null >"$ilog" 2>&1; then
      problem "$name: the install failed:"
      show_matches '[Ee]rror|[Ff]ailed|[Uu]nable|[Dd]enied|[Ll]ocked|[Tt]imed out|[Dd]eveloper [Mm]ode|not paired|not available' "$ilog" 12
      hints "$ilog"
      note "iPhone: NOT installed on $name ($udid): the install failed (log $ilog)"
      why=$(grep -E -m 1 '[Ee]rror|[Ff]ailed|[Uu]nable|[Dd]enied|[Ll]ocked|[Tt]imed out|[Dd]eveloper [Mm]ode|not paired|not available' "$ilog" 2>/dev/null | sed 's/^[[:space:]]*//')
      result iphone failed "$udid" "$name: the install failed${why:+: $why} (log $ilog)"
      continue
    fi
    installed=$((installed + 1))
    if [ "$LAUNCH_IPHONE" -eq 0 ]; then
      say "    $name: installed"
      note "iPhone: installed on $name ($udid)"
      result iphone installed "$udid" "$name: installed"
    elif xcrun devicectl device process launch --device "$udid" --timeout 45 "$IPHONE_BUNDLE_ID" \
      </dev/null >"$llog" 2>&1; then
      say "    $name: installed and opened"
      note "iPhone: installed on $name ($udid) and opened it"
      result iphone installed "$udid" "$name: installed and opened"
    elif grep -qi 'lock' "$llog"; then
      warn "$name: installed, but it's locked so the app didn't open"
      note "iPhone: installed on $name ($udid) (locked, so not opened)"
      result iphone installed "$udid" "$name: installed (locked, so not opened)"
    else
      problem "$name: installed, but the app didn't open:"
      show_matches '[Ee]rror|[Ff]ailed|[Uu]nable|[Dd]enied|[Tt]rust|[Tt]imed out' "$llog" 8
      note "iPhone: installed on $name ($udid), but it DIDN'T OPEN (log $llog)"
      result iphone installed "$udid" "$name: installed, but it didn't open (log $llog)"
    fi
  done
  note "     signed by $identity ($identity_name), certificate $(valid_until "$cert_expires")"
  note "     app profile $app_uuid (expires ${app_expires%%T*}), widgets profile $widgets_uuid (expires ${widgets_expires%%T*})"
  [ "$installed" -gt 0 ]
}

# ------------------------------------------------------------------------------------------------------ main

main() {
  local parts="" missing="" tool dir ids_before ids_after line self_sum="" opt value
  local -a pass_args
  pass_args=()   # the arguments again, paths made absolute, for running an updated deploy.sh

  while [ $# -gt 0 ]; do
    opt=$1
    value=""
    case "$opt" in
      --expect | --branch | --wait | --keep-iphone | --results)
        if [ $# -lt 2 ]; then
          say "$opt needs a value"
          usage
          return 2
        fi
        value=$2
        shift 2
        ;;
      --expect=* | --branch=* | --wait=* | --keep-iphone=* | --results=*)
        value=${opt#*=}
        opt=${opt%%=*}
        shift
        ;;
      *) shift ;;
    esac
    case "$opt" in
      --expect) EXPECT=$value ;;
      --branch) BRANCH=$value; DETACH=1 ;;
      --wait) SHARE_WAIT=$value ;;
      --keep-iphone)
        if [ -z "$value" ]; then say "--keep-iphone wants a folder"; return 2; fi
        KEEP_IPHONE=$(absolute "$value")
        value=$KEEP_IPHONE
        ;;
      --results)
        if [ -z "$value" ]; then say "--results wants a file"; return 2; fi
        RESULTS=$(absolute "$value")
        value=$RESULTS
        ;;
      --no-launch) LAUNCH_IPHONE=0 ;;
      --xcode-signing) XCODE_SIGNING=1 ;;
      mac) DO_MAC=1 ;;
      share) DO_SHARE=1 ;;
      mac-shared) DO_MAC_SHARED=1 ;;
      iphone | iphones) DO_IPHONE=1 ;;
      -h | --help) usage; return 0 ;;
      *) say "Unknown argument: $opt"; usage; return 2 ;;
    esac
    case "$opt" in
      --expect | --branch | --wait | --keep-iphone | --results) pass_args+=("$opt" "$value") ;;
      *) pass_args+=("$opt") ;;
    esac
  done
  if [ "$DO_MAC" -eq 1 ] && [ "$DO_MAC_SHARED" -eq 1 ]; then
    say "mac (build here) and mac-shared (install another Mac's build) both install the Mac app: pick one"
    usage
    return 2
  fi
  if [ "$DO_MAC" -eq 0 ] && [ "$DO_IPHONE" -eq 0 ] && [ "$DO_MAC_SHARED" -eq 0 ] && [ "$DO_SHARE" -eq 0 ]; then
    DO_MAC=1
  fi
  if [ -n "$EXPECT" ]; then
    case "$EXPECT" in
      *[!0-9a-fA-F]*) say "--expect wants a commit hash, not '$EXPECT'"; return 2 ;;
    esac
    if [ "${#EXPECT}" -lt 4 ]; then
      say "--expect wants at least 4 characters of the commit hash"
      return 2
    fi
  fi
  if [ "$DETACH" -eq 1 ]; then
    case "$BRANCH" in
      '' | -* | /* | */ | *..* | *//* | *.lock | *[!A-Za-z0-9._/-]*)
        say "--branch wants a branch name, not '$BRANCH'"
        return 2
        ;;
    esac
    BRANCH_OPT="--branch $BRANCH "
  fi
  case "$SHARE_WAIT" in
    '' | *[!0-9]*) say "--wait wants a number of seconds, not '$SHARE_WAIT'"; return 2 ;;
  esac
  SHARE_WAIT=$((10#$SHARE_WAIT))
  if [ -n "$RESULTS" ] && ! : >>"$RESULTS" 2>/dev/null; then
    say "Can't write to --results $RESULTS"
    return 2
  fi
  [ "$DO_MAC" -eq 1 ] && parts="Mac"
  [ "$DO_SHARE" -eq 1 ] && parts="Mac (shared in iCloud Drive)"
  [ "$DO_MAC_SHARED" -eq 1 ] && parts="Mac (another Mac's shared build)"
  [ "$DO_IPHONE" -eq 1 ] && parts="${parts:+$parts and }iPhones"

  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  if [ -z "$ROOT" ] || [ ! -f "$ROOT/project.yml" ] || [ ! -f "$ROOT/scripts/signing.py" ]; then
    say "Can't find the Woodrufffamily repository around ${BASH_SOURCE[0]}"
    return 1
  fi
  if ! cd "$ROOT"; then
    say "Can't cd to $ROOT"
    return 1
  fi
  SIGNING="$ROOT/scripts/signing.py"
  self_sum=$(cksum <"$ROOT/scripts/deploy.sh" 2>/dev/null)

  # xcodegen (Homebrew) may be missing from PATH in a non-login shell.
  for dir in /opt/homebrew/bin /usr/local/bin; do
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) if [ -d "$dir" ]; then PATH="$PATH:$dir"; fi ;;
    esac
  done
  export PATH

  TMPROOT=${TMPDIR:-/tmp}
  TMPROOT=${TMPROOT%/}
  if [ -z "$TMPROOT" ] || [ ! -d "$TMPROOT" ]; then
    TMPROOT=/tmp
  fi
  LOGDIR=$(mktemp -d "$TMPROOT/woodruff-deploy.XXXXXX") || LOGDIR=""
  if [ -z "$LOGDIR" ]; then
    say "Can't make a temporary folder in $TMPROOT"
    return 1
  fi
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT
  trap 'cleanup; exit 143' TERM

  say "Woodruff Family deploy: $parts, from $BRANCH"
  say "Logs: $LOGDIR"
  ids_before=$(identity_count)
  say "Signing identities (security find-identity -v -p codesigning | tail -1): $ids_before"
  if [ -n "${WOODRUFF_DEPLOY_REEXEC:-}" ] && [ -n "${WOODRUFF_DEPLOY_IDS_BEFORE:-}" ]; then
    ids_before=$WOODRUFF_DEPLOY_IDS_BEFORE   # counted by the run that updated this script, before anything else
  fi

  for tool in git python3 xcodebuild security codesign ditto; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ "$DO_MAC" -eq 1 ] || [ "$DO_MAC_SHARED" -eq 1 ]; then
    for tool in osascript pgrep open; do
      command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
  fi
  if [ "$DO_IPHONE" -eq 1 ]; then
    command -v xcrun >/dev/null 2>&1 || missing="$missing xcrun"
  fi
  if [ -n "$missing" ]; then
    problem "this Mac is missing:$missing"
    nothing_built
  elif ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1; then
    problem "python3 is older than 3.7"
    nothing_built
  elif ! update_checkout "$EXPECT"; then
    nothing_built
  else
    # The pull may have brought a new deploy.sh, and this run would mix the old steps with the new signing.py:
    # run the new one instead (once; nothing has been built or installed yet).
    if [ -z "${WOODRUFF_DEPLOY_REEXEC:-}" ] && [ -n "$self_sum" ] &&
      [ "$(cksum <"$ROOT/scripts/deploy.sh" 2>/dev/null)" != "$self_sum" ]; then
      say "    scripts/deploy.sh changed in this update; running the new one"
      WOODRUFF_DEPLOY_REEXEC=1
      WOODRUFF_DEPLOY_IDS_BEFORE=$ids_before
      export WOODRUFF_DEPLOY_REEXEC WOODRUFF_DEPLOY_IDS_BEFORE
      shopt -s execfail
      exec "${BASH:-/bin/bash}" "$ROOT/scripts/deploy.sh" ${pass_args[@]+"${pass_args[@]}"}
      shopt -u execfail
      problem "couldn't run the updated scripts/deploy.sh; run it again"
      nothing_built
    elif [ "$DO_MAC" -eq 0 ] && [ "$DO_IPHONE" -eq 0 ]; then
      # Nothing to build here, so no xcodegen.
      if [ "$DO_MAC_SHARED" -eq 1 ]; then
        deploy_mac_shared
      fi
      if [ "$DO_SHARE" -eq 1 ]; then
        share_installed
      fi
    elif generate_project; then
      if [ "$DO_MAC" -eq 1 ]; then
        deploy_mac
        if [ "$DO_SHARE" -eq 1 ]; then
          share_mac
        fi
      elif [ "$DO_SHARE" -eq 1 ]; then
        share_installed
      fi
      if [ "$DO_MAC_SHARED" -eq 1 ]; then
        deploy_mac_shared
      fi
      if [ "$DO_IPHONE" -eq 1 ]; then
        deploy_iphone
        cleanup
      fi
    else
      nothing_built
    fi
  fi

  ids_after=$(identity_count)
  step "Summary"
  say "    commit: $HEAD_DESC"
  for line in ${SUMMARY[@]+"${SUMMARY[@]}"}; do
    say "    $line"
  done
  say "    signing identities before: $ids_before"
  say "    signing identities after:  $ids_after"
  say "    logs: $LOGDIR"
  if [ "$ids_after" != "$ids_before" ]; then
    FAILED=1
    say ""
    say "!!!!! THE SIGNING IDENTITIES CHANGED DURING THIS DEPLOY: \"$ids_before\" before, \"$ids_after\" now. !!!!!"
    say "!!!!! This script never touches certificates; look in Keychain Access and Xcode > Settings > Accounts. !!!!!"
  fi
  say ""
  if [ "$FAILED" -ne 0 ]; then
    say "Not everything worked: see PROBLEM above."
    return 1
  fi
  say "Done."
  return 0
}

# ${1+"$@"}: bash 3.2 with set -u can call an empty "$@" unbound (the default run has no arguments).
main ${1+"$@"}; exit $?
