"""Caller-declared naming and discovery for exact retained outputs."""
from copy import deepcopy
from datetime import date
from itertools import islice, zip_longest
from pathlib import Path
import os
import re
import shutil
import sys
import tempfile
from unicodedata import category, east_asian_width

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


_CONSOLE_CONTROLS = {"Cc", "Cf", "Cs", "Zl", "Zp"}


def _console_width(value):
    return sum(0 if category(c) in ("Mn", "Me") else
               2 if east_asian_width(c) in ("W", "F") else 1 for c in value)


def _console_label(value, width=72):
    label = "".join(" " if category(c) in _CONSOLE_CONTROLS else c for c in value).strip()
    if _console_width(label) <= width:
        return label
    prefix = label[:width - 3]
    while _console_width(prefix) > width - 3:
        prefix = prefix[:-1]
    return prefix.rstrip() + "..."


def _console_path(path):
    if path is None:
        return "Unresolved"
    if not any(category(c) in _CONSOLE_CONTROLS for c in path):
        return path
    escaped = "".join(f"\\u{{{ord(c):X}}}" if category(c) in _CONSOLE_CONTROLS
                      else "\\\\" if c == "\\" else c for c in path)
    return escaped + " [escaped; see exact getter for raw path]"


def _console_ref(record):
    return f"{record['id']}@{record['revision']}"


def _recent_records(project, kind, *, active_only=False):
    from .protocol import _timestamp

    stamps = {}
    rows = []
    # Stable sorting preserves reverse stored order for ties and unknown dates.
    for rec in reversed(project.state["records"]):
        if rec["kind"] != kind or project._latest_index[rec["id"]] is not rec:
            continue
        if active_only and rec["status"] != "active":
            continue
        value = rec["created_at"]
        if value not in stamps:
            stamps[value] = value if _timestamp(value) is not None else None
        rows.append((rec, stamps[value]))
    rows.sort(key=lambda row: row[1] or "", reverse=True)
    return rows


def _output_title(record, presentation):
    return (presentation and presentation["title"]) or record["name"]


def recent_figures(project, limit):
    rows = _recent_records(project, "figure", active_only=True)
    items = []
    for rec, stamp in rows[:limit]:
        _, descriptor = _read(rec)
        path = project._resolve(rec["locator"], lexical=True)
        items.append({"name": _output_title(rec, descriptor), "ref": project._ref(rec),
                      "recorded_at": stamp, "generated_on": descriptor["generated_on"] if descriptor else None,
                      "path": str(path) if path is not None else None,
                      "directory": str(path.parent) if path is not None else None,
                      "availability_checked": False})
    return {"items": items, "total": len(rows), "omitted": len(rows) - len(items)}


def recent_figure_lines(report):
    lines = []
    for item in report["items"]:
        lines += [f"  {_console_label(item['name']) or 'Unnamed figure'}",
                  f"    {_console_ref(item['ref'])} | Recorded (UTC) {_recorded_text(item['recorded_at'])}"]
        if item["generated_on"]:
            lines.append(f"    Recorded generation date {item['generated_on']}")
        lines += ["    File   " + _console_path(item["path"]),
                  "    Folder " + _console_path(item["directory"])]
    if not lines:
        return ["  None recorded"]
    if report["omitted"]:
        lines.append(f"  +{report['omitted']} more figures")
    return lines


def _recorded_text(stamp):
    return stamp[:-1].replace("T", " ") if stamp is not None else "Unknown"


def _analysis_output_labels(project, record, width):
    linked = {}
    for edge in project._lineage.adjacent(project._ref(record), "downstream", extended=True):
        if edge["type"] in ("produced_result", "transformation_context", "analytical_association"):
            # The index orders edges by target ID and then ascending target revision.
            ref = edge["to"]
            linked[ref["id"]] = ref
    labels = []
    for ref in islice(linked.values(), 2):
        output = project._record(ref)
        _, descriptor = _read(output)
        labels.append(_console_label(_output_title(output, descriptor), width) or "Unnamed output")
        flags = []
        if output["revision"] != project._latest_index[ref["id"]]["revision"]:
            flags.append("historical")
        if output["status"] != "active":
            flags.append(output["status"])
        if flags:
            labels.append(f"{_console_ref(ref)} ({', '.join(flags)})")
    if len(linked) > 2:
        labels.append(f"+{len(linked) - 2} more")
    return labels or ["None linked to this revision"]


def _analysis_table(project):
    analyses = _recent_records(project, "analysis")[:4]
    if not analyses:
        return ["  None recorded"]
    headings = ("Recorded (UTC)", "Ticket / analysis", "Recorded outputs")
    refs = [_console_ref(record) for record, _ in analyses]
    outputs = [_analysis_output_labels(project, record, 39) for record, _ in analyses]
    widths = (19, max(34, max(map(len, refs))),
              max(39, max(_console_width(line) for group in outputs for line in group)))
    border = "+" + "+".join("-" * (width + 2) for width in widths) + "+"

    def row(*values):
        cells = [value + " " * (width - _console_width(value)) for value, width in zip(values, widths)]
        return "| " + " | ".join(cells) + " |"

    lines = [border, row(*headings), border]
    for (record, stamp), ref, labels in zip(analyses, refs, outputs):
        ticket = record["details"].get("ticket_name")
        label = _console_label(ticket, widths[1]) if isinstance(ticket, str) else ""
        label = label or _console_label(record["name"], widths[1]) or "Unnamed analysis"
        lines.extend(row(*cells) for cells in zip_longest(
            [_recorded_text(stamp)], [label, ref], labels, fillvalue=""))
        lines.append(border)
    lines.append("Each output shows its latest linked revision for the exact analysis revision in that row.")
    return lines


def _console_scope(scope):
    if scope is None:
        return []
    fields = []
    for key, label in (("condition_values", "Conditions"), ("assignment_inclusion", "Assignment")):
        values = scope[key]
        if values:
            shown = ", ".join(_console_label(value, 24) for value in values[:3])
            if len(values) > 3:
                shown += f" (+{len(values) - 3} more)"
            fields.append(label + " " + shown)
    for key, label, width in (("assay", "Assay", 36), ("layer", "Layer", 36),
                              ("observation_unit", "Observation unit", 36), ("selection", "Selection", 64)):
        if scope[key]:
            fields.append(label + " " + _console_label(scope[key], width))
    return fields


def project_overview(project):
    info = project.state["project"]
    lines = ["BioDataLedger for — " + (_console_label(info["name"]) or "Unnamed project")]
    purpose = _console_label(info["purpose"] or "", 160)
    if purpose:
        lines.append(purpose)
    lines += ["", "Recent analyses", *_analysis_table(project), "",
              "Project folder", "  " + _console_path(str(project.root)),
              "", "Current input selections"]
    for purpose in project._purposes[:3]:
        rec = project._record(project.state["current"][purpose], "data")
        path = project._resolve(rec["locator"], lexical=True)
        lines += [f"  {_console_label(purpose)} — {_console_label(rec['name']) or 'Unnamed data'}"]
        scope = _console_scope(rec.get("scope"))
        if scope:
            lines.append("    Recorded scope — " + " | ".join(scope))
        lines += ["    File " + _console_path(str(path) if path is not None else None),
                  "    " + _console_ref(rec)]
    if not project._purposes:
        lines.append("  None recorded")
    elif len(project._purposes) > 3:
        lines.append(f"  +{len(project._purposes) - 3} more selections")
    return "\n".join([*lines, "", "Latest figure by registration (UTC)",
                      *recent_figure_lines(recent_figures(project, 1)), "",
                      "File availability not checked. More: p.help()"])


def project_help(project):
    from . import __version__

    return "\n".join([
        "BioDataLedger help",
        f"Package version: {__version__} | Registry revision: {project.state['state_revision']} | "
        f"Unsaved changes: {'yes' if project.unsaved else 'no'}",
        "",
        "Project overview         print(p)",
        "Technical status         p.status()",
        'Find a topic             p.find_outputs(topic="QC")',
        'Analysis inputs/outputs  p.get_info("ANA-001@1")',
        'Figure sources and code  p.get_info("FIG-001@1")',
        'Inspect data             p.get_data("DATA-001@1")',
        'Registration history     print(p.timeline_summary(order="newest"))',
        'Recorded runs            print(p.timeline_summary(view="runs", order="newest"))',
        "Recent figures & folders p.recent_figures()",
        'Current input choice     p.get_data(purpose="review")',
        'Full figure file path    p.get_figure("FIG-001@1").path',
        'Full data file path      p.get_data("DATA-001@1").path',
        "",
        "Use your project's exact references and recorded purposes.",
        "Registration dates describe registry entries. See recorded runs for wrapper execution evidence.",
        "Full API                 docs/API.md in the BioDataLedger source checkout",
    ])


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
