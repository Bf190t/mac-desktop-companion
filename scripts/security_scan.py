#!/usr/bin/env python3
"""Offline static security scan for a code base (stdlib only, read-only, Python 3.9+).

Rule ideas adapted from DeepSec Shield (Unclecheng-li/DeepSec, MIT licence; formerly VibeGuard) and
rewritten from scratch - no DeepSec code is included or run. See THIRD_PARTY_NOTICES.md.

Layers
  L1  text rules: secret prefixes, sensitive assignments with a Shannon-entropy test, insecure configuration,
      typical "AI-written code" mistakes, risky front-end sinks (innerHTML, eval), risky calls in Swift apps
      (TLS overrides, spawning processes, web views, opening URLs, Markdown rendering, plain http, logged secrets,
      unsafe unarchiving).
  L2  Python AST: shell commands / string commands, eval/exec/pickle/yaml.load, SQL built from interpolated
      strings (also via a variable), TLS verification off, outbound requests carrying environment secrets,
      commands built from prompt/message text, archive extraction.
  SC  supply chain: imports that resolve to nothing installed ("hallucinated package"), unpinned dependencies,
      extra package indexes, package.json without a lock file.

Secrets never leave the scan: every evidence / source text is scrubbed (all secret patterns, sensitive assignment
values quoted or not, user:password@ in URLs, bearer tokens, passwords given to command-line tools, and - as a last,
heuristic layer - base64 runs and long tokens that look random) before it is printed, written as JSON or stored in
the baseline. A whole text is scrubbed BEFORE it is cut to length, so a cut never leaves half a secret behind, and
fingerprints are hashed from scrubbed text only. Known limits: a secret with no telling name, no known prefix and no
random look (or split into short pieces, e.g. "abc" "def") can still show up in the source line of another finding;
under a sensitive name, letters-only pass phrases, digits-only PINs and values containing "(" are left alone (too
much ordinary code looks like that); the random-look layer misses a small share of random strings; file names are
printed as they are.

Run it with the PROJECT'S OWN interpreter: results depend on the Python version (syntax the interpreter cannot
parse, standard-library module names, installed packages). The baseline records the version and the scan warns
when it differs.

Findings a human reviewed live in a baseline file (default: <root>/.security-scan-baseline.json) as fingerprints
with the reason they are fine. An entry whose reason is empty, null or starts with "TODO" does NOT count.

Exit codes: 0 nothing unreviewed - 1 unreviewed findings - 2 bad arguments (missing root / --dirs) - 3 internal
error (unreadable baseline, crash).

usage:
  python security_scan.py --root PROJECT [--dirs src web] [--include-tests] [--json] [--all]
  python security_scan.py --root PROJECT --write-baseline      # then fill in every "reason"
"""
from __future__ import annotations

import argparse
import ast
import bisect
import codecs
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys

BASELINE_NAME = '.security-scan-baseline.json'
SEVERITY = ('critical', 'high', 'medium', 'low')
CODE_SUFFIXES = {'.py', '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.vue', '.svelte', '.html', '.htm', '.sh',
                 '.command', '.swift'}
TEXT_SUFFIXES = CODE_SUFFIXES | {'.json', '.toml', '.txt', '.md', '.yaml', '.yml', '.ini', '.cfg', '.env', '.plist', '.xcconfig',
                                 '.conf', '.properties'}
# Never useful to scan.
SKIP_DIRS = {'.git', '.hg', '.svn', '.venv', 'venv', 'env', 'node_modules', '__pycache__', 'dist', 'build', '.tox',
             '.mypy_cache', '.pytest_cache', '.ruff_cache', 'site-packages', '.idea', '.vscode', 'coverage', '.next',
             '.cache', '.nuxt'}
# Usually data: only code files inside them are scanned.
DATA_DIRS = {'data', 'runtime', 'logs', 'backups', 'exports', 'reports', 'outbox'}
TEST_DIRS = {'tests', 'test', '__tests__', 'spec'}
JS_SUFFIXES = ('.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.vue', '.svelte')

# ------------------------------------------------------------------ L1: secrets
SECRET_RULES = (
    ('secret_aws_key', r'\bA(?:KIA|SIA)[0-9A-Z]{16}\b'),
    ('secret_github_token', r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{30,255}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b'),
    ('secret_slack_token', r'\bxox[baprs]-[A-Za-z0-9-]{20,}\b'),
    ('secret_google_key', r'\bAIza[0-9A-Za-z_-]{35}\b'),
    ('secret_anthropic_key', r'\bsk-ant-[A-Za-z0-9_-]{32,}\b'),
    ('secret_openai_style_key', r'\bsk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{32,}\b'),      # many LLM vendors use this shape
    ('secret_stripe_key', r'\b(?:sk|rk)_live_[A-Za-z0-9]{20,}\b'),
    ('secret_jwt', r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'),
    ('secret_private_key', r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ED25519 |PGP )?PRIVATE KEY-----'),
    ('secret_url_password', r'\b[A-Za-z][A-Za-z0-9+.-]{1,20}://[^:\s/@\'"]+:[^@\s\'"/]{3,}@[^)\s\'"]+'),
)
# Name parts are bounded ({0,64}): unbounded ones made a long run like _key_key_key… take quadratic time.
# Explicit look-arounds instead of \b: \b is Unicode-aware, so 签名_key had no boundary before "_key".
_NAME_PART = r'[A-Za-z0-9_]{0,64}'
SENSITIVE_NAME = (_NAME_PART + r'(?:api[_-]?key|secret|password|passwd|token|private[_-]?key|client[_-]?secret|'
                  r'access[_-]?key|credential|_key)' + _NAME_PART)
_NAME = r'(?<![A-Za-z0-9_])(' + SENSITIVE_NAME + r')(?![A-Za-z0-9_])'
# let apiKey: String? = …   const k: string | undefined = …   SIGNING_KEY: Final[str] = …
_TYPE = (r'(?:\s*:\s*[A-Za-z_][\w.]{0,80}(?:<[^>\n]{0,80}>|\[[^\]\n]{0,80}\])?[?!]?'
         r'(?:\s*\|\s*[A-Za-z_][\w.]{0,40}(?:\[[^\]\n]{0,40}\])?){0,3})?')
_PREFIX = r'(?:[bBrRuU]{1,2}|#)'                                    # b"…"  rb"…"  Swift #"…"#
SENSITIVE_ASSIGNMENT = re.compile(
    _NAME + r'[\'"]?' + _TYPE + r'\s*[:=]\s*' + _PREFIX + r'?([\'"`])((?:\\.|(?!\2).){12,})\2', re.I)
PLACEHOLDERS = {'changeme', 'change-me', 'example', 'sample', 'placeholder', 'your-key', 'your-api-key', 'your-secret',
                'your-token', 'test', 'test-key', 'dummy', 'fake', 'todo', 'redacted', 'xxx', 'none', 'null'}
# Extra scrubbing (never reported on their own): credentials in URLs, bearer tokens, key=value secrets.
SCRUB_EXTRA = (
    re.compile(r'(?<=://)([^:\s/@\'"]*):([^\s\'"/]*)@'),     # user:pass@ (pass may contain @), token:@, :pass@
    re.compile(r'(?<=://)([A-Za-z0-9_\-]{20,})@'),                              # https://<token>@host
    re.compile(r'(?i)(bearer|token|basic)(\s+)([A-Za-z0-9._~+/=-]{12,})'),
    re.compile(r'(?i)((?:api[_-]?key|secret|password|passwd|pwd|token|access[_-]?key|auth)[\'"]?\s*[:=]\s*[\'"]?)'
               r'([^\'"\s,;}&)]{6,})'),
)
# Passwords given to command-line tools, as a shell string or as an argv list ('-p', 'xxx'). A value right before a
# quote is taken up to that quote (it may contain ")" or ","); $VAR, %VAR%, {var} are references, not secrets.
_SEP = r'(?:\s+|[\'"]\s*,\s*[\'"])'
_ARG = r'(?![$%{])([^\s\'"`]{4,}(?=[\'"`])|[^\s\'"`,)\]]{4,})'
CLI_SECRETS = tuple(re.compile(p + _ARG) for p in (
    r'(\bsshpass(?:' + _SEP + r'-[A-Za-oq-z]\b)*' + _SEP + r'-p' + _SEP + r'?[\'"]?)',          # sshpass [-v] -p X
    r'(\bSSHPASS=[\'"]?)',
    r'(\b(?:mysql|mysqldump|mysqladmin|mariadb)\b[^\n]{0,200}?' + _SEP + r'-p[\'"]?)',    # -pPASSWORD (attached)
    r'(\bredis-cli\b[^\n]{0,200}?' + _SEP + r'-a' + _SEP + r'[\'"]?)',
    r'(\bcurl\b[^\n]{0,300}?' + _SEP + r'(?:-[A-Za-z]*u|--user)' + _SEP + r'?[\'"]?[^\s:\'"]*:)',   # -u / -su user:X
    r'(\bopenssl\b[^\n]{0,200}?' + _SEP + r'-k' + _SEP + r'[\'"]?)',
    r'(-pass(?:in|out|word)?' + _SEP + r'[\'"]?pass:)',
    r'(\b(?:(?:docker|podman|helm)' + _SEP + r'(?:registry' + _SEP + r')?login|mongo|mongosh|mongodump|mongorestore)\b'
    r'[^\n]{0,200}?' + _SEP + r'-p' + _SEP + r'[\'"]?)',
    r'(\b(?:sqlcmd|bcp)\b[^\n]{0,200}?' + _SEP + r'-P' + _SEP + r'[\'"]?)',
    r'(\bldap\w*\b[^\n]{0,200}?' + _SEP + r'-w' + _SEP + r'[\'"]?)',
    r'(\bsmbclient\b[^\n]{0,200}?' + _SEP + r'-U' + _SEP + r'[\'"]?[^\s%\'"]+%)',          # -U user%X
    r'(\bhtpasswd\b' + _SEP + r'-\w*b\w*' + _SEP + r'\S+' + _SEP + r'\S+' + _SEP + r'[\'"]?)',  # -b file user X
    r'(--[\w-]{0,30}?(?:password|passwd|pass|pwd|token|secret|api[_-]?key|access[_-]?key|credential|auth|'
    r'(?:secret|signing|master|encryption|license)[_-]?key)(?:=|' + _SEP + r')[\'"]?)',
))
# Last-resort scrubbing, so a value cannot slip out because a rule formats its evidence differently ("name = value",
# no quotes), a string spans several lines, or a .env line is unquoted: every sensitive name from SENSITIVE_ASSIGNMENT
# with an unquoted value that could be a secret, base64 runs (they contain "/" and "+", which split other tokens), and
# any long token that reads like a key or digest. This last layer is a heuristic: it catches most random strings, not
# all of them (see _looks_random).
SENSITIVE_BARE = re.compile(_NAME + r'([\'"]?' + _TYPE + r'\s*[:=]\s*(?:' + _PREFIX + r'(?=[\'"`]))?[\'"`]?)'
                            r'([^\s\'"`,;}&)\]]{8,})', re.I)
BASE64_RUN = re.compile(r'(?:[A-Za-z0-9+/]|\\n){20,}={0,2}')       # \n: a PEM body written inside a JSON / JS string
# session ids cut into short parts by "."; the look-behind starts a match only at the start of a part (a long part
# without dots would otherwise cost quadratic time). It may start right after a dot, so v1.<part>.<part> is caught too.
DOTTED_RUN = re.compile(r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]{4,})+')
RANDOM_TOKEN = re.compile(r'[A-Za-z0-9_+-]{20,}={0,2}')             # "=" only as padding: NAME=value stays two tokens

# ------------------------------------------------------------------ L1: configuration / AI-code patterns
TEXT_RULES = (
    ('high', 'config_debug_true', r'\b(?:DEBUG|debug)\s*=\s*True\b|app\.run\([^)]*debug\s*=\s*True', ('.py',)),
    ('high', 'config_cors_wildcard', r'allow_origins\s*=\s*\[\s*[\'"]\*[\'"]|Access-Control-Allow-Origin[\'"]?\s*[:,]\s*[\'"]\*[\'"]|origin\s*:\s*[\'"]\*[\'"]', None),
    ('high', 'config_tls_off', r'\bverify\s*=\s*False\b|CERT_NONE|check_hostname\s*=\s*False|NODE_TLS_REJECT_UNAUTHORIZED|rejectUnauthorized\s*:\s*false', ('.py',) + JS_SUFFIXES),
    ('high', 'config_bind_all', r'host\s*=\s*[\'"]0\.0\.0\.0[\'"]|--host[\'"]?\s*,\s*[\'"]0\.0\.0\.0|listen\(\s*\d+\s*,\s*[\'"]0\.0\.0\.0', ('.py', '.plist', '.command', '.sh') + JS_SUFFIXES),
    ('medium', 'config_cookie_insecure', r'(?i)\bhttponly\s*=\s*False|\bsecure\s*=\s*False|\bsamesite\s*=\s*[\'"]?none', ('.py',)),
    ('high', 'ai_default_password', r'\b(?:password|passwd|pwd)\s*[:=]\s*[\'"](?:admin|password|123456|12345678|changeme|root)[\'"]', None),
    ('high', 'ai_weak_random_token', r'\b(?:token|secret|key|nonce|csrf|otp|session)\w*\s*=\s*(?:random\.(?:random|randint|choice|getrandbits)|Math\.random)\s*\(', ('.py',) + JS_SUFFIXES),
    ('medium', 'ai_weak_hash_secret', r'hashlib\.(?:md5|sha1)\s*\([^)\n]*(?:password|secret|token|key)', ('.py',)),
    ('high', 'web_inner_html', r'\.(?:innerHTML|outerHTML)\s*[+]?=|insertAdjacentHTML\s*\(|document\.write\s*\(|dangerouslySetInnerHTML|\bv-html\s*=', JS_SUFFIXES + ('.html', '.htm')),
    ('high', 'web_eval_js', r'(?<![.\w])(?:eval|Function)\s*\(|setTimeout\s*\(\s*[\'"`]|setInterval\s*\(\s*[\'"`]', JS_SUFFIXES + ('.html', '.htm')),
    ('medium', 'web_target_blank', r'target\s*=\s*[\'"]_blank[\'"](?![^>]*noopener)', ('.html', '.htm', '.jsx', '.tsx', '.vue', '.svelte')),
    ('high', 'template_autoescape_off', r'autoescape\s*=\s*False|\|\s*safe\b|Markup\s*\(', ('.py', '.html', '.htm')),
    # Native macOS / iOS apps (Swift): common risky calls. Every hit needs a human look; review each one and write the reason
    # into the baseline (from a real review of a Swift app, 2026-11-19).
    ('high', 'swift_tls_override', r'serverTrust|\.useCredential\b|URLAuthenticationChallenge|NSAllowsArbitraryLoads|allowsExpiredCertificates|SecTrustSetExceptions', ('.swift', '.py', '.plist')),
    ('high', 'swift_spawn_process', r'\bProcess\(\)|\bNSTask\b|posix_spawn|(?<![.\w])system\(|NSAppleScript|\bdlopen\(', ('.swift',)),
    ('high', 'swift_web_view', r'\bWKWebView\b|evaluateJavaScript|loadHTMLString', ('.swift',)),
    ('medium', 'swift_open_external_url', r'NSWorkspace\.shared\.open\(|\bopenURL\(|\.openURL\b|Link\(destination:', ('.swift',)),
    ('medium', 'swift_markdown_render', r'AttributedString\(markdown:|NSAttributedString\(markdown:', ('.swift',)),
    ('medium', 'swift_plain_http', r'"http://(?!127\.0\.0\.1|localhost|\[::1\])[^"\s]+', ('.swift',)),
    ('medium', 'swift_log_secret', r'(?:\bprint|\bNSLog|\bos_log|\bdebugPrint|logger\.\w+)\([^)\n]{0,300}(?i:apikey|api_key|accesskey|access_key|secret|token|cookie|password|credential)', ('.swift',)),
    ('medium', 'swift_unsafe_unarchive', r'NSKeyedUnarchiver\.unarchiveObject|unarchiveTopLevelObjectWithData|PropertyListSerialization\.propertyList\(from:', ('.swift',)),
)

# ------------------------------------------------------------------ L2 / agent rules on the Python AST
COMMAND_SINKS = {('subprocess', 'getoutput'), ('subprocess', 'getstatusoutput'), ('subprocess', 'run'), ('subprocess', 'Popen'),
                 ('subprocess', 'call'), ('subprocess', 'check_call'), ('subprocess', 'check_output'), ('os', 'system'),
                 ('os', 'popen'), ('asyncio', 'create_subprocess_shell')}
ALWAYS_SHELL = {('os', 'system'), ('os', 'popen'), ('asyncio', 'create_subprocess_shell'), ('subprocess', 'getoutput'),
                ('subprocess', 'getstatusoutput')}
SQL_METHODS = {'execute', 'executemany', 'executescript', 'raw'}
HTTP_SINKS = {'get', 'post', 'put', 'patch', 'delete', 'request', 'stream', 'urlopen', 'send'}
AGENT_WORDS = re.compile(r'(?<![A-Za-z])(?:prompt|message|question|user_text|reply|answer|completion|llm_output|tool_input)(?![a-z])', re.I)


def _redact(value):
    value = str(value)
    return '***' if len(value) <= 8 else value[:4] + '…'


def _looks_random(token):
    """A long token that reads like a key or a digest, not like a word or an identifier (CamelCase, snake_case).
    Heuristic: misses roughly 1 in 12 random 20-character base62 tokens, about 1 in 70 of 32 characters, about 1 in
    6 base32 and 1 in 12 base36 tokens of 24+ characters, and one-case tokens under 24 characters - the named and
    prefixed rules above are what the guarantee rests on."""
    core = re.sub(r'[_+=/-]', '', token)
    if len(core) < 16:
        return False
    if re.fullmatch(r'[0-9a-fA-F]+', core):                  # hex keys and digests
        digits = sum(c.isdigit() for c in core) / len(core)
        return len(core) >= 20 and 0.15 <= digits <= 0.85
    upper, lower, digit = (bool(re.search(p, core)) for p in (r'[A-Z]', r'[a-z]', r'\d'))
    kinds = ['U' if c.isupper() else 'L' if c.islower() else 'D' for c in core]
    switches = sum(a != b for a, b in zip(kinds, kinds[1:])) / (len(core) - 1)
    words = sum(len(m.group(0)) for m in re.finditer(r'[A-Za-z][a-z]{2,}', core)) / len(core)
    runs = [len(m.group(0)) for m in re.finditer(r'[a-z]+', core)] or [0]
    share = sum(c.isdigit() for c in core) / len(core)
    if upper and lower and digit:                            # base62 / base64
        return switches >= 0.3 and words < 0.6
    if upper and lower:                                      # letters only: must be long and very mixed
        return len(core) >= 24 and switches >= 0.4 and words < 0.5 and max(runs) <= 4
    if upper and digit:                                      # base32 (TOTP seeds and the like)
        return len(core) >= 24 and 0.1 <= share <= 0.75 and switches >= 0.2
    if lower and digit:                                      # base36
        return len(core) >= 24 and 0.1 <= share <= 0.75 and switches >= 0.2 and sum(runs) / len(runs) <= 5.5
    return False


def _bare_secret(value):
    """An unquoted (or unterminated) value under a sensitive name that could be a secret."""
    if _looks_like_code(value) or value.lower() in PLACEHOLDERS:
        return False
    if len(value) >= 16 and _entropy(value) >= 3.0:
        return True
    # a letter plus a digit or a symbol; a plain name (cache_key) is not a secret. Letters-only pass phrases and
    # digits-only PINs are let through on purpose (too much code looks like that) - a known limit.
    return bool(re.search(r'[A-Za-z]', value) and re.search(r'[^A-Za-z_]', value))


def _base64_secret(run):
    """A base64 run with "/" or "+" that looks random as a whole. A run that starts with a plain lowercase word is
    a path (item/<hash>): left to RANDOM_TOKEN, which judges each part on its own."""
    if not re.search(r'[/+]', run) or re.match(r'/?[a-z]{3,}(?:/|$)', run):
        return False
    return _looks_random(run.replace('\\n', ''))


def _looks_like_code(value):
    """func(…  x[…  $VAR  ${…}  %(…)  a path  module.attr.attr  cfg.CONST : an expression or a reference, not a secret."""
    return bool(re.match(r'[A-Za-z_][\w.]*[(\[]|\$|%\(|\{|\.{0,2}/|~/', value)
                or re.fullmatch(r'[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)+|[A-Za-z_]\w*\.[A-Z_][A-Z0-9_]*', value))


def _url_userinfo(m):
    return m.group(1) + ':***@' if m.group(2) else _redact(m.group(1)) + ':@'     # token:@host - the user IS the key


def _scrub(text):
    """Remove every secret-looking value from a text that will be printed or stored."""
    text = str(text or '')
    for _rule, pattern in SECRET_RULES:
        text = re.sub(pattern, lambda m: _redact(m.group(0)), text)
    text = SENSITIVE_ASSIGNMENT.sub(lambda m: m.group(0).replace(m.group(3), _redact(m.group(3))), text)
    text = SCRUB_EXTRA[0].sub(_url_userinfo, text)
    text = SCRUB_EXTRA[1].sub('***@', text)
    text = SCRUB_EXTRA[2].sub(lambda m: m.group(1) + m.group(2) + _redact(m.group(3)), text)
    text = SCRUB_EXTRA[3].sub(lambda m: m.group(1) + _redact(m.group(2)), text)
    for pattern in CLI_SECRETS:
        text = pattern.sub(lambda m: m.group(1) + _redact(m.group(2)), text)
    text = SENSITIVE_BARE.sub(lambda m: m.group(1) + m.group(2) + _redact(m.group(3))
                              if _bare_secret(m.group(3)) else m.group(0), text)
    text = BASE64_RUN.sub(lambda m: _redact(m.group(0)) if _base64_secret(m.group(0)) else m.group(0), text)
    text = DOTTED_RUN.sub(lambda m: _redact(m.group(0)) if _looks_random(m.group(0).replace('.', '')) else m.group(0),
                          text)
    text = RANDOM_TOKEN.sub(lambda m: _redact(m.group(0)) if _looks_random(m.group(0)) else m.group(0), text)
    return text


def _clip(text, limit):
    """Scrub the WHOLE text first, cut afterwards. Cutting first (even with a margin) can leave half a secret that no
    pattern recognises any more - and scrubbing shortens the text, which pulls that half into the kept part."""
    return _scrub(text)[:limit]


def _entropy(value):
    if len(value) < 16 or re.search(r'\s', value) or not re.search(r'[A-Za-z]', value) or not re.search(r'\d', value):
        return 0.0
    return -sum((n / len(value)) * math.log2(n / len(value)) for n in (value.count(c) for c in set(value)))


def _norm(line):
    return _clip(re.sub(r'\s+', ' ', line.strip()), 240)


def _source_of(lines):
    """line number -> normalised, scrubbed source line; each line is scrubbed once even with many findings on it."""
    cache = {}

    def src(line):
        if line not in cache:
            cache[line] = _norm(lines[line - 1] if 0 < line <= len(lines) else '')
        return cache[line]
    return src


def _lines(text):
    """Split on \\n only (splitlines() also splits on form feeds etc. and shifts line numbers)."""
    return [line.rstrip('\r') for line in text.split('\n')]


class Finding(dict):
    def fingerprint(self):
        if self.get('fp_key'):
            raw = f"{self['rule']}|{self['fp_key']}"
        else:
            raw = f"{self['rule']}|{self['file']}|{self['source']}|{self.get('expression', '')}|{self['occurrence']}"
        return hashlib.sha256(raw.encode()).hexdigest()[:16]


def read_text(path):
    """utf-8 (with or without BOM), utf-16 with BOM; None when unreadable or binary."""
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if raw.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        try:
            return raw.decode('utf-16')
        except UnicodeDecodeError:
            return None
    try:
        return raw.decode('utf-8-sig')
    except UnicodeDecodeError:
        return None


def scan_text(path, rel, text, findings):
    lines = _lines(text)
    suffix = '.env' if path.name.startswith('.env') or path.name.endswith('.env') else path.suffix.lower()

    newlines = [i for i, ch in enumerate(text) if ch == '\n']

    def line_of(pos):
        return bisect.bisect_left(newlines, pos) + 1

    src = _source_of(lines)

    for rule, pattern in SECRET_RULES:
        for match in re.finditer(pattern, text):
            line = line_of(match.start())
            findings.append(Finding(severity='critical', rule=rule, file=rel, line=line, evidence=_redact(match.group(0)),
                                    source=src(line)))
    for match in SENSITIVE_ASSIGNMENT.finditer(text):
        value = match.group(3)
        line_no = line_of(match.start())
        source = lines[line_no - 1] if line_no <= len(lines) else ''
        if value.strip().lower().replace(' ', '-') in PLACEHOLDERS or re.search(r'os\.getenv|os\.environ|process\.env', source):
            continue
        if _entropy(value) >= 3.8:
            findings.append(Finding(severity='critical', rule='secret_high_entropy_literal', file=rel, line=line_no,
                                    evidence=f'{match.group(1)} = {_redact(value)}', source=src(line_no)))
    for severity, rule, pattern, suffixes in TEXT_RULES:
        if suffixes and suffix not in suffixes:
            continue
        for match in re.finditer(pattern, text):
            line = line_of(match.start())
            findings.append(Finding(severity=severity, rule=rule, file=rel, line=line, evidence=_clip(match.group(0), 80),
                                    source=src(line)))


def _dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return tuple(reversed(parts))


def _argv_list(node):
    """[...] + [...]: an argv list built from parts, not a shell string."""
    if isinstance(node, (ast.List, ast.Tuple)):
        return True
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _argv_list(node.left) or _argv_list(node.right)
    return False


def _is_dynamic_string(node):
    """f-string with expressions, '...' % x, '...'.format(...), or '...' + x."""
    if isinstance(node, ast.JoinedStr):
        return any(isinstance(v, ast.FormattedValue) for v in node.values)
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Mod, ast.Add)):
        return not (isinstance(node.left, ast.Constant) and isinstance(node.right, ast.Constant))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'format':
        return True
    return False


def _interpolated(node):
    if isinstance(node, ast.JoinedStr):
        return sorted({_clip(ast.unparse(v.value), 60) for v in node.values if isinstance(v, ast.FormattedValue)})
    return [_clip(ast.unparse(node), 80)]


def scan_python(rel, text, findings):
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError) as exc:       # ValueError: NUL bytes on 3.9
        message = str(getattr(exc, 'msg', exc)).split('Did you mean')[0].strip()
        findings.append(Finding(severity='low', rule='python_parse_error', file=rel, line=getattr(exc, 'lineno', 0) or 0,
                                evidence=_clip(message, 80) + f'（这个 Python {sys.version_info[0]}.{sys.version_info[1]} '
                                         '解析不了，文件里的代码没有做 AST 检查）', source=''))
        return
    src = _source_of(_lines(text))

    def add(severity, rule, node, evidence, limit=160):
        """evidence is passed uncut: _clip scrubs it first and only then cuts it to `limit`."""
        line = getattr(node, 'lineno', 0)
        # any change to the call is new; hashed AFTER scrubbing, or the id would let anyone test guesses of a secret
        expression = hashlib.sha256(_scrub(ast.unparse(node)).encode()).hexdigest()[:16]
        findings.append(Finding(severity=severity, rule=rule, file=rel, line=line, evidence=_clip(evidence, limit),
                                expression=expression, source=src(line)))

    dynamic_names, imported, aliases = set(), {}, {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and _is_dynamic_string(node.value):
            dynamic_names |= {t.id for t in node.targets if isinstance(t, ast.Name)}
        if isinstance(node, ast.AnnAssign) and node.value is not None and _is_dynamic_string(node.value) \
                and isinstance(node.target, ast.Name):
            dynamic_names.add(node.target.id)
        if isinstance(node, ast.AugAssign) and isinstance(node.op, ast.Add) and isinstance(node.target, ast.Name) \
                and not isinstance(node.value, ast.Constant):
            dynamic_names.add(node.target.id)          # sql += "..." + name
        if isinstance(node, ast.ImportFrom) and node.module:
            for alias in node.names:
                imported[alias.asname or alias.name] = (node.module.split('.')[0], alias.name)
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.asname:
                    aliases[alias.asname] = alias.name.split('.')[0]      # import subprocess as sp

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = _dotted(node.func)
        if name and name[0] in aliases:
            name = (aliases[name[0]],) + name[1:]
        if len(name) == 1 and name[0] in imported:                       # from pickle import loads; loads(...)
            name = imported[name[0]]
        if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Call) and _dotted(node.func.value.func) == ('__import__',):
            first = node.func.value.args[0] if node.func.value.args else None
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                name = (first.value, node.func.attr)                    # __import__('os').system(...)
        tail = name[-2:] if len(name) >= 2 else name
        keywords = {k.arg: k.value for k in node.keywords if k.arg}
        # command execution: shell=True, or a single string command instead of an argv list
        if tail in COMMAND_SINKS or (len(name) == 1 and name[0] in ('system', 'popen')):
            shell = keywords.get('shell')
            variable_shell = shell is not None and not (isinstance(shell, ast.Constant) and shell.value is False)
            if variable_shell or tail in ALWAYS_SHELL:
                add('critical', 'command_shell', node, ast.unparse(node))
            elif node.args and isinstance(node.args[0], (ast.JoinedStr, ast.Constant, ast.BinOp)) and not _argv_list(node.args[0]):
                if not (isinstance(node.args[0], ast.Constant) and not isinstance(node.args[0].value, str)):
                    add('high', 'command_string', node, ast.unparse(node.args[0]))
            if node.args and AGENT_WORDS.search(ast.unparse(node.args[0])):
                add('high', 'agent_command_from_text', node, ast.unparse(node.args[0]))
        # dynamic code / unsafe deserialization
        if name in (('eval',), ('exec',)) or tail in (('pickle', 'load'), ('pickle', 'loads'), ('marshal', 'loads'),
                                                     ('dill', 'loads'), ('shelve', 'open')):
            add('critical', 'dynamic_code_or_pickle', node, ast.unparse(node), 120)
        if tail == ('yaml', 'load'):
            loader = keywords.get('Loader') or (node.args[1] if len(node.args) > 1 else None)
            if loader is None or 'Safe' not in ast.unparse(loader):
                add('critical', 'yaml_unsafe_load', node, ast.unparse(node), 120)
        # SQL built from interpolated strings
        if isinstance(node.func, ast.Attribute) and node.func.attr in SQL_METHODS and node.args and _is_dynamic_string(node.args[0]):
            add('medium', 'sql_dynamic_string', node, ', '.join(_interpolated(node.args[0])))
        elif (isinstance(node.func, ast.Attribute) and node.func.attr in SQL_METHODS and node.args
              and isinstance(node.args[0], ast.Name) and node.args[0].id in dynamic_names):
            add('medium', 'sql_dynamic_variable', node, node.args[0].id + ' (built from a dynamic string)')
        if tail == ('ssl', '_create_unverified_context'):
            add('high', 'tls_verify_false', node, ast.unparse(node), 120)
        # TLS verification off / outbound requests carrying secrets
        if isinstance(node.func, ast.Attribute) and node.func.attr in HTTP_SINKS:
            verify = keywords.get('verify')
            if isinstance(verify, ast.Constant) and verify.value is False:
                add('high', 'tls_verify_false', node, ast.unparse(node), 120)
            payload = ' '.join(ast.unparse(a) for a in (*node.args, *keywords.values()))
            if re.search(r'os\.environ(?!\.get\([\'"](?:HOME|PATH|LANG|TZ)[\'"])|getenv\(|\.ssh|id_rsa|keychain', payload):
                add('critical', 'agent_exfil_env_in_request', node, payload)
        # open() on a path built with an f-string: a hint for the manual path-traversal review
        if name == ('open',) and node.args and isinstance(node.args[0], ast.JoinedStr):
            add('low', 'path_from_fstring', node, ast.unparse(node.args[0]), 120)
        # archive extraction: tarfile needs filter='data' (3.12+), zipfile members need a path check
        if isinstance(node.func, ast.Attribute) and node.func.attr == 'extractall' and 'filter' not in keywords:
            add('low', 'archive_extractall_review', node,
                _clip(ast.unparse(node), 100) + '  ← tar 要加 filter="data"；zip 要先检查成员路径')


def _stdlib_names():
    names = getattr(sys, 'stdlib_module_names', None)        # Python 3.10+
    if names:
        return set(names)
    import sysconfig                                         # Python 3.9: list the standard library folder
    found = set(sys.builtin_module_names)
    stdlib = Path(sysconfig.get_paths()['stdlib'])
    for item in stdlib.iterdir():
        if item.name == 'site-packages':
            continue
        if item.suffix == '.py' or (item.is_dir() and (item / '__init__.py').exists()):
            found.add(item.stem if item.suffix == '.py' else item.name)
    dynload = stdlib / 'lib-dynload'
    if dynload.is_dir():
        found |= {p.name.split('.')[0] for p in dynload.iterdir()}
    return found | {'__future__', 'tomllib'}


def _skipped(rel_parts, skip):
    return any(part in skip for part in rel_parts[:-1])


def scan_imports(root, files, extra_local, findings):
    """Every top-level import resolves (stdlib, the project itself, or an installed distribution)."""
    stdlib = _stdlib_names()
    local = set(extra_local) | {p.name for p in root.iterdir() if p.is_dir()}
    for path in root.rglob('*.py'):
        try:
            parts = path.relative_to(root).parts
        except ValueError:
            continue
        if _skipped(parts, SKIP_DIRS):
            continue
        local.add(path.stem)
        if path.name == '__init__.py':
            local.add(path.parent.name)                      # src/ layout: src/mypkg/__init__.py
    seen = {}
    for path, rel in files:
        if path.suffix != '.py':
            continue
        text = read_text(path)
        if text is None:
            continue
        try:
            tree = ast.parse(text)
        except (SyntaxError, ValueError):
            continue
        optional = set()                                    # try: import x / except ImportError: fallback
        for node in ast.walk(tree):
            if isinstance(node, ast.Try) and any(
                    h.type is None or any(n in ast.unparse(h.type) for n in ('ImportError', 'ModuleNotFoundError', 'Exception'))
                    for h in node.handlers):
                optional |= {id(n) for stmt in node.body for n in ast.walk(stmt) if isinstance(n, (ast.Import, ast.ImportFrom))}
        for node in ast.walk(tree):
            names = []
            if id(node) in optional:
                continue
            if isinstance(node, ast.Import):
                names = [a.name.split('.')[0] for a in node.names]
            elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                names = [node.module.split('.')[0]]
            for name in names:
                seen.setdefault(name, (rel, node.lineno))
    for name, (rel, line) in sorted(seen.items()):
        if name in stdlib or name in local:
            continue
        try:
            found = importlib.util.find_spec(name) is not None
        except (ImportError, ValueError):
            found = False
        if not found:
            findings.append(Finding(severity='high', rule='supply_unresolved_import', file=rel, line=line, evidence=name,
                                    source=f'import {name}', fp_key=name))


def _pyproject_deps(text):
    """(deps, error). tomllib on 3.11+, otherwise a small bracket-aware reader of dependency arrays."""
    try:
        import tomllib
    except ImportError:
        tomllib = None
    if tomllib is not None:
        try:
            project = tomllib.loads(text).get('project', {})
        except Exception as exc:                            # tomllib.TOMLDecodeError
            return [], f'pyproject.toml 解析失败：{type(exc).__name__}'
        deps = list(project.get('dependencies', []))
        for extra in (project.get('optional-dependencies') or {}).values():
            deps += list(extra)
        return deps, None
    deps = []
    for match in re.finditer(r'(?m)^\s*([A-Za-z0-9_-]+)\s*=\s*\[', text):
        headers = re.findall(r'(?m)^\s*(\[[^\]\n]+\])\s*$', text[:match.start()])
        table = headers[-1].replace(' ', '') if headers else ''
        if not ((table == '[project]' and match.group(1) == 'dependencies') or table == '[project.optional-dependencies]'):
            continue
        i, quote, item, depth = match.end(), None, '', 1
        while i < len(text) and depth:
            ch = text[i]
            if quote:
                if ch == quote:
                    deps.append(item)
                    item, quote = '', None
                else:
                    item += ch
            elif ch in '"\'':
                quote = ch
            elif ch == '[':
                depth += 1
            elif ch == ']':
                depth -= 1
            i += 1
        if depth:
            return deps, 'pyproject.toml 依赖列表没有正常结束（Python 3.9 简易解析）'
    return deps, None


def scan_pins(root, findings):
    pinned = re.compile(r'[A-Za-z0-9_.\-\[\],]+==[0-9][A-Za-z0-9_.\-+]*(?:\s*;.*)?')
    path = root / 'pyproject.toml'
    if path.is_file():
        text = read_text(path)
        deps, error = _pyproject_deps(text) if text is not None else ([], 'pyproject.toml 读不出来')
        if error:
            findings.append(Finding(severity='low', rule='supply_parse_error', file='pyproject.toml', line=0, evidence=error,
                                    source=error))
        has_lock = any((root / name).is_file() for name in ('uv.lock', 'poetry.lock', 'pdm.lock', 'requirements.lock'))
        for dep in deps:
            if not pinned.fullmatch(dep.replace(' ', '')) and not has_lock:
                findings.append(Finding(severity='medium', rule='supply_unpinned_dependency', file='pyproject.toml', line=0,
                                        evidence=dep, source=dep))
    for req in sorted(root.glob('requirements*.txt')):
        text = read_text(req)
        if text is None:
            findings.append(Finding(severity='low', rule='supply_parse_error', file=req.name, line=0,
                                    evidence='编码认不出，没检查', source=req.name))
            continue
        for number, line in enumerate(_lines(text), 1):
            line = line.split(' #', 1)[0].strip()
            if not line or line.startswith('#') or line.startswith(('-r', '-c', '--hash')):
                continue
            if line.startswith(('--extra-index-url', '--index-url', '-i ', '--trusted-host')):
                findings.append(Finding(severity='high', rule='supply_extra_index', file=req.name, line=number, evidence=_clip(line, 80), source=line))
            elif not pinned.fullmatch(line.split(' \\')[0].replace(' ', '')):
                findings.append(Finding(severity='medium', rule='supply_unpinned_dependency', file=req.name, line=number,
                                        evidence=_clip(line, 80), source=line))
    pkg = root / 'package.json'
    if pkg.is_file() and not any((root / n).is_file() for n in ('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lockb', 'bun.lock')):
        findings.append(Finding(severity='medium', rule='supply_no_lockfile', file='package.json', line=0,
                                evidence='package.json 没有锁文件', source='package.json'))


def collect_files(root, bases, include_tests, exclude_paths):
    skip = SKIP_DIRS | (set() if include_tests else TEST_DIRS)
    out = []
    for base in bases:
        paths = sorted(base.rglob('*')) if base.is_dir() else [base]
        for path in paths:
            try:
                rel_parts = path.relative_to(root).parts
            except ValueError:
                continue
            try:
                if not path.is_file() or path.is_symlink() or path.stat().st_size > 2_000_000:
                    continue
            except OSError:
                continue
            if _skipped(rel_parts, skip) or path.resolve() in exclude_paths:
                continue
            is_env = path.name.startswith('.env') or path.name.endswith('.env')
            if path.suffix.lower() not in TEXT_SUFFIXES and not is_env:
                continue
            if _skipped(rel_parts, DATA_DIRS) and path.suffix.lower() not in CODE_SUFFIXES and not is_env:
                continue
            out.append((path, path.relative_to(root).as_posix()))
    return out


def scan(root, dirs=None, include_tests=False, extra_local=(), exclude_paths=()):
    root = Path(root).resolve()
    bases = [(root / d).resolve() for d in dirs] if dirs else [root]
    files = collect_files(root, bases, include_tests, set(exclude_paths))
    findings = []
    for path, rel in files:
        text = read_text(path)
        if text is None:
            continue
        scan_text(path, rel, text, findings)
        if path.suffix == '.py':
            try:
                scan_python(rel, text, findings)
            except RecursionError:              # e.g. a 200-link call chain: ast.unparse runs out of stack
                findings.append(Finding(severity='low', rule='python_parse_error', file=rel, line=0,
                                        evidence='代码嵌套太深，AST 检查做到一半停了（文本规则照常检查）', source=''))
    scan_imports(root, files, extra_local, findings)
    scan_pins(root, findings)
    counts = {}
    for finding in findings:
        finding['source'] = _scrub(finding['source'])               # never print or store a secret
        finding['evidence'] = _scrub(finding['evidence'])
        key = (finding['rule'], finding['file'], finding['source'])
        counts[key] = counts.get(key, 0) + 1
        finding['occurrence'] = counts[key]
        finding['id'] = finding.fingerprint()
        finding.pop('fp_key', None)
    findings.sort(key=lambda f: (SEVERITY.index(f['severity']), f['file'], f['line']))
    return findings


def _reviewed(entry):
    reason = entry.get('reason')
    if not isinstance(reason, str):
        return False
    reason = reason.strip()
    return bool(reason) and not reason.upper().startswith('TODO') and reason not in ('待查', '待定', '?', '？')


def load_baseline(path):
    """(reviewed ids -> entry, python version or None). Raises ValueError when the file is broken."""
    if not path.is_file():
        return {}, None
    text = read_text(path)
    try:
        data = json.loads(text or '')
    except ValueError as exc:
        raise ValueError(f'基线文件不是有效的 JSON：{path}（{exc}）') from None
    if not isinstance(data, dict) or not isinstance(data.get('reviewed', []), list):
        raise ValueError(f'基线文件格式不对：{path}')
    entries = [e for e in data.get('reviewed', []) if isinstance(e, dict) and e.get('id')]
    return {e['id']: e for e in entries if _reviewed(e)}, data.get('python')


def _python_version():
    return f'{sys.version_info[0]}.{sys.version_info[1]}'


def run(args):
    root = args.root.resolve()
    if not root.is_dir():
        print(f'找不到项目目录：{root}', file=sys.stderr)
        return 2
    for d in args.dirs or []:
        if not (root / d).exists():
            print(f'--dirs 里的 {d} 不存在（相对于 {root}）', file=sys.stderr)
            return 2
    baseline_path = (args.baseline or root / BASELINE_NAME).resolve()
    findings = scan(root, args.dirs, args.include_tests, args.extra_local, {Path(__file__).resolve(), baseline_path})
    if args.write_baseline:
        previous = {}
        if baseline_path.is_file():
            data = json.loads(read_text(baseline_path) or '{}')
            previous = {e['id']: e for e in data.get('reviewed', []) if isinstance(e, dict) and e.get('id')}
        entries = [{'id': f['id'], 'severity': f['severity'], 'rule': f['rule'], 'file': f['file'], 'line': f['line'],
                    'source': f['source'], 'reason': (previous.get(f['id']) or {}).get('reason') or 'TODO'} for f in findings]
        out = {'schema_version': 'security-scan-baseline/1', 'python': _python_version(),
               'note': '已人工复查、确认安全的发现。reason 必须写清为什么安全；空的、null、以 TODO 开头的都不算复查过。'
                       '请用被审项目自己的 Python 运行扫描，版本变了结果可能不同。',
               'reviewed': entries}
        baseline_path.write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
        todo = sum(1 for e in entries if not _reviewed(e))
        print(f'写入 {len(entries)} 条到 {baseline_path}；其中 {todo} 条还要补写理由（reason）。')
        return 0
    baseline, version = load_baseline(baseline_path)
    if version and version != _python_version():
        print(f'注意：基线是用 Python {version} 生成的，现在用的是 {_python_version()}，结果可能不同；'
              '请用被审项目自己的解释器运行。', file=sys.stderr)
    new = [f for f in findings if f['id'] not in baseline]
    shown = findings if args.all else new
    if args.json:
        print(json.dumps(shown, ensure_ascii=False, indent=1))
    else:
        for f in shown:
            mark = '' if f['id'] in baseline else ' [未复查]'
            print(f"[{f['severity']}] {f['rule']} {f['file']}:{f['line']}  {f['evidence']}{mark}")
        print(f'\n共 {len(findings)} 条，已复查 {len(findings) - len(new)} 条，未复查 {len(new)} 条'
              f'（Python {_python_version()}）。')
    return 1 if new else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description='Offline static security scan (stdlib only)')
    parser.add_argument('--root', type=Path, default=Path.cwd(), help='project root (default: current directory)')
    parser.add_argument('--dirs', nargs='*', help='only these sub-directories / files (default: the whole root)')
    parser.add_argument('--include-tests', action='store_true', help='also scan tests/ (fixtures there are often fake secrets)')
    parser.add_argument('--extra-local', nargs='*', default=[], help='module names that are local or live in another runtime')
    parser.add_argument('--baseline', type=Path, help=f'baseline file (default: <root>/{BASELINE_NAME})')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--all', action='store_true', help='show reviewed findings too')
    parser.add_argument('--write-baseline', action='store_true', help='write every current finding; keep old reasons, new ones get "TODO"')
    args = parser.parse_args(argv)
    try:
        return run(args)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 3
    except Exception as exc:                                # never let a crash look like "findings"
        print(f'扫描器内部错误：{type(exc).__name__}: {exc}', file=sys.stderr)
        return 3


if __name__ == '__main__':
    raise SystemExit(main())
