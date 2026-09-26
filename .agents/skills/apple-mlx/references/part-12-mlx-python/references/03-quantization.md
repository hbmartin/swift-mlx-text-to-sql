# MLX quantization: modes, group sizes, gates, and the corruption bugs

**Part 12 · MLX in Python · Reference 03**

**Version floor.** Everything in this guide was read against **mlx `0.32.1`** (the declared
version in the tree; latest tag in the shallow clone is `v0.32.0`) and **mlx-lm `0.31.3`**, which
pins `mlx >= 0.31.2` on Darwin. macOS wheels require **Apple silicon, native Python ≥ 3.10, and
macOS ≥ 14.0**. That is the floor for *using* quantization at all.

There is a **second, much higher floor** for the fast kernels. MLX's NAX quantized matmuls — the
ones that run on the M5-generation neural accelerators — require **Metal 4, macOS SDK ≥ 26.2, a
deployment target ≥ 26.2**, and at runtime **`__builtin_available(macOS 26.2, iOS 26.2, tvOS 26.2,
visionOS 26.2)` plus GPU architecture generation ≥ 17 (≥ 18 on `'p'` parts)**. Below that line you
get the older Metal kernels, silently. Above it you get more speed and, as of **2026-07-27**, a
cluster of **open correctness bugs that silently corrupt quantized model output**. Both halves of
that sentence are the reason this guide exists.

Nothing here is written from memory. Every API name, flag and number comes from a research note
read this session and carries an evidence marker.

---

## What this covers

Quantization in MLX is not one feature. It is four things wearing the same name, and confusing
them is how people ship broken models:

1. **A numeric format** — affine at 2/3/4/5/6/8 bits, or one of the three block-float modes
   (`mxfp4`, `mxfp8`, `nvfp4`). Choosing one is a size/quality decision.
2. **A memory layout** — packed `uint32` weights plus a separate scales array plus (for affine) a
   separate biases array. Three arrays, not one. Every API in this guide takes all three.
3. **A kernel dispatch problem** — whether your shapes hit the fast path is decided by
   `K % 64 == 0`, by `transpose=True`, and for the gather path by a tile constant of `BK = 64`.
   Miss those and nothing warns you; you just get slower, or on one hardware generation, wrong.
4. **A calibration procedure** — plain round-to-nearest, or one of mlx-lm's four data-aware
   pipelines (AWQ, GPTQ, DWQ, dynamic). This is where the quality actually comes from at 3 bits
   and below.

Read this guide to learn:

- **The verified mode inventory** and what each mode's scale encoding actually is — including the
  fact that `fp8_e8m0`, `fp8_e4m3` and `fp4_e2m1` are **MLX's own C++ structs**, not Metal types,
  and that MLX builds the whole MX/NV story in software on top of plain integer operands.
- **The bits-per-weight arithmetic**, so you can predict a checkpoint's size before you convert it
  and recognise when MLX's reported number disagrees with your expectation (it usually should).
- **The complete API**: `mx.quantize`, `mx.dequantize`, `mx.quantized_matmul`, `mx.gather_qmm`,
  `mx.qqmm`, `nn.quantize`, `nn.QuantizedLinear`, `nn.QuantizedEmbedding`, `nn.QQLinear`.
- **The gates** that decide kernel selection, what happens when you miss them, and why the failure
  is invisible.
- **`gather_qmm`** — the op that makes Mixture-of-Experts decode tractable, why reading only the
  routed experts is worth multiples rather than percentages, and community measurements of exactly
  that.
- **Learned quantization** — what AWQ, GPTQ, DWQ and dynamic quantization each actually do in
  mlx-lm's implementation, their real argparse defaults, their hard limits, and when the extra
  compute pays for itself.
- **⚠️ The corruption bugs.** Four separate defects in quantized matmul paths, with issue numbers
  and precise status as of 2026-07-29. One of them leaves output rows **unwritten**, exposing
  recycled Metal allocator memory — which is sometimes coincidentally plausible, which is why it
  went unnoticed.
- **A verification recipe** you should run before every ship: quantized versus unquantized, one
  fixed prompt, greedy sampling, and a buffer-poisoning trick that turns "sometimes wrong" into
  "always caught".

## What this does *not* cover

- **KV-cache quantization** (`--kv-bits`, `QuantizedKVCache`, `quantized_kv_start`). It shares the
  word "quantization" and almost nothing else: it is an *activation* cache format, its failure
  modes are different, and it deserves its own guide. §11 gives you the four facts you need so you
  don't conflate the two.
- **LoRA / QLoRA / DoRA on quantized bases.** That is the fine-tuning guide in this part.
- **Distributed and sharded quantized layers** (`QuantizedAllToShardedLinear`,
  `QuantizedShardedToAllLinear`). See the distributed guide.
- **Core AI's compression story** (palettization, `.aimodel` numeric formats). Different framework,
  different file format, different tooling —
  [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md).
- **Metal kernel authoring against MetalPerformancePrimitives.**
  [Part 11](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md) covers what TensorOps does and does not give you;
  §2.4 here summarises the one conclusion that changes how you read MLX's quantized kernels.

## What you need

- **`pip install mlx`** on Apple silicon with native Python ≥ 3.10 (check:
  `python -c "import platform; print(platform.processor())"` must print `arm`).
- **`pip install mlx-lm`** for the model-level tooling, and **`pip install "mlx-lm[train]"`** for
  any of the learned-quantization CLIs — they import `datasets` and `tqdm`, which are not in the
  base install.
- A model you can run **unquantized** at least once. The verification recipe in §10 is a
  differential test; without a reference you are guessing.
- If you are on an M5-generation machine (`applegpu_g17*`), read §9 **before** you trust a
  quantized MoE model's output. That is not hyperbole; it is the state of the tree on 2026-07-27.

---

## ⚠️ Read this before you trust a number below

Three sourcing rules apply to everything that follows.

**First: the MLX clone behind these notes is shallow (`--depth 50`).** `git log` on most paths
returns the graft boundary, not real history. No date in this guide should be read as "this is
when the feature landed" unless it is attached to a specific PR number that the notes recorded with
a date. Where I know a date, I give it; where I do not, I say so.

**Second: the NAX quantized path is new and actively churning.** Three correctness fix PRs touching
NAX opened in the **72 hours before 2026-07-27** — PRs **#3912**, **#3922** and **#3924**; on a
2026-08-03 `gh` re-check the first two were still open and #3924 was closed unmerged 2026-08-02
— including a *missing `else`* in `tile_matmad_nax` that silently compiles to nothing for odd tile
shapes and produces garbage. The research note that found it puts it plainly:

> ✅ **VERIFIED** — "There is an **active stream of correctness fixes** as of the last week before
> this investigation (3912, 3922, 3924, all within 72 hours). The NAX path is **new and still
> settling**. A guide should not present it as mature."
> — `notes/repos/mlx-tensorops-kernels.md:2003-2005`

Treat every M5-generation quantized number in this guide as a moving target, and pin your mlx
version in production.

**Third: community measurements are labelled as such, every time.** The MoE throughput numbers in
§7.4 come from a community model zoo, not from Apple. They are unique — nobody else has published
them — and they are not Apple-official. Where a number is community-measured, the hardware and the
source file are named inline.

---

## Contents

1. [The mental model: quantization is three arrays](#1-the-mental-model-quantization-is-three-arrays)
2. [The mode inventory](#2-the-mode-inventory)
3. [Sizing: what bits and group size actually cost](#3-sizing-what-bits-and-group-size-actually-cost)
4. [The array API](#4-the-array-api)
5. [The module API: `nn.quantize` and friends](#5-the-module-api-nnquantize-and-friends)
6. [The gates: what decides whether you get the fast kernel](#6-the-gates-what-decides-whether-you-get-the-fast-kernel)
7. [`gather_qmm`, MoE, and why routed-only reads matter](#7-gather_qmm-moe-and-why-routed-only-reads-matter)
8. [Learned quantization: AWQ, GPTQ, DWQ, dynamic](#8-learned-quantization-awq-gptq-dwq-dynamic)
9. [⚠️ The corruption bugs](#9-️-the-corruption-bugs)
10. [The verification recipe](#10-the-verification-recipe)
11. [KV-cache quantization is a different thing](#11-kv-cache-quantization-is-a-different-thing)
12. [Selection table: what to pick](#12-selection-table-what-to-pick)
13. [Declared gaps](#13-declared-gaps)
14. [Sources](#14-sources)

---

## 1. The mental model: quantization is three arrays

The single most common source of confusion in MLX quantization code is the assumption that a
quantized weight is *a weight*. It is not. `mx.quantize` returns a tuple, and every downstream op
takes the pieces separately.

### 1.1 What `mx.quantize` returns

> ✅ **VERIFIED** — the Python signature, quoted from the `nb::sig` string in `python/src/ops.cpp`
> (recorded at `notes/repos/mlx-core.md:772-774`):
>
> ```python
> def quantize(w: array, /, group_size: Optional[int] = None, bits: Optional[int] = None,
>              mode: str = 'affine', *, global_scale: Optional[array] = None,
>              stream=None) -> tuple[array, array, array]
> ```

Three arrays come back: the **packed weights**, the **scales**, and (for affine) the **biases**.

```python
import mlx.core as mx

w = mx.random.normal(shape=(4096, 4096)).astype(mx.bfloat16)
wq, scales, biases = mx.quantize(w, group_size=64, bits=4, mode="affine")

mx.eval(wq, scales, biases)
print(wq.dtype, wq.shape)          # packed uint32
print(scales.dtype, scales.shape)
print(biases.dtype, biases.shape)
```

The packed layout is documented in the op's own docstring:

> ✅ **VERIFIED** — quoted from the `quantize` docstring
> (`notes/repos/mlx-core.md:765`): "*`w_hat_i` fits in `b` bits and is packed in an unsigned 32-bit
> integer from the lower to upper bits. For instance, for 4-bit quantization we fit 8 elements in
> an unsigned 32 bit integer where the 1st element occupies the 4 least significant bits, the 2nd
> bits 4-7 etc.*"

So the packed array's **last dimension shrinks**. `nn.QuantizedLinear` has to undo that arithmetic
just to print itself:

> ✅ **VERIFIED** — `QuantizedLinear._extra_repr` reconstructs the logical input dimension as
> `(in_dims * 32) // self.bits` (`notes/repos/mlx-core.md:860`).

That one line is worth memorising, because it tells you the invariant: **the stored weight's last
dim is in units of packed `uint32` words, not elements.** Any code that reads `weight.shape[-1]`
on a quantized module and treats it as a feature count is wrong.

### 1.2 The affine formula

> ✅ **VERIFIED** — quoted verbatim from the `quantize` docstring
> (`notes/repos/mlx-core.md:759-764`):
>
> ```
> alpha = max_i w_i ;  beta = min_i w_i ;  s = (alpha - beta) / (2^b - 1)
> w_hat_i = round((w_i - beta) / s)
> dequantize:  w_i = s * w_hat_i + beta
> ```

Read that carefully, because two properties fall out of it and both matter later:

- **It is asymmetric.** There is a per-group `beta` (the bias), so a group whose values are all
  positive wastes no codes on negatives. This is why affine outperforms naive symmetric schemes on
  weight distributions that are not centred.
- **It is min/max, not percentile.** A single outlier in a group stretches `s` for the whole group
  and coarsens every other value in it. That is precisely the failure mode the data-aware methods
  in §8 exist to fix — AWQ by *scaling and clipping* before quantizing, GPTQ by minimising the
  layer's output error rather than the weight's error.

The group is along the **last axis**. Two consequences:

- `mx.quantize` requires at least 2 dimensions, and the last dimension must divide by `group_size`
  (see §2.5 for the exact error strings).
- For a KV cache, grouping along the last axis means grouping along `head_dim` — which is why
  quantizing a cache and then slicing/concatenating along the sequence axis is numerically safe.
  (That observation comes from the mlx-lm rotating-KV thread; see §11.)

### 1.3 `mx.dequantize` — and the round-trip you should actually run

> ✅ **VERIFIED** — `notes/repos/mlx-core.md:776-779`:
>
> ```python
> def dequantize(w: array, /, scales: array, biases: Optional[array] = None,
>                group_size: Optional[int] = None, bits: Optional[int] = None,
>                mode: str = 'affine', global_scale: Optional[array] = None,
>                dtype: Optional[Dtype] = None, *, stream=None) -> array
> ```

Note `dtype`. Its behaviour is documented and it is a trap if you ignore it:

> ✅ **VERIFIED** — "*If `None` the return type is inferred from the scales and biases when
> possible and otherwise defaults to `bfloat16`.*" (`notes/repos/mlx-core.md:825`)

So a `dequantize` on a mode with no biases and an 8-bit scale encoding can hand you `bfloat16` when
you expected `float32`. Pass `dtype=` explicitly in any test harness.

The single most useful diagnostic in this entire guide is four lines long:

```python
import mlx.core as mx

def roundtrip_error(w, *, group_size=64, bits=4, mode="affine"):
    """Max absolute and relative error of a quantize -> dequantize round trip."""
    q = mx.quantize(w, group_size=group_size, bits=bits, mode=mode)
    wq, scales = q[0], q[1]
    biases = q[2] if len(q) > 2 else None
    w2 = mx.dequantize(
        wq, scales, biases,
        group_size=group_size, bits=bits, mode=mode, dtype=w.dtype,
    )
    err = mx.abs(w2 - w)
    denom = mx.maximum(mx.abs(w), mx.array(1e-6, dtype=w.dtype))
    mx.eval(err, denom)
    return float(mx.max(err).item()), float(mx.max(err / denom).item())

w = mx.random.normal(shape=(2048, 2048)).astype(mx.bfloat16)
for bits in (2, 3, 4, 5, 6, 8):
    for gs in (32, 64, 128):
        abs_e, rel_e = roundtrip_error(w, group_size=gs, bits=bits)
        print(f"affine b={bits} g={gs:3d}  max|err|={abs_e:.5f}  max rel={rel_e:.3f}")
```

Run it on your *actual weight tensors*, not on Gaussian noise, before you pick a configuration.
Real transformer weights are not Gaussian, and the outlier structure is the whole game.

> 🟡 **RECONSTRUCTED** — the defensive `len(q) > 2` unpacking. The published signature says
> `quantize` returns `tuple[array, array, array]`, but the mode table says the `mxfp4` / `mxfp8` /
> `nvfp4` modes have **no bias**, and `dequantize`'s `biases` parameter is `Optional`. The notes do
> not settle whether the non-affine modes return a 2-tuple, a 3-tuple with a `None`, or a 3-tuple
> with a dummy. **Safe default: unpack defensively as above**, and pass `biases=None` explicitly
> for the fp modes. See §13.

### 1.4 What `mx.quantized_matmul` is for

You almost never call `mx.dequantize` in a hot path. Dequantizing materialises the full-precision
weight, which defeats the entire purpose — the win from quantization on Apple silicon is
overwhelmingly a **memory-bandwidth** win, not an arithmetic one. `mx.quantized_matmul` consumes
the packed representation directly:

> ✅ **VERIFIED** — `notes/repos/mlx-core.md:781-783`:
>
> ```python
> def quantized_matmul(x: array, w: array, /, scales: array, biases: Optional[array] = None,
>                      transpose: bool = True, group_size: Optional[int] = None,
>                      bits: Optional[int] = None, mode: str = 'affine', *, stream=None) -> array
> ```

Note `transpose: bool = True`. That default is not cosmetic; it is the shape the fast kernels are
written for, and §6 is about what happens when you change it.

---

## 2. The mode inventory

### 2.1 The table

This table is quoted verbatim from MLX's own `quantize` docstring. It is the authoritative list of
**MLX quantization modes at the pinned revision**; it is not an inventory of Metal tensor formats.

> ✅ **VERIFIED** — reproduced from `python/src/ops.cpp:4649-4660`, recorded at
> `notes/repos/mlx-core.md:742-752`:
>
> ```
> ======  ======================   ==========================  =============  =====
> mode    group size               bits                        scale type     bias
> ======  ======================   ==========================  =============  =====
> affine  32, 64*, 128             2, 3, 4*, 5, 6, 8           same as input  yes
> mxfp4   32*                      4*                          e8m0           no
> mxfp8   32*                      8*                          e8m0           no
> nvfp4   16*                      4*                          e4m3           no
> ======  ======================   ==========================  =============  =====
> ```
>
> `*` marks the default when the argument is unspecified.

The same defaults appear a second time in the `mlx.nn` layer, which is a useful corroboration:

> ✅ **VERIFIED** — `mlx.nn.layers.quantized._defaults_for_mode`
> (`notes/repos/mlx-core.md:756`), and again in mlx-lm's `utils.quantize_model`
> (`notes/repos/mlx-lm.md:1037`):
>
> ```python
> mode_defaults = {"affine": (64, 4), "mxfp4": (32, 4), "nvfp4": (16, 4), "mxfp8": (32, 8)}
> ```
>
> The tuple is `(group_size, bits)`.

Read the table as **four modes, eighteen affine configurations, three block-float
configurations**: affine gives you 6 bit widths × 3 group sizes; the block-float modes each pin
both. There is no `mxfp4` at group size 64, no `nvfp4` at 8 bits, no affine at 7 bits.

### 2.2 Affine is the general one, and it is *more* general than any hardware format

Look at what the Metal kernels are actually instantiated for:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/quantized_nax.metal:88-104`, quoted at
> `notes/repos/mlx-tensorops-kernels.md:1616-1636`:
>
> ```cpp
> #define instantiate_quantized_groups(bits) \
>   instantiate_quantized_types(128, bits)   \
>   instantiate_quantized_types(64, bits)    \
>   instantiate_quantized_types(32, bits)
>
> #define instantiate_quantized_all() \
>   instantiate_quantized_groups(2) \
>   instantiate_quantized_groups(3) \
>   instantiate_quantized_groups(4) \
>   instantiate_quantized_groups(5) \
>   instantiate_quantized_groups(6) \
>   instantiate_quantized_groups(8)
> ```
>
> Activation dtypes instantiated: `float`, `float16_t`, `bfloat16_t`.

**Bits 3, 5 and 6 are not powers of two.** No hardware tensor type can represent them. MLX handles
this with an explicit pack-factor table:

> ✅ **VERIFIED** — `quantized_nax.h:20-29`
> (`notes/repos/mlx-tensorops-kernels.md:1640-1645`):
>
> ```cpp
> template <int bits, int wsize = 8>
> inline constexpr short get_pack_factor() {
>   return (bits == 3 || bits == 5) ? 8 : (bits == 6 ? 4 : wsize / bits);
> }
> ```

That is 3 bits packing 8 elements per unit and 6 bits packing 4 — deliberate, hand-written bit
manipulation, not a hardware feature. It is also why 3-bit and 5-bit exist at all: they are
*software* formats, so MLX can offer them.

Bit width 7 is explicitly excluded from the validator (§2.5). Do not go looking for it.

### 2.3 The block-float modes, and what their scales really are

`mxfp4`, `mxfp8` and `nvfp4` follow the OCP microscaling (MX) specification family: a small
floating-point element type plus one shared 8-bit exponent-or-float scale per block.

> ✅ **VERIFIED** — mode-to-encoding mapping, from the Metal instantiation list
> `fp_quantized_nax.metal:71-78` (`notes/repos/mlx-tensorops-kernels.md:1649-1666`):
>
> | Mode | Block size | Bits | Scale encoding |
> |---|---:|---:|---|
> | `nvfp4` | 16 | 4 | `fp8_e4m3` (selected by the `group_size == 16` branch) |
> | `mxfp8` | 32 | 8 | `fp8_e8m0` |
> | `mxfp4` | 32 | 4 | `fp8_e8m0` |
>
> ```cpp
> #define instantiate_quantized_types(type) \
>   instantiate_quantized_modes(type, nvfp4, 16, 4) \
>   instantiate_quantized_modes(type, mxfp8, 32, 8) \
>   instantiate_quantized_modes(type, mxfp4, 32, 4)
>
> instantiate_quantized_types(float)
> instantiate_quantized_types(bfloat16_t)
> instantiate_quantized_types(float16_t)
> ```

The element types are `E2M1` (fp4) and `E4M3` (fp8), per the docstring
(`notes/repos/mlx-core.md:767`).

### 2.4 ⚠️ MLX's `fp8_e8m0`, `fp8_e4m3`, and `fp4_e2m1` are its own structs

This implementation fact is easy to conflate with the platform surface. At the pinned MLX commit,
these names are private software structs; Xcode 27 separately documents native `MTLTensorDataType`
cases for int2, FP4, FP8, and E8M0 and auxiliary scale planes.[^metal27-formats]

> ✅ **VERIFIED** — `notes/repos/mlx-tensorops-kernels.md:1546-1549`: "`fp8_e8m0` and `fp8_e4m3`
> are defined in `mlx/backend/metal/kernels/fp8.h` (`fp8_e8m0` at `fp8.h:51-52`), and `fp4_e2m1` in
> `fp4.h`. They are **plain structs with hand-written bit manipulation**, loaded from a `uint8_t`
> by reinterpret-cast. There is no hardware fp8 type and no Metal `fp8` at all." That final
> negative conclusion describes the Xcode 26.6 snapshot used by the research note, not the
> Xcode 27 API.

Here is the scale decode, in full:

> ✅ **VERIFIED** — `fp_quantized_nax.h:31-38`
> (`notes/repos/mlx-tensorops-kernels.md:1534-1543`):
>
> ```cpp
> template <typename T, int group_size>
> static inline T dequantize_scale(uint8_t s) {
>   if constexpr (group_size == 16) {
>     // Use nv scale
>     return T(*(thread fp8_e4m3*)(&s));
>   } else {
>     return T(*(thread fp8_e8m0*)(&s));
>   }
> }
> ```

A `uint8_t` reinterpret-cast to a struct MLX wrote. That is the entire mechanism. And the element
decode is the same idea:

> ✅ **VERIFIED** — `fp_quantized_nax.h:50-67`
> (`notes/repos/mlx-tensorops-kernels.md:1553-1573`):
>
> ```cpp
> template <int bits, typename U = float>
> struct Dequantize {
>   U operator()(uint8_t x) {
>     if constexpr (bits == 8) {
>       return U(*(thread fp8_e4m3*)(&x));
>     } else {
>       return U(*(thread fp4_e2m1*)(&x));
>     }
>   }
> };
>
> template <typename U, int bits>
> inline void dequantize(uint8_t w, U scale, threadgroup U* w_local) {
>   if constexpr (bits == 4) {
>     w_local[0] = scale * Dequantize<4, U>{}(w);
>     w_local[1] = scale * Dequantize<4, U>{}(w >> 4);
>   } else {
>     w_local[0] = scale * Dequantize<8, U>{}(w);
>   }
> }
> ```

**Why this matters practically.** MLX dequantizes into *threadgroup memory* and then feeds
full-precision tiles to the matmul. The tensor op never sees a quantized value:

> ✅ **VERIFIED** — `notes/repos/mlx-tensorops-kernels.md:1445-1468`:
> "MLX hand-dequantizes into threadgroup memory before the tensor op ever sees the data. It does
> not use scale planes. It does not pass 4-bit tensors to `matmul2d`. It does not dequantize into
> cooperative tensors either. … By the time MPP is involved, the weights are plain
> `half`/`bfloat`/`float`. The op is a **dense matmul**; it has no idea quantization ever happened."
>
> ```
> device uint8_t (packed 4/8-bit weights)  +  device uint8_t/T (scales, biases)
>         |   QuantizedBlockLoader::load_unsafe()   <-- dequantization happens HERE
>         v
> threadgroup T (or threadgroup Wtype = bfloat)     <-- full-precision tile in shared memory
>         |   NAXTile::load()
>         v
> thread registers -> tile_matmad_nax -> cooperative_tensor -> matmul2d::run()
> ```

The destination is declared `threadgroup T Ws[BN * BK_padded]` at `quantized_nax.h:1230`, and the
FP path's threadgroup type defaults to `bfloat` (`fp_quantized_nax.h:198-204`).

Three consequences you should carry away:

1. **This MLX revision does not opt into native FP4/FP8 tensor formats.** It builds MX and NV in its
   software layer even though Xcode 27 now provides corresponding host-side tensor formats.
2. **This MLX revision does not feed scale planes to `matmul2d`.** Its kernels hand-dequantize.
   That remains useful for 26.x deployment and custom formats, but it is an implementation choice,
   not proof that Xcode 27's documented multiplane API is absent.[^metal27-planes]
3. **The dequantize cost is real and it is in the kernel.** Every group's scale is decoded and
   multiplied in software, per tile load. This is why group size has a performance dimension and
   not only a size one.

### 2.5 The validation errors, so you can recognise them

These are the exact strings `mlx/ops.cpp` raises. Knowing them saves a debugging session.

> ✅ **VERIFIED** — all quoted from `notes/repos/mlx-core.md:818-825`:
>
> | Error | Cause |
> |---|---|
> | `[quantize] The requested group size <g> is not supported. The supported group sizes are 32, 64, and 128.` | affine with a bad `group_size` |
> | `[quantize] The requested number of bits <b> is not supported. The supported bits are 2, 3, 4, 5, 6 and 8.` | bad `bits`; the guard is `bits < 2 \|\| bits > 8 \|\| bits == 7` — **7 is explicitly excluded** |
> | `[quantize] <mode> quantization requires group size <16\|32> but got <g>.` | wrong group size for a block-float mode |
> | `[quantize] <mode> ... requires bits to be <4\|8> but got <b>.` | wrong bit width for a block-float mode |
> | `[quantize] The matrix to be quantized must have at least 2 dimension` | 1-D input (note the missing "s" — that is verbatim) |
> | `[quantize] The last dimension of the matrix needs to be divisible by <group_size>` | the alignment rule from §1.2 |
> | `[quantize] Global scale is not supported on the Metal backend.` | `global_scale=` on Apple silicon, **mlx ≤ 0.32.0 only** — PR #3757 removed the throw (ships in 0.32.1, 2026-08-18); see §2.6 |
> | `[dequantize] The matrix should be given as a uint32` | you passed the wrong array as `w` |

### 2.6 `global_scale` is CUDA/CPU only, and that has a real cost on Metal

`nvfp4` supports an optional per-tensor scale on top of the per-block scale. On Metal it throws on
mlx ≤ 0.32.0; PR **#3757** (merged 2026-08-04, first shipped in **0.32.1**, released 2026-08-18)
removed the rejection and added basic Metal support — see the closure context below. The section
title is kept for anchor stability; read "is CUDA/CPU only" as the ≤ 0.32.0 state this section
documents.

> ✅ **VERIFIED (mlx ≤ 0.32.0)** — the Metal backend rejects it explicitly, `mlx/backend/metal/quantized.cpp`
> L1725-1730 at that version, quoted in `notes/repos/issues-mlx-stack.md:455-462`:
>
> ```cpp
> if (mode_ == QuantizationMode::Nvfp4 &&
>     static_cast<int>(inputs.size()) > base_size) {
>   throw std::runtime_error(
>       "[QQMatmul] Global scale (tensor-scale nvfp4) is not supported "
>       "on the Metal backend.");
> }
> ```

The consequence, from the issue that tracks it (**mlx#3911, closed 2026-08-05**):

> ✅ **VERIFIED** — quoted from mlx#3911 via `notes/repos/issues-mlx-stack.md:464`:
> "Without tensor-scale support, NVFP4 on Metal has ~137x less dynamic range than NVIDIA Blackwell
> (unsigned UE4M3 vs signed E4M3 scales) … This blocks NVFP4 quantization for Apple Silicon users
> running MoE models (DeepSeek-V3/V4, GLM-5.1, etc.)"

**Closure context (as of 2026-08-23):** mlx#3911 closed 2026-08-05, the day after PR **#3757 "Add
gather_qqmm"** merged (2026-08-04). The maintainer's closing comment: *"#3757 has added some basic
support for global scale in QQMatmul, but at the moment not all fast kernels get the support and we
are still working on improving things."* The PR's diff deletes all three Metal-side rejections —
the `[QQMatmul]` throw quoted above plus the `[quantize]` / `[dequantize]` strings in `mlx/ops.cpp`
(§2.5) — and routes a Metal `qqmm` with a global scale through the **`qmv` fallback** rather than a
fast kernel (PR description: *"The implementation is bare minimum … for Metal it is `qmv`"*). The
first release carrying it is **v0.32.1 (2026-08-18)**; the fix is *not* in the 0.32.0 wheel.

**Practical rule:** on mlx ≤ 0.32.0, if you are on Apple silicon and someone hands you an `nvfp4`
checkpoint that was produced *with* a global scale, you cannot run it as-is, and the failure is a
thrown exception rather than silent degradation — which is the good outcome. On 0.32.1+ the same
checkpoint *runs*, but through the `qmv` fallback path, so expect matmul throughput well below the
fast-kernel numbers in §6 until the follow-up kernels land. If you are choosing a mode for an
Apple-silicon target and dynamic range is your concern, `mxfp4` (E8M0 scales, which are pure
exponents and therefore wide-range) or affine is still the safer pick.

---

## 3. Sizing: what bits and group size actually cost

### 3.1 The arithmetic

A quantized weight tensor costs `bits` per element **plus** the amortised cost of its per-group
metadata. For affine, that metadata is a scale *and* a bias, each stored in the input dtype
("scale type: same as input", "bias: yes"). For the block-float modes it is one 8-bit scale and no
bias.

So, with a `bfloat16`/`float16` model (16-bit scales):

```
affine:  bpw = bits + (16 + 16) / group_size
mxfp4:   bpw = 4    + 8 / 32   = 4.25
mxfp8:   bpw = 8    + 8 / 32   = 8.25
nvfp4:   bpw = 4    + 8 / 16   = 4.50
```

> 🟡 **RECONSTRUCTED** — this arithmetic is *derived* from the verified mode table (§2.1: scale
> type "same as input", bias "yes"/"no") and the verified block sizes. The formula itself is not
> quoted from MLX source. It is arithmetic, not an API claim, but treat the exact numbers as
> predictions to check rather than as guarantees. The authoritative number is the one MLX computes
> for you — see §3.3.

Filling in the affine grid:

| bits | group 32 | group 64 | group 128 |
|---:|---:|---:|---:|
| 2 | 3.00 | 2.50 | 2.25 |
| 3 | 4.00 | 3.50 | 3.25 |
| 4 | 5.00 | 4.50 | 4.25 |
| 5 | 6.00 | 5.50 | 5.25 |
| 6 | 7.00 | 6.50 | 6.25 |
| 8 | 9.00 | 8.50 | 8.25 |

Two things jump out of this table, and both are load-bearing.

**Group size 32 is expensive.** At 2 bits, halving the group from 64 to 32 costs +0.5 bpw — a 20%
size increase — on a format whose entire selling point is size. At 4 bits it is +0.5 on 4.5, or
11%. Meanwhile the *quality* gain from a smaller group is real but has diminishing returns, because
you are buying finer outlier isolation at the cost of more metadata. **The default of 64 is the
default because it is usually the right trade.**

**A 4-bit affine model is a 4.5-bit model.** People say "4-bit" and then are surprised the file is
larger than `params × 0.5 bytes`. It is `params × 0.5625 bytes` at the default group size, plus
every layer that was not quantized at all (§3.4), plus the tokenizer and config. On a 7B model that
is roughly 4.9 GB, not 4.4 GB.

**mxfp4 is the cheapest 4-bit format in the inventory** at 4.25 bpw, and `nvfp4` — despite the
smaller elements-per-scale ratio being better for quality — is the most expensive 4-bit at 4.50,
tied with affine-64.

### 3.2 Where quality actually comes from

The honest summary of what the corpus supports:

- **8-bit is a quality floor that basically nobody argues about.** Community measurement on a
  different stack (Core AI, not MLX — see §7.4 for the sourcing caveat) put a symmetric int8 scheme
  at "+1 flip in 41 tokens, at the fp16 ceiling" while 4-bit schemes produced 11–12 flips
  (`notes/repos/john-rocky-models.md:1315-1321`). Same conclusion, different framework: 8 bits is
  where round-to-nearest stops hurting.
- **4-bit round-to-nearest is usable for chat and marginal for structure.** The same community
  source: *"non-QAT int4 flips structural tokens (broken grammar), so int8 stays the quality
  floor"* and *"int4 is a WALL … non-QAT int4 can't reach clean (needs QAT weights)"*
  (`notes/repos/john-rocky-models.md:1290-1291, 1322`). Community-measured, on Core AI bundles,
  M4 Max. Attribute accordingly — but the mechanism (round-to-nearest at 4 bits loses structural
  tokens first) is format-level, not framework-level.
- **3 bits and below is where data-aware quantization stops being optional.** mlx-lm's own doc says
  DWQ *"works best 2–4 bit"* and that going from 16 to 8 or 6 bits *"often doesn't work well"*
  (`notes/repos/mlx-lm.md:1157`) — i.e. the learned methods have nothing to fix at 8 bits and
  everything to fix at 3.

### 3.3 Let MLX tell you the real number

mlx-lm computes bits-per-weight for you and prints it during conversion.

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1057-1058`: `quantize_model` prints
> `[INFO] Quantized model with {bpw:.3f} bits per weight.`, where
> `compute_bits_per_weight = model_bytes * 8 / get_total_parameters(model)`.

**This number will not match the table in §3.1, and that is correct.** It divides *total* model
bytes by *total* parameters, so it includes every layer that was skipped, every norm, every
embedding that got different treatment, and the `lm_head`. If your printed bpw is far above your
target, that is the signal to investigate §3.4 — not a bug in the arithmetic.

### 3.4 ⚠️ SILENT FAILURE: layers that do not divide by the group size are skipped

This is the failure that quietly inflates your model and, worse, quietly changes which parts of
your network are in full precision.

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1039-1040`: mlx-lm's `quantize_model` predicate wrapper
> "*skips layers whose `weight.shape[-1] % group_size != 0` and layers without `to_quantized`.*"
>
> ⚠️ **SILENT FAILURE**
>
> A `Linear` whose input dimension is not divisible by your `group_size` is **silently left in full
> precision**. No warning, no exception, no entry in the config. You asked for a 4-bit model and
> got a model that is 4-bit *except for the layers that happened to have awkward shapes*.
>
> **Why it is easy to miss:** the model loads, runs, and produces good output — better output, in
> fact, than a fully quantized one. The only symptoms are (a) a bits-per-weight print that is
> higher than you expected and (b) a file that is larger than you expected. Both are easy to read
> as "quantization overhead" and move on.
>
> **Why it bites hardest at group size 128:** more shapes fail `% 128 == 0` than fail `% 32 == 0`.
> A model with `head_dim`-derived projection widths, an odd vocabulary, or a MoE intermediate size
> chosen for hardware reasons can have several such layers.
>
> **Detection.** After conversion, walk the model and assert on the module type — do not trust the
> config alone:
>
> ```python
> import mlx.nn as nn
> from mlx_lm import load
>
> model, tokenizer = load("mlx_model")
>
> unquantized = []
> for path, module in model.named_modules():
>     if isinstance(module, nn.Linear) and not isinstance(module, nn.QuantizedLinear):
>         w = module.get("weight", None)
>         if w is not None:
>             unquantized.append((path, tuple(w.shape)))
>
> if unquantized:
>     print(f"{len(unquantized)} Linear layers are NOT quantized:")
>     for path, shape in unquantized:
>         print(f"  {path:60s} {shape}")
> else:
>     print("every Linear is quantized")
> ```
>
> If the list is non-empty and you did not put those layers there deliberately (via a
> `quant_predicate`), reduce your group size to 64 or 32 and re-convert.

### 3.5 Mixed precision: MLX ships four recipes

You do not have to pick one bit width for the whole model. mlx-lm ships named recipes, and models
can ship their own predicate.

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1060-1077`:
>
> ```python
> QUANT_RECIPES = ["mixed_2_6", "mixed_3_4", "mixed_3_6", "mixed_4_6"]
> ```
>
> Recipe → `(low_bits, high_bits)`: `mixed_2_6 → (2, 6)`, `mixed_3_4 → (3, 4)`,
> `mixed_3_6 → (3, 6)`, `mixed_4_6 → (4, 6)`.
>
> The predicate itself, described in the notes as llama.cpp-`Q4_K_M`-like and credited in-repo to
> Alex Barron / a llama.cpp permalink:
>
> ```python
> use_more_bits = (index < num_layers // 8
>                  or index >= 7 * num_layers // 8
>                  or (index - num_layers // 8) % 3 == 2)
> if ("v_proj" in path or "v_a_proj" in path or "v_b_proj" in path) and use_more_bits: high
> if "down_proj" in path and use_more_bits: high
> if "lm_head" in path: high
> else: low
> ```
>
> It requires the model to have `down_proj` modules, otherwise:
> `ValueError("Model does not have expected keys for mixed quant.")`

The shape of that heuristic is worth internalising even if you never use the recipe: **first
eighth of the layers, last eighth of the layers, every third layer in between, plus all value
projections, all down projections and the LM head** get more bits. Those are the places where
quantization error propagates worst.

**Constraint:** > ✅ **VERIFIED** — "*quant predicates only work with `--q-mode affine`*"
(`notes/repos/mlx-lm.md:244`). You cannot mix-and-match a recipe with `mxfp4`.

### 3.6 Models can carry their own predicate

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1044-1056`: `quantize_model` picks up
> `getattr(model, "quant_predicate", None)`. Example from `models/gpt_oss.py:328`:
>
> ```python
> def quant_predicate(self):
>     def predicate(path, _):
>         if path.endswith("router"):
>             return {"group_size": 64, "bits": 8}
>         return True
> ```
>
> **22 model files define one**: `gemma4_text, granitemoe, gemma4, jamba, gpt_oss,
> granitemoehybrid, afmoe, longcat_flash_ngram, bailing_moe, kimi_linear, mellum, lfm2_moe,
> minimax, bailing_moe_linear, longcat_flash, qwen3_moe, qwen3_next, Klear, step3p5, qwen3_5,
> qwen3_vl_moe, rwkv7`.

Look at what gpt-oss does: **the MoE router gets 8 bits at group 64 while everything else takes
your CLI setting.** That is a deep piece of domain knowledge encoded in one function. A router
produces expert *indices*; a small numeric perturbation there does not degrade an output smoothly,
it routes the token to a different expert entirely. Quantization error at a router is discrete, not
continuous.

If you are writing your own model class, this is the hook. And if you are quantizing a MoE model
that *isn't* in that list of 22, ask yourself whether its router needs the same protection.

### 3.7 Per-layer overrides land in the config

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1041-1043`: per-layer overrides are written to
> `config["quantization"][path] = {"group_size": …, "bits": …}`, and
> `config["quantization_config"] = config["quantization"]` (mirrored "support hf model tree
> #957"). If the model already has a `quantization` key, the config becomes fine-grained per-layer.

So a converted checkpoint's `config.json` is a readable record of exactly what happened. When you
inherit a quantized model from someone else, read `config["quantization"]` first — it will tell you
whether you have a uniform 4-bit model or a mixed one, and which layers were exempted.

---

## 4. The array API

This section is the reference. Every signature is quoted; nothing is inferred.

### 4.1 The five ops

> ✅ **VERIFIED** — all five quoted from the `nb::sig` strings in `python/src/ops.cpp`, recorded at
> `notes/repos/mlx-core.md:771-798`:
>
> ```python
> def quantize(w: array, /, group_size: Optional[int] = None, bits: Optional[int] = None,
>              mode: str = 'affine', *, global_scale: Optional[array] = None,
>              stream=None) -> tuple[array, array, array]
>
> def dequantize(w: array, /, scales: array, biases: Optional[array] = None,
>                group_size: Optional[int] = None, bits: Optional[int] = None,
>                mode: str = 'affine', global_scale: Optional[array] = None,
>                dtype: Optional[Dtype] = None, *, stream=None) -> array
>
> def quantized_matmul(x: array, w: array, /, scales: array, biases: Optional[array] = None,
>                      transpose: bool = True, group_size: Optional[int] = None,
>                      bits: Optional[int] = None, mode: str = 'affine', *, stream=None) -> array
>
> def gather_qmm(x: array, w: array, /, scales: array, biases: Optional[array] = None,
>                lhs_indices: Optional[array] = None, rhs_indices: Optional[array] = None,
>                transpose: bool = True, group_size: Optional[int] = None,
>                bits: Optional[int] = None, mode: str = 'affine',
>                *, sorted_indices: bool = False, stream=None) -> array
>
> def qqmm(x: array, w: array, scales: Optional[array] = None, group_size: Optional[int] = None,
>          bits: Optional[int] = None, mode: str = 'nvfp4',
>          global_scale_x: Optional[array] = None, global_scale_w: Optional[array] = None,
>          *, stream=None) -> array
> ```
>
> Plus two small conversion helpers:
>
> ```python
> def to_fp8(x: array, *, stream=None) -> array          # -> uint8 E4M3
> def from_fp8(x: array, dtype: Dtype = bfloat16, *, stream=None) -> array
> ```
>
> The C++ declarations at `mlx/ops.h:1547-1611` match, with `mode` as `const std::string&` and
> `global_scale` as `std::optional<array>`.

Notice the `/` in four of the five signatures: `w`, `x` and (for `quantize`) the weight are
**positional-only**. You cannot write `mx.quantize(w=my_weight)`.

### 4.2 A complete worked round trip

```python
"""Quantize a weight, matmul with it, and measure the error against full precision."""
import mlx.core as mx

mx.random.seed(0)

K, N, M = 4096, 4096, 8          # K = reduction dim, N = output dim, M = batch
GROUP, BITS, MODE = 64, 4, "affine"

# A weight laid out the way MLX wants it for transpose=True: [N, K].
w = mx.random.normal(shape=(N, K)).astype(mx.bfloat16)
x = mx.random.normal(shape=(M, K)).astype(mx.bfloat16)

q = mx.quantize(w, group_size=GROUP, bits=BITS, mode=MODE)
wq, scales = q[0], q[1]
biases = q[2] if len(q) > 2 else None

# The fast path: consume the packed representation directly.
y_q = mx.quantized_matmul(
    x, wq, scales, biases,
    transpose=True, group_size=GROUP, bits=BITS, mode=MODE,
)

# The reference: full-precision matmul against the ORIGINAL weight.
y_ref = x @ w.T

mx.eval(y_q, y_ref)

err = mx.abs(y_q.astype(mx.float32) - y_ref.astype(mx.float32))
scale = mx.maximum(mx.abs(y_ref.astype(mx.float32)), mx.array(1e-3))
print(f"output shape      : {y_q.shape}")
print(f"max abs error     : {float(mx.max(err).item()):.5f}")
print(f"max rel error     : {float(mx.max(err / scale).item()):.5f}")
print(f"packed weight dtype/shape: {wq.dtype} {wq.shape}")
print(f"scales dtype/shape       : {scales.dtype} {scales.shape}")
```

Three things to internalise from this listing:

1. **`transpose=True` means `w` is `[N, K]` and the op computes `x @ w.T`.** This is the *default*
   and it is the only layout the fast kernels support (§6.2). If you have a `[K, N]` weight, you
   transpose it once at conversion time, not on every forward pass.
2. **You must pass `group_size`, `bits` and `mode` to the matmul too.** They are not carried on the
   arrays. Passing a different `group_size` to `quantized_matmul` than you passed to `quantize`
   does not raise a shape error in general — it silently reinterprets the scales array. Keep the
   three values in one place in your code; see §4.5.
3. **Compare against the original `w`, not against `dequantize(quantize(w))`.** The latter tells
   you the kernel agrees with itself, which is not the question you care about.

### 4.3 `mx.qqmm` — quantizing the activations too

`qqmm` is the newest member of the family and the one with the most restrictions. It quantizes
**both** operands.

> ✅ **VERIFIED** — `notes/repos/mlx-core.md:802-812`. Key facts:
>
> - Default `mode` is `"nvfp4"`, and **only `nvfp4` and `mxfp8` are supported**. Anything else:
>   `"[qqmm] Only 'nvfp4' and 'mxfp8' quantization modes are supported but '<mode>'"`.
> - `x` is quantized **on the fly**. `w` is used as-is if already quantized (then `scales` is
>   required and `group_size`/`bits`/`mode` must match), otherwise it is quantized on the fly too.
> - "*If `w` is expected to receive gradients, it must be provided in non-quantized form.*"
> - Non-quantized dtypes must be `float32`/`float16`/`bfloat16`; a quantized `w` must be packed in
>   unsigned ints.
> - **Only 2-D inputs**: `"[qqmm] Only 2D inputs are supported"`.
> - For `nvfp4`, **either both or neither** of `global_scale_x` / `global_scale_w`.

And a numerical-tolerance note straight from the shipped example, which you should read before you
write an equality assertion:

> ✅ **VERIFIED** — header comment of `examples/python/qqmm.py`, quoted at
> `notes/repos/mlx-core.md:812`: "*In mxfp8 mode, the results do not match exactly: fewer than 1%
> of output elements differ. … The error can exceed 1 ULP for very small values, and is always
> below 1 ULP for larger values. For nvfp4, the results match exactly.*"

That is a remarkable sentence and worth reading twice: **nvfp4 `qqmm` matches exactly, mxfp8 does
not.** The lower-precision format is the reproducible one, because its arithmetic path has less
room for reassociation. Do not assume "more bits ⇒ more agreement".

The VJP pattern is also demonstrated in that example:

> ✅ **VERIFIED** — `examples/python/qqmm.py:80-112`
> (`notes/repos/mlx-core.md:813`): `mx.vjp(lambda x: mx.qqmm(x, w, ...), primals=(x,),
> cotangents=(c,))` equals `mx.qqmm(c, quantize(w.T))`.

### 4.4 `to_fp8` / `from_fp8`

Two small helpers that expose MLX's E4M3 codec directly:

```python
import mlx.core as mx

x  = mx.random.normal(shape=(1024,)).astype(mx.float32)
p  = mx.to_fp8(x)                       # uint8, E4M3
x2 = mx.from_fp8(p, dtype=mx.float32)   # back out; default dtype is bfloat16

mx.eval(p, x2)
print(p.dtype, p.shape)                 # uint8 (1024,)
print(float(mx.max(mx.abs(x2 - x)).item()))
```

These are useful for building your own storage formats and for sanity-checking what E4M3 actually
costs you on your data distribution. **Note the default `dtype=bfloat16` on `from_fp8`** — the
same footgun as `dequantize`.

### 4.5 A small discipline that prevents most quantization bugs

Because `group_size`, `bits` and `mode` travel *alongside* the arrays rather than inside them,
every real codebase eventually invents a container for them. Do it on day one:

```python
from dataclasses import dataclass
from typing import Optional
import mlx.core as mx


@dataclass(frozen=True)
class QuantSpec:
    """The three values that must agree between quantize and every consumer."""
    group_size: int
    bits: int
    mode: str = "affine"

    def quantize(self, w: mx.array):
        q = mx.quantize(w, self.group_size, self.bits, self.mode)
        biases = q[2] if len(q) > 2 else None
        return q[0], q[1], biases

    def matmul(self, x, wq, scales, biases=None, *, transpose: bool = True):
        return mx.quantized_matmul(
            x, wq, scales, biases,
            transpose=transpose,
            group_size=self.group_size, bits=self.bits, mode=self.mode,
        )

    def dequantize(self, wq, scales, biases=None, *, dtype: Optional[mx.Dtype] = None):
        return mx.dequantize(
            wq, scales, biases,
            group_size=self.group_size, bits=self.bits, mode=self.mode, dtype=dtype,
        )

    def check_shape(self, w: mx.array) -> None:
        """Fail loudly at build time rather than silently at convert time."""
        if w.ndim < 2:
            raise ValueError(f"quantize needs >= 2 dims, got {w.shape}")
        if w.shape[-1] % self.group_size:
            raise ValueError(
                f"last dim {w.shape[-1]} is not divisible by group_size "
                f"{self.group_size}: this layer would be SILENTLY SKIPPED by "
                f"mlx-lm's quantize_model predicate"
            )
        if self.mode == "affine" and w.shape[-1] % 64:
            raise ValueError(
                f"K={w.shape[-1]} is not a multiple of 64: this layer will not "
                f"take the NAX fast path on M5-class hardware (see guide §6.1)"
            )


spec = QuantSpec(group_size=64, bits=4, mode="affine")
```

That `check_shape` is doing the work of two sections of this guide at once. It is fifteen lines and
it will save you a re-conversion.

---

## 5. The module API: `nn.quantize` and friends

Below the array ops sits a module layer that does the whole-model transformation for you.

### 5.1 `nn.quantize`

> ✅ **VERIFIED** — `python/mlx/nn/layers/quantized.py`, recorded at
> `notes/repos/mlx-core.md:831-846`:
>
> ```python
> nn.quantize(model, group_size=None, bits=None, *, mode="affine",
>             quantize_input=False, class_predicate=None)
> ```
>
> - Default predicate: **every leaf module that defines `to_quantized()`**.
> - `class_predicate(path, module)` may return `True` / `False` **or a dict of kwargs** forwarded
>   to `to_quantized`.
> - "*`quantize_input=True` is only supported for `"nvfp4"` and `"mxfp8"` modes and `Linear`
>   layers.*"
> - **Modifies the model in place** (`model.update_modules(leaves)`).
>
> Examples from the docstring:
>
> ```python
> nn.quantize(model, group_size=64, bits=4, mode="affine")
>
> predicate = lambda p, m: isinstance(m, nn.Linear)
> nn.quantize(model, mode="nvfp4", quantize_input=True, class_predicate=predicate)
> ```

The dict-returning predicate is the most useful and least-known feature here. It is how you build
mixed precision without leaving `mlx.nn`:

```python
import mlx.nn as nn


def predicate(path: str, module: nn.Module):
    """Per-layer quantization policy.

    Return False to leave a module in full precision, True to use the call's
    defaults, or a dict of kwargs to override them for this module only.
    """
    if not isinstance(module, (nn.Linear, nn.Embedding)):
        return False

    # Routers decide WHICH expert runs. Their error is discrete, not smooth.
    if path.endswith("router") or path.endswith("gate"):
        return {"group_size": 64, "bits": 8}

    # The output head sees every token; it is worth protecting.
    if "lm_head" in path:
        return {"group_size": 64, "bits": 6}

    # Anything whose input dim does not divide the group size would be skipped
    # anyway; make the decision explicit so it shows up in the diff.
    w = module.get("weight", None)
    if w is not None and w.shape[-1] % 64:
        return False

    return True


nn.quantize(model, group_size=64, bits=4, mode="affine", class_predicate=predicate)
```

**Note that `nn.quantize` mutates the model in place and returns nothing useful.** If you need the
"before" model for a differential test (§10), you must load two copies — you cannot quantize and
then un-quantize.

### 5.2 The quantized layer classes

> ✅ **VERIFIED** — `notes/repos/mlx-core.md:848-860`:
>
> ```python
> nn.QuantizedLinear(input_dims, output_dims, bias=True,
>                    group_size=None, bits=None, mode="affine")
> nn.QuantizedLinear.from_linear(linear_layer, group_size=None, bits=None, mode="affine")
>
> nn.QuantizedEmbedding(num_embeddings, dims, group_size=None, bits=None, mode="affine")
> nn.QuantizedEmbedding.from_embedding(...)
>
> nn.QQLinear(input_dims, output_dims, group_size=None, bits=None, mode="nvfp4")
> ```
>
> - `QuantizedLinear` and `QuantizedEmbedding` **freeze their parameters in `__init__`**
>   (`self.freeze()`).
> - `QuantizedEmbedding.as_linear(x)` exists for tied embeddings.
> - `QQLinear` quantizes activations too and has **no bias support**:
>   `from_linear` raises `NotImplementedError("QQLinear does not support bias yet.")`.

The frozen-parameters detail is the one that surprises people mid-fine-tune. A `QuantizedLinear`'s
weights are *not* trainable by default. That is deliberate — you cannot backprop through a packed
`uint32` — and it is what makes QLoRA work: the base is frozen, the adapter is not.

### 5.3 `QQLinear`'s train/eval switch is stateful

This is a genuinely unusual API and worth reading closely:

> ✅ **VERIFIED** — `notes/repos/mlx-core.md:851-858`:
>
> ```python
> def _set_training_mode(self, mode):
>     super()._set_training_mode(mode)
>     if self._training: self.dequantize()
>     else:              self.quantize()
> ```
>
> i.e. **`layer.eval()` packs the weights; `layer.train()` unpacks them** so gradients can flow.

So calling `model.train()` on a network containing `QQLinear` layers **allocates full-precision
copies of those weights**. If you were counting on a fixed memory footprint, that is where it went.
Conversely, if you profile a model that you forgot to `.eval()`, you are measuring the unpacked
path and your numbers are meaningless.

### 5.4 Which layers are quantizable at all

The default predicate is "every leaf module that defines `to_quantized()`". In mlx-lm that set
includes the MoE expert containers:

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1585`: `mlx_lm/models/switch_layers.py` defines
> `SwitchLinear`, `QuantizedSwitchLinear`, `SwiGLU`, `SwitchGLU`, `SwitchMLP`, `_gather_sort`,
> `_scatter_unsort`.

`QuantizedSwitchLinear` is the MoE analogue of `QuantizedLinear`, and it is the thing that
ultimately calls `mx.gather_qmm`. §7 is about that path.

### 5.5 The mlx-lm convert CLI

For whole checkpoints you generally do not call `nn.quantize` yourself; you use the CLI.

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:221-244`, read from `mlx_lm/convert.py`'s argparse:
>
> | Flag | Default | Notes |
> |---|---|---|
> | `--hf-path` / `--model` | — | same destination (`hf_path`) |
> | `--mlx-path` | `mlx_model` | **must not already exist** |
> | `-q` / `--quantize` | False | |
> | `--q-group-size` | None → mode default | |
> | `--q-bits` | None → mode default | |
> | `--q-mode` | `affine` | choices: `affine`, `mxfp4`, `nvfp4`, `mxfp8` |
> | `--quant-predicate` | None | choices: `mixed_2_6`, `mixed_3_4`, `mixed_3_6`, `mixed_4_6` |
> | `--dtype` | None | `float16` / `bfloat16` / `float32`; else from config `torch_dtype` |
> | `--upload-repo` | None | |
> | `-d` / `--dequantize` | False | mutually exclusive with `-q` |
> | `--trust-remote-code` | False | |
>
> ```bash
> mlx_lm.convert --model mistralai/Mistral-7B-Instruct-v0.3 -q
> mlx_lm.convert --model mistralai/Mistral-7B-Instruct-v0.3 -q \
>                --upload-repo mlx-community/my-4bit-mistral
> mlx_lm.convert --model Qwen/Qwen3-8B -q --q-mode nvfp4          # group_size 16, bits 4
> mlx_lm.convert --model meta-llama/Llama-3.1-8B -q --q-bits 3 --quant-predicate mixed_3_6
> ```
>
> Errors: `ValueError(f"Cannot save to the path {mlx_path} as it already exists...")` and
> `ValueError("Choose either quantize or dequantize, not both.")`.

Two operational notes. **`--mlx-path` must not exist** — there is no `--force`; delete or rename
first, which is mildly annoying in a script and is also a safety feature. And **`--trust-remote-code`
defaults to `False` for a reason**: mlx-lm shipped a fix for **CVE-2026-5843 /
GHSA-9m9w-53g9-47c4**, where a `model_file` key in `config.json` caused `load_model` to import and
execute a Python file straight from the model directory on a plain `load()`
(`notes/repos/mlx-lm.md`, PR #1385). Do not set that flag reflexively.

### 5.6 Loading checkpoints someone else quantized

MLX reads several foreign quantization formats. The translation table is worth having:

> ✅ **VERIFIED** — `mlx_lm/utils.load_model` lines 391-419, recorded at
> `notes/repos/mlx-lm.md:1079-1089`. `config["quantization"]` is honoured directly (including
> per-path dicts). Otherwise a legacy `quantization_config` is translated:
>
> | `quant_method` | Handling |
> |---|---|
> | `bitnet` | `from .models.bitlinear_layers import bitnet_quantize; model = bitnet_quantize(model, quantization_config)` |
> | `mxfp4` | `{"group_size": 32, "bits": 4, "mode": "mxfp4"}` |
> | `compressed-tensors` with `format == "nvfp4-pack-quantized"` | `{"group_size": 16, "bits": 4, "mode": "nvfp4"}` |
> | `compressed-tensors` (other) | `{"group_size": 32, "bits": 4, "mode": "affine"}` |
> | `awq` / `gptq` | `_transform_awq_weights(...)` — unpacks/transposes/repacks AutoAWQ-GPTQ 4-bit weights into MLX layout |

The AWQ/GPTQ importer has hard limits you will hit:

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1091-1098`:
>
> - **Only `bits == 4`**: `ValueError(f"Only {bits=} is supported for AutoAWQ/GPTQ models.")`
> - Any `*.g_idx` key raises: "*Models with non-contiguous group indices (g_idx) are not currently
>   supported. Please use a model without g_idx or re-quantize the model using mlx_lm.convert.*"
> - AWQ stores `qweight` as `[in_features, out//8]`; MLX wants `[out, in//8]`. The unpack shifts
>   are the AWQ interleave `mx.array([0, 4, 1, 5, 2, 6, 3, 7]) * bits`.
> - Bias conversion: MLX dequantizes as `w*scale + bias`, AWQ as `(w - zero)*scale`, so
>   `biases = -zeros * scales`; the symmetric case uses `zero_point = 1 << (bits-1)` (= 8).

That last bullet is the clearest possible illustration of §1.2. **AWQ's "zero point" and MLX's
"bias" are the same idea in different algebra**, and the conversion is exactly one sign flip and
one multiply. If you are ever debugging a foreign checkpoint that loads but produces garbage, that
relation is the first thing to check.

### 5.7 Activation quantization at the model level

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1100-1110`. When `config["quantize_activations"]` is
> true, `load_model` swaps every `nn.QuantizedLinear` for
> `nn.QQLinear(in_dims, out_dims, group_size, bits, mode)`, with two guards:
>
> ```python
> if m.mode not in ("nvfp4", "mxfp8"):
>     raise ValueError("Mode ({m.mode}) does not support activation quantization")
> if m.get("bias", False):
>     raise ValueError("Linear layer with bias does not support activation quantization")
> ```
>
> Exposed as `--quantize-activations` / `-qa` on `mlx_lm.generate` and `mlx_lm.benchmark`
> (passed as `model_config={"quantize_activations": args.quantize_activations}`).

So `-qa` is only meaningful on an `nvfp4` or `mxfp8` checkpoint, and only on a model whose linears
have no bias term. Most modern LLM architectures satisfy the second condition; almost no
affine-quantized checkpoint satisfies the first. **If `-qa` seems to do nothing, check your
`--q-mode` first.**

---

## 6. The gates: what decides whether you get the fast kernel

This is the section that explains why two shapes that look equally reasonable can differ by
multiples in throughput, with no diagnostic anywhere.

### 6.1 The three gates

> ✅ **VERIFIED** — all read out of the MLX Metal backend and quoted at
> `notes/repos/mlx-tensorops-kernels.md:1673-1683`:
>
> | Requirement | Where | Note |
> |---|---|---|
> | `K % 64 == 0` | `quantized.cpp:787`, `:982` | **hard gate**; otherwise fall back to non-NAX |
> | `transpose == true` | `quantized.cpp:787`, `:982`, `:1327` | the NAX quantized path is **transposed-B only** |
> | `BK >= SIMD_SIZE` | `quantized_nax.h:952` | `static_assert` |
> | `BK % SIMD_SIZE == 0` | `quantized_nax.h:953` | `static_assert` |
> | **BK = 64 only for gather** | `quantized.cpp:689` | comment: *"The gather qmm NAX kernels are instantiated with BK = 64 only"* |
> | `BK_padded = BK + 16/sizeof(T)` | `quantized_nax.h:960` | bank-conflict padding |
> | tiles fixed at 64/64/64, `WM=WN=2` | `quantized_nax.metal:61-81` | every instantiation |
> | `SK = 32`, `TK = SK/16 = 2` | `quantized_nax.h:991-995` | K micro-step |

Three of those are yours to control:

**Gate 1 — `K % 64 == 0`.** `K` is the *reduction* dimension: the input feature count of the
linear, the last dimension of your `[N, K]` weight. Almost every mainstream transformer satisfies
this by construction (hidden sizes of 2048, 3072, 4096, 5120 are all multiples of 64). The models
that *don't* are the interesting ones: adapters with odd ranks, vision towers with `head_dim` 72,
custom projections sized to a non-round latent, and anything where someone picked a dimension for a
parameter-count target rather than for alignment.

**Gate 2 — `transpose=True`.** The NAX quantized kernels are **transposed-B only**. There is no
`transpose=False` NAX kernel. If your weight is stored `[K, N]` and you pass `transpose=False`, you
leave the fast path entirely.

**Gate 3 — `BK = 64` for gather.** For `gather_qmm`, the NAX kernels exist at exactly one K-block
size. This constrains the geometry of the whole MoE path and is why the gather kernels have their
own alignment bugs (§9.1, §9.2) separate from the dense ones.

### 6.2 ⚠️ SILENT FAILURE: missing a gate costs you throughput and tells you nothing

> ⚠️ **SILENT FAILURE**
>
> **There is no warning when your shapes miss the NAX gates.** `quantized.cpp` checks
> `K % 64 == 0 && transpose`, and if the condition fails it dispatches a different kernel. No log
> line, no `UserWarning`, no attribute you can read afterwards. The op returns correct numbers at a
> different speed.
>
> **Why this is worse than it sounds:** on an M5-class machine the difference between the NAX and
> non-NAX quantized matmul is the difference between using the neural accelerators and not. You do
> not find out from the API; you find out from a benchmark you may not have run, or from a user
> saying the app feels slow.
>
> **Adjacent instance of the same class**, and the reason to take this seriously: the *build* gate
> has exactly the same property. If `MACOSX_DEPLOYMENT_TARGET < 26.2`, CMake drops **every NAX
> kernel** and sets `MLX_METAL_NO_NAX`, emitting only a CMake `WARNING` that scrolls past in a
> build log. mlx#3821 ("Source builds silently drop the NAX kernels when
> `MACOSX_DEPLOYMENT_TARGET < 26.2` — no configure-time warning", CLOSED) and its fix PR **#3824**
> ("Warn at configure time when NAX kernels are disabled", MERGED) exist because people shipped
> builds like this.
> ✅ VERIFIED, `notes/repos/issues-mlx-stack.md:1021`.
>
> **Detection.** Measure, do not assume. §6.5 gives a probe.

### 6.3 What actually runs: the dispatch ladder

Quantized matmul is not one kernel. Which one you get depends on `M` — the number of rows in `x`,
i.e. your batch × sequence length.

> ✅ **VERIFIED** — established in the mlx#3852 thread and recorded at
> `notes/repos/issues-mlx-stack.md:481-484`:
>
> - Generation 16 takes **`qmv_wide`** for affine at **M ≥ 2** (`use_qmv_wide`), up to
>   **`get_qmv_batch_limit`** (10–12 at the dimensions tested), then **`qmm`**.
> - Past the qmv batch limit, the qmm path is **flat at 0.887 ms for every M from 10 to 32** — so
>   **M=10 pays the M=32 price**.

And `qmv_wide` itself:

> ✅ **VERIFIED** — mlx PR **#3764** (MERGED), `notes/repos/issues-mlx-stack.md:1032`:
> "`qmv_wide` — small-batch quantized matvec for **M ∈ [2, vector_limit)**; dequantizes each weight
> group once and reuses across the tile ('adapted from llama.cpp's `kernel_mul_mv_ext`'). Covers
> **affine, nvfp4, mxfp4, mxfp8**, all dtypes, batched weights. **fp modes on all GPU generations;
> affine gated to gen-15+.** Speedups vs `qmv` on Gemma-4-12B `[15360x3840]` bf16: M=4 → 1.4–2.0×;
> M=8 → 1.2–2.2×."

Note the asymmetry buried in that quote: **the fp modes get `qmv_wide` on every GPU generation;
affine is gated to gen-15 and later.** On an older Mac, `mxfp4` may take a better small-batch path
than affine does.

The practical shape of the ladder:

| M (rows of `x`) | What you are doing | Kernel family |
|---|---|---|
| 1 | single-token decode | `qmv` |
| 2 … ~10 | speculative verify, tiny batch | `qmv_wide` (affine: gen-15+) |
| ~10 … 32 | small batch | `qmm` — **flat cost**, M=10 costs the same as M=32 |
| large | prefill, real batching | `qmm` |

**The flat region is free throughput.** If you are running at M=10, going to M=32 costs you
nothing in kernel time. Batch harder.

### 6.4 The 2-bit surprise: it stops paying at M ≥ 3

Everyone assumes fewer bits is monotonically faster. On the quantized matmul path, it is not.

> ✅ **VERIFIED** — mlx#3852 (**CLOSED 2026-08-16 without an optimization**), measured on **M4 Pro
> (`applegpu_g16s`), mlx 0.32.0 wheel, macOS 15.6, group_size=128**. The maintainer closed it to
> prioritize real inference cases; the measurements were not disputed, and the proposed BM=16
> optimization PR #3863 had already closed unmerged on 2026-08-02. Recorded at
> `notes/repos/issues-mlx-stack.md:470-479`. Figures are the M=1 absolute time followed by
> speedups relative to it:
>
> | shape (K→N) | bits | M1 | M2 | M3 | M4 | M8 | M10 | M32 |
> |---|---|---|---|---|---|---|---|---|
> | 5120→17408 | 2 | 0.121 ms | 1.30× | 1.82× | 2.34× | 4.53× | 7.3× | 7.3× |
> | 5120→17408 | 4 | 0.198 ms | **0.99×** | 1.13× | 1.43× | 2.84× | 4.5× | 4.5× |
> | 5120→248320 (lm_head) | 2 | 1.539 ms | 1.39× | 1.98× | 2.53× | 5.11× | | |
> | 5120→248320 (lm_head) | 4 | 2.725 ms | **1.01×** | 1.14× | 1.47× | 3.03× | | |
>
> "At M=3 the two bit widths cost the same absolute time (0.221 vs 0.224 ms). **This kills 2-bit's
> speculative-decoding value** since verify width M = draft+1 = 2–6. Measured spec speedup 1.2× on
> a 2-bit 27B vs 1.6–2.1× on 8-bit models, same machine."

Also established in that thread, and worth knowing before you optimise the wrong thing:

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:484`: "Half-precision arithmetic ran at
> identical speed (**no 2× half rate on M-series**), and `math_mode: "fast"` was a no-op for this
> kernel."

**Read the table this way.** At M=1 — pure single-token decode — 2-bit is 1.6× faster than 4-bit
(0.121 vs 0.198 ms), exactly as the bandwidth argument predicts. By M=3 the advantage is gone. The
2-bit kernel's *scaling* with M is better in relative terms, but it started from a lower absolute
base and the two curves cross. So **2-bit is a pure single-token-decode optimisation.** The moment
you speculate, batch, or prefill, you are paying 2-bit's quality cost for none of its speed.

That is a genuinely counterintuitive result and it comes from one machine, one mlx version, one
group size. Attribute it precisely: **community-measured, M4 Pro `applegpu_g16s`, mlx 0.32.0 wheel,
macOS 15.6, group_size 128.** If 2-bit matters to your product, re-measure on your target.

### 6.5 A probe you can run

Measurement beats inference. This script sweeps `K` around the 64-boundary and around the batch
ladder, so you can see both gates on your own hardware:

```python
"""Probe quantized-matmul dispatch on THIS machine.

Sweeps K across the K % 64 boundary and M across the qmv / qmv_wide / qmm ladder.
Prints per-call milliseconds. Look for step changes, not smooth curves.
"""
import time
import mlx.core as mx

GROUP, BITS, MODE = 64, 4, "affine"
N = 8192
WARMUP, ITERS = 5, 50


def bench(M: int, K: int) -> float:
    w = mx.random.normal(shape=(N, K)).astype(mx.bfloat16)
    x = mx.random.normal(shape=(M, K)).astype(mx.bfloat16)
    q = mx.quantize(w, GROUP, BITS, MODE)
    wq, scales = q[0], q[1]
    biases = q[2] if len(q) > 2 else None
    mx.eval(wq, scales, x)

    def call():
        return mx.quantized_matmul(
            x, wq, scales, biases,
            transpose=True, group_size=GROUP, bits=BITS, mode=MODE,
        )

    for _ in range(WARMUP):
        mx.eval(call())
    mx.synchronize()

    t0 = time.perf_counter()
    for _ in range(ITERS):
        mx.eval(call())
    mx.synchronize()
    return (time.perf_counter() - t0) * 1e3 / ITERS


print(f"device: {mx.device_info().get('architecture', 'unknown')}")
print()
print("=== K sweep at M=1 (the K % 64 gate) ===")
for K in (4096, 4160, 4224, 4288, 4096 + 32, 4096 + 16):
    print(f"  K={K:5d}  K%64={K % 64:2d}  {bench(1, K):7.3f} ms")

print()
print("=== M sweep at K=4096 (the dispatch ladder) ===")
for M in (1, 2, 3, 4, 8, 10, 12, 16, 32, 64):
    print(f"  M={M:3d}  {bench(M, 4096):7.3f} ms")
```

What to look for:

- In the **K sweep**, a `K` that is a multiple of 64 should not be dramatically slower than a
  nearby one that is not; if a *non*-multiple is notably slower per-element, you are seeing the
  fallback. On pre-gen-17 hardware there is no NAX path at all and the sweep will look flat — that
  itself is the answer.
- In the **M sweep**, look for the flat region. On the M4 Pro data above it was M=10 through M=32.
  Find yours and batch to its top edge.

> 🔴 **GAP** — MLX exposes **no API to ask which quantized kernel a given call dispatched to.**
> There is no `mx.explain(...)`, no env var that logs the selection, and the gates live in
> `quantized.cpp` behind the Python boundary. Resolving this would need either an upstream
> diagnostic hook or a Metal capture in Instruments where you read the kernel *name* (the NAX
> variants are separately named — `quantized_nax`, `fp_quantized_nax`).
> **Safe default: benchmark the shapes you care about and use `transpose=True`.** Keep `K % 64 ==
> 0` when the model already has that shape. If it does not, alignment means changing or padding a
> model dimension, not flipping a free conversion option; measure that overhead and use the
> version/fallback guidance in §9.4.[^k64-tradeoff]

### 6.6 The other silent numeric switch: `MLX_ENABLE_TF32`

Not strictly a quantization gate, but it lands on the same code paths and it will confuse your
verification runs, so it belongs here.

> ✅ **VERIFIED** — quoted from a contributor reading the source in mlx#3860, recorded at
> `notes/repos/issues-mlx-stack.md:307`: "on Metal every TF32 gate is
> `is_nax_available() && (env::enable_tf32() || dtype != float32)` — the steel and gather GEMM
> paths in `matmul.cpp`, **`quantized.cpp`**, and the SDPA gate — and **`is_nax_available()`
> requires macOS ≥ 26.2 and `arch_gen >= 17` (18 on `'p'` parts)**. So the flag is inert before
> gen-17 on Metal. On CUDA it isn't gated at all."

Three properties, all of which have cost people days:

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:311-314`:
>
> 1. **Shape-dependent.** Matvec shapes (M=1 or N=1) do not take the NAX route and stay exact
>    fp32. The *same dtype and op* gives different precision by operand shape.
> 2. **First-use latched.** The env var is read lazily on first use.
>    `os.environ["MLX_ENABLE_TF32"] = "0"` **before the first matmul** works in-process; set any
>    later and it silently does nothing.
> 3. **Not limited to things that look like matmuls** — it also moves attention paths that compose
>    from ordinary GEMMs.

**The default is `1`.** ✅ VERIFIED (`notes/repos/issues-mlx-stack.md:284`, `mlx/utils.h`). MLX's
own test suite forces it off: `python/tests/mlx_tests.py:6` sets `MLX_ENABLE_TF32=0`
(`notes/repos/mlx-core.md:827`), and mlx-lm PR **#1595** pins it in `tests/test_models.py`.

**Do the same in any verification harness.** Set it at the very top of your entry point, before you
import anything that might touch a GPU:

```python
import os
os.environ["MLX_ENABLE_TF32"] = "0"   # MUST precede the first matmul in the process

import mlx.core as mx     # noqa: E402
import mlx.nn as nn       # noqa: E402
```

---

## 7. `gather_qmm`, MoE, and why routed-only reads matter

### 7.1 The problem `gather_qmm` solves

A Mixture-of-Experts feed-forward block stores `E` expert weight matrices stacked into one tensor
of shape `(E, N, K)`. Each token's router picks `top_k` of them. The arithmetic is tiny — you do
`top_k` matmuls per token, not `E` — but the *memory* behaviour is what decides your throughput on
Apple silicon, because decode is bandwidth-bound.

There are two ways to implement this and they differ by an order of magnitude:

1. **Gather, then dense matmul.** Materialise the selected expert weights into a contiguous buffer
   and run an ordinary matmul. Simple, correct, and it reads the whole expert table — or at least
   behaves as if it does.
2. **Index inside the kernel.** Pass the expert indices *into* the kernel and have each threadgroup
   load only the slabs it needs. Reads scale with `top_k`, not with `E`.

`mx.gather_qmm` is option 2, for quantized weights.

### 7.2 The signature and its index semantics

> ✅ **VERIFIED** — `notes/repos/mlx-core.md:785-789`:
>
> ```python
> def gather_qmm(x: array, w: array, /, scales: array, biases: Optional[array] = None,
>                lhs_indices: Optional[array] = None, rhs_indices: Optional[array] = None,
>                transpose: bool = True, group_size: Optional[int] = None,
>                bits: Optional[int] = None, mode: str = 'affine',
>                *, sorted_indices: bool = False, stream=None) -> array
> ```

The index semantics are the part people get wrong:

> ✅ **VERIFIED** — from the op docs, quoted at `notes/repos/mlx-core.md:927`:
> "*the indices `lhs_indices` and `rhs_indices` contain **flat indices along the batch dimensions**
> (i.e. all but the last two dimensions)*". `sorted_indices=True` "*may allow a faster
> implementation*". And, critically: "*`scales` and `biases` must have the same batch dimensions as
> `w`*".

Unpack that:

- **Flat batch indices, not element indices.** For an expert table `w` of shape `(E, N, K)`, the
  batch dimensions are just `(E,)`, so `rhs_indices` holds expert IDs in `[0, E)`. For a table
  with more leading dims, you index the *flattened* batch space.
- **`scales` and `biases` are indexed the same way.** They carry the same batch dimensions as `w`,
  so a single `rhs_indices` selects the weight slab and its metadata together. This is why you
  cannot quantize experts individually and stack the results with mismatched layouts.
- **`sorted_indices=True` is a promise, not a request.** You are telling the kernel your indices
  are already sorted so it can use a better implementation. §9.1 and §9.2 are both bugs in
  *exactly that* sorted path.

### 7.3 What mlx-lm builds on top

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1585`: `mlx_lm/models/switch_layers.py` provides
> `SwitchLinear`, `QuantizedSwitchLinear`, `SwiGLU`, `SwitchGLU`, `SwitchMLP`, `_gather_sort`,
> `_scatter_unsort`.

The `_gather_sort` / `_scatter_unsort` pair is the tell. The flow is: route → sort the token-expert
pairs so all rows for one expert are contiguous → call the sorted `gather_qmm` path → unsort back
into token order. Sorting is what makes `sorted_indices=True` legal, and it is also what makes the
row count `n = tokens × top_k` rather than `tokens` — a fact that turns out to matter enormously in
§9.1.

Two operational facts about MoE weight loading, both of which bite before you ever reach a kernel:

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:771`: "**`mlx_lm.load` with default
> `lazy=False` calls `mx.eval(model.parameters())`**, which materializes the full stacked
> `(num_experts, ...)` expert table at load time — an **18.2 GB spike on Qwen3.6-35B-A3B-4bit**
> *before a single token*. Use `load(lazy=True)` and drop the full-table references before anything
> forces their eval."
>
> ✅ **VERIFIED** — same source, `notes/repos/issues-mlx-stack.md:769`: "**A prefix slice of an
> `mx.array` is a view that pins the whole parent buffer**, so slicing does not actually free the
> rest of the table."

Those two together are why "just load the first N experts" does not work, and why MoE memory
engineering in MLX is about *not creating* the full table rather than about trimming it afterwards.

### 7.4 What routed-only reads are worth — community measurements

Here is the evidence that this design choice dominates everything else in MoE decode.

> ⚠️ **SOURCING** — the numbers in this subsection are **community-measured** by GitHub user
> `john-rocky` (Daisuke Majima / "rockyshikoku") in the `coreai-model-zoo` repository, recorded at
> `notes/repos/john-rocky-models.md:1275-1310` and `:2625-2627`. They are **not Apple-published**.
> The repository is partly agent-generated and its own README ships a benchmark protocol; the
> research note flags it explicitly as unique-but-unofficial primary source material.
>
> **They were also measured on Core AI, not MLX.** The zoo was fixing *Core AI's* stock `GatherMM`
> lowering, which "gathers then runs a DENSE matmul — it does **NOT** read only the routed experts,
> so MoE decode is over-read-bound, not active-param-bound." The fix was a hand-written
> `coreai_torch.TorchMetalKernel` matvec that "takes the routed expert indices as a kernel INPUT and
> reads ONLY the top-k experts' weight slabs (`QP[w,n,e]`, `e = IDX[slot]` — indexed global load;
> the other E−k experts are never fetched)."
>
> **Why it belongs in an MLX guide anyway:** that is precisely what `mx.gather_qmm` already does.
> These numbers are the cleanest available measurement of *what the routed-only gather is worth*,
> because someone measured a system with it against the same system without it, on the same
> hardware, on the same weights.

Measured on **M4 Max**:

| Config | Decode | Bundle size | Note (verbatim from the source) |
|---|---:|---:|---|
| LFM2.5-8B-A1B, int8 MoE, stock `GatherMM` | 39 tok/s | 8.8 GB | over-read bound |
| LFM2.5-8B-A1B, int8 MoE, `gather_qmm` kernel | **141 tok/s** | — | **3.6×**, reads 4/32 experts |
| LFM2.5-8B-A1B, int4km, `gather_qmm` | 162.7 tok/s | **4.7 GB** | iPhone-jetsam-safe |
| Qwen3.6-35B-A3B (256 experts / top-8), stock `GatherMM` | 30.9 tok/s | — | *"32× expert over-read"* |
| Qwen3.6-35B-A3B, `gather_qmm` kernel | **64.9 tok/s** | — | **2.1×**; MLX on the same box was ~55–70, so this reaches **rough parity with MLX** |
| GLM-4.7-Flash (MoE + MLA), stock → `gather_qmm` | 20.3 → **52.4** tok/s | — | 2.6×; MLA on all 47 layers keeps it below Qwen3.6 |

And on **iPhone 17 Pro (A19 Pro), GPU**:

| Config | Decode | Size | Note |
|---|---:|---:|---|
| LFM2.5-8B-A1B int4km MoE, `gather_qmm` | **~32 tok/s** | 4.7 GB | *"the zoo's first iPhone MoE on hardware"* |

Three readings of this table, in increasing order of usefulness:

**1. The naive one: gather kernels are fast.** True but shallow.

**2. The mechanical one: the win is proportional to `E / top_k`.** Qwen3.6 is 256 experts at top-8
— a 32× over-read — and got 2.1×. LFM2.5 is 32 experts at top-4 — an 8× over-read — and got 3.6×.
The wins are *not* proportional to the over-read ratio, because both configurations are already
partly bounded by other things (attention, the dense path, dispatch). What the ratio tells you is
the *headroom*, not the outcome.

**3. The one that changes decisions: it is a size story as much as a speed story.** The int4
variant at 4.7 GB is what made an 8B-class MoE fit on an iPhone at all. On device, the binding
constraint is usually the jetsam limit, not the clock.

There is a fourth number in the same source that is genuinely surprising and worth its own callout:

> ✅ **VERIFIED** (community-measured, M4 Max) — `notes/repos/john-rocky-models.md:1283-1292`,
> the same LFM2.5-8B-A1B on the **stock** dense-gather path:
>
> | Scheme | Decode | Bundle | Effective bandwidth | Interpretation |
> |---|---:|---:|---:|---|
> | int8 | 39 tok/s | 8.8 GB | 345 GB/s | ≈ full-read, bandwidth-saturated |
> | int4 | **170 tok/s** | 5.0 GB | **848 GB/s** (*above* physical bandwidth) | ⇒ int4 is **not** full-reading |
>
> *"dropping a MoE to int4 buys ~4× decode here, not the ~2× the byte ratio predicts — but non-QAT
> int4 flips structural tokens (broken grammar), so int8 stays the quality floor."*

An "effective bandwidth" above the machine's physical bandwidth is a proof by contradiction: the
implementation cannot be reading every expert. Halving the bits changed the *access pattern*, not
just the byte count. **When a quantization change buys you more than the byte ratio predicts, stop
and find out what else changed** — you are usually looking at a different kernel, not a faster one.

### 7.5 The quality lever in MoE is the expert scheme, not the gather

One more finding from the same community source, because it reverses an intuition and the source
is unusually careful about it — including retracting its own earlier claim.

> ✅ **VERIFIED** (community-measured) — `notes/repos/john-rocky-models.md:1310-1337`.
>
> The gather kernel itself is exact: *"kernel == 'select-from-all' bit-for-bit."* So quality is set
> entirely by the expert quantization scheme. On a 41-token paragraph, gated against an fp32
> oracle:
>
> | Scheme | Token flips / 41 | Verdict |
> |---|---:|---|
> | symmetric-linear int8, per-K-block-32 scale | **+1** (at the fp16 ceiling) | clean |
> | k-means int8 | +5 | *"lossier — don't use"* |
> | k-means int4 | +12 | wall |
> | affine-block-32 int4 | +11 | wall |
>
> The source **retracts an earlier claim** in the same document: *"(An earlier 'fp16-faithful'
> claim was WRONG — held only on a degenerate loop-y prompt; the gather kernel's QUALITY is set by
> the expert quant scheme, not the gather.)"*
>
> **And then it reverses the ranking for top-1 routing** (ZAYA1-8B, 2026-06-22): *"'sym8 not
> k-means' holds for top-k ≥ 4, REVERSES for top-1. … each token's FFN output is a weighted sum of
> k experts so expert-quant error **AVERAGES (~/√k)** and even crude linear int8 survives. ZAYA is
> top-1 of 16: one token → one expert, error NOT averaged → sym8 (linear) collapses … while km8
> (k-means int8, 256-entry codebook) recovers fp16 quality."*

The mechanism transfers to MLX directly even though the schemes do not map one-to-one:

> **Quantization error in a top-k MoE averages down by roughly √k.** A top-8 model tolerates
> per-expert error that a top-1 model does not. If you are quantizing a low-`k` or top-1 MoE, treat
> it like a dense model — use more bits — and do not carry over a configuration that worked on a
> top-8 model.

MLX's counterpart of "protect the sensitive part" is the per-model `quant_predicate` (§3.6), and
gpt-oss's choice to give the **router** 8 bits at group 64 is the same instinct applied one level
up: protect the discrete decision, then let the averaged arithmetic absorb the rest.

### 7.6 Making a MoE layer with the array API

If you are building your own MoE rather than using mlx-lm's, this is the shape:

```python
"""A minimal quantized MoE expert bank built directly on mx.gather_qmm."""
import mlx.core as mx
import mlx.nn as nn


class QuantizedExpertBank(nn.Module):
    """E experts of shape [N, K], quantized together, dispatched by index.

    Weights are stored [E, N, K] so that transpose=True is satisfied and the
    NAX gather kernels (BK = 64) are reachable. K must be a multiple of 64
    AND a multiple of group_size.
    """

    def __init__(self, num_experts: int, in_dims: int, out_dims: int,
                 *, group_size: int = 64, bits: int = 4, mode: str = "affine"):
        super().__init__()
        if in_dims % group_size:
            raise ValueError(
                f"in_dims={in_dims} must be divisible by group_size={group_size}"
            )
        if in_dims % 64:
            raise ValueError(
                f"in_dims={in_dims} must be a multiple of 64 for the NAX gather path"
            )
        self.group_size = group_size
        self.bits = bits
        self.mode = mode
        self.num_experts = num_experts

        w = mx.random.normal(shape=(num_experts, out_dims, in_dims)) * (in_dims ** -0.5)
        q = mx.quantize(w.astype(mx.bfloat16), group_size, bits, mode)
        self.weight, self.scales = q[0], q[1]
        if len(q) > 2:
            self.biases = q[2]
        self.freeze()   # packed uint32 weights are not differentiable

    def __call__(self, x: mx.array, expert_indices: mx.array) -> mx.array:
        """x: [n, K] rows already sorted by expert. expert_indices: [n] int32."""
        return mx.gather_qmm(
            x, self.weight, self.scales, self.get("biases", None),
            lhs_indices=None,
            rhs_indices=expert_indices,
            transpose=True,
            group_size=self.group_size,
            bits=self.bits,
            mode=self.mode,
            sorted_indices=True,     # ONLY if you actually sorted. See section 9.
        )
```

Two comments in that listing are load-bearing:

- **`sorted_indices=True` is a claim about your data.** If your indices are not sorted the result
  is not merely slower. And even when they *are* sorted, the sorted path is where both open
  corruption bugs live — read §9.1 and §9.2 before enabling it on M5 hardware.
- **`self.freeze()`** mirrors what `nn.QuantizedLinear` does in its own `__init__`
  (✅ `notes/repos/mlx-core.md:849`). Packed weights cannot receive gradients.

> 🔴 **GAP** — the exact expected **shape and dtype of `rhs_indices`** (int32 vs uint32, and the
> permitted rank) is not pinned down in the notes beyond "flat indices along the batch dimensions".
> Nor is the interaction between `lhs_indices` and `rhs_indices` when both are given. Resolving this
> needs `python/tests/test_quantized.py` or the C++ validation in `mlx/ops.cpp` read directly.
> **Safe default: pass a 1-D `int32` array of length `n` for `rhs_indices` and `None` for
> `lhs_indices`**, which is the MoE-decode shape and the one mlx-lm's `SwitchLinear` exercises.

---

## 8. Learned quantization: AWQ, GPTQ, DWQ, dynamic

Everything so far has been **round-to-nearest**: take the weight, compute min and max per group,
round. That is what `mx.quantize` does and it is the right default. It is also, below about 4 bits,
not good enough — because it minimises the error in the *weights*, and nobody cares about the
weights. What matters is the error in the *outputs*.

mlx-lm ships four pipelines that fix that, each with a different theory of what to optimise.

### 8.1 The four, in the maintainers' own words

> ✅ **VERIFIED** — quoted verbatim from `mlx_lm/LEARNED_QUANTS.md`, recorded at
> `notes/repos/mlx-lm.md:1113-1120`:
>
> > DWQ fine-tunes non-quantized parameters (including quantization scales and biases) using the
> > non-quantized model as a teacher. AWQ scales and clips the weights prior to quantization.
> > Dynamic quantization estimates the sensitivity of a model's outputs to each layer and uses a
> > higher precision for layers which have higher sensitivity. GPTQ finds quantized weights which
> > minimize the squared error of each layer's output given the provided input.
> > … Dynamic quantization is the fastest to run. DWQ takes longer but typically yields better
> > results. **You can also cascade methods.**

That last sentence is easy to skim past and is the most actionable thing in the paragraph. These
are not four alternatives; they compose.

**Prerequisite for all four:** `pip install "mlx-lm[train]"`
(✅ `notes/repos/mlx-lm.md:1122`).

**They all share one calibration corpus:**

> ✅ **VERIFIED** — `mlx_lm/quant/utils.py`, quoted at `notes/repos/mlx-lm.md:1124-1130`:
>
> ```python
> save_dir = Path.home() / ".cache/mlx-lm/calibration_v5.txt"
> url = ("https://gist.githubusercontent.com/tristandruyen/9e207a95c7d75ddf37525d353e00659c/"
>        "raw/571fda718462de863e5a0171078c175420c7649a/calibration_data_v5_rc.txt")
> ```
>
> Downloaded once, tokenized, chunked into non-overlapping `sequence_length` blocks, randomly
> permuted.

Note what that means operationally: **the first learned-quantization run on a fresh machine hits
the network**, and the corpus is a community gist rather than something versioned inside mlx-lm. If
you are quantizing in CI or on an air-gapped box, pre-seed `~/.cache/mlx-lm/calibration_v5.txt`.

### 8.2 The CLI entry points

> ✅ **VERIFIED** — console scripts registered by the mlx-lm wheel
> (`notes/repos/mlx-lm.md:99-102`):
>
> ```
> mlx_lm.awq           = mlx_lm.quant.awq:main
> mlx_lm.dwq           = mlx_lm.quant.dwq:main
> mlx_lm.dynamic_quant = mlx_lm.quant.dynamic_quant:main
> mlx_lm.gptq          = mlx_lm.quant.gptq:main
> ```

### 8.3 DWQ — distillation-aware, the quality leader

**Theory.** Freeze the quantized weights, treat the *scales and biases* as trainable parameters,
and fine-tune them to match the full-precision model's output distribution. You are not changing
which codes the weights map to; you are moving the codebook.

> ✅ **VERIFIED** — `quant/dwq.py` (428 lines), recorded at `notes/repos/mlx-lm.md:1132-1158`.
>
> ```bash
> mlx_lm.dwq --model Qwen/Qwen3-0.6B
> mlx_lm.dwq --model Qwen/Qwen3-8B --bits 3 --group-size 32 --batch-size 1 --max-seq-length 512
> ```
>
> Actual argparse defaults: `--model/-m` (**required**), `--quantized-model` (None), `--mlx-path`
> (`mlx_model`), `--bits` (**4**), `--group-size` (**64**), `--num-samples` (**2048**),
> `--max-seq-length` (**1025**), `--seed` (123), `--learning-rate` (**1e-6**), `--batch-size`
> (**4**), `--data-path` (`allenai/tulu-3-sft-mixture`), `--grad-checkpoint`, `--target-dir`,
> `--targets-only`, `--pipeline`, `--trust-remote-code`.

The mechanics are worth reading because they explain the method's limits:

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1144-1156`:
>
> - It unfreezes **only** the quantization parameters of affine, sub-8-bit layers:
>   ```python
>   if hasattr(m, "bits") and hasattr(m, "group_size") and m.mode == "affine" and m.bits < 8:
>       m.unfreeze(keys=["scales", "biases"], recurse=False)
>   ```
> - Loss is `kl_div_loss(scale*logits, scale*targets)` with `scale = 1/temperature`,
>   `temperature = 2.0`.
> - Optimizer `optimizers.Adam(learning_rate=args.learning_rate, bias_correction=True)`; parameters
>   are accumulated in `float32` and applied back as `bfloat16`.
> - Optional precomputed targets: with `--target-dir` it saves top-1024 logits + indices per batch
>   as `{i:010d}.safetensors` (`--targets-only` computes and exits), which lets the teacher be
>   freed. `has_targets` requires actual `*.safetensors` in **both** `train/` and `valid/`
>   (fix `f39cb8e`).
> - Validation every 200 iterations, with a final warning if it regressed:
>   `"❌❌❌\n[WARNING] Final validation loss … is worse than initial validation loss …"`.

Read the unfreeze condition again: **`m.mode == "affine" and m.bits < 8`.**

> ⚠️ **SILENT FAILURE**
>
> **DWQ silently does nothing to an `mxfp4`, `mxfp8` or `nvfp4` model, and nothing to an 8-bit
> affine model.** The condition `m.mode == "affine" and m.bits < 8` is a filter, not an assertion —
> layers that fail it are simply never unfrozen. The run completes, prints losses, and writes a
> checkpoint that is byte-equivalent in its quantization to what you started with.
>
> This is consistent with the method (the fp modes have no bias to train, and 8-bit has nothing to
> fix), but the failure presentation is wrong: you get a successful-looking training run instead of
> an error.
>
> **Detection:** DWQ's own doc says the quiet part out loud — *"works best 2–4 bit; 16→8/6 bit
> often doesn't work well"* (`notes/repos/mlx-lm.md:1157`). If you ran DWQ and the evaluation is
> identical to the round-to-nearest baseline to the last digit, check your `--bits` and your mode
> before you conclude the method does not work.
>
> **The other half of the same guard is a genuine feature:** the final-validation warning
> (`"❌❌❌ … is worse than initial validation loss"`) means DWQ *can* make a model worse and tells
> you when it did. Do not ignore that line in a CI log.

**Tuning tips from the doc** (✅ `notes/repos/mlx-lm.md:1157-1158`): `--group-size 32` doubles the
number of tunable parameters; distil from an **8-bit teacher** rather than the bf16 original to
save memory; `--max-seq-length 512` to fit.

### 8.4 AWQ — scale and clip before quantizing

**Theory.** Some weight channels matter more than others, and which ones is determined by the
*activations* they see. Scale those channels up before quantizing (so they get more of the group's
dynamic range), fold the inverse scale into the preceding operation so the maths is unchanged, then
quantize. Then clip the ranges to trade a little max-error for a lot of mean-error.

> ✅ **VERIFIED** — `quant/awq.py` (595 lines), recorded at `notes/repos/mlx-lm.md:1160-1193`.
>
> ```bash
> mlx_lm.awq --model Qwen/Qwen3-0.6B
> ```
>
> Actual defaults: `--model/-m` (`mlx-community/Qwen2.5-7B-Instruct-bf16`), `--mlx-path`
> (`mlx_model`), `--bits` (**4**), `--group-size` (**64**), `--embed-bits` (**4**),
> `--embed-group-size` (**32**), `--num-samples` (**128**), `--sequence-length` (**512**),
> `--n-grid` (**20**), `--seed` (123), `--trust-remote-code`.

**The hard limit — read this before you plan a run:**

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1169-1171`. `AWQ_MODEL_CONFIGS` supports **only**:
> `llama`, `mistral`, `qwen2`, `qwen3`, `gemma3_text`, `gemma3`, `deepseek_v2`.
> Anything else raises `NotImplementedError(f"AWQ support for {model_type} models NYI.")`.

Seven architectures. That is the whole list. **AWQ is not a general tool in mlx-lm**; it needs
hand-written per-architecture configuration describing which linears share a scale and what op
precedes them:

> ✅ **VERIFIED** — the config dataclasses, `notes/repos/mlx-lm.md:1174-1184`:
>
> ```python
> @dataclass
> class ScaleConfig:
>     prev: nn.Module; layers: list[nn.Module]; block: nn.Module | None = None
>     kwargs: list = field(default_factory=list); use_config: Callable | None = None
>
> @dataclass
> class AWQConfig:
>     embed: str; lm_head: str; no_clip: list[str]
>     scale_configs: list[ScaleConfig]; lm_key: str | None = None
> ```

The algorithm per transformer block:

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1185-1193`: capture per-linear `input_feat` with a
> `Catcher` module → quantize without AWQ to get a reference loss → grid-search scales
> (`scales = max(x_max**ratio, 1e-4)`, normalised by `sqrt(max*min)`, `ratio = i/n_grid`) → fold
> the scales into the previous op (`apply_scale` handles `Linear`/`SwitchLinear`,
> `LayerNorm`/`RMSNorm`, and Gemma-style RMSNorm with the `1 + w` convention) → per-group clip
> search (`max_shrink=0.5`, `n_frames=512` subsampled activations) → requantize.
>
> **If `after_loss > before_loss` it reverts**: *"Loss is not reduced, falling back to original
> weights."* Progress prints `Loss reduction: {after/before}` per block. Distributed-aware via
> `mx.distributed.all_sum` and `dist_split`.

The per-block revert is a genuinely good design: AWQ cannot make a block worse than
round-to-nearest, because it checks. Watch the `Loss reduction:` line — a run where most blocks
print ≈1.0 is a run where AWQ found nothing, and you should reach for DWQ or GPTQ instead.

Note `--embed-bits 4` / `--embed-group-size 32` as separate knobs. Embeddings get their own
treatment because their access pattern (one row per token) and their error propagation are unlike
a projection's.

### 8.5 GPTQ — minimise each layer's output error

**Theory.** For each linear, accumulate the Hessian of its output error with respect to its
weights over calibration data, then quantize columns one at a time, propagating each column's
rounding error into the not-yet-quantized columns so it can be compensated.

> ✅ **VERIFIED** — `quant/gptq.py` (239 lines), recorded at `notes/repos/mlx-lm.md:1195-1207`.
>
> ```bash
> mlx_lm.gptq --model Qwen/Qwen3-0.6B
> ```
>
> Defaults: `--model/-m` (`Qwen/Qwen3-0.6B-base`), `--mlx-path` (`mlx_model`), `--bits` (**4**),
> `--group-size` (**64**), `--fallback-bits` (**6**), `--fallback-group-size` (**64**),
> `--num-samples` (**-1 = all**), `--sequence-length` (**512**), `--seed` (123),
> `--trust-remote-code`.
>
> - `assert bits in {2, 4, 8}, f"Unsupported bits {bits}"` — **note this is narrower than
>   `mx.quantize`'s `{2,3,4,5,6,8}`.** No 3, 5 or 6-bit GPTQ.
> - Hessians accumulated with a `Catcher` (`self.H = self.H + xf.T @ xf`), damped with
>   `1e-2 * mean(diag(H))`, inverted with `mx.linalg.cholesky` / `cholesky_inv` **on the CPU
>   stream** (`with mx.stream(mx.cpu)`).
> - Applies only to `nn.Linear` / `SwitchLinear`; **everything else quantizable gets the fallback
>   config** (6 bits, group 64 by default).

Two details worth pausing on.

**The Cholesky runs on the CPU stream.** That is a deliberate `with mx.stream(mx.cpu)`, and it is a
nice illustration of MLX's unified-memory model: the same arrays, a different device, no copies.
Linear algebra with tight conditioning behaves better in the CPU path; the rest of the pipeline
stays on GPU.

**The fallback is not a fallback, it is a policy.** Anything that is not a `Linear` or a
`SwitchLinear` — embeddings, output heads depending on the model, anything exotic — silently gets
`--fallback-bits` (6) at `--fallback-group-size` (64). If you run GPTQ at `--bits 4` and your model
comes out at 4.9 bits per weight, that is why. It is not a bug; it is `--fallback-bits` doing its
job on more layers than you expected. Set it explicitly.

### 8.6 Dynamic quantization — spend bits where they matter

**Theory.** Measure how much the model's output changes when each layer is quantized more coarsely,
then assign high bits to sensitive layers and low bits to the rest, subject to a total budget.

> ✅ **VERIFIED** — `quant/dynamic_quant.py` (268 lines), recorded at
> `notes/repos/mlx-lm.md:1209-1223`.
>
> ```bash
> mlx_lm.dynamic_quant --model Qwen/Qwen3-0.6B --target-bpw 4.8
> ```
>
> Defaults: `--model/-m` (`Qwen/Qwen3-0.6B-base`), `--mlx-path` (`mlx_model`), `--seed` (123),
> `--sensitivities` (path to a precomputed JSON), `--target-bpw` (**5.0**), `--low-bits` (**4**),
> `--low-group-size` (**64**), `--high-bits` (**5**), `--high-group-size` (**64**), `--report-ppl`,
> `--grad-checkpoint`, `--accumulation-dtype` (`float32` | `bfloat16`), `--trust-remote-code`.
>
> - Sensitivity metric:
>   `(accumulated_grad * (low_q_weight - high_q_weight)).sum() / (n_params / 1e6)`, where the
>   gradients are of `kl_div_loss(q_model(batch), model(batch))`.
> - Writes `{model.replace("/","_")}_sensitivities.json` for reuse.
> - The threshold is found by **binary search** on bits-per-weight down to
>   `tolerance = 1e-3 * (max_sens - min_sens)`.

And the constraint that explains most confused bug reports about it:

> ✅ **VERIFIED** — from the doc, `notes/repos/mlx-lm.md:1222-1223`: *"For a given set of
> quantization parameters only certain ranges are possible. For example, with the default
> parameters a BPW in the range `[4.5, 5.5]` is achievable."*

`--target-bpw` is **not** a free dial. With `--low-bits 4 --high-bits 5` at group 64 you can reach
[4.5, 5.5] — the two endpoints of §3.1's table — and nothing outside it. Asking for 3.8 with those
settings cannot succeed. Widen the low/high pair first (`--low-bits 3 --high-bits 6`), then set
your target.

**The sensitivity JSON is the real product of a dynamic-quant run.** It costs gradient computation
over the calibration set; the bit assignment afterwards is cheap. Cache it (`--sensitivities`) and
reuse it while you sweep `--target-bpw`.

### 8.7 When the extra step pays

Putting the four side by side:

| Method | Optimises | Cost to run | Bit range where it earns its keep | Architecture limits |
|---|---|---|---|---|
| **round-to-nearest** (`mx.quantize`) | weight error | free | 6–8 bits | none |
| **dynamic** | allocation of bits across layers | **cheapest of the four** (doc: *"fastest to run"*) | anywhere you have a bpw budget | none stated; needs `--low/--high` to bracket your target |
| **GPTQ** | per-layer output squared error | one Hessian per linear + a Cholesky | 2–4 bits | `bits ∈ {2,4,8}` only; non-Linear gets the fallback |
| **AWQ** | activation-aware channel scaling + clipping | grid search per block (`--n-grid 20`) | 3–4 bits | **7 model types only** |
| **DWQ** | the codebook itself, against a teacher | **most expensive** (a real training loop) | doc: *"works best 2–4 bit"* | affine + `bits < 8` only |

**A decision rule that matches what the code supports:**

- **8 bits or 6 bits:** do nothing. Round-to-nearest. None of these methods has anything to fix and
  DWQ will silently no-op (§8.3).
- **5 bits:** dynamic quantization, if you have a budget to hit. Otherwise plain.
- **4 bits, supported architecture:** AWQ. It is bounded-loss by construction (it reverts blocks it
  makes worse) and it is much cheaper than DWQ.
- **4 bits, unsupported architecture:** GPTQ, or dynamic with `--low-bits 4 --high-bits 6`.
- **3 bits and below:** DWQ, and expect to spend real time. The doc's own example is
  `--bits 3 --group-size 32 --batch-size 1 --max-seq-length 512`, which tells you the memory
  profile.
- **Cascading:** the doc explicitly allows it. The natural order is AWQ or GPTQ first (they change
  *which* codes the weights take), then DWQ on the result (it moves the codebook). DWQ's
  `--quantized-model` flag exists to take an already-quantized model as input.

### 8.8 Evaluate, then upload

> ✅ **VERIFIED** — `notes/repos/mlx-lm.md:1225-1230`:
>
> ```bash
> mlx_lm.evaluate --model mlx_model \
>   --tasks winogrande boolq arc_challenge arc_easy hellaswag openbookqa piqa social_iqa
>
> mlx_lm.upload --path mlx_model \
>   --upload-repo mlx-community/Mistral-7B-Instruct-v0.3-3bit-DWQ
> ```

That eight-task list is the one mlx-lm's own docs use for post-quantization evaluation. It is a
reasonable default battery precisely because it is multiple-choice: it measures whether the model
still *ranks* the right continuation, which is what quantization damages first.

But run §10's differential check as well. Benchmark deltas of a point or two are within noise
between runs; a corrupted kernel is not.

---

## 9. ⚠️ The corruption bugs

This is why the guide exists.

Between 2026-06 and 2026-07-27 the MLX quantized-matmul kernels accumulated a cluster of
correctness defects. Some are fixed, some are open, and the worst of them **does not produce wrong
arithmetic — it produces no arithmetic at all**, leaving output rows unwritten and exposing whatever
the recycled Metal buffer last held. Sometimes that is obviously garbage. Sometimes it is
coincidentally plausible. That is the whole problem.

**Status legend.** Every entry below is marked with its state *as of 2026-08-03* (re-checked
against live GitHub via `gh` on 2026-08-03; the notes behind this section were taken 2026-07-27).
Statuses move. Check the issue before you rely on this table.

| # | Defect | Issue / PR | Status 2026-08-03 | Affects |
|---|---|---|---|---|
| 9.1 | affine `gather_qmm` int16 overflow → **unwritten rows** | mlx**#3856** → PR **#3922** | issue **closed completed**, fix PR **merged 2026-08-26** | affine MoE, M5/NAX only |
| 9.2 | `gather_qmm` sorted-rhs `K % 64 != 0` tail | mlx**#3887** → PR **#3922** | issue **closed completed 2026-09-07**, fix PR **merged 2026-08-26** | affine **and mxfp4** MoE, M5/NAX only |
| 9.3 | `nvfp4` split-K → ~2× error, `NaN`/`inf` | PR **#3854** | **MERGED 2026-07-22** | nvfp4 dense matmul |
| 9.4 | fp quantized matmul, quantized dim not a multiple of 32 | PR **#3912** | **OPEN** (opened 2026-07-24) | nvfp4 (group 16); GPU matrix path, **not** NAX-only |
| 9.5 | fp quantized matvec, output dim < 8 | PR **#3804** | **MERGED** | mxfp4 matvec |
| 9.6 | `tile_matmad_nax` missing `else` → silent no-op for odd tile shapes | PR **#3924** | **CLOSED unmerged** 2026-08-02, declined | all NAX GEMM |
| 9.7 | `nvfp4` `global_scale` unimplemented on Metal | mlx**#3911** → PR **#3757** | **CLOSED** 2026-08-05; fix merged 2026-08-04, ships in **0.32.1** — on ≤ 0.32.0 it **throws**, does not corrupt | nvfp4 on Apple silicon, mlx ≤ 0.32.0 |

Read the last column carefully. **Five of the seven are M5-generation-only.** On an M1 through M4
machine most of this section is history rather than a hazard — but "most" is not "all", and the
`nvfp4` split-K bug (9.3) was not NAX-gated.

### 9.1 The bad one: affine `gather_qmm` leaves rows unwritten — mlx#3856

**Status: issue closed completed and fix PR #3922 merged, 2026-08-26.**

> ✅ **VERIFIED** — mlx#3856 (closed completed 2026-08-26; 9 comments), summarised at
> `notes/repos/issues-mlx-stack.md:379-427`.
>
> **Trigger, stated precisely:** flattened gathered row count `n` with **`n > 32768` AND
> `n % 64 != 0`**, on the **sorted-indices `gather_qmm` path**, in **affine** mode, **NAX-only**
> (M5-generation GPU on macOS 26.2+). *"The bug cannot be reproduced on M1–M4 hardware."*

**Why the trigger looks like three different bugs.** In an MoE forward, `n = tokens × top_k`. So
the same defect presents as `tokens % 32` at top_k=2 and as `tokens % 16` at top_k=4 — which is why
early reports disagreed with each other:

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:383`: "In an MoE forward `n = tokens × top_k`,
> which unifies earlier reports: at top_k=2 it looks like `tokens % 32`, at top_k=4 like
> `tokens % 16` — **the invariant is row alignment, not sequence length.**"

**The root cause** is four lines of Metal:

> ✅ **VERIFIED** — `mlx/backend/metal/kernels/quantized_nax.h#L1532-L1535` (commit `b7c3dd6d`),
> quoted at `notes/repos/issues-mlx-stack.md:385-394`:
>
> ```c++
> const short sgp_sm =
>     align_M ? SM : min(SM, short(max(0, (M - (y_row + tm)))));
> const short sgp_sn =
>     align_N ? SN : min(SN, short(max(0, (N - (y_col + tn)))));
> ```
>
> "`M - (y_row + tm)` … is cast to `short` **before** the `min`. When `align_M == false`
> (`n % 64 != 0`, `BM = 64`) and a tile sits ≥ 32768 rows from the end, the cast wraps negative; a
> negative `sgp_sm` zeroes the A-tile and the store path stores nothing. Those output rows are
> **never written** and expose stale allocator memory."

`short` is 16-bit. 32768 is 2^15. That is the entire bug.

> ⚠️ **SILENT FAILURE**
>
> **Unwritten output rows do not read as zeros or NaNs. They read as whatever the recycled
> `MTLBuffer` last contained.** From the fix PR's own regression-test note:
>
> > ✅ **VERIFIED**, `notes/repos/issues-mlx-stack.md:425`: *"unwritten rows hold whatever the
> > recycled MTLBuffer last contained, which is sometimes coincidentally plausible. A regression
> > test should poison the output buffer (or compare two runs) rather than trust one lucky read."*
>
> There is no exception, no NaN, no obviously-wrong magnitude to trip an assertion. A model
> generates fluent text that is subtly wrong — different reasoning, different tool call, different
> answer — with every other signal healthy.
>
> **This is the single most important sentence in this guide: a single-run comparison against a
> reference can pass by luck.** §10.4 gives you the poisoning recipe that turns it deterministic.
>
> The PR author's own security framing, which is the right one:
> > *"this can leave tensor rows unwritten and expose contents reused from MLX's same-process Metal
> > allocator pool. … We found no cross-process disclosure, arbitrary code execution, sandbox
> > escape, or other trust-boundary crossing, so this is a correctness bug rather than a
> > cybersecurity vulnerability."* (`notes/repos/issues-mlx-stack.md:427`)
>
> Same-process only. But if your process also holds user data in MLX arrays, "same process" is not
> nothing.

**The measurements**, which show exactly how the trigger behaves:

> ✅ **VERIFIED** — measured on **M5, mlx 0.32.0**, `notes/repos/issues-mlx-stack.md:400-406`:
>
> ```
> mode=affine bits=4 n=32768 (n%64= 0): max|err|=0.0078  bad rows=0/32768
> mode=affine bits=4 n=32802 (n%64=34): max|err|=16.9303  bad rows=64/32802
> mode=affine bits=4 n=40002 (n%64= 2): max|err|=21.7688  bad rows=7264/40002
> mode=affine bits=8 n=32802 (n%64=34): max|err|=16.5858  bad rows=64/32802
> mode=mxfp4  bits=4 n=32802 (n%64=34): max|err|=0.0077   bad rows=0/32802
> ```

Note the last line. **`mxfp4` is clean for this bug.** That is not luck:

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:396`: "#3631 fixed the identical pattern in
> three sibling kernels (`fp_qmm_t_impl`, the fp gather-rhs kernel, and affine `qmm_t_nax_tgp_impl`)
> but **missed this fourth site** — which is exactly why **mxfp4 tests clean while affine
> corrupts**. A twin lurks in `sgp_sn` (needs `N > 32768`)."

So the fp modes were patched in a previous round (PR **#3631**, MERGED 2026-06-05, "Fix int16
overflow in NAX qmm edge-tile bounds") and affine's gather kernel was overlooked. **And there is a
known un-triggered twin** in the `N` dimension, which would need an output dimension above 32768 —
uncommon but not impossible for a large `lm_head`.

**Model-level blast radius**, which is what makes this a shipping problem rather than a curiosity:

> ✅ **VERIFIED** — measured on **M5**, one-shot versus 2048-chunked prefill, N=16068,
> `notes/repos/issues-mlx-stack.md:408-419`:
>
> | model | expert quant mode | max logit diff | argmax |
> |---|---|---:|---|
> | Qwen3-Coder-30B-A3B-Instruct-8bit | affine 8-bit | 7.4 | **diverged** |
> | Qwen3-Coder-Next-MLX-4bit | affine 4-bit | 10.8 | **diverged (37/64)** |
> | Qwen3-Next-80B-A3B-Instruct-4bit | affine 4-bit | 3.3 | **diverged** |
> | Laguna-XS-2.1-8bit | affine 8-bit | 17.8 | **diverged (60/64)** |
> | DeepSeek-V2-Lite-Chat-4bit (MLA) | affine 4-bit | 6.7 | survived |
> | Nemotron-Super-120B-5bit (hybrid) | affine 5-bit | 7.1 | survived |
> | gpt-oss-20b | mxfp4 | 0.34 | ok |
> | Qwen3-Coder-Next abliterated mxfp4-gs32 | mxfp4 | 1.28 | ok |

**Every affine MoE in that table diverged at the argmax.** "Diverged at the argmax" means a
different token was selected — not a rounding difference, a different generation. And note that
**8-bit is not protection**: Laguna-XS at 8 bits has the worst logit delta in the table. The bug is
about tile bounds, not about precision.

**What to do about it right now:**

> ✅ **VERIFIED** — the two fixes in flight, `notes/repos/issues-mlx-stack.md:421-423`:
>
> - **Downstream:** mlx-lm PR **#1585**, "switch_layers: pad sorted gather rows to a multiple of
>   64" — described as *provably output-neutral* (the unsort indexes only original rows); closed
>   unmerged 2026-08-21.
> - **Upstream:** mlx PR **#3922**, "Fix sorted gather_qmm NAX boundary handling" — clamps the
>   remaining row/column counts in `int` before narrowing to `short`.
>
> Both were **OPEN** as of 2026-07-29; upstream #3922 merged 2026-08-26 and downstream #1585
> closed unmerged 2026-08-21.

Your options, in order of preference:

1. **Pin merge commit `d73eb752` or later on mlx main.** Released v0.32.2 predates the #3922 fix.
2. **Pad your gathered rows to a multiple of 64 yourself.** This is what mlx-lm PR #1585 does, and
   the reasoning that makes it safe is worth understanding: you append dummy rows to reach the
   alignment, run the gather, and then unsort using indices that only reference the original rows.
   The padding rows are computed and discarded. Output-neutral by construction.
3. **Use `mxfp4` for the expert weights.** Clean for *this* bug — but see §9.2, which is not.
4. **Chunk your prefill below the threshold.** `n = tokens × top_k > 32768` is the trigger, so a
   top-8 model needs prefill chunks under ~4096 tokens to stay below it. Fragile — it depends on
   `top_k` and it does nothing for the `n % 64` half — but it is a same-day mitigation.
5. **Run on M1–M4.** Genuinely a valid answer for a build machine or a test rig; the bug does not
   reproduce there.

### 9.2 The second, independent gather defect — mlx#3887

**Status: FIXED ON MAIN by PR #3922 (`d73eb752`); issue closed completed 2026-09-07.**

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:429-431`: "`gather_qmm` sorted-rhs path
> corrupt for **`K % 64 != 0`** on M5/NAX: `!align_K` tail bounds the load with `BK` instead of the
> K remainder. Two differences from #3856: the trigger axis is the **reduction dim**, and **mxfp4 is
> affected too** (wider blast radius). Root-caused by `jundot` in `omlx#2267`, verified on M5
> against 0.32.0."

This one closes the escape hatch from §9.1. **Switching your experts to `mxfp4` does not make you
safe if `K % 64 != 0`.**

It also gives §6.1's alignment gate a second, sharper reason to exist. Recall the two facts:

- The **dense** quantized path has a host-side gate at `quantized.cpp:787` / `:982`:
  `K % 64 == 0`, else fall back to a non-NAX kernel.
- The **gather** path is listed at `quantized.cpp:1327` for `transpose` only, and #3887 shows an
  in-kernel `!align_K` tail — i.e. the gather kernel *handles* a K remainder rather than declining
  the shape. And its handling is wrong.

> 🟡 **RECONSTRUCTED** — the inference that the gather path lacks the dense path's host-side
> `K % 64` bail-out. It follows from the two verified facts above (the alignment table lists
> `:1327` under `transpose` only, and #3887 describes an in-kernel `!align_K` branch), but I have
> not read `quantized.cpp:1327` directly. Treat the shape of the argument as right and the
> attribution to a specific line as provisional.

**Practical rule that covers both 9.1 and 9.2:** for any quantized MoE you intend to run on
M5-class hardware, **prefer an already-aligned `K % 64 == 0` shape** and, on releases through 0.32.2,
pad gathered rows to a multiple of 64. Those conditions sidestep both defect triggers. If the model's
native K is not aligned, padding is a correctness workaround with memory and compute cost — measure
it rather than describing it as a free conversion setting.[^k64-tradeoff]

### 9.3 `nvfp4` split-K — fixed, and the reason is instructive — PR #3854

**Status: MERGED 2026-07-22.**

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:433-449`: "`nvfp4` (`group_size == 16`)
> quantized matmuls taking the split-K path (`qmm_splitk` / `fp_qmm_t_splitk`) produced non-uniform
> ~2× error and `NaN`/`inf`. `affine` unaffected (group_size ≥ 32 keeps partitions ≥ BK)."
>
> Before:
> ```cpp
> split_k = std::min(split_k, K / group_size);
> while (split_k > 1 && (K % (split_k * group_size) != 0)) split_k--;
> ```
> After:
> ```cpp
> int k_align = group_size > 32 ? group_size : 32; // BK
> split_k = std::min(split_k, K / k_align);
> while (split_k > 1 && (K % (split_k * k_align) != 0)) split_k--;
> ```
>
> Example failure: `K=64, group_size=16 → split_k=4, k_partition_size=16 < BK=32`.

The lesson generalises well past this one bug: **`nvfp4`'s group size of 16 is smaller than every
kernel block constant in the system.** `BK` is 32 or 64; the group is 16. Any code path that
assumes "a group is at least as large as a block" is wrong for `nvfp4` and only for `nvfp4`. That
is a structural hazard, not a one-off, and it is a reason to treat `nvfp4` on Metal as the least
mature of the four modes — a judgement that §9.7 independently supports.

This one is **merged**, so an mlx build from after 2026-07-22 has it. It is in the table because
its *shape* — a mode-specific block-size assumption — is the kind of defect that recurs.

### 9.4 fp quantized matmul when the quantized dim is not a multiple of 32 — PR #3912

**Status: OPEN as of 2026-07-29, opened 2026-07-24.**

> ✅ **VERIFIED** — `notes/repos/mlx-tensorops-kernels.md:1994`: PR **3912**, 2026-07-24, OPEN:
> *"Fix fp quantized matmul corruption when the quantized dim is not a multiple of 32"*. Also
> listed among open mlx PRs at `notes/repos/issues-mlx-stack.md:1049`.

Same family, third alignment constant. Note that 32 is the block size of `mxfp4` and `mxfp8`, so
this is the fp modes' analogue of §9.2.

> ✅ **VERIFIED** — PR body read via `gh` on **2026-07-29** (PR still **OPEN**). The trigger is
> `K % 32 == 16`, which only **`nvfp4`** (group size 16) can legally produce — `mx.quantize`
> accepts `K = 1040`, and the fp quantized Metal kernels tile the quantized dim by 32 without
> bounding the 16-wide tail. Affected: the **GPU matrix path** of `quantized_matmul` /
> `gather_qmm` (`fp_qmm_t_impl` and siblings in `fp_quantized.h`, introduced with Metal nvfp4
> support in #2946). The CPU backend and the vector (decode) kernels handle the same shapes
> correctly — *"a model can decode perfectly and corrupt during prefill."* **Not NAX-only:** the
> PR's reproducer is an M3 Pro. Magnitude in that reproducer: max |err| ≈ 40, **72% of outputs
> wrong**, versus ~1e-3 on the aligned/CPU/vector paths.
> **Safe default until the PR merges:** keep dimensions that are *already* multiples of 64 aligned;
> for a legal non-aligned NVFP4 model, either pin a revision containing #3912's bounded-tail fix,
> route the affected matrix operation to the verified CPU path, or pad only after measuring the
> graph-wide cost. The PR's own `K = 1040` reproducer would need padding to 1088: 48 extra reduction
> elements, **4.6% more** weights and multiply work for every affected matrix, plus matching
> activation/adjacent-layer changes. Alignment covers several current bugs, but it is not free and
> it is not merely a quantizer switch.[^k64-tradeoff]

### 9.5 fp quantized matvec with output dim < 8 — PR #3804

**Status: MERGED.**

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:1043`: PR **#3804** "Fix fp quantized matvec
> for output dim < 8 (issue **#3762**: `fp_qmv_impl` used the raw scale byte instead of
> `dequantize_scale` → **wrong mxfp4 matvec for `out_vec_size < 8`**)."

Read the mechanism: the kernel used the raw `uint8_t` scale *as a number*, instead of
reinterpreting it through `dequantize_scale` (the function quoted in §2.4). That is the exact
failure mode §2.4 predicts you should watch for — the MX scale is a *bit pattern*, not an integer,
and any code path that forgets to decode it produces plausible-looking garbage rather than an
obvious explosion.

Small output dimensions are rare in transformer bodies but common in routers, gates and classifier
heads. This one is merged; it is here as a pattern to recognise.

### 9.6 `tile_matmad_nax` has no `else` — PR #3924

**Status: closed unmerged 2026-08-02, maintainer declined — the missing `else` is still at HEAD.**

> ✅ **VERIFIED** — `notes/repos/mlx-tensorops-kernels.md:1417-1428`: `tile_matmad_nax` picks
> between two `mma` overloads by tile shape at `steel/gemm/nax.h:847,865`. "**Note there is no
> `else`.** If `TN` is odd and not 1 (or `TN==1` with odd `TM`), `tile_matmad_nax` silently compiles
> to nothing and the GEMM produces garbage. Upstream PR **#3924** ('Add a tile-shape static_assert
> to `tile_matmad_nax`', open as of 2026-07-26) exists to fix exactly this."

This one is not specific to quantization — it is in the shared NAX GEMM machinery that the
quantized kernels feed into (see the pipeline diagram in §2.4). It is here for two reasons.

**First, it is the purest example of the failure class this whole guide is about.** A missing
`else` in a `if constexpr` chain is not a wrong answer; it is *no code*. The kernel launches, the
output buffer is whatever it was, and nothing anywhere reports a problem.

**Second, the fix is a `static_assert`.** That is the right fix, and it tells you the intended
contract: **tile shapes are supposed to be constrained, and the constraint was simply never
written down.** As long as you use MLX's own instantiations (tiles fixed at 64/64/64 with
`WM=WN=2`, per §6.1) you are inside the supported set. If you are writing your own kernels against
these headers — Part 11 territory — you are not, and you should assume the assert is not there yet.

### 9.7 `nvfp4` `global_scale` on Metal — mlx#3911

**Status: CLOSED 2026-08-05 — fixed by PR #3757 (merged 2026-08-04), shipped in mlx 0.32.1, as of
2026-08-23.** Covered in §2.6, including the closure context. It stays in this table for
completeness and as the counterexample: on ≤ 0.32.0, an unimplemented feature that raises
`std::runtime_error` is *the good outcome* — you find out immediately. Compare with everything
above it in this section. On 0.32.1+ the throw is gone and Metal takes the `qmv` fallback path
instead (basic support only; the maintainer's closing comment says not all fast kernels have it
yet).

### 9.8 Adjacent: two more silent-corruption knobs worth knowing

Neither is quantization, but both will contaminate a quantization investigation, so rule them out
first.

**`MLX_SDPA_BLOCKS` must be a multiple of 32.**

> ✅ **VERIFIED** — mlx PR **#3875** (MERGED 2026-07-22), `notes/repos/issues-mlx-stack.md:262-274`.
> The env var was added in #3455 and validated only for `> 0`, but pass-2 in `sdpa_vector.h`
> iterates `blocks / BN` with `BN = 32` and integer division:
>
> ```cpp
> for (int b = 0; b < blocks / BN; ++b) {
>   max_score = max(max_score, maxs[simd_lid + BN * b]);
> }
> ```
>
> *"Any other value silently corrupts the attention output on every decode step — no error, no
> clamp."* **On mlx ≤ 0.32.0, use a multiple of 32 or you get silently wrong attention.** Built-in
> choices are 32–1024, all multiples of 32.

**Batch-versus-single equivalence is not achievable on gen-17, in any dtype.**

> ✅ **VERIFIED** — mlx#3897 (closed 2026-08-09; 7 comments at snapshot), M5 base
> `applegpu_g17g` 32 GB, macOS 26.5.2 /
> 25F84, reproduced on mlx 0.31.2 **and** 0.32.0; M3 Max clean.
> `notes/repos/issues-mlx-stack.md:323-337`: `mlx-lm/tests/test_generate.py` fails 8 of 28 on
> `mx.allclose(batch_logprobs, single_logprobs)` at `rtol=1e-5`, with max |Δlogprob| ≈
> **0.031–0.039**; **argmax always matched**. Two independent mechanisms were separated in-thread:
> fp16/bf16 divergence traces to the NAX attention kernel (only the arch override
> `MLX_METAL_GPU_ARCH=applegpu_g16s` moves it), while fp32 divergence traces to TF32 in fp32 GEMM.
> **Takeaway: a strict `rtol=1e-5` batch-equivalence assertion cannot hold on gen-17.**

And a methodological warning from that same thread that belongs in every numerics investigation:

> ✅ **VERIFIED**, quoted from mlx#3897 at `notes/repos/issues-mlx-stack.md:335`: *"Your per-seed
> table shows the medians were hiding a 27-of-32 disagreement with a ten-seed tail up to 2^-13 …
> The median was the wrong statistic and I should not have leaned on it for a claim about a
> mechanism."*

**Use maxima and disagreement counts, not medians.** A median hides exactly the tail you are
hunting.

### 9.9 The one-paragraph summary you can act on

If you run **quantized MoE models on M5-generation hardware** on a release through mlx 0.32.2, you
are exposed to two independent silent-corruption defects (#3856, #3887), and the result is *plausible
wrong output*, not an error. Main after `d73eb752` fixes both defects; releases through 0.32.2
predate that merge. Prefer a native `K % 64 == 0`; otherwise choose a fixed revision, safe fallback,
or measured padding. On affected released builds, pad gathered rows to 64, and verify with §10
before every release.
If you run **dense quantized models on M1–M4**, essentially none of this section applies to you
today. Everyone should pin their mlx version, because the fixes and the regressions are landing in
the same weeks.[^k64-tradeoff]

---

## 10. The verification recipe

Given §9, "the model loads and produces fluent text" is not evidence of anything. Here is what to
run instead. The whole thing is four checks, in increasing cost, and you should wire at least the
first two into CI.

### 10.1 Check 1 — the differential generation test

**The single most valuable test: same prompt, greedy sampling, quantized model versus the
unquantized one. Compare token IDs, not text.**

Greedy decoding removes sampling noise entirely, so any divergence is a real difference in the
model's ranking of the next token. And comparing IDs rather than strings avoids detokenizer
whitespace artefacts hiding a difference.

```python
"""Differential check: does quantizing this model change what it generates?

Run before every release. Greedy sampling, fixed prompt, token-ID comparison.
"""
import os
os.environ["MLX_ENABLE_TF32"] = "0"   # must precede the first matmul (guide section 6.6)

import mlx.core as mx                     # noqa: E402
from mlx_lm import load                   # noqa: E402
from mlx_lm.generate import generate_step  # noqa: E402

REFERENCE = "mlx-community/SOME-MODEL-bf16"     # the unquantized reference
CANDIDATE = "mlx_model"                          # your freshly quantized output
MAX_TOKENS = 128

PROMPTS = [
    # Keep these FIXED across releases. Diversity matters more than length.
    "Write a Python function that reverses a linked list.",
    "Explain, in three sentences, why the sky is blue.",
    "List the first ten prime numbers as a JSON array.",
    "Translate to French: The quick brown fox jumps over the lazy dog.",
]


def greedy_ids(model, tokenizer, prompt: str, max_tokens: int = MAX_TOKENS):
    messages = [{"role": "user", "content": prompt}]
    ids = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
    out = []
    for token, _logprobs in generate_step(
        mx.array(ids),
        model,
        max_tokens=max_tokens,
        sampler=lambda logits: mx.argmax(logits, axis=-1),   # explicit greedy
    ):
        out.append(int(token))
    return out


ref_model, ref_tok = load(REFERENCE)
cand_model, cand_tok = load(CANDIDATE)

assert ref_tok.vocab_size == cand_tok.vocab_size, "tokenizers differ; comparison is meaningless"

failures = 0
for prompt in PROMPTS:
    a = greedy_ids(ref_model, ref_tok, prompt)
    b = greedy_ids(cand_model, cand_tok, prompt)

    if a == b:
        print(f"OK        exact match ({len(a)} tokens): {prompt[:50]!r}")
        continue

    # Find the first divergence and report its neighbourhood.
    n = min(len(a), len(b))
    i = next((k for k in range(n) if a[k] != b[k]), n)
    print(f"DIVERGED  at token {i}/{max(len(a), len(b))}: {prompt[:50]!r}")
    print(f"    reference : {ref_tok.decode(a[max(0, i - 8):i + 8])!r}")
    print(f"    candidate : {cand_tok.decode(b[max(0, i - 8):i + 8])!r}")
    failures += 1

print()
print(f"{len(PROMPTS) - failures}/{len(PROMPTS)} prompts matched exactly")
```

**How to read the result — this is the part that needs judgement.**

*Exact match on every prompt* is the strongest possible signal and it is achievable more often than
people expect, especially at 8 bits. Take it.

*Divergence late in a long generation* is normal and usually benign: quantization changes the
logits slightly, an eventual near-tie flips, and the two generations separate forever afterwards. A
single flip at token 90 of 128 tells you almost nothing on its own.

*Divergence at token 0 through 5* is a red flag. The very first tokens after a prompt are usually
decided by a wide logit margin. If those flip, something structural is wrong — not "quantization
noise".

*Divergence that changes with prefill chunking* is the §9.1 signature. See check 3.

**Track the divergence index over time, not just pass/fail.** A model that diverged at token 90
last release and diverges at token 12 this release has regressed, even though both "diverge".

### 10.2 Check 2 — logit-level comparison at fixed position

Generation comparison is end-to-end but coarse. A logit comparison at a fixed position tells you
the magnitude, which is what you need to distinguish "quantization noise" from "corruption".

```python
"""Compare raw logits between reference and candidate on a fixed prompt.

Reports max absolute difference and whether the argmax agrees at every position.
"""
import os
os.environ["MLX_ENABLE_TF32"] = "0"

import mlx.core as mx           # noqa: E402
from mlx_lm import load         # noqa: E402

PROMPT = "The capital of France is Paris, and the capital of Germany is"

ref_model, tok = load("mlx-community/SOME-MODEL-bf16")
cand_model, _ = load("mlx_model")

ids = mx.array(tok.encode(PROMPT))[None]        # [1, T]

ref_logits = ref_model(ids)
cand_logits = cand_model(ids)
mx.eval(ref_logits, cand_logits)

r = ref_logits.astype(mx.float32)
c = cand_logits.astype(mx.float32)

diff = mx.abs(r - c)
argmax_ref = mx.argmax(r, axis=-1)
argmax_cand = mx.argmax(c, axis=-1)
agree = mx.sum(argmax_ref == argmax_cand)
mx.eval(diff, agree)

n_positions = ids.shape[1]
print(f"positions           : {n_positions}")
print(f"max |logit diff|    : {float(mx.max(diff).item()):.4f}")
print(f"mean |logit diff|   : {float(mx.mean(diff).item()):.5f}")
print(f"argmax agreement    : {int(agree.item())}/{n_positions}")
```

**Calibration for the numbers this prints.** Use the model-level table from §9.1 as your reference
scale — those are real measurements of a real corruption, on M5, at N=16068:

| max logit diff | What it means |
|---:|---|
| ~0.3–1.3 | the `mxfp4` rows in that table, all with `argmax: ok` — this is quantization noise |
| 3.3–17.8 | every affine row in that table — **all argmax-diverged, all corrupted** |

There is no universal threshold, because it depends on your model's logit scale. But **an order of
magnitude between "noisy" and "broken" showed up cleanly in that measurement**, and if your
candidate lands in the second band you should assume corruption rather than precision loss until
proven otherwise.

**And do not use `rtol=1e-5`.** §9.8: on gen-17 hardware, batch-versus-single logprobs differ by
0.031–0.039 with a *correct* model. A tolerance that tight will fail on healthy builds and teach
you to ignore the test.

### 10.3 Check 3 — the chunked-prefill A/B, which targets §9.1 directly

The §9.1 measurements were obtained by comparing **one-shot prefill against 2048-chunked prefill**.
That is not incidental: chunking changes `n`, and `n` is the trigger. If your model is affected,
this comparison reveals it with no reference model required.

```python
"""One-shot vs chunked prefill on the SAME model.

A correct implementation gives (nearly) identical logits either way. A large
difference is the mlx#3856 / #3887 signature: the row count changed, and with it
the tile alignment.
"""
import os
os.environ["MLX_ENABLE_TF32"] = "0"

import mlx.core as mx                       # noqa: E402
from mlx_lm import load                     # noqa: E402
from mlx_lm.models.cache import make_prompt_cache   # noqa: E402

model, tok = load("mlx_model")

# Long enough that tokens x top_k can exceed 32768 on a top-8 MoE.
text = "The history of computing begins with the abacus. " * 400
ids = mx.array(tok.encode(text))[None]
T = ids.shape[1]
print(f"prompt tokens: {T}")


def prefill_logits(chunk: int):
    cache = make_prompt_cache(model)
    out = None
    i = 0
    while i < T:
        out = model(ids[:, i:i + chunk], cache=cache)
        i += chunk
    mx.eval(out)
    return out[:, -1, :].astype(mx.float32)


one_shot = prefill_logits(T)
chunked = prefill_logits(2048)
mx.eval(one_shot, chunked)

diff = mx.abs(one_shot - chunked)
mx.eval(diff)
print(f"max |logit diff| one-shot vs 2048-chunked : {float(mx.max(diff).item()):.4f}")
print(f"argmax one-shot : {int(mx.argmax(one_shot).item())}")
print(f"argmax chunked  : {int(mx.argmax(chunked).item())}")
```

If the two argmaxes disagree, you have reproduced the bug on your model, on your hardware, with no
reference checkpoint and no unquantized copy. That makes this the cheapest high-signal check in the
guide for MoE models specifically.

**Also sweep `top_k`-adjusted lengths.** With `n = tokens × top_k`, a top-8 model crosses `n =
32768` at about 4096 tokens. Test at 4000, 4100 and 4200 tokens; the `n % 64 != 0` half of the
trigger means adjacent lengths behave differently.

### 10.4 Check 4 — poisoning the allocator, for the "sometimes lucky" case

§9.1's regression-test note is explicit that a single read can pass by accident: *"unwritten rows
hold whatever the recycled MTLBuffer last contained, which is sometimes coincidentally plausible. A
regression test should poison the output buffer (or compare two runs) rather than trust one lucky
read."*

MLX gives you no API to write a sentinel into a specific output buffer. What you *can* do is fill
the allocator's recycle pool with a distinctive value first, so that any unwritten row inherits it —
and then repeat with a different value. Rows that change between the two runs were never written.

```python
"""Detect unwritten output rows by seeding the allocator's recycle pool.

Technique: fill and release buffers containing a distinctive sentinel, so a
recycled buffer starts life full of it. Run the op. Repeat with a different
sentinel. Any element that differs between the two runs was NOT written by the
kernel -- it is showing you recycled memory.
"""
import mlx.core as mx


def seed_recycle_pool(value: float, shape, dtype, *, repeats: int = 8) -> None:
    """Allocate, fill and drop buffers so the pool holds `value`."""
    for _ in range(repeats):
        junk = mx.full(shape, value, dtype=dtype)
        mx.eval(junk)
        del junk
    # Do NOT call mx.clear_cache(): we WANT these in the recycle pool.


def run_once(sentinel: float, *, n, K, N, E, group_size=64, bits=4, mode="affine"):
    w = mx.random.normal(shape=(E, N, K)).astype(mx.bfloat16)
    q = mx.quantize(w, group_size, bits, mode)
    wq, scales = q[0], q[1]
    biases = q[2] if len(q) > 2 else None

    x = mx.random.normal(shape=(n, K)).astype(mx.bfloat16)
    idx = mx.sort(mx.random.randint(0, E, shape=(n,)))   # sorted -> sorted_indices=True is legal
    mx.eval(wq, scales, x, idx)

    seed_recycle_pool(sentinel, (n, N), mx.bfloat16)

    y = mx.gather_qmm(
        x, wq, scales, biases,
        rhs_indices=idx, transpose=True,
        group_size=group_size, bits=bits, mode=mode,
        sorted_indices=True,
    )
    mx.eval(y)
    return y


# n > 32768 and n % 64 != 0 is the mlx#3856 trigger.
CFG = dict(n=32802, K=1024, N=512, E=8)

mx.random.seed(0)
a = run_once(1234.0, **CFG)
mx.random.seed(0)          # identical inputs
b = run_once(-4321.0, **CFG)

delta = mx.abs(a.astype(mx.float32) - b.astype(mx.float32))
per_row = mx.max(delta, axis=-1)
bad_rows = mx.sum(per_row > 0)
mx.eval(bad_rows, delta)

print(f"n = {CFG['n']}  (n % 64 = {CFG['n'] % 64})")
print(f"rows differing between the two sentinel runs : {int(bad_rows.item())}/{CFG['n']}")
print(f"max |difference|                             : {float(mx.max(delta).item()):.4f}")
print()
print("Any nonzero row count means the kernel did not write those rows.")
```

> 🟡 **RECONSTRUCTED** — the *technique* is attested (the fix PR's own regression-test note calls
> for exactly "poison the output buffer or compare two runs"); the Python spelling above is mine.
> MLX has no documented API for writing a sentinel into a specific output allocation, and whether
> `mx.full` + `del` reliably places a buffer of the right size class into the recycle pool depends
> on allocator internals. Two facts make it plausible: the buffer cache's reuse window is
> `[size, size + 2·page_size)` (`notes/repos/issues-mlx-stack.md:1081`), and `mx.clear_cache()`
> drains that pool — which is why the code above deliberately does *not* call it.
> **If the row count comes back 0 on a configuration you believe is affected, do not conclude you
> are safe** — fall back to check 3, which needs no allocator assumptions at all.

### 10.5 What to put in CI

A pragmatic split:

| Check | Cost | Run it |
|---|---|---|
| §10.1 differential generation, 4 prompts × 128 tokens | seconds to a minute | **every commit that touches quantization config** |
| §10.2 logit comparison at a fixed position | seconds | **every commit** |
| §10.3 chunked-prefill A/B | one long prefill | **every release, and every mlx version bump** — MoE models especially |
| §10.4 allocator poisoning | one long gather | when investigating, or as a pinned regression test for #3856 |
| `mlx_lm.evaluate` on the eight-task battery (§8.8) | tens of minutes | **every release** |

And two hygiene rules that make all of the above meaningful:

1. **`MLX_ENABLE_TF32=0` at the top of the harness, before any import that could touch the GPU.**
   It is first-use latched (§6.6); setting it later silently does nothing.
2. **Pin the mlx version in the test environment and bump it deliberately.** Given §9, an unpinned
   `mlx` is a moving correctness surface. The mlx-lm test suite itself pins `MLX_ENABLE_TF32=0`
   (PR #1595) for exactly this reason.

---

## 11. KV-cache quantization is a different thing

Four facts, so you do not conflate weight quantization with cache quantization. Each has a pointer
to where the real coverage lives.

**1. It costs decode speed and, today, *raises* prefill peak memory.**

> ✅ **VERIFIED** — mlx-lm#1587 (OPEN, 11 comments), reported on Llama-3.2-3B-Instruct-4bit,
> **M4 Max 128 GB, macOS 27.0**, `notes/repos/issues-mlx-stack.md:498-505`:
>
> | context | case | peak MLX memory | decode speed |
> |---|---|---:|---:|
> | 8,000 tok | fp16 | 3.46 GB | 3.2 tok/s |
> | 8,000 tok | q8 | **4.87 GB (+1.41)** | 2.6 tok/s |
> | 32,000 tok | fp16 | 4.72 GB | 1.0 tok/s |
> | 32,000 tok | q8 | **7.10 GB (+2.38)** | 0.7 tok/s |
>
> The cause was isolated to the **unfused quantized attention path**, not cache resize churn;
> presizing the cache closed only 1.5% (M1) / 3.8% (M5 Max) of the inversion. **Mitigation:
> a smaller `prefill_step_size`** — at chunk 512 *"the inversion disappears entirely."*

The conclusion from that thread is worth memorising:

> ✅ **VERIFIED**, `notes/repos/issues-mlx-stack.md:563`: *"on a 4-bit dense model KV is only ~19%
> of decode-step bytes — weights dominate, so halving KV bandwidth cannot pay for the
> compose/dequant overhead. So `--kv-bits 8` is a **capacity** tool (roughly half the KV bytes →
> longer context or more cache slots in the same RAM), bought at a few percent of decode speed. It
> is not a throughput lever."*

**2. The library default and the CLI default disagree.**

> ✅ **VERIFIED** — mlx-lm#1566 (closed 2026-08-03, no fix merged), `notes/repos/issues-mlx-stack.md:567-569`:
> `generate_step()` and `speculative_generate_step()` both default `quantized_kv_start=0`, while
> the CLIs default `--quantized-kv-start` to `DEFAULT_QUANTIZED_KV_START = 5000`.
> **A library caller that passes `kv_bits=` without `quantized_kv_start=` quantizes from token 0
> and eats the full cost.** Always pass both.

**3. `RotatingKVCache` cannot be quantized — and `hasattr` will not save you.**

> ✅ **VERIFIED** — `notes/repos/issues-mlx-stack.md:580-596`:
> ```python
> def to_quantized(self, group_size: int = 64, bits: int = 4) -> QuantizedKVCache:
>     raise NotImplementedError("RotatingKVCache Quantization NYI")
> ```
> and `maybe_quantize_kv_cache` guards with `if hasattr(c, "to_quantized")` — which passes,
> because the method **is defined and it raises**. *"Presence ≠ implementation."*
> Fix in flight: mlx-lm PR **#1584** adds `RotatingQuantizedKVCache`; `keep > 0` will still raise.

**4. gpt-oss plus a quantized KV cache is a silent client timeout.**

> ✅ **VERIFIED** — mlx-lm#1438, quoted at `notes/repos/issues-mlx-stack.md:625`: *"gpt-oss uses
> attention sinks, and a quantized KV cache raises `'Quantized SDPA does not support attention
> sinks'` from the generation thread. The thread dies, the request never returns, and the client
> sits until its own timeout, so it presents as a network timeout during prefill rather than as an
> error. KV quantization has to be off for this family."*

Everything else about the cache — sizing, trimming, prefix reuse, the rotating-window contract —
belongs to the KV-cache guide in this part and to
[Part 3](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-03-context-profiles-agentic/README.md).

---

## 12. Selection table: what to pick

### 12.1 The decision, in one table

Bits-per-weight figures are from §3.1's arithmetic. "Quality check" names the minimum verification
from §10 that this configuration warrants.

| Model size | Target device | Mode + group | bpw | Why | Quality check |
|---|---|---|---:|---|---|
| **≤ 1.5B dense** | iPhone / iPad | `affine` 8-bit, group 64 | 8.50 | it fits; do not pay quality for size you do not need | §10.1 |
| **≤ 1.5B dense** | Mac | `affine` 8-bit, group 64 | 8.50 | same | §10.1 |
| **3–8B dense** | iPhone / iPad | `affine` 4-bit, group 64 | 4.50 | the standard on-device point; jetsam headroom matters more than the last point of quality | §10.1 + §10.2 |
| **3–8B dense** | Mac (M1–M4) | `affine` 4-bit group 64, or **6-bit group 64** if RAM allows | 4.50 / 6.50 | 6-bit is an underused sweet spot: near-8-bit quality, 25% smaller | §10.1 |
| **3–8B dense** | Mac (M5-gen) | `affine` 4-bit, group 64, **`K % 64 == 0` enforced** | 4.50 | fast path + avoids §9's alignment class | §10.1 + §10.3 |
| **8–35B dense** | Mac | `affine` 4-bit group 64, or `mixed_4_6` | 4.50 / ~4.9 | mixed protects the sensitive layers for ~0.4 bpw | §10.1 + §10.2 + `mlx_lm.evaluate` |
| **≥ 35B dense** | Mac (lots of RAM) | `affine` 4-bit group 64 | 4.50 | bandwidth-bound; smaller wins | §10.1 + `mlx_lm.evaluate` |
| **≥ 35B dense** | Mac (tight RAM) | `mixed_3_6` after **DWQ** | ~3.4 | 3-bit round-to-nearest is not shippable; DWQ makes it | full §10 + `mlx_lm.evaluate` |
| **MoE, top-k ≥ 4** | Mac (M1–M4) | `affine` 4-bit group 64 | 4.50 | error averages ~/√k across experts | §10.1 + §10.3 |
| **MoE, top-k ≥ 4** | Mac (**M5-gen**) | `affine` 4-bit + **pad gathered rows to 64** + `K % 64 == 0` | 4.50 | ⚠️ §9.1 is fixed on main but unreleased; §9.2 remains open | **§10.3 mandatory** + §10.4 |
| **MoE, top-1 / low-k** | any | **8-bit**, or 4-bit only with DWQ | 8.50 | error does not average; one expert carries the token | full §10 |
| **MoE router / gate** | any | **8-bit, group 64** regardless of the rest | 8.50 | routing error is discrete, not smooth (this is what gpt-oss does) | included above |
| **`lm_head`** | any | 6-bit, or the `mixed_*` recipes' "high" | 6.50 | every token passes through it | §10.2 |
| **any** | Linux CUDA | `nvfp4` with `global_scale` | 4.50+ | the only place tensor-scale nvfp4 has fast kernels — Metal gained fallback-speed (`qmv`) support in 0.32.1, §2.6 | §10.1 |
| **pre-quantized `mxfp4` checkpoint** | any | leave it | 4.25 | gpt-oss ships this way; converting loses nothing and risks something | §10.1 |

### 12.2 Group size, decided separately

Group size is a smaller decision than bits and it has a clean rule:

| Situation | Group |
|---|---|
| default, everything | **64** |
| you are at 2–3 bits and quality is failing | **32** — but re-read §3.1: it costs +0.5 bpw, which at 2 bits is a 20% size increase |
| you are at 6–8 bits and want the last few percent of size | **128** — but check §3.4, more layers will fail the divisibility test and be silently skipped |
| embeddings | mlx-lm's AWQ defaults to **32** for embeddings while using 64 for everything else (`--embed-group-size 32`); that asymmetry is a deliberate choice worth copying |
| `mxfp4` / `mxfp8` | **32**, not a choice |
| `nvfp4` | **16**, not a choice |

### 12.3 Mode, decided by target and provenance

| Choose | When |
|---|---|
| **`affine`** | the default answer. Widest bit range (2/3/4/5/6/8), all three group sizes, the only mode the mixed-precision recipes and DWQ support, and the only mode with a bias term. |
| **`mxfp4`** | you already have an `mxfp4` checkpoint (gpt-oss), or you want the cheapest 4-bit at 4.25 bpw, or you need to sidestep §9.1 specifically. Cannot use quant predicates or DWQ. |
| **`mxfp8`** | you want block-float at 8 bits, typically as a DWQ *teacher* or as an activation-quantization base (`-qa` needs `mxfp8` or `nvfp4`). |
| **`nvfp4`** | CUDA, or an incoming `compressed-tensors` / `nvfp4-pack-quantized` checkpoint. On Metal, know that `global_scale` throws on ≤ 0.32.0 and runs only via the slow `qmv` fallback on 0.32.1+ (§2.6), and that its group of 16 is smaller than every kernel block constant (§9.3). |

### 12.4 The quick-reference card

Everything in this guide that fits on one screen:

```
MODES        affine   2,3,4,5,6,8 bits   group 32/64/128   scale=input dtype  + bias
             mxfp4    4 bits             group 32          scale=e8m0         no bias
             mxfp8    8 bits             group 32          scale=e8m0         no bias
             nvfp4    4 bits             group 16          scale=e4m3         no bias
             (defaults marked in the docstring: affine 64/4, mxfp4 32/4,
              nvfp4 16/4, mxfp8 32/8.  7 bits does not exist.)

BPW          affine  = bits + 32/group   (16-bit scale + 16-bit bias)
             mxfp4   = 4.25   mxfp8 = 8.25   nvfp4 = 4.50

GATES        K % 64 == 0          -> NAX fast path (else silent fallback)
             transpose == True    -> the only NAX layout
             BK = 64              -> the only gather instantiation
             last dim % group == 0 -> or mlx-lm SILENTLY SKIPS the layer

LADDER       M = 1        qmv
             M = 2..~10   qmv_wide  (affine: gen-15+; fp modes: all gens)
             M = ~10..32  qmm, FLAT -- M=10 costs what M=32 costs. Batch up.
             2-bit loses its speed advantage at M >= 3.

FIXED MAIN   #3856  affine gather_qmm, n > 32768 && n % 64 != 0, M5/NAX
             #3887  gather_qmm sorted-rhs, K % 64 != 0, M5/NAX, mxfp4 too
                    -> both fixed by #3922 (`d73eb752`); v0.32.2 predates the merge
OPEN BUGS    #3912  fp quantized matmul, quantized dim % 32 != 0
             #3924  tile_matmad_nax missing else, odd tile shapes
             (#3912/#3924 OPEN; #3854 nvfp4 split-K is MERGED)

MITIGATION   Prefer native K % 64 == 0; otherwise pin a fixed revision, use a
             safe fallback, or measure padding. Pad gathered rows to 64 while
             the row-tail bugs remain open.

ENV          MLX_ENABLE_TF32 defaults to 1. Set it to 0 BEFORE the first matmul
             or it silently does nothing. Metal: gen-17 + macOS 26.2 only.
             MLX_SDPA_BLOCKS must be a multiple of 32 on mlx <= 0.32.0.

VERIFY       greedy, fixed prompt, compare TOKEN IDS against the unquantized model.
             one-shot vs 2048-chunked prefill on the same model (MoE).
             maxima and disagreement counts -- never medians.
```

### 12.5 Three rules that survive every version bump

**1. Treat `K % 64 == 0` as a measured shape tradeoff, not a free conversion rule.** It is the NAX
fast-path gate and sidesteps several current corruption bugs when the architecture is already
aligned. For a legal non-aligned model, changing K means padding weights and activations or changing
the graph contract. Pin a fixed MLX revision or use a safe fallback when that cost is worse than the
temporary workaround.[^k64-tradeoff]

**2. Never ship a quantized model you have not diffed against the unquantized one.** Greedy, fixed
prompt, token IDs. It costs a minute and it is the only check that catches the failure class this
guide documents — because that class does not raise, does not warn, and does not produce NaNs.

**3. Pin your mlx version and read the changelog when you bump it.** Between 2026-06-05 and
2026-07-26 this subsystem saw at least seven correctness-relevant PRs. That rate will not last
forever, but it is the rate today.

---

## 13. Declared gaps

Things this guide could not verify, what would resolve them, and what to do meanwhile.

> 🔴 **GAP 1 — the return arity of `mx.quantize` for non-affine modes.**
> The published signature says `-> tuple[array, array, array]`, but the mode table says `mxfp4`,
> `mxfp8` and `nvfp4` have **no bias**, and `dequantize`'s `biases` is `Optional`. Whether those
> modes return a 2-tuple, a 3-tuple ending in `None`, or a 3-tuple with a dummy array is not
> settled by the notes.
> **Resolution:** `python/tests/test_quantized.py`, or one line at a REPL.
> **Safe default:** unpack defensively (`q[2] if len(q) > 2 else None`) and pass `biases=None`
> explicitly for the fp modes, as every listing in this guide does.
>
> 🔴 **GAP 2 — no way to ask which quantized kernel ran.**
> There is no MLX API, env var or attribute that reports the dispatch decision. The gates live in
> `quantized.cpp` behind the Python boundary.
> **Resolution:** an upstream diagnostic hook, or a Metal capture in Instruments where the kernel
> names are readable (the NAX variants are separately named).
> **Safe default:** benchmark the shapes you care about (§6.5), use `transpose=True`, and preserve
> native 64-alignment where it exists. For a non-aligned K, compare a pinned fix or safe fallback
> against measured padding rather than changing the graph unconditionally.
>
> ✅ **GAP 3 — RESOLVED 2026-07-29 — PR #3912's trigger, scope and magnitude.**
> The PR body was read live via `gh` on 2026-07-29 (PR still **OPEN**): trigger `K % 32 == 16`,
> legal only for `nvfp4` (group size 16); affected kernels `fp_qmm_t_impl` and siblings in
> `fp_quantized.h`, GPU matrix path only (CPU and vector/decode kernels correct); **not**
> NAX-gated — reproduced on an M3 Pro; magnitude max |err| ≈ 40 with 72% of outputs wrong in the
> reproducer. Full detail now in §9.4.
> **Safe default:** keep already-aligned dimensions aligned. For legal non-aligned NVFP4 dimensions,
> pin a revision containing the fix or use a verified fallback; pad only after measuring the
> graph-wide overhead.
>
> 🔴 **GAP 4 — `gather_qmm`'s index dtype and rank contract.**
> "Flat indices along the batch dimensions" is the whole published description. The permitted dtype
> (int32 vs uint32), the permitted rank, and the semantics when `lhs_indices` and `rhs_indices` are
> both supplied are not pinned down.
> **Resolution:** `mlx/ops.cpp`'s validation for `gather_qmm`, or `python/tests/test_quantized.py`.
> **Safe default:** 1-D `int32` `rhs_indices` of length `n`, `lhs_indices=None` — the MoE-decode
> shape mlx-lm's `SwitchLinear` exercises.
>
> ✅ **RESOLVED ON MAIN — `mlx#3922` merged 2026-08-26; `mlx#3856` and `mlx#3887` are closed.**
> Both `mlx#3856` and `mlx#3887` were **OPEN** on 2026-07-27, with `mlx#3922` (upstream) and
> `mlx-lm#1585` (downstream
> padding workaround) also open. A **2026-07-31** re-check still found all three open; that is now
> historical. On **2026-08-26**, `mlx#3922` merged with a focused regression test and `mlx#3856`
> closed.
> Release v0.32.2 (2026-08-25) predates that merge. On 2026-09-07, `mlx#3887` closed completed
> after maintainers confirmed #3922 covers its reported affine and MXFP ragged-K cases.
> **Resolution:** pin `d73eb752` or later, or use a release that contains that commit.
> **Safe default:** preserve native 64-alignment and keep the gathered-row workaround on ≤0.32.2
> while needed, but re-measure and remove padding after a fix; both forms of padding consume memory
> and compute even when the underlying bug is gone.
>
> 🔴 **GAP 6 — quality numbers for MLX's quantization modes specifically.**
> The corpus contains no MLX-measured perplexity or benchmark table comparing affine-4 against
> `mxfp4` against `nvfp4` on the same model. The quality claims in §3.2 and §7.5 are
> **community-measured on Core AI bundles**, not on MLX, and the schemes do not map one-to-one
> (Core AI's "sym8" is symmetric-linear with a per-K-block-32 scale; MLX's affine-8 is asymmetric
> with a bias). The *mechanisms* transfer; the exact rankings may not.
> **Resolution:** run `mlx_lm.evaluate` (§8.8) across modes on one model and publish it.
> **Safe default:** treat §3.2 as directional and run your own §10 checks.
>
> 🔴 **GAP 7 — the `nn.quantize` / `mlx_lm` interaction with `quantize_input=True`.**
> The docstring says `quantize_input=True` is "only supported for `nvfp4` and `mxfp8` modes and
> `Linear` layers", and mlx-lm's `-qa` path raises on a bias term. What happens when
> `quantize_input=True` meets a model containing a mix of eligible and ineligible layers — silent
> skip, or raise — is not recorded.
> **Resolution:** `python/mlx/nn/layers/quantized.py` read directly.
> **Safe default:** apply a `class_predicate` that selects only the layers you have verified are
> eligible, rather than relying on the default predicate to do the filtering.
>
> 🔴 **GAP 8 — the poisoning technique's reliability.**
> §10.4's allocator-seeding code is a reconstruction. Whether `mx.full` + `del` reliably places a
> buffer of the right size class into the recycle pool depends on allocator internals; the only
> supporting facts are the reuse window `[size, size + 2·page_size)` and the fact that
> `mx.clear_cache()` drains the pool.
> **Resolution:** upstream PR #3922 now includes the focused regression in `python/tests/test_quantized.py`.
> **Safe default:** treat a zero result from §10.4 as inconclusive and fall back to §10.3, which
> makes no allocator assumptions.

**One thing that is emphatically *not* a gap:** the pinned MLX implementation does not use native
scale planes. Its kernels hand-dequantize into threadgroup memory (§2.4). The older negative header
search applied to Xcode 26.6 only; Xcode 27 documents auxiliary scale planes, so do not generalize
MLX's current implementation into a platform limitation.[^metal27-planes]

---

## 14. Sources

Everything in this guide traces to one of these. Nothing was written from model memory.

**Repository source, read on disk (strongest evidence class):**

- `notes/repos/mlx-core.md` — `ml-explore/mlx` at HEAD `973e27f`, declared version **0.32.1**,
  latest tag `v0.32.0`, shallow clone (50 commits). The mode table (§2.1), every Python signature
  in §4, the `mlx.nn` layer semantics in §5, the validation errors in §2.5.
- `notes/repos/mlx-lm.md` — `ml-explore/mlx-lm` at HEAD `e5baded`, version **0.31.3**, dated
  **2026-07-26**, shallow clone. `MIN_MLX_VERSION = "0.31.2"`. The convert CLI (§5.5), the
  mixed-precision recipes (§3.5), the foreign-checkpoint translation table (§5.6), and all four
  learned-quantization pipelines with their real argparse defaults (§8).
- `notes/repos/mlx-tensorops-kernels.md` — the Metal kernel sources plus the
  `MetalPerformancePrimitives` headers shipped in the Xcode SDK. The alignment gates (§6.1), the
  hand-dequantization pipeline and the `fp8.h` / `fp4.h` struct finding (§2.4), the instantiation
  lists (§2.2, §2.3), the NAX build and runtime gates, and the PR ledger including `mlx#3912` /
  `mlx#3922` / `mlx#3924`.

**GitHub issues and PRs with maintainer and contributor participation:**

- `notes/repos/issues-mlx-stack.md` — the whole of §9, plus the dispatch ladder (§6.3), the 2-bit
  slope (§6.4), the TF32 story (§6.6), the MoE loading facts (§7.3) and the KV-cache material
  (§11). Individual references: mlx **#3856**, **#3887**, **#3852**, **#3860**, **#3897**,
  **#3911**, **#3702**, PRs **#3854**, **#3875**, **#3764**, **#3804**, **#3922**; mlx-lm
  **#1587**, **#1566**, **#1573**/**#1584**, **#1438**, **#1585**, **#1595**.

**Community-measured, attributed as such:**

- `notes/repos/john-rocky-models.md` — the `coreai-model-zoo` by GitHub user `john-rocky`
  (Daisuke Majima / "rockyshikoku"). The MoE gather throughput table and the int4-versus-int8
  bandwidth anomaly (§7.4), and the expert-scheme quality findings including the top-1 reversal
  (§7.5). **Measured on Core AI, not MLX**, on M4 Max and iPhone 17 Pro (A19 Pro). Partly
  agent-generated; unique primary source; **not Apple-official**.

**Series corrections applied:**

- `notes/CORRECTIONS-PENDING.md` — item **C3** correctly identified `fp8_e8m0` / `fp8_e4m3` /
  `fp4_e2m1` as MLX's own structs but overgeneralized a 26.6 negative header search. §2.4 now
  distinguishes MLX's pinned implementation from Xcode 27's documented multiplane tensor API.

**A note on precedence.** Where the brief for this guide and the research notes disagreed, the
notes won and the difference is reported inline — most visibly in §7.4, where the community
`gather_qmm` throughput numbers turn out to have been measured against **Core AI's** stock
`GatherMM` rather than inside MLX. They are presented here for what they actually measure: the
value of reading only the routed experts, which is exactly what `mx.gather_qmm` does for you.

---

*Last verified against the corpus on **2026-07-27**. Bug statuses in §9 move; check the issues
before relying on the table.*

[^metal27-formats]: Apple's current [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype)
    documentation lists Int2, UInt2, Float4E2M1, Float8E4M3, Float8E5M2, and Float8UE8M0. These
    platform formats are distinct from the like-named helper structs in the pinned MLX source.
[^metal27-planes]: Apple documents
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes),
    and [`MTLTensor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensor/auxiliaryplanes).
    The repository's [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L27-L78)
    describes the E8M0 scale plane and `blockFactors` relationship.
[^k64-tradeoff]: [`ml-explore/mlx` PR #3912](https://github.com/ml-explore/mlx/pull/3912)
    documents that NVFP4's group size 16 makes `K = 1040` a legal input and that the kernel, rather
    than the model, must handle legal 16-wide tails. Padding that example to the next multiple of
    64 gives 1088 elements: `(1088 - 1040) / 1040 = 4.615%` additional reduction-width storage and
    multiply work before accounting for the corresponding activation and adjacent-layer changes.
    The local source mirror records the same dispatch gate in
    [`notes/repos/mlx-tensorops-kernels.md`](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/notes/repos/mlx-tensorops-kernels.md), while
    the guide's §6.1 examples identify adapters, 72-wide heads, and custom projections for which K
    is part of the model contract rather than a free quantization parameter.
