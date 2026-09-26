# DNIKit: auditing datasets and networks before you convert

**Part 16 · Adjacent capabilities · Reference 05**

**Version floor: DNIKit `2.0.0` (all three distributions pinned together), plus `main` at commit
`2f39056` (2026-07-09).** There is no OS floor, because **nothing in this guide runs on a device**.
DNIKit is a pure-Python desktop toolkit: it never touches iOS 27, macOS 27, Xcode 27, Core AI,
Foundation Models, MLX or Metal. Its own floors, read from `src/dnikit/pyproject.toml` this
session, are **`requires-python = ">=3.7"`**, with **Python 3.9 recommended by Apple's own install
docs** and **Python 3.9.7 explicitly broken**. If you want the TensorFlow 1 backend you are pinned
to **Python ≤ 3.7, `numpy<1.19`, `protobuf<4.0`, `Keras<2.4`, `h5py<3.0`, `tensorflow<2.0`**.

---

## This is the shortest guide in the series, on purpose

Every other guide in these seventeen parts assumes your model is good and asks how to deploy it.
Part 8 converts it. Part 9 compresses it. Part 10 routes it to the right compute unit. Part 15
ships it. This guide asks a question none of the others do: **is your data any good, and is your
network the size it actually needs to be?**

That question is genuinely worth asking before you spend a day on conversion and quantization. It
is also, in 2026, almost entirely disconnected from everything else in this series. Here is the
honest evidence position, stated once and up front:

- **Our entire evidence base is one repository** — `apple/dnikit`, cloned `--depth 50`.
- **There is no WWDC session on DNIKit.** Not in 2025, not in 2026, not in our transcript corpus.
- **There is no Apple developer documentation page.** The docs are a Sphinx site the repo builds
  itself, published to `apple.github.io/dnikit`.
- **There is no Core AI integration, no `.aimodel` awareness, no Core ML support, no MLX support,
  and no Swift.** `coremltools` appears nowhere in the tree; neither does `mlx`.
- **The repo's own `CONTRIBUTING.md` says so plainly**, verbatim: *"This project was released to
  share our work and support our publications in this area, but there are limited plans for future
  development of the repository."*

So: **you can skip this guide entirely unless you have a data-quality problem.** If your training
set is clean, deduplicated, and you already know your layer widths are right, close this file and
go read [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md). Nothing later in the series depends
on anything here.

If, on the other hand, you have inherited a dataset of unknown provenance, or you are about to
spend a week quantizing a network that might be 3× wider than it needs to be — DNIKit is a real,
working, Apache-2.0 toolkit that will tell you both things in an afternoon. That is the case this
guide is written for.

### The freshness signal, and what it tells you about fit

`git log --format='%H %ad %an %s' --date=iso` on the clone returns exactly three commits at depth
50. ✅ **VERIFIED** (`notes/repos/dnikit.md` §"Last 3 commits", read from the clone at
`repos/apple__dnikit`):

```
2f39056311d6e0fbbe4e5f73da3767a5b5070dac  2026-07-09  Kiwi                Handle Keras 3 tensor metadata in TF2 models (#4)
b44b14f87507b0d305b7cc7bbcf7f091717485da  2023-09-06  Megan Maher Welsh   Remove frozen requirements file.
e9f4a9a8380b628a36b68b2251724a9adfab1b21  2023-07-25  Megan Maher Welsh   DNIKit 2.0.0 Release.
```

Read that carefully. The project shipped 2.0.0 in July 2023, went quiet for **almost three years**,
and its single 2026 commit is a **Keras 3 tensor-metadata fix**. Nothing about MLX. Nothing about
Core AI. Nothing about Apple silicon. The centre of gravity of this toolkit is **TensorFlow 2 and
Keras**, which is not where the rest of this series lives — Parts 8 through 10 are PyTorch-first,
Parts 12 and 13 are MLX.

That is not a reason to dismiss the tool. `Duplicates`, `Familiarity` and `PFA` are framework-
agnostic once you have activations in a NumPy array, and §5.3 shows the escape hatch Apple
documents for exactly that. But it *is* a reason to expect friction: the sample models are
`tf.keras.applications`, the sample datasets are `tf.keras.datasets`, and the one path Apple keeps
alive is the TF2/Keras one.

---

## What this covers

- **§1 — Should you read this at all.** A five-line decision, and the one workflow where the answer
  is unambiguously yes.
- **§2 — Install, versions, and the environment that actually works.** Three version-locked
  distributions, five extras, one packaging bug, and a Python release that is specifically broken.
- **§3 — Producer → PipelineStage → Introspector.** The architecture, and *why* it is shaped that
  way: lazy streaming over datasets too large to hold in memory. Plus the four places DNIKit
  abandons streaming and loads everything into RAM anyway.
- **§4 — `Batch`.** The universal container: fields, snapshots, metadata, standard keys, and the
  frozen-array invariant that bites PyTorch users.
- **§5 — `Model` and the framework backends.** What TF2/Keras 3 supports, what TF1 supports, why
  the PyTorch package is data-adaptors-only, and the fact that **Core ML is not supported at all**.
- **§6 — The introspectors.** `DimensionReduction`, `Familiarity`, `Duplicates`, `IUA`, and
  **`PFA` — Principal Filter Analysis**, which is the reason a compression engineer should care.
  Plus `DatasetReport`, which bundles four of them into one pandas DataFrame.
- **§7 — One complete worked example, end to end.** CIFAR-10 through MobileNet, cached, reduced,
  audited for duplicates and rare data, then a PFA recipe. Runnable top to bottom.
- **§8 — The pre-flight workflow for Parts 8–10.** Audit the dataset, audit the network, prune,
  *then* convert. With the handoff points named.
- **§9 — What is explicitly not here.** So you do not go looking.
- **§10 — Consolidated footguns.**
- **§11 — Declared gaps.**

## What this does *not* cover

- **Symphony**, the interactive UI that consumes `DatasetReport`'s DataFrame. It lives in a
  different repository (`apple/ml-symphony`) that we did not clone. §6.6 documents the column
  contract DNIKit emits; the widget API is a declared gap (§11, G6).
- **The PFA paper's mathematics.** We cite it (§6.5) and describe the strategies operationally.
  The derivation is in the WACV 2020 paper.
- **Anything on-device.** For evaluating a *shipping* model's quality, you want
  [Part 6 — Evaluations](../../part-06-evaluations/README.md), which is a completely different framework
  with a completely different purpose. DNIKit runs before training finishes; Evaluations runs after
  the app is built.

## What you need

- **macOS or Linux.** ✅ VERIFIED (`docs/general/installation.rst`): *"DNIKit currently supports
  Python version 3.7 or greater for macOS or Linux. Python 3.9 is recommended. Note: to run
  TensorFlow 1, install Python 3.7."* Windows is not claimed — though note that PR #4's test
  invocation in the commit message is PowerShell, so somebody is running it there.
- **Python 3.8–3.10, and specifically not 3.9.7.** §2.3.
- **TensorFlow 2**, if you want the model-loading path rather than bringing your own activations.
- **Enough RAM to hold your entire response set at once**, because `Familiarity` (GMM) and
  `Duplicates` both call `_accumulate_batches` (§3.4). That is plain float32 arithmetic you can do
  yourself: `n_samples × n_dims × 4` bytes for the accumulated array, plus whatever
  `annoy`/scikit-learn allocate on top. We have not measured the multiplier — see §11 G3.
- **No Apple silicon requirement.** DNIKit is NumPy/scikit-learn/annoy. It runs on anything.

---

## Evidence markers used in this guide

> ✅ **VERIFIED** — read out of the `apple/dnikit` repository this session: source file, test file,
> docstring, `pyproject.toml`, or the repo's own Sphinx `.rst`. Citation attached.
>
> 🟡 **RECONSTRUCTED** — the concept is attested in the repo but the exact spelling or behaviour is
> inferred from surrounding code rather than read directly.
>
> 🔴 **GAP** — could not verify. The box names what is unknown, what would resolve it, and what to
> do in the meantime.
>
> ⚠️ **SILENT FAILURE** — it does not throw. This guide has five.

**One caveat that applies to every code block below.** The research pass that produced our notes
read the repository exhaustively — 60+ source files, 8 test files, 20 `.rst` pages, and all seven
notebooks' code cells dumped verbatim — but **executed nothing**. TensorFlow was not installed in
that session. So every listing here is ✅ VERIFIED *as source that exists in the repo*, and
**UNVERIFIED as something that runs today under TF 2.16+/Keras 3.** §11 G1 is explicit about this.
Treat the code as a faithful transcription, not as a smoke-tested recipe.

---

## Contents

1. [Should you read this at all](#1-should-you-read-this-at-all)
2. [Install, versions, and the environment that actually works](#2-install-versions-and-the-environment-that-actually-works)
3. [Producer, PipelineStage, Introspector](#3-producer-pipelinestage-introspector)
4. [`Batch`: the universal container](#4-batch-the-universal-container)
5. [`Model` and the framework backends](#5-model-and-the-framework-backends)
6. [The introspectors](#6-the-introspectors)
7. [One complete worked example](#7-one-complete-worked-example)
8. [The pre-flight workflow for Parts 8–10](#8-the-pre-flight-workflow-for-parts-810)
9. [What is explicitly not here](#9-what-is-explicitly-not-here)
10. [Consolidated footguns](#10-consolidated-footguns)
11. [Declared gaps](#11-declared-gaps)
12. [Sources](#12-sources)

---

## 1. Should you read this at all

Here is the decision, compressed.

| If this is true of you | Then |
|---|---|
| You have a dataset someone else assembled, and you do not know how many near-duplicates it contains | **Read §6.3 and §7.** This is the strongest single reason to use DNIKit. |
| You are about to quantize a conv-heavy vision model and you suspect it is over-parameterised | **Read §6.5 (PFA).** Prune first, quantize second — see §8 for why the order matters. |
| Your model does well on the validation set and badly in the field | **Read §6.2 (Familiarity).** Fit on train, score field data, compare. |
| You are training and losses look fine but capacity feels wasted | **Read §6.4 (IUA).** Dying-ReLU detection. |
| You want a shareable dataset-quality dashboard | **Read §6.6 (`DatasetReport`).** Note the viewer lives in another repo. |
| Your model is a transformer / LLM | **Skip this guide.** Every introspector here assumes conv or dense activations reduced to `Batch × Channels`. Nothing in DNIKit knows what attention is. `ResponseInfo.LayerKind` has an `ATTENTION = 8007` member and nothing consumes it specially. |
| You are working in MLX, Core ML, or Core AI and want tooling that plugs in | **Skip this guide.** It does not. §9. |
| You are working in PyTorch | **Read §5.3 first.** You get data adaptors, not a `Model`. You run inference yourself. |

### The one workflow where the answer is unambiguously yes

You have a trained TF2/Keras vision model, a large image dataset, and a deadline to get it on
device. The sequence that pays for itself:

1. Run activations once, `Cacher()` them to disk (§3.5). This is the expensive step and you do it
   exactly once.
2. `Duplicates.introspect` on the cached, PCA-reduced responses. Near-duplicates in a training set
   inflate your validation score and waste capacity. ✅ §6.3.
3. `Familiarity.introspect` fit on train, scored on test. If the mean log-score gap is large, your
   splits are not from the same distribution and every number you have measured is suspect. ✅ §6.2.
4. `PFA.introspect` → `pfa.get_recipe()`. You get a per-layer *recommended filter count*. ✅ §6.5.
5. **Retrain at the recommended widths** — PFA does not modify your model, and Apple's docs are
   emphatic about this (§6.5).
6. *Then* convert (Part 8), *then* compress (Part 9).

Apple's published PFA numbers for step 4–5, from `docs/index.rst:80-84` and
`docs/introspectors/model_introspection/network_compression.rst:310-315` — ✅ VERIFIED as *claims
in the repo's documentation*, **Apple-published**, hardware and date unstated, and not reproduced
by us:

| Model / dataset | Compression | Accuracy change |
|---|---|---|
| VGG-16 / CIFAR-10 | **8×** | **+0.4%** |
| VGG-16 / CIFAR-100 | **3×** | **+1.4 pp** |
| VGG-16 / ImageNet | **1.4×** | **+2.4%** |

And a smaller worked figure from the same page: an MNIST convnet whose Conv2D layers go **32 → 21
and 64 → 45** yields a **40% model-size reduction (271 KB vs 450 KB)** with no significant accuracy
cost; pushing to `Energy(0.8)` gives **>80% compression at roughly 0.5% accuracy loss** (32 → 7 and
64 → 14 filters).

⚠️ Treat all six of those numbers as **documentation claims, not measurements you can cite**. They
carry no hardware, no software version, no date, and no confidence interval, and the underlying
paper is Suau, Zappella & Apostoloff, *"Filter Distillation for Network Compression"*, WACV 2020
(arXiv:1807.10585) — a 2018 preprint. A 1.4× compression with a 2.4% accuracy *gain* on ImageNet is
a strong claim; the series convention is to say so rather than repeat it flat.

---

## 2. Install, versions, and the environment that actually works

### 2.1 Three distributions, one version

DNIKit ships as **three separately installable but version-locked distributions**, each with its
own `pyproject.toml` built by flit: `dnikit`, `dnikit_tensorflow`, `dnikit_torch`. ✅ VERIFIED
(repo layout, `src/*/pyproject.toml`).

The lockstep is enforced at import time, not by pip.
✅ VERIFIED (`src/dnikit_tensorflow/dnikit_tensorflow/__init__.py:34-38`):

```python
# Raise error if dnikit and dnikit_tensorflow versions are out of sync
assert __version__ == dnikit.__version__, (
    f'dnikit_tensorflow v{__version__} and '
    f'dnikit v{dnikit.__version__} should be the same versions.'
)
```

The same pattern is at `src/dnikit_torch/dnikit_torch/__init__.py:32-35`. **Mixing package versions
raises `AssertionError` on `import`, before you write a line of your own code.** If you see a bare
`AssertionError` with no message from a DNIKit import, this is it.

### 2.2 Extras, and the one that does not exist

✅ VERIFIED, quoted from `src/dnikit/pyproject.toml`:

```toml
requires-python = ">=3.7"
requires = [
    "annoy",  # duplicates -- approximate nearest neighbor oh yeah
    "numpy",
    "scikit-learn",
    "typing_extensions; python_version < '3.8'",
]

[tool.flit.metadata.requires-extra]
image          = ["opencv-python-headless", "Pillow"]
dimreduction   = ["umap-learn", "pacmap"]
dataset-report = ["pandas", "umap-learn", "pacmap"]

tensorflow      = ["dnikit_tensorflow[tf2]==2.0.0"]
tensorflow1     = ["dnikit_tensorflow[tf1]==2.0.0"]
tensorflow1-gpu = ["dnikit_tensorflow[tf1-gpu]==2.0.0"]
torch           = ["dnikit_torch==2.0.0"]
```

Three things in that block are worth knowing before you type `pip install`:

- **`dnikit[complete]` references a `duplicates` extra that is not defined.** ✅ VERIFIED — the
  `complete` extra lists `dnikit[duplicates]==2.0.0`, and `requires-extra` has no `duplicates` key.
  Functionally nothing is missing, because `annoy` (the actual duplicates dependency) is in the
  **base** `requires`. But `docs/dev/contributing.rst:56` also claims `make install` installs
  `dnikit[...,duplicates]`, so the phantom extra is in two places.
- **`dnikit[complete]` does not include `torch`**, even though
  `docs/general/installation.rst:101-103` claims it installs *"`notebook`, `image`, `dimreduction`,
  `dataset-report`, `tensorflow`, & `torch` options."* ✅ VERIFIED by reading both files.
- **`scipy` is used but not declared.** `scipy.stats.entropy` (PFA's KL strategy),
  `scipy.stats.multivariate_normal` and `scipy.special.logsumexp` (Familiarity) are all imported;
  `scipy` arrives transitively via `scikit-learn`. ✅ VERIFIED. It works today. It is one
  dependency-resolution change away from not working.

Install commands, ✅ VERIFIED from `docs/general/installation.rst`:

```shell
pip install -U pip wheel

pip install dnikit                       # base: numpy, scikit-learn, annoy
pip install "dnikit[notebook]"           # to run the example notebooks
pip install "dnikit[tensorflow]"         # TF2 backend
pip install "dnikit[torch]"              # torch data adaptors
pip install "dnikit[dataset-report]"     # pandas + umap-learn + pacmap
pip install "dnikit[image]"              # opencv-python-headless + Pillow
pip install "dnikit[dimreduction]"       # umap-learn + pacmap
pip install "dnikit[complete]"           # base + TF2 + notebook  (see the extras bug above)

jupyter notebook                         # launch the examples
```

If you are on Ubuntu, the docs also list system prerequisites — ✅ VERIFIED
(`docs/general/installation.rst`):

```shell
sudo apt install -y python3.9-dev python3.9-venv python3.9-tk
sudo apt-get install -y libsm6 libxext6 libxrender-dev libgl1-mesa-glx
```

### 2.3 Python 3.9.7 is specifically broken

This is not a soft recommendation. ✅ VERIFIED, quoted verbatim from
`docs/general/support.rst:91-97`:

> *"There is a bug in Python 3.9.7 that makes this version incompatible with DNIKit... this bug
> causes dataclasses that inherit from Protocols to have an incorrect `__init__` function.
> Dataclasses and Protocols are used throughout DNIKit, so DNIKit will fail on Python 3.9.7."*

The upstream reference is CPython issue 89244. DNIKit's architecture is built on
`@dataclasses.dataclass(frozen=True)` classes conforming to `typing.Protocol` — `Batch`, `Model`,
`ResponseInfo`, `TorchProducer`, `ProducerTorchDataset` are all this shape — so the breakage is
total, not partial. Use 3.9.6 or 3.10.

### 2.4 The TF version trap

✅ VERIFIED, `src/dnikit_tensorflow/pyproject.toml`:

```toml
requires = ["dnikit==2.0.0"]

[tool.flit.metadata.requires-extra]
tf2     = ["tensorflow"]                                                          # unpinned!
tf1     = ["numpy<1.19", "protobuf<4.0", "Keras<2.4", "h5py<3.0", "tensorflow<2.0"]
tf1-gpu = ["numpy<1.19", "protobuf<4.0", "Keras<2.4", "h5py<3.0", "tensorflow-gpu<2.0"]
```

The `tf2` extra is an **unpinned `tensorflow`** with no upper bound. That is exactly why Keras 3
broke DNIKit — `pip install "dnikit[tensorflow]"` in 2024 or later pulls TF 2.16+, which defaults
to Keras 3, which changed the tensor-metadata surface DNIKit reads. Issue #2 → PR #4 → commit
`2f39056` is that story, and §5.5 walks the fix.

**If you install DNIKit 2.0.0 from PyPI today, you do not get the fix.** The release predates it by
three years. You need the repository at `main`:

```shell
git clone https://github.com/apple/dnikit.git
cd dnikit
make install     # flit install -s with extras notebook,image,dimreduction,dataset-report,tf2
```

✅ VERIFIED — the `Makefile` target is:

```make
components := dnikit dnikit_tensorflow dnikit_torch
export PIP_INDEX_URL := https://pypi.org/simple

install: cmd = install -s --deps=develop --extras=notebook,image,dimreduction,dataset-report,tf2

$(components):
	@pip install -U flit$(FLIT_VER) flit_core$(FLIT_VER)
	@flit -f src/$@/pyproject.toml $(cmd)
```

Other targets, ✅ VERIFIED from the same file: `make all` (== `install`), `make install-tf1`,
`make install-tf1-gpu`, `make uninstall`, `make test`, `make test-all`, `make test-pytest`,
`make test-smoke`, `make test-notebooks`, `make doc`, `make clean`.

### 2.5 Two testing facts that will confuse you

**Every `pytest` run also runs mypy, flake8 and coverage.** ✅ VERIFIED, `pytest.ini`:

```ini
[pytest]
testpaths = src/dnikit/  src/dnikit_tensorflow/  src/dnikit_torch/
filterwarnings = error::dnikit.exceptions.DNIKitDeprecationWarning
addopts =
    --mypy --flake8 --junit-xml=junit.xml -s
    --cov src --cov-fail-under 80 --cov-report html:coverage
    --strict-markers -rs
markers = regression, slow
flake8-max-line-length = 100
```

To run one test without dragging mypy and flake8 along, override `addopts`. The pattern is in PR
#4's own commit message — ✅ VERIFIED, quoted (PowerShell, from the contributor):

```powershell
$env:PYTHONPATH='src/dnikit;src/dnikit_tensorflow'; python -m pytest -o addopts= `
  src/dnikit_tensorflow/tests/test_tf2_model_loaders.py::test_tf_load_from_memory -q
```

**Notebook "tests" do not execute notebooks.** ✅ VERIFIED, `Makefile`:

```make
test-notebooks:
	@jupyter nbconvert --to python --output-dir notebooks/.verify notebooks/*/*.ipynb
	@mypy notebooks/.verify
```

That is a *static type check*. A notebook can pass `make test-notebooks` and still fail on the
first cell. The thing that actually runs them is `make doc`, because `docs/conf.py` sets
`nbsphinx_execute = 'always'` with `nbsphinx_timeout = 600` — and `nbsphinx_allow_errors = True`,
so **a docs build that executes a broken notebook still succeeds**. ✅ VERIFIED.

---

## 3. Producer, PipelineStage, Introspector

### 3.1 Why the architecture has this shape

DNIKit's core abstraction is three protocols deep and the reason is memory. You are introspecting a
*dataset*, which by construction is the thing that does not fit in RAM, and you are doing it by
running a network over every element and keeping the **intermediate activations** — which are
larger than the input. A 224×224 RGB image is 150 KB; MobileNet's `conv_pw_13` response for that
same image is 7×7×1024 floats, or 200 KB, and that is one layer of many.

So DNIKit is built around **lazy evaluation with an explicit consumption point**. ✅ VERIFIED,
quoted from `docs/how_to/dnikit_concepts.rst`:

> *"DNIKit begins with a `Producer` that is in charge of generating `Batches` of data... DNIKit only
> loads, processes and consumes data when it needs to. This is known as **lazy evaluation**... A
> `pipeline` is a composition of `Batch` transformations that we call `PipelineStages`... Finally,
> DNIKit's `Introspectors` will analyze input `Batches` (usually `Batches` of model responses)."*

The load-bearing consequence, and the first thing to internalise:

> **Nothing computes until `<Introspector>.introspect(...)` is called.** `pipeline()` builds a graph
> and returns a closure. It does not touch your data, does not load your model's weights into a
> forward pass, and does not raise the exception your shape mismatch is going to cause.

That is why `peek_first_batch` (§3.6) is the primary debugging tool in this toolkit, and why a
20-line pipeline that "works" can blow up on line 21.

### 3.2 `Producer`

✅ VERIFIED, `src/dnikit/dnikit/base/_producer.py:23-71`:

```python
class Producer(t.Protocol):
    def __call__(self, batch_size: int) -> t.Iterable[Batch]:
        """All Producers should yield at least one Batch of size batch_size.
           The last of the batches is allowed to have a size smaller than batch_size."""
        ...
```

It is a `Protocol` with one method, so **a plain function is a `Producer`**. Both styles are in the
docstring — ✅ VERIFIED verbatim, `_producer.py:34-56`:

```python
import numpy
import typing as t
from dnikit.base import Batch, Producer


# Implement a Producer as a free function
def simple_producer(batch_size: int) -> t.Iterable[Batch]:
    for i in range(100):
        data = numpy.random.randn(batch_size, 10)
        yield Batch({"input": data})


# Implement a Producer as a class
class ClassProducer(Producer):
    def __init__(self):
        self._dims = (10, 1)

    def __call__(self, batch_size: int) -> t.Iterable[Batch]:
        for i in range(100):
            data = numpy.random.randn(batch_size, *self._dims)
            yield Batch({"input": data})
```

> ⚠️ **SILENT FAILURE #1 — an infinite `Producer` hangs, it does not error.**
>
> ✅ VERIFIED, warning quoted verbatim from `_producer.py:58-62`: *"Make sure to have a finite
> number of batches the `Producer` will generate, as some `Introspector` instances will try to
> consume all the batches of the producer and the program will stop responding indefinitely if
> there are infinite batches."*
>
> This is easy to hit because the natural way to wrap a streaming data source — a `while True` over
> a socket, a `itertools.cycle`, a Keras `Sequence` with `shuffle=True` and no epoch bound — is
> infinite. `Familiarity.introspect`, `Duplicates.introspect` and `_accumulate_batches` will all
> consume until the generator stops. There is no timeout, no batch cap, and no warning: your
> process sits at 100% CPU with growing RSS and never returns.
>
> **Safe default:** wrap every custom `Producer` in an explicit counter and `return` when you hit
> it, even when you think the underlying source is finite:
>
> ```python
> def bounded(inner: Producer, max_batches: int) -> Producer:
>     def _producer(batch_size: int) -> t.Iterable[Batch]:
>         for i, batch in enumerate(inner(batch_size)):
>             if i >= max_batches:
>                 return
>             yield batch
>     return _producer
> ```
>
> (That helper is ours, not DNIKit's — it is a `Producer` by protocol conformance, which is the
> point of the design.)

Helpers in the same module, ✅ VERIFIED:

| Symbol | Location | Purpose |
|---|---|---|
| `peek_first_batch(producer, batch_size=1) -> Batch` | `_producer.py:147` | **Public.** The debugger. §3.6 |
| `_accumulate_batches(producer, *, batch_size=1024) -> Batch` | `_producer.py:74` | **Private.** Loads *everything* into RAM. Raises `DNIKitException("Producer did not produce any batches")` on `ValueError`. Used by `Familiarity.Strategy.GMM` and `Duplicates.introspect`. |
| `_resize_batches(batches) -> Producer` | `_producer.py:94` | Re-chunks. Used by `CachedProducer` and `StubProducer`. |
| `_produce_elements(producer, batch_size=32)` | `_producer.py:163` | Element-wise iteration. |

### 3.3 `PipelineStage` and `pipeline()`

✅ VERIFIED, `src/dnikit/dnikit/base/_pipeline.py`:

```python
class PipelineStage(_Logged, abc.ABC):
    def _pipeline(self, producer: Producer) -> Producer:      # :43  (override rarely)
        batch_processor = self._get_batch_processor()

        def new_producer(batch_size: int) -> t.Iterable[Batch]:
            for batch in producer(batch_size):
                yield batch_processor(batch)
        return new_producer

    @abc.abstractmethod
    def _get_batch_processor(self) -> t.Callable[[Batch], Batch]: ...   # :59
```

The composition function, ✅ VERIFIED `_pipeline.py:115-116`:

```python
def pipeline(producer: Producer, *stages: OneOrMany[PipelineStage]) -> Producer
```

Two facts about `pipeline()` that explain notebook idioms you will see:

- **Stage arguments may be tuples or lists and are flattened automatically** via
  `resolve_one_or_many_to_list`. This is why you can write `pipeline(data, *model_stages)` or pass
  `(a, b, c)` inline, and why `TFModelWrapper.__call__` can return a 2- or 3-tuple of stages and
  still be dropped straight into a pipeline. ✅ VERIFIED.
- A non-`PipelineStage` argument raises `TypeError(f"Stage is of unsupported type: {type(stage)}")`.
  ✅ VERIFIED.

**The statelessness contract is the part people get wrong.** ✅ VERIFIED, quoted verbatim from
`_pipeline.py:67-72`:

> *"The batch processor **MUST be stateless**. That is, its outputs must only depend on the input
> `batch`. If the `PipelineStage` has some state, the best way to ensure the batch processor is
> stateless is to make a local copy of all mutable variables."*

The canonical idiom for a stage that *does* have configuration, ✅ VERIFIED verbatim from the same
docstring, `_pipeline.py:94-110`:

```python
class Stateful(PipelineStage):
    def __init__(self, factor: float):
        self.factor = factor

    def _get_batch_processor(self) -> t.Callable[[Batch], Batch]:
        factor = self.factor          # local copy captured by closure

        def batch_operation(batch: Batch) -> Batch:
            return Batch({"result": batch["input"] * factor})
        return batch_operation
```

Read `factor = self.factor` as load-bearing, not stylistic. `_get_batch_processor` is called **once,
at pipeline-construction time**, and the closure it returns may be invoked from a different thread
than the one that built it — `multi_introspect` (§3.7) runs introspectors on a `ThreadPoolExecutor`.
Capturing `self` instead of a snapshot means a mutation between construction and consumption
changes results retroactively, and because nothing computes until `introspect()`, "between
construction and consumption" can be most of your script.

### 3.4 Where streaming stops

The architecture is designed for streaming, but **four things in DNIKit deliberately abandon it**.
Know which, because this is where your 200k-image audit dies with a `MemoryError`.

| Component | Streams? | Evidence |
|---|---|---|
| `DimensionReduction.Strategy.PCA` | ✅ **yes** — `sklearn.decomposition.IncrementalPCA`, `partial_fit` per batch | `_reducers.py` |
| `DimensionReduction.Strategy.StandardPCA` | ❌ accumulates | exact `sklearn.decomposition.PCA` |
| `DimensionReduction.Strategy.TSNE` / `UMAP` / `PaCMAP` | ❌ accumulate | one-shot or `.fit` on the whole array |
| `Familiarity.Strategy.GMM` (fitting) | ❌ `_accumulate_batches(batch_size=1024)` | `_gmm_familiarity.py` |
| `Duplicates.introspect` | ❌ `_accumulate_batches(producer, batch_size=batch_size)` | `_duplicates.py:278-428` |
| `PFA` covariance accumulation | ✅ **yes** — keeps `_count`, `_sum_x`, `_sum_xxt` | `_covariances_calculator.py` |
| `IUA` | ✅ **yes** — per-batch `np.isclose` counts | `_iua.py` |

All ✅ VERIFIED by reading the named files.

PFA's streaming covariance is the nicest piece of engineering in the toolkit and worth naming
explicitly: `get_centered_covariances()` computes `sum_xxt/(n-1) - outer(mean, sum_x/(n-1))`, so it
never materialises the data matrix. That is why **PFA is the introspector you can run on a dataset
that does not fit in memory**, and `Duplicates` is the one you cannot.

**The practical consequence: reduce dimensions before the memory-hungry introspectors.** The docs'
own recommended recipe, ✅ VERIFIED (`docs/introspectors/data_introspection/dimension_reduction.rst`):
reduce 1024 → 40 with streaming `PCA` first, **then** UMAP / PaCMAP / t-SNE → 2. A 40-dim
accumulation is 25× smaller than a 1024-dim one, and `Duplicates`' runtime is linear in dimensions
as well as samples.

### 3.5 `Cacher` — pay for inference once

Model inference is the expensive stage. `Cacher` writes post-inference batches to disk so the
second, third and fourth introspector do not re-run the network.

✅ VERIFIED, `src/dnikit/dnikit/base/_cached_producer.py` (exported through `dnikit.processors`):

```python
from dnikit.processors import Cacher
from dnikit.base import pipeline

cacher = Cacher(storage_path=None)      # default: tempfile.mkdtemp(prefix="dnikit-cacher-")
pipelined = pipeline(producer, processor, cacher)

cacher.cached          # bool: True once the ".cache.done" marker exists
cacher.storage_path    # resolved absolute Path
cp  = cacher.as_producer()               # -> CachedProducer (raises if not yet cached)
cp2 = cp.copy_to(new_path, overwrite=False)
Cacher.clear(storage_path=None)          # deletes ALL dnikit caches under tempdir (or given dir)
```

On-disk format: **one Python pickle per batch**, named `f"{index}.pkl"`, plus two marker files
`.dni_cache_dir` and `.cache.done`. ✅ VERIFIED. That is a convenience format, not an interchange
format — do not build tooling on it, and do not commit it.

`Cacher` attaches a numeric `Batch.StdKeys.IDENTIFIER` if the batch does not already have one
(`_add_identifier`, `_cached_producer.py:232-244`). ✅ VERIFIED. That matters because
`DatasetReport` **requires** `IDENTIFIER` (§6.6) — putting a `Cacher` at the end of your pipeline
quietly satisfies that requirement, which is why every notebook does it.

Errors, ✅ VERIFIED verbatim:

- `DNIKitException(f"Path {path} already contains caching files.")` — constructing a `Cacher` over
  a directory that already has a cache.
- `DNIKitException("Cacher already used in a pipeline. Either create a new Cacher ... or call
  as_producer() ...")` — **a `Cacher` is single-use per pipeline.**
- `DNIKitException("Caching must be complete before converting to a CachedProducer.")` —
  `as_producer()` called before the pipeline has been fully consumed.
- `DNIKitException(f"{path} does not contain cached batches. Cannot create CachedProducer.")`
- `Cacher._get_batch_processor()` deliberately raises
  `DNIKitException('Should never call this function in CachedProducer')` — it overrides `_pipeline`
  instead of using the batch-processor path.

Two behavioural notes: reading a cache with a **different `batch_size`** than was written works but
is *"relatively computationally expensive since it involves concatenating and splitting batches"*
(✅ VERIFIED, docstring); and `Cacher.clear()` carries an explicit warning — *"Make sure to only
call this function once pipelines are no longer needed... Otherwise, a cache that is already in use
may be destroyed!"* It deletes **all** DNIKit caches under the temp directory, not just yours.

### 3.6 `peek_first_batch` and `PipelineDebugger`

Because nothing runs until `introspect()`, you need a way to force one batch through. ✅ VERIFIED,
`docs/general/support.rst`:

```python
from dnikit.base import peek_first_batch, pipeline

b           = peek_first_batch(producer, batch_size=1)                      # raw producer
b_processor = peek_first_batch(pipeline(producer, processor1), batch_size=2) # after preprocessing
b_full      = peek_first_batch(response_producer, batch_size=1)             # whole pipeline
```

And a stage that prints what is flowing through it, ✅ VERIFIED:

```python
from dnikit.processors import PipelineDebugger, SnapshotSaver

producer = pipeline(stub_dataset_metadata, SnapshotSaver(save="snap"), PipelineDebugger())
batch = peek_first_batch(producer, 5)
output = PipelineDebugger.dump(batch)
```

`PipelineDebugger(label="", first_only=True, dump_fields=False, fields=None)` — ✅ VERIFIED
signature. Output shape:

```
<label> Batch(batch_size=N) {
field: (shape)
...
Snapshots:
snap: ['field', ...]

Metadata:
Batch.MetaKey(name=...)
Batch.DictMetaKey(name=...)Batch.DictMetaKey(name=...): ['k1','k2']
}
```

(The missing newline between the two `DictMetaKey` lines is in the source's format string, not a
transcription error.)

### 3.7 `multi_introspect` — several introspectors, one pass

If you want `PFA` *and* `Familiarity` over the same activations and cannot afford the disk for a
`Cacher`, run them concurrently over a single pass. ✅ VERIFIED,
`src/dnikit/dnikit/base/_multi_introspect.py`:

```python
def multi_introspect(*introspectors: _Introspector[t.Any],
                     producer: Producer) -> t.Tuple[t.Any, ...]
```

```python
from dnikit.base import multi_introspect
from dnikit.introspectors import PFA, Familiarity
import functools

pfa, familiarity = multi_introspect(PFA.introspect, Familiarity.introspect, producer=producer)

# with arguments — either a lambda or functools.partial:
results = multi_introspect(
    lambda prod: Familiarity.introspect(prod, strategy=Familiarity.Strategy.GMM()),
    producer=producer)

results = multi_introspect(
    functools.partial(Familiarity.introspect, strategy=Familiarity.Strategy.GMM()),
    producer=producer)
```

Typed overloads exist for 1–7 introspectors plus a generic `*introspectors` fallback
(`_multi_introspect.py:162-221`). ✅ VERIFIED.

The implementation is worth one sentence because it explains the constraints: `_ProducerSplitter`
(`:43-158`) hands batches between threads using `threading.Event`, with one thread per introspector
on a `concurrent.futures.ThreadPoolExecutor(max_workers=num_introspectors)`. **Only one thread runs
at a time** — threads are used for *preemption*, not parallelism. You get one pass over the data,
not a speedup.

Three gotchas, ✅ VERIFIED:

- **All introspectors must request the same `batch_size`**, else
  `ValueError(f"Mismatched batch_size, got {batch_size}, expected {self._batch_size}")`
  (`:135`). Note the defaults differ: `Duplicates` defaults to `32`, `Familiarity` to `1024`,
  `PFA` to `32`, `IUA` to `32`. Pass an explicit `batch_size` to every one of them.
- Any exception in any introspector triggers `splitter.signal_failure()` →
  `DNIKitException("Encountered exception when processing multiple introspectors")` chained via
  `from e` (`:334-337`).
- Verbatim warning, `_multi_introspect.py:305-307`: *"Do not attempt to catch the `AssertionError`
  in any of the input introspectors, doing so may cause deadlock!"*

---

## 4. `Batch`: the universal container

`Batch` is the only thing that flows through a DNIKit pipeline. It is a frozen dataclass with a
single member, `_storage: _BatchStorage`, and it is by a wide margin the biggest file in the repo
(`src/dnikit/dnikit/base/_batch/_batch.py`, 1,237 lines). ✅ VERIFIED.

Three conceptual parts, ✅ VERIFIED:

| Accessor | Type | Notes |
|---|---|---|
| `batch.fields` | `Mapping[str, np.ndarray]` | **Dimension 0 is always the batch dimension.** |
| `batch.snapshots` | `Mapping[str, Batch]` | Saved earlier pipeline state. **Snapshots may not contain snapshots.** |
| `batch.metadata` | `Batch.MetadataType` | Keyed by `Batch.MetaKey` / `Batch.DictMetaKey` |
| `batch.batch_size` | `int` | |
| `batch.elements` | `Batch.ElementsView` | Iteration / indexing / slicing |

### 4.1 Construction

✅ VERIFIED, `_batch.py:178-181` (the two `__init__` overloads) and the `Builder` API:

```python
from dnikit.base import Batch
import numpy

# Fields-only constructor
batch = Batch({"images": numpy.zeros((32, 3, 64, 64))})

# Full construction via Builder
builder = Batch.Builder()                       # or Batch.Builder(base=existing_batch)
builder.fields["images"] = images
builder.metadata[Batch.StdKeys.IDENTIFIER] = [...]
builder.metadata[Batch.StdKeys.LABELS] = {"fine": [...], "coarse": [...]}
builder.snapshots["origin"] = previous_batch
batch = builder.make_batch()
```

Errors and invariants, ✅ VERIFIED verbatim:

- `ValueError("Cannot initialize Batch without any fields")` — empty fields.
- `ValueError("Cannot provide both `fields` and `storage` arguments")`.
- `Batch.Builder(batch)` → `ValueError("Batch.Builder(batch) is not supported -- use
  Batch.Builder(base=batch) ...")` (`:867-870`). This is a real trap: the positional argument is
  `fields`, and passing a `Batch` there is the obvious wrong guess.
- `Batch.Builder(fields=..., base=...)` together → `ValueError("Use either `fields` or `base`
  argument, not both")`.
- `check_invariants()` (`_storage.py:56-85`) raises `DNIKitException` if field lengths mismatch, if
  a snapshot's `batch_size` differs, if a snapshot contains snapshots, or if metadata sequence
  lengths ≠ `batch_size`.
- A `_BatchStorage` with neither fields nor metadata → `DNIKitException("Must have non-empty fields
  or metadata.")`.

### 4.2 Arrays are frozen — and this bites PyTorch users specifically

✅ VERIFIED, `_storage.py:52-54`: `Batch` construction calls `self._storage.freeze_arrays()`, which
sets `array.flags.writeable = False` on **every field array**.

That is a correctness feature — a `PipelineStage`'s batch processor must be stateless (§3.3), and
frozen arrays make accidental in-place mutation raise instead of silently corrupting a downstream
introspector. But it collides with PyTorch, which requires writable memory to construct a tensor
without a copy warning. DNIKit's own `ProducerTorchDataset` therefore calls `.copy()` on every
field before handing it over (§5.3), and the comment in the shipped example says so:

```python
def transform(element: Batch.ElementType) -> np.ndarray:
    # note: pycharm requires a writable copy of the ndarray
    return element.fields["image"].reshape((128, 32)).copy()
```

✅ VERIFIED verbatim from `dnikit_torch`'s docstring. If you write your own bridge, copy.

### 4.3 Metadata keys

Two key kinds, both generic over a payload type. ✅ VERIFIED:

```python
META_KEY      = Batch.MetaKey[int]("META_KEY")           # -> Sequence[int], len == batch_size
DICT_META_KEY = Batch.DictMetaKey[float]("DICT_KEY")     # -> Mapping[str, Sequence[float]]

flat = batch.metadata[META_KEY]                          # Sequence[int]
d    = batch.metadata[DICT_META_KEY]["key"]              # Sequence[float]

element_value = batch.elements[0].metadata[META_KEY]     # int
element_dict  = batch.elements[0].metadata[DICT_META_KEY]  # Mapping[str, float]
```

> ⚠️ **Generic payload types are type-checker-only and are never validated at runtime.** ✅
> VERIFIED. A `Batch.MetaKey[int]` will happily carry strings. Key `name` must be unique.

The standard keys are assigned at module bottom rather than in the class body — the source comment
says this was *"unable to do this inline because of type visibility issues."* ✅ VERIFIED,
`_batch.py:1116-1237`:

```python
Batch.StdKeys.IDENTIFIER = Batch.MetaKey[t.Hashable]('dnikit.base.Batch.StdKeys.identifier')
Batch.StdKeys.PATH       = Batch.MetaKey[dt.PathOrStr]('dnikit.base.Batch.StdKeys.path')
Batch.StdKeys.LABELS     = Batch.DictMetaKey[t.Hashable]('dnikit.base.Batch.StdKeys.labels')
```

`Batch.StdKeys()` raises `DNIKitException("Do not instantiate Batch.StdKeys")`. ✅ VERIFIED.

`IDENTIFIER` is the one you must get right, because `DatasetReport` requires it (§6.6) and
`Duplicates` results are only interpretable through it. The documented use cases, ✅ VERIFIED
(`_batch.py:1129-1184`): the array index for CIFAR; the file path for image datasets;
a `(path, crop_x, crop_y, crop_w, crop_h)` tuple for face-crop datasets; a UUID or sequence integer
when nothing natural exists.

`LABELS` is a dict-of-sequences, one entry per label dimension:

```python
builder.metadata[Batch.StdKeys.LABELS] = {
    "shape": ["square", "square", "triangle", ...],
    "color": ["blue",   "red",    "green",    ...],
}
```

### 4.4 `batch.elements`

✅ VERIFIED, `_batch.py:262-342`:

```python
element = batch.elements[42]               # -> Batch.ElementType
subset  = batch.elements[-1, 1, 2, 3, 5]   # Sequence[int] -> Batch
subset  = batch.elements[10:30:2]          # slice         -> Batch
for element in batch.elements: ...         # Batch.ElementType
len(batch.elements) == batch.batch_size
```

`Batch.ElementType.fields` returns an `np.ndarray` for fields with ≥2 dimensions and an `np.number`
for 1-D fields. Out-of-range sequence selectors raise
`IndexError(f"Selector {selector} out of range in batch with {n} elements")` (`_storage.py:171-177`).
Concatenation requires **identical** fields, snapshots, metadata keys and metadata sub-fields, else
`ValueError("Cannot concatenate batches with different fields/snapshots/metadata/metadata fields")`
(`_storage.py:134-166`). ✅ VERIFIED.

---

## 5. `Model` and the framework backends

### 5.1 `dnikit.base.Model`

✅ VERIFIED, `src/dnikit/dnikit/base/_model.py:124-241`. A frozen dataclass wrapping a private
`_ModelDetails`. **Do not instantiate it directly** — use the `dnikit_tensorflow` loaders.

```python
model.response_infos   # Mapping[str, ResponseInfo]  -- every layer output
model.input_layers     # Mapping[str, ResponseInfo]  -- placeholders whose name contains 'input'

stage = model(requested_responses: dt.OneManyOrNone[str] = None)   # -> PipelineStage
```

> ⚠️ `requested_responses=None` requests **every layer**. The docstring's own warning, ✅ VERIFIED
> at `_model.py:230-231`: *"which may be expensive to compute!"* For MobileNet that is ~90 layers
> of full spatial activations per image. Always pass a list.

The idiom for picking exactly the conv layers, ✅ VERIFIED (this exact shape appears in both the
PFA and IUA notebooks):

```python
from dnikit.base import ResponseInfo

conv2d_responses = [
    info.name
    for info in model.response_infos.values()
    if info.layer.kind is ResponseInfo.LayerKind.CONV_2D
    and 'preds' not in info.name
]
```

### 5.2 Input binding — the auto-rename, and when it stops

`_ModelPipelineStage._get_batch_processor` (`_model.py:83-121`) implements a three-rule binding.
✅ VERIFIED:

1. If the model has **exactly one** input and the batch has **exactly one** field, the names differ,
   **and** `batch.fields[f].shape[1:] == input_response.shape[1:]`, DNIKit **silently renames** the
   field to the input's name. This is why `mobilenet.model(...)` "just works" on a producer whose
   field is called `samples` or `images`.
2. Otherwise, if `len(potential_inputs) == len(batch.fields)` but the name sets differ, you get a
   long, genuinely helpful exception — ✅ VERIFIED verbatim:

   ```
   DNIKitException: Model expects inputs named {names} but batch contains fields named {fields}.
   Field names must match expected input names to perform inference. (To change field names in a
   batch, try using a FieldRenamer in the pipeline. To import the FieldRenamer class, do
   'from dnikit.processors import FieldRenamer')
   ```

3. The output batch is built with `Batch.Builder(base=batch)` and `builder.fields =
   dict(inference_result)` — so **input fields are replaced by responses**, while metadata and
   snapshots are preserved. That is what makes `IDENTIFIER` and `LABELS` survive inference, which
   the whole `DatasetReport` design depends on.

> ⚠️ **SILENT FAILURE #2 — the shape-matched auto-rename does not check semantics.**
>
> Rule 1 fires on **shape agreement alone**. If your producer emits one field and the model has one
> input and the trailing dimensions line up, DNIKit binds them, whatever the field is called and
> whatever it contains. A pipeline that accidentally feeds a `mask` field, or a batch of
> already-normalised images into a model whose preprocessing you also applied, or `(N, 224, 224, 3)`
> depth maps into an RGB classifier, produces activations, produces a `DatasetReport`, produces a
> PFA recipe — and none of it means anything. There is no warning, because from DNIKit's point of
> view nothing went wrong.
>
> **Safe default:** never rely on the auto-rename in a pipeline you intend to trust. Put an explicit
> `FieldRenamer` in, and assert the binding once at the top of your script:
>
> ```python
> from dnikit.base import peek_first_batch, pipeline
> from dnikit.processors import FieldRenamer
>
> raw = peek_first_batch(dataset, batch_size=1)
> print("producer fields:", {k: v.shape for k, v in raw.fields.items()})
> print("model inputs:   ", {k: v.shape for k, v in model.input_layers.items()})
>
> producer = pipeline(dataset, FieldRenamer({"samples": "input_1"}), model(conv2d_responses))
> ```
>
> The two `print`s cost nothing and turn a silent misbinding into a thing you can see.

`FieldRenamer` takes its mapping **positionally**, not as a keyword: `FieldRenamer(mapping)`.
✅ VERIFIED (§5.6 table).

### 5.3 The backend matrix — and Core ML's absence

✅ VERIFIED by reading the tree:

| Framework | Support level | Where |
|---|---|---|
| **TensorFlow 2 / tf.keras** | **Full `Model`** — load from path or memory, per-layer response extraction, inference | `src/dnikit_tensorflow/.../_tf2_*.py` |
| **TensorFlow 1** (graph/session) | **Full `Model`** — SavedModel, `.pb`, checkpoint, Keras `.h5`, arch+weights | `_tf1_*.py` |
| **PyTorch** | **Data adaptors only** — `TorchProducer`, `ProducerTorchDataset`. **No `Model`, no `_ModelDetails`.** You run inference yourself and feed the responses in as a `Producer`. | `src/dnikit_torch/dnikit_torch/_torch_producer.py` |
| **Core ML** | ❌ **Not supported.** No `coremltools`, no `.mlmodel` or `.mlpackage` loader anywhere in the repo. | — |
| **Core AI / `.aimodel`** | ❌ **Not supported.** No reference of any kind. | — |
| **MLX** | ❌ **Not supported.** | — |
| **JAX / anything else** | Via a custom `Producer` of responses — the docs name JAX explicitly | `docs/utils/data_producers.rst:234-236` |

That last row is the escape hatch and it is the one that makes DNIKit usable from the rest of this
series. The `_ModelDetails` protocol has exactly three methods (`_model.py:29-74`):
`run_inference(inputs, outputs)`, `get_response_infos()`, and `get_input_layer_responses()` — but
Apple explicitly tells you **not** to implement it. ✅ VERIFIED, quoted verbatim from
`_model.py:36-42`:

> *"To wrap a deep learning framework that DNIKit does not currently support, it's recommended to
> create a custom `Producer` that yields the model responses, rather than creating a custom
> `_ModelDetails`. This class is intended for code that will eventually be integrated into DNIKit."*

**That is the officially sanctioned route for a PyTorch, MLX or Core ML user**, and it is
straightforward, because a `Producer` is one function (§3.2). You run your own forward pass, hook
whatever layer you want, and yield `Batch({"conv13": activations})` with an `IDENTIFIER`. Everything
from §6 onwards then works unchanged, because every introspector consumes activations, not models.

🟡 **RECONSTRUCTED:** the sketch below is *our* composition of two verified pieces (the `Producer`
protocol from `_producer.py:34-56`, and `Batch.Builder` from `_batch.py`). It does not appear in the
repo. The shape is right; treat the details as ours.

```python
import typing as t
import numpy as np
import torch
from dnikit.base import Batch, Producer


def torch_response_producer(model: torch.nn.Module,
                            loader: torch.utils.data.DataLoader,
                            layer: torch.nn.Module,
                            field_name: str = "responses") -> Producer:
    """Yield DNIKit Batches of activations captured from `layer` by a forward hook."""
    captured: t.List[torch.Tensor] = []

    def _hook(_m, _i, output):
        captured.append(output.detach().cpu())

    handle = layer.register_forward_hook(_hook)
    model.eval()

    def _producer(batch_size: int) -> t.Iterable[Batch]:
        index = 0
        try:
            with torch.no_grad():
                for images, _labels in loader:
                    captured.clear()
                    model(images)
                    acts = captured[0].numpy()               # (B, C, H, W)
                    acts = acts.reshape(acts.shape[0], acts.shape[1], -1).max(axis=-1)  # -> (B, C)

                    builder = Batch.Builder()
                    builder.fields[field_name] = acts.astype(np.float32)
                    builder.metadata[Batch.StdKeys.IDENTIFIER] = list(
                        range(index, index + acts.shape[0]))
                    index += acts.shape[0]
                    yield builder.make_batch()
        finally:
            handle.remove()

    return _producer
```

Feed that straight into `PFA.introspect`, `Duplicates.introspect` or `Familiarity.introspect`. Note
the manual max-pool to `(B, C)` — every introspector except `IUA` requires 2-D fields (§6), and
doing it in the hook is cheaper than shipping full spatial activations through a pipeline.

### 5.4 The PyTorch adaptors that *are* shipped

`dnikit_torch.__all__ == ["ProducerTorchDataset", "TorchProducer"]`. ✅ VERIFIED.

**`TorchProducer`** — a `DataLoader` becomes a DNIKit `Producer`:

```python
import typing as t
from dnikit.base import Batch
from dnikit_torch import TorchProducer

key1 = Batch.DictMetaKey[int]("KEY1")
key2 = Batch.DictMetaKey[t.Mapping[str, str]]("KEY2")

producer = TorchProducer(loader, ["image", None, key1, key2])
# element.metadata[key1] == {"_": 50}
# element.metadata[key2] == {"k1": "v1", "k2": "v2"}
```

✅ VERIFIED signature:

```python
@dataclasses.dataclass(frozen=True)
class TorchProducer(Producer):
    data_loader: DataLoader
    mapping: t.Sequence[TORCH_PRODUCER_MAPPING]
    anonymous_field_name: str = "_"

TORCH_PRODUCER_MAPPING = t.Union[str, Batch.DictMetaKey, Batch.MetaKey,
                                 t.Callable[[t.Any, Batch.Builder], None]]
```

The mapping is **positional over the tuple your `Dataset` yields**: a `str` becomes a field, a
`MetaKey` becomes flat metadata, a `DictMetaKey` becomes dict metadata (wrapped under
`anonymous_field_name` unless the value is itself a dict), `None` discards that position, and a
callable gets `(value, builder)` for custom handling. ✅ VERIFIED.

Three gotchas, ✅ VERIFIED:

- `TorchProducer.batch_size == data_loader.batch_size or 100`, and calling `producer(batch_size)`
  with anything else raises `ValueError('The Torch DataLoader used in this instance produces
  batches of size {n}, requested batch size: {m}')`. **So a `TorchProducer` cannot be handed to an
  introspector with a mismatched `batch_size=` kwarg** — and the introspector defaults differ
  (`Duplicates`/`IUA`/`PFA` = 32, `Familiarity` = 1024). Set the `DataLoader` batch size to match,
  or pass the matching `batch_size=` to every introspector.
- `assert not isinstance(self.mapping, str)` — passing a bare string instead of a list is common
  enough that they assert on it.
- List-of-lists metadata is **transposed**: `list(map(list, zip(*value)))`, because *"lists of
  `[a, b, c, ...]` are expected, not `[a, a, a, ...]`."*

The behaviours are pinned by tests (`src/dnikit_torch/tests/test_torch_producer.py`, `DataLoader`
`batch_size=2`) — ✅ VERIFIED:

```python
_run_producer([7],             ["image", key1]).metadata[key1] == {"_": [7, 7]}
_run_producer(["a"],           ["image", key1]).metadata[key1] == {"_": ["a", "a"]}
_run_producer([[7, 8]],        ["image", key1]).metadata[key1] == {"_": [[7, 8], [7, 8]]}
_run_producer([["cat","dog"]], ["image", key1]).metadata[key1] == {"_": [["cat","dog"],["cat","dog"]]}
_run_producer([{"k1":"v1","k2":"v2"}], ["image", key1]).metadata[key1] == {"k1":["v1","v1"], "k2":["v2","v2"]}
_run_producer([7, 8], ["image", None, key2]).metadata[key2] == {"_": [8, 8]}
```

**`ProducerTorchDataset`** goes the other way — a DNIKit `Producer` becomes a torch
`IterableDataset`, so you can train on data you have audited. ✅ VERIFIED:

```python
@dataclasses.dataclass(frozen=True)
class ProducerTorchDataset(IterableDataset):
    producer: Producer
    mapping: t.Sequence[PRODUCER_TORCH_MAPPING]
    batch_size: int = 100      # size pulled from the Producer, independent of the DataLoader
    transforms: t.Optional[t.Mapping[str, t.Callable[[torch.Tensor], torch.Tensor]]] = None
```

```python
from torchvision import transforms

dataset = ProducerTorchDataset(
    producer, ["image", "mask", "heights"],
    transforms={"image": transforms.RandomCrop(32, 32),
                "mask": transforms.Compose([transforms.CenterCrop(10), transforms.ColorJitter()])})
```

Note that unlike torchvision's `transform` / `target_transform` convention, **transforms are keyed
by field name**. And a `DictMetaKey` whose dict has a single field is unwrapped to just that
field's value. ✅ VERIFIED.

### 5.5 Loading a TensorFlow model, and the Keras 3 story

The public surface is five symbols. ✅ VERIFIED,
`src/dnikit_tensorflow/dnikit_tensorflow/__init__.py:26-32`:

```python
__all__ = ["load_tf_model_from_path", "load_tf_model_from_memory",
           "TFModelExamples", "TFModelWrapper", "TFDatasetExamples"]
```

```python
from dnikit_tensorflow import load_tf_model_from_path, load_tf_model_from_memory

dni_model = load_tf_model_from_path("/path/to/model")      # PathOrStr

tf2_model = ...                                            # tf.keras.models.Model
dni_model = load_tf_model_from_memory(model=tf2_model)     # TF2: pass `model=`
dni_model = load_tf_model_from_memory(session=tf1_sess)    # TF1: pass `session=`
```

Which keyword you pass depends on which TensorFlow is installed, decided **at import time**:
`running_tf_1()` is literally `tf.__version__[0] == '1'` (`_tensorflow_protocols.py:27-28`), and
`_tensorflow_loading.py:24-31` branches on it. Passing the wrong one, or both, or neither, raises
`ValueError('For TF2 (currently installed), please pass param `model`')` — with the text switching
to `session` under TF1. ✅ VERIFIED.

Path loading walks an ordered chain, first `can_load()` wins. ✅ VERIFIED, `_tf2_loading.py:30-36`:

```python
TF2LoadingChain = LoadingChain(loading_chain=[
    _TF2SavedKerasModelLoader,      # tf.saved_model.contains_saved_model(dir)
    _TF2KerasArchAndWeightsLoader,  # a directory containing exactly 1 arch file + 1 weights file
    _TF2KerasWholeModelLoader,      # pathname.suffix == '.h5'
])
```

Failure of the whole chain →
`DNIKitException(f'DNIKit unable to load TF model from path: {pathname}.')`. Architecture
extensions are `['.json', '.yml', '.hdf5', '.he5']`, weights extensions `['.hdf', '.h5', '.hdf5',
'.he5']`, and a directory qualifies only if **exactly one** file of each kind is present
(`_tensorflow_file_loaders.py:53-81`). ✅ VERIFIED.

> 🔴 **GAP — there is no `.keras` loader.**
>
> Keras 3's native serialization format is `.keras`. `can_load` in the TF2 chain checks only for a
> SavedModel directory, an arch+weights directory, and the `.h5` suffix. A `.keras` file falls
> through the whole chain to `DNIKitException('DNIKit unable to load TF model from path: ...')`.
> **Confirmed by reading all three loaders; not executed.**
>
> *What would resolve it:* installing TF 2.16+ and running `load_tf_model_from_path("m.keras")`.
> *Safe default:* load the model yourself with Keras and use
> `load_tf_model_from_memory(model=...)`, which bypasses the file-loader chain entirely. The repo's
> own advice points the same way — ✅ VERIFIED verbatim, `_tensorflow_loading.py:92-96`: *"The keras
> loaders are currently using `tf.keras` instead of `keras` natively, and so issues might appear
> when trying to load models saved with native `keras` (not tf.keras). In this case, load the model
> outside of DNIKit with `keras` and pass it to load with `load_tf_model_from_memory`."*

**What commit `2f39056` actually fixed.** The 2026 commit touches two files
(`_tf2_model.py` +45/−14 and `test_tf2_model_loaders.py` +23/−2). Its summary, ✅ VERIFIED verbatim
from the commit message:

> - read TF2 tensor dtype and shape from `type_spec` when available, with a Keras 3 fallback to
>   `dtype` and `shape`
> - normalize tensor metadata through TensorFlow before building `ResponseInfo`
> - use layer metadata when Keras 3 output names are generic, so Conv2D responses still classify
>   correctly

The core of it, ✅ VERIFIED from the diff:

```python
def _get_tensor_dtype_and_shape(tensor: t.Any) -> t.Tuple[t.Any, t.Any]:
    type_spec = getattr(tensor, "type_spec", None)
    if type_spec is not None:
        return type_spec.dtype, type_spec.shape
    return tensor.dtype, tensor.shape
```

```python
-def _convert_tf_operation(layer_name: str) -> ResponseInfo.LayerKind:
+def _convert_tf_operation(*layer_names: str) -> ResponseInfo.LayerKind:
     # First check known operations
-    operation = _extract_kind(layer_name)
-    if operation in _KNOWN_OPS:
-        return _KNOWN_OPS[operation]
+    for layer_name in layer_names:
+        operation = _extract_kind(layer_name)
+        if operation in _KNOWN_OPS:
+            return _KNOWN_OPS[operation]
     # next, check layer name prefixes
-    for layer_prefix, layer_kind in _LAYER_PREFIXES.items():
-        if layer_name.startswith(layer_prefix):
-            return layer_kind
+    for layer_name in layer_names:
+        for layer_prefix, layer_kind in _LAYER_PREFIXES.items():
+            if layer_name.startswith(layer_prefix):
+                return layer_kind
     return ResponseInfo.LayerKind.UNKNOWN
```

with the call site now passing three name candidates in priority order — `layer.output.name` →
`layer.name` → `layer.__class__.__name__` — and two new op names registered in `_KNOWN_OPS`
(`"InputLayer"` → `PLACEHOLDER`, `"BatchNormalization"` → `BATCH_NORM`), because Keras 3 reports
**class names** where TF2 reported graph op names. ✅ VERIFIED.

The two new tests double as the contract, ✅ VERIFIED verbatim
(`test_tf2_model_loaders.py:92-106`):

```python
def test_get_tensor_dtype_and_shape_without_type_spec() -> None:
    class Tensor:
        dtype = tf.float32
        shape = (None, 32, 32, 3)
    dtype, shape = _get_tensor_dtype_and_shape(Tensor())
    assert dtype == tf.float32
    assert shape == (None, 32, 32, 3)


def test_convert_tf_operation_uses_layer_metadata_when_output_name_is_generic() -> None:
    kind = _convert_tf_operation("keras_tensor_1", "conv0_conv", "Conv2D")
    assert kind is ResponseInfo.LayerKind.CONV_2D
```

> ⚠️ **SILENT FAILURE #3 — without this commit, Keras 3 gives you an empty layer list and a
> successful run that analyses nothing.**
>
> Every workflow in §6 starts by filtering `model.response_infos` on
> `info.layer.kind is ResponseInfo.LayerKind.CONV_2D`. Under Keras 3 *before* `2f39056`, output
> names are generic (`keras_tensor_1`), so `_convert_tf_operation` matches neither `_KNOWN_OPS` nor
> `_LAYER_PREFIXES` and returns `LayerKind.UNKNOWN` for everything. The filter yields `[]`.
>
> `Model.__call__([])` does not raise. `PFA.introspect` on a producer of empty responses does not
> raise. `PFA.show(recipe)` prints an empty table. **You get a clean run, a green notebook, and zero
> information** — and the reason is three layers away in a name-classification helper.
>
> **Safe default:** assert on the filter before you build the pipeline. One line:
>
> ```python
> conv2d_responses = [info.name for info in model.response_infos.values()
>                     if info.layer.kind is ResponseInfo.LayerKind.CONV_2D
>                     and 'preds' not in info.name]
> assert conv2d_responses, (
>     "No CONV_2D responses classified — are you on Keras 3 without commit 2f39056? "
>     f"kinds seen: {sorted({i.layer.kind.name for i in model.response_infos.values()})}")
> ```
>
> The `kinds seen` set makes the diagnosis immediate: an all-`UNKNOWN` set is the signature.

Even *with* the fix, one field stays broken: `typename` is still derived **only** from
`layer.output.name`, so under Keras 3 `ResponseInfo.Layer.typename` can be a useless
`"keras_tensor_1"` while `kind` is correct. ✅ VERIFIED. Use `kind`, never `typename`.

**Response names differ between TF1 and TF2**, and the repo's own test says so — ✅ VERIFIED,
`src/dnikit_tensorflow/tests/test_tf_examples.py:33-36`:

```python
if running_tf_1():
    layer_name = "conv_pw_13/Conv2D:0"
else:
    layer_name = "conv_pw_13"
```

Several `.rst` pages still show the old `'conv_pw_13/convolution:0'` spelling — including
`docs/introspectors/data_introspection/familiarity.rst:93` and `duplicates.rst:58`. **Those are
stale for TF2.** The notebooks use the bare `'conv_pw_13'`, and the notebooks are right.

### 5.6 `ResponseInfo`, and the processors you will actually use

✅ VERIFIED, `src/dnikit/dnikit/base/_response_info.py`:

```python
@dataclass(frozen=True)
class ResponseInfo:
    name: str
    dtype: np.dtype
    shape: t.Tuple[t.Optional[int], ...]   # first dim is generally None
    layer: "ResponseInfo.Layer"            # .name, .kind (LayerKind), .typename (framework str)
```

`ResponseInfo.LayerKind` is a plain `enum` with numeric values grouped by family (`:89-139`).
✅ VERIFIED, and two oddities worth knowing: **`LINEAR` and `DENSE` are the same member (`1000`)**,
so `kind is LayerKind.LINEAR` and `kind is LayerKind.DENSE` are the same test; and
`MAX_POOLING_3D` is `3003`, with **no `3002`**. There is an `ATTENTION = 8007` member and nothing
in the toolkit treats it specially.

The processors (`dnikit.processors`) are the glue between a producer's shape and an introspector's
requirements. Full `__all__`, ✅ VERIFIED (`src/dnikit/dnikit/processors/__init__.py:48-68`): `Processor`,
`MeanStdNormalizer`, `Transposer`, `FieldRemover`, `FieldRenamer`, `Flattener`, `MetadataRemover`,
`MetadataRenamer`, `SnapshotSaver`, `SnapshotRemover`, `PipelineDebugger`, `Pooler`, `Concatenator`,
`Cacher`, `Composer`, `ImageGammaContrastProcessor`, `ImageGaussianBlurProcessor`, `ImageResizer`,
`ImageRotationProcessor`.

The eight you will use, with exact signatures — ✅ VERIFIED:

| Class | Signature | Notes |
|---|---|---|
| `Processor` | `(func: Callable[[np.ndarray], np.ndarray], *, fields=None)` | Not abstract — instantiate with a lambda. `fields=None` ⇒ **all** fields. |
| `Pooler` | `(*, dim: OneOrMany[int], method: Pooler.Method, fields=None)` | `Method.MAX / SUM / AVERAGE`; `assert 0 not in dims`. **The workhorse: `dim=(1,2)` turns `B×H×W×C` into `B×C`.** |
| `Flattener` | `(order: str = 'C', fields=None)` | `B×N1×N2×…` → `B×N`; `order ∈ {C,F,A,K}`. |
| `Transposer` | `(*, dim: Sequence[int], fields=None)` | `ValueError("Unable to move the 0th (batch) dimension.")` if `dim[0] != 0`. NHWC→NCHW is `dim=[0,3,1,2]`. |
| `FieldRenamer` | `(mapping: Mapping[str, str])` | **Positional**, not keyword. |
| `FieldRemover` | `(*, fields: OneOrMany[str], keep: bool = False)` | |
| `MeanStdNormalizer` | `(*, mean: float, std: float, fields=None)` | `(x - mean) / std` |
| `ImageResizer` | `(*, pixel_format: ImageFormat, size: Tuple[int,int], fields=None)` | ⚠️ `size` is **(width, height)**; OpenCV `INTER_LINEAR`; **does not honour aspect ratio**; `assert len(data.shape) == 4`. |

All image processors raise `DNIKitException("OpenCV not available, was dnikit['image'] installed?")`
at construction time. ✅ VERIFIED.

> **Doc bug you will hit within ten minutes:** four `.rst` pages —
> `dataset_report.rst`, `duplicates.rst`, `familiarity.rst` and `how_to/introspect.rst` — write
> `ImageResizer(pixel_format=ImageResizer.Format.HWC, ...)`. **`ImageResizer.Format` does not
> exist.** The real symbol is `dnikit.base.ImageFormat`, and every notebook uses it:
> `ImageResizer(pixel_format=ImageFormat.HWC, size=(224, 224))`. ✅ VERIFIED both ways.

### 5.7 The producers and sample assets Apple ships

Three concrete `Producer`s come in the box (`dnikit.base.__all__`). ✅ VERIFIED.

**`ImageProducer`** — a directory of images:

```python
from dnikit.base import ImageProducer
import pathlib

producer = ImageProducer(pathlib.Path("/data/photos"),
                         extensions=None,     # default {"png","jpeg","jpg","tiff","bmp"}
                         recursive=True,
                         field="images")
```

Loads with `cv2.imread(path, cv2.IMREAD_UNCHANGED)`, converts BGR→RGB and BGRA→RGBA, expands
grayscale to `C=1`, outputs **NHWC**, searches both lower- and UPPER-case globs, and returns paths
`sorted()`. Sets **both** `Batch.StdKeys.IDENTIFIER` and `Batch.StdKeys.PATH` to the `pathlib.Path`
list. ✅ VERIFIED (`_image_producer.py:118-249`).

> ⚠️ **All images must have the same H×W×C.** A mismatch raises
> `DNIKitException(f"Invalid shape for image in: {image_path}, got: {image.shape}, expected:
> {expected_shape}")`. ✅ VERIFIED, and confirmed in prose at `docs/general/support.rst:83-88`:
> *"the images need to be the same dimensions. If some images in the dataset have different sizes,
> it's necessary to define a custom `Producer`."* This is the single most likely reason your first
> real-world `ImageProducer` run dies.

**`TrainTestSplitProducer`** — the `((x_train, y_train), (x_test, y_test))` tuple shape that
`tf.keras.datasets` returns:

```python
from dnikit.base import TrainTestSplitProducer
import tensorflow as tf

producer = TrainTestSplitProducer(tf.keras.datasets.cifar10.load_data(),
                                  attach_metadata=True, max_samples=-1)
subset = producer.subset(labels=["automobile"], datasets=["train"], max_samples=1000)
producer.shuffle()          # note: "this shuffling will not transfer to subsets"
```

✅ VERIFIED (`_traintest_producer.py:29-224`). The field name is **always `"samples"`**. Metadata:
`IDENTIFIER` is the list of integer indices; `LABELS` is `{"label": <the label>, "dataset": 0 for
train / 1 for test}`. `datasets=` accepts only `"train"` and `"test"`. `np.squeeze` is applied to
both samples and labels, so an `(N, 1)` label array becomes `(N,)`.

**`dnikit.samples`** — stubs for testing a pipeline without a dataset. ✅ VERIFIED:

```python
from dnikit.samples import StubProducer, StubImageDataset, StubGatedAdditionDataset

StubProducer(data: Mapping[str, np.ndarray], metadata: Optional[Mapping] = None)
StubImageDataset(dataset_size, image_width=640, image_height=480, channel_count=3)
StubGatedAdditionDataset(dataset_size, minimum_sequence_length=100, maximum_sequence_length=100)
```

And `dnikit_tensorflow` ships sample models and datasets. ✅ VERIFIED
(`_sample_models.py`, `_sample_datasets.py`):

```python
from dnikit_tensorflow import TFModelExamples, TFModelWrapper, TFDatasetExamples

mobilenet = TFModelExamples.MobileNet()      # -> TFModelWrapper
mobilenet.model             # dnikit.base.Model
mobilenet.preprocessing     # Processor wrapping keras preprocess_input
mobilenet.postprocessing    # None
mobilenet.response_infos    # Mapping[str, ResponseInfo]  (a PROPERTY, not a method)

stages = mobilenet(requested_responses=['conv_pw_13'])   # pre + model + post, flattened by pipeline()

cifar10  = TFDatasetExamples.CIFAR10(attach_metadata=True, max_samples=-1)
cifar100 = TFDatasetExamples.CIFAR100(label_mode='fine')   # or 'coarse'
mnist    = TFDatasetExamples.MNIST()
fashion  = TFDatasetExamples.FashionMNIST()
```

Note the distinction that trips people up: **`mobilenet(...)` returns a tuple of stages**
(preprocessing + model + postprocessing), whereas **`mobilenet.model(...)` returns just the model
stage**. Both appear in the notebooks and they are not interchangeable — if you apply
`mobilenet.preprocessing` yourself, use `mobilenet.model(...)`.

`TFModelExamples.MobileNet` is a one-liner, ✅ VERIFIED (`_sample_models.py:149-151`):

```python
MobileNet: t.Callable[..., TFModelWrapper] = lambda: (
    TFModelWrapper.from_keras(tf.keras.applications.mobilenet.MobileNet(),
                              tf.keras.applications.mobilenet.preprocess_input))
```

> 🔴 **GAP — `TFModelWrapper.load_keras_model` round-trips through a temp `.h5`.**
> ✅ VERIFIED (`_sample_models.py:84-96`): it calls `model.save(model_path)` into a
> `tempfile.TemporaryDirectory()` as `model.h5`, then `load_tf_model_from_path`. Keras 3 changed
> bare `.h5` saving, and **PR #4 did not touch this file**. Whether it still works under
> TF 2.16+ is **UNVERIFIED**.
> *Resolution:* run `TFModelExamples.MobileNet()` on a Keras 3 install.
> *Safe default:* skip `TFModelExamples` entirely and use
> `load_tf_model_from_memory(model=tf.keras.applications.MobileNet())` plus a hand-written
> `Processor(tf.keras.applications.mobilenet.preprocess_input)`.

---

## 6. The introspectors

`dnikit.introspectors.__all__`, ✅ VERIFIED (`introspectors/__init__.py:56-77`):

```
DimensionReduction, DimensionReductionStrategyType, OneOrManyDimStrategies,
Duplicates, DuplicatesThresholdStrategyType,
IUA,
FamiliarityDistribution, FamiliarityStrategyType, FamiliarityResult, Familiarity, GMMCovarianceType,
PFA, PFAKLDiagnostics, PFAEnergyDiagnostics, PFARecipe,
PFAUnitSelectionStrategyType, PFAStrategyType, PFACovariancesResult,
DatasetReport, ReportConfig
```

The protocol is deliberately loose — ✅ VERIFIED, `_introspector.py:20-57`:

```python
class Introspector(t.Protocol):
    introspect: t.Callable[..., t.Any]   # static factory; args are algorithm-dependent
```

**The shape-requirement table is the thing to memorise**, because it is the source of most first-run
failures. ✅ VERIFIED across the five implementations:

| Introspector | Input shape | Returns | Streams? |
|---|---|---|---|
| `DimensionReduction` | **exactly 2-D** `B×N` | a `PipelineStage` | only with `Strategy.PCA` |
| `Familiarity` | **exactly 2-D** `B×N` (40–100 dims recommended) | a `PipelineStage` | no (GMM accumulates) |
| `Duplicates` | **exactly 2-D** `B×N` (asserted) | a result object | no (accumulates) |
| `PFA` | **exactly 2-D** `B×C` | a result object | **yes** |
| `IUA` | **un-pooled, any rank** | a result object | yes |
| `DatasetReport` | pooled responses + `IDENTIFIER` (+ `LABELS`) | a `DataFrame` holder | partially (3 passes) |

`IUA` is the odd one out: it wants **raw, un-pooled** conv responses, because it counts inactive
units per element and flattens the non-batch dimensions itself. Everything else wants `Pooler` or
`Flattener` in front of it.

### 6.1 `DimensionReduction`

Not an analysis in itself — the enabling step for everything else, and the thing that makes
`Duplicates` and `Familiarity` tractable.

✅ VERIFIED:

```python
DimensionReduction.introspect(producer: Producer, *,
                              strategies: OneOrManyDimStrategies,
                              batch_size: t.Optional[int] = None) -> DimensionReduction
```

`OneOrManyDimStrategies = Union[DimensionReductionStrategyType, Mapping[str,
DimensionReductionStrategyType]]`. A single strategy is `._clone()`-d per field through a
`defaultdict`; a mapping applies per-field, and **fields absent from the mapping are left
untouched**. The result is itself a `PipelineStage`, so you consume it with `pipeline()`.

| Strategy | Constructor | Streaming | Notes |
|---|---|---|---|
| `PCA` | `PCA(target_dimensions: int = 2)` | ✅ `IncrementalPCA` | `default_batch_size() = max(target_dimensions*5, 500)`; skips `partial_fit` for batches smaller than `target_dimensions` |
| `StandardPCA` | `StandardPCA(target_dimensions=2)` | ❌ | exact `sklearn.decomposition.PCA` |
| `TSNE` | `TSNE(target_dimensions=2, *, _parameters=None, **kwargs)` | ❌ **one-shot** | kwargs forwarded to `sklearn.manifold.TSNE` |
| `UMAP` | `UMAP(target_dimensions=2, *, _parameters=None, **kwargs)` | ❌ but has `.transform` | `umap-learn`; **lazy import** |
| `PaCMAP` | `PaCMAP(target_dimensions=2, *, _parameters=None, **kwargs)` | ❌ **one-shot** | lazy import |

All ✅ VERIFIED from `_dim_reduction/_reducers.py`.

The documented recipe, and the one every notebook follows — ✅ VERIFIED
(`notebooks/data_introspection/dimension_reduction.ipynb`):

```python
from dnikit.base import pipeline
from dnikit.introspectors import DimensionReduction

BATCH_SIZE = 500

partial_reducer = DimensionReduction.introspect(
    producer, batch_size=BATCH_SIZE, strategies=DimensionReduction.Strategy.PCA(40))
partially_reduced = pipeline(producer, partial_reducer)

umap = DimensionReduction.introspect(
    partially_reduced, batch_size=BATCH_SIZE, strategies=DimensionReduction.Strategy.UMAP(2))
umap_reduced = pipeline(partially_reduced, umap)
```

**1024 → 40 with streaming PCA, then 40 → 2 with UMAP.** Do not go straight to 2-D: t-SNE and UMAP
on 1024-dim input are slow and, per the docs, worse.

Gotchas, ✅ VERIFIED:

- Input must be **exactly** 2-D:
  `DNIKitException(f'Unable to reduce response of shape {field.shape}. The shape is expected to
  have 2 dimensions')`. Use `Flattener` or `Pooler` first.
- `PCA.check_batch_size` raises when `batch_size < target_dimensions`, with a message containing a
  missing space — `'...requires that thebatch_size ({batch_size}) must be larger or equal to the
  target_dimensions ({target_dimensions}).'` (`_reducers.py:69-72`). If you grep for
  `"the batch_size"` you will not find it.
- Calling the wrong transform: `TSNE.transform` / `PaCMAP.transform` →
  `DNIKitException("transform() not implemented, call transform_one_shot()")`, and
  `PCA.transform_one_shot` → the mirror message.
- One-shot strategies are handled by computing the whole embedding once and **slicing it by a
  running offset** as batches flow through (`_dimension_reduction.py:161-188`). The consequence:
  **the pipeline must be replayed in the same order.** A shuffled or non-deterministic producer
  under a one-shot reducer silently mis-assigns coordinates.
- UMAP and PaCMAP are imported lazily, with a source comment naming the reason: *"Caution due to
  numba SIGSEGV on task cleanup"* (`_reducers.py:243-244`, `:308-309`). ✅ VERIFIED verbatim.
- `UMAP.transform` redirects stdout to `os.devnull` because *"File umap.umap_.py has a print
  statement `print("inside function\n", graph)` that clutters DNIKit stdout"* (`:334-337`).
  ✅ VERIFIED verbatim — worth knowing, because it means **UMAP-stage exceptions can lose their
  stdout context**.
- **`umap` on PyPI is not `umap-learn`.** DNIKit needs `umap-learn`, which imports as `umap`. The
  unrelated `umap` package will install cleanly and then fail at import. Called out at
  `docs/general/support.rst:72-80`. ✅ VERIFIED.
- Missing packages give `ImportError("pacmap not available, was dnikit['dimreduction'] or pacmap
  installed?")` and the UMAP equivalent.

### 6.2 `Familiarity` — out-of-distribution and rare-data scoring

This is the introspector that answers *"does my training set actually resemble what the model will
see?"* It fits a density model over activations, then scores every sample against it.

✅ VERIFIED:

```python
Familiarity.introspect(producer: Producer, *,
                       strategy: t.Optional[FamiliarityStrategyType] = None,   # default GMM()
                       batch_size: int = 1024) -> Familiarity
```

Like `DimensionReduction`, it returns a **`PipelineStage`, not a result**. It is two-phase — fit,
then score:

```python
from dnikit.base import pipeline
from dnikit.introspectors import Familiarity

familiarity = Familiarity.introspect(reduced_producer)      # phase 1: fit
scored = pipeline(reduced_producer, familiarity)            # phase 2: score

for batch in scored(batch_size=8):
    for response_name, scores in batch.metadata[familiarity.meta_key].items():
        print(response_name, [s.score for s in scores])
```

`familiarity.meta_key` is a `Batch.DictMetaKey[FamiliarityResult]`; for the GMM strategy it is the
class variable `Batch.DictMetaKey[FamiliarityResult]("GMM")` (`_gmm_familiarity.py:117`).
✅ VERIFIED.

The strategy, ✅ VERIFIED (`_gmm_familiarity.py:69-174`):

```python
Familiarity.Strategy.GMM(*, gaussian_count: int = 5,
                            convergence_threshold: float = 1e-3,
                            max_iterations: int = 200,
                            covariance_type: GMMCovarianceType = GMMCovarianceType.DIAG,
                            _random_state: t.Optional[RandomState] = None)
```

It wraps `sklearn.mixture.GaussianMixture`. `GMMCovarianceType.FULL = 'full'` /
`GMMCovarianceType.DIAG = 'diag'`, and the guidance is explicit — ✅ VERIFIED verbatim,
`_gmm_familiarity.py:51-56`:

> *"If there are concerns about overfitting due to a lack of data, dimensions are high wrt. the data
> available, etc. Then use `DIAG`. This is typically the case when working with **DNN embeddings**.
> Else, use `FULL`. For example, if fitting 2D data."*

Which is to say: **for the workflow in this guide, keep the default `DIAG`.** You are always
scoring DNN embeddings.

> ⚠️ **SILENT FAILURE #4 — the familiarity score's sign is documented one way and implemented the
> other, and sorting the wrong direction silently inverts your entire analysis.**
>
> The `FamiliarityResult` docstring says: *"Familiarity score. Note: This will actually be the log
> score."* The implementation returns `scipy.special.logsumexp(log_pdf_i + log_weight_i)` — a
> **positive log-density**, so **higher = more familiar**. But the docs' mathematics section
> (`docs/introspectors/data_introspection/familiarity.rst:333-337`) describes it as the
> **negative** log-likelihood, under which lower would be more familiar. ✅ VERIFIED both readings.
>
> The notebooks resolve it: they sort `reverse=True` to get "most familiar". **Treat "higher = more
> familiar" as the operational truth.**
>
> Why this is a silent failure and not a documentation nit: the entire use of `Familiarity` is
> ranking. If you sort the wrong way while hunting rare data, you get the *most typical* samples in
> your dataset, presented as the rarest. Nothing errors. The numbers look plausible. Everything
> downstream — the samples you re-label, the images you send for review, the classes you decide to
> collect more of — is exactly backwards.
>
> **Safe default:** verify the direction once, on data whose answer you know, before you trust a
> ranking:
>
> ```python
> import numpy as np
>
> scored = pipeline(reduced, familiarity)
> rows = []
> for batch in scored(batch_size=64):
>     for element in batch.elements:
>         result = element.metadata[familiarity.meta_key][RESPONSE_NAME]
>         rows.append((element.metadata[Batch.StdKeys.IDENTIFIER], result.score))
>
> rows.sort(key=lambda r: r[1], reverse=True)
> print("MOST familiar (should look boring/typical):", rows[:5])
> print("LEAST familiar (should look odd/rare):    ", rows[-5:])
> ```
>
> Look at the images. If "most familiar" looks weird, your sort is inverted.

**Comparing two distributions.** The documented heuristic uses the likelihood ratio
`L(f→p) = F(D_f, D_p) / F(D_f, D_f)` — fit on `f`, score `p`, normalise by scoring `f` against
itself. ✅ VERIFIED (`familiarity.rst:266-283`):

| Ratio | Reading |
|---|---|
| `< 0.6` | huge gap — **re-collect data** |
| `0.6 – 0.8` | small gap, worth inspecting |
| `0.8 – 1.2` | fine |
| `> 1.2` | gap worth inspecting |

⚠️ Note the implementation detail that will confuse you if you follow the notebook rather than the
prose: the distribution notebook computes the **difference of mean log-scores**,
`stats['test'] - stats['train']`, which is the **log** of that ratio. ✅ VERIFIED. So the thresholds
above must be logged before you compare against a notebook-style number: `log(0.6) ≈ -0.51`,
`log(0.8) ≈ -0.22`, `log(1.2) ≈ +0.18`.

Other gotchas, ✅ VERIFIED:

- Fitting **accumulates the full producer in memory** (`_accumulate_batches`, default
  `batch_size=1024`).
- Input must be 2-D per field; the docs recommend **40–100 dimensions** after reduction.
- `src/dnikit/tests/test_familiarity.py` records that DNIKit's log-pdf differs slightly from
  sklearn's: the test compares `np.exp(score)` with `atol=1e-2` and warns that **ranking can swap
  for close samples** (repo issue #427). Do not read fine-grained rank differences as signal.

### 6.3 `Duplicates` — the one you should run first

Near-duplicates in a training set inflate your validation score, waste capacity, and — if they
straddle the train/test split — invalidate every number you have. This is the cheapest useful thing
DNIKit does.

✅ VERIFIED:

```python
Duplicates.introspect(producer: Producer, *,
                      batch_size: int = 32,
                      threshold: t.Optional[DuplicatesThresholdStrategyType] = None  # default Slope()
                      ) -> Duplicates

duplicates.results   # Mapping[str, Sequence[Duplicates.DuplicateSetCandidate]]
duplicates.count     # int, number of elements in the producer
```

`DuplicateSetCandidate` carries `std: float`, `mean: float` (distance to centroid),
`projection: Optional[np.ndarray]` (2-D PCA, **only when the cluster has more than 5 members**),
`indices: Sequence[int]`, `batch: Batch`, and a `size` property. ✅ VERIFIED.

Two threshold strategies, ✅ VERIFIED:

- `Duplicates.ThresholdStrategy.Percentile(percentile: float)` — e.g. `98.5` means 98.5% of pairs
  are *not* considered close.
- `Duplicates.ThresholdStrategy.Slope(sensitivity: int = 5)` — an elbow finder, and the default.
  `__post_init__` raises ``ValueError("`sensitivity` must be > 2")``. Docstring, ✅ VERIFIED:
  *"A lower sensitivity (down to 2) will consider more items to be close... A sensitivity of 20 ...
  is a reasonable large value."*

The algorithm, ✅ VERIFIED (`_duplicates.py:278-428`), because knowing it tells you how to tune it:

1. `_accumulate_batches(producer, batch_size=batch_size)` — **everything into RAM.**
2. **Per-column L2 normalisation** of the response matrix: `l2 = np.linalg.norm(responses, axis=0);
   normalized = responses / l2` — *"this prevents large values in a single column from dominating
   the distance metric."*
3. `annoy.AnnoyIndex(dim, "euclidean")`, `index.set_seed(0)`, `index.build(30)` — 30 trees,
   *"the higher the number, the better the precision when querying (at the cost of time and
   memory)."*
4. `n = 10` nearest neighbours per item — *"n can be anything > 2 ... a value of 10 gives similar
   distance threshold results as the previous kCDTree implementation."*
5. The threshold is applied to `np.trim_zeros(np.sort(distances.reshape(count*n)))`.
6. Clusters are the **transitive closure** of overlapping neighbour sets.
7. Within a cluster, elements are ordered by a 1-D PCA projection (if >2 members) and a 2-D
   `projection` is computed (if >5).

Step 6 is the one to keep in mind: transitive closure means a chain of "each pair is close" merges
into a single large cluster even when the endpoints are not similar. Cluster `mean` (distance to
centroid) is your sanity check — sort by it. The traversal idiom, ✅ VERIFIED:

```python
for response_name, clusters in duplicates.results.items():
    clusters = sorted(clusters, key=lambda x: x.mean)   # tightest clusters first
    for cluster in clusters[:20]:
        ids = [e.metadata[Batch.StdKeys.IDENTIFIER] for e in cluster.batch.elements]
        print(f"{response_name}: size={cluster.size} mean={cluster.mean:.4f} -> {ids}")
```

⚠️ Two sharp edges, ✅ VERIFIED: `assert len(responses.shape) == 2, "Requires 1d vector per
element"`; and **if a normalised column has L2 == 0, `responses / l2` produces NaN/inf with no
guard in the code.** A constant channel — entirely plausible after aggressive pooling of a dead
filter — poisons the index silently. Run `IUA` (§6.4) first if you suspect dead units, or drop
zero-variance columns before you hand the array over.

### 6.4 `IUA` — Inactive Unit Analysis

Dying-ReLU detection: how many units are effectively zero, per layer, across your data.

✅ VERIFIED:

```python
IUA.introspect(producer: Producer, *, batch_size: int = 32,
               rtol: float = 1e-05, atol: float = 1e-08) -> IUA

iua.results   # Mapping[str, IUA.Result]
IUA.show(iua, *, vis_type: str = IUA.VisType.TABLE,
         response_names: t.Optional[t.Sequence[str]] = None)

IUA.VisType.TABLE == 'table'
IUA.VisType.CHART == 'chart'
```

`IUA.Result` fields: `mean_inactive: float`, `std_inactive: float`, `inactive: Sequence[float]`
(per-probe counts), `unit_inactive_count: Sequence[float]`, `unit_inactive_proportion:
Sequence[float]`. "Inactive" is literally
`np.isclose(responses, np.zeros_like(responses), rtol=rtol, atol=atol)`, counted per batch element
with dimension 0 preserved and the rest flattened. ✅ VERIFIED (`_iua.py`).

Notebook usage, ✅ VERIFIED verbatim from
`notebooks/model_introspection/inactive_unit_analysis.ipynb`:

```python
response_producer = pipeline(
    data_producer,
    FieldRenamer({"images": "input_1:0"}),
    model(conv2d_responses),
    Transposer(dim=(0, 3, 1, 2))
)
iua = IUA.introspect(response_producer)
IUA.show(iua)                                                   # pandas table
IUA.show(iua, vis_type=IUA.VisType.CHART, response_names=['conv_pw_9'])
```

⚠️ The `FieldRenamer({"images": "input_1:0"})` in that cell uses a **TF1-style** input name with the
`:0` suffix (§5.5). On TF2 the input is named `input_1` without it. Read the notebook as a shape,
not as a copyable literal, and check `model.input_layers` for your actual name.

Errors from `IUA.show`, ✅ VERIFIED: `ValueError(f'Invalid response passed: {response}. Try one of:
{result_keys}')`; `ValueError("Empty list of layers specified...")`; ``ValueError('Unexpected input
for parameter `vis_type`...')``. And two wrong messages worth recognising —
`DNIKitException("PIL not available, was 'dnikit[notebook]' installed?")` is raised when **pandas**
is missing (`_iua.py:215-216`), and `_show_chart` builds
`plt.subplots(len(responses), figsize=(7, 70))` — **a hard-coded 70-inch-tall figure**, which is
why the chart view looks broken for anything but a handful of layers. Pass `response_names`.

### 6.5 `PFA` — Principal Filter Analysis

This is the reason a compression engineer should read this guide. PFA looks at the **covariance of
each layer's responses over your data**, decides how many of that layer's filters are actually
carrying independent information, and hands you a per-layer recommended width.

✅ VERIFIED (`_pfa/_pfa.py`):

```python
PFA.introspect(producer: Producer, *, batch_size: int = 32,
               epsilon_inactive: float = 1e-8) -> PFA

pfa.get_recipe(*, strategy: t.Optional[PFAStrategyType] = None,                 # default KL()
                  unit_strategy: t.Optional[PFAUnitSelectionStrategyType] = None # default L1Max()
              ) -> t.Mapping[str, PFARecipe]

PFA.show(recipe_result: OneOrMany[Mapping[str, PFARecipe]], *,
         vis_type: str = PFA.VisType.TABLE,
         include_columns: t.Optional[t.Sequence[str]] = None,
         exclude_columns: t.Optional[t.Sequence[str]] = None)

pfa.failed_responses   # Sequence[str] -- layers dropped for having fewer samples than features
```

**The input requirement is 2-D `Batch × C`.** ✅ VERIFIED verbatim, `_pfa.py:120-128`:

> *"The responses generated by `producer` are assumed to be **2D (Batch x C)**. Thus it might be
> necessary to `pipeline` together the `Producer` with a `Processor` (e.g., `Pooler`), that
> transforms each individual response from multi-dimensional to mono-dimensional."*

Violating it raises `DNIKitException(f'Unable to introspect response {name}, of shape
{shape},which has more than two dimensions.')` — note the missing space, again.

Under the hood: covariances accumulate in streaming form (`_count`, `_sum_x`, `_sum_xxt`), then
`np.linalg.eigh` gives eigenvalues clamped with `np.maximum(0.0, ...)` and returned **descending**.
Inactive units are those with `var < epsilon_inactive * np.max(var)` where
`var = np.abs(np.diag(covariances))`. ✅ VERIFIED (`_covariances_calculator.py:39-101`).

**Compression strategies** — ✅ VERIFIED (`_pfa_algorithms.py`):

| Strategy | Signature | What it does |
|---|---|---|
| `PFA.Strategy.KL` | `KL(interpolation_function=None)` | **Parameter-free.** `kl = scipy.stats.entropy(pk=normalised_eigenvalues + eps, qk=uniform)`; `max_kl = log(C)`; `units_ratio = interpolation(kl, max_kl)`; `recommended = ceil(C * units_ratio)`. Default interpolation is `KL.LinearInterpolation()` = `1 - kl/max_kl`. Diagnostics: `PFAKLDiagnostics(kl_divergence, units_ratio)`. |
| `PFA.Strategy.Energy` | `Energy(energy_threshold: float, min_kept_count: int = 0)` | Keep top eigenvalues until cumulative energy ≥ threshold. `ValueError('energy_threshold should be between 0.0 and 1.0, but it is {v}')`. Logs a warning if `min_kept_count` forces the energy constraint to be violated. Diagnostics: `PFAEnergyDiagnostics(total_kept_energy)`. |
| `PFA.Strategy.Size` | `Size(relative_size: float, min_kept_count: int = 0, epsilon_energy: float = 1e-8)` | **Cross-layer.** Builds per-layer exclusive cumulative-energy curves, takes `np.percentile(all_values, 100*relative_size)` as a single global energy threshold, then delegates to `Energy`. |

Start with `KL()` because it has no knobs; move to `Energy` when you want an explicit
compression/accuracy dial.

**Unit-selection strategies** decide *which* filters to drop, given a count. ✅ VERIFIED
(`_pfa_units.py`): `AbsMax`, `AbsMin`, `L1Max`, `L1Min`, all instances of
`_DirectionalStrategy(distance ∈ {ABS, L1}, direction ∈ {np.nanmax, np.nanmin})`. They operate on
`|Pearson correlation|` derived from the covariance
(`corr = covar / max(sqrt(var_i*var_j), 1e-8)`) with the diagonal and all inactive rows/columns set
to NaN, and return the indices of **maximally-correlated (i.e. redundant)** units — the first
`covariances.inactive_units.shape[0]` entries being the inactive ones.
`PFA.UnitSelectionStrategy.get_algos()` yields one instance of each, for comparison runs.

`PFARecipe` (`_recommendation.py:58-117`) carries `original_output_count`,
`recommended_output_count`, `maximally_correlated_units: Sequence[int]`, `number_inactive_units:
int`, and `diagnostics`. ✅ VERIFIED.

> ⚠️ **SILENT FAILURE #5 — PFA drops layers it cannot analyse, and only `warnings.warn`s.**
>
> If a response has **fewer samples than features**, PFA skips it entirely and emits:
>
> ```
> Attempted to compute covariance of data matrix with less data points than features
> (data_point#, feature#) = (N, C)
> ```
>
> The layer name lands in `pfa.failed_responses` and **is simply absent from the recipe**.
> ✅ VERIFIED (`_pfa.py`, `_covariances_calculator.py`).
>
> This is easy to hit and easy to miss. A 1024-channel layer needs more than 1024 samples; running
> PFA on `max_samples=500` for a quick smoke test silently analyses only your narrow early layers.
> `warnings.warn` prints once per location by Python's default filter, and in a Jupyter notebook it
> lands above the cell output where nobody looks. `PFA.show(recipe)` then prints a perfectly
> well-formed table of the layers that *did* work, and you plan a retrain against it.
>
> **Safe default:** check `failed_responses` immediately, every time.
>
> ```python
> pfa = PFA.introspect(producer, batch_size=500)
> if pfa.failed_responses:
>     raise RuntimeError(
>         f"PFA skipped {len(pfa.failed_responses)} layers for insufficient samples: "
>         f"{sorted(pfa.failed_responses)}. Increase max_samples above the widest layer's "
>         f"channel count.")
> ```

`PFA.show` table columns, ✅ VERIFIED: `["layer name", "original count", "recommended count",
"units to keep", "KL divergence", "PFA strategy", "units ratio", "kept energy"]`. Only the first
four are shown by default; **`include_columns=[]` means show *all* columns**, which is
counter-intuitive enough to be worth stating twice. `"units to keep"` is
`set(range(original)) - set(maximally_correlated_units)`.

Errors, ✅ VERIFIED — the first one is the mistake everyone makes:

- Passing the `PFA` object instead of a recipe → `DNIKitException("The output of `PFA.introspect`
  has been passed into `PFA.show()`. Please pass the output of `pfa.get_recipe` into `PFA.show()`.
  The default behavior can be used by calling: `pfa = PFA.introspect(); recipe = pfa.get_recipe();
  PFA.show(recipe)`")`
- ``ValueError("`recipe_result` parameter input is emtpy")`` — **`emtpy` is the actual spelling in
  the source** (`_pfa.py:387`).
- Multiple recipes with `VisType.CHART` → `DNIKitException("Only one recipe's chart can be plotted
  at a time. ...")`
- `DNIKitException("No columns selected, are the `exclude columns` the same as the ones to
  `include`")`
- Missing pandas → `DNIKitException("PIL not available, was 'dnikit[notebook]' installed?")` —
  the same wrong message as `IUA` (`_pfa.py:229-230`).

**Two documentation bugs on the PFA page specifically** (`network_compression.rst:150-155`),
✅ VERIFIED against source: it shows `pfa.get_recipe(compression=PFA.Strategy.Energy(...))` — **the
keyword is `strategy=`**; it uses a non-existent `PFA.Strategy.SOME_STRATEGY` as a placeholder; and
it calls `dnikit_model.response_infos()` as a method when it is a **property**.

**PFA does not modify your model.** The docs emphasise this and so will we — ✅ VERIFIED verbatim:

> *"Note that PFA does not compress a network directly! It's important to instead retrain the
> network model with the suggested layer sizes."*

The documented six-step workflow (`network_compression.rst:358-451`): (1) train, (2) run inference
and collect responses, (3) reduce conv responses to one value per filter, (4) `PFA.introspect`,
(5) `get_recipe` with a strategy, (6) act on the recipe. *"The user is responsible for steps 1 and
6, while all the other steps can be done within DNIKit."*

### 6.6 `DatasetReport` — four introspectors, one DataFrame

`DatasetReport` bundles **Familiarity + Duplicates + a 2-D projection + a label/ID summary** and
emits a `pandas.DataFrame` with one row per sample, shaped for the **Symphony** UI
(`apple/ml-symphony`).

✅ VERIFIED:

```python
DatasetReport.introspect(producer: Producer, *,
                         config: t.Optional[ReportConfig] = None,
                         batch_size: int = 1024) -> DatasetReport

report.data                                  # pandas.DataFrame, one row per sample
report.to_disk(directory='./report_save', *, overwrite=False)
DatasetReport.from_disk(directory) -> DatasetReport
```

```python
ReportConfig(
    projection:  t.Optional[OneOrManyDimStrategies]        = <UMAP(2) or None>,
    duplicates:  t.Optional[DuplicatesThresholdStrategyType] = Duplicates.ThresholdStrategy.Slope(),
    familiarity: t.Optional[FamiliarityStrategyType]       = Familiarity.Strategy.GMM(),
    dim_reduction: t.Optional[OneOrManyDimStrategies]      = None,   # None => auto PCA(40) for >40-dim fields
    split_familiarity_min: int = 50,
)
```

✅ VERIFIED (`_dataset_report_stages.py:65-134`). Set any component to `None` to skip it.
`config.n_stages` is 3 if familiarity or projection is enabled, 2 if only duplicates, else 1 — and
each stage is one `multi_introspect` call over one pass of the data, which is why `Cacher` matters
so much here.

> ⚠️ **The projection silently disables itself if `umap-learn` is missing.** ✅ VERIFIED:
> `_projection_default()` logs *"UMAP not available, not running projection in report.To fix,
> install dnikit['dimreduction']."* (missing space and all) and returns `None`. Your report is built
> successfully, with **no `projection_*_x` / `projection_*_y` columns at all**, and Symphony shows
> you a scatter plot with nothing in it. It is a log line, not an exception. If you need the
> projection, assert on the columns after `introspect`.

**The column contract** — this is the interface to Symphony and the reason the report is useful
outside it. Names are sanitised by `_string_util.remove_special_characters`, which strips everything
outside `[a-zA-Z0-9-_]` and maps spaces to `_`. ✅ VERIFIED (`_dataframe_formatting.py` + tests):

```
id
<label_dimension>                                          # one column per LABELS key
duplicates_<response>
projection_<response>_x , projection_<response>_y
familiarity_<response>
splitFamiliarity_<response>_byAttr_<label_dimension>       # value is a dict {label: score}
```

Pinned by `src/dnikit/tests/test_dataset_report.py:504-536`, ✅ VERIFIED verbatim:

```python
overall_title.make_title('response_1') == 'familiarity_response_1'
split_title.make_title('response_1')   == 'splitFamiliarity_response_1_byAttr_color_blue'
_DataframeFamiliarityTitle._format_split_suffix('shape') == '_byAttr_shape'
```

Duplicates columns use **`-1` for "not in a cluster"** and otherwise the cluster number
(`_report_builder_introspectors.py:120-144`). ✅ VERIFIED:

```
   duplicates_result
0                 -1
3                  0
5                  0
6                  0
```

Requirements and gotchas, ✅ VERIFIED:

- **`Batch.StdKeys.IDENTIFIER` is required** — `_SummaryBuilder` reads it unconditionally. The docs
  add: *"For the moment, the `Batch.StdKeys.IDENTIFIER` should be a path to the image data."*
  A trailing `Cacher()` will attach a numeric one if you have not (§3.5).
- **All `LABELS` values are stringified** by a pre-stage `Composer`, because the summary builder and
  the split-familiarity filter assume `str`. The test `test_nonstr_labels` confirms ints, floats,
  tuples and bools all become their `str()`. Your integer class IDs come back as `"3"`.
- `Batch.StdKeys.LABELS` is optional. Without it there is no split familiarity and the columns
  reduce to `{id, duplicates_<r>, projection_<r>_x, projection_<r>_y, familiarity_<r>}`.
- **Labels with fewer than `split_familiarity_min` (default 50) samples are dropped** from split
  familiarity — so your rarest class, which is exactly the one you wanted to inspect, is the one
  most likely to be excluded. Lower the threshold deliberately.
- Missing pandas → `DNIKitException("pandas not available, was dnikit['dataset_report'] or
  dnikit['dataset_report_base'] installed?")`. **Both names are wrong**: the real extra is
  `dataset-report` with a hyphen, and `dataset_report_base` does not exist.
- `to_disk` without `overwrite=True` → `FileExistsError('Report file already exists at this
  path.Set "overwrite=True" ...')`. `from_disk` on a directory without the pickle →
  `FileNotFoundError(f"{directory} missing necessary file: report_save_data.pkl. ...")`.
- **The storage format is a pandas pickle.** Version-fragile, not portable. Do not archive analyses
  in it.

Minimal invocation from the docs (`dataset_report.rst:44-64`) — reproduced here **with the
`ImageResizer.Format` doc bug corrected**, since the original does not run:

```python
from dnikit.base import pipeline, ImageFormat
from dnikit.processors import Cacher, ImageResizer, Pooler
from dnikit.introspectors import DatasetReport
from dnikit_tensorflow import TFDatasetExamples, TFModelExamples

cifar10 = TFDatasetExamples.CIFAR10(attach_metadata=True)
mobilenet = TFModelExamples.MobileNet()

producer = pipeline(
    cifar10,
    ImageResizer(pixel_format=ImageFormat.HWC, size=(224, 224)),   # docs say ImageResizer.Format — wrong
    mobilenet(requested_responses=['conv_pw_13']),
    Pooler(dim=(1, 2), method=Pooler.Method.MAX),
    Cacher(),
)
report = DatasetReport.introspect(producer)
```

Duplicates-only, if that is all you want (much cheaper — `n_stages` drops to 2):

```python
from dnikit.introspectors import DatasetReport, ReportConfig

config = ReportConfig(projection=None, familiarity=None)
report = DatasetReport.introspect(producer, config=config)
```

---

## 7. One complete worked example

Everything above, in one script you can run top to bottom. CIFAR-10 through MobileNet: cache the
activations once, reduce them, audit for duplicates, score for rarity, then produce a PFA pruning
recipe.

**Evidence status:** every API call below is ✅ VERIFIED against the repository — signatures from
source, the pipeline shape from `notebooks/model_introspection/principal_filter_analysis.ipynb` and
`notebooks/data_introspection/dataset_report.ipynb`. **The script as a whole has not been
executed by us** (§11 G1). The assertions in it exist precisely because we could not run it.

```python
"""
DNIKit pre-flight audit: dataset quality + network width, before conversion.

Verified against apple/dnikit @ 2f39056 (2026-07-09).
Requires: make install  (from a git clone -- PyPI 2.0.0 predates the Keras 3 fix)
"""
import typing as t

import numpy as np

from dnikit.base import Batch, ImageFormat, ResponseInfo, peek_first_batch, pipeline
from dnikit.exceptions import enable_deprecation_warnings
from dnikit.introspectors import Duplicates, Familiarity, PFA, DimensionReduction
from dnikit.processors import Cacher, ImageResizer, Pooler
from dnikit_tensorflow import TFDatasetExamples, TFModelExamples

enable_deprecation_warnings(error=True)     # the notebooks all open with this

BATCH_SIZE = 500
MAX_SAMPLES = 2000          # must exceed the widest layer's channel count -- see step 5
RESPONSE = "conv_pw_13"     # TF2 spelling; TF1 would be "conv_pw_13/Conv2D:0"

# ---------------------------------------------------------------- 1. model + layer selection
mobilenet = TFModelExamples.MobileNet()

conv2d_responses = [
    info.name
    for info in mobilenet.response_infos.values()          # PROPERTY, not a method
    if info.layer.kind is ResponseInfo.LayerKind.CONV_2D
    and "preds" not in info.name
]

# SILENT FAILURE #3 guard: Keras 3 without commit 2f39056 classifies everything UNKNOWN.
assert conv2d_responses, (
    "No CONV_2D responses classified. Are you on Keras 3 without commit 2f39056? "
    f"kinds seen: {sorted({i.layer.kind.name for i in mobilenet.response_infos.values()})}"
)
print(f"{len(conv2d_responses)} Conv2D responses selected")

# ---------------------------------------------------------------- 2. data
cifar10 = TFDatasetExamples.CIFAR10(attach_metadata=True, max_samples=MAX_SAMPLES)
cifar10.shuffle()

dataset = pipeline(
    cifar10,
    mobilenet.preprocessing,                                       # keras preprocess_input
    ImageResizer(pixel_format=ImageFormat.HWC, size=(224, 224)),   # (width, height)!
)

# SILENT FAILURE #2 guard: never trust the shape-matched auto-rename silently.
raw = peek_first_batch(dataset, batch_size=1)
print("producer fields:", {k: v.shape for k, v in raw.fields.items()})
print("model inputs:   ", {k: v.shape for k, v in mobilenet.model.input_layers.items()})

# ---------------------------------------------------------------- 3. inference, cached once
cacher = Cacher()      # single-use per pipeline; writes one pickle per batch to a temp dir

responses = pipeline(
    dataset,
    mobilenet.model(conv2d_responses),                 # .model(...) -- preprocessing applied above
    Pooler(dim=(1, 2), method=Pooler.Method.MAX),      # B x H x W x C  ->  B x C
    cacher,
)

# Nothing has run yet. Force one full pass, then reuse from disk.
for _ in responses(batch_size=BATCH_SIZE):
    pass
cached = cacher.as_producer()
print(f"cached to {cacher.storage_path}")

# ---------------------------------------------------------------- 4. dataset audit
# 4a. reduce 1024 -> 40 (streaming IncrementalPCA), as the docs recommend
reducer = DimensionReduction.introspect(
    cached, batch_size=BATCH_SIZE,
    strategies=DimensionReduction.Strategy.PCA(40))
reduced = pipeline(cached, reducer)

# 4b. near-duplicates
duplicates = Duplicates.introspect(reduced, batch_size=BATCH_SIZE)
clusters = sorted(duplicates.results[RESPONSE], key=lambda c: c.mean)
print(f"{len(clusters)} duplicate clusters over {duplicates.count} samples")
for cluster in clusters[:10]:
    ids = [e.metadata[Batch.StdKeys.IDENTIFIER] for e in cluster.batch.elements]
    print(f"  size={cluster.size:3d}  mean={cluster.mean:.4f}  ids={ids}")

# 4c. familiarity -- fit and score in one pass over the same reduced responses
familiarity = Familiarity.introspect(reduced, batch_size=BATCH_SIZE)
scored = pipeline(reduced, familiarity)

rows: t.List[t.Tuple[t.Hashable, float]] = []
for batch in scored(batch_size=BATCH_SIZE):
    for element in batch.elements:
        result = element.metadata[familiarity.meta_key][RESPONSE]
        rows.append((element.metadata[Batch.StdKeys.IDENTIFIER], result.score))

# SILENT FAILURE #4 guard: higher == more familiar (code returns log-density, docs disagree).
rows.sort(key=lambda r: r[1], reverse=True)
print("MOST familiar (should look typical):", rows[:5])
print("LEAST familiar (should look rare):  ", rows[-5:])

# ---------------------------------------------------------------- 5. network audit
pfa = PFA.introspect(cached, batch_size=BATCH_SIZE)

# SILENT FAILURE #5 guard: layers with fewer samples than features are dropped, warn-only.
if pfa.failed_responses:
    raise RuntimeError(
        f"PFA skipped {len(pfa.failed_responses)} layers for insufficient samples: "
        f"{sorted(pfa.failed_responses)}. Raise MAX_SAMPLES above the widest channel count.")

kl_recipe = pfa.get_recipe()                          # == PFA.Strategy.KL(), parameter-free
PFA.show(kl_recipe, include_columns=[])               # [] means ALL columns

energy_80 = pfa.get_recipe(strategy=PFA.Strategy.Energy(energy_threshold=0.80, min_kept_count=3))
energy_99 = pfa.get_recipe(strategy=PFA.Strategy.Energy(energy_threshold=0.99, min_kept_count=3))
table = PFA.show((energy_80, energy_99))
table["Energy"] = ["0.8"] * len(energy_80) + ["0.99"] * len(energy_99)

# ---------------------------------------------------------------- 6. the handoff
total_before = sum(r.original_output_count for r in kl_recipe.values())
total_after = sum(r.recommended_output_count for r in kl_recipe.values())
print(f"\nPFA/KL recommends {total_after} filters where the model has {total_before} "
      f"({total_after / total_before:.1%})")
print("PFA does NOT modify the model. Retrain at these widths, then convert (Part 8).")
```

**What each step is buying you**, in the order they pay off:

1. **Step 4b (duplicates) is the cheapest win.** If clusters come back with `size` in the dozens,
   your validation split is contaminated and every accuracy number you have is optimistic. Fix that
   before anything else, because it changes what "no accuracy loss" means in step 5.
2. **Step 4c (familiarity) is the one that explains field failures.** Fit on train, score
   production samples, apply the ratio heuristic from §6.2. If the ratio is below 0.6, no amount of
   quantization tuning will help you — you have the wrong data.
3. **Step 5 (PFA) is the one that changes your deployment.** The `total_after / total_before` line
   is the headline: if it comes back at 40%, you are about to convert a model that is 2.5× wider
   than it needs to be, and every megabyte and millisecond you save there is saved *before* Part 9
   ever runs.

Two deliberate choices in that script worth naming. `PFA.introspect` consumes `cached` (the pooled
1024-dim responses), **not** `reduced` — PFA analyses the covariance structure of the actual
filters, so reducing first would be analysing PCA components, not filters. And `Duplicates` and
`Familiarity` both consume `reduced`, because both accumulate in RAM and both are linear in
dimension. That split is the whole reason `Cacher` is in the pipeline.

---

## 8. The pre-flight workflow for Parts 8–10

Here is the argument for why this guide exists at all, stated as a sequence.

Parts 8, 9 and 10 are expensive. Part 8 converts a PyTorch model and makes you fight op coverage.
Part 9 quantizes and palettizes it, which is a calibration-data problem with a long feedback loop.
Part 10 splits it into functions, routes it to the ANE, and profiles it. Between them that is
comfortably a week of work on a real model, and **all of it is wasted if the model is 3× wider than
it needs to be or the dataset that produced it is 30% duplicates**.

So the ordering is:

```
  ┌─ DNIKit ────────────────────────────────────────────┐
  │  1. Audit the DATASET                                │
  │       Duplicates   -> contaminated splits?           │
  │       Familiarity  -> train/field distribution gap?  │
  │  2. Audit the NETWORK                                │
  │       IUA          -> dead units / wasted capacity?  │
  │       PFA          -> per-layer recommended width    │
  │  3. RETRAIN at the recommended widths  (you do this) │
  └──────────────────────────────────────────────────────┘
                          │
                          ▼
   Part 8   convert                (the IO contract, op coverage)
   Part 9   compress               (quantize, palettize, prune, joint)
   Part 10  author + route + debug (ANE vs GPU, splitting, profiling)
   Part 15  ship                   (distribution, memory, thermals)
```

**Why prune before quantize, not after.** Structured width reduction and numeric compression are
multiplicative, not alternatives: a layer pruned from 1024 to 400 filters and then quantized to
int4 is smaller than either alone. But they interact in one direction only. PFA's recommendation is
derived from the **covariance of full-precision activations**; running it on already-quantized
responses measures quantization noise as if it were signal. Meanwhile Part 9's calibration is
sensitive to layer width — recalibrating after a width change is mandatory, so doing the width
change second means doing Part 9 twice.

The handoff is a plain integer per layer. `PFARecipe.recommended_output_count` is a filter count;
you edit your model definition, retrain, and the artifact that reaches Part 8 is an ordinary
checkpoint. **There is no file format, no export, and no tool integration** — DNIKit prints a
number and stops. That is the whole interface, and it is worth saying plainly because a reader
coming from the rest of this series will reasonably expect an `.aimodel`-aware export step. There
is none.

**Where each audit result lands:**

| DNIKit finding | Acts on | Where in this series |
|---|---|---|
| Duplicate clusters spanning train/test | Your split; your reported accuracy | Before anything. Also invalidates [Part 6](../../part-06-evaluations/README.md) baselines. |
| Familiarity ratio < 0.6 between train and field data | Data collection | Before anything. Nothing downstream fixes it. |
| High `unit_inactive_proportion` in a layer (IUA) | Architecture / initialisation / learning rate | Retraining, not deployment. |
| `PFARecipe.recommended_output_count` ≪ `original_output_count` | Model definition → retrain | Then [Part 8](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md), then [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md). |
| Nothing found | — | Skip straight to Part 8. This is a legitimate and common outcome. |

**And where it does not apply.** If your model is a transformer, none of this transfers. PFA's
notion of a "filter" is a conv channel or a dense unit; the strategies are per-layer covariance
analyses of `Batch × C` response matrices. Attention heads, KV projections and MoE experts are not
modelled, and `LayerKind.ATTENTION` exists in the enum with nothing consuming it. For LLM-shaped
compression go to [Part 9](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-09-coreai-compression-numerics/README.md) and
[Part 12 guide 03](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-12-mlx-python/references/03-quantization.md) instead.

---

## 9. What is explicitly not here

Stated once, as a list, so nobody goes looking:

- **No Core AI integration.** No `.aimodel`, no `AIModel`, no `InferenceFunction`, no `NDArray`, no
  specialization. ✅ VERIFIED — zero references in the tree.
- **No Core ML.** No `coremltools` dependency, no `.mlmodel` or `.mlpackage` loader, no conversion
  path. ✅ VERIFIED.
- **No MLX.** Neither `mlx` nor `mlx-lm` appears anywhere. ✅ VERIFIED.
- **No Swift.** DNIKit is pure Python. There is no package, no SPM manifest, no binding.
- **No on-device anything.** No iOS, no macOS-specific code paths, no Metal, no ANE awareness.
  DNIKit does not know Apple silicon exists.
- **No Foundation Models, Speech, Evaluations or App Intents relationship.**
- **No LLM support.** Nothing in the toolkit models attention, tokens, or autoregressive decoding.
- **No `.keras` model loader** (§5.5).
- **No PyTorch `Model`** — data adaptors only (§5.3).
- **No visualisation UI in this repo** — `DatasetReport` emits a DataFrame; Symphony is elsewhere.
- **No published quality or latency benchmark run by us.** The PFA numbers in §1 are the repo's own
  documentation claims.

The connection between DNIKit and the rest of this series is **conceptual, not code-level**: both
care about model quality on device, and they share no symbol, file format, or dependency.

---

## 10. Consolidated footguns

Everything above, compressed to a checklist. All ✅ VERIFIED unless marked.

**Environment**

1. **Python 3.9.7 is broken** — dataclass-inheriting-Protocol `__init__` bug (CPython 89244).
2. **TF1 pins you to Python ≤ 3.7**, `numpy<1.19`, `protobuf<4.0`, `Keras<2.4`, `h5py<3.0`.
3. **Version lockstep** — `dnikit`, `dnikit_tensorflow`, `dnikit_torch` assert equal `__version__`
   at import; a mismatch is a bare `AssertionError`.
4. **`dnikit[complete]` references a nonexistent `duplicates` extra** and omits `torch`.
5. **The `tf2` extra is an unpinned `tensorflow`** — this is why Keras 3 broke it.
6. **PyPI 2.0.0 does not have the Keras 3 fix.** Install from a git clone.
7. **`umap` (PyPI) ≠ `umap-learn`.**
8. **`scipy` is used but undeclared** — it arrives via `scikit-learn`.

**Pipeline**

9. **Nothing runs until `introspect()`.** `peek_first_batch` is the debugger.
10. **Batch field arrays are frozen** (`flags.writeable = False`). Copy before mutating or handing
    to torch.
11. **`Model.__call__(None)` requests every layer.**
12. **The field↔input auto-rename fires on shape agreement alone** (⚠️ #2).
13. **An infinite `Producer` hangs forever** (⚠️ #1).
14. **A `Cacher` is single-use per pipeline**, writes pickles to a temp dir, and `Cacher.clear()`
    deletes *all* DNIKit caches under it.
15. **`multi_introspect` requires a uniform `batch_size`**, and the introspector defaults differ
    (32 / 32 / 32 / 1024).
16. **`TorchProducer` rejects any `batch_size` different from its `DataLoader`'s.**
17. **`ImageProducer` requires every image to share H×W×C.**
18. **`ImageResizer(size=...)` is `(width, height)`** and ignores aspect ratio.

**Introspectors**

19. **`DimensionReduction`, `Familiarity`, `Duplicates` and `PFA` all require exactly 2-D fields.**
    `IUA` wants un-pooled responses. Pool or flatten accordingly.
20. **`Familiarity` (GMM) and `Duplicates` accumulate everything in RAM.** `PCA` is the only
    streaming reducer.
21. **Familiarity score: higher = more familiar** (⚠️ #4). The docs' math section disagrees.
22. **`PFA.show(pfa)` is wrong** — pass `pfa.get_recipe()`.
23. **`PFA` silently drops layers with fewer samples than features** into `failed_responses`
    (⚠️ #5).
24. **`PFA.show(include_columns=[])` means show ALL columns.**
25. **`DatasetReport` requires `IDENTIFIER`, stringifies all `LABELS`**, and drops labels with fewer
    than `split_familiarity_min` (50) samples from split familiarity.
26. **The report's projection silently disables itself** without `umap-learn`.
27. **`Duplicates` clusters are a transitive closure** — long chains merge; sort by `mean`.
28. **A zero-variance column makes `Duplicates` produce NaN/inf** with no guard.
29. **Keras 3 without commit `2f39056` classifies every layer `UNKNOWN`** (⚠️ #3).

**Wrong strings in the shipped code and docs** — recognise them so you do not chase the wrong bug

30. `"PIL not available, was 'dnikit[notebook]' installed?"` is raised when **pandas** is missing —
    in both `PFA` (`_pfa.py:229-230`) and `IUA` (`_iua.py:215-216`).
31. `"pandas not available, was dnikit['dataset_report'] or dnikit['dataset_report_base']
    installed?"` — **both extra names are wrong**; it is `dataset-report`.
32. ``"`recipe_result` parameter input is emtpy"`` — the typo is in the source.
33. `"...requires that thebatch_size..."` — missing space, in the source.
34. **Doc bug:** `ImageResizer.Format.HWC` does not exist — use `dnikit.base.ImageFormat.HWC`.
    Appears in four `.rst` files.
35. **Doc bug:** `pfa.get_recipe(compression=...)` — the keyword is `strategy=`.
36. **Doc bug:** `model.response_infos()` written as a call — it is a **property**.
37. **Stale docs:** `'conv_pw_13/convolution:0'` is the TF1 spelling; TF2 uses bare `'conv_pw_13'`.
38. `LayerKind.LINEAR` and `LayerKind.DENSE` are the same member (`1000`); `MAX_POOLING_3D` is
    `3003` and there is no `3002`.

---

## 11. Declared gaps

Eight things we could not verify. Each says what is unknown, what would resolve it, and what to do
in the meantime.

> 🔴 **G1 — Nothing in this guide was executed.**
> The research pass read the repository exhaustively but had no TensorFlow installed. Every
> signature, error string, default and code listing is a faithful transcription of source that
> exists; **none of it is a smoke test.**
> *Resolution:* `make install` on a clean Python 3.10 environment and run the seven notebooks.
> *Safe default:* run §7's script on `MAX_SAMPLES=2000` first and check the three assertions fire
> correctly before scaling up.

> 🔴 **G2 — Does DNIKit + `2f39056` actually run under Keras 3 / TF 2.16+?**
> The commit fixes response-metadata extraction and layer classification. But three other Keras-3
> sensitive paths were **not** touched: `TFModelWrapper.load_keras_model` still saves to a bare
> `.h5`; `_TF2KerasWholeModelLoader.can_load` still keys on `.h5`; and
> `_Tensorflow2ModelDetails.run_inference` still builds
> `tf.keras.Model(inputs=[self.model.input], outputs=[...])`. All three are areas Keras 3 changed.
> *Resolution:* one run of `TFModelExamples.MobileNet()` on TF 2.16+.
> *Safe default:* bypass the sample wrappers — `load_tf_model_from_memory(model=...)` with a model
> you constructed yourself, and a hand-written `Processor` for preprocessing (§5.7).

> 🔴 **G3 — Memory ceilings are unmeasured.**
> We know `Familiarity` and `Duplicates` call `_accumulate_batches` and that annoy builds 30 trees.
> We do **not** know the peak-RSS multiplier over the raw array size, so we cannot tell you how
> many samples fit in 32 GB.
> *Resolution:* an instrumented run at several sample counts.
> *Safe default:* reduce to 40 dimensions with streaming `PCA` before either introspector (§3.4),
> and bisect upward from a size you know works.

> 🔴 **G4 — `PFA.Strategy.Size`'s `relative_size` may not mean what the docs say.**
> The docs describe it as *"percentage of the weights"*; the implementation takes a **percentile
> over the pooled per-layer cumulative-energy curves**, which is a proxy for channel fraction, not
> weight fraction. Whether these coincide in practice is unverified.
> *Resolution:* compute actual parameter counts from a `Size(0.5)` recipe and compare.
> *Safe default:* use `PFA.Strategy.Energy` with an explicit threshold, whose semantics are
> unambiguous, or `KL()` which has no parameter to misread.

> 🔴 **G5 — `epsilon_energy` in `PFA.Strategy.Size` is documented wrongly.**
> The docs' example passes `epsilon_energy=0.6` and describes it as *"ensures that at least 0.6 of
> the energy is preserved"*. In the code it is only a clamp keeping the derived threshold inside
> `[eps, 1-eps]`, default `1e-8`. **The documentation appears to be simply wrong.**
> *Safe default:* leave it at its default and control compression with `energy_threshold` /
> `relative_size`.

> 🔴 **G6 — Symphony's widget contract is not in this repo.**
> `DatasetReport` emits a DataFrame whose column naming we reverse-engineered from
> `_dataframe_formatting.py` and `test_dataset_report.py` (§6.6). The consumer lives in
> `apple/ml-symphony`, which we did not clone. The docs say only that Symphony *"operates on
> images, audio, and tabular data."*
> *Resolution:* clone `apple/ml-symphony`.
> *Safe default:* consume `report.data` directly as a pandas DataFrame. The column contract in §6.6
> is test-pinned and sufficient for your own plotting.

> 🔴 **G7 — The familiarity-score sign discrepancy: doc bug or deliberate redefinition?**
> Code returns `logsumexp` (positive log-density); the docs' math section says negative
> log-likelihood. We lean **doc bug**, and the notebooks' `reverse=True` sorting supports that, but
> we did not confirm it with the authors.
> *Safe default:* the empirical check in §6.2's callout. Look at the images.

> 🔴 **G8 — Repository history is invisible.**
> The clone is `--depth 50` and returns only three commits. GitHub issues #1–#3 are referenced
> indirectly ("Fixes #2") but no issue data is in the clone, and `docs/dev/contributing.rst` names a
> `develop` branch that this clone does not have.
> *Resolution:* a full clone plus the GitHub issue API.
> *Consequence:* we cannot tell you whether other Keras 3 problems are known-and-open.

---

## 12. Sources

**Evidence class: a single open-source repository.** This is the weakest evidence position of any
guide in the series and the guide says so throughout.

- **`apple/dnikit`**, local clone at `repos/apple__dnikit`, `--depth 50`, HEAD `2f39056`
  (2026-07-09). Apache-2.0. Version 2.0.0; `CITATION.cff` `date-released` 2023-06-19; `CHANGELOG.md`
  dates the 2.0.0 release 2023-08-03.
  - Source read: ~60 files across `src/dnikit/`, `src/dnikit_tensorflow/`, `src/dnikit_torch/`.
  - Tests read: `test_dataset_report.py`, `test_familiarity.py`, `test_duplicates.py`, `test_pfa.py`,
    `test_multi_introspect.py`, `test_cached_producer.py`, `test_tf2_model_loaders.py`,
    `test_tf_examples.py`, `test_torch_producer.py`.
  - Docs read: 20 `.rst` files under `docs/`.
  - Notebooks: all seven, code cells dumped verbatim —
    `data_introspection/{dataset_report, duplicates, dimension_reduction,
    familiarity_for_rare_data_discovery, familiarity_for_dataset_distribution}.ipynb` and
    `model_introspection/{principal_filter_analysis, inactive_unit_analysis}.ipynb`.
  - Build metadata: three `pyproject.toml`s, `Makefile`, `pytest.ini`, `conftest.py`,
    `.bumpversion.cfg`, `CONTRIBUTING.md`.
- **Research note:** `notes/repos/dnikit.md` (1,670 lines), the synthesis of the above.
- **Papers cited by the repo** (`docs/reference/how_to_cite.rst`):
  - **PFA** — Suau Cuadros, Zappella & Apostoloff, *"Filter distillation for network compression"*,
    WACV 2020, [arXiv:1807.10585](https://arxiv.org/abs/1807.10585).
  - **Symphony** — Bäuerle, Cabrera, Hohman, Maher, Koski, Suau, Barik & Moritz, *"Symphony:
    Composing Interactive Interfaces for Machine Learning"*, CHI 2022.
  - **t-SNE** van der Maaten & Hinton 2008 · **UMAP** McInnes, Healy & Melville
    ([arXiv:1802.03426](https://arxiv.org/abs/1802.03426)) · **PaCMAP** Wang, Huang, Rudin &
    Shaposhnik, JMLR 22(201), 2021 · **ANNOY** Bernhardsson 2018.
  - `IUA` and `Familiarity` (without visualisation) carry no additional citation.

**Not sources, because they do not exist:** there is no WWDC session, no
`developer.apple.com/documentation` page, no Apple Developer Forums thread, and no sample-code
project for DNIKit in our corpus. Where this guide states a fact about the toolkit, it came from
the repository or from the repository's own Sphinx documentation, and nowhere else.

**Citation**, ✅ VERIFIED from `CITATION.cff` / `docs/reference/how_to_cite.rst`:

```bibtex
@online{DNIKit,
     author = {Welsh, Megan Maher; Koski, David; Sarabia, Miguel; Sivakumar, Niv; Arawjo, Ian;
               Joshi, Aparna; Doumbouya, Moussa; Suau, Xavier; Zappella, Luca; Apostoloff, Nicholas},
     title = {Data and Network Introspection Kit},
     year = 2023,
     url = {https://github.com/apple/dnikit},
}
```

---

**Next:** if the audit found something, act on it and then go to
[Part 8 — Core AI: converting from PyTorch](https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/part-08-coreai-pytorch-conversion/README.md). If it found
nothing, go there anyway — that was the point of running it.
