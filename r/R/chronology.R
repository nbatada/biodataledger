.chronology_version <- "biodataledger-chronology/1"
.chronology_max_bytes <- 65536L

.chronology_unknown <- function(state, record, reason) {
  ref <- .make_ref(state, record)
  .obj(analysis_ref = ref, receipt_ref = .copy(ref), evidence = "unknown", reason = reason)
}

.receipt_timing <- function(receipt) {
  start <- .protocol_timestamp(receipt$started_at_utc)
  end <- .protocol_timestamp(receipt$ended_at_utc)
  if (identical(receipt$status, "started")) return(if (!is.na(start)) "open" else "invalid")
  if (identical(receipt$status, "blocked") || !isTRUE(receipt$phases$execution_started)) return("not_executed")
  if (!is.na(start) && !is.na(end) && start <= end) "valid_interval" else "invalid"
}

.chronology_entry <- function(state, record, get_execution) {
  receipt <- get_execution(.make_ref(state, record))
  if (identical(receipt$status, "unknown")) return(.chronology_unknown(state, record, receipt$reason))
  timing <- .receipt_timing(receipt)
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

.timeline_timestamp <- function(value) {
  # R can parse year zero, outside the range accepted by the Python reader.
  !startsWith(value, "0000-") && !is.na(.protocol_timestamp(value))
}

.timeline_receipt <- function(state, record) {
  receipt <- record$details$execution_receipt
  if (!isTRUE(.execution_receipt_valid(state, record, receipt)) ||
      !is.character(receipt$status) || length(receipt$status) != 1L) return(NULL)
  valid_outputs <- vapply(receipt$outputs, function(item) {
    is.character(item$status) && length(item$status) == 1L &&
      (!identical(item$status, "registered") || .is_obj(item$record_ref))
  }, logical(1))
  if (all(valid_outputs)) receipt else NULL
}

.timeline_receipt_timing <- function(receipt) {
  if (is.null(receipt)) return("unknown")
  timing <- .receipt_timing(receipt)
  if (timing %in% c("open", "valid_interval") &&
      (startsWith(receipt$started_at_utc, "0000-") ||
       (!is.null(receipt$ended_at_utc) && startsWith(receipt$ended_at_utc, "0000-")))) return("invalid")
  if (timing == "valid_interval" && !isTRUE(receipt$phases$code_executed)) return("code_not_executed")
  timing
}

.timeline_index <- function(state, view) {
  records <- state$records
  positions <- seq_along(records)
  if (view == "registration") {
    stamps <- vapply(records, `[[`, character(1), "created_at")
    unique_stamps <- unique(stamps)
    valid <- vapply(unique_stamps, .timeline_timestamp, logical(1))
    stamps[!valid[match(stamps, unique_stamps)]] <- ""
    timing <- rep(NA_character_, length(stamps))
  } else {
    latest <- attr(state, "record_index")$latest
    positions <- positions[vapply(positions, function(i) {
      rec <- records[[i]]
      rec$kind == "analysis" && get(rec$id, latest) == i && "execution_receipt" %in% names(rec$details)
    }, logical(1))]
    stamps <- character(length(positions))
    timing <- character(length(positions))
    for (i in seq_along(positions)) {
      rec <- records[[positions[[i]]]]
      receipt <- .timeline_receipt(state, rec)
      timing[[i]] <- .timeline_receipt_timing(receipt)
      if (timing[[i]] == "valid_interval" && !isTRUE(state$imported)) stamps[[i]] <- receipt$started_at_utc
    }
  }
  ids <- vapply(positions, function(i) records[[i]]$id, character(1))
  revisions <- vapply(positions, function(i) records[[i]]$revision, numeric(1))
  oldest <- order(!nzchar(stamps), stamps, ids, revisions, method = "radix")
  newest <- order(!nzchar(stamps), stamps, ids, revisions, method = "radix", decreasing = c(FALSE, TRUE, FALSE, FALSE))
  list(positions = positions, stamps = stamps, timing = timing, oldest = oldest, newest = newest)
}

.timeline_row <- function(state, view, index, slot) {
  record <- state$records[[index$positions[[slot]]]]
  stamp <- index$stamps[[slot]]
  timing <- index$timing[[slot]]
  receipt <- NULL; evidence <- NULL
  if (record$kind == "analysis") {
    if (view == "registration") receipt <- .timeline_receipt(state, record)
    else if (timing != "unknown") receipt <- record$details$execution_receipt
    evidence <- if (is.null(receipt)) "unknown" else if (isTRUE(state$imported)) "untrusted_imported" else "recorded"
  }
  analysis <- if (is.character(record$analysis)) .ref(state, record$analysis) else record$analysis
  row <- .obj(ref = .make_ref(state, record), kind = record$kind, time_utc = if (nzchar(stamp)) stamp else NULL,
              evidence = evidence, outcome = receipt$status, analysis_ref = analysis, omitted_text_fields = list())
  texts <- .obj(name = record$name, registration_at_utc = record$created_at)
  links <- .obj(input_refs = record$inputs)
  if (view == "runs") {
    row[c("run_ref", "template_ref", "timing_status")] <- list(receipt$run_ref, receipt$template_ref, timing)
    texts[c("started_at_utc", "ended_at_utc")] <- list(receipt$started_at_utc, receipt$ended_at_utc)
    links["output_refs"] <- list(if (!is.null(receipt)) {
      .arr(lapply(Filter(function(item) identical(item$status, "registered"), receipt$outputs), `[[`, "record_ref"))
    } else NULL)
  }
  for (field in names(texts)) {
    value <- texts[[field]]
    if (!is.null(value) && nchar(value, type = "bytes") > 256L) {
      row$omitted_text_fields <- c(row$omitted_text_fields, list(field))
      value <- NULL
    }
    row[field] <- list(value)
  }
  for (field in names(links)) {
    refs <- links[[field]]
    shown <- NULL
    if (!is.null(refs)) {
      slice <- lapply(refs[seq_len(min(length(refs), 10L))], function(ref) if (is.character(ref)) .ref(state, ref) else ref)
      shown <- .arr(Filter(function(ref) nchar(.json(ref), type = "bytes") <= 512L, slice))
    }
    row[field] <- list(shown)
    row[[paste0(field, "_omitted")]] <- length(refs) - length(shown)
  }
  row
}

.timeline_page <- function(state, dirty, cache, view, order, limit, cursor) {
  if (!is.character(view) || length(view) != 1L || !view %in% c("registration", "runs")) .fail("view must be registration or runs")
  if (!is.character(order) || length(order) != 1L || !order %in% c("oldest", "newest")) .fail("order must be oldest or newest")
  if (!.is_int(limit, TRUE) || limit > 20L) .fail("limit must be an integer from 1 to 20")
  prefix <- paste0(cache$snapshot, ":", view, ":", order, ":")
  offset <- 0L
  if (!is.null(cursor)) {
    if (!is.character(cursor) || length(cursor) != 1L || is.na(cursor) || !startsWith(cursor, prefix)) {
      .fail("stale or invalid timeline cursor; restart paging")
    }
    value <- substring(cursor, nchar(prefix) + 1L)
    if (nchar(value, type = "bytes") > 10L || !grepl("^[0-9]+\\z", value, perl = TRUE)) .fail("invalid timeline cursor offset")
    offset <- as.numeric(value)
  }
  if (is.null(cache[[view]])) cache[[view]] <- .timeline_index(state, view)
  index <- cache[[view]]
  slots <- index[[order]]
  total <- length(slots)
  if (!is.null(cursor) && (offset <= 0L || offset >= total)) .fail("invalid timeline cursor offset")
  rows <- list(); used <- 0L
  for (slot in slots[offset + seq_len(min(limit, total - offset))]) {
    row <- .timeline_row(state, view, index, slot)
    size <- nchar(.json(row), type = "bytes") + 1L
    # Leave room for report metadata and up to 190 pairwise relations.
    if (used + size > .chronology_max_bytes - 12288L) {
      if (!length(rows)) .fail("timeline row exceeds report limit; retrieve the exact record")
      break
    }
    rows[[length(rows) + 1L]] <- row
    used <- used + size
  }
  end <- offset + length(rows)
  report <- .obj(report_version = "biodataledger-timeline/1", view = view, order = order, timezone = "UTC",
                 registry_revision = state$state_revision, unsaved = dirty,
                 imported_claim = if (isTRUE(state$imported)) "untrusted_imported_claim" else NULL,
                 total_rows = total, rows = .arr(rows), relations = if (view == "runs") .chronology_relations(rows) else list(),
                 next_cursor = if (end < total) paste0(prefix, sprintf("%.0f", end)) else NULL)
  if (nchar(.json(report), type = "bytes") > .chronology_max_bytes) .fail("timeline report exceeds 64 KiB")
  report
}

.timeline_ref <- function(ref) paste0(ref$id, "@", sprintf("%.0f", ref$revision))

.timeline_summary <- function(report) {
  runs <- report$view == "runs"
  heading <- if (runs) "Recorded runs by wrapper start" else "Record revisions by registration time"
  lines <- paste0(heading, " (UTC, ", report$order, " first)")
  if (!is.null(report$imported_claim)) lines <- c(lines, "Imported metadata. Receipt claims are untrusted.")
  unknown_heading <- FALSE
  for (number in seq_along(report$rows)) {
    row <- report$rows[[number]]
    stamp <- if (is.null(row$time_utc)) "UNKNOWN" else row$time_utc
    if (is.null(row$time_utc) && !unknown_heading) {
      lines <- c(lines, "Time unknown or unqualified")
      unknown_heading <- TRUE
    }
    name <- if (is.null(row$name)) "[name omitted]" else .json(row$name)
    status <- if (!is.null(row$outcome)) row$outcome else if (identical(row$evidence, "unknown")) "execution UNKNOWN" else row$kind
    line <- paste0("[", number, "] ", stamp, "  ", .timeline_ref(row$ref), "  ", name, "  ", status)
    if (!is.null(row$outcome)) line <- paste0(line, " (", gsub("_", " ", row$evidence), ")")
    lines <- c(lines, line)
    if (runs) {
      if (!is.null(row$run_ref)) lines <- c(lines, paste0("    Run ", .timeline_ref(row$run_ref),
                                                        " | Template ", .timeline_ref(row$template_ref)))
      start <- if (is.null(row$started_at_utc)) "UNKNOWN" else .json(row$started_at_utc)
      end <- if (is.null(row$ended_at_utc)) "UNKNOWN" else .json(row$ended_at_utc)
      lines <- c(lines, paste0("    Wrapper start ", start, " | End ", end, " | ", gsub("_", " ", row$timing_status)))
    } else if (!is.null(row$analysis_ref)) {
      lines <- c(lines, paste0("    Analysis ", .timeline_ref(row$analysis_ref)))
    }
    for (field in c("input_refs", "output_refs")) {
      refs <- row[[field]]
      if (is.null(refs)) next
      label <- if (field == "input_refs") "Declared inputs" else "Registered outputs"
      linked <- if (length(refs)) paste(vapply(refs, .timeline_ref, character(1)), collapse = ", ") else "none shown"
      omitted <- row[[paste0(field, "_omitted")]]
      lines <- c(lines, paste0("    ", label, " ", linked, if (omitted > 0L) paste0(" (", omitted, " omitted)") else ""))
    }
  }
  if (runs) {
    qualified <- Filter(function(pair) pair$relation %in% c("overlap", "tied", "tied_boundary"), report$relations)
    relations <- vapply(qualified, function(pair) paste0(pair$left, "-", pair$right, " ", gsub("_", " ", pair$relation)), character(1))
    if (length(relations)) lines <- c(lines, paste0("Overlaps or ties on this page: ", paste(relations, collapse = ", ")))
    lines <- c(lines, "Wrapper intervals are partial evidence. Unrecorded execution remains unknown.")
  } else {
    lines <- c(lines, "Registration times describe record revisions. Equal times share the same displayed time.")
  }
  paste(c(lines, paste0("Next cursor: ", if (is.null(report$next_cursor)) "none" else report$next_cursor)), collapse = "\n")
}
