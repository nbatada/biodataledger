# Changelog

## 0.8.0 — local, unpublished

- Add native scientific-decision recording/revision and exact decision retrieval,
  reusing DEC records and optional versioned metadata.
- Preserve exact cluster subjects, submitted labels and supporting/contradictory
  evidence; keep declared scientific status separate from record lifecycle.
- Retain generic decision corrections and legacy state/ZIP compatibility. Approval
  remains unauthenticated, and malformed/imported evidence remains qualified.

## 0.7.0 — local, unpublished

- Add optional native `run_analysis`, exact `get_execution` and compact
  `execution_summary` for explicit execution of a registered code-snapshot function.
- Preserve started/terminal run revisions, exact template/input/output links,
  parameters/seed declarations and failures with explicit save confirmations.
- Keep checked file identity, observed invocation, declared parameters and unknown
  input consumption/scientific validity separate. Ordinary queries remain read-only.
- Existing schema versions, snapshots and ZIP format are unchanged. Old clients can
  preserve optional receipt metadata but do not validate or enforce its semantics.

## 0.6.0 — local, unpublished

- Added equivalent native register_result, check_result and dependencies APIs. Result files are referenced by default; hashing/copying is explicit.
- Preserve exact artifact, producer, observation and rendering references. CSV checks report measured properties; native Seurat/AnnData selectors remain declarations with unknown unmeasured alignment.
- Added bounded in-memory dependency lookup and cross-language result tests. No new registry schema, database, workflow engine or mandatory scientific container.

## Unreleased — Lightweight agent workflow

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

## Local figure-source extension — BIODATALEDGER-008

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
