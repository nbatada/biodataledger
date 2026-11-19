# Work through a synthetic project in R or Python

Copy the contents of [input-files](input-files/) to a new project directory and set `project_root` to its path in your chosen language. Run the four examples for that language in order. The figures and scripts are supplied fixtures. Set `archive_path` to a new ZIP filename and `import_root` to a new directory before the sharing step.

## Record data, analyses and figures

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
a = p.register_analysis("QC", inputs=[d.ref], code="qc.py",
                        method="synthetic display", params={"min_genes": 200})
# After the analysis declaration is staged, native analysis can use d.path
# and write its outputs. The figures here are already saved synthetic fixtures.
f1 = p.register_figure("library.svg", type="qc", analysis=a)
f2 = p.register_figure("genes.svg", type="qc", analysis=a)
p.save()
print(p.status())
figures = p.find_figures(type="qc")
figure = p.get_figure(path="library.svg")
print(figure.inputs, figure.code, figure.params, figure.provenance)
print(p.get_figure(f1, compact=True))
preserved_source = p.read_figure_source(f1)
print(preserved_source["content"].decode("utf-8"))
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
a <- p$register_analysis("QC", inputs = list(d$ref), code = "qc.R",
                        method = "synthetic display", params = list(min_genes = 200))
# After the analysis declaration is staged, native analysis can use d$path
# and write its outputs. The figures here are already saved synthetic fixtures.
f1 <- p$register_figure("library.svg", type = "qc", analysis = a)
f2 <- p$register_figure("genes.svg", type = "qc", analysis = a)
p$save()
print(p$status())
figures <- p$find_figures(type = "qc")
figure <- p$get_figure(path = "library.svg")
print(list(inputs = figure$inputs, code = figure$code, params = figure$params, provenance = figure$provenance))
print(p$get_figure(f1, compact = TRUE))
preserved_source <- p$read_figure_source(f1)
cat(rawToChar(preserved_source$content))
```

</details>

## Conditions and levels

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

## Share a result

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

## Follow analyses and their data

<details>
<summary>Python</summary>

```python
print(p)
print(p.timeline_summary(view="analyses"))
print(p.timeline_summary(view="registration"))
print(p.timeline_summary(view="runs"))
page = p.timeline(view="analyses", order="oldest", limit=2)
if page["next_cursor"] is not None:
    next_page = p.timeline(view="analyses", order="oldest", limit=2,
                           cursor=page["next_cursor"])
```

</details>

<details>
<summary>R</summary>

```r
print(p)
cat(p$timeline_summary(view = "analyses"), "\n")
cat(p$timeline_summary(view = "registration"), "\n")
cat(p$timeline_summary(view = "runs"), "\n")
page <- p$timeline(view = "analyses", order = "oldest", limit = 2L)
if (!is.null(page$next_cursor)) {
  next_page <- p$timeline(view = "analyses", order = "oldest", limit = 2L,
                          cursor = page$next_cursor)
}
```

</details>
