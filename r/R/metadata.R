# Continuous metadata tables are retained as ordinary DATA payloads; registry rows stay bounded.
.metadata_categories <- c("sample_preparation", "acquisition", "processing_qc", "analysis", "annotation", "result")
.metadata_key <- "bl_metadata_table"
.metadata_binding_key <- "bl_metadata_bindings"
.metadata_role <- "bl_metadata_table"
.metadata_policy_key <- "bl_metadata_policy"
.metadata_version <- "biodataledger-metadata/1"
.metadata_binding_version <- "biodataledger-metadata-bindings/1"
.metadata_file_limit <- 64 * 1024 * 1024

.metadata_text <- function(x, allow_empty = FALSE) is.character(x) && length(x) == 1L && !is.na(x) && (allow_empty || nzchar(trimws(x)))
.metadata_array <- function(x, name, nonempty = FALSE) {
  if (is.character(x)) x <- as.list(x)
  if (!.is_arr(x) || (nonempty && !length(x)) || !all(vapply(x, .metadata_text, logical(1))) || anyDuplicated(unlist(x, use.names = FALSE))) .fail(paste0("Invalid ", name))
  .arr(as.list(unlist(x, use.names = FALSE)))
}
.metadata_ref <- function(state, value, latest = FALSE) {
  ref <- .ref(state, value); rec <- .record(state, ref)
  if (rec$kind != "data" || !identical(rec$role, .metadata_role) || is.null(rec$details[[.metadata_key]])) .fail("Metadata table reference required")
  if (latest && ref$revision != state$records[[get(rec$id, attr(state, "record_index")$latest)]]$revision) .fail("Latest metadata table reference required")
  ref
}
.metadata_descriptor <- function(category, key_columns, required_columns, authority, reason, units, links, columns, row_count, delimiter) {
  if (!.metadata_text(category) || !category %in% .metadata_categories || !.metadata_text(authority) || !.metadata_text(reason) || !delimiter %in% c(",", "\t") || !.is_obj(units) || !.is_arr(links) || !.is_int(row_count, TRUE)) .fail("Invalid metadata descriptor")
  key_columns <- .metadata_array(key_columns, "key_columns", TRUE); required_columns <- .metadata_array(required_columns, "required_columns")
  columns <- .metadata_array(columns, "columns", TRUE)
  if (!all(unlist(key_columns, use.names = FALSE) %in% unlist(columns, use.names = FALSE)) || !all(unlist(required_columns, use.names = FALSE) %in% unlist(columns, use.names = FALSE))) .fail("Metadata columns missing")
  if (length(units)) for (key in names(units)) if (!key %in% unlist(columns, use.names = FALSE) || !.metadata_text(units[[key]])) .fail("Invalid metadata units")
  .obj(version = .metadata_version, category = category, key_columns = key_columns, required_columns = required_columns, authority = authority, reason = reason, units = units, links = links, columns = columns, row_count = as.integer(row_count), delimiter = delimiter)
}
.metadata_parse <- function(path, delimiter) {
  info <- file.info(path); if (is.na(info$size) || info$size > .metadata_file_limit || info$size < 1L) .fail("Metadata CSV exceeds 64 MiB or is empty")
  options <- list(file = path, sep = delimiter, quote = "\"", comment.char = "", fill = FALSE,
                  colClasses = "character", na.strings = character(), check.names = FALSE,
                  stringsAsFactors = FALSE, strip.white = FALSE, blank.lines.skip = FALSE,
                  fileEncoding = "UTF-8", row.names = NULL)
  header <- tryCatch(do.call(utils::read.table, c(options, list(header = FALSE, nrows = 1L))), error = function(e) .fail(paste0("Invalid metadata CSV: ", conditionMessage(e))))
  table <- tryCatch(do.call(utils::read.table, c(options, list(header = TRUE))), error = function(e) .fail(paste0("Invalid metadata CSV: ", conditionMessage(e))))
  if (ncol(table) != ncol(header)) .fail("Metadata CSV rows are ragged")
  names(table) <- sub("^\\ufeff", "", names(table))
  if (!nrow(table) || !ncol(table) || ncol(table) > 256L || any(!nzchar(names(table))) || anyDuplicated(names(table))) .fail("Metadata requires unique nonempty headers and data rows")
  for (name in names(table)) table[[name]] <- ifelse(is.na(table[[name]]), "", enc2utf8(table[[name]]))
  table
}
.metadata_tuple <- function(table, columns) do.call(paste0, lapply(columns, function(column) {
  value <- table[[column]]; paste0(nchar(value, type = "chars"), ":", value)
}))
.metadata_validate_rows <- function(table, key_columns, required_columns) {
  if (!all(c(unlist(key_columns, use.names = FALSE), unlist(required_columns, use.names = FALSE)) %in% names(table))) .fail("Metadata required columns missing")
  for (column in unique(c(unlist(key_columns, use.names = FALSE), unlist(required_columns, use.names = FALSE)))) if (any(!nzchar(trimws(table[[column]])))) .fail("Metadata key or required value is blank")
  keys <- .metadata_tuple(table, unlist(key_columns, use.names = FALSE))
  if (anyDuplicated(keys)) .fail("Metadata composite keys must be unique")
  invisible(keys)
}
.metadata_links <- function(state, links, columns, latest = FALSE) {
  if (!is.list(links) || (!is.null(names(links)) && length(links))) .fail("Metadata links must be an array")
  seen <- character(); out <- lapply(links, function(link) {
    if (!.is_obj(link) || !setequal(names(link), c("ref", "columns", "target_columns"))) .fail("Invalid metadata link")
    target <- .metadata_ref(state, link$ref, latest = latest); desc <- .record(state, target)$details[[.metadata_key]]
    child <- .metadata_array(link$columns, "link columns", TRUE); target_columns <- .metadata_array(link$target_columns, "target_columns", TRUE)
    if (!identical(unlist(target_columns, use.names = FALSE), unlist(desc$key_columns, use.names = FALSE)) || length(child) != length(target_columns) || !all(unlist(child, use.names = FALSE) %in% columns)) .fail("Invalid metadata link columns")
    marker <- .ref_text(target); if (marker %in% seen) .fail("Duplicate metadata link"); seen <<- c(seen, marker)
    .obj(ref = target, columns = child, target_columns = target_columns)
  })
  .arr(out)
}
.metadata_link_rows <- function(root, state, links, child_table) {
  for (link in links) {
    target <- .record(state, link$ref); path <- .resolve(root, state, target$locator)
    if (is.null(path) || !file.exists(path) || dir.exists(path) || file.info(path)$size != target$size || !identical(.hash(path), target$sha256)) .fail("Metadata link target is unavailable or changed")
    parent <- .metadata_parse(path, target$details[[.metadata_key]]$delimiter)
    .metadata_validate_rows(parent, target$details[[.metadata_key]]$key_columns, target$details[[.metadata_key]]$required_columns)
    if (!identical(names(parent), unlist(target$details[[.metadata_key]]$columns, use.names = FALSE)) || nrow(parent) != target$details[[.metadata_key]]$row_count) .fail("Metadata link target differs from descriptor")
    child_keys <- .metadata_tuple(child_table, unlist(link$columns, use.names = FALSE)); parent_keys <- .metadata_tuple(parent, unlist(link$target_columns, use.names = FALSE))
    if (!all(child_keys %in% parent_keys)) .fail("Metadata foreign key is absent from target")
  }
  invisible(NULL)
}
.metadata_validate_descriptor <- function(state, rec) {
  value <- rec$details[[.metadata_key]]
  if (is.null(value)) { if (identical(rec$role, .metadata_role)) .fail("Metadata table descriptor required"); return(invisible(NULL)) }
  if (rec$kind != "data" || !identical(rec$role, .metadata_role) || !.is_obj(value) || !setequal(names(value), c("version", "category", "key_columns", "required_columns", "authority", "reason", "units", "links", "columns", "row_count", "delimiter")) || is.null(rec$locator) || !identical(rec$locator$kind, "project") || !startsWith(rec$locator$value, ".nb_project_bundle/outputs/metadata-") || is.null(rec$sha256) || is.null(rec$size)) .fail("Invalid metadata table record")
  canonical <- .metadata_descriptor(value$category, value$key_columns, value$required_columns, value$authority, value$reason, value$units, value$links, value$columns, value$row_count, value$delimiter)
  if (!.result_equal(canonical, value)) .fail("Metadata descriptor is not canonical")
  .metadata_links(state, value$links, unlist(value$columns, use.names = FALSE)); invisible(NULL)
}
.metadata_validate_bindings <- function(state, rec) {
  value <- rec$details[[.metadata_binding_key]]
  if (is.null(value)) return(invisible(NULL))
  if (!rec$kind %in% c("data", "analysis") || identical(rec$role, .metadata_role) || !.is_obj(value) || !setequal(names(value), c("version", "refs", "reason")) || !identical(value$version, .metadata_binding_version) || !.metadata_text(value$reason) || !.is_arr(value$refs) || !length(value$refs)) .fail("Invalid metadata bindings")
  ids <- character(); for (ref in value$refs) { exact <- .metadata_ref(state, ref); if (exact$id %in% ids) .fail("Duplicate metadata ID binding"); ids <- c(ids, exact$id) }; invisible(NULL)
}
.metadata_validate_state <- function(state, record_only = NULL) {
  for (rec in if (is.null(record_only)) state$records else list(record_only)) { .metadata_validate_descriptor(state, rec); .metadata_validate_bindings(state, rec) }
  if (is.null(record_only)) {
    typed <- any(vapply(state$records, function(rec) !is.null(rec$details[[.metadata_key]]) || !is.null(rec$details[[.metadata_binding_key]]), logical(1)))
    if (typed && (!identical(state$schema_version, "0.4.0") || !identical(state$project[[.metadata_policy_key]], "continuous_metadata_v1"))) .fail("Typed metadata requires schema 0.4.0 and continuous_metadata_v1 policy")
    visiting <- character(); visited <- character()
    visit <- function(ref) {
      key <- .ref_text(ref); if (key %in% visiting) .fail("Metadata links contain a cycle"); if (key %in% visited) return(invisible(NULL))
      rec <- .record(state, ref); if (!is.null(rec$details[[.metadata_key]])) { visiting <<- c(visiting, key); for (link in rec$details[[.metadata_key]]$links) visit(link$ref); visiting <<- setdiff(visiting, key) }
      visited <<- c(visited, key); invisible(NULL)
    }
    for (rec in state$records) if (!is.null(rec$details[[.metadata_key]])) visit(.make_ref(state, rec))
  }
  invisible(NULL)
}
.metadata_rows <- function(table, offset, limit) {
  n <- nrow(table); idx <- if (offset >= n) integer() else seq.int(offset + 1L, min(n, offset + limit))
  .arr(lapply(idx, function(i) { row <- as.list(table[i, , drop = FALSE]); names(row) <- names(table); row }))
}
.metadata_summary <- function(state, ref) { rec <- .record(state, ref); d <- rec$details[[.metadata_key]]; .obj(ref = .make_ref(state, rec), name = rec$name, category = d$category, authority = d$authority, key_columns = .copy(d$key_columns), links = .copy(d$links), columns = .copy(d$columns), row_count = d$row_count) }
.metadata_subject_neighbors <- function(state, rec) {
  out <- list(); add <- function(ref) if (!is.null(ref)) out[[length(out) + 1L]] <<- ref
  bindings <- rec$details[[.metadata_binding_key]]; if (!is.null(bindings)) for (ref in bindings$refs) add(ref)
  if (rec$kind == "data" && !is.null(rec$scope$transformation_ref)) add(rec$scope$transformation_ref)
  if (rec$kind == "analysis" && !is.null(rec$inputs)) for (ref in rec$inputs) add(ref)
  if (rec$kind == "figure") { add(rec$analysis); if (!is.null(rec$inputs)) for (ref in rec$inputs) add(ref) }
  if (!is.null(rec$details[[.metadata_key]])) for (link in rec$details[[.metadata_key]]$links) add(link$ref)
  out
}
.metadata_view <- function(state, ref) {
  subject <- .ref(state, ref); queue <- list(subject); seen <- character(); categories <- stats::setNames(vector("list", length(.metadata_categories)), .metadata_categories); source_refs <- list(); truncated <- FALSE
  while (length(queue)) {
    here <- queue[[1L]]; queue <- queue[-1L]; key <- .ref_text(here); if (key %in% seen) next
    if (length(seen) >= 1000L) { truncated <- TRUE; break }
    seen <- c(seen, key); rec <- .record(state, here)
    if (!is.null(rec$details[[.metadata_key]])) { d <- rec$details[[.metadata_key]]; categories[[d$category]][[length(categories[[d$category]]) + 1L]] <- .metadata_summary(state, here); source_refs[[length(source_refs) + 1L]] <- .make_ref(state, rec) }
    for (next_ref in .metadata_subject_neighbors(state, rec)) queue[[length(queue) + 1L]] <- next_ref
  }
  for (category in names(categories)) categories[[category]] <- .arr(categories[[category]])
  .obj(subject_ref = subject, categories = categories, missing_categories = .arr(as.list(.metadata_categories[vapply(categories, length, integer(1)) == 0L])), source_refs = .arr(source_refs), limits = .obj(max_records = 1000L, truncated = truncated, visited_records = length(seen)))
}
.metadata_issue <- function(code, message, ref = NULL) .obj(code = code, message = message, ref = ref)
.metadata_public_get <- function(x) {
  out <- x; names(out) <- paste0("bl_", names(out)); out
}
.metadata_public_view <- function(x) {
  summaries <- lapply(x$categories, function(items) lapply(items, .metadata_public_get))
  out <- .obj(bl_subject_ref = x$subject_ref, bl_categories = summaries, bl_missing_categories = x$missing_categories,
              bl_source_refs = x$source_refs, bl_limits = .obj(bl_max_records = x$limits$max_records,
              bl_truncated = x$limits$truncated, bl_visited_records = x$limits$visited_records))
  out
}
.metadata_public_check <- function(x) {
  issues <- lapply(x$issues, function(issue) .obj(bl_code = issue$code, bl_message = issue$message, bl_ref = issue$ref))
  .obj(bl_status = x$status, bl_subject_ref = x$subject_ref, bl_available_categories = x$available_categories,
       bl_missing_required = x$missing_required, bl_issues = issues, bl_tables_checked = x$tables_checked,
       bl_data_alignment = x$data_alignment, bl_scientific_acceptance = x$scientific_acceptance)
}
.metadata_check <- function(root, state, ref, required_categories = NULL) {
  view <- .metadata_view(state, ref); required <- if (is.null(required_categories)) "sample_preparation" else unlist(.metadata_array(required_categories, "required_categories"), use.names = FALSE)
  if (!all(required %in% .metadata_categories)) .fail("Unknown metadata category")
  available <- names(view$categories)[vapply(view$categories, length, integer(1)) > 0L]; missing <- setdiff(required, available); issues <- list(); checked <- new.env(parent = emptyenv()); checked$count <- 0L; tables <- new.env(parent = emptyenv()); failed <- FALSE; unknown <- length(missing) > 0L || isTRUE(view$limits$truncated)
  if (isTRUE(view$limits$truncated)) issues[[length(issues) + 1L]] <- .metadata_issue("TRUNCATED", "Metadata graph traversal reached its limit")
  for (summary in unlist(view$categories, recursive = FALSE)) {
    rec <- .record(state, summary$ref); path <- .resolve(root, state, rec$locator)
    if (is.null(path) || !file.exists(path)) { unknown <- TRUE; issues[[length(issues)+1L]] <- .metadata_issue("MISSING_FILE", "Metadata table is unavailable", summary$ref); next }
    if (nzchar(Sys.readlink(path))) { failed <- TRUE; issues[[length(issues)+1L]] <- .metadata_issue("UNSAFE_FILE", "Managed metadata table must not be a symbolic link", summary$ref); next }
    tryCatch({
      before <- file.info(path); if (is.na(before$size) || before$size != rec$size) .fail("Metadata file size mismatch")
      observed <- .hash(path); if (!identical(observed, rec$sha256)) .fail("Metadata file digest mismatch")
      table <- .metadata_parse(path, rec$details[[.metadata_key]]$delimiter); .metadata_validate_rows(table, rec$details[[.metadata_key]]$key_columns, rec$details[[.metadata_key]]$required_columns)
      if (!identical(names(table), unlist(rec$details[[.metadata_key]]$columns, use.names = FALSE)) || nrow(table) != rec$details[[.metadata_key]]$row_count) .fail("Metadata table differs from descriptor")
      assign(.ref_text(summary$ref), list(rec = rec, ref = summary$ref, table = table), envir = tables); checked$count <- checked$count + 1L; assign(as.character(checked$count), summary$ref, envir = checked)
    }, error = function(e) { failed <<- TRUE; code <- if (grepl("size", conditionMessage(e), ignore.case=TRUE)) "SIZE_MISMATCH" else if (grepl("digest", conditionMessage(e), ignore.case=TRUE)) "DIGEST_MISMATCH" else "INVALID_TABLE"; issues[[length(issues)+1L]] <<- .metadata_issue(code, conditionMessage(e), summary$ref) })
  }
  table_values <- as.list(tables)
  for (item in table_values) for (link in item$rec$details[[.metadata_key]]$links) {
    target <- get0(.ref_text(link$ref), envir = tables, inherits = FALSE); if (is.null(target)) { unknown <- TRUE; issues[[length(issues)+1L]] <- .metadata_issue("UNVERIFIED_LINK", "Linked metadata table unavailable or invalid", item$ref); next }
    child_keys <- .metadata_tuple(item$table, unlist(link$columns, use.names = FALSE)); target_keys <- .metadata_tuple(target$table, unlist(link$target_columns, use.names = FALSE))
    if (!all(child_keys %in% target_keys)) { failed <- TRUE; issues[[length(issues)+1L]] <- .metadata_issue("INVALID_LINK", "Metadata foreign key is absent from target", item$ref) }
  }
  grouped <- split(table_values, vapply(table_values, function(x) paste(x$rec$details[[.metadata_key]]$category, paste(unlist(x$rec$details[[.metadata_key]]$key_columns, use.names = FALSE), collapse = "\r"), sep = "\f"), character(1)))
  for (group in grouped) if (length(group) > 1L) for (i in seq_len(length(group)-1L)) for (j in seq.int(i+1L, length(group))) {
    left <- group[[i]]; right <- group[[j]]; keys <- unlist(left$rec$details[[.metadata_key]]$key_columns, use.names = FALSE); common <- setdiff(intersect(names(left$table), names(right$table)), keys)
    left_key <- .metadata_tuple(left$table, keys); right_key <- .metadata_tuple(right$table, keys); right_index <- match(left_key, right_key); shared <- !is.na(right_index)
    for (column in common) {
      a <- left$table[[column]][shared]; b <- right$table[[column]][right_index[shared]]
      if (any(nzchar(a) & nzchar(b) & a != b)) { failed <- TRUE; issues[[length(issues)+1L]] <- .metadata_issue("CONFLICT", paste0("Conflicting metadata value in ", column), left$ref) }
    }
  }
  checked_refs <- lapply(seq_len(checked$count), function(i) get(as.character(i), envir = checked, inherits = FALSE))
  .obj(status = if (failed) "FAIL" else if (unknown) "UNKNOWN" else "PASS", subject_ref = view$subject_ref, available_categories = .arr(as.list(available)), missing_required = .arr(as.list(missing)), issues = .arr(issues), tables_checked = .arr(checked_refs), data_alignment = "not_checked", scientific_acceptance = "not_assessed")
}
