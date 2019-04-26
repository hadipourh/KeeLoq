#include "polygen.h"

polyequations polynomials(uint32_t *plains, uint32_t *ciphers, int r, int number_of_plains)
{
    int i, j;
    uint64_t eqs_ctr = 0;
    uint64_t number_of_equations;
    number_of_equations = number_of_plains * (64 + (r * 3));
    polys equations[number_of_equations];
    polyequations output;
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
    output.number_of_eqs = eqs_ctr;
    output.eqs = equations;
    return output;
}