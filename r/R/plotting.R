# Optional table-first renderers; no plotting package is loaded at core import.
.bdl_pl_need <- function(package) {
  if (!requireNamespace(package, quietly = TRUE))
    stop("Install optional package '", package, "' to use this plotting function.", call. = FALSE)
}
.bdl_pl_text <- function(x, name) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(trimws(x)))
    stop(name, " must be one nonempty string.", call. = FALSE)
  x
}
.bdl_pl_table <- function(data, columns) {
  .bdl_pl_need("ggplot2")
  if (!is.data.frame(data) || !nrow(data) || anyDuplicated(names(data)))
    stop("data must be a nonempty data frame with unique column names.", call. = FALSE)
  for (column in columns) {
    .bdl_pl_text(column, "column")
    if (!column %in% names(data)) stop("Missing column: ", column, call. = FALSE)
    value <- data[[column]]
    if (!is.atomic(value) || !is.null(dim(value)) || anyNA(value) ||
        (is.numeric(value) && any(!is.finite(value))))
      stop("Column must contain nonmissing scalar values: ", column, call. = FALSE)
  }
  data
}
.bdl_pl_numeric <- function(x, name) {
  if (!is.numeric(x) || any(!is.finite(x)))
    stop(name, " must contain finite numeric values.", call. = FALSE)
  x
}
.bdl_pl_ids <- function(x, name) {
  if (!(is.character(x) || is.factor(x)) || any(!nzchar(trimws(as.character(x)))))
    stop(name, " must contain nonempty character identifiers.", call. = FALSE)
  as.character(x)
}
.bdl_pl_unique <- function(x, name) {
  if (anyDuplicated(x)) stop("Duplicate ", name, ".", call. = FALSE)
}
.bdl_pl_factor <- function(x, order = NULL, name = "group") {
  x <- as.character(x)
  if (any(!nzchar(trimws(x)))) stop(name, " contains empty labels.", call. = FALSE)
  if (is.null(order)) order <- unique(x)
  if (!is.character(order) || anyNA(order) || anyDuplicated(order) ||
      length(order) != length(unique(x)) || !setequal(order, x))
    stop(name, " order must name every observed level exactly once.", call. = FALSE)
  factor(x, levels = order)
}
.bdl_pl_limits <- function(limits, values, name) {
  if (is.null(limits)) return(range(values))
  if (!is.numeric(limits) || length(limits) != 2L || any(!is.finite(limits)) ||
      limits[1L] >= limits[2L] || min(values) < limits[1L] || max(values) > limits[2L])
    stop(name, " must be increasing finite bounds containing all values; clipping is refused.", call. = FALSE)
  limits
}
.bdl_pl_palette <- function(palette, levels) {
  if (is.null(palette)) return(NULL)
  if (!is.character(palette) || anyNA(palette)) stop("palette must contain colours.", call. = FALSE)
  if (is.null(names(palette))) {
    if (length(palette) != length(levels)) stop("palette needs one colour per level.", call. = FALSE)
    names(palette) <- levels
  } else if (anyDuplicated(names(palette)) || !setequal(names(palette), levels)) {
    stop("Named palette must cover every level exactly once.", call. = FALSE)
  }
  tryCatch(grDevices::col2rgb(palette), error = function(e) stop("Invalid palette colour.", call. = FALSE))
  palette
}
.bdl_pl_aes <- function(...) do.call(ggplot2::aes, lapply(list(...), as.name))
.bdl_pl_style <- function(plot, title = NULL) {
  if (!is.null(title)) .bdl_pl_text(title, "title")
  plot + ggplot2::theme_classic(base_size = 12) +
    ggplot2::theme(legend.position = "bottom", plot.title = ggplot2::element_text(face = "bold")) +
    ggplot2::labs(title = title)
}
# Shared scatter mapping keeps continuous normalization global across facets.
.bdl_pl_color <- function(plot, data, color_kind, palette, color_limits, label) {
  if (color_kind == "continuous") {
    .bdl_pl_numeric(data$color, label)
    limits <- .bdl_pl_limits(color_limits, data$color, "color_limits")
    if (is.null(palette)) palette <- c("#eeeeee", "#222222")
    if (!is.character(palette) || length(palette) < 2L || anyNA(palette))
      stop("Continuous palette needs at least two colours.", call. = FALSE)
    tryCatch(grDevices::col2rgb(palette), error = function(e) stop("Invalid palette colour.", call. = FALSE))
    plot <- plot + ggplot2::scale_colour_gradientn(colours = palette, limits = limits)
  } else {
    if (!is.null(color_limits)) stop("color_limits requires continuous colour.", call. = FALSE)
    pal <- .bdl_pl_palette(palette, levels(data$color))
    if (!is.null(pal)) plot <- plot + ggplot2::scale_colour_manual(values = pal, drop = FALSE)
  }
  plot + ggplot2::labs(colour = label)
}
.bdl_pl_scatter <- function(data, x, y, color, color_kind, sample_id, palette,
                            color_limits, xlabel, ylabel, title) {
  data <- .bdl_pl_table(data, c(x, y, sample_id, color))
  d <- data.frame(x = .bdl_pl_numeric(data[[x]], x), y = .bdl_pl_numeric(data[[y]], y))
  if (!is.null(sample_id)) {
    d$sample <- .bdl_pl_ids(data[[sample_id]], sample_id)
    .bdl_pl_unique(d$sample, "sample identifiers")
  }
  .bdl_pl_text(xlabel, "xlabel"); .bdl_pl_text(ylabel, "ylabel")
  if (is.null(color)) {
    if (!is.null(palette) || !is.null(color_limits)) stop("Colour options require a color column.", call. = FALSE)
    p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "x", y = "y")) + ggplot2::geom_point(size = 1.8)
  } else {
    d$color <- if (color_kind == "continuous") .bdl_pl_numeric(data[[color]], color) else .bdl_pl_factor(data[[color]], name = color)
    p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "x", y = "y", colour = "color")) + ggplot2::geom_point(size = 1.8)
    p <- .bdl_pl_color(p, d, color_kind, palette, color_limits, color)
  }
  .bdl_pl_style(p + ggplot2::labs(x = xlabel, y = ylabel), title)
}

#' Plot existing PCA coordinates
#' @export
bdl_pl_pca <- function(data, x, y, color = NULL, color_kind = c("categorical", "continuous"),
                       variance_percent = NULL, sample_id = NULL, label_samples = FALSE,
                       palette = NULL, color_limits = NULL, xlabel = x, ylabel = y, title = NULL) {
  color_kind <- match.arg(color_kind)
  if (!is.logical(label_samples) || length(label_samples) != 1L || is.na(label_samples))
    stop("label_samples must be TRUE or FALSE.", call. = FALSE)
  if (label_samples && is.null(sample_id)) stop("label_samples requires sample_id.", call. = FALSE)
  if (!is.null(variance_percent)) {
    if (!is.numeric(variance_percent) || length(variance_percent) != 2L ||
        any(!is.finite(variance_percent)) || any(variance_percent < 0 | variance_percent > 100) ||
        sum(variance_percent) > 100 + 1e-10)
      stop("variance_percent must be two percentages in [0,100] summing to at most 100.", call. = FALSE)
    xlabel <- paste0(xlabel, " (", format(variance_percent[1L], trim = TRUE), "% variance)")
    ylabel <- paste0(ylabel, " (", format(variance_percent[2L], trim = TRUE), "% variance)")
  }
  p <- .bdl_pl_scatter(data, x, y, color, color_kind, sample_id, palette, color_limits, xlabel, ylabel, title)
  if (label_samples) p <- p + ggplot2::geom_text(.bdl_pl_aes(label = "sample"), vjust = -0.6, show.legend = FALSE)
  p
}

#' Plot existing UMAP coordinates with shared split scales
#' @export
bdl_pl_umap_split <- function(data, x, y, split_by, color = NULL,
                              color_kind = c("categorical", "continuous"), split_order = NULL,
                              sample_id = NULL, palette = NULL, color_limits = NULL,
                              xlabel = x, ylabel = y, ncol = NULL, title = NULL) {
  color_kind <- match.arg(color_kind)
  .bdl_pl_table(data, split_by)
  if (!is.null(ncol) && (length(ncol) != 1L || !is.numeric(ncol) || !is.finite(ncol) || ncol < 1 || ncol != floor(ncol)))
    stop("ncol must be a positive integer.", call. = FALSE)
  p <- .bdl_pl_scatter(data, x, y, color, color_kind, sample_id, palette, color_limits, xlabel, ylabel, title)
  p$data$split <- .bdl_pl_factor(data[[split_by]], split_order, split_by)
  p + ggplot2::facet_wrap(ggplot2::vars(!!as.name("split")), ncol = ncol) + ggplot2::coord_fixed()
}

#' Plot prepared long-form QC distributions
#' @export
bdl_pl_violin_qc <- function(data, group, value, value_label, group_order = NULL,
                             palette = NULL, title = NULL) {
  data <- .bdl_pl_table(data, c(value, group)); .bdl_pl_text(value_label, "value_label")
  d <- data.frame(value = .bdl_pl_numeric(data[[value]], value),
                  group = .bdl_pl_factor(data[[group]], group_order, group))
  pal <- .bdl_pl_palette(palette, levels(d$group))
  p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "group", y = "value", fill = "group"))
  density_groups <- names(Filter(function(values) length(values) > 1L && length(unique(values)) > 1L,
                                 split(d$value, d$group)))
  if (length(density_groups)) p <- p + ggplot2::geom_violin(
    data = d[d$group %in% density_groups, , drop = FALSE], trim = TRUE, scale = "width")
  p <- p + ggplot2::geom_point(size = 1, alpha = 0.6) +
    ggplot2::labs(x = group, y = value_label, fill = group)
  if (!is.null(pal)) p <- p + ggplot2::scale_fill_manual(values = pal, drop = FALSE)
  .bdl_pl_style(p, title)
}

#' Plot individual sample observations without inferred statistics
#' @export
bdl_pl_group_comparison <- function(data, group, value, sample_id, observation_unit, value_label,
                                    group_order = NULL, palette = NULL, title = NULL) {
  data <- .bdl_pl_table(data, c(value, group, sample_id))
  .bdl_pl_text(observation_unit, "observation_unit"); .bdl_pl_text(value_label, "value_label")
  d <- data.frame(value = .bdl_pl_numeric(data[[value]], value),
                  group = .bdl_pl_factor(data[[group]], group_order, group),
                  sample = .bdl_pl_ids(data[[sample_id]], sample_id))
  .bdl_pl_unique(d$sample, "sample identifiers")
  pal <- .bdl_pl_palette(palette, levels(d$group))
  p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "group", y = "value", colour = "group")) +
    ggplot2::geom_point(size = 2) + ggplot2::labs(x = group, y = value_label, colour = group,
      caption = paste0("Observation unit: ", observation_unit, "; identifier: ", sample_id,
        ". Observations: ", paste(paste0(names(table(d$group)), " n=", as.integer(table(d$group))), collapse = "; ")))
  if (!is.null(pal)) p <- p + ggplot2::scale_colour_manual(values = pal, drop = FALSE)
  .bdl_pl_style(p, title)
}

#' Plot an already prepared matrix without transformation
#' @export
bdl_pl_heatmap <- function(matrix, value_label, row_order = NULL, column_order = NULL,
                           color_limits = NULL, row_label = "Feature", column_label = "Sample", title = NULL) {
  .bdl_pl_need("ggplot2"); .bdl_pl_text(value_label, "value_label")
  .bdl_pl_text(row_label, "row_label"); .bdl_pl_text(column_label, "column_label")
  if (!is.matrix(matrix) || !is.numeric(matrix) || !length(matrix) || any(!is.finite(matrix)))
    stop("matrix must be a nonempty finite numeric matrix.", call. = FALSE)
  rows <- rownames(matrix); columns <- colnames(matrix)
  if (is.null(rows) || is.null(columns)) stop("matrix needs explicit row and column names.", call. = FALSE)
  .bdl_pl_ids(rows, "row names"); .bdl_pl_ids(columns, "column names")
  .bdl_pl_unique(rows, "row names"); .bdl_pl_unique(columns, "column names")
  rows <- levels(.bdl_pl_factor(rows, row_order, "row"))
  columns <- levels(.bdl_pl_factor(columns, column_order, "column"))
  ordered <- matrix[rows, columns, drop = FALSE]
  d <- expand.grid(row = rows, column = columns, KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)
  d$row <- factor(d$row, levels = rev(rows)); d$column <- factor(d$column, levels = columns)
  d$value <- as.vector(ordered)
  p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "column", y = "row", fill = "value")) +
    ggplot2::geom_tile() + ggplot2::scale_fill_gradient(low = "#f7fbff", high = "#08306b",
      limits = .bdl_pl_limits(color_limits, d$value, "color_limits")) +
    ggplot2::labs(x = column_label, y = row_label, fill = value_label)
  .bdl_pl_style(p, title)
}

#' Plot existing differential-expression estimates and adjusted probabilities
#' @export
bdl_pl_volcano <- function(data, log2fc, padj, contrast, lfc_threshold,
                           padj_threshold, zero_p_floor = NULL, feature = NULL, title = NULL) {
  data <- .bdl_pl_table(data, c(log2fc, padj, feature)); .bdl_pl_text(contrast, "contrast")
  ids <- if (is.null(feature)) as.character(seq_len(nrow(data))) else .bdl_pl_ids(data[[feature]], feature)
  .bdl_pl_unique(ids, "feature identifiers")
  fc <- .bdl_pl_numeric(data[[log2fc]], log2fc); prob <- .bdl_pl_numeric(data[[padj]], padj)
  if (any(prob < 0 | prob > 1)) stop("Adjusted probabilities must be in [0,1].", call. = FALSE)
  if (!is.numeric(lfc_threshold) || length(lfc_threshold) != 1L || !is.finite(lfc_threshold) || lfc_threshold < 0)
    stop("lfc_threshold must be nonnegative and finite.", call. = FALSE)
  if (!is.numeric(padj_threshold) || length(padj_threshold) != 1L || !is.finite(padj_threshold) || padj_threshold <= 0 || padj_threshold > 1)
    stop("padj_threshold must be in (0,1].", call. = FALSE)
  if (!is.null(zero_p_floor) && (!is.numeric(zero_p_floor) || length(zero_p_floor) != 1L ||
      !is.finite(zero_p_floor) || zero_p_floor <= 0 || zero_p_floor > 1))
    stop("zero_p_floor must be in (0,1].", call. = FALSE)
  if (any(prob == 0) && is.null(zero_p_floor)) stop("Zero probabilities require an explicit zero_p_floor for display.", call. = FALSE)
  if (!is.null(zero_p_floor) && (zero_p_floor > padj_threshold || any(prob > 0 & prob < zero_p_floor)))
    stop("zero_p_floor must not exceed the threshold or any positive probability.", call. = FALSE)
  display <- prob
  if (any(prob == 0)) display[prob == 0] <- zero_p_floor
  status <- ifelse(prob <= padj_threshold & abs(fc) >= lfc_threshold & fc != 0,
                   ifelse(fc > 0, "higher", "lower"), "other")
  d <- data.frame(log2fc = fc, neglog10_padj = -log10(display), feature = ids, padj = prob,
                  status = factor(status, levels = c("other", "lower", "higher")))
  caption <- if (any(prob == 0)) paste0(sum(prob == 0), " zero probabilities displayed at ", format(zero_p_floor), "; original probabilities determine thresholds.") else NULL
  p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "log2fc", y = "neglog10_padj", colour = "status")) +
    ggplot2::geom_vline(xintercept = c(-lfc_threshold, lfc_threshold), linetype = 2, colour = "grey60") +
    ggplot2::geom_hline(yintercept = -log10(padj_threshold), linetype = 2, colour = "grey60") +
    ggplot2::geom_point(size = 1.6) + ggplot2::scale_colour_manual(values = c(other = "grey65", lower = "#386cb0", higher = "#d73027"),
      labels = c(other = "Other", lower = "Lower; meets supplied cutoffs", higher = "Higher; meets supplied cutoffs"), drop = FALSE) +
    ggplot2::labs(x = paste0("log2 fold change (", contrast, ")"), y = "-log10(adjusted p-value)",
                  colour = NULL, caption = caption, subtitle = contrast)
  .bdl_pl_style(p, title)
}

#' Plot existing abundance and log2 fold change
#' @export
bdl_pl_ma <- function(data, abundance, log2fc, contrast, abundance_scale,
                      feature = NULL, abundance_label = abundance, title = NULL) {
  data <- .bdl_pl_table(data, c(abundance, log2fc, feature)); .bdl_pl_text(contrast, "contrast")
  .bdl_pl_text(abundance_label, "abundance_label"); .bdl_pl_text(abundance_scale, "abundance_scale")
  if (!abundance_scale %in% c("linear", "log2", "log10"))
    stop("abundance_scale must be linear, log2 or log10 (describes supplied values; no transformation).", call. = FALSE)
  ids <- if (is.null(feature)) as.character(seq_len(nrow(data))) else .bdl_pl_ids(data[[feature]], feature)
  .bdl_pl_unique(ids, "feature identifiers")
  d <- data.frame(abundance = .bdl_pl_numeric(data[[abundance]], abundance),
                  log2fc = .bdl_pl_numeric(data[[log2fc]], log2fc), feature = ids)
  if (abundance_scale == "linear" && any(d$abundance < 0)) stop("Linear abundance must be nonnegative.", call. = FALSE)
  p <- ggplot2::ggplot(d, .bdl_pl_aes(x = "abundance", y = "log2fc")) +
    ggplot2::geom_hline(yintercept = 0, colour = "grey60", linetype = 2) + ggplot2::geom_point(size = 1.6) +
    ggplot2::labs(x = paste0(abundance_label, " (", abundance_scale, ")"),
                  y = paste0("log2 fold change (", contrast, ")"), subtitle = contrast)
  .bdl_pl_style(p, title)
}

#' Compose editable native plots
#' @export
bdl_pl_compose <- function(plots, ncol = NULL, widths = NULL, heights = NULL, labels = NULL) {
  .bdl_pl_need("patchwork")
  if (!is.list(plots) || !length(plots) || !all(vapply(plots, inherits, logical(1), "ggplot")))
    stop("plots must be a nonempty list of ggplot objects.", call. = FALSE)
  if (!is.null(ncol) && (!is.numeric(ncol) || length(ncol) != 1L || !is.finite(ncol) || ncol < 1 || ncol != as.integer(ncol)))
    stop("ncol must be a positive integer.", call. = FALSE)
  columns <- if (is.null(ncol)) ceiling(sqrt(length(plots))) else as.integer(ncol)
  rows <- ceiling(length(plots) / columns)
  for (entry in list(list(widths, columns, "widths"), list(heights, rows, "heights"))) {
    v <- entry[[1L]]
    if (!is.null(v) && (!is.numeric(v) || length(v) != entry[[2L]] || any(!is.finite(v)) || any(v <= 0)))
      stop(entry[[3L]], " must supply positive finite values for each layout column/row.", call. = FALSE)
  }
  if (!is.null(labels) && (!is.character(labels) || length(labels) != length(plots) || anyNA(labels)))
    stop("labels must supply one string per plot.", call. = FALSE)
  if (!is.null(labels)) plots <- Map(function(p, tag) p + ggplot2::labs(tag = tag), plots, labels)
  patchwork::wrap_plots(plots, ncol = columns, widths = widths, heights = heights)
}
