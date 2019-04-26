#ifndef __keeloq_h__
#define __keeloq_h__

#include <stdint.h>

#define NLF_LOOKUP_CONSTANT 0x3a5c742e

char nlf(int d);
void keeloq_encrypt(uint64_t *key, uint32_t *plaintext, uint32_t *ciphertext, int nrounds);
void keeloq_decrypt(uint64_t *key, uint32_t *plaintext, uint32_t *ciphertext, int nrounds);

#endif
