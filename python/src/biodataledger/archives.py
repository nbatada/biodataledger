"""Selected, reviewed ZIPs. Archive input is inert and untrusted."""
import copy
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import unicodedata
from urllib.parse import urlsplit
import uuid
import zipfile

from .core import (BundleError, ProjectBundle, STATE_PATH, MAX_JSON, atomic_state, canonical,
                   digest_bytes, fingerprint, locator_key, parse_json, require, safe_relative,
                   validate_state)

FORMAT = "nb-project-bundle-zip/0.1"
MAX_FILES = 10000
MAX_TOTAL = 100 * 1024**3
MAX_RATIO = 1000
RESERVED = {STATE_PATH, "OVERVIEW.md", "DEPENDENCIES.json", "manifest.json"}


def safe_inventory(names):
    spellings = {}
    seen = set()
    for name in names:
        safe_relative(name)
        parts = name.split("/")
        for index in range(1, len(parts) + 1):
            prefix = "/".join(parts[:index])
            key = unicodedata.normalize("NFC", prefix).casefold()
            require(key not in spellings or spellings[key] == prefix, "case/Unicode ancestor collision")
            spellings[key] = prefix
        key = unicodedata.normalize("NFC", name).casefold()
        require(key not in seen, "duplicate/colliding archive member")
        seen.add(key)
    for key in seen:
        parents = key.split("/")[:-1]
        require(not any("/".join(parents[:i]) in seen for i in range(1, len(parents) + 1)),
                "file/directory path collision")


def sensitive_locator(locator):
    value = locator["value"]
    name = Path(value).name.lower()
    if name == ".env" or name.startswith(".env.") or name in ("id_rsa", "id_ed25519", "credentials", "credentials.json"):
        return True
    if any(part.lower() in (".ssh", ".aws") for part in value.replace("\\", "/").split("/")):
        return True
    if locator["kind"] == "uri":
        parsed = urlsplit(value)
        return bool(parsed.username or parsed.password or parsed.query)
    return False


def overview(state):
    lines = ["# " + state["project"]["name"], "", "Generated overview; authoritative state: .nb_project_bundle/project.json",
             "State revision: " + str(state["state_revision"]), "Purpose: " + str(state["project"]["purpose"] or "unknown"),
             "Next task: " + str(state["project"]["next_task"] or "unknown"), "",
             "Records are declared unless a specific check is recorded. Import does not execute code.",
             "Scientific acceptance and reproduction are not established by this bundle.", "", "## Current inputs"]
    for purpose, ref in state["current"].items():
        lines.append("- %s: %s@%s" % (purpose, ref["id"], ref["revision"]))
    lines.extend(["", "## Figures"])
    for rec in state["records"]:
        if rec["kind"] == "figure":
            ref = rec["analysis"]
            analysis = "%s@%s" % (ref["id"], ref["revision"]) if ref else "unknown"
            lines.append("- %s@%s: %s (%s); analysis %s" % (rec["id"], rec["revision"], rec["name"], rec["type"], analysis))
    lines.extend(["", "Inspect DEPENDENCIES.json for omitted/missing files. Record inspection is not proof of resumability.", ""])
    return "\n".join(lines).encode("utf-8")


def plan_hash(plan):
    return digest_bytes(canonical({key: value for key, value in plan.items() if key != "plan_digest"}))


def preview_export(project, mode, include=None, exclude=None, redact=None):
    require(mode in ("context", "working"), "mode must be context or working")
    require(not project.unsaved, "save staged records before export")
    require(not exclude and not redact, "Phase 1 requires explicit selected payloads; metadata redaction is not implemented")
    raw = (project.root / STATE_PATH).read_bytes()
    require(digest_bytes(raw) == project._loaded_digest, "stale state; reopen before preview")
    require(mode == "working" or not include, "context contains no selected payload")
    selected = {}
    def add(locator, expected, role):
        require(not sensitive_locator(locator), "credential-like file/URI excluded; do not package secrets")
        file = project._resolve(locator)
        require(file is not None and file.is_file(), "selected payload missing or not a regular file")
        actual = fingerprint(file)
        require(expected is None or actual == expected, "registered payload drift; retain a new revision before export")
        selected[locator_key(locator)] = {"locator": copy.deepcopy(locator), "size": file.stat().st_size,
                                         "sha256": actual, "role": role}
    for ref in include or []:
        rec = project._record(ref)
        require(rec["kind"] in ("data", "figure", "analysis"), "select data, figures or analyses")
        if rec["locator"] is not None:
            add(rec["locator"], rec["sha256"], rec["kind"])
        source = project._record(rec["analysis"], "analysis") if rec["analysis"] else rec
        for code in source["code"]:
            if code["snapshot"]:
                require(not sensitive_locator(code["locator"]), "credential-like code cannot be packaged")
                add({"kind": "project", "value": code["snapshot"]}, code["sha256"], "code")
    files = []
    bindings = {}
    for index, key in enumerate(sorted(selected), 1):
        item = selected[key]
        base = Path(item["locator"]["value"]).name
        base = re.sub(r"[^A-Za-z0-9._-]", "_", base)[:120] or "file"
        item["path"] = "payload/%05d-%s" % (index, base)
        bindings[key] = item["path"]
        files.append(item)
    omitted = []
    for rec in project.state["records"]:
        if rec["locator"] is not None and locator_key(rec["locator"]) not in selected:
            omitted.append({"ref": project._ref(rec), "locator": copy.deepcopy(rec["locator"]), "reason": "not selected"})
        for code in rec["code"]:
            loc = {"kind": "project", "value": code["snapshot"]} if code["snapshot"] else code["locator"]
            if locator_key(loc) not in selected:
                omitted.append({"ref": project._ref(rec), "locator": copy.deepcopy(loc), "reason": "code not packaged"})
    missing = [item for item in project.check() if item["status"] == "missing"]
    # Metadata is visible, not automatically sanitized. Reject known credential-bearing URIs even in context mode.
    locators = [r["locator"] for r in project.state["records"] if r["locator"]]
    locators += [project.state["project"][k] for k in ("raw_dir", "metadata") if project.state["project"][k]]
    require(not any(loc["kind"] == "uri" and sensitive_locator(loc) for loc in locators),
            "credential-bearing URI in metadata; correct it before sharing")
    state = copy.deepcopy(project.state)
    plan = {"mode": mode, "project_id": state["project"]["id"], "state_revision": state["state_revision"],
            "source_digest": project._loaded_digest, "files": files, "bindings": bindings,
            "omitted": omitted, "missing": missing, "metadata": copy.deepcopy(state), "state": state,
            "total_bytes": sum(f["size"] for f in files),
            "warning": "Review ALL metadata/history for sensitive information. No anonymization or dependency completeness guarantee."}
    plan["plan_digest"] = plan_hash(plan)
    return plan


def validate_zip(path):
    """Validate metadata, members and hashes without executing or extracting content."""
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        require(0 < len(infos) <= MAX_FILES, "archive entry count limit")
        safe_inventory([info.filename for info in infos])
        total = 0
        for info in infos:
            mode = info.external_attr >> 16
            require(not info.is_dir() and stat.S_IFMT(mode) in (0, stat.S_IFREG), "archive member is not a regular file")
            require(not info.flag_bits & 1, "encrypted archive unsupported")
            require(info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "unsupported compression")
            total += info.file_size
            require(info.file_size / max(info.compress_size, 1) <= MAX_RATIO, "archive expansion ratio limit")
        require(total <= MAX_TOTAL, "archive expanded size limit")
        names = {i.filename: i for i in infos}
        require(RESERVED <= set(names), "archive missing required metadata")
        require(names["manifest.json"].file_size <= MAX_JSON and names[STATE_PATH].file_size <= MAX_JSON, "metadata size limit")
        manifest = parse_json(archive.read("manifest.json"))
        keys = {"format", "export_id", "project_id", "state_revision", "mode", "files", "bindings", "omitted", "missing"}
        require(isinstance(manifest, dict) and set(manifest) == keys and manifest["format"] == FORMAT, "invalid archive manifest")
        require(manifest["mode"] in ("context", "working") and isinstance(manifest["files"], list), "invalid archive mode/files")
        listed = {}
        for entry in manifest["files"]:
            require(isinstance(entry, dict) and set(entry) == {"path", "size", "sha256", "role"}, "invalid manifest entry")
            require(entry["path"] not in listed and entry["path"] in names and entry["path"] != "manifest.json", "invalid/repeated manifest path")
            require(type(entry["size"]) is int and entry["size"] == names[entry["path"]].file_size, "manifest size mismatch")
            require(isinstance(entry["role"], str), "manifest role required")
            require(isinstance(entry["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]), "invalid manifest digest")
            import hashlib
            digest = hashlib.sha256()
            actual_size = 0
            with archive.open(entry["path"]) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    actual_size += len(block)
                    require(actual_size <= entry["size"], "expanded payload exceeds declared size")
                    digest.update(block)
            require(actual_size == entry["size"] and digest.hexdigest() == entry["sha256"], "payload hash/size mismatch")
            listed[entry["path"]] = entry
        require(set(listed) == set(names) - {"manifest.json"}, "unlisted archive files")
        state = validate_state(parse_json(archive.read(STATE_PATH)))
        require(manifest["project_id"] == state["project"]["id"] and manifest["state_revision"] == state["state_revision"], "archive state identity mismatch")
        require(isinstance(manifest["bindings"], dict), "manifest bindings must be object")
        for key, target in manifest["bindings"].items():
            require(isinstance(key, str) and ":" in key, "invalid mapping key")
            safe_relative(target)
            require(target in listed and target not in RESERVED, "invalid payload binding")
        require(manifest["mode"] != "context" or not manifest["bindings"] and set(names) == RESERVED, "context must not contain payloads")
        return manifest, state


def export_zip(project, plan, path):
    require(isinstance(plan, dict) and plan.get("plan_digest") == plan_hash(plan), "edited/invalid export plan")
    require(not project.unsaved, "save staged state before export")
    raw = (project.root / STATE_PATH).read_bytes()
    require(plan["source_digest"] == digest_bytes(raw) == project._loaded_digest, "stale export plan")
    require(plan["project_id"] == project.state["project"]["id"], "wrong project plan")
    output = Path(path).expanduser().absolute()
    require(output.parent.is_dir() and not output.exists() and not output.is_symlink(), "output parent required; archive overwrite prohibited")
    require(shutil.disk_usage(output.parent).free >= plan["total_bytes"] + 20 * 1024 * 1024, "insufficient free space")
    dependencies = {"omitted": plan["omitted"], "missing": plan["missing"], "closure": "declared only; script imports not discovered"}
    metadata = {STATE_PATH: canonical(plan["state"]), "OVERVIEW.md": overview(plan["state"]),
                "DEPENDENCIES.json": canonical(dependencies)}
    manifest = {"format": FORMAT, "export_id": str(uuid.uuid4()), "project_id": plan["project_id"],
                "state_revision": plan["state_revision"], "mode": plan["mode"], "files": [],
                "bindings": plan["bindings"], "omitted": plan["omitted"], "missing": plan["missing"]}
    for name, data in metadata.items():
        manifest["files"].append({"path": name, "size": len(data), "sha256": digest_bytes(data), "role": "metadata"})
    for entry in plan["files"]:
        source = project._resolve(entry["locator"])
        require(source is not None and source.is_file() and source.stat().st_size == entry["size"]
                and fingerprint(source) == entry["sha256"], "selected payload changed/missing since preview")
        manifest["files"].append({k: entry[k] for k in ("path", "size", "sha256", "role")})
    temporary = None
    try:
        handle, temporary = tempfile.mkstemp(dir=output.parent, prefix=".bundle-", suffix=".zip")
        os.close(handle)
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
            for name, data in metadata.items():
                archive.writestr(name, data)
            for entry in plan["files"]:
                source = project._resolve(entry["locator"])
                import hashlib
                digest = hashlib.sha256()
                info = zipfile.ZipInfo(entry["path"])
                info.external_attr = (stat.S_IFREG | 0o600) << 16
                info.create_system = 3
                with source.open("rb") as reader, archive.open(info, "w", force_zip64=True) as writer:
                    for block in iter(lambda: reader.read(1024 * 1024), b""):
                        digest.update(block)
                        writer.write(block)
                require(digest.hexdigest() == entry["sha256"], "selected payload changed while packaging")
            archive.writestr("manifest.json", canonical(manifest))
        require(digest_bytes((project.root / STATE_PATH).read_bytes()) == plan["source_digest"], "state changed during export")
        validate_zip(temporary)
        os.link(temporary, output)  # Exclusive publication; never replace a concurrent user's file.
        return {"path": str(output), "sha256": fingerprint(output), "mode": plan["mode"], "status": "inspectable"}
    finally:
        if temporary is not None and Path(temporary).exists():
            Path(temporary).unlink()


def import_zip(path, project_dir):
    source = Path(path).expanduser().resolve()
    before = fingerprint(source)
    manifest, state = validate_zip(source)
    dest = Path(project_dir).expanduser().absolute()
    require(dest.parent.is_dir() and not dest.exists() and not dest.is_symlink(), "new import destination required")
    required = sum(entry["size"] for entry in manifest["files"])
    require(shutil.disk_usage(dest.parent).free >= required + 20 * 1024 * 1024, "insufficient import space")
    staging = Path(tempfile.mkdtemp(dir=dest.parent, prefix=".import-"))
    published = False
    try:
        with zipfile.ZipFile(source) as archive:
            for entry in manifest["files"]:
                target = staging / safe_relative(entry["path"])
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry["path"]) as reader, target.open("xb") as writer:
                    shutil.copyfileobj(reader, writer, 1024 * 1024)
                require(fingerprint(target) == entry["sha256"], "payload changed during import")
        require(fingerprint(source) == before, "archive changed during import")
        state["bindings"] = copy.deepcopy(manifest["bindings"])
        state["imported"] = True
        state["state_revision"] += 1
        state["last_transaction"] = str(uuid.uuid4())
        obj = ProjectBundle(staging, state, None)
        obj._event("import", reason="export " + manifest["export_id"], transaction=state["last_transaction"])
        atomic_state(staging / STATE_PATH, state)
        # An exclusive empty destination claim prevents replacing a concurrent project.
        dest.mkdir()
        try:
            children = sorted(staging.iterdir(), key=lambda child: child.name == ".nb_project_bundle")
            for child in children:
                os.rename(child, dest / child.name)
            published = True
        except Exception:
            # Only this freshly claimed destination contains these files; preserve evidence if publication fails.
            raise BundleError("partial import publication; inspect " + str(dest))
        return ProjectBundle.open(dest)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
