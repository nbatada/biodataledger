#!/usr/bin/env python3
"""Run a synthetic shared-library workflow with an installed BioDataLedger client."""
import argparse
import hashlib
import inspect
import json
import tempfile
from pathlib import Path

from biodataledger import ProjectBundle, __version__

FUNCTION_NAME = "nb_utils_general_check_columns"
CONTRACT_V1 = {
    "inputs": "A list of row dictionaries",
    "parameters": "required: ordered column names",
    "outputs": "Required names missing from at least one row, in the supplied order",
    "example": "nb_utils_general_check_columns(rows, ['sample_id', 'value'])",
    "limitations": "Checks column presence only; no scientific validation",
}
CONTRACT_V2 = dict(CONTRACT_V1, parameters="required: ordered names; strict=False: raise if missing")
SOURCE_V1 = '''def nb_utils_general_check_columns(rows, required):
    return [name for name in required if any(name not in row for row in rows)]
'''
SOURCE_V2 = '''def nb_utils_general_check_columns(rows, required, strict=False):
    missing = [name for name in required if any(name not in row for row in rows)]
    if strict and missing:
        raise ValueError("Missing columns: " + ", ".join(missing))
    return missing
'''


def check_capabilities():
    required = ("register_helper", "find_helpers", "get_helper", "register_helper_from",
                "register_analysis", "register_result", "register_data", "resolve_data")
    missing = [name for name in required if not callable(getattr(ProjectBundle, name, None))]
    if not missing and "sources" not in inspect.signature(ProjectBundle.find_helpers).parameters:
        missing.append("find_helpers(sources=...)")
    if missing:
        raise RuntimeError(f"BioDataLedger {__version__} lacks {', '.join(missing)}. "
                           "Use a compatible installed client; nothing was installed or upgraded.")


def select_exact(report, library_root, source_ref):
    """Choose the known fixture identity, never the first or newest search result."""
    matches = [card for card in report["helpers"]
               if card["source_project"]["location"] == str(library_root)
               and card["source_project"]["id"] == source_ref["project_id"]
               and card["ref"] == source_ref]
    if len(matches) != 1:
        raise RuntimeError("The reviewed helper was not uniquely found; inspect source coverage.")
    return matches[0]


def load_reviewed_snapshot(project, helper_ref):
    """Load only this example's reviewed single-file function, after an explicit save."""
    card = project.get_helper(helper_ref, verify="snapshot")
    files = card["verification"]["files"]
    if card["verification"]["status"] != "pass" or len(files) != 1:
        raise RuntimeError("Retained source is missing or changed; no working-file fallback.")
    path = Path(files[0]["path"])
    # This fixture's source is visible above. A matching hash does not make arbitrary code safe.
    namespace = {"__name__": "reviewed_shared_helper", "__file__": str(path)}
    exec(compile(path.read_text(), str(path), "exec"), namespace)
    return namespace[FUNCTION_NAME], path


def main(destination=None):
    check_capabilities()
    if destination is None:
        root = Path(tempfile.mkdtemp(prefix="bdl-shared-library-")).resolve()
    else:
        requested = Path(destination).expanduser()
        if requested.exists() or requested.is_symlink():
            raise ValueError("Destination must be new; existing files were not changed.")
        root = requested.resolve()
        root.mkdir(parents=True)
    library_root, analysis_root = root / "library", root / "analysis"
    library_root.mkdir()
    analysis_root.mkdir()

    # 1. Register a reviewed function in a synthetic equivalent of ~/git/lib.
    module = library_root / "nb_utils_general.py"
    module.write_text(SOURCE_V1)
    library = ProjectBundle.create("Synthetic shared library", library_root)
    helper_details = dict(name="Required columns", language="Python",
                          purpose="Check required table columns", source=module,
                          function=FUNCTION_NAME, tags=["general", "columns"])
    source_v1 = library.register_helper(**helper_details, contract=CONTRACT_V1)
    library.save()

    # 2. Find, inspect, adopt and save an exact helper in a separate project.
    project = ProjectBundle.create("Unrelated synthetic analysis", analysis_root)
    project.status()  # One ordinary session-start metadata query.
    report = project.find_helpers("required columns", sources=[library_root])
    chosen = select_exact(report, library_root, source_v1)
    inspected = library.get_helper(chosen["ref"])
    assert inspected["descriptor"]["contract"] == CONTRACT_V1
    local_v1 = project.register_helper_from(chosen)
    input_path = analysis_root / "shop_table.json"
    input_path.write_text(json.dumps([{"item": "pencil", "price": 1.5}]))
    data_ref = project.register_data(input_path, "input", hash=True)
    project.save()  # Saves this example's approved helper and input batch.

    # 3. Verify and load the retained source and exact input, then execute ordinary Python.
    check_v1, snapshot_v1 = load_reviewed_snapshot(project, local_v1)
    verified_input = project.resolve_data(ref=data_ref, verify="sha256")
    rows = json.loads(verified_input.path.read_text())
    required = ["item", "price", "currency"]
    result_v1 = check_v1(rows, required)
    assert result_v1 == ["currency"]
    output_v1 = analysis_root / "missing_v1.json"
    output_v1.write_text(json.dumps(result_v1))
    analysis_v1 = project.register_analysis(
        "Check shop table v1", inputs=[data_ref], code=__file__,
        method="Required column presence", params={"required": required},
        helper_refs=[local_v1])
    result_ref_v1 = project.register_result(output_v1, analysis_v1, hash=True)
    project.save()
    original_hash = hashlib.sha256(output_v1.read_bytes()).hexdigest()
    original_source = snapshot_v1.read_bytes()

    # 4. With authority to edit this synthetic library, add optional strict behavior.
    module.write_text(SOURCE_V2)
    source_v2 = library.register_helper(
        **helper_details, contract=CONTRACT_V2, ref=source_v1,
        reason="Add optional strict mode while preserving default behavior")
    library.save()
    chosen_v2 = select_exact(project.find_helpers("required columns", sources=[library_root]),
                             library_root, source_v2)
    assert library.get_helper(chosen_v2["ref"])["descriptor"]["contract"] == CONTRACT_V2
    local_v2 = project.register_helper_from(chosen_v2)
    project.save()
    check_v2, _ = load_reviewed_snapshot(project, local_v2)
    result_v2 = check_v2(rows, required)
    assert result_v2 == result_v1 and check_v2(rows, ["item", "price"], strict=True) == []
    try:
        check_v2(rows, required, strict=True)
    except ValueError as error:
        strict_error = str(error)
    else:
        raise AssertionError("Strict mode should reject the missing column.")
    output_v2 = analysis_root / "missing_v2.json"
    output_v2.write_text(json.dumps(result_v2))
    analysis_v2 = project.register_analysis(
        "Check shop table v2", inputs=[data_ref], code=__file__,
        method="Required column presence", params={"required": required, "strict": False},
        helper_refs=[local_v2])
    result_ref_v2 = project.register_result(output_v2, analysis_v2, hash=True)
    project.save()

    # 5. Reopen and prove that old references, source bytes and output stayed unchanged.
    reopened = ProjectBundle.open(analysis_root)
    assert reopened.get_analysis(analysis_v1).details["bl_helper_refs"] == [local_v1]
    assert reopened.get_data(ref=result_ref_v1).scope["transformation_ref"] == analysis_v1
    assert reopened.get_data(ref=result_ref_v2).scope["transformation_ref"] == analysis_v2
    assert reopened.get_helper(local_v1)["foreign_refs"][0]["ref"] == source_v1
    assert reopened.get_helper(local_v1, verify="snapshot")["verification"]["status"] == "pass"
    assert snapshot_v1.read_bytes() == original_source
    assert hashlib.sha256(output_v1.read_bytes()).hexdigest() == original_hash
    summary = dict(package_version=__version__, library_root=str(library_root),
                   analysis_root=str(analysis_root), function=FUNCTION_NAME,
                   source_refs=[source_v1, source_v2], local_refs=[local_v1, local_v2],
                   analysis_refs=[analysis_v1, analysis_v2], result_refs=[result_ref_v1, result_ref_v2],
                   results=[result_v1, result_v2], strict_error=strict_error,
                   original_result_sha256=original_hash, old_pin_preserved=True)
    print(json.dumps(summary, sort_keys=True))
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", help="new synthetic workspace; default: new temporary folder")
    main(**vars(parser.parse_args()))
