# Resume a saved project

BioDataLedger resumes its saved registry. It does not reconstruct an interrupted
native analysis, restore an unsaved Seurat/AnnData object, or decide whether a
partly completed analysis is valid.

## Short procedure

1. If the original R or Python kernel still runs, keep its live handles and
   unsaved scientific objects. Check the registry once with `status()`; do not
   restart the kernel, reload modules, or replace those handles merely to inspect
   the registry. That handle can contain pending edits or be stale after another
   writer saves; it is not a fresh inspection of saved state.
2. Before an intentional handoff, record an authorized next task with
   `set_context()` and, only when a real decision was made, `record_decision()`
   against its exact target refs. Save that meaningful batch once. These calls do
   not run automatically or capture an interrupted analysis.
3. In a new process, reopen the explicit project root and inspect `status()`.
   Recover only the exact saved DATA, FIG, ANA, or DEC references needed for the
   saved next task. If an exact execution receipt exists, inspect it. A started
   or incomplete receipt leaves completion ambiguous; otherwise continue the
   authorized next task. Load scientific objects with their native loader after
   resolving the selected input; the registry does not serialize large live objects.

Python:

```python
from biodataledger import ProjectBundle

p = ProjectBundle.open(project_dir="[absolute project folder]")
print(p.status())
input_record = p.get_data(ref="[exact DATA ref]")
decision = p.get_decision("[exact DEC ref]")  # if relevant to the next task
# At an authorized handoff only:
# p.set_context({"next_task": "[specific next task]"})
# p.record_decision("[actual decision]", "[reason]", [input_record.ref])
# p.save_and_confirm()
```

R:

```r
library(BioDataLedger)

p <- ProjectBundle$open(project_dir = "[absolute project folder]")
print(p$status())
input_record <- p$get_data(ref = "[exact DATA ref]")
decision <- p$get_decision("[exact DEC ref]") # if relevant to the next task
# At an authorized handoff only:
# p$set_context(list(next_task = "[specific next task]"))
# p$record_decision("[actual decision]", "[reason]", list(input_record$ref))
# p$save_and_confirm()
```

`status()` describes the loaded registry handle, including unsaved registry
changes. It does not report arbitrary live objects in an R/Python kernel. Do not
call `save_and_confirm()` to make an interrupted run look complete: it commits all
pending registry edits on that handle.

## Copy-paste agent prompt

```text
Resume this BioDataLedger project without changing scientific choices or
inventing completion for interrupted work.

Project folder: [absolute path]
Task: [specific next task]
Known exact refs: [DATA/FIG/ANA/DEC refs, if available]

Open the explicit root once in a fresh process and inspect status once. If the
original kernel survives, preserve its live handles, unsaved Seurat/AnnData
objects, scripts and outputs; do not restart, reload, replace, or auto-serialize
them. Its handle may be stale or have pending edits, so do not treat it as a fresh
saved-state inspection. Use ProjectBundle.open and exact getters for the refs
needed for the stated task. Resolve a selected input with verify="sha256" before
its native loader when the task needs the file. Inspect an exact execution receipt
when one exists; report started or incomplete work as ambiguous, otherwise continue
the authorized task. Before an intentional handoff only, use set_context for a
specific next_task and record_decision only for an actual decision with exact
targets, then save one authorized meaningful batch. Do not save per turn or flush
unrelated pending edits. Report saved-state findings and live-session limitations.
```
