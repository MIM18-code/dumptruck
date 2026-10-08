# Third-party notices

Dumptruck's original public code and project assets are Apache-2.0. See
`LICENSE`, `NOTICE`, and `assets/PROVENANCE.md`. Third-party components retain
their own licenses. Proprietary camera components are outside the Apache grant.

| Component | Use | License and included evidence |
| --- | --- | --- |
| ASC MHL | Schema and reference for the C4 hasher | MIT, Copyright 2020 ASC. `LICENSES/ASC-MHL-MIT.txt`. |
| python-xxhash 4.0.1 | Python hashing dependency | BSD-2-Clause. `LICENSES/python-xxhash-BSD-2-Clause.txt`. |
| xxHash | Native hashing implementation | BSD-2-Clause. `LICENSES/xxHash-BSD-2-Clause.txt`. |
| ascmhl 1.2 | Separately installed test validator | ASC MIT, supplied with the dependency. |
| CPython 3.13.15 standalone | Bundled interpreter | Python license. The public runtime recipe collects dependency notices from the exact build metadata. |
| FFmpeg / FFprobe 9.0.1 public candidate build | Separate local-file metadata and thumbnail processes | LGPL-2.1-or-later. Complete source, build script, license texts, and build configuration accompany this build. |
| FFmpeg / FFprobe 9.0.1 private build | Original full FFmpeg binaries | GPL-enabled upstream build. Private use does not establish clearance to redistribute this binary. |
| Optional RED and Blackmagic runtimes | Proprietary metadata and thumbnail helpers | Separate camera component terms. Vendor binaries remain outside the open source grant. |
| ARRI Image SDK 9.1.1 and ARRI MXF library 4.4.16 (private build; public only after ARRI approval) | arri-probe: ARRIRAW and ARRICORE metadata and Rec.709 thumbnails | ARRI Partner Program agreement; runtime bundled inside the app only, notices preserved. `legal/ARRI_COMPONENT_NOTICES.txt` carries the OpenCL, TinyXML, JPEG XS and MXF-library third-party notices. |
| Apple system frameworks | macOS application and runtime support | Supplied by macOS under Apple's terms. No Apple SDK ships in the source archive. |

ASC provenance is [ascmitc/mhl at commit 0fb61f1](https://github.com/ascmitc/mhl/tree/0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687).
The schema matched upstream before an attribution comment was added. Research
notes identify ASC's C4 implementation as a reference. Those files retain ASC's
MIT notice without asserting that the entire engine was copied.

The xxhash notices were extracted from the SHA-256-pinned 4.0.1 source archive
listed in `packaging/runtime-sources.json` and the Homebrew formula.

## Bundled open runtime

Inside a public-workflow candidate app, `Contents/Resources/engine/legal/` contains the pinned
input list, Python build metadata and dependency license texts, and the FFmpeg
source archive and build recipe. FFmpeg is built without GPL, nonfree, network,
or automatically detected external library support. Its bundled command-line
programs link only to macOS system libraries. This build supports local-file
inspection and thumbnail generation; it is not the old all-codec vendor build.

The Python full archive for release 20260814 omits the zlib-ng notice named in
its own metadata. The recipe obtains that notice from zlib-ng 2.2.4's exact
source archive, as pinned by the upstream release's `pythonbuild/downloads.py`.
Python's other notices come from the same full build as the stripped interpreter.

`packaging/make_public_dmg.sh` uses the LGPL build. The private builder at
`packaging/make_dmg.sh` retains the original full Martin Riedl FFmpeg binaries.
Private DMGs require separate GPL compliance review before redistribution.
[FFmpeg distribution guidance](https://www.ffmpeg.org/legal.html).

## Camera components

The public source archive does not include SDK helper sources, headers,
libraries, or confidential SDK documentation. The private candidate builder
can include compiled RED and Blackmagic helpers and their runtime libraries.
Their component-only terms and Blackmagic third-party notices are in
`Contents/Resources/legal/cameras/`. Vendor runtime bytes are preserved.

ARRI Reference Tool and REDline integration code remain open source. Their
separately installed vendor applications are not included. The July 15, 2025
art-cmd EULA does not grant general redistribution permission. ARRI's Image
Partner Program agreement or written permission is required before bundling
ARRI decoding. No vendor endorsement or certification is claimed.
