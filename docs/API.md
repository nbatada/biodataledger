# BioDataLedger API reference

Current agent API for **BioDataLedger 0.16.0** in Python (`biodataledger`) and R (`BioDataLedger`). Linked feature contracts specify nested inputs and reports. Earlier `API_0.*.md` files describe their named versions. [Release source at v0.16.0](https://github.com/nbatada/biodataledger/tree/v0.16.0).

## Open and inspect a project

Use the scientist's explicit project root. Open once per process, print the handle to see the **loaded package version**, **registry revision**, and **unsaved changes**, and read compact status once at task start. A loaded handle keeps its own view of the registry until deliberately reopened.

```python
from biodataledger import ProjectBundle

p = ProjectBundle.open(project_root)
print(p)
status = p.status()
```

```r
p <- BioDataLedger::ProjectBundle$open(project_root)
print(p)
status <- p$status()
```

- If the task names a DATA revision or a current-for-purpose input, use that selector. Resolve the chosen input explicitly before loading it with the project's native loader. Missing or ambiguous selectors, unknown required scope, or a missing digest need resolution before use.
- Use metadata lookups for bookkeeping. Search results are candidates. An unchecked availability field means unknown, and a newer revision may belong to a different scientific purpose.
- Record meaningful work, then save the related batch. Keep the exact references returned by writers. `save_and_confirm()` commits **all** pending edits on that handle.
- On a stale-write error, preserve pending edits and any saved output files. Open a separate fresh handle and reconcile the changes deliberately before retrying. A clean save does not check freshness.

See [agent operating guidance](agent/USAGE.md), [updating a running project](UPDATING.md), and [retaining inputs and outputs](RETAINED_INPUTS.md).

## Choose a function

| Task | Functions |
| --- | --- |
| [Project lifecycle and orientation](#project-lifecycle-and-orientation) | [`create`](#create), [`open`](#open), [`status`](#status), [`summary`](#summary), [`summary_text`](#summary_text), [`get_raw_dir`](#get_raw_dir), [`get_metadata_path`](#get_metadata_path), [`get_output_dir`](#get_output_dir) |
| [Find and search](#find-and-search) | [`find_figures`](#find_figures), [`find_outputs`](#find_outputs), [`related_work`](#related_work) |
| [Retrieve exact records and code](#retrieve-exact-records-and-code) | [`get_data`](#get_data), [`get_analysis`](#get_analysis), [`get_figure`](#get_figure), [`get_info`](#get_info), [`read_figure_source`](#read_figure_source) |
| [Explicit verification](#explicit-verification) | [`resolve_data`](#resolve_data), [`resolve_figure`](#resolve_figure), [`check`](#check), [`check_context`](#check_context), [`check_design_metadata`](#check_design_metadata), [`check_object`](#check_object), [`check_result`](#check_result) |
| [Register files and revise records](#register-files-and-revise-records) | [`register_data`](#register_data), [`register_analysis`](#register_analysis), [`register_figure`](#register_figure), [`save_figure`](#save_figure), [`register_result`](#register_result), [`update_record`](#update_record), [`set_current`](#set_current), [`set_context`](#set_context), [`set_data_scope`](#set_data_scope) |
| [Experimental design](#experimental-design) | [`set_design`](#set_design), [`get_design`](#get_design), [`get_condition`](#get_condition), [`get_levels`](#get_levels), [`get_selected_levels`](#get_selected_levels), [`get_reference_level`](#get_reference_level), [`get_replicate`](#get_replicate), [`get_design_summary`](#get_design_summary) |
| [Presentation and filenames](#presentation-and-filenames) | [`set_presentation`](#set_presentation), [`output_name`](#output_name), [`export_named_output`](#export_named_output) |
| [Graphs and chronology](#graphs-and-chronology) | [`dependencies`](#dependencies), [`export_graph`](#export_graph), [`timeline`](#timeline), [`timeline_summary`](#timeline_summary), [`execution_history`](#execution_history), [`execution_history_summary`](#execution_history_summary) |
| [Decisions, protocols, execution, and comparisons](#decisions-protocols-execution-and-comparisons) | [`record_decision`](#record_decision), [`record_scientific_decision`](#record_scientific_decision), [`get_decision`](#get_decision), [`register_protocol`](#register_protocol), [`get_protocol`](#get_protocol), [`compare_protocol`](#compare_protocol), [`run_analysis`](#run_analysis), [`get_execution`](#get_execution), [`execution_summary`](#execution_summary), [`register_comparison_plan`](#register_comparison_plan), [`record_comparison_assessment`](#record_comparison_assessment), [`get_comparison`](#get_comparison) |
| [Save, share, and recover](#save-share-and-recover) | [`save`](#save), [`save_and_confirm`](#save_and_confirm), [`preview_export`](#preview_export), [`export_zip`](#export_zip), [`import_zip`](#import_zip), [`rebind_external`](#rebind_external) |

## References, paths, and effects

Pass an exact local reference with `project_id`, `id`, and positive integer `revision` in a Python dictionary or R named list. Use returned refs to carry the project UUID. A string such as `DATA-001@2` is local to the opened project. Record prefixes are `DATA` for saved data and derived artifacts, `ANA` for analyses and explicit execution receipts, `FIG` for figures, `DES` for design revisions, and `DEC` for decisions, protocols, comparison plans, and comparison assessments. The typed getters distinguish those uses. Registry revision counts commits, while a record revision identifies a version of one record.

Compact keys such as `D001r2` and `F003r1` work in `set_presentation`, `output_name`, `get_info`, and `export_named_output`. `A001r1` is accepted by `get_info` for ANA. Use full references or `ID@revision` elsewhere, except for the documented figure selectors. Filenames, topics, and display names serve discovery.

The notation `<omitted>` below describes an internal Python default. Omit the argument to use that behavior. Use `None` in Python and `NULL` in R for explicit null values. For nested metadata, use Python dictionaries and lists or R named lists for objects and unnamed lists for arrays. Use named arguments in R when skipping earlier parameters. Where a Python signature has `*`, pass subsequent arguments by keyword.

Relative registered file paths resolve from the project root. Getters can return a resolved path before any availability or integrity check. Python file views use `pathlib.Path` and attribute access such as `data.path`. R views use path strings and list fields such as `data$path`. Structured reports and exact refs use Python dictionaries or R lists. Returned metadata is detached. Use the documented mutators to change project state.

Metadata queries inspect the loaded registry. Some resolve local paths, while explicit checks can inspect filesystem metadata, stream file hashes, or read selected bytes as noted below. Registration records declarations, and an ordinary ANA or FIG reports execution as unknown with evidence `not_captured`. File integrity, declared inputs, observed wrapper execution, actual input use, and scientific approval are distinct claims. Writes are supported on tested local macOS filesystems. Python exposes `from biodataledger import BundleError`, a `ValueError` subclass used for package validation. R signals native error conditions. Filesystem and native execution errors can also surface. Keep the exact error and selector when a call fails.

The short examples use `p` for a project handle and names such as `data_ref` and `figure_ref` for actual references returned by a writer or query. Names such as `input.csv` denote existing project files. For a complete paired workflow with real synthetic files, see the [retained input example](RETAINED_INPUTS.md) and the [lineage demo](LINEAGE_DEMO.md).

## Project lifecycle and orientation

### create

```text
Python  ProjectBundle.create(name, project_dir, purpose=None, raw_dir=None, metadata=None)
R       ProjectBundle$create(name, project_dir, purpose = NULL, raw_dir = NULL, metadata = NULL)
```

Initialize a registry in an existing explicit directory. Only `name` and `project_dir` are required. Optional `raw_dir` and `metadata` register project locators. Returns a handle to the newly committed registry at revision 1. An existing registry blocks creation. For a new project, use `ProjectBundle.create("Synthetic QC", project_root)` or `ProjectBundle$create("Synthetic QC", project_root)`.

### open

```text
Python  ProjectBundle.open(project_dir)
R       ProjectBundle$open(project_dir)
```

Load and validate the registry at `.nb_project_bundle/project.json` and build in-memory indexes. Returns a handle. A missing or invalid registry raises an error. Open does not initialize the directory or deserialize registered data. See the [opening example](#open-and-inspect-a-project).

### status

```text
Python  p.status(compact=True, purpose=None, check_files=False)
R       p$status(compact = TRUE, purpose = NULL, check_files = FALSE)
```

Read bounded project metadata. Returns `package_version`, project identity, `registry_revision`, `unsaved`, up to five exact current-purpose references, next task, record counts, truncation, and availability indicators. A named `purpose` adds a compact pinned dataset/design/scope when available. `active_question` is null. Keep `compact=True` or `TRUE`. The false setting is unsupported. Use `summary()` for more context. The report is bounded to 4096 UTF-8 bytes. Default availability is unchecked. `check_files=True` or `TRUE` checks existence for at most 100 distinct relevant locators and returns up to five missing items with checked and unchecked counts. With a named purpose, Python checks its selected record only. R also considers latest records. See the [opening example](#open-and-inspect-a-project).

### summary

```text
Python  p.summary()
R       p$summary()
```

Read `state_revision`, `unsaved`, total record-revision count, DATA/ANA/FIG identity counts, current pointers, next task, current design, and ordinary-registration evidence. Python also includes `project` metadata. Call `p.summary()` or `p$summary()` when compact status omits fields the task needs. Counts refer to registry records and include retained artifacts and execution records.

### summary_text

```text
Python  p.summary_text(purpose=None)
R       p$summary_text(purpose = NULL)
```

Format a human-readable card with project, design, record counts, loaded package version, registry revision, and unsaved state. With `purpose`, the card shows the selected input context. Python presents the compact dataset section. R keeps the record counts and adds selected-purpose details. Call `p.summary_text(purpose="review")` or `p$summary_text(purpose="review")`. Python `repr(p)` returns the default card text, and `print(p)` displays it. R `print(p)` displays the default card and returns the handle invisibly. Python `p.unsaved` is a read-only boolean property. R exposes the flag in `p$status()$unsaved` and `p$summary()$unsaved`. Use the documented constructors and these accessors instead of direct Python initialization or editing the internal `root` and `state` fields. For loaded package version alone, use `biodataledger.__version__` or `getNamespaceVersion("BioDataLedger")`.

### get_raw_dir

```text
Python  p.get_raw_dir()
R       p$get_raw_dir()
```

Return the resolved registered raw-data directory path or null when absent or unresolved. `p.get_raw_dir()` or `p$get_raw_dir()` is a locator lookup. Check the path explicitly if availability matters.

### get_metadata_path

```text
Python  p.get_metadata_path()
R       p$get_metadata_path()
```

Return the resolved registered metadata path or null when absent or unresolved. `p.get_metadata_path()` or `p$get_metadata_path()` does not read the metadata file.

### get_output_dir

```text
Python  p.get_output_dir(kind)
R       p$get_output_dir(kind)
```

Construct the path under `results/<kind>`. For example, call `p.get_output_dir("qc")` or `p$get_output_dir("qc")`. The method leaves directory creation to the caller. Use a simple token of letters, digits, underscores or hyphens. Python enforces the token and project containment. R constructs the path from the supplied value, so pass only a trusted simple token.

## Find and search

### find_figures

```text
Python  p.find_figures(query=None, type=None)
R       p$find_figures(query = NULL, type = NULL)
```

Find the latest active revisions of figure IDs. The optional `type` filter is exact. All whitespace-separated query terms must match literal case-insensitive substrings across recorded names, descriptions, type, locator, asset ID, or the linked analysis's name and description. Returns figure views in stable ID order as a Python list or R named list. Empty results mean no match in this search scope. Example `p.find_figures(query="sample QC")` or `p$find_figures(query="sample QC")`. This reads metadata with unchecked file availability.

### find_outputs

```text
Python  p.find_outputs(topic=None, question=None, query=None, kind=None, document_id=None, limit=20, offset=0, historical=False)
R       p$find_outputs(topic = NULL, question = NULL, query = NULL, kind = NULL, document_id = NULL, limit = 20L, offset = 0L, historical = FALSE)
```

Search retained DATA and FIG by recorded presentation topics, question text, free text, kind (`DATA` or `FIG`), or exact case-sensitive `document_id`. Filters combine. The default includes the latest revision of each DATA or FIG ID. Set `historical=True` or `TRUE` to include earlier revisions. Inspect `record_status` independently of revision scope. Returns `items`, `total`, `offset`, `next_offset`, and `truncated` with report context. Use a limit of 1–100 and a nonnegative offset. Continue on the same unchanged handle. Use `p.find_outputs(topic="QC")` or `p$find_outputs(topic="QC")`, then inspect an exact returned ref. See [matching rules and paired examples](api/OUTPUT_DISCOVERY_V1.md#find-and-inspect).

### related_work

```text
Python  p.related_work(input_ref=None, query=None, limit=5)
R       p$related_work(input_ref = NULL, query = NULL, limit = 5L)
```

Supply exactly one of `input_ref` (exact DATA) or a nonblank keyword `query`. Input matching follows declared direct links, including historical ANA revisions. Text matching searches latest active analysis metadata. Returns a compact report with analysis entries, exact linked input/result/figure refs, match basis, counts, and coverage/omission markers. Limits are 1–20 entries and 4096 UTF-8 bytes per report. Exact input search checks up to 100 adjacent edges, and keyword search checks up to 1,000 latest active ANA records. Empty or truncated results describe recorded coverage only. Try `p.related_work(input_ref=data_ref)` or `p$related_work(query="sample QC")`. See [related-work report and bounds](api/RELATED_WORK_V1.md).

For bounded name search over DATA or DEC, use [structured graph overview filters](#export_graph). Inspect the matching exact records separately.

## Retrieve exact records and code

### get_data

```text
Python  p.get_data(ref=None, role=None, purpose=None, check_files=False)
R       p$get_data(ref = NULL, role = NULL, purpose = NULL, check_files = FALSE)
```

Choose one of exact `ref`, an unambiguous `role` among latest active DATA records, or a recorded `purpose` pointer. Returns a DATA view with `ref`, `path`, `locator`, `scope`, design fields, `result`, and availability fields. Missing or ambiguous selectors raise an error. `check_files=True` or `TRUE` checks existence. For use of a scientific input, call [resolve_data](#resolve_data) for the chosen exact revision. Example `p.get_data(ref=data_ref)` or `p$get_data(ref=data_ref)`.

### get_analysis

```text
Python  p.get_analysis(ref)
R       p$get_analysis(ref)
```

Return the exact ANA revision as an analysis view with recorded `inputs`, `code`, `method`, `params`, `design_ref`, `design`, and `evidence`. An unknown input declaration is null and an explicitly empty list is empty. Use `p.get_analysis(analysis_ref)` or `p$get_analysis(analysis_ref)`. For an execution receipt, use [get_execution](#get_execution).

### get_figure

```text
Python  p.get_figure(ref=None, check_files=False, *, asset_id=None, path=None, revision=None, compact=False)
R       p$get_figure(ref = NULL, check_files = FALSE, asset_id = NULL, path = NULL, revision = NULL, compact = FALSE)
```

Choose exactly one of `ref`, `asset_id`, or a path matching the recorded locator or its absolute project spelling. A bare FIG ID, asset ID, or path must select one revision, optionally constrained by `revision`. If the match is ambiguous, pass a full exact ref. Returns the figure view with inherited analytical inputs/code/design and separate rendering inputs, generating code, dependencies, and missing-evidence markers. `check_files` checks existence only. `compact=True` or `TRUE` returns a report capped at 4096 UTF-8 bytes with truncation information. Example `p.get_figure(figure_ref)` or `p$get_figure(figure_ref)`.

### get_info

```text
Python  p.get_info(ref, limit=20, offset=0)
R       p$get_info(ref, limit = 20L, offset = 0L)
```

Inspect exact DATA, FIG, or ANA provenance and immediate registered outputs. Returns paged `inputs` and `outputs`, recorded details, `producer_ref`, `analytical_source`, and, for FIG, `rendering_inputs` and `plotting_code`. A linked FIG producer is its recorded ANA. For DATA, a producer comes from its recorded transformation reference. A code candidate or a human-readable name alone supplies no generating-code evidence. `limit` is 1–100 and `offset` starts at zero. The same offset applies to separate input, output, rendering-input and code-candidate pages, each with its own continuation. A record or analytical-source block over 16 KiB is omitted whole with a status marker. Use an exact getter for full detail. Example `p.get_info(figure_ref, limit=5)` or `p$get_info(figure_ref, limit=5L)`. See [report fields](api/OUTPUT_DISCOVERY_V1.md#find-and-inspect).

### read_figure_source

```text
Python  p.read_figure_source(ref=None, *, asset_id=None, path=None, revision=None, code_ref=None)
R       p$read_figure_source(ref = NULL, asset_id = NULL, path = NULL, revision = NULL, code_ref = NULL)
```

Use the figure selectors above to retrieve at most 1 MiB of verified code. Supply an exact `code_ref` selector with owner `record`, zero-based `index` in both languages, and optional matching `sha256` when the recorded source is ambiguous. The method uses a declared source or a single eligible candidate if unambiguous. Returns `content` (Python bytes or R raw vector), `code_ref`, `sha256`, `snapshot`, `integrity`, and execution evidence fields. A recorded snapshot is preferred and a missing or altered snapshot rejects. An unsnapshotted original can be read if it meets size and digest checks. Read with `p.read_figure_source(figure_ref)` or `p$read_figure_source(figure_ref)`. Inspect the bytes without executing them. See [figure and code declarations](api/API_0.11.0.md#figure-rendering-sources--biodataledger-008) for the figure-source descriptor.

## Explicit verification

### resolve_data

```text
Python  p.resolve_data(ref=None, purpose=None, *, verify, expected_scope=None, require_membership=False)
R       p$resolve_data(ref = NULL, purpose = NULL, verify, expected_scope = NULL, require_membership = FALSE)
```

Before using a selected input, supply exactly one of `ref` or `purpose` and `verify="sha256"`. Requires an active exact DATA revision, a readable local regular file and an existing matching SHA-256 baseline. Returns a DATA view with `available` and `availability_checked` true and a `verification` report. Optional `expected_scope` matches `condition_values`, `assignment_inclusion`, `observation_unit`, `assay`, or `layer`. Array fields compare as sets. `require_membership=True` or `TRUE` also reads and verifies the bound membership report and membership file. This checks recorded evidence for the saved artifact. Use [check_object](#check_object) in R for supported live-object checks. The method streams file bytes and leaves native object loading to the caller. Stop on `NO_CURRENT`, `SCOPE_UNKNOWN`, `SCOPE_CONFLICT`, `MISSING_DIGEST`, or a mismatch and report the exact failure. Example `p.resolve_data(ref=data_ref, verify="sha256")` or `p$resolve_data(ref=data_ref, verify="sha256")`. See [retained input examples](RETAINED_INPUTS.md).

### resolve_figure

```text
Python  p.resolve_figure(ref, *, verify)
R       p$resolve_figure(ref, verify)
```

Supply an active exact FIG ref and `verify="sha256"`. Streams the local figure file and checks it against the recorded size and digest. Returns the full figure view plus matched `verification` and checked availability. If the exact source or preserved copy is missing or altered, report that revision and its failure. Example `p.resolve_figure(figure_ref, verify="sha256")` or `p$resolve_figure(figure_ref, verify="sha256")`.

### check

```text
Python  p.check(hashes=False)
R       p$check(hashes = FALSE)
```

Inspect file/code availability across all registered revisions. Python also validates loaded registry structure. With `hashes=True` or `TRUE`, explicitly hash local regular files with a recorded baseline. Returns per-entry exact `ref` and `status`. Python adds `role`, `locator`, and fingerprint status, and uses labels such as `available`, `staged`, `missing`, `match`, and `stale`. R adds `path` and marks code entries with `role="code"`, and uses `ok`, `unknown`, `missing`, and `stale`. This can traverse much more than compact status. Prefer a targeted resolver for one file. Example `p.check()` or `p$check()`.

### check_context

```text
Python  p.check_context(ref)
R       p$check_context(ref)
```

Compare declarations for an exact DATA, ANA, or FIG against the record's pinned design. A linked figure uses its exact ANA. Returns `status` (`consistent`, `inconsistent`, or `unknown`), `issues`, and `unknown`. For separate inputs, selected levels must appear in each input's declared scope. For combined inputs, coverage is checked across the union. Missing declarations remain unknown. Example `p.check_context(analysis_ref)` or `p$check_context(analysis_ref)`. This checks metadata only.

### check_design_metadata

```text
Python  p.check_design_metadata(metadata, ref=None)
R       p$check_design_metadata(metadata, ref = NULL)
```

Compare already-supplied columns against the exact `ref` or current design. Python accepts a mapping of column names to sequences. R accepts a data frame or named list of columns. Returns `valid`, observed and missing levels, missing columns, unexpected levels, and counts of missing values. A valid report can still list absent design levels. This check does not load a file, subset data, or assess replicate independence. Example `p.check_design_metadata({"condition": ["A", "B"]}, ref=design_ref)` for a design using those levels and no replicate column.

### check_object

```text
Python  Unavailable
R       p$check_object(object, ref = NULL, purpose = NULL, assay = NULL, layer = NULL)
```

R only. Check an already-loaded supported generic object or optional Seurat object against the required exact DATA ref or explicit purpose, with optional `assay` and `layer`. Measures bounded live metadata, sample-qualified membership and representation against registered requirements and can verify/read separately registered CSV authority files. Returns a `BioDataLedgerInputCheck` with `overall`, per-check evidence and `blockers`. Required FAIL or UNKNOWN yields BLOCKED. Print the report and inspect its requirements before proceeding. See [the live-object contract and example](api/OBJECT_CHECK_V1.md#manual-use-and-a-project-helper). A loader-attached reference records declared origin.

### check_result

```text
Python  p.check_result(ref)
R       p$check_result(ref)
```

Check an exact result DATA using its recorded embedding and membership declarations. Returns a versioned report with artifact integrity and alignment/membership findings, with an overall `PASS`, `FAIL`, or `UNKNOWN`. CSV verification can hash and read bounded CSV files and compare qualified keys and finite coordinates. Native Seurat and AnnData embedding selectors remain unmeasured by this method. Use `p.check_result(result_ref)` or `p$check_result(result_ref)`. For a generic nonembedding file, use [resolve_data](#resolve_data) for strict byte identity. See [result verification fields and bounds](api/RESULTS_V1.md#explicit-checking).

## Register files and revise records

Register only saved files and known links. A writer normally returns an exact staged reference. Use that reference in later registrations and commit the batch explicitly. A file copy may already exist on disk before its registration is saved.

### register_data

```text
Python  p.register_data(path, role, name=None, hash=False, **details)
R       p$register_data(path, role, name = NULL, hash = FALSE, ...)
```

Register an existing path under a required role with an optional name and named metadata details. A local file records size. Request `hash=True` or `TRUE` when the revision will need strict verification. Hashing requires a local regular file. Python also accepts a URI string as an unresolved declaration. Use a local path for native R registration. URI locators already in a registry may remain unresolved for local reuse. The package does not fetch URI bytes. Example `p.register_data("input.csv", "input", hash=True)` or `p$register_data("input.csv", "input", hash=TRUE)`. Use `register_result` for a typed derived artifact.

### register_analysis

```text
Python  p.register_analysis(name, inputs, code=None, method=None, params=None, snapshot_code=True, design_ref=<omitted>, input_mode='separate', **details)
R       p$register_analysis(name, inputs, code = NULL, method = NULL, params = NULL, snapshot_code = TRUE, design_ref = state$project$design, input_mode = "separate", ...)
```

Stage a named analysis with an ordered list of exact DATA refs, or explicit null for unknown inputs. Supply optional method, parameters, and named details. `code` takes a local path or a sequence of local paths. Code is hashed even when `snapshot_code` is false. The default captures up to 1 MiB per code file and saves the immutable snapshots at commit. Omitted `design_ref` pins the current design, while explicit null records unknown design. `input_mode` is `"separate"` or `"combined"`. Invalid references or known scope conflicts reject. Example `p.register_analysis("Count samples", [data_ref], code="qc.py")` or `p$register_analysis("Count samples", list(data_ref), code="qc.R")`. Registration stages the declaration without invoking the code.

### register_figure

```text
Python  p.register_figure(path, type, *args, **context)
R       p$register_figure(...)
```

The dispatcher in each language forwards the arguments below. The file must already exist as a local regular file. The method records its size and digest, stages a FIG, and leaves the file at its existing location. An exact ANA in `analysis` supplies inherited inputs, code, method, parameters and design. Omit those overrides for a linked figure. A standalone figure can declare those fields directly, with the same snapshot and design defaults as `register_analysis`. Example `p.register_figure("panel.svg", "QC", analysis=analysis_ref)` or `p$register_figure("panel.svg", "QC", analysis=analysis_ref)`.

```text
Python  path, type, analysis=None, name=None, inputs=None, code=None, method=None,
        params=None, snapshot_code=True, design_ref=<omitted>, input_mode=<omitted>,
        figure_sources=<omitted>, **details
R       path, type, analysis = NULL, name = NULL, inputs = NULL, code = NULL,
        method = NULL, params = NULL, snapshot_code = TRUE,
        design_ref = state$project$design, input_mode = "separate",
        figure_sources = NULL, ...
```

Optional `figure_sources` distinguishes the named asset, exact DATA rendering inputs, rendering relationship, exact code selector, and declared dependencies. The analysis describes analytical inputs. Rendering inputs record the caller’s declaration of what was supplied to the plot. Set `relationship="declared"` only when that relationship is known. Candidate inputs can retain an `"unknown"` relationship. A named code selector is distinct from analytical code candidates. See [the figure-source descriptor and constraints](api/API_0.11.0.md#figure-rendering-sources--biodataledger-008) and [the paired demo](LINEAGE_DEMO.md).

### save_figure

```text
Python  p.save_figure(source, type=None, ref=None, **context)
R       p$save_figure(source, type = NULL, ref = NULL, ...)
```

Copy one already saved local figure into a new managed output location, verify the copied bytes, and stage its FIG. For a new FIG, supply `type` and optional registration context as in [register_figure](#register_figure). With `ref`, append a revision preserving that record's analytical context. An optional type changes the recorded figure type. Other context overrides reject, and the prior presentation descriptor is cleared on a revised copy. The copied file is written before the registry save. Example `p.save_figure("panel-v2.svg", ref=figure_ref)` or `p$save_figure("panel-v2.svg", ref=figure_ref)`. Use this when prior image bytes must remain independently accessible.

### register_result

```text
Python  p.register_result(source, analysis_ref, ref=None, embedding=None, copy=False, hash=False)
R       p$register_result(source, analysis_ref, ref = NULL, embedding = NULL, copy = FALSE, hash = FALSE)
```

Stage a typed result as DATA with role `derived_result`. `source` is an existing local regular file or exact active DATA ref. Supply the exact producer ANA as `analysis_ref`, or explicit null if unknown. With `ref`, revise an existing typed result. By default the new revision references the file and keeps a supplied DATA baseline. `hash` requests a digest check/capture, and `copy` also verifies and writes a managed file before registry save. Optional `embedding` describes CSV coordinate columns or a native Seurat/AnnData selector, with exact membership authority when known. Invalid descriptors, missing files or baseline conflicts during hashing reject. Example `p.register_result("counts.csv", analysis_ref, hash=True)` or `p$register_result("counts.csv", analysis_ref, hash=TRUE)`. See [the result contract](api/RESULTS_V1.md#register-an-existing-result).

### update_record

```text
Python  p.update_record(ref, changes, reason)
R       p$update_record(ref, changes, reason)
```

Append a correction to an exact source revision with a nonblank reason. The returned revision follows the latest revision of that ID. Use named `changes` with fields appropriate to the record kind. Supported keys are `name`, `status`, `details`, `method`, `params`, `inputs`, `code`, `foreign_refs`, `path`, `design_ref`, `input_mode`, `analysis`, and `figure_sources`. Use full exact refs and the existing code descriptor format for analytical fields. Supplying `details` replaces that metadata object, so preserve existing fields needed by the record. A DATA/FIG path correction hashes the new file and drops prior presentation metadata. Old refs remain pinned and current pointers do not move. Protected fields and incompatible analytical overrides reject. Use dedicated writers for designs, result paths, preserved figures, scope, protocols, comparisons, and typed decision content. Example `p.update_record(data_ref, {"path": "input-v2.csv"}, "Corrected export")` or `p$update_record(data_ref, list(path="input-v2.csv"), "Corrected export")` for ordinary DATA. See [revision rules](RETAINED_INPUTS.md#revise-an-existing-input-or-result).

### set_current

```text
Python  p.set_current(ref, purpose, reason)
R       p$set_current(ref, purpose, reason)
```

Stage an explicit current-for-purpose pointer to an exact active DATA revision and return the selected ref. Require the scientist's selection and a reason. The method rejects when project context names external authorities. A newer DATA revision does not move the pointer. Example `p.set_current(data_ref, "review", "Scientist selected this revision")` or `p$set_current(data_ref, "review", "Scientist selected this revision")`.

### set_context

```text
Python  p.set_context(changes)
R       p$set_context(changes)
```

Stage changes to project `purpose`, `next_task`, `questions`, `authorities`, `raw_dir`, or `metadata`. Use a dictionary or named list. Question and authority values are arrays. The last two fields are locator inputs or null. Identical context leaves the handle clean if it was already clean. There is no returned record ref. Example `p.set_context({"next_task": "Review count table"})` or `p$set_context(list(next_task="Review count table"))`.

### set_data_scope

```text
Python  p.set_data_scope(ref, scope, reason, design_ref=None)
R       p$set_data_scope(ref, scope, reason, design_ref = NULL)
```

Append a DATA revision describing its saved population or representation. Pass optional `observation_unit`, `selection`, `condition_values`, `assignment_inclusion`, `assay`, `layer`, `sample_manifest_ref`, `transformation_ref`, `evidence`, and `membership_evidence` in `scope`. Use exact full refs for nested reference fields. An omitted/null `design_ref` records unknown design. A `verification_recorded` claim requires a matching registered report, which the writer reads and checks. Returns a new exact DATA ref while leaving bytes and current selection unchanged. Example `p.set_data_scope(data_ref, {"observation_unit": "sample"}, "Document table rows")` or `p$set_data_scope(data_ref, list(observation_unit="sample"), "Document table rows")`. See [scope and membership schemas](api/API_0.11.0.md#experimental-design-and-saved-object-scope).

## Experimental design

### set_design

```text
Python  p.set_design(condition, levels, selected_levels=None, reference_level=None, replicate=None, selection_reason=None, metadata=None, context=None)
R       p$set_design(condition, levels, selected_levels = NULL, reference_level = NULL, replicate = NULL, selection_reason = NULL, metadata = NULL, context = list())
```

Stage a new `DES-001` revision and make it the project design. Supply the condition column and ordered unique levels. Selected levels default to all levels. An explicit selection is a nonempty subset, and an optional reference level must be selected. Optional replicate names a column, and context contains exact DATA or ANA refs. Optional in-memory metadata must pass [check_design_metadata](#check_design_metadata) for the revision to stage. Existing analysis/figure design pins remain exact. Example `p.set_design("condition", ["A", "B"], reference_level="A")` or `p$set_design("condition", c("A", "B"), reference_level="A")`.

### get_design

```text
Python  p.get_design(ref=None)
R       p$get_design(ref = NULL)
```

Retrieve the current design when `ref` is omitted or null, or retrieve an exact historical DES. Returns the declaration fields with exact `ref`, selection rationale, context and metadata-check evidence, or null if no current design is set. Call `p.get_design(ref=design_ref)` or `p$get_design(ref=design_ref)` to inspect an analysis's pinned design.

### get_condition

```text
Python  p.get_condition()
R       p$get_condition()
```

Read the current design's condition column name or null. Example `p.get_condition()` or `p$get_condition()`.

### get_levels

```text
Python  p.get_levels()
R       p$get_levels()
```

Read ordered available condition levels or null. Python returns a list and R a character vector when configured. Example `p.get_levels()` or `p$get_levels()`.

### get_selected_levels

```text
Python  p.get_selected_levels()
R       p$get_selected_levels()
```

Read ordered selected levels or null. Python returns a list and R a character vector when configured. Example `p.get_selected_levels()` or `p$get_selected_levels()`.

### get_reference_level

```text
Python  p.get_reference_level()
R       p$get_reference_level()
```

Read the current reference level or null when unspecified. Example `p.get_reference_level()` or `p$get_reference_level()`.

### get_replicate

```text
Python  p.get_replicate()
R       p$get_replicate()
```

Read the declared replicate column name or null when unspecified. Example `p.get_replicate()` or `p$get_replicate()`.

### get_design_summary

```text
Python  p.get_design_summary()
R       p$get_design_summary()
```

Read compact current design metadata with condition, up to five selected levels, reference level, replicate, design revision and truncation. Returns null when no design is configured. Call `p.get_design_summary()` or `p$get_design_summary()`. Use [get_design](#get_design) for all levels or a pinned historical design.

## Presentation and filenames

### set_presentation

```text
Python  p.set_presentation(ref, *, primary_topic, description, generated_on, topics=<omitted>, questions=<omitted>, uses=<omitted>, title=<omitted>, subtitle=<omitted>, reason)
R       p$set_presentation(ref, primary_topic, description, generated_on, topics = NULL, questions = NULL, uses = NULL, title = NULL, subtitle = NULL, reason)
```

Stage presentation metadata on the latest exact DATA or FIG revision. Supply `primary_topic`, short token `description`, the actual generation day as `YYYY-MM-DD`, and a reason. Optional topics, questions, uses, title and subtitle persist when omitted. Use an empty list to clear arrays, or explicit null to clear optional values. The primary topic stays among the topics. Identical descriptors return the original ref. A revised descriptor returns a new ref without reading or renaming the file. Example `p.set_presentation(figure_ref, primary_topic="QC", description="sample-counts", generated_on="2026-11-06", reason="Label retained panel")` or the corresponding R call. See [paired examples and field constraints](api/OUTPUT_DISCOVERY_V1.md#exact-names-and-presentation-revisions).

### output_name

```text
Python  p.output_name(ref)
R       p$output_name(ref)
```

Derive a filename and tag for an exact DATA or FIG using its recorded presentation. Returns the filename, `output_key`, tag, exact `ref`, project identity and presentation fields. Requires a recorded local file locator with size and supported extension. Missing or invalid presentation rejects. It does not check availability or change any file. Use `p.output_name(presented_ref)` or `p$output_name(presented_ref)` with the reference returned by [set_presentation](#set_presentation).

### export_named_output

```text
Python  p.export_named_output(ref, destination_dir)
R       p$export_named_output(ref, destination_dir)
```

Verify and publish a copy of an exact DATA or FIG under the derived name in an existing destination directory. Requires valid presentation, a local regular file and a recorded matching digest. An existing destination or mismatch rejects. Returns the copied path, filename, project identity, source ref, digest and integrity. The copy does not change the registry. Example `p.export_named_output(presented_ref, destination_dir)` or `p$export_named_output(presented_ref, destination_dir)`. See [copy requirements](api/OUTPUT_DISCOVERY_V1.md#optional-named-copy).

## Graphs and chronology

### dependencies

```text
Python  p.dependencies(ref, direction, depth=1, limit=20)
R       p$dependencies(ref, direction, depth = 1, limit = 20)
```

Follow bounded recorded upstream or downstream edges for an exact ref. `direction` is `"upstream"` or `"downstream"`, with depth 1–3 and edge limit 1–100. Returns exact refs, typed `edges`, `unknown` and truncation. Use `p.dependencies(figure_ref, "upstream", depth=2)` or `p$dependencies(figure_ref, "upstream", depth=2L)` for a local lineage query. See [edge types and bounds](api/RESULTS_V1.md#forward-and-backward-dependencies).

### export_graph

```text
Python  p.export_graph(ref=None, direction='upstream', depth=3, limit=100, format='dot', filters=None, offset=0, style='detailed', lineage_roots=None)
R       p$export_graph(ref = NULL, direction = "upstream", depth = 3L, limit = 100L, format = "dot", filters = NULL, offset = 0L, style = "detailed", lineage_roots = NULL)
```

Omit `ref` for an overview page or pass an exact ref for focused lineage. `direction` is `"upstream"` or `"downstream"`, depth 1–10, and node limit 1–100. The graph is capped at 100 edges and 128 KiB. Overview accepts `filters` and zero-based `offset` and inspects up to 1,000 record slots and 1,000 edges per page. Use `format="structured"` for the versioned graph report with nodes, edges, scan counts, truncation, cycle qualification and `next_offset`. Overview pages contain only edges between nodes on that page. The default `format="dot"` returns detailed DOT text. `style="presentation"` works only for DOT and can color declared lineage from up to six exact DATA roots. In R use a list of refs or a character vector of exact DATA revisions for `lineage_roots`. Focused presentation hides revision-only context. Use the detailed view for that context.

For a name search, use `p.export_graph(format="structured", filters={"asset_type": "DATA", "query": "Toy counts"})` or the R call with `filters=list(asset_type="DATA", query="Toy counts")`. Inspect `truncation` and follow `next_offset` with the same filters and unchanged handle. To draw lineage, use `p.export_graph(figure_ref, style="presentation", lineage_roots=[data_ref])` or the R call with `lineage_roots=list(data_ref)`. This returns text. Save it as a DOT file and use an optional Graphviz installation for rendering. See [graph filters, bounds and diagram semantics](api/GRAPH_V1.md) and [the paired lineage demo](LINEAGE_DEMO.md).

### timeline

```text
Python  p.timeline(view='registration', order='oldest', limit=10, cursor=None)
R       p$timeline(view = "registration", order = "oldest", limit = 10L, cursor = NULL)
```

Page recorded UTC chronology. `view="registration"` shows every record revision. `view="runs"` uses qualifying recorded wrapper start times and preserves unqualified times separately. `order` is `"oldest"` or `"newest"`, with unknown times last. Returns `rows`, timing `relations`, qualifiers, and `next_cursor` in a report capped at 64 KiB. Use limit 1–20. A cursor is valid for the same view/order on the same unchanged handle. Restart paging after an edit or reopen. Example `p.timeline(view="runs", order="newest")` or `p$timeline(view="runs", order="newest")`. See [timeline fields](api/CHRONOLOGY_V1.md#read-the-project-timeline).

### timeline_summary

```text
Python  p.timeline_summary(view='registration', order='oldest', limit=10, cursor=None)
R       p$timeline_summary(view = "registration", order = "oldest", limit = 10L, cursor = NULL)
```

Format the same timeline page as text, including continuation when present. Use `p.timeline_summary()` or `p$timeline_summary()` for a human-readable registration page. Use the structured timeline for programmatic refs and cursors.

### execution_history

```text
Python  p.execution_history(analysis_ref=None, protocol_ref=None, limit=10, offset=0)
R       p$execution_history(analysis_ref = NULL, protocol_ref = NULL, limit = 10L, offset = 0L)
```

Page the recorded run receipts in reverse registration-slot order, for the whole project or with at most one exact ANA or protocol DEC selector. Returns `entries`, pairwise timing `relations`, selector, loaded revision and `scan.next_offset`/cutoffs. Limit 1–20. Each page examines up to 1,000 slots and is capped at 64 KiB. Continue on the same unchanged handle with the same selector. Missing, open, failed or imported evidence remains qualified. Use `p.execution_history(analysis_ref=analysis_ref)` or `p$execution_history(analysis_ref=analysis_ref)`. See [chronology and paging](api/CHRONOLOGY_V1.md). Dependency order and declared protocol intent are separate.

### execution_history_summary

```text
Python  p.execution_history_summary(analysis_ref=None, protocol_ref=None, limit=10, offset=0)
R       p$execution_history_summary(analysis_ref = NULL, protocol_ref = NULL, limit = 10L, offset = 0L)
```

Format the same bounded history page as text. Example `p.execution_history_summary(limit=5)` or `p$execution_history_summary(limit=5L)`. Use the structured query for exact refs and page offsets.

## Decisions, protocols, execution, and comparisons

### record_decision

```text
Python  p.record_decision(text, reason, targets)
R       p$record_decision(text, reason, targets = list())
```

Stage a generic DEC note with text, reason and an array of exact target refs. Returns a new exact DEC. Use this to retain an ordinary note or rationale. Example `p.record_decision("Reviewed QC table", "Synthetic example", [data_ref])` or `p$record_decision("Reviewed QC table", "Synthetic example", list(data_ref))`. For declared scientific status and supporting or contradictory evidence, use the typed writer.

### record_scientific_decision

```text
Python  p.record_scientific_decision(text, reason, subjects, scientific_status, supporting=None, contradictory=None, ref=None)
R       p$record_scientific_decision(text, reason, subjects, scientific_status, supporting = NULL, contradictory = NULL, ref = NULL)
```

Stage a DEC with declared `scientific_status` of `proposed`, `provisional`, `approved`, or `superseded`. Each subject includes `ref` and may include `cluster_id` for DATA or ANA and a text `annotation`. Supply supporting or contradictory exact refs when available. To revise, pass the latest exact `ref`. The subject identities stay fixed. Returns the staged DEC ref. Approval is a recorded declaration and remains unauthenticated. See [paired decision examples](api/DECISIONS_V1.md#record-and-revise).

### get_decision

```text
Python  p.get_decision(ref)
R       p$get_decision(ref)
```

Read an exact DEC with `text`, `reason`, `targets`, `record_status`, typed `scientific` metadata, `approval`, and unknown/imported qualifiers. Legacy notes can have null `scientific`. Protocol or comparison records use their own getters and have approval `not_applicable` here. Example `p.get_decision(decision_ref)` or `p$get_decision(decision_ref)`.

### register_protocol

```text
Python  p.register_protocol(name, steps, reason, ref=None)
R       p$register_protocol(name, steps, reason, ref = NULL)
```

Stage ordered intended work in a typed DEC. Each step needs a unique `step_id`, exact `analysis_ref` with known inputs, code, method and parameters, and `required_outputs`. Optional data-dependent parameters, seeds and environment refs describe intent. A revision requires the latest exact protocol ref. Returns the staged DEC. Approve separately through a scientific decision about the exact protocol revision. See [step definitions and paired examples](api/PROTOCOLS_V1.md#record-the-intended-work).

### get_protocol

```text
Python  p.get_protocol(ref)
R       p$get_protocol(ref)
```

Read an exact DEC protocol with `name`, `record_status`, `protocol` containing the ordered steps, and unknown/imported qualifiers. Unsupported, absent or malformed descriptors produce unknown markers. Call `p.get_protocol(protocol_ref)` or `p$get_protocol(protocol_ref)`. This does not inspect payloads or run the protocol.

### compare_protocol

```text
Python  p.compare_protocol(ref, executions, approval_ref=None)
R       p$compare_protocol(ref, executions, approval_ref = NULL)
```

Compare one exact protocol against an ordered `executions` array of unique `step_id` and exact `analysis_ref` pairs. A terminal receipt ref is preferred when run evidence exists. Optional `approval_ref` must identify a matching scientific declaration to report recorded approval. Returns expected and submitted order, qualified `observed_order`, per-step mismatches and unknowns, extra steps and approval. This compares recorded evidence without executing steps. See [paired comparison examples](api/PROTOCOLS_V1.md#compare-selected-evidence).

### run_analysis

```text
Python  p.run_analysis(analysis_ref, entry_point, outputs=[], seeds=None, verify_inputs=True, verify_code=True)
R       p$run_analysis(analysis_ref, entry_point, outputs = list(), seeds = NULL, verify_inputs = TRUE, verify_code = TRUE, object_checks = list())
```

Explicitly execute one trusted native source file already registered as the analysis's single code snapshot. Specify the named `entry_point`. The function receives `inputs` (exact local paths), `params`, `seeds`, and requested `outputs` (paths). Each output descriptor has a new `path` and `kind="result"` or `kind="figure"` with `type`. Parents must exist. The wrapper executes the snapshot's top-level code and callback with native process permissions. Pass only code authorized for execution. Seeds are supplied declarations for the code to apply.

Default input verification streams pinned files at preflight, after top-level source execution, and after the callback, including callback errors. The snapshot always receives a digest check. `verify_code` additionally checks the current original. R `object_checks` can supply exact input refs and trusted `get_object` functions, with optional assay and layer. Every configured check must pass at each checkpoint.

The wrapper durably records started and terminal ANA revisions through `save_and_confirm()`, including any other pending edits at those boundaries. Captured outputs are registered against the started run ref. A successful return includes `run_ref`, exact terminal `receipt_ref`, phases, input/output evidence, and persistence. A run failure can raise an error with a durable receipt and leave files or captured output registrations behind. Inspect the Python error's `receipt` attribute or the R condition's `receipt` field when present. Preserve the evidence and inspect the exact outcome before retrying. Receipts qualify observed wrapper activity and leave input consumption and scientific validity unknown. See [function definitions, paired calls and failure handling](api/EXECUTION_V1.md).

### get_execution

```text
Python  p.get_execution(ref)
R       p$get_execution(ref)
```

Read the receipt on an exact ANA revision. If valid, returns run and template refs, phase flags, outcome, inputs and outputs, timestamps, and evidence qualifiers. A missing or malformed receipt gives `status="unknown"`. Imported receipts remain untrusted claims. Pass the terminal `receipt_ref` returned by [run_analysis](#run_analysis), for example `p.get_execution(receipt["receipt_ref"])` or `p$get_execution(receipt$receipt_ref)`.

### execution_summary

```text
Python  p.execution_summary(ref)
R       p$execution_summary(ref)
```

Format a compact receipt card for one exact ANA. Example `p.execution_summary(receipt["receipt_ref"])` or `p$execution_summary(receipt$receipt_ref)`. Use the structured getter for exact phases, checkpoints and output refs.

### register_comparison_plan

```text
Python  p.register_comparison_plan(name, mode, original, intended, criteria, reason, ref=None)
R       p$register_comparison_plan(name, mode, original, intended, criteria, reason, ref = NULL)
```

Stage a typed DEC plan for `"reproduce"`, `"reapply"`, or `"rerender"`. `original` holds `analysis_ref` (an exact ANA, preferably the terminal receipt when recorded) and `outputs` (named slots with exact DATA/FIG refs). `intended` binds ordered exact input refs and an explicit retrospective flag, with mode-specific requirements. `criteria` specifies comparators, requirements and exact output slots, with at least one required output or visual criterion. Returns a staged exact plan ref. Use the latest plan ref to revise. The writer validates declarations and does not compute comparison metrics. See [plan fields and criteria](api/COMPARISONS_V1.md#plan-fields) and the [synthetic comparison fixture](../tests/test_comparison.py).

### record_comparison_assessment

```text
Python  p.record_comparison_assessment(plan_ref, candidate, observations, reason, ref=None)
R       p$record_comparison_assessment(plan_ref, candidate, observations, reason, ref = NULL)
```

Stage a typed DEC against an exact plan and a candidate with matching named output slots. Supply an observations array with `criterion_id`, declared verdict, observed value, rationale, exact evidence, subjects and comparator per item. Optional contradiction and review refs qualify the submitted evidence. Revising requires the latest matching assessment ref and preserves its plan and candidate binding. Returns a staged exact assessment ref. See [evidence binding rules](api/COMPARISONS_V1.md#assessment-and-evidence-binding) and the [synthetic R fixture](../r/tests/comparison.R).

### get_comparison

```text
Python  p.get_comparison(ref, scientific_acceptance_ref=None)
R       p$get_comparison(ref, scientific_acceptance_ref = NULL)
```

Read an exact plan or assessment with descriptor, metadata consistency, context, criteria, evidence qualifications, and effective `PASS`, `FAIL`, or `UNKNOWN` verdict. A plan alone reports UNKNOWN. Optional `scientific_acceptance_ref` checks a separate exact scientific decision about this comparison revision. No payloads are read and the report qualifies the verdict as submitted evidence. Example `p.get_comparison(assessment_ref)` or `p$get_comparison(assessment_ref)`. See [verdict rules](api/COMPARISONS_V1.md#verdicts-and-limits).

## Save, share, and recover

### save

```text
Python  p.save()
R       p$save()
```

Commit all staged registry changes and pending code snapshots. Returns `state_revision` and `transaction`. A dirty save acquires the writer lock and checks the full saved registry digest before publishing a new revision. A clean call returns the loaded revision and transaction without a freshness check. If a lock or stale-state error occurs, keep pending edits and any written files, then reconcile against a separately opened handle. Example `p.save()` or `p$save()`. Use the receipt below when reporting a durable write.

### save_and_confirm

```text
Python  p.save_and_confirm()
R       p$save_and_confirm()
```

Commit the same batch as [save](#save) and return `status`, `scope="all_pending_changes"`, `previous_committed_revision`, `committed_revision`, `transaction_id` and `registry_written`. Report a new durable registry write when `status="persisted"` and `registry_written` is true. `no_changes` means the handle was clean. A save error propagates. Example `p.save_and_confirm()` or `p$save_and_confirm()`.

### preview_export

```text
Python  p.preview_export(mode, include=None, exclude=None, redact=None)
R       p$preview_export(mode, include = list(), exclude = NULL, redact = NULL)
```

Review a ZIP plan for a saved project. `mode="context"` carries registry metadata only. `mode="working"` adds local file payloads and applicable code snapshots for selected exact DATA, FIG or ANA refs in `include`. Selecting a figure does not recursively include its DATA inputs or script imports. Both modes expose full registry metadata and history, including metadata for omitted payloads. Redaction and exclusion are unsupported. Review `state`, `omitted`, `missing`, and the file inventory. Python `files` lists selected payloads. R `files` includes metadata and payloads, with selected payloads also in `payload`. Preview reads registry metadata, checks locator availability and hashes selected files. Use the same handle and runtime for preview and export. Unsaved edits and missing or changed selected files block preview. Preview from a fresh loaded revision when other writers have saved. Python also rejects a stale handle during preview. Example `p.preview_export("working", include=[figure_ref, data_ref])` or the R call with `include=list(figure_ref, data_ref)`. See [sharing examples](../README.md#share-a-result).

### export_zip

```text
Python  p.export_zip(plan, path)
R       p$export_zip(plan, path)
```

Write the reviewed, unedited plan to a new archive path in an existing directory. The export checks the plan against registry and payload digests and validates the packaged ZIP before exclusive publication. A stale plan or changed payload requires a fresh preview and review. Python returns `path`, `sha256`, `mode`, and `status="inspectable"`. R invisibly returns the supplied path. Example `p.export_zip(plan, zip_path)` or `p$export_zip(plan, zip_path)`. The archive contains the selected materials for inspection. Reuse depends on verified inputs, omitted dependencies and the available runtime.

### import_zip

```text
Python  ProjectBundle.import_zip(path, project_dir)
R       ProjectBundle$import_zip(path, project_dir)
```

Validate and import an archive into a new, nonexistent project directory with an existing parent. The importer verifies member safety and file digests and returns a loaded handle. It preserves exact record refs and qualifies imported evidence. It does not execute scripts or fetch omitted files. Rebinding an omitted external file is a separate deliberate action. Example `ProjectBundle.import_zip(zip_path, new_root)` or `ProjectBundle$import_zip(zip_path, new_root)`. If publication fails partway, inspect the reported destination before retrying. See [recovery](RECOVERY.md).

### rebind_external

```text
Python  p.rebind_external(ref, path, reason)
R       p$rebind_external(ref, path, reason)
```

Stage a local binding for the external locator of an exact record, with a reason. The new target must be an existing regular file and match the recorded digest when available. The binding applies by locator, which may affect other records sharing it. It creates no record revision and returns no ref. Inspect other affected refs and use strict verification for the intended input. Example `p.rebind_external(data_ref, local_file, "Restored registered copy")` or `p$rebind_external(data_ref, local_file, "Restored registered copy")`. Save the staged binding after review.
