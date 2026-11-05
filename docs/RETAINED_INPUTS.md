# Retained inputs for a new analysis or redraw

## Find, verify, and retain one result

When you know only a name, use `export_graph(format="structured", filters=...)`
with `asset_type="DATA"` or `"DEC"` and a text `query`. Inspect `nodes` and
`truncation`, which can flag missing relationships as well as missing nodes.
Follow `next_offset` to continue the record scan with the same filters and
unchanged handle. Even a page with one candidate may be incomplete. Ask for the
exact choice if it has not been recorded; a known exact ref can be resolved
independently of the search. Use `get_decision(ref)` to inspect a chosen decision;
its presence does not authenticate approval, and it is not an analysis DATA input.

If you already know the selector, use `get_data(role=...)` for a unique active
match among latest revisions or `get_data(purpose=...)` for the recorded current
choice. List purpose
names with `list(project.summary()["current"])` in Python or
`names(project$summary()$current)` in R. Keep the returned exact reference;
do not guess a revision from a bare ID or reselect by role or purpose later.

For work you already intend to retain, resolve the selected DATA with
`verify="sha256"` before loading it. Graph searches and ordinary getters use
metadata only. Strict resolution requires a registered digest and rereads the
selected file to compare it. Use `hash=True` / `TRUE` when registering a new input
or plain-file result you will verify this way. Stage `register_analysis()` before
writing outputs so invalid input kinds, design refs and known declared scope
conflicts surface early. Unknown context stays unknown; verify any context your
task requires. Use `code=` for the script snapshot; it does not need a separate
DATA record. Stage results after saving the actual files.

Save either block as a script. Run the Python script with `python workflow.py`
or the R script with `Rscript workflow.R`, using the installed package. Each uses
disposable synthetic files and simulates a recorded purpose choice and decision.

```python
from pathlib import Path
from tempfile import TemporaryDirectory

from biodataledger import ProjectBundle

with TemporaryDirectory(prefix="synthetic-retention-") as directory:
    root = Path(directory)
    (root / "numbers.txt").write_text("2\n3\n", encoding="utf-8")
    project = ProjectBundle.create("Synthetic retention", root)
    source_ref = project.register_data("numbers.txt", "input", name="Toy counts", hash=True)
    project.set_current(source_ref, "sum", "Selected for this synthetic example")
    decision_ref = project.record_scientific_decision(
        "Toy sum convention", "Demonstration only",
        subjects=[{"ref": source_ref}], scientific_status="provisional")
    project.save_and_confirm()

    for kind, query in (("DATA", "Toy counts"), ("DEC", "Toy sum convention")):
        candidates = project.export_graph(format="structured",
            filters={"asset_type": kind, "query": query}, limit=5)
        print([node["ref"] for node in candidates["nodes"]],
              candidates["truncation"], candidates["next_offset"])
    selected = project.get_data(purpose="sum").ref
    decision = project.get_decision(decision_ref)
    print(decision["text"], decision["approval"])
    source = project.resolve_data(ref=selected, verify="sha256")
    analysis = project.register_analysis("Sum toy counts", inputs=[source.ref],
        code=Path(__file__).resolve(), method="Integer sum", params={"na_rm": False},
        design_ref=None)

    total = sum(int(line) for line in source.path.read_text(encoding="utf-8").splitlines())
    output = root / "sum-v1.txt"
    with output.open("x", encoding="utf-8") as handle:
        handle.write(f"{total}\n")
    result = project.register_result(output, analysis_ref=analysis, hash=True)
    receipt = project.save_and_confirm()
    print(total, result, receipt["status"])
```

```r
library(BioDataLedger)

run_example <- function() {
  script <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  root <- tempfile("synthetic-retention-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines(c("2", "3"), file.path(root, "numbers.txt"))
  project <- ProjectBundle$create("Synthetic retention", root)
  source_ref <- project$register_data("numbers.txt", "input", name = "Toy counts", hash = TRUE)
  selected_for_sum <- project$set_current(source_ref, "sum", "Selected for this synthetic example")
  decision_ref <- project$record_scientific_decision(
    "Toy sum convention", "Demonstration only",
    subjects = list(list(ref = source_ref)), scientific_status = "provisional")
  setup <- project$save_and_confirm()

  for (kind in c("DATA", "DEC")) {
    query <- if (kind == "DATA") "Toy counts" else "Toy sum convention"
    candidates <- project$export_graph(format = "structured",
      filters = list(asset_type = kind, query = query), limit = 5L)
    print(list(refs = lapply(candidates$nodes, function(node) node$ref),
      truncation = candidates$truncation, next_offset = candidates$next_offset))
  }
  selected <- project$get_data(purpose = "sum")$ref
  decision <- project$get_decision(decision_ref)
  print(list(decision = decision$text, approval = decision$approval))
  source <- project$resolve_data(ref = selected, verify = "sha256")
  analysis <- project$register_analysis("Sum toy counts", inputs = list(source$ref),
    code = normalizePath(script, mustWork = TRUE), method = "Integer sum",
    params = list(na_rm = FALSE), design_ref = NULL)

  total <- sum(as.integer(readLines(source$path)))
  output <- file.path(root, "sum-v1.txt")
  if (file.exists(output)) stop("Choose a new output path")
  writeLines(as.character(total), output)
  result <- project$register_result(output, analysis_ref = analysis, hash = TRUE)
  receipt <- project$save_and_confirm()
  print(list(total = total, result = result, status = receipt$status))
}

run_example()
```

Add related figures with `register_figure(..., analysis=analysis)` and the exact
result as a declared rendering input when applicable. Save the related batch once.
If a write or registration fails, stop before saving. Report which files were
written and which records are unregistered or still staged. If saving fails,
preserve the files and staged edits for reconciliation. The registry save commits
all pending edits on the handle; it does not roll back caller-created files.

## Revise an existing input or result

For an ordinary DATA record, use `update_record(ref, changes={"path": "counts-v2.txt"},
reason="Corrected export")` (R: `changes = list(path = "counts-v2.txt")`).
It hashes the new file and captures its path and digest in a revision of the same ID; existing
references and purpose choices stay pinned. For a typed result, use
`register_result(new_path, analysis_ref=producer, ref=old_result_ref, hash=True)`
(R: `hash = TRUE`). Use a new ID only for a distinct logical artifact. A shared
path or digest does not determine identity. To retain earlier bytes, keep prior
versioned paths unchanged or register each result revision with a managed copy
(`copy=True` / `TRUE`) before reusing its source path. Managed copies verify both
source and copied bytes.

`set_data_scope()` replaces the scope on a new DATA revision. Its top-level
fields are optional; omitted fields become unknown. Include any prior scope
values you intend to keep and pass the intended exact `design_ref` explicitly;
omitting it records unknown design. Scope and design changes do not move a
current-for-purpose pointer.

## Keep the resolved source with the loaded object

Use this pattern when starting a new, authorized analysis or redraw. It is not
a request to migrate a near-complete older project or to change an existing
helper's return type. Keep the one opened `ProjectBundle` handle, resolve one
selected input, and retain the native object with the returned source view.
These snippets assume `project` was opened at the explicit `project_root`, the
output directory already exists, and the named loader, renderer and save function
are supplied by your analysis. They are not standalone scripts.

```python
from pathlib import Path
from retained_input import load_retained_input, register_redraw  # copy examples/retained_input.py beside this script

data, source = load_retained_input(project, read_my_format, purpose="redraw")
# read_my_format, draw and save_redraw are native analysis functions.
# Work with data. If the purpose pointer changes now, source.ref does not.
output = Path(project_root) / "plots/redraw.svg"
if output.exists():
    raise FileExistsError(output)  # Choose a deliberate new/revisioned path instead.
save_redraw(draw(data), output)
retained = register_redraw(project, source, name="redraw", figure_path=output,
                            figure_type="embedding", code=Path(project_root) / "draw.py", method="manual redraw",
                            params={"colour": "sample"})
project.save()
```

```r
source("examples/retained_input.R")
loaded <- load_retained_input(project, readRDS, purpose = "redraw")
# draw_redraw and save_redraw are native analysis functions. Work with
# loaded$object, save the real output deliberately, then use loaded$source.
output <- file.path(project_root, "plots", "redraw.svg")
if (file.exists(output)) stop("Choose a deliberate new/revisioned output path")
save_redraw(draw_redraw(loaded$object), output)
retained <- register_redraw(project, loaded$source, "redraw", output,
                            "embedding", file.path(project_root, "draw.R"), "manual redraw", list(colour = "sample"))
project$save()
```

For a small redraw menu, choose the requested job before loading:

```python
from retained_input import load_selected_redraw_input

data, source = load_selected_redraw_input(
    project, {"umap": {"purpose": "umap"}, "qc": {"ref": qc_ref}}, requested_job, read_my_format)
```

Only the chosen selector is resolved and passed to the loader. The
`register_redraw` convenience function assumes the figure already exists. For
a planned retained output, use the explicit preflight above so an invalid
analysis declaration is caught before writing.
Registration records declared provenance. A matching snapshot or hash records
file bytes at its check time; it does not prove that a native object stayed
unchanged, that the object was consumed by computation, or that the analysis has
scientific approval. Re-resolve when a fresh check is needed.

`save()` commits all pending edits on the opened project handle, not only this
registration. Its successful return does not grant scientific approval.
