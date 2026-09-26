# Section maps for the deep reference guides

The deep guides are bundled with this skill. Each entry links the local file, then lists every **top-level** (`##`) section as an anchor; a guide's own `## Contents` lists its subsections. Open the narrowest relevant section first.

> Generated 2026-09-22 from the guide headings. Regenerate with `./scripts/build-skills.sh` rather than editing by hand.

## Part 6 — Evaluations

### 6.1 — Building blocks, Swift Testing integration, and evaluation-driven development

The foundation everything else hangs on: the `Evaluation` protocol's five steps (`subject(from:)` → `dataset` → `evaluators` + `Metric` → `aggregateMetrics(using:)` → a Swift Testing `@Test`), each with the corrected spelling verified against Apple's Book Tracker sample rather than reconstructed from spoken narration.

**Local reference:** [part-06-evaluations/references/01-foundations-and-hill-climbing.md](part-06-evaluations/references/01-foundations-and-hill-climbing.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The contract that generative features break | `#1-the-contract-that-generative-features-break` |
| 2. Evaluations is not an LLM framework | `#2-evaluations-is-not-an-llm-framework` |
| 3. The five steps, and the four components | `#3-the-five-steps-and-the-four-components` |
| 4. Step 1 — `subject(from:)`, the code under measurement | `#4-step-1--subjectfrom-the-code-under-measurement` |
| 5. Step 2 — the dataset: `ModelSample` and the loaders | `#5-step-2--the-dataset-modelsample-and-the-loaders` |
| 6. Step 3 — evaluators and metrics | `#6-step-3--evaluators-and-metrics` |
| 7. Step 4 — `aggregateMetrics(using:)` | `#7-step-4--aggregatemetricsusing` |
| 8. Step 5 — the test that runs it | `#8-step-5--the-test-that-runs-it` |
| 9. The whole thing, in one file | `#9-the-whole-thing-in-one-file` |
| 10. The quantitative / qualitative rule of thumb | `#10-the-quantitative--qualitative-rule-of-thumb` |
| 11. The Xcode 27 Evaluations report | `#11-the-xcode-27-evaluations-report` |
| 12. The attachment, and the meta-evaluation it unlocks | `#12-the-attachment-and-the-meta-evaluation-it-unlocks` |
| 13. Hill climbing: the loop, and why it needs science | `#13-hill-climbing-the-loop-and-why-it-needs-science` |
| 14. Control, experimental, one variable, backport | `#14-control-experimental-one-variable-backport` |
| 15. Hill-climbing something that is not a prompt | `#15-hill-climbing-something-that-is-not-a-prompt` |
| 16. Everything you can turn | `#16-everything-you-can-turn` |
| 17. ⚠️ The silent failures | `#17-️-the-silent-failures` |
| 18. Why this framework exists: there is no model version pinning | `#18-why-this-framework-exists-there-is-no-model-version-pinning` |
| 19. Quick reference | `#19-quick-reference` |
| 20. Sources, and where they disagree | `#20-sources-and-where-they-disagree` |

### 6.2 — Model judges, score dimensions, drift, and Cohen's kappa

The half of evaluation that cannot be written as an `if`, and then the harder half: proving the thing doing the judging deserves to be trusted.

**Local reference:** [part-06-evaluations/references/02-model-judges-and-alignment.md](part-06-evaluations/references/02-model-judges-and-alignment.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. When a metric has to be qualitative | `#1-when-a-metric-has-to-be-qualitative` |
| 2. A judge is just another `Evaluator` | `#2-a-judge-is-just-another-evaluator` |
| 3. Choosing the judge model | `#3-choosing-the-judge-model` |
| 4. The four parts of a judge, and the one you write | `#4-the-four-parts-of-a-judge-and-the-one-you-write` |
| 5. `ScoringScale`: numeric, pass/fail, custom | `#5-scoringscale-numeric-passfail-custom` |
| 6. `ScoreDimension`: name, description, scale | `#6-scoredimension-name-description-scale` |
| 7. The key technique: split the question | `#7-the-key-technique-split-the-question` |
| 8. `ModelJudgePrompt` | `#8-modeljudgeprompt` |
| 9. Rationales are the debugging loop | `#9-rationales-are-the-debugging-loop` |
| 10. Pairwise judging | `#10-pairwise-judging` |
| 11. Mixing judges and code evaluators | `#11-mixing-judges-and-code-evaluators` |
| 12. Drift | `#12-drift` |
| 13. Why accuracy is the wrong alignment measure | `#13-why-accuracy-is-the-wrong-alignment-measure` |
| 14. Cohen's kappa | `#14-cohens-kappa` |
| 15. Implementing kappa — the framework does not ship it | `#15-implementing-kappa--the-framework-does-not-ship-it` |
| 16. The meta-evaluation, end to end | `#16-the-meta-evaluation-end-to-end` |
| 17. Hill-climbing the judge: four iterations | `#17-hill-climbing-the-judge-four-iterations` |
| 18. Overfitting the alignment score | `#18-overfitting-the-alignment-score` |
| 19. ⚠️ Silent failures in judge alignment | `#19-️-silent-failures-in-judge-alignment` |
| 20. What is still unknown | `#20-what-is-still-unknown` |
| 21. Quick reference | `#21-quick-reference` |
| 22. Sources | `#22-sources` |

### 6.3 — `SampleGenerator`, synthetic datasets, and evaluating tool trajectories

Two subjects that share a chapter because both are about honesty.

**Local reference:** [part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md](part-06-evaluations/references/03-synthetic-data-and-tool-trajectories.md)

| Section | Anchor |
|---|---|
| What this covers | `#what-this-covers` |
| What you need | `#what-you-need` |
| Contents | `#contents` |
| 1. The thirteen-sample lie | `#1-the-thirteen-sample-lie` |
| 2. Two doors into synthetic data | `#2-two-doors-into-synthetic-data` |
| 3. ⚠️ `targetCount` counts the samples you already have | `#3-️-targetcount-counts-the-samples-you-already-have` |
| 4. `SampleGenerator`, parameter by parameter | `#4-samplegenerator-parameter-by-parameter` |
| 5. ⚠️ `sessionProvider` is a factory and it may be called twice | `#5-️-sessionprovider-is-a-factory-and-it-may-be-called-twice` |
| 6. Paying for generation: entitlement, quota, and why it lives in a CLI target | `#6-paying-for-generation-entitlement-quota-and-why-it-lives-in-a-cli-target` |
| 7. `samplingStrategy`: random or sliding window | `#7-samplingstrategy-random-or-sliding-window` |
| 8. ⚠️ The validator runs alone | `#8-️-the-validator-runs-alone` |
| 9. Where the samples go: `samples`, `invalidSamples`, JSON, `JSONLoader` | `#9-where-the-samples-go-samples-invalidsamples-json-jsonloader` |
| 10. The reality check: expansion makes your scores drop | `#10-the-reality-check-expansion-makes-your-scores-drop` |
| 11. Coverage beats count | `#11-coverage-beats-count` |
| 12. Why the final answer is not enough | `#12-why-the-final-answer-is-not-enough` |
| 13. `TrajectoryExpectation`: four shapes | `#13-trajectoryexpectation-four-shapes` |
| 14. `ToolExpectation`, `anyOrder`, and additional calls | `#14-toolexpectation-anyorder-and-additional-calls` |
| 15. The nine argument matchers | `#15-the-nine-argument-matchers` |
| 16. `disallowed`: evaluating what the model must *not* do | `#16-disallowed-evaluating-what-the-model-must-not-do` |
| 17. ⚠️ Wiring it up: `ToolCallEvaluator` and the transcript you must remember to pass | `#17-️-wiring-it-up-toolcallevaluator-and-the-transcript-you-must-remember-to-pass` |
| 18. Synthesising tool-evaluation datasets | `#18-synthesising-tool-evaluation-datasets` |
| 19. One suite, two kinds of confidence | `#19-one-suite-two-kinds-of-confidence` |
| 20. Quick reference | `#20-quick-reference` |
| 21. Sources | `#21-sources` |

## Part 16 — Adjacent capabilities

### 16.5 — DNIKit: auditing datasets and networks before you convert

The shortest guide in the series, on purpose.

**Local reference:** [part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md](part-16-adjacent-capabilities/references/05-dnikit-dataset-and-model-introspection.md)

| Section | Anchor |
|---|---|
| This is the shortest guide in the series, on purpose | `#this-is-the-shortest-guide-in-the-series-on-purpose` |
| What this covers | `#what-this-covers` |
| What this does *not* cover | `#what-this-does-not-cover` |
| What you need | `#what-you-need` |
| Evidence markers used in this guide | `#evidence-markers-used-in-this-guide` |
| Contents | `#contents` |
| 1. Should you read this at all | `#1-should-you-read-this-at-all` |
| 2. Install, versions, and the environment that actually works | `#2-install-versions-and-the-environment-that-actually-works` |
| 3. Producer, PipelineStage, Introspector | `#3-producer-pipelinestage-introspector` |
| 4. `Batch`: the universal container | `#4-batch-the-universal-container` |
| 5. `Model` and the framework backends | `#5-model-and-the-framework-backends` |
| 6. The introspectors | `#6-the-introspectors` |
| 7. One complete worked example | `#7-one-complete-worked-example` |
| 8. The pre-flight workflow for Parts 8–10 | `#8-the-pre-flight-workflow-for-parts-810` |
| 9. What is explicitly not here | `#9-what-is-explicitly-not-here` |
| 10. Consolidated footguns | `#10-consolidated-footguns` |
| 11. Declared gaps | `#11-declared-gaps` |
| 12. Sources | `#12-sources` |
