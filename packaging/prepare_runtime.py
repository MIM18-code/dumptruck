#!/usr/bin/env python3
"""Prepare pinned runtime files and their notices for the macOS app builder."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'packaging/vendor'
SOURCES = ROOT / 'packaging/runtime-sources.json'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(entry):
    path = VENDOR / entry['file']
    if not path.exists():
        temporary = path.with_suffix(path.suffix + '.download')
        with urllib.request.urlopen(entry['url'], timeout=60) as src, temporary.open('wb') as dst:
            shutil.copyfileobj(src, dst)
        if digest(temporary) != entry['sha256']:
            temporary.unlink()
            raise ValueError(f"Download hash mismatch: {entry['file']}")
        temporary.rename(path)
    if digest(path) != entry['sha256']:
        raise ValueError(f"Input hash mismatch: {path}")
    return path


def main():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This runtime recipe requires Apple Silicon macOS.')
    VENDOR.mkdir(parents=True, exist_ok=True)
    entries = json.loads(SOURCES.read_text())
    inputs = {name: fetch(entry) for name, entry in entries.items()}
    # Work directories retain build logs; each output is new and never overwrites a previous runtime.
    work = Path(tempfile.mkdtemp(prefix='runtime-build-', dir=VENDOR))
    runtime = work / 'runtime'
    runtime.mkdir()
    subprocess.run(['tar', '-xzf', str(inputs['python']), '-C', str(runtime)], check=True)
    python = runtime / 'python/bin/python3.13'
    subprocess.run([str(python), '-m', 'pip', 'install', '--no-input', '--no-deps', str(inputs['xxhash'])], check=True)
    legal = runtime / 'legal'
    legal.mkdir()
    metadata = subprocess.check_output(['tar', '-xOf', str(inputs['python_full']), 'python/PYTHON.json'])
    (legal / 'PYTHON.json').write_bytes(metadata)
    obj = json.loads(metadata)
    # Collect every notice named by this exact Python build, not a generic CPython license.
    license_paths = set()
    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == 'license_path':
                    license_paths.add(child)
                elif key == 'license_paths':
                    license_paths.update(child)
                else:
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(obj)
    python_legal = legal / 'python'
    python_legal.mkdir()
    for name in sorted(license_paths):
        if name == 'licenses/LICENSE.zlib-ng.txt':
            # Upstream PYTHON.json names this notice but the full archive omits it.
            # Recover it from the exact zlib-ng source pinned by upstream's 20260814 downloads.py.
            with tarfile.open(inputs['zlib_ng']) as archive:
                member = next(m for m in archive.getmembers() if m.name.endswith('/LICENSE.md') and m.name.count('/') == 1)
                data = archive.extractfile(member).read()
        else:
            data = subprocess.check_output(['tar', '-xOf', str(inputs['python_full']), 'python/' + name])
        (python_legal / Path(name).name).write_bytes(data)
    # Remove build-time pip and bundled development tools, retaining the runtime license inventory.
    stdlib = runtime / 'python/lib/python3.13'
    for name in ['test', 'idlelib', 'turtledemo', 'tkinter', 'ensurepip']:
        shutil.rmtree(stdlib / name, ignore_errors=True)
    for pattern in ['pip', 'pip-*.dist-info']:
        for path in (stdlib / 'site-packages').glob(pattern):
            shutil.rmtree(path)
    for path in runtime.rglob('__pycache__'):
        shutil.rmtree(path)
    source_dir = work / 'ffmpeg'
    source_dir.mkdir()
    subprocess.run(['tar', '-xf', str(inputs['ffmpeg']), '-C', str(source_dir), '--strip-components', '1'], check=True)
    print('Building FFmpeg from retained source...', flush=True)
    subprocess.run(['bash', str(ROOT / 'packaging/build_ffmpeg.sh'), str(source_dir)], check=True)
    tools = runtime / '.venv/bin'
    tools.mkdir(parents=True)
    for name in ['ffmpeg', 'ffprobe']:
        shutil.copy2(source_dir / name, tools / name)
        # Refuse a GPL/nonfree or locally linked build even if configure defaults change.
        license_output = subprocess.check_output([str(tools / name), '-L'], stderr=subprocess.STDOUT)
        normalized_license = b' '.join(license_output.split())
        if b'GNU Lesser General Public License' not in normalized_license or b'--enable-gpl' in normalized_license:
            raise ValueError(f'Unexpected FFmpeg license: {name}')
        linked = subprocess.check_output(['otool', '-L', str(tools / name)], text=True)
        for line in linked.splitlines()[1:]:
            if not line.strip().startswith(('/usr/lib/', '/System/Library/')):
                raise ValueError(f'Unexpected external dependency: {line}')
    decoder_output = subprocess.check_output([str(tools / 'ffmpeg'), '-hide_banner', '-decoders'], text=True)
    decoders = {parts[1] for line in decoder_output.splitlines() if len(parts := line.split()) >= 2}
    required = {'h264', 'hevc', 'prores', 'mjpeg', 'jpeg2000', 'png', 'exr'}
    if missing := required - decoders:
        raise ValueError(f'Missing media decoders: {sorted(missing)}')
    corresponding = legal / 'ffmpeg'
    corresponding.mkdir()
    for name in ['LICENSE.md', 'COPYING.LGPLv2.1', 'COPYING.GPLv2', 'COPYING.GPLv3', 'COPYING.LGPLv3', 'configure-dumptruck.log']:
        shutil.copy2(source_dir / name, corresponding / name)
    shutil.copy2(ROOT / 'packaging/build_ffmpeg.sh', corresponding)
    shutil.copy2(inputs['ffmpeg'], corresponding)
    (corresponding / 'BUILD_ENVIRONMENT.txt').write_text(subprocess.check_output(['clang', '--version'], text=True))
    (tools / 'python').write_text('#!/bin/sh\nexport PYTHONDONTWRITEBYTECODE=1\nexec "$(cd "$(dirname "$0")/../.." && pwd)/python/bin/python3.13" "$@"\n')
    (tools / 'python').chmod(0o755)
    shutil.copy2(SOURCES, legal)
    # Record files and symlinks. The DMG builder validates these before copying the runtime.
    records = {}
    for path in sorted(runtime.rglob('*')):
        relative = path.relative_to(runtime).as_posix()
        if path.is_symlink():
            records[relative] = {'symlink': str(path.readlink())}
        elif path.is_file():
            records[relative] = {'sha256': digest(path)}
    (runtime / 'MANIFEST.json').write_text(json.dumps(records, indent=2) + '\n')
    print('Runtime prepared:', runtime, flush=True)
    (VENDOR / 'runtime-path.txt').write_text(str(runtime.resolve()) + '\n')


if __name__ == '__main__':
    main()
