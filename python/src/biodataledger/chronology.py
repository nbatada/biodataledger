"""Read-only receipt history; presentation order is never inferred execution order."""
import copy

from .core import canonical, require
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
