#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define nlf_lookup_constant 0x3a5c742e
//const uint32_t nlf_lookup_constant = 0x3a5c742e;
struct
{
	char eq[200];
} equations[];
int n = 0;


char nlf(int d) {
	return (nlf_lookup_constant >> d) & 0x1;
}

uint32_t encrypt(uint64_t key, uint32_t plaintext) {
	uint32_t preg = plaintext;
	char out, xor, nlf_input;
	for (int i = 0; i < 528; i++)
	{
		nlf_input = (((preg >> 31) & 0x1) << 4) | (((preg >> 26) & 0x1) << 3) |
			(((preg >> 20) & 0x1) << 2) | (((preg >> 9) & 0x1) << 1) | ((preg >> 1) & 0x1);
		out = nlf(nlf_input);
		xor = ((key >> (i % 64)) & 0x1) ^ ((preg >> 16) & 0x1) ^ (preg & 0x1) ^ out;
		preg = (preg >> 1) | (xor << 31);
	}
	return preg;
}



void polynomials(uint32_t *plains, uint32_t *ciphers, int r) {
	size_t number_of_plains = sizeof(plains) / sizeof(plains[0]);	
	char *temp;
	int i, j;	
	for (i = 0; i < number_of_plains; i++)
	{
		for (j = 0; j < 32; j++)
		{
			sprintf(equations[n].eq, "L_%d_%d + %d", i, j, ((plains[i] >> j) & 0x1));						
			n++;
		}
		for (j = 32; j < r + 32; j++)
		{
			temp = "L_%d_%d + k_%d_%d + L_%d_%d + L_%d_%d + L_%d_%d + L_%d_%d"
			" + L_%d_%d*L_%d_%d + b_%d_%d + L_%d_%d*L_%d_%d + L_%d_%d*L_%d_%d"
			" + L_%d_%d*L_%d_%d + L_%d_%d*L_%d_%d + b_%d_%d*L_%d_%d + b_%d_%d*L_%d_%d"
			" + a_%d_%d*L_%d_%d + a_%d_%d*L_%d_%d";
			sprintf(equations[n].eq, temp,
				i, j, i, (j - 32) % 64, i, (j - 32), i, (j - 16), i, (j - 23), i, (j - 30),
				i, (j - 1), i, (j - 12), i, j, i, (j - 6), i, (j - 12), i, (j - 6), i, (j - 30), i, (j - 12), i, (j - 23),
				i, (j - 23), i, (j - 30), i, j, i, (j - 23), i, j, i, (j - 12), i, j, i, (j - 23), i, j, i, (j - 12));						
			n++;
			sprintf(equations[n].eq, "a_%d_%d + L_%d_%d*L_%d_%d", i, j, i, (j - 1), i, (j - 6));			
			n++;
			sprintf(equations[n].eq, "b_%d_%d + L_%d_%d*L_%d_%d", i, j, i, (j - 1), i, (j - 30));			
			n++;
		}
		for (j = r; j < r + 32; j++)
		{
            sprintf(equations[n].eq, "L_%d_%d + %d", i, j, ((ciphers[i] >> j) & 0x1));
			n++;
		}
		printf("value of i = %d\n", i);
	}
}

void copy_string(char *target, char *source) {
   while (*source) {
      *target = *source;
      source++;
      target++;
   }
   *target = '\0';
}

int main() {
	uint64_t k = 0x5cec6701b79fd949;
	uint32_t p = 0xf741e2db;
	uint32_t c;
	c = encrypt(k, p);
	printf("%x\n", c);
	uint32_t ps[2] = {0x123, 0x1273};
	uint32_t cs[2] = {0x1523, 0x1238};
	polynomials(ps, cs, 3);
	size_t size_of_equations;	
	for(size_t i = 0; i < n; i++)
	{
		printf("%s\n", equations[i].eq);
	}	
	getchar();
	return 0;
}