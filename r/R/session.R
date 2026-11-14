# Optional live R ownership; scientific objects never enter the project registry.
.bdl_sessions <- new.env(parent = emptyenv())

.session_link <- function(path) {
  target <- Sys.readlink(path)
  !is.na(target) && nzchar(target)
}
.session_root <- function(project_dir) {
  if (!.design_text(project_dir) || !dir.exists(project_dir)) .fail("Existing project directory required")
  normalizePath(project_dir, mustWork = TRUE)
}
.session_paths <- function(root) {
  bundle <- file.path(root, ".nb_project_bundle")
  folder <- file.path(bundle, "r-session")
  owner <- file.path(folder, "owner.json")
  for (path in c(bundle, folder, owner)) {
    if (.session_link(path)) .fail("SESSION_PATH: symbolic links are not allowed in ownership metadata")
    if (file.exists(path) && !startsWith(normalizePath(path, mustWork = TRUE), paste0(root, "/")))
      .fail("SESSION_PATH: ownership metadata escapes project")
  }
  if (!dir.exists(bundle) || file.exists(folder) && !dir.exists(folder) || dir.exists(owner))
    .fail("SESSION_PATH: ownership metadata path collision")
  list(folder = folder, owner = owner)
}
.session_read_owner <- function(root) {
  paths <- .session_paths(root)
  if (!dir.exists(paths$folder)) return(NULL)
  if (!identical(list.files(paths$folder, all.files = TRUE, no.. = TRUE), "owner.json") ||
      !file.exists(paths$owner) || is.na(file.info(paths$owner)$size) || file.info(paths$owner)$size > 16384)
    .fail("SESSION_OWNER: incomplete or unexpected ownership metadata; preserve and inspect it")
  owner <- tryCatch(.read_json(paths$owner), error = function(e) .fail("SESSION_OWNER: malformed owner.json"))
  fields <- c("version", "host", "pid", "session_id", "process_nonce", "root", "project_id", "created_at")
  if (!is.list(owner) || !setequal(names(owner), fields) ||
      !identical(owner$version, "biodataledger-r-session/1") || !.design_text(owner$host) ||
      !.is_int(owner$pid, TRUE) || owner$pid > .Machine$integer.max || !.is_uuid(owner$session_id) || !.is_uuid(owner$process_nonce) ||
      !identical(owner$root, root) || !.is_uuid(owner$project_id) || !.valid_utc_timestamp(owner$created_at))
    .fail("SESSION_OWNER: invalid or unsupported ownership metadata")
  owner
}
.session_live_error <- function(owner) {
  .fail(sprintf("USE_LIVE_R_SESSION: execute in the owning R process on %s, PID %s, session %s; attach is not a connection or automatic takeover",
                owner$host, owner$pid, owner$session_id))
}
.session_owner_equal <- function(first, second) {
  !is.null(first) && !is.null(second) && setequal(names(first), names(second)) &&
    all(vapply(names(first), function(name) identical(first[[name]], second[[name]]), logical(1)))
}
.session_remove_owner <- function(root, expected) {
  if (!.session_owner_equal(.session_read_owner(root), expected)) .fail("SESSION_OWNER: ownership changed; metadata preserved")
  paths <- .session_paths(root)
  # Remove only our exact file and then the empty directory, never recursively.
  if (!file.remove(paths$owner) || !file.remove(paths$folder)) .fail("SESSION_OWNER: cannot remove ownership metadata")
  invisible(NULL)
}
.session_exact_ref <- function(ref, project_id) {
  if (is.character(ref) && length(ref) == 1L && !is.na(ref) && grepl("^DATA-[0-9]{3,}@[1-9][0-9]*$", ref)) {
    parts <- strsplit(ref, "@", fixed = TRUE)[[1L]]
    ref <- list(project_id = project_id, id = parts[[1L]], revision = suppressWarnings(as.integer(parts[[2L]])))
  }
  if (!is.list(ref) || !setequal(names(ref), c("project_id", "id", "revision")) ||
      !identical(ref$project_id, project_id) || !.design_text(ref$id) ||
      !grepl("^DATA-[0-9]{3,}$", ref$id) || !.is_int(ref$revision, TRUE))
    .fail("SESSION_SOURCE: exact DATA revision from this project required")
  list(project_id = ref$project_id, id = ref$id, revision = as.integer(ref$revision))
}
.session_source_identity <- function(source) {
  transient <- c("locator", "path", "available", "availability_checked", "verification", "result")
  identity <- source[setdiff(names(source), transient)]
  # Normalize small ledger metadata as persisted; never serialize the native object.
  .parse_json_bytes(charToRaw(.json(identity)))
}
.session_new <- function(root, project, owner) {
  token <- new.env(parent = emptyenv())
  objects <- new.env(parent = emptyenv())
  metadata <- new.env(parent = emptyenv())
  identities <- new.env(parent = emptyenv())
  generations <- new.env(parent = emptyenv())
  busy <- new.env(parent = emptyenv())
  closed <- FALSE
  assert_owner <- function() {
    if (closed) .fail("SESSION_CLOSED: this handle has been closed")
    if (!identical(Sys.getpid(), owner$pid) || !identical(Sys.info()[["nodename"]], owner$host) ||
        !exists(root, .bdl_sessions, inherits = FALSE) ||
        !identical(get(root, .bdl_sessions, inherits = FALSE)$token, token)) .session_live_error(owner)
    invisible(NULL)
  }
  check_slot <- function(slot, loaded = FALSE, allow_busy = FALSE) {
    assert_owner()
    if (!.design_text(slot) || nchar(slot, type = "bytes") > 128L) .fail("SESSION_SLOT: nonempty slot name up to 128 bytes required")
    if (!allow_busy && exists(slot, busy, inherits = FALSE)) .fail("SESSION_BUSY: loader or validator is running for this slot")
    if (loaded && !exists(slot, metadata, inherits = FALSE)) .fail("SESSION_SLOT: no managed data in this slot")
  }
  check_generation <- function(slot, expected_generation) {
    current <- get(slot, metadata, inherits = FALSE)
    if (!.is_int(expected_generation, TRUE) || expected_generation != current$generation)
      .fail("SESSION_GENERATION: stale or invalid expected_generation")
    current
  }
  slot_info <- function(slot, reused = NULL) {
    result <- get(slot, metadata, inherits = FALSE)
    if (!is.null(reused)) result$reused <- reused
    result
  }
  next_generation <- function(slot) {
    previous <- if (exists(slot, generations, inherits = FALSE)) get(slot, generations, inherits = FALSE) else 0L
    if (previous >= .Machine$integer.max) .fail("SESSION_GENERATION: generation exhausted; use a new session")
    previous + 1L
  }
  load_once <- function(slot, ref, loader) {
    check_slot(slot)
    ref <- .session_exact_ref(ref, owner$project_id)
    if (exists(slot, metadata, inherits = FALSE)) {
      if (!identical(get(slot, metadata, inherits = FALSE)$origin_ref, ref)) .fail("SESSION_SOURCE: slot already holds a different exact source")
      return(slot_info(slot, reused = TRUE))
    }
    logical_id <- ref$id
    for (other in ls(metadata, all.names = TRUE)) {
      if (identical(get(other, metadata, inherits = FALSE)$origin_ref$id, logical_id))
        .fail("SESSION_SOURCE: this logical DATA identity already has a managed slot")
    }
    for (other in ls(busy, all.names = TRUE)) {
      if (identical(get(other, busy, inherits = FALSE), logical_id)) .fail("SESSION_BUSY: this DATA identity is already being loaded")
    }
    if (!is.function(loader)) .fail("loader must be a function")
    assign(slot, logical_id, busy)
    on.exit(rm(list = slot, envir = busy), add = TRUE)
    source <- project$resolve_data(ref = ref, verify = "sha256")
    identity <- .session_source_identity(source)
    value <- loader(source$path)
    generation <- next_generation(slot)
    item <- list(slot = slot, origin_ref = ref, generation = generation, modified_since_load = FALSE,
                 object_class = class(value), source_verified_at = source$verification$checked_at,
                 owner = owner, changed_at = .now(), reason = NULL)
    assign(slot, value, objects)
    assign(slot, item, metadata)
    assign(slot, identity, identities)
    assign(slot, generation, generations)
    slot_info(slot, reused = FALSE)
  }
  get_data <- function(slot) {
    check_slot(slot, loaded = TRUE, allow_busy = TRUE)
    get(slot, objects, inherits = FALSE)
  }
  info <- function(slot = NULL) {
    assert_owner()
    if (!is.null(slot)) { check_slot(slot, loaded = TRUE, allow_busy = TRUE); return(slot_info(slot)) }
    list(owner = owner, slots = stats::setNames(lapply(ls(metadata, all.names = TRUE), slot_info), ls(metadata, all.names = TRUE)))
  }
  replace_data <- function(slot, value, expected_generation, reason, validate) {
    check_slot(slot, loaded = TRUE)
    item <- check_generation(slot, expected_generation)
    if (!.design_text(reason)) .fail("Replacement reason required")
    if (!is.function(validate)) .fail("validate must be a function returning TRUE")
    assign(slot, item$origin_ref$id, busy)
    on.exit(rm(list = slot, envir = busy), add = TRUE)
    # Force only after ownership, generation and reentrancy checks.
    force(value)
    if (!identical(validate(value), TRUE)) .fail("SESSION_VALIDATION: validate(value) must return TRUE")
    generation <- next_generation(slot)
    item$generation <- generation
    item$modified_since_load <- TRUE
    item$object_class <- class(value)
    item$changed_at <- .now()
    item$reason <- reason
    assign(slot, value, objects)
    assign(slot, item, metadata)
    assign(slot, generation, generations)
    slot_info(slot)
  }
  release_data <- function(slot, expected_generation, reason) {
    check_slot(slot, loaded = TRUE)
    item <- check_generation(slot, expected_generation)
    if (!.design_text(reason)) .fail("Release reason required")
    rm(list = slot, envir = objects)
    rm(list = slot, envir = metadata)
    rm(list = slot, envir = identities)
    item$released <- TRUE
    item$reason <- reason
    item
  }
  refresh_project <- function(reason, allow_pending = FALSE) {
    assert_owner()
    if (length(ls(busy, all.names = TRUE))) .fail("SESSION_BUSY: wait for loader or validator before refreshing project metadata")
    if (!.design_text(reason)) .fail("Project refresh reason required")
    if (!is.logical(allow_pending) || length(allow_pending) != 1L || is.na(allow_pending))
      .fail("allow_pending must be TRUE or FALSE")
    if (isTRUE(project$status()$unsaved) && !allow_pending)
      .fail("SESSION_UNSAVED: retain and reconcile pending edits explicitly; allow_pending=TRUE returns the previous handle")
    if (!.session_owner_equal(.session_read_owner(root), owner)) .fail("SESSION_OWNER: ownership changed; project metadata not refreshed")
    proposed <- ProjectBundle$open(root)
    if (!identical(proposed$status()$project$id, owner$project_id))
      .fail("SESSION_PROJECT: project identity changed; current handle preserved")
    for (slot in ls(metadata, all.names = TRUE)) {
      ref <- get(slot, metadata, inherits = FALSE)$origin_ref
      candidate <- tryCatch(proposed$get_data(ref = ref),
                            error = function(e) .fail("SESSION_SOURCE: cached origin is absent or invalid in refreshed project metadata"))
      if (!.result_equal(get(slot, identities, inherits = FALSE), .session_source_identity(candidate)))
        .fail("SESSION_SOURCE: cached origin identity differs in refreshed project metadata; current handle preserved")
    }
    previous <- project
    project <<- proposed
    previous
  }
  close <- function() {
    assert_owner()
    if (length(ls(busy, all.names = TRUE))) .fail("SESSION_BUSY: wait for loader or validator before closing")
    if (isTRUE(project$status()$unsaved)) .fail("SESSION_UNSAVED: save or reconcile pending project edits before closing")
    .session_remove_owner(root, owner)
    rm(list = ls(objects, all.names = TRUE), envir = objects)
    rm(list = ls(metadata, all.names = TRUE), envir = metadata)
    rm(list = ls(identities, all.names = TRUE), envir = identities)
    rm(list = root, envir = .bdl_sessions)
    project <<- NULL
    closed <<- TRUE
    invisible(NULL)
  }
  handle <- structure(list(project = function() { assert_owner(); project }, load_once = load_once,
                           get_data = get_data, info = info, refresh_project = refresh_project, replace_data = replace_data,
                           release_data = release_data, close = close), class = "BioDataLedgerSession")
  assign(root, list(token = token, handle = handle), .bdl_sessions)
  handle
}

bdl_session_start <- function(project_dir) {
  root <- .session_root(project_dir)
  owner <- .session_read_owner(root)
  if (!is.null(owner)) return(bdl_session_attach(root))
  if (!identical(Sys.info()[["sysname"]], "Darwin")) .fail("R session ownership currently requires macOS")
  if (exists(root, .bdl_sessions, inherits = FALSE)) .fail("SESSION_OWNER: live handle lost its ownership metadata; do not start a replacement")
  project <- ProjectBundle$open(root)
  status <- project$status()
  owner <- list(version = "biodataledger-r-session/1", host = Sys.info()[["nodename"]], pid = Sys.getpid(),
                session_id = .uuid(), process_nonce = .uuid(), root = root,
                project_id = status$project$id, created_at = .now())
  paths <- .session_paths(root)
  if (!dir.create(paths$folder, mode = "0700", showWarnings = FALSE)) .fail("SESSION_OWNER: ownership directory already exists or cannot be created")
  complete <- FALSE
  on.exit({
    # Ordinary publication errors clean only the newly reserved, unshared marker.
    if (!complete && !.session_link(paths$folder) && !.session_link(paths$owner) &&
        dir.exists(paths$folder) && !dir.exists(paths$owner) &&
        all(list.files(paths$folder, all.files = TRUE, no.. = TRUE) %in% "owner.json")) {
      if (file.exists(paths$owner)) file.remove(paths$owner)
      file.remove(paths$folder)
    }
  }, add = TRUE)
  # An incomplete marker after a process crash is deliberately not taken over.
  writeLines(.json(owner), paths$owner, useBytes = TRUE)
  if (!isTRUE(Sys.chmod(paths$owner, mode = "0600"))) .fail("SESSION_OWNER: cannot restrict marker permissions")
  if (!.session_owner_equal(.session_read_owner(root), owner)) .fail("SESSION_OWNER: owner publication failed")
  handle <- .session_new(root, project, owner)
  complete <- TRUE
  handle
}

bdl_session_attach <- function(project_dir) {
  root <- .session_root(project_dir)
  owner <- .session_read_owner(root)
  if (is.null(owner)) .fail("SESSION_NOT_STARTED: call bdl_session_start explicitly in the intended live R console")
  if (!identical(owner$host, Sys.info()[["nodename"]]) || !identical(owner$pid, Sys.getpid()) ||
      !exists(root, .bdl_sessions, inherits = FALSE)) .session_live_error(owner)
  handle <- get(root, .bdl_sessions, inherits = FALSE)$handle
  if (!.session_owner_equal(handle$info()$owner, owner)) .session_live_error(owner)
  handle
}

bdl_session_recover <- function(project_dir, expected_session_id, reason) {
  root <- .session_root(project_dir)
  owner <- .session_read_owner(root)
  if (is.null(owner)) .fail("SESSION_NOT_STARTED: no ownership metadata to recover")
  if (!.is_uuid(expected_session_id) || !identical(expected_session_id, owner$session_id)) .fail("SESSION_OWNER: expected_session_id does not match")
  if (!.design_text(reason)) .fail("Recovery reason required")
  if (!identical(Sys.info()[["sysname"]], "Darwin") || !identical(owner$host, Sys.info()[["nodename"]]))
    .fail("SESSION_RECOVERY: only confirmed absent same-host macOS owners can be recovered")
  if (owner$pid == Sys.getpid() || isTRUE(tools::pskill(owner$pid, signal = 0L))) .session_live_error(owner)
  # Signal zero checks existence only; require the explicit absent-process error.
  process <- tryCatch(suppressWarnings(system2("/bin/kill", c("-0", as.character(owner$pid)),
                                                stdout = TRUE, stderr = TRUE, env = "LC_ALL=C")),
                      error = function(e) NULL)
  absent <- paste0("kill: ", owner$pid, ": No such process")
  if (is.null(process) || !identical(attr(process, "status"), 1L) ||
      !identical(unname(as.character(process)), absent))
    .fail("SESSION_RECOVERY: owner absence is uncertain; metadata preserved")
  .session_remove_owner(root, owner)
  list(recovered_session_id = owner$session_id, reason = reason, recovered_at = .now(), data_reloaded = FALSE)
}

print.BioDataLedgerSession <- function(x, ...) {
  details <- x$info()
  cat(sprintf("BioDataLedger R session %s\nOwner: %s, PID %s\n", details$owner$session_id, details$owner$host, details$owner$pid))
  if (!length(details$slots)) cat("Managed slots: none\n")
  for (item in details$slots) cat(sprintf("  %s: %s@%s, generation %s, modified=%s\n", item$slot,
                                        item$origin_ref$id, item$origin_ref$revision, item$generation, item$modified_since_load))
  invisible(x)
}
