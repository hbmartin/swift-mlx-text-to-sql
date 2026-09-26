# `TorchMetalKernel`: writing and embedding a custom Metal kernel

**Part 8 · Core AI: converting from PyTorch · Reference 03**

**Version floor.** `TorchMetalKernel` ships in **`coreai-torch` 0.4.1**, which pins
**`coreai-core==1.0.0b2`** exactly, requires **Python ≥ 3.11** and **torch ≥ 2.8.0** (validated to
**2.13.0**; anything newer imports with a `UserWarning`). ✅ **VERIFIED** —
`repos/apple__coreai-torch/pyproject.toml:5-59`, `coreai_torch/__init__.py:32-39`. The assets it
produces run on the public Core AI runtime, i.e. **iOS 27 / iPadOS 27 / macOS 27** and the Xcode 27
toolchain; there is no back-deployment of `.aimodel` custom kernels to 26.x. Authoring itself is
**macOS-only in practice** — Apple's own test suite skips every Metal test with *"Metal tests run
only on Mac"* (`tests/dsl/conftest.py:23`), and a custom kernel is **GPU-only by construction**: the
Neural Engine executes fixed hardware ops and cannot run arbitrary Metal Shading Language.

If your kernel body reaches for **TensorOps** (`mpp::tensor_ops::matmul2d`, cooperative tensors),
a second, finer version ladder applies to the *device OS*, not to `coreai-torch`:
**26.0** TensorOps introduced · **26.1** bfloat tensors · **26.3** cooperative tensors as matmul
*inputs* · **26.4** int4/int8 tensors. ✅ **VERIFIED** — Apple Tech Talk 111432, *"Accelerate your
machine learning workloads with the M5 and A19 GPUs"*, quoted in
`notes/transcripts/missing-sessions.md` §7.5. **26.2 appears nowhere in that ladder**, even though
the shipped Xcode 26.6 SDK annotates the relevant TensorOps symbols with a 26.2 deployment macro.
Both statements are true and they are about different things — §11 untangles them.

> ⚠️ **Read this before you write a line of MSL.** Core AI has **zero Apple sample-code projects** —
> verified: 0 `sampleCode` entries across all 312 indexed Core AI symbols, and
> `/documentation/updates/coreai` returns 404. Unlike Foundation Models, there is no first-party
> compiling reference app to diff your work against. The strongest evidence available is the shipped
> `apple/coreai-torch` source and its test suite, which is what this guide is built on. Every
> signature below was read from that clone this session, and every line citation is real.

---

## What this covers

The mechanism, in one sentence, is the one the WWDC26 session 325 presenter used: **you give
`coreai-torch` a second input alongside your PyTorch model — your kernel source in Metal Shading
Language — and the converter bundles both into a single asset, with the MSL embedded so it ships
with the model.**

> ✅ **VERIFIED** — WWDC26 session 325, *"Dive into Core AI model authoring and optimization"*
> (Sachin, Core AI team), lines 178–184:
> *"Here's what changes with custom Metal kernels. **I am adding a second input to `coreai-torch`.
> My kernel's source code written in the Metal Shading Language, or MSL.** The converter takes both
> my PyTorch model and my custom kernel, and **bundles them together into a single asset. The MSL is
> embedded right inside. It ships with the model.**"*

Concretely, this guide covers:

- **The three pieces** you must write — a PyTorch reference implementation (which is what
  `torch.export` sees during tracing), the Metal kernel body, and the `TorchMetalKernel`
  registration that binds them — plus the fourth thing you *don't* write, because the converter
  generates it.
- **When to do this at all.** Core AI already ships fast kernels and primitives for heavy operations
  like scaled dot-product attention. Reaching for a custom kernel before profiling is a reliable way
  to make a model slower. §2 is deliberately discouraging, with community measurements showing both
  a 3.6× win and a clear regression from the same technique.
- **The full constructor and call signature**, field by field, read from
  `coreai_torch/_torch_metal_kernel.py`.
- **The axis reversal.** `MTLTensor` extents are stored in the *reverse* of the torch shape. This is
  documented in Apple's own test docstring and it is the single most expensive footgun in the API —
  it produces kernels whose PyTorch reference passes on CPU and whose Metal body reads out of bounds.
- **`result_shapes` at every call site**, why the transcript makes a point of it, and what silently
  goes wrong when you hardcode it.
- **Registration order** — kernels must be registered with `TorchConverter` *before* the exported
  program is added — and the exact `ValueError` you get when two kernels share a name.
- **Scalars, dtype templating, multiple outputs, `helper_src`**, and the 31-buffer parameter limit
  that ties all four together.
- **Reaching TensorOps from inside a `TorchMetalKernel` body** — the SAM3 FlashAttention integration
  from session 330, the OS 27 auxiliary scale-plane path, and the 26.x/custom-format cooperative-
  tensor fallback.[^xcode27-scale-planes]
- **The failure taxonomy**: what raises at construction, what raises at conversion, and the one
  category that raises neither — a malformed MSL body that converts cleanly, saves cleanly, loads
  cleanly, and fails only when you bind a function.

## What this does *not* cover

- **How to write a *good* Metal kernel.** Tiling, SIMD-group mapping, cooperative tensors,
  `matmul2d` descriptors, `reduce_rows`, the M5 neural accelerator — all of that is
  [Part 11 — Metal and TensorOps](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md). This guide is about the
  *seam*: how a kernel you already know how to write gets into an `.aimodel`. §11 marks the handoff
  precisely.
- **Custom op *lowering*** (`register_torch_lowering`), which expresses a new op using existing Core
  AI operations rather than raw MSL. That is a different, usually better, extension point — see
  guide 04 in this part, and §2.3 for the decision.
- **Composite ops** (`coreai_torch.composite_ops`: `SDPA`, `RoPE`, `RMSNorm`, `GatherMM`,
  `GatedDeltaUpdate`) — the pre-packaged fast paths you should exhaust first. Guide 02 in this part.

## What you need

- A **Mac**. Not a preference: `tests/dsl/conftest.py` skips the entire Metal test tree on
  non-Darwin, and the runtime path requires Metal-backed storage.
- **`pip install coreai-torch`** (installs `coreai` and `coreai_torch`). The `.aimodel` you produce
  needs macOS 27 / iOS 27 to run.
- Working knowledge of **Metal Shading Language**. This guide does not teach MSL. It teaches the
  ~15 things about MSL-inside-Core-AI that differ from MSL-inside-a-Metal-app.
- Ideally, a **profile** showing that the built-in path is your bottleneck. §2 explains how to get
  one and why the answer is usually "don't".

---

## Contents

1. [The mechanism: three pieces, one artifact](#1-the-mechanism-three-pieces-one-artifact)
2. [When to do this at all](#2-when-to-do-this-at-all)
3. [The complete worked example: a fused SiLU](#3-the-complete-worked-example-a-fused-silu)
4. [The constructor, field by field](#4-the-constructor-field-by-field)
5. [What the converter generates — and the axis reversal](#5-what-the-converter-generates--and-the-axis-reversal)
6. [`result_shapes`: why every call site](#6-result_shapes-why-every-call-site)
7. [Thread dispatch: grid, threadgroup, and bounds](#7-thread-dispatch-grid-threadgroup-and-bounds)
8. [Registering, converting, running](#8-registering-converting-running)
9. [Scalar inputs: literals in disguise](#9-scalar-inputs-literals-in-disguise)
10. [Dtype templating, the kernel cache, and multiple outputs](#10-dtype-templating-the-kernel-cache-and-multiple-outputs)
11. [`helper_src` and reaching TensorOps](#11-helper_src-and-reaching-tensorops)
12. [The failure taxonomy](#12-the-failure-taxonomy)
13. [Does it pay? Community measurements](#13-does-it-pay-community-measurements)
14. [Testing a kernel, and the de-risk ladder](#14-testing-a-kernel-and-the-de-risk-ladder)
15. [Deployment reality](#15-deployment-reality)
16. [Quick reference](#16-quick-reference)
17. [Sources and evidence ledger](#17-sources-and-evidence-ledger)

---

## 1. The mechanism: three pieces, one artifact

### 1.1 The shape of it

Everywhere else in `coreai-torch`, conversion is a one-input affair: an `ExportedProgram` goes in,
an `AIProgram` comes out. Custom Metal kernels add a **second input channel** that runs parallel to
the graph:

```
                    ┌──────────────────────────────┐
  your nn.Module ──►│ torch.export.export          │──► ExportedProgram
                    │ .run_decompositions(          │      (custom-kernel ops survive
                    │    get_decomp_table())        │       decomposition intact)
                    └──────────────────────────────┘             │
                                                                 ▼
  your MSL body ───► TorchMetalKernel(...) ──► converter.register_custom_kernels([k])
                            ▲                            │
                            │                            ▼
                     torch reference          converter.add_exported_program(ep, ...)
                     (shape inference)                   │
                                                         ▼
                                                 converter.to_coreai()
                                                 program.optimize()
                                                 program.save_asset(path)
                                                         │
                                                         ▼
                                            one .aimodel directory,
                                            MSL text embedded inside
```

The output is not "a model plus a shader library". It is **one `.aimodel` directory** whose
program bytecode carries your Metal source as a string attribute on a `coreai.metal4_kernel`
operation. The kernel travels with the model, gets compiled by the Core AI runtime on the device
during specialization, and survives ahead-of-time compilation to `.aimodelc`.

> ✅ **VERIFIED** — the IR shape, from `tests/dsl/test_custom_kernels.py:116-128`, a live
> FileCheck assertion:
>
> ```
> coreai.metal4_kernel kernel_args(%a, %b),
>   threads_per_grid %g, threads_per_thread_group %tg, result_shapes(%rs)
>   {kernel_name = "custom_add_<8 random chars>", kernel_source = "<the whole MSL>"}
>   : (tensor<2x2x3xf16, #coreaix.hw_constraints<MTLBuffer, alignments: [1x1x1x1],
>                                                 interleave: [1x1x1]>>,
>      tensor<2x2x3xf16, …>,
>      tensor<3xui32>,          // threads_per_grid
>      tensor<3xui32>,          // threads_per_thread_group
>      tensor<3xui32>)          // result_shapes, one per result
>     -> tensor<2x2x3xf16, …>
> ```
>
> Three things worth reading off that: the MSL is a **string attribute** (`kernel_source`), the
> dispatch tuples and result shapes are **real tensor operands** (`tensor<3xui32>`), and every
> tensor touching the kernel carries an `#coreaix.hw_constraints<MTLBuffer, …>` encoding. That last
> one is why runtime inputs must be Metal-backed — §8.4.

> ✅ **VERIFIED** — the kernel is **not** a raw-Metal bypass. It is lowered to a first-class Core AI
> operation and executed by the OS Core AI runtime like any other op. Community summary of the same
> point, from `notes/repos/john-rocky-models.md` §5.6 (`custom-metal-kernels.md:11-14`):
> *"It is **not a raw-Metal bypass** — the MSL travels inside the single `.aimodel` artifact and runs
> in the OS Core AI runtime."*

### 1.2 The three pieces

**Piece one — the PyTorch reference.** A plain Python function with fully annotated parameters and
return type. This is what `torch.export` traces. It never runs on device; its entire job is to tell
the exporter the *shape and dtype* of the kernel's outputs so the surrounding graph type-checks.

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`, `torch_defn` row: *"Reference PyTorch
> implementation used for shape inference during `torch.export`."*

**Piece two — the Metal kernel body.** Note *body*, not function. You write the statements that go
inside the `[[kernel]]` function's braces. You do not write the signature, the buffer bindings, the
`#include`, or the `[[kernel]]` attribute.

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`, `src` row: *"Body of the Metal `[[kernel]]`
> function. The signature, buffer bindings, and `#include <metal_stdlib>` are generated automatically
> from `input_names`, `result_names`, and `metal_params`."*

**Piece three — the registration.** A `TorchMetalKernel(...)` object binding the two together, plus
the input and output names. The names are load-bearing in a way that is easy to miss: **the
identifiers you declare are the identifiers your MSL body uses.** The session's SiLU example
declares `"x"` and `"y"`, and the on-screen MSL body writes to `y` and reads from `x`.

> ✅ **VERIFIED** — session 325:186–204, verbatim:
> *"With just these two pieces, I can now register a Core AI **`TorchMetalKernel`**, give it **the
> Metal source, the PyTorch reference and the input and output names.** In this case, the input and
> output names are **`"x"` and `"y"`** respectively, and **you can see those names being used in the
> MSL kernel above**."*
> *"So you write the Metal. You write the PyTorch reference. **And Core AI binds them together.**"*

Then you call it. From session 325:202: *"Using it in a model, I will just **call it like any other
Python function. Pass the input, specify the thread grid and I am done.**"*

Except there is a fourth thing you must pass at every call site, and the presenter flags it
explicitly one sentence later. That is §6.

### 1.3 The one-line mental model

> **A `TorchMetalKernel` is a `torch.library.custom_op` whose lowering emits your MSL.**

That is not an analogy. It is the implementation. `TorchMetalKernel.__init__` registers a real
PyTorch custom operator under the `coreai_metal_kernels` namespace, and
`register_custom_kernels` registers a `coreai-torch` lowering for exactly that operator name:

> ✅ **VERIFIED** — `coreai_torch/_torch_metal_kernel.py:297-300`:
>
> ```python
> torch_custom_op = torch.library.custom_op(
>     f"coreai_metal_kernels::{self.name}",
>     mutates_args=(),
> )(wrapper)
> ```
>
> and `coreai_torch/converter.py:1050-1052`:
>
> ```python
> @self.register_torch_lowering(
>     f"coreai_metal_kernels::{kernel.name}.default"
> )
> ```

Two consequences follow immediately and both bite people:

1. **The kernel op survives `run_decompositions()`.** It is not an ATen op, so the decomposition
   table has nothing to say about it. ✅ **VERIFIED** — `docs/guides/custom-metal-kernels.ipynb`,
   step 3: *"Custom kernel ops are preserved through `run_decompositions()` — they are not
   decomposed."*
2. **The kernel name is a global registration key.** Two `TorchMetalKernel` objects with the same
   `name` string cannot both be registered with one converter, even if their MSL is byte-identical.
   §12.1 has the error.

---

## 2. When to do this at all

### 2.1 Apple's own framing is a gate, not an invitation

The session introduces custom kernels only *after* telling you not to need them:

> ✅ **VERIFIED** — session 325:170–177, verbatim and in order:
> *"Core AI **already ships with pre-packaged fast kernels and primitives for heavy operations like
> Scaled Dot Product Attention**, commonly found in Transformers. You can find examples of how to
> leverage these operations in the `coreai-models` repository."*
> *"But if you **live on the cutting edge** and want even more customization, we also have support for
> **custom Metal 4 kernels**."*

"Live on the cutting edge" is doing a lot of work in that sentence. The pre-packaged path is not a
consolation prize — it is a set of hand-tuned kernels that already know about the hardware you are
targeting, that survive OS updates, and that Apple regression-tests. Your kernel does none of those
things.

There is a second, quieter signal in the same repository. The `coreai-torch` docs guide opens with
its own three-item gate:

> ✅ **VERIFIED** — `docs/guides/custom-metal-kernels.ipynb`, "When You Need This":
> - *"You need a GPU kernel that is not available as a standard PyTorch or CoreAI op."*
> - *"You want to fuse multiple operations into a single Metal dispatch for performance."*
> - *"You need fine-grained control over thread dispatch, shared memory, or Metal-specific features."*

Note that "my op is slow" is not on that list. "Not available" and "fuse multiple operations" are.

### 2.2 The escalation ladder

In practice there are four rungs, and you should be able to say why each of the ones below you
failed before you climb.

| Rung | Mechanism | Cost to you | When it is the answer |
|---|---|---|---|
| 0 | **Plain ATen**, converted as-is | zero | Almost always. Start here; most models export without any of this. |
| 1 | **Composite ops** — `coreai_torch.composite_ops.SDPA` / `RoPE` / `RMSNorm` / `GatherMM` / `GatedDeltaUpdate`, or `ExternalizeSpec(composite_op_name=…)` | a module swap | A well-known building block is being decomposed into primitives and losing its optimized implementation. |
| 2 | **Custom lowering** — `register_torch_lowering("my_lib::op.default")` | Python, no MSL | Your op *can* be expressed with Core AI operations; you just need the converter to know how. Portable across compute units. |
| 3 | **`TorchMetalKernel`** | MSL + a maintenance burden | Nothing above expresses it, or profiling says the dispatch count is the bottleneck. **GPU only.** |

Rung 1 exists precisely so you do not need rung 3, and the mechanism is worth restating because it
is under-used:

> ✅ **VERIFIED** — `docs/guides/conversion-workflows.ipynb`, cell 8 rationale: *"Externalizing a
> submodule **preserves its operation boundary** during conversion… When you mark a well-known
> building block — such as attention, RoPE, or RMSNorm — as a **composite op**, the compiler
> recognizes that operation and can apply an optimized implementation tailored to it, producing a
> faster model."*

### 2.3 Rung 2 versus rung 3

Apple's own docs point you down the ladder rather than up it. The custom-kernel notebook's "Next
Steps" section lists custom lowering **first**, described as *"a simpler alternative for ops that can
be expressed using standard Core AI operations."* ✅ **VERIFIED** —
`docs/guides/custom-metal-kernels.ipynb`, final markdown cell.

The trade is:

| | `register_torch_lowering` | `TorchMetalKernel` |
|---|---|---|
| What you write | Python calling `coreai.*` graph builders | Metal Shading Language |
| Compute units | CPU / GPU / Neural Engine — whatever the compiler picks | **GPU only** |
| Fusion | Participates in normal graph optimization | **Is a fusion barrier** (§13.3) |
| Numerics | The compiler's | Yours, including every `exp()` you forgot to stabilize |
| API stability | Depends on `coreai._compiler.dialects` — *"private upstream API"* | Depends on `coreai.authoring` — *"experimental and subject to change"* |

Both carry an explicit instability warning. The `TorchMetalKernel` one appears twice, at the top of
both the API reference and the tutorial:

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`, warning block: *"Authoring Metal kernels uses
> APIs from `coreai-core` (such as `coreai.authoring`). **These APIs are experimental and subject to
> change in future releases.**"*

### 2.4 The compute-unit consequence is structural

This is the fact most likely to invalidate a plan, and it has nothing to do with betas or bugs:

> ✅ **VERIFIED (structural)** — the Neural Engine executes fixed hardware operations
> (convolution, layer norm, and friends); it cannot execute arbitrary Metal Shading Language. A
> model containing a `coreai.metal4_kernel` op therefore has a GPU-resident region, permanently.
> Community statement of the same, from `notes/repos/john-rocky-models.md` §5.6
> (`custom-metal-kernels.md:22-24`): *"The ANE runs only fixed hardware ops (Conv/LayerNorm/…); it
> cannot execute arbitrary MSL. So 'write fused-int8 kernels' is, by construction, a GPU strategy —
> independent of any beta bug."*

The same community source tabulates the two first-class authoring modes, sourced to Apple's own
agent-skill reference files (`neural_engine_rules.md` / `gpu_rules.md` in `apple/coreai-models`):

| | Neural Engine (iOS-style authoring) | GPU (macOS-style authoring) |
|---|---|---|
| Shapes | fully static | dynamic OK |
| Layout | **BC1S** `(B, C, 1, S)` | standard `(B, S, D)` / `(B, H, S, D)` |
| Projections | 1×1 `Conv2d` | `nn.Linear`, fused QKV |
| Attention | per-head, sequential | **fused native SDPA** |
| Custom MSL kernels | **NO** | **YES** (`TorchMetalKernel`) |
| Precision | fp16 only | fp16 weights, fp32 intermediates OK |

*(Community-compiled table, `notes/repos/john-rocky-models.md` §5.3, citing Apple's
`coreai-skills` reference files. Attribute as community-organized from Apple source, not as an Apple
publication.)*

There is a corollary for users of the optional `coreai-models` loader: its recognized
multi-entrypoint structures select its Neural Engine preference.[^sample-routing-policy] A custom
Metal kernel remains GPU-only, which may be exactly right, but do not generalize the helper’s naming
policy into a Core AI framework rule. See guide 05 in this part for the split, and Part 7 for what
the Swift side sees.

### 2.5 The honest performance picture

Two community results from the same author, on the same machine, using the same API, pointing in
opposite directions. Both are worth internalizing before you start.

> **Community-measured** — `notes/repos/john-rocky-models.md` §5.6, quoting the author's
> `custom-metal-kernels.md:116-125`. Single-author material with self-declared uncontrolled
> benchmarks; hardware M4 Max, beta macOS 27, dated mid-2026. Not an Apple figure.
>
> 1. *"The win is killing dispatch overhead via **fusion**, not kernelizing ops. Per-op
>    kernelization of small ops does NOT help — measured here: **kernelizing attention q/k/v/o was
>    *slower*; any single op-class ≤ 1.3 ms.** The real lever is collapsing **~28 ops/layer into 1–3
>    mega-kernels** (whole-layer fusion)."*
> 2. *"Custom int8 wins only on BIG memory-bound matmuls (FFN, the 262 144-vocab head)… **Don't
>    kernelize small projections (k/v).**"*
> 3. *"**Prefer native SDPA on GPU** — already fused; don't hand-roll it."*
> 4. *"A decode-step SSM scan kernel is only ~3–8 % faster than the plain torch graph (paired A/B) —
>    not worth the barrier + shape constraints. The SSM kernel win is **prefill** (chunked SSD,
>    13.7× on Mac), not decode."*

Against that, the same author's mixture-of-experts kernel is one of the largest single wins in the
whole corpus — 39 → 141 tok/s. §13 gives that result in full, including *why* it worked when
kernelizing attention did not.

The synthesis is uncomfortable but clear: **custom kernels pay when they change the asymptotics of
memory traffic or collapse a dispatch storm. They lose when they merely re-implement something Apple
already fused.** SDPA is the canonical example of the latter.

### 2.6 Get a profile first

You do not have to guess which ops dominate. `coreai_torch.debugging` ships an op-level
benchmarker:

```python
import sys
from coreai_torch.debugging.benchmarker import benchmark_coreai_program

result = await benchmark_coreai_program(
    coreai_program=coreai_program,
    inputs={"x": torch.randn(2, 4)},
    num_runs=50,
)
result.write_summary(sys.stdout)
for name, module in result.get_module_timings().items():
    print(f"{name}: {module.aggregated_op_stats.average:.3f}ms avg")
```

> ✅ **VERIFIED** — `docs/api/debugging.md`. Note `get_module_timings()` keys by **PyTorch module**,
> which is what makes the output actionable: you learn that `detector.decoder` costs 40 % of the
> graph, not that `aten.mul` does.
>
> ⚠️ During the preview, operation-level debug metadata requires two environment variables to be set
> **before** conversion, or the module and source attribution is simply missing:
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```
> ✅ **VERIFIED** — `docs/api/debugging.md:5-13`.

And one more measurement rule, which is the most reusable sentence in the community archive:

> **Community-measured protocol** — `notes/repos/john-rocky-models.md` §5.6 (`:124`):
> *"**Measurement protocol matters more than the kernel: pair both arms in one process, interleave
> ≥ 8 reps, report median + spread; unpaired single-shot on a ±15 %-drift machine will confirm
> anything.**"*

---

## 3. The complete worked example: a fused SiLU

### 3.1 Apple's canonical example, verbatim

Before the session's example, here is the one that is quoted verbatim from Apple's shipping docs and
that you can copy without any reconstruction. It is a two-input element-wise add.

> ✅ **VERIFIED** — `docs/guides/custom-metal-kernels.ipynb` cells 2, 4, 6, 8 and
> `docs/api/TorchMetalKernel.md` "Example". Reproduced in full; the only edit is merging the
> notebook's repeated imports.

```python
import torch
import torch.nn as nn
from coreai.authoring import MetalParameter

from coreai_torch import TorchConverter, TorchMetalKernel, get_decomp_table


def torch_add(x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
    """Reference implementation for shape inference during export."""
    return x + y


custom_add = TorchMetalKernel(
    "vector_add",
    input_names=["x", "y"],
    result_names=["output"],
    src="output[id] = x[id] + y[id];",
    torch_defn=torch_add,
    metal_params=[
        MetalParameter("id", "uint", "thread_position_in_grid"),
    ],
)


class AddModel(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return custom_add(
            x,
            y,
            threads_per_grid=(x.shape[0], 1, 1),
            threads_per_thread_group=(1, 1, 1),
            result_shapes=[list(x.shape)],
        )


model = AddModel().eval()
example_inputs = (torch.randn(16), torch.randn(16))

exported = torch.export.export(model, args=example_inputs)
exported = exported.run_decompositions(get_decomp_table())

converter = TorchConverter()
converter.register_custom_kernels([custom_add])
converter.add_exported_program(
    exported,
    input_names=["x", "y"],
    output_names=["result"],
)
coreai_program = converter.to_coreai()
coreai_program.optimize()
```

Nine lines of that are the entire API surface. Everything else in this guide is about the ways those
nine lines go wrong.

Two details in the boilerplate that are not about Metal at all but will stop you before you get
there:

- **`.eval()` before export.** ✅ **VERIFIED** — `docs/getting-started/quickstart.ipynb` cell 3:
  *"**Always call `.eval()` before exporting.** Layers such as `BatchNorm` and `Dropout` behave
  differently in training mode and produce a different graph."*
- **`run_decompositions(get_decomp_table())` is mandatory**, not optional, and Core AI's table is
  not PyTorch's. ✅ **VERIFIED** — `docs/api/TorchConverter.md:53-55`: *"The caller **must** call
  `run_decompositions()` on the program before passing it here — use `get_decomp_table()` to preserve
  known composite ops in the lowered IR."* Using `torch.export.default_decompositions()` instead
  decomposes `instance_norm` into an unsupported op and you get a `ValueError` listing unsupported
  ATen ops.

### 3.2 The session's example: a fused SiLU

Session 325 uses the Sigmoid Linear Unit — `x · σ(x)` — as its demonstration.

> ✅ **VERIFIED** — session 325:186–194, verbatim:
> *"First, I define a **PyTorch reference** for our example. A standard **Sigmoid Linear Unit, or
> SiLU**. It's a common activation function used in generative transformer models. **This is what
> `torch.export` sees during tracing.**"*
> *"Below that, I implement the actual Metal kernel in MSL. This is a **simple element-wise kernel,
> one thread per element**, that computes the **fused activation** directly on the GPU."*

Here is that example built from the verified API. **The Python is verified API usage; the MSL body is
written for this guide, not quoted from Apple.**

> 🟡 **RECONSTRUCTED — the MSL body only.** The on-screen source at 325:191 was never read aloud, so
> the exact expression Apple used is unknown: whether they wrote `x / (1 + exp(-x))` or
> `x * (1 / (1 + exp(-x)))`, and whether they used `exp`, `metal::precise::exp` or `fast::exp`, is
> not recoverable from the transcript. Every *API* call below is ✅ verified against
> `docs/api/TorchMetalKernel.md` and `coreai_torch/_torch_metal_kernel.py`; only the four lines
> between the triple quotes are inference. Treat the shape as right and the arithmetic as yours to
> own.

```python
import torch
import torch.nn as nn
from coreai.authoring import MetalParameter

from coreai_torch import TorchConverter, TorchMetalKernel, get_decomp_table


# ── Piece 1: the PyTorch reference. This is what torch.export sees. ────────────
def torch_silu(x: torch.Tensor) -> torch.Tensor:
    """SiLU / swish: x * sigmoid(x). Never runs on device — shape inference only."""
    return x * torch.sigmoid(x)


# ── Piece 2 + 3: the MSL body, and the object that binds it to the reference. ──
SILU_SRC = """
    // One thread per element. `id` is bound by metal_params below.
    // `x` and `y` are the names declared in input_names / result_names.
    if (id >= x.get_extent(0)) { return; }          // guard: grid may over-dispatch
    const float v = float(x[id]);
    y[id] = v / (1.0f + metal::precise::exp(-v));   // fused sigmoid-linear unit
"""

silu_kernel = TorchMetalKernel(
    "fused_silu",
    input_names=["x"],
    result_names=["y"],
    src=SILU_SRC,
    torch_defn=torch_silu,
    metal_params=[
        MetalParameter("id", "uint", "thread_position_in_grid"),
    ],
)


# ── Calling it: like any other Python function, plus the dispatch arguments. ───
class SiLUModel(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        n = x.shape[0]
        return silu_kernel(
            x,
            threads_per_grid=(n, 1, 1),
            threads_per_thread_group=(min(n, 256), 1, 1),
            result_shapes=[list(x.shape)],   # <- REQUIRED at every call site. §6.
        )


# ── Conversion: register the kernels FIRST, then add the program. ─────────────
model = SiLUModel().eval()
example_inputs = (torch.randn(4096, dtype=torch.float16),)

exported = torch.export.export(model, args=example_inputs)
exported = exported.run_decompositions(get_decomp_table())

converter = TorchConverter()
converter.register_custom_kernels([silu_kernel])          # BEFORE add_exported_program
converter.add_exported_program(
    exported,
    input_names=["x"],
    output_names=["y"],
)
coreai_program = converter.to_coreai()
coreai_program.optimize()
```

Read the MSL body against the declarations one more time, because this is the coupling that the
session calls out and that nothing in Python checks for you:

| MSL identifier | Where it comes from | Declared as |
|---|---|---|
| `x` | `input_names=["x"]` | a `device` tensor parameter, generated |
| `y` | `result_names=["y"]` | a `device` tensor parameter, generated |
| `id` | `metal_params=[MetalParameter("id", …)]` | `uint id [[thread_position_in_grid]]`, generated |

If you rename `input_names` to `["inp"]` and leave the body saying `x`, nothing in `TorchMetalKernel`
complains — the constructor validates names against each other and against `torch_defn`'s parameter
*count*, never against the text of `src`. You find out at `load_function()` time, from a message that
does not mention `x`. §12.4.

### 3.3 What the session says happens next

> ✅ **VERIFIED** — session 325:203–204:
> *"**One thing to note, is that I pass in the `result_shapes` to every instantiation of the custom
> kernel** in the PyTorch source. **This allows Core AI to bake in the computation of the output
> shapes of the kernel from the input shapes, if your model has dynamic shaped inputs.**"*
> *"When I convert with `TorchConverter`, **I register my custom kernels with the converter, then add
> the exported program as before.** The Metal source gets embedded directly in the asset — **a single
> artifact. The kernel travels with the model.**"*

Both of those sentences describe hard requirements with non-obvious failure modes, and each gets its
own section: `result_shapes` is §6, registration order is §8.1.

---

## 4. The constructor, field by field

### 4.1 The signature

> ✅ **VERIFIED** — `coreai_torch/_torch_metal_kernel.py:71-81`, read from the shipping source.
> Identical to `docs/api/TorchMetalKernel.md`.

```python
class TorchMetalKernel(CustomMetalKernel):
    def __init__(
        self,
        name: str,
        input_names: list[str],
        result_names: list[str],
        src: str,
        torch_defn: Callable[..., Any],
        metal_params: list[MetalParameter] | None = None,
        helper_src: str | None = None,
        template_dtypes: dict[str, str] | None = None,
    ) -> None: ...
```

and the call:

```python
    def __call__(
        self,
        *args: Any,
        threads_per_grid: tuple[int, int, int],
        threads_per_thread_group: tuple[int, int, int],
        result_shapes: list[list[int]],
    ) -> Any: ...
```

✅ **VERIFIED** — `_torch_metal_kernel.py:413-419`. All three dispatch arguments are **keyword-only**
(they follow `*args`) and **none has a default**. You cannot forget one; you can only get one wrong.

`MetalParameter` is re-exported from `coreai.authoring` for convenience:

> ✅ **VERIFIED** — `coreai_torch/__init__.py:186-187`, with Apple's own comment:
> ```python
> # Re-export MetalParameter so users don't need a separate coreai import.
> from coreai.authoring import MetalParameter
> ```
> so `from coreai_torch import TorchMetalKernel, MetalParameter` and
> `from coreai.authoring import MetalParameter` are equally valid. Apple's docs page uses the first
> form; Apple's notebook uses the second.

### 4.2 `name`

Becomes part of the emitted kernel's name, and is the registration key.

- Must be a non-empty, non-whitespace string. ✅ **VERIFIED** — `_torch_metal_kernel.py:145-147`,
  `ValueError(f"Kernel name must be a non-empty string, got {name!r}")`. Apple's comment explains
  why: *"The Swift runtime (`CustomMetalKernel.swift`) treats an empty `kernelName` as a user
  error; catch it eagerly with a clear message rather than letting it surface deep in the runtime."*
- The name in the IR is **not** the name you gave it. Each `(rank, dtype)` combination gets an
  8-character random suffix: `kernel_name = "custom_add_<8 chars>"`. ✅ **VERIFIED** —
  `tests/dsl/test_custom_kernels.py:122` and `tests/dsl/test_kernel_collisions.py:6-14`.
  **Consequence:** never pattern-match on emitted kernel names. Apple's own tests diff by the
  `kernel_source` string attribute instead, with a helper that walks the escaped string
  (`test_dtype_specialization.py:56-80`).

### 4.3 `input_names` and `result_names`

The identifiers your MSL body uses, and — for inputs — the positional binding to `torch_defn`'s
parameters.

Validation, all at construction time:

| Rule | Error |
|---|---|
| `result_names` non-empty | `ValueError("result_names must contain at least one entry")` |
| no duplicates within either list | `ValueError(f"Duplicate {label} names: {duplicates}")` |
| no name in both lists | `ValueError(f"Names appear in both input_names and result_names: {overlap}")` |
| `len(input_names) == len(torch_defn parameters)` | `ValueError("torch function should have same number of parameters as specified by input names, expected N, got M")` |

✅ **VERIFIED** — `_torch_metal_kernel.py:149-201`; each message is pinned by a test in
`tests/dsl/test_metal_kernel_robustness.py:355-411` and `tests/dsl/test_custom_kernels.py:254-272`.

Apple's rationale for the overlap check is worth quoting because it tells you what the generated
code looks like: *"Duplicate or overlapping names produce ill-formed Metal kernel sources (two
parameters with the same identifier) and confusing failures."* (`_torch_metal_kernel.py:154-157`.)
Inputs and results are parameters of the **same** function — there is no separate output binding
mechanism.

**Zero inputs is legal.** A kernel with only results and thread parameters constructs and lowers
cleanly (`tests/dsl/test_metal_kernel_robustness.py:83-138`, *"Kernels with zero kernel inputs (only
outputs + thread params)"*). **Zero results is not** — it is rejected at construction.

### 4.4 `src`

The **body**. Not the function. The generated wrapper supplies:

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`: *"The signature, buffer bindings, and
> `#include <metal_stdlib>` are generated automatically from `input_names`, `result_names`, and
> `metal_params`."*

An **empty `src` is accepted** — Apple's own test says *"An empty body `src` is acceptable — Python
should not over-validate"* and asserts that it *"still produces valid Metal source and lowers
cleanly"* (`tests/dsl/test_metal_kernel_robustness.py:167-198`). So does a body of pure garbage;
see §12.4, which is the most important paragraph in this guide.

### 4.5 `torch_defn`

The reference implementation. Its constraints are strict, checked at construction, and worth
learning as a list because every one of them has a test:

> ✅ **VERIFIED** — `_torch_metal_kernel.py:174-244`, `docs/api/TorchMetalKernel.md` "Constraints".

1. **Every parameter must be annotated** as `torch.Tensor`, `int`, `float` or `bool`.
   Anything else — including `str` — raises
   `TypeError("custom kernels only support `torch.Tensor`, `float`, `bool` and `int` inputs, got …")`.
2. **No variadic parameters.** `*args` / `**kwargs` raise
   `TypeError("custom kernels do not support variadic parameters (*args / **kwargs); got parameter '…' with kind …")`.
3. **Parameter count must equal `len(input_names)`.**
4. **The return annotation must be** `torch.Tensor`, `list[torch.Tensor]`, or
   `tuple[torch.Tensor, ...]` **with a concrete member count**. `tuple[torch.Tensor, ...]` (the
   ellipsis form), `Sequence[torch.Tensor]`, and bare `int` are all rejected —
   `tests/dsl/test_custom_kernels.py:294-343` pins all three.
5. **Arity must match**: a single-`Tensor` return with two `result_names` raises
   `ValueError("torch_defn returns a single torch.Tensor, but result_names has 2 entries: …")`; a
   concrete tuple whose length differs raises the analogous message. `list[torch.Tensor]` is
   variable-length so it is only checked at call time.

> ✅ **VERIFIED, and a real trap if your module uses `from __future__ import annotations`.**
> `TorchMetalKernel` resolves annotations with `inspect.signature(torch_defn, eval_str=True)`
> specifically for this. Apple's comment (`_torch_metal_kernel.py:104-106`): *"eval_str=True resolves
> PEP 563 string annotations introduced by `from __future__ import annotations` in the caller's
> module. Without this, `param.annotation` is the bare string `"torch.Tensor"` and the identity checks
> in `_validate_torch_inputs` fail."* This is handled for you — but it means your annotations must be
> *resolvable in the defining module's namespace*. A `torch_defn` annotated with a type imported
> under `if TYPE_CHECKING:` will raise at construction, not at export.

**What `torch_defn` is *not*.** It is not a fallback. It never executes on device, and Core AI does
not compare its output against your kernel's. It is a shape oracle and nothing more — which is
exactly why §5.4's failure mode is so nasty: a reference that is correct and a kernel that is wrong
produce a model that converts, exports, and lies.

### 4.6 `metal_params`

The thread attributes bound into the generated signature.

```python
MetalParameter("gid", "uint2", "thread_position_in_grid")
```

> 🟡 **RECONSTRUCTED — the parameter *names*.** The positional form above is ✅ verified from six
> independent Apple call sites (`docs/api/TorchMetalKernel.md`, the notebook, and four test files).
> The keyword spelling `MetalParameter(name=…, dtype=…, attr=…)` is reported by community notes
> citing `coreai/authoring/metal.py:36-52`, which is not in this corpus — `coreai-core` ships as a
> wheel, not source. **Safe default meanwhile: pass the three arguments positionally**, exactly as
> every Apple example does. That form is verified and cannot be wrong.

Attributes seen in Apple's own kernels, all ✅ verified from `tests/dsl/`:

| Attribute | Type used | Where |
|---|---|---|
| `thread_position_in_grid` | `uint` | element-wise kernels, `test_custom_kernels.py:45` |
| `thread_position_in_grid` | `uint2` | 2-D matmul, `test_matmul_kernel.py:62` |
| `thread_position_in_threadgroup` | `uint2` | tiled matmul, `test_matmul_kernel.py:158` |
| `threadgroup_position_in_grid` | `uint2` | tiled matmul, `test_matmul_kernel.py:159` |

There is no evidence in the corpus for which *other* MSL thread attributes are accepted — the
mechanism looks like a pass-through of the attribute string, but nothing verifies that.

> 🔴 **GAP — the accepted set of `MetalParameter` attribute strings is unenumerated.** Apple's
> examples cover exactly the three above. Whether `simdgroup_index_in_threadgroup`,
> `thread_index_in_simdgroup`, `threads_per_threadgroup` and friends are accepted is not shown
> anywhere in this corpus, and there is no validation list in `_torch_metal_kernel.py` (the file
> never inspects the attribute string — it is forwarded to `CustomMetalKernel` in `coreai-core`).
> Resolving it needs the `coreai.authoring.metal` source or a runtime experiment. **Safe default
> meanwhile:** stick to the four attributes above, and if you need SIMD-group indices, derive them
> from `thread_position_in_threadgroup` inside the body rather than requesting a new attribute —
> that is pure MSL and cannot be rejected by the binding layer.

`metal_params` counts against the 31-parameter budget. See §12.2.

### 4.7 `helper_src`

Additional Metal source pasted **before** the kernel definition.

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`: *"Additional Metal source pasted before the
> kernel definition (helper functions, type aliases, etc.)."*

This is where `#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>`, `using namespace`
declarations, `struct`s, type aliases and any function you want to call from the body go. For
anything larger than an element-wise operation this is where most of your code lives. §11.

### 4.8 `template_dtypes`

One kernel, many dtypes. §10.1.

---

## 5. What the converter generates — and the axis reversal

### 5.1 The generated function

You write a body; the converter writes the function around it. Assembling what is verifiable, the
generated source for the `vector_add` example has this shape:

> 🟡 **RECONSTRUCTED — the exact generated text.** Individual *fragments* are ✅ verified from test
> assertions against the emitted `kernel_source` attribute: `"device half"` and `"device float"`
> both appear (`tests/dsl/test_dtype_specialization.py:251-252`), scalar parameters appear as
> `constant float& c ` (`tests/dsl/test_scalar_inputs.py:119`), and the docs state that
> `#include <metal_stdlib>` and the buffer bindings are generated. The *layout* below — parameter
> order, buffer indices, the `tensor<>` template arguments — is assembled from those fragments plus
> the community `_tensorops_proto` scripts, which describe the auto-generated signature as
> `tensor<device T, dextents, tensor_handle>`. Do not copy this as source; it is a mental model.

```cpp
#include <metal_stdlib>
// … plus whatever you put in helper_src, pasted here …

[[kernel]] void vector_add_<8 random chars>(
    /* one parameter per input_names entry, in order   */  device-address-space tensors,
    /* one parameter per result_names entry, in order  */  device-address-space tensors,
    /* any rank-0 scalar inputs                        */  constant float& c   [[buffer(N)]],
    /* one parameter per metal_params entry            */  uint id [[thread_position_in_grid]])
{
    // ← your `src` goes here, verbatim
}
```

Three facts you can rely on:

1. **Tensor inputs and results live in the `device` address space.** ✅ **VERIFIED** —
   `test_dtype_specialization.py:251-252` asserts `"device half"` and `"device float"` are present in
   the two emitted sources.
2. **They are Metal *tensor* objects, not raw pointers.** They support `.get_extent(i)`,
   `.get_rank()`, multi-index subscripting `A[k, m]`, and `metal::array<uint, N>` indexing. ✅
   **VERIFIED** — all four appear in Apple's own kernel fixtures (`tests/dsl/conftest.py:37-140`).
3. **Scalars are `constant T&`, not tensors.** ✅ **VERIFIED** — `test_scalar_inputs.py:119`. §9.

### 5.2 ⚠️ The axis reversal

This is the one to tattoo somewhere.

> ⚠️ **SILENT FAILURE — `MTLTensor` extents are the *reverse* of the torch shape, and your PyTorch
> reference cannot detect the mismatch.**
>
> ✅ **VERIFIED** — Apple's own module docstring, `tests/dsl/test_thread_config.py:16-20`:
>
> > *"Note: `MTLTensor` extents are stored in **reverse** of the torch shape (see
> > `NDArray+Metal.swift`: `shapeSpan.reversed()`). For a torch tensor of shape `(D0, D1, D2)` the
> > kernel sees extents `(D2, D1, D0)`; `get_extent(0)` is the innermost (fastest-varying) torch dim.
> > **Multi-dim dispatch tuples must match this convention.**"*
>
> Apple's own matmul fixture spells out the consequence in a comment
> (`tests/dsl/conftest.py:166-170`) — read it against a torch `x` of shape `(M, K)` and `y` of shape
> `(K, N)`:
>
> ```cpp
> // A shape [K,M]: A[k, m]   B shape [N,K]: B[n, k]   C shape [N,M]: C[n, m]
> const uint K = A.get_extent(0);
> const uint M = A.get_extent(1);
> const uint N = B.get_extent(0);
> ```
>
> **Everything is transposed.** `A.get_extent(0)` returns `K` — the *last* torch dimension. The
> subscript order is reversed too: `A[k, gid.y]` reads torch element `x[gid.y, k]`.
>
> **Why it is silent.** Your `torch_defn` is written in torch coordinates and is correct. It is
> traced, it type-checks, the graph converts, the asset saves. Only the Metal body has the wrong
> convention, and the only thing that would catch it is a numerical comparison against the reference
> — which Core AI does not perform for you.
>
> **The community NaN, in full** (`notes/repos/john-rocky-models.md` §9.2, community-measured, single
> author, beta OSes): a per-row scale buffer for a ternary-weight kernel had to be torch `[N, 1]`, not
> `[1, N]`, *"because the DSL reverses axes, so the Metal `D[0, n]` reads torch `d[n,0]`. **The torch
> reference (`d.reshape(-1,1)`) is shape-agnostic so CPU passed either way — but the Metal kernel read
> out-of-bounds and produced NaN logits on the engine.**"*
>
> The same author independently rediscovered the rule with a 61-line probe kernel that writes
> `out[tgid.x, tgid.y] = 100 + 10*x + y` into a known-good `[64, 32]` output and reads the result
> back in numpy, recording in a code comment: *"Metal tensor coords are TRANSPOSED vs numpy:
> `torch[M,K]` → tensor extents `[K,M]` (dim0 = inner/contiguous). Verified with `probe_dispatch`:
> `out[a,b]` lands at `numpy[b,a]`."*
>
> **Do the probe.** Thirty lines, five minutes, and it makes every subsequent kernel in the project
> cheaper. §14.1 gives it.

### 5.3 The reversal reaches the dispatch tuple too

Apple's docstring says *"multi-dim dispatch tuples must match this convention"*, and the matmul
fixture shows what that means in practice. For torch `x: (M, K)`, `y: (K, N)`, output `(M, N)`:

```python
grid = (N, M, 1)          # x dimension of the grid indexes N, y indexes M
threads = (16, 16, 1)
result_shape = [M, N]     # result_shapes stays in TORCH order
```

✅ **VERIFIED** — `tests/dsl/test_matmul_kernel.py:75-87`. Note the asymmetry that makes this
genuinely confusing: **`result_shapes` is in torch order** (`[M, N]`), while **`threads_per_grid` is
in tensor/Metal order** (`(N, M, 1)`), and the body indexes `C[gid.x, gid.y]` = `C[n, m]`. Three
conventions, one call site.

A working rule that keeps it straight:

> - **Python-side arguments** (`result_shapes`, `x.shape[…]`) — torch order.
> - **Metal-side everything** (`get_extent(i)`, subscripts, and the grid you are indexing *with*) —
>   reversed order, fastest-varying dimension first.
> - `threads_per_grid` is Metal-side, because `gid.x` is what indexes it.

### 5.4 The general lesson: a correct reference masks an incorrect kernel

The axis reversal is the most common instance of a general property of this API:

> ⚠️ **SILENT FAILURE — the PyTorch reference is not a test.** `torch_defn` is used for shape
> inference. It is not executed alongside your kernel, not compared against it, and not shipped in
> the asset. A kernel that returns zeros, garbage, or NaN produces an `.aimodel` that converts
> without complaint. The only thing standing between you and a wrong model is a numerical test you
> write yourself. §14.

This is also why the community protocol note is so emphatic that eager-mode PyTorch is not an
adequate check for a kernel-bearing module:

> **Community-measured** — `notes/repos/john-rocky-models.md` §5.3: *"`MetalSwitchGLU`'s eager torch
> path is unreliable (garbage on MPS) — **judge schemes ONLY via a real export + engine run, never
> eager-MPS**."*

### 5.5 Supported element dtypes

Kernel inputs and results must have a dtype the converter can map to an MSL type. Unmapped dtypes
raise at **conversion** time, not construction:

```
TypeError: kernel input at index 0 has unsupported dtype: f8E5M2
TypeError: Result type at index 0 has unsupported dtype: f8E5M2
```

✅ **VERIFIED** — `tests/dsl/test_custom_kernels.py:382-452`, which uses `torch.float8_e5m2` to prove
both messages.

The mapping itself is in `coreai-core`, which is not source-available here. The community record of
it is:

> 🟡 **RECONSTRUCTED — the dtype table.** Community-reported mapping
> (`notes/repos/john-rocky-models.md`, citing `coreai/authoring/metal.py`):
> `bf16→bfloat`, `f16→half`, `f32→float`, `si8→int8_t`, `ui8→uint8_t`, `ui32→uint`, `si32→int`,
> `i1→bool`. **Independent corroboration for the float half:** `template_dtypes` substitution is
> documented by Apple as producing *"`half`, `float`, `bfloat`"* (`docs/api/TorchMetalKernel.md`),
> and Apple's own matmul test parametrizes over `torch.bfloat16, float16, float32, int8, int16,
> int32` and passes for all six (`tests/dsl/test_matmul_kernel.py:28-38`) — so int16 is supported
> too, which the community list omits. **Safe default:** stick to fp16/bf16/fp32 for data and
> int8/int32 for indices; anything exotic, test the conversion first — the `TypeError` is immediate
> and cheap to trigger.

**Sub-byte types are not on that list.** If you are working with int4 weights you pass them as
packed `uint8` and reinterpret inside the kernel. §11.4.

---

## 6. `result_shapes`: why every call site

### 6.1 What Apple says, and what it means

> ✅ **VERIFIED** — session 325:203, verbatim:
> *"**One thing to note, is that I pass in the `result_shapes` to every instantiation of the custom
> kernel** in the PyTorch source. **This allows Core AI to bake in the computation of the output
> shapes of the kernel from the input shapes, if your model has dynamic shaped inputs.**"*

Unpack that. Core AI's compiler needs to know the shape of every tensor in the graph. For a normal
op it derives that from the op's semantics. For your kernel it cannot — the compiler has no idea what
your MSL does. So you tell it, per call site, by passing an expression that **relates the output
shape to the input shapes**:

```python
result_shapes=[list(x.shape)]                 # "same shape as x"
result_shapes=[[x.shape[0], y.shape[1]]]      # "M from x, N from y"
result_shapes=[list(x.shape), list(x.shape)]  # two results, both x-shaped
```

Because those expressions are evaluated *during tracing*, they compose with `torch.export`'s
symbolic shapes. When `x.shape[0]` is a `Dim`, the expression carries the symbol rather than a
number — which is the "baking in" the presenter describes.

### 6.2 It is not optional and it is not defaulted

```python
def __call__(self, *args, threads_per_grid, threads_per_thread_group, result_shapes): ...
```

Keyword-only, no default. Omitting it is a `TypeError` from Python itself. Getting the *count* wrong
is caught explicitly:

```
ValueError: result_shapes must contain one shape per result name;
            expected 2 (for ['out_sin', 'out_cos']), got 1
```

✅ **VERIFIED** — `_torch_metal_kernel.py:434-440`; pinned by
`tests/dsl/test_metal_kernel_robustness.py:545-556`.

### 6.3 What it becomes

Each shape becomes a `uint32` tensor operand on the op:

> ✅ **VERIFIED** — `_torch_metal_kernel.py:442-445`:
> ```python
> grid_tn   = torch.tensor(list(threads_per_grid),         dtype=torch.uint32)
> tgroup_tn = torch.tensor(list(threads_per_thread_group), dtype=torch.uint32)
> shape_tns = [torch.tensor(shape, dtype=torch.uint32) for shape in result_shapes]
> return self.torch_custom_op(*args, grid_tn, tgroup_tn, *shape_tns)
> ```
>
> and on the torch-op side the signature is the `torch_defn` signature **augmented** with
> `threads_per_grid`, `threads_per_thread_group`, and one `result_shape_<name>` parameter per result
> (`_torch_metal_kernel.py:132-135, 258-281`). The wrapper strips those extra arguments before
> calling your reference, so `torch_defn` never sees them (`:285-295`).

In the IR they show up as the trailing `tensor<3xui32>` operands you saw in §1.1.

### 6.4 ⚠️ The failure mode: a hardcoded shape under a dynamic input

> ⚠️ **SILENT FAILURE — a literal `result_shapes` compiles into a dynamic-shaped graph without
> complaint.**
>
> Apple's own test demonstrates the exact configuration. `tests/dsl/test_custom_kernels.py:58-73`
> defines a model whose call site passes `result_shapes=[result_shape]` where `result_shape` is the
> Python literal `[2, 2, 3]`. `test_import_dynamic_shape` (`:136-182`) then exports that model with
> `dynamic_shapes={"x": {0: dim}, "y": {0: dim}}` and asserts the emitted IR:
>
> ```
> … result_shapes(%rs) … : (tensor<?x2x3xf16, …>, tensor<?x2x3xf16, …>,
>                           tensor<3xui32>, tensor<3xui32>, tensor<3xui32>)
>                           -> tensor<?x2x3xf16, …>
> ```
>
> The tensor types are **`?x2x3`** — dimension 0 is dynamic — while the `result_shapes` operand is a
> **constant** three-element `ui32` tensor holding `[2, 2, 3]`. The conversion succeeds. The test
> passes; it is checking IR structure, not numerics.
>
> **What that means for you:** if the first dimension arrives as 7 at runtime, the graph's type says
> `?` and your kernel has been told to write a `[2, 2, 3]` result. Nothing in the Python layer, the
> converter, or the emitted IR objects.
>
> **The rule:** `result_shapes` entries must be **expressions over the input tensors' `.shape`**, at
> every call site, always. `list(x.shape)` — not `[2, 2, 3]`, not a module attribute captured at
> `__init__`, not a constant computed from `example_inputs`. Every Apple example in the tutorial, the
> API docs and the test suite that is not specifically testing IR structure does exactly this:
> `result_shapes=[list(x.shape)]`.

### 6.5 What "every instantiation" actually means

The word "instantiation" in the transcript means **call site**, not kernel object. One
`TorchMetalKernel` object called from three places in `forward()` needs three `result_shapes`
arguments, each computed from the tensors flowing into *that* call. This is not redundancy; the
converter lowers each FX node independently and each node carries its own shape operands.

The kernel *object* is reusable and should be reused — a module-level singleton called from many
places is the normal pattern, and the kernel cache (§10.2) is built for it.

### 6.6 The dynamic-shape boundary

> 🔴 **GAP — the symbolic path through `result_shapes` is not verified end to end.** The mechanism is
> clear at the IR level (a `ui32` shape tensor operand per result) and the transcript states the
> intent plainly ("bake in the computation of the output shapes… if your model has dynamic shaped
> inputs"). What this corpus does **not** contain is a test that exports a kernel-bearing model with
> a genuinely dynamic dimension, computes `result_shapes` from `x.shape`, and then *runs* it at two
> different sizes. Apple's dynamic-shape test hardcodes the shape and only checks IR
> (`test_custom_kernels.py:136-182`); Apple's dynamic matmul test
> (`test_matmul_kernel.py:103-120`, `dynamic_shapes` over the `K` dimension) does derive
> `result_shape = [M, N]` from `x.shape`/`y.shape` — but `M` and `N` are the *static* dimensions
> there; only `K`, which does not appear in the result, is dynamic.
>
> Concretely unresolved: what `torch.tensor([SymInt, 2, 3], dtype=torch.uint32)` does during
> `torch.export` tracing — whether it specializes to the example value, produces a symbolic operand,
> or raises. Resolving it needs one experiment on a Mac with `coreai-torch` installed: export a
> kernel model with `Dim` on the result-bearing axis, run it at two sizes, compare.
>
> **Safe default meanwhile:** (a) always derive `result_shapes` from input `.shape`; (b) if a
> *result-bearing* dimension is dynamic, verify numerically at two or more sizes before shipping —
> `validate_numerical_output(..., dynamic_shapes=...)` from Apple's test harness (§14.3) is set up
> for exactly this; (c) if you cannot verify, prefer a static shape for the kernel's output and
> reshape outside the kernel, which costs one op and removes the risk.

---

## 7. Thread dispatch: grid, threadgroup, and bounds

### 7.1 The two tuples

Both are 3-tuples, both keyword-only, both validated:

```
ValueError: threads_per_grid must be a 3-tuple, got 2 elements: (16, 1)
ValueError: threads_per_thread_group must be a 3-tuple, got 4 elements: (…)
```

✅ **VERIFIED** — `_torch_metal_kernel.py:421-433`; pinned by
`tests/dsl/test_metal_kernel_robustness.py:503-541`.

Apple's docstring states the runtime contract precisely:

> ✅ **VERIFIED** — `tests/dsl/test_thread_config.py:8-14`:
> *"The runtime forwards `threads_per_grid` and `threads_per_threadgroup` verbatim to Metal's
> **`dispatchThreads`**. Threadgroup sizes exceeding `maxTotalThreadsPerThreadgroup` (1024 on current
> Apple Silicon) are rejected by Metal at PSO time; valid sizes near or above the visible grid are
> simply rounded up — **the kernel is responsible for guarding out-of-bounds reads/writes when
> `threads_per_grid` exceeds the visible tensor extent.**"*

Two things follow. First, this is `dispatchThreads`, not `dispatchThreadgroups` — you give a
**thread count**, not a threadgroup count, so no `ceil_div` is needed on your side. Second, **bounds
guarding is your job**, always.

### 7.2 The converter does not validate your dispatch

> ✅ **VERIFIED** — `tests/dsl/test_thread_config.py:130-157`, name and docstring:
> `test_threadgroup_larger_than_typical_pso_max_lowers` — *"An over-large
> `threads_per_thread_group` is accepted at the IR layer. The runtime clamps this to
> `pso.maxTotalThreadsPerThreadgroup` (1024 on most Apple Silicon GPUs); **the converter should not
> pre-validate that — it's a hardware property only known at PSO compilation time.**"*
>
> The test passes `threads_per_thread_group=(2048, 1, 1)` and asserts the program lowers.

So a dispatch configuration that no GPU can execute converts cleanly. This is a deliberate design
choice, and a defensible one, but it means **the first place an impossible dispatch can surface is
device load**.

Apple's own softmax fixture guards against it in Python rather than trusting the runtime:

```python
MAX_THREADS = 1024
# "We can't exceed 1024 threads per thread group. We should probably have this be
#  deferred to the runtime, but we're putting this guard in here so that the tests
#  don't choose threadgroups that are too large."
threads_per_thread_group=(min(MAX_THREADS, num_slices), 1, 1)
```

✅ **VERIFIED** — `tests/dsl/test_softmax.py:32-37, 76-79`. Copy the pattern.

### 7.3 Bounds guards, three canonical forms

Apple's own fixtures show three, in increasing order of care.

**1-D, guard on the first extent** (`test_thread_config.py:67`):

```cpp
if (id >= x.get_extent(0)) return;
out[id] = x[id];
```

**2-D, guard both** (`conftest.py:129-141`, the naive matmul):

```cpp
const uint K = A.get_extent(0);
const uint M = A.get_extent(1);
const uint N = B.get_extent(0);

if (gid.x >= N || gid.y >= M) return;   // bounds guard

TYPE sum = ZERO;
for (uint k = 0; k < K; ++k) {
    sum += A[k, gid.y] * B[gid.x, k];
}
C[gid.x, gid.y] = sum;
```

**Tiled, guard on load *and* on store** (`conftest.py:163-200`) — this is the important one, because
a tiled kernel has two distinct out-of-range conditions:

```cpp
const uint TILE = 16;
const uint K = A.get_extent(0);
const uint M = A.get_extent(1);
const uint N = B.get_extent(0);

threadgroup TYPE tileA[TILE][TILE];
threadgroup TYPE tileB[TILE][TILE];

TYPE accum = ZERO;
const uint numTiles = (K + TILE - 1) / TILE;

for (uint t = 0; t < numTiles; ++t) {
    const uint a_k = t * TILE + tid.x;
    const uint a_m = tgid.y * TILE + tid.y;
    tileA[tid.y][tid.x] = (a_k < K && a_m < M) ? A[a_k, a_m] : ZERO;   // guard the LOAD

    const uint b_n = tgid.x * TILE + tid.x;
    const uint b_k = t * TILE + tid.y;
    tileB[tid.y][tid.x] = (b_n < N && b_k < K) ? B[b_n, b_k] : ZERO;

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint kk = 0; kk < TILE; ++kk) {
        accum += tileA[tid.y][kk] * tileB[kk][tid.x];
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);
}

if (gid.x < N && gid.y < M) {      // guard the STORE
    C[gid.x, gid.y] = accum;
}
```

Note the **zero-padding of out-of-range loads** rather than an early `return`: a thread that returns
early never reaches `threadgroup_barrier`, which is undefined behaviour in a threadgroup where other
threads do. Every thread must execute every barrier. This is standard MSL discipline, but it is the
most common way a tiled Core AI kernel goes from "wrong" to "hangs".

The matching Python side (`test_matmul_kernel.py:175-189`) rounds the grid up to whole tiles:

```python
TILE = 16
grid = (((N + TILE - 1) // TILE) * TILE,
        ((M + TILE - 1) // TILE) * TILE,
        1)
threads = (TILE, TILE, 1)
result_shape = [M, N]
```

### 7.4 `threads_per_grid=(1, 1, 1)` is legal and means one thread

Apple has a test for it — *"`threads_per_grid=(1,1,1)` writes exactly one element"* —
and another confirming that **under-dispatch leaves untouched tail elements** rather than erroring:
*"Under-dispatch leaves untouched tail elements; the kernel must not OOB."* ✅ **VERIFIED** —
`tests/dsl/test_thread_config.py:251-256, 299-304`.

Which is another way of saying: **an under-dispatched kernel returns partially-uninitialized memory
and does not fail.** If your grid computation has an off-by-one, the tail of your output tensor is
whatever was in the buffer. Add the numerical test.

### 7.5 A dispatch checklist

- [ ] Grid expressed in **Metal/reversed** axis order (§5.3).
- [ ] Grid derived from `.shape` at the call site, not hardcoded.
- [ ] Threadgroup product ≤ 1024, clamped in Python.
- [ ] Every read and every write bounds-guarded against `get_extent(...)`.
- [ ] If you use `threadgroup_barrier`, no early `return` before it — pad instead.
- [ ] Numerical test at a size that is **not** a multiple of your tile.

---

## 8. Registering, converting, running

### 8.1 Registration order is a hard requirement

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`: *"`TorchMetalKernel` instances must be registered
> with the converter via `register_custom_kernels()` **before** `add_exported_program()`."* Restated
> in `docs/guides/custom-metal-kernels.ipynb` step 4: *"This must be called **before**
> `add_exported_program()`."* Every one of Apple's fourteen `tests/dsl/` files does it in that order.

```python
converter = TorchConverter()
converter.register_custom_kernels([kernel_a, kernel_b])   # FIRST
converter.add_exported_program(ep, input_names=[...], output_names=[...])   # THEN
program = converter.to_coreai()
program.optimize()
```

The reason is mechanical: `add_exported_program` walks the FX graph and resolves each node's target
against the converter's lowering registry. `register_custom_kernels` is what *populates* that
registry for `coreai_metal_kernels::*` targets. If the registry is empty when the walk happens, the
node has no lowering rule.

The signature:

```python
def register_custom_kernels(self, kernels: Sequence[TorchMetalKernel]) -> Self
```

✅ **VERIFIED** — `coreai_torch/converter.py:1036-1039`. It returns `self`, so it chains:
`TorchConverter().register_custom_kernels([k]).add_exported_program(ep)`.

**A related guarantee worth knowing:** `TorchConverter.clear()` drops staged programs but keeps
lowerings. ✅ **VERIFIED** — `docs/api/TorchConverter.md`: *"Custom lowerings registered via
`register_torch_lowering()` are always preserved."* Since `register_custom_kernels` is implemented in
terms of `register_torch_lowering`, your kernels survive a `clear()` — which is what you want when
staging several entrypoints into one asset.

### 8.2 Kernel names are global to a converter

> ✅ **VERIFIED** — `tests/dsl/test_kernel_collisions.py:76-135`. Two `TorchMetalKernel` objects with
> the same `name` cannot both be registered, **even with byte-identical MSL**, and **even across two
> separate `register_custom_kernels` calls**. The error comes from the underlying lowering registry
> (`converter.py:1026-1029`):
>
> ```
> ValueError: 'coreai_metal_kernels::my_name.default' is already registered;
>             set allow_override=True to replace it
> ```
>
> Apple's test docstrings explain the reasoning: *"Even with the same MSL source, the second
> registration fails fast. A coreai-torch `register_custom_kernels` call cannot tell that two
> kernels are equivalent."* and *"Distinct MSL bodies under the same `name` would silently shadow.
> The converter must not allow this."*

The practical consequence for library code: **do not construct `TorchMetalKernel` objects inside a
function that may be called twice.** Build them at module scope, or memoize. A factory like

```python
def make_kernel(nbits: int) -> TorchMetalKernel:
    return TorchMetalKernel(f"gather_qmm_{nbits}", ...)   # name varies with config — good
```

is fine because the name varies; a factory that always returns `TorchMetalKernel("my_kernel", ...)`
will fail the second time it is used in one conversion.

### 8.3 Multiple entrypoints, one asset

Custom kernels compose with the multi-function split that Part 8's guide 05 covers. Register once,
then stage each program:

```python
converter = TorchConverter()
converter.register_custom_kernels([flash_attn_kernel])

converter.add_exported_program(img_ep,  entrypoint_name="image_encode",
                               input_names=["pixel_values"],
                               output_names=["backbone_features"])
converter.add_exported_program(txt_ep,  entrypoint_name="text_encode",
                               input_names=["input_ids"],
                               output_names=["text_features"])
converter.add_exported_program(det_ep,  entrypoint_name="detect",
                               input_names=["backbone_features", "text_features"],
                               output_names=["pred_masks", "pred_boxes",
                                             "pred_logits", "presence_logits"])
program = converter.to_coreai()
program.optimize()
program.save_asset(asset_path)
```

✅ **VERIFIED (the multi-entrypoint pattern)** —
`apple/coreai-models`, `python/src/coreai_models/segmentation/pipeline.py:265-286`, which is the
shipped SAM3 export. `entrypoint_name` must be unique across staged programs
(`docs/api/TorchConverter.md`).

⚠️ Remember §2.4: the function containing the kernel is GPU-resident. In a split like the above you
would put a custom attention kernel in `image_encode` and accept that that function runs on the GPU,
while `detect` remains free to go elsewhere.

### 8.4 Running it: Metal-backed storage is required

This is the runtime requirement people miss.

> ✅ **VERIFIED** — `tests/utils.py:531-533`, Apple's own harness docstring: *"Pass
> `metal_inputs=True` to back all runtime inputs with `StorageKind.METAL` (**required for Metal
> kernels**)."* The implementation (`tests/utils.py:228-231, 485-487`) wraps every input as
> `NDArray(data=…, backing=StorageKind.METAL)`.

```python
from pathlib import Path

import numpy as np
from coreai.runtime import NDArray, StorageKind

asset = coreai_program.save_asset(Path("silu.aimodel"))

async with asset.executable() as ai_model:
    function = ai_model.load_function("main")
    outputs = await function({
        "x": NDArray(data=x.numpy(), backing=StorageKind.METAL),
    })
    y = outputs["y"].numpy()      # materialize INSIDE the block
```

Four runtime facts, all ✅ **VERIFIED** from
`docs/coreai-core/tutorials/run-an-aimodel.ipynb`:

- `.aimodel` is a **directory**, not a file; `save_asset()` returns an `AIModelAsset`.
- `AIModelAsset.load(path)` *"reads the `.aimodel` directory header from disk so you can inspect it;
  **it does not yet compile the program for inference. That work happens lazily inside the
  `executable()` async context manager**."*
- Inference is `async`. `load_function` is synchronous; calling the function is not.
- **Materialize before leaving the block**: *"the model's backing buffers are only guaranteed valid
  until the context exits."* Call `.numpy()` inside the `async with`.

The `StorageKind.METAL` requirement is visible in the IR: every kernel-adjacent tensor carries
`#coreaix.hw_constraints<MTLBuffer, …>` (§1.1). The community note puts the reason plainly:
*"Metal-backed buffers forced on all I/O — the GPU can't read host memory mid-kernel"*
(`notes/repos/john-rocky-models.md`, community-reported).

### 8.5 A footgun on the way out of Python

> **Community-measured, but mechanically obvious once stated** —
> `notes/repos/john-rocky-models.md` §5.4: *"**Keep the `AIModel` reference alive** in a persistent
> multi-call runner — storing only the `load_function` lets the model get GC'd and the function then
> returns **GARBAGE** (no crash, just wrong output → looks like a conversion bug). Hold
> `self.models[name] = m`."*
>
> Attribute as community-measured (single author, M4 Max, beta macOS 27, mid-2026). It is not a
> kernel-specific issue, but it presents *as* one — a kernel you just wrote returning nonsense is the
> first thing you will blame.

---

## 9. Scalar inputs: literals in disguise

### 9.1 The three allowed scalar types

A `torch_defn` parameter annotated `int`, `float` or `bool` becomes a scalar kernel input.

> ✅ **VERIFIED** — `_torch_metal_kernel.py:22-29`:
> ```python
> _ALLOWED_SCALARS = {int, float, bool}
> _SCALAR_METAL_DTYPE = {bool: "bool", int: "int", float: "float"}
> ```

In the generated signature they appear as `constant T&` parameters rather than tensors:

> ✅ **VERIFIED** — `tests/dsl/test_scalar_inputs.py:117-127`, which asserts
> `f"constant {metal_dtype}& c "` is present in the emitted `kernel_source` for each of
> `(float, 2.5, "float")`, `(int, 7, "int")`, `(bool, True, "bool")`. The module docstring
> (`:8-11`) states the binding: *"A scalar passed to a `TorchMetalKernel` (`int`, `float`, `bool`) is
> captured by `get_operand` as a `coreai.constant` rank-0 tensor and bound to the kernel as a
> `constant T& name [[buffer(N)]]` parameter — a different runtime path from the regular tensor
> (`MTLTensor`) bindings."*

Apple's own softmax kernel uses one — the reduction axis is an `int` scalar:

```python
def torch_softmax(x: torch.Tensor, dim: int) -> torch.Tensor:
    return x.softmax(dim=dim)

custom_softmax = TorchMetalKernel(
    "custom_softmax",
    input_names=["input", "axis"],
    result_names=["output"],
    src=softmax_src,
    torch_defn=torch_softmax,
    metal_params=[MetalParameter("gid", "uint", "thread_position_in_grid")],
    template_dtypes={"input": "TYPE"},
)
```

✅ **VERIFIED** — `tests/dsl/test_softmax.py:40-66`. And the body uses `axis` as an ordinary
value: `uint normalized_axis = axis >= 0 ? uint(axis) : uint(input.get_rank() + axis);`
(`tests/dsl/conftest.py:37`).

### 9.2 Scalars are **baked as literals**, and that has consequences

This is the surprising part. The declared `constant T&` parameter is real, but the value your body
reads is a *shadowing local* holding a literal, injected in front of your source.

> ✅ **VERIFIED** — `_torch_metal_kernel.py:332-407`, with Apple's own explanation of why
> (`:337-345`):
>
> > *"The runtime binds rank-0 inputs as `MTLTensor` resource handles, so a `constant T&` parameter
> > declared in the kernel source can't be dereferenced as a value — it would read from the handle,
> > not the scalar's storage. Workaround: keep the parameter declaration intact (the IR contract
> > still surfaces `constant T& <name>`) but **shadow it inside the body with a local variable
> > initialized to the literal**, so the user-written body still resolves the name to the right
> > value."*
>
> The transform (`:372-407`) wraps your body in a nested block so the locals can legally shadow the
> parameters:
>
> ```python
> return "{\n" + "\n".join(decls) + "\n" + src + "\n}"    # e.g. decls = ["float c = 2.5f;"]
> ```

Three things follow, and each will bite somebody:

1. **The scalar's value is fixed at trace time.** A "runtime scalar" is not a thing here — the value
   in your `forward()` at export time is the value compiled into the kernel. If it varies, it must be
   a rank-≥1 tensor input, or a separate kernel variant.
2. **Different scalar values produce different kernels.** Apple maintains a per-value sub-cache so
   that call sites with different scalar values do not collide, while identical ones still share a
   pipeline state object (`_scalar_kernel_caches`, `:63-69` and `:363-365`). Sweeping a scalar over
   many values therefore multiplies your compiled kernel count.
3. **Your body's variable names must not collide** with the injected declarations in a way you did
   not intend — the shadowing is by design, but a local of the same name inside your own nested scope
   will shadow the shadow.

### 9.3 Range and finiteness are enforced

```
ValueError: int scalar 'n'=5000000000 is outside the 32-bit int range that MSL `int` supports
ValueError: float scalar 'eps'=inf is not finite; NaN/Inf scalars are not supported
```

✅ **VERIFIED** — `_torch_metal_kernel.py:386-400`. Both raise at **conversion** time (when the
lowering runs), not at construction, because the value is only known once the FX node is visited.

`bool` widens to `ui8` at the IR level and is patched back to `bool` in the MSL signature:

> ✅ **VERIFIED** — `_torch_metal_kernel.py:25-29` and `_utils.py:1070-1082`: *"Bool widens to ui8
> because `i1` is rejected by the `metal4_kernel` verifier; the MSL signature still emits
> `constant bool&`."*
>
> Also note `scalar_constant` (`_utils.py:1070-1086`) deliberately bypasses the converter's fp16
> promotion: *"Bypasses the fp16 promotion `get_operand` applies to Python floats so the MSL
> parameter ends up as `constant float&` even when the surrounding tensors are fp16."* If you were
> wondering why your scalar is `float` and not `half` in an fp16 model — that is why, and it is
> intentional.

### 9.4 Scalars share the parameter budget

29 scalars + 1 result = 30 buffers lowers cleanly; 25 tensors + 6 scalars + 1 result = 32 does not.

✅ **VERIFIED** — `tests/dsl/test_scalar_inputs.py:129-215`, both cases, with the second asserting
the limit error. §12.2.

---

## 10. Dtype templating, the kernel cache, and multiple outputs

### 10.1 `template_dtypes`

One kernel object, many element types. You put a placeholder token in `src` and name the input whose
dtype decides the substitution.

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md` and `docs/guides/custom-metal-kernels.ipynb`
> cell 10, reproduced verbatim:

```python
custom_matmul = TorchMetalKernel(
    "matmul",
    input_names=["A", "B"],
    result_names=["C"],
    src="""
        const uint K = A.get_extent(0);
        const uint M = A.get_extent(1);
        const uint N = B.get_extent(0);
        if (gid.x >= N || gid.y >= M) return;
        TYPE sum = 0.0f;
        for (uint k = 0; k < K; ++k) {
            sum += A[k, gid.y] * B[gid.x, k];
        }
        C[gid.x, gid.y] = sum;
    """,
    torch_defn=torch_matmul,
    metal_params=[MetalParameter("gid", "uint2", "thread_position_in_grid")],
    # "A" is the input whose dtype determines the substitution;
    # every occurrence of "TYPE" in src is replaced with the
    # corresponding Metal type (e.g. "half", "float", "bfloat").
    template_dtypes={"A": "TYPE"},
)
```

Validation, both at construction:

```
ValueError: Inputs {'z'} not specified              # template key is not an input name
ValueError: Provided duplicated template strings ['TYPE']   # two inputs, same placeholder
```

✅ **VERIFIED** — `tests/dsl/test_custom_kernels.py:345-380`.

⚠️ **The substitution is textual.** "Every occurrence of `"TYPE"` in `src` is replaced" means
*every* occurrence — including inside a comment, a string, or a longer identifier such as `MY_TYPE`.
Choose a placeholder that cannot appear by accident; Apple uses the all-caps `TYPE` and nothing else
in their bodies contains those four characters.

⚠️ **Templating does not solve literals.** Apple's own test fixtures template the *type* but then
have to specialize the *zero literal* separately, per dtype, in Python:

```python
generic_naive_matmul.replace("ZERO", "0")            # int
generic_naive_matmul.replace("ZERO", "0.0f")         # float / half
generic_naive_matmul.replace("ZERO", "bfloat(0.0)")  # bfloat16
```

✅ **VERIFIED** — `tests/dsl/conftest.py:144-159`. `TYPE sum = 0.0f;` in the docs example works
for half and float but not for the integer instantiations, which is exactly why the test suite has
three fixtures where the docs have one. If you template across integer and float dtypes, template
your literals too.

### 10.2 The kernel cache, and what "one kernel" means

> ✅ **VERIFIED** — `tests/dsl/test_kernel_collisions.py:137-227` and
> `test_dtype_specialization.py:6-24`. The cache is keyed on **`(rank, dtype)`** (plus scalar values,
> §9.2):
>
> - Same kernel, same `(rank, dtype)`, two call sites → **one** emitted source and one randomized
>   name, reused. Apple's robustness test asserts *"Two `metal4_kernel` ops emitted, but kernel cache
>   means a single randomized name (the same suffix appears twice)"*
>   (`test_metal_kernel_robustness.py:233-261`).
> - Same kernel, **different** `(rank, dtype)` → two distinct sources, two randomized names, two
>   pipeline states. `test_dtype_specialization.py:242-254` asserts exactly two sources, that they
>   differ, and that one contains `"device half"` while the other contains `"device float"`.
>
> The docstring's framing: *"This produces a per-shape kernel **variant** — the same Python kernel
> emitted twice with different dtypes generates two distinct PSOs because the templated MSL source
> differs."*

Practical reading: **kernel objects are cheap to reuse and expensive to duplicate.** One module-level
object called from twenty places costs one compiled kernel per distinct `(rank, dtype, scalars)`
combination, which is what you want.

### 10.3 Multiple outputs

> ✅ **VERIFIED** — `docs/guides/custom-metal-kernels.ipynb` cell 11, reproduced verbatim:

```python
def torch_sincos(x: torch.Tensor) -> list[torch.Tensor]:
    return [torch.sin(x), torch.cos(x)]


sincos_kernel = TorchMetalKernel(
    "sincos",
    input_names=["x"],
    result_names=["out_sin", "out_cos"],
    src="out_sin[id] = sin(x[id]); out_cos[id] = cos(x[id]);",
    torch_defn=torch_sincos,
    metal_params=[MetalParameter("id", "uint", "thread_position_in_grid")],
)


class SinCosModel(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        results = sincos_kernel(
            x,
            threads_per_grid=(x.shape[0], 1, 1),
            threads_per_thread_group=(1, 1, 1),
            result_shapes=[list(x.shape), list(x.shape)],
        )
        return results[0] + results[1]  # sin(x) + cos(x)
```

`list[torch.Tensor]` is variable-length, so arity is checked at call time (via `result_shapes`), not
at construction. `tuple[torch.Tensor, torch.Tensor]` is checked at construction. Prefer the tuple
form when the count is fixed — you get the error earlier and with a better message.

---

## 11. `helper_src` and reaching TensorOps

### 11.1 The handoff

Everything so far has been about the *seam*. The kernels have been deliberately naive: an
element-wise add, a triple-loop matmul. Real performance work means TensorOps —
`mpp::tensor_ops::matmul2d`, cooperative tensors, `reduce_rows`, the M5 neural accelerator — and
that is a different discipline with its own guide.

The two WWDC sessions are explicitly wired together in both directions:

> ✅ **VERIFIED** — session 325:205: *"For more details on how you can write efficient Metal kernels
> for Core AI, and to see an optimized kernel live in action with the SAM3 model please see the
> 'Optimize custom machine learning operations with Metal tensors' talk."*
>
> ✅ **VERIFIED** — session 330:121: *"Check out the 'Deep Dive into Core AI Model authoring and
> Optimization' session for the details of how to integrate a Metal kernel into a Core AI model."*

**→ For how to write the kernel: [Part 11 — Metal and TensorOps](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md).**
That guide covers `matmul2d_descriptor`'s seven positional arguments and its `mode::multiply`
default, execution scopes, cooperative-tensor construction and the `get_*_input` /
`get_destination` template-argument asymmetry, `reduce_rows`, `map_iterator`, and the alignment
rules for sub-byte tensors.

**→ This section covers only what changes when that kernel lives inside a `TorchMetalKernel`.**

### 11.2 Where the TensorOps code goes

`helper_src` is pasted *before* the kernel definition, so it is where includes, `using namespace`
lines and type aliases belong:

```python
TENSOR_OPS_PREAMBLE = """
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>

using namespace metal;
using namespace mpp::tensor_ops;

// type aliases, helper functions, structs — anything the body needs
"""

flash_attn = TorchMetalKernel(
    "flash_attention",
    input_names=["q", "k", "v"],
    result_names=["o"],
    src=FLASH_ATTENTION_BODY,
    helper_src=TENSOR_OPS_PREAMBLE,
    torch_defn=torch_sdpa_reference,
    metal_params=[
        MetalParameter("tgid", "uint2", "threadgroup_position_in_grid"),
        MetalParameter("tid",  "uint2", "thread_position_in_threadgroup"),
    ],
)
```

✅ **VERIFIED** — that `helper_src` is *"additional Metal source pasted before the kernel
definition (helper functions, type aliases, etc.)"* (`docs/api/TorchMetalKernel.md`), and that the
MPP include line is `#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>` with
namespace `mpp::tensor_ops` (Xcode SDK headers, as used by MLX). 🟡 The specific combination above
— an MPP include inside `helper_src` — is the obvious composition of two verified facts and is what
the community `_tensorops_proto` scripts do, but no Apple example in this corpus shows it.

### 11.3 The SAM3 FlashAttention integration, as narrated

Session 330 closes by putting a hand-written FlashAttention kernel into SAM3 through exactly this
API. The presenter describes a three-step recipe:

> ✅ **VERIFIED** — session 330:122–126, verbatim:
> *"I've followed the steps outlined in that session to integrate our custom FlashAttention kernel
> into a **Sam3 image segmentation model**. **We define the body of our custom attention kernel as a
> string in Python and register the `TorchMetalKernel` object**, shown here."*
> *"Then, **we replace the default huggingface attention implementation with one that calls our
> kernel**, shown here."*
> *"Finally, **we load the model from huggingface and export it from PyTorch as an optimized Core AI
> asset**."*
>
> And the result, 330:131–132: *"Looking at the final result, we can see the model correctly
> segmented the image. **The car is highlighted in blue, so our attention kernel is fully integrated
> into the model as expected.**"*

So the pattern is: **kernel body as a Python string → `TorchMetalKernel` → monkey-patch the
upstream module's attention implementation to call it → export as usual.** That is a genuinely
useful technique, because it lets you keep using an unmodified Hugging Face checkpoint and model
class while swapping one operation.

```python
# Step 2, in shape. The kernel is a plain Python callable, so the patched
# forward is an ordinary function.
def custom_attention_forward(self, q, k, v, **kwargs):
    return flash_attn(
        q, k, v,
        threads_per_grid=(...),
        threads_per_thread_group=(...),
        result_shapes=[list(q.shape)],
    )

SomeAttentionClass.forward = custom_attention_forward
```

> 🟡 **RECONSTRUCTED — the monkey-patch target.** The presenter says *"shown here"* and the code
> appears on screen without being read aloud. The *technique* is verified from the narration; the
> class you patch, the exact `forward` signature you must match, and the dispatch tuple used are all
> unknown. The Hugging Face attention-forward signature has also changed shape across `transformers`
> versions. **Safe default meanwhile:** patch the narrowest thing that works — in modern
> `transformers`, register a named attention implementation and select it via the model config
> rather than assigning to a class attribute, so a version bump produces an error instead of a
> silently-unpatched model. And assert the patch took effect (`assert cls.forward is
> custom_attention_forward`) before exporting; an unpatched export converts perfectly and is simply
> the original model.

⚠️ The SAM3 export in `apple/coreai-models` does **not** contain this kernel. The shipped recipe
(`models/sam3/README.md`, `segmentation/pipeline.py`) uses composite-op SDPA and palettization; the
FlashAttention integration exists only in session 330's demo. There is no code to copy.

### 11.4 ⚠️ Version reality for quantized kernels

If your kernel body dequantizes weights — which is the main reason to write one — the API you can
target is narrower than session 330's narration suggests. Three things must be said plainly.

**(a) The feature ladder is per-point-release, and 26.2 is not in it.**

> ✅ **VERIFIED** — Apple Tech Talk 111432, *"Accelerate your machine learning workloads with the M5
> and A19 GPUs"*, verbatim:
> *"Since we introduced TensorOps, we've continued expanding the API in iOS and Mac OS 26. In
> **26.1**, we added **bfloat tensor support**… In **26.3**, we added support for **cooperative
> tensors as inputs to matmul**. This lets you **build custom dequantization routines inside your
> kernel**, essential for running quantized models efficiently. And in **26.4**, we added **four bit
> and eight bit integer tensors**, so quantized models can fully leverage neural accelerators."*

| OS version | TensorOps capability |
|---|---|
| **26.0** | TensorOps introduced (WWDC25 session 262) |
| **26.1** | `bfloat` tensor element type |
| **26.2** | *(nothing in Apple's ladder)* |
| **26.3** | **cooperative tensors as matmul inputs** → in-kernel custom dequantization |
| **26.4** | **int4 / int8 tensor element types** |

The apparent conflict with the shipped SDK is not a conflict. The Xcode 26.6 headers define
`__TENSOR_OPS_SUPPORT_DEPLOYMENT_TARGET_26_2` — a deployment-target macro on *specific symbols* —
while the ladder above describes *features*. ✅ Both are verified; they are different views. **Do
not print a single blanket "TensorOps requires 26.x".** Print the ladder, and gate on the specific
capability you use.

Independent corroboration of the same floor from a shipping build system: MLX compiles its TensorOps
kernels only when `MLX_METAL_VERSION >= 400` **and** SDK ≥ 26.2 **and** deployment target ≥ 26.2
(`mlx/backend/metal/kernels/CMakeLists.txt:158-182`, ✅ verified in
`notes/repos/mlx-tensorops-kernels.md` §11.2).

**(b) Xcode 26.6 lacks fp4, fp8 and int2; Xcode 27 adds them.**

> ✅ **VERIFIED 26.x baseline.**
> 1. The `MetalPerformancePrimitives` headers shipped in the Xcode 26.6 SDK: `__tensor_ops_datatype`
>    enumerates float32/float16/bfloat16, int4/int8/int16/int32 and the unsigned counterparts.
>    **int2, fp4, fp8 and E8M0 are absent from that 26.6 SDK.**
> 2. `MTLTensorDataType` in `MTLTensor.h` stops at
>    `MTLTensorDataTypeInt4 / UInt4 API_AVAILABLE(macos(26.4), ios(26.4))`.
> 3. Tech Talk 111432 announces *"four bit and eight bit integer tensors"* — four and eight only.
>
> One more useful constraint from the header's own supported-combination table
> (`MPPTensorOpsMatMul2d.h:13-61`): **4-bit only ever appears as the *right* (weight) operand.**
> There is no `int4 × int4` combination.

For OS 27, `MTLTensorDataType` adds int2/uint2, FP4 E2M1, FP8 E4M3/E5M2 and unsigned E8M0, and the
MPP type map adds the corresponding `metal::*_format` shader operand types. Do not carry the 26.6
negative result forward to an Xcode 27 target.[^xcode27-scale-planes]

**(c) OS 27 has an E8M0 auxiliary scale-plane mechanism.**

> ✅ **VERIFIED (Xcode 27 correction).** Session 330’s `dataType`, `blockFactors` and auxiliary-plane
> map are present in `MTLTensorAuxiliaryPlaneDescriptor`, `MTLTensorAuxiliaryPlaneDescriptorMap`, and
> `MTLTensorDescriptor.auxiliaryPlanes` — declared in the macOS 27.0 beta SDK's
> `Metal.framework/Headers/MTLTensor.h` (`:164`, `:191`, `:288`, the last gated
> `API_AVAILABLE(macos(27.0), ios(27.0))`). The supported scale plane uses unsigned E8M0 and defaults
> to block width 32. TensorOps consumes supported data and scale planes together and handles their
> dequantization.[^xcode27-scale-planes]
>
> **Fallback.** On 26.x, or for a custom format whose scale dtype/block geometry the OS 27
> descriptor cannot express, **dequantize in-kernel into a cooperative tensor** and feed that to
> `matmul2d`. Session 330 explicitly distinguishes this custom-format path from OS 27 automatic
> dequantization. Cooperative-tensor inputs require **26.3**.[^xcode27-scale-planes]

A community de-risk script demonstrates the concrete fallback when you cannot even use cooperative
tensors as inputs — staging the dequant through threadgroup memory:

> **Community-measured / community-authored** — `notes/repos/john-rocky-models.md` §10.1, describing
> `_tensorops_proto/m2_int4_block32_scaled.py` (120 lines, M4 Max, beta macOS 27, 2026-07):
> block-32 fp16-scaled int4 matmul, which *"manually dequants each `[k=32, n=32]` weight block into
> `threadgroup half wsh[BLK*TILE_N]`, applying the per-block fp16 scale, then runs `matmul2d`
> half×half with `mode::multiply` on the first block and `mode::multiply_accumulate` thereafter —
> accumulating into a float `C` across `K/32` blocks, with `threadgroup_barrier` on both sides."*
> Signed int4 is decoded explicitly (`if (code > 7) code -= 16;`) with the comment *"decode signed
> int4 manually (unambiguous)"*. The author's conclusion: **you can get block-32 scaling at Metal 4.0
> by staging the dequant in threadgroup memory.**
>
> Note the mode detail — `matmul2d_descriptor`'s default is `mode::multiply`, so the first block
> initializes and subsequent blocks must explicitly request `multiply_accumulate`. Part 11 covers
> this; it is a documented default that reads backwards.

### 11.5 Two open questions at this boundary

> 🔴 **GAP — the MSL language version `coreai-torch` compiles embedded kernel source at is
> unpublished.** This matters because TensorOps features are gated on it: `matmul2d` with uniform
> int4 is reported to need Metal 4.0, while the multi-plane machinery (`metal::tensor_blockwise`,
> `__HAVE_TENSOR_MULTIPLANE__`) is reported to need 4.1. The question — *"can `coreai-torch` compile
> the embedded MSL at `-std=metal4.1`?"* — is raised verbatim as an open item in community notes
> (`notes/repos/john-rocky-models.md` §5.7) and is not answered anywhere in this corpus. There is no
> `msl_version` or `std` parameter on `TorchMetalKernel`; the compile happens inside `coreai-core`.
> Resolving it needs either the `coreai.authoring` source or an empirical probe — compile a body
> using a known-4.1-only construct and see whether `load_function` succeeds.
>
> **Safe default meanwhile:** target Metal 4.0 constructs. `matmul2d`, cooperative tensors,
> `reduce_rows` and `slice`/`static_slice` are all reachable there, and the threadgroup-staging
> dequant above removes the only compelling reason to need 4.1.

> ⚠️ **SILENT FAILURE — a missing feature macro makes the whole MPP header expand to nothing.**
> ✅ **VERIFIED** — `MPPTensorOpsMatMul2d.h:328` is guarded by
> `#if defined(__METAL_VERSION__) && defined(__HAVE_TENSOR__)`. As the header analysis in
> `notes/repos/mlx-tensorops-kernels.md` §11.1 puts it: *"If `__HAVE_TENSOR__` is undefined the
> entire header expands to nothing — no error, just an empty namespace and a confusing 'no member
> named matmul2d' later."* Related macros: `__HAVE_BFLOAT__`, `__HAVE_INT4B_FORMAT_TYPE__`,
> `__HAVE_EXECUTION_UNIT__`.
>
> Inside a `TorchMetalKernel` you do not control the compiler invocation, so if `matmul2d` "does not
> exist", the cause is a feature macro, not a typo. Add
> `#if !defined(__HAVE_TENSOR__) \n #error "no tensor support" \n #endif` to `helper_src` while
> debugging, so the failure names itself.

---

## 12. The failure taxonomy

Failures land in four buckets, and the further right you go the worse the diagnostics get.

```
construction   →   call site   →   conversion   →   load / run
(TorchMetalKernel(...))  (kernel(...))  (add_exported_program / to_coreai)  (load_function)
   rich errors        rich errors        decent errors        one generic message
```

### 12.1 Construction-time errors (rich, cheap, all pinned by tests)

✅ **VERIFIED** — every row from `coreai_torch/_torch_metal_kernel.py` with a matching test in
`tests/dsl/`.

| Trigger | Exception and message |
|---|---|
| empty / whitespace `name` | `ValueError("Kernel name must be a non-empty string, got …")` |
| empty `result_names` | `ValueError("result_names must contain at least one entry")` |
| duplicate name in a list | `ValueError("Duplicate input names: ['x']")` / `"Duplicate result names: ['out']"` |
| name in both lists | `ValueError("Names appear in both input_names and result_names: […]")` |
| `*args` / `**kwargs` in `torch_defn` | `TypeError("custom kernels do not support variadic parameters (*args / **kwargs); got parameter '…' with kind …")` |
| unsupported parameter annotation | `TypeError("custom kernels only support \`torch.Tensor\`, \`float\`, \`bool\` and \`int\` inputs, got <class 'str'>")` |
| parameter count ≠ `len(input_names)` | `ValueError("torch function should have same number of parameters as specified by input names, expected 2, got 1")` |
| bad return annotation | `TypeError("Metal kernels only support return types of \`torch.Tensor\`, \`list[torch.Tensor]\`, or \`tuple[torch.Tensor]\` (with a concrete number of tuple members). …")` |
| single-Tensor return, >1 result name | `ValueError("torch_defn returns a single torch.Tensor, but result_names has 2 entries: …")` |
| tuple arity mismatch | `ValueError("torch_defn returns tuple of 2 tensors, but result_names has 3 entries: …")` |
| `template_dtypes` key not an input | `ValueError("Inputs {'z'} not specified")` |
| duplicate template placeholder | `ValueError("Provided duplicated template strings ['TYPE']")` |

### 12.2 Call-site and conversion-time errors

| Trigger | Exception | When |
|---|---|---|
| grid tuple not length 3 | `ValueError("threads_per_grid must be a 3-tuple, got 2 elements: …")` | call |
| threadgroup tuple not length 3 | `ValueError("threads_per_thread_group must be a 3-tuple, got …")` | call |
| wrong number of `result_shapes` | `ValueError("result_shapes must contain one shape per result name; expected 2 (for [...]), got 1")` | call |
| **parameter budget exceeded** | `ValueError("metal kernels support 31 inputs, got 32")` | conversion |
| duplicate kernel name | `ValueError("'coreai_metal_kernels::N.default' is already registered; set allow_override=True to replace it")` | `register_custom_kernels` |
| unsupported input dtype | `TypeError("kernel input at index 0 has unsupported dtype: f8E5M2")` | conversion |
| unsupported result dtype | `TypeError("Result type at index 0 has unsupported dtype: f8E5M2")` | conversion |
| int scalar out of int32 range | `ValueError("int scalar 'n'=… is outside the 32-bit int range that MSL \`int\` supports")` | conversion |
| non-finite float scalar | `ValueError("float scalar 'eps'=inf is not finite; NaN/Inf scalars are not supported")` | conversion |

✅ **VERIFIED** — all rows from `tests/dsl/`; the parameter-budget row from
`tests/dsl/test_custom_kernels.py:184-252` with Apple's own arithmetic in the comment:

> *"Metal 4: params = inputs + results + metal_params. Use 21 metal params so 10 inputs + 1 result +
> 21 metal_params = 32 > PARAMETER_LIMIT (31)."*

**The budget is `len(input_names) + len(result_names) + len(metal_params) ≤ 31`,** and scalar inputs
count as inputs (`tests/dsl/test_scalar_inputs.py:8-17, 176-215`). If you are fusing a whole
transformer layer, this is a real ceiling — plan to pack related tensors rather than passing twenty
separate weight buffers.

### 12.3 The known converter bug: custom kernels inside `torch.cond`

> ⚠️ **VERIFIED BUG, pinned as a strict `xfail` in Apple's own suite.**
> `tests/dsl/test_metal_kernel_robustness.py:264-290`, docstring verbatim:
>
> > *"The converter currently routes branch bodies through
> > `coreai_torch._utils.convert_branch_subgraph`, which is wired with `_aten_to_core_resolver` only
> > and does **not** receive the user-defined torch lowerings registered by
> > `TorchConverter.register_custom_kernels`. Calling a custom kernel inside a `cond` branch
> > therefore raises **`unsupported op in branch`**. **This is a real bug** — fixing it requires
> > threading user lowerings through `replace_cond` / `replace_while_loop`. The test below pins the
> > current behavior so the regression is visible and is upgraded to a passing assertion once the
> > converter is fixed."*
>
> Marked `@pytest.mark.xfail(..., strict=True)`, so the day Apple fixes it their CI turns red and the
> test is promoted.
>
> **Workaround:** hoist the kernel call out of the branch. Compute it unconditionally and select
> afterwards, or restructure so the conditional selects *inputs* rather than *operations*.
> Independently, higher-order ops (`cond`, `while_loop`) are noted as *"not yet supported by the
> cpu/gpu/neural_engine compute unit runtimes"* — they run only on the interpreter compute unit in
> Apple's tests — so a `cond`-bearing graph has a second problem regardless of kernels.

### 12.4 ⚠️ The one that gets everybody: a bad kernel body is not a conversion error

> ⚠️ **SILENT FAILURE — malformed Metal Shading Language converts cleanly, optimizes cleanly, saves
> cleanly, loads cleanly, and fails only when you bind a function — with a message that contains no
> compiler diagnostic.**
>
> ✅ **VERIFIED** — `tests/dsl/test_failures.py:22-70`, in full. Apple's own test constructs a kernel
> whose entire body is
>
> ```python
> src="A[s] = sdfs"
> ```
>
> — an undeclared array, an undeclared index, an undefined identifier, and no semicolon — then:
>
> ```python
> converter.register_custom_kernels([custom_kernel])   # OK
> converter.add_exported_program(ep, ...)              # OK
> coreai_program = converter.to_coreai()               # OK
> coreai_program.save_asset(Path(tmp))                 # OK
> model = await AIModel.load(Path(tmp))                # OK
> with pytest.raises(RuntimeError, match=re.escape(
>         "Kernel coreai.metal4_kernel invoked with invalid parameters")):
>     model.load_function("main")                      # ← finally fails, here
> ```
>
> The test is named `test_raise_comprehensible_compilation_failure`, and the "comprehensible" message
> is **`RuntimeError: Kernel coreai.metal4_kernel invoked with invalid parameters`**. No line number.
> No column. No Metal compiler output. No mention of `A`, `s` or `sdfs`.
>
> **Every category of MSL mistake lands here**: syntax errors, undeclared identifiers, a variable
> name that does not match `input_names`, a `#include` that is not available, a construct your MSL
> version does not support, a threadgroup array that exceeds the limit. They all present as the same
> sentence, at `load_function`, after conversion has told you everything is fine.
>
> **Mitigations, in order of value:**
> 1. **Compile the MSL yourself first.** Paste the body into a standalone `.metal` file with a
>    hand-written signature and run `xcrun metal -c`. You get real diagnostics. Do this every time
>    you change the body; it costs seconds.
> 2. **Never write more than a few lines between `load_function` calls.** Bisecting a 200-line kernel
>    against a message with no line number is miserable.
> 3. **Keep a minimal always-works kernel** in the same file (the identity kernel from §7.3) so that
>    when everything breaks you can prove the *pipeline* still works and isolate the change to the
>    body.
> 4. **Watch for name drift.** `input_names=["x"]` with a body that says `input` is not a compile
>    error you will recognize from that message. §3.2's table exists for this.

### 12.5 ⚠️ Apple's own end-to-end kernel tests are currently disabled

This is a fact about the state of the API that you should factor into your risk assessment.

> ✅ **VERIFIED** — three files in `tests/dsl/` carry a module-level skip:
>
> ```python
> pytestmark = pytest.mark.skip(
>     reason="ExecutableOptions(enable_encoding_functions=...) was removed in the "
>     "AIProgram API; no replacement found in coreai.authoring/runtime/compiler. "
>     "DSL kernel tests need a follow-up once a replacement surfaces."
> )
> ```
>
> and, on the individual tests inside them, a second skip:
>
> ```python
> @pytest.mark.skip("reenable once runtime kernel moved to support Metal 4")
> ```
>
> The three are `test_softmax.py`, `test_self_attention.py` and `test_multiple_kernels.py` — i.e.
> the *numerical, end-to-end, actually-runs-on-the-GPU* tests. Additionally, CI deselects the whole
> marker: `.github/workflows/ci.yml:37` runs
> `pytest tests/ -n auto -m "not slow and not dsl"`, and `tests/dsl/conftest.py:16-23` adds the `dsl`
> marker to every test in the directory.

What still runs (on a developer's Mac, not in CI): the IR-level tests, the validation tests, the
matmul tests via `validate_numerical_output`, dtype specialization, thread configuration, scalar
inputs and the collision tests. What does not: Apple's own softmax and self-attention kernels,
end to end, on a device.

**Read this as calibration, not alarm.** The API is real, it is documented, it lowers correctly, and
community work has shipped models built on it. But the "reenable once runtime kernel moved to support
Metal 4" note tells you the runtime side is in motion, and §12.4 tells you the diagnostics are thin.
Budget for your own numerical harness (§14) rather than assuming the platform will catch you.

---

## 13. Does it pay? Community measurements

Everything in this section is **community-measured**: a single author, self-declared uncontrolled
benchmarks, beta operating systems, mid-2026. It is not Apple-published and must not be presented as
such. It is included because it is the only end-to-end evidence in existence for this API, the
numbers are unusually well-documented, and the *shape* of the result — one large win, several
regressions — is more instructive than any single figure. Source throughout:
`notes/repos/john-rocky-models.md`, which summarizes the `john-rocky/coreai-model-zoo` knowledge
files.

### 13.1 The win: a `gather_qmm` kernel for mixture-of-experts decode

**The problem.** Core AI's built-in `GatherMM` composite op gathers expert weights and then runs a
**dense** matmul — it does not read only the routed experts. So MoE decode is bound by over-reading
weights, not by active parameters.

> **Community-measured** — *"`GatherMM` gathers then runs a DENSE matmul — it does **NOT** read only
> the routed experts, so MoE decode is over-read-bound, not active-param-bound (Qwen3.6-35B-A3B int8
> sits at ~25 % of bandwidth)."*

**The fix.** A `TorchMetalKernel` matvec that takes the routed expert indices as a kernel **input**
and reads only the top-k experts' weight slabs — *"`QP[w,n,e]`, `e = IDX[slot]` — indexed global
load; the other E−k experts are never fetched."* Packaged as a drop-in `MetalSwitchGLU` replacing
`SwitchGLU`, applied model-wide by a `metalize_moe(model, nbits)` helper.

**The results.** All **community-measured on an M4 Max, beta macOS 27, dated 2026-06-13**:

| Model | Configuration | Decode | Change |
|---|---|---|---|
| LFM2.5-8B-A1B | int8 MoE, stock `GatherMM` | 39 tok/s | baseline (8.8 GB, ~345 GB/s effective) |
| LFM2.5-8B-A1B | int8 MoE, custom `gather_qmm` | **141 tok/s** | **3.6×** — reads 4 of 32 experts |
| LFM2.5-8B-A1B | int4km, `gather_qmm` | 162.7 tok/s | 4.7 GB, iPhone-jetsam-safe |
| Qwen3.6-35B-A3B | stock → `gather_qmm` | **30.9 → 64.9 tok/s** | **2.1×** — top-8 of 256 experts |
| GLM-4.7-Flash | stock → `gather_qmm` | 20.3 → 52.4 tok/s | 2.6×; MLA on all 47 layers caps it |
| LFM2.5-8B-A1B int4km | on **iPhone 17 Pro (A19 Pro) GPU** | ~32 tok/s | *"the zoo's first iPhone MoE on hardware"* |

Numerics: *"kernel == 'select-from-all' bit-for-bit."* The kernel changes *what is read*, not *what
is computed*.

**Why it worked when kernelizing attention did not.** The kernel changed the memory-traffic
asymptotics: `O(E)` weight reads became `O(k)`. That is a structural win no amount of fusing or
tuning of the dense path can recover. Compare §2.5's failures, which all re-implemented work that was
already efficient.

**The enabler, and its constraint.**

> **Community-measured probe result:** *"**Rank-3 buffer indexing + a DATA-DEPENDENT gather both
> lower + run on the GPU.** So a kernel can take an index tensor as an INPUT and read only the rows
> it points at — `W[m, n, e]` with `e = uint(IDX[slot])` reads only expert-slab `e` out of a
> `[E, N, M]` tensor."*
>
> ⚠️ **The critical caveat, and it is a `torch_defn` constraint:** *"The `torch_defn` must stay
> fake-traceable: express the gather as `torch.index_select(W, 0, idx)` (shape-static), **NEVER
> `int(idx[i])`** (FakeTensor has no concrete value)."*
>
> This generalizes. Your reference implementation is traced with `FakeTensor`s, so **any Python-level
> read of a tensor's *value*** — `int(t[0])`, `t.item()`, `if t > 0`, `range(t)` — fails at export.
> The reference may only do shape arithmetic. That constraint applies to every `torch_defn`, not just
> gathers.

And one more correctness trap from the same work, which is a good example of what "the reference
cannot catch it" looks like in a real kernel:

> **Community-measured** — *"gate/up share the token `x` across routed experts, but the **down**
> projection feeds each expert its OWN gated activation — so the kernel's `A` must be `[k, K]` (one
> row per slot, `A[c, slot]`), with `x` replicated k-wide for gate/up. **Treating `A` as a single
> shared `[1, K]` row silently corrupts down (relative error ~1.3 = garbage).**"*

### 13.2 The losses, restated

From §2.5, and worth repeating next to the win so the comparison is unavoidable
(community-measured, same hardware and period):

- **Kernelizing attention q/k/v/o was *slower*.** Any single op-class was ≤ 1.3 ms; there was nothing
  to win.
- **Native SDPA on GPU should not be hand-rolled** — *"already fused; don't hand-roll it."*
- **A decode-step SSM scan kernel gained 3–8 %**, judged *"not worth the barrier + shape
  constraints."* The same technique on **prefill** (chunked scan) was 13.7× on Mac. Same kernel
  class, opposite verdict, decided entirely by which phase it ran in.
- **An absorbed-MLA staging kernel currently measures 0.78×** — i.e. a regression the author records
  and does not ship, with an explicit stop rule: *"If it can't beat naive even @8K → record and stop
  (don't ship a non-win)."*

### 13.3 ⚠️ The hidden cost: a kernel is a fusion barrier

> ⚠️ **SILENT FAILURE — inserting a kernel can make the surrounding graph slower in a way that does
> not appear in your kernel's own timing.**
>
> **Community-measured** — *"A `metal4_kernel` op is a **FUSION BARRIER**, and its edges are
> materialized in the dtype/layout the kernel asks for. A dtype cast on the boundary (e.g.
> `state.float()` in, `.half()` out) is a real `coreai.cast` op that blows the tensor up — hand large
> state/activation tensors across in their native dtype and accumulate fp32 in registers."*
>
> Two costs, neither visible in a microbenchmark of the kernel:
> 1. **Ops that would have fused across your kernel's position no longer can.** This is why replacing
>    a *single* cheap op with a kernel is usually a regression: you pay a barrier to save nothing.
> 2. **Boundary casts materialize.** If your kernel wants fp32 inputs and the graph is fp16, the
>    converter inserts a real cast op writing a full-size fp32 tensor to memory. **Take the tensor in
>    its native dtype and widen inside the kernel** — `const float v = float(x[id]);` — which costs
>    nothing, versus a graph-level cast which costs a full read and write.
>
> The §3.2 SiLU body does exactly this: `x` is fp16, and the body widens per-element in a register.

### 13.4 A related structural constraint worth knowing before you commit

If your model is a language model behind Foundation Models, note that grammar-constrained decoding
(`@Generable`) requires access to engine **logits**, which GPU-pipelined Core AI bundles do not
expose (community-measured; see Part 4). A custom-kernel-bearing model is GPU-resident by
construction (§2.4), so this constraint and the kernel decision travel together.

---

## 14. Testing a kernel, and the de-risk ladder

Given §5.4 (the reference is not a test), §12.4 (bad MSL is silent until load) and §12.5 (Apple's own
end-to-end tests are off), your numerical harness is not optional. Here is the order that costs the
least.

### 14.1 Step 0 — the dispatch probe (30 lines, do this once per project)

Before any real kernel, write one that does nothing but reveal the coordinate system. The community
`probe_dispatch.py` pattern: thread 0 of each threadgroup writes a *known encoding of its own
threadgroup id* into a known-good output, and you read it back in numpy.

```python
import numpy as np
import torch
import torch.nn as nn
from coreai.authoring import MetalParameter
from coreai.runtime import NDArray, StorageKind

from coreai_torch import TorchConverter, TorchMetalKernel, get_decomp_table

PROBE_SRC = """
    // Thread 0 of each threadgroup stamps its own tgid into the output.
    if (tid.x != 0 || tid.y != 0) { return; }
    if (tgid.x >= out.get_extent(0) || tgid.y >= out.get_extent(1)) { return; }
    out[tgid.x, tgid.y] = float(100 + 10 * tgid.x + tgid.y);
"""


def torch_probe(z: torch.Tensor) -> torch.Tensor:
    return torch.zeros_like(z)


probe = TorchMetalKernel(
    "probe_dispatch",
    input_names=["z"],
    result_names=["out"],
    src=PROBE_SRC,
    torch_defn=torch_probe,
    metal_params=[
        MetalParameter("tid",  "uint2", "thread_position_in_threadgroup"),
        MetalParameter("tgid", "uint2", "threadgroup_position_in_grid"),
    ],
)


class ProbeModel(nn.Module):
    def forward(self, z: torch.Tensor) -> torch.Tensor:
        return probe(
            z,
            threads_per_grid=(8, 4, 1),            # 8 groups in x, 4 in y (1 thread each)
            threads_per_thread_group=(1, 1, 1),
            result_shapes=[list(z.shape)],
        )
```

Run it, print the numpy array, and write down which torch index moved when `tgid.x` moved. That
single fact — *"`out[a, b]` in the kernel lands at `numpy[b, a]`"* — is the thing that makes every
subsequent kernel in the project debuggable. §5.2.

### 14.2 Step 1 — compile the MSL standalone

Extract the body, wrap it in a hand-written signature, and run `xcrun metal -c probe.metal -o /dev/null`.
This is the only way to see a real Metal compiler diagnostic (§12.4). Keep the wrapper file around
and regenerate it whenever you edit the body; the five-line script that writes it is worth more than
any amount of careful reading.

### 14.3 Step 2 — Apple's numerical harness

`coreai-torch`'s own test suite ships a reusable end-to-end validator, and it has first-class
support for custom kernels:

```python
from tests.utils import validate_numerical_output

await validate_numerical_output(
    model=MatmulModel().eval(),
    custom_kernels=[custom_matmul],   # registered before conversion, for you
    metal_inputs=True,                # StorageKind.METAL on every input — required
    input_names=["x", "y"],
    output_names=["result"],
    atol=0.1, rtol=0.1,
    dynamic_shapes=dynamic_shapes,    # optional
    x=fuzzed_x, y=fuzzed_y,           # named tensors become forward() kwargs
)
```

✅ **VERIFIED** — `tests/utils.py:523-620` and its use in `tests/dsl/test_matmul_kernel.py:109-120`.
Its docstring documents two modes (`model=` end-to-end, or a pre-converted `coreai_program=` plus
`torch_out=`), and notes the default `atol=1e-2` exists *"because FP16 accuracy is flaky"*.

This lives in the repo's `tests/` package rather than the installed wheel, so you either vendor it or
reimplement the twenty lines it wraps: export → decompose → register → convert → optimize →
`save_asset` → `executable()` → `load_function` → `await function(...)` → compare against the torch
reference.

**Fuzz the shapes.** Apple's matmul test picks `M, K, N` randomly from `range(2, 20)` on every run
(`test_matmul_kernel.py:90-91`) — which is how tile-boundary bugs get found. Sizes that are exact
multiples of your tile will pass a broken kernel.

### 14.4 Step 3 — the isolation script

Community practice worth adopting wholesale: for each kernel *idea*, write a standalone 60–120-line
script that does nothing but that kernel, and reports cosine similarity plus relative L2 against a
torch reference — before it goes anywhere near your model.

> **Community-authored** — `notes/repos/john-rocky-models.md` §10.1 describes seven such scripts,
> all built on the same skeleton: *"`TorchMetalKernel(src=<MSL body>)` → `torch.export` →
> `TorchConverter.register_custom_kernels` → `add_exported_program` → `to_coreai().optimize()` →
> `save_asset` → `asset.executable()` → `load_function("main")` → `await fn({...})`, then cosine +
> relative-L2 vs a torch reference."*
>
> Two refinements from that set that are worth stealing:
> - The base matmul script reports **a per-tile correctness map**, not one aggregate number — *"so a
>   partially-wrong tiling shows up as a spatial pattern rather than one bad number."*
> - One script is a pure **A/B gate** that answers the go/no-go question before the expensive work:
>   *"does the matrix-unit path beat Core AI's default matmul at compute-bound shapes? **If
>   `matmul2d` can't beat MPSGraph matmul here, a custom FlashAttention won't beat MPSGraph SDPA
>   either (same matrix ceiling). If it can, FlashAttention is worth building.**"*
>
> That ladder produced a **negative** result on A19 (the default path was already near peak) and an
> open question on M4 Max. Which is exactly what a de-risk ladder is for, and a good reason to build
> one before you build a kernel.

### 14.5 Step 4 — bisect divergence with the debugging tools

If a kernel-bearing model produces subtly wrong output, `coreai_torch.debugging` gives you two
instruments that beat print statements:

```python
# NaN / Inf isolation on the converted program
from coreai_torch.debugging.validator import create_validator_for_coreai_program

validator = await create_validator_for_coreai_program(coreai_program, "main")
result = await validator.check_for_nans(inputs={"x": torch.randn(2, 4)})
print(result.failed_nodes[0])          # first op that produced a NaN

# Cross-framework comparison, PyTorch vs Core AI, op by op
from coreai_torch.debugging.comparator import create_comparator_for_programs

comparator = await create_comparator_for_programs(
    source_program=exported_program,
    target_program=coreai_program,
    target_entry_point="main",
)
result = await comparator.compare_with_tolerance(
    inputs={"x": example_input}, rtol=1e-5, atol=1e-8)
for source_op, target_op in result.failed_nodes:
    print(f"Mismatch: {source_op} vs {target_op}")
```

✅ **VERIFIED** — `docs/api/debugging.md`. Nearly everything in that module is `async`. Note the
comparator compares the *converted* program against the *exported* one, so for a custom kernel it is
comparing your MSL against your `torch_defn` — which is precisely the check that nothing else
performs. Remember the preview environment variables from §2.6.

The **Core AI Debugger** app (`https://developer.apple.com/core-ai-debugger/`) adds a visual version
of the same comparison with automatically identified "sync points" and a PSNR metric; Part 10 covers
it. For kernel work its value is that it will show you *where* in the graph divergence starts, which
for a fusion-barrier op is usually the boundary rather than the body.

### 14.6 One numerics rule that is not about Core AI at all

> ⚠️ **Naked `exp()` in a hand-written kernel.** Any softmax-shaped computation must subtract the
> running maximum before exponentiating. The community archive records this as an explicit standing
> rule — *"three separate sessions lost to this; subtract the max first"* — and Apple's own softmax
> fixture does it in a labelled pass: *"Pass 1 — find maximum value along the axis (numerical
> stability)"* (`tests/dsl/conftest.py:92-101`), as does their self-attention fixture, which computes
> the max only over unmasked positions so that `exp(-inf - max) == 0` handles the causal mask for
> free (`tests/dsl/test_self_attention.py:89-99`).
>
> In fp16 this is not a refinement; `exp(12)` already overflows half precision. A kernel that works
> on your test tensor and produces `inf` on real activations is the classic presentation.

---

## 15. Deployment reality

### 15.1 The kernel travels with the model

That is the design claim, and it holds through ahead-of-time compilation:

> ✅ **VERIFIED (transcript)** — session 325:184: *"The Metal source gets embedded directly in the
> asset — **a single artifact. The kernel travels with the model.**"*
>
> **Community-measured corroboration through AOT** —
> `notes/repos/john-rocky-models.md` §5.2: a `TorchMetalKernel` model **survives ahead-of-time
> compilation** — *"the `.aimodelc`'s `specialized_model_*.mpsgraph` contains the full `[[kernel]]`
> MSL signature + compiled MTLB in `resources.bin`, and the compiled asset's outputs are
> **bit-identical** to the source `.aimodel`."* Measured cold-load benefit for a GPU monolith:
> **`.aimodelc` 4.9 s vs `.aimodel` 19.2 s true-cold specialize (~4×)**; warm 0.0 s for both.
> (Single author, M4 Max / iPhone 17 Pro, beta OSes, 2026-06.)

So the artifact story is clean: one `.aimodel` directory, containing your MSL as text, which the
runtime compiles during specialization and which `coreai-build` can pre-compile per architecture.

### 15.2 What that means for the compute-unit decision

Restating §2.4 because it is the deployment consequence people discover late: **the function
containing the kernel runs on the GPU.** Not "prefers"; cannot do otherwise. If your product plan
depends on Neural Engine residency for battery life on iPhone, a custom kernel in that function
forecloses it.

The corollary that is easy to miss: this is a *per-entrypoint* decision, and Core AI's multi-function
assets let you make it per-entrypoint rather than per-model. Splitting a model into
`image_encode` / `text_encode` / `detect` is presented in session 325 as a latency technique
(*"the second inference is 76% faster, even after warmup"*, 325:261 — Apple-published, hardware and
protocol unstated), but it is also the mechanism by which parts of a model reach the Neural Engine.
Put the kernel in the function that wants the GPU and leave the others free. Guide 05 in this part
covers the split; Part 7 covers what the Swift side sees.

### 15.3 On-device compile cost and cache behaviour

Your MSL is compiled on the device the first time the model specializes. Practical notes, all
**community-measured** (single author, iPhone 17 Pro / M4 Max, beta OSes, 2026-06):

- *"The AOT load stages the precompiled MPSGraph package into `Library/Caches/coreai-cache` — needs
  ~3 GB free; **a near-full device fails ENOSPC, and the partial stage pollutes the content-keyed
  cache** → next launch fails `Code=2` (No such file)."* The recorded recovery is uninstall →
  reinstall.
- A kernel-bearing GPU model measured decode 17 tok/s, prefill 13 tok/s, resident ~2.1 GB, cold load
  9 s on iPhone 17 Pro.
- `coreai-build compile` **exits 0 for any requested architecture** — *"a successful compile does NOT
  validate the arch choice; only a device load does."*

None of that is kernel-specific, but a kernel raises the compile cost and therefore the exposure.

### 15.4 The maintenance question

Two warnings in the shipping docs, and one in the test suite, should shape how you plan:

- `docs/api/TorchMetalKernel.md`: *"These APIs are experimental and subject to change in future
  releases."*
- `pyproject.toml`: `coreai-core==1.0.0b2` — an **exact pin on a beta**.
- `tests/dsl/`: three end-to-end suites skipped pending *"once runtime kernel moved to support
  Metal 4"*.

A custom kernel is code you own forever, on a surface Apple has labelled experimental, on a hardware
target that gains capabilities per point release (§11.4). If the ladder in §2.2 offers you a rung
below 3, take it.

---

## 16. Quick reference

### 16.1 The whole API

```python
from coreai.authoring import MetalParameter          # or: from coreai_torch import MetalParameter
from coreai_torch import TorchConverter, TorchMetalKernel, get_decomp_table

TorchMetalKernel(
    name,                  # str, non-empty; becomes part of the emitted kernel name
    input_names,           # list[str]; must match torch_defn's parameter count
    result_names,          # list[str]; at least one; disjoint from input_names
    src,                   # str, the BODY of the [[kernel]] function
    torch_defn,            # Callable; annotated Tensor|int|float|bool params,
                           #   returns Tensor | list[Tensor] | tuple[Tensor, …]
    metal_params=None,     # list[MetalParameter(name, msl_type, attribute)]
    helper_src=None,       # str, pasted BEFORE the kernel definition
    template_dtypes=None,  # {input_name: "PLACEHOLDER"} → replaced with the Metal dtype
)

kernel(*args,
       threads_per_grid=(x, y, z),            # keyword-only, 3-tuple, Metal axis order
       threads_per_thread_group=(x, y, z),    # keyword-only, 3-tuple, product ≤ 1024
       result_shapes=[[...], ...])            # keyword-only, one per result, TORCH order,
                                              #   derived from input .shape — never literals

converter = TorchConverter()
converter.register_custom_kernels([kernel])   # BEFORE add_exported_program; returns self
converter.add_exported_program(ep, input_names=[...], output_names=[...])
program = converter.to_coreai()
program.optimize()                            # in-place; nothing consumes the return value
asset = program.save_asset(Path("m.aimodel")) # a DIRECTORY

async with asset.executable() as ai_model:
    fn = ai_model.load_function("main")
    out = await fn({"x": NDArray(data=arr, backing=StorageKind.METAL)})   # METAL required
    y = out["y"].numpy()                      # materialize INSIDE the block
```

### 16.2 The rules, in one place

| # | Rule | Section |
|---|---|---|
| 1 | Exhaust composite ops and custom lowerings before writing MSL | §2.2 |
| 2 | A kernel makes its function **GPU-only**, permanently | §2.4 |
| 3 | `.eval()` then `torch.export` then `run_decompositions(get_decomp_table())` | §3.1 |
| 4 | `src` is the **body**; the signature, bindings and `#include` are generated | §4.4 |
| 5 | MSL identifiers must match `input_names` / `result_names` / `metal_params` exactly — unchecked | §3.2, §12.4 |
| 6 | **Metal tensor extents are the reverse of the torch shape** | §5.2 |
| 7 | `result_shapes` derived from input `.shape`, at **every** call site | §6.4 |
| 8 | Bounds-guard every read and write; no early `return` before a barrier | §7.3 |
| 9 | `register_custom_kernels` **before** `add_exported_program` | §8.1 |
| 10 | Kernel `name` is a global key — build kernel objects at module scope | §8.2 |
| 11 | Runtime inputs need `StorageKind.METAL` | §8.4 |
| 12 | Scalars are baked as literals at trace time — they cannot vary at runtime | §9.2 |
| 13 | `inputs + results + metal_params ≤ 31` | §12.2 |
| 14 | No custom kernel inside a `torch.cond` branch (known converter bug) | §12.3 |
| 15 | Bad MSL fails only at `load_function`, with no diagnostic — compile it standalone first | §12.4 |
| 16 | OS 27 supports E8M0 auxiliary scale planes; dequantize in-kernel on 26.x or for custom formats[^xcode27-scale-planes] | §11.4 |
| 17 | 26.x supports int4/int8 here; OS 27 adds int2, FP4, FP8 and E8M0 tensor types[^xcode27-scale-planes] | §11.4 |
| 18 | A kernel is a **fusion barrier**; take tensors in their native dtype | §13.3 |
| 19 | The `torch_defn` must stay fake-traceable — no `.item()`, no `int(t[0])` | §13.1 |
| 20 | Subtract the max before `exp()` | §14.6 |

### 16.3 Error-message → cause lookup

| Message | Cause |
|---|---|
| `Kernel coreai.metal4_kernel invoked with invalid parameters` | **Any** MSL compile failure — syntax, undeclared identifier, name mismatch. §12.4 |
| `metal kernels support 31 inputs, got 32` | `inputs + results + metal_params` over budget. §12.2 |
| `… is already registered; set allow_override=True` | Two kernels share a `name`. §8.2 |
| `kernel input at index N has unsupported dtype: …` | Dtype has no MSL mapping. §5.5 |
| `result_shapes must contain one shape per result name` | Count mismatch at the call site. §6.2 |
| `torch function should have same number of parameters …` | `input_names` vs `torch_defn` arity. §4.5 |
| `custom kernels only support torch.Tensor, float, bool and int inputs` | An annotation the API cannot bind. §4.5 |
| `unsupported op in branch` | Custom kernel inside `torch.cond`. §12.3 |
| `no member named 'matmul2d'` | `__HAVE_TENSOR__` not defined for this compile. §11.5 |
| NaN logits, CPU reference fine | Axis reversal. §5.2 |

---

## 17. Sources and evidence ledger

### 17.1 Primary — read this session, on disk

**`apple/coreai-torch`**, local clone at `repos/apple__coreai-torch`, git `main`,
HEAD `4529671`, package version **0.4.1**, `coreai-core==1.0.0b2`:

- `coreai_torch/_torch_metal_kernel.py` — **read in full (445 lines)**. Every constructor field,
  every validation message, the scalar-literal injection, the augmented torch-op signature, and the
  `__call__` implementation come from here with line citations.
- `coreai_torch/converter.py:1016-1080` — `register_custom_kernels` and the duplicate-registration
  error.
- `coreai_torch/_utils.py:1070-1086` — `scalar_constant` and the fp16-promotion bypass.
- `coreai_torch/__init__.py` — the public surface and the `MetalParameter` re-export.
- `docs/api/TorchMetalKernel.md` — **read in full (178 lines)**; the constructor table, the call
  table, the constraints, the templating and multiple-output examples.
- `docs/guides/custom-metal-kernels.ipynb` — **all 14 cells**; the "When You Need This" gate, the
  four-step walkthrough, and the two extra examples.
- `docs/api/TorchConverter.md`, `docs/api/debugging.md`, `docs/getting-started/quickstart.ipynb`,
  `docs/coreai-core/tutorials/run-an-aimodel.ipynb`, `docs/guides/conversion-workflows.ipynb`.
- `tests/dsl/` — **all 14 files**. This is where most of the non-obvious material in this guide comes
  from:
  - `conftest.py` — the collection hook, and Apple's four MSL fixtures (softmax, naive matmul, tiled
    matmul, with per-dtype literal specialization).
  - `test_custom_kernels.py` — the emitted IR, the 31-parameter limit, dtype rejection, all the
    construction-time validation.
  - `test_thread_config.py` — **the axis-reversal docstring**, dispatch lowering, and the
    boundary-behaviour tests.
  - `test_failures.py` — the malformed-MSL silent failure, in full.
  - `test_matmul_kernel.py` — the working naive and tiled matmul call sites, dtype parametrization,
    shape fuzzing, `validate_numerical_output` usage.
  - `test_metal_kernel_robustness.py` — zero-input kernels, empty bodies, the `torch.cond` xfail,
    name and arity validation.
  - `test_scalar_inputs.py` — `constant T&` bindings, the 31-buffer accounting.
  - `test_dtype_specialization.py`, `test_kernel_collisions.py` — the kernel cache semantics.
  - `test_softmax.py`, `test_self_attention.py`, `test_multiple_kernels.py` — **currently skipped**;
    read for their MSL and their skip reasons.
- `tests/utils.py:200-620` — `validate_numerical_output`, `metal_inputs`, `custom_kernels`.
- `.github/workflows/ci.yml:37` — `-m "not slow and not dsl"`.
- `pyproject.toml` — versions, pins, markers.

**`apple/coreai-models`**: `python/src/coreai_models/segmentation/pipeline.py:265-286` (the shipped
three-entrypoint SAM3 conversion); `models/sam3/README.md`.

### 17.2 Primary — transcripts

- **WWDC26 session 325**, *"Dive into Core AI model authoring and optimization"* (Sachin, Core AI
  team; Nicole, Core AI Debugger). Lines 166–205 are the custom-kernel segment; 178–184 and 186–204
  are quoted verbatim here. Via `notes/transcripts/coreai-python-metal.md`.
- **WWDC26 session 330**, *"Optimize custom machine learning operations with Metal tensors"*
  (Shiyao, GPU Software Engineer). Lines 118–137 are the Core AI hand-off and the SAM3
  FlashAttention integration. Via the same note.
- **Apple Tech Talk 111432**, *"Accelerate your machine learning workloads with the M5 and A19
  GPUs"* — the TensorOps version ladder. Via `notes/transcripts/missing-sessions.md` §7.5.

### 17.3 Primary — SDK headers

`MetalPerformancePrimitives.framework` and `Metal.framework` headers from two captures. The Xcode
26.6 baseline is read via `notes/repos/mlx-tensorops-kernels.md` and
`notes/transcripts/coreai-python-metal.md` §2; the OS 27 half — the low-bit types and auxiliary
planes — is read directly from the macOS 27.0 beta SDK's shipped headers
(`MPPTensorOpsMatMul2d.h`, `__impl/MPPTensorOpsTypes.h`, `__impl/MPPTensorOpsAvailability.h`,
`MTLTensor.h`). Used for the dtype set, the supported matmul combinations, the feature macros and
the 26.x deployment baseline, plus the OS 27 low-bit types and auxiliary
planes.[^xcode27-scale-planes]

### 17.4 Community — attributed, never presented as Apple

`notes/repos/john-rocky-models.md`, summarizing the `john-rocky/coreai-model-zoo` knowledge files.
⚠️ **Single-author material with self-declared uncontrolled benchmarks**, on beta operating systems,
M4 Max and iPhone 17 Pro, dated April–July 2026. Everything drawn from it in this guide is labelled
community-measured at the point of use. It is also the only source in existence for several facts —
the `gather_qmm` result, the axis-reversal NaN, the fusion-barrier cost, the AOT survival of a
kernel-bearing model — which is why it is here at all.

`notes/repos/mlx-tensorops-kernels.md` — MLX's Metal kernels and the MPP header analysis. MLX is
Apple's, but its *kernels* are engineering choices, not API documentation; used here for corroborating
what the headers do and do not contain.

### 17.5 Where sources disagreed, and how this guide ruled

| Conflict | Ruling |
|---|---|
| Session 330 narrates `MTLTensor` **scale planes** with `blockFactors` and an auxiliary plane map | **Corroborated by Xcode 27.** The older negative result came from Xcode 26.x headers and the pinned MLX implementation; in-kernel cooperative-tensor dequantization remains the fallback for 26.x and custom formats. §11.4[^xcode27-scale-planes] |
| Session 330 says int2, FP4, FP8 and E8M0 tensor types are new in iOS/macOS 27 | **Corroborated by Xcode 27.** The 26.0/26.1/26.3/26.4 ladder still describes earlier TensorOps capabilities; the new low-bit formats form a distinct OS 27 tier. §11.4[^xcode27-scale-planes] |
| CORRECTIONS-PENDING C3 said TensorOps availability is a blanket **26.2** | **Superseded** by Tech Talk 111432's ladder (26.0/26.1/26.3/26.4). Both the ladder and the 26.2 *symbol* macro are printed, as separate facts. §11.4 |
| `MetalParameter`'s keyword names | Community-cited only; **guide uses the verified positional form**. §4.6 |
| Community dtype map omits `int16`; Apple's test parametrizes over it and passes | Apple's test wins; both stated. §5.5 |
| Docs example writes `TYPE sum = 0.0f;` under templating; Apple's own tests specialize the literal per dtype | Tests win — the docs example is float-only. §10.1 |
| Session 325 presents the multi-function split purely as a latency technique | The optional `coreai-models` loader additionally maps recognized structures to its Neural Engine preference; this is package policy, not a framework contract. |

### 17.6 Declared gaps — nothing is guessed inside these

1. **The SiLU MSL body from session 325:191.** Never read aloud; the exact expression and whether it
   used `exp`, `precise::exp` or `fast::exp` is unrecoverable. §3.2 reconstructs the shape and says
   so. **Resolution:** a frame capture of the session slide.
2. **The FlashAttention kernel and monkey-patch from session 330.** Shown on screen, not narrated;
   tile sizes, threadgroup configuration, the patched class and the `TorchMetalKernel` arguments are
   all unknown, and Apple's shipped SAM3 recipe does not contain the kernel. **Resolution:** the
   "TensorOps sample code" download referenced at 330:136, which is not in this corpus. §11.3.
3. **`MetalParameter`'s keyword parameter names**, and the accepted set of attribute strings. The
   file (`coreai/authoring/metal.py`) ships in a wheel, not as source. **Resolution:** an installed
   `coreai-core`. §4.6.
4. **The symbolic path through `result_shapes`** — no test in this corpus exports a kernel model with
   a dynamic *result-bearing* dimension and runs it at two sizes. **Resolution:** one experiment on a
   Mac with `coreai-torch` installed. §6.6.
5. **The MSL language version the embedded source is compiled at.** Determines whether Metal 4.1
   constructs are reachable. No parameter exposes it. **Resolution:** an empirical probe, or the
   `coreai.authoring` source. §11.5.
6. **The full dtype mapping table.** Reconstructed from a community note plus Apple's test
   parametrization; the authoritative table is inside `coreai-core`. §5.5.
7. **Whether the three skipped `tests/dsl/` suites reflect a runtime regression or an API migration
   in progress.** The skip reason names a removed `ExecutableOptions(enable_encoding_functions=…)`
   parameter and *"once runtime kernel moved to support Metal 4"*; whether both are the same issue is
   not stated. **Resolution:** a later `coreai-torch` release, or the `coreai-core` changelog — which
   does not exist yet (`docs/release-notes.md` is a "Coming soon" placeholder). §12.5.

### 17.7 Not used as evidence

- Any claim that Core AI ships an Apple sample-code project for custom kernels. **It does not** —
  verified 0 `sampleCode` entries across 312 indexed Core AI symbols;
  `/documentation/updates/coreai` 404s.
- The invented spellings in circulation: `.coreaimodel`, `.aiasset`, a `coreai-torch convert` CLI,
  "iOS 20 / macOS 17", an on-device LoRA training API. None appear in any Apple artifact in this
  corpus. The extension is **`.aimodel`** (a directory), the entry point is the **`TorchConverter`
  class**, and the OS line is **26 / 27**.
- OS 27 scale-plane APIs without their documented E8M0/block-factor/usage constraints. §11.4.

---

**Next in this part:** guide 04 covers `register_torch_lowering` — the rung-2 alternative that
expresses a new op with Core AI primitives instead of MSL, and keeps every compute unit available.
**Next for kernel authors:** [Part 11 — Metal and TensorOps](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-11-metal-and-tensorops/README.md),
which is where the kernel body itself gets written.

[^xcode27-scale-planes]: Apple’s OS 27 API reference documents the scale-plane descriptor, the tensor
    descriptor’s auxiliary-plane map, and the new tensor datatypes:
    [`MTLTensorAuxiliaryPlaneDescriptor`](https://developer.apple.com/documentation/metal/mtltensorauxiliaryplanedescriptor),
    [`MTLTensorDescriptor.auxiliaryPlanes`](https://developer.apple.com/documentation/metal/mtltensordescriptor/auxiliaryplanes), and
    [`MTLTensorDataType`](https://developer.apple.com/documentation/metal/mtltensordatatype).
    The automatic-dequantization path and custom-format fallback are both stated in the authoritative
    [WWDC26 session 330 transcript](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/transcripts/wwdc2026-330.txt#L53-L78).

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
