# Render lineage-demo:cells-by-sample from its saved count CSV.

render_counts <- function(count_path, output_path) {
  rows <- read.csv(count_path)
  fields <- c("cohort_a_cells", "cohort_b_cells")
  colors <- c("#17628D", "#A24520")
  labels <- c("A  Hashed · Vehicle and Low", "B  Hashed or unassigned · All treatments")
  left <- 174
  plot_width <- 507
  axis_y <- 143 + 63 * nrow(rows)
  max_count <- max(rows[fields])
  tick_step <- max(1, ceiling(max_count / 6))
  axis_max <- max(tick_step, ceiling(max_count / tick_step) * tick_step)
  svg <- c(
    sprintf(paste0('<svg xmlns="http://www.w3.org/2000/svg" width="760" height="%d" ',
                   'viewBox="0 0 760 %d" role="img" aria-labelledby="title description">'), axis_y + 81, axis_y + 81),
    '<title id="title">Cells included by sample</title>',
    '<desc id="description">Synthetic counts for two cohorts, grouped by sample and treatment.</desc>',
    '<rect width="100%" height="100%" fill="#FFFFFF"/>',
    '<g font-family="system-ui, sans-serif" fill="#172C3B">',
    '<text x="24" y="39" font-size="26" font-weight="700">Cells included by sample</text>',
    '<text x="24" y="65" font-size="15">Synthetic data · Descriptive counts</text>'
  )
  legend_x <- c(24, 320)
  for (j in seq_along(fields)) {
    svg <- c(svg, sprintf('<rect x="%d" y="91" width="14" height="14" rx="2" fill="%s"/>', legend_x[j], colors[j]),
             sprintf('<text x="%d" y="103" font-size="14">%s</text>', legend_x[j] + 22, labels[j]))
  }

  for (tick in seq(0, axis_max, by = tick_step)) {
    x <- left + tick / axis_max * plot_width
    svg <- c(svg,
             sprintf('<line x1="%.2f" y1="125" x2="%.2f" y2="%d" stroke="#D4DFE6"/>', x, x, axis_y),
             sprintf('<text x="%.2f" y="%d" text-anchor="middle" font-size="13">%d</text>', x, axis_y + 18, tick))
  }

  for (i in seq_len(nrow(rows))) {
    y <- 137 + 63 * (i - 1)
    sample <- paste(rows$sample_id[i], rows$treatment[i], sep = " · ")
    sample <- gsub("&", "&amp;", sample, fixed = TRUE)
    sample <- gsub("<", "&lt;", sample, fixed = TRUE)
    sample <- gsub(">", "&gt;", sample, fixed = TRUE)
    svg <- c(svg, sprintf('<text x="%d" y="%d" text-anchor="end" font-size="15">%s</text>', left - 14, y + 22, sample))
    for (j in seq_along(fields)) {
      bar_y <- y + 21 * (j - 1)
      count <- rows[[fields[j]]][i]
      width <- count / axis_max * plot_width
      svg <- c(svg,
               sprintf('<rect x="%d" y="%d" width="%.2f" height="15" rx="2" fill="%s"/>', left, bar_y, width, colors[j]),
               sprintf('<text x="%.2f" y="%d" font-size="13">%d</text>', left + width + 7, bar_y + 12, count))
    }
  }

  svg <- c(svg,
           sprintf('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#677D8A"/>', left, axis_y, left + plot_width, axis_y),
           sprintf('<text x="%.2f" y="%d" text-anchor="middle" font-size="15">Included cells</text>', left + plot_width / 2, axis_y + 39),
           sprintf('<text x="24" y="%d" font-size="13">Cohort A excludes the High sample by design.</text>', axis_y + 65),
           '</g></svg>')
  output <- file(output_path, open = "wx")
  on.exit(close(output))
  writeLines(enc2utf8(svg), output, useBytes = TRUE)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 2L) stop("Supply the retained count CSV and a new SVG path", call. = FALSE)
  render_counts(args[[1L]], args[[2L]])
}
