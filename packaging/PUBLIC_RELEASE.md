# Application packaging

These are the public release build paths. Private builds use the separate
`packaging/dumptruck.rb` and `packaging/make_dmg.sh` in the private checkout.
The public source archive does not include those private recipes.

Dumptruck's original source and project assets are Apache-2.0. Proprietary
camera binaries retain separate terms. See `THIRD_PARTY_NOTICES.md`.

## Self-contained local candidate

Build on Apple Silicon macOS with Xcode Command Line Tools and Python 3.11 or
later for the packaging scripts:

```sh
python3 packaging/prepare_runtime.py
DUMPTRUCK_CAMERA_HELPERS=1 packaging/make_public_dmg.sh
```

The first command downloads only pinned upstream inputs and checks SHA-256
hashes. It prepares Python with its dependency notices, builds FFmpeg and
FFprobe without GPL/nonfree/external codec libraries, and includes FFmpeg's
source and build script. Build logs and prepared runtimes stay under the
ignored `packaging/vendor/` directory. Failed builds retain their logs.

The second command includes the private RED and Blackmagic helpers and requires
the RED R3D SDK (private checkout only) plus the Blackmagic RAW SDK installed
under Applications. Omit `DUMPTRUCK_CAMERA_HELPERS=1` to build the open core
without proprietary helpers. Download recipients never compile those helpers.

The output is a new, timestamped DMG in `packaging/dist/`. Previous candidates
are not overwritten. The builder validates the runtime inventory, signs our
executables, and preserves the original vendor runtime bytes. It copies artwork
and sounds into the app. FFmpeg source and dependency notices are accessible
inside `Contents/Resources/engine/legal/`.

Signing uses `packaging/release_signing.sh`. With a "Developer ID
Application" identity in the keychain, every executable gets the hardened
runtime and a secure timestamp, and the DMG is notarized and stapled through
the notarytool keychain profile `dumptruck-notary` (override with
`DUMPTRUCK_NOTARY_PROFILE`). Create that profile once:

```sh
xcrun notarytool store-credentials dumptruck-notary \
    --apple-id <developer account> --team-id <TEAMID>
```

Without a Developer ID identity the builder falls back to local signing and
skips notarization. Check a notarized candidate with
`python3 tests/bundle_smoke.py --release <dmg>`.

ARRI decoder bundling still requires vendor approval, and camera-component
terms need final review. Existing installations of ARRI
Reference Tool and REDline remain usable. The original full FFmpeg ZIP inputs
are no longer used by this recipe.

## Source installation through Homebrew

The formula installs Python and FFmpeg separately and builds the open core.
It carries Apache-2.0 metadata and all project notices. It does not build or
copy proprietary helpers. Do not publish bottles without reviewing their
actual contents and accompanying terms.

Generate the reviewed archive:

```sh
python3 packaging/make_source_release.py
```

Use the printed absolute archive path below:

```sh
archive="/absolute/path/to/dumptruck-source-HASH.tar.gz"
formula_uri="$(brew ruby -ruri -e \
  'puts "file://#{URI::DEFAULT_PARSER.escape(File.expand_path(ARGV.fetch(0)))}"' \
  packaging/public/dumptruck.rb)"
HOMEBREW_DUMPTRUCK_LOCAL_ARCHIVE="$archive" \
HOMEBREW_DUMPTRUCK_LOCAL_ARCHIVE_SHA256="$(shasum -a 256 "$archive" | awk '{print $1}')" \
HOMEBREW_DEVELOPER=1 \
  brew install --build-from-source --formula "$formula_uri"
```

The app installs at `$(brew --prefix)/opt/dumptruck/Dumptruck.app`. The formula
records the engine path so the app can move to Applications. Its current HEAD
URL points to the private development repository. Update it to the reviewed
public repository before publishing a tap.
