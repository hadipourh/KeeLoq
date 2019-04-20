#include "polygen.h"

output_of_polynomials polynomials(uint32_t *plains, uint32_t *ciphers, int r, int number_of_plains)
{	
	char buffer[300];
	int i;
	int j;
	uint64_t eqs_ctr = 0;
	output_of_polynomials output;
	output.eqs = (polys *)calloc(number_of_plains * (64 + (r * 3)), sizeof(polys));
	for (i = 0; i < number_of_plains; i++)
	{
		for (j = 0; j < 32; j++)
		{
			sprintf(buffer, EQ1, i, j, ((plains[i] >> j) & 0x1));
			output.eqs[eqs_ctr].eq = (char *)malloc(sizeof(buffer));
			strcpy(output.eqs[eqs_ctr].eq, buffer);
			eqs_ctr++;
		}
		for (j = 32; j < r + 32; j++)
		{
			sprintf(buffer, EQ2,
					i, j, i, (j - 32) % 64, i, (j - 32), i, (j - 16), i, (j - 23),
					i, (j - 30), i, (j - 1), i, (j - 12), i, j, i, (j - 6), i,
					(j - 12), i, (j - 6), i, (j - 30), i, (j - 12), i, (j - 23),
					i, (j - 23), i, (j - 30), i, j, i, (j - 23), i, j, i, (j - 12),
					i, j, i, (j - 23), i, j, i, (j - 12));
			output.eqs[eqs_ctr].eq = (char *)malloc(sizeof(buffer));
			strcpy(output.eqs[eqs_ctr].eq, buffer);
			eqs_ctr++;
			sprintf(buffer, EQ3, i, j, i, (j - 1), i, (j - 6));
			output.eqs[eqs_ctr].eq = (char *)malloc(sizeof(buffer));
			strcpy(output.eqs[eqs_ctr].eq, buffer);
			eqs_ctr++;
			sprintf(buffer, EQ4, i, j, i, (j - 1), i, (j - 30));
			output.eqs[eqs_ctr].eq = (char *)malloc(sizeof(buffer));
			strcpy(output.eqs[eqs_ctr].eq, buffer);
			eqs_ctr++;
		}
		for (j = r; j < r + 32; j++)
		{
			sprintf(buffer, EQ1, i, j, ((ciphers[i] >> j) & 0x1));
			output.eqs[eqs_ctr].eq = (char *)malloc(sizeof(buffer));
			strcpy(output.eqs[eqs_ctr].eq, buffer);
			eqs_ctr++;
		}
	}
	output.number_of_eqs = eqs_ctr;
	return output;
}
