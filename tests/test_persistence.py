"""Installed native save receipts and fresh-process recovery."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from biodataledger import ProjectBundle, BundleError


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'data.csv').write_text('value\n1\n')
        (self.root / 'figure.svg').write_text('<svg/>')
        self.p = ProjectBundle.create('Synthetic persistence', self.root)
        self.path = self.root / '.nb_project_bundle/project.json'

    def test_receipt_covers_all_pending_changes_and_clean_is_not_write(self):
        d = self.p.register_data('data.csv', 'input')
        a = self.p.register_analysis('Synthetic', [d])
        f = self.p.register_figure('figure.svg', 'fixture', analysis=a)
        self.p.set_current(d, 'analysis', 'synthetic selection')
        before = json.loads(self.path.read_bytes())
        receipt = self.p.save_and_confirm()
        after = json.loads(self.path.read_bytes())
        self.assertEqual(receipt, {
            'status': 'persisted', 'scope': 'all_pending_changes',
            'previous_committed_revision': before['state_revision'],
            'committed_revision': after['state_revision'],
            'transaction_id': after['last_transaction'], 'registry_written': True})
        self.assertEqual(after['state_revision'], before['state_revision'] + 1)
        reopened = ProjectBundle.open(self.root)
        self.assertEqual(reopened.get_figure(f).analysis, a)
        self.assertEqual(reopened.get_data(purpose='analysis').ref, d)
        raw = self.path.read_bytes()
        with patch('pathlib.Path.open', side_effect=AssertionError('clean receipt must not read/write')):
            clean = self.p.save_and_confirm()
        self.assertEqual(clean['status'], 'no_changes')
        self.assertFalse(clean['registry_written'])
        self.assertEqual(clean['previous_committed_revision'], clean['committed_revision'])
        self.assertEqual(self.path.read_bytes(), raw)

    def test_failed_publication_and_stale_save_leave_pending_edits(self):
        other = ProjectBundle.open(self.root)
        d = self.p.register_data('data.csv', 'input')
        before = self.path.read_bytes()
        with patch('biodataledger.core.os.replace', side_effect=OSError('synthetic publication failure')):
            with self.assertRaises(OSError):
                self.p.save_and_confirm()
        self.assertTrue(self.p.unsaved)
        self.assertEqual(self.p.get_data(ref=d).ref, d)
        self.assertEqual(self.path.read_bytes(), before)
        self.p.save_and_confirm()
        other.set_context({'next_task': 'stale pending change'})
        with self.assertRaises(BundleError):
            other.save_and_confirm()
        self.assertTrue(other.unsaved)
        # A clean old session is not refreshed or described as a fresh write.
        stale_clean = ProjectBundle.open(self.root)
        self.p.set_context({'next_task': 'newer committed state'})
        self.p.save_and_confirm()
        self.assertEqual(stale_clean.save_and_confirm()['status'], 'no_changes')

    def test_normal_exit_and_fresh_native_recovery(self):
        script = Path(__file__).with_name('r_persistence_exchange.R')
        python = """
import json,sys
from biodataledger import ProjectBundle
p=ProjectBundle.open(sys.argv[1])
if sys.argv[2]=='write':
 d=p.register_data('data.csv','input')
 a=p.register_analysis('Synthetic',[d])
 p.register_figure('figure.svg','fixture',analysis=a)
 p.set_current(d,'analysis','synthetic')
 p.set_design('treatment',['Vehicle','Drug'])
 p.record_decision('Keep synthetic data','fixture',[d])
 if sys.argv[3]=='saved': print(json.dumps(p.save_and_confirm()))
else:
 expected=sys.argv[3]=='saved'
 assert bool(p.find_figures())==expected
 assert (p.get_design() is not None)==expected
 if expected:
  assert p.get_data(purpose='analysis').ref['id']=='DATA-001'
  assert p.get_analysis('ANA-001@1').name=='Synthetic'
 assert not p.status()['unsaved']
"""
        env = dict(os.environ)
        if env.get('BDL_R_LIB'):
            env['R_LIBS_USER'] = os.pathsep.join(filter(None, (env['BDL_R_LIB'], env.get('R_LIBS_USER', ''))))
        for writer in ('Python', 'R'):
            for mode in ('saved', 'unsaved'):
                root = self.root / (writer + '-' + mode)
                root.mkdir()
                (root / 'data.csv').write_text('value\n1\n')
                (root / 'figure.svg').write_text('<svg/>')
                ProjectBundle.create('Native recovery', root)
                def run(client, action):
                    cmd = ([sys.executable, '-c', python] if client == 'Python'
                           else ['Rscript', '--vanilla', str(script)])
                    result = subprocess.run(cmd + [str(root), action, mode], env=env,
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    return result
                result = run(writer, 'write')
                state = json.loads((root / '.nb_project_bundle/project.json').read_bytes())
                if mode == 'saved':
                    receipt = json.loads(result.stdout)
                    self.assertEqual(receipt['scope'], 'all_pending_changes')
                    self.assertEqual(receipt['status'], 'persisted')
                    self.assertEqual(receipt['transaction_id'], state['last_transaction'])
                    self.assertEqual(receipt['committed_revision'], state['state_revision'])
                    self.assertTrue(any(x['kind'] == 'decision' for x in state['records']))
                else:
                    self.assertEqual(state['records'], [])
                for reader in ('Python', 'R'):
                    run(reader, 'read')
