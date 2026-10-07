#include "CDecoders.h"
#include <stdlib.h>

static void *lzma_alloc(ISzAllocPtr p, size_t size) { (void)p; return malloc(size); }
static void lzma_free(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc lzma_allocator = { lzma_alloc, lzma_free };

long vnhub_lzma_decode(unsigned char *dest, size_t dest_len,
                       const unsigned char *src, size_t src_len,
                       const unsigned char *props) {
    SizeT out_len = dest_len;
    SizeT in_len = src_len;
    ELzmaStatus status;
    SRes result = LzmaDecode(dest, &out_len, src, &in_len, props, LZMA_PROPS_SIZE,
                             LZMA_FINISH_ANY, &status, &lzma_allocator);
    if (result != SZ_OK) return -1;
    return (long)out_len;
}
