#include "keeloq.h"

char nlf(int d)
{
	return (NLF_LOOKUP_CONSTANT >> d) & 0x1;
}

uint32_t keeloq_encrypt(uint64_t key, uint32_t plaintext, int nrounds)
{
	uint32_t dreg = plaintext;
	char out, xor, nlf_input;
	for (int i = 0; i < nrounds; i++)
	{
		nlf_input = (((dreg >> 31) & 0x1) << 4) | (((dreg >> 26) & 0x1) << 3) |
					(((dreg >> 20) & 0x1) << 2) | (((dreg >> 9) & 0x1) << 1) | ((dreg >> 1) & 0x1);
		out = nlf(nlf_input);
		xor = ((key >> (i % 64)) & 0x1) ^ ((dreg >> 16) & 0x1) ^ (dreg & 0x1) ^ out;
		dreg = (dreg >> 1) | (xor << 31);
	}
	return dreg;
}

uint32_t keeloq_decrypt(uint64_t key, uint32_t ciphertext, int nrounds)
{
	uint32_t dreg = ciphertext;
	char out, xor, nlf_input;
	for (int i = 0; i < nrounds; i++)
	{
		nlf_input = (((dreg >> 30) & 0x1) << 4) | (((dreg >> 25) & 0x1) << 3) |
					(((dreg >> 19) & 0x1) << 2) | (((dreg >> 8) & 0x1) << 1) | (dreg & 0x1);
		out = nlf(nlf_input);
		xor = ((key >> ((15 - i) % 64)) & 0x1) ^ ((dreg >> 31) & 0x1) ^ ((dreg >> 15) & 0x1) ^ out;
		dreg = (dreg << 1) | xor;
	}
	return dreg;
}
