#ifndef MITM_GENERALIZED_H
#define MITM_GENERALIZED_H

#include <stdint.h>
#include <stddef.h>

#define MITM_NUM_PAIRS (1u << 16)
#define MITM_MAX_ENUM  (1u << 12)

typedef struct {
    int tp;
    int tc;
    int to;
    int chosen_plaintext_mode;
    uint32_t cp_mask;
    uint32_t cp_value;
} MitmProfile;

typedef struct {
    uint32_t pstar;
    uint64_t k3_bits;
    uint64_t k3_mask;
    uint32_t ystar;
    uint32_t j;
} RightRecord;

uint32_t mitm_enc_rounds(uint64_t key, uint32_t s, int ki, int nrounds);
uint32_t mitm_dec_rounds(uint64_t key, uint32_t s, int ki, int nrounds);
uint32_t mitm_keeloq_enc_full(uint64_t key, uint32_t pt);

uint64_t mitm_extract_key_bits(uint32_t a, uint32_t b, int start, int t);
uint64_t mitm_range_mask(int start, int t);

int mitm_build_pstar_candidates(uint32_t pj, uint32_t overlap, int tc, int to,
                                uint32_t *out, int out_cap);
int mitm_build_xstar_candidates(uint32_t xi, uint32_t overlap, int tp, int to,
                                uint32_t *out, int out_cap);

int mitm_get_chosen_overlap_reduction(const MitmProfile *profile,
                                      uint32_t *reduced_guess_space,
                                      uint32_t *fixed_overlap_high_bits);

int mitm_validate_profile(MitmProfile *profile, char *err_buf, size_t err_len);

#endif