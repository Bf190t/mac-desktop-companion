"""Offline tests for switching an installed 0.2.0 reading voice to the bundled sample in place.

No download and no model: a temporary folder stands in for the installation, and a fake Python
runtime speaks the helper's JSON-lines protocol, so the real record_chimes() path (sandboxed helper
process included) runs end to end.
"""
from contextlib import redirect_stdout
from pathlib import Path
import errno
import hashlib
import io
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # no __pycache__ next to the scripts under test

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('voice_installer', ROOT / 'voice/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

FAKE_WORKER = r'''
import base64, hashlib, json, os, sys
from pathlib import Path
# The sandbox lets the helper write only to its own folder, which is also its TMPDIR.
name = 'worker-args-' + hashlib.sha256(os.path.realpath(sys.argv[0]).encode()).hexdigest()[:16] + '.json'
Path(os.environ['TMPDIR'], name).write_text(json.dumps(sys.argv[1:]))
print(json.dumps({'event': 'ready', 'load_seconds': 0.1}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    pcm = base64.b64encode(b'\x01\x00' * 240).decode()
    print(json.dumps({'event': 'audio', 'id': request['id'], 'pcm': pcm}), flush=True)
    print(json.dumps({'event': 'done', 'id': request['id']}), flush=True)
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fake_installation(base):
    """An installation as 0.2.0 left it: same runtime, packages and model, previous voice sample."""
    resources = base / 'resources'
    resources.mkdir()
    for name in ['install.py', 'model-manifest.json', 'runtime-manifest.json', 'requirements-lock.txt',
                 'companion_voice.wav', 'companion_voice.json']:
        shutil.copyfile(ROOT / 'voice' / name, resources / name)
    # Stands in for the real helper (no model). The helper runs sandboxed: only programs inside the Python
    # runtime may start, so the fake runtime is a link to this test's own Python, not a shell script.
    (resources / 'tts_worker.py').write_text(FAKE_WORKER)
    root = base / 'Voice'
    (root / 'voices/chimes/zh').mkdir(parents=True)
    (root / 'model').mkdir()
    (root / 'model/model.safetensors').write_bytes(b'not a model')
    (root / 'deps').mkdir()
    old = b'RIFF' + b'previous sample' * 64
    (root / 'voices/companion_voice.wav').write_bytes(old)
    (root / 'voices/companion_voice.json').write_text(json.dumps({'sha256': hashlib.sha256(old).hexdigest()}))
    (root / 'voices/chimes/zh/chime-09.wav').write_bytes(b'old chime')
    python = root / 'python-base/bin/python3.12'
    python.parent.mkdir(parents=True)
    python.symlink_to(os.path.realpath(sys.executable))
    marker = {'schema': 1, 'kind': 'voice',
              'model_revision': json.loads((resources / 'model-manifest.json').read_text())['revision'],
              'requirements_sha256': sha(resources / 'requirements-lock.txt'),
              'runtime_sha256': json.loads((resources / 'runtime-manifest.json').read_text())['sha256'],
              'voice_sha256': hashlib.sha256(old).hexdigest(), 'chimes': ['zh', 'en']}
    (root / 'installation.json').write_text(json.dumps(marker))
    return root, resources


class VoiceSwitchTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root, self.resources = fake_installation(Path(self.folder.name))
        self.marker_before = self.marker()['voice_sha256']

    def tearDown(self):
        self.folder.cleanup()

    def marker(self):
        return json.loads((self.root / 'installation.json').read_text())

    def test_switch_records_chimes_with_installed_model_and_new_sample(self):
        with redirect_stdout(io.StringIO()) as progress:
            self.assertTrue(installer.switch_voice(self.root, self.resources))
        self.assertIn('"phase": "chimes"', progress.getvalue())
        new = sha(self.resources / 'companion_voice.wav')
        self.assertEqual(sha(self.root / 'voices/companion_voice.wav'), new)
        self.assertEqual(self.marker()['voice_sha256'], new)
        chimes = sorted(p.relative_to(self.root / 'voices/chimes').as_posix() for p in (self.root / 'voices/chimes').rglob('*.wav'))
        self.assertEqual(len(chimes), 50)
        self.assertIn('zh/chime-09.wav', chimes)
        self.assertNotEqual((self.root / 'voices/chimes/zh/chime-09.wav').read_bytes(), b'old chime')
        name = 'worker-args-' + hashlib.sha256(os.path.realpath(self.resources / 'tts_worker.py').encode()).hexdigest()[:16] + '.json'
        args_file = installer.user_directory() / name
        args = json.loads(args_file.read_text())
        args_file.unlink()
        self.assertEqual(args[args.index('--model-path') + 1], str((self.root / 'model').resolve()))
        self.assertEqual(args[args.index('--deps') + 1], str((self.root / 'deps').resolve()))
        reference = Path(args[args.index('--voice-ref') + 1])
        self.assertEqual(reference.name, 'companion_voice.wav')
        self.assertIn('.voice-switch.', str(reference))          # the new sample, never the old one
        self.assertEqual(list(self.root.glob('.voice-switch.*')), [])
        self.assertFalse(installer.switch_voice(self.root, self.resources))    # already current

    def test_failed_recording_keeps_previous_installation_untouched(self):
        before = (self.root / 'installation.json').read_bytes(), sha(self.root / 'voices/companion_voice.wav')
        def broken(stage, resources, runtime=None):
            raise RuntimeError('helper failed')
        with self.assertRaisesRegex(RuntimeError, 'helper failed'):
            installer.switch_voice(self.root, self.resources, recorder=broken)
        self.assertEqual((self.root / 'installation.json').read_bytes(), before[0])
        self.assertEqual(sha(self.root / 'voices/companion_voice.wav'), before[1])
        self.assertEqual((self.root / 'voices/chimes/zh/chime-09.wav').read_bytes(), b'old chime')
        self.assertEqual(list(self.root.glob('.voice-switch.*')), [])

    def test_refuses_when_more_than_the_voice_differs(self):
        for key, value in [('model_revision', '0' * 40), ('requirements_sha256', '0' * 64), ('runtime_sha256', '0' * 64), ('kind', 'chat')]:
            marker = self.marker()
            original = dict(marker)
            marker[key] = value
            (self.root / 'installation.json').write_text(json.dumps(marker))
            with self.assertRaisesRegex(RuntimeError, 'install again'):
                installer.switch_voice(self.root, self.resources, recorder=lambda *a, **k: self.fail('recorded'))
            (self.root / 'installation.json').write_text(json.dumps(original))

    def test_refuses_a_bundled_sample_that_does_not_match_its_description(self):
        (self.resources / 'companion_voice.json').write_text(json.dumps({'sha256': '0' * 64}))
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            installer.switch_voice(self.root, self.resources, recorder=lambda *a, **k: self.fail('recorded'))

    # ---- interrupted switches (SIGKILL / power loss) ------------------------------------------

    def state(self):
        """(sample in voices/: 'old' | 'new' | 'missing', sample the marker names, leftover folders)."""
        new = sha(self.resources / 'companion_voice.wav')
        wav = self.root / 'voices/companion_voice.wav'
        voices = 'missing' if not wav.is_file() else 'new' if sha(wav) == new else 'old'
        marker = 'new' if self.marker()['voice_sha256'] == new else 'old'
        return voices, marker, sorted(p.name for p in self.root.glob('.voice-switch.*'))

    def killed_at(self, point):
        result = subprocess.run([sys.executable, '-I', '-B', '-c', KILLED_CHILD, str(ROOT / 'voice/install.py'),
                                 str(self.root), str(self.resources), point], capture_output=True, text=True)
        self.assertEqual(result.returncode, 9, result.stderr)

    def finish_and_check(self):
        with redirect_stdout(io.StringIO()):
            self.assertTrue(installer.switch_voice(self.root, self.resources, recorder=quick_recorder))
        self.assertEqual(self.state(), ('new', 'new', []))
        self.assertEqual((self.root / 'voices/chimes/zh/chime-09.wav').read_bytes(), b'new chime')

    def test_swap_paths_exchanges_two_folders(self):
        a, b = Path(self.folder.name) / 'a', Path(self.folder.name) / 'b'
        a.mkdir(); b.mkdir(); (a / 'x').write_text('a'); (b / 'y').write_text('b')
        try:
            installer.swap_paths(a, b)
        except OSError as error:
            self.skipTest(f'no atomic swap here: {error}')
        self.assertEqual(sorted(os.listdir(a)), ['y'])
        self.assertEqual(sorted(os.listdir(b)), ['x'])

    def test_killed_before_the_swap_keeps_the_old_voice(self):
        self.killed_at('before-commit')
        voices, marker, leftovers = self.state()
        self.assertEqual((voices, marker), ('old', 'old'))   # the app still sees a working installation
        self.assertEqual(len(leftovers), 1)
        self.finish_and_check()

    def test_killed_right_after_the_swap_keeps_a_voices_folder(self):
        self.killed_at('after-swap')
        voices, marker, _ = self.state()
        self.assertEqual((voices, marker), ('new', 'old'))   # installed; the app offers to switch again
        self.finish_and_check()

    def test_killed_between_the_two_renames_of_the_fallback_is_repaired(self):
        """Where no atomic swap exists (and as 0.2.1 did it), voices/ is renamed away first; a kill
        right then leaves no voices/ folder. The next run puts the previous one back and switches."""
        self.killed_at('fallback-between-renames')
        voices, marker, leftovers = self.state()
        self.assertEqual((voices, marker), ('missing', 'old'))
        self.assertEqual(len(leftovers), 1)
        self.assertTrue((self.root / leftovers[0] / 'previous-voices/companion_voice.wav').is_file())
        self.finish_and_check()

    def test_state_left_by_the_old_two_rename_switch_is_repaired(self):
        leftover = self.root / '.voice-switch.abc123'
        (leftover / 'voices').mkdir(parents=True)
        os.rename(self.root / 'voices', leftover / 'previous-voices')
        recovered = []
        def recorder(stage, resources, runtime=None):
            recovered.append(sha(self.root / 'voices/companion_voice.wav'))
            quick_recorder(stage, resources, runtime)
        with redirect_stdout(io.StringIO()):
            self.assertTrue(installer.switch_voice(self.root, self.resources, recorder=recorder))
        self.assertEqual(recovered, [self.marker_before])        # the previous voice was back first
        self.assertEqual(self.state(), ('new', 'new', []))

    def test_fallback_without_atomic_swap_still_switches(self):
        def unsupported(first, second):
            raise OSError(errno.ENOTSUP, 'not supported')
        saved = installer.swap_paths
        installer.swap_paths = unsupported
        try:
            self.finish_and_check()
        finally:
            installer.swap_paths = saved

    def test_marker_write_failure_swaps_the_folders_back(self):
        saved = Path.write_text
        def full(path, *args, **kwargs):
            if path.name == '.installation.json.tmp':
                raise OSError(errno.ENOSPC, 'No space left on device')
            return saved(path, *args, **kwargs)
        Path.write_text = full
        try:
            with redirect_stdout(io.StringIO()), self.assertRaises(OSError):
                installer.switch_voice(self.root, self.resources, recorder=quick_recorder)
        finally:
            Path.write_text = saved
        self.assertEqual(self.state(), ('old', 'old', []))
        self.assertEqual((self.root / 'voices/chimes/zh/chime-09.wav').read_bytes(), b'old chime')
        self.assertFalse((self.root / '.installation.json.tmp').exists())
        self.finish_and_check()

    def test_missing_voices_folder_gets_the_new_voice(self):
        shutil.rmtree(self.root / 'voices')
        self.finish_and_check()

    def test_symlinked_leftover_is_not_followed(self):
        victim = Path(self.folder.name) / 'victim'
        (victim / 'previous-voices').mkdir(parents=True)
        (victim / 'previous-voices/companion_voice.wav').write_bytes(b'RIFF elsewhere')
        os.symlink(victim, self.root / '.voice-switch.link')
        shutil.rmtree(self.root / 'voices')
        with redirect_stdout(io.StringIO()):
            self.assertTrue(installer.switch_voice(self.root, self.resources, recorder=quick_recorder))
        self.assertTrue((victim / 'previous-voices/companion_voice.wav').is_file())
        self.assertTrue(os.path.islink(self.root / '.voice-switch.link'))
        self.assertEqual(sha(self.root / 'voices/companion_voice.wav'), sha(self.resources / 'companion_voice.wav'))


def quick_recorder(stage, resources, runtime=None):
    (stage / 'voices/chimes/zh').mkdir(parents=True)
    (stage / 'voices/chimes/zh/chime-09.wav').write_bytes(b'new chime')


# Runs switch_voice in a child process that dies with os._exit(9) (like SIGKILL: no cleanup, no
# finally blocks) at the chosen point.
KILLED_CHILD = r'''
import errno, importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('voice_installer', sys.argv[1])
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
root, resources, point = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
def recorder(stage, resources, runtime=None):
    (stage / 'voices/chimes/zh').mkdir(parents=True)
    (stage / 'voices/chimes/zh/chime-09.wav').write_bytes(b'new chime')
    if point == 'before-commit':
        os._exit(9)
real_swap, real_rename = installer.swap_paths, os.rename
def swap(first, second):
    if point == 'fallback-between-renames':
        raise OSError(errno.ENOTSUP, 'not supported')
    real_swap(first, second)
    if point == 'after-swap':
        os._exit(9)
def rename(source, target):
    real_rename(source, target)
    if point == 'fallback-between-renames' and Path(target).name == 'previous-voices':
        os._exit(9)
installer.swap_paths = swap
installer.os.rename = rename
installer.switch_voice(root, resources, recorder=recorder)
os._exit(0)
'''


if __name__ == '__main__':
    unittest.main()
