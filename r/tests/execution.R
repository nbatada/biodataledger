library(BioDataLedger)

main <- function() {
  root <- tempfile("execution-"); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("input", file.path(root, "input.txt"))
  code <- file.path(root, "analysis.R")
  writeLines(c(
    "run_it <- function(inputs, params, seeds, outputs) {",
    "  state <- jsonlite::fromJSON(params$registry, simplifyVector=FALSE)",
    "  receipts <- Filter(function(x) identical(x$kind, 'analysis') && !is.null(x$details$execution_receipt), state$records)",
    "  stopifnot(length(receipts) == 1L, identical(receipts[[1]]$details$execution_receipt$status, 'started'))",
    "  writeLines('result', outputs[[1]])",
    "  writeLines('figure', outputs[[2]])",
    "}", "ignore_it <- function(inputs, params, seeds, outputs) { rnorm(1); NULL }"), code)
  p <- ProjectBundle$create("Execution", root)
  input <- p$register_data("input.txt", "input", hash = TRUE)
  analysis <- p$register_analysis("Synthetic", list(input), code = "analysis.R",
                                  method = "synthetic", params = list(registry = file.path(root, ".nb_project_bundle", "project.json")))
  result_path <- file.path(root, "result.txt")
  figure_path <- file.path(root, "figure.txt")
  receipt <- p$run_analysis(analysis, "run_it", outputs = list(
    list(path = "result.txt", kind = "result"), list(path = figure_path, kind = "figure", type = "text")),
    seeds = list(seed = 4L))
  stopifnot(identical(receipt$status, "succeeded"), receipt$run_ref$revision == 1L,
            receipt$receipt_ref$revision == 2L, receipt$phases$code_executed,
            receipt$phases$callback_invoked, identical(receipt$inputs[[1]]$identity, "match"),
            all(vapply(receipt$outputs, function(x) identical(x$status, "registered"), logical(1))),
            identical(p$get_execution(receipt$receipt_ref)$status, "succeeded"),
            !is.null(receipt$persistence), nchar(p$execution_summary(receipt$receipt_ref), type = "bytes") <= 4096L)
  injected <- tryCatch(p$register_analysis("Injected", list(input), execution_receipt = list()), error = identity)
  stopifnot(inherits(injected, "error"))
  rewritten <- tryCatch(p$update_record(receipt$receipt_ref, list(params = list(changed = TRUE)), "rewrite execution"), error = identity)
  stopifnot(inherits(rewritten, "error"))
  started <- p$get_execution(receipt$run_ref)
  stopifnot(identical(started$status, "started"), !started$phases$execution_started,
            identical(p$get_data(ref=receipt$outputs[[1]]$record_ref)$scope$transformation_ref, receipt$run_ref))
  before <- p$get_analysis(analysis)
  writeLines("changed", file.path(root, "input.txt"))
  blocked <- tryCatch(p$run_analysis(analysis, "run_it"), BioDataLedgerExecutionError = identity)
  stopifnot(inherits(blocked, "BioDataLedgerExecutionError"), identical(blocked$receipt$status, "blocked"),
            !blocked$receipt$phases$execution_started, identical(p$get_analysis(analysis)$ref, before$ref))
  reopened <- ProjectBundle$open(root)
  stopifnot(identical(reopened$get_execution(blocked$receipt$receipt_ref)$status, "blocked"),
            identical(reopened$get_execution(receipt$receipt_ref)$status, "succeeded"))

  writeLines("unhashed", file.path(root, "unhashed.txt"))
  unhashed <- reopened$register_data("unhashed.txt", "optional")
  optional <- reopened$register_analysis("Optional verification", list(unhashed), code = "analysis.R")
  required <- tryCatch(reopened$run_analysis(optional, "ignore_it"), BioDataLedgerExecutionError = identity)
  optional_receipt <- reopened$run_analysis(optional, "ignore_it", verify_inputs = FALSE)
  stopifnot(inherits(required, "BioDataLedgerExecutionError"), identical(required$receipt$status, "blocked"),
            identical(optional_receipt$status, "succeeded"), identical(optional_receipt$inputs[[1]]$identity, "unknown"))

  writeLines("input", file.path(root, "input.txt"))
  failing <- file.path(root, "failing.R")
  writeLines(c("fail_it <- function(inputs, params, seeds, outputs) {", "writeLines('partial', outputs[[1]])", "stop('synthetic failure')", "}"), failing)
  failed_analysis <- reopened$register_analysis("Failure", list(input), code = "failing.R")
  failure <- tryCatch(reopened$run_analysis(failed_analysis, "fail_it", outputs = list(list(path = file.path(root, "partial.txt"), kind = "result"))),
                      BioDataLedgerExecutionError = identity)
  stopifnot(inherits(failure, "BioDataLedgerExecutionError"), identical(failure$receipt$status, "failed"),
            identical(failure$receipt$outputs[[1]]$status, "registered"), failure$receipt$phases$callback_invoked)

  invalid <- file.path(root, "invalid.R")
  writeLines("not valid <-", invalid)
  invalid_analysis <- reopened$register_analysis("Invalid source", list(input), code = "invalid.R")
  syntax_failure <- tryCatch(reopened$run_analysis(invalid_analysis, "run"), BioDataLedgerExecutionError = identity)
  stopifnot(inherits(syntax_failure, "BioDataLedgerExecutionError"), identical(syntax_failure$receipt$status, "failed"),
            !syntax_failure$receipt$phases$code_executed, !syntax_failure$receipt$phases$callback_invoked,
            identical(reopened$get_execution(syntax_failure$receipt$receipt_ref)$status, "failed"))

  top_output <- file.path(root, "top-level.txt")
  top <- file.path(root, "top.R")
  writeLines(c(sprintf("writeLines('partial', %s)", shQuote(top_output)), "stop('top-level failure')"), top)
  top_analysis <- reopened$register_analysis("Top level failure", list(input), code = "top.R")
  top_failure <- tryCatch(reopened$run_analysis(top_analysis, "run", outputs = list(list(path = "top-level.txt", kind = "result"))), BioDataLedgerExecutionError = identity)
  stopifnot(inherits(top_failure, "BioDataLedgerExecutionError"), top_failure$receipt$phases$code_executed,
            !top_failure$receipt$phases$callback_invoked, identical(top_failure$receipt$outputs[[1]]$status, "registered"))

  namespace <- asNamespace("BioDataLedger")
  trace(".hash", where = namespace, tracer = quote(stop("receipt query performed I/O")), print = FALSE)
  traced <- TRUE
  on.exit(if (traced) untrace(".hash", where = namespace), add = TRUE)
  stopifnot(identical(reopened$get_execution(receipt$receipt_ref)$status, "succeeded"))
  untrace(".hash", where = namespace)
  traced <- FALSE

  writeLines("stop('replacement code must not execute')", file.path(root, "analysis.R"))
  changed_code <- tryCatch(reopened$run_analysis(optional, "ignore_it", verify_inputs = FALSE),
                           BioDataLedgerExecutionError = identity)
  stopifnot(inherits(changed_code, "BioDataLedgerExecutionError"), changed_code$receipt$status == "blocked",
            !any(unlist(changed_code$receipt$phases)))
  missing <- tryCatch(reopened$run_analysis(optional, "ignore_it", verify_inputs = FALSE, verify_code = FALSE,
                      outputs = list(list(path = "missing.txt", kind = "result"))), BioDataLedgerExecutionError = identity)
  stopifnot(inherits(missing, "BioDataLedgerExecutionError"), missing$receipt$status == "incomplete",
            missing$receipt$outputs[[1]]$status == "missing", missing$receipt$input_consumption == "unknown",
            reopened$get_execution(missing$receipt$receipt_ref)$status == "incomplete")

  # Malformed legacy/imported claims cannot acquire positive evidence in views.
  registry_path <- file.path(root, ".nb_project_bundle", "project.json")
  original <- jsonlite::fromJSON(registry_path, simplifyVector = FALSE)
  index <- which(vapply(original$records, function(x) identical(x$id, receipt$receipt_ref$id) && x$revision == receipt$receipt_ref$revision, logical(1)))
  start_index <- which(vapply(original$records, function(x) identical(x$id, receipt$run_ref$id) && x$revision == 1L, logical(1)))
  input_index <- which(vapply(original$records, function(x) identical(x$id, input$id) && x$revision == input$revision, logical(1)))
  mutations <- list(
    function(x) {x$records[[input_index]]["sha256"] <- list(NULL); x},
    function(x) {x$records[[start_index]]$input_mode <- "combined"; x},
    function(x) {x$records[[index]]$details$execution_receipt$seeds <- "not an object"; x},
    function(x) {x$records[[index]]$details$execution_receipt$code$path <- ""; x},
    function(x) {x$records[[index]]$details$execution_receipt$outputs[[1]]$status <- "missing"; x}
  )
  for (mutate in mutations) {
    forged <- mutate(original)
    jsonlite::write_json(forged, registry_path, auto_unbox = TRUE, null = "null", digits = 15)
    stopifnot(identical(ProjectBundle$open(root)$get_execution(receipt$receipt_ref)$status, "unknown"))
  }
}
main()
