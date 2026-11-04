.chronology_version <- "biodataledger-chronology/1"
.chronology_max_bytes <- 65536L

.chronology_unknown <- function(state, record, reason) {
  ref <- .make_ref(state, record)
  .obj(analysis_ref = ref, receipt_ref = .copy(ref), evidence = "unknown", reason = reason)
}

.chronology_entry <- function(state, record, get_execution) {
  receipt <- get_execution(.make_ref(state, record))
  if (identical(receipt$status, "unknown")) return(.chronology_unknown(state, record, receipt$reason))
  start <- .protocol_timestamp(receipt$started_at_utc)
  end <- .protocol_timestamp(receipt$ended_at_utc)
  if (identical(receipt$status, "started")) timing <- if (!is.na(start)) "open" else "invalid"
  else if (identical(receipt$status, "blocked") || !isTRUE(receipt$phases$execution_started)) timing <- "not_executed"
  else timing <- if (!is.na(start) && !is.na(end) && start <= end) "valid_interval" else "invalid"
  .obj(analysis_ref = .make_ref(state, record), receipt_ref = .copy(receipt$receipt_ref),
       run_ref = .copy(receipt$run_ref), template_ref = .copy(receipt$template_ref),
       registration_at_utc = record$created_at, started_at_utc = receipt$started_at_utc,
       ended_at_utc = receipt$ended_at_utc, outcome = receipt$status, timing_status = timing,
       evidence = if (isTRUE(state$imported)) "untrusted_imported" else "recorded")
}

.chronology_relations <- function(entries) {
  intervals <- lapply(entries, function(entry) {
    if (!identical(entry$timing_status, "valid_interval") || !identical(entry$evidence, "recorded")) return(NULL)
    c(.protocol_timestamp(entry$started_at_utc), .protocol_timestamp(entry$ended_at_utc))
  })
  result <- list()
  if (length(entries) > 1L) for (left in seq_len(length(entries) - 1L)) {
    for (right in seq.int(left + 1L, length(entries))) {
      a <- intervals[[left]]; b <- intervals[[right]]; relation <- "unknown"
      if (!is.null(a) && !is.null(b)) {
        if (a[[2]] < b[[1]]) relation <- "before"
        else if (b[[2]] < a[[1]]) relation <- "after"
        else if (all(a == b)) relation <- "tied"
        else if (a[[2]] == b[[1]] || b[[2]] == a[[1]]) relation <- "tied_boundary"
        else relation <- "overlap"
      }
      result[[length(result) + 1L]] <- .obj(left = left, right = right, relation = relation)
    }
  }
  .arr(result)
}

.chronology_selection <- function(state, analysis_ref, protocol_ref, get_protocol) {
  selector <- .obj(kind = "project"); targets <- NULL; run_id <- NULL
  if (!is.null(analysis_ref)) {
    record <- .record(state, analysis_ref)
    if (record$kind != "analysis") .fail("Analysis reference required")
    selector <- .obj(kind = "analysis_ref", analysis_ref = .make_ref(state, record))
    targets <- list(selector$analysis_ref)
    if ("execution_receipt" %in% names(record$details)) run_id <- record$id
  } else if (!is.null(protocol_ref)) {
    view <- get_protocol(protocol_ref)
    if (is.null(view$protocol)) .fail("Protocol unavailable")
    steps <- view$protocol$steps
    targets <- lapply(steps, `[[`, "analysis_ref")
    displayed <- list()
    for (step in steps[seq_len(min(length(steps), 20L))]) {
      item <- .obj(step_id = step$step_id, analysis_ref = step$analysis_ref)
      if (nchar(.json(.arr(c(displayed, list(item)))), type = "bytes") > 4096L) break
      displayed[[length(displayed) + 1L]] <- .copy(item)
    }
    selector <- .obj(kind = "protocol_ref", protocol_ref = view$ref, steps = .arr(displayed),
                     omitted_steps = length(steps) - length(displayed), order_evidence = "declared_intent_not_approval")
  }
  list(selector = selector, targets = targets, run_id = run_id)
}

.chronology_report <- function(state, dirty, selector, entries, offset, cursor, total, reason) {
  more <- cursor < total
  .obj(report_version = .chronology_version, selector = selector, registry_revision = state$state_revision,
       unsaved = dirty, imported_claim = if (isTRUE(state$imported)) "untrusted_imported_claim" else NULL,
       scan = .obj(offset = offset, scanned = cursor - offset, total_record_slots = total,
                   next_offset = if (more) cursor else NULL, truncated = more, stop_reason = reason),
       presentation_order = "reverse_registration_slots_not_execution_or_dependency_or_protocol_order",
       evidence_scope = "recorded_receipts_only_not_complete_execution_history",
       entries = .arr(entries), relations = .chronology_relations(entries))
}

.chronology_history <- function(state, dirty, analysis_ref = NULL, protocol_ref = NULL,
                               limit = 10L, offset = 0L, get_execution, get_protocol) {
  if (!is.null(analysis_ref) && !is.null(protocol_ref)) .fail("Choose at most one selector")
  if (!.is_int(limit, TRUE) || limit > 20L) .fail("limit must be an integer from 1 to 20")
  if (!.is_int(offset) || offset < 0 || offset > 2147483647) .fail("offset must be a nonnegative 32-bit integer")
  selection <- .chronology_selection(state, analysis_ref, protocol_ref, get_protocol)
  selector <- selection$selector; targets <- selection$targets; run_id <- selection$run_id
  entries <- list(); expanded <- 0; cursor <- offset; total <- length(state$records); reason <- "end"
  latest <- attr(state, "record_index")$latest
  while (cursor < total && cursor - offset < 1000L && length(entries) < limit) {
    index <- total - cursor; record <- state$records[[index]]
    if (record$kind != "analysis" || get(record$id, latest) != index || !"execution_receipt" %in% names(record$details)) {
      cursor <- cursor + 1L
      next
    }
    raw <- record$details$execution_receipt
    matches <- is.null(targets) || identical(record$id, run_id) ||
      .is_obj(raw) && any(vapply(targets, function(target) .protocol_same(raw$template_ref, target), logical(1)))
    if (!matches) { cursor <- cursor + 1L; next }
    size <- nchar(.json(record), type = "bytes")
    if (size > .chronology_max_bytes) entry <- .chronology_unknown(state, record, "metadata_limit")
    else {
      if (expanded + size > 1048576) { reason <- "metadata_budget"; break }
      expanded <- expanded + size
      entry <- .chronology_entry(state, record, get_execution)
    }
    candidate <- .chronology_report(state, dirty, selector, c(entries, list(entry)), offset, cursor + 1L, total, "end")
    if (nchar(.json(candidate), type = "bytes") > .chronology_max_bytes) {
      if (length(entries)) { reason <- "report_limit"; break }
      entry <- .chronology_unknown(state, record, "report_limit")
    }
    entries[[length(entries) + 1L]] <- entry
    cursor <- cursor + 1L
  }
  if (identical(reason, "end") && cursor < total) reason <- if (length(entries) == limit) "limit" else "scan_limit"
  report <- .chronology_report(state, dirty, selector, entries, offset, cursor, total, reason)
  if (nchar(.json(report), type = "bytes") > .chronology_max_bytes) .fail("Chronology report exceeds 64 KiB")
  report
}

.chronology_summary <- function(report) {
  header <- "Recorded receipt history; reverse registration slots, not a total execution/dependency/protocol order."
  rows <- vapply(seq_along(report$entries), function(index) {
    entry <- report$entries[[index]]; ref <- entry$receipt_ref
    row <- paste0("[", index, "] ", ref$id, "@", ref$revision, ": ", if (is.null(entry$outcome)) entry$reason else entry$outcome,
                  "; evidence=", entry$evidence)
    if ("started_at_utc" %in% names(entry)) row <- paste0(row, "; start=", entry$started_at_utc,
      "; end=", if (is.null(entry$ended_at_utc)) "unknown" else entry$ended_at_utc, "; timing=", entry$timing_status)
    row
  }, character(1))
  count <- length(rows)
  repeat {
    footer <- paste0("Summary omitted ", length(rows) - count, " entries; next_offset=",
                     if (is.null(report$scan$next_offset)) "none" else report$scan$next_offset,
                     "; absent records do not prove no execution.")
    relations <- vapply(Filter(function(item) item$right <= count, report$relations),
                        function(item) paste0(item$left, "-", item$right, "=", item$relation), character(1))
    relation_line <- paste0("Relations among shown rows: ", if (length(relations)) paste(relations, collapse = ", ") else "none")
    text <- paste(c(header, rows[seq_len(count)], relation_line, footer), collapse = "\n")
    if (nchar(text, type = "bytes") <= 4096L) return(text)
    count <- count - 1L
  }
}
