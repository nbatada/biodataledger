"""Adversarial synthetic checkpoints, never proof of consumption."""
import tempfile
from pathlib import Path
import unittest
from biodataledger import ProjectBundle, BundleError

class InputControlTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); (self.root/'input').write_text('checked'); (self.root/'other').write_text('different')
        self.p=ProjectBundle.create('synthetic',self.root)
        self.d=self.p.register_data('input','input',hash=True)
    def analysis(self,body,top=''):
        code=self.root/'run.py'; code.write_text('from pathlib import Path\n'+top+'\ndef run(inputs, params, seeds, outputs):\n'+body+'\n')
        return self.p.register_analysis('test',[self.d],code=str(code),method='synthetic',params={})
    def test_inactive_rejected_like_resolution(self):
        self.d=self.p.update_record(self.d,{'status':'inactive'},'synthetic')
        a=self.analysis("    raise AssertionError('callback must not run')")
        with self.assertRaises(BundleError):self.p.resolve_data(ref=self.d,verify='sha256')
        for verify in (True,False):
            with self.assertRaises(BundleError) as caught:self.p.run_analysis(a,'run',verify_inputs=verify)
            self.assertFalse(caught.exception.receipt['phases']['callback_invoked'])
            self.assertEqual(caught.exception.receipt['status'],'blocked')
    def test_missing_modified_block_before_invocation(self):
        a=self.analysis('    pass')
        for mutation in ('changed',None):
            if mutation:(self.root/'input').write_text(mutation)
            else:(self.root/'input').unlink()
            with self.assertRaises(BundleError) as caught:self.p.run_analysis(a,'run')
            self.assertFalse(caught.exception.receipt['phases']['callback_invoked'])
    def test_ignored_input_is_never_consumption_evidence(self):
        a=self.analysis('    Path(outputs[0]).write_text(Path('+repr(str(self.root/'other'))+').read_text())')
        receipt=self.p.run_analysis(a,'run',[{'path':'output','kind':'result'}])
        self.assertEqual((self.root/'output').read_text(),'different')
        self.assertEqual(receipt['input_consumption'],'unknown')
        self.assertEqual(receipt['inputs'][0]['identity'],'match')
    def test_top_level_mutation_prevents_callback(self):
        a=self.analysis('    Path('+repr(str(self.root/'marker'))+').write_text("called")', 'Path('+repr(str(self.root/'input'))+').write_text("changed")')
        with self.assertRaises(BundleError) as caught:self.p.run_analysis(a,'run')
        self.assertFalse(caught.exception.receipt['phases']['callback_invoked'])
        self.assertFalse((self.root/'marker').exists())
        self.assertNotEqual(caught.exception.receipt['inputs'][0]['identity'],'match')
    def test_callback_mutation_revokes_latest_file_match(self):
        a=self.analysis('    Path(inputs[0]).write_text("changed")')
        with self.assertRaises(BundleError) as caught:self.p.run_analysis(a,'run')
        r=caught.exception.receipt
        self.assertTrue(r['phases']['callback_invoked']);self.assertEqual(r['status'],'failed')
        self.assertNotEqual(r['inputs'][0]['identity'],'match')
        self.assertEqual(r['input_consumption'],'unknown')
    def test_checkpoint_receipts_and_legacy_compatibility(self):
        a=self.analysis('    pass');r=self.p.run_analysis(a,'run')
        self.assertEqual([c['phase'] for c in r['input_checkpoints']['checks']],['preflight','before_callback','after_callback'])
        self.assertEqual(self.p.get_execution(r['receipt_ref'])['status'],'succeeded')
        rec=self.p._record(r['receipt_ref']);rec['details']['execution_receipt'].pop('input_checkpoints')
        self.assertEqual(self.p.get_execution(r['receipt_ref'])['status'],'succeeded')
if __name__=='__main__':unittest.main()
