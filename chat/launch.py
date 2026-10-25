"""Isolated entry point; application supplies the optional-install directory."""
from pathlib import Path
import os
import runpy
import sys

if len(sys.argv) < 2:
    raise SystemExit('Missing installation directory')
root = Path(sys.argv.pop(1)).resolve(strict=True)
if not (root / 'installation.json').is_file():
    raise SystemExit('Optional chat is not installed')
# -I ignores environment/PYTHONPATH and user site-packages. Only the pinned
# dependency directory is added, never the working directory or shell profile.
sys.path.insert(0, str(root / 'deps'))
os.environ['COMPANION_CHAT_ROOT'] = str(root)
runpy.run_path(str(Path(__file__).with_name('worker.py')), run_name='__main__')
