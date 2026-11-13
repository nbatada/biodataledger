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
            if view == "analyses":
                if record["kind"] != "analysis":
                    continue
                has_receipt = "execution_receipt" in record["details"]
                receipt = _validated_receipt(project, record) if has_receipt else None
                # One latest receipt revision per run ID; ordinary revisions remain inspectable.
                if has_receipt and project._latest_index[record["id"]] is not record:
                    continue
                timing = _timeline_receipt_timing(receipt)
                stamp = (receipt["started_at_utc"] if receipt is not None and timing == "valid_interval"
                         and not project.state["imported"] else record["created_at"] if not has_receipt else None)
                if stamp not in parsed:
                    parsed[stamp] = stamp if _timestamp(stamp) is not None else None
                stamp = parsed[stamp]
                slots.append((position, stamp, timing))
                continue
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


def _timeline_refs(project, refs, limit=10):
    shown = [project._ref(project._record(ref)) if isinstance(ref, str) else ref for ref in refs[:limit]]
    shown = [ref for ref in shown if len(canonical(ref)) <= 512]
    return shown, len(refs) - len(shown)


def _analysis_consumers(project, outputs):
    consumers, mappings, remaining = [], [], 100
    display_remaining = 10
    cutoff = False
    for output in outputs:
        linked, truncated = [], False
        if remaining == 0:
            mappings.append({"output_ref": output, "analysis_refs": [], "analysis_refs_omitted": 0,
                             "scan_truncated": True})
            cutoff = True
            continue
        for edge in project._lineage.adjacent(output, "downstream", extended=True):
            if remaining == 0:
                truncated = True
                cutoff = True
                break
            remaining -= 1
            if edge["type"] == "input_to_analysis":
                consumers.append(edge["to"])
                linked.append(edge["to"])
        shown, omitted = _timeline_refs(project, linked, display_remaining)
        display_remaining -= len(shown)
        mappings.append({"output_ref": output, "analysis_refs": shown, "analysis_refs_omitted": omitted,
                         "scan_truncated": truncated})
    unique = []
    for ref in consumers:
        if ref not in unique:
            unique.append(ref)
    flat, omitted = _timeline_refs(project, unique)
    return flat, omitted, cutoff, mappings


def _analysis_links(project, record, receipt, receipt_claim):
    if receipt is not None:
        return ([item["record_ref"] for item in receipt["outputs"] if item["status"] == "registered"], [], False)
    if receipt_claim:
        return [], [], False
    produced, figures, scanned = [], [], 0
    for edge in project._lineage.adjacent(project._ref(record), "downstream", extended=True):
        scanned += 1
        if scanned > 100:
            break
        if edge["type"] in ("produced_result", "transformation_context") and edge["basis"] == "declared":
            produced.append(edge["to"])
        elif edge["type"] == "analytical_association":
            figures.append(edge["to"])
    return produced, figures, scanned > 100


def _timeline_item(project, ref):
    from .presentation import _output_title, _read
    from .related_work import _clip
    record = project._record(ref)
    _, descriptor = _read(record) if record["kind"] in ("data", "figure") else (None, None)
    name, clipped = _clip(_output_title(record, descriptor), 192)
    stamp = record["created_at"]
    return {"ref": project._ref(record), "kind": record["kind"], "name": name, "name_clipped": clipped,
            "record_status": record["status"],
            "revision_status": "latest" if project._latest_index[record["id"]] is record else "historical",
            "registration_at_utc": stamp if _timestamp(stamp) is not None else None}


def _analysis_name(record):
    ticket = record["details"].get("ticket_name")
    return ticket if isinstance(ticket, str) and ticket else record["name"]


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
    texts = {"name": _analysis_name(record) if view == "analyses" and record["kind"] == "analysis" else record["name"], "registration_at_utc": record["created_at"]}
    links = {"input_refs": record["inputs"]}
    if view in ("runs", "analyses"):
        row.update(run_ref=None, template_ref=None, timing_status=timing)
        texts.update(started_at_utc=None, ended_at_utc=None)
        links["output_refs"] = None
        if receipt is not None:
            row.update(run_ref=receipt["run_ref"], template_ref=receipt["template_ref"])
            texts.update(started_at_utc=receipt["started_at_utc"], ended_at_utc=receipt["ended_at_utc"])
            links["output_refs"] = [item["record_ref"] for item in receipt["outputs"] if item["status"] == "registered"]
    if view == "analyses":
        row["record_status"] = record["status"]
        row["revision_status"] = "latest" if project._latest_index[record["id"]] is record else "historical"
        row["time_source"] = ("wrapper_start" if receipt is not None and row["time_utc"] == receipt["started_at_utc"]
                              else "registration" if "execution_receipt" not in record["details"] else "unqualified")
        outputs, figures, cutoff = _analysis_links(project, record, receipt, "execution_receipt" in record["details"])
        links["output_refs"], links["associated_figure_refs"] = outputs, figures
        row["output_scan_truncated"] = cutoff
    for field, value in texts.items():
        if value is not None and (len(value) > 256 or len(value.encode("utf-8")) > 256):
            row["omitted_text_fields"].append(field)
            value = None
        row[field] = value
    for field, refs in links.items():
        shown = None
        if refs is not None:
            shown, omitted = _timeline_refs(project, refs)
        row[field] = shown
        row[field + "_omitted"] = omitted if shown is not None else 0
    if view == "analyses":
        outputs = row["output_refs"] or []
        row["output_items"] = [_timeline_item(project, ref) for ref in outputs]
        row["input_items"] = [_timeline_item(project, ref) for ref in row["input_refs"] or []]
        row["associated_figure_items"] = [_timeline_item(project, ref) for ref in row["associated_figure_refs"] or []]
        data_outputs = [item["ref"] for item in row["output_items"] if item["kind"] == "data"]
        consumers, omitted, cutoff, mappings = _analysis_consumers(project, data_outputs)
        row["downstream_analysis_refs"], row["downstream_analysis_refs_omitted"] = consumers, omitted
        row["downstream_scan_truncated"] = cutoff
        row["output_consumers"] = mappings
    return row


def timeline(project, view="registration", order="oldest", limit=10, cursor=None):
    """Read a globally ordered page from this loaded instance's metadata."""
    require(isinstance(view, str) and view in ("registration", "runs", "analyses"), "view must be registration, runs or analyses")
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
              "total_rows": len(slots), "rows": rows, "relations": _relations(rows) if view in ("runs", "analyses") else [],
              "next_cursor": prefix + str(end) if end < len(slots) else None}
    require(len(canonical(report)) <= MAX_BYTES, "timeline report exceeds 64 KiB")
    return copy.deepcopy(report)


def _timeline_ref(ref):
    return f"{ref['id']}@{ref['revision']}"


def _analysis_summary_lines(row):
    from .presentation import _console_label

    def stamp(value):
        return value if _timestamp(value) is not None else "UNKNOWN"

    def item_text(item):
        label = _console_label(item["name"], 48)
        if item["name_clipped"] and not label.endswith("..."):
            label += "..."
        flags = _analysis_flags(item)
        return f"{_timeline_ref(item['ref'])} {label}{flags} [Registered {stamp(item['registration_at_utc'])}]"

    lines = ["    Input " + item_text(item) for item in row["input_items"]]
    if not lines:
        lines.append("    Inputs " + ("unknown" if row["input_refs"] is None else "none recorded"))
    by_ref = {_timeline_ref(item["ref"]): item for item in row["output_items"]}
    producer = _timeline_ref(row["run_ref"] or row["ref"])
    for mapping in row["output_consumers"]:
        item = by_ref[_timeline_ref(mapping["output_ref"])]
        target = ", ".join(map(_timeline_ref, mapping["analysis_refs"]))
        if not target:
            target = ("consumers omitted" if mapping["analysis_refs_omitted"] else
                      "consumers unknown" if mapping["scan_truncated"] else "no recorded consumer")
        if mapping["analysis_refs_omitted"]:
            target += f" (+{mapping['analysis_refs_omitted']} consumers omitted)"
        if mapping["scan_truncated"]:
            target += " [scan incomplete]"
        lines.append(f"    {producer} -> {item_text(item)} -> {target}")
    for item in row["output_items"]:
        if item["kind"] == "figure":
            lines.append("    Receipt figure " + item_text(item))
    for item in row["associated_figure_items"]:
        lines.append("    Associated figure " + item_text(item))
    if not row["output_items"] and not row["associated_figure_items"]:
        lines.append("    Outputs unknown" if row["time_source"] == "unqualified" else "    No recorded outputs shown")
    for field, label in (("input_refs", "inputs"), ("output_refs", "outputs"),
                         ("associated_figure_refs", "associated figures")):
        if row[field + "_omitted"]:
            lines.append(f"    +{row[field + '_omitted']} {label} omitted")
    if row["output_scan_truncated"] or row["downstream_scan_truncated"]:
        lines.append("    Link scan truncated at 100 edges; additional links may be uninspected")
    if row["run_ref"] is not None:
        lines.append(f"    Run {producer} | Receipt {_timeline_ref(row['ref'])} | "
                     f"Registered {stamp(row['registration_at_utc'])} | "
                     f"Wrapper start {stamp(row['started_at_utc'])} | End {stamp(row['ended_at_utc'])}")
    return lines


def _analysis_flags(item):
    flags = []
    if item["revision_status"] == "historical":
        flags.append("historical")
    if item["record_status"] != "active":
        flags.append(item["record_status"])
    return " (" + ", ".join(flags) + ")" if flags else ""


def timeline_summary(report):
    runs, analyses = report["view"] == "runs", report["view"] == "analyses"
    heading = "Recorded runs by wrapper start" if runs else "Analyses and recorded data flow" if analyses else "Record revisions by registration time"
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
        if analyses and row["name"] is not None:
            from .presentation import _console_label
            name = _console_label(row["name"], 72)
        if analyses:
            name += _analysis_flags(row)
        evidence = row["evidence"]
        status = row["outcome"] or ("execution UNKNOWN" if evidence == "unknown" else row["kind"])
        source = {"wrapper_start": "Run started", "registration": "Registered", "unqualified": "Time unqualified"}.get(row.get("time_source"), "")
        line = f"[{number}] {stamp}" + (f" ({source})" if source else "") + f"  {_timeline_ref(row['ref'])}  {name}  {status}"
        if row["outcome"]:
            line += f" ({evidence.replace('_', ' ')})"
        lines.append(line)
        if analyses:
            lines.extend(_analysis_summary_lines(row))
            continue
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
    if runs or analyses:
        relations = [f"{pair['left']}-{pair['right']} {pair['relation'].replace('_', ' ')}"
                     for pair in report["relations"] if pair["relation"] in ("overlap", "tied", "tied_boundary")]
        if relations:
            lines.append("Overlaps or ties on this page: " + ", ".join(relations))
        if analyses:
            lines.append("Registration is not execution; arrows show recorded dependencies, not verified consumption.")
        else:
            lines.append("Wrapper intervals are partial evidence. Unrecorded execution remains unknown.")
    else:
        lines.append("Registration times describe record revisions. Equal times share the same displayed time.")
    lines.append(f"Next cursor: {report['next_cursor'] or 'none'}")
    return "\n".join(lines)
