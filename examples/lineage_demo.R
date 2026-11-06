# Create or inspect the synthetic cohort-count example in docs/LINEAGE_DEMO.md.
library(BioDataLedger)

question <- "Which samples and cells are included in this comparison?"
figure_title <- "Cells included by sample"
current_purpose <- "cohort-a-review"

write_synthetic_cells <- function(path) {
  # Each row is one invented cell. No expression values or biological replicates.
  samples <- data.frame(sample_id = c("S01", "S02", "S03"),
                        treatment = c("Vehicle", "Low", "High"),
                        hashed = c(5L, 3L, 4L), unassigned = c(2L, 3L, 1L),
                        ambiguous = c(1L, 1L, 2L))
  rows <- lapply(seq_len(nrow(samples)), function(i) {
    sample <- samples[i, ]
    assignments <- rep(c("hashed", "unassigned", "ambiguous"),
                       times = c(sample$hashed, sample$unassigned, sample$ambiguous))
    data.frame(sample_id = sample$sample_id,
               cell_id = sprintf("%s-C%02d", sample$sample_id, seq_along(assignments)),
               treatment = sample$treatment, assignment = assignments)
  })
  write.csv(do.call(rbind, rows), path, row.names = FALSE)
}

retain_cohort <- function(project, script_path, raw_path, raw, cohort_path,
                          treatments, assignments, ref = NULL) {
  analysis <- project$register_analysis(
    paste("Select", tools::file_path_sans_ext(basename(cohort_path))),
    inputs = list(raw), code = script_path,
    method = "Select cell rows by treatment and assignment",
    params = list(treatments = as.list(treatments), assignments = as.list(assignments))
  )
  cells <- read.csv(raw_path)
  kept <- cells$treatment %in% treatments & cells$assignment %in% assignments
  write.csv(cells[kept, ], cohort_path, row.names = FALSE)
  project$register_result(cohort_path, analysis, ref = ref, hash = TRUE)
}

count_cells <- function(cohort_a_path, cohort_b_path, count_path) {
  cohort_a <- read.csv(cohort_a_path)
  cohort_b <- read.csv(cohort_b_path)
  samples <- unique(rbind(cohort_a[c("sample_id", "treatment")],
                          cohort_b[c("sample_id", "treatment")]))
  samples <- samples[order(samples$sample_id), ]
  samples$cohort_a_cells <- as.integer(table(factor(cohort_a$sample_id, levels = samples$sample_id)))
  samples$cohort_b_cells <- as.integer(table(factor(cohort_b$sample_id, levels = samples$sample_id)))
  write.csv(samples, count_path, row.names = FALSE)
}

create <- function(root, script_path) {
  if (!dir.create(root, showWarnings = FALSE)) stop("Choose a new directory with an existing parent")
  root <- normalizePath(root, mustWork = TRUE)
  project <- ProjectBundle$create("Synthetic sample inclusion QC", root)
  raw_path <- file.path(root, "synthetic-cells.csv")
  write_synthetic_cells(raw_path)
  raw <- project$register_data(raw_path, "raw", name = "Synthetic cell assignments", hash = TRUE)

  # Two separate analysis-ready cohorts from the same source rows.
  cohort_a_path <- file.path(root, "cohort-a-hashed.csv")
  cohort_a <- retain_cohort(project, script_path, raw_path, raw, cohort_a_path,
                            treatments = c("Vehicle", "Low"), assignments = "hashed")
  cohort_b_path <- file.path(root, "cohort-b-hashed-or-unassigned.csv")
  cohort_b <- retain_cohort(project, script_path, raw_path, raw, cohort_b_path,
                            treatments = c("Vehicle", "Low", "High"),
                            assignments = c("hashed", "unassigned"))

  # Count one row per included cell, grouped by sample and cohort.
  count_path <- file.path(root, "cells-by-sample.csv")
  counting <- project$register_analysis(
    "Count included cells by sample", inputs = list(cohort_a, cohort_b), code = script_path,
    method = "Count included cell rows per sample separately for each cohort"
  )
  count_cells(cohort_a_path, cohort_b_path, count_path)
  count_table <- project$register_result(count_path, counting, hash = TRUE)

  # The plotting script reads only the retained count table.
  plotting_script <- file.path(dirname(script_path), "lineage_demo_plot.R")
  source(plotting_script, local = TRUE, encoding = "UTF-8")
  plotting <- project$register_analysis(
    "Plot sample inclusion", inputs = list(count_table), code = plotting_script,
    method = "Draw paired horizontal bars from the retained count table"
  )
  plot_path <- file.path(root, "cells-by-sample.svg")
  render_counts(count_path, plot_path)
  figure <- project$register_figure(
    plot_path, "qc", analysis = plotting, name = figure_title,
    figure_sources = list(asset_id = "lineage-demo:cells-by-sample", rendering_inputs = list(count_table),
                          relationship = "declared", generating_code = list(record = plotting, index = 0L))
  )
  project$set_presentation(
    figure, primary_topic = "QC-samples", description = "cells-by-sample", generated_on = as.character(Sys.Date()),
    questions = question, title = figure_title, subtitle = "Synthetic example",
    uses = list(list(kind = "slide", document_id = "synthetic-qc-deck", item_id = "sample-inclusion",
                     title = "Sample inclusion")),
    reason = "Record the question and declared slide use"
  )

  # A later version of A keeps unassigned cells. The saved plot still uses A's earlier revision.
  updated_a <- retain_cohort(project, script_path, raw_path, raw, file.path(root, "cohort-a-updated.csv"),
                             treatments = c("Vehicle", "Low"), assignments = c("hashed", "unassigned"),
                             ref = cohort_a)
  project$set_current(updated_a, purpose = current_purpose, reason = "Use the updated cohort for the next review")
  project$save()
  cat("Saved synthetic project in ", root, "\n", sep = "")
}

exact_label <- function(ref) paste0(ref$id, "@", ref$revision)

inspect <- function(root) {
  project <- ProjectBundle$open(root)
  matches <- project$find_outputs(topic = "QC-samples", question = question, kind = "figure",
                                  document_id = "synthetic-qc-deck")
  if (matches$total != 1L) stop("Expected one retained figure for the demo question and slide deck")
  figure <- matches$items[[1L]]$ref
  info <- project$get_info(figure)
  count_table <- info$rendering_inputs$items[[1L]]$ref
  plotting_code <- info$plotting_code$generating_code$selector
  cohort_roots <- lapply(project$get_info(count_table)$inputs$items, `[[`, "ref")
  current_a <- project$get_data(purpose = current_purpose)$ref

  # These calls explicitly check file bytes. The metadata queries above do not.
  plot <- project$resolve_figure(figure, verify = "sha256")
  counts <- project$resolve_data(ref = count_table, verify = "sha256")
  code <- project$read_figure_source(figure, code_ref = plotting_code)
  labels <- c(
    paste("Project", figure$project_id),
    paste("Figure", exact_label(figure), plot$path),
    paste("Suggested filename", project$output_name(figure)$filename),
    paste("Rendering input", exact_label(count_table), counts$path),
    paste("Plotting code", exact_label(plotting_code$record), "index", plotting_code$index,
          file.path(root, code$snapshot)),
    paste("Plotting code SHA-256", code$sha256),
    paste("Counted cohorts", paste(vapply(cohort_roots, exact_label, character(1)), collapse = ", ")),
    paste("Current cohort A for review", exact_label(current_a))
  )
  writeLines(labels, stderr())

  project$export_graph(ref = figure, direction = "upstream", depth = 8L, style = "presentation",
                       lineage_roots = cohort_roots)
}

main <- function(args, script_path) {
  if (length(args) != 2L || !args[[1L]] %in% c("create", "inspect")) {
    stop("Usage: Rscript examples/lineage_demo.R create|inspect PROJECT_DIR", call. = FALSE)
  }
  root <- path.expand(args[[2L]])
  if (args[[1L]] == "create") {
    create(root, normalizePath(script_path, mustWork = TRUE))
  } else {
    cat(inspect(normalizePath(root, mustWork = TRUE)))
  }
}

if (sys.nframe() == 0L) {
  script_path <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE))
  main(commandArgs(trailingOnly = TRUE), script_path)
}
