library(BioDataLedger)

main <- function() {
fail <- function(expr) stopifnot(inherits(try(force(expr), silent = TRUE), "try-error"))
record_count <- function(project) project$summary()$records
namespace <- asNamespace("BioDataLedger")
index_counter <- ".bdl_registration_index_counter"
metadata_calls <- ".bdl_registration_metadata_calls"
assign(index_counter, 0L, envir = .GlobalEnv)
assign(metadata_calls, logical(), envir = .GlobalEnv)
trace(".index_state", tracer = quote(assign(".bdl_registration_index_counter", get(".bdl_registration_index_counter", envir = .GlobalEnv) + 1L, envir = .GlobalEnv)), where = namespace, print = FALSE)
trace(".metadata_validate_state", tracer = quote(assign(".bdl_registration_metadata_calls", c(get(".bdl_registration_metadata_calls", envir = .GlobalEnv), is.null(record_only)), envir = .GlobalEnv)), where = namespace, print = FALSE)
on.exit({
  untrace(".index_state", where = namespace)
  untrace(".metadata_validate_state", where = namespace)
  rm(list = c(index_counter, metadata_calls), envir = .GlobalEnv)
}, add = TRUE)

reset_counters <- function() {
  assign(index_counter, 0L, envir = .GlobalEnv)
  assign(metadata_calls, logical(), envir = .GlobalEnv)
}
ordinary_registration_is_bounded <- function(expr) {
  reset_counters()
  force(expr)
  stopifnot(
    get(index_counter, envir = .GlobalEnv) == 0L,
    identical(get(metadata_calls, envir = .GlobalEnv), FALSE)
  )
}

root <- tempfile("registration-performance-")
stopifnot(dir.create(root, recursive = TRUE))
writeLines(c("sample_id,label", "S1,treated"), file.path(root, "metadata.csv"), useBytes = TRUE)
writeLines("payload", file.path(root, "data.txt"), useBytes = TRUE)

# Metadata-free DATA and ANA registration must not rebuild whole-state metadata indexes.
plain <- ProjectBundle$create("plain", root)
ordinary_registration_is_bounded(plain$register_data("data.txt", "input"))
plain_data <- plain$get_data("DATA-001@1")$ref
ordinary_registration_is_bounded(plain$register_analysis("ordinary", list(plain_data)))
plain_before <- record_count(plain)
fail(plain$register_data("data.txt", "bl_metadata_table"))
stopifnot(record_count(plain) == plain_before)
plain$save()
stopifnot(ProjectBundle$open(root)$get_analysis("ANA-001@1")$name == "ordinary")

# Once metadata is enabled, ordinary DATA/ANA registration stays record-local.
enabled_root <- tempfile("registration-performance-enabled-")
stopifnot(dir.create(enabled_root, recursive = TRUE))
writeLines(c("sample_id,label", "S1,treated"), file.path(enabled_root, "metadata.csv"), useBytes = TRUE)
writeLines("payload", file.path(enabled_root, "data.txt"), useBytes = TRUE)
enabled <- ProjectBundle$create("enabled", enabled_root)
metadata <- enabled$register_metadata("metadata.csv", "sample_preparation", "sample_id", authority = "fixture", reason = "fixture")
ordinary_registration_is_bounded(enabled$register_data("data.txt", "input"))
enabled_data <- enabled$get_data("DATA-002@1")$ref
ordinary_registration_is_bounded(enabled$register_analysis("ordinary", list(enabled_data)))

# Typed metadata registration and bindings retain whole-state validation.
reset_counters()
metadata_revision <- enabled$register_metadata("metadata.csv", "sample_preparation", "sample_id", authority = "fixture", reason = "revision", ref = metadata)
stopifnot(any(get(metadata_calls, envir = .GlobalEnv)))
reset_counters()
bound <- enabled$bind_metadata(enabled_data, list(metadata_revision), "fixture binding")
stopifnot(any(get(metadata_calls, envir = .GlobalEnv)))
before <- record_count(enabled)
before_history <- enabled$timeline(limit = 20L)
bad_metadata <- metadata_revision; bad_metadata$revision <- 99L
fail(enabled$bind_metadata(bound, list(bad_metadata), "malformed exact reference"))
stopifnot(record_count(enabled) == before, identical(enabled$timeline(limit = 20L), before_history))

reset_counters()
enabled$save()
reopened <- ProjectBundle$open(enabled_root)
stopifnot(any(get(metadata_calls, envir = .GlobalEnv)), reopened$check_metadata(bound)$bl_status == "PASS")
state_path <- file.path(enabled_root, ".nb_project_bundle", "project.json")
saved_state <- readBin(state_path, "raw", n = file.info(state_path)$size)
state <- jsonlite::fromJSON(rawToChar(saved_state), simplifyVector = FALSE)
state$project$bl_metadata_policy <- NULL
jsonlite::write_json(state, state_path, auto_unbox = TRUE, null = "null", digits = 15)
fail(ProjectBundle$open(enabled_root))
writeBin(saved_state, state_path)
stopifnot(ProjectBundle$open(enabled_root)$check_metadata(bound)$bl_status == "PASS")
cat("PASS: ordinary registration avoids whole-state metadata work\n")
}

main()
