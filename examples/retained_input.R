# Small helpers for a new retained-input workflow. Sourcing only defines functions.

load_retained_input <- function(project, loader, ref = NULL, purpose = NULL, verify = "sha256") {
  if (!xor(is.null(ref), is.null(purpose))) stop("choose exactly one of ref or purpose")
  if (!is.function(loader)) stop("loader must be a function")
  source <- project$resolve_data(ref = ref, purpose = purpose, verify = verify)
  list(object = loader(source$path), source = source)
}

load_selected_redraw_input <- function(project, jobs, requested_job, loader, verify = "sha256") {
  if (is.null(jobs[[requested_job]])) stop("requested job is not declared")
  selector <- jobs[[requested_job]]
  if (!is.list(selector)) stop("job selector must be a list")
  do.call(load_retained_input, c(list(project = project, loader = loader, verify = verify), selector))
}

register_redraw <- function(project, source, name, figure_path, figure_type, code, method, params) {
  analysis <- project$register_analysis(name, inputs = list(source$ref), code = code,
                                        method = method, params = params)
  figure <- project$register_figure(
    figure_path, type = figure_type, analysis = analysis,
    figure_sources = list(rendering_inputs = list(source$ref), relationship = "declared"))
  list(analysis = analysis, figure = figure, source = source)
}
