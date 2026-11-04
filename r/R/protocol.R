# Ordered intended protocols; comparison is bounded metadata-only receipt inspection.
.protocol_key <- "analysis_protocol"
.protocol_version <- "biodataledger-protocol/1"
.protocol_limit <- 65536L

.protocol_output <- function(value) {
  if (!.is_obj(value) || !identical(value$kind, "result") && !identical(value$kind, "figure")) .fail("Invalid required output")
  allowed <- if (identical(value$kind, "result")) "kind" else c("kind", "type")
  if (!setequal(names(value), allowed) || identical(value$kind, "figure") && (!is.character(value$type) || length(value$type) != 1L || !nzchar(value$type))) .fail("Invalid required output")
  .copy(value)
}

.protocol_descriptor <- function(state, steps, reason) {
  if (!is.character(reason) || length(reason) != 1L || !nzchar(trimws(reason))) .fail("Protocol reason required")
  if (!.is_arr(steps) || !length(steps) || length(steps) > 100L) .fail("Steps must be an array of 1 to 100 items")
  ids <- character(); expanded <- 0L; normalized <- lapply(steps, function(step) {
    if (!.is_obj(step) || !all(c("step_id", "analysis_ref", "required_outputs") %in% names(step)) || !all(names(step) %in% c("step_id", "analysis_ref", "data_dependent_params", "required_outputs", "seeds", "environment_ref")) ||
        !is.character(step$step_id) || length(step$step_id) != 1L || !nzchar(trimws(step$step_id)) || step$step_id %in% ids) .fail("Invalid protocol step")
    ids <<- c(ids, step$step_id); analysis <- .record(state, step$analysis_ref)
    if (analysis$kind != "analysis") .fail("Protocol analysis_ref must reference analysis")
    bytes <- nchar(.json(analysis), type = "bytes"); if (bytes > .protocol_limit) .fail("Protocol analysis metadata exceeds 64 KiB limit")
    expanded <<- expanded + bytes; if (expanded > 1048576L) .fail("Protocol expanded analysis metadata exceeds 1 MiB limit")
    if (is.null(analysis$inputs) || !is.character(analysis$method) || length(analysis$method) != 1L || !nzchar(analysis$method) || !.is_obj(analysis$params) || !length(analysis$code)) .fail("Protocol analysis must declare inputs, method, params and code")
    dynamic <- if (!"data_dependent_params" %in% names(step)) list() else step$data_dependent_params
    if (!.is_arr(dynamic) || any(!vapply(dynamic, function(x) is.character(x) && length(x) == 1L && nzchar(x), logical(1))) || anyDuplicated(unlist(dynamic, use.names = FALSE))) .fail("data_dependent_params must be unique parameter names")
    dynamic <- unlist(dynamic, use.names = FALSE)
    if (length(dynamic) && !.is_obj(analysis$params) || length(dynamic) && !all(dynamic %in% names(analysis$params))) .fail("Data-dependent parameter missing from pinned analysis")
    if (!.is_arr(step$required_outputs) || length(step$required_outputs) > 100L) .fail("required_outputs must be an array of at most 100 items")
    if (!is.null(step$seeds) && !.is_obj(step$seeds)) .fail("Protocol seeds must be object or null")
    environment <- if (is.null(step$environment_ref)) NULL else .make_ref(state, .record(state, step$environment_ref))
    .obj(step_id = step$step_id, analysis_ref = .make_ref(state, analysis), data_dependent_params = .arr(as.list(dynamic)),
         required_outputs = .arr(lapply(step$required_outputs, .protocol_output)), seeds = .copy(step$seeds), environment_ref = environment)
  })
  out <- .obj(version = .protocol_version, reason = reason, targets = .arr(lapply(normalized, `[[`, "analysis_ref")), steps = .arr(normalized))
  if (nchar(.json(out), type = "bytes") > .protocol_limit) .fail("Protocol exceeds 64 KiB metadata limit")
  out
}

.protocol_read <- function(state, rec) {
  value <- rec$details[[.protocol_key]]
  if (!.is_obj(value) || !identical(value$version, .protocol_version)) return(list(protocol = NULL, issue = "unsupported_analysis_protocol"))
  tryCatch({
    if (!setequal(names(value), c("version", "reason", "targets", "steps")) ||
        "scientific_decision" %in% names(rec$details) || any(.comparison_keys %in% names(rec$details)) ||
        !.protocol_same(value$targets, rec$details$targets) ||
        !identical(value$reason, rec$details$reason)) .fail("Protocol fields")
    normalized <- .protocol_descriptor(state, value$steps, value$reason)
    if (!.protocol_same(normalized, value) || !.protocol_same(value$targets, .arr(lapply(value$steps, `[[`, "analysis_ref")))) .fail("Protocol is not canonical")
    list(protocol = normalized, issue = NULL)
  }, error = function(e) list(protocol = NULL, issue = "malformed_analysis_protocol"))
}

.protocol_timestamp <- function(value) {
  if (!is.character(value) || length(value) != 1L || nchar(value, type = "bytes") != 20L ||
      !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", value)) return(as.POSIXct(NA))
  parsed <- as.POSIXct(value, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  if (is.na(parsed) || !identical(format(parsed, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), value)) as.POSIXct(NA) else parsed
}

.protocol_same <- function(left, right) {
  if (.is_obj(left) && .is_obj(right)) return(setequal(names(left), names(right)) &&
    all(vapply(names(left), function(key) .protocol_same(left[[key]], right[[key]]), logical(1))))
  if (.is_arr(left) && .is_arr(right)) return(length(left) == length(right) &&
    all(vapply(seq_along(left), function(i) .protocol_same(left[[i]], right[[i]]), logical(1))))
  if (is.numeric(left) && is.numeric(right)) return(identical(length(left), length(right)) && all(left == right))
  identical(left, right)
}
