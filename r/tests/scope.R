library(BioDataLedger)
root <- tempfile('bdl-scope-r-'); dir.create(root)
writeLines('sample,cell\ns1,c1', file.path(root, 'members.csv'))
writeLines('sample,cell,value\ns1,c1,1', file.path(root, 'subject.csv'))
b <- ProjectBundle$create('scope', root)
writeLines('print(1)', file.path(root, 'ghost.R'))
stopifnot(inherits(try(b$register_analysis('bad', inputs = NULL, code = 'ghost.R', params = list()), silent = TRUE), 'try-error'))
stopifnot(!b$summary()$unsaved, b$summary()$records == 0L)
ghost_hash <- digest::digest(file = file.path(root, 'ghost.R'), algo = 'sha256', serialize = FALSE)
m <- b$register_data('members.csv', 'membership', hash = TRUE)
d <- b$register_data('subject.csv', 'input', hash = TRUE, membership = m)
writeLines('print(2)', file.path(root, 'plot.R'))
writeLines('<svg/>', file.path(root, 'figure.svg'))
a <- b$register_analysis('figure analysis', list(d), code = 'plot.R', snapshot_code = FALSE)
f <- b$register_figure('figure.svg', 'qc', analysis = a)
figure_json <- jsonlite::fromJSON(jsonlite::toJSON(b$get_figure(f), auto_unbox = TRUE, null = 'null'), simplifyVector = FALSE)
stopifnot('available' %in% names(figure_json), is.null(figure_json$available),
          'design_ref' %in% names(figure_json), is.null(figure_json$design_ref),
          'available' %in% names(figure_json$input_availability[[1]]), is.null(figure_json$input_availability[[1]]$available),
          'available' %in% names(figure_json$code_availability[[1]]), is.null(figure_json$code_availability[[1]]$available))

des <- b$set_design('condition', c('treated', 'control'), selected_levels = 'treated')
stopifnot(identical(b$get_data(role = 'input')$ref, d))
stopifnot(is.null(b$get_data(ref = d)$available), identical(b$get_data(ref = d)$availability_checked, FALSE))
legacy_json <- jsonlite::fromJSON(jsonlite::toJSON(b$get_data(ref = d), auto_unbox = TRUE, null = 'null'), simplifyVector = FALSE)
stopifnot(all(c('available', 'design_ref', 'design', 'scope') %in% names(legacy_json)),
          is.null(legacy_json$available), is.null(legacy_json$design_ref),
          is.null(legacy_json$design), is.null(legacy_json$scope))
missing_status <- jsonlite::fromJSON(jsonlite::toJSON(b$status(purpose = 'unset'), auto_unbox = TRUE, null = 'null'), simplifyVector = FALSE)
stopifnot('dataset' %in% names(missing_status), is.null(missing_status$dataset))

stopifnot(isTRUE(b$get_data(ref = d, check_files = TRUE)$available))
stopifnot(inherits(try(b$resolve_data(ref = d), silent = TRUE), 'try-error'))
scope <- list(condition_values = list('treated'), observation_unit = 'cell', evidence = list(basis = 'declared', source_refs = list()))
d2 <- b$set_data_scope(d, scope, 'scientist selection', design_ref = des)
stopifnot(identical(b$get_data(ref = d2)$design_ref, des), is.null(b$get_data(ref = d)$scope))
stopifnot(identical(b$get_data(role = 'input')$scope, b$get_data(ref = d2)$scope), identical(b$get_data(role = 'input')$design_ref, des))

view <- b$resolve_data(ref = d2, verify = 'sha256', expected_scope = list(condition_values = list('treated')))
stopifnot(identical(view$verification$file_integrity, 'match'), identical(view$verification$required_scope, 'match'))
stopifnot(isTRUE(view$available), isTRUE(view$availability_checked))
expect_code <- function(code, expr) {
  result <- tryCatch({force(expr); NULL}, error = function(e) conditionMessage(e))
  if (!is.character(result) || !startsWith(result, code)) stop(paste(code, result))
}
expect_code('SCOPE_CONFLICT', b$resolve_data(ref = d2, verify = 'sha256', expected_scope = list(condition_values = list('control'))))
expect_code('SCOPE_UNKNOWN', b$resolve_data(ref = d2, verify = 'sha256', expected_scope = list(assay = 'RNA')))
expect_code('MEMBERSHIP_EVIDENCE', b$resolve_data(ref = d2, verify = 'sha256', require_membership = TRUE))
report <- list(report_version = 'biodataledger-membership-check/1',
               subject_sha256 = b$get_data(ref = d)$sha256,
               membership_ref = m[c('id', 'project_id', 'revision')], membership_sha256 = b$get_data(ref = m)$sha256,
               key_columns = list('sample', 'cell'), key_namespace = 'sample+cell',
               comparison = 'set_keys', result = 'match', checked_at = '2026-11-03T00:00:00Z',
               checker = list(method = 'independent CSV comparison', origin = 'native_check', analysis_ref = NULL),
               counts = list(subject_rows = 1L, membership_rows = 1L,
                             subject_duplicate_keys = 0L, membership_duplicate_keys = 0L,
                             missing_keys = 0L, extra_keys = 0L),
               observed_scope = list(condition_values = list('treated')))
jsonlite::write_json(report, file.path(root, 'report.json'), auto_unbox = TRUE, null = 'null')
rep_ref <- b$register_data('report.json', 'membership_report', hash = TRUE)
scope$membership_evidence <- list(status = 'verification_recorded', report_ref = rep_ref)
d3 <- b$set_data_scope(d2, scope, 'report checked', design_ref = des)
invalid_date_report <- report
invalid_date_report$checked_at <- '2026-02-30T00:00:00Z'
jsonlite::write_json(invalid_date_report, file.path(root, 'invalid_date_report.json'), auto_unbox = TRUE, null = 'null')
invalid_date_ref <- b$register_data('invalid_date_report.json', 'membership_report', hash = TRUE)
invalid_date_scope <- scope; invalid_date_scope$membership_evidence$report_ref <- invalid_date_ref
before_invalid_date <- b$summary()$records
expect_code('MEMBERSHIP_EVIDENCE', b$set_data_scope(d2, invalid_date_scope, 'invalid calendar date', design_ref = des))
stopifnot(b$summary()$records == before_invalid_date)
bad_report <- report
bad_report$observed_scope <- list(condition_values = list('control'))
jsonlite::write_json(bad_report, file.path(root, 'bad_report.json'), auto_unbox = TRUE, null = 'null')
bad_ref <- b$register_data('bad_report.json', 'membership_report', hash = TRUE)
bad_scope <- scope; bad_scope$membership_evidence$report_ref <- bad_ref
before_bad <- b$summary()$records
expect_code('SCOPE_CONFLICT', b$set_data_scope(d2, bad_scope, 'contradictory report', design_ref = des))
stopifnot(b$summary()$records == before_bad, identical(b$get_data(ref = d3)$scope$condition_values, list('treated')))
stopifnot(identical(b$resolve_data(ref = d3, verify = 'sha256', require_membership = TRUE)$verification$membership, 'verified_against_recorded_evidence'))
stopifnot(identical(b$resolve_data(ref = d3, verify = 'sha256')$verification$membership, 'verification_recorded_not_rechecked'))
expect_code('MEMBERSHIP_EVIDENCE', b$update_record(d3, list(path = 'subject.csv'), 'bad correction'))
writeLines('tampered', file.path(root, 'members.csv'))
expect_code('SIZE_MISMATCH', b$resolve_data(ref = d3, verify = 'sha256', require_membership = TRUE))
# Scope recording verifies report bindings without reading the changed membership bytes.
d4 <- b$set_data_scope(d2, scope, 'recorded report binding', design_ref = NULL)
stopifnot(is.null(b$get_data(ref = d4)$design_ref), 'design' %in% names(b$get_data(ref = d4)))
# Restore the original independently generated membership file for the remaining checks.
writeLines('sample,cell\ns1,c1', file.path(root, 'members.csv'))
stopifnot(b$status()$missing$checked == 0L, is.null(b$status()$missing$found), !b$status()$availability_checked)
b$set_current(d2, 'comparison', 'confirmed')
b$save()
stopifnot(!file.exists(file.path(root, '.nb_project_bundle', 'code', ghost_hash)))
b$set_design('condition', c('treated', 'control'), selected_levels = 'treated')
b$save()
stopifnot(identical(jsonlite::fromJSON(file.path(root, '.nb_project_bundle', 'project.json'))$schema_version, '0.4.0'))
opened <- ProjectBundle$open(root)
stopifnot(identical(opened$get_data(purpose = 'comparison')$ref, d2), identical(opened$get_data(ref = d)$scope, NULL))
writeLines('sample,cell,value\ns1,c1,2', file.path(root, 'subject.csv'))
expect_code('DIGEST_MISMATCH', opened$resolve_data(purpose = 'comparison', verify = 'sha256'))
opened$set_context(list(next_task = opened$summary()$next_task))
stopifnot(!opened$status()$unsaved)
# Active role buckets follow only latest revisions and preserve ambiguity.
other_input <- b$register_data('figure.svg', 'input', hash = FALSE)
stopifnot(inherits(try(b$get_data(role = 'input'), silent = TRUE), 'try-error'))
other_inactive <- b$update_record(other_input, list(status = 'inactive'), 'not a selected input')
stopifnot(identical(b$get_data(role = 'input')$ref, d4))
original_inactive <- b$update_record(d4, list(status = 'inactive'), 'temporary deactivation')
stopifnot(inherits(try(b$get_data(role = 'input'), silent = TRUE), 'try-error'))
reactivated <- b$update_record(original_inactive, list(status = 'active'), 'reactivation')
stopifnot(identical(b$get_data(role = 'input')$ref, reactivated),
          identical(b$get_data(role = 'input')$scope, b$get_data(ref = reactivated)$scope))

# Migrate unchecked metadata retrieval to strict native input resolution.
check_native_input_resolution_migration <- function() {
  root <- tempfile('native-input-migration-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  selected_path <- file.path(root, 'selected.rds')
  other_path <- file.path(root, 'other.rds')
  # These opaque bytes are not RDS objects and must never be deserialized.
  original <- charToRaw('opaque-selected-v1')
  writeBin(original, selected_path); writeBin(charToRaw('plausible-other-input'), other_path)
  p <- ProjectBundle$create('native input migration', root)
  selected <- p$register_data('selected.rds', 'analysis_ready', hash = TRUE)
  other <- p$register_data('other.rds', 'analysis_ready', hash = TRUE)
  p$set_current(selected, 'qc', 'explicit synthetic input selection'); p$save()
  registry <- file.path(root, '.nb_project_bundle', 'project.json')
  before <- readBin(registry, 'raw', file.info(registry)$size)
  history <- jsonlite::fromJSON(rawToChar(before), simplifyVector = FALSE)$history
  baseline <- p$get_data(ref = selected)
  digest <- get('digest', asNamespace('digest'))
  on.exit(assignInNamespace('digest', digest, ns = 'digest'), add = TRUE)
  for (case in c('existing', 'tampered', 'missing')) {
    if (case == 'tampered') {
      changed <- charToRaw('opaque-selected-v2')
      stopifnot(length(changed) == length(original)); writeBin(changed, selected_path)
    }
    if (case == 'missing') unlink(selected_path)
    assignInNamespace('digest', function(...) stop('metadata retrieval must not hash'), ns = 'digest')
    unchecked <- p$get_data(purpose = 'qc')
    exists_only <- p$get_data(purpose = 'qc', check_files = TRUE)
    assignInNamespace('digest', digest, ns = 'digest')
    stopifnot(is.null(unchecked$available), identical(unchecked$availability_checked, FALSE),
              identical(exists_only$availability_checked, TRUE),
              identical(exists_only$available, case != 'missing'),
              identical(unchecked$ref, selected), identical(unchecked$path, baseline$path),
              identical(unchecked$sha256, baseline$sha256),
              identical(p$get_data(ref = other)$status, 'active'), file.exists(other_path))
    if (case == 'existing') {
      verified <- p$resolve_data(purpose = 'qc', verify = 'sha256')
      stopifnot(identical(verified$ref, selected), identical(verified$path, baseline$path),
                identical(verified$path, normalizePath(selected_path)),
                identical(verified$sha256, baseline$sha256), identical(verified$available, TRUE),
                identical(verified$availability_checked, TRUE),
                identical(verified$verification$file_integrity, 'match'),
                identical(verified$verification$baseline_sha256, baseline$sha256),
                identical(verified$verification$observed_sha256, baseline$sha256))
    } else {
      expect_code(if (case == 'tampered') 'DIGEST_MISMATCH' else 'MISSING_FILE',
                  p$resolve_data(purpose = 'qc', verify = 'sha256'))
    }
    after <- readBin(registry, 'raw', file.info(registry)$size)
    stopifnot(identical(after, before), !p$status()$unsaved,
              identical(jsonlite::fromJSON(rawToChar(after), simplifyVector = FALSE)$history, history),
              identical(p$get_data(purpose = 'qc')$ref, selected),
              identical(p$get_data(purpose = 'qc')$sha256, baseline$sha256))
  }
}
check_native_input_resolution_migration()
