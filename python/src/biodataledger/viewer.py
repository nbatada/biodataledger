"""Export a private, bounded browser snapshot of loaded project metadata."""
import base64
import hashlib
from importlib.resources import files
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import webbrowser

from . import __version__
from .core import BundleError, canonical, now, require, valid_uuid, validate_values
from .protocol import _timestamp


_CARD_BYTES = 16 * 1024
_METADATA_BYTES = 16 * 1024 * 1024
_PREVIEW_BYTES = 2 * 1024 * 1024
_PREVIEWS_BYTES = 8 * 1024 * 1024
_HTML_BYTES = 32 * 1024 * 1024


def _key(ref):
    return f"{ref['project_id']}/{ref['id']}@{ref['revision']}"


def _generation(project):
    state = project.state
    return (state["state_revision"], state["last_transaction"], len(state["records"]),
            len(state["history"]), project.unsaved)


def _timeline(project, view, remaining):
    pages, cursor, included = [], None, 0
    while remaining:
        page = project.timeline(view=view, order="oldest", limit=min(remaining, 20), cursor=cursor)
        cursor = page.pop("next_cursor")
        page["has_more"] = cursor is not None
        pages.append(page)
        count = len(page["rows"])
        included += count
        remaining -= count
        if cursor is None:
            break
    return {"pages": pages, "omitted": pages[0]["total_rows"] - included}


def _card(project, record, slot, latest):
    ref = project._ref(record)
    path = project._resolve(record["locator"], lexical=True)
    stamp = record["created_at"]
    card = {"ref": ref, "key": _key(ref), "kind": record["kind"], "name": record["name"],
            "status": record["status"], "is_latest": latest, "stored_order": slot,
            "recorded_at": stamp if _timestamp(stamp) is not None else None,
            "path": str(path) if path is not None else None,
            "directory": str(path.parent) if path is not None else None,
            "info": project.get_info(ref, limit=20) if record["kind"] in ("data", "analysis", "figure")
            else {"record": record, "availability_checked": False}}
    if len(canonical(card)) > _CARD_BYTES:
        card.update(name=None, path=None, directory=None, info=None, omission="card exceeds 16 KiB")
    return card


def _metadata(project, limit):
    state = project.state
    project_info = {**{key: state["project"][key] for key in ("id", "name", "purpose")},
                    "root": str(project.root)}
    omitted_fields = []
    for key in ("name", "purpose", "root"):
        if len(canonical(project_info[key])) > 4096:
            project_info[key] = None
            omitted_fields.append(key)
    current, current_bytes = [], 0
    for purpose in sorted(state["current"]):
        item = {"purpose": purpose, "ref": project._ref(project._record(state["current"][purpose]))}
        size = len(canonical(item)) + 1
        if current_bytes + size <= 64 * 1024:
            current.append(item)
            current_bytes += size
    records = state["records"]
    coverage = {"total_records": len(records), "included_records": 0, "omitted_records": len(records),
                "byte_limit_hit": False, "omitted_card_details": 0,
                "omitted_project_fields": omitted_fields, "omitted_current": len(state["current"]) - len(current)}
    payload = {"report_version": "biodataledger-view/1", "package_version": __version__, "client": "Python",
               "captured_at_utc": now(), "project": project_info, "registry_revision": state["state_revision"],
               "unsaved": project.unsaved, "imported": state["imported"], "coverage": coverage, "current": current,
               "records": [], "timelines": {view: _timeline(project, view, min(limit, 1000))
                                            for view in ("registration", "runs")}, "previews": {}}
    used = len(canonical(payload))
    # Later changes to coverage counters must also fit.
    for latest in (True, False):
        for slot in range(len(records), 0, -1):
            if len(payload["records"]) == limit or coverage["byte_limit_hit"]:
                break
            record = records[slot - 1]
            if (project._latest_index[record["id"]] is record) != latest:
                continue
            card = _card(project, record, slot, latest)
            used += len(canonical(card)) + 1
            if used > _METADATA_BYTES - 1024:
                coverage["byte_limit_hit"] = True
                break
            payload["records"].append(card)
            coverage["omitted_card_details"] += "omission" in card
    coverage["included_records"] = len(payload["records"])
    coverage["omitted_records"] -= coverage["included_records"]
    require(len(canonical(payload)) <= _METADATA_BYTES, "viewer metadata exceeds 16 MiB")
    return payload


def _preview_records(project, refs):
    if refs is None:
        return {}
    require(isinstance(refs, (list, tuple)) and len(refs) <= 10, "preview_refs requires up to 10 exact FIG refs")
    selected = {}
    for ref in refs:
        # Parse exact figure identities without resolving missing/foreign records to a newer revision.
        if isinstance(ref, str):
            match = re.fullmatch(r"(FIG-[0-9]{3,})@([1-9][0-9]{0,15})", ref)
            require(match is not None, "preview_refs requires exact FIG refs")
            ref = {"project_id": project.state["project"]["id"], "id": match[1], "revision": int(match[2])}
        require(isinstance(ref, dict) and set(ref) == {"project_id", "id", "revision"}
                and valid_uuid(ref["project_id"]) and isinstance(ref["id"], str)
                and re.fullmatch(r"FIG-[0-9]{3,}", ref["id"]) and type(ref["revision"]) is int
                and 1 <= ref["revision"] <= 2**53 - 1, "preview_refs requires exact FIG refs")
        selected[_key(ref)] = (project._index.get((ref["id"], ref["revision"]))
                               if ref["project_id"] == project.state["project"]["id"] else None)
    return selected


def _mime(data):
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "image/webp"
    if b"\0" in data:
        return None
    try:
        text = data.decode("utf-8-sig").lstrip(" \t\r\n")
    except UnicodeDecodeError:
        return None
    if re.match(r"<(?:svg(?:[\s>/]|$)|\?xml(?:[\s?]|$)|!DOCTYPE\s)", text):
        return "image/svg+xml"
    return None


def _read_preview(project, record, remaining):
    def omitted(status, reason):
        return {"status": status, "reason": reason}, 0

    if record is None:
        return omitted("unresolved", "Exact figure revision is unavailable")
    digest = record["sha256"]
    if digest is None:
        return omitted("unsupported", "Recorded SHA-256 is required")
    try:
        path = project._resolve(record["locator"])
    except (BundleError, OSError, RuntimeError):
        path = None
    if path is None or not path.is_absolute():
        return omitted("unresolved", "No safe local figure path")
    limit = min(_PREVIEW_BYTES, remaining)
    try:
        # Nonblocking open also protects against a regular file replaced by a FIFO.
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            source = os.fstat(stream.fileno())
            if not stat.S_ISREG(source.st_mode):
                return omitted("unsupported", "Preview source must be a regular file")
            if source.st_size > limit:
                return omitted("oversize", "Preview byte budget exceeded")
            data = stream.read(limit + 1)
    except OSError:
        return omitted("missing", "Figure file is missing or unreadable")
    if len(data) > limit:
        return omitted("oversize", "Preview byte budget exceeded")
    if hashlib.sha256(data).hexdigest() != digest.lower():
        return omitted("tampered", "Figure bytes differ from the recorded SHA-256")
    mime = _mime(data)
    if mime is None:
        return omitted("unsupported", "Preview requires PNG, JPEG, GIF, WebP, or UTF-8 SVG")
    return {"status": "included", "mime": mime, "base64": _base64(data), "digest": digest.lower()}, len(data)


def _base64(data):
    return base64.b64encode(data).decode("ascii")


def _render(payload):
    template = files("biodataledger").joinpath("viewer.html").read_bytes().decode("utf-8")
    for tag, section, marker in (("script", "app", "__BDL_SCRIPT_HASH__"), ("style", "style", "__BDL_STYLE_HASH__")):
        match = re.search(fr'<{tag} id="bdl-{section}">(.*?)</{tag}>', template, re.S)
        require(match is not None and template.count(marker) == 1, "invalid installed viewer template")
        template = template.replace(marker, _base64(hashlib.sha256(match[1].encode("utf-8")).digest()))
    marker = "__BDL_PAYLOAD_BASE64__"
    require(template.count(marker) == 1, "invalid installed viewer template")
    html = template.replace(marker, _base64(canonical(payload))).encode("utf-8")
    require(len(html) <= _HTML_BYTES, "viewer HTML exceeds 32 MiB; lower limit or omit previews")
    return html


def _launch(path):
    return webbrowser.open(path.as_uri())


def export_view(project, path, open_browser, limit, preview_refs):
    require(sys.platform == "darwin", "viewer writes currently require macOS")
    require(type(open_browser) is bool, "open_browser must be boolean")
    require(type(limit) is int and 1 <= limit <= 5000, "limit must be an integer from 1 to 5000")
    generation = _generation(project)
    selected = _preview_records(project, preview_refs)
    payload = _metadata(project, limit)
    remaining = _PREVIEWS_BYTES
    for key, record in selected.items():
        payload["previews"][key], size = _read_preview(project, record, remaining)
        remaining -= size
    validate_values(payload)
    html = _render(payload)

    private_dir = None
    try:
        if path is None:
            private_dir = Path(tempfile.mkdtemp(prefix="biodataledger-view-"))
            target = private_dir / "project.html"
        else:
            target = project.root / Path(path).expanduser()
        target = target.parent.resolve(strict=True) / target.name
        require(not os.path.lexists(target), "destination exists; overwrite prohibited")
        with tempfile.NamedTemporaryFile(prefix=".bdl-view-", dir=target.parent) as staged:
            staged.write(html)
            staged.flush()
            require(_generation(project) == generation, "loaded project changed during viewer export; retry")
            try:
                os.link(staged.name, target)
            except FileExistsError as exc:
                raise BundleError("destination exists; overwrite prohibited") from exc
    except Exception as exc:
        if private_dir is not None:
            private_dir.rmdir()
        if isinstance(exc, (OSError, TypeError, RuntimeError)):
            raise BundleError("cannot stage or exclusively publish viewer snapshot") from exc
        raise

    error = None
    if open_browser:
        try:
            if not _launch(target):
                error = "Default browser launch request was unsuccessful"
        except Exception as exc:
            error = f"Default browser launch failed: {exc}"
    return {"path": str(target), "captured_at_utc": payload["captured_at_utc"], "coverage": payload["coverage"],
            "preview_results": {key: {k: v for k, v in preview.items() if k != "base64"}
                                for key, preview in payload["previews"].items()},
            "browser_open_requested": open_browser, "launch_error": error}
