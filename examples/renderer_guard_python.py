"""Headless synthetic guarded rendering; run with an explicit existing directory."""
import argparse
from biodataledger import ProjectBundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_dir", help="existing directory without a BioDataLedger registry")
    args = parser.parse_args()
    project = ProjectBundle.create("Synthetic guarded rendering", args.project_dir)
    project.require_approved_figures("Retain native-rendered figures")
    figure = project.render_figure(
        "pca", data={"PC1": [1., 2., 3.], "PC2": [3., 1., 2.]},
        plot_args={"x": "PC1", "y": "PC2"}, name="Synthetic PCA", dpi=100,
    )
    project.save()
    print(project.get_figure(figure).details["renderer_receipt"])


if __name__ == "__main__":
    main()
