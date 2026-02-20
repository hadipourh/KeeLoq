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
#include "attacks/polygen.h"

#define DEFAULT_ROUNDS 528
#define DEFAULT_KEY    0x5CEC6701B79FD949ULL

void print_usage(const char *prog) {
    printf("KeeLoq Cipher Implementation\n\n");
    printf("Usage:\n");
    printf("  %s              Demo encryption/decryption\n", prog);
    printf("  %s speed        Run encryption speed benchmark\n", prog);
    printf("  %s polygen      Generate polynomial equations (to mqkeeloq.txt)\n", prog);
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

    for (uint64_t i = 0; i < num_eqs; i++) {
        fprintf(fp, "%s\n", equations[i].poly);
    }
    fclose(fp);

    printf("\nGenerated %llu equations for %d rounds, %d P/C pairs\n",
           (unsigned long long)num_eqs, rounds, num_pairs);
    printf("Output written to: mqkeeloq.txt\n");

    free(plaintexts);
    free(ciphertexts);
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
    } else if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        print_usage(argv[0]);
    } else {
        fprintf(stderr, "Unknown command: %s\n\n", argv[1]);
        print_usage(argv[0]);
        return 1;
    }

    return 0;
}
