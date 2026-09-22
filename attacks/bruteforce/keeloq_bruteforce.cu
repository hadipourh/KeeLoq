/*
 * High-performance CUDA brute-force key recovery for KeeLoq
 *
 * Searches the full 2^64 key space (or a partial space when key bits are
 * fixed) using a waterfall filtering strategy:
 *
 *   Phase 1 — Every candidate key is tested against the FIRST P/C pair.
 *             KeeLoq has a 32-bit block, so ~2^{k-32} false positives survive
 *             (where k = number of free key bits).
 *
 *   Phase 2 — Survivors are immediately tested against the SECOND P/C pair
 *             inside the same kernel (no intermediate storage, no extra
 *             launch overhead).  Two pairs give 64 bits of filtering, which
 *             is sufficient to uniquely identify a 64-bit key with
 *             overwhelming probability.
 *
 * Only 2 P/C pairs are required.  The kernel early-exits after pair 1
 * fails, so the vast majority of threads execute only 528 rounds instead
 * of 1056.  This nearly halves the total work compared to testing both
 * pairs unconditionally.
 *
 * Compile:
 *   nvcc -O3 --use_fast_math -arch=sm_70 -o keeloq_bf keeloq_bruteforce.cu
 *
 * Usage:
 *   ./keeloq_bf [options]
 *
 */

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <chrono>
#include <cinttypes>
#include <random>

/* ========================== compile-time knobs ========================== */

/* NLF constant for KeeLoq */
#define NLF_CONSTANT 0x3A5C742EU

/* Full KeeLoq uses 528 rounds */
#define KEELOQ_FULL_ROUNDS 528

/*
 * Threads per block — 256 is usually optimal for compute-bound kernels.
 * Override at compile time:  nvcc -DBLOCK_SIZE=128 ...
 */
#ifndef BLOCK_SIZE
#define BLOCK_SIZE 192
#endif

/*
 * Minimum thread blocks ptxas must keep resident per SM.
 *
 * This is the register cap for the bit-slice kernel: naming N blocks limits it
 * to 65536/(N*BLOCK_SIZE) registers per thread.  At 2 that is 128 registers
 * with BLOCK_SIZE=256, or 170 with BLOCK_SIZE=192; 3 needs <= 85 and spills.
 *
 * NOTE: --maxrregcount (the Makefile's MAXREG=) has NO effect here, because
 * __launch_bounds__ takes precedence over it.  Use this knob instead.
 */
#ifndef MIN_BLOCKS_PER_SM
#define MIN_BLOCKS_PER_SM 2
#endif

/*
 * How many key bits each thread sweeps in an inner loop.
 * The outer grid covers the upper (free_bits - THREAD_INNER_BITS) bits,
 * while each thread iterates over the lowest THREAD_INNER_BITS in a
 * register loop.  This amortizes launch / scheduling overhead and
 * increases instruction-level parallelism.
 *
 * 8 means each thread tests 256 consecutive keys.
 * Useful range: 4–12.  Higher = fewer threads, more work per thread.
 * Override at compile time:  nvcc -DTHREAD_INNER_BITS=10 ...
 */
#ifndef THREAD_INNER_BITS
#define THREAD_INNER_BITS 8
#endif
#define THREAD_INNER_COUNT (1U << THREAD_INNER_BITS)

/* Maximum number of results we store (should be tiny for a correct run) */
#define MAX_RESULTS 256

/* Maximum supported fixed-bit positions */
#define MAX_FREE_BITS 64

/* ========================== device helpers =============================== */

/* -----------------------------------------------------------------------
 * BIT-SLICE HELPERS
 *
 * keeloq_bs528_match() processes BS_LANES=32 keys simultaneously.
 * Each "variable" (key bit, state bit) is a uint32_t whose j-th bit is the
 * value for key-lane j.  A single bitwise AND/OR/XOR operates on all 32
 * lanes in parallel — effectively a free 32× throughput multiplier.
 *
 * NLF(a,b,c,d,e) Boolean formula (5 inputs, 1 output) — truth table
 * 0x3A5C742E, synthesised as a multiplexer tree (~48 bitwise ops):
 *   input index = (e<<4)|(d<<3)|(c<<2)|(b<<1)|a
 *   where  a = x[1], b = x[9], c = x[20], d = x[26], e = x[31]
 *
 * State layout: xs[32] — xs[b] holds bit b of all 32 states.
 * ----------------------------------------------------------------------- */

#define BS_LANES 32   /* keys processed in parallel per bit-slice call */
#define BS_LANES_BITS 5   /* log2(BS_LANES) */

/* NLF evaluated on 32 key-lanes at once.
 * Inputs a..e are uint32_t bit-planes (one bit per lane).
 * Truth table 0x3A5C742E, implemented as a MUX tree (~24 bitwise ops). */
__device__ __forceinline__
uint32_t nlf_bs(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e)
{
    /*
     * The four (e,d) sub-tables of 0x3A5C742E are 0x2E 0x74 0x5C 0x3A, and
     * 0x74 / 0x3A are the bit-reversals of 0x2E / 0x5C.  Equivalently,
     * verified exhaustively over all 32 inputs:
     *
     *     NLF(e,d,c,b,a) == NLF(e,0,c^d,b^d,a^d)
     *
     * so d does nothing but complement the other three inputs.  That collapses
     * the generic (e,d) MUX tree from 7 LOP3 to 3 XOR + 3 LOP3.
     */
    uint32_t ap = a ^ d, bp = b ^ d, cp = c ^ d;
    uint32_t g0 = (cp & (ap & ~bp)) | (~cp & (ap | bp));   /* LUT 0x2E */
    uint32_t g1 = (cp & ~ap)        | (~cp & bp);          /* LUT 0x5C */
    return (e & g1) | (~e & g0);                           /* LUT 0xCA */
}

/*
 * Low-register variant: key bit-plane for round r is computed on demand,
 * reused across all 8+1 repeat cycles. The key repeats every 64 rounds so
 * ks[64] is computed once and used for all 528 rounds.
 *
 * To avoid a 64-word register array in the *caller*, the ks[] is computed
 * and consumed inside this function, which should be inlined.
 */
/*
 * Bit-slice 528-round KeeLoq for 32 candidate keys, fused with the ciphertext
 * test.  Returns a 32-bit mask: bit l set iff lane l encrypts pt to ct.
 *
 * Three properties keep the hot path short:
 *
 *  - Index rotation.  The one-bit state shift is applied to the *subscript*,
 *    not the data: with the round loop unrolled every subscript is a
 *    compile-time constant, so the shift costs no register moves.  64 = 0
 *    (mod 32), so the mapping realigns at each 64-round cycle boundary and the
 *    offset is 16 after all 528 rounds.
 *
 *  - Filter at round 512.  By the NLFSR passthrough property the last 16
 *    rounds only shift state[31:16] down into ct[15:0], so ct[15:0] is already
 *    determined at round 512.  Testing there rejects all 32 lanes with
 *    probability (1-2^-16)^32 = 0.9995 and skips the final 16 rounds.
 *
 *  - The ciphertext compare is fused in, and the final compare covers only
 *    ct[31:16] since the low half is confirmed by the round-512 filter.
 */
__device__ __forceinline__
uint32_t keeloq_bs528_match(
    int           start_bit,
    int           free_bits,
    uint64_t      c0,            /* candidate index of lane 0 */
    uint32_t      base_key_lo32,
    uint32_t      base_key_hi32,
    uint32_t      pt,
    uint32_t      ct)
{
    /* Lane patterns for the 5 low-order bits that vary across the 32 lanes */
    constexpr uint32_t LP[5] = {
        0xAAAAAAAAu, 0xCCCCCCCCu, 0xF0F0F0F0u, 0xFF00FF00u, 0xFFFF0000u };

    /* broadcast bit b of v to a whole plane */
    #define BS_BCAST(v, b) ((uint32_t)(-(int32_t)(((v) >> (b)) & 1u)))

    uint32_t xs[32];
    #pragma unroll
    for (int b = 0; b < 32; ++b) xs[b] = BS_BCAST(pt, b);

    uint32_t ks[64];
    #pragma unroll
    for (int r = 0; r < 64; ++r) {
        int j = r - start_bit;
        uint32_t plane;
        if (j >= 0 && j < free_bits) {
            uint32_t base_bit = ((c0 >> j) & 1ull) ? 0xFFFFFFFFu : 0u;
            plane = (j < BS_LANES_BITS) ? (base_bit ^ LP[j]) : base_bit;
        } else {
            uint32_t bk_bit = (r < 32) ? ((base_key_lo32 >> r) & 1u)
                                       : ((base_key_hi32 >> (r - 32)) & 1u);
            plane = bk_bit ? 0xFFFFFFFFu : 0u;
        }
        ks[r] = plane;
    }

    /* logical state bit i lives in xs[(i + off) & 31] */
    int off = 0;
    #define BS_S(i) xs[(((i) + off) & 31)]
    #define BS_ROUND(kr)                                                       \
        do {                                                                   \
            uint32_t fb = nlf_bs(BS_S(1), BS_S(9), BS_S(20), BS_S(26), BS_S(31))\
                        ^ BS_S(16) ^ BS_S(0) ^ (kr);                           \
            xs[off & 31] = fb;      /* slot of logical bit 0, now shifted out */\
            off = (off + 1) & 31;                                              \
        } while (0)

    #pragma unroll 1
    for (int cyc = 0; cyc < 8; ++cyc) {
        #pragma unroll
        for (int r = 0; r < 64; ++r) BS_ROUND(ks[r]);
    }

    /* 512 rounds done, off == 0: ct[15:0] == state_512[31:16] */
    uint32_t alive = 0xFFFFFFFFu;
    #pragma unroll
    for (int b = 0; b < 16; ++b)
        alive &= ~(xs[16 + b] ^ BS_BCAST(ct, b));
    if (alive == 0u) return 0u;

    #pragma unroll
    for (int r = 0; r < 16; ++r) BS_ROUND(ks[r]);

    /* off == 16; ct[15:0] already confirmed above, so only test the high half */
    #pragma unroll
    for (int b = 16; b < 32; ++b)
        alive &= ~(BS_S(b) ^ BS_BCAST(ct, b));

    #undef BS_ROUND
    #undef BS_S
    #undef BS_BCAST
    return alive;
}

/*
 * KeeLoq encryption — fully unrolled NLF via constant lookup.
 *
 * The key is treated as a read-only constant; extracting bit (r % 64)
 * via a variable shift allows the compiler to schedule the key-bit
 * extraction independently of the feedback chain, maximising ILP.
 */
__device__ __forceinline__
uint32_t keeloq_encrypt_dev(uint64_t key, uint32_t pt, int rounds) {
    uint32_t x = pt;
    for (int r = 0; r < rounds; ++r) {
        /* NLF input: 5 bits from the LFSR state */
        uint32_t nlf_in = (((x >> 31) & 1u) << 4) |
                          (((x >> 26) & 1u) << 3) |
                          (((x >> 20) & 1u) << 2) |
                          (((x >>  9) & 1u) << 1) |
                           ((x >>  1) & 1u);
        /* Feedback bit: key_bit XOR state[16] XOR state[0] XOR NLF */
        uint32_t fb = (uint32_t)((key >> (r & 63)) & 1ull) ^
                      ((x >> 16) & 1u) ^ (x & 1u) ^
                      ((NLF_CONSTANT >> nlf_in) & 1u);
        /* Shift register right, inject feedback at MSB */
        x = (x >> 1) | (fb << 31);
    }
    return x;
}

/*
 * Fast path for the common benchmark case (full KeeLoq: 528 rounds).
 *
 * Using fixed 64-round cycles encourages stronger unrolling and constant
 * key-bit indexing while avoiding the loop-carried dependency introduced by
 * key-rotation based implementations.
 */
__device__ __forceinline__
uint32_t keeloq_encrypt_528_dev(uint64_t key, uint32_t pt) {
    uint32_t x = pt;
    #pragma unroll
    for (int cyc = 0; cyc < 8; ++cyc) {
        #pragma unroll
        for (int r = 0; r < 64; ++r) {
            uint32_t nlf_in = (((x >> 31) & 1u) << 4) |
                              (((x >> 26) & 1u) << 3) |
                              (((x >> 20) & 1u) << 2) |
                              (((x >>  9) & 1u) << 1) |
                               ((x >>  1) & 1u);
            uint32_t fb = (uint32_t)((key >> r) & 1ull) ^
                          ((x >> 16) & 1u) ^ (x & 1u) ^
                          ((NLF_CONSTANT >> nlf_in) & 1u);
            x = (x >> 1) | (fb << 31);
        }
    }
    #pragma unroll
    for (int r = 0; r < 16; ++r) {
        uint32_t nlf_in = (((x >> 31) & 1u) << 4) |
                          (((x >> 26) & 1u) << 3) |
                          (((x >> 20) & 1u) << 2) |
                          (((x >>  9) & 1u) << 1) |
                           ((x >>  1) & 1u);
        uint32_t fb = (uint32_t)((key >> r) & 1ull) ^
                      ((x >> 16) & 1u) ^ (x & 1u) ^
                      ((NLF_CONSTANT >> nlf_in) & 1u);
        x = (x >> 1) | (fb << 31);
    }
    return x;
}

/* ========================== kernels ====================================== */

/* -----------------------------------------------------------------------
 * BIT-SLICE KERNEL — processes BS_LANES=32 keys per thread per inner step.
 *
 * In the contiguous-free-bits case:
 *   candidate index = (chunk_offset + gid) * THREAD_INNER_COUNT * BS_LANES + inner * BS_LANES + lane
 *
 * Key bit-planes:
 *   For the free bit block [start_bit .. start_bit+free_bits-1], bits
 *   j = 0..free_bits-1 of candidate k go to ks[start_bit+j].
 *   Lane l of step s processes candidate:
 *     c = (chunk_offset + gid) * (THREAD_INNER_COUNT * BS_LANES) + inner * BS_LANES + l
 *   So ks[start_bit+j] has bit (c >> j) & 1 for lane l.
 *   Since the 32 lanes differ only in their lowest 5 bits (we set
 *   ks[start_bit+0..4] = constant patterns), and the outer bits are
 *   shared, only the low BS_LANES_BITS=5 key bits differ across lanes.
 *
 * Pairs: both P/C pairs are tested in the bit-slice domain.
 * A "hit" in any lane triggers an atomicAdd and scalar verification.
 * ----------------------------------------------------------------------- */
__launch_bounds__(BLOCK_SIZE, MIN_BLOCKS_PER_SM)
__global__ void
bruteforce_kernel_bs_528_2(int            start_bit,
                           int            free_bits,
                           uint64_t       base_key,
                           uint32_t       pt0, uint32_t ct0,
                           uint32_t       pt1, uint32_t ct1,
                           uint64_t      *__restrict__ results,
                           uint32_t      *__restrict__ result_cnt,
                           uint64_t       chunk_offset,
                           uint64_t       num_outer_threads)
{
    uint64_t gid = (uint64_t)blockIdx.x * BLOCK_SIZE + threadIdx.x;
    if (gid >= num_outer_threads) return;

    /* Each outer thread processes THREAD_INNER_COUNT groups of BS_LANES=32 keys.
     * cand_base = index of the first candidate for this thread. */
    uint64_t cand_base = ((chunk_offset + gid) * (uint64_t)THREAD_INNER_COUNT) << BS_LANES_BITS;

    /* Split base_key into lo/hi 32-bit halves for on-the-fly key bit extraction */
    uint32_t bk_lo = (uint32_t)base_key;
    uint32_t bk_hi = (uint32_t)(base_key >> 32);

    for (uint32_t inner = 0; inner < THREAD_INNER_COUNT; ++inner) {
        /* Candidate index of lane 0 for this inner step */
        uint64_t c0 = cand_base + (uint64_t)inner * BS_LANES;

        /* Waterfall: pair 0 rejects ~every candidate, so pair 1 is essentially
         * never evaluated and the cost stays ~1 encryption per key. */
        uint32_t pass0 = keeloq_bs528_match(start_bit, free_bits, c0,
                                            bk_lo, bk_hi, pt0, ct0);
        if (pass0 == 0) continue;

        uint32_t both_pass = pass0 & keeloq_bs528_match(start_bit, free_bits, c0,
                                                        bk_lo, bk_hi, pt1, ct1);
        if (both_pass == 0) continue;

        /* ---- Record hits (rare — ~1 in 2^64 keys) ---- */
        uint32_t hits = both_pass;
        while (hits) {
            int lane = __ffs(hits) - 1;
            hits &= hits - 1;
            uint64_t winning_key = base_key | ((c0 + (uint64_t)lane) << start_bit);
            uint32_t slot = atomicAdd(result_cnt, 1u);
            if (slot < MAX_RESULTS)
                results[slot] = winning_key;
        }
    }
}

/*
 * FAST PATH — contiguous free bits.
 *
 * When the free key bits form a single contiguous block (bits start_bit
 * through start_bit + free_bits - 1), we can construct the candidate key
 * with a single shift+OR instead of looping over a free-index array.
 * This eliminates the 64-register fidx[] array and the per-bit set/clear
 * loops, dropping register pressure from ~70+ to ~12, enabling 100%
 * occupancy on most GPUs and roughly doubling throughput.
 *
 * Key construction:  key = base_key | ((uint64_t)candidate << start_bit)
 *
 * The inner loop advances the key by a fixed step (1 << start_bit) each
 * iteration — a single 64-bit ADD instead of recomputing shift+OR.
 */
template <int NUM_PAIRS>
__launch_bounds__(BLOCK_SIZE)
__global__ void
bruteforce_kernel_contig(int            rounds,
                         int            start_bit,
                         uint64_t       base_key,
                         const uint32_t *__restrict__ pts,
                         const uint32_t *__restrict__ cts,
                         uint64_t      *__restrict__ results,
                         uint32_t      *__restrict__ result_cnt,
                         uint64_t       chunk_offset,
                         uint64_t       num_outer_threads)
{
    uint64_t gid = (uint64_t)blockIdx.x * BLOCK_SIZE + threadIdx.x;
    if (gid >= num_outer_threads) return;

    /* Pre-load P/C pairs into registers */
    uint32_t lpt[2], lct[2];
    #pragma unroll
    for (int p = 0; p < NUM_PAIRS; ++p) {
        lpt[p] = pts[p];
        lct[p] = cts[p];
    }

    /* Starting candidate; advance key by key_step each inner iteration */
    uint64_t cand_base = (chunk_offset + gid) * THREAD_INNER_COUNT;
    uint64_t key = base_key | (cand_base << start_bit);
    uint64_t key_step = 1ull << start_bit;

    if (rounds == KEELOQ_FULL_ROUNDS) {
        for (uint32_t inner = 0; inner < THREAD_INNER_COUNT; ++inner, key += key_step) {
            /* Waterfall: pair 0 first, then pair 1 (common NUM_PAIRS==2 case). */
            if (keeloq_encrypt_528_dev(key, lpt[0]) != lct[0])
                continue;

            if constexpr (NUM_PAIRS == 2) {
                if (keeloq_encrypt_528_dev(key, lpt[1]) != lct[1])
                    continue;
            } else {
                bool ok = true;
                #pragma unroll
                for (int p = 1; p < NUM_PAIRS; ++p) {
                    if (keeloq_encrypt_528_dev(key, lpt[p]) != lct[p]) {
                        ok = false;
                        break;
                    }
                }
                if (!ok) continue;
            }

            uint32_t slot = atomicAdd(result_cnt, 1u);
            if (slot < MAX_RESULTS)
                results[slot] = key;
        }
    } else {
        for (uint32_t inner = 0; inner < THREAD_INNER_COUNT; ++inner, key += key_step) {
            if (keeloq_encrypt_dev(key, lpt[0], rounds) != lct[0])
                continue;

            if constexpr (NUM_PAIRS == 2) {
                if (keeloq_encrypt_dev(key, lpt[1], rounds) != lct[1])
                    continue;
            } else {
                bool ok = true;
                #pragma unroll
                for (int p = 1; p < NUM_PAIRS; ++p) {
                    if (keeloq_encrypt_dev(key, lpt[p], rounds) != lct[p]) {
                        ok = false;
                        break;
                    }
                }
                if (!ok) continue;
            }

            uint32_t slot = atomicAdd(result_cnt, 1u);
            if (slot < MAX_RESULTS)
                results[slot] = key;
        }
    }
}

/*
 * Ultra-fast specialisation for the dominant benchmark path:
 * - contiguous free bits
 * - exactly 2 P/C pairs
 * - full KeeLoq rounds (528)
 */
__launch_bounds__(BLOCK_SIZE)
__global__ void
bruteforce_kernel_contig_528_2(int            start_bit,
                               uint64_t       base_key,
                               uint32_t       pt0,
                               uint32_t       ct0,
                               uint32_t       pt1,
                               uint32_t       ct1,
                               uint64_t      *__restrict__ results,
                               uint32_t      *__restrict__ result_cnt,
                               uint64_t       chunk_offset,
                               uint64_t       num_outer_threads)
{
    uint64_t gid = (uint64_t)blockIdx.x * BLOCK_SIZE + threadIdx.x;
    if (gid >= num_outer_threads) return;

    uint64_t cand_base = (chunk_offset + gid) * THREAD_INNER_COUNT;
    uint64_t key = base_key | (cand_base << start_bit);
    uint64_t key_step = 1ull << start_bit;

    /*
     * Two-key software pipelining improves ILP and cuts loop-control overhead.
     * THREAD_INNER_COUNT is always a power of two (>= 1), so a tail path keeps
     * correctness for odd values in case of custom builds.
     */
    uint32_t inner = 0;
    for (; inner + 1 < THREAD_INNER_COUNT; inner += 2, key += (key_step << 1)) {
        uint64_t key0 = key;
        uint64_t key1 = key + key_step;

        if (keeloq_encrypt_528_dev(key0, pt0) == ct0 &&
            keeloq_encrypt_528_dev(key0, pt1) == ct1) {
            uint32_t slot0 = atomicAdd(result_cnt, 1u);
            if (slot0 < MAX_RESULTS)
                results[slot0] = key0;
        }

        if (keeloq_encrypt_528_dev(key1, pt0) == ct0 &&
            keeloq_encrypt_528_dev(key1, pt1) == ct1) {
            uint32_t slot1 = atomicAdd(result_cnt, 1u);
            if (slot1 < MAX_RESULTS)
                results[slot1] = key1;
        }
    }

    if (inner < THREAD_INNER_COUNT) {
        if (keeloq_encrypt_528_dev(key, pt0) == ct0 &&
            keeloq_encrypt_528_dev(key, pt1) == ct1) {
            uint32_t slot = atomicAdd(result_cnt, 1u);
            if (slot < MAX_RESULTS)
                results[slot] = key;
        }
    }
}

/*
 * GENERIC PATH — arbitrary (possibly non-contiguous) free bits.
 *
 * Uses a per-thread fidx[] register array to map candidate-index bits
 * to actual key bit positions.  Higher register pressure, lower occupancy,
 * but handles any fixed/free pattern (e.g., --fix-mask with gaps).
 */
template <int NUM_PAIRS>
__global__ void
bruteforce_kernel_generic(int            rounds,
                          int            free_bits,
                          const int     *__restrict__ free_idx,
                          uint64_t       base_key,
                          const uint32_t *__restrict__ pts,
                          const uint32_t *__restrict__ cts,
                          uint64_t      *__restrict__ results,
                          uint32_t      *__restrict__ result_cnt,
                          uint64_t       chunk_offset,
                          uint64_t       num_outer_threads)
{
    uint64_t gid = (uint64_t)blockIdx.x * BLOCK_SIZE + threadIdx.x;
    if (gid >= num_outer_threads) return;

    /* Pre-load free_idx into registers */
    int fidx[MAX_FREE_BITS];
    for (int b = 0; b < free_bits; ++b)
        fidx[b] = free_idx[b];

    /* Pre-load P/C pairs into registers */
    uint32_t lpt[2], lct[2];
    #pragma unroll
    for (int p = 0; p < NUM_PAIRS; ++p) {
        lpt[p] = pts[p];
        lct[p] = cts[p];
    }

    int inner_bits = (free_bits < THREAD_INNER_BITS) ? free_bits : THREAD_INNER_BITS;
    uint32_t inner_count = 1u << inner_bits;

    /* Build key template: set all free bits above the inner portion */
    uint64_t outer_val = chunk_offset + gid;
    uint64_t key_template = base_key;
    for (int b = inner_bits; b < free_bits; ++b) {
        if ((outer_val >> (b - inner_bits)) & 1ull)
            key_template |= (1ull << fidx[b]);
    }

    /* Inner loop: sweep the lowest inner_bits free positions */
    for (uint32_t inner = 0; inner < inner_count; ++inner) {
        uint64_t key = key_template;
        for (int b = 0; b < inner_bits; ++b) {
            if ((inner >> b) & 1u)
                key |= (1ull << fidx[b]);
            else
                key &= ~(1ull << fidx[b]);
        }

        /* Waterfall: test pair 0 first (early exit for ~all candidates) */
        if (keeloq_encrypt_dev(key, lpt[0], rounds) != lct[0])
            continue;

        /* Pair 0 matched — test remaining pairs */
        bool ok = true;
        #pragma unroll
        for (int p = 1; p < NUM_PAIRS; ++p) {
            if (keeloq_encrypt_dev(key, lpt[p], rounds) != lct[p]) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;

        /* All pairs matched — record the key */
        uint32_t slot = atomicAdd(result_cnt, 1u);
        if (slot < MAX_RESULTS)
            results[slot] = key;
    }
}

/* ========================== host code ==================================== */

static void print_usage(const char *prog) {
    fprintf(stderr,
        "KeeLoq CUDA Brute-Force Key Recovery\n\n"
        "Usage: %s [options]\n\n"
        "Options:\n"
        "  --key KEY          Target key in hex (default: 0x5CEC6701B79FD949)\n"
        "  --pt0 HEX          Plaintext 0 (hex)\n"
        "  --ct0 HEX          Ciphertext 0 (hex)\n"
        "  --pt1 HEX          Plaintext 1 (hex)\n"
        "  --ct1 HEX          Ciphertext 1 (hex)\n"
        "  --rounds N         Number of rounds (default: 528)\n"
        "  --random-key       Use a random 64-bit target key for this run\n"
        "  --fix-low N        Fix lowest N key bits to the target key value\n"
        "  --fix-high N       Fix highest N key bits to the target key value\n"
        "  --fix-mask HEX     Arbitrary bitmask of fixed positions\n"
        "  --fix-value HEX    Value for fixed positions (default: from --key)\n"
        "  --device N         CUDA device index (default: 0)\n"
        "  --benchmark        Generate random P/C pairs from --key and run\n"
        "  -h, --help         Show this help\n\n"
        "Compile-time tuning (pass via make or nvcc -D):\n"
        "  BLOCK_SIZE=N       Threads per block (default: 256, try 128 or 512)\n"
        "  THREAD_INNER_BITS=N  Keys/thread = 2^N (default: 8, range: 4-12)\n\n"
        "Example (full 2^64 search):\n"
        "  %s --pt0 0xA3B1799D --ct0 0xBC49AC6D --pt1 0x46685257 --ct1 0x92CA7761\n\n"
        "Example (test with 24 bits fixed):\n"
        "  %s --benchmark --fix-low 24\n",
        prog, prog, prog);
}

/* Simple hex parser for uint64_t / uint32_t */
static uint64_t parse_hex64(const char *s) {
    return strtoull(s, nullptr, 0);
}
static uint32_t parse_hex32(const char *s) {
    return (uint32_t)strtoul(s, nullptr, 0);
}

/* KeeLoq encrypt on host (for generating test data / verification) */
static uint32_t keeloq_encrypt_host(uint64_t key, uint32_t pt, int rounds) {
    uint32_t x = pt;
    for (int r = 0; r < rounds; ++r) {
        uint32_t nlf_in = (((x >> 31) & 1u) << 4) |
                          (((x >> 26) & 1u) << 3) |
                          (((x >> 20) & 1u) << 2) |
                          (((x >>  9) & 1u) << 1) |
                           ((x >>  1) & 1u);
        uint32_t fb = (uint32_t)((key >> (r & 63)) & 1ull) ^
                      ((x >> 16) & 1u) ^ (x & 1u) ^
                      ((NLF_CONSTANT >> nlf_in) & 1u);
        x = (x >> 1) | (fb << 31);
    }
    return x;
}

int main(int argc, char **argv) {
    /* Defaults */
    uint64_t target_key   = 0x5CEC6701B79FD949ull;
    int      rounds       = KEELOQ_FULL_ROUNDS;
    int      fix_low      = 0;
    int      fix_high     = 0;
    uint64_t fix_mask     = 0;
    uint64_t fix_value    = 0;
    bool     fix_mask_set = false;
    bool     fix_value_set = false;
    bool     benchmark    = false;
    bool     random_key   = false;
    int      device_id    = 0;
    uint32_t pt0 = 0, ct0 = 0, pt1 = 0, ct1 = 0;
    bool     pairs_given  = false;

    /* Parse command line */
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            print_usage(argv[0]); return 0;
        } else if (!strcmp(argv[i], "--key") && i+1 < argc) {
            target_key = parse_hex64(argv[++i]);
        } else if (!strcmp(argv[i], "--rounds") && i+1 < argc) {
            rounds = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--random-key")) {
            random_key = true;
        } else if (!strcmp(argv[i], "--fix-low") && i+1 < argc) {
            fix_low = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--fix-high") && i+1 < argc) {
            fix_high = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--fix-mask") && i+1 < argc) {
            fix_mask = parse_hex64(argv[++i]); fix_mask_set = true;
        } else if (!strcmp(argv[i], "--fix-value") && i+1 < argc) {
            fix_value = parse_hex64(argv[++i]); fix_value_set = true;
        } else if (!strcmp(argv[i], "--device") && i+1 < argc) {
            device_id = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--benchmark")) {
            benchmark = true;
        } else if (!strcmp(argv[i], "--pt0") && i+1 < argc) {
            pt0 = parse_hex32(argv[++i]); pairs_given = true;
        } else if (!strcmp(argv[i], "--ct0") && i+1 < argc) {
            ct0 = parse_hex32(argv[++i]);
        } else if (!strcmp(argv[i], "--pt1") && i+1 < argc) {
            pt1 = parse_hex32(argv[++i]);
        } else if (!strcmp(argv[i], "--ct1") && i+1 < argc) {
            ct1 = parse_hex32(argv[++i]);
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]); return 1;
        }
    }

    if (random_key) {
        std::random_device rd;
        std::mt19937_64 gen(rd());
        target_key = gen();
    }

    /* Select CUDA device */
    cudaSetDevice(device_id);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, device_id);
    int clock_khz = 0;
    cudaDeviceGetAttribute(&clock_khz, cudaDevAttrClockRate, device_id);
    fprintf(stderr, "Device %d: %s  (SMs: %d, clock: %d MHz, mem: %.1f GB)\n",
            device_id, prop.name, prop.multiProcessorCount,
            clock_khz / 1000,
            prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));

    /* Build fixed mask */
    if (!fix_mask_set) {
        fix_mask = 0;
        for (int b = 0; b < fix_low; ++b)
            fix_mask |= (1ull << b);
        for (int b = 64 - fix_high; b < 64; ++b)
            fix_mask |= (1ull << b);
    }
    if (!fix_value_set)
        fix_value = target_key;

    /* Generate P/C pairs */
    if (benchmark || !pairs_given) {
        /* Generate 2 random P/C pairs from target key */
        /* Use a simple LCG seeded from the key for reproducibility */
        uint32_t seed = (uint32_t)(target_key ^ (target_key >> 32)) ^ 0xDEADBEEF;
        pt0 = seed * 1103515245u + 12345u;
        pt1 = pt0 * 1103515245u + 12345u;
        ct0 = keeloq_encrypt_host(target_key, pt0, rounds);
        ct1 = keeloq_encrypt_host(target_key, pt1, rounds);
        if (!pairs_given)
            fprintf(stderr, "Auto-generated P/C pairs from target key.\n");
    }

    /* Determine free bit positions */
    int free_idx_h[64];
    int free_bits = 0;
    for (int b = 0; b < 64; ++b) {
        if (!((fix_mask >> b) & 1ull))
            free_idx_h[free_bits++] = b;
    }

    /*
     * Detect whether the free bits form a single contiguous block.
     * If so, we use the fast-path kernel (no fidx[] array, ~2x faster).
     */
    bool contiguous = true;
    int  contig_start = (free_bits > 0) ? free_idx_h[0] : 0;
    for (int i = 1; i < free_bits; ++i) {
        if (free_idx_h[i] != contig_start + i) {
            contiguous = false;
            break;
        }
    }

    /* Bit-slice requires contiguous free bits and at least 5 free bits (32 lanes). */
    bool use_bitslice = (contiguous && rounds == KEELOQ_FULL_ROUNDS && free_bits >= BS_LANES_BITS);

    /* Base key with fixed bits filled in */
    uint64_t base_key = fix_value & fix_mask;

    uint64_t total_candidates = (free_bits == 64) ? 0 /* means 2^64 */ : (1ull << free_bits);
    int log2_total = free_bits;

    /* Pre-compute grid info for the banner */
    uint64_t banner_outer;
    int banner_inner_bits = THREAD_INNER_BITS + (use_bitslice ? BS_LANES_BITS : 0);
    if (free_bits <= banner_inner_bits)
        banner_outer = 1;
    else if (free_bits == 64)
        banner_outer = 1ull << (64 - banner_inner_bits);
    else
        banner_outer = 1ull << (free_bits - banner_inner_bits);
    uint64_t banner_blocks = (banner_outer + BLOCK_SIZE - 1) / BLOCK_SIZE;
    int blocks_per_sm = (banner_blocks + prop.multiProcessorCount - 1) / prop.multiProcessorCount;
    int warps_per_block = BLOCK_SIZE / 32;

    fprintf(stderr, "\n");
    fprintf(stderr, "======================================================\n");
    fprintf(stderr, "  KeeLoq CUDA Brute-Force Key Recovery\n");
    fprintf(stderr, "======================================================\n");
    fprintf(stderr, "  Rounds:           %d\n", rounds);
    fprintf(stderr, "  Target key:       0x%016" PRIX64 "\n", target_key);
    fprintf(stderr, "  Fixed bits:       %d  (mask: 0x%016" PRIX64 ")\n", 64 - free_bits, fix_mask);
    fprintf(stderr, "  Free bits:        %d  (search space: 2^%d)\n", free_bits, log2_total);
    const char *kernel_name = !contiguous             ? "generic (scattered free bits)"
                            : (!use_bitslice)         ? "FAST scalar (contiguous)"
                            :                           "BIT-SLICE x32 (contiguous, 528r)";
    fprintf(stderr, "  Kernel:           %s\n", kernel_name);
    fprintf(stderr, "  P/C pair 0:       0x%08X -> 0x%08X\n", pt0, ct0);
    fprintf(stderr, "  P/C pair 1:       0x%08X -> 0x%08X\n", pt1, ct1);
    fprintf(stderr, "  Waterfall:        pair 0 filters first (early exit)\n");
    fprintf(stderr, "------------------------------------------------------\n");
    fprintf(stderr, "  GPU Grid Layout\n");
    fprintf(stderr, "------------------------------------------------------\n");
    fprintf(stderr, "  SMs on device:    %d\n", prop.multiProcessorCount);
    fprintf(stderr, "  Block size:       %d threads  (%d warps)\n", BLOCK_SIZE, warps_per_block);
    {
        int  total_inner_bits = THREAD_INNER_BITS + (use_bitslice ? BS_LANES_BITS : 0);
        uint64_t kpt = (uint64_t)THREAD_INNER_COUNT * (use_bitslice ? BS_LANES : 1);
        fprintf(stderr, "  Inner loop:       2^%d = %" PRIu64 " keys/thread%s\n",
                total_inner_bits, kpt,
            use_bitslice ? "  (32-way bit-slice)" : "");
        int outer_bits = free_bits > total_inner_bits ? free_bits - total_inner_bits : 0;
        fprintf(stderr, "  Outer threads:    2^%d\n", outer_bits);
        fprintf(stderr, "  Total blocks:     %" PRIu64 "\n", banner_blocks);
        fprintf(stderr, "  Blocks/SM:        ~%d\n", blocks_per_sm);
        fprintf(stderr, "  Keys/block:       %d x %" PRIu64 " = %" PRIu64 "\n",
                BLOCK_SIZE, kpt, (uint64_t)BLOCK_SIZE * kpt);
    }
    fprintf(stderr, "\n");
    fprintf(stderr, "  GPU <%d SMs>\n", prop.multiProcessorCount);
    fprintf(stderr, "  ");
    /* Print a visual bar: one '#' per SM (up to 40), scale if more */
    int bar_len = prop.multiProcessorCount;
    if (bar_len > 40) bar_len = 40;
    fprintf(stderr, "[");
    for (int i = 0; i < bar_len; ++i) fprintf(stderr, "#");
    fprintf(stderr, "]");
    if (prop.multiProcessorCount > 40)
        fprintf(stderr, " (%d SMs)", prop.multiProcessorCount);
    fprintf(stderr, "\n");
    fprintf(stderr, "  Each SM: ~%d blocks x %d threads x %" PRIu64 " keys/thread\n",
            blocks_per_sm, BLOCK_SIZE,
            (uint64_t)THREAD_INNER_COUNT * (use_bitslice ? BS_LANES : 1));
    fprintf(stderr, "======================================================\n\n");

    /* Host-side verification of pairs */
    if (benchmark) {
        uint32_t check0 = keeloq_encrypt_host(target_key, pt0, rounds);
        uint32_t check1 = keeloq_encrypt_host(target_key, pt1, rounds);
        if (check0 != ct0 || check1 != ct1) {
            fprintf(stderr, "FATAL: P/C pair self-check failed!\n");
            return 1;
        }
        fprintf(stderr, "Self-check: P/C pairs verified against target key.\n");
    }

    /* Allocate device memory */
    int      *d_free_idx;
    uint32_t *d_pts, *d_cts;
    uint64_t *d_results;
    uint32_t *d_result_cnt;

    cudaMalloc(&d_free_idx,   (free_bits > 0 ? free_bits : 1) * sizeof(int));
    cudaMalloc(&d_pts,        2 * sizeof(uint32_t));
    cudaMalloc(&d_cts,        2 * sizeof(uint32_t));
    cudaMalloc(&d_results,    MAX_RESULTS * sizeof(uint64_t));
    cudaMalloc(&d_result_cnt, sizeof(uint32_t));

    uint32_t h_pts[2] = {pt0, pt1};
    uint32_t h_cts[2] = {ct0, ct1};
    if (free_bits > 0)
        cudaMemcpy(d_free_idx, free_idx_h, free_bits * sizeof(int),  cudaMemcpyHostToDevice);
    cudaMemcpy(d_pts,      h_pts,      2 * sizeof(uint32_t),     cudaMemcpyHostToDevice);
    cudaMemcpy(d_cts,      h_cts,      2 * sizeof(uint32_t),     cudaMemcpyHostToDevice);

    uint32_t zero = 0;
    cudaMemcpy(d_result_cnt, &zero, sizeof(uint32_t), cudaMemcpyHostToDevice);

    /*
     * Launch strategy:
     *
     * outer_threads = total_candidates / THREAD_INNER_COUNT.
     * Each thread sweeps THREAD_INNER_COUNT consecutive keys in a register loop.
     * For > 2^31 outer threads, we split into multiple launch chunks.
     * Between chunks we poll for results and report progress.
     */

    /*
     * Keys per outer thread:
     *   bit-slice kernel : THREAD_INNER_COUNT * BS_LANES  (32x bonus)
     *   scalar kernels   : THREAD_INNER_COUNT
     */
    uint64_t keys_per_outer = use_bitslice
        ? ((uint64_t)THREAD_INNER_COUNT << BS_LANES_BITS)
        :  (uint64_t)THREAD_INNER_COUNT;

    uint64_t outer_threads;
    if (free_bits <= (int)(use_bitslice ? THREAD_INNER_BITS + BS_LANES_BITS : THREAD_INNER_BITS)) {
        outer_threads = 1;
    } else if (free_bits == 64) {
        int shift = 64 - THREAD_INNER_BITS - (use_bitslice ? BS_LANES_BITS : 0);
        outer_threads = (shift <= 0) ? 1 : (1ull << shift);
    } else {
        int shift = free_bits - THREAD_INNER_BITS - (use_bitslice ? BS_LANES_BITS : 0);
        outer_threads = (shift <= 0) ? 1 : (1ull << shift);
    }

    /* Max blocks per launch — stay under 2^31 - 1 (CUDA grid limit) */
    const uint64_t MAX_GRID_DIM = (1ull << 31) - 1;
    uint64_t max_threads_per_launch = MAX_GRID_DIM * BLOCK_SIZE;

    /*
     * Cap each chunk so we get ~5–20 second progress updates.
     * Bit-slice processes 32× more keys per outer thread, so use a 32× smaller
     * outer-thread cap to keep chunk wall time similar.
     */
    uint64_t chunk_max = benchmark ? (1ull << 28) : (1ull << 26);
    if (use_bitslice && chunk_max >= BS_LANES) chunk_max >>= BS_LANES_BITS;
    if (max_threads_per_launch > chunk_max)
        max_threads_per_launch = chunk_max;

    auto wall_start = std::chrono::high_resolution_clock::now();

    uint64_t outer_done = 0;
    int      chunk_no = 0;

    while (outer_done < outer_threads) {
        uint64_t outer_this = outer_threads - outer_done;
        if (outer_this > max_threads_per_launch)
            outer_this = max_threads_per_launch;

        uint64_t blocks = (outer_this + BLOCK_SIZE - 1) / BLOCK_SIZE;

        /*
         * chunk_offset = the outer-thread index where this chunk starts.
         * Dispatch to bit-slice (fastest), scalar contiguous, or generic kernel.
         */
        if (use_bitslice) {
            bruteforce_kernel_bs_528_2<<<(unsigned int)blocks, BLOCK_SIZE>>>(
                contig_start,
                free_bits,
                base_key,
                pt0, ct0, pt1, ct1,
                d_results, d_result_cnt,
                outer_done,
                outer_this);
        } else if (contiguous) {
            if (rounds == KEELOQ_FULL_ROUNDS) {
                bruteforce_kernel_contig_528_2<<<(unsigned int)blocks, BLOCK_SIZE>>>(
                    contig_start,
                    base_key,
                    pt0, ct0, pt1, ct1,
                    d_results, d_result_cnt,
                    outer_done,
                    outer_this);
            } else {
                bruteforce_kernel_contig<2><<<(unsigned int)blocks, BLOCK_SIZE>>>(
                    rounds,
                    contig_start,
                    base_key,
                    d_pts, d_cts,
                    d_results, d_result_cnt,
                    outer_done,
                    outer_this);
            }
        } else {
            bruteforce_kernel_generic<2><<<(unsigned int)blocks, BLOCK_SIZE>>>(
                rounds,
                free_bits,
                d_free_idx,
                base_key,
                d_pts, d_cts,
                d_results, d_result_cnt,
                outer_done,
                outer_this);
        }

        cudaError_t err = cudaDeviceSynchronize();
        if (err != cudaSuccess) {
            fprintf(stderr, "\nCUDA error after chunk %d: %s\n", chunk_no, cudaGetErrorString(err));
            return 1;
        }

        outer_done += outer_this;

        /* Check if key was found */
        uint32_t h_cnt;
        cudaMemcpy(&h_cnt, d_result_cnt, sizeof(uint32_t), cudaMemcpyDeviceToHost);

        auto wall_now = std::chrono::high_resolution_clock::now();
        double elapsed = std::chrono::duration<double>(wall_now - wall_start).count();
        double frac = (double)outer_done / (double)outer_threads;

        /* Compute live throughput */
        double keys_so_far = (double)outer_done * (double)keys_per_outer;
        double rate_g = (elapsed > 0) ? keys_so_far / elapsed / 1e9 : 0;

        fprintf(stderr, "\r  Chunk %d: %.4f%% done | %u hit(s) | %.1fs | %.3f Gkeys/s",
                chunk_no, frac * 100.0, h_cnt, elapsed, rate_g);
        fflush(stderr);

        chunk_no++;

        if (h_cnt > 0)
            break;
    }

    auto wall_end = std::chrono::high_resolution_clock::now();
    double total_time = std::chrono::duration<double>(wall_end - wall_start).count();

    /* Read back results */
    uint32_t h_cnt;
    cudaMemcpy(&h_cnt, d_result_cnt, sizeof(uint32_t), cudaMemcpyDeviceToHost);
    if (h_cnt > MAX_RESULTS) h_cnt = MAX_RESULTS;

    uint64_t h_results[MAX_RESULTS];
    if (h_cnt > 0)
        cudaMemcpy(h_results, d_results, h_cnt * sizeof(uint64_t), cudaMemcpyDeviceToHost);

    fprintf(stderr, "\n\n");
    fprintf(stderr, "======================================================\n");
    fprintf(stderr, "  RESULTS\n");
    fprintf(stderr, "======================================================\n");
    fprintf(stderr, "  Total time:     %.3f s\n", total_time);

    /* Compute throughput from actual work done (can stop early on hit). */
    double keys_tested = (double)outer_done * (double)keys_per_outer;
    /*
     * With the waterfall strategy, ~all candidates are rejected by pair 0
     * (one 528-round encryption).  Only ~2^{-32} survive to pair 1.
     * Effective encryptions ≈ keys_tested * (1 + 2^{-32}) ≈ keys_tested.
     */
    double enc_per_sec = keys_tested / total_time;
    double giga = enc_per_sec / 1e9;

    fprintf(stderr, "  Keys tested:    %.0f\n", keys_tested);
    fprintf(stderr, "  Search budget:  2^%d", log2_total);
    if (free_bits < 64)
        fprintf(stderr, " = %" PRIu64, total_candidates);
    fprintf(stderr, "\n");
    fprintf(stderr, "  Throughput:     %.3f Gkeys/s  (waterfall: ~1 enc/key)\n", giga);
    fprintf(stderr, "  Keys found:     %u\n", h_cnt);

    if (h_cnt > 0) {
        for (uint32_t i = 0; i < h_cnt; ++i) {
            fprintf(stderr, "  Key[%u]:         0x%016" PRIX64, i, h_results[i]);
            if (benchmark && h_results[i] == target_key)
                fprintf(stderr, "  <-- MATCHES TARGET");
            fprintf(stderr, "\n");

            /* Verify on host */
            uint32_t v0 = keeloq_encrypt_host(h_results[i], pt0, rounds);
            uint32_t v1 = keeloq_encrypt_host(h_results[i], pt1, rounds);
            if (v0 == ct0 && v1 == ct1) {
                fprintf(stderr, "                  Host verification: PASS\n");
            } else {
                fprintf(stderr, "                  Host verification: FAIL (v0=0x%08X v1=0x%08X)\n", v0, v1);
            }
        }
        /* Print the key to stdout for scripting */
        printf("0x%016" PRIX64 "\n", h_results[0]);
    } else {
        fprintf(stderr, "  NO KEY FOUND\n");
    }

    fprintf(stderr, "======================================================\n");

    /* Cleanup */
    cudaFree(d_free_idx);
    cudaFree(d_pts);
    cudaFree(d_cts);
    cudaFree(d_results);
    cudaFree(d_result_cnt);

    return (h_cnt > 0) ? 0 : 1;
}
