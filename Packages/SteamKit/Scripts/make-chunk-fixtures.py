#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.

"""Writes synthetic depot-chunk fixtures to Tests/SteamKitTests/Fixtures/chunks/.

Each chunk is the same plaintext compressed the three ways Steam does (VZip LZMA, VZstd,
PKZip), then encrypted the way the CDN serves it: AES-256-ECB(IV) followed by
AES-256-CBC(PKCS#7) of the compressed bytes. Uses a made-up key, never a real depot key.
Requires openssl and zstd on PATH (brew install openssl zstd).
"""
import hashlib, io, json, lzma, os, struct, subprocess, zipfile, zlib, base64

OUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "SteamKitTests", "Fixtures", "chunks")
KEY = bytes(range(32))
IV = bytes(range(100, 116))


def openssl(mode, data, iv=None, pad=True):
    args = ["openssl", "enc", f"-aes-256-{mode}", "-K", KEY.hex()]
    if iv is not None:
        args += ["-iv", iv.hex()]
    if not pad:
        args.append("-nopad")
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout


def encrypt(data):
    return openssl("ecb", IV, pad=False) + openssl("cbc", data, iv=IV)


def adler_seed0(data):
    return zlib.adler32(data, 0) & 0xFFFFFFFF


def vzip(plain):
    alone = lzma.compress(plain, format=lzma.FORMAT_ALONE)
    props, stream = alone[:5], alone[13:]  # .lzma header: 5 props bytes + u64 size
    crc = zlib.crc32(plain) & 0xFFFFFFFF
    return b"VZa" + struct.pack("<I", crc) + props + stream + struct.pack("<II", crc, len(plain)) + b"zv"


def vzstd(plain):
    frame = subprocess.run(["zstd", "-q", "-c", "-19"], input=plain, capture_output=True, check=True).stdout
    crc = zlib.crc32(plain) & 0xFFFFFFFF
    return b"VSZa" + struct.pack("<I", crc) + frame + struct.pack("<III", crc, len(plain), 0) + b"zsv"


def pkzip(plain):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("z", plain)
    return buffer.getvalue()


def main():
    os.makedirs(OUT, exist_ok=True)
    words = b"Highway Blossoms rides along Route 66 with Amber and Marina. "
    plain = b"".join(words + str(i).encode() + b"\n" for i in range(1500))
    meta = {
        "key": KEY.hex(),
        "size": len(plain),
        "adler": adler_seed0(plain),
        "sha1": hashlib.sha1(plain).hexdigest(),
        # A filename as manifests store it: base64 of the encrypted, NUL-terminated name.
        "encryptedFilename": base64.b64encode(encrypt(b"game\\images\\bg road.png\x00")).decode(),
        "filename": "game/images/bg road.png",
    }
    for name, data in [("vzip", vzip(plain)), ("vzstd", vzstd(plain)), ("pkzip", pkzip(plain))]:
        with open(os.path.join(OUT, f"{name}.bin"), "wb") as f:
            f.write(encrypt(data))
    with open(os.path.join(OUT, "plain.bin"), "wb") as f:
        f.write(plain)
    with open(os.path.join(OUT, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
