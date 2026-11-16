"""Synthetic continuous metadata lifecycle; creates a new directory only."""
from pathlib import Path
import argparse
import json
from biodataledger import ProjectBundle

CATEGORIES = ["sample_preparation", "acquisition", "processing_qc", "analysis", "annotation", "result"]


def run(root):
    root = Path(root).resolve()
    root.mkdir()  # Existing destination is refused; never overwrite a real project.
    project = ProjectBundle.create("Synthetic metadata lifecycle", root)

    def table(filename, text, category, keys, links=None, ref=None, units=None):
        (root / filename).write_text(text, encoding="utf-8")
        return project.register_metadata(filename, category, keys,
            authority="Synthetic example: supplied fixture, not biological evidence",
            reason="Demonstrate continuous metadata history", links=links,
            ref=ref, units=units)

    def link(ref, columns, targets=None):
        return {"ref": ref, "columns": columns, "target_columns": targets or columns}

    # First record exists before any sequencing data or scientific matrix.
    samples = table("samples.csv", "sample_id,donor_id,treatment,tissue\n001,D01,control,tissue_A\n002,D02,treated,tissue_A\n",
                    "sample_preparation", ["sample_id"])
    project.set_current(samples, "sample_sheet", "Select the synthetic sample sheet")
    # One sample split across libraries; one library pooled across two samples.
    acquisition = table("libraries.csv", "library_id,sample_id,rna_input\nL1,001,3\nPOOL,001,1.5\nPOOL,002,1.5\n",
                        "acquisition", ["library_id", "sample_id"], [link(samples, ["sample_id"])], units={"rna_input": "ng"})
    qc = table("qc.csv", "sample_id,cell_id,library_id,included,reason\n001,C1,L1,true,\n001,C2,POOL,false,no paired receptor\n002,C1,POOL,true,\n",
               "processing_qc", ["sample_id", "cell_id"], [link(acquisition, ["library_id", "sample_id"])])
    (root / "analysis_ready.csv").write_text("sample_id,cell_id,value\n001,C1,1\n002,C1,2\n")
    data = project.register_data("analysis_ready.csv", "analysis_ready", hash=True)
    data = project.bind_metadata(data, [qc], "Context for the retained synthetic subset")
    analysis = project.register_analysis("Synthetic assignment example", [data],
        method="Supplied illustrative assignments; no clustering was executed",
        params={"illustrative_resolution": 0.4})
    clusters = table("clusters.csv", "sample_id,cell_id,cluster,resolution\n001,C1,0,0.4\n002,C1,1,0.4\n",
                     "analysis", ["sample_id", "cell_id"], [link(qc, ["sample_id", "cell_id"])])
    labels = table("labels.csv", "sample_id,cell_id,label\n001,C1,population A\n002,C1,provisional B\n",
                   "annotation", ["sample_id", "cell_id"], [link(clusters, ["sample_id", "cell_id"])])
    previous_analysis = project.bind_metadata(analysis, [labels], "Original illustrative annotation")
    revised_labels = table("labels_corrected.csv", "sample_id,cell_id,label\n001,C1,population A\n002,C1,population B\n",
                           "annotation", ["sample_id", "cell_id"], [link(clusters, ["sample_id", "cell_id"])], ref=labels)
    current_analysis = project.bind_metadata(previous_analysis, [revised_labels], "Illustrate an annotation correction")
    result_metadata = table("result_meaning.csv", "measure,observation_unit,denominator,summary\nretained_count,cells,eligible cells,count\n",
                            "result", ["measure"])
    (root / "result.csv").write_text("measure,value\nretained_count,2\n")
    result = project.register_result("result.csv", current_analysis, hash=True)
    result = project.bind_metadata(result, [result_metadata], "Meaning of the retained quantity")
    project.save_and_confirm()
    reopened = ProjectBundle.open(root)
    report = reopened.check_metadata(result, required_categories=CATEGORIES)
    assert report["bl_status"] == "PASS", report
    assert reopened.get_metadata(labels)["bl_rows"][1]["label"] == "provisional B"
    assert reopened.get_metadata(revised_labels)["bl_rows"][1]["label"] == "population B"
    assert reopened.metadata_view(previous_analysis)["bl_categories"]["annotation"][0]["bl_ref"] == labels
    assert reopened.get_metadata(qc)["bl_row_count"] == 3  # Excluded cell remains documented.
    output = {"project": str(root), "samples": samples, "result": result,
              "previous_analysis": previous_analysis, "current_analysis": current_analysis,
              "metadata_check": report, "scientific_acceptance": "not_assessed"}
    (root / "metadata_example_receipt.json").write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_dir", help="New nonexistent directory in an existing parent")
    run(parser.parse_args().project_dir)
