# Comparison evidence — version 1

Local development 0.12.0 adds three native ProjectBundle methods. These record and
inspect submitted comparison evidence. They never execute an analysis/comparator,
load an artifact or hash a file. BioAnalysisExecutor is not a dependency.

| API | Purpose |
| --- | --- |
| `register_comparison_plan(name, mode, original, intended, criteria, reason, ref=None)` | Create or revise intended comparison criteria. |
| `record_comparison_assessment(plan_ref, candidate, observations, reason, ref=None)` | Record observed comparisons for one exact plan and candidate. |
| `get_comparison(ref, scientific_acceptance_ref=None)` | Retrieve the typed descriptor, context checks and effective verdict. |

R uses `$`, `NULL`, `TRUE` and lists with the same field names and meanings. Save
staged records explicitly with `save_and_confirm()` before another client opens them.

## Types and revisions

Plans and assessments reuse DEC storage with mutually exclusive, versioned
`comparison_plan` and `comparison_assessment` descriptors. Both descriptors and
reports expose `record_type`. They are **not scientific decisions or approvals**:
`get_comparison` and `get_decision` return `scientific=null` and
`approval="not_applicable"` for comparison records. Mixed-type records are invalid;
scientific approval readers never accept a comparison-bearing record.

Dedicated writers append revisions from the latest exact revision. Generic updates,
metadata injection and conversion to/from scientific decisions or protocols reject.
Assessment revisions preserve the exact plan and candidate bindings: a different
run/output or plan requires a new assessment ID. Earlier FAIL and UNKNOWN records
remain retrievable. A plan revision does not rewrite existing assessments.

No schema or ZIP migration is introduced. Older clients preserve optional metadata
but cannot enforce these new API guards. Raw files remain externally mutable and
metadata cannot authenticate an author or the truth of submitted evidence.

## Plan fields

`mode` is `reproduce`, `reapply` or `rerender`. This bounded slice compares one
original analysis with one candidate analysis and up to 20 ordered output slots.
It does not orchestrate or assess an entire multi-step protocol.

`original` and assessment `candidate` have:

```python
{"analysis_ref": exact_analysis_ref,
 "outputs": [{"slot_id": "result", "ref": exact_data_or_figure_ref}]}
```

Use exact terminal run refs when recorded execution evidence exists. Distinct run
IDs and distinct output revisions are required; comparing an output to itself is
not evidence of rerunning it. Result producer links must match the run's started
revision, or the declared analysis when no receipt is available. Absent execution
remains UNKNOWN, and failed execution cannot satisfy the context checks.

`intended` requires `input_refs` (ordered exact DATA refs) and `retrospective` (boolean).
Do not claim prospective criteria from timestamps alone. Optional fields normalize
to null or empty containers:

- `protocol_ref`, `approval_ref`, `source_protocol_ref`, `source_approval_ref`.
- `input_mapping`: ordered `{index, from, to}` entries, zero-based indices.
- `visual_changes`: named intended rendering parameter values.
- `environment_ref`: exact declared environment record. Current receipts do not
  verify environments; requiring this pin leaves environment verification UNKNOWN.

For **reproduce**, original and candidate input refs, method, code and fixed
parameters must match. Required output criteria still need independent comparison
evidence. The report does not infer reproduction from those metadata checks.

For **reapply**, map every ordered original input to the intended new input, including
identity mappings for retained inputs. No unaccounted additions/deletions/splits/merges
are inferred. Pin the source and new single-step protocols, and separate approved
scientific DEC refs whose subjects are those exact protocol revisions. Candidate and
original receipt templates must match the corresponding protocol step. Old approval
does not approve the new input binding. Missing approval or protocol evidence stays
UNKNOWN. Fixed method/code/settings must match; protocol-marked data-dependent values
are excluded from fixed-value equality, but missing values remain UNKNOWN.

For **rerender**, inputs and retained analytical result revisions must stay identical.
Each old/new FIG must declare the same exact `figure_sources.rendering_inputs`.
The original and candidate analyses describe the render operation, with visual
settings in `params`; `visual_changes` names the intended parameter updates. Render
code may change, while the method and other parameters stay fixed. Analytical
recomputation or a new result identity cannot silently count as rerender.

## Explicit criteria

Each of 1–20 criteria has `criterion_id`, `required`, `domain`, `slots`,
`comparison_kind`, `requirement` and exact `comparator_ref`. Domains are identity,
method, output or visual. At least one required output/visual criterion is mandatory.

| Kind | Required requirement fields |
| --- | --- |
| `manual` | `rubric`, `scope` |
| `numeric` | `metric`, `units`, `operator`, finite numeric `threshold`, `alignment`, `aggregation`, `missing`, `nonfinite`, `exclusions` |
| `bytes` | `algorithm` |
| `structural` | `keys`, `order`, `duplicates` |

Numeric operators are `<`, `<=`, `==`, `>=`, `>`. There are no default tolerances.
These requirements describe an external comparison; the package does not evaluate
scientific metrics or user expressions, and cannot verify that a comparator followed
the rubric or threshold. It preserves submitted observations and their provenance.

## Assessment and evidence binding

Each observation has `criterion_id`, `verdict` (PASS/FAIL/UNKNOWN), `observed`,
`reason`, `evidence` (exact refs), `subjects` and `comparator_ref`. Optional
`contradictory_evidence` defaults to an empty list of exact references;
`independent_review_ref` defaults to null. Conflicting submitted evidence makes
that criterion effectively UNKNOWN while retaining its claimed verdict and all
references. The package does not read report text to discover unstated conflicts.

`subjects` must list all criterion-selected original outputs followed by corresponding
candidate outputs, in slot order. `comparator_ref` must equal the plan criterion's
reference. Missing/blank observations, missing evidence or wrong bindings produce
effective UNKNOWN while preserving the submitted verdict. Evidence must also bind:

- **Native comparator ANA:** its ordered inputs equal the selected subjects, and a
  referenced result DATA's producer is that comparator/run's started revision.
- **Manual review DEC:** the criterion comparator and evidence ref identify that
  review; its `details.targets` equal the selected subjects. This may be an existing
  generic decision retaining a rubric-based review, without implying approval.
- **External comparator DATA:** a retained method/version description is registered
  as the comparator. Referenced evidence DATA details declare `comparison_subjects`
  and `comparison_comparator_ref` equal to these bindings. This is explicitly submitted
  external provenance, not an authenticated execution observation.

Bare reviewer names and unrelated evidence refs do not support PASS. No payload is
read to check a report's contents; correctness of the external observation remains
with its producer and scientific reviewer. Evidence references can be retrieved with
existing exact getters. Actual consumption and scientific validity remain unknown.

## Verdicts and limits

The report exposes four distinct sections:

- `context` and `metadata_consistency`: checks of recorded bindings and method intent.
- `criteria`: submitted observations/verdicts versus effective verdicts and gaps.
- `independent_support`: separately supplied review refs and their binding status.
  A separate generic review DEC must target the same exact outputs and differ from
  the comparator and comparison evidence refs. `review_recorded` only means that
  a bound review was supplied: independence is `not_authenticated` and empirical
  verification remains `UNKNOWN`. It never implies that BioDataLedger independently
  checked the comparison or that two records came from different people.
- `scientific_acceptance`: absent unless an exact separate scientific-decision ref
  is explicitly supplied to the getter. Its subject must equal this exact comparison
  revision. Valid declared approval appears as `recorded_approved`; imports, wrong
  subjects and comparison records used as acceptance yield UNKNOWN. This neither
  changes the comparison verdict nor converts comparison evidence into approval.

`verdict_qualification` labels the aggregate as `submitted_evidence_only`, or
`conflicting_evidence` when applicable. No report returns an unqualified scientific
PASS or independently verified conclusion. A required supported FAIL or context conflict yields
FAIL; otherwise missing required evidence/context yields UNKNOWN; otherwise PASS.
Optional criteria remain visible but do not alter the aggregate. Imported evidence
never produces an unqualified PASS; submitted verdicts are retained with an unknown
trust qualification. A plan alone has no result and reports UNKNOWN.

PASS means **submitted evidence satisfies the specified contract**. It is not approval,
a scientific-reproducibility certificate or proof of input/parameter consumption.
Historical digest comparisons concern those recorded observations; no current-file
integrity claim or fresh 0.11.1 checkpoint is manufactured. Existing P0 file/object
checks remain unchanged. No additional default hashing pass is introduced.

Descriptors/reports are capped at 64 KiB, with at most 20 criteria/output slots,
10 evidence refs per observation and 100 distinct references in each bounded
metadata value. Oversized metadata rejects rather than silently dropping criteria.
No new database, persistent index, runner, automatic rerun or executor integration.
