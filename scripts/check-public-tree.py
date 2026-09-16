#!/usr/bin/env python3
"""Fail closed on accidentally staged private-engine or personal runtime files."""
from pathlib import Path
import re
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
try:
    names = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
except subprocess.CalledProcessError:
    names = [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and not any(part in {'.build', '.git', 'dist', '__pycache__'} for part in p.parts)]
problems = []
blocked_prefixes = ('mastering/vendor/', 'mastering/Source/', 'private/', 'custom/QA/', 'custom/backups/')
blocked_names = {'ReSoulCatalog.json', 'SOURCE-MANIFEST.json', '.env', 'hosts.yml', 'credentials', 'id_rsa', 'id_ed25519'}
blocked_suffixes = {'.wav', '.flac', '.mp3', '.m4a', '.aiff', '.safetensors', '.ckpt', '.pt', '.pth', '.npy', '.p12', '.p8', '.pem', '.key', '.dmg', '.dylib'}
for name in filter(None, names):
    p = root / name
    if name.startswith(blocked_prefixes) or p.name in blocked_names or p.suffix.lower() in blocked_suffixes:
        problems.append((name, 'private/binary/data file'))
    if not p.is_file():
        continue
    if p.stat().st_size > 12_000_000:
        problems.append((name, 'oversized file requires review'))
    try:
        text = p.read_text()
    except (UnicodeError, OSError):
        continue
    # This guard reports filenames only; never print suspected credentials.
    if re.search(r'/Users/[A-Za-z0-9_.-]+/', text):
        problems.append((name, 'personal absolute path'))
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text):
        problems.append((name, 'private key'))
if problems:
    for name, reason in problems:
        print(f'{name}: {reason}', file=sys.stderr)
    sys.exit(1)
print(f'Public-tree guard passed for {sum(bool(n) for n in names)} files. Run a separate secret scanner before publishing.')
