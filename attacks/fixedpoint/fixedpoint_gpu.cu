/*
 * fixedpoint_gpu.cu — GPU Phase 1 for KeeLoq Fixed-Point Attack
 *
 * Interface-compatible with fixedpoint_mt:
 *   ./fixedpoint_gpu [threads_per_block] [key_hex]
 *
 * Output-compatible artifacts:
 *   - fixedpoint_data.txt (same format expected by fixedpoint_sat.py)
 *
 * Notes:
 *   - This accelerates Phase 1 scan/filter/peel on CUDA GPUs.
 *   - Phase 2 remains unchanged.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/time.h>
#include <cuda_runtime.h>

#define NLF 0x3A5C742EU
#define TOTAL_PLAINTEXTS (1ULL << 32)
#define MAX_SURVIVORS_TOTAL (1 << 20)      /* 1,048,576, comfortably above expected ~65k */
#define MAX_SURVIVORS_CHUNK (1 << 20)
#define DEFAULT_TPB 256
#define DEFAULT_CHUNK (1U << 26)           /* 67,108,864 plaintexts per launch */
#define BS_LANES      32                   /* plaintexts processed per thread (bit-slice) */
#define BS_LANES_BITS  5                   /* log2(BS_LANES) */

static inline uint32_t keeloq_enc_offset_host(uint64_t key, uint32_t pt, int start_round, int nrounds)
{
    uint32_t s = pt;
    for (int i = 0; i < nrounds; i++) {
        int ki = (start_round + i) % 64;
        uint8_t nlf_in = (uint8_t)(
            ((s >> 31) & 1) << 4 |
            ((s >> 26) & 1) << 3 |
            ((s >> 20) & 1) << 2 |
            ((s >>  9) & 1) << 1 |
            ((s >>  1) & 1)
        );
        uint8_t fb = ((NLF >> nlf_in) & 1)
                   ^ ((uint8_t)(key >> ki) & 1)
                   ^ ((s >> 16) & 1)
                   ^ (s & 1);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return s;
}

__device__ __forceinline__ uint32_t keeloq_enc_528_dev(uint64_t key, uint32_t pt)
{
    uint32_t s = pt;
    #pragma unroll 1
    for (int i = 0; i < 528; i++) {
        uint8_t nlf_in = (uint8_t)(
            ((s >> 31) & 1) << 4 |
            ((s >> 26) & 1) << 3 |
            ((s >> 20) & 1) << 2 |
            ((s >>  9) & 1) << 1 |
            ((s >>  1) & 1)
        );
        uint8_t fb = ((NLF >> nlf_in) & 1)
                   ^ ((uint8_t)(key >> (i & 63)) & 1)
                   ^ ((s >> 16) & 1)
                   ^ (s & 1);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return s;
}

__device__ __forceinline__ uint16_t peel_k16_dev(uint32_t S, uint32_t C)
{
    uint16_t pk = 0;
    uint32_t s = S;
    #pragma unroll
    for (int i = 0; i < 16; i++) {
        uint8_t fb = (C >> (16 + i)) & 1;
        uint8_t nlf_in = (uint8_t)(
            ((s >> 31) & 1) << 4 |
            ((s >> 26) & 1) << 3 |
            ((s >> 20) & 1) << 2 |
            ((s >>  9) & 1) << 1 |
            ((s >>  1) & 1)
        );
        uint8_t ki = fb ^ ((NLF >> nlf_in) & 1) ^ ((s >> 16) & 1) ^ (s & 1);
        pk |= ((uint16_t)ki << i);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return pk;
}

/* -----------------------------------------------------------------------
 * nlf_bs — NLF on BS_LANES=32 state-words at once.
 * Each argument is a uint32_t bit-plane: bit l is the value for lane l.
 * Truth table 0x3A5C742E, inputs: a=x[1], b=x[9], c=x[20], d=x[26], e=x[31].
 * ----------------------------------------------------------------------- */
__device__ __forceinline__
uint32_t nlf_bs(uint32_t a, uint32_t b, uint32_t c, uint32_t d, uint32_t e)
{
    uint32_t ne = ~e, nd = ~d, nc = ~c, nb = ~b, na = ~a;
    uint32_t e1_d1 = (c & nb)  | (nc & a);
    uint32_t e1_d0 = (c & na)  | (nc & b);
    uint32_t e1    = (d & e1_d1) | (nd & e1_d0);
    uint32_t e0_d1 = (c & ((b & na) | nb)) | (nc & (b & na));
    uint32_t e0_d0 = (c & (nb & a))        | (nc & (b | (nb & a)));
    uint32_t e0    = (d & e0_d1) | (nd & e0_d0);
    return (e & e1) | (ne & e0);
}

/* -----------------------------------------------------------------------
 * phase1_scan_bs_kernel — bit-slice Phase 1 scan.
 *
 * Each thread encrypts BS_LANES=32 consecutive plaintexts simultaneously
 * using a 32-lane bit-plane representation.  The key is fixed for every
 * lane, so each round's key bit is a scalar broadcast (0 or ~0).
 *
 * Caller guarantees:
 *   start   is a multiple of BS_LANES  (chunk alignment ensures this)
 *   count   is a multiple of BS_LANES  (DEFAULT_CHUNK = 2^26 is exact)
 * ----------------------------------------------------------------------- */
__global__ void phase1_scan_bs_kernel(uint64_t key,
                                      uint64_t start,
                                      uint32_t count,
                                      uint32_t *outP,
                                      uint32_t *outC,
                                      uint16_t *outK16,
                                      uint32_t *outCount,
                                      uint32_t maxOut)
{
    /* LP[b] = bit b of lane index l, for l = 0..31 */
    constexpr uint32_t LP[5] = {
        0xAAAAAAAAu, 0xCCCCCCCCu, 0xF0F0F0F0u, 0xFF00FF00u, 0xFFFF0000u
    };

    uint64_t idx         = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    uint64_t base_offset = idx * (uint64_t)BS_LANES;
    if (base_offset >= (uint64_t)count) return;

    /* Plaintext of lane 0; pt_l = base_pt + l for l = 0..31.
     * base_pt & 0x1F == 0 is guaranteed (start is chunk-aligned, idx*32 is 32-aligned). */
    uint32_t base_pt = (uint32_t)(start + base_offset);

    /* ---- initialise 32 bit-planes from 32 consecutive plaintexts ----
     * Because base_pt & 0x1F == 0:
     *   bit b < 5 of pt_l  = bit b of l  → LP[b]
     *   bit b >= 5 of pt_l = bit b of base_pt (constant across all lanes) */
    uint32_t xs[32];
#pragma unroll
    for (int b = 0;           b < BS_LANES_BITS; b++) xs[b] = LP[b];
#pragma unroll
    for (int b = BS_LANES_BITS; b < 32;          b++)
        xs[b] = ((base_pt >> b) & 1U) ? 0xFFFFFFFFU : 0U;

    /* ---- precompute 64-entry key schedule; reused 8 cycles + 16 rounds ----
     * Key bit r is scalar — identical for all 32 lanes since key is fixed. */
    uint32_t ks[64];
#pragma unroll
    for (int r = 0; r < 64; r++)
        ks[r] = ((key >> r) & 1ULL) ? 0xFFFFFFFFU : 0U;

    /* ---- 528-round bit-slice encryption: 8 × 64 + 16 rounds ---- */
#pragma unroll 1
    for (int cyc = 0; cyc < 8; cyc++) {
#pragma unroll
        for (int r = 0; r < 64; r++) {
            uint32_t fb = nlf_bs(xs[1], xs[9], xs[20], xs[26], xs[31])
                        ^ xs[16] ^ xs[0] ^ ks[r];
            /* Shift state: new xs[31]=fb, new xs[b]=old xs[b+1] for b<31 */
            uint32_t prev = fb;
#pragma unroll
            for (int b = 31; b >= 0; --b) {
                uint32_t tmp = xs[b]; xs[b] = prev; prev = tmp;
            }
        }
    }
#pragma unroll
    for (int r = 0; r < 16; r++) {
        uint32_t fb = nlf_bs(xs[1], xs[9], xs[20], xs[26], xs[31])
                    ^ xs[16] ^ xs[0] ^ ks[r];
        uint32_t prev = fb;
#pragma unroll
        for (int b = 31; b >= 0; --b) {
            uint32_t tmp = xs[b]; xs[b] = prev; prev = tmp;
        }
    }

    /* ---- fixed-point filter: ct[0..15] must equal base_pt[16..31] ----
     * Because base_pt & 0x1F == 0, pt_l >> 16 == base_pt >> 16 for every l,
     * so the expected 16-bit pattern is identical across all 32 lanes. */
    uint32_t pass = 0xFFFFFFFFU;
#pragma unroll
    for (int b = 0; b < 16; b++) {
        uint32_t exp = ((base_pt >> (16 + b)) & 1U) ? 0xFFFFFFFFU : 0U;
        pass &= ~(xs[b] ^ exp);   /* XNOR: keep lanes where bit b matches */
    }
    if (pass == 0U) return;

    /* ---- process surviving lanes individually ---- */
    while (pass) {
        int l = __ffs(pass) - 1;   /* index of lowest set bit */
        pass &= pass - 1;          /* clear that bit */

        uint32_t pt_l = base_pt + (uint32_t)l;

        /* Reconstruct ciphertext for lane l from the 32 bit-planes */
        uint32_t ct_l = 0U;
#pragma unroll
        for (int b = 0; b < 32; b++)
            ct_l |= ((xs[b] >> l) & 1U) << b;

        uint16_t pk  = peel_k16_dev(pt_l, ct_l);
        uint32_t pos = atomicAdd(outCount, 1U);
        if (pos < maxOut) {
            outP[pos]   = pt_l;
            outC[pos]   = ct_l;
            outK16[pos] = pk;
        }
    }
}

__global__ void phase1_scan_kernel(uint64_t key,
                                   uint64_t start,
                                   uint32_t count,
                                   uint32_t *outP,
                                   uint32_t *outC,
                                   uint16_t *outK16,
                                   uint32_t *outCount,
                                   uint32_t maxOut)
{
    uint64_t idx = (uint64_t)blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= count) return;

    uint32_t pt = (uint32_t)(start + idx);
    uint32_t ct = keeloq_enc_528_dev(key, pt);

    if ((ct & 0xFFFFU) == (pt >> 16)) {
        uint16_t pk = peel_k16_dev(pt, ct);
        uint32_t pos = atomicAdd(outCount, 1U);
        if (pos < maxOut) {
            outP[pos] = pt;
            outC[pos] = ct;
            outK16[pos] = pk;
        }
    }
}

typedef struct {
    uint16_t k16;
    int      votes;
} k16_entry_t;

static int cmp_votes_desc(const void *a, const void *b)
{
    return ((const k16_entry_t *)b)->votes - ((const k16_entry_t *)a)->votes;
}

static void cuda_check(cudaError_t e, const char *what)
{
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error at %s: %s\n", what, cudaGetErrorString(e));
        exit(1);
    }
}

int main(int argc, char *argv[])
{
    int tpb = DEFAULT_TPB;
    uint64_t key = 0x5CEC6701B79FD949ULL;

    if (argc >= 2) {
        int x = atoi(argv[1]);
        if (x > 0) tpb = x;
    }
    if (argc >= 3) key = strtoull(argv[2], NULL, 0);

    int dev = 0;
    cuda_check(cudaSetDevice(dev), "cudaSetDevice");
    cudaDeviceProp prop;
    cuda_check(cudaGetDeviceProperties(&prop, dev), "cudaGetDeviceProperties");

    uint16_t real_k16 = (uint16_t)(key & 0xFFFFULL);

    printf("\n");
    printf("════════════════════════════════════════════════════════════════════════\n");
    printf("  KeeLoq Fixed-Point Attack // Phase 1 (GPU Scan + Vote)\n");
    printf("════════════════════════════════════════════════════════════════════════\n\n");
    printf("  [*] Key            : 0x%016llx\n", (unsigned long long)key);
    printf("  [*] Backend        : CUDA GPU (%s)\n", prop.name);
    printf("  [*] Threads/block  : %d\n", tpb);
    printf("  [*] Search space   : 2^32 plaintexts\n");
    printf("  [*] True k[0..15]  : 0x%04x\n\n", real_k16);

    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  [SCAN] Scanning 2^32 plaintexts on GPU...\n");
    printf("────────────────────────────────────────────────────────────────────────\n");

    uint32_t *dP = NULL, *dC = NULL, *dCount = NULL;
    uint16_t *dK16 = NULL;
    cuda_check(cudaMalloc((void **)&dP, sizeof(uint32_t) * MAX_SURVIVORS_CHUNK), "cudaMalloc dP");
    cuda_check(cudaMalloc((void **)&dC, sizeof(uint32_t) * MAX_SURVIVORS_CHUNK), "cudaMalloc dC");
    cuda_check(cudaMalloc((void **)&dK16, sizeof(uint16_t) * MAX_SURVIVORS_CHUNK), "cudaMalloc dK16");
    cuda_check(cudaMalloc((void **)&dCount, sizeof(uint32_t)), "cudaMalloc dCount");

    uint32_t *hP_chunk = (uint32_t *)malloc(sizeof(uint32_t) * MAX_SURVIVORS_CHUNK);
    uint32_t *hC_chunk = (uint32_t *)malloc(sizeof(uint32_t) * MAX_SURVIVORS_CHUNK);
    uint16_t *hK_chunk = (uint16_t *)malloc(sizeof(uint16_t) * MAX_SURVIVORS_CHUNK);

    uint32_t *allP = (uint32_t *)malloc(sizeof(uint32_t) * MAX_SURVIVORS_TOTAL);
    uint32_t *allC = (uint32_t *)malloc(sizeof(uint32_t) * MAX_SURVIVORS_TOTAL);
    uint16_t *allK = (uint16_t *)malloc(sizeof(uint16_t) * MAX_SURVIVORS_TOTAL);

    if (!hP_chunk || !hC_chunk || !hK_chunk || !allP || !allC || !allK) {
        fprintf(stderr, "memory allocation failed\n");
        return 1;
    }

    struct timeval t0, t1;
    gettimeofday(&t0, NULL);

    uint64_t processed = 0;
    uint32_t total_survivors = 0;
    uint64_t chunk = DEFAULT_CHUNK;

    while (processed < TOTAL_PLAINTEXTS) {
        uint32_t thisCount = (uint32_t)((TOTAL_PLAINTEXTS - processed) < chunk
                              ? (TOTAL_PLAINTEXTS - processed)
                              : chunk);

        uint32_t zero = 0;
        cuda_check(cudaMemcpy(dCount, &zero, sizeof(uint32_t), cudaMemcpyHostToDevice), "memcpy dCount=0");

        /* Each bit-slice thread covers BS_LANES=32 consecutive plaintexts.
         * thisCount is always a multiple of BS_LANES (DEFAULT_CHUNK = 2^26). */
        uint32_t bs_count = thisCount >> BS_LANES_BITS;  /* = thisCount / 32 */
        dim3 block((unsigned)tpb);
        dim3 grid((unsigned)((bs_count + (uint32_t)tpb - 1) / (uint32_t)tpb));
        phase1_scan_bs_kernel<<<grid, block>>>(key, processed, thisCount,
                                               dP, dC, dK16, dCount,
                                               MAX_SURVIVORS_CHUNK);
        cuda_check(cudaGetLastError(), "kernel launch");
        cuda_check(cudaDeviceSynchronize(), "kernel sync");

        uint32_t found = 0;
        cuda_check(cudaMemcpy(&found, dCount, sizeof(uint32_t), cudaMemcpyDeviceToHost), "copy dCount->host");
        if (found > MAX_SURVIVORS_CHUNK) found = MAX_SURVIVORS_CHUNK;

        if (found > 0) {
            cuda_check(cudaMemcpy(hP_chunk, dP, sizeof(uint32_t) * found, cudaMemcpyDeviceToHost), "copy dP");
            cuda_check(cudaMemcpy(hC_chunk, dC, sizeof(uint32_t) * found, cudaMemcpyDeviceToHost), "copy dC");
            cuda_check(cudaMemcpy(hK_chunk, dK16, sizeof(uint16_t) * found, cudaMemcpyDeviceToHost), "copy dK16");

            uint32_t room = (total_survivors < MAX_SURVIVORS_TOTAL) ? (MAX_SURVIVORS_TOTAL - total_survivors) : 0;
            uint32_t keep = (found < room) ? found : room;
            if (keep > 0) {
                memcpy(allP + total_survivors, hP_chunk, sizeof(uint32_t) * keep);
                memcpy(allC + total_survivors, hC_chunk, sizeof(uint32_t) * keep);
                memcpy(allK + total_survivors, hK_chunk, sizeof(uint16_t) * keep);
                total_survivors += keep;
            }
        }

        processed += thisCount;

        struct timeval now;
        gettimeofday(&now, NULL);
        double elapsed = (now.tv_sec - t0.tv_sec) + (now.tv_usec - t0.tv_usec) * 1e-6;
        if ((processed & ((1ULL << 29) - 1)) == 0 || processed == TOTAL_PLAINTEXTS) {
            printf("\r  [~] Progress: %6.2f%%  |  %.1fs  |  survivors=%u",
                   100.0 * (double)processed / (double)TOTAL_PLAINTEXTS,
                   elapsed, total_survivors);
            fflush(stdout);
        }
    }

    gettimeofday(&t1, NULL);
    double total_time = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) * 1e-6;
    printf("\n");

    printf("  [*] Done: %.1fs  (%.1f M enc/s)\n",
           total_time, (double)TOTAL_PLAINTEXTS / total_time / 1e6);
    printf("  [*] Survivors: %u  (expected ~%d)\n\n", total_survivors, 1 << 16);

    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  [VOTE] Majority vote on k[0..15]\n");
    printf("────────────────────────────────────────────────────────────────────────\n");

    int *hist = (int *)calloc(1 << 16, sizeof(int));
    if (!hist) { perror("calloc"); return 1; }

    for (uint32_t i = 0; i < total_survivors; i++) hist[allK[i]]++;

    uint16_t best_k16 = 0;
    int best_count = 0;
    int second_best = 0;
    for (int k = 0; k < (1 << 16); k++) {
        if (hist[k] > best_count) {
            second_best = best_count;
            best_count = hist[k];
            best_k16 = (uint16_t)k;
        } else if (hist[k] > second_best) {
            second_best = hist[k];
        }
    }

    int correct_count = hist[real_k16];
    printf("\n");
    printf("  ┌─────────────┬───────────┐\n");
    printf("  │     k16     │   votes   │\n");
    printf("  ├─────────────┼───────────┤\n");
    printf("  │ 0x%04x BEST │ %9d │\n", best_k16, best_count);
    printf("  │ 2nd best    │ %9d │\n", second_best);
    printf("  │ 0x%04x TRUE │ %9d │\n", real_k16, correct_count);
    printf("  └─────────────┴───────────┘\n");
    printf("  [*] Match: %s\n\n", best_k16 == real_k16 ? "YES" : "NO");

    #define MAX_GROUPS 65536
    int threshold = 1;

    k16_entry_t *top_list = (k16_entry_t *)malloc((1 << 16) * sizeof(k16_entry_t));
    if (!top_list) { perror("malloc"); return 1; }
    int ntop = 0;
    for (int k = 0; k < (1 << 16); k++) {
        if (hist[k] >= threshold) {
            top_list[ntop].k16 = (uint16_t)k;
            top_list[ntop].votes = hist[k];
            ntop++;
        }
    }
    qsort(top_list, ntop, sizeof(k16_entry_t), cmp_votes_desc);
    if (ntop > MAX_GROUPS) ntop = MAX_GROUPS;

    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  [GROUPS] Top k[0..15] candidates (votes >= %d)\n", threshold);
    printf("────────────────────────────────────────────────────────────────────────\n");
    int true_rank = -1;
    printf("\n");
    for (int g = 0; g < ntop; g++) {
        int is_true = (top_list[g].k16 == real_k16);
        if (is_true) true_rank = g + 1;
        if (g < 10 || is_true) {
            printf("  #%-4d  0x%04x  votes=%-5d%s\n", g + 1,
                   top_list[g].k16, top_list[g].votes,
                   is_true ? "  <<" : "");
        }
    }
    if (ntop > 10) {
        if (true_rank > 10)
            printf("  ...    +%d more  (true @ #%d)\n", ntop - 10, true_rank);
        else
            printf("  ...    +%d more\n", ntop - 10);
    }
    if (true_rank < 0)
        printf("  [!] WARNING: true k[0..15] not found in candidates!\n");
    printf("\n  [*] Total groups: %d\n\n", ntop);

    FILE *outfp = fopen("fixedpoint_data.txt", "w");
    if (!outfp) { perror("fopen"); return 1; }
    fprintf(outfp, "# KeeLoq Fixed-Point Attack — Phase 1 Output\n");
    fprintf(outfp, "# Top k[0..15] candidates sorted by vote count\n");
    fprintf(outfp, "# Format: [group] sections with S C M16 lines\n\n");
    fprintf(outfp, "# phase1_scan_seconds=%.6f\n", total_time);
    fprintf(outfp, "# phase1_threads=%d\n", tpb);
    fprintf(outfp, "# phase1_survivors=%u\n", total_survivors);
    fprintf(outfp, "# phase1_true_k16=0x%04x\n", real_k16);
    fprintf(outfp, "# phase1_true_votes=%d\n\n", correct_count);

    int total_fp = 0;
    for (int g = 0; g < ntop; g++) {
        uint16_t gk16 = top_list[g].k16;
        uint64_t partial_key = (uint64_t)gk16;

        fprintf(outfp, "[group]\n");
        fprintf(outfp, "k16=0x%04x\n", gk16);
        fprintf(outfp, "votes=%d\n", top_list[g].votes);

        for (uint32_t i = 0; i < total_survivors; i++) {
            if (allK[i] != gk16) continue;
            uint32_t S = allP[i];
            uint32_t C = allC[i];
            uint32_t M16 = keeloq_enc_offset_host(partial_key, S, 0, 16);
            fprintf(outfp, "0x%08x 0x%08x 0x%08x\n", S, C, M16);
            total_fp++;
        }
    }
    fclose(outfp);

    printf("  [*] Written %d groups (%d candidates) -> fixedpoint_data.txt\n\n",
           ntop, total_fp);

    printf("\n");
    printf("════════════════════════════════════════════════════════════════════════\n");
    printf("  PHASE 1 SUMMARY\n");
    printf("════════════════════════════════════════════════════════════════════════\n");
    printf("  Scan time      : %8.1fs  (%6.1f M enc/s)\n", total_time,
           (double)TOTAL_PLAINTEXTS / total_time / 1e6);
    printf("  Backend        : CUDA GPU\n");
    printf("  Threads/block  : %8d\n", tpb);
    printf("  Survivors      : %8u\n", total_survivors);
    printf("  ────────────────────────────────────────────────────────────────────\n");
    printf("  Best k16       :   0x%04x  (votes: %d)%s\n", best_k16, best_count,
           best_k16 == real_k16 ? " [OK]" : "");
    printf("  True k16       :   0x%04x  (votes: %d, rank: #%d)\n",
           real_k16, correct_count, true_rank);
    printf("  Groups         : %8d  (threshold >= %d)\n", ntop, threshold);
    printf("  ────────────────────────────────────────────────────────────────────\n");
    printf("  Output         : fixedpoint_data.txt\n");
    printf("  Next step      : python3 fixedpoint_sat.py\n");
    printf("════════════════════════════════════════════════════════════════════════\n");

    free(top_list);
    free(hist);
    free(hP_chunk); free(hC_chunk); free(hK_chunk);
    free(allP); free(allC); free(allK);

    cudaFree(dP); cudaFree(dC); cudaFree(dK16); cudaFree(dCount);
    return 0;
}
