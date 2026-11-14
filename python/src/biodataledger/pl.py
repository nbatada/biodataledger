"""Optional, table-first native Matplotlib plots; no analysis or saving side effects.

Install ``biodataledger[plotting]`` to use this module. All numerical values must
already be prepared by the caller. See docs/PLOTTING_PYTHON.md for contracts.
"""
from collections.abc import Mapping
import math

try:
    import numpy as np
    import pandas as pd
    import matplotlib.pyplot as plt
    from matplotlib.colors import Normalize, to_rgba
    from matplotlib.lines import Line2D
except ImportError as exc:
    raise ImportError("Plotting requires biodataledger[plotting] (matplotlib, numpy, pandas).") from exc

__all__ = ["pca", "umap_split", "violin_qc", "group_comparison", "heatmap", "volcano", "ma", "compose"]


def _text(value, name):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{name} must be a nonempty string")
    return value


def _table(table, columns):
    frame = pd.DataFrame(table).copy()
    if frame.empty or not frame.columns.is_unique:
        raise ValueError("table must be nonempty with unique column names")
    for column in columns:
        _text(column, "column name")
        if column not in frame or frame[column].isna().any():
            raise ValueError(f"missing column or values: {column}")
    return frame


def _numbers(values, name):
    if not pd.api.types.is_numeric_dtype(values) or pd.api.types.is_bool_dtype(values) or np.iscomplexobj(values):
        raise ValueError(f"{name} must contain numeric values")
    result = np.asarray(values, dtype=float)
    if not np.isfinite(result).all():
        raise ValueError(f"{name} must contain finite values")
    return result


def _levels(values, order=None):
    levels = list(pd.unique(values))
    if order is None:
        return levels
    order = list(order)
    if len(order) != len(levels) or len(set(order)) != len(order) or set(order) != set(levels):
        raise ValueError("order must list every observed category exactly once")
    return order


def _palette(levels, palette):
    if palette is None:
        colors = plt.rcParams["axes.prop_cycle"].by_key()["color"]
        return {level: colors[i % len(colors)] for i, level in enumerate(levels)}
    if not isinstance(palette, Mapping) or set(palette) != set(levels):
        raise ValueError("palette must map every observed category exactly once")
    for color in palette.values():
        to_rgba(color)
    return palette


def _axes(ax):
    return plt.subplots()[1] if ax is None else ax


def _normalization(values, vmin, vmax):
    lower = float(np.min(values)) if vmin is None else float(vmin)
    upper = float(np.max(values)) if vmax is None else float(vmax)
    if not math.isfinite(lower) or not math.isfinite(upper) or lower > upper:
        raise ValueError("color bounds must be finite and ordered")
    if np.min(values) < lower or np.max(values) > upper:
        raise ValueError("color bounds would clip supplied values")
    return Normalize(lower, upper)


def _color(frame, color, color_kind, palette, vmin, vmax):
    if color is None:
        if palette is not None or vmin is not None or vmax is not None:
            raise ValueError("palette/bounds require a color column")
        return None
    if color_kind == "continuous":
        if palette is not None:
            raise ValueError("continuous color uses cmap, not a category palette")
        return _normalization(_numbers(frame[color], color), vmin, vmax)
    if color_kind != "categorical":
        raise ValueError("color_kind must be categorical or continuous")
    if vmin is not None or vmax is not None:
        raise ValueError("bounds require continuous color")
    return _palette(_levels(frame[color]), palette)


def _scatter(ax, frame, x, y, color, colors, cmap, size):
    if not np.isscalar(size) or not math.isfinite(size) or size <= 0:
        raise ValueError("size must be a finite positive marker area")
    if color is None:
        ax.scatter(frame[x], frame[y], s=size)
    elif isinstance(colors, Normalize):
        artist = ax.scatter(frame[x], frame[y], c=frame[color], norm=colors, cmap=cmap, s=size)
        return artist
    else:
        for level, value in colors.items():
            selected = frame[frame[color] == level]
            ax.scatter(selected[x], selected[y], color=value, label=str(level), s=size)
        ax.legend(title=color)
    return None


def pca(table, *, x, y, sample_id=None, label_samples=False, color=None, color_kind="categorical", variance_percent=None,
        palette=None, cmap="viridis", vmin=None, vmax=None, size=20, ax=None):
    """Plot supplied PCA coordinates. Optional variance is two percentages, not fitted."""
    frame = _table(table, [x, y] + ([color] if color is not None else []))
    _numbers(frame[x], x)
    _numbers(frame[y], y)
    if sample_id is not None:
        _text(sample_id, "sample_id")
        if sample_id not in frame or frame[sample_id].isna().any() or frame[sample_id].duplicated().any():
            raise ValueError("sample_id must identify unique nonmissing observations")
    if not isinstance(label_samples, bool) or (label_samples and sample_id is None):
        raise ValueError("label_samples requires sample_id and must be boolean")
    colors = _color(frame, color, color_kind, palette, vmin, vmax)
    labels = [x, y]
    if variance_percent is not None:
        variance = np.asarray(variance_percent, dtype=float)
        if variance.shape != (2,) or not np.isfinite(variance).all() or (variance < 0).any() or variance.sum() > 100:
            raise ValueError("variance_percent must be two nonnegative percentages totaling at most 100")
        labels = [f"{name} ({value:g}% variance)" for name, value in zip(labels, variance)]
    ax = _axes(ax)
    artist = _scatter(ax, frame, x, y, color, colors, cmap, size)
    if artist is not None:
        ax.figure.colorbar(artist, ax=ax, label=color)
    if label_samples:
        for xv, yv, label in zip(frame[x], frame[y], frame[sample_id]):
            ax.annotate(str(label), (xv, yv))
    ax.set(xlabel=labels[0], ylabel=labels[1])
    return ax


def _grid(count, ncols, figsize, width_ratios=None, height_ratios=None):
    if not isinstance(ncols, int) or isinstance(ncols, bool) or ncols < 1:
        raise ValueError("ncols must be a positive integer")
    ncols = min(count, ncols)
    nrows = math.ceil(count / ncols)
    for ratios, expected in ((width_ratios, ncols), (height_ratios, nrows)):
        if ratios is not None:
            array = np.asarray(ratios, dtype=float)
            if array.shape != (expected,) or not np.isfinite(array).all() or (array <= 0).any():
                raise ValueError("ratios must be finite positive values matching grid columns/rows")
    fig, axes = plt.subplots(nrows, ncols, squeeze=False,
                             figsize=figsize or (4 * ncols, 3.5 * nrows),
                             gridspec_kw={"width_ratios": width_ratios, "height_ratios": height_ratios})
    for ax in axes.flat[count:]:
        fig.delaxes(ax)
    return fig, list(axes.flat[:count])


def umap_split(table, *, x, y, split_by, split_order=None, color=None,
               color_kind="categorical", palette=None, cmap="viridis", vmin=None,
               vmax=None, size=20, ncols=3, figsize=None):
    """Split supplied coordinates; all panels share coordinate limits and color scales."""
    frame = _table(table, [x, y, split_by] + ([color] if color is not None else []))
    xs, ys = _numbers(frame[x], x), _numbers(frame[y], y)
    levels = _levels(frame[split_by], split_order)
    colors = _color(frame, color, color_kind, palette, vmin, vmax)
    fig, axes = _grid(len(levels), ncols, figsize)
    def limits(values):
        low, high = float(values.min()), float(values.max())
        padding = (high - low) * .05 if high != low else max(abs(low) * .05, .5)
        return low - padding, high + padding
    for level, ax in zip(levels, axes):
        artist = _scatter(ax, frame[frame[split_by] == level], x, y, color, colors, cmap, size)
        ax.set(xlabel=x, ylabel=y, title=str(level), xlim=limits(xs), ylim=limits(ys), aspect="equal")
    if color is not None and isinstance(colors, Normalize):
        fig.colorbar(artist, ax=axes, label=color)
    return fig


def violin_qc(table, *, group, value, value_label, group_order=None, palette=None, ax=None):
    """Draw one prepared QC metric. KDE is confined to observed min/max; points stay exact."""
    frame = _table(table, [group, value])
    _text(value_label, "value_label")
    values = _numbers(frame[value], value)
    levels = _levels(frame[group], group_order)
    colors = _palette(levels, palette)
    ax = _axes(ax)
    for position, level in enumerate(levels):
        selected = values[np.asarray(frame[group] == level)]
        # Constant/singleton groups have no estimable density; keep their exact points.
        if len(selected) > 1 and np.ptp(selected) > 0:
            violin = ax.violinplot([selected], positions=[position], showextrema=True)
            for body in violin["bodies"]:
                body.set_facecolor(colors[level])
        ax.scatter(np.full(len(selected), position), selected, color=colors[level], s=12)
    ax.set(xticks=range(len(levels)), xticklabels=[str(x) for x in levels], xlabel=group, ylabel=value_label)
    return ax


def group_comparison(table, *, group, value, sample_id, observation_unit, value_label,
                     group_order=None, palette=None, ax=None):
    """One exact point per unique observation ID; no aggregation or statistical tests."""
    frame = _table(table, [group, value, sample_id])
    _text(observation_unit, "observation_unit")
    _text(value_label, "value_label")
    values = _numbers(frame[value], value)
    if frame[sample_id].duplicated().any():
        raise ValueError("sample_id must identify unique observations; prepare repeated measures explicitly")
    levels = _levels(frame[group], group_order)
    colors = _palette(levels, palette)
    ax = _axes(ax)
    for position, level in enumerate(levels):
        selected = values[np.asarray(frame[group] == level)]
        ax.scatter(np.full(len(selected), position), selected, color=colors[level], label=str(level))
    ax.set(xticks=range(len(levels)), xticklabels=[str(x) for x in levels],
           xlabel=group, ylabel=value_label, title=f"Observation unit: {observation_unit}")
    return ax


def heatmap(matrix, *, value_label, row_labels=None, column_labels=None,
            cmap="viridis", vmin=None, vmax=None, ax=None):
    """Display matrix values unchanged in supplied row/column order, without clustering."""
    _text(value_label, "value_label")
    if isinstance(matrix, pd.DataFrame):
        if row_labels is None:
            row_labels = list(matrix.index)
        if column_labels is None:
            column_labels = list(matrix.columns)
    values = np.asarray(matrix)
    if values.ndim != 2 or 0 in values.shape or not np.issubdtype(values.dtype, np.number) or np.iscomplexobj(values):
        raise ValueError("matrix must be a nonempty real numeric 2D matrix")
    values = values.astype(float)
    if not np.isfinite(values).all():
        raise ValueError("matrix must contain finite values")
    if row_labels is None or column_labels is None:
        raise ValueError("row_labels and column_labels are required for an unlabeled matrix")
    row_labels, column_labels = list(row_labels), list(column_labels)
    if len(row_labels) != values.shape[0] or len(column_labels) != values.shape[1]:
        raise ValueError("label lengths must match matrix dimensions")
    if pd.isna(row_labels).any() or pd.isna(column_labels).any():
        raise ValueError("matrix labels must not be missing")
    norm = _normalization(values, vmin, vmax)
    ax = _axes(ax)
    artist = ax.imshow(values, cmap=cmap, norm=norm, aspect="auto", interpolation="nearest")
    ax.set(xticks=range(values.shape[1]), xticklabels=[str(x) for x in column_labels],
           yticks=range(values.shape[0]), yticklabels=[str(x) for x in row_labels])
    ax.figure.colorbar(artist, ax=ax, label=value_label)
    return ax


def volcano(table, *, log2fc, padj, contrast, lfc_threshold, padj_threshold,
            zero_p_floor=None, ax=None):
    """Plot existing DE values; zero p requires an explicit display floor. Thresholds inclusive."""
    frame = _table(table, [log2fc, padj])
    _text(contrast, "contrast")
    fold, probabilities = _numbers(frame[log2fc], log2fc), _numbers(frame[padj], padj)
    if ((probabilities < 0) | (probabilities > 1)).any():
        raise ValueError("adjusted p values must be between zero and one")
    if not math.isfinite(lfc_threshold) or lfc_threshold < 0 or not math.isfinite(padj_threshold) or not 0 < padj_threshold <= 1:
        raise ValueError("lfc_threshold must be nonnegative; padj_threshold must be in (0, 1]")
    if zero_p_floor is not None and (not math.isfinite(zero_p_floor) or not 0 < zero_p_floor <= 1):
        raise ValueError("zero_p_floor must be in (0, 1]")
    zeros = probabilities == 0
    if zeros.any() and zero_p_floor is None:
        raise ValueError("zero adjusted p values require explicit zero_p_floor for display")
    displayed = probabilities.copy()
    if zeros.any():
        positive = probabilities[~zeros]
        if zero_p_floor > padj_threshold or (positive.size and zero_p_floor > positive.min()):
            raise ValueError("zero_p_floor must not exceed the p threshold or any positive p value")
        displayed[zeros] = zero_p_floor
    selected = (np.abs(fold) >= lfc_threshold) & (probabilities <= padj_threshold)
    colors = np.where(selected, "#B33A3A", "#777777")
    ax = _axes(ax)
    ax.scatter(fold, -np.log10(displayed), c=colors, s=20)
    for boundary in sorted(set([-lfc_threshold, lfc_threshold])):
        ax.axvline(boundary, color="black", linestyle="--", linewidth=.8)
    ax.axhline(-np.log10(padj_threshold), color="black", linestyle="--", linewidth=.8)
    ax.legend(handles=[Line2D([], [], marker="o", linestyle="none", color="#B33A3A", label="Meets supplied cutoffs"),
                       Line2D([], [], marker="o", linestyle="none", color="#777777", label="Other")])
    label = "-log10(adjusted p-value)"
    if zeros.any():
        label += f"; zero p displayed at {zero_p_floor:g}"
    ax.set(xlabel="log2 fold change", ylabel=label, title=contrast)
    return ax


def ma(table, *, abundance, log2fc, contrast, abundance_scale, ax=None):
    """Plot existing abundance and log2FC. abundance_scale describes values; no transform."""
    frame = _table(table, [abundance, log2fc])
    _text(contrast, "contrast")
    values = _numbers(frame[abundance], abundance)
    _numbers(frame[log2fc], log2fc)
    if abundance_scale not in ("linear", "log2", "log10"):
        raise ValueError("abundance_scale must be linear, log2 or log10")
    if abundance_scale == "linear" and (values < 0).any():
        raise ValueError("linear abundance must be nonnegative")
    ax = _axes(ax)
    ax.scatter(values, frame[log2fc], s=20)
    ax.axhline(0, color="black", linestyle="--", linewidth=.8)
    ax.set(xlabel=f"{abundance} ({abundance_scale})", ylabel="log2 fold change", title=contrast)
    return ax


def compose(panels, *, ncols=2, figsize=None, labels=None, width_ratios=None, height_ratios=None):
    """Call each ``panel(ax)`` in row-major order on one editable native Figure."""
    panels = list(panels)
    if not panels or not all(callable(panel) for panel in panels):
        raise ValueError("panels must be a nonempty sequence of callables receiving ax")
    if labels is not None:
        labels = list(labels)
        if len(labels) != len(panels) or not all(isinstance(label, str) for label in labels):
            raise ValueError("labels must provide one string per panel")
    fig, axes = _grid(len(panels), ncols, figsize, width_ratios, height_ratios)
    for i, (panel, ax) in enumerate(zip(panels, axes)):
        panel(ax)
        if labels is not None:
            ax.text(0, 1.04, labels[i], transform=ax.transAxes, fontweight="bold")
    return fig
