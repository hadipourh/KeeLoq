#ifndef __polygen_h__
#define __polygen_h__

#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

#define EQ1 "L_%d_%d + %d"
#define EQ2 "L_%d_%d + k_%d_%d + L_%d_%d + L_%d_%d + L_%d_%d + L_%d_%d"                \
            " + L_%d_%d*L_%d_%d + b_%d_%d + L_%d_%d*L_%d_%d + L_%d_%d*L_%d_%d"         \
            " + L_%d_%d*L_%d_%d + L_%d_%d*L_%d_%d + b_%d_%d*L_%d_%d + b_%d_%d*L_%d_%d" \
            " + a_%d_%d*L_%d_%d + a_%d_%d*L_%d_%d"
#define EQ3 "a_%d_%d + L_%d_%d*L_%d_%d"
#define EQ4 "b_%d_%d + L_%d_%d*L_%d_%d"

typedef struct
{
    char *eq;
} polys;
typedef struct
{
    polys *eqs;
    uint64_t number_of_eqs;
} output_of_polynomials;

output_of_polynomials polynomials(uint32_t *plains, uint32_t *ciphers, int r, int number_of_plains);
#endif
