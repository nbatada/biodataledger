"""Read-only receipt history; presentation order is never inferred execution order."""
import copy
import uuid

from .core import canonical, require
from .execution import _validated_receipt
from .protocol import _timestamp

VERSION = "biodataledger-chronology/1"
MAX_SCAN = 1000
MAX_BYTES = 64 * 1024
MAX_EXPANDED = 1024 * 1024
PRESENTATION = "reverse_registration_slots_not_execution_or_dependency_or_protocol_order"


def _unknown(project, record, reason):
    ref = project._ref(record)
    return {"analysis_ref": ref, "receipt_ref": copy.deepcopy(ref), "evidence": "unknown", "reason": reason}


def _receipt_timing(receipt):
    start, end = _timestamp(receipt["started_at_utc"]), _timestamp(receipt["ended_at_utc"])
    if receipt["status"] == "started":
        return "open" if start is not None else "invalid"
    if receipt["status"] == "blocked" or not receipt["phases"]["execution_started"]:
        return "not_executed"
    return "valid_interval" if start is not None and end is not None and start <= end else "invalid"


def _entry(project, record):
    receipt = project.get_execution(project._ref(record))
    if receipt["status"] == "unknown":
        return _unknown(project, record, receipt["reason"])
    timing = _receipt_timing(receipt)
    return {"analysis_ref": project._ref(record), "receipt_ref": copy.deepcopy(receipt["receipt_ref"]),
            "run_ref": copy.deepcopy(receipt["run_ref"]), "template_ref": copy.deepcopy(receipt["template_ref"]),
            "registration_at_utc": record["created_at"], "started_at_utc": receipt["started_at_utc"],
            "ended_at_utc": receipt["ended_at_utc"], "outcome": receipt["status"], "timing_status": timing,
            "evidence": "untrusted_imported" if project.state["imported"] else "recorded"}


def _relations(entries):
    intervals = [(_timestamp(e["started_at_utc"]), _timestamp(e["ended_at_utc"]))
                 if e.get("timing_status") == "valid_interval" and e["evidence"] == "recorded" else None
                 for e in entries]
    result = []
    for left, a in enumerate(intervals):
        for right in range(left + 1, len(intervals)):
            b, relation = intervals[right], "unknown"
            if a is not None and b is not None:
                if a[1] < b[0]: relation = "before"
                elif b[1] < a[0]: relation = "after"
                elif a == b: relation = "tied"
                elif a[1] == b[0] or b[1] == a[0]: relation = "tied_boundary"
                else: relation = "overlap"
            result.append({"left": left + 1, "right": right + 1, "relation": relation})
    return result


def _selection(project, analysis_ref, protocol_ref):
    selector, targets, run_id = {"kind": "project"}, None, None
    if analysis_ref is not None:
        record = project._record(analysis_ref, "analysis")
        selector = {"kind": "analysis_ref", "analysis_ref": project._ref(record)}
        targets = [selector["analysis_ref"]]
        run_id = record["id"] if "execution_receipt" in record["details"] else None
    elif protocol_ref is not None:
        view = project.get_protocol(protocol_ref)
        require(view["protocol"] is not None, "protocol unavailable")
        steps = view["protocol"]["steps"]
        targets = [step["analysis_ref"] for step in steps]
        displayed = []
        for step in steps[:20]:
            item = {"step_id": step["step_id"], "analysis_ref": step["analysis_ref"]}
            if len(canonical(displayed + [item])) > 4096: break
            displayed.append(copy.deepcopy(item))
        selector = {"kind": "protocol_ref", "protocol_ref": view["ref"], "steps": displayed,
                    "omitted_steps": len(steps) - len(displayed), "order_evidence": "declared_intent_not_approval"}
    return selector, targets, run_id


def _report(project, selector, entries, offset, cursor, total, reason):
    more = cursor < total
    return {"report_version": VERSION, "selector": selector, "registry_revision": project.state["state_revision"],
            "unsaved": project.unsaved, "imported_claim": "untrusted_imported_claim" if project.state["imported"] else None,
            "scan": {"offset": offset, "scanned": cursor - offset, "total_record_slots": total,
                     "next_offset": cursor if more else None, "truncated": more, "stop_reason": reason},
            "presentation_order": PRESENTATION, "evidence_scope": "recorded_receipts_only_not_complete_execution_history",
            "entries": entries, "relations": _relations(entries)}


def execution_history(project, analysis_ref=None, protocol_ref=None, limit=10, offset=0):
    """Read a bounded page from a fixed loaded registry, without file I/O or mutation."""
    require(analysis_ref is None or protocol_ref is None, "choose at most one selector")
    require(type(limit) is int and 1 <= limit <= 20, "limit must be an integer from 1 to 20")
    require(type(offset) is int and 0 <= offset <= 2147483647, "offset must be a nonnegative 32-bit integer")
    selector, targets, run_id = _selection(project, analysis_ref, protocol_ref)
    records, entries, expanded = project.state["records"], [], 0
    total, cursor, reason = len(records), offset, "end"
    while cursor < total and cursor - offset < MAX_SCAN and len(entries) < limit:
        record = records[total - 1 - cursor]
        if (record["kind"] != "analysis" or project._latest_index[record["id"]] is not record
                or "execution_receipt" not in record["details"]):
            cursor += 1
            continue
        raw = record["details"]["execution_receipt"]
        matches = targets is None or record["id"] == run_id or isinstance(raw, dict) and raw.get("template_ref") in targets
        if not matches:
            cursor += 1
            continue
        size = len(canonical(record))
        if size > MAX_BYTES:
            entry = _unknown(project, record, "metadata_limit")
        else:
            if expanded + size > MAX_EXPANDED:
                reason = "metadata_budget"
                break
            expanded += size
            entry = _entry(project, record)
        candidate = _report(project, selector, entries + [entry], offset, cursor + 1, total, "end")
        if len(canonical(candidate)) > MAX_BYTES:
            if entries:
                reason = "report_limit"
                break  # The unreturned candidate remains at next_offset.
            entry = _unknown(project, record, "report_limit")
        entries.append(entry)
        cursor += 1
    if reason == "end" and cursor < total:
        reason = "limit" if len(entries) == limit else "scan_limit"
    report = _report(project, selector, entries, offset, cursor, total, reason)
    require(len(canonical(report)) <= MAX_BYTES, "chronology report exceeds 64 KiB")
    return report


def execution_history_summary(project, **kwargs):
    report = execution_history(project, **kwargs)
    header = "Recorded receipt history; reverse registration slots, not a total execution/dependency/protocol order."
    rows = []
    for index, entry in enumerate(report["entries"], 1):
        ref = entry["receipt_ref"]
        row = "[" + str(index) + "] " + ref["id"] + "@" + str(ref["revision"]) + ": " + entry.get("outcome", entry.get("reason", "unknown"))
        row += "; evidence=" + entry["evidence"]
        if "started_at_utc" in entry:
            row += "; start=" + entry["started_at_utc"] + "; end=" + (entry["ended_at_utc"] or "unknown")
            row += "; timing=" + entry["timing_status"]
        rows.append(row)
    count = len(rows)
    while True:
        footer = "Summary omitted " + str(len(rows) - count) + " entries; next_offset="
        footer += str(report["scan"]["next_offset"]) if report["scan"]["next_offset"] is not None else "none"
        footer += "; absent records do not prove no execution."
        relations = [str(item["left"]) + "-" + str(item["right"]) + "=" + item["relation"]
                     for item in report["relations"] if item["right"] <= count]
        relation_line = "Relations among shown rows: " + (", ".join(relations) or "none")
        text = "\n".join([header] + rows[:count] + [relation_line, footer])
        if len(text.encode("utf-8")) <= 4096: return text
        count -= 1


def _timeline_receipt_timing(receipt):
    if receipt is None:
        return "unknown"
    timing = _receipt_timing(receipt)
    if timing == "valid_interval" and not receipt["phases"]["code_executed"]:
        return "code_not_executed"
    return timing


def _timeline_index(project, view):
    slots, parsed = [], {}
    for position, record in enumerate(project.state["records"]):
        timing = None
        if view == "registration":
            stamp = record["created_at"]
            if stamp not in parsed:
                parsed[stamp] = stamp if _timestamp(stamp) is not None else None
            stamp = parsed[stamp]
        else:
            if (record["kind"] != "analysis" or project._latest_index[record["id"]] is not record
                    or "execution_receipt" not in record["details"]):
                continue
            receipt = _validated_receipt(project, record)
            timing = _timeline_receipt_timing(receipt)
            stamp = receipt["started_at_utc"] if timing == "valid_interval" and not project.state["imported"] else None
        slots.append((position, stamp, timing))
    records = project.state["records"]
    slots.sort(key=lambda slot: (records[slot[0]]["id"], records[slot[0]]["revision"]))
    known = [slot for slot in slots if slot[1] is not None]
    unknown = [slot for slot in slots if slot[1] is None]
    return {order: sorted(known, key=lambda slot: slot[1], reverse=order == "newest") + unknown
            for order in ("oldest", "newest")}


def _timeline_row(project, view, slot):
    position, stamp, timing = slot
    record = project.state["records"][position]
    receipt = None
    if record["kind"] == "analysis" and "execution_receipt" in record["details"]:
        if view == "registration":
            receipt = _validated_receipt(project, record)
        elif timing != "unknown":
            receipt = record["details"]["execution_receipt"]
    evidence = None
    if record["kind"] == "analysis":
        evidence = "unknown" if receipt is None else "untrusted_imported" if project.state["imported"] else "recorded"
    analysis = record["analysis"]
    if isinstance(analysis, str):
        analysis = project._ref(project._record(analysis))
    row = {"ref": project._ref(record), "kind": record["kind"], "time_utc": stamp,
           "evidence": evidence, "outcome": receipt["status"] if receipt is not None else None,
           "analysis_ref": analysis, "omitted_text_fields": []}
    texts = {"name": record["name"], "registration_at_utc": record["created_at"]}
    links = {"input_refs": record["inputs"]}
    if view == "runs":
        row.update(run_ref=None, template_ref=None, timing_status=timing)
        texts.update(started_at_utc=None, ended_at_utc=None)
        links["output_refs"] = None
        if receipt is not None:
            row.update(run_ref=receipt["run_ref"], template_ref=receipt["template_ref"])
            texts.update(started_at_utc=receipt["started_at_utc"], ended_at_utc=receipt["ended_at_utc"])
            links["output_refs"] = [item["record_ref"] for item in receipt["outputs"] if item["status"] == "registered"]
    for field, value in texts.items():
        if value is not None and (len(value) > 256 or len(value.encode("utf-8")) > 256):
            row["omitted_text_fields"].append(field)
            value = None
        row[field] = value
    for field, refs in links.items():
        shown = None
        if refs is not None:
            shown = [project._ref(project._record(ref)) if isinstance(ref, str) else ref for ref in refs[:10]]
            shown = [ref for ref in shown if len(canonical(ref)) <= 512]
        row[field] = shown
        row[field + "_omitted"] = len(refs) - len(shown) if shown is not None else 0
    return row


def timeline(project, view="registration", order="oldest", limit=10, cursor=None):
    """Read a globally ordered page from this loaded instance's metadata."""
    require(isinstance(view, str) and view in ("registration", "runs"), "view must be registration or runs")
    require(isinstance(order, str) and order in ("oldest", "newest"), "order must be oldest or newest")
    require(type(limit) is int and 1 <= limit <= 20, "limit must be an integer from 1 to 20")
    state = project.state
    generation = (state["state_revision"], state["last_transaction"], len(state["records"]), len(state["history"]))
    if project._timeline_cache is None or project._timeline_cache[0] != generation:
        project._timeline_cache = (generation, str(uuid.uuid4()), {})
    _, snapshot, indexes = project._timeline_cache
    prefix = f"{snapshot}:{view}:{order}:"
    offset = 0
    if cursor is not None:
        require(isinstance(cursor, str) and cursor.startswith(prefix), "stale or invalid timeline cursor; restart paging")
        value = cursor[len(prefix):]
        require(0 < len(value) <= 10 and value.isascii() and value.isdecimal(), "invalid timeline cursor offset")
        offset = int(value)
    if view not in indexes:
        indexes[view] = _timeline_index(project, view)
    slots = indexes[view][order]
    require(cursor is None or 0 < offset < len(slots), "invalid timeline cursor offset")
    rows, used = [], 0
    for slot in slots[offset:offset + limit]:
        row = _timeline_row(project, view, slot)
        size = len(canonical(row)) + 1
        # Leave room for report metadata and up to 190 pairwise relations.
        if used + size > MAX_BYTES - 12288:
            require(rows, "timeline row exceeds report limit; retrieve the exact record")
            break
        rows.append(row)
        used += size
    end = offset + len(rows)
    report = {"report_version": "biodataledger-timeline/1", "view": view, "order": order, "timezone": "UTC",
              "registry_revision": state["state_revision"], "unsaved": project.unsaved,
              "imported_claim": "untrusted_imported_claim" if state["imported"] else None,
              "total_rows": len(slots), "rows": rows, "relations": _relations(rows) if view == "runs" else [],
              "next_cursor": prefix + str(end) if end < len(slots) else None}
    require(len(canonical(report)) <= MAX_BYTES, "timeline report exceeds 64 KiB")
    return copy.deepcopy(report)


def _timeline_ref(ref):
    return f"{ref['id']}@{ref['revision']}"


def timeline_summary(report):
    runs = report["view"] == "runs"
    heading = "Recorded runs by wrapper start" if runs else "Record revisions by registration time"
    lines = [f"{heading} (UTC, {report['order']} first)"]
    if report["imported_claim"]:
        lines.append("Imported metadata. Receipt claims are untrusted.")
    unknown_heading = False
    for number, row in enumerate(report["rows"], 1):
        stamp = row["time_utc"] or "UNKNOWN"
        if row["time_utc"] is None and not unknown_heading:
            lines.append("Time unknown or unqualified")
            unknown_heading = True
        name = canonical(row["name"]).decode("utf-8") if row["name"] is not None else "[name omitted]"
        evidence = row["evidence"]
        status = row["outcome"] or ("execution UNKNOWN" if evidence == "unknown" else row["kind"])
        line = f"[{number}] {stamp}  {_timeline_ref(row['ref'])}  {name}  {status}"
        if row["outcome"]:
            line += f" ({evidence.replace('_', ' ')})"
        lines.append(line)
        if runs:
            if row["run_ref"] is not None:
                lines.append(f"    Run {_timeline_ref(row['run_ref'])} | Template {_timeline_ref(row['template_ref'])}")
            start = row["started_at_utc"]
            end = row["ended_at_utc"]
            start = canonical(start).decode("utf-8") if start is not None else "UNKNOWN"
            end = canonical(end).decode("utf-8") if end is not None else "UNKNOWN"
            lines.append(f"    Wrapper start {start} | End {end} | {row['timing_status'].replace('_', ' ')}")
        elif row["analysis_ref"] is not None:
            lines.append(f"    Analysis {_timeline_ref(row['analysis_ref'])}")
        for field, label in (("input_refs", "Declared inputs"), ("output_refs", "Registered outputs")):
            refs = row.get(field)
            if refs is None:
                continue
            linked = ", ".join(map(_timeline_ref, refs)) or "none shown"
            omitted = row[field + "_omitted"]
            lines.append(f"    {label} {linked}" + (f" ({omitted} omitted)" if omitted else ""))
    if runs:
        relations = [f"{pair['left']}-{pair['right']} {pair['relation'].replace('_', ' ')}"
                     for pair in report["relations"] if pair["relation"] in ("overlap", "tied", "tied_boundary")]
        if relations:
            lines.append("Overlaps or ties on this page: " + ", ".join(relations))
        lines.append("Wrapper intervals are partial evidence. Unrecorded execution remains unknown.")
    else:
        lines.append("Registration times describe record revisions. Equal times share the same displayed time.")
    lines.append(f"Next cursor: {report['next_cursor'] or 'none'}")
    return "\n".join(lines)
