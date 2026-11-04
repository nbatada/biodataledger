# Bounded recorded-work lookup; it does not infer scientific equivalence.
.related_work_version <- "biodataledger-related-work/1"
.related_ref_equal <- function(left, right) !is.null(left) && !is.null(right) && identical(left$project_id, right$project_id) && identical(left$id, right$id) && isTRUE(left$revision == right$revision)
.related_clip <- function(value, limit) {
  if (!is.character(value) || length(value) != 1L || is.na(value)) return(list(value = NULL, clipped = FALSE))
  clipped <- nchar(value, type = "chars") > limit
  value <- enc2utf8(substr(value, 1L, limit)); raw <- charToRaw(value)
  if (!clipped && length(raw) <= limit) return(list(value = value, clipped = FALSE))
  raw <- raw[seq_len(limit)]
  decode <- function(bytes) {
    text <- tryCatch(rawToChar(bytes), error = function(e) NA_character_)
    if (is.na(text) || !isTRUE(validUTF8(text)) || is.na(iconv(text, from = "UTF-8", to = "UTF-8", sub = NA))) NA_character_ else text
  }
  for (backoff in 0:3) {
    candidate <- if (backoff == 0L) raw else raw[seq_len(length(raw) - backoff)]
    text <- decode(candidate)
    if (!is.na(text)) return(list(value = text, clipped = TRUE))
  }
  list(value = "", clipped = TRUE)
}
.related_refs <- function(values, limit = 10L) list(values = .arr(lapply(values[seq_len(min(length(values), limit))], .copy)), omitted = max(0L, length(values) - limit))
.related_unique_refs <- function(values) {
  seen <- character(); out <- list()
  for (value in values) {
    key <- paste(value$project_id, value$id, value$revision, sep = "@")
    if (!key %in% seen) { seen <- c(seen, key); out[[length(out) + 1L]] <- value }
  }
  out
}
.related_fields <- function(rec) {
  details <- if (.is_obj(rec$details)) rec$details else list()
  fields <- list(list(field = "name", value = rec$name))
  for (key in c("title", "purpose", "description")) fields[[length(fields) + 1L]] <- list(field = key, value = details[[key]])
  tags <- details[["tags"]]
  if (is.character(tags)) {
    for (tag in utils::head(tags, 32L)) if (is.character(tag) && length(tag) == 1L && !is.na(tag))
      fields[[length(fields) + 1L]] <- list(field = "tags", value = tag)
  } else if (is.list(tags) && is.null(names(tags))) {
    for (tag in utils::head(tags, 32L)) if (is.character(tag) && length(tag) == 1L && !is.na(tag))
      fields[[length(fields) + 1L]] <- list(field = "tags", value = tag)
  }
  fields
}
.related_match <- function(rec, terms) {
  values <- list(); matched <- character(); clipped <- FALSE
  details <- if (.is_obj(rec$details)) rec$details else list()
  tags <- details[["tags"]]
  clipped <- (is.character(tags) || is.list(tags) && is.null(names(tags))) && length(tags) > 32L
  for (item in .related_fields(rec)) {
    value <- .related_clip(item$value, if (identical(item$field, "tags")) 128L else 4096L)
    clipped <- clipped || value$clipped
    if (!is.null(value$value)) values[[length(values) + 1L]] <- list(field = item$field, value = stringi::stri_trans_casefold(value$value))
  }
  for (term in terms) for (item in values) if (grepl(term, item$value, fixed = TRUE)) matched <- c(matched, item$field)
  list(match = all(vapply(terms, function(term) any(vapply(values, function(item) grepl(term, item$value, fixed = TRUE), logical(1))), logical(1))),
       fields = sort(unique(matched), method = "radix"), clipped = clipped)
}
.related_entry <- function(state, graph, rec, basis, get_analysis, get_execution, matched_fields = NULL) {
  ref <- .make_ref(state, rec); input_refs <- if (is.null(rec$inputs)) list(values = NULL, omitted = NULL) else .related_refs(rec$inputs)
  receipt <- get_execution(ref); anchor <- if (!identical(receipt$status, "unknown") && !is.null(receipt$run_ref)) receipt$run_ref else ref
  anchor <- tryCatch(.make_ref(state, .record(state, anchor)), error = function(e) ref)
  links <- .result_dependencies(state, graph, anchor, "downstream", depth = 2L, limit = 100L)
  results <- list(); figures <- list()
  for (edge in links$edges) {
    if (identical(edge$type, "produced_result") && .related_ref_equal(edge$from, anchor)) results[[length(results) + 1L]] <- edge$to
    else if (edge$type %in% c("analytical_association", "rendered_in_figure")) figures[[length(figures) + 1L]] <- edge$to
  }
  result_refs <- .related_refs(.related_unique_refs(results)); figure_refs <- .related_refs(.related_unique_refs(figures)); title <- .related_clip(rec$name, 256L)
  evidence <- .analytical_evidence(rec)
  out <- .obj(ref = ref, artifact_analysis_ref = anchor, record_status = rec$status, title = title$value, match_basis = basis, inputs = input_refs$values,
              results = result_refs$values, figures = figure_refs$values,
              provenance = .obj(relationships = evidence$input_relationships, execution_status = receipt$status,
                                scientific_validity = "unknown", input_consumption = "unknown", equivalence = "unknown"),
              omitted = .obj(inputs = input_refs$omitted, results = result_refs$omitted, figures = figure_refs$omitted,
                             links_incomplete = isTRUE(links$truncated), title = title$clipped))
  if (!is.null(matched_fields)) out$matched_fields <- .arr(matched_fields)
  out
}
.related_work <- function(state, graph, input_ref = NULL, query = NULL, limit = 5L, get_analysis, get_execution, unsaved) {
  if (xor(is.null(input_ref), is.null(query)) != TRUE) .fail("Choose exactly one of input_ref or query")
  if (!.is_int(limit, TRUE) || limit > 20L) .fail("limit must be an integer from 1 to 20")
  metadata_clipped <- FALSE
  if (!is.null(input_ref)) {
    selected <- .record(state, input_ref); if (!identical(selected$kind, "data")) .fail("Not data")
    selected_ref <- .make_ref(state, selected); selector <- .obj(kind = "input_ref", input_ref = selected_ref)
    key <- .result_id(selected_ref); adjacent <- if (exists(key, graph$forward, inherits = FALSE)) get(key, graph$forward) else list()
    bounded_edges <- utils::head(adjacent, 100L)
    search_truncated <- length(adjacent) > 100L
    matched <- lapply(Filter(function(edge) identical(edge$type, "input_to_analysis") && .related_ref_equal(edge$from, selected_ref), bounded_edges), function(edge) .record(state, edge$to))
    entries <- lapply(utils::head(matched, limit), function(rec) .related_entry(state, graph, rec, "exact_input_reference", get_analysis, get_execution))
    active_count <- NULL; inspected <- length(bounded_edges)
  } else {
    if (!is.character(query) || length(query) != 1L || is.na(query) || !nzchar(stringi::stri_trim_both(query))) .fail("query must be nonblank text")
    query_prefix <- enc2utf8(substr(query, 1L, 256L)); if (nchar(query, type = "chars") > 256L || length(charToRaw(query_prefix)) > 256L) .fail("query exceeds 256 UTF-8 bytes")
    query <- query_prefix
    terms <- stringi::stri_split_regex(stringi::stri_trans_casefold(stringi::stri_trim_both(query)), "\\s+")[[1L]]
    selector <- .obj(kind = "query", query = query, terms = .arr(terms)); candidates <- list()
    index <- attr(state, "record_index")$latest
    latest <- lapply(sort(ls(index), method = "radix"), function(id) state$records[[get(id, index)]])
    latest <- Filter(function(rec) identical(rec$kind, "analysis") && identical(rec$status, "active"), latest)
    for (rec in utils::head(latest, 1000L)) {
      found <- .related_match(rec, terms); metadata_clipped <- metadata_clipped || found$clipped
      if (found$match) candidates[[length(candidates) + 1L]] <- list(rec = rec, fields = found$fields)
    }
    matched <- lapply(candidates, `[[`, "rec"); search_truncated <- length(latest) > 1000L
    entries <- lapply(utils::head(candidates, limit), function(candidate) .related_entry(state, graph, candidate$rec, "text_candidate", get_analysis, get_execution, candidate$fields))
    active_count <- length(latest); inspected <- min(length(latest), 1000L)
  }
  uncertain <- search_truncated || metadata_clipped
  report <- .obj(report_version = .related_work_version, selector = selector, registry_revision = state$state_revision, unsaved = unsaved,
    state = .obj(no_match = if (length(matched)) FALSE else if (uncertain) NULL else TRUE,
                 multiple = if (length(matched) > 1L) TRUE else if (uncertain) NULL else FALSE, incomplete = FALSE),
    counts = .obj(active_analysis_records = active_count, inspected_edges = inspected,
                  matched = length(matched), returned = length(entries), omitted = max(0L, length(matched) - length(entries))),
    truncation = .obj(report = FALSE, search = search_truncated, metadata = metadata_clipped,
                      links = any(vapply(entries, function(entry) isTRUE(entry$omitted$links_incomplete), logical(1))),
                      details = any(vapply(entries, function(entry) isTRUE(entry$omitted$title) ||
                        any(vapply(entry$omitted[c("inputs", "results", "figures")], function(n) !is.null(n) && n > 0L, logical(1))), logical(1)))),
    coverage = .obj(relationships = "recorded_only", scientific_validity = "unknown", input_consumption = "unknown", equivalence = "unknown",
                    imported_claims = if (isTRUE(state$imported)) "untrusted" else "not_imported",
                    analysis_scope = if (is.null(input_ref)) "latest_active" else "direct_input_historical_revisions"), analyses = .arr(entries))
  while (nchar(.json(report), type = "bytes") > 4096L && length(report$analyses)) {
    report$analyses[[length(report$analyses)]] <- NULL; report$counts$returned <- report$counts$returned - 1L
    report$counts$omitted <- report$counts$omitted + 1L; report$truncation$report <- TRUE
  }
  report$state$incomplete <- any(unlist(report$truncation, use.names = FALSE)) || report$counts$omitted > 0L
  if (nchar(.json(report), type = "bytes") > 4096L) .fail("related-work report exceeds byte limit")
  report
}
