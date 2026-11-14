# Optional R plotting

These local, unreleased helpers render prepared tables and matrices as editable
`ggplot` objects. Install `ggplot2` separately; composition also needs `patchwork`.
Neither package is required for the core BioDataLedger registry. There is no
Seurat, CellStyle or analysis-runtime dependency.

Install from a source checkout containing this module, not the published 0.17.0
tag. Pin the tested Git commit. To keep your existing scientific environment
unchanged, create a project library directory and install into it:

```sh
mkdir -p /path/to/project-library
R CMD INSTALL --library=/path/to/project-library r
```

In the project's R session, put that library first before loading the package:

```r
.libPaths(c("/path/to/project-library", .libPaths()))
```

Replace the example path with your actual project library. Start a fresh R
session if BioDataLedger was already loaded; changing a library path does not
replace the package already in memory.

```r
library(BioDataLedger)
coordinates <- data.frame(sample = c("s1", "s2", "s3", "s4"),
  PC1 = c(-2, -1, 1, 2), PC2 = c(1, -1, 2, -2),
  condition = c("control", "control", "treated", "treated"))
p <- bdl_pl_pca(coordinates, "PC1", "PC2", color = "condition",
  sample_id = "sample", variance_percent = c(45, 20))
p <- p + ggplot2::theme_bw() + ggplot2::labs(title = "Prepared PCA")
# Save explicitly, then register retained outputs using your analysis provenance.
# ggplot2::ggsave("chosen-new-output.pdf", p, width = 6, height = 4)
```

| Function | Prepared input and contract |
| --- | --- |
| `bdl_pl_pca` | Existing x/y coordinates; optional sample IDs/labels and supplied variance **percentages**. No PCA fitting. |
| `bdl_pl_umap_split` | Existing x/y coordinates and `split_by`; fixed shared bounds and equal coordinate aspect. One colour scale across all panels. Use `color_kind="continuous"` explicitly for numeric colouring. |
| `bdl_pl_violin_qc` | One `group` and numeric `value` column with explicit `value_label`, including units. Density plus all observed points; singleton/constant groups show points only; no random jitter or quantile trimming. Compose calls for different metrics. |
| `bdl_pl_group_comparison` | `group`, numeric `value`, unique `sample_id`, explicit `observation_unit` and `value_label`. Individual points only; no inferred tests or summaries. Caption reports observation counts per group. IDs do not prove independence. |
| `bdl_pl_heatmap` | Finite numeric matrix with unique row/column names and explicit `value_label`. Preserves values, with optional explicit row/column ordering. No scaling, clustering or normalization. |
| `bdl_pl_volcano` | Existing `log2fc` and adjusted `padj`, explicit numerator/reference `contrast`, nonnegative `lfc_threshold`, and `padj_threshold`. Inclusive supplied cutoffs classify nonzero higher/lower values; exact zero is neutral; this is not a new statistical test. |
| `bdl_pl_ma` | Existing abundance and log2 fold change; explicit `contrast` and `abundance_scale` (`linear`, `log2`, `log10`). Scale describes supplied values; it never transforms them. Include quantity/units in `abundance_label`. |
| `bdl_pl_compose` | List of ggplots; optional `ncol`, relative `widths`/`heights`, and one panel label each. Returns native patchwork without rasterizing. |

All selected columns must be nonmissing; numeric values must be finite. Explicit
orders must include every observed level exactly once. Supplied colour bounds
must contain all values: clipping is refused. No functions silently remove rows,
recalculate coordinates or alter the input data. Points can overlap, and editing
the returned plot can change scales or hide observations; assess those edits.

Adjusted probabilities must be in [0,1]. Exact zeros require an explicit
`zero_p_floor` for display, no larger than the threshold or any positive
probability. Only zeros receive that display substitute. The caption discloses
it, and classification uses the original probabilities. Missing or invalid DE
values are refused; prepare and document any exclusions before plotting.

```r
# Native objects remain editable before and after composition.
combined <- bdl_pl_compose(list(p, p + ggplot2::theme_classic()), ncol = 2,
  widths = c(2, 1), labels = c("a", "b"))
```

Default native styling is provisional. It uses classic axes and a bottom legend,
without a copied publication-theme system. If you have a compatible R CellStyle
installation, apply it explicitly to the returned object, for example
`cellstyle::style_plot(p)`. CellStyle is not installed or selected automatically.
Native edits and exports require their own scientific and visual review.

The installed-package synthetic gallery covers all seven functions and native
composition. It creates a **new** output directory and refuses an existing path:

```sh
Rscript examples/plotting_R.R /path/to/new-gallery
```

The example saves PDF plots and a PDF/PNG gallery without opening graphics
windows. Technical rendering is separate from scientist visual acceptance.
Saving does not register provenance automatically: retain the actual source
values, plotting code, parameters and chosen figure revision through your normal
`ProjectBundle` analysis/figure registration and save checkpoint.
