library(BioDataLedger)
stopifnot(!"ggplot2" %in% loadedNamespaces(), !"patchwork" %in% loadedNamespaces())
root <- tempfile("renderer-guard-"); dir.create(root)
writeLines("an existing image", file.path(root, "old.png"))
p <- ProjectBundle$create("guard", root)
stopifnot(is.function(p$require_approved_figures))
legacy <- p$register_figure(file.path(root, "old.png"), type = "legacy")
p$require_approved_figures("Use approved native renderers")
before <- p$status()
files <- list.files(root, recursive = TRUE, all.files = TRUE)
error <- tryCatch(p$register_figure(file.path(root, "old.png"), type = "bypass"), error = identity)
stopifnot(inherits(error, "error"), grepl("APPROVED_RENDERER_REQUIRED", conditionMessage(error)),
          identical(before, p$status()), identical(files, list.files(root, recursive = TRUE, all.files = TRUE)))
fail <- function(expr, text = NULL) {
  e <- tryCatch({force(expr); NULL}, error = identity)
  stopifnot(inherits(e, "error"))
  if (!is.null(text)) stopifnot(grepl(text, conditionMessage(e), fixed = TRUE))
}
unchanged <- function(expr, text = NULL) {
  state <- serialize(environment(p$render_figure)$state, NULL)
  pending <- serialize(environment(p$render_figure)$pending_code, NULL)
  before <- p$status()
  files <- list.files(root, recursive = TRUE, all.files = TRUE)
  fail(expr, text)
  stopifnot(identical(before, p$status()), identical(state, serialize(environment(p$render_figure)$state, NULL)),
            identical(pending, serialize(environment(p$render_figure)$pending_code, NULL)),
            identical(files, list.files(root, recursive = TRUE, all.files = TRUE)))
}
# Guard refusals occur before ordinary copying, correction or metadata installation.
unchanged(p$save_figure("old.png", type = "copy"), "APPROVED_RENDERER_REQUIRED")
unchanged(p$save_figure("old.png", ref = legacy), "APPROVED_RENDERER_REQUIRED")
unchanged(p$update_record(legacy, list(path = "old.png"), "change bytes"), "APPROVED_RENDERER_REQUIRED")
unchanged(p$update_record(legacy, list(method = "other"), "change context"), "APPROVED_RENDERER_REQUIRED")
unchanged(p$update_record(legacy, list(details = list(renderer_receipt = list())), "forge"), "library-managed")
unchanged(p$register_data("old.png", "input", renderer_receipt = list()), "library-managed")
unchanged(p$register_analysis("fake", NULL, renderer_receipt = list()), "library-managed")
p$save()
stopifnot(ProjectBundle$open(root)$figure_policy() == "approved_renderers_v1")
registry <- file.path(root, ".nb_project_bundle", "project.json")
stopifnot(jsonlite::fromJSON(registry)$schema_version == "0.4.0")
# Malformed and null persisted policies reject, rather than disabling the guard.
saved <- readBin(registry, "raw", n = file.info(registry)$size)
for (policy in list(NULL, "unrestricted", "unknown")) {
  state <- jsonlite::fromJSON(rawToChar(saved), simplifyVector = FALSE)
  state$project["figure_policy"] <- list(policy)
  writeLines(jsonlite::toJSON(state, auto_unbox = TRUE, null = "null"), registry)
  fail(ProjectBundle$open(root), "figure_policy")
}
writeBin(saved, registry)
p <- ProjectBundle$open(root)
# Existing pending code snapshots survive failures without becoming committed.
writeLines("function() NULL", file.path(root, "pending.R"))
a <- p$register_analysis("pending code", NULL, code = "pending.R")
d <- data.frame(sample = c("s1", "s2", "s3"), x = c(-2, 0, 3), y = c(1, -1, 2),
                group = c("a", "a", "b"), value = c(3, 4, 7))
original <- serialize(d, NULL)
args <- list(x = "x", y = "y", sample_id = "sample")
unchanged(p$render_figure(function() NULL, data = d, plot_args = args))
unchanged(p$render_figure("pca", data = d, plot_args = list(x = "x", y = "y", title = function() NULL)))
unchanged(p$render_figure("pca", data = d, plot_args = list(x = "x", y = "y", ax = list())))
unchanged(p$render_figure("pca", data = d, plot_args = list(x = "missing", y = "y")))
unchanged(p$render_figure("pca", data = d, plot_args = args, analysis = "ANA-999@1"))
unchanged(p$render_figure("pca", data = d, plot_args = args, width = 100, height = 100, dpi = 2400))
if (requireNamespace("ggplot2", quietly = TRUE) && requireNamespace("patchwork", quietly = TRUE)) {
  custom <- bdl_pl_pca(d, "x", "y")
  unchanged(p$render_figure("pca", data = custom, plot_args = args))
  unchanged(p$render_figure("pca", data = d, plot_args = list(x = "x", y = "y", title = custom)))
  refs <- lapply(c("png", "pdf", "svg"), function(format) p$render_figure("pca", data = d, plot_args = args, analysis = a, format = format, width = 3, height = 2, dpi = 72))
  for (ref in refs) {
    rec <- p$get_figure(ref); receipt <- rec$details$renderer_receipt
    stopifnot(file.exists(rec$path), receipt$renderer == "pca", receipt$backend == "ggplot2",
              receipt$output_sha256 == rec$sha256, receipt$scientific_acceptance == "not_assessed",
              receipt$verification == "local_render_observed", length(receipt$panels) == 0L,
              identical(receipt$export_settings, list(format = rec$details$format, width = 3, height = 2, units = "in", dpi = 72)),
              identical(receipt$implementation_sha256, getFromNamespace(".renderer_fingerprint", "BioDataLedger")()),
              identical(p$resolve_figure(ref, verify = "sha256")$path, rec$path))
  }
  # All seven fixed entry points and declarative composition use prepared values.
  specs <- list(
    list(renderer = "umap_split", data = d, plot_args = list(x = "x", y = "y", split_by = "group")),
    list(renderer = "violin_qc", data = d, plot_args = list(group = "group", value = "value", value_label = "CPM")),
    list(renderer = "group_comparison", data = d, plot_args = list(group = "group", value = "value", sample_id = "sample", observation_unit = "sample", value_label = "CPM")),
    list(renderer = "heatmap", data = matrix(1:4, 2, dimnames = list(c("g1", "g2"), c("s1", "s2"))), plot_args = list(value_label = "CPM")),
    list(renderer = "volcano", data = data.frame(fc = c(-1, 2), p = c(.2, .01)), plot_args = list(log2fc = "fc", padj = "p", contrast = "b/a", lfc_threshold = 1, padj_threshold = .05)),
    list(renderer = "ma", data = data.frame(a = c(1, 2), fc = c(-1, 2)), plot_args = list(abundance = "a", log2fc = "fc", contrast = "b/a", abundance_scale = "linear")))
  for (spec in specs) do.call(p$render_figure, c(spec, list(format = "pdf")))
  composition <- p$render_figure("compose", panels = list(list(renderer = "pca", data = d, plot_args = args), specs[[4L]]), plot_args = list(ncol = 2), format = "pdf")
  stopifnot(length(p$get_figure(composition)$details$renderer_receipt$panels) == 2L,
            identical(original, serialize(d, NULL)))
  unchanged(p$render_figure("compose", panels = list(specs[[1L]])), "single-axis")
  malformed <- environment(p$render_figure)$state
  at <- which(vapply(malformed$records, function(rec) rec$kind == "figure" && !is.null(rec$details$renderer_receipt), logical(1)))[1L]
  malformed$records[[at]]$details$renderer_receipt$rendered_at <- "2026-02-31T25:99:99Z"
  fail(getFromNamespace(".validate", "BioDataLedger")(malformed), "renderer_receipt")
  for (settings in list(NULL, list(format = "pdf", width = 3, height = 2, units = "cm", dpi = 72),
                        list(format = "png", width = 100, height = 100, units = "in", dpi = 2400),
                        list(format = "pdf", width = 3, height = 2, units = "in", dpi = 72))) {
    malformed <- environment(p$render_figure)$state
    malformed$records[[at]]$details$renderer_receipt["export_settings"] <- list(settings)
    fail(getFromNamespace(".validate", "BioDataLedger")(malformed), "export_settings")
  }
  first <- refs[[1L]]; receipt <- p$get_figure(first)$details$renderer_receipt
  unchanged(p$update_record(first, list(details = list()), "erase receipt"), "immutable")
  changed <- p$get_figure(first)$details; changed$renderer_receipt$output_sha256 <- paste(rep("0", 64), collapse = "")
  unchanged(p$update_record(first, list(details = changed), "forge receipt"), "immutable")
  named <- p$update_record(first, list(name = "Readable name", status = "active"), "presentation")
  presented <- p$set_presentation(named, primary_topic = "pca", description = "native", generated_on = "2026-11-13", reason = "presentation")
  stopifnot(identical(receipt, p$get_figure(presented)$details$renderer_receipt))
  # A forced name collision must not remove an existing managed output directory.
  namespace <- asNamespace("BioDataLedger")
  collision <- "00000000-0000-4000-8000-000000000000"
  collision_path <- file.path(root, ".nb_project_bundle", "outputs", paste0("render-", collision))
  dir.create(collision_path); writeLines("preserve", file.path(collision_path, "existing.txt"))
  with_collision <- function(expr) {
    old <- get(".uuid", namespace)
    unlockBinding(".uuid", namespace); assign(".uuid", function() collision, namespace); lockBinding(".uuid", namespace)
    on.exit({unlockBinding(".uuid", namespace); assign(".uuid", old, namespace); lockBinding(".uuid", namespace)}, add = TRUE)
    force(expr)
  }
  with_collision(suppressWarnings(unchanged(p$render_figure("pca", data = d, plot_args = args), "exclusively create")))
  # A post-device failure removes its files and leaves staged work intact.
  namespace <- asNamespace("BioDataLedger")
  trace(".renderer_write", where = namespace, exit = quote(stop("injected post-device failure")), print = FALSE)
  unchanged(p$render_figure("pca", data = d, plot_args = args, format = "pdf"), "injected post-device")
  untrace(".renderer_write", where = namespace)
  rec <- p$get_figure(refs[[2L]])
  writeLines("tampered", rec$path)
  fail(p$resolve_figure(refs[[2L]], verify = "sha256"))
  p$save()
  q <- ProjectBundle$open(root)
  stopifnot(q$figure_policy() == "approved_renderers_v1", isTRUE(all.equal(receipt, q$get_figure(first)$details$renderer_receipt, check.attributes = FALSE)))
}
# Untouched projects retain their old schema and ordinary registration/copy behavior.
legacy_root <- tempfile("renderer-legacy-"); dir.create(legacy_root)
u <- ProjectBundle$create("legacy", legacy_root)
stopifnot(u$figure_policy() == "unrestricted")
writeLines("old image", file.path(legacy_root, "old.png"))
f <- u$register_figure("old.png", "legacy")
u$save_figure("old.png", ref = f)
fail(u$register_figure("old.png", "fake", renderer_receipt = list()), "library-managed")
u$save()
stopifnot(ProjectBundle$open(legacy_root)$figure_policy() == "unrestricted")
cat("PASS: guarded renderer refusals, persistence, native outputs, receipts, rollback and legacy behavior\n")
# Strict external figure rebinding requires the recorded digest and byte size.
external <- tempfile(fileext = ".png"); writeLines("external retained bytes", external)
external_ref <- u$register_figure(external, "legacy")
u$require_approved_figures("govern future retained figures")
replacement <- tempfile(fileext = ".png"); file.copy(external, replacement)
u$rebind_external(external_ref, replacement, "same bytes")
stopifnot(u$get_figure(external_ref)$path == normalizePath(replacement))
writeLines("different bytes", replacement)
before <- u$status()
fail(u$rebind_external(external_ref, replacement, "different bytes"), "APPROVED_RENDERER_REQUIRED")
stopifnot(identical(before, u$status()))
cat("PASS: strict external figure rebind requires identical recorded bytes\n")
# Managed rendering must not follow pre-existing output or registry symlinks.
if (requireNamespace("ggplot2", quietly = TRUE)) for (ancestor in c("outputs", ".nb_project_bundle")) {
  safe_root <- tempfile("renderer-contained-"); dir.create(safe_root)
  safe <- ProjectBundle$create("contained", safe_root)
  safe$require_approved_figures("managed native files")
  outside <- tempfile("renderer-outside-"); dir.create(outside)
  registry_dir <- file.path(safe_root, ".nb_project_bundle")
  if (ancestor == "outputs") {
    stopifnot(file.symlink(outside, file.path(registry_dir, "outputs")))
  } else {
    stopifnot(file.rename(registry_dir, file.path(outside, "registry")))
    stopifnot(file.symlink(file.path(outside, "registry"), registry_dir))
  }
  before <- serialize(environment(safe$render_figure)$state, NULL)
  external_files <- list.files(outside, recursive = TRUE, all.files = TRUE)
  fail(safe$render_figure("pca", data = data.frame(x = 1:2, y = 2:1), plot_args = list(x = "x", y = "y"), format = "pdf"))
  stopifnot(identical(before, serialize(environment(safe$render_figure)$state, NULL)),
            identical(external_files, list.files(outside, recursive = TRUE, all.files = TRUE)))
}
cat("PASS: renderer output and registry ancestry reject symlinks without external writes\n")
