// Aplicação de patches IPS e BPS em memória (soft-patching, como o RetroArch faz).
#include "rf_patch.h"
#include <stdlib.h>
#include <string.h>

static uint32_t rf_crc_table[256];

uint32_t rf_crc32(const uint8_t *data, size_t len) {
    if (!rf_crc_table[1]) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            rf_crc_table[i] = c;
        }
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) crc = rf_crc_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

// Garante espaço para `need` bytes no buffer de saída (preenche com zero o que crescer)
static int rf_grow(uint8_t **buf, size_t *len, size_t *cap, size_t need) {
    if (need > *cap) {
        size_t ncap = *cap ? *cap : 1024;
        while (ncap < need) ncap *= 2;
        uint8_t *nb = realloc(*buf, ncap);
        if (!nb) return 0;
        *buf = nb;
        *cap = ncap;
    }
    if (need > *len) {
        memset(*buf + *len, 0, need - *len);
        *len = need;
    }
    return 1;
}

static rf_patch_result rf_apply_ips(const uint8_t *src, size_t srcLen, const uint8_t *p, size_t pLen,
                                    uint8_t **out, size_t *outLen) {
    size_t cap = srcLen + 1024, len = srcLen;
    uint8_t *buf = malloc(cap);
    if (!buf) return RF_PATCH_NO_MEMORY;
    memcpy(buf, src, srcLen);
    size_t pos = 5;
    for (;;) {
        if (pos + 3 > pLen) goto bad;
        if (memcmp(p + pos, "EOF", 3) == 0) {
            pos += 3;
            if (pos + 3 <= pLen) {   // extensão: tamanho final do arquivo
                size_t trunc = ((size_t)p[pos] << 16) | ((size_t)p[pos + 1] << 8) | p[pos + 2];
                if (trunc < len) len = trunc;
                else if (!rf_grow(&buf, &len, &cap, trunc)) goto oom;
            }
            break;
        }
        size_t off = ((size_t)p[pos] << 16) | ((size_t)p[pos + 1] << 8) | p[pos + 2];
        pos += 3;
        if (pos + 2 > pLen) goto bad;
        size_t size = ((size_t)p[pos] << 8) | p[pos + 1];
        pos += 2;
        if (size) {
            if (pos + size > pLen) goto bad;
            if (!rf_grow(&buf, &len, &cap, off + size)) goto oom;
            memcpy(buf + off, p + pos, size);
            pos += size;
        } else {   // RLE: repete um byte
            if (pos + 3 > pLen) goto bad;
            size_t run = ((size_t)p[pos] << 8) | p[pos + 1];
            uint8_t value = p[pos + 2];
            pos += 3;
            if (!rf_grow(&buf, &len, &cap, off + run)) goto oom;
            memset(buf + off, value, run);
        }
    }
    *out = buf;
    *outLen = len;
    return RF_PATCH_OK;
bad:
    free(buf);
    return RF_PATCH_CORRUPT;
oom:
    free(buf);
    return RF_PATCH_NO_MEMORY;
}

static int rf_bps_varint(const uint8_t *p, size_t end, size_t *pos, uint64_t *value) {
    uint64_t data = 0, shift = 1;
    for (;;) {
        if (*pos >= end || shift > ((uint64_t)1 << 56)) return 0;
        uint8_t x = p[(*pos)++];
        data += (x & 0x7F) * shift;
        if (x & 0x80) break;
        shift <<= 7;
        data += shift;
    }
    *value = data;
    return 1;
}

static uint32_t rf_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static rf_patch_result rf_apply_bps(const uint8_t *src, size_t srcLen, const uint8_t *p, size_t pLen,
                                    uint8_t **out, size_t *outLen) {
    if (pLen < 4 + 3 + 12) return RF_PATCH_CORRUPT;
    if (rf_crc32(p, pLen - 4) != rf_le32(p + pLen - 4)) return RF_PATCH_CORRUPT;
    if (rf_crc32(src, srcLen) != rf_le32(p + pLen - 12)) return RF_PATCH_WRONG_SOURCE;

    size_t end = pLen - 12, pos = 4;
    uint64_t sourceSize, targetSize, metaSize;
    if (!rf_bps_varint(p, end, &pos, &sourceSize) || !rf_bps_varint(p, end, &pos, &targetSize) ||
        !rf_bps_varint(p, end, &pos, &metaSize)) return RF_PATCH_CORRUPT;
    if (sourceSize != srcLen) return RF_PATCH_WRONG_SOURCE;
    if (targetSize > (64u << 20) || metaSize > end - pos) return RF_PATCH_CORRUPT;
    pos += metaSize;

    uint8_t *dst = malloc(targetSize ? targetSize : 1);
    if (!dst) return RF_PATCH_NO_MEMORY;
    size_t outPos = 0;
    int64_t srcRel = 0, dstRel = 0;
    while (pos < end) {
        uint64_t data;
        if (!rf_bps_varint(p, end, &pos, &data)) goto bad;
        uint64_t cmd = data & 3, n = (data >> 2) + 1;
        if (outPos + n > targetSize) goto bad;
        switch (cmd) {
            case 0:   // SourceRead
                if (outPos + n > srcLen) goto bad;
                memcpy(dst + outPos, src + outPos, n);
                outPos += n;
                break;
            case 1:   // TargetRead
                if (pos + n > end) goto bad;
                memcpy(dst + outPos, p + pos, n);
                pos += n;
                outPos += n;
                break;
            case 2:   // SourceCopy
            case 3: { // TargetCopy
                uint64_t raw;
                if (!rf_bps_varint(p, end, &pos, &raw)) goto bad;
                int64_t delta = (int64_t)(raw >> 1) * ((raw & 1) ? -1 : 1);
                if (cmd == 2) {
                    srcRel += delta;
                    if (srcRel < 0 || (uint64_t)srcRel + n > srcLen) goto bad;
                    memcpy(dst + outPos, src + srcRel, n);
                    srcRel += n;
                    outPos += n;
                } else {
                    dstRel += delta;
                    if (dstRel < 0 || (uint64_t)dstRel >= outPos) goto bad;
                    // Pode sobrepor (repetição de padrão): copia byte a byte
                    for (uint64_t i = 0; i < n; i++) dst[outPos++] = dst[dstRel++];
                }
                break;
            }
        }
    }
    if (outPos != targetSize) goto bad;
    if (rf_crc32(dst, targetSize) != rf_le32(p + pLen - 8)) goto bad;
    *out = dst;
    *outLen = targetSize;
    return RF_PATCH_OK;
bad:
    free(dst);
    return RF_PATCH_CORRUPT;
}

rf_patch_result rf_apply_patch(const uint8_t *src, size_t srcLen, const uint8_t *patch, size_t patchLen,
                               uint8_t **out, size_t *outLen) {
    *out = NULL;
    *outLen = 0;
    if (patchLen >= 5 && memcmp(patch, "PATCH", 5) == 0) return rf_apply_ips(src, srcLen, patch, patchLen, out, outLen);
    if (patchLen >= 4 && memcmp(patch, "BPS1", 4) == 0) return rf_apply_bps(src, srcLen, patch, patchLen, out, outLen);
    return RF_PATCH_UNKNOWN_FORMAT;
}
