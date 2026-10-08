# Public release procedure

The maintainer selected Apache-2.0 for Dumptruck's original code and project
assets. See `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`. Proprietary camera
components retain separate terms and are not covered by the Apache grant.

## Source release

Run `python3 packaging/make_source_release.py`. The explicit file list exports
current working files with a SHA-256 manifest. It omits Git history, proprietary
SDK helper sources, vendor files, research, and private review reports. Artwork
and sounds are included based on the maintainer's confirmation of their origin.

Publish the reviewed export into a repository with fresh history. Do not simply
make the private development repository public, because its excluded files and
historical versions remain accessible in Git. Update the formula's HEAD URL
before publishing a public Homebrew tap. Resolve the naming concern recorded
in the private audit before public launch.

Contributors must have the right to submit their work under Apache-2.0. Retain
third-party notices and disclose borrowed code. Apache section 5 governs
contributions unless a separate agreement provides otherwise.

## Downloadable application

Run `python3 packaging/prepare_runtime.py`, then `packaging/make_public_dmg.sh`. The
builder produces a locally signed review candidate with Python, FFmpeg,
artwork, sounds, and dependency notices. FFmpeg's source and build script ship
inside the app. This fixes the former recipe's missing corresponding source.

From the private checkout, set `DUMPTRUCK_CAMERA_HELPERS=1` when building to
include compiled RED and Blackmagic helpers under separate component terms.
The public checkout cannot compile SDK-derived sources it does not contain.
End users of a candidate with those helpers need no compiler or SDK install.

The candidate is not a fully cleared public release. ARRI's decoder cannot be
bundled under the art-cmd EULA examined here. Obtain the appropriate ARRI
agreement and SDK or written redistribution permission. Confirm the proposed
camera-component terms and their acceptance mechanism meet the actual vendor
agreements before distributing the mixed-license app.

Use an Apple Developer ID identity and Apple's notarization process for a
normal public Mac download. A local or ad-hoc signature is not notarization.
With the Developer ID identity and the `dumptruck-notary` notarytool profile
installed, the recipe signs with the hardened runtime, notarizes and staples
the DMG. It never uploads or publishes the result anywhere else. Old private DMGs and any Homebrew bottles need their own review.
