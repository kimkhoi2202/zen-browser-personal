"""Check that the public asset audit rejects private data and escaping links."""
from pathlib import Path
import tempfile
import unittest
from release_macos import audit_app


class PublicPayload(unittest.TestCase):
    def test_profile_database_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/Resources/cookies.sqlite').touch()
            with self.assertRaisesRegex(RuntimeError, 'Private-data'):
                audit_app(app)

    def test_external_keychain_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            app.mkdir()
            (app / 'Unrelated Data').symlink_to(Path(directory).parent)
            with self.assertRaisesRegex(RuntimeError, 'escapes bundle'):
                audit_app(app)

    def test_framework_internal_symlink_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Example.app'
            (app / 'Framework/Versions/A').mkdir(parents=True)
            (app / 'Framework/Versions/Current').symlink_to('A')
            audit_app(app)
