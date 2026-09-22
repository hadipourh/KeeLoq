/*
 * fixedpoint_mt.c — Multithreaded Fixed-Point Attack on KeeLoq (Phase 1)
 *
 * Attack: Exploit fixed points of F^8 where F = E_64.
 *   For such S: E_528(K, S) = E_16(K, S) = C.
 *   Filter: C[0..15] == S[16..31]  (16-bit, prob 2^{-16}).
 *   Peel:   recover k[0..15] instantly from (S, C) via 16 XORs.
 *   Vote:   true fixed points agree on k[0..15]; false positives don't.
 *   Output: fixedpoint_data.txt with S, C, M16 for SAT Phase 2.
 *
 * Phase 2 (fixedpoint_sat.py):
 *   SAT recovers k[16..63] from 48-round constraints using M16.
 *
 * Compile:
 *   cc -O3 -march=native -o fixedpoint_mt fixedpoint_mt.c -lpthread
 *
 * Usage:
 *   ./fixedpoint_mt [num_threads] [key_hex]
 *
 * Defaults: 10 threads, key = 0x5CEC6701B79FD949
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <sys/time.h>

/* ------------------------------------------------------------------ */
/* KeeLoq constants                                                    */
/* ------------------------------------------------------------------ */

#define NLF 0x3A5C742EU

/* ------------------------------------------------------------------ */
/* Inline KeeLoq encryption — fully unrolled NLF, no function calls   */
/* ------------------------------------------------------------------ */

static inline uint32_t keeloq_enc_inline(uint64_t key, uint32_t pt, int nrounds)
{
    uint32_t s = pt;
    for (int i = 0; i < nrounds; i++) {
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

/* Encrypt rounds [start_round..start_round+nrounds) using key schedule offset */
static inline uint32_t keeloq_enc_offset(uint64_t key, uint32_t pt, int start_round, int nrounds)
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

/* ------------------------------------------------------------------ */
/* Peel 16 rounds: given (S, C) with E_16(K, S) = C, recover k[0..15] */
/* ------------------------------------------------------------------ */

static inline uint16_t peel_k16(uint32_t S, uint32_t C)
{
    uint16_t pk = 0;
    uint32_t s = S;
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

/* ------------------------------------------------------------------ */
/* Per-thread data                                                     */
/* ------------------------------------------------------------------ */

#define MAX_SURVIVORS_PER_THREAD (1 << 16)

typedef struct {
    /* input */
    int         thread_id;
    uint64_t    key;
    uint64_t    range_start;
    uint64_t    range_end;

    /* output */
    uint32_t    surv_P[MAX_SURVIVORS_PER_THREAD];
    uint32_t    surv_C[MAX_SURVIVORS_PER_THREAD];
    uint16_t    surv_k16[MAX_SURVIVORS_PER_THREAD];
    int         surv_count;
    double      elapsed;
} thread_data_t;

/* ------------------------------------------------------------------ */
/* Worker thread                                                       */
/* ------------------------------------------------------------------ */

static void *worker(void *arg)
{
    thread_data_t *td = (thread_data_t *)arg;
    uint64_t key   = td->key;
    uint64_t start = td->range_start;
    uint64_t end   = td->range_end;
    int count = 0;

    struct timeval tv0, tv1;
    gettimeofday(&tv0, NULL);

    for (uint64_t p = start; p < end; p++) {
        uint32_t pt = (uint32_t)p;

        /* --- Inline 528-round encryption --- */
        uint32_t ct = keeloq_enc_inline(key, pt, 528);

        /* --- Filter: C[0..15] == P[16..31] --- */
        if ((ct & 0xFFFF) == (pt >> 16)) {
            if (count < MAX_SURVIVORS_PER_THREAD) {
                td->surv_P[count]   = pt;
                td->surv_C[count]   = ct;
                td->surv_k16[count] = peel_k16(pt, ct);
                count++;
            }
        }
    }

    td->surv_count = count;

    gettimeofday(&tv1, NULL);
    td->elapsed = (tv1.tv_sec - tv0.tv_sec) + (tv1.tv_usec - tv0.tv_usec) * 1e-6;

    return NULL;
}

/* ------------------------------------------------------------------ */
/* Progress reporter thread                                            */
/* ------------------------------------------------------------------ */

typedef struct {
    thread_data_t *threads;
    int            nthreads;
    uint64_t       total;
    volatile int  *done_flag;
} progress_data_t;

static void *progress_reporter(void *arg)
{
    progress_data_t *pd = (progress_data_t *)arg;
    struct timeval tv0;
    gettimeofday(&tv0, NULL);

    while (!*pd->done_flag) {
        struct timespec ts = { .tv_sec = 2, .tv_nsec = 0 };
        nanosleep(&ts, NULL);
        if (*pd->done_flag) break;

        struct timeval tvn;
        gettimeofday(&tvn, NULL);
        double elapsed = (tvn.tv_sec - tv0.tv_sec) + (tvn.tv_usec - tv0.tv_usec) * 1e-6;

        /* Estimate progress from thread ranges (rough) */
        int total_surv = 0;
        for (int i = 0; i < pd->nthreads; i++)
            total_surv += pd->threads[i].surv_count;

        fprintf(stderr, "\r  [%.0fs] survivors so far: %d  ", elapsed, total_surv);
        fflush(stderr);
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* k[0..15] candidate entry for multi-group output                     */
/* ------------------------------------------------------------------ */

typedef struct {
    uint16_t k16;
    int      votes;
} k16_entry_t;

static int cmp_votes_desc(const void *a, const void *b)
{
    return ((const k16_entry_t *)b)->votes - ((const k16_entry_t *)a)->votes;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    int nthreads = 10;
    uint64_t key = 0x5CEC6701B79FD949ULL;

    if (argc > 1) nthreads = atoi(argv[1]);
    if (argc > 2) key = strtoull(argv[2], NULL, 16);
    if (nthreads < 1) nthreads = 1;
    if (nthreads > 256) nthreads = 256;

    uint16_t real_k16 = (uint16_t)(key & 0xFFFF);
    uint64_t total = 1ULL << 32;

    printf("\n");
    printf("════════════════════════════════════════════════════════════════════════\n");
    printf("  KeeLoq Fixed-Point Attack // Phase 1 (Scan + Vote)\n");
    printf("════════════════════════════════════════════════════════════════════════\n");
    printf("\n");
    printf("  [*] Key            : 0x%016llx\n", (unsigned long long)key);
    printf("  [*] Threads        : %d\n", nthreads);
    printf("  [*] Search space   : 2^32 plaintexts\n");
    printf("  [*] True k[0..15]  : 0x%04x\n", real_k16);
    printf("\n");

    /* ---- Allocate thread data ---- */
    thread_data_t *threads = calloc(nthreads, sizeof(thread_data_t));
    if (!threads) { perror("calloc"); return 1; }

    /* ---- Divide work ---- */
    uint64_t chunk = total / nthreads;
    for (int i = 0; i < nthreads; i++) {
        threads[i].thread_id   = i;
        threads[i].key         = key;
        threads[i].range_start = i * chunk;
        threads[i].range_end   = (i == nthreads - 1) ? total : (i + 1) * chunk;
        threads[i].surv_count  = 0;
    }

    /* ---- Launch threads ---- */
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  [SCAN] Scanning 2^32 plaintexts...\n");
    printf("────────────────────────────────────────────────────────────────────────\n");
    fflush(stdout);

    struct timeval t0, t1;
    gettimeofday(&t0, NULL);

    volatile int done_flag = 0;
    progress_data_t pdata = { threads, nthreads, total, &done_flag };
    pthread_t progress_tid;
    pthread_create(&progress_tid, NULL, progress_reporter, &pdata);

    pthread_t *tids = malloc(nthreads * sizeof(pthread_t));
    for (int i = 0; i < nthreads; i++) {
        pthread_create(&tids[i], NULL, worker, &threads[i]);
    }

    for (int i = 0; i < nthreads; i++) {
        pthread_join(tids[i], NULL);
    }

    done_flag = 1;
    pthread_join(progress_tid, NULL);
    fprintf(stderr, "\r                                                  \r");

    gettimeofday(&t1, NULL);
    double total_time = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) * 1e-6;

    /* ---- Gather results ---- */
    int total_survivors = 0;
    for (int i = 0; i < nthreads; i++)
        total_survivors += threads[i].surv_count;

    printf("  [*] Done: %.1fs  (%.1f M enc/s)\n", total_time,
           total / total_time / 1e6);
    printf("  [*] Survivors: %d  (expected ~%d)\n\n", total_survivors, 1 << 16);

    /* ---- Phase 2: Majority vote on k[0..15] ---- */
    printf("────────────────────────────────────────────────────────────────────────\n");
    printf("  [VOTE] Majority vote on k[0..15]\n");
    printf("────────────────────────────────────────────────────────────────────────\n");

    int *hist = calloc(1 << 16, sizeof(int));
    if (!hist) { perror("calloc"); return 1; }

    for (int i = 0; i < nthreads; i++) {
        for (int j = 0; j < threads[i].surv_count; j++) {
            hist[threads[i].surv_k16[j]]++;
        }
    }

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

    /* ---- Phase 3: Collect top k[0..15] candidates ---- */
    /*
     * With ~2^16 survivors in 2^16 bins, false-positive occupancy is
     * approximately Poisson(1), so raw vote ranking is noisy.
     * Keep threshold=1 so low-vote true groups are not dropped.
     */
    #define MAX_GROUPS 65536
    int threshold = 1;

    k16_entry_t *top_list = malloc((1 << 16) * sizeof(k16_entry_t));
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

    /* ---- Write multi-group fixedpoint_data.txt ---- */
    FILE *outfp = fopen("fixedpoint_data.txt", "w");
    if (!outfp) { perror("fopen"); return 1; }
    fprintf(outfp, "# KeeLoq Fixed-Point Attack — Phase 1 Output\n");
    fprintf(outfp, "# Top k[0..15] candidates sorted by vote count\n");
    fprintf(outfp, "# Format: [group] sections with S C M16 lines\n\n");
    fprintf(outfp, "# phase1_scan_seconds=%.6f\n", total_time);
    fprintf(outfp, "# phase1_threads=%d\n", nthreads);
    fprintf(outfp, "# phase1_survivors=%d\n", total_survivors);
    fprintf(outfp, "# phase1_true_k16=0x%04x\n", real_k16);
    fprintf(outfp, "# phase1_true_votes=%d\n\n", correct_count);

    int total_fp = 0;
    for (int g = 0; g < ntop; g++) {
        uint16_t gk16 = top_list[g].k16;
        uint64_t partial_key = (uint64_t)gk16;

        fprintf(outfp, "[group]\n");
        fprintf(outfp, "k16=0x%04x\n", gk16);
        fprintf(outfp, "votes=%d\n", top_list[g].votes);

        for (int i = 0; i < nthreads; i++) {
            for (int j = 0; j < threads[i].surv_count; j++) {
                if (threads[i].surv_k16[j] != gk16) continue;
                uint32_t S = threads[i].surv_P[j];
                uint32_t C = threads[i].surv_C[j];
                uint32_t M16 = keeloq_enc_offset(partial_key, S, 0, 16);
                fprintf(outfp, "0x%08x 0x%08x 0x%08x\n", S, C, M16);
                total_fp++;
            }
        }
    }
    fclose(outfp);
    printf("  [*] Written %d groups (%d candidates) -> fixedpoint_data.txt\n\n",
           ntop, total_fp);

        /* ---- Summary ---- */
        printf("\n");
        printf("════════════════════════════════════════════════════════════════════════\n");
        printf("  PHASE 1 SUMMARY\n");
        printf("════════════════════════════════════════════════════════════════════════\n");
        printf("  Scan time      : %8.1fs  (%6.1f M enc/s)\n", total_time,
            total / total_time / 1e6);
        printf("  Threads        : %8d\n", nthreads);
        printf("  Survivors      : %8d\n", total_survivors);
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
    free(tids);
    free(threads);
    return 0;
}
