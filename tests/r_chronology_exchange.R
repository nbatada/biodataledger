args <- commandArgs(TRUE)
library(BioDataLedger)
request <- jsonlite::fromJSON(args[[2]], simplifyVector = FALSE)
p <- ProjectBundle$open(args[[1]])
options <- if (is.null(request$options)) list() else request$options
path <- file.path(args[[1]], ".nb_project_bundle", "project.json")
before <- readBin(path, "raw", file.info(path)$size)
if (identical(request$mode, "timeline")) {
  answer <- list(pages = list())
  repeat {
    page <- do.call(p$timeline, options)
    next_cursor <- page$next_cursor
    page$next_cursor <- !is.null(next_cursor)
    answer$pages[[length(answer$pages) + 1L]] <- page
    if (is.null(next_cursor)) break
    options$cursor <- next_cursor
  }
  answer$summary <- sub("Next cursor: .*\\z", "Next cursor: checked", do.call(p$timeline_summary, request$options), perl = TRUE)
} else {
  answer <- list(report = do.call(p$execution_history, options), summary = do.call(p$execution_history_summary, options))
}
stopifnot(identical(before, readBin(path, "raw", file.info(path)$size)))
if (identical(request$mode, "native_run")) {
  writeLines("run <- function(inputs, params, seeds, outputs) writeLines('synthetic', outputs[[1]])", file.path(args[[1]], "native.R"))
  data <- p$register_data("input.txt", "native", hash = TRUE)
  analysis <- p$register_analysis("native synthetic", list(data), code = "native.R", method = "synthetic", params = list(n = 1))
  receipt <- p$run_analysis(analysis, "run", list(list(path = "native-output.txt", kind = "result")))
  answer$analysis_ref <- analysis
  answer$native_report <- p$execution_history(analysis_ref = analysis)
  answer$native_summary <- p$execution_history_summary(analysis_ref = analysis)
}
cat(jsonlite::toJSON(answer, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
