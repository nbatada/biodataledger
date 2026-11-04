# Derived results and dependency lineage — v1

Introduced in the **0.6.0** Python/R packages and included in the pinned GitHub
installation in the README. This is a package API version, not a new registry
schema. No new schema or ZIP format is introduced.

A derived result is an ordinary exact DATA revision. The library records
`DATA → ANA → result DATA → FIG` using existing identities. It never reconstructs
missing historical provenance or computes an embedding.

## Register an existing result

Python: `p.register_result(source, analysis_ref, ref=None, embedding=None, copy=False, hash=False)`.
R: `p$register_result(source, analysis_ref, ref=NULL, embedding=NULL, copy=FALSE, hash=FALSE)`.

`source` is a local existing file path or an exact DATA ref (including local
`DATA-003@1` shorthand). `analysis_ref` is an explicit exact ANA ref or null when
unknown. Neither argument selects a latest record implicitly. The return value is
an exact DATA ref; changes are staged until `save_and_confirm()` succeeds.

By default the result references the original file. Registration performs no
payload read, hashing, scientific-object loading or copying. A source DATA ref
reuses its recorded locator/digest/size without claiming the bytes were rechecked.
A path with no explicit hashing has unknown byte identity. An external file can
subsequently change; registry revisions alone do not retain its original bytes.

- `hash=True/TRUE` explicitly hashes the selected file. An existing source DATA
  baseline must match; a mismatch rejects rather than refreshing that baseline.
- `copy=True/TRUE` explicitly copies the entire selected file to an exclusive
  project-managed location and verifies source/copy digests. It never extracts a
  reduction implicitly. This may be costly for large RDS/H5AD files. Source and
  previous copies are never overwritten. Copying always verifies bytes regardless
  of the hash argument.
- `ref` appends a revision of an existing recognized result DATA identity. Supply
  the new source, producer and embedding declaration explicitly. Old references
  and current-for-purpose pointers stay unchanged.
- `embedding=None/NULL` records a generic result such as a DE table. A descriptor
  identifies a CSV or a named native embedding without loading it.

The producer is stored once in DATA `scope.transformation_ref`; its exact design
context is retained when known. Method, parameters and code remain owned by that
ANA revision. A producer link is declared provenance, not execution evidence.
`details.membership` holds the exact independent observation authority when supplied.

Invalid declarations reject before staging. Failed copying removes only that
call's new copy. A later failed registry save retains staged edits and completed
copies for inspection; it does not roll back external scientific computations.
Generic path or result-descriptor edits must use `register_result` to create a new
revision. Ordinary metadata corrections preserve the existing declarations.

## Embedding declarations

Use a named dictionary/list with these fields. Unknown field names reject.

| Field | Meaning |
| --- | --- |
| `format` | `csv`, `seurat` or `anndata` |
| `key_columns` | Two distinct text columns for qualified identity; defaults to `sample_id`, `cell_id` |
| `coordinate_columns` | Required distinct CSV coordinate column names; null for native formats |
| `selector` | Null for CSV; exact Seurat reduction or AnnData obsm key for native formats |
| `membership_ref` | Optional exact DATA ref to an independently registered observation CSV |
| `alignment` | CSV `same_row`; native `ordered` (default) or `keyed` |
| `row_key_column` | Native observation-manifest column mapping to embedding row names/obs_names; required for keyed alignment, optional for ordered; null for CSV |
| `comparison` | `set_keys` or `ordered_keys` for independent CSV membership checks; defaults to ordered for ordered native alignment, otherwise set |

For example, a CSV descriptor can be
`{"format":"csv","coordinate_columns":["UMAP_1","UMAP_2"],"membership_ref":membership}`
in Python, or the corresponding named R list. Seurat uses
`{"format":"seurat","selector":"umap","membership_ref":membership}`; AnnData
uses format `anndata` and selector `X_umap`. Selectors are literal names, never
expressions to evaluate. Native ordered alignment declares that manifest rows
correspond to embedding rows; keyed alignment explicitly names the row-key column.

The exact identity includes the DATA artifact revision, selector and observation
reference/alignment declaration. A reduction name alone is not an embedding identity.
Missing authority or unmeasured native alignment remains UNKNOWN. Separate objects
can have identical cell counts or treatment labels and different qualified cells.

## Explicit checking

`check_result(ref)` is read-only in both clients. It accepts an exact DATA ref and
returns a `biodataledger-result-check/1` report with:

- exact `ref`, adapter, observed SHA-256 and observed row count when measured;
- field-level status/reason for contract, file integrity, observation identity,
  coordinates, alignment and membership;
- overall FAIL if any field fails, otherwise UNKNOWN if any is unknown, otherwise
  PASS; execution remains UNKNOWN and scientific validity/downstream use unverified.

The overall status covers those checks, not completeness of producer provenance or
scientific approval. A generic artifact has no embedding adapter; use existing
`resolve_data(ref=..., verify="sha256")` for explicit generic-file verification.

V1 executes **CSV checks only**. Seurat/AnnData descriptors round-trip in either
client, but `check_result` reports `adapter_not_available` for unmeasured properties.
It does not call readRDS/read_h5ad, load Seurat/AnnData, install dependencies or
convert native formats. These native selectors are supported references, not
validated native embedding extraction.

CSV checks read at most 20 MiB per selected artifact/authority. Larger or unavailable
files give UNKNOWN with a reason, never partial PASS. Known digest contradictions
are FAIL. A missing baseline leaves file integrity UNKNOWN even if structure passes;
an observed hash is never silently adopted as the registered baseline.

The CSV header and row widths must be valid, qualified keys nonblank and unique,
and coordinate values finite decimal numbers. IDs are text, retaining leading
zeros and Unicode. Coordinates and qualified IDs on the same row establish the
recorded alignment. No sorting, normalization, joins or recomputation occur.
Quoted commas and newlines are supported. Blank rows or malformed fields fail.

When an independent membership authority is supplied, its registered digest must
match before exact qualified-key comparison. Set comparison ignores row order;
ordered comparison does not. Equal counts alone do not establish membership.
Missing authority/digest is UNKNOWN; contradictory keys or tampered authority fail.
A valid table cannot establish that coordinates were scientifically assigned to the
right cells before saving without independent evidence.

Reports do not write the registry or scientific approval. Retain a report using
ordinary file/DATA registration if needed, then save explicitly. A check applies to
the measured bytes at that checkpoint, not to future file mutations or actual use
by an unrestricted plotting script.

## Forward and backward dependencies

`dependencies(ref, direction, depth=1, limit=20)` accepts an exact record ref and
`upstream` or `downstream`. Depth is 1–3, edge limit 1–100. The response is bounded
to 16 KiB and omits complete edges/identity-bearing items when necessary, marking
`truncated`. It never shortens an ID into a different identity.

The response contains typed exact `from`/`to` refs, evidence basis and source field:

| Edge type | Recorded relationship |
| --- | --- |
| `input_to_analysis` | DATA → ANA from analysis inputs |
| `produced_result` | ANA → opted-in result DATA from transformation_ref |
| `rendered_in_figure` | DATA → FIG from exact rendering inputs |
| `analytical_association` | ANA → FIG analytical context, separate from rendering |
| `artifact_container` | Exact source DATA → result DATA sharing/copying that artifact |
| `observation_authority` | Exact membership DATA → result DATA |

Associations are not evidence of computational generation. Declared and unknown
relationships retain their basis; paths through unknown links do not become
verified. Legacy transformation/parent hints do not acquire an inferred producer.
No returned edges means no recorded matching dependencies, not no real dependants.
Coverage remains `recorded_only` and execution `unknown`. Missing evidence and
truncation are explicit. No automatic revalidation or rerun is performed.

Queries use in-memory adjacency over exact revisions, not a graph database. They
perform no payload reads, hashes, directory search, scientific-object load or
registry writes. Indexes are rebuilt on open and maintained for staged records.

## Retain and retrieve one result chain

Register the input and generating ANA using existing APIs. Register an existing
coordinate file with `register_result`, then pass that exact DATA ref through
`figure_sources.rendering_inputs` when registering the plot. Set relationship to
`declared` only when that declaration is actually supplied. The figure's analytical
analysis and the rendering producer may differ and remain separate.

Call `save_and_confirm()` once for the related batch. Its all_pending_changes receipt
confirms registry persistence only. Reopen in a fresh R/Python process and retrieve
exact refs; `get_data()` is metadata-only, while explicit `resolve_data()` checks
selected file integrity. Use existing `save_figure()` when a plot copy is desired.
Rerendering can reuse the exact result; new computation or observation mapping must
create a new revision. Never silently select a later embedding for an old figure.

## Compatibility and limits

The result contract is optional versioned metadata under `details.biodataledger.result`.
Producer and membership remain in existing canonical fields. Copy metadata uses an
ordinary DATA locator/hash; the FIG-only top-level preservation field is unchanged.
Registry schema remains within existing 0.1.0–0.4.0 support. Writing DATA scope uses
the existing 0.3.0 minimum; analyses/figures still use 0.4.0. Opening never migrates.

Older clients can preserve these optional details but do not validate result
semantics or expose these APIs. Unknown descriptor versions remain uninterpreted;
malformed known metadata is reported unknown. Result-requiring mutations reject
unsupported or incompatible descriptors instead of guessing or dropping them.
An unrestricted older client or shell is not prevented from editing metadata or
files. Strict verification detects changed known bytes; copied files are not
filesystem-immutable. Missing external bytes cannot be recovered from hashes.

No scientific data container, workflow engine, graph database, native embedding
conversion, execution recorder or automatic historical reconstruction is included.
