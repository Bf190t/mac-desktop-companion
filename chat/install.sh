#!/bin/sh
# Explicit, optional install. Never writes to the application bundle or uses sudo.
set -eu
umask 077
resources=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$#" -ne 1 ]; then echo 'Usage: install.sh INSTALL_DIRECTORY' >&2; exit 2; fi
destination=$1
case "$destination" in /*) ;; *) echo 'Installation directory must be absolute' >&2; exit 2;; esac
if [ "$(/usr/bin/uname -m)" != arm64 ]; then echo 'Local chat requires Apple silicon' >&2; exit 2; fi
major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
if [ "$major" -lt 26 ]; then echo 'Local chat requires macOS 26 or newer' >&2; exit 2; fi
parent=$(/usr/bin/dirname "$destination")
/bin/mkdir -p "$parent"
if [ -e "$destination" ]; then echo 'Installation already exists; remove it first' >&2; exit 2; fi
stage=$(/usr/bin/mktemp -d "$parent/.chat-install.XXXXXX")
child=''
cleanup() {
  if [ -n "$child" ]; then /bin/kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  [ ! -d "$stage" ] || /bin/rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
# Pin comes from the official GitHub release API digest. Verify before executing.
url='https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.12.15%2B20261021-aarch64-apple-darwin-install_only.tar.gz'
sha='a18cc33862b53bd54a148c710def5375c1b47470cccedf817a19c2d211764584'
printf '%s\n' '{"progress":0.02,"phase":"runtime"}'
/usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --silent --show-error --connect-timeout 30 --max-time 900 --retry 2 "$url" -o "$stage/python.tar.gz" & child=$!
wait "$child"; child=''
actual=$(/usr/bin/shasum -a 256 "$stage/python.tar.gz" | /usr/bin/cut -d' ' -f1)
if [ "$actual" != "$sha" ]; then echo 'Python archive checksum mismatch' >&2; exit 3; fi
/usr/bin/tar -xzf "$stage/python.tar.gz" -C "$stage"
/bin/rm "$stage/python.tar.gz"
/bin/mv "$stage/python" "$stage/python-base"
printf '%s\n' '{"progress":0.08,"phase":"dependencies"}'
"$stage/python-base/bin/python3.12" -I -B -u "$resources/install.py" "$stage" "$resources" & child=$!
wait "$child"; child=''
# Same-volume move commits a complete installation. A competing installer cannot
# overwrite an existing destination; the app serializes its own install action.
if [ -e "$destination" ]; then echo 'Destination appeared during installation' >&2; exit 3; fi
"$stage/python-base/bin/python3.12" -I -B -c 'import os,sys;os.rename(sys.argv[1],sys.argv[2])' "$stage" "$destination"
printf '%s\n' '{"progress":1.0,"phase":"installed"}'
