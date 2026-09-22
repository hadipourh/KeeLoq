/*
 * verify_cube_par.c — Parallel empirical cube-sum verification for KeeLoq
 *
 * Splits the 2^dim cube iteration space across all available CPU cores
 * using pthreads. Tests multiple random keys for key-independence.
 *
 * Usage:
 *   ./verify_cube_par <nrounds> <nkeys> <seed> <cube_bit0> [cube_bit1 ...]
 *
 * Example (dim-31, const_bit=31):
 *   ./verify_cube_par 48 5 42  0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 \
 *                               16 17 18 19 20 21 22 23 24 25 26 27 28 29 30
 *
 * Output (stdout, machine-parseable):
 *   BALANCED <count> <bit0> <bit1> ...
 *
 * Progress and timing go to stderr.
 *
 * Compile:
 *   gcc -O2 -o verify_cube_par verify_cube_par.c -lpthread
 *
 * Override thread count:
 *   NTHREADS=4 ./verify_cube_par ...
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>

/* ── Inline KeeLoq encryption (no external dependency) ──────────────── */

#define NLF_LUT 0x3a5c742eU

static inline uint32_t keeloq_enc(uint64_t key, uint32_t pt, int nrounds)
{
    uint32_t s = pt;
    for (int i = 0; i < nrounds; i++) {
        int ni = (((s >> 31) & 1) << 4) |
                 (((s >> 26) & 1) << 3) |
                 (((s >> 20) & 1) << 2) |
                 (((s >>  9) & 1) << 1) |
                 ((s >>  1) & 1);
        uint32_t fb = ((NLF_LUT >> ni) & 1) ^
                      ((uint32_t)((key >> (i % 64)) & 1)) ^
                      ((s >> 16) & 1) ^
                      (s & 1);
        s = (s >> 1) | (fb << 31);
    }
    return s;
}

/* ── xorshift64 PRNG (deterministic, seeded) ────────────────────────── */

static uint64_t rng_state;

static void   rng_seed(uint64_t s) { rng_state = s ? s : 1; }
static uint64_t rng_next(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >>  7;
    x ^= x << 17;
    return (rng_state = x);
}

/* ── Parallel cube-sum computation ──────────────────────────────────── */

#define MAX_DIM     32
#define MAX_THREADS 512

/* Shared (read-only after setup) configuration */
static int g_nrounds;
static int g_cube_dim;
static int g_cube_bits[MAX_DIM];
static int g_is_identity;   /* 1 ⇔ cube_bits = {0,1,…,dim-1} */

typedef struct {
    uint64_t key;
    uint64_t start;          /* inclusive */
    uint64_t end;            /* exclusive */
    uint32_t partial_xor;    /* result written by thread */
} work_t;

static void *worker(void *arg)
{
    work_t  *w   = (work_t *)arg;
    uint32_t xor = 0;
    uint64_t key = w->key;
    int      nr  = g_nrounds;

    if (g_is_identity) {
        /* Fast path: plaintext == index (no bit-scatter needed) */
        for (uint64_t idx = w->start; idx < w->end; idx++)
            xor ^= keeloq_enc(key, (uint32_t)idx, nr);
    } else {
        /* General path: scatter index bits into plaintext positions */
        int dim = g_cube_dim;
        for (uint64_t idx = w->start; idx < w->end; idx++) {
            uint32_t pt = 0;
            for (int b = 0; b < dim; b++)
                if (idx & (1ULL << b))
                    pt |= (1u << g_cube_bits[b]);
            xor ^= keeloq_enc(key, pt, nr);
        }
    }

    w->partial_xor = xor;
    return NULL;
}

/* ── main ───────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    if (argc < 5) {
        fprintf(stderr,
            "Usage: %s <nrounds> <nkeys> <seed> <cube_bit0> [cube_bit1 ...]\n"
            "\n"
            "  Computes the XOR cube sum over 2^dim plaintexts for <nkeys>\n"
            "  random keys, using all available CPU cores.\n"
            "\n"
            "  Environment:\n"
            "    NTHREADS=N   override automatic core detection\n"
            "\n"
            "  Output (stdout):  BALANCED <count> [bit0 bit1 ...]\n"
            "  Progress (stderr)\n",
            argv[0]);
        return 1;
    }

    /* ── Parse arguments ──────────────────────────────────────────── */
    g_nrounds = atoi(argv[1]);
    int     nkeys = atoi(argv[2]);
    uint64_t seed = strtoull(argv[3], NULL, 10);
    g_cube_dim    = argc - 4;

    if (g_cube_dim < 1 || g_cube_dim > MAX_DIM) {
        fprintf(stderr, "Error: cube dimension %d out of range [1,%d]\n",
                g_cube_dim, MAX_DIM);
        return 1;
    }

    for (int i = 0; i < g_cube_dim; i++) {
        g_cube_bits[i] = atoi(argv[4 + i]);
        if (g_cube_bits[i] < 0 || g_cube_bits[i] > 31) {
            fprintf(stderr, "Error: cube bit %d out of range [0,31]\n",
                    g_cube_bits[i]);
            return 1;
        }
    }

    /* Check for identity scatter (cube = {0,1,…,dim-1}) */
    g_is_identity = 1;
    for (int i = 0; i < g_cube_dim; i++)
        if (g_cube_bits[i] != i) { g_is_identity = 0; break; }

    /* ── Detect CPU cores dynamically ─────────────────────────────── */
    int nthreads = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (nthreads < 1) nthreads = 1;
    if (nthreads > MAX_THREADS) nthreads = MAX_THREADS;

    /* Allow override via environment variable */
    const char *env_t = getenv("NTHREADS");
    if (env_t) {
        int v = atoi(env_t);
        if (v >= 1 && v <= MAX_THREADS) nthreads = v;
    }

    uint64_t total = 1ULL << g_cube_dim;

    fprintf(stderr,
        "KeeLoq Parallel Cube Verification\n"
        "  Rounds   = %d\n"
        "  Cube dim = %d  (identity scatter: %s)\n"
        "  Keys     = %d  (seed %llu)\n"
        "  Threads  = %d\n"
        "  Texts    = 2^%d = %llu\n\n",
        g_nrounds, g_cube_dim,
        g_is_identity ? "YES — fast path" : "no",
        nkeys, (unsigned long long)seed,
        nthreads, g_cube_dim, (unsigned long long)total);

    /* ── Key-independence loop ────────────────────────────────────── */
    uint32_t all_balanced = 0xFFFFFFFF;   /* bits 0 for ALL keys */
    uint32_t all_one      = 0xFFFFFFFF;   /* bits 1 for ALL keys */
    rng_seed(seed);

    struct timespec wall0, wall1;
    clock_gettime(CLOCK_MONOTONIC, &wall0);

    for (int ki = 0; ki < nkeys; ki++) {
        uint64_t key = rng_next();

        /* Partition the iteration space across threads */
        pthread_t tids[MAX_THREADS];
        work_t    works[MAX_THREADS];
        uint64_t  chunk = total / (uint64_t)nthreads;
        uint64_t  rem   = total % (uint64_t)nthreads;
        uint64_t  off   = 0;

        for (int t = 0; t < nthreads; t++) {
            works[t].key   = key;
            works[t].start = off;
            uint64_t sz    = chunk + ((uint64_t)t < rem ? 1 : 0);
            works[t].end   = off + sz;
            works[t].partial_xor = 0;
            off = works[t].end;
        }

        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);

        for (int t = 0; t < nthreads; t++)
            pthread_create(&tids[t], NULL, worker, &works[t]);
        for (int t = 0; t < nthreads; t++)
            pthread_join(tids[t], NULL);

        clock_gettime(CLOCK_MONOTONIC, &t1);

        /* Gather partial results */
        uint32_t xor_sum = 0;
        for (int t = 0; t < nthreads; t++)
            xor_sum ^= works[t].partial_xor;

        double dt = (t1.tv_sec - t0.tv_sec) +
                    (t1.tv_nsec - t0.tv_nsec) * 1e-9;
        all_balanced &= ~xor_sum;
        all_one      &= xor_sum;

        int bal = __builtin_popcount(~xor_sum);
        fprintf(stderr, "  Key %2d/%d  %016llX  sum=%08X  balanced=%2d/32  (%.1fs)\n",
                ki + 1, nkeys,
                (unsigned long long)key, xor_sum, bal, dt);
    }

    clock_gettime(CLOCK_MONOTONIC, &wall1);
    double total_time = (wall1.tv_sec - wall0.tv_sec) +
                        (wall1.tv_nsec - wall0.tv_nsec) * 1e-9;

    /* ── Report ───────────────────────────────────────────────────── */
    /* Key-independent = same value for ALL keys (either always 0 or always 1) */
    uint32_t all_key_indep = all_balanced | all_one;

    int bal_count = 0;
    for (int j = 0; j < 32; j++)
        if ((all_balanced >> j) & 1) bal_count++;
    int ki_count = 0;
    for (int j = 0; j < 32; j++)
        if ((all_key_indep >> j) & 1) ki_count++;

    /* Machine-parseable lines on stdout */
    printf("BALANCED %d", bal_count);
    for (int j = 0; j < 32; j++)
        if ((all_balanced >> j) & 1) printf(" %d", j);
    printf("\n");

    printf("KEY_INDEPENDENT %d", ki_count);
    for (int j = 0; j < 32; j++)
        if ((all_key_indep >> j) & 1) printf(" %d", j);
    printf("\n");

    fprintf(stderr, "\nDone: %d key-independent bits (%d always-0, %d always-1) in %.1fs\n",
            ki_count, bal_count, ki_count - bal_count, total_time);

    return 0;
}
