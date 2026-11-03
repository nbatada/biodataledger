"""Register an existing tiny synthetic input and two figures in a new trial folder."""
from pathlib import Path
import shutil
import sys
from biodataledger import ProjectBundle


def main(project_dir):
    root = Path(project_dir).expanduser().resolve()
    root.mkdir()  # Refuse to overwrite an existing project.
    inputs = Path(__file__).resolve().parent / "input-files"
    for name in ("input.csv", "library.svg", "genes.svg", "qc.py"):
        shutil.copyfile(inputs / name, root / name)
    p = ProjectBundle.create("Synthetic trial", project_dir=root)
    data = p.register_data("input.csv", role="analysis_ready", hash=True)
    p.set_current(data, purpose="qc", reason="Synthetic trial input; no scientific approval")
    receipt = p.save_and_confirm()
    p = ProjectBundle.open(project_dir=root)
    data = p.resolve_data(purpose="qc", verify="sha256")
    # Retain already-saved files. Parameters and source are declarations, not execution proof.
    analysis = p.register_analysis("Synthetic QC", inputs=[data.ref], code="qc.py",
                                   method="synthetic display", params={"min_genes": 200})
    first = p.register_figure("library.svg", type="qc", analysis=analysis)
    p.register_figure("genes.svg", type="qc", analysis=analysis)
    receipt = p.save_and_confirm()
    print("Persisted", first, "in", root, "receipt:", receipt)
    print("Four retention calls; shared source/method/parameters entered once. No rerun verified.")


if __name__ == "__main__":
    main(sys.argv[1])
