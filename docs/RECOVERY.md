# Restore a declared file layout

A working ZIP preserves selected bytes and registry bindings. It does not recreate the relative file layout a script may need. The examples [Python](../examples/recovery_python.py) and [R](../examples/recovery_R.R) restore a **reviewed, finite** layout from an imported working ZIP. They do not execute code, install a runtime, infer imports, rebind the ledger or claim that the result is reproducible.

Register the JSON manifest as an ordinary DATA artifact. Include its exact DATA ref, the target FIG ref, and all declared payloads in the reviewed `preview_export("working", include=...)` call. Import the ZIP to a new root with the existing `ProjectBundle.import_zip` API. The manifest must be available through `get_data(ref=manifest_ref).path`. Review the full manifest before applying it.

Manifest version `biodataledger-recovery/1` has exactly these fields:

```json
{
  "version": "biodataledger-recovery/1",
  "figure_ref": {"project_id": "PROJECT-UUID", "id": "FIG-001", "revision": 1},
  "files": [
    {"source": {"kind": "record", "ref": {"project_id": "PROJECT-UUID", "id": "DATA-001", "revision": 1}}, "destination": "data/input.csv", "sha256": "64 lowercase hexadecimal characters", "size": 18, "purpose": "selected input"},
    {"source": {"kind": "code", "analysis_ref": {"project_id": "PROJECT-UUID", "id": "ANA-001", "revision": 1}, "locator": {"kind": "project", "value": "scripts/plot.py"}, "sha256": "64 lowercase hexadecimal characters"}, "destination": "scripts/plot.py", "sha256": "64 lowercase hexadecimal characters", "size": 120, "purpose": "declared entrypoint"}
  ],
  "entrypoint": "scripts/plot.py",
  "working_directory": ".",
  "import_roots": ["scripts"],
  "external_requirements": ["Python version and packages require review"]
}
```

Replace the illustrative UUID, digests and sizes with exact recorded values. A record source must be an exact DATA or FIG revision with a recorded digest. A code source must match the target figure's exact ANA revision, code locator and digest. Register any supporting file outside that analysis as a separate DATA artifact. Snapshotted code is preferred. All destinations are safe relative paths; `.` is allowed only for working directory and import roots. The entrypoint must be one of the listed files. External requirements state known needs and unknowns; they are not install commands.

Python (place the example module beside your script, or run from the repository's `examples/` directory; replace the illustrative project/output paths):

```python
from biodataledger import ProjectBundle
from recovery_python import preview_recovery, apply_recovery

project = ProjectBundle.open("imported-project")
manifest_path = project.get_data(ref=manifest_ref).path
preview = preview_recovery(project, manifest_path)
print(preview)  # Review files, mapping, entrypoint, cwd, import roots and requirements.
result = apply_recovery(project, manifest_path, "new-recovered-layout", preview)
```

R (after `source("examples/recovery_R.R")`):

```r
library(BioDataLedger)
project <- ProjectBundle$open("imported-project")
manifest_path <- project$get_data(ref = manifest_ref)$path
preview <- preview_recovery(project, "imported-project", manifest_path)
print(preview)
result <- apply_recovery(project, "imported-project", manifest_path,
                         "new-recovered-layout", preview)
```

Both helpers hash the entire declared source set at preview, recheck it before apply, copy into a sibling staging directory, verify copied bytes and claim a new destination exclusively before publication. A filesystem failure during publication can leave a partial directory that must be inspected; the helpers report this explicitly. They refuse missing/corrupt sources, symlinks, unsafe or colliding destinations, and existing output. The imported registry and bindings remain in their original root. A separate person must assess the declared runtime and, if authorized, run and compare the recovered analysis.

The R example uses BioDataLedger's internal bounded JSON reader because the installed package exposes no public manifest parser. This coupling is limited to manifest intake; record and source inspection use public getters.
