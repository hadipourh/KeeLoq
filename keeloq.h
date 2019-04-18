#ifndef __keeloq_h__
#define __keeloq_h__

#include <stdint.h>

#define nlf_lookup_constant 0x3a5c742e

char nlf(int d);
uint32_t encrypt(uint64_t key, uint32_t plaintext, int nrounds);
uint32_t decrypt(uint64_t key, uint32_t ciphertext, int nrounds);

#endif