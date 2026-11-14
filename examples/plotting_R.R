# Installed-package synthetic gallery. Creates a new output directory only.
# Run: Rscript examples/plotting_R.R /path/to/new-gallery
library(BioDataLedger)
main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 1L) stop("Supply one new output directory.")
  output <- args[[1L]]
  if (file.exists(output)) stop("Output directory already exists; choose a new path.")
  if (!requireNamespace("ggplot2", quietly = TRUE) || !requireNamespace("patchwork", quietly = TRUE))
    stop("Install optional ggplot2 and patchwork to run this example.")
  d <- data.frame(sample = paste0("s", 1:6), PC1 = c(-3, -2, -1, 1, 2, 3),
    PC2 = c(1, -2, 0, 2, -1, 3), condition = rep(c("control", "treated"), each = 3),
    expression = c(1, 2, 4, 8, 12, 16))
  de <- data.frame(gene = paste0("gene", 1:6), log2FC = c(-2, -1, 0, 0.5, 1.5, 3),
    padj = c(0.01, 0.05, 1, 0.5, 0.02, 0), mean_log2_CPM = c(2, 4, 6, 8, 10, 12))
  m <- matrix(c(-1, 0, 1, 2, 3, 4), 2,
              dimnames = list(c("gene1", "gene2"), c("sample1", "sample2", "sample3")))
  plots <- list(
    bdl_pl_pca(d, "PC1", "PC2", color = "condition", sample_id = "sample",
      variance_percent = c(48, 22), title = "Prepared PCA") + ggplot2::theme(legend.position = "bottom"),
    bdl_pl_umap_split(d, "PC1", "PC2", "condition", color = "expression",
      color_kind = "continuous", xlabel = "Supplied UMAP1", ylabel = "Supplied UMAP2", title = "Synthetic coordinates"),
    bdl_pl_violin_qc(d, "condition", "expression", "Prepared expression (CPM)", title = "QC distribution"),
    bdl_pl_group_comparison(d, "condition", "expression", "sample", "biological sample",
      "Prepared expression (CPM)", title = "Individual observations"),
    bdl_pl_heatmap(m, "Prepared expression (log2 CPM)", title = "Prepared matrix"),
    bdl_pl_volcano(de, "log2FC", "padj", "treated / control", 1, 0.05,
      zero_p_floor = 0.001, feature = "gene", title = "Existing DE estimates"),
    bdl_pl_ma(de, "mean_log2_CPM", "log2FC", "treated / control", "log2",
      feature = "gene", abundance_label = "Mean expression (CPM)", title = "Prepared MA values"))
  names(plots) <- c("pca", "umap_split", "violin_qc", "group_comparison", "heatmap", "volcano", "ma")
  dir.create(output, recursive = TRUE)
  for (name in names(plots)) ggplot2::ggsave(file.path(output, paste0(name, ".pdf")),
    plots[[name]], width = 7, height = 5, units = "in")
  gallery <- bdl_pl_compose(plots, ncol = 2, labels = letters[seq_along(plots)])
  ggplot2::ggsave(file.path(output, "gallery.pdf"), gallery, width = 14, height = 20, units = "in", limitsize = FALSE)
  ggplot2::ggsave(file.path(output, "gallery.png"), gallery, width = 14, height = 20, units = "in", dpi = 120, limitsize = FALSE)
  cat("Saved synthetic native R gallery in", normalizePath(output), "\n")
}
main()
