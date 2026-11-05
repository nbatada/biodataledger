"""Synthetic PRMT5 lineage only: no expression data or analysis execution."""
from pathlib import Path
from tempfile import TemporaryDirectory

from biodataledger import ProjectBundle


def create_example(root):
    root = Path(root)
    (root / "original-gex.txt").write_text("synthetic placeholder\n")
    (root / "analysis-ready-gex.txt").write_text("synthetic placeholder\n")
    (root / "umap.csv").write_text("sample_id,cell_id,x,y\nS1,C1,0,1\n")
    (root / "figure.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>')
    project = ProjectBundle.create("Synthetic PRMT5 lineage", root)
    original = project.register_data("original-gex.txt", "raw", name="Original GEX")
    qc = project.register_analysis("QC", inputs=[original])
    ready = project.register_result("analysis-ready-gex.txt", qc)
    cd8 = project.register_analysis("CD8 analysis", inputs=[ready])
    umap = project.register_result("umap.csv", cd8, embedding={"format": "csv", "coordinate_columns": ["x", "y"]})
    fig = project.register_figure("figure.svg", "umap", analysis=cd8, name="Saved UMAP figure",
                                  figure_sources={"rendering_inputs": [umap], "relationship": "declared"})
    project.save()
    return project, original, fig


def main():
    with TemporaryDirectory(prefix="synthetic-graph-") as root:
        project, _, fig = create_example(root)
        print(project.export_graph(fig, depth=6), end="")


if __name__ == "__main__":
    main()
