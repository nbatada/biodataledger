.renderer_policy <- "approved_renderers_v1"
.renderer_names <- c("pca", "umap_split", "violin_qc", "group_comparison", "heatmap", "volcano", "ma")
.renderer_required <- function() .fail("APPROVED_RENDERER_REQUIRED: use render_figure(renderer=..., data=..., plot_args=...) with a native BioDataLedger renderer")
.renderer_reserved <- function(details) {
  if ("renderer_receipt" %in% names(details)) .fail("renderer_receipt is library-managed; use render_figure")
}
.renderer_plain <- function(x) {
  if (is.null(x)) return(TRUE)
  if (is.object(x) || !is.null(attributes(x)) && !identical(names(attributes(x)), "names")) return(FALSE)
  if (is.list(x)) return(all(vapply(x, .renderer_plain, logical(1))))
  typeof(x) %in% c("logical", "integer", "double", "character") && !anyNA(x) && (!is.numeric(x) || all(is.finite(x)))
}
.renderer_args <- function(args, renderer) {
  if (is.null(args) || is.list(args) && !length(args)) args <- .obj()
  if (!.is_obj(args) || anyDuplicated(names(args)) || any(!nzchar(names(args))) || !.renderer_plain(args)) .fail("plot_args must be a plain named list of JSON-compatible settings; callbacks and plot objects are forbidden")
  fun <- get(paste0("bdl_pl_", renderer), envir = environment(.renderer_args), inherits = FALSE)
  allowed <- setdiff(names(formals(fun)), c("data", "matrix", "plots", "ax"))
  if (!all(names(args) %in% allowed)) .fail("Unsupported plot_args; data, plots, axes and callbacks are forbidden")
  args
}
.renderer_panel <- function(renderer, data, args) {
  if (!.design_text(renderer) || !renderer %in% .renderer_names) .fail("Choose an approved native renderer")
  args <- .renderer_args(args, renderer)
  if (renderer == "heatmap") {
    if (!is.matrix(data) || !is.numeric(data) || is.object(data)) .fail("heatmap data must be a plain numeric matrix")
  } else if (!identical(class(data), "data.frame") || !all(vapply(data, function(x) is.atomic(x) && !is.object(x) || is.factor(x), logical(1)))) .fail("data must be a plain data.frame; plot objects and custom classes are forbidden")
  input <- if (renderer == "heatmap") list(matrix = data) else list(data = data)
  fun <- get(paste0("bdl_pl_", renderer), envir = environment(.renderer_panel), inherits = FALSE)
  list(plot = do.call(fun, c(input, args)), descriptor = .obj(renderer = renderer, plot_args = args))
}
.renderer_fingerprint <- function() {
  ns <- environment(.renderer_fingerprint)
  names <- sort(ls(ns, all.names = TRUE, pattern = "^(\\.bdl_pl_|bdl_pl_)"))
  definitions <- vapply(names, function(name) {
    fun <- get(name, envir = ns, inherits = FALSE)
    paste(name, paste(deparse(formals(fun), width.cutoff = 500L), collapse = "\n"), paste(deparse(body(fun), width.cutoff = 500L), collapse = "\n"), sep = "\n")
  }, character(1))
  .hash_raw(charToRaw(enc2utf8(paste(definitions, collapse = "\n"))))
}
.renderer_utc <- function(x) {
  if (!.design_text(x) || !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", x)) return(FALSE)
  observed <- tryCatch(as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), error = function(e) NA)
  !is.na(observed) && identical(format(observed, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), x)
}
.renderer_export <- function(format, width, height, dpi) {
  for (item in list(list(width, 100), list(height, 100), list(dpi, 2400)))
    if (!is.numeric(item[[1L]]) || length(item[[1L]]) != 1L || !is.finite(item[[1L]]) || item[[1L]] <= 0 || item[[1L]] > item[[2L]]) .fail("width/height must be positive finite inches <=100 and dpi must be positive finite <=2400")
  if (width * height * dpi * dpi > 100000000) .fail("Render dimensions exceed 100 million pixels")
  if (!.design_text(format) || !format %in% c("png", "pdf", "svg")) .fail("format must be png, pdf or svg")
  .obj(format = format, width = width, height = height, units = "in", dpi = dpi)
}
.renderer_parent <- function(root) {
  for (relative in c(".nb_project_bundle", ".nb_project_bundle/outputs")) {
    # Managed paths cannot use external bindings or follow directory symlinks.
    path <- .resolve(root, .obj(bindings = .obj(), imported = FALSE), .obj(kind = "project", value = relative))
    link <- Sys.readlink(path)
    if (!is.na(link) && nzchar(link)) .fail("Managed render directories must not be symbolic links")
    if (file.exists(path) && !dir.exists(path)) .fail("Managed render parent is not a directory")
  }
  path
}
.renderer_validate <- function(rec) {
  if (!"renderer_receipt" %in% names(rec$details)) return(invisible(NULL))
  x <- rec$details$renderer_receipt
  fields <- c("version", "renderer", "backend", "package_version", "rendered_at", "output_sha256", "implementation_sha256", "plot_args", "panels", "export_settings", "verification", "scientific_acceptance")
  if (rec$kind != "figure" || !.is_obj(x) || !setequal(names(x), fields) ||
      !identical(x$version, "biodataledger-renderer/1") || !.design_text(x$renderer) || !x$renderer %in% c(.renderer_names, "compose") ||
      !.design_text(x$backend) || !x$backend %in% c("matplotlib", "ggplot2") || !.design_text(x$package_version) ||
      !.renderer_utc(x$rendered_at) ||
      !.is_sha(x$output_sha256) || !identical(x$output_sha256, tolower(x$output_sha256)) || !identical(x$output_sha256, rec$sha256) || is.null(rec$size) ||
      !.is_sha(x$implementation_sha256) || !identical(x$implementation_sha256, tolower(x$implementation_sha256)) || !.is_obj(x$plot_args) || !.renderer_plain(x$plot_args) || !.is_arr(x$panels) ||
      !identical(x$verification, "local_render_observed") || !identical(x$scientific_acceptance, "not_assessed")) .fail("Invalid renderer_receipt")
  settings <- x$export_settings
  if (!.is_obj(settings) || !setequal(names(settings), c("format", "width", "height", "units", "dpi")) ||
      !identical(settings$units, "in") || !identical(settings$format, rec$details$format) ||
      !tryCatch({.renderer_export(settings$format, settings$width, settings$height, settings$dpi); TRUE}, error = function(e) FALSE)) .fail("Invalid renderer_receipt export_settings")
  if (x$renderer == "compose") {
    if (!length(x$panels)) .fail("Invalid renderer_receipt panels")
    for (panel in x$panels) if (!.is_obj(panel) || !setequal(names(panel), c("renderer", "plot_args")) ||
        !.design_text(panel$renderer) || !panel$renderer %in% setdiff(.renderer_names, "umap_split") ||
        !.is_obj(panel$plot_args) || !.renderer_plain(panel$plot_args)) .fail("Invalid renderer_receipt panels")
  } else if (length(x$panels)) .fail("Invalid renderer_receipt panels")
  invisible(NULL)
}
.renderer_write <- function(renderer, data, plot_args, panels, path, format, width, height, dpi) {
  if (!.design_text(renderer) || !renderer %in% c(.renderer_names, "compose")) .fail("Choose an approved native renderer")
  export_settings <- .renderer_export(format, width, height, dpi)
  args <- .renderer_args(plot_args, renderer)
  descriptors <- list()
  if (renderer == "compose") {
    if (!is.null(data) || !.is_arr(panels) || !length(panels)) .fail("compose requires a nonempty panel list and no data argument")
    built <- lapply(panels, function(panel) {
      if (!.is_obj(panel) || !all(c("renderer", "data") %in% names(panel)) || !all(names(panel) %in% c("renderer", "data", "plot_args")) || anyDuplicated(names(panel)) || !.design_text(panel$renderer) || !panel$renderer %in% setdiff(.renderer_names, "umap_split")) .fail("Each panel must declare an approved single-axis renderer, data and optional plot_args")
      .renderer_panel(panel$renderer, panel$data, panel$plot_args)
    })
    descriptors <- .arr(lapply(built, `[[`, "descriptor"))
    plot <- do.call(bdl_pl_compose, c(list(plots = lapply(built, `[[`, "plot")), args))
  } else {
    if (!is.null(panels)) .fail("panels is only supported for compose")
    plot <- .renderer_panel(renderer, data, args)$plot
  }
  # Native devices avoid new graphics dependencies; no external device callback is accepted.
  switch(format, png = grDevices::png(path, width = width, height = height, units = "in", res = dpi),
         pdf = grDevices::pdf(path, width = width, height = height),
         svg = grDevices::svg(path, width = width, height = height))
  device <- grDevices::dev.cur()
  on.exit(if (device %in% grDevices::dev.list()) grDevices::dev.off(device), add = TRUE)
  print(plot)
  grDevices::dev.off(device)
  .obj(version = "biodataledger-renderer/1", renderer = renderer, backend = "ggplot2",
       package_version = as.character(utils::packageVersion("BioDataLedger")), rendered_at = .now(),
       output_sha256 = .hash(path), implementation_sha256 = .renderer_fingerprint(),
       plot_args = args, panels = descriptors, export_settings = export_settings, verification = "local_render_observed", scientific_acceptance = "not_assessed")
}
