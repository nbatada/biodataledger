#!/usr/bin/env Rscript
# Synthetic shared-library workflow using an installed BioDataLedger client.
library(BioDataLedger)

function_name <- "nb_utils_general_check_columns"
contract_v1 <- list(
  inputs = "A data.frame", parameters = "required: ordered column names",
  outputs = "Missing required names, in the supplied order",
  example = "nb_utils_general_check_columns(rows, c('item', 'price'))",
  limitations = "Checks column presence only; no scientific validation"
)
contract_v2 <- contract_v1
contract_v2$parameters <- "required: ordered names; strict=FALSE: error if missing"
source_v1_text <- c(
  "nb_utils_general_check_columns <- function(rows, required) {",
  "  setdiff(required, names(rows))",
  "}"
)
source_v2_text <- c(
  "nb_utils_general_check_columns <- function(rows, required, strict=FALSE) {",
  "  missing <- setdiff(required, names(rows))",
  "  if (strict && length(missing)) stop(paste('Missing columns:', paste(missing, collapse=', ')))",
  "  missing",
  "}"
)

check_capabilities <- function(project) {
  required <- c("register_helper", "find_helpers", "get_helper", "register_helper_from",
                "register_analysis", "register_result", "register_data", "resolve_data",
                "save_and_confirm")
  missing <- required[!vapply(required, function(name) is.function(project[[name]]), logical(1))]
  if (!length(missing)) {
    parameters <- c(find_helpers="sources", get_helper="verify", register_analysis="helper_refs")
    for (method in names(parameters)) {
      parameter <- parameters[[method]]
      if (!parameter %in% names(formals(project[[method]]))) {
        missing <- c(missing, paste0(method, "(", parameter, "=...)"))
      }
    }
  }
  if (length(missing)) {
    stop(paste("Loaded BioDataLedger", getNamespaceVersion("BioDataLedger"), "lacks",
               paste(missing, collapse=", "),
               "Use a compatible installed client; nothing was installed or upgraded."))
  }
}

select_exact <- function(report, library_root, source_ref) {
  matches <- Filter(function(card) {
    identical(card$source_project$location, library_root) &&
      identical(card$source_project$id, source_ref$project_id) && identical(card$ref, source_ref)
  }, report$helpers)
  if (length(matches) != 1L) stop("The reviewed helper was not uniquely found; inspect coverage.")
  matches[[1L]]
}

load_reviewed_snapshot <- function(project, helper_ref) {
  card <- project$get_helper(helper_ref, verify="snapshot")
  files <- card$verification$files
  if (card$verification$status != "pass" || length(files) != 1L) {
    stop("Retained source is missing or changed; no working-file fallback.")
  }
  path <- files[[1L]]$path
  # Only the reviewed single-file fixture above is loaded. This environment is not a sandbox.
  helpers <- new.env(parent=baseenv())
  sys.source(path, envir=helpers)
  list(call=helpers[[function_name]], path=path)
}

main <- function(destination=NULL) {
  if (is.null(destination)) {
    root <- tempfile("bdl-shared-library-")
  } else {
    root <- path.expand(destination)
    link <- Sys.readlink(root)
    if (file.exists(root) || (!is.na(link) && nzchar(link))) {
      stop("Destination must be new; existing files were not changed.")
    }
  }
  if (!dir.create(root, recursive=TRUE)) stop("Could not create the new demonstration workspace.")
  root <- normalizePath(root)
  library_root <- file.path(root, "library")
  analysis_root <- file.path(root, "analysis")
  dir.create(library_root)
  dir.create(analysis_root)
  settings <- list(shared_custom_library_folder=library_root) # Caller settings, not ledger state.
  script_path <- sub("^--file=", "", grep("^--file=", commandArgs(), value=TRUE))
  if (length(script_path) != 1L) stop("Run this complete example with Rscript.")
  script_path <- normalizePath(script_path, mustWork=TRUE)

  # 1. Register a reviewed function in a synthetic equivalent of ~/git/lib.
  library_project <- ProjectBundle$create("Synthetic shared library", library_root)
  check_capabilities(library_project)
  module <- file.path(library_root, "nb_utils_general.R")
  writeLines(source_v1_text, module)
  source_v1 <- library_project$register_helper(
    "Required columns", language="R", purpose="Check required table columns",
    contract=contract_v1, source=module, function_name=function_name,
    tags=list("general", "columns"))
  library_project$save()

  # 2. Find, inspect, adopt and save an exact helper in a separate project.
  project <- ProjectBundle$create("Unrelated synthetic analysis", analysis_root)
  project$status() # One ordinary session-start metadata query.
  report <- project$find_helpers("required columns", sources=list(settings$shared_custom_library_folder))
  chosen <- select_exact(report, library_root, source_v1)
  stopifnot(identical(library_project$get_helper(chosen$ref)$descriptor$contract, contract_v1))
  local_v1 <- project$register_helper_from(chosen)
  input_path <- file.path(analysis_root, "shop_table.csv")
  write.csv(data.frame(item="pencil", price=1.5), input_path, row.names=FALSE)
  data_ref <- project$register_data(input_path, "input", hash=TRUE)
  adoption_save_v1 <- project$save_and_confirm() # This example's approved helper/input batch.
  stopifnot(adoption_save_v1$status == "persisted", isTRUE(adoption_save_v1$registry_written))

  # 3. Verify retained source and exact input, then execute ordinary R.
  helper_v1 <- load_reviewed_snapshot(project, local_v1)
  verified_input <- project$resolve_data(ref=data_ref, verify="sha256")
  rows <- read.csv(verified_input$path, stringsAsFactors=FALSE)
  required <- c("item", "price", "currency")
  result_v1 <- helper_v1$call(rows, required)
  stopifnot(identical(result_v1, "currency"))
  output_v1 <- file.path(analysis_root, "missing_v1.json")
  writeLines(jsonlite::toJSON(as.list(result_v1), auto_unbox=TRUE), output_v1)
  analysis_v1 <- project$register_analysis(
    "Check shop table v1", inputs=list(data_ref), code=script_path,
    method="Required column presence", params=list(required=as.list(required)),
    helper_refs=list(local_v1))
  result_ref_v1 <- project$register_result(output_v1, analysis_v1, hash=TRUE)
  project$save()
  original_hash <- digest::digest(file=output_v1, algo="sha256", serialize=FALSE)
  original_source <- readBin(helper_v1$path, "raw", n=file.info(helper_v1$path)$size)

  # 4. With authority to edit this synthetic library, add optional strict behavior.
  writeLines(source_v2_text, module)
  source_v2 <- library_project$register_helper(
    "Required columns", language="R", purpose="Check required table columns",
    contract=contract_v2, source=module, function_name=function_name,
    tags=list("general", "columns"), ref=source_v1,
    reason="Add optional strict mode while preserving default behavior")
  library_project$save()
  report_v2 <- project$find_helpers("required columns", sources=list(settings$shared_custom_library_folder))
  chosen_v2 <- select_exact(report_v2, library_root, source_v2)
  stopifnot(identical(library_project$get_helper(chosen_v2$ref)$descriptor$contract, contract_v2))
  local_v2 <- project$register_helper_from(chosen_v2)
  adoption_save_v2 <- project$save_and_confirm()
  stopifnot(adoption_save_v2$status == "persisted", isTRUE(adoption_save_v2$registry_written))
  helper_v2 <- load_reviewed_snapshot(project, local_v2)
  result_v2 <- helper_v2$call(rows, required)
  stopifnot(identical(result_v2, result_v1),
            length(helper_v2$call(rows, c("item", "price"), strict=TRUE)) == 0L)
  strict_error <- tryCatch({helper_v2$call(rows, required, strict=TRUE); NULL},
                           error=function(error) conditionMessage(error))
  stopifnot(identical(strict_error, "Missing columns: currency"))
  output_v2 <- file.path(analysis_root, "missing_v2.json")
  writeLines(jsonlite::toJSON(as.list(result_v2), auto_unbox=TRUE), output_v2)
  analysis_v2 <- project$register_analysis(
    "Check shop table v2", inputs=list(data_ref), code=script_path,
    method="Required column presence", params=list(required=as.list(required), strict=FALSE),
    helper_refs=list(local_v2))
  result_ref_v2 <- project$register_result(output_v2, analysis_v2, hash=TRUE)
  project$save()

  # 5. Reopen and prove that old references, source bytes and output stayed unchanged.
  reopened <- ProjectBundle$open(analysis_root)
  stopifnot(
    identical(reopened$get_analysis(analysis_v1)$details$bl_helper_refs, list(local_v1)),
    identical(reopened$get_data(ref=result_ref_v1)$scope$transformation_ref, analysis_v1),
    identical(reopened$get_data(ref=result_ref_v2)$scope$transformation_ref, analysis_v2),
    identical(reopened$get_helper(local_v1)$foreign_refs[[1L]]$ref, source_v1),
    reopened$get_helper(local_v1, verify="snapshot")$verification$status == "pass",
    identical(readBin(helper_v1$path, "raw", n=file.info(helper_v1$path)$size), original_source),
    identical(digest::digest(file=output_v1, algo="sha256", serialize=FALSE), original_hash)
  )
  summary <- list(
    package_version=as.character(getNamespaceVersion("BioDataLedger")),
    library_root=library_root, analysis_root=analysis_root, `function`=function_name,
    source_refs=list(source_v1, source_v2), local_refs=list(local_v1, local_v2),
    analysis_refs=list(analysis_v1, analysis_v2), result_refs=list(result_ref_v1, result_ref_v2),
    adoption_saves=list(adoption_save_v1, adoption_save_v2),
    results=list(as.list(result_v1), as.list(result_v2)), strict_error=strict_error,
    original_result_sha256=original_hash, old_pin_preserved=TRUE)
  cat(jsonlite::toJSON(summary, auto_unbox=TRUE, null="null"), "\n")
  invisible(summary)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly=TRUE)
  if (length(args) == 0L) {
    main()
  } else if (length(args) == 2L && args[[1L]] == "--destination") {
    main(args[[2L]])
  } else {
    stop("Usage: Rscript examples/shared_library_R.R [--destination NEW_DIRECTORY]")
  }
}
