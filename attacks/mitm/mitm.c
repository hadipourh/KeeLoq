/*
 * mitm.c — Slide + Meet-in-the-Middle Attack on KeeLoq
 *
 * REFERENCE:
 *   Indesteege, Keller, Dunkelman, Biham, Preneel.
 *   "A Practical Attack on KeeLoq", EUROCRYPT 2008, LNCS 4965, pp. 1-18.
 *   https://doi.org/10.1007/978-3-540-78967-3_1
 *
 * THEORY:
 *   KeeLoq = g_{k0} ∘ F^8   where F = E_64, g_{k0} = E_16 using k[0..15].
 *
 *   A "slid pair" (P_i, P_j) satisfies  F(P_i) = P_j.
 *   With 2^16 random KP, birthday paradox gives a slid pair w.p. ≈ 0.63.
 *
 *   For the correct k̂₀ = k[0..15]:
 *     X_i = g_{k̂₀}(P_i)       (forward 16 rounds from plaintext)
 *     Y_j = g_{k̂₀}^{-1}(C_j)  (backward 16 rounds from ciphertext)
 *
 *   For the correct guess of P*_j[lo 16 bits] = underP*j:
 *     k̂₃ = k[48..63] determined from P_j + underP*j via linear extraction
 *     Y*_j = g_{k̂₃}^{-1}(Y_j)  (backward 16 more rounds)
 *
 *   From the plaintext side for each P_i:
 *     k̂₁ = k[16..31] determined from X_i + X*_i via linear extraction
 *     C*_i = g_{k̂₁}(C_i)        (forward 16 more rounds on ciphertext)
 *
 *   MitM condition: C*_i[hi 16 bits] == Y*_j[lo 16 bits]
 *   Then k̂₂ = k[32..47] from X*_i + P*_j gives the full key.
 *
 * COMPLEXITY:
 *   Outer loop: 2^16 values of k̂₀
 *   Inner loop: 2^16 guesses of underP*j × 2^16 plaintexts = 2^32 per k̂₀
 *   Total: about 2^45.0 full KeeLoq encryptions for the basic 16/16/16 profile.
 *   Parallelised over NUM_THREADS; each thread handles a slice of k̂₀.
 *
 * DATA: 2^16 known plaintext-ciphertext pairs (P[i], C[i]).
 *
 * COMPILE:
 *   cc -O3 -march=native -pthread -o mitm mitm.c
 *
 * USAGE:
 *   ./mitm [num_threads] [key_hex]
 *   key_hex is optional; used only for self-test data generation + verification.
 *   This program always generates self-test data internally.
 *
 * DEFAULTS:
 *   threads = number of hardware threads, key = 0x5CEC6701B79FD949
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/* Compile-time knobs                                                  */
/* ------------------------------------------------------------------ */

#define DATA_BITS    16          /* use 2^DATA_BITS known plaintexts   */
#define NUM_PAIRS    (1u << DATA_BITS)

/* ------------------------------------------------------------------ */
/* KeeLoq primitive                                                    */
/* ------------------------------------------------------------------ */

#define NLF_CONST 0x3A5C742EU

static inline uint8_t nlf_bit(uint32_t s)
{
    uint8_t idx = (uint8_t)(
        ((s >> 31) & 1u) << 4 |
        ((s >> 26) & 1u) << 3 |
        ((s >> 20) & 1u) << 2 |
        ((s >>  9) & 1u) << 1 |
        ((s >>  1) & 1u)
    );
    return (NLF_CONST >> idx) & 1u;
}


/* ------------------------------------------------------------------ */
/* Single-round decrypt helper                                         */
/* ------------------------------------------------------------------ */

/*
 * One forward round:
 *   fb = nlf(s[31],s[26],s[20],s[9],s[1]) ^ k[ki] ^ s[16] ^ s[0]
 *   s' = (s >> 1) | (fb << 31)
 *
 * Inverse: given s', recover s.
 *   s[1..31] = s'[0..30]  =>  s & 0xFFFFFFFE = (s' << 1) & 0xFFFFFFFE
 *   s[0] = fb ^ nlf(s[31],s[26],s[20],s[9],s[1]) ^ k[ki] ^ s[16]
 *         = s'[31] ^ nlf(s'[30],s'[25],s'[19],s'[8],s'[0]) ^ k[ki] ^ s'[15]
 */
static inline uint32_t keeloq_dec_one_round(uint64_t key, uint32_t sp, int ki)
{
    uint8_t nlf_idx = (uint8_t)(
        ((sp >> 30) & 1u) << 4 |
        ((sp >> 25) & 1u) << 3 |
        ((sp >> 19) & 1u) << 2 |
        ((sp >>  8) & 1u) << 1 |
        ((sp >>  0) & 1u)
    );
    uint8_t bit0 = ((sp >> 31) & 1u)
                 ^ ((NLF_CONST >> nlf_idx) & 1u)
                 ^ ((uint8_t)(key >> ki) & 1u)
                 ^ ((sp >> 15) & 1u);
    return ((sp << 1) & 0xFFFFFFFEu) | (uint32_t)bit0;
}

/* Forward: nrounds starting at ki */
static inline uint32_t enc_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
{
    for (int i = 0; i < nrounds; i++) {
        uint8_t nlf_idx = (uint8_t)(
            ((s >> 31) & 1u) << 4 |
            ((s >> 26) & 1u) << 3 |
            ((s >> 20) & 1u) << 2 |
            ((s >>  9) & 1u) << 1 |
            ((s >>  1) & 1u)
        );
        uint8_t fb = ((NLF_CONST >> nlf_idx) & 1u)
                   ^ ((uint8_t)(key >> ((ki + i) & 63)) & 1u)
                   ^ ((s >> 16) & 1u)
                   ^ (s & 1u);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return s;
}

/* Backward: nrounds, undoing rounds [ki .. ki+nrounds-1] applied in reverse */
static inline uint32_t dec_rounds(uint64_t key, uint32_t s, int ki, int nrounds)
{
    for (int i = nrounds - 1; i >= 0; i--)
        s = keeloq_dec_one_round(key, s, (ki + i) & 63);
    return s;
}

/* Full 528-round encrypt */
static inline uint32_t keeloq_enc_full(uint64_t key, uint32_t pt)
{
    return enc_rounds(key, pt, 0, 528);
}

/* ------------------------------------------------------------------ */
/* Linear key extraction (Bogdanov / Indesteege Sect 3.2)             */
/*                                                                     */
/* Given states A = state after round `start` and B = state after     */
/* round `start + t` (t ≤ 32), recover key bits k[start..start+t-1]. */
/* Returns extracted key bits as a 64-bit mask (bits at positions      */
/* start..start+t-1 set correctly, all others 0).                     */
/* ------------------------------------------------------------------ */

static inline uint64_t extract_key_bits(uint32_t A, uint32_t B,
                                        int start, int t)
{
    /*
     * A is the state before t rounds; B is the state after t rounds (t ≤ 32).
     * KeeLoq NLFSR shift: s' = (s >> 1) | (fb << 31).
     *
     * After t rounds:
     *   B[31:32-t]   = feedback bits fb_0..fb_{t-1}  (fb_0 oldest, at B[32-t]).
     *   B[31-t:0]    = A[31:t]  (original high bits shifted right by t).
     *
     * More precisely, after round i (0-indexed), fb_i is placed at bit 31 and
     * shifts right t-1-i more times: fb_i ends up at B[31-(t-1-i)] = B[32-t+i].
     * So: fb_i = (B >> (32 - t + i)) & 1   for i = 0 .. t-1.
     *
     * Passthrough check: A[31:t] -> B[31-t:0]  =>  (A >> t) == (B & ((1<<(32-t))-1)).
     */
    uint64_t kbits = 0;
    uint32_t s = A;
    for (int i = 0; i < t; i++) {
        uint8_t fb = (B >> (32 - t + i)) & 1u;
        uint8_t nlf_idx = (uint8_t)(
            ((s >> 31) & 1u) << 4 |
            ((s >> 26) & 1u) << 3 |
            ((s >> 20) & 1u) << 2 |
            ((s >>  9) & 1u) << 1 |
            ((s >>  1) & 1u)
        );
        uint8_t ki_bit = fb
                       ^ ((NLF_CONST >> nlf_idx) & 1u)
                       ^ ((s >> 16) & 1u)
                       ^ (s & 1u);
        int pos = (start + i) & 63;
        kbits |= ((uint64_t)ki_bit << pos);
        s = (s >> 1) | ((uint32_t)fb << 31);
    }
    return kbits;
}

/* ------------------------------------------------------------------ */
/* Hash table for the MitM step                                        */
/* For each key k̂₀ and underP*j guess we store all N right-side        */
/* candidates in per-bucket linked lists indexed by Y*_j[15:0].        */
/* This preserves completeness: no bucket overflow can drop records.   */
/* ------------------------------------------------------------------ */

typedef struct {
    uint32_t y_star;   /* full 32-bit Y*_j                            */
    uint32_t p_star_lo16; /* underP*j (for key recovery later)        */
    uint64_t k3_bits;  /* k̂₃ = k[48..63]                             */
    uint32_t idx;      /* plaintext index j                           */
    uint32_t pj;       /* plaintext P_j                               */
    uint32_t cj;       /* ciphertext C_j                              */
    uint32_t xj;       /* X_j = g_{k0}(P_j)                          */
    uint32_t yj;       /* Y_j = g_{k0}^{-1}(C_j)                     */
    uint32_t valid;
} HTableEntry;

#define HT_EMPTY (-1)

/* Per-thread shared state */
static uint32_t g_P[NUM_PAIRS];  /* plaintexts  */
static uint32_t g_C[NUM_PAIRS];  /* ciphertexts */

/* ------------------------------------------------------------------ */
/* Per-thread work                                                     */
/* ------------------------------------------------------------------ */

typedef struct {
    uint32_t k0_start;   /* first k̂₀ value for this thread */
    uint32_t k0_end;     /* last+1 */
    uint64_t true_key;   /* for verification (0 = unknown) */
    /* output */
    int      found;
    uint64_t recovered_key;
    double   elapsed_s;
} ThreadArg;

static volatile int g_done = 0;  /* set to 1 when any thread finds the key */

/*
 * Basic 16/16/16 geometry from Indesteege et al. Sect. 3.3:
 *
 *   Pi --[enc 16, k0]--> Xi --[enc 16, k1]--> X*i
 *   Ci --[dec 16, k0]--> Yi <--[dec 16, k3]-- Y*j
 *   Pj <--[enc 16, k3]-- P*j
 *
 * Passthrough facts for t = 16:
 *   Forward:  B[15:0]  = A[31:16],  B[31:16] = new enc bits
 *   Backward: B[31:16] = A[15:0],   B[15:0]  = new dec bits
 *
 * Hence, for a guessed underP*j = P*j[15:0], the full state P*j is known:
 *   P*j = (Pj[15:0] << 16) | underP*j
 * and k3 = k[48..63] follows from extract_key_bits(P*j, Pj, 48, 16).
 *
 * Similarly, for a fixed underP*j the overlap condition sets X*i[31:16] to
 * underP*j, while the forward passthrough fixes X*i[15:0] = Xi[31:16]. Thus
 *   X*i = (underP*j << 16) | (Xi >> 16)
 * and k1 = k[16..31] follows from extract_key_bits(Xi, X*i, 16, 16).
 *
 * The meet in the middle test is then
 *   C*i[31:16] == Y*j[15:0],
 * after which k2 = k[32..47] is extracted from both paths and cross checked.
 */

/* Build P*j from Pj and underP*j = P*j[15:0] */
static inline uint32_t make_pstar(uint32_t Pj, uint32_t underP)
{
    /* dec passthrough: P*j[31:16] = Pj[15:0];  P*j[15:0] = underP (new dec bits) */
    return ((Pj & 0xFFFFu) << 16) | (underP & 0xFFFFu);
}

/* Build X*_i from Xi and the guessed overlap: high half = guessed enc bits, low half = passthrough */
static inline uint32_t make_xstar(uint32_t Xi, uint32_t upj)
{
    /* X*i[31:16] = upj; X*i[15:0] = Xi[31:16] by forward passthrough */
    return ((upj & 0xFFFFu) << 16) | (Xi >> 16);
}

static void *attack_thread(void *arg)
{
    ThreadArg *ta = (ThreadArg *)arg;
    struct timeval tv0, tv1;
    gettimeofday(&tv0, NULL);

    /*
     * Hash table — allocated per-thread to avoid false sharing.
     *
     * PASSTHROUGH FACTS (t=16 rounds):
     *   Forward:  B[15:0]  = A[31:16]  (high bits shift to low — passthrough)
     *             B[31:16] = new enc bits (key-dependent)
     *   Backward: B[31:16] = A[15:0]   (low bits shift to high — passthrough)
     *             B[15:0]  = new dec bits (key-dependent)
     *
     * CIPHERTEXT-SIDE HT BUILD (for each upj and each j):
     *   P*j  = dec 16 rounds (k3) from Pj
     *          P*j[31:16] = Pj[15:0]  (passthrough)
     *          P*j[15:0]  = upj        (guess; these are the key-dep dec bits)
     *   k3   = extract_key_bits(P*j, Pj, 48, 16)
     *   Y*j  = dec 16 rounds (k3) from Yj
     *          Y*j[31:16] = Yj[15:0]  (passthrough, FREE from k3)
     *          Y*j[15:0]  = new key-dep dec bits
    *   Store in HT keyed by Y*j[15:0] (the new dec bits)
     *
        * PLAINTEXT-SIDE PROBE (for each i):
        *   Overlap condition (slid pair): X*i[31:16] == P*j[15:0] == upj
     *   X*i  = enc 16 rounds (k1) from Xi
     *          X*i[15:0]  = Xi[31:16]  (passthrough)
     *          X*i[31:16] = upj        (== P*j[15:0]; this is the slid condition)
     *   k1   = extract_key_bits(Xi, X*i, 16, 16)
     *   C*i  = enc 16 rounds (k1) from Ci
     *          C*i[15:0]  = Ci[31:16]   (passthrough)
     *          C*i[31:16] = new enc bits
     *
     * MitM MATCH: enc_rounds(k2, C*i) == Y*j  (16 fwd rounds with k[32..47])
     *   Passthrough tells us: Y*j[15:0] == C*i[31:16]  (necessary, free from k2)
     *   So HT is indexed by Y*j[15:0] (new dec bits) and probed with C*i[31:16].
     *   => HT key = ystar & 0xFFFF, probe key = cstar >> 16.
     *
     * ON A COLLISION:
     *   k2 = extract_key_bits(C*i, Y*j, 32, 16)
     *   Verify with extract_key_bits(X*i, P*j, 32, 16) (should match k2)
     *   Assemble full key = k0 | k1 | k2 | k3 and verify vs. known pairs.
     */
    HTableEntry *ht_records = (HTableEntry *)malloc(NUM_PAIRS * sizeof(HTableEntry));
    int32_t *ht_next = (int32_t *)malloc(NUM_PAIRS * sizeof(int32_t));
    int32_t *ht_head = (int32_t *)malloc(NUM_PAIRS * sizeof(int32_t));
    if (!ht_records || !ht_next || !ht_head) {
        fprintf(stderr, "OOM\n");
        free(ht_records); free(ht_next); free(ht_head);
        return NULL;
    }

    uint64_t kk0;

    for (uint32_t k0 = ta->k0_start; k0 < ta->k0_end && !g_done; k0++) {

        kk0 = (uint64_t)k0;  /* k[0..15] only */

        /* Step 1: compute Xi = enc16(k0, Pi)  and  Yi = dec16(k0, Ci) for all i */
        uint32_t X[NUM_PAIRS], Y[NUM_PAIRS];
        for (uint32_t i = 0; i < NUM_PAIRS; i++) {
            X[i] = enc_rounds(kk0, g_P[i], 0, 16);
            Y[i] = dec_rounds(kk0, g_C[i], 0, 16);
        }

        /* Step 2: for each 16-bit guess of P*j[15:0] = upj */
        for (uint32_t upj = 0; upj < 65536u && !g_done; upj++) {

            /* -----------------------------------------------------------
             * BUILD RIGHT SIDE (ciphertext) HT:
             * For each j, given upj = P*j[15:0]:
             *   P*j_full = (Pj[15:0] << 16) | upj
             *   k3       = extract from (P*j → Pj) at rounds 48..63
             *   Y*j      = dec16(k3, Yj, 48)
             *   HT key   = Y*j[15:0]  (new dec bits, probed by C*i[31:16])
             * ----------------------------------------------------------- */
            for (uint32_t b = 0; b < NUM_PAIRS; b++) ht_head[b] = HT_EMPTY;
            uint32_t rec_count = 0;

            for (uint32_t j = 0; j < NUM_PAIRS; j++) {
                uint32_t pstar = make_pstar(g_P[j], upj);
                /* P*j → Pj is 16 forward rounds with k[48..63] */
                uint64_t k3_mask = extract_key_bits(pstar, g_P[j], 48, 16);
                uint32_t ystar   = dec_rounds(k3_mask, Y[j], 48, 16);

                /* HT indexed by Y*j[15:0] (new dec bits) — probed by C*i[31:16] */
                uint32_t bucket = (ystar & 0xFFFFu) & (NUM_PAIRS - 1);
                HTableEntry *e = &ht_records[rec_count];
                e->y_star      = ystar;
                e->p_star_lo16 = upj;
                e->k3_bits     = k3_mask;
                e->idx         = j;
                e->pj          = g_P[j];
                e->cj          = g_C[j];
                e->xj          = X[j];
                e->yj          = Y[j];
                e->valid       = 1;
                ht_next[rec_count] = ht_head[bucket];
                ht_head[bucket] = (int32_t)rec_count;
                rec_count++;
            }

            /* -----------------------------------------------------------
             * PROBE LEFT SIDE (plaintext):
             * For each i and the current upj guess:
             *   X*i      = (upj << 16) | (Xi >> 16)   [enc passthrough sets X*i[15:0]=Xi[31:16]]
             *              X*i[31:16] = upj  (our guess for the new enc feedback bits)
             *   k1       = extract from (Xi → X*i) at rounds 16..31
             *   C*i      = enc16(k1, Ci, 16)
             *   Probe HT by C*i[31:16]  (== Y*j[15:0] for a true slid pair)
             * ----------------------------------------------------------- */
            for (uint32_t i = 0; i < NUM_PAIRS && !g_done; i++) {
                uint32_t xstar   = make_xstar(X[i], upj);
                uint64_t k1_mask = extract_key_bits(X[i], xstar, 16, 16);
                uint32_t cstar   = enc_rounds(k1_mask, g_C[i], 16, 16);

                /* MitM probe: C*i[31:16] == Y*j[15:0]  =>  passthrough match */
                uint32_t probe  = (cstar >> 16) & (NUM_PAIRS - 1);
                for (int32_t idx = ht_head[probe]; idx != HT_EMPTY; idx = ht_next[idx]) {
                    HTableEntry *e = &ht_records[idx];
                    /* Verify the passthrough: C*i[31:16] must equal Y*j[15:0] */
                    if ((cstar >> 16) != (e->y_star & 0xFFFFu)) continue;

                    /* Candidate! Extract k[32..47] from two paths and cross-check. */
                    uint32_t pstar_full = make_pstar(e->pj, e->p_star_lo16);
                    /* Path 1: C*i → Y*j (16 enc rounds with k[32..47]) */
                    uint64_t k2_from_C = extract_key_bits(cstar, e->y_star, 32, 16);
                    /* Path 2: X*i → P*j (16 enc rounds with k[32..47]) */
                    uint64_t k2_from_P = extract_key_bits(xstar, pstar_full, 32, 16);
                    /* Both paths must agree on k[32..47] */
                    if (((k2_from_C ^ k2_from_P) & 0x0000FFFF00000000ULL) != 0) continue;

                    /* Assemble candidate full key */
                    uint64_t cand_key = kk0
                                      | k1_mask
                                      | k2_from_C
                                      | e->k3_bits;

                    /* Verify against known pairs */
                    if (keeloq_enc_full(cand_key, g_P[0]) != g_C[0]) continue;
                    if (keeloq_enc_full(cand_key, g_P[1]) != g_C[1]) continue;

                    /* Key found! */
                    if (!g_done) {
                        g_done = 1;
                        ta->found = 1;
                        ta->recovered_key = cand_key;
                        gettimeofday(&tv1, NULL);
                        ta->elapsed_s = (tv1.tv_sec - tv0.tv_sec)
                                      + (tv1.tv_usec - tv0.tv_usec) * 1e-6;
                    }
                    goto done;
                }
            }
        }
    }

done:
    free(ht_records);
    free(ht_next);
    free(ht_head);
    if (!ta->found) {
        gettimeofday(&tv1, NULL);
        ta->elapsed_s = (tv1.tv_sec - tv0.tv_sec)
                      + (tv1.tv_usec - tv0.tv_usec) * 1e-6;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

static double now_s(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

int main(int argc, char **argv)
{
    int nthreads = (int)sysconf(_SC_NPROCESSORS_ONLN);
    uint64_t true_key = 0x5CEC6701B79FD949ULL;

    if (argc >= 2) nthreads = atoi(argv[1]);
    if (argc >= 3) true_key = strtoull(argv[2], NULL, 16);
    if (nthreads < 1) nthreads = 1;
    if (nthreads > 65536) nthreads = 65536;

    printf("KeeLoq Slide+MitM Attack\n");
    printf("Ref: Indesteege et al., EUROCRYPT 2008\n");
    printf("Threads: %d  |  Data: 2^%d KP  |  Key: %016llx\n",
           nthreads, DATA_BITS, (unsigned long long)true_key);

    /* Generate self-test data */
    srand(42);
    for (uint32_t i = 0; i < NUM_PAIRS; i++) {
        g_P[i] = ((uint32_t)rand() << 16) ^ (uint32_t)rand();
        g_C[i] = keeloq_enc_full(true_key, g_P[i]);
    }
    printf("Generated %u KP pairs.\n", NUM_PAIRS);

    /* Distribute k̂₀ range over threads */
    pthread_t *tids = (pthread_t *)malloc(nthreads * sizeof(pthread_t));
    ThreadArg *args = (ThreadArg *)calloc(nthreads, sizeof(ThreadArg));

    uint32_t step = (NUM_PAIRS + nthreads - 1) / nthreads;
    for (int t = 0; t < nthreads; t++) {
        args[t].k0_start  = t * step;
        args[t].k0_end    = (t + 1) * step;
        if (args[t].k0_end > NUM_PAIRS) args[t].k0_end = NUM_PAIRS;
        args[t].true_key  = true_key;
        args[t].found     = 0;
    }

    double t0 = now_s();
    for (int t = 0; t < nthreads; t++)
        pthread_create(&tids[t], NULL, attack_thread, &args[t]);
    for (int t = 0; t < nthreads; t++)
        pthread_join(tids[t], NULL);
    double elapsed = now_s() - t0;

    /* Report */
    int found = 0;
    uint64_t rec_key = 0;
    for (int t = 0; t < nthreads; t++) {
        if (args[t].found) {
            found = 1;
            rec_key = args[t].recovered_key;
            printf("Thread %d found key in %.2f s\n", t, args[t].elapsed_s);
        }
    }

    if (found) {
        printf("Recovered key : %016llx\n", (unsigned long long)rec_key);
        printf("True key      : %016llx\n", (unsigned long long)true_key);
        printf("Match         : %s\n", rec_key == true_key ? "YES" : "NO (false positive – verify manually)");
    } else {
        printf("No key found (no slid pair in dataset, or attack incomplete).\n");
        printf("Hint: with 2^16 random KP, success probability ≈ 63%%.\n");
    }
    printf("Wall time: %.2f s\n", elapsed);

    free(tids); free(args);
    return found ? 0 : 1;
}
