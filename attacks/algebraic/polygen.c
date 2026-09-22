#include "polygen.h"

uint64_t calculate_num_of_equations(int r, int number_of_plains)
{
    uint64_t output;
    output = number_of_plains * (64 + (r * 3));
    return output;
}

void polynomials(uint32_t *plains, uint32_t *ciphers, polynomial *equations, int r, int number_of_plains)
{
    int i, j;
    uint64_t eqs_ctr = 0;
    for (i = 0; i < number_of_plains; i++)
    {
        for (j = 0; j < 32; j++)
        {
            sprintf(equations[eqs_ctr].poly, EQ1, i, j, ((plains[i] >> j) & 0x1));
            eqs_ctr++;
        }
        for (j = 32; j < r + 32; j++)
        {
            sprintf(equations[eqs_ctr].poly, EQ2,
                    i, j, (j - 32) % 64, i, (j - 32), i, (j - 16), i, (j - 23),
                    i, (j - 31), i, (j - 1), i, (j - 12), i, j, i, (j - 6), i,
                    (j - 12), i, (j - 6), i, (j - 31), i, (j - 12), i, (j - 23),
                    i, (j - 23), i, (j - 31), i, j, i, (j - 23), i, j, i, (j - 12),
                    i, j, i, (j - 23), i, j, i, (j - 12));
            eqs_ctr++;
            sprintf(equations[eqs_ctr].poly, EQ3, i, j, i, (j - 1), i, (j - 6));
            eqs_ctr++;
            sprintf(equations[eqs_ctr].poly, EQ4, i, j, i, (j - 1), i, (j - 31));
            eqs_ctr++;
        }
        for (j = r; j < r + 32; j++)
        {
            sprintf(equations[eqs_ctr].poly, EQ1, i, j, ((ciphers[i] >> (j - r)) & 0x1));
            eqs_ctr++;
        }
    }
}

/*
 * Symbolic mode: generates equations with P_i_j and C_i_j as variables
 * instead of concrete 0/1 values. Useful for precomputing equation structure.
 */
void polynomials_symbolic(polynomial *equations, int r, int number_of_plains)
{
    int i, j;
    uint64_t eqs_ctr = 0;
    for (i = 0; i < number_of_plains; i++)
    {
        /* Plaintext input constraints: L_i_j + P_i_j = 0 */
        for (j = 0; j < 32; j++)
        {
            sprintf(equations[eqs_ctr].poly, EQ1_SYM_P, i, j, i, j);
            eqs_ctr++;
        }
        /* Round equations (same as concrete mode - no P/C involved) */
        for (j = 32; j < r + 32; j++)
        {
            sprintf(equations[eqs_ctr].poly, EQ2,
                    i, j, (j - 32) % 64, i, (j - 32), i, (j - 16), i, (j - 23),
                    i, (j - 31), i, (j - 1), i, (j - 12), i, j, i, (j - 6), i,
                    (j - 12), i, (j - 6), i, (j - 31), i, (j - 12), i, (j - 23),
                    i, (j - 23), i, (j - 31), i, j, i, (j - 23), i, j, i, (j - 12),
                    i, j, i, (j - 23), i, j, i, (j - 12));
            eqs_ctr++;
            sprintf(equations[eqs_ctr].poly, EQ3, i, j, i, (j - 1), i, (j - 6));
            eqs_ctr++;
            sprintf(equations[eqs_ctr].poly, EQ4, i, j, i, (j - 1), i, (j - 31));
            eqs_ctr++;
        }
        /* Ciphertext output constraints: L_i_(r+j) + C_i_j = 0 */
        for (j = r; j < r + 32; j++)
        {
            sprintf(equations[eqs_ctr].poly, EQ1_SYM_C, i, j, i, (j - r));
            eqs_ctr++;
        }
    }
}

/*
 * Helper: generate round equations for a single 64-round constraint
 * with a given key offset and pair index.
 * key_offset: the starting key bit index (0 for E_64, 16 for E')
 */
static uint64_t gen_constraint_concrete(int pair_idx, uint32_t plain, uint32_t cipher,
                                        int key_offset, polynomial *equations, uint64_t eqs_ctr)
{
    int j;
    /* Plaintext input: L_pair_j = plain bit j */
    for (j = 0; j < 32; j++)
    {
        sprintf(equations[eqs_ctr].poly, EQ1, pair_idx, j, ((plain >> j) & 0x1));
        eqs_ctr++;
    }
    /* 64 round equations with key offset */
    for (j = 32; j < 96; j++)
    {
        sprintf(equations[eqs_ctr].poly, EQ2,
                pair_idx, j, ((j - 32) + key_offset) % 64,
                pair_idx, (j - 32), pair_idx, (j - 16), pair_idx, (j - 23),
                pair_idx, (j - 31), pair_idx, (j - 1), pair_idx, (j - 12),
                pair_idx, j, pair_idx, (j - 6), pair_idx,
                (j - 12), pair_idx, (j - 6), pair_idx, (j - 31), pair_idx, (j - 12),
                pair_idx, (j - 23), pair_idx, (j - 23), pair_idx, (j - 31),
                pair_idx, j, pair_idx, (j - 23), pair_idx, j, pair_idx, (j - 12),
                pair_idx, j, pair_idx, (j - 23), pair_idx, j, pair_idx, (j - 12));
        eqs_ctr++;
        sprintf(equations[eqs_ctr].poly, EQ3, pair_idx, j, pair_idx, (j - 1), pair_idx, (j - 6));
        eqs_ctr++;
        sprintf(equations[eqs_ctr].poly, EQ4, pair_idx, j, pair_idx, (j - 1), pair_idx, (j - 31));
        eqs_ctr++;
    }
    /* Ciphertext output: L_pair_(64+j) = cipher bit j */
    for (j = 64; j < 96; j++)
    {
        sprintf(equations[eqs_ctr].poly, EQ1, pair_idx, j, ((cipher >> (j - 64)) & 0x1));
        eqs_ctr++;
    }
    return eqs_ctr;
}

static uint64_t gen_constraint_symbolic(int pair_idx, int key_offset,
                                        polynomial *equations, uint64_t eqs_ctr)
{
    int j;
    /* Plaintext input: L_pair_j + P_pair_j */
    for (j = 0; j < 32; j++)
    {
        sprintf(equations[eqs_ctr].poly, EQ1_SYM_P, pair_idx, j, pair_idx, j);
        eqs_ctr++;
    }
    /* 64 round equations with key offset */
    for (j = 32; j < 96; j++)
    {
        sprintf(equations[eqs_ctr].poly, EQ2,
                pair_idx, j, ((j - 32) + key_offset) % 64,
                pair_idx, (j - 32), pair_idx, (j - 16), pair_idx, (j - 23),
                pair_idx, (j - 31), pair_idx, (j - 1), pair_idx, (j - 12),
                pair_idx, j, pair_idx, (j - 6), pair_idx,
                (j - 12), pair_idx, (j - 6), pair_idx, (j - 31), pair_idx, (j - 12),
                pair_idx, (j - 23), pair_idx, (j - 23), pair_idx, (j - 31),
                pair_idx, j, pair_idx, (j - 23), pair_idx, j, pair_idx, (j - 12),
                pair_idx, j, pair_idx, (j - 23), pair_idx, j, pair_idx, (j - 12));
        eqs_ctr++;
        sprintf(equations[eqs_ctr].poly, EQ3, pair_idx, j, pair_idx, (j - 1), pair_idx, (j - 6));
        eqs_ctr++;
        sprintf(equations[eqs_ctr].poly, EQ4, pair_idx, j, pair_idx, (j - 1), pair_idx, (j - 31));
        eqs_ctr++;
    }
    /* Ciphertext output: L_pair_(64+j) + C_pair_j */
    for (j = 64; j < 96; j++)
    {
        sprintf(equations[eqs_ctr].poly, EQ1_SYM_C, pair_idx, j, pair_idx, (j - 64));
        eqs_ctr++;
    }
    return eqs_ctr;
}

/*
 * Number of equations for slide528 mode:
 * 2 constraints x (32 input + 64*3 round + 32 output) = 2 x 256 = 512
 */
uint64_t calculate_num_of_equations_slide528(void)
{
    return 2 * (32 + 64 * 3 + 32);
}

/*
 * Concrete slide528: two 64-round constraints from a slid pair.
 *   plains[0] = P1, plains[1] = P2
 *   ciphers[0] = C1, ciphers[1] = C2
 * Constraint 0 (pair_idx=0): E_64(K, P1) = P2, key offset 0
 * Constraint 1 (pair_idx=1): E'_64(K, C1) = C2, key offset 16
 */
void polynomials_slide528(uint32_t *plains, uint32_t *ciphers, polynomial *equations)
{
    uint64_t eqs_ctr = 0;
    /* Constraint 0: E_64 at offset 0, input=P1, output=P2 */
    eqs_ctr = gen_constraint_concrete(0, plains[0], plains[1], 0, equations, eqs_ctr);
    /* Constraint 1: E'_64 at offset 16, input=C1, output=C2 */
    eqs_ctr = gen_constraint_concrete(1, ciphers[0], ciphers[1], 16, equations, eqs_ctr);
}

/*
 * Symbolic slide528: same structure but P/C as variables.
 */
void polynomials_slide528_symbolic(polynomial *equations)
{
    uint64_t eqs_ctr = 0;
    /* Constraint 0: E_64 at offset 0 */
    eqs_ctr = gen_constraint_symbolic(0, 0, equations, eqs_ctr);
    /* Constraint 1: E'_64 at offset 16 */
    eqs_ctr = gen_constraint_symbolic(1, 16, equations, eqs_ctr);
}