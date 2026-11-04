"""Versioned intended analysis protocols and bounded receipt comparison."""
import copy
from datetime import datetime
import re

from .core import BundleError, canonical, require

KEY = "analysis_protocol"
VERSION = "biodataledger-protocol/1"
MAX_STEPS = 100
MAX_BYTES = 64 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024


def _metadata_size(record):
    size = len(canonical(record))
    require(size <= MAX_BYTES, "protocol analysis exceeds 64 KiB metadata limit")
    return size


def _same(left, right):
    """JSON structural equality: booleans are distinct; finite numeric values compare numerically."""
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is type(right) and left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return left == right
    if isinstance(left, dict) and isinstance(right, dict):
        return set(left) == set(right) and all(_same(left[key], right[key]) for key in left)
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(_same(a, b) for a, b in zip(left, right))
    return type(left) is type(right) and left == right


def _timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return None


def _output(value):
    require(isinstance(value, dict) and value.get("kind") in ("result", "figure"), "invalid required output")
    allowed = {"kind"} if value["kind"] == "result" else {"kind", "type"}
    require(set(value) == allowed and (value["kind"] == "result" or isinstance(value["type"], str) and value["type"]),
            "invalid required output")
    return copy.deepcopy(value)


def _descriptor(project, steps, reason):
    require(isinstance(reason, str) and reason.strip(), "protocol reason required")
    require(isinstance(steps, list) and 0 < len(steps) <= MAX_STEPS, "steps must be an array of 1 to 100 items")
    normalized, ids, expanded_size = [], set(), 0
    for step in steps:
        require(isinstance(step, dict) and {"step_id", "analysis_ref", "required_outputs"} <= set(step) <= {"step_id", "analysis_ref", "data_dependent_params", "required_outputs", "seeds", "environment_ref"},
                "invalid protocol step")
        step_id = step["step_id"]
        require(isinstance(step_id, str) and step_id.strip() and step_id not in ids, "protocol step_id must be unique")
        ids.add(step_id)
        analysis = project._record(step["analysis_ref"], "analysis")
        expanded_size += _metadata_size(analysis)
        require(expanded_size <= MAX_EXPANDED_BYTES, "protocol expanded analyses exceed 1 MiB metadata limit")
        require(analysis["inputs"] is not None and isinstance(analysis["method"], str) and analysis["method"]
                and isinstance(analysis["params"], dict) and analysis["code"],
                "protocol analysis must declare inputs, method, params and code")
        dynamic = step.get("data_dependent_params", [])
        require(isinstance(dynamic, list) and all(isinstance(x, str) and x for x in dynamic) and len(dynamic) == len(set(dynamic)),
                "data_dependent_params must be unique parameter names")
        require(isinstance(analysis["params"], dict) or not dynamic, "data-dependent parameters require declared template params")
        require(all(x in (analysis["params"] or {}) for x in dynamic), "data-dependent parameter missing from pinned analysis")
        outputs = step["required_outputs"]
        require(isinstance(outputs, list) and len(outputs) <= MAX_STEPS, "required_outputs must be an array of at most 100 items")
        seeds = step.get("seeds")
        require(seeds is None or isinstance(seeds, dict), "protocol seeds must be object or null")
        environment = step.get("environment_ref")
        if environment is not None:
            environment = project._ref(project._record(environment))
        normalized.append({"step_id": step_id, "analysis_ref": project._ref(analysis),
                           "data_dependent_params": list(dynamic), "required_outputs": [_output(x) for x in outputs],
                           "seeds": copy.deepcopy(seeds), "environment_ref": environment})
    value = {"version": VERSION, "reason": reason, "targets": [copy.deepcopy(x["analysis_ref"]) for x in normalized], "steps": normalized}
    require(len(canonical(value)) <= MAX_BYTES, "protocol exceeds 64 KiB metadata limit")
    return value


def _read(project, rec):
    value = rec["details"].get(KEY)
    if not isinstance(value, dict) or value.get("version") != VERSION:
        return None, "unsupported_analysis_protocol"
    try:
        if (set(value) != {"version", "reason", "targets", "steps"}
                or "scientific_decision" in rec["details"]
                or not _same(value.get("targets"), rec["details"].get("targets"))
                or value.get("reason") != rec["details"].get("reason")):
            raise BundleError("protocol fields")
        normalized = _descriptor(project, value["steps"], value["reason"])
        require(_same(normalized, value) and _same(value["targets"], [x["analysis_ref"] for x in value["steps"]]), "protocol is not canonical")
        return normalized, None
    except (BundleError, KeyError, TypeError):
        return None, "malformed_analysis_protocol"


def register_protocol(project, name, steps, reason, ref=None):
    require(isinstance(name, str) and name.strip(), "protocol name required")
    descriptor = _descriptor(project, steps, reason)
    if ref is None:
        rec = project._new("decision", name)
    else:
        old = project._record(ref, "decision")
        require(old["revision"] == project._latest_index[old["id"]]["revision"], "protocol revision must be current")
        require("scientific_decision" not in old["details"], "cannot convert scientific decision to analysis protocol")
        prior, issue = _read(project, old)
        require(prior is not None and issue is None, "cannot revise unsupported or malformed protocol")
        rec = copy.deepcopy(old)
        rec["revision"] += 1
        from .core import now
        rec["created_at"] = now()
    rec["name"] = name
    rec["details"] = {"reason": reason, "targets": copy.deepcopy(descriptor["targets"]), "approval": "not_authenticated", KEY: descriptor}
    return project._stage(rec, "register_protocol", reason)


def get_protocol(project, ref):
    rec = project._record(ref, "decision")
    protocol, issue = _read(project, rec)
    unknown = [] if issue is None else [issue]
    if project.state["imported"]:
        unknown.append("untrusted_imported_claim")
    return {"ref": project._ref(rec), "name": rec["name"], "record_status": rec["status"], "protocol": copy.deepcopy(protocol),
            "unknown": unknown, "imported_claim": "untrusted_imported_claim" if project.state["imported"] else None}


def _approval(project, approval_ref, protocol_ref):
    if approval_ref is None:
        return {"status": "not_supplied"}
    try:
        view = project.get_decision(approval_ref)
        scientific = view["scientific"]
        if project.state["imported"] or scientific is None or scientific["scientific_status"] != "approved":
            return {"status": "unknown", "reason": "approval_not_approved_or_malformed"}
        subjects = [item["ref"] for item in scientific["subjects"]]
        return {"status": "match" if subjects == [protocol_ref] else "mismatch", "ref": copy.deepcopy(view["ref"])}
    except BundleError:
        return {"status": "unknown", "reason": "approval_reference_unavailable"}


def _compare_step(project, expected, selected, receipt):
    result = {"step_id": expected["step_id"], "expected_analysis_ref": copy.deepcopy(expected["analysis_ref"]),
              "selected_analysis_ref": copy.deepcopy(selected["analysis_ref"]), "mismatches": [], "unknown": [],
              "data_dependent_observations": {}}
    result["receipt_status"] = receipt["status"]
    if receipt["status"] == "unknown" or project.state["imported"]:
        result["unknown"].append("execution_receipt")
        return result
    result["receipt_template_ref"] = copy.deepcopy(receipt.get("template_ref"))
    if receipt["status"] != "succeeded":
        result["mismatches"].append("execution_status." + receipt["status"])
    observed = project._record(selected["analysis_ref"], "analysis")
    template = project._record(expected["analysis_ref"], "analysis")
    for key in ("inputs", "method", "code", "design", "input_mode"):
        if not _same(observed.get(key), template.get(key)):
            result["mismatches"].append(key)
    expected_params, observed_params = template.get("params"), observed.get("params")
    if expected_params is None or observed_params is None:
        if not _same(expected_params, observed_params):
            result["mismatches"].append("params")
    else:
        for key in sorted(set(expected_params) | set(observed_params)):
            if key in expected["data_dependent_params"]:
                if key not in observed_params:
                    result["unknown"].append("data_dependent_param." + key)
                else:
                    result["data_dependent_observations"][key] = copy.deepcopy(observed_params[key])
            elif (key in expected_params) != (key in observed_params) or not _same(expected_params.get(key), observed_params.get(key)):
                result["mismatches"].append("params." + key)
    if expected["seeds"] is None:
        result["unknown"].append("seeds")
    elif not _same(receipt.get("seeds"), expected["seeds"]):
        result["mismatches"].append("seeds")
    got = [{k: item[k] for k in ("kind", "type") if k in item} for item in receipt.get("outputs", []) if item.get("status") == "registered"]
    if not _same(got, expected["required_outputs"]):
        result["mismatches"].append("required_outputs")
    if any(item.get("identity") != "match" for item in receipt.get("inputs", [])):
        result["unknown"].append("input_identity")
    result["unknown"].extend(["environment", "input_consumption", "scientific_validity", "actual_parameter_use"])
    return result


def compare_protocol(project, ref, executions, approval_ref=None):
    rec = project._record(ref, "decision")
    protocol, issue = _read(project, rec)
    require(protocol is not None, "protocol unavailable: " + (issue or "unknown"))
    require(isinstance(executions, list) and len(executions) <= MAX_STEPS, "executions must be an array of at most 100 items")
    selected, ids, expanded_size = [], set(), 0
    for item in executions:
        require(isinstance(item, dict) and set(item) == {"step_id", "analysis_ref"} and isinstance(item["step_id"], str) and item["step_id"], "invalid execution selection")
        require(item["step_id"] not in ids, "duplicate execution step_id")
        ids.add(item["step_id"])
        analysis = project._record(item["analysis_ref"], "analysis")
        expanded_size += _metadata_size(analysis)
        require(expanded_size <= MAX_EXPANDED_BYTES, "selected analyses exceed 1 MiB metadata limit")
        selected.append({"step_id": item["step_id"], "analysis_ref": project._ref(analysis)})
    expected_ids = [item["step_id"] for item in protocol["steps"]]
    selected_ids = [item["step_id"] for item in selected]
    steps, by_id = [], {item["step_id"]: item for item in selected}
    receipts = {item["step_id"]: project.get_execution(item["analysis_ref"]) for item in selected}
    for expected in protocol["steps"]:
        if expected["step_id"] not in by_id:
            steps.append({"step_id": expected["step_id"], "expected_analysis_ref": copy.deepcopy(expected["analysis_ref"]), "selected_analysis_ref": None, "mismatches": ["missing_step"], "unknown": []})
        else:
            steps.append(_compare_step(project, expected, by_id[expected["step_id"]], receipts[expected["step_id"]]))
    extras = [item["step_id"] for item in selected if item["step_id"] not in expected_ids]
    order = "match" if selected_ids == expected_ids else "mismatch"
    times = []
    for item in selected:
        receipt = receipts[item["step_id"]]
        start, end = _timestamp(receipt.get("started_at_utc")), _timestamp(receipt.get("ended_at_utc"))
        times.append((start, end))
    observed_order = "unknown"
    if (not project.state["imported"] and len(times) > 1
            and all(receipt.get("status") == "succeeded" for receipt in receipts.values())
            and all(a and b and a < b for a, b in times)):
        if all(times[i][1] < times[i + 1][0] for i in range(len(times) - 1)):
            observed_order = "strict_nonoverlap_in_submitted_order"
        elif any(times[i][0] > times[i + 1][1] for i in range(len(times) - 1)):
            observed_order = "different_from_submitted_order"
    report = {"report_version": VERSION, "protocol_ref": project._ref(rec), "registry_revision": project.state["state_revision"], "unsaved": project.unsaved,
            "imported_claim": "untrusted_imported_claim" if project.state["imported"] else None,
            "approval": _approval(project, approval_ref, project._ref(rec)), "submitted_order": selected_ids, "expected_order": expected_ids,
            "order": order, "observed_order": observed_order, "extra_steps": extras, "steps": steps,
            "coverage": {"protocol": "intended_declared", "execution": "selected_receipts_only", "environment": "unknown", "scientific_validity": "unknown", "input_consumption": "unknown"}}
    require(len(canonical(report)) <= MAX_BYTES, "protocol comparison exceeds 64 KiB report limit")
    return report
