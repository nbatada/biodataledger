args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc = args[[1]])
action <- args[[2]]; root <- args[[3]]
emit <- function(x) cat(jsonlite::toJSON(x, auto_unbox = TRUE, null = 'null', digits = 15))
if (action == 'create') {
  p <- ProjectBundle$create('Synthetic R renderer guard', root)
  invisible(p$require_approved_figures('native renderers'))
} else if (action == 'append') {
  p <- ProjectBundle$open(root)
  stopifnot(p$figure_policy() == 'approved_renderers_v1')
  f <- p$resolve_figure(args[[4]], verify = 'sha256')
  stopifnot(f$details$renderer_receipt$backend == 'matplotlib')
  stopifnot(identical(f$details$renderer_receipt$export_settings$units, 'in'),
            f$details$renderer_receipt$export_settings$width == 2,
            f$details$renderer_receipt$export_settings$dpi == 72)
} else if (action == 'import') {
  p <- ProjectBundle$import_zip(args[[4]], root)
  stopifnot(p$figure_policy() == 'approved_renderers_v1')
  f <- p$resolve_figure(args[[5]], verify = 'sha256')
  stopifnot(f$details$renderer_receipt$verification == 'local_render_observed')
  emit(list(policy = p$figure_policy(), figure = f$ref))
  quit(status = 0)
} else stop('unknown action')
figure <- p$render_figure('pca', data = data.frame(PC1 = c(1, 2, 3), PC2 = c(3, 1, 2)),
                          plot_args = list(x = 'PC1', y = 'PC2'), width = 2, height = 2, dpi = 72)
composition <- p$render_figure('compose',
  panels = list(list(renderer = 'pca', data = data.frame(x = c(1, 2), y = c(2, 1)),
                     plot_args = list(x = 'x', y = 'y'))),
  plot_args = list(ncol = 1), width = 2, height = 2, dpi = 72)
refused <- try(p$register_figure(p$get_figure(figure)$path, 'plot'), silent = TRUE)
stopifnot(inherits(refused, 'try-error'), grepl('APPROVED_RENDERER_REQUIRED', as.character(refused)))
invisible(p$save())
emit(list(policy = p$figure_policy(), figure = figure, composition = composition))
