/*
 * KeeLoq Cipher Implementation
 * Author: H. Hadipour
 *
 * Usage:
 *   ./keeloq              - Demo encryption/decryption
 *   ./keeloq speed        - Run encryption speed benchmark
 *   ./keeloq polygen      - Generate polynomial equations
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "keeloq.h"
#include "speed.h"
#include "attacks/algebraic/polygen.h"

#define DEFAULT_ROUNDS 528
#define DEFAULT_KEY    0x5CEC6701B79FD949ULL

void print_usage(const char *prog) {
    printf("KeeLoq Cipher Implementation\n\n");
    printf("Usage:\n");
    printf("  %s              Demo encryption/decryption\n", prog);
    printf("  %s speed        Run encryption speed benchmark\n", prog);
    printf("  %s polygen      Generate polynomial equations (to mqkeeloq.txt)\n", prog);
    printf("  %s polygen-sym  Generate symbolic equations with P_i_j, C_i_j variables\n", prog);
    printf("  %s slide528     Generate slide528 equations (concrete, to mqkeeloq.txt)\n", prog);
    printf("  %s slide528-sym Generate slide528 equations (symbolic, to mqkeeloq_symbolic.txt)\n", prog);
    printf("\n");
}

void demo_encrypt_decrypt(void) {
    uint64_t key = DEFAULT_KEY;
    uint32_t plaintext = 0xF741E2DB;
    uint32_t ciphertext;
    int rounds = DEFAULT_ROUNDS;

    printf("KeeLoq Encryption/Decryption Demo\n");
    printf("==================================\n");
    printf("Key:       0x%016llX\n", (unsigned long long)key);
    printf("Rounds:    %d\n", rounds);
    printf("Plaintext: 0x%08X\n\n", plaintext);

    keeloq_encrypt(&key, &plaintext, &ciphertext, rounds);
    printf("After encryption: 0x%08X\n", ciphertext);

    uint32_t decrypted;
    keeloq_decrypt(&key, &decrypted, &ciphertext, rounds);
    printf("After decryption: 0x%08X\n", decrypted);

    if (decrypted == plaintext) {
        printf("\nVerification: PASSED\n");
    } else {
        printf("\nVerification: FAILED\n");
    }
}

void run_speed_benchmark(void) {
    int rounds = DEFAULT_ROUNDS;
    double rate;

    printf("KeeLoq Speed Benchmark\n");
    printf("======================\n");
    printf("Rounds: %d\n", rounds);
    printf("Running benchmark...\n\n");

    rate = speed(rounds);
    printf("Encryption speed: %.2f MB/s\n", rate / 1000000.0);
}

void generate_equations(void) {
    uint64_t key = DEFAULT_KEY;
    int rounds = 32;  /* Default for equation generation */
    int num_pairs = 1;
    
    printf("KeeLoq Polynomial Equation Generator\n");
    printf("====================================\n");
    printf("Enter number of rounds: ");
    scanf("%d", &rounds);
    printf("Enter number of P/C pairs: ");
    scanf("%d", &num_pairs);
    
    if (num_pairs < 1) num_pairs = 1;
    if (rounds < 1) rounds = 1;

    /* Allocate arrays */
    uint32_t *plaintexts = malloc(num_pairs * sizeof(uint32_t));
    uint32_t *ciphertexts = malloc(num_pairs * sizeof(uint32_t));
    
    /* Generate random plaintexts and encrypt */
    srand((unsigned)time(NULL));
    for (int i = 0; i < num_pairs; i++) {
        plaintexts[i] = (uint32_t)rand();
        keeloq_encrypt(&key, &plaintexts[i], &ciphertexts[i], rounds);
    }

    /* Generate equations */
    uint64_t num_eqs = calculate_num_of_equations(rounds, num_pairs);
    polynomial *equations = malloc(num_eqs * sizeof(polynomial));
    polynomials(plaintexts, ciphertexts, equations, rounds, num_pairs);

    /* Write to file */
    FILE *fp = fopen("mqkeeloq.txt", "w");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open mqkeeloq.txt for writing\n");
        free(plaintexts);
        free(ciphertexts);
        free(equations);
        return;
    }

    /* Write header comments */
    fprintf(fp, "# KeeLoq polynomial equations\n");
    fprintf(fp, "# Rounds: %d, Pairs: %d\n", rounds, num_pairs);
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++) {
        fprintf(fp, "%s\n", equations[i].poly);
    }
    fprintf(fp, "end\n");
    fclose(fp);

    printf("\nGenerated %llu equations for %d rounds, %d P/C pairs\n",
           (unsigned long long)num_eqs, rounds, num_pairs);
    printf("Output written to: mqkeeloq.txt\n");

    free(plaintexts);
    free(ciphertexts);
    free(equations);
}

void generate_equations_symbolic(void) {
    int rounds = 64;  /* Default for slide attack */
    int num_pairs = 3; /* Default: 3 constraints for slide attack */
    
    printf("KeeLoq Symbolic Polynomial Equation Generator\n");
    printf("=============================================\n");
    printf("This generates equations with P_i_j (plaintext) and C_i_j (ciphertext)\n");
    printf("as symbolic variables instead of concrete 0/1 values.\n\n");
    printf("Enter number of rounds [64]: ");
    char buf[32];
    if (fgets(buf, sizeof(buf), stdin) && buf[0] != '\n') {
        rounds = atoi(buf);
    }
    printf("Enter number of P/C pairs [3]: ");
    if (fgets(buf, sizeof(buf), stdin) && buf[0] != '\n') {
        num_pairs = atoi(buf);
    }
    
    if (num_pairs < 1) num_pairs = 1;
    if (rounds < 1) rounds = 1;

    /* Generate equations */
    uint64_t num_eqs = calculate_num_of_equations(rounds, num_pairs);
    polynomial *equations = malloc(num_eqs * sizeof(polynomial));
    polynomials_symbolic(equations, rounds, num_pairs);

    /* Write to file */
    FILE *fp = fopen("mqkeeloq_symbolic.txt", "w");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open mqkeeloq_symbolic.txt for writing\n");
        free(equations);
        return;
    }

    /* Write header comment */
    fprintf(fp, "# Symbolic KeeLoq equations\n");
    fprintf(fp, "# Rounds: %d, Pairs: %d\n", rounds, num_pairs);
    fprintf(fp, "# Variables: P_i_j = plaintext bit j of pair i\n");
    fprintf(fp, "#            C_i_j = ciphertext bit j of pair i\n");
    fprintf(fp, "#            L_i_j = state bit j of pair i\n");
    fprintf(fp, "#            k_j   = key bit j (0-63)\n");
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++) {
        fprintf(fp, "%s\n", equations[i].poly);
    }
    /* Known variables section for symbolic mode */
    fprintf(fp, "known\n");
    for (int i = 0; i < num_pairs; i++) {
        for (int j = 0; j < 32; j++) {
            fprintf(fp, "P_%d_%d\n", i, j);
        }
    }
    for (int i = 0; i < num_pairs; i++) {
        for (int j = 0; j < 32; j++) {
            fprintf(fp, "C_%d_%d\n", i, j);
        }
    }
    fprintf(fp, "end\n");
    fclose(fp);

    printf("\nGenerated %llu symbolic equations for %d rounds, %d P/C pairs\n",
           (unsigned long long)num_eqs, rounds, num_pairs);
    printf("Output written to: mqkeeloq_symbolic.txt\n");

    free(equations);
}

/*
 * Slide528 concrete mode:
 * Generates a slid pair (P1,C1), (P2,C2) under E_528 such that P2 = E_64(K, P1),
 * then produces two 64-round constraint equations:
 *   Constraint 0: E_64(K, P1) = P2   (key offset 0)
 *   Constraint 1: E'_64(K, C1) = C2  (key offset 16)
 */
void generate_equations_slide528(void) {
    uint64_t key = DEFAULT_KEY;

    printf("KeeLoq Slide528 Equation Generator (concrete)\n");
    printf("=============================================\n");
    printf("Key: 0x%016llX\n", (unsigned long long)key);
    printf("Generating slid pair under E_528...\n");

    srand((unsigned)time(NULL));
    uint32_t P1 = (uint32_t)rand();
    uint32_t P2, C1, C2;

    /* P2 = E_64(K, P1) */
    keeloq_encrypt(&key, &P1, &P2, 64);
    /* C1 = E_528(K, P1) */
    keeloq_encrypt(&key, &P1, &C1, 528);
    /* C2 = E_528(K, P2) */
    keeloq_encrypt(&key, &P2, &C2, 528);

    printf("P1 = 0x%08X\n", P1);
    printf("P2 = 0x%08X  (= E_64(K, P1))\n", P2);
    printf("C1 = 0x%08X  (= E_528(K, P1))\n", C1);
    printf("C2 = 0x%08X  (= E_528(K, P2))\n\n", C2);

    uint32_t plains[2] = {P1, P2};
    uint32_t ciphers[2] = {C1, C2};

    uint64_t num_eqs = calculate_num_of_equations_slide528();
    polynomial *equations = malloc(num_eqs * sizeof(polynomial));
    polynomials_slide528(plains, ciphers, equations);

    FILE *fp = fopen("mqkeeloq.txt", "w");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open mqkeeloq.txt for writing\n");
        free(equations);
        return;
    }

    fprintf(fp, "# KeeLoq Slide528 equations (concrete)\n");
    fprintf(fp, "# Key: 0x%016llX\n", (unsigned long long)key);
    fprintf(fp, "# P1=0x%08X, P2=0x%08X, C1=0x%08X, C2=0x%08X\n", P1, P2, C1, C2);
    fprintf(fp, "# Constraint 0: E_64(K, P1) = P2, key offset 0\n");
    fprintf(fp, "# Constraint 1: E'_64(K, C1) = C2, key offset 16\n");
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++) {
        fprintf(fp, "%s\n", equations[i].poly);
    }
    fprintf(fp, "end\n");
    fclose(fp);

    printf("Generated %llu equations\n", (unsigned long long)num_eqs);
    printf("Output written to: mqkeeloq.txt\n");

    free(equations);
}

/*
 * Slide528 symbolic mode:
 * Same two constraints but with P_i_j / C_i_j as symbolic variables.
 */
void generate_equations_slide528_symbolic(void) {
    printf("KeeLoq Slide528 Symbolic Equation Generator\n");
    printf("============================================\n");
    printf("Constraint 0: E_64(K, P1) = P2, key offset 0\n");
    printf("Constraint 1: E'_64(K, C1) = C2, key offset 16\n\n");

    uint64_t num_eqs = calculate_num_of_equations_slide528();
    polynomial *equations = malloc(num_eqs * sizeof(polynomial));
    polynomials_slide528_symbolic(equations);

    FILE *fp = fopen("mqkeeloq_symbolic.txt", "w");
    if (!fp) {
        fprintf(stderr, "Error: Cannot open mqkeeloq_symbolic.txt for writing\n");
        free(equations);
        return;
    }

    fprintf(fp, "# KeeLoq Slide528 symbolic equations\n");
    fprintf(fp, "# Constraint 0 (pair 0): E_64(K, P1) = P2, key offset 0\n");
    fprintf(fp, "#   L_0_j uses k_((j-32) %% 64)\n");
    fprintf(fp, "# Constraint 1 (pair 1): E'_64(K, C1) = C2, key offset 16\n");
    fprintf(fp, "#   L_1_j uses k_(((j-32)+16) %% 64)\n");
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++) {
        fprintf(fp, "%s\n", equations[i].poly);
    }
    fprintf(fp, "known\n");
    /* Pair 0: P1 input, P2 output */
    for (int j = 0; j < 32; j++) fprintf(fp, "P_0_%d\n", j);
    for (int j = 0; j < 32; j++) fprintf(fp, "C_0_%d\n", j);
    /* Pair 1: C1 input, C2 output */
    for (int j = 0; j < 32; j++) fprintf(fp, "P_1_%d\n", j);
    for (int j = 0; j < 32; j++) fprintf(fp, "C_1_%d\n", j);
    fprintf(fp, "end\n");
    fclose(fp);

    printf("Generated %llu symbolic equations\n", (unsigned long long)num_eqs);
    printf("Output written to: mqkeeloq_symbolic.txt\n");

    free(equations);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        demo_encrypt_decrypt();
        return 0;
    }

    if (strcmp(argv[1], "speed") == 0) {
        run_speed_benchmark();
    } else if (strcmp(argv[1], "polygen") == 0) {
        generate_equations();
    } else if (strcmp(argv[1], "polygen-sym") == 0) {
        generate_equations_symbolic();
    } else if (strcmp(argv[1], "slide528") == 0) {
        generate_equations_slide528();
    } else if (strcmp(argv[1], "slide528-sym") == 0) {
        generate_equations_slide528_symbolic();
    } else if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        print_usage(argv[0]);
    } else {
        fprintf(stderr, "Unknown command: %s\n\n", argv[1]);
        print_usage(argv[0]);
        return 1;
    }

    return 0;
}
