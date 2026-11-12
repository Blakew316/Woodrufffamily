#!/bin/bash
# Checks a built Apple TV app: the DTS and Dolby TrueHD decoder (FilmSound.framework) is in it where the app looks
# for it, linked weakly (the app must start without it too), and used by the app's code. CI runs it on the apps it
# builds; nothing on the family's Macs does.
#
#   scripts/check_filmsound.sh "<path to Woodruff Family.app>"
set -euo pipefail

app="${1:?the built app}"
fw="$app/Frameworks/FilmSound.framework/FilmSound"
if [ ! -f "$fw" ]; then
  echo "FilmSound.framework isn't in $app"
  exit 1
fi
echo "FilmSound in the app: $(lipo -archs "$fw")"

loads=""
wanted=""
for f in "$app"/*; do
  if [ -f "$f" ] && file "$f" | grep "Mach-O" >/dev/null; then
    loads="$loads$(otool -l "$f")
"
    wanted="$wanted$(nm -u "$f" 2>/dev/null || true)
"
  fi
done

has() {  # $1 = the load command, $2 = what one of them must name
  grep -A2 "cmd $1\$" <<<"$loads" | grep "$2" >/dev/null
}

if ! has LC_LOAD_WEAK_DYLIB "FilmSound.framework/FilmSound"; then
  echo "The app doesn't link FilmSound weakly."
  exit 1
fi
if has LC_LOAD_DYLIB "FilmSound.framework/FilmSound"; then
  echo "The app links FilmSound strongly: it couldn't start without it."
  exit 1
fi
if ! has LC_RPATH "@executable_path/Frameworks"; then
  echo "The app doesn't look in its own Frameworks folder."
  exit 1
fi
if ! grep "_wfsound_decode" <<<"$wanted" >/dev/null; then
  echo "The app's code doesn't use the decoder (was the FilmSound module found when it was compiled?)."
  exit 1
fi
echo "The decoder is in the app, linked weakly, and used by it."
