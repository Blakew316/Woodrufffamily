# FilmHeights

The overhead sounds of Dolby TrueHD Atmos and DTS:X for the Apple TV's own film player (`FilmPlayer` in WoodruffKit,
`App/TV/TVFilmSound.swift`). What a film's packets come to here is 7.1 with four overhead channels (7.1.4), which the
Apple TV sends on as Dolby Atmos.

Nearly all of it is other people's work, used under their licences:

## From AetherEngine

`Sources/FilmHeights/Aether/`, the tests named after those files, and `Sources/FilmHeights/Resources/silent-atmos.mp4`
are from [AetherEngine](https://github.com/superuser404notfound/AetherEngine) (the owner's fork
`Blakew316/AetherEngine` at commit c37814874a1040626e9132b830b6426f6af2da42), Copyright (C) 2026 Vincent Herbst, under
the GNU Lesser General Public License v3 with its Apple Store / DRM Exception: `LICENSE-AetherEngine` here.

- Unchanged: `BedRegression`, `AllocentricPanner`, `SpatialSpeakerLayout`, `ObjectAudioPlacement`,
  `ObjectMetadataHold`, `PeakLimiter`, `ObjectAudioDecoding`, `TrueHDMajorSync`, `TrueHDObjectAudioDecoder`, and the
  tests (their `import` names this package).
- `AtmosOutputActivator`: without its extension on the engine's own players (the last 48 lines).
- AetherEngine keeps these parts behind package traits that are off by default; `Package.swift` here turns them on.

`HeightsCore`, `TrueHDHeights`, `DTSXHeights`, `HeightsOutputKeeper` and `EngineLog` are this app's: they stand where
AetherEngine's `SpatialAudioBridge` and `DTSXObjectAudioDecoder` do, for a player that hands over whole packets and
takes plain samples back. `DTSXHeights` keeps `DTSXObjectAudioDecoder`'s tables and rules. They are under the same
licence as the files they are built on.

## LibTrueHD

`TrueHD.xcframework` is from [LibTrueHD](https://github.com/superuser404notfound/LibTrueHD), commit
12b26e487a2ade918e53380d47f5727883fedafc (3.2.0): its Mac, Apple TV and Apple TV simulator libraries as that
repository ships them, nothing rebuilt. MIT, with Apache-2.0 parts compiled in (the `truehd` and `oamd` crates of
the truehdd project): `LICENSE-LibTrueHD`, `LICENSE-APACHE-LibTrueHD` and `NOTICE-LibTrueHD` here travel with it.

    21093e181027a0b5f29bac7fb8e9b85ca12c732d5214f6888bd084709c82c500  TrueHD.xcframework/macos-arm64_x86_64/libtruehd_atmos.a
    593f3101766d4b05b5482a59e589e45171ffa83de480fc81905592bd3bd2967a  TrueHD.xcframework/tvos-arm64-simulator/libtruehd_atmos.a
    563617c7c994c5f75ae5c7e211ae02e989ac0ff0340a017796a6d73a71a59916  TrueHD.xcframework/tvos-arm64/libtruehd_atmos.a

## DTS:X

DTS:X is decoded by FFmpeg's own DTS decoder in `Packages/FilmSound`, with FFmpegBuild's patch that also reads the
four overhead channels (`scripts/build_filmsound.sh`).

Dolby, Dolby Atmos and Dolby TrueHD are trademarks of Dolby Laboratories; DTS and DTS:X are trademarks of DTS, Inc.
Nothing here is affiliated with or endorsed by either. Their formats may be covered by patents.
