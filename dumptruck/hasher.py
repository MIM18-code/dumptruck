"""Streaming hashers. xxh64 is the primary (XXH64BE-compatible hex); C4 is required
by the ASC MHL chain format."""

import errno
import fcntl
import hashlib
import os
import stat as stat_mod

import xxhash

# 4 MiB: below 64 KiB python-xxhash holds the GIL and thread scaling collapses
# (measured 1.25x vs 3.5x on this hardware).
CHUNK_SIZE = 4 * 1024 * 1024

# Verification is fed by operator-selected folders and untrusted manifest
# paths.  Keep descriptor traversal finite before it allocates descriptors or
# starts a read.
MAX_RELATIVE_PATH_BYTES = 4 * 1024
MAX_RELATIVE_COMPONENTS = 256

_C4_CHARSET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
_C4_ID_LEN = 90


# C4 implementation informed by ASC MHL, Copyright (c) 2020 ASC.
# MIT license and attribution: LICENSES/ASC-MHL-MIT.txt.
class C4Hasher:
    """C4 ID: SHA-512 rendered as base58 with the C4 charset, 'c4' prefix, 90 chars."""

    name = "c4"

    def __init__(self) -> None:
        self._sha = hashlib.sha512()

    def update(self, data) -> None:
        self._sha.update(data)

    def hexdigest(self) -> str:
        num = int.from_bytes(self._sha.digest(), "big")
        chars = []
        while num > 0:
            num, rem = divmod(num, 58)
            chars.append(_C4_CHARSET[rem])
        encoded = "".join(reversed(chars))
        body_len = _C4_ID_LEN - 2
        return "c4" + encoded.rjust(body_len, _C4_CHARSET[0])


_FACTORIES = {
    "xxh64": xxhash.xxh64,
    "xxh3": xxhash.xxh3_64,
    "xxh128": xxhash.xxh3_128,
    "md5": hashlib.md5,
    "sha1": hashlib.sha1,
    "sha256": hashlib.sha256,  # client-interop (not ASC MHL formats — receipt/report only)
    "sha512": hashlib.sha512,
    "c4": C4Hasher,
}

SUPPORTED_FORMATS = tuple(_FACTORIES)


def make_hashers(formats):
    unknown = set(formats) - set(_FACTORIES)
    if unknown:
        raise ValueError(f"unsupported hash formats: {sorted(unknown)}")
    return {fmt: _FACTORIES[fmt]() for fmt in formats}


def _validate_relative_path(rel_path):
    """Return safe POSIX components for a descriptor-relative path."""
    if not isinstance(rel_path, str) or not rel_path:
        raise OSError(errno.EINVAL, "relative path is empty or not text")
    try:
        encoded = rel_path.encode("utf-8")
    except UnicodeEncodeError as e:
        raise OSError(errno.EINVAL, "relative path is not valid UTF-8") from e
    if len(encoded) > MAX_RELATIVE_PATH_BYTES:
        raise OSError(errno.ENAMETOOLONG, "relative path exceeds safety limit")
    if "\\" in rel_path or rel_path.startswith("/") or "\x00" in rel_path:
        raise OSError(errno.EINVAL, f"unsafe relative path {rel_path!r}")
    if any(ord(c) < 0x20 for c in rel_path):
        raise OSError(errno.EINVAL, "relative path contains a control character")
    parts = rel_path.split("/")
    if not parts or len(parts) > MAX_RELATIVE_COMPONENTS:
        raise OSError(errno.EINVAL, "relative path has too many components")
    if any(not p or p in (".", "..") for p in parts):
        raise OSError(errno.EINVAL, f"relative path is not canonical: {rel_path!r}")
    return parts


def _open_regular_fd(path, dir_fd=None):
    """Open a regular file without following a symlink or blocking on a FIFO."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                 dir_fd=dir_fd)
    try:
        if not stat_mod.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, "not a regular file", path)
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _same_file_identity(left, right):
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    return all(getattr(left, field, None) == getattr(right, field, None)
               for field in fields)


def _hash_open_fd(fd, formats, chunk_size=CHUNK_SIZE, fd_setup=None,
                  pins=(), leaf_parent_fd=None, leaf_name=None):
    """Hash an already pinned descriptor and prove its names stayed bound."""
    try:
        hashers = make_hashers(formats)
        pre = os.fstat(fd)
    except BaseException:
        os.close(fd)
        raise
    setup_ok = True
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    try:
        f_ctx = os.fdopen(fd, "rb", buffering=0)
    except BaseException:
        # Keep the raw descriptor owned until fdopen successfully transfers
        # that ownership.
        os.close(fd)
        raise
    with f_ctx as f:
        if fd_setup is not None:
            # A false return is evidence that F_NOCACHE (or its platform
            # equivalent) was not established; it must not be presented as a
            # successful cache-bypassed read.
            setup_ok = bool(fd_setup(f.fileno()))
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            for h in hashers.values():
                h.update(chunk)
        # Capture this while fdopen still owns a live descriptor; the
        # context manager closes it immediately after leaving the block.
        post = os.fstat(f.fileno())
    try:
        if not _same_file_identity(pre, post):
            raise OSError(errno.EAGAIN,
                          "file changed while its checksum was being read")
        # A directory component can be renamed and replaced while its open fd
        # still points at the old tree.  Check every canonical name against
        # the descriptor we actually traversed, plus the leaf name.
        for parent_fd, name, child_fd in pins:
            current = os.lstat(name, dir_fd=parent_fd)
            child = os.fstat(child_fd)
            if ((current.st_dev, current.st_ino) != (child.st_dev, child.st_ino)
                    or not stat_mod.S_ISDIR(current.st_mode)):
                raise OSError(errno.EAGAIN,
                              "directory changed while its file was read")
        if leaf_parent_fd is not None:
            current = os.lstat(leaf_name, dir_fd=leaf_parent_fd)
            if ((current.st_dev, current.st_ino) != (post.st_dev, post.st_ino)
                    or not stat_mod.S_ISREG(current.st_mode)):
                raise OSError(errno.EAGAIN,
                              "file name changed while its checksum was read")
    except BaseException:
        raise
    return {fmt: h.hexdigest() for fmt, h in hashers.items()}, setup_ok


def hash_file_with_status(path, formats, chunk_size=CHUNK_SIZE, fd_setup=None):
    """Return ``(hashes, fd_setup_succeeded)`` for a path-based read."""
    fd = _open_regular_fd(path)
    return _hash_open_fd(fd, formats, chunk_size=chunk_size, fd_setup=fd_setup)


def _open_relative_regular(root_fd, rel_path):
    """Open ``rel_path`` beneath a pinned root with O_NOFOLLOW at every hop.

    Returns ``(leaf_fd, owned_fds, pins, leaf_parent_fd, leaf_name)``.  The
    caller closes all descriptors after hashing. Keeping every parent open
    lets the hash pass prove nested directory names were not replaced while
    the read was in flight.
    """
    parts = _validate_relative_path(rel_path)
    owned = [os.dup(root_fd)]
    pins = []
    current = owned[0]
    try:
        for name in parts[:-1]:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=current)
            try:
                child_is_dir = stat_mod.S_ISDIR(os.fstat(child).st_mode)
            except BaseException:
                os.close(child)
                raise
            if not child_is_dir:
                os.close(child)
                raise OSError(errno.ENOTDIR,
                              "relative component is not a directory", name)
            owned.append(child)
            pins.append((current, name, child))
            current = child
        leaf = _open_regular_fd(parts[-1], dir_fd=current)
        return leaf, owned, pins, current, parts[-1]
    except BaseException:
        for fd in reversed(owned):
            try:
                os.close(fd)
            except OSError:
                pass
        raise


def hash_file_at(root_fd, rel_path, formats, chunk_size=CHUNK_SIZE,
                 fd_setup=None):
    """Hash a regular file relative to a pinned directory descriptor.

    No intermediate component follows a symlink, and identity is checked
    before/after the streaming read. Returns ``(hashes, fd_setup_succeeded)``.
    """
    leaf, owned, pins, parent_fd, leaf_name = _open_relative_regular(root_fd,
                                                                       rel_path)
    try:
        return _hash_open_fd(leaf, formats, chunk_size=chunk_size,
                             fd_setup=fd_setup, pins=pins,
                             leaf_parent_fd=parent_fd, leaf_name=leaf_name)
    finally:
        # _hash_open_fd's fdopen closes leaf on normal/error paths. The
        # traversal descriptors are owned by this function.
        for fd in reversed(owned):
            try:
                os.close(fd)
            except OSError:
                pass


def hash_file(path, formats, chunk_size=CHUNK_SIZE):
    """Hash a REGULAR file in one streaming pass.

    The path API remains for existing callers; verifier code uses
    :func:`hash_file_at` so nested path components are descriptor-relative.
    Callers that need fd_setup must use :func:`hash_file_with_status`, which
    returns whether the setup actually took — this wrapper would silently
    discard that bit, the exact overstatement class rounds 10-20 removed.
    """
    hashes, _setup_ok = hash_file_with_status(path, formats,
                                               chunk_size=chunk_size)
    return hashes


def c4_of_file(path) -> str:
    return hash_file(path, ["c4"])["c4"]
