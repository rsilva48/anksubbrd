import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


class SourceTest(unittest.TestCase):
    def test_source_matches_ipa_and_rejects_wrong_version(self):
        with tempfile.TemporaryDirectory(prefix='anksubbrd-source-test-') as folder:
            root = pathlib.Path(folder)
            ipa = root / 'AirPlaySubtitlePlayer-unsigned.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps({
                    'CFBundleShortVersionString': '0.2.5', 'CFBundleVersion': '42',
                    'CFBundleIdentifier': 'com.personal.airplaysubtitleplayer', 'MinimumOSVersion': '26.0',
                }, fmt=plistlib.FMT_BINARY))
            notes, output = root / 'notes.md', root / 'source.json'
            notes.write_text('Cambios: búsqueda y subtítulos', encoding='utf-8')
            script = pathlib.Path(__file__).with_name('generate-source.py')
            command = [sys.executable, str(script), '--ipa', str(ipa), '--notes', str(notes), '--output', str(output),
                       '--repository', 'rsilva48/anksubbrd', '--tag', 'v0.2.5', '--commit', 'a' * 40]
            subprocess.run(command, check=True, capture_output=True)
            app = json.loads(output.read_text(encoding='utf-8'))['apps'][0]
            version = app['versions'][0]
            self.assertEqual(app['bundleIdentifier'], 'com.personal.airplaysubtitleplayer')
            self.assertEqual((version['version'], version['buildVersion'], version['minOSVersion']), ('0.2.5', '42', '26.0'))
            self.assertEqual(version['size'], ipa.stat().st_size)
            self.assertEqual(version['sha256'], hashlib.sha256(ipa.read_bytes()).hexdigest())
            self.assertIn('/v0.2.5/', version['downloadURL'])
            self.assertIn('búsqueda', version['localizedDescription'])
            command[command.index('v0.2.5')] = 'v0.2.6'
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
