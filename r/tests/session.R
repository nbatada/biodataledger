library(BioDataLedger)

local({
  if (!identical(Sys.info()[["sysname"]], "Darwin")) return(invisible(NULL))
  root <- tempfile("bdl-session-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  expect_error <- function(expr, pattern) {
    error <- tryCatch({force(expr); NULL}, error = identity)
    stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error), fixed = TRUE))
    invisible(error)
  }
  quote_r <- function(value) paste(capture.output(dput(value)), collapse = "\n")
  child <- function(lines) {
    script <- tempfile(fileext = ".R")
    on.exit(unlink(script), add = TRUE)
    writeLines(c(paste0(".libPaths(c(", quote_r(dirname(find.package("BioDataLedger"))), ", .libPaths()))"),
                 "library(BioDataLedger)", lines), script)
    output <- system2(file.path(R.home("bin"), "Rscript"), shQuote(script), stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(output, "status"))) stop(paste(output, collapse = "\n"))
    output
  }
  new_project <- function(name) {
    path <- file.path(root, name)
    dir.create(path)
    ProjectBundle$create(name, path)
    path
  }
  path <- new_project("reuse")
  project <- ProjectBundle$open(path)
  source <- file.path(path, "input.rds")
  saveRDS(data.frame(value = 1:4), source)
  ref <- project$register_data("input.rds", "analysis_ready", hash = TRUE)
  other_ref <- project$register_data("input.rds", "different_dataset", hash = TRUE)
  revision <- project$update_record(ref, list(name = "revised metadata"), "fixture")
  project$save()
  registry <- file.path(path, ".nb_project_bundle", "project.json")
  before <- readBin(registry, "raw", n = file.info(registry)$size)
  session <- bdl_session_start(path)
  stopifnot(identical(session, bdl_session_start(path)), identical(session, bdl_session_attach(path)),
            identical(session$project(), session$project()))
  rendered <- paste(capture.output(print(session)), collapse = "\n")
  stopifnot(grepl("Owner:", rendered, fixed = TRUE), !grepl("function", rendered, fixed = TRUE))

  # Count only first resolution hashes, then fail if any later retrieval hashes.
  counter <- new.env(parent = emptyenv())
  counter$hashes <- 0L
  counter$loads <- 0L
  options(bdl.session.test.counter = counter)
  on.exit(options(bdl.session.test.counter = NULL), add = TRUE)
  suppressMessages(trace(".hash", where = asNamespace("BioDataLedger"), print = FALSE,
                         tracer = quote({
                           counter <- getOption("bdl.session.test.counter")
                           counter$hashes <- counter$hashes + 1L
                         })))
  tracing <- TRUE
  on.exit(if (tracing) suppressMessages(untrace(".hash", where = asNamespace("BioDataLedger"))), add = TRUE)
  first <- session$load_once("analysis", ref, function(path) {counter$loads <- counter$loads + 1L; readRDS(path)})
  stopifnot(counter$hashes == 1L, counter$loads == 1L, !first$reused, first$generation == 1L)
  stopifnot(file.rename(source, paste0(source, ".held")))
  reused <- session$load_once("analysis", "DATA-001@1", function(path) stop("must not reload"))
  stopifnot(reused$reused, identical(session$get_data("analysis"), data.frame(value = 1:4)),
            counter$hashes == 1L, counter$loads == 1L)
  detached <- session$info("analysis")
  detached$origin_ref$id <- "DATA-999"
  stopifnot(identical(session$info("analysis")$origin_ref, ref))
  expect_error(session$load_once("analysis", revision, readRDS), "SESSION_SOURCE")
  expect_error(session$load_once("duplicate", revision, readRDS), "SESSION_SOURCE")
  expect_error(session$load_once("bad", "DATA-001", readRDS), "SESSION_SOURCE")
  expect_error(session$load_once("bad", list(project_id = "foreign", id = "DATA-001", revision = 1L), readRDS), "SESSION_SOURCE")
  stopifnot(counter$hashes == 1L)

  evaluated <- FALSE
  expect_error(session$replace_data("analysis", {evaluated <- TRUE; stop("forced stale value")},
                                    expected_generation = 99L, reason = "stale", validate = function(x) TRUE), "SESSION_GENERATION")
  stopifnot(!evaluated)
  original <- session$info("analysis")
  expect_error(session$replace_data("analysis", data.frame(value = 9L), 1L, "reject", function(x) FALSE), "SESSION_VALIDATION")
  expect_error(session$replace_data("analysis", data.frame(value = 9L), 1L, "reject", function(x) stop("validator failure")), "validator failure")
  stopifnot(identical(original, session$info("analysis")), identical(session$get_data("analysis"), data.frame(value = 1:4)))
  replacement <- session$replace_data("analysis", transform(session$get_data("analysis"), value = value + 1L), 1L,
                                      "synthetic approved increment", function(x) is.data.frame(x) && nrow(x) == 4L)
  stopifnot(replacement$generation == 2L, replacement$modified_since_load,
            identical(replacement$origin_ref, ref), identical(session$get_data("analysis"), data.frame(value = 2:5)))
  stopifnot(session$load_once("analysis", ref, stop("cached loader promise must not force"))$modified_since_load)
  expect_error(session$replace_data("analysis", data.frame(value = 9L), 2L, "recursive", function(x) {
    session$release_data("analysis", 2L, "recursive release"); TRUE
  }), "SESSION_BUSY")
  expect_error(session$replace_data("analysis", data.frame(value = 9L), 2L, "recursive", function(x) {
    session$replace_data("analysis", x, 2L, "recursive replace", function(x) TRUE); TRUE
  }), "SESSION_BUSY")
  expect_error(session$replace_data("analysis", data.frame(value = 9L), 2L, "recursive", function(x) {
    session$load_once("analysis", ref, readRDS); TRUE
  }), "SESSION_BUSY")
  expect_error(session$replace_data("analysis", data.frame(value = 9L), 2L, "recursive", function(x) { session$close(); TRUE }), "SESSION_BUSY")
  stopifnot(identical(replacement, session$info("analysis")))

  # Ordinary aliases are outside helper ownership, and only one current binding is kept.
  alias <- session$get_data("analysis")
  internal <- environment(session$get_data)
  stopifnot(identical(ls(internal$objects), "analysis"), identical(ls(internal$metadata), "analysis"),
            !exists("loader", internal, inherits = FALSE), !exists("validate", internal, inherits = FALSE))
  serialized <- file.path(root, "handle.rds")
  saveRDS(session, serialized)
  expect_error(readRDS(serialized)$get_data("analysis"), "USE_LIVE_R_SESSION")
  child(c(paste0("root <- ", quote_r(path)), paste0("handle <- readRDS(", quote_r(serialized), ")"),
          'for (action in list(function() bdl_session_start(root), function() bdl_session_attach(root), function() handle$get_data("analysis"))) {',
          '  error <- tryCatch(action(), error = identity)',
          '  stopifnot(inherits(error, "error"), grepl("USE_LIVE_R_SESSION", conditionMessage(error), fixed = TRUE))', '}'))
  fork <- parallel::mcparallel(tryCatch({session$get_data("analysis"); FALSE}, error = function(e) grepl("USE_LIVE_R_SESSION", conditionMessage(e), fixed = TRUE)))
  stopifnot(isTRUE(parallel::mccollect(fork)[[1L]]), counter$hashes == 1L)
  expect_error(bdl_session_recover(path, first$owner$session_id, "still live"), "USE_LIVE_R_SESSION")
  expect_error(session$release_data("analysis", 1L, "stale release"), "SESSION_GENERATION")
  released <- session$release_data("analysis", 2L, "finished synthetic object")
  stopifnot(released$released, identical(alias, data.frame(value = 2:5)), !length(session$info()$slots), !length(ls(internal$objects)))
  expect_error(session$get_data("analysis"), "SESSION_SLOT")
  stopifnot(file.rename(paste0(source, ".held"), source))
  reloaded <- session$load_once("analysis", ref, readRDS)
  stopifnot(reloaded$generation == 3L, !reloaded$modified_since_load, counter$hashes == 2L)
  expect_error(session$replace_data("analysis", stop("old generation must not force"), 1L, "old", function(x) TRUE), "SESSION_GENERATION")
  # Different logical IDs are allowed even if their registered paths coincide.
  session$load_once("other", other_ref, readRDS)
  stopifnot(length(session$info()$slots) == 2L)
  session$close()
  expect_error(session$get_data("analysis"), "SESSION_CLOSED")
  expect_error(session$project(), "SESSION_CLOSED")
  expect_error(bdl_session_attach(path), "SESSION_NOT_STARTED")
  stopifnot(identical(before, readBin(registry, "raw", n = file.info(registry)$size)), file.exists(source),
            !dir.exists(file.path(path, ".nb_project_bundle", "r-session")))
  suppressMessages(untrace(".hash", where = asNamespace("BioDataLedger")))
  tracing <- FALSE

  # Loader failures/reentry never publish a half-loaded managed slot.
  session <- bdl_session_start(path)
  expect_error(session$load_once("analysis", ref, function(path) {
    session$load_once("analysis", ref, readRDS)
  }), "SESSION_BUSY")
  expect_error(session$load_once("analysis", ref, function(path) {
    session$load_once("other", ref, readRDS)
  }), "SESSION_BUSY")
  stopifnot(!length(session$info()$slots))
  session$load_once("analysis", ref, readRDS)
  session$project()$register_data("input.rds", "pending", hash = TRUE)
  expect_error(session$close(), "SESSION_UNSAVED")
  stopifnot(identical(session, bdl_session_attach(path)))
  session$project()$save()
  session$close()

  # A stale metadata handle can be explicitly replaced without losing its edits.
  refresh_root <- new_project("refresh")
  refresh_source <- file.path(refresh_root, "input.rds")
  saveRDS(data.frame(value = 1:3), refresh_source)
  initial <- ProjectBundle$open(refresh_root)
  refresh_ref <- initial$register_data("input.rds", "initial", hash = TRUE)
  initial$save()
  session <- bdl_session_start(refresh_root)
  loads <- 0L
  session$load_once("analysis", refresh_ref, function(path) {loads <<- loads + 1L; readRDS(path)})
  session$replace_data("analysis", data.frame(value = 2:4), 1L, "synthetic increment", function(x) TRUE)
  old_project <- session$project()
  pending <- old_project$register_data("input.rds", "pending", hash = TRUE)
  external <- ProjectBundle$open(refresh_root)
  external$register_data("input.rds", "external", hash = TRUE)
  external$save()
  expect_error(old_project$save(), "Stale project state")
  expect_error(session$close(), "SESSION_UNSAVED")
  expect_error(session$refresh_project("external reconciliation"), "SESSION_UNSAVED")
  expect_error(session$refresh_project("external reconciliation", allow_pending = NA), "allow_pending")
  cached_before <- session$info("analysis")
  suppressMessages(trace(".hash", where = asNamespace("BioDataLedger"), print = FALSE,
                         tracer = quote(if (endsWith(path, "input.rds")) stop("must not hash cached data"))))
  previous <- session$refresh_project("explicit external metadata reconciliation", allow_pending = TRUE)
  stopifnot(identical(previous, old_project), previous$summary()$unsaved,
            previous$get_data(ref = pending)$role == "pending", !identical(previous, session$project()),
            !session$project()$summary()$unsaved, loads == 1L,
            identical(cached_before, session$info("analysis")),
            identical(session$get_data("analysis"), data.frame(value = 2:4)))
  clean_previous <- session$project()
  stopifnot(identical(session$refresh_project("clean metadata refresh"), clean_previous),
            identical(cached_before, session$info("analysis")), loads == 1L)
  expect_error(session$replace_data("analysis", data.frame(value = 8L), 2L, "recursive refresh", function(x) {
    session$refresh_project("inside validator"); TRUE
  }), "SESSION_BUSY")
  suppressMessages(untrace(".hash", where = asNamespace("BioDataLedger")))
  # Use this project's second DATA identity to reach the loader callback guard.
  second_ref <- session$project()$get_data(ref = "DATA-002@1")$ref
  expect_error(session$load_once("other", second_ref, function(path) {
    session$refresh_project("inside loader")
  }), "SESSION_BUSY")
  suppressMessages(trace(".hash", where = asNamespace("BioDataLedger"), print = FALSE,
                         tracer = quote(if (endsWith(path, "input.rds")) stop("must not hash cached data"))))
  stable_project <- session$project()
  refresh_registry <- file.path(refresh_root, ".nb_project_bundle", "project.json")
  registry_bytes <- readBin(refresh_registry, "raw", n = file.info(refresh_registry)$size)
  empty_root <- new_project("replacement-metadata")
  empty_registry <- file.path(empty_root, ".nb_project_bundle", "project.json")
  empty_state <- jsonlite::fromJSON(empty_registry, simplifyVector = FALSE)
  writeLines(as.character(jsonlite::toJSON(empty_state, auto_unbox = TRUE, null = "null")), refresh_registry)
  expect_error(session$refresh_project("wrong project"), "SESSION_PROJECT")
  stopifnot(identical(session$project(), stable_project), identical(cached_before, session$info("analysis")))
  empty_state$project$id <- cached_before$origin_ref$project_id
  writeLines(as.character(jsonlite::toJSON(empty_state, auto_unbox = TRUE, null = "null")), refresh_registry)
  expect_error(session$refresh_project("missing cached origin"), "SESSION_SOURCE")
  stopifnot(identical(session$project(), stable_project), identical(cached_before, session$info("analysis")))
  writeBin(registry_bytes, refresh_registry)
  refresh_bundle <- file.path(refresh_root, ".nb_project_bundle")
  moved_bundle <- file.path(root, "moved-refresh-bundle")
  stopifnot(file.rename(refresh_bundle, moved_bundle), file.symlink(moved_bundle, refresh_bundle))
  expect_error(session$refresh_project("invalid ownership root"), "SESSION_PATH")
  stopifnot(identical(session$project(), stable_project), identical(cached_before, session$info("analysis")))
  unlink(refresh_bundle)
  stopifnot(file.rename(moved_bundle, refresh_bundle))
  suppressMessages(untrace(".hash", where = asNamespace("BioDataLedger")))
  # The retained stale handle still has its unsaved edits; fresh metadata can close.
  stopifnot(previous$summary()$unsaved, previous$get_data(ref = pending)$role == "pending", loads == 1L)
  session$close()

  # A normal save/reopen preserves identity despite native/JSON numeric types.
  roundtrip_root <- new_project("refresh-roundtrip")
  saveRDS(data.frame(value = 1:3), file.path(roundtrip_root, "input.rds"))
  session <- bdl_session_start(roundtrip_root)
  pending_ref <- session$project()$register_data("input.rds", "pending", hash = TRUE)
  session$load_once("analysis", pending_ref, readRDS)
  session$project()$save()
  previous <- session$refresh_project("saved metadata roundtrip")
  stopifnot(!previous$summary()$unsaved, session$info("analysis")$generation == 1L)
  session$close()

  # Pending ID/revision collisions cannot relabel an already loaded native object.
  collision_root <- new_project("refresh-collision")
  saveRDS(data.frame(value = 1:3), file.path(collision_root, "input.rds"))
  saveRDS(data.frame(value = 5:7), file.path(collision_root, "other.rds"))
  session <- bdl_session_start(collision_root)
  colliding_ref <- session$project()$register_data("input.rds", "pending", hash = TRUE)
  session$load_once("analysis", colliding_ref, readRDS)
  pending_project <- session$project()
  collision_metadata <- session$info("analysis")
  external <- ProjectBundle$open(collision_root)
  committed_ref <- external$register_data("other.rds", "external", hash = TRUE)
  external$save()
  stopifnot(identical(colliding_ref, committed_ref))
  expect_error(pending_project$save(), "Stale project state")
  suppressMessages(trace(".hash", where = asNamespace("BioDataLedger"), print = FALSE,
                         tracer = quote(if (basename(path) %in% c("input.rds", "other.rds")) stop("must not hash cached data"))))
  expect_error(session$refresh_project("colliding pending record", allow_pending = TRUE), "SESSION_SOURCE")
  stopifnot(identical(session$project(), pending_project), pending_project$summary()$unsaved,
            identical(session$info("analysis"), collision_metadata),
            identical(session$get_data("analysis"), data.frame(value = 1:3)))
  # Deliberately releasing the conflicting slot permits an explicit metadata swap.
  retained <- session$get_data("analysis")
  session$release_data("analysis", 1L, "retain alias and reconcile colliding metadata separately")
  returned <- session$refresh_project("explicit metadata reconciliation after release", allow_pending = TRUE)
  stopifnot(identical(returned, pending_project), returned$summary()$unsaved,
            identical(retained, data.frame(value = 1:3)))
  suppressMessages(untrace(".hash", where = asNamespace("BioDataLedger")))
  session$close()

  # Deliberate stopped-owner recovery has an exact token and never reloads data.
  dead <- new_project("stopped")
  child(c(paste0("session <- bdl_session_start(", quote_r(dead), ")"), 'print(session$info()$owner$pid)'))
  owner_path <- file.path(dead, ".nb_project_bundle", "r-session", "owner.json")
  owner <- jsonlite::fromJSON(owner_path, simplifyVector = FALSE)
  expect_error(bdl_session_start(dead), "USE_LIVE_R_SESSION")
  expect_error(bdl_session_recover(dead, "00000000-0000-0000-0000-000000000000", "wrong token"), "does not match")
  original_owner <- readLines(owner_path)
  owner$host <- paste0(owner$host, "-foreign")
  writeLines(as.character(jsonlite::toJSON(owner, auto_unbox = TRUE)), owner_path)
  expect_error(bdl_session_recover(dead, owner$session_id, "foreign"), "same-host")
  stopifnot(file.exists(owner_path))
  writeLines(original_owner, owner_path)
  # PID 1 exists but may be unprobeable from a restricted process. Never infer death.
  owner$host <- Sys.info()[["nodename"]]
  owner$pid <- 1L
  writeLines(as.character(jsonlite::toJSON(owner, auto_unbox = TRUE)), owner_path)
  error <- tryCatch(bdl_session_recover(dead, owner$session_id, "unprobeable owner"), error = identity)
  stopifnot(inherits(error, "error"), file.exists(owner_path),
            grepl("USE_LIVE_R_SESSION|absence is uncertain", conditionMessage(error)))
  writeLines(original_owner, owner_path)
  recovered <- bdl_session_recover(dead, owner$session_id, "confirmed disposable owner exited")
  stopifnot(!recovered$data_reloaded, !file.exists(owner_path))
  bdl_session_start(dead)$close()

  # Marker collisions, foreign contents and symlinks are preserved on refusal.
  session <- bdl_session_start(path)
  marker <- file.path(path, ".nb_project_bundle", "r-session")
  owner_path <- file.path(marker, "owner.json")
  saved_owner <- readLines(owner_path)
  writeLines("unrelated", file.path(marker, "extra"))
  expect_error(session$close(), "SESSION_OWNER")
  stopifnot(file.exists(owner_path), readLines(file.path(marker, "extra")) == "unrelated")
  unlink(file.path(marker, "extra"))
  writeLines('{"version":"unknown"}', owner_path)
  expect_error(bdl_session_attach(path), "SESSION_OWNER")
  writeLines(saved_owner, owner_path)
  target <- file.path(root, "untouched-owner.json")
  writeLines(saved_owner, target)
  unlink(owner_path)
  stopifnot(file.symlink(target, owner_path))
  expect_error(session$close(), "SESSION_PATH")
  stopifnot(identical(readLines(target), saved_owner))
  unlink(owner_path)
  writeLines(saved_owner, owner_path)
  session$close()
  folder_target <- file.path(root, "untouched-folder")
  dir.create(folder_target)
  writeLines("keep", file.path(folder_target, "keep"))
  stopifnot(file.symlink(folder_target, marker))
  expect_error(bdl_session_start(path), "SESSION_PATH")
  stopifnot(readLines(file.path(folder_target, "keep")) == "keep")
  unlink(marker)
  writeLines("collision", marker)
  expect_error(bdl_session_start(path), "SESSION_PATH")
  stopifnot(readLines(marker) == "collision")
  unlink(marker)
  dir.create(marker)
  expect_error(bdl_session_start(path), "SESSION_OWNER")
  stopifnot(dir.exists(marker))
  unlink(marker, recursive = TRUE)

  linked <- new_project("linked-parent")
  bundle <- file.path(linked, ".nb_project_bundle")
  outside <- file.path(root, "preserved-bundle")
  stopifnot(file.rename(bundle, outside), file.symlink(outside, bundle))
  expect_error(bdl_session_start(linked), "SESSION_PATH")
  stopifnot(file.exists(file.path(outside, "project.json")))
  unlink(bundle)
  stopifnot(file.rename(outside, bundle))

  # An ordinary start publication error releases only its new empty reservation.
  ns <- asNamespace("BioDataLedger")
  suppressMessages(trace(".json", where = ns, print = FALSE, tracer = quote(stop("injected owner write failure"))))
  failure <- tryCatch(bdl_session_start(path), error = identity)
  suppressMessages(untrace(".json", where = ns))
  stopifnot(inherits(failure, "error"), grepl("injected owner write failure", conditionMessage(failure), fixed = TRUE), !dir.exists(marker))
  bdl_session_start(path)$close()
  cat("Managed R session focused tests passed\n")
})
