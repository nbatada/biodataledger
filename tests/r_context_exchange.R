args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc = args[[1]])
action <- args[[2]]; root <- args[[3]]
emit <- function(x) cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = 'null', digits = 15))
if (action == 'append') {
  p <- ProjectBundle$open(root)
  a <- p$get_analysis(args[[4]])
  rejected <- inherits(try(p$register_analysis('wrong default', list(args[[6]])), silent = TRUE), 'try-error')
  next_a <- p$register_analysis('R exact', a$inputs, design_ref = a$design_ref)
  f <- p$save_figure('figure.svg', ref = args[[5]])
  p$save()
  emit(list(context = p$check_context(next_a), rejected = rejected, analysis = next_a, figure = f))
} else if (action == 'create') {
  writeLines('x', file.path(root, 'data.csv')); writeLines('<svg>old</svg>', file.path(root, 'figure.svg'))
  p <- ProjectBundle$create('native R', root)
  d <- p$register_data('data.csv', 'input')
  des <- p$set_design('treatment', c('Vehicle', 'LowDose'))
  vehicle <- p$set_data_scope(d, list(condition_values = list('Vehicle')), 'vehicle', des)
  low <- p$set_data_scope(d, list(condition_values = list('LowDose')), 'low', des)
  a <- p$register_analysis('combined', list(vehicle, low), design_ref = des, input_mode = 'combined')
  f <- p$save_figure('figure.svg', 'plot', analysis = a)
  p$save(); emit(list(analysis = a, figure = f))
} else if (action == 'copy') {
  p <- ProjectBundle$open(root)
  f <- p$save_figure('figure.svg', ref = args[[4]]); p$save(); emit(list(figure = f))
} else if (action == 'import_copy') {
  p <- ProjectBundle$import_zip(args[[4]], root)
  old <- p$resolve_figure(args[[5]], verify = 'sha256')
  f <- p$save_figure(old$path, ref = old$ref); p$save(); emit(list(code = p$get_figure(f)$code))
} else if (action == 'archive') {
  p <- ProjectBundle$import_zip(args[[4]], root)
  f <- p$resolve_figure(args[[5]], verify = 'sha256')
  p$export_zip(p$preview_export('working', include = list(f$ref)), args[[6]])
  emit(list(preservation = f$preservation, verification = f$verification))
} else if (action == 'context') {
  p <- ProjectBundle$open(root); emit(list(context = p$check_context(args[[4]])))
} else if (action == 'inspect') {
  p <- ProjectBundle$open(root); f <- p$resolve_figure(args[[4]], verify = 'sha256')
  emit(list(verification = f$verification, context = p$check_context(args[[4]])))
} else stop('unknown action')
