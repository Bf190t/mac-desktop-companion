"""Second-stage installer, run only after the portable Python hash was verified.

Only prebuilt PyPI wheels with committed SHA-256 hashes and a pinned safetensors
model are accepted. No model repository code or pickle files are executed.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time

child = None

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
    name = entry.get('name', '')
    return (isinstance(name, str) and name not in ('', '.', '..')
            and Path(name).name == name and '/' not in name and '\\' not in name
            and isinstance(entry.get('bytes'), int) and not isinstance(entry['bytes'], bool) and entry['bytes'] > 0
            and isinstance(entry.get('sha256'), str) and len(entry['sha256']) == 64
            and all(c in '0123456789abcdef' for c in entry['sha256']))

def install(stage, resources):
    stage = stage.resolve(strict=True)
    resources = resources.resolve(strict=True)
    # A conservative peak-space allowance: weights + wheels + installed packages.
    if shutil.disk_usage(stage).free < 3 * 1024**3:
        raise RuntimeError('At least 3 GiB of free disk space is required')
    manifest = json.loads((resources / 'model-manifest.json').read_text())
    if manifest['repo'] != 'mlx-community/Qwen3-1.7B-4bit' or manifest['revision'] != '3b1b1768f8f8cf8351c712464f906e86c2b8269e':
        raise RuntimeError('Unexpected model revision')
    if not all(valid_entry(item) for item in manifest['files']):
        raise RuntimeError('Invalid model manifest')
    run([sys.executable, '-I', '-B', '-m', 'pip', '--isolated', 'install',
         '--disable-pip-version-check', '--no-input', '--no-cache-dir',
         '--only-binary=:all:', '--require-hashes', '--no-deps',
         '--index-url', 'https://pypi.org/simple', '--target', str(stage / 'deps'),
         '-r', str(resources / 'requirements-lock.txt')])
    # Entry-point scripts are not needed and contain staging paths. The app calls
    # the isolated Python directly, while package license metadata is retained.
    shutil.rmtree(stage / 'deps' / 'bin', ignore_errors=True)
    model = stage / 'model'
    model.mkdir()
    total = sum(entry['bytes'] for entry in manifest['files'])
    completed = 0
    for entry in manifest['files']:
        name = entry['name']
        print(json.dumps({'progress': .2 + .75 * completed / total, 'phase': 'model', 'file': name}), flush=True)
        target = model / name
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
    # Two upstream wheels omit their full license text. Retain the supplemental
    # upstream licenses shipped with either the source checkout or the app.
    for candidate in [resources.parent / 'ChatLicenses',
                      resources.parent / 'app/Resources/ChatLicenses']:
        if candidate.is_dir():
            shutil.copytree(candidate, stage / 'licenses', dirs_exist_ok=True)
            break
    # Verify imports before committing. GPU inference is deliberately deferred
    # until the user sends a message; installation itself does not load weights.
    run([sys.executable, '-I', '-B', '-c',
         'import sys;sys.path.insert(0,sys.argv[1]);import mlx.core,mlx_lm,psutil,transformers;print("Imports verified",file=sys.stderr)',
         str(stage / 'deps')])
    marker = {'schema': 1, 'model_revision': manifest['revision'],
              'requirements_sha256': digest(resources / 'requirements-lock.txt'),
              'runtime_sha256': json.loads((resources / 'runtime-manifest.json').read_text())['sha256']}
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
