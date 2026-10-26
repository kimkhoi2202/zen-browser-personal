"""Safety checks with synthetic data only; never reads a real browser profile."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import clone_profile as migration
import jsonlz4


class ProfileMigrationSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'Original Profile'
        self.source.mkdir()
        self.destination = self.root / 'Production'
        self.backup = self.root / 'Backup'
        self.old_umask = os.umask(0o077)
        (self.source / 'prefs.js').write_text('user_pref("test.path", ' + json.dumps(str(self.source)) + ');\n')
        (self.source / 'extensions.json').write_text(json.dumps({'addons': [{
            'id': 'synthetic@example.invalid', 'type': 'extension', 'active': True,
            'location': 'app-profile', 'path': str(self.source / 'extensions/example.xpi')
        }]}))
        (self.source / 'addonStartup.json.lz4').write_bytes(jsonlz4.dumps({'path': str(self.source)}))
        (self.source / 'key4.db').write_bytes(b'synthetic-encrypted-key-material')
        with contextlib.closing(sqlite3.connect(self.source / 'cookies.sqlite')) as db:
            db.execute('CREATE TABLE moz_cookies(value TEXT)')
            db.execute("INSERT INTO moz_cookies VALUES ('synthetic-session')")
            db.commit()
        self.before = migration.fingerprint(self.source)

    def tearDown(self):
        os.umask(self.old_umask)
        self.temp.cleanup()

    def clone(self, **kwargs):
        with patch.object(migration.subprocess, 'check_output', return_value=''), \
             patch.object(migration.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
            run.return_value.stdout = b''
            return migration.clone_profile(self.source, self.destination, self.backup, **kwargs)

    def test_copies_sessions_without_modifying_source_or_encrypted_material(self):
        report = self.clone()
        self.assertEqual(migration.fingerprint(self.source), self.before)
        self.assertEqual(migration.fingerprint(self.backup / 'Original Profile'), self.before)
        self.assertEqual((self.destination / 'key4.db').read_bytes(), b'synthetic-encrypted-key-material')
        self.assertEqual(report['inventory']['cookies'], 1)
        self.assertEqual(report['inventory']['active_installed_extensions'], 1)
        self.assertEqual(jsonlz4.loads((self.destination / 'addonStartup.json.lz4').read_bytes())['path'], str(self.destination.resolve()))
        self.assertFalse((self.source / 'cookies.sqlite-shm').exists())
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o700)

    def test_uncheckpointed_database_fails_before_creating_copies(self):
        (self.source / 'cookies.sqlite-wal').write_bytes(b'pending-writes')
        with self.assertRaisesRegex(RuntimeError, 'uncheckpointed WAL'):
            self.clone()
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.backup.exists())

    def test_resume_requires_byte_identical_snapshot(self):
        self.backup.mkdir()
        shutil.copytree(self.source, self.backup / 'Original Profile')
        (self.backup / 'Original Profile/key4.db').write_bytes(b'wrong-backup')
        with self.assertRaisesRegex(AssertionError, 'Backup does not match'):
            self.clone(resume_verified_backup=True)
        self.assertFalse(self.destination.exists())
        self.assertEqual(migration.fingerprint(self.source), self.before)

    def test_refuses_overwriting_existing_destination(self):
        self.destination.mkdir()
        marker = self.destination / 'preserve.txt'
        marker.write_text('existing browser data')
        with self.assertRaisesRegex(RuntimeError, 'never overwrite'):
            self.clone()
        self.assertEqual(marker.read_text(), 'existing browser data')


if __name__ == '__main__':
    unittest.main()
