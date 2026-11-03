library(BioDataLedger)
main <- function() {
  root <- tempfile('persistence-'); dir.create(root)
  on.exit(unlink(root, recursive=TRUE), add=TRUE)
  writeLines('synthetic', file.path(root, 'data.csv'))
  p <- ProjectBundle$create('Persistence receipt', root)
  stale <- ProjectBundle$open(root)
  path <- file.path(root, '.nb_project_bundle', 'project.json')
  bytes <- function() readBin(path, 'raw', n=file.info(path)$size)
  initial <- bytes()
  d <- p$register_data('data.csv', 'input')
  p$set_current(d, 'analysis', 'synthetic choice')
  options(BioDataLedger.inject_save_before_rename=TRUE)
  on.exit(options(BioDataLedger.inject_save_before_rename=NULL), add=TRUE)
  failure <- tryCatch(p$save_and_confirm(), error=identity)
  options(BioDataLedger.inject_save_before_rename=NULL)
  stopifnot(inherits(failure, 'error'), p$status()$unsaved, identical(initial, bytes()))
  receipt <- p$save_and_confirm()
  state <- jsonlite::fromJSON(path, simplifyVector=FALSE)
  stopifnot(receipt$status == 'persisted', receipt$scope == 'all_pending_changes',
            receipt$registry_written, receipt$committed_revision == state$state_revision,
            receipt$previous_committed_revision + 1L == receipt$committed_revision,
            receipt$transaction_id == state$last_transaction, !p$status()$unsaved)
  before <- bytes()
  namespace <- asNamespace('BioDataLedger')
  trace('.hash', where=namespace, tracer=quote(stop('clean save performed I/O')), print=FALSE)
  traced <- TRUE
  on.exit(if (traced) untrace('.hash', where=namespace), add=TRUE)
  clean <- p$save_and_confirm()
  stopifnot(clean$status == 'no_changes', !clean$registry_written,
            clean$committed_revision == clean$previous_committed_revision,
            identical(before, bytes()))
  untrace('.hash', where=namespace)
  traced <- FALSE
  stale$set_context(list(next_task='pending stale update'))
  failure <- tryCatch(stale$save_and_confirm(), error=identity)
  stopifnot(inherits(failure, 'error'), stale$status()$unsaved, identical(before, bytes()))
}
main()
