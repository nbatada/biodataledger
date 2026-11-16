# Sourcing defines functions only. Real workflow: start once in the live R console;
# subsequent agent code attaches there. See docs/R_SESSION.md; no execution bridge.

plot_cached_values <- function(project_dir) {
  session <- BioDataLedger::bdl_session_attach(project_dir)
  source <- session$info("analysis")
  # Reuse current native values, including accepted replacements; no file reload.
  DF_plot <- session$get_data("analysis")[c("sample_id", "group", "value")]
  figure <- BioDataLedger::bdl_pl_group_comparison(
    DF_plot, group = "group", value = "value", sample_id = "sample_id",
    value_label = "Synthetic prepared value", observation_unit = "synthetic sample"
  )
  list(figure = figure, source = source)
}

synthetic_batch <- function() {
  # R removes its session tempdir on exit; use its parent so a failed batch's
  # owned synthetic directory remains available for inspection.
  project_dir <- tempfile("bdl-synthetic-session-", tmpdir = dirname(tempdir()))
  stopifnot(dir.create(project_dir, mode = "0700"))
  closed <- FALSE
  # Preserve failed synthetic ownership metadata for inspection; clean up only
  # after the explicit successful close below.
  on.exit(if (closed) unlink(project_dir, recursive = TRUE) else
    message("Synthetic batch failed; retained directory: ", project_dir), add = TRUE)
  project <- BioDataLedger::ProjectBundle$create("Synthetic session demonstration", project_dir)
  DF_values <- data.frame(sample_id = paste0("S", 1:4), group = c("A", "A", "B", "B"), value = c(1, 2, 3, 4))
  saveRDS(DF_values, file.path(project_dir, "prepared.rds"))
  ref <- project$register_data("prepared.rds", "analysis_ready", hash = TRUE)
  project$save()

  # Standalone example deliberately owns a disposable process/project, not Positron.
  # A live owner in another process makes bdl_session_start() refuse; this example
  # never recovers, reloads, or replaces that owner.
  session <- BioDataLedger::bdl_session_start(project_dir)
  loaded <- session$load_once("analysis", ref, readRDS)
  stopifnot(!loaded$reused)
  plotted <- plot_cached_values(project_dir)
  # Deliberate metadata-only refresh, keeping the returned previous native handle.
  previous_project <- session$refresh_project(reason = "Synthetic metadata reread")
  stopifnot(!previous_project$summary()$unsaved)
  stopifnot(session$load_once("analysis", ref, readRDS)$reused)
  # This synthetic batch creates no retained scientific output. In real work,
  # checkpoint a retained native output explicitly before this approved registry save.
  session$project()$save()
  session$close()
  closed <- TRUE
  invisible(plotted)
}

main <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (!identical(args, "--synthetic-batch"))
    stop("Run `Rscript examples/session_R.R --synthetic-batch`; sourcing defines functions only.", call. = FALSE)
  synthetic_batch()
}

if (sys.nframe() == 0L) main()
