# Dumptruck

Checksum-verified camera media offloading for macOS. Dumptruck copies media to
backup drives, verifies the copies, and records the results in reports and
ASC MHL manifests. The app has no erase function.

"VERIFIED · SAFE TO CLEAR" means the job met the engine's verification criteria at the time
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

## Scripting the running app

`dumptruck-ctl` drives the open app the way its buttons do: stage a card and
name it, add destinations, start, pause, resume, stop, Stage Retry and eject.
Jobs started this way show in the window, Job History and the verdicts. A
refused command prints the reason the window would show and exits 1. Stop
needs `--confirm`. An eject the app would warn about needs `--confirm`, or
`--force` while a transfer is reading or writing that volume, where ejecting
can damage the copy in progress. A finished Fast-mode or failed run is not in
progress, so its card ejects with `--confirm`.

```sh
dumptruck-ctl status
dumptruck-ctl stage A001 --label A001     # a volume name or an absolute path
dumptruck-ctl add-dest "Crucial X10 Pro"
dumptruck-ctl mirror "Crucial X10 Pro/Show/11232026"   # drive name first, or /Volumes/…
dumptruck-ctl start --wait 30             # retries while the card is still being read
dumptruck-ctl wait A001                   # exits 0 only when verified
dumptruck-ctl eject A001
```

`status`, `add-dest`, `stage` and `mirror` print where the card will land,
for example `card lands in: /Volumes/X9/Show/11232026/Raws/A001`. The
Organize template (Settings, `{Project}/Raws` by default) adds its folder
under the mirrored folder, so mirroring a folder that already ends in `Raws`
gives `…/Raws/Raws/A001`; the reply notes a folder name that repeats. A
mirrored folder may be a full path, a path that starts with the drive's name
(`X9/Show/11232026`), or a folder inside the one staged destination drive
(`Show/11232026`).

`start --verify fast` runs that one job in Fast mode (size check only) and
`--verify full` in full verification, without changing the saved
Verification setting. A Fast-mode job ends COPIED · NOT VERIFIED, never
VERIFIED, so `wait` exits 5 when such a job finished with every file copied
and none failed, and `wait --accept-copied` exits 0 for it. A verified job
the window shows amber (a file left behind, the card changed mid-copy, a
failed flush, damage found later) exits 1, Fast or full.

Homebrew installs `dumptruck-ctl`. From an app bundle, run
`/Applications/Dumptruck.app/Contents/Resources/engine/.venv/bin/python /Applications/Dumptruck.app/Contents/Resources/engine/dumptruck/ctl.py`,
and from a checkout, `python3 dumptruck/ctl.py`. `--json` prints the app's
reply as is; `dumptruck-ctl --help` lists every command.

The app listens on a Unix socket at
`~/Library/Application Support/Dumptruck/control.sock` (mode 0600, current user
only, no network listener). `DUMPTRUCK_HOME` moves it to
`$DUMPTRUCK_HOME/control.sock`, `DUMPTRUCK_CONTROL_SOCKET` names another path,
and `DUMPTRUCK_CONTROL_SOCKET=off` turns it off.

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
