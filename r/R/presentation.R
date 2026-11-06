.presentation_key <- "biodataledger.presentation"
.presentation_version <- "biodataledger-presentation/1"
.presentation_kinds <- c(data = "D", figure = "F", analysis = "A")
.presentation_outputs <- c("data", "figure")
.presentation_edges <- c("produced_result", "transformation_context", "analytical_association",
                         "parent_data", "artifact_container", "rendered_in_figure", "input_to_figure")
.presentation_detail_bytes <- 16384L
.presentation_lower <- function(x) chartr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", x)

.console_controls <- "[\\p{Cc}\\p{Cf}\\p{Cs}\\p{Zl}\\p{Zp}]"

.console_label <- function(value, width = 72L) {
  label <- stringi::stri_trim_both(stringi::stri_replace_all_regex(value, .console_controls, " "))
  if (stri_width(label) <= width) return(label)
  prefix <- substr(label, 1L, width - 3L)
  while (stri_width(prefix) > width - 3L)
    prefix <- substr(prefix, 1L, nchar(prefix) - 1L)
  paste0(stringi::stri_trim_right(prefix), "...")
}

.console_path <- function(path) {
  if (is.null(path)) return("Unresolved")
  if (!stringi::stri_detect_regex(path, .console_controls)) return(path)
  points <- utf8ToInt(enc2utf8(path))
  chars <- intToUtf8(points, multiple = TRUE)
  control <- stringi::stri_detect_regex(chars, .console_controls)
  chars[chars == "\\"] <- "\\\\"
  chars[control] <- paste0("\\u{", sprintf("%X", points[control]), "}")
  paste0(paste(chars, collapse = ""), " [escaped; see exact getter for raw path]")
}

.console_ref <- function(ref) paste0(ref$id, "@", sprintf("%.0f", ref$revision))

.recent_records <- function(state, kind, active_only = FALSE) {
  latest <- attr(state, "record_index")$latest
  ids <- ls(latest, all.names = TRUE, sorted = FALSE)
  prefix <- if (kind == "analysis") "ANA-" else "FIG-"
  positions <- unlist(mget(ids[startsWith(ids, prefix)], latest, inherits = FALSE), use.names = FALSE)
  records <- state$records[positions]
  if (active_only) {
    keep <- vapply(records, function(rec) rec$status == "active", logical(1))
    positions <- positions[keep]
    records <- records[keep]
  }
  stamps <- vapply(records, "[[", character(1), "created_at")
  unique_stamps <- unique(stamps)
  valid <- vapply(unique_stamps, .timeline_timestamp, logical(1))
  stamps[!valid[match(stamps, unique_stamps)]] <- ""
  # Reverse stored order breaks ties and orders records with unknown dates.
  order <- order(stamps, as.integer(positions), decreasing = TRUE, method = "radix")
  list(records = records[order], stamps = stamps[order])
}

.output_title <- function(rec, descriptor) {
  if (is.null(descriptor$title)) rec$name else descriptor$title
}

.recent_figures <- function(root, state, limit) {
  rows <- .recent_records(state, "figure", active_only = TRUE)
  total <- length(rows$records)
  items <- lapply(seq_len(min(limit, total)), function(i) {
    rec <- rows$records[[i]]; stamp <- rows$stamps[[i]]
    descriptor <- .presentation_read(rec)$descriptor
    path <- .resolve(root, state, rec$locator, lexical = TRUE)
    .obj(name = .output_title(rec, descriptor), ref = .make_ref(state, rec),
         recorded_at = if (nzchar(stamp)) stamp else NULL, generated_on = descriptor$generated_on,
         path = path, directory = if (is.null(path)) NULL else dirname(path),
         availability_checked = FALSE)
  })
  .obj(items = items, total = total, omitted = total - length(items))
}

.recorded_text <- function(stamp) {
  if (is.null(stamp) || !nzchar(stamp)) "Unknown" else sub("T", " ", substr(stamp, 1L, 19L), fixed = TRUE)
}

.recent_figure_lines <- function(report) {
  if (!length(report$items)) return("  None recorded")
  lines <- lapply(report$items, function(item) {
    label <- .console_label(item$name)
    c(paste0("  ", if (nzchar(label)) label else "Unnamed figure"),
      paste0("    ", .console_ref(item$ref), " | Recorded (UTC) ", .recorded_text(item$recorded_at)),
      if (!is.null(item$generated_on)) paste0("    Recorded generation date ", item$generated_on),
      paste0("    File   ", .console_path(item$path)),
      paste0("    Folder ", .console_path(item$directory)))
  })
  c(unlist(lines, use.names = FALSE), if (report$omitted) sprintf("  +%d more figures", report$omitted))
}

.analysis_output_labels <- function(state, graph, rec, width) {
  latest <- attr(state, "record_index")$latest
  exact <- .make_ref(state, rec)
  edges <- c(.result_adjacent(graph, exact, "downstream"),
             get0(.result_id(exact), graph$extra_forward, inherits = FALSE, ifnotfound = list()))
  kinds <- c("produced_result", "transformation_context", "analytical_association")
  edges <- .result_sort_edges(Filter(function(edge) edge$type %in% kinds, edges))
  if (!length(edges)) return("None linked to this revision")
  ids <- vapply(edges, function(edge) edge$to$id, character(1))
  # Edges are ordered by target ID and then ascending target revision.
  linked <- edges[!duplicated(ids, fromLast = TRUE)]
  labels <- character()
  for (edge in utils::head(linked, 2L)) {
    ref <- edge$to
    output <- .record(state, ref)
    label <- .console_label(.output_title(output, .presentation_read(output)$descriptor), width)
    labels <- c(labels, if (nzchar(label)) label else "Unnamed output")
    current <- state$records[[get(ref$id, latest, inherits = FALSE)]]
    flags <- c(if (output$revision != current$revision) "historical",
               if (output$status != "active") output$status)
    if (length(flags)) labels <- c(labels, paste0(.console_ref(ref), " (", paste(flags, collapse = ", "), ")"))
  }
  c(labels, if (length(linked) > 2L) sprintf("+%d more", length(linked) - 2L))
}

.analysis_table <- function(state, graph) {
  rows <- .recent_records(state, "analysis")
  analyses <- utils::head(rows$records, 4L)
  if (!length(analyses)) return("  None recorded")
  refs <- vapply(analyses, .console_ref, character(1))
  outputs <- lapply(analyses, function(rec) .analysis_output_labels(state, graph, rec, 39L))
  widths <- c(19L, max(34L, nchar(refs)), max(39L, stri_width(unlist(outputs, use.names = FALSE))))
  border <- paste0("+", paste(strrep("-", widths + 2L), collapse = "+"), "+")
  row <- function(values) {
    cells <- paste0(values, strrep(" ", widths - stri_width(values)))
    paste0("| ", paste(cells, collapse = " | "), " |")
  }
  lines <- c(border, row(c("Recorded (UTC)", "Ticket / analysis", "Recorded outputs")), border)
  for (i in seq_along(analyses)) {
    rec <- analyses[[i]]
    ticket <- rec$details[["ticket_name"]]
    label <- if (is.character(ticket) && length(ticket) == 1L) .console_label(ticket, widths[2L]) else ""
    if (!nzchar(label)) label <- .console_label(rec$name, widths[2L])
    if (!nzchar(label)) label <- "Unnamed analysis"
    labels <- outputs[[i]]
    n <- max(2L, length(labels))
    dates <- c(.recorded_text(rows$stamps[[i]]), rep("", n - 1L))
    names <- c(label, refs[[i]], rep("", n - 2L))
    labels <- c(labels, rep("", n - length(labels)))
    lines <- c(lines, vapply(seq_len(n), function(j) row(c(dates[[j]], names[[j]], labels[[j]])), character(1)), border)
  }
  c(lines, "Each output shows its latest linked revision for the exact analysis revision in that row.")
}

.console_scope <- function(scope) {
  fields <- character()
  labels <- c(condition_values = "Conditions", assignment_inclusion = "Assignment")
  for (key in names(labels)) {
    values <- scope[[key]]
    if (length(values)) {
      shown <- paste(vapply(utils::head(values, 3L), .console_label, character(1), width = 24L), collapse = ", ")
      if (length(values) > 3L) shown <- paste0(shown, " (+", length(values) - 3L, " more)")
      fields <- c(fields, paste(labels[[key]], shown))
    }
  }
  labels <- c(assay = "Assay", layer = "Layer", observation_unit = "Observation unit", selection = "Selection")
  for (key in names(labels)) {
    width <- if (key == "selection") 64L else 36L
    if (!is.null(scope[[key]])) fields <- c(fields, paste(labels[[key]], .console_label(scope[[key]], width)))
  }
  fields
}

.project_overview <- function(root, state, graph) {
  info <- state$project
  name <- .console_label(info$name)
  purpose <- if (is.null(info$purpose)) "" else .console_label(info$purpose, 160L)
  lines <- c(paste0("BioDataLedger for \u2014 ", if (nzchar(name)) name else "Unnamed project"),
             if (nzchar(purpose)) purpose, "", "Recent analyses", .analysis_table(state, graph), "",
             "Project folder", paste0("  ", .console_path(root)), "", "Current input selections")
  purposes <- attr(state, "record_index")$summary$purposes
  for (purpose in utils::head(purposes, 3L)) {
    rec <- .record(state, state$current[[purpose]])
    path <- .resolve(root, state, rec$locator, lexical = TRUE)
    name <- .console_label(rec$name)
    scope <- .console_scope(rec$scope)
    lines <- c(lines, paste0("  ", .console_label(purpose), " \u2014 ", if (nzchar(name)) name else "Unnamed data"),
               if (length(scope)) paste0("    Recorded scope \u2014 ", paste(scope, collapse = " | ")),
               paste0("    File ", .console_path(path)), paste0("    ", .console_ref(rec)))
  }
  if (!length(purposes)) lines <- c(lines, "  None recorded")
  if (length(purposes) > 3L) lines <- c(lines, sprintf("  +%d more selections", length(purposes) - 3L))
  c(lines, "", "Latest figure by registration (UTC)", .recent_figure_lines(.recent_figures(root, state, 1L)), "",
    "File availability not checked. More: p$help()")
}

.project_help <- function(state, dirty) {
  paste(c("BioDataLedger help",
          paste0("Package version: ", getNamespaceVersion("BioDataLedger"),
                 " | Registry revision: ", state$state_revision, " | Unsaved changes: ", if (dirty) "yes" else "no"),
          "",
          "Project overview         print(p)",
          "Technical status         p$status()",
          'Find a topic             p$find_outputs(topic="QC")',
          'Analysis inputs/outputs  p$get_info("ANA-001@1")',
          'Figure sources and code  p$get_info("FIG-001@1")',
          'Inspect data             p$get_data("DATA-001@1")',
          'Registration history     cat(p$timeline_summary(order="newest"), "\\n")',
          'Recorded runs            cat(p$timeline_summary(view="runs", order="newest"), "\\n")',
          "Recent figures & folders p$recent_figures()",
          'Current input choice     p$get_data(purpose="review")',
          'Full figure file path    p$get_figure("FIG-001@1")$path',
          'Full data file path      p$get_data("DATA-001@1")$path',
          "",
          "Use your project's exact references and recorded purposes.",
          "Registration dates describe registry entries. See recorded runs for wrapper execution evidence.",
          "Full API                 docs/API.md in the BioDataLedger source checkout"), collapse = "\n")
}

.presentation_text <- function(x, limit) {
  is.character(x) && length(x) == 1L && !is.na(x) && nchar(enc2utf8(x), type = "bytes") <= limit &&
    nzchar(stringi::stri_trim_both(x)) && !stringi::stri_detect_regex(x, "\\p{Cc}")
}
.presentation_token <- function(x, limit) {
  is.character(x) && length(x) == 1L && !is.na(x) && nchar(x, type = "bytes") <= limit &&
    grepl("\\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\\z", x, perl = TRUE)
}
.presentation_day <- function(x) {
  if (!.presentation_text(x, 10L) || !grepl("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z", x, perl = TRUE)) return(FALSE)
  parts <- as.integer(strsplit(x, "-", fixed = TRUE)[[1L]])
  y <- parts[1L]; m <- parts[2L]; d <- parts[3L]
  days <- c(31L, 28L + (y %% 4L == 0L && (y %% 100L != 0L || y %% 400L == 0L)), 31L,
            30L, 31L, 30L, 31L, 31L, 30L, 31L, 30L, 31L)
  y >= 1L && m >= 1L && m <= 12L && d >= 1L && d <= days[m]
}
.presentation_use <- function(x) {
  .result_exact(x, c("kind", "document_id", "item_id", "title")) &&
    (identical(x$kind, "slide") || identical(x$kind, "manuscript")) &&
    .presentation_text(x$document_id, 128L) && .presentation_text(x$item_id, 128L) &&
    .presentation_text(x$title, 256L)
}
.presentation_validate <- function(desc) {
  if (!.result_exact(desc, c("version", "primary_topic", "description", "generated_on", "topics",
                             "questions", "uses", "title", "subtitle")) ||
      !identical(desc$version, .presentation_version)) .fail("Invalid presentation descriptor")
  if (!.presentation_token(desc$primary_topic, 64L)) .fail("primary_topic must be an ASCII topic token (max 64)")
  if (!.presentation_token(desc$description, 96L)) .fail("description must be an ASCII filename token (max 96)")
  if (!.presentation_day(desc$generated_on)) .fail("generated_on must be a real YYYY-MM-DD date")
  topics <- desc$topics; questions <- desc$questions; uses <- desc$uses
  if (!.is_arr(topics) || !length(topics) || length(topics) > 8L ||
      !all(vapply(topics, .presentation_token, logical(1), limit = 64L)) ||
      !identical(topics[[1L]], desc$primary_topic) || anyDuplicated(.presentation_lower(unlist(topics)))) .fail("Invalid presentation topics")
  if (!.is_arr(questions) || length(questions) > 8L ||
      !all(vapply(questions, .presentation_text, logical(1), limit = 256L)))
    .fail("Questions must contain up to 8 nonblank strings (256 UTF-8 bytes each)")
  if (!.is_arr(uses) || length(uses) > 8L || !all(vapply(uses, .presentation_use, logical(1))))
    .fail("Uses must contain up to 8 slide/manuscript declarations with document_id, item_id and title")
  for (x in list(desc$title, desc$subtitle)) if (!is.null(x) && !.presentation_text(x, 256L))
    .fail("title/subtitle must be null or nonblank text (256 UTF-8 bytes each)")
  invisible(TRUE)
}
.presentation_read <- function(rec) {
  if (!rec$kind %in% .presentation_outputs) return(list(status = "not_applicable", descriptor = NULL))
  if (!.presentation_key %in% names(rec$details)) return(list(status = "missing", descriptor = NULL))
  desc <- rec$details[[.presentation_key]]
  if (!.is_obj(desc) || !.presentation_text(desc[["version"]], 128L)) return(list(status = "invalid", descriptor = NULL))
  if (!identical(desc$version, .presentation_version)) return(list(status = "unsupported", descriptor = NULL))
  if (!tryCatch(.presentation_validate(desc), error = function(e) FALSE)) return(list(status = "invalid", descriptor = NULL))
  list(status = "declared", descriptor = desc)
}
.presentation_only_change <- function(rec, changes) {
  if (!identical(names(changes), "details") || !.is_obj(changes$details)) return(FALSE)
  after <- rec; after$details <- changes$details
  if (!identical(.presentation_read(after)$status, "declared")) return(FALSE)
  before <- rec$details; after <- after$details
  before[[.presentation_key]] <- NULL; after[[.presentation_key]] <- NULL
  .result_equal(before, after)
}
.presentation_record <- function(state, ref) {
  if (is.character(ref) && length(ref) == 1L && !is.na(ref) &&
      grepl("\\A[DFA][0-9]{3,}r[1-9][0-9]*\\z", ref, perl = TRUE)) {
    prefix <- switch(substr(ref, 1L, 1L), D = "DATA", F = "FIG", A = "ANA")
    ref <- paste0(prefix, "-", sub("r", "@", substring(ref, 2L), fixed = TRUE))
  }
  rec <- .record(state, ref)
  if (!rec$kind %in% names(.presentation_kinds)) .fail("DATA, FIG or ANA reference required")
  rec
}
.presentation_output_key <- function(rec) paste0(.presentation_kinds[[rec$kind]], sub("^[^-]+-", "", rec$id), "r", sprintf("%.0f", rec$revision))
.presentation_project <- function(state) state$project[c("id", "name")]
.set_presentation <- function(state, ref, primary_topic, description, generated_on, optional, reason, update_record) {
  rec <- .presentation_record(state, ref)
  if (!rec$kind %in% .presentation_outputs) .fail("Presentation requires DATA or FIG")
  if (state$records[[get(rec$id, attr(state, "record_index")$latest)]]$revision != rec$revision)
    .fail("set_presentation requires the latest exact revision")
  if (!.presentation_text(reason, 512L)) .fail("Nonblank reason required (max 512 UTF-8 bytes)")
  if (!.presentation_token(primary_topic, 64L)) .fail("primary_topic must be an ASCII topic token (max 64)")
  prior <- .presentation_read(rec)$descriptor
  defaults <- .obj(topics = prior$topics[-1L], questions = prior$questions, uses = prior$uses,
                   title = prior$title, subtitle = prior$subtitle)
  defaults[names(optional)] <- optional
  topics <- defaults$topics; questions <- defaults$questions; uses <- defaults$uses
  if (is.character(topics) && is.null(names(topics))) topics <- .arr(topics)
  if (is.character(questions) && is.null(names(questions))) questions <- .arr(questions)
  if (is.null(topics)) topics <- list()
  if (is.null(questions)) questions <- list()
  if (is.null(uses)) uses <- list()
  if (!.is_arr(topics) || length(topics) > 8L || !all(vapply(topics, .presentation_token, logical(1), limit = 64L)))
    .fail("Topics must contain up to 8 ASCII topic tokens (64 bytes each)")
  tags <- c(list(primary_topic), topics)
  desc <- .obj(version = .presentation_version, primary_topic = primary_topic, description = description,
               generated_on = generated_on, topics = tags[!duplicated(.presentation_lower(unlist(tags)))], questions = questions,
               uses = uses, title = defaults$title, subtitle = defaults$subtitle)
  .presentation_validate(desc)
  exact <- .make_ref(state, rec)
  if (.result_equal(desc, rec$details[[.presentation_key]])) return(exact)
  details <- rec$details; details[[.presentation_key]] <- desc
  update_record(exact, .obj(details = details), reason)
}
.output_name <- function(state, ref) {
  rec <- .presentation_record(state, ref)
  if (!rec$kind %in% .presentation_outputs) .fail("output_name requires DATA or FIG")
  reading <- .presentation_read(rec); desc <- reading$descriptor
  if (!identical(reading$status, "declared")) .fail(paste("Output presentation is", reading$status))
  loc <- rec$locator
  if (is.null(loc) || !loc$kind %in% c("project", "external") || is.null(rec$size))
    .fail("Recorded local file locator required")
  base <- basename(chartr("\\", "/", loc$value))
  suffix <- regexpr("(?i:\\.tar\\.gz)\\z|\\.[A-Za-z0-9]{1,16}\\z", base, perl = TRUE)
  if (suffix[1L] <= 1L || !grepl("[^.]", substr(base, 1L, suffix[1L] - 1L)))
    .fail("Recorded file needs an ordinary extension or .tar.gz")
  key <- .presentation_output_key(rec)
  filename <- paste0(paste(gsub("-", "", desc$generated_on, fixed = TRUE), desc$primary_topic, key,
                           desc$description, sep = "_"), regmatches(base, suffix))
  if (nchar(filename, type = "bytes") > 255L) .fail("Generated filename exceeds 255 bytes")
  c(.copy(desc), .obj(ref = .make_ref(state, rec), project = .presentation_project(state), kind = rec$kind,
                      output_key = key, filename = filename, tag = paste(desc$primary_topic, key, sep = ":")))
}
.presentation_limits <- function(limit, offset) {
  if (!.is_int(limit, TRUE) || limit > 100L || !.is_int(offset) || offset < 0L)
    .fail("Limit must be 1 to 100; offset must be a nonnegative integer")
}
.presentation_page <- function(items, limit, offset) {
  total <- length(items); end <- min(total, offset + as.double(limit))
  .obj(items = if (offset < end) .arr(items[seq.int(offset + 1, end)]) else list(),
       total = total, offset = offset, next_offset = if (end < total) end else NULL,
       truncated = (total > 0L && offset > 0L) || end < total)
}
.presentation_brief <- function(state, rec) {
  name <- .related_clip(rec$name, 192L)
  .obj(ref = .make_ref(state, rec), kind = rec$kind, output_key = .presentation_output_key(rec),
       name = name$value, name_clipped = name$clipped)
}
.presentation_summary <- function(state, rec, reading) {
  c(.presentation_brief(state, rec),
    .obj(record_status = rec$status, presentation_status = reading$status, presentation = .copy(reading$descriptor)))
}
.presentation_record_page <- function(state, refs, limit, offset) {
  result <- .presentation_page(refs, limit, offset)
  result$items <- .arr(lapply(result$items, function(ref) .presentation_brief(state, .record(state, ref))))
  result
}
.find_outputs <- function(state, topic, question, query, kind, document_id, limit, offset, historical) {
  .presentation_limits(limit, offset)
  if (!is.logical(historical) || length(historical) != 1L || is.na(historical)) .fail("historical must be boolean")
  if (!is.null(topic) && !.presentation_token(topic, 64L)) .fail("Topic must be an ASCII topic token")
  if (!is.null(question) && !.presentation_text(question, 256L)) .fail("Question must be nonblank text")
  if (!is.null(query) && !.presentation_text(query, 256L)) .fail("Query must be nonblank text")
  if (!is.null(document_id) && !.presentation_text(document_id, 128L)) .fail("document_id must be nonblank text")
  if (!is.null(kind)) {
    if (!.presentation_text(kind, 6L) || !.presentation_lower(kind) %in% c("data", "fig", "figure")) .fail("Kind must be DATA or FIG")
    kind <- if (.presentation_lower(kind) == "data") "data" else "figure"
  }
  needle <- if (is.null(topic)) NULL else .presentation_lower(topic)
  folded_question <- if (is.null(question)) NULL else stringi::stri_trans_casefold(question)
  terms <- if (is.null(query)) character() else stringi::stri_split_regex(stringi::stri_trans_casefold(stringi::stri_trim_both(query)), "\\s+")[[1L]]
  filtered <- !is.null(topic) || !is.null(question) || !is.null(query) || !is.null(document_id)
  matches_filters <- function(desc) {
    if (is.null(desc)) return(FALSE)
    tags <- .presentation_lower(as.character(desc$topics))
    if (!is.null(topic) && !any(tags == needle | startsWith(tags, paste0(needle, "-")))) return(FALSE)
    if (!is.null(question) && !any(grepl(folded_question, stringi::stri_trans_casefold(as.character(desc$questions)), fixed = TRUE))) return(FALSE)
    if (!is.null(document_id) && !any(vapply(desc$uses, function(u) identical(u$document_id, document_id), logical(1)))) return(FALSE)
    if (length(terms)) {
      fields <- stringi::stri_trans_casefold(unlist(c(desc[c("topics", "questions", "description", "title", "subtitle")],
                           lapply(desc$uses, function(u) u[c("title", "document_id", "item_id")])), use.names = FALSE))
      if (!all(vapply(terms, function(term) any(grepl(term, fields, fixed = TRUE)), logical(1)))) return(FALSE)
    }
    TRUE
  }
  statuses <- .obj(declared = 0L, missing = 0L, invalid = 0L, unsupported = 0L)
  latest <- attr(state, "record_index")$latest
  slots <- if (historical) seq_along(state$records) else unname(unlist(as.list(latest)))
  matches <- vector("list", length(slots)); n <- 0L
  for (i in slots) {
    rec <- state$records[[i]]
    if (!rec$kind %in% .presentation_outputs || (!is.null(kind) && rec$kind != kind)) next
    reading <- .presentation_read(rec)
    statuses[[reading$status]] <- statuses[[reading$status]] + 1L
    if (filtered && !matches_filters(reading$descriptor)) next
    n <- n + 1L
    matches[[n]] <- list(slot = i, id = rec$id, revision = rec$revision, reading = reading,
                        day = if (is.null(reading$descriptor)) 0 else as.integer(gsub("-", "", reading$descriptor$generated_on, fixed = TRUE)))
  }
  matches <- matches[seq_len(n)]
  ordered <- order(-vapply(matches, `[[`, numeric(1), "day"),
                   vapply(matches, `[[`, character(1), "id"),
                   -vapply(matches, `[[`, numeric(1), "revision"), method = "radix")
  result <- .presentation_page(matches[ordered], limit, offset)
  result$items <- .arr(lapply(result$items, function(m) .presentation_summary(state, state$records[[m$slot]], m$reading)))
  c(.obj(project = .presentation_project(state), historical = historical, presentation_status_counts = statuses), result)
}
.presentation_figure_info <- function(state, rec, owner, limit, offset) {
  value <- rec$details[[.figure_sources_key]]
  source_status <- "missing"; descriptor <- NULL
  if (.sources_known(value)) {
    descriptor <- tryCatch(.sources_normalize(state, value), error = function(e) NULL)
    source_status <- if (is.null(descriptor)) "invalid" else "declared"
  } else if (.figure_sources_key %in% names(rec$details)) {
    source_status <- if (.is_obj(value) && is.character(value[["version"]])) "unsupported" else "invalid"
  }
  code <- function(selector) {
    entry <- .record(state, selector$record)$code[[selector$index + 1L]]
    c(.obj(selector = selector), entry, .obj(integrity = "not_checked", availability_checked = FALSE))
  }
  selection <- descriptor$generating_code
  candidates <- .presentation_page(seq_along(owner$code), limit, offset)
  candidates$items <- .arr(lapply(candidates$items, function(i)
    code(.obj(record = .make_ref(state, owner), index = i - 1L, sha256 = owner$code[[i]]$sha256, registered_ref = NULL))))
  rendering <- descriptor$rendering_inputs
  .copy(.obj(
    plotting_code = .obj(status = if (is.null(selection)) "unknown" else "declared", source_status = source_status,
                         generating_code = if (is.null(selection)) NULL else code(selection), candidates = candidates),
    rendering_inputs = c(.obj(status = if (is.null(rendering)) "unknown" else "recorded",
                              relationship = if (is.null(descriptor)) "unknown" else descriptor$relationship),
                         .presentation_record_page(state, rendering, limit, offset))))
}
.presentation_detail <- function(value) {
  if (is.null(value)) return(list(value = NULL, status = "unknown"))
  if (nchar(.json(value), type = "bytes") > .presentation_detail_bytes)
    return(list(value = NULL, status = "size_limit"))
  list(value = .copy(value), status = "included")
}
.get_info <- function(state, graph, ref, limit, offset) {
  .presentation_limits(limit, offset)
  rec <- .presentation_record(state, ref); exact <- .make_ref(state, rec)
  producer <- if (rec$kind == "figure") rec$analysis else rec$scope$transformation_ref
  source <- if (!is.null(producer)) .record(state, producer) else if (rec$kind != "data") rec else NULL
  inputs <- source$inputs
  edges <- c(.result_adjacent(graph, exact, "downstream"),
             get0(.result_id(exact), graph$extra_forward, inherits = FALSE, ifnotfound = list()))
  outputs <- .result_sort_edges(Filter(function(e) e$type %in% .presentation_edges, edges))
  output_page <- .presentation_page(outputs, limit, offset)
  output_page$items <- .arr(lapply(output_page$items, function(edge)
    c(edge, .obj(output = .presentation_brief(state, .record(state, edge$to))))))
  context <- if (is.null(source)) NULL else .obj(
    ref = .make_ref(state, source), code = source$code, method = source$method, params = source$params,
    design = source$design, input_mode = source$input_mode, evidence = .analytical_evidence(source))
  figure <- if (rec$kind == "figure") .presentation_figure_info(state, rec, source, limit, offset)
            else .obj(plotting_code = NULL, rendering_inputs = NULL)
  rec$inputs <- NULL
  recorded <- .presentation_detail(rec); context <- .presentation_detail(context)
  c(.presentation_summary(state, rec, .presentation_read(rec)), figure, .obj(
    project = .presentation_project(state), record = recorded$value, record_fields_status = recorded$status,
    analytical_source = context$value, analytical_source_status = context$status,
    analytical_source_ref = if (is.null(source)) NULL else .make_ref(state, source),
    producer_ref = .copy(producer), producer = if (is.null(producer)) NULL else .presentation_brief(state, source),
    availability_checked = FALSE,
    inputs = c(.obj(status = if (is.null(inputs)) "unknown" else "recorded"),
               .presentation_record_page(state, inputs, limit, offset)),
    outputs = .copy(output_page)))
}
.export_named_output <- function(root, state, ref, destination_dir) {
  if (!identical(Sys.info()[["sysname"]], "Darwin")) .fail("Named output writes currently require macOS")
  report <- .output_name(state, ref); rec <- .record(state, report$ref)
  if (is.null(rec$sha256)) .fail("MISSING_DIGEST: registered SHA-256 required")
  source <- .resolve(root, state, rec$locator)
  if (is.null(source) || !utils::file_test("-f", source)) .fail("Registered source file missing or not a regular file")
  if (!is.character(destination_dir) || length(destination_dir) != 1L || is.na(destination_dir) ||
      !nzchar(destination_dir) || !dir.exists(path.expand(destination_dir))) .fail("Existing destination directory required")
  directory <- normalizePath(path.expand(destination_dir), mustWork = TRUE)
  target <- file.path(directory, report$filename); link <- Sys.readlink(target)
  if (file.exists(target) || (!is.na(link) && nzchar(link))) .fail("Destination exists; overwrite prohibited")
  staging <- tempfile(".bdl-output-", tmpdir = directory)
  if (!dir.create(staging, mode = "0700", showWarnings = FALSE)) .fail("Cannot exclusively create staging directory")
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)
  staged <- file.path(staging, "output")
  if (!isTRUE(suppressWarnings(file.copy(source, staged, overwrite = FALSE, copy.mode = FALSE)))) .fail("Cannot stage named output")
  if (!Sys.chmod(staged, mode = "0600")) .fail("Cannot set staging file permissions")
  observed <- .hash(staged)
  if (!identical(observed, tolower(rec$sha256))) .fail("DIGEST_MISMATCH: copy differs from exact source revision")
  if (!isTRUE(suppressWarnings(file.link(staged, target)))) .fail("Cannot exclusively publish named output")
  .obj(project = report$project, ref = report$ref, path = target, filename = report$filename,
       sha256 = observed, integrity = "match")
}
