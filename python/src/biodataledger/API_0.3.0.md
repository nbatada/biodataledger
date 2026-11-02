# BioDataLedger public API 0.3.0

Python `biodataledger` and R `BioDataLedger` 0.3.0 support legacy schema 0.1.0 and optional experimental-design schema 0.2.0. The maintained source is this file; identical copies ship in both packages. The wire contract/shared schema define persistent representation. This API records declared science; it does not perform or validate it.

Use `ProjectBundle.create/open/import_zip` in Python and `ProjectBundle$create/open/import_zip` in R. Creation requires a name and an existing explicit project directory; purpose, raw_dir and metadata are optional. Open is read-only and never initializes. Returned objects expose the following methods (`p.method` / `p$method`).

| Operation | Arguments and result |
| --- | --- |
| `get_raw_dir`, `get_metadata_path` | No args; configured path or missing. No loading/scanning. |
| `get_output_dir` | `kind`; resolves root/results/kind without creating it. |
| `get_data` | Exactly one of `ref`, `role`, `purpose`; returns record/path/ref/availability, never a matrix. Ambiguous or missing selection errors; a selected missing file returns unavailable without fallback. |
| `register_data` | Existing `path`, `role`; optional name, `hash=True/TRUE` and declared semantic details. Defaults to no payload reading. Directory references cannot be selected as ZIP payloads. |
| `register_analysis` | `name`, `inputs` (list of exact refs, null for unknown); optional code path/list, method, params and semantic details. Supplied code snapshots default on, max 1 MiB per file; explicit `snapshot_code=False/FALSE` records only the declared file fingerprint. |
| `register_figure` | Existing regular file `path`, `type`; optional exact `analysis` ref and name. With analysis, inherit its inputs/code/method/params without repeated entry. Conflicting direct analytical fields reject. Without analysis, direct fields or unknowns are allowed. |
| `find_figures` | Optional literal `query`, `type`; returns candidate record list; select before `get_figure`. |
| `get_analysis` | Exact analysis ref; returns the registered analysis plus design_ref and its exact design, or null when unknown. |
| `get_figure` | Exact ref; returns data/code refs, method/params, analysis_details, exact design/design_ref, explicit provenance (figure_file/analytical/execution), unknown fields, input/code availability. Existence is not a fresh hash check; call check(hashes=True/TRUE) for byte verification. |
| `status(compact=True/TRUE)` | Bounded project/current refs, recorded next task, missing/unchecked counts and staged-edit state; no raw-directory crawl or payload read/hash. Maximum 4096 compact UTF-8 JSON bytes with explicit truncation. Active question is null because legacy state does not designate one. |
| `summary`, `check` | Summary of state/current/unsaved/next task plus current design and unique latest data/analysis/figure counts; check reports referenced availability, optional hashes. No eager matrix loading or imported code execution. |
| `save` | Validates staged edits; shared writer lock and loaded-byte digest reject stale writes; atomically replaces state on the tested local filesystem. Returns revision and transaction. No automatic merge/retry. |
| `set_current` | Exact data ref, purpose, reason. Requires actual scientist authority outside the API; external authority declarations make local pointer changes reject. Registration does not move a pointer. |
| `set_context`, `update_record`, `record_decision`, `rebind_external` | Explicit context/correction/history/location operations. Corrections preserve older refs; no scientific approval conferred. See method signatures; do not use as an automatic cohort-repair mechanism. |
| `preview_export` | `mode="context"` or `"working"`, optional `include` list of exact data/figure/analysis refs. Shows files, metadata, bindings, omissions and missing resources. Plans are local to the client that created them. |
| `export_zip` | Reviewed plan and new output `path`. Rejects edited/stale plans and changed/missing selected bytes. Never overwrite output. |
| `import_zip` | Archive `path`, new `project_dir`. Validates before publishing; no execution/deserialization/fetching/install. Imported external resources remain unavailable until explicitly rebound. |

References are `{project_id, id, revision}` dictionaries/lists. Exact local shorthand `FIG-001@1` resolves only within the opened project. Names are not identities. Mutations stage edits until save; creation itself commits the initial empty state. Snapshots preserve the supplied bytes, not a proof those bytes executed.

Parameters must be a JSON object or null. In R use a named list; arrays use unnamed lists, including `list()` for an empty array. Unknown is `None`/`NULL`, distinct from an explicitly empty array/object. Do not pass unsupported arbitrary R/Python objects. Subset, layer, unit and selection references are declared details, not universally required fields. Large cell membership belongs in a referenced file.

## Four-call retained-figure example

Python, after `p` is opened and `d = p.get_data(purpose="qc")` resolves an authorized input:

```python
a = p.register_analysis("QC", [d.ref], code="qc.py", method="declared summary", params={"cutoff": 200})
f1 = p.register_figure("library.svg", "qc", analysis=a)
f2 = p.register_figure("genes.svg", "qc", analysis=a)
p.save()
```

R:

```r
a <- p$register_analysis("QC", list(d$ref), code = "qc.R", method = "declared summary", params = list(cutoff = 200))
f1 <- p$register_figure("library.svg", "qc", analysis = a)
f2 <- p$register_figure("genes.svg", "qc", analysis = a)
p$save()
```

Eight required argument values; code/method/parameters entered once as three extra shared arguments. Example cutoff is synthetic, not an analytical recommendation. A legacy figure is allowed with just path/type, then save; its code/inputs/method remain unknown.

## Sharing and limits

Working payload selection is explicit. A selected figure includes its declared code snapshot in the preview; it does not recursively include its input data or script imports. Select a data ref explicitly when intended. Context has metadata/history only. Review free text, identifiers and all paths before sharing; no patient-data detector or anonymizer exists.

This version does not implement metadata redaction, custom output directory configuration, raising archive limits or generalized save/load adapters. Unsupported preview redact/exclude requests reject; do not silently ignore them. Whole registry metadata/history is included, so a project containing sensitive metadata is not suitable for this version's external sharing. Do not export it. The synthetic example contains none.

Fixed limits: 10,000 archive entries; 20 MiB state/manifest; 100 GiB declared expanded total; compression ratio 1,000:1; 1 MiB code snapshot per file. Both clients reject tested unsafe paths, links, collisions, corrupt payloads and invalid references. Standard ZIP64-capable tooling is used, but physical exports over 4 GiB have not been benchmarked/qualified in this version.

Writes have been tested on local macOS. Power-loss durability and network/cloud-sync writes are untested. R requires macOS writes. No universal cross-platform guarantee follows from portable metadata. Native RDS/H5AD remain opaque files; importing their registry is not converting or executing them.

The source checkout and immutable snapshot may both exist; only the snapshot preserves earlier bytes. No code executes on open/import. Filesystem restrictions, scientific authority, authenticity and consent are not enforced by an unrestricted package caller. No automatic resumable/reproduced status: those require separate task/runtime evidence or an actual rerun.

## Experimental design

Python: `p.set_design(condition, levels, selected_levels=None, reference_level=None, replicate=None, selection_reason=None, metadata=None, context=None)`.

R: `p$set_design(condition, levels, selected_levels=NULL, reference_level=NULL, replicate=NULL, selection_reason=NULL, metadata=NULL, context=list())`.

Both stage a new exact DES-001 revision and return `{project_id, id, revision}`; call save to persist. R level arguments are character vectors; Python uses lists of strings. No design is required at project creation. Omitted selected_levels means all declared levels. Levels and selection must be nonempty and unique; the selection must be a subset and any reference must belong to the selection. Order is preserved without sorting. Optional fields remain null when absent.

| Method | Result |
| --- | --- |
| `get_design(ref=None/NULL)` | Full current design or exact requested historical design, including its ref, evidence_source, metadata_check and context. Missing current design returns null. Missing explicit refs reject. |
| `get_condition()` | Condition column name or null. |
| `get_levels()` | Ordered declared categories; Python list / R character vector, or null without design. |
| `get_selected_levels()` | Ordered intended analysis categories, or null. |
| `get_reference_level()` | Reference category or null. |
| `get_replicate()` | Biological replicate column name or null. |
| `check_design_metadata(metadata, ref=None/NULL)` | Read-only report against current/exact design; no design is an error. No file or expression-matrix access. |
| `get_design_summary()` | Bounded condition, selected_levels, reference_level, replicate, revision and truncated flag; null without design. First five selected levels, text fields clipped to 64 characters. Full get_design is exact. |
| `summary_text()` | Bounded AnnData-like project description with purpose, design, excluded levels, reason, revision and actual unique-record counts. Values clipped to 160 characters, level lists to eight values. Used by Python repr and R print. |

Design details contain exactly condition, levels, selected_levels, reference_level, replicate, selection_reason, evidence_source, metadata_check and context. Context is a list of exact data/analysis references, default empty (not inferred). It does not establish the origin of supplied metadata.

Metadata must be an in-memory dictionary of column sequences in Python, or a named column list/data frame in R. R factor labels are supported; Python pandas users can supply `table.to_dict(orient="list")`. Only the named condition and replicate are inspected. Condition values must be strings or missing; replicate values may also be numeric. A check returns valid, row_count, observed_levels, missing_levels, missing_selected_levels, missing_columns, unexpected_levels, missing_condition_values and missing_replicate_values. Observed order is first appearance. Missing columns produce a failed report with row_count zero; unequal lengths or malformed values reject. Missing/blank/nonfinite values fail verification. At least one row and no unknown levels are required. Declared/selected categories absent from the supplied dataset are reported separately and do not alone invalidate the check.

A read-only check never changes evidence. Passing `metadata` to set_design requires a valid check and stores that report with evidence_source `metadata-verified`. Otherwise evidence is `scientist-declared` with a null report. Verification concerns supplied labels, not a scientific comparison, independent replicates, data filtering or proof of source authenticity. Raw metadata rows and replicate identities are not persisted; observed condition labels and counts are.

New analyses automatically pin the current design, if configured. Linked figures derive their design from the exact analysis revision; standalone figures pin the current design. Later set_design calls never rewrite earlier records, including unknown legacy contexts. get_analysis/get_figure return design_ref and resolved design. Generic update_record preserves those refs and cannot modify a design record; use set_design for a new revision.

First configuration stages schema 0.2.0 and save commits it under the ordinary lock/stale-state protocol. Old schema 0.1.0 projects open without mutation; clients before package 0.3.0 reject design-enabled states. ZIP format, state path and prior record identities remain unchanged. Whole-registry exports retain design history and evidence; review labels/reasons/context for privacy before sharing.
