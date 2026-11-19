#!/usr/bin/env python3
"""The model helpers' sandbox (security review 2026-11-19).

1. app/Sources/WorkerSandbox.swift and voice/install.py use the same profile.
2. Under that profile a helper cannot connect anywhere (not even 127.0.0.1), cannot start other programs
   (/usr/bin/true, /usr/bin/open, /bin/sh), but its own Python runtime still runs and can start itself.
Nothing here opens an app or goes online: the only listener is a local socket created by this test.
"""
import ast
import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
failures = []


def check(name, ok):
    if not ok:
        failures.append(name)
        print('FAIL', name)


def swift_profile():
    text = (ROOT / 'app/Sources/WorkerSandbox.swift').read_text()
    block = re.search(r'static let profile = (.*?)\n\n', text, re.S).group(1)
    return ''.join(ast.literal_eval(part) for part in re.findall(r'"(?:[^"\\]|\\.)*"', block))


def python_profile():
    text = (ROOT / 'voice/install.py').read_text()
    block = re.search(r'SANDBOX_PROFILE = \((.*?)\)\n', text, re.S).group(1)
    return ''.join(ast.literal_eval(part) for part in re.findall(r"'(?:[^'\\]|\\.)*'", block))


def main():
    profile = swift_profile()
    check('Swift and Python profiles match', profile == python_profile())
    for rule in ['(deny network*)', '(deny lsopen)', '(deny appleevent-send)', '(deny process-exec*)',
                 '(deny device-microphone)', '(deny device-camera)', '(deny user-preference-write)',
                 '(global-name "com.apple.pasteboard.1")', '(global-name-prefix "com.apple.backgroundtaskmanagement")',
                 '(global-name-prefix "com.apple.coreservices.sharedfilelistd")', '(deny signal)', '(deny file-write*)']:
        check('profile has ' + rule, rule in profile)

    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    sys.path.insert(0, str(ROOT / 'voice'))
    import install as voice_install
    userdir = voice_install.user_directory()
    sys.path.pop(0)
    check('helper folder is its own folder in the per-user temporary folder',
          str(userdir).startswith('/private/var/folders/') and userdir.name == voice_install.HELPER_FOLDER
          and userdir.parent.name == 'T' and userdir.is_dir() and (userdir.stat().st_mode & 0o777) == 0o700)
    import uuid
    tag = uuid.uuid4().hex
    prefs_domain = f'com.example.sandbox-probe.{tag}'
    board_name = f'sandbox-probe-{tag}'
    outsider = subprocess.Popen(['/bin/sleep', '60'])
    outsider_pid = outsider.pid
    blocked_targets = {
        'caches': userdir.parent.parent / 'C' / f'sandbox-write-probe-{tag}.txt',     # other apps' caches
        'troot': userdir.parent / f'sandbox-write-probe-{tag}.txt',                   # installers, lock
        'home': Path.home() / f'.sandbox-write-probe-{tag}',
        'tmp': Path('/private/tmp') / f'sandbox-write-probe-{tag}',
    }
    outside = str(ROOT / 'build' / 'sandbox-write-probe.txt')
    (ROOT / 'build').mkdir(exist_ok=True)
    inside = str(userdir)
    probe = f'''
import socket, subprocess, sys
def blocked(action):
    try:
        action()
        return False
    except (OSError, subprocess.SubprocessError):
        return True
s = socket.socket()
print('tcp', blocked(lambda: s.connect(('127.0.0.1', {port}))))
print('true', blocked(lambda: subprocess.run(['/usr/bin/true'], check=True)))
print('open', blocked(lambda: subprocess.run(['/usr/bin/open', '-h'], check=True, capture_output=True)))
print('sh', blocked(lambda: subprocess.run(['/bin/sh', '-c', 'exit 0'], check=True)))
print('self', not blocked(lambda: subprocess.run([sys.executable, '-I', '-c', 'pass'], check=True)))
import ctypes, os, tempfile
check = ctypes.CDLL('/usr/lib/libSystem.B.dylib').sandbox_check
check.restype = ctypes.c_int
check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p]
print('mic', check(os.getpid(), b'device-microphone', 0x40000000, None) == 1)
print('camera', check(os.getpid(), b'device-camera', 0x40000000, None) == 1)
print('outside', blocked(lambda: open({outside!r}, 'w').close()))
for name, target in {({k: str(v) for k, v in blocked_targets.items()})!r}.items():
    print(name, blocked(lambda: open(target, 'w').close()))
print('devnull', not blocked(lambda: open('/dev/null', 'w').write('x')))
cf = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cfs = lambda text: cf.CFStringCreateWithCString(None, text.encode(), 0x08000100)
cf.CFPreferencesSetAppValue.argtypes = [ctypes.c_void_p] * 3
cf.CFPreferencesAppSynchronize.argtypes = [ctypes.c_void_p]
cf.CFPreferencesAppSynchronize.restype = ctypes.c_ubyte
cf.CFPreferencesSetAppValue(cfs('probe'), cfs('x'), cfs({prefs_domain!r}))
print('prefswrite', cf.CFPreferencesAppSynchronize(cfs({prefs_domain!r})) == 0)
objc = ctypes.cdll.LoadLibrary('/usr/lib/libobjc.A.dylib')
ctypes.cdll.LoadLibrary('/System/Library/Frameworks/AppKit.framework/AppKit')
objc.objc_getClass.restype = ctypes.c_void_p
objc.objc_getClass.argtypes = [ctypes.c_char_p]
objc.sel_registerName.restype = ctypes.c_void_p
objc.sel_registerName.argtypes = [ctypes.c_char_p]
send = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value)
board = send(objc.objc_getClass(b'NSPasteboard'), objc.sel_registerName(b'pasteboardWithName:'), cfs({board_name!r}))
print('pasteboard', not board)
cs = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreServices.framework/CoreServices')
login_key = ctypes.c_void_p.in_dll(cs, 'kLSSharedFileListSessionLoginItems').value
cs.LSSharedFileListCreate.restype = ctypes.c_void_p
cs.LSSharedFileListCreate.argtypes = [ctypes.c_void_p] * 3
cs.LSSharedFileListCopySnapshot.restype = ctypes.c_void_p
cs.LSSharedFileListCopySnapshot.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
items = cs.LSSharedFileListCreate(None, login_key, None)
seed = ctypes.c_uint32()
snapshot = cs.LSSharedFileListCopySnapshot(items, ctypes.byref(seed)) if items else None
print('loginitems', not snapshot or cf.CFArrayGetCount(snapshot) == 0)
import signal as signals
print('signal', blocked(lambda: os.kill({outsider_pid}, signals.SIGCONT)))
print('prefs', check(os.getpid(), b'user-preference-write', 0x40000000, None) == 1)
inside = tempfile.NamedTemporaryFile(dir={inside!r}, delete=True)
print('inside', True)
'''
    runtime = Path(os.path.realpath(sys.executable)).parent.parent
    result = subprocess.run(['/usr/bin/sandbox-exec', '-D', f'RUNTIME={runtime}', '-D', f'USERDIR={userdir}', '-p', profile,
                             sys.executable, '-I', '-c', probe],
                            capture_output=True, text=True, timeout=60, env={'PATH': '/usr/bin:/bin', 'HOME': os.environ.get('HOME', '/')})
    listener.close()
    seen = dict(line.split() for line in result.stdout.splitlines() if len(line.split()) == 2)
    check(f'sandboxed probe ran (exit {result.returncode}: {result.stderr.strip()[-200:]})', result.returncode == 0)
    check('TCP to 127.0.0.1 blocked', seen.get('tcp') == 'True')
    check('/usr/bin/true blocked', seen.get('true') == 'True')
    check('/usr/bin/open blocked', seen.get('open') == 'True')
    check('/bin/sh blocked', seen.get('sh') == 'True')
    check('own Python runtime still runs', seen.get('self') == 'True')
    check('microphone denied', seen.get('mic') == 'True')
    check('camera denied', seen.get('camera') == 'True')
    check('writing outside the private temporary folder blocked', seen.get('outside') == 'True' and not Path(outside).exists())
    for name, label in [('caches', "the per-user cache folder (other apps' caches)"), ('troot', 'the shared temporary folder itself'),
                        ('home', 'the home folder'), ('tmp', '/private/tmp')]:
        target = blocked_targets[name]
        check(f'writing in {label} blocked', seen.get(name) == 'True' and not target.exists())
        if target.exists():
            target.unlink()
    outsider.kill()
    outsider.wait()
    prefs_file = Path.home() / 'Library/Preferences' / f'{prefs_domain}.plist'
    check('writing app preferences (cfprefsd) denied', seen.get('prefswrite') == 'True' and not prefs_file.exists())
    if prefs_file.exists():
        prefs_file.unlink()
    check('pasteboard unavailable', seen.get('pasteboard') == 'True')
    check('login items unreachable', seen.get('loginitems') == 'True')
    check('signals to other processes blocked', seen.get('signal') == 'True')
    check('/dev/null still writable', seen.get('devnull') == 'True')
    check('changing app preferences denied', seen.get('prefs') == 'True')
    check('writing in the private temporary folder allowed', seen.get('inside') == 'True')
    if failures:
        print(f'Worker sandbox: {len(failures)} check(s) failed')
        sys.exit(1)
    print('Worker sandbox: all checks passed')


if __name__ == '__main__':
    main()
