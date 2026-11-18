/* Edge coverage for libFuzzer from code GCC instrumented with -fsanitize-coverage=trace-pc.
 *
 * GCC (so GNAT) cannot emit the trace-pc-guard instrumentation libFuzzer reads, and libFuzzer no longer reads
 * plain trace-pc. This file implements __sanitizer_cov_trace_pc the way AFL counts edges (the hash of the
 * previous and current location) into 8-bit counters, and hands those counters to libFuzzer as if a compiler
 * had made them. run.sh weakens libFuzzer's own stub of the same name so this one is used. The comparison
 * hooks (-fsanitize-coverage=trace-cmp) are libFuzzer's, unchanged. */
#include <stddef.h>
#include <stdint.h>

#define EDGES (1u << 16)

static uint8_t counters[EDGES];
static uintptr_t locations[2 * EDGES]; /* libFuzzer wants a {pc, flags} pair per counter */
static __thread uintptr_t previous;

void __sanitizer_cov_8bit_counters_init(uint8_t *start, uint8_t *stop);
void __sanitizer_cov_pcs_init(const uintptr_t *start, const uintptr_t *stop);

__attribute__((constructor)) static void register_counters(void) {
  for (size_t i = 0; i < EDGES; i++) locations[2 * i] = i + 1;
  __sanitizer_cov_8bit_counters_init(counters, counters + EDGES);
  __sanitizer_cov_pcs_init(locations, locations + 2 * EDGES);
}

void __sanitizer_cov_trace_pc(void) {
  uintptr_t here = (uintptr_t)__builtin_return_address(0);
  here = (here >> 4) ^ (here << 8);
  counters[(here ^ previous) & (EDGES - 1)]++;
  previous = here >> 1;
}

/* GCC also traces floating-point comparisons; libFuzzer has no hooks for them. */
void __sanitizer_cov_trace_cmpf(float left, float right) { (void)left; (void)right; }
void __sanitizer_cov_trace_cmpd(double left, double right) { (void)left; (void)right; }
