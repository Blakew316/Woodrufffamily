#!/bin/bash
#
# Deploy Woodruff Family to this Mac and/or the iPhones paired with it, signed with what's already here.
#
#   scripts/deploy.sh [--expect <commit>] [mac] [iphone]          (no part named: mac)
#
#   mac      Build the Mac app signed with this Mac's own "Apple Development" identity (it needs no profile),
#            quit the running Woodruff Family, copy the new one over /Applications/Woodruff Family.app,
#            check its signature and open it.
#   iphone   Build the iPhone app unsigned, sign a copy with codesign and the provisioning profiles Xcode
#            already made on this Mac, and install it on every iPhone paired with this Mac.
#   --expect <commit>   Stop before building unless the checkout is that commit (a prefix is enough).
#
# First it updates the checkout (git fetch, checkout claude/native-apps, pull --ff-only; if that brought a new
# deploy.sh, it runs the new one) and runs xcodegen.
#
# It never runs -allowProvisioningUpdates or -authenticationKey*, never contacts Apple's developer services,
# never asks for an Apple ID (or anything else), and never creates, imports, revokes, deletes or changes a
# certificate, key, profile, keychain or keychain search list. When the iPhone profiles or a signing certificate
# expire (or a certificate is revoked) it says so and skips what can't be signed; only then does someone need to
# sign in to Xcode once on this Mac. It warns 30 days ahead.
#
# It deletes nothing but its own temporary folder and, at most once, a stale generated
# build/Build/Products/Release/Woodruff Family.app. Logs stay in a temporary folder named at the end.
# The exit status is 0 only if everything asked for worked; iPhone problems never stop the Mac part.
#
# Written for macOS's /bin/bash 3.2: no associative arrays, mapfile, ${x,,}, &>> or wait -n.

set -u
unset CDPATH   # an exported CDPATH would make `cd scripts/..` print the folder and spoil ROOT

TEAM="D8D94SXAG6"
BRANCH="claude/native-apps"
IPHONE_BUNDLE_ID="com.blakew316.woodruff"          # always this id on the iPhones
IPHONE_WIDGETS_ID="com.blakew316.woodruff.widgets"
MAC_BUNDLE_ID="com.woodruff.family.mac"
HOMEKIT="com.apple.developer.homekit"
APP_NAME="Woodruff Family"
MAC_INSTALLED="/Applications/Woodruff Family.app"

ROOT=""
SIGNING=""
TMPROOT=""
LOGDIR=""
WORK=""
FAILED=0
HEAD_DESC="(not updated)"
SUMMARY=()
IPHONE_UDIDS=()
IPHONE_NAMES=()

say()     { printf '%s\n' "$*"; }
step()    { printf '\n==> %s\n' "$*"; }
warn()    { printf 'WARNING: %s\n' "$*"; }
problem() { FAILED=1; printf 'PROBLEM: %s\n' "$*"; }
note()    { SUMMARY+=("$*"); }
indent()  { sed 's/^/    /'; }
signing() { python3 -I "$SIGNING" "$@"; }

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [--expect <commit>] [mac] [iphone]      (no part named: mac)
  mac                 build, sign and install the Mac app in /Applications on this Mac
  iphone              build, sign and install the iPhone app on every iPhone paired with this Mac
  --expect <commit>   stop before building unless the checkout is at that commit (a prefix is enough)
It uses only the certificates and profiles already on this Mac; it never asks for an Apple ID.
EOF
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
  if grep -qi 'developer mode' "$1"; then
    say "    hint: turn on Developer Mode on the iPhone (Settings > Privacy & Security > Developer Mode)."
  fi
}

# A build or verify that failed because WoodruffMacWidgets.appex inside the generated app has a stale signature.
stale_widget_signature() {
  grep -E -B 3 -A 3 'code object is not signed at all|a sealed resource is missing or invalid|invalid signature' \
    "$1" 2>/dev/null | grep -q 'WoodruffMacWidgets\.appex'
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
  local log="$LOGDIR/git.log" head head_lc expect_lc
  step "Updating the checkout to the newest $BRANCH"
  export GIT_TERMINAL_PROMPT=0
  if [ -z "${GIT_SSH_COMMAND:-}" ] && [ -z "${GIT_SSH:-}" ] && [ -z "$(git config --get core.sshCommand 2>/dev/null)" ]; then
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes"   # never a passphrase or host-key prompt
  fi
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
  head=$(git rev-parse HEAD 2>/dev/null)
  HEAD_DESC=$(git log -1 --format='%h %s' 2>/dev/null)
  say "    at $HEAD_DESC"
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

mac_failed() {  # $1 = what happened, $2 = a log to look at (optional)
  problem "$1"
  if [ -n "${2:-}" ]; then hints "$2"; fi
  note "Mac: NOT installed: $1"
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
  local identity name why cert_expires cert_days attempt=1 log vlog status built waited bid ilog verified=1 running=0

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

  while :; do
    log="$LOGDIR/mac-build-$attempt.log"
    step "Mac: building (Release)"
    xcodebuild -project WoodruffFamily.xcodeproj -scheme WoodruffFamilyMac -destination 'platform=macOS' \
      -configuration Release -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="$identity" "PROVISIONING_PROFILE_SPECIFIER=" build </dev/null >"$log" 2>&1
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
    mac_failed "the Mac app didn't build or verify (log $log); $MAC_INSTALLED wasn't touched" "$log"
    return 1
  done

  bid=$(signing bundle-id "$product" 2>/dev/null)
  if [ "$bid" != "$MAC_BUNDLE_ID" ]; then
    mac_failed "the new build is '$bid', not $MAC_BUNDLE_ID; $MAC_INSTALLED wasn't touched"
    return 1
  fi

  # Only now, with a verified new build, is the installed app quit and replaced.
  step "Mac: installing"
  ilog="$LOGDIR/mac-install.log"
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    say "    quitting the running $APP_NAME"
    osascript -e 'quit app "Woodruff Family"' </dev/null >>"$ilog" 2>&1
    waited=0
    while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
      if [ "$waited" -ge 15 ]; then
        mac_failed "$APP_NAME didn't quit within 15 seconds, so it wasn't replaced (the new build is $product)"
        return 1
      fi
      sleep 1
      waited=$((waited + 1))
    done
  fi
  if ! ditto "$product" "$MAC_INSTALLED" </dev/null >>"$ilog" 2>&1; then
    tail -n 5 "$ilog" | indent
    mac_failed "copying the new build to $MAC_INSTALLED failed, so it may be incomplete (the new build is $product)"
    return 1
  fi
  vlog="$LOGDIR/mac-verify-installed.log"
  if codesign --verify --deep --strict --verbose=2 "$MAC_INSTALLED" </dev/null >"$vlog" 2>&1; then
    say "    $MAC_INSTALLED verifies"
  else
    verified=0
    problem "$MAC_INSTALLED doesn't verify after copying:"
    show_matches '.' "$vlog" 12
    say "    (\"file added\" means files from the old version are still inside it: drag $product"
    say "    into Applications and choose Replace)"
  fi
  if ! open "$MAC_INSTALLED" </dev/null >>"$ilog" 2>&1; then
    tail -n 3 "$ilog" | indent
  fi
  waited=0
  while [ "$waited" -lt 20 ]; do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
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
    note "Mac: installed $MAC_INSTALLED and it's running"
  elif [ "$verified" -eq 1 ]; then
    note "Mac: installed $MAC_INSTALLED, but it DIDN'T START"
  else
    note "Mac: installed $MAC_INSTALLED, but its signature DOESN'T VERIFY (log $vlog)"
  fi
  note "     signed by $identity ($name), certificate $(valid_until "$cert_expires")"
  return 0
}

# ---------------------------------------------------------------------------------------------- the iPhones

iphone_failed() {  # $1 = what happened, $2 = a log to show the end of (optional)
  problem "$1"
  if [ -n "${2:-}" ] && [ -f "$2" ]; then
    tail -n 8 "$2" | indent
    hints "$2"
  fi
  note "iPhone: NOT installed: $1"
  return 1
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
  local -a targets usable
  local udid name i status identity identity_name cert_expires cert_days app_profile app_uuid app_expires app_days
  local widgets_profile widgets_uuid widgets_expires widgets_days log product copy appex slog vlog
  local bid item ilog llog installed=0

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
    iphone_failed "no iPhone is paired with this Mac (xcrun devicectl list devices shows none)"
    return 1
  fi
  i=0
  while [ "$i" -lt "${#IPHONE_UDIDS[@]}" ]; do
    say "    ${IPHONE_NAMES[$i]:-?}  ${IPHONE_UDIDS[$i]}"
    i=$((i + 1))
  done
  targets=("${IPHONE_UDIDS[@]}")

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
      return 1
    fi
    for udid in "${IPHONE_UDIDS[@]}"; do
      case " ${usable[*]} " in
        *" $udid "*) ;;
        *) note "iPhone: NOT installed on $(device_name "$udid") ($udid): the provisioning profiles don't list it" ;;
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

  step "iPhone: building (Release, unsigned)"
  log="$LOGDIR/iphone-build.log"
  product="$ROOT/build/Build/Products/Release-iphoneos/$APP_NAME.app"
  xcodebuild -project WoodruffFamily.xcodeproj -scheme WoodruffFamily -destination 'generic/platform=iOS' \
    -configuration Release -derivedDataPath build DEVELOPMENT_TEAM="$TEAM" \
    WOODRUFF_BUNDLE_ID="$IPHONE_BUNDLE_ID" CODE_SIGNING_ALLOWED=NO build </dev/null >"$log" 2>&1
  status=$?
  show_build "$log"
  if ! build_succeeded "$status" "$log" "$product"; then
    hints "$log"
    problem "the iPhone app didn't build"
    note "iPhone: NOT installed: the build failed (log $log)"
    return 1
  fi

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
  vlog="$LOGDIR/iphone-verify.log"
  if ! codesign --verify --deep --strict --verbose=2 "$copy" </dev/null >"$vlog" 2>&1; then
    iphone_failed "the signed app doesn't verify" "$vlog"
    return 1
  fi
  say "    signed and verified"

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
      continue
    fi
    installed=$((installed + 1))
    if xcrun devicectl device process launch --device "$udid" --timeout 45 "$IPHONE_BUNDLE_ID" \
      </dev/null >"$llog" 2>&1; then
      say "    $name: installed and opened"
      note "iPhone: installed on $name ($udid) and opened it"
    elif grep -qi 'lock' "$llog"; then
      warn "$name: installed, but it's locked so the app didn't open"
      note "iPhone: installed on $name ($udid) (locked, so not opened)"
    else
      problem "$name: installed, but the app didn't open:"
      show_matches '[Ee]rror|[Ff]ailed|[Uu]nable|[Dd]enied|[Tt]rust|[Tt]imed out' "$llog" 8
      note "iPhone: installed on $name ($udid), but it DIDN'T OPEN (log $llog)"
    fi
  done
  note "     signed by $identity ($identity_name), certificate $(valid_until "$cert_expires")"
  note "     app profile $app_uuid (expires ${app_expires%%T*}), widgets profile $widgets_uuid (expires ${widgets_expires%%T*})"
  [ "$installed" -gt 0 ]
}

# ------------------------------------------------------------------------------------------------------ main

main() {
  local do_mac=0 do_iphone=0 expect="" parts="" missing="" tool dir ids_before ids_after line self_sum=""
  local -a orig_args
  orig_args=(${1+"$@"})

  while [ $# -gt 0 ]; do
    case "$1" in
      --expect)
        if [ $# -lt 2 ]; then
          usage
          return 2
        fi
        expect=$2
        shift 2
        ;;
      --expect=*) expect=${1#--expect=}; shift ;;
      mac) do_mac=1; shift ;;
      iphone | iphones) do_iphone=1; shift ;;
      -h | --help) usage; return 0 ;;
      *) say "Unknown argument: $1"; usage; return 2 ;;
    esac
  done
  if [ "$do_mac" -eq 0 ] && [ "$do_iphone" -eq 0 ]; then
    do_mac=1
  fi
  if [ -n "$expect" ]; then
    case "$expect" in
      *[!0-9a-fA-F]*) say "--expect wants a commit hash, not '$expect'"; return 2 ;;
    esac
    if [ "${#expect}" -lt 4 ]; then
      say "--expect wants at least 4 characters of the commit hash"
      return 2
    fi
  fi
  [ "$do_mac" -eq 1 ] && parts="Mac"
  [ "$do_iphone" -eq 1 ] && parts="${parts:+$parts and }iPhones"

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
  if [ "$do_mac" -eq 1 ]; then
    for tool in osascript pgrep open; do
      command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
  fi
  if [ "$do_iphone" -eq 1 ]; then
    command -v xcrun >/dev/null 2>&1 || missing="$missing xcrun"
  fi
  if [ -n "$missing" ]; then
    problem "this Mac is missing:$missing"
    note "Nothing was built or installed."
  elif ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1; then
    problem "python3 is older than 3.7"
    note "Nothing was built or installed."
  elif ! update_checkout "$expect"; then
    note "Nothing was built or installed."
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
      exec "${BASH:-/bin/bash}" "$ROOT/scripts/deploy.sh" ${orig_args[@]+"${orig_args[@]}"}
      shopt -u execfail
      problem "couldn't run the updated scripts/deploy.sh; run it again"
      note "Nothing was built or installed."
    elif generate_project; then
      if [ "$do_mac" -eq 1 ]; then
        deploy_mac
      fi
      if [ "$do_iphone" -eq 1 ]; then
        deploy_iphone
        cleanup
      fi
    else
      note "Nothing was built or installed."
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
