# On-device SQL generation latency

## Decision

The iPhone runtime uses the selected 3B checkpoint requantized to 4-bit affine
weights with group size 128, grammar-constrained decoding (GCD) disabled, and
a 128-token output cap. The manifest records decoding separately as
`production.device_runtime`; the checked-in Release selection retains policy
version `iphone-30-second-v1`, while the evaluated Debug runtime uses
`iphone-30-second-v10` to pin MLX's command-buffer byte limit to 10 MB, use
the quality-gated compiled Qwen2 MLP graph, fuse Q/K/V only for two-to-four
token target-verification tensors, and project greedy primary tokens directly
into a compact question-aware SQL vocabulary. During those same short target
verification calls, v8 omits the MLP residual in transformer layers 8 and 10.
For the longer three- and four-token verification tensors, it also omits layer
2's MLP residual; two-token checks retain layer 2. This shape-aware distinction
improved the complete quality gate while removing additional target work.
V9 adds one narrower optimization: for an exact three-token verification input,
it also omits layer 16's MLP only when both proposed continuations are unanimous
across at least 512 matching corpus observations. Less-supported, non-unanimous,
and differently shaped checks retain the v8 graph. V10 adds a second gate for
exact two-token checks: it omits final-layer MLP 35 only when the single proposal
is unanimous across at least 512 observations. Because layer 35 is last, this
does not alter a later layer's K/V cache.
Prefill and serial decoding continue to execute the complete model. The original evaluation
configuration remains intact for provenance. The Debug
artifact records the weight policy as `iphone-q4-g128-v2`. Model preparation
also prefills and retains the invariant system/schema KV cache. Each query
deep-copies that evaluated cache, tokenizes only the user-controlled text, and
appends a preparation-verified five-token assistant suffix. If a tokenizer's
chat template cannot reproduce the exact full token sequence this way, the
runtime automatically falls back to full chat-template rendering.
The evaluated Debug runtime then emits one token through the ordinary serial
path and enables an order-6 SQL n-gram CPU drafter. It normally proposes one
token, expanding to two or three only while every continuation is unanimous
across at least eight training occurrences. The 3B target model verifies every proposal
and remains the source of every emitted token. The Debug manifest pins the
strategy, maximum block size, support threshold, serial prefix,
1,353-statement source digest, and exact 223,727-byte resource digest; the
runtime re-hashes the bundled resource before use. A
manifest without that exact optional policy—including the checked-in XiYan
Release selection—keeps speculation disabled. Repairs also retain the ordinary
serial decoder because the speculative quality gate covered primary generation.
The Debug manifest's `candidate_count: 1` is now enforced by the pipeline;
valid Debug turns make one SQL-generation call instead of the previously
hard-coded three. This does not change the single-candidate accuracy contract
used to materialize the Debug artifact. The checked-in verified production
manifest still requests three candidates and therefore retains three-way
voting.

Physical timing uses an explicitly optimized benchmark build: Xcode selects
the Release configuration (`-O`, whole-module compilation), while an explicit
`CREG_DEVICE_BENCHMARK` Swift condition and `CONFIGURATION=Debug` materializer
override allow the receipt-verified Debug candidate. Ordinary Release builds
receive neither override and continue to reject Debug model identities. A
launch-only environment variable submits the frozen vacancy question after
model and history readiness, clears prior conversational context, and persists
the normal turn telemetry. This makes the phone measurement automated without
adding a production UI or network benchmark path.

The change targets the hard 30-second generation deadline. The failing iPhone
trace reached that deadline without returning a candidate while running the
latest local reliability-v3 Qwen2.5-Coder-3B checkpoint with GCD enabled and a
512-token cap. Earlier XiYan 3B phone generations returned only 24 tokens but
still took 23.4–26.7 seconds with GCD enabled, identifying per-token constrained
decoding—not the output cap—as the immediate bottleneck.

## Evidence

The held-out 200-item fine-tune matrix already contains an exact GCD ablation:

| Configuration | EX | Valid SQL | p95 latency on M4 Pro |
|---|---:|---:|---:|
| XiYan fine-tune, GCD on | 65.5% | 93.0% | 3.009 s |
| XiYan fine-tune, GCD off | 65.0% | 92.5% | 1.559 s |
| Qwen fine-tune, GCD on | 52.5% | 89.5% | 2.973 s |
| Qwen fine-tune, GCD off | 52.5% | 86.0% | 1.559 s |

For the selected XiYan production checkpoint, disabling GCD reduced p95 by
48.2% at a 0.5-point EX and valid-SQL cost. The app still parses and executes
generated SQL against its read-only database, so invalid unconstrained output
follows the existing repair path.

The latest local reliability-v3 checkpoint was also evaluated directly with
GCD off and `max_tokens=128` on the complete 60-item `gold_v1` set and all
three database snapshots. The Python/MLX run exactly matched GCD-on accuracy:
63.3% EX and 98.3% valid SQL. Mean generation latency fell from 3.193 to 2.376
seconds (1.34x), and p95 fell from 4.644 to 3.475 seconds. The smaller 15-item
binding run produced 100% valid SQL, 53.3% EX, 2.574-second mean latency, and
3.384-second p95 latency. The production Swift/MLX Release binding harness
produced 86.7% valid SQL and the same 53.3% EX; generation p95 was 1.330
seconds and its maximum was 1.360 seconds. These runs are local exploratory
evidence rather than production model-selection evidence.

The Qwen chat prompt for the timeout question contains 1,220 tokens. The
runtime-derived common prefix safely caches 1,207 of them (99.0%), leaving only
13 prompt tokens to prefill after submission. On the complete 60-item Swift
parity set, prefix caching changed zero generated SQL strings and zero EX
outcomes. Warm mean wall time fell from 1.653 to 0.595 seconds (2.78x), p95
fell from 2.351 to 1.305 seconds (1.80x), and the observed maximum fell from
2.425 to 1.413 seconds. Both Swift runs scored 58.3% EX and 91.7% valid SQL;
the lower Swift score relative to Python is a pre-existing runtime parity gap,
not a cache-induced change.

Requantizing the exact evaluated iteration-600 fusion from 4-bit group 64 to
4-bit group 128 improved both quality and latency in the preserved Swift
receipt build. On the primary 60-item database, EX rose from 58.3% to 68.3%
and valid SQL rose from 91.7% to 100%. Across the same 60 questions and all
three database snapshots, the old artifact scored 104/180 (57.8%) while group
128 scored 121/180 (67.2%); valid SQL improved from 163/180 (90.6%) to 180/180.
On the primary snapshot, cached mean wall time fell from 0.595 to 0.519
seconds, p95 fell from 1.305 to 0.922 seconds, and the maximum fell from 1.413
to 1.298 seconds. Mean output length fell from 50.3 to 44.4 tokens, p95 was 91,
the maximum was 122, and no generation reached the 128-token cap.

A clean rebuild from the current Swift/MLX source scores 115/180 with the same
pinned group-128 bytes and 180/180 valid SQL. Its primary-snapshot mean is
0.501 seconds, p95 is 0.910 seconds, and maximum is 1.190 seconds. Thirteen SQL
outputs differ from the preserved receipt build, consistent with a changed
compiled numerical path rather than prompt, artifact, or dataset drift. The
historical 121/180 receipt remains the artifact-selection evidence; comparisons
between new runtime strategies use the fresh 115/180 control built from the
same current source.

The evaluated artifact is fail-closed: the materializer pins the source-fusion
directory digest, the optimized directory digest, checkpoint hash, and
quantization policy. A re-fusion under the current Python toolchain produced
different weights and failed the accuracy screen, so a clean build cannot
silently substitute newly generated bytes for the evaluated cache.

An exact replay now provides the best phone/Mac multiplier. For the same XiYan
model, GCD setting, vacancy question, and 24-token output, the M4 Pro produced
15.37 tokens/second while eight completed iPhone 15 Pro candidates produced
1.42–1.72 tokens/second. That is an 8.96–10.85x throughput ratio, centered at
9.33x. Candidate wall time gives a consistent 7.62–10.10x range, centered at
8.78x. The earlier 11–18x estimate mixed questions and timing slices, so it is
retained only as a conservative planning envelope rather than the central
estimate.

The final CPU-draft speculative policy was compared with a same-artifact,
same-prompt serial control across all 200 `gold_v2` questions. Every generated
SQL string and token count matched. Both runs therefore retained 154/200 EX
and 196/200 valid SQL. Mean total latency fell from 510.072 to 417.370 ms
(18.2%), and p95 fell from 810.168 to 637.760 ms (21.3%). The winner was faster
on 189/200 paired items. Its maximum was 1.233 seconds versus 1.186 seconds for
the serial control. Fixed two-token drafting was slower, but selectively using
up to three proposals for unanimous order-6 contexts with at least eight
training occurrences improved mean latency another 1.6% over adaptive K=2.
K=4 changed one 60-item output and was slower, so three is the maximum. One
ordinary serial token was also necessary: starting target verification with
the entire prompt changed seven of 60 SQL strings, while a one-token prefix
changed zero of 60 and zero of 200.
Relaxing the K=3 continuation rule from unanimity to 99%, 95%, 90%, or 80%
confidence preserved all 60 screen outputs but increased paired mean latency
by 2.9, 6.3, 6.7, and 11.3 ms respectively. The extra verification work
outweighed the saved target calls, so the production gate remains unanimous.
A compact CPU-built verify tensor preserved all 60 outputs and identical
speculation telemetry, but changed mean generation by only -0.12 ms while
raising total latency 1.32 ms, so the existing lazy construction remains.
Using a unanimous shorter-context backoff to authorize longer drafts also
preserved all 60 outputs across support thresholds 8–64. The best threshold,
16, saved nine target rounds and six verified positions but improved paired
mean latency by only 0.58 ms (0.13%); every other threshold was neutral or
slower, so the added policy was removed.
Across the 200-item winner, 4,885 of 6,368 CPU proposals were accepted (76.7%).
Including the one serial token per question, target decode calls fell from
8,975 to 4,341 (51.6%). The final manifest/resource code path independently
retained 39/60 EX, 60/60 validity, and zero output differences; its warm model
preparation was 1.924 seconds versus 1.622 seconds for serial, a one-time
302 ms cost outside the per-query deadline. Resident memory did not increase
in that matched process-level measurement.

The final runtime also pins MLX's command-buffer byte limit to 10 MB rather
than its 40 MB default. A matched 200-item A/B preserved every SQL string,
token count, accuracy outcome, and speculative-decoding counter: both sides
scored 154/200 EX and 196/200 valid SQL, with 4,141 target rounds, 6,368 drafts,
4,885 accepted drafts, and 10,509 verified positions. The 10 MB run reduced
mean total latency from 411.628 to 408.043 ms (0.87%), mean generation from
313.477 to 300.680 ms (4.08%), p95 total latency from 630.717 to 609.225 ms
(3.41%), and maximum total latency from 1.193 to 1.175 seconds (1.51%). It was
faster on 129/200 paired items, although median total latency rose 6.774 ms.
Two earlier matched 60-item order-reversed pairs independently favored 10 MB
on 52/60 and 48/60 items. Because the production goal is the 30-second tail,
the repeated mean and tail gains justify the v2 runtime policy despite the
small median regression.

The v3 runtime additionally replaces Qwen2's separately dispatched
`silu(gate) * up` operations with one shapeless compiled MLX graph. The model
implementation is selected through an isolated factory rather than mutating
MLXLLM's process-global model registry, and v1/v2 manifests retain the upstream
Qwen2 path. A same-binary, same-artifact 200-item reverse-order comparison
preserved every SQL string, token count, accuracy result, and speculation
counter. Mean total latency fell from 403.643 to 399.041 ms (1.14%), mean
generation from 293.396 to 290.803 ms (0.88%), p95 total latency from 609.406
to 602.356 ms (1.16%), and maximum from 1.170 to 1.154 seconds (1.43%). The
fusion won 164/200 total-time pairings and 192/200 generation-time pairings.
Earlier order-reversed 60-item pairs independently measured a 0.55% aggregate
total-time gain, while a separate full-200 pair measured 0.23%; the effect is
small but repeatable and output-identical.

The v4 runtime reduces Qwen's tied 151,936-token output projection to roughly
4,100 rows per primary question. The static rows come from the receipt-checked
1,353-statement SQL draft corpus and bundled schema/grammar lexemes. Dynamic
rows are selected only when their decoded core occurs within a word in the
current question; no evaluation answer or generated SQL is used. Restricted
head kernels are warmed during model preparation, outside the query deadline.
The optimization is limited to deterministic, GCD-off primary generation;
repairs and other decoding modes retain the complete head. Offline token
coverage included every token chosen by the control on all 200 questions. A
same-binary full-corpus A/B then preserved every SQL string, token count,
accuracy result, and speculation counter: both scored 154/200 EX and 196/200
valid SQL. Mean total latency fell from 400.125 to 380.961 ms (4.79%), mean
generation from 290.797 to 271.163 ms (6.75%), p95 total from 606.731 to
573.805 ms (5.43%), and maximum total from 1.160 to 1.074 seconds (7.46%). The
restricted head was faster on 195/200 total-time pairings and all 200
generation-time pairings. Preparation increased by 856 ms and resident memory
by about 8 MB, both outside the per-query deadline.

The v5 runtime combines the three quantized attention projections only for the
two-to-four-token tensors produced by SQL n-gram target verification. It
deliberately retains the original three projections for the long prompt prefill
and one-token serial decode. Two order-reversed 60-item gates preserved every
SQL string, token count, and speculation decision while reducing aggregate
mean generation by 7.88 ms (2.7%); the fused path won 118/120 generation
pairings. The required 200-item gate again preserved every SQL string, token
count, speculation decision, EX outcome, and validity outcome: both paths
scored 154/200 EX and 196/200 valid SQL. Mean total latency fell from 395.731
to 393.131 ms (0.66%), mean generation from 294.076 to 289.490 ms (1.56%),
p95 total from 601.034 to 597.937 ms (0.52%), and maximum total from 1.138 to
1.131 seconds (0.62%). It won 139/200 total-time and 197/200 generation-time
pairings. Prepared resident memory was 1.826 GB versus 1.839 GB for control,
so the process-level measurement found no memory increase.

The v6 runtime removes the remaining scatter from each restricted-head call.
The GPU returns the local argmax over roughly 4,100 rows, and the n-gram
iterator translates those few local indices to global vocabulary IDs on the
CPU only after the target batch's existing synchronization. This avoids both
the 151,936-row fill/scatter and the extra GPU indexed gather that made the
earlier compact-head attempt slower. Two order-reversed 60-item comparisons
preserved every SQL string, token count, and speculation counter while reducing
aggregate mean generation by 1.851 ms (0.64%) and winning 94/120 generation
pairings. The required 200-item gate again preserved all outputs and counters,
154/200 EX, and 196/200 valid SQL. Mean generation fell from 268.264 to
267.189 ms (0.40%) and the candidate won 141/200 generation pairings. Mean
end-to-end time was neutral (+0.006 ms), while total p95 fell from 567.501 to
564.513 ms (0.53%). The change is pinned to v6; v5 and all ordinary, repair,
constrained, or non-greedy paths retain vocabulary-shaped logits.

The v7 runtime removes two MLP residuals only while verifying two-to-four-token
SQL n-gram drafts. A full 200-item comparison against the adjacent v6 control
improved EX from 154/200 to 157/200 and valid SQL from 196/200 to 197/200, with
five accuracy wins and two losses. Mean generation fell from 266.688 to
265.350 ms (0.50%), mean end-to-end time from 377.293 to 375.206 ms (0.55%),
and total p95 from 569.214 to 556.511 ms (2.23%). The candidate won 176/200
generation and 150/200 total-time pairings; its 1.722 ms maximum regression is
noise-sized. A second full run through the production CLI option reproduced
all 200 candidate SQL strings, EX/validity outcomes, and 4,185 target calls
without any experimental environment hook. That run measured 265.490 ms mean
generation, 376.089 ms mean total, 549.781 ms total p95, and a 1.057-second
maximum. The manifest accepts only the evaluated ordered layer list `[8, 10]`;
v1–v6 reject the field.

The v8 runtime retains v7's layer-8/layer-10 verification skips and additionally
omits layer 2 only for three- and four-token target batches. Against the same
adjacent v7 control, it changed 10/200 SQL strings, improved EX from 157/200 to
158/200 with one accuracy win and no losses, and retained 197/200 valid SQL.
Across two order-reversed full-corpus candidate runs, mean generation was
264.386 ms versus 270.726 ms for control (2.34% faster) and mean end-to-end time
was 372.312 ms versus 381.053 ms (2.29% faster). Both candidate orders improved
p95 and maximum latency; they won 363/400 generation pairings and 324/400 total
pairings. The production CLI replay reproduced all 200 SQL strings, token
counts, EX/validity outcomes, and speculative counters from the experimental
candidate, including 4,172 target calls. The manifest accepts only base skips
`[8, 10]` plus long-batch extra skips `[2]`; v1–v7 reject the latter field.

The v9 runtime adds a confidence gate to the otherwise rejected layer-16
three-token specialization. It activates only when both n-gram proposals are
unanimous and each has support of at least 512. The full 200-item gate retained
158/200 EX and 197/200 valid SQL with only four SQL changes from v8, no accuracy
or validity changes, eight fewer emitted tokens, seven fewer target calls, and
13 fewer draft proposals. Three candidate runs reproduced the same complete
output/speculation signature. Against two interleaved v8 controls, every
adjacent mean comparison favored v9; candidate means averaged 281.605 ms for
generation and 373.732 ms end to end versus 285.927 and 378.850 ms for control
(1.51% and 1.35% faster). Candidate total p95 averaged 556.093 ms versus
567.923 ms (2.08% faster). The clean production CLI replay reproduced the
same 200-result signature, including 8,960 tokens, 4,165 target calls, and
6,374 proposals, without an experimental environment variable. The manifest
accepts only layer 16, input length 3, minimum support 512, and unanimity; v1–v8
reject the confidence field.

The v10 runtime adds an independent confidence gate for the common one-draft
path. It omits the layer-35 MLP only for exact two-token verification inputs
whose proposal is unanimous with support at least 512. The full 200-item gate
was byte-identical to v9 across SQL, EX, validity, token counts, and every
speculation counter: 158/200 EX, 197/200 valid, 8,960 tokens, 4,165 target
calls, and 6,374 proposals. A clean CLI replay reproduced that same complete
signature. Four block-interleaved timing passes, with order reversed and
alternated, all favored v10 on mean generation. After averaging all four
measurements per query, mean generation fell from 289.771 to 286.622 ms
(1.09%) and mean total time from 383.131 to 379.601 ms (0.92%). Total p95 fell
from 558.756 to 552.490 ms (1.12%) and the averaged maximum from 1.118 to 1.095
seconds (2.13%). Median paired deltas were -0.920 ms generation and -1.032 ms
total; trimmed-mean deltas were -1.408 and -1.631 ms. The candidate won 113/200
averaged generation pairings, 119/200 total pairings, and 6/10 blocks. A block
bootstrap placed the 95% interval for mean generation delta at -6.335 to
-0.450 ms. The fail-closed manifest accepts only layer 35, input length 2,
support 512, and unanimity as the additional rule; v1–v9 reject the new field.

Follow-up screens confirmed that the support boundary is sharp rather than a
tunable continuum: lowering the exact-two-token layer-35 threshold from 512
to 384 or 256 changed outputs, and thresholds from 128 down through 8 also
reduced validity. Applying layer 35 unconditionally to three/four-token checks
fell to 33/60 EX and 48/60 valid. Confidence-gated layer-35 MLP skips for exact
three- and four-token checks at support 512 preserved the complete 200-item
behavior signature, but a two-pass, 10-block timing matrix improved mean
generation only 0.16% while its paired median and trimmed mean were slightly
slower and only 3/10 blocks won. Those extensions remain rejected.

Applying the matched 8–11x phone/Mac range to the final speculative Swift
distribution with the v10 policy projects a 2.87–3.96 second mean on the iPhone
15 Pro and a 4.19–5.76 second p95. The adjusted observed maximum projects to
8.14–11.20 seconds. This uses the v5/v6/v7/v8/v9/v10 paired ratios to adjust the
selected v4 thermal-run distribution. The deliberately conservative 18x
ceiling still projects a 6.45 second mean, 9.40 second p95, and 18.33 second
maximum.
These remain estimates until the optimized artifact runs on a physical phone,
but both views put the full observed distribution below the 30-second deadline
rather than relying on the mean.

The cap has headroom in the Python evidence: across 460 recorded generations—
the production fine-tune's 200 GCD-on and 200 GCD-off outputs plus the latest
checkpoint's 60 selected-evaluation outputs—the maximum was 104 tokens. None
exceeded 128. Swift nevertheless exposed two deterministic repetition loops
that reached the cap, including one invalid truncated query. Raising the cap to
192 let both loops continue, reduced valid SQL to 80.0%, and reduced EX to
46.7%. The deployed group-128 artifact has no cap hits and a 122-token maximum,
so 128 remains the safer latency and validity guard for this checkpoint.

Primary checked-in evidence:

- `eval/analyses/gcd-f929b94733b949c3/analysis.json`
- `eval/runs/matrix-fine-tune-gold-v2-ft-xiyansql-qwencoder-3b-gcd-off-t-0_0-s-0/`
- `eval/training-runs/qwen25-coder-3b-73cb7525c61bc76c76d880076d56d39e0f25cd1675f21a01c28ae2b560838500-seed-424242-wb-0qvg7e4k/checkpoint-evaluations/runs/checkpoint-000600/`

## Alternatives considered

| Option | Expected effect | Decision |
|---|---|---|
| Qwen2.5-Coder-1.5B 4-bit | Roughly halves weight traffic | Do not deploy as a direct replacement. The matched QLoRA run peaked at 30/60 EX and 51/60 valid SQL on the primary Swift gate, versus 41/60 and 60/60 for production, although mean wall time fell to 0.290 seconds. A fresh all-layer run using the exact selected 3B recipe was also stopped at iteration 100: it emitted plausible SQL followed by punctuation loops on all 60 items, and rescoring only the SQL first line reached just 26/60 EX and 49/60 valid SQL. |
| DatA-SQL-1.5B 4-bit plus app-specific QLoRA | Starts from a SQL-specialized 1.5B base | Do not deploy as a direct replacement. Iteration 400 was the best checkpoint at 36/60 EX and 53/60 valid SQL on the primary snapshot, and 107/180 EX across all three snapshots. Later iteration 500 regressed to 34/60. |
| Validity-gated 1.5B → 3B cascade | Runs the 3B model only when the fast model fails SQLite validation | Reject. The initially promising DatA-SQL iteration-400 result scored 122/180 versus 115/180 for its same-binary q128 control, but the complete 200-item `gold_v2` gate reversed the result: 135/200 versus 154/200. On the 140 questions not used while designing the semantic-risk screen, the cascade scored 94/140 versus 115/140, with 33 regressions and only 12 wins. The screen recovered two cases and still reached only 96/140. Resident memory after preparation was 2.75 GB and measured peak memory footprint was 3.55 GB, so this also carried a substantial phone-memory cost. |
| DatA-SQL 1.5B last-eight-layer QLoRA | Reduces adapter training cost and tests whether preserving lower layers improves generalization | Do not deploy. Iteration 150 reached 14/15 on the screen but only 33/60 EX and 54/60 valid SQL on the full primary gate; its cascade recovered to 36/60 at essentially the same mean latency as the stronger iteration-400 all-layer cascade. Iteration 200 regressed to 13/15 despite a lower validation loss, so the run stopped at the gate. |
| Qwen3-1.7B 4-bit | Smaller model | Do not deploy: its checked-in base screen reached 20.0% EX and showed especially high GCD overhead. |
| Qwen3.5-2B 4-bit | Newer hybrid architecture with higher decode throughput | Reject as a replacement. The pinned Swift runtime produced 168 tokens/second (1.51x q128 throughput), but the unfine-tuned model scored only 4/15 EX and 13/15 valid SQL. An all-layer QLoRA viability probe exposed 8.41 million trainable parameters but did not complete its first optimizer step in six minutes, making a speculative full run unjustified against the 15/15 q128 screen. |
| Qwen3.5-0.8B 4-bit | About 622 MB and optimized for task-specific fine-tuning | Reject. It reached 214 tokens/second (1.93x q128 throughput) but only 2/15 EX and 9/15 valid SQL, far outside the no-regression quality constraint. |
| SQLForge Qwen2.5-Coder-1.5B | Public SQL-specialized adapter on a smaller base | Reject. It reached 10/15 EX on the screen, but the complete 60-item validity-gated cascade scored only 28/60 versus 39/60 for q128, despite invoking the 3B fallback 12 times and retaining 2.76 GB resident after both models were prepared. |
| 2-bit, 3-bit, or mixed 3/4-bit quantization | Reduces the fused model from 1.6 GB to 0.84–1.3 GB | Reject. Earlier post-training 3/4-bit variants collapsed to 0/15 EX and 0% valid SQL while a 4-bit requantization control remained valid. A fresh exact-source test also covered affine 2-bit and 3-bit weights at group sizes 64 and 128: all four scored 0/15 valid SQL, hit the 128-token cap on every item with repetitive text, and took 0.952–1.156 seconds mean wall time versus 0.283 seconds for the same-binary 4-bit group-128 control. |
| Sensitivity-calibrated mixed 2/4-bit quantization | Keeps gradient-ranked sensitive layers at q4 while reducing only low-sensitivity projections | Reject. A 56-batch calibration pass used the exact deployed q4 bytes as teacher and peaked at 22.76 GB. Both the 3.989-bpw artifact (about 1.4 GB) and a near-q4 4.201-bpw artifact (about 1.5 GB versus 4.251 bpw for q128) scored 0/15 valid SQL, emitting repetitive punctuation. Even a very small 2-bit subset destabilizes this checkpoint. |
| 4-bit group-size tuning | Reduces scale metadata and can alter quantization error without lowering bit depth | Deploy group 128. It improved three-snapshot EX by 9.4 points, reached 100% valid SQL, reduced p95 by 29.3%, and reduced the model from about 1.6 GB to 1.5 GB. Group 32 was slower and less accurate; group 256 is unsupported. |
| MXFP4 | Alternate 4-bit encoding | Reject. It scored 12/15 versus 15/15 for affine group 128 and was slower (0.300 versus 0.287 seconds mean wall time). |
| Neural-model speculative decoding | Can reduce autoregressive latency with a good draft model | Reject for this target. Qwen 0.5B preserved all 15 outputs but increased mean wall time from 1.735 to 2.030 seconds and did not improve mean decode throughput. The 1.5B draft also increased total latency. |
| Training-corpus SQL n-gram speculation | Uses a tiny CPU predictor while the 3B model verifies every proposed token | Deploy only under the exact Debug manifest policy. Order 6, a one-token serial prefix, and adaptive one/two/three-token drafts preserved every SQL string and token count over 200 items while reducing mean total latency 18.2% and p95 21.3%. Additional tokens are proposed only while every context is unanimous across at least eight training occurrences; K=3 reduced target calls from 5,168 to 4,141 and improved mean another 1.6% over adaptive K=2. K=4 changed one 60-item output and was slower. Relaxing unanimity to 99%, 95%, 90%, or 80% preserved the 60 outputs but added 2.9–11.3 ms paired mean latency, so unanimity remains required. Starting with zero serial tokens changed 7/60 outputs. Fixed two-token drafts were slower, so the deployed iterator expands selectively. Acceptance-adaptive fallbacks after four or sixteen rounds also increased mean and p95, so speculation otherwise remains uninterrupted. A 1,520-statement repair-05 corpus looked 1.7% faster on 60 items, but saved only three target calls over 200 and made mean total latency 1.7% slower; the pinned 1,353-statement corpus remains selected. A corrected per-token serial fallback for contexts absent from the corpus preserved all 200 outputs, but increased target calls from 5,168 to 5,232 and mean total latency by 10.2 ms (2.4%), losing on 142/200 paired items; it was removed. Adding 200 training-only SQL strings generated by the deployed model reduced target calls from 5,168 to 5,146 and preserved all 200 outputs, but increased mean total latency by 5.3 ms and lost on 128/200 paired items, so the larger self-draft corpus was rejected. Orders 4, 5, 7, 8, 10, 12, and 16 all preserved the 60-item outputs; order 12 looked best by call count, but the full 200-item gate increased calls from 5,168 to 5,204, raised mean latency 8.0 ms, and lost 133/200 pairings, confirming order 6. |
| Prompt/KV-cache reuse | Avoids repeated system/schema prefill | Deploy. It removes 1,207 of 1,220 prompt tokens from the timed path and passed byte-identical 60-item Swift parity. |
| Direct user-suffix tokenization | Avoids re-rendering and re-tokenizing the cached 1,207-token schema on every query | Deploy with preparation-time fail-safe validation. Alternating same-binary runs reduced mean input preparation from 13.613 to 5.778 ms (57.6%). All SQL strings and token counts matched across the 15- and 60-item gates; the 60-item run retained 39/60 EX and 60/60 valid SQL. |
| Preparation-time verification-shape warmup | Evaluates ordinary three/four-token and confidence-specialized two/three-token graphs before the first query deadline | Reject. Six alternating fresh-process pairs on a one-draft first query made generation exactly neutral. Repeating on T1-02, which uses 19 drafts across 15 target rounds, averaged 191.060 ms generation with the extra warmup versus 191.164 ms control (-0.05%); total time regressed 0.09% and preparation increased by about 120 ms. MLX's relevant kernels are already generalized by the existing one/two-token warmup. |
| Cached diagnostic-privacy expressions | Compiles the five immutable SQL/path/identifier redaction regexes once instead of rebuilding ICU state for every diagnostic value | Deploy in the app code independently of the model runtime version. The same 15-query Release Time Profiler workload reduced inclusive `DiagnosticPrivacy.redact` CPU from 1,138 to 5 ms, ICU leaf work from 755 to 4 ms, and total sampled CPU from 4,600 to 3,580 ms. SQL and every speculation counter stayed identical. Even though the second run's Metal generation slice was thermally slower, mean end-to-end time fell from 239.9 to 186.6 ms (22.2%). All 106 Swift tests, including the privacy-boundary cases, pass unchanged. |
| In-place reuse of the prepared prompt KV cache | Avoids cloning the 36-layer cache for each query | Reject. Two alternating 15-item pairs preserved every SQL string and token count, but reduced mean input preparation by only 0.185 ms (5.682 to 5.497 ms) while mean generation increased 2.3% (187.926 to 192.273 ms). The apparent total-time gain occurred only in the first pair and disappeared when run order was reversed. Shared mutation would also require cancellation-safe serialization, so the production path retains independent cache copies. |
| Question-aware restricted output projection | Computes greedy primary logits for about 4,100 SQL/prompt-relevant rows of Qwen's 151,936-token head | Deploy through the fail-closed Debug runtime v4 manifest. Static training-only and printable-ASCII attempts were rejected: the former changed quality and the latter was slower. The selected resource-plus-question policy covered all control-selected tokens offline, then preserved every output and speculation decision in a same-binary 200-item gate while improving mean total 4.79%, generation 6.75%, p95 5.43%, and maximum 7.46%. It won all 200 generation pairings. Repairs and non-greedy/non-production modes keep the full head. |
| Preparation-cached training-question output head | Reuses one 13,036-row restricted projection instead of gathering roughly 4,100 question-specific rows per request | Reject. The vocabulary was derived only from training user messages plus the bundled SQL/schema/grammar sources and covered every token selected by the full-head control over 200 evaluation items. It preserved every SQL string, token count, and speculation decision in one 15-item and two order-reversed 60-item comparisons. The first 60-item order made fixed 2.833 ms faster overall; reversing order made it 1.238 ms slower. Across both pairs it was only 0.797 ms faster overall (0.20%) while generation was consistently 1.789 ms slower and won just 13/120 generation pairings. The noise-sized setup saving does not justify tripling the restricted projection or adding a production vocabulary resource. |
| Narrower question-token selectors | Reduces the dynamic head below the selected roughly 4,100-row substring policy | Reject. Encoding each word in every output-relevant context reduced the offline mean to 3,579 rows, but two order-reversed 15-item pairs were total-time neutral because tokenizer setup erased the projection saving. A cheaper 3,606-row encoding policy improved the aggregate 15-item generation time by 1.459 ms, then reversed across two 60-item orders: aggregate total and generation became 1.444 and 0.735 ms slower. All SQL strings and token counts matched, although one long item changed internal speculation acceptance. A tokenizer-free 3,905-row policy that kept all length-three substrings plus two-character word boundaries retained exact output and speculation on 15 items, but made generation 0.265 ms slower. The broader selected policy remains both safer for unseen literals and no slower in repeatable end-to-end timing. |
| Drop corpus-specific literal rows from the question-aware head | Retains grammar, schema, request fragments, punctuation compounds, and short aliases while reducing the static vocabulary tail | Reject. Dropping every draft-corpus row changed 3/15 SQL strings and reduced EX from 15/15 to 14/15. Retaining punctuation-only and one/two-character corpus tokens restored exact SQL and speculation over 60 items, but mean generation increased 0.19% while total time changed by only -0.06%. The smaller projection is neither safer nor measurably faster. |
| Cached invariant rows within the dynamic output head | Gathers the 3,523 SQL/schema rows during preparation and appends only question-specific rows per request | Reject. It retained exact SQL, token counts, and speculation in two order-reversed 15-item pairs, and generation was neutral as intended. Total time improved 1.101 ms in the first order and regressed 1.162 ms when reversed, for a 0.031 ms aggregate regression. Concatenating the cached and dynamic quantized tensors costs essentially the same as MLX's existing one-shot gather, while retaining an extra projection copy in memory. |
| Compact restricted-head sampling | Samples the roughly 4,100 local logits directly and maps the local argmax back to a global token ID instead of scattering into a vocabulary-shaped tensor | Reject. It preserved every SQL string, token count, and speculation decision on 15 items, but mean total and generation rose 2.782 and 2.855 ms versus the selected scattered head; it won only 6/15 total and 2/15 generation pairings. The extra indexed token-ID gather outweighed the avoided fill/scatter. |
| CPU-mapped compact restricted-head sampling | Converts the already-synchronized target batch's local argmax indices to global IDs on the CPU, avoiding both the full-vocabulary scatter and a GPU gather | Deploy through the fail-closed Debug runtime v6 manifest. Two reversed 60-item pairs and the 200-item gate preserved every SQL string, token count, accuracy result, validity result, and speculation counter. The full gate improved mean generation 0.40% and won 141/200 generation pairings; end-to-end mean was neutral, but total p95 improved 0.53%. |
| Shape-aware verification-only MLP residual skipping | Omits layers 8 and 10 for every two-to-four-token target check, plus layer 2 only for three- and four-token checks | Deploy through the fail-closed Debug runtime v8 manifest. V7's base skips improved EX from 154 to 157 and validity from 196 to 197 versus v6. The additional shape-aware v8 skip then improved EX to 158 with no accuracy losses, retained 197 valid SQL, and reduced order-reversed mean generation and total latency by 2.34% and 2.29% versus adjacent v7. Its production-path replay reproduced all SQL, token counts, and speculative counters. Prompt prefill, one-token serial decoding, repairs, and every other layer remain complete. |
| Confidence-gated exact-length MLP skip | Omits layer 16 only for exact three-token verification inputs backed by two 100%-unanimous n-gram continuations with support at least 512 each | Deploy through the fail-closed Debug runtime v9 manifest. The full 200-item gate retained 158 EX and 197 valid SQL with no outcome changes, while deterministic repeated runs saved eight output tokens, seven target calls, and 13 proposals versus v8. Interleaved candidates improved mean generation 1.51%, mean total 1.35%, and total p95 2.08% on average. Ungated length-three layer 16 was rejected because its extra tokens and calls made it slightly slower. |
| Confidence-gated final-MLP skip for one-draft checks | Omits layer 35 only for exact two-token verification inputs backed by one 100%-unanimous n-gram continuation with support at least 512 | Deploy through the fail-closed Debug runtime v10 manifest. The complete 200-item output, accuracy, validity, token, and speculation signatures were byte-identical to v9. Four order-balanced timing passes improved averaged mean generation 1.09%, total 0.92%, total p95 1.12%, and maximum 2.13%; all four pass means favored v10 and the block-bootstrap 95% interval for generation delta remained below zero. As the final-layer MLP, the skipped residual cannot alter later-layer K/V cache state. |
| Broader confidence-gated MLP skipping | Omits more layers or adds an exact-four-token specialization under strong n-gram evidence | Reject beyond v10. Adding layer 27 to v9's exact-three-token gate retained 158 EX/197 valid and exact counters, but a reversed short A/B was total-time neutral. Adding all remaining MLP skips only at support 1,024 preserved the complete 200-item signature, yet a stronger 10-block A/B was slower in 9/10 blocks. An exact-four-token layer-14 rule at support 256 retained 158/197 and made only execution-equivalent SQL changes, but two opposite-order 200-item passes regressed generation 1.21% and total 1.02%. |
| Confidence-gated final-layer cache-only execution | For v10's exact-two-token support-512 gate, computes and caches only the final layer's K/V projections while omitting Q, attention, output projection, and MLP | Reject. Separate K/V projections were timing-neutral on two reversed 60-item passes. Fusing K/V preserved every SQL string, outcome, token count, and speculation counter over the full 200-item gate and looked 0.51% faster on the 60-item screen. The stronger two-pass full-corpus reversal disagreed: pass one improved generation 0.10%, pass two regressed 0.85%, and the order-averaged result was 0.37% slower with a 0.91 ms slower paired median and only 73/200 wins. The experimental path was removed. |
| Confidence-gated fourth draft token | Extends an already-unanimous three-token proposal by one token under stronger support | Reject. Support 256 retained 158/200 EX and 197/200 valid SQL and saved 13 target calls, but added 24 emitted tokens. Two opposite-order 200-item passes regressed mean generation 1.63% and total time 0.99%. A stricter support-512 follow-up retained EX, validity, and total tokens while saving 22 calls, but changed G-145's upper date boundary from `2026-06-30` to `2026-07-01`; both happened to execute correctly only because of the benchmark snapshot. Every active fourth proposal had support exactly 525, while thresholds 528, 544, 576, 640, 768, and 1,024 were inactive. Restricting the fourth proposal to the repeated structural `" ="` token still reproduced the date change, proving the verification shape rather than the exceptional token caused the semantic drift. The experimental path was removed. |
| Trust ultra-high-support draft tokens without projecting their verification positions | Still executes the target transformer/K/V path but projects only the final position when every draft is unanimous | Reject. Thresholds below 1,024 reduced the 60-item screen to 41 EX; support 1,024 preserved the complete 200-item behavior signature. Its two-order 200-item A/B improved generation only 0.056% and total 0.143%, with just 5/10 blocks faster. The noise-sized result does not justify changing the invariant that target logits verify every emitted draft token. |
| Last-position-only compact prefix projection | Projects only the final hidden state when the serial prefix consumes the remaining prompt suffix | Reject as below the noise floor. It preserved every SQL string, accuracy/validity result, and speculation counter over the 200-item gate, but improved mean generation only 0.05% and total time only 0.11%, winning 96/200 generation and 93/200 total pairings. Two smaller reversed screens disagreed on the size and direction of the effect. |
| FP16 execution and KV-cache variants | Reduces BF16 arithmetic or cache bandwidth without altering the q4 packed weights | Reject on quality or latency. Casting every floating parameter to FP16 changed 9/60 SQL strings, reduced validity from 60 to 59, reduced EX from 39 to 38, and increased mean generation 1.95%. Restricting FP16 to the compact output head preserved 15/15 outputs but increased generation 0.05% and total time 0.80%. An always-FP16 KV cache changed 6/60 outputs; delaying conversion until 16 generated tokens still changed 2/60 and increased generation 0.78%. The deployed BF16 path remains selected. |
| Smaller KV-cache growth quantum | Allocates generated-token cache capacity in 128-token rather than 256-token increments | Reject. It preserved all 15 SQL strings but increased mean generation 0.11% and total time 0.49%. The default growth policy remains selected. |
| Compact-output prompt instruction | Asks the model to use fewer output tokens without changing SQL semantics | Reject. Appending `Use the shortest execution-equivalent SQL.` preserved 15/15 EX, but changed zero SQL strings and generated the same 279 tokens as the clean control. Mean generation was 194.559 ms versus 192.107 ms for the clean screen, so the extra prompt tokens provided no latency benefit. |
| Preserve unused KV-cache capacity while cloning the prompt cache | Avoids the first suffix-token cache growth | Reject. All 60 SQL strings were identical, but mean generation time increased 1.2% (424.5 to 429.4 ms) and total time changed by only -0.2%, within noise. |
| MLX allocator-cache sizing | Reuses temporary GPU buffers without increasing model or KV precision | Keep the existing 20 MB limit. An exact-output 15-item sweep over 2, 8, 16, 20, 32, 48, 64, and 256 MB found 20 MB fastest at 188.121 ms mean generation. The 48/64 MB results were statistically tied at 188.131/188.144 ms but consumed more cache; both smaller and larger settings were slower. |
| MLX fast fence synchronization | Uses Metal's newer shared-event synchronization path | Reject. `MLX_METAL_FAST_SYNCH=1` preserved all outputs but changed mean generation from 192.107 to 192.033 ms (-0.04%) and mean total time from 275.102 to 274.975 ms, which is measurement noise. |
| MLX command-buffer operation limit | Commits GPU work more frequently to reduce apparent decode latency | Keep MLX's device defaults. Alternating 15-item runs with 20 rather than 40 operations per command buffer reduced measured generation by 4.13%, but true end-to-end time by only 0.32%; the work moved into stream cleanup rather than disappearing. Limits from 10 through 80 showed the same flat total-time behavior, and MLX already selects 20 automatically on iPhone-class GPUs. |
| MLX command-buffer byte limit | Commits large Metal command buffers sooner without changing graph semantics | Deploy 10 MB through the fail-closed Debug runtime v2 manifest. A matched 200-item gate preserved every output and all accuracy/speculation counters while improving mean total latency 0.87%, mean generation 4.08%, p95 3.41%, and maximum 1.51% versus MLX's 40 MB default. It won 129/200 pairs; two order-reversed 60-item pairs also favored it on 52/60 and 48/60 items. A later 4/6/8/10 MB sweep made 4 MB look fastest inside the stream. Two full 200-item order-reversed gates then showed why it must not replace 10 MB: all 400 outputs remained exact and 4 MB saved 5.229 ms of measured decode, but it added 6.638 ms to the synchronous iterator/prefill and surrounding slice, regressed true end-to-end mean by 1.425 ms, and won only 140/400 total-time pairings. |
| Compiled Qwen2 SiLU-product graph | Consolidates the MLP activation and elementwise product into one shapeless MLX graph | Deploy through the fail-closed Debug runtime v3 manifest. A same-binary 200-item A/B preserved every output and speculation decision while improving mean total time 1.14%, generation 0.88%, p95 1.16%, and maximum 1.43%; independent order-reversed runs also favored it. |
| Compiled complete quantized MLP graph | Extends compilation across gate/up quantized matrix multiplies, SiLU/product, and the down projection | Reject. Two order-reversed 15-item pairs preserved every SQL string, token count, and speculation counter, but aggregate mean generation increased from 147.211 to 149.153 ms (1.32%) and total time from 251.068 to 252.827 ms (0.70%). Passing all quantized weights through the compiled graph costs more than the extra eager scheduling it removes. |
| Compiled q4 projection-plus-bias graph | Compiles the affine quantized matrix multiply and bias addition used by Q/K/V | Reject. It preserved all 15 SQL strings but increased mean generation 0.60% and won only 1/15 generation pairings. MLX's eager affine projection remains faster at these shapes. |
| Fused quantized Q/K/V projection at every sequence length | Replaces three attention projections with one concatenated quantized matrix multiply and two views | Reject on quality. It looked strong and exact over two order-reversed 15-item and two 60-item pairs; the 60-item aggregate improved total and generation by 6.534 and 4.654 ms, winning 106/120 total and 120/120 generation pairings. The required 200-item gate then exposed one divergent query: execution accuracy stayed 154/200, but G-204 changed from valid SQL to a 128-token unterminated literal, reducing validity from 196/200 to 195/200 and increasing the observed maximum. Prefill-only fusion reproduced the failure, proving the long-prefill reduction order was unsafe. Restricting fusion to one-token decode restored exact G-204 output and preserved all 60 outputs in two reversed orders, but aggregate generation regressed 0.136 ms and the apparent 0.480 ms total gain was order/cleanup noise. |
| Verification-only fused quantized Q/K/V projection | Uses the concatenated projection only for two-to-four-token target-verification tensors | Deploy through the fail-closed Debug runtime v5 manifest. G-204 returned to the control SQL, both reversed 60-item gates were exact and improved aggregate mean generation 2.7%, and the 200-item gate preserved every output, accuracy result, validity result, and speculation counter. The full gate improved mean generation 1.56%, with 197/200 generation wins, while prepared resident memory did not increase. The code has no production mode that can fuse the accuracy-breaking long prefill. |
| Short-suffix fused quantized Q/K/V projection | Extends the verified fusion from two-to-four-token checks through direct prompt suffixes of at most 16 tokens, while leaving the known divergent 17-token G-204 suffix unfused | Reject. All 60 SQL strings and speculation counters remained exact, but mean generation increased 0.22% and won only 31/60 pairings. Total time changed by a noise-sized -0.21% while the maximum regressed, so the selected path remains verification-only. |
| Fused quantized K/V projection | Preserves the query projection while combining the two smaller attention projections | Reject. It preserved exact SQL and speculation in two order-reversed 15-item pairs, but aggregate generation regressed 0.030 ms and aggregate total improved only 0.090 ms. The removed dispatch is too small to matter. |
| Fused quantized gate/up projection | Replaces the MLP's two equal-sized input projections with one matrix multiply and two views | Reject at the screen. Fusing at every shape preserved 15/15 EX and exact output/speculation, but increased mean generation 0.388 ms and total time 3.920 ms, winning only 3/15 generation pairings. Restricting it to the v5 two-to-four-token verification calls also preserved exact output/speculation, but increased mean generation 0.462 ms, won only 4/15 generation pairings, and changed total time by a noise-sized -0.013 ms. The doubled output width offsets any dispatch saving even at the smaller shape. |
| Whole-layer or whole-phase structured skipping | Omits complete transformer blocks, attention, or MLP work at every sequence length | Reject beyond v8. Full-block layer 2 was 4.09% faster over 200 items and reached 159/200 EX, but validity fell from 196 to 195; retrying all five invalid outputs erased nearly all of the gain. Full-block layer 10 likewise reached only 195 valid SQL. MLP-only layer 2 scored 157/200 EX and 195 valid. Exhaustive short-verification screens of additional layer pairs and triples found no full-gate winner: the promising `[8, 14]` pair fell to 154 EX/195 valid over 200, and adding layer 14 to every three/four-token check was timing-neutral with a worse tail. After v8, exact-length screens identified layer 16 for three-token checks and layer 24 for four-token checks as a 43/60 EX combination, but the full gate fell to 196 valid SQL. Isolated layer 24 at length four scored 156/196; layer 14 at lengths three or four scored 158/196; layer 16 at length four scored 156/195; and layer 24 at length three scored 156/196. Layer 16 at length three alone reached 159/200 EX and retained 197 validity, but emitted 19 extra tokens, made seven extra target calls, and was slightly slower than adjacent v8, so accuracy improvement alone does not justify it. Only v8's layer-2 long-batch specialization improves quality and repeatable latency together. |
| Direct tied-embedding access for the restricted head | Avoids flattening and scanning the compiled model's module tree once per query | Reject as unmeasurable. The 60-item candidate preserved every SQL string, token count, and speculation decision, but mean total time changed by only -0.049 ms, won 30/60 total-time pairings, and made the non-generation setup slice 0.424 ms slower. The apparent -0.473 ms generation change cannot come from this setup-only edit and is timing noise. |
| Skip zero-token speculative-cache trims | Avoids visiting all 36 prompt caches after a fully accepted draft | Reject. The candidate preserved every SQL string, token count, and speculation decision over 60 items, but mean generation was 4.686 ms slower than the preceding control and 4.458 ms slower than the following control. It won only 21/60 and 24/60 generation pairings respectively, so the branch costs more than the existing no-op trim path. |
| Trust the restricted vocabulary's existing sorted/unique form | Avoids rebuilding and sorting a second 4,000-row `Set` per request | Reject as unmeasurable. The 60-item candidate preserved every SQL string, token count, and speculation decision, but saved only 0.040 ms of input preparation, changed mean total time by -0.077 ms, and increased measured generation by 0.865 ms. It won 31/60 total and 23/60 generation pairings, so the private-contract complexity has no end-to-end payoff. |
| Compiled residual-add/RMSNorm graph | Extends graph compilation across a Qwen residual boundary | Reject. It preserved all 60 outputs, but generation increased 1.375 ms and was faster on only 5/60 pairings. Its 0.402 ms total-time improvement was cleanup-placement noise rather than reduced generation work. |
| MLX graph-traversal breadth | Changes breadth-first graph scheduling before GPU evaluation | Keep the default width of 20. Exact-output 15-item runs at widths 5, 10, 20, 40, and 80 all generated the same 279 tokens. Mean total times were 274.775, 275.429, 275.260, 276.337, and 275.352 ms respectively, a noise-sized spread with no monotonic improvement. |
| Prompt shortening | Reduces prompt-cache attention and preparation work | Reject. Removing 493 bytes of repeated schema values reduced the 15-item screen from 15/15 to 14/15 and slightly increased mean generation as the changed prompt emitted six extra tokens. Removing every enum scored 12/15; removing the three demonstrations scored 13/15 with only 14/15 valid SQL and emitted 29 extra tokens. The exact training prompt is both more accurate and faster after output length is included. |
| Collect raw token IDs and detokenize once | Removes per-chunk Swift string appends | Reject. It preserved 15/15 EX but changed only insignificant whitespace and moved mean wall time from 282.116 to 282.402 ms; generation time was likewise neutral (194.209 versus 194.328 ms). |
| Stop decoding at the first decoded SQL terminator | Avoids EOS or prose after a complete statement | Reject. On all 60 questions it preserved every SQL string, 39/60 EX, and 60/60 validity, but generated exactly the same token counts. A same-binary control was faster: mean generation was 415.288 versus 416.738 ms and total time was 503.226 versus 506.508 ms. The selected model already terminates cleanly. |
| Repetition penalty | Can terminate deterministic output loops | Reject. A mild 1.02 penalty reduced the Swift binding score from 53.3% to 46.7% by changing an execution-correct cap-hit query. |
| 8-bit KV-cache compression | Reduces attention-cache bandwidth | Reject. A serial same-binary screen preserved all 15 outputs but increased mean wall time from 0.283 to 0.297 seconds (5.0%); an earlier run was 9.4% slower. Combined with the selected batched n-gram verifier, both ordinary dynamic conversion and preparation-time prefix prequantization collapsed to 0/15 valid SQL versus 15/15 for the uncompressed cache. The numerical perturbation is therefore incompatible with production speculation as well as slower in the serial path. |
| 4-bit KV-cache compression | Further reduces attention-cache bandwidth | Reject. It collapsed from 15/15 to 0/15 valid SQL, expanded output from 279 to 1,455 tokens, and increased mean wall time from 0.283 to 1.039 seconds. |
| MLX wired-memory ticket | Keeps weights resident during active decode to avoid unified-memory paging | Retain behind the physical-benchmark flag, disabled by default. It preserved every SQL string across 60 items. On the M4 Pro, mean generation was neutral (-0.03%) and total time increased 0.28%; only an 8 GB phone under realistic memory pressure can establish whether residency offsets the ticket/system-call overhead. |
| Speculative decode warm-up during model preparation | Moves first-use decode-shape work outside the query deadline | Reject. Six paired cold-launch runs with a four-token warm-up reduced first-query generation by only 1.09 ms (1.2%) while increasing preparation by 143 ms. Immediate preparation-plus-query latency therefore became about 142 ms slower. |
| Optimized benchmark build | Removes Debug `-Onone` host-code overhead while retaining the experimental model gate | Use for physical measurement. The signed app is built with Release `-O` and whole-module settings plus an explicit benchmark-only compile condition; its bundled q128 manifest and receipt verify unchanged. Physical timing is pending device unlock. |
| Re-fusing from BF16 or under the current toolchain | Avoids carrying forward the evaluated fused bytes | Reject. Both paths changed outputs; the clean BF16 fusion scored 11/15 on tier 1, and the newly re-fused group-128 artifact scored 13/15 versus 15/15 for the pinned evaluated artifact. |

The immediate phone build uses the one-candidate Debug v10 policy and the pinned
group-128 artifact with compiled Qwen2 MLP fusion and the question-aware output
head. Its two-to-four-token target checks also use the verified fused Q/K/V
projection and omit the evaluated layer-8/layer-10 MLP residuals; three- and
four-token checks additionally omit layer 2. Exact three-token
checks additionally omit layer 16 only under the manifest-pinned 512-support
unanimity gate. Exact two-token checks additionally omit final-layer MLP 35
under the same support/unanimity threshold. It maps the already-synchronized local argmax indices to global
vocabulary IDs on the CPU. The CPU SQL n-gram verifier is the only speculative path
that improved latency without changing the 200-item output or accuracy gate;
smaller-model, cascade, lower-bit, neural-draft, and Swift-loop alternatives
lose accuracy or fail to improve latency. The remaining physical experiment is
an A/B of the same exact q128
artifact with MLX wired memory disabled and enabled. Wired memory remains off
by default until that phone measurement proves a benefit; it does not alter
weights, prompts, or generated tokens.
