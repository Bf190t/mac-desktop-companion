"""Second-stage installer for the optional reading voice, run only after the portable Python hash
was verified. Only prebuilt PyPI wheels with committed SHA-256 hashes and a pinned safetensors model
are accepted; no model repository code or pickle files are executed.

Unlike the chat installer, this one runs the model once at the end: it records the hourly chimes in
the companion's voice (Chinese and English), so a chime never loads the model, and it checks that
the voice really speaks before the installation is committed.
"""
from pathlib import Path, PurePosixPath
import base64
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import wave

child = None
# Same profile as app/Sources/WorkerSandbox.swift (a test checks they match): no network, no programs other
# than the helper's own Python runtime, no opening apps or links, no Apple events.
SANDBOX_PROFILE = ('(version 1)(allow default)(deny network*)(deny lsopen)(deny appleevent-send)'
                   '(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") (global-name-prefix "com.apple.lsd.")'
                   ' (global-name "com.apple.pasteboard.1") (global-name-prefix "com.apple.backgroundtaskmanagement")'
                   ' (global-name-prefix "com.apple.coreservices.sharedfilelistd") (global-name "com.apple.dock.server")'
                   ' (global-name "com.apple.securityd.xpc") (global-name "com.apple.SecurityServer"))'
                   '(deny signal)(allow signal (target same-sandbox))'
                   '(deny process-exec*)(allow process-exec (subpath (param "RUNTIME")))'
                   '(deny device-microphone)(deny device-camera)(deny user-preference-write)'
                   '(deny file-write*)(allow file-write* (subpath (param "USERDIR")) (literal "/dev/null") (literal "/dev/zero")'
                   ' (literal "/dev/dtracehelper") (subpath "/dev/fd"))')
HELPER_FOLDER = 'desktop-companion-helpers'   # same as WorkerSandbox.helperFolderName


def user_directory():
    """The helper's own owner-only folder inside this user's private temporary folder (…/T/desktop-companion-helpers),
    the only place it may write besides a few /dev nodes, and its TMPDIR. Not T itself (installer downloads, the
    single-instance lock) and not T's parent (other apps' caches in C/, system data in 0/). Mirrors WorkerSandbox."""
    import ctypes
    buffer = ctypes.create_string_buffer(1024)
    length = ctypes.CDLL(None).confstr(65537, buffer, len(buffer))   # _CS_DARWIN_USER_TEMP_DIR
    temp = buffer.value.decode() if 0 < length <= len(buffer) else tempfile.gettempdir()
    folder = Path(os.path.realpath(temp)) / HELPER_FOLDER
    try:
        os.mkdir(folder, 0o700)
    except FileExistsError:
        pass
    try:
        fd = os.open(folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)   # never follow a planted link
    except OSError:
        return folder
    try:
        info = os.fstat(fd)
        if info.st_uid == os.getuid() and info.st_mode & 0o077:
            os.fchmod(fd, 0o700)
    finally:
        os.close(fd)
    return folder


def helper_environment():
    """Environment for the sandboxed voice helper, like WorkerSandbox.environment(): nothing inherited."""
    return {'PATH': '/usr/bin:/bin', 'HOME': os.path.expanduser('~'), 'TMPDIR': f'{user_directory()}/', 'HF_HUB_OFFLINE': '1',
            'TRANSFORMERS_OFFLINE': '1', 'HF_HUB_DISABLE_TELEMETRY': '1', 'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONUNBUFFERED': '1'}


def sandboxed(python):
    """sandbox-exec command that runs `python` (a Path) under SANDBOX_PROFILE."""
    runtime = Path(os.path.realpath(python)).parent.parent
    return ['/usr/bin/sandbox-exec', '-D', f'RUNTIME={runtime}', '-D', f'USERDIR={user_directory()}',
            '-p', SANDBOX_PROFILE, str(python)]
ENGLISH = ['midnight', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven']


def stop(signum, frame):
    global child
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    raise SystemExit(130)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def run(command):
    global child
    child = subprocess.Popen(command, stdout=sys.stderr, stderr=sys.stderr,
                             start_new_session=True, env={**os.environ, 'PIP_CONFIG_FILE': os.devnull})
    code = child.wait()
    child = None
    if code:
        raise RuntimeError(f'Installer subprocess failed ({code})')


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while block := stream.read(4 * 1024 * 1024):
            value.update(block)
    return value.hexdigest()


def valid_entry(entry):
    """A file name, or one sub-folder plus a file name (speech_tokenizer/config.json)."""
    name = entry.get('name', '')
    if not isinstance(name, str) or '\\' in name:
        return False
    parts = PurePosixPath(name).parts
    return (0 < len(parts) <= 2 and not PurePosixPath(name).is_absolute()
            and all(p not in ('', '.', '..') for p in parts)
            and isinstance(entry.get('bytes'), int) and not isinstance(entry['bytes'], bool) and entry['bytes'] > 0
            and isinstance(entry.get('sha256'), str) and len(entry['sha256']) == 64
            and all(c in '0123456789abcdef' for c in entry['sha256']))


def chime_texts():
    """What the hourly chime says. The same sentences are spoken by the system voice as a fallback."""
    texts = {}
    for hour in range(24):
        texts[f'zh/chime-{hour:02d}'] = f'现在是{hour}点。'
        if hour == 0:
            english = "It's midnight."
        elif hour == 12:
            english = "It's noon."
        else:
            part = 'in the morning' if hour < 12 else 'in the afternoon' if hour < 18 else 'in the evening'
            english = f"It's {ENGLISH[hour % 12]} o'clock {part}."
        texts[f'en/chime-{hour:02d}'] = english
    texts['zh/chime-test'] = '这是报时示例。'
    texts['en/chime-test'] = 'This is a time announcement preview.'
    return texts


def record_chimes(stage, resources, runtime=None):
    """Runs the real voice helper once (sandboxed: no network, no other programs) and writes one WAV per
    chime into stage/voices/chimes, cloning stage/voices/companion_voice.wav. The Python runtime, packages and
    model come from `runtime` (default: the stage itself; an existing installation when switching voice)."""
    runtime = runtime or stage
    worker = [*sandboxed(runtime / 'python-base/bin/python3.12'), '-I', '-B', '-u', str(resources / 'tts_worker.py'),
              '--deps', str(runtime / 'deps'), '--model-path', str(runtime / 'model'),
              '--voice-ref', str(stage / 'voices/companion_voice.wav')]
    global child
    child = subprocess.Popen(worker, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, start_new_session=True,
                             env=helper_environment())
    watchdog = threading.Timer(900, lambda: os.killpg(child.pid, signal.SIGKILL))
    watchdog.start()
    pending = list(chime_texts().items())
    total, results, current = len(pending), {}, None

    def send_next():
        nonlocal current
        if not pending:
            return False
        current, text = pending.pop(0)
        language = 'english' if current.startswith('en/') else 'chinese'
        results[current] = bytearray()
        child.stdin.write((json.dumps({'op': 'speak', 'id': current, 'text': text, 'language': language}) + '\n').encode())
        child.stdin.flush()
        return True
    try:
        for raw in child.stdout:
            event = json.loads(raw)
            kind = event['event']
            if kind == 'ready':
                send_next()
            elif kind == 'audio':
                results[event['id']] += base64.b64decode(event['pcm'])
            elif kind == 'done':
                if not results[event['id']]:
                    raise RuntimeError('The voice produced no sound for ' + event['id'])
                print(json.dumps({'progress': .88 + .1 * (total - len(pending)) / total, 'phase': 'chimes'}), flush=True)
                if not send_next():
                    break
            elif kind in ('error', 'cancelled'):
                raise RuntimeError(f"Voice check failed: {event.get('code', kind)} {event.get('detail', '')}")
    finally:
        watchdog.cancel()
        child.stdin.close()
        try:
            child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        child = None
    if len(results) != total or any(not pcm for pcm in results.values()):
        raise RuntimeError('The voice helper stopped before all chimes were recorded')
    for name, pcm in results.items():
        target = stage / 'voices/chimes' / f'{name}.wav'
        target.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(target), 'wb') as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(24000)
            output.writeframes(bytes(pcm))


def install(stage, resources):
    stage = stage.resolve(strict=True)
    resources = resources.resolve(strict=True)
    # Weights (~2 GB) + wheels + installed packages (~0.5 GB), with room to spare.
    if shutil.disk_usage(stage).free < 4 * 1024**3:
        raise RuntimeError('At least 4 GiB of free disk space is required')
    manifest = json.loads((resources / 'model-manifest.json').read_text())
    if manifest['repo'] != 'mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit' or manifest['revision'] != '50f45ef0047cde7e84c2ef04326acb8ada2436a7':
        raise RuntimeError('Unexpected model revision')
    if not all(valid_entry(item) for item in manifest['files']):
        raise RuntimeError('Invalid model manifest')
    run([sys.executable, '-I', '-B', '-m', 'pip', '--isolated', 'install',
         '--disable-pip-version-check', '--no-input', '--no-cache-dir',
         '--only-binary=:all:', '--require-hashes', '--no-deps',
         '--index-url', 'https://pypi.org/simple', '--target', str(stage / 'deps'),
         '-r', str(resources / 'requirements-lock.txt')])
    shutil.rmtree(stage / 'deps' / 'bin', ignore_errors=True)
    model = stage / 'model'
    model.mkdir()
    total = sum(entry['bytes'] for entry in manifest['files'])
    completed = 0
    for entry in manifest['files']:
        name = entry['name']
        print(json.dumps({'progress': .2 + .65 * completed / total, 'phase': 'model', 'file': name}), flush=True)
        target = model / name
        target.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://huggingface.co/{manifest['repo']}/resolve/{manifest['revision']}/{name}?download=true"
        run(['/usr/bin/curl', '-q', '--max-filesize', str(entry['bytes']), '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
             '--silent', '--show-error', '--connect-timeout', '30', '--max-time', '1800', '--retry', '2',
             url, '-o', str(target)])
        if target.stat().st_size != entry['bytes'] or digest(target) != entry['sha256']:
            raise RuntimeError('Model checksum mismatch: ' + name)
        completed += entry['bytes']
    for filename in ['model-manifest.json', 'runtime-manifest.json', 'requirements-lock.txt',
                     'MODEL-LICENSE.txt', 'THIRD-PARTY-NOTICES.txt']:
        shutil.copyfile(resources / filename, stage / filename)
    (stage / 'voices').mkdir()
    for filename in ['companion_voice.wav', 'companion_voice.json']:
        shutil.copyfile(resources / filename, stage / 'voices' / filename)
    run([sys.executable, '-I', '-B', '-c',
         'import sys;sys.path.insert(0,sys.argv[1]);import mlx.core,mlx_audio;print("Imports verified",file=sys.stderr)',
         str(stage / 'deps')])
    print(json.dumps({'progress': .87, 'phase': 'chimes'}), flush=True)
    record_chimes(stage, resources)
    marker = {'schema': 1, 'kind': 'voice', 'model_revision': manifest['revision'],
              'requirements_sha256': digest(resources / 'requirements-lock.txt'),
              'runtime_sha256': json.loads((resources / 'runtime-manifest.json').read_text())['sha256'],
              'voice_sha256': digest(resources / 'companion_voice.wav'), 'chimes': ['zh', 'en']}
    (stage / 'installation.json').write_text(json.dumps(marker, indent=2) + '\n')
    print(json.dumps({'progress': .99, 'phase': 'verified'}), flush=True)


RENAME_SWAP = 0x00000002    # <stdio.h> flag for renamex_np(2): exchange the two paths atomically


def swap_paths(first, second):
    """Exchanges two directory entries in one step with macOS renamex_np(RENAME_SWAP). Both names
    exist at every instant, so a kill or power loss leaves either the old or the new arrangement,
    never a missing folder. Raises OSError (ENOTSUP when the system or file system cannot swap)."""
    import ctypes
    import errno
    try:
        renamex = ctypes.CDLL(None, use_errno=True).renamex_np
    except (AttributeError, OSError):
        raise OSError(errno.ENOTSUP, 'renamex_np is not available') from None
    renamex.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex.restype = ctypes.c_int
    if renamex(os.fsencode(first), os.fsencode(second), RENAME_SWAP) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(first), None, str(second))


def recover_interrupted_switch(root, expected_sha):
    """Undoes what an interrupted earlier switch can have left. Before swap_paths (and where
    swapping is unsupported) voices/ was renamed into the staging folder first; a kill between the
    two renames left no voices/ at all. Put that previous folder back (preferring the one that
    matches installation.json), then remove staging leftovers. Symbolic links are never followed."""
    voices = root / 'voices'
    leftovers = sorted(p for p in root.glob('.voice-switch.*') if p.is_dir() and not p.is_symlink())
    if not os.path.lexists(voices):
        candidates = [p / 'previous-voices' for p in leftovers
                      if (p / 'previous-voices').is_dir() and not (p / 'previous-voices').is_symlink()
                      and (p / 'previous-voices/companion_voice.wav').is_file()]
        candidates.sort(key=lambda p: digest(p / 'companion_voice.wav') != expected_sha)
        if candidates:
            os.rename(candidates[0], voices)
    for leftover in root.glob('.voice-switch.*'):
        shutil.rmtree(leftover, ignore_errors=True)     # refuses symbolic links; they stay


def switch_voice(root, resources, recorder=None):
    """Moves an existing installation to the voice sample bundled with this app, without
    downloading anything. Allowed only when the model revision, locked packages and Python runtime
    are exactly the ones this app installs (true from 0.2.0 to 0.2.1): then only the sample and the
    chimes recorded with it differ. The chimes are re-recorded with the installed model (network
    denied) into a staging folder; voices/ is swapped and installation.json rewritten only after
    that succeeded, so the app never pairs the new marker with the old sample. The swap is one
    atomic step (swap_paths); if the marker cannot be written the folders are swapped back. A run
    interrupted by an older version is repaired first (recover_interrupted_switch). Returns False
    when nothing needed switching."""
    root = root.resolve(strict=True)
    resources = resources.resolve(strict=True)
    marker = json.loads((root / 'installation.json').read_text())
    manifest = json.loads((resources / 'model-manifest.json').read_text())
    runtime_sha = json.loads((resources / 'runtime-manifest.json').read_text())['sha256']
    if (marker.get('schema') != 1 or marker.get('kind') != 'voice'
            or marker.get('model_revision') != manifest['revision']
            or marker.get('requirements_sha256') != digest(resources / 'requirements-lock.txt')
            or marker.get('runtime_sha256') != runtime_sha):
        raise RuntimeError('This installation differs from this app beyond the voice; remove it and install again')
    sample = digest(resources / 'companion_voice.wav')
    if json.loads((resources / 'companion_voice.json').read_text()).get('sha256') != sample:
        raise RuntimeError('The bundled voice sample does not match its description')
    recover_interrupted_switch(root, marker.get('voice_sha256'))
    installed = root / 'voices/companion_voice.wav'
    if marker.get('voice_sha256') == sample and installed.is_file() and digest(installed) == sample:
        return False
    stage = Path(tempfile.mkdtemp(prefix='.voice-switch.', dir=root))
    try:
        (stage / 'voices').mkdir()
        for filename in ['companion_voice.wav', 'companion_voice.json']:
            shutil.copyfile(resources / filename, stage / 'voices' / filename)
        print(json.dumps({'progress': .1, 'phase': 'chimes'}), flush=True)
        (recorder or record_chimes)(stage, resources, runtime=root)
        if digest(stage / 'voices/companion_voice.wav') != sample:
            raise RuntimeError('The staged voice sample changed while recording')
        # Commit. Cancelling cannot interrupt it halfway (SIGTERM waits until it is done); SIGKILL
        # or power loss can, so every step leaves a voices/ folder in place.
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
        try:
            current, new = root / 'voices', stage / 'voices'
            if not os.path.lexists(current):
                os.rename(new, current)                      # nothing to keep: just move it in
                undo = lambda: os.rename(current, new)
            else:
                try:
                    swap_paths(new, current)                 # atomic: old or new, never neither
                    undo = lambda: swap_paths(new, current)
                except OSError as error:
                    import errno
                    if error.errno not in (errno.ENOTSUP, errno.EINVAL, errno.ENOSYS, errno.EXDEV):
                        raise
                    # No atomic swap here (another file system): two renames; a run that is
                    # killed between them is repaired by recover_interrupted_switch() next time.
                    os.rename(current, stage / 'previous-voices')
                    try:
                        os.rename(new, current)
                    except OSError:
                        os.rename(stage / 'previous-voices', current)
                        raise
                    undo = lambda: (os.rename(current, new), os.rename(stage / 'previous-voices', current))
            marker['voice_sha256'] = sample
            temporary = root / '.installation.json.tmp'
            try:
                temporary.write_text(json.dumps(marker, indent=2) + '\n')
                os.replace(temporary, root / 'installation.json')
            except BaseException:
                undo()                                       # the folder must match the marker again
                temporary.unlink(missing_ok=True)
                raise
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGINT})
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    print(json.dumps({'progress': .99, 'phase': 'verified'}), flush=True)
    return True


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--switch-voice':
            switch_voice(Path(sys.argv[2]), Path(sys.argv[3]))
            raise SystemExit(0)
        if len(sys.argv) != 3:
            raise RuntimeError('Expected staging and resource directories')
        install(Path(sys.argv[1]), Path(sys.argv[2]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
