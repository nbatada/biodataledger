library(BioDataLedger)
local({
  root <- tempfile("protocol-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("synthetic", file.path(root, "input.txt"))
  writeLines(c("run <- function(inputs, params, seeds, outputs) {",
               "  if (isTRUE(params$fail)) stop('synthetic failure')",
               "  if (!isTRUE(params$skip)) for (path in outputs) writeLines('synthetic', path)",
               "}"), file.path(root, "code.R"))
  p <- ProjectBundle$create("synthetic protocols", root)
  data <- p$register_data("input.txt", "input", hash = TRUE)
  params <- list(resolution = 0.5, dynamic = "selection rule", nullable = NULL)
  analysis <- function(values = params, input = data) p$register_analysis("template", list(input), code = "code.R", method = "synthetic", params = values)
  template <- analysis()
  step <- list(step_id = "one", analysis_ref = template, required_outputs = list(list(kind = "result")), data_dependent_params = list("dynamic"))
  protocol <- p$register_protocol("ordered", list(step), "synthetic intent")
  original <- p$get_protocol(protocol)
  revised <- p$register_protocol("revision two", list(step), "revision", protocol)
  stopifnot(identical(p$get_protocol(protocol), original), revised$revision == 2L)
  fails <- function(expr) inherits(tryCatch(force(expr), error = identity), "error")
  stopifnot(fails(p$update_record(revised, list(name = "bad"), "bad")),
            fails(p$update_record(revised, list(status = "inactive"), "bad")),
            fails(p$register_protocol("stale", list(step), "bad", protocol)))
  approval <- p$record_scientific_decision("approved", "submitted", list(list(ref = protocol)), "approved")
  stopifnot(identical(p$compare_protocol(protocol, list(), approval)$approval$status, "match"),
            identical(p$compare_protocol(revised, list(), approval)$approval$status, "mismatch"),
            fails(p$register_protocol("bad", list(step), "bad", approval)),
            fails(p$record_scientific_decision("bad", "why", list(list(ref = data)), "approved", ref = protocol)))
  counter <- 0L
  run <- function(ref = template, verify = TRUE) {
    counter <<- counter + 1L
    tryCatch(p$run_analysis(ref, "run", list(list(path = paste0("output", counter, ".txt"), kind = "result")), verify_inputs = verify),
             error = function(e) { if (is.null(e$receipt)) stop(e); e$receipt })
  }
  compare <- function(receipt) p$compare_protocol(protocol, list(list(step_id = "one", analysis_ref = receipt$receipt_ref)))$steps[[1]]
  base <- run()
  stopifnot(length(compare(base)$mismatches) == 0L)
  changed <- run(analysis(list(resolution = 0.8, dynamic = 12, nullable = NULL)))
  stopifnot("params.resolution" %in% unlist(compare(changed)$mismatches))
  dynamic <- compare(run(analysis(list(resolution = 0.5, dynamic = NULL, nullable = NULL))))
  stopifnot(length(dynamic$mismatches) == 0L, "dynamic" %in% names(dynamic$data_dependent_observations))
  missing <- compare(run(analysis(list(resolution = 0.5))))
  stopifnot("data_dependent_param.dynamic" %in% unlist(missing$unknown), "params.nullable" %in% unlist(missing$mismatches))
  other <- p$register_data("input.txt", "other identity", hash = TRUE)
  stopifnot("inputs" %in% unlist(compare(run(analysis(input = other)))$mismatches))
  failed <- run(analysis(c(params, list(fail = TRUE))))
  stopifnot(identical(failed$status, "failed"), "execution_status.failed" %in% unlist(compare(failed)$mismatches))
  incomplete <- run(analysis(c(params, list(skip = TRUE))))
  stopifnot(identical(incomplete$status, "incomplete"), "required_outputs" %in% unlist(compare(incomplete)$mismatches))
  stopifnot("input_identity" %in% unlist(compare(run(verify = FALSE))$unknown))
  second <- step; second$step_id <- "two"
  ordered <- p$register_protocol("two steps", list(step, second), "synthetic")
  selected <- list(list(step_id = "two", analysis_ref = base$receipt_ref), list(step_id = "one", analysis_ref = changed$receipt_ref))
  stopifnot(identical(p$compare_protocol(ordered, selected)$order, "mismatch"),
            "missing_step" %in% unlist(p$compare_protocol(ordered, selected[1])$steps[[1]]$mismatches),
            "execution_receipt" %in% unlist(p$compare_protocol(protocol, list(list(step_id = "one", analysis_ref = template)))$steps[[1]]$unknown))
  invisible(p$save_and_confirm())
  state_path <- file.path(root, ".nb_project_bundle", "project.json")
  before <- readBin(state_path, "raw", file.info(state_path)$size)
  p$get_protocol(protocol); compare(base)
  stopifnot(identical(before, readBin(state_path, "raw", file.info(state_path)$size)),
            identical(ProjectBundle$open(root)$get_protocol(protocol), original))
})
