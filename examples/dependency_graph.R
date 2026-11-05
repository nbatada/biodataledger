# Synthetic PRMT5 lineage only: no expression data or analysis execution.
library(BioDataLedger)

main <- function() {
  root <- tempfile("synthetic-graph-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("synthetic placeholder", file.path(root, "original-gex.txt"))
  writeLines("synthetic placeholder", file.path(root, "analysis-ready-gex.txt"))
  writeLines(c("sample_id,cell_id,x,y", "S1,C1,0,1"), file.path(root, "umap.csv"))
  writeLines('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>', file.path(root, "figure.svg"))
  project <- ProjectBundle$create("Synthetic PRMT5 lineage", root)
  original <- project$register_data("original-gex.txt", "raw", name = "Original GEX")
  qc <- project$register_analysis("QC", inputs = list(original))
  ready <- project$register_result("analysis-ready-gex.txt", qc)
  cd8 <- project$register_analysis("CD8 analysis", inputs = list(ready))
  umap <- project$register_result("umap.csv", cd8,
    embedding = list(format = "csv", coordinate_columns = list("x", "y")))
  fig <- project$register_figure("figure.svg", "umap", analysis = cd8, name = "Saved UMAP figure",
    figure_sources = list(rendering_inputs = list(umap), relationship = "declared"))
  project$save()
  cat(project$export_graph(fig, depth = 6L))
}

main()
