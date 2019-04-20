#include <stdio.h>
#include "keeloq.h"
#include "speed.h"
#include "polygen.h"

int main()
{
    // Using encrypt and decrypt functions:
    uint64_t k = 0x5cec6701b79fd949;
    uint32_t p = 0xf741e2db;
    uint32_t c;
    int r = 40;
    int number_of_plaintexts = 1;
    printf("Enter the number of rounds: ");
    scanf("%d", &r);
    printf("plaintext before encryption\t: %x\n", p);
    c = keeloq_encrypt(k, p, r);
    printf("ciphertext\t: %x\n", c);
    p = keeloq_decrypt(k, c, r);
    printf("plaintext after decryption\t: %x\n", p);
    /*
    using 'polynomials' function, to genrate poolynomial
    equations of KeeLoq over GF(2), for a given number of rounds:
    */
    printf("%s\n%s", "Enter the number of rounds",
           "this time to generate polynomial equations: ");
    scanf("%d", &r);
    printf("%s\n%s", "Enter an integer bigger than 1",
           "as the number of known plaintexts to generate polynomial equations: ");
    scanf("%d", &number_of_plaintexts);
    time_t t;
    uint32_t *ps = (uint32_t *)malloc(number_of_plaintexts * sizeof(uint32_t));
    uint32_t *cs = (uint32_t *)malloc(number_of_plaintexts * sizeof(uint32_t));
    int i;
    // Intializes random number generator
    srand((unsigned)time(&t));
    for (i = 0; i < number_of_plaintexts; i++)
    {
        ps[i] = (uint32_t)rand();
    }
    for (i = 0; i < number_of_plaintexts; i++)
    {
        cs[i] = keeloq_encrypt(k, ps[i], r);
    }
    output_of_polynomials output;
    output = polynomials(ps, cs, r, number_of_plaintexts);
    for (size_t i = 0; i < output.number_of_eqs; i++)
    {
        printf("%s\n", output.eqs[i].eq);
    }
    free(ps);
    free(cs);
    // Using speed method:
    double cpu_time;
    cpu_time = speed(r);
    printf("speed of %d rounds of encryption\t: %f (mega byte/second)\n", r, cpu_time);
    printf("Type Enter to exit\n");
    do
    {
    } while (getchar() != '\n');
    getchar();
    return 0;
}
