# Shiori

A player for the visual novels you own, on iPhone, iPad and Apple TV. Sign in with your Steam account, download your PC games onto the device, add patches through the Files app, and play them with touch, a keyboard and pointer, or a controller.

Shiori doesn't include or sell any games, and this repository holds no game content. It plays the games your account owns.

[Support](https://owcramer.github.io/shiori/support/) · [Privacy Policy](https://owcramer.github.io/shiori/privacy/) · [Compatibility](https://github.com/OWCramer/shiori-compatibility) · [Patches](https://github.com/OWCramer/shiori-patches)

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

Movies use an LGPL build of FFmpeg from [shiori-ffmpeg](https://github.com/OWCramer/shiori-ffmpeg). Steam sign-in, downloads and Steam Cloud are `Packages/SteamKit`.

## Building

Needs Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and for the engine frameworks CMake, Ninja and Rust (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`).

The engine frameworks are prebuilt into `Vendor/` (git-ignored) by each repository's scripts. Check the repositories out side by side:

```sh
git clone https://github.com/OWCramer/shiori
git clone https://github.com/OWCramer/shiori-ffmpeg
git clone https://github.com/OWCramer/KiriKit
git clone https://github.com/OWCramer/SiglusKit
git clone https://github.com/OWCramer/LucaKit
```

Then build each one (every script is safe to re-run):

```sh
(cd shiori-ffmpeg && Scripts/ffmpeg/fetch-ffmpeg.sh && Scripts/ffmpeg/build-ios-ffmpeg.sh)
(cd KiriKit && Scripts/krkr2/fetch.sh && Scripts/krkr2/build-framework.sh)
(cd SiglusKit && Scripts/siglus/fetch-siglus.sh && Scripts/siglus/build-ios-framework.sh)
(cd LucaKit && Scripts/luca/fetch-vpx.sh && Scripts/luca/build-ios-vpx.sh)
(cd shiori && Scripts/build-renpy-runtimes.sh && Scripts/tv/build-renpy-tv.sh)
cp -R shiori-ffmpeg/Vendor/ShioriFFmpeg.xcframework KiriKit/Vendor/ShioriKrkr.xcframework \
      SiglusKit/Vendor/ShioriSiglus.xcframework LucaKit/Vendor/ShioriVPX.xcframework shiori/Vendor/
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

Shiori is free software under the [Mozilla Public License 2.0](LICENSE). Third-party components keep their own licences, listed in [docs/licences.md](docs/licences.md); the app shows their notices in Settings › About › Acknowledgements (`App/Resources/Acknowledgements`).

FFmpeg, FriBidi and pygame_sdl2 are LGPL and linked statically: the build scripts above rebuild them from source, so a modified copy can be linked into Shiori.

Shiori isn't affiliated with or endorsed by Valve. Steam is a trademark of Valve Corporation.

## Contact

me@ocramer.com · security issues: see [SECURITY.md](SECURITY.md)
