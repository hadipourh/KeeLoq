#include "speed.h"
#include "keeloq.h"

const uint64_t key = 0x5cec6701b79fd949;

double speed(int r)
{
    // Generateing 10000000 random plaintexts:
    time_t t;
    int plaintexts[NUMBER_OF_ENCRYPTIONS];
    int i;
    clock_t start, end;
    double cpu_time_used;
    double rate;
    //Intializes random number generator
    srand((unsigned)time(&t));
    for (i = 0; i < NUMBER_OF_ENCRYPTIONS; i++)
    {
        plaintexts[i] = rand();
    }
    start = clock();
    for (i = 0; i < NUMBER_OF_ENCRYPTIONS; i++)
    {
        keeloq_encrypt(key, plaintexts[i], r);
    }
    end = clock();
    cpu_time_used = ((double)(end - start)) / CLOCKS_PER_SEC;
    rate = (NUMBER_OF_ENCRYPTIONS * 4) / cpu_time_used;
    return rate;
}
