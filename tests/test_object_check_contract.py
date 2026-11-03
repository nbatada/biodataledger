"""Report/registry interchange only; Python does not implement object checking."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from biodataledger import ProjectBundle


class ObjectCheckContractTests(unittest.TestCase):
    def test_native_report_and_requirements_survive_python_save(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, text in {
                'membership.csv': 'sample_id,cell_id\nS1,AA\nS2,AA\n',
                'samples.csv': 'sample_id,treatment,donor\nS1,Vehicle,D1\nS2,Drug,D2\n',
                'clusters.csv': 'sample_id,cell_id,cluster\nS1,AA,0\nS2,AA,1\n',
                'dataset.txt': 'opaque synthetic bytes\n',
            }.items():
                (root / name).write_text(text)
            p = ProjectBundle.create('Synthetic report interchange', root)
            member = p.register_data('membership.csv', 'authority', hash=True)
            samples = p.register_data('samples.csv', 'authority', hash=True)
            clusters = p.register_data('clusters.csv', 'authority', hash=True)
            configuration = {'version': 'biodataledger-object-requirements/1',
                             'membership_policy': 'exact', 'cluster_ref': clusters}
            data = p.register_data('dataset.txt', 'input', hash=True,
                                   membership=member, object_check=configuration)
            design = p.set_design('treatment', ['Vehicle', 'Drug'], replicate='donor')
            data = p.set_data_scope(data, {'condition_values': ['Vehicle', 'Drug'],
                                          'assay': 'RNA', 'layer': 'counts',
                                          'sample_manifest_ref': samples}, 'synthetic', design)
            p.set_current(data, 'object_check', 'synthetic selection')
            p.save()
            script = Path(__file__).with_name('r_object_check_exchange.R')
            for _ in range(2):
                result = subprocess.run(['Rscript', '--vanilla', str(script), str(root)],
                                        capture_output=True, text=True, env=os.environ, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report['report_version'], 'biodataledger-object-check/1')
                self.assertEqual(report['requirement_ref'], data)
                self.assertEqual(report['references']['clusters'], clusters)
                self.assertEqual(report['overall'], 'PASS')
                self.assertEqual(report['blockers'], [])
                self.assertTrue(report['unverified'])
                self.assertTrue(all(field['status'] == 'PASS' for field in report['fields'].values()))
                p = ProjectBundle.open(root)
                self.assertEqual(p.get_data(ref=data).details['object_check'], configuration)
                p.set_context({'next_task': 'Python preserved requirements'})
                p.save()
