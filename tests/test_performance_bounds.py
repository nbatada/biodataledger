"""Focused bounded-read regressions for cross-project helper capture."""
import tempfile
import unittest
import copy
from pathlib import Path
from unittest.mock import patch

from biodataledger import BundleError, ProjectBundle
from biodataledger import core
from biodataledger.core import MAX_JSON


class BoundedReadTests(unittest.TestCase):
    def test_rejects_oversize_before_open(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "oversize.bin"
            with path.open("wb") as stream:
                stream.truncate(MAX_JSON + 1)
            with patch.object(Path, "open", side_effect=AssertionError("must not read oversize file")):
                with self.assertRaises(BundleError):
                    core.read_bounded(path, MAX_JSON, "oversize")

    def test_read_request_is_bounded_to_observed_size_plus_one(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "small.bin"; path.write_bytes(b"abc")
            seen = []
            original = Path.open
            def opened(value, *args, **kwargs):
                stream = original(value, *args, **kwargs); original_read = stream.read
                def read(size=-1):
                    seen.append(size); return original_read(size)
                stream.read = read
                return stream
            with patch.object(Path, "open", opened):
                self.assertEqual(core.read_bounded(path, MAX_JSON, "small"), b"abc")
            self.assertEqual(seen, [4])


class AdoptionBoundsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        a_root, b_root = root / 'a', root / 'b'
        a_root.mkdir(); b_root.mkdir()
        self.a = ProjectBundle.create('Synthetic source', a_root)
        self.b = ProjectBundle.create('Synthetic target', b_root)
        self.contract = {key: 'Synthetic check' for key in
                         ('inputs', 'parameters', 'outputs', 'example', 'limitations')}
        paths = []
        for i in range(20):
            path = a_root / f'helper-{i}.py'
            path.write_text(f'def check_{i}(x): return x\n')
            paths.append(path)
        self.ref = self.a.register_helper('columns', language='Python', purpose='columns',
                                         source=paths, function='check_0', contract=self.contract)
        self.a.save()
        self.candidate = self.b.find_helpers('columns', sources=[a_root])['helpers'][0]
        pending = b_root / 'pending.py'; pending.write_text('VALUE = 1\n')
        self.b.register_helper('pending', language='Python', purpose='pending',
                               source=pending, function='pending', contract=self.contract)

    def assert_growth_is_bounded(self, phase):
        registry = self.a.root / core.STATE_PATH
        snapshot = self.a.root / self.a.get_helper(self.ref)['code'][0]['snapshot']
        target = snapshot if phase == 'snapshot' else registry
        limit = 1024 * 1024 if phase == 'snapshot' else MAX_JSON
        selected_open = 2 if phase == 'final_registry' else 1
        before = copy.deepcopy(self.b.state), copy.deepcopy(self.b._snapshots), self.b.unsaved
        original_open = Path.open
        opens = 0
        reads = []

        def opened(path, *args, **kwargs):
            nonlocal opens
            stream = original_open(path, *args, **kwargs)
            mode = args[0] if args else kwargs.get('mode', 'r')
            if path == target and mode == 'rb':
                opens += 1
                if opens == selected_open:
                    original_read = stream.read

                    def grow_then_read(size=-1):
                        with original_open(path, 'wb') as writer:
                            writer.write(b'x' * (limit + 4096))
                        data = original_read(size)
                        reads.append((size, len(data)))
                        return data

                    stream.read = grow_then_read
            return stream

        with patch.object(Path, 'open', opened):
            with self.assertRaises(BundleError):
                self.b.register_helper_from(self.candidate)
        self.assertEqual((self.b.state, self.b._snapshots, self.b.unsaved), before)
        self.assertEqual(len(reads), 1, 'growth hook did not run')
        requested, received = reads[0]
        self.assertGreaterEqual(requested, 0, 'unbounded read requested')
        self.assertLessEqual(requested, limit + 1)
        self.assertLessEqual(received, limit + 1)

    def test_snapshot_growth_preserves_pending_and_bounds_read(self):
        self.assert_growth_is_bounded('snapshot')

    def test_initial_registry_growth_preserves_pending_and_bounds_read(self):
        self.assert_growth_is_bounded('initial_registry')

    def test_final_registry_growth_preserves_pending_and_bounds_read(self):
        self.assert_growth_is_bounded('final_registry')

    def test_twenty_files_build_one_source_facade(self):
        calls = []
        original = ProjectBundle._reindex

        def counted(project):
            if project.root == self.a.root:
                calls.append(project.root)
            original(project)

        with patch.object(ProjectBundle, '_reindex', counted):
            adopted = self.b.register_helper_from(self.candidate)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(self.b.get_helper(adopted)['code']), 20)

    def test_package_adoption_needs_no_source_facade(self):
        self.a.register_helper('package', language='Python', purpose='package',
                               package='synthetic-missing', version='1', function='check',
                               contract=self.contract)
        self.a.save()
        candidate = self.b.find_helpers('package', sources=[self.a.root])['helpers'][0]
        with patch.object(ProjectBundle, '_reindex', side_effect=AssertionError('no source facade')):
            adopted = self.b.register_helper_from(candidate)
        self.assertEqual(self.b.get_helper(adopted)['code'], [])
