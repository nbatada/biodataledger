"""Presentation DOT for one bounded, already selected graph report."""
from . import figure_sources, presentation
from .core import require, safe_relative
from .graph import BYTE_LIMIT, _exact, _graph_ref, _quote
from .related_work import _clip

_PALETTE = (
    ('#17628D', '#DCEEF9'), ('#A24520', '#FCE6DA'), ('#356B44', '#E2F0E4'),
    ('#744681', '#EFE3F2'), ('#866019', '#FAEECF'), ('#1C6C70', '#DBF1F0'),
)
_TYPES = {
    'DATA': ('DATA', 'box'), 'ANA': ('ANALYSIS', 'ellipse'), 'RESULT': ('RESULT', 'cylinder'),
    'FIG': ('FIGURE', 'note'), 'DEC': ('DECISION', 'hexagon'), 'DES': ('DESIGN', 'folder'),
}
_FLOW = {
    'input_to_analysis': ('DATA', 'ANA'), 'produced_result': ('ANA', 'DATA'),
    'transformation_context': ('ANA', 'DATA'), 'parent_data': ('DATA', 'DATA'),
    'rendered_in_figure': ('DATA', 'FIG'),
}
_CONTEXT = {
    'analytical_association': 'associated', 'revision_of': 'revision', 'design_context': 'design',
    'design_subject': 'design subject', 'decision_concerns': 'concerns', 'clustering_context': 'clustering',
    'artifact_container': 'container', 'observation_authority': 'membership',
    'rendered_in_figure': 'rendering unconfirmed', 'input_to_figure': 'analytical input',
}
_NOTE_LIMIT = 8
_NOTE_LINK_LIMIT = 24
_NEUTRAL = '#64748B'


def presentation_roots(project, values):
    if values is None:
        return []
    require(isinstance(values, (list, tuple)) and len(values) <= len(_PALETTE),
            'lineage_roots must be an ordered list of up to six exact local DATA references')
    roots = [_exact(_graph_ref(project, value, ('data',))) for value in values]
    require(len(set(roots)) == len(roots), 'lineage_roots must be distinct')
    return roots


def _short(text, limit, truncated=False):
    prefix, clipped = _clip(text.replace('\n', ' ').replace('\r', ' '), limit)
    return prefix + ('…' if clipped or truncated else '')


def _code_selector(project, rec, node):
    descriptor = rec['details'].get(figure_sources.KEY)
    # The index already validated the whole descriptor; recheck only the selector.
    if not figure_sources.recognized(descriptor) or 'rendering_relationship_invalid' in node['unknown']:
        return None
    try:
        return figure_sources.normalize({'generating_code': descriptor.get('generating_code')},
                                        project, require, safe_relative)['generating_code']
    except (ValueError, KeyError, TypeError):
        return None


def _focused_links(report, nodes, edges):
    if report['ref'] is None or not any(edge[2] == 'revision_of' for edge in edges):
        return nodes, edges
    downstream = report['direction'] == 'downstream'
    neighbors = {key: [] for key in nodes}
    non_history = [edge for edge in edges if edge[2] != 'revision_of']
    for source, target, _, _ in non_history:
        start, end = (source, target) if downstream else (target, source)
        neighbors[start].append(end)
    queue = [_exact(report['ref'])]
    reached = set(queue)
    for start in queue:
        for end in neighbors[start]:
            if end not in reached:
                reached.add(end)
                queue.append(end)
    return ({key: node for key, node in nodes.items() if key in reached},
            [edge for edge in non_history if edge[0] in reached and edge[1] in reached])


def presentation_dot(project, report, roots):
    nodes = {_exact(node['ref']): node for node in report['nodes']}
    edges = [(_exact(edge['from']), _exact(edge['to']), edge['type'],
              edge['basis'] == 'declared' and _FLOW.get(edge['type']) ==
              (nodes[_exact(edge['from'])]['kind'], nodes[_exact(edge['to'])]['kind']))
             for edge in report['edges']]
    nodes, edges = _focused_links(report, nodes, edges)
    omitted_nodes = len(report['nodes']) - len(nodes)
    omitted_edges = len(report['edges']) - len(edges)
    seeds = {root: i for i, root in enumerate(roots)}
    sources = {key: {seeds[key]} if key in seeds else set() for key in nodes}
    # Propagation is monotone and terminates even when visible records form a cycle.
    changed = True
    while changed:
        changed = False
        for source, target, _, flows in edges:
            if flows and target not in seeds and not sources[source] <= sources[target]:
                sources[target].update(sources[source])
                changed = True

    node_lines, edge_lines, notes, note_links = [], [], [], []
    seen = {'question': {}, 'code': {}}
    omissions = {'question': 0, 'code': 0}
    links = {'question': 0, 'code': 0}

    def add_note(kind, identity, label, target):
        ids = seen[kind]
        if links[kind] >= _NOTE_LINK_LIMIT or identity not in ids and len(ids) >= _NOTE_LIMIT:
            omissions[kind] += 1
            return False
        if identity not in ids:
            ids[identity] = f'annotation-{kind}-{len(ids) + 1}'
            notes.append('  ' + _quote(ids[identity]) + ' [shape=note, style="filled,dashed", '
                         'fillcolor="#F8FAFC", fontsize=11, label=' + _quote(label) + '];')
        note_links.append('  ' + _quote(target) + ' -> ' + _quote(ids[identity])
                          + ' [style=dashed, dir=none, color="' + _NEUTRAL + '"];')
        links[kind] += 1
        return True

    for key, node in nodes.items():
        rec = project._record(node['ref'])
        desc = presentation._read(rec)[1]
        if desc is not None:
            for question in dict.fromkeys(desc['questions']):
                add_note('question', question, 'Question context\n' + _short(question, 112), key)
        title, shape = _TYPES[node['asset_type']]
        label = f"{title}  ·  {key}\n" + _short(node['label'], 72, node['label_truncated'])
        color, fill = '#475569', '#F1F5F9'
        groups = sorted(sources[key])
        if groups:
            marker = 'Source boundary ' if key in seeds else 'Sources ' if len(groups) > 1 else 'Source '
            label += '\n' + marker + ' + '.join(str(i + 1) for i in groups)
            if len(groups) == 1:
                color, fill = _PALETTE[groups[0]]
            else:
                label += ' (mixed)'
        if node['asset_type'] == 'FIG':
            unknown = node['unknown']
            if 'rendering_inputs_unknown' in unknown or 'rendering_relationship_invalid' in unknown:
                label += '\nRendering inputs unknown'
            elif 'rendering_relationship_unknown' in unknown:
                inputs = rec['details'][figure_sources.KEY].get('rendering_inputs')
                label += '\nRendering link unconfirmed' if inputs else '\nRendering inputs unknown'
            selector = _code_selector(project, rec, node)
            if selector is None:
                label += '\nPlotting code unknown'
            else:
                owner, index, digest = _exact(selector['record']), selector['index'], selector['sha256']
                locator = project._record(selector['record'])['code'][index]['locator']
                basename = locator['value'].replace('\\', '/').rsplit('/', 1)[-1] if locator['kind'] != 'uri' else ''
                callout = 'Declared plotting code\n'
                if basename.strip() and basename not in ('.', '..'):
                    callout += _short(basename, 64) + '\n'
                callout += f'{owner} · entry {index} · sha256 {digest[:12]}'
                if not add_note('code', (owner, index, digest), callout, key):
                    label += '\nPlotting code note omitted'
        node_lines.append(f'  {_quote(key)} [shape={shape}, color="{color}", fillcolor="{fill}", label={_quote(label)}];')

    for source, target, kind, flows in edges:
        if flows:
            colors = ':'.join(_PALETTE[i][0] for i in sorted(sources[source])) or _NEUTRAL
            attrs = f'color="{colors}"'
        else:
            label = _CONTEXT.get(kind, kind.replace('_', ' '))
            attrs = f'style=dashed, constraint=false, color="{_NEUTRAL}", label={_quote(label)}'
        edge_lines.append(f'  {_quote(source)} -> {_quote(target)} [{attrs}];')

    snapshot = report['snapshot']
    scope = ('Project page (on-page links only)' if report['ref'] is None else
             f"{report['direction'].capitalize()} of {_exact(report['ref'])} (depth {report['depth']})")
    flags = ', '.join(report['truncation']) or 'none'
    cycle = 'Detailed view cycle check' if omitted_edges else 'Visible cycle check'
    header = ['Recorded lineage', scope,
              'Solid: recorded computational links   |   Dashed: context or unconfirmed links',
              'Declarations do not establish execution or approval.',
              f"Omissions: {flags}   |   {cycle}: {report['cycle']}"]
    if omitted_edges:
        header.append(f'Revision history omitted (records: {omitted_nodes}; links: {omitted_edges}). See detailed view.')
    if report['next_offset'] is not None:
        header.append(f"Next page offset: {report['next_offset']}")
    if snapshot['imported']:
        header.append('Imported records; execution claims unverified')
    if snapshot['unsaved']:
        header.append('Includes unsaved edits')
    if report['cycle'] == 'unknown' or any(node['issue'] for node in nodes.values()):
        header.append('See detailed graph for unresolved links or view limits.')
    if any(omissions.values()):
        header.append(f"Annotation links omitted: questions {omissions['question']}; plotting code {omissions['code']}")
    for i, root in enumerate(roots, 1):
        desc = ' — ' + _short(nodes[root]['label'], 72, nodes[root]['label_truncated']) if root in nodes else ' (not in view)'
        header.append(f'Source {i}: {root}{desc}')
    lines = [
        'digraph biodataledger {',
        '  graph [rankdir=TB, labelloc=t, labeljust=l, bgcolor="white", fontname="Helvetica",'
        ' fontsize=15, pad=0.24, nodesep=0.32, ranksep=0.60, label=' + _quote('\n'.join(header))
        + ', project_id=' + _quote(snapshot['project_id'])
        + ', registry_revision=' + _quote(str(snapshot['registry_revision']))
        + ', transaction=' + _quote(snapshot['last_transaction']) + '];',
        '  node [fontname="Helvetica", fontsize=13, style=filled, fontcolor="#0F172A", margin="0.16,0.10", penwidth=1.4];',
        '  edge [fontname="Helvetica", fontsize=10, fontcolor="#475569", arrowsize=0.7, penwidth=1.6];',
    ]
    dot = '\n'.join(lines + node_lines + notes + edge_lines + note_links + ['}', ''])
    require(len(dot.encode('utf-8')) <= BYTE_LIMIT, 'presentation DOT exceeds 128 KiB; request a narrower view')
    return dot
