#ifndef RF_PATCH_H
#define RF_PATCH_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    RF_PATCH_OK = 0,
    RF_PATCH_UNKNOWN_FORMAT,   // não é IPS nem BPS
    RF_PATCH_CORRUPT,          // arquivo de patch danificado
    RF_PATCH_WRONG_SOURCE,     // BPS feito para outra versão da ROM (CRC não bate)
    RF_PATCH_NO_MEMORY,
} rf_patch_result;

// Aplica um patch IPS ou BPS. Em caso de sucesso, *out é alocado com malloc (libere com free).
rf_patch_result rf_apply_patch(const uint8_t *src, size_t srcLen, const uint8_t *patch, size_t patchLen,
                               uint8_t **out, size_t *outLen);

uint32_t rf_crc32(const uint8_t *data, size_t len);

#endif
