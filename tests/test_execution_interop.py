"""Execution receipts survive native saves/imports without gaining authority."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from biodataledger import ProjectBundle


class ExecutionInteropTests(unittest.TestCase):
    def native(self, script, *args):
        result = subprocess.run(
            ['Rscript', '--vanilla', '-', os.environ['BDL_R_LIB'], *map(str, args)],
            input=script, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_python_receipt_native_save_and_working_import(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'project'; root.mkdir()
            (root / 'input.txt').write_text('synthetic input\n')
            (root / 'code.py').write_text(
                'def run(inputs, params, seeds, outputs):\n'
                '    with open(outputs[0], "w") as handle:\n'
                '        handle.write("value\\n1\\n")\n')
            p = ProjectBundle.create('Synthetic cross-language execution', root)
            d = p.register_data('input.txt', 'input', hash=True)
            a = p.register_analysis('Declared template', [d], code='code.py',
                                    method='synthetic', params={'label': 'α', 'n': 1})
            receipt = p.run_analysis(a, 'run',
                                     outputs=[{'path': 'result.csv', 'kind': 'result'}],
                                     seeds={'random': 42})
            ref = receipt['receipt_ref']; before = p.get_execution(ref)
            native = self.native(r'''
args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc=args[[1]])
p <- ProjectBundle$open(args[[2]])
ref <- jsonlite::fromJSON(args[[3]],simplifyVector=FALSE)
view <- p$get_execution(ref)
p$set_context(list(next_task='Native metadata save'))
invisible(p$save_and_confirm())
archive <- args[[4]]
plan <- p$preview_export('working')
p$export_zip(plan,archive)
q <- ProjectBundle$import_zip(archive,args[[5]])
cat(jsonlite::toJSON(list(view=view,imported=q$get_execution(ref)),auto_unbox=TRUE,null='null',digits=NA))
''', root, json.dumps(ref), Path(tmp) / 'working.zip', Path(tmp) / 'imported')
            self.assertEqual(native['view'], before)
            self.assertEqual(native['imported'].pop('authenticity'), 'untrusted_imported_claim')
            self.assertEqual(native['imported'], before)
            reopened = ProjectBundle.open(root)
            self.assertEqual(reopened.get_execution(ref), before)
            self.assertEqual(before['input_consumption'], 'unknown')
            self.assertEqual(before['scientific_validity'], 'unknown')
            self.assertEqual(reopened.get_analysis(a).evidence['execution'], 'unknown')
            output = before['outputs'][0]
            self.assertEqual(output['digest'], hashlib.sha256((root / 'result.csv').read_bytes()).hexdigest())
            self.assertEqual(reopened.get_data(ref=output['record_ref']).scope['transformation_ref'], before['run_ref'])

    def test_r_hard_exit_leaves_readable_started_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "exit.R").write_text(
                'die <- function(inputs, params, seeds, outputs) quit(save="no", status=23, runLast=FALSE)\n')
            p = ProjectBundle.create("Synthetic interrupted R run", root)
            a = p.register_analysis("Hard exit", [], code="exit.R")
            p.save_and_confirm()
            result = subprocess.run(
                ['Rscript', '--vanilla', '-', os.environ['BDL_R_LIB'], str(root), json.dumps(a)],
                input="args <- commandArgs(TRUE)\nlibrary(BioDataLedger,lib.loc=args[[1]])\np <- ProjectBundle$open(args[[2]])\np$run_analysis(jsonlite::fromJSON(args[[3]],simplifyVector=FALSE),'die')\n", text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
            started = ProjectBundle.open(root).get_execution("ANA-002@1")
            self.assertEqual(started["status"], "started")
            self.assertFalse(any(started["phases"].values()))
            self.assertIsNone(started["ended_at_utc"])

    def test_r_receipt_python_save_and_working_import(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'project'; root.mkdir()
            (root / 'input.txt').write_text('synthetic input\n')
            (root / 'code.R').write_text(
                'run <- function(inputs, params, seeds, outputs) {\n'
                '  writeLines(c("value", "1"), outputs[[1]])\n'
                '  writeLines("<svg/>", outputs[[2]])\n}\n')
            native = self.native(r'''
args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc=args[[1]])
p <- ProjectBundle$create('Synthetic native execution',args[[2]])
d <- p$register_data('input.txt','input',hash=TRUE)
a <- p$register_analysis('Template',list(d),code='code.R',method='synthetic',params=list(label='α',n=1))
run <- p$run_analysis(a,'run',outputs=list(list(path='result.csv',kind='result'),list(path='figure.svg',kind='figure',type='synthetic')),seeds=list(random=42))
cat(jsonlite::toJSON(list(ref=run$receipt_ref,view=p$get_execution(run$receipt_ref)),auto_unbox=TRUE,null='null',digits=NA))
''', root)
            p = ProjectBundle.open(root)
            self.assertEqual(p.get_execution(native['ref']), native['view'])
            p.set_context({'next_task': 'Python metadata save'})
            p.save_and_confirm()
            archive = Path(tmp) / 'working.zip'
            p.export_zip(p.preview_export('working'), archive)
            imported = ProjectBundle.import_zip(archive, Path(tmp) / 'imported')
            imported_view = imported.get_execution(native['ref'])
            self.assertEqual(imported_view.pop('authenticity'), 'untrusted_imported_claim')
            self.assertEqual(imported_view, native['view'])
            reread = self.native(r'''
args <- commandArgs(TRUE)
library(BioDataLedger,lib.loc=args[[1]])
p <- ProjectBundle$open(args[[2]])
cat(jsonlite::toJSON(p$get_execution(jsonlite::fromJSON(args[[3]],simplifyVector=FALSE)),auto_unbox=TRUE,null='null',digits=NA))
''', root, json.dumps(native['ref']))
            self.assertEqual(reread, native['view'])
            self.assertEqual(reread['status'], 'succeeded')
            self.assertEqual(reread['input_consumption'], 'unknown')
            figure = reread['outputs'][1]['record_ref']
            self.assertEqual(p.get_figure(figure).analysis, reread['run_ref'])
            self.assertEqual(p.get_figure(figure).evidence['execution'], 'unknown')


if __name__ == '__main__':
    unittest.main()
