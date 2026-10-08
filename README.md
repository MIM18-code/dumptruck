# Dumptruck

Checksum-verified camera media offloading for macOS. Dumptruck copies media to
backup drives, verifies the copies, and records the results in reports and
ASC MHL manifests. The app has no erase function.

"SAFE TO WIPE" means the job met the engine's verification criteria at the time
of the check. It is not a guarantee against later hardware failure, missing
source material, or every form of data loss. Review the evidence and your
backup requirements before erasing original media. The software is provided
without warranty under the terms of [Apache-2.0](LICENSE).

## Build from source

Requires macOS 14 or later, Xcode Command Line Tools, Python 3.13, and Homebrew.
The current build workflow targets Apple Silicon.

```sh
xcode-select --install
brew install python@3.13 ffmpeg
python3.13 -m venv .venv
.venv/bin/python -m pip install xxhash==4.0.1
ln -s "$(brew --prefix ffmpeg)/bin/ffmpeg" .venv/bin/ffmpeg
ln -s "$(brew --prefix ffmpeg)/bin/ffprobe" .venv/bin/ffprobe
DumptruckApp/make_app.sh
open DumptruckApp/build/Dumptruck.app
```

Keep the app in this checkout so it can find the engine. For a separately
installed app and engine, use the [public packaging instructions](packaging/PUBLIC_RELEASE.md).
The private checkout also has its original Homebrew workflow in
`packaging/README.md`, with native RED/BRAW helper builds and full Homebrew FFmpeg.
The CLI runs with `.venv/bin/python -m dumptruck.cli --help`.

A source build uses a local signing identity when available and otherwise an
ad-hoc signature, and is not notarized. The [public packaging recipe](packaging/PUBLIC_RELEASE.md)
builds a self-contained DMG with Python, FFmpeg, and optional native camera
helpers, and signs and notarizes it when a Developer ID identity is installed.
Bundled camera helpers stay off until the user agrees to their terms in the app. ARRI bundling and public distribution still require the steps
in the [release procedure](legal/PUBLIC_RELEASE.md).

## Included code

- Python engine in `dumptruck/`, with copy verification, generation history,
  ASC MHL v2.0, and legacy MHL v1.1 support.
- Native SwiftUI app in `DumptruckApp/`, with job evidence, queue controls,
  history, and optional remote notifications.
- HTML and PDF reports and JSON receipts for offload results.

The public source package includes the project artwork and sounds. See
[asset provenance](assets/PROVENANCE.md). Proprietary SDK helpers are excluded.
ARRI Reference Tool and REDline integration
remain available when those vendor applications are installed separately. FFmpeg supplies optional media metadata and
thumbnails through a separate installation. These extras do not control the
copy verification verdict.

## Verification

The adversarial suite also uses ASC's separately installed schema validator.

```sh
.venv/bin/python -m pip install ascmhl==1.2
.venv/bin/python tests/adversarial.py
.venv/bin/python tests/cards_and_identity.py
DumptruckApp/run_checks.sh
cd DumptruckApp
swift build -c release
```

## License and release

Dumptruck's original public code is Apache-2.0, selected by its maintainer.
See [LICENSE](LICENSE), [NOTICE](NOTICE), and
[third-party notices](THIRD_PARTY_NOTICES.md). Third-party components retain
their own licenses. Product and vendor names do not imply endorsement.

See [data handling](PRIVACY.md) before sharing reports or enabling webhooks.
The [public release procedure](legal/PUBLIC_RELEASE.md) explains how to export
reviewed source without private files or Git history. The private development
repository must not be made public without resolving the remaining audit items.
