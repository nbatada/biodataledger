args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("usage: library path", call. = FALSE)
library(BioDataLedger, lib.loc = args[[1L]])

root <- tempfile("bdl-helper-r-"); dir.create(root)
writeLines(c(
  "validate_required_columns <- function(table, required) setdiff(required, names(table))",
  "optional_extension <- function(table, required, allow_extra = TRUE) {",
  "  missing <- validate_required_columns(table, required)",
  "  if (!allow_extra && length(setdiff(names(table), required))) c(missing, 'unexpected columns') else missing",
  "}"
), file.path(root, "helper.R"))
writeLines("unused_helper_support <- function(x) x", file.path(root, "support.R"))
source(file.path(root, "helper.R"))
stopifnot(identical(validate_required_columns(data.frame(sample_id="a"), "sample_id"), character()),
          identical(validate_required_columns(data.frame(value=1), "sample_id"), "sample_id"),
          identical(optional_extension(data.frame(sample_id="a", value=1), "sample_id", FALSE), "unexpected columns"))

p <- ProjectBundle$create("helpers", root)
contract <- list(inputs="table", parameters="required columns", outputs="missing names",
                 example="validate_required_columns(table, required=c('sample_id'))", limitations="presence only")
first <- p$register_helper("required columns", "R", "check table columns", contract,
                           source=c("helper.R", "support.R"), function_name="validate_required_columns", tags=list("columns"))
analysis <- p$register_analysis("first table", list(), helper_refs=list(first))
second <- p$register_helper("required columns package", "R", "check columns from package", contract,
                            package="stats", version=as.character(utils::packageVersion("stats")), function_name="median", tags=list("columns"), ref=first)
stopifnot(identical(p$get_analysis(analysis)$details$bl_helper_refs, list(first)), second$revision == 2L,
          identical(p$get_helper(first, "sha256")$verification$status, "pass"),
          identical(p$get_helper(second, "identity")$verification$status, "qualified_match"))
stopifnot(inherits(try(p$update_record(first, list(name="mutated"), "synthetic"), silent=TRUE), "try-error"),
          inherits(try(p$update_record(second, list(details=list(bl_helper=list())), "synthetic"), silent=TRUE), "try-error"))
graph <- p$export_graph(ref=first, direction="downstream", format="structured")
stopifnot(any(vapply(graph$edges, function(x) identical(x$type, "declared_helper_use") && identical(x$to, analysis), logical(1))))

missing <- p$register_helper("missing package", "R", "synthetic package", contract,
                             package="definitelymissingbdlpackage", version="1.0", function_name="call")
mismatch <- p$register_helper("mismatch package", "R", "synthetic mismatch", contract,
                              package="stats", version="0.0.0", function_name="median")
stopifnot(identical(p$get_helper(missing, "identity")$verification$status, "missing"),
          identical(p$get_helper(mismatch, "identity")$verification$status, "mismatch"))
writeLines("validate_required_columns <- function(table, required) 'drift'", file.path(root, "helper.R"))
stopifnot(identical(p$get_helper(first, "sha256")$verification$status, "fail"))
file.remove(file.path(root, "support.R"))
missing_source <- p$get_helper(first, "sha256")$verification
stopifnot(identical(missing_source$status, "fail"), any(vapply(missing_source$files, function(x) identical(x$status, "missing"), logical(1))))
ordinary <- p$record_decision("ordinary", "synthetic", list())
stopifnot(inherits(try(p$register_analysis("bad", list(), helper_refs=list(ordinary)), silent=TRUE), "try-error"),
          inherits(try(p$register_helper("bad", "R", "bad source", contract, source=list(), function_name="f"), silent=TRUE), "try-error"))

for (i in seq_len(105L)) p$record_decision(sprintf("ordinary %03d", i), "synthetic", list())
found <- p$find_helpers("  CHECK   COLUMNS ")
stopifnot(found$coverage$scanned_latest_records == 100L, found$coverage$incomplete,
          found$coverage$scanned_latest_helpers <= 100L,
          identical(found$coverage$scope, "first 100 latest DEC records in this ledger; metadata only"))
p$save_and_confirm()
reopened <- ProjectBundle$open(root)
stopifnot(identical(reopened$get_helper(second, "identity")$verification$status, "qualified_match"))
plan <- reopened$preview_export("working", include=list(first, second))
stopifnot(length(plan$files) >= 1L)
bad_root <- tempfile("bdl-helper-malformed-"); dir.create(bad_root)
file.copy(file.path(root, ".nb_project_bundle"), bad_root, recursive=TRUE)
bad_path <- file.path(bad_root, ".nb_project_bundle", "project.json")
bad <- jsonlite::fromJSON(bad_path, simplifyVector=FALSE)
helper_slot <- which(vapply(bad$records, function(x) !is.null(x$details$bl_helper), logical(1)))[1L]
bad$records[[helper_slot]]$details$bl_helper$contract$inputs <- ""
writeLines(jsonlite::toJSON(bad, auto_unbox=TRUE, null="null"), bad_path, useBytes=TRUE)
stopifnot(inherits(try(ProjectBundle$open(bad_root), silent=TRUE), "try-error"))
bad_ref_root <- tempfile("bdl-helper-malformed-ref-"); dir.create(bad_ref_root)
file.copy(file.path(root, ".nb_project_bundle"), bad_ref_root, recursive=TRUE)
bad_ref_path <- file.path(bad_ref_root, ".nb_project_bundle", "project.json")
bad_ref <- jsonlite::fromJSON(bad_ref_path, simplifyVector=FALSE)
analysis_slot <- which(vapply(bad_ref$records, function(x) !is.null(x$details$bl_helper_refs), logical(1)))[1L]
bad_ref$records[[analysis_slot]]$details$bl_helper_refs[[1L]] <- ordinary
writeLines(jsonlite::toJSON(bad_ref, auto_unbox=TRUE, null="null"), bad_ref_path, useBytes=TRUE)
stopifnot(inherits(try(ProjectBundle$open(bad_ref_root), silent=TRUE), "try-error"))
cat("r helper tests passed\n")

# An installed but unloaded package is inspected without loading its namespace.
before_namespaces <- loadedNamespaces()
unloaded <- p$register_helper("installed package", "R", "inspect metadata only", contract,
  package="splines", version=as.character(utils::packageVersion("splines")), function_name="ns")
stopifnot(identical(p$get_helper(unloaded, "identity")$verification$status, "qualified_match"),
          setequal(before_namespaces, loadedNamespaces()))
p$save()
retained <- p$get_helper(first, "snapshot")
stopifnot(identical(retained$verification$status, "pass"),
          identical(retained$verification$basis, "retained_snapshot"),
          all(vapply(retained$verification$files, function(x) file.exists(x$path), logical(1))))
