"""Native, explicit project records; scientific computation stays with the caller."""
import copy
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import socket
import sys
import tempfile
from types import SimpleNamespace
from urllib.parse import urlsplit
import uuid
from collections import defaultdict
from datetime import datetime, timezone

from .design import validate_design, check_metadata, compact_design, summary_text

VERSION = "0.1.0"
DESIGN_VERSION = "0.2.0"
SCOPE_VERSION = "0.3.0"
STATE_PATH = ".nb_project_bundle/project.json"
MAX_JSON = 20 * 1024 * 1024
PREFIXES = {"data": "DATA", "analysis": "ANA", "figure": "FIG", "decision": "DEC", "design": "DES"}
RECORD_KEYS = set("kind id revision name created_at locator role type sha256 size inputs analysis code method params details status foreign_refs".split())
STATE_KEYS = set("schema_version project state_revision last_transaction records current bindings history imported".split())
PROJECT_KEYS = set("id name purpose raw_dir metadata next_task questions authorities".split())


class BundleError(ValueError):
    """A rejected operation; caller edits and source files are preserved."""


def require(condition, message):
    if not condition:
        raise BundleError(message)


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fingerprint(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def parse_json(raw):
    require(len(raw) <= MAX_JSON, "JSON exceeds 20 MiB limit")
    try:
        value = json.loads(raw, object_pairs_hook=unique_object,
                           parse_constant=lambda x: (_ for _ in ()).throw(BundleError("non-finite JSON number")))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BundleError("malformed JSON: " + str(exc)) from exc
    validate_values(value)
    return value


def validate_values(value):
    if isinstance(value, dict):
        require(all(isinstance(k, str) for k in value), "object keys must be strings")
        for child in value.values():
            validate_values(child)
    elif isinstance(value, list):
        for child in value:
            validate_values(child)
    elif isinstance(value, bool) or value is None or isinstance(value, str):
        return
    elif type(value) is int:
        require(abs(value) <= 2**53 - 1, "integer outside exact JSON range; use a string")
    elif type(value) is float:
        require(math.isfinite(value) and abs(value) <= 2**53 - 1, "unsafe or non-finite number")
    else:
        raise BundleError("unsupported JSON value: " + type(value).__name__)


def safe_relative(value):
    require(isinstance(value, str) and value and "\\" not in value and ":" not in value,
            "unsafe relative path")
    require(not value.startswith("/") and all(ord(c) >= 32 for c in value), "unsafe relative path")
    parts = value.split("/")
    require(all(p not in ("", ".", "..") for p in parts), "unsafe relative path")
    return value


def locator_key(locator):
    return locator["kind"] + ":" + locator["value"]


def validate_locator(locator):
    require(isinstance(locator, dict) and set(locator) == {"kind", "value"}, "invalid locator")
    kind, value = locator["kind"], locator["value"]
    require(kind in ("project", "external", "uri") and isinstance(value, str) and value, "invalid locator")
    if kind == "project":
        safe_relative(value)
    elif kind == "external":
        require(Path(value).is_absolute() or re.match(r"^[A-Za-z]:[/\\]", value), "external locator must be absolute")
    else:
        require(bool(urlsplit(value).scheme), "URI needs a scheme")


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def ref_key(ref):
    return ref["id"], ref["revision"]


def validate_record(rec, version):
    validate_values(rec)
    require(isinstance(rec, dict) and RECORD_KEYS <= set(rec) <= RECORD_KEYS | {"design", "scope"}, "invalid record fields")
    require(rec["kind"] in PREFIXES, "invalid record kind")
    require(isinstance(rec["id"], str) and re.fullmatch(PREFIXES[rec["kind"]] + r"-\d{3,}", rec["id"]), "invalid record ID")
    require(type(rec["revision"]) is int and rec["revision"] >= 1, "invalid record revision")
    require(isinstance(rec["name"], str) and rec["name"] and isinstance(rec["created_at"], str), "record name/time required")
    require(rec["status"] in ("active", "superseded", "inactive"), "invalid record status")
    require(isinstance(rec["details"], dict) and isinstance(rec["foreign_refs"], list), "invalid details/foreign_refs")
    require(rec["params"] is None or isinstance(rec["params"], dict), "parameters must be object or null")
    require(rec["inputs"] is None or isinstance(rec["inputs"], list), "inputs must be array or null")
    require(isinstance(rec["code"], list), "code must be array")
    for field in ("role", "type", "method"):
        require(rec[field] is None or isinstance(rec[field], str), "invalid text field: " + field)
    if rec["locator"] is not None:
        validate_locator(rec["locator"])
    require(rec["sha256"] is None or bool(re.fullmatch(r"[0-9a-f]{64}", str(rec["sha256"]))), "invalid SHA256")
    require(rec["size"] is None or type(rec["size"]) is int and rec["size"] >= 0, "invalid file size")
    if rec["kind"] in ("data", "figure"):
        require(rec["locator"] is not None, "file record needs locator")
    if rec["kind"] == "figure":
        require(bool(rec["type"]) and rec["sha256"] is not None, "figure needs type and digest")
    if rec["kind"] == "data":
        require(bool(rec["role"]), "data role required")
    if rec["kind"] == "design":
        require(rec["id"] == "DES-001", "invalid design identity")
        validate_design(rec["details"], require)
    for code in rec["code"]:
        require(isinstance(code, dict) and set(code) == {"locator", "sha256", "snapshot"}, "invalid code entry")
        validate_locator(code["locator"])
        require(code["sha256"] is None or bool(re.fullmatch(r"[0-9a-f]{64}", str(code["sha256"]))), "invalid code digest")
        if code["snapshot"] is not None:
            require(code["snapshot"] == ".nb_project_bundle/code/" + str(code["sha256"]), "invalid snapshot path")
    require(version != VERSION or "design" not in rec and rec["kind"] != "design", "design requires schema 0.2.0")
    require("scope" not in rec or version == SCOPE_VERSION and rec["kind"] == "data", "scope requires schema 0.3.0 DATA")
    require(rec["kind"] != "data" or "design" not in rec or version == SCOPE_VERSION, "DATA design requires schema 0.3.0")
    if "scope" in rec:
        from .scope import normalize_scope
        require(normalize_scope(rec["scope"], require) == rec["scope"], "scope must use canonical fields")


def validate_links(rec, check_ref):
    for ref in rec["inputs"] or []:
        check_ref(ref, "data")
    if rec["analysis"] is not None:
        check_ref(rec["analysis"], "analysis")
    for field, kind in (("parent", "data"), ("membership", "data"), ("clustering_run", "analysis")):
        if rec["details"].get(field) is not None:
            check_ref(rec["details"][field], kind)
    if rec["kind"] == "figure" and rec["analysis"] is not None:
        require("design" not in rec, "linked figure inherits its analysis design")
    if "design" in rec:
        require(rec["kind"] in ("data", "analysis", "figure"), "design context belongs to analyses or figures")
        if rec["design"] is not None:
            check_ref(rec["design"], "design")
    if rec["kind"] == "design":
        for ref in rec["details"]["context"]:
            check_ref(ref)
            require(check_ref(ref)["kind"] in ("data", "analysis"), "design context must reference data or analysis")
    if "scope" in rec:
        scope = rec["scope"]
        for field, kind in (("sample_manifest_ref", "data"), ("transformation_ref", "analysis")):
            if scope[field] is not None:
                check_ref(scope[field], kind)
        for ref in scope["evidence"]["source_refs"]:
            require(check_ref(ref)["kind"] in ("data", "analysis", "decision"), "scope source kind")
        report = scope["membership_evidence"]["report_ref"]
        if report is not None:
            check_ref(report, "data")


def validate_state(state):
    validate_values(state)
    require(isinstance(state, dict) and set(state) == STATE_KEYS, "unexpected/missing state fields")
    require(state["schema_version"] in (VERSION, DESIGN_VERSION, SCOPE_VERSION), "unsupported schema version")
    project = state["project"]
    require(isinstance(project, dict) and PROJECT_KEYS <= set(project) <= PROJECT_KEYS | {"design"}, "invalid project fields")
    require(valid_uuid(project["id"]) and isinstance(project["name"], str) and project["name"], "invalid project identity")
    require(valid_uuid(state["last_transaction"]), "invalid transaction ID")
    require(type(state["state_revision"]) is int and state["state_revision"] >= 1, "invalid state revision")
    require(type(state["imported"]) is bool, "invalid imported flag")
    for field in ("purpose", "next_task"):
        require(project[field] is None or isinstance(project[field], str), "invalid project text")
    for field in ("raw_dir", "metadata"):
        if project[field] is not None:
            validate_locator(project[field])
    require(isinstance(project["questions"], list) and isinstance(project["authorities"], list), "project arrays required")
    require(isinstance(state["records"], list) and isinstance(state["history"], list), "records/history must be arrays")
    require(isinstance(state["current"], dict) and isinstance(state["bindings"], dict), "current/bindings must be objects")
    for key, value in state["bindings"].items():
        require(isinstance(key, str) and ":" in key, "invalid binding key")
        # Rebinding external paths is explicit; archive import accepts only internal mappings.
        require(isinstance(value, str) and value, "invalid binding")
        if not Path(value).is_absolute():
            safe_relative(value)
    if state["schema_version"] == VERSION:
        require("design" not in project and all("design" not in r and r.get("kind") != "design" for r in state["records"]), "design requires schema 0.2.0")
    index = {}
    for rec in state["records"]:
        validate_record(rec, state["schema_version"])
        key = ref_key(rec)
        require(key not in index, "duplicate record revision")
        index[key] = rec
    def check_ref(ref, kind=None):
        require(isinstance(ref, dict) and set(ref) == {"project_id", "id", "revision"}, "invalid exact reference")
        require(ref["project_id"] == project["id"] and isinstance(ref["id"], str) and type(ref["revision"]) is int and ref["revision"] > 0, "foreign or invalid reference")
        require(ref_key(ref) in index, "dangling reference")
        require(kind is None or index[ref_key(ref)]["kind"] == kind, "wrong reference kind")
        return index[ref_key(ref)]
    for rec in state["records"]:
        validate_links(rec, check_ref)
    if project.get("design") is not None:
        check_ref(project["design"], "design")
    for purpose, ref in state["current"].items():
        require(bool(purpose.strip()), "empty purpose")
        check_ref(ref, "data")
    for event in state["history"]:
        require(isinstance(event, dict) and set(event) == {"at", "action", "actor", "reason", "target", "transaction"}, "invalid history")
        require(all(isinstance(event[k], str) for k in ("at", "action", "actor")), "invalid history text")
        require(event["transaction"] is None or valid_uuid(event["transaction"]), "invalid event transaction")
        if event["target"] is not None:
            check_ref(event["target"])
    return state


def atomic_state(path, state):
    raw = canonical(validate_state(state))
    require(len(raw) <= MAX_JSON, "state exceeds 20 MiB")
    temp = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".state-", delete=False) as out:
            temp = Path(out.name)
            out.write(raw)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if temp is not None and temp.exists():
            temp.unlink()
    return digest_bytes(raw)


class ProjectBundle:
    """Small staged state object. Each mutator needs save() to commit."""

    def __init__(self, root, state, raw_digest):
        self.root = root
        self.state = state
        self._loaded_digest = raw_digest
        self._loaded_revision = state["state_revision"]
        self._dirty = False
        self._snapshots = {}
        self._reindex()

    @classmethod
    def create(cls, name, project_dir, purpose=None, raw_dir=None, metadata=None):
        require(isinstance(name, str) and name.strip(), "name is required")
        root = Path(project_dir).expanduser().resolve()
        require(root.is_dir(), "explicit existing project directory required")
        state = {"schema_version": VERSION, "project": {"id": str(uuid.uuid4()), "name": name,
                 "purpose": purpose, "raw_dir": None, "metadata": None, "next_task": None,
                 "questions": [], "authorities": []}, "state_revision": 1,
                 "last_transaction": str(uuid.uuid4()), "records": [], "current": {}, "bindings": {},
                 "history": [], "imported": False}
        obj = cls(root, state, None)
        for key, value in (("raw_dir", raw_dir), ("metadata", metadata)):
            if value is not None:
                state["project"][key] = obj._locator(value)
        obj._event("create", transaction=state["last_transaction"])
        validate_state(state)
        folder = root / ".nb_project_bundle"
        require(not folder.exists() and not folder.is_symlink(), "project registry already exists")
        folder.mkdir()  # Exclusive creation, no overwrite or recursive project migration.
        obj._loaded_digest = atomic_state(root / STATE_PATH, state)
        obj._dirty = False
        return obj

    @classmethod
    def open(cls, project_dir):
        root = Path(project_dir).expanduser().resolve()
        path = root / STATE_PATH
        require(path.is_file() and not path.is_symlink(), "project registry missing or symlinked")
        require(path.parent.resolve() == root / ".nb_project_bundle", "registry escapes root")
        require(path.stat().st_size <= MAX_JSON, "state exceeds 20 MiB")
        raw = path.read_bytes()
        return cls(root, validate_state(parse_json(raw)), digest_bytes(raw))

    @property
    def unsaved(self):
        return self._dirty

    def _reindex(self):
        self._index = {}
        self._latest_index = {}
        self._kind_counts = {kind: 0 for kind in PREFIXES}
        self._next_ids = {kind: 0 for kind in PREFIXES}
        self._roles = defaultdict(set)
        for rec in self.state["records"]:
            self._index_record(rec)
        self._purposes = sorted(self.state["current"])

    def _index_record(self, rec):
        self._index[ref_key(rec)] = rec
        self._next_ids[rec["kind"]] = max(self._next_ids[rec["kind"]], int(rec["id"].split("-")[1]))
        old = self._latest_index.get(rec["id"])
        if old is None or rec["revision"] > old["revision"]:
            if old is None:
                self._kind_counts[rec["kind"]] += 1
            elif old["kind"] == "data" and old["status"] == "active":
                self._roles[old["role"]].discard(old["id"])
            self._latest_index[rec["id"]] = rec
            if rec["kind"] == "data" and rec["status"] == "active":
                self._roles[rec["role"]].add(rec["id"])

    def _locator(self, path):
        path = str(path)
        if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", path):
            return {"kind": "uri", "value": path}
        file = Path(path).expanduser()
        if not file.is_absolute():
            safe_relative(file.as_posix())
            file = self.root / file
        file = file.resolve()
        try:
            relative = file.relative_to(self.root).as_posix()
            if relative == ".":
                return {"kind": "external", "value": str(file)}
            return {"kind": "project", "value": safe_relative(relative)}
        except ValueError:
            return {"kind": "external", "value": str(file)}

    def _resolve(self, locator):
        if locator is None:
            return None
        key = locator_key(locator)
        if key in self.state["bindings"]:
            value = self.state["bindings"][key]
            file = Path(value)
            return file if file.is_absolute() else self._internal(value)
        if locator["kind"] == "project":
            return self._internal(locator["value"])
        if locator["kind"] == "external" and not self.state["imported"]:
            return Path(locator["value"])
        return None

    def _internal(self, value):
        path = self.root / safe_relative(value)
        require(os.path.commonpath([str(self.root), str(path.resolve())]) == str(self.root), "project path escapes root")
        return path

    def _ref(self, rec):
        return {"project_id": self.state["project"]["id"], "id": rec["id"], "revision": rec["revision"]}

    def _record(self, ref, kind=None):
        if isinstance(ref, str):
            match = re.fullmatch(r"((?:DATA|ANA|FIG|DEC|DES)-\d{3,})@([1-9]\d*)", ref)
            require(match is not None, "exact ID@revision required")
            ref = {"project_id": self.state["project"]["id"], "id": match[1], "revision": int(match[2])}
        require(isinstance(ref, dict) and set(ref) == {"project_id", "id", "revision"}, "exact reference required")
        require(ref["project_id"] == self.state["project"]["id"] and isinstance(ref["id"], str) and re.fullmatch(r"(?:DATA|ANA|FIG|DEC|DES)-\d{3,}", ref["id"]) and type(ref["revision"]) is int and ref["revision"] > 0, "wrong project/reference")
        rec = self._index.get(ref_key(ref))
        require(rec is not None, "missing exact record")
        require(kind is None or rec["kind"] == kind, "wrong record kind")
        return rec

    def _event(self, action, target=None, reason=None, transaction=None):
        self._dirty = True
        self.state["history"].append({"at": now(), "action": action, "actor": "caller", "reason": reason,
                                      "target": copy.deepcopy(target), "transaction": transaction})

    def _new(self, kind, name):
        require(isinstance(name, str) and name.strip(), "record name required")
        return {"kind": kind, "id": "%s-%03d" % (PREFIXES[kind], self._next_ids[kind] + 1),
                "revision": 1, "name": name, "created_at": now(), "locator": None, "role": None,
                "type": None, "sha256": None, "size": None, "inputs": None, "analysis": None,
                "code": [], "method": None, "params": None, "details": {}, "status": "active", "foreign_refs": []}

    def _stage(self, rec, action="register", reason=None, version=None):
        version = version or self.state["schema_version"]
        validate_record(rec, version)
        require(ref_key(rec) not in self._index, "duplicate record revision")
        def check_ref(ref, kind=None):
            if isinstance(ref, dict) and ref == self._ref(rec):
                require(kind is None or rec["kind"] == kind, "wrong record kind")
                return rec
            return self._record(ref, kind)
        validate_links(rec, check_ref)
        snapshots = {}
        for code in rec["code"]:
            dest = code["snapshot"]
            if dest and dest not in self._snapshots and not self._internal(dest).exists():
                source = self._resolve(code["locator"])
                require(source is not None and source.is_file() and source.stat().st_size <= 1024 * 1024, "code snapshot source missing or oversized")
                raw = source.read_bytes()
                require(digest_bytes(raw) == code["sha256"], "code changed during capture")
                snapshots[dest] = raw
        rec = copy.deepcopy(rec)
        self.state["records"].append(rec)
        self.state["schema_version"] = version
        self._index_record(rec)
        self._snapshots.update(snapshots)
        ref = self._ref(rec)
        self._event(action, ref, reason)
        return ref

    def _code(self, paths, snapshot=True):
        if paths is None:
            return []
        if isinstance(paths, (str, Path)):
            paths = [paths]
        require(isinstance(paths, (list, tuple)), "code must be path or list of paths")
        entries = []
        for file in paths:
            loc = self._locator(file)
            path = self._resolve(loc)
            require(path is not None and path.is_file(), "declared code file missing")
            require(not snapshot or path.stat().st_size <= 1024 * 1024,
                    "code exceeds 1 MiB snapshot limit; opt out explicitly")
            digest = fingerprint(path)
            relative = ".nb_project_bundle/code/" + digest if snapshot else None
            if snapshot:
                raw = path.read_bytes()
                require(digest_bytes(raw) == digest, "code changed during capture")
            entries.append({"locator": loc, "sha256": digest, "snapshot": relative})
        return entries

    def register_data(self, path, role, name=None, hash=False, **details):
        require(isinstance(role, str) and role, "data role required")
        locator = self._locator(path)
        file = self._resolve(locator)
        require(locator["kind"] == "uri" or file is not None and file.exists(), "data path missing")
        rec = self._new("data", name or Path(str(path)).name)
        rec.update(locator=locator, role=role, details=copy.deepcopy(details))
        if file is not None and file.is_file():
            rec["size"] = file.stat().st_size
            rec["sha256"] = fingerprint(file) if hash else None
        require(not hash or rec["sha256"] is not None, "hashing requires a local regular file")
        rec["details"]["provenance"] = {"file": "captured" if hash else "unknown", "analytical": "declared"}
        return self._stage(rec)

    def register_analysis(self, name, inputs, code=None, method=None, params=None, snapshot_code=True, **details):
        rec = self._new("analysis", name)
        require(inputs is None or isinstance(inputs, list), "inputs must be list or None")
        rec.update(inputs=None if inputs is None else [self._ref(self._record(x, "data")) for x in inputs],
                   code=self._code(code, snapshot_code), method=method, params=copy.deepcopy(params), details=copy.deepcopy(details))
        rec["details"]["provenance"] = {"file": "unknown", "analytical": "declared"}
        if self.state["project"].get("design") is not None:
            rec["design"] = copy.deepcopy(self.state["project"]["design"])
        return self._stage(rec)

    def register_figure(self, path, type, analysis=None, name=None, inputs=None, code=None, method=None, params=None,
                        snapshot_code=True, **details):
        locator = self._locator(path)
        file = self._resolve(locator)
        require(file is not None and file.is_file(), "figure must be an existing regular file")
        if analysis is not None:
            require(all(x is None for x in (inputs, code, method, params)), "do not override inherited analysis fields")
        rec = self._new("figure", name or file.stem)
        rec.update(locator=locator, type=type, size=file.stat().st_size, sha256=fingerprint(file),
                   analysis=self._ref(self._record(analysis, "analysis")) if analysis is not None else None,
                   inputs=None if inputs is None else [self._ref(self._record(x, "data")) for x in inputs],
                   code=self._code(code, snapshot_code), method=method, params=copy.deepcopy(params), details=copy.deepcopy(details))
        rec["details"]["format"] = file.suffix.lstrip(".").lower()
        rec["details"]["provenance"] = {"file": "captured", "analytical": "declared" if analysis or inputs or code else "unknown"}
        if analysis is None and self.state["project"].get("design") is not None:
            rec["design"] = copy.deepcopy(self.state["project"]["design"])
        return self._stage(rec)

    def _verify_file(self, rec, max_bytes=None):
        label = rec["id"] + "@" + str(rec["revision"])
        def fail(code):
            raise BundleError(code + ": " + label)
        path = self._resolve(rec["locator"])
        if path is None:
            fail("UNRESOLVED")
        try:
            before = path.stat()
        except FileNotFoundError:
            fail("MISSING_FILE")
        except OSError:
            fail("UNUSABLE_FILE")
        if not path.is_file():
            fail("UNUSABLE_FILE")
        if rec["size"] is not None and before.st_size != rec["size"]:
            fail("SIZE_MISMATCH")
        if max_bytes is not None and before.st_size > max_bytes:
            fail("MEMBERSHIP_EVIDENCE")
        if rec["sha256"] is None:
            fail("MISSING_DIGEST")
        try:
            actual = fingerprint(path)
            after = path.stat()
        except OSError:
            fail("UNUSABLE_FILE")
        stat_key = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if stat_key(before) != stat_key(after):
            fail("FILE_CHANGED")
        if actual != rec["sha256"]:
            fail("DIGEST_MISMATCH")
        return path, actual

    def _membership_report(self, rec, scope, check_membership):
        from .scope import validate_report, same_value
        label = rec["id"] + "@" + str(rec["revision"])
        def evidence_require(condition, detail):
            require(condition, "MEMBERSHIP_EVIDENCE: " + label + " " + detail)
        ev = scope["membership_evidence"]
        evidence_require(ev["status"] == "verification_recorded", "no recorded verification")
        report_rec = self._record(ev["report_ref"], "data")
        path, expected = self._verify_file(report_rec, MAX_JSON)
        # Check the bytes actually parsed as well as the streamed integrity result.
        raw = path.read_bytes()
        evidence_require(digest_bytes(raw) == expected, "report changed while reading")
        report = parse_json(raw)
        validate_report(report, evidence_require)
        membership_ref = rec["details"].get("membership")
        evidence_require(membership_ref is not None and membership_ref == report["membership_ref"], "membership binding mismatch")
        member = self._record(membership_ref, "data")
        evidence_require(rec["sha256"] is not None and report["subject_sha256"] == rec["sha256"], "subject binding mismatch")
        evidence_require(member["sha256"] is not None and report["membership_sha256"] == member["sha256"], "membership digest mismatch")
        evidence_require(report["result"] == "match", "comparison did not match")
        if report["checker"]["analysis_ref"] is not None:
            self._record(report["checker"]["analysis_ref"], "analysis")
        if check_membership:
            self._verify_file(member)
        checked = []
        for key, value in report.get("observed_scope", {}).items():
            if scope[key] is not None:
                require(same_value(key, scope[key], value), "SCOPE_CONFLICT: " + label + " " + key)
                checked.append(key)
        return sorted(checked)

    def set_data_scope(self, ref, scope, reason, design_ref=None):
        from .scope import normalize_scope
        require(isinstance(reason, str) and reason.strip(), "scope reason required")
        rec = copy.deepcopy(self._record(ref, "data"))
        scope = normalize_scope(scope, require)
        design_ref = self._ref(self._record(design_ref, "design")) if design_ref is not None else None
        if scope["membership_evidence"]["status"] == "verification_recorded":
            self._membership_report(rec, scope, False)
        rec.update(revision=self._latest_index[rec["id"]]["revision"] + 1,
                   created_at=now(), scope=scope, design=design_ref)
        return self._stage(rec, "set_data_scope", reason, version=SCOPE_VERSION)

    def resolve_data(self, ref=None, purpose=None, *, verify, expected_scope=None, require_membership=False):
        from .scope import validate_expected, same_value
        require(verify == "sha256", "SELECTOR: explicit verify='sha256' required")
        require(type(require_membership) is bool, "SELECTOR: require_membership must be boolean")
        require((ref is not None) + (purpose is not None) == 1, "SELECTOR: exactly one ref or purpose required")
        if expected_scope is not None:
            validate_expected(expected_scope, require)
        if purpose is not None:
            require(isinstance(purpose, str) and purpose in self.state["current"], "NO_CURRENT: no selected dataset for purpose")
            ref = self.state["current"][purpose]
        try:
            rec = self._record(ref, "data")
        except BundleError as exc:
            raise BundleError("SELECTOR: " + str(exc)) from exc
        label = rec["id"] + "@" + str(rec["revision"])
        require(rec["status"] == "active", "INACTIVE: " + label)
        scope = rec.get("scope")
        for key, value in (expected_scope or {}).items():
            require(scope is not None and scope[key] is not None, "SCOPE_UNKNOWN: " + label + " " + key)
            require(same_value(key, scope[key], value), "SCOPE_CONFLICT: " + label + " " + key)
        if scope and scope["condition_values"] is not None and rec.get("design") is not None:
            design = self.get_design(rec["design"])
            values = set(scope["condition_values"])
            require(set(design["selected_levels"]) <= values <= set(design["levels"]), "SCOPE_CONFLICT: " + label + " condition_values")
        if require_membership:
            require(scope is not None and scope["membership_evidence"]["status"] == "verification_recorded", "MEMBERSHIP_EVIDENCE: " + label)
        path, actual = self._verify_file(rec)
        membership = scope["membership_evidence"]["status"] if scope else "unknown"
        checked = []
        if require_membership:
            require(scope is not None, "MEMBERSHIP_EVIDENCE: " + label)
            checked = self._membership_report(rec, scope, True)
            membership = "verified_against_recorded_evidence"
        elif membership == "verification_recorded":
            membership = "verification_recorded_not_rechecked"
        view = self.get_data(ref=self._ref(rec))
        view.available = True
        view.availability_checked = True
        view.verification = {"checked_at": now(), "baseline_sha256": rec["sha256"], "observed_sha256": actual,
                             "file_integrity": "match", "scope_basis": scope["evidence"]["basis"] if scope else "unknown",
                             "required_scope": "match" if expected_scope is not None else "not_requested",
                             "membership": membership, "verified_scope_fields": checked}
        return view

    def get_raw_dir(self):
        return self._resolve(self.state["project"]["raw_dir"])

    def get_metadata_path(self):
        return self._resolve(self.state["project"]["metadata"])

    def get_output_dir(self, kind):
        require(isinstance(kind, str) and re.fullmatch(r"[A-Za-z0-9_-]+", kind), "simple output kind required")
        return self._internal("results/" + kind)

    def _latest(self, kind=None):
        return [rec for key, rec in sorted(self._latest_index.items()) if kind is None or rec["kind"] == kind]

    def _view(self, rec, check_files=False):
        require(type(check_files) is bool, "check_files must be boolean")
        view = copy.deepcopy(rec)
        path = self._resolve(rec["locator"])
        view.update(ref=self._ref(rec), path=path, available=(path is not None and path.exists()) if check_files else None,
                    availability_checked=check_files, unsaved=self.unsaved)
        return SimpleNamespace(**view)

    def get_data(self, ref=None, role=None, purpose=None, check_files=False):
        require(sum(x is not None for x in (ref, role, purpose)) == 1, "choose exactly one data selector")
        if purpose is not None:
            require(purpose in self.state["current"], "no current dataset for purpose")
            ref = self.state["current"][purpose]
        if ref is None:
            matches = [self._latest_index[key] for key in self._roles.get(role, ())]
            require(len(matches) == 1, "missing or ambiguous data role")
            rec = matches[0]
        else:
            rec = self._record(ref, "data")
        view = self._view(rec, check_files)
        view.design_ref = copy.deepcopy(rec.get("design"))
        view.design = self.get_design(view.design_ref) if view.design_ref else None
        view.scope = copy.deepcopy(rec.get("scope"))
        return view

    def get_figure(self, ref, check_files=False):
        rec = self._record(ref, "figure")
        view = self._view(rec, check_files)
        source = self._record(rec["analysis"], "analysis") if rec["analysis"] else rec
        for key in ("inputs", "code", "method", "params"):
            setattr(view, key, copy.deepcopy(source[key]))
        view.design_ref = copy.deepcopy(source.get("design"))
        view.design = self.get_design(view.design_ref) if view.design_ref else None
        view.analysis_details = copy.deepcopy(source["details"])
        # Analysis context has no figure file; its generic null file marker is not a figure gap.
        view.analysis_details.get("provenance", {}).pop("file", None)
        view.provenance = {"figure_file": rec["details"].get("provenance", {}).get("file", "unknown"),
                           "analytical": source["details"].get("provenance", {}).get("analytical", "unknown"),
                           "execution": "unknown"}
        view.unknown = [key for key in ("inputs", "method", "params") if getattr(view, key) is None]
        if not view.code:
            view.unknown.append("code")
        view.input_availability = [{"ref": x, "available": self.get_data(ref=x, check_files=check_files).available} for x in view.inputs or []]
        view.code_availability = []
        for code in view.code:
            snapshot = code["snapshot"]
            file = self._resolve({"kind": "project", "value": snapshot}) if snapshot else self._resolve(code["locator"])
            view.code_availability.append({"reference": copy.deepcopy(code), "path": file,
                                          "available": bool(snapshot in self._snapshots or file is not None and file.is_file()) if check_files else None})
        return view

    def find_figures(self, query=None, type=None):
        tokens = (query or "").casefold().split()
        result = []
        for rec in self._latest("figure"):
            haystack = " ".join([rec["name"], rec["type"], str(rec["details"].get("description", ""))]).casefold()
            if rec["status"] == "active" and (type is None or rec["type"] == type) and all(t in haystack for t in tokens):
                result.append(self.get_figure(self._ref(rec)))
        return result

    def set_current(self, ref, purpose, reason):
        require(not self.state["project"]["authorities"], "current selection governed by external authority")
        require(isinstance(purpose, str) and purpose.strip() and isinstance(reason, str) and reason.strip(), "purpose and reason required")
        rec = self._record(ref, "data")
        require(rec["status"] == "active", "current data must be active")
        self.state["current"][purpose] = self._ref(rec)
        self._purposes = sorted(self.state["current"])
        self._event("set_current", self._ref(rec), reason)
        return self._ref(rec)

    def update_record(self, ref, changes, reason):
        require(isinstance(changes, dict) and isinstance(reason, str) and reason.strip(), "changes and reason required")
        rec = copy.deepcopy(self._record(ref))
        require(rec["kind"] != "design", "use set_design to revise experimental design")
        allowed = {"name", "status", "details", "method", "params", "inputs", "code", "foreign_refs", "path"}
        require(set(changes) <= allowed, "protected or unknown correction field")
        if rec.get("scope", {}).get("membership_evidence", {}).get("status") == "verification_recorded":
            require(not ({"path", "details"} & set(changes)), "clear membership evidence through set_data_scope before changing subject/bindings")
        if "path" in changes:
            require(rec["kind"] in ("data", "figure"), "path correction requires file record")
            loc = self._locator(changes["path"])
            file = self._resolve(loc)
            require(file is not None and file.is_file(), "new revision file missing")
            rec.update(locator=loc, sha256=fingerprint(file), size=file.stat().st_size)
        rec.update(copy.deepcopy({k: v for k, v in changes.items() if k != "path"}))
        rec["revision"] = self._latest_index[rec["id"]]["revision"] + 1
        rec["created_at"] = now()
        return self._stage(rec, "update_record", reason)

    def set_context(self, changes):
        allowed = {"purpose", "next_task", "questions", "authorities", "raw_dir", "metadata"}
        require(isinstance(changes, dict) and set(changes) <= allowed, "unknown/protected context field")
        project = copy.deepcopy(self.state["project"])
        for key, value in changes.items():
            project[key] = self._locator(value) if key in ("raw_dir", "metadata") and value is not None else copy.deepcopy(value)
        validate_values(project)
        for key in ("purpose", "next_task"):
            require(project[key] is None or isinstance(project[key], str), "invalid project text")
        for key in ("questions", "authorities"):
            require(isinstance(project[key], list), "project arrays required")
        for key in ("raw_dir", "metadata"):
            if project[key] is not None:
                validate_locator(project[key])
        if project != self.state["project"]:
            self.state["project"] = project
            self._event("set_context")

    def record_decision(self, text, reason, targets):
        require(isinstance(reason, str) and reason.strip() and isinstance(targets, list), "reason/targets required")
        rec = self._new("decision", text)
        rec["details"] = {"reason": reason, "targets": [self._ref(self._record(x)) for x in targets], "approval": "not_authenticated"}
        return self._stage(rec, "record_decision", reason)

    def rebind_external(self, ref, path, reason):
        require(isinstance(reason, str) and reason.strip(), "rebind reason required")
        rec = self._record(ref)
        require(rec["locator"] is not None and rec["locator"]["kind"] != "project", "only external locator may be rebound")
        file = Path(path).expanduser().resolve()
        require(file.is_file(), "rebind target missing")
        if rec["sha256"]:
            require(fingerprint(file) == rec["sha256"], "rebind digest mismatch")
        self.state["bindings"][locator_key(rec["locator"])] = str(file)
        self._event("rebind_external", self._ref(rec), reason)

    def set_design(self, condition, levels, selected_levels=None, reference_level=None, replicate=None,
                   selection_reason=None, metadata=None, context=None):
        """Stage a scientist-selected design revision; never subset data."""
        details = {"condition": condition, "levels": copy.deepcopy(levels),
                   "selected_levels": copy.deepcopy(levels if selected_levels is None else selected_levels),
                   "reference_level": reference_level, "replicate": replicate, "selection_reason": selection_reason,
                   "evidence_source": "scientist-declared", "metadata_check": None,
                   "context": copy.deepcopy([] if context is None else context)}
        validate_design(details, require)
        details["context"] = [self._ref(self._record(ref)) for ref in details["context"]]
        if metadata is not None:
            report = check_metadata(details, metadata, require)
            require(report["valid"], "metadata does not verify the declared design: " + str(report))
            details.update(evidence_source="metadata-verified", metadata_check=report)
        rec = self._new("design", "Experimental design")
        rec.update(id="DES-001", revision=self._latest_index.get("DES-001", {}).get("revision", 0) + 1, details=details)
        version = SCOPE_VERSION if self.state["schema_version"] == SCOPE_VERSION else DESIGN_VERSION
        ref = self._stage(rec, "set_design", selection_reason, version=version)
        self.state["project"]["design"] = copy.deepcopy(ref)
        return ref

    def get_design(self, ref=None):
        ref = self.state["project"].get("design") if ref is None else ref
        if ref is None:
            return None
        rec = self._record(ref, "design")
        return dict(copy.deepcopy(rec["details"]), ref=self._ref(rec))

    def get_condition(self):
        design = self.get_design()
        return design["condition"] if design else None

    def get_levels(self):
        design = self.get_design()
        return design["levels"] if design else None

    def get_selected_levels(self):
        design = self.get_design()
        return design["selected_levels"] if design else None

    def get_reference_level(self):
        design = self.get_design()
        return design["reference_level"] if design else None

    def get_replicate(self):
        design = self.get_design()
        return design["replicate"] if design else None

    def check_design_metadata(self, metadata, ref=None):
        design = self.get_design(ref)
        require(design is not None, "experimental design is not configured")
        return check_metadata(design, metadata, require)

    def get_design_summary(self):
        return compact_design(self.get_design())

    def get_analysis(self, ref):
        rec = self._record(ref, "analysis")
        view = self._view(rec)
        view.design_ref = copy.deepcopy(rec.get("design"))
        view.design = self.get_design(view.design_ref) if view.design_ref else None
        return view

    def summary(self):
        return {"project": copy.deepcopy(self.state["project"]), "state_revision": self.state["state_revision"],
                "unsaved": self.unsaved, "records": len(self.state["records"]), "current": copy.deepcopy(self.state["current"]),
                "next_task": self.state["project"]["next_task"], "design": self.get_design(),
                "counts": {kind: self._kind_counts[kind] for kind in ("data", "analysis", "figure")}}

    def summary_text(self, purpose=None):
        counts = {kind: self._kind_counts[kind] for kind in ("data", "analysis", "figure")}
        if purpose is None:
            return summary_text(self.state["project"], self.get_design(), counts)
        status = self.status(purpose=purpose)
        return "BioDataLedger: " + status["project"]["name"] + "\nPurpose: " + status["purpose"] + "\n" + json.dumps(status.get("dataset"), ensure_ascii=False, indent=2)


    def __repr__(self):
        return self.summary_text()

    def check(self, hashes=False):
        validate_state(self.state)
        report = []
        for rec in self.state["records"]:
            entries = []
            if rec["locator"] is not None:
                entries.append((rec["locator"], rec["sha256"], "file"))
            for code in rec["code"]:
                loc = {"kind": "project", "value": code["snapshot"]} if code["snapshot"] else code["locator"]
                entries.append((loc, code["sha256"], "code"))
            for loc, expected, role in entries:
                file = self._resolve(loc)
                status = "missing" if file is None or not file.exists() else "available"
                if loc["value"] in self._snapshots:
                    status = "staged"
                if hashes and file is not None and file.is_file() and expected:
                    status = "match" if fingerprint(file) == expected else "stale"
                report.append({"ref": self._ref(rec), "role": role, "locator": copy.deepcopy(loc),
                               "status": status, "fingerprint": "known" if expected else "unknown"})
        return report

    def status(self, compact=True, purpose=None, check_files=False):
        """Bounded metadata by default; availability checks are explicit."""
        require(compact is True, "use summary()/check() for detailed output")
        require(type(check_files) is bool, "check_files must be boolean")
        require(purpose is None or isinstance(purpose, str) and purpose.strip(), "purpose must be nonempty")
        clipped = False
        def text(value, limit):
            nonlocal clipped
            if value is None:
                return None
            clipped = clipped or len(value) > limit
            return value[:limit]
        def reference(ref):
            nonlocal clipped
            if len(ref["id"]) > 64:
                clipped = True
                return None
            return copy.deepcopy(ref)
        pointers = self.state["current"]
        purposes = self._purposes if purpose is None else ([purpose] if purpose in pointers else [])
        current = [{"purpose": text(key, 64), "ref": reference(pointers[key])} for key in purposes[:5]]
        missing, found, candidates = [], None, []
        if check_files:
            seen = set()
            records = [self._record(pointers[key], "data") for key in purposes]
            records += self._latest() if purpose is None else []
            for record in records:
                locators = [(record["locator"], "file")] if record["locator"] is not None else []
                locators += [({"kind": "project", "value": code["snapshot"]} if code["snapshot"] else code["locator"], "code") for code in record["code"]]
                for locator, role in locators:
                    key = locator_key(locator)
                    if key not in seen:
                        seen.add(key)
                        candidates.append((locator, role, self._ref(record)))
            found = 0
            for locator, role, ref in candidates[:100]:
                path = self._resolve(locator)
                if path is None or not path.exists():
                    found += 1
                    if len(missing) < 5:
                        missing.append({"ref": reference(ref), "role": role, "reason": "unresolved" if path is None else "missing"})
        result = {"project": {"id": self.state["project"]["id"], "name": text(self.state["project"]["name"], 80)},
                  "registry_revision": self.state["state_revision"], "current": current,
                  "active_question": None, "next_task": text(self.state["project"]["next_task"], 160),
                  "missing": {"checked": min(100, len(candidates)), "unchecked": max(0, len(candidates) - 100) if check_files else None,
                              "found": found, "items": missing}, "unsaved": self.unsaved,
                  "truncated": {"current": len(purposes) - len(current), "missing": found - len(missing) if check_files else 0, "text": False},
                  "counts": {kind: self._kind_counts[kind] for kind in ("data", "analysis", "figure")}, "availability_checked": check_files}
        if purpose is not None:
            result.update(purpose=text(purpose, 64), dataset=None)
            if purpose in pointers:
                rec = self._record(pointers[purpose], "data")
                design_ref = rec.get("design")
                design = compact_design(self.get_design(design_ref)) if design_ref else None
                clipped = clipped or bool(design and design["truncated"])
                scope = None
                if "scope" in rec:
                    scope = {}
                    for key in ("condition_values", "assignment_inclusion"):
                        values = rec["scope"][key]
                        clipped = clipped or bool(values and len(values) > 5)
                        scope[key] = None if values is None else [text(x, 64) for x in values[:5]]
                    for key in ("observation_unit", "assay", "layer"):
                        scope[key] = text(rec["scope"][key], 64)
                    scope["evidence"] = rec["scope"]["evidence"]["basis"]
                    scope["membership_evidence"] = rec["scope"]["membership_evidence"]["status"]
                result["dataset"] = {"ref": reference(self._ref(rec)), "design_ref": reference(design_ref) if design_ref else None,
                                     "design": design, "scope": scope, "file_integrity": "not_checked"}
        result["truncated"]["text"] = clipped
        while len(canonical(result)) > 4096:
            if result["current"]:
                result["current"].pop()
                result["truncated"]["current"] += 1
            elif result["missing"]["items"]:
                result["missing"]["items"].pop()
                result["truncated"]["missing"] += 1
            elif result.get("dataset") is not None:
                result["dataset"] = None
                result["truncated"]["dataset"] = True
            else:
                raise BundleError("compact status exceeds its byte budget")
        return result

    def save(self):
        if not self._dirty:
            return {"state_revision": self._loaded_revision, "transaction": self.state["last_transaction"]}
        require(sys.platform != "win32", "Windows writes not qualified; use a tested local macOS runtime")
        folder = self.root / ".nb_project_bundle"
        lock = folder / "write.lock"
        try:
            lock.mkdir()
        except FileExistsError as exc:
            raise BundleError("writer lock held; inspect/recover deliberately") from exc
        try:
            (lock / "owner.json").write_bytes(canonical({"pid": os.getpid(), "host": socket.gethostname(), "at": now()}))
            raw = (self.root / STATE_PATH).read_bytes()
            current = validate_state(parse_json(raw))
            require(digest_bytes(raw) == self._loaded_digest and current["state_revision"] == self._loaded_revision,
                    "stale state; reload and reconcile, edits retained")
            if not self.unsaved:
                return {"state_revision": self._loaded_revision, "transaction": self.state["last_transaction"]}
            trial = copy.deepcopy(self.state)
            trial["state_revision"] = current["state_revision"] + 1
            trial["last_transaction"] = str(uuid.uuid4())
            for event in trial["history"]:
                if event["transaction"] is None:
                    event["transaction"] = trial["last_transaction"]
            validate_state(trial)
            for relative, content in self._snapshots.items():
                file = self._internal(relative)
                file.parent.mkdir(exist_ok=True)
                try:
                    with file.open("xb") as output:
                        output.write(content)
                        output.flush()
                        os.fsync(output.fileno())
                except FileExistsError:
                    require(fingerprint(file) == digest_bytes(content), "snapshot conflict")
            new_digest = atomic_state(self.root / STATE_PATH, trial)
            self.state = trial
            self._loaded_digest = new_digest
            self._loaded_revision = trial["state_revision"]
            self._dirty = False
            self._reindex()
            self._snapshots.clear()
            return {"state_revision": trial["state_revision"], "transaction": trial["last_transaction"]}
        finally:
            owner = lock / "owner.json"
            if owner.exists():
                owner.unlink()
            lock.rmdir()

    def preview_export(self, mode, include=None, exclude=None, redact=None):
        from .archives import preview_export
        return preview_export(self, mode, include, exclude, redact)

    def export_zip(self, plan, path):
        from .archives import export_zip
        return export_zip(self, plan, path)

    @classmethod
    def import_zip(cls, path, project_dir):
        from .archives import import_zip
        return import_zip(path, project_dir)
