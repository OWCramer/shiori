// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

// Decoders Apple's Compression framework lacks, for Steam depot chunks:
// raw LZMA (VZip) from the LZMA SDK, and Zstandard (VZstd).
#include <stddef.h>
#include "LzmaDec.h"
#include "zstd.h"

/// Decodes a raw LZMA stream with 5-byte `props` into `dest`.
/// Returns the number of bytes written, or -1 on corrupt input.
long shiori_lzma_decode(unsigned char *dest, size_t dest_len,
                       const unsigned char *src, size_t src_len,
                       const unsigned char *props);
