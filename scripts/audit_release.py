#!/usr/bin/env python3
"""Targeted release-content audit. This is not a vulnerability scanner.

Read-only: it never extracts archives or prints matched secret contents.
Source mode skips build output; audit the final app/ZIP separately.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile

SOURCE_SKIP = {'.git', 'build', 'dist', '__pycache__', '.pytest_cache', '.venv'}
FORBIDDEN_COMPONENTS = {
    'reference', 'references', 'preview', 'previews', 'private', 'local-assets',
    'qa', '.qa', '.model-test', 'python-base', 'site-packages', 'venv',
}
FORBIDDEN_SUFFIXES = {
    '.safetensors', '.gguf', '.onnx', '.aiff', '.aif', '.wav', '.m4a',
    '.pem', '.key', '.mobileprovision', '.pyc', '.pyo', '.log',
}
# Recognizable pre-publication assets must not re-enter a release.
FORBIDDEN_ASSETS = {'Idle.png', 'Blink.png', 'Blueberry.png', 'VoiceSample.aiff',
                    'AssetManifest.json', 'python-runtime-provenance.json'}
SOURCE_TOP = {'app', 'chat', 'scripts', 'tests', 'docs', '.github'}
SOURCE_ROOT_FILES = {
    'README.md', 'README.zh-CN.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'SECURITY.md', 'CONTRIBUTING.md', '.gitignore', '.gitattributes',
    'CHANGELOG.md', 'VERSION',
}
PATTERNS = [
    ('private-home-path', re.compile(rb'/(?:Users|home)/[A-Za-z0-9][^/\s\x00"\'<>]{1,80}/')),
    ('private-key', re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')),
    ('github-token', re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{50,255})')),
    ('aws-access-key', re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('api-secret', re.compile(rb'\bsk-(?:proj-)?[A-Za-z0-9_-]{40,255}\b')),
    ('legacy-bundle-id', re.compile(rb'local\.' + b'makoto')),
    ('legacy-public-art-brand', re.compile(('结' + '城理|蓝' + '莓理|ATL' + 'US|SE' + 'GA').encode())),
]
MAX_SOURCE_FILE = 8 * 1024 * 1024
MAX_RELEASE_FILE = 64 * 1024 * 1024
MAX_ARCHIVE_TOTAL = 256 * 1024 * 1024


class Audit:
    def __init__(self, mode: str, deny_terms: list[str]):
        self.mode = mode
        self.deny = [(f'explicit-private-term-{i + 1}', s.encode())
                     for i, s in enumerate(deny_terms) if s]
        self.findings: list[dict[str, str]] = []
        self.manifest: list[dict[str, object]] = []

    def flag(self, name: str, rule: str) -> None:
        item = {'path': name, 'rule': rule}
        if item not in self.findings:
            self.findings.append(item)

    def name(self, name: str) -> bool:
        path = PurePosixPath(name)
        parts = path.parts
        if path.is_absolute() or '..' in parts or '\\' in name:
            self.flag(name, 'unsafe-path')
            return False
        if any(p in FORBIDDEN_COMPONENTS for p in parts):
            self.flag(name, 'excluded-directory')
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name in FORBIDDEN_ASSETS:
            self.flag(name, 'excluded-artifact')
        if path.name == '.DS_Store' or path.name == '.env' or path.name.startswith('.env.'):
            self.flag(name, 'local-metadata-or-environment')
        if self.mode == 'source':
            if len(parts) == 1 and parts[0] not in SOURCE_ROOT_FILES:
                self.flag(name, 'unlisted-root-file')
            if len(parts) > 1 and parts[0] not in SOURCE_TOP:
                self.flag(name, 'unlisted-source-directory')
            if path.suffix.lower() in {'.zip', '.dmg', '.gz', '.dylib', '.so'} or any(p.endswith('.app') for p in parts):
                self.flag(name, 'binary-or-archive-in-source')
        return True

    def content(self, name: str, data: bytes) -> None:
        self.manifest.append({'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        for label, pattern in PATTERNS:
            if pattern.search(data):
                self.flag(name, label)
        for label, value in self.deny:
            if value in data:
                self.flag(name, label)

    def tree(self, root: Path) -> None:
        for directory, dirs, files in os.walk(root, followlinks=False):
            current = Path(directory)
            # Filtering output is source-specific, not a way to hide runtime from an app audit.
            dirs[:] = sorted(d for d in dirs if not (self.mode == 'source' and d in SOURCE_SKIP))
            for d in list(dirs):
                path = current / d
                if path.is_symlink():
                    self.link(root, path)
                    dirs.remove(d)
            for filename in sorted(files):
                path = current / filename
                name = path.relative_to(root).as_posix()
                if path.is_symlink():
                    self.link(root, path)
                    continue
                if not self.name(name):
                    continue
                if not path.is_file():
                    self.flag(name, 'non-regular-file')
                    continue
                size = path.stat().st_size
                limit = MAX_SOURCE_FILE if self.mode == 'source' else MAX_RELEASE_FILE
                if size > limit:
                    self.flag(name, 'unexpected-large-file')
                    continue
                self.content(name, path.read_bytes())

    def link(self, root: Path, path: Path) -> None:
        name = path.relative_to(root).as_posix()
        self.name(name)
        target = os.readlink(path)
        if os.path.isabs(target):
            self.flag(name, 'absolute-symlink')
            return
        try:
            path.resolve(strict=True).relative_to(root.resolve())
        except (ValueError, OSError, RuntimeError):
            self.flag(name, 'external-or-broken-symlink')

    def archive(self, path: Path) -> None:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if sum(e.file_size for e in entries) > MAX_ARCHIVE_TOTAL:
                self.flag(path.name, 'unexpected-large-archive')
                return
            seen = set()
            for entry in entries:
                if entry.is_dir():
                    continue
                name = entry.filename
                if name in seen:
                    self.flag(name, 'duplicate-archive-entry')
                seen.add(name)
                if not self.name(name):
                    continue
                if entry.flag_bits & 1:
                    self.flag(name, 'encrypted-archive-entry')
                    continue
                if entry.file_size > MAX_RELEASE_FILE:
                    self.flag(name, 'unexpected-large-file')
                    continue
                data = archive.read(entry)
                if stat.S_ISLNK(entry.external_attr >> 16):
                    target = data.decode('utf-8', errors='replace')
                    resolved = PurePosixPath(name).parent / target
                    if target.startswith('/') or '..' in resolved.parts:
                        self.flag(name, 'unsafe-archive-symlink')
                self.content(name, data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--mode', choices=('source', 'app', 'zip'), required=True)
    parser.add_argument('--deny-term', action='append', default=[], help='Private local text to reject; never echoed.')
    parser.add_argument('--json', type=Path, help='Optional report path, preferably outside the source tree.')
    args = parser.parse_args()
    audit = Audit(args.mode, args.deny_term)
    if args.mode == 'zip':
        audit.archive(args.path)
    elif args.path.is_dir():
        audit.tree(args.path)
    else:
        parser.error('Expected a directory for source/app mode.')
    result = {'schema': 1, 'mode': args.mode, 'passed': not audit.findings,
              'files_checked': len(audit.manifest),
              'bytes_checked': sum(int(f['bytes']) for f in audit.manifest),
              'findings': audit.findings, 'manifest': audit.manifest,
              'limits': 'Targeted content checks only; not a full privacy, vulnerability, or license audit.'}
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'manifest'}, ensure_ascii=False, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
