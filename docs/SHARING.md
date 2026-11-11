# Share a reviewed project subset

Share a ZIP only after reviewing the complete registry metadata and history plus
the explicit payloads. A context ZIP carries metadata only. A working ZIP can
carry selected local files and relevant code snapshots; it does not prove a run,
scientific validity, or a usable recipient environment.

## Short procedure

1. Choose exact DATA and FIG references with the scientist. Save the authorized
   registry batch with `save_and_confirm()`, then reopen or inspect a fresh,
   clean handle before sharing.
2. Build a `preview_export("working", include=...)` plan with every payload the
   recipient needs, including `.rds` or `.h5ad` files when intended. Review its
   state, omissions, missing files and inventory. A selected figure does not
   recursively include its input data or script dependencies.
3. Export the unchanged reviewed plan to a new ZIP path. The recipient imports it
   into a new, nonexistent project root whose parent already exists, then opens
   retained objects with the appropriate native R or Python loader.

Python:

```python
from pathlib import Path
from biodataledger import ProjectBundle

p = ProjectBundle.open(project_dir="[absolute project folder]")
print(p.status())
input_record = p.get_data(ref="[exact DATA ref]")
figure = p.get_figure("[exact FIG ref]", compact=True)
receipt = p.save_and_confirm()                 # only an authorized pending batch
plan = p.preview_export("working", include=[input_record.ref, figure["ref"]])
# Review plan["state"], plan["omitted"], plan["missing"], and plan["files"] first.
archive = Path("[output ZIP in an existing folder]")
result = p.export_zip(plan, archive)
q = ProjectBundle.import_zip(archive, "[new nonexistent recipient project root]")
print(q.status())
```

R:

```r
library(BioDataLedger)

p <- ProjectBundle$open(project_dir = "[absolute project folder]")
print(p$status())
input_record <- p$get_data(ref = "[exact DATA ref]")
figure <- p$get_figure("[exact FIG ref]", compact = TRUE)
receipt <- p$save_and_confirm()                   # only an authorized pending batch
plan <- p$preview_export("working", include = list(input_record$ref, figure$ref))
# Review plan$state, plan$omitted, plan$missing, and plan$files first.
archive <- "[output ZIP in an existing folder]"
p$export_zip(plan, archive)
q <- ProjectBundle$import_zip(archive, project_dir = "[new nonexistent recipient project root]")
print(q$status())
```

Both export modes include the whole registry metadata and history, even for
omitted payloads. Redaction is unsupported, so do not export material whose
metadata should not be shared. Verify the plan rather than assuming a figure
brings its inputs, `.rds`, `.h5ad`, script imports, or any other dependency.
An import does not execute code, install an R/Python environment, or recreate a
working directory layout. See [recovery](RECOVERY.md) for an explicitly reviewed
layout-restoration workflow.

## Copy-paste agent prompt

```text
Prepare a BioDataLedger ZIP handoff without changing scientific choices.

Project folder: [absolute path]
Selected DATA ref(s): [exact ref(s)]
Selected FIG ref(s): [exact ref(s)]
Output ZIP: [new ZIP path in an existing folder]
Recipient project root: [new nonexistent root with an existing parent]

Open the explicit project root, inspect status once, and use the listed exact
refs. Do not infer or recursively include dependencies: list each intended
payload explicitly, including .rds or .h5ad files when requested. Before export,
explain that the ZIP carries the full registry metadata and history and that
redaction is unsupported. Save only an authorized pending registry batch. Create
preview_export("working", include=...) and stop for review of its state, omitted,
missing and file inventory. Export the unedited approved plan to the stated new
ZIP path. Demonstrate import_zip only into the stated new root; scripts remain
inert. Report omitted dependencies, native loader needs, environment/layout
limits, and the RECOVERY.md option for a reviewed file layout.
```
