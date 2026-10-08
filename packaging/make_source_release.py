#!/usr/bin/env python3
"""Export the reviewed public files without private assets or Git history."""
import hashlib
import io
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parent.parent
FILE_LIST = ROOT / "packaging/public-source-files.txt"


def collect(root=ROOT, file_list=FILE_LIST):
    names = file_list.read_text().splitlines()
    if not names or len(names) != len(set(names)):
        raise ValueError("Public source list is empty or contains duplicates")
    result = []
    for name in names:
        rel = PurePosixPath(name)
        if not name or rel.is_absolute() or '..' in rel.parts or str(rel) != name:
            raise ValueError(f"Invalid release path: {name}")
        path = root / name
        if any(p.is_symlink() for p in [path, *path.parents] if p != root.parent):
            raise ValueError(f"Release symlink is forbidden: {name}")
        if not path.is_file():
            raise ValueError(f"Missing release input: {name}")
        result.append((name, path.read_bytes(), 0o755 if path.stat().st_mode & 0o111 else 0o644))
    return result


def main():
    files = collect()
    names = {name for name, _, _ in files}
    if not {'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'} <= names:
        raise ValueError("Release must contain license and notices")
    manifest = ''.join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data, _ in files)
    dist = ROOT / 'packaging/dist'
    dist.mkdir(parents=True, exist_ok=True)
    # A content-derived name preserves previous exports and identifies dirty-tree changes.
    digest = hashlib.sha256(manifest.encode()).hexdigest()[:16]
    output = dist / f'dumptruck-source-{digest}.tar.gz'
    with output.open('xb') as stream:
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for name, data, mode in files + [('SOURCE_SHA256SUMS', manifest.encode(), 0o644)]:
                info = tarfile.TarInfo('dumptruck/' + name)
                info.size, info.mode, info.mtime = len(data), mode, 0
                archive.addfile(info, io.BytesIO(data))
    print(output)
    print(f'{len(files)} files; archive SHA-256 {hashlib.sha256(output.read_bytes()).hexdigest()}')


if __name__ == '__main__':
    main()
