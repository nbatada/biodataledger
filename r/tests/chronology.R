library(BioDataLedger)
local({
  root <- tempfile("chronology-"); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("synthetic", file.path(root, "input.txt"))
  writeLines(c("run <- function(inputs, params, seeds, outputs) {",
               "  if (isTRUE(params$fail)) stop('synthetic failure')",
               "  if (!isTRUE(params$skip)) for (path in outputs) writeLines('synthetic', path)", "}"), file.path(root, "code.R"))
  p <- ProjectBundle$create("synthetic chronology", root)
  data <- p$register_data("input.txt", "input", hash = TRUE)
  template <- function(params = list(n = 1)) p$register_analysis("template", list(data), code = "code.R", method = "synthetic", params = params)
  a <- template(); b <- template(list(n = 2))
  protocol <- p$register_protocol("intent", list(list(step_id = "b", analysis_ref = b, required_outputs = list()), list(step_id = "a", analysis_ref = a, required_outputs = list())), "synthetic")
  counter <- 0L
  run <- function(ref = a) {
    counter <<- counter + 1L
    tryCatch(p$run_analysis(ref, "run", list(list(path = paste0("out", counter, ".txt"), kind = "result"))), error = function(e) { if (is.null(e$receipt)) stop(e); e$receipt })
  }
  first <- run(); second <- run(b)
  report <- p$execution_history(protocol_ref = protocol)
  stopifnot(length(report$entries) == 2L, length(report$relations) == 1L,
            identical(report$entries[[1]]$receipt_ref, second$receipt_ref),
            identical(report$selector$steps[[1]]$step_id, "b"),
            identical(report$selector$order_evidence, "declared_intent_not_approval"),
            identical(p$execution_history(analysis_ref = first$run_ref)$entries[[1]]$receipt_ref, first$receipt_ref))
  page <- p$execution_history(limit = 1)
  stopifnot(!is.null(page$scan$next_offset), identical(page$entries[[1]]$receipt_ref, second$receipt_ref))
  following <- p$execution_history(limit = 1, offset = page$scan$next_offset)
  stopifnot(identical(following$entries[[1]]$receipt_ref, first$receipt_ref))
  tail_page <- p$execution_history(offset = following$scan$next_offset)
  stopifnot(length(tail_page$entries) == 0L)
  failed <- run(template(list(fail = TRUE)))
  incomplete <- run(template(list(skip = TRUE)))
  writeLines("changed", file.path(root, "input.txt")); blocked <- run()
  history <- p$execution_history()
  stopifnot(identical(history$entries[[1]]$outcome, "blocked"),
            identical(history$entries[[1]]$timing_status, "not_executed"),
            identical(history$entries[[2]]$outcome, "incomplete"),
            identical(history$entries[[3]]$outcome, "failed"),
            identical(history$relations[[1]]$relation, "unknown"))
  unknown <- template(list(n = 99))
  stopifnot(length(p$execution_history(analysis_ref = unknown)$entries) == 0L)
  invisible(p$save_and_confirm())
  path <- file.path(root, ".nb_project_bundle", "project.json")
  before <- readBin(path, "raw", file.info(path)$size)
  text <- p$execution_history_summary()
  stopifnot(nchar(text, type = "bytes") <= 4096L, grepl("start=", text, fixed = TRUE), grepl("not a total execution", text, fixed = TRUE),
            identical(before, readBin(path, "raw", file.info(path)$size)))
  archive <- file.path(root, "context.zip")
  invisible(p$export_zip(p$preview_export("context"), archive))
  imported <- ProjectBundle$import_zip(archive, file.path(root, "imported"))
  stopifnot(all(vapply(imported$execution_history()$relations, function(x) identical(x$relation, "unknown"), logical(1))))
})
