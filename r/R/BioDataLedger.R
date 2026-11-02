.obj <- function(...) { x <- list(...); if (!length(x)) names(x) <- character(); x }
.arr <- function(x = list()) unname(as.list(x))
.uuid <- function() as.character(uuid::UUIDgenerate())
.now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
.fail <- function(message) stop(message, call. = FALSE)
.copy <- function(x) unserialize(serialize(x, NULL))
.json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE))
.read_json <- function(path) {
  bytes <- readBin(path, "raw", n = file.info(path)$size)
  text <- rawToChar(bytes)
  if (!jsonlite::validate(text)) .fail("Invalid JSON")
  .reject_duplicate_keys(text)
  jsonlite::fromJSON(text, simplifyVector = FALSE)
}
.reject_duplicate_keys <- function(text) {
  chars <- strsplit(text, "", fixed = TRUE)[[1]]
  stack <- list(); expecting <- FALSE; i <- 1L; n <- length(chars)
  while (i <= n) {
    ch <- chars[i]
    if (ch == '"') {
      j <- i + 1L; escaped <- FALSE
      while (j <= n) {
        if (chars[j] == '"' && !escaped) break
        if (chars[j] == "\\" && !escaped) escaped <- TRUE else escaped <- FALSE
        j <- j + 1L
      }
      if (j > n) .fail("Invalid JSON string")
      if (length(stack) && identical(stack[[length(stack)]]$type, "object") && expecting) {
        key <- jsonlite::fromJSON(paste0(chars[i:j], collapse = ""))
        k <- j + 1L; while (k <= n && chars[k] %in% c(" ", "\n", "\r", "\t")) k <- k + 1L
        if (k <= n && chars[k] == ":") {
          if (key %in% stack[[length(stack)]]$keys) .fail("Duplicate JSON key")
          stack[[length(stack)]]$keys <- c(stack[[length(stack)]]$keys, key)
          expecting <- FALSE
        }
      }
      i <- j
    } else if (ch == "{") {stack[[length(stack) + 1L]] <- list(type = "object", keys = character()); expecting <- TRUE
    } else if (ch == "[") {stack[[length(stack) + 1L]] <- list(type = "array", keys = character()); expecting <- FALSE
    } else if (ch %in% c("}", "]")) {stack[[length(stack)]] <- NULL; expecting <- FALSE
    } else if (ch == "," && length(stack)) expecting <- identical(stack[[length(stack)]]$type, "object")
    i <- i + 1L
  }
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
.ref <- function(state, x) {
  if (is.character(x) && length(x) == 1L) {
    if (!grepl("^(DATA|ANA|FIG|DEC|DES)-[0-9]{3,}@[1-9][0-9]*$", x)) .fail("Exact revision required")
    bits <- strsplit(x, "@", fixed = TRUE)[[1]]; x <- .obj(project_id = state$project$id, id = bits[1], revision = as.integer(bits[2]))
  }
  .validate_ref_shape(state, x)
  if (!any(vapply(state$records, function(r) identical(r$id, x$id) && r$revision == x$revision, logical(1)))) .fail("Dangling reference")
  x
}
.record <- function(state, ref) {
  ref <- .ref(state, ref)
  state$records[[which(vapply(state$records, function(r) identical(r$id, ref$id) && r$revision == ref$revision, logical(1)))[1]]]
}
.next_id <- function(state, kind) {
  prefix <- switch(kind, data = "DATA", analysis = "ANA", figure = "FIG", decision = "DEC", design = "DES")
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
.is_sha <- function(x) is.character(x) && length(x) == 1L && grepl("^[0-9a-fA-F]{64}$", x)
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
.validate <- function(state) {
  .finite_tree(state)
  if (!.is_arr(state$records) || !.is_arr(state$history)) .fail("Records and history must be arrays")
  if (is.null(names(state$current)) || is.null(names(state$bindings))) .fail("Current and bindings must be objects")
  required <- c("schema_version","project","state_revision","last_transaction","records","current","bindings","history","imported")
  if (!setequal(names(state), required) || !state$schema_version %in% c("0.1.0", "0.2.0")) .fail("Unsupported state schema")
  if (!.is_int(state$state_revision, TRUE) || !.is_uuid(state$last_transaction)) .fail("Invalid state revision or transaction")
  project_fields <- c("id","name","purpose","raw_dir","metadata","next_task","questions","authorities")
  if (!.is_obj(state$project) || !setequal(names(state$project), project_fields) && !(identical(state$schema_version, "0.2.0") && setequal(names(state$project), c(project_fields, "design")))) .fail("Invalid project fields")
  if (!.is_uuid(state$project$id) || !is.character(state$project$name) || length(state$project$name) != 1L || !nzchar(state$project$name) || !.is_arr(state$project$questions) || !.is_arr(state$project$authorities)) .fail("Invalid project identity or arrays")
  for (field in c("purpose", "next_task")) if (!is.null(state$project[[field]]) && (!is.character(state$project[[field]]) || length(state$project[[field]]) != 1L)) .fail("Invalid project text")
  for (field in c("raw_dir", "metadata")) if (!is.null(state$project[[field]])) .validate_locator(state$project[[field]])
  if (!is.logical(state$imported) || length(state$imported) != 1L || is.na(state$imported)) .fail("Invalid import flag")
  for (value in state$bindings) if (!is.character(value) || length(value) != 1L || (!startsWith(value, "/") && !.safe_rel(value))) .fail("Invalid binding")
  if (!is.null(state$project$design) && .record_kind(state, state$project$design) != "design") .fail("Project design must reference design")
  keys <- character(); kinds <- c(DATA = "data", ANA = "analysis", FIG = "figure", DEC = "decision", DES = "design")
  fields <- c("kind","id","revision","name","created_at","locator","role","type","sha256","size","inputs","analysis","code","method","params","details","status","foreign_refs")
  for (r in state$records) {
    allowed_fields <- if (identical(state$schema_version, "0.2.0") && r$kind %in% c("analysis", "figure")) c(fields, "design") else fields
    if (!.is_obj(r) || !setequal(names(r), fields) && !setequal(names(r), allowed_fields) || !grepl("^(DATA|ANA|FIG|DEC|DES)-[0-9]{3,}$", r$id) || !identical(kinds[[sub("-.*", "", r$id)]], r$kind) || !.is_int(r$revision, TRUE) || !r$status %in% c("active","superseded","inactive")) .fail("Invalid record")
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
    key <- paste(r$id, r$revision); if (key %in% keys) .fail("Duplicate record version"); keys <- c(keys, key)
    if (!is.null(r$locator)) .validate_locator(r$locator)
    if (!is.null(r$inputs)) for (x in r$inputs) if (.record_kind(state, x) != "data") .fail("Input must reference data")
    if (!is.null(r$analysis) && .record_kind(state, r$analysis) != "analysis") .fail("Figure analysis must reference analysis")
    if (r$kind == "figure" && !is.null(r$analysis) && !is.null(r$design)) .fail("Linked figure cannot store a design reference")
    if (r$kind == "figure" && !is.null(r$analysis) && "design" %in% names(r)) .fail("Linked figure inherits its analysis design")
    if (!is.null(r$design) && .record_kind(state, r$design) != "design") .fail("Record design must reference design")
    if (r$kind == "design") {
      if (!identical(state$schema_version, "0.2.0") || r$id != "DES-001") .fail("Invalid design record identity")
      .validate_design_details(state, r$details)
    }
    for (field in c("parent","membership")) if (!is.null(r$details[[field]]) && .record_kind(state, r$details[[field]]) != "data") .fail("Selection reference must be data")
    if (!is.null(r$details$clustering_run) && .record_kind(state, r$details$clustering_run) != "analysis") .fail("Clustering run must be analysis")
  }
  for (x in state$current) if (.record_kind(state, x) != "data") .fail("Current must reference data")
  for (h in state$history) {
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
    writeBin(charToRaw(.json(state)), temp)
    if (!file.rename(temp, path)) .fail("Cannot publish initial registry")
    open(root)
  }
  open <- function(project_dir) {
    root <- normalizePath(project_dir, mustWork = TRUE); path <- file.path(root, ".nb_project_bundle", "project.json")
    if (!file.exists(path)) .fail("Project registry missing")
    state <- .read_json(path); .validate(state)
    loaded_digest <- .hash(path); loaded_revision <- state$state_revision
    pending_code <- list(); dirty <- FALSE
    event <- function(action, reason = NULL, target = NULL) {
      state$history[[length(state$history) + 1L]] <<- .obj(at = .now(), action = action, actor = "local", reason = reason, target = target, transaction = NULL)
      dirty <<- TRUE
    }
    view <- function(rec) {
      p <- .resolve(root, state, rec$locator)
      out <- .copy(rec); out$ref <- .make_ref(state, rec); out$path <- p
      out$available <- !is.null(p) && !identical(rec$locator$kind, "uri") && file.exists(p)
      out
    }
    append_record <- function(rec, action) {
      proposed <- .copy(state)
      proposed$records[[length(proposed$records) + 1L]] <- rec
      .validate(proposed)
      state <<- proposed
      ref <- .make_ref(state, rec); event(action, target = ref); ref
    }
    validate_details <- function(details) {
      if (is.null(details$provenance)) details$provenance <- .obj(file = "unknown", analytical = "declared")
      details
    }
    install_code <- function(rec) {
      if (!length(rec$code)) return()
      for (entry in rec$code) if (!is.null(entry$snapshot)) {
        source <- .resolve(root, state, entry$locator)
        bytes <- readBin(source, "raw", n = file.info(source)$size)
        if (.hash_raw(bytes) != entry$sha256) .fail("Code changed during registration")
        pending_code[[entry$snapshot]] <<- bytes
      }
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
    register_analysis <- function(name, inputs, code = NULL, method = NULL, params = NULL, snapshot_code = TRUE, ...) {
      if (!is.null(inputs)) inputs <- .arr(lapply(inputs, function(x) {r <- .ref(state, x); if (.record_kind(state, r) != "data") .fail("Analysis inputs must be data"); r}))
      entries <- .code_entries(root, code, snapshot_code)
      rec <- .new_record(state, "analysis", name, inputs = inputs, code = entries, method = method, params = params, details = validate_details(.obj(...)), design = state$project$design)
      install_code(rec); append_record(rec, "register_analysis")
    }
    register_figure <- function(path, type, analysis = NULL, name = NULL, inputs = NULL, code = NULL, method = NULL, params = NULL, snapshot_code = TRUE, ...) {
      loc <- .locator(root, path); p <- .resolve(root, state, loc)
      if (is.null(p) || dir.exists(p)) .fail("Figure must be a local regular file")
      if (!is.null(analysis)) {
        analysis <- .ref(state, analysis)
        if (.record_kind(state, analysis) != "analysis") .fail("Figure analysis must reference analysis")
        if (!is.null(inputs) || !is.null(code) || !is.null(method) || !is.null(params)) .fail("Direct analytical fields conflict with analysis")
      }
      if (!is.null(inputs)) inputs <- .arr(lapply(inputs, function(x) {r <- .ref(state, x); if (.record_kind(state, r) != "data") .fail("Figure inputs must be data"); r}))
      entries <- .code_entries(root, code, snapshot_code)
      details <- validate_details(.obj(...)); details$format <- tolower(tools::file_ext(p)); details$provenance$file <- "captured"
      design <- if (is.null(analysis)) state$project$design else NULL
      rec <- .new_record(state, "figure", if (is.null(name)) tools::file_path_sans_ext(basename(p)) else name, loc, type = type, sha256 = .hash(p), size = file.info(p)$size, inputs = inputs, analysis = analysis, code = entries, method = method, params = params, details = details, design = design)
      install_code(rec); append_record(rec, "register_figure")
    }
    get_data <- function(ref = NULL, role = NULL, purpose = NULL) {
      if (sum(!vapply(list(ref, role, purpose), is.null, logical(1))) != 1L) .fail("Choose exactly one selector")
      if (!is.null(purpose)) {ref <- state$current[[purpose]]; if (is.null(ref)) .fail("No current data for purpose")}
      if (!is.null(ref)) {rec <- .record(state, ref); if (rec$kind != "data") .fail("Not data"); return(view(rec))}
      candidates <- Filter(function(r) r$kind == "data" && identical(r$role, role), state$records)
      latest <- lapply(split(candidates, vapply(candidates, function(r) r$id, character(1))), function(rs) rs[[which.max(vapply(rs, function(r) r$revision, numeric(1)))]])
      latest <- Filter(function(r) identical(r$status, "active"), latest)
      if (length(latest) != 1L) .fail("Role selector is missing or ambiguous")
      view(latest[[1]])
    }
    get_figure <- function(ref) {
      rec <- .record(state, ref); if (rec$kind != "figure") .fail("Not figure")
      out <- view(rec)
      design_ref <- if (is.null(rec$analysis)) rec$design else .record(state, rec$analysis)$design
      out$design_ref <- .copy(design_ref); out$design <- if (is.null(design_ref)) NULL else get_design(design_ref)
      if (!is.null(rec$analysis)) {
        a <- .record(state, rec$analysis)
        out$inputs <- .copy(a$inputs); out$code <- .copy(a$code); out$method <- a$method; out$params <- .copy(a$params)
      }
      out$analysis_details <- if (is.null(rec$analysis)) .copy(rec$details) else .copy(.record(state, rec$analysis)$details)
      out$analysis_details$provenance$file <- NULL # Analysis context is not the figure file.
      analytical_source <- if (is.null(rec$analysis)) rec else .record(state, rec$analysis)
      out$provenance <- .obj(figure_file = if (is.null(rec$details$provenance$file)) "unknown" else rec$details$provenance$file,
                             analytical = if (is.null(analytical_source$details$provenance$analytical)) "unknown" else analytical_source$details$provenance$analytical,
                             execution = "unknown")
      out$unknown <- .arr(c(if (is.null(out$inputs)) "inputs", if (is.null(out$method)) "method", if (is.null(out$params)) "params", if (!length(out$code)) "code"))
      out$input_availability <- if (is.null(out$inputs)) NULL else .arr(lapply(out$inputs, function(x) .obj(ref = x, available = isTRUE(get_data(ref = x)$available))))
      out$code_availability <- .arr(lapply(out$code, function(x) {
        key <- paste0(x$locator$kind, ":", x$locator$value)
        p <- if (!is.null(state$bindings[[key]])) .resolve(root, state, x$locator) else if (!is.null(x$snapshot)) .resolve(root, state, .obj(kind = "project", value = x$snapshot)) else .resolve(root, state, x$locator)
        .obj(reference = x, path = p, available = !is.null(p) && file.exists(p))
      }))
      out$source_code_availability <- .arr(lapply(out$code_availability, function(x) x$available))
      out
    }
    get_analysis <- function(ref) {
      rec <- .record(state, ref); if (rec$kind != "analysis") .fail("Not analysis")
      out <- view(rec); out$design_ref <- .copy(rec$design); out$design <- if (is.null(rec$design)) NULL else get_design(rec$design)
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
      proposed <- .copy(state); proposed$schema_version <- "0.2.0"
      proposed$records[[length(proposed$records) + 1L]] <- rec
      proposed$project$design <- .make_ref(proposed, rec)
      .validate(proposed)
      state <<- proposed; event("set_design", reason = selection_reason, target = proposed$project$design)
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
      if (.hash(path) != loaded_digest || .read_json(path)$state_revision != loaded_revision) .fail("Stale project state")
      proposed <- .copy(state); proposed$state_revision <- state$state_revision + 1L; proposed$last_transaction <- .uuid()
      for (i in seq_along(proposed$history)) if (is.null(proposed$history[[i]]$transaction)) proposed$history[[i]]$transaction <- proposed$last_transaction
      .validate(proposed)
      for (dest in names(pending_code)) {
        bytes <- pending_code[[dest]]; target <- file.path(root, dest); dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
        if (file.exists(target)) {if (.hash(target) != basename(target)) .fail("Snapshot digest conflict")}
        else {if (.hash_raw(bytes) != basename(target)) .fail("Snapshot bytes changed"); writeBin(bytes, target)}
      }
      temp <- tempfile("project-", tmpdir = folder); con <- file(temp, "wb")
      writeBin(charToRaw(.json(proposed)), con); flush(con); close(con)
      on.exit(if (file.exists(temp)) unlink(temp), add = TRUE)
      if (isTRUE(getOption("BioDataLedger.inject_save_before_rename"))) .fail("Injected save failure before publication")
      if (!file.rename(temp, path)) .fail("Atomic replacement failed")
      state <<- proposed; loaded_digest <<- .hash(path); loaded_revision <<- state$state_revision; pending_code <<- list(); dirty <<- FALSE
      .obj(state_revision = state$state_revision, transaction = state$last_transaction)
    }
    set_current <- function(ref, purpose, reason) {
      if (length(state$project$authorities)) .fail("Adopted authority makes current pointer reference-only")
      if (!is.character(purpose) || !nzchar(purpose) || !is.character(reason) || !nzchar(reason)) .fail("Purpose and reason required")
      ref <- .ref(state, ref); if (.record_kind(state, ref) != "data") .fail("Current must be data")
      state$current[[purpose]] <<- ref; event("set_current", reason, ref); invisible(ref)
    }
    set_context <- function(changes) {
      allowed <- c("purpose","questions","next_task","raw_dir","metadata","authorities")
      if (!.is_obj(changes) || !all(names(changes) %in% allowed)) .fail("Unsupported context field")
      proposed <- .copy(state)
      for (key in names(changes)) {
        value <- .copy(changes[[key]])
        if (key %in% c("raw_dir", "metadata")) value <- .context_locator(root, value)
        proposed$project[key] <- list(value)
      }
      .validate(proposed)
      state <<- proposed
      event("set_context"); invisible(NULL)
    }
    update_record <- function(ref, changes, reason) {
      rec <- .record(state, ref)
      if (rec$kind == "design") .fail("Use set_design to revise design")
      allowed <- c("name", "status", "details", "method", "params", "inputs", "code", "foreign_refs", "path")
      if (!is.character(reason) || !nzchar(reason)) .fail("Reason required")
      if (!.is_obj(changes) || !length(changes) || !all(names(changes) %in% allowed)) .fail("Unsupported record correction")
      new <- .copy(rec); new$revision <- max(vapply(Filter(function(r) r$id == rec$id, state$records), function(r) r$revision, numeric(1))) + 1L
      if (!is.null(changes$path)) {
        if (!rec$kind %in% c("data", "figure")) .fail("Path correction needs file record")
        loc <- .locator(root, changes$path); file <- .resolve(root, state, loc)
        if (is.null(file) || !file.exists(file) || dir.exists(file)) .fail("New revision file missing")
        new$locator <- loc; new$sha256 <- .hash(file); new$size <- as.numeric(file.info(file)$size)
      }
      new$created_at <- .now()
      for (key in setdiff(names(changes), "path")) new[key] <- list(.copy(changes[[key]]))
      out <- append_record(new, "update_record"); state$history[[length(state$history)]]$reason <<- reason; out
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
      latest <- list()
      for (rec in state$records) if (is.null(latest[[rec$id]]) || rec$revision > latest[[rec$id]]$revision) latest[[rec$id]] <- rec
      counts <- .obj(data = 0L, analysis = 0L, figure = 0L)
      for (rec in latest) if (rec$kind %in% names(counts)) counts[[rec$kind]] <- counts[[rec$kind]] + 1L
      .obj(state_revision = state$state_revision, unsaved = dirty, records = length(state$records), current = .copy(state$current), next_task = state$project$next_task, design = get_design(), counts = counts)
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
    summary_text <- function() {
      clip <- function(x) {
        if (is.null(x)) return("unknown")
        if (is.list(x)) x <- unlist(x, use.names = FALSE)
        if (length(x) != 1L) x <- if (!length(x)) "none" else paste0(paste(head(x, 8L), collapse = ", "), if (length(x) > 8L) ", ..." else "")
        x <- gsub("[\r\n\t]", " ", as.character(x))
        if (nchar(x, type = "chars") > 160L) paste0(substr(x, 1L, 160L), "...") else x
      }
      d <- get_design(); counts <- summary()$counts
      lines <- c(paste0("BioDataLedger: ", clip(state$project$name)), "Purpose:", paste0("  ", clip(state$project$purpose)), "Experimental design:")
      if (is.null(d)) lines <- c(lines, "  not configured") else {
        levels <- unlist(d$levels, use.names = FALSE); selected <- unlist(d$selected_levels, use.names = FALSE)
        excluded <- levels[!levels %in% selected]
        values <- list(Condition = d$condition, Levels = levels, `Selected levels` = selected, Reference = d$reference_level, Replicate = d$replicate, Excluded = excluded, Reason = d$selection_reason, `Design revision` = d$ref$revision)
        lines <- c(lines, vapply(names(values), function(label) paste0("  ", sprintf("%-18s", paste0(label, ":")), clip(values[[label]])), character(1)))
      }
      paste(c(lines, "Project:", sprintf("  Data:             %d registered datasets", counts$data), sprintf("  Analyses:         %d", counts$analysis), sprintf("  Figures:          %d", counts$figure)), collapse = "\n")
    }
    status <- function(compact = TRUE) {
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
      purposes <- sort(names(state$current), method = "radix")
      current <- lapply(head(purposes, 5L), function(purpose) .obj(purpose = clip(purpose, 64L), ref = safe_ref(state$current[[purpose]])))
      latest <- list()
      for (rec in state$records) if (is.null(latest[[rec$id]]) || rec$revision > latest[[rec$id]]$revision) latest[[rec$id]] <- rec
      candidates <- list(); seen <- character()
      add <- function(loc, ref, role, snapshot = NULL) {
        key <- paste0(loc$kind, ":", loc$value)
        if (key %in% seen) return(invisible(NULL))
        seen <<- c(seen, key)
        candidates[[length(candidates) + 1L]] <<- .obj(locator = loc, ref = ref, role = role, snapshot = snapshot)
      }
      records_to_check <- c(lapply(purposes, function(purpose) .record(state, state$current[[purpose]])), latest[sort(names(latest), method = "radix")])
      for (rec in records_to_check) {
        ref <- .make_ref(state, rec)
        if (!is.null(rec$locator)) add(rec$locator, ref, "file")
        for (entry in rec$code) {
          loc <- if (is.null(entry$snapshot)) entry$locator else .obj(kind = "project", value = entry$snapshot)
          add(loc, ref, "code")
        }
      }
      checked <- min(length(candidates), 100L); found <- 0L; items <- list()
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
      result <- .obj(project = .obj(id = state$project$id, name = clip(state$project$name, 80L)), registry_revision = state$state_revision,
                     current = .arr(current), active_question = NULL, next_task = clip(state$project$next_task, 160L),
                     missing = .obj(checked = checked, unchecked = length(candidates) - checked, found = found, items = .arr(items)),
                     unsaved = dirty, truncated = .obj(current = max(0L, length(purposes) - 5L), missing = found - length(items), text = clipped))
      while (nchar(.json(result), type = "bytes") > 4096L) {
        if (length(result$current)) {
          result$current[[length(result$current)]] <- NULL
          result$truncated$current <- result$truncated$current + 1L
        } else if (length(result$missing$items)) {
          result$missing$items[[length(result$missing$items)]] <- NULL
          result$truncated$missing <- result$truncated$missing + 1L
        } else .fail("Status exceeds byte limit")
      }
      result
    }
    get_raw_dir <- function() .resolve(root, state, state$project$raw_dir)
    get_metadata_path <- function() .resolve(root, state, state$project$metadata)
    get_output_dir <- function(kind) file.path(root, "results", kind)
    self <- list(register_data = register_data, register_analysis = register_analysis, register_figure = register_figure, get_data = get_data, get_analysis = get_analysis, get_figure = get_figure, get_design = get_design, get_condition = get_condition, get_levels = get_levels, get_selected_levels = get_selected_levels, get_reference_level = get_reference_level, get_replicate = get_replicate, set_design = set_design, check_design_metadata = check_design_metadata, get_design_summary = get_design_summary, summary_text = summary_text, find_figures = find_figures, save = save, set_current = set_current, set_context = set_context, update_record = update_record, record_decision = record_decision, rebind_external = rebind_external, check = check, summary = summary, status = status, get_raw_dir = get_raw_dir, get_metadata_path = get_metadata_path, get_output_dir = get_output_dir)
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
  writeBin(charToRaw(.json(manifest)), file.path(folder, "manifest.json"))
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
  .validate(state); writeBin(charToRaw(.json(state)), statefile)
  if (.hash(path) != archive_digest) .fail("Archive changed during import")
  if (!dir.create(project_dir, showWarnings = FALSE)) .fail("Import destination exists")
  items <- list.files(stage, all.files = TRUE, no.. = TRUE)
  items <- c(setdiff(items, ".nb_project_bundle"), ".nb_project_bundle")
  for (item in items) {
    if (!file.rename(file.path(stage, item), file.path(project_dir, item))) .fail(paste("Import incomplete in", project_dir))
  }
  open(project_dir)
}
