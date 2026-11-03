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
  p$save()
  p <- ProjectBundle$open(project_dir = project_dir)
  data <- p$resolve_data(purpose = "qc", verify = "sha256")
  # Retain saved files; these declarations do not prove that the script executed.
  analysis <- p$register_analysis("Synthetic QC", inputs = list(data$ref), code = "qc.R",
                                  method = "synthetic display", params = list(min_genes = 200))
  first <- p$register_figure("library.svg", type = "qc", analysis = analysis)
  p$register_figure("genes.svg", type = "qc", analysis = analysis)
  p$save()
  print(first)
  message("Four retention calls; shared context entered once. No rerun verified.")
}

args <- commandArgs(trailingOnly = TRUE)
main(args[[1]], args[[2]])
