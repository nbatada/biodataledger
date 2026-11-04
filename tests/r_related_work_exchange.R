args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) stop("usage: root route selector-or-query limit", call. = FALSE)
library(BioDataLedger, lib.loc = Sys.getenv("BDL_R_LIB"))
p <- if (identical(args[[1L]], "import")) ProjectBundle$import_zip(args[[2L]], args[[3L]]) else ProjectBundle$open(args[[1L]])
offset <- if (identical(args[[1L]], "import")) 2L else 0L
report <- if (identical(args[[2L + offset]], "numeric_guard")) {
  ref <- p$get_data(ref = args[[3L + offset]])$ref
  supplied <- ref; supplied$revision <- as.numeric(ref$revision)
  analysis <- p$register_analysis("Native numeric reference", list(supplied))
  value <- p$related_work(input_ref = ref, limit = as.integer(args[[4L + offset]]))
  stopifnot(any(vapply(value$analyses, function(x) identical(x$ref$id, analysis$id), logical(1))))
  value
} else if (identical(args[[2L + offset]], "input")) {
  p$related_work(input_ref = args[[3L + offset]], limit = as.integer(args[[4L + offset]]))
} else {
  p$related_work(query = args[[3L + offset]], limit = as.integer(args[[4L + offset]]))
}
cat(jsonlite::toJSON(report, auto_unbox = TRUE, null = "null", digits = NA))
