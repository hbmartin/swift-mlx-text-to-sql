# MLX fundamentals: unified memory, lazy evaluation, transforms, and `compile`

**Part 12 · MLX in Python · Reference 01**

---

## Version floor

**MLX is a pip package, not an OS framework, and its floor is much lower than the rest of this
series.** Everything in this guide targets **MLX 0.32.x**. The checkout this guide was written
against declares `MLX_VERSION_MAJOR 0 / MINOR 32 / PATCH 1` → **0.32.1** at commit `973e27f`, and the
documentation site served **"MLX 0.32.0 documentation"** on every page when it was crawled
(2026-07-27). To install the macOS wheel you need **Apple silicon**, a **native `arm` Python ≥ 3.10**,
and **macOS ≥ 14.0** — *not* macOS 27. If you have been reading Parts 7–11 of this series, unlearn
the 27.0 floor here; it does not apply.

A handful of MLX features do carry their own OS floors, and those are the ones that trip people up:
`mx.set_wired_limit` needs **macOS ≥ 15.0**; Metal shader logging needs **Metal 3.2 (macOS 15 / iOS
18)**; the NAX (neural-accelerator) Metal kernels need **macOS/iOS/tvOS/visionOS ≥ 26.2** *and* a GPU
architecture generation ≥ 17; and the JACCL distributed backend needs **macOS ≥ 26.2** plus
Thunderbolt 5. Each is marked in place below. Everything else in this guide — unified memory, lazy
evaluation, the transforms, `mx.compile`, streams, `nn.Module`, saving and loading — runs on macOS
14.

> 🔴 **GAP — MLX version-introduction dates.** The repository clone used for this guide is
> **shallow (50 commits)**, so `git log` on most paths returns only the graft boundary. This guide can
> tell you that an API **exists at 0.32.1** because it was read out of the source or the shipped
> docs; it **cannot** tell you which MLX release introduced it. Wherever you see a phrase like
> "recent" or "new", it means *new relative to the 0.31 → 0.32 commit window we could actually see*,
> not a dated claim. To resolve: `git clone --filter=blob:none` the full history and
> `git log -S '<symbol>' --oneline` it. **Safe default:** pin `mlx==0.32.*` in your requirements and
> re-read the shipped `mlx/version.h` rather than trusting any date, including ours.

---

## What this covers

This is the conceptual primer that the rest of Part 12 assumes. MLX looks like NumPy, and the
resemblance is close enough that you can be productive in ten minutes and wrong in twenty. The five
ideas below are where the resemblance ends, and every one of them is load-bearing:

- **Unified memory.** Arrays do not live "on a device." They live in memory that both CPU and GPU can
  read. You do not move arrays; you choose, per operation, *which device runs it*. This deletes an
  entire category of code (`.to(device)`, `.cpu()`, pinned-memory staging) and introduces a new
  tuning knob (per-op stream/device placement) that most people never touch and occasionally should.
- **Lazy evaluation.** Operations build a graph. Nothing computes until something forces it. This is
  the single largest source of "why is my MLX program using 60 GB" and "why does the traceback point
  at the wrong line."
- **Composable function transforms.** `grad`, `value_and_grad`, `vjp`, `jvp`, `vmap`, `checkpoint`,
  `custom_function`, and `compile` are all *function-to-function* transforms, and every one of them
  returns something the others can transform again.
- **`mx.compile`.** What it actually fuses (a short, verified list), what it costs, and — the part
  that costs people days — exactly what makes it recompile. We read the cache-key code and it
  contains a trigger the documentation does not mention.
- **`nn.Module` as a parameter tree.** MLX modules are not PyTorch modules with different spelling.
  `Module` is a `dict` subclass, parameters are a plain nested tree of arrays, and gradients flow
  through an explicit `model.update(params)` call rather than through in-place `.grad` accumulation.

Plus the plumbing you need on day one: streams and devices, saving and loading (`safetensors`,
`npz`, `.mlxfn`), and converting to and from NumPy and PyTorch without silently destroying your
gradients.

## What this does *not* cover

- **Running or fine-tuning LLMs.** `mlx-lm`, KV caches, prompt caching, quantized generation — those
  are the later guides in this part.
- **Distributed training and `mlx.launch`.** JACCL, ring, MPI, NCCL, hostfile schemas, tensor and
  data parallelism — the distributed guide in this part. This guide mentions JACCL exactly once, for
  its OS floor.
- **Writing custom Metal kernels.** `mx.fast.metal_kernel`, `atomic_outputs`, `math_mode` — the
  kernel-authoring guide in this part, and [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md) for the
  Metal/TensorOps layer underneath.
- **Quantization formats.** `affine` / `mxfp4` / `mxfp8` / `nvfp4`, `qqmm`, `nn.quantize` — the
  quantization guide in this part, and [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) for the
  Core AI equivalent.
- **MLX in Swift.** [Part 13](../../part-13-mlx-swift/README.md). The concepts transfer; the spellings and
  several of the footguns do not.
- **Getting an MLX model into Core AI or Foundation Models.**
  [Part 14](../../part-14-bridges-between-stacks/README.md).

## What you need

- An **Apple silicon Mac**, **macOS ≥ 14.0**, and a **native `arm` Python ≥ 3.10**. Check with
  `python -c "import platform; print(platform.processor())"` — it must print `arm`, not `i386`.
- `pip install mlx`. That is the whole install on Apple silicon.
- Optionally NumPy (`numpy>=2` is what MLX's own dev extras pin) and PyTorch if you want the interop
  sections. MLX's `dev` extras declare `torch>=2.9`; the PyTorch-MPS zero-copy path behaves
  differently before and after **PyTorch 2.12** (§12.3).
- No GPU-programming background. You will not write a kernel in this guide.

---

## ⚠️ Read this before you trust a signature below

MLX moves fast — fast enough that a model's recollection of its API is both **stale and confidently
wrong**. Nothing in this guide was written from memory. Every claim traces to one of the following,
read in the session that produced this guide, strongest first:

1. **The MLX source tree on disk** — `/repos/ml-explore__mlx` at commit `973e27f`, version
   **0.32.1**. This is the strongest class: `python/src/*.cpp` holds the nanobind bindings including
   the literal `nb::sig(...)` strings that *become* the published Python signatures, and
   `mlx/*.cpp` holds the behaviour. Where the docs and the source disagree, **the source wins** and
   the guide says so.
2. **The MLX documentation site crawl** (`ml-explore.github.io/mlx/build/html/`, harvested
   2026-07-27, 5,465 lines of extracted verbatim text). Apple's own prose and code samples.
3. **Maintainer answers in GitHub issues and PRs** on `ml-explore/mlx` and `ml-explore/mlx-lm`.
   Attributed by handle where quoted.
4. **Community-measured numbers** from issue threads — always labelled as such, with hardware and
   OS, and never presented as Apple figures.

Two markers you will see constantly:

> ✅ **VERIFIED** — quoted from source or docs read this session, with the citation attached.
> 🟡 **RECONSTRUCTED** — the concept is attested but a spelling or default is inferred.
> 🔴 **GAP** — we could not verify it, and we say so rather than guessing. Every GAP box ends with a
> safe default.

### Freshness warning, and it is sharp

The clone's HEAD is `973e27f` ("[CUDA] Fix grid overflow in gemm conv unfold kernels…", PR #3893).
**Three NAX correctness fix PRs opened in the three days before 2026-07-27, and none is in
this checkout: #3912/#3922 still open, #3924 closed unmerged, on a 2026-08-03
`gh` re-check:** PRs **#3912** (fp quantized matmul corruption when the quantized dimension is not a
multiple of 32), **#3922** (sorted `gather_qmm` NAX boundary handling), and **#3924** — one of which
is a *missing `else`* in `tile_matmad_nax` that silently miscompiles odd tile shapes. We grepped:
`tile_matmad_nax` is present at `mlx/backend/metal/kernels/steel/gemm/nax.h:825` and called from
`gemm_nax.h:81,119`, and none of #3912/#3922/#3924 appear in `git log`.

None of that touches the fundamentals in this guide — NAX is the M5-and-later matmul path, and it is
Part 11's and the quantization guide's problem. But it establishes the posture: **the newest
surfaces in MLX are sharp-edged, they fail silently and numerically rather than loudly, and a
three-day-old checkout can be wrong.** Pin your version, and re-run your own numerics after every
bump.

---

## Contents

- [0. Orientation: five ideas, one page](#0-orientation-five-ideas-one-page)
- [1. Unified memory: the defining design decision](#1-unified-memory-the-defining-design-decision)
- [2. Lazy evaluation: nothing computes until you force it](#2-lazy-evaluation-nothing-computes-until-you-force-it)
- [3. When to evaluate — and the two ways to get it wrong](#3-when-to-evaluate--and-the-two-ways-to-get-it-wrong)
- [4. Function transforms](#4-function-transforms)
- [5. `custom_function`: teaching MLX your own derivative](#5-custom_function-teaching-mlx-your-own-derivative)
- [6. `mx.compile`: what it actually does](#6-mxcompile-what-it-actually-does)
- [7. Capturing state: `inputs=` and `outputs=`](#7-capturing-state-inputs-and-outputs)
- [8. What causes recompilation — the verified cache key](#8-what-causes-recompilation--the-verified-cache-key)
- [9. Shapeless compilation and its constraints](#9-shapeless-compilation-and-its-constraints)
- [10. Streams and devices](#10-streams-and-devices)
- [11. `nn.Module`: parameters as a tree](#11-nnmodule-parameters-as-a-tree)
- [12. Saving, loading, exporting, and interop](#12-saving-loading-exporting-and-interop)

**Scope:** this reference intentionally ends at §12; the contents list includes only sections present
in this file. API spellings and behavior are pinned to the inspected MLX revision.[^scope-source]

---

## 0. Orientation: five ideas, one page

Apple's own one-paragraph pitch, quoted verbatim from the docs index:

> ✅ **VERIFIED** — `ml-explore.github.io/mlx/build/html/index.html`, harvested 2026-07-27:
>
> > MLX is a NumPy-like array framework designed for efficient and flexible machine learning on Apple
> > silicon, brought to you by Apple machine learning research.
> >
> > The Python API closely follows NumPy with a few exceptions. MLX also has a fully featured C++ API
> > which closely follows the Python API.
> >
> > The main differences between MLX and NumPy are:
> >
> > - **Composable function transformations**: MLX has composable function transformations for
> >   automatic differentiation, automatic vectorization, and computation graph optimization.
> > - **Lazy computation**: Computations in MLX are lazy. Arrays are only materialized when needed.
> > - **Multi-device**: Operations can run on any of the supported devices (CPU, GPU, …)
> >
> > The design of MLX is inspired by frameworks like PyTorch, Jax, and ArrayFire. A notable difference
> > from these frameworks and MLX is the *unified memory model*. Arrays in MLX live in shared memory.
> > Operations on MLX arrays can be performed on any of the supported device types without performing
> > data copies. Currently supported device types are the CPU and GPU.

Read that last paragraph twice. "Operations on MLX arrays can be performed on any of the supported
device types without performing data copies" is not marketing; it is the API contract, and it is why
MLX has no `.to(device)`.

### The five ideas

```
1.  UNIFIED MEMORY      arrays are in shared memory; you pick the DEVICE per operation
                        →  mx.add(a, b, stream=mx.cpu)   mx.add(a, b, stream=mx.gpu)

2.  LAZY EVALUATION     ops record a graph; nothing runs until mx.eval() or an implicit trigger
                        →  c = a + b        # nothing happened
                           mx.eval(c)       # now it happened

3.  TRANSFORMS          every transform is function → function, and they compose arbitrarily
                        →  mx.grad(mx.vmap(mx.grad(f)))

4.  COMPILE             mx.compile fuses element-wise chains into one kernel and caches per signature
                        →  step = mx.compile(step_fn)

5.  MODULE = TREE       nn.Module is a dict; parameters are a nested tree; updates are explicit
                        →  model.update(new_params)
```

### The thirty-second demo

```python
import mlx.core as mx

a = mx.array([1, 2, 3, 4])
print(a.shape)   # [4]        <- a LIST, not a tuple
print(a.dtype)   # int32      <- default integer dtype

b = mx.array([1.0, 2.0, 3.0, 4.0])
print(b.dtype)   # float32    <- default float dtype

c = a + b        # nothing has been computed yet
mx.eval(c)       # now it has
print(c)         # array([2, 4, 6, 8], dtype=float32)
```

> ✅ **VERIFIED** — `usage/quick_start.html`. The `.shape` return being a **list** `[4]` rather than
> a tuple is quoted verbatim from the rendered docs. This bites anyone porting NumPy code that does
> `assert x.shape == (4,)`.

And the transform demo, also verbatim:

```python
>>> x = mx.array(0.0)
>>> mx.sin(x)
array(0, dtype=float32)
>>> mx.grad(mx.sin)(x)
array(1, dtype=float32)
>>> mx.grad(mx.grad(mx.sin))(x)
array(-0, dtype=float32)
```

> ✅ **VERIFIED** — `usage/quick_start.html`. Note `mx.grad(mx.sin)` — you differentiate the
> *function*, not a loss tensor. There is no `.backward()`, no `.grad` attribute, no `zero_grad()`.

### Defaults you should memorise now

| Thing | Default | Source |
|---|---|---|
| Float dtype | `float32` | `python/data_types.html` |
| Integer dtype | `int32` | `python/data_types.html` |
| `float64` | **CPU only** — "Using `float64` arrays on the GPU will result in an exception." | `python/data_types.html` |
| `array.shape` | a **list**, e.g. `[4]` | `usage/quick_start.html` |
| Device for an unspecified op | `mx.default_stream(mx.default_device())` | `usage/using_streams.html` |
| Memory limit (Metal) | 1.5× the device's max recommended working set size | `mx.set_memory_limit` docstring |
| Cache limit | equal to the memory limit; `0` disables the cache | `mx.set_cache_limit` docstring |
| Wired limit | `0` | `mx.set_wired_limit` docstring |
| `MLX_ENABLE_TF32` | **`1`** | `mlx/utils.h::env::enable_tf32()` |
| `MLX_BFS_MAX_WIDTH` | `20` | `mlx/utils.h`, used at `mlx/transforms.cpp:181` |

That `MLX_ENABLE_TF32=1` row deserves a flag now and a full treatment in the numerics guide: **fp32
matmuls are not bit-exact by default.** On CUDA the flag applies unconditionally; on Metal it is
gated behind `is_nax_available()`, which requires macOS ≥ 26.2 *and* GPU architecture generation ≥ 17
(≥ 18 on phone-class `'p'` parts) — so it is inert on M1–M4 and live on M5/A19-class silicon.

> ✅ **VERIFIED** — the Metal gate is quoted from a contributor reading source in mlx#3860:
> *"on Metal every TF32 gate is `is_nax_available() && (env::enable_tf32() || dtype != float32)`."*
> The runtime gate itself is in `mlx/backend/metal/device.cpp` (`is_nax_available()`), which checks
> `__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)` and
> `gen >= (arch == 'p' ? 18 : 17)`.

⚠️ Two mechanics from that thread will cost you a bisection if you don't know them: the env var is
**read lazily on first use**, so `os.environ["MLX_ENABLE_TF32"]="0"` set *after* your first matmul
silently does nothing; and it is **shape-dependent**, because matvec shapes (M=1 or N=1) don't take
the NAX route and stay exact fp32. Same dtype, same op, different precision by operand shape.

---

## 1. Unified memory: the defining design decision

### 1.1 What it removes

In PyTorch, JAX-on-GPU, or CUDA generally, an array has a *location*. You allocate on the host, you
copy to the device, you compute, you copy back. The copy is explicit, it is slow, and forgetting it
is a runtime error you have all seen:

```
RuntimeError: Expected all tensors to be on the same device,
but found at least two devices, cuda:0 and cpu!
```

MLX does not have that error, because MLX arrays do not have a location. Apple silicon has a unified
memory architecture — one physical pool the CPU and GPU both address — and MLX is built directly on
top of that fact rather than emulating a discrete-GPU model over it.

> ✅ **VERIFIED** — `usage/unified_memory.html`, quoted in full because the page is short and every
> sentence matters:
>
> > Apple silicon has a unified memory architecture. The CPU and GPU have direct access to the same
> > memory pool. MLX is designed to take advantage of that.
> >
> > Concretely, when you make an array in MLX you don't have to specify its location:
> >
> > ```python
> > a = mx.random.normal((100,))
> > b = mx.random.normal((100,))
> > ```
> >
> > Both `a` and `b` live in unified memory.
> >
> > In MLX, rather than moving arrays to devices, you specify the device when you run the operation.
> > Any device can perform any operation on `a` and `b` without needing to move them from one memory
> > location to another.

So the mental model flips:

```
PyTorch / CUDA                        MLX
──────────────                        ───
data has a location                   data has no location
you move data to a device             you send an OPERATION to a device
x = x.to("cuda")                      mx.add(a, b, stream=mx.gpu)
copies are explicit and costly        there are no copies
```

### 1.2 What it introduces: per-operation placement

Every MLX operation — *including random number generation* — takes an optional `stream=` keyword.
That is the whole placement API.

> ✅ **VERIFIED** — `usage/using_streams.html`. This page is tiny; here is its **entire** body:
>
> > All operations (including random number generation) take an optional keyword argument `stream`.
> > The `stream` kwarg specifies which `Stream` the operation should run on. If the stream is
> > unspecified then the operation is run on the default stream of the default device:
> > `mx.default_stream(mx.default_device())`. The `stream` kwarg can also be a `Device` (e.g.
> > `stream=my_device`) in which case the operation is run on the default stream of the provided
> > device `mx.default_stream(my_device)`.

```python
import mlx.core as mx

a = mx.random.normal((100,))
b = mx.random.normal((100,))

mx.add(a, b, stream=mx.cpu)   # this add runs on the CPU
mx.add(a, b, stream=mx.gpu)   # this add runs on the GPU
```

> ✅ **VERIFIED** — `usage/unified_memory.html`, verbatim. Apple's own commentary on this snippet:
> *"In the above, both the CPU and the GPU will perform the same add operation. The operations can
> (and likely will) be run in parallel since there are no dependencies between them."*

Note what did *not* happen: no copy, no synchronisation, no allocation. Both operations read the
same bytes.

### 1.3 Dependencies are handled for you

The obvious next worry is data races. Apple addresses it directly:

```python
c = mx.add(a, b, stream=mx.cpu)
d = mx.add(a, c, stream=mx.gpu)   # depends on c, which is being computed on the CPU
```

> ✅ **VERIFIED** — `usage/unified_memory.html`:
>
> > In the above case, the second `add` runs on the GPU but it depends on the output of the first
> > `add` which is running on the CPU. MLX will automatically insert a dependency between the two
> > streams so that the second `add` only starts executing after the first is complete and `c` is
> > available.

You do not write events, fences, or `stream.wait_event()`. The scheduler derives the dependency from
the graph. This is a direct consequence of lazy evaluation (§2): because MLX holds the whole graph
before it runs anything, it can see that `d` needs `c`.

### 1.4 When placement is actually a tuning knob

Most of the time you should leave `stream=` alone. The default is the GPU on Apple silicon and it is
the right answer for anything compute-dense. But because there is no transfer cost, mixing devices
inside one function becomes *cheap enough to be worth doing*, which is not true anywhere else.

Apple's worked example:

```python
def fun(a, b, d1, d2):
    x = mx.matmul(a, b, stream=d1)
    for _ in range(500):
        b = mx.exp(b, stream=d2)
    return x, b

a = mx.random.uniform(shape=(4096, 512))
b = mx.random.uniform(shape=(512, 4))
```

> ✅ **VERIFIED** — `usage/unified_memory.html`, including the numbers:
>
> > The first `matmul` operation is a good fit for the GPU since it's more compute dense. The second
> > sequence of operations are a better fit for the CPU, since they are very small and would probably
> > be overhead bound on the GPU.
> >
> > If we time the computation fully on the GPU, we get **2.8 milliseconds**. But if we run the
> > computation with `d1=mx.gpu` and `d2=mx.cpu`, then the time is only about **1.4 milliseconds**,
> > about twice as fast. These times were measured on an **M1 Max**.

**Attribution: Apple-published, M1 Max, no OS or MLX version stated on the page.** Treat the *shape*
of the result (small element-wise chains are overhead-bound on the GPU; a long serial dependency of
tiny ops belongs on the CPU) as durable, and the 2× as illustrative. We did not reproduce it.

The heuristic that generalises:

| Workload shape | Better device | Why |
|---|---|---|
| Large matmul, conv, attention | GPU | compute-dense; amortises dispatch |
| Long chain of tiny element-wise ops on small arrays | CPU | GPU dispatch overhead dominates |
| Anything with a serial data dependency and tiny operands | CPU | the GPU cannot parallelise a serial chain |
| Two independent branches | one each | genuine concurrency, zero transfer cost |

### 1.5 Where unified memory stops being free

Unified memory removes transfers. It does not remove **allocation**, and on Apple silicon
allocation is where MLX programs actually die. Three community findings, all attributed:

- **`mx.get_peak_memory()` excludes the buffer pool.** *Community-measured*, mlx#3896 (closed
  2026-08-08; open at time
  of research): streaming a 198B MoE layer-by-layer on an **M5 Max 128 GB, mlx 0.32.0, Darwin
  25.4.0**, `mx.get_peak_memory()` reported **~46 GB** while the OS reported **~110 GB**. A
  contributor reading `mlx/backend/metal/allocator.cpp` explained why: *"`peak_memory_` is a
  high-water mark of `active_memory_`, so it can never include the buffer pool. When you free a
  buffer it leaves `active` but is retained by the pool — still a live Metal allocation, still
  GPU-dirty, still in your `phys_footprint`."* The same file's own limit check uses
  `get_active_memory() + get_cache_memory()`.
  **Actionable:** gate memory-pressure logic on `mx.get_active_memory() + mx.get_cache_memory()`.
  In their churn test that sum matched the OS footprint to 0.2%. Closure context (checked
  2026-08-23): the maintainer closed the issue confirming exactly that scoping — `get_peak_memory()`
  is intended for measuring a *single* model's inference/training run, where cache hit rate is near
  100%; for long-running or parallel serving he recommends the `active + cache` check himself. No
  code or docs change landed.
- **`mx.clear_cache()` works, but `phys_footprint` trails it by seconds.** Same thread: 0.00 GB cache
  at t+0 with 15.14 GB still in `phys_footprint`; 0.02 GB by t+4 s. Don't sample immediately and
  conclude you have a leak.
- **A count-based limit exists that no byte knob touches.** *Community-measured*, mlx#3849: the Metal
  backend enforces a **live-buffer count**, default fallback **499000**, readable as
  `mx.device_info()["resource_limit"]`. Exceeding it raises
  `[metal::malloc] Resource limit (499000) exceeded`. There is **no `set_resource_limit`**.
  This matters for §8, because unbounded `mx.compile` variant accumulation is one of the ways to
  exhaust it.

```python
import mlx.core as mx

def memory_report(label: str) -> None:
    """The memory numbers that actually correlate with what the OS sees."""
    active = mx.get_active_memory()
    cache = mx.get_cache_memory()
    peak = mx.get_peak_memory()
    gb = 1024 ** 3
    print(
        f"{label:<20} active={active/gb:6.2f} GB  cache={cache/gb:6.2f} GB  "
        f"active+cache={(active+cache)/gb:6.2f} GB  reported_peak={peak/gb:6.2f} GB"
    )

x = mx.random.normal((8192, 8192))
mx.eval(x)
memory_report("after alloc")
del x
memory_report("after del")        # active drops; cache does NOT
mx.clear_cache()
memory_report("after clear_cache")
```

> ✅ **VERIFIED (API surface)** — `mx.get_active_memory`, `mx.get_peak_memory`,
> `mx.reset_peak_memory`, `mx.get_cache_memory`, `mx.set_memory_limit`, `mx.set_cache_limit`,
> `mx.set_wired_limit`, `mx.clear_cache` are all top-level `mlx.core` functions, listed at
> `python/memory_management.html` and bound in `python/src/memory.cpp`.
> ⚠️ The `mx.metal.get_active_memory()` / `mx.metal.set_memory_limit()` spellings are **deprecated**
> and print a deprecation to stderr on first call (`python/src/metal.cpp`). Use the top-level ones.


---

## 2. Lazy evaluation: nothing computes until you force it

### 2.1 The claim, and it is literal

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`:
>
> > When you perform operations in MLX, no computation actually happens. Instead a compute graph is
> > recorded. The actual computation only happens if an `eval()` is performed.

This is not "deferred until the end of the statement" or "batched for efficiency." It is literal.
After `c = a + b`, `c` is a node in a graph with no data behind it. `c.shape` and `c.dtype` are known
— MLX computes those eagerly, because shapes and dtypes are needed to build the rest of the graph —
but `c`'s bytes do not exist.

```python
import mlx.core as mx

a = mx.array([1.0, 2.0, 3.0])
b = mx.array([10.0, 20.0, 30.0])

c = a + b          # no arithmetic has happened
d = mx.exp(c)      # still nothing
e = d * d          # still nothing; the graph is now three nodes deep

mx.eval(e)         # NOW all three run, in one scheduled batch
```

### 2.2 Why lazy is the right default

Apple gives two reasons, and there is a third that matters more in practice.

**Reason one: transforms need the graph.**

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`:
>
> > Lazy evaluation lets us record a compute graph without actually doing any computations. This is
> > useful for function transformations like `grad()` and `vmap()` and graph optimizations.
> >
> > Currently, MLX does not compile and rerun compute graphs. They are all generated dynamically.
> > However, lazy evaluation makes it much easier to integrate compilation for future performance
> > enhancements.

Note the honesty in that second paragraph: the base execution model is *dynamic*, re-traced every
call. `mx.compile` (§6) is the opt-in that caches and reuses a graph.

**Reason two: you only compute what you use.**

```python
def fun(x):
    a = fun1(x)
    b = expensive_fun(a)
    return a, b

y, _ = fun(x)
```

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`: *"Here, we never actually compute the output of
> `expensive_fun`. Use this pattern with care though, as the graph of `expensive_fun` is still built,
> and that has some cost associated to it."*

**Reason three (the one you will actually exploit): lazy initialisation halves peak memory at load.**

```python
model = Model()                                  # no memory used yet
model.load_weights("weights_fp16.safetensors")
```

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`:
>
> > Say you have a very large model `Model` derived from `mlx.nn.Module`. You can instantiate this
> > model with `model = Model()`. Typically, this will initialize all of the weights as `float32`, but
> > the initialization does not actually compute anything until you perform an `eval()`. If you update
> > the model with `float16` weights, your maximum consumed memory will be half that required if eager
> > computation was used instead.

This is a genuinely important trick and it is why `mlx_lm.load(..., lazy=True)` exists. Constructing
an `nn.Linear(4096, 4096)` records "there will be a `glorot_uniform` initialisation here" — it does
not allocate 64 MB of fp32. If you then overwrite that parameter with a bf16 tensor from a
safetensors file, the fp32 initialisation is never evaluated and never allocated.

⚠️ The inverse is a real trap. *Community-measured*, mlx-lm#1438: *"`mlx_lm.load` with default
`lazy=False` calls `mx.eval(model.parameters())`, which materializes the full stacked
`(num_experts, ...)` expert table at load time — an 18.2 GB spike on Qwen3.6-35B-A3B-4bit before a
single token."* And separately, mlx-lm#1572: *"One-shot `mx.eval(model.parameters())` of >300 GB
models triggers IOGPU command-buffer watchdog timeout at load."* Both are the same lesson from
opposite ends: **`mx.eval` on an entire model is a single, enormous, unbounded unit of work.**

### 2.3 What implicitly evaluates

This is the list to memorise, because these are the lines that "mysteriously" cost 400 ms.

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`:
>
> > An important behavior to be aware of is when the graph will be implicitly evaluated. Anytime you
> > `print` an array, convert it to an `numpy.ndarray`, or otherwise access its memory via
> > `memoryview`, the graph will be evaluated. Saving arrays via `save()` (or any other MLX saving
> > functions) will also evaluate the array.
> >
> > Calling `array.item()` on a scalar array will also evaluate it.

Consolidated:

| Trigger | Example | Notes |
|---|---|---|
| `print` / `repr` | `print(loss)` | the classic accidental sync |
| NumPy conversion | `np.array(x)` | buffer protocol |
| `memoryview` | `memoryview(x)` | anything touching the raw bytes |
| `.item()` | `losses.append(loss.item())` | scalar arrays only |
| `.tolist()` | `x.tolist()` | goes through the buffer |
| Any MLX save | `mx.save`, `mx.savez`, `mx.save_safetensors`, `mx.save_gguf` | ✅ docs |
| Scalar array in `if` | `if y > 0:` | see §2.4 |
| `mx.export_function` | see §12.4 | exports the graph, which requires tracing it |

And the reassurance you need in order to sprinkle `mx.eval` freely while debugging:

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`: *"Also, calling `eval()` on an array or set of
> arrays multiple times is perfectly fine. This is effectively a no-op."*

Once an array is evaluated it holds data and is detached from its inputs — the C++ tutorial states
this outright: *"Once an array is evaluated, it has data and is detached from its inputs."*
(`examples/cpp/tutorial.cpp`.) That detachment also means an evaluated array owns real buffer
memory — the raw ingredient in §3.5's functional-cache leak.

### 2.4 Control flow on array values forces evaluation

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`, an explicit **Warning** block:
>
> > **Warning**: Using scalar arrays for control-flow will cause an evaluation.
>
> ```python
> def fun(x):
>     h, y = first_layer(x)
>     if y > 0:  # An evaluation is done here!
>         z = second_layer_a(h)
>     else:
>         z = second_layer_b(h)
>     return z
> ```
>
> > Using arrays for control flow should be done with care. The above example works and can even be
> > used with gradient transformations. However, this can be very inefficient if evaluations are done
> > too frequently.

Two consequences worth separating:

1. **It works.** Data-dependent Python control flow is legal in eager MLX, and gradients still flow,
   because the branch not taken simply isn't in the graph. This is friendlier than JAX, where you'd
   reach for `lax.cond`.
2. **It is a synchronisation point.** Every such `if` stalls the pipeline: the CPU must wait for the
   GPU to produce `y` before it can decide which ops to record next. In a decode loop that runs
   once per token, this is the difference between a saturated GPU and a sawtooth.
3. **It is illegal inside `mx.compile`.** See §6.4 — under tracing, `y` is a placeholder with no
   data, and the comparison crashes.

### 2.5 The API

```
eval(*args) -> None
```

> ✅ **VERIFIED** — `python/src/transforms.cpp`, read from source. The literal binding:
>
> ```cpp
> "eval",
> [](const nb::args& args) {
>   std::vector<mx::array> arrays = tree_flatten(args, false);
>   {
>     nb::gil_scoped_release nogil;
>     eval(arrays);
>   }
> },
> nb::arg(),
> nb::sig("def eval(*args) -> None"),
> ```
>
> Docstring: *"Evaluate an `array` or tree of `array`. `*args` (arrays or trees of arrays): Each
> argument can be a single array or a tree of arrays. If a tree is given the nodes can be a Python
> `list`, `tuple` or `dict`. **Leaves which are not arrays are ignored.**"*

Three things fall out of that six-line binding:

- **`mx.eval` takes trees.** `mx.eval(model.parameters(), optimizer.state)` is idiomatic and correct;
  you never flatten by hand.
- **Non-array leaves are ignored**, so passing a dict with a stray `"step": 3` in it is harmless.
- **It releases the GIL** (`nb::gil_scoped_release nogil;`). Other Python threads run while the graph
  executes. This is why threaded servers around MLX are viable at all — and also why MLX's
  thread-affinity rules (§10.4) matter.

There is also an asynchronous form:

```python
>>> x = mx.array(1.0)
>>> y = mx.exp(x)
>>> mx.async_eval(y)
>>> print(y)
```

> ✅ **VERIFIED** — `python/transforms.html` and `python/src/transforms.cpp`. Signature
> `async_eval(*args)`. Carries an explicit **Note**: *"This is an experimental API and may change in
> future versions."*
>
> 🔴 **GAP — `async_eval` completion semantics.** The docs give the example above and nothing else.
> We could not verify from the crawl or the binding what guarantees `async_eval` makes about
> completion ordering relative to a later `mx.eval`, whether it is safe across threads, or what
> happens if the process exits with work outstanding. **Safe default: don't use it.** It is labelled
> experimental by its own authors, and the throughput you want is almost always available from
> batching more work into one ordinary `mx.eval` instead.

### 2.6 One knob worth knowing: graph BFS width

> ✅ **VERIFIED** — `mlx/utils.h::env::bfs_max_width()`, consumed at `mlx/transforms.cpp:181`.
> Environment variable **`MLX_BFS_MAX_WIDTH`**, default **`20`**.

When `mx.eval` walks the graph it does a breadth-first traversal with a bounded frontier. The
default of 20 is a scheduling heuristic, not a correctness bound. You will almost never touch this,
but it explains why very wide graphs (hundreds of independent branches) do not all get scheduled at
once, and it is the first thing to try if you have an unusually wide graph that under-utilises the
GPU.

🔴 **GAP:** we did not find documentation for `MLX_BFS_MAX_WIDTH` anywhere on the docs site — it is
source-only. Its performance characteristics are unmeasured by us. **Safe default: leave it alone.**

---

## 3. When to evaluate — and the two ways to get it wrong

There is a single sentence in the docs that defines the whole tuning range:

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`: *"there is some fixed overhead with each graph
> evaluation. On the other hand, there is some slight overhead which grows with the compute graph
> size, so extremely large graphs (while computationally correct) can be costly. Luckily, a wide
> range of compute graph sizes work pretty well with MLX: **anything from a few tens of operations to
> many thousands of operations per evaluation should be okay.**"*

So: **tens to thousands of ops per `eval`.** Below that you are paying fixed overhead too often;
above that you are paying graph-management overhead and, far more importantly, holding every
intermediate alive.

### 3.1 Failure mode one — evaluating too often

Apple's own anti-pattern:

```python
for _ in range(100):
     a = a + b
     mx.eval(a)
     b = b * 2
     mx.eval(b)
```

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`, presented verbatim as *"a bad idea because there is
> some fixed overhead with each graph evaluation."*

Two ops per evaluation is far below the useful range. Worse, from `mx.compile`'s point of view
(§6.2) every `eval` is a **fusion barrier**: MLX can only fuse operations that are in the graph at
the same time. Sprinkling `mx.eval` after every line is the most effective way to make `mx.compile`
do nothing at all while still paying its tracing cost.

This one is *usually* visible — you notice a slow loop. Failure mode two is not.

### 3.2 Failure mode two — never evaluating

The classic beginner training loop:

```python
# ⚠️ WRONG — this graph never stops growing.
losses = []
for batch in dataset:
    loss, grads = loss_and_grad_fn(model, batch)
    optimizer.update(model, grads)
    losses.append(loss)          # keeps a reference to an UNEVALUATED array
# ... 10,000 iterations later, memory is gone
```

Nothing here forces a computation. `loss` is a graph node. `optimizer.update` writes new *graph
nodes* into the model's parameters, and those nodes reference the previous iteration's nodes as
inputs. After 10,000 steps you are holding a 10,000-step-deep graph containing every intermediate
activation of every batch, and you have computed exactly zero gradients.

What you see: memory climbing linearly, no output, and — eventually — either an OOM, a
`[metal::malloc] Resource limit (499000) exceeded`, or a GPU watchdog timeout, all of which point at
whatever line happened to trip the limit rather than at the missing `eval`.

The fix is one line, and it is the single most important line in an MLX training loop:

```python
for batch in dataset:
    # Nothing has been evaluated yet
    loss, grads = value_and_grad_fn(model, batch)

    # Still nothing has been evaluated
    optimizer.update(model, grads)

    # Evaluate the loss and the new parameters, which runs the full
    # gradient computation and optimizer update
    mx.eval(loss, model.parameters())
```

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`, verbatim including the comments. The canonical form
> in `python/optimizers.html` adds the optimizer state, which you need for any optimizer with
> momentum: `mx.eval(model.parameters(), optimizer.state)`.

**Evaluate the model parameters *and* the optimizer state.** If you evaluate only the loss, the
parameter update is still a pending graph and the graph still accumulates — you have fixed the
symptom (the loss prints) and not the leak.

### 3.3 ⚠️ SILENT FAILURE: lazy evaluation moves the traceback

This is the defect class that makes MLX genuinely hard to debug, and it deserves its own box.

> ⚠️ **SILENT FAILURE — the exception fires at the `eval`, not at the bug.**
>
> Because MLX only *records* operations, an operation that will fail at execution time raises
> nothing when you write it. The graph builds happily. The exception surfaces at whatever line
> eventually forces evaluation — which may be a `print` fifty lines later, in a different function,
> possibly inside a library.
>
> ```python
> import mlx.core as mx
>
> def build(x):
>     h = some_projection(x)        # <- the actual bug lives here
>     h = mx.reshape(h, (-1, 128))
>     h = h @ mx.random.normal((256, 64))   # incompatible: recorded, not run
>     return h
>
> def train_step(x):
>     h = build(x)
>     for _ in range(12):
>         h = mx.tanh(h) + h        # 12 more layers of graph on top of the bad node
>     return mx.sum(h)
>
> loss = train_step(mx.random.normal((32, 512)))
> print(loss)   # <-- the traceback points HERE
> ```
>
> Shape *mismatches* in particular are caught at record time in most cases, because MLX propagates
> shapes eagerly. What is **not** caught at record time is everything that depends on data or on
> execution: device-specific dtype restrictions (`float64` on the GPU), out-of-bounds gather indices
> (which are undefined behaviour, not an error), and any backend failure such as an
> allocation refusal or a Metal command-buffer error.
>
> **How to find the real line.** Bisect with `mx.eval`. Add an `mx.eval(...)` after each stage and
> the exception moves to the first stage that actually breaks:
>
> ```python
> def build(x):
>     h = some_projection(x); mx.eval(h)     # temporary
>     h = mx.reshape(h, (-1, 128)); mx.eval(h)
>     h = h @ mx.random.normal((256, 64)); mx.eval(h)
>     return h
> ```
>
> Delete the `mx.eval` calls when you are done — leaving them in is failure mode one (§3.1).
>
> **A reusable debugging aid**, if you would rather not edit call sites:
>
> ```python
> import contextlib, mlx.core as mx
>
> @contextlib.contextmanager
> def eager(enabled: bool = True):
>     """Force evaluation at every checkpoint inside the block.
>
>     Not a real eager mode -- MLX has none. This just gives you a `step()`
>     you can sprinkle, and one place to turn it all off.
>     """
>     def step(*arrays, label: str = ""):
>         if enabled:
>             mx.eval(*arrays)
>             if label:
>                 print(f"[eager] ok: {label}")
>     yield step
>
> with eager(True) as step:
>     h = some_projection(x);  step(h, label="projection")
>     h = mx.reshape(h, (-1, 128)); step(h, label="reshape")
> ```
>
> There is no global `MLX_EAGER=1`. `MLX_DISABLE_COMPILE` (§6.4) disables *compilation*, which is a
> different thing and does not make evaluation eager.

### 3.4 The partial-evaluation trap

A subtler cousin, and Apple documents it explicitly:

> ✅ **VERIFIED** — `usage/lazy_evaluation.html`: *"In the example above, printing the loss
> (`print(loss)`) or adding the loss scalar to a list (`losses.append(loss.item())`) would cause a
> graph evaluation. If these lines are before `mx.eval(loss, model.parameters())` then this will be a
> **partial evaluation, computing only the forward pass.**"*

```python
# ⚠️ SUBTLY SLOW — two evaluations per step instead of one.
for batch in dataset:
    loss, grads = value_and_grad_fn(model, batch)
    optimizer.update(model, grads)
    print(f"loss = {loss.item():.4f}")     # <-- forces the FORWARD pass here
    mx.eval(loss, model.parameters())      # <-- then the backward + update here
```

```python
# ✅ CORRECT — one evaluation, then read the already-computed scalar.
for batch in dataset:
    loss, grads = value_and_grad_fn(model, batch)
    optimizer.update(model, grads)
    mx.eval(loss, model.parameters(), optimizer.state)
    print(f"loss = {loss.item():.4f}")     # <-- free: loss already has data
```

The cost is not catastrophic — the forward pass would have run anyway — but you have split one
scheduled batch into two, added a CPU↔GPU round-trip in the middle of every step, and given the
scheduler less to overlap. In a small-model training loop this is measurable. The rule: **force
evaluation once, then read.**

### 3.5 ⚠️ The functional-cache leak (community-measured)

One more lazy-evaluation failure worth knowing before you write anything stateful, because it is
subtle and it is *not* fixed by the normal training-loop `mx.eval`.

*Community-measured*, mlx-lm#1332 (closed 2026-08-27 and consolidated into #1662, not established
fixed; open at research time), DeepSeek-V4 on Apple silicon:
`RuntimeError: [metal::malloc] Resource limit (499000) exceeded` after **~11,300 generated tokens,
independent of prompt length**.

The mechanism, from the reporter's analysis cross-checked against `mlx/backend/metal/allocator.h`:

- A cache built *functionally* — `self.pooled = mx.concatenate([self.pooled, px], axis=1)` each step
  — makes `pooled_N` reference `pooled_{N-1}` in its input graph.
- The cache object holds the head of that chain, so **every prior step's intermediate array and its
  Metal buffer stays resident**: roughly one retained buffer per layer per step.
- `499000 / 43 layers ≈ 11.3K steps`. The arithmetic matches the observed failure point exactly.
- Critically: **`mx.eval(token)` does not detach the cache intermediates.** Evaluating the *output*
  does not evaluate — and therefore does not detach — the cache state.

The fix was to evaluate the cache state too: *"Adding `mx.eval([c.state for c in cache])` after the
per-step eval collapses growth from ~205 KB/step to ~7 KB/step."*

**Generalise it:** any object that accumulates arrays across iterations must be included in your
per-iteration `mx.eval`, not just the thing you print. If you write a stateful class, give it a
`state` property that returns its arrays and evaluate it every step.


---

## 4. Function transforms

### 4.1 The organising principle

> ✅ **VERIFIED** — `usage/function_transforms.html`: *"MLX uses composable function transformations
> for automatic differentiation, vectorization, and compute graph optimizations. […] The key idea
> behind composable function transformations is that **every transformation returns a function which
> can be further transformed.**"*

Everything follows from that. `mx.grad(f)` is a function. `mx.vmap(mx.grad(f))` is a function.
`mx.compile(mx.vmap(mx.grad(f)))` is a function. There is no tape, no context manager, no
`requires_grad` flag on the data.

If you are coming from PyTorch, Apple says it plainly:

> ✅ **VERIFIED** — `usage/function_transforms.html`, a **Note** block: *"If you are coming to MLX
> from PyTorch, you no longer need functions like `backward`, `zero_grad`, and `detach`, or properties
> like `requires_grad`."*

The complete transform surface, from the API index:

```
eval(*args)                              async_eval(*args)
grad(fun[, argnums, argnames])           value_and_grad(fun[, argnums, argnames])
vjp(fun, primals, cotangents)            jvp(fun, primals, tangents)
vmap(fun[, in_axes, out_axes])           checkpoint(fun)
compile(fun[, inputs, outputs, shapeless])
custom_function(*args, **kwargs)
disable_compile()                        enable_compile()
```

> ✅ **VERIFIED** — `python/transforms.html` index listing, cross-checked against the `nb::sig`
> strings in `python/src/transforms.cpp` read from source. The two agree exactly.

### 4.2 `grad` and `value_and_grad`

```
grad(fun: Callable[P, R],
     argnums: int | Sequence[int] | None = None,
     argnames: str | Sequence[str] = []) -> Callable[P, Any]

value_and_grad(fun: Callable[P, R],
               argnums: int | Sequence[int] | None = None,
               argnames: str | Sequence[str] = []) -> Callable[P, Tuple[R, Any]]
```

> ✅ **VERIFIED** — both signatures are the literal `nb::sig(...)` strings in
> `python/src/transforms.cpp`, and match the rendered autosummary pages.
>
> Key semantics, quoted: *"`argnums` – Specify the index (or indices) of the positional arguments of
> `fun` to compute the gradient with respect to. **If neither `argnums` nor `argnames` are provided
> `argnums` defaults to `0`** indicating `fun`'s first argument. `argnames` – Specify keyword
> arguments of `fun` to compute gradients with respect to. It defaults to `[]` so no gradients for
> keyword arguments by default."*

A complete worked example, verbatim from the docs:

```python
import mlx.core as mx

def loss_fn(w, x, y):
    return mx.mean(mx.square(w * x - y))

w = mx.array(1.0)
x = mx.array([0.5, -0.5])
y = mx.array([1.5, -1.5])

# Computes the gradient of loss_fn with respect to w:
grad_fn = mx.grad(loss_fn)
dloss_dw = grad_fn(w, x, y)
# Prints array(-1, dtype=float32)
print(dloss_dw)

# To get the gradient with respect to x we can do:
grad_fn = mx.grad(loss_fn, argnums=1)
dloss_dx = grad_fn(w, x, y)
# Prints array([-1, 1], dtype=float32)
print(dloss_dx)
```

> ✅ **VERIFIED** — `usage/function_transforms.html`, verbatim including the expected outputs.

`value_and_grad` is what you actually use in training, because computing the loss twice is silly:

```python
loss_and_grad_fn = mx.value_and_grad(loss_fn)
loss, dloss_dw = loss_and_grad_fn(w, x, y)
```

And it has one signature rule that catches people:

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.value_and_grad.html`: *"The function passed to
> `value_and_grad()` should return **either a scalar loss or a tuple in which the first element is a
> scalar loss and the remaining elements can be anything.**"*

Which enables the auxiliary-output pattern:

```python
def lasso(params, inputs, targets, a=1.0, b=1.0):
    outputs = forward(params, inputs)
    mse = (outputs - targets).square().mean()
    l1 = mx.abs(outputs - targets).mean()

    loss = a*mse + b*l1

    return loss, mse, l1

(loss, mse, l1), grads = mx.value_and_grad(lasso)(params, inputs, targets)
```

> ✅ **VERIFIED** — `usage/function_transforms.html`, verbatim. Note the destructuring on the left:
> the *whole tuple* comes back in position 0, gradients in position 1, and gradients are taken with
> respect to the **first element only**.

### 4.3 Gradients flow through pytrees

You do not need a flat parameter vector. `dict`, `list` and `tuple` nest arbitrarily and the gradient
comes back with the same structure:

```python
def loss_fn(params, x, y):
    w, b = params["weight"], params["bias"]
    h = w * x + b
    return mx.mean(mx.square(h - y))

params = {"weight": mx.array(1.0), "bias": mx.array(0.0)}
x = mx.array([0.5, -0.5])
y = mx.array([1.5, -1.5])

grad_fn = mx.grad(loss_fn)
grads = grad_fn(params, x, y)

# Prints
# {'weight': array(-1, dtype=float32), 'bias': array(0, dtype=float32)}
print(grads)
```

> ✅ **VERIFIED** — `usage/function_transforms.html`, verbatim including the printed output.

This is the entire mechanism behind `nn.value_and_grad` (§11.4): a model's parameters *are* a pytree,
so differentiating with respect to them is just `mx.value_and_grad` with a dict in argument 0.

A "tree" in MLX has a precise definition:

> ✅ **VERIFIED** — `python/tree_utils.html`: *"In MLX we consider a python tree to be an arbitrarily
> nested collection of dictionaries, lists and tuples **without cycles**. […] **Note**: Dictionaries
> should have keys that are valid python identifiers."*

That last note is not cosmetic — `tree_flatten` builds dotted paths (`"layers.0.weight"`), so a key
containing a `.` will produce an ambiguous flattened path.

### 4.4 Blocking gradients

```python
y = mx.stop_gradient(x)
```

> ✅ **VERIFIED** — `python/src/ops.cpp`, read from source:
> ```
> def stop_gradient(a: array, /, *, stream: Union[None, Stream, Device] = None) -> array
> ```
> Docstring: *"Stop gradients from being computed. The operation is the identity but it prevents
> gradients from flowing through the array."*

Note it is a *positional-only* first argument (`/`) with a keyword-only `stream`. And note it is in
`is_noop` in the compiler (`mlx/compile.cpp`: `is_noop = Copy, StopGradient`) — so it costs nothing
at execution time in a compiled graph.

### 4.5 Higher-order derivatives

```python
>>> d2fdx2 = mx.grad(mx.grad(mx.sin))
>>> d2fdx2(mx.array(mx.pi / 2))
array(-1, dtype=float32)
```

> ✅ **VERIFIED** — `usage/function_transforms.html`: *"Using `grad()` on the output of `grad()` is
> always ok. You keep getting higher order derivatives."*

### 4.6 `vjp` and `jvp` — the primitives underneath

```
vjp(fun: Callable, primals: list[array], cotangents: list[array])
    -> tuple[list[array], list[array]]

jvp(fun: Callable, primals: list[array], tangents: list[array])
    -> tuple[list[array], list[array]]
```

> ✅ **VERIFIED** — both are literal `nb::sig` strings in `python/src/transforms.cpp`.
>
> `vjp` docstring: *"Computes the product of the `cotangents` with the Jacobian of a function `fun`
> evaluated at `primals`. The `cotangents` should be the same in number, shape, and type as the
> outputs of `fun`. Returns a tuple with the outputs of `fun` in the first position and the
> vector-Jacobian products in the second position."*

```python
import mlx.core as mx

outs, vjps = mx.vjp(mx.sin, (mx.array(1.0),), (mx.array(1.0),))
outs, jvps = mx.jvp(mx.sin, (mx.array(1.0),), (mx.array(1.0),))
```

> ✅ **VERIFIED** — both examples verbatim from the autosummary pages.

You reach for these when `grad` is the wrong shape of tool: `vjp` for reverse-mode with a specific
cotangent (per-example gradients, Jacobian rows), `jvp` for forward-mode (Jacobian columns,
directional derivatives, cheap Hessian-vector products when composed with `grad`). `grad` is
`value_and_grad` is `vjp` with a cotangent of one, restricted to scalar outputs.

### 4.7 `vmap`

```
vmap(fun: Callable[P, R], in_axes: object = 0, out_axes: object = 0) -> Callable[P, R]
```

> ✅ **VERIFIED** — literal `nb::sig` in `python/src/transforms.cpp`.
>
> *"`in_axes` – An integer or a valid **prefix tree** of the inputs to `fun` where each node specifies
> the vmapped axis. **If the value is `None` then the corresponding input(s) are not vmapped.**
> Defaults to `0`. `out_axes` – same idea for outputs. Defaults to `0`."*

The docs' motivating example, verbatim:

```python
xs = mx.random.uniform(shape=(4096, 100))
ys = mx.random.uniform(shape=(100, 4096))

def naive_add(xs, ys):
    return [xs[i] + ys[:, i] for i in range(xs.shape[0])]
```

```python
# Vectorize over the second dimension of x and the
# first dimension of y
vmap_add = mx.vmap(lambda x, y: x + y, in_axes=(0, 1))
```

```python
import timeit

print(timeit.timeit(lambda: mx.eval(naive_add(xs, ys)), number=100))
print(timeit.timeit(lambda: mx.eval(vmap_add(xs, ys)), number=100))
```

> ✅ **VERIFIED** — `usage/function_transforms.html`, with the numbers: *"On an M1 Max the naive
> version takes in total `5.639` seconds whereas the vectorized version takes only `0.024` seconds,
> **more than 200 times faster.**"* Apple's own caveat follows immediately: *"Of course, this
> operation is quite contrived. A better approach is to simply do `xs + ys.T`, but for more complex
> functions `vmap()` can be quite handy."*

**Attribution: Apple-published, M1 Max, no OS/MLX version stated.** The 200× is measuring "a Python
loop of 4,096 tiny graph nodes" against "one vectorised op", which is a real effect but not a
`vmap`-specific one — the same 4,096-node graph is slow for all the reasons in §3.1. Take the
lesson (don't build graphs in Python loops), not the multiplier.

The `None` axis is the part people miss. It is how you broadcast a shared argument:

```python
import mlx.core as mx

# Per-example loss over a batch, with weights SHARED across the batch.
def single_example_loss(w, x, y):
    return mx.square(mx.sum(w * x) - y)

w = mx.random.normal((16,))          # shared
xs = mx.random.normal((32, 16))      # batched on axis 0
ys = mx.random.normal((32,))         # batched on axis 0

# w is not vmapped (None); xs and ys are vmapped on axis 0.
per_example = mx.vmap(single_example_loss, in_axes=(None, 0, 0))
losses = per_example(w, xs, ys)      # shape [32]
mx.eval(losses)
```

> 🟡 **RECONSTRUCTED** — the `in_axes=(None, 0, 0)` composition is built from the verified
> `in_axes` semantics quoted above (`None` → not vmapped; tuple → per-argument) and the verified
> `in_axes=(0, 1)` example. The exact snippet above is ours, not Apple's. It follows directly from
> the documented rules, but we did not execute it.

And the transform's one documented sharp edge:

> ✅ **VERIFIED** — `usage/function_transforms.html`, a **Warning** block: *"Some operations are not
> yet supported with `vmap()`. If you encounter an error like: `ValueError: Primitive's vmap not
> implemented.` file an issue and include your function. We will prioritize including it."*

This is a *loud* failure — an exception with a clear message — which makes it the friendliest gap in
MLX. Note that it happens at **trace time**, not at eval time, because `vmap` has to rewrite the
graph as it is built.

🔴 **GAP — which primitives lack `vmap`.** We did not enumerate them. Doing so requires reading
`mlx/primitives.cpp` (6,202 lines) and checking which `Primitive` subclasses do not override `vmap`;
the C++ base class raises, as the extension example shows
(`throw std::runtime_error("[Axpby] vmap not implemented.")`). **Safe default: try it; the error is
explicit and arrives at trace time, so a single smoke test tells you.**

### 4.8 `checkpoint` — trading compute for memory

```
checkpoint(fun: Callable[P, R]) -> Callable[P, R]
```

> ✅ **VERIFIED** — literal `nb::sig` in `python/src/transforms.cpp`. Docstring: *"Transform the
> passed callable to one that performs gradient checkpointing with respect to the inputs of the
> callable. **Use this to reduce memory use for gradient computations at the expense of increased
> computation.**"*

There is also a module-aware version:

> ✅ **VERIFIED** — `python/mlx/nn/utils.py`, read from source:
> `mlx.nn.utils.checkpoint(module: Module, fn: Optional[Callable] = None)`. Its docstring states it
> checkpoints *"with respect to the trainable parameters of the module (and the callable's inputs)"*
> — i.e. it covers parameters, which the bare `mx.checkpoint` does not. When `fn is None` it captures
> the **module** rather than `module.__call__`, so a monkey-patched `__call__` is respected.

```python
import mlx.nn as nn

class Block(nn.Module):
    def __init__(self, dims: int):
        super().__init__()
        self.norm = nn.RMSNorm(dims)
        self.up = nn.Linear(dims, 4 * dims)
        self.down = nn.Linear(4 * dims, dims)

    def __call__(self, x):
        h = self.up(self.norm(x))
        return x + self.down(nn.gelu(h))

class Stack(nn.Module):
    def __init__(self, n_layers: int, dims: int, checkpointing: bool = False):
        super().__init__()
        self.layers = [Block(dims) for _ in range(n_layers)]
        self.checkpointing = checkpointing

    def __call__(self, x):
        for layer in self.layers:
            step = nn.utils.checkpoint(layer) if self.checkpointing else layer
            x = step(x)
        return x
```

> 🟡 **RECONSTRUCTED** — the *composition* above (per-layer checkpointing inside a stack) is the
> standard pattern and follows from the verified `nn.utils.checkpoint(module)` signature, but this
> exact code is ours. `nn.RMSNorm(dims[, eps])`, `nn.Linear(input_dims, output_dims[, bias])` and
> `nn.gelu` are ✅ verified names from `python/nn/layers.html` and `python/nn/functions.html`.
> 🔴 **GAP:** we did not measure the memory/compute trade-off. Neither the docs nor the source state
> a rule of thumb. **Safe default: don't checkpoint until you actually OOM**, then checkpoint the
> deepest repeated block first, and measure with `mx.get_active_memory() + mx.get_cache_memory()`.

### 4.9 Composing transforms

Everything composes, and the composition order means what you would expect:

```python
import mlx.core as mx

def f(w, x):
    return mx.sum(mx.tanh(w * x))

# 1. gradient w.r.t. w
g = mx.grad(f)

# 2. per-example gradients: batch over x, share w
per_example_grads = mx.vmap(g, in_axes=(None, 0))

# 3. compile the whole thing
fast_per_example_grads = mx.compile(per_example_grads)

w = mx.random.normal((8,))
xs = mx.random.normal((64, 8))
out = fast_per_example_grads(w, xs)     # shape [64, 8]
mx.eval(out)
```

> 🟡 **RECONSTRUCTED** — the composition is ours; each individual transform's semantics are ✅
> verified above. The docs state the general rule verbatim (`usage/quick_start.html`): *"MLX has
> standard function transformations like `grad()` and `vmap()`. Transformations can be composed
> arbitrarily. For example `grad(vmap(grad(fn)))` (or any other composition) is allowed."*

One composition rule is **not** obvious and Apple flags it:

> ✅ **VERIFIED** — `usage/compile.html`, a **Note** block: *"In order to compile as much as
> possible, **a transformation of a compiled function will not by default be compiled**. To compile
> the transformed function simply pass it through `compile()`."*
>
> ```python
> @mx.compile
> def inner(x):
>     return mx.exp(-mx.abs(x))
>
> def outer(x):
>     inner(inner(x))
>
> # Compiling the outer function is good to do as it will likely
> # be faster even though the inner functions are compiled
> fun = mx.compile(outer)
> ```

Read that carefully: `mx.grad(compiled_f)` gives you a gradient function that is *not* compiled. If
you want it compiled you must say `mx.compile(mx.grad(compiled_f))`. The reason is fusion scope —
compiling the outer function lets MLX fuse across the inner boundaries, which it cannot do if the
inner graph is already sealed into a kernel.


---

## 5. `custom_function`: teaching MLX your own derivative

### 5.1 What it is

```
class custom_function(*args, **kwargs)
__init__(self, f: Callable)
```
Methods: `jvp(self, f)`, `vjp(self, f)`, `vmap(self, f)`.

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.custom_function.html`, and the implementation is at
> `python/src/transforms.cpp`. Docstring:
>
> > This class is meant to be used as a function decorator. Instances are callables that behave
> > identically to the wrapped function. However, when a function transformation is used (e.g.
> > computing gradients using `value_and_grad()`) then the functions defined via
> > `custom_function.vjp()`, `custom_function.jvp()` and `custom_function.vmap()` are used instead of
> > the default transformation.
> >
> > Note, all custom transformations are **optional**. Undefined transformations fall back to the
> > default behaviour.

Three reasons to reach for it:

1. **Numerical stability.** The autodiff-derived derivative of your function is correct but
   catastrophically imprecise (the classic `log(1 + exp(x))` family).
2. **Speed.** You know a closed form that is cheaper than differentiating the forward graph.
3. **You wrote a custom Metal kernel** and MLX has no idea how to differentiate it. This is the
   dominant use in practice, and it is why the docs' own worked example lives on the custom-kernel
   page.

### 5.2 The shape of it

```python
import mlx.core as mx

@mx.custom_function
def f(x, y):
    return mx.sin(x) * y

@f.vjp
def f_vjp(primals, cotangent, output):
    x, y = primals
    return cotan * mx.cos(x) * y, cotan * mx.sin(x)

@f.jvp
def f_jvp(primals, tangents):
   x, y = primals
   dx, dy = tangents
   return dx * mx.cos(x) * y + dy * mx.sin(x)

@f.vmap
def f_vmap(inputs, axes):
   x, y = inputs
   ax, ay = axes
   if ay != ax and ax is not None:
       y = y.swapaxes(ay, ax)
   return mx.sin(x) * y, (ax or ay)
```

> ✅ **VERIFIED** — reproduced verbatim from `python/_autosummary/mlx.core.custom_function.html`,
> **including its bug**: the `f_vjp` body references `cotan`, which is not the parameter name
> (`cotangent`). We are reproducing Apple's snippet exactly so you can recognise it; **the working
> form uses the parameter name you declared.** Corrected:
>
> ```python
> @f.vjp
> def f_vjp(primals, cotangent, output):
>     x, y = primals
>     return cotangent * mx.cos(x) * y, cotangent * mx.sin(x)
> ```

The signature contract, which is the thing worth memorising:

| Hook | Receives | Returns |
|---|---|---|
| `vjp` | `(primals, cotangents, outputs)` | one cotangent per input |
| `jvp` | `(primals, tangents)` | one tangent for the output |
| `vmap` | `(inputs, axes)` | `(outputs, out_axes)` |

> ✅ **VERIFIED (arity)** — three positional arguments for `vjp`. The docs are internally
> inconsistent about the *names* — the `custom_function` page shows both
> `f_vjp(primals, cotangent, output)` and `f_vjp(x, dx, fx)` in different snippets — but the arity is
> 3 in every occurrence, including the third independent one on `dev/custom_metal_kernels.html`
> (`grid_sample_vjp(primals, cotangent, _)`). The repo notes record the contract as
> *"**vjp** takes `(primals, cotangents, outputs)` — outputs are passed so you don't recompute the
> forward"*, which explains why the third argument exists.
>
> ✅ **VERIFIED (jvp tangents may be `None`)** — from the same notes: *"**jvp** takes
> `(primals, tangents)`; tangents may be `None` for inputs with no gradient."* Your `jvp` must
> tolerate a `None` in the tangents tuple.

### 5.3 ⚠️ SILENT FAILURE: `custom_function` silently zeroes gradients for captured arrays

This is the footgun the docs call out, and it is worth its own box because the failure is *a number*,
not an exception.

> ⚠️ **SILENT FAILURE — captured arrays become constants, and their gradient is silently `0.0`.**
>
> ✅ **VERIFIED** — `python/_autosummary/mlx.core.custom_function.html`, verbatim: *"All
> `custom_function` instances behave as pure functions. Namely, any variables captured will be
> treated as constants and **no gradients will be computed with respect to the captured arrays.**"*
>
> Apple's own demonstration, verbatim:
>
> ```python
> import mlx.core as mx
>
> def g(x, y):
>     @mx.custom_function
>     def f(x):
>         return x * y
>
>     @f.vjp
>     def f_vjp(x, dx, fx):
>         # Note that we have only x, dx and fx and nothing with respect to y
>         raise ValueError("Abort!")
>
>     return f(x)
>
> x = mx.array(2.0)
> y = mx.array(3.0)
> print(g(x, y))                      # prints 6.0
> print(mx.grad(g)(x, y))             # Raises exception
> print(mx.grad(g, argnums=1)(x, y))  # prints 0.0
> ```
>
> Read the last two lines together. Differentiating with respect to `x` **raises**, because your
> custom `vjp` runs and it happens to raise. Differentiating with respect to `y` — the captured
> array — **prints `0.0`**. It does not raise. It does not warn. It reports that the function is
> constant in `y`, which is false.
>
> In a real model this shows up as a parameter that never learns. The loss goes down (the other
> parameters compensate), the gradient norm looks plausible (the zero is one entry among thousands),
> and nothing in the traceback points at the closure.
>
> **How to avoid it:** make every array the function depends on an *explicit argument*.
>
> ```python
> # ⚠️ WRONG — `scale` is captured; its gradient will be silently zero.
> def make_op(scale):
>     @mx.custom_function
>     def op(x):
>         return x * scale
>     @op.vjp
>     def op_vjp(primals, cotangent, output):
>         (x,) = primals
>         return (cotangent * scale,)
>     return op
>
> # ✅ CORRECT — `scale` is an argument, so it gets a cotangent.
> @mx.custom_function
> def op(x, scale):
>     return x * scale
>
> @op.vjp
> def op_vjp(primals, cotangent, output):
>     x, scale = primals
>     return cotangent * scale, cotangent * x
> ```
>
> **How to detect it:** a finite-difference check against the *undecorated* function. Because
> `custom_function` instances "behave identically to the wrapped function" in the forward direction,
> you can compare gradients directly:
>
> ```python
> import mlx.core as mx
>
> def finite_diff_check(fn, args, argnum: int, eps: float = 1e-3) -> tuple[float, float]:
>     """Compare mx.grad against a central finite difference. Returns (analytic, numeric)."""
>     analytic = mx.grad(fn, argnums=argnum)(*args)
>
>     bumped_hi = list(args)
>     bumped_lo = list(args)
>     bumped_hi[argnum] = args[argnum] + eps
>     bumped_lo[argnum] = args[argnum] - eps
>     numeric = (fn(*bumped_hi) - fn(*bumped_lo)) / (2 * eps)
>
>     mx.eval(analytic, numeric)
>     return float(analytic.item()), float(numeric.item())
>
> a, n = finite_diff_check(op, (mx.array(2.0), mx.array(3.0)), argnum=1)
> print(f"analytic={a}  numeric={n}")
> assert abs(a - n) < 1e-2, "custom_function gradient disagrees with finite differences"
> ```
>
> 🟡 **RECONSTRUCTED** — the helper is ours. It uses only ✅ verified APIs (`mx.grad(fn, argnums=)`,
> `.item()`, `mx.eval`). Run it once per custom function, on scalars, at authoring time.

### 5.4 The realistic use: differentiating a custom kernel

The docs' full worked example is a bilinear `grid_sample`, and it is the canonical shape of a
kernel + custom VJP pair. Abbreviated to show the structure (the full Metal source is in the
kernel-authoring guide):

```python
kernel = mx.fast.metal_kernel(
    name="grid_sample",
    input_names=["x", "grid"],
    output_names=["out"],
    source=source,
)

@mx.custom_function
def grid_sample(x, grid):

    assert x.ndim == 4, "`x` must be 4D."
    assert grid.ndim == 4, "`grid` must be 4D."

    B, _, _, C = x.shape
    _, gN, gM, D = grid.shape
    out_shape = (B, gN, gM, C)

    assert D == 2, "Last dim of `grid` must be size 2."

    outputs = kernel(
        inputs=[x, grid],
        template=[("T", x.dtype)],
        output_shapes=[out_shape],
        output_dtypes=[x.dtype],
        grid=(np.prod(out_shape), 1, 1),
        threadgroup=(256, 1, 1),
    )
    return outputs[0]


@grid_sample.vjp
def grid_sample_vjp(primals, cotangent, _):
    x, grid = primals
    ...
    outputs = grad_kernel(
        inputs=[x, grid, cotangent],
        template=[("T", x.dtype)],
        output_shapes=[x.shape, grid.shape],
        output_dtypes=[x.dtype, x.dtype],
        grid=(grid_size, 1, 1),
        threadgroup=(256, 1, 1),
        init_value=0,
    )
    return outputs[0], outputs[1]
```

> ✅ **VERIFIED** — `dev/custom_metal_kernels.html`, verbatim (elided in the middle, marked with
> `...`). Note the third `vjp` parameter is `_` — Apple's own code ignores the forward output here,
> which confirms both the arity and that the argument is a convenience rather than a requirement.
>
> Reported speedups, **Apple-published, M1 Max**, `x.shape=(8,1024,1024,64)`,
> `grid.shape=(8,256,256,2)`: forward `55.7ms -> 6.7ms => 8x speed up`; VJP
> `676.4ms -> 16.7ms => 40x speed up`. No OS or MLX version is stated on the page.

Two details from that example generalise to every custom-kernel VJP: the backward kernel needs
`atomic_outputs=True` (so multiple threadgroups can accumulate into the same gradient element) and
`init_value=0` (so the outputs start zeroed rather than holding recycled buffer contents). Getting
`init_value` wrong gives you gradients contaminated with whatever the allocator handed you last —
another silent numerical failure. The kernel-authoring guide covers this properly.

---

## 6. `mx.compile`: what it actually does

### 6.1 The signature and the promise

```
compile(fun: Callable[P, R],
        inputs: object | None = None,
        outputs: object | None = None,
        shapeless: bool = False) -> Callable[P, R]
```

> ✅ **VERIFIED** — the literal `nb::sig` string at `python/src/transforms.cpp:1494`, read from
> source, character for character. It matches the rendered autosummary page exactly.

> ✅ **VERIFIED** — `usage/compile.html` opening: *"MLX has a `compile()` function transformation
> which compiles computation graphs. Function compilation results in smaller graphs by **merging
> common work and fusing certain operations**. In many cases this can lead to big improvements in
> run-time and memory use."*

Note the two distinct claims: **merging common work** (common-subexpression elimination, the
"simplify" pass) and **fusing certain operations** (the "fuse" pass). They are separate passes and
you can disable them independently — see §6.5.

The basic usage is unremarkable:

```python
def fun(x, y):
    return mx.exp(-x) + y

x = mx.array(1.0)
y = mx.array(2.0)

# Regular call, no compilation
# Prints: array(2.36788, dtype=float32)
print(fun(x, y))

# Compile the function
compiled_fun = mx.compile(fun)

# Prints: array(2.36788, dtype=float32)
print(compiled_fun(x, y))
```

> ✅ **VERIFIED** — `usage/compile.html`, verbatim. Apple's framing of the cost:
> *"The first time you call a compiled function, MLX will build the compute graph, optimize it, and
> generate and compile code. This can be relatively slow. However, MLX will cache compiled functions,
> so calling a compiled function multiple times will not initiate a new compilation. This means you
> should typically compile functions that you plan to use more than once."*

### 6.2 What it fuses — the exact list

This is the section that answers "will `compile` help my function?", and the answer is verifiable
because the predicate is a plain C++ function.

> ✅ **VERIFIED** — `mlx/compile.cpp`, read from source at commit `973e27f`:
>
> ```cpp
> bool is_fusable(const Primitive& p) {
>   return is_unary(p) || is_binary(p) || is_ternary(p) || is_broadcast(p);
> }
> ```

And those four predicates enumerate, exhaustively:

| Class | Primitives |
|---|---|
| **unary** | `Abs, ArcCos, ArcCosh, ArcSin, ArcSinh, ArcTan, ArcTanh, AsType, Ceil, Cos, Conjugate, Cosh, Remainder, Erf, ErfInv, Exp, Floor, Log, Log1p, LogicalNot, Negative, Round, Sigmoid, Sign, Sin, Sinh, Square, Sqrt, Tan, Tanh, Expm1, Real, Imag, BitwiseInvert` |
| **binary** | `Add, Divide, Equal, Greater, GreaterEqual, Less, LessEqual, LogicalNot, LogicalAnd, LogicalOr, LogAddExp, Maximum, Minimum, Multiply, NotEqual, Power, Subtract, BitwiseBinary, ArcTan2` |
| **ternary** | `Select` |
| **broadcast** | `Broadcast` |

> ✅ **VERIFIED** — transcribed from the `typeid(p) == typeid(...)` chains in
> `mlx/compile.cpp` (`is_unary`, `is_binary`, `is_ternary`, `is_broadcast`), read from source this
> session.

Two adjacent classifications from the same file:

```cpp
bool is_noop(const Primitive& p) {
  return typeid(p) == typeid(Copy) || typeid(p) == typeid(StopGradient);
}

bool is_reduction(const Primitive& p) {
  return typeid(p) == typeid(Reduce) || typeid(p) == typeid(ArgReduce);
}
```

**What this means in practice.** `mx.compile` fuses **element-wise chains and broadcasts, and
nothing else.** It does not fuse:

- **matmuls** (`Matmul`, `AddMM`, `GatherMM`, `QuantizedMatmul`, …)
- **reductions** (`sum`, `mean`, `max`, `argmax`, `softmax`'s reduction half, …)
- **gathers and scatters** (indexing, `take`, `gather_qmm`, …)
- **convolutions**
- **`mx.fast.*`** — `rms_norm`, `layer_norm`, `rope`, `scaled_dot_product_attention` are already
  single fused kernels; `compile` cannot merge them with their neighbours
- **FFT, linalg, sorts**

So the mental model is: **`compile` collapses the glue between your heavy kernels.** A transformer
block's matmuls and attention are untouched; the activations, residual adds, scalar multiplies,
masking and dtype casts between them collapse into one kernel each. That is a real and worthwhile
win — those glue ops are pure memory traffic — but it is not "MLX compiles my model."

There is one error message you may hit:

> ✅ **VERIFIED** — `mlx/compile.cpp:965` (per the repo notes' line reference; the string is in
> the fusion pass): `"[compile] Compilation failed. Tried to fuse operations with different output
> shapes"`. This is a **loud** failure, which is the good kind.

### 6.3 The speedup, honestly attributed

```python
def gelu(x):
    return x * (1 + mx.erf(x / math.sqrt(2))) / 2
```

> ✅ **VERIFIED** — `usage/compile.html`: *"If you use this function with small arrays, it will be
> overhead bound. If you use it with large arrays it will be memory bandwidth bound. However, all of
> the operations in the `gelu` are fusible into a single kernel with `compile()`. This can speedup
> both cases considerably."*

Apple's benchmark harness, verbatim — worth copying because it has the two properties a benchmark
needs (warm-up, and `mx.eval` inside the timed loop):

```python
import time

def timeit(fun, x):
    # warm up
    for _ in range(10):
        mx.eval(fun(x))

    tic = time.perf_counter()
    for _ in range(100):
        mx.eval(fun(x))
    toc = time.perf_counter()
    tpi = 1e3 * (toc - tic) / 100
    print(f"Time per iteration {tpi:.3f} (ms)")
```

```python
x = mx.random.uniform(shape=(32, 1000, 4096))
timeit(gelu, x)
timeit(mx.compile(gelu), x)
```

> ✅ **VERIFIED** — `usage/compile.html`: *"On an M1 Max the times are **15.5 and 3.1
> milliseconds**. The compiled `gelu` is **five times faster**."*

**Attribution: Apple-published, M1 Max, no OS or MLX version stated on the page. We did not
reproduce it.** The 5× is a best case by construction: `gelu` is *seven* element-wise operations on
a 512-MB fp32 array with no fusion-breaking ops at all, so the uncompiled version reads and writes
that array seven times and the compiled version does it once. Your transformer block will not see
5×. What it will see is the elimination of a handful of full-tensor round-trips per layer, which is
worth measuring.

> ⚠️ Note the warm-up loop is not optional. The first call to a compiled function pays graph
> construction, optimisation, code generation and Metal compilation. If you benchmark without warming
> up you are measuring the compiler.

Corroborating data point on how much a compiled step is worth in a real decode loop — *community*,
mlx-swift-lm#467 is titled "compiled decode step" and is one of a batch of upstreaming PRs gated
**token-identical** in interleaved A/B testing on **M3 Max**. We did not read a number from it, and
it is Swift rather than Python, so treat it as directional only.

### 6.4 The tracing model, and why you cannot `print` inside

> ✅ **VERIFIED** — `usage/compile.html`: *"When a compiled function is first called, it is traced
> with **placeholder inputs**. This means you can't evaluate arrays (for example to print their
> contents) inside compiled functions."*
>
> ```python
> @mx.compile
> def fun(x):
>     z = -x
>     print(z)  # Crash
>     return mx.exp(z)
>
> fun(mx.array(5.0))
> ```

The placeholder has shape and dtype but no data. `print` forces evaluation (§2.3), evaluation of a
placeholder is undefined, and MLX crashes. The same applies to `.item()`, `np.array(...)`, and any
`if` on an array value (§2.4).

The escape hatch is global:

```python
@mx.compile
def fun(x):
    z = -x
    print(z)  # Okay
    return mx.exp(z)

mx.disable_compile()
fun(mx.array(5.0))
```

> ✅ **VERIFIED** — `usage/compile.html`. APIs: `mx.disable_compile()` — *"Globally disable
> compilation."*; `mx.enable_compile()` — *"Globally enable compilation."*; environment variable
> **`MLX_DISABLE_COMPILE`**.
>
> ✅ **VERIFIED (precedence)** — from the repo notes reading `mlx/compile.cpp:219` and the bindings:
> `mx.enable_compile()` **overrides** the `MLX_DISABLE_COMPILE` environment variable. So a library
> that calls `enable_compile()` will defeat your env var; if you need compilation off for debugging,
> prefer calling `mx.disable_compile()` *after* imports.

A debugging pattern that is worth having in your pocket:

```python
import os, mlx.core as mx

# Put this at the very top of a repro script.
if os.environ.get("DEBUG_MLX"):
    mx.disable_compile()   # calls, not the env var: survives library enable_compile()
```

### 6.5 The two passes, and how to bisect them

> ✅ **VERIFIED** — `mlx/compile.h` / `mlx/compile.cpp`, read from source:
>
> ```cpp
> enum class CompileMode { disabled, no_simplify, no_fuse, enabled };
> MLX_API void set_compile_mode(CompileMode mode);
> ```
>
> Per the repo notes, two passes run per compiled entry (`mlx/compile.cpp:1141-1150`):
> `compile_simplify` (skipped under `no_simplify`) then `compile_fuse` (skipped under `no_fuse`).

This is a genuinely useful bisection tool when a compiled function produces different numbers from
its uncompiled twin: `no_fuse` keeps CSE and drops kernel fusion, `no_simplify` does the reverse.

🔴 **GAP — `set_compile_mode` is not exposed to Python.** We found `CompileMode` and
`set_compile_mode` in the C++ headers and confirmed `disable_compile` / `enable_compile` in the
Python bindings, but we did **not** find a Python binding for the intermediate `no_simplify` /
`no_fuse` modes, and there is no mention of them anywhere in the docs-site crawl. **Safe default
from Python: bisect with `mx.disable_compile()` (all-or-nothing).** If you need the intermediate
modes, you are in C++ or you are rebuilding MLX. To resolve: grep `python/src/transforms.cpp` for
`CompileMode` in a newer checkout.

### 6.6 Compiled functions must be pure

> ✅ **VERIFIED** — `usage/compile.html`: *"Compiled functions are intended to be *pure*; that is
> they should not have side effects."*
>
> ```python
> state = []
>
> @mx.compile
> def fun(x, y):
>     z = x + y
>     state.append(z)
>     return mx.exp(z)
>
> fun(mx.array(1.0), mx.array(2.0))
> # Crash!
> print(state)
> ```
>
> *"After the first call of `fun`, the `state` list will hold a **placeholder array**. The placeholder
> does not have any data; it is only used to build the computation graph. Printing such an array
> results in a crash."*

Note what happened: the `append` ran exactly once, during tracing, and what it stored was a
placeholder. On the second call the traced graph is replayed and the Python `append` does not run at
all. **Any Python side effect inside a compiled function happens once, at trace time, and never
again.** That includes logging, counters, progress bars, and appending to lists.

This has a happier and more consequential cousin, next section.


---

## 7. Capturing state: `inputs=` and `outputs=`

### 7.1 ⚠️ SILENT FAILURE: captured arrays are frozen constants

This is the second silent failure in this guide, and it is the one most likely to cost you a
training run.

> ⚠️ **SILENT FAILURE — an array captured by closure becomes a compile-time constant. Updating it
> has no effect, and nothing tells you.**
>
> ✅ **VERIFIED** — `usage/compile.html`, verbatim including the comments:
>
> ```python
> state = [mx.array(1.0)]
>
> @mx.compile
> def fun(x):
>     return x + state[0]
>
> # Prints array(2, dtype=float32)
> print(fun(mx.array(1.0)))
>
> # Update state
> state[0] = mx.array(5.0)
>
> # Still prints array(2, dtype=float32)
> print(fun(mx.array(1.0)))
> ```
>
> The second `print` should be `6`. It is `2`. There is no exception, no warning, and no
> log line. The value `1.0` was baked into the compiled kernel at trace time and the assignment to
> `state[0]` rebound a Python name that the compiled graph no longer consults.
>
> **Why this is so dangerous in a training loop:** it looks exactly like "my model isn't learning."
> If your optimizer state, learning-rate schedule, RNG key, or model parameters are reached by
> closure rather than passed as arguments, the compiled step will happily train against iteration
> zero's values forever. The loss curve is flat-ish, the gradients are finite, and the bug is
> invisible in any per-step assertion you are likely to write.
>
> **Detection:** run the same step function with and without compilation and compare outputs after
> two or more iterations. One iteration is not enough — the first call traces, so it is *correct*.
>
> ```python
> import mlx.core as mx
>
> def check_compile_equivalence(step_fn, args_seq, *, atol=1e-5):
>     """Run N steps compiled and uncompiled; compare. Catches frozen-constant capture.
>
>     Requires N >= 2: the first compiled call traces and therefore always agrees.
>     """
>     mx.disable_compile()
>     eager_outs = [step_fn(*a) for a in args_seq]
>     mx.eval(eager_outs)
>     eager_outs = [mx.array(o) for o in eager_outs]   # detach from the graph
>
>     mx.enable_compile()
>     compiled = mx.compile(step_fn)
>     comp_outs = [compiled(*a) for a in args_seq]
>     mx.eval(comp_outs)
>
>     for i, (e, c) in enumerate(zip(eager_outs, comp_outs)):
>         if not mx.allclose(e, c, atol=atol).item():
>             raise AssertionError(
>                 f"compiled/eager divergence at step {i}: "
>                 f"max|delta| = {mx.max(mx.abs(e - c)).item()}"
>             )
>     print(f"compile equivalence OK over {len(args_seq)} steps")
> ```
>
> 🟡 **RECONSTRUCTED** — the helper is ours. Every API in it is ✅ verified: `mx.disable_compile`,
> `mx.enable_compile`, `mx.compile`, `mx.eval`, `mx.allclose`, `mx.max`, `mx.abs`, `.item()`.
> ⚠️ Note this check assumes your step function is deterministic. If it samples, add
> `mx.random.state` to the compiled capture (§7.4) *and* seed both runs, or the comparison will fail
> for the wrong reason.

### 7.2 Fix one: pass the state as an argument

```python
state = [mx.array(1.0)]

@mx.compile
def fun(x, state):
    return x + state[0]

# Prints array(2, dtype=float32)
print(fun(mx.array(1.0), state))
...
# Prints array(6, dtype=float32)
print(fun(mx.array(1.0), state))
```

> ✅ **VERIFIED** — `usage/compile.html`, verbatim (the `...` is Apple's elision, not ours).

This works because arrays reached through the *arguments* are flattened into the compiled function's
input list, so a new value is a new input rather than a new constant. It is the simplest fix and it
is what you should reach for first.

### 7.3 Fix two: `inputs=` and `outputs=`

When threading state through arguments is impractical — which it usually is, because
`optimizer.update(model, grads)` mutates two objects that are not arguments — MLX gives you an
explicit capture list.

```python
from functools import partial

state = [mx.array(1.0)]

# Tell compile to capture state as an input
@partial(mx.compile, inputs=state)
def fun(x):
    return x + state[0]

# Prints array(2, dtype=float32)
print(fun(mx.array(1.0)))

# Update state
state[0] = mx.array(5.0)

# Prints array(6, dtype=float32)
print(fun(mx.array(1.0)))
```

```python
from functools import partial

state = []

# Tell compile to capture state as an output
@partial(mx.compile, outputs=state)
def fun(x, y):
    z = x + y
    state.append(z)
    return mx.exp(z)

fun(mx.array(1.0), mx.array(2.0))
# Prints [array(3, dtype=float32)]
print(state)
```

> ✅ **VERIFIED** — both snippets verbatim from `usage/compile.html`. Apple's framing: *"This is
> particularly useful for compiling a function which includes an update to a container of arrays, as
> is commonly done when training the parameters of a `mlx.nn.Module`."*

The `partial` is necessary because `inputs=` and `outputs=` are keyword parameters of `compile`, not
of your function; `@mx.compile` bare is only valid when you want the defaults.

The semantics of both parameters, verbatim from the signature docs:

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.compile.html`:
>
> > `inputs` (*list or dict, optional*) – These inputs will be captured during the function
> > compilation along with the inputs to `fun`. The `inputs` can be a `list` or a `dict` containing
> > arbitrarily nested lists, dictionaries, or arrays. **Leaf nodes that are not `array` are
> > ignored.** Default: `None`
> >
> > `outputs` (*list or dict, optional*) – These outputs will be captured and updated in a compiled
> > function. […] Leaf nodes that are not `array` are ignored. Default: `None`

"Leaf nodes that are not `array` are ignored" is doing quiet work here: it means you can pass a whole
`optimizer.state` dict — which contains a `"step"` array and possibly scalar config — without
filtering it.

### 7.4 The canonical compiled training step

This is the single most-copied snippet in MLX, and it is worth understanding line by line.

```python
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
from functools import partial

# 4 examples with 10 features each
x = mx.random.uniform(shape=(4, 10))

# 0, 1 targets
y = mx.array([0, 1, 0, 1])

# Simple linear model
model = nn.Linear(10, 1)

# SGD with momentum
optimizer = optim.SGD(learning_rate=0.1, momentum=0.8)

def loss_fn(model, x, y):
    logits = model(x).squeeze()
    return nn.losses.binary_cross_entropy(logits, y)

# The state that will be captured as input and output
state = [model.state, optimizer.state]

@partial(mx.compile, inputs=state, outputs=state)
def step(x, y):
    loss_and_grad_fn = nn.value_and_grad(model, loss_fn)
    loss, grads = loss_and_grad_fn(model, x, y)
    optimizer.update(model, grads)
    return loss

# Perform 10 steps of gradient descent
for it in range(10):
    loss = step(x, y)
    # Evaluate the model and optimizer state
    mx.eval(state)
    print(loss)
```

> ✅ **VERIFIED** — `usage/compile.html`, verbatim including comments.

Line by line:

- **`state = [model.state, optimizer.state]`** — both objects' *live* array containers.
  `Module.state` is special and §11.3 explains it: it returns the module **itself**, so this list
  holds a reference that reflects updates rather than a snapshot.
- **`inputs=state`** — the compiled function reads the current parameters and optimizer moments on
  every call rather than the traced ones.
- **`outputs=state`** — the compiled function *writes back* the updated parameters and moments.
  Without this, `optimizer.update(model, grads)` inside the compiled function would update
  placeholders and be discarded.
- **`nn.value_and_grad(model, loss_fn)` inside `step`** — this looks wasteful (rebuilding the
  transform every call) but it is not: everything inside the function body runs once, at trace time.
- **`mx.eval(state)`** — the forcing point (§3.2). Note it evaluates the *captured state*, which is
  exactly the model parameters plus the optimizer moments.
- **`print(loss)`** — this comes *after* `mx.eval(state)`, avoiding the partial-evaluation trap of
  §3.4. Apple got the ordering right; copy the ordering.

And the sampling caveat, which is easy to miss and produces silently deterministic output:

> ✅ **VERIFIED** — `usage/compile.html`, a **Note**: *"If you are using a module which performs
> random sampling such as `mlx.nn.Dropout()`, make sure you also include `mx.random.state` in the
> `state` captured by `compile()`, i.e. `state = [model.state, optimizer.state, mx.random.state]`."*

We verified what `mx.random.state` actually is, because the docs never say:

> ✅ **VERIFIED** — `python/src/random.cpp`, read from source. `mx.random.state` is a **process-global
> sentinel object** of an internal class `_RandomState`, with a comment that explains the design
> exactly:
>
> ```cpp
> // A process-global sentinel for `mx.random.state`. Since it is the same object
> // on every thread, capturing it (e.g. with `mx.compile`) is thread-independent;
> // the pytree traversal in trees.cpp resolves it to the calling thread's key.
> ```
>
> The underlying key sequence is `static thread_local`:
> ```cpp
> PyKeySequence& default_key() {
>   // Each thread has its own random key to avoid race condition.
>   static thread_local PyKeySequence ks;
>   return ks;
> }
> ```

Two consequences. First, **`mx.random.seed()` in one thread does not seed another** — each thread
carries its own key. Second, the sentinel-plus-thread-local design is *why* capturing
`mx.random.state` in a compiled function works across threads at all; getting this wrong was a real
bug, fixed by mlx PR **#3828** ("Fix captured random state in compile"), which per the issue notes
closed mlx-lm#1444 and fixed mlx-lm#1439 — *"temperature > 0 is silently deterministic on the second
call onward."* That is exactly the silent failure of §7.1, wearing a sampling costume.

### 7.5 What arguments a compiled function will accept

Reading the binding turns up a rule the docs do not state anywhere:

> ✅ **VERIFIED** — `python/src/transforms.cpp`, `PyCompiledFun::call_impl`, read from source. The
> argument-flattening recursion accepts exactly: `list`, `tuple`, `dict`, `mx.array`, `str`, `int`,
> `float`, and `None`. Anything else raises:
>
> ```
> [compile] Function arguments must be trees of arrays or constants
> (floats, ints, strings, or None), but received type <T>.
> ```

So you cannot pass a NumPy array, a dataclass, a `Module`, or a custom object as an argument to a
compiled function. Arrays go in the input list; **`str`, `int`, `float` and `None` go into the
`constants` vector** — which is part of the cache key. Hold on to that; it is the whole of §8.4.

---

## 8. What causes recompilation — the verified cache key

### 8.1 What the documentation says

> ✅ **VERIFIED** — `usage/compile.html`, verbatim:
>
> > There are some important cases to be aware of that can cause a function to be recompiled:
> > - Changing the shape or number of dimensions
> > - Changing the type of any of the inputs
> > - Changing the number of inputs to the function
> >
> > In certain cases only some of the compilation stack will be rerun (for example when changing the
> > shapes) and in other cases the full compilation stack will be rerun (for example when changing the
> > types). In general you should avoid compiling functions too frequently.

That list is correct and incomplete.

### 8.2 What the source says

We read `CompilerCache::find` in `mlx/compile.cpp` at commit `973e27f`. Here is the actual lookup,
verbatim:

```cpp
CacheEntry& find(
    std::uintptr_t fun_id,
    const std::vector<array>& inputs,
    bool shapeless,
    const std::vector<uint64_t>& constants) {
  // Find the cache entries for |fun_id|.
  std::vector<CacheEntry>& entries = cache_[fun_id];

  // Compare if 2 arrays have same shape and dtype.
  auto has_same_shape_and_dtype = [shapeless](
                                      const std::vector<array>& in1,
                                      const std::vector<array>& in2) {
    if (in1.size() != in2.size()) {
      return false;
    }
    for (size_t i = 0; i < in1.size(); ++i) {
      if (in1[i].ndim() != in2[i].ndim()) {
        return false;
      }
      if (!shapeless && in1[i].shape() != in2[i].shape()) {
        return false;
      }
      if (in1[i].dtype() != in2[i].dtype()) {
        return false;
      }
    }
    return true;
  };
  // Loop over entries and check:
  // - Default stream and device match the entry's default stream
  // - Inputs match i.e. shapes and types must be equal.
  auto stream = default_stream(default_device());
  for (CacheEntry& entry : entries) {
    // Check that the default stream and device match
    if (entry.stream != stream) {
      continue;
    }
    if (entry.shapeless != shapeless) {
      continue;
    }

    // Check the inputs match and return if so
    if (has_same_shape_and_dtype(inputs, entry.inputs) &&
        constants == entry.constants) {
      return entry;
    }
  }
  // Otherwise append a new cache entry
  entries.push_back(CacheEntry{stream, shapeless});
  return entries.back();
}
```

> ✅ **VERIFIED** — `mlx/compile.cpp`, `class CompilerCache`, read from source this session.

So the complete cache key is:

| Component | Recompiles when it changes? | In the docs? |
|---|---|---|
| `fun_id` (the function identity — §8.3) | yes | implied |
| **default stream / default device at call time** | **yes** | ❌ **no** |
| `shapeless` flag | yes | implied |
| number of inputs | yes | ✅ |
| per-input `ndim` | yes, **even under `shapeless`** | ✅ (as "number of dimensions") |
| per-input `shape` | yes, **unless `shapeless`** | ✅ |
| per-input `dtype` | yes, **even under `shapeless`** | ✅ |
| `constants` vector (§8.4) | yes | ❌ **no** |

Two of those eight are undocumented, and both of them cause real bugs.

**The default-stream trigger.** Look at the comment in the source: *"Check that the default stream
and device match."* If you call a compiled function inside `with mx.stream(mx.cpu):` and then again
outside it, you get **two cache entries and two compilations**, even with identical inputs. The same
applies to any code path that calls `mx.set_default_device` or `mx.set_default_stream` between
invocations — including, on a threaded server, calling the compiled function from a thread whose
default stream differs (§10.4).

> 🔴 **GAP:** we verified the *keying* but did not measure the cost of the extra entry, and we did not
> find this documented anywhere on the docs site or in an issue thread. **Safe default: pick your
> stream/device once, at process start, and do not change the default around compiled functions.** If
> you need a specific stream for a compiled function, pass `stream=` on the ops inside it rather than
> switching the global default around the call.

### 8.3 What `fun_id` actually is

> ✅ **VERIFIED** — `python/src/transforms.cpp`, `PyCompiledFun`'s constructor, read from source:
>
> ```cpp
> PyCompiledFun(
>     const nb::callable& fun,
>     nb::object inputs,
>     nb::object outputs,
>     bool shapeless)
>     : fun(fun),
>       fun_id(reinterpret_cast<std::uintptr_t>(fun.ptr())),
>       ...
> ```

`fun_id` is **the address of the Python callable object**. That single line answers a question the
docs leave open and explains two behaviours:

**It explains why this hits the cache:**

```python
compiled_fun = mx.compile(fun)

# Compiled here
compiled_fun(x, y)

# Not compiled again
compiled_fun(x, y)

# Not compiled again
mx.compile(fun)(x, y)
```

> ✅ **VERIFIED** — `usage/compile.html`, verbatim including the comments. The third line calls
> `mx.compile` afresh, yet does not recompile, because `fun` is the same Python object and therefore
> the same `fun_id`.

**And it explains why this does not:**

```python
a = mx.array(1.0)
# Don't do this, compiles lambda at each iteration
for _ in range(5):
    mx.compile(lambda x: mx.exp(mx.abs(x)))(a)
```

> ✅ **VERIFIED** — `usage/compile.html`, verbatim including Apple's comment. Each iteration
> constructs a **new lambda object** at a new address, so `fun_id` differs, so the cache misses every
> time. You pay full compilation five times and gain nothing.

There is also lifetime management worth knowing about: `PyCompiledFun`'s destructor calls
`mx::detail::compile_erase(fun_id)`, so when the compiled callable is garbage-collected its cache
entries are dropped. That is why holding the compiled function in a module-level variable (rather
than recreating it) is both faster *and* bounded.

### 8.4 ⚠️ SILENT FAILURE: Python scalars are baked into the cache key

Here is the mechanism that makes `mx.compile` "slower than eager" and looks like nothing at all.

> ⚠️ **SILENT FAILURE — a varying `int` argument silently recompiles on every call, and it presents
> as "compile made my code slower."**
>
> ✅ **VERIFIED** — `python/src/transforms.cpp`, `PyCompiledFun::call_impl`, read from source. The
> argument recursion classifies each leaf:
>
> ```cpp
> } else if (nb::isinstance<mx::array>(obj)) {
>   inputs.push_back(nb::cast<mx::array>(obj));
>   constants.push_back(array_identifier);
> } else if (nb::isinstance<nb::str>(obj)) {
>   auto r = obj.attr("__hash__")();
>   constants.push_back(nb::cast<int64_t>(r));
> } else if (nb::isinstance<nb::int_>(obj)) {
>   constants.push_back(nb::cast<int64_t>(obj));
> } else if (nb::isinstance<nb::float_>(obj)) {
>   auto r = nb::cast<double>(obj);
>   constants.push_back(*reinterpret_cast<uint64_t*>(&r));
> } else if (obj.is_none()) {
>   constants.push_back(none_identifier);
> }
> ```
>
> An `mx.array` contributes a *placeholder marker* to `constants` and its data to `inputs`. An `int`,
> `float`, `str` or `None` contributes **its value** to `constants`. And `constants == entry.constants`
> is part of the cache lookup (§8.2).
>
> Therefore:
>
> ```python
> # ⚠️ WRONG — `position` is a Python int. Every step is a NEW cache entry.
> @mx.compile
> def decode_step(x, cache_k, cache_v, position: int):
>     ...
>
> for position in range(1000):
>     out = decode_step(x, k, v, position)     # 1000 compilations
> ```
>
> ```python
> # ✅ CORRECT — pass it as a 0-d array so it lands in `inputs`, not `constants`.
> @mx.compile
> def decode_step(x, cache_k, cache_v, position):
>     ...
>
> for i in range(1000):
>     out = decode_step(x, k, v, mx.array(i, dtype=mx.int32))
> ```
>
> 🟡 **RECONSTRUCTED** — the two snippets are illustrative and ours; the *mechanism* they illustrate
> is ✅ verified from the source above. The correct form assumes your function can consume a 0-d
> array where it previously used a Python `int`, which for indexing means using `mx.slice` /
> `mx.slice_update` (which take array start indices) rather than Python slicing.
>
> **Why it presents as "compile is slower."** Compilation is not free — Apple says so: *"The first
> time you call a compiled function, MLX will build the compute graph, optimize it, and generate and
> compile code. This can be relatively slow."* If you recompile every iteration you pay that cost
> every iteration *plus* the fused kernel's execution. The uncompiled version pays only execution.
> Net: compiled is slower, monotonically, with no error and no log line.
>
> **The second symptom is worse: unbounded memory growth.** *Community-measured*, mlx#3849 (closed
> 2026-08-05; open at
> research time), which is the best-documented account of this failure:
>
> > "compiled training with a fixed shape plateaus; compiled training with new sequence shapes grows
> > when each new shape is introduced; ... the same variable-shape schedule in eager mode remains
> > flat; calling `mx.clear_cache()` after every step does not stop the growth."
> >
> > "`mx.compile` keeps a cache entry per distinct input signature (shape + dtype + constants), and
> > it's **unbounded** ... `mx.clear_cache()` only drains the allocator's *recycle pool*; it never
> > frees a buffer that's still live."
>
> The failure that eventually surfaces is
> `RuntimeError: [metal::malloc] Resource limit (499000) exceeded` — a *count* of live Metal buffers,
> which no byte-budget knob (`set_memory_limit`, `set_cache_limit`, `set_wired_limit`) affects.
>
> **Closure context (checked 2026-08-23):** mlx#3849 closed with the limit deliberately kept. The
> maintainer: *"The code reading resource limit is bugged and we should probably fix it or just
> remove it"*, but exceeding it *"clearly indicates some fatal mistakes"* — *"So at the moment I
> think it is fine keep it be."* No setter and no fix landed; treat hitting the ceiling as a signal
> of variant accumulation (this section), not as a knob to raise.
>
> **How to detect it before it costs you a night.** MLX exposes no compile-cache statistics from
> Python, so instrument the caller:
>
> ```python
> import mlx.core as mx
>
> class CompileWatch:
>     """Warn when a compiled function is called with a new (shape, dtype, constants) signature.
>
>     MLX has no public compile-cache introspection, so this reconstructs the key
>     from the same rules the C++ cache uses.
>     """
>     def __init__(self, name: str, warn_after: int = 4):
>         self.name = name
>         self.warn_after = warn_after
>         self.seen: set = set()
>
>     def _leaf(self, obj):
>         if isinstance(obj, mx.array):
>             return ("array", tuple(obj.shape), str(obj.dtype))
>         if isinstance(obj, (int, float, str, bool)) or obj is None:
>             return ("const", repr(obj))            # <- this is the dangerous class
>         if isinstance(obj, (list, tuple)):
>             return ("seq", tuple(self._leaf(o) for o in obj))
>         if isinstance(obj, dict):
>             return ("map", tuple((k, self._leaf(v)) for k, v in sorted(obj.items())))
>         return ("other", type(obj).__name__)
>
>     def __call__(self, *args, **kwargs):
>         key = (
>             tuple(self._leaf(a) for a in args),
>             tuple((k, self._leaf(v)) for k, v in sorted(kwargs.items())),
>             str(mx.default_device()),              # <- the undocumented trigger, sec. 8.2
>         )
>         if key not in self.seen:
>             self.seen.add(key)
>             if len(self.seen) > self.warn_after:
>                 print(
>                     f"[CompileWatch] {self.name}: {len(self.seen)} distinct signatures "
>                     f"seen. New: {key}"
>                 )
>         return key
>
> watch = CompileWatch("decode_step")
>
> for i in range(1000):
>     watch(x, k, v, i)          # call BEFORE the compiled function
>     out = decode_step(x, k, v, i)
> ```
>
> 🟡 **RECONSTRUCTED** — the watcher is ours. It reimplements the key-construction rules that are
> ✅ verified in §8.2 and §8.4 above; it is an approximation, not a hook into the real cache (there
> is none). It will catch the two cases that matter — varying scalars and varying shapes — which is
> the point.

### 8.5 There is no public way to clear the compile cache

> ✅ **VERIFIED** — `mlx/compile.cpp` contains `detail::compile_erase(fun_id)` and
> `detail::compile_clear_cache()` (which calls `detail::compiler_cache().clear()`), plus
> `detail::compile_cache_empty()`. These are in the `detail` namespace.
>
> ✅ **VERIFIED (Python side)** — `python/src/transforms.cpp` calls
> `ensure_compile_cache_cleanup()` at the top of every compiled call, and `PyCompiledFun`'s
> destructor calls `compile_erase(fun_id)`.
>
> *Community* corroboration, mlx#3849: *"There is an internal `detail::compile_clear_cache` (wired to
> interpreter exit) but **no public 'clear the compile cache' API**; `disable_compile()` turns
> compilation off rather than reclaiming."*

**Safe defaults, in priority order:**

1. **Keep the signature space small.** Bucket your sequence lengths (pad to multiples of 256, as
   `mlx-lm`'s KV cache does). Never pass a monotonically increasing `int`.
2. **Use `shapeless=True`** when shapes genuinely vary (§9) — mlx#3849's own recommended fix.
3. **Drop the reference.** The compiled callable's destructor erases its entries, so
   `del compiled_step` and rebuilding is the only reclamation you have. Ugly, but it works.
4. **Monitor `mx.get_active_memory() + mx.get_cache_memory()`** and
   `mx.device_info()["resource_limit"]`, not `get_peak_memory()` (§1.5).


---

## 9. Shapeless compilation and its constraints

### 9.1 What it does

```python
def fun(x, y):
    return mx.abs(x + y)

compiled_fun = mx.compile(fun, shapeless=True)

x = mx.array(1.0)
y = mx.array(-2.0)

# Firt call compiles the function
print(compiled_fun(x, y))

# Second call with different shapes
# does not recompile the function
x = mx.array([1.0, -6.0])
y = mx.array([-2.0, 3.0])
print(compiled_fun(x, y))
```

> ✅ **VERIFIED** — `usage/compile.html`, verbatim (including the typo "Firt"). Preamble: *"When the
> shape of an input to a compiled function changes, the function is recompiled. You can compile a
> function once and run it on inputs with variable shapes by specifying `shapeless=True` to
> `compile()`. In this case changes to the shapes of the inputs do not cause the function to be
> recompiled."*

### 9.2 What it does *not* exempt you from

This is the part that surprises people, and we can be exact about it because we read the comparison
code (§8.2).

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.compile.html`, verbatim: *"`shapeless` (*bool,
> optional*) – A function compiled with the `shapeless` option enabled will not be recompiled when
> the input shape changes. **Not all functions can be compiled with `shapeless` enabled. Attempting
> to compile such functions with shapeless enabled will throw.** Note, **changing the number of
> dimensions or type of any input will result in a recompilation even with `shapeless` set to
> `True`.** Default: `False`"*
>
> Corroborated by the source: in `has_same_shape_and_dtype`, the `ndim` and `dtype` checks are
> unconditional and only the `shape` check is guarded by `if (!shapeless)`.

| Changes | Recompiles with `shapeless=False`? | With `shapeless=True`? |
|---|---|---|
| shape, same ndim (`[4]` → `[8]`) | yes | **no** |
| ndim (`[4]` → `[2, 4]`) | yes | **yes** |
| dtype (`float32` → `bfloat16`) | yes | **yes** |
| number of arguments | yes | **yes** |
| a Python `int`/`float`/`str`/`None` argument's value | yes | **yes** |
| default device or stream | yes | **yes** |

So `shapeless=True` buys you exactly one of six axes. It is the *most valuable* one for LLM serving
(variable sequence length at fixed rank and dtype), which is why it is mlx#3849's recommended fix,
but it is not a blanket exemption.

⚠️ And note the last two rows. *Community*, mlx#3849 again: *"shapeless gives up shape
specialization, and **constants varying across calls still make distinct entries**."* Turning on
`shapeless` does not save you from §8.4.

### 9.3 ⚠️ SILENT FAILURE: shape-derived arithmetic bakes in the first shape

> ⚠️ **SILENT FAILURE — under `shapeless=True`, any Python arithmetic on `x.shape` is evaluated once
> at trace time and frozen.**
>
> ✅ **VERIFIED** — `usage/compile.html`, verbatim: *"Use shapeless compilations carefully. Since
> compilation is not triggered when shapes change, **any graphs which are conditional on the input
> shapes will not work as expected.** Shape-dependent computations are common and sometimes subtle to
> detect. For example:"*
>
> ```python
> def fun(x):
>     return x.reshape(x.shape[0] * x.shape[1], -1)
>
> compiled_fun = mx.compile(fun, shapeless=True)
>
> x = mx.random.uniform(shape=(2, 3, 4))
>
> out = compiled_fun(x)
>
> x = mx.random.uniform(shape=(5, 5, 3))
>
> # Error, can't reshape (5, 5, 3) to (6, -1)
> out = compiled_fun(x)
> ```
>
> *"The second call to the `compiled_fun` fails because of the call to `reshape()` which uses the
> static shape of `x` in the first call. We can fix this by using `flatten()` to avoid hardcoding the
> shape of `x`."*
>
> ```python
> def fun(x):
>     return x.flatten(0, 1)
>
> compiled_fun = mx.compile(fun, shapeless=True)
>
> x = mx.random.uniform(shape=(2, 3, 4))
>
> out = compiled_fun(x)
>
> x = mx.random.uniform(shape=(5, 5, 3))
>
> # Ok
> out = compiled_fun(x)
> ```
>
> **This particular case is loud** — the reshape is impossible and it raises. Be grateful. The
> dangerous cousin is the case where the frozen shape happens to remain *valid*:
>
> ```python
> # ⚠️ SILENTLY WRONG under shapeless=True.
> def masked_mean(x, mask):
>     # x.shape[1] is baked in at trace time.
>     return mx.sum(x * mask, axis=1) / x.shape[1]
> ```
>
> Trace it at `x.shape == (8, 128, 64)` and every later call divides by `128`, whatever the real
> sequence length is. Call it at length 256 and your means are half what they should be. Nothing
> raises, because `128` is a perfectly good float.
>
> ```python
> # ✅ CORRECT — derive the divisor from an array operation, which lives in the graph.
> def masked_mean(x, mask):
>     return mx.sum(x * mask, axis=1) / mx.sum(mask, axis=1)
> ```
>
> 🟡 **RECONSTRUCTED** — the `masked_mean` pair is ours. The *mechanism* is ✅ verified by Apple's
> `reshape` example above; we constructed a case where the frozen value stays valid, because that is
> the one that hurts.
>
> **The rule:** inside a `shapeless=True` function, treat `x.shape[i]` as a **compile-time constant**.
> Anything you compute from it is frozen. Anything you need to vary must come from an array op.
> Prefer `flatten(start, end)`, `unflatten`, `reshape(..., -1)`, `mx.sum(mask)` and friends over
> Python arithmetic on shape entries.
>
> **How to detect it:** the same two-run equivalence check as §7.1, but with *different shapes* on
> the two runs:
>
> ```python
> import mlx.core as mx
>
> def check_shapeless(fn, arg_sets, *, atol=1e-5):
>     """Compile once with shapeless=True, then compare against eager on varying shapes."""
>     compiled = mx.compile(fn, shapeless=True)
>     for i, args in enumerate(arg_sets):
>         want = fn(*args)
>         got = compiled(*args)
>         mx.eval(want, got)
>         if not mx.allclose(want, got, atol=atol).item():
>             raise AssertionError(
>                 f"shapeless divergence on arg set {i} "
>                 f"(shapes {[tuple(a.shape) for a in args]}): "
>                 f"max|delta| = {mx.max(mx.abs(want - got)).item()}"
>             )
>     print(f"shapeless OK over {len(arg_sets)} shape configurations")
> ```
>
> 🟡 **RECONSTRUCTED** — ours; all APIs used are ✅ verified. **Give it at least three shape sets,
> and make the first one unrepresentative** (e.g. `[1, ...]`), because a bug that freezes shape[0]
> is invisible if every test case shares a shape[0].

### 9.4 When to use it

| Situation | `shapeless` |
|---|---|
| Fixed-shape training loop | **no** — you get better specialisation without it |
| LLM decode (batch 1, one token at a time) | **no** — the shape is already constant |
| LLM prefill with variable prompt length | **yes** — this is the case it exists for |
| Batched inference with ragged batch sizes | **yes** |
| Any function that reshapes using `x.shape` arithmetic | **no**, or fix the function first (§9.3) |
| A function that raises on `shapeless=True` | it is telling you it cannot be shapeless; believe it |

Note that shapeless *export* exists too and works the same way — see §12.4.

---

## 10. Streams and devices

### 10.1 The type vocabulary

There are three stream-ish types in MLX 0.32, and conflating them causes real bugs.

```
Device(type: mlx.core.DeviceType, index: int = 0)     mx.cpu, mx.gpu are Device values
Stream                                                 .device is a read-only attribute
ThreadLocalStream                                      a DISTINCT Python class, not a Stream
```

> ✅ **VERIFIED** — `python/devices_and_streams.html` for the listing, and `python/src/stream.cpp`
> read from source for the details: `nb::class_<mx::Stream>(m, "Stream", ...)` with
> `.def_ro("device", &mx::Stream::device)`, plus `__repr__` and `__eq__`. The C++ definitions are
> `struct Device { enum class DeviceType { cpu, gpu }; DeviceType type; int index; };` and
> `struct Stream { int index; Device device; };` with
> `struct ThreadLocalStream : public Stream {};` (`mlx/device.h`, `mlx/stream.h`).
>
> This closes an open question the docs-site crawl flagged: the `Stream` autosummary page renders the
> content of `mlx.core.stream` (the context manager) instead of the class, so `.device` is not
> discoverable from the docs. It is real; it is read-only.

The full API surface:

```
Device(*args, **kwargs)                 A device to run operations on.
Stream                                  A stream for running operations on a given device.
default_device()                        Get the default device.
set_default_device(device)              Set the default device.
default_stream(device)                  Get the device's default stream.
new_stream(device)                      Make a new stream on the given device.
new_thread_local_stream(device)         Make a new stream that will be unique per thread.
set_default_stream(stream)              Set the default stream.
stream(s)                               Create a context manager to set the default device and stream.
synchronize([stream])                   Synchronize with the given stream.
clear_streams()                         Destroy all streams created in current thread.
device_count(device_type)               Get the number of available devices for the given device type.
device_info([d])                        Get information about a device.
```

> ✅ **VERIFIED** — `python/devices_and_streams.html`, transcribed exactly. The source
> (`python/src/device.cpp`, `python/src/stream.cpp`) additionally exposes `mx.is_available(device)`
> and `mx.new_thread_unsafe_stream(device)`, which are **not** on that index page.

### 10.2 The default, and how to change it

Every operation without an explicit `stream=` runs on `mx.default_stream(mx.default_device())`
(✅ verified, `usage/using_streams.html`, quoted in full at §1.2).

```python
import mlx.core as mx

print(mx.default_device())          # Device(gpu, 0) on Apple silicon
mx.set_default_device(mx.cpu)       # process-wide
print(mx.default_device())          # Device(cpu, 0)
```

> ✅ **VERIFIED** — `python/src/device.cpp`: `m.def("default_device", &mx::default_device, "Get the
> default device.")` and `m.def("set_default_device", &mx::set_default_device, "device"_a, "Set the
> default device.")`.

The scoped form is usually what you want:

```python
with mx.stream(mx.cpu):
    y = expensive_but_serial(x)      # every op inside runs on the CPU
z = y + 1                            # back on the default device
```

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.stream.html`: `stream(s: Stream |
> mlx.core.ThreadLocalStream | Device) -> mlx.core.StreamContext`, *"Create a context manager to set
> the default device and stream."* The implementation is `PyStreamContext` in
> `python/src/stream.cpp`, which raises `"[StreamContext] Invalid argument, please specify a stream
> or device."` if you pass nothing.

⚠️ Cross-reference §8.2: **this context manager changes the `mx.compile` cache key.** Calling a
compiled function inside and outside a `with mx.stream(...)` block compiles it twice. Prefer
per-operation `stream=` inside a compiled function over wrapping the call.

### 10.3 Using streams for concurrency

Two streams on the same device let independent work overlap:

```python
import mlx.core as mx

s1 = mx.new_stream(mx.gpu)
s2 = mx.new_stream(mx.gpu)

a = mx.random.normal((4096, 4096))
b = mx.random.normal((4096, 4096))

# Two independent chains; MLX may overlap them.
p = mx.matmul(a, a, stream=s1)
q = mx.matmul(b, b, stream=s2)

mx.eval(p, q)
```

> ✅ **VERIFIED (API)** — `new_stream(device: Device) -> Stream`, from
> `python/_autosummary/mlx.core.new_stream.html`.
> 🟡 **RECONSTRUCTED (the example)** — the composition is ours; the semantics it relies on
> (independent operations on different streams may run in parallel; MLX inserts cross-stream
> dependencies where they exist) are ✅ verified from `usage/unified_memory.html`, §1.2–1.3.
> 🔴 **GAP:** we did not measure whether two GPU streams actually overlap on Apple silicon, and the
> docs make the "can and likely will be run in parallel" claim only for the CPU/GPU pair, not for two
> GPU streams. **Safe default: the CPU/GPU split (§1.4) is documented and worth trying; multi-stream
> on one GPU is speculative — measure before you build on it.**

### 10.4 ⚠️ Streams are thread-affine

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.new_stream.html`, an explicit **Note**: *"The stream
> can only be used on the thread where it was created on, **using it in any other thread would result
> in errors**."*
>
> ✅ **VERIFIED** — the two escape hatches, from the source and the repo notes:
> - `mx.new_thread_local_stream(device) -> ThreadLocalStream` — *"Make a new stream that will be
>   unique per thread."*
> - `mx.new_thread_unsafe_stream(device)` — bound in `python/src/stream.cpp` but **absent from the
>   docs index page**. Its docstring per the repo notes: *"currently all nodes in a graph must be
>   evaluated in sequence and it is user's responsibility to ensure there is no race condition."*

This is not theoretical. *Community*, mlx#3727 (closed) records a 0.31.1 → 0.31.2 regression:
*"stream created in main thread is unusable from a worker thread — `There is no Stream(gpu, 0) in
current thread` (breaks mlx_lm threaded server)."* The downstream fix was mlx-lm PR #1090, "Thread
local generation stream."

And the cleanup call exists for the same reason:

> ✅ **VERIFIED** — `mx.clear_streams()`: *"Destroy all streams created in current thread."*
> MLX's own test harness (`python/tests/mlx_tests.py`) calls `mx.clear_streams()` before exiting.

**Practical rules for threaded code:**

1. Build arrays and run models on the thread that owns the stream. The broader community gotcha
   list puts it bluntly: *"MLX arrays are thread-affine — build them on the thread that runs the
   model."*
2. If you need a per-thread stream, use `mx.new_thread_local_stream`, not `mx.new_stream`.
3. `mx.random`'s default key sequence is **`static thread_local`** (§7.4), so seeding in the main
   thread does not seed a worker.
4. `mx.eval` releases the GIL (§2.5), so other Python threads *do* make progress during evaluation —
   which is precisely why these races are reachable.

⚠️ There is a cost to per-call stream setup. *Community*, mlx-lm#1435 reports a **uniform +55–77 ms
TTFT regression** on mlx-lm 0.31.3 vs 0.27.1 on an **M3 Ultra**, decode flat within ±1.5%,
independent of model size — with the hypothesis that
`with wired_limit(model, [generation_stream]):` plus `mx.new_thread_local_stream(...)` is now entered
on **every** generation call. Attribution: community-measured, hypothesis not confirmed by a
maintainer. The transferable lesson: **create streams once, not per request.**

### 10.5 `mx.synchronize`

```
synchronize(stream: Stream | mlx.core.ThreadLocalStream | Device | None = None) -> None
```

> ✅ **VERIFIED** — `python/src/stream.cpp`, read from source. The binding:
>
> ```cpp
> "synchronize",
> [](mx::StreamOrDevice s) {
>   if (std::holds_alternative<std::monostate>(s)) {
>     mx::synchronize();
>   } else {
>     mx::synchronize(mx::to_stream(s));
>   }
> },
> "stream"_a = nb::none(),
> ```
>
> Docstring: *"Synchronize with the given stream. If device is provided the default stream for that
> device is used. If `None` then the default stream of the default device is used. Default: `None`."*

**`mx.synchronize()` is not `mx.eval()`.** The distinction matters:

| | What it does | When you need it |
|---|---|---|
| `mx.eval(x)` | **Schedules and completes** the computation of `x` | almost always — this is your tool |
| `mx.synchronize(s)` | **Waits** for already-scheduled work on stream `s` to finish | benchmarking; interop hand-off |

`mx.eval` implies the wait for the arrays you passed it. `mx.synchronize` schedules nothing; it just
blocks until the stream drains. You need it in exactly two situations:

**Benchmarking**, where you must not attribute the GPU's queue depth to the wrong line:

```python
import time, mlx.core as mx

def bench(fn, *args, warmup: int = 10, iters: int = 100) -> float:
    """Milliseconds per iteration. Follows MLX's own benchmark harness shape."""
    for _ in range(warmup):
        mx.eval(fn(*args))
    mx.synchronize()

    tic = time.perf_counter()
    for _ in range(iters):
        mx.eval(fn(*args))
    mx.synchronize()
    toc = time.perf_counter()
    return 1e3 * (toc - tic) / iters
```

> 🟡 **RECONSTRUCTED** — the `mx.synchronize()` calls are ours; the rest of the harness (warm-up
> loop, `mx.eval` inside the timed loop, `perf_counter`, the ms-per-iteration formula) is ✅ verified
> from `benchmarks/python/time_utils.py` in the MLX repo and the `timeit` helper in
> `usage/compile.html`. **Note that MLX's own harness does *not* call `synchronize`** — because
> `mx.eval` already blocks on the arrays it was given. Adding it is belt-and-braces for cases where
> `fn` leaves other work queued.

**Interop hand-off**, where another framework is about to read MLX's memory:

> ✅ **VERIFIED** — `usage/numpy.html`: *"DLPack conversion **does not synchronize pending Metal
> work**; synchronize or evaluate the producing framework before reading the converted array."*
> See §12.5.

### 10.6 Querying the device

```python
import mlx.core as mx

info = mx.device_info()
print(info)
```

> ✅ **VERIFIED** — `device_info(d: Device | None = None) -> dict[str, str | int]`, from
> `python/_autosummary/mlx.core.device_info.html`: *"Get information about a device. Returns a
> dictionary with device properties. Available keys depend on the backend and device type. **Common
> keys include `device_name`, `architecture`, and `total_memory` (or `memory_size`).**"*
>
> ✅ **VERIFIED (extended key set)** — from `mlx/device.h`'s comment, per the repo notes:
> `device_name` (str), `architecture` (str), `total_memory`/`memory_size` (size_t), and **CUDA only**
> `free_memory`, `uuid`, `pci_bus_id`, `compute_capability_major`, `compute_capability_minor`.
> Metal additionally exposes `max_recommended_working_set_size` — referenced by the
> `set_wired_limit` docstring.
>
> 🟡 **RECONSTRUCTED** — `resource_limit` as a key is attested only by mlx#3849
> (*"`mx.device_info()["resource_limit"]` reports the value MLX is actually using"*, community). We
> did not find it in the docs or confirm it in `mlx/device.h`. Treat the key as probable and guard
> with `.get()`.

The `architecture` string is worth understanding because it drives real dispatch decisions. Its
**last character** classifies the chip and the two digits before it are the generation:

| suffix | class | `max_ops_per_buffer` | `max_mb_per_buffer` |
|---|---|---|---|
| `p` | phone | 20 | 40 |
| `g` | base / pro (and iPad/iPhone) | 40 | 40 |
| `s` | Max (and Pro) | 50 | 50 |
| `d` | Ultra | 50 | 50 |
| other | default | 40 | 40 |

> ✅ **VERIFIED (the table)** — `mlx/backend/metal/device.cpp` heuristics, per the repo notes.
> Both columns are overridable with `MLX_MAX_OPS_PER_BUFFER` / `MLX_MAX_MB_PER_BUFFER`, and the
> architecture string itself can be forced with `MLX_METAL_GPU_ARCH`.
>
> ⚠️ **The `g` / `s` mapping is disputed.** The repo-notes table (read from `device.cpp`) labels `g`
> "base / pro" and `s` "max". A community thread (mlx#3885) corrects this in-thread to: `'g'` = base
> chips **and iPads/iPhones**, `'s'` = **Pro and Max**, `'d'` = **Ultra**, citing observed values
> `applegpu_g13s` (M1 Max), `applegpu_g15s` (M3 Max), `applegpu_g16s` (**M4 Max and M4 Pro**),
> `applegpu_g16g` (M4 iPad Pro), `applegpu_g17g` (M5 base), `applegpu_g17s` (M5 Max) — and states
> flatly that the suffix **cannot distinguish Pro from Max**. Both sources are reporting the same
> letter; they disagree about which products land on `s`. **Safe default: use the suffix for
> dispatch-class reasoning only, never to identify a product.**
>
> 🔴 **GAP — `MLX_METAL_GPU_ARCH`.** It appears in mlx#3860 and mlx#3897 as a same-silicon
> kernel-family override (forcing `applegpu_g16s` on an M5 to disable the NAX path). Its documented
> status, valid values, and whether it is supported or debug-only are **unverified**. **Safe default:
> use it for bisection only, never in shipping code.**

The generation number is the gate for the M5-and-later neural-accelerator path:

> ✅ **VERIFIED** — `mlx/backend/metal/device.cpp`, `is_nax_available()`, quoted in the repo notes
> from source:
>
> ```cpp
> if (__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
>   can_use_nax = true;
> }
> auto& d = metal::device(mlx::core::Device::gpu);
> auto arch = d.get_architecture().back();
> auto gen  = d.get_architecture_gen();
> can_use_nax &= gen >= (arch == 'p' ? 18 : 17);
> ```
>
> So NAX needs **macOS/iOS/tvOS/visionOS ≥ 26.2 at runtime** *and* architecture generation **≥ 17**
> (**≥ 18** for phone-class `'p'` GPUs). Separately, the kernels must have been *built*: the CMake
> gate requires Metal 4, macOS SDK ≥ 26.2 and `CMAKE_OSX_DEPLOYMENT_TARGET` ≥ 26.2, otherwise it
> defines `MLX_METAL_NO_NAX` and compiles them out. A source build on an older SDK silently loses
> them — mlx#3821, fixed by PR #3824 which added a configure-time warning.


---

## 11. `nn.Module`: parameters as a tree

### 11.1 A `Module` is a `dict`

This is the fact everything else follows from, and it is not obvious from the docs.

> ✅ **VERIFIED** — `python/mlx/nn/layers/base.py`, read from source: **`class Module(dict)`**.
>
> `__setattr__` routes values of type `mx.array | dict | list | tuple` **into the dict** (and
> therefore into the parameter tree); everything else goes to normal `__dict__` and is popped from
> the dict.

> ✅ **VERIFIED** — `python/nn.html`: *"**A parameter of a module is any public member of type
> `mlx.core.array` (its name should not start with `_`).** It can be arbitrarily nested in other
> `Module` instances or lists and dictionaries."*
>
> The filter is literally `valid_parameter_filter`:
> `isinstance(value, (dict, list, mx.array)) and not key.startswith("_")`.

⚠️ Two consequences that produce confusing bugs:

1. **A NumPy array or a Python float assigned to `self.something` is not a parameter.** It goes to
   `__dict__`, `parameters()` never sees it, `save_weights` never writes it, and `load_weights`
   never restores it. If you meant it to be state, make it an `mx.array`.
2. **A leading underscore excludes it.** `self._buffer = mx.zeros(...)` is invisible to the parameter
   tree by design — which is how you make a genuinely non-parameter buffer, and also how you
   accidentally lose one.

### 11.2 The canonical module

```python
import mlx.core as mx
import mlx.nn as nn

class MLP(nn.Module):
    def __init__(self, in_dims: int, out_dims: int):
        super().__init__()

        self.layers = [
            nn.Linear(in_dims, 128),
            nn.Linear(128, 128),
            nn.Linear(128, out_dims),
        ]

    def __call__(self, x):
        for i, l in enumerate(self.layers):
            x = mx.maximum(x, 0) if i > 0 else x
            x = l(x)
        return x

# The model is created with all its parameters but nothing is initialized
# yet because MLX is lazily evaluated
mlp = MLP(2, 10)

# We can access its parameters by calling mlp.parameters()
params = mlp.parameters()
print(params["layers"][0]["weight"].shape)

# Printing a parameter will cause it to be evaluated and thus initialized
print(params["layers"][0])

# We can also force evaluate all parameters to initialize the model
mx.eval(mlp.parameters())
```

> ✅ **VERIFIED** — `python/nn.html`, verbatim including comments.

Four things to notice:

- **`__call__`, not `forward`.** MLX modules are called directly.
- **A plain Python `list` of layers is a valid container** — no `nn.ModuleList`. The list goes into
  the dict because `__setattr__` accepts `list`.
- **`parameters()` returns a nested dict/list tree**, and the list index becomes a list index in the
  tree, not a string key. `params["layers"][0]["weight"]`.
- **Nothing is initialised.** The comments say it outright. This is §2.2's memory trick in its
  natural habitat.

Introspection is pleasant:

```python
print(mlp)
```
```
MLP(
  (layers.0): Linear(input_dims=2, output_dims=128, bias=True)
  (layers.1): Linear(input_dims=128, output_dims=128, bias=True)
  (layers.2): Linear(input_dims=128, output_dims=10, bias=True)
)
```

```python
from mlx.utils import tree_map
shapes = tree_map(lambda p: p.shape, mlp.parameters())

from mlx.utils import tree_flatten
num_params = sum(v.size for _, v in tree_flatten(mlp.parameters()))
```

> ✅ **VERIFIED** — all three verbatim from `python/nn.html`. `tree_flatten` yields
> `(dotted_path, array)` pairs, so `num_params` is the standard parameter-count idiom.

### 11.3 `parameters()` vs `state` — the distinction that matters

> ✅ **VERIFIED** — `python/mlx/nn/layers/base.py`, read from source:
>
> ```python
> @property
> def state(self):
>     """The module's state dictionary
>
>     The module's state dictionary contains any attribute set on the
>     module including parameters in :meth:`Module.parameters`
>
>     Unlike :meth:`Module.parameters`, the :attr:`Module.state` property is
>     a reference to the module's state. Updates to it will be reflected in
>     the original module.
>     """
>     return self
> ```

`Module.state` **returns the module itself.** That is why `state = [model.state, optimizer.state]`
in §7.4 works: the list holds a live reference, so when `mx.compile`'s `outputs=` machinery writes
updated arrays back into it, the model is updated.

| | Returns | Aliasing |
|---|---|---|
| `model.parameters()` | a **new** nested dict/list tree of the arrays | a snapshot of the structure |
| `model.trainable_parameters()` | same, excluding frozen entries | snapshot |
| `model.state` | **the module** (a dict subclass) | live reference; includes non-parameter attributes |

Use `parameters()` when you want a tree to map over or serialise. Use `state` when you want something
`mx.compile` or `mx.eval` can write through.

🔴 **GAP:** the docstring says `state` contains *"any attribute set on the module"* — which, given
`__setattr__`'s routing, means every `array`/`dict`/`list`/`tuple` attribute including frozen
parameters and any non-parameter arrays you stored. We did **not** verify whether `state` includes
child-module objects themselves (it must, since they are dict values), nor exactly what
`mx.eval(model.state)` traverses versus `mx.eval(model.parameters())`. **Safe default: evaluate
`model.parameters()` when you mean parameters, and capture `model.state` when you mean "the thing
`compile` should write through."** They are the two idioms Apple's own code uses.

### 11.4 The update model, and how it differs from PyTorch

This is the section to read if you are porting.

In PyTorch, parameters are mutable tensors with a `.grad` slot; `loss.backward()` accumulates into
that slot in place; `optimizer.step()` mutates the parameters in place; `optimizer.zero_grad()`
clears the slots. State lives *on the tensors*.

In MLX, parameters are ordinary immutable arrays in a tree, gradients are a **separate tree of the
same shape** returned by a function, and updating means *replacing* entries in the tree.

> ✅ **VERIFIED** — `python/nn.html` shows the manual pattern explicitly:
>
> ```python
> model = ...
>
> def f(params, other_inputs):
>     model.update(params)  # <---- Necessary to make the model use the passed parameters
>     return model(other_inputs)
>
> f(model.trainable_parameters(), mx.zeros((10,)))
> ```

That `model.update(params)` line is the whole difference. `mx.value_and_grad` differentiates with
respect to **argument 0**, so to get gradients with respect to a model you must (a) pass the
parameters as argument 0, and (b) install them into the model before the forward pass. `update`
is what installs them.

> ✅ **VERIFIED** — `python/mlx/nn/layers/base.py`, read from source:
>
> ```python
> def update(self, parameters: dict, strict: bool = True) -> Module:
> ```
>
> Docstring: *"Replace the parameters of this Module with the provided ones in the dict of dicts and
> lists. **Commonly used by the optimizer to change the model to the updated (optimized) parameters.
> Also used by the `mlx.nn.value_and_grad` to set the tracers in the model in order to compute
> gradients.** The passed in parameters dictionary need not be a full dictionary similar to
> `parameters`. Only the provided locations will be updated. `strict` (bool): If `True` checks that
> `parameters` is a subset of the module's parameters. Default: `True`."*

Note "**set the tracers**": during a `value_and_grad` trace, `update` installs *tracer* arrays into
the model, which is how gradients flow through `model(x)` at all.

`nn.value_and_grad` packages this pattern, and reading its nine lines is the fastest way to
internalise the model:

```python
def value_and_grad(model: Module, fn: Callable):
    def inner_fn(params, *args, **kwargs):
        model.update(params)
        return fn(*args, **kwargs)

    value_grad_fn = mx.value_and_grad(inner_fn)

    @wraps(fn)
    def wrapped_value_grad_fn(*args, **kwargs):
        value, grad = value_grad_fn(model.trainable_parameters(), *args, **kwargs)
        return value, grad

    return wrapped_value_grad_fn
```

> ✅ **VERIFIED** — `python/mlx/nn/utils.py`, read from source, verbatim (docstring elided).
>
> The docs describe the same three steps: *"it wraps the passed function with a function that calls
> `Module.update()` to make sure the model is using the provided parameters; it calls
> `mlx.core.value_and_grad()` to transform the function into a function that also computes the
> gradients with respect to the passed parameters; it wraps the returned function with a function
> that passes the trainable parameters as the first argument."* (`python/nn.html`.)

Note it differentiates `model.trainable_parameters()`, not `model.parameters()` — **frozen
parameters get no gradient**, which is how `nn.QuantizedLinear` (frozen in its `__init__`) stays out
of the backward pass.

Side by side:

```python
# ---- PyTorch ------------------------------------------------------------
# for x, y in loader:
#     optimizer.zero_grad()
#     loss = loss_fn(model(x), y)
#     loss.backward()             # mutates p.grad for every parameter
#     optimizer.step()            # mutates p in place

# ---- MLX ----------------------------------------------------------------
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim

model = MLP(2, 10)
optimizer = optim.AdamW(learning_rate=1e-3)

def loss_fn(model, x, y):
    return nn.losses.cross_entropy(model(x), y, reduction="mean")

loss_and_grad_fn = nn.value_and_grad(model, loss_fn)

for x, y in loader:
    loss, grads = loss_and_grad_fn(model, x, y)   # grads is a TREE, shaped like the params
    optimizer.update(model, grads)                # replaces entries in the tree
    mx.eval(model.parameters(), optimizer.state)  # the one forcing point (sec. 3.2)
```

> 🟡 **RECONSTRUCTED** — the loop is assembled from ✅ verified pieces: the `nn.value_and_grad(model,
> loss_fn)` → `optimizer.update(model, grads)` → `mx.eval(model.parameters(), optimizer.state)`
> sequence is verbatim from `python/optimizers.html`; `optim.AdamW(learning_rate=...)` and
> `nn.losses.cross_entropy(logits, targets, ...)` are ✅ verified names and first parameters from
> `python/optimizers/common_optimizers.html` and `python/nn/losses.html`.
> ⚠️ `reduction="mean"` is 🟡 — the losses index lists `cross_entropy(logits, targets[, weights, ...])`
> and the source has a `_reduce(loss, reduction="none")` helper, so `reduction` exists and defaults to
> `"none"`; we did not verify the accepted literal strings. **Safe default: omit `reduction` and take
> the mean yourself.**

### 11.5 The rest of the `Module` surface

> ✅ **VERIFIED** — complete list from `python/nn/module.html`'s toctree, cross-checked against
> `python/mlx/nn/layers/base.py`:

| Method | Notes |
|---|---|
| `parameters()` | recursive tree of all arrays |
| `trainable_parameters()` | excludes frozen |
| `children()` | direct descendants |
| `leaf_modules()` | submodules with no submodules |
| `modules()`, `named_modules()` | flat iteration; paths like `"model.layers.0.linear"` |
| `filter_and_map(filter_fn, map_fn=None, is_leaf_fn=None)` | the primitive behind all of the above |
| `update(parameters, strict=True)` | partial trees allowed |
| `update_modules(modules, strict=True)` | swap submodules programmatically |
| `apply(map_fn, filter_fn=None)` | map over parameters and install the result |
| `apply_to_modules(apply_fn)` | `apply_fn(path, module)` |
| `freeze(*, recurse=True, keys=None, strict=False)` | idempotent |
| `unfreeze(*, recurse=True, keys=None, strict=False)` | |
| `train(mode=True)`, `eval()` | sets `_training` recursively |
| `set_dtype(dtype, predicate=...)` | see below |
| `load_weights(file_or_weights, strict=True)` | `.npz` / `.safetensors` / list of pairs |
| `save_weights(file)` | `.npz` → `mx.savez`; `.safetensors` → `mx.save_safetensors`; else `ValueError` |
| `training` (property), `state` (property) | |

`apply` is the one you will reach for most:

> ✅ **VERIFIED** — `python/mlx/nn/layers/base.py`, read from source:
>
> ```python
> def apply(
>     self,
>     map_fn: Callable[[mx.array], mx.array],
>     filter_fn: Optional[Callable[[Module, str, Any], bool]] = None,
> ) -> Module:
> ```
>
> Docstring: *"Map all the parameters using the provided `map_fn` and immediately update the module
> with the mapped parameters. For instance running `model.apply(lambda x: x.astype(mx.float16))`
> casts all parameters to 16 bit floats."*
>
> The implementation is two lines, and they show the whole design:
> ```python
> filter_fn = filter_fn or Module.valid_parameter_filter
> self.update(self.filter_and_map(filter_fn, map_fn))
> return self
> ```

So `apply` is `filter_and_map` composed with `update`. Everything in the module system is that
composition.

`set_dtype` is `apply` with a guard you want:

> ✅ **VERIFIED** — `python/nn/_autosummary/mlx.nn.Module.set_dtype.html`:
> `Module.set_dtype(dtype, predicate=<function Module.<lambda>>)`, where *"`predicate` – A predicate
> to select parameters to cast. **By default, only parameters of type `floating` will be updated to
> avoid casting integer parameters to the new dtype.**"* Source confirms the default is
> `lambda x: mx.issubdtype(x, mx.floating)`.

⚠️ Use `set_dtype`, not `apply(lambda x: x.astype(mx.bfloat16))`. The bare `apply` will happily cast
your integer parameters — embedding indices, quantised weights packed in `uint32` — to bfloat16 and
destroy them. `set_dtype`'s default predicate exists precisely to prevent that.

Freezing has a nice idiom:

```python
model = nn.Transformer()
model.freeze()
model.apply_to_modules(lambda k, v: v.unfreeze() if k.endswith("attention") else None)
```

> ✅ **VERIFIED** — from the `Module.freeze` docstring, per the repo notes reading
> `python/mlx/nn/layers/base.py`. `freeze` is idempotent, takes `keys=` for selective freezing
> (`module.freeze(keys="bias")`), and `strict=` to error on unknown keys.

### 11.6 Loading weights

```python
import mlx.core as mx
import mlx.nn as nn

model = nn.Linear(10, 10)

# Load from file
model.load_weights("weights.npz")

# Load from .safetensors file
model.load_weights("weights.safetensors")

# Load from list
weights = [
    ("weight", mx.random.uniform(shape=(10, 10))),
    ("bias",  mx.zeros((10,))),
]
model.load_weights(weights)

# Missing weight
weights = [
    ("weight", mx.random.uniform(shape=(10, 10))),
]

# Raises a ValueError exception
model.load_weights(weights)

# Ok, only updates the weight but not the bias
model.load_weights(weights, strict=False)
```

> ✅ **VERIFIED** — `python/nn/_autosummary/mlx.nn.Module.load_weights.html`, verbatim.
> Signature: `load_weights(file_or_weights: str | List[Tuple[str, array]], strict: bool = True) -> Module`.
> *"`strict` – **If `True` then checks that the provided weights exactly match the parameters of the
> model. Otherwise, only the weights actually contained in the model are loaded and shapes are not
> checked.** Default: `True`."*

⚠️ **Read that `strict=False` clause twice: "shapes are not checked."** `strict=False` is not a
lenient-but-safe mode; it silently accepts a weight of the wrong shape. If you are loading a
checkpoint whose key names differ, rename the keys and keep `strict=True` rather than reaching for
`strict=False`. The error messages under `strict=True` are informative — per the repo notes reading
source, they are `"Received {n} parameters not in model: \n{...}"`, `"Missing {n} parameters:
\n{...}"`, and `"Expected shape {v.shape} but received shape {v_new.shape} for parameter {k}"`.

### 11.7 Optimizers

> ✅ **VERIFIED** — `python/optimizers/optimizer.html` and `python/mlx/optimizers/optimizers.py`:
>
> ```
> Optimizer.state                                    The optimizer's state dictionary.
> Optimizer.apply_gradients(gradients, parameters)   Apply the gradients to the parameters and
>                                                    return the updated parameters.
> Optimizer.init(parameters)                         Initialize the optimizer's state
> Optimizer.update(model, gradients)                 Apply the gradients to the parameters of the
>                                                    model and update the model with the new parameters.
> ```
>
> Available: `SGD, RMSprop, Adagrad, Adafactor, AdaDelta, Adam, AdamW, Adamax, Lion, MultiOptimizer,
> Muon`. Plus `clip_grad_norm(grads, max_norm)`, which returns **`(possibly_rescaled_grads,
> original_norm)`** — a tuple, not just the gradients.

Two behaviours worth flagging now (the training guide covers them properly):

- **`AdamW(..., bias_correction: bool = False)`.** ✅ Verified from the class signature on
  `python/optimizers/_autosummary/mlx.optimizers.AdamW.html`. **The default is `False`**, which
  differs from PyTorch's AdamW. If you are reproducing a PyTorch training run, set it to `True`.
- **Optimizer serialisation is partial.** ✅ Verified, `python/optimizers.html`: *"not every optimizer
  configuration parameter is saved in the state. For example, for Adam the learning rate is saved but
  the `betas` and `eps` parameters are not. A good rule of thumb is if the parameter can be scheduled
  then it will be included in the optimizer state."* So a resumed run must reconstruct the optimizer
  with the same hyperparameters and only then assign `optimizer.state`.

```python
import mlx.core as mx
from mlx.utils import tree_flatten, tree_unflatten
import mlx.optimizers as optim

optimizer = optim.Adam(learning_rate=1e-2)

# Perform some updates with the optimizer
model = {"w" : mx.zeros((5, 5))}
grads = {"w" : mx.ones((5, 5))}
optimizer.update(model, grads)

# Save the state
state = tree_flatten(optimizer.state, destination={})
mx.save_safetensors("optimizer.safetensors", state)

# Later on, for example when loading from a checkpoint,
# recreate the optimizer and load the state
optimizer = optim.Adam(learning_rate=1e-2)

state = tree_unflatten(mx.load("optimizer.safetensors"))
optimizer.state = state
```

> ✅ **VERIFIED** — `python/optimizers.html`, verbatim. Note `tree_flatten(..., destination={})`,
> which yields a flat **dict** (`{"a.b": value}`) instead of a list of pairs — required because
> `save_safetensors` takes a `dict[str, array]`.


---

## 12. Saving, loading, exporting, and interop

### 12.1 The four array formats

> ✅ **VERIFIED** — `usage/saving_and_loading.html`, table transcribed exactly:

| Format | Extension | Function | Notes |
|---|---|---|---|
| NumPy | `.npy` | `save()` | Single arrays only |
| NumPy archive | `.npz` | `savez()` and `savez_compressed()` | Multiple arrays |
| Safetensors | `.safetensors` | `save_safetensors()` | Multiple arrays |
| GGUF | `.gguf` | `save_gguf()` | Multiple arrays |

> ✅ **VERIFIED** — *"The `load()` function will load any of the supported serialization formats. It
> determines the format from the extensions. The output of `load()` depends on the format."*

```
load(file: file | str | Path, /, format: str | None = None, return_metadata: bool = False, *,
     stream: None | Stream | Device = None)
     -> array | dict[str, array] | Tuple[dict[str, array], dict[str, Any]]

save_safetensors(file: file | str | Path, arrays: dict[str, array],
                 metadata: dict[str, str] | None = None)
```

> ✅ **VERIFIED** — `python/_autosummary/mlx.core.load.html` and
> `python/_autosummary/mlx.core.save_safetensors.html`.
>
> ⚠️ Two things from `load`'s own documentation. First, `format` — *"If `None`, the format is inferred
> from the file extension. **Supported formats: `npy`, `npz`, and `safetensors`.**"* — omits `gguf`
> from the explicit `format=` list even though `load` reads `.gguf` by extension. Second, a
> **Warning**: *"When loading unsupported quantization formats from GGUF, tensors will automatically
> cast to `mx.float16`."* That is a silent precision change on load; if you care, check dtypes after
> loading a GGUF.

```python
>>> a = mx.array([1.0])
>>> mx.save("array", a)          # writes array.npy -- extension added automatically
>>> mx.load("array.npy")
array([1], dtype=float32)

>>> a = mx.array([1.0]); b = mx.array([2.0])
>>> mx.savez("arrays", a, b=b)
>>> mx.load("arrays.npz")
{'b': array([2], dtype=float32), 'arr_0': array([1], dtype=float32)}

>>> mx.save_safetensors("arrays", {"a": a, "b": b})
```

> ✅ **VERIFIED** — `usage/saving_and_loading.html`, verbatim. Note `savez`'s positional arrays get
> auto-named `arr_0`, `arr_1`, … — *"For compatibility with `numpy.savez()` the MLX `savez()` takes
> arrays as arguments. **If the keywords are missing, then default names will be provided.**"*
> `save_safetensors` and `save_gguf` take a `dict[str, array]` instead.

**Which to use.** `safetensors` for anything you will share or reload: it is the Hugging Face
lingua franca, it carries a `metadata: dict[str, str]`, and `Module.save_weights`/`load_weights`
speak it natively. `npz` for scratch and for optimizer state (§11.7). `npy` for a single array.
`gguf` only when something downstream requires it, and mind the fp16 cast warning above.

### 12.2 ⚠️ Saving forces evaluation

Repeating §2.3 because it belongs here too: *"Saving arrays via `save()` (or any other MLX saving
functions) will also evaluate the array."* (✅ `usage/lazy_evaluation.html`.) So
`mx.save_safetensors("ckpt.safetensors", tree_flatten(model.parameters(), destination={}))` in the
middle of a training loop is a full synchronisation point, and a large one. Checkpoint at a natural
boundary, not inside the step.

### 12.3 Converting to and from NumPy

```python
import mlx.core as mx
import numpy as np

a = mx.arange(3)
b = np.array(a) # copy of a
c = mx.array(b) # copy of b
```

> ✅ **VERIFIED** — `usage/numpy.html`, verbatim. The mechanisms are the **Python buffer protocol**
> and **DLPack**.

Three rules, all ✅ verified from the same page:

1. **NumPy has no bfloat16.** *"Since NumPy does not support `bfloat16` arrays, you will need to
   convert to `float16` or `float32` first: `np.array(a.astype(mx.float32))`. Otherwise, you will
   receive an error like: `Item size 2 for PEP 3118 buffer format string does not match the dtype V
   item size 0.`"* That error message is unforgettable once you have seen it and incomprehensible the
   first time; now you know.
2. **NumPy `float64` becomes MLX `float32`.** *"NumPy arrays with type `float64` will be default
   converted to MLX arrays with type `float32`."* Silent, and usually what you want, but it means a
   `np.float64` array round-trips lossily.
3. **`copy=False` gives you a view into MLX memory.**
   ```python
   a = mx.arange(3)
   a_view = np.array(a, copy=False)
   print(a_view.flags.owndata)  # False
   a_view[0] = 1
   print(a[0].item())  # 1
   ```
   *"A NumPy array view is a normal NumPy array, except that it does not own its memory. This means
   writing to the view is reflected in the original array."*

That third one leads directly to the next silent failure.

### 12.4 ⚠️ SILENT FAILURE: writing through a NumPy view destroys gradients

> ⚠️ **SILENT FAILURE — external mutations of MLX memory are invisible to autodiff. The gradient is
> wrong; nothing raises.**
>
> ✅ **VERIFIED** — `usage/numpy.html`, verbatim, including Apple's own demonstration:
>
> ```python
> def f(x):
>     x_view = np.array(x, copy=False)
>     x_view[:] *= x_view # modify memory without telling mx
>     return x.sum()
>
> x = mx.array([3.0])
> y, df = mx.value_and_grad(f)(x)
> print("f(x) = x² =", y.item())    # 9.0
> print("f'(x) = 2x !=", df.item()) # 1.0
> ```
>
> Apple's explanation: *"The function `f` indirectly modifies the array `x` through a memory view.
> However, this modification is not reflected in the gradient, as seen in the last line outputting
> `1.0`, representing the gradient of the sum operation alone. The squaring of `x` occurs externally
> to MLX, meaning that no gradient is incorporated."*
>
> The value is right (`9.0`) and the gradient is wrong (`1.0` instead of `6.0`). A training run
> containing this will *converge to something* — just not to the thing you asked for.
>
> ⚠️ **And it is not limited to in-place writes.** Apple continues: *"It's important to note that a
> similar issue arises during array conversion and copying. For instance, a function defined as
> `mx.array(np.array(x)**2).sum()` would also result in an incorrect gradient, even though no in-place
> operations on MLX memory are executed."* Any excursion through NumPy — even a pure, copying one —
> **breaks the graph**. The result is a fresh MLX array with no ancestry, so the gradient stops there.
>
> **The rule: never route a differentiated computation through NumPy.** Not `np.array(x)`, not
> `x.tolist()`, not SciPy, not a Python `math` call on `.item()`. If MLX lacks the op you need,
> write it with `mx.custom_function` (§5) or `mx.fast.metal_kernel` and give it a VJP.
>
> **How to detect it:** the finite-difference check from §5.3, applied to any function you suspect.
> A gradient that comes back as exactly the derivative of the *outer* op — `1.0` for a `sum`, the
> cotangent for an identity — is the signature.

### 12.5 PyTorch interop

This is the most gotcha-dense page in the MLX documentation and it is worth reading closely.

> ✅ **VERIFIED** — `usage/numpy.html`, verbatim:
>
> > PyTorch supports DLPack inputs and can import MLX arrays directly. MLX can also import PyTorch
> > tensors through DLPack with `mx.asarray` or `mx.from_dlpack`. Use `torch.as_tensor` to import an
> > MLX array with DLPack; `torch.tensor` copies the data instead. Similarly, `mx.asarray` can share
> > DLPack inputs when possible, while `mx.array` copies.

```python
import mlx.core as mx
import torch

a = mx.arange(3, dtype=mx.float32)
mx.eval(a)

shared = torch.as_tensor(a)   # zero-copy
copied = torch.tensor(a)      # copy
```

> ✅ **VERIFIED** — verbatim. Note `mx.eval(a)` before the conversion: an unevaluated array has no
> data to share.

The direction matrix:

| From → To | Call | Copies? |
|---|---|---|
| MLX → torch | `torch.as_tensor(mlx_arr)` | **no** (DLPack; no copy on Metal) |
| MLX → torch | `torch.tensor(mlx_arr)` | yes |
| torch CPU → MLX | `mx.array(t)` / `mx.asarray(t)` | **always yes** |
| torch MPS → MLX | `mx.asarray(t)` or `mx.from_dlpack(t, copy=None)` | no, *if the Metal buffer is not private* |
| torch MPS → MLX | `mx.from_dlpack(t, copy=False)` | never — **raises** if a copy would be needed |
| torch MPS → MLX | `mx.from_dlpack(t, copy=True)` / `mx.array(t)` | yes |

> ✅ **VERIFIED** — `usage/numpy.html`:
>
> > **Metal DLPack inputs are different.** If a PyTorch MPS tensor is passed to `mx.asarray` or to
> > `mx.from_dlpack` with `copy=None`, MLX imports it without a copy when the underlying Metal buffer
> > is not private. **Private Metal buffers are copied into MLX-managed storage instead.** Passing
> > `copy=False` requires zero-copy import and **raises an error if a copy would be needed**. Passing
> > `copy=True` asks MLX to create a new array instead of reusing the Metal buffer. Zero-copy imports
> > preserve the DLPack strides. `mx.array` also creates a new array instead of reusing the Metal
> > buffer. MLX arrays exported to PyTorch with DLPack are exported without a copy on Metal.
> >
> > In particular, **PyTorch 2.12 and later use shared storage for ordinary MPS tensors on Apple
> > silicon, while older PyTorch versions may use private storage and require a copy on import.**
> > DLPack conversion **does not synchronize pending Metal work**; synchronize or evaluate the
> > producing framework before reading the converted array.

```python
b = torch.arange(3, device="mps", dtype=torch.float32)
torch.mps.synchronize()
c = mx.asarray(b)                # zero-copy if the Metal buffer can be reused
d = mx.from_dlpack(b, copy=True) # explicit copy


a = mx.arange(3, dtype=mx.float32)
mx.eval(a)
b = torch.as_tensor(a)           # zero-copy DLPack import on Metal
```

> ✅ **VERIFIED** — verbatim.

⚠️ **The synchronisation clause is the dangerous one.** DLPack hands over a pointer; it does not
wait for the producer's queued work. Read an MLX array from PyTorch before `mx.eval`, or a PyTorch
MPS tensor from MLX before `torch.mps.synchronize()`, and you get **whatever was in the buffer**.
Not an error — a plausible-looking array of stale or partial values. The discipline is mechanical:

```python
# MLX -> PyTorch
mx.eval(a)                       # or mx.synchronize()
t = torch.as_tensor(a)

# PyTorch -> MLX
torch.mps.synchronize()
x = mx.asarray(t)
```

JAX and TensorFlow are simpler:

```python
import mlx.core as mx
import jax.numpy as jnp
a = mx.arange(3); b = jnp.array(a); c = mx.array(b)     # JAX: full buffer-protocol support

import tensorflow as tf
a = mx.arange(3); b = tf.constant(memoryview(a)); c = mx.array(b)   # TF needs an explicit memoryview
```

> ✅ **VERIFIED** — both verbatim from `usage/numpy.html`.

### 12.6 `export_function` / `import_function` — the `.mlxfn` format

This is how you run a computation authored in Python from C++ (or from another MLX front-end)
without a Python runtime.

> ✅ **VERIFIED** — `python/src/export.cpp`, read from source, the literal `nb::sig`:
> ```
> def export_function(file_or_callback: Union[str, Callable], fun: Callable, *args,
>                     shapeless: bool = False, **kwargs) -> None
> ```
> and `python/_autosummary/mlx.core.import_function.html`:
> ```
> import_function(file: str) -> Callable
> ```
>
> ⚠️ **Warning block on `export_function`**, verbatim: *"This is part of an experimental API which is
> likely to change in future versions of MLX. **Functions exported with older versions of MLX may not
> be compatible with future versions.**"*

```python
def fun(x, y):
    return x + y

x = mx.array(1.0)
y = mx.array(1.0)
mx.export_function("add.mlxfn", fun, x, y)
```

```python
add_fun = mx.import_function("add.mlxfn")

out, = add_fun(mx.array(1.0), mx.array(2.0))
# Prints: array(3, dtype=float32)
print(out)

# Raises an exception
add_fun(mx.array(1), mx.array(3.0))

# Raises an exception
add_fun(mx.array([1.0, 2.0]), mx.array(3.0))
```

> ✅ **VERIFIED** — `usage/export.html`, verbatim. *"To export a function, provide sample input arrays
> that the function can be called with. **The data doesn't matter, but the shapes and types of the
> arrays do.**"* And: *"even though the original `fun` returns a single output array, **the imported
> function always returns a tuple of one or more arrays.**"*

That trailing comma in `out, = add_fun(...)` is not a typo. **Imported functions always return a
tuple**, even for one output. Forgetting it gives you a tuple where you expected an array, and the
next operation fails somewhere unhelpful.

Keyword arguments are part of the contract:

> ✅ **VERIFIED** — `usage/export.html`: *"**If you use keyword arguments to export the function, then
> you have to use the same keyword arguments when calling the imported function.**"*
>
> ```python
> mx.export_function("add.mlxfn", fun, x, y=y)
> imported_fun = mx.import_function("add.mlxfn")
>
> out, = imported_fun(x, y=y)              # Ok
> out, = imported_fun((x,), {"y": y})      # Also ok
> out, = imported_fun(x, y)                # Raises: keyword argument missing
> out, = imported_fun(x, z=y)              # Raises: wrong key
> ```

### 12.7 ⚠️ Exporting a module: `mx.eval` first, or you export the initialiser

```python
model = nn.Linear(4, 4)
mx.eval(model.parameters())

def call(x):
    return model(x)

mx.export_function("model.mlxfn", call, mx.zeros(4))
```

> ✅ **VERIFIED** — `usage/export.html`, verbatim, including the **Note**: *"For enclosed arrays
> inside an exported function, be extra careful to ensure they are evaluated. **The computation graph
> that gets exported will include the computation that produces enclosed inputs.** If the above
> example was missing `mx.eval(model.parameters())`, the exported function would include the random
> initialization of the `mlx.nn.Module` parameters."*

This is lazy evaluation's sharpest edge in the whole guide. Forget the `mx.eval` and your `.mlxfn`
contains, not weights, but the *`glorot_uniform` initialiser that produces weights*. It will run,
it will produce output, and the output will be from freshly random parameters every time. The file
size may even look plausible. **Always `mx.eval(model.parameters())` before exporting.**

The parameterised form, if you want the weights as inputs rather than baked in:

```python
model = nn.Linear(4, 4)
mx.eval(model.parameters())

def call(x, **params):
    # Set the model's parameters to the input parameters
    model.update(tree_unflatten(list(params.items())))
    return model(x)

params = tree_flatten(model.parameters(), destination={})
mx.export_function("model.mlxfn", call, (mx.zeros(4),), params)
```

> ✅ **VERIFIED** — `usage/export.html`, verbatim. Note it is `model.update(...)` again (§11.4) —
> the same mechanism that makes gradients work makes parameter injection work.

Three more capabilities worth knowing exist:

- **Shapeless export.** `mx.export_function("fun.mlxfn", mx.abs, mx.array([0.0]), shapeless=True)`.
  ✅ Verified; *"Shapeless exporting works the same as shapeless compilation and should be used
  carefully"* — so §9.3's frozen-shape trap applies.
- **Multiple traces in one file**, which dedupes constants (important when the constants are a
  model's weights):
  ```python
  with mx.exporter("fun.mlxfn", fun) as exporter:
      exporter(mx.array(1.0))
      exporter(mx.array(1.0), y=mx.array(0.0))
  ```
  ✅ Verified; signature `exporter(file: str, fun: Callable, *, shapeless: bool = False) ->
  mlx.core.FunctionExporter`. *"In the above example the function constant data […] is only saved
  once."*
- **Callback export**, for inspecting a graph instead of writing a file: pass a callable as the first
  argument and receive dicts with a `type` field in `{"inputs", "keyword_inputs", "outputs",
  "constants", "primitives"}`. ✅ Verified.

Imported functions are still transformable — `mx.grad(lambda x: imported_fun(x)[0])` and
`mx.compile(imported_fun)` both work (✅ verified, `usage/export.html`; note the docs' own snippet
for the compile case has a bug — it never assigns `compiled_fun` — which we mention only so you
don't copy it).

🔴 **GAP — `.mlxfn` forward compatibility.** Apple's warning says exported functions "may not be
compatible with future versions" but gives no versioning scheme, no format version field we could
find, and no migration path. `mlx.core.FunctionExporter`'s own API beyond "context manager and
callable" is undocumented. **Safe default: treat `.mlxfn` as a build artefact, not an archive.
Regenerate it from Python source on every MLX bump, and keep the Python that produced it in version
control.**

[^scope-source]: Source snapshot: [`ml-explore/mlx` at `973e27f`](https://github.com/ml-explore/mlx/tree/973e27f82ffe68dbd626cda31ba34997045d1eb7).
