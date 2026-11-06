args <- commandArgs(trailingOnly = TRUE)
library(BioDataLedger, lib.loc = args[[1]])
action <- args[[2]]; root <- args[[3]]
fixture <- jsonlite::fromJSON(args[[4]])
apply_design <- function(p, x = fixture, ...) do.call(p$set_design, c(x, list(...)))
json <- function(x) cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
if (action == "create") {
  p <- ProjectBundle$create("PRMT5 (synthetic)", root,
    purpose = "Treatment-associated changes in T-cell populations")
  apply_design(p)
  a <- p$register_analysis("Declared synthetic comparison", inputs = NULL)
  writeLines("synthetic", file.path(root, "figure.svg"))
  p$register_figure("figure.svg", "qc", analysis = a)
  p$save()
  json(p$get_design())
} else if (action == "invalid") {
  cat(tryCatch({ProjectBundle$open(root); "ACCEPTED"}, error = function(e) "REJECTED"))
} else if (action == "invalid_set") {
  p <- ProjectBundle$open(root)
  before <- p$get_design()
  invalid <- jsonlite::fromJSON(args[[5]])
  result <- tryCatch({apply_design(p, invalid); "ACCEPTED"}, error = function(e) "REJECTED")
  stopifnot(identical(before, p$get_design()), !p$summary()$unsaved)
  cat(result)
} else if (action %in% c("overview", "overview_revision")) {
  p <- ProjectBundle$open(root)
  if (action == "overview_revision") {
    p$set_presentation(args[[5]], "QC", "t-cell-distribution", "2019-12-31",
                       title = "T-cell distribution", reason = "fixture metadata edit")
    p$save()
  }
  json(list(overview = as.list(capture.output(print(p))),
            report = p$recent_figures(structured = TRUE)))
} else {
  p <- if (action == "import") ProjectBundle$import_zip(args[[5]], root) else ProjectBundle$open(root)
  if (action == "change") {
    fixture$selected_levels <- fixture$levels
    apply_design(p); p$save()
  } else if (action == "metadata") {
    columns <- jsonlite::fromJSON(args[[5]], simplifyVector = FALSE)
    ref <- apply_design(p, metadata = columns, context = list("DATA-001@1"))
    p$save()
  } else if (action == "check_metadata") {
    json(p$check_design_metadata(jsonlite::fromJSON(args[[5]], simplifyVector = FALSE)))
    quit(status = 0)
  } else if (action == "stale") {
    apply_design(p)
    writeLines("ready", args[[5]])
    deadline <- Sys.time() + 10
    while (!file.exists(args[[6]]) && Sys.time() < deadline) Sys.sleep(0.02)
    cat(tryCatch({p$save(); "ACCEPTED"}, error = function(e) "REJECTED"))
    quit(status = 0)
  } else if (action == "export") {
    p$export_zip(p$preview_export("context"), args[[5]])
  }
  json(list(design = p$get_design(), compact = p$get_design_summary(),
    analysis_design = p$get_analysis("ANA-001@1")$design,
    figure_design = p$get_figure("FIG-001@1")$design,
    text = p$summary_text(), counts = p$summary()$counts))
}
