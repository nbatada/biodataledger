# Recorded comparison evidence, never scientific approval or execution.
.comparison_plan_key <- "comparison_plan"
.comparison_assessment_key <- "comparison_assessment"
.comparison_keys <- c(.comparison_plan_key, .comparison_assessment_key)
.comparison_typed_keys <- c(.comparison_keys, .scientific_decision_key, .analysis_protocol_key)
.comparison_limit <- 65536L

.comparison_text <- function(value) is.character(value) && length(value) == 1L && !is.na(value) && nzchar(trimws(value))
.comparison_bound <- function(value) {
  if (nchar(.json(value), type = "bytes") > .comparison_limit) .fail("Comparison metadata exceeds 64 KiB limit")
  refs <- character(); visit <- function(item) {
    if (.is_obj(item) && setequal(names(item), c("project_id", "id", "revision"))) refs <<- c(refs, paste(item$project_id, item$id, item$revision, sep = "\r"))
    else if (is.list(item)) for (child in item) visit(child)
  }; visit(value)
  if (length(unique(refs)) > 100L) .fail("Comparison exceeds 100 distinct references")
  value
}
.comparison_refs <- function(state, value) {
  if (!.is_arr(value) || length(value) > 100L) .fail("Bounded reference list required")
  .arr(lapply(value, function(x) .make_ref(state, .record(state, x))))
}
.comparison_side <- function(state, value) {
  if (!.is_obj(value) || !setequal(names(value), c("analysis_ref", "outputs"))) .fail("analysis_ref and outputs required")
  analysis_rec <- .record(state, value$analysis_ref); analysis <- .make_ref(state, analysis_rec); if (analysis_rec$kind != "analysis") .fail("Comparison analysis_ref must reference analysis")
  .comparison_bound(analysis_rec)
  if (!.is_arr(value$outputs) || !length(value$outputs) || length(value$outputs) > 20L) .fail("1-20 output slots required")
  ids <- character(); outputs <- lapply(value$outputs, function(item) {
    if (!.is_obj(item) || !setequal(names(item), c("slot_id", "ref")) || !.comparison_text(item$slot_id) || item$slot_id %in% ids) .fail("Unique output slot required")
    ids <<- c(ids, item$slot_id); record <- .record(state, item$ref)
    if (!record$kind %in% c("data", "figure")) .fail("Output must be DATA or FIG")
    .obj(slot_id = item$slot_id, ref = .make_ref(state, record))
  })
  .obj(analysis_ref = analysis, outputs = .arr(outputs))
}
.comparison_plan <- function(state, mode, original, intended, criteria) {
  if (!is.character(mode) || length(mode) != 1L || !mode %in% c("reproduce", "reapply", "rerender")) .fail("Invalid comparison mode")
  original <- .comparison_side(state, original)
  fields <- c("input_refs", "protocol_ref", "approval_ref", "source_protocol_ref", "source_approval_ref", "input_mapping", "visual_changes", "environment_ref", "retrospective")
  if (!.is_obj(intended) || !all(c("input_refs", "retrospective") %in% names(intended)) || !all(names(intended) %in% fields)) .fail("Explicit intended inputs/retrospective required")
  target <- .obj(input_refs = list(), protocol_ref = NULL, approval_ref = NULL, source_protocol_ref = NULL, source_approval_ref = NULL, input_mapping = list(), visual_changes = .obj(), environment_ref = NULL)
  for (field in names(intended)) target[field] <- list(.copy(intended[[field]]))
  target$input_refs <- .comparison_refs(state, target$input_refs)
  if (!is.logical(target$retrospective) || length(target$retrospective) != 1L || is.na(target$retrospective) || !.is_obj(target$visual_changes)) .fail("Invalid comparison intent")
  for (ref in target$input_refs) if (.record_kind(state, ref) != "data") .fail("Comparison intended inputs must be DATA")
  for (field in c("protocol_ref", "approval_ref", "source_protocol_ref", "source_approval_ref", "environment_ref")) if (!is.null(target[[field]])) {
    record <- .record(state, target[[field]])
    if (field != "environment_ref" && record$kind != "decision") .fail("Comparison protocol/approval references must be DEC")
    target[[field]] <- .make_ref(state, record)
  }
  if (!.is_arr(target$input_mapping) || length(target$input_mapping) > 100L) .fail("Bounded input mapping required")
  target$input_mapping <- .arr(lapply(target$input_mapping, function(item) {
    if (!.is_obj(item) || !setequal(names(item), c("index", "from", "to")) || !.is_int(item$index) || item$index < 0L) .fail("Mapping index/from/to required")
    from <- .make_ref(state, .record(state, item$from)); to <- .make_ref(state, .record(state, item$to))
    if (.record_kind(state, from) != "data" || .record_kind(state, to) != "data") .fail("Mapping must reference DATA")
    .obj(index = item$index, from = from, to = to)
  }))
  if (mode != "reapply" && length(target$input_mapping)) .fail("Input mapping only for reapply")
  if (mode != "rerender" && length(target$visual_changes)) .fail("Visual changes only for rerender")
  if (!.is_arr(criteria) || !length(criteria) || length(criteria) > 20L) .fail("1-20 criteria required")
  slots <- vapply(original$outputs, `[[`, "slot_id", FUN.VALUE = character(1)); ids <- character()
  requirements <- list(manual = c("rubric", "scope"), numeric = c("metric", "units", "operator", "threshold", "alignment", "aggregation", "missing", "nonfinite", "exclusions"), bytes = "algorithm", structural = c("keys", "order", "duplicates"))
  normalized <- lapply(criteria, function(item) {
    if (!.is_obj(item) || !setequal(names(item), c("criterion_id", "required", "domain", "slots", "requirement", "comparator_ref", "comparison_kind")) || !.comparison_text(item$criterion_id) || item$criterion_id %in% ids || !is.logical(item$required) || length(item$required) != 1L || is.na(item$required)) .fail("Invalid comparison criterion")
    ids <<- c(ids, item$criterion_id)
    if (!is.character(item$domain) || length(item$domain) != 1L || !item$domain %in% c("identity", "method", "output", "visual") || !is.character(item$comparison_kind) || length(item$comparison_kind) != 1L || is.null(requirements[[item$comparison_kind]])) .fail("Invalid comparison criterion kind/domain")
    if (!.is_arr(item$slots) || !length(item$slots) || any(!vapply(item$slots, .comparison_text, logical(1))) || !all(unlist(item$slots, use.names = FALSE) %in% slots) || anyDuplicated(unlist(item$slots, use.names = FALSE))) .fail("Invalid comparison criterion slots")
    required <- requirements[[item$comparison_kind]]
    if (!.is_obj(item$requirement) || !all(required %in% names(item$requirement)) || any(vapply(required, function(key) is.null(item$requirement[[key]]), logical(1)))) .fail("Explicit comparison requirements missing")
    if (any(vapply(required, function(key) is.character(item$requirement[[key]]) && !.comparison_text(item$requirement[[key]]), logical(1)))) .fail("Blank comparison requirements")
    if (identical(item$comparison_kind, "numeric") && (!item$requirement$operator %in% c("<", "<=", "==", ">=", ">") || !is.numeric(item$requirement$threshold) || length(item$requirement$threshold) != 1L || !is.finite(item$requirement$threshold))) .fail("Numeric operator/finite threshold required")
    comparator <- .record(state, item$comparator_ref); if (!comparator$kind %in% c("analysis", "data", "decision")) .fail("Comparison comparator reference required")
    out <- .copy(item); out$slots <- .arr(as.list(unlist(item$slots, use.names = FALSE))); out$comparator_ref <- .make_ref(state, comparator); out
  })
  if (!any(vapply(normalized, function(x) isTRUE(x$required) && x$domain %in% c("output", "visual"), logical(1)))) .fail("Required output/visual criterion required")
  .comparison_bound(.obj(record_type = .comparison_plan_key, version = "biodataledger-comparison-plan/1", mode = mode, original = original, intended = target, criteria = .arr(normalized)))
}
.comparison_assessment <- function(state, plan_ref, candidate, observations) {
  plan_rec <- .record(state, plan_ref); if (plan_rec$kind != "decision") .fail("Comparison plan required")
  plan_ref <- .make_ref(state, plan_rec)
  if (!identical(intersect(.comparison_typed_keys, names(plan_rec$details)), .comparison_plan_key)) .fail("Exact comparison plan required")
  plan <- .comparison_read(state, plan_rec)$descriptor
  if (is.null(plan) || !identical(plan$record_type, .comparison_plan_key)) .fail("Comparison plan required")
  candidate <- .comparison_side(state, candidate)
  if (!identical(vapply(candidate$outputs, `[[`, character(1), "slot_id"), vapply(plan$original$outputs, `[[`, character(1), "slot_id"))) .fail("Candidate output slots must match plan")
  if (!.is_arr(observations) || length(observations) > 20L) .fail("Bounded observations required")
  ids <- character(); known <- vapply(plan$criteria, `[[`, "criterion_id", FUN.VALUE = character(1))
  normalized <- lapply(observations, function(item) {
    required <- c("criterion_id", "verdict", "observed", "reason", "evidence", "subjects", "comparator_ref"); allowed <- c(required, "contradictory_evidence", "independent_review_ref")
    if (!.is_obj(item) || !all(required %in% names(item)) || !all(names(item) %in% allowed) || !.comparison_text(item$criterion_id) || !item$criterion_id %in% known || item$criterion_id %in% ids || !is.character(item$verdict) || length(item$verdict) != 1L || !item$verdict %in% c("PASS", "FAIL", "UNKNOWN") || !.comparison_text(item$reason)) .fail("Invalid comparison observation")
    ids <<- c(ids, item$criterion_id); if (!.is_arr(item$evidence) || length(item$evidence) > 10L) .fail("At most10 evidence refs")
    out <- .obj(contradictory_evidence = list(), independent_review_ref = NULL); for (key in names(item)) out[key] <- list(.copy(item[[key]])); out$evidence <- .comparison_refs(state, out$evidence); out$subjects <- .comparison_refs(state, out$subjects)
    if (!.is_arr(out$contradictory_evidence) || length(out$contradictory_evidence) > 10L) .fail("At most10 contradictory refs")
    out$contradictory_evidence <- .comparison_refs(state, out$contradictory_evidence)
    if (!is.null(out$independent_review_ref)) { review <- .record(state, out$independent_review_ref); if (review$kind != "decision") .fail("Independent review must be DEC"); out$independent_review_ref <- .make_ref(state, review) }
    if (!is.null(out$comparator_ref)) out$comparator_ref <- .make_ref(state, .record(state, out$comparator_ref)); out
  })
  .comparison_bound(.obj(record_type = .comparison_assessment_key, version = "biodataledger-comparison-assessment/1", plan_ref = plan_ref, candidate = candidate, observations = .arr(normalized)))
}
.comparison_read <- function(state, rec) {
  present <- intersect(.comparison_typed_keys, names(rec$details))
  if (length(present) != 1L || !present %in% .comparison_keys) return(.obj(record_type = NULL, descriptor = NULL, issue = if (length(intersect(.comparison_keys, names(rec$details)))) "malformed_or_unsupported_comparison" else NULL))
  key <- present; value <- rec$details[[key]]
  tryCatch({
    if (!.is_obj(value) || !identical(value$record_type, key)) .fail("Invalid comparison record type")
    normalized <- if (identical(key, .comparison_plan_key)) .comparison_plan(state, value$mode, value$original, value$intended, value$criteria) else .comparison_assessment(state, value$plan_ref, value$candidate, value$observations)
    if (!.protocol_same(value, normalized)) .fail("Noncanonical comparison")
    .obj(record_type = key, descriptor = normalized, issue = NULL)
  }, error = function(e) .obj(record_type = key, descriptor = NULL, issue = "malformed_or_unsupported_comparison"))
}
.comparison_context <- function(state, get_execution, get_decision, get_protocol, compare_protocol, plan, candidate) {
  checks <- list(); add <- function(check, verdict) checks[[length(checks) + 1L]] <<- .obj(check = check, verdict = verdict)
  original <- plan$original; intended <- plan$intended; mode <- plan$mode; old <- .record(state, original$analysis_ref); new <- .record(state, candidate$analysis_ref)
  add("distinct_candidate_run", if (!identical(original$analysis_ref$id, candidate$analysis_ref$id)) "PASS" else "FAIL")
  add("distinct_candidate_outputs", if (all(vapply(seq_along(original$outputs), function(i) !.protocol_same(original$outputs[[i]]$ref, candidate$outputs[[i]]$ref), logical(1)))) "PASS" else "FAIL")
  add("intended_inputs", if (is.null(new$inputs)) "UNKNOWN" else if (.protocol_same(new$inputs, intended$input_refs)) "PASS" else "FAIL")
  if (mode %in% c("reproduce", "rerender")) add("same_inputs", if (is.null(old$inputs) || is.null(new$inputs)) "UNKNOWN" else if (.protocol_same(old$inputs, new$inputs)) "PASS" else "FAIL") else {
    count <- min(length(old$inputs), length(intended$input_refs))
    expected <- .arr(lapply(seq_len(count), function(i) .obj(index = i - 1L, from = old$inputs[[i]], to = intended$input_refs[[i]])))
    add("input_mapping", if (!is.null(old$inputs) && length(old$inputs) == length(intended$input_refs) && .protocol_same(intended$input_mapping, expected)) "PASS" else "FAIL")
    approval <- function(ref, subject) { if (is.null(ref) || is.null(subject)) return("UNKNOWN"); view <- tryCatch(get_decision(ref), error = function(e) NULL); if (is.null(view) || isTRUE(state$imported) || is.null(view$scientific)) "UNKNOWN" else if (identical(view$scientific$scientific_status, "approved") && .protocol_same(.arr(lapply(view$scientific$subjects, `[[`, "ref")), .arr(list(subject)))) "PASS" else "FAIL" }
    add("source_approval", approval(intended$source_approval_ref, intended$source_protocol_ref)); add("target_approval", approval(intended$approval_ref, intended$protocol_ref))
  }
  for (field in if (identical(mode, "rerender")) "method" else c("method", "code")) add(paste0("same_", field), if (is.null(old[[field]]) || !length(old[[field]]) || is.null(new[[field]]) || !length(new[[field]])) "UNKNOWN" else if (.protocol_same(old[[field]], new[[field]])) "PASS" else "FAIL")
  expected_params <- .copy(old$params); observed_params <- .copy(new$params); dynamic <- list()
  if (!is.null(intended$protocol_ref)) { protocol <- get_protocol(intended$protocol_ref)$protocol; if (!is.null(protocol) && length(protocol$steps) == 1L) dynamic <- protocol$steps[[1]]$data_dependent_params }
  for (key in dynamic) { if (.is_obj(expected_params)) expected_params[[key]] <- NULL; if (.is_obj(observed_params)) { if (!key %in% names(observed_params)) add(paste0("data_dependent_", key), "UNKNOWN"); observed_params[[key]] <- NULL } }
  if (identical(mode, "rerender") && .is_obj(expected_params)) for (key in names(intended$visual_changes)) expected_params[key] <- list(.copy(intended$visual_changes[[key]]))
  add("parameters", if (is.null(expected_params) || is.null(observed_params)) "UNKNOWN" else if (.protocol_same(expected_params, observed_params)) "PASS" else "FAIL")
  for (side_name in c("original", "candidate")) { side <- if (side_name == "original") original else candidate; receipt <- get_execution(side$analysis_ref); add(paste0(side_name, "_execution"), if (identical(receipt$status, "unknown") || isTRUE(state$imported)) "UNKNOWN" else if (identical(receipt$status, "succeeded")) "PASS" else "FAIL"); anchor <- if (is.null(receipt$run_ref)) side$analysis_ref else receipt$run_ref; for (slot in side$outputs) { out <- .record(state, slot$ref); producer <- if (identical(out$kind, "data")) out$scope$transformation_ref else out$analysis; add(paste0(side_name, "_producer_", slot$slot_id), if (is.null(producer)) "UNKNOWN" else if (.protocol_same(producer, anchor)) "PASS" else "FAIL") } }
  if (identical(mode, "rerender")) for (i in seq_along(original$outputs)) { x <- .record(state, original$outputs[[i]]$ref)$details[[.figure_sources_key]]$rendering_inputs; y <- .record(state, candidate$outputs[[i]]$ref)$details[[.figure_sources_key]]$rendering_inputs; add(paste0("same_rendering_result_", original$outputs[[i]]$slot_id), if (is.null(x) || is.null(y) || !length(x) || !length(y)) "UNKNOWN" else if (.protocol_same(x, y)) "PASS" else "FAIL") }
  if (!is.null(intended$environment_ref)) add("environment_verification", "UNKNOWN")
  if (!is.null(intended$protocol_ref)) { protocol <- get_protocol(intended$protocol_ref)$protocol; receipt <- get_execution(candidate$analysis_ref); add("protocol_binding", if (is.null(protocol) || length(protocol$steps) != 1L) "UNKNOWN" else if (.protocol_same(protocol$steps[[1]]$analysis_ref, receipt$template_ref)) "PASS" else "FAIL") }
  if (!is.null(intended$protocol_ref)) { protocol <- get_protocol(intended$protocol_ref)$protocol; if (!is.null(protocol) && length(protocol$steps) == 1L) { step <- protocol$steps[[1]]; compared <- compare_protocol(intended$protocol_ref, list(.obj(step_id = step$step_id, analysis_ref = candidate$analysis_ref))); row <- compared$steps[[1]]; add("protocol_requirements", if (length(row$mismatches)) "FAIL" else if ("execution_receipt" %in% unlist(row$unknown, use.names = FALSE) || any(startsWith(unlist(row$unknown, use.names = FALSE), "data_dependent_param."))) "UNKNOWN" else "PASS") } }
  if (identical(mode, "reapply") && !is.null(intended$source_protocol_ref)) { source <- get_protocol(intended$source_protocol_ref)$protocol; receipt <- get_execution(original$analysis_ref); add("source_protocol_binding", if (is.null(source) || length(source$steps) != 1L) "UNKNOWN" else if (.protocol_same(source$steps[[1]]$analysis_ref, receipt$template_ref)) "PASS" else "FAIL") }
  .arr(checks)
}
