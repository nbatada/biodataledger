"""Bounded recorded-work lookup; it does not infer scientific equivalence."""
from copy import deepcopy

from .core import BundleError, _record_evidence, canonical, require

REPORT_VERSION = "biodataledger-related-work/1"
MAX_REPORT_BYTES = 4096


def _clip(value, limit):
    """Return a valid UTF-8 prefix and whether content was omitted."""
    if not isinstance(value, str):
        return None, False
    prefix = value[:limit]
    raw = prefix.encode("utf-8")
    if len(value) <= limit and len(raw) <= limit:
        return value, False
    return raw[:limit].decode("utf-8", "ignore"), True


def _refs(values, limit=10):
    return [deepcopy(value) for value in values[:limit]], max(0, len(values) - limit)


def _unique_refs(values):
    seen, result = set(), []
    for value in values:
        key = (value["project_id"], value["id"], value["revision"])
        if key not in seen:
            seen.add(key)
            result.append(value)
    return result


def _fields(rec):
    details = rec.get("details") if isinstance(rec.get("details"), dict) else {}
    fields = [("name", rec.get("name"))]
    for key in ("title", "purpose", "description"):
        fields.append((key, details.get(key)))
    tags = details.get("tags")
    if isinstance(tags, str):
        fields.append(("tags", tags))
    elif isinstance(tags, list):
        fields.extend(("tags", value) for value in tags[:32] if isinstance(value, str))
    return fields


def _match(rec, terms):
    details = rec.get("details") if isinstance(rec.get("details"), dict) else {}
    matched, values, clipped = [], [], isinstance(details.get("tags"), list) and len(details["tags"]) > 32
    for field, value in _fields(rec):
        value, was_clipped = _clip(value, 128 if field == "tags" else 4096)
        clipped = clipped or was_clipped
        if isinstance(value, str):
            values.append((field, value.casefold()))
    for term in terms:
        matched.extend(field for field, value in values if term in value)
    return all(any(term in value for _, value in values) for term in terms), sorted(set(matched)), clipped


def _entry(project, rec, basis, matched_fields=None):
    ref = project._ref(rec)
    inputs, omitted_inputs = (None, None) if rec.get("inputs") is None else _refs(rec["inputs"])
    receipt = project.get_execution(ref)
    anchor = receipt.get("run_ref") if receipt.get("status") != "unknown" else None
    try:
        anchor = project._ref(project._record(anchor, "analysis")) if anchor is not None else ref
    except BundleError:
        anchor = ref
    links = project.dependencies(anchor, "downstream", depth=2, limit=100)
    results, figures = [], []
    for edge in links["edges"]:
        target = edge["to"]
        if edge["type"] == "produced_result" and edge["from"] == anchor:
            results.append(target)
        elif edge["type"] in ("analytical_association", "rendered_in_figure"):
            figures.append(target)
    results, omitted_results = _refs(_unique_refs(results))
    figures, omitted_figures = _refs(_unique_refs(figures))
    title, title_clipped = _clip(rec["name"], 256)
    evidence = _record_evidence(rec)
    return {
        "ref": ref, "artifact_analysis_ref": anchor, "record_status": rec["status"], "title": title, "match_basis": basis,
        **({"matched_fields": matched_fields} if matched_fields is not None else {}),
        "inputs": inputs, "results": results, "figures": figures,
        "provenance": {"relationships": evidence["input_relationships"],
                       "execution_status": receipt["status"],
                       "scientific_validity": "unknown", "input_consumption": "unknown",
                       "equivalence": "unknown"},
        "omitted": {"inputs": omitted_inputs, "results": omitted_results,
                    "figures": omitted_figures, "links_incomplete": bool(links["truncated"]),
                    "title": title_clipped},
    }


def related_work(project, input_ref=None, query=None, limit=5):
    """Return bounded declared links or literal metadata candidates without I/O."""
    require((input_ref is None) != (query is None), "choose exactly one of input_ref or query")
    require(type(limit) is int and 1 <= limit <= 20, "limit must be an integer from 1 to 20")
    metadata_clipped = False
    if input_ref is not None:
        selected = project._record(input_ref, "data")
        selector = {"kind": "input_ref", "input_ref": project._ref(selected)}
        adjacency = project._lineage.outgoing.get((selected["id"], selected["revision"]), [])
        bounded_edges = adjacency[:100]
        search_truncated = len(adjacency) > 100
        matched = [project._record(project._lineage.edges[key]["to"], "analysis") for key in bounded_edges
                   if project._lineage.edges[key]["type"] == "input_to_analysis"]
        entries = [_entry(project, rec, "exact_input_reference") for rec in matched[:limit]]
        active_count, inspected = None, len(bounded_edges)
    else:
        require(isinstance(query, str) and query.strip(), "query must be nonblank text")
        try:
            query_prefix = query[:256]
            require(len(query) <= 256 and len(query_prefix.encode("utf-8")) <= 256, "query exceeds 256 UTF-8 bytes")
        except UnicodeEncodeError as exc:
            raise BundleError("query must be UTF-8 text") from exc
        terms = query.casefold().split()
        selector = {"kind": "query", "query": query, "terms": terms}
        latest = [rec for rec in project._latest("analysis") if rec["status"] == "active"]
        candidates = []
        for rec in latest[:1000]:
            is_match, fields, clipped = _match(rec, terms)
            metadata_clipped = metadata_clipped or clipped
            if is_match:
                candidates.append((rec, fields))
        matched = [rec for rec, _ in candidates]
        search_truncated = len(latest) > 1000
        entries = [_entry(project, rec, "text_candidate", fields)
                   for rec, fields in candidates[:limit]]
        active_count, inspected = len(latest), min(len(latest), 1000)
    uncertain_match_state = search_truncated or metadata_clipped
    report = {"report_version": REPORT_VERSION, "selector": selector,
              "registry_revision": project.state["state_revision"], "unsaved": project.unsaved,
              "state": {"no_match": False if matched else (None if uncertain_match_state else True),
                        "multiple": True if len(matched) > 1 else (None if uncertain_match_state else False), "incomplete": False},
              "counts": {"active_analysis_records": active_count, "inspected_edges": inspected,
                         "matched": len(matched), "returned": len(entries), "omitted": max(0, len(matched) - len(entries))},
              "truncation": {"report": False, "search": search_truncated, "metadata": metadata_clipped,
                             "links": any(entry["omitted"]["links_incomplete"] for entry in entries),
                             "details": any(entry["omitted"]["title"] or any((entry["omitted"][key] or 0) > 0
                                            for key in ("inputs", "results", "figures")) for entry in entries)},
              "coverage": {"relationships": "recorded_only", "scientific_validity": "unknown",
                           "input_consumption": "unknown", "equivalence": "unknown",
                           "imported_claims": "untrusted" if project.state["imported"] else "not_imported",
                           "analysis_scope": "latest_active" if query is not None else "direct_input_historical_revisions"}, "analyses": entries}
    while len(canonical(report)) > MAX_REPORT_BYTES and report["analyses"]:
        report["analyses"].pop()
        report["counts"]["returned"] -= 1
        report["counts"]["omitted"] += 1
        report["truncation"]["report"] = True
    report["state"]["incomplete"] = any(report["truncation"].values()) or report["counts"]["omitted"] > 0
    require(len(canonical(report)) <= MAX_REPORT_BYTES, "related-work report exceeds byte limit")
    return report
