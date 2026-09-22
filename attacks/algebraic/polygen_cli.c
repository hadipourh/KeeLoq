#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "polygen.h"
#include "keeloq.h"

#define DEFAULT_KEY 0x5CEC6701B79FD949ULL

static void usage(const char *prog)
{
    printf("KeeLoq Algebraic Equation Generator\n\n");
    printf("Usage:\n");
    printf("  %s polygen       Generate concrete equations in mqkeeloq.txt\n", prog);
    printf("  %s polygen-sym   Generate symbolic equations in mqkeeloq_symbolic.txt\n", prog);
    printf("  %s slide528      Generate slide528 concrete equations in mqkeeloq.txt\n", prog);
    printf("  %s slide528-sym  Generate slide528 symbolic equations in mqkeeloq_symbolic.txt\n", prog);
}

static void run_polygen(void)
{
    uint64_t key = DEFAULT_KEY;
    int rounds = 32;
    int num_pairs = 1;

    printf("KeeLoq Algebraic Equation Generator\n");
    printf("===================================\n");
    printf("Enter number of rounds: ");
    scanf("%d", &rounds);
    printf("Enter number of P/C pairs: ");
    scanf("%d", &num_pairs);

    if (num_pairs < 1) num_pairs = 1;
    if (rounds < 1) rounds = 1;

    uint32_t *plaintexts = malloc((size_t)num_pairs * sizeof(uint32_t));
    uint32_t *ciphertexts = malloc((size_t)num_pairs * sizeof(uint32_t));
    if (!plaintexts || !ciphertexts)
    {
        fprintf(stderr, "Allocation failure\n");
        free(plaintexts);
        free(ciphertexts);
        return;
    }

    srand((unsigned)time(NULL));
    for (int i = 0; i < num_pairs; i++)
    {
        plaintexts[i] = (uint32_t)rand();
        keeloq_encrypt(&key, &plaintexts[i], &ciphertexts[i], rounds);
    }

    uint64_t num_eqs = calculate_num_of_equations(rounds, num_pairs);
    polynomial *equations = malloc((size_t)num_eqs * sizeof(polynomial));
    if (!equations)
    {
        fprintf(stderr, "Allocation failure\n");
        free(plaintexts);
        free(ciphertexts);
        return;
    }
    polynomials(plaintexts, ciphertexts, equations, rounds, num_pairs);

    FILE *fp = fopen("mqkeeloq.txt", "w");
    if (!fp)
    {
        fprintf(stderr, "Cannot open mqkeeloq.txt for writing\n");
        free(plaintexts);
        free(ciphertexts);
        free(equations);
        return;
    }

    fprintf(fp, "# KeeLoq algebraic equations\n");
    fprintf(fp, "# WARNING: reduced-round system, not a direct full 528-round attack\n");
    fprintf(fp, "# Rounds: %d, Pairs: %d\n", rounds, num_pairs);
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++)
        fprintf(fp, "%s\n", equations[i].poly);
    fprintf(fp, "end\n");
    fclose(fp);

    printf("Generated %llu equations in mqkeeloq.txt\n", (unsigned long long)num_eqs);

    free(plaintexts);
    free(ciphertexts);
    free(equations);
}

static void run_polygen_sym(void)
{
    int rounds = 64;
    int num_pairs = 1;
    char buf[32];

    printf("KeeLoq Symbolic Algebraic Equation Generator\n");
    printf("============================================\n");
    printf("Enter number of rounds [64]: ");
    if (fgets(buf, sizeof(buf), stdin) && buf[0] != '\n') rounds = atoi(buf);
    printf("Enter number of P/C pairs [1]: ");
    if (fgets(buf, sizeof(buf), stdin) && buf[0] != '\n') num_pairs = atoi(buf);
    if (num_pairs < 1) num_pairs = 1;
    if (rounds < 1) rounds = 1;

    uint64_t num_eqs = calculate_num_of_equations(rounds, num_pairs);
    polynomial *equations = malloc((size_t)num_eqs * sizeof(polynomial));
    if (!equations)
    {
        fprintf(stderr, "Allocation failure\n");
        return;
    }
    polynomials_symbolic(equations, rounds, num_pairs);

    FILE *fp = fopen("mqkeeloq_symbolic.txt", "w");
    if (!fp)
    {
        fprintf(stderr, "Cannot open mqkeeloq_symbolic.txt for writing\n");
        free(equations);
        return;
    }

    fprintf(fp, "# Symbolic KeeLoq algebraic equations\n");
    fprintf(fp, "# WARNING: reduced-round system, not a direct full 528-round attack\n");
    fprintf(fp, "# Rounds: %d, Pairs: %d\n", rounds, num_pairs);
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++)
        fprintf(fp, "%s\n", equations[i].poly);
    fprintf(fp, "known\n");
    for (int i = 0; i < num_pairs; i++)
        for (int j = 0; j < 32; j++)
            fprintf(fp, "P_%d_%d\n", i, j);
    for (int i = 0; i < num_pairs; i++)
        for (int j = 0; j < 32; j++)
            fprintf(fp, "C_%d_%d\n", i, j);
    fprintf(fp, "end\n");
    fclose(fp);

    printf("Generated %llu symbolic equations in mqkeeloq_symbolic.txt\n", (unsigned long long)num_eqs);
    free(equations);
}

static void run_slide528(void)
{
    uint64_t key = DEFAULT_KEY;
    uint32_t P1, P2, C1, C2;
    uint32_t plains[2];
    uint32_t ciphers[2];

    srand((unsigned)time(NULL));
    P1 = (uint32_t)rand();
    keeloq_encrypt(&key, &P1, &P2, 64);
    keeloq_encrypt(&key, &P1, &C1, 528);
    keeloq_encrypt(&key, &P2, &C2, 528);

    plains[0] = P1;
    plains[1] = P2;
    ciphers[0] = C1;
    ciphers[1] = C2;

    uint64_t num_eqs = calculate_num_of_equations_slide528();
    polynomial *equations = malloc((size_t)num_eqs * sizeof(polynomial));
    if (!equations)
    {
        fprintf(stderr, "Allocation failure\n");
        return;
    }
    polynomials_slide528(plains, ciphers, equations);

    FILE *fp = fopen("mqkeeloq.txt", "w");
    if (!fp)
    {
        fprintf(stderr, "Cannot open mqkeeloq.txt for writing\n");
        free(equations);
        return;
    }

    fprintf(fp, "# KeeLoq Slide528 equations\n");
    fprintf(fp, "# NOTE: derived 64-round constraints from the full cipher; not a standalone practical full-round key-recovery attack\n");
    fprintf(fp, "# P1=0x%08X, P2=0x%08X, C1=0x%08X, C2=0x%08X\n", P1, P2, C1, C2);
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++)
        fprintf(fp, "%s\n", equations[i].poly);
    fprintf(fp, "end\n");
    fclose(fp);

    printf("Generated %llu slide528 equations in mqkeeloq.txt\n", (unsigned long long)num_eqs);
    free(equations);
}

static void run_slide528_sym(void)
{
    uint64_t num_eqs = calculate_num_of_equations_slide528();
    polynomial *equations = malloc((size_t)num_eqs * sizeof(polynomial));
    if (!equations)
    {
        fprintf(stderr, "Allocation failure\n");
        return;
    }
    polynomials_slide528_symbolic(equations);

    FILE *fp = fopen("mqkeeloq_symbolic.txt", "w");
    if (!fp)
    {
        fprintf(stderr, "Cannot open mqkeeloq_symbolic.txt for writing\n");
        free(equations);
        return;
    }

    fprintf(fp, "# KeeLoq Slide528 symbolic equations\n");
    fprintf(fp, "# NOTE: derived 64-round constraints from the full cipher; not a standalone practical full-round key-recovery attack\n");
    fprintf(fp, "# Total equations: %llu\n", (unsigned long long)num_eqs);
    fprintf(fp, "algebraic relations\n");
    for (uint64_t i = 0; i < num_eqs; i++)
        fprintf(fp, "%s\n", equations[i].poly);
    fprintf(fp, "known\n");
    for (int pair = 0; pair < 2; pair++)
        for (int j = 0; j < 32; j++)
            fprintf(fp, "P_%d_%d\n", pair, j);
    for (int pair = 0; pair < 2; pair++)
        for (int j = 0; j < 32; j++)
            fprintf(fp, "C_%d_%d\n", pair, j);
    fprintf(fp, "end\n");
    fclose(fp);

    printf("Generated %llu symbolic slide528 equations in mqkeeloq_symbolic.txt\n", (unsigned long long)num_eqs);
    free(equations);
}

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        usage(argv[0]);
        return 1;
    }

    if (strcmp(argv[1], "polygen") == 0)
        run_polygen();
    else if (strcmp(argv[1], "polygen-sym") == 0)
        run_polygen_sym();
    else if (strcmp(argv[1], "slide528") == 0)
        run_slide528();
    else if (strcmp(argv[1], "slide528-sym") == 0)
        run_slide528_sym();
    else
    {
        usage(argv[0]);
        return 1;
    }
    return 0;
}
