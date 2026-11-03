"""Synthetic figure rendering context and bounded preserved-source access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from biodataledger import ProjectBundle, BundleError
from biodataledger.core import STATE_PATH, canonical


class FigureSourcesTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        for name,value in [('analysis.csv','analytical'),('render.csv','rendering'),('plot.R','# synthetic generating source\n'),('helper.R','# relative helper\n'),('figure.svg','<svg/>')]:
            (self.root/name).write_text(value)
        self.p=ProjectBundle.create('Synthetic source fixture',self.root)
        for i in range(49): self.analytical=self.p.register_data('analysis.csv','input')
        for i in range(8): self.rendering=self.p.register_data('render.csv','result',hash=True)
        self.helper=self.p.register_data('helper.R','support',hash=True)
        for i in range(14): self.analysis=self.p.register_analysis('Synthetic comparison',[self.analytical],code='plot.R',method='fixture',params={'threshold':0.25})
        for i in range(75): self.figure=self.p.register_figure('figure.svg','synthetic',analysis=self.analysis)
        self.p.save()
        self.sources={'rendering_inputs':[self.rendering],'relationship':'unknown',
                      'generating_code':{'record':self.analysis,'index':0},
                      'dependencies':[{'path':'helpers/helper.R','ref':self.helper}], 'asset_id':'study:panel-A'}

    def marked(self):
        return self.p.update_record(self.figure,{'figure_sources':self.sources},'explicit rendering declarations')

    def test_separate_exact_inputs_and_aliases(self):
        f=self.marked();self.p.save()
        v=self.p.get_figure(f)
        self.assertEqual(self.analytical['id'],'DATA-049');self.assertEqual(self.rendering['id'],'DATA-057')
        self.assertEqual(self.analysis['id'],'ANA-014');self.assertEqual(f['id'],'FIG-075')
        self.assertEqual(v.inputs,[self.analytical]);self.assertEqual(v.rendering_inputs,[self.rendering])
        self.assertEqual(v.params,{'threshold':0.25});self.assertEqual(v.evidence['execution'],'unknown')
        self.assertEqual(v.rendering_relationship,'unknown')
        unset=self.p.register_figure('figure.svg','synthetic',figure_sources=None)
        self.assertIsNone(self.p.get_figure(unset).rendering_inputs)
        self.assertIn('rendering_relationship',self.p.get_figure(f,compact=True)['missing'])
        self.assertEqual(self.p.get_figure(asset_id='study:panel-A').ref,f)
        self.assertEqual(self.p.get_figure('FIG-075',revision=2).ref,f)
        with self.assertRaises(BundleError):self.p.get_figure('FIG-075')
        with self.assertRaises(BundleError):self.p.get_figure(path='figure.svg')
        self.assertIsNone(self.p.get_figure(self.figure).rendering_inputs)
        self.assertEqual(self.p.get_figure(f).figure_sources['rendering_details'][0]['parent'],None)
        self.p.set_context({'next_task':'later default'});self.p.save()
        self.assertEqual(self.p.get_figure(f).analysis,self.analysis)

    def test_source_reads_staged_preserved_and_no_fallback(self):
        f=self.marked();original=(self.root/'plot.R').read_bytes()
        self.assertEqual(self.p.read_figure_source(f)['content'],original)
        (self.root/'plot.R').write_text('# changed original\n')
        self.assertEqual(self.p.read_figure_source(f)['content'],original)
        self.p.save();view=self.p.get_figure(f)
        snapshot=self.root/view.generating_code['snapshot']
        snapshot.unlink()
        with self.assertRaisesRegex(BundleError,'SOURCE_MISSING'):self.p.read_figure_source(f)
        self.assertEqual((self.root/'plot.R').read_text(),'# changed original\n')
        snapshot.write_bytes(b'x'*(1024*1024+1))
        with self.assertRaisesRegex(BundleError,'SOURCE_OVERSIZED'):self.p.read_figure_source(f)

    def test_invalid_mutations_atomic_and_legacy_details_safe(self):
        before=canonical(self.p.state)
        cases=[dict(self.sources,rendering_inputs=[self.analysis]),
               dict(self.sources,generating_code={'record':self.analysis,'index':0,'sha256':'0'*64}),
               dict(self.sources,dependencies=[{'path':'../escape.R','ref':self.helper}]),
               dict(self.sources,dependencies=[{'path':'C:/escape','ref':self.helper}]),
               dict(self.sources,dependencies=[{'path':'x','ref':self.helper},{'path':'x/y','ref':self.helper}])]
        for value in cases:
            with self.assertRaises(BundleError):self.p.update_record(self.figure,{'figure_sources':value},'invalid')
            self.assertEqual(canonical(self.p.state),before)
        details=self.p.get_figure(self.figure).details
        details['biodataledger.figure_sources']={'version':'biodataledger-figure-sources/1','bad':True}
        with self.assertRaises(BundleError):self.p.update_record(self.figure,{'details':details},'cannot bypass')
        details['biodataledger.figure_sources']={'unrelated':'legacy freeform'}
        legacy=self.p.update_record(self.figure,{'details':details},'legacy metadata');self.p.save()
        raw=(self.root/STATE_PATH).read_bytes();q=ProjectBundle.open(self.root)
        self.assertIsNone(q.get_figure(legacy).rendering_inputs)
        self.assertEqual((self.root/STATE_PATH).read_bytes(),raw);self.assertFalse(q.unsaved)

    def test_compact_metadata_queries_and_explicit_availability(self):
        f=self.marked();self.p.save()
        with patch('biodataledger.core.fingerprint',side_effect=AssertionError('hash')),patch.object(Path,'open',side_effect=AssertionError('read')),patch('os.scandir',side_effect=AssertionError('scan')):
            report=self.p.get_figure(f,compact=True)
        self.assertLessEqual(len(canonical(report)),4096)
        self.assertEqual(report['analytical_inputs'],[self.analytical]);self.assertEqual(report['rendering_inputs'],[self.rendering])
        self.assertEqual(report['execution'],'unknown');self.assertIn('execution_evidence',report['missing'])
        self.assertEqual(report['code_candidates'],[])
        (self.root/'render.csv').unlink();(self.root/'helper.R').unlink()
        v=self.p.get_figure(f,check_files=True)
        self.assertFalse(v.figure_sources['rendering_details'][0]['available'])
        self.assertFalse(v.dependencies[0]['available'])
        self.assertEqual(v.figure_sources['dependency_completeness'],'unknown')

    def test_legacy_candidates_explicit_selection_and_read_bound(self):
        original=(self.root/'plot.R').read_bytes()
        legacy=self.p.get_figure(self.figure)
        self.assertEqual(len(legacy.figure_sources['code_candidates']),1)
        self.assertEqual(self.p.read_figure_source(self.figure)['content'],original)
        (self.root/'plot.R').write_text('# modified original')
        self.assertEqual(self.p.read_figure_source(self.figure)['content'],original)
        (self.root/'second.R').write_text('# second source')
        owner=self.p.register_analysis('two scripts',[self.analytical],code=['plot.R','second.R'])
        f=self.p.register_figure('figure.svg','synthetic',analysis=owner)
        with self.assertRaisesRegex(BundleError,'SOURCE_UNKNOWN'):self.p.read_figure_source(f)
        selector={'record':owner,'index':1}
        self.assertEqual(self.p.read_figure_source(f,code_ref=selector)['content'],b'# second source')
        source=self.p.get_figure(self.figure).figure_sources['code_candidates'][0]
        with patch('biodataledger.core.fingerprint',side_effect=AssertionError('unbounded hash pass')):
            self.assertEqual(self.p.read_figure_source(self.figure)['content'],original)
        f=self.marked();self.p.save()
        (self.root/'render.csv').unlink()
        report=self.p.get_figure(f,compact=True,check_files=True)
        self.assertIn('rendering_file',report['missing'])
        self.assertFalse(report['rendering_details'][0]['available'])
        self.assertEqual(report['generating_code']['integrity'],'not_checked')

    def test_registered_code_and_recorded_lineage_only(self):
        code=self.p.register_data('plot.R','code',hash=True)
        details=self.p.get_data(ref=self.rendering).details;details['parent']=self.analytical
        child=self.p.update_record(self.rendering,{'details':details},'recorded parent')
        sources=dict(self.sources,rendering_inputs=[child],generating_code={'record':self.analysis,'index':0,'registered_ref':code})
        f=self.p.register_figure('figure.svg','synthetic',analysis=self.analysis,figure_sources=sources)
        report=self.p.get_figure(f,compact=True)
        self.assertEqual(report['rendering_details'][0]['parent'],self.analytical)
        self.assertEqual(report['rendering_relationship'],'unknown')
        self.assertIn('rendering_relationship',report['missing'])
        declared=self.p.update_record(f,{'figure_sources':dict(sources,relationship='declared')},'explicit relationship declaration')
        self.assertEqual(self.p.get_figure(declared).rendering_relationship,'declared')
        self.assertEqual(report['generating_code']['selector']['registered_ref'],code)
        before=canonical(self.p.state)
        sources['generating_code']['registered_ref']=self.rendering
        with self.assertRaises(BundleError):self.p.register_figure('figure.svg','synthetic',analysis=self.analysis,figure_sources=sources)
        self.assertEqual(canonical(self.p.state),before)

    def test_compact_omissions_and_readonly_alias_ambiguity(self):
        long_params={'x'*100:'value','small':'雪'*500,'array':list(range(100))}
        owner=self.p.register_analysis('large params',[self.analytical],code='plot.R',params=long_params)
        f=self.p.register_figure('figure.svg','synthetic',analysis=owner,figure_sources=self.sources)
        self.p.save();before=(self.root/STATE_PATH).read_bytes()
        report=self.p.get_figure(f,compact=True)
        self.assertLessEqual(len(canonical(report)),4096)
        self.assertIn('params',report['truncated']['fields'])
        with self.assertRaises(BundleError):self.p.get_figure(asset_id='study:panel-A',path='figure.svg')
        self.assertEqual((self.root/STATE_PATH).read_bytes(),before);self.assertFalse(self.p.unsaved)

    def test_imported_snapshot_and_missing_figure_reporting(self):
        f=self.marked();self.p.save()
        archive=self.root/'working.zip'
        self.p.export_zip(self.p.preview_export('working',include=[f]),archive)
        q=ProjectBundle.import_zip(archive,self.root/'imported')
        self.assertEqual(q.read_figure_source(f)['content'],(self.root/'plot.R').read_bytes())
        self.assertEqual(q.read_figure_source(f)['integrity'],'match')
        (self.root/'figure.svg').unlink()
        report=self.p.get_figure(f,compact=True,check_files=True)
        self.assertFalse(report['available']);self.assertEqual(report['integrity'],'not_checked')
        self.assertIn('figure_file',report['missing'])

    def test_native_roundtrip_and_legacy_client_readability(self):
        f=self.marked();self.p.save();key=f['id']+'@'+str(f['revision'])
        script=Path(__file__).with_name('r_sources_exchange.R')
        r=subprocess.run(['Rscript','--vanilla',str(script),os.environ['BDL_R_LIB'],str(self.root),key],capture_output=True,text=True,timeout=30)
        self.assertEqual(r.returncode,0,r.stderr)
        observed=json.loads(r.stdout);self.assertEqual(observed['report'],self.p.get_figure(f,compact=True))
        q=ProjectBundle.open(self.root);self.assertEqual(q.read_figure_source(observed['revised'])['content'],(self.root/'plot.R').read_bytes())


if __name__=='__main__':unittest.main()
