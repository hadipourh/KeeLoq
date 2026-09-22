/*
 * mitm_gpu_cp2013.cu — KeeLoq chosen-profile GPU specialization (tp=20, tc=13, to=17)
 *
 * Fixed-profile CUDA implementation for plan profile #3.
 * Profile properties:
 *   - tp > to  => left multiplicity (2^(tp-to) = 8 X*_i candidates)
 *   - tc < to  => right side is constrained/rejected (0 or 1 P*_j candidate)
 *
 * Validation flags:
 *   --pairs-log2 N       (8..16)
 *   --inject-slid-pair
 *   --max-k0 N
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <cuda_runtime.h>

#define PROFILE_TP 20
#define PROFILE_TC 13
#define PROFILE_TO 17

#define K3_START ((64 - PROFILE_TC) & 63)
#define MID_START ((16 + PROFILE_TP) & 63)
#define MID_T     (48 - PROFILE_TP - PROFILE_TC)

#define OVERLAP_SPACE (1u << PROFILE_TO)
#define OVERLAP_MASK  (OVERLAP_SPACE - 1u)
#define K0_SPACE      (1u << 16)

#define DEFAULT_BLOCK_DIM 256
#define HT_BUCKETS  OVERLAP_SPACE

#ifndef ENABLE_GPU_STATS
#define ENABLE_GPU_STATS 0
#endif

#ifndef K0_BATCH
#define K0_BATCH    32
#endif

#ifndef OV_BATCH
#define OV_BATCH    1
#endif

#define NLF_CONST 0x3A5C742EU

#define CUDA_CHECK(call) do { \
    cudaError_t _e = (call); \
    if (_e != cudaSuccess) { \
        fprintf(stderr, "CUDA error at %s:%d — %s\n", __FILE__, __LINE__, cudaGetErrorString(_e)); \
        exit(1); \
    } \
} while (0)

__device__ __forceinline__
uint32_t dec_one_round(uint64_t key, uint32_t sp, int ki)
{
    uint8_t nlf_idx = (uint8_t)(
        ((sp >> 30) & 1u) << 4 | ((sp >> 25) & 1u) << 3 |
        ((sp >> 19) & 1u) << 2 | ((sp >> 8) & 1u) << 1 |
        ((sp >> 0) & 1u)
    );
    uint8_t bit0 = ((sp >> 31) & 1u)
                 ^ ((NLF_CONST >> nlf_idx) & 1u)
                 ^ ((uint8_t)(key >> ki) & 1u)
                 ^ ((sp >> 15) & 1u);
    return ((sp << 1) & 0xFFFFFFFEu) | (uint32_t)bit0;
}

__device__ __forceinline__
uint32_t enc_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
{
    for (int i = 0; i < nrounds; i++) {
        uint8_t nlf_idx = (uint8_t)(
            ((s >> 31) & 1u) << 4 | ((s >> 26) & 1u) << 3 |
            ((s >> 20) & 1u) << 2 | ((s >> 9) & 1u) << 1 |
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

__device__ __forceinline__
uint32_t dec_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
{
    for (int i = nrounds - 1; i >= 0; i--) {
        s = dec_one_round(key, s, (ki + i) & 63);
    }
    return s;
}

__device__ __forceinline__
uint32_t keeloq_enc_full(uint64_t key, uint32_t pt)
{
    return enc_rounds(key, pt, 0, 528);
}

__device__ __forceinline__
uint64_t extract_key_bits(uint32_t A, uint32_t B, int start, int t)
{
    uint64_t kbits = 0;
    uint32_t s = A;
    for (int i = 0; i < t; i++) {
        uint8_t fb = (B >> (32 - t + i)) & 1u;
        uint8_t nlf_idx = (uint8_t)(
            ((s >> 31) & 1u) << 4 | ((s >> 26) & 1u) << 3 |
            ((s >> 20) & 1u) << 2 | ((s >> 9) & 1u) << 1 |
            ((s >> 1) & 1u)
        );
        uint8_t ki_bit = fb
                       ^ ((NLF_CONST >> nlf_idx) & 1u)
                       ^ ((s >> 16) & 1u)
                       ^ (s & 1u);
        kbits |= ((uint64_t)ki_bit << ((start + i) & 63));
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return kbits;
}

/*
 * One step of the extract_key_bits() recurrence, factored out so the two K2
 * paths can be run in lockstep.  Consumes feedback bit i of B (a window of
 * width t at the top of B), returns the recovered key bit, advances *s.
 */
__device__ __forceinline__
uint8_t extract_step(uint32_t *s, uint32_t B, int i, int t)
{
    uint8_t fb = (B >> (32 - t + i)) & 1u;
    uint8_t nlf_idx = (uint8_t)(
        ((*s >> 31) & 1u) << 4 | ((*s >> 26) & 1u) << 3 |
        ((*s >> 20) & 1u) << 2 | ((*s >>  9) & 1u) << 1 |
        ((*s >>  1) & 1u)
    );
    uint8_t k_bit = fb
                  ^ ((NLF_CONST >> nlf_idx) & 1u)
                  ^ ((*s >> 16) & 1u)
                  ^ (*s & 1u);
    *s = (*s >> 1) | ((uint32_t)fb << 31);
    return k_bit;
}

/*
 * Middle-chunk agreement test with early abort.
 *
 * The candidate is accepted only if the ciphertext path and the plaintext path
 * recover the same t middle key bits.  The two extractions run interleaved and
 * stop at the first disagreeing bit: a wrong candidate disagrees on the very
 * first bit half the time, so this costs about 4 rounds instead of 2*t.
 *
 * That matters because this is the hot path of the probe kernel.  The overlap
 * filter is only t_o bits wide, so each probe walks several chain entries on
 * average (8 for the 15/15/14 profile) and this test runs on every one.
 *
 * On agreement *mid_out receives the middle key bits, placed at the same bit
 * positions extract_key_bits(cstar, ystar, start, t) uses; on mismatch it is
 * left untouched.
 */
__device__ __forceinline__
bool mid_bits_agree(uint32_t cstar, uint32_t ystar,
                    uint32_t xstar, uint32_t pstar,
                    int start, int t, uint64_t *mid_out)
{
    uint32_t sc = cstar, sp = xstar;
    uint64_t mid = 0;
    for (int i = 0; i < t; i++) {
        uint8_t bit_c = extract_step(&sc, ystar, i, t);
        uint8_t bit_p = extract_step(&sp, pstar, i, t);
        if (bit_c != bit_p) return false;
        mid |= ((uint64_t)bit_c << ((start + i) & 63));
    }
    *mid_out = mid;
    return true;
}

__device__ __forceinline__
int build_pstar_candidate(uint32_t pj, uint32_t ov, uint32_t *pstar_out)
{
    /* Reject when the overlap bits that straddle tc..to-1 don't match pj.
     * Bits [tc..to-1] of P* come from pj[0..to-tc-1], but ov also
     * prescribes those same bit positions — they must agree.             */
    uint32_t check_bits = PROFILE_TO - PROFILE_TC;          /* 4 */
    if (((pj ^ (ov >> PROFILE_TC)) & ((1u << check_bits) - 1u)) != 0)
        return 0;

    /* P*[31:tc] = pj[18:0],  P*[tc-1:0] = ov[tc-1:0]                 */
    *pstar_out = ((pj & ((1u << (32 - PROFILE_TC)) - 1u)) << PROFILE_TC)
               | (ov & ((1u << PROFILE_TC) - 1u));
    return 1;
}

__device__ __forceinline__
uint32_t make_xstar_candidate(uint32_t xi, uint32_t ov, uint32_t free_bits)
{
    /* X*[11:0]  = xi[31:20]   (low part, from the encryption output)  */
    uint32_t low  = (xi >> PROFILE_TP)
                  & ((1u << (32 - PROFILE_TP)) - 1u);
    /* X*[31:15] = ov[16:0]    (overlap window, 17 bits)               */
    uint32_t high = (ov & ((1u << PROFILE_TO) - 1u))
                  << (32 - PROFILE_TO);
    /* X*[14:12] = free_bits[2:0] (tp−to = 3 free bits)                */
    uint32_t mid  = (free_bits & ((1u << (PROFILE_TP - PROFILE_TO)) - 1u))
                  << (32 - PROFILE_TP);
    return low | mid | high;
}

struct DevHTEntry {
    uint32_t ystar;
    uint32_t pstar;
    uint32_t k3_bits;
};

static_assert(sizeof(DevHTEntry) == 12, "DevHTEntry must remain bandwidth-efficient");

#define HT_EMPTY (-1)

__device__ int d_found = 0;
__device__ uint32_t d_key_lo = 0;
__device__ uint32_t d_key_hi = 0;
__device__ uint32_t d_k0_found = 0;
__device__ unsigned long long d_right_candidates = 0;
__device__ unsigned long long d_left_candidates = 0;
__device__ unsigned long long d_verify_tries = 0;

__global__ void compute_XY_kernel(
    const uint32_t *__restrict__ d_P,
    const uint32_t *__restrict__ d_C,
    uint32_t *__restrict__ d_X,
    uint32_t *__restrict__ d_Y,
    uint32_t k0_batch_start,
    uint32_t k0_batch_size,
    uint32_t N)
{
    if (d_found) return;
    uint32_t k0_idx = blockIdx.x;
    if (k0_idx >= k0_batch_size) return;

    uint32_t i = (uint32_t)blockIdx.y * blockDim.x + threadIdx.x;
    if (i >= N) return;

    uint64_t kk0 = (uint64_t)(k0_batch_start + k0_idx);
    uint32_t *X = d_X + (size_t)k0_idx * N;
    uint32_t *Y = d_Y + (size_t)k0_idx * N;

    X[i] = enc_rounds(kk0, d_P[i], 0, 16);
    Y[i] = dec_rounds(kk0, d_C[i], 0, 16);
}

__global__ void build_ht_kernel(
    const uint32_t *__restrict__ d_P,
    const uint32_t *__restrict__ d_Y,
    DevHTEntry *__restrict__ d_ht,
    int32_t *__restrict__ d_ht_next,
    int32_t *__restrict__ d_ht_head,
    uint32_t k0_batch_size,
    uint32_t N,
    uint32_t ov_start,
    uint32_t ov_batch_size)
{
    if (d_found) return;
    uint32_t k0_idx = blockIdx.x;
    if (k0_idx >= k0_batch_size) return;

    uint32_t j = (uint32_t)blockIdx.y * blockDim.x + threadIdx.x;
    if (j >= N) return;

    uint32_t ov_off = blockIdx.z;
    if (ov_off >= ov_batch_size) return;
    uint32_t ov = ov_start + ov_off;
    if (ov >= OVERLAP_SPACE) return;

    const uint32_t *Y = d_Y + (size_t)k0_idx * N;
    uint32_t pj = d_P[j];
    uint32_t batch_idx = k0_idx * ov_batch_size + ov_off;

    uint32_t pstar;
    if (!build_pstar_candidate(pj, ov, &pstar)) {
        return;
    }

    uint64_t k3 = extract_key_bits(pstar, pj, K3_START, PROFILE_TC);
    uint32_t ystar = dec_rounds(k3, Y[j], K3_START, PROFILE_TC);
#if ENABLE_GPU_STATS
    atomicAdd(&d_right_candidates, 1ULL);
#endif

    uint32_t rec_idx = batch_idx * N + j;
    uint32_t bucket = ystar & OVERLAP_MASK;
    DevHTEntry *e = &d_ht[rec_idx];
    e->ystar = ystar;
    e->pstar = pstar;
    e->k3_bits = (uint32_t)(k3 >> K3_START);

    int32_t *head_ptr = &d_ht_head[(size_t)batch_idx * HT_BUCKETS + bucket];
    int32_t prev = atomicExch(head_ptr, (int32_t)rec_idx);
    d_ht_next[rec_idx] = prev;
}

__global__ void probe_ht_kernel(
    const uint32_t *__restrict__ d_P,
    const uint32_t *__restrict__ d_C,
    const uint32_t *__restrict__ d_X,
    const DevHTEntry *__restrict__ d_ht,
    const int32_t *__restrict__ d_ht_next,
    const int32_t *__restrict__ d_ht_head,
    uint32_t k0_batch_start,
    uint32_t k0_batch_size,
    uint32_t N,
    uint32_t ov_start,
    uint32_t ov_batch_size)
{
    if (d_found) return;
    uint32_t k0_idx = blockIdx.x;
    if (k0_idx >= k0_batch_size) return;

    uint32_t i = (uint32_t)blockIdx.y * blockDim.x + threadIdx.x;
    if (i >= N) return;

    uint32_t ov_off = blockIdx.z;
    if (ov_off >= ov_batch_size) return;
    uint32_t ov = ov_start + ov_off;
    if (ov >= OVERLAP_SPACE) return;

    uint64_t kk0 = (uint64_t)(k0_batch_start + k0_idx);
    const uint32_t *X = d_X + (size_t)k0_idx * N;
    uint32_t xi = X[i];
    uint32_t batch_idx = k0_idx * ov_batch_size + ov_off;

    for (uint32_t free_bits = 0; free_bits < (1u << (PROFILE_TP - PROFILE_TO)); free_bits++) {
        uint32_t xstar = make_xstar_candidate(xi, ov, free_bits);
        uint64_t k1 = extract_key_bits(xi, xstar, 16, PROFILE_TP);
        uint32_t cstar = enc_rounds(k1, d_C[i], 16, PROFILE_TP);
    #if ENABLE_GPU_STATS
        atomicAdd(&d_left_candidates, 1ULL);
    #endif

        uint32_t probe = (cstar >> (32 - PROFILE_TO)) & OVERLAP_MASK;
        for (int32_t rec_idx = d_ht_head[(size_t)batch_idx * HT_BUCKETS + probe];
             rec_idx != HT_EMPTY;
             rec_idx = d_ht_next[rec_idx]) {
            const DevHTEntry *e = &d_ht[rec_idx];

            uint64_t k3 = (uint64_t)e->k3_bits << K3_START;
            uint64_t mid_mask = (((uint64_t)1u << MID_T) - 1u) << MID_START;
            uint64_t mid_c;
            if (!mid_bits_agree(cstar, e->ystar, xstar, e->pstar, MID_START, MID_T, &mid_c)) continue;

            uint64_t cand = kk0 | k1 | k3 | (mid_c & mid_mask);

#if ENABLE_GPU_STATS
            atomicAdd(&d_verify_tries, 1ULL);
#endif
            if (keeloq_enc_full(cand, d_P[0]) != d_C[0]) continue;
            if (keeloq_enc_full(cand, d_P[1]) != d_C[1]) continue;

            if (atomicCAS(&d_found, 0, 1) == 0) {
                d_key_lo = (uint32_t)(cand & 0xFFFFFFFFu);
                d_key_hi = (uint32_t)(cand >> 32);
                d_k0_found = (uint32_t)kk0;
            }
            return;
        }
    }
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t cpu_enc_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
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

static uint32_t cpu_enc_full(uint64_t key, uint32_t pt)
{
    return cpu_enc_rounds(key, pt, 0, 528);
}

static uint32_t cpu_enc_64(uint64_t key, uint32_t pt)
{
    return cpu_enc_rounds(key, pt, 0, 64);
}

static void print_usage(const char *prog)
{
    printf("Usage: %s [key_hex|random] [--pairs-log2 N] [--inject-slid-pair] [--max-k0 N] [--block-dim N]\n", prog);
}

static int pick_launch_block_size(void)
{
    int min_grid = 0;
    int candidates[3] = {0, 0, 0};
    cudaError_t errors[3];

    errors[0] = cudaOccupancyMaxPotentialBlockSize(
        &min_grid, &candidates[0], compute_XY_kernel, 0, 0);
    errors[1] = cudaOccupancyMaxPotentialBlockSize(
        &min_grid, &candidates[1], build_ht_kernel, 0, 0);
    errors[2] = cudaOccupancyMaxPotentialBlockSize(
        &min_grid, &candidates[2], probe_ht_kernel, 0, 0);

    int block_size = DEFAULT_BLOCK_DIM;
    for (int i = 0; i < 3; i++) {
        if (errors[i] == cudaSuccess && candidates[i] > 0 && candidates[i] < block_size) {
            block_size = candidates[i];
        }
    }
    block_size = (block_size / 32) * 32;
    if (block_size < 64) block_size = 64;
    if (block_size > 1024) block_size = 1024;
    return block_size;
}

int main(int argc, char **argv)
{
    uint64_t true_key = 0x5CEC6701B79FD949ULL;
    uint32_t pairs_log2 = 16;
    int inject_slid_pair = 0;
    uint32_t max_k0 = K0_SPACE;
    int user_block_dim = 0;
    int key_set = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pairs-log2") == 0 && i + 1 < argc) {
            pairs_log2 = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--inject-slid-pair") == 0) {
            inject_slid_pair = 1;
        } else if (strcmp(argv[i], "--max-k0") == 0 && i + 1 < argc) {
            max_k0 = (uint32_t)strtoul(argv[++i], NULL, 10);
            if (max_k0 > K0_SPACE) max_k0 = K0_SPACE;
        } else if (strcmp(argv[i], "--block-dim") == 0 && i + 1 < argc) {
            user_block_dim = atoi(argv[++i]);
        } else if (strcmp(argv[i], "random") == 0 || strcmp(argv[i], "-r") == 0) {
            FILE *fp = fopen("/dev/urandom", "rb");
            if (fp) {
                if (fread(&true_key, 8, 1, fp) != 1) {
                    srand((unsigned)time(NULL));
                    true_key = ((uint64_t)rand() << 32) ^ (uint64_t)rand();
                }
                fclose(fp);
            }
            key_set = 1;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (!key_set && argv[i][0] != '-') {
            true_key = strtoull(argv[i], NULL, 16);
            key_set = 1;
        } else {
            fprintf(stderr, "Unknown arg: %s\n", argv[i]);
            print_usage(argv[0]);
            return 2;
        }
    }

    if (pairs_log2 < 8 || pairs_log2 > 16) {
        fprintf(stderr, "--pairs-log2 must be in [8,16]\n");
        return 2;
    }
    if (user_block_dim != 0) {
        if (user_block_dim < 64 || user_block_dim > 1024 || (user_block_dim % 32) != 0) {
            fprintf(stderr, "--block-dim must be 0 (auto) or a multiple of 32 in [64,1024]\n");
            return 2;
        }
    }
    uint32_t pair_count = 1u << pairs_log2;
    uint32_t alloc_k0_batch = K0_BATCH < max_k0 ? K0_BATCH : max_k0;

    int dev = 0;
    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, dev));

    printf("KeeLoq chosen-profile Slide+MitM — GPU profile 20/13/17\n");
    printf("GPU : %s (SM %d.%d, %d SMs)\n", prop.name, prop.major, prop.minor, prop.multiProcessorCount);
    printf("pairs: 2^%u (%u) | max_k0: %u | inject_slid=%s\n", pairs_log2, pair_count, max_k0, inject_slid_pair ? "yes" : "no");
    printf("key  : %016llx\n\n", (unsigned long long)true_key);

    int launch_block_size = user_block_dim ? user_block_dim : pick_launch_block_size();
    if (launch_block_size > prop.maxThreadsPerBlock) {
        launch_block_size = (prop.maxThreadsPerBlock / 32) * 32;
        if (launch_block_size < 32) launch_block_size = prop.maxThreadsPerBlock;
    }
    printf("launch block: %d (%s)\n", launch_block_size, user_block_dim ? "user" : "auto");
    printf("gpu stats   : %s\n\n", ENABLE_GPU_STATS ? "on" : "off");

    int progress_single_line = isatty(fileno(stdout));

    uint32_t *h_P = (uint32_t *)malloc((size_t)pair_count * sizeof(uint32_t));
    uint32_t *h_C = (uint32_t *)malloc((size_t)pair_count * sizeof(uint32_t));
    if (!h_P || !h_C) {
        fprintf(stderr, "OOM host pair buffers\n");
        free(h_P); free(h_C);
        return 1;
    }

    srand(42);
    for (uint32_t i = 0; i < pair_count; i++) {
        h_P[i] = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
        h_C[i] = cpu_enc_full(true_key, h_P[i]);
    }
    if (inject_slid_pair && pair_count >= 2) {
        uint32_t p0 = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
        uint32_t p1 = cpu_enc_64(true_key, p0);
        h_P[0] = p0;
        h_C[0] = cpu_enc_full(true_key, p0);
        h_P[1] = p1;
        h_C[1] = cpu_enc_full(true_key, p1);
    }

    uint32_t *d_P = NULL, *d_C = NULL, *d_X = NULL, *d_Y = NULL;
    DevHTEntry *d_ht = NULL;
    int32_t *d_ht_next = NULL, *d_ht_head = NULL;

    size_t pair_bytes = (size_t)pair_count * sizeof(uint32_t);
    size_t XY_bytes = (size_t)alloc_k0_batch * pair_count * sizeof(uint32_t);
    size_t ht_records = (size_t)alloc_k0_batch * OV_BATCH * pair_count;
    size_t ht_bytes = ht_records * sizeof(DevHTEntry);
    size_t next_bytes = ht_records * sizeof(int32_t);
    size_t head_bytes = (size_t)alloc_k0_batch * OV_BATCH * HT_BUCKETS * sizeof(int32_t);
    size_t total_dev_bytes = pair_bytes * 2 + XY_bytes * 2 + ht_bytes + next_bytes + head_bytes;

    if (ht_records > (size_t)INT32_MAX + 1u) {
        fprintf(stderr, "Batch geometry exceeds the exact int32 hash-chain index limit. Reduce K0_BATCH or OV_BATCH.\n");
        free(h_P); free(h_C);
        return 2;
    }
    size_t memory_reserve = prop.totalGlobalMem / 20u;
    if (total_dev_bytes > prop.totalGlobalMem - memory_reserve) {
        fprintf(stderr, "GPU buffers need %.2f GiB; reduce K0_BATCH or OV_BATCH.\n",
                (double)total_dev_bytes / (1024.0 * 1024.0 * 1024.0));
        free(h_P); free(h_C);
        return 2;
    }

    CUDA_CHECK(cudaMalloc(&d_P, pair_bytes));
    CUDA_CHECK(cudaMalloc(&d_C, pair_bytes));
    CUDA_CHECK(cudaMalloc(&d_X, XY_bytes));
    CUDA_CHECK(cudaMalloc(&d_Y, XY_bytes));
    CUDA_CHECK(cudaMalloc(&d_ht, ht_bytes));
    CUDA_CHECK(cudaMalloc(&d_ht_next, next_bytes));
    CUDA_CHECK(cudaMalloc(&d_ht_head, head_bytes));

    CUDA_CHECK(cudaMemcpy(d_P, h_P, pair_bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_C, h_C, pair_bytes, cudaMemcpyHostToDevice));
    int zero = 0;
    uint32_t zero_u32 = 0;
    CUDA_CHECK(cudaMemcpyToSymbol(d_found, &zero, sizeof(int)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_key_lo, &zero_u32, sizeof(uint32_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_key_hi, &zero_u32, sizeof(uint32_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_k0_found, &zero_u32, sizeof(uint32_t)));
#if ENABLE_GPU_STATS
    unsigned long long zero_u64 = 0;
    CUDA_CHECK(cudaMemcpyToSymbol(d_right_candidates, &zero_u64, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_left_candidates, &zero_u64, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_verify_tries, &zero_u64, sizeof(unsigned long long)));
#endif

    uint32_t n_pair_blocks = (pair_count + (uint32_t)launch_block_size - 1u) / (uint32_t)launch_block_size;
    dim3 block((uint32_t)launch_block_size);

    double t0 = now_s();
    int h_found = 0;
    uint32_t h_key_lo = 0, h_key_hi = 0, h_k0_found = 0;
#if ENABLE_GPU_STATS
    unsigned long long h_right_candidates = 0;
    unsigned long long h_left_candidates = 0;
    unsigned long long h_verify_tries = 0;
#endif

    for (uint32_t k0_start = 0; k0_start < max_k0 && !h_found; k0_start += K0_BATCH) {
        uint32_t batch_sz = K0_BATCH;
        if (k0_start + batch_sz > max_k0) batch_sz = max_k0 - k0_start;

        dim3 grid_xy(batch_sz, n_pair_blocks);
        compute_XY_kernel<<<grid_xy, block>>>(d_P, d_C, d_X, d_Y, k0_start, batch_sz, pair_count);

        for (uint32_t ov_start = 0; ov_start < OVERLAP_SPACE && !h_found; ov_start += OV_BATCH) {
            uint32_t ov_batch_sz = OV_BATCH;
            if (ov_start + ov_batch_sz > OVERLAP_SPACE) ov_batch_sz = OVERLAP_SPACE - ov_start;

            size_t active_head_bytes = (size_t)batch_sz * ov_batch_sz * HT_BUCKETS * sizeof(int32_t);
            CUDA_CHECK(cudaMemsetAsync(d_ht_head, 0xFF, active_head_bytes));

            dim3 grid3d(batch_sz, n_pair_blocks, ov_batch_sz);
            build_ht_kernel<<<grid3d, block>>>(d_P, d_Y, d_ht, d_ht_next, d_ht_head, batch_sz, pair_count, ov_start, ov_batch_sz);
            probe_ht_kernel<<<grid3d, block>>>(d_P, d_C, d_X, d_ht, d_ht_next, d_ht_head, k0_start, batch_sz, pair_count, ov_start, ov_batch_sz);

            if (((ov_start + ov_batch_sz) & 0x3FFu) < OV_BATCH) {
                CUDA_CHECK(cudaMemcpyFromSymbol(&h_found, d_found, sizeof(int)));
            }
        }

        if (!h_found) {
            CUDA_CHECK(cudaMemcpyFromSymbol(&h_found, d_found, sizeof(int)));
        }

        if ((max_k0 <= 1024u) || ((k0_start & 0xFFu) == 0)) {
            double elapsed = now_s() - t0;
            double pct = max_k0 ? (double)(k0_start + batch_sz) / max_k0 : 1.0;
            double eta = (pct > 0.001) ? elapsed * (1.0 - pct) / pct : 0;
            if (progress_single_line) {
                printf("\rk0: %5u / %u [%.1f%%] %.0fs elapsed, ETA %.0fs", k0_start + batch_sz, max_k0, pct * 100.0, elapsed, eta);
            } else {
                printf("k0: %5u / %u [%.1f%%] %.0fs elapsed, ETA %.0fs\n", k0_start + batch_sz, max_k0, pct * 100.0, elapsed, eta);
            }
            fflush(stdout);
        }
    }

    double elapsed = now_s() - t0;
#if ENABLE_GPU_STATS
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_right_candidates, d_right_candidates, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_left_candidates, d_left_candidates, sizeof(unsigned long long)));
    CUDA_CHECK(cudaMemcpyFromSymbol(&h_verify_tries, d_verify_tries, sizeof(unsigned long long)));
#endif
    printf("\n");

    if (h_found) {
        CUDA_CHECK(cudaMemcpyFromSymbol(&h_key_lo, d_key_lo, sizeof(uint32_t)));
        CUDA_CHECK(cudaMemcpyFromSymbol(&h_key_hi, d_key_hi, sizeof(uint32_t)));
        CUDA_CHECK(cudaMemcpyFromSymbol(&h_k0_found, d_k0_found, sizeof(uint32_t)));
        uint64_t rec_key = ((uint64_t)h_key_hi << 32) | h_key_lo;
        printf("Recovered key : %016llx\n", (unsigned long long)rec_key);
        printf("True key      : %016llx\n", (unsigned long long)true_key);
        printf("k0 found      : %u\n", h_k0_found);
        printf("Match         : %s\n", rec_key == true_key ? "YES" : "NO");
    } else {
        printf("No key found in scanned range/profile.\n");
    }
#if ENABLE_GPU_STATS
    printf("Right cand : %llu\n", h_right_candidates);
    printf("Left cand  : %llu\n", h_left_candidates);
    printf("Verify tries : %llu\n", h_verify_tries);
#else
    printf("GPU stats  : disabled (build with -DENABLE_GPU_STATS=1 to enable counters)\n");
#endif
    printf("Device mem : %.1f MB\n", (double)total_dev_bytes / (1024.0 * 1024.0));
    printf("Total time: %.2f s\n", elapsed);
    printf("Wall time : %.2f s\n", elapsed);

    cudaFree(d_P); cudaFree(d_C); cudaFree(d_X); cudaFree(d_Y);
    cudaFree(d_ht); cudaFree(d_ht_next); cudaFree(d_ht_head);
    free(h_P); free(h_C);
    return h_found ? 0 : 1;
}
