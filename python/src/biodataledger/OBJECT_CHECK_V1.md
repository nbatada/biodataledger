# Live input check — R prototype and report contract v1

`ledger$check_object(object, ref=NULL, purpose=NULL, assay=NULL, layer=NULL)`
checks an already-loaded object. Supply exactly one exact DATA reference or
current-for-purpose selector. The selected DATA revision supplies the requirements.
The method returns a `BioDataLedgerInputCheck` list with a native R print method.
There is no Python checker yet; the report and ordinary registry metadata are
language-neutral. This prototype is included in the pinned GitHub build.

## What is measured

The checker compares sample-qualified cell IDs, condition values, replicate
mapping and cluster assignments with registered independent authorities. It
inspects the selected assay/layer and its cell names, without reading expression
values. A caller must name the assay and layer explicitly; the checker never uses
the expected representation as an observed default.

The `biodataledger_ref` object attribute is a **declared** origin reference. PASS
for dataset identity means that its project, DATA ID and revision match the
selected requirement. It does not authenticate the object or prove it was loaded
from those file bytes. Missing identity is UNKNOWN; a different complete identity
is FAIL. Required FAIL or UNKNOWN produces BLOCKED.

A PASS report covers only the properties measured at that instant. It does not
prove biological validity, a scientific subset-selection rule, matrix values,
file-to-object identity, future immutability, downstream assay/layer consumption,
or that an analysis or figure used the checked object. Those limits print on every
card. Ordinary analysis and registration APIs remain ungated; a project helper can
explicitly refuse to continue when the report is BLOCKED.

## Existing records supply the requirements

Reuse one selected DATA revision, its pinned `design`, existing `scope` and
`details.membership`; do not create a separate requirement registry. Record the
following authorities as ordinary DATA records with `hash=TRUE`:

| Existing field | CSV authority or expectation |
| --- | --- |
| `details.membership` | Exact DATA ref to a membership CSV with `sample_id,cell_id` |
| `scope.sample_manifest_ref` | Exact DATA ref to a CSV with unique `sample_id` and the pinned DES condition/replicate columns |
| `scope.condition_values` | Expected observed condition levels; otherwise the pinned DES selected levels |
| `scope.assay`, `scope.layer` | Expected representation selections |
| pinned DES `condition`, `replicate` | Names of columns to inspect in object metadata and sample mapping |

CSV values are read as text. Sample-qualified pairs are compared without ambiguous
separator concatenation. Blank/NA keys, empty observations and duplicate qualified
IDs cannot pass. No counts, condition labels, column names or stored verification
report substitute for measuring the actual keys and assignments.

Small optional instructions live in the same DATA record's existing freeform
`details.object_check` block:

```json
{
  "version": "biodataledger-object-requirements/1",
  "membership_policy": "exact",
  "cluster_ref": {"project_id": "<project UUID>", "id": "DATA-003", "revision": 1},
  "required": ["clusters"]
}
```

`cluster_ref` is an exact DATA ref to an independent CSV with
`sample_id,cell_id,cluster`. Actual metadata must contain a `cluster` column;
if the project's column has another name, expose its current values under that
name in the object's metadata for this prototype. No expected assignments are
copied into the observation. Extra reference cells are allowed; every observed
cell must have the expected assignment.

All keys after `version` are optional. An absent block defaults to exact membership.
Unsupported versions, keys, invalid selectors or flags report required UNKNOWN;
they do not silently reduce checking. `required` is an array of additional field
names from the report below. It cannot disable an automatically required check.
Use existing `register_data(..., membership=..., object_check=...)`,
`set_data_scope()` and `update_record(..., changes=list(details=...), reason=...)`
to record or revise these declarations. Preserve other details when revising them.
Historical references remain pinned. Older clients preserve but do not enforce
this optional metadata.

The checker always requires valid requirements, dataset identity, a verified
membership reference and measured membership. Conditions become required when
scope/DES declares them; replicates when DES names them; assay/layer and
representation when scope declares them; clusters when a cluster ref is recorded.
Additional `required` names can make unavailable evidence blocking. Absent optional
checks remain UNKNOWN and do not block.

## Membership policies

- `exact`: observed sample-qualified cells equal the approved set, regardless of order.
- `subset`: every observed cell belongs to the approved parent; empty objects do
  not pass. Containment does not verify the scientific selection rule.
- `exclude`: no observed qualified cell appears in the forbidden manifest. A
  manifest containing only `sample_id` instead forbids entire samples.

The policy changes only membership comparison. Required condition levels,
replicate mapping, representation and clustering requirements still apply. For
example, a subset missing a required treatment level is BLOCKED even if all its
cells belong to the approved parent. Register the scientist's intended scope for
that subset instead of silently relaxing the parent requirements.

Conditions compare both the observed level set and each cell's sample-to-condition
mapping. Replicates compare each cell's sample-to-replicate mapping. Matching
levels without an independent sample mapping gives UNKNOWN, not PASS. Extra
samples in a reference table are allowed; missing observed samples, swapped values
or duplicate sample mapping keys cannot pass. Scope that conflicts with the pinned
design produces FAIL. Labels do not establish biological replication.

Authorities must be readable local CSV files with a registered SHA-256 and at most
20 MiB each. The exact bytes read are hashed before parsing. Missing files/digests,
malformed tables or missing/ambiguous columns produce UNKNOWN for the affected
check; mismatched hashes or inactive authority revisions produce FAIL.
`membership_reference=PASS` confirms the referenced CSV's byte integrity and
parsing, while `membership` separately assesses whether its keys are usable and
match. Each authority is read at most once per call, with no cache across calls.
There is no dataset reload, whole-object serialization, recursive search, matrix
hashing, full-registry reload or registry write.

## Supported already-loaded objects

The generic interface is an ordinary R list:

```r
object <- list(
  cells = cell_metadata,
  assays = list(RNA = list(counts = counts_matrix))
)
attr(object, "biodataledger_ref") <- resolved$ref
```

`cells` is a data frame with nonempty `sample_id` and `cell_id`, plus the required
DES-named metadata and `cluster` columns. Its row names identify columns of the
selected matrix. Matrices can be base matrices or `Matrix` objects; the checker
looks only at dimensions and column names. The selected layer must cover exactly
the metadata cells, with unique names. Multiple entries with the same assay/layer
name are ambiguous and yield UNKNOWN. Large matrix values are neither copied nor
inspected.

If the supplied object inherits `Seurat` and optional **SeuratObject >=5.0.0** is
installed, the built-in adapter reads `object[[]]`, assay names and exact layer
names/cell names. It does not call `GetAssayData` or materialize expression values.
There is no default/partial layer match; select an exact split-layer name. A layer
covering only part of the object's metadata fails representation checking. Add
sample-qualified metadata columns explicitly; barcodes alone are insufficient.
The same origin attribute is read as a declaration. SeuratObject is not required
for ordinary BioDataLedger or the generic interface.

## Manual use and a project helper

Assume the scientist has registered the appropriate requirements and selected the
current input for `comparison`. Load it using the project's native loader:

```r
ledger <- BioDataLedger::ProjectBundle$open(project_root)
resolved <- ledger$resolve_data(purpose="comparison", verify="sha256")
object <- readRDS(resolved$path)  # Explicit project loading, outside the checker.
attr(object, "biodataledger_ref") <- resolved$ref
card <- ledger$check_object(object, purpose="comparison", assay="RNA", layer="counts")
print(card)
if (card$overall != "PASS") stop("Input check BLOCKED; inspect the card")
```

Attaching the reference records the loader's declaration; it does not seal the
object. Recheck after modifying the object's membership, metadata or representation.
Use the project's actual native loader and representation, not this example's
names by default. A project-specific helper may perform the same explicit call
and stop; no callback engine or mandatory helper framework is provided.

For a fully synthetic demonstration, run the package's `r/tests/object_check.R`
with an installed local prototype. It prints the actual full PASS and wrong-cell
BLOCKED cards, then checks the other failure and optional-evidence cases. The test
uses no real project data.

## Language-neutral report

The R list can be encoded using
`jsonlite::toJSON(unclass(card), auto_unbox=TRUE, null="null")`.
It contains summaries, references and evidence labels, never the supplied object,
cell-ID vectors, matrices or a full registry dump.

| Property | Contract |
| --- | --- |
| `report_version` | `biodataledger-object-check/1` |
| `requirement_ref` | Exact project UUID, DATA ID and integer revision |
| `references` | Exact dataset/design/membership/samples/clusters refs, or null |
| `checker` | Implementation and checker version string |
| `checked_at` | UTC timestamp `YYYY-MM-DDTHH:MM:SSZ` |
| `fields` | Map with the ten fields below |
| `overall` | `PASS` or `BLOCKED` |
| `blockers` | Array of required field names whose status is FAIL or UNKNOWN |
| `unverified` | Array of explicit properties the check cannot establish |

Field names are `requirements`, `dataset`, `membership_reference`, `membership`,
`conditions`, `replicates`, `representation`, `assay`, `layer`, `clusters`. Every
field has `status` (PASS/FAIL/UNKNOWN), `required` (boolean), `requirement` (reference
alias/field), `expected` and `observed` (bounded display summaries), `source`
(evidence source including declaration labels) and `reason`. Exact authoritative
refs live in `references`; summaries are not reusable machine authority. Summary
strings are limited to 100 characters with an explicit ellipsis when abbreviated.

FAIL means observed contradiction; UNKNOWN means missing or insufficient evidence.
Malformed/absent authority keys are UNKNOWN, while duplicate observed cells are
FAIL. The deterministic decision is BLOCKED iff any required field is not PASS.
Optional FAIL/UNKNOWN remain visible. This is a voluntary checkpoint result, not
an execution receipt, stored scientific approval or an enforcement boundary.
