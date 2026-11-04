"""Fresh installed-client parity for result descriptors, checks and lineage."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from biodataledger import ProjectBundle


class ResultInteropTests(unittest.TestCase):
    maxDiff = None
    def run_r(self, action, root, ref='DATA-003@1', depth=3, limit=20):
        script = Path(__file__).with_name('r_results_exchange.R')
        out = subprocess.run(['Rscript', '--vanilla', str(script), action, str(root), ref, str(depth), str(limit)],
                             capture_output=True, text=True, env=os.environ, timeout=30)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        return json.loads(out.stdout)

    def fixture(self, root):
        (root / 'input.h5ad').write_text('opaque synthetic bytes')
        (root / 'umap.csv').write_text('sample_id,cell_id,UMAP_1,UMAP_2\nS1,001,1,2\nS2,001,3,4\n')
        (root / 'members.csv').write_text('sample_id,cell_id\nS1,001\nS2,001\n')
        (root / 'plot.svg').write_text('<svg/>')
        p = ProjectBundle.create('Synthetic PRMT5 result exchange', root)
        d = p.register_data('input.h5ad', 'input', hash=True)
        m = p.register_data('members.csv', 'observations', hash=True)
        a = p.register_analysis('UMAP declaration', [d], params={'seed': 1})
        p.save_and_confirm()
        return p, d, m, a

    def assert_parity(self, p, result, depth=3, limit=20):
        out = self.run_r('inspect', p.root, result['id'] + '@' + str(result['revision']), depth, limit)
        self.assertEqual(out['check'], p.check_result(result))
        self.assertEqual(out['view'], p.get_data(ref=result).result)
        self.assertEqual(out['descriptor'], p.get_data(ref=result).details['biodataledger.result'])
        self.assertEqual(out['upstream'], p.dependencies(result, 'upstream', depth=depth, limit=limit))
        self.assertEqual(out['downstream'], p.dependencies('DATA-001@1', 'downstream', depth=depth, limit=limit))

    def test_native_result_roundtrip_and_same_negative_evidence(self):
        for writer in ('Python', 'R'):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                p, d, m, a = self.fixture(root)
                if writer == 'R':
                    result = self.run_r('register', root)['result']
                    p = ProjectBundle.open(root)
                else:
                    result = p.register_result('umap.csv', a, hash=True,
                              embedding={'format':'csv','coordinate_columns':['UMAP_1','UMAP_2'],'membership_ref':m})
                    p.register_figure('plot.svg','umap',analysis=a,
                                      figure_sources={'rendering_inputs':[result],'relationship':'declared'})
                    p.save_and_confirm()
                self.assert_parity(p, result)
                (root / 'umap.csv').write_text('changed bytes')
                self.assert_parity(p, result)

    def test_native_metadata_selectors_and_saved_copy_exchange(self):
        with tempfile.TemporaryDirectory() as tmp:
            p, d, m, a = self.fixture(Path(tmp).resolve())
            results = [p.register_result(d,a,embedding={'format':fmt,'selector':selector,'membership_ref':m})
                       for fmt,selector in [('seurat','umap'),('anndata','X_umap')]]
            results.append(p.register_result('umap.csv',a,copy=True,
                            embedding={'format':'csv','coordinate_columns':['UMAP_1','UMAP_2'],'membership_ref':m}))
            p.save_and_confirm()
            for result in results: self.assert_parity(p,result)
            archive = Path(tmp) / 'selected.zip'
            p.export_zip(p.preview_export('working', include=results+[m]),archive)
            q = ProjectBundle.import_zip(archive,Path(tmp)/'imported')
            for result in results: self.assert_parity(q,result)

    def test_csv_negative_and_missing_evidence_parity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            p, d, m, a = self.fixture(root)
            valid = (root/'umap.csv').read_text()
            scenarios = [
                ('missing_column', valid.replace('UMAP_2','other'), m, True),
                ('duplicate_keys', valid.replace('S2,001','S1,001'), m, True),
                ('empty_key', valid.replace('S2,001','S2,'), m, True),
                ('nan', valid.replace('S1,001,1,2','S1,001,NaN,2'), m, True),
                ('ragged', valid.replace('S1,001,1,2','S1,001,1'), m, True),
                ('blank_row', valid.replace('S2,001','\nS2,001'), m, True),
                ('no_authority',valid,None,True),
                ('no_hash',valid,m,False),
                ('header_only',valid.splitlines()[0]+'\n',m,True),
                ('wrong_cells',valid.replace('S2,001','S2,999'),m,True),
                ('quoted_key',valid.replace('S2,001','S2,"a,b"'),None,True),
                ('newline_key',valid.replace('S2,001','S2,"a\nb"'),None,True),
            ]
            results=[]
            for name,content,member,hashed in scenarios:
                (root/(name+'.csv')).write_text(content)
                results.append(p.register_result(name+'.csv',a,hash=hashed,
                    embedding={'format':'csv','coordinate_columns':['UMAP_1','UMAP_2'],'membership_ref':member}))
            generic=p.register_result('umap.csv',None)
            p.save_and_confirm()
            for result in results+[generic]:
                with self.subTest(result=result):self.assert_parity(p,result)
            # Invalid bytes still identify a registered file; CSV validation fails separately.
            (root/'bad.csv').write_bytes(b'sample_id,cell_id,UMAP_1,UMAP_2\nS1,\xff,1,2\n')
            bad=p.register_result('bad.csv',a,hash=True,embedding={'format':'csv','coordinate_columns':['UMAP_1','UMAP_2']})
            p.save_and_confirm();self.assert_parity(p,bad)
            with (root/'oversized.csv').open('wb') as stream:stream.truncate(20*1024*1024+1)
            oversized=p.register_result('oversized.csv',a,
                embedding={'format':'csv','coordinate_columns':['UMAP_1','UMAP_2']})
            p.save_and_confirm();self.assert_parity(p,oversized)
            self.assertEqual(p.check_result(oversized)['fields']['file_integrity']['reason'],'size_limit')


    def test_bounded_queries_and_keyed_native_reference_parity(self):
        with tempfile.TemporaryDirectory() as tmp:
            p,d,m,a=self.fixture(Path(tmp).resolve())
            result=p.register_result(d,a,embedding={'format':'anndata','selector':'X_umap',
                'membership_ref':m,'alignment':'keyed','row_key_column':'obs_name'})
            for _ in range(5):
                p.register_figure('plot.svg','umap',analysis=a,
                    figure_sources={'rendering_inputs':[result],'relationship':'unknown'})
            p.save_and_confirm()
            for depth in (1,2,3):
                for limit in (1,2,20):
                    with self.subTest(depth=depth,limit=limit):self.assert_parity(p,result,depth,limit)

    def test_high_fanout_depth_limit_does_not_scan_adjacency(self):
        with tempfile.TemporaryDirectory() as tmp:
            p,d,m,a=self.fixture(Path(tmp).resolve())
            for _ in range(100):p.register_result('umap.csv',a)
            p.save_and_confirm()
            self.run_r('bounded',p.root)

    def test_metadata_correction_uses_semantic_result_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            p,d,m,a=self.fixture(Path(tmp).resolve())
            original=p.register_result('umap.csv',a,hash=True,
                embedding={'format':'csv','coordinate_columns':['UMAP_1','UMAP_2'],'membership_ref':m})
            p.save_and_confirm()
            revised=self.run_r('metadata_correction',p.root,original['id']+'@1')
            q=ProjectBundle.open(p.root)
            self.assertEqual(q.get_data(ref=revised).details['biodataledger.result'],p.get_data(ref=original).details['biodataledger.result'])
            self.assertEqual(q.check_result(revised)['overall'],'PASS')
            self.assertEqual(q.check_result(original)['overall'],'PASS')
