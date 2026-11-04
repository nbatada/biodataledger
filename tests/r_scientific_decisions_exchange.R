library(BioDataLedger)
args <- commandArgs(TRUE)
mode <- if (length(args) >= 3L) args[[3]] else "exchange"
if (mode == "import") {
  p <- ProjectBundle$import_zip(args[[4]], args[[1]])
  view <- p$get_decision(args[[2]])
  stopifnot(identical(view$imported_claim, "untrusted_imported_claim"))
  cat(jsonlite::toJSON(view, auto_unbox=TRUE, null="null"))
} else {
  p <- ProjectBundle$open(args[[1]])
  python_status <- p$get_decision(args[[2]])$scientific$scientific_status
  d <- p$get_data(role="input")$ref
  a <- p$register_analysis("R clustering", list(d))
  blank <- tryCatch(p$record_scientific_decision("Blank", "   ", list(list(ref=a)), "proposed"), error=identity)
  stopifnot(inherits(blank,"error"))
  ref <- p$record_scientific_decision("R label", "R rationale", list(list(ref=a, cluster_id="01", annotation="R annotation")), "approved", list(d), list(d))
  invisible(p$save_and_confirm())
  ns <- asNamespace("BioDataLedger")
  invisible(trace(".hash", where=ns, tracer=quote(stop("unexpected receipt query hash")), print=FALSE))
  view <- p$get_decision(ref)
  stopifnot(identical(view$approval,"not_authenticated"), identical(p$save_and_confirm()$status,"no_changes"))
  invisible(untrace(".hash", where=ns))
  archive <- file.path(args[[1]],"native-context.zip")
  p$export_zip(p$preview_export("context"), archive)
  cat(jsonlite::toJSON(list(ref=ref, python_status=python_status, view=view, archive=archive),auto_unbox=TRUE,null="null"))
}
