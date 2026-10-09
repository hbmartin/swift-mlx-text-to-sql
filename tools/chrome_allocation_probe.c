// Host-only opt-in benchmark instrumentation; never linked into the app.
// libmalloc's logger ABI: apple-oss-distributions/libmalloc/private/stack_logging.h.
#include <dlfcn.h>
#include <stdint.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

typedef void logger_t(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
static logger_t **logger_slot, *previous_logger;
static atomic_bool active;
static _Atomic(pthread_t) owner;
static uint64_t allocation_count, requested_bytes;

static void count_allocation(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c,
                             uintptr_t result, uint32_t skip) {
  // Accessing a dylib TLS variable on a fresh thread allocates its storage
  // and recursively invokes malloc_logger. Filter without TLS first.
  if (atomic_load_explicit(&active, memory_order_acquire)
      && pthread_equal(pthread_self(), atomic_load_explicit(&owner, memory_order_relaxed))
      && (type & 2) && result) {
    allocation_count++;
    requested_bytes += (type & 4) ? c : ((type & 8) ? b : a);
  }
  if (previous_logger) previous_logger(type, a, b, c, result, skip);
}

// Called only by the serialized main-actor benchmark. Other threads are ignored.
void creg_alloc_begin(void) {
  logger_slot = (logger_t **)dlsym(RTLD_DEFAULT, "malloc_logger");
  allocation_count = requested_bytes = 0;
  if (!logger_slot) return;
  previous_logger = *logger_slot;
  atomic_store_explicit(&owner, pthread_self(), memory_order_relaxed);
  atomic_store_explicit(&active, true, memory_order_release);
  *logger_slot = count_allocation;
}
uint64_t creg_alloc_end(uint64_t *bytes) {
  atomic_store_explicit(&active, false, memory_order_release);
  if (logger_slot) *logger_slot = previous_logger;
  *bytes = requested_bytes;
  return allocation_count;
}
