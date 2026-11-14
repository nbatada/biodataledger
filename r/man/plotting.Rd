\name{bdl_pl_pca}
\alias{bdl_pl_pca}
\alias{bdl_pl_umap_split}
\alias{bdl_pl_violin_qc}
\alias{bdl_pl_group_comparison}
\alias{bdl_pl_heatmap}
\alias{bdl_pl_volcano}
\alias{bdl_pl_ma}
\alias{bdl_pl_compose}
\title{Optional Native Plots from Prepared Tables}
\description{Render prepared values as editable ggplot objects. These functions do not fit models, normalize data, compute embeddings or infer scientific acceptance.}
\usage{
bdl_pl_pca(data, x, y, color = NULL,
  color_kind = c("categorical", "continuous"), variance_percent = NULL,
  sample_id = NULL, label_samples = FALSE, palette = NULL,
  color_limits = NULL, xlabel = x, ylabel = y, title = NULL)
bdl_pl_umap_split(data, x, y, split_by, color = NULL,
  color_kind = c("categorical", "continuous"), split_order = NULL,
  sample_id = NULL, palette = NULL, color_limits = NULL,
  xlabel = x, ylabel = y, ncol = NULL, title = NULL)
bdl_pl_violin_qc(data, group, value, value_label, group_order = NULL,
  palette = NULL, title = NULL)
bdl_pl_group_comparison(data, group, value, sample_id, observation_unit,
  value_label, group_order = NULL, palette = NULL, title = NULL)
bdl_pl_heatmap(matrix, value_label, row_order = NULL,
  column_order = NULL, color_limits = NULL, row_label = "Feature",
  column_label = "Sample", title = NULL)
bdl_pl_volcano(data, log2fc, padj, contrast, lfc_threshold,
  padj_threshold, zero_p_floor = NULL, feature = NULL, title = NULL)
bdl_pl_ma(data, abundance, log2fc, contrast, abundance_scale,
  feature = NULL, abundance_label = abundance, title = NULL)
bdl_pl_compose(plots, ncol = NULL, widths = NULL, heights = NULL,
  labels = NULL)
}
\arguments{
\item{data}{A nonempty data frame. Selected values must be nonmissing; numeric plotting values must be finite.}
\item{x, y}{Names of existing coordinate columns; no coordinates are recomputed.}
\item{color}{Optional column name for point colour.}
\item{color_kind}{Categorical by default, or explicit continuous numeric colour.}
\item{variance_percent}{Optional two supplied PCA variance percentages in [0,100], summing to at most 100.}
\item{sample_id}{Column of nonempty unique character sample/observation identifiers; optional for embeddings.}
\item{label_samples}{Whether to add PCA labels from the required sample identifier column.}
\item{palette}{Optional categorical colours, one per observed level, optionally named. Continuous plots accept at least two gradient colours.}
\item{color_limits}{Optional increasing finite colour limits containing all values. Out-of-range values are refused rather than clipped.}
\item{xlabel, ylabel}{Coordinate axis labels.}
\item{title}{Optional plot title.}
\item{split_by}{Column defining UMAP panels. All panels share coordinate and colour scales.}
\item{split_order, group_order, row_order, column_order}{Optional complete permutations of observed labels. Defaults retain first appearance (matrix order for heatmaps).}
\item{ncol}{Optional positive integer number of panel columns.}
\item{group}{Column defining categories.}
\item{value}{Column of prepared numeric observations.}
\item{value_label}{Explicit displayed quantity and units, for example \code{"Expression (log2 CPM)"}.}
\item{observation_unit}{Explicit unit of observation, for example \code{"biological sample"}. Identifiers do not establish biological independence.}
\item{matrix}{Prepared finite numeric matrix with unique nonempty row and column names. No clustering or scaling is performed.}
\item{row_label, column_label}{Heatmap axis labels.}
\item{log2fc, padj}{Names of existing log2 fold change and adjusted-probability columns. Probabilities must be in [0,1].}
\item{contrast}{Explicit numerator/reference contrast description.}
\item{lfc_threshold}{Nonnegative absolute log2 fold change threshold; zero requests no effect-size cutoff. Exact zero fold changes remain neutral.}
\item{padj_threshold}{Adjusted-probability threshold in (0,1]. Threshold comparisons are inclusive.}
\item{zero_p_floor}{Required when probabilities contain zero. Positive display substitute no larger than the threshold or any positive probability; only exact zeros change for display, never threshold classification.}
\item{feature}{Optional column of unique nonempty feature identifiers, retained in plot data.}
\item{abundance}{Name of existing abundance column.}
\item{abundance_scale}{Required \code{"linear"}, \code{"log2"} or \code{"log10"}; describes supplied values, with no transformation. Linear abundance must be nonnegative.}
\item{abundance_label}{Displayed abundance quantity, including any necessary units.}
\item{plots}{Nonempty list of ggplot objects, in display order.}
\item{widths, heights}{Optional positive relative dimensions, one per layout column/row.}
\item{labels}{Optional character vector with one panel tag per plot.}
}
\details{
Plotting requires optional ggplot2, checked only when called. Composition requires
optional patchwork. Core registry use does not require either package.
Violin plots show a kernel density and all observations without random jitter;
singleton or constant groups show only points, without a density. Overlapping points can coincide.
Group comparisons show only individual values, without summary statistics or tests.
Heatmap row order runs top to bottom. Continuous UMAP colour normalization covers
all split panels together. There is no implicit filtering or quantile trimming.
Native themes, scales and layers can be added with standard ggplot syntax.
Composition does not rasterize its component plots. Caller edits can change these
properties and require their own checks. Saving and registration remain explicit.
}
\value{A ggplot object; \code{bdl_pl_compose} returns a patchwork object.}
\examples{
if (requireNamespace("ggplot2", quietly = TRUE)) {
  d <- data.frame(sample = c("s1", "s2"), PC1 = c(-1, 1), PC2 = c(2, -2))
  p <- bdl_pl_pca(d, "PC1", "PC2", sample_id = "sample",
                  variance_percent = c(50, 25))
  p <- p + ggplot2::labs(title = "Prepared PCA")
}
}
