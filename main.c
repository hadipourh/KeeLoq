#include <stdio.h>
#include "keeloq.h"
#include "speed.h"
#include "polygen.h"

int main() 
{
        //using encrypt and decrypt functions:
	uint64_t k = 0x5cec6701b79fd949;
	uint32_t p = 0xf741e2db;
	double cpu_time;
	printf("plaintext before encryption\t: %x\n", p);
	uint32_t c;	
	c = encrypt(k, p, 528);
	printf("ciphertext\t: %x\n", c);
	p = decrypt(k, c, 528);
	printf("plaintext after decryption\t: %x\n", p);	        
        
        /*
        using 'polynomials' function, to genrate poolynomial
        equations of KeeLoq over GF(2), for a given number of rounds:
        */
        int r = 40;
	uint32_t ps[2] = {p, p + 3};
	uint32_t cs[2] = {encrypt(k, ps[0], r), encrypt(k, ps[1], r)};
	output_of_polynomials output;
	output = polynomials(ps, cs, r);
	for(size_t i = 0; i < output.number_of_eqs; i++)
	{
		printf("%s\n", output.eqs[i].eq);	
	}

        //using speed method:
        cpu_time = speed(r);
	printf("speed of %d round encryption\t: %f (mega byte/second)\n", r, cpu_time);	
	printf("Press Enter to exit");
	getchar();
	return 0;
}
