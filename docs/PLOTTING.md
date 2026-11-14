# Reusable scientific plots

Local, unreleased addition. These functions are not in the published 0.17.0 tag.

BioDataLedger's optional plotting module draws from prepared tables and existing
coordinates. Use it without opening a ledger. It returns native objects so you can
adjust the figure with familiar plotting tools.

| Purpose | Python | R |
| --- | --- | --- |
| Existing sample PCA coordinates | `bdl.pl.pca` | `bdl_pl_pca` |
| Existing UMAP split into comparable panels | `bdl.pl.umap_split` | `bdl_pl_umap_split` |
| Prepared QC distributions | `bdl.pl.violin_qc` | `bdl_pl_violin_qc` |
| Individual observations across groups | `bdl.pl.group_comparison` | `bdl_pl_group_comparison` |
| Prepared expression or summary matrix | `bdl.pl.heatmap` | `bdl_pl_heatmap` |
| Existing differential-expression results | `bdl.pl.volcano` | `bdl_pl_volcano` |
| Existing abundance and log2 fold change | `bdl.pl.ma` | `bdl_pl_ma` |
| Multiple panels | `bdl.pl.compose` | `bdl_pl_compose` |

See the [Python guide](PLOTTING_PYTHON.md) and [R guide](PLOTTING_R.md) for
installation, exact arguments and executable examples.

## What the functions do

You supply the values, observation unit, group definitions, expression scale and
comparison. The renderer supplies consistent drawing behavior and rejects inputs
it cannot represent as specified. It does not normalize counts, fit PCA, compute
UMAP, fit differential-expression models, choose genes or perform statistical
tests. Heatmaps preserve the supplied matrix and ordering; any scaling or
clustering belongs in an explicit upstream step.

For bulk RNA-seq, prepare sample coordinates from your chosen analysis method,
transformed expression/QC values and retained differential-expression results.
Supply the selected genes and sample order for a heatmap. A plot does not make
raw counts comparable or establish that a differential-expression model is valid.
Scanpy and Seurat are not required. Their existing coordinates or prepared values
can be supplied using the same table interfaces; native-object adapters are not
part of this first release.

## Edit and combine

R returns ggplot objects. Add a theme, labels or layers using normal ggplot syntax,
then combine them with `bdl_pl_compose`, which uses optional patchwork.

Python returns Matplotlib axes for single panels and figures for split panels or
composition. Single-panel functions accept an existing axis. `bdl.pl.compose`
allocates a shared grid and calls your panel functions on those axes. It does not
copy arbitrary figures or convert them to screenshots. Keep the prepared data
available to redraw panels; drawing them again does not require rerunning their
analysis.

The default native appearance is a starting point for review, not a manuscript
certification. You may explicitly apply CellStyle to the returned objects when
that optional package is available. BioDataLedger does not copy CellStyle or
silently change its appearance depending on whether CellStyle is installed.

## Preserve improvements and provenance

Keep your rendering script, exact package build/version, prepared plot table and
parameters with the saved output. Existing `register_analysis`, `register_figure`
and `save` calls can record these relationships. No new registry format is needed.
Native `savefig` or `ggsave` remains available for ordinary exports.

These functions do not enforce their use by other code, authenticate the input
data or mark a figure scientifically accepted. Editing the returned native object
can change its meaning: retain the final customization code as well as the original
renderer call. A declared renderer version is not independently verified execution.

Report a recurring figure problem with its small input example, call and expected
behavior. A correction should become a focused regression case and a new reviewed
code revision. Pin the tested package commit while these additions are unreleased;
do not silently update an active project. Keep the old code and dependencies when
you need to reproduce an earlier figure.

The included examples are synthetic. Human readability and scientific suitability
remain review tasks; automated checks cover only their stated properties.
