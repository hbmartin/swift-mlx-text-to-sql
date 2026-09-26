# When an op will not convert: coverage, composite ops, custom lowerings, externalization

**Part 8 · Core AI: converting from PyTorch · Reference 02**

**Version floor.** Everything here is `coreai-torch` **0.4.1** (published 2026-07-06), which pins
`coreai-core==**1.0.0b2**` exactly, requires **Python ≥ 3.11**, and accepts **torch ≥ 2.8.0** with no
upper bound but warns above **2.13.0**. The `.aimodel` assets it produces run on **iOS 27.0 /
iPadOS 27.0 / macOS 27.0** and are compiled with **Xcode 27.0+**; nothing in this guide back-deploys
to any 26.x OS, because the Core AI framework does not exist there. Two hard version gates you must
know before you read anything else:

> ⚠️ ✅ **VERIFIED** — `coreai-torch` v0.4.1 release notes, verbatim: *"**.aimodel artifacts converted
> with coreai-torch v0.4.0 will fail to load/specialize on-device starting with OS 27 second beta
> onwards. Reconvert your model using coreai-torch v0.4.1 or later to produce a compatible
> artifact.**"* Maintainer @gokulkrishna98 on `coreai-torch#37` (resolved: closed as completed
> 2026-07-13): *"from macOS beta 2 the assets
> generated via coreai-torch 0.4.0 will fail to compile. Please use coreai-torch 0.4.1 for
> conversion."* There is a recovery path that does not require re-conversion — §9.6.

> ⚠️ ✅ **VERIFIED** — everything under `coreai._compiler` (which is where the graph-building
> primitives you need for a custom lowering live) is **private upstream API**. `coreai-torch`'s own
> docs say so: *"The leading underscore on `_compiler` marks this as private upstream API — it may
> move or change without notice across `coreai-core` releases."*
> (`docs/guides/custom-op-lowering.ipynb`, cell 0.) A `coreai-core` wheel bump can break every
> custom lowering you wrote. Pin it.

**Evidence standard for this guide.** Core AI ships **zero Apple sample-code projects** — verified:
0 `sampleCode` entries across all 312 indexed Core AI symbols, and `/documentation/updates/coreai`
404s. So unlike Parts 1–6, there is no first-party compiling reference project to check against.
What there *is*, and what this guide leans on, is stronger than it sounds: the **shipped source of
`apple/coreai-torch` at commit `4529671` (version 0.4.1)** and **`apple/coreai-models`**, both read
directly off disk this session, plus Apple's own agent skills in `coreai-models`, the package's
documentation, and the issue tracker. Where a claim comes from source, the file and line are named.

---

## What this covers

This is the debugging guide for **conversion failures** — and, more importantly, for **conversions
that succeed but should not have**.

`TorchConverter` gives you an error message for the easy case: an op it cannot lower. The error is
good, it names the ops, and it tells you the fix. That case is five minutes of work. The cases that
cost you a week are the other three: an op that *is* supported but not in the overload your
decomposition path produced; a decomposition table that quietly changed shape under you; and a
lowering that ran, produced a correctly-shaped tensor, and got the arithmetic wrong.

- **Op coverage and the overload rule.** `docs/api/supported-aten-ops.md` lists every ATen operator
  `TorchConverter` lowers out of the box, in FX qualified-name form `op_name.overload`. Coverage is
  **per-overload, not per-op**, and which overload you get depends on your decomposition path. This
  is the single highest-value fact in the guide and it is stated once, in one sentence, in Apple's
  docs. §2.
- **Reading the two validator errors.** They are different errors with different fixes and they are
  easy to confuse. Plus the third error, which fires *later*, from a different code path, with a
  different message. §3.
- **A worked diagnosis procedure** for "supported op, unsupported overload" — the failure mode with
  no error message that says so. §4.
- **Composite ops as a library you author models from**, not merely a conversion detail. All fifteen
  documented composites, both categories, the attribute schemas, and the three traps. §5.
- **The unadvertised capability**: `gather-mm` is Mixture-of-Experts expert dispatch and
  `gated-delta-update` is a modern linear-attention / state-space update (Qwen3-Next class). Core AI
  therefore has **first-class MoE and SSM support in the IR**. Nobody said this out loud. §6 also
  says exactly how far that support does *not* extend up the stack, which matters more.
- **Custom lowerings**: `register_torch_lowering()`, `allow_override=True` to replace a built-in, the
  six-way dispatch ladder, the registration-ordering rule, and `generate_composite_decl` for
  emitting a *composite* from your own lowering — with Apple's own shipping example. §7.
- **Externalization**: `ExternalizeSpec` and `externalize_modules`, the five-phase pipeline, and the
  real motivations from Apple's own agent skill. §8.
- **Four live silent-miscompile defects on 0.4.1**, all verified against the shipped source in this
  session, all with open-or-closed-unmerged fixes as of 2026-07-29. §9.
- **A diagnostic checklist**: given a symptom, which of the four failure classes is it, and which
  tool finds it. §10.

## What this does *not* cover

- **The basic conversion pipeline** — `torch.export` → `run_decompositions` → `TorchConverter` →
  `optimize()` → `save_asset()`. See [`01-conversion-and-the-io-contract.md`](01-conversion-and-the-io-contract.md).
- **Compression and numeric formats** — `coreai-opt`, quantization, palettization, fp16 casting. That
  is [Part 9](../../part-09-coreai-compression-numerics/README.md).
- **The Core AI Debugger app, `coreai_torch.debugging`, and the ANE/GPU hardware rules** — that is
  [Part 10](../../part-10-coreai-hardware-authoring-debugging/README.md), and this guide cross-links to it at
  every point where a diagnosis needs a tool.
- **Custom Metal kernels** (`TorchMetalKernel`). A kernel is a different escape hatch from a
  lowering, with a different failure surface; it belongs with the hardware-authoring material in
  Part 10.

## What you need

- `pip install coreai-torch` (0.4.1 or later — see the version gate above), on **macOS, Apple
  silicon**. There are **no Linux/arm64 `coreai-core` wheels**; Linux containers need
  `--platform linux/amd64`, and even then you get conversion, not execution.
- A model that already exports cleanly through `torch.export.export`. If `torch.export` fails, none
  of this applies yet — `add_pytorch_module` re-raises the export error with a message telling you
  exactly that (§3.4).
- Optional but strongly recommended: a local clone of `apple/coreai-models`. It is the only place
  outside your own code where you can read a real, shipping `_EXTERNALIZE_SPECS` list and a real
  `register_torch_lowering` call site (§7.7, §8.5).

---

## Contents

1. [Four ways a conversion fails](#1-four-ways-a-conversion-fails)
2. [The coverage table and the overload rule](#2-the-coverage-table-and-the-overload-rule)
3. [The validator errors, and the third one that is not from the validator](#3-the-validator-errors-and-the-third-one-that-is-not-from-the-validator)
4. [Diagnosing an overload mismatch](#4-diagnosing-an-overload-mismatch)
5. [Composite ops: a library you author models from](#5-composite-ops-a-library-you-author-models-from)
6. [The unadvertised capability: first-class MoE and SSM](#6-the-unadvertised-capability-first-class-moe-and-ssm)
7. [Custom lowerings](#7-custom-lowerings)
8. [Externalization](#8-externalization)
9. [Four live silent-miscompile defects on 0.4.1](#9-four-live-silent-miscompile-defects-on-041)
10. [The diagnostic checklist](#10-the-diagnostic-checklist)
11. [Quick reference](#11-quick-reference)
12. [Sources and evidence ledger](#12-sources-and-evidence-ledger)

---

## 1. Four ways a conversion fails

Every conversion problem you will hit falls into one of four classes. They have different symptoms,
different error messages (or none), and — critically — **different fixes**. Getting the class wrong
is how people spend three days writing a custom lowering for an op that was already supported.

| # | Class | Symptom | What is actually wrong | Fix |
|---|---|---|---|---|
| 1 | **Unsupported op** | `ValueError: The exported program contains unsupported ATen ops: …` at `add_exported_program()` | The op has no entry in `_aten_to_core_resolver` under any overload | Write a custom lowering (§7), or restructure the model to avoid the op |
| 2 | **Wrong overload** | Same error text, but the op *is* in `supported-aten-ops.md` | Your decomposition path produced `foo.bar` where the registry has `foo.default` | Change the decomposition path, or register the missing overload (§4) |
| 3 | **Decomposition-table miss** | `ValueError: The exported program contains non-decomposed ops: …` | You did not call `run_decompositions()`, or you called it with the wrong table | `ep.run_decompositions(coreai_torch.get_decomp_table())` (§3.3) |
| 4 | **Silent miscompile** | Conversion succeeds. Shapes are right. Numbers are wrong. | A lowering ran and got the arithmetic wrong, or `optimize()` deleted something load-bearing | Numerics gates (§10), then work around the specific defect (§9) |

Classes 1 and 3 announce themselves. Class 2 announces itself with a *misleading* message — the
error says "unsupported", the doc says "supported", and both are telling the truth about different
things. Class 4 announces nothing at all.

> ⚠️ **SILENT FAILURE — the shape of the problem.** Core AI's conversion stack is dominated by
> class 4. The corpus of open issues on `apple/coreai-torch`, `apple/coreai-optimization` and
> `apple/coreai-models` contains **seventeen distinct defects that produce plausible output with the
> correct shape and no diagnostic**. Four of them live in `coreai-torch` 0.4.1 with unmerged fixes as
> of 2026-07-29 and are documented in §9. The practical consequence: **a conversion that "worked" is
> not evidence of anything until you have run a numerics gate.** §10 gives you four of them.

Two structural facts explain why class 2 exists at all, and they are worth internalising before §2:

1. **`coreai-torch` does not decompose your model.** You do. `run_decompositions()` is your call,
   with your table, and the converter validates the *result*. Two developers converting the same
   `nn.Module` on different PyTorch versions can hand the converter structurally different graphs.
2. **The registry is keyed on the FX target string**, which carries the overload suffix. There is no
   fuzzy matching, no fallback to a sibling overload, and no "did you mean" — a key is present or it
   is not.

> ✅ **VERIFIED** — `coreai_torch/converter.py:674-678`, the first four lines of
> `_handle_call_function_op`:
>
> ```python
> target: str = get_target(node)
> namespace: str | None = get_namespace(node)
> qualified_target: str = f"{namespace}::{target}"
> variantless_target: str = strip_variant_from_target(target)
> ```
>
> and `coreai_torch/_utils.py:417-419`:
>
> ```python
> def get_target(node: fx.Node) -> str:
>     """Return the target name from an FX node."""
>     return node.target.__name__ if callable(node.target) else str(node.target)
> ```
>
> For an `OpOverload` like `torch.ops.aten.add.Tensor`, `__name__` is `"add.Tensor"`. That string —
> including the overload — is the dictionary key.

---

## 2. The coverage table and the overload rule

### 2.1 Where the table is and how it is organised

`docs/api/supported-aten-ops.md` in the `coreai-torch` package is the canonical list. Its first
sentence is unambiguous about scope:

> ✅ **VERIFIED** — `docs/api/supported-aten-ops.md:3`, verbatim:
> *"This page lists every PyTorch ATen operator that `TorchConverter` lowers to Core AI operations
> out of the box."*

The table has roughly 180 rows across two sections — ATen ops and higher-order ops — with a Notes
column that is genuinely load-bearing (it is where you learn that `cumsum` becomes a `coreai.scan`
and that `alias` emits no IR at all).

The four bullets under *"How to read this page"* are the whole contract. Here they are verbatim,
because every one of them is a footgun:

> ✅ **VERIFIED** — `docs/api/supported-aten-ops.md:7-10`, verbatim:
>
> - *"Op names use the FX qualified-name form `op_name.overload` (e.g. `add.Tensor`, `mean.dim`).
>   **When PyTorch's decomposition pipeline produces a different overload than the one listed, that
>   overload is not supported.**"*
> - *"A few names appear without an overload suffix (e.g. `add`, `mul`, `getitem`) — these match
>   plain Python-operator FX nodes that have no `.default` overload."*
> - *"Three ops — `instance_norm.default`, `pixel_shuffle.default`, and
>   `scaled_dot_product_attention.default` — are deliberately preserved by `get_decomp_table()` and
>   emitted as composite ops in the lowered IR."*
> - *"All ops below are resolved through the registry in `coreai_torch._aten_to_core`. To override a
>   built-in lowering with your own, pass `allow_override=True` to `register_torch_lowering()`."*

### 2.2 ⚠️ The overload rule, stated plainly

The emphasis in that first bullet is mine. Apple states the rule once, in a subordinate clause, in a
"how to read this page" preamble that most readers skip. It is the most consequential sentence in
the entire `coreai-torch` documentation set:

> ⚠️ **SILENT FAILURE — coverage is per-overload, not per-op.**
>
> `mean.dim` is supported. `mean.default` is supported. `mean.names_dim` is not — it is not in the
> table and it is not in the registry. `pow.Tensor_Scalar`, `pow.Tensor_Tensor` and `pow.Scalar` are
> supported; a fourth `pow` overload would not be. `sum.dim_IntList` is supported and **`sum.default`
> is not in the table at all**.
>
> The failure this produces is not silent in the sense of "wrong numbers" — it throws. What is
> silent is the *diagnosis*: the error says `unsupported ATen ops: aten.foo.bar`, you look up `foo`
> in the table, you find it, and you conclude the error is wrong or the package is broken. It is
> neither. You have a different overload.

The reason this is not a documentation bug is that the registry genuinely is a flat dictionary of
qualified names. Look at the shape of it:

> ✅ **VERIFIED** — `coreai_torch/_aten_to_core.py`, the resolver table (excerpt, lines 3591-3593
> and 3719-3722):
>
> ```python
> "div.Scalar": replace_binary_ops,
> "div.Tensor": replace_binary_ops,
> "div.Tensor_mode": replace_div_tensor_mode,
> ...
> "truediv": replace_truediv,
> "true_divide.Tensor": replace_binary_ops,
> ```
>
> Three `div` overloads, two of which share a handler and one of which does not. `true_divide` has
> exactly one overload registered, `.Tensor`. Nothing here would match `div.out` or
> `true_divide.Scalar`.

### 2.3 Why the overload you get is not under your control (entirely)

The overload in your FX graph is chosen by PyTorch, during export and decomposition, from inputs you
mostly do not control directly:

| Input | Effect on the overload |
|---|---|
| **PyTorch version** | The decomposition table ships with torch. `torch.export.default_decompositions()` is different between 2.8 and 2.13, and `coreai-torch` accepts that whole range |
| **Which decomposition table you pass** | `get_decomp_table()` preserves 12 ops; the raw default preserves none of them; passing nothing at all preserves everything |
| **Argument types at the call site** | `x / 2` produces a `Scalar` overload; `x / y` produces `Tensor` |
| **Whether you used the functional or module form** | `F.pixel_shuffle` and `nn.PixelShuffle` reach the same ATen op; `torch.nn.functional.adaptive_avg_pool2d(x, (1,1))` reaches `_adaptive_avg_pool2d.default` |
| **`strict=True` vs `strict=False` on `torch.export.export`** | Different tracing frontends can produce different graphs for the same code |
| **Dynamic vs static shapes** | Symbolic-int paths introduce `sym_size.int`, `sym_float`, `sym_min` nodes that static exports never contain |

That last row is not hypothetical. `coreai-torch` PR **#13** (merged, commit `53d6bdd`, "Harden
mixed-source SymInt lowerings under dynamic shapes") existed *because* dynamic-shape export produces
target strings that static export does not:

> ✅ **VERIFIED** — PR #13's own description, quoted in the issue thread: the fix registers a **bare
> `aten.pow`** and a **bare `aten.round`** resolver entry because *"torch.export rewrites leave
> `aten.pow` as the OpOverloadPacket target with no overload suffix"*. Before that PR, a model that
> converted fine with static shapes failed with `Unsupported ATen op: pow` the moment you added a
> `dynamic_shapes=` argument.

That is class 2 in its purest form: same model, same package, same op, *different overload*, because
one export was dynamic.

### 2.4 The bare-operator keys

The second bullet in §2.1 describes a second family of keys with no overload suffix at all. These
are FX nodes for plain Python operators — `operator.add`, `operator.getitem` — which have no ATen
overload because they are not ATen ops:

> ✅ **VERIFIED** — the following appear in the table without an overload suffix
> (`docs/api/supported-aten-ops.md`): `add`, `ceil`, `floordiv`, `getitem`, `mod`, `mul`, `neg`,
> `sub`, `sym_float`, `sym_min`, `truediv`, `trunc`. Several appear in *both* forms — e.g.
> `` `ceil`, `ceil.default` `` and `` `neg`, `neg.default` `` are single table rows listing both.

Two practical consequences:

1. **`getitem` is a real, supported op that emits no IR.** Any lowering returning multiple values
   produces `getitem` nodes downstream, and they are pure index reads into `values_map`.
   ✅ **VERIFIED** — `coreai_torch/_aten_to_core.py:1644-1650`, the entire handler:

   ```python
   def replace_getitem(values_map, node, loc):
       item_idx_name = f"{node.args[0].name}#{node.args[1]}"
       if item_idx_name in values_map:
           return values_map[item_idx_name]
       return values_map[node.args[0].name]
   ```

   That `"#{i}"` key format is the same one the dispatcher writes when your lowering returns a list
   (§7.1) — which is exactly why returning a Python list of `Value`s Just Works downstream.
2. **When you write a custom lowering for a bare-operator key, the qualified name still needs a
   namespace.** `register_torch_lowering` splits on `"::"` and requires exactly two non-empty parts.
   A bare-operator node's namespace is `None`, which routes to the ATen branch (§7.4), so you would
   register it as `"aten::truediv"`.

### 2.5 Doc/source drift: two supported ops the table does not list

The table is generated by hand, and it has fallen behind the resolver twice:

> ✅ **VERIFIED** — `coreai_torch/_aten_to_core.py`'s resolver contains `"atan2.default"` (added in
> commit `a43cc84`, corrected in `1b3cb3b`) and `"masked_scatter.default"` (added in `a68f1ad`).
> Neither appears in `docs/api/supported-aten-ops.md` at commit `4529671`.

So the doc is a *lower bound* on coverage, not an exact one. The authoritative check is the
registry itself, which you can query in three lines:

```python
# Ground truth for "is this exact overload supported?" — 0.4.1.
# Note: _aten_to_core is a private module. This is a diagnostic, not production code.
from coreai_torch._aten_to_core import _aten_to_core_resolver

print(len(_aten_to_core_resolver))                  # total registered keys
print("masked_scatter.default" in _aten_to_core_resolver)   # True on 0.4.1
print("mean.names_dim" in _aten_to_core_resolver)           # False

# Everything the registry knows about a given op name, across all overloads:
op = "div"
print(sorted(k for k in _aten_to_core_resolver if k.split(".")[0] == op))
# -> ['div.Scalar', 'div.Tensor', 'div.Tensor_mode']
```

That last query is the one to reach for when the error message and the documentation disagree. It
answers the actual question — *which overloads of this op exist in the registry* — which neither the
error nor the doc answers.

### 2.6 The three op groups worth knowing by name

Three groups in the table behave differently enough from "op in, op out" that they deserve calling
out before you debug anything.

**Ops that emit no IR.** `alias.default` — *"Identity — no IR emitted"*. `clone.default` —
*"Identity in the absence of memory-format changes"*. `_to_copy.default` and `to.dtype` — *"Identity
or `coreai.cast`"*. `_local_scalar_dense.default` — *"Returns the 0-dim input as-is"*. If you are
reading converted IR and looking for the `clone()` you wrote, it is not there, and that is correct.

> ⚠️ This matters for a specific bug class. `coreai-torch#11` reports a runtime buffer-liveness
> defect where an unrelated live tensor gets clobbered, and the reporter states verbatim:
> *"**inserting `clone()`/`contiguous()` barriers does not protect the victim.**"* Now you know why —
> `clone` is an identity in the lowered IR. Barrier-by-clone is not a technique that exists here.

**Ops that become something structurally different.** `cumsum.default` → *"`coreai.scan` with a sum
combiner"*. `embedding.default` and `index.Tensor` → `coreai.gather_nd`. `index_put.default` →
`coreai.scatter_nd`. `slice_scatter.default` → `coreai.slice_update`. `isinf.default` → *"`(x ==
+inf) | (x == -inf)`"*. When you inspect the IR or read a `freqop` histogram, these are the names you
will see, not the ATen ones.

**Higher-order ops.** Exactly two are supported:

> ✅ **VERIFIED** — `docs/api/supported-aten-ops.md`, "Higher-order ops" section, verbatim:
>
> | Op | Notes |
> |---|---|
> | `cond` | `torch.cond` — emitted as a Core AI conditional with two branch subgraphs |
> | `while_loop` | `torch._higher_order_ops.while_loop` |

> ⚠️ **SILENT FAILURE — higher-order ops convert but do not run everywhere.** `coreai-torch`'s own
> test suite auto-skips every test marked `control_flow` when the compute unit is anything other
> than the bundled interpreter, with this reason (✅ VERIFIED, `tests/conftest.py`): *"Higher-order
> ops like `torch.cond` / `while_loop` are **not yet supported by the cpu/gpu/neural_engine compute
> unit runtimes**."* Your model containing a `while_loop` will convert, save, and pass a Python
> interpreter run. It may then fail — or, per `coreai-torch#2`, crash the MPSGraph runtime with an
> `EXC_BAD_ACCESS` — on the delegate you actually ship on. This is directly relevant to §6, because
> `GatedDeltaUpdate` is implemented with `torch.ops.higher_order.while_loop` internally.

---

## 3. The validator errors, and the third one that is not from the validator

### 3.1 Where validation runs

`validate_exported_program()` runs **eagerly**, inside `add_exported_program()` and inside
`add_pytorch_module()` — not at `to_coreai()`. So you get the error at the line where you staged the
program, which is the useful place for it.

> ✅ **VERIFIED** — `coreai_torch/converter.py`, `add_exported_program` body, in order:
> `inject_subbyte_tensors(exported_program)` → `validate_exported_program(exported_program,
> self._user_defined_torch_lowering)` → append a `_StagedEntry` → `return self`.

The validator's own docstring states the two cases exactly:

> ✅ **VERIFIED** — `coreai_torch/_validate.py:29-38`, verbatim:
> *"Validate that an exported program is ready for conversion.*
> *Raises `ValueError` with an actionable message when:*
> *1. The program contains ops that should have been decomposed by `run_decompositions()` — the
> caller forgot to call it.*
> *2. The program contains core ATen ops that are not supported by the converter — the user needs
> `register_torch_lowering()`."*

### 3.2 Error A — "non-decomposed ops"

> ✅ **VERIFIED** — `coreai_torch/_validate.py:106-112`, verbatim:
>
> ```python
> raise ValueError(
>     f"The exported program contains non-decomposed ops: {ops_list}. "
>     f"Please call run_decompositions() on your ExportedProgram before "
>     f"passing it to TorchConverter. Example:\n"
>     f"  ep = ep.run_decompositions(coreai_torch.get_decomp_table())"
> )
> ```

**What it actually means.** The op you were handed appears in
`torch.export.default_decompositions()` — i.e. PyTorch itself considers it a composite that *should*
have been decomposed — **and** the converter has no lowering for it, and neither do you. The
canonical example is `aten.linear`, which is in the default decomposition table and has no
`coreai-torch` lowering, so a graph that still contains it means `run_decompositions()` was never
called.

Note the subtlety in the validator's control flow: an op in the default decomposition table that the
resolver *does* know how to lower is **not** an error. The validator checks the resolver first.

> ✅ **VERIFIED** — `coreai_torch/_validate.py:72-84`:
>
> ```python
> # Check if the op should have been decomposed.
> # But first check if the resolver can handle it directly.
> if target_str in decomp_targets:
>     ...
>     if (
>         resolver_key not in _aten_to_core_resolver
>         and qualified_target not in user_lowerings
>     ):
>         non_decomposed.append(target_str)
>     continue
> ```

**Fix:** call `run_decompositions()` with `get_decomp_table()`. Which brings us to the trap.

### 3.3 ⚠️ The `get_decomp_table()` trap — using the wrong table makes conversion *fail*

The intuition most people bring is "the default table is the safe one; `get_decomp_table()` is an
optimisation." That is backwards.

> ✅ **VERIFIED** — `coreai_torch/_decomp.py`, the complete list:
>
> ```python
> _COMPOSITE_OPS: list = [
>     torch.ops.aten.hardsigmoid.default,
>     torch.ops.aten.hardswish.default,
>     torch.ops.aten.instance_norm.default,
>     torch.ops.aten.pixel_shuffle.default,
>     torch.ops.aten.reflection_pad1d.default,
>     torch.ops.aten.reflection_pad2d.default,
>     torch.ops.aten.reflection_pad3d.default,
>     torch.ops.aten.replication_pad1d.default,
>     torch.ops.aten.replication_pad2d.default,
>     torch.ops.aten.replication_pad3d.default,
>     torch.ops.aten.scaled_dot_product_attention.default,
>     torch.ops.aten.silu.default,
> ]
>
> def get_decomp_table() -> dict:
>     table = torch.export.default_decompositions()
>     for op in _COMPOSITE_OPS:
>         table.pop(op, None)
>     return table
> ```
>
> That is the entire implementation. Twelve ops removed from PyTorch's default table; nothing added.
> Each call returns a **fresh copy** — mutating what you get back does not affect other callers
> (tested by `test_returns_independent_copy`).

The docstring splits the twelve into two purposes:

> ✅ **VERIFIED** — `coreai_torch/_decomp.py`, `get_decomp_table` docstring:
> *Composite ops:* `hardsigmoid.default`, `instance_norm.default`, `pixel_shuffle.default`,
> `scaled_dot_product_attention.default`.
> *Direct lowerings:* `hardswish.default`, `reflection_pad{1,2,3}d.default` (to `coreai.pad` reflect),
> `replication_pad{1,2,3}d.default` (to `coreai.pad` replicate), `silu.default`.

> ⚠️ **SILENT FAILURE — inverted, and worth reading twice.** Using
> `torch.export.default_decompositions()` instead of `get_decomp_table()` does **not** give you a
> more-decomposed, more-portable graph. It gives you a graph that **fails to convert**.
>
> `coreai-torch`'s own test proves it: `test_add_pytorch_module_full_table_decomposes_instance_norm`
> asserts `pytest.raises(ValueError, match="unsupported ATen ops")`, because full decomposition of
> `instance_norm` produces `_native_batch_norm_legit` — an overload with **no lowering** (the
> registry has `_native_batch_norm_legit_no_training.default`, note the suffix, and only that one).
>
> This is class 2 and class 3 in the same failure. You decomposed *more*, which turned a supported
> composite into an unsupported overload. The error you get says "unsupported", and the fix is to
> decompose *less*.

The `pad` entries are recent — they arrived in PR **#29** ("do not decompose pad op"), whose
rationale was that non-`constant` pad modes were being decomposed into many small ops and
complicating the IR. If you are on 0.4.0 or a pre-`45a231f` checkout, that list is six ops, not
twelve, and reflection/replication padding will decompose.

### 3.4 What the validator deliberately ignores

Three categories are skipped, and knowing which is the difference between trusting a clean
validation and over-trusting it.

> ✅ **VERIFIED** — `coreai_torch/_validate.py:39-70`:
>
> 1. **Everything in `_COMPOSITE_OPS`** — *"Skip composite ops — these are intentionally preserved."*
> 2. **Five assertion ops** that `preprocess_graph()` strips before conversion:
>    ```python
>    assertion_targets = {
>        str(torch.ops.aten._assert_async.msg),
>        str(torch.ops.aten._assert_scalar.default),
>        str(torch.ops.aten.sym_constrain_range_for_size.default),
>        str(torch.ops.aten.sym_constrain_range.default),
>        str(torch.ops.aten._assert_tensor_metadata.default),
>    }
>    ```
> 3. **Every target that does not start with `aten.`** — *"Only check aten ops for unsupported
>    status."* Custom ops, `coreai::*` ops, `higher_order` ops and externalized-submodule call nodes
>    all pass through untouched.

> ⚠️ **Consequence you must design around.** Validation is an **ATen-only** check. If your model
> calls a custom `torch.library` op for which you have not registered a lowering, `add_exported_program`
> will accept it silently and you will not find out until `to_coreai()` — from a *different* error
> (§3.5). Same for a `higher_order` op that is not `cond` or `while_loop`.

Registering a user lowering suppresses the "unsupported" error for the op it covers — the validator
consults `self._user_defined_torch_lowering`, which is why the second argument exists
(`test_user_lowering_bypasses_unsupported_check`). This has an ordering implication that bites
people; see §7.5.

The `add_pytorch_module` path has one more failure mode in front of all of this, because it calls
your `export_fn` eagerly:

> ✅ **VERIFIED** — `coreai_torch/converter.py`, inside `add_pytorch_module`:
>
> ```python
> raise RuntimeError(
>     f"Your model failed to export: {e}\n"
>     f"Ensure the model is exportable via torch.export before "
>     f"passing it to TorchConverter.add_pytorch_module."
> ) from e
> ```
>
> If you see this, the problem is upstream of Core AI entirely. Fix `torch.export.export(model, …)`
> in isolation first.

### 3.5 Error C — the one that is not from the validator

There is a third error with a *different message*, raised from a *different file*, at a *different
time*:

> ✅ **VERIFIED** — `coreai_torch/converter.py:696-701`, inside `_handle_call_function_op`:
>
> ```python
> elif namespace is None or namespace == "aten":
>     if target not in _aten_to_core_resolver:
>         raise ValueError(
>             f"Unsupported ATen op: {target}. "
>             f"Use register_torch_lowering() to provide a custom lowering."
>         )
> ```

Compare the two:

| | Validator (§3.2, §3.4) | Lowering dispatch (§3.5) |
|---|---|---|
| Message | `The exported program contains unsupported ATen ops: aten.foo.bar` | `Unsupported ATen op: foo.bar` |
| Fires at | `add_exported_program()` / `add_pytorch_module()` | `to_coreai()` |
| Names | **All** offending ops, sorted and de-duplicated | The **first** one hit, in graph order |
| Prefix | Full FX target, with `aten.` | Resolver key, **without** `aten.` |
| Sees | Only the top-level staged graph | Every graph, including externalized submodule bodies |

The last row is the one that matters. **The validator does not walk externalized submodule graphs**,
which are exported separately in phase 3 of the externalization pipeline (§8.3). So a model whose
top level validates cleanly can still fail at `to_coreai()` with the short-form message coming from
inside an externalized block. If you get `Unsupported ATen op:` with no "The exported program
contains" prefix, look inside your composites, not at your top-level graph.

> 🔴 **GAP** — whether `validate_exported_program` is ever invoked on the re-exported whole-program
> graph in the `externalize_modules` path (phase 1 re-export) is **not verified**. Reading
> `converter.py`, `add_pytorch_module` validates the program returned by your `export_fn` *before*
> externalization marking, and `_run_externalize_pipeline` re-exports afterwards; whether that second
> program is re-validated was not traced end-to-end in this session. **Safe default meanwhile:**
> treat the `to_coreai()`-time message as the authoritative one for externalized models, and do not
> conclude from a clean `add_pytorch_module()` that your submodules are convertible. Resolving this
> needs a read of `_run_externalize_pipeline` in `converter.py` with the `externalize_modules`
> argument non-empty.

---

## 4. Diagnosing an overload mismatch

You have the error. It names ops. The documentation says those ops are supported. Here is the
procedure that resolves it in about two minutes.

### 4.1 Step 1 — get the exact target strings out of your graph

The error already gives you the FX target string, but you usually want the whole inventory, not one
op, and you want it *before* you stage the program.

```python
"""Inventory the exact FX target strings in an ExportedProgram, with counts.

Run this on the decomposed program — the one you are about to hand to the converter.
It answers the only question that matters: which qualified names, exactly, are in
this graph.
"""
from collections import Counter

import torch


def graph_targets(ep: torch.export.ExportedProgram) -> Counter:
    counts: Counter = Counter()
    for node in ep.graph.nodes:
        if node.op != "call_function":
            continue
        target = node.target
        # Same rule the converter uses: __name__ for callables, str() otherwise.
        name = target.__name__ if callable(target) else str(target)
        namespace = str(target.namespace) if hasattr(target, "namespace") else None
        counts[f"{namespace}::{name}"] += 1
    return counts


ep = torch.export.export(model.eval(), args=example_inputs)
ep = ep.run_decompositions(coreai_torch.get_decomp_table())

for qualified, n in sorted(graph_targets(ep).items()):
    print(f"{n:5d}  {qualified}")
```

This mirrors `get_target` / `get_namespace` from `coreai_torch/_utils.py:417-426` exactly, so the
strings it prints are the strings the dispatcher will look up. Output looks like:

```
    1  None::getitem
   52  aten::add.Tensor
   17  aten::cat.default
    1  aten::mean.names_dim          <- the culprit
   34  aten::mul.Tensor
    8  aten::scaled_dot_product_attention.default
```

### 4.2 Step 2 — diff against the registry, not against the docs

```python
"""Which of my graph's aten ops are actually registered? Registry, not docs."""
from coreai_torch._aten_to_core import _aten_to_core_resolver  # private; diagnostic only

missing = []
for qualified in graph_targets(ep):
    namespace, _, name = qualified.partition("::")
    if namespace not in ("aten", "None"):
        continue                      # custom / higher-order: validator ignores these too
    if name not in _aten_to_core_resolver:
        siblings = sorted(
            k for k in _aten_to_core_resolver if k.split(".")[0] == name.split(".")[0]
        )
        missing.append((name, siblings))

for name, siblings in missing:
    if siblings:
        print(f"OVERLOAD MISMATCH  {name}  -> registry has: {siblings}")
    else:
        print(f"GENUINELY UNSUPPORTED  {name}  -> no overload of this op is registered")
```

The two output lines are the two diagnoses, and they have completely different fixes:

- **`OVERLOAD MISMATCH`** — the op is supported. You produced the wrong overload. Fix the
  decomposition path (§4.3) or register the overload you have (§4.4).
- **`GENUINELY UNSUPPORTED`** — nothing named `foo` is in the registry. You need a real lowering
  (§7), a model change, or an upstream contribution.

`coreai-torch`'s `CONTRIBUTING.md` is explicit that the second case is welcome upstream:

> ✅ **VERIFIED** — `CONTRIBUTING.md`, "In scope": *"Support for missing ops or layer types via
> existing conversion mechanisms (e.g. adding an entry to the ATen-to-Core resolver, fixing a
> numerical mismatch in an existing lowering)"*. And out of scope: *"Major new conversion features or
> architectural changes"*, *"Changes to the core API surface"* — because *"We keep the API surface
> intentionally limited to ensure reliability and maintainability across PyTorch releases."*
> Note two process gates from the PR threads: contributions need **tests that fail without the
> change**, and commits need **verified signatures** to be mergeable.

### 4.3 Step 3a — change the decomposition path

Four levers, in the order you should try them:

| Lever | When | How |
|---|---|---|
| **Use `get_decomp_table()`** | You are passing the raw default, or nothing | `ep.run_decompositions(coreai_torch.get_decomp_table())` |
| **Preserve one more op** | A composite you want kept is being shredded | `t = get_decomp_table(); t.pop(torch.ops.aten.foo.default, None)` — the table is a fresh mutable copy |
| **Decompose one more op** | You are holding an overload with no lowering, but its decomposition is all supported ops | Do *not* pop it, or add it back from `torch.export.default_decompositions()` |
| **Change the call site** | The overload is chosen by argument types | `x / 2` → `x / torch.tensor(2.0)` moves `div.Scalar` to `div.Tensor`; `x.sum(dim=[0])` produces `sum.dim_IntList`, `x.sum()` may not |

The second lever is the one people miss. `get_decomp_table()` returns a plain `dict` that is yours
to modify:

```python
import torch
import coreai_torch

table = coreai_torch.get_decomp_table()

# Preserve one more op through decomposition (keep it whole in the graph).
# Only do this if you have a lowering for it — otherwise you have just created
# an "unsupported ATen ops" error for yourself.
table.pop(torch.ops.aten.my_composite.default, None)

ep = ep.run_decompositions(table)
```

`coreai-torch`'s own test helper exposes exactly this as a parameter — `validate_numerical_output(…,
remove_decomps=[…])` — which is a good signal that per-model table surgery is an expected workflow,
not a hack.

### 4.4 Step 3b — register the overload you actually have

If the decomposition path is not yours to change (a third-party model, a pinned torch version), you
can point the missing overload at the existing handler. This is the cheapest possible custom
lowering, because you are not writing one — you are reusing the one that already exists:

```python
"""Register a missing overload by delegating to the handler for a sibling overload.

VERIFY THE SEMANTICS FIRST. Two overloads of the same op are not always
interchangeable — `div.Tensor` and `div.Tensor_mode` differ by a rounding-mode
argument, and delegating one to the other would silently drop it.
"""
from coreai_torch import TorchConverter
from coreai_torch._aten_to_core import _aten_to_core_resolver  # private

converter = TorchConverter()

# Example shape only: the registry has `mean.dim`; suppose your graph has a
# semantically identical overload the registry does not list.
sibling = _aten_to_core_resolver["mean.dim"]


@converter.register_torch_lowering("aten::mean.some_other_overload")
def _lower_mean_other(values_map, node, loc):
    return sibling(values_map, node, loc)
```

Three things make this safe or unsafe:

1. **The handler signature is uniform.** Every resolver entry is
   `(values_map, node, loc) -> Value | list[Value]`, so delegation compiles. See §7.1.
2. **The handler reads `node.args` positionally.** If your overload has a different argument order
   or arity, the delegate will read the wrong thing — and it will usually still produce a
   correctly-shaped tensor. That is class 4.
3. **`allow_override` is not needed here**, because you are registering a key that is *absent* from
   the reserved resolver. It is only needed when you replace something that exists (§7.3).

### 4.5 The failure-shape table

Symptoms seen in the wild, mapped to class:

| What you observe | Class | Note |
|---|---|---|
| Error names an op that is in the docs table | 2 | Compare overloads with §4.2 |
| Error appears only when you add `dynamic_shapes=` | 2 | SymInt paths produce bare-packet targets; see PR #13 |
| Error appears only after a torch upgrade | 2 or 3 | The default decomposition table shipped with torch changed |
| Error names `_native_batch_norm_legit` | 3 → 2 | You decomposed too much; use `get_decomp_table()` |
| Error names `aten.linear` | 3 | `run_decompositions()` was never called |
| `Unsupported ATen op:` with no "exported program contains" prefix | 1 or 2, **inside an externalized submodule** | §3.5 |
| Converts fine, `save_asset()` raises `failed to persist mlasset` | 4 | A lowering emitted dynamic types where static were required — this was the shape of PR #40's conv-transpose bug |
| Converts fine, numbers wrong | 4 | §9, §10 |

---

## 5. Composite ops: a library you author models from

### 5.1 What a composite op is, in the IR

A composite op is a **`coreai.graph` with a `composite_decl` attribute**, invoked from the parent
graph. The body is a real, fully-lowered implementation — not a stub — and the declaration is a hint
that lets the compiler pattern-match a hardware-optimised kernel, falling back to the generic body
when it cannot.

> ✅ **VERIFIED** — `docs/guides/externalization.ipynb`, cell 1, the emitted IR for a model whose
> `forward` is `linear(norm(x))` with `norm` externalized as a composite:
>
> ```llvm
> module {
>   coreai.graph private noinline @norm.rms_norm(
>       %arg0: tensor<1x10xf32> {coreai.name = "input"},
>       %arg1: tensor<10xf32> {coreai.name = "scale"}
>   ) -> tensor<1x10xf32> attributes {
>       composite_decl = #coreai.composite_declaration<"rms_norm" = {
>           input_names = ["input", "scale"],
>           op_attrs = {axes = -1 : si64, eps = 9.99999974E-6 : f32, version = 1 : si64},
>           output_names = ["output"]}>
>   } {
>     // ... rms-norm body ...
>     coreai.output %15 : tensor<1x10xf32>
>   }
>   coreai.graph @main(%arg0: tensor<1x10xf32>) -> tensor<1x5xf32> {
>     %3 = coreai.invoke @norm.rms_norm(%arg0, %0)
>         : (tensor<1x10xf32>, tensor<10xf32>) -> tensor<1x10xf32>
>     coreai.output %7 : tensor<1x5xf32>
>   }
> }
> ```
>
> Note `private noinline` and the `composite_decl` attribute. Compare **simple externalization**,
> same cell, which produces `coreai.graph noinline @norm(...)` with **no** `composite_decl` — *"the
> compiler sees an opaque subgraph rather than a named op."*

Three properties fall out of that IR and are worth holding onto:

1. **`noinline` is what preserves the boundary.** `AIProgram.optimize()` inlines non-`noinline`
   graphs; a composite survives it.
2. **Attributes are `op_attrs`, not inputs.** `eps` is `9.99999974E-6 : f32` inside the declaration,
   not a graph argument. That is why `composite_attrs` exists and why scalars must be instance
   attributes, not `forward` parameters (§8.4).
3. **`version` is always present.** `generate_composite_decl` injects it (§7.6). Every composite in
   the package is `v1`; there is no v2.

> ✅ **VERIFIED** — `coreai_torch/composite_ops/_utils.py`: `class Version(enum.Enum): v1 = 1`, and
> every composite module sets `self.version = Version.v1`. `rope()` and
> `scaled_dot_product_attention()` raise `NotImplementedError` for any other version.

### 5.2 The full inventory — fifteen documented composites, two categories

> ✅ **VERIFIED** — `docs/api/composite-ops.md`, verbatim on the split:
> - *"**Module-class composite ops** — `nn.Module` subclasses you build into your model and
>   externalize with an `ExternalizeSpec`. Pass them (or `ExternalizeSpec` objects) to the
>   `externalize_modules` parameter of `add_pytorch_module()` to trigger externalization."*
> - *"**ATen-derived composite ops** — recognized automatically from the ATen nodes in your
>   `ExportedProgram` during conversion. These have no corresponding `nn.Module` wrapper; use the
>   standard PyTorch APIs (e.g., `torch.nn.BatchNorm2d`, `torch.nn.functional.pixel_shuffle`) and
>   Core AI preserves them as composite ops."*

The documentation directory `docs/api/composite-ops/` contains fifteen pages. Two of them
(`module-class`, `aten-derived`) are the category index pages; the other thirteen are ops:

| Doc page | Category | Composite name in IR | How you get it |
|---|---|---|---|
| `gather-mm` | module-class | `gather_mm` | `composite_ops.GatherMM` + spec |
| `gated-delta-update` | module-class | `gated_delta_update` | `composite_ops.GatedDeltaUpdate` + spec |
| `rms-norm` | module-class | `rms_norm` | `composite_ops.RMSNormImpl` + spec |
| `rope` | module-class | `rope` | `composite_ops.RoPE` + spec |
| `sdpa` | module-class | `scaled_dot_product_attention` | `composite_ops.SDPA` + spec |
| `batch-norm` | ATen-derived | `batch_norm` | `aten._native_batch_norm_legit_no_training` |
| `group-norm` | ATen-derived | `group_norm` | `aten.native_group_norm` |
| `hard-sigmoid` | ATen-derived | `hard_sigmoid` | `aten.hardsigmoid` |
| `instance-norm` | ATen-derived | `instance_norm` | `aten.instance_norm` |
| `layer-norm` | ATen-derived | `layer_norm` | `aten.native_layer_norm` |
| `linalg-vector-norm` | ATen-derived | `linalg_vector_norm` | `aten.linalg_vector_norm` |
| `log-softmax` | ATen-derived | `log_softmax` | `aten._log_softmax` |
| `pixel-shuffle` | ATen-derived | `pixel_shuffle` | `aten.pixel_shuffle` |

Plus one that has a lowering but no doc page of its own: `scaled_dot_product_attention` **also**
arrives via the ATen path (§5.5), and `avg_pool2d.default` / `avg_pool3d.default` are annotated in
the ops table as *"Lowered as a composite op"* without a dedicated page.

The public import surface is exactly five names:

> ✅ **VERIFIED** — `coreai_torch/composite_ops/__init__.py`:
>
> ```python
> from ._gated_delta_update import GatedDeltaUpdate
> from ._gather_mm import GatherMM
> from ._rms_norm import RMSNorm, RMSNormImpl
> from ._rope import RoPE
> from ._sdpa import SDPA
>
> __all__ = ["GatherMM", "GatedDeltaUpdate", "RMSNorm", "RMSNormImpl", "RoPE", "SDPA"]
> ```
>
> Six exported symbols, five composite targets — `RMSNorm` is a wrapper, not a target (§5.6).

### 5.3 ATen-derived composites: the attribute schemas

You get these for free by writing normal PyTorch, provided the op survives decomposition. The
attribute set is what the compiler matches on, so it is worth knowing:

| Composite | Inputs | Attributes |
|---|---|---|
| `batch_norm` | `input`, `gamma`, `beta`, `mean`, `variance` | `eps`, `version` |
| `group_norm` | `input`, `weight`, `bias` | `num_groups`, `num_channels`, `eps`, `version` |
| `layer_norm` | `input`, `gamma`, `beta` | `axes`, `eps`, `version` |
| `instance_norm` | `input`, `gamma`, `beta` | `eps`, `version` |
| `hard_sigmoid` | `input` | `version` |
| `log_softmax` | `input` | `axis`, `version` |
| `linalg_vector_norm` | `input` | `ord`, `axes`, `keep_dim`, `version` |
| `pixel_shuffle` | `input` | `upscale_factor`, `version` |

All ✅ VERIFIED from the corresponding `docs/api/composite-ops/*.md` pages. Two details from those
pages that reliably surprise people:

> ✅ **VERIFIED** — `batch-norm.md`: *"The mean and variance are pre-computed running statistics
> passed in as inputs; **`momentum` (a training-only construct) is dropped during conversion**."*
> The ATen source is `aten._native_batch_norm_legit_no_training` — the **inference path only**. A
> model left in training mode does not produce this op. This is the concrete reason
> `coreai-torch`'s quickstart says *"**Always call `.eval()` before exporting.** Layers such as
> `BatchNorm` and `Dropout` behave differently in training mode and produce a different graph."*

> ✅ **VERIFIED** — `linalg-vector-norm.md` carries an inline naming warning in its own example:
> *"Note: the PyTorch arg is `dim`; Core AI's IR attribute is `axes`"*. The same rename applies to
> `layer_norm`. When you read IR or write `composite_attrs`, the Core AI spelling is `axes`.

> ⚠️ **SILENT FAILURE — `instance_norm` only becomes a composite when it uses input statistics.**
> `replace_instance_norm` in `_aten_to_core.py` emits the composite **only when `use_input_stats`
> (`node.args[5]`) is truthy**; otherwise it inlines running-stat normalisation. Both paths produce
> correct numbers, so nothing fails — you just quietly lose the composite and whatever optimised
> kernel it would have selected, with no diagnostic. Check with `freqop` (§10.4): a
> `composite.instance_norm` row present means you got it, absent means you did not.

### 5.4 Module-class composites: the three-step pattern

For the five module-class composites the shape is always the same:

1. Use the provided class as a **named submodule** in your model — **not as the root module**.
2. Convert via **`add_pytorch_module`**. `add_exported_program` has no externalization.
3. Pass an `ExternalizeSpec` with `composite_op_name` and `composite_attrs`.

A complete, copyable example — an RMSNorm block, from the pieces the package documents:

```python
"""Module-class composite: RMSNormImpl externalized as `rms_norm`.

coreai-torch 0.4.1. Requires macOS + Apple silicon to run the result.
"""

import torch
import torch.nn as nn

import coreai_torch
from coreai_torch import ExternalizeSpec, TorchConverter
from coreai_torch.composite_ops import RMSNormImpl


class Block(nn.Module):
    def __init__(self, dim: int = 16, eps: float = 1e-5) -> None:
        super().__init__()
        # The caller owns the scale. RMSNormImpl takes it as a forward argument so
        # that it lands on the composite boundary as a graph input rather than
        # being baked in as a constant.
        self.weight = nn.Parameter(torch.ones(dim))
        self.norm = RMSNormImpl(eps=eps)      # named submodule, NOT the root
        self.proj = nn.Linear(dim, dim // 2)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.proj(self.norm(x, self.weight))


model = Block().eval()
sample = (torch.randn(1, 16),)

converter = TorchConverter().add_pytorch_module(          # NOT add_exported_program
    model,
    export_fn=lambda m: torch.export.export(m, args=sample).run_decompositions(
        coreai_torch.get_decomp_table()
    ),
    externalize_modules=[
        ExternalizeSpec(
            target_class=RMSNormImpl,                     # the Impl, not the wrapper
            composite_op_name="rms_norm",
            composite_attrs=["axes", "eps"],              # instance attribute names
        )
    ],
    input_names=["x"],
    output_names=["y"],
)
coreai_program = converter.to_coreai()
coreai_program.optimize()

# The composite survives optimize() because it is `noinline`.
assert 'composite_declaration<"rms_norm"' in str(coreai_program)
```

> ✅ **VERIFIED** — `docs/guides/composite-ops.ipynb`, tip: *"`composite_attrs` must match actual
> instance attribute names on the target class (e.g., `self.eps`, `self.axes`)."* `RMSNormImpl` sets
> `self.eps` and `self.axes = -1` in `__init__`, which is why `["axes", "eps"]` is the right list.

> ⚠️ **SILENT FAILURE — a typo in `composite_attrs` or `target_class` warns, it does not raise.**
> An unmatched `target_class` produces a `UserWarning` and the model converts *without* the
> composite (§8.7). If you ship with `warnings` filtered — which many training/export scripts do —
> you get a slower model and no signal at all. Assert on the IR, as the example above does.

### 5.5 ⚠️ SDPA: two paths, one name, different attributes

Attention reaches the IR by two completely different routes, and they do not produce the same thing.

**Route A — the ATen path.** You write `torch.nn.functional.scaled_dot_product_attention`, and
`get_decomp_table()` preserves `aten.scaled_dot_product_attention.default`, and
`replace_sdpa` in `_aten_to_core.py` builds the composite.

**Route B — the module path.** You use `coreai_torch.composite_ops.SDPA` as a submodule and
externalize it.

Both emit a composite named `scaled_dot_product_attention`. Here is what differs:

| | Route A (`aten` path) | Route B (`composite_ops.SDPA`) |
|---|---|---|
| `is_causal` in `op_attrs` | **always `False`** | the real value |
| `window_size` in `op_attrs` | **always `0`** | the real value |
| How causality is expressed | a **materialised float mask** built outside the composite and passed as `attn_mask` | an attribute the compiler reads |
| Sliding window | not expressible | `window_size` attribute |
| Attention sinks | not expressible | `sinks` input |
| Causal mask geometry | PyTorch's **upper-left** | **lower-right** |

> ✅ **VERIFIED** — `_aten_to_core.py`, `replace_sdpa`. `is_causal=True` is implemented by building
> a float mask outside the composite and passing it as `attn_mask` — the source comment is *"The
> composite interface is always mask-based."* Masked positions get **`-1e4`, not `-inf`**
> (`_sdpa_build_causal_mask` → `neg_large = coreai.constant(-1e4, dtype=ele_type)`). The emitted
> attributes are literally:
>
> ```python
> op_attributes: dict[str, Any] = {"is_causal": False, "window_size": 0, "version": 1}
> if scale is not None:
>     op_attributes["scale"] = scale
> ```

> ⚠️ **SILENT FAILURE — the causal-mask convention differs between the two routes.**
> ✅ VERIFIED, `coreai_torch/composite_ops/_sdpa.py:19-44`, the `CausalVariant` docstring:
> *"When query length = key length, causal mask is simply a square lower triangular True matrix, and
> this enum has no effect. When query length != key length, causal mask can be considered as a slice
> of that square matrix."* — and the default is
> `causal_variant: CausalVariant = CausalVariant.lower_right`, with the source comment
> *"lower-right causal mask, i.e. query being the trailing tokens, is what we need for decoding,
> where when `q_len != k_len` we have query being the latest token in sequence."*
>
> `torch.nn.functional.scaled_dot_product_attention`'s `is_causal=True` is **upper-left**. The two
> agree whenever `q_len == k_len` and disagree **on every decode step**, where `q_len == 1` and
> `k_len` is the cache length. A model that passes its parity test on a full-sequence forward pass
> can therefore be wrong the moment you run it autoregressively — same code, same weights, correct
> shapes, different mask. If you swap `F.scaled_dot_product_attention(…, is_causal=True)` for
> `composite_ops.SDPA(is_causal=True)`, re-validate **at decode length**, not just at prefill length.

Two more SDPA facts worth carrying:

> ✅ **VERIFIED** — `docs/api/composite-ops/sdpa.md`: *"For GQA / MQA, do **not** pre-tile `key` /
> `value` to match `N_q` — pass them with their native `N_kv` and the broadcasting is recorded as
> part of the composite op."* Schemas: MHA (`N_q == N_kv`), GQA (`N_q > N_kv`, `N_q % N_kv == 0`),
> MQA (`N_kv == 1`). Shapes `query [B, N_q, T_q, D]`, `key [B, N_kv, T_kv, D]`,
> `value [B, N_kv, T_kv, D_v]`.

> ✅ **VERIFIED** — `_sdpa.py` contains `_vanilla_repeat_interleave`, which exists because
> *"PyTorch official `torch.repeat_interleave` has dynamic shape bug starting from torch 2.8 and
> still fails at torch 2.10"*. It uses `torch.index_select(x, 1, arange(num_heads).repeat_interleave(reps))`
> instead. If you hand-roll GQA head expansion with `repeat_interleave` in a dynamic-shape export,
> that is a known-broken construct — use `index_select`.

### 5.6 ⚠️ `RMSNormImpl`, not `RMSNorm`

`coreai_torch.composite_ops` exports both. Only one is an externalization target.

> ✅ **VERIFIED** — `docs/api/composite-ops/rms-norm.md`: *"`RMSNormImpl` **is the true composite
> op** — the class the converter externalizes as `rms_norm`. It takes both the input `x` and the
> scale `γ` as explicit forward arguments so that, when externalized, the scale appears as a graph
> input on the composite op boundary rather than being baked in as a constant from a sibling
> parameter."* And on the wrapper: *"`RMSNorm` is a thin `nn.Module` wrapper around `RMSNormImpl`
> that owns the learnable scale parameter so callers don't have to wire one up themselves."*
>
> `docs/guides/conversion-workflows.ipynb` states the trap directly: *"`coreai_torch.composite_ops`
> ships convenience wrappers like `RMSNorm` … but **`target_class` in the `ExternalizeSpec` must
> still be `RMSNormImpl`** (the inner module the converter recognizes as the `rms_norm` composite
> op)."*

Because `RMSNorm` *contains* an `RMSNormImpl`, using the wrapper in your model and specifying
`target_class=RMSNormImpl` works fine — the `isinstance` walk finds the inner module. What does not
work is `target_class=RMSNorm`: no submodule is an instance of it that the converter treats as the
composite, you get the unmatched-class `UserWarning`, and you ship without the composite.

`RMSNormImpl` also does something numerically deliberate that you should not "simplify":

> ✅ **VERIFIED** — `coreai_torch/composite_ops/_rms_norm.py`, with its own comments:
>
> ```python
> def forward(self, input: torch.Tensor, scale: torch.Tensor) -> torch.Tensor:
>     # need f32, otherwise square may overflow f16 max 65504
>     input_f32 = input.to(torch.float32)
>     square_f32 = input_f32 * input_f32
>     # need f32, otherwise accumulation may ignore small values
>     mean_square_f32 = square_f32.mean(self.axes, keepdim=True)
>     inv_rms_f32 = torch.rsqrt(mean_square_f32 + self.eps)
>     input_normalized = input * inv_rms_f32
>     # for the gemma3 case, the scale is always fp32, and hence we
>     # do the down cast in the end
>     if scale.dtype != input.dtype and scale.dtype == torch.float32:
>         return (input_normalized * scale).to(input.dtype)
>     return input_normalized.to(input.dtype) * scale
> ```
>
> Two fp16 hazards handled explicitly (overflow of `x²` past 65504, and small-value loss in the
> accumulation) plus a Gemma3-shaped special case for an fp32 scale on an fp16 input. This is the
> reference for how *your* norms should be written; §9.1 is what happens when an op does not do this.

### 5.7 ⚠️ RoPE: fp32 is mandatory, and the partial-rotary pairing is a trap

> ✅ **VERIFIED** — `coreai_torch/composite_ops/_rope.py:26-30`, two hard `torch._check`s:
>
> ```python
> torch._check(
>     position_ids.dtype == torch.float32,
>     message="position_ids needs to be in fp32",
> )
> torch._check(freqs.dtype == torch.float32, message="freqs needs to be in fp32")
> ```
>
> and `rotation_dims` must be `>= 2` and even
> (`torch._check(rotation_dims % 2 == 0, message="rotation dimension divisible by 2")`).
> The source comment on why fp32 is non-negotiable: *"in practice f16 gives wrong generated text…
> even if half_dim = 64 = 2^6 — anyway, observation is always correct :p let us just stick to f32"*.

The resolution order is documented and worth memorising, because passing a redundant argument
silently does nothing:

> ✅ **VERIFIED** — `docs/api/composite-ops/rope.md`: *"1. If `cos` and `sin` are both provided, use
> them directly. 2. Else, build `cos`/`sin` from `position_ids` and `freqs`."* And on the arguments:
> *"`position_ids` … **Ignored if `cos` and `sin` are provided.**"*, *"`freqs` … **Ignored if `cos`
> and `sin` are provided.**"*, and for `offset`: *"If a tensor is provided alongside the int
> attribute, **the tensor wins**."*

> ⚠️ **SILENT FAILURE — partial-rotary RoPE pairs the wrong dimensions.** Community-reported
> (`apple/coreai-models` issue **#66**, author `kylejfrost`, 2026-07, acknowledged by maintainer
> @stikves as *"a known issue"*), verbatim:
>
> > *"The composite `RoPE` partial-rotary mode (`dims < head_dim`) pairs dimensions in a **contiguous
> > block** (dim `i` ↔ `i + dims/2`, *inside* the first `dims` dims, passing the rest through).
> > HuggingFace `transformers`' **partial / 'proportional' rotary** (any model with
> > `partial_rotary_factor < 1`) instead pairs across the **full head_dim half-split** (dim `i` ↔
> > `i + head_dim/2`), with only the first `rope_angles` frequencies non-zero (`inv_freq`
> > zero-padded). The **frequencies are identical; only the dim pairing differs**, so the result is
> > silently wrong."*
>
> Community-measured, single reporter, uncontrolled conditions: full-rotary (sliding) layers came
> out bit-exact (PSNR ∞); the global partial-rotary layer measured **PSNR ≈ 21.6 dB, max-abs ≈ 8.2**
> on gemma-4-26B-A4B (`head_dim=512`, `partial_rotary_factor=0.25`). The reporter's framing of why
> this is nasty: *"Generation stays coherent (global layers are ~1/6 of the stack), so it passes a
> smoke test — but it isn't faithful to the reference, and it **breaks EAGLE/MTP speculative-draft
> acceptance**."*
>
> **Apple's stated workaround** (@stikves, verbatim): *"currently the workaround is **pre-computing
> the sine/cosine tables** for RoPE embeddings"* — i.e. compute `cos`/`sin` yourself against the
> reference convention and pass them in, which takes resolution rule 1 and bypasses the internal
> pairing entirely. **Safe default:** if your model has `partial_rotary_factor < 1`, precompute
> `cos`/`sin`; if it does not, the composite's own path is fine.
>
> Second-order hazard from the same thread: *"If `inv_freq` is stored as a **registered buffer**,
> `model.to(bfloat16)` downcasts it and bf16's ~3-digit mantissa corrupts the frequencies (cos error
> ≈ 0.35 at position 200). Recomputing `inv_freq` in fp32 inside `forward` avoids it."*

---

## 6. The unadvertised capability: first-class MoE and SSM

Two of the five module-class composites are not general-purpose primitives. They are named
architectural building blocks for two model families that dominated 2025–26 research, and neither
WWDC26 session 325 nor the `coreai-torch` README says so out loud. Read the doc pages and it is
unmistakable.

### 6.1 `gather_mm` is Mixture-of-Experts expert dispatch

> ✅ **VERIFIED** — `docs/api/composite-ops/gather-mm.md`, opening paragraph, verbatim:
> *"Gather matmul — optionally gathers rows from one or both operands before performing the matrix
> multiplication … **The primary use case is Mixture-of-Experts (MoE): each token selects a subset of
> expert weight matrices and the result is computed in a single fused operation. Without `GatherMM`,
> you would explicitly gather the relevant expert weights and then run a matmul; this op fuses both
> for better performance.**"*
>
> The doc's own argument table is written in MoE vocabulary: `lhs` — *"MoE: the input hidden-state
> tensor"*; `rhs` — *"MoE: the stacked expert weight matrices"*; `rhs_indices` — *"MoE: the
> active-experts indices"*; `lhs_indices` — *"MoE: typically `None`"*.

The complete MoE example from that page, verbatim, is a working expert-dispatch layer:

```python
class MoELayer(nn.Module):
    def __init__(self):
        super().__init__()
        self.gather_mm = GatherMM(num_batch_axes=0)

    def forward(
        self,
        x: torch.Tensor,          # [B, T, 1, 1, D]
        experts: torch.Tensor,    # [E, D, H]
        indices: torch.Tensor,    # [B, T, K]
    ) -> torch.Tensor:            # [B, T, K, 1, H]
        return self.gather_mm(x, experts, rhs_indices=indices)
```

and the fused gate+up variant, which is how every SwiGLU MoE block is actually shaped:

```python
class FusedMoELayer(nn.Module):
    def __init__(self):
        super().__init__()
        self.gather_mm = GatherMM(num_batch_axes=1)   # gather on the expert axis (dim 1)

    def forward(
        self,
        x: torch.Tensor,             # [B, T, 1, 1, D]
        fused_experts: torch.Tensor, # [2, E, D, H]  (gate + up stacked)
        indices: torch.Tensor,       # [B, T, K]
    ) -> torch.Tensor:               # [2, B, T, K, 1, H]
        return self.gather_mm(x, fused_experts, rhs_indices=indices)
```

Apple's own agent skill names the higher-level wrappers that sit on top of it:

> ✅ **VERIFIED** — `apple/coreai-models`,
> `skills/skills/model-authoring/references/gpu_rules.md`, "Mixture of Experts (MoE)" section,
> verbatim: *"For models with sparse expert routing (e.g. Qwen3-MoE, Mixtral), use the `GatherMM`
> composite op via `SwitchLinear`: **`SwitchLinear`**: A single weight tensor of shape
> `(num_weight_sets, num_experts, output_dims, input_dims)` holding all experts. At inference time,
> takes indices of selected experts and performs batched gather + matmul in one operation via
> `coreai_torch.composite_ops.GatherMM`. **`SwitchGLU`**: Combines three `SwitchLinear` layers (gate,
> up, down) with SwiGLU activation for MoE MLP blocks. **Routing**: Standard `nn.Linear` gate +
> softmax + top-k selection to choose active experts per token. Expert indices are typically cast to
> `uint16` before passing to GatherMM."*
>
> And the loading detail that trips everyone up: *"HuggingFace stores per-expert weights separately
> (e.g., `experts.0.gate_proj.weight`, `experts.1.gate_proj.weight`). At load time, stack them into
> the `(1, num_experts, out, in)` shape expected by `SwitchLinear`."*

> ⚠️ Note the dtype constraint, which is easy to get wrong because PyTorch will not complain.
> ✅ VERIFIED, `gather-mm.md` data-types table: `lhs_indices` / `rhs_indices` must be **unsigned
> integer index types (e.g. `uint16`, `uint32`)**. `torch.topk` returns `int64`. The composite's own
> reference decomposition contains `indices.to(torch.int32)` with the comment *"TODO: Remove this
> explicit cast once torch supports uint indices"* — so the eager path launders your dtype and the
> lowered path may not. Cast explicitly at the call site.

### 6.2 `gated_delta_update` is a linear-attention / state-space recurrence

> ✅ **VERIFIED** — `docs/api/composite-ops/gated-delta-update.md`, opening paragraph, verbatim:
> *"Gated Delta Network recurrence — **a linear-complexity alternative to softmax attention for
> sequence modeling. Used in modern efficient attention mechanisms like Delta Networks (Qwen3-Next)
> and other recurrent-style transformers.** Use this op when your model implements a **state-space or
> linear recurrence layer** that you want preserved as a single composite op in the lowered IR. The
> state tensor `S` is a key-value memory matrix that accumulates over timesteps; `initial_state` lets
> you pass a cached state for autoregressive generation or chunked processing."*
>
> The recurrence, from the same page:
>
> $$S_t = g_t \odot S_{t-1} + \beta_t \, k_t^\top \bigl(v_t - S_{t-1} k_t\bigr)$$
>
> Signature (verbatim): `forward(query [B, N_kq_heads, S, D_k], key [B, N_kq_heads, S, D_k],
> value [B, N_v_heads, S, D_v], g [B, N_v_heads, S], beta [B, N_v_heads, S],
> initial_state [B, N_v_heads, D_k, D_v]) -> (output [B, S, N_v_heads, D_v],
> final_state [B, N_v_heads, D_k, D_v])`.

Constraints that are not obvious from the shapes:

> ✅ **VERIFIED** — same page: *"`g` should be negative — the op applies `exp` internally and
> `exp(g)` must lie in `[0, 1]` for the decay to behave correctly."* · *"`beta` is typically in
> `[0, 1]` (often the output of a sigmoid)."* · *"Q and K have the same head count, unlike SDPA"* ·
> `use_qk_l2_norm=True` by default — *"Set it to `False` if your model already L2-normalizes Q/K
> externally."*

Put the two together and the conclusion is unavoidable, and it is the thing nobody said:

> **Core AI's IR has first-class Mixture-of-Experts *and* state-space / linear-attention support.**
> `gather_mm` is the MoE dispatch primitive; `gated_delta_update` is the Qwen3-Next-class recurrence.
> Both are named composites the compiler can pattern-match to a hardware kernel, both ship in the
> public package, and both are in Apple's own `_EXTERNALIZE_SPECS` list for macOS LLM export (§8.5).
> That is a materially different capability story from "Core AI converts PyTorch models."

Apple's own MoE work shows up as measured throughput:

> ✅ **VERIFIED (Apple-published)** — `apple/coreai-models` PR **#69**, *"[Qwen3-MoE] Optimize expert
> selection"* (merged): simplifying the path when `norm_topk_prob` is set moved **prompt 1066.4 →
> 1103.7 tok/s and generation 62.1 → 69.2 tok/s**. Hardware and OS build are **not stated in the PR**,
> so treat the absolute numbers as unanchored; the ~11% generation delta is the citable part.

### 6.3 ⚠️ How far that support does *not* extend

This is the part that will save you a month, so it gets more space than the good news.

**IR support is not runtime support.** The composite exists, the converter emits it, and the shipped
Swift LLM runtime refuses to run the resulting model.

> ✅ **VERIFIED** — `apple/coreai-models` issue **#118**, *"[Swift runtime] `CoreAISequentialEngine`
> rejects hybrid models with four persistent states"*. A 16 KB no-weights repro with the function
> contract `inputs: input_ids, position_ids · output: logits · states: keyCache, valueCache,
> convState, recState` fails at load with:
>
> ```text
> Expected 2 states (KV cache), got 4: states=["keyCache", "valueCache", "convState", "recState"], outputs=["logits"]
> ```
>
> Root cause is a `descriptor.stateNames.count == 2` guard. **Maintainer answer (@stikves),
> verbatim — the definitive statement:** *"Thanks for the report. **The check for only 2 states is
> deliberate. We currently do not have support for linear attention or similar hybrid state models.**
> Keeping this open for potential future changes."* Filed as FB23893830. Still open 2026-07-29.

**Prefix caching is forfeit for these architectures, and that is architectural, not a bug.**

> ✅ **VERIFIED** — `trimKVCache` returns `-1` (unsupported) whenever `extraStates` is non-empty.
> The reporter of #118 states the underlying reason cleanly: *"There is also a correctness issue with
> KV-only prefix rewind. **Recurrent state is a summary of the full prefix and cannot be rewound by
> changing a KV token cursor.** A safe implementation must replay the prompt or maintain recurrent
> checkpoints."*
>
> The cost is large. Community-measured on a Mac (qwen3-0.6b, byte-identical greedy output): turn-2
> TTFT **23.28 s → 0.230 s (101×)** at 4k context with prefix reuse, 15.2× at 357 tokens. Hybrid
> models pay full re-prefill every turn. **Model-selection consequence:** picking Qwen3.5, Qwen3.6,
> LFM2.5 or Granite 4 for an on-device chat feature trades away a 100× turn-2 latency win.

**`GatedDeltaUpdate` is implemented with a `while_loop`, which the accelerator runtimes do not run.**

> ✅ **VERIFIED** — `coreai_torch/composite_ops/_gated_delta_update.py`, with its own comment:
>
> ```python
> # Run the while loop: equivalent to for t in range(s).
> # query/key/value/g_exp/beta are passed as additional_inputs so they are
> # explicit graph inputs to the subgraph rather than closed-over tensors.
> _, state, output = torch.ops.higher_order.while_loop(
>     cond_fn, body_fn,
>     (torch.tensor(0, device=query.device), state, output),
>     (query, key, value, g_exp, beta),
> )
> ```
>
> Combined with `tests/conftest.py`'s auto-skip (§2.6) — *"Higher-order ops like `torch.cond` /
> `while_loop` are not yet supported by the cpu/gpu/neural_engine compute unit runtimes"* — this
> means the composite's own generic body is interpreter-only. It runs if the compiler pattern-matches
> the composite to a kernel; it does not run if the compiler falls back.

And the crash that follows from exactly that combination:

> ✅ **VERIFIED** — `coreai-torch` issue **#2** (open), author `scndls`. Crash:
> `EXC_BAD_ACCESS (code=1, address=0x0)` at
> `MetalPerformanceShadersGraph mlir::FloatType::getWidth() + 16`. The decision table, verbatim:
>
> | Model | Result |
> |---|---|
> | 1 `GatedDeltaUpdate` layer + 1 attention layer (dynamic context) | **runs** (exit 0) |
> | **2** `GatedDeltaUpdate` layers + 1 attention layer (dynamic context) | **EXC_BAD_ACCESS** at execute |
> | N stacked `GatedDeltaUpdate` layers, **no attention**, fully static export | runs (verified to N=3) |
>
> *"It is the **combination**: 2+ DeltaNet `scf.while` scans plus a dynamic KV-context dimension in
> the same exported function."* Also in the thread: with one layer the run prints
> `ANECCompile() FAILED ... MLIR MPS to ANEC conversion failed` on the first execute — **and the
> runtime falls back and the call still completes (exit 0)**. A compile failure you only see in the
> log, not in the return value.

**The escape route (static export) is blocked by a third bug.** This is the trap that makes hybrid
models genuinely hard right now, and the reporter mapped it out precisely:

> ✅ **VERIFIED** — `coreai-torch` issue **#6** (open), verbatim: *"This is the third member of a bug
> family that currently blocks the natural export paths for hybrid DeltaNet models (Qwen3.5/3.6,
> Qwen3-Next): dynamic context dims trip #1 (SDPA externalize re-export) and #2 (MPSGraph
> `FloatType::getWidth()` null-deref), so the model must be exported **fully static**. But a static
> stateful decode function then needs its KV write position as a **runtime value** — which this crash
> forbids."* The crash is `EXC_BAD_ACCESS` in
> `ANECompiler mlir::anecir::ANECPlistInterface::addOpToNetwork` at `AIModel.load`, and it fires
> exactly when the slice-update `begin`/`end` are computed from an input tensor's values rather than
> being compile-time constants.
>
> **The reporter's working escape hatch, and the one to copy:** a **sliding-window KV cache** —
> *"every call shifts the cached window left by the static query length and appends the new chunk at
> the end so all slice indices stay constant; a host-built attention mask encodes
> validity/causality."* Costs a full cache rewrite per step; matched eager to rel err ≤ 5e-4 across
> stepped calls. A related crash (`coreai-models#5`) with the same root shape was reported by a
> maintainer as *"**should be fixed in macOS / Xcode beta 4**"* — unconfirmed by the reporter as of
> 2026-07-29.

**Summary you can act on:**

| Layer | MoE (`gather_mm`) | SSM / linear attention (`gated_delta_update`) |
|---|---|---|
| Composite in the IR | ✅ shipped, documented | ✅ shipped, documented |
| In Apple's `_EXTERNALIZE_SPECS` | ✅ yes | ✅ yes |
| Apple ships a working model using it | ✅ Qwen3-MoE, Mixtral, GPT-OSS | ❌ none — spec only |
| Runs on GPU/ANE delegates | ✅ (Qwen3-MoE ships) | ⚠️ see #2 — combination-dependent |
| Swift `CoreAISequentialEngine` accepts it | ✅ (2 states) | ❌ hard-rejected, deliberately (#118) |
| Prefix caching / `trimKVCache` | ✅ | ❌ returns `-1` |

The asymmetry between the two is visible in Apple's own repository, and it is stark:

> ✅ **VERIFIED** — grep of `apple/coreai-models/python/src/` this session.
> **`GatherMM` is used for real**: `primitives/macos/switch.py:22` —
> `self.gather_mm = coreai_torch.composite_ops.GatherMM(num_batch_axes=1)` inside `SwitchLinear`,
> consumed by `SwitchGLU`, consumed by **three shipping MoE model recipes**:
> `models/macos/qwen3_moe.py`, `models/macos/mixtral.py`, `models/macos/gpt_oss.py`.
> **`GatedDeltaUpdate` appears in exactly two lines of the entire repository** — its entry in
> `export/macos.py`'s `_EXTERNALIZE_SPECS` (lines 59–60). **No model recipe instantiates it.**
>
> So MoE is a fully-worked, shipped path with three reference implementations. SSM / linear
> attention is a composite with a spec and no reference model. **Safe default:** treat SSM/hybrid
> support as *IR-complete and runtime-incomplete*. If you need a hybrid model on device today, plan
> for a custom Swift runtime, not `CoreAILanguageModel`. Note also that `coreai-torch`'s own
> `tests/composite_ops/test_gated_delta_update.py` is marked `@pytest.mark.flaky(reruns=3)`.

---

## 7. Custom lowerings

### 7.1 The contract

> ✅ **VERIFIED** — `coreai_torch/converter.py:986-1034`, the real signature:
>
> ```python
> def register_torch_lowering(
>     self: Self,
>     qualified_name: str,
>     allow_override: Optional[bool] = False,
> ) -> Callable:
> ```
>
> and the callback shape, from `docs/guides/custom-op-lowering.ipynb` cell 7:
>
> ```python
> def lowering_func(
>     values_map: dict[str, Value],
>     node: torch.fx.Node,
>     loc: Location,
> ) -> Value | list[Value]:
>     ...
> ```
>
> Argument semantics, verbatim from the same cell:
>
> | Argument | Type | Description |
> |---|---|---|
> | `values_map` | `dict[str, Value]` | *"Maps FX node names to their CoreAI `Value`s. Use this to look up tensor operands."* |
> | `node` | `torch.fx.Node` | *"The FX node being lowered. **Tensor args are `fx.Node` objects; scalar args are plain Python values.**"* |
> | `loc` | `Location` | *"CoreAI Location. Pass to CoreAI op constructors."* |

Four rules that follow from the dispatcher's post-processing and are not obvious from the signature:

1. **Return a single `Value` or a list.** A list is stored under `"<node.name>#0"`, `"<node.name>#1"`,
   … which is exactly what downstream `getitem` nodes read.
2. **Your result is type-checked.** ✅ VERIFIED, `converter.py:728-738`: every returned value is
   passed to `check_result_type(op_result, val, node, i)` against `node.meta["val"]`. A shape or
   dtype mismatch fails at conversion, not at runtime. This is a genuinely useful guard rail — but
   note it checks *type*, never *value*, so an arithmetically wrong lowering of the right shape
   sails through.
3. **`get_operand` / `get_operands` do the boring work.** They resolve `fx.Node` args via
   `values_map` and turn scalars, tensors and mixed lists into constants.
   ✅ VERIFIED, `coreai_torch/_utils.py:987-1034`:
   `get_operand(values_map, node, idx, loc=None)` and
   `get_operands(values_map, node, indices, loc=None)`.
4. **`get_operand` promotes Python floats to fp16 in fp16 graphs.** ✅ VERIFIED, its own docstring:
   *"When arg is a Python float and every float tensor operand of the node is fp16, the scalar is
   promoted to an fp16 constant (provided no precision loss) to keep operand types consistent."*
   If you need a literal that must stay fp32 (a `1e-6` epsilon, say), do not route it through
   `get_operand` — build the constant yourself with an explicit dtype.

### 7.2 Worked example — lowering a custom torch op

The full four-step recipe, verbatim from `docs/guides/custom-op-lowering.ipynb` (cells 2, 4, 6, 8,
10), assembled into one runnable file:

```python
"""Custom torch op -> Core AI lowering. coreai-torch 0.4.1.

Four pieces: the op, the fake impl, the model, the lowering.
"""

import torch
import torch.nn as nn

from coreai._compiler.dialects import coreai      # PRIVATE upstream API — see the version-floor note
from coreai_torch import TorchConverter, get_decomp_table
from coreai_torch._utils import get_operands      # underscore-private, but used by Apple's own docs


# --- 1. Define the torch op ------------------------------------------------
@torch.library.custom_op("my_lib::scaled_add", mutates_args=())
def scaled_add(x: torch.Tensor, y: torch.Tensor, scale: float) -> torch.Tensor:
    """Eager implementation: runs on CPU during normal PyTorch inference."""
    return x + scale * y


@scaled_add.register_fake
def _(x: torch.Tensor, y: torch.Tensor, scale: float) -> torch.Tensor:
    """Abstract implementation: called by torch.export to infer output shapes."""
    return torch.empty_like(x)


# --- 2. Use it in a model --------------------------------------------------
class ScaledAddModel(nn.Module):
    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        return torch.ops.my_lib.scaled_add(x, y, 0.5)


# --- 3. Export -------------------------------------------------------------
model = ScaledAddModel().eval()
example_inputs = (torch.randn(4, 8), torch.randn(4, 8))

exported = torch.export.export(model, args=example_inputs)
exported = exported.run_decompositions(get_decomp_table())
# Custom ops are not touched by decomposition — `my_lib::scaled_add` survives as one node.


# --- 4. Register the lowering ---------------------------------------------
converter = TorchConverter()


@converter.register_torch_lowering("my_lib::scaled_add.default")
def lower_scaled_add(values_map, node, loc):
    x, y = get_operands(values_map, node, [0, 1], loc)
    scale = node.args[2]                      # plain Python float, NOT an fx.Node

    scale_val = coreai.constant(scale, dtype=x.type.element_type)
    scaled_y = coreai.broadcasting_mul(y, scale_val, loc=loc)
    return coreai.broadcasting_add(x, scaled_y, loc=loc)


coreai_program = converter.add_exported_program(
    exported,
    input_names=["x", "y"],
    output_names=["result"],
).to_coreai()
coreai_program.optimize()

print(str(coreai_program))    # AIProgram's __str__ prints the MLIR
```

> ✅ **VERIFIED** — the `.default` requirement, verbatim from cell 7: *"The op's qualified name in the
> FX graph **always carries the overload suffix `.default`**, so register it as
> `"my_lib::scaled_add.default"`."* And from the Notes section: *"Custom ops defined with
> `@custom_op` always use the `.default` overload."*

### 7.3 `allow_override=True` — replacing a built-in

The other half of the API. `register_torch_lowering` refuses to shadow a reserved-namespace op
unless you say so explicitly:

> ✅ **VERIFIED** — `coreai_torch/converter.py:1016-1029`:
>
> ```python
> if not allow_override:
>     _reserved = {
>         "aten": _aten_to_core_resolver,
>         "higher_order": _higher_order_resolver,
>         "coreai": _custom_to_core_resolver,
>         "coreaix": _custom_to_core_resolver,
>     }
>     resolver = _reserved.get(namespace)
>     if (resolver is not None and target in resolver) or (
>         qualified_name in self._user_defined_torch_lowering
>     ):
>         raise ValueError(
>             f"{qualified_name!r} is already registered; set allow_override=True to replace it"
>         )
> ```
>
> Note what the guard checks: the **exact overload key** must already be present. Registering
> `"aten::some_unlisted_overload"` needs no `allow_override` at all (§4.4), because the key is not
> there to collide with. And the docstring's own words for the flag: *"If `True`, **silently**
> replaces an existing lowering for the same op."*

Apple's documented use case for overriding is specialisation-under-known-constraints — you know
something about your deployment that the general lowering cannot assume:

> ✅ **VERIFIED** — `docs/guides/custom-op-lowering.ipynb`, cell 13, verbatim: *"To replace the
> built-in lowering for a standard ATen op, pass `allow_override=True`. This is useful when you know
> your model's runtime constraints allow a simpler implementation. For example, the default lowering
> for `aten._adaptive_avg_pool2d` handles dynamic input shapes and non-divisible output sizes. If
> your model always runs with static shapes and an output size that evenly divides the input (e.g.,
> ResNet's final `adaptive_avg_pool2d(output_size=(1, 1))`), you can replace it with a simpler
> `sumpool2d` + divide"*

Their example, verbatim (cell 14):

```python
import numpy as np
import torch
import torch.nn as nn

from coreai._compiler.dialects import coreai
from coreai_torch import TorchConverter, get_decomp_table
from coreai_torch._utils import get_operand


class PoolModel(nn.Module):
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return torch.nn.functional.adaptive_avg_pool2d(x, (1, 1))


pool_model = PoolModel().eval()
pool_input = (torch.randn(1, 3, 8, 8),)
pool_exported = torch.export.export(pool_model, args=pool_input)
pool_exported = pool_exported.run_decompositions(get_decomp_table())

converter = TorchConverter()


@converter.register_torch_lowering(
    "aten::_adaptive_avg_pool2d.default", allow_override=True
)
def lower_adaptive_avg_pool2d_static(values_map, node, loc):
    x = get_operand(values_map, node, 0, loc)
    output_h, output_w = node.args[1]
    input_h, input_w = x.type.shape[2], x.type.shape[3]
    stride_h, stride_w = input_h // output_h, input_w // output_w
    kernel_h = input_h - (output_h - 1) * stride_h
    kernel_w = input_w - (output_w - 1) * stride_w
    return coreai.broadcasting_divide(
        coreai.sumpool2d(
            x,
            kernel_size=np.array([kernel_h, kernel_w], dtype=np.uint32),
            strides=np.array([stride_h, stride_w], dtype=np.uint32),
            dilation=coreai.constant([1, 1], dtype=np.uint32),
        ),
        coreai.cast(float(kernel_h * kernel_w), x.type.element_type),
    )


coreai_program = converter.add_exported_program(pool_exported).to_coreai()
coreai_program.optimize()
```

Read that lowering with the failure classes in mind. It indexes `x.type.shape[2]` and
`x.type.shape[3]` directly. On a dynamic-shape export those are `?` and the arithmetic is wrong or
throws. It integer-divides to get the stride, which is only equivalent to adaptive pooling when the
division is exact. **Both preconditions are stated in prose and enforced by nothing.** That is the
deal you make when you override: you have asserted a constraint the compiler cannot check.

> ⚠️ **SILENT FAILURE — an override is permanent for the converter instance and invisible in the
> output.** Registration is **per-`TorchConverter` instance**; the global resolver dicts are never
> mutated (✅ VERIFIED — `tests/test_converter.py::test_override_aten_add_does_not_mutate_resolver`).
> That is good hygiene, but it means a converter object passed around a codebase carries hidden
> semantics. Nothing in the emitted IR records that `_adaptive_avg_pool2d` was overridden.
> `TorchConverter.__repr__` is the only introspection you get:
>
> ```text
> TorchConverter(
>   programs:
>     main: ExportedProgram ['x'] -> ['y'], externalize=['Inner']
>   custom_lowerings: ['my_lib::my_op.default']
> )
> ```
>
> Print it in your export script and log it. It is the cheapest audit trail available.

### 7.4 The six-way dispatch ladder

Knowing the precedence tells you what your registration will and will not shadow.

> ✅ **VERIFIED** — `coreai_torch/converter.py:680-726`, `_handle_call_function_op`, in source order:
>
> 1. **`node.name in self._externalized_lowerings`** — a per-node lowering installed by the
>    externalization pipeline for one specific call site. **Highest priority, keyed by node name, not
>    op name.**
> 2. **`qualified_target in self._user_defined_torch_lowering`** — where
>    `qualified_target = f"{namespace}::{target}"`. Your registrations.
> 3. **`namespace is None or namespace == "aten"`** → `_aten_to_core_resolver[target]`, else
>    `ValueError(f"Unsupported ATen op: {target}. …")`.
> 4. **`namespace in ("coreai", "coreaix")`** → `_custom_to_core_resolver[variantless_target]` —
>    note **variantless**: `strip_variant_from_target` removes a `.default`, `.Tensor`, `.Scalar` or
>    `.dim` suffix (`_utils.py:429-436`), so these five compression ops match regardless of overload.
> 5. **`namespace == "higher_order"`** → `_higher_order_resolver[target]`, called with
>    `graph_module=self.exported_program.graph_module` as a keyword — **not** with `loc`. A
>    higher-order lowering has a different callback signature from every other kind.
> 6. else `ValueError(f"unable to handle call function op: target: {target}, namespace: {namespace}")`.

Two consequences that matter in practice:

- **Externalization wins over your lowering.** If you externalize `SDPA` *and* register
  `"aten::scaled_dot_product_attention.default"`, the externalized call sites take rung 1 and your
  lowering never runs for them. It will still run for any *non*-externalized SDPA node.
- **The `coreai::` namespace is variantless.** ✅ VERIFIED, `_custom_to_core.py` resolver:
  `{"lut_to_dense", "constexpr_blockwise_shift_scale", "quantize", "dequantize",
  "sparse_to_dense"}`. These are the compression ops (Part 9). If you register
  `"coreai::quantize.default"` with `allow_override=True`, the guard's collision check looks for
  `"quantize.default"` in `_custom_to_core_resolver` — which contains `"quantize"` — so the collision
  is **not** detected and your registration lands at rung 2 anyway. It works; it just does not
  error the way you might expect.

### 7.5 ⚠️ Registration ordering — the rule is subtler than "always first"

For **Metal kernels** the rule is absolute and documented:

> ✅ **VERIFIED** — `docs/api/TorchMetalKernel.md`: *"`TorchMetalKernel` instances must be registered
> with the converter via `register_custom_kernels()` **before** `add_exported_program()`."*

For **lowerings** the rule is conditional, and Apple's own shipping code registers them **after**:

> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/export/macos.py:186-195`:
>
> ```python
> model.eval()
> converter = coreai_torch.TorchConverter()
> converter.add_pytorch_module(
>     model,
>     export_fn=export_fn,
>     externalize_modules=_EXTERNALIZE_SPECS,
>     input_names=input_names,
>     output_names=output_names,
>     state_names=state_names,
> )
> register_custom_torch_lowering(converter)     # <- AFTER add_pytorch_module
> return converter.to_coreai()
> ```

Both are correct, and the reason is §3.4. The validator only checks `aten.`-prefixed targets, and it
consults `user_lowerings` when deciding whether an ATen op is unsupported. So:

| Your lowering covers | Register before `add_*`? | Why |
|---|---|---|
| An **ATen** op the registry lacks | **Yes, required** | Otherwise `validate_exported_program` raises "unsupported ATen ops" before your lowering exists |
| An ATen op the registry **has**, with `allow_override=True` | No, either order works | The validator already considers it supported |
| A **custom-namespace** op (`my_lib::`, `coreai::`, `CompositeOps::`) | No, either order works | The validator skips non-`aten.` targets entirely — this is what `coreai-models` relies on |

**Recommendation: always register first.** The distinction costs nothing to ignore in the safe
direction, and it removes an ordering dependency from your export script that a future refactor
will otherwise break. `TorchConverter`'s own docstring supports this: *"Reusable state (custom op
lowerings) is retained across calls to `to_coreai()`. Per-conversion transient state is reset each
time."* and `clear()` documents *"Custom lowerings are always preserved."* — so registering early
costs you nothing across multiple conversions.

### 7.6 Emitting a *composite* from a custom lowering

A plain lowering emits ops into the parent graph. To emit a **named composite** — a `private
noinline` graph with a `composite_decl` that the compiler can pattern-match — you combine
`generate_composite_decl` with the `@coreai.graph` decorator.

> ✅ **VERIFIED** — `coreai_torch/_composite_declaration.py:162-202`, the **real** signature:
>
> ```python
> def generate_composite_decl(
>     context: Context,
>     composite_name: str,
>     input_names: Sequence[str],
>     output_names: Sequence[str],
>     op_attributes: dict,
>     version=1,
> ):
>     ...
>     op_attributes["version"] = version
>     return CompositeDeclaration(
>         composite_name,
>         {
>             "input_names": input_names,
>             "output_names": output_names,
>             "op_attrs": op_attributes,
>         },
>     ).to_coreai_attr(context)
> ```

> ⚠️ **Two documentation defects here, both verified.**
> 1. `docs/api/generate-composite-decl.md` documents the second parameter as `op_name` and omits
>    `version` entirely. The real name is **`composite_name`** and there is a sixth parameter.
>    Positional calls work either way; keyword calls using `op_name=` will `TypeError`.
> 2. The doc says it returns a `CompositeDeclaration`. It returns the **parsed MLIR `Attribute`**
>    (`.to_coreai_attr(context)`), which is what `@coreai.graph(composite_decl=…)` wants.

> ⚠️ **SILENT FAILURE — `generate_composite_decl` mutates the dict you pass it.**
> `op_attributes["version"] = version` writes into **your** dictionary. If you build one
> `op_attributes` dict and reuse it across several composites — a natural thing to do in a loop —
> the mutation persists, and a `version` key you never set appears in every subsequent declaration.
> It is benign today because `version` is always 1. It stops being benign the moment a v2 exists.
> **Pass a fresh dict, or a copy, every time.**

Attribute value types are restricted:

> ✅ **VERIFIED** — `_composite_declaration.py`: `bool` → `BoolAttr`, `int` → `IntegerAttr(si64)`,
> `float` → `FloatAttr(f32)`, `str` → `StringAttr`, `dict` → nested `DictAttr`, `list` → `ArrayAttr`.
> Anything else raises
> `TypeError("Unsupported value provided in composite declaration {v}.")`.
> Note `float` → **f32**: an `eps` of `1e-5` renders in the IR as `9.99999974E-6 : f32`. That is not
> a bug and not a precision loss you introduced.

The in-tree reference implementation is small enough to read whole:

> ✅ **VERIFIED** — `coreai_torch/_utils.py:1926-1941`, `build_hard_sigmoid_composite`:
>
> ```python
> def build_hard_sigmoid_composite(context: Any) -> coreai.GraphOp:
>     """Build a hard_sigmoid composite graph: min(max(x + 3, 0), 6) / 6."""
>     composite_decl = generate_composite_decl(
>         context, "hard_sigmoid", ["input"], ["output"], {}
>     )
>
>     @coreai.graph(private=True, no_inline=True, composite_decl=composite_decl)
>     def hard_sigmoid(input: Value) -> Value:
>         dtype = input.type.element_type
>         three = coreai.constant(3.0, dtype=dtype)
>         zero = coreai.constant(0.0, dtype=dtype)
>         six = coreai.constant(6.0, dtype=dtype)
>         add_three = coreai.broadcasting_add(input, three)
>         max_val = coreai.broadcasting_maximum(add_three, zero)
>         min_val = coreai.broadcasting_minimum(max_val, six)
>         return coreai.broadcasting_divide(min_val, six)
>
>     return hard_sigmoid
> ```
>
> `private=True, no_inline=True, composite_decl=…` is the exact trio that produces the
> `coreai.graph private noinline @… attributes {composite_decl = …}` form from §5.1.

And the documented call-site pattern, verbatim:

> ✅ **VERIFIED** — `docs/api/generate-composite-decl.md`:
>
> ```python
> from coreai_torch import generate_composite_decl, TorchConverter
>
>
> def my_custom_op_conversion(values_map, node, loc):
>     arg0 = values_map[node.args[0].name]
>     arg1 = values_map[node.args[1].name]
>     op_attributes = {
>         "some_attribute": 0.5,
>         "version": 1,
>     }
>     composite_decl = generate_composite_decl(
>         arg0.context,
>         "my_custom_op",
>         ["argument0", "argument1"],
>         ["output"],
>         op_attributes,
>     )
>
>     # The decorator transforms this function: calling it returns an OpResultList
>     @coreai.graph(no_inline=True, composite_decl=composite_decl)
>     def my_custom_op_impl(argument0: Value, argument1: Value) -> Value:
>         ...
>         return result
>
>     return my_custom_op_impl(arg0, arg1)[0]
>
>
> converter = TorchConverter()
> converter.register_torch_lowering("mylib::my_custom_op")(my_custom_op_conversion)
> ```
>
> with the note: *"The `coreai.graph` decorator always returns an `OpResultList`. **Index it at `[0]`
> when the composite produces a single output.**"* Forgetting the `[0]` hands the type checker an
> `OpResultList` where it wants a `Value` — a fast, loud failure, thankfully.

### 7.7 Apple's own shipping example

`apple/coreai-models` contains the only non-toy `register_torch_lowering` call site in the corpus,
and it is worth reading in full because it demonstrates every technique in this section at once.

> ✅ **VERIFIED** — `python/src/coreai_models/export/mlir_ops.py`, `register_custom_torch_lowering`:
>
> ```python
> def register_custom_torch_lowering(converter) -> None:
>     converter.register_torch_lowering("coreai::immutable_slice_update.default")(
>         custom_lowering_slice_update
>     )
>     converter.register_torch_lowering("CompositeOps::label_tensor_as_input.default")(
>         custom_lowering_composite_op_inputs
>     )
>     converter.register_torch_lowering("CompositeOps::label_tensor_as_output.default")(
>         custom_lowering_composite_op_outputs
>     )
>     converter.register_torch_lowering("coreai::dequantize_per_tensor.default")(
>         custom_lowering_dequantize_per_tensor
>     )
>     converter.register_torch_lowering("coreai::fused_dequant_gather_reshape.default")(
>         custom_lowering_fused_gather_dequant
>     )
>     converter.register_torch_lowering("coreai::rope_gather_cached_cos_sin.default")(
>         custom_lowering_rope_gather_cached_cos_sin
>     )
> ```

Six registrations, and note the shapes they cover:

- **Two are pure pass-throughs.** `custom_lowering_composite_op_inputs` and `…_outputs` return
  `_get_operand(values_map, node, 0)` and nothing else. `CompositeOps::label_tensor_as_input` is a
  marker op that exists only to survive tracing and then vanish. **A lowering that emits no IR is a
  legitimate, useful lowering.**
- **One is a three-line rewrite.** `custom_lowering_slice_update`:
  ```python
  x, update, begin, end = _get_operands(values_map, node, [0, 1, 2, 3])
  strides = [1] * x.type.rank
  return coreai.slice_update(x, begin, end, strides, update)
  ```
- **Two build named composites.** `custom_lowering_fused_gather_dequant` emits a composite called
  `fused_interleaved_embedding_gather_dequant_reshape` — gather + dequantize + reshape fused into one
  op — and `custom_lowering_rope_gather_cached_cos_sin` emits `rope_cached_cos_sin_gather`, a
  two-output composite (`["gathered_cos", "gathered_sin"]`).

The second of those is the concrete implementation of Apple's own RoPE workaround from §5.7 — the
"pre-compute the sine/cosine tables" advice, made into a composite that gathers from the cached
tables by position id.

Two techniques appear here that exist nowhere in the `coreai-torch` documentation:

> ✅ **VERIFIED** — `mlir_ops.py` uses `coreaix.copy_with_constraints(value, constraints)` and
> `coreaix.copy_discarding_constraints(value)` with
> `HardwareConstraints(AllocationType.IOSurface, alignments=[1,1,32,1], interleave=[1,1,1])`
> from `coreai.authoring.types`, and annotates a composite graph parameter with
> `Annotated[Value, TensorSpec(encoding=emb_enc)]`. This is how a lowering pins a tensor to an
> IOSurface-backed layout with a specific interleave — the mechanism behind ANE-friendly embedding
> tables. It is entirely undocumented in `coreai-torch`.

> 🔴 **GAP** — the semantics of `AllocationType`, `alignments` and `interleave` in
> `HardwareConstraints`, and which values are valid for which compute unit, are **unverified**. The
> only instances observed are `alignments=[1,1,1,1], interleave=[8,1,1]` (embedding table) and
> `alignments=[1,1,32,1], interleave=[1,1,1]` (RoPE cos/sin cache), plus the
> `#coreaix.hw_constraints<MTLBuffer, alignments: [1x1x1x1], interleave: [1x1x1]>` encoding that
> `TorchMetalKernel` attaches to every kernel operand. Resolving this needs the `coreai.authoring`
> type documentation or the installed `coreai-core` package. **Safe default meanwhile:** do not
> invent constraint values. If you need this, copy Apple's two working configurations verbatim and
> A/B the result against an unconstrained version — a wrong constraint is a layout bug, which is
> class 4.

Finally, note the import line, which is a small trap of its own:

> ✅ **VERIFIED** — `mlir_ops.py:25`: `from coreai_torch._utils import generate_composite_decl`.
> Apple imports it from the **private** `_utils` module, even though `coreai_torch/__init__.py`
> re-exports it publicly (`from ._composite_declaration import generate_composite_decl`, listed in
> `__all__`). Both work — `_utils.py:46` re-imports it — but **use the public
> `from coreai_torch import generate_composite_decl`** in your own code.

---

## 8. Externalization

### 8.1 What it is and what it produces

Externalization pulls a submodule out of the flattened graph and gives it its own `coreai.graph`,
which `@main` reaches by `coreai.invoke`. That is the whole mechanism; everything else is what the
extracted graph carries.

> ✅ **VERIFIED** — `docs/guides/externalization.ipynb`, cell 0, verbatim: *"Externalization preserves
> a submodule's operation boundary during conversion, so the operation stays intact as a recognizable
> unit in the converted model. When you mark a well-known building block — such as attention, RoPE,
> or RMSNorm — as a **composite op**, the compiler recognizes that operation and can apply an
> implementation optimized for it, producing a faster model."*

There are two modes and they differ by exactly one attribute:

| Mode | You pass | Emitted graph | `composite_decl` | Status |
|---|---|---|---|---|
| **Composite-op** | `ExternalizeSpec(target_class=…, composite_op_name=…, composite_attrs=[…])` | `coreai.graph private noinline @path.name_<hash>` | ✅ present | supported |
| **Simple** | a bare class, or a spec with only `target_class` | `coreai.graph noinline @path_<hash>` | ❌ absent | **experimental** |

> ✅ **VERIFIED** — `docs/api/ExternalizeSpec.md`, verbatim: *"Passing a bare class (or an
> `ExternalizeSpec` with only `target_class`) performs *simple externalization* — the submodule is
> extracted into its own standalone graph with **no composite-op metadata**. This is
> **experimental**; prefer setting `composite_op_name`."* And from the guide: *"It offers **no
> optimization benefit** and simply defines a boundary around the submodule."*

Both IR forms are quoted verbatim in §5.1.

### 8.2 `ExternalizeSpec`

> ✅ **VERIFIED** — `coreai_torch/externalize.py:87-112`, the real declaration and its validation:
>
> ```python
> @dataclass
> class ExternalizeSpec:
>     target_class: type
>     composite_op_name: str | None = None
>     composite_attrs: list[str] | None = None
>
>     def __post_init__(self) -> None:
>         if self.composite_op_name is None:
>             composite_only = {"composite_attrs": self.composite_attrs}
>             set_fields = [k for k, v in composite_only.items() if v is not None]
>             if set_fields:
>                 raise ValueError(
>                     f"ExternalizeSpec: {set_fields} can only be set when "
>                     f"composite_op_name is provided."
>                 )
> ```
>
> Field semantics, from the same source's docstring: `target_class` — *"`nn.Module` subclass to match
> (via `isinstance`)"*; `composite_op_name` — *"If set, the emitted graph gets a `composite_decl`
> **and is marked `private`**"*; `composite_attrs` — *"Module attribute names (e.g. `["eps"]`) whose
> values are included in `composite_decl`."*

Matching walks `model.named_modules()`, **skips the root** (`if not name: continue`), and **the first
matching config wins** (the inner loop `break`s). So the ordering of your `externalize_modules` list
matters if two specs could match the same instance — for instance a base class and its subclass.

The entry point is `add_pytorch_module`:

> ✅ **VERIFIED** — `coreai_torch/converter.py`:
>
> ```python
> def add_pytorch_module(
>     self,
>     model: torch.nn.Module,
>     *,
>     export_fn: Callable[[torch.nn.Module], ExportedProgram],
>     externalize_modules: list[type | ExternalizeSpec] | None = None,
>     input_names: Sequence[str] | None = None,
>     output_names: Sequence[str] | None = None,
>     state_names: Sequence[str] | None = None,
>     entrypoint_name: str = "main",
> ) -> Self:
> ```
>
> Note the `*`: **every parameter after `model` is keyword-only**, and `export_fn` is **required**.
> `docs/api/TorchConverter.md` renders these positionally, which is wrong — code written from the
> doc will `TypeError`.

> ⚠️ **Externalization requires `add_pytorch_module`.** `add_exported_program` has no
> `externalize_modules` parameter and no externalization path at all. This is not a limitation you
> can work around by pre-exporting: the pipeline needs the live `nn.Module` because phase 1 patches
> `submodule.forward` and re-exports (§8.3).

### 8.3 The five-phase pipeline, and why it matters for debugging

You do not call any of this, but knowing the phases tells you where an error came from.

> ✅ **VERIFIED** — `coreai_torch/externalize.py:9-56`, the module docstring, condensed:
>
> **Phase 1 — Mark & Re-export (`_mark_externalize`).** Walk `model.named_modules()`; for each match:
> resolve the module path, sanitize the op name, save `_original_forward`, **register a
> `torch.library.custom_op` from the submodule's `forward`**, register the original forward as the
> fake impl via `register_fake`, patch `submodule.forward` to call the custom op, stamp
> `_externalize_config`. Then **re-export via `export_fn(model)`** and `run_decompositions`. *"The FX
> graph now contains opaque `call_function` nodes for each custom op call site."*
>
> **Phase 2 — Prepare.** Yields one `_PreparedModule` **per call-site node**, shallowest-first, each
> with a UUID-suffixed graph name, fake inputs, dynamic shapes and source nodes.
>
> **Phase 3 — Export submodules.** `torch.export.export` on each prepared submodule, then derive
> composite I/O names from the graph signature, then `run_decompositions()`.
>
> **Phase 4 — Emit Core AI IR.** Deepest-first, so inner lowerings exist when parent graphs are
> built. `noinline` for all; `private` + `composite_decl` for composite ops. Registers per-node
> lowerings keyed by FX node name — this is rung 1 of the dispatch ladder (§7.4).
>
> **Phase 5 — Cleanup.** Remove all markers. *"The user's model is left unmodified."*

Four operational facts fall out:

**Your model is exported twice.** Phase 1 re-runs `export_fn(model)` after patching. If your
`export_fn` is expensive, non-deterministic, or has side effects, you pay for it twice and may get
two different graphs. Keep it pure.

**Your model is not mutated.** ✅ VERIFIED — restoration happens in a `finally`, and there is a test
for it: `tests/test_externalize.py::test_model_not_mutated_after_convert`.

**Each call site gets its own graph.** ✅ VERIFIED, `_utils.py`: graph name is
`f"{module_path}_{uuid4().hex[:8]}"`, with the source comment: *"Even when two call sites have the
same argument count, each must get its own `noinline` graph so the runtime does not deduplicate
invocations of the same graph symbol."* **Do not pattern-match on exact symbol names** in tooling —
they contain a random hex suffix and change every run.

**Inner submodules are decomposed with the *default* table, not yours.** ✅ VERIFIED,
`externalize.py`, with the comment:

```python
# The user's export_fn may preserve composite ops like aten.scaled_dot_product_attention
# so they survive in the *whole-model* graph for externalization detection.
# Inside the externalized body those ops must be decomposed.
inner_ep = inner_ep.run_decompositions()
```

> ⚠️ **This is a real class-2 generator.** A model that converts cleanly at the top level can fail
> from *inside* an externalized body, because the body was decomposed with a table you did not
> choose. It is also why the §3.5 short-form `Unsupported ATen op:` message can appear with a clean
> validation. If you see an unfamiliar overload named in a `to_coreai()`-time error, check whether
> the op lives inside something you externalized.

Two more constraints, both hard errors:

> ✅ **VERIFIED** — `externalize.py`: non-tensor arguments to an externalized submodule are rejected:
>
> ```text
> TypeError: Expected argument {i} of custom op node '{node.target}' to be a Tensor, but got
> {type}. Only Tensor inputs are supported for externalized submodules.
> ```
>
> And fake inputs are **fresh concrete tensors** (`torch.empty(shape, dtype, device)`), not the
> parent's `FakeTensor`s, deliberately — to avoid inheriting view metadata such as `storage_offset`
> from a `.narrow()`, and to avoid `SymInt`s bound to the parent's `ShapeEnv`.

### 8.4 Requirements for composite-op modules

Two rules, and violating either produces a `TypeError` or a wrong composite, not a warning.

> ✅ **VERIFIED** — `docs/guides/externalization.ipynb`, cell 5, verbatim:
>
> 1. *"**Forward arguments must be tensors** — all `forward` parameters that become inputs must be
>    `torch.Tensor`. Scalar configuration (e.g., `eps`, `is_causal`) should be stored as instance
>    attributes and serialized via `composite_attrs` in `ExternalizeSpec`."*
> 2. *"**Optional arguments must use `torch.Tensor | None = None`** — when an optional is not
>    provided (left as `None`), it is excluded entirely and does not appear in `input_names`.
>    **There is no support for default tensor values.**"*

Input and output names are derived, not declared:

> ✅ **VERIFIED** — `coreai_torch/externalize.py`, `_derive_composite_io_names`: *"Parameters and
> buffers use their `target` (attribute name), user inputs use their `arg.name` (forward parameter
> name). Output names follow the convention `"output"` for a single return or `"output_0"`,
> `"output_1"`, … for tuple returns."*
>
> Verified behaviours from `tests/test_externalize.py::test_derive_composite_io_names_*`:
> `forward(query, key)` → `["query", "key"]`, `["output"]`; a module with
> `self.weight = nn.Parameter(...)` and `forward(input)` → **`["weight", "input"]` — parameters come
> first**; a tuple return → `["output_0", "output_1"]`; optional args left `None` at export are
> excluded; skipped middle optionals still order correctly (`["x", "c"]`, `["x", "a", "c"]`).

> ⚠️ The parameters-first ordering is the one that surprises people. If you are writing a compiler
> pattern or reading IR by hand, the composite's `input_names` are **not** your `forward` signature —
> they are parameters and buffers, then forward args.

### 8.5 What Apple actually externalizes

The single most useful artefact for calibrating your own spec list:

> ✅ **VERIFIED** — `apple/coreai-models`, `python/src/coreai_models/export/macos.py:35-62`, verbatim,
> including its own comment:
>
> ```python
> # Composite ops that are externalized (kept as named composites in the MLIR graph
> # rather than being inlined/decomposed).
> _EXTERNALIZE_SPECS = [
>     coreai_torch.ExternalizeSpec(
>         target_class=coreai_torch.composite_ops.GatherMM,
>         composite_op_name="gather_mm",
>         composite_attrs=["num_batch_axes"],
>     ),
>     coreai_torch.ExternalizeSpec(
>         target_class=coreai_torch.composite_ops.RMSNormImpl,
>         composite_op_name="rms_norm",
>         composite_attrs=["axes", "eps"],
>     ),
>     coreai_torch.ExternalizeSpec(
>         target_class=coreai_torch.composite_ops.RoPE,
>         composite_op_name="rope",
>         composite_attrs=["scale", "base", "dims", "interleaved"],
>     ),
>     coreai_torch.ExternalizeSpec(
>         target_class=coreai_torch.composite_ops.SDPA,
>         composite_op_name="scaled_dot_product_attention",
>         composite_attrs=["scale", "is_causal", "window_size"],
>     ),
>     coreai_torch.ExternalizeSpec(
>         target_class=coreai_torch.composite_ops.GatedDeltaUpdate,
>         composite_op_name="gated_delta_update",
>         composite_attrs=[],
>     ),
> ]
> ```

Three things to take from it:

1. **All five module-class composites, always, unconditionally.** This is the macOS LLM export path
   for every model in the repo. It is a superset — most checkpoints do not contain a `GatherMM` or a
   `GatedDeltaUpdate` — and that is deliberate; see the "superset across model variants" rationale in
   §8.7.
2. **`RMSNormImpl`, not `RMSNorm`** — Apple's own list confirms §5.6.
3. ⚠️ **`GatedDeltaUpdate` gets `composite_attrs=[]`, not `["use_qk_l2_norm"]`.** The doc page's
   `ExternalizeSpec` example says `composite_attrs=["use_qk_l2_norm"]`; Apple's shipping export
   passes an empty list. Both are valid — an empty list means the composite carries only `version` —
   but they are **different composites** from the compiler's point of view, because the attribute set
   is part of what it matches on. 🔴 **GAP:** which one the Core AI compiler's `gated_delta_update`
   pattern actually expects is **unverified**; the compiler is closed-source. **Safe default:** copy
   Apple's shipping form (`composite_attrs=[]`) and set `use_qk_l2_norm` correctly on the module
   itself, since the flag changes the emitted body either way.

Note also what is **not** in that list: no ATen-derived composites. They need no spec — they are
recognised from the graph.

### 8.6 The real motivations — and one terminology collision to defuse

Apple's `model-authoring` agent skill is the closest thing to a rationale document, and it points at
two large-model patterns:

> ✅ **VERIFIED** — `apple/coreai-models`, `skills/skills/model-authoring/SKILL.md:23`, verbatim:
> *"For complex models (LLMs, MoE, multimodal, diffusion), **explore the coreai-models repo before
> writing primitives from scratch**. It has complete authoring primitives for both GPU and Neural
> Engine, including advanced patterns like **iOS embedding quantization, MoE routing, and
> memory-efficient weight loading for large models**."*

**Motivation 1 — memory-efficient weight loading for large models.**

> ✅ **VERIFIED** — `skills/skills/model-authoring/references/gpu_rules.md`, "Memory-efficient weight
> loading", verbatim: *"For large models (7B+), avoid holding both the source HuggingFace model and
> the re-authored model in RAM simultaneously"* — via **meta-device initialization**
> (`model = MyReauthoredModel(config, device="meta")`), **assign-mode loading**
> (`model.load_state_dict(mutated_state_dict, assign=True)`), and **streaming one layer at a time**:
> *"open safetensors files directly, process one layer's weights (mutate state dict keys, reshape for
> Conv2d or fuse QKV), load that layer, then move to the next. **Peak RAM is roughly one layer rather
> than the full model.**"* The end-to-end pattern is named `from_hf_memory_efficient`.

> ⚠️ **Correction, stated plainly because it will otherwise cost you a day.** This is a
> **PyTorch-side model-construction technique**, not an `ExternalizeSpec` feature.
> `externalize_modules` does not stream weights, does not reduce peak RAM during export, and does not
> mmap anything. The two topics sit next to each other in Apple's skill because both are "how you
> handle a 7B model", not because one implements the other. (The mmap-backed path that *does* exist
> is `KMeansPalettizer.finalize(mmap_dir=…)` in `coreai-opt` — Part 9 — and `coreai-models` PR #101,
> *"Add support for memory efficient iOS exports for large models"*, which was **still open** as of
> 2026-07-29.)

**Motivation 2 — iOS embedding quantization.**

> ✅ **VERIFIED** — `skills/skills/model-authoring/SKILL.md`, "Neural Engine and GPU at a glance"
> table row, verbatim: *"| Embedding shape | `(V, 1, D)` — **externalized** | Standard
> `nn.Embedding` |"*, and `references/neural_engine_rules.md:261-275`: *"Neural Engine embeddings use
> shape `(vocab_size, 1, hidden_size)` to maintain BC1S-compatible output"*, with the loading rule
> *"`embedding_weight = source_weight.unsqueeze(1)  # (V, D) → (V, 1, D)`"*.

The reason the shape is `(V, 1, D)` is the Neural Engine's BC1S layout — `(B, C, 1, S)` channels-first
— which the whole iOS authoring path is built around. But **what "externalized" means in that table
is not `ExternalizeSpec`**:

> ✅ **VERIFIED** — `references/neural_engine_rules.md:432-447`, "Model decomposition", verbatim:
> *"Neural Engine models typically **separate the embedding table from the transformer body**. The
> embedding is **exported separately** because Neural Engine **quantizes it independently** and
> **passes the table as an explicit input** … **This decomposition enables separate embedding
> quantization and lookup programs.**"*
>
> ```python
> class ModelForCausalLM(nn.Module):
>     def __init__(self, config):
>         self.embed_tokens = Embedding(config)  # Exported separately
>         self.extend = ModelExtend(config)      # Main export target
> ```
>
> And the resulting artefact, from the same file: a compiled iOS LLM exposes entrypoints named
> `extend_{ctx}_{len}`, `prompt_opt_{ctx}_{len}` and **`gather_embeddings_{N}`** — *"Embedding lookup
> before each extend"*.

> ⚠️ **Terminology collision — two different mechanisms, one word.**
>
> | Intent | Mechanism | API |
> |---|---|---|
> | Preserve an op boundary inside one function so the compiler can match a kernel | Externalization | `ExternalizeSpec` + `externalize_modules` |
> | Split a model into independently-compressible, independently-callable programs | **Multi-entrypoint conversion** | multiple `add_exported_program(…, entrypoint_name=…)` calls on one converter |
>
> The embedding-table story is the **second** one. You get it by staging several exported programs
> with distinct `entrypoint_name`s, exactly as `coreai-models` does for the segmentation pipeline
> (`image_encode` / `text_encode` / `detect`) — three functions, three compression schemes, one
> `.aimodel`. Reaching for `ExternalizeSpec` to solve an embedding-quantization problem will not work
> and will waste your afternoon.
>
> When loaded through the optional `coreai-models` package, that recognized multi-entrypoint split
> also selects the helper’s Neural Engine preference; it is not a Core AI framework naming
> contract.[^sample-routing-policy] See [Part 7](../../part-07-coreai-swift-runtime/README.md) and
> [Part 10](../../part-10-coreai-hardware-authoring-debugging/README.md), where it is covered properly.

**Motivation 3, the one Apple states most directly, is simply speed.** From the externalization
guide: *"the compiler recognizes that operation and can apply an implementation optimized for it,
**producing a faster model**."* And from WWDC26 session 325 (spoken narration): *"you can take a
group of those ops and **fuse them into a single operation**. This **replaces several steps with a
single kernel dispatch** within the graph. … Core AI **already ships with pre-packaged fast kernels
and primitives for heavy operations like Scaled Dot Product Attention**, commonly found in
Transformers."*

> 🔴 **GAP** — **there is no published number for what externalizing a composite is worth.** No
> Apple benchmark, no community measurement in this corpus, isolates composite-on versus
> composite-off for the same model. The mechanism is documented; the magnitude is not.
> Resolving this needs an A/B: convert once with `externalize_modules=[...]` and once with `[]`,
> then `benchmark_coreai_program` on both (§10.4). **Safe default meanwhile:** externalize the five
> module-class composites as Apple does — the cost is a list literal and the mechanism is
> well-attested — but do not promise a stakeholder a percentage.

### 8.7 ⚠️ The four silent failures in externalization

**(a) An unmatched `target_class` warns; it does not raise.**

> ✅ **VERIFIED** — `coreai_torch/externalize.py:391-399`, the exact text:
>
> ```text
> externalize_modules: the following target class(es) did not match any submodule in the model:
> {names}. No externalization will happen for these classes. If intentional (e.g. passing a superset
> across model variants), this warning is safe to ignore. Otherwise, check for typos or stale class
> references.
> ```
>
> The rationale from the source docstring is legitimate: *"callers legitimately pass a superset of
> specs across model variants (e.g. `[Qwen2Attn, MixtralAttn]` where only one applies per
> checkpoint)"* — which is precisely what `_EXTERNALIZE_SPECS` does (§8.5).
>
> But the consequence is that **a typo, a stale import, or a refactored class name silently produces
> a slower model**. And because the superset pattern is the *recommended* usage, you cannot fix this
> by treating the warning as an error. **Assert on the IR instead:**
>
> ```python
> ir = str(coreai_program)
> for name in ("rms_norm", "rope", "scaled_dot_product_attention"):
>     assert f'composite_declaration<"{name}"' in ir, f"composite {name} missing from IR"
> ```

**(b) A matched-but-unreachable submodule is skipped, also with a warning.**

> ✅ **VERIFIED** — `coreai_torch/externalize.py:437-444` (added by PR #18):
>
> ```text
> [WARN] coreai_torch.externalize: skipping unused submodule '{name}'.
>        It matched an externalize_modules target class but is not reachable from the exported graph.
>        Action: remove it from the model passed to add_pytorch_module, or ignore if intentional.
> ```
>
> This is an *improvement* — before PR #18 it raised `ValueError: Custom op for '<name>' not found in
> any ancestor program` and aborted the whole conversion. But it means a module you registered but
> never call in `forward` (a common state after a refactor) is now invisible.

**(c) Sub-byte compression injection is skipped on the externalization path.**

> ✅ **VERIFIED** — `coreai_torch/converter.py`, inside `add_pytorch_module`:
>
> ```python
> if not externalize_modules:
>     inject_subbyte_tensors(ep)
> ```
>
> When you externalize, injection happens later, on the **re-exported** whole program inside
> `_run_externalize_pipeline`. The historical bug this guards against is documented in the skipped
> quantized-weight externalization tests: *"the externalize re-export used to **discard sub-byte
> injection (si4 weights degraded to si8)**"* — a model that was silently twice the intended weight
> size, with correct numerics. It is fixed, but the coupling between externalization and compression
> is real, and it is why you should check weight dtypes in the IR after any change to either.

**(d) The SDPA externalize re-export drops a dimension bound.**

> ✅ **VERIFIED** — `coreai-torch` issue **#1** (open), author `scndls`. Error, verbatim:
>
> ```text
> RuntimeError: Internal error: failed to export submodule 'sdpa_061e31ac': Constraints violated (d_20)!
>   - Not all values of d_20 = L['key'].size()[2] in the specified range satisfy the generated guard
>     12 <= L['key'].size()[2] and L['key'].size()[2] <= IntInfinity()
> Suggested fixes:
>   d_20 = Dim('d_20', min=12)
> This is a coreai-torch bug. Please report it.
> ```
>
> Why the shipped models do not hit it, verbatim: *"The shipped models don't hit this because they
> keep the **query** dynamic as well, so query and key share a single bounded symbol. The bug only
> surfaces when `query_len` is static (a fixed prefill chunk / single decode step) while the context
> is dynamic."* Internals named: `_dim_for_sym` in `_utils.py` reads `var_to_range` to reconstruct
> the `Dim`, and a `torch._check(key.size(-2) <= cap)` in the **parent** forward **does not propagate
> into the submodule re-export**.
>
> **Workaround (from the thread):** drop `SDPA` from the externalize list so it decomposes to
> primitive ops — you lose the composite and keep the export. The PR that targeted this (**#7**,
> *"Skip fully-specialised dims in submodule re-export"*, +347/−241) was **closed without being
> merged on 2026-07-29** (re-checked via `gh` 2026-07-31), so the workaround remains the only path.
>
> This failure is at least loud. Note the message: **"This is a coreai-torch bug. Please report it."**
> is emitted by the package itself — if you see that sentence, do not debug your model.

---

## 9. Four live silent-miscompile defects on 0.4.1

Everything in this section was **verified against the shipped source this session**, at
`apple/coreai-torch` commit `4529671`, `coreai_torch/__version__.py` = `"0.4.1"`. Each defect has a
proposed fix that was **open or closed-unmerged as of 2026-07-29**, which means each is live in the
version you get from `pip install coreai-torch` today.

They share a shape: **the conversion succeeds, the shapes are right, and the numbers are wrong.**
None of them throws. Three of them are wrong on *every* backend, because the defect is in the
lowering — upstream of any delegate.

### 9.1 fp16 overflow in `softplus`, `mish`, `logsumexp`, `logcumsumexp`

**Status:** `apple/coreai-torch` issue **#21** open; proposal **apple/coreai-torch#5** open;
implementation PR **apple/coreai-torch#22** open, unmerged.

**Verified live.** Grep of `coreai_torch/_aten_to_core.py` and `coreai_torch/_decomp.py` at HEAD:
**zero occurrences of `softplus`, `mish` or `logsumexp`.** They are neither in `_COMPOSITE_OPS` nor
in the resolver, so PyTorch's default decomposition applies and produces the naïve form.

The overflow table, from issue #21:

> ✅ **VERIFIED (reporter-measured, `Ashutosh0x`, 2026-06-21, macOS 26 / Apple silicon, PyTorch 2.7+)**
>
> | Operation | Naïve decomposition | Failure threshold | Failure mode |
> |---|---|---|---|
> | `softplus` | `log(1 + exp(x))` | `x ≈ 10.4` | Output → 0 |
> | `mish` | `x * tanh(log(1 + exp(x)))` | `x ≈ 10.4` | Output → 0 |
> | `logsumexp` | `log(sum(exp(x_i)))` | `x ≈ 7.63` | Output → 0 |
> | `logcumsumexp` | `log(cumsum(exp(x_i)))` | `x ≈ 11.09` | Output → ∞/NaN |
>
> Root cause, verbatim: *"When `softplus` is not in this list, PyTorch decomposes it to
> `log(1 + exp(x))`, where `exp(x)` overflows fp16 (max 65,504) for `x > ~11.09`. **On the ANE
> specifically, the overflow occurs even earlier at `x ≈ 10.4` due to an internal 2^15-bounded
> representation.**"*

The proposed stable forms, from PR #22:

| Operation | Naïve | Stable |
|---|---|---|
| `softplus` | `log(1 + exp(x))` | `max(x, 0) + log(1 + exp(-abs(x)))` |
| `mish` | `x * tanh(log(1 + exp(x)))` | `x * tanh(softplus_stable(x))` |
| `logsumexp` | `log(sum(exp(x)))` | `max(x) + log(sum(exp(x - max(x))))` |

and the one-line proof from the same PR:

```python
import numpy as np

x = np.float16(15.0)
naive = np.float16(np.log(np.float16(1.0) + np.exp(x)))                  # inf  (WRONG)
stable = np.float16(np.maximum(x, 0) + np.log(1 + np.exp(-np.abs(x))))   # 15.0 (CORRECT)
```

Note that `log_softmax` is **already** safe — the package has a max-shifted `replace_log_softmax` in
`_aten_to_core.py`. So the stable-decomposition technique is present in the codebase; it just has not
been applied to these four ops.

> ⚠️ **The sanctioned workaround is to rewrite your PyTorch module.** This is not a guess — it is a
> maintainer's answer on the sibling `coreai-optimization` issue **#7**, verbatim (@crowbat,
> CONTRIBUTOR): *"You're right that the casting utility currently only considers statically available
> tensors when choosing whether or not to cast parts of the model to lower precision. … Before such
> handling is in place, **a workaround could be to manually edit the original Pytorch model
> definition to substitute stable versions of ops like `Softplus`**, avoiding the need for changes in
> either `coreai-opt` or `coreai-torch`."*

```python
"""Drop-in stable replacements. Substitute these in your nn.Module before export.

Why this works: the converter has no lowering for softplus/mish/logsumexp, so it
sees whatever these decompose into. Writing the stable algebra yourself means the
graph contains only ops that cannot overflow.
"""

import torch
import torch.nn as nn


class StableSoftplus(nn.Module):
    """softplus(x) = max(x, 0) + log1p(exp(-|x|))  — exact, and exp() never exceeds 1."""

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return torch.clamp(x, min=0) + torch.log1p(torch.exp(-torch.abs(x)))


class StableMish(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.softplus = StableSoftplus()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x * torch.tanh(self.softplus(x))


def stable_logsumexp(x: torch.Tensor, dim: int, keepdim: bool = False) -> torch.Tensor:
    """logsumexp with the max shifted out — exp() argument is always <= 0."""
    m = torch.amax(x, dim=dim, keepdim=True)
    out = m + torch.log(torch.sum(torch.exp(x - m), dim=dim, keepdim=True))
    return out if keepdim else out.squeeze(dim)
```

> ⚠️ **The compound case is worse than either half.** From `coreai-opt` issue #7, verbatim: *"When
> `coreai-optimization` applies weight compression (palettization, quantization) AND fp16 casting
> together: 1. Quantization introduces rounding errors in weights 2. These errors can shift
> activation distributions 3. **Values that were safely below the overflow threshold may now exceed
> it** 4. The casting pass has no mechanism to detect or prevent this."* A model that passed its
> fp16 gate before compression can fail it after, from an op you never looked at.

### 9.2 Integer true-divide truncates instead of promoting to float

**Status:** `apple/coreai-torch#32` merged 2026-07-29.

**Verified live.** `coreai_torch/_aten_to_core.py:3591-3592` and `:3722`:

```python
"div.Scalar": replace_binary_ops,
"div.Tensor": replace_binary_ops,
...
"true_divide.Tensor": replace_binary_ops,
```

and `replace_binary_ops` (`:836-846`) promotes both operands to their **common** type before
dividing:

```python
x, y = _get_operands(values_map, node, [0, 1])
promoted_type = get_promoted_type(x.type, y.type)
result = _op_map[get_target(node)](
    x=coreai.cast(x, promoted_type),
    y=coreai.cast(y, promoted_type),
)
if isinstance(node.meta.get("val"), torch.Tensor):
    target_type = get_output_element_type_from_node(node)
    if result.type.element_type != target_type:
        result = coreai.cast(result, target_type)
```

For two integer tensors, `get_promoted_type` yields an **integer** type, so the division runs in
integers — and *then* the result is cast up to the float output type. The fraction is already gone.

Contrast the handler that does it correctly, `replace_truediv` (`:850-858`), which casts to the
**output** type first:

```python
x, y = _get_operands(values_map, node, [0, 1])
result_type = get_output_element_type_from_node(node)
return coreai.broadcasting_divide(
    x=coreai.cast(x, result_type),
    y=coreai.cast(y, result_type),
)
```

That is exactly the fix merged by `apple/coreai-torch#32` on 2026-07-29 — re-point
`div.Tensor` / `div.Scalar` / `true_divide.Tensor` at `replace_truediv`. The source excerpt above
is the pre-merge defect snapshot; refresh the research mirror before treating those line numbers
as current HEAD.

> ⚠️ **SILENT FAILURE.** From PR #32, verbatim: the generic handler *"keeps same-kind integers as
> integers — correct for add/sub/mul, **wrong for true divide**: it divided as ints then cast,
> dropping the fraction on **every** backend."* The same latent bug exists in
> `replace_div_tensor_mode`'s `rounding_mode=None` branch. `floordiv`, `mod`, `fmod` and
> `rounding_mode="floor"/"trunc"` were already correct.
>
> **Where this bites:** any `x / n` where both sides are integer tensors — sequence-position
> arithmetic, index normalisation, `positions / head_dim`, anything computing a ratio from shape
> values. PyTorch's contract is that `/` on integers **always** produces a float. Core AI 0.4.1
> gives you a floored integer widened to float. `7 / 2` returns `3.0`.
>
> **Workaround:** cast one operand to float at the call site.
>
> ```python
> ratio = a.float() / b        # correct on 0.4.1
> ratio = a / b                # WRONG on 0.4.1 when a and b are both integer tensors
> ```

### 9.3 `cat` on packed sub-byte tensors always concatenates on dim 0

**Status:** PR **#41** open, unmerged.

**Verified live.** `coreai_torch/_compression/_intx.py:380-382`, `__torch_dispatch__`:

```python
if func is torch.ops.aten.cat.default:
    self, dim = fill_defaults(args, 2, [0])
    unpacked = [x.unpack_func(x.elem, x.tensor_shape, x.nbits) for x in self]
    return cls.from_unpacked(func(unpacked), self[0].nbits)
```

`dim` is unpacked from `args` and then **never used**. `func(unpacked)` calls `aten.cat` with its
default `dim=0`.

Compare the branch immediately above it, which does it right:

```python
if func is torch.ops.aten.slice.Tensor:
    self, dim, start, end, step = fill_defaults(args, 5, [0, None, None, 1])
    unpacked = self.unpack_func(self.elem, self.tensor_shape, self.nbits)
    return cls.from_unpacked(func(unpacked, dim, start, end, step), self.nbits)
```

> ⚠️ **SILENT FAILURE.** Per PR #41: two `(2, 4)` packed tensors concatenated with `dim=1` produce
> **`(4, 4)` instead of `(2, 8)`**, silently. Affects both `IntxTensor` and `UintxTensor` — i.e.
> every 2-, 4- or 8-bit quantized weight and every 1-, 2-, 3-, 4-, 6- or 8-bit palettized LUT that
> passes through a `cat`.
>
> **Where this bites:** weight surgery on compressed checkpoints. Fusing per-expert MoE weights
> (§6.1 — *"stack them into the `(1, num_experts, out, in)` shape"*), fusing Q/K/V projections, or
> concatenating gate and up projections — all of which are standard steps in a re-authoring pipeline,
> and all of which are typically done on the **last** dimension.
>
> **Why you might not notice:** if the tensors are square, or if the concatenated dimensions happen
> to have compatible sizes, the resulting shape can still be *valid* — just wrong. A downstream
> matmul then computes garbage with no shape error. This is the same failure geometry as
> `coreai-torch#49`, where square inputs hid an `optimize()` bug and unequal (17×23) inputs exposed
> it.
>
> **Workaround:** do every `cat` on **unpacked** tensors, before sub-byte injection. Concretely: do
> your weight fusion in the PyTorch model definition or in the state-dict mutation step, never on a
> tensor that has already been through `inject_subbyte_tensors` or a palettizer `finalize()`.

### 9.4 int64 accumulator narrowing in `sum` and `prod`

**Status:** `apple/coreai-torch#45` **closed without merge**. The defect stands.

**Verified live.** `coreai_torch/_aten_to_core.py:2692-2701`, `replace_sum_dim_intlist`:

```python
x = _get_operand(values_map, node, 0)
args = node.args

target_type = get_output_element_type_from_node(node)
if x.type.element_type != target_type:
    x = coreai.cast(x, target_type)
```

and `get_output_element_type_from_node` (`_utils.py:451-473`) ends with:

```python
dtype = _NARROW_TORCH_DTYPE.get(dtype, dtype)
return TORCH_TO_COREAI_DTYPE[dtype]()
```

where (`_utils.py:305-308`):

```python
_NARROW_TORCH_DTYPE: dict[torch.dtype, torch.dtype] = {
    torch.int64: torch.int32,
    torch.float64: torch.float32,
}
```

PyTorch's contract is that `torch.sum` / `torch.prod` on a narrower integer input **promote the
accumulator to int64**. The lowering asks for the node's output type, which PyTorch says is int64,
and the narrowing map turns that into int32 before the reduction is emitted.

> ⚠️ **SILENT FAILURE.** From PR #45, verbatim: *"That made the reduction itself run (and overflow)
> in `int32` instead of `int64`, **silently wrapping identically on every backend (interpreter, cpu,
> gpu, ane)** — this corrupts the lowered IR itself, upstream of any backend."* The PR also notes:
> *"CoreAI's IR already supports `int64` (`si64`) as a first-class type"* — so this is a lowering
> policy, not a hardware limit.
>
> **Known related gap, called out by the PR author and not fixed:** *"`replace_cumsum` has the same
> accumulator-narrowing shape … `cumsum`'s narrowing appears to additionally **crash** rather than
> silently wrap when pressed with an overflowing input."*
>
> **Where this bites:** counting. `mask.sum()` over a large batch, token counts, histogram bins,
> cumulative index arithmetic. Any integer reduction whose true total exceeds 2³¹−1 ≈ 2.1 × 10⁹.
>
> **Workaround:** cast to float before reducing if the magnitude allows (fp32 is exact to 2²⁴), or
> reduce in chunks, or restructure so the reduction runs on a dtype that cannot overflow:
>
> ```python
> total = mask.to(torch.float32).sum(dim=0)     # exact below 2**24
> ```

### 9.5 Two more you must know, though they are not in `coreai-torch`'s lowerings

**MobileNetV3 / ANE fp16: a 2D matmul feeding `Hardswish`.**

> ✅ **VERIFIED** — `coreai-torch` issue **#51** (open, 0 comments), author `zli96`, 2026-07-23.
> Environment: **macOS 27 beta 3, `coreai-torch` v0.4.1**. Reporter-measured, FP16 NPU vs GPU on the
> *same* `.aimodel`:
>
> | Test case | Max abs diff | Rel L2 diff |
> |---|---|---|
> | MobileNet V2 (Linear + ReLU/Identity classifier) | `0.002686` | `0.001025` |
> | MobileNet V3 Small (Linear + Hardswish classifier) | `0.199219` | `0.039235` |
>
> Two orders of magnitude worse, from swapping the classifier activation.
> **Reporter's own workaround, verbatim:** *"Transforming the 2D matrix into a 4D matrix
> (1 x 1 x m x n) avoids the issue on the NPU."*
>
> Single reporter, uncontrolled conditions, no Apple response as of 2026-07-29. But the mitigation is
> cheap, consistent with the Neural Engine's BC1S/4D orientation, and worth trying before you conclude
> your quantization is at fault.

**`AIProgram.optimize()` is not always semantics-preserving.**

> ✅ **VERIFIED** — `coreai-torch` issue **#49** (open), author `dkomoroske`, 2026-07-23. macOS 27.0
> builds `26A5378j` and `26A5388g`, `coreai-torch 0.4.1`, `coreai-core 1.0.0b2`, torch 2.11.0. Also
> filed as Feedback Assistant **FB23695952**. `optimize()` deletes an `expand_dims`/`transpose` that
> is **semantically load-bearing for broadcasting**, in the expanded squared-distance form.
>
> Minimal failing shape:
>
> ```python
> s1 = torch.sum(x ** 2, dim=-1).unsqueeze(-1)  # (1,N,1)
> s2 = torch.sum(y ** 2, dim=-1).unsqueeze(-2)  # (1,1,N)
> out = (s1 - 2 * z + s2).clamp(min=0.0)
> ```
>
> Reporter-measured harness output, verbatim:
>
> ```text
> Chain           optimize=False: max|d| = 1.907e-06  OK
> Chain           optimize=True : max|d| = 1.022e+01  MISCOMPILED
> ChainReordered  optimize=False: max|d| = 3.815e-06  OK
> ChainReordered  optimize=True : max|d| = 3.815e-06  OK
> ```
>
> Impact, verbatim: *"In a larger GeoTransformer conversion, this appeared as approximately **17 dB
> PSNR** versus eager PyTorch and scrambled nearest-neighbor relationships. **Disabling `optimize()`
> restored approximately 78–85 dB parity.**"*
>
> Two things make this generalisable rather than a one-off. First, `SpecializationOptions.cpu_only()`
> reproduces it — *"so it is a compiler/optimizer bug, not a delegate bug"*. Second, and more
> important for your test design: **unequal input lengths (17×23) come out correct**, and only
> shape-compatible (square) cases miscompile, because the wrong operand still broadcasts. **A parity
> test on square tensors can pass while the same code on rectangular tensors fails, and vice versa.**
>
> **Two verified workarounds:** (1) do not call `optimize()` — *"Conversion, `save_asset`,
> specialization, loading, and inference work correctly without it"*; (2) reorder to
> `(||x||² + ||y||²) − 2·x·y`.
>
> **This is why "optimize=True vs optimize=False" is one of the four standard numerics gates in §10.**
> Note the tension with §5.1: `optimize()` is also what stateful models **require** (mutation outputs
> become handle tokens only after it runs), so "just skip it" is not free.

### 9.6 Recovering 0.4.0 artifacts without re-converting

Not a miscompile, but the version gate from the top of this guide has a documented escape hatch that
is easy to miss.

> ✅ **VERIFIED** — `coreai-torch` issue **#44** (resolved: closed as completed 2026-07-24),
> maintainer @cymbalrush, verbatim: *"Could
> you try using `strip_debug_info` to remove debugging metadata? This should prevent the compiler
> failure. After stripping the debug information, make sure to save the updated asset."*
>
> ```python
> from pathlib import Path
>
> from coreai.authoring import AIModelAsset
> from coreai_torch.debugging.debug_info import strip_debug_info
>
> asset = AIModelAsset.load(Path("model.aimodel"))
> coreai_program = asset.program
> strip_debug_info(coreai_program)                       # in-place
> coreai_program.save_asset(Path("model_stripped.aimodel"))
> ```
>
> Two findings from the same thread that save time:
> **`coreai-build package`** re-emits the asset and updates the producer stamp *"but the IR locations
> are untouched"* — the repacked asset still fails. And **`coreai-build inspect` succeeding is not
> evidence a model will compile**: *"function signatures, inputs/outputs and states all print
> correctly. So the payload itself isn't corrupt; only the location metadata is in the pre-0.4.1
> form."*
>
> 🔴 **GAP** — whether `strip_debug_info` returns a new program or mutates in place is **unverified**;
> the maintainer's snippet calls it as a bare statement and says "modifies the program in place", but
> the reported implementation lives at `debug_info.py#L539` and was not read this session. **Safe
> default:** call it as a statement *and* keep the original binding, as above — that is correct under
> either behaviour.

### 9.7 The register

Nine defects, in one table, so you can check your own model against it:

| # | Defect | Wrong on | Fix status 2026-07-29 | Cheap workaround |
|---|---|---|---|---|
| 1 | fp16 `softplus`/`mish`/`logsumexp`/`logcumsumexp` overflow | ANE worst (`x≈10.4`), any fp16 | `apple/coreai-torch#22` open | Rewrite the module (§9.1) |
| 2 | Integer true-divide truncates | **every** backend | `apple/coreai-torch#32` merged 2026-07-29 | `a.float() / b` |
| 3 | `cat` on packed intx ignores `dim` | every backend | `apple/coreai-torch#41` open | `cat` before packing |
| 4 | int64→int32 accumulator narrowing in `sum`/`prod` | every backend | `apple/coreai-torch#45` **closed unmerged** | Reduce in fp32 |
| 5 | `optimize()` drops broadcast-significant axis moves | every backend (incl. `cpu_only`) | `apple/coreai-torch#49` open, FB23695952 | Skip `optimize()` or reorder |
| 6 | float→int→float cast round-trip folded to identity | every backend | `apple/coreai-torch#9` open | Avoid the round-trip idiom |
| 7 | GPU delegate runs `floor`/`trunc`/`ceil` as identity; `round` ties-away | **GPU only**; CPU correct | `apple/coreai-torch#10` open | `torch.div(x*2., 2., rounding_mode="floor")` |
| 8 | int64-comparison bool mask clobbers an unrelated live tensor | CPU **and** GPU | `apple/coreai-torch#11` open | Float-arithmetic masks (below) |
| 9 | Partial-rotary RoPE pairs contiguously, not half-split | every backend | `apple/coreai-models#66` open, known | Precompute `cos`/`sin` (§5.7) |

Two workarounds from that table are worth spelling out because they are non-obvious.

> ✅ **VERIFIED** — issue **#10**, reporter-measured on GPU: `floor`, `trunc` and `ceil` are executed
> as **identity**, and `round` uses **ties-away-from-zero** where PyTorch uses ties-to-even. **CPU is
> correct for all four**, so the same `.aimodel` computes different mathematics on different compute
> units. Also: `div(x, 1, rounding_mode="floor")` is **folded to identity at conversion time**, while
> `div(2x, 2, rounding_mode="floor")` is correct. Hence the workaround — a divisor of 1 is what
> triggers the fold, so multiply through:
>
> ```python
> floored = torch.div(x * 2.0, 2.0, rounding_mode="floor")   # exact in FP, and lowers correctly
> ```
>
> Reported impact, verbatim: *"Hit while porting RF-DETR — the deformable-attention sampling floor
> turned the whole decoder into noise on GPU while CPU was bit-clean."*

> ✅ **VERIFIED** — issue **#11**, the mask workaround, verbatim: *"Compute in-bounds masks in float
> arithmetic only — for integer-valued floats, `1 - (x - x.clamp(lo, hi)).abs().clamp(max=1)` is an
> exact 0/1 mask — and cast to int only at the gather index."* The defect it avoids is severe:
> an `int64` comparison → bool → float chain **corrupts an unrelated, still-live tensor elsewhere in
> the graph**, including a declared graph output, deterministically, on CPU and GPU, with
> `optimize()` off, and *"inserting `clone()`/`contiguous()` barriers does not protect the victim"*
> (see §2.6 for why). In a small graph the victim reads back NaN; in RF-DETR's full decoder the
> reporter measured *"plausible-looking garbage rather than NaN … **output cosine ~0.65 with no error
> raised**"*.

All nine are single-reporter community findings except #1 (which has an Apple maintainer response on
the sibling repo) and the four PR-backed ones (#2, #3, #4 and #1), whose *mechanisms* this guide
verified directly against Apple's shipped source. Treat the **mechanisms** as verified and the
**measured magnitudes** as community-measured.

---

## 10. The diagnostic checklist

### 10.1 Which class is it?

Start here. The first three questions take under a minute each and eliminate three of the four
classes.

```
Did add_exported_program() / add_pytorch_module() raise?
├─ YES, "contains non-decomposed ops"   ──────────► CLASS 3 · §3.2, §3.3
│     Fix: ep.run_decompositions(coreai_torch.get_decomp_table())
│
├─ YES, "contains unsupported ATen ops" ──┐
│                                          │  Is the base op name in supported-aten-ops.md
│                                          │  (or in _aten_to_core_resolver) under ANY overload?
│                                          ├─ YES ─────────────────► CLASS 2 · §4
│                                          └─ NO  ─────────────────► CLASS 1 · §7
│
└─ NO
   │
   Did to_coreai() raise "Unsupported ATen op: …" (short form, no "exported program contains")?
   ├─ YES ──► CLASS 1 or 2, INSIDE an externalized submodule · §3.5, §8.3
   │           The body was decomposed with the DEFAULT table, not yours.
   │
   └─ NO — conversion succeeded
      │
      Do the numbers match eager PyTorch, within tolerance, on the SAME input?
      ├─ YES ──► run the other three gates (§10.2) before you believe it
      └─ NO  ──► CLASS 4 · §9, §10.3
```

### 10.2 The four gates every converted model should pass

Every single silent miscompile in §9 was found by one of these four A/Bs. Run all four; they are
cheap relative to what they find, and each one catches a defect class the others cannot.

| Gate | What you compare | Catches |
|---|---|---|
| **A · Eager vs Core AI** | `model(x)` vs the `.aimodel`'s output for the same `x` | Lowering arithmetic (§9.1–9.4), composite mismatch (§5.5, §5.7) |
| **B · `optimize=True` vs `optimize=False`** | Two assets from the same `AIProgram`, one optimized | Optimizer-introduced miscompiles (§9.5) |
| **C · CPU vs GPU vs ANE** | The *same* `.aimodel`, three `SpecializationOptions` | Delegate divergence (§9.5, issue #10), ANE fp16 (§9.5) |
| **D · Token-exact greedy oracle** (LLMs only) | Greedy generation vs an fp32 reference, token by token | Everything above, compounded over many steps |

Gate C's harness, assembled from the API surface confirmed across issues #51 and #10:

```python
"""Gate C: run one .aimodel on CPU, GPU and Neural Engine and diff the outputs.

Verified API surface: SpecializationOptions.cpu_only(),
SpecializationOptions.from_preferred_compute_unit_kind(ComputeUnitKind.gpu() /
.neural_engine()), AIModel.load(path, options), model.load_function("main"),
awaiting the function with a dict of NDArray.
"""

import asyncio
from pathlib import Path

import numpy as np
import coreai.runtime as rt


async def compare_units(asset_path: Path, inputs_np: dict[str, np.ndarray]) -> None:
    units = {
        "cpu": rt.SpecializationOptions.cpu_only(),
        "gpu": rt.SpecializationOptions.from_preferred_compute_unit_kind(
            rt.ComputeUnitKind.gpu()
        ),
        "ane": rt.SpecializationOptions.from_preferred_compute_unit_kind(
            rt.ComputeUnitKind.neural_engine()
        ),
    }
    nd_inputs = {k: rt.NDArray(v) for k, v in inputs_np.items()}

    results: dict[str, dict[str, np.ndarray]] = {}
    for name, opts in units.items():
        model = await rt.AIModel.load(asset_path, specialization_options=opts)
        out = await model.load_function("main")(nd_inputs)
        results[name] = {k: v.numpy().astype(np.float32) for k, v in out.items()}

    ref = results["cpu"]
    for unit in ("gpu", "ane"):
        for key, arr in results[unit].items():
            d = np.abs(arr - ref[key])
            rel_l2 = np.linalg.norm(arr - ref[key]) / (np.linalg.norm(ref[key]) + 1e-12)
            print(f"{unit:4s} {key:20s} max|d|={d.max():.6g}  relL2={rel_l2:.6g}")


asyncio.run(compare_units(Path("model.aimodel"), {"image": np.random.randn(1, 3, 224, 224).astype(np.float16)}))
```

> ⚠️ **Design your gate inputs to break symmetry.** Issue #49 miscompiles on square/equal-length
> inputs and is *correct* on 17×23. Issue #9's cast round-trip is an identity on values that happen
> to be integral. A gate that only ever sees `torch.randn(1, 3, 224, 224)` will miss both. **Use
> asymmetric shapes, values that straddle zero, values above 10 (§9.1's threshold), and integer
> tensors large enough to overflow int32 (§9.4) where your model actually has them.**

### 10.3 Which tool finds which class

| Symptom | Class | Tool | Where |
|---|---|---|---|
| Error names ops at staging time | 1 · 2 · 3 | The error text + the registry query (§2.5, §4.2) | this guide |
| Not sure which overloads you produced | 2 | `graph_targets()` (§4.1) or `coreai_torch._utils.print_graph(ep)` | this guide |
| Not sure whether a composite survived | 4 (perf) | `tools/freqop/freqop.py` — counts `composite.<name>` rows | §10.4 |
| Two assets that should be identical are not | 2 · 4 | `tools/graphdiff/graphdiff.py`, or `coreai_torch.debugging.graph_diff` | §10.4 |
| NaN or Inf appears somewhere | 4 | `coreai_torch.debugging.validator` — bisection over the graph | Part 10 |
| Numbers drift and you need the first divergent op | 4 | `coreai_torch.debugging.comparator` — PyTorch ↔ Core AI, per-op | Part 10 |
| You need per-op tensors from a **deployed** model | 4 | `coreai_torch.debugging.inspector.CoreAIInspector` | Part 10 |
| You need a PyTorch reference trace to compare against | 4 | `debugging.torch_utils.save_intermediates` → the Core AI Debugger app | Part 10 |
| You want a visual, source-linked divergence hunt | 4 | **Core AI Debugger** app, sync points, PSNR metric | Part 10 |
| An op is slow but correct | perf | `debugging.benchmarker.benchmark_coreai_program` | Part 10 |

Everything in the bottom half of that table lives in
[Part 10, the hardware-authoring and debugging part](../../part-10-coreai-hardware-authoring-debugging/README.md),
which covers the Core AI Debugger app, the `coreai_torch.debugging` module in full (it is almost
entirely `async`), and the ANE/GPU authoring rules. Two preview-era environment variables gate the
metadata those tools need:

> ✅ **VERIFIED** — `docs/api/debugging.md:5-13`, verbatim: *"During the current preview, set the
> following environment variables to ensure **operation-level debug metadata is preserved** and
> available to these tools"*:
>
> ```bash
> export USE_LOCAL_COREAI=1
> export ENABLE_DEBUG_INFO=1
> ```
>
> Without them, module-stack and source-location metadata — the thing that makes the debugger's
> navigator and source viewer work — may be missing. Neither variable is read anywhere in
> `coreai-torch`'s own Python; they are consumed by `coreai-core`.

### 10.4 The two CLI tools that belong in your export script

Both live under `tools/` in the `coreai-torch` checkout and are run as plain scripts — they are
**not** console entry points (there is no `[project.scripts]` in `pyproject.toml`).

**`freqop` — did my composite actually happen?**

> ✅ **VERIFIED** — `tools/freqop/README.md`:
>
> ```text
> usage: freqop [-h] [--plot] FILE [FILE]
>
> positional arguments:
>   FILE        AIModel asset to analyze (.aimodel)
>   FILE        optional second AIModel asset to compare against
> ```
>
> It counts `coreai.*` ops, and — this is the useful part — **composite ops (graphs with a
> `composite_decl`) are reported as `composite.<name>`**, e.g. `composite.layer_norm`,
> `composite.scaled_dot_product_attention`. Two-file mode prints a Delta column and marks differing
> ops with `*`.

That gives you a one-command answer to "did my `ExternalizeSpec` take effect", and a two-file diff
that answers "what changed when I bumped the package". `--plot` needs matplotlib, which is not a
declared dependency.

**`graphdiff` — are these two models structurally the same?**

> ✅ **VERIFIED** — `tools/graphdiff/README.md`:
>
> ```text
> usage: graphdiff [-h] [--entry-point NAME] [--max-items N] [--output FILE] SOURCE TARGET
> ```
>
> Exit codes: **`0` isomorphic, `1` structural differences, `2` input error** — so it drops straight
> into CI. Composite-aware by default: it diffs `main` vs `main` and matches composite sub-graphs via
> paired `coreai.invoke` callees (e.g. `@sdpa_abc123` ↔ `@sdpa_def456`), diffs each, and reports
> unmatched ones. `--output FILE` writes HTML when the extension is `.html`.

The callee-pairing behaviour is exactly what you need given §8.3's UUID suffixes — the tool already
knows the names are random.

### 10.5 A conversion gate you can paste into CI

```python
"""Minimal conversion gate. Fails loudly on the things that otherwise fail silently.

Covers: composites present, optimize() is semantics-preserving for this model,
eager parity. Add gate C (compute units) and gate D (greedy oracle) as your
model demands.
"""

import asyncio
import tempfile
from pathlib import Path

import numpy as np
import torch

import coreai_torch
from coreai.runtime import NDArray
from coreai_torch import ExternalizeSpec, TorchConverter

REQUIRED_COMPOSITES = ("rms_norm", "rope", "scaled_dot_product_attention")


def build(model, sample, specs, *, optimize: bool):
    converter = TorchConverter().add_pytorch_module(
        model,
        export_fn=lambda m: torch.export.export(m, args=sample).run_decompositions(
            coreai_torch.get_decomp_table()
        ),
        externalize_modules=specs,
        input_names=["x"],
        output_names=["y"],
    )
    program = converter.to_coreai()
    if optimize:
        program.optimize()
    return program


async def run(program, x: np.ndarray) -> np.ndarray:
    with tempfile.TemporaryDirectory() as tmp:
        asset = program.save_asset(Path(tmp) / "gate.aimodel")
        async with asset.executable() as ai_model:
            fn = ai_model.load_function("main")
            out = await fn({"x": NDArray(x)})
            return out["y"].numpy()          # materialize INSIDE the block


async def gate(model, sample, specs):
    x = sample[0].numpy()

    prog_opt = build(model, sample, specs, optimize=True)
    prog_raw = build(model, sample, specs, optimize=False)

    # 1. Composites survived externalization (§8.7a — a typo only warns).
    ir = str(prog_opt)
    for name in REQUIRED_COMPOSITES:
        assert f'composite_declaration<"{name}"' in ir, f"missing composite: {name}"

    y_opt = await run(prog_opt, x)
    y_raw = await run(prog_raw, x)

    # 2. optimize() did not change the math (§9.5).
    d_opt = np.abs(y_opt.astype(np.float32) - y_raw.astype(np.float32)).max()
    assert d_opt < 1e-3, f"optimize() changed the result: max|d| = {d_opt:g}"

    # 3. Eager parity. atol=1e-2 is coreai-torch's own default "because FP16
    #    accuracy is flaky" — tighten it if your model is fp32.
    with torch.no_grad():
        y_torch = model(*sample).numpy()
    assert np.allclose(y_torch, y_opt, atol=1e-2), (
        f"eager parity failed: max|d| = {np.abs(y_torch - y_opt).max():g}"
    )
    print("gate: OK")
```

> The `atol=1e-2` is not a shrug — it is `coreai-torch`'s own default in
> `tests/utils.py::validate_numerical_output`, with the stated reason *"FP16 accuracy is flaky"*.
> That helper is worth reading in full if you are building a serious harness; it supports two modes
> (end-to-end from `model=`, or pre-converted from `coreai_program=` + `torch_out=`) and takes
> `dynamic_shapes`, `state_names`, `num_calls`, `remove_decomps`, `run_optimize_passes`,
> `custom_kernels` and `metal_inputs`.

---

## 11. Quick reference

### 11.1 API surface used in this guide

```python
# Public, from coreai_torch
from coreai_torch import (
    ExternalizeSpec,           # dataclass: target_class, composite_op_name, composite_attrs
    MetalParameter,            # re-exported from coreai.authoring
    TorchConverter,
    TorchMetalKernel,
    generate_composite_decl,   # (context, composite_name, input_names, output_names, op_attributes, version=1)
    get_decomp_table,          # -> dict, a fresh copy each call
)

# Public, from coreai_torch.composite_ops
from coreai_torch.composite_ops import (
    GatherMM,                  # MoE expert dispatch
    GatedDeltaUpdate,          # linear-attention / SSM recurrence
    RMSNorm,                   # convenience WRAPPER — never an externalization target
    RMSNormImpl,               # the actual composite target
    RoPE,
    SDPA,
)

# Underscore-private, but used by Apple's own documentation and code
from coreai_torch._utils import get_operand, get_operands, print_graph
from coreai_torch._aten_to_core import _aten_to_core_resolver     # diagnostics only

# Private upstream — pin coreai-core
from coreai._compiler.dialects import coreai
```

`TorchConverter`, with the **real** signatures (keyword-only markers included):

```python
TorchConverter(*, mode: TorchConverter.Mode = Mode.DEBUG)   # Mode.DEBUG | Mode.RELEASE

.add_exported_program(ep, *, input_names=None, output_names=None,
                      state_names=None, entrypoint_name="main") -> Self
.add_pytorch_module(model, *, export_fn, externalize_modules=None,
                    input_names=None, output_names=None,
                    state_names=None, entrypoint_name="main") -> Self
.register_torch_lowering(qualified_name: str, allow_override: bool = False) -> Callable
.register_custom_kernels(kernels: Sequence[TorchMetalKernel]) -> Self
.to_coreai(*, entrypoints: Sequence[str] | None = None) -> AIProgram
.clear(*, entrypoints: Sequence[str] | None = None) -> None    # lowerings always preserved
```

> ⚠️ `docs/api/TorchConverter.md` renders the naming parameters and `export_fn` **positionally**.
> The source has a `*`. Code written from the doc raises `TypeError`. Also undocumented in that
> file: the `mode=` constructor parameter.

### 11.2 The composite inventory, one screen

| Composite name in IR | How you get it | Attributes |
|---|---|---|
| `gather_mm` | `GatherMM` + spec | `num_batch_axes` |
| `gated_delta_update` | `GatedDeltaUpdate` + spec | `use_qk_l2_norm` (doc) / **`[]`** (Apple's shipping list) |
| `rms_norm` | `RMSNormImpl` + spec | `axes`, `eps` |
| `rope` | `RoPE` + spec | `scale`, `base`, `dims`, `interleaved` |
| `scaled_dot_product_attention` | `SDPA` + spec, **or** `aten.scaled_dot_product_attention` | `scale`, `is_causal`, `window_size` — but the ATen path always emits `is_causal=False, window_size=0` |
| `batch_norm` | `nn.BatchNorm*` in `.eval()` | `eps` |
| `group_norm` | `torch.group_norm` | `num_groups`, `num_channels`, `eps` |
| `layer_norm` | `F.layer_norm` | `axes`, `eps` |
| `instance_norm` | `F.instance_norm` **with `use_input_stats`** | `eps` |
| `hard_sigmoid` | `F.hardsigmoid` | — |
| `log_softmax` | `F.log_softmax` | `axis` |
| `linalg_vector_norm` | `torch.linalg.vector_norm` | `ord`, `axes`, `keep_dim` |
| `pixel_shuffle` | `F.pixel_shuffle` | `upscale_factor` |

Every one also carries `version` (always `1`).

### 11.3 The rules that prevent the failures in this guide

1. **Always `run_decompositions(get_decomp_table())`.** Never the raw default table — it decomposes
   too much and creates unsupported overloads. §3.3
2. **Check the registry, not the docs**, when an error and the documentation disagree. The docs are a
   lower bound. §2.5
3. **Register ATen lowerings before `add_exported_program`.** Custom-namespace lowerings can go
   after, but there is no reason to rely on that. §7.5
4. **`target_class=RMSNormImpl`, never `RMSNorm`.** §5.6
5. **Assert on the emitted IR** that each composite you asked for is present — an unmatched
   `ExternalizeSpec` only warns. §8.7a
6. **All composite `forward` args are tensors**; scalars are instance attributes named in
   `composite_attrs`; optionals are `torch.Tensor | None = None`. §8.4
7. **Pass a fresh dict to `generate_composite_decl`** — it writes `version` into yours. §7.6
8. **Re-validate attention at decode length**, not just prefill: `composite_ops.SDPA` is lower-right
   causal, `F.scaled_dot_product_attention` is upper-left. §5.5
9. **RoPE `position_ids` and `freqs` must be fp32**, and if `partial_rotary_factor < 1`, precompute
   `cos`/`sin`. §5.7
10. **Run all four numerics gates**, with asymmetric shapes and values that straddle the fp16 danger
    zone. §10.2
11. **Cast to float before dividing integers**, and reduce integer `sum`/`prod` in fp32, until PRs
    #32 and #45 land. §9.2, §9.4
12. **Do every `cat` before sub-byte packing.** §9.3
13. **Do not pattern-match externalized graph symbol names** — they carry a random 8-hex suffix. §8.3
14. **Pin `coreai-core`.** Every custom lowering depends on private `coreai._compiler` API.

### 11.4 Error-message index

| Message (excerpt) | Raised by | Section |
|---|---|---|
| `The exported program contains non-decomposed ops: …` | `_validate.py` at staging | §3.2 |
| `The exported program contains unsupported ATen ops: …` | `_validate.py` at staging | §3.4, §4 |
| `Unsupported ATen op: {target}. Use register_torch_lowering()…` | `converter.py` at `to_coreai()` | §3.5 |
| `Your model failed to export: …` | `add_pytorch_module` | §3.4 |
| `qualified_name must be 'namespace::op_name', got …` | `register_torch_lowering` | §7.3 |
| `{name!r} is already registered; set allow_override=True to replace it` | `register_torch_lowering` | §7.3 |
| `ExternalizeSpec: ['composite_attrs'] can only be set when composite_op_name is provided.` | `ExternalizeSpec.__post_init__` | §8.2 |
| `externalize_modules: the following target class(es) did not match…` (**warning**) | `_mark_externalize` | §8.7a |
| `[WARN] coreai_torch.externalize: skipping unused submodule…` (**warning**) | `_PreparedModules` | §8.7b |
| `Expected argument {i} … to be a Tensor … Only Tensor inputs are supported` | externalize phase 2 | §8.3 |
| `Internal error: failed to export submodule '…': Constraints violated` + *"This is a coreai-torch bug"* | externalize phase 3 | §8.7d |
| `Unsupported value provided in composite declaration {v}.` | `generate_composite_decl` | §7.6 |
| `A program with entrypoint_name=… is already staged.` | `add_exported_program` | §8.6 |
| `No programs to convert. Call add_exported_program() or add_pytorch_module() first.` | `to_coreai` | — |

---

## 12. Sources and evidence ledger

### Primary — Apple source read directly off disk this session (strongest class available)

**`apple/coreai-torch` @ commit `4529671`, `__version__ = "0.4.1"`**
(`/Volumes/ExtStor/FM and MLX and CoreAI/repos/apple__coreai-torch`):

- `docs/api/supported-aten-ops.md` — read in full (177 lines). The overload rule (§2.2) is quoted
  verbatim from line 7.
- `docs/api/composite-ops.md`, `docs/api/composite-ops/{module-class,aten-derived,gather-mm,
  gated-delta-update,rms-norm,rope,sdpa,batch-norm,group-norm,layer-norm,instance-norm,
  hard-sigmoid,log-softmax,linalg-vector-norm,pixel-shuffle}.md` — the full composite inventory
  and every attribute schema in §5.2–5.3 and §11.2.
- `docs/api/ExternalizeSpec.md` — §8.1, §8.2.
- `docs/guides/externalization.ipynb`, `docs/guides/custom-op-lowering.ipynb` — every worked example
  in §7.2, §7.3 and §8.1 is verbatim from these notebooks.
- `docs/api/generate-composite-decl.md` and `docs/api/debugging.md` — §7.6, §10.3.
- `coreai_torch/_validate.py` (full), `coreai_torch/_decomp.py` (full),
  `coreai_torch/externalize.py` (lines 1–200, 360–450), `coreai_torch/_composite_declaration.py`
  (`generate_composite_decl`), `coreai_torch/converter.py`
  (`_handle_call_function_op`, `register_torch_lowering`, `register_custom_kernels`),
  `coreai_torch/_utils.py` (`get_target`, `get_namespace`, `strip_variant_from_target`,
  `get_operand`, `get_operands`, `get_output_element_type_from_node`, `_NARROW_TORCH_DTYPE`,
  `print_graph`, `build_hard_sigmoid_composite`),
  `coreai_torch/_aten_to_core.py` (`replace_binary_ops`, `replace_truediv`,
  `replace_sum_dim_intlist`, the resolver table),
  `coreai_torch/_compression/_intx.py` (`__torch_dispatch__`'s `cat` branch),
  `coreai_torch/composite_ops/{_sdpa,_rope,_rms_norm,_gated_delta_update,__init__}.py`.
- `tools/graphdiff/README.md`, `tools/freqop/README.md`, `pyproject.toml`, `CONTRIBUTING.md`.

**`apple/coreai-models`** (`/Volumes/ExtStor/FM and MLX and CoreAI/repos/apple__coreai-models`):

- `python/src/coreai_models/export/macos.py` — `_EXTERNALIZE_SPECS` (§8.5) and the
  register-after-staging ordering (§7.5), both quoted verbatim.
- `python/src/coreai_models/export/mlir_ops.py` — read in full; the only non-toy
  `register_torch_lowering` call site in the corpus (§7.7).
- `python/src/coreai_models/primitives/macos/switch.py`,
  `python/src/coreai_models/models/macos/{qwen3_moe,mixtral,gpt_oss}.py` — the `GatherMM` →
  `SwitchLinear` → `SwitchGLU` → three shipping MoE models chain (§6.3).
- `skills/skills/model-authoring/SKILL.md` and
  `skills/skills/model-authoring/references/{gpu_rules,neural_engine_rules}.md` — Apple's own
  empirical rules; §6.1, §8.6.

### Secondary — research notes in this corpus

- `notes/repos/coreai-torch.md` — the deep-dive on the package; used for cross-checking every source
  claim above and for the material on `_custom_to_core_resolver`, `check_result_type`, the
  `TorchConverter.__repr__` form, `tests/utils.py::validate_numerical_output`, and the doc/source
  drift catalogue.
- `notes/repos/issues-coreai-stack.md` — every issue and PR cited in §9 and §6.3, read live via `gh`
  on 2026-07-27: `coreai-torch` #1, #2, #5, #6, #9, #10, #11, #21, #37, #44, #49, #51 and PRs #7,
  #13, #18, #22, #29, #32, #40, #41, #45; `coreai-optimization` #7; `coreai-models` #66, #118 and
  PR #69. States re-checked via `gh` 2026-07-29.
- `notes/transcripts/coreai-python-metal.md` — WWDC26 session 325, *"Dive into Core AI model
  authoring and optimization"* (Sachin and Nicole). Used only for framing quotes in §8.6; every
  API-shaped claim from the session was checked against source before use.
- `notes/repos/mlx2coreai.md` — a **community** converter (`lucasnewman/mlx2coreai`) that emits the
  same composite declarations from MLX rather than PyTorch. Cited nowhere as authority; it
  independently corroborates the `composite_declaration` textual form, the `-1e4` causal-mask
  constant, the `MutableBuffers.buffer_mutation` argument attribute, and the int64→int32 narrowing
  policy. Its own gotcha list is a useful sanity check on what is intrinsic to Core AI versus
  specific to `coreai-torch`.

### Attribution of numbers

| Number | Class | Provenance |
|---|---|---|
| Prompt 1066.4→1103.7 tok/s, generation 62.1→69.2 tok/s (Qwen3-MoE) | **Apple-published** | `coreai-models` PR #69. **Hardware and OS build not stated in the PR** — the ~11% delta is the citable part, not the absolutes |
| MobileNetV3 vs V2 ANE fp16 divergence (0.199 vs 0.0027 max abs) | **Community-measured** | `coreai-torch`#51, single reporter `zli96`, macOS 27 beta 3, coreai-torch 0.4.1, 2026-07-23 |
| `optimize()` miscompile 1.02e+01 vs 1.9e-06; 17 dB vs 78–85 dB PSNR | **Community-measured** | `coreai-torch`#49, `dkomoroske`, macOS 27.0 `26A5378j`/`26A5388g`, torch 2.11.0, 2026-07-23, FB23695952 |
| fp16 overflow thresholds (10.4 / 7.63 / 11.09) | **Community-measured** | `coreai-torch`#21, `Ashutosh0x`, macOS 26 / Apple silicon, PyTorch 2.7+, 2026-06-21 |
| Partial-rotary RoPE PSNR ≈ 21.6 dB, max-abs ≈ 8.2 | **Community-measured** | `coreai-models`#66, `kylejfrost`; maintainer acknowledged the defect, not the number |
| Prefix reuse 23.28 s → 0.230 s (101×); 15.2× at 357 tokens | **Community-measured**, uncontrolled | qwen3-0.6b on a Mac, 2026-06; single author, self-declared uncontrolled benchmarks. Directionally strong, absolutely unanchored |
| RF-DETR decoder output cosine ≈ 0.65 under issue #11 | **Community-measured** | `coreai-torch`#11, `john-rocky`, M4 Max, macOS 27.0 `26A5353q` |

No number in this guide is presented as an Apple figure unless the row above says so.

### Where sources disagreed, and how this guide ruled

| Conflict | Ruling |
|---|---|
| `docs/api/TorchConverter.md` shows naming params and `export_fn` positionally; the source has `*` | **Source wins.** Keyword-only. §8.2, §11.1 |
| `docs/api/generate-composite-decl.md` says the 2nd param is `op_name` and returns a `CompositeDeclaration`; source says `composite_name` and returns an `Attribute` | **Source wins.** §7.6 |
| `supported-aten-ops.md` omits `atan2.default` and `masked_scatter.default`, which are in the resolver | **Source wins.** The doc is a lower bound. §2.5 |
| `gated-delta-update.md` example uses `composite_attrs=["use_qk_l2_norm"]`; Apple's shipping `_EXTERNALIZE_SPECS` uses `[]` | **Neither is provably wrong.** Declared as an open GAP; recommendation is to copy the shipping form. §8.5 |
| Apple's skill labels the ANE embedding table "externalized"; the detailed reference describes a **separate export with its own entrypoint** | **Detailed reference wins.** Two mechanisms, one word — the guide names both and points each intent at the right API. §8.6 |
| WWDC26 325 says composites are "pre-packaged fast kernels" with no measured benefit; no A/B exists anywhere | Kept as mechanism, declared as a GAP on magnitude. §8.6 |
| Session 325 frames the multi-entrypoint split as a latency trick; the optional `coreai-models` loader also maps recognized structures to its ANE preference | Package policy, not a Core AI framework contract; deferred to Parts 7 and 10. §8.6[^sample-routing-policy] |
| `coreai-torch`#8 was closed completed on 2026-09-14 after the fix merged in #13; a maintainer reconfirmed all four float-`arange` forms on coreai-torch 0.4.2 | Not relied on in this guide either way |

### Declared gaps — nothing is guessed inside these

- **Whether `validate_exported_program` re-runs on the phase-1 re-exported program** in the
  externalization path. Safe default given: trust the `to_coreai()`-time error for externalized
  models. §3.5
- **Which `composite_attrs` the Core AI compiler's `gated_delta_update` pattern expects.** Safe
  default given: copy Apple's shipping `[]`. §8.5
- **`HardwareConstraints` semantics** — `AllocationType`, `alignments`, `interleave`, and which
  values suit which compute unit. Safe default given: copy Apple's two working configurations
  verbatim and A/B. §7.7
- **What externalizing a composite is worth**, in latency or energy. No Apple or community number
  exists. Safe default given: externalize as Apple does, but promise nothing. §8.6
- **Whether `strip_debug_info` returns a new program or mutates in place.** Safe default given: a
  call form that is correct either way. §9.6
- **The full `CorePasses` catalog behind `AIProgram.optimize()`**, and whether `optimize()` takes
  arguments. Only three pass names are attested (`_CORE_OPTIMIZE`, `_UPDATE_SIGNATURE_TO_HANDLES`,
  `_PROPAGATE_HANDLE_UPDATES`, from a deleted test helper) plus two from a crash report
  (`legalize-to-core`, `core-to-odix`). Consequence for this guide: §9.5's advice is "A/B it", not
  "disable pass X".

### Not used as evidence

- Any claim about a `coreai-torch convert` CLI, a `.coreaimodel` or `.aiasset` file extension, an
  "iOS 20 / macOS 17", or an on-device LoRA training API. All four are fabrications in circulation;
  none exists. The conversion entry point is the `TorchConverter` **class**, the artefact is an
  `.aimodel` **directory**, and the OS line is 27.
- The `coreai-models` PyPI wheel. Maintainer @tjia1818, verbatim: *"the wheel on the pypi.org is not
  to be used, it's just a stub."* Use a source checkout.

[^sample-routing-policy]: The classifier and preferences are implemented in the optional
    `apple/coreai-models` package’s pinned
    [`ModelStructure.swift`](https://github.com/apple/coreai-models/blob/5ed9981303b38d5a44aa6b45509bc4f6945029f5/swift/Sources/CoreAIShared/Runtime/ModelStructure.swift#L12-L218).
    Core AI’s `.default` behavior is documented separately in
    [Managing model specialization and caching](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/docs/Managing%20model%20specialization%20and%20caching.md).
