# Source this file for explicit preview_recovery() and apply_recovery() helpers.
.recovery_fail <- function(message) stop(paste0("Recovery: ", message), call. = FALSE)
.recovery_rel <- function(x, directory = FALSE) {
  if (directory && identical(x, ".")) return(x)
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x) || grepl("[\\\\:[:cntrl:]]|^/|(^|/)\\.{1,2}(/|$)|//", x)) .recovery_fail(paste("unsafe relative path", x))
  x
}
.recovery_file <- function(path) {
  if (!file.exists(path) || dir.exists(path)) .recovery_fail(paste("missing or nonregular source", path))
  p <- path
  repeat {
    link <- Sys.readlink(p)
    if (!is.na(link) && nzchar(link)) .recovery_fail(paste("symlink source", path))
    next_p <- dirname(p)
    if (identical(p, next_p)) break
    p <- next_p
  }
  invisible(path)
}
.recovery_ref <- function(x) {
  if (!is.list(x) || !setequal(names(x), c("project_id", "id", "revision"))) .recovery_fail("exact reference required")
  x
}
.recovery_hash <- function(path) digest::digest(file = path, algo = "sha256", serialize = FALSE)
.recovery_manifest <- function(x) {
  if (is.character(x) && length(x) == 1L) {
    # The package parser enforces the existing 20 MiB limit, duplicate-key rejection, and JSON syntax.
    # No public bounded JSON parser is exposed by BioDataLedger.
    x <- getFromNamespace(".read_json", "BioDataLedger")(x)
  }
  if (!is.list(x) || !setequal(names(x), c("version", "figure_ref", "files", "entrypoint", "working_directory", "import_roots", "external_requirements")) || !identical(x$version, "biodataledger-recovery/1")) .recovery_fail("invalid manifest")
  x
}
preview_recovery <- function(project, project_root, manifest) {
  manifest <- .recovery_manifest(manifest)
  .recovery_ref(manifest$figure_ref)
  figure <- project$get_figure(manifest$figure_ref)
  files <- manifest$files
  if (!is.list(files) || !is.null(names(files)) || !length(files) || length(files) > 10000L) .recovery_fail("finite nonempty files list required")
  root <- normalizePath(project_root, mustWork = TRUE)
  checked <- list(); keys <- character(); spellings <- list()
  for (i in seq_along(files)) {
    entry <- files[[i]]
    if (!is.list(entry) || !setequal(names(entry), c("source", "destination", "sha256", "size", "purpose"))) .recovery_fail(paste("invalid entry", i))
    dest <- .recovery_rel(entry$destination)
    key <- stringi::stri_trans_casefold(stringi::stri_trans_nfc(dest))
    parts <- strsplit(dest, "/", fixed = TRUE)[[1L]]
    for (j in seq_along(parts)) {
      prefix <- paste(parts[seq_len(j)], collapse = "/")
      normalized <- stringi::stri_trans_casefold(stringi::stri_trans_nfc(prefix))
      prior <- spellings[[normalized]]
      if (!is.null(prior) && !identical(prior, prefix)) .recovery_fail(paste("case/Unicode ancestor collision", dest))
      spellings[[normalized]] <- prefix
    }
    if (key %in% keys || any(startsWith(key, paste0(keys, "/")) | startsWith(keys, paste0(key, "/")))) .recovery_fail(paste("destination collision", dest))
    keys <- c(keys, key)
    if (!is.character(entry$sha256) || !grepl("^[0-9a-f]{64}$", entry$sha256) || !is.numeric(entry$size) || length(entry$size) != 1L || is.na(entry$size) || entry$size < 0 || entry$size != floor(entry$size) || !is.character(entry$purpose) || length(entry$purpose) != 1L || !nzchar(entry$purpose)) .recovery_fail(paste("invalid digest, size or purpose", dest))
    source <- entry$source
    if (!is.list(source) || !source$kind %in% c("record", "code")) .recovery_fail(paste("invalid source", dest))
    if (identical(source$kind, "record")) {
      if (!setequal(names(source), c("kind", "ref"))) .recovery_fail("invalid record source")
      ref <- .recovery_ref(source$ref)
      view <- if (startsWith(ref$id, "DATA-")) project$get_data(ref = ref) else if (startsWith(ref$id, "FIG-")) project$get_figure(ref) else .recovery_fail("source must be DATA or FIG")
      if (is.null(view$sha256) || !identical(view$sha256, entry$sha256) || !identical(as.numeric(view$size), as.numeric(entry$size))) .recovery_fail(paste("record digest or size disagrees", dest))
      path <- view$path
    } else {
      if (!setequal(names(source), c("kind", "analysis_ref", "locator", "sha256")) || !identical(source$sha256, entry$sha256)) .recovery_fail("invalid code source")
      analysis_ref <- .recovery_ref(source$analysis_ref)
      target_ref <- figure$analysis
      if (is.null(target_ref) || !identical(analysis_ref$project_id, target_ref$project_id) || !identical(analysis_ref$id, target_ref$id) || as.numeric(analysis_ref$revision) != as.numeric(target_ref$revision)) .recovery_fail("code source must be target figure analysis")
      matches <- Filter(function(x) identical(x$locator, source$locator) && identical(x$sha256, entry$sha256), figure$code)
      if (length(matches) != 1L) .recovery_fail("code locator absent or ambiguous")
      code <- matches[[1L]]
      if (is.null(code$snapshot)) .recovery_fail("code without snapshot needs explicit binding; register a snapshot")
      availability <- Filter(function(x) identical(x$reference$locator, source$locator) && identical(x$reference$sha256, entry$sha256), figure$code_availability)
      if (length(availability) != 1L) .recovery_fail("code is not available through target figure")
      path <- availability[[1L]]$path
    }
    if (is.null(path)) .recovery_fail(paste("unresolved source", dest))
    .recovery_file(path)
    if (!identical(.recovery_hash(path), entry$sha256) || file.info(path)$size != entry$size) .recovery_fail(paste("source bytes disagree", dest))
    checked[[i]] <- list(destination = dest, source_path = path, sha256 = entry$sha256, size = entry$size, purpose = entry$purpose)
  }
  entrypoint <- .recovery_rel(manifest$entrypoint)
  if (!entrypoint %in% vapply(checked, `[[`, character(1), "destination")) .recovery_fail("undeclared entrypoint")
  cwd <- .recovery_rel(manifest$working_directory, TRUE)
  roots <- manifest$import_roots; requirements <- manifest$external_requirements
  if (!is.list(roots) || !is.null(names(roots)) || !is.list(requirements) || !is.null(names(requirements)) || !all(vapply(roots, function(x) is.character(x) && length(x) == 1L, logical(1))) || !all(vapply(requirements, function(x) is.character(x) && length(x) == 1L && nzchar(x), logical(1)))) .recovery_fail("invalid hints")
  roots <- lapply(roots, .recovery_rel, directory = TRUE)
  destinations <- vapply(checked, `[[`, character(1), "destination")
  for (hint in c(cwd, unlist(roots))) if (hint != "." && !any(startsWith(destinations, paste0(hint, "/")))) .recovery_fail(paste("directory hint has no file", hint))
  signature <- digest::digest(jsonlite::toJSON(manifest, auto_unbox = TRUE, null = "null"), algo = "sha256", serialize = FALSE)
  list(manifest_sha256 = signature, files = checked, entrypoint = entrypoint, working_directory = cwd, import_roots = roots, external_requirements = requirements)
}
apply_recovery <- function(project, project_root, manifest, destination, reviewed_preview) {
  fresh <- preview_recovery(project, project_root, manifest)
  if (!identical(fresh, reviewed_preview)) .recovery_fail("manifest or source changed since review")
  link <- Sys.readlink(destination)
  if (file.exists(destination) || dir.exists(destination) || (!is.na(link) && nzchar(link))) .recovery_fail("output already exists")
  parent <- normalizePath(dirname(destination), mustWork = TRUE)
  stage <- tempfile(".biodataledger-recovery-", tmpdir = parent)
  if (!dir.create(stage)) .recovery_fail("cannot create staging directory")
  on.exit(if (dir.exists(stage)) unlink(stage, recursive = TRUE), add = TRUE)
  for (entry in fresh$files) {
    .recovery_file(entry$source_path)
    target <- file.path(stage, entry$destination)
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    if (!file.copy(entry$source_path, target, overwrite = FALSE, copy.mode = FALSE)) .recovery_fail(paste("copy failed", entry$destination))
    if (!identical(.recovery_hash(target), entry$sha256) || file.info(target)$size != entry$size || !identical(.recovery_hash(entry$source_path), entry$sha256)) .recovery_fail(paste("changed during copy", entry$destination))
  }
  if (!dir.create(destination, showWarnings = FALSE)) .recovery_fail("output appeared during copy")
  children <- list.files(stage, all.files = TRUE, no.. = TRUE)
  for (child in children) {
    if (!file.rename(file.path(stage, child), file.path(destination, child))) .recovery_fail(paste("partial recovery publication; inspect", destination))
  }
  c(fresh, list(destination = destination))
}
