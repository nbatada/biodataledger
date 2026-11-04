# Retained inputs for a new analysis or redraw

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

Only the chosen selector is resolved and passed to the loader. Work one stage
at a time: resolve/load, compute and save the real output, then retain it.
Registration records declared provenance. A matching snapshot or hash records
file bytes at its check time; it does not prove that a native object stayed
unchanged, that the object was consumed by computation, or that the analysis has
scientific approval. Re-resolve when a fresh check is needed.

`save()` commits all pending edits on the opened project handle, not only this
registration. Its successful return does not grant scientific approval.
