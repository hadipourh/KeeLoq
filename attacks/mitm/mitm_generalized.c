#include "mitm_generalized.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>

#define NLF_CONST 0x3A5C742EU
#define DEFAULT_KEY 0x5CEC6701B79FD949ULL
#define BRUTEFORCE_UNKNOWN_LIMIT 20

typedef struct {
    int32_t head;
    uint32_t gen;
} BucketHead;

static inline uint8_t nlf_bit(uint32_t s)
{
    uint8_t idx = (uint8_t)(
        ((s >> 31) & 1u) << 4 |
        ((s >> 26) & 1u) << 3 |
        ((s >> 20) & 1u) << 2 |
        ((s >> 9) & 1u) << 1 |
        ((s >> 1) & 1u)
    );
    return (NLF_CONST >> idx) & 1u;
}

static inline uint32_t keeloq_dec_one_round(uint64_t key, uint32_t sp, int ki)
{
    uint8_t nlf_idx = (uint8_t)(
        ((sp >> 30) & 1u) << 4 |
        ((sp >> 25) & 1u) << 3 |
        ((sp >> 19) & 1u) << 2 |
        ((sp >> 8) & 1u) << 1 |
        ((sp >> 0) & 1u)
    );
    uint8_t bit0 = ((sp >> 31) & 1u)
                 ^ ((NLF_CONST >> nlf_idx) & 1u)
                 ^ ((uint8_t)(key >> ki) & 1u)
                 ^ ((sp >> 15) & 1u);
    return ((sp << 1) & 0xFFFFFFFEu) | (uint32_t)bit0;
}

uint32_t mitm_enc_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
{
    for (int i = 0; i < nrounds; i++) {
        uint8_t nlf_idx = (uint8_t)(
            ((s >> 31) & 1u) << 4 |
            ((s >> 26) & 1u) << 3 |
            ((s >> 20) & 1u) << 2 |
            ((s >> 9) & 1u) << 1 |
            ((s >> 1) & 1u)
        );
        uint8_t fb = ((NLF_CONST >> nlf_idx) & 1u)
                   ^ ((uint8_t)(key >> ((ki + i) & 63)) & 1u)
                   ^ ((s >> 16) & 1u)
                   ^ (s & 1u);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return s;
}

uint32_t mitm_dec_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
{
    for (int i = nrounds - 1; i >= 0; i--) {
        s = keeloq_dec_one_round(key, s, (ki + i) & 63);
    }
    return s;
}

uint32_t mitm_keeloq_enc_full(uint64_t key, uint32_t pt)
{
    return mitm_enc_rounds(key, pt, 0, 528);
}

uint64_t mitm_range_mask(int start, int t)
{
    uint64_t mask = 0;
    for (int i = 0; i < t; i++) {
        mask |= (uint64_t)1u << ((start + i) & 63);
    }
    return mask;
}

uint64_t mitm_extract_key_bits(uint32_t a, uint32_t b, int start, int t)
{
    uint64_t kbits = 0;
    uint32_t s = a;
    for (int i = 0; i < t; i++) {
        uint8_t fb = (b >> (32 - t + i)) & 1u;
        uint8_t ki_bit = fb
                       ^ nlf_bit(s)
                       ^ ((s >> 16) & 1u)
                       ^ (s & 1u);
        int pos = (start + i) & 63;
        kbits |= ((uint64_t)ki_bit << pos);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return kbits;
}

static inline int bit_at(uint32_t x, int pos)
{
    return (x >> pos) & 1u;
}

static inline uint32_t set_bit(uint32_t x, int pos, int val)
{
    if (val) {
        return x | ((uint32_t)1u << pos);
    }
    return x & ~((uint32_t)1u << pos);
}

int mitm_build_pstar_candidates(uint32_t pj, uint32_t overlap, int tc, int to,
                                uint32_t *out, int out_cap)
{
    uint32_t base = 0;
    uint32_t fixed_low_mask = 0;
    uint32_t fixed_low_bits = 0;

    for (int b = tc; b < 32; b++) {
        int v = bit_at(pj, b - tc);
        base = set_bit(base, b, v);
    }

    for (int b = 0; b < to; b++) {
        int want = bit_at(overlap, b);
        if (b < tc) {
            fixed_low_mask = set_bit(fixed_low_mask, b, 1);
            fixed_low_bits = set_bit(fixed_low_bits, b, want);
        } else {
            int have = bit_at(base, b);
            if (have != want) {
                return 0;
            }
        }
    }

    int free_bits = tc - to;
    if (free_bits < 0) {
        free_bits = 0;
    }
    if (free_bits > 20) {
        return 0;
    }

    int count = 1 << free_bits;
    if (count > out_cap) {
        count = out_cap;
    }

    for (int idx = 0; idx < count; idx++) {
        uint32_t pstar = base;
        for (int b = 0; b < tc; b++) {
            if ((fixed_low_mask >> b) & 1u) {
                pstar = set_bit(pstar, b, bit_at(fixed_low_bits, b));
            } else {
                int fb_pos = b - to;
                int val = (idx >> fb_pos) & 1u;
                pstar = set_bit(pstar, b, val);
            }
        }
        out[idx] = pstar;
    }

    return count;
}

int mitm_build_xstar_candidates(uint32_t xi, uint32_t overlap, int tp, int to,
                                uint32_t *out, int out_cap)
{
    uint32_t base = 0;
    uint32_t fixed_high_mask = 0;
    uint32_t fixed_high_bits = 0;

    for (int b = 0; b <= 31 - tp; b++) {
        int v = bit_at(xi, b + tp);
        base = set_bit(base, b, v);
    }

    int high_start = 32 - tp;
    int ov_start = 32 - to;
    for (int b = ov_start; b < 32; b++) {
        int want = bit_at(overlap, b - ov_start);
        if (b >= high_start) {
            int rel = b - high_start;
            fixed_high_mask = set_bit(fixed_high_mask, rel, 1);
            fixed_high_bits = set_bit(fixed_high_bits, rel, want);
        } else {
            int have = bit_at(base, b);
            if (have != want) {
                return 0;
            }
        }
    }

    int free_bits = tp - to;
    if (free_bits < 0) {
        free_bits = 0;
    }
    if (free_bits > 20) {
        return 0;
    }

    int count = 1 << free_bits;
    if (count > out_cap) {
        count = out_cap;
    }

    for (int idx = 0; idx < count; idx++) {
        uint32_t xstar = base;
        for (int rel = 0; rel < tp; rel++) {
            int b = high_start + rel;
            if ((fixed_high_mask >> rel) & 1u) {
                xstar = set_bit(xstar, b, bit_at(fixed_high_bits, rel));
            } else {
                int fb_pos = rel;
                int val = (idx >> fb_pos) & 1u;
                xstar = set_bit(xstar, b, val);
            }
        }
        out[idx] = xstar;
    }

    return count;
}

int mitm_validate_profile(MitmProfile *profile, char *err_buf, size_t err_len)
{
    if (profile->tp < 1 || profile->tp > 31) {
        snprintf(err_buf, err_len, "tp must be in [1,31]");
        return 0;
    }
    if (profile->tc < 1 || profile->tc > 31) {
        snprintf(err_buf, err_len, "tc must be in [1,31]");
        return 0;
    }
    profile->to = profile->tp + profile->tc - 16;
    if (profile->to < 1 || profile->to > 24) {
        snprintf(err_buf, err_len, "to=tp+tc-16 must be in [1,24] for this reference implementation");
        return 0;
    }
    if ((profile->tp - profile->to) > 20 || (profile->tc - profile->to) > 20) {
        snprintf(err_buf, err_len, "free-bit multiplicity exceeds reference cap (20)");
        return 0;
    }
    return 1;
}

int mitm_get_chosen_overlap_reduction(const MitmProfile *profile,
                                      uint32_t *reduced_guess_space,
                                      uint32_t *fixed_overlap_high_bits)
{
    if (!profile->chosen_plaintext_mode || profile->tc >= profile->to) {
        return 0;
    }

    int fixed_bits = profile->to - profile->tc;
    if (fixed_bits <= 0 || fixed_bits >= 32) {
        return 0;
    }

    uint32_t low_mask = ((uint32_t)1u << fixed_bits) - 1u;
    if ((profile->cp_mask & low_mask) != low_mask) {
        return 0;
    }

    if (reduced_guess_space) {
        *reduced_guess_space = (uint32_t)1u << profile->tc;
    }
    if (fixed_overlap_high_bits) {
        *fixed_overlap_high_bits = (profile->cp_value & low_mask) << profile->tc;
    }
    return 1;
}

#ifndef MITM_GENERALIZED_NO_MAIN

static inline int merge_partial(uint64_t *bits, uint64_t *mask,
                                uint64_t add_bits, uint64_t add_mask)
{
    uint64_t overlap = (*mask) & add_mask;
    if (((*bits ^ add_bits) & overlap) != 0) {
        return 0;
    }
    *bits = (*bits & ~add_mask) | (add_bits & add_mask);
    *mask |= add_mask;
    return 1;
}

static int unknown_positions(uint64_t known_mask, int *positions, int max_pos)
{
    int cnt = 0;
    for (int p = 0; p < 64; p++) {
        if (((known_mask >> p) & 1u) == 0) {
            if (cnt >= max_pos) {
                return -1;
            }
            positions[cnt++] = p;
        }
    }
    return cnt;
}

static inline double now_s(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

static inline uint32_t keeloq_enc_64(uint64_t key, uint32_t pt)
{
    return mitm_enc_rounds(key, pt, 0, 64);
}

static void generate_pairs(uint32_t *p, uint32_t *c, uint64_t key,
                           const MitmProfile *profile,
                           uint32_t pair_count,
                           int inject_slid_pair)
{
    srand(42);
    for (uint32_t i = 0; i < pair_count; i++) {
        uint32_t pt;
        do {
            pt = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
        } while (profile->chosen_plaintext_mode && ((pt & profile->cp_mask) != profile->cp_value));
        p[i] = pt;
        c[i] = mitm_keeloq_enc_full(key, pt);
    }

    if (inject_slid_pair && pair_count >= 2) {
        uint32_t p0 = 0;
        uint32_t p1 = 0;
        int found = 0;

        if (profile->chosen_plaintext_mode) {
            for (uint32_t tries = 0; tries < (1u << 22); tries++) {
                uint32_t cand = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
                if ((cand & profile->cp_mask) != profile->cp_value) {
                    continue;
                }
                uint32_t cand1 = keeloq_enc_64(key, cand);
                if ((cand1 & profile->cp_mask) != profile->cp_value) {
                    continue;
                }
                p0 = cand;
                p1 = cand1;
                found = 1;
                break;
            }
        } else {
            p0 = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
            p1 = keeloq_enc_64(key, p0);
            found = 1;
        }

        if (found) {
            p[0] = p0;
            c[0] = mitm_keeloq_enc_full(key, p0);
            p[1] = p1;
            c[1] = mitm_keeloq_enc_full(key, p1);
        } else {
            fprintf(stderr, "Warning: could not inject chosen-compatible slid pair under cp constraints\n");
        }
    }
}

static void print_usage(const char *prog)
{
    printf("Usage: %s [--tp N] [--tc N] [--key HEX] [--max-k0 N] [--pairs-log2 N] [--inject-slid-pair] [--chosen] [--cp-mask HEX] [--cp-value HEX]\n", prog);
    printf("Defaults: tp=16 tc=16 key=%016llx max-k0=65536 pairs-log2=16\n", (unsigned long long)DEFAULT_KEY);
}

int main(int argc, char **argv)
{
    MitmProfile profile;
    profile.tp = 16;
    profile.tc = 16;
    profile.to = 16;
    profile.chosen_plaintext_mode = 0;
    profile.cp_mask = 0;
    profile.cp_value = 0;

    uint64_t true_key = DEFAULT_KEY;
    uint32_t max_k0 = 65536;
    uint32_t pairs_log2 = 16;
    int inject_slid_pair = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--tp") == 0 && i + 1 < argc) {
            profile.tp = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--tc") == 0 && i + 1 < argc) {
            profile.tc = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--key") == 0 && i + 1 < argc) {
            true_key = strtoull(argv[++i], NULL, 16);
        } else if (strcmp(argv[i], "--max-k0") == 0 && i + 1 < argc) {
            max_k0 = (uint32_t)strtoul(argv[++i], NULL, 10);
            if (max_k0 > 65536u) {
                max_k0 = 65536u;
            }
        } else if (strcmp(argv[i], "--pairs-log2") == 0 && i + 1 < argc) {
            pairs_log2 = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--inject-slid-pair") == 0) {
            inject_slid_pair = 1;
        } else if (strcmp(argv[i], "--chosen") == 0) {
            profile.chosen_plaintext_mode = 1;
        } else if (strcmp(argv[i], "--cp-mask") == 0 && i + 1 < argc) {
            profile.cp_mask = (uint32_t)strtoul(argv[++i], NULL, 16);
        } else if (strcmp(argv[i], "--cp-value") == 0 && i + 1 < argc) {
            profile.cp_value = (uint32_t)strtoul(argv[++i], NULL, 16);
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown arg: %s\n", argv[i]);
            print_usage(argv[0]);
            return 2;
        }
    }

    char err[160] = {0};
    if (!mitm_validate_profile(&profile, err, sizeof(err))) {
        fprintf(stderr, "Invalid profile: %s\n", err);
        return 2;
    }

    if (pairs_log2 < 8 || pairs_log2 > 16) {
        fprintf(stderr, "Invalid --pairs-log2 (must be in [8,16])\n");
        return 2;
    }
    uint32_t pair_count = 1u << pairs_log2;

    uint32_t *p = (uint32_t *)malloc(sizeof(uint32_t) * pair_count);
    uint32_t *c = (uint32_t *)malloc(sizeof(uint32_t) * pair_count);
    uint32_t *x = (uint32_t *)malloc(sizeof(uint32_t) * pair_count);
    uint32_t *y = (uint32_t *)malloc(sizeof(uint32_t) * pair_count);
    if (!p || !c || !x || !y) {
        fprintf(stderr, "OOM while allocating pair buffers\n");
        free(p); free(c); free(x); free(y);
        return 1;
    }

    uint32_t overlap_space = 1u << profile.to;
    uint32_t overlap_mask = overlap_space - 1u;
    uint32_t overlap_guess_space = overlap_space;
    uint32_t chosen_overlap_high_bits = 0;
    int chosen_overlap_reduced = mitm_get_chosen_overlap_reduction(
        &profile, &overlap_guess_space, &chosen_overlap_high_bits);

    uint32_t right_mult = 1u << (profile.tc > profile.to ? (profile.tc - profile.to) : 0);
    if (right_mult == 0) {
        right_mult = 1;
    }
    uint32_t max_right_records = pair_count * right_mult;
    RightRecord *records = (RightRecord *)malloc(sizeof(RightRecord) * max_right_records);
    int32_t *next = (int32_t *)malloc(sizeof(int32_t) * max_right_records);
    BucketHead *buckets = (BucketHead *)calloc(overlap_space, sizeof(BucketHead));
    if (!records || !next || !buckets) {
        fprintf(stderr, "OOM while allocating right-side buffers\n");
        free(p); free(c); free(x); free(y);
        free(records); free(next); free(buckets);
        return 1;
    }

    uint64_t k0_mask = mitm_range_mask(0, 16);
    int k3_start = (64 - profile.tc) & 63;
    uint64_t k1_mask = mitm_range_mask(16, profile.tp);
    int mid_start = (16 + profile.tp) & 63;
    int mid_t = 48 - profile.tp - profile.tc;
    if (mid_t < 1 || mid_t > 31) {
        fprintf(stderr, "Invalid middle window: start=%d len=%d\n", mid_start, mid_t);
        free(p); free(c); free(x); free(y);
        free(records); free(next); free(buckets);
        return 2;
    }
    uint64_t mid_mask = mitm_range_mask(mid_start, mid_t);
    uint64_t k3_mask = mitm_range_mask(k3_start, profile.tc);
    uint64_t k3_unique_mask = k3_mask & ~mid_mask;

    uint32_t pstar_candidates[MITM_MAX_ENUM];
    uint32_t xstar_candidates[MITM_MAX_ENUM];

        generate_pairs(p, c, true_key, &profile, pair_count, inject_slid_pair);

    printf("KeeLoq generalized Slide+MitM reference\n");
    printf("Profile: tp=%d tc=%d to=%d | chosen=%s\n",
           profile.tp, profile.tc, profile.to,
           profile.chosen_plaintext_mode ? "yes" : "no");
    if (chosen_overlap_reduced) {
        printf("Chosen reduction: overlap guesses reduced to 2^%d (fixed upper bits from plaintext structure)\n",
               profile.tc);
    } else if (profile.chosen_plaintext_mode) {
        int fixed_bits = profile.to - profile.tc;
        if (fixed_bits > 0) {
            uint32_t low_mask = ((uint32_t)1u << fixed_bits) - 1u;
            if ((profile.cp_mask & low_mask) != low_mask) {
                printf("Chosen reduction: inactive (cp_mask must fix the lowest %d plaintext bit(s); need cp_mask low mask %0*x)\n",
                       fixed_bits, (fixed_bits + 3) / 4, low_mask);
            } else {
                printf("Chosen reduction: inactive (profile does not satisfy tc < to reduction case)\n");
            }
        } else {
            printf("Chosen reduction: inactive (profile does not satisfy tc < to reduction case)\n");
        }
    }
        printf("Key: %016llx | pairs: 2^%u | max_k0: %u | inject_slid=%s\n",
            (unsigned long long)true_key, pairs_log2, max_k0,
            inject_slid_pair ? "yes" : "no");

    double t0 = now_s();
    uint64_t tested_collisions = 0;
    uint64_t right_records_total = 0;
    uint64_t left_candidates_total = 0;
    uint64_t pstar_total = 0;
    uint64_t xstar_total = 0;

    int found = 0;
    uint64_t recovered = 0;
    uint64_t bucket_gen = 1;

    for (uint32_t k0 = 0; k0 < max_k0 && !found; k0++) {
        uint64_t kk0 = (uint64_t)k0;

        for (uint32_t i = 0; i < pair_count; i++) {
            x[i] = mitm_enc_rounds(kk0, p[i], 0, 16);
            y[i] = mitm_dec_rounds(kk0, c[i], 0, 16);
        }

        for (uint32_t ov_guess = 0; ov_guess < overlap_guess_space && !found; ov_guess++) {
            uint32_t ov = chosen_overlap_reduced ? (ov_guess | chosen_overlap_high_bits) : ov_guess;
            uint32_t rec_count = 0;
            bucket_gen++;
            if (bucket_gen == 0) {
                memset(buckets, 0, sizeof(BucketHead) * overlap_space);
                bucket_gen = 1;
            }

            for (uint32_t j = 0; j < pair_count; j++) {
                int np = mitm_build_pstar_candidates(p[j], ov, profile.tc, profile.to,
                                                     pstar_candidates, MITM_MAX_ENUM);
                pstar_total += (uint64_t)np;
                for (int rp = 0; rp < np; rp++) {
                    if (rec_count >= max_right_records) {
                        break;
                    }
                    uint32_t pstar = pstar_candidates[rp];
                    uint64_t k3_bits = mitm_extract_key_bits(pstar, p[j], k3_start, profile.tc);

                    uint64_t bits = kk0;
                    uint64_t mask = k0_mask;
                    if (!merge_partial(&bits, &mask, k3_bits, k3_mask)) {
                        continue;
                    }

                    uint32_t ystar = mitm_dec_rounds(k3_bits, y[j], k3_start, profile.tc);
                    uint32_t key = ystar & overlap_mask;

                    records[rec_count].pstar = pstar;
                    records[rec_count].k3_bits = k3_bits;
                    records[rec_count].k3_mask = k3_mask;
                    records[rec_count].ystar = ystar;
                    records[rec_count].j = j;

                    if (buckets[key].gen != bucket_gen) {
                        buckets[key].gen = bucket_gen;
                        buckets[key].head = -1;
                    }
                    next[rec_count] = buckets[key].head;
                    buckets[key].head = (int32_t)rec_count;
                    rec_count++;
                }
            }
            right_records_total += rec_count;

            for (uint32_t i = 0; i < pair_count && !found; i++) {
                int nx = mitm_build_xstar_candidates(x[i], ov, profile.tp, profile.to,
                                                     xstar_candidates, MITM_MAX_ENUM);
                xstar_total += (uint64_t)nx;
                left_candidates_total += (uint64_t)nx;

                for (int lx = 0; lx < nx && !found; lx++) {
                    uint32_t xstar = xstar_candidates[lx];
                    uint64_t k1_bits = mitm_extract_key_bits(x[i], xstar, 16, profile.tp);

                    uint64_t bits_l = kk0;
                    uint64_t mask_l = k0_mask;
                    if (!merge_partial(&bits_l, &mask_l, k1_bits, k1_mask)) {
                        continue;
                    }

                    uint32_t cstar = mitm_enc_rounds(k1_bits, c[i], 16, profile.tp);
                    uint32_t probe = (cstar >> (32 - profile.to)) & overlap_mask;
                    if (buckets[probe].gen != bucket_gen) {
                        continue;
                    }

                    for (int32_t idx = buckets[probe].head; idx >= 0 && !found; idx = next[idx]) {
                        RightRecord *rr = &records[idx];
                        tested_collisions++;

                        uint64_t bits = kk0;
                        uint64_t mask = k0_mask;
                        if (!merge_partial(&bits, &mask, k1_bits, k1_mask)) {
                            continue;
                        }
                        if (!merge_partial(&bits, &mask, rr->k3_bits, k3_unique_mask)) {
                            continue;
                        }

                        uint64_t mid_from_c = mitm_extract_key_bits(cstar, rr->ystar, mid_start, mid_t);
                        uint64_t mid_from_p = mitm_extract_key_bits(xstar, rr->pstar, mid_start, mid_t);
                        if (((mid_from_c ^ mid_from_p) & mid_mask) != 0) {
                            continue;
                        }
                        if (!merge_partial(&bits, &mask, mid_from_c, mid_mask)) {
                            continue;
                        }
                        if (!merge_partial(&bits, &mask, mid_from_p, mid_mask)) {
                            continue;
                        }

                        int unknown_pos[64];
                        int unknown = unknown_positions(mask, unknown_pos, 64);
                        if (unknown < 0 || unknown > BRUTEFORCE_UNKNOWN_LIMIT) {
                            continue;
                        }

                        uint64_t combs = 1ULL << unknown;
                        for (uint64_t g = 0; g < combs; g++) {
                            uint64_t cand = bits;
                            for (int u = 0; u < unknown; u++) {
                                uint64_t bit = (g >> u) & 1u;
                                if (bit) {
                                    cand |= (1ULL << unknown_pos[u]);
                                } else {
                                    cand &= ~(1ULL << unknown_pos[u]);
                                }
                            }
                            if (mitm_keeloq_enc_full(cand, p[0]) != c[0]) continue;
                            if (mitm_keeloq_enc_full(cand, p[1]) != c[1]) continue;
                            if (mitm_keeloq_enc_full(cand, p[i]) != c[i]) continue;
                            if (mitm_keeloq_enc_full(cand, p[rr->j]) != c[rr->j]) continue;

                            found = 1;
                            recovered = cand;
                            break;
                        }
                    }
                }
            }
        }

        if ((max_k0 <= 1024u) || ((k0 & 0x3FFu) == 0)) {
            double te = now_s() - t0;
            printf("Progress: k0=%5u/%u, elapsed=%.1fs\r", k0, max_k0, te);
            fflush(stdout);
        }
    }

    double te = now_s() - t0;
    printf("\n");
    printf("right records total: %llu\n", (unsigned long long)right_records_total);
    printf("left candidates total: %llu\n", (unsigned long long)left_candidates_total);
    printf("pstar enum total: %llu\n", (unsigned long long)pstar_total);
    printf("xstar enum total: %llu\n", (unsigned long long)xstar_total);
    printf("tested collisions: %llu\n", (unsigned long long)tested_collisions);

    if (found) {
        printf("Recovered key: %016llx\n", (unsigned long long)recovered);
        printf("True key     : %016llx\n", (unsigned long long)true_key);
        printf("Match        : %s\n", recovered == true_key ? "YES" : "NO");
    } else {
        printf("No key recovered in scanned range/profile.\n");
    }
    printf("Wall time: %.2f s\n", te);

    free(p); free(c); free(x); free(y);
    free(records); free(next); free(buckets);
    return found ? 0 : 1;
}
#endif
