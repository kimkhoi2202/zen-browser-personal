"""A source-built engine may only be packaged while its compiled sources match."""
import unittest
from build_macos import engine_affecting


class SourceBuiltEngine(unittest.TestCase):
    def test_packaging_inputs_and_docs_need_no_engine_rebuild(self):
        self.assertEqual(engine_affecting([
            'personal/channels.json', 'personal/launcher.c', 'scripts/personal/build_macos.py',
            'src/zen/urlbar/PersonalCommandActions.mjs', 'src/zen/urlbar/ZenUrlbarController.mjs',
            'src/zen/spaces/ZenSpaceManager.mjs',
            'locales/en-US/browser/browser/zen-command-palette.ftl', 'README.md', 'docs/index.md',
            'Generation Scripts/README.md', 'personal/Yab-style PiP.md']), [])

    def test_compiled_sources_need_an_engine_rebuild(self):
        compiled = ['src/zen/pip/ZenPipNativeChrome.mm', 'prefs/zen/view.yaml', 'src/zen/urlbar/moz.build',
                    'locales/en-US/browser/browser/zen-general.ftl', 'surfer.json', 'src/zen/pip/README.md']
        self.assertEqual(engine_affecting(compiled), compiled)


class MachOFiles(unittest.TestCase):
    def test_only_mach_o_files_are_signed_separately(self):
        import tempfile
        from pathlib import Path
        from build_macos import is_macho
        with tempfile.TemporaryDirectory() as directory:
            library, text = Path(directory) / 'libclearkey.dylib', Path(directory) / 'manifest.json'
            library.write_bytes(bytes.fromhex('cffaedfe') + bytes(28))
            text.write_text('{}')
            self.assertTrue(is_macho(library))
            self.assertFalse(is_macho(text))


if __name__ == '__main__':
    unittest.main()
