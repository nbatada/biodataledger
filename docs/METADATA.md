# Continuous sample-to-analysis metadata

Available in the local 0.19.0 build. The published 0.18.0 source does not include
these methods. Install the reviewed 0.19.0 build into a separate environment/library
before starting a new metadata-enabled project. Both native clients must support
this version; opening such a project with an older client is intentionally refused.
Existing projects are unchanged until you explicitly use this workflow.

## Start with the sample sheet

The biological sample sheet is recorded before sequencing files exist. Later
metadata extends that history through acquisition, QC, analysis and interpretation.
BioDataLedger stores exact table revisions and their relationships; it does not
infer experimental facts or scientific acceptance.

| Category | What it describes |
| --- | --- |
| `sample_preparation` | Donor/mouse, specimen, tissue, treatment/control, collection, sorting and preparation batch |
| `acquisition` | Library/assay, input amount, pooling, run, depth and raw-file identities |
| `processing_qc` | Processing methods, QC measurements, inclusion/exclusion and reasons |
| `analysis` | Representation, normalization, features, embeddings, clustering run/resolution and assignments |
| `annotation` | Biological labels, their evidence, review state and corrections |
| `result` | Meaning of retained quantities: observation unit, denominator, estimator, aggregation and presentation |

These categories apply across projects and assays. Column names are your own;
fields such as cancer type or treatment are not required for every study. Supply
`required_columns` for the actual task and `units` for relevant measurements.
All imported values remain text: `001`, literal `NA` and `0` keep their meanings.
An empty optional field is unreported. Explicit terms such as `not_applicable`
can distinguish other missingness meanings; the package does not invent them.

## User columns and BioDataLedger fields

You choose the scientific column names and values. BioDataLedger copies the table
without renaming columns or inventing identifiers. It reserves **`bl_`** for its
new continuous-metadata bookkeeping: for example `bl_ref`, `bl_category`,
`bl_rows`, `bl_status`, `bl_issues` and `bl_categories` in API results.
The rows inside `bl_rows` retain the original source-column names. Exact record
references still use the established `project_id`, `id`, `revision` fields;
user-supplied link declarations and units mappings also retain their names.

A unique sample ID is sufficient for the sample sheet. Mouse/donor ID is optional
unless you explicitly require it. Individual samples and pools can coexist, with
columns such as `sample_type`, `pool_id`, `mouse_id`, `timepoint`, `tissue`,
`sorted_population` and `cells_recovered` when those facts are available. Blank
optional mouse IDs stay blank; no fictitious animals or longitudinal pairings are
created. Record known pool membership in a separate mapping table keyed by both
sample ID and mouse ID, linking only known identities. Unknown membership remains
unknown. Tissue and cell-type subsamples do not automatically become independent
biological replicates.

## First-project setup

Use your existing sample CSV, with a unique, nonblank identifier for each row.
The caller names the authority: for example, a reviewed biologist's sample sheet.
This is a declared source, not authenticated consent or proof of biological truth.

Python:

```python
from biodataledger import ProjectBundle

p = ProjectBundle.create("My study", project_dir="/existing/new/project")
samples = p.register_metadata(
    "/path/to/samples.csv", "sample_preparation", ["sample_id"],
    authority="Investigator-reviewed sample sheet",
    reason="Record the experimental samples before acquisition",
    required_columns=["donor_id", "treatment"],
)
p.set_current(samples, "sample_sheet", "Use the reviewed sample sheet")
p.save_and_confirm()
```

R:

```r
library(BioDataLedger)
p <- ProjectBundle$create("My study", project_dir = "/existing/new/project")
samples <- p$register_metadata(
  "/path/to/samples.csv", "sample_preparation", c("sample_id"),
  authority = "Investigator-reviewed sample sheet",
  reason = "Record the experimental samples before acquisition",
  required_columns = c("donor_id", "treatment")
)
p$set_current(samples, "sample_sheet", "Use the reviewed sample sheet")
p$save_and_confirm()
```

Replace the example required fields with those appropriate to your study. You can
start with a sample sheet alone. Raw data need not exist yet. Opening an existing
project uses `ProjectBundle.open` or `ProjectBundle$open`, not another `create`.
To recover the saved sample-sheet reference, use `get_data(purpose="sample_sheet")`.
The legacy creation argument `metadata=` remains a file locator; it does not replace
explicit categorized metadata registration.

## Add acquisition and later stages

Suppose `libraries.csv` contains `library_id,sample_id,rna_input`. A pooled library
has multiple rows, one per contributor, so use a composite key. The link explicitly
checks that every contributor exists in the pinned sample sheet.

```python
libraries = p.register_metadata(
    "libraries.csv", "acquisition", ["library_id", "sample_id"],
    authority="Sequencing core delivery",
    reason="Record library preparation and pooling",
    links=[{"ref": samples, "columns": ["sample_id"],
            "target_columns": ["sample_id"]}],
    units={"rna_input": "ng"},
)
```

R uses a list of links, each a named list:

```r
libraries <- p$register_metadata(
  "libraries.csv", "acquisition", c("library_id", "sample_id"),
  authority = "Sequencing core delivery",
  reason = "Record library preparation and pooling",
  links = list(list(ref = samples, columns = c("sample_id"),
                    target_columns = c("sample_id"))),
  units = list(rna_input = "ng")
)
```

Link columns must match the referenced table's complete key, in the supplied order.
Blank, partial, duplicate or unmatched keys are rejected. A link validates the
reported relationship; it does not verify experimental sample identity. Separate
mapping tables represent splits, pools and repeated acquisition without pretending
a technical library is a biological replicate. Do not guess donor assignment for
unassigned observations; record those separately without a false sample link.

Use the same registration method for processing/QC, analysis, annotation and result
tables. Keep exclusion flags and reasons as explicit columns, retaining excluded
rows. Bind an exclusion to its particular dataset or analysis: absence of paired
TRA/TRB can exclude a cell from receptor analysis while RNA analysis remains valid.
The package does not apply inclusion flags or alter scientific objects.

## Pin metadata to the data or analysis that used it

```python
raw = p.register_data("counts.csv", role="analysis_ready", hash=True)
data = p.bind_metadata(raw, [libraries, qc], "Metadata for this retained dataset")
analysis = p.register_analysis("Reviewed analysis", [data], code="analysis.py")
p.save_and_confirm()
print(p.metadata_view(analysis))
print(p.check_metadata(analysis, required_categories=["sample_preparation",
                                                     "acquisition", "processing_qc"]))
```

Here `qc` is a previously registered processing/QC table. R uses the same methods
with `$`, `list(libraries, qc)` and `c(...)` for category names. `bind_metadata`
returns a **new record revision**; use that returned reference downstream. Its list
replaces the subject's previous direct metadata bindings. Linked source tables are
followed at their exact revisions, so the sample sheet need not be copied into every
stage. Binding metadata does not check the rows of a scientific matrix.

Analyses inherit metadata by following their exact DATA inputs. Linked figures
follow their exact analysis. Metadata views do not scan unrelated project files or
choose whichever sheet is newest. Protected execution records cannot be rebound;
retain their historical evidence and use an appropriate new ordinary analysis.

## Inspect and check

- `metadata_view(ref)` groups recorded descriptors under all six categories. It
  uses loaded registry metadata only; it does not read tables or scientific data.
- `get_metadata(ref, limit=20, offset=0)` verifies the selected table bytes and
  returns a page of its rows, column names, keys, authority and links.
- `check_metadata(ref, required_categories=...)` explicitly reads and verifies the
  relevant tables and their links. Default required category: `sample_preparation`.

`bl_status="PASS"` means the declared structural metadata requirements passed. `bl_status="UNKNOWN"` means
required metadata or files are unavailable, or the bounded view is incomplete.
`bl_status="FAIL"` reports invalid, changed or conflicting metadata. Different nonblank values
for the same category/key/column across attached authorities are conflicts; the
package does not silently select a winner. Different categories or granularities
remain separately visible rather than being flattened into a misleading join.

This is a grouped metadata view with explicit relationship checks, not an automatic
wide cell-by-all-metadata join. The report always states that matrix alignment and
scientific acceptance were not assessed. Use supported R live-object checks when
appropriate, and apply scientist-reviewed assay-specific validation independently.
No arbitrary interpreter is prevented from bypassing these voluntary checks.

## Correct metadata without rewriting the past

```python
updated_labels = p.register_metadata(
    "corrected_labels.csv", "annotation", ["sample_id", "cell_id"],
    authority="Reviewed annotation table", reason="Correct a provisional label",
    ref=labels, links=[{"ref": clusters, "columns": ["sample_id", "cell_id"],
                        "target_columns": ["sample_id", "cell_id"]}],
)
updated_analysis = p.bind_metadata(
    analysis, [updated_labels], "Use reviewed labels for subsequent work"
)
p.save_and_confirm()
```

`labels` and `clusters` are exact previously registered metadata refs. Correct only
the latest table revision, retaining its category and keys. Earlier source snapshots
and analysis bindings remain available. Changing a global current-purpose selection
is a separate explicit action. A clustering resolution change requires a new
clustering analysis/assignment table; renaming a cluster is an annotation revision.
Sorted population and inferred cell type belong to different categories.

## Storage, sharing and limits

Registration preserves a managed, byte-identical CSV snapshot with a SHA-256 digest.
Use the actual source file, not a symbolic-link filename. Replacing a managed
snapshot with a symbolic link is rejected, even if the target has identical bytes.
It never overwrites the supplied sheet. Snapshot files live outside registry JSON;
metadata-only inspection does not load the tables. This version accepts UTF-8 CSV
(including BOM), comma or explicit tab delimiter, up to 64 MiB and 256 columns.
Paged reads return at most 200 rows; graph traversal is limited to 1,000 records and
reports truncation. Large source matrices are not loaded, converted or stored here.

A failed registration removes its own newly created snapshot and preserves pending
work. A failed save leaves staged changes available for reconciliation. Existing
atomic/stale-save protections still apply. As elsewhere, a recorded digest is not
permanent preservation if someone later deletes the managed file.

A working ZIP must explicitly include every intended metadata table payload and any
data the recipient needs. Selecting a subject does not recursively include all its
metadata files. Context-only ZIPs preserve references but cannot verify absent table
bytes. Both modes include full registry metadata/history; review privacy before sharing.

See the executable synthetic lifecycle in [Python](../examples/metadata_python.py)
and [R](../examples/metadata_R.R). The examples make no biological claims and do not
use real project data.
