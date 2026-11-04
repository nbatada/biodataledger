"""Small experimental-design values and checks; never reads scientific files."""
import math
from collections.abc import Mapping

FIELDS = set("condition levels selected_levels reference_level replicate selection_reason evidence_source metadata_check context".split())
REPORT_FIELDS = set("valid row_count observed_levels missing_levels missing_selected_levels missing_columns unexpected_levels missing_condition_values missing_replicate_values".split())


def validate_design(design, require):
    require(isinstance(design, dict) and set(design) == FIELDS, "invalid experimental design fields")
    for key in ("condition", "reference_level", "replicate"):
        value = design[key]
        require((key != "condition" and value is None) or isinstance(value, str) and bool(value.strip()), "invalid design " + key)
    for key in ("levels", "selected_levels"):
        values = design[key]
        require(isinstance(values, list) and bool(values) and all(isinstance(x, str) and x.strip() for x in values), key + " must contain nonempty strings")
        require(len(set(values)) == len(values), "duplicate " + key)
    require(set(design["selected_levels"]) <= set(design["levels"]), "selected_levels must be a subset of levels")
    require(design["reference_level"] is None or design["reference_level"] in design["selected_levels"], "reference_level must belong to selected_levels")
    require(design["selection_reason"] is None or isinstance(design["selection_reason"], str), "invalid selection_reason")
    require(isinstance(design["context"], list), "design context must be an array of exact references")
    require(design["evidence_source"] in ("scientist-declared", "metadata-verified"), "invalid design evidence source")
    report = design["metadata_check"]
    if design["evidence_source"] == "scientist-declared":
        require(report is None, "declared design must not claim metadata verification")
    else:
        require(isinstance(report, dict) and set(report) == REPORT_FIELDS, "metadata verification report required")
        require(report["valid"] is True and type(report["row_count"]) is int and report["row_count"] > 0, "invalid metadata verification")
        for key in ("observed_levels", "missing_levels", "missing_selected_levels", "missing_columns", "unexpected_levels"):
            require(isinstance(report[key], list) and all(isinstance(x, str) for x in report[key]), "invalid metadata report levels")
            require(len(set(report[key])) == len(report[key]), "duplicate metadata report values")
        observed = report["observed_levels"]
        require(bool(observed) and set(observed) <= set(design["levels"]), "invalid verified observed levels")
        require(report["missing_levels"] == [x for x in design["levels"] if x not in observed], "invalid missing levels report")
        require(report["missing_selected_levels"] == [x for x in design["selected_levels"] if x not in observed], "invalid missing selected levels report")
        require(not report["missing_columns"] and not report["unexpected_levels"], "invalid verified columns or levels")
        require(type(report["missing_condition_values"]) is int and report["missing_condition_values"] == 0 and type(report["missing_replicate_values"]) is int and report["missing_replicate_values"] == 0, "verified metadata has missing values")


def check_metadata(design, metadata, require):
    """Inspect supplied column sequences, not filenames or expression matrices."""
    require(isinstance(metadata, Mapping), "metadata must be a mapping of column names to sequences")
    columns = [design["condition"]] + ([design["replicate"]] if design["replicate"] else [])
    missing = list(dict.fromkeys(x for x in columns if x not in metadata))
    report = {"valid": False, "row_count": 0, "observed_levels": [], "missing_levels": list(design["levels"]),
              "missing_selected_levels": list(design["selected_levels"]), "missing_columns": missing,
              "unexpected_levels": [], "missing_condition_values": 0, "missing_replicate_values": 0}
    if missing:
        return report
    values = {}
    for key in columns:
        column = metadata[key]
        require(not isinstance(column, (str, bytes, Mapping)) and hasattr(column, "__len__") and hasattr(column, "__iter__"), "metadata columns must be sequences")
        values[key] = list(column)
    condition = values[design["condition"]]
    replicate = values.get(design["replicate"], [])
    require(design["replicate"] is None or len(replicate) == len(condition), "metadata columns have unequal lengths")
    def missing_value(x):
        return x is None or isinstance(x, float) and not math.isfinite(x) or isinstance(x, str) and not x.strip()
    for value in condition:
        require(missing_value(value) or isinstance(value, str), "condition values must be strings or missing")
        if missing_value(value):
            report["missing_condition_values"] += 1
        elif value not in report["observed_levels"]:
            report["observed_levels"].append(value)
    for value in replicate:
        require(missing_value(value) or type(value) in (str, int, float), "replicate values must be strings, numbers or missing")
        report["missing_replicate_values"] += int(missing_value(value))
    observed = report["observed_levels"]
    report.update(row_count=len(condition), missing_levels=[x for x in design["levels"] if x not in observed],
                  missing_selected_levels=[x for x in design["selected_levels"] if x not in observed],
                  unexpected_levels=[x for x in observed if x not in design["levels"]])
    report["valid"] = bool(condition) and not report["unexpected_levels"] and not report["missing_condition_values"] and not report["missing_replicate_values"]
    return report


def compact_design(design):
    if design is None:
        return None
    truncated = len(design["selected_levels"]) > 5
    def clip(value):
        nonlocal truncated
        if value is None:
            return None
        truncated = truncated or len(value) > 64
        return value[:64]
    result = {"condition": clip(design["condition"]), "selected_levels": [clip(x) for x in design["selected_levels"][:5]],
              "reference_level": clip(design["reference_level"]), "replicate": clip(design["replicate"]),
              "revision": design["ref"]["revision"]}
    result["truncated"] = truncated
    return result


def summary_text(project, design, counts):
    def display(value):
        if value is None:
            return "unknown"
        if isinstance(value, list):
            value = ", ".join(value[:8]) + (", ..." if len(value) > 8 else "") if value else "none"
        value = str(value).replace("\n", " ").replace("\r", " ").replace("\t", " ")
        return value[:160] + ("..." if len(value) > 160 else "")
    lines = ["BioDataLedger: " + display(project["name"]), "Purpose:", "  " + display(project["purpose"]), "Experimental design:"]
    if design is None:
        lines.append("  not configured")
    else:
        for label, value in (("Condition", design["condition"]), ("Levels", design["levels"]),
                             ("Selected levels", design["selected_levels"]), ("Reference", design["reference_level"]),
                             ("Replicate", design["replicate"]), ("Excluded", [x for x in design["levels"] if x not in design["selected_levels"]]),
                             ("Reason", design["selection_reason"]), ("Design revision", design["ref"]["revision"])):
            lines.append("  " + (label + ":").ljust(18) + display(value))
    lines.extend(["Project:", "  Data/artifact records: %d" % counts["data"],
                  "  Analysis records:      %d" % counts["analysis"], "  Figures:               %d" % counts["figure"]])
    return "\n".join(lines)
