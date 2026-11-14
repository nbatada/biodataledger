"""Focused installed-client plotting checks using synthetic prepared values only."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import biodataledger as bdl

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np
    import pandas as pd
    from biodataledger import pl
    HAS_PLOTTING = True
except ImportError:
    HAS_PLOTTING = False


class CorePlottingBoundaryTests(unittest.TestCase):
    def test_core_without_optional_dependencies(self):
        installed_site = str(Path(bdl.__file__).resolve().parents[1])
        code = '''
import sys
sys.path.insert(0, sys.argv[1])
class BlockOptional:
    def find_spec(self, fullname, path=None, target=None):
        if fullname.split('.')[0] in ('matplotlib', 'numpy', 'pandas'):
            raise ImportError('optional dependency blocked')
sys.meta_path.insert(0, BlockOptional())
import biodataledger as bdl
assert not any(x in sys.modules for x in ('matplotlib', 'numpy', 'pandas'))
from pathlib import Path
import tempfile
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'data.csv').write_text('sample,value\\nS1,3\\n')
    project = bdl.ProjectBundle.create('Synthetic plotting boundary', root)
    ref = project.register_data('data.csv', 'plotting_input', name='prepared plotting input')
    project.save()
    reopened = bdl.ProjectBundle.open(root)
    assert reopened.get_data(ref).name == 'prepared plotting input'
try:
    bdl.pl
except ImportError as exc:
    assert 'biodataledger[plotting]' in str(exc)
else:
    raise AssertionError('plotting unexpectedly available')
'''
        result = subprocess.run([sys.executable, "-S", "-c", code, installed_site],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(HAS_PLOTTING, "optional plotting dependencies unavailable")
class PlottingTests(unittest.TestCase):
    def setUp(self):
        self.frame = pd.DataFrame({"PC1": [1., 3., -1., 5.], "PC2": [2., -2., 4., 0.],
                                   "sample": ["S1", "S2", "S3", "S4"],
                                   "group": ["A", "A", "B", "B"], "signal": [0., 4., 8., 12.]})
        self.original = self.frame.copy(deep=True)

    def tearDown(self):
        pd.testing.assert_frame_equal(self.frame, self.original)
        plt.close("all")

    def test_pca_exact_coordinates_labels_and_editability(self):
        ax = pl.pca(self.frame, x="PC1", y="PC2", sample_id="sample", label_samples=True,
                    variance_percent=[41, 19])
        np.testing.assert_array_equal(ax.collections[0].get_offsets(), self.frame[["PC1", "PC2"]])
        self.assertEqual(ax.get_xlabel(), "PC1 (41% variance)")
        self.assertEqual([t.get_text() for t in ax.texts], list(self.frame["sample"]))
        ax.set_title("Edited native title")
        self.assertEqual(ax.get_title(), "Edited native title")

    def test_split_shared_bounds_normalization_and_panel_order(self):
        fig = pl.umap_split(self.frame, x="PC1", y="PC2", split_by="group",
                            split_order=["B", "A"], color="signal", color_kind="continuous")
        left, right = fig.axes[:2]
        self.assertEqual([left.get_title(), right.get_title()], ["B", "A"])
        self.assertEqual(left.get_xlim(), right.get_xlim())
        self.assertEqual(left.get_ylim(), right.get_ylim())
        self.assertEqual(left.get_aspect(), 1.)
        self.assertIs(left.collections[0].norm, right.collections[0].norm)
        self.assertEqual((left.collections[0].norm.vmin, left.collections[0].norm.vmax), (0, 12))
        np.testing.assert_array_equal(left.collections[0].get_offsets(), self.frame.loc[2:, ["PC1", "PC2"]])
        np.testing.assert_array_equal(left.collections[0].get_array(), [8., 12.])

    def test_category_palette_global_mapping_and_invalid_mapping(self):
        fig = pl.umap_split(self.frame, x="PC1", y="PC2", split_by="group", color="group",
                            palette={"A": "red", "B": "blue"})
        np.testing.assert_array_equal(fig.axes[0].collections[0].get_facecolor()[0], [1, 0, 0, 1])
        np.testing.assert_array_equal(fig.axes[1].collections[1].get_facecolor()[0], [0, 0, 1, 1])
        with self.assertRaises(ValueError):
            pl.pca(self.frame, x="PC1", y="PC2", color="group", palette={"A": "red"})

    def test_violin_exact_points_and_singleton_constant_groups(self):
        ax = pl.violin_qc(self.frame, group="group", value="signal", value_label="Counts (UMI)")
        points = [artist.get_offsets() for artist in ax.collections if isinstance(artist, matplotlib.collections.PathCollection)]
        np.testing.assert_array_equal(points[0], [[0., 0.], [0., 4.]])
        self.assertEqual(ax.get_ylabel(), "Counts (UMI)")
        constant = self.frame.assign(signal=1.)
        ax2 = pl.violin_qc(constant, group="sample", value="signal", value_label="Counts")
        self.assertEqual(len(ax2.collections), 4)

    def test_group_observation_identity_order_and_units(self):
        ax = pl.group_comparison(self.frame, group="group", value="signal", sample_id="sample",
                                 observation_unit="biological sample", value_label="Counts",
                                 group_order=["B", "A"])
        np.testing.assert_array_equal(ax.collections[0].get_offsets(), [[0., 8.], [0., 12.]])
        self.assertIn("biological sample", ax.get_title())
        with self.assertRaises(ValueError):
            pl.group_comparison(self.frame.assign(sample="S1"), group="group", value="signal",
                                sample_id="sample", observation_unit="sample", value_label="Counts")

    def test_heatmap_preserves_values_order_and_no_clipping(self):
        matrix = pd.DataFrame([[2, -1], [8, 4]], index=["g2", "g1"], columns=["S2", "S1"])
        original = matrix.copy(deep=True)
        ax = pl.heatmap(matrix, value_label="log2 expression")
        np.testing.assert_array_equal(ax.images[0].get_array(), matrix)
        self.assertEqual([t.get_text() for t in ax.get_xticklabels()], ["S2", "S1"])
        pd.testing.assert_frame_equal(matrix, original)
        with self.assertRaises(ValueError):
            pl.heatmap(matrix, value_label="value", vmax=5)
        with self.assertRaises(ValueError):
            pl.heatmap([[1, 2]], value_label="value")

    def test_volcano_thresholds_zero_handling_no_mutation(self):
        de = pd.DataFrame({"fc": [2., 1., -3., 0.], "q": [.01, .05, 0., .8]})
        original = de.copy(deep=True)
        with self.assertRaises(ValueError):
            pl.volcano(de, log2fc="fc", padj="q", contrast="B vs A", lfc_threshold=1, padj_threshold=.05)
        ax = pl.volcano(de, log2fc="fc", padj="q", contrast="B vs A", lfc_threshold=1,
                        padj_threshold=.05, zero_p_floor=1e-8)
        np.testing.assert_allclose(ax.collections[0].get_offsets(), [[2, 2], [1, -np.log10(.05)], [-3, 8], [0, -np.log10(.8)]])
        colors = ax.collections[0].get_facecolors()
        np.testing.assert_array_equal(colors[0], colors[1])
        self.assertFalse(np.array_equal(colors[0], colors[3]))
        self.assertIn("zero p displayed at 1e-08", ax.get_ylabel())
        self.assertEqual(ax.get_xlabel(), "log2 fold change")
        self.assertEqual([t.get_text() for t in ax.get_legend().get_texts()], ["Meets supplied cutoffs", "Other"])
        pd.testing.assert_frame_equal(de, original)

    def test_ma_scale_is_metadata_not_transform(self):
        ax = pl.ma(self.frame, abundance="signal", log2fc="PC1", contrast="B vs A", abundance_scale="linear")
        np.testing.assert_array_equal(ax.collections[0].get_offsets(), self.frame[["signal", "PC1"]])
        self.assertEqual(ax.get_xlabel(), "signal (linear)")
        with self.assertRaises(ValueError):
            pl.ma(self.frame, abundance="PC1", log2fc="PC2", contrast="B vs A", abundance_scale="linear")

    def test_composition_native_axes_panel_labels_ratios_and_order(self):
        received = []
        def panel(name):
            def draw(ax):
                received.append(ax)
                ax.set_title(name)
                pl.pca(self.frame, x="PC1", y="PC2", ax=ax)
            return draw
        fig = pl.compose([panel("first"), panel("second"), panel("third")], ncols=2,
                         labels=["a", "b", "c"], width_ratios=[2, 1], height_ratios=[1, 2])
        self.assertEqual(received, fig.axes)
        self.assertEqual([ax.get_title() for ax in fig.axes], ["first", "second", "third"])
        self.assertEqual([ax.texts[0].get_text() for ax in fig.axes], ["a", "b", "c"])
        self.assertEqual(fig.axes[0].get_gridspec().get_width_ratios(), [2, 1])
        with self.assertRaises(ValueError):
            pl.compose([panel("a")], labels=[])
        with self.assertRaises(ValueError):
            pl.compose([panel("a"), panel("b")], width_ratios=[1])

    def test_invalid_values_bounds_orders_and_sample_labels(self):
        for invalid in (np.nan, np.inf, complex(1, 2)):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                pl.pca(self.frame.assign(PC1=invalid), x="PC1", y="PC2")
        with self.assertRaises(ValueError):
            pl.pca(self.frame, x="PC1", y="PC2", color="signal", color_kind="continuous", vmax=5)
        with self.assertRaises(ValueError):
            pl.pca(self.frame, x="PC1", y="PC2", label_samples=True)
        with self.assertRaises(ValueError):
            pl.pca(self.frame.assign(sample="S1"), x="PC1", y="PC2", sample_id="sample")
        with self.assertRaises(ValueError):
            pl.umap_split(self.frame, x="PC1", y="PC2", split_by="group", split_order=["A"])
        with self.assertRaises(ValueError):
            pl.pca(self.frame, x="PC1", y="PC2", variance_percent=[80, 40])
        with self.assertRaises(ValueError):
            pl.volcano(self.frame.assign(q=1.1), log2fc="PC1", padj="q", contrast="B vs A", lfc_threshold=1, padj_threshold=.05)


if __name__ == "__main__":
    unittest.main()
