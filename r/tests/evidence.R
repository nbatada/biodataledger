library(BioDataLedger)
check_execution_evidence <- function() {
  root <- tempfile('execution-evidence-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines('synthetic', file.path(root, 'input.txt'))
  writeLines('# declared source only', file.path(root, 'plot.R'))
  writeLines('<svg/>', file.path(root, 'figure.svg'))
  p <- ProjectBundle$create('declared evidence', root)
  d <- p$register_data('input.txt', 'input', hash = TRUE)
  claim <- list(file = 'verified', analytical = 'observed', execution = 'observed')
  a <- p$register_analysis('complete declarations', list(d), code = 'plot.R', method = 'synthetic',
                           params = list(n = 1), provenance = claim)
  f <- p$register_figure('figure.svg', 'summary', analysis = a, provenance = claim)
  view <- p$get_figure(f)
  stopifnot(identical(view$unknown, list('execution_evidence')),
            identical(view$evidence$missing, view$unknown),
            identical(view$evidence$input_relationships, 'declared'),
            identical(view$evidence$code_relationships, 'declared'),
            identical(view$evidence$execution, 'unknown'),
            identical(view$evidence$execution_evidence, 'not_captured'),
            identical(p$get_analysis(a)$details$provenance, list(file = 'unknown', analytical = 'declared')),
            identical(view$details$provenance, list(file = 'captured', analytical = 'declared')),
            identical(p$get_analysis(a)$evidence, view$evidence))
  standalone <- p$register_figure('figure.svg', 'summary')
  missing <- list('inputs', 'method', 'params', 'code', 'analytical_provenance', 'execution_evidence')
  stopifnot(identical(p$get_figure(standalone)$evidence$missing, missing),
            identical(p$get_figure(standalone)$provenance$analytical, 'unknown'))
  empty_object <- structure(list(), names = character())
  empty <- p$register_analysis('empty supplied fields', list(), method = '', params = empty_object)
  stopifnot(identical(p$get_analysis(empty)$evidence$input_relationships, 'declared'),
            identical(p$get_analysis(empty)$evidence$missing, list('code', 'execution_evidence')))
  details <- p$get_analysis(a)$details; details$provenance <- claim
  revised <- p$update_record(a, list(details = details), 'retain an explicit caller claim')
  new_figure <- p$register_figure('figure.svg', 'summary', analysis = revised)
  stopifnot(identical(p$get_figure(f)$evidence$input_relationships, 'declared'),
            identical(p$get_figure(new_figure)$evidence$input_relationships, 'unknown'),
            identical(p$get_figure(new_figure)$provenance$analytical, 'unknown'),
            identical(p$get_analysis(revised)$details$provenance, claim),
            identical(p$get_figure(new_figure)$evidence$missing, list('analytical_provenance', 'execution_evidence')))
  managed <- p$save_figure('figure.svg', ref = f)
  p$set_current(d, 'input', 'scientist fixture selection'); p$save()
  stopifnot(p$resolve_figure(managed, verify = 'sha256')$evidence$execution == 'unknown',
            p$get_figure(f, check_files = TRUE)$code_availability[[1]]$available,
            p$get_figure(f)$evidence$execution == 'unknown')
  # Simulate old, unconstrained labels without changing them when read.
  path <- file.path(root, '.nb_project_bundle', 'project.json')
  state <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  for (i in seq_along(state$records)) {
    rec <- state$records[[i]]
    if (identical(rec$id, f$id)) state$records[[i]]$details$provenance$file <- 'observed'
    if (identical(rec$id, standalone$id)) state$records[[i]]$details$provenance <- 'verified'
  }
  jsonlite::write_json(state, path, auto_unbox = TRUE, null = 'null', digits = 15)
  before <- readBin(path, 'raw', file.info(path)$size)
  q <- ProjectBundle$open(root)
  stopifnot(q$get_figure(f)$provenance$figure_file == 'unknown',
            q$get_figure(f)$details$provenance$file == 'observed',
            q$get_figure(standalone)$provenance$analytical == 'unknown',
            q$get_figure(standalone)$details$provenance == 'verified',
            q$get_analysis(revised)$evidence$execution == 'unknown')
  changed <- q$get_figure(f); changed$evidence$missing <- list('modified view')
  stopifnot(identical(q$get_figure(f)$evidence$missing, list('execution_evidence')))
  constant <- list(execution = 'unknown', execution_evidence = 'not_captured', missing = list('execution_evidence'))
  stopifnot(identical(q$status()$evidence, constant), identical(q$summary()$evidence, constant),
            identical(q$status(purpose = 'input')$evidence, constant),
            nchar(jsonlite::toJSON(q$status(), auto_unbox = TRUE, null = 'null'), type = 'bytes') <= 4096L,
            grepl('Execution evidence: not captured by registry.', q$summary_text(), fixed = TRUE),
            !q$status()$unsaved, identical(readBin(path, 'raw', file.info(path)$size), before))
  archive <- file.path(root, 'working.zip')
  q$export_zip(q$preview_export('working', list(d, f)), archive)
  imported <- ProjectBundle$import_zip(archive, file.path(root, 'imported'))
  stopifnot(imported$resolve_figure(f, verify = 'sha256')$evidence$execution == 'unknown',
            imported$get_figure(f)$evidence$execution_evidence == 'not_captured')
  # Ordinary evidence queries must not hash or reload scientific/registry bytes.
  ns <- asNamespace('BioDataLedger')
  originals <- lapply(c('.hash', '.read_json'), function(name) get(name, ns)); names(originals) <- c('.hash', '.read_json')
  on.exit(for (name in names(originals)) assignInNamespace(name, originals[[name]], ns = 'BioDataLedger'), add = TRUE)
  for (name in names(originals)) assignInNamespace(name, function(...) stop('unexpected payload/registry read'), ns = 'BioDataLedger')
  stopifnot(q$get_analysis(a)$evidence$execution == 'unknown', q$get_figure(f)$evidence$execution == 'unknown',
            identical(q$status()$evidence, constant), identical(q$summary()$evidence, constant), !q$status()$unsaved)
}
check_execution_evidence()
