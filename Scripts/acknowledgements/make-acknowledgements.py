#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.

"""Builds App/Resources/Acknowledgements (Settings › About › Acknowledgements) from the licence
files of every component Shiori ships. See docs/licences.md; rerun when a component changes:

    python3 -I Scripts/acknowledgements/make-acknowledgements.py
"""
import hashlib, json, os, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WT = HERE.parent.parent
# Vendor/ is gitignored; worktrees use the main checkout's.
V = Path(os.environ.get("SHIORI_VENDOR", WT / "Vendor"))
if not (V / "krkr2").exists():
    V = Path.home() / "Developer/vn-hub/Vendor"
OUT = WT / "App/Resources/Acknowledgements"
REG = next((Path.home() / ".cargo/registry/src").glob("index.crates.io-*"))
SHARE = V / "krkr2-deps/arm64-ios/arm64-ios/share"
# Crates compiled into ShioriSiglus for aarch64-apple-ios (name, version, licence, kind, path),
# from Cargo.lock walked from game_launcher and the target's dep-info.
TSV = HERE / "siglus-crates.tsv"
# Swift packages as Xcode resolved them.
SPM = next(p for p in (Path.home() / "Library/Developer/Xcode/DerivedData").glob("Shiori-*/SourcePackages/checkouts")
           if (p / "Kingfisher/LICENSE").exists())
HB = Path("/opt/homebrew/Cellar")

def rd(p): return Path(p).read_text(encoding="utf-8", errors="replace").strip() + "\n"
def lines(p, a, b): return "\n".join(rd(p).splitlines()[a - 1:b]).rstrip() + "\n"

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
def mit(c): return f"MIT License\n\n{c}\n\n{MIT}"

def bsd(c, n=3, org="the copyright holder"):
    t = f"""{c}
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
"""
    if n == 3:
        t += f"""
3. Neither the name of {org} nor the names of its contributors may be used
   to endorse or promote products derived from this software without
   specific prior written permission.
"""
    t += """
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""
    return t

def zlib(c):
    return f"""{c}

This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
"""

APACHE = rd(REG / "ahash-0.8.12/LICENSE-APACHE")
MPL2 = rd(V / "siglus_rs/LICENSE-MPL-2.0")
LGPL21 = rd(V / "ffmpeg/COPYING.LGPLv2.1")
OFL_SIGLUS = rd(WT / "App/Resources/SiglusFonts/OFL.txt")
KIRIKIRI = rd(V / "krkrsdl3/LICENSE").split("----------------------------------------------------------------------------\nkrkrsdl3")[0].rstrip() + "\n"

OPENSSL = """OpenSSL 1.1.1 is under the dual OpenSSL and SSLeay licences below.

  LICENSE ISSUES
  ==============

  The OpenSSL toolkit stays under a double license, i.e. both the conditions of
  the OpenSSL License and the original SSLeay license apply to the toolkit.

  OpenSSL License
  ---------------

 Copyright (c) 1998-2019 The OpenSSL Project.  All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:

 1. Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

 3. All advertising materials mentioning features or use of this
    software must display the following acknowledgment:
    "This product includes software developed by the OpenSSL Project
    for use in the OpenSSL Toolkit. (http://www.openssl.org/)"

 4. The names "OpenSSL Toolkit" and "OpenSSL Project" must not be used to
    endorse or promote products derived from this software without
    prior written permission. For written permission, please contact
    openssl-core@openssl.org.

 5. Products derived from this software may not be called "OpenSSL"
    nor may "OpenSSL" appear in their names without prior written
    permission of the OpenSSL Project.

 6. Redistributions of any form whatsoever must retain the following
    acknowledgment:
    "This product includes software developed by the OpenSSL Project
    for use in the OpenSSL Toolkit (http://www.openssl.org/)"

 THIS SOFTWARE IS PROVIDED BY THE OpenSSL PROJECT ``AS IS'' AND ANY
 EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE OpenSSL PROJECT OR
 ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 OF THE POSSIBILITY OF SUCH DAMAGE.

 This product includes cryptographic software written by Eric Young
 (eay@cryptsoft.com).  This product includes software written by Tim
 Hudson (tjh@cryptsoft.com).

 Original SSLeay License
 -----------------------

 Copyright (C) 1995-1998 Eric Young (eay@cryptsoft.com)
 All rights reserved.

 This package is an SSL implementation written
 by Eric Young (eay@cryptsoft.com).
 The implementation was written so as to conform with Netscapes SSL.

 This library is free for commercial and non-commercial use as long as
 the following conditions are aheared to.  The following conditions
 apply to all code found in this distribution, be it the RC4, RSA,
 lhash, DES, etc., code; not just the SSL code.  The SSL documentation
 included with this distribution is covered by the same copyright terms
 except that the holder is Tim Hudson (tjh@cryptsoft.com).

 Copyright remains Eric Young's, and as such any Copyright notices in
 the code are not to be removed.
 If this package is used in a product, Eric Young should be given attribution
 as the author of the parts of the library used.
 This can be in the form of a textual message at program startup or
 in documentation (online or textual) provided with the package.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 1. Redistributions of source code must retain the copyright
    notice, this list of conditions and the following disclaimer.
 2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
 3. All advertising materials mentioning features or use of this software
    must display the following acknowledgement:
    "This product includes cryptographic software written by
     Eric Young (eay@cryptsoft.com)"
    The word 'cryptographic' can be left out if the rouines from the library
    being used are not cryptographic related :-).
 4. If you include any Windows specific code (or a derivative thereof) from
    the apps directory (application code) you must include an acknowledgement:
    "This product includes software written by Tim Hudson (tjh@cryptsoft.com)"

 THIS SOFTWARE IS PROVIDED BY ERIC YOUNG ``AS IS'' AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 SUCH DAMAGE.

 The licence and distribution terms for any publically available version or
 derivative of this code cannot be changed.  i.e. this code cannot simply be
 copied and put under another distribution licence
 [including the GNU Public Licence.]
"""

def sep(title): return f"\n\n==== {title} ====\n\n"

entries = []  # (name, version, licence, file, text)
def add(name, version, licence, file, text):
    entries.append(dict(name=name, version=version, licence=licence, file=file, text=text))

# --- App and Swift packages -------------------------------------------------
add("Kingfisher", "8.12.0", "MIT", "Kingfisher.txt", rd(SPM / "Kingfisher/LICENSE"))
add("SwiftProtobuf", "1.38.1", "Apache 2.0", "SwiftProtobuf.txt", rd(SPM / "swift-protobuf/LICENSE.txt"))
add("BIZ UDGothic", None, "SIL Open Font License 1.1", "BIZ-UDGothic.txt", OFL_SIGLUS)

# --- SteamKit ------------------------------------------------------------------
add("Zstandard", "1.5.7", "BSD 3-Clause", "Zstandard.txt", rd(WT / "Packages/SteamKit/Sources/CDecoders/LICENSE-zstd"))
add("LZMA SDK", None, "Public Domain", "LZMA-SDK.txt",
    "LzmaDec.c and its headers, from the LZMA SDK by Igor Pavlov (https://7-zip.org/sdk.html).\n\nThe LZMA SDK is placed in the public domain.\n")

# --- Artemis -------------------------------------------------------------------
add("Lua", "5.1.5", "MIT", "Lua.txt", rd(SPM / "ArtemisKit/Sources/CLua/COPYRIGHT"))
sv = rd(SPM / "ArtemisKit/Sources/CVorbis/stb_vorbis.c").splitlines()
i = max(k for k, l in enumerate(sv) if "ALTERNATIVE A - MIT License" in l)
j = max(k for k, l in enumerate(sv) if "ALTERNATIVE B" in l)
add("stb_vorbis", "1.22", "MIT", "stb_vorbis.txt", "Used under the MIT License (it is also in the public domain).\n\n" + "\n".join(sv[i + 1:j - 1]) + "\n")
add("libogg", "1.3.5, 1.3.6", "BSD 3-Clause", "libogg.txt", rd(SPM / "ArtemisKit/Sources/CVideo/ogg/COPYING"))
add("libtheora", "1.2.0", "BSD 3-Clause", "libtheora.txt",
    "libtheora decodes Artemis games' Theora movies; siglus_rs's theora-rs, which decodes Siglus games' OMV movies, "
    "is a Rust rewrite of libtheora 1.2.0.\n\n" + rd(SPM / "ArtemisKit/Sources/CVideo/theora/COPYING"))
add("PL_MPEG", None, "MIT", "pl_mpeg.txt", mit("Copyright (c) 2019 Dominic Szablewski"))

# --- Luca, CatSystem2, KiriKiri decryption ------------------------------------
add("libvpx", "1.15.2", "BSD 3-Clause", "libvpx.txt", rd(V / "libvpx/LICENSE") + sep("Additional IP Rights Grant (Patents)") + rd(V / "libvpx/PATENTS"))
add("FFmpeg", "8.0.3", "LGPL 2.1 or later", "FFmpeg.txt",
    "Shiori uses FFmpeg's libavformat, libavcodec and libavutil, built under the LGPL 2.1 or later "
    "(no GPL or non-free parts), for CatSystem2, KiriKiri and Siglus games' Windows Media and MPEG movies. "
    "FFmpeg's source and Shiori's build script (Scripts/catsystem/build-ios-ffmpeg.sh) are published with "
    "Shiori's source, so a modified FFmpeg can be relinked.\n\n" + rd(V / "ffmpeg/LICENSE.md") + sep("GNU Lesser General Public License 2.1") + LGPL21)
add("GARbro", None, "MIT", "GARbro.txt",
    "Shiori's CxDec and Hx decryption (ShioriKrkr) are ported from GARbro, and its KIF and HG-3 readers follow GARbro's format code.\n\n" + rd(V / "garbro/LICENSE"))
add("LuckSystem", None, "MIT", "LuckSystem.txt",
    "Luca System formats and Summer Pockets REFLECTION BLUE's opcode names follow LuckSystem (https://github.com/wetor/LuckSystem).\n\n" + mit("Copyright (c) wetor"))

# --- KiriKiri (ShioriKrkr) -------------------------------------------------------
krkr = rd(V / "krkr2/LICENSE")
add("KiriKiri (krkr2)", "3ac366c", "KiriKiri License", "KiriKiri.txt",
    "Shiori's KiriKiri engine is built on krkr2 (https://github.com/2468785842/krkr2), KiriKiri 2 and KiriKiri Z, "
    "with the plug-ins scriptsEx, win32dialog, dirlist, csvParser, varfile, saveStruct, getabout, addFont, wutcwf, "
    "windowEx, getSample, layerExPerspective, fftgraph, LayerExBase, xp3filter and fstat, and parts of Kirikiroid2 (zeas2). "
    "This software is based in part on the work of the Independent JPEG Group.\n\n" + krkr)
add("KiriKiri plug-ins (wamsoft)", None, "KiriKiri License", "wamsoft.txt",
    "AlphaMovie, KAGParserEx, extrans, layerExAreaAverage, layerExBTOA, layerExImage, layerExRaster and shrinkCopy "
    "(https://github.com/wamsoft) are distributed under the same licence as the KiriKiri engine:\n\n" + KIRIKIRI
    + sep("CxImage (in layerExImage)") + rd(V / "upstream-plugins/wamsoft/layerExImage/LICENSE.TXT"))
add("krkrsdl3", "358b046", "KiriKiri License", "krkrsdl3.txt",
    "PackinOne, lzfs, gfxEffect and LayerExDraw come from krkrsdl3 (https://github.com/krkrsdl3/krkrsdl3). "
    "Shiori's changes to them are published with Shiori's source.\n\n" + rd(V / "krkrsdl3/LICENSE"))
add("VelocityTracker (Android)", None, "Apache 2.0", "VelocityTracker.txt",
    "Copyright (C) 2012 The Android Open Source Project\n\n" + APACHE)
md5 = rd(V / "krkr2/cpp/core/utils/md5.c").split("*/")[0].lstrip("/*").strip()
add("MD5 (L. Peter Deutsch)", None, "zlib", "md5.txt", md5 + "\n")

dep = lambda port: rd(SHARE / port / "copyright")
ft = rd(SHARE / "freetype/copyright")
ft = ft.split("GPLv2.TXT:")[0].rstrip() + "\n"
add("FreeType", "2.14.3", "FreeType License", "FreeType.txt",
    "Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.\n\n"
    "Shiori uses FreeType under the FreeType License (FTL).\n\n" + ft)
add("libpng", "1.6.58", "libpng License", "libpng.txt", dep("libpng"))
add("zlib", "1.3.2", "zlib", "zlib.txt", dep("zlib"))
add("libjpeg-turbo", "3.2.0", "IJG, BSD 3-Clause", "libjpeg-turbo.txt",
    "This software is based in part on the work of the Independent JPEG Group.\n\n" + dep("libjpeg-turbo"))
add("libwebp", "1.6.0", "BSD 3-Clause", "libwebp.txt", dep("libwebp"))
add("libvorbis", "1.3.7", "BSD 3-Clause", "libvorbis.txt", dep("libvorbis"))
add("Opus", "1.5.2", "BSD 3-Clause", "Opus.txt", dep("opus"))
add("opusfile", "0.12", "BSD 3-Clause", "opusfile.txt", dep("opusfile"))
add("Oniguruma", "6.9.10", "BSD 2-Clause", "Oniguruma.txt", dep("oniguruma"))
add("fmt", "12.2.0", "MIT", "fmt.txt", dep("fmt"))
add("spdlog", "1.17.0", "MIT", "spdlog.txt", dep("spdlog"))
add("LZ4", "1.10.0", "BSD 2-Clause", "LZ4.txt", dep("lz4"))
add("xxHash", "0.8.3", "BSD 2-Clause", "xxHash.txt", dep("xxhash"))
add("PlutoVG", "1.3.3", "MIT", "PlutoVG.txt", dep("plutovg"))
add("Brotli", "1.2.0", "MIT", "Brotli.txt", dep("brotli"))
add("bzip2", "1.0.8", "bzip2 License", "bzip2.txt", dep("bzip2"))
uc = rd(SHARE / "uchardet/copyright")
uc = uc.split("GNU GENERAL PUBLIC LICENSE")[0].rstrip() + "\n"
add("uchardet", "0.0.8", "MPL 1.1", "uchardet.txt",
    "uchardet is available under the MPL 1.1, GPL 2 or LGPL 2.1; Shiori uses it under the MPL 1.1. "
    "Its source is at https://gitlab.freedesktop.org/uchardet/uchardet.\n\n" + uc)

# --- Siglus ----------------------------------------------------------------------
add("siglus_rs", "5f358ef", "MPL 2.0", "siglus_rs.txt",
    "Shiori's Siglus engine is siglus_rs (https://github.com/xmoezzz/siglus_rs). Its source, with Shiori's "
    "changes (Scripts/siglus/patches), is published with Shiori's source.\n\n" + MPL2)

# Rust crates: every licence file, grouped by identical text.
crates, groups = [], {}
for row in TSV.read_text().splitlines():
    name, ver, lic, kind, path = row.split("\t")[:5]
    if kind != "registry" and name != "kira":
        continue
    src = Path(path) if kind == "registry" else REG / f"{name}-{ver}"
    if name == "kira": lic = "MIT OR Apache-2.0"
    crates.append(f"{name} {ver} ({lic})")
    files = sorted(p for p in src.iterdir() if p.is_file() and re.match(r"(?i)(licen[cs]e|copying|notice|copyright)", p.name))
    for p in files:
        t = rd(p)
        h = hashlib.sha1(t.encode()).hexdigest()
        groups.setdefault(h, [t, []])[1].append(f"{name} {ver}")
txt = "The Rust crates compiled into Shiori's Siglus engine, with their licences.\n\n" + "\n".join(crates)
for t, users in sorted(groups.values(), key=lambda g: g[1][0]):
    txt += sep(", ".join(users)) + t
add("Rust crates (Siglus)", None, "MIT, Apache 2.0 and others", "Rust-crates.txt", txt)

# --- Ren'Py ------------------------------------------------------------------------
def renpy_head(p):
    out = []
    for l in rd(p).splitlines():
        if not l.startswith("#"): break
        out.append(l[2:] if l.startswith("# ") else l[1:])
    return "\n".join(out).strip() + "\n"
add("Ren'Py", "8.1.3, 7.8.7", "MIT", "RenPy.txt",
    "Ren'Py 8.1.3 and 7.8.7 (https://www.renpy.org), with renios and pygame_sdl2.\n\n"
    + renpy_head(V / "RenPy8Base/renpy/main.py") + sep("Ren'Py 7.8.7") + renpy_head(V / "RenPy7Base/renpy/main.py"))
add("pygame_sdl2", None, "zlib, LGPL 2.1", "pygame_sdl2.txt",
    "pygame_sdl2 (https://github.com/renpy/pygame_sdl2) is under the zlib licence; the parts derived from "
    "Pygame are under the GNU LGPL 2.1 or later. Its source and Ren'Py's iOS build scripts are published, so a "
    "modified copy can be relinked into the Ren'Py runtimes.\n\n"
    + zlib("Copyright 2014 Tom Rothamel <pytom@bishoujo.us>\nCopyright 2014 Patrick Dawson <pat@dw.is>")
    + sep("GNU Lesser General Public License 2.1") + LGPL21)
add("Python", "3.9.10, 2.7.18", "PSF License", "Python.txt", rd(HB / "python@3.14/3.14.7/LICENSE"))
add("SDL", "2.0.20", "zlib", "SDL.txt", zlib("Copyright (C) 1997-2022 Sam Lantinga <slouken@libsdl.org>")
    + sep("SDL_image") + zlib("Copyright (C) 1997-2022 Sam Lantinga <slouken@libsdl.org>"))
add("GNU FriBidi", "1.0.7", "LGPL 2.1 or later", "FriBidi.txt",
    "GNU FriBidi (https://github.com/fribidi/fribidi), statically linked into the Ren'Py runtimes. Its source and "
    "Ren'Py's iOS build scripts are published, so a modified copy can be relinked.\n\n"
    "Copyright (C) 2004 Sharif FarsiWeb, Inc.\nCopyright (C) 2001, 2002, 2004 Behdad Esfahbod\n"
    "Copyright (C) 1999, 2000 Dov Grobgeld\n\n" + LGPL21)
add("OpenSSL", "1.1.1s", "OpenSSL, SSLeay", "OpenSSL.txt", OPENSSL)
add("libffi", None, "MIT", "libffi.txt", rd(HB / "libffi/3.7.1/LICENSE"))
add("HarfBuzz", "8.0.1", "MIT (Old MIT)", "HarfBuzz.txt", rd(HB / "harfbuzz/14.5.1/COPYING"))
add("libavif", "0.11.1", "BSD 2-Clause", "libavif.txt", bsd("Copyright 2019 Joe Drago", n=2))
add("libaom", "3.5.0", "BSD 2-Clause", "libaom.txt",
    bsd("Copyright (c) 2016, Alliance for Open Media", n=2)
    + "\nlibaom is also covered by the Alliance for Open Media Patent License 1.0 (https://aomedia.org/license/patent-license/).\n")
add("libyuv", None, "BSD 3-Clause", "libyuv.txt", rd(V / "libvpx/third_party/libyuv/LICENSE"))
add("xz (liblzma)", "5.4.2", "Public Domain", "xz.txt", "liblzma from XZ Utils 5.4.2 (https://tukaani.org/xz/) is in the public domain.\n")
add("MetalANGLE", None, "BSD 3-Clause", "MetalANGLE.txt",
    "MetalANGLE (https://github.com/kakashidinho/metalangle), the OpenGL ES layer for Ren'Py, is based on ANGLE.\n\n"
    + bsd("Copyright 2018 The ANGLE Project Authors.", org="TransGaming Inc., Google Inc., 3DLabs Inc. Ltd.")
    + sep("glslang") + rd(HB / "glslang/16.6.0/LICENSE.txt") + sep("SPIRV-Cross") + rd(HB / "spirv-cross/1.4.363.0/LICENSE"))
pyp = (
    "Python packages bundled with the Ren'Py runtimes.\n\n"
    "requests 2.20.0: Apache 2.0, Copyright 2018 Kenneth Reitz\n"
    "rsa 3.4.2: Apache 2.0, Copyright 2011 Sybren A. Stüvel\n"
    "certifi 2023.07.22: MPL 2.0, Kenneth Reitz (source: https://github.com/certifi/python-certifi)\n"
    "chardet 3.0.4: LGPL 2.1 or later, Mark Pilgrim and contributors (source: https://github.com/chardet/chardet)\n"
    "urllib3: MIT, Copyright (c) 2008-2019 Andrey Petrov and contributors\n"
    "ecdsa: MIT, Copyright (c) 2010 Brian Warner\n"
    "future: MIT, Copyright (c) 2013-2019 Python Charmers Pty Ltd, Australia\n"
    "six 1.12.0: MIT, Copyright (c) 2010-2018 Benjamin Peterson\n"
    "pefile 2021.9.3: MIT, Copyright (c) 2004-2021 Ero Carrera\n"
    "pyobjus, pyjnius: MIT, Copyright (c) 2010-2023 Kivy Team and other contributors\n"
    "idna: BSD 3-Clause, Copyright (c) 2013-2018 Kim Davies and contributors\n"
    "pyasn1 0.4.2: BSD 2-Clause, Copyright (c) 2005-2019 Ilya Etingof\n"
    + sep("MIT License") + MIT + sep("BSD 3-Clause (idna)") + bsd("Copyright (c) 2013-2018, Kim Davies. All rights reserved.", org="the copyright holder")
    + sep("BSD 2-Clause (pyasn1)") + bsd("Copyright (c) 2005-2019, Ilya Etingof <etingof@gmail.com>", n=2)
    + sep("Apache License 2.0 (requests, rsa)") + APACHE + sep("Mozilla Public License 2.0 (certifi)") + MPL2
    + sep("GNU Lesser General Public License 2.1 (chardet)") + LGPL21)
add("Python packages (Ren'Py)", None, "MIT, Apache 2.0, BSD, MPL 2.0, LGPL 2.1", "Python-packages.txt", pyp)
add("DejaVu Sans", None, "Bitstream Vera License", "DejaVu.txt", rd(V / "RenPy8Base/renpy/common/DejaVuSans.txt"))
add("OpenDyslexic", "3", "SIL Open Font License 1.1", "OpenDyslexic.txt", rd(V / "RenPy8Base/renpy/common/_OpenDyslexic3-Regular.txt"))
add("Quicksand", None, "SIL Open Font License 1.1", "Quicksand.txt", rd(V / "RenPy8Base/renpy/common/_theme_awt/OFL.txt"))
add("Twemoji", None, "CC BY 4.0 (graphics), MIT (code)", "Twemoji.txt",
    rd(V / "RenPy7Base/renpy/common/TwemojiCOLRv0.txt"))

# Nothing from Aether ships (the Standard engine, AetherKrkr, left the app on 2026-10-15); its
# Mac reference harness (Scripts/kirikiri) is never built into the app, so it has no entry here.

# --- write -----------------------------------------------------------------------
for f in OUT.glob("*.txt"): f.unlink()
for e in entries:
    (OUT / e["file"]).write_text(e["text"], encoding="utf-8")
manifest = [{k: e[k] for k in ("name", "version", "licence", "file") if e[k] is not None} for e in entries]
(OUT / "acknowledgements.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
print(len(entries), "entries;", sum((OUT / e["file"]).stat().st_size for e in entries) // 1024, "KB")
