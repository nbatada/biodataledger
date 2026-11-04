# BioDataLedger API 0.7.0

Native Python `biodataledger` and R `BioDataLedger` expose `ProjectBundle`. R uses `$`, `NULL`, `TRUE` and lists. Registration records declarations. Optional `run_analysis` executes one explicitly selected snapshotted native function and records scoped observations; it does not authenticate approval or validate biological conclusions. Mutation must use the public methods; direct edits to internal state are unsupported.

## Open once, inspect cheaply, verify explicitly

`ProjectBundle.create(name, project_dir, purpose=None, raw_dir=None, metadata=None)` creates a registry in an existing root and refuses overwrite. `open(project_dir)` loads and validates it once. Loaded exact lookups use hash indexes; indexes are not persisted. A loaded object does not automatically refresh when another writer saves.

| Operation | Contract |
| --- | --- |
| `get_data(ref=None, role=None, purpose=None, check_files=False)` | Exactly one selector. Exact refs include project UUID, record ID and revision; `DATA-001@2` is local shorthand. Purpose uses its exact current pointer. A missing or ambiguous role rejects. Returns detached path/ref/scope/design metadata. |
| `get_analysis(ref)` / `get_figure(ref, check_files=False)` | Retrieve exact historical records. Figures inherit inputs, input mode, code, method, parameters and design from their linked analysis. `get_figure` exposes unknown fields, source paths and separate declared/file/execution provenance. |
| `find_figures(query=None, type=None)` | Search latest active figure names/types/descriptions and the name/description of each linked exact analysis revision. All whitespace-separated query tokens must match as literal, caseless substrings; type filtering is exact. Returns the same inherited context/evidence as `get_figure`, in stable ID order (R retains named lists). Search uses loaded latest/exact indexes and performs no payload reads or hashing. |
| `status(compact=True, purpose=None, check_files=False)` | Bounded metadata, counts, current refs, next task and dirty state. A named purpose adds the selected dataset's compact scope and pinned design. Missing purpose stays visible as no selected dataset. No registry dump or default file inventory. |
| `summary()` / `summary_text(purpose=None)` | Summary values or readable project/purpose context. No matrix loading or implicit hashing. |
| `resolve_data(ref=None, purpose=None, verify=..., expected_scope=None, require_membership=False)` | Explicit strict verification; supply exactly one selector and `verify="sha256"`. Streams the selected file only, requires a captured digest, active record and usable file, and rejects size/digest/scope contradictions. Returns a verified path or raises; never substitutes a different dataset. |
| `check(hashes=False)` | Explicit registry-wide file audit. Hashing is opt-in and can be expensive. |

**0.4 availability change:** ordinary getters return `available=None`/`NULL` and `availability_checked=False`/`FALSE`. This means not checked, not missing. Use `check_files=True`/`TRUE` for existence checks, or `resolve_data(..., verify="sha256")` before using a selected input. Dependent availability is likewise unknown by default. Status reports zero files checked and unknown unchecked/missing totals until explicitly requested. `check_files=True` checks at most 100 distinct relevant locators and reports remaining counts; it does not hash.

Compact status is capped at 4096 UTF-8 bytes, with explicit omissions/truncation. Exact references are not shortened into different IDs. A byte cap is not a model-independent token guarantee. The ordinary summary aims to stay below 500 estimated tokens; full details are requested separately.

### Updating older input helpers

An older helper that treats `availability_checked=False` or unchecked
`available=None`/`NULL` as a missing file will reject valid inputs. Replace its input
retrieval with strict resolution; keep its signature and return mapping:

```r
data <- project$resolve_data(ref = data_ref, verify = "sha256")
```

```python
data = project.resolve_data(ref=data_ref, verify="sha256")
```

`data_ref` must remain the same exact registered reference. For an existing
current-for-purpose selector, use `purpose` instead of `ref`. Successful resolution
returns the existing metadata fields, including `path`, `ref` and `sha256`, plus
`verification`, with `available` and `availability_checked` true. Remove the old
unchecked-availability rejection; preserve other helper behavior. Let resolution
errors stop the caller instead of choosing another dataset.

For role-based helpers, first inspect the unambiguous role with `get_data(role=...)`,
then pass the returned exact `ref` to `resolve_data`. The resolver does not accept
a role selector. `get_data(check_files=True)` checks existence only and cannot
replace the digest check: a changed file may still exist.

Resolution streams the selected file's bytes; it does not deserialize RDS, Seurat
or H5AD objects, change selections, update hashes or save the registry. A missing
digest is an error, not permission to create a new baseline automatically.
Establish that baseline separately through authorized registration/revision.
Keep ordinary metadata inspection cheap; verify only when the input will be used.

## Retain data, analyses and figures

- `register_data(path, role, name=None, hash=False, **details)` records an existing file/URI. Hashing large local files is an explicit opt-in. Known parent/membership links use exact DATA refs in details; clustering_run uses an ANA ref.
- `register_analysis(name, inputs, code=None, method=None, params=None, snapshot_code=True, design_ref=<project default>, input_mode="separate", **details)` pins exact DATA refs and the resolved design once. Pass an exact design ref to override the default or explicit null for unknown design. `input_mode="combined"` declares joint comparison scope without pooling files. New records reject known scope contradictions; missing context stays unknown. Inputs/method/parameters may be explicitly unknown.
- `register_figure(path, type, analysis=None, name=None, inputs=None, code=None, method=None, params=None, snapshot_code=True, design_ref=<project default>, input_mode="separate", figure_sources=None, **details)` records an existing figure and its digest. Standalone figures resolve/pin their design and check declared scope like analyses. With an analysis ref, all explicit design/input-mode/inputs/code/method/params overrides reject; the figure inherits that exact context. One analysis can supply shared provenance to several figures.
- Supplied code files are snapshotted by default, with a 1 MiB per-file limit and explicit opt-out. Snapshots preserve bytes; they do not prove execution or discover imports. Native figure/data saving remains outside the library.
- `save()` commits meaningful staged changes as one atomic JSON snapshot. Clean save returns without disk writes. Dirty save checks the loaded digest/revision under the existing lock; a stale writer fails and retains pending edits. Do not automatically merge or steal locks.
- `update_record(ref, changes, reason)` appends a correction, preserving earlier revisions and current pointers. DATA scope/design changes use `set_data_scope`; project design changes use `set_design`. Analysis/standalone-figure design and input-mode corrections use `design_ref`/`input_mode` in `changes` and recheck declared consistency. Clear a recorded membership-verification claim through the scope setter before changing its bound file/details.
- `set_current(ref, purpose, reason)` records an explicit scientist-selected active DATA revision. It never rewrites historical analysis inputs. External scientific authority blocks a competing local current choice.
- `record_decision(text, reason, targets)`, `set_context(changes)` and `rebind_external(ref, path, reason)` retain their explicit declaration/rebinding roles. Rebinding checks known hashes. `get_raw_dir`, `get_metadata_path`, and `get_output_dir(kind)` retrieve locations without creating analysis directories.

## Declared relationships and execution evidence

Analysis and figure detail views add a detached `evidence` object:

```json
{"input_relationships":"declared","code_relationships":"declared","execution":"unknown","execution_evidence":"not_captured","missing":["execution_evidence"]}
```

This example has all declared fields present. Missing inputs, method, parameters
or code are listed individually. Unknown analytical provenance is also explicit.
Figure `unknown` uses the same missing-information list. Linked figures use their
exact analysis revision; corrections do not reinterpret earlier figures.

Ordinary registration does not observe analysis execution. Code snapshots and recorded or
verified file digests establish file facts, not execution of the declared code on
the declared inputs. Strict integrity checks and imports never promote execution
status. Arbitrary `details` fields, including claims named `execution_evidence`,
are not a supported captured-execution contract.

Existing records are not rewritten or upgraded. Unsupported legacy provenance
labels remain in raw `details`; derived provenance reports treat them as unknown.
New R registrations use the same declared/unknown defaults as Python, regardless
of caller-supplied provenance labels. Existing `provenance` keys remain available.

`status()` and `summary()` include a small constant `evidence` object containing
`execution`, `execution_evidence` and the missing execution-evidence marker.
This describes ordinary registration; it is not a scan of every
record's completeness or of external execution logs. Query an exact detail view
for record-specific missing fields. Ordinary evidence queries load no payloads,
perform no hashing or writes, and retain the compact status byte cap. Explicit
run observations use `get_execution` separately; producer links do not prove input
consumption. There is no automatic session recorder or new schema/dependency.

## Experimental design and saved-object scope

`set_design(condition, levels, selected_levels=None, reference_level=None, replicate=None, selection_reason=None, metadata=None, context=...)` records a versioned DES declaration. The condition and ordered levels are required. Selected levels default to all levels; an explicit selection must be a nonempty unique subset. Optional in-memory metadata checks validate supplied labels, not biological independence. Nothing subsets a scientific object.

Use `get_design(ref=None)`, `get_condition`, `get_levels`, `get_selected_levels`, `get_reference_level`, `get_replicate`, `get_design_summary` and `check_design_metadata` to inspect it. Analysis/figure design pins stay historical when the global design changes.

`set_data_scope(ref, scope, reason, design_ref=None)` returns a **new DATA revision**. It never selects that revision current, changes the source file or guesses a design pin. Null means unrecorded design. Scope fields are optional and normalize to unknown/null:

| Scope field | Value |
| --- | --- |
| observation_unit, selection, assay, layer | Nonblank text or null. Selection text is never executed. |
| condition_values, assignment_inclusion | Nonempty unique string array or null. These describe the saved object, not the intended comparison. |
| sample_manifest_ref, transformation_ref | Exact DATA and ANA refs respectively, or null. |
| evidence | `{basis: "declared" | "inferred" | "unknown", source_refs: [...]}`; source refs are DATA/ANA/DEC. |
| membership_evidence | `{status: "unknown" | "declared" | "inferred" | "verification_recorded", report_ref: ...}`. Only verification_recorded has a non-null exact DATA report ref. |

Existing details.parent and details.membership remain the authoritative parent and observation-membership refs. Large membership lists stay in files. Legacy arbitrary details, including a key called scope, are not silently converted.

Strict resolution compares any explicitly supplied expected_scope fields: condition_values, assignment_inclusion, observation_unit, assay and layer. Missing required values raise SCOPE_UNKNOWN; differences raise SCOPE_CONFLICT. Arrays compare as sets after duplicate rejection. Known saved condition values must fit the pinned design and include its selected levels; broader inputs containing other available levels are permitted and displayed. No automatic filtering occurs.

## Recorded membership evidence

A small hash-pinned DATA JSON report uses version `biodataledger-membership-check/1` and these required keys: subject_sha256, membership_ref, membership_sha256, key_columns, key_namespace, comparison (`ordered_keys` or `set_keys`), result (`match`, `mismatch`, `incomplete`), checked_at (UTC), checker (`method`, `origin`: native_check/manual_check, `analysis_ref` or null), and counts (`subject_rows`, `membership_rows`, `subject_duplicate_keys`, `membership_duplicate_keys`, `missing_keys`, `extra_keys`). Counts are nonnegative exact JSON-safe integers. A match requires equal rows and zero duplicates/missing/extra keys. Equal row counts alone do not verify membership.

Optional observed_scope contains only explicitly checked canonical scope fields. A recorded report must bind to the subject's baseline digest and exact membership artifact/ref/digest. The setter checks the report, not the large subject or membership bytes. Explicit `require_membership=True` resolution rechecks the subject, report and membership file and rejects stale/missing/contradictory evidence. Without it, the result says recorded verification was not rechecked. Only reported matching fields are marked verified against recorded evidence; other fields keep their original basis.

Report production/native object inspection is outside the core. The package checks report consistency, not honesty or biological validity. A self-consistent false declaration cannot be detected without independent evidence.

## Sharing, intake and recovery

`preview_export(mode, include=...)` enumerates files, all registry metadata/history and omissions; `export_zip(plan, path)` exports that reviewed state; `ProjectBundle.import_zip(path, project_dir)` validates and imports without executing code. Context ZIPs contain metadata. Working ZIPs add explicitly selected files and code snapshots; selecting a figure does not recursively include all scientific inputs or imports. Review metadata privacy before sharing.

The repository guide `docs/ADOPTION.md` uses a finite confirmed file list and preserves the existing directory tree. `docs/RECOVERY.md` documents an explicit declared-file manifest and native example helpers that restore relative layout into a new destination. Recovery preserves the imported ledger/bindings and exposes entrypoint/cwd/runtime hints. It does not run code, install environments, discover dependencies or guarantee reproduction.

Legacy state/snapshot paths and ZIP `nb-project-bundle-zip/0.1` remain unchanged. Schemas 0.1.0–0.3.0 open without migration. DATA scope/design first enabled schema 0.3.0 (clients >=0.4.0). New analysis/figure registration or managed saving enables schema 0.4.0 (clients >=0.5.0). These older clients reject newer schemas rather than drop fields. No operation downgrades an existing schema.

The 20 MiB limit applies to registry JSON and archive manifest JSON individually, not total payload size. Existing 10,000 archive-entry, 100 GiB expanded-size and 1000:1 ratio limits remain. Oversized metadata refuses before publication and retains staged edits. No 100,000-record capacity claim, other-platform/network-volume write qualification, scientific acceptance or automatic reproduction follows from these APIs.

## Exact designs and saved figure copies — 0.5.0

`register_analysis(..., design_ref=..., input_mode="separate")` and standalone
`register_figure` accept an exact design reference. Omission pins the project
default once; explicit null records unknown design. A linked figure inherits its
exact analysis context. `input_mode="separate"` checks each input against selected
levels. Explicit `"combined"` checks their declared union for a comparison; it does
not pool or merge files. A DATA design pin supplies its condition identity. Missing design pins or
condition values remain uncertain.

`check_context(ref)` inspects only the named analysis, DATA or figure context.
It reports consistent, unknown or inconsistent declarations. It reads no payload
and does not establish filtering, biological correctness or scientific approval.
Legacy inconsistencies remain readable. Missing input mode on a legacy multi-input
record remains unknown. Metadata-only corrections preserve that context;
changes to inputs/design/mode or analysis linkage reject known contradictions. Available levels may exceed the design's selected subset.

`resolve_figure(ref, verify="sha256")` uses the existing targeted integrity check
before returning a usable path. Ordinary getters remain metadata-only. A missing
or changed external file has **no preserved copy recorded** for that exact revision. Its original digest
and historical record remain unchanged.

`save_figure(source, type=None, ref=None, ...registration context...)` copies an
explicit existing saved native figure into a new package-managed revision. It
does not execute plotting code or serialize objects. With no ref it creates a
figure identity; with an exact figure ref it appends that identity's revision,
retaining its exact analytical context. Revise that context separately through
`update_record` before copying a changed output. Every copy has an exclusively
created destination under `.nb_project_bundle/outputs/`; no existing bytes are
overwritten, including after concurrent calls. Failed copying/registration never
stages a trusted record. Successful calls return an exact figure ref; use
`get_figure(ref).path` (R: `$path`) for its path, then `save()` for registry
persistence. A failed/stale registry save leaves the completed copy and staged
edits for inspection; it never replaces another writer's bytes.

Managed records carry reserved `preservation` metadata containing
`artifact_role="preserved_copy"` and the source locator. Exact code snapshots are
retained when revising a standalone figure, even if its original script is gone. External `register_figure` behavior is unchanged and does not
claim a preserved copy. A newer preserved revision does not retroactively
preserve an older external revision. Strict resolution checks actual bytes even
for managed copies. Native files remain editable outside the package; no
immutable-filesystem or reproduction guarantee is made. No DATA is copied.

New analysis/figure registration and managed saving stage schema 0.4.0, which
requires clients >=0.5.0 in both languages. Schemas 0.1.0–0.3.0 remain readable
without migration on open. DATA scope recording remains unchanged, including
partial files that share a design pin. Strict DATA resolution retains its
existing individual-file checks; it does not resolve a combined comparison.

Corrections accept `design_ref` and `input_mode` on an analysis or standalone
figure. `analysis` may link a figure to an exact analysis revision; simultaneous
owned analytical overrides reject. DATA design corrections use `set_data_scope`.
Current-purpose pointers and historical references never move automatically.

## Figure rendering sources — BIODATALEDGER-008

Analytical inputs, method, parameters, design and execution uncertainty continue
to come from the exact linked analysis. Rendering inputs are separately declared;
a saved result table is not automatically the same input as the analytical
matrix. A known rendering reference can have an unknown relationship to the
analytical input; a file hash, snapshot or recorded parent does not promote it. Nothing infers a relationship from names, sizes or matching counts.

`register_figure(..., figure_sources={...})` accepts this optional object. R uses
named lists and zero-based code indexes, matching Python:

```text
rendering_inputs: [exact DATA refs] or null
relationship: "declared" or "unknown" (default)
generating_code: {record: exact ANA/FIG ref, index: 0, sha256: optional expected digest,
                  registered_ref: optional exact DATA ref} or null
dependencies: [{path: "helpers/palette.R", ref: exact DATA ref}] or null
asset_id: an explicit project-scoped string alias or null
```

The generating selector resolves an existing code entry once and stores its exact
owner revision, index and digest. A supplied digest must match; an optional code
DATA binding must have that same captured digest. This records a declaration,
not proof that the script generated the figure. No new CODE identities or
execution recorder are introduced. Relative dependency paths reject traversal,
absolute/drive/backslash paths and case/Unicode/file-parent collisions. Declared
dependencies do not establish that every dependency was captured.

Use `update_record(ref, {"figure_sources": {...}}, reason)` to append a correction;
explicit null clears this declaration. Generic details corrections cannot insert
invalid recognized source links. Earlier revisions/current pointers remain fixed.
Storage is optional `details["biodataledger.figure_sources"]` with marker
`version="biodataledger-figure-sources/1"`. Unrelated legacy values under that key
remain uninterpreted. Opening never migrates old records. These figure-source
features use registry schema 0.4.0; saved pre-extension 0.5.0 clients can still
read the optional details but do not validate or expose the source contract.

`get_figure(ref=None, check_files=False, asset_id=None, path=None, revision=None,
compact=False)` retains the old exact-ref calls. Supply exactly one selector.
`FIG-075@2` or a full project/record/revision ref is exact. Bare `FIG-075`, a
registered path, or an explicit asset alias succeeds only for one recorded
revision; otherwise choose an exact reference or supply revision. Paths match
registered relative/absolute paths, not filename guesses. All revisions are
considered, so a newer record is never chosen silently. Exact refs use the loaded
hash index; alias/path lookup scans loaded metadata only.

Full figure views add analytical_inputs, rendering_inputs, rendering_relationship,
generating_code, dependencies, asset_id and figure_sources. Existing analytical
fields/evidence keep their meanings. Existing recorded code candidates and
snapshots remain visible even without a new generating-code declaration. Compact
reports omit the duplicate selected generating entry from alternatives; full views
retain every candidate. Recorded
DATA parent/transformation refs are shown as evidence where present; absence stays
unknown. Ordinary queries never read/hash payload bytes or scan directories.
`check_files=True` requests existence checks only; reported integrity remains
`not_checked`. Missing files become explicit report markers. Dependency
completeness and execution remain unknown even when every listed file exists.

`compact=True` returns a JSON-serializable report bounded to 4096 UTF-8 bytes.
It includes figure identity/path/availability, exact analysis, separate inputs,
recorded relationship evidence, code candidates/snapshots, method/parameters and
missing/contradictory declarations. Large values are omitted with truncation
metadata; exact identity strings are never shortened. Use the full getter for
omitted values. A compact report is not an execution or standalone-readiness
certificate.

`read_figure_source(ref=None, asset_id=None, path=None, revision=None,
code_ref=None)` explicitly retrieves at most 1 MiB of source bytes and verifies
those returned bytes against the recorded SHA-256. It returns content (`bytes` in
Python, `raw` in R), code_ref, sha256, snapshot, integrity="match" and execution
unknown/not_captured. A recorded generating selector is preferred. Otherwise one
recorded code candidate can be read as declared code, without asserting that it
generated the figure. Multiple candidates require an exact code_ref selection.
A recorded snapshot is used exclusively, including staged/imported snapshots;
a missing or corrupt snapshot never falls back to the original. When no snapshot
was recorded, only a matching bounded original file can be returned.

No source is executed or written by this method. Existing declared-file recovery
helpers remain available for an explicitly reviewed file layout. ZIP payload
selection is unchanged: new rendering/dependency declarations do not implicitly
copy their DATA files. Review/include the needed records and code owners during
working export.


## Portable project helpers

Set the project root explicitly from your launch directory or a caller-supplied
configuration. For example, in R use `project_root <- normalizePath(".", mustWork=TRUE)`
only when the session starts in the project root; in Python use `Path.cwd()` under
the same condition. Otherwise pass the selected root into your script. Do not
embed a developer's home directory or search upward/recursively for a ledger.

BioDataLedger resolves metadata; a project helper loads the scientific object:

```r
get_project_data <- function(project, ref) {
  verified <- project$resolve_data(ref = ref, verify = "sha256")
  readRDS(verified$path)
}
```

The helper is project code, not a package API. Choose `readRDS`, `read.csv` or another
native loader for the known file format. `get_data(ref=...)` retrieves metadata
without hashing or loading the object. `resolve_data(ref=..., verify="sha256")`
streams bytes against the recorded digest without deserializing the object and
fails if the file or baseline is missing or changed. A matching digest establishes
file integrity, not biological scope or scientific validity.

Reuse the resolved result and loaded object within the session while the input
remains unchanged. There is no verification cache or automatic invalidation:
resolve again after an input change or when a new verification is required. A
stored resolution result is evidence about bytes at verification time only.

Project-relative registered locators resolve against the opened root after moving
the project. Export previews list selected payloads and omitted dependencies;
imports retain original relative locators and explicit payload bindings. External
files not packaged remain unresolved until deliberate rebinding. Inspect the
preview before sharing; exporting a figure does not automatically package its data.

## Figure discovery and function declarations

`find_figures(query=...)` also searches the registered locator and a recognized
`figure_sources.asset_id`. It still returns latest active revisions, with literal
case-insensitive matching. It searches registry metadata, never the filesystem.
For exact selection use `get_figure(ref)`, `get_figure(asset_id=...)` or
`get_figure(path="plots/panel.svg")`. Paths must match the registered locator or its
resolved absolute project path; a basename alone does not match a nested path.
Ambiguous selectors reject; pass the exact reference or an explicit revision.

`get_figure(..., compact=True)` (`TRUE` in R) now includes `asset_id` and
`entry_point`. To record an optional function name, pass
`details={"entry_point": "draw_umap_by_library"}` to Python `register_figure`, or
`details=list(entry_point="draw_umap_by_library")` in R. This reuses optional figure
metadata, adds no API argument and records only a declaration. The name does not
prove invocation or select among code files. Use `figure_sources.generating_code`
for an exact code selector. Blank, absent or nonscalar entry points report null;
large strings are omitted with a truncation marker. The full getter preserves raw
metadata. Compact output remains capped at 4096 UTF-8 bytes.

Existing revisions already preserve an explicit figure identity: use
`save_figure(source, ref=old_exact_ref)` for a revised saved image, or
`update_record(old_exact_ref, changes, reason)` for a metadata correction. The
returned reference has the same figure ID and a new revision. Old exact refs
remain readable; no relationship is inferred from filenames. Prefer managed
`save_figure` copies when old image bytes must also remain available: metadata
history alone cannot preserve an overwritten external file.


## R-only live-object prototype — BIODATALEDGER-010

`check_object(object, ref=NULL, purpose=NULL, assay=NULL, layer=NULL)` accepts an
already-loaded generic list or an optional Seurat object. It compares observed
membership/metadata/selected representation with the exact DATA revision's existing
scope, pinned design and registered manifests. Required FAIL or UNKNOWN returns
BLOCKED. It is read-only and never loads or hashes the dataset/matrix. Printed
cards distinguish observed values, declared identity/selection and unverified
origin/downstream use. No Python checker or automatic execution gate is added.
See [object-check v1](OBJECT_CHECK_V1.md) for the native interface, CSV authorities,
required-field rules, manual helper example and language-neutral report contract.
This local prototype is not included in the README's pinned published build.

## Save and confirm persistence

`save_and_confirm()` in Python and R saves **all pending changes** through the
existing `save()` path. Registration and setters still stage edits; they do not
autosave. Use this explicit boundary immediately after a completed dataset-choice,
design or scientific-decision change, and once after registering a related result
batch. The operation saves earlier pending edits too, including unrelated figures;
it does not isolate the latest setter or roll back an incomplete batch.

The returned receipt has these fields:

| Field | Meaning |
| --- | --- |
| `status` | `persisted` after a successful write; `no_changes` for a clean call |
| `scope` | Always `all_pending_changes`; no exact changed-record inventory is claimed |
| `previous_committed_revision` | Revision on which the loaded session was based |
| `committed_revision` | Revision returned by the successful save |
| `transaction_id` | Transaction ID for that committed revision |
| `registry_written` | True only when this call published a new registry revision |

On a clean call, the two revisions are equal and the transaction ID is the loaded
revision's existing ID. No disk read/write or freshness check occurs. A stale clean
session is not refreshed: open a new session to read the latest saved state.
Save errors propagate without a success receipt; pending edits remain available
for inspection/reconciliation. Do not automatically reload/discard them or retry a
stale write. Successful registry persistence is not scientific verification or
approval, does not copy every external dataset, and is not a power-loss guarantee.

Python: `receipt = ledger.save_and_confirm()`.
R: `receipt <- ledger$save_and_confirm()`.
Report durable registration only after this returns `status="persisted"` and
`registry_written=True/TRUE`. `save()` remains supported with its original return
shape. This additive helper changes no schema, storage architecture or getter.
It provides no background, timer or session-exit autosave.

## Derived results and dependency lineage — 0.6.0

Both native clients add register_result(), check_result() and dependencies().
Reference-first registration reuses existing DATA/ANA/FIG revisions and producer/
rendering links; copying and hashing are explicit options. CSV is the first
validated adapter. Native Seurat/AnnData selectors are supported declarations with
unmeasured alignment UNKNOWN. Save related changes through save_and_confirm().
See RESULTS_V1.md for arguments, report fields, bounds and compatibility. Package
0.6.0 does not introduce a new registry schema or migrate old projects on open.

## Explicit execution receipts — 0.7.0

`run_analysis(analysis_ref, entry_point, outputs=[], seeds=None,
verify_inputs=True, verify_code=True)` runs one function from one registered native
code snapshot. The function receives `inputs`, `params`, `seeds`, `outputs`.
Inputs and outputs are ordered paths; scientific objects are not loaded by the
wrapper. R uses named lists, `NULL`, `TRUE` and `$run_analysis`.

A distinct ANA run preserves the template's exact context. The started revision is
saved before invocation. A terminal revision records success, failure or incomplete
evidence and is saved through `save_and_confirm`. Outputs register through existing
DATA/FIG methods and retain the exact started run as producer. `get_execution(ref)`
reads one exact receipt revision; `execution_summary(ref)` provides bounded text.
The full [execution contract](EXECUTION_V1.md) defines errors, verification,
interruption, output capture and evidence limits. Existing generic provenance views
remain conservative; use this explicit receipt getter for run observations.
