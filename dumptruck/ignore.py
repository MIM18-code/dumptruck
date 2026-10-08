"""Junk filtering: OS litter never copies; everything else does.

Rule from the research: any file sharing an essence file's basename is a sidecar
and copies verbatim; manufacturer control files are mandatory. Only OS junk is
filtered, and the same patterns go into the ASC MHL <ignore> block so seals
don't break over litter that appears later.
"""

import fnmatch

IGNORE_NAMES = {
    ".DS_Store",
    ".Trashes",
    ".TemporaryItems",
    ".Spotlight-V100",
    ".fseventsd",
    ".metadata_never_index",
    ".com.apple.timemachine.donotpresent",
    # Permission-protected macOS system dirs found at the root of any volume
    # the OS has written to. Cards never carry them, but a general-purpose
    # drive staged as a source does — and walking into one crashes the scan
    # with PermissionError (alpha field report, 2026-08-23).
    ".DocumentRevisions-V100",
    ".MobileBackups",
    ".PKInstallSandboxManager",
    "System Volume Information",
    "$RECYCLE.BIN",
    "Thumbs.db",
    "desktop.ini",
}

# AppleDouble litter + our own bookkeeping (lock files AND staged partials,
# whose names are <destname>.dumptruck-partial-<pid>-<tid>).
# macOS renames a damaged revisions or Spotlight store in place with a
# "-bad-N" suffix and leaves the old one root-locked beside the new one
# (field report 2026-09-15: ".DocumentRevisions-V100-bad-1" on a 2 TB
# drive refused the whole source). Match the family, not the exact name.
IGNORE_PATTERNS = ("._*", ".dumptruck-*", "*.dumptruck-partial-*",
                   ".DocumentRevisions-V100*", ".Spotlight-V100*",
                   ".MobileBackups*")

# Patterns recorded in ASC MHL manifests (spec default set + ours).
MHL_IGNORE_PATTERNS = sorted(IGNORE_NAMES | set(IGNORE_PATTERNS) | {"ascmhl", "ascmhl/"})


def is_junk(name: str) -> bool:
    if name in IGNORE_NAMES:
        return True
    return any(fnmatch.fnmatch(name, pat) for pat in IGNORE_PATTERNS)
