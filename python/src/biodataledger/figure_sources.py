"""Small opt-in figure declarations; scientific execution remains uncaptured."""
import copy
import unicodedata

KEY = 'biodataledger.figure_sources'
VERSION = 'biodataledger-figure-sources/1'
FIELDS = {'rendering_inputs', 'relationship', 'generating_code', 'dependencies', 'asset_id'}


def recognized(value):
    return isinstance(value, dict) and value.get('version') == VERSION


def normalize(value, project, require, safe_relative):
    require(isinstance(value, dict) and set(value) <= FIELDS | {'version'}, 'invalid figure_sources fields')
    require('version' not in value or value['version'] == VERSION, 'unsupported figure_sources version')
    out = {'version': VERSION, **{key: copy.deepcopy(value.get(key)) for key in sorted(FIELDS)}}
    out['relationship'] = value.get('relationship', 'unknown')
    require(out['relationship'] in ('declared', 'unknown'), 'invalid rendering relationship')
    require(out['relationship'] != 'declared' or out['rendering_inputs'] is not None, 'rendering inputs unknown')
    if out['rendering_inputs'] is not None:
        require(isinstance(out['rendering_inputs'], list), 'rendering_inputs must be an array or null')
        out['rendering_inputs'] = [project._ref(project._record(ref, 'data')) for ref in out['rendering_inputs']]
    code = out['generating_code']
    if code is not None:
        require(isinstance(code, dict) and {'record', 'index'} <= set(code) <= {'record', 'index', 'sha256', 'registered_ref'}, 'invalid generating code selector')
        owner = project._record(code['record'])
        require(owner['kind'] in ('analysis', 'figure'), 'code owner must be analysis or figure')
        index = code['index']
        require(type(index) is int and 0 <= index < len(owner['code']), 'invalid code index')
        entry = owner['code'][index]
        require(entry['sha256'] is not None and code.get('sha256', entry['sha256']) == entry['sha256'], 'generating code digest conflict')
        code = {'record': project._ref(owner), 'index': index, 'sha256': entry['sha256'], 'registered_ref': code.get('registered_ref')}
        if code['registered_ref'] is not None:
            data = project._record(code['registered_ref'], 'data')
            require(data['sha256'] == entry['sha256'], 'registered code digest conflict')
            code['registered_ref'] = project._ref(data)
        out['generating_code'] = code
    dependencies = out['dependencies']
    if dependencies is not None:
        require(isinstance(dependencies, list), 'dependencies must be an array or null')
        paths = []
        for dependency in dependencies:
            require(isinstance(dependency, dict) and set(dependency) == {'path', 'ref'}, 'invalid dependency')
            path = safe_relative(dependency['path'])
            key = unicodedata.normalize('NFC', path).casefold()
            require(not any(key == old or key.startswith(old + '/') or old.startswith(key + '/') for old in paths), 'dependency path collision')
            paths.append(key)
            dependency['ref'] = project._ref(project._record(dependency['ref'], 'data'))
    require(out['asset_id'] is None or isinstance(out['asset_id'], str) and bool(out['asset_id'].strip()), 'invalid asset_id')
    return out


def describe(project, rec, check_files, require, safe_relative):
    value = rec['details'].get(KEY)
    out = {'rendering_inputs': None, 'relationship': 'unknown', 'generating_code': None,
           'dependencies': None, 'asset_id': None, 'rendering_details': [], 'code': None,
           'dependency_details': [], 'dependency_completeness': 'unknown', 'code_candidates': [], 'missing': [], 'contradictions': []}
    if recognized(value):
        try:
            value = normalize(value, project, require, safe_relative)
            out.update({key: copy.deepcopy(value[key]) for key in FIELDS})
        except ValueError as exc:
            out['contradictions'] = [str(exc)]
            value = None
    else:
        value = None
    for field in ('rendering_inputs', 'generating_code', 'dependencies'):
        if out[field] is None:
            out['missing'].append(field)
    def data_view(ref):
        data = project._record(ref, 'data')
        path = project._resolve(data['locator'])
        return {'ref': copy.deepcopy(ref), 'path': str(path) if path is not None else None,
                'available': bool(path is not None and path.is_file()) if check_files else None,
                'availability_checked': check_files, 'parent': copy.deepcopy(data['details'].get('parent')),
                'transformation_ref': copy.deepcopy((data.get('scope') or {}).get('transformation_ref'))}
    out['rendering_details'] = [data_view(ref) for ref in out['rendering_inputs'] or []]
    out['dependency_details'] = [dict(data_view(x['ref']), relative_path=x['path']) for x in out['dependencies'] or []]
    def code_view(selector):
        entry = project._record(selector['record'])['code'][selector['index']]
        path = project._resolve({'kind': 'project', 'value': entry['snapshot']}) if entry['snapshot'] else project._resolve(entry['locator'])
        return {'selector': copy.deepcopy(selector), **copy.deepcopy(entry),
                'path': str(path) if path is not None else None,
                'available': bool(entry['snapshot'] in project._snapshots or path is not None and path.is_file()) if check_files else None,
                'availability_checked': check_files, 'integrity': 'not_checked'}
    owner = project._record(rec['analysis'], 'analysis') if rec['analysis'] else rec
    for index, entry in enumerate(owner['code']):
        out['code_candidates'].append(code_view({'record': project._ref(owner), 'index': index, 'sha256': entry['sha256'], 'registered_ref': None}))
    if out['generating_code'] is not None:
        out['code'] = code_view(out['generating_code'])
    if out['relationship'] == 'unknown': out['missing'].append('rendering_relationship')
    if check_files:
        for field, marker in (('rendering_details', 'rendering_file'), ('dependency_details', 'dependency_file'), ('code_candidates', 'code_candidate_file')):
            if any(item['available'] is False for item in out[field]): out['missing'].append(marker)
        if out['code'] is not None and out['code']['available'] is False: out['missing'].append('source_file')
    return out


def compact(view, canonical):
    sources = view.figure_sources
    truncated = {'analytical_inputs': 0, 'rendering_inputs': 0, 'dependencies': 0, 'code_candidates': 0, 'fields': []}
    def text(value, key, limit=384):
        if value is not None and len(str(value)) > limit:
            truncated['fields'].append(key)
            return None
        return value
    def ref(value, key):
        if value is not None and len(value['id']) > 64:
            truncated['fields'].append(key)
            return None
        return copy.deepcopy(value)
    def refs(values, key):
        if values is None:
            return None
        out = [ref(value, key) for value in values[:3]]
        out = [value for value in out if value is not None]
        truncated[key] = len(values) - len(out)
        return out
    def params(value, depth=0):
        if depth > 2:
            truncated['fields'].append('params'); return None
        if isinstance(value, dict):
            if len(value) > 3: truncated['fields'].append('params')
            selected = list(value)[:3]
            if any(len(key) > 64 for key in selected): truncated['fields'].append('params')
            return {key: params(value[key], depth + 1) for key in selected if len(key) <= 64}
        if isinstance(value, list):
            if len(value) > 3: truncated['fields'].append('params')
            return [params(x, depth + 1) for x in value[:3]]
        return text(value, 'params', 80) if isinstance(value, str) else value
    def short_code(value):
        code = copy.deepcopy(value)
        if code:
            code['selector']['record'] = ref(code['selector']['record'], 'generating_code')
            code['selector']['registered_ref'] = ref(code['selector']['registered_ref'], 'registered_ref')
            code['locator']['value'] = text(code['locator']['value'], 'code_locator')
            code['path'] = text(code['path'], 'code_path')
        return code
    code = short_code(sources['code'])
    selected = sources['code']['selector'] if sources['code'] else None
    alternatives = [value for value in sources['code_candidates'] if selected is None or
                    any(value['selector'][key] != selected[key] for key in ('record', 'index', 'sha256'))]
    candidates = [short_code(value) for value in alternatives[:3]]
    truncated['code_candidates'] = len(alternatives) - len(candidates)
    rendering_details = []
    for value in sources['rendering_details'][:3]:
        rendering_details.append({'ref': ref(value['ref'], 'rendering_inputs'), 'parent': ref(value['parent'], 'parent'),
                                  'transformation_ref': ref(value['transformation_ref'], 'transformation_ref'),
                                  'available': value['available'], 'integrity': 'not_checked'})
    dependencies = []
    for item in sources['dependency_details'][:3]:
        dependencies.append({'path': text(item['relative_path'], 'dependency_path', 128), 'ref': ref(item['ref'], 'dependencies'), 'available': item['available']})
    truncated['dependencies'] = len(sources['dependency_details']) - len(dependencies)
    entry_point = view.details.get('entry_point')
    if not isinstance(entry_point, str) or not entry_point.strip():
        entry_point = None
    report = {'asset_id': text(view.asset_id, 'asset_id'), 'entry_point': text(entry_point, 'entry_point'), 'ref': ref(view.ref, 'ref'), 'path': text(str(view.path) if view.path is not None else None, 'path'),
              'available': view.available, 'availability_checked': view.availability_checked, 'integrity': 'not_checked',
              'analysis': ref(view.analysis, 'analysis'), 'analytical_inputs': refs(view.inputs, 'analytical_inputs'),
              'rendering_inputs': refs(view.rendering_inputs, 'rendering_inputs'), 'rendering_relationship': view.rendering_relationship,
              'generating_code': code, 'code_candidates': candidates, 'rendering_details': rendering_details,
              'dependencies': dependencies, 'dependency_completeness': 'unknown',
              'method': text(view.method, 'method', 128), 'params': params(view.params),
              'execution': 'unknown', 'execution_evidence': 'not_captured',
              'missing': list(dict.fromkeys(view.unknown + sources['missing'])),
              'contradictions': [text(x, 'contradictions', 160) for x in sources['contradictions'][:3]], 'truncated': truncated}
    if view.availability_checked and view.available is False: report['missing'].append('figure_file')
    while len(canonical(report)) > 4096:
        if report['params'] is not None:
            report['params'] = None; truncated['fields'].append('params')
        elif report['dependencies']:
            report['dependencies'].pop(); truncated['dependencies'] += 1
        elif report['code_candidates']:
            report['code_candidates'].pop(); truncated['code_candidates'] += 1
        elif report['rendering_details']:
            report['rendering_details'].pop(); truncated['fields'].append('rendering_details')
        elif report['rendering_inputs']:
            report['rendering_inputs'].pop(); truncated['rendering_inputs'] += 1
        elif report['analytical_inputs']:
            report['analytical_inputs'].pop(); truncated['analytical_inputs'] += 1
        elif report['generating_code'] is not None:
            report['generating_code'] = None; truncated['fields'].append('generating_code')
        else:
            report = {'ref': ref(view.ref, 'ref'), 'execution': 'unknown', 'execution_evidence': 'not_captured', 'missing': ['report_fields_omitted'], 'truncated': {'all': True}}
            if len(canonical(report)) > 4096: report['ref'] = None
            return report
    truncated['fields'] = list(dict.fromkeys(truncated['fields']))
    return report
