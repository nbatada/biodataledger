"""Render lineage-demo:cells-by-sample from its saved count CSV."""

import argparse
import csv
from html import escape
from pathlib import Path


def render_counts(count_path, output_path):
    with count_path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    series = [
        ("cohort_a_cells", "#17628D", "A  Hashed · Vehicle and Low"),
        ("cohort_b_cells", "#A24520", "B  Hashed or unassigned · All treatments"),
    ]
    left, plot_width = 174, 507
    axis_y = 143 + 63 * len(rows)
    max_count = max(int(row[field]) for row in rows for field, _, _ in series)
    tick_step = max(1, (max_count + 5) // 6)
    axis_max = max(tick_step, ((max_count + tick_step - 1) // tick_step) * tick_step)
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="760" height="{axis_y + 81}" '
        f'viewBox="0 0 760 {axis_y + 81}" role="img" aria-labelledby="title description">',
        '<title id="title">Cells included by sample</title>',
        '<desc id="description">Synthetic counts for two cohorts, grouped by sample and treatment.</desc>',
        '<rect width="100%" height="100%" fill="#FFFFFF"/>',
        '<g font-family="system-ui, sans-serif" fill="#172C3B">',
        '<text x="24" y="39" font-size="26" font-weight="700">Cells included by sample</text>',
        '<text x="24" y="65" font-size="15">Synthetic data · Descriptive counts</text>',
    ]
    for x, (_, color, label) in zip([24, 320], series):
        svg.append(f'<rect x="{x}" y="91" width="14" height="14" rx="2" fill="{color}"/>')
        svg.append(f'<text x="{x + 22}" y="103" font-size="14">{label}</text>')

    for tick in range(0, axis_max + 1, tick_step):
        x = left + tick / axis_max * plot_width
        svg.append(f'<line x1="{x:.2f}" y1="125" x2="{x:.2f}" y2="{axis_y}" stroke="#D4DFE6"/>')
        svg.append(f'<text x="{x:.2f}" y="{axis_y + 18}" text-anchor="middle" font-size="13">{tick}</text>')

    for row_index, row in enumerate(rows):
        y = 137 + 63 * row_index
        sample = escape(f"{row['sample_id']} · {row['treatment']}")
        svg.append(f'<text x="{left - 14}" y="{y + 22}" text-anchor="end" font-size="15">{sample}</text>')
        for bar_index, (field, color, _) in enumerate(series):
            bar_y = y + 21 * bar_index
            count = int(row[field])
            width = count / axis_max * plot_width
            svg.append(f'<rect x="{left}" y="{bar_y}" width="{width:.2f}" height="15" rx="2" fill="{color}"/>')
            svg.append(f'<text x="{left + width + 7:.2f}" y="{bar_y + 12}" font-size="13">{count}</text>')

    svg.extend([
        f'<line x1="{left}" y1="{axis_y}" x2="{left + plot_width}" y2="{axis_y}" stroke="#677D8A"/>',
        f'<text x="{left + plot_width / 2:.2f}" y="{axis_y + 39}" text-anchor="middle" font-size="15">Included cells</text>',
        f'<text x="24" y="{axis_y + 65}" font-size="13">Cohort A excludes the High sample by design.</text>',
        '</g></svg>',
    ])
    with output_path.open("x", encoding="utf-8") as stream:
        stream.write("\n".join(svg) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("count_csv", type=Path)
    parser.add_argument("new_svg", type=Path)
    args = parser.parse_args()
    render_counts(args.count_csv, args.new_svg)
