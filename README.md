# BioDataLedger

**Find retained figures and understand their recorded data, code and parameters without rebuilding a project's history.** BioDataLedger is a lightweight native R/Python project registry for existing computational research folders. No AI service, database or workflow engine is required.

Source version: **0.3.0**, including experimental design and levels, under the MIT license. See the [GitHub repository](https://github.com/nbatada/biodataledger). This is a source publication, not a PyPI or CRAN release. The R maintainer-contact placeholder remains unresolved. Start with the synthetic examples below; the [API reference](docs/api/API_0.3.0.md) documents all methods.

## Repository instructions: start here

BioDataLedger is a small record book for a research project. It remembers which data, code, parameters and experimental design belong to a saved result. You continue doing analysis in your usual Python or R tools, then register the results you want to keep.

The repository contains the **software**. Your research project stays in its own folder; you do not need to move your data into this repository. BioDataLedger saves its records in `.nb_project_bundle/` inside the project you choose. It does not run analyses or automatically filter data.

Follow these steps: **get the source → install one client → try the synthetic example → use your own project**. Python and R read the same project records. You can install either client or both; no agent, API key or account with an AI service is needed.

### 1. Get the source

If you already have this checkout, open a terminal in its root folder and skip the clone command. Otherwise:

```sh
git clone https://github.com/nbatada/biodataledger.git
cd biodataledger
```

The commands below run from this repository folder. The experimental-design examples require version **0.3.0**; the installation check below prints the version you installed.

### 2. Install Python, R, or both

The tested environment is **macOS**. For Python, you need Python 3.9 or newer. For R, you need an installed R runtime. An online installation downloads build tools or R dependencies; offline installation requires those packages to be available already.

**Python — paste into your terminal:**

```sh
python3 -m venv .venv
.venv/bin/python -m pip install ./python
.venv/bin/python -c 'import biodataledger; print(biodataledger.__version__)'
```

The last command prints the installed version. Use `.venv/bin/python` for the examples, or select this environment in your editor/notebook. Python has no runtime dependencies; installation uses setuptools and wheel to build the package.

**R — paste into your terminal:**

```sh
mkdir -p .r-library
export R_LIBS_USER="$PWD/.r-library"
Rscript -e 'install.packages(c("jsonlite", "digest", "zip", "uuid", "stringi"), repos="https://cloud.r-project.org")'
R CMD INSTALL -l "$R_LIBS_USER" r
Rscript -e 'library(BioDataLedger); print(packageVersion("BioDataLedger"))'
```

The last command prints the installed version. You may skip `install.packages` if these dependencies are already available; `zip` must be version 3.0.2 or newer. In each new shell, set `R_LIBS_USER` to the absolute path of this checkout's `.r-library` before starting R. In an already open R session, add that absolute path with `.libPaths(c("/absolute/path/to/biodataledger/.r-library", .libPaths()))`, then run `library(BioDataLedger)`.

### 3. Try a safe example

Choose the command for your installed language:

```sh
# Python
.venv/bin/python examples/trial_python.py "$PWD/trial-python"

# R
R_LIBS_USER="$PWD/.r-library" Rscript examples/trial_R.R "$PWD/trial-r" "$PWD/examples/input-files"
```

Each command creates a separate synthetic project and prints a saved figure reference. The example registers one dataset, one analysis and two figures. It uses only files supplied in the repository and refuses to overwrite an existing destination. For another run, choose a new destination name. Continue below for the retrieval and sharing examples.

### 4. Use your own project

1. Choose your existing research folder as `project_root`. Create a registry once; use `open` in later sessions.
2. If useful, record your [condition, levels, selection and replicate](#experimental-design-and-levels) before registering an analysis.
3. Run your analysis with your usual tools and save its outputs.
4. Register the input, analysis and figures using the [Python or R examples below](#five-minute-quick-start), then call `save()`.
5. Later, reopen the project and use `find_figures()` and `get_figure()` to recover a retained result's recorded sources.

For an AI coding assistant, use the [copy-ready agent instructions](#paste-into-your-coding-agent). For method arguments and return values, use the [API reference](docs/api/API_0.3.0.md). The package works directly from Python or R without an agent. No PyPI or CRAN release has been published.

## Five-minute quick start

For a safe trial, run `examples/trial_python.py` or `examples/trial_R.R` using the commands above. They copy only supplied synthetic files into a new directory. For your own project, set `project_root` to its explicit existing root and replace the sample names with real registered inputs and saved outputs. Creation requires only name/root; optional purpose, raw_dir and metadata can be added. Reopen instead of creating if a registry already exists.

Python (`project_root` is the existing synthetic trial folder containing input.csv, qc.py, library.svg and genes.svg):

```python
from biodataledger import ProjectBundle
p = ProjectBundle.create("Synthetic study", project_dir=project_root)
d = p.register_data("input.csv", role="analysis_ready", hash=True)
p.set_current(d, purpose="qc", reason="Scientist-selected synthetic trial input")
p.save()

p = ProjectBundle.open(project_dir=project_root)
d = p.get_data(purpose="qc")
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

R (load the installed package and use the corresponding synthetic qc.R):

```r
library(BioDataLedger)
p <- ProjectBundle$create("Synthetic study", project_dir = project_root)
d <- p$register_data("input.csv", role = "analysis_ready", hash = TRUE)
p$set_current(d, purpose = "qc", reason = "Scientist-selected synthetic trial input")
p$save()

p <- ProjectBundle$open(project_dir = project_root)
d <- p$get_data(purpose = "qc")
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

Retention is four calls: one analysis, two figures, save. Enter shared provenance once. The sample parameter is fictional, not a QC recommendation. Inspect before selecting a candidate figure; names and latest timestamps do not establish identity.

## Experimental design and levels

Design is optional. `levels` lists available categories in the stated order; `selected_levels` records the intended analysis selection. It does **not** subset a dataset or expression matrix. Observed levels can differ between datasets.

For an already opened project `p`, this fictional PRMT5 example declares a comparison; it does not inspect or change real PRMT5 data:

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

Use `get_condition()`, `get_levels()`, `get_selected_levels()`, `get_reference_level()` and `get_replicate()` in native analysis code. `get_design()` returns the full current design; `get_design("DES-001@1")` retrieves an exact earlier revision. `get_design_summary()` returns bounded condition, selection, reference, replicate and revision fields, with an explicit truncation flag. Printed counts reflect registered records, not illustrative totals.

Each `set_design` creates a revision. New analyses capture the current design; linked figures inherit that analysis's exact design. Existing analyses and figures retain their original design or explicit unknown context, even if the current selection changes. `get_analysis(ref)` and `get_figure(ref)` expose that retained design.

Optional `check_design_metadata(metadata)` checks supplied column values without loading a file. Python accepts a dictionary of column sequences (for a pandas table, pass `table.to_dict(orient="list")`); R accepts a data frame or named column list, including factor columns. Only condition and replicate columns are inspected. Missing columns/values and unexpected observed levels are reported. Absent declared or selected levels are listed separately and do not by themselves invalidate the check. Matching metadata does not establish that a contrast is estimable or scientifically valid.

To retain verification, pass those columns as `metadata=` to `set_design`; an invalid check leaves the registry unchanged. The record then says `metadata-verified` rather than `scientist-declared`. `context=[data_ref]` in Python or `context=list(data_ref)` in R can identify exact registered data/analysis context. Verification describes the supplied columns at that time; it is not proof that they came from a particular dataset. No metadata rows are saved, but observed level labels and counts are recorded.

Legacy projects still load without a design. The first `set_design` stages schema 0.2.0; `save()` persists it. Clients older than package 0.3.0 reject this newer schema. Legacy state paths, old records and ZIP format remain unchanged.

## Share with a colleague

Context means metadata without scientific payloads. Working means explicitly selected files plus listed code snapshots. Review the complete preview, including metadata/history, missing dependencies and omissions. To share this synthetic example:

```python
plan = p.preview_export("working", include=[d.ref, f1, f2])
print(plan)
p.export_zip(plan, path=archive_path)
q = ProjectBundle.import_zip(archive_path, project_dir=import_root)
print(q.get_figure(f1).provenance)
print(q.check(hashes=True))
```

```r
plan <- p$preview_export("working", include = list(d$ref, f1, f2))
print(plan)
p$export_zip(plan, path = archive_path)
q <- ProjectBundle$import_zip(archive_path, project_dir = import_root)
print(q$get_figure(f1)$provenance)
print(q$check(hashes = TRUE))
```

`archive_path` must be a new ZIP filename and `import_root` a new directory. Use `preview_export("context")` for metadata-only sharing. Imports do not run code, load native objects or fetch missing inputs. Included hashes are checked; omitted external resources remain unavailable until explicitly rebound. The other language can inspect the same registry and files without converting RDS/H5AD objects.

## What provenance means

Captured file bytes/digests are not proof of which computation ran. Data/code links, methods and parameters are declarations unless separately verified. Snapshots preserve supplied source bytes; a hash alone cannot recover a lost file. Unknown execution remains unknown. Scientific validity, acceptance and an actual reproduced rerun require their own evidence.

There is **no automatic sensitive-metadata redaction**. Do not publish or transfer confidential project data, patient identifiers, credentials or private history. Whole registry metadata travels in this version. A bundle being inspectable does not establish that it is resumable or reproduced.

## API at a glance

BioDataLedger uses a local Python/R package API, not a web API. No API key is needed. Python imports `ProjectBundle` from `biodataledger`; R loads `BioDataLedger` and uses `ProjectBundle`. The examples above show both languages; the [full API reference](docs/api/API_0.3.0.md) documents arguments, returned values and limits.

| Task | Python | R |
| --- | --- | --- |
| Open an existing registry | `ProjectBundle.open(project_dir=project_root)` | `ProjectBundle$open(project_dir=project_root)` |
| Inspect compact status | `p.status()` | `p$status()` |
| Resolve a selected input | `p.get_data(purpose="qc")` | `p$get_data(purpose="qc")` |
| Find candidate figures | `p.find_figures(type="qc")` | `p$find_figures(type="qc")` |
| Inspect an exact figure | `p.get_figure("FIG-001@1")` | `p$get_figure("FIG-001@1")` |
| Retain analysis and figures | `p.register_analysis(...)`, `p.register_figure(...)` | `p$register_analysis(...)`, `p$register_figure(...)` |
| Save staged changes | `p.save()` | `p$save()` |

Replace the sample purpose, type and reference with values from your project. Creation uses `ProjectBundle.create` / `ProjectBundle$create` only when explicitly starting a new registry.

## Paste into your coding agent

Install the package first. Replace the bracketed fields, then paste this prompt into your agent. The initial step is read-only; the requested task supplies any later execution authority.

```text
Use the installed BioDataLedger package for this project.
Project root: [absolute path to my existing project]
Language: [Python or R]
Task: [the specific lookup or analysis I want]

Read the BioDataLedger API reference supplied with the installed package.
Use ProjectBundle from biodataledger (Python) or BioDataLedger (R).
Open the explicit project root once and call status() once at session start.
Read get_design_summary(); use get_design() if it is truncated.
Use the recorded condition, levels, selection, reference and replicate.
A design is a declaration, not permission to filter data or change the analysis.
If no registry exists, ask before creating one.
Resolve inputs by exact registered reference or my selected purpose.
Report missing or ambiguous inputs; do not guess or search unrelated folders.
First report the selected records, missing evidence and next action.

For analysis I authorize, use native Python/R tools. Register only retained,
actually saved outputs. Record known exact inputs, generating code, method
and parameters once with register_analysis; link related register_figure
calls to that analysis and save meaningful changes. Keep unknowns explicit.
Ask before changing current inputs, cohorts, labels or scientific decisions.
On a stale-write error, preserve staged work and report the conflict.
Preview files and metadata before any separately authorized export.
Do not treat registration or hashes as proof of execution or scientific validity.
```

See the [agent usage contract](docs/agent/USAGE.md) for the same boundaries. BioDataLedger also works directly from Python or R without an agent.

## Optional agent use and limits

Query compact status at session start; resolve known paths with getters; register retained results; save meaningful edits. Ask the scientist before changing current inputs or scientific decisions. Missing/ambiguous records are not permission to guess or search unrelated folders. These instructions do not restrict an unrestricted shell/interpreter. The [agent usage guide](docs/agent/USAGE.md) describes these package-use boundaries.

The legacy storage/ZIP formats remain compatible. Writes have been tested on local macOS. Windows/Linux writes, network/cloud-synced projects, power loss and physical >4 GiB export performance are not yet verified. Native object saving, GUI, workflow replay, database/cloud sync and mandatory agent tooling are non-goals.

## Run the package checks

After installing both clients from this checkout, run these commands from the repository root:

```sh
BDL_R_LIB="$PWD/.r-library" .venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
R CMD build r
R CMD check --no-manual BioDataLedger_0.3.0.tar.gz
```

The tests use synthetic fixtures and check native R/Python interoperability, exact revisions, experimental design, safe import and the README examples. Software checks do not establish scientific validity.
