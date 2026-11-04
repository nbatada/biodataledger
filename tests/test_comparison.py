"""Explicit comparison types, submitted evidence and no payload inference."""
import copy,json,os,subprocess,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from biodataledger import ProjectBundle,BundleError

class ComparisonTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.root=Path(tmp.name)
        (self.root/'input').write_text('1');(self.root/'run.py').write_text("from pathlib import Path\ndef run(inputs,params,seeds,outputs):\n    for x in outputs: Path(x).write_text('1')\n")
        self.p=ProjectBundle.create('synthetic comparisons',self.root);self.d=self.p.register_data('input','input',hash=True)
        self.a=self.p.register_analysis('method',[self.d],code='run.py',method='synthetic',params={'n':1})
        self.old=self.run_record(self.a,'old');self.new=self.run_record(self.a,'new')
        self.evidence=self.p.record_decision('manual numeric review','synthetic retained comparison',self.subjects())
        self.criteria=[dict(criterion_id='output',required=True,domain='output',slots=['result'],comparison_kind='manual',requirement={'rubric':'values identical','scope':'all rows'},comparator_ref=self.evidence)]
    def run_record(self,a,name):
        r=self.p.run_analysis(a,'run',[{'path':name,'kind':'result'}]);return {'analysis_ref':r['receipt_ref'],'outputs':[{'slot_id':'result','ref':r['outputs'][0]['record_ref']}]}
    def subjects(self):return [self.old['outputs'][0]['ref'],self.new['outputs'][0]['ref']]
    def plan(self,mode='reproduce',**intent):
        return self.p.register_comparison_plan('comparison',mode,self.old,dict(input_refs=[self.d],retrospective=True,**intent),self.criteria,'synthetic')
    def obs(self,verdict='PASS',**changes):
        result=dict(criterion_id='output',verdict=verdict,observed='identical values',reason='synthetic observation',evidence=[self.evidence],subjects=self.subjects(),comparator_ref=self.evidence);result.update(changes);return [result]
    def assess(self,plan,observations=None,candidate=None,**kw):return self.p.record_comparison_assessment(plan,candidate or self.new,self.obs() if observations is None else observations,'synthetic',**kw)
    def check_native(self, ref):
        self.p.save_and_confirm()
        request=self.root/'native-read.json';request.write_text(json.dumps({'ref':ref,'read_only':True}))
        env=dict(os.environ);env['R_LIBS_USER']=os.pathsep.join(filter(None,(env.get('BDL_R_LIB',str(Path('.r-library').resolve())),env.get('R_LIBS_USER',''))))
        result=subprocess.run(['Rscript','--vanilla',str(Path(__file__).with_name('r_comparison_exchange.R')),str(self.root),str(request)],env=env,capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['view'],self.p.get_comparison(ref))

    def test_verdicts_are_evidence_not_approval(self):
        plan=self.plan()
        for status in ('PASS','FAIL','UNKNOWN'):
            ref=self.assess(plan,self.obs(status));view=self.p.get_comparison(ref)
            self.assertEqual(view['verdict'],status);self.assertEqual(view['approval'],'not_applicable');self.assertIsNone(view['scientific'])
            decision=self.p.get_decision(ref);self.assertIsNone(decision['scientific']);self.assertEqual(decision['approval'],'not_applicable')
        for observation in ([],self.obs(evidence=[]),self.obs(subjects=[]),self.obs(observed=None),self.obs(comparator_ref=self.d)):
            self.assertEqual(self.p.get_comparison(self.assess(plan,observation))['verdict'],'UNKNOWN')
        unrelated=self.p.record_decision('unrelated','not these outputs',[self.d]);self.assertEqual(self.p.get_comparison(self.assess(plan,self.obs(evidence=[unrelated])))['verdict'],'UNKNOWN')
    def test_history_typeguards_and_mixed_approval(self):
        plan=self.plan();first=self.assess(plan,self.obs('FAIL'));old=copy.deepcopy(self.p._record(first))
        second=self.assess(plan,ref=first);self.assertEqual(self.p.get_comparison(second)['verdict'],'PASS');self.assertEqual(self.p._record(first),old)
        for operation in (lambda:self.p.update_record(plan,{'status':'inactive'},'bad'),lambda:self.p.record_scientific_decision('approve','bad',[{'ref':self.d}],'approved',ref=first),lambda:self.p.register_protocol('convert',[{'step_id':'s','analysis_ref':self.a,'required_outputs':[{'kind':'result'}]}],'bad',ref=plan),lambda:self.p.register_analysis('inject',[],comparison_plan={}),lambda:self.assess(plan,candidate=self.old,ref=second)):
            with self.assertRaises(BundleError):operation()
        scientific=self.p.record_scientific_decision('approval','scientist submitted',[{'ref':plan}],'approved')
        with self.assertRaises(BundleError):self.assess(plan,ref=scientific)
        self.p._record(first)['details']['scientific_decision']=copy.deepcopy(self.p._record(scientific)['details']['scientific_decision'])
        self.assertIsNone(self.p.get_decision(first)['scientific']);self.assertEqual(self.p.get_comparison(first)['verdict'],'UNKNOWN')
    def test_wrong_inputs_producer_and_unknown_execution(self):
        plan=self.plan();other=self.p.register_data('input','other identity',hash=True)
        a=self.p.register_analysis('new',[other],code='run.py',method='synthetic',params={'n':1});candidate=self.run_record(a,'other-output')
        self.assertEqual(self.p.get_comparison(self.assess(plan,candidate=candidate))['verdict'],'FAIL')
        bad=copy.deepcopy(self.new);bad['outputs']=self.old['outputs'];self.assertEqual(self.p.get_comparison(self.assess(plan,candidate=bad))['verdict'],'FAIL')
        plain={'analysis_ref':self.a,'outputs':self.old['outputs']}
        view=self.p.get_comparison(self.assess(plan,candidate=plain));self.assertNotEqual(view['verdict'],'PASS')
    def test_reapply_needs_mapping_and_new_approval(self):
        source=self.p.register_protocol('source',[{'step_id':'s','analysis_ref':self.a,'required_outputs':[{'kind':'result'}]}],'source')
        oldapproval=self.p.record_scientific_decision('approved','submitted',[{'ref':source}],'approved')
        newdata=self.p.register_data('input','new input',hash=True);a=self.p.register_analysis('apply',[newdata],code='run.py',method='synthetic',params={'n':1})
        target=self.p.register_protocol('new input',[{'step_id':'s','analysis_ref':a,'required_outputs':[{'kind':'result'}]}],'new binding',ref=source)
        approval=self.p.record_scientific_decision('approved new','submitted',[{'ref':target}],'approved')
        self.new=self.run_record(a,'apply');self.evidence=self.p.record_decision('comparison','new output valid',self.subjects());self.criteria[0]['comparator_ref']=self.evidence
        intent=dict(input_refs=[newdata],retrospective=True,protocol_ref=target,approval_ref=approval,source_protocol_ref=source,source_approval_ref=oldapproval,input_mapping=[{'index':0,'from':self.d,'to':newdata}])
        p=self.p.register_comparison_plan('reapply','reapply',self.old,intent,self.criteria,'plan');ref=self.assess(p);self.assertEqual(self.p.get_comparison(ref)['verdict'],'PASS');self.check_native(ref)
        intent['approval_ref']=oldapproval;p=self.p.register_comparison_plan('bad','reapply',self.old,intent,self.criteria,'plan');self.assertEqual(self.p.get_comparison(self.assess(p))['verdict'],'FAIL')
    def test_rerender_requires_same_result_and_visual_changes(self):
        result=self.old['outputs'][0]['ref'];sides=[]
        for name,color in [('figold','blue'),('fignew','red')]:
            a=self.p.register_analysis(name,[result],code='run.py',method='render',params={'color':color});r=self.p.run_analysis(a,'run',[{'path':name,'kind':'figure','type':'plot'}]);fig=r['outputs'][0]['record_ref']
            fig=self.p.update_record(fig,{'figure_sources':{'rendering_inputs':[result],'relationship':'declared'}},'declare rendering source')
            sides.append({'analysis_ref':r['receipt_ref'],'outputs':[{'slot_id':'result','ref':fig}]})
        self.old,self.new=sides;self.evidence=self.p.record_decision('visual review','labels readable',self.subjects());self.criteria[0].update(domain='visual',comparator_ref=self.evidence)
        plan=self.p.register_comparison_plan('rerender','rerender',self.old,{'input_refs':[result],'retrospective':True,'visual_changes':{'color':'red'}},self.criteria,'plan')
        ref=self.assess(plan);self.assertEqual(self.p.get_comparison(ref)['verdict'],'PASS');self.check_native(ref)
        self.p._record(self.new['outputs'][0]['ref'])['details']['biodataledger.figure_sources']['rendering_inputs']=[self.d]
        self.assertEqual(self.p.get_comparison(self.assess(plan))['verdict'],'FAIL')
    def test_required_fail_precedence_plan_revisions_and_validation(self):
        extra=copy.deepcopy(self.criteria[0]);extra['criterion_id']='second';self.criteria.append(extra)
        plan=self.plan();first=self.assess(plan,self.obs('FAIL'))
        self.assertEqual(self.p.get_comparison(first)['verdict'],'FAIL')
        revised=self.p.register_comparison_plan('revised','reproduce',self.old,{'input_refs':[self.d],'retrospective':True},self.criteria,'revision',ref=plan)
        self.assertEqual(self.p.get_comparison(first)['descriptor']['plan_ref'],plan)
        with self.assertRaises(BundleError):self.assess(revised,ref=first)
        self.assertEqual(self.p.get_comparison(self.assess(plan,candidate=self.old))['verdict'],'FAIL')
        bad=copy.deepcopy(self.criteria);bad[0]['required']=False;bad[1]['required']=False
        with self.assertRaises(BundleError):self.p.register_comparison_plan('bad','reproduce',self.old,{'input_refs':[self.d],'retrospective':True},bad,'why')
        with self.assertRaises(BundleError):self.assess(plan,self.obs()+self.obs())
        numeric=copy.deepcopy(self.criteria[:1]);numeric[0].update(comparison_kind='numeric',requirement=dict(metric='max_abs_error',units='value',operator='<=',threshold=float('nan'),alignment=['id'],aggregation='max',missing='unknown',nonfinite='unknown',exclusions=[]))
        with self.assertRaises(BundleError):self.p.register_comparison_plan('bad numeric','reproduce',self.old,{'input_refs':[self.d],'retrospective':True},numeric,'why')
        legacy=self.p.record_decision('legacy','why',[self.d]);self.assertEqual(self.p.get_decision(legacy)['approval'],'not_authenticated')

    def test_missing_plan_and_external_evidence_binding(self):
        plan=self.plan();ref=self.assess(plan);self.p._record(plan)['details']['comparison_plan']['version']='future'
        self.assertEqual(self.p.get_comparison(ref)['verdict'],'UNKNOWN');self.check_native(ref)
        (self.root/'method.txt').write_text('external comparator v1')
        method=self.p.register_data('method.txt','external method')
        (self.root/'report.txt').write_text('synthetic identical values')
        evidence=self.p.register_data('report.txt','external comparison',comparison_subjects=self.subjects(),comparison_comparator_ref=method)
        self.criteria[0]['comparator_ref']=method;plan=self.plan()
        assessment=self.assess(plan,self.obs(comparator_ref=method,evidence=[evidence]))
        self.assertEqual(self.p.get_comparison(assessment)['verdict'],'PASS')
        self.p._record(evidence)['details']['comparison_subjects']=[self.d]
        self.assertEqual(self.p.get_comparison(assessment)['verdict'],'UNKNOWN')

    def test_conflicts_independent_support_and_separate_acceptance(self):
        plan=self.plan();contradiction=self.p.record_decision('conflict','output differs',self.subjects())
        observation=self.obs(contradictory_evidence=[contradiction])
        ref=self.assess(plan,observation);report=self.p.get_comparison(ref)
        self.assertEqual(report['metadata_consistency'],'PASS');self.assertEqual(report['criteria'][0]['submitted']['verdict'],'PASS')
        self.assertEqual(report['verdict'],'UNKNOWN');self.assertIn('conflicting_evidence',report['criteria'][0]['gaps'])
        self.assertEqual(report['scientific_acceptance']['status'],'not_supplied')
        review=self.p.record_decision('independent review','separately submitted review',self.subjects())
        assessed=self.assess(plan,self.obs(independent_review_ref=review));view=self.p.get_comparison(assessed)
        self.assertEqual(view['verdict'],'PASS');self.assertEqual(view['independent_support'][0]['status'],'review_recorded')
        self.assertEqual(view['independent_support'][0]['empirical_verification'],'UNKNOWN')
        selfref=self.assess(plan,self.obs(independent_review_ref=self.evidence))
        self.assertEqual(self.p.get_comparison(selfref)['independent_support'][0]['status'],'UNKNOWN')
        acceptance=self.p.record_scientific_decision('scientist acceptance','submitted separately',[{'ref':assessed}],'approved')
        accepted=self.p.get_comparison(assessed,scientific_acceptance_ref=acceptance)
        self.assertEqual(accepted['approval'],'not_applicable');self.assertEqual(accepted['scientific_acceptance']['status'],'recorded_approved')
        self.assertEqual(self.p.get_comparison(ref,scientific_acceptance_ref=acceptance)['scientific_acceptance']['status'],'UNKNOWN')
        self.assertEqual(self.p.get_comparison(assessed,scientific_acceptance_ref=assessed)['scientific_acceptance']['status'],'UNKNOWN')
        self.check_native(ref);self.check_native(assessed)

    def test_no_io_imports_and_native_roundtrip(self):
        plan=self.plan();assessment=self.assess(plan);self.p.save_and_confirm();path=self.root/'.nb_project_bundle/project.json';before=path.read_bytes()
        with patch('biodataledger.core.fingerprint',side_effect=AssertionError('hash')),patch.object(Path,'open',side_effect=AssertionError('I/O')):
            expected=self.p.get_comparison(assessment)
        self.assertEqual(before,path.read_bytes())
        archive=self.root/'context.zip';self.p.export_zip(self.p.preview_export('context'),archive);q=ProjectBundle.import_zip(archive,self.root/'import');self.assertEqual(q.get_comparison(assessment)['verdict'],'UNKNOWN')
        request=self.root/'request.json';request.write_text(json.dumps({'ref':assessment,'plan':plan,'candidate':self.new,'observations':self.obs()}))
        env=dict(os.environ);env['R_LIBS_USER']=os.pathsep.join(filter(None,(env.get('BDL_R_LIB',str(Path('.r-library').resolve())),env.get('R_LIBS_USER',''))))
        result=subprocess.run(['Rscript','--vanilla',str(Path(__file__).with_name('r_comparison_exchange.R')),str(self.root),str(request)],env=env,capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr);native=json.loads(result.stdout);self.assertEqual(native['view'],expected)
        reopened=ProjectBundle.open(self.root);self.assertEqual(reopened.get_comparison(native['new_ref']),native['new_view'])
if __name__=='__main__':unittest.main()
