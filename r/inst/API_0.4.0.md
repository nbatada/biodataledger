# BioDataLedger API 0.4.0

Native Python `biodataledger` and R `BioDataLedger` expose `ProjectBundle`. R uses `$`, `NULL`, `TRUE` and lists. The package records declarations; it does not run analyses, authenticate approval or validate biological conclusions. Mutation must use the public methods; direct edits to internal state are unsupported.

## Open once, inspect cheaply, verify explicitly

`ProjectBundle.create(name, project_dir, purpose=None, raw_dir=None, metadata=None)` creates a registry in an existing root and refuses overwrite. `open(project_dir)` loads and validates it once. Loaded exact lookups use hash indexes; indexes are not persisted. A loaded object does not automatically refresh when another writer saves.

| Operation | Contract |
| --- | --- |
| `get_data(ref=None, role=None, purpose=None, check_files=False)` | Exactly one selector. Exact refs include project UUID, record ID and revision; `DATA-001@2` is local shorthand. Purpose uses its exact current pointer. A missing or ambiguous role rejects. Returns detached path/ref/scope/design metadata. |
| `get_analysis(ref)` / `get_figure(ref, check_files=False)` | Retrieve exact historical records. Figures inherit inputs, code, method, parameters and design from their linked analysis. `get_figure` exposes unknown fields, source paths and separate declared/file/execution provenance. |
| `find_figures(query=None, type=None)` | Search latest active figures. Call `get_figure` for full provenance in either language. Search is a deliberate inventory operation, not an indexed exact lookup. |
| `status(compact=True, purpose=None, check_files=False)` | Bounded metadata, counts, current refs, next task and dirty state. A named purpose adds the selected dataset's compact scope and pinned design. Missing purpose stays visible as no selected dataset. No registry dump or default file inventory. |
| `summary()` / `summary_text(purpose=None)` | Summary values or readable project/purpose context. No matrix loading or implicit hashing. |
| `resolve_data(ref=None, purpose=None, verify=..., expected_scope=None, require_membership=False)` | Explicit strict verification; supply exactly one selector and `verify="sha256"`. Streams the selected file only, requires a captured digest, active record and usable file, and rejects size/digest/scope contradictions. Returns a verified path or raises; never substitutes a different dataset. |
| `check(hashes=False)` | Explicit registry-wide file audit. Hashing is opt-in and can be expensive. |

**0.4 availability change:** ordinary getters return `available=None`/`NULL` and `availability_checked=False`/`FALSE`. This means not checked, not missing. Use `check_files=True`/`TRUE` for existence checks, or `resolve_data(..., verify="sha256")` before using a selected input. Dependent availability is likewise unknown by default. Status reports zero files checked and unknown unchecked/missing totals until explicitly requested. `check_files=True` checks at most 100 distinct relevant locators and reports remaining counts; it does not hash.

Compact status is capped at 4096 UTF-8 bytes, with explicit omissions/truncation. Exact references are not shortened into different IDs. A byte cap is not a model-independent token guarantee. The ordinary summary aims to stay below 500 estimated tokens; full details are requested separately.

## Retain data, analyses and figures

- `register_data(path, role, name=None, hash=False, **details)` records an existing file/URI. Hashing large local files is an explicit opt-in. Known parent/membership links use exact DATA refs in details; clustering_run uses an ANA ref.
- `register_analysis(name, inputs, code=None, method=None, params=None, snapshot_code=True, **details)` pins exact DATA refs and the current design, if set. Inputs/method/parameters may be explicitly unknown.
- `register_figure(path, type, analysis=None, name=None, inputs=None, code=None, method=None, params=None, snapshot_code=True, **details)` records an existing figure and its digest. With an analysis ref, direct inputs/code/method/params overrides reject. One analysis can supply shared provenance to several figures.
- Supplied code files are snapshotted by default, with a 1 MiB per-file limit and explicit opt-out. Snapshots preserve bytes; they do not prove execution or discover imports. Native figure/data saving remains outside the library.
- `save()` commits meaningful staged changes as one atomic JSON snapshot. Clean save returns without disk writes. Dirty save checks the loaded digest/revision under the existing lock; a stale writer fails and retains pending edits. Do not automatically merge or steal locks.
- `update_record(ref, changes, reason)` appends a correction, preserving earlier revisions and current pointers. Protected scope/design changes use their dedicated setters. Clear a recorded membership-verification claim through the scope setter before changing its bound file/details.
- `set_current(ref, purpose, reason)` records an explicit scientist-selected active DATA revision. It never rewrites historical analysis inputs. External scientific authority blocks a competing local current choice.
- `record_decision(text, reason, targets)`, `set_context(changes)` and `rebind_external(ref, path, reason)` retain their explicit declaration/rebinding roles. Rebinding checks known hashes. `get_raw_dir`, `get_metadata_path`, and `get_output_dir(kind)` retrieve locations without creating analysis directories.

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

Legacy state/snapshot paths and ZIP `nb-project-bundle-zip/0.1` remain unchanged. Schema 0.1.0 and 0.2.0 open without migration. Saving DATA scope/design enables schema 0.3.0, which older clients reject. Use package 0.4.0 in both languages for new scopes.

The 20 MiB limit applies to registry JSON and archive manifest JSON individually, not total payload size. Existing 10,000 archive-entry, 100 GiB expanded-size and 1000:1 ratio limits remain. Oversized metadata refuses before publication and retains staged edits. No 100,000-record capacity claim, other-platform/network-volume write qualification, scientific acceptance or automatic reproduction follows from these APIs.
