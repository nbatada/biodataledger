"""Exact derived-artifact declarations and explicit bounded CSV checks."""
from bisect import insort
from collections import defaultdict, deque
from copy import deepcopy
import csv
import io
import math
from pathlib import Path
import re
import shutil
import tempfile

from .core import (BundleError, canonical, digest_bytes, fingerprint, now, require,
                   validate_locator)
from .scope import normalize_scope

KEY = 'biodataledger.result'
VERSION = 'biodataledger-result/1'
MAX_CHECK_BYTES = 20 * 1024 * 1024
NUMERIC = re.compile(r'[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z')


def text(value):
    return isinstance(value, str) and bool(value.strip())


def normalize_embedding(project, value):
    if value is None:
        return None, None
    require(isinstance(value, dict) and set(value) <= {
        'format', 'selector', 'key_columns', 'coordinate_columns', 'alignment',
        'comparison', 'membership_ref', 'row_key_column'}, 'invalid embedding fields')
    fmt = value.get('format')
    require(fmt in ('csv', 'seurat', 'anndata'), 'unsupported embedding format')
    keys = value.get('key_columns')
    if keys is None: keys = ['sample_id', 'cell_id']
    require(isinstance(keys, list) and len(keys) == 2 and all(text(x) for x in keys)
            and len(set(keys)) == 2, 'two distinct qualified key columns required')
    selector = value.get('selector')
    coordinates = value.get('coordinate_columns')
    row_key = value.get('row_key_column')
    if fmt == 'csv':
        require(selector is None and row_key is None, 'CSV selector and row_key_column must be null')
        require(isinstance(coordinates, list) and coordinates and all(text(x) for x in coordinates)
                and len(set(keys + coordinates)) == len(keys + coordinates), 'distinct coordinate columns required')
        alignment = value.get('alignment')
        if alignment is None: alignment = 'same_row'
        require(alignment == 'same_row', 'CSV alignment must be same_row')
    else:
        require(text(selector) and coordinates is None, 'native selector required; coordinates must be null')
        alignment = value.get('alignment')
        if alignment is None: alignment = 'ordered'
        require(alignment in ('keyed', 'ordered'), 'invalid native alignment')
        require(row_key is None or text(row_key), 'invalid observation row key column')
        require(alignment != 'keyed' or text(row_key), 'keyed native alignment requires row_key_column')
    comparison = value.get('comparison')
    if comparison is None: comparison = 'ordered_keys' if alignment == 'ordered' else 'set_keys'
    require(comparison in ('set_keys', 'ordered_keys'), 'invalid membership comparison')
    member = value.get('membership_ref')
    member = project._ref(project._record(member, 'data')) if member is not None else None
    return {'format': fmt, 'selector': selector, 'key_columns': deepcopy(keys),
            'coordinate_columns': deepcopy(coordinates), 'alignment': alignment,
            'comparison': comparison, 'row_key_column': row_key}, member


def validate_result(project, rec):
    value = rec['details'].get(KEY)
    require(rec['kind'] == 'data' and isinstance(value, dict) and set(value) == {
        'version', 'artifact_source_ref', 'storage', 'embedding'} and value['version'] == VERSION,
        'unsupported or invalid result descriptor')
    require(rec['role'] == 'derived_result', 'result role must be derived_result')
    storage = value['storage']
    require(isinstance(storage, dict) and set(storage) == {'mode', 'source_locator'}
            and storage['mode'] in ('reference', 'copy'), 'invalid result storage')
    validate_locator(storage['source_locator'])
    if storage['mode'] == 'copy':
        require(rec['locator']['kind'] == 'project' and
                rec['locator']['value'].startswith('.nb_project_bundle/outputs/result-')
                and rec['sha256'] is not None, 'invalid copied result binding')
    else:
        require(rec['locator'] == storage['source_locator'], 'reference locator mismatch')
    if value['artifact_source_ref'] is not None:
        source = project._record(value['artifact_source_ref'], 'data')
        require(project._ref(source) != project._ref(rec), 'self result source')
        require(storage['source_locator'] == source['locator'], 'source locator mismatch')
        require(source['sha256'] is None or source['sha256'] == rec['sha256'], 'source baseline mismatch')
    normalized, _ = normalize_embedding(project, value['embedding'])
    require(normalized == value['embedding'], 'embedding must use canonical fields')
    member = rec['details'].get('membership')
    if member is not None:
        project._record(member, 'data')
        require(member != project._ref(rec), 'self observation authority')
    require(isinstance(rec.get('scope'), dict), 'result scope required')
    producer = rec['scope']['transformation_ref']
    if producer is not None:
        project._record(producer, 'analysis')
    return value


def describe_result(project, rec):
    if KEY not in rec['details']:
        return None
    value = rec['details'][KEY]
    if not isinstance(value, dict) or value.get('version') != VERSION:
        return {'status': 'unknown', 'missing': ['unrecognized_result'], 'execution': 'unknown'}
    try:
        validate_result(project, rec)
    except (ValueError, KeyError, TypeError):
        return {'status': 'unknown', 'missing': ['invalid_result'], 'execution': 'unknown'}
    missing = ['artifact_integrity_not_checked']
    if rec['scope']['transformation_ref'] is None:
        missing.append('producer_unknown')
    missing.append('embedding_unknown' if value['embedding'] is None else 'alignment_not_checked')
    if rec['details'].get('membership') is None:
        missing.append('membership_unknown')
    return {'status': 'declared', 'missing': missing, 'execution': 'unknown'}


def guard_update(rec, changes):
    incoming = changes.get('details', {})
    if KEY in rec['details']:
        require('path' not in changes, 'use register_result to revise result paths')
        if 'details' in changes:
            require(incoming.get(KEY) == rec['details'][KEY] and
                    incoming.get('membership') == rec['details'].get('membership'),
                    'use register_result to revise result declarations')
    else:
        require(KEY not in incoming, 'use register_result to declare a result')


def register_result(project, source, analysis_ref, ref=None, embedding=None, copy=False, hash=False):
    require(type(copy) is bool and type(hash) is bool, 'copy/hash must be boolean')
    producer = project._record(analysis_ref, 'analysis') if analysis_ref is not None else None
    original = project._record(ref, 'data') if ref is not None else None
    if original is not None:
        validate_result(project, original)
    parsed, member = normalize_embedding(project, embedding)
    is_ref = isinstance(source, dict) or isinstance(source, str) and re.fullmatch(r'DATA-\d+@[1-9]\d*', source)
    source_rec = project._record(source, 'data') if is_ref else None
    if source_rec is not None:
        require(source_rec['status'] == 'active', 'source DATA is inactive')
    locator = deepcopy(source_rec['locator']) if source_rec else project._locator(source)
    require(locator['kind'] != 'uri', 'local result file required')
    file = project._resolve(locator)
    require(file is not None and file.is_file(), 'result source must be an existing regular file')
    baseline = source_rec['sha256'] if source_rec else None
    size = source_rec['size'] if source_rec else file.stat().st_size
    captured = baseline
    folder = None
    try:
        if hash or copy:
            before = file.stat()
            captured = fingerprint(file)
            after = file.stat()
            require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                    (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'source changed during hashing')
            require(baseline is None or captured == baseline, 'source baseline mismatch')
            size = after.st_size
        dest = file
        if copy:
            base = project._internal('.nb_project_bundle/outputs')
            base.mkdir(parents=True, exist_ok=True)
            folder = Path(tempfile.mkdtemp(prefix='result-', dir=base))
            dest = folder / file.name
            with file.open('rb') as inp, dest.open('xb') as out:
                shutil.copyfileobj(inp, out, length=1024 * 1024)
            require(fingerprint(dest) == captured and fingerprint(file) == captured,
                    'source changed during copy')
        rec = deepcopy(original) if original else project._new('data', file.name)
        if original:
            rec['revision'] = project._latest_index[rec['id']]['revision'] + 1
            rec['created_at'] = now()
        rec.update(locator=project._locator(dest) if copy else locator, role='derived_result',
                   sha256=captured, size=size, design=deepcopy(producer.get('design')) if producer else None,
                   scope=normalize_scope({'transformation_ref': project._ref(producer) if producer else None}, require))
        rec['details']['membership'] = member
        rec['details'][KEY] = {'version': VERSION,
            'artifact_source_ref': project._ref(source_rec) if source_rec else None,
            'storage': {'mode': 'copy' if copy else 'reference', 'source_locator': locator},
            'embedding': parsed}
        rec['details']['provenance'] = {'file': 'captured' if captured else 'unknown', 'analytical': 'declared'}
        validate_result(project, rec)
        version = project.state['schema_version'] if project.state['schema_version'] in ('0.3.0', '0.4.0') else '0.3.0'
        return project._stage(rec, 'register_result', version=version)
    except BaseException:
        if folder is not None:
            shutil.rmtree(folder)
        raise


def _read_table(project, rec):
    """Read the selected bounded bytes once; no interpreter/scientific object load."""
    if rec['status'] != 'active':
        return None, None, 'FAIL', 'inactive_artifact'
    file = project._resolve(rec['locator'])
    if file is None or not file.is_file():
        return None, None, 'UNKNOWN', 'artifact_unavailable'
    try:
        before = file.stat()
        if before.st_size > MAX_CHECK_BYTES:
            return None, None, 'UNKNOWN', 'size_limit'
        with file.open('rb') as stream:
            raw = stream.read(MAX_CHECK_BYTES + 1)
        after = file.stat()
        if len(raw) > MAX_CHECK_BYTES:
            return None, None, 'UNKNOWN', 'size_limit'
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            return None, None, 'FAIL', 'artifact_changed_during_read'
    except OSError:
        return None, None, 'UNKNOWN', 'artifact_unavailable'
    digest = digest_bytes(raw)
    if rec['sha256'] is not None and digest != rec['sha256']:
        return None, digest, 'FAIL', 'digest_mismatch'
    integrity, reason = ('PASS', 'digest_match') if rec['sha256'] else ('UNKNOWN', 'baseline_missing')
    try:
        content = raw.decode('utf-8')
        require('\x00' not in content, 'NUL in CSV')
        rows = list(csv.reader(io.StringIO(content, newline=''), strict=True))
        require(bool(rows) and bool(rows[0]), 'CSV header missing')
        header = rows[0]
        require(all(text(x) for x in header) and len(set(header)) == len(header), 'invalid CSV headers')
        require(all(len(row) == len(header) for row in rows[1:]), 'inconsistent CSV rows')
        return (header, rows[1:]), digest, integrity, reason
    except (ValueError, UnicodeDecodeError, csv.Error):
        return None, digest, integrity, 'invalid_csv'


def _keys(table, columns):
    header, rows = table
    if not rows or not all(name in header for name in columns):
        return None
    indices = [header.index(name) for name in columns]
    keys = [tuple(row[i] for i in indices) for row in rows]
    if any(not all(text(x) for x in key) for key in keys) or len(set(keys)) != len(keys):
        return None
    return keys


def check_result(project, ref):
    rec = project._record(ref, 'data')
    report = {'ref': project._ref(rec), 'report_version': 'biodataledger-result-check/1', 'adapter': None,
        'fields': {key: {'status': 'UNKNOWN', 'reason': 'not_checked'} for key in
                   ('contract', 'file_integrity', 'observation_identity', 'coordinates', 'alignment', 'membership')},
        'observed_sha256': None, 'rows': None, 'execution': 'UNKNOWN',
        'unverified': ['scientific_validity', 'downstream_use']}
    def put(key, status, reason):
        report['fields'][key] = {'status': status, 'reason': reason}
    def finish():
        statuses = [x['status'] for x in report['fields'].values()]
        report['overall'] = 'FAIL' if 'FAIL' in statuses else 'UNKNOWN' if 'UNKNOWN' in statuses else 'PASS'
        return report
    try:
        descriptor = validate_result(project, rec)
    except (ValueError, KeyError, TypeError):
        put('contract', 'UNKNOWN', 'unsupported_or_invalid_result')
        return finish()
    put('contract', 'PASS', 'recognized_result')
    embedding = descriptor['embedding']
    if embedding is None:
        return finish()
    report['adapter'] = embedding['format']
    if embedding['format'] != 'csv':
        for key in report['fields']:
            if key != 'contract': put(key, 'UNKNOWN', 'adapter_not_available')
        return finish()
    table, digest, status, reason = _read_table(project, rec)
    report['observed_sha256'] = digest
    put('file_integrity', status, reason if reason != 'invalid_csv' else 'digest_match' if status == 'PASS' else 'baseline_missing')
    if table is None:
        if reason == 'invalid_csv':
            for key in ('observation_identity', 'coordinates', 'alignment'):
                put(key, 'FAIL', 'invalid_csv')
        return finish()
    header, rows = table
    report['rows'] = len(rows)
    keys = _keys(table, embedding['key_columns'])
    put('observation_identity', 'PASS' if keys is not None else 'FAIL',
        'unique_qualified_keys' if keys is not None else 'invalid_observation_keys')
    columns = embedding['coordinate_columns']
    numeric = bool(rows) and all(name in header for name in columns)
    if numeric:
        indices = [header.index(name) for name in columns]
        numeric = all(NUMERIC.fullmatch(row[i].strip()) and math.isfinite(float(row[i])) for row in rows for i in indices)
    put('coordinates', 'PASS' if numeric else 'FAIL', 'finite_coordinates' if numeric else 'invalid_coordinates')
    aligned = keys is not None and numeric
    put('alignment', 'PASS' if aligned else 'FAIL', 'same_row' if aligned else 'invalid_row_alignment')
    member_ref = rec['details'].get('membership')
    if member_ref is None:
        put('membership', 'UNKNOWN', 'authority_missing')
    elif keys is None:
        put('membership', 'UNKNOWN', 'subject_keys_invalid')
    else:
        authority = project._record(member_ref, 'data')
        if authority['sha256'] is None:
            put('membership', 'UNKNOWN', 'authority_baseline_missing')
        else:
            reference, _, integrity, why = _read_table(project, authority)
            if reference is None or integrity != 'PASS':
                put('membership', 'FAIL' if why == 'invalid_csv' else integrity, why)
            else:
                expected = _keys(reference, embedding['key_columns'])
                if expected is None:
                    put('membership', 'FAIL', 'invalid_authority_keys')
                else:
                    matched = keys == expected if embedding['comparison'] == 'ordered_keys' else set(keys) == set(expected)
                    put('membership', 'PASS' if matched else 'FAIL', 'membership_match' if matched else 'membership_mismatch')
    return finish()


def _node(ref):
    return ref['id'], ref['revision']


def _edge_key(edge):
    return (*_node(edge['from']), *_node(edge['to']), edge['type'])


class LineageIndex:
    """In-memory adjacency over exact revisions; no persisted graph or file I/O."""
    def __init__(self, project):
        self.outgoing = defaultdict(list)
        self.incoming = defaultdict(list)
        self.edges = {}
        self.nodes = set()
        self.unknown = {}
        for rec in project.state['records']:
            self.add(project, rec)

    def add(self, project, rec):
        ref = project._ref(rec)
        node = _node(ref)
        if node in self.nodes:
            return
        self.nodes.add(node)
        unknown = []
        edges = []
        def add(source, target, kind, basis, field):
            edges.append({'from': deepcopy(source), 'to': deepcopy(target), 'type': kind, 'basis': basis, 'source_field': field})
        if rec['kind'] == 'analysis':
            for source in rec['inputs'] or []:
                add(source, ref, 'input_to_analysis', 'declared', 'inputs')
            if rec['inputs'] is None:
                unknown.append('inputs_unknown')
        elif rec['kind'] == 'data':
            info = describe_result(project, rec)
            if info is not None:
                unknown += info['missing']
                if info['status'] == 'declared':
                    producer = rec['scope']['transformation_ref']
                    if producer is not None:
                        add(producer, ref, 'produced_result', 'declared', 'scope.transformation_ref')
                    source = rec['details'][KEY]['artifact_source_ref']
                    if source is not None:
                        add(source, ref, 'artifact_container', 'declared', 'details.biodataledger.result.artifact_source_ref')
                    member = rec['details'].get('membership')
                    if member is not None:
                        add(member, ref, 'observation_authority', 'declared', 'details.membership')
            else:
                unknown.append('result_relationships_unknown')
        elif rec['kind'] == 'figure':
            from .figure_sources import KEY as FIG_KEY, recognized, normalize
            from .core import safe_relative
            if rec['analysis'] is not None:
                add(rec['analysis'], ref, 'analytical_association', 'declared', 'analysis')
            raw = rec['details'].get(FIG_KEY)
            if recognized(raw):
                try:
                    value = normalize(raw, project, require, safe_relative)
                    if value['rendering_inputs'] is None: unknown.append('rendering_inputs_unknown')
                    if value['relationship'] == 'unknown': unknown.append('rendering_relationship_unknown')
                    for source in value['rendering_inputs'] or []:
                        add(source, ref, 'rendered_in_figure', value['relationship'], 'figure_sources.rendering_inputs')
                except (ValueError, KeyError, TypeError):
                    unknown.append('rendering_relationship_invalid')
            else:
                unknown.append('rendering_inputs_unknown')
        self.unknown[node] = list(dict.fromkeys(unknown))
        for edge in edges:
            key = _edge_key(edge)
            if key not in self.edges:
                self.edges[key] = edge
                insort(self.outgoing[_node(edge['from'])], key)
                insort(self.incoming[_node(edge['to'])], key)

    def query(self, project, ref, direction, depth, limit):
        require(direction in ('upstream', 'downstream'), 'direction must be upstream or downstream')
        require(type(depth) is int and 1 <= depth <= 3 and type(limit) is int and 1 <= limit <= 100,
                'depth 1..3 and limit 1..100 required')
        ref = project._ref(project._record(ref))
        report = {'ref': ref, 'direction': direction, 'depth': depth, 'edges': [], 'unknown': [],
                  'execution': 'unknown', 'coverage': 'recorded_only', 'truncated': False}
        queue = deque([(ref, 0)])
        visited, seen_edges = set(), set()
        adjacency = self.incoming if direction == 'upstream' else self.outgoing
        stopped = False
        while queue and not stopped:
            current, distance = queue.popleft()
            node = _node(current)
            if node in visited: continue
            visited.add(node)
            report['unknown'] += [{'ref': deepcopy(current), 'reason': reason} for reason in self.unknown.get(node, [])]
            if distance >= depth:
                if any(key not in seen_edges for key in adjacency.get(node, [])):
                    report["truncated"] = True
                continue
            for key in adjacency.get(node, []):
                if key in seen_edges: continue
                if len(report['edges']) >= limit:
                    report['truncated'] = True
                    stopped = True
                    break
                edge = self.edges[key]
                report['edges'].append(deepcopy(edge))
                seen_edges.add(key)
                neighbor = edge['from'] if direction == 'upstream' else edge['to']
                queue.append((neighbor, distance + 1))
        # Response limits omit complete identities, never shortened strings.
        while len(canonical(report)) > 16384:
            report['truncated'] = True
            if report['unknown']: report['unknown'].pop()
            elif report['edges']: report['edges'].pop()
            elif report['ref'] is not None: report['ref'] = None
            else: break
        return report
