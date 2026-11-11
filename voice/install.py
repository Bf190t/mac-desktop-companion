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
import threading
import wave

child = None
SANDBOX = ['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)']
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


def record_chimes(stage, resources):
    """Runs the real voice helper once (network denied) and writes one WAV per chime."""
    worker = [*SANDBOX, str(stage / 'python-base/bin/python3.12'), '-I', '-B', '-u', str(resources / 'tts_worker.py'),
              '--deps', str(stage / 'deps'), '--model-path', str(stage / 'model'),
              '--voice-ref', str(stage / 'voices/companion_voice.wav')]
    global child
    child = subprocess.Popen(worker, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, start_new_session=True)
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
        run(['/usr/bin/curl', '--fail', '--location', '--proto', '=https', '--proto-redir', '=https',
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


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3:
            raise RuntimeError('Expected staging and resource directories')
        install(Path(sys.argv[1]), Path(sys.argv[2]))
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
