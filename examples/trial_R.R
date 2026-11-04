# Register existing tiny synthetic files; never analyze real data in this trial.
library(BioDataLedger)

main <- function(project_dir, input_dir) {
  if (file.exists(project_dir) || !dir.create(project_dir)) stop("Use a new trial directory")
  for (name in c("input.csv", "library.svg", "genes.svg", "qc.R")) {
    if (!file.copy(file.path(input_dir, name), file.path(project_dir, name))) stop("Cannot copy fixture")
  }
  p <- ProjectBundle$create("Synthetic trial", project_dir = project_dir)
  data <- p$register_data("input.csv", role = "analysis_ready", hash = TRUE)
  p$set_current(data, purpose = "qc", reason = "Synthetic trial input; no scientific approval")
  receipt <- p$save_and_confirm()
  p <- ProjectBundle$open(project_dir = project_dir)
  data <- p$resolve_data(purpose = "qc", verify = "sha256")
  # Retain saved files; these declarations do not prove that the script executed.
  analysis <- p$register_analysis("Synthetic QC", inputs = list(data$ref), code = "qc.R",
                                  method = "synthetic display", params = list(min_genes = 200))
  first <- p$register_figure("library.svg", type = "qc", analysis = analysis)
  second <- p$register_figure("genes.svg", type = "qc", analysis = analysis)
  receipt <- p$save_and_confirm()
  p <- ProjectBundle$open(project_dir = project_dir)
  print(p$status())
  cat("Exact references:", jsonlite::toJSON(list(input = data$ref, analysis = analysis,
      figures = list(first, second)), auto_unbox = TRUE), "\n")
  print(p$get_figure(first, compact = TRUE))
  # Only synthetic fixtures are exported here; review real metadata/history before sharing.
  for (mode in c("context", "working")) {
    selected <- if (mode == "working") list(data$ref, first, second) else NULL
    plan <- p$preview_export(mode, include = selected)
    archive <- file.path(project_dir, paste0("trial-", mode, ".zip"))
    p$export_zip(plan, path = archive)
    cat(mode, "ZIP:", archive, "payload files:", length(plan$files), "\n")
  }
  print(receipt)
  print(first)
  message("Four retention calls; shared context entered once. Execution evidence remains unknown; no rerun verified.")
}

args <- commandArgs(trailingOnly = TRUE)
main(args[[1]], args[[2]])
