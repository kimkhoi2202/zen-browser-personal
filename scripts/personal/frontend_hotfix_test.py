"""Verify that a frontend hotfix cannot silently change other archive payloads."""
from pathlib import Path
import tempfile
import unittest
import zipfile

from frontend_hotfix import MODULE, replace_module


class FrontendHotfix(unittest.TestCase):
    def test_replaces_only_the_expected_module(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'omni.ja'
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr(MODULE, b'original')
                z.writestr('modules/other.mjs', b'preserved')
            self.assertEqual(replace_module(archive, b'original', b'fixed'), [MODULE])
            with zipfile.ZipFile(archive) as z:
                self.assertEqual(z.read(MODULE), b'fixed')
                self.assertEqual(z.read('modules/other.mjs'), b'preserved')

    def test_rejects_an_unexpected_source_without_modifying_the_archive(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'omni.ja'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr(MODULE, b'another version')
            before = archive.read_bytes()
            with self.assertRaisesRegex(RuntimeError, 'differs from its recorded source'):
                replace_module(archive, b'original', b'fixed')
            self.assertEqual(archive.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
