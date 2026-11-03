# BioDataLedger

**Resume your analysis without reconstructing its history.**

A research folder can contain several dataset versions, scripts and figures, with little indication of which belong together. Returning after a break—or handing the project to a colleague—can mean searching old code just to recover earlier choices.

BioDataLedger records the dataset revisions, cohort notes, code and parameters you associate with each retained analysis and figure. You can then retrieve a result’s recorded sources, find the input you designated for a task, and see what information is missing. It works in R and Python with your existing files.

Use it when your analysis spans multiple sessions, your datasets change, or someone else needs to understand and continue your work.

![Without BioDataLedger, the source of a saved CD8 figure is unclear. With BioDataLedger, an exact figure lookup retrieves its recorded input, analysis code and parameters.](docs/assets/biodataledger-provenance-gemini-v1.jpg)

The example illustrates records you supply; the package does not choose or verify the cohort for you.

[Install](#install) · [Examples](#record-data-analyses-and-figures) · [Conditions and levels](#conditions-and-levels) · [Agent instructions](#using-an-agent) · [API reference](docs/api/API_0.5.0.md)

## Install

Version **0.5.0** · MIT license · Tested on **macOS**. Install Python, R, or both. No AI service is required.

**R — install the tested version from GitHub**

Run this in R to install the verified 0.5.0 package at commit `a368f59`:

```r
if (!requireNamespace("remotes", quietly = TRUE))
  install.packages("remotes", repos = "https://cloud.r-project.org")

remotes::install_github(
  "nbatada/biodataledger",
  subdir = "r",
  ref = "a368f591189199b8d59fae9e447b8c6df49c02a7",
  upgrade = "never"
)
```

Then load it with `library(BioDataLedger)`.

**Source checkout — Python, repository examples, or an R source install**

```sh
git clone https://github.com/nbatada/biodataledger.git
cd biodataledger
```

**Python 3.9 or newer**

```sh
python3 -m venv .venv
.venv/bin/python -m pip install ./python
.venv/bin/python -c 'import biodataledger; print(biodataledger.__version__)'
```

Use `.venv/bin/python` or select this environment in your editor. Installation needs setuptools/wheel; the package has no Python runtime dependencies.

**R from the source checkout**

```sh
mkdir -p .r-library
export R_LIBS_USER="$PWD/.r-library"
Rscript -e 'install.packages(c("jsonlite", "digest", "zip", "uuid", "stringi"), repos="https://cloud.r-project.org")'
R CMD INSTALL -l "$R_LIBS_USER" r
Rscript -e 'library(BioDataLedger); print(packageVersion("BioDataLedger"))'
```

Skip the dependency installation if those packages are already available (`zip` ≥3.0.2). In a new shell, set `R_LIBS_USER` to the absolute path of `.r-library` before starting R. In an open R session, add that path with `.libPaths(c("/absolute/path/to/.r-library", .libPaths()))`.

Offline installation requires the build tools and dependencies to be available locally.

## Try it

From the repository root, run either synthetic example:

```sh
.venv/bin/python examples/trial_python.py "$PWD/trial-python"
R_LIBS_USER="$PWD/.r-library" Rscript examples/trial_R.R "$PWD/trial-r" "$PWD/examples/input-files"
```

Each creates a new project with one dataset, one analysis and two figures. Existing destinations are never overwritten.

## Record data, analyses and figures

For your own project, set `project_root` to its existing folder. Use `create` once and `open` on later visits. Run your analysis normally, then register the saved outputs and call `save()`.

The examples below assume a fresh folder containing copies of `examples/input-files/`. Use a different folder from an initialized trial project. Python uses `qc.py`; R uses `qc.R`.

<details>
<summary>Python</summary>

```python
from biodataledger import ProjectBundle
p = ProjectBundle.create("Synthetic study", project_dir=project_root)
d = p.register_data("input.csv", role="analysis_ready", hash=True)
p.set_current(d, purpose="qc", reason="Scientist-selected synthetic trial input")
p.save()

p = ProjectBundle.open(project_dir=project_root)
d = p.resolve_data(purpose="qc", verify="sha256")
# Normal native analysis uses d.path and saves figures. The registry runs nothing.
a = p.register_analysis("QC", inputs=[d.ref], code="qc.py",
                        method="synthetic display", params={"min_genes": 200})
f1 = p.register_figure("library.svg", type="qc", analysis=a)
f2 = p.register_figure("genes.svg", type="qc", analysis=a)
p.save()
print(p.status())
figures = p.find_figures(type="qc")
figure = p.get_figure(figures[0].ref)
print(figure.inputs, figure.code, figure.params, figure.provenance)
```

</details>

<details>
<summary>R</summary>

```r
library(BioDataLedger)
p <- ProjectBundle$create("Synthetic study", project_dir = project_root)
d <- p$register_data("input.csv", role = "analysis_ready", hash = TRUE)
p$set_current(d, purpose = "qc", reason = "Scientist-selected synthetic trial input")
p$save()

p <- ProjectBundle$open(project_dir = project_root)
d <- p$resolve_data(purpose = "qc", verify = "sha256")
# Normal native analysis uses d$path and saves figures; no package execution.
a <- p$register_analysis("QC", inputs = list(d$ref), code = "qc.R",
                        method = "synthetic display", params = list(min_genes = 200))
f1 <- p$register_figure("library.svg", type = "qc", analysis = a)
f2 <- p$register_figure("genes.svg", type = "qc", analysis = a)
p$save()
print(p$status())
figures <- p$find_figures(type = "qc")
figure <- p$get_figure(figures[[1]]$ref)
print(list(inputs = figure$inputs, code = figure$code, params = figure$params, provenance = figure$provenance))
```

</details>

## Inspect and resume

Open the project once and use exact getters for frequent metadata lookups. In 0.4, availability is unknown until explicitly checked: use `check_files=True` in Python (`TRUE` in R) for existence, or `resolve_data(..., verify="sha256")` for a selected input's byte integrity. Clean `save()` performs no disk write. A loaded object does not automatically refresh after another writer saves.

Dataset scope can record the saved population, assay/layer and an exact design revision. These declarations do not prove biological membership. See the [API](docs/api/API_0.5.0.md), [existing-project intake](docs/ADOPTION.md) and [declared-file recovery](docs/RECOVERY.md) guides. Recovery preserves code/file layout; it does not install a runtime or run an analysis.

## Conditions and levels

`condition` names the metadata column. `levels` lists the available categories; `selected_levels` records the intended comparison. `reference_level` sets its baseline, and `replicate` names the biological replicate column. These declarations do not filter data.

For an open project `p`, this synthetic example records Vehicle versus LowDose:

<details>
<summary>Python</summary>

```python
p.set_design(
    condition="treatment",
    levels=["Vehicle", "LowDose", "HighDose"],
    selected_levels=["Vehicle", "LowDose"],
    reference_level="Vehicle",
    replicate="mouse_id",
    selection_reason="HighDose excluded due to low RNA complexity"
)
p.save()
print(p)
print(p.get_design_summary())
```

</details>

<details>
<summary>R</summary>

```r
p$set_design(
  condition = "treatment",
  levels = c("Vehicle", "LowDose", "HighDose"),
  selected_levels = c("Vehicle", "LowDose"),
  reference_level = "Vehicle",
  replicate = "mouse_id",
  selection_reason = "HighDose excluded due to low RNA complexity"
)
p$save()
p
p$get_design_summary()
```

</details>

Use `get_design()` for the full record or `get_design_summary()` for a compact view. Each change creates a revision. Earlier analyses and their figures retain their recorded design. Optional `check_design_metadata()` checks supplied columns; see the [API](docs/api/API_0.5.0.md#experimental-design-and-saved-object-scope) for verification rules and getters.

Analysis registration uses the project design as a default and pins that exact
revision once. Pass `design_ref` to choose another exact design, or explicit
`None` (R: `NULL`) to record unknown design. DATA scope describes available file
contents; selected design levels describe the intended comparison. Extra
available levels do not mean the file was filtered.

`input_mode="separate"` checks each known input's declared scope. Use explicit
`input_mode="combined"` when separate condition files jointly support a comparison;
this declaration does not pool or merge files. `check_context(ref)` reports known
contradictions and missing context without reading scientific data. Declared
consistency does not establish biological correctness or scientific approval.

To check a retained figure's bytes, use `resolve_figure(ref, verify="sha256")`.
Ordinary `get_figure` remains a metadata lookup. To preserve an existing saved
figure, call `save_figure(source, type, analysis=...)`, then `save()`. This copies
one file into an exclusive managed location. Pass `ref` instead of analytical
context to append an existing figure's revision. Older copies and external files
are never overwritten. An external file's hash alone provides no preserved copy.
See the [full contract](docs/api/API_0.5.0.md#exact-designs-and-saved-figure-copies--050).

## Share a result

Preview the export, then save selected files to a ZIP. **ZIPs include the whole registry's metadata and history**, even when only a few files are selected. Review sensitive information and missing dependencies before sharing; a ZIP is not a guarantee that an analysis will run elsewhere.

These examples continue from above. Set `archive_path` to a new ZIP filename and `import_root` to a new directory.

<details>
<summary>Python</summary>

```python
plan = p.preview_export("working", include=[d.ref, f1, f2])
print(plan)
p.export_zip(plan, path=archive_path)
q = ProjectBundle.import_zip(archive_path, project_dir=import_root)
print(q.get_figure(f1).provenance)
print(q.check(hashes=True))
```

</details>

<details>
<summary>R</summary>

```r
plan <- p$preview_export("working", include = list(d$ref, f1, f2))
print(plan)
p$export_zip(plan, path = archive_path)
q <- ProjectBundle$import_zip(archive_path, project_dir = import_root)
print(q$get_figure(f1)$provenance)
print(q$check(hashes = TRUE))
```

</details>

Use `preview_export("context")` for metadata only. Import checks packaged hashes and does not execute scripts or fetch missing files.

## Using an agent

Install the package, fill in the brackets and paste this into your coding agent:

```text
Use BioDataLedger for this project.
Project folder: [absolute path]
Language: [R or Python]
Task: [what I want to do]

Open the registry and read status() and get_design_summary().
If no registry exists, ask before creating one.
Use exact dataset references or my chosen current-for-purpose input.
Report missing files, ambiguous choices and unknown provenance.
Ask before changing the cohort, design or current dataset.
For authorized work, register saved results with their known inputs,
code and parameters, then save. Preserve staged work on a stale-write error.
Preview all files and metadata before an authorized export.
```

The [agent guide](docs/agent/USAGE.md) gives the full usage rules. You can also use the package directly from R or Python.

Keep the project loaded in the active process and query it only when needed.
There is no required call on every chat turn. Group related lookups when a tool
starts a fresh process, and save once after meaningful record changes. A loaded
object retains its revision; reopen deliberately for another writer's updates.

## Limits

Records describe the sources you supply; they are not proof that code ran or that a result is scientifically valid. Data remain native files, and selecting levels does not subset an object.

`get_analysis(ref).evidence` and `get_figure(ref).evidence` distinguish declared
input/code relationships from execution evidence (R uses `$evidence`). The
registry currently captures no analysis execution, so execution remains unknown
and `execution_evidence` appears in the missing-information list even when every
declared field is present. Compact status and summaries state this explicitly.
Hashes, code snapshots and successful imports do not change that status.

Older projects remain readable. Saving experimental design requires clients ≥0.3.0; DATA scope/design records require clients ≥0.4.0; explicit analysis input modes and managed figure copies require clients ≥0.5.0. Windows/Linux writes, network/cloud-synced folders, power-loss recovery and exports over 4 GiB remain unverified. The R maintainer-contact placeholder is unresolved; no PyPI or CRAN release has been published.

## Tests

After installing both clients:

```sh
BDL_R_LIB="$PWD/.r-library" .venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
R CMD build r
R CMD check --no-manual BioDataLedger_0.5.0.tar.gz
```
