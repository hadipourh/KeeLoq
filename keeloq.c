#include "keeloq.h"

char nlf(int d)
{
    return (NLF_LOOKUP_CONSTANT >> d) & 0x1;
}

void keeloq_encrypt(uint64_t *key, uint32_t *plaintext, uint32_t *ciphertext, int nrounds)
{    
    *ciphertext = *plaintext;
    char out, xor, nlf_input;
    for (int i = 0; i < nrounds; i++)
    {
        nlf_input = (((*ciphertext >> 31) & 0x1) << 4) | (((*ciphertext >> 26) & 0x1) << 3) |
                    (((*ciphertext >> 20) & 0x1) << 2) | (((*ciphertext >> 9) & 0x1) << 1) | ((*ciphertext >> 1) & 0x1);
        out = nlf(nlf_input);
        xor = ((*key >> (i % 64)) & 0x1) ^ ((*ciphertext >> 16) & 0x1) ^ (*ciphertext & 0x1) ^ out;
        *ciphertext = (*ciphertext >> 1) | (xor << 31);
    }    
}

void keeloq_decrypt(uint64_t *key, uint32_t *plaintext, uint32_t *ciphertext, int nrounds)
{
    *plaintext = *ciphertext;    
    char out, xor, nlf_input;
    for (int i = 0; i < nrounds; i++)
    {
        nlf_input = (((*plaintext >> 30) & 0x1) << 4) | (((*plaintext >> 25) & 0x1) << 3) |
                    (((*plaintext >> 19) & 0x1) << 2) | (((*plaintext >> 8) & 0x1) << 1) | (*plaintext & 0x1);
        out = nlf(nlf_input);
        xor = ((*key >> ((15 - i) % 64)) & 0x1) ^ ((*plaintext >> 31) & 0x1) ^ ((*plaintext >> 15) & 0x1) ^ out;
        *plaintext = (*plaintext << 1) | xor;
    }    
}