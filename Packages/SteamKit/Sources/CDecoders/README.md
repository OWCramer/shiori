Vendored C decoders for depot chunks.

- `LzmaDec.c`, `LzmaDec.h`, `7zTypes.h`, `Precomp.h`, `Compiler.h`, `7zWindows.h`: LZMA SDK
  (public domain), from https://github.com/ip7z/7zip `C/`.
- `zstddeclib.c`, `zstd.h`, `zstd_errors.h`: Zstandard 1.5.7 decoder (BSD, see `LICENSE-zstd`), amalgamated with
  `build/single_file_libs/create_single_file_decoder.sh` from the release tarball.
