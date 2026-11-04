args <- commandArgs(TRUE)
library(BioDataLedger)
request <- jsonlite::fromJSON(args[[2]], simplifyVector = FALSE)
p <- ProjectBundle$open(args[[1]])
report <- p$compare_protocol(request$protocol, request$executions)
view <- p$get_protocol(request$protocol)
answer <- list(report = report, protocol = view)
if (identical(request$mode, "revise")) {
  revised <- p$register_protocol("native revision", view$protocol$steps, "synthetic native revision", request$protocol)
  # Exercise native invocation and result comparison, not just a Python fixture.
  writeLines("run <- function(inputs, params, seeds, outputs) writeLines('native synthetic', outputs[[1]])", file.path(args[[1]], "native.R"))
  input <- p$get_analysis(view$protocol$steps[[1]]$analysis_ref)$inputs[[1]]
  template <- p$register_analysis("native template", list(input), code = "native.R", method = "synthetic native", params = list(n = 1, dynamic = "rule"))
  native_protocol <- p$register_protocol("native intent", list(list(step_id = "native", analysis_ref = template, required_outputs = list(list(kind = "result")), data_dependent_params = list("dynamic"))), "synthetic")
  actual <- p$register_analysis("native observed", list(input), code = "native.R", method = "synthetic native", params = list(n = 1L, dynamic = NULL))
  receipt <- p$run_analysis(actual, "run", list(list(path = "native-output.txt", kind = "result")))
  selected <- list(list(step_id = "native", analysis_ref = receipt$receipt_ref))
  native_report <- p$compare_protocol(native_protocol, selected)
  stopifnot(length(native_report$steps[[1]]$mismatches) == 0L, "dynamic" %in% names(native_report$steps[[1]]$data_dependent_observations))
  invisible(p$save_and_confirm())
  archive <- file.path(args[[1]], "native-context.zip")
  invisible(p$export_zip(p$preview_export("context"), archive))
  answer$new_ref <- revised
  answer$new_view <- p$get_protocol(revised)
  answer$archive <- archive
  answer$native_protocol <- native_protocol
  answer$native_selection <- selected
  answer$native_report <- native_report
}
cat(jsonlite::toJSON(answer, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
