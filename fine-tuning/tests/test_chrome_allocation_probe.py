"""Exercise the actual malloc logger on threads with uninitialized dylib TLS."""
import subprocess
import sys
from pathlib import Path

import pytest


@pytest.mark.skipif(sys.platform != "darwin", reason="Darwin malloc_logger ABI")
def test_fresh_threads_do_not_reenter_allocator_probe(tmp_path):
    root = Path(__file__).resolve().parents[2]
    library = tmp_path / "probe.dylib"
    source = tmp_path / "probe_test.c"
    executable = tmp_path / "probe_test"
    source.write_text(r'''
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/resource.h>
static atomic_int go;
static atomic_ulong chained;
static void *volatile owner_allocation;
typedef void logger_t(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
static void previous_logger(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c,
                            uintptr_t result, uint32_t skip) {
  if ((type & 2) && result) atomic_fetch_add(&chained, 1);
}
static void *worker(void *arg) {
  while (!atomic_load(&go)) {}
  void *volatile allocation = malloc(4096);
  free(allocation);
  return NULL;
}
int main(int argc, char **argv) {
  struct rlimit limit = {0, 0};
  setrlimit(RLIMIT_CORE, &limit);
  void *handle = dlopen(argv[1], RTLD_NOW);
  if (!handle) return 2;
  void (*begin)(void) = dlsym(handle, "creg_alloc_begin");
  uint64_t (*end)(uint64_t *) = dlsym(handle, "creg_alloc_end");
  if (!begin || !end) return 3;
  pthread_t threads[8];
  for (int i = 0; i < 8; ++i) pthread_create(&threads[i], NULL, worker, NULL);
  logger_t **slot = dlsym(RTLD_DEFAULT, "malloc_logger");
  if (!slot) return 5;
  *slot = previous_logger;
  begin();
  owner_allocation = malloc(64);
  atomic_store(&go, 1);
  for (int i = 0; i < 8; ++i) pthread_join(threads[i], NULL);
  uint64_t bytes = 0;
  uint64_t count = end(&bytes);
  if (*slot != previous_logger || atomic_load(&chained) < 9) return 6;
  unsigned long before = atomic_load(&chained);
  void *volatile after = malloc(32);
  free(after);
  if (atomic_load(&chained) <= before) return 7;
  *slot = NULL;
  free(owner_allocation);
  printf("%llu %llu\n", count, bytes);
  return count == 1 && bytes == 64 ? 0 : 4;
}
''')
    subprocess.run(["clang", "-dynamiclib", "-O2", str(root / "tools/chrome_allocation_probe.c"),
                    "-o", str(library)], check=True, timeout=30)
    subprocess.run(["clang", "-O2", str(source), "-o", str(executable)], check=True, timeout=30)
    for _ in range(6):
        result = subprocess.run([str(executable), str(library)], capture_output=True,
                                text=True, timeout=10)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
