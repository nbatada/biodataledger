.obj <- function(...) { x <- list(...); if (!length(x)) names(x) <- character(); x }
.arr <- function(x = list()) unname(as.list(x))
.uuid <- function() as.character(uuid::UUIDgenerate())
.now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
.fail <- function(message) stop(message, call. = FALSE)
.copy <- function(x) unserialize(serialize(x, NULL))
.json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
.metadata_limit <- 20971520
# Parse only the bounded bytes that were actually read.
.parse_json_bytes <- function(bytes) {
  if (length(bytes) > .metadata_limit) .fail("Metadata size limit exceeded")
  text <- rawToChar(bytes)
  if (!jsonlite::validate(text)) .fail("Invalid JSON")
  parsed <- jsonlite::fromJSON(text, simplifyVector = FALSE)
  .reject_duplicate_keys(parsed)
  parsed
}
.read_json <- function(path) {
  if (is.na(file.info(path)$size) || file.info(path)$size > .metadata_limit) .fail("Metadata size limit exceeded")
  bytes <- readBin(path, "raw", n = .metadata_limit + 1L)
  .parse_json_bytes(bytes)
}
.reject_duplicate_keys <- function(value) {
  if (!is.list(value)) return(invisible(NULL))
  # simplifyVector=FALSE retains decoded object names, including duplicates.
  keys <- names(value)
  if (!is.null(keys) && anyDuplicated(keys)) .fail("Duplicate JSON key")
  for (child in value) .reject_duplicate_keys(child)
  invisible(NULL)
}
.hash <- function(path) digest::digest(file = path, algo = "sha256", serialize = FALSE)
.safe_rel <- function(x) {
  is.character(x) && length(x) == 1L && nzchar(x) && !endsWith(x, "/") && !grepl(":", x, fixed = TRUE) && !grepl("[\\\\[:cntrl:]]|^/|^[A-Za-z]:|(^|/)\\.{1,2}(/|$)|//", x)
}
.context_locator <- function(root, path) {
  if (is.null(path)) return(NULL)
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) .fail("Invalid context path")
  if (startsWith(path, "/")) return(.obj(kind = "external", value = path))
  if (!.safe_rel(path)) .fail("Unsafe context path")
  .obj(kind = "project", value = path)
}
.locator <- function(root, path) {
  if (is.list(path) && identical(path$kind, "uri")) return(path)
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) .fail("Invalid path")
  candidate <- if (startsWith(path, "/")) path else file.path(root, path)
  if (!file.exists(candidate)) .fail("Registered local path is missing")
  real <- normalizePath(candidate, mustWork = TRUE)
  base <- paste0(normalizePath(root, mustWork = TRUE), "/")
  if (startsWith(real, base)) .obj(kind = "project", value = substring(real, nchar(base) + 1L)) else .obj(kind = "external", value = real)
}
.resolve <- function(root, state, loc) {
  if (is.null(loc)) return(NULL)
  key <- paste0(loc$kind, ":", loc$value)
  if (!is.null(state$bindings[[key]])) {
    binding <- state$bindings[[key]]
    if (startsWith(binding, "/")) return(binding)
    if (!.safe_rel(binding)) .fail("Unsafe local binding")
    return(file.path(root, binding))
  }
  if (identical(loc$kind, "project")) {
    if (!.safe_rel(loc$value)) .fail("Unsafe project locator")
    p <- file.path(root, loc$value)
    if (file.exists(p) && !startsWith(normalizePath(p, mustWork = TRUE), paste0(normalizePath(root), "/"))) .fail("Project locator escapes root")
    return(p)
  }
  if (identical(loc$kind, "external") && !isTRUE(state$imported)) return(loc$value)
  if (identical(loc$kind, "uri")) return(loc$value)
  NULL
}
# Derived indexes stay in memory and are rebuilt after accepted mutations.
.index_state <- function(state) {
  exact <- new.env(hash = TRUE, parent = emptyenv()); latest <- new.env(hash = TRUE, parent = emptyenv())
  next_id <- new.env(hash = TRUE, parent = emptyenv())
  for (i in seq_along(state$records)) {
    rec <- state$records[[i]]; key <- paste0(rec$id, "@", rec$revision)
    if (exists(key, exact, inherits = FALSE)) .fail("Duplicate record version")
    assign(key, i, exact)
    if (!exists(rec$id, latest, inherits = FALSE) || rec$revision > state$records[[get(rec$id, latest)]]$revision) assign(rec$id, i, latest)
    prefix <- sub("-.*", "", rec$id); number <- suppressWarnings(as.integer(sub(".*-", "", rec$id)))
    if (!is.na(number)) assign(prefix, max(number, if (exists(prefix, next_id, inherits = FALSE)) get(prefix, next_id) else 0L), next_id)
  }
  counts <- .obj(data = 0L, analysis = 0L, figure = 0L)
  roles <- new.env(hash = TRUE, parent = emptyenv())
  role_counts <- new.env(hash = TRUE, parent = emptyenv())
  for (id in ls(latest)) {
    kind <- state$records[[get(id, latest)]]$kind
    if (kind %in% names(counts)) counts[[kind]] <- counts[[kind]] + 1L
    rec <- state$records[[get(id, latest)]]
    if (identical(rec$kind, "data") && identical(rec$status, "active")) {
      bucket <- if (exists(rec$role, roles, inherits = FALSE)) get(rec$role, roles) else character()
      bucket <- c(bucket, rec$id)
      assign(rec$role, bucket, roles)
      assign(rec$role, length(bucket), role_counts)
    }
  }
  summary_cache <- new.env(parent = emptyenv())
  summary_cache$counts <- counts
  summary_cache$purposes <- sort(names(state$current), method = "radix")
  attr(state, "record_index") <- list(exact = exact, latest = latest, next_id = next_id, roles = roles, role_counts = role_counts, summary = summary_cache)
  state
}
.index_add <- function(state, rec) {
  index <- attr(state, "record_index")
  i <- length(state$records); key <- paste0(rec$id, "@", rec$revision)
  is_new <- !exists(rec$id, index$latest, inherits = FALSE)
  old <- if (is_new) NULL else state$records[[get(rec$id, index$latest)]]
  if (!is.null(old) && identical(old$kind, "data") && identical(old$status, "active")) {
    bucket <- get(old$role, index$roles)
    bucket <- bucket[bucket != old$id]
    assign(old$role, bucket, index$roles)
    assign(old$role, length(bucket), index$role_counts)
  }
  if (identical(rec$kind, "data") && identical(rec$status, "active")) {
    bucket <- if (exists(rec$role, index$roles, inherits = FALSE)) get(rec$role, index$roles) else character()
    bucket <- c(bucket, rec$id)
    assign(rec$role, bucket, index$roles)
    assign(rec$role, length(bucket), index$role_counts)
  }
  assign(key, i, index$exact)
  assign(rec$id, i, index$latest)
  if (is_new && rec$kind %in% names(index$summary$counts)) index$summary$counts[[rec$kind]] <- index$summary$counts[[rec$kind]] + 1L
  prefix <- sub("-.*", "", rec$id)
  number <- as.integer(sub(".*-", "", rec$id))
  assign(prefix, max(number, if (exists(prefix, index$next_id, inherits = FALSE)) get(prefix, index$next_id) else 0L), index$next_id)
  state
}
.lookup_record <- function(state, ref) {
  index <- attr(state, "record_index")
  if (!is.null(index)) {
    key <- paste0(ref$id, "@", ref$revision)
    if (!exists(key, index$exact, inherits = FALSE)) return(NULL)
    return(state$records[[get(key, index$exact, inherits = FALSE)]])
  }
  for (rec in state$records) if (identical(rec$id, ref$id) && rec$revision == ref$revision) return(rec)
  NULL
}
.ref <- function(state, x) {
  if (is.character(x) && length(x) == 1L) {
    if (!grepl("^(DATA|ANA|FIG|DEC|DES)-[0-9]{3,}@[1-9][0-9]*$", x)) .fail("Exact revision required")
    bits <- strsplit(x, "@", fixed = TRUE)[[1]]; x <- .obj(project_id = state$project$id, id = bits[1], revision = as.integer(bits[2]))
  }
  .validate_ref_shape(state, x)
  if (is.null(.lookup_record(state, x))) .fail("Dangling reference")
  x
}
.record <- function(state, ref) .lookup_record(state, .ref(state, ref))
.next_id <- function(state, kind) {
  prefix <- switch(kind, data = "DATA", analysis = "ANA", figure = "FIG", decision = "DEC", design = "DES")
  index <- attr(state, "record_index")
  if (!is.null(index)) return(sprintf("%s-%03d", prefix, if (exists(prefix, index$next_id, inherits = FALSE)) get(prefix, index$next_id) + 1L else 1L))
  ids <- vapply(state$records, function(r) r$id, character(1)); nums <- as.integer(sub(".*-", "", ids[startsWith(ids, paste0(prefix, "-"))]))
  sprintf("%s-%03d", prefix, if (length(nums)) max(nums) + 1L else 1L)
}
.make_ref <- function(state, rec) .obj(project_id = state$project$id, id = rec$id, revision = rec$revision)
.new_record <- function(state, kind, name, locator = NULL, role = NULL, type = NULL, sha256 = NULL, size = NULL, inputs = NULL, analysis = NULL, code = list(), method = NULL, params = NULL, details = .obj(), status = "active", foreign_refs = list(), design = NULL) {
  rec <- .obj(kind = kind, id = .next_id(state, kind), revision = 1L, name = name, created_at = .now(), locator = locator, role = role, type = type, sha256 = sha256, size = size, inputs = inputs, analysis = analysis, code = .arr(code), method = method, params = params, details = details, status = status, foreign_refs = .arr(foreign_refs))
  if (!is.null(design)) rec$design <- design
  rec
}
.finite_tree <- function(x) {
  if (is.numeric(x) && any(!is.finite(x) | abs(x) > 9007199254740991)) .fail("Unsafe JSON number")
  if (is.list(x)) for (value in x) .finite_tree(value)
  invisible(TRUE)
}
.is_obj <- function(x) is.list(x) && !is.null(names(x))
.is_arr <- function(x) is.list(x) && is.null(names(x))
.is_int <- function(x, positive = FALSE) is.numeric(x) && length(x) == 1L && is.finite(x) && x == floor(x) && abs(x) <= 9007199254740991 && (!positive || x >= 1)
.is_uuid <- function(x) is.character(x) && length(x) == 1L && grepl("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", x)
.is_sha <- function(x) is.character(x) && length(x) == 1L && grepl("\\A[0-9a-fA-F]{64}\\z", x, perl = TRUE)
.validate_locator <- function(x) {
  if (!.is_obj(x) || !setequal(names(x), c("kind", "value")) || !is.character(x$value) || length(x$value) != 1L || !nzchar(x$value) || !x$kind %in% c("project", "external", "uri")) .fail("Invalid locator")
  if (x$kind == "project" && !.safe_rel(x$value)) .fail("Unsafe project locator")
  if (x$kind == "external" && !startsWith(x$value, "/")) .fail("External locator must be absolute")
}
.validate_ref_shape <- function(state, x) {
  if (!.is_obj(x) || !setequal(names(x), c("project_id", "id", "revision")) || !identical(x$project_id, state$project$id) || !is.character(x$id) || length(x$id) != 1L || !grepl("^(DATA|ANA|FIG|DEC|DES)-[0-9]{3,}$", x$id) || !.is_int(x$revision, TRUE)) .fail("Invalid reference")
}
.design_text <- function(x, optional = FALSE) is.null(x) && optional || is.character(x) && length(x) == 1L && !is.na(x) && nzchar(trimws(x))
.design_levels <- function(x) .is_arr(x) && length(x) > 0L && all(vapply(x, .design_text, logical(1))) && !anyDuplicated(unlist(x, use.names = FALSE))
.validate_design_details <- function(state, x) {
  fields <- c("condition", "levels", "selected_levels", "reference_level", "replicate", "selection_reason", "evidence_source", "metadata_check", "context")
  if (!.is_obj(x) || !setequal(names(x), fields) || !.design_text(x$condition) || !.design_text(x$reference_level, TRUE) || !.design_text(x$replicate, TRUE) || !(is.null(x$selection_reason) || is.character(x$selection_reason) && length(x$selection_reason) == 1L && !is.na(x$selection_reason)) || !.design_levels(x$levels) || !.design_levels(x$selected_levels)) .fail("Invalid design details")
  levels <- unlist(x$levels, use.names = FALSE); selected <- unlist(x$selected_levels, use.names = FALSE)
  if (!all(selected %in% levels) || !is.null(x$reference_level) && !x$reference_level %in% selected) .fail("Invalid design level selection")
  if (!x$evidence_source %in% c("scientist-declared", "metadata-verified")) .fail("Invalid design evidence source")
  report <- x$metadata_check
  if (identical(x$evidence_source, "scientist-declared")) {
    if (!is.null(report)) .fail("Declared design cannot claim metadata verification")
  } else {
    report_fields <- c("valid", "row_count", "observed_levels", "missing_levels", "missing_selected_levels", "missing_columns", "unexpected_levels", "missing_condition_values", "missing_replicate_values")
    if (!.is_obj(report) || !setequal(names(report), report_fields) || !identical(report$valid, TRUE) || !.is_int(report$row_count, TRUE)) .fail("Invalid verified metadata report")
    for (field in c("observed_levels", "missing_levels", "missing_selected_levels", "missing_columns", "unexpected_levels")) {
      values <- report[[field]]
      if (!.is_arr(values) || !all(vapply(values, function(v) is.character(v) && length(v) == 1L && !is.na(v), logical(1))) || anyDuplicated(unlist(values, use.names = FALSE))) .fail("Invalid metadata report values")
    }
    observed <- unlist(report$observed_levels, use.names = FALSE)
    if (!length(observed) || !all(observed %in% levels) || !identical(as.character(unlist(report$missing_levels, use.names = FALSE)), levels[!levels %in% observed]) || !identical(as.character(unlist(report$missing_selected_levels, use.names = FALSE)), selected[!selected %in% observed]) || length(report$missing_columns) || length(report$unexpected_levels) || !.is_int(report$missing_condition_values) || !.is_int(report$missing_replicate_values) || report$missing_condition_values != 0L || report$missing_replicate_values != 0L) .fail("Metadata verification is inconsistent")
  }
  if (!.is_arr(x$context)) .fail("Design context must be an array")
  for (ref in x$context) if (!.record_kind(state, ref) %in% c("data", "analysis")) .fail("Design context must reference data or analysis")
}
.check_design_metadata <- function(metadata, design) {
  if (!is.list(metadata) || is.null(names(metadata)) || anyDuplicated(names(metadata))) .fail("Metadata must be named columns")
  needed <- c(design$condition, design$replicate)
  missing_columns <- needed[!needed %in% names(metadata)]
  levels <- unlist(design$levels, use.names = FALSE); selected <- unlist(design$selected_levels, use.names = FALSE)
  if (length(missing_columns)) return(.obj(valid = FALSE, row_count = 0L, observed_levels = list(), missing_levels = .arr(levels), missing_selected_levels = .arr(selected), missing_columns = .arr(missing_columns), unexpected_levels = list(), missing_condition_values = 0L, missing_replicate_values = 0L))
  normalize <- function(column, numeric_ok = FALSE) {
    if (is.factor(column)) column <- as.character(column)
    if (is.list(column)) {
      column <- lapply(column, function(value) {
        if (is.null(value) || length(value) == 1L && (is.na(value) || is.numeric(value) && !is.finite(value))) return(NA_character_)
        if (length(value) != 1L || !(is.character(value) || numeric_ok && is.numeric(value))) .fail("Invalid metadata value")
        as.character(value)
      })
      return(unlist(column, use.names = FALSE))
    }
    if (!is.atomic(column) || !(is.character(column) || numeric_ok && is.numeric(column))) .fail("Invalid metadata column")
    column
  }
  condition <- normalize(metadata[[design$condition]])
  replicate <- if (is.null(design$replicate)) NULL else normalize(metadata[[design$replicate]], TRUE)
  if (!is.null(replicate) && length(replicate) != length(condition)) .fail("Invalid metadata columns")
  missing_condition <- is.na(condition) | !nzchar(trimws(condition))
  missing_replicate <- if (is.null(replicate)) logical(length(condition)) else if (is.numeric(replicate)) !is.finite(replicate) else is.na(replicate) | !nzchar(trimws(replicate))
  observed <- unique(condition[!missing_condition])
  .obj(valid = length(condition) > 0L && !any(missing_condition) && !any(missing_replicate) && all(observed %in% levels), row_count = length(condition), observed_levels = .arr(observed), missing_levels = .arr(levels[!levels %in% observed]), missing_selected_levels = .arr(selected[!selected %in% observed]), missing_columns = list(), unexpected_levels = .arr(observed[!observed %in% levels]), missing_condition_values = sum(missing_condition), missing_replicate_values = sum(missing_replicate))
}
.scope_fields <- c("observation_unit", "condition_values", "selection", "assay", "layer", "assignment_inclusion", "sample_manifest_ref", "transformation_ref", "evidence", "membership_evidence")
.scope_expected_fields <- c("condition_values", "assignment_inclusion", "observation_unit", "assay", "layer")
.scope_array <- function(x) is.null(x) || .design_levels(x)
.scope_ref <- function(state, ref, kinds) {
  if (is.null(ref)) return(invisible(NULL))
  .validate_ref_shape(state, ref)
  if (!.record_kind(state, ref) %in% kinds) .fail("Invalid scope reference kind")
}
.normalize_scope <- function(scope) {
  if (!.is_obj(scope) || anyDuplicated(names(scope)) || !all(names(scope) %in% .scope_fields)) .fail("Invalid scope")
  out <- .obj()
  for (key in .scope_fields) out[key] <- list(if (key %in% names(scope)) scope[[key]] else NULL)
  if (is.null(out$evidence)) out$evidence <- .obj(basis = "unknown", source_refs = list())
  if (is.null(out$membership_evidence)) out$membership_evidence <- .obj(status = "unknown", report_ref = NULL)
  out
}
.validate_scope <- function(state, scope) {
  if (!.is_obj(scope) || !setequal(names(scope), .scope_fields)) .fail("Invalid scope fields")
  for (key in c("observation_unit", "selection", "assay", "layer")) if (!.design_text(scope[[key]], TRUE)) .fail("Invalid scope text")
  for (key in c("condition_values", "assignment_inclusion")) if (!.scope_array(scope[[key]])) .fail("Invalid scope values")
  .scope_ref(state, scope$sample_manifest_ref, "data")
  .scope_ref(state, scope$transformation_ref, "analysis")
  evidence <- scope$evidence
  if (!.is_obj(evidence) || !setequal(names(evidence), c("basis", "source_refs")) || !is.character(evidence$basis) || length(evidence$basis) != 1L || !evidence$basis %in% c("unknown", "declared", "inferred") || !.is_arr(evidence$source_refs)) .fail("Invalid scope evidence")
  for (ref in evidence$source_refs) .scope_ref(state, ref, c("data", "analysis", "decision"))
  membership <- scope$membership_evidence
  if (!.is_obj(membership) || !setequal(names(membership), c("status", "report_ref")) || !is.character(membership$status) || length(membership$status) != 1L || !membership$status %in% c("unknown", "declared", "inferred", "verification_recorded")) .fail("Invalid membership evidence")
  if (identical(membership$status, "verification_recorded") != !is.null(membership$report_ref)) .fail("Membership report reference required only for recorded verification")
  .scope_ref(state, membership$report_ref, "data")
  invisible(TRUE)
}
.validate_expected_scope <- function(scope) {
  if (is.null(scope)) return(NULL)
  if (!.is_obj(scope) || anyDuplicated(names(scope)) || !length(scope) || !all(names(scope) %in% .scope_expected_fields)) .fail("INVALID_SCOPE: expected_scope has invalid keys")
  for (key in names(scope)) {
    value <- scope[[key]]
    if (is.null(value) || if (key %in% c("condition_values", "assignment_inclusion")) !.design_levels(value) else !.design_text(value)) .fail("INVALID_SCOPE: expected_scope has invalid values")
  }
  scope
}
.scope_compare <- function(actual, required) {
  for (key in names(required)) {
    value <- actual[[key]]
    if (is.null(value)) return("SCOPE_UNKNOWN")
    if (key %in% c("condition_values", "assignment_inclusion")) {
      if (!setequal(unlist(value, use.names = FALSE), unlist(required[[key]], use.names = FALSE))) return("SCOPE_CONFLICT")
    } else if (!identical(value, required[[key]])) return("SCOPE_CONFLICT")
  }
  NULL
}
.ref_text <- function(ref) paste0(ref$id, "@", ref$revision)
.verify_error <- function(code, ref = NULL) .fail(paste(code, if (is.null(ref)) "" else .ref_text(ref)))
.verify_file <- function(root, state, rec, ref) {
  path <- .resolve(root, state, rec$locator)
  if (is.null(path) || identical(rec$locator$kind, "uri")) .verify_error("UNRESOLVED", ref)
  if (!file.exists(path)) .verify_error("MISSING_FILE", ref)
  if (dir.exists(path) || file.access(path, 4L) != 0L) .verify_error("UNUSABLE_FILE", ref)
  before <- file.info(path)
  if (!is.null(rec$size) && before$size != rec$size) .verify_error("SIZE_MISMATCH", ref)
  if (is.null(rec$sha256)) .verify_error("MISSING_DIGEST", ref)
  observed <- .hash(path)
  after <- file.info(path)
  if (!identical(before$size, after$size) || !identical(before$mtime, after$mtime) || !identical(before$ctime, after$ctime)) .verify_error("FILE_CHANGED", ref)
  if (!identical(tolower(rec$sha256), tolower(observed))) .verify_error("DIGEST_MISMATCH", ref)
  list(path = path, observed = observed)
}
.same_exact_ref <- function(state, left, right, kind) {
  valid <- tryCatch({.validate_ref_shape(state, left); .scope_ref(state, left, kind); TRUE}, error = function(e) FALSE)
  valid && identical(left$project_id, right$project_id) && identical(left$id, right$id) && identical(left$revision, right$revision)
}
.valid_utc_timestamp <- function(x) {
  if (!.design_text(x) || !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", x)) return(FALSE)
  parsed <- suppressWarnings(strptime(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  !is.na(parsed) && identical(format(parsed, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), x)
}
.read_verified_report <- function(root, state, rec, ref) {
  path <- .resolve(root, state, rec$locator)
  if (is.null(path) || identical(rec$locator$kind, "uri") || !file.exists(path) || dir.exists(path) || file.access(path, 4L) != 0L || is.null(rec$sha256)) .verify_error("MEMBERSHIP_EVIDENCE", ref)
  before <- file.info(path)
  if (is.na(before$size) || before$size > .metadata_limit || !is.null(rec$size) && before$size != rec$size) .verify_error("MEMBERSHIP_EVIDENCE", ref)
  bytes <- readBin(path, "raw", n = .metadata_limit + 1L)
  after <- file.info(path)
  if (length(bytes) > .metadata_limit || !identical(before$size, after$size) || !identical(before$mtime, after$mtime) || !identical(before$ctime, after$ctime) || length(bytes) != before$size || !identical(.hash_raw(bytes), rec$sha256)) .verify_error("MEMBERSHIP_EVIDENCE", ref)
  .parse_json_bytes(bytes)
}
.check_membership_report <- function(root, state, subject, subject_ref, subject_hash, check_membership = TRUE) {
  scope <- subject$scope; ev <- scope$membership_evidence
  if (is.null(ev) || !identical(ev$status, "verification_recorded")) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref)
  member_ref <- subject$details$membership
  if (is.null(member_ref)) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref)
  report_ref <- ev$report_ref
  member <- .record(state, member_ref); report_rec <- .record(state, report_ref)
  if (is.null(member$sha256)) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref)
  if (check_membership) .verify_file(root, state, member, member_ref)
  report <- tryCatch(.read_verified_report(root, state, report_rec, report_ref), error = function(e) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref))
  fields <- c("report_version", "subject_sha256", "membership_ref", "membership_sha256", "key_columns", "key_namespace", "comparison", "result", "checked_at", "checker", "counts")
  if (!.is_obj(report) || !setequal(names(report), fields) && !setequal(names(report), c(fields, "observed_scope")) ||
      !identical(report$report_version, "biodataledger-membership-check/1") || !is.character(report$subject_sha256) || length(report$subject_sha256) != 1L || !grepl("^[0-9a-f]{64}$", report$subject_sha256) || !is.character(report$membership_sha256) || length(report$membership_sha256) != 1L || !grepl("^[0-9a-f]{64}$", report$membership_sha256) ||
      !identical(report$subject_sha256, subject_hash) || !identical(report$membership_sha256, member$sha256) ||
      !.same_exact_ref(state, report$membership_ref, member_ref, "data") || !.design_levels(report$key_columns) || !.design_text(report$key_namespace) ||
      !is.character(report$comparison) || length(report$comparison) != 1L || !report$comparison %in% c("ordered_keys", "set_keys") || !is.character(report$result) || length(report$result) != 1L || !report$result %in% c("match", "mismatch", "incomplete") ||
      !.valid_utc_timestamp(report$checked_at) ||
      !.is_obj(report$checker) || !setequal(names(report$checker), c("method", "origin", "analysis_ref")) || !.design_text(report$checker$method) || !is.character(report$checker$origin) || length(report$checker$origin) != 1L || !report$checker$origin %in% c("native_check", "manual_check") ||
      !.is_obj(report$counts) || !setequal(names(report$counts), c("subject_rows", "membership_rows", "subject_duplicate_keys", "membership_duplicate_keys", "missing_keys", "extra_keys")) ||
      !all(vapply(report$counts, function(x) .is_int(x) && x >= 0, logical(1)))) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref)
  if (!is.null(report$checker$analysis_ref)) tryCatch(.scope_ref(state, report$checker$analysis_ref, "analysis"), error = function(e) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref))
  counts <- report$counts
  actual_match <- counts$subject_rows == counts$membership_rows && all(unlist(counts[c("subject_duplicate_keys", "membership_duplicate_keys", "missing_keys", "extra_keys")]) == 0)
  if (!identical(report$result == "match", actual_match) || !identical(report$result, "match")) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref)
  checked_fields <- list()
  if ("observed_scope" %in% names(report)) {
    observed <- tryCatch(.validate_expected_scope(report$observed_scope), error = function(e) .verify_error("MEMBERSHIP_EVIDENCE", subject_ref))
    for (key in names(observed)) {
      if (!is.null(scope[[key]]) && !is.null(.scope_compare(scope, observed[key]))) .verify_error("SCOPE_CONFLICT", subject_ref)
      if (!is.null(scope[[key]])) checked_fields[[length(checked_fields) + 1L]] <- key
    }
  }
  sort(unlist(checked_fields, use.names = FALSE))
}
.validate <- function(state, record_only = NULL) {
  .finite_tree(if (is.null(record_only)) state else record_only)
  if (is.null(record_only) || is.null(attr(state, "record_index"))) state <- .index_state(state)
  if (!is.null(record_only) && !is.null(.lookup_record(state, .obj(project_id = state$project$id, id = record_only$id, revision = record_only$revision)))) .fail("Duplicate record version")
  if (!.is_arr(state$records) || !.is_arr(state$history)) .fail("Records and history must be arrays")
  if (is.null(names(state$current)) || is.null(names(state$bindings))) .fail("Current and bindings must be objects")
  required <- c("schema_version","project","state_revision","last_transaction","records","current","bindings","history","imported")
  if (!setequal(names(state), required) || !state$schema_version %in% c("0.1.0", "0.2.0", "0.3.0", "0.4.0")) .fail("Unsupported state schema")
  if (!.is_int(state$state_revision, TRUE) || !.is_uuid(state$last_transaction)) .fail("Invalid state revision or transaction")
  project_fields <- c("id","name","purpose","raw_dir","metadata","next_task","questions","authorities")
  if (!.is_obj(state$project) || !setequal(names(state$project), project_fields) && !(state$schema_version %in% c("0.2.0", "0.3.0", "0.4.0") && setequal(names(state$project), c(project_fields, "design")))) .fail("Invalid project fields")
  if (!.is_uuid(state$project$id) || !is.character(state$project$name) || length(state$project$name) != 1L || !nzchar(state$project$name) || !.is_arr(state$project$questions) || !.is_arr(state$project$authorities)) .fail("Invalid project identity or arrays")
  for (field in c("purpose", "next_task")) if (!is.null(state$project[[field]]) && (!is.character(state$project[[field]]) || length(state$project[[field]]) != 1L)) .fail("Invalid project text")
  for (field in c("raw_dir", "metadata")) if (!is.null(state$project[[field]])) .validate_locator(state$project[[field]])
  if (!is.logical(state$imported) || length(state$imported) != 1L || is.na(state$imported)) .fail("Invalid import flag")
  for (value in state$bindings) if (!is.character(value) || length(value) != 1L || (!startsWith(value, "/") && !.safe_rel(value))) .fail("Invalid binding")
  if (!is.null(state$project$design) && .record_kind(state, state$project$design) != "design") .fail("Project design must reference design")
  kinds <- c(DATA = "data", ANA = "analysis", FIG = "figure", DEC = "decision", DES = "design")
  fields <- c("kind","id","revision","name","created_at","locator","role","type","sha256","size","inputs","analysis","code","method","params","details","status","foreign_refs")
  for (r in if (is.null(record_only)) state$records else list(record_only)) {
    optional_fields <- if (state$schema_version %in% c("0.2.0", "0.3.0", "0.4.0") && r$kind %in% c("analysis", "figure") || state$schema_version %in% c("0.3.0", "0.4.0") && r$kind == "data") "design" else character()
    if (state$schema_version %in% c("0.3.0", "0.4.0") && r$kind == "data") optional_fields <- c(optional_fields, "scope")
    if (state$schema_version == "0.4.0" && r$kind %in% c("analysis", "figure")) optional_fields <- c(optional_fields, "input_mode")
    if (state$schema_version == "0.4.0" && r$kind == "figure") optional_fields <- c(optional_fields, "preservation")
    if (!.is_obj(r) || !all(fields %in% names(r)) || !all(names(r) %in% c(fields, optional_fields)) || anyDuplicated(names(r)) || !grepl("^(DATA|ANA|FIG|DEC|DES)-[0-9]{3,}$", r$id) || !identical(kinds[[sub("-.*", "", r$id)]], r$kind) || !.is_int(r$revision, TRUE) || !r$status %in% c("active","superseded","inactive")) .fail("Invalid record")
    if (!is.character(r$name) || length(r$name) != 1L || !.is_obj(r$details) || !.is_arr(r$code) || !.is_arr(r$foreign_refs) || (!is.null(r$params) && !.is_obj(r$params)) || (!is.null(r$inputs) && !.is_arr(r$inputs))) .fail("Invalid record fields")
    if (!nzchar(r$name) || !is.character(r$created_at) || length(r$created_at) != 1L) .fail("Record name and time required")
    for (field in c("role", "type", "method")) if (!is.null(r[[field]]) && (!is.character(r[[field]]) || length(r[[field]]) != 1L)) .fail("Invalid record text")
    if (r$kind %in% c("data", "figure") && is.null(r$locator)) .fail("File locator required")
    if (r$kind == "data" && (is.null(r$role) || !nzchar(r$role))) .fail("Data role required")
    if (r$kind == "figure" && (is.null(r$type) || !nzchar(r$type) || is.null(r$sha256))) .fail("Figure type and digest required")
    if (!is.null(r$sha256) && !.is_sha(r$sha256)) .fail("Invalid digest")
    if (!is.null(r$size) && (!.is_int(r$size) || r$size < 0)) .fail("Invalid size")
    for (entry in r$code) {
      if (!.is_obj(entry) || !setequal(names(entry), c("locator", "sha256", "snapshot"))) .fail("Invalid code entry")
      .validate_locator(entry$locator)
      if (!is.null(entry$sha256) && !.is_sha(entry$sha256)) .fail("Invalid code digest")
      if (!is.null(entry$snapshot) && !.safe_rel(entry$snapshot)) .fail("Invalid code snapshot")
    }
    if (!is.null(r$locator)) .validate_locator(r$locator)
    if (!is.null(r$inputs)) for (x in r$inputs) if (.record_kind(state, x) != "data") .fail("Input must reference data")
    if (!is.null(r$analysis) && .record_kind(state, r$analysis) != "analysis") .fail("Figure analysis must reference analysis")
    if ("input_mode" %in% names(r) && (!is.character(r$input_mode) || length(r$input_mode) != 1L || !r$input_mode %in% c("separate", "combined") || !is.null(r$analysis))) .fail("Invalid input_mode")
    if ("preservation" %in% names(r)) {
      x <- r$preservation
      if (!.is_obj(x) || !setequal(names(x), c("artifact_role", "source")) || !identical(x$artifact_role, "preserved_copy") || r$locator$kind != "project" || !startsWith(r$locator$value, ".nb_project_bundle/outputs/")) .fail("Invalid preservation")
      .validate_locator(x$source)
    }
    if (r$kind == "figure" && !is.null(r$analysis) && !is.null(r$design)) .fail("Linked figure cannot store a design reference")
    if (r$kind == "figure" && !is.null(r$analysis) && "design" %in% names(r)) .fail("Linked figure inherits its analysis design")
    if (!is.null(r$design) && .record_kind(state, r$design) != "design") .fail("Record design must reference design")
    if (r$kind == "design") {
      if (!state$schema_version %in% c("0.2.0", "0.3.0", "0.4.0") || r$id != "DES-001") .fail("Invalid design record identity")
      .validate_design_details(state, r$details)
    }
    if ("scope" %in% names(r)) .validate_scope(state, r$scope)
    for (field in c("parent","membership")) if (!is.null(r$details[[field]]) && .record_kind(state, r$details[[field]]) != "data") .fail("Selection reference must be data")
    if (!is.null(r$details$clustering_run) && .record_kind(state, r$details$clustering_run) != "analysis") .fail("Clustering run must be analysis")
  }
  if (is.null(record_only)) for (x in state$current) if (.record_kind(state, x) != "data") .fail("Current must reference data")
  if (is.null(record_only)) for (h in state$history) {
    if (!.is_obj(h) || !setequal(names(h), c("at","action","actor","reason","target","transaction"))) .fail("Invalid history entry")
    if (!is.null(h$target)) .validate_ref_shape(state, h$target)
    if (!is.null(h$transaction) && !.is_uuid(h$transaction)) .fail("Invalid history transaction")
  }
  invisible(TRUE)
}
.record_kind <- function(state, ref) .record(state, ref)$kind
.code_entries <- function(root, paths, snapshot_code) {
  if (is.null(paths)) return(list())
  if (is.character(paths)) paths <- as.list(paths)
  lapply(paths, function(path) {
    loc <- .locator(root, path); resolved <- .resolve(root, list(bindings = .obj(), imported = FALSE), loc)
    if (dir.exists(resolved)) .fail("Code must be a file")
    size <- file.info(resolved)$size
    if (snapshot_code && size > 1048576) .fail("Code snapshot exceeds 1 MiB")
    hash <- .hash(resolved)
    .obj(locator = loc, sha256 = hash, snapshot = if (snapshot_code) paste0(".nb_project_bundle/code/", hash) else NULL)
  })
}
ProjectBundle <- local({
  create <- function(name, project_dir, purpose = NULL, raw_dir = NULL, metadata = NULL) {
    if (missing(project_dir) || !dir.exists(project_dir)) .fail("Existing project directory required")
    if (!identical(Sys.info()[["sysname"]], "Darwin")) .fail("Writes currently require macOS")
    root <- normalizePath(project_dir, mustWork = TRUE); folder <- file.path(root, ".nb_project_bundle")
    if (file.exists(folder)) .fail("Registry already exists")
    state <- .obj(schema_version = "0.1.0", project = .obj(id = .uuid(), name = name, purpose = purpose, raw_dir = .context_locator(root, raw_dir), metadata = .context_locator(root, metadata), next_task = NULL, questions = list(), authorities = list()), state_revision = 1L, last_transaction = .uuid(), records = list(), current = .obj(), bindings = .obj(), history = list(), imported = FALSE)
    .validate(state)
    if (!dir.create(folder)) .fail("Cannot create registry")
    path <- file.path(folder, "project.json"); temp <- tempfile("project-", tmpdir = folder)
    bytes <- charToRaw(.json(state)); if (length(bytes) > .metadata_limit) .fail("Metadata size limit exceeded")
    writeBin(bytes, temp)
    if (!file.rename(temp, path)) .fail("Cannot publish initial registry")
    open(root)
  }
  open <- function(project_dir) {
    root <- normalizePath(project_dir, mustWork = TRUE); path <- file.path(root, ".nb_project_bundle", "project.json")
    if (!file.exists(path)) .fail("Project registry missing")
    state <- .read_json(path); .validate(state); state <- .index_state(state)
    loaded_digest <- .hash(path); loaded_revision <- state$state_revision
    pending_code <- list(); dirty <- FALSE
    event <- function(action, reason = NULL, target = NULL) {
      state$history[[length(state$history) + 1L]] <<- .obj(at = .now(), action = action, actor = "local", reason = reason, target = target, transaction = NULL)
      dirty <<- TRUE
    }
    view <- function(rec, check_files = FALSE) {
      p <- .resolve(root, state, rec$locator)
      out <- .copy(rec); out$ref <- .make_ref(state, rec); out["path"] <- list(p)
      out["available"] <- list(if (check_files) !is.null(p) && !identical(rec$locator$kind, "uri") && file.exists(p) else NULL)
      out$availability_checked <- check_files
      out
    }
    append_record <- function(rec, action, code_bytes = list(), context_check = TRUE, version = NULL) {
      proposed <- state
      if (!is.null(version)) proposed$schema_version <- version
      .validate(proposed, record_only = rec)
      if (context_check && rec$kind %in% c("analysis", "figure") && identical(context_report(rec)$status, "inconsistent")) .fail(paste0("SCOPE_CONFLICT: ", paste(unlist(context_report(rec)$issues), collapse = "; ")))
      state$schema_version <<- proposed$schema_version
      state$records[[length(state$records) + 1L]] <<- rec
      state <<- .index_add(state, rec)
      if (length(code_bytes)) pending_code[names(code_bytes)] <<- code_bytes
      ref <- .make_ref(state, rec); event(action, target = ref); ref
    }
    validate_details <- function(details) {
      if (is.null(details$provenance)) details$provenance <- .obj(file = "unknown", analytical = "declared")
      details
    }
    capture_code <- function(rec) {
      captured <- list()
      if (!length(rec$code)) return(captured)
      for (entry in rec$code) if (!is.null(entry$snapshot)) {
        dest <- entry$snapshot
        if (!is.null(pending_code[[dest]])) {
          if (.hash_raw(pending_code[[dest]]) != entry$sha256) .fail("Pending code snapshot changed")
          next
        }
        snapshot <- .resolve(root, state, .obj(kind = "project", value = dest))
        if (!is.null(snapshot) && file.exists(snapshot)) {
          if (dir.exists(snapshot) || .hash(snapshot) != entry$sha256) .fail("Recorded code snapshot changed")
          next
        }
        source <- .resolve(root, state, entry$locator)
        if (is.null(source) || !file.exists(source) || dir.exists(source) || file.info(source)$size > 1048576) .fail("Code snapshot source missing or oversized")
        bytes <- readBin(source, "raw", n = file.info(source)$size)
        if (.hash_raw(bytes) != entry$sha256) .fail("Code changed during registration")
        captured[[dest]] <- bytes
      }
      captured
    }
    select_design <- function(ref) {
      if (is.null(ref)) return(NULL)
      ref <- .ref(state, ref)
      if (.record_kind(state, ref) != "design") .fail("Design reference required")
      ref
    }
    context_report <- function(rec) {
      if (rec$kind == "figure" && !is.null(rec$analysis)) rec <- .record(state, rec$analysis)
      if (is.null(rec$design)) return(.obj(status = "unknown", issues = list(), unknown = list("design")))
      design <- .record(state, rec$design)$details
      inputs <- if (rec$kind == "data") list(rec) else lapply(rec$inputs, function(x) .record(state, x))
      issues <- unknown <- character(); union <- character()
      if (!length(inputs)) unknown <- "inputs"
      mode <- if (is.null(rec$input_mode)) if (length(inputs) <= 1L) "separate" else "unknown" else rec$input_mode
      if (mode == "unknown") unknown <- c(unknown, "input_mode")
      scope_unknown <- FALSE
      for (data in inputs) {
        label <- paste0(data$id, "@", data$revision)
        condition <- NULL
        if (!is.null(data$design)) condition <- .record(state, data$design)$details$condition
        if (is.null(condition)) {unknown <- c(unknown, paste(label, "condition")); scope_unknown <- TRUE; next}
        if (!identical(condition, design$condition)) {issues <- c(issues, paste(label, "condition differs")); next}
        values <- data$scope$condition_values
        if (is.null(values)) {unknown <- c(unknown, paste(label, "condition_values")); scope_unknown <- TRUE; next}
        values <- unlist(values, use.names = FALSE); union <- unique(c(union, values))
        if (!all(values %in% unlist(design$levels, use.names = FALSE))) issues <- c(issues, paste(label, "undeclared levels"))
        if (mode == "separate" && !all(unlist(design$selected_levels, use.names = FALSE) %in% values)) issues <- c(issues, paste(label, "selected levels absent"))
      }
      if (mode %in% c("combined", "unknown") && length(inputs) && !scope_unknown && !all(unlist(design$selected_levels, use.names = FALSE) %in% union)) issues <- c(issues, "combined selected levels absent")
      .obj(status = if (length(issues)) "inconsistent" else if (length(unknown)) "unknown" else "consistent", issues = .arr(issues), unknown = .arr(unknown))
    }
    check_context <- function(ref) {
      rec <- .record(state, ref)
      if (!rec$kind %in% c("data", "analysis", "figure")) .fail("Context requires data, analysis or figure")
      context_report(rec)
    }
    resolve_figure <- function(ref, verify) {
      if (missing(verify) || !identical(verify, "sha256")) .fail("verify='sha256' required")
      ref <- .ref(state, ref); rec <- .record(state, ref)
      if (rec$kind != "figure") .fail("Figure required")
      if (rec$status != "active") .fail("INACTIVE")
      checked <- tryCatch(.verify_file(root, state, rec, ref), error = function(e) .fail(paste0(conditionMessage(e), "; ", if (is.null(rec$preservation)) "no preserved copy recorded" else "preserved copy unavailable or changed")))
      out <- get_figure(ref); out$path <- checked$path; out$available <- TRUE; out$availability_checked <- TRUE
      out$verification <- .obj(file_integrity = "match", baseline_sha256 = rec$sha256, observed_sha256 = checked$observed)
      out
    }
    save_figure <- function(source, type = NULL, ref = NULL, ...) {
      context <- list(...)
      if (any(c("preservation", "artifact_role") %in% names(context))) .fail("Reserved preservation metadata")
      loc <- .locator(root, source); path <- .resolve(root, state, loc)
      if (is.null(path) || !file.exists(path) || dir.exists(path)) .fail("Source must be an existing regular file")
      original <- if (is.null(ref)) NULL else .copy(.record(state, ref))
      if (!is.null(original) && (original$kind != "figure" || length(context))) .fail("Figure revision retains its context; use update_record first")
      if (is.null(type) && is.null(original)) .fail("Figure type required")
      digest <- .hash(path)
      base <- file.path(root, ".nb_project_bundle", "outputs")
      dir.create(base, recursive = TRUE, showWarnings = FALSE)
      base <- .resolve(root, state, .obj(kind = "project", value = ".nb_project_bundle/outputs"))
      folder <- file.path(base, paste0("figure-", .uuid()))
      if (!dir.create(folder, showWarnings = FALSE)) .fail("Cannot exclusively create output directory")
      complete <- FALSE
      on.exit(if (!complete) unlink(folder, recursive = TRUE), add = TRUE)
      dest <- file.path(folder, basename(path))
      if (!file.copy(path, dest, overwrite = FALSE) || !identical(.hash(dest), digest) || !identical(.hash(path), digest)) .fail("Source changed or copy failed")
      preservation <- .obj(artifact_role = "preserved_copy", source = loc)
      if (is.null(original)) {
        rec <- do.call(figure_record, c(list(path = dest, type = type), context))
      } else {
        rec <- original; rec$revision <- state$records[[get(rec$id, attr(state, "record_index")$latest)]]$revision + 1L
        rec$created_at <- .now(); rec$locator <- .locator(root, dest); rec$sha256 <- digest; rec$size <- as.numeric(file.info(dest)$size)
        rec$details$format <- tolower(tools::file_ext(dest))
        if (!is.null(type)) rec$type <- type
      }
      rec$preservation <- preservation
      out <- append_record(rec, "save_figure", capture_code(rec), version = "0.4.0")
      complete <- TRUE; out
    }
    register_data <- function(path, role, name = NULL, hash = FALSE, ...) {
      loc <- .locator(root, path); p <- .resolve(root, state, loc)
      if (!is.null(p) && !file.access(p, 4) == 0) .fail("Unreadable file")
      size <- if (!is.null(p) && !dir.exists(p)) file.info(p)$size else NULL
      digest <- if (hash && !is.null(size)) .hash(p) else NULL
      if (hash && is.null(size)) .fail("Cannot hash directory or URI")
      details <- validate_details(.obj(...)); details$provenance$file <- if (!is.null(digest)) "captured" else "unknown"
      rec <- .new_record(state, "data", if (is.null(name)) basename(if (is.null(p)) loc$value else p) else name, loc, role = role, sha256 = digest, size = size, details = details)
      append_record(rec, "register_data")
    }
    register_analysis <- function(name, inputs, code = NULL, method = NULL, params = NULL, snapshot_code = TRUE, design_ref = state$project$design, input_mode = "separate", ...) {
      if (!is.null(inputs)) inputs <- .arr(lapply(inputs, function(x) {r <- .ref(state, x); if (.record_kind(state, r) != "data") .fail("Analysis inputs must be data"); r}))
      entries <- .code_entries(root, code, snapshot_code)
      rec <- .new_record(state, "analysis", name, inputs = inputs, code = entries, method = method, params = params, details = validate_details(.obj(...)), design = select_design(design_ref))
      rec["design"] <- list(select_design(design_ref)); rec$input_mode <- input_mode
      append_record(rec, "register_analysis", capture_code(rec), version = "0.4.0")
    }
    figure_record <- function(path, type, analysis = NULL, name = NULL, inputs = NULL, code = NULL, method = NULL, params = NULL, snapshot_code = TRUE, design_ref = state$project$design, input_mode = "separate", ...) {
      loc <- .locator(root, path); p <- .resolve(root, state, loc)
      if (is.null(p) || dir.exists(p)) .fail("Figure must be a local regular file")
      if (!is.null(analysis)) {
        analysis <- .ref(state, analysis)
        if (.record_kind(state, analysis) != "analysis") .fail("Figure analysis must reference analysis")
        if (!is.null(inputs) || !is.null(code) || !is.null(method) || !is.null(params) || !missing(design_ref) || !missing(input_mode)) .fail("Direct analytical fields conflict with analysis")
      }
      if (!is.null(inputs)) inputs <- .arr(lapply(inputs, function(x) {r <- .ref(state, x); if (.record_kind(state, r) != "data") .fail("Figure inputs must be data"); r}))
      entries <- .code_entries(root, code, snapshot_code)
      details <- validate_details(.obj(...)); if (any(c("preservation", "artifact_role") %in% names(details))) .fail("Reserved preservation metadata")
      details$format <- tolower(tools::file_ext(p)); details$provenance$file <- "captured"
      design <- if (is.null(analysis)) select_design(design_ref) else NULL
      rec <- .new_record(state, "figure", if (is.null(name)) tools::file_path_sans_ext(basename(p)) else name, loc, type = type, sha256 = .hash(p), size = file.info(p)$size, inputs = inputs, analysis = analysis, code = entries, method = method, params = params, details = details, design = design)
      if (is.null(analysis)) {rec["design"] <- list(design); rec$input_mode <- input_mode}
      rec
    }
    register_figure <- function(...) {
      rec <- figure_record(...)
      append_record(rec, "register_figure", capture_code(rec), version = "0.4.0")
    }
    get_data <- function(ref = NULL, role = NULL, purpose = NULL, check_files = FALSE) {
      if (!is.logical(check_files) || length(check_files) != 1L || is.na(check_files)) .fail("Invalid check_files")
      if (sum(!vapply(list(ref, role, purpose), is.null, logical(1))) != 1L) .fail("Choose exactly one selector")
      if (!is.null(purpose)) {ref <- state$current[[purpose]]; if (is.null(ref)) .fail("No current data for purpose")}
      if (!is.null(ref)) {rec <- .record(state, ref); if (rec$kind != "data") .fail("Not data"); out <- view(rec, check_files); out["design_ref"] <- list(.copy(rec$design)); out["design"] <- list(if (is.null(rec$design)) NULL else get_design(rec$design)); out["scope"] <- list(.copy(rec$scope)); return(out)}
      index <- attr(state, "record_index")
      if (!.design_text(role) || !exists(role, index$role_counts, inherits = FALSE) || get(role, index$role_counts) != 1L) .fail("Role selector is missing or ambiguous")
      id <- get(role, index$roles)[[1L]]
      rec <- state$records[[get(id, index$latest)]]
      get_data(ref = .make_ref(state, rec), check_files = check_files)
    }
    set_data_scope <- function(ref, scope, reason, design_ref = NULL) {
      if (!.design_text(reason)) .fail("Reason required")
      ref <- .ref(state, ref); rec <- .record(state, ref)
      if (rec$kind != "data") .fail("Scope requires data")
      if (!is.null(design_ref)) {design_ref <- .ref(state, design_ref); if (.record_kind(state, design_ref) != "design") .fail("Invalid design reference")}
      scope <- .normalize_scope(scope)
      .validate_scope(state, scope)
      if (identical(scope$membership_evidence$status, "verification_recorded")) {
        subject_hash <- rec$sha256
        if (is.null(subject_hash)) .verify_error("MEMBERSHIP_EVIDENCE", ref)
        candidate <- .copy(rec); candidate$scope <- scope
        .check_membership_report(root, state, candidate, ref, subject_hash, check_membership = FALSE)
      }
      new <- .copy(rec); new$revision <- state$records[[get(rec$id, attr(state, "record_index")$latest)]]$revision + 1L
      new$created_at <- .now(); new$scope <- scope; new["design"] <- list(design_ref)
      proposed <- .copy(state); proposed$schema_version <- if (state$schema_version == "0.4.0") "0.4.0" else "0.3.0"
      proposed$records[[length(proposed$records) + 1L]] <- new
      .validate(proposed, record_only = new)
      state <<- .index_state(proposed)
      out <- .make_ref(state, new); event("set_data_scope", reason, out); out
    }
    resolve_data <- function(ref = NULL, purpose = NULL, verify, expected_scope = NULL, require_membership = FALSE) {
      if (missing(verify) || !identical(verify, "sha256")) .verify_error("SELECTOR: verify='sha256' required")
      if (sum(!vapply(list(ref, purpose), is.null, logical(1))) != 1L) .verify_error("SELECTOR")
      if (!is.logical(require_membership) || length(require_membership) != 1L || is.na(require_membership)) .verify_error("SELECTOR")
      expected_scope <- .validate_expected_scope(expected_scope)
      if (!is.null(purpose)) {
        if (!.design_text(purpose)) .verify_error("SELECTOR")
        ref <- state$current[[purpose]]
        if (is.null(ref)) .verify_error("NO_CURRENT")
      }
      ref <- tryCatch(.ref(state, ref), error = function(e) .verify_error("SELECTOR"))
      rec <- .record(state, ref)
      if (rec$kind != "data") .verify_error("SELECTOR", ref)
      if (!identical(rec$status, "active")) .verify_error("INACTIVE", ref)
      if (is.null(rec$scope)) {
        if (!is.null(expected_scope)) .verify_error("SCOPE_UNKNOWN", ref)
        if (require_membership) .verify_error("MEMBERSHIP_EVIDENCE", ref)
      } else {
        if (!is.null(expected_scope)) {
          comparison <- .scope_compare(rec$scope, expected_scope)
          if (!is.null(comparison)) .verify_error(comparison, ref)
        }
        if (!is.null(rec$design) && !is.null(rec$scope$condition_values)) {
          design <- get_design(rec$design)
          values <- unlist(rec$scope$condition_values, use.names = FALSE)
          available <- unlist(design$levels, use.names = FALSE)
          selected <- unlist(design$selected_levels, use.names = FALSE)
          if (!all(values %in% available) || !all(selected %in% values)) .verify_error("SCOPE_CONFLICT", ref)
        }
      }
      if (require_membership && !identical(rec$scope$membership_evidence$status, "verification_recorded")) .verify_error("MEMBERSHIP_EVIDENCE", ref)
      checked <- .verify_file(root, state, rec, ref)
      verified_fields <- list()
      if (require_membership) verified_fields <- .arr(.check_membership_report(root, state, rec, ref, checked$observed))
      out <- get_data(ref = ref)
      out["available"] <- list(TRUE); out$availability_checked <- TRUE
      out$verification <- .obj(checked_at = .now(), baseline_sha256 = rec$sha256, observed_sha256 = checked$observed,
                               file_integrity = "match", scope_basis = if (is.null(rec$scope)) "unknown" else rec$scope$evidence$basis,
                               required_scope = if (is.null(expected_scope)) "not_requested" else "match",
                               membership = if (require_membership) "verified_against_recorded_evidence" else if (is.null(rec$scope)) "unknown" else if (identical(rec$scope$membership_evidence$status, "verification_recorded")) "verification_recorded_not_rechecked" else rec$scope$membership_evidence$status,
                               verified_scope_fields = verified_fields)
      out
    }
    get_figure <- function(ref, check_files = FALSE) {
      if (!is.logical(check_files) || length(check_files) != 1L || is.na(check_files)) .fail("Invalid check_files")
      rec <- .record(state, ref); if (rec$kind != "figure") .fail("Not figure")
      out <- view(rec, check_files)
      design_ref <- if (is.null(rec$analysis)) rec$design else .record(state, rec$analysis)$design
      out["design_ref"] <- list(.copy(design_ref)); out["design"] <- list(if (is.null(design_ref)) NULL else get_design(design_ref))
      if (!is.null(rec$analysis)) {
        a <- .record(state, rec$analysis)
        out$inputs <- .copy(a$inputs); out$code <- .copy(a$code); out$method <- a$method; out$params <- .copy(a$params)
      }
      out$analysis_details <- if (is.null(rec$analysis)) .copy(rec$details) else .copy(.record(state, rec$analysis)$details)
      out$analysis_details$provenance$file <- NULL # Analysis context is not the figure file.
      analytical_source <- if (is.null(rec$analysis)) rec else .record(state, rec$analysis)
      out["input_mode"] <- list(.copy(analytical_source$input_mode))
      out$provenance <- .obj(figure_file = if (is.null(rec$details$provenance$file)) "unknown" else rec$details$provenance$file,
                             analytical = if (is.null(analytical_source$details$provenance$analytical)) "unknown" else analytical_source$details$provenance$analytical,
                             execution = "unknown")
      out$unknown <- .arr(c(if (is.null(out$inputs)) "inputs", if (is.null(out$method)) "method", if (is.null(out$params)) "params", if (!length(out$code)) "code"))
      out["input_availability"] <- list(if (is.null(out$inputs)) NULL else .arr(lapply(out$inputs, function(x) .obj(ref = x, available = if (check_files) get_data(ref = x, check_files = TRUE)$available else NULL, availability_checked = check_files))))
      out$code_availability <- .arr(lapply(out$code, function(x) {
        key <- paste0(x$locator$kind, ":", x$locator$value)
        p <- if (!is.null(state$bindings[[key]])) .resolve(root, state, x$locator) else if (!is.null(x$snapshot)) .resolve(root, state, .obj(kind = "project", value = x$snapshot)) else .resolve(root, state, x$locator)
        .obj(reference = x, path = p, available = if (check_files) !is.null(p) && file.exists(p) else NULL, availability_checked = check_files)
      }))
      out$source_code_availability <- .arr(lapply(out$code_availability, function(x) x$available))
      out
    }
    get_analysis <- function(ref) {
      rec <- .record(state, ref); if (rec$kind != "analysis") .fail("Not analysis")
      out <- view(rec); out["design_ref"] <- list(.copy(rec$design)); out["design"] <- list(if (is.null(rec$design)) NULL else get_design(rec$design))
      out
    }
    get_design <- function(ref = NULL) {
      if (is.null(ref)) ref <- state$project$design
      if (is.null(ref)) return(NULL)
      rec <- .record(state, ref); if (rec$kind != "design") .fail("Not design")
      out <- .copy(rec$details); out$ref <- .make_ref(state, rec); out
    }
    get_condition <- function() get_design()$condition
    get_levels <- function() {x <- get_design()$levels; if (is.null(x)) NULL else unlist(x, use.names = FALSE)}
    get_selected_levels <- function() {x <- get_design()$selected_levels; if (is.null(x)) NULL else unlist(x, use.names = FALSE)}
    get_reference_level <- function() get_design()$reference_level
    get_replicate <- function() get_design()$replicate
    check_design_metadata <- function(metadata, ref = NULL) {
      design <- get_design(ref); if (is.null(design)) .fail("No design configured")
      .check_design_metadata(metadata, design)
    }
    set_design <- function(condition, levels, selected_levels = NULL, reference_level = NULL, replicate = NULL, selection_reason = NULL, metadata = NULL, context = list()) {
      if (!.design_text(condition) || !.design_text(reference_level, TRUE) || !.design_text(replicate, TRUE) || !(is.null(selection_reason) || is.character(selection_reason) && length(selection_reason) == 1L && !is.na(selection_reason))) .fail("Invalid design text")
      if (!is.character(levels) || !length(levels)) .fail("Invalid levels")
      if (is.null(selected_levels)) selected_levels <- levels
      if (!is.character(selected_levels) || !length(selected_levels)) .fail("Invalid selected levels")
      if (!is.list(context) || !is.null(names(context))) .fail("Invalid design context")
      context <- .arr(lapply(context, function(x) {ref <- .ref(state, x); if (!.record_kind(state, ref) %in% c("data", "analysis")) .fail("Design context must reference data or analysis"); ref}))
      details <- .obj(condition = condition, levels = .arr(levels), selected_levels = .arr(selected_levels), reference_level = reference_level, replicate = replicate, selection_reason = selection_reason, evidence_source = "scientist-declared", metadata_check = NULL, context = context)
      .validate_design_details(state, details)
      if (!is.null(metadata)) {
        report <- .check_design_metadata(metadata, details)
        if (!report$valid) .fail("Metadata does not match design")
        details$metadata_check <- report; details$evidence_source <- "metadata-verified"
      }
      existing <- Filter(function(r) identical(r$kind, "design"), state$records)
      rec <- .new_record(state, "design", "Experimental design", details = details)
      if (length(existing)) {rec$id <- "DES-001"; rec$revision <- max(vapply(existing, function(r) r$revision, numeric(1))) + 1L}
      proposed <- .copy(state); if (identical(proposed$schema_version, "0.1.0")) proposed$schema_version <- "0.2.0"
      proposed$records[[length(proposed$records) + 1L]] <- rec
      proposed$project$design <- .make_ref(proposed, rec)
      .validate(proposed)
      state <<- .index_state(proposed); event("set_design", reason = selection_reason, target = proposed$project$design)
      invisible(.copy(proposed$project$design))
    }
    find_figures <- function(query = NULL, type = NULL) {
      figures <- Filter(function(r) r$kind == "figure", state$records)
      latest <- lapply(split(figures, vapply(figures, function(r) r$id, character(1))), function(rs) rs[[which.max(vapply(rs, function(r) r$revision, numeric(1)))]])
      latest <- latest[order(names(latest))]
      if (!is.null(type)) latest <- Filter(function(r) identical(r$type, type), latest)
      if (!is.null(query) && nzchar(query)) {
        tokens <- strsplit(tolower(trimws(query)), "[[:space:]]+")[[1]]
        latest <- Filter(function(r) {hay <- tolower(paste(r$name, r$type, r$details$description)); all(vapply(tokens, function(t) grepl(t, hay, fixed = TRUE), logical(1)))}, latest)
      }
      lapply(latest, view)
    }
    save <- function() {
      if (!dirty) return(.obj(state_revision = state$state_revision, transaction = state$last_transaction))
      if (!identical(Sys.info()[["sysname"]], "Darwin")) .fail("Writes currently require macOS")
      folder <- file.path(root, ".nb_project_bundle"); lock <- file.path(folder, "write.lock")
      if (!dir.create(lock, showWarnings = FALSE)) .fail("Write lock held")
      on.exit(unlink(lock, recursive = TRUE), add = TRUE)
      path <- file.path(folder, "project.json")
      # Matching bytes retain the revision validated when this object was opened.
      if (.hash(path) != loaded_digest) .fail("Stale project state")
      proposed <- .copy(state); proposed$state_revision <- state$state_revision + 1L; proposed$last_transaction <- .uuid()
      for (i in seq_along(proposed$history)) if (is.null(proposed$history[[i]]$transaction)) proposed$history[[i]]$transaction <- proposed$last_transaction
      .validate(proposed)
      serialized <- charToRaw(.json(proposed))
      if (length(serialized) > .metadata_limit) .fail("Metadata size limit exceeded")
      for (dest in names(pending_code)) {
        bytes <- pending_code[[dest]]; target <- file.path(root, dest); dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
        if (file.exists(target)) {if (.hash(target) != basename(target)) .fail("Snapshot digest conflict")}
        else {if (.hash_raw(bytes) != basename(target)) .fail("Snapshot bytes changed"); writeBin(bytes, target)}
      }
      temp <- tempfile("project-", tmpdir = folder); con <- file(temp, "wb")
      writeBin(serialized, con); flush(con); close(con)
      on.exit(if (file.exists(temp)) unlink(temp), add = TRUE)
      if (isTRUE(getOption("BioDataLedger.inject_save_before_rename"))) .fail("Injected save failure before publication")
      if (!file.rename(temp, path)) .fail("Atomic replacement failed")
      state <<- .index_state(proposed); loaded_digest <<- .hash(path); loaded_revision <<- state$state_revision; pending_code <<- list(); dirty <<- FALSE
      .obj(state_revision = state$state_revision, transaction = state$last_transaction)
    }
    set_current <- function(ref, purpose, reason) {
      if (length(state$project$authorities)) .fail("Adopted authority makes current pointer reference-only")
      if (!is.character(purpose) || !nzchar(purpose) || !is.character(reason) || !nzchar(reason)) .fail("Purpose and reason required")
      ref <- .ref(state, ref); if (.record_kind(state, ref) != "data") .fail("Current must be data")
      if (!identical(.record(state, ref)$status, "active")) .fail("INACTIVE: current data must be active")
      is_new <- is.null(state$current[[purpose]])
      state$current[[purpose]] <<- ref
      if (is_new) attr(state, "record_index")$summary$purposes <- sort(c(attr(state, "record_index")$summary$purposes, purpose), method = "radix")
      event("set_current", reason, ref); invisible(ref)
    }
    set_context <- function(changes) {
      allowed <- c("purpose","questions","next_task","raw_dir","metadata","authorities")
      if (!.is_obj(changes) || !all(names(changes) %in% allowed)) .fail("Unsupported context field")
      project <- .copy(state$project)
      for (key in names(changes)) {
        value <- .copy(changes[[key]])
        if (key %in% c("raw_dir", "metadata")) value <- .context_locator(root, value)
        project[key] <- list(value)
      }
      if (identical(project, state$project)) return(invisible(NULL))
      proposed <- .copy(state); proposed$project <- project
      .validate(proposed)
      state <<- .index_state(proposed)
      event("set_context"); invisible(NULL)
    }
    update_record <- function(ref, changes, reason) {
      rec <- .record(state, ref)
      if (rec$kind == "design") .fail("Use set_design to revise design")
      allowed <- c("name", "status", "details", "method", "params", "inputs", "code", "foreign_refs", "path", "design_ref", "input_mode", "analysis")
      if (!is.character(reason) || !nzchar(reason)) .fail("Reason required")
      if (!.is_obj(changes) || !length(changes) || !all(names(changes) %in% allowed)) .fail("Unsupported record correction")
      new <- .copy(rec); new$revision <- state$records[[get(rec$id, attr(state, "record_index")$latest)]]$revision + 1L
      if (rec$kind == "data" && !is.null(rec$scope) && identical(rec$scope$membership_evidence$status, "verification_recorded") && ("path" %in% names(changes) || "details" %in% names(changes))) .fail("MEMBERSHIP_EVIDENCE: revise scope before changing bound file or membership")
      if (any(c("preservation", "artifact_role") %in% names(changes$details))) .fail("Reserved preservation metadata")
      if (!is.null(rec$preservation) && "path" %in% names(changes)) .fail("Use save_figure for preserved bytes")
      if (any(c("design_ref", "input_mode") %in% names(changes)) && !rec$kind %in% c("analysis", "figure")) .fail("Use set_data_scope for DATA design")
      if ("analysis" %in% names(changes) && any(c("inputs", "code", "method", "params", "design_ref", "input_mode") %in% names(changes))) .fail("Do not override inherited analysis context")
      if (rec$kind == "figure" && !is.null(rec$analysis) && any(c("inputs", "code", "method", "params", "design_ref", "input_mode") %in% names(changes))) .fail("Linked figure inherits analysis context")
      if ("design_ref" %in% names(changes)) new["design"] <- list(select_design(changes$design_ref))
      if ("analysis" %in% names(changes)) {
        if (rec$kind != "figure" || is.null(changes$analysis)) .fail("Exact figure analysis required")
        new$analysis <- .ref(state, changes$analysis); new$design <- NULL; new$input_mode <- NULL
        new["inputs"] <- list(NULL); new$code <- list(); new["method"] <- list(NULL); new["params"] <- list(NULL)
      }
      if (!is.null(changes$path)) {
        if (!rec$kind %in% c("data", "figure")) .fail("Path correction needs file record")
        loc <- .locator(root, changes$path); file <- .resolve(root, state, loc)
        if (is.null(file) || !file.exists(file) || dir.exists(file)) .fail("New revision file missing")
        new$locator <- loc; new$sha256 <- .hash(file); new$size <- as.numeric(file.info(file)$size)
      }
      new$created_at <- .now()
      for (key in setdiff(names(changes), c("path", "design_ref", "analysis"))) new[key] <- list(.copy(changes[[key]]))
      out <- append_record(new, "update_record", context_check = any(c("inputs", "design_ref", "input_mode", "analysis") %in% names(changes)), version = if (any(c("design_ref", "input_mode", "analysis") %in% names(changes))) "0.4.0" else NULL); state$history[[length(state$history)]]$reason <<- reason; out
    }
    record_decision <- function(text, reason, targets = list()) {
      if (!nzchar(text) || !nzchar(reason)) .fail("Decision text and reason required")
      targets <- .arr(lapply(targets, function(x) .ref(state, x)))
      rec <- .new_record(state, "decision", text, details = .obj(text = text, reason = reason, targets = targets, provenance = .obj(file = "unknown", analytical = "declared")))
      out <- append_record(rec, "record_decision"); state$history[[length(state$history)]]$reason <<- reason; out
    }
    rebind_external <- function(ref, path, reason) {
      rec <- .record(state, ref)
      if (is.null(rec$locator) || rec$locator$kind == "project") .fail("Reference is not external")
      if (!is.character(reason) || !nzchar(reason)) .fail("Rebind reason required")
      if (!file.exists(path) || dir.exists(path)) .fail("Rebinding requires an existing file")
      if (!is.null(rec$sha256) && .hash(path) != rec$sha256) .fail("Rebinding digest mismatch")
      key <- paste0(rec$locator$kind, ":", rec$locator$value)
      state$bindings[[key]] <<- normalizePath(path, mustWork = TRUE)
      event("rebind_external", reason, .ref(state, ref)); invisible(NULL)
    }
    check <- function(hashes = FALSE) {
      issues <- list()
      for (rec in state$records) {
        if (!is.null(rec$locator)) {
          p <- .resolve(root, state, rec$locator); status <- if (is.null(p) || !file.exists(p)) "missing" else if (hashes && !is.null(rec$sha256) && .hash(p) != rec$sha256) "stale" else if (is.null(rec$sha256)) "unknown" else "ok"
          issues[[length(issues) + 1L]] <- .obj(ref = .make_ref(state, rec), status = status, path = p)
        }
        for (entry in rec$code) {
          key <- paste0(entry$locator$kind, ":", entry$locator$value)
          p <- if (!is.null(state$bindings[[key]])) .resolve(root, state, entry$locator) else if (!is.null(entry$snapshot)) .resolve(root, state, .obj(kind = "project", value = entry$snapshot)) else .resolve(root, state, entry$locator)
          status <- if (is.null(p) || !file.exists(p)) "missing" else if (hashes && !is.null(entry$sha256) && .hash(p) != entry$sha256) "stale" else if (is.null(entry$sha256)) "unknown" else "ok"
          issues[[length(issues) + 1L]] <- .obj(ref = .make_ref(state, rec), status = status, path = p, role = "code")
        }
      }
      issues
    }
    summary <- function() {
      .obj(state_revision = state$state_revision, unsaved = dirty, records = length(state$records), current = .copy(state$current),
           next_task = state$project$next_task, design = get_design(), counts = .copy(attr(state, "record_index")$summary$counts))
    }
    get_design_summary <- function() {
      design <- get_design(); if (is.null(design)) return(NULL)
      truncated <- FALSE
      clip <- function(x) {if (is.null(x)) return(NULL); if (nchar(x, type = "chars") > 64L) {truncated <<- TRUE; substr(x, 1L, 64L)} else x}
      selected <- unlist(design$selected_levels, use.names = FALSE)
      if (length(selected) > 5L) truncated <- TRUE
      selected <- vapply(head(selected, 5L), clip, character(1))
      .obj(condition = clip(design$condition), selected_levels = .arr(selected), reference_level = clip(design$reference_level), replicate = clip(design$replicate), revision = design$ref$revision, truncated = truncated)
    }
    summary_text <- function(purpose = NULL) {
      clip <- function(x) {
        if (is.null(x)) return("unknown")
        if (is.list(x)) x <- unlist(x, use.names = FALSE)
        if (length(x) != 1L) x <- if (!length(x)) "none" else paste0(paste(head(x, 8L), collapse = ", "), if (length(x) > 8L) ", ..." else "")
        x <- gsub("[\r\n\t]", " ", as.character(x))
        if (nchar(x, type = "chars") > 160L) paste0(substr(x, 1L, 160L), "...") else x
      }
      d <- if (is.null(purpose)) get_design() else {ref <- state$current[[purpose]]; if (is.null(ref)) NULL else {rec <- .record(state, ref); if (is.null(rec$design)) NULL else get_design(rec$design)}}; counts <- summary()$counts
      lines <- c(paste0("BioDataLedger: ", clip(state$project$name)), "Purpose:", paste0("  ", clip(state$project$purpose)), "Experimental design:")
      if (is.null(d)) lines <- c(lines, "  not configured") else {
        levels <- unlist(d$levels, use.names = FALSE); selected <- unlist(d$selected_levels, use.names = FALSE)
        excluded <- levels[!levels %in% selected]
        values <- list(Condition = d$condition, Levels = levels, `Selected levels` = selected, Reference = d$reference_level, Replicate = d$replicate, Excluded = excluded, Reason = d$selection_reason, `Design revision` = d$ref$revision)
        lines <- c(lines, vapply(names(values), function(label) paste0("  ", sprintf("%-18s", paste0(label, ":")), clip(values[[label]])), character(1)))
      }
      if (!is.null(purpose)) {
        ref <- state$current[[purpose]]
        lines <- c(lines, paste0("Selected purpose: ", clip(purpose)))
        if (is.null(ref)) lines <- c(lines, "  no selected dataset") else {
          rec <- .record(state, ref); scope <- rec$scope
          lines <- c(lines, paste0("  Dataset: ", .ref_text(ref)),
                     paste0("  Scope basis: ", if (is.null(scope)) "unknown" else scope$evidence$basis),
                     paste0("  Condition values: ", if (is.null(scope)) "unknown" else clip(scope$condition_values)),
                     paste0("  Observation unit: ", if (is.null(scope)) "unknown" else clip(scope$observation_unit)),
                     paste0("  Assignment inclusion: ", if (is.null(scope)) "unknown" else clip(scope$assignment_inclusion)),
                     paste0("  Membership evidence: ", if (is.null(scope)) "unknown" else scope$membership_evidence$status),
                     "  File integrity: not checked")
        }
      }
      paste(c(lines, "Project:", sprintf("  Data:             %d registered datasets", counts$data), sprintf("  Analyses:         %d", counts$analysis), sprintf("  Figures:          %d", counts$figure)), collapse = "\n")
    }
    status <- function(compact = TRUE, purpose = NULL, check_files = FALSE) {
      if (!is.null(purpose) && !.design_text(purpose)) .fail("Invalid purpose")
      if (!is.logical(check_files) || length(check_files) != 1L || is.na(check_files)) .fail("Invalid check_files")
      if (!identical(compact, TRUE)) .fail("Only compact status is supported")
      clipped <- FALSE
      clip <- function(x, limit) {
        if (is.null(x)) return(NULL)
        if (nchar(x, type = "chars") <= limit) return(x)
        clipped <<- TRUE
        substr(x, 1L, limit)
      }
      safe_ref <- function(ref) {
        if (nchar(ref$id, type = "chars") <= 64L) return(.copy(ref))
        clipped <<- TRUE
        NULL
      }
      purposes <- if (is.null(purpose)) attr(state, "record_index")$summary$purposes else if (is.null(state$current[[purpose]])) character() else purpose
      current <- lapply(head(purposes, 5L), function(purpose) .obj(purpose = clip(purpose, 64L), ref = safe_ref(state$current[[purpose]])))
      candidates <- list(); seen <- character()
      add <- function(loc, ref, role, snapshot = NULL) {
        key <- paste0(loc$kind, ":", loc$value)
        if (key %in% seen) return(invisible(NULL))
        seen <<- c(seen, key)
        candidates[[length(candidates) + 1L]] <<- .obj(locator = loc, ref = ref, role = role, snapshot = snapshot)
      }
      latest <- if (check_files) lapply(ls(attr(state, "record_index")$latest), function(id) state$records[[get(id, attr(state, "record_index")$latest)]]) else list()
      records_to_check <- if (check_files) c(lapply(purposes, function(purpose) .record(state, state$current[[purpose]])), latest) else list()
      for (rec in records_to_check) {
        ref <- .make_ref(state, rec)
        if (!is.null(rec$locator)) add(rec$locator, ref, "file")
        for (entry in rec$code) {
          loc <- if (is.null(entry$snapshot)) entry$locator else .obj(kind = "project", value = entry$snapshot)
          add(loc, ref, "code")
        }
      }
      checked <- if (check_files) min(length(candidates), 100L) else 0L; found <- 0L; items <- list()
      if (checked) for (candidate in candidates[seq_len(checked)]) {
        loc <- candidate$locator; key <- paste0(loc$kind, ":", loc$value)
        bound <- !is.null(state$bindings[[key]])
        resolved <- if (bound) .resolve(root, state, loc) else if (!is.null(candidate$snapshot)) .resolve(root, state, .obj(kind = "project", value = candidate$snapshot)) else .resolve(root, state, loc)
        reason <- if (!bound && is.null(candidate$snapshot) && (identical(loc$kind, "uri") || (identical(loc$kind, "external") && isTRUE(state$imported)))) "unresolved" else if (is.null(resolved) || !file.exists(resolved)) "missing" else NULL
        if (!is.null(reason)) {
          found <- found + 1L
          if (length(items) < 5L) items[[length(items) + 1L]] <- .obj(ref = safe_ref(candidate$ref), role = candidate$role, reason = reason)
        }
      }
      dataset <- NULL; dataset_omitted <- FALSE
      if (!is.null(purpose) && length(purposes)) {
        rec <- .record(state, state$current[[purpose]])
        scope <- rec$scope
        short_values <- function(values) {
          if (is.null(values)) return(NULL)
          if (length(values) > 5L) clipped <<- TRUE
          .arr(lapply(head(values, 5L), function(value) clip(value, 64L)))
        }
        short_scope <- if (is.null(scope)) NULL else .obj(
          condition_values = short_values(scope$condition_values),
          assignment_inclusion = short_values(scope$assignment_inclusion),
          observation_unit = clip(scope$observation_unit, 64L), assay = clip(scope$assay, 64L), layer = clip(scope$layer, 64L),
          evidence = scope$evidence$basis, membership_evidence = scope$membership_evidence$status)
        des <- if (is.null(rec$design)) NULL else get_design(rec$design)
        short_design <- if (is.null(des)) NULL else {
          selected <- des$selected_levels
          design_values <- c(des$condition, des$reference_level, des$replicate, unlist(head(selected, 5L), use.names = FALSE))
          design_truncated <- length(selected) > 5L || any(nchar(design_values, type = "chars") > 64L)
          if (design_truncated) clipped <- TRUE
          .obj(condition = clip(des$condition, 64L), selected_levels = short_values(selected),
               reference_level = clip(des$reference_level, 64L), replicate = clip(des$replicate, 64L),
               revision = des$ref$revision, truncated = design_truncated)
        }
        if (nchar(rec$id, type = "chars") > 64L || !is.null(rec$design) && nchar(rec$design$id, type = "chars") > 64L) {
          dataset_omitted <- TRUE; clipped <- TRUE
        } else dataset <- .obj(ref = .make_ref(state, rec), design_ref = .copy(rec$design), design = short_design,
                             scope = short_scope, file_integrity = "not_checked")
      }
      result <- .obj(project = .obj(id = state$project$id, name = clip(state$project$name, 80L)), registry_revision = state$state_revision,
                     current = .arr(current), active_question = NULL, next_task = clip(state$project$next_task, 160L),
                     missing = .obj(checked = checked, unchecked = if (check_files) length(candidates) - checked else NULL, found = if (check_files) found else NULL, items = .arr(items)),
                     availability_checked = check_files, counts = .copy(attr(state, "record_index")$summary$counts), unsaved = dirty, truncated = .obj(current = max(0L, length(purposes) - 5L), missing = found - length(items), text = clipped))
      if (!is.null(purpose)) {result$purpose <- clip(purpose, 64L); result["dataset"] <- list(dataset); result$truncated$current <- 0L; if (dataset_omitted) result$truncated$dataset <- TRUE; result$truncated$text <- clipped}
      while (nchar(.json(result), type = "bytes") > 4096L) {
        if (length(result$current)) {
          result$current[[length(result$current)]] <- NULL
          result$truncated$current <- result$truncated$current + 1L
        } else if (length(result$missing$items)) {
          result$missing$items[[length(result$missing$items)]] <- NULL
          result$truncated$missing <- result$truncated$missing + 1L
        } else if (!is.null(result$dataset)) {result$dataset <- NULL; result$truncated$dataset <- TRUE}
        else .fail("Status exceeds byte limit")
      }
      result
    }
    get_raw_dir <- function() .resolve(root, state, state$project$raw_dir)
    get_metadata_path <- function() .resolve(root, state, state$project$metadata)
    get_output_dir <- function(kind) file.path(root, "results", kind)
    self <- list(check_context = check_context, resolve_figure = resolve_figure, save_figure = save_figure, register_data = register_data, set_data_scope = set_data_scope, resolve_data = resolve_data, register_analysis = register_analysis, register_figure = register_figure, get_data = get_data, get_analysis = get_analysis, get_figure = get_figure, get_design = get_design, get_condition = get_condition, get_levels = get_levels, get_selected_levels = get_selected_levels, get_reference_level = get_reference_level, get_replicate = get_replicate, set_design = set_design, check_design_metadata = check_design_metadata, get_design_summary = get_design_summary, summary_text = summary_text, find_figures = find_figures, save = save, set_current = set_current, set_context = set_context, update_record = update_record, record_decision = record_decision, rebind_external = rebind_external, check = check, summary = summary, status = status, get_raw_dir = get_raw_dir, get_metadata_path = get_metadata_path, get_output_dir = get_output_dir)
    self$preview_export <- function(mode, include = list(), exclude = NULL, redact = NULL) .preview_export(root, state, dirty, mode, include, exclude, redact)
    self$export_zip <- function(plan, path) .export_zip(root, state, dirty, plan, path)
    class(self) <- "ProjectBundle"; self
  }
  import_zip <- function(path, project_dir) .import_zip(path, project_dir, open)
  list(create = create, open = open, import_zip = import_zip)
})
print.ProjectBundle <- function(x, ...) {cat(x$summary_text(), "\n", sep = ""); invisible(x)}
.plan_digest <- function(plan) .hash_raw(charToRaw(.json(plan)))
.hash_raw <- function(bytes) digest::digest(bytes, algo = "sha256", serialize = FALSE)
.payload_source <- function(root, state, loc) .resolve(root, state, loc)
.preview_export <- function(root, state, dirty, mode, include, exclude, redact) {
  if (dirty) .fail("Save before preview")
  if (!mode %in% c("context", "working")) .fail("Invalid archive mode")
  if (mode == "context" && length(include)) .fail("Context archive cannot include payload")
  if (!is.null(exclude) || !is.null(redact)) .fail("Redaction and exclusion are not implemented")
  selected <- lapply(include, function(x) .record(state, x))
  payload <- list(); bindings <- .obj(); missing <- list(); omitted <- list()
  add <- function(loc, role) {
    if (is.null(loc)) return()
    key <- paste0(loc$kind, ":", loc$value); if (!is.null(bindings[[key]])) return()
    source <- .payload_source(root, state, loc)
    if (is.null(source) || !file.exists(source) || dir.exists(source)) .fail(paste("Selected payload missing:", key))
    base <- basename(source); safe <- gsub("[^A-Za-z0-9._-]", "_", base)
    out <- if (startsWith(loc$value, ".nb_project_bundle/code/")) loc$value else sprintf("payload/%05d-%s", length(payload) + 1L, safe)
    payload[[length(payload) + 1L]] <<- .obj(source_locator = loc, source = source, path = out, size = as.numeric(file.info(source)$size), sha256 = .hash(source), role = role)
    bindings[[key]] <<- out
  }
  if (mode == "working") for (rec in selected) {
    if (rec$kind %in% c("data", "figure")) {
      if (!is.null(rec$sha256)) {
        source <- .payload_source(root, state, rec$locator)
        if (is.null(source) || !file.exists(source) || .hash(source) != rec$sha256) .fail("Selected record digest is stale")
      }
      add(rec$locator, rec$kind)
    }
    a <- if (rec$kind == "figure" && !is.null(rec$analysis)) .record(state, rec$analysis) else rec
    if (a$kind %in% c("figure", "analysis")) for (entry in a$code) {
      if (is.null(entry$snapshot)) {omitted[[length(omitted) + 1L]] <- paste0("Unsnapshotted code: ", entry$locator$value); next}
      snapshot_loc <- .obj(kind = "project", value = entry$snapshot)
      snapshot <- .resolve(root, state, snapshot_loc)
      if (is.null(snapshot) || !file.exists(snapshot) || .hash(snapshot) != entry$sha256) .fail("Selected code snapshot missing or stale")
      add(snapshot_loc, "code")
      bindings[[paste0(entry$locator$kind, ":", entry$locator$value)]] <- entry$snapshot
    }
  }
  payload <- payload[order(vapply(payload, function(x) paste0(x$source_locator$kind, ":", x$source_locator$value), character(1)))]
  for (i in seq_along(payload)) if (!startsWith(payload[[i]]$path, ".nb_project_bundle/code/")) {
    old <- payload[[i]]$path
    payload[[i]]$path <- sprintf("payload/%05d-%s", i, gsub("[^A-Za-z0-9._-]", "_", basename(payload[[i]]$source)))
    for (key in names(bindings)) if (identical(bindings[[key]], old)) bindings[[key]] <- payload[[i]]$path
  }
  for (rec in state$records) if (!is.null(rec$locator)) {
    key <- paste0(rec$locator$kind, ":", rec$locator$value)
    if (is.null(bindings[[key]])) {
      omitted[[length(omitted) + 1L]] <- key
      p <- .payload_source(root, state, rec$locator)
      if (is.null(p) || !file.exists(p)) missing[[length(missing) + 1L]] <- key
    }
  }
  state_text <- .json(state)
  figures <- Filter(function(r) r$kind == "figure", state$records)
  figure_lines <- vapply(figures, function(r) paste0("- ", r$id, "@", r$revision, " ", r$name, " | analysis: ", if (is.null(r$analysis)) "unknown" else paste0(r$analysis$id, "@", r$analysis$revision)), character(1))
  current_lines <- if (length(state$current)) vapply(names(state$current), function(k) paste0("- ", k, ": ", state$current[[k]]$id, "@", state$current[[k]]$revision), character(1)) else "- none"
  overview <- paste(c(paste0("# ", state$project$name), paste0("Project ID: ", state$project$id), paste0("State revision: ", state$state_revision), paste0("Next task: ", if (is.null(state$project$next_task)) "unknown" else state$project$next_task), "Current:", current_lines, "Figures:", if (length(figure_lines)) figure_lines else "- none"), collapse = "\n")
  dependencies <- .json(.obj(missing = .arr(missing), omitted = .arr(omitted)))
  metadata <- list(.obj(path = ".nb_project_bundle/project.json", content = state_text, role = "state"), .obj(path = "OVERVIEW.md", content = overview, role = "overview"), .obj(path = "DEPENDENCIES.json", content = dependencies, role = "dependencies"))
  files <- c(lapply(metadata, function(x) .obj(path = x$path, size = nchar(x$content, type = "bytes"), sha256 = .hash_raw(charToRaw(x$content)), role = x$role)), lapply(payload, function(x) .obj(path = x$path, size = x$size, sha256 = x$sha256, role = x$role)))
  plan <- .obj(mode = mode, project_id = state$project$id, state_revision = state$state_revision, source_digest = .hash(file.path(root, ".nb_project_bundle", "project.json")), files = .arr(files), bindings = bindings, omitted = .arr(omitted), missing = .arr(missing), metadata = .arr(metadata), payload = .arr(payload), state = .copy(state))
  plan$plan_digest <- .plan_digest(plan)
  plan
}
.validate_zip <- function(path, manifest = NULL) {
  entries <- zip::zip_list(path)
  required_columns <- c("filename", "type", "encryption", "compressed_size", "uncompressed_size")
  if (!is.data.frame(entries) || !all(required_columns %in% names(entries))) .fail("ZIP metadata lacks required safety fields; use a supported zip package")

  if (nrow(entries) > 10000) .fail("ZIP entry count limit exceeded")
  names <- entries$filename
  if (any(!vapply(names, .safe_rel, logical(1)))) .fail("Unsafe ZIP entry name")
  if (any(entries$type != "file") || any(entries$encryption != "none")) .fail("ZIP entries must be unencrypted regular files")
  if (any(entries$uncompressed_size > 107374182400) || sum(entries$uncompressed_size) > 107374182400) .fail("ZIP expanded size limit exceeded")
  if (any(entries$compressed_size == 0 & entries$uncompressed_size > 0) || any(entries$uncompressed_size / pmax(1, entries$compressed_size) > 1000)) .fail("ZIP ratio limit exceeded")
  canonical <- stringi::stri_trans_nfc(enc2utf8(names))
  normalized <- tolower(canonical); if (anyDuplicated(normalized)) .fail("ZIP case collision")
  ancestors <- new.env(parent = emptyenv())
  for (entry in canonical) {
    parts <- strsplit(entry, "/", fixed = TRUE)[[1]]
    if (length(parts) > 1L) for (i in seq_len(length(parts) - 1L)) {
      original <- paste(parts[seq_len(i)], collapse = "/")
      key <- tolower(original)
      if (exists(key, envir = ancestors, inherits = FALSE) && !identical(get(key, envir = ancestors), original)) .fail("ZIP ancestor case collision")
      assign(key, original, envir = ancestors)
    }
  }
  for (n in normalized) {
    parts <- strsplit(n, "/", fixed = TRUE)[[1]]
    if (length(parts) > 1) for (i in seq_len(length(parts) - 1L)) if (paste(parts[seq_len(i)], collapse = "/") %in% normalized) .fail("ZIP file-parent collision")
  }
  if (!"manifest.json" %in% names) .fail("ZIP manifest missing")
  if (!".nb_project_bundle/project.json" %in% names || entries$uncompressed_size[match("manifest.json", names)] > 20971520 || entries$uncompressed_size[match(".nb_project_bundle/project.json", names)] > 20971520) .fail("ZIP metadata size limit exceeded")
  if (!is.null(manifest)) {
    required <- c(".nb_project_bundle/project.json", "OVERVIEW.md", "DEPENDENCIES.json", "manifest.json")
    if (!all(required %in% names) || !manifest$mode %in% c("context", "working") || !.is_uuid(manifest$export_id) || !.is_arr(manifest$files) || !.is_obj(manifest$bindings)) .fail("Invalid manifest mode or metadata")
    paths <- vapply(manifest$files, function(x) {
      if (!.is_obj(x) || !setequal(names(x), c("path", "size", "sha256", "role")) || !.safe_rel(x$path) || !.is_int(x$size) || x$size < 0 || !.is_sha(x$sha256) || !is.character(x$role) || length(x$role) != 1L) .fail("Invalid manifest file")
      if (x$path == "manifest.json" || !x$path %in% names || entries$uncompressed_size[match(x$path, names)] != x$size) .fail("Invalid manifest size or path")
      x$path
    }, character(1))
    if (anyDuplicated(paths) || !setequal(names, c("manifest.json", paths))) .fail("ZIP entries differ from manifest")
    for (binding in manifest$bindings) if (!.safe_rel(binding) || !binding %in% paths || binding %in% required) .fail("Invalid payload binding")
    if (manifest$mode == "context" && (length(manifest$bindings) || !setequal(names, required))) .fail("Context contains payloads")
  }
  entries
}
.free_bytes <- function(path) {
  output <- suppressWarnings(tryCatch(system2("df", c("-k", shQuote(path)), stdout = TRUE, stderr = TRUE), error = function(e) character()))
  if (!length(output)) .fail("Cannot check available disk space")
  fields <- strsplit(trimws(utils::tail(output, 1L)), "[[:space:]]+")[[1]]
  if (length(fields) < 4L || is.na(suppressWarnings(as.numeric(fields[4])))) .fail("Cannot parse available disk space")
  as.numeric(fields[4]) * 1024
}
.require_space <- function(path, bytes) {
  if (.free_bytes(path) < bytes) .fail("Insufficient free disk space")
}
.export_zip <- function(root, state, dirty, plan, path) {
  if (file.info(file.path(root, ".nb_project_bundle", "project.json"))$size > .metadata_limit) .fail("Metadata size limit exceeded")
  if (dirty || !identical(.hash(file.path(root, ".nb_project_bundle", "project.json")), plan$source_digest) || !identical(state$state_revision, plan$state_revision)) .fail("Export plan is stale")
  supplied <- .copy(plan); digest <- supplied$plan_digest; supplied$plan_digest <- NULL
  if (!identical(.plan_digest(supplied), digest)) .fail("Export plan was edited")
  if (file.exists(path)) .fail("Archive output exists")
  .require_space(dirname(path), 2 * sum(vapply(plan$files, function(x) x$size, numeric(1))) + 1048576)
  for (x in plan$payload) if (!file.exists(x$source) || .hash(x$source) != x$sha256) .fail("Export payload changed")
  folder <- tempfile("nb-bundle-"); dir.create(folder)
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  for (x in plan$metadata) {target <- file.path(folder, x$path); dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE); writeBin(charToRaw(x$content), target)}
  for (x in plan$payload) {target <- file.path(folder, x$path); dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE); if (!file.copy(x$source, target)) .fail("Cannot stage payload"); if (.hash(target) != x$sha256) .fail("Payload changed while staging")}
  manifest <- .obj(format = "nb-project-bundle-zip/0.1", export_id = .uuid(), project_id = state$project$id, state_revision = state$state_revision, mode = plan$mode, files = plan$files, bindings = plan$bindings, omitted = plan$omitted, missing = plan$missing)
  manifest_bytes <- charToRaw(.json(manifest)); if (length(manifest_bytes) > .metadata_limit) .fail("Metadata size limit exceeded")
  writeBin(manifest_bytes, file.path(folder, "manifest.json"))
  tmpzip <- tempfile("nb-bundle-", tmpdir = dirname(path), fileext = ".zip")
  on.exit(if (file.exists(tmpzip)) unlink(tmpzip), add = TRUE)
  zip::zipr(tmpzip, files = c(vapply(plan$files, function(x) x$path, character(1)), "manifest.json"), recurse = FALSE, compression_level = 0, include_directories = FALSE, root = folder, mode = "mirror")
  .validate_zip(tmpzip, manifest)
  if (.hash(file.path(root, ".nb_project_bundle", "project.json")) != plan$source_digest) .fail("State changed during export")
  if (!file.link(tmpzip, path)) .fail("Cannot publish ZIP exclusively")
  invisible(path)
}
.import_zip <- function(path, project_dir, open) {
  if (!identical(Sys.info()[["sysname"]], "Darwin")) .fail("Writes currently require macOS")
  if (file.exists(project_dir)) .fail("Import destination exists")
  archive_digest <- .hash(path)
  entries <- .validate_zip(path)
  .require_space(dirname(project_dir), 2 * sum(entries$uncompressed_size) + 1048576)
  stage <- tempfile(paste0(basename(project_dir), "-"), tmpdir = dirname(project_dir)); dir.create(stage)
  on.exit(if (dir.exists(stage)) unlink(stage, recursive = TRUE), add = TRUE)
  zip::unzip(path, files = "manifest.json", exdir = stage)
  manifest <- .read_json(file.path(stage, "manifest.json"))
  if (!identical(manifest$format, "nb-project-bundle-zip/0.1") || !setequal(names(manifest), c("format","export_id","project_id","state_revision","mode","files","bindings","omitted","missing"))) .fail("Invalid manifest")
  .validate_zip(path, manifest)
  listed <- vapply(manifest$files, function(x) x$path, character(1))
  for (binding in manifest$bindings) if (!.safe_rel(binding) || !binding %in% listed) .fail("Unsafe or missing manifest binding")
  zip::unzip(path, files = vapply(manifest$files, function(x) x$path, character(1)), exdir = stage)
  for (entry in manifest$files) {
    target <- file.path(stage, entry$path)
    if (!file.exists(target) || file.info(target)$size != entry$size || .hash(target) != entry$sha256) .fail("ZIP content digest mismatch")
  }
  statefile <- file.path(stage, ".nb_project_bundle", "project.json"); state <- .read_json(statefile); .validate(state)
  if (!identical(state$project$id, manifest$project_id) || !identical(state$state_revision, manifest$state_revision)) .fail("ZIP state identity mismatch")
  state$bindings <- .copy(manifest$bindings); state$imported <- TRUE; state$state_revision <- state$state_revision + 1L; state$last_transaction <- .uuid()
  state$history[[length(state$history) + 1L]] <- .obj(at = .now(), action = "import", actor = "local", reason = NULL, target = NULL, transaction = state$last_transaction)
  .validate(state); bytes <- charToRaw(.json(state)); if (length(bytes) > .metadata_limit) .fail("Metadata size limit exceeded"); writeBin(bytes, statefile)
  if (.hash(path) != archive_digest) .fail("Archive changed during import")
  if (!dir.create(project_dir, showWarnings = FALSE)) .fail("Import destination exists")
  items <- list.files(stage, all.files = TRUE, no.. = TRUE)
  items <- c(setdiff(items, ".nb_project_bundle"), ".nb_project_bundle")
  for (item in items) {
    if (!file.rename(file.path(stage, item), file.path(project_dir, item))) .fail(paste("Import incomplete in", project_dir))
  }
  open(project_dir)
}
