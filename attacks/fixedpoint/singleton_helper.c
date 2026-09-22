#include <stdint.h>

#include "keeloq.h"

static inline uint8_t singleton_feedback_bit(uint32_t s_target, uint16_t prefix16, int round_idx)
{
    if (round_idx < 16)
    {
        return (prefix16 >> round_idx) & 1U;
    }
    return (s_target >> (round_idx - 16)) & 1U;
}

static uint64_t singleton_candidate_from_feedback_prefix(uint16_t k16, uint32_t s_target, uint32_t m16, uint16_t prefix16)
{
    uint32_t state = m16;
    uint64_t key = k16;

    for (int i = 0; i < 48; i++)
    {
        uint8_t feedback = singleton_feedback_bit(s_target, prefix16, i);
        uint8_t nlf_input = (((state >> 31) & 1U) << 4) |
                            (((state >> 26) & 1U) << 3) |
                            (((state >> 20) & 1U) << 2) |
                            (((state >> 9) & 1U) << 1) |
                            ((state >> 1) & 1U);
        uint8_t key_bit = feedback ^ ((state >> 16) & 1U) ^ (state & 1U) ^ (uint8_t)nlf(nlf_input);
        key |= ((uint64_t)key_bit) << (16 + i);
        state = (state >> 1) | ((uint32_t)feedback << 31);
    }

    return key;
}

int search_singleton_constructive(uint16_t k16,
                                  uint32_t s_target,
                                  uint32_t m16,
                                  const uint32_t *verify_s,
                                  const uint32_t *verify_c,
                                  int verify_count,
                                  uint64_t *out_key,
                                  uint32_t *prefixes_tested)
{
    if (verify_s == 0 || verify_c == 0 || out_key == 0 || prefixes_tested == 0 || verify_count <= 0)
    {
        return 0;
    }

    for (uint32_t prefix16 = 0; prefix16 < 65536U; prefix16++)
    {
        uint64_t key = singleton_candidate_from_feedback_prefix(k16, s_target, m16, (uint16_t)prefix16);
        uint64_t key_copy = key;
        uint32_t plaintext = verify_s[0];
        uint32_t ciphertext = 0;
        keeloq_encrypt(&key_copy, &plaintext, &ciphertext, 528);
        if (ciphertext != verify_c[0])
        {
            continue;
        }

        int ok = 1;
        for (int i = 1; i < verify_count; i++)
        {
            key_copy = key;
            plaintext = verify_s[i];
            ciphertext = 0;
            keeloq_encrypt(&key_copy, &plaintext, &ciphertext, 528);
            if (ciphertext != verify_c[i])
            {
                ok = 0;
                break;
            }
        }

        if (ok)
        {
            *out_key = key;
            *prefixes_tested = prefix16 + 1U;
            return 1;
        }
    }

    *prefixes_tested = 65536U;
    return 0;
}