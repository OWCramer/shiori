// Decoders Apple's Compression framework lacks, for Steam depot chunks:
// raw LZMA (VZip) from the LZMA SDK, and Zstandard (VZstd).
#include <stddef.h>
#include "LzmaDec.h"
#include "zstd.h"

/// Decodes a raw LZMA stream with 5-byte `props` into `dest`.
/// Returns the number of bytes written, or -1 on corrupt input.
long vnhub_lzma_decode(unsigned char *dest, size_t dest_len,
                       const unsigned char *src, size_t src_len,
                       const unsigned char *props);
