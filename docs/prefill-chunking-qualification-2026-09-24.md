# Prefill chunking qualification, 2026-09-24

**Release status: blocked.** Production explicitly uses `.balanced`, but an
exact, provenance-matched qualified `gold_v2` artifact is unavailable. This
change must not be released on the strength of an aggregate score or the
same-binary control alone. Production has not been switched to `.remainder`.

## Inputs and runs

The optimized host binary was
`CREGKit/.build/release/creg-eval-cli` (SHA-256
`b4dcabcc929cdfaf5308ac6b4e45e52be4420c7912d7ec4b3ef69b53d9abcff5`).
All four runs used the pinned 4-bit
`ft-xiyansql-qwencoder-3b` model at revision
`7f97a54819b9329338a5353266d6d2a1294eb341`, the same `gold_v2`
corpus and database, temperature 0, seed 0, top-p 1, top-k 0, and a
10,000-row cap. The model directory digest was
`a3befce92b39afe29c0c0b01c534bd81731f151940470697d5f2038c89efd8c6`.
Each JSON run records its full command and input provenance.

| Configuration | Balanced EX | Remainder EX | Balanced valid SQL | Remainder valid SQL | Balanced losses against remainder |
| --- | ---: | ---: | ---: | ---: | --- |
| Evaluation: GCD on, 512 tokens | 136/200 | 136/200 | 189/200 | 187/200 | 0 EX, 0 valid SQL |
| Device runtime: GCD off, 128 tokens | 136/200 | 136/200 | 189/200 | 187/200 | 0 EX, 0 valid SQL |

The balanced and remainder modes differ on nine SQL outputs in each
configuration: `G-120`, `G-130`, `G-215`, `G-224`, `T1-12`, `T1-18`,
`T2-25`, `T2-33`, and `T2-42`. The reports record the full SQL and
item-level EX and valid-SQL outcome for every changed output:

- [Evaluation report](../eval/analyses/prefill-chunking-2026-09-24/gate-report.json) and [balanced](../eval/runs/prefill-chunking-2026-09-24/balanced.json) / [remainder](../eval/runs/prefill-chunking-2026-09-24/remainder.json) runs.
- [Device runtime report](../eval/analyses/prefill-chunking-2026-09-24/device-gate-report.json) and [balanced](../eval/runs/prefill-chunking-2026-09-24/device-balanced.json) / [remainder](../eval/runs/prefill-chunking-2026-09-24/device-remainder.json) runs.

The older checked-in
`eval/runs/swift-parity-provenance-ft-xiyansql-qwencoder-3b-gcd-on-t-0_0-s-0/swift.json`
has 130/200 EX and 184/200 valid SQL. Its system-prompt, grammar, and
package-lock digests differ from the new run. The evaluation report records
all 60 balanced-versus-historical SQL changes and the four EX and two
valid-SQL losses against that historical output, but those comparisons
cannot attribute a change to prefill chunking. The union of historical and
same-binary differences is 63 items.

The gate implementation in
[`compare_prefill_chunking.py`](../fine-tuning/tools/compare_prefill_chunking.py)
rejects item-level losses and mismatched input provenance, checks that
balanced and remainder used the same optimized binary, and writes the
changed-output report even when blocked. Both reports have status
`blocked`: the evaluation report rejects the mismatched historical
artifact, and the device report records `qualified.artifactMissing`.

## Preparation and build verification

- A controlled cancellation test holds a non-cancellable container load,
  cancels its caller, completes the load, then requests the container three
  more times. The measured load count remains **one**. Reducer tests cover
  inactive and background suspension behavior and journal ordering. A
  repeated physical iOS background preparation measurement was not
  available in this host run.
- The unsigned Debug iOS simulator build passed.
- `swift test --skip ResultPresentationMigrationHandlerTests` passed 592
  tests. A full `swift test` run failed on four assertions in the unchanged
  `ResultPresentationMigrationHandlerTests` chart migration suite; an
  isolated run of that suite also failed.
- `python3 fine-tuning/tests/test_compare_prefill_chunking.py` passed,
  including a case where aggregate scores tie but an individual EX loss
  blocks the gate.

To unblock release, produce the exact qualified 200-item artifact for the
same model, configuration, prompt, grammar, gold corpus, database, and
package lock; rerun the checker against it; and review every SQL change in
the generated report. The controlled container test does not replace an
on-device repeated background preparation measurement.
