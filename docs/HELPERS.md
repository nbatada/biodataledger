# Find and reuse functions

Available in the local 0.21.1 source build. A helper is a registered reusable function,
not an analysis result or proof of approval. Source modules and shared packages use
the same catalogue in the current project. BioDataLedger never searches other projects
unless their roots are supplied explicitly, imports a function, installs a package or
runs a helper automatically.

## Reuse, extend, then create

Before writing a function, search for a registered implementation and inspect its
inputs, parameters, outputs and limitations.

1. Reuse it with different inputs or supported parameters when it fits.
2. If needed, extend the general implementation. Test earlier behavior and the new
   capability; register a new helper revision deliberately. Editing a shared library
   still requires permission to change that library.
3. Create a separate function only when the existing one cannot reasonably support
   the requirement. Explain the specific gap; avoid copying its implementation.

Search finds candidates, not scientific equivalence. An unregistered function may
exist outside the search scope. Registration and passing tests do not authenticate
scientific approval or force an agent to reuse code.

## Register an existing source function

Suppose your existing `R/table_helpers.R` defines:

```r
validate_required_columns <- function(table, required) {
  setdiff(required, names(table))
}
```

Register its purpose and calling instructions through your existing project handle:

```r
helper_ref <- project$register_helper(
  "Required columns", language = "R", purpose = "Check required table columns",
  source = "R/table_helpers.R", function_name = "validate_required_columns",
  contract = list(
    inputs = "A data.frame",
    parameters = "required: character vector of column names",
    outputs = "Missing column names; empty when all are present",
    example = "validate_required_columns(table, c('id', 'value'))",
    limitations = "Checks names only, not values or scientific validity"
  ), tags = list("table", "columns")
)
project$save()
```

Source files are explicit: `source` accepts one path or up to 20 selected paths.
Code is hashed and snapshotted by default using existing per-file limits. Include
required local supporting modules explicitly; imports and package dependencies are
not discovered. Original locations and snapshot hashes are retained, but the package
does not rebuild a runnable module directory or environment. `snapshot_code=FALSE`
is an explicit hash-only option with weaker recovery. Keep declared code dependencies
and environment requirements in the call contract.

In Python the same methods use `function="validate_required_columns"`, a dictionary
for `contract`, and lists for `tags`, `source` and `helper_refs`.

## Find, check, and call

```r
candidates <- project$find_helpers("required columns", language = "R")
# Inspect candidates and coverage; choose a suitable exact reference explicitly.
card <- project$get_helper(helper_ref, verify = "sha256")
stopifnot(card$verification$status == "pass")

# Ordinary R execution in the intended process, after reviewing the selected source.
source("R/table_helpers.R")
missing <- validate_required_columns(table, required = c("id", "value"))
```

Changing the table or column names does not require rewriting the function. Hash
verification covers declared current source bytes at check time. It does not verify
undeclared dependencies, future changes, scientific suitability or actual execution.
Missing/mismatched files fail; unreadable files remain unknown. After an explicit save,
`get_helper(ref, verify="snapshot")` checks the retained source snapshots and returns
their resolved file paths, including after import. This verifies retained bytes rather
than the current working source. Hash-only registrations report `not_retained`; there
is no silent fallback between current source and snapshots. Default
`get_helper(ref)` is metadata-only and reports that identity was not checked.

## Reuse a helper from another selected project

Pass only project roots you are authorized to inspect. Discovery reads each selected
saved `project.json` only; it does not inspect sibling projects, source code, payloads,
live sessions or unsaved edits. The combined search is bounded to eight projects,
including the current one, and reports per-source coverage and failures.

```python
report = project_b.find_helpers("required columns", sources=[project_a_root])
chosen = next(card for card in report["helpers"]
              if not card["source_project"]["current"])
local_ref = project_b.register_helper_from(chosen)
project_b.save()  # adoption never saves implicitly
```

R uses `project_b$find_helpers("required columns", sources=list(project_a_root))`
and `project_b$register_helper_from(chosen)`. A candidate includes source identity,
location, exact helper ref and saved-registry token. Adoption rereads the source and
rejects token changes; it stages one local DEC pin. B analyses use that local ref.
`get_helper` exposes its typed `helper_origin` in `foreign_refs`.

Source-helper adoption copies only chosen retained snapshots into B after hash checks;
it never reinterprets A working paths. Package helpers retain their declared
package/version/function without copying, installing or loading a package. A later A
revision never updates B. Origin is declared provenance, not execution, approval or
scientific validity.

When retaining work, pass the exact helper reference to `register_analysis` alongside
the selected scientific DATA inputs. `helper_refs=list(helper_ref)` is separate from
`inputs`; in Python use `helper_refs=[helper_ref]`. Save the approved registry edits
explicitly. These links record declared implementation use, not observed execution.

## Shared package functions

Use `package`, `version` and the function name instead of `source`. For example,
`package="myhelpers", version="1.2.0", function_name="validate_required_columns"`
describes a hypothetical shared R library; it does not install that library or
assert that it exists on this computer. No wrapper file or package-source copy is needed.

`get_helper(ref, verify="identity")` inspects native package version metadata without
loading the target. A match is qualified: version strings do not prove byte identity,
function existence, dependency compatibility or which code executed. Python checks
installed distribution metadata, not the state of an already imported module. R uses
an already loaded namespace when present, otherwise the selected installed package.
An opposite-language check is unknown. A missing package or version mismatch requires
resolution; never silently upgrade or replace a loaded namespace. Package SHA-256
verification is unavailable because package source bytes are not captured by this API.

## Extend without rewriting history

An optional type check could extend the column validator while preserving name-only
behavior. Test both modes and call `register_helper(..., ref=helper_ref, reason=...)`
with the updated contract and source or package pin. It creates a new revision of the
same helper. A stale revision is rejected; lifecycle changes use existing
`update_record(ref, changes, reason)` with only a `status` change. Other metadata/code changes use the
helper writer.

Earlier analyses remain linked to their original helper revision. A new capability
does not itself invalidate earlier results. A bug fix may require scientific review
and new runs, never an automatic historical rewrite. Use the existing extended graph
with the exact old helper reference to inspect `declared_helper_use` edges to analyses.
Revision links are not evidence of code consumption. Only recorded use is visible;
actual scientific impact and rerun decisions require review. Retain reruns separately.

## Search, handoff and compatibility limits

Search is case-folded literal all-term matching over name, purpose and tags, with an
optional language filter. It inspects the first 100 latest DEC records in stable ID
order and returns at most 20 cards (default 5). Read the coverage fields: a partial
search is not evidence that no helper exists. Exact inspection remains available
outside that window. Cards shorten long text with explicit field notices.
Current-project reports stay within 16 KiB; explicit cross-project reports stay within
32 KiB and may omit whole cards. Discovery does not read payloads or source code,
write projects, or hash scientific files; it hashes selected saved registry bytes to
bind a candidate token.

Helper descriptions use the existing DEC record type with a versioned `bl_helper`
descriptor. Analyses retain exact references in `details.bl_helper_refs`. This avoids
new record kinds or schema migrations. An exact helper revision can describe a source
module in one revision and a shared package in a later revision.

Working exports include helper source snapshots only when that helper revision is
explicitly selected. Selecting an analysis does not implicitly package helper files.
Existing archive rules still include registry metadata/history; package dependencies
remain external and may be unavailable after import. Import never executes code.
Old 0.20.0 clients preserve helper-origin metadata opaquely during unrelated saves but
cannot create or enforce cross-project adoption semantics. Old 0.19.3 clients preserve
helper metadata opaquely but cannot enforce typed helper records or links.
