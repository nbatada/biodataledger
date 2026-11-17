# Find and reuse functions

BioDataLedger 0.21.1 supports explicit shared-library discovery and adoption in
native R and Python. A helper card describes a source function or package function.
Discovery and adoption never import, execute or install it. Registration is not
scientific approval or proof that an analysis used the function.

## Library layout and names

One convention is a Git repository at `~/git/lib`, with files directly at its root:

```text
~/git/lib/
├── nb_utils_general.R
├── nb_utils_general.py
├── nb_utils_plotting.R
├── nb_utils_plotting.py
├── nb_utils_scrnaseq.R
├── nb_utils_scrnaseq.py
├── nb_utils_bulkrnaseq.R
└── nb_utils_bulkrnaseq.py
```

Create only modules you need. R and Python should have matching responsibilities;
there is no requirement to implement every function twice. The path and names are
user conventions, not hardcoded package requirements.

They are one user's optional convention, not a global default. Another user may keep
helpers under different names and locations, use more than one approved library root,
and keep a saved helper registry in each library they want to search. Pass those explicit
roots to `find_helpers(sources=...)`;
BioDataLedger does not infer a home-directory path or restrict helper names.

If project settings centralize one shared folder, a readable name is
`shared_custom_library_folder`. Pass `[settings["shared_custom_library_folder"]]`
as `sources` in Python, or `list(settings$shared_custom_library_folder)` in R.
The examples below use this caller setting. It is not a ProjectBundle initialization
parameter or stored registry field; BioDataLedger does not read it automatically or
enforce reuse by arbitrary scripts. For several libraries, pass the selected roots
explicitly through the same `sources` list.

Use `nb_utils_<domain>_<verb>_<object>` for shared functions:

| Module | Responsibility | Example name |
| --- | --- | --- |
| `nb_utils_general.R` / `.py` | Reusable table operations and identifier checks | `nb_utils_general_check_ids()` |
| `nb_utils_plotting.R` / `.py` | Reusable plots and themes using prepared results | `nb_utils_plotting_draw_dotplots()` |
| `nb_utils_scrnaseq.R` / `.py` | Single-cell operations with explicit assay/layer and parameters | `nb_utils_scrnaseq_summarize_qc()` |
| `nb_utils_bulkrnaseq.R` / `.py` | Bulk RNA-seq operations with explicit design and contrasts | `nb_utils_bulkrnaseq_fit_deseq2()` |

These names illustrate the convention; BioDataLedger does not supply those scientific
functions. Keep project paths, sample selections, genes and scientific decisions in
caller code. A prefix identifies shared code, not validated code.

## What each project retains

| Location | Contents |
| --- | --- |
| Shared library repository | Source modules, tests, examples and Git history |
| Library-root BioDataLedger registry | Helper contracts, exact revisions and selected code snapshots |
| Analysis-project registry | Deliberately adopted local helper pins, exact source origins and retained copies |
| Retained analysis | Exact local `helper_refs`, separate from scientific input references |

The library checkout is a development location. Recording a Git commit does not make
`source()` or Python imports load that revision. BioDataLedger records helper revisions
and source hashes; it does not automatically capture, check out or restore Git commits.
Load the selected retained source, or use a separately pinned and verified environment.

## Reuse, extend, then create

Search for a suitable implementation and inspect its inputs, parameters, outputs,
dependencies and limitations. Reuse it when it fits. Extend the general function with
old/new behavior tests when justified. Create another function only for a specific gap.

Changing a shared library requires authority to edit that repository. Use one writer
at a time. A new revision is adopted deliberately by each project; it does not update
old pins or rerun analyses. A local derivative retains its declared origin but does not
claim to remain identical to the source. Scientific impact and rerun decisions require
scientist review.

## Register a library function

First verify the actual loaded client's capabilities. This workflow uses
`register_helper`, `find_helpers(sources=...)`, `get_helper`, `register_helper_from`
and `register_analysis(helper_refs=...)`. A checkout or installation report does not
update a live namespace. Missing methods require explicit setup or upgrade; do not
install, restart a session or edit registry JSON to bypass the problem.

Use an existing registry opened at the chosen library root. Creating a new library
registry with `ProjectBundle.create` / `ProjectBundle$create` belongs to authorized
setup; discovery never initializes one. In the following R snippets, `library_project`
is that library handle and `project` is the current analysis handle in the intended
process. The complete runnable examples below create their own synthetic fixtures.

Suppose `~/git/lib/nb_utils_general.R` contains this reviewed function:

```r
nb_utils_general_check_columns <- function(table, required) {
  setdiff(required, names(table))
}
```

Register its contract in the library ledger:

```r
source_ref <- library_project$register_helper(
  "Required columns", language="R", purpose="Check required table columns",
  source="nb_utils_general.R", function_name="nb_utils_general_check_columns",
  contract=list(
    inputs="A data.frame", parameters="required: ordered column names",
    outputs="Missing required names in the supplied order",
    example="nb_utils_general_check_columns(table, c('id', 'value'))",
    limitations="Column presence only; no scientific validation"
  ), tags=list("general", "columns")
)
library_project$save()
```

Python uses `function="nb_utils_general_check_columns"`, a dictionary for `contract`,
and lists for `source`, `tags` and references. Use a Python module for Python execution.

## Find, inspect, adopt, save, verify, then call

Search only explicitly selected roots. Inspect the returned cards and per-source
coverage, then select a full exact `approved_source_ref`. Never select the first or
newest hit automatically. The source handle below is read-only during adoption.

```r
settings <- list(shared_custom_library_folder=path.expand("~/git/lib")) # Example caller settings.
library_root <- settings$shared_custom_library_folder
report <- project$find_helpers("required columns", language="R", sources=list(library_root))
# approved_source_ref is the full reference deliberately selected after inspecting report.
selected <- Filter(function(card) {
  identical(card$ref, approved_source_ref) &&
    identical(card$source_project$location, normalizePath(library_root))
}, report$helpers)
stopifnot(length(selected) == 1L)
chosen <- selected[[1L]]
source_card <- library_project$get_helper(chosen$ref) # Inspect contract and declared source identity.
local_ref <- project$register_helper_from(chosen)
receipt <- project$save_and_confirm() # Only after confirming all pending edits belong to approved work.
stopifnot(receipt$status %in% c("persisted", "no_changes"),
          identical(receipt$registry_written, receipt$status == "persisted"))
```

A saved-source change invalidates its candidate token: refresh and review it instead
of changing the token or silently adopting another version. Source helpers retain only
selected saved snapshots resolved through source bindings, with their pinned hashes.
Missing/hash-only/drifting snapshots reject; there is no original-working-file fallback.
`get_helper(local_ref)$foreign_refs` exposes the exact declared source origin.

Verify **after saving**, because adoption only stages the retained files. For a reviewed,
single-file R helper and an already selected table:

```r
retained <- project$get_helper(local_ref, verify="snapshot")
stopifnot(retained$verification$status == "pass", length(retained$verification$files) == 1L)
helpers <- new.env(parent=baseenv())
sys.source(retained$verification$files[[1L]]$path, envir=helpers)
missing <- helpers$nb_utils_general_check_columns(table, required=c("id", "value"))
```

This is explicit caller execution. A separate namespace prevents ordinary name clashes;
it is not a security sandbox. Review code before loading it. A hash match establishes
byte identity at that check, not safety, scientific suitability or future immutability.
The [Python example](../examples/shared_library_python.py) shows the corresponding
verified retained-source load into a separate dictionary namespace.

When retaining a saved output, link it to its analysis. Here `table_ref` is the exact
registered input and `output_path` is the file actually written by the authorized work:

```r
analysis_ref <- project$register_analysis(
  "Check required columns", inputs=list(table_ref),
  method="Column presence", params=list(required=list("id", "value")),
  helper_refs=list(local_ref)
)
result_ref <- project$register_result(output_path, analysis_ref, hash=TRUE)
project$save()
```

These links declare helper use; they do not observe which function executed. Preserve
actual execution output or receipts separately. Never put a foreign helper ref directly
in analysis inputs or `helper_refs`; adoption returns the required local reference.

## Runnable R and Python workflows

Run from a compatible source checkout with installed native clients; 0.21.1 is tested:

```sh
python3 examples/shared_library_python.py --destination /tmp/bdl-shared-python-example
Rscript --vanilla examples/shared_library_R.R --destination /tmp/bdl-shared-r-example
```

Choose new destinations: both scripts reject an existing path before modifying it.
Omit `--destination` for temporary workspaces, which may be removed when the process
ends. They do not open your existing `~/git/lib`. Each example registers a real
`nb_utils_general_check_columns` function, adopts and executes retained v1 source on an
unrelated table, records a linked result, adds an optional strict argument in v2 and
executes both modes. It then reopens the ledger and checks old pins, source and outputs.
See the [R example](../examples/shared_library_R.R) and [Python example](../examples/shared_library_python.py).

Rscript here is a disposable demonstration process. In a real analysis, use the
scientist's existing authorized native session; these examples do not authorize replacing
its live objects or bypassing [managed-session ownership](R_SESSION.md).

## Package helpers and recovery limits

For a shared package, register `package`, `version` and the function name instead of
`source`. `get_helper(ref, verify="identity")` checks native package metadata without
importing/installing the target. A qualified match does not prove function existence,
source bytes, dependency compatibility or which code is loaded/executed. Python checks
installed distribution metadata; R uses an existing loaded namespace when present,
otherwise the selected installed package. Missing/mismatched versions need explicit
resolution, never silent upgrades or namespace replacement.

For source modules, register one to 20 explicit files. `verify="sha256"` checks declared
current source; `verify="snapshot"` checks retained source and returns its resolved paths.
Hash-only registration reports `not_retained`. `get_helper(ref)` alone is metadata-only.
Source snapshots do not reconstruct a module directory, relative imports, undeclared
support files or an execution environment. Use an appropriately pinned package/environment
for interdependent libraries; do not quietly switch to mutable working files.

## Discovery and sharing limits

Search uses case-folded literal matching of all terms over name, purpose and tags. It
examines the first 100 latest DEC records per selected source, returning at most 20 cards
(default 5). At most seven foreign roots plus the current handle are searched. Foreign
sources are saved registries, not unsaved sessions. No-match is not global absence.

Read errors, invalid sources, duplicate-UUID conflicts and omissions remain explicit.
Local reports are bounded to 16 KiB; cross-project reports to 32 KiB, omitting whole cards
when needed. Selection identity is not shortened. Metadata alone exceeding the cap causes
an explicit error. Discovery reads/hashes selected registry bytes only, not code or
scientific payloads, and performs no writes. Imported provenance remains qualified.

Working exports retain helper snapshots only when those exact helper revisions are
explicitly selected; selecting an analysis alone does not include them. Existing archive
rules still include registry metadata/history. Imports are inert. Old 0.20.0 clients
preserve origin metadata opaquely on unrelated saves but cannot enforce adoption semantics;
old 0.19.3 clients preserve helper metadata without enforcing its typed contract.
