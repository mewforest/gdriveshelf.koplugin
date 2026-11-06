import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile
import hashlib
import re

spec = importlib.util.spec_from_file_location('package_tool', Path(__file__).parents[1] / 'tools/package.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

class PackageTests(unittest.TestCase):
    def test_appstore_identity_and_version_are_literal_and_source_is_unchanged(self):
        source = packager.ROOT / 'gdriveshelf.koplugin/_meta.lua'
        before = source.read_bytes()
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(packager.package('0.1.42', tmp)) as handle:
                meta = handle.read('gdriveshelf.koplugin/_meta.lua').decode()
                # This is the upstream archive detector's intentionally loose pattern.
                self.assertEqual(re.search(r'name\s*=\s*[\"\']([^\"\']+)', meta).group(1), 'gdriveshelf')
                self.assertEqual(re.search(r'version\s*=\s*[\"\']([^\"\']+)', meta).group(1), '0.1.42')
                self.assertEqual(handle.read('gdriveshelf.koplugin/PACKAGE_VERSION'), b'0.1.42\n')
            self.assertEqual(source.read_bytes(), before)
            self.assertIn(b"version='0.0.0-dev'", before)

    def test_install_zip_has_only_plugin_folder_and_helper_is_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = packager.package('0.1.3', tmp)
            with zipfile.ZipFile(archive) as handle:
                self.assertTrue(all(name.startswith('gdriveshelf.koplugin/') for name in handle.namelist()))
                self.assertIn('gdriveshelf.koplugin/LICENSE', handle.namelist())
                self.assertEqual(handle.read('gdriveshelf.koplugin/PACKAGE_VERSION'), b'0.1.3\n')
                self.assertFalse(any(name.endswith('.py') or '/screenshots/' in name for name in handle.namelist()))
            helper = Path(tmp) / 'gdriveshelf-authorize.py'
            self.assertEqual(helper.read_bytes(), (packager.ROOT / 'tools/authorize.py').read_bytes())
            for asset in (archive, helper):
                digest = hashlib.sha256(asset.read_bytes()).hexdigest()
                self.assertEqual(asset.with_suffix(asset.suffix + '.sha256').read_text(), f'{digest}  {asset.name}\n')
            first = archive.read_bytes()
            self.assertEqual(packager.package('0.1.3', tmp).read_bytes(), first)
