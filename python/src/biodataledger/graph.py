"""Bounded views of the registry's existing exact-revision lineage index."""
import re
from copy import deepcopy
from datetime import date

from .chronology import _receipt_timing
from .execution import _validated_receipt
from .core import PREFIXES, BundleError, canonical, require
from .protocol import _timestamp
from .related_work import _clip, _match

VERSION = 'biodataledger-graph/1'
SCAN_LIMIT = 1000
EDGE_LIMIT = 100
BYTE_LIMIT = 128 * 1024
FILTERS = {'asset_type', 'query', 'registered_on', 'executed_on', 'revision', 'record_status', 'anchor'}


def index_graph_record(project, rec, ref, result_valid, add):
    """Add graph-view edges to the lineage index without changing legacy queries."""
    details = rec['details']
    def link(source, target, kind, field, basis='declared'):
        if source is not None:
            add(source, target, kind, basis, field, graph_only=True)

    # Both lookups support imported registries whose physical slots are not revision order.
    for delta in (-1, 1):
        adjacent = project._index.get((ref['id'], ref['revision'] + delta))
        if adjacent is not None:
            older, newer = (project._ref(adjacent), ref) if delta < 0 else (ref, project._ref(adjacent))
            link(older, newer, 'revision_of', 'id/revision', 'record_identity')
    link(rec.get('design'), ref, 'design_context', 'design')
    if rec['kind'] == 'design':
        for subject in details['context']:
            link(subject, ref, 'design_subject', 'details.context')
    if rec['kind'] == 'data':
        link(details.get('parent'), ref, 'parent_data', 'details.parent')
        link(details.get('clustering_run'), ref, 'clustering_context', 'details.clustering_run')
        if not result_valid:
            link(details.get('membership'), ref, 'observation_authority', 'details.membership')
            link(rec.get('scope', {}).get('transformation_ref'), ref, 'transformation_context', 'scope.transformation_ref')
    if rec['kind'] == 'figure' and rec['analysis'] is None:
        for source in rec['inputs'] or []:
            link(source, ref, 'input_to_figure', 'inputs')
    if rec['kind'] == 'decision' and 'targets' in details:
        targets = details['targets']
        if not isinstance(targets, list):
            return {'reason': 'invalid_decision_targets', 'related_ref': None, 'identity_omitted': False, 'count': 1, 'uninspected': 0}
        issue = None
        count = 0
        for source in targets[:SCAN_LIMIT]:
            # Legacy decision targets are optional metadata, not core validated links.
            reason, related, identity_omitted = None, None, False
            if (isinstance(source, dict) and set(source) == {'project_id', 'id', 'revision'}
                    and source['project_id'] == ref['project_id']
                    and isinstance(source['id'], str)
                    and re.fullmatch(r'(?:DATA|ANA|FIG|DEC|DES)-[0-9]{3,}', source['id'])
                    and type(source['revision']) is int and source['revision'] > 0):
                target = project._index.get((source['id'], source['revision']))
                if target is None:
                    reason = 'unresolved_decision_target'
                    identity_omitted = len(source['id']) > 128 or source['revision'] > 2147483647
                    related = None if identity_omitted else deepcopy(source)
                else:
                    link(source, ref, 'decision_concerns', 'details.targets')
            else:
                reason = 'invalid_decision_target'
            if reason is not None:
                count += 1
                if issue is None:
                    issue = {'reason': reason, 'related_ref': related, 'identity_omitted': identity_omitted}
        uninspected = max(0, len(targets) - SCAN_LIMIT)
        if issue is not None or uninspected:
            return {**(issue or {'reason': 'decision_target_limit', 'related_ref': None, 'identity_omitted': False}),
                    'count': count, 'uninspected': uninspected}
    return None


def _graph_ref(project, value, kinds=PREFIXES):
    rec = project._record(value)
    require(rec['kind'] in kinds, 'reference kind outside graph selection')
    return project._ref(rec)


def _date(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', value):
        return False
    try:
        date.fromisoformat(value)
        return True
    except ValueError:
        return False


def _filters(project, filters):
    require(filters is None or isinstance(filters, dict) and set(filters) <= FILTERS, 'invalid graph filters')
    out = dict(filters or {})
    if 'asset_type' in out:
        require(out['asset_type'] in ('DATA', 'ANA', 'FIG', 'DEC', 'DES', 'RESULT'), 'invalid asset_type')
    if 'revision' in out:
        require(out['revision'] in ('latest', 'historical'), 'invalid revision filter')
    if 'record_status' in out:
        require(out['record_status'] in ('active', 'inactive', 'superseded'), 'invalid record_status')
    if 'query' in out:
        value, clipped = _clip(out['query'], 256)
        require(value is not None and value.strip() and not clipped, 'query must be nonblank and at most 256 UTF-8 bytes')
    for field in ('registered_on', 'executed_on'):
        if field in out:
            require(_date(out[field]), field + ' must be a UTC date YYYY-MM-DD')
    if 'anchor' in out:
        out['anchor'] = _graph_ref(project, out['anchor'], ('data', 'analysis'))
    return out


def _key(ref):
    return ref['id'], ref['revision']


def _execution(project, rec):
    receipt = _validated_receipt(project, rec) if rec['kind'] == 'analysis' and 'execution_receipt' in rec['details'] else None
    if receipt is None:
        return {'evidence': 'unknown', 'status': 'unknown', 'timing_status': 'unknown',
                'started_at_utc': None, 'ended_at_utc': None, 'code_executed': None}
    start, end = receipt['started_at_utc'], receipt['ended_at_utc']
    return {'evidence': 'untrusted_imported' if project.state['imported'] else 'recorded',
            'status': receipt['status'], 'timing_status': _receipt_timing(receipt),
            'started_at_utc': start if _timestamp(start) is not None else None,
            'ended_at_utc': end if _timestamp(end) is not None else None,
            'code_executed': receipt['phases']['code_executed']}


def _asset_type(project, rec):
    unknown = project._lineage.unknown.get((rec['id'], rec['revision']), ())
    return 'RESULT' if 'artifact_integrity_not_checked' in unknown else PREFIXES[rec['kind']]


def _node(project, rec, ref):
    key = _key(ref)
    label, clipped = _clip(rec['name'], 192)
    timestamp = rec['created_at']
    owner = project._record(rec['analysis'], 'analysis') if rec['kind'] == 'figure' and rec['analysis'] else rec
    scientific_status = 'unknown'
    if rec['kind'] == 'decision' and 'scientific_decision' in rec['details']:
        descriptor, _ = project._scientific_decision_for_record(rec)
        if descriptor is not None:
            scientific_status = descriptor['scientific_status']
    issue = project._lineage.graph_issues.get(key)
    return {'ref': ref, 'kind': PREFIXES[rec['kind']], 'asset_type': _asset_type(project, rec), 'label': label,
            'label_truncated': clipped, 'record_status': rec['status'],
            'revision_status': 'latest' if project._latest_index[rec['id']] is rec else 'historical',
            'registration_at_utc': timestamp if _timestamp(timestamp) is not None else None,
            'superseded_at_utc': None, 'execution': _execution(project, rec),
            'scientific_status': scientific_status, 'approval': 'not_authenticated',
            'code_owner_ref': project._ref(owner) if owner['code'] else None,
            'code_count': len(owner['code']), 'unknown': list(project._lineage.unknown.get(key, [])),
            'issue': deepcopy(issue)}


def _overview(project, filters, offset, limit):
    graph = project._lineage
    anchor = filters.get('anchor')
    terms = filters.get('query', '').casefold().split()
    records = project.state['records']
    cursor, stops, nodes, slots = offset, {'page_boundary'} if offset else set(), [], []
    while cursor < len(records) and cursor - offset < SCAN_LIMIT and len(nodes) < limit:
        rec = records[cursor]
        cursor += 1
        if 'asset_type' in filters and filters['asset_type'] not in (PREFIXES[rec['kind']], _asset_type(project, rec)):
            continue
        revision = 'latest' if project._latest_index[rec['id']] is rec else 'historical'
        if filters.get('revision', revision) != revision or filters.get('record_status', rec['status']) != rec['status']:
            continue
        ref = project._ref(rec)
        if anchor is not None and anchor != ref:
            # Check the candidate's own adjacency in O(1) by the sorted exact edge-key buckets.
            if not graph.connected(anchor, ref):
                continue
        if 'registered_on' in filters:
            stamp = rec['created_at']
            if _timestamp(stamp) is None or stamp[:10] != filters['registered_on']:
                continue
        if terms:
            matches, _, clipped = _match(rec, terms)
            if clipped:
                stops.add('topic_metadata_limit')
            if not matches:
                continue
        if 'executed_on' in filters:
            execution = _execution(project, rec)
            stamp = execution['started_at_utc']
            if execution['timing_status'] != 'valid_interval' or not execution['code_executed'] or stamp[:10] != filters['executed_on']:
                continue
        nodes.append(ref)
        slots.append(cursor - 1)
    if cursor < len(records):
        stops.add('node_limit' if len(nodes) == limit else 'scan_limit')
    keys, edges, scanned = {_key(ref) for ref in nodes}, [], 0
    for ref in nodes:
        for edge in graph.adjacent(ref, 'downstream', extended=True):
            if scanned >= SCAN_LIMIT:
                stops.add('edge_scan_limit')
                break
            scanned += 1
            if _key(edge['to']) in keys:
                if len(edges) >= EDGE_LIMIT:
                    stops.add('edge_limit')
                    break
                edges.append(edge)
        if 'edge_limit' in stops or 'edge_scan_limit' in stops:
            break
    return nodes, edges, stops, cursor, slots


def _cycle(nodes, edges, incomplete):
    indegree = {_key(node['ref']): 0 for node in nodes}
    downstream = {key: [] for key in indegree}
    for edge in edges:
        source, target = _key(edge['from']), _key(edge['to'])
        indegree[target] += 1
        downstream[source].append(target)
    queue = [key for key in indegree if indegree[key] == 0]
    for source in queue:
        for target in downstream[source]:
            indegree[target] -= 1
            if indegree[target] == 0:
                queue.append(target)
    return 'detected' if len(queue) < len(nodes) else 'unknown' if incomplete else 'not_detected_in_view'


def _exact(ref):
    return ref['id'] + '@' + str(ref['revision'])


def _quote(value):
    # Escape caller text inside a DOT quoted string; never use HTML or URL attributes.
    value = re.sub(r'[\x00-\x09\x0b-\x1f\x7f]', ' ', value)
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def _dot(report):
    snap = report['snapshot']
    flags = ', '.join(report['truncation']) or 'none'
    summary = ('Recorded graph; ' + report['mode'] + '; omissions: ' + flags + '; cycle: ' + report['cycle']
               + '; edge scope: ' + report['edge_scope'])
    if report['next_offset'] is not None:
        summary += '; next_offset=' + str(report['next_offset'])
    lines = ['digraph biodataledger {',
             '  graph [label=' + _quote(summary) + ', project_id=' + _quote(snap['project_id'])
             + ', registry_revision=' + _quote(str(snap['registry_revision']))
             + ', transaction=' + _quote(snap['last_transaction'])
             + ', truncated=' + _quote(str(report['truncated']).lower()) + '];']
    for node in report['nodes']:
        execution = node['execution']
        stamp = lambda value: value or 'unknown'
        label = (_exact(node['ref']) + ' [' + node['asset_type'] + '] ' + node['label']
                 + ('…' if node['label_truncated'] else '') + '\n' + node['revision_status'] + '/' + node['record_status']
                 + '; registered: ' + stamp(node['registration_at_utc'])
                 + '; superseded: ' + stamp(node['superseded_at_utc'])
                 + '\nexecution: ' + execution['evidence'] + '/' + execution['status'] + '/' + execution['timing_status']
                 + '; receipt start: ' + stamp(execution['started_at_utc']) + '; receipt end: ' + stamp(execution['ended_at_utc']))
        unknown = node['unknown'] + ([node['issue']['reason']] if node['issue'] else [])
        if node['issue'] and node['issue']['related_ref'] is not None:
            unknown[-1] += ' ' + _exact(node['issue']['related_ref'])
        if unknown:
            label += '\n' + ', '.join(unknown)
        lines.append('  ' + _quote(_exact(node['ref'])) + ' [label=' + _quote(label) + '];')
    for edge in report['edges']:
        lines.append('  ' + _quote(_exact(edge['from'])) + ' -> ' + _quote(_exact(edge['to']))
                     + ' [label=' + _quote(edge['type']) + ', basis=' + _quote(edge['basis'])
                     + ', source_field=' + _quote(edge['source_field']) + '];')
    return '\n'.join(lines + ['}', ''])


def export_graph(project, ref, direction, depth, limit, format, filters, offset, style, lineage_roots):
    require(direction in ('upstream', 'downstream'), 'direction must be upstream or downstream')
    require(type(depth) is int and 1 <= depth <= 10 and type(limit) is int and 1 <= limit <= 100,
            'depth 1..10 and limit 1..100 required')
    require(format in ('dot', 'structured'), 'format must be dot or structured')
    require(style in ('detailed', 'presentation'), 'style must be detailed or presentation')
    require(style != 'presentation' or format == 'dot', 'presentation style requires DOT format')
    require(style == 'presentation' or lineage_roots is None, 'lineage_roots requires presentation style')
    if style == 'presentation':
        from .diagram import presentation_dot, presentation_roots
        roots = presentation_roots(project, lineage_roots)
    require(type(offset) is int and 0 <= offset <= 2147483647, 'offset must be a nonnegative 32-bit integer')
    require(ref is None or filters is None and offset == 0, 'filters and offset are overview-only')
    state = project.state
    filters = _filters(project, filters)
    if ref is None:
        refs, edges, stops, cursor, slots = _overview(project, filters, offset, limit)
    else:
        ref = _graph_ref(project, ref)
        refs, edges, stops = project._lineage.walk(ref, direction, depth, EDGE_LIMIT, node_limit=limit, extended=True)
        cursor = None
    nodes = [_node(project, project._record(item), item) for item in refs]
    total = len(state['records'])
    report = {'report_version': VERSION, 'mode': 'overview' if ref is None else 'lineage', 'ref': ref,
              'direction': direction if ref is not None else None, 'depth': depth if ref is not None else None,
              'filters': filters, 'limit': limit, 'offset': offset if ref is None else None,
              'scanned_record_slots': cursor - offset if cursor is not None else None,
              'snapshot': {'project_id': state['project']['id'], 'registry_revision': state['state_revision'],
                           'last_transaction': state['last_transaction'], 'unsaved': project.unsaved,
                           'record_slots': total, 'imported': state['imported']},
              'next_offset': cursor if cursor is not None and cursor < total else None,
              'coverage': 'recorded_only', 'edge_scope': 'induced_page' if ref is None else 'directional_walk',
              'cycle_scope': 'visible_navigation_edges', 'nodes': nodes, 'edges': deepcopy(edges)}
    # Use the same bounded graph for both formats, including DOT's escaping overhead.
    while True:
        report['truncation'] = sorted(stops | ({'decision_target_limit'}
                                               if project._lineage.graph_target_limit else set()))
        report['truncated'] = bool(report['truncation'])
        unresolved = any(n['issue'] is not None or any(
            reason in ('invalid_result', 'unrecognized_result', 'rendering_relationship_invalid')
            for reason in n['unknown']) for n in nodes)
        report['cycle'] = _cycle(nodes, report['edges'], report['truncated'] or unresolved)
        dot = _dot(report)
        if len(canonical(report)) <= BYTE_LIMIT and len(dot.encode('utf-8')) <= BYTE_LIMIT:
            if style == 'presentation':
                return presentation_dot(project, report, roots)
            return dot if format == 'dot' else report
        require(bool(nodes), 'graph selector exceeds byte limit')
        # In overview, move the cursor back to the first omitted match so it can be retrieved.
        dropped = nodes.pop()
        if ref is None:
            slot = slots.pop()
            if not nodes:
                slot += 1
                stops.add('oversized_node')
            report['next_offset'] = slot if slot < total else None
            report['scanned_record_slots'] = slot - offset
        stops.add('byte_limit')
        if ref is not None and not nodes:
            raise BundleError('graph root exceeds byte limit')
        dropped_key = _key(dropped['ref'])
        report['edges'] = [edge for edge in report['edges'] if dropped_key not in (_key(edge['from']), _key(edge['to']))]
