# shiori-ffmpeg

The FFmpeg build [Shiori](https://github.com/OWCramer/shiori) and [KiriKit](https://github.com/OWCramer/KiriKit) link: FFmpeg n8.0.3, LGPL-2.1+, with only what visual novel movies need (the ASF and MPEG program-stream demuxers; Windows Media video and audio, MPEG-1/2 video and MPEG audio decoders). No `--enable-gpl`, `--enable-nonfree` or `--enable-version3`.

```sh
Scripts/ffmpeg/fetch-ffmpeg.sh        # FFmpeg into Vendor/ffmpeg, pinned
Scripts/ffmpeg/build-ios-ffmpeg.sh    # Vendor/ShioriFFmpeg.xcframework (static, device and simulator)
Scripts/ffmpeg/build-ffmpeg-macos.sh  # build/ffmpeg-macos/install, for KiriKit's Mac harness
```

## Relinking

Shiori and KiriKit link this library statically. To use a modified FFmpeg, change the source in `Vendor/ffmpeg`, rerun the build, copy `ShioriFFmpeg.xcframework` into the app's `Vendor/`, rebuild KiriKit's framework against it, and build the app.

## Licence

The scripts are under the [Mozilla Public License 2.0](LICENSE). FFmpeg is LGPL-2.1-or-later, fetched from its own repository and never committed here.
