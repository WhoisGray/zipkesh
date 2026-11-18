"""Exercise source selection without installing dependencies or Finder services."""
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerSourceTests(unittest.TestCase):
    def run_selection(self, tag='v2.3.4', version='2.3.4', local=False, failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'fixture'
            (source / 'Sources').mkdir(parents=True)
            (source / 'zipkesh').mkdir()
            (source / 'Sources/Zipkesh.swift').touch()
            (source / 'zipkesh/engine.py').touch()
            (source / 'VERSION').write_text(version)
            archive = root / 'archive.tar.gz'
            with tarfile.open(archive, 'w:gz') as output:
                output.add(source, arcname='arbitrary-archive-root')
            curl = root / 'curl'
            curl.write_text('''#!/bin/bash
set -eu
if [ "$FAILURE" = 1 ]; then exit 22; fi
if [[ "$*" == *url_effective* ]]; then
    printf 'https://github.com/whoisGray/zipkesh/releases/tag/%s' "$MOCK_TAG"
else
    [[ "$*" == *"/refs/tags/$MOCK_TAG"* ]] || exit 23
    while [ "$1" != -o ]; do shift; done
    cp "$ARCHIVE" "$2"
fi
''')
            curl.chmod(0o755)
            script = (ROOT / 'install.sh').read_text()
            script = script[:script.index("# Homebrew's installer")]
            start = script.index('[ "$(uname -s)"')
            end = script.index('SOURCE=""', start)
            script = script[:start] + script[end:]
            script = script.replace('/usr/bin/curl', '"$MOCK_CURL"')
            script += '\nprintf "SELECTED=%s\\n" "$VERSION"\n'
            installer = (source if local else root) / 'install.sh'
            installer.write_text(script)
            env = dict(os.environ, MOCK_CURL=str(curl), ARCHIVE=str(archive),
                       MOCK_TAG=tag, FAILURE=str(int(failure)))
            return subprocess.run(['/bin/bash', str(installer)], env=env,
                                  capture_output=True, text=True)

    def test_downloads_latest_tag_and_reads_archive_version(self):
        result = self.run_selection()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SELECTED=2.3.4', result.stdout)

    def test_rejects_tag_version_mismatch(self):
        result = self.run_selection(version='1.0.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)

    def test_rejects_missing_release_and_invalid_tag(self):
        for options in ({'failure': True}, {'tag': 'latest'}):
            with self.subTest(options=options):
                result = self.run_selection(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('SELECTED=', result.stdout)

    def test_local_checkout_uses_its_version_without_network(self):
        result = self.run_selection(local=True, failure=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SELECTED=2.3.4', result.stdout)
