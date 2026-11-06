args <- commandArgs(TRUE)
library(BioDataLedger)
p <- ProjectBundle$open(args[[1]])
options <- jsonlite::fromJSON(args[[2]], simplifyVector = FALSE)
path <- file.path(args[[1]], ".nb_project_bundle", "project.json")
read_registry <- function() readBin(path, "raw", file.info(path)$size)
before <- read_registry()
answer <- lapply(options, function(opts) {
  report_opts <- opts[setdiff(names(opts), c("style", "lineage_roots"))]
  list(report = do.call(p$export_graph, c(report_opts, list(format = "structured"))),
       dot = do.call(p$export_graph, opts))
})
stopifnot(identical(before, read_registry()))
cat(jsonlite::toJSON(answer, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
