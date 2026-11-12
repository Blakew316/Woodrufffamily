#!/bin/bash
# Builds Packages/FilmSound/FilmSound.xcframework: FFmpeg's decoders for the sound the Apple TV has none for (DTS,
# DTS-HD, Dolby TrueHD, MLP) behind Packages/FilmSound/Sources/wfsound.h, for the Apple TV and its simulator.
# Only those decoders and FFmpeg's sample converter are built in (LGPL 2.1 or later: no GPL parts, nothing else).
#
# Run on a Mac with Xcode. GitHub runs it (.github/workflows/filmsound.yml) whenever this script or the sources
# change and keeps what it built on the branch filmsound-build; the framework the app is built with is the copy
# of that in this folder. deploy.sh never runs this. Before anything is built for the Apple TV, the same code is
# built for this Mac and checked: a tone in every channel must come out of the channel wfsound.h says
# (Packages/FilmSound/Tests/selftest.c).
set -euo pipefail

FFMPEG_VERSION="7.1.5"
# The source archive from ffmpeg.org. Any other file is refused.
FFMPEG_SHA256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
MIN_TVOS="17.0"
MIN_MACOS="13.0"

here="$(cd "$(dirname "$0")/.." && pwd)"
pkg="$here/Packages/FilmSound"
work="${FILMSOUND_WORK:-$here/build/filmsound}"
jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
url="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

# What FFmpeg is built with, the same for every platform (written into BUILD-INFO.txt beside the framework).
common=(--disable-everything --disable-programs --disable-doc --disable-autodetect --disable-network
        --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale
        --enable-avcodec --enable-swresample
        --enable-decoder=dca --enable-decoder=truehd --enable-decoder=mlp
        --disable-asm --enable-pic --enable-static --disable-shared --disable-debug)

mkdir -p "$work"
tarball="$work/ffmpeg-$FFMPEG_VERSION.tar.xz"
if [ ! -f "$tarball" ]; then
  curl -fsSL --connect-timeout 20 --max-time 900 --retry 3 -o "$tarball" "$url"
fi
got="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
echo "FFmpeg $FFMPEG_VERSION source: SHA-256 $got"
if [ "$got" != "$FFMPEG_SHA256" ]; then
  echo "That isn't the expected file ($FFMPEG_SHA256), so nothing was built."
  rm -f "$tarball"
  exit 1
fi
rm -rf "$work/src"
mkdir -p "$work/src"
tar -xJf "$tarball" -C "$work/src" --strip-components 1

# ffmpeg_for <name> <sdk> <arch> <minimum-version flag> [more configure flags…]: FFmpeg's libraries for one
# platform, in $work/<name>/prefix.
ffmpeg_for() {
  local name="$1" sdk="$2" arch="$3" min="$4"
  shift 4
  local dir="$work/$name" sysroot cc flags
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  flags="-arch $arch -isysroot $sysroot $min"
  rm -rf "$dir"
  mkdir -p "$dir/obj"
  echo "FFmpeg for $name ($sdk, $arch)…"
  if ! ( cd "$dir/obj" && "$work/src/configure" --prefix="$dir/prefix" --enable-cross-compile --target-os=darwin \
           --arch="$arch" --cc="$cc" --extra-cflags="$flags" --extra-ldflags="$flags" "${common[@]}" "$@" \
           > "$dir/configure.log" 2>&1 ); then
    echo "FFmpeg for $name: configure failed"
    tail -30 "$dir/configure.log"
    tail -60 "$dir/obj/ffbuild/config.log" 2>/dev/null || true
    exit 1
  fi
  grep -E "^License:" "$dir/configure.log" || true
  if ! ( cd "$dir/obj" && make -j"$jobs" > "$dir/make.log" 2>&1 && make install >> "$dir/make.log" 2>&1 ); then
    echo "FFmpeg for $name: the build failed"
    tail -60 "$dir/make.log"
    exit 1
  fi
}

# What FFmpeg's libraries ask to be linked with besides themselves (from the notes it installs beside them).
others_of() {
  local dir="$1"
  sed -n 's/^Libs: *//p; s/^Libs\.private: *//p' "$dir/prefix/lib/pkgconfig/libavcodec.pc" \
      "$dir/prefix/lib/pkgconfig/libswresample.pc" "$dir/prefix/lib/pkgconfig/libavutil.pc" \
    | tr ' ' '\n' | grep -v -e '^-L' -e '^-lav' -e '^-lsw' -e '^$' | tr '\n' ' '
}

# binary_for <name> <sdk> <arch> <minimum-version flag>: wfsound and FFmpeg's libraries (built by ffmpeg_for
# <name>) as one dynamic library, $work/<name>/FilmSound, showing only wfsound's own functions.
binary_for() {
  local name="$1" sdk="$2" arch="$3" min="$4"
  local dir="$work/$name" sysroot cc others
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" -f clang)"
  others="$(others_of "$dir")"
  # shellcheck disable=SC2086
  "$cc" -arch "$arch" -isysroot "$sysroot" $min -O2 -fPIC -dynamiclib \
    -install_name @rpath/FilmSound.framework/FilmSound \
    -Wl,-exported_symbols_list,"$work/exports.txt" -Wl,-dead_strip \
    -I"$dir/prefix/include" "$pkg/Sources/wfsound.c" \
    "$dir/prefix/lib/libavcodec.a" "$dir/prefix/lib/libswresample.a" "$dir/prefix/lib/libavutil.a" \
    $others -o "$dir/FilmSound"
  strip -x "$dir/FilmSound"
}

# framework_of <folder> <platform name> <binary>…: FilmSound.framework in <folder>, from the binaries of one
# platform (one for each processor).
framework_of() {
  local out="$1" platform="$2"
  shift 2
  local fw="$out/FilmSound.framework"
  rm -rf "$fw"
  mkdir -p "$fw/Headers" "$fw/Modules"
  lipo -create "$@" -output "$fw/FilmSound"
  cp "$pkg/Sources/wfsound.h" "$fw/Headers/wfsound.h"
  printf 'framework module FilmSound {\n    header "wfsound.h"\n    export *\n}\n' > "$fw/Modules/module.modulemap"
  cp "$work/src/COPYING.LGPLv2.1" "$fw/COPYING.LGPLv2.1"
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>FilmSound</string>
  <key>CFBundleIdentifier</key><string>com.blakew316.woodruff.filmsound</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>FilmSound</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$FFMPEG_VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>$MIN_TVOS</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict>
</plist>
PLIST
  plutil -lint "$fw/Info.plist"
  echo "FilmSound for $platform: $(du -k "$fw/FilmSound" | cut -f1) KB, $(lipo -archs "$fw/FilmSound")"
  # Only wfsound's own functions may show.
  local shown
  shown="$(nm -gU "$fw/FilmSound" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
  echo "  shows: $shown"
  if [ "$shown" != "_wfsound_about _wfsound_close _wfsound_decode _wfsound_flush _wfsound_open " ]; then
    echo "  That isn't wfsound's five functions and nothing else, so nothing was kept."
    exit 1
  fi
}

printf '_wfsound_open\n_wfsound_decode\n_wfsound_flush\n_wfsound_close\n_wfsound_about\n' > "$work/exports.txt"

# 1. On this Mac, with FFmpeg's own DTS and TrueHD encoders beside the decoders: every channel is checked.
host="$(uname -m)"
ffmpeg_for host macosx "$host" "-mmacosx-version-min=$MIN_MACOS" \
  --enable-encoder=dca --enable-encoder=truehd --enable-decoder=pcm_s16le
# shellcheck disable=SC2046
"$(xcrun --sdk macosx -f clang)" -arch "$host" -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  "-mmacosx-version-min=$MIN_MACOS" -O2 -Wall -DWFSOUND_SELFTEST -Wno-deprecated-declarations \
  -I"$work/host/prefix/include" -I"$pkg/Sources" "$pkg/Sources/wfsound.c" "$pkg/Tests/selftest.c" \
  "$work/host/prefix/lib/libavcodec.a" "$work/host/prefix/lib/libswresample.a" "$work/host/prefix/lib/libavutil.a" \
  $(others_of "$work/host") -o "$work/host/selftest"
echo "Checking the channels…"
"$work/host/selftest"

# 2. For the Apple TV and its simulator (both kinds of Mac), the decoders alone.
ffmpeg_for tvos appletvos arm64 "-mtvos-version-min=$MIN_TVOS"
binary_for tvos appletvos arm64 "-mtvos-version-min=$MIN_TVOS"
ffmpeg_for tvsim-arm64 appletvsimulator arm64 "-mtvos-simulator-version-min=$MIN_TVOS"
binary_for tvsim-arm64 appletvsimulator arm64 "-mtvos-simulator-version-min=$MIN_TVOS"
ffmpeg_for tvsim-x86_64 appletvsimulator x86_64 "-mtvos-simulator-version-min=$MIN_TVOS"
binary_for tvsim-x86_64 appletvsimulator x86_64 "-mtvos-simulator-version-min=$MIN_TVOS"

mkdir -p "$work/out-tvos" "$work/out-tvsim"
framework_of "$work/out-tvos" AppleTVOS "$work/tvos/FilmSound"
framework_of "$work/out-tvsim" AppleTVSimulator "$work/tvsim-arm64/FilmSound" "$work/tvsim-x86_64/FilmSound"
otool -l "$work/out-tvos/FilmSound.framework/FilmSound" | grep -A4 LC_BUILD_VERSION | grep -E "platform|minos" || true
otool -L "$work/out-tvos/FilmSound.framework/FilmSound"

rm -rf "$pkg/FilmSound.xcframework"
xcodebuild -create-xcframework -framework "$work/out-tvos/FilmSound.framework" \
  -framework "$work/out-tvsim/FilmSound.framework" -output "$pkg/FilmSound.xcframework"

# What it was built from, kept beside it (the LGPL asks that the source and how it was built be told).
cp "$work/src/COPYING.LGPLv2.1" "$pkg/COPYING.LGPLv2.1"
{
  echo "FilmSound.xcframework: wfsound (Packages/FilmSound/Sources) with FFmpeg's DTS, Dolby TrueHD and MLP decoders."
  echo "FFmpeg $FFMPEG_VERSION, licensed under the GNU Lesser General Public License, version 2.1 or later"
  echo "(COPYING.LGPLv2.1 beside this file). wfsound is under the same licence."
  echo "Source: $url"
  echo "SHA-256: $got"
  echo "Built by scripts/build_filmsound.sh, FFmpeg configured with:"
  echo "  ${common[*]}"
} > "$pkg/BUILD-INFO.txt"
cat "$pkg/BUILD-INFO.txt"
find "$pkg/FilmSound.xcframework" -type f | sort
du -sh "$pkg/FilmSound.xcframework"
