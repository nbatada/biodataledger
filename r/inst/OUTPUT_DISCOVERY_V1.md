# Name and find retained outputs

This feature is available in the source checkout and is unreleased.

Register an existing file first. Then describe the retained output with
`set_presentation` and use its **returned exact revision** to suggest a filename
or make an optional named copy. No filename is reserved before registration.
The registered file stays at its original location. Browsing, naming and finding
outputs require no copies, even for large scientific data.

## A retained figure and data table

The SVG is a placeholder and the rendering-input link is illustrative. These
declarations do not demonstrate execution or actual data consumption. In analysis
work, use the paths of your real saved files and supply your recorded generation
date.

```python
from pathlib import Path
from tempfile import TemporaryDirectory
from biodataledger import ProjectBundle

with TemporaryDirectory() as folder:
    root = Path(folder)
    counts = "sample,reads\nS1,10\nS2,20\n"
    (root / "raw.csv").write_text(counts)
    (root / "samples.csv").write_text(counts)
    svg = '<svg xmlns="http://www.w3.org/2000/svg"/>'
    (root / "plot.svg").write_text(svg)
    (root / "qc.py").write_text("from pathlib import Path\nPath('samples.csv').write_text(Path('raw.csv').read_text())\n")
    (root / "plot.py").write_text(f"from pathlib import Path\nPath('plot.svg').write_text({svg!r})\n")
    project = ProjectBundle.create("Synthetic donor QC", root)
    raw = project.register_data("raw.csv", "input", hash=True)
    analysis = project.register_analysis("Inspect donor QC", [raw], code=["qc.py", "plot.py"])
    data = project.register_result("samples.csv", analysis, hash=True)
    data = project.set_presentation(
        data, primary_topic="QC-filtering", description="sample-counts",
        generated_on="2026-11-05", questions=["Which samples meet the QC criteria?"],
        reason="Describe the retained sample table",
    )
    figure = project.register_figure(
        "plot.svg", "qc", analysis=analysis,
        figure_sources={"rendering_inputs": [data], "relationship": "declared",
                        "generating_code": {"record": analysis, "index": 1}},
    )
    figure = project.set_presentation(
        figure, primary_topic="QC-samples", description="donor-view",
        generated_on="2026-11-05", topics=["CLONALITY"],
        questions=["How are donors represented?", "Which donors contribute clones?"],
        uses=[{"kind": "slide", "document_id": "lab-meeting-2026-11",
               "item_id": "donor-qc", "title": "Donor representation"}],
        title="Donor representation", subtitle="Synthetic example",
        reason="Record the figure labels and slide link",
    )
    project.save_and_confirm()
    name = project.output_name(figure)  # 20261105_QC-samples_F001r2_donor-view.svg
    qc = project.find_outputs(topic="QC")  # includes QC-filtering and QC-samples
    clone_view = project.find_outputs(topic="CLONALITY", document_id="lab-meeting-2026-11")
    info = project.get_info(clone_view["items"][0]["ref"])
    slide_links = info["presentation"]["uses"]
    plotting_script = info["plotting_code"]["generating_code"]
    rendering_inputs = info["rendering_inputs"]["items"]
    analysis_info = project.get_info(analysis)  # Named inputs and immediate outputs

    copies = root / "copies"
    copies.mkdir()
    exported = project.export_named_output(figure, copies)  # Optional
```

The same workflow in R:

```r
library(BioDataLedger)
root <- tempfile("output-discovery-")
dir.create(root)
counts <- c("sample,reads", "S1,10", "S2,20")
writeLines(counts, file.path(root, "raw.csv"))
writeLines(counts, file.path(root, "samples.csv"))
writeLines('<svg xmlns="http://www.w3.org/2000/svg"/>', file.path(root, "plot.svg"))
writeLines("file.copy('raw.csv', 'samples.csv', overwrite = TRUE)", file.path(root, "qc.R"))
writeLines("writeLines('<svg xmlns=\"http://www.w3.org/2000/svg\"/>', 'plot.svg')",
           file.path(root, "plot.R"))
project <- ProjectBundle$create("Synthetic donor QC", root)
raw <- project$register_data("raw.csv", "input", hash = TRUE)
analysis <- project$register_analysis("Inspect donor QC", list(raw), code = c("qc.R", "plot.R"))
data <- project$register_result("samples.csv", analysis, hash = TRUE)
data <- project$set_presentation(
  data, primary_topic = "QC-filtering", description = "sample-counts",
  generated_on = "2026-11-05", questions = "Which samples meet the QC criteria?",
  reason = "Describe the retained sample table"
)
figure <- project$register_figure(
  "plot.svg", "qc", analysis = analysis,
  figure_sources = list(rendering_inputs = list(data), relationship = "declared",
                        generating_code = list(record = analysis, index = 1L))
)
figure <- project$set_presentation(
  figure, primary_topic = "QC-samples", description = "donor-view",
  generated_on = "2026-11-05", topics = "CLONALITY",
  questions = c("How are donors represented?", "Which donors contribute clones?"),
  uses = list(list(kind = "slide", document_id = "lab-meeting-2026-11",
                   item_id = "donor-qc", title = "Donor representation")),
  title = "Donor representation", subtitle = "Synthetic example",
  reason = "Record the figure labels and slide link"
)
project$save_and_confirm()
name <- project$output_name(figure)  # 20261105_QC-samples_F001r2_donor-view.svg
qc <- project$find_outputs(topic = "QC")
clone_view <- project$find_outputs(topic = "CLONALITY", document_id = "lab-meeting-2026-11")
info <- project$get_info(clone_view$items[[1]]$ref)
slide_links <- info$presentation$uses
plotting_script <- info$plotting_code$generating_code
rendering_inputs <- info$rendering_inputs$items
analysis_info <- project$get_info(analysis)  # Named inputs and immediate outputs

copies <- file.path(root, "copies")
dir.create(copies)
exported <- project$export_named_output(figure, copies)  # Optional
unlink(root, recursive = TRUE)  # Only this synthetic project
```

## Exact names and presentation revisions

The name has four underscore-separated fields:
`YYYYMMDD_PRIMARY-TOPIC_OUTPUTKEY_DESCRIPTION.ext`. The date is the
caller-declared generation day, recorded as a real `YYYY-MM-DD`. The library
does not infer it from a file timestamp, registration time or run. The extension
comes from the recorded local file locator: an ordinary final extension of
1–16 ASCII letters/digits, or `.tar.gz`. Names are capped at 255 bytes. URI and
directory records have no suggested filename. Naming does not check current file
availability.

Use the returned reference object or canonical `FIG-001@2` / `DATA-001@2`.
The new methods also accept exact project-local keys such as `F001r2` / `D001r2`;
`A001r1` works for analysis inspection in `get_info`. Neither the key nor the
filename includes a project ID. Keep the report's project UUID/name and exact ref
when passing the filename or copy to someone else. Existing methods still use
their documented reference syntax.

`set_presentation(ref, primary_topic, description, generated_on, ..., reason)`
requires the latest exact DATA or FIG revision. In Python, all arguments after
`ref` are keyword-only. It stages a metadata revision, leaves all prior revisions
and file bytes intact, and does not move any current pointer. An identical
descriptor on the latest revision returns that ref without adding another revision.
Omitted optional fields keep their prior values from a valid descriptor.
Replacing the primary topic replaces that tag and retains the prior secondary
tags unless you supply a replacement list. Pass an empty list or `None` (`NULL`
in R) to clear topics beyond the primary, questions or uses; pass `None` or
`NULL` to clear a title or subtitle. A missing, invalid or unsupported descriptor
supplies no prior values.
A label-only correction normally repeats the original generation date. Correct an
incorrect recorded date explicitly and state why. The new revision does not mean
the file was regenerated. An earlier filename remains tied to the earlier ref.

`primary_topic` and `description` are ASCII letter/digit tokens with optional
single hyphens between groups (64 and 96 bytes respectively). The primary tag is
always first; up to eight distinct topics total can be recorded, ignoring case
for duplicates. There are up to eight questions and eight uses. Question, title
and subtitle text can contain Unicode and is limited to 256 UTF-8 bytes per item.
Text fields must be nonblank and cannot contain control characters.
Titles and subtitles are optional; no scientific title, sample count, subset or
question is inferred. Each use is a declaration with `kind` (`slide` or
`manuscript`), exact `document_id`, exact `item_id` (each up to 128 bytes), and
`title` (up to 256 bytes). Stable IDs are supplied by the caller; the package
does not open a deck or manuscript to check them. A nonblank `reason` (up to
512 bytes) is required. Python takes lists; R accepts character vectors or lists
for topics/questions and a list of named lists for uses.

A rerun of the same logical artifact can use the existing revision API:
`save_figure(..., ref=...)` for a preserved figure, `register_result(..., ref=...)`
for a derived result, or an allowed `update_record(..., changes={"path": ...})`
file revision. These paths clear the prior presentation on the new revision.
Supply a new explicit generation date and labels after registering the rerun.
A distinct alternative output starts a new ID. Keep the old file or use a managed
copy if the old bytes must remain recoverable. If an external file was overwritten
or removed, its record and name can remain inspectable but an exact old copy may
be unavailable.

## Find and inspect

`output_name(ref)` returns `filename`, `output_key`, the tag `TOPIC:OUTPUTKEY`,
presentation fields, project identity and exact ref. The optional descriptor lives
in `details["biodataledger.presentation"]` as
`biodataledger-presentation/1`. A missing, invalid or unsupported block never
generates a filename. Older records remain readable with their existing details.
Use `set_presentation` to explicitly add or replace a descriptor.

`find_outputs(topic=None, question=None, query=None, kind=None, document_id=None,
limit=20, offset=0, historical=False)` searches the latest DATA and FIG revision
of each ID. Set `historical=True` to include prior exact revisions, for example
to find a formerly linked slide. Filters combine with AND. Topics match any tag,
case-insensitively, with a hyphen boundary: `QC` matches `QC-samples` and
`QC-filtering`, but not `QCness`. Questions match a literal case-insensitive
substring. Every whitespace-separated `query` term must occur in at least one
recorded topic, question, description, title, subtitle or use field (title or IDs).
`document_id` is an exact case-sensitive identity match. `kind` takes DATA or FIG
(or their full names). No fields are inferred from filenames or producer labels.

Results sort by generation day (newest first, unknown last), then exact ID
(ascending), then revision (newest first). The report contains the exact
`total`, zero-based `offset`, `next_offset` (null at the end), and `truncated`
(whether this page omits matches). A page returns at most `limit` summaries
(1–100). Keep the loaded handle unchanged between pages. A search with no semantic
filters includes outputs with missing or unrecognized descriptors and reports
their status. Semantic filters exclude those outputs; `presentation_status_counts`
covers the selected kind and revision scope before applying semantic filters.
Lifecycle status is reported independently.

`get_info(ref, limit=20, offset=0)` inspects an exact DATA, FIG or ANA without
resolving paths. It returns recorded fields, declared presentation, and the
exact analytical source fields when recorded. Each of `record` and
`analytical_source` is omitted whole if it would exceed 16 KiB of JSON. Its
status is then `size_limit`, and the exact `ref` or `analytical_source_ref`
can be passed to the usual getters for full metadata. No individual scientific
values are shortened. Analytical input refs and immediate output edges are separate pages
with their own totals and continuation; the supplied offset applies to both.
Inputs are those declared by the exact analytical source. Input items, output
targets and producers include names, kinds and exact refs; names may be clipped
at 192 UTF-8 bytes, with an explicit flag. Output edges retain the recorded
relationship type. DATA producer means the exact scope transformation; a DATA
parent is separate. FIG producer means its exact linked analysis. ANA output
edges include exact results and linked figures, including historical revisions.

For a FIG, `rendering_inputs` separately pages the exact DATA refs named in
`figure_sources`. `plotting_code.generating_code` shows the selected code owner
ref, zero-based code index, recorded locator, project-relative snapshot path
(when recorded) and digest. `plotting_code.candidates` pages the code entries of
the linked analysis or standalone figure. The same offset applies to these pages.
If no valid generating-code selector was recorded, plotting code stays unknown
even if there are candidates. Selection is a declaration and no snapshot bytes
are inspected here. Use `read_figure_source` when you explicitly want verified
recorded source bytes.

Output edges are recorded relationships, not a complete pipeline or inferred
causal claims. Presentation labels, declared links and an empty page do not
establish execution, completeness of the scientific work, approval or readiness
to reuse.

## Optional named copy

`export_named_output(ref, destination_dir)` copies one exact registered local
file to its suggested filename in an existing directory. It requires a
registered SHA-256 and verifies the staged bytes before publishing the copy
exclusively. Existing files and symlinks are refused. A missing or changed
original cannot be substituted with other bytes. The result gives project,
exact source ref, filename, destination path and matching SHA-256. No export
record is added; neither the source file nor the registry is rewritten.
Save the presentation first when its reference must be recoverable in another
process. Named-copy publication requires hard-link support and is supported on
tested local macOS filesystems.
