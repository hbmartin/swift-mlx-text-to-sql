# Model license and distribution report

This report records the license decision used by model acquisition,
fine-tuning, publication, and Release bundling. It is an engineering
compliance record, not legal advice. The machine-readable source of truth is
`model-manifest.json`; file sizes and SHA-256 values below are enforced by the
manifest fetcher and Release-bundle inspector.

## Source-artifact declarations

| Artifact key | Immutable source | Declared terms | Commercial use in CREG |
|---|---|---|---:|
| `qwen25-coder-3b` | `mlx-community/Qwen2.5-Coder-3B-Instruct-4bit@3dd939c621c08e5753d5b89f35a2642cd83b98ca` | Qwen Research License | No |
| `qwen25-coder-1_5b` | `mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit@b3252a2f97102b1fb1571fec2c9b27219a8536be` | Apache-2.0 | Yes |
| `qwen3-1_7b` | `mlx-community/Qwen3-1.7B-4bit@3b1b1768f8f8cf8351c712464f906e86c2b8269e` | Apache-2.0 | Yes |
| `xiyansql-qwencoder-3b` | `XGenerationLab/XiYanSQL-QwenCoder-3B-2502@0d35ce19d4e4d78d82d19b18b3e0f1c7a86eb535` | Apache-2.0 plus the conservatively inherited Qwen Research License | No |

The 3B Qwen license is pinned to
`Qwen/Qwen2.5-Coder-3B-Instruct@488639f1ff808d1d3d0ba301aef8c11461451ec5`.
Its exact `LICENSE` is 7,388 bytes with SHA-256
`ef52482bb785733093dc9a2e8edd8e764c77d12d8e9d8f10a80c9b547d32d0f9`.

The XiYan repository publishes an Apache-2.0 `LICENSE`, 11,343 bytes with
SHA-256
`832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e`.
However, its pinned `config.json` identifies
`model/Qwen/Qwen2___5-Coder-3B-Instruct` in `_name_or_path`. CREG therefore
does not interpret the intermediate repository's Apache declaration as
removing the identified Qwen 3B terms. XiYan and CREG derivatives of XiYan are
treated as non-commercial and carry both license texts.

Relevant upstream records:

- [Qwen2.5-Coder-3B-Instruct license and model card](https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct)
- [XiYanSQL-QwenCoder-3B-2502 pinned repository](https://huggingface.co/XGenerationLab/XiYanSQL-QwenCoder-3B-2502/tree/0d35ce19d4e4d78d82d19b18b3e0f1c7a86eb535)
- [XiYan pinned lineage configuration](https://huggingface.co/XGenerationLab/XiYanSQL-QwenCoder-3B-2502/blob/0d35ce19d4e4d78d82d19b18b3e0f1c7a86eb535/config.json)

## Required derivative files

Every direct Qwen2.5-Coder-3B CREG derivative contains:

- `LICENSE`: the hash-pinned Qwen Research License;
- `NOTICE`: the committed CREG attribution and modification notice;
- a model-card modification statement;
- the phrase “Built/Improved using Qwen”; and
- an explicit non-commercial research-and-evaluation warning.

Every XiYan-based CREG derivative contains:

- `LICENSE`: the hash-pinned XiYan Apache-2.0 text;
- `QWEN_LICENSE`: the hash-pinned Qwen Research License;
- the same `NOTICE`, modification statement, attribution, and
  non-commercial warning.

The committed `fine-tuning/config/QWEN-NOTICE.txt` is 712 bytes with SHA-256
`bf8cecc65e55ad4e863623d147523815c2ba2a4da5757158aa86d175ca2dbeff`.
Publication refuses to proceed if its bytes differ.

## Enforcement path

`fine-tuning/tools/fetch_model.py` validates that every revision is an
immutable 40-character commit, verifies the complete declared model
inventory, downloads each required license from its separately pinned source,
and verifies license and notice bytes before copying a production artifact.

`fine-tuning/tools/publish_finalists.py` stages the fused 4-bit model outside
the completed training directory, adds the required license and notice files,
generates a model card with full training configuration and provenance, and
uploads the staged snapshot. It then performs a forced fresh download at the
returned Hub commit and compares every file's size and SHA-256. The completed
training materialization is replaced with the public bytes only after that
independent check succeeds.

`fine-tuning/tools/inspect_release_bundle.py` checks that the built app
contains the exact selected manifest, complete selected model inventory, every
declared license, and the notice. An absent, extra, or mismatched model file
fails inspection.

## Verified public derivatives

The two derivatives were published and independently downloaded from their
returned immutable commits:

| Derivative | Public commit | Required license payload | Verification |
|---|---|---|---|
| Qwen finalist | [`430d38301eedb6c61e48c25c7d38a2b227bf56c6`](https://huggingface.co/hbmartin/creg-sql-mlx-community-qwen2-5-coder-3b-instruct-4bit-mlx-4bit/tree/430d38301eedb6c61e48c25c7d38a2b227bf56c6) | `LICENSE`, `NOTICE` | Fresh ten-file tree `c09f7ec567a5d45dbbb3fbbd35b1e9db6933b6db5bf0e6ab1fd772af275c5204` |
| XiYan finalist | [`7f97a54819b9329338a5353266d6d2a1294eb341`](https://huggingface.co/hbmartin/creg-sql-xgenerationlab-xiyansql-qwencoder-3b-2502-mlx-4bit/tree/7f97a54819b9329338a5353266d6d2a1294eb341) | `LICENSE`, `QWEN_LICENSE`, `NOTICE` | Fresh twelve-file tree `a3befce92b39afe29c0c0b01c534bd81731f151940470697d5f2038c89efd8c6` |

The corresponding immutable publication records are
`eval/publications/publish-qlora-qwen25-coder-3b-seed-424242/publication.json`
and
`eval/publications/publish-qlora-xiyansql-qwencoder-3b-seed-424242/publication.json`.
Their SHA-256 values are respectively
`2a983c6251af85755facc3f5ee2af6b760c405e818570f9a3b2403307703b369`
and
`420bcfe1788704e053e0dc979076192e7dc1c1face016da8a56a51303600b2d2`.

## Verified Release distribution

The clean-cache Release build selected the XiYan derivative and bundled all
12 declared files. The independent record at
`eval/build-verification/release-xiyansql-qwencoder-3b-7f97a548/report.json`
matched:

- public revision `7f97a54819b9329338a5353266d6d2a1294eb341`;
- expected and observed model-tree SHA-256
  `a3befce92b39afe29c0c0b01c534bd81731f151940470697d5f2038c89efd8c6`;
- exactly 1,747,812,702 model bytes and no extra distribution files; and
- the required `LICENSE`, `QWEN_LICENSE`, and `NOTICE` bytes.

The embedded and source manifest SHA-256 values both equal
`be2bc2ff256577e72173bd1bf52422c4a38650c0b91101c3c971e9b53f3d7b73`.
This verifies that the legal payload inspected in the app is the same payload
declared for the evaluated production artifact.

## Operational conclusion

CREG remains a non-commercial research prototype whenever the selected
production artifact descends from either Qwen2.5-Coder-3B or the pinned
XiYanSQL model. A future selection of an Apache-only source would not
retroactively change the restrictions on already published Qwen-derived
artifacts. Each public model and each Release bundle must be assessed from its
own pinned manifest entry and included files.
