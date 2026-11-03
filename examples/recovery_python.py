"""Preview and restore only explicitly declared files from an imported bundle."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import unicodedata

VERSION = "biodataledger-recovery/1"
SHA = re.compile(r"^[0-9a-f]{64}$")


def _fail(message):
    raise ValueError("Recovery: " + message)


def _relative(value, directory=False):
    if directory and value == ".":
        return value
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value or ":" in value or any(ord(c) < 32 for c in value):
        _fail("unsafe relative path: " + repr(value))
    if any(part in ("", ".", "..") for part in value.split("/")):
        _fail("unsafe relative path: " + repr(value))
    return value


def _digest(path):
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            h.update(block)
            size += len(block)
    return h.hexdigest(), size


def _regular(path):
    if not path.is_file() or path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        _fail("missing, nonregular or symlink source: " + str(path))


def _ref(value):
    if not isinstance(value, dict) or set(value) != {"project_id", "id", "revision"}:
        _fail("exact reference required")
    return value


def _source(project, figure, source, expected):
    if not isinstance(source, dict) or source.get("kind") not in ("record", "code"):
        _fail("invalid source declaration")
    if source["kind"] == "record":
        if set(source) != {"kind", "ref"}:
            _fail("invalid record source")
        ref = _ref(source["ref"])
        if ref["id"].startswith("DATA-"):
            view = project.get_data(ref=ref)
        elif ref["id"].startswith("FIG-"):
            view = project.get_figure(ref)
        else:
            _fail("record source must be DATA or FIG")
        if not view.sha256 or view.sha256 != expected:
            _fail("record digest absent or disagrees: " + ref["id"])
        return view.path, view.size
    if set(source) != {"kind", "analysis_ref", "locator", "sha256"}:
        _fail("invalid code source")
    ref = _ref(source["analysis_ref"])
    if ref != figure.analysis:
        _fail("code source must be target figure's analysis")
    if not SHA.fullmatch(source["sha256"]) or source["sha256"] != expected:
        _fail("code digest disagreement")
    matches = [item for item in figure.code_availability
               if item["reference"]["locator"] == source["locator"]
               and item["reference"]["sha256"] == expected]
    if len(matches) != 1:
        _fail("code locator absent or ambiguous")
    return matches[0]["path"], None


def _manifest(value):
    if isinstance(value, (str, os.PathLike)):
        path = Path(value)
        if path.stat().st_size > 20 * 1024 * 1024:
            _fail("manifest exceeds 20 MiB")
        with path.open("rb") as stream:
            raw = stream.read(20 * 1024 * 1024 + 1)
        if len(raw) > 20 * 1024 * 1024:
            _fail("manifest exceeds 20 MiB")
        def unique(pairs):
            result = {}
            for key, item in pairs:
                if key in result:
                    _fail("duplicate JSON key: " + key)
                result[key] = item
            return result
        try:
            value = json.loads(raw, object_pairs_hook=unique,
                               parse_constant=lambda x: _fail("nonfinite JSON number: " + x))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            _fail("malformed manifest JSON: " + str(exc))
    if not isinstance(value, dict) or set(value) != {"version", "figure_ref", "files", "entrypoint", "working_directory", "import_roots", "external_requirements"} or value["version"] != VERSION:
        _fail("invalid manifest version or fields")
    try:
        json.dumps(value, allow_nan=False)
    except (TypeError, ValueError) as exc:
        _fail("invalid manifest value: " + str(exc))
    return value


def preview_recovery(project, manifest):
    """Validate the complete finite mapping and return a reviewable fingerprint."""
    manifest = _manifest(manifest)
    _ref(manifest["figure_ref"])
    figure = project.get_figure(manifest["figure_ref"])
    files = manifest["files"]
    if not isinstance(files, list) or not files or len(files) > 10000:
        _fail("files must be a finite nonempty list")
    destinations = set()
    spellings = {}
    checked = []
    for index, entry in enumerate(files):
        if not isinstance(entry, dict) or set(entry) != {"source", "destination", "sha256", "size", "purpose"}:
            _fail("invalid file entry " + str(index))
        destination = _relative(entry["destination"])
        folded = unicodedata.normalize("NFC", destination).casefold()
        parts = destination.split("/")
        for i in range(1, len(parts) + 1):
            prefix = "/".join(parts[:i])
            key = unicodedata.normalize("NFC", prefix).casefold()
            if key in spellings and spellings[key] != prefix:
                _fail("case/Unicode ancestor collision: " + destination)
            spellings[key] = prefix
        if folded in destinations or any(folded.startswith(old + "/") or old.startswith(folded + "/") for old in destinations):
            _fail("destination collision: " + destination)
        destinations.add(folded)
        expected = entry["sha256"]
        size = entry["size"]
        if not isinstance(expected, str) or not SHA.fullmatch(expected) or type(size) is not int or size < 0 or not isinstance(entry["purpose"], str) or not entry["purpose"]:
            _fail("invalid digest, size or purpose: " + destination)
        path, recorded_size = _source(project, figure, entry["source"], expected)
        if path is None:
            _fail("unresolved source: " + destination)
        path = Path(path)
        _regular(path)
        actual = _digest(path)
        if actual != (expected, size) or (recorded_size is not None and recorded_size != size):
            _fail("source bytes disagree: " + destination)
        checked.append({"destination": destination, "source_path": str(path), "sha256": expected, "size": size, "purpose": entry["purpose"]})
    entrypoint = _relative(manifest["entrypoint"])
    if entrypoint not in {x["destination"] for x in checked}:
        _fail("entrypoint is not declared")
    cwd = _relative(manifest["working_directory"], directory=True)
    roots = manifest["import_roots"]
    requirements = manifest["external_requirements"]
    if not isinstance(roots, list) or not all(_relative(x, directory=True) for x in roots) or not isinstance(requirements, list) or not all(isinstance(x, str) and x for x in requirements):
        _fail("invalid import roots or external requirements")
    for hint in [cwd] + roots:
        if hint != "." and not any(x["destination"].startswith(hint + "/") for x in checked):
            _fail("directory hint has no declared file: " + hint)
    signature = hashlib.sha256(json.dumps(manifest, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
    return {"manifest_sha256": signature, "files": checked, "entrypoint": entrypoint, "working_directory": cwd, "import_roots": roots, "external_requirements": requirements}


def apply_recovery(project, manifest, destination, reviewed_preview):
    """Recheck the reviewed mapping and publish into an exclusively claimed directory."""
    fresh = preview_recovery(project, manifest)
    if fresh != reviewed_preview:
        _fail("manifest or source changed since review")
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        _fail("output already exists")
    parent = destination.parent.resolve(strict=True)
    stage = Path(tempfile.mkdtemp(prefix=".biodataledger-recovery-", dir=parent))
    try:
        for entry in fresh["files"]:
            source = Path(entry["source_path"])
            _regular(source)
            target = stage / entry["destination"]
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open("rb") as inp, target.open("xb") as out:
                shutil.copyfileobj(inp, out, 1024 * 1024)
            if _digest(target) != (entry["sha256"], entry["size"]) or _digest(source) != (entry["sha256"], entry["size"]):
                _fail("changed source during copy: " + entry["destination"])
        try:
            destination.mkdir()
        except FileExistsError:
            _fail("output appeared during copy")
        try:
            for child in stage.iterdir():
                os.rename(child, destination / child.name)
        except Exception:
            _fail("partial recovery publication; inspect " + str(destination))
        return {**fresh, "destination": str(destination)}
    finally:
        if stage.exists():
            shutil.rmtree(stage)
