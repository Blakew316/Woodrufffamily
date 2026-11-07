#!/bin/bash
# Puts Google's WebRTC library (prebuilt by github.com/stasel/WebRTC) in Packages/WebRTC/WebRTC.xcframework, once:
# a download with time limits and retries, checked against its known SHA-256. Run before xcodegen (deploy.sh and CI
# do). Exits non-zero with a plain message when it can't, so a build fails at once instead of hanging.
# macOS /bin/bash 3.2.
set -u
VERSION="157.0.0"
URL="https://github.com/stasel/WebRTC/releases/download/$VERSION/WebRTC-M157.xcframework.zip"
SHA256="ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328"

here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$here/Packages/WebRTC"
stamp="$dest/.fetched"
if [ -d "$dest/WebRTC.xcframework" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$SHA256" ]; then
  echo "WebRTC $VERSION already here"
  exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/webrtc.XXXXXX")" || { echo "WebRTC: no temporary folder"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
zip="$tmp/WebRTC.zip"
ok=0
for try in 1 2 3 4; do
  # Gives up on a stalled download (under 10 KB/s for a minute) rather than waiting forever.
  if curl -fsSL --connect-timeout 20 --max-time 900 --speed-limit 10240 --speed-time 60 -o "$zip" "$URL"; then
    ok=1
    break
  fi
  echo "WebRTC: download try $try failed"
  sleep $((try * 5))
done
if [ "$ok" != 1 ]; then
  echo "WebRTC: couldn't download $URL after 4 tries"
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  got="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
else
  got="$(sha256sum "$zip" | cut -d' ' -f1)"
fi
if [ "$got" != "$SHA256" ]; then
  echo "WebRTC: the download isn't the expected file (SHA-256 $got), so it wasn't used"
  exit 1
fi

if command -v ditto >/dev/null 2>&1; then
  ditto -x -k "$zip" "$tmp/out" || { echo "WebRTC: couldn't unzip it"; exit 1; }
else
  mkdir -p "$tmp/out" && unzip -q "$zip" -d "$tmp/out" || { echo "WebRTC: couldn't unzip it"; exit 1; }
fi
if [ ! -d "$tmp/out/WebRTC.xcframework" ]; then
  echo "WebRTC: the download has no WebRTC.xcframework"
  exit 1
fi
rm -rf "$dest/WebRTC.xcframework"
mv "$tmp/out/WebRTC.xcframework" "$dest/WebRTC.xcframework" || { echo "WebRTC: couldn't move it into place"; exit 1; }
echo "$SHA256" > "$stamp"
echo "WebRTC $VERSION downloaded"
