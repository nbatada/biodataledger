# Changelog

## 0.19.1 — local development

- Add an Analysis log to the offline HTML viewer using recorded analysis
  chronology, exact input/output revisions and qualified timing evidence.
- Clarify canonical managed R-session reuse and one-process batch workflows,
  including the limits of aliases, independent handles and serialized sessions.
- Keep the existing registry schema and historical references unchanged.

## 0.19.0 — local development

- Batch R dependency-graph construction for ordinary and extended edges, so
  high-fanout adjacency buckets are sorted once while preserving graph output.
- Avoid R whole-state metadata validation and index reconstruction for ordinary
  DATA/ANA registration. Typed metadata tables and bindings retain full validation.
- Add versioned sample-to-analysis metadata tables in six categories, explicit
  key relationships, pinned dataset/analysis bindings, grouped metadata views
  and structural readiness checks. Retain managed table snapshots and historical
  references without loading scientific matrices or adding runtime dependencies.
  Metadata-enabled projects require clients supporting continuous metadata v1.
  Generated metadata uses `bl_`; original table columns and optional animal IDs
  remain unchanged, including records representing pooled samples.
- Include declared metadata-table key links and pinned DATA/ANA metadata bindings
  in the bounded extended provenance graph, retaining exact historical revisions
  without reading metadata payloads. The legacy `dependencies()` contract is unchanged.
- Fix R ZIP payload bindings when different source files share a filename,
  preserving each file's identity after archive-path sorting.


## 0.18.0 — source update, 2026-11-14

- Qualify the complete native test suite by installing its optional plotting
  dependencies in CI, while retaining a separate core-only Python boundary check.
  Plotting remains optional for ordinary package use.

- Add an optional R session helper with explicit process ownership, load-once
  retrieval, generation-checked replacement and deliberate release/recovery.
  Keep native data in the designated R process, separate from registry metadata.
  No automatic runtime connection, data serialization or global-object cleanup.

- Add an opt-in approved-renderer project policy. `render_figure` invokes native
  plotting internally, stages an output-bound rendering receipt and supports
  declarative composition. Guarded projects reject direct figure registration,
  copying and identity-changing corrections with actionable errors. Existing
  unguarded projects are unchanged; older clients reject guarded registries.
  The guard covers ordinary APIs, not unrestricted code or scientific validity.

- Add optional native plotting namespaces `bdl.pl` and `bdl_pl_*` for prepared
  PCA/UMAP coordinates, QC distributions, group comparisons, heatmaps, volcano
  and MA plots, with panel composition. Return editable Matplotlib/ggplot objects
  without running normalization, embeddings or statistical models. See the
  [plotting guide](docs/PLOTTING.md).

- Show oldest-first analysis input/output chains in `print(p)` and the new
  `timeline(view="analyses")` view in R and Python. Preserve exact intermediate
  data revisions, recorded names, UTC timestamps and qualified run timing.
  Reuse loaded metadata and bounded pages without payload reads or hashing.

- Add a private, [read-only browser snapshot](docs/VIEWER.md) in R and Python.
  Search loaded records, follow exact revisions, and optionally include
  digest-verified previews of selected figures.

## 0.17.0 — 2026-11-06

- Show a concise Python and R project overview with recent analysis registrations,
  exact linked outputs, current input selections, and the latest figure path.
  Keep the technical card available through `summary_text()`.
- Add `help()` for common inspection commands and `recent_figures()` for full
  figure paths and UTC registration order. Both use loaded metadata.
- Publish the complete R and Python [API reference](docs/API.md) and link to it
  from both help menus.

## 0.16.0 — 2026-11-06

- Add a presentation style for lineage DOT in R and Python, with optional
  colors for exact DATA roots and notes for recorded questions and plotting code.
- Add a synthetic lineage demo in R and Python that generates sample counts and
  a plot, then recovers the exact count table and plotting script in a fresh
  process. The retained figure traces to its recorded cohort revision, even
  after a newer revision becomes current for review.

## 0.15.0 — 2026-11-05

- Explain exact reference syntax when R receives an ID without a revision.
- Document how to find and verify inputs, stage an analysis before writing
  outputs, and retain the result with exact references in R and Python.
- Find retained data and figures by recorded topics, questions and slide or
  manuscript links. Derive filenames from exact revisions and optionally
  export a digest-verified copy in R or Python.

## 0.14.0 — 2026-11-05

- Add on-demand UTC timelines for record registrations and recorded runs in R
  and Python. Both views support oldest-first and newest-first pages. The run
  view preserves ties, overlaps and unknown order.

## 0.13.0 — 2026-11-05

- Export bounded exact-revision project graphs and focused lineage in native R
  and Python as DOT or structured data, with filters, pagination, evidence and
  explicit cutoffs. Graph queries require no payload I/O or Graphviz.

- Label inspection-card totals as data/artifact records and analysis records.
  Counts include registered outputs and template/run records; they do not count
  distinct biological datasets or independent analyses.

## 0.12.2 — maintenance release, 2026-11-04

- Show the loaded package version, registry revision and unsaved changes in project
  inspection cards; include `package_version` in compact status and the runtime
  version in R input-check cards. Inspection remains read-only.

- Reuse exact unchanged JSON fragments during repeated R saves in one loaded
  session. Every dirty save still validates the full state and preserves existing
  file verification, stale-write, locking and atomic publication safeguards.
  In a local synthetic 5,000-revision benchmark, repeated saves and execution
  receipts were about 2.9× faster; the first dirty save was about 19.5% slower.
  Reuse adds memory proportional to registry metadata; large-file hashing is unchanged.
  These timings do not establish performance on scientific workloads.
- Add safe upgrade instructions for existing projects and live R/Python sessions.
  No registry conversion, schema/API change or dependency upgrade is required.

## 0.12.1 — consolidated release, 2026-11-04

Includes the 0.10–0.12 development series: ordered protocols, evidence-qualified
execution history, fresh runner input checkpoints and bounded comparison evidence.
The existing native R/Python API, registry schemas and ZIP format are preserved.
Scientific acceptance and input consumption remain separate from software checks.

- Reject mixed scientific-decision/protocol metadata as scientific approval in
  both native clients; valid separate approvals of exact protocols are preserved.
- Refresh pinned installation instructions and package checks, and extend the
  synthetic native trials with context/working ZIP handoffs and explicit unknowns.

## 0.12.0 — development milestone, included in 0.12.1

- Add explicit comparison plan/assessment types, separate from scientific decisions
  and approvals, reusing DEC storage without schema migration.
- Retain exact original/candidate outputs, criteria and bound submitted evidence
  for reproduce, reapply and rerender; report scoped PASS/FAIL/UNKNOWN.
- Prevent mixed-type approval and record conversion, preserve prior assessments,
  and perform no new payload hashing, scientific execution or automatic reruns.


## 0.11.1 — development milestone, included in 0.12.1

- Align runner input eligibility with strict exact DATA resolution.
- Recheck files before callback and after callback/error; retain checkpoint evidence.
- Add optional R live-object verification using existing check_object and fresh getters.
- Preserve unknown consumption and legacy receipt compatibility; no sandbox claim.


## 0.11.0 — development milestone, included in 0.12.1

- Add bounded execution-history retrieval by project, exact analysis or protocol,
  reusing existing receipts without persisted format or registration changes.
- Keep run outcomes, registration timestamps and intended protocol order separate
  from pairwise timing evidence; preserve overlaps, ties and unknown intervals.
- Add compact native R/Python summaries, explicit paging/omissions and imported
  evidence qualifications. Queries do not load scientific data or write records.


## 0.10.0 — development milestone, included in 0.12.1

- Add versioned ordered protocols that pin existing analysis revisions, separate
  fixed parameters from data-dependent results, and declare required outputs.
- Reuse exact scientific decisions for declared protocol approval; revisions do
  not inherit approval. Prior protocol revisions remain unchanged.
- Compare selected execution receipts with intended steps and report differences,
  missing evidence and chronology limits without running or loading analyses.
- Preserve native R/Python, existing state/ZIP formats and dependency footprint.
  Metadata agreement does not establish scientific compliance or input consumption.


## 0.9.0 — consolidated release, 2026-11-03

First public release of the 0.6–0.9 development series. Includes the R live-object
verification prototype, native save-and-confirm, derived-result/embedding lineage,
explicit execution receipts, scientific decision/annotation records and bounded
exact-input/topic related-work lookup. Earlier 0.5.0 source updates remain included.
Registry schemas and ZIP format are unchanged; no mandatory LLM or new dependency.
Detailed development milestones follow.

- Add bounded native related_work reports for exact DATA revisions or literal
  analysis topic/purpose metadata, without a new index service or payload I/O.
- Return exact analysis/input/result/figure references, recorded provenance and
  qualified execution status; distinguish text candidates from exact input links.
- Preserve historical producer anchors, unknown evidence and explicit limits;
  no scientific-equivalence, approval or automatic reuse claim.

## 0.8.0 — development milestone, included in 0.9.0

- Add native scientific-decision recording/revision and exact decision retrieval,
  reusing DEC records and optional versioned metadata.
- Preserve exact cluster subjects, submitted labels and supporting/contradictory
  evidence; keep declared scientific status separate from record lifecycle.
- Retain generic decision corrections and legacy state/ZIP compatibility. Approval
  remains unauthenticated, and malformed/imported evidence remains qualified.

## 0.7.0 — development milestone, included in 0.9.0

- Add optional native `run_analysis`, exact `get_execution` and compact
  `execution_summary` for explicit execution of a registered code-snapshot function.
- Preserve started/terminal run revisions, exact template/input/output links,
  parameters/seed declarations and failures with explicit save confirmations.
- Keep checked file identity, observed invocation, declared parameters and unknown
  input consumption/scientific validity separate. Ordinary queries remain read-only.
- Existing schema versions, snapshots and ZIP format are unchanged. Old clients can
  preserve optional receipt metadata but do not validate or enforce its semantics.

## 0.6.0 — development milestone, included in 0.9.0

- Added equivalent native register_result, check_result and dependencies APIs. Result files are referenced by default; hashing/copying is explicit.
- Preserve exact artifact, producer, observation and rendering references. CSV checks report measured properties; native Seurat/AnnData selectors remain declarations with unknown unmeasured alignment.
- Added bounded in-memory dependency lookup and cross-language result tests. No new registry schema, database, workflow engine or mandatory scientific container.

## Lightweight agent workflow — included through 0.9.0

- Added native `save_and_confirm()` receipts for all pending changes, including previous/new committed revision, transaction ID and explicit persisted/no-changes status. Reuses existing atomic/stale-write safeguards; no autosave, schema change or scientific-approval claim.

- Added the R-only `check_object` prototype for read-only live membership, metadata, selected representation and cluster checks against existing registered references. Required FAIL/UNKNOWN returns BLOCKED; printed cards distinguish observations from declarations and unverified downstream use. Generic lists work without optional SeuratObject. No Python checker, execution engine or registry schema change.

- Figure search also matches registered paths and explicit scientific asset IDs.
- Compact figure reports expose asset IDs and optional `details.entry_point` function declarations without changing API signatures or the persisted schema.
- Added nested-status and native figure-discovery regressions and portable project-helper guidance.

- Native trial examples now resolve the selected input with explicit SHA-256 verification. Added migration guidance and regression coverage separating unchecked metadata from unavailable files; the core API and its metadata-only defaults are unchanged.

- Figure search includes the name/description of its exact recorded analysis. R now excludes inactive/superseded latest figures and returns inherited context/evidence like Python. Both clients retain metadata-only search and existing indexes.

- Analysis/figure details and compact summaries explicitly distinguish declared relationships from missing execution evidence. Historical records remain unchanged; file hashes, snapshots, imports and caller-supplied labels never establish observed execution. R registration defaults now match Python.

- Reduced R JSON parsing overhead while preserving decoded duplicate-key and malformed-input checks.
- Dirty saves compare the original validated registry bytes under the writer lock without reparsing unchanged metadata. Python validates the proposed state once before publishing snapshots or registry bytes.
- R reuses the indexes produced by full validation and uses ordinary copy-on-modify semantics for save candidates, avoiding a redundant index rebuild and deep copy without removing checks.
- Clarified loaded-session reuse, grouped fresh-process lookups, explicit input verification and meaningful saves. No mandatory per-turn operation, new API, dependency or persisted format.

## Figure-source extension — included through 0.9.0

- Separate explicit rendering DATA refs from exact analytical inputs; retain recorded parent/transformation evidence without inferring relationships.
- Extend figure getters with unambiguous ID/asset/path selectors and a <=4096-byte compact report, including missing files, declared code candidates, snapshots and explicit unverified integrity/execution.
- Add bounded `read_figure_source` access to verified snapshot bytes, including staged/imported sources and exact selection among multiple scripts. No original-file fallback when a snapshot was recorded.
- Reuse optional versioned details and existing code identities; package/schema remain 0.5.0/0.4.0. Old records/freeform details remain readable without migration. No recovery engine, new dependency or execution capture.

## 0.5.0 — Exact analysis context and preserved figure revisions

- Analyses and standalone figures accept exact `design_ref` and explicit separate/combined input modes. Known scope contradictions reject before staging; missing context stays unknown. Historical refs and project defaults remain distinct.
- Added targeted metadata-only `check_context`; legacy inconsistencies remain readable and can receive metadata corrections without rewriting their analytical context.
- Added `resolve_figure(..., verify="sha256")` using existing byte verification. Missing/changed external bytes do not imply recovery.
- Added `save_figure(source, ..., ref=...)` to copy an existing saved output into an exclusive managed revision. No plotting execution, DATA copies or overwriting; ordinary external registration remains available.
- Native R managed revisions reuse verified pending/existing code snapshots when the original standalone script is missing, including after import.
- Schema 0.4.0 stores input modes and preservation facts; schemas 0.1.0–0.3.0 remain readable. New features require both clients >=0.5.0. No new runtime dependencies.

## 0.4.0 — Exact input resolution and loaded lookup performance

- Use in-memory exact-reference indexes and explicit dirty tracking; clean saves avoid disk writes. Preserve atomic JSON and stale-writer checks.
- Make ordinary getters/status metadata-only. Availability is unknown until `check_files=True/TRUE`; strict `resolve_data(..., verify="sha256")` verifies a selected file explicitly.
- Add versioned DATA scope/design pins, explicit requirement comparisons and bound membership-evidence checks. New scope uses schema 0.3.0; old projects and ZIP format remain readable.
- Add confirmed existing-project intake guidance and native declared-file recovery examples. Recovery does not execute code or reconstruct environments.
- Enforce bounded JSON metadata in both clients. No database, automatic recorder or real-data migration.

## 0.3.0 — Experimental design

- Add ordered condition/levels, selected/reference levels, optional biological replicate and reason in both native clients.
- Preserve exact design revisions in analyses and figures; keep legacy projects readable without automatic migration.
- Add optional in-memory metadata checks and explicit declared/verified evidence with dataset/analysis context.
- Add compact project printing, actual inventory counts and bounded get_design_summary.
- Extend shared schema to 0.2.0 only when design is configured; older clients reject that extension. Legacy paths and ZIP format are unchanged.

## 0.2.0 — Native R and Python clients

- Independent Python `biodataledger` and R `BioDataLedger` packages; retained ProjectBundle facade.
- Preserved schema 0.1.0, legacy state/snapshot paths and ZIP marker without rewriting scientific records.
- Added bounded read-only compact status for scientists and optional agents.
- Added installed-package examples and cross-language regression tests.
- Compact status checks pinned current inputs before latest versions; R ZIP import rejects incomplete safety metadata and requires zip ≥3.0.2. Regression checks pass.
