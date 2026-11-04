.obj <- function(...) { x <- list(...); if (!length(x)) names(x) <- character(); x }
.arr <- function(x = list()) unname(as.list(x))
.execution_summary <- function() .obj(execution = "unknown", execution_evidence = "not_captured", missing = list("execution_evidence"))
.provenance_status <- function(rec, field, allowed) {
  provenance <- rec$details$provenance
  value <- if (.is_obj(provenance)) provenance[[field]] else NULL
  if (is.character(value) && length(value) == 1L && !is.na(value) && value %in% allowed) value else "unknown"
}
.analytical_evidence <- function(rec) {
  declared <- identical(.provenance_status(rec, "analytical", c("declared", "unknown")), "declared")
  .obj(input_relationships = if (declared && !is.null(rec$inputs)) "declared" else "unknown",
       code_relationships = if (declared && length(rec$code)) "declared" else "unknown",
       execution = "unknown", execution_evidence = "not_captured",
       missing = .arr(c(if (is.null(rec$inputs)) "inputs", if (is.null(rec$method)) "method",
                        if (is.null(rec$params)) "params", if (!length(rec$code)) "code",
                        if (!declared) "analytical_provenance", "execution_evidence")))
}
.uuid <- function() as.character(uuid::UUIDgenerate())
.now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
.fail <- function(message) stop(message, call. = FALSE)
.copy <- function(x) unserialize(serialize(x, NULL))
.json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
.json_cacheable <- function(x) {
  attributes <- attributes(x)
  if (!is.null(attributes) && !identical(names(attributes), "names")) return(FALSE)
  if (is.list(x)) return(all(vapply(x, .json_cacheable, logical(1))))
  is.null(x) || typeof(x) %in% c("logical", "integer", "double", "character")
}
.json_save <- function(state, previous = NULL, cache = NULL) {
  if (!is.null(attributes(state$records)) || !is.null(attributes(state$history))) return(list(text = .json(state), cache = NULL))
  encode <- function(values, old, fragments) {
    text <- saved <- vector("list", length(values))
    for (i in seq_along(values)) {
      if (i <= length(fragments) && !is.null(fragments[[i]]) &&
          identical(values[[i]], old[[i]], num.eq = FALSE, single.NA = FALSE, attrib.as.set = FALSE)) {
        text[[i]] <- fragments[[i]]; saved[[i]] <- fragments[[i]]
      } else {
        text[[i]] <- .json(values[[i]])
        # Reference objects and class-specific serializers must run afresh.
        if (.json_cacheable(values[[i]])) saved[[i]] <- text[[i]]
      }
    }
    verbatim <- lapply(text, function(x) structure(x, class = "json"))
    list(text = as.character(jsonlite::toJSON(verbatim, auto_unbox = TRUE, json_verbatim = TRUE)), cache = saved)
  }
  records <- encode(state$records, previous$records, cache$records)
  history <- encode(state$history, previous$history, cache$history)
  parts <- lapply(names(state), function(name) {
    text <- if (name == "records") records$text else if (name == "history") history$text else .json(state[[name]])
    structure(text, class = "json")
  })
  names(parts) <- names(state)
  list(text = as.character(jsonlite::toJSON(parts, auto_unbox = TRUE, json_verbatim = TRUE)),
       cache = list(records = records$cache, history = history$cache))
}
.metadata_limit <- 20971520
.scientific_decision_key <- "scientific_decision"
.analysis_protocol_key <- "analysis_protocol"
.scientific_decision_version <- "biodataledger-scientific-decision/1"
.scientific_statuses <- c("proposed", "provisional", "approved", "superseded")
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
  invisible(state)
}
.record_kind <- function(state, ref) .record(state, ref)$kind
.scientific_refs <- function(state, values, field) {
  if (!.is_arr(values) || length(values) > 100L) .fail(paste0(field, " must be an array of at most 100 references"))
  .arr(lapply(values, function(value) .make_ref(state, .record(state, value))))
}
.scientific_descriptor <- function(state, subjects, scientific_status, supporting = list(), contradictory = list()) {
  if (!is.list(subjects) || !is.null(names(subjects)) || !length(subjects) || length(subjects) > 100L) .fail("Subjects must be a nonempty array of at most 100 items")
  if (!is.character(scientific_status) || length(scientific_status) != 1L || !scientific_status %in% .scientific_statuses) .fail("Invalid scientific_status")
  seen <- character(); normalized <- lapply(subjects, function(subject) {
    if (!.is_obj(subject) || !identical(sort(names(subject)), sort(c("ref", intersect(c("cluster_id", "annotation"), names(subject))))) || is.null(subject$ref)) .fail("Invalid scientific decision subject")
    rec <- .record(state, subject$ref); item <- .obj(ref = .make_ref(state, rec))
    for (field in c("cluster_id", "annotation")) if (field %in% names(subject)) {
      value <- subject[[field]]
      if (!is.character(value) || length(value) != 1L || !nzchar(value)) .fail(paste0("Invalid ", field))
      item[[field]] <- value
    }
    if (!is.null(item$cluster_id) && !rec$kind %in% c("data", "analysis")) .fail("cluster_id requires DATA or ANA subject")
    identity <- paste(item$ref$id, item$ref$revision, if (is.null(item$cluster_id)) "" else item$cluster_id, sep = "\r")
    if (identity %in% seen) .fail("Duplicate scientific decision subject")
    seen <<- c(seen, identity); item
  })
  .obj(version = .scientific_decision_version, subjects = .arr(normalized), scientific_status = scientific_status,
       supporting = .scientific_refs(state, supporting, "supporting"), contradictory = .scientific_refs(state, contradictory, "contradictory"))
}
.read_scientific_descriptor <- function(state, value) {
  if (is.null(value)) return(list(scientific = NULL, issue = "legacy_untyped_decision"))
  if (!.is_obj(value) || !identical(value$version, .scientific_decision_version)) return(list(scientific = NULL, issue = "unsupported_scientific_decision"))
  result <- tryCatch({
    if (!setequal(names(value), c("version", "subjects", "scientific_status", "supporting", "contradictory"))) .fail("descriptor fields")
    normalized <- .scientific_descriptor(state, value$subjects, value$scientific_status, value$supporting, value$contradictory)
    if (!.result_equal(normalized, value)) .fail("descriptor is not canonical")
    list(scientific = .copy(normalized), issue = NULL)
  }, error = function(e) list(scientific = NULL, issue = "malformed_scientific_decision"))
  result
}
.scientific_decision_for_record <- function(state, rec) {
  if (any(.comparison_keys %in% names(rec$details))) return(list(scientific = NULL, issue = "comparison_not_scientific_decision"))
  if (.analysis_protocol_key %in% names(rec$details)) return(list(scientific = NULL, issue = "protocol_is_not_scientific_decision"))
  parsed <- .read_scientific_descriptor(state, rec$details[[.scientific_decision_key]])
  if (is.null(parsed$scientific)) return(parsed)
  result <- tryCatch({
    if (!.design_text(rec$details$reason)) .fail("Decision rationale missing")
    targets <- .scientific_refs(state, rec$details$targets, "targets")
    if (!.result_equal(targets, rec$details$targets)) .fail("Decision targets are not canonical")
    expected <- .arr(lapply(parsed$scientific$subjects, function(x) x$ref))
    if (!.result_equal(targets, expected)) .fail("Decision targets do not bind subjects")
    if ("text" %in% names(rec$details) && (!is.character(rec$details$text) || length(rec$details$text) != 1L || !identical(rec$details$text, rec$name))) .fail("Decision text alias does not bind name")
    parsed
  }, error = function(e) list(scientific = NULL, issue = "malformed_scientific_decision"))
  result
}
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
    state <- .validate(.read_json(path))
    result_graph <- .result_graph(state)
    loaded_digest <- .hash(path); loaded_revision <- state$state_revision
    pending_code <- list(); dirty <- FALSE
    serialization_state <- NULL; serialization_cache <- NULL
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
      if (rec$kind == "figure" && .sources_known(rec$details[[.figure_sources_key]])) .sources_normalize(state, rec$details[[.figure_sources_key]])
      if (context_check && rec$kind %in% c("analysis", "figure") && identical(context_report(rec)$status, "inconsistent")) .fail(paste0("SCOPE_CONFLICT: ", paste(unlist(context_report(rec)$issues), collapse = "; ")))
      state$schema_version <<- proposed$schema_version
      state$records[[length(state$records) + 1L]] <<- rec
      state <<- .index_add(state, rec)
      .result_index_record(result_graph,state,rec)
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
      if (.result_key %in% names(list(...))) .fail('Use register_result for result declarations')
      if ("execution_receipt" %in% names(list(...))) .fail("Execution receipt is runner-managed")
      if (.scientific_decision_key %in% names(list(...))) .fail("Scientific decision metadata is reserved")
      if (.analysis_protocol_key %in% names(list(...))) .fail("Analysis protocol metadata is reserved")
      if (any(.comparison_keys %in% names(list(...)))) .fail("Comparison metadata is reserved")
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
      details <- .obj(...)
      if ("execution_receipt" %in% names(details)) .fail("Execution receipt is runner-managed")
      if (.scientific_decision_key %in% names(details)) .fail("Scientific decision metadata is reserved")
      if (.analysis_protocol_key %in% names(details)) .fail("Analysis protocol metadata is reserved")
      if (any(.comparison_keys %in% names(details))) .fail("Comparison metadata is reserved")
      details$provenance <- .obj(file = "unknown", analytical = "declared")
      rec <- .new_record(state, "analysis", name, inputs = inputs, code = entries, method = method, params = params, details = details, design = select_design(design_ref))
      rec["design"] <- list(select_design(design_ref)); rec$input_mode <- input_mode
      append_record(rec, "register_analysis", capture_code(rec), version = "0.4.0")
    }
    figure_record <- function(path, type, analysis = NULL, name = NULL, inputs = NULL, code = NULL, method = NULL, params = NULL, snapshot_code = TRUE, design_ref = state$project$design, input_mode = "separate", figure_sources = NULL, ...) {
      loc <- .locator(root, path); p <- .resolve(root, state, loc)
      if (is.null(p) || dir.exists(p)) .fail("Figure must be a local regular file")
      if (!is.null(analysis)) {
        analysis <- .ref(state, analysis)
        if (.record_kind(state, analysis) != "analysis") .fail("Figure analysis must reference analysis")
        if (!is.null(inputs) || !is.null(code) || !is.null(method) || !is.null(params) || !missing(design_ref) || !missing(input_mode)) .fail("Direct analytical fields conflict with analysis")
      }
      if (!is.null(inputs)) inputs <- .arr(lapply(inputs, function(x) {r <- .ref(state, x); if (.record_kind(state, r) != "data") .fail("Figure inputs must be data"); r}))
      entries <- .code_entries(root, code, snapshot_code)
      details <- .obj(...); if (any(c("preservation", "artifact_role", "execution_receipt", .scientific_decision_key, .analysis_protocol_key, .comparison_keys) %in% names(details))) .fail("Reserved metadata")
      if (!is.null(figure_sources)) details[[.figure_sources_key]] <- .sources_normalize(state, figure_sources)
      details$format <- tolower(tools::file_ext(p))
      details$provenance <- .obj(file = "captured", analytical = if (!is.null(analysis) || length(inputs) || length(entries)) "declared" else "unknown")
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
      if (!is.null(ref)) {rec <- .record(state, ref); if (rec$kind != "data") .fail("Not data"); out <- view(rec, check_files); out["design_ref"] <- list(.copy(rec$design)); out["design"] <- list(if (is.null(rec$design)) NULL else get_design(rec$design)); out["scope"] <- list(.copy(rec$scope)); out["result"] <- list(.result_summary(state,rec)); return(out)}
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
      if (!is.null(rec$details[[.result_key]]) && !.result_valid(state,new)) .fail('Invalid result declaration')
      proposed <- .copy(state); proposed$schema_version <- if (state$schema_version == "0.4.0") "0.4.0" else "0.3.0"
      proposed$records[[length(proposed$records) + 1L]] <- new
      .validate(proposed, record_only = new)
      state <<- .index_state(proposed)
      .result_index_record(result_graph,state,new)
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
    check_object <- function(object, ref = NULL, purpose = NULL, assay = NULL, layer = NULL) {
      if (sum(!vapply(list(ref,purpose),is.null,logical(1)))!=1L) .fail("Choose exactly one ref or purpose")
      if (!is.null(purpose)) {
        if (!.design_text(purpose)) .fail("Invalid purpose")
        ref <- state$current[[purpose]]
        if (is.null(ref)) .fail("No current data for purpose")
      }
      .check_object(root,state,object,.ref(state,ref),assay,layer)
    }
    figure_selector <- function(ref = NULL, asset_id = NULL, path = NULL, revision = NULL) {
      if (sum(!vapply(list(ref,asset_id,path),is.null,logical(1))) != 1L || !is.null(revision) && !.is_int(revision,TRUE)) .fail("Choose one figure selector and valid revision")
      if (!is.null(ref)) {
        if (is.character(ref) && length(ref)==1L && grepl("^FIG-[0-9]{3,}$",ref)) {
          if (!is.null(revision)) return(.record(state,paste0(ref,"@",revision)))
          matches <- Filter(function(x) x$id==ref,state$records)
        } else {
          rec <- .record(state,ref)
          if (rec$kind!="figure" || !is.null(revision) && rec$revision!=revision) .fail("Wrong figure/revision")
          return(rec)
        }
      } else if (!is.null(asset_id)) {
        if (!.design_text(asset_id)) .fail("Invalid asset_id")
        matches <- Filter(function(x) x$kind=="figure" && .sources_known(x$details[[.figure_sources_key]]) && identical(x$details[[.figure_sources_key]]$asset_id,asset_id),state$records)
      } else {
        if (!.design_text(path)) .fail("Invalid figure path")
        matches <- Filter(function(x) x$kind=="figure" && (identical(x$locator$value,path) || x$locator$kind=="project" && identical(file.path(root,x$locator$value),path)),state$records)
      }
      if (!is.null(revision)) matches <- Filter(function(x) x$revision==revision,matches)
      if (length(matches)!=1L) .fail("Missing or ambiguous figure selector; use exact reference")
      matches[[1L]]
    }
    get_figure <- function(ref = NULL, check_files = FALSE, asset_id = NULL, path = NULL, revision = NULL, compact = FALSE) {
      if (!is.logical(check_files) || length(check_files) != 1L || is.na(check_files)) .fail("Invalid check_files")
      if (!is.logical(compact) || length(compact)!=1L || is.na(compact)) .fail("Invalid compact")
      rec <- figure_selector(ref,asset_id,path,revision)
      out <- view(rec, check_files)
      design_ref <- if (is.null(rec$analysis)) rec$design else .record(state, rec$analysis)$design
      out["design_ref"] <- list(.copy(design_ref)); out["design"] <- list(if (is.null(design_ref)) NULL else get_design(design_ref))
      if (!is.null(rec$analysis)) {
        a <- .record(state, rec$analysis)
        out$inputs <- .copy(a$inputs); out$code <- .copy(a$code); out$method <- a$method; out$params <- .copy(a$params)
      }
      out$analysis_details <- if (is.null(rec$analysis)) .copy(rec$details) else .copy(.record(state, rec$analysis)$details)
      if (.is_obj(out$analysis_details$provenance)) out$analysis_details$provenance$file <- NULL # Analysis context is not the figure file.
      analytical_source <- if (is.null(rec$analysis)) rec else .record(state, rec$analysis)
      out["input_mode"] <- list(.copy(analytical_source$input_mode))
      out$provenance <- .obj(figure_file = .provenance_status(rec, "file", c("captured", "unknown")),
                             analytical = .provenance_status(analytical_source, "analytical", c("declared", "unknown")),
                             execution = "unknown")
      out$evidence <- .analytical_evidence(analytical_source)
      out$unknown <- .copy(out$evidence$missing)
      out["input_availability"] <- list(if (is.null(out$inputs)) NULL else .arr(lapply(out$inputs, function(x) .obj(ref = x, available = if (check_files) get_data(ref = x, check_files = TRUE)$available else NULL, availability_checked = check_files))))
      out$code_availability <- .arr(lapply(out$code, function(x) {
        key <- paste0(x$locator$kind, ":", x$locator$value)
        p <- if (!is.null(state$bindings[[key]])) .resolve(root, state, x$locator) else if (!is.null(x$snapshot)) .resolve(root, state, .obj(kind = "project", value = x$snapshot)) else .resolve(root, state, x$locator)
        .obj(reference = x, path = p, available = if (check_files) !is.null(p) && file.exists(p) else NULL, availability_checked = check_files)
      }))
      out$source_code_availability <- .arr(lapply(out$code_availability, function(x) x$available))
      out$figure_sources <- .sources_describe(root,state,rec,check_files,pending_code)
      out["analytical_inputs"] <- list(.copy(out$inputs)); out["rendering_inputs"] <- list(.copy(out$figure_sources$rendering_inputs))
      out$rendering_relationship <- out$figure_sources$relationship
      out["generating_code"] <- list(.copy(out$figure_sources$code)); out$dependencies <- .copy(out$figure_sources$dependency_details)
      out["asset_id"] <- list(out$figure_sources$asset_id)
      if (compact) .sources_compact(out) else out
    }
    read_figure_source <- function(ref = NULL, asset_id = NULL, path = NULL, revision = NULL, code_ref = NULL) {
      rec <- figure_selector(ref,asset_id,path,revision)
      sources <- .sources_describe(root,state,rec,FALSE,pending_code)
      if (length(sources$contradictions)) .fail(paste("Invalid figure_sources",paste(unlist(sources$contradictions),collapse="; ")))
      source <- sources$code
      if (!is.null(code_ref)) {
        selected <- .sources_normalize(state,.obj(generating_code=code_ref))$generating_code
        allowed <- c(sources$code_candidates,if(is.null(source)) list() else list(source))
        matches <- Filter(function(x) .same_exact_ref(state,x$selector$record,selected$record,.record(state,selected$record)$kind) && x$selector$index==selected$index && identical(x$selector$sha256,selected$sha256),allowed)
        if (!length(matches)) .fail("SOURCE_UNKNOWN: code selection does not belong to figure")
        source <- matches[[1L]]
      } else if (is.null(source)) {
        if (length(sources$code_candidates)!=1L) .fail("SOURCE_UNKNOWN: exact code selection required")
        source <- sources$code_candidates[[1L]]
      }
      selector <- source$selector
      if (is.null(selector$sha256)) .fail("SOURCE_DIGEST_UNKNOWN")
      entry <- .record(state,selector$record)$code[[selector$index+1L]]
      snapshot <- entry$snapshot
      bytes <- if(!is.null(snapshot)) pending_code[[snapshot]] else NULL
      if (is.null(bytes)) {
        locator <- if(is.null(snapshot)) entry$locator else .obj(kind="project",value=snapshot)
        file <- .resolve(root,state,locator)
        if (is.null(file) || !file.exists(file) || dir.exists(file)) .fail("SOURCE_MISSING: recorded source unavailable")
        if (file.info(file)$size>1048576) .fail("SOURCE_OVERSIZED: source exceeds 1 MiB")
        bytes <- readBin(file,"raw",n=1048577L)
      }
      if (length(bytes)>1048576) .fail("SOURCE_OVERSIZED: source exceeds 1 MiB")
      if (!identical(.hash_raw(bytes),selector$sha256)) .fail("SOURCE_DIGEST_MISMATCH")
      .obj(content=bytes,sha256=selector$sha256,code_ref=.copy(selector),snapshot=snapshot,integrity="match",execution="unknown",execution_evidence="not_captured")
    }
    get_analysis <- function(ref) {
      rec <- .record(state, ref); if (rec$kind != "analysis") .fail("Not analysis")
      out <- view(rec); out["design_ref"] <- list(.copy(rec$design)); out["design"] <- list(if (is.null(rec$design)) NULL else get_design(rec$design))
      out$evidence <- .analytical_evidence(rec)
      out
    }
    run_analysis <- function(analysis_ref, entry_point, outputs = list(), seeds = NULL,
                             verify_inputs = TRUE, verify_code = TRUE, object_checks = list()) {
      template_ref <- .ref(state, analysis_ref)
      template <- .record(state, template_ref)
      if (template$kind != "analysis" || !is.character(entry_point) || length(entry_point) != 1L ||
          !nzchar(entry_point) || !grepl("^[A-Za-z.][A-Za-z0-9._]*$", entry_point) ||
          !is.logical(verify_inputs) || length(verify_inputs) != 1L || is.na(verify_inputs) ||
          !is.logical(verify_code) || length(verify_code) != 1L || is.na(verify_code) ||
          (!is.null(seeds) && !.is_obj(seeds)) || length(template$code) != 1L ||
          is.null(template$code[[1L]]$snapshot) || !.is_arr(object_checks) || length(object_checks)>100L) .fail("Execution requires one snapshotted code file and valid arguments")
      if (length(template$inputs) > 100L) .fail("Execution supports at most 100 inputs")
      object_checks <- lapply(object_checks, function(spec) {
        if (!.is_obj(spec) || !all(names(spec) %in% c("ref","get_object","assay","layer")) || !all(c("ref","get_object") %in% names(spec)) || !is.function(spec$get_object)) .fail("Invalid object check")
        ref <- .ref(state,spec$ref); if (.record_kind(state,ref)!="data" || !any(vapply(template$inputs,function(x)identical(x,ref),logical(1)))) .fail("Object check ref must be an analysis input")
        spec$ref <- ref; spec
      })
      specs <- .execution_output_specs(outputs, root)
      code <- template$code[[1L]]
      receipt <- .obj(version = .execution_version, status = "started", template_ref = .copy(template_ref),
        run_ref = .obj(project_id = state$project$id, id = .next_id(state, "analysis"), revision = 1L), receipt_ref = NULL, started_at_utc = .now(), ended_at_utc = NULL,
        entry_point = entry_point, language = "r",
        code = .obj(path = code$locator$value, digest = code$sha256,
                    snapshot_digest = code$sha256, snapshot = code$snapshot),
        method = .copy(template$method), params = .copy(template$params), seeds = .copy(seeds),
        inputs = .arr(lapply(template$inputs, function(input_ref) .obj(ref = .copy(input_ref), path = NULL, identity = "unknown", reason = "not_checked"))), outputs = .arr(lapply(specs, .execution_output_view)),
        phases = .obj(execution_started = FALSE, code_executed = FALSE, callback_invoked = FALSE),
        input_checkpoints = .obj(version="biodataledger-input-checkpoints/1",checks=list()),
        input_consumption = "unknown", scientific_validity = "unknown", downstream_consumption = "unknown",
        error = NULL)
      run <- .copy(template); run$id <- receipt$run_ref$id; run$revision <- 1L
      receipt$receipt_ref <- .copy(receipt$run_ref)
      run$name <- paste0(template$name, " execution"); run$created_at <- .now()
      run$details$execution_receipt <- receipt
      run_ref <- append_record(run, "run_analysis_started", context_check = FALSE)
      # The started revision is intentionally durable before any file verification or callback.
      started <- save_and_confirm()
      terminal <- function(status, message = NULL) {
        receipt$status <<- status; receipt$ended_at_utc <<- .now(); receipt["error"] <<- list(message)
        final <- .copy(run); final$revision <- state$records[[get(run$id, attr(state, "record_index")$latest)]]$revision + 1L
        final$created_at <- .now(); receipt$receipt_ref <<- .obj(project_id = state$project$id, id = final$id, revision = final$revision)
        final$details$execution_receipt <- .copy(receipt)
        append_record(final, "run_analysis_terminal", context_check = FALSE)
        persisted <- save_and_confirm()
        returned <- .copy(receipt); returned$persistence <- persisted
        returned
      }
      fail_terminal <- function(status, message) {
        final <- terminal(status, message)
        .execution_stop(message, final)
      }
      checkpoint <- function(phase) {
        files <- lapply(template$inputs, function(input_ref) {
          input <- .record(state, input_ref)
          item <- .obj(ref=.copy(input_ref), path=NULL, identity="unknown", reason="verification_not_requested")
          tryCatch({
            if (!identical(input$status,"active")) .fail("INACTIVE: exact input revision")
            path <- .resolve(root,state,input$locator)
            if (is.null(path) || !file.exists(path) || dir.exists(path)) .fail("local_path_unavailable")
            if (verify_inputs) {
              resolved <- resolve_data(ref=input_ref, verify="sha256")
              path <- resolved$path
              item$identity <- "match"; item$reason <- "sha256_match"
            }
            item$path <- path
            item
          }, error=function(e) {
            item$reason <- .execution_text(e)
            if (grepl("DIGEST_MISMATCH|SIZE_MISMATCH|FILE_CHANGED",item$reason)) item$identity <- "mismatch"
            item
          })
        })
        objects <- lapply(object_checks, function(spec) {
          report <- tryCatch(check_object(spec$get_object(),ref=spec$ref,assay=spec$assay,layer=spec$layer),error=function(e) NULL)
          .obj(ref=.copy(spec$ref),overall=if(is.null(report)) "UNKNOWN" else report$overall,
               blockers=if(is.null(report)) list("object_check_error") else .copy(report$blockers))
        })
        receipt$inputs <<- .arr(files)
        receipt$input_checkpoints$checks[[length(receipt$input_checkpoints$checks)+1L]] <<- .obj(phase=phase,files=.arr(files),objects=.arr(objects))
        if(any(vapply(files,function(x)is.null(x$path) || verify_inputs && !identical(x$identity,"match"),logical(1))) ||
           any(!vapply(objects,function(x)identical(x$overall,"PASS"),logical(1)))) .fail(paste("Input checkpoint failed:",phase))
        files
      }
      checked_inputs <- tryCatch(checkpoint("preflight"),error=function(e)e)
      if(inherits(checked_inputs,"error")) fail_terminal("blocked",.execution_text(checked_inputs))
      snapshot_path <- .resolve(root, state, .obj(kind = "project", value = code$snapshot))
      verification <- tryCatch({
        if (is.null(snapshot_path) || !file.exists(snapshot_path) || dir.exists(snapshot_path) || file.info(snapshot_path)$size > 1048576) .execution_stop("Code snapshot unavailable")
        bytes <- readBin(snapshot_path, "raw", n = 1048577L)
        if (length(bytes) > 1048576 || !identical(.hash_raw(bytes), code$sha256)) .execution_stop("Code snapshot integrity mismatch")
        if (verify_code) {
          current <- .resolve(root, state, code$locator)
          if (is.null(current) || !file.exists(current) || dir.exists(current) || !identical(.hash(current), code$sha256)) .execution_stop("Current code verification failed")
        }
        bytes
      }, BioDataLedgerExecutionError = function(e) e, error = function(e) .execution_error(conditionMessage(e)))
      if (inherits(verification, "BioDataLedgerExecutionError")) fail_terminal("blocked", conditionMessage(verification))
      receipt$phases$execution_started <- TRUE
      result <- tryCatch({
        execution_env <- new.env(parent = globalenv())
        expression <- parse(text = rawToChar(verification), keep.source = FALSE)
        receipt$phases$code_executed <- TRUE
        eval(expression, envir = execution_env)
        checked_inputs <- checkpoint("before_callback")
        callback <- get(entry_point, envir = execution_env, inherits = FALSE)
        if (!is.function(callback)) .fail("Execution entry point is not a function")
        receipt$phases$callback_invoked <- TRUE
        do.call(callback, list(inputs = unname(vapply(checked_inputs, function(x) x$path, character(1))),
                               params = .copy(template$params), seeds = .copy(seeds),
                               outputs = unname(vapply(specs, function(x) x$path, character(1)))))
        checkpoint("after_callback")
        NULL
      }, interrupt = function(e) .execution_error("Execution interrupted"), error = function(e) .execution_error(conditionMessage(e)))
      if (isTRUE(receipt$phases$callback_invoked) && !identical(receipt$input_checkpoints$checks[[length(receipt$input_checkpoints$checks)]]$phase,"after_callback")) {
        postcheck <- tryCatch({checkpoint("after_callback"); NULL}, error=function(e) .execution_error(conditionMessage(e)))
        if (is.null(result) && !is.null(postcheck)) result <- postcheck
      }
      capture_failure <- NULL
      captured <- lapply(seq_along(specs), function(i) {
        spec <- specs[[i]]; item <- .execution_output_view(spec)
        if (!file.exists(spec$path) || dir.exists(spec$path)) {item$status <- "missing"; return(item)}
        digest <- tryCatch(.hash(spec$path), error = function(e) e)
        if (inherits(digest, "error")) {item$status <- "unreadable"; item$error <- .execution_text(digest); return(item)}
        item$digest <- digest; item$status <- "observed"
        registered <- tryCatch(if (identical(spec$kind, "result"))
          register_result(spec$path, run_ref, hash = TRUE) else register_figure(spec$path, type = spec$type, analysis = run_ref),
          error = function(e) e)
        if (inherits(registered, "error")) {item$status <- "registration_failed"; item$error <- .execution_text(registered); capture_failure <<- item$error}
        else if (!identical(tolower(.record(state, registered)$sha256), tolower(digest))) {
          item$status <- "registration_failed"; item$error <- "Registered output digest mismatch"; capture_failure <<- item$error
        } else {item$status <- "registered"; item$record_ref <- registered}
        item
      })
      receipt$outputs <- .arr(captured)
      if (!is.null(result)) fail_terminal("failed", conditionMessage(result))
      if (any(vapply(captured, function(x) !identical(x$status, "registered"), logical(1))))
        fail_terminal("incomplete", if (is.null(capture_failure)) "Declared output missing or unreadable" else capture_failure)
      final <- terminal("succeeded")
      final
    }
    get_execution <- function(ref) {
      rec <- .record(state, ref)
      if (rec$kind != "analysis") .fail("Not analysis")
      receipt <- rec$details$execution_receipt
      if (!.execution_receipt_valid(state, rec, receipt))
        return(.obj(status = "unknown", receipt_ref = .make_ref(state, rec), reason = "absent_or_malformed_execution_receipt"))
      out <- .execution_receipt_view(receipt)
      out$receipt_ref <- .make_ref(state, rec)
      if (isTRUE(state$imported)) out$authenticity <- "untrusted_imported_claim"
      out
    }
    execution_summary <- function(ref) {
      receipt <- get_execution(ref)
      text <- if (identical(receipt$status, "unknown")) "Execution receipt: unknown for this exact analysis revision." else
        {
          inputs <- vapply(receipt$inputs, function(x) identical(x$identity, "match"), logical(1))
          error <- if (is.null(receipt$error)) NULL else .execution_text(receipt$error, 512L)
          paste(c(paste0("Execution ", receipt$status, ": ", .execution_ref_text(receipt$receipt_ref), " (", receipt$entry_point, ")."),
                  paste0("Inputs matched: ", sum(inputs), "/", length(inputs), "; code: ", substr(receipt$code$digest, 1L, 12L), "; callback invoked: ", receipt$phases$callback_invoked, "."),
                  paste0("Outputs captured: ", sum(vapply(receipt$outputs, function(x) identical(x$status, "registered"), logical(1))), "/", length(receipt$outputs), ". Input use/science: unknown."), if (!is.null(error)) paste0("Error: ", error)), collapse = " ")
        }
      .execution_text(text, 4096L)
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
      index <- attr(state, "record_index")$latest
      ids <- sort(ls(index, pattern = "^FIG-"), method = "radix")
      latest <- setNames(lapply(ids, function(id) state$records[[get(id, index, inherits = FALSE)]]), ids)
      latest <- Filter(function(r) identical(r$status, "active"), latest)
      if (!is.null(type)) latest <- Filter(function(r) identical(r$type, type), latest)
      if (!is.null(query) && nzchar(query)) {
        tokens <- strsplit(stringi::stri_trans_casefold(trimws(query)), "[[:space:]]+")[[1]]
        latest <- Filter(function(r) {
          a <- if (is.null(r$analysis)) NULL else .record(state, r$analysis)
          fields <- Filter(function(x) is.character(x) && length(x) == 1L && !is.na(x),
                           list(r$name, r$type, r$details$description, a$name, a$details$description, r$locator$value,
                                if (.sources_known(r$details[[.figure_sources_key]])) r$details[[.figure_sources_key]]$asset_id else NULL))
          hay <- stringi::stri_trans_casefold(paste(unlist(fields, use.names = FALSE), collapse = " "))
          all(vapply(tokens, function(t) grepl(t, hay, fixed = TRUE), logical(1)))
        }, latest)
      }
      lapply(latest, function(r) get_figure(.make_ref(state, r)))
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
      proposed <- state; proposed$state_revision <- state$state_revision + 1L; proposed$last_transaction <- .uuid()
      for (i in seq_along(proposed$history)) if (is.null(proposed$history[[i]]$transaction)) proposed$history[[i]]$transaction <- proposed$last_transaction
      proposed <- .validate(proposed)
      encoded <- .json_save(proposed, serialization_state, serialization_cache)
      serialized <- charToRaw(encoded$text)
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
      state <<- proposed; loaded_digest <<- .hash(path); loaded_revision <<- state$state_revision; pending_code <<- list(); dirty <<- FALSE
      serialization_state <<- list(records = proposed$records, history = proposed$history); serialization_cache <<- encoded$cache
      .obj(state_revision = state$state_revision, transaction = state$last_transaction)
    }
    save_and_confirm <- function() {
      previous <- loaded_revision
      result <- save()
      written <- result$state_revision != previous
      .obj(status = if (written) "persisted" else "no_changes",
           scope = "all_pending_changes", previous_committed_revision = previous,
           committed_revision = result$state_revision,
           transaction_id = result$transaction, registry_written = written)
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
      allowed <- c("name", "status", "details", "method", "params", "inputs", "code", "foreign_refs", "path", "design_ref", "input_mode", "analysis", "figure_sources")
      if (!is.character(reason) || !nzchar(reason)) .fail("Reason required")
      if (!.is_obj(changes) || !length(changes) || !all(names(changes) %in% allowed)) .fail("Unsupported record correction")
      if ("execution_receipt" %in% names(rec$details)) .fail("Execution runs are runner-managed")
      if ("details" %in% names(changes) && "execution_receipt" %in% names(changes$details)) .fail("Execution receipt is runner-managed")
      if ("details" %in% names(changes) && .scientific_decision_key %in% names(changes$details)) .fail("Scientific decision metadata is writer-managed")
      if ("details" %in% names(changes) && .analysis_protocol_key %in% names(changes$details)) .fail("Analysis protocol metadata is writer-managed")
      if ("details" %in% names(changes) && any(.comparison_keys %in% names(changes$details))) .fail("Comparison metadata is writer-managed")
      if (rec$kind == "decision" && .scientific_decision_key %in% names(rec$details) && !identical(names(changes), "status")) .fail("Typed scientific decisions allow lifecycle status correction only")
      if (.analysis_protocol_key %in% names(rec$details)) .fail("Use register_protocol to revise analysis protocols")
      if (any(.comparison_keys %in% names(rec$details))) .fail("Use comparison writers to revise comparison records")
      if (!is.null(rec$details[[.result_key]]) && ('path' %in% names(changes) ||
          'details' %in% names(changes) && (!.result_equal(changes$details[[.result_key]],rec$details[[.result_key]]) ||
          !.result_equal(changes$details$membership,rec$details$membership)))) .fail('Use register_result to revise result identity')
      if (is.null(rec$details[[.result_key]]) && 'details' %in% names(changes) &&
          !is.null(changes$details[[.result_key]])) .fail('Use register_result to declare a result')
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
      for (key in setdiff(names(changes), c("path", "design_ref", "analysis", "figure_sources"))) new[key] <- list(.copy(changes[[key]]))
      if (!is.null(rec$details[[.result_key]]) && !.result_valid(state,new)) .fail('Invalid result declaration')
      if ("figure_sources" %in% names(changes)) {
        if (rec$kind!="figure") .fail("figure_sources requires a figure")
        if (is.null(changes$figure_sources)) new$details[[.figure_sources_key]] <- NULL else new$details[[.figure_sources_key]] <- .sources_normalize(state,changes$figure_sources)
      }
      out <- append_record(new, "update_record", context_check = any(c("inputs", "design_ref", "input_mode", "analysis") %in% names(changes)), version = if (any(c("design_ref", "input_mode", "analysis") %in% names(changes))) "0.4.0" else NULL); state$history[[length(state$history)]]$reason <<- reason; out
    }
    record_decision <- function(text, reason, targets = list()) {
      if (!nzchar(text) || !nzchar(reason)) .fail("Decision text and reason required")
      targets <- .arr(lapply(targets, function(x) .ref(state, x)))
      rec <- .new_record(state, "decision", text, details = .obj(text = text, reason = reason, targets = targets, provenance = .obj(file = "unknown", analytical = "declared")))
      out <- append_record(rec, "record_decision"); state$history[[length(state$history)]]$reason <<- reason; out
    }
    record_scientific_decision <- function(text, reason, subjects, scientific_status, supporting = NULL, contradictory = NULL, ref = NULL) {
      if (!.design_text(text) || !.design_text(reason)) .fail("Decision text and reason required")
      descriptor <- .scientific_descriptor(state, subjects, scientific_status, if (is.null(supporting)) list() else supporting, if (is.null(contradictory)) list() else contradictory)
      if (is.null(ref)) rec <- .new_record(state, "decision", text) else {
        old <- .record(state, ref)
        if (old$kind != "decision") .fail("Not decision")
        latest <- state$records[[get(old$id, attr(state, "record_index")$latest)]]
        if (old$revision != latest$revision) .fail("Scientific decision revision must be current")
        if (.analysis_protocol_key %in% names(old$details) || any(.comparison_keys %in% names(old$details))) .fail("Cannot convert protocol or comparison to scientific decision")
        prior <- .scientific_decision_for_record(state, old)
        if (!is.null(prior$issue) && prior$issue != "legacy_untyped_decision") .fail("Cannot revise unsupported or malformed scientific decision")
        if (!is.null(prior$scientific)) {
          old_ids <- vapply(prior$scientific$subjects, function(x) paste(x$ref$id, x$ref$revision, if (is.null(x$cluster_id)) "" else x$cluster_id, sep = "\r"), character(1))
          new_ids <- vapply(descriptor$subjects, function(x) paste(x$ref$id, x$ref$revision, if (is.null(x$cluster_id)) "" else x$cluster_id, sep = "\r"), character(1))
          if (!identical(old_ids, new_ids)) .fail("Scientific decision subjects are immutable")
        }
        rec <- .copy(old); rec$revision <- old$revision + 1L; rec$created_at <- .now()
      }
      rec$name <- text
      rec$details <- .copy(rec$details); rec$details$reason <- reason; rec$details$text <- text
      rec$details$targets <- .arr(lapply(descriptor$subjects, function(x) .copy(x$ref)))
      rec$details$approval <- "not_authenticated"; rec$details[[.scientific_decision_key]] <- descriptor
      out <- append_record(rec, "record_scientific_decision"); state$history[[length(state$history)]]$reason <<- reason; out
    }
    get_decision <- function(ref) {
      rec <- .record(state, ref); if (rec$kind != "decision") .fail("Not decision")
      if (any(.comparison_keys %in% names(rec$details))) return(.obj(ref = .make_ref(state, rec), text = rec$name, reason = .copy(rec$details$reason),
        targets = list(), record_status = rec$status, scientific = NULL, approval = "not_applicable",
        unknown = .arr(list("comparison_not_scientific_decision")), imported_claim = if (isTRUE(state$imported)) "untrusted_imported_claim" else NULL))
      parsed <- .scientific_decision_for_record(state, rec)
      unknown <- if (is.null(parsed$issue)) list() else list(parsed$issue)
      if (isTRUE(state$imported)) unknown <- c(unknown, list("untrusted_imported_claim"))
      .obj(ref = .make_ref(state, rec), text = rec$name, reason = .copy(rec$details$reason),
           targets = .copy(if (is.null(rec$details$targets)) list() else rec$details$targets), record_status = rec$status,
           scientific = parsed$scientific, approval = if (.analysis_protocol_key %in% names(rec$details)) "not_applicable" else "not_authenticated", unknown = .arr(unknown),
           imported_claim = if (isTRUE(state$imported)) "untrusted_imported_claim" else NULL)
    }
    register_protocol <- function(name, steps, reason, ref = NULL) {
      if (!is.character(name) || length(name) != 1L || !nzchar(name)) .fail("Protocol name required")
      descriptor <- .protocol_descriptor(state, steps, reason)
      if (is.null(ref)) rec <- .new_record(state, "decision", name) else {
        old <- .record(state, ref); latest <- state$records[[get(old$id, attr(state, "record_index")$latest)]]
        if (old$kind != "decision" || old$revision != latest$revision) .fail("Protocol revision must be current")
        if (.scientific_decision_key %in% names(old$details) || any(.comparison_keys %in% names(old$details))) .fail("Cannot convert scientific decision or comparison to analysis protocol")
        prior <- .protocol_read(state, old)
        if (is.null(prior$protocol)) .fail("Cannot revise unsupported or malformed protocol")
        rec <- .copy(old); rec$revision <- old$revision + 1L; rec$created_at <- .now()
      }
      rec$name <- name; rec$details <- .obj(reason = reason, targets = .copy(descriptor$targets), approval = "not_authenticated")
      rec$details[[.analysis_protocol_key]] <- descriptor
      out <- append_record(rec, "register_protocol"); state$history[[length(state$history)]]$reason <<- reason; out
    }
    get_protocol <- function(ref) {
      rec <- .record(state, ref); if (rec$kind != "decision") .fail("Not decision")
      parsed <- .protocol_read(state, rec); unknown <- if (is.null(parsed$issue)) list() else list(parsed$issue)
      if (isTRUE(state$imported)) unknown <- c(unknown, list("untrusted_imported_claim"))
      .obj(ref = .make_ref(state, rec), name = rec$name, record_status = rec$status, protocol = parsed$protocol,
           unknown = .arr(unknown), imported_claim = if (isTRUE(state$imported)) "untrusted_imported_claim" else NULL)
    }
    register_comparison_plan <- function(name, mode, original, intended, criteria, reason, ref = NULL) {
      descriptor <- .comparison_plan(state, mode, original, intended, criteria)
      if (!.comparison_text(name) || !.comparison_text(reason)) .fail("Comparison name/reason required")
      if (is.null(ref)) rec <- .new_record(state, "decision", name) else {
        old <- .record(state, ref); latest <- state$records[[get(old$id, attr(state, "record_index")$latest)]]
        prior <- .comparison_read(state, old)
        if (old$kind != "decision" || old$revision != latest$revision || !identical(prior$record_type, .comparison_plan_key) || is.null(prior$descriptor)) .fail("Latest matching comparison revision required")
        rec <- .copy(old); rec$revision <- old$revision + 1L; rec$created_at <- .now()
      }
      rec$name <- name; rec$details <- .obj(reason = reason, approval = "not_applicable"); rec$details[[.comparison_plan_key]] <- descriptor
      out <- append_record(rec, "register_comparison_plan"); state$history[[length(state$history)]]$reason <<- reason; out
    }
    record_comparison_assessment <- function(plan_ref, candidate, observations, reason, ref = NULL) {
      descriptor <- .comparison_assessment(state, plan_ref, candidate, observations)
      if (!.comparison_text(reason)) .fail("Comparison reason required")
      if (is.null(ref)) rec <- .new_record(state, "decision", "Comparison assessment") else {
        old <- .record(state, ref); latest <- state$records[[get(old$id, attr(state, "record_index")$latest)]]
        prior <- .comparison_read(state, old)
        if (old$kind != "decision" || old$revision != latest$revision || !identical(prior$record_type, .comparison_assessment_key) || is.null(prior$descriptor)) .fail("Latest matching comparison revision required")
        if (!.protocol_same(prior$descriptor$plan_ref, descriptor$plan_ref) || !.protocol_same(prior$descriptor$candidate, descriptor$candidate)) .fail("Assessment plan/candidate binding immutable")
        rec <- .copy(old); rec$revision <- old$revision + 1L; rec$created_at <- .now()
      }
      rec$name <- "Comparison assessment"; rec$details <- .obj(reason = reason, approval = "not_applicable"); rec$details[[.comparison_assessment_key]] <- descriptor
      out <- append_record(rec, "register_comparison_assessment"); state$history[[length(state$history)]]$reason <<- reason; out
    }
    get_comparison <- function(ref, scientific_acceptance_ref = NULL) {
      rec <- .record(state, ref); if (rec$kind != "decision") .fail("Not decision")
      parsed <- .comparison_read(state, rec)
      out <- .obj(ref = .make_ref(state, rec), record_type = parsed$record_type, approval = "not_applicable", scientific = NULL,
        descriptor = parsed$descriptor, verdict = "UNKNOWN", context = list(), criteria = list(),
        claim_scope = "submitted evidence under specified criteria; not scientific reproducibility or approval", unknown = .arr(list("input_consumption", "scientific_validity")),
        metadata_consistency = "UNKNOWN", verdict_qualification = "submitted_evidence_only", independent_support = list(),
        scientific_acceptance = .obj(status = "not_supplied", ref = NULL, authentication = "not_authenticated"))
      if (!is.null(scientific_acceptance_ref)) {
        acceptance <- get_decision(scientific_acceptance_ref); scientific <- acceptance$scientific
        bound <- !is.null(scientific) && .protocol_same(.arr(lapply(scientific$subjects, `[[`, "ref")), .arr(list(.make_ref(state, rec))))
        out$scientific_acceptance <- .obj(status = if (bound && !isTRUE(state$imported)) paste0("recorded_", scientific$scientific_status) else "UNKNOWN", ref = acceptance$ref, authentication = "not_authenticated")
      }
      if (is.null(parsed$descriptor)) { out$unknown <- c(out$unknown, list("malformed_or_unsupported_comparison")); return(out) }
      if (identical(parsed$record_type, .comparison_plan_key)) return(out)
      plan <- .comparison_read(state, .record(state, parsed$descriptor$plan_ref))$descriptor
      context <- .comparison_context(state, get_execution, get_decision, get_protocol, compare_protocol, plan, parsed$descriptor$candidate); out$context <- context
      observations <- parsed$descriptor$observations; required <- character()
      for (criterion in plan$criteria) {
        found <- Filter(function(x) identical(x$criterion_id, criterion$criterion_id), observations); item <- if (length(found)) found[[1L]] else NULL
        effective <- "UNKNOWN"; gaps <- list(); expected <- list()
        for (side in list(plan$original, parsed$descriptor$candidate)) for (slot in side$outputs) if (slot$slot_id %in% unlist(criterion$slots, use.names = FALSE)) expected[[length(expected) + 1L]] <- slot$ref
        if (is.null(item)) gaps <- list("observation_missing") else {
          if (!length(item$evidence)) gaps <- c(gaps, list("evidence_missing"))
          if (!.protocol_same(item$subjects, .arr(expected))) gaps <- c(gaps, list("subject_binding"))
          if (!.protocol_same(item$comparator_ref, criterion$comparator_ref)) gaps <- c(gaps, list("comparator_binding"))
          if (is.null(item$observed) || is.character(item$observed) && !.comparison_text(item$observed)) gaps <- c(gaps, list("observation_unknown"))
          comparator <- .record(state, criterion$comparator_ref); evidence_bound <- FALSE
          for (evidence_ref in item$evidence) {
            evidence <- .record(state, evidence_ref)
            if (identical(comparator$kind, "analysis") && identical(evidence$kind, "data")) {
              receipt <- get_execution(criterion$comparator_ref); anchor <- if (is.null(receipt$run_ref)) criterion$comparator_ref else receipt$run_ref
              evidence_bound <- evidence_bound || (.protocol_same(evidence$scope$transformation_ref, anchor) && .protocol_same(comparator$inputs, .arr(expected)))
            } else if (identical(evidence$kind, "decision")) {
              evidence_bound <- evidence_bound || (.protocol_same(evidence$details$targets, .arr(expected)) && .protocol_same(evidence_ref, criterion$comparator_ref))
            } else if (identical(comparator$kind, "data") && identical(evidence$kind, "data")) {
              evidence_bound <- evidence_bound || (.protocol_same(evidence$details$comparison_subjects, .arr(expected)) && .protocol_same(evidence$details$comparison_comparator_ref, criterion$comparator_ref))
            }
          }
          if (!evidence_bound) gaps <- c(gaps, list("evidence_binding"))
          if (length(item$contradictory_evidence)) gaps <- c(gaps, list("conflicting_evidence"))
          if (!length(gaps)) effective <- item$verdict
        }
        review_ref <- if (is.null(item)) NULL else item$independent_review_ref; review_status <- "not_supplied"
        if (!is.null(review_ref)) {
          review <- .record(state, review_ref)
          review_status <- if (!length(intersect(.comparison_typed_keys, names(review$details))) && .protocol_same(review$details$targets, .arr(expected)) && !any(vapply(c(item$evidence, list(item$comparator_ref)), function(x) .protocol_same(review_ref, x), logical(1)))) "review_recorded" else "UNKNOWN"
        }
        out$independent_support[[length(out$independent_support) + 1L]] <- .obj(criterion_id = criterion$criterion_id, review_ref = review_ref, status = review_status, independence = "not_authenticated", empirical_verification = "UNKNOWN")
        out$criteria[[length(out$criteria) + 1L]] <- .obj(criterion_id = criterion$criterion_id, required = criterion$required, submitted = .copy(item), effective = effective, gaps = .arr(gaps))
        if (isTRUE(criterion$required)) required <- c(required, effective)
      }
      metadata <- vapply(context, `[[`, "verdict", FUN.VALUE = character(1))
      out$metadata_consistency <- if ("FAIL" %in% metadata) "FAIL" else if ("UNKNOWN" %in% metadata) "UNKNOWN" else "PASS"
      statuses <- c(required, metadata)
      out$verdict <- if ("FAIL" %in% statuses) "FAIL" else if ("UNKNOWN" %in% statuses) "UNKNOWN" else "PASS"
      if (any(vapply(out$criteria, function(row) "conflicting_evidence" %in% unlist(row$gaps, use.names = FALSE), logical(1)))) out$verdict_qualification <- "conflicting_evidence"
      if (isTRUE(state$imported)) { out$unknown <- c(out$unknown, list("untrusted_imported_claim")); if (identical(out$verdict, "PASS")) out$verdict <- "UNKNOWN" }
      .comparison_bound(out)
    }
    compare_protocol <- function(ref, executions, approval_ref = NULL) {
      rec <- .record(state, ref); if (rec$kind != "decision") .fail("Not decision")
      parsed <- .protocol_read(state, rec); if (is.null(parsed$protocol)) .fail(paste0("Protocol unavailable: ", parsed$issue))
      protocol <- parsed$protocol
      if (!.is_arr(executions) || length(executions) > 100L) .fail("executions must be an array of at most 100 items")
      ids <- character(); expanded <- 0L; selected <- lapply(executions, function(item) {
        if (!.is_obj(item) || !setequal(names(item), c("step_id", "analysis_ref")) || !is.character(item$step_id) || length(item$step_id) != 1L || !nzchar(item$step_id) || item$step_id %in% ids) .fail("Invalid execution selection")
        ids <<- c(ids, item$step_id); analysis <- .record(state, item$analysis_ref); if (analysis$kind != "analysis") .fail("Execution analysis_ref must reference analysis")
        bytes <- nchar(.json(analysis), type = "bytes")
        if (bytes > .protocol_limit) .fail("Protocol analysis metadata exceeds 64 KiB limit")
        expanded <<- expanded + bytes
        if (expanded > 1048576L) .fail("Selected analysis metadata exceeds 1 MiB limit")
        .obj(step_id = item$step_id, analysis_ref = .make_ref(state, analysis))
      })
      expected_ids <- vapply(protocol$steps, `[[`, "step_id", FUN.VALUE = character(1)); selected_ids <- vapply(selected, `[[`, "step_id", FUN.VALUE = character(1))
      by_id <- setNames(selected, selected_ids)
      receipts <- setNames(lapply(selected, function(item) get_execution(item$analysis_ref)), selected_ids)
      step_reports <- lapply(protocol$steps, function(expected) {
        item <- by_id[[expected$step_id]]
        if (is.null(item)) return(.obj(step_id = expected$step_id, expected_analysis_ref = .copy(expected$analysis_ref), selected_analysis_ref = NULL, mismatches = list("missing_step"), unknown = list()))
        result <- .obj(step_id = expected$step_id, expected_analysis_ref = .copy(expected$analysis_ref), selected_analysis_ref = .copy(item$analysis_ref), mismatches = list(), unknown = list(), data_dependent_observations = .obj())
        receipt <- receipts[[item$step_id]]; result$receipt_status <- receipt$status
        if (identical(receipt$status, "unknown") || isTRUE(state$imported)) { result$unknown <- c(result$unknown, list("execution_receipt")); return(result) }
        result$receipt_template_ref <- .copy(receipt$template_ref)
        if (!identical(receipt$status, "succeeded")) result$mismatches <- c(result$mismatches, list(paste0("execution_status.", receipt$status)))
        observed <- .record(state, item$analysis_ref); template <- .record(state, expected$analysis_ref)
        for (field in c("inputs", "method", "code", "design", "input_mode")) if (!.protocol_same(observed[[field]], template[[field]])) result$mismatches <- c(result$mismatches, list(field))
        if (is.null(template$params) || is.null(observed$params)) { if (!.protocol_same(template$params, observed$params)) result$mismatches <- c(result$mismatches, list("params")) } else {
          keys <- sort(unique(c(names(template$params), names(observed$params))), method = "radix")
          for (key in keys) if (key %in% unlist(expected$data_dependent_params, use.names = FALSE)) {
            if (!key %in% names(observed$params)) result$unknown <- c(result$unknown, list(paste0("data_dependent_param.", key))) else result$data_dependent_observations[key] <- list(.copy(observed$params[[key]]))
          } else if ((key %in% names(template$params)) != (key %in% names(observed$params)) || !.protocol_same(template$params[[key]], observed$params[[key]])) result$mismatches <- c(result$mismatches, list(paste0("params.", key)))
        }
        if (is.null(expected$seeds)) result$unknown <- c(result$unknown, list("seeds")) else if (!.protocol_same(receipt$seeds, expected$seeds)) result$mismatches <- c(result$mismatches, list("seeds"))
        got <- lapply(Filter(function(x) identical(x$status, "registered"), receipt$outputs), function(x) { out <- .obj(kind = x$kind); if (!is.null(x$type)) out$type <- x$type; out })
        if (!.protocol_same(.arr(got), expected$required_outputs)) result$mismatches <- c(result$mismatches, list("required_outputs"))
        if (any(vapply(receipt$inputs, function(item) !identical(item$identity, "match"), logical(1)))) result$unknown <- c(result$unknown, list("input_identity"))
        result$unknown <- c(result$unknown, list("environment", "input_consumption", "scientific_validity", "actual_parameter_use")); result
      })
      approval <- if (is.null(approval_ref)) .obj(status = "not_supplied") else tryCatch({ view <- get_decision(approval_ref); scientific <- view$scientific; if (isTRUE(state$imported) || is.null(scientific) || !identical(scientific$scientific_status, "approved")) .obj(status = "unknown", reason = "approval_not_approved_or_malformed") else .obj(status = if (.protocol_same(.arr(lapply(scientific$subjects, `[[`, "ref")), .arr(list(.make_ref(state, rec)))) ) "match" else "mismatch", ref = .copy(view$ref)) }, error = function(e) .obj(status = "unknown", reason = "approval_reference_unavailable"))
      extra <- selected_ids[!selected_ids %in% expected_ids]
      starts <- lapply(receipts, function(item) .protocol_timestamp(item$started_at_utc))
      ends <- lapply(receipts, function(item) .protocol_timestamp(item$ended_at_utc))
      observed_order <- "unknown"
      valid_times <- !isTRUE(state$imported) && length(receipts) > 1L &&
        all(vapply(receipts, function(item) identical(item$status, "succeeded"), logical(1))) &&
        all(vapply(c(starts, ends), function(x) length(x) == 1L && !is.na(x), logical(1))) &&
        all(vapply(seq_along(receipts), function(i) starts[[i]] < ends[[i]], logical(1)))
      if (valid_times) {
        pairs <- seq_len(length(receipts) - 1L)
        if (all(vapply(pairs, function(i) ends[[i]] < starts[[i + 1L]], logical(1)))) observed_order <- "strict_nonoverlap_in_submitted_order"
        else if (any(vapply(pairs, function(i) starts[[i]] > ends[[i + 1L]], logical(1)))) observed_order <- "different_from_submitted_order"
      }
      report <- .obj(report_version = .protocol_version, protocol_ref = .make_ref(state, rec), registry_revision = state$state_revision, unsaved = dirty,
           imported_claim = if (isTRUE(state$imported)) "untrusted_imported_claim" else NULL,
           approval = approval, submitted_order = .arr(as.list(selected_ids)), expected_order = .arr(as.list(expected_ids)), order = if (identical(selected_ids, expected_ids)) "match" else "mismatch", observed_order = observed_order, extra_steps = .arr(as.list(extra)), steps = .arr(step_reports),
           coverage = .obj(protocol = "intended_declared", execution = "selected_receipts_only", environment = "unknown", scientific_validity = "unknown", input_consumption = "unknown"))
      if (nchar(.json(report), type = "bytes") > .protocol_limit) .fail("Protocol comparison exceeds 64 KiB report limit")
      report
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
           next_task = state$project$next_task, design = get_design(), counts = .copy(attr(state, "record_index")$summary$counts), evidence = .execution_summary())
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
      paste(c(lines, "Project:", sprintf("  Data/artifact records: %d", counts$data), sprintf("  Analysis records:      %d", counts$analysis), sprintf("  Figures:               %d", counts$figure), paste0("Package version: ", getNamespaceVersion("BioDataLedger")), paste0("Registry revision: ", state$state_revision), paste0("Unsaved changes: ", if (dirty) "yes" else "no"), "Registration does not capture execution; inspect explicit run receipts."), collapse = "\n")
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
      result <- .obj(package_version = as.character(getNamespaceVersion("BioDataLedger")), project = .obj(id = state$project$id, name = clip(state$project$name, 80L)), registry_revision = state$state_revision,
                     current = .arr(current), active_question = NULL, next_task = clip(state$project$next_task, 160L),
                     missing = .obj(checked = checked, unchecked = if (check_files) length(candidates) - checked else NULL, found = if (check_files) found else NULL, items = .arr(items)),
                     availability_checked = check_files, counts = .copy(attr(state, "record_index")$summary$counts), unsaved = dirty, truncated = .obj(current = max(0L, length(purposes) - 5L), missing = found - length(items), text = clipped), evidence = .execution_summary())
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
    register_result <- function(source, analysis_ref, ref = NULL, embedding = NULL, copy = FALSE, hash = FALSE) {
      if (!is.logical(copy) || length(copy)!=1L || is.na(copy) || !is.logical(hash) || length(hash)!=1L || is.na(hash)) .fail('Invalid copy/hash')
      producer <- .result_ref(state,analysis_ref,'analysis')
      info <- .result_embedding(state,embedding)
      old <- if (is.null(ref)) NULL else .record(state,.result_ref(state,ref))
      if (!is.null(old) && !.result_valid(state,old)) .fail('Existing result declaration invalid')
      source_ref <- if (is.list(source) || is.character(source) && length(source)==1L && grepl('^DATA-[0-9]+@[0-9]+$',source)) .result_ref(state,source) else NULL
      if (!is.null(source_ref)) {
        source_rec <- .record(state,source_ref)
        if (!identical(source_rec$status,'active')) .fail('Inactive source data')
        loc <- source_rec$locator; baseline <- source_rec$sha256; size <- source_rec$size
      } else { loc <- .locator(root,source); baseline <- NULL; size <- NULL }
      if (identical(loc$kind,'uri')) .fail('Local result file required')
      path <- .resolve(root,state,loc)
      if (is.null(path) || !file.exists(path) || dir.exists(path)) .fail('Existing regular result file required')
      before <- file.info(path)
      observed <- if (copy || hash) .hash(path) else NULL
      after <- file.info(path)
      if (copy || hash) {
        if (!identical(before$size,after$size) || !identical(before$mtime,after$mtime) ||
            !identical(before$ctime,after$ctime)) .fail('Source changed during registration')
      }
      if (!is.null(baseline) && !is.null(observed) && !identical(tolower(baseline),tolower(observed))) .fail('Source digest mismatch')
      digest <- if (!is.null(baseline)) baseline else observed
      if (is.null(size) || copy || hash) size <- as.numeric(after$size)
      target <- loc
      if (copy) {
        base <- file.path(root,'.nb_project_bundle','outputs')
        dir.create(base,recursive=TRUE,showWarnings=FALSE)
        folder <- file.path(base,paste0('result-',.uuid()))
        if (!dir.create(folder,showWarnings=FALSE)) .fail('Cannot create result folder')
        complete <- FALSE
        on.exit(if (!complete) unlink(folder,recursive=TRUE),add=TRUE)
        dest <- file.path(folder,basename(path))
        if (!file.copy(path,dest,overwrite=FALSE) || !identical(.hash(dest),observed) || !identical(.hash(path),observed)) .fail('Result copy verification failed')
        target <- .locator(root,dest)
      }
      details <- if (is.null(old)) .obj() else .copy(old$details)
      details[[.result_key]] <- .obj(version=.result_version,artifact_source_ref=source_ref,
                                     storage=.obj(mode=if (copy) 'copy' else 'reference',source_locator=loc),embedding=info$embedding)
      details['membership'] <- list(info$membership)
      details <- validate_details(details)
      details$provenance$file <- if (is.null(digest)) 'unknown' else 'captured'
      rec <- if (is.null(old)) .new_record(state,'data',basename(path),target,role='derived_result',sha256=digest,size=size,details=details) else .copy(old)
      if (!is.null(old)) {
        rec$revision <- state$records[[get(rec$id,attr(state,'record_index')$latest)]]$revision+1L
        rec$created_at <- .now();rec$locator <- target;rec$sha256 <- digest;rec$size <- size;rec$details <- details
      }
      rec$scope <- .normalize_scope(.obj(transformation_ref=producer))
      rec['design'] <- list(if (is.null(producer)) NULL else .record(state,producer)$design)
      version <- if (state$schema_version %in% c('0.3.0','0.4.0')) state$schema_version else '0.3.0'
      if (!.result_valid(state,rec)) .fail('Invalid result declaration')
      out <- append_record(rec,'register_result',version=version)
      if (copy) complete <- TRUE
      out
    }
    check_result <- function(ref) .result_check(root,state,.result_ref(state,ref))
    dependencies <- function(ref,direction,depth=1,limit=20) .result_dependencies(state,result_graph,.ref(state,ref),direction,depth,limit)
    get_raw_dir <- function() .resolve(root, state, state$project$raw_dir)
    get_metadata_path <- function() .resolve(root, state, state$project$metadata)
    get_output_dir <- function(kind) file.path(root, "results", kind)
    related_work <- function(input_ref = NULL, query = NULL, limit = 5L) .related_work(state, result_graph, input_ref, query, limit, get_analysis, get_execution, dirty)
    execution_history <- function(analysis_ref = NULL, protocol_ref = NULL, limit = 10L, offset = 0L) .chronology_history(state, dirty, analysis_ref, protocol_ref, limit, offset, get_execution, get_protocol)
    execution_history_summary <- function(analysis_ref = NULL, protocol_ref = NULL, limit = 10L, offset = 0L) .chronology_summary(execution_history(analysis_ref, protocol_ref, limit, offset))
    self <- list(run_analysis = run_analysis, get_execution = get_execution, execution_summary = execution_summary, execution_history = execution_history, execution_history_summary = execution_history_summary, register_result = register_result, check_result = check_result, dependencies = dependencies, related_work = related_work, register_protocol = register_protocol, get_protocol = get_protocol, compare_protocol = compare_protocol, register_comparison_plan = register_comparison_plan, record_comparison_assessment = record_comparison_assessment, get_comparison = get_comparison, check_object = check_object, read_figure_source = read_figure_source, check_context = check_context, resolve_figure = resolve_figure, save_figure = save_figure, register_data = register_data, set_data_scope = set_data_scope, resolve_data = resolve_data, register_analysis = register_analysis, register_figure = register_figure, get_data = get_data, get_analysis = get_analysis, get_figure = get_figure, get_design = get_design, get_condition = get_condition, get_levels = get_levels, get_selected_levels = get_selected_levels, get_reference_level = get_reference_level, get_replicate = get_replicate, set_design = set_design, check_design_metadata = check_design_metadata, get_design_summary = get_design_summary, summary_text = summary_text, find_figures = find_figures, save = save, save_and_confirm = save_and_confirm, set_current = set_current, set_context = set_context, update_record = update_record, record_decision = record_decision, record_scientific_decision = record_scientific_decision, get_decision = get_decision, rebind_external = rebind_external, check = check, summary = summary, status = status, get_raw_dir = get_raw_dir, get_metadata_path = get_metadata_path, get_output_dir = get_output_dir)
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
