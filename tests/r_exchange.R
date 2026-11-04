args <- commandArgs(trailingOnly = TRUE)
library(BioDataLedger, lib.loc = args[[1]])
stopifnot(as.character(packageVersion("BioDataLedger")) == "0.9.0")
action <- args[[2]]
root <- args[[3]]
if (action == "create") {
  writeLines("sample,value\nS1,1\nS2,2", file.path(root, "input.csv"))
  writeLines("# Synthetic declared source\ncutoff <- 200", file.path(root, "qc.R"))
  writeLines('<svg xmlns="http://www.w3.org/2000/svg"><text x="1" y="12">Synthetic QC</text></svg>', file.path(root, "qc.svg"))
  p <- ProjectBundle$create("R synthetic", root)
  d <- p$register_data("input.csv", "analysis_ready", hash = TRUE)
  p$set_current(d, "qc", "synthetic choice")
  a <- p$register_analysis("R QC", list(d), code = "qc.R", method = "declared R summary", params = list(cutoff = 200, labels = list("one"), empty = list()))
  p$register_figure("qc.svg", "qc", analysis = a)
  p$save()
  p$export_zip(p$preview_export("working", include = list(d, "FIG-001@1")), args[[4]])
} else if (action == "update") {
  p <- ProjectBundle$open(root)
  stopifnot(p$get_figure("FIG-001@1", check_files = TRUE)$available)
  p$set_context(list(next_task = "updated by R"))
  p$save()
} else if (action == "inspect") {
  p <- ProjectBundle$open(root)
  f <- p$get_figure("FIG-001@1", check_files = TRUE)
  cat(jsonlite::toJSON(list(figure = f$ref, params = f$params, method = f$method, next_task = p$summary()$next_task, code = f$code_availability), auto_unbox = TRUE, null = "null"))
} else if (action == "import") {
  q <- ProjectBundle$import_zip(args[[4]], root)
  f <- q$get_figure("FIG-001@1", check_files = TRUE)
  stopifnot(isTRUE(f$available), isTRUE(f$code_availability[[1]]$available), isTRUE(q$get_data(purpose = "qc", check_files = TRUE)$available), identical(f$provenance$figure_file, "captured"), identical(f$provenance$execution, "unknown"))
  q$set_context(list(next_task = "imported and updated by R"))
  q$save()
} else if (action == "stale") {
  p <- ProjectBundle$open(root)
  p$set_context(list(next_task = "R pending"))
  writeLines("ready", args[[4]])
  deadline <- Sys.time() + 10
  while (!file.exists(args[[5]]) && Sys.time() < deadline) Sys.sleep(0.02)
  result <- tryCatch({p$save(); "WRONG-SUCCESS"}, error = function(e) paste("REJECTED", conditionMessage(e)))
  cat(result)
} else if (action == "status") {
  p <- ProjectBundle$open(root)
  cat(jsonlite::toJSON(p$status(check_files = TRUE), auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
} else if (action == "legacy") {
  p <- ProjectBundle$import_zip(args[[4]], root)
  f <- p$get_figure("FIG-001@1", check_files = TRUE)
  stopifnot(f$params$min_genes == 200, identical(isTRUE(f$available), args[[5]] == "working"))
} else if (action == "mutations") {
  p <- ProjectBundle$open(root)
  p$set_context(list(purpose = NULL, raw_dir = "missing-raw"))
  revised <- p$update_record("FIG-001@1", list(path = "genes.svg"), "synthetic render revision")
  external <- p$register_data(args[[4]], "external", hash = TRUE)
  p$rebind_external(external, args[[4]], "explicit external location")
  p$save()
  q <- ProjectBundle$open(root)
  stopifnot(is.null(q$summary()$project$purpose), q$get_figure(revised, check_files = TRUE)$revision == 2)
  cat("MUTATIONS-OK")
} else if (action == "large") {
  p <- ProjectBundle$open(root)
  old_hash <- get(".hash", asNamespace("BioDataLedger"))
  blocked_hash <- function(path) {
    if (basename(path) == "large.h5ad") stop("unexpected payload hash/read")
    old_hash(path)
  }
  assignInNamespace(".hash", blocked_hash, ns = "BioDataLedger")
  d <- p$register_data("large.h5ad", "opaque")
  stopifnot(isTRUE(p$get_data(ref = d, check_files = TRUE)$available), is.null(p$get_data(ref = d, check_files = TRUE)$sha256))
  stopifnot(p$status(check_files = TRUE)$missing$checked >= 1)
  cat("NO-PAYLOAD-HASH")
} else if (action == "archive-invalid") {
  result <- tryCatch({ProjectBundle$import_zip(args[[4]], root); "WRONG-SUCCESS"}, error = function(e) "REJECTED")
  cat(result)
} else if (action == "invalid") {
  result <- tryCatch({ProjectBundle$open(root); "WRONG-SUCCESS"}, error = function(e) "REJECTED")
  cat(result)
} else stop("unknown test action")
