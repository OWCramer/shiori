# Shiori

A player for the visual novels you own, on iPhone, iPad and Apple TV. Sign in with your Steam account, download your PC games onto the device, add patches through the Files app, and play them with touch, a keyboard and pointer, or a controller.

Shiori doesn't include or sell any games, and this repository holds no game content. It plays the games your account owns.

[Join the TestFlight beta](https://testflight.apple.com/join/p6CHjMne) · [Website](https://ocramer.com/apps/shiori) · [Support](https://ocramer.com/apps/shiori/support) · [Privacy Policy](https://ocramer.com/apps/shiori/privacy) · [Compatibility](https://compat.ocramer.com) · [Patches](https://github.com/OWCramer/shiori-patches)

## Engines

Shiori runs each game on a native runtime for its engine. Each engine is its own repository and Swift package:

| Engine | Package | Runtime |
|---|---|---|
| Ren'Py 6.99–8 | in this repository (`App/RenPy`) | Ren'Py's own iOS runtime (renios), embedded CPython and SDL2 |
| KiriKiri / KiriKiri Z | [KiriKit](https://github.com/OWCramer/KiriKit) | krkr2's core with Shiori's environment and Metal compositor |
| Artemis | [ArtemisKit](https://github.com/OWCramer/ArtemisKit) | Shiori's own interpreter (Swift, Lua 5.1) |
| SiglusEngine | [SiglusKit](https://github.com/OWCramer/SiglusKit) | siglus_rs, patched |
| Luca System | [LucaKit](https://github.com/OWCramer/LucaKit) | Shiori's own interpreter (Swift) |
| CatSystem2 | [CatSystemKit](https://github.com/OWCramer/CatSystemKit) | Shiori's own interpreter (Swift), and the E-mote renderer KiriKit uses |

Movies use an LGPL build of FFmpeg (`Scripts/ffmpeg`, see below). Steam sign-in, downloads and Steam Cloud are `Packages/SteamKit`.

## Building

Needs Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and for the engine frameworks CMake, Ninja and Rust (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`).

The engine frameworks are prebuilt into `Vendor/` (git-ignored) by each repository's scripts. Check the repositories out side by side:

```sh
git clone https://github.com/OWCramer/shiori
git clone https://github.com/OWCramer/KiriKit
git clone https://github.com/OWCramer/SiglusKit
git clone https://github.com/OWCramer/LucaKit
```

Then build each one (every script is safe to re-run):

```sh
(cd shiori && Scripts/ffmpeg/fetch-ffmpeg.sh && Scripts/ffmpeg/build-ios-ffmpeg.sh)
(cd KiriKit && Scripts/krkr2/fetch.sh && Scripts/krkr2/build-framework.sh)
(cd SiglusKit && Scripts/siglus/fetch-siglus.sh && Scripts/siglus/build-ios-framework.sh)
(cd LucaKit && Scripts/luca/fetch-vpx.sh && Scripts/luca/build-ios-vpx.sh)
(cd shiori && Scripts/build-renpy-runtimes.sh && Scripts/tv/build-renpy-tv.sh)
cp -R KiriKit/Vendor/ShioriKrkr.xcframework SiglusKit/Vendor/ShioriSiglus.xcframework LucaKit/Vendor/ShioriVPX.xcframework shiori/Vendor/
```

Then generate the project and open it:

```sh
cd shiori
xcodegen generate
open Shiori.xcodeproj
```

Set your own team in `Signing.local.xcconfig` (`DEVELOPMENT_TEAM = …`, not committed); the bundle and iCloud container IDs are Shiori's, so change them too for a build of your own.

The engine packages resolve from GitHub by version. To work on an engine and the app together, point the project at your checkouts with a `project.local.yml` (git-ignored) and generate from it:

```yaml
include: [project.yml]
packages:
  KiriKit:
    path: ../KiriKit
```

```sh
xcodegen generate --spec project.local.yml
```

## Licence

Shiori is free software under the [Mozilla Public License 2.0](LICENSE). Third-party components keep their own licences; the app shows their notices in Settings › About › Acknowledgements (`App/Resources/Acknowledgements`).

FFmpeg, FriBidi and pygame_sdl2 are LGPL and linked statically: the build scripts above rebuild them from source, so a modified copy can be linked into Shiori.

### FFmpeg (LGPL)

Shiori links FFmpeg n8.0.3 ([source](https://github.com/FFmpeg/FFmpeg/tree/n8.0.3)) statically, under the LGPL-2.1-or-later. `Scripts/ffmpeg/fetch-ffmpeg.sh` fetches that tag and `Scripts/ffmpeg/build-ios-ffmpeg.sh` builds it (`build-ffmpeg-macos.sh` for KiriKit's Mac harness) with `--disable-everything --disable-autodetect` and only: demuxers asf, mpegps and mpegvideo; decoders wmv1, wmv2, wmv3, vc1, wmav1, wmav2, wmapro, wmalossless, mpeg1video, mpeg2video, mp2 and mp3; parsers mpegvideo and mpegaudio. No GPL, non-free or version-3 parts are enabled.

To relink Shiori with a modified FFmpeg: change the source fetched into `Vendor/ffmpeg`, rerun `build-ios-ffmpeg.sh` (it writes `Vendor/ShioriFFmpeg.xcframework`), rebuild KiriKit and SiglusKit's frameworks as above so they pick it up, then rebuild the app. On request, the FFmpeg source and build scripts for any released version are available from me@ocramer.com.

Shiori isn't affiliated with or endorsed by Valve. Steam is a trademark of Valve Corporation.

## Contact

me@ocramer.com · security issues: see [SECURITY.md](SECURITY.md)
