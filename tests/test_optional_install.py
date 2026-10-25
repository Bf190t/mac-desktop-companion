"""Offline safety checks for the optional installer; no downloads or model loads."""
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('optional_installer', ROOT/'chat/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class OptionalInstallTests(unittest.TestCase):
    def test_manifest_rejects_paths_and_invalid_hash(self):
        good = {'name':'model.safetensors','bytes':1,'sha256':'a'*64}
        self.assertTrue(installer.valid_entry(good))
        for name in ['', '.', '..', '../escape', '/absolute', 'folder/file', 'folder\\file']:
            self.assertFalse(installer.valid_entry({**good,'name':name}), name)
        self.assertFalse(installer.valid_entry({**good,'sha256':'z'*64}))
        self.assertFalse(installer.valid_entry({**good,'bytes':0}))

    def test_low_disk_stops_before_download(self):
        with tempfile.TemporaryDirectory() as folder:
            with mock.patch.object(installer.shutil, 'disk_usage', return_value=type('Usage',(),{'free':1})()):
                with mock.patch.object(installer, 'run') as run:
                    with self.assertRaisesRegex(RuntimeError,'3 GiB'):
                        installer.install(Path(folder), ROOT/'chat')
                    run.assert_not_called()

    def test_hash_mismatch_never_creates_completion_marker(self):
        with tempfile.TemporaryDirectory() as folder:
            base=Path(folder);resources=base/'resources';resources.mkdir();stage=base/'stage';stage.mkdir()
            manifest={'repo':'mlx-community/Qwen3-1.7B-4bit','revision':'3b1b1768f8f8cf8351c712464f906e86c2b8269e',
                      'files':[{'name':'model.safetensors','bytes':4,'sha256':'0'*64}]}
            (resources/'model-manifest.json').write_text(json.dumps(manifest))
            def fake_run(command):
                if command[0]=='/usr/bin/curl':Path(command[-1]).write_bytes(b'bad!')
            with mock.patch.object(installer,'run',side_effect=fake_run):
                with self.assertRaisesRegex(RuntimeError,'checksum mismatch'):
                    installer.install(stage, resources)
            self.assertFalse((stage/'installation.json').exists())

    def test_runtime_pin_matches_bootstrap(self):
        manifest=json.loads((ROOT/'chat/runtime-manifest.json').read_text())
        script=(ROOT/'chat/install.sh').read_text()
        self.assertIn(manifest['sha256'],script)
        self.assertIn(manifest['url'],script)
        self.assertIn('--proto-redir',script)
        self.assertIn('os.rename',script)
        self.assertIn('--require-hashes',(ROOT/'chat/install.py').read_text())
        self.assertIn('--only-binary=:all:',(ROOT/'chat/install.py').read_text())

if __name__=='__main__':unittest.main()
