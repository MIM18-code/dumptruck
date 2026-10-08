"""macOS-specific fd flags for cache-honest I/O + physical device topology.

The load-bearing rule (measured): F_NOCACHE does NOT purge pages already in the
unified buffer cache, so it must be set on the DESTINATION WRITE fd before the
first byte is written. Then the verify re-read is a guaranteed device read.
Plain fsync() on macOS only reaches the drive cache; F_FULLFSYNC reaches media.

Every setter returns whether the syscall actually succeeded — the attestation
must reflect reality, never assumption (bug-hunt finding: hard-coded flags).
"""

import fcntl
import sys

IS_MACOS = sys.platform == "darwin"

# Not exposed by the fcntl module by name; from this SDK's sys/fcntl.h.
F_NOCACHE_EXT = 112

# Shared fail-closed sentinel: unresolvable topology must NEVER count as an
# independent device (bug-hunt finding: fail-open st_dev fallback).
UNKNOWN_DEVICE = "unknown"


def _set(fd, cmd, arg=1) -> bool:
    try:
        fcntl.fcntl(fd, cmd, arg)
        return True
    except OSError:
        return False


def setup_source_fd(fd) -> bool:
    if not IS_MACOS:
        return False
    ok = _set(fd, fcntl.F_NOCACHE)
    _set(fd, fcntl.F_RDAHEAD)
    return ok


def setup_dest_write_fd(fd) -> bool:
    if not IS_MACOS:
        return False
    # F_NOCACHE_EXT relaxes the size/alignment restrictions for uncached writes;
    # fall back to plain F_NOCACHE where unsupported.
    return _set(fd, F_NOCACHE_EXT) or _set(fd, fcntl.F_NOCACHE)


def setup_verify_fd(fd) -> bool:
    if not IS_MACOS:
        return False
    ok = _set(fd, fcntl.F_NOCACHE)
    _set(fd, fcntl.F_RDAHEAD)
    return ok


def full_fsync(fd) -> bool:
    """True only when the full flush-to-media primitive succeeded."""
    if IS_MACOS and _set(fd, fcntl.F_FULLFSYNC, 0):
        return True
    import os

    try:
        os.fsync(fd)
    except OSError:
        pass
    return False


def fsync_dir(path) -> bool:
    """Sync a directory so a just-renamed entry survives power loss."""
    import os

    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return False
    try:
        return full_fsync(fd)
    finally:
        os.close(fd)


_device_cache: dict = {}


def physical_device_id(path) -> str:
    """Display-friendly physical identity string, or UNKNOWN_DEVICE.
    Independence decisions must use physical_stores() — a fused/multi-store
    container flattened to one string hides shared underlying disks."""
    stores = physical_stores(path)
    if stores == UNKNOWN_DEVICE or not stores:
        return UNKNOWN_DEVICE
    return "+".join(sorted(stores))


def physical_stores(path):
    """Resolve a path to the SET of underlying whole disks (frozenset), or
    UNKNOWN_DEVICE.

    Two destinations are not two copies if they're volumes on one device (two
    APFS volumes on one SSD, two shares on one RAID). The key must therefore be
    the PHYSICAL disks: for APFS volumes that means the container's physical
    stores' whole disks — never the per-volume DiskUUID (which made every APFS
    volume look like its own device) and never st_dev (fail-open). Fusion/RAID
    containers return EVERY member disk so callers can require pairwise-disjoint
    sets (two containers sharing one member disk are NOT independent copies).
    Anything unresolvable returns the shared UNKNOWN_DEVICE sentinel, which the
    attestation must count as zero independent devices.
    """
    import os
    import plistlib
    import re
    import subprocess

    try:
        dev = os.stat(path).st_dev
    except OSError:
        return UNKNOWN_DEVICE
    if dev in _device_cache:
        return _device_cache[dev]

    result = UNKNOWN_DEVICE
    if IS_MACOS:
        try:
            # diskutil answers for mount points/devices, not arbitrary paths:
            # walk up to the containing mount point first.
            mount = os.path.realpath(path)
            while not os.path.ismount(mount):
                parent = os.path.dirname(mount)
                if parent == mount:
                    break
                mount = parent
            out = subprocess.run(
                ["diskutil", "info", "-plist", mount],
                capture_output=True, timeout=15, check=True,
            ).stdout
            info = plistlib.loads(out)
            if "Error" in info:
                raise OSError(f"diskutil error for {mount}")
            # APFS: resolve through the container to the physical store(s).
            stores = info.get("APFSPhysicalStores") or []
            wholes = {re.sub(r"s\d+$", "", s.get("APFSPhysicalStore", ""))
                      for s in stores if s.get("APFSPhysicalStore")}
            if wholes:
                result = frozenset(wholes)
            else:
                whole = info.get("ParentWholeDisk")
                if not whole and info.get("DeviceIdentifier"):
                    whole = re.sub(r"s\d+.*$", "", info["DeviceIdentifier"])
                if whole:
                    result = frozenset({whole})
        except (subprocess.SubprocessError, plistlib.InvalidFileException, OSError):
            pass
    _device_cache[dev] = result
    return result
