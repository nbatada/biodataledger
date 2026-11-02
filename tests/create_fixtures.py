"""Create only synthetic contract fixtures and a small portable example."""
import json
from pathlib import Path
import tempfile
from biodataledger import ProjectBundle


def make_project(root):
    root.mkdir(parents=True, exist_ok=False)
    (root / "input.csv").write_text("sample,genes\nS1,300\nS2,400\n")
    (root / "qc.py").write_text('''"""Synthetic display recipe. No clinical data or scientific inference."""
from pathlib import Path

def main():
    for name, label in [("library.svg", "Synthetic library QC"), ("genes.svg", "Synthetic genes QC")]:
        Path(name).write_text('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="60"><text x="10" y="30">' + label + '</text></svg>')

if __name__ == "__main__":
    main()
''')
    for name, label in (("library.svg", "Synthetic library QC"), ("genes.svg", "Synthetic genes QC")):
        (root / name).write_text('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="60"><text x="10" y="30">' + label + '</text></svg>')
    p = ProjectBundle.create("Synthetic Project Bundle Trial", root, purpose="Find retained QC figures and their declared sources")
    d = p.register_data("input.csv", "analysis_ready", hash=True, subset="synthetic two samples")
    p.set_current(d, "qc", "synthetic trial input, not scientific approval")
    p.set_context({"next_task": "Inspect FIG-001@1 and report its known sources and unknown execution evidence."})
    p.save()
    a = p.register_analysis("Synthetic QC", [d], code="qc.py", method="synthetic display",
                            params={"min_genes": 200}, unit="sample")
    f = p.register_figure("library.svg", "qc", analysis=a)
    g = p.register_figure("genes.svg", "qc", analysis=a)
    legacy = p.register_figure("genes.svg", "legacy", name="Legacy T-cell clonality (synthetic)")
    p.save()
    return p, d, f, g, legacy


def main():
    base = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary:
        p, *_ = make_project(Path(temporary) / "example")
        state = p.state
        (base / "tests/fixtures/with-provenance.json").write_text(json.dumps(state, indent=2))
        invalid = json.loads(json.dumps(state))
        invalid["current"]["qc"]["revision"] = 999
        (base / "tests/fixtures/invalid-dangling.json").write_text(json.dumps(invalid))
        empty_dir = Path(temporary) / "empty"
        empty_dir.mkdir()
        empty = ProjectBundle.create("Empty", empty_dir)
        (base / "tests/fixtures/minimal.json").write_text(json.dumps(empty.state, indent=2))
    (base / "tests/fixtures/invalid-duplicate-key.json").write_text('{"schema_version":"0.1.0","schema_version":"0.1.0"}')


if __name__ == "__main__":
    main()
