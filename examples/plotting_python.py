"""Synthetic editable plotting gallery. Run with --output to explicitly save SVGs."""
import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
import biodataledger as bdl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New output directory; existing paths are refused")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    samples = pd.DataFrame({"sample": ["S1", "S2", "S3", "S4"],
                            "condition": ["control", "control", "treated", "treated"],
                            "PC1": [-2., -1., 1., 2.], "PC2": [-1., 1., 1., -1.],
                            "library_millions": [12., 18., 15., 23.]})
    de = pd.DataFrame({"gene": ["G1", "G2", "G3", "G4"],
                       "log2FC": [-2., 1.5, .2, 3.], "padj": [.01, .02, .9, .001],
                       "mean_normalized_count": [25., 90., 15., 250.]})
    palette = {"control": "#377EB8", "treated": "#E41A1C"}
    panels = [
        lambda ax: bdl.pl.pca(samples, x="PC1", y="PC2", sample_id="sample", color="condition",
                             variance_percent=[42, 18], palette=palette, ax=ax),
        lambda ax: bdl.pl.volcano(de, log2fc="log2FC", padj="padj", contrast="treated vs control",
                                 lfc_threshold=1, padj_threshold=.05, ax=ax),
        lambda ax: bdl.pl.ma(de, abundance="mean_normalized_count", log2fc="log2FC",
                            contrast="treated vs control", abundance_scale="linear", ax=ax),
        lambda ax: bdl.pl.group_comparison(samples, group="condition", value="library_millions",
                                          sample_id="sample", observation_unit="biological sample",
                                          value_label="Library size (million reads)", palette=palette, ax=ax),
        lambda ax: bdl.pl.violin_qc(samples, group="condition", value="library_millions",
                                   value_label="Library size (million reads)", palette=palette, ax=ax),
        lambda ax: bdl.pl.heatmap(pd.DataFrame([[2., -1., 0., 1.], [-2., 1., 2., 0.]],
                                             index=["G1", "G2"], columns=samples["sample"]),
                                 value_label="Prepared log2 expression", ax=ax),
    ]
    figure = bdl.pl.compose(panels, ncols=2, labels=list("abcdef"), figsize=(12, 13), width_ratios=[1, 1])
    figure.axes[0].set_title("Prepared PCA coordinates")  # Native Matplotlib customization.
    figure.subplots_adjust(wspace=.5, hspace=.55)
    figure.savefig(args.output / "bulk_rnaseq.svg")
    # Synthetic coordinates illustrate the API; they are not a fitted UMAP.
    split = bdl.pl.umap_split(samples, x="PC1", y="PC2", split_by="condition",
                             color="library_millions", color_kind="continuous")
    split.savefig(args.output / "split_coordinates.svg")
    plt.close(figure)
    plt.close(split)


if __name__ == "__main__":
    main()
