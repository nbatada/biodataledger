args <- commandArgs(trailingOnly = TRUE)
script_path <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)))
source(file.path(dirname(dirname(script_path)), "examples/recovery_R.R"))
library(BioDataLedger)
p <- ProjectBundle$open(args[[1]])
manifest <- jsonlite::fromJSON(p$get_data(role = "recovery_manifest")$path, simplifyVector = FALSE)
preview <- preview_recovery(p, args[[1]], manifest)
stopifnot(length(preview$files) == 4L)
result <- apply_recovery(p, args[[1]], manifest, args[[2]], preview)
stopifnot(file.exists(file.path(args[[2]], result$entrypoint)))
invalid <- manifest
invalid$files[[1]]$destination <- "A/input.csv"
invalid$files[[2]]$destination <- "a/figure.svg"
stopifnot(inherits(try(preview_recovery(p, args[[1]], invalid), silent = TRUE), "try-error"))
invalid <- manifest
invalid$files[[3]]$source$analysis_ref$id <- "ANA-999"
stopifnot(inherits(try(preview_recovery(p, args[[1]], invalid), silent = TRUE), "try-error"))
bad_json <- tempfile(fileext = ".json")
writeLines('{"version":"biodataledger-recovery/1","version":"biodataledger-recovery/1"}', bad_json)
stopifnot(inherits(try(preview_recovery(p, args[[1]], bad_json), silent = TRUE), "try-error"))
