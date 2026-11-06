"""Caller-declared naming and discovery for exact retained outputs."""
from copy import deepcopy
from datetime import date
from pathlib import Path
import os
import re
import shutil
import sys
import tempfile

from .core import BundleError, _DEFAULT, _record_evidence, canonical, fingerprint, require, safe_relative
from .related_work import _clip

KEY = "biodataledger.presentation"
VERSION = "biodataledger-presentation/1"
OUTPUTS = ("data", "figure")
PREFIXES = {"data": "D", "figure": "F", "analysis": "A"}
ID_PREFIXES = {"D": "DATA", "F": "FIG", "A": "ANA"}
FIELDS = {"version", "primary_topic", "description", "generated_on", "topics",
          "questions", "uses", "title", "subtitle"}
OUTPUT_EDGES = {"produced_result", "transformation_context", "analytical_association",
                "parent_data", "artifact_container", "rendered_in_figure", "input_to_figure"}
DETAIL_BYTES = 16 * 1024


def _text(value, limit):
    return (isinstance(value, str) and 0 < len(value) <= limit and value.strip()
            and not re.search(r"[\x00-\x1f\x7f-\x9f\ud800-\udfff]", value)
            and len(value.encode("utf-8")) <= limit)


def _token(value, limit):
    return (isinstance(value, str) and len(value) <= limit
            and re.fullmatch(r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*", value))


def _day(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        return False
    try:
        date.fromisoformat(value)
        return True
    except ValueError:
        return False


def _valid_use(item):
    return (isinstance(item, dict) and set(item) == {"kind", "document_id", "item_id", "title"}
            and item["kind"] in ("slide", "manuscript") and _text(item["document_id"], 128)
            and _text(item["item_id"], 128) and _text(item["title"], 256))


def _validate(desc):
    require(isinstance(desc, dict) and set(desc) == FIELDS and desc["version"] == VERSION,
            "invalid presentation descriptor")
    require(_token(desc["primary_topic"], 64), "primary_topic must be an ASCII topic token (max 64)")
    require(_token(desc["description"], 96), "description must be an ASCII filename token (max 96)")
    require(_day(desc["generated_on"]), "generated_on must be a real YYYY-MM-DD date")
    topics, questions, uses = (desc[key] for key in ("topics", "questions", "uses"))
    require(isinstance(topics, list) and 1 <= len(topics) <= 8
            and all(_token(topic, 64) for topic in topics) and topics[0] == desc["primary_topic"]
            and len({topic.lower() for topic in topics}) == len(topics), "invalid presentation topics")
    require(isinstance(questions, list) and len(questions) <= 8 and all(_text(q, 256) for q in questions),
            "questions must contain up to 8 nonblank strings (256 UTF-8 bytes each)")
    require(isinstance(uses, list) and len(uses) <= 8 and all(_valid_use(use) for use in uses),
            "uses must contain up to 8 slide/manuscript declarations with document_id, item_id and title")
    require(all(desc[key] is None or _text(desc[key], 256) for key in ("title", "subtitle")),
            "title/subtitle must be null or nonblank text (256 UTF-8 bytes each)")


def _read(rec):
    if rec["kind"] not in OUTPUTS:
        return "not_applicable", None
    if KEY not in rec["details"]:
        return "missing", None
    desc = rec["details"][KEY]
    if not isinstance(desc, dict) or not _text(desc.get("version"), 128):
        return "invalid", None
    if desc["version"] != VERSION:
        return "unsupported", None
    try:
        _validate(desc)
    except BundleError:
        return "invalid", None
    return "declared", desc


def presentation_only_change(rec, changes):
    """Allow a presentation revision without changing any membership binding."""
    if set(changes) != {"details"} or not isinstance(changes["details"], dict):
        return False
    before, after = rec["details"], changes["details"]
    if _read({**rec, "details": after})[0] != "declared":
        return False
    return canonical({k: v for k, v in before.items() if k != KEY}) == canonical(
        {k: v for k, v in after.items() if k != KEY})


def _record(project, ref):
    if isinstance(ref, str):
        match = re.fullmatch(r"([DFA])([0-9]{3,})r([1-9][0-9]*)", ref)
        if match:
            prefix, number, revision = match.groups()
            ref = f"{ID_PREFIXES[prefix]}-{number}@{revision}"
    rec = project._record(ref)
    require(rec["kind"] in PREFIXES, "DATA, FIG or ANA reference required")
    return rec


def _key(rec):
    return f'{PREFIXES[rec["kind"]]}{rec["id"].split("-", 1)[1]}r{rec["revision"]}'


def _project(project):
    return {k: project.state["project"][k] for k in ("id", "name")}


def set_presentation(project, ref, *, primary_topic, description, generated_on, topics,
                     questions, uses, title, subtitle, reason):
    rec = _record(project, ref)
    require(rec["kind"] in OUTPUTS, "presentation requires DATA or FIG")
    require(project._latest_index[rec["id"]]["revision"] == rec["revision"],
            "set_presentation requires the latest exact revision")
    require(_text(reason, 512), "nonblank reason required (max 512 UTF-8 bytes)")
    require(_token(primary_topic, 64), "primary_topic must be an ASCII topic token (max 64)")
    _, prior = _read(rec)
    prior = prior or {}
    topics = prior.get("topics", [])[1:] if topics is _DEFAULT else topics
    questions = prior.get("questions") if questions is _DEFAULT else questions
    uses = prior.get("uses") if uses is _DEFAULT else uses
    title = prior.get("title") if title is _DEFAULT else title
    subtitle = prior.get("subtitle") if subtitle is _DEFAULT else subtitle
    topics = [] if topics is None else topics
    require(isinstance(topics, list) and len(topics) <= 8 and all(_token(t, 64) for t in topics),
            "topics must contain up to 8 ASCII topic tokens (64 bytes each)")
    tags = {primary_topic.lower(): primary_topic}
    for topic in topics:
        tags.setdefault(topic.lower(), topic)
    desc = {"version": VERSION, "primary_topic": primary_topic, "description": description,
            "generated_on": generated_on, "topics": list(tags.values()),
            "questions": [] if questions is None else questions, "uses": [] if uses is None else uses,
            "title": title, "subtitle": subtitle}
    _validate(desc)
    if desc == rec["details"].get(KEY):
        return project._ref(rec)
    return project.update_record(project._ref(rec), {"details": {**rec["details"], KEY: desc}}, reason)


def output_name(project, ref):
    rec = _record(project, ref)
    require(rec["kind"] in OUTPUTS, "output_name requires DATA or FIG")
    status, desc = _read(rec)
    require(status == "declared", "output presentation is " + status)
    loc = rec["locator"]
    require(loc is not None and loc["kind"] in ("project", "external") and rec["size"] is not None,
            "recorded local file locator required")
    base = loc["value"].replace("\\", "/").rsplit("/", 1)[-1]
    suffix = re.search(r"(?i)\.tar\.gz\Z", base) or re.search(r"\.[A-Za-z0-9]{1,16}\Z", base)
    require(suffix is not None and suffix.start() > 0 and base[:suffix.start()].strip("."),
            "recorded file needs an ordinary extension or .tar.gz")
    key = _key(rec)
    filename = "_".join((desc["generated_on"].replace("-", ""), desc["primary_topic"], key,
                         desc["description"])) + suffix.group()
    require(len(filename.encode("utf-8")) <= 255, "generated filename exceeds 255 bytes")
    return {**deepcopy(desc), "ref": project._ref(rec), "project": _project(project), "kind": rec["kind"],
            "output_key": key, "filename": filename, "tag": f'{desc["primary_topic"]}:{key}'}


def _limits(limit, offset):
    require(type(limit) is int and 1 <= limit <= 100 and type(offset) is int and 0 <= offset <= 2**53 - 1,
            "limit must be 1–100; offset must be a nonnegative integer")


def _page(values, limit, offset):
    total = len(values)
    end = offset + limit
    return {"items": values[offset:end], "total": total, "offset": offset,
            "next_offset": end if end < total else None, "truncated": (total > 0 and offset > 0) or end < total}


def _brief(project, rec):
    name, clipped = _clip(rec["name"], 192)
    return {"ref": project._ref(rec), "kind": rec["kind"], "output_key": _key(rec),
            "name": name, "name_clipped": clipped}


def _summary(project, rec, status, desc):
    return {**_brief(project, rec),
            "record_status": rec["status"], "presentation_status": status, "presentation": deepcopy(desc)}


def _record_page(project, refs, limit, offset):
    result = _page(refs or [], limit, offset)
    result["items"] = [_brief(project, project._record(ref)) for ref in result["items"]]
    return result


def find_outputs(project, topic, question, query, kind, document_id, limit, offset, historical):
    _limits(limit, offset)
    require(type(historical) is bool, "historical must be boolean")
    require(topic is None or _token(topic, 64), "topic must be an ASCII topic token")
    require(question is None or _text(question, 256), "question must be nonblank text")
    require(query is None or _text(query, 256), "query must be nonblank text")
    require(document_id is None or _text(document_id, 128), "document_id must be nonblank text")
    if isinstance(kind, str):
        kind = {"data": "data", "fig": "figure", "figure": "figure"}.get(kind.lower(), kind)
    require(kind is None or kind in OUTPUTS, "kind must be DATA or FIG")
    needle = topic.lower() if topic is not None else None
    folded_question = question.casefold() if question is not None else None
    terms = query.casefold().split() if query is not None else ()
    statuses = dict.fromkeys(("declared", "missing", "invalid", "unsupported"), 0)
    matches = []
    records = project.state["records"] if historical else project._latest_index.values()
    for rec in records:
        if rec["kind"] not in OUTPUTS or kind is not None and rec["kind"] != kind:
            continue
        status, desc = _read(rec)
        statuses[status] += 1
        if any(x is not None for x in (topic, question, query, document_id)):
            if desc is None:
                continue
            if needle is not None and not any(t.lower() == needle or t.lower().startswith(needle + "-")
                                              for t in desc["topics"]):
                continue
            if folded_question is not None and not any(folded_question in q.casefold() for q in desc["questions"]):
                continue
            if document_id is not None and not any(u["document_id"] == document_id for u in desc["uses"]):
                continue
            if terms:
                fields = [*desc["topics"], *desc["questions"], desc["description"], desc["title"] or "",
                          desc["subtitle"] or "", *(u[k] for u in desc["uses"] for k in ("title", "document_id", "item_id"))]
                fields = [f.casefold() for f in fields]
                if not all(any(term in f for f in fields) for term in terms):
                    continue
        day = int(desc["generated_on"].replace("-", "")) if desc is not None else 0
        matches.append((-day, rec["id"], -rec["revision"], rec, status, desc))
    matches.sort(key=lambda match: match[:3])
    result = _page(matches, limit, offset)
    result["items"] = [_summary(project, rec, status, desc) for _, _, _, rec, status, desc in result["items"]]
    return {"project": _project(project), "historical": historical, "presentation_status_counts": statuses, **result}


def _figure_info(project, rec, owner, limit, offset):
    from .figure_sources import KEY as SOURCE_KEY, normalize, recognized

    value = rec["details"].get(SOURCE_KEY)
    source_status = "missing"
    descriptor = {}
    if recognized(value):
        try:
            descriptor = normalize(value, project, require, safe_relative)
            source_status = "declared"
        except BundleError:
            source_status = "invalid"
    elif SOURCE_KEY in rec["details"]:
        source_status = "unsupported" if isinstance(value, dict) and isinstance(value.get("version"), str) else "invalid"

    def code(selector):
        entry = project._record(selector["record"])["code"][selector["index"]]
        return {"selector": selector, **entry, "integrity": "not_checked", "availability_checked": False}

    selection = descriptor.get("generating_code")
    candidates = _page(range(len(owner["code"])), limit, offset)
    candidates["items"] = [code({"record": project._ref(owner), "index": i, "sha256": owner["code"][i]["sha256"],
                                "registered_ref": None}) for i in candidates["items"]]
    rendering = descriptor.get("rendering_inputs")
    return deepcopy({
        "plotting_code": {"status": "declared" if selection is not None else "unknown", "source_status": source_status,
                          "generating_code": code(selection) if selection is not None else None, "candidates": candidates},
        "rendering_inputs": {"status": "recorded" if rendering is not None else "unknown",
                             "relationship": descriptor.get("relationship", "unknown"),
                             **_record_page(project, rendering, limit, offset)},
    })


def _bounded_detail(value):
    if value is None:
        return None, "unknown"
    if len(canonical(value)) > DETAIL_BYTES:
        return None, "size_limit"
    return deepcopy(value), "included"


def get_info(project, ref, limit, offset):
    _limits(limit, offset)
    rec = _record(project, ref)
    exact = project._ref(rec)
    producer = rec["analysis"] if rec["kind"] == "figure" else (rec.get("scope") or {}).get("transformation_ref")
    source = project._record(producer, "analysis") if producer else rec if rec["kind"] != "data" else None
    inputs = source["inputs"] if source is not None else None
    outputs = [edge for edge in project._lineage.adjacent(exact, "downstream", extended=True)
               if edge["type"] in OUTPUT_EDGES]
    output_page = _page(outputs, limit, offset)
    output_page["items"] = [{**edge, "output": _brief(project, project._record(edge["to"]))}
                            for edge in output_page["items"]]
    status, desc = _read(rec)
    recorded, record_status = _bounded_detail({k: v for k, v in rec.items() if k != "inputs"})
    context = ({**{k: source.get(k) for k in ("code", "method", "params", "design", "input_mode")},
                "ref": project._ref(source), "evidence": _record_evidence(source)}
               if source is not None else None)
    context, source_status = _bounded_detail(context)
    figure = (_figure_info(project, rec, source, limit, offset) if rec["kind"] == "figure"
              else {"plotting_code": None, "rendering_inputs": None})
    return {**_summary(project, rec, status, desc), "project": _project(project),
            "record": recorded, "record_fields_status": record_status,
            "analytical_source": context, "analytical_source_status": source_status,
            "analytical_source_ref": project._ref(source) if source is not None else None,
            "producer_ref": deepcopy(producer), "producer": _brief(project, source) if producer else None,
            "availability_checked": False, **figure,
            "inputs": {"status": "unknown" if inputs is None else "recorded",
                       **_record_page(project, inputs, limit, offset)},
            "outputs": deepcopy(output_page)}


def export_named_output(project, ref, destination_dir):
    require(sys.platform == "darwin", "named output writes currently require macOS")
    report = output_name(project, ref)
    rec = project._record(report["ref"])
    require(rec["sha256"] is not None, "MISSING_DIGEST: registered SHA-256 required")
    source = project._resolve(rec["locator"])
    require(source is not None and source.is_file(), "registered source file missing or not a regular file")
    try:
        directory = Path(destination_dir).expanduser().resolve(strict=True)
        require(directory.is_dir(), "existing destination directory required")
        target = directory / report["filename"]
        require(not target.exists() and not target.is_symlink(), "destination exists; overwrite prohibited")
        with tempfile.NamedTemporaryFile(prefix=".bdl-output-", dir=directory) as staged:
            with source.open("rb") as reader:
                shutil.copyfileobj(reader, staged, length=1024 * 1024)
            staged.flush()
            observed = fingerprint(staged.name)
            require(observed == rec["sha256"].lower(), "DIGEST_MISMATCH: copy differs from exact source revision")
            try:
                os.link(staged.name, target)
            except FileExistsError as exc:
                raise BundleError("destination exists; overwrite prohibited") from exc
    except (OSError, TypeError, RuntimeError) as exc:
        raise BundleError("cannot stage or exclusively publish named output") from exc
    return {"project": report["project"], "ref": report["ref"], "path": str(target),
            "filename": report["filename"], "sha256": observed, "integrity": "match"}
