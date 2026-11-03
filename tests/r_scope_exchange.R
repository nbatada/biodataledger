args <- commandArgs(trailingOnly = TRUE)
library(BioDataLedger, lib.loc = args[[1]])
action <- args[[2]]; root <- args[[3]]
json <- function(x) cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = 'null', digits = 15, force = TRUE))
if (action == 'create') {
  p <- ProjectBundle$create('scope exchange', root)
  writeLines('small synthetic data', file.path(root, 'data.csv'))
  d <- p$register_data('data.csv', 'input', hash = TRUE)
  des <- p$set_design('condition', c('treated', 'control'), selected_levels = 'treated')
  scoped <- p$set_data_scope(d, list(condition_values = list('treated'), observation_unit = 'sample',
      evidence = list(basis = 'declared', source_refs = list())), 'confirmed', design_ref = des)
  p$set_current(scoped, 'comparison', 'confirmed'); p$save()
  json(list(ref = scoped, data = p$get_data(ref = scoped), verification = p$resolve_data(purpose = 'comparison', verify = 'sha256')$verification))
} else if (action == 'inspect') {
  p <- ProjectBundle$open(root)
  ref <- args[[4]]
  json(list(data = p$get_data(ref = ref), verification = p$resolve_data(ref = ref, verify = 'sha256')$verification,
            status = p$status(purpose = 'comparison')))
} else if (action == 'verify') {
  p <- ProjectBundle$open(root)
  json(p$resolve_data(ref = args[[4]], verify = 'sha256', require_membership = TRUE)$verification)
} else if (action == 'append') {
  p <- ProjectBundle$open(root)
  input <- p$resolve_data(ref = args[[4]], verify = 'sha256')
  writeLines('synthetic figure', file.path(root, 'figure.svg'))
  writeLines('# Native synthetic retention example', file.path(root, 'retained.R'))
  analysis <- p$register_analysis('Native retained example', list(input$ref), code = 'retained.R',
                                 method = 'synthetic fixture', params = list(statistic = 'fixture'))
  f <- p$register_figure('figure.svg', 'qc', analysis = analysis)
  p$save()
  json(list(figure = p$get_figure(f), input = p$get_data(ref = args[[4]])))
} else stop('Unknown exchange action')
