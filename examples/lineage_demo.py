"""Create or inspect the synthetic cohort-count example in docs/LINEAGE_DEMO.md."""

import argparse
import csv
import sys
from collections import Counter
from datetime import date
from pathlib import Path

from biodataledger import ProjectBundle
from lineage_demo_plot import render_counts


QUESTION = "Which samples and cells are included in this comparison?"
FIGURE_TITLE = "Cells included by sample"
CURRENT_PURPOSE = "cohort-a-review"
CELL_FIELDS = ["sample_id", "cell_id", "treatment", "assignment"]
COUNT_FIELDS = ["sample_id", "treatment", "cohort_a_cells", "cohort_b_cells"]


def read_csv(path):
    with path.open(newline="", encoding="utf-8") as stream:
        return list(csv.DictReader(stream))


def write_csv(path, fields, rows):
    with path.open("x", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def write_synthetic_cells(path):
    # Each row is one invented cell. No expression values or biological replicates.
    samples = [("S01", "Vehicle", 5, 2, 1), ("S02", "Low", 3, 3, 1), ("S03", "High", 4, 1, 2)]
    rows = []
    for sample_id, treatment, hashed, unassigned, ambiguous in samples:
        assignments = ["hashed"] * hashed + ["unassigned"] * unassigned + ["ambiguous"] * ambiguous
        for i, assignment in enumerate(assignments, start=1):
            rows.append(dict(sample_id=sample_id, cell_id=f"{sample_id}-C{i:02d}",
                             treatment=treatment, assignment=assignment))
    write_csv(path, CELL_FIELDS, rows)


def retain_cohort(project, raw_path, raw, cohort_path, *, treatments, assignments, ref=None):
    analysis = project.register_analysis(
        f"Select {cohort_path.stem}", inputs=[raw], code=Path(__file__).resolve(),
        method="Select cell rows by treatment and assignment",
        params={"treatments": treatments, "assignments": assignments},
    )
    rows = [cell for cell in read_csv(raw_path)
            if cell["treatment"] in treatments and cell["assignment"] in assignments]
    write_csv(cohort_path, CELL_FIELDS, rows)
    return project.register_result(cohort_path, analysis, ref=ref, hash=True)


def count_cells(cohort_a_path, cohort_b_path, count_path):
    def counts(path):
        return Counter((cell["sample_id"], cell["treatment"]) for cell in read_csv(path))

    cohort_a = counts(cohort_a_path)
    cohort_b = counts(cohort_b_path)
    rows = [dict(sample_id=sample_id, treatment=treatment,
                 cohort_a_cells=cohort_a[sample_id, treatment],
                 cohort_b_cells=cohort_b[sample_id, treatment])
            for sample_id, treatment in sorted(cohort_a.keys() | cohort_b.keys())]
    write_csv(count_path, COUNT_FIELDS, rows)


def create(root):
    root.mkdir()  # Exclusive, including when an existing directory is empty.
    project = ProjectBundle.create("Synthetic sample inclusion QC", root)
    raw_path = root / "synthetic-cells.csv"
    write_synthetic_cells(raw_path)
    raw = project.register_data(raw_path, "raw", name="Synthetic cell assignments", hash=True)

    # Two separate analysis-ready cohorts from the same source rows.
    cohort_a_path = root / "cohort-a-hashed.csv"
    cohort_a = retain_cohort(project, raw_path, raw, cohort_a_path,
                             treatments=["Vehicle", "Low"], assignments=["hashed"])
    cohort_b_path = root / "cohort-b-hashed-or-unassigned.csv"
    cohort_b = retain_cohort(project, raw_path, raw, cohort_b_path,
                             treatments=["Vehicle", "Low", "High"], assignments=["hashed", "unassigned"])

    # Count one row per included cell, grouped by sample and cohort.
    count_path = root / "cells-by-sample.csv"
    counting = project.register_analysis(
        "Count included cells by sample", inputs=[cohort_a, cohort_b], code=Path(__file__).resolve(),
        method="Count included cell rows per sample separately for each cohort",
    )
    count_cells(cohort_a_path, cohort_b_path, count_path)
    table = project.register_result(count_path, counting, hash=True)

    # The plotting script reads only the retained count table.
    plotting = project.register_analysis(
        "Plot sample inclusion", inputs=[table], code=Path(__file__).resolve().with_name("lineage_demo_plot.py"),
        method="Draw paired horizontal bars from the retained count table",
    )
    plot_path = root / "cells-by-sample.svg"
    render_counts(count_path, plot_path)
    figure = project.register_figure(
        plot_path, "qc", analysis=plotting, name=FIGURE_TITLE,
        figure_sources={"asset_id": "lineage-demo:cells-by-sample", "rendering_inputs": [table],
                        "relationship": "declared", "generating_code": {"record": plotting, "index": 0}},
    )
    project.set_presentation(
        figure, primary_topic="QC-samples", description="cells-by-sample", generated_on=date.today().isoformat(),
        questions=[QUESTION], title=FIGURE_TITLE, subtitle="Synthetic example",
        uses=[{"kind": "slide", "document_id": "synthetic-qc-deck", "item_id": "sample-inclusion",
               "title": "Sample inclusion"}],
        reason="Record the question and declared slide use",
    )

    # A later version of A keeps unassigned cells. The saved plot still uses A's earlier revision.
    updated_a = retain_cohort(project, raw_path, raw, root / "cohort-a-updated.csv", ref=cohort_a,
                              treatments=["Vehicle", "Low"], assignments=["hashed", "unassigned"])
    project.set_current(updated_a, purpose=CURRENT_PURPOSE, reason="Use the updated cohort for the next review")
    project.save()
    print(f"Saved synthetic project in {root}")


def exact_label(ref):
    return f"{ref['id']}@{ref['revision']}"


def inspect(root):
    project = ProjectBundle.open(root)
    matches = project.find_outputs(topic="QC-samples", question=QUESTION, kind="figure",
                                   document_id="synthetic-qc-deck")
    if matches["total"] != 1:
        raise ValueError("Expected one retained figure for the demo question and slide deck")
    figure = matches["items"][0]["ref"]
    info = project.get_info(figure)
    table = info["rendering_inputs"]["items"][0]["ref"]
    plotting_code = info["plotting_code"]["generating_code"]["selector"]
    cohort_roots = [item["ref"] for item in project.get_info(table)["inputs"]["items"]]
    current_a = project.get_data(purpose=CURRENT_PURPOSE).ref

    # These calls explicitly check file bytes. The metadata queries above do not.
    plot = project.resolve_figure(figure, verify="sha256")
    counts = project.resolve_data(ref=table, verify="sha256")
    code = project.read_figure_source(figure, code_ref=plotting_code)
    print(f"Project {figure['project_id']}", file=sys.stderr)
    print(f"Figure {exact_label(figure)} {plot.path}", file=sys.stderr)
    print(f"Suggested filename {project.output_name(figure)['filename']}", file=sys.stderr)
    print(f"Rendering input {exact_label(table)} {counts.path}", file=sys.stderr)
    print(f"Plotting code {exact_label(plotting_code['record'])} index {plotting_code['index']} "
          f"{root / code['snapshot']}", file=sys.stderr)
    print(f"Plotting code SHA-256 {code['sha256']}", file=sys.stderr)
    print(f"Counted cohorts {', '.join(map(exact_label, cohort_roots))}", file=sys.stderr)
    print(f"Current cohort A for review {exact_label(current_a)}", file=sys.stderr)

    return project.export_graph(ref=figure, direction="upstream", depth=8, style="presentation",
                                lineage_roots=cohort_roots)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "inspect"])
    parser.add_argument("project_dir", type=Path)
    args = parser.parse_args()
    root = args.project_dir.expanduser().absolute()
    if args.action == "create":
        create(root)
    else:
        print(inspect(root), end="")


if __name__ == "__main__":
    main()
