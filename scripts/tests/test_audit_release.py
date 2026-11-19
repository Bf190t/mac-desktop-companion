"""Regression tests for scripts/audit_release.py; offline, temporary folders only.

Private terms are never written here: every private-term case uses invented words supplied at run
time through a temporary deny-terms file or RELEASE_DENY_TERMS, which proves the mechanism. The
real terms live only in the maintainer's local file and in the CI secret. Strings that the audit
itself would flag (home paths, addresses, tokens, persona phrases) are assembled at run time so
this file passes its own audit.
"""
from pathlib import Path
import base64
import gzip
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import wave
import zlib

sys.dont_write_bytecode = True   # no __pycache__ next to the scripts under test
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/audit_release.py'
spec = importlib.util.spec_from_file_location('audit_release', SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

FAKE_CJK = '朔砚澜'      # three unrelated characters standing in for a private name
FAKE_EN = 'Zyxwv Qrstu'               # an invented two-word name
FAKE_PROJECT = 'Qorvexa'              # an invented project name
# "<age> high-school boy" in Chinese, from code points so this file passes its own audit.
PERSONA_ZH = ''.join(map(chr, [0x5341, 0x4e03, 0x5c81, 0x7684, 0x9ad8, 0x4e2d, 0x7537, 0x751f]))
PERSONA_EN = '17' + '-year-old ' + 'high' + ' school boy'
HOME = '/' + 'Users' + '/'
SOMEONE = 'some' + 'one'


def fullwidth(text):
    return ''.join(chr(ord(c) + 0xFEE0) if '!' <= c <= '~' else '　' for c in text)


def run(path, mode='source', terms=(), env_terms=None, extra=()):
    with tempfile.TemporaryDirectory() as folder:
        args = [sys.executable, '-I', str(SCRIPT), '--mode', mode, str(path), *extra]
        if terms:
            deny = Path(folder) / 'deny.txt'
            deny.write_text('# local only\n' + '\n'.join(terms) + '\n', encoding='utf-8')
            args += ['--deny-terms-file', str(deny)]
        env = {k: v for k, v in os.environ.items() if k != 'RELEASE_DENY_TERMS'}
        if env_terms is not None:
            env['RELEASE_DENY_TERMS'] = env_terms
        result = subprocess.run(args, capture_output=True, text=True, env=env)
    report = json.loads(result.stdout)
    assert (result.returncode == 0) == report['passed'], result.stdout
    return report, result.stdout


def tree(files):
    folder = Path(tempfile.mkdtemp())
    for name, data in files.items():
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data if isinstance(data, bytes) else data.encode('utf-8'))
    return folder


def rules(report):
    return {item['rule'] for item in report['findings']}


TERMS = [FAKE_CJK, FAKE_EN, FAKE_PROJECT]
# The reviewer's 19 samples, rebuilt with invented private words: name -> (files, rule expected).
SAMPLES = {
    'cjk-name': ({'app/a.txt': 'role: ' + FAKE_CJK}, 'private-term'),
    'home-path': ({'app/a.txt': 'path=' + HOME + SOMEONE + '/Desktop/x'}, 'private-home-path'),
    'project-name': ({'app/a.txt': FAKE_PROJECT + 'Pet'}, 'private-term'),
    'english-name': ({'app/a.txt': FAKE_EN}, 'private-term'),
    'other-project-cjk': ({'app/a.txt': FAKE_CJK[::-1] + FAKE_CJK}, 'private-term'),
    'other-project-en': ({'app/a.txt': 'x' + FAKE_PROJECT.upper() + 'y'}, 'private-term'),
    'persona-zh': ({'app/a.txt': PERSONA_ZH + '，声音清亮'}, 'persona-description'),
    'home-no-slash': ({'app/a.txt': 'home=' + HOME + SOMEONE}, 'private-home-path'),
    'tilde-folder': ({'app/a.txt': 'dir=~' + '/Desktop/x'}, 'personal-folder-path'),
    'email': ({'app/a.txt': 'mail=' + SOMEONE + '@' + 'example.com'}, 'email-address'),
    'hf-token': ({'app/a.txt': 'HF_TOKEN=' + 'hf_' + 'iKZWeqhFWCEPyYngFbyBMWXaSCrUZoLgub'}, 'huggingface-token'),
    'game-title': ({'app/a.txt': FAKE_EN + ' 3 Reload'}, 'private-term'),
    'bundle-upper': ({'app/a.txt': 'LOCAL.' + FAKE_PROJECT.upper() + '.desktop-pet'}, 'private-term'),
    'bundle-lower': ({'app/a.txt': 'local.' + FAKE_PROJECT.lower() + '.desktop-pet'}, 'private-term'),
    'nickname': ({'app/a.txt': '蓝' + FAKE_CJK}, 'private-term'),
    'utf16-no-bom': ({'app/a.txt': FAKE_CJK.encode('utf-16-le')}, 'private-term'),
    'spaced-out': ({'app/a.txt': ' '.join(FAKE_CJK)}, 'private-term'),
    'file-name': ({'docs/' + FAKE_PROJECT + '.png': b'x'}, 'private-term-in-path'),
    'unpinned-voice': ({'voice/companion_voice.wav': b'RIFF' + os.urandom(64)}, 'companion-voice-not-pinned'),
}


class AuditReleaseTests(unittest.TestCase):
    def test_reviewer_samples_are_all_blocked(self):
        self.assertEqual(len(SAMPLES), 19)
        for label, (files, expected) in SAMPLES.items():
            folder = tree(files)
            try:
                report, output = run(folder, terms=TERMS)
                self.assertFalse(report['passed'], label)
                self.assertIn(expected, rules(report), label)
                for term in TERMS:
                    self.assertNotIn(term, output, 'a private term was printed: ' + label)
            finally:
                shutil.rmtree(folder)

    def test_generic_rules_work_without_any_private_terms(self):
        for label in ('home-path', 'persona-zh', 'home-no-slash', 'tilde-folder', 'email', 'hf-token', 'unpinned-voice'):
            files, expected = SAMPLES[label]
            folder = tree(files)
            try:
                report, _ = run(folder)
                self.assertIn(expected, rules(report), label)
            finally:
                shutil.rmtree(folder)
        folder = tree({'docs/a.md': 'She is a ' + PERSONA_EN + '.'})
        try:
            self.assertIn('persona-description', rules(run(folder)[0]))
        finally:
            shutil.rmtree(folder)

    def test_terms_from_environment_and_normalized_forms(self):
        cases = {'fullwidth': fullwidth(FAKE_EN), 'no-space': FAKE_EN.replace(' ', ''),
                 'punctuated': '-'.join(FAKE_PROJECT), 'utf16-be': FAKE_CJK.encode('utf-16-be'),
                 'utf16-bom': FAKE_EN.encode('utf-16')}
        for label, data in cases.items():
            folder = tree({'app/a.txt': data})
            try:
                report, output = run(folder, env_terms='\n'.join(TERMS) + '\n')
                self.assertIn('private-term', rules(report), label)
                self.assertEqual(report['private_terms_loaded'], 3)
                self.assertNotIn(FAKE_EN, output)
            finally:
                shutil.rmtree(folder)

    def test_path_with_private_term_is_withheld(self):
        folder = tree({'docs/' + FAKE_PROJECT + '-art.txt': 'ok'})
        try:
            report, output = run(folder, terms=TERMS)
            self.assertIn('private-term-in-path', rules(report))
            self.assertNotIn(FAKE_PROJECT, output)
        finally:
            shutil.rmtree(folder)

    def test_placeholders_and_clean_text_pass(self):
        text = '\n'.join([
            'Contact: 12345+someone@users.noreply.github.com',
            'Example: ' + 'you' + '@' + 'example.com',
            'Shared: ' + HOME + 'Shared/Library', 'Placeholder: ' + HOME + '<name>/Library',
            'Placeholder: ' + HOME + '$USER/Library', 'Asset: icon_16x16' + '@' + '2x.png',
            'Install it to your Desktop folder.', 'A cheerful high school club, and a 17-year-old cat.',
        ])
        folder = tree({'docs/a.md': text})
        try:
            report, _ = run(folder, terms=TERMS)
            self.assertTrue(report['passed'], report['findings'])
        finally:
            shutil.rmtree(folder)

    def test_voice_is_pinned_twice(self):
        wav = (ROOT / 'voice/companion_voice.wav').read_bytes()
        recorded = json.loads((ROOT / 'voice/companion_voice.json').read_text())['sha256']
        self.assertEqual(hashlib.sha256(wav).hexdigest(), audit.COMPANION_VOICE_SHA256)
        self.assertEqual(recorded, audit.COMPANION_VOICE_SHA256)
        good = {'voice/companion_voice.wav': wav,
                'voice/companion_voice.json': (ROOT / 'voice/companion_voice.json').read_bytes()}
        folder = tree(good)
        try:
            self.assertTrue(run(folder)[0]['passed'])
        finally:
            shutil.rmtree(folder)
        # Like 0.2.0: a different sample whose JSON agrees with it is still rejected by the pin.
        other = b'RIFF' + os.urandom(128)
        meta = json.dumps({'sha256': hashlib.sha256(other).hexdigest()})
        folder = tree({'voice/companion_voice.wav': other, 'voice/companion_voice.json': meta})
        try:
            report, _ = run(folder)
            self.assertIn('companion-voice-not-pinned', rules(report))
            self.assertNotIn('companion-voice-json-mismatch', rules(report))
        finally:
            shutil.rmtree(folder)
        # The pinned sample with a JSON that disagrees.
        folder = tree({'voice/companion_voice.wav': wav, 'voice/companion_voice.json': json.dumps({'sha256': '0' * 64})})
        try:
            self.assertIn('companion-voice-json-mismatch', rules(run(folder)[0]))
        finally:
            shutil.rmtree(folder)

    def test_retired_voice_and_private_assets_blocked_under_any_name(self):
        self.assertIn('563bc296fb82a61737136e070621e52d1d154c6d7e820802c94479a19d486e14', audit.RETIRED_VOICE_SHA256)
        retired, asset = os.urandom(256), b'\x89PNG' + os.urandom(256)
        folder = tree({'docs/sample.bin': retired, 'docs/art/picture.png': asset})
        auditor = audit.Audit('source', [])
        saved = set(audit.RETIRED_VOICE_SHA256), audit.PRIVATE_ASSET_SHA256
        try:
            audit.RETIRED_VOICE_SHA256.add(hashlib.sha256(retired).hexdigest())
            audit.PRIVATE_ASSET_SHA256 = frozenset({hashlib.sha256(asset).hexdigest()})
            auditor.tree(folder)
        finally:
            audit.RETIRED_VOICE_SHA256.clear(); audit.RETIRED_VOICE_SHA256.update(saved[0])
            audit.PRIVATE_ASSET_SHA256 = saved[1]
            shutil.rmtree(folder)
        found = {(f['path'], f['rule']) for f in auditor.findings}
        self.assertIn(('docs/sample.bin', 'retired-voice'), found)
        self.assertIn(('docs/art/picture.png', 'private-asset'), found)

    def test_zip_checks_bundle_identifier(self):
        wav = (ROOT / 'voice/companion_voice.wav').read_bytes()
        meta = (ROOT / 'voice/companion_voice.json').read_bytes()
        def plist(identifier):
            key = 'CFBundle' + 'Identifier'
            return ('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                    f'<key>{key}</key><string>{identifier}</string></dict></plist>').encode()
        with tempfile.TemporaryDirectory() as folder:
            for label, entries, expected in [
                ('public', {'Info.plist': plist(audit.PUBLIC_BUNDLE_ID)}, None),
                ('other-id', {'Info.plist': plist('local.example.pet')}, 'unexpected-bundle-identifier'),
                ('no-plist', {}, 'missing-info-plist'),
            ]:
                archive = Path(folder) / f'{label}.zip'
                with zipfile.ZipFile(archive, 'w') as z:
                    app = 'Desktop Companion 9.9.9/Desktop Companion.app/Contents/'
                    for name, data in entries.items():
                        z.writestr(app + name, data)
                    z.writestr(app + 'Resources/Voice/companion_voice.wav', wav)
                    z.writestr(app + 'Resources/Voice/companion_voice.json', meta)
                report, _ = run(archive, mode='zip')
                if expected is None:
                    self.assertTrue(report['passed'], report['findings'])
                else:
                    self.assertIn(expected, rules(report), label)

    @unittest.skipUnless(shutil.which('git'), 'git is not installed')
    def test_history_mode_and_accepted_list(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder) / 'repo'
            repo.mkdir()
            env = {**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_COMMITTER_NAME': 't',
                   'GIT_AUTHOR_EMAIL': 'user' + '@' + 'example.com', 'GIT_COMMITTER_EMAIL': 'user' + '@' + 'example.com',
                   'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
            def git(*args):
                subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, env=env)
            git('init', '-q')
            (repo / 'notes.txt').write_text('about ' + FAKE_EN + '\n')
            git('add', '-A'); git('commit', '-q', '-m', 'one')
            (repo / 'notes.txt').write_text('clean now\n')
            git('add', '-A'); git('commit', '-q', '-m', 'two')
            empty = Path(folder) / 'accepted.json'
            empty.write_text(json.dumps({'schema': 1, 'accepted': []}))
            # The tip is clean, but the term is still in history.
            report, output = run(repo, mode='history', terms=TERMS, extra=['--accepted', str(empty)])
            self.assertFalse(report['passed'])
            self.assertEqual(rules(report), {'private-term'})
            self.assertNotIn(FAKE_EN, output)
            blob = report['findings'][0]['blob']
            accepted = Path(folder) / 'accepted2.json'
            accepted.write_text(json.dumps({'schema': 1, 'accepted': [{'blob': blob, 'rules': ['private-term']}]}))
            report, _ = run(repo, mode='history', terms=TERMS, extra=['--accepted', str(accepted)])
            self.assertTrue(report['passed'])
            self.assertEqual(len(report['accepted_history_findings']), 1)
            # A new hit in another blob still fails, even with the accepted list.
            (repo / 'other.txt').write_text('see ' + FAKE_PROJECT + '\n')
            git('add', '-A'); git('commit', '-q', '-m', 'three')
            report, _ = run(repo, mode='history', terms=TERMS, extra=['--accepted', str(accepted)])
            self.assertFalse(report['passed'])
            self.assertTrue(all(f['blob'] != blob for f in report['findings']))

    def test_accepted_history_entries_are_well_formed(self):
        data = json.loads((ROOT / 'scripts/audit-history-accepted.json').read_text())
        for item in data['accepted']:
            self.assertRegex(item['blob'], r'^[0-9a-f]{40}$')
            self.assertTrue(item['rules'] and item['reason'])

    # ---- second review round -------------------------------------------------------------

    def test_audio_is_found_by_content_under_any_name(self):
        """A retired voice that is transcoded, edited by one byte, renamed or hidden behind a few
        bytes no longer matches its hash; the content signature still catches it."""
        wav = io.BytesIO()
        with wave.open(wav, 'wb') as out:
            out.setnchannels(1); out.setsampwidth(2); out.setframerate(24000)
            out.writeframes(os.urandom(4000))
        wav = wav.getvalue()
        edited = wav[:-1] + bytes([wav[-1] ^ 1])
        samples = {
            'wav-renamed.bin': wav, 'wav-one-byte.dat': edited, 'wav-behind-prefix.bin': b'JUNK' + wav,
            'aiff.bin': b'FORM' + b'\x00\x00\x10\x00' + b'AIFF' + os.urandom(64),
            'aifc.bin': b'FORM' + b'\x00\x00\x10\x00' + b'AIFC' + os.urandom(64),
            'flac.bin': b'fLaC\x00\x00\x00\x22' + os.urandom(64),
            'ogg.bin': b'OggS\x00\x02' + os.urandom(64),
            'caf.bin': b'caff\x00\x01\x00\x00' + os.urandom(64),
            'm4a.bin': b'\x00\x00\x00\x20ftypM4A ' + os.urandom(64),
            'm4b.bin': b'\x00\x00\x00\x20ftypM4B ' + os.urandom(64),
            'mp4.bin': b'\x00\x00\x00\x20ftypisom' + os.urandom(64),
            'id3.bin': b'ID3\x04\x00\x00' + os.urandom(64),
            'mpeg-frame.bin': b'\xff\xfb\x90\x64' + os.urandom(64),
            'adts.bin': b'\xff\xf1\x50\x80' + os.urandom(64),
            'snd.bin': b'.snd\x00\x00\x00\x18' + os.urandom(64),
        }
        for label, data in samples.items():
            folder = tree({'docs/' + label: data})
            try:
                report, _ = run(folder)
                self.assertIn('audio-content', rules(report), label)
            finally:
                shutil.rmtree(folder)
        # Audio suffixes are blocked by name as well.
        for suffix in ('.mp3', '.m4a', '.caf', '.flac', '.ogg', '.opus', '.aac', '.m4b', '.mp4', '.au', '.aif', '.aiff'):
            self.assertIn(suffix, audit.FORBIDDEN_SUFFIXES)
        # The pinned voice itself, at its own path, is not reported; the same bytes elsewhere are.
        voice = (ROOT / 'voice/companion_voice.wav').read_bytes()
        folder = tree({'voice/companion_voice.wav': voice,
                       'voice/companion_voice.json': (ROOT / 'voice/companion_voice.json').read_bytes(),
                       'docs/copy.bin': voice})
        try:
            found = {(f['path'], f['rule']) for f in run(folder)[0]['findings']}
            self.assertEqual(found, {('docs/copy.bin', 'audio-content')})
        finally:
            shutil.rmtree(folder)
        # PNG, JPEG, PDF and plain text are not audio.
        for data in (b'\x89PNG\r\n\x1a\n' + os.urandom(64), b'\xff\xd8\xff\xe0' + os.urandom(64), b'%PDF-1.7\n', b'RIFF and WAVE are words'):
            self.assertIsNone(audit.audio_signature(data))

    def test_repository_ships_no_other_audio_or_archives(self):
        auditor = audit.Audit('source', [])
        auditor.tree(ROOT)
        self.assertFalse({f['rule'] for f in auditor.findings} & {'audio-content', 'nested-archive', 'nested-archive-name'},
                         auditor.findings)

    def test_folding_catches_look_alikes_marks_and_traditional_forms(self):
        cyr = {'o': 0x43e, 'e': 0x435, 'a': 0x430}
        greek = {'o': 0x3bf, 'a': 0x3b1}
        traditional = FAKE_CJK[0] + chr(0x786f) + chr(0x703e)          # the same name in traditional forms
        cases = {
            'cyrillic': ''.join(chr(cyr.get(c, ord(c))) for c in FAKE_PROJECT),
            'greek': ''.join(chr(greek.get(c, ord(c))) for c in FAKE_PROJECT),
            'combining-mark': FAKE_CJK[0] + '́' + FAKE_CJK[1:],
            'variation-selector': FAKE_CJK[0] + '︀' + FAKE_CJK[1:],
            'zero-width-joiner': FAKE_CJK[0] + '‍' + FAKE_CJK[1:],
            'accented-latin': FAKE_PROJECT.replace('e', 'é'),
            'traditional': traditional,
            'short-ascii-with-mark': 'x Q́rx y',
        }
        for label, text in cases.items():
            folder = tree({'docs/a.md': 'x ' + text + ' y'})
            try:
                report, output = run(folder, terms=TERMS + ['Qrx'])
                self.assertIn('private-term', rules(report), label)
                self.assertNotIn(FAKE_CJK, output)
            finally:
                shutil.rmtree(folder)
        # A term written in traditional characters matches simplified text, too.
        folder = tree({'docs/a.md': 'x ' + FAKE_CJK})
        try:
            self.assertIn('private-term', rules(run(folder, terms=[traditional])[0]))
        finally:
            shutil.rmtree(folder)

    def test_other_encodings_base64_and_png_text(self):
        def png(kind, payload):
            def chunk(t, data):
                return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data))
            return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
                    + chunk(kind, payload) + chunk(b'IEND', b''))
        payload = ('name=' + FAKE_CJK).encode()
        long_payload = ('notes ' * 40 + FAKE_EN + ' end').encode()
        wrapped = base64.b64encode(long_payload).decode()
        cases = {
            'gb18030': ('x ' + FAKE_CJK).encode('gb18030'),
            'big5': ('x ' + FAKE_CJK[0] + chr(0x786f) + chr(0x703e)).encode('big5'),
            'base64': base64.b64encode(payload),
            'base64-inside-word': 'key=abc' + base64.b64encode(payload).decode(),
            'base64-url-safe': base64.urlsafe_b64encode(b'\xfb\xff' + payload).decode(),
            'base64-wrapped': '\n'.join(wrapped[i:i + 64] for i in range(0, len(wrapped), 64)),
            'png-tEXt': png(b'tEXt', b'Author\x00' + FAKE_PROJECT.encode()),
            'png-zTXt': png(b'zTXt', b'Comment\x00\x00' + zlib.compress(FAKE_CJK.encode())),
            'png-iTXt': png(b'iTXt', b'Comment\x00\x01\x00\x00\x00' + zlib.compress(FAKE_EN.encode())),
        }
        for label, data in cases.items():
            folder = tree({'docs/a.' + ('png' if label.startswith('png') else 'txt'): data})
            try:
                report, output = run(folder, terms=TERMS)
                self.assertIn('private-term', rules(report), label)
                self.assertNotIn(FAKE_EN, output)
            finally:
                shutil.rmtree(folder)
        # Long Base64-alphabet runs that hide nothing (hashes, identifiers, random data) stay clean.
        clean = '\n'.join([hashlib.sha256(os.urandom(8)).hexdigest() for _ in range(50)]
                          + [base64.b64encode(os.urandom(300)).decode() for _ in range(50)]
                          + ['requirementsLockfileIdentifier', 'AbstractSingletonProxyFactoryBean'])
        folder = tree({'docs/a.txt': clean})
        try:
            report, _ = run(folder, terms=TERMS)
            self.assertTrue(report['passed'], report['findings'])
        finally:
            shutil.rmtree(folder)
        # PNG metadata gets the generic rules too (a home folder path in an XMP packet).
        folder = tree({'docs/a.png': png(b'iTXt', b'XML:com.adobe.xmp\x00\x00\x00\x00\x00' + (HOME + SOMEONE + '/art.psd').encode())})
        try:
            self.assertIn('private-home-path', rules(run(folder)[0]))
        finally:
            shutil.rmtree(folder)

    def test_nested_archives_are_reported_and_scanned(self):
        def zipped(entries, method=zipfile.ZIP_DEFLATED):
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w', method) as z:
                for name, value in entries.items():
                    z.writestr(name, value)
            return data.getvalue()
        def plist():
            return plistlib.dumps({'CFBundle' + 'Identifier': audit.PUBLIC_BUNDLE_ID})
        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode='w') as t:
            info = tarfile.TarInfo('n.txt'); body = FAKE_EN.encode(); info.size = len(body)
            t.addfile(info, io.BytesIO(body))
        inner_zip = zipped({'n.txt': 'see ' + FAKE_CJK})
        app = 'Desktop Companion.app/Contents/'
        with tempfile.TemporaryDirectory() as folder:
            # zip in zip (release mode)
            outer = Path(folder) / 'release.zip'
            outer.write_bytes(zipped({app + 'Info.plist': plist(), app + 'Resources/extra.zip': inner_zip}))
            report, output = run(outer, mode='zip', terms=TERMS)
            found = {(f['path'], f['rule']) for f in report['findings']}
            self.assertIn((app + 'Resources/extra.zip', 'nested-archive'), found)
            self.assertIn((app + 'Resources/extra.zip!/n.txt', 'private-term'), found)
            self.assertNotIn(FAKE_CJK, output)
            # .gz, .tar.gz and a disguised zip inside an app bundle
            bundle = tree({app + 'Info.plist': plist(), app + 'Resources/data.gz': gzip.compress(FAKE_EN.encode()),
                           app + 'Resources/logs.tgz': gzip.compress(tar.getvalue()),
                           app + 'Resources/blob.bin': inner_zip,
                           app + 'Resources/other.dat': b'7z\xbc\xaf\x27\x1c' + os.urandom(32)})
            try:
                report, _ = run(bundle / 'Desktop Companion.app', mode='app', terms=TERMS)
                found = {(f['path'], f['rule']) for f in report['findings']}
                for path in ('Contents/Resources/data.gz!/data', 'Contents/Resources/logs.tgz!/logs.tar!/n.txt',
                             'Contents/Resources/blob.bin!/n.txt'):
                    self.assertIn((path, 'private-term'), found, path)
                self.assertIn(('Contents/Resources/blob.bin', 'nested-archive'), found)
                self.assertIn(('Contents/Resources/other.dat', 'archive-not-scanned'), found)
            finally:
                shutil.rmtree(bundle)
            # Limits: a compression bomb and deep nesting end quickly with a finding.
            bomb = tree({app + 'Info.plist': plist(),
                         app + 'Resources/bomb.gz': gzip.compress(b'\0' * (audit.MAX_RELEASE_FILE + 1024), 1)})
            deep = inner_zip
            for level in range(audit.MAX_NESTED_DEPTH + 2):
                deep = zipped({f'level{level}.zip': deep}, zipfile.ZIP_STORED)
            try:
                (bomb / app / 'Resources/deep.bin').write_bytes(deep)
                report, _ = run(bomb / 'Desktop Companion.app', mode='app')
                found = rules(report)
                self.assertIn('unexpected-large-file', found)
                self.assertIn('archive-not-scanned', found)
            finally:
                shutil.rmtree(bomb)

    def test_zip_names_written_without_the_utf8_flag(self):
        """ditto stores UTF-8 names without flag 0x800; Python reads them as cp437."""
        real = ('Desktop Companion.app/Contents/Resources/' + FAKE_CJK + '.txt').encode('utf-8')
        placeholder = b'Desktop Companion.app/Contents/Resources/' + b'X' * (len(real) - 45) + b'.txt'
        self.assertEqual(len(placeholder), len(real))
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / 'r.zip'
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr('Desktop Companion.app/Contents/Info.plist', plistlib.dumps({'CFBundle' + 'Identifier': audit.PUBLIC_BUNDLE_ID}))
                z.writestr(placeholder.decode('ascii'), 'ok')
            archive.write_bytes(archive.read_bytes().replace(placeholder, real))    # raw UTF-8 bytes, flag unset
            with zipfile.ZipFile(archive) as z:
                info = z.infolist()[1]
                self.assertFalse(info.flag_bits & 0x800)
                self.assertNotIn(FAKE_CJK, info.filename)
            report, output = run(archive, mode='zip', terms=TERMS)
            self.assertIn('private-term-in-path', rules(report))
            self.assertNotIn(FAKE_CJK, output)
            if shutil.which('ditto'):
                source = Path(folder) / 'src/A.app/Contents'
                source.mkdir(parents=True)
                (source / (FAKE_CJK + '.txt')).write_text('ok')
                (source / 'Info.plist').write_bytes(plistlib.dumps({'CFBundle' + 'Identifier': audit.PUBLIC_BUNDLE_ID}))
                made = Path(folder) / 'ditto.zip'
                subprocess.run(['ditto', '-c', '-k', '--keepParent', str(source.parent), str(made)], check=True)
                self.assertIn('private-term-in-path', rules(run(made, mode='zip', terms=TERMS)[0]))

    def test_private_path_is_withheld_from_every_rule_and_the_manifest(self):
        files = {'docs/' + FAKE_PROJECT + '.wav': b'RIFF\x00\x00\x00\x00WAVEfmt ' + os.urandom(32),
                 'docs/' + FAKE_EN + '/.DS_Store': b'x', 'docs/' + FAKE_CJK + '/notes.log': 'mail=' + SOMEONE + '@' + 'example.com'}
        folder = tree(files)
        try:
            with tempfile.TemporaryDirectory() as out:
                report_path = Path(out) / 'report.json'
                report, output = run(folder, terms=TERMS, extra=['--json', str(report_path)])
                saved = report_path.read_text(encoding='utf-8')
            self.assertTrue({'private-term-in-path', 'excluded-artifact', 'audio-content',
                             'local-metadata-or-environment', 'email-address'} <= rules(report))
            for text in (output, saved):
                for term in TERMS:
                    self.assertNotIn(term, text)
            shown = {f['path'] for f in report['findings']}
            self.assertTrue(all(p.startswith('<path withheld #') for p in shown), shown)
            self.assertEqual(len(shown), 3)
        finally:
            shutil.rmtree(folder)

    @unittest.skipUnless(shutil.which('git'), 'git is not installed')
    def test_history_waives_path_rules_only_for_listed_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder) / 'repo'
            repo.mkdir()
            env = {**os.environ, 'GIT_AUTHOR_NAME': 't', 'GIT_COMMITTER_NAME': 't',
                   'GIT_AUTHOR_EMAIL': 'user' + '@' + 'example.com', 'GIT_COMMITTER_EMAIL': 'user' + '@' + 'example.com',
                   'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
            def git(*args):
                return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, env=env, text=True).stdout.strip()
            git('init', '-q')
            (repo / 'old.log').write_text('kept\n')
            git('add', '-A'); git('commit', '-q', '-m', 'one')
            blob = git('rev-parse', 'HEAD:old.log')
            git('rm', '-q', 'old.log'); git('commit', '-q', '-m', 'two')
            accepted = Path(folder) / 'accepted.json'
            accepted.write_text(json.dumps({'accepted': [{'blob': blob, 'rules': ['excluded-artifact'], 'paths': ['old.log']}]}))
            self.assertTrue(run(repo, mode='history', extra=['--accepted', str(accepted)])[0]['passed'])
            # The same bytes under another forbidden name are not covered by that entry.
            (repo / 'again.log').write_text('kept\n')
            git('add', '-A'); git('commit', '-q', '-m', 'three')
            report, _ = run(repo, mode='history', extra=['--accepted', str(accepted)])
            self.assertEqual({(f['path'], f['rule']) for f in report['findings']}, {('again.log', 'excluded-artifact')})

    def test_audit_tooling_passes_its_own_audit(self):
        files = {name: (ROOT / name).read_bytes() for name in
                 ('scripts/audit_release.py', 'scripts/audit-history-accepted.json', 'scripts/tests/test_audit_release.py')}
        folder = tree(files)
        try:
            report, _ = run(folder)
            self.assertTrue(report['passed'], report['findings'])
        finally:
            shutil.rmtree(folder)


if __name__ == '__main__':
    unittest.main()
