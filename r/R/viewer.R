# The viewer uses enough JSON digits to preserve the registry's exact numeric range.
.viewer_json <- function(x) as.character(jsonlite::toJSON(
  x, auto_unbox = TRUE, null = "null", digits = 17L, force = TRUE))
.viewer_bytes <- function(x) nchar(.viewer_json(x), type = "bytes")
.viewer_base64 <- function(x) gsub("\n", "", jsonlite::base64_enc(x), fixed = TRUE)
.viewer_key <- function(ref) paste0(ref$project_id, "/", ref$id, "@", sprintf("%.0f", ref$revision))

.viewer_timeline <- function(timeline, view, remaining) {
  pages <- list(); cursor <- NULL; included <- 0L
  repeat {
    page <- timeline(view = view, order = "oldest", limit = min(remaining, 20L), cursor = cursor)
    cursor <- page$next_cursor
    page$next_cursor <- NULL
    page$has_more <- !is.null(cursor)
    pages[[length(pages) + 1L]] <- page
    count <- length(page$rows)
    included <- included + count
    remaining <- remaining - count
    if (is.null(cursor) || remaining == 0L) break
  }
  .obj(pages = pages, omitted = pages[[1L]]$total_rows - included)
}

.viewer_card <- function(root, state, graph, record, slot, latest) {
  ref <- .make_ref(state, record)
  path <- .resolve(root, state, record$locator, lexical = TRUE)
  stamp <- if (.timeline_timestamp(record$created_at)) record$created_at else NULL
  card <- .obj(ref = ref, key = .viewer_key(ref), kind = record$kind, name = record$name,
               status = record$status, is_latest = latest, stored_order = slot, recorded_at = stamp,
               path = path, directory = if (!is.null(path)) dirname(path) else NULL,
               info = if (record$kind %in% c("data", "analysis", "figure")) .get_info(state, graph, ref, 20L, 0L)
                      else .obj(record = record, availability_checked = FALSE))
  if (.viewer_bytes(card) > 16L * 1024L) {
    card[c("name", "path", "directory", "info")] <- list(NULL)
    card$omission <- "card exceeds 16 KiB"
  }
  card
}

.viewer_metadata <- function(root, state, graph, dirty, timeline, limit) {
  project <- c(state$project[c("id", "name", "purpose")], .obj(root = root))
  omitted_fields <- list()
  for (key in c("name", "purpose", "root")) if (.viewer_bytes(project[[key]]) > 4096L) {
    project[key] <- list(NULL)
    omitted_fields[[length(omitted_fields) + 1L]] <- key
  }
  current <- list(); current_bytes <- 0L
  for (purpose in sort(names(state$current), method = "radix")) {
    item <- .obj(purpose = purpose, ref = .ref(state, state$current[[purpose]]))
    bytes <- .viewer_bytes(item) + 1L
    if (current_bytes + bytes <= 64L * 1024L) {
      current[[length(current) + 1L]] <- item
      current_bytes <- current_bytes + bytes
    }
  }
  total <- length(state$records)
  payload <- .obj(report_version = "biodataledger-view/1",
                  package_version = as.character(getNamespaceVersion("BioDataLedger")), client = "R",
                  captured_at_utc = .now(), project = project, registry_revision = state$state_revision,
                  unsaved = dirty, imported = state$imported,
                  coverage = .obj(total_records = total, included_records = 0L, omitted_records = total,
                                  byte_limit_hit = FALSE, omitted_card_details = 0L,
                                  omitted_project_fields = omitted_fields,
                                  omitted_current = length(state$current) - length(current)),
                  current = current, records = list(),
                  timelines = .obj(registration = .viewer_timeline(timeline, "registration", min(limit, 1000L)),
                                   runs = .viewer_timeline(timeline, "runs", min(limit, 1000L))),
                  previews = .obj())
  used <- .viewer_bytes(payload)
  latest_index <- attr(state, "record_index")$latest
  latest <- vapply(seq_along(state$records), function(i) i == get(state$records[[i]]$id, latest_index), logical(1))
  slots <- c(rev(which(latest)), rev(which(!latest)))
  for (slot in utils::head(slots, limit)) {
    card <- .viewer_card(root, state, graph, state$records[[slot]], slot, latest[[slot]])
    used <- used + .viewer_bytes(card) + 1L
    if (used > 16L * 1024L * 1024L - 1024L) {
      payload$coverage$byte_limit_hit <- TRUE
      break
    }
    payload$records[[length(payload$records) + 1L]] <- card
    payload$coverage$omitted_card_details <- payload$coverage$omitted_card_details + !is.null(card$omission)
  }
  payload$coverage$included_records <- length(payload$records)
  payload$coverage$omitted_records <- total - length(payload$records)
  if (.viewer_bytes(payload) > 16L * 1024L * 1024L) .fail("viewer metadata exceeds 16 MiB")
  payload
}

.viewer_preview_records <- function(state, refs) {
  if (is.null(refs)) return(.obj())
  if (is.character(refs)) refs <- as.list(refs)
  message <- "preview_refs requires up to 10 exact FIG refs"
  if (!.is_arr(refs) || length(refs) > 10L) .fail(message)
  selected <- .obj()
  for (ref in refs) {
    if (is.character(ref) && length(ref) == 1L && !is.na(ref)) {
      if (!grepl("^FIG-[0-9]{3,}@[1-9][0-9]{0,15}\\z", ref, perl = TRUE)) .fail(message)
      bits <- strsplit(ref, "@", fixed = TRUE)[[1L]]
      ref <- .obj(project_id = state$project$id, id = bits[[1L]], revision = as.numeric(bits[[2L]]))
    }
    if (!.is_obj(ref) || !setequal(names(ref), c("project_id", "id", "revision")) ||
        length(ref) != 3L || !.is_uuid(ref$project_id) || !is.character(ref$id) || length(ref$id) != 1L ||
        !grepl("^FIG-[0-9]{3,}\\z", ref$id, perl = TRUE) || !.is_int(ref$revision, TRUE)) .fail(message)
    selected[.viewer_key(ref)] <- list(if (identical(ref$project_id, state$project$id)) .lookup_record(state, ref) else NULL)
  }
  selected
}

.viewer_mime <- function(bytes) {
  prefix <- function(expected, start = 1L) {
    end <- start + length(expected) - 1L
    length(bytes) >= end && identical(bytes[start:end], expected)
  }
  if (prefix(as.raw(c(137, 80, 78, 71, 13, 10, 26, 10)))) return("image/png")
  if (prefix(as.raw(c(255, 216, 255)))) return("image/jpeg")
  if (prefix(charToRaw("GIF87a")) || prefix(charToRaw("GIF89a"))) return("image/gif")
  if (prefix(charToRaw("RIFF")) && prefix(charToRaw("WEBP"), 9L)) return("image/webp")
  if (any(bytes == as.raw(0))) return(NULL)
  text <- rawToChar(bytes)
  if (!stringi::stri_enc_isutf8(text)) return(NULL)
  Encoding(text) <- "UTF-8"
  text <- sub("^\ufeff", "", text, perl = TRUE)
  if (grepl("^[ \\t\\r\\n]*<(svg([[:space:]>/]|$)|\\?xml([[:space:]?]|$)|!DOCTYPE[[:space:]])", text, perl = TRUE))
    return("image/svg+xml")
  NULL
}

.viewer_read_preview <- function(root, state, record, remaining) {
  omitted <- function(status, reason) .obj(preview = .obj(status = status, reason = reason), size = 0L)
  if (is.null(record)) return(omitted("unresolved", "Exact figure revision is unavailable"))
  sha <- record$sha256
  if (is.null(sha)) return(omitted("unsupported", "Recorded SHA-256 is required"))
  path <- tryCatch(.resolve(root, state, record$locator, lexical = TRUE), error = function(e) NULL)
  if (is.null(path)) return(omitted("unresolved", "No safe local figure path"))
  if (!file.exists(path)) return(omitted("missing", "Figure file is missing or unreadable"))
  real <- normalizePath(path, mustWork = FALSE)
  binding <- state$bindings[[paste0(record$locator$kind, ":", record$locator$value)]]
  relative <- if (is.null(binding)) record$locator$kind == "project" else !startsWith(binding, "/")
  if (relative && !startsWith(real, paste0(root, "/")))
    return(omitted("unresolved", "No safe local figure path"))
  # R's file.info cannot distinguish FIFOs/devices from regular files.
  if (system2("/bin/test", c("-f", shQuote(real)), stdout = FALSE, stderr = FALSE) != 0L)
    return(omitted("unsupported", "Preview source must be a regular file"))
  limit <- min(remaining, 2L * 1024L * 1024L)
  size <- file.info(real, extra_cols = FALSE)$size
  if (is.na(size)) return(omitted("missing", "Figure file is missing or unreadable"))
  if (size > limit) return(omitted("oversize", "Preview byte budget exceeded"))
  bytes <- tryCatch({
    stream <- file(real, open = "rb", blocking = FALSE, raw = TRUE)
    on.exit(close(stream))
    readBin(stream, "raw", n = limit + 1L)
  }, warning = function(e) NULL, error = function(e) NULL)
  if (is.null(bytes)) return(omitted("missing", "Figure file is missing or unreadable"))
  if (length(bytes) > limit) return(omitted("oversize", "Preview byte budget exceeded"))
  if (.hash_raw(bytes) != tolower(sha)) return(omitted("tampered", "Figure bytes differ from the recorded SHA-256"))
  mime <- .viewer_mime(bytes)
  if (is.null(mime)) return(omitted("unsupported", "Preview requires PNG, JPEG, GIF, WebP, or UTF-8 SVG"))
  .obj(preview = .obj(status = "included", mime = mime, base64 = .viewer_base64(bytes),
                     digest = tolower(sha)), size = length(bytes))
}

.viewer_render <- function(payload) {
  path <- system.file("viewer.html", package = "BioDataLedger", mustWork = TRUE)
  template <- rawToChar(readBin(path, "raw", n = file.info(path)$size))
  replace <- function(marker, replacement) {
    if (length(gregexpr(marker, template, fixed = TRUE)[[1L]]) != 1L ||
        !grepl(marker, template, fixed = TRUE)) .fail("invalid installed viewer template")
    sub(marker, replacement, template, fixed = TRUE)
  }
  hash <- function(tag, id) {
    pattern <- paste0("(?s)<", tag, ' id="bdl-', id, '">(.*?)</', tag, ">")
    body <- regmatches(template, regexec(pattern, template, perl = TRUE))[[1L]]
    if (length(body) != 2L) .fail("invalid installed viewer template")
    .viewer_base64(digest::digest(charToRaw(body[[2L]]), algo = "sha256", serialize = FALSE, raw = TRUE))
  }
  template <- replace("__BDL_SCRIPT_HASH__", hash("script", "app"))
  template <- replace("__BDL_STYLE_HASH__", hash("style", "style"))
  bytes <- charToRaw(replace("__BDL_PAYLOAD_BASE64__", .viewer_base64(charToRaw(enc2utf8(.viewer_json(payload))))))
  if (length(bytes) > 32L * 1024L * 1024L) .fail("viewer HTML exceeds 32 MiB; lower limit or omit previews")
  bytes
}

.viewer_launch <- function(path) {
  url <- paste0("file://", gsub("%2F", "/", utils::URLencode(path, reserved = TRUE, repeated = TRUE), fixed = TRUE))
  system2("/usr/bin/open", shQuote(url), stdout = FALSE, stderr = FALSE) == 0L
}

.export_view <- function(root, state, graph, dirty, timeline, generation, path, open_browser, limit, preview_refs) {
  if (!identical(Sys.info()[["sysname"]], "Darwin")) .fail("viewer writes currently require macOS")
  if (!is.logical(open_browser) || length(open_browser) != 1L || is.na(open_browser)) .fail("open_browser must be boolean")
  if (!.is_int(limit, TRUE) || limit > 5000L) .fail("limit must be an integer from 1 to 5000")
  initial <- generation()
  selected <- .viewer_preview_records(state, preview_refs)
  payload <- .viewer_metadata(root, state, graph, dirty, timeline, limit)
  remaining <- 8L * 1024L * 1024L
  for (key in names(selected)) {
    result <- .viewer_read_preview(root, state, selected[[key]], remaining)
    payload$previews[[key]] <- result$preview
    remaining <- remaining - result$size
  }
  .finite_tree(payload)
  bytes <- .viewer_render(payload)
  private <- is.null(path)
  published <- FALSE
  if (private) {
    folder <- tempfile("biodataledger-view-", tmpdir = dirname(tempdir()))
    if (!dir.create(folder, mode = "0700")) .fail("cannot create private viewer directory")
    on.exit(if (!published) unlink(folder, recursive = TRUE), add = TRUE)
    path <- file.path(folder, "project.html")
  } else {
    if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) .fail("viewer path must be a file path")
    path <- path.expand(path)
    if (!startsWith(path, "/")) path <- file.path(root, path)
  }
  parent <- normalizePath(dirname(path), mustWork = TRUE)
  target <- file.path(parent, basename(path))
  exists <- function() file.exists(target) || isTRUE(nzchar(Sys.readlink(target), keepNA = TRUE))
  if (exists()) .fail("destination exists; overwrite prohibited")
  staging <- tempfile(".bdl-view-", tmpdir = parent)
  if (!dir.create(staging, mode = "0700")) .fail("cannot stage viewer snapshot")
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)
  staged <- file.path(staging, "project.html")
  writeBin(bytes, staged)
  if (!Sys.chmod(staged, "0600", use_umask = FALSE)) .fail("cannot set viewer snapshot permissions")
  if (!identical(initial, generation())) .fail("loaded project changed during viewer export; retry")
  if (!suppressWarnings(file.link(staged, target))) {
    if (exists()) .fail("destination exists; overwrite prohibited")
    .fail("cannot exclusively publish viewer snapshot")
  }
  published <- TRUE
  launch_error <- NULL
  if (open_browser) launch_error <- tryCatch({
    result <- .viewer_launch(target)
    if (identical(result, FALSE)) "Default browser launch request was unsuccessful" else NULL
  }, warning = function(w) paste("Default browser launch failed:", conditionMessage(w)),
     error = function(e) paste("Default browser launch failed:", conditionMessage(e)))
  previews <- payload$previews
  for (key in names(previews)) previews[[key]]$base64 <- NULL
  .obj(path = target, captured_at_utc = payload$captured_at_utc, coverage = payload$coverage,
       preview_results = previews, browser_open_requested = open_browser, launch_error = launch_error)
}
