#include "speed.h"
#include "keeloq.h"

double speed(int r)
{
    // Generateing 10000000 random plaintexts:
    uint64_t key = 0x5cec6701b79fd949;
    uint32_t plaintexts[NUMBER_OF_ENCRYPTIONS];
    uint32_t *ciphertext;
    time_t t;    
    ciphertext = (uint32_t*) malloc(NUMBER_OF_ENCRYPTIONS * sizeof(uint32_t));
    int i;
    clock_t start, end;
    double cpu_time_used;
    double rate;
    //Intializes random number generator
    srand((unsigned)time(&t));
    for (i = 0; i < NUMBER_OF_ENCRYPTIONS; i++)
    {
        plaintexts[i] = (uint32_t)rand();
    }
    start = clock();
    for (i = 0; i < NUMBER_OF_ENCRYPTIONS; i++)
    {        
        keeloq_encrypt(&key, plaintexts + i, ciphertext + i, r);
    }
    end = clock();
    cpu_time_used = ((double)(end - start)) / CLOCKS_PER_SEC;
    rate = (NUMBER_OF_ENCRYPTIONS * 4) / cpu_time_used;
    return rate;
}
