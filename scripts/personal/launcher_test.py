"""Exercise the actual macOS launcher with a synthetic engine, never a browser."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Native macOS launcher requires Apple headers')
class LauncherPaths(unittest.TestCase):
    def test_engine_receives_canonical_ini_and_forced_isolated_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            macos = root / 'Test App.app/Contents/MacOS'
            resources = root / 'Test App.app/Contents/Resources/browser'
            macos.mkdir(parents=True)
            resources.mkdir(parents=True)
            ini = resources / 'personal-application.ini'
            ini.write_text('[App]\nName=Synthetic\n')
            capture = root / 'arguments.json'
            engine = macos / 'zen-engine'
            engine.write_text('#!' + sys.executable + '\nimport json,sys\n'
                              'from pathlib import Path\nPath(' + repr(str(capture)) +
                              ').write_text(json.dumps(sys.argv[1:]))\n')
            engine.chmod(0o700)
            launcher = macos / 'zen-personal'
            source = Path(__file__).resolve().parents[2] / 'personal/launcher.c'
            subprocess.run(['clang', '-Wall', '-Wextra', '-Werror',
                            '-DPERSONAL_CHANNEL="Synthetic Test"', str(source),
                            '-o', str(launcher)], check=True, capture_output=True)
            env = dict(os.environ, HOME=str(root / 'Synthetic Home'))
            subprocess.run([str(launcher), 'https://example.invalid/'], env=env, check=True)
            args = json.loads(capture.read_text())
            self.assertEqual(args[0:2], ['-app', str(ini)])
            self.assertNotIn('..', Path(args[1]).parts)
            self.assertEqual(args[2:4], ['-profile', str(root / 'Synthetic Home/Library/Application Support/Zen Personal/Synthetic Test')])
            self.assertTrue(Path(args[3]).is_dir())
            self.assertEqual(args[-1], 'https://example.invalid/')
            for override in ['-profile', '--profile', '-P', '-app']:
                denied = subprocess.run([str(launcher), override, '/tmp/wrong-profile'], env=env, capture_output=True)
                self.assertEqual(denied.returncode, 2)
                self.assertEqual(json.loads(capture.read_text()), args)


if __name__ == '__main__':
    unittest.main()
