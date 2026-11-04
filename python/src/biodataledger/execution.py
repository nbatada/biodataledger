"""Explicit, bounded native execution evidence; not a workflow engine or sandbox."""
import copy
from pathlib import Path
import re

from .core import BundleError, digest_bytes, fingerprint, require


KEY = "execution_receipt"
VERSION = "biodataledger-execution/1"
MAX_ITEMS = 100
MAX_CODE = 1024 * 1024


class ExecutionError(BundleError):
    """A terminal execution observation; ``receipt`` is detached metadata."""
    def __init__(self, message, receipt):
        super().__init__(message)
        self.receipt = copy.deepcopy(receipt)


def _bounded(value, limit=1024):
    raw = str(value).encode("utf-8", "replace")[:limit]
    return raw.decode("utf-8", "ignore")


def _unknown(ref, reason):
    return {"ref": copy.deepcopy(ref), "path": None, "identity": "unknown", "reason": reason}


def _receipt(project, source, run, entry_point, seeds, outputs):
    code = source["code"][0]
    return {
        "version": VERSION,
        "status": "started",
        "template_ref": project._ref(source),
        "run_ref": project._ref(run),
        "receipt_ref": project._ref(run),
        "started_at_utc": run["created_at"],
        "ended_at_utc": None,
        "entry_point": entry_point,
        "language": "python",
        "code": {"path": code["locator"]["value"], "digest": code["sha256"],
                 "snapshot_digest": code["sha256"], "snapshot": code["snapshot"]},
        "method": copy.deepcopy(source["method"]),
        "params": copy.deepcopy(source["params"]),
        "seeds": copy.deepcopy(seeds),
        "inputs": [_unknown(ref, "not_checked") for ref in source["inputs"] or []],
        "outputs": [dict(item, status="not_observed") for item in outputs],
        "phases": {"execution_started": False, "code_executed": False, "callback_invoked": False},
        "input_consumption": "unknown",
        "scientific_validity": "unknown",
        "downstream_consumption": "unknown",
        "error": None,
    }


def _valid_receipt(value):
    """Check the small receipt contract, without asserting its authenticity."""
    required = {"version", "status", "template_ref", "run_ref", "receipt_ref", "started_at_utc", "ended_at_utc",
                "entry_point", "language", "code", "method", "params", "seeds", "inputs", "outputs",
                "phases", "input_consumption", "scientific_validity", "downstream_consumption", "error"}
    if not isinstance(value, dict) or not required <= set(value) or value["version"] != VERSION:
        return False
    text = lambda item: isinstance(item, str) and bool(item)
    digest = lambda item: isinstance(item, str) and re.fullmatch(r"[0-9a-f]{64}", item) is not None
    ref = lambda item: (isinstance(item, dict) and set(item) == {"project_id", "id", "revision"}
                        and text(item["project_id"]) and text(item["id"])
                        and type(item["revision"]) is int and item["revision"] >= 1)
    status = value["status"]
    if (not isinstance(status, str) or status not in {"started", "succeeded", "failed", "blocked", "incomplete"}
            or value["language"] not in ("python", "r")
            or not all(ref(value[key]) for key in ("template_ref", "run_ref", "receipt_ref"))
            or not text(value["started_at_utc"]) or not text(value["entry_point"])
            or value["method"] is not None and not isinstance(value["method"], str)
            or value["params"] is not None and not isinstance(value["params"], dict)
            or value["seeds"] is not None and not isinstance(value["seeds"], dict)
            or not isinstance(value["inputs"], list) or len(value["inputs"]) > MAX_ITEMS
            or not isinstance(value["outputs"], list) or len(value["outputs"]) > MAX_ITEMS
            or value["error"] is not None and not isinstance(value["error"], str)):
        return False
    code, phases = value["code"], value["phases"]
    if not (isinstance(code, dict) and {"path", "digest", "snapshot_digest", "snapshot"} <= set(code)
            and text(code["path"]) and text(code["snapshot"]) and digest(code["digest"])
            and code["snapshot_digest"] == code["digest"]
            and code["snapshot"] == ".nb_project_bundle/code/" + code["digest"]
            and isinstance(phases, dict) and set(phases) == {"execution_started", "code_executed", "callback_invoked"}
            and all(type(item) is bool for item in phases.values())):
        return False
    for item in value["inputs"]:
        if (not isinstance(item, dict) or not ref(item.get("ref"))
                or item.get("identity") not in ("match", "unknown", "mismatch")
                or not text(item.get("reason"))
                or item.get("path") is not None and not text(item["path"])
                or item.get("identity") == "match" and (not text(item.get("path")) or item.get("reason") not in ("sha256_match", "digest_match"))):
            return False
    if any(value[field] != "unknown" for field in ("input_consumption", "scientific_validity", "downstream_consumption")):
        return False
    for item in value["outputs"]:
        if (not isinstance(item, dict) or item.get("kind") not in ("result", "figure")
                or item.get("status") not in ("not_observed", "observed", "missing", "unreadable", "registered", "registration_failed")
                or not text(item.get("path")) or item.get("kind") == "figure" and not text(item.get("type"))
                or "digest" in item and not digest(item["digest"])
                or "record_ref" in item and not ref(item["record_ref"])
                or item.get("status") == "registered" and (not digest(item.get("digest")) or not ref(item.get("record_ref")))):
            return False
    if phases["callback_invoked"] and not phases["code_executed"] or phases["code_executed"] and not phases["execution_started"]:
        return False
    if status == "started":
        return (value["ended_at_utc"] is None and value["error"] is None and not any(phases.values())
                and all(item["identity"] == "unknown" for item in value["inputs"])
                and all(item["status"] == "not_observed" for item in value["outputs"]))
    if not text(value["ended_at_utc"]):
        return False
    if status == "blocked":
        return not any(phases.values()) and text(value["error"]) and all(item["status"] == "not_observed" for item in value["outputs"])
    if status == "succeeded":
        return all(phases.values()) and value["error"] is None and all(item["status"] == "registered" for item in value["outputs"])
    if status == "incomplete":
        return all(phases.values()) and text(value["error"]) and any(item["status"] != "registered" for item in value["outputs"])
    return phases["execution_started"] and text(value["error"])


def _bound_receipt(project, rec, receipt):
    """Check exact recorded links only; this never reads scientific payloads."""
    expected = project._ref(rec)
    if (receipt["receipt_ref"] != expected or receipt["run_ref"] != dict(expected, revision=1)
            or receipt["status"] == "started" and rec["revision"] != 1
            or receipt["status"] != "started" and rec["revision"] != 2):
        return False
    template = project._record(receipt["template_ref"], "analysis")
    started = project._record(receipt["run_ref"], "analysis")
    if any(rec.get(key) != template.get(key) or rec.get(key) != started.get(key)
           for key in ("inputs", "code", "method", "params", "design", "input_mode")):
        return False
    if (len(rec["code"]) != 1 or receipt["code"]["digest"] != rec["code"][0]["sha256"]
            or receipt["code"]["snapshot"] != rec["code"][0]["snapshot"]
            or receipt["code"]["path"] != rec["code"][0]["locator"]["value"]
            or receipt["method"] != rec["method"] or receipt["params"] != rec["params"]
            or [item["ref"] for item in receipt["inputs"]] != (rec["inputs"] or [])):
        return False
    for item in receipt["inputs"]:
        source = project._record(item["ref"], "data")
        if item["identity"] == "match" and source["sha256"] is None:
            return False
    for item in receipt["outputs"]:
        if item["status"] != "registered":
            continue
        output = project._record(item["record_ref"], "data" if item["kind"] == "result" else "figure")
        producer = output.get("scope", {}).get("transformation_ref") if item["kind"] == "result" else output["analysis"]
        if (output["sha256"] != item["digest"] or producer != receipt["run_ref"]
                or item["kind"] == "figure" and output["type"] != item["type"]):
            return False
    return True


def _outputs(project, outputs):
    require(isinstance(outputs, list) and len(outputs) <= MAX_ITEMS, "outputs must be a list of at most 100 items")
    checked, paths = [], set()
    for item in outputs:
        require(isinstance(item, dict) and set(item) <= {"path", "kind", "type"} and {"path", "kind"} <= set(item),
                "output must contain path and kind")
        require(item["kind"] in ("result", "figure"), "output kind must be result or figure")
        require(item["kind"] != "figure" or isinstance(item.get("type"), str) and item["type"], "figure output requires type")
        require(item["kind"] != "result" or "type" not in item, "result output cannot have type")
        require(isinstance(item["path"], str) and item["path"] and not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", item["path"]), "output path required")
        path = Path(item["path"]).expanduser()
        relative = not path.is_absolute()
        if relative:
            path = project.root / path
        require((not relative or project.root in (path.resolve(), *path.resolve().parents)) and path.parent.is_dir() and not path.exists() and not path.is_symlink(),
                "output must be a new project-root or absolute path under an existing directory")
        resolved = path.resolve()
        require(str(resolved) not in paths, "duplicate output path")
        registry = (project.root / ".nb_project_bundle").resolve()
        require(registry not in (resolved, *resolved.parents), "registry-internal output prohibited")
        paths.add(str(resolved))
        checked.append({"path": str(resolved), "kind": item["kind"], **({"type": item["type"]} if "type" in item else {})})
    return checked


def _snapshot(project, code, verify_code):
    require(code["snapshot"] is not None, "execution requires a captured code snapshot")
    snapshot = project._internal(code["snapshot"])
    require(snapshot.is_file() and snapshot.stat().st_size <= MAX_CODE, "captured code snapshot unavailable or oversized")
    raw = snapshot.read_bytes()
    require(len(raw) <= MAX_CODE and digest_bytes(raw) == code["sha256"], "captured code snapshot digest mismatch")
    if verify_code:
        current = project._resolve(code["locator"])
        require(current is not None and current.is_file() and fingerprint(current) == code["sha256"], "registered code changed or unavailable")
    return raw


def _input_paths(project, source, verify):
    refs = source["inputs"] or []
    require(len(refs) <= MAX_ITEMS, "analysis has more than 100 inputs")
    result, paths, failed = [], [], False
    for ref in refs:
        rec = project._record(ref, "data")
        if verify:
            try:
                path, _ = project._verify_file(rec)
                entry = {"ref": copy.deepcopy(ref), "path": str(path), "identity": "match", "reason": "sha256_match"}
            except BundleError as exc:
                message = str(exc)
                identity = "mismatch" if message.startswith(("SIZE_MISMATCH", "FILE_CHANGED", "DIGEST_MISMATCH")) else "unknown"
                entry = _unknown(ref, _bounded(message))
                entry["identity"] = identity
                failed = True
        else:
            path = project._resolve(rec["locator"])
            if path is None or not path.is_file():
                entry = _unknown(ref, "local_path_unavailable")
                failed = True
            else:
                entry = {"ref": copy.deepcopy(ref), "path": str(path), "identity": "unknown", "reason": "verification_not_requested"}
        result.append(entry)
        paths.append(entry["path"])
    return result, paths, failed


def _capture_outputs(project, run_ref, outputs):
    observed, incomplete = [], False
    for item in outputs:
        entry = copy.deepcopy(item)
        path = Path(item["path"])
        if not path.exists() or not path.is_file():
            entry["status"] = "missing"
            observed.append(entry)
            incomplete = True
            continue
        try:
            entry["digest"] = fingerprint(path)
        except OSError:
            entry["status"] = "unreadable"
            observed.append(entry)
            incomplete = True
            continue
        entry["status"] = "observed"
        try:
            if item["kind"] == "result":
                entry["record_ref"] = project.register_result(str(path), run_ref, hash=True)
            else:
                entry["record_ref"] = project.register_figure(str(path), item["type"], analysis=run_ref)
            require(project._record(entry["record_ref"])["sha256"] == entry["digest"], "output changed while registering")
            entry["status"] = "registered"
        except (BundleError, OSError) as exc:
            entry["status"] = "registration_failed"
            entry["error"] = _bounded(exc)
            incomplete = True
        observed.append(entry)
    return observed, incomplete


def _terminal(project, run_ref, receipt, status, error=None):
    run = copy.deepcopy(project._record(run_ref, "analysis"))
    receipt = copy.deepcopy(receipt)
    receipt["status"] = status
    receipt["ended_at_utc"] = project._new("analysis", "terminal")["created_at"]
    receipt["error"] = (_bounded(error) or type(error).__name__) if error is not None else None
    run["revision"] += 1
    run["created_at"] = receipt["ended_at_utc"]
    receipt["receipt_ref"] = project._ref(run)
    run["details"][KEY] = receipt
    project._stage(run, "run_analysis_terminal", context_check=False)
    persistence = project.save_and_confirm()
    receipt["persistence"] = persistence
    return receipt


def run_analysis(project, analysis_ref, entry_point, outputs=[], seeds=None, verify_inputs=True, verify_code=True):
    """Execute exactly one captured Python callback and retain only scoped observations."""
    source = project._record(analysis_ref, "analysis")
    require(isinstance(entry_point, str) and re.fullmatch(r"[A-Za-z_]\w*", entry_point), "entry_point must be a Python function name")
    require(type(verify_inputs) is bool and type(verify_code) is bool, "verification flags must be boolean")
    require(seeds is None or isinstance(seeds, dict), "seeds must be a JSON object or null")
    require(len(source["code"]) == 1 and source["code"][0]["snapshot"] is not None,
            "execution requires exactly one snapshotted code file")
    require(len(source["inputs"] or []) <= MAX_ITEMS, "analysis has more than 100 inputs")
    checked_outputs = _outputs(project, outputs)

    run = project._new("analysis", source["name"] + " execution")
    run.update(inputs=copy.deepcopy(source["inputs"]), code=copy.deepcopy(source["code"]), method=copy.deepcopy(source["method"]),
               params=copy.deepcopy(source["params"]), details=copy.deepcopy(source["details"]))
    for field in ("design", "input_mode"):
        if field in source:
            run[field] = copy.deepcopy(source[field])
    receipt = _receipt(project, source, run, entry_point, seeds, checked_outputs)
    run["details"].pop(KEY, None)
    run["details"][KEY] = receipt
    run_ref = project._stage(run, "run_analysis_started", context_check=False)
    project.save_and_confirm()  # The durable start boundary includes all previously staged edits.

    try:
        raw = _snapshot(project, source["code"][0], verify_code)
        receipt["inputs"], input_paths, bad_inputs = _input_paths(project, source, verify_inputs)
    except (BundleError, OSError) as exc:
        terminal = _terminal(project, run_ref, receipt, "blocked", exc)
        raise ExecutionError("execution blocked", terminal) from exc
    if bad_inputs:
        terminal = _terminal(project, run_ref, receipt, "blocked", "required input verification or local resolution failed")
        raise ExecutionError("execution blocked", terminal)
    try:
        namespace = {"__name__": "__biodataledger_execution__"}
        receipt["phases"]["execution_started"] = True
        compiled = compile(raw, source["code"][0]["locator"]["value"], "exec")
        receipt["phases"]["code_executed"] = True
        exec(compiled, namespace, namespace)
        callback = namespace.get(entry_point)
        require(callable(callback), "entry_point not defined by captured code")
        receipt["phases"]["callback_invoked"] = True
        callback(inputs=input_paths, params=copy.deepcopy(source["params"]), seeds=copy.deepcopy(seeds),
                 outputs=[item["path"] for item in checked_outputs])
    except BaseException as exc:
        receipt["outputs"], _ = _capture_outputs(project, run_ref, checked_outputs)
        terminal = _terminal(project, run_ref, receipt, "failed", exc)
        raise ExecutionError("execution failed: " + _bounded(exc), terminal) from exc

    observed, incomplete = _capture_outputs(project, run_ref, checked_outputs)
    receipt["outputs"] = observed
    if incomplete:
        terminal = _terminal(project, run_ref, receipt, "incomplete", "required output missing, unreadable, or unregistered")
        raise ExecutionError("execution incomplete", terminal)
    return _terminal(project, run_ref, receipt, "succeeded")


def get_execution(project, ref):
    rec = project._record(ref, "analysis")
    receipt = rec["details"].get(KEY)
    try:
        valid = _valid_receipt(receipt) and _bound_receipt(project, rec, receipt)
    except (BundleError, KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        return {"status": "unknown", "receipt_ref": project._ref(rec), "reason": "absent_or_malformed_execution_receipt"}
    result = copy.deepcopy(receipt)
    if project.state["imported"]:
        result["authenticity"] = "untrusted_imported_claim"
    return result


def execution_summary(project, ref):
    receipt = get_execution(project, ref)
    text = "%s: %s" % (receipt["receipt_ref"]["id"] + "@" + str(receipt["receipt_ref"]["revision"]), receipt["status"])
    if receipt["status"] != "unknown":
        checked = sum(item["identity"] == "match" for item in receipt["inputs"])
        text += ("; entry point " + receipt["entry_point"] + "; inputs matched " + str(checked) + "/" + str(len(receipt["inputs"]))
                 + "; code " + receipt["code"]["digest"][:12] + "; callback " + str(receipt["phases"]["callback_invoked"]).lower()
                 + "; outputs captured " + str(sum(item["status"] == "registered" for item in receipt["outputs"])) + "/" + str(len(receipt["outputs"])) + "; input use/science: unknown")
        if receipt["error"]:
            text += "; error " + receipt["error"]
    return _bounded(text, 4096)
