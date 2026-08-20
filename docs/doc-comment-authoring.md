# Doc Comment Authoring

Rules for the documentation comments in `CREGKit/Sources`.

## Overview

The DocC build in `.github/workflows/documentation.yml` runs with
`--warnings-as-errors`, so an unresolvable reference in a doc comment fails CI
on the pull request that introduces it. These rules keep that from happening.

## Cross-module references are code spans

DocC resolves symbol links per target, so a symbol link pointing at another
module fails the build even with `--enable-experimental-combined-documentation`
enabled. Refer to a symbol in another module with a single-backtick code span:

```swift
/// Decoded by `InferenceSerializer` before the pipeline sees it.
```

A double-backtick symbol link to the same symbol does not resolve:

```swift
/// Decoded by ``InferenceSerializer`` before the pipeline sees it.
```

Written in `CREGEngine/QueryPipeline.swift`, that fails with:

```text
'InferenceSerializer' doesn't exist at '/CREGEngine/QueryPipeline'
```

Within one module, double-backtick symbol links are correct and preferred —
they render as navigable links and the build checks that the target exists.

## Articles in this directory are published

Everything under `docs/` is staged into the `CREGEngine` documentation catalog
and compiled. A new article has to be curated under a topic in
`docs/CREGEngine.md`, and any symbol-link syntax it discusses belongs inside a
fenced code block, where DocC will not try to resolve it.
