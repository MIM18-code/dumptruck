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
    return full_fsync_error(fd) is None


def full_fsync_error(fd):
    """None when F_FULLFSYNC reached media, else the errno it failed with.
    A failure still runs plain fsync() so the bytes get as far as they can.
    Network volumes (SMB, WebDAV) refuse F_FULLFSYNC outright: measured
    ENOTTY on a WebDAV mount, where fsync() still succeeds."""
    import errno
    import os

    err = errno.ENOTSUP
    if IS_MACOS:
        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC, 0)
            return None
        except OSError as e:
            err = e.errno
    try:
        os.fsync(fd)
    except OSError:
        pass
    return err


MNT_LOCAL = 0x00001000


def describe_volume(fd):
    """(mount point, filesystem type, is_local) for the volume holding fd, or
    None. Display only: it explains a degraded attestation to the operator and
    must never feed a safety decision."""
    if not IS_MACOS:
        return None
    try:
        import ctypes
        import platform

        class _Statfs(ctypes.Structure):
            # struct statfs, 64-bit inode layout (sys/mount.h).
            _fields_ = [
                ("f_bsize", ctypes.c_uint32), ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64), ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64), ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64), ("f_fsid", ctypes.c_int32 * 2),
                ("f_owner", ctypes.c_uint32), ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32), ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32), ("f_reserved", ctypes.c_uint32 * 7),
            ]

        libc = ctypes.CDLL(None, use_errno=True)
        name = "fstatfs$INODE64" if platform.machine() == "x86_64" else "fstatfs"
        fn = getattr(libc, name)
        fn.argtypes = [ctypes.c_int, ctypes.POINTER(_Statfs)]
        st = _Statfs()
        if fn(fd, ctypes.byref(st)) != 0:
            return None
        return (st.f_mntonname.decode("utf-8", "replace"),
                st.f_fstypename.decode("utf-8", "replace"),
                bool(st.f_flags & MNT_LOCAL))
    except Exception:  # noqa: BLE001 — a description must never break a copy
        return None


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


_SHARE_KINDS = {"smbfs": "SMB", "nfs": "NFS", "webdav": "WebDAV", "afpfs": "AFP"}


def share_label(volume):
    """'FOLIAGE (SMB)' for a network volume from describe_volume()."""
    import os

    mount, fstype, _local = volume
    return f"{os.path.basename(mount) or mount} ({_SHARE_KINDS.get(fstype, fstype)})"


def flush_failure_text(err, volume):
    """Operator-facing reason a destination could not flush to media."""
    import errno as _errno

    code = _errno.errorcode.get(err, str(err))
    if volume is None:
        return f"F_FULLFSYNC failed ({code}); plain fsync was used"
    mount, fstype, local = volume
    if not local and err in (_errno.ENOTTY, _errno.ENOTSUP):
        # A DIT reads this, not a kernel engineer: network shares never
        # confirm a flush, and that is normal, not a fault.
        # Durability only: verification results live elsewhere (a Fast run
        # never reads back, so this must not claim it did).
        return (f"{share_label(volume)} is a network share: macOS can't confirm "
                "the server has written the copy to its disks. Copies on network "
                "shares don't count toward SAFE TO WIPE")
    where = "network" if not local else "local"
    return f"{mount} ({fstype}, {where}) rejected F_FULLFSYNC ({code}); plain fsync was used"


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
