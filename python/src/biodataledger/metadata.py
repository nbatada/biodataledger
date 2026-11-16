"""Continuous metadata tables; values remain text and tables remain outside state."""
import copy
import csv
import hashlib
import os
from pathlib import Path
import shutil
import uuid

VERSION = "biodataledger-metadata/1"
BINDINGS_VERSION = "biodataledger-metadata-bindings/1"
KEY = "bl_metadata_table"
BINDINGS_KEY = "bl_metadata_bindings"
CATEGORIES = {"sample_preparation", "acquisition", "processing_qc", "analysis", "annotation", "result"}
CATEGORY_ORDER = ("sample_preparation", "acquisition", "processing_qc", "analysis", "annotation", "result")
MAX_BYTES = 64 * 1024 * 1024
MAX_COLUMNS = 256


def _text(value, label, require):
    require(isinstance(value, str) and value.strip(), label + " required")
    return value


def _columns(value, label, require):
    require(isinstance(value, (list, tuple)) and value, label + " required")
    result = list(value)
    require(all(isinstance(x, str) and x.strip() for x in result) and len(result) == len(set(result)),
            "invalid " + label)
    return result


def _exact_ref(project, value, require):
    return project._ref(project._record(value, "data"))


def descriptor(rec, require):
    value = rec["details"].get(KEY)
    require(isinstance(value, dict) and set(value) == {"version", "category", "key_columns", "required_columns", "authority", "reason", "units", "links", "columns", "row_count", "delimiter"},
            "invalid metadata descriptor")
    require(value["version"] == VERSION and value["category"] in CATEGORIES, "invalid metadata descriptor version/category")
    keys = _columns(value["key_columns"], "metadata key_columns", require)
    columns = _columns(value["columns"], "metadata columns", require)
    require(len(columns) <= MAX_COLUMNS and set(keys) <= set(columns), "invalid metadata columns")
    required = value["required_columns"]
    require(isinstance(required, list) and len(required) == len(set(required)) and all(isinstance(x, str) and x in columns for x in required), "invalid required_columns")
    _text(value["authority"], "metadata authority", require); _text(value["reason"], "metadata reason", require)
    require(isinstance(value["units"], dict) and all(isinstance(k, str) and k in columns and isinstance(v, str) and v.strip() for k, v in value["units"].items()), "invalid metadata units")
    require(isinstance(value["links"], list) and type(value["row_count"]) is int and value["row_count"] > 0 and value["delimiter"] in (",", "\t"), "invalid metadata links/table shape")
    require(rec["kind"] == "data" and rec["role"] == "bl_metadata_table" and rec["locator"] and rec["locator"]["kind"] == "project" and rec["locator"]["value"].startswith(".nb_project_bundle/outputs/metadata-"), "invalid metadata record")
    require(isinstance(rec["sha256"], str) and isinstance(rec["size"], int), "metadata identity required")
    return value


def validate_record(rec, require):
    require(rec.get("role") != "bl_metadata_table" or KEY in rec["details"], "metadata_table role requires descriptor")
    if KEY in rec["details"]:
        descriptor(rec, require)
    if BINDINGS_KEY in rec["details"]:
        value = rec["details"][BINDINGS_KEY]
        require(isinstance(value, dict) and set(value) == {"version", "refs", "reason"} and value["version"] == BINDINGS_VERSION,
                "invalid metadata bindings")
        require(rec["kind"] in ("data", "analysis") and not is_metadata(rec), "metadata bindings target must be DATA/ANA")
        _text(value["reason"], "metadata binding reason", require)
        require(isinstance(value["refs"], list) and value["refs"], "metadata bindings required")


def validate_links(rec, check_ref, require):
    if KEY not in rec["details"]:
        if BINDINGS_KEY in rec["details"]:
            refs = rec["details"][BINDINGS_KEY]["refs"]
            seen, ids = set(), set()
            for ref in refs:
                target = check_ref(ref, "data")
                require(is_metadata(target), "metadata binding requires metadata table")
                token = (ref["id"], ref["revision"])
                require(token not in seen and ref["id"] not in ids, "duplicate metadata binding")
                seen.add(token); ids.add(ref["id"])
        return
    table = descriptor(rec, require)
    for link in table["links"]:
        require(isinstance(link, dict) and set(link) == {"ref", "columns", "target_columns"}, "invalid metadata link")
        target = check_ref(link["ref"], "data")
        target_table = descriptor(target, require)
        columns = _columns(link["columns"], "link columns", require)
        targets = _columns(link["target_columns"], "link target_columns", require)
        require(set(columns) <= set(table["columns"]) and targets == target_table["key_columns"] and len(columns) == len(targets), "invalid metadata link columns")


def validate_graph(records, check_ref, require):
    graph = {}
    for rec in records:
        if is_metadata(rec):
            graph[(rec["id"], rec["revision"])] = [(x["ref"]["id"], x["ref"]["revision"]) for x in descriptor(rec, require)["links"]]
    done = set()
    for start in graph:
        if start in done: continue
        active, stack = set(), [(start, False)]
        while stack:
            node, leaving = stack.pop()
            if leaving:
                active.remove(node); done.add(node); continue
            if node in done: continue
            require(node not in active, "metadata link cycle")
            active.add(node); stack.append((node, True))
            stack.extend((child, False) for child in graph.get(node, []) if child not in done)


def is_metadata(rec):
    return rec.get("kind") == "data" and rec.get("role") == "bl_metadata_table" and KEY in rec.get("details", {})


def reserve(details, require):
    require(not ({KEY, BINDINGS_KEY} & set(details)), "metadata descriptors/bindings are dedicated-writer only")


def _read(path, delimiter, require):
    require(path is not None and path.is_file() and not path.is_symlink(), "MISSING_FILE")
    require(path.stat().st_size <= MAX_BYTES, "metadata table exceeds 64 MiB")
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as stream:
            reader = csv.reader(stream, delimiter=delimiter)
            header = next(reader, None)
            require(header is not None and header and len(header) <= MAX_COLUMNS and all(x and x.strip() for x in header) and len(header) == len(set(header)), "invalid metadata headers")
            rows = []
            for row in reader:
                require(len(row) == len(header), "ragged metadata row")
                rows.append(dict(zip(header, row)))
    except (UnicodeDecodeError, csv.Error) as exc:
        from .core import BundleError
        raise BundleError("metadata table must be valid UTF-8 CSV") from exc
    except OSError as exc:
        from .core import BundleError
        raise BundleError("MISSING_FILE") from exc
    require(rows, "metadata table needs data rows")
    return header, rows


def _verified(project, rec, require):
    path = project._resolve(rec["locator"])
    require(path is not None and not path.is_symlink() and path.is_file(), "UNSAFE_FILE" if path is not None and path.is_symlink() else "MISSING_FILE")
    require(path.stat().st_size == rec["size"], "SIZE_MISMATCH")
    require(project._verify_file(rec)[1] == rec["sha256"], "DIGEST_MISMATCH")
    return path


def _validate_rows(table, rows, require):
    keys, required = table["key_columns"], table["required_columns"]
    seen = set()
    for row in rows:
        require(all(row[x].strip() for x in keys), "blank metadata key")
        token = tuple(row[x] for x in keys)
        require(token not in seen, "duplicate metadata key")
        seen.add(token)
        require(all(row[x].strip() for x in required), "blank required metadata value")
    return seen


def _load(project, rec, require):
    table = descriptor(rec, require)
    path = _verified(project, rec, require)
    before = path.stat()
    columns, rows = _read(path, table["delimiter"], require)
    after = path.stat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "FILE_CHANGED")
    require(columns == table["columns"] and len(rows) == table["row_count"], "INVALID_TABLE")
    _validate_rows(table, rows, require)
    return table, rows


def register(project, path, category, key_columns, *, authority, reason, ref=None, links=None, required_columns=None, units=None, name=None, delimiter=","):
    from .core import fingerprint, now, require
    require(category in CATEGORIES and delimiter in (",", "\t"), "invalid metadata category/delimiter")
    keys = _columns(key_columns, "metadata key_columns", require)
    require(required_columns is None or isinstance(required_columns, (list, tuple)), "invalid required_columns")
    required = [] if required_columns is None else list(required_columns)
    require(len(required) == len(set(required)) and all(isinstance(x, str) and x.strip() for x in required), "invalid required_columns")
    _text(authority, "metadata authority", require); _text(reason, "metadata reason", require)
    require(units is None or isinstance(units, dict), "invalid metadata units")
    source = Path(path).expanduser()
    if not source.is_absolute(): source = project.root / source
    require(not source.is_symlink(), "metadata source symlink rejected")
    source = source.resolve(); require(source.is_file() and source.stat().st_size <= MAX_BYTES, "metadata source missing/unsafe/oversized")
    before = source.stat(); source_hash = fingerprint(source)
    columns, rows = _read(source, delimiter, require)
    require(set(keys) <= set(columns) and set(required) <= set(columns), "metadata columns absent")
    _validate_rows({"key_columns": keys, "required_columns": required}, rows, require)
    units = {} if units is None else copy.deepcopy(units)
    require(all(isinstance(k, str) and k in columns and isinstance(v, str) and v.strip() for k,v in units.items()), "invalid metadata units")
    original = None if ref is None else copy.deepcopy(project._record(ref, "data"))
    if original is not None:
        require(original["revision"] == project._latest_index[original["id"]]["revision"], "metadata revision requires latest exact ref")
        old = descriptor(original, require)
        require(old["category"] == category and old["key_columns"] == keys, "metadata category/key_columns immutable")
    folder = project._internal(".nb_project_bundle/outputs/metadata-" + str(uuid.uuid4()))
    folder.mkdir(parents=True, exist_ok=False); dest = folder / "table.csv"
    state, dirty, snapshots = copy.deepcopy(project.state), project._dirty, copy.deepcopy(project._snapshots)
    try:
        with source.open("rb") as inp, dest.open("xb") as out: shutil.copyfileobj(inp, out, 1024 * 1024)
        after = source.stat()
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) and fingerprint(dest) == source_hash and fingerprint(source) == source_hash, "metadata source changed during capture")
        copied_columns, copied_rows = _read(dest, delimiter, require); require(copied_columns == columns and copied_rows == rows, "metadata capture changed")
        require(links is None or isinstance(links, list), "invalid metadata links")
        link_values = []
        for link in links or []:
            require(isinstance(link, dict) and set(link) == {"ref", "columns", "target_columns"}, "invalid metadata link")
            link_values.append({"ref": _exact_ref(project, link["ref"], require),
                                "columns": _columns(link["columns"], "link columns", require),
                                "target_columns": _columns(link["target_columns"], "link target_columns", require)})
        for link in link_values:
            require(set(link["columns"]) <= set(columns) and all(row[column].strip() for row in rows for column in link["columns"]),
                    "linked metadata fields must be nonblank")
            target = project._record(link["ref"], "data")
            target_table, target_rows = _load(project, target, require)
            require(is_metadata(target) and link["target_columns"] == target_table["key_columns"] and len(link["columns"]) == len(link["target_columns"]), "invalid metadata link target")
            targets = {tuple(row[column] for column in link["target_columns"]) for row in target_rows}
            require(all(tuple(row[column] for column in link["columns"]) in targets for row in rows), "INVALID_LINK")
        table = {"version": VERSION, "category": category, "key_columns": keys, "required_columns": required, "authority": authority, "reason": reason, "units": units, "links": link_values, "columns": columns, "row_count": len(rows), "delimiter": delimiter}
        rec = project._new("data", name or source.name)
        if original is not None:
            rec = original; rec["revision"] = project._latest_index[rec["id"]]["revision"] + 1; rec["created_at"] = now()
        rec.update(locator=project._locator(dest), role="bl_metadata_table", sha256=fingerprint(dest), size=dest.stat().st_size)
        rec["details"] = {KEY: table, "provenance": {"file": "captured", "analytical": "declared"}}
        result = project._stage(rec, "register_metadata", reason, version="0.4.0", context_check=False)
        project.state["project"]["bl_metadata_policy"] = "continuous_metadata_v1"
        return result
    except BaseException:
        project.state, project._dirty, project._snapshots = state, dirty, snapshots; project._reindex(); shutil.rmtree(folder, ignore_errors=True); raise


def get(project, ref, limit=20, offset=0):
    from .core import require
    require(type(limit) is int and 1 <= limit <= 200 and type(offset) is int and offset >= 0, "invalid metadata page")
    rec = project._record(ref, "data"); table, rows = _load(project, rec, require)
    result = {"ref": project._ref(rec), "name": rec["name"], "category": table["category"],
            "authority": table["authority"], "reason": table["reason"], "key_columns": copy.deepcopy(table["key_columns"]),
            "required_columns": copy.deepcopy(table["required_columns"]), "units": copy.deepcopy(table["units"]),
            "links": copy.deepcopy(table["links"]), "columns": copy.deepcopy(table["columns"]), "row_count": table["row_count"],
            "rows": copy.deepcopy(rows[offset:offset+limit]), "offset": offset, "limit": limit,
            "has_more": offset + limit < len(rows), "integrity": "verified"}
    return _prefix(result)


def bind(project, ref, metadata_refs, reason):
    from .core import now, require
    require(isinstance(metadata_refs, list) and metadata_refs and isinstance(reason, str) and reason.strip(), "metadata refs/reason required")
    old = copy.deepcopy(project._record(ref)); require(old["kind"] in ("data", "analysis") and not is_metadata(old), "metadata binding target must be generic DATA/ANA")
    require(old["revision"] == project._latest_index[old["id"]]["revision"], "metadata binding requires latest exact ref")
    require(not ({"execution_receipt", "analysis_protocol", "renderer_receipt"} & set(old["details"])), "protected record cannot bind metadata")
    refs = [_exact_ref(project, x, require) for x in metadata_refs]
    require(len({(x["id"], x["revision"]) for x in refs}) == len(refs) and len({x["id"] for x in refs}) == len(refs), "duplicate metadata binding")
    for item in refs: require(is_metadata(project._record(item, "data")), "metadata binding requires metadata table")
    old["revision"] = project._latest_index[old["id"]]["revision"] + 1; old["created_at"] = now(); old["details"][BINDINGS_KEY] = {"version": BINDINGS_VERSION, "refs": refs, "reason": reason}
    result = project._stage(old, "bind_metadata", reason, version="0.4.0", context_check=False)
    project.state["project"]["bl_metadata_policy"] = "continuous_metadata_v1"
    return result


def _summary(project, rec):
    from .core import require
    table = descriptor(rec, require)
    return {"ref": project._ref(rec), "name": rec["name"], "category": table["category"],
            "authority": table["authority"], "key_columns": copy.deepcopy(table["key_columns"]),
            "links": copy.deepcopy(table["links"]), "columns": copy.deepcopy(table["columns"]), "row_count": table["row_count"]}


def view(project, ref):
    from .core import require
    subject = project._record(ref); queue, visited, tables, truncated = [subject], set(), {}, False
    while queue:
        rec = queue.pop(0); token = (rec["id"], rec["revision"])
        if token in visited: continue
        if len(visited) >= 1000: truncated = True; break
        visited.add(token)
        bindings = rec["details"].get(BINDINGS_KEY, {}).get("refs", [])
        for item in bindings: queue.append(project._record(item, "data"))
        if is_metadata(rec):
            table = descriptor(rec, require); tables[token] = rec
            for link in table["links"]: queue.append(project._record(link["ref"], "data"))
        if rec["kind"] == "data" and rec.get("scope", {}).get("transformation_ref") is not None: queue.append(project._record(rec["scope"]["transformation_ref"], "analysis"))
        if rec["kind"] == "analysis":
            for item in rec["inputs"] or []: queue.append(project._record(item, "data"))
        if rec["kind"] == "figure":
            if rec["analysis"] is not None: queue.append(project._record(rec["analysis"], "analysis"))
            for item in rec["inputs"] or []: queue.append(project._record(item, "data"))
    categories = {category: [] for category in CATEGORY_ORDER}
    for rec in tables.values(): categories[descriptor(rec, require)["category"]].append(_summary(project, rec))
    return {"subject_ref": project._ref(subject), "categories": categories, "missing_categories": [x for x in CATEGORY_ORDER if not categories[x]], "source_refs": [project._ref(x) for x in tables.values()], "limits": {"max_records": 1000, "visited_records": len(visited), "truncated": truncated}}


def _prefix(value):
    return {"bl_" + key: child for key, child in value.items()}


def public_view(project, ref):
    result = view(project, ref)
    result["categories"] = {category: [_prefix(item) for item in entries] for category, entries in result["categories"].items()}
    result["limits"] = _prefix(result["limits"])
    return _prefix(result)


def check(project, ref, required_categories=None):
    from .core import BundleError, require
    require(required_categories is None or isinstance(required_categories, (list, tuple)), "invalid required_categories")
    required = ["sample_preparation"] if required_categories is None else list(required_categories)
    require(len(required) == len(set(required)) and all(isinstance(x, str) and x.strip() for x in required), "invalid required_categories")
    require(set(required) <= CATEGORIES, "invalid required metadata category")
    report = view(project, ref); issues, checked, values, cache = [], [], {}, {}
    def issue(code, message, item):
        entry = {"code": code, "message": message, "ref": item}
        if entry not in issues: issues.append(entry)
    if report["limits"]["truncated"]: issue("TRUNCATED", "metadata graph traversal truncated", None)
    for item in report["source_refs"]:
        token = (item["id"], item["revision"])
        rec = project._record(item, "data")
        try:
            cache[token] = _load(project, rec, require)
            checked.append(item)
        except BundleError as exc:
            raw = str(exc).split(":", 1)[0]
            code = "MISSING_FILE" if raw in {"UNRESOLVED", "MISSING_FILE"} else raw if raw in {"SIZE_MISMATCH", "DIGEST_MISMATCH", "UNSAFE_FILE"} else "INVALID_TABLE"
            issue(code, str(exc), item)
    for item in report["source_refs"]:
        token = (item["id"], item["revision"])
        if token not in cache: continue
        table, rows = cache[token]
        for link in table["links"]:
            target_token = (link["ref"]["id"], link["ref"]["revision"])
            if target_token not in cache:
                issue("UNVERIFIED_LINK", "linked metadata table unavailable or invalid", item); continue
            _, target_rows = cache[target_token]
            target_keys = {tuple(row[x] for x in link["target_columns"]) for row in target_rows}
            if any(tuple(row[x] for x in link["columns"]) not in target_keys for row in rows):
                issue("INVALID_LINK", "metadata foreign key missing", item)
        group = (table["category"], tuple(table["key_columns"]))
        for row in rows:
            token = tuple(row[x] for x in table["key_columns"])
            for column, value in row.items():
                if value != "":
                    marker = (group, token, column)
                    if marker in values and values[marker][0] != value: issue("CONFLICT", "conflicting metadata values", item)
                    values[marker] = (value, item)
    missing = [x for x in required if not report["categories"][x]]
    if missing: issues.extend({"code": "MISSING_CATEGORY", "message": "required metadata category missing", "ref": None} for _ in missing)
    unknown = bool(missing or report["limits"]["truncated"] or any(x["code"] in {"MISSING_FILE", "UNVERIFIED_LINK"} for x in issues))
    failed = any(x["code"] in {"SIZE_MISMATCH", "DIGEST_MISMATCH", "UNSAFE_FILE", "INVALID_TABLE", "INVALID_LINK", "CONFLICT"} for x in issues)
    return _prefix({"status": "FAIL" if failed else "UNKNOWN" if unknown else "PASS", "subject_ref": report["subject_ref"], "available_categories": [x for x in CATEGORY_ORDER if report["categories"][x]], "missing_required": missing, "issues": [_prefix(item) for item in issues], "tables_checked": checked, "data_alignment": "not_checked", "scientific_acceptance": "not_assessed"})
