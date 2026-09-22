#ifndef __polygen_h__
#define __polygen_h__

#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

/* Concrete mode: uses actual bit values 0 or 1 */
#define EQ1 "L_%d_%d + %d"
#define EQ2 "L_%d_%d + k_%d + L_%d_%d + L_%d_%d + L_%d_%d + L_%d_%d"                   \
            " + L_%d_%d*L_%d_%d + b_%d_%d + L_%d_%d*L_%d_%d + L_%d_%d*L_%d_%d"         \
            " + L_%d_%d*L_%d_%d + L_%d_%d*L_%d_%d + b_%d_%d*L_%d_%d + b_%d_%d*L_%d_%d" \
            " + a_%d_%d*L_%d_%d + a_%d_%d*L_%d_%d"
#define EQ3 "a_%d_%d + L_%d_%d*L_%d_%d"
#define EQ4 "b_%d_%d + L_%d_%d*L_%d_%d"

/* Symbolic mode: uses P_i_j for plaintext bits, C_i_j for ciphertext bits */
#define EQ1_SYM_P "L_%d_%d + P_%d_%d"
#define EQ1_SYM_C "L_%d_%d + C_%d_%d"

typedef struct
{
    char poly[300];
} polynomial;

uint64_t calculate_num_of_equations(int r, int number_of_plains);
void polynomials(uint32_t *plains, uint32_t *ciphers, polynomial *equations, int r, int number_of_plains);
void polynomials_symbolic(polynomial *equations, int r, int number_of_plains);

/*
 * Slide528 mode: generates two 64-round constraints with different key offsets.
 *   Constraint 0: E_64 at key offset 0  (P1 -> P2)
 *   Constraint 1: E'_64 at key offset 16 (C1 -> C2)
 * concrete version: uses actual P/C bit values
 * symbolic version: uses P_i_j, C_i_j variables
 */
void polynomials_slide528(uint32_t *plains, uint32_t *ciphers, polynomial *equations);
void polynomials_slide528_symbolic(polynomial *equations);
uint64_t calculate_num_of_equations_slide528(void);
#endif