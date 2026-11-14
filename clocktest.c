#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

/* Dependency-chain benchmark.
   The inline asm barrier forces the accumulator to be materialized every
   iteration, so the compiler cannot fold the loop into a closed form.
   The only critical path is:  x = x + i   (add latency 1 cycle)
   => cycles_per_iteration ~= 1  =>  effective clock = N / elapsed. */

int main(int argc, char **argv) {
    uint64_t N = (argc > 1) ? strtoull(argv[1], NULL, 10) : 4000000000ULL;

    /* warm up: let HWP/P-state settle */
    uint64_t w = 1;
    for (uint64_t i = 0; i < 300000000ULL; i++) {
        w += i;
        __asm__ volatile("" : "+r"(w));
    }

    struct timespec a, b;
    volatile uint64_t sink;
    uint64_t x = 1;

    clock_gettime(CLOCK_MONOTONIC, &a);
    for (uint64_t i = 0; i < N; i++) {
        x += i;
        __asm__ volatile("" : "+r"(x));   /* opaque: prevents closed-form folding */
    }
    clock_gettime(CLOCK_MONOTONIC, &b);
    sink = x + w;

    double t = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
    printf("N=%llu  seconds=%.3f  effective_GHz=%.2f  (sink=%llu)\n",
           (unsigned long long)N, t, (double)N / t / 1e9,
           (unsigned long long)sink);
    return 0;
}
