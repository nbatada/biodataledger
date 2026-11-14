# Retain figures through approved native renderers

Local, unreleased addition. Use a source build containing this API in both languages;
the published 0.17.0 tag does not contain it. Follow the source-install instructions
in the [Python](PLOTTING_PYTHON.md) or [R](PLOTTING_R.md) plotting guide and start a
fresh session before enabling the policy in a project.

The optional project policy rejects direct figure registration and copying through
the ordinary BioDataLedger API. Existing projects remain unrestricted. Enable the
policy deliberately, then save it at a normal checkpoint:

```python
from biodataledger import ProjectBundle

p = ProjectBundle.open("/path/to/project")
p.require_approved_figures("Retain figures rendered by the native plotting library")
p.save()
assert p.figure_policy() == "approved_renderers_v1"
```

The R equivalents are `p$require_approved_figures(reason)`, `p$figure_policy()` and
`p$save()`. There is no ordinary API to disable an enabled policy. The policy uses
an optional project field in schema 0.4.0. Earlier clients reject that field when
opening a guarded registry. Upgrade both clients before enabling it. Historical
figures remain historical; enabling the policy adds no receipt to them.

## Render and stage a retained figure

Prepare numerical values normally. BioDataLedger invokes one of its fixed native
renderers, writes a fresh image to a unique managed directory, hashes the saved
bytes and stages an exact FIG reference. It does not save other pending edits:

```python
ref = p.render_figure(
    "pca",
    data={"PC1": [1.0, 2.0, 3.0], "PC2": [3.0, 1.0, 2.0]},
    plot_args={"x": "PC1", "y": "PC2"},
    name="Prepared PCA coordinates",
    format="png", width=6, height=4, dpi=300,
)
receipt = p.get_figure(ref).details["renderer_receipt"]
p.save()
```

```r
ref <- p$render_figure(
  "pca", data = data.frame(PC1 = c(1, 2, 3), PC2 = c(3, 1, 2)),
  plot_args = list(x = "PC1", y = "PC2"),
  name = "Prepared PCA coordinates",
  format = "png", width = 6, height = 4, dpi = 300
)
receipt <- p$get_figure(ref)$details$renderer_receipt
p$save()
```

Approved names are `pca`, `umap_split`, `violin_qc`, `group_comparison`, `heatmap`,
`volcano` and `ma`, plus declarative `compose`. Their prepared-data contracts are
documented in [Python plotting](PLOTTING_PYTHON.md) and [R plotting](PLOTTING_R.md).
Plotting dependencies remain optional. Python settings are a plain dictionary;
R settings are a named list. Settings must contain JSON-compatible values and
supported renderer arguments. Data, axes, existing plots, callbacks, arbitrary
function names and output file paths cannot be injected through settings. Python
arguments after `renderer` are keyword-only. An optional exact `analysis` reference
provides inherited declared analytical context.

Formats are `png`, `pdf` and `svg`. Width and height are positive inches, at most
100; dpi is positive and at most 2400. The combined size is limited to 100 million
pixels. Images are written below `.nb_project_bundle/outputs/render-*` without
overwriting previous output. Invalid input, rendering failure or staging failure
restores pending registry edits and removes the newly created rendering directory.
If the failed call created the output parent, it also removes that parent when empty.
Input tables are not registered or copied to disk by this operation.

## Compose declarative panels

Composition accepts prepared data and approved single-axis renderer specifications:

```python
ref = p.render_figure(
    "compose",
    panels=[
        {"renderer": "pca", "data": coordinates,
         "plot_args": {"x": "PC1", "y": "PC2"}},
        {"renderer": "heatmap", "data": prepared_matrix,
         "plot_args": {"value_label": "Prepared expression"}},
    ],
    plot_args={"ncols": 2, "labels": ["a", "b"]},
)
```

In R, use `list(list(renderer = ..., data = ..., plot_args = list(...)), ...)`
and native layout setting `ncol = 2`. Nested composition and `umap_split` panels
are excluded. The library constructs native plotting callbacks or plot objects
internally. Ordinary native plotting remains editable for exploration; retained
guarded figures use a fresh render from the supported settings.

## What is checked

Guarded projects reject `register_figure` and both forms of `save_figure`, including
copies of existing FIG references, with `APPROVED_RENDERER_REQUIRED` and an instruction
to use `render_figure`. Figure auto-registration from `run_analysis` uses the same
gate; callback execution alone cannot make an output an approved rendered figure.
General FIG corrections allow name, lifecycle status and the existing validated
presentation descriptor. They cannot replace file paths, analytical context or a
renderer receipt. Explicit external rebinding requires the recorded digest and
size to match the replacement bytes.

`details.renderer_receipt` is reserved metadata. It records renderer, backend,
package version, UTC render time, output SHA-256, backend-specific implementation
SHA-256, JSON settings, panel renderer/settings declarations, and
`export_settings={format, width, height, units="in", dpi}` for the saved rendering call.
It reports
`verification="local_render_observed"` with
`scientific_acceptance="not_assessed"`. Panel data are excluded. The Python
implementation digest identifies installed plotting-module bytes; the R digest
identifies sorted native plotting function definitions. The clients validate the
receipt structure, export bounds and format, and its binding to the recorded output digest. Use
`resolve_figure(ref, verify="sha256")` or its R equivalent to verify current bytes.
Policy and receipt metadata survive native saves and selected ZIP exchanges.

This records local rendering, not input truth, biological validity, full upstream
execution, human acceptance or cryptographic authentication. The guard applies to
ordinary package APIs; an unrestricted interpreter, shell or direct registry edit
is outside its boundary. Registering an image as DATA does not make it a FIG.
