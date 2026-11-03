library(BioDataLedger)
root <- tempfile("nb-r-"); dir.create(root)
writeLines("data", file.path(root, "data.txt"))
writeLines("plot(1)", file.path(root, "plot.R"))
writeLines("figure", file.path(root, "figure.png"))
b <- ProjectBundle$create("synthetic", root)
d <- b$register_data("data.txt", "qc", hash = TRUE)
a <- b$register_analysis("analysis", list(d), code = "plot.R", method = "example", params = list(n = 1))
f <- b$register_figure("figure.png", "qc", analysis = a)
b$set_current(d, "qc", "synthetic selection")
stopifnot(b$get_data(purpose = "qc")$ref$id == d$id)
stopifnot(b$get_figure(f)$method == "example")
b$save()
stopifnot(length(b$find_figures("figure")) == 1L)
other <- ProjectBundle$open(root)
other$set_context(list(next_task = "later")); other$save()
b$set_context(list(next_task = "stale"))
stopifnot(inherits(try(b$save(), silent = TRUE), "try-error"), b$summary()$unsaved)
clean <- ProjectBundle$open(root)
plan <- clean$preview_export("working", list(d, f))
zipfile <- tempfile(fileext = ".zip"); clean$export_zip(plan, zipfile)
relocated <- tempfile("nb-import-"); imported <- ProjectBundle$import_zip(zipfile, relocated)
stopifnot(imported$get_data(ref = d, check_files = TRUE)$available, imported$get_figure(f, check_files = TRUE)$available)
stopifnot(imported$get_figure(f, check_files = TRUE)$source_code_availability[[1]])
stopifnot(inherits(try(ProjectBundle$import_zip(zipfile, relocated), silent = TRUE), "try-error"))
context <- clean$preview_export("context")
context_zip <- tempfile(fileext = ".zip"); clean$export_zip(context, context_zip)
stopifnot(!ProjectBundle$import_zip(context_zip, tempfile("nb-context-"))$get_data(ref = d, check_files = TRUE)$available)

check_search_exact_inherited_context <- function() {
  root <- tempfile('search-context-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines('synthetic', file.path(root, 'input.txt'))
  writeLines('# declared source', file.path(root, 'plot.R'))
  writeLines('<svg/>', file.path(root, 'plot.svg'))
  p <- ProjectBundle$create('search fixture', root)
  d <- p$register_data('input.txt', 'input')
  design <- p$set_design('treatment', c('Vehicle', 'LowDose'))
  a <- p$register_analysis('Clonality', list(d), code = 'plot.R', method = 'synthetic',
                           params = list(n = 2), input_mode = 'combined', description = 'Rare clone expansion')
  f <- p$register_figure('plot.svg', 'summary', analysis = a, name = 'Visible panel', description = 'Frequency')
  hidden <- p$register_figure('plot.svg', 'summary', analysis = a, name = 'Hidden panel')
  details <- p$get_analysis(a)$details; details$description <- 'Replacement topic'
  newer <- p$update_record(a, list(name = 'Diversity', details = details), 'exact new analysis revision')
  recent <- p$register_figure('plot.svg', 'summary', analysis = newer, name = 'Modern panel')
  latest <- p$update_record(f, list(name = 'Corrected visible panel'), 'title only')
  p$update_record(hidden, list(status = 'inactive'), 'exclude inactive latest')
  superseded <- p$register_figure('plot.svg', 'summary', analysis = a, name = 'Superseded panel')
  p$update_record(superseded, list(status = 'superseded'), 'exclude superseded latest')
  standalone <- p$register_figure('plot.svg', 'control', name = 'Calibration', description = 'Control sample Straße')
  p$set_design('another condition', 'one'); p$save()
  refs <- function(rows) unname(lapply(rows, function(x) x$ref))
  stopifnot(identical(refs(p$find_figures('CLONALITY rare', type = 'summary')), list(latest)),
            identical(refs(p$find_figures('replacement')), list(recent)),
            identical(refs(p$find_figures('frequency')), list(latest)),
            identical(refs(p$find_figures('control calibration')), list(standalone)),
            identical(refs(p$find_figures()), list(latest, recent, standalone)),
            identical(refs(p$find_figures('   ')), list(latest, recent, standalone)),
            length(p$find_figures('hidden')) == 0L, length(p$find_figures('superseded')) == 0L,
            identical(refs(p$find_figures('STRASSE')), list(standalone)),
            length(p$find_figures('clonality', type = 'control')) == 0L)
  view <- p$find_figures('clonality')[[1]]
  stopifnot(identical(view$analysis, a), identical(view$design_ref, design),
            identical(view$inputs, list(d)), identical(view$input_mode, 'combined'),
            identical(view$method, 'synthetic'), identical(view$params, list(n = 2)),
            length(view$code) == 1L, is.null(view$available),
            identical(view$evidence, p$get_figure(latest)$evidence),
            identical(view$evidence$execution_evidence, 'not_captured'))
  ns <- asNamespace('BioDataLedger')
  originals <- lapply(c('.hash', '.read_json', '.json'), function(name) get(name, ns))
  names(originals) <- c('.hash', '.read_json', '.json')
  on.exit(for (name in names(originals)) assignInNamespace(name, originals[[name]], ns = 'BioDataLedger'), add = TRUE)
  for (name in names(originals)) assignInNamespace(name, function(...) stop('unexpected payload/registry I/O'), ns = 'BioDataLedger')
  stopifnot(identical(refs(p$find_figures('clonality')), list(latest)))
}
check_search_exact_inherited_context()
