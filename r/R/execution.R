.execution_version <- "biodataledger-execution/1"

.execution_error <- function(message, receipt = NULL) {
  structure(list(message = message, call = NULL, receipt = receipt),
            class = c("BioDataLedgerExecutionError", "error", "condition"))
}

.execution_stop <- function(message, receipt = NULL) stop(.execution_error(message, receipt))

.execution_text <- function(x, limit = 1024L) {
  text <- enc2utf8(if (inherits(x, "condition")) conditionMessage(x) else as.character(x)[1L])
  while (nchar(text, type = "bytes") > limit) text <- substr(text, 1L, nchar(text, type = "chars") - 1L)
  text
}

.execution_ref_text <- function(ref) paste0(ref$id, "@", ref$revision)

.execution_output_specs <- function(outputs, root) {
  if (!.is_arr(outputs) || length(outputs) > 100L) .fail("Outputs must be an array of at most 100 items")
  seen <- character()
  lapply(outputs, function(output) {
    if (!.is_obj(output) || !all(names(output) %in% c("path", "kind", "type")) ||
        !all(c("path", "kind") %in% names(output)) || !is.character(output$path) ||
        length(output$path) != 1L || grepl("^[A-Za-z][A-Za-z0-9+.-]*:", output$path) || !output$kind %in% c("result", "figure") ||
        (identical(output$kind, "figure") && (!is.character(output$type) || length(output$type) != 1L || !nzchar(output$type))) ||
        (identical(output$kind, "result") && !is.null(output$type))) .fail("Invalid output declaration")
    requested <- if (startsWith(output$path, "/")) output$path else file.path(root, output$path)
    parent <- dirname(requested)
    if (!dir.exists(parent)) .fail("Output parent directory is unavailable")
    path <- file.path(normalizePath(parent, mustWork = TRUE), basename(requested))
    registry <- paste0(normalizePath(file.path(root, ".nb_project_bundle"), mustWork = FALSE), "/")
    project <- paste0(normalizePath(root, mustWork = TRUE), "/")
    link <- Sys.readlink(path)
    if ((!startsWith(output$path, "/") && !startsWith(path, project)) || startsWith(path, registry) || path %in% seen || file.exists(path) || (!is.na(link) && nzchar(link)) || !dir.exists(dirname(path))) .fail("Output path is unavailable")
    seen <<- c(seen, path)
    .obj(path = path, kind = output$kind, type = output$type)
  })
}

.execution_output_view <- function(spec) {
  out <- .obj(path = spec$path, kind = spec$kind, status = "not_observed")
  if (!is.null(spec$type)) out$type <- spec$type
  out
}

.execution_receipt_view <- function(receipt) {
  out <- .copy(receipt)
  out$receipt_ref <- if (is.null(out$receipt_ref)) NULL else .copy(out$receipt_ref)
  out
}

.execution_receipt_valid <- function(state, rec, receipt) {
  tryCatch(.execution_receipt_valid_inner(state, rec, receipt), error = function(e) FALSE)
}

.execution_receipt_valid_inner <- function(state, rec, receipt) {
  required <- c("version", "status", "template_ref", "run_ref", "receipt_ref", "started_at_utc",
                "ended_at_utc", "entry_point", "language", "code", "method", "params", "seeds",
                "inputs", "outputs", "phases", "input_consumption", "scientific_validity",
                "downstream_consumption", "error")
  .is_obj(receipt) && identical(receipt$version, .execution_version) &&
    all(required %in% names(receipt)) && receipt$status %in% c("started", "succeeded", "failed", "blocked", "incomplete") &&
    is.character(receipt$language) && length(receipt$language) == 1L && receipt$language %in% c("r", "python") &&
    (is.null(receipt$seeds) || .is_obj(receipt$seeds)) && length(receipt$inputs) <= 100L && length(receipt$outputs) <= 100L && .is_obj(receipt$code) && all(c("path", "digest", "snapshot_digest", "snapshot") %in% names(receipt$code)) &&
    is.character(receipt$code$path) && length(receipt$code$path) == 1L && nzchar(receipt$code$path) && .is_sha(receipt$code$digest) && .is_sha(receipt$code$snapshot_digest) && .is_obj(receipt$phases) && .is_arr(receipt$inputs) && .is_arr(receipt$outputs) &&
    all(c("execution_started", "code_executed", "callback_invoked") %in% names(receipt$phases)) &&
    all(vapply(receipt$phases[c("execution_started", "code_executed", "callback_invoked")], function(x) is.logical(x) && length(x) == 1L && !is.na(x), logical(1))) &&
    identical(receipt$input_consumption, "unknown") && identical(receipt$scientific_validity, "unknown") &&
    identical(receipt$downstream_consumption, "unknown") &&
    {
      checkpoints <- receipt$input_checkpoints
      if (!is.null(checkpoints)) {
        if (!.is_obj(checkpoints) || !identical(checkpoints$version,"biodataledger-input-checkpoints/1") || !.is_arr(checkpoints$checks) || length(checkpoints$checks)>3L) return(FALSE)
        expected <- c("preflight","before_callback","after_callback")
        for (i in seq_along(checkpoints$checks)) { check <- checkpoints$checks[[i]]; if (!.is_obj(check) || !identical(check$phase,expected[[i]]) || !.is_arr(check$files) || !.is_arr(check$objects) || length(check$files)!=length(receipt$inputs)) return(FALSE)
          if (!all(vapply(seq_along(check$files),function(j) identical(check$files[[j]]$ref,receipt$inputs[[j]]$ref),logical(1)))) return(FALSE)
          for (object in check$objects) if (!.is_obj(object) || !all(c("ref","overall","blockers") %in% names(object)) || !(object$overall %in% c("PASS","BLOCKED","UNKNOWN")) || ! .is_arr(object$blockers) || !all(vapply(object$blockers,function(x)is.character(x)&&length(x)==1L,logical(1)))) return(FALSE)
        }
        if (length(checkpoints$checks) && !identical(checkpoints$checks[[length(checkpoints$checks)]]$files,receipt$inputs)) return(FALSE)
      }
      .validate_ref_shape(state, receipt$template_ref); .validate_ref_shape(state, receipt$run_ref); .validate_ref_shape(state, receipt$receipt_ref)
      template <- .record(state, receipt$template_ref)
      started <- .record(state, receipt$run_ref)
      if (template$kind != "analysis" || length(rec$code) != 1L || !identical(receipt$code$path, rec$code[[1L]]$locator$value) || !identical(receipt$code$digest, rec$code[[1L]]$sha256) ||
          !identical(receipt$code$snapshot_digest, rec$code[[1L]]$sha256) || !identical(receipt$code$snapshot, rec$code[[1L]]$snapshot) ||
          !identical(rec$inputs, template$inputs) || !identical(rec$code, template$code) || !identical(rec$method, template$method) ||
          !.result_equal(rec$params, template$params) || !identical(started$inputs, template$inputs) || !identical(started$code, template$code) ||
          !identical(started$design, template$design) || !identical(started$input_mode, template$input_mode) ||
          !identical(started$method, template$method) || !.result_equal(started$params, template$params) || !identical(rec$design, template$design) || !identical(rec$input_mode, template$input_mode) ||
          !identical(receipt$method, rec$method) || !.result_equal(receipt$params, rec$params)) return(FALSE)
      if (!identical(receipt$run_ref$id, rec$id) || receipt$run_ref$revision != 1L || !identical(receipt$receipt_ref$id, rec$id) || receipt$receipt_ref$revision != rec$revision ||
          !is.character(receipt$started_at_utc) || length(receipt$started_at_utc) != 1L || (!is.null(receipt$ended_at_utc) && (!is.character(receipt$ended_at_utc) || length(receipt$ended_at_utc) != 1L))) return(FALSE)
      phases <- receipt$phases
      if ((phases$callback_invoked && (!phases$code_executed || !phases$execution_started)) || (phases$code_executed && !phases$execution_started) ||
          (receipt$status == "started" && (phases$execution_started || phases$code_executed || phases$callback_invoked)) ||
          (receipt$status == "blocked" && (phases$execution_started || phases$code_executed || phases$callback_invoked)) ||
          (receipt$status == "failed" && !phases$execution_started) ||
          (receipt$status %in% c("succeeded", "incomplete") && (!phases$execution_started || !phases$code_executed || !phases$callback_invoked))) return(FALSE)
      if ((receipt$status == "started") != is.null(receipt$ended_at_utc) || (receipt$status == "succeeded" && !is.null(receipt$error)) ||
          (receipt$status %in% c("failed", "blocked", "incomplete") && (!is.character(receipt$error) || length(receipt$error) != 1L))) return(FALSE)
      if ((receipt$status == "started" && (rec$revision != 1L || !is.null(receipt$error))) || (receipt$status != "started" && rec$revision != 2L)) return(FALSE)
      if (length(receipt$inputs) != length(rec$inputs)) return(FALSE)
      for (i in seq_along(receipt$inputs)) {
        item <- receipt$inputs[[i]]
        if (!.is_obj(item) || !all(c("ref", "path", "identity", "reason") %in% names(item)) || !identical(item$ref, rec$inputs[[i]]) ||
            !item$identity %in% c("match", "unknown", "mismatch") || !is.character(item$reason) || length(item$reason) != 1L) return(FALSE)
        if (identical(item$identity, "match") && (is.null(.record(state, item$ref)$sha256) || !item$reason %in% c("digest_match", "sha256_match") || !is.character(item$path) || length(item$path) != 1L)) return(FALSE)
      }
      if ("input_checkpoints" %in% names(receipt)) {
        cp <- receipt$input_checkpoints
        if (!.is_obj(cp) || !setequal(names(cp),c("version","checks")) || !identical(cp$version,"biodataledger-input-checkpoints/1") || !.is_arr(cp$checks) || length(cp$checks)>3L) return(FALSE)
        order <- c("preflight","before_callback","after_callback")
        for (i in seq_along(cp$checks)) {
          check <- cp$checks[[i]]
          if (!.is_obj(check) || !setequal(names(check),c("phase","files","objects")) || !identical(check$phase,order[[i]]) || !.is_arr(check$files) || length(check$files)!=length(receipt$inputs) || !.is_arr(check$objects) || length(check$objects)>100L) return(FALSE)
          for (j in seq_along(check$files)) {
            item <- check$files[[j]]
            if (!.is_obj(item) || !identical(item$ref,receipt$inputs[[j]]$ref) || !item$identity %in% c("match","mismatch","unknown") || !is.character(item$reason) || length(item$reason)!=1L) return(FALSE)
          }
          for (item in check$objects) {
            if (!.is_obj(item) || !setequal(names(item),c("ref","overall","blockers")) || !any(vapply(receipt$inputs,function(x)identical(x$ref,item$ref),logical(1))) || !item$overall %in% c("PASS","BLOCKED","UNKNOWN") || !.is_arr(item$blockers) || length(item$blockers)>100L || any(!vapply(item$blockers,function(x)is.character(x)&&length(x)==1L&&nzchar(x),logical(1)))) return(FALSE)
          }
        }
        if (length(cp$checks) && !identical(cp$checks[[length(cp$checks)]]$files,receipt$inputs)) return(FALSE)
        if (receipt$status=="succeeded" && (length(cp$checks)!=3L || any(!vapply(cp$checks[[3L]]$objects,function(x)identical(x$overall,"PASS"),logical(1))))) return(FALSE)
      }
      for (item in receipt$outputs) {
        if (!.is_obj(item) || !all(c("path", "kind", "status") %in% names(item)) || !is.character(item$path) || length(item$path) != 1L ||
            !item$kind %in% c("result", "figure") || !item$status %in% c("not_observed", "missing", "unreadable", "observed", "registered", "registration_failed")) return(FALSE)
        if (identical(item$kind, "figure") && (!is.character(item$type) || length(item$type) != 1L)) return(FALSE)
        if (identical(item$status, "registered")) {
          if (!.is_sha(item$digest)) return(FALSE)
          target <- tryCatch(.record(state, item$record_ref), error = function(e) NULL)
          if (is.null(target) || !identical(target$sha256, item$digest) || (item$kind == "result" && (target$kind != "data" || !identical(target$scope$transformation_ref, receipt$run_ref))) ||
              (item$kind == "figure" && (target$kind != "figure" || !identical(target$analysis, receipt$run_ref) || !identical(target$type, item$type)))) return(FALSE)
        }
      }
      if (receipt$status == "succeeded" && any(vapply(receipt$outputs, function(x) !identical(x$status, "registered"), logical(1)))) return(FALSE)
      if (receipt$status == "started" && (any(vapply(receipt$inputs, function(x) !identical(x$identity, "unknown"), logical(1))) || any(vapply(receipt$outputs, function(x) !identical(x$status, "not_observed"), logical(1))))) return(FALSE)
      if (receipt$status == "blocked" && any(vapply(receipt$outputs, function(x) !identical(x$status, "not_observed"), logical(1)))) return(FALSE)
      if (receipt$status == "incomplete" && !any(vapply(receipt$outputs, function(x) !identical(x$status, "registered"), logical(1)))) return(FALSE)
      TRUE
    }
}
