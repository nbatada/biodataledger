# Optional Python plotting

From the 0.18.0 source checkout on `main`, install plotting into your
chosen environment with `python -m pip install './python[plotting]'`. Pin the
tested Git commit for reuse; the published 0.17.0 tag does not contain this module.
Core registry imports do not load NumPy, pandas or Matplotlib. Access plotting
through `import biodataledger as bdl; bdl.pl.pca(...)`. This module consumes
prepared tables and matrices. It performs no PCA, UMAP, normalization, differential
expression, clustering, aggregation, statistical testing or registration.

Single plots return editable Matplotlib `Axes`; `umap_split` and `compose` return
editable `Figure` objects. Functions do not call `show`, save files or modify input
objects. Pass `ax=` to draw on a caller-owned axis. Explicit caller saves and edits
remain ordinary Matplotlib operations.

```python
import pandas as pd
import biodataledger as bdl

samples = pd.DataFrame({
    "sample": ["S1", "S2", "S3", "S4"],
    "condition": ["control", "control", "treated", "treated"],
    "PC1": [-2., -1., 1., 2.], "PC2": [-1., 1., 1., -1.],
})
ax = bdl.pl.pca(samples, x="PC1", y="PC2", sample_id="sample",
                color="condition", variance_percent=[42, 18],
                palette={"control": "#377EB8", "treated": "#E41A1C"})
ax.set_title("Prepared sample coordinates")
ax.figure.savefig("pca.svg")  # Explicit saving, outside the renderer.
```

The coordinates and variance in this example are synthetic supplied values.
`variance_percent` is exactly two nonnegative percentages totaling at most 100.
`sample_id` optionally checks unique nonmissing sample identities;
`label_samples=True` adds those IDs without automatic label placement.

| Function | Required keyword arguments | Behavior |
| --- | --- | --- |
| `pca(table, ...)` | `x`, `y` | Existing coordinates; optional sample IDs, variance percentages and color. |
| `umap_split(table, ...)` | `x`, `y`, `split_by` | Existing coordinates with shared global coordinate bounds and color mapping. |
| `violin_qc(table, ...)` | `group`, `value`, `value_label` | One prepared QC metric. Exact points plus native violin KDE inside observed range; singleton/constant groups show points only. |
| `group_comparison(table, ...)` | `group`, `value`, `sample_id`, `observation_unit`, `value_label` | One point per unique observation ID, with unit in title. No summaries, significance or jitter. |
| `heatmap(matrix, ...)` | `value_label` | Numeric matrix in supplied order, no scaling/clustering. DataFrame labels retained; unlabeled arrays require `row_labels`, `column_labels`. |
| `volcano(table, ...)` | `log2fc`, `padj`, `contrast`, `lfc_threshold`, `padj_threshold` | Existing DE results; inclusive threshold highlighting. Zero adjusted p requires `zero_p_floor`. |
| `ma(table, ...)` | `abundance`, `log2fc`, `contrast`, `abundance_scale` | Existing values; `linear`, `log2`, `log10` describes abundance and does not transform it. Linear abundance must be nonnegative. |

Tables can be pandas DataFrames or objects accepted by `pd.DataFrame`. Column names
are explicit strings. Numeric plot columns must contain finite real numbers;
missing values, empty tables and duplicate column names are refused. No row is
silently removed. Prepare repeated measures explicitly: `group_comparison` requires
unique supplied observation IDs and does not infer biological replication.
`value_label` should name the metric and units, such as `Library size (million reads)`.

Embedding `color` names a table column. `color_kind="categorical"` is the default;
set `color_kind="continuous"` for numeric values. Optional category palettes must
map every observed category exactly once. `group_order` and `split_order` must
contain every observed category exactly once; default order is first appearance,
not unused pandas categorical levels. Continuous colors use `cmap="viridis"` and
one shared `Normalize` over the full input, including split panels. `vmin`/`vmax`
can expand bounds but cannot clip values. The same restriction applies to heatmaps.
Split embeddings use equal x/y aspect to preserve geometry.
Coordinate bounds in split panels include every supplied point plus 5% padding
(constant axes receive nonzero padding). No percentile trimming is performed.

Volcano adjusted p values must be in [0, 1]; the threshold is in (0, 1] and fold
threshold nonnegative. Red means both `abs(log2fc) >= lfc_threshold` and
`padj <= padj_threshold`; grey means otherwise. The supplied `contrast` must state
the numerator/reference direction used for log2FC. No test is fitted. Zero p values
are refused unless an explicit positive `zero_p_floor` is provided. Only zeros
are displayed at that floor, which must not exceed the threshold or any positive
p value. The y-axis states this substitution; original values remain untouched.
Positive p values are never clipped. `ma` uses the same contrast convention.
DE y/x labels name adjusted p and log2 fold change explicitly, regardless of
the supplied column names.

## Native composition and styling

```python
fig = bdl.pl.compose(
    [lambda ax: bdl.pl.pca(samples, x="PC1", y="PC2", ax=ax),
     lambda ax: bdl.pl.pca(samples, x="PC2", y="PC1", ax=ax)],
    ncols=2, labels=["a", "b"], width_ratios=[2, 1], height_ratios=[1],
)
fig.axes[0].set_ylabel("Edited axis label")
```

Callbacks receive an axis in row-major order. `labels` supplies one string per
panel; positive `width_ratios` and `height_ratios` must match actual grid columns
and rows. `figsize=(width, height)` is in inches. Composition renders into shared
axes. It does not accept or copy arbitrary pre-existing figures or rasterize
artists. Added colorbars belong to the same Figure. Caller edits remain native
Matplotlib and can change scientific meaning; inspect the finished result.
Caller-owned axes retain caller settings, including fixed axis limits; those
settings can hide values, so review them before retaining an output.

Default styling uses Matplotlib settings without copying CellStyle. If CellStyle
is separately installed, style a returned plot explicitly using its public API:

```python
from cellstyle import style_plot
style_plot(ax)
```

See CellStyle's installed documentation for supported options. It is not a
BioDataLedger dependency. Default appearance is provisional and has not been
accepted by scientist visual review.

Run `examples/plotting_python.py --output NEW_DIRECTORY` for a synthetic SVG gallery
covering all seven functions. It refuses an existing output directory. The example
saves explicitly and never opens a GUI. Retained scientific outputs still need
normal explicit BioDataLedger registration with known data/code/method/parameters;
plot creation alone records no provenance or scientific acceptance.
