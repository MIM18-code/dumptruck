#!/usr/bin/env python3
"""Reject an incomplete or changed prepared runtime before app packaging."""
import hashlib
import json
from pathlib import Path
import sys


def verify(root):
    root = root.resolve()
    records = json.loads((root / 'MANIFEST.json').read_text())
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != set(records) | {'MANIFEST.json'}:
        raise ValueError('Runtime file inventory changed; prepare it again.')
    for name, record in records.items():
        path = root / name
        if not path.resolve().is_relative_to(root):
            raise ValueError(f'Runtime path escapes its directory: {name}')
        if 'symlink' in record:
            if not path.is_symlink() or str(path.readlink()) != record['symlink']:
                raise ValueError(f'Runtime symlink changed: {name}')
        else:
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if path.is_symlink() or digest != record['sha256']:
                raise ValueError(f'Runtime file changed: {name}')
    for name in ['.venv/bin/python', '.venv/bin/ffmpeg', '.venv/bin/ffprobe', 'legal/PYTHON.json', 'legal/python/LICENSE.zlib-ng.txt', 'legal/ffmpeg/ffmpeg-9.0.1.tar.xz', 'legal/ffmpeg/build_ffmpeg.sh']:
        if name not in records:
            raise ValueError(f'Missing runtime component or notice: {name}')
    print('Prepared runtime inventory and hashes verified.')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
