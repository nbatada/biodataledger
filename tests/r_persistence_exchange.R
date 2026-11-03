library(BioDataLedger)
args <- commandArgs(TRUE)
p <- ProjectBundle$open(args[1])
if (args[2] == 'write') {
  d <- p$register_data('data.csv', 'input')
  a <- p$register_analysis('Synthetic', list(d))
  p$register_figure('figure.svg', 'fixture', analysis=a)
  p$set_current(d, 'analysis', 'synthetic')
  p$set_design('treatment', c('Vehicle', 'Drug'))
  p$record_decision('Keep synthetic data', 'fixture', list(d))
  if (args[3] == 'saved') cat(jsonlite::toJSON(p$save_and_confirm(), auto_unbox=TRUE))
} else {
  expected <- args[3] == 'saved'
  stopifnot((length(p$find_figures()) > 0L) == expected,
            !is.null(p$get_design()) == expected, !p$status()$unsaved)
  if (expected) stopifnot(p$get_data(purpose='analysis')$ref$id == 'DATA-001',
                         p$get_analysis('ANA-001@1')$name == 'Synthetic')
}
