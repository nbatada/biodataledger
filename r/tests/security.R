library(BioDataLedger)
root <- tempfile("nb-sec-"); dir.create(root)
writeLines("data", file.path(root, "data.txt"))
b <- ProjectBundle$create("security", root)
d <- b$register_data("data.txt", "qc", hash = TRUE)
b$save()
plan <- b$preview_export("working", list(d))
zipfile <- tempfile(fileext = ".zip")
writeLines("changed", file.path(root, "data.txt"))
stopifnot(inherits(try(b$export_zip(plan, zipfile), silent = TRUE), "try-error"), !file.exists(zipfile))
stopifnot(inherits(try(b$preview_export("working", list(d)), silent = TRUE), "try-error"))
statefile <- file.path(root, ".nb_project_bundle", "project.json")
original <- readLines(statefile, warn = FALSE)
writeLines(sub('"schema_version"', '"schema_version":"0.1.0","schema_version"', original, fixed = TRUE), statefile)
stopifnot(inherits(try(ProjectBundle$open(root), silent = TRUE), "try-error"))
writeLines(original, statefile)
stopifnot(!BioDataLedger:::.safe_rel("../outside"), !BioDataLedger:::.safe_rel("C:/bad"), !BioDataLedger:::.safe_rel("a\\b"))
stopifnot(!BioDataLedger:::.safe_rel("a:b"), !BioDataLedger:::.safe_rel("a/"))
root2 <- tempfile("nb-inject-"); dir.create(root2)
b2 <- ProjectBundle$create("inject", root2)
b2$set_context(list(next_task = "pending"))
state2 <- file.path(root2, ".nb_project_bundle", "project.json")
before <- readBin(state2, "raw", n = file.info(state2)$size)
options(BioDataLedger.inject_save_before_rename = TRUE)
stopifnot(inherits(try(b2$save(), silent = TRUE), "try-error"))
options(BioDataLedger.inject_save_before_rename = NULL)
after <- readBin(state2, "raw", n = file.info(state2)$size)
stopifnot(identical(before, after), !dir.exists(file.path(root2, ".nb_project_bundle", "write.lock")), b2$summary()$unsaved)
stopifnot(b2$save()$state_revision == 2)
stopifnot(inherits(try(b2$preview_export("context", list("DATA-001@1")), silent = TRUE), "try-error"))
# An older/incompatible ZIP metadata table must not silently skip link/encryption checks.
check_zip_metadata_fields <- function() {
  folder <- tempfile("zip-metadata-"); dir.create(folder)
  writeLines("synthetic", file.path(folder, "data.txt"))
  b <- ProjectBundle$create("metadata guard", folder)
  d <- b$register_data("data.txt", "input"); b$save()
  archive <- tempfile(fileext = ".zip")
  b$export_zip(b$preview_export("working", list(d)), archive)
  original <- get("zip_list", asNamespace("zip"))
  on.exit(assignInNamespace("zip_list", original, ns = "zip"), add = TRUE)
  incomplete <- function(...) {result <- original(...); result$type <- NULL; result}
  assignInNamespace("zip_list", incomplete, ns = "zip")
  stopifnot(inherits(try(BioDataLedger:::.validate_zip(archive), silent = TRUE), "try-error"))
}
check_zip_metadata_fields()

# Decoded-key validation must retain nested and escaped duplicate rejection.
check_decoded_json_keys <- function() {
  parse <- function(text) BioDataLedger:::.parse_json_bytes(charToRaw(enc2utf8(text)))
  invalid <- c(
    '{"a":1,"a":2}', '{"a":1,"\\u0061":2}',
    '{"outer":{"x":null,"x":[]}}', '[{"nested":[{"x":1,"\\u0078":2}]}]',
    '{"":1,"":2}', '{"α":1,"\\u03b1":2}',
    '{"a\\u0062":1,"ab":2}', '{"a\\\\b":1,"a\\u005cb":2}',
    '{"a":}', '{"a":1,}', '[1,]', '{"a":NaN}', '{"a":Infinity}'
  )
  for (text in invalid) stopifnot(inherits(try(parse(text), silent = TRUE), 'try-error'))
  valid <- parse('{"object":{},"array":[],"null":null,"a":{"x":1},"b":{"x":2},"escaped":"a\\\\b\\\"c","unicode":"α"}')
  stopifnot(BioDataLedger:::.is_obj(valid$object), BioDataLedger:::.is_arr(valid$array),
            is.null(valid$null), 'null' %in% names(valid), valid$a$x == 1,
            valid$b$x == 2, valid$unicode == 'α')
  stopifnot(inherits(try(BioDataLedger:::.finite_tree(parse('{"overflow":1e999}')), silent = TRUE), 'try-error'))
}
check_decoded_json_keys()

# Matching validated bytes need no second parse while the writer lock is held.
check_save_reuses_validated_revision <- function() {
  root <- tempfile('save-validated-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  p <- ProjectBundle$create('same validated bytes', root)
  p$set_context(list(next_task = 'pending'))
  original <- get('.read_json', asNamespace('BioDataLedger'))
  on.exit(assignInNamespace('.read_json', original, ns = 'BioDataLedger'), add = TRUE)
  assignInNamespace('.read_json', function(...) stop('unexpected registry reparse'), ns = 'BioDataLedger')
  stopifnot(p$save()$state_revision == 2L, !p$status()$unsaved)
  assignInNamespace('.read_json', original, ns = 'BioDataLedger')
  # Changed valid bytes with the same revision must still reject and retain edits.
  q <- ProjectBundle$open(root)
  q$set_context(list(next_task = 'local edit'))
  path <- file.path(root, '.nb_project_bundle', 'project.json')
  raw <- readBin(path, 'raw', file.info(path)$size)
  writeBin(c(raw, charToRaw(' ')), path)
  stopifnot(inherits(try(q$save(), silent = TRUE), 'try-error'), q$status()$unsaved,
            !dir.exists(file.path(root, '.nb_project_bundle', 'write.lock')))
  writeBin(raw, path)
  stopifnot(q$save()$state_revision == 3L)
}
check_save_reuses_validated_revision()

# Digest matching is ASCII-only and consumes the complete scalar string.
check_digest_shapes <- function() {
  digest <- paste(rep('a09F', 16), collapse = '')
  valid <- c(digest, tolower(digest), toupper(digest))
  invalid <- list('', substr(digest, 1, 63), paste0(digest, 'a'),
                  paste0(digest, '\n'), paste0(digest, '\r\n'), paste0('\n', digest),
                  paste0(substr(digest, 1, 63), 'α'), paste0(substr(digest, 1, 63), 'ａ'),
                  paste0(substr(digest, 1, 63), 'g'), NA_character_, NULL,
                  c(digest, digest), 1, list(digest))
  stopifnot(all(vapply(valid, BioDataLedger:::.is_sha, logical(1))),
            !any(vapply(invalid, BioDataLedger:::.is_sha, logical(1))))
}
check_digest_shapes()

# Candidate save edits must not leak into the staged state on either failure path.
check_save_candidate_isolation <- function() {
  root <- tempfile('save-isolation-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines('synthetic', file.path(root, 'input.txt'))
  p <- ProjectBundle$create('candidate isolation', root)
  d <- p$register_data('input.txt', 'input', hash = TRUE); p$save()
  p$set_context(list(next_task = 'pending edit'))
  state_env <- environment(p$save)
  state <- get('state', state_env)
  index_values <- function(state) {
    index <- attr(state, 'record_index')
    lapply(index, function(x) if (is.environment(x)) as.list(x, all.names = TRUE) else x)
  }
  path <- file.path(root, '.nb_project_bundle', 'project.json')
  disk <- readBin(path, 'raw', file.info(path)$size)
  for (failure in c('validation', 'publication')) {
    candidate <- state
    if (failure == 'validation') candidate$schema_version <- 'invalid'
    assign('state', candidate, envir = state_env)
    metadata <- BioDataLedger:::.json(candidate)
    indexes <- BioDataLedger:::.copy(index_values(candidate))
    if (failure == 'publication') options(BioDataLedger.inject_save_before_rename = TRUE)
    result <- try(p$save(), silent = TRUE)
    options(BioDataLedger.inject_save_before_rename = NULL)
    current <- get('state', state_env)
    stopifnot(inherits(result, 'try-error'), identical(BioDataLedger:::.json(current), metadata),
              identical(index_values(current), indexes), identical(current$history, candidate$history),
              identical(readBin(path, 'raw', file.info(path)$size), disk), p$status()$unsaved,
              !dir.exists(file.path(root, '.nb_project_bundle', 'write.lock')))
  }
  assign('state', state, envir = state_env)
  stopifnot(p$save()$state_revision == state$state_revision + 1L)
}
check_save_candidate_isolation()

# Full validation already built the exact indexes needed by open and dirty save.
check_validated_index_reuse <- function() {
  root <- tempfile('save-index-reuse-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  p <- ProjectBundle$create('index reuse', root)
  original <- get('.index_state', asNamespace('BioDataLedger'))
  on.exit(assignInNamespace('.index_state', original, ns = 'BioDataLedger'), add = TRUE)
  calls <- 0L
  assignInNamespace('.index_state', function(state) {calls <<- calls + 1L; original(state)}, ns = 'BioDataLedger')
  p <- ProjectBundle$open(root)
  stopifnot(calls == 1L)
  p$set_context(list(next_task = 'meaningful update'))
  calls <- 0L
  p$save()
  stopifnot(calls == 1L, !p$status()$unsaved)
  p$save()
  stopifnot(calls == 1L)
}
check_validated_index_reuse()
