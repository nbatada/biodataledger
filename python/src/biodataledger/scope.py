"""Typed declarations and recorded evidence; no scientific object loading."""
import copy
from datetime import datetime
import re

FIELDS = set("observation_unit condition_values selection assay layer assignment_inclusion sample_manifest_ref transformation_ref evidence membership_evidence".split())
ARRAY_FIELDS = {"condition_values", "assignment_inclusion"}
EXPECTED_FIELDS = ARRAY_FIELDS | {"observation_unit", "assay", "layer"}


def text(value):
    return isinstance(value, str) and bool(value.strip())


def string_array(value):
    return isinstance(value, list) and bool(value) and all(text(x) for x in value) and len(set(value)) == len(value)


def ref_shape(value, require):
    require(isinstance(value, dict) and set(value) == {"project_id", "id", "revision"}, "invalid scope reference")
    require(isinstance(value["project_id"], str) and isinstance(value["id"], str) and type(value["revision"]) is int and value["revision"] > 0, "invalid scope reference")


def normalize_scope(scope, require):
    require(isinstance(scope, dict) and set(scope) <= FIELDS, "invalid scope fields")
    out = {key: copy.deepcopy(scope.get(key)) for key in sorted(FIELDS)}
    for key in ("observation_unit", "selection", "assay", "layer"):
        require(out[key] is None or text(out[key]), "invalid scope text: " + key)
    for key in ARRAY_FIELDS:
        require(out[key] is None or string_array(out[key]), "invalid scope values: " + key)
    for key in ("sample_manifest_ref", "transformation_ref"):
        if out[key] is not None:
            ref_shape(out[key], require)
    if out["evidence"] is None:
        out["evidence"] = {"basis": "unknown", "source_refs": []}
    evidence = out["evidence"]
    require(isinstance(evidence, dict) and set(evidence) == {"basis", "source_refs"}, "invalid scope evidence")
    require(evidence["basis"] in ("unknown", "declared", "inferred") and isinstance(evidence["source_refs"], list), "invalid scope evidence")
    for ref in evidence["source_refs"]:
        ref_shape(ref, require)
    if out["membership_evidence"] is None:
        out["membership_evidence"] = {"status": "unknown", "report_ref": None}
    evidence = out["membership_evidence"]
    require(isinstance(evidence, dict) and set(evidence) == {"status", "report_ref"}, "invalid membership evidence")
    require(evidence["status"] in ("unknown", "declared", "inferred", "verification_recorded"), "invalid membership evidence")
    require((evidence["status"] == "verification_recorded") == (evidence["report_ref"] is not None), "membership report required only for recorded verification")
    if evidence["report_ref"] is not None:
        ref_shape(evidence["report_ref"], require)
    return out


def validate_expected(expected, require):
    require(isinstance(expected, dict) and bool(expected) and set(expected) <= EXPECTED_FIELDS, "invalid expected scope fields")
    for key, value in expected.items():
        require(string_array(value) if key in ARRAY_FIELDS else text(value), "invalid expected scope value")


def same_value(key, left, right):
    return set(left) == set(right) if key in ARRAY_FIELDS else left == right


def validate_report(report, require):
    fields = set("report_version subject_sha256 membership_ref membership_sha256 key_columns key_namespace comparison result checked_at checker counts".split())
    require(isinstance(report, dict) and fields <= set(report) <= fields | {"observed_scope"}, "invalid membership report fields")
    require(report["report_version"] == "biodataledger-membership-check/1", "unsupported membership report")
    for key in ("subject_sha256", "membership_sha256"):
        require(isinstance(report[key], str) and re.fullmatch(r"[0-9a-f]{64}", report[key]), "invalid membership digest")
    ref_shape(report["membership_ref"], require)
    require(string_array(report["key_columns"]) and text(report["key_namespace"]), "invalid membership key definition")
    require(report["comparison"] in ("ordered_keys", "set_keys") and report["result"] in ("match", "mismatch", "incomplete"), "invalid membership comparison")
    try:
        stamp = report["checked_at"]
        valid_time = isinstance(stamp, str) and datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").strftime("%Y-%m-%dT%H:%M:%SZ") == stamp
    except (ValueError, TypeError):
        valid_time = False
    require(valid_time, "invalid membership timestamp")
    checker = report["checker"]
    require(isinstance(checker, dict) and set(checker) == {"method", "origin", "analysis_ref"}, "invalid membership checker")
    require(text(checker["method"]) and checker["origin"] in ("native_check", "manual_check"), "invalid membership checker")
    if checker["analysis_ref"] is not None:
        ref_shape(checker["analysis_ref"], require)
    counts = report["counts"]
    names = set("subject_rows membership_rows subject_duplicate_keys membership_duplicate_keys missing_keys extra_keys".split())
    require(isinstance(counts, dict) and set(counts) == names and all(type(v) is int and 0 <= v <= 2**53 - 1 for v in counts.values()), "invalid membership counts")
    if report["result"] == "match":
        require(counts["subject_rows"] == counts["membership_rows"] and all(counts[k] == 0 for k in names - {"subject_rows", "membership_rows"}), "inconsistent membership match")
    if "observed_scope" in report:
        validate_expected(report["observed_scope"], require)
