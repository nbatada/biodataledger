"""Recorded comparison evidence, never scientific approval or execution."""
import copy
import math
from .core import BundleError, canonical, now, require
from .protocol import _same

PLAN = 'comparison_plan'
ASSESSMENT = 'comparison_assessment'
KEYS = {PLAN, ASSESSMENT}
TYPED = KEYS | {'scientific_decision', 'analysis_protocol'}


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _bound(value):
    require(len(canonical(value)) <= 65536, 'comparison metadata exceeds 64 KiB')
    refs=set()
    def visit(item):
        if isinstance(item,dict):
            if set(item)=={'project_id','id','revision'}:refs.add((item['project_id'],item['id'],item['revision']))
            else:
                for child in item.values():visit(child)
        elif isinstance(item,list):
            for child in item:visit(child)
    visit(value)
    require(len(refs)<=100,'comparison exceeds 100 distinct references')
    return value


def _refs(project, value):
    require(isinstance(value, list) and len(value) <= 100, 'bounded reference list required')
    return [project._ref(project._record(x)) for x in value]


def _side(project, value):
    require(isinstance(value, dict) and set(value) == {'analysis_ref', 'outputs'}, 'analysis_ref and outputs required')
    analysis_record=project._record(value['analysis_ref'], 'analysis')
    _bound(analysis_record)
    analysis = project._ref(analysis_record)
    outputs = value['outputs']
    require(isinstance(outputs, list) and 0 < len(outputs) <= 20, '1–20 output slots required')
    result, ids = [], set()
    for item in outputs:
        require(isinstance(item, dict) and set(item) == {'slot_id', 'ref'} and _text(item['slot_id']) and item['slot_id'] not in ids, 'unique output slot required')
        ids.add(item['slot_id']); record = project._record(item['ref'])
        require(record['kind'] in ('data', 'figure'), 'output must be DATA or FIG')
        result.append({'slot_id': item['slot_id'], 'ref': project._ref(record)})
    return {'analysis_ref': analysis, 'outputs': result}


def _plan(project, mode, original, intended, criteria):
    require(mode in ('reproduce', 'reapply', 'rerender'), 'invalid comparison mode')
    original = _side(project, original)
    fields = {'input_refs','protocol_ref','approval_ref','source_protocol_ref','source_approval_ref','input_mapping','visual_changes','environment_ref','retrospective'}
    require(isinstance(intended, dict) and {'input_refs','retrospective'} <= set(intended) <= fields, 'explicit intended inputs/retrospective required')
    target = dict(protocol_ref=None, approval_ref=None, source_protocol_ref=None, source_approval_ref=None, input_mapping=[], visual_changes={}, environment_ref=None)
    target.update(copy.deepcopy(intended)); target['input_refs'] = _refs(project,target['input_refs'])
    require(type(target['retrospective']) is bool and isinstance(target['visual_changes'],dict), 'invalid intent')
    for ref in target['input_refs']: project._record(ref,'data')
    for field in ('protocol_ref','approval_ref','source_protocol_ref','source_approval_ref','environment_ref'):
        if target[field] is not None: target[field] = project._ref(project._record(target[field], None if field=='environment_ref' else 'decision'))
    require(isinstance(target['input_mapping'],list) and len(target['input_mapping'])<=100,'bounded mapping required')
    for item in target['input_mapping']:
        require(isinstance(item,dict) and set(item)=={'index','from','to'} and type(item['index']) is int and item['index']>=0,'mapping index/from/to required')
        for field in ('from','to'): item[field]=project._ref(project._record(item[field],'data'))
    require(mode=='reapply' or not target['input_mapping'],'input mapping only for reapply')
    require(mode=='rerender' or not target['visual_changes'],'visual changes only for rerender')
    require(isinstance(criteria,list) and 0<len(criteria)<=20,'1–20 criteria required')
    normalized, ids = [],set(); slots={x['slot_id'] for x in original['outputs']}
    requirements={'manual':{'rubric','scope'},'numeric':{'metric','units','operator','threshold','alignment','aggregation','missing','nonfinite','exclusions'},'bytes':{'algorithm'},'structural':{'keys','order','duplicates'}}
    for c in criteria:
        require(isinstance(c,dict) and set(c)=={'criterion_id','required','domain','slots','requirement','comparator_ref','comparison_kind'},'invalid criterion fields')
        require(_text(c['criterion_id']) and c['criterion_id'] not in ids and type(c['required']) is bool,'unique criterion ID/required flag')
        ids.add(c['criterion_id'])
        require(c['domain'] in ('identity','method','output','visual') and c['comparison_kind'] in requirements,'invalid criterion kind/domain')
        require(isinstance(c['slots'],list) and c['slots'] and all(isinstance(x,str) and x in slots for x in c['slots']) and len(set(c['slots']))==len(c['slots']),'invalid criterion slots')
        require(isinstance(c['requirement'],dict) and requirements[c['comparison_kind']] <= set(c['requirement']),'explicit comparison requirements missing')
        require(all(c['requirement'][x] is not None for x in requirements[c['comparison_kind']]),'null comparison requirements')
        require(all(not isinstance(c['requirement'][x],str) or _text(c['requirement'][x]) for x in requirements[c['comparison_kind']]),'blank comparison requirements')
        if c['comparison_kind']=='numeric':
            rule=c['requirement'];require(rule['operator'] in ('<','<=','==','>=','>') and type(rule['threshold']) in (int,float) and math.isfinite(rule['threshold']),'numeric operator/finite threshold required')
        item=copy.deepcopy(c); comp=project._record(c['comparator_ref']);require(comp['kind'] in ('analysis','data','decision'),'comparator reference required')
        item['comparator_ref']=project._ref(comp);normalized.append(item)
    require(any(c['required'] and c['domain'] in ('output','visual') for c in normalized),'required output/visual criterion required')
    return _bound({'record_type':PLAN,'version':'biodataledger-comparison-plan/1','mode':mode,'original':original,'intended':target,'criteria':normalized})


def _assessment(project, plan_ref, candidate, observations):
    plan_ref=project._ref(project._record(plan_ref,'decision'))
    record=project._record(plan_ref)
    require(TYPED & set(record['details']) == {PLAN},'exact comparison plan required')
    plan=_read(project,record)[1]
    require(plan is not None and plan['record_type']==PLAN,'comparison plan required')
    candidate=_side(project,candidate)
    require([x['slot_id'] for x in candidate['outputs']]==[x['slot_id'] for x in plan['original']['outputs']],'candidate output slots must match plan')
    require(isinstance(observations,list) and len(observations)<=20,'bounded observations required')
    ids=set();known={c['criterion_id'] for c in plan['criteria']};normalized=[]
    for item in observations:
        require(isinstance(item,dict) and {'criterion_id','verdict','observed','reason','evidence','subjects','comparator_ref'} <= set(item) <= {'criterion_id','verdict','observed','reason','evidence','subjects','comparator_ref','contradictory_evidence','independent_review_ref'},'invalid observation fields')
        require(item['criterion_id'] in known and item['criterion_id'] not in ids and item['verdict'] in ('PASS','FAIL','UNKNOWN') and _text(item['reason']),'invalid observation')
        ids.add(item['criterion_id']);v=dict(contradictory_evidence=[],independent_review_ref=None);v.update(copy.deepcopy(item))
        require(isinstance(v['evidence'],list) and len(v['evidence'])<=10,'at most10 evidence refs')
        v['evidence']=_refs(project,v['evidence']);v['subjects']=_refs(project,v['subjects'])
        require(isinstance(v['contradictory_evidence'],list) and len(v['contradictory_evidence'])<=10,'at most10 contradictory refs')
        v['contradictory_evidence']=_refs(project,v['contradictory_evidence'])
        if v['independent_review_ref'] is not None:v['independent_review_ref']=project._ref(project._record(v['independent_review_ref'],'decision'))
        if v['comparator_ref'] is not None:v['comparator_ref']=project._ref(project._record(v['comparator_ref']))
        normalized.append(v)
    return _bound({'record_type':ASSESSMENT,'version':'biodataledger-comparison-assessment/1','plan_ref':plan_ref,'candidate':candidate,'observations':normalized})


def _read(project, record):
    present=TYPED & set(record['details'])
    if len(present)!=1 or not (present & KEYS):return None,None
    key=next(iter(present));v=record['details'][key]
    try:
        require(isinstance(v,dict) and v.get('record_type')==key,'invalid record type')
        if key==PLAN: normalized=_plan(project,v['mode'],v['original'],v['intended'],v['criteria'])
        else: normalized=_assessment(project,v['plan_ref'],v['candidate'],v['observations'])
        require(_same(v,normalized),'noncanonical comparison')
        return key,normalized
    except (BundleError,TypeError,KeyError,ValueError,RecursionError):return key,None


def _write(project,key,name,value,reason,ref):
    require(_text(name) and _text(reason),'name/reason required')
    if ref is None:rec=project._new('decision',name)
    else:
        old=project._record(ref,'decision');kind,prior=_read(project,old)
        require(kind==key and prior is not None and old['revision']==project._latest_index[old['id']]['revision'],'latest matching comparison revision required')
        if key==ASSESSMENT: require(_same(prior['plan_ref'],value['plan_ref']) and _same(prior['candidate'],value['candidate']),'assessment plan/candidate binding immutable')
        rec=copy.deepcopy(old);rec['revision']+=1;rec['created_at']=now()
    rec['name']=name;rec['details']={'reason':reason,'approval':'not_applicable',key:value}
    return project._stage(rec,'register_'+key,reason)


def register_comparison_plan(project,name,mode,original,intended,criteria,reason,ref=None):
    return _write(project,PLAN,name,_plan(project,mode,original,intended,criteria),reason,ref)


def record_comparison_assessment(project,plan_ref,candidate,observations,reason,ref=None):
    return _write(project,ASSESSMENT,'Comparison assessment',_assessment(project,plan_ref,candidate,observations),reason,ref)


def _approval(project,ref,subject):
    if ref is None or subject is None:return 'UNKNOWN'
    view=project.get_decision(ref);s=view['scientific']
    if project.state['imported'] or s is None:return 'UNKNOWN'
    return 'PASS' if s['scientific_status']=='approved' and [x['ref'] for x in s['subjects']]==[subject] else 'FAIL'


def _context(project,plan,candidate):
    checks=[]
    def add(name,status):checks.append({'check':name,'verdict':status})
    original=plan['original'];intent=plan['intended'];mode=plan['mode']
    old=project._record(original['analysis_ref'],'analysis');new=project._record(candidate['analysis_ref'],'analysis')
    add('distinct_candidate_run','PASS' if original['analysis_ref']['id'] != candidate['analysis_ref']['id'] else 'FAIL')
    add('distinct_candidate_outputs','PASS' if all(a['ref']!=b['ref'] for a,b in zip(original['outputs'],candidate['outputs'])) else 'FAIL')
    add('intended_inputs','UNKNOWN' if new['inputs'] is None else 'PASS' if _same(new['inputs'],intent['input_refs']) else 'FAIL')
    if mode in ('reproduce','rerender'):add('same_inputs','UNKNOWN' if old['inputs'] is None or new['inputs'] is None else 'PASS' if _same(old['inputs'],new['inputs']) else 'FAIL')
    else:
        mapping=intent['input_mapping'];expected=[{'index':i,'from':x,'to':y} for i,(x,y) in enumerate(zip(old['inputs'] or [],intent['input_refs']))]
        add('input_mapping','PASS' if old['inputs'] is not None and len(old['inputs'])==len(intent['input_refs']) and _same(mapping,expected) else 'FAIL')
        add('source_approval',_approval(project,intent['source_approval_ref'],intent['source_protocol_ref']))
        add('target_approval',_approval(project,intent['approval_ref'],intent['protocol_ref']))
    for field in (('method',) if mode=='rerender' else ('method','code')):
        add('same_'+field,'UNKNOWN' if not old[field] or not new[field] else 'PASS' if _same(old[field],new[field]) else 'FAIL')
    expected_params=copy.deepcopy(old['params'])
    observed_params=copy.deepcopy(new['params'])
    dynamic=[]
    if intent['protocol_ref'] is not None:
        protocol=project.get_protocol(intent['protocol_ref'])['protocol']
        if protocol is not None and len(protocol['steps'])==1:dynamic=protocol['steps'][0]['data_dependent_params']
    for key in dynamic:
        if isinstance(expected_params,dict):expected_params.pop(key,None)
        if isinstance(observed_params,dict):
            if key not in observed_params:add('data_dependent_'+key,'UNKNOWN')
            observed_params.pop(key,None)
    if mode=='rerender' and isinstance(expected_params,dict):expected_params.update(intent['visual_changes'])
    add('parameters','UNKNOWN' if expected_params is None or observed_params is None else 'PASS' if _same(expected_params,observed_params) else 'FAIL')
    for label,side in [('original',original),('candidate',candidate)]:
        receipt=project.get_execution(side['analysis_ref'])
        add(label+'_execution','UNKNOWN' if receipt['status']=='unknown' or project.state['imported'] else 'PASS' if receipt['status']=='succeeded' else 'FAIL')
        anchor=receipt.get('run_ref',side['analysis_ref'])
        for slot in side['outputs']:
            rec=project._record(slot['ref']);producer=rec.get('scope',{}).get('transformation_ref') if rec['kind']=='data' else rec['analysis']
            add(label+'_producer_'+slot['slot_id'],'UNKNOWN' if producer is None else 'PASS' if producer==anchor else 'FAIL')
    if mode=='rerender':
        for a,b in zip(original['outputs'],candidate['outputs']):
            oldfig=project._record(a['ref']);newfig=project._record(b['ref'])
            x=oldfig['details'].get('biodataledger.figure_sources',{}).get('rendering_inputs');y=newfig['details'].get('biodataledger.figure_sources',{}).get('rendering_inputs')
            add('same_rendering_result_'+a['slot_id'],'UNKNOWN' if not x or not y else 'PASS' if x==y else 'FAIL')
    if intent['environment_ref'] is not None:add('environment_verification','UNKNOWN')
    if intent['protocol_ref'] is not None:
        protocol=project.get_protocol(intent['protocol_ref'])['protocol']
        add('protocol_binding','UNKNOWN' if protocol is None or len(protocol['steps'])!=1 else 'PASS' if protocol['steps'][0]['analysis_ref']==project.get_execution(candidate['analysis_ref']).get('template_ref') else 'FAIL')
        if protocol is not None and len(protocol['steps'])==1:
            step=protocol['steps'][0]
            compared=project.compare_protocol(intent['protocol_ref'],[{'step_id':step['step_id'],'analysis_ref':candidate['analysis_ref']}])
            row=compared['steps'][0]
            add('protocol_requirements','FAIL' if row['mismatches'] else 'UNKNOWN' if 'execution_receipt' in row['unknown'] or any(x.startswith('data_dependent_param.') for x in row['unknown']) else 'PASS')
    if mode=='reapply' and intent['source_protocol_ref'] is not None:
        source=project.get_protocol(intent['source_protocol_ref'])['protocol']
        add('source_protocol_binding','UNKNOWN' if source is None or len(source['steps'])!=1 else 'PASS' if source['steps'][0]['analysis_ref']==project.get_execution(original['analysis_ref']).get('template_ref') else 'FAIL')
    return checks


def get_comparison(project,ref,scientific_acceptance_ref=None):
    rec=project._record(ref,'decision');kind,value=_read(project,rec)
    out={'ref':project._ref(rec),'record_type':kind,'approval':'not_applicable','scientific':None,'descriptor':value,'verdict':'UNKNOWN','context':[],'criteria':[],
         'claim_scope':'submitted evidence under specified criteria; not scientific reproducibility or approval', 'unknown':['input_consumption','scientific_validity'],
         'metadata_consistency':'UNKNOWN','verdict_qualification':'submitted_evidence_only',
         'independent_support':[], 'scientific_acceptance':{'status':'not_supplied','ref':None,'authentication':'not_authenticated'}}
    if scientific_acceptance_ref is not None:
        acceptance=project.get_decision(scientific_acceptance_ref);scientific=acceptance['scientific']
        bound=scientific is not None and [x['ref'] for x in scientific['subjects']]==[project._ref(rec)]
        out['scientific_acceptance']={'status':('recorded_'+scientific['scientific_status']) if bound and not project.state['imported'] else 'UNKNOWN', 'ref':acceptance['ref'],'authentication':'not_authenticated'}
    if value is None:out['unknown'].append('malformed_or_unsupported_comparison');return out
    if kind==PLAN:return out
    plan=_read(project,project._record(value['plan_ref']))[1];context=_context(project,plan,value['candidate']);out['context']=context
    observations={x['criterion_id']:x for x in value['observations']};required=[]
    for criterion in plan['criteria']:
        item=observations.get(criterion['criterion_id']);effective='UNKNOWN';gaps=[]
        expected=[x['ref'] for side in (plan['original'],value['candidate']) for x in side['outputs'] if x['slot_id'] in criterion['slots']]
        if item is None:gaps.append('observation_missing')
        else:
            if not item['evidence']:gaps.append('evidence_missing')
            if not _same(item['subjects'],expected):gaps.append('subject_binding')
            if item['comparator_ref']!=criterion['comparator_ref']:gaps.append('comparator_binding')
            if item['observed'] is None or isinstance(item['observed'],str) and not _text(item['observed']):gaps.append('observation_unknown')
            comp=project._record(criterion['comparator_ref'])
            evidence_bound=False
            for evidence_ref in item['evidence']:
                evidence=project._record(evidence_ref)
                if comp['kind']=='analysis' and evidence['kind']=='data':
                    anchor=project.get_execution(criterion['comparator_ref']).get('run_ref',criterion['comparator_ref'])
                    evidence_bound |= (evidence.get('scope',{}).get('transformation_ref')==anchor and comp['inputs']==expected)
                elif evidence['kind']=='decision':
                    evidence_bound |= evidence['details'].get('targets')==expected and evidence_ref==criterion['comparator_ref']
                elif comp['kind']=='data' and evidence['kind']=='data':
                    evidence_bound |= (evidence['details'].get('comparison_subjects')==expected and evidence['details'].get('comparison_comparator_ref')==criterion['comparator_ref'])
            if not evidence_bound:gaps.append('evidence_binding')
            if item['contradictory_evidence']:gaps.append('conflicting_evidence')
            if not gaps:effective=item['verdict']
        review_ref=None if item is None else item['independent_review_ref']
        review_status='not_supplied'
        if review_ref is not None:
            review=project._record(review_ref,'decision')
            review_status='review_recorded' if not (TYPED & set(review['details'])) and review['details'].get('targets')==expected and review_ref not in item['evidence']+[item['comparator_ref']] else 'UNKNOWN'
        out['independent_support'].append({'criterion_id':criterion['criterion_id'],'review_ref':review_ref,'status':review_status,'independence':'not_authenticated','empirical_verification':'UNKNOWN'})
        out['criteria'].append({'criterion_id':criterion['criterion_id'],'required':criterion['required'],'submitted':copy.deepcopy(item),'effective':effective,'gaps':gaps})
        if criterion['required']:required.append(effective)
    metadata=[x['verdict'] for x in context]
    out['metadata_consistency']='FAIL' if 'FAIL' in metadata else 'UNKNOWN' if 'UNKNOWN' in metadata else 'PASS'
    statuses=required+metadata
    out['verdict']='FAIL' if 'FAIL' in statuses else 'UNKNOWN' if 'UNKNOWN' in statuses else 'PASS'
    if any('conflicting_evidence' in row['gaps'] for row in out['criteria']):out['verdict_qualification']='conflicting_evidence'
    if project.state['imported']:
        out['unknown'].append('untrusted_imported_claim')
        if out['verdict']=='PASS':out['verdict']='UNKNOWN'
    return _bound(out)
