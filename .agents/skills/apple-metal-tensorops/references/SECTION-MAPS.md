# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 11 — Metal and TensorOps

### 11.1 — TensorOps: `matmul2d`, tensor types, and what quantization actually looks like

The ground floor, written header-first: the two namespaces and where each physically lives, the seven positional arguments of `matmul2d_descriptor`, the complete execution-scope vocabulary, the three tensor construction tags, cooperative tensors, and reductions.

**Local reference:** [part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md](part-11-metal-and-tensorops/references/01-tensorops-and-quantized-operands.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 0. How this guide was verified — and why sources must be version-scoped | `#0-how-this-guide-was-verified--and-why-sources-must-be-version-scoped` |
| 1. The version story: two ladders, both true | `#1-the-version-story-two-ladders-both-true` |
| 2. Two namespaces, two headers, two `tensor` types | `#2-two-namespaces-two-headers-two-tensor-types` |
| 3. `matmul2d_descriptor` — seven positional arguments | `#3-matmul2d_descriptor--seven-positional-arguments` |
| 4. Execution scopes — the complete vocabulary | `#4-execution-scopes--the-complete-vocabulary` |
| 5. Tensors: `tensor_handle`, `tensor_offset`, `tensor_inline` | `#5-tensors-tensor_handle-tensor_offset-tensor_inline` |
| 6. Cooperative tensors | `#6-cooperative-tensors` |
| 7. Reductions and iterator mapping | `#7-reductions-and-iterator-mapping` |

### 11.2 — Cooperative tensors, reductions, and building a fused attention kernel

The advanced guide, and the longer of the two.

**Local reference:** [part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md](part-11-metal-and-tensorops/references/02-cooperative-tensors-and-flash-attention.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| §0 — Evidence, versions, and where the files are | `#0--evidence-versions-and-where-the-files-are` |
| §1 — Why cooperative tensors exist | `#1--why-cooperative-tensors-exist` |
| §2 — What a cooperative tensor actually is | `#2--what-a-cooperative-tensor-actually-is` |
| §3 — The asymmetry: element types vs operand types | `#3--the-asymmetry-element-types-vs-operand-types` |
| §4 — Feeding a cooperative tensor into a matmul | `#4--feeding-a-cooperative-tensor-into-a-matmul` |
| §5 — Reading and writing elements | `#5--reading-and-writing-elements` |
| §6 — Reductions | `#6--reductions` |
| §7 — `map_iterator` and `is_iterator_compatible` | `#7--map_iterator-and-is_iterator_compatible` |
| §8 — Building FlashAttention, step by step | `#8--building-flashattention-step-by-step` |
| §9 — The assembled kernel | `#9--the-assembled-kernel` |
| §10 — The host side you cannot skip | `#10--the-host-side-you-cannot-skip` |
| §11 — The expert escape hatch: what MLX does instead | `#11--the-expert-escape-hatch-what-mlx-does-instead` |
| §12 — Getting the kernel into a model | `#12--getting-the-kernel-into-a-model` |
| §13 — ⚠️ Freshness: NAX is new and still settling | `#13--️-freshness-nax-is-new-and-still-settling` |
| §14 — Performance: the three things that actually move the number | `#14--performance-the-three-things-that-actually-move-the-number` |
