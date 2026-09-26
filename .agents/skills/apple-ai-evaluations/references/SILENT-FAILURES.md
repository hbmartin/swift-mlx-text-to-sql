# Silent-failure index — Evaluations: measuring on-device model output

**73 ⚠️ callouts from the guide parts this skill covers, sorted by the symptom you would observe.** Most defects in this stack do not throw, so the symptom is what you start from.

> Sliced from the series index on 2026-09-22. The full index across all 17 parts is at https://github.com/hbmartin/Foundation-Models-and-Core-AI-and-MLX-skills/blob/main/guides/SILENT-FAILURES.md. Generated — regenerate with `./scripts/build-skills.sh` rather than editing by hand.

| Symptom | Entries |
|---|---:|
| [Wrong output](#wrong-output) | 6 |
| [Empty output / no-op](#empty-output--no-op) | 4 |
| [Truncation & limits](#truncation--limits) | 9 |
| [Ignored input](#ignored-input) | 1 |
| [Stale state](#stale-state) | 3 |
| [Misleading signals](#misleading-signals) | 11 |
| [Docs vs reality](#docs-vs-reality) | 11 |
| [API footguns](#api-footguns) | 8 |
| [General cautions](#general-cautions) | 20 |

## Wrong output

**Part 6**

- [Expert and judge scores pair by index; any reorder, filter or dropped call shifts pairs — kappa reads a plausible 0-0.2.](part-06-evaluations/references/02-model-judges-and-alignment.md#191-️-the-positional-join-which-nothing-validates) — 6.2
- [?? 0.0 turns a missing expert score into an off-scale fifth category, skewing p_chance and depressing kappa beyond one…](part-06-evaluations/references/02-model-judges-and-alignment.md#192-️--00-turns-a-missing-expert-score-into-a-rating-of-zero) — 6.2
- [The generating session has no tools registered; it invents lookalike names and the samples look valid but score as…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#181-️-the-generating-model-has-never-heard-of-your-tools) — 6.3

**Part 16**

- [Auto-rename binds fields to inputs on shape alone — a mask or pre-normalised batch is analysed cleanly and wrongly](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#52-input-binding--the-auto-rename-and-when-it-stops) — 16.5 🔇
- [A zero-L2 constant column turns normalisation into NaN/inf with no guard — the duplicates index is silently poisoned](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#63-duplicates--the-one-you-should-run-first) — 16.5
- [Consolidated: field-to-input auto-rename fires on shape agreement alone](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#10-consolidated-footguns) — 16.5

## Empty output / no-op

**Part 6**

- [guard let expected copied into a prompt-only generator rejects 100% of output — no-expected datasets validate to zero…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#82-the-validator-you-should-write) — 6.3 🔇

**Part 16**

- [Keras 3 before 2f39056 yields generic tensor names and an empty layer list — a successful run that analyses nothing](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#55-loading-a-tensorflow-model-and-the-keras-3-story) — 16.5 🔇
- [Without umap-learn the report builds successfully with no projection columns — Symphony shows an empty scatter](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#66-datasetreport--four-introspectors-one-dataframe) — 16.5
- [Consolidated: Keras 3 without 2f39056 classifies every layer UNKNOWN — empty analysis, no error](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#10-consolidated-footguns) — 16.5

## Truncation & limits

**Part 6**

- [JSONLoader logs malformed rows to OSLog and skips them; a corrupt dataset shrinks and still reports a clean aggregate.](part-06-evaluations/README.md#61--building-blocks-swift-testing-integration-and-evaluation-driven-development) — 6.README 🔇
- [targetCount is a total: 13 seeds + 100 yields 87 new samples, and a target below your current count generates zero…](part-06-evaluations/README.md#63--samplegenerator-synthetic-datasets-and-evaluating-tool-trajectories) — 6.README 🔇
- [A 100-row file with 63 undecodable rows loads 37, runs cleanly and reports a green aggregate; only OSLog records the…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#171-a-corrupt-dataset-shrinks-your-evaluation-instead-of-failing-it) — 6.1 🔇
- [TOC: targetCount counts the samples you already have — generation runs under-deliver or produce nothing.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#contents) — 6.3
- [targetCount is the total dataset size including seeds, not a count of new samples to generate.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#3-️-targetcount-counts-the-samples-you-already-have) — 6.3
- [With 800 samples, targetCount: 200 adds nothing and exits cleanly; 13 seeds + 1000 yields 987 new — never a thousand.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#3-️-targetcount-counts-the-samples-you-already-have) — 6.3 🔇
- [JSONLoader reads JSON or JSONL and OSLog-and-skips malformed entries — your dataset silently shrinks on read.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#93-reading-it-back--and-the-loader-that-swallows-your-data) — 6.3 🔇

**Part 16**

- [PFA skips layers with fewer samples than features, emitting only a warning — the layer is absent from the recipe](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#65-pfa--principal-filter-analysis) — 16.5 🔇
- [Consolidated: PFA drops unanalysable layers with only a warning](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#10-consolidated-footguns) — 16.5

## Ignored input

**Part 6**

- [instructions and reference apply only to pointwise evaluators; pairwise drops your ModelJudgePrompt for Apple's…](part-06-evaluations/references/02-model-judges-and-alignment.md#195-️-a-pairwise-judge-silently-discards-your-instructions) — 6.2

## Stale state

**Part 6**

- [TOC: sessionProvider is a factory that may be called again mid-run, discarding conversation-held state.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#contents) — 6.3
- [sessionProvider is a factory: on context exhaustion the run silently swaps in a fresh session mid-generation.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#5-️-sessionprovider-is-a-factory-and-it-may-be-called-twice) — 6.3
- [After a mid-run session swap, conversation-held rules ('no repeats') vanish — the dataset's second half goes…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#5-️-sessionprovider-is-a-factory-and-it-may-be-called-twice) — 6.3 🔇

## Misleading signals

**Part 6**

- [An eval whose model config differs from the app's (guardrails, options) scores a system you don't ship, and stays green.](part-06-evaluations/references/01-foundations-and-hill-climbing.md#4-step-1--subjectfrom-the-code-under-measurement) — 6.1 🔇
- [(3...8).contains reads 100% for a constant 8 — @Guide(.count(3...8)) fixed the range and collapsed the distribution…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#pairing-a-passfail-metric-with-a-scored-one) — 6.1 🔇
- [Omit ModelJudgePrompt and the judge falls back to defaultInstructions — stable, plausible scores with zero app context.](part-06-evaluations/references/02-model-judges-and-alignment.md#83-what-good-instructions-contain) — 6.2 🔇
- [Judge drift never throws and grows with your dataset; the only detector is the kappa calibration you must build…](part-06-evaluations/references/02-model-judges-and-alignment.md#122-the-mechanics-and-the-part-that-should-alarm-you) — 6.2 🔇
- [Calibration contamination raises kappa — the judge looks better the more you break it, then ships behind a green test.](part-06-evaluations/references/02-model-judges-and-alignment.md#18-overfitting-the-alignment-score) — 6.2 🔇
- [cohensKappa ?? 0 reports undefined kappa (single category, mismatched arrays) as chance-level agreement — wrong…](part-06-evaluations/references/02-model-judges-and-alignment.md#193-️-an-undefined-κ-reports-as-no-agreement) — 6.2
- [A judge returning 4 every time posts a perfect mean and zero sigma; aggregate only the mean and you ship it.](part-06-evaluations/references/02-model-judges-and-alignment.md#194-️-a-judge-that-never-varies-looks-excellent-by-mean) — 6.2
- [An eval on default guardrails while the app runs permissive ones scores a different system, and no test will say so.](part-06-evaluations/references/02-model-judges-and-alignment.md#197-️-the-evaluation-constructs-the-model-differently-from-the-app) — 6.2
- [TOC: the validator sees one sample at a time — cross-sample rules become always-true no-ops.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#contents) — 6.3
- [The validator runs on single samples; dataset-wide rules cannot be expressed and quietly validate nothing.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#8-️-the-validator-runs-alone) — 6.3
- [Cross-sample rules in a one-sample validator ('reviews must vary') are trivially true — check-shaped no-ops that pass…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#81-the-two-bins) — 6.3 🔇

## Docs vs reality

**Part 6**

- [Session 335 presents Cohen's kappa as built-in; MetricsAggregator has no agreement statistic — Apple hand-writes 72…](part-06-evaluations/README.md#62--model-judges-score-dimensions-drift-and-cohens-kappa) — 6.README 🔇
- [The evaluates trait's second parameter is info: [String: String]; session 298 calls it 'notes' — trust the API spelling.](part-06-evaluations/references/01-foundations-and-hill-climbing.md#81-the-trait-is-evaluates-and-the-second-label-is-info) — 6.1
- [Reconstructions show func f(results:); the real shape is plain func f() reading EvaluationContext.current.result…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#83-the-dataset-runs-before-the-test-body-and-the-body-never-iterates) — 6.1
- [reference returns [String: String] — each pair a labelled prompt section — not the String circulating material claims.](part-06-evaluations/references/02-model-judges-and-alignment.md#81-the-type) — 6.2
- [Cohen's kappa is not in the framework despite session 335; Book Tracker hand-writes 72 lines in Statistics.swift.](part-06-evaluations/references/02-model-judges-and-alignment.md#151-the-correction) — 6.2
- [The doc gestures at 'certain eligibility requirements'; the session states a <2M-downloads bar — a genuine corpus…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#61-the-entitlement-is-managed-and-there-is-an-eligibility-bar) — 6.3

**Part 16**

- [Familiarity's sign is documented backwards; PFA drops layers with a mere warning; pre-fix Keras 3 analyses nothing](part-16-adjacent-capabilities/README.md#165--dnikit-auditing-datasets-and-networks-before-you-convert) — 16.README 🔇
- [The docs' math has Familiarity's sign backwards — higher is more familiar; sort the documented way and results invert](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#62-familiarity--out-of-distribution-and-rare-data-scoring) — 16.5 🔇
- [The notebook reports difference of mean log-scores (log of the ratio) — log the thresholds before comparing](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#62-familiarity--out-of-distribution-and-rare-data-scoring) — 16.5
- [The notebook's FieldRenamer literal is TF1-style 'input_1:0'; TF2 names it 'input_1' — check model.input_layers](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#64-iua--inactive-unit-analysis) — 16.5
- [Consolidated: Familiarity is higher-is-more-familiar; the docs' math section disagrees](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#10-consolidated-footguns) — 16.5

## API footguns

**Part 6**

- [Apple's snippet shadows Metric('Match') in the closure — same-name metrics merge or produce results aggregation never…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#the-shape-before-the-details) — 6.1
- [Metric labels are unchecked strings written twice; a case typo makes #expect read a label that was never registered.](part-06-evaluations/references/02-model-judges-and-alignment.md#196-️-a-custom-label-typo-tests-nothing) — 6.2
- [The samples result includes the seeds too — appending it to an existing dataset duplicates every seed.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#4-samplegenerator-parameter-by-parameter) — 6.3

**Part 16**

- [An infinite Producer hangs forever — introspectors consume all batches and the program stops responding, no error](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#32-producer) — 16.5 🔇
- [MetaKey generic payloads are type-checker-only — a MetaKey[int] happily carries strings at runtime](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#43-metadata-keys) — 16.5
- [requested_responses=None requests every layer (~90 on MobileNet, full spatial activations) — always pass a list](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#51-dnikitbasemodel) — 16.5
- [ImageResizer size is (width, height), ignores aspect ratio, and asserts 4-D input](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#56-responseinfo-and-the-processors-you-will-actually-use) — 16.5
- [Consolidated: an infinite Producer hangs forever](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#10-consolidated-footguns) — 16.5

## General cautions

**Part 6**

- [TOC: the guide's collected silent failures — shrinking datasets, collapsed distributions, mismatched configs, orphan…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#contents) — 6.1
- [ScoreDimension text differs between production and calibration on purpose — 'same evaluator' means same type, not same…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#the-round-trip) — 6.1
- [Give the judge only a few alignment examples; a longer list overfits the alignment score and hides misalignment…](part-06-evaluations/references/01-foundations-and-hill-climbing.md#rule-4--three-iterations-and-what-each-one-taught) — 6.1
- [A broken evaluation still produces a number — the number you decided to trust; the catalogue below runs worst-first.](part-06-evaluations/references/01-foundations-and-hill-climbing.md#17-️-the-silent-failures) — 6.1
- [Overview: judge-alignment silent failures — unvalidated positional join, ?? 0 phantom ratings, undefined kappa read as…](part-06-evaluations/references/02-model-judges-and-alignment.md#what-this-covers) — 6.2
- [TOC: silent failures in judge alignment (section 19).](part-06-evaluations/references/02-model-judges-and-alignment.md#contents) — 6.2
- [numeric(_:) takes [Double: String]; Apple's sample writes integer literals that coerce — both work, dumps say Double.](part-06-evaluations/references/02-model-judges-and-alignment.md#5-scoringscale-numeric-passfail-custom) — 6.2
- [Section index: eight silent failures in judge alignment, from the positional join to inherited FM failure modes.](part-06-evaluations/references/02-model-judges-and-alignment.md#19-️-silent-failures-in-judge-alignment) — 6.2
- [Judge calls are model calls — guardrails, context, availability apply; 12% failed calls silently corrupt the…](part-06-evaluations/references/02-model-judges-and-alignment.md#198-️-judge-inferences-inherit-every-foundation-models-failure-mode) — 6.2
- [TOC: ToolCallEvaluator requires ModelSubject(value:transcript:); omitting the transcript throws missingTranscript…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#contents) — 6.3
- [Apple writes .exact values bare ('Paris, France') and wrapped (.string('r')); both compile via literal conformances.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#152-the-value-wrapping-footgun) — 6.3
- [ToolCallEvaluator needs ModelSubject(value:transcript:) — without the transcript no trajectory can be scored.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#17-️-wiring-it-up-toolcallevaluator-and-the-transcript-you-must-remember-to-pass) — 6.3
- [ModelSubject(value:) without transcript: still builds; ToolCallEvaluator throws missingTranscript — loud but…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#172-the-line-everyone-forgets) — 6.3
- [The 58%-to-100% tool-eval lift is Apple's 12-sample letter-counting demo — a framework demo, not an expected benchmark.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#174-what-tool-evaluation-buys-with-a-number) — 6.3
- [Only sample-attested call shapes are generated; the combined (ordered:unordered:disallowed:) init is real but…](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#183-converting-plans-into-samples) — 6.3
- [Two Apple samples are deliberately uncited: coffee-game and SpeechAnalyzer are unrefreshed iOS 26/WWDC25 leftovers.](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md#21-sources) — 6.3

**Part 16**

- [Read-first: two planning-level facts gate everything in this part — learn them before scoping work](part-16-adjacent-capabilities/README.md#️-two-things-to-learn-before-you-plan-anything) — 16.README
- [Marker definition: these do not throw — this guide catalogues five](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#evidence-markers-used-in-this-guide) — 16.5 🔇
- [Treat the six performance numbers as documentation claims, not citable measurements](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#the-one-workflow-where-the-answer-is-unambiguously-yes) — 16.5
- [All images must share H×W×C — mismatches raise DNIKitException; differing sizes need a custom Producer](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md#57-the-producers-and-sample-assets-apple-ships) — 16.5

---

🔇 = the guide marks this as an explicit **SILENT FAILURE** callout.
