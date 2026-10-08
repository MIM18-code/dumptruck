#!/usr/bin/env python3
"""Stage binary camera helpers for a local release candidate, never SDK sources."""
import argparse
import hashlib
import os
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('engine', type=Path)
    parser.add_argument('legal', type=Path)
    args = parser.parse_args()
    tools = args.engine / 'tools'
    if tools.exists():
        raise SystemExit(f'Refusing to overwrite existing tools: {tools}')
    sdk = ROOT / 'tools/vendor/R3DSDK'
    braw = Path('/Applications/Blackmagic RAW/Blackmagic RAW SDK')
    # ARRI Image SDK runtime: bundled only inside the app (Partner Program
    # agreement 2.2/4.1). The private build carries it for development and
    # for the prototype ARRI tests; the public build only once ARRI has
    # approved the Licensed Product (DUMPTRUCK_ARRI_APPROVED=1).
    arri_vendor = ROOT / 'tools/vendor/arri'
    include_arri = arri_vendor.exists() and os.environ.get('DUMPTRUCK_ARRI', '1') == '1'
    helpers = ['r3d', 'braw'] + (['arri'] if include_arri else [])
    # Compile from the private checkout. The public source package intentionally lacks these sources.
    for name in helpers:
        subprocess.run(['bash', str(ROOT / f'tools/build-{name}-probe.sh')], check=True)
    tools.mkdir(parents=True)
    for name in helpers:
        shutil.copy2(ROOT / 'tools' / f'{name}-probe', tools / f'{name}-probe')
    if include_arri:
        # Only the runtime: the master library, its plugins and the JPEG XS
        # codec. No headers, documentation, samples or schemas (ARRI, 2026-09-16).
        arri_runtime = tools / 'vendor/arri'
        arri_runtime.mkdir(parents=True)
        for entry in sorted(arri_vendor.iterdir()):
            if entry.is_symlink():
                (arri_runtime / entry.name).symlink_to(os.readlink(entry))
            elif entry.is_dir():
                shutil.copytree(entry, arri_runtime / entry.name, symlinks=True)
            else:
                shutil.copy2(entry, arri_runtime / entry.name)
    red_runtime = tools / 'vendor/R3DSDK/Redistributable/mac'
    red_runtime.mkdir(parents=True)
    for name in ['REDR3D.dylib', 'REDDecoder.dylib', 'REDMetal.dylib', 'REDOpenCL.dylib']:
        shutil.copy2(sdk / 'Redistributable/mac' / name, red_runtime / name)
    framework = braw / 'Mac/Libraries/BlackmagicRawAPI.framework'
    shutil.copytree(framework, tools / 'vendor/BlackmagicRawAPI.framework', symlinks=True)
    args.legal.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'legal/CAMERA_COMPONENT_TERMS.txt', args.legal)
    if include_arri:
        shutil.copy2(ROOT / 'legal/ARRI_COMPONENT_NOTICES.txt', args.legal)
    # This is the vendor's runtime dependency notice, not the confidential RED SDK documentation.
    subprocess.run(['textutil', '-convert', 'txt', str(braw / 'Documents/Third Party Licenses.rtf'), '-output', str(args.legal / 'Blackmagic-Third-Party-Licenses.txt')], check=True)
    originals = {}
    bases = [sdk / 'Redistributable/mac', framework] + ([arri_vendor] if include_arri else [])
    for base in bases:
        for source in base.rglob('*'):
            if source.is_file() and not source.is_symlink():
                if base == framework:
                    target = tools / 'vendor/BlackmagicRawAPI.framework' / source.relative_to(base)
                elif include_arri and base == arri_vendor:
                    target = tools / 'vendor/arri' / source.relative_to(base)
                else:
                    target = red_runtime / source.relative_to(base)
                if target.exists():
                    want = hashlib.sha256(source.read_bytes()).hexdigest()
                    assert hashlib.sha256(target.read_bytes()).hexdigest() == want
                    originals[target.relative_to(args.engine).as_posix()] = want
    (args.legal / 'CAMERA_RUNTIME_SHA256.json').write_text(json.dumps(originals, indent=2) + '\n')
    for name in helpers:
        subprocess.run([str(tools / f'{name}-probe'), '--help'], check=True)
    if include_arri:
        subprocess.run([str(tools / 'arri-probe'), '--version'], check=True)
    print('Native helpers staged; vendor runtime bytes preserved.')


if __name__ == '__main__':
    main()
