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

main <- function() {
  project_dir <- tempfile("bdl-synthetic-session-")
  dir.create(project_dir)
  on.exit(unlink(project_dir, recursive = TRUE), add = TRUE)
  project <- BioDataLedger::ProjectBundle$create("Synthetic session demonstration", project_dir)
  DF_values <- data.frame(sample_id = paste0("S", 1:4), group = c("A", "A", "B", "B"), value = c(1, 2, 3, 4))
  saveRDS(DF_values, file.path(project_dir, "prepared.rds"))
  ref <- project$register_data("prepared.rds", "analysis_ready", hash = TRUE)
  project$save()

  # Standalone example deliberately owns a disposable process/project, not Positron.
  session <- BioDataLedger::bdl_session_start(project_dir)
  on.exit(session$close(), add = TRUE, after = FALSE)
  loaded <- session$load_once("analysis", ref, readRDS)
  stopifnot(!loaded$reused)
  plotted <- plot_cached_values(project_dir)
  # Deliberate metadata-only refresh, keeping the returned previous native handle.
  previous_project <- session$refresh_project(reason = "Synthetic metadata reread")
  stopifnot(!previous_project$summary()$unsaved)
  stopifnot(session$load_once("analysis", ref, readRDS)$reused)
  invisible(plotted)
}

if (sys.nframe() == 0L) main()
