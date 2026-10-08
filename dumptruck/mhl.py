"""MHL manifest emit/read — descriptor-native custody I/O.

Writes BOTH flavors from the same in-memory hash table (zero extra I/O):
- ASC MHL v2.0: ascmhl/ folder with numbered generations + C4-hashed chain file
  (record of truth; what ALEXA 35s write and MediaVerify reads)
- Legacy MHL v1.1: single .mhl in the card folder with <xxhash64be>
  (what the installed base — OffShoot, ShotPut, Silverstack, YoYotta — reads)

Manifests are DESTINATION-SPECIFIC: each card folder's manifest describes what
actually happened at that destination, never an aggregate across destinations.
Generation allocation is O_EXCL + flock-protected so concurrent jobs can't
collide; all writes are fsync'd temp+rename (a crash never truncates a seal).

DESCRIPTOR DISCIPLINE (the round-12 structural pass): every read and write in
this module happens relative to a directory descriptor opened with
O_DIRECTORY|O_NOFOLLOW — a path swapped or symlinked after the caller pinned
its card root can never redirect custody I/O. Public functions accept the
caller's pinned `root_fd`; when omitted (standalone tooling, tests) they open
and own their own NOFOLLOW descriptor for the duration of the call.
"""

import contextlib
import datetime
import errno
import fcntl
import getpass
import os
import re
import socket
import stat as stat_mod
import uuid as uuid_mod
import warnings as warnings_mod
import xml.etree.ElementTree as ET

from . import TOOL_NAME, __version__, hasher, macio
from .ignore import MHL_IGNORE_PATTERNS

ASCMHL_DIR = "ascmhl"
ASCMHL_NS = "urn:ASC:MHL:v2.0"
ASCMHL_CHAIN_NS = "urn:ASC:MHL:DIRECTORY:v2.0"
_CHAIN_NAME = "ascmhl_chain.xml"

# A custody verifier must not let a damaged/untrusted manifest consume
# unbounded memory.  These limits are well above normal camera-card history,
# while making malformed XML and path lists a visible verification failure.
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_CHAIN_BYTES = 8 * 1024 * 1024
MAX_GENERATIONS = 100_000
MAX_MANIFEST_ENTRIES = 1_000_000
MAX_MANIFEST_PATH_BYTES = 4 * 1024
MAX_HASH_TEXT_BYTES = 256


def _reject_dtd(data):
    """Refuse any document carrying a DTD before it reaches the parser.

    The byte caps above bound what we READ, but expat expands internal
    entities at parse time — a small document can balloon to ~100x its size
    in memory before expat's own billion-laughs throttle activates (Ox round
    20, finding M1). ASC MHL documents never carry a DOCTYPE, so any DTD or
    entity declaration is proof of damage or tampering, not a dialect.
    Returns an error string, or None when the document is DTD-free.
    """
    if b"\x00" in data:
        # UTF-16/32 prologs interleave NULs and could smuggle a DOCTYPE past
        # a byte scan; ASC MHL is UTF-8 and camera vendors write UTF-8.
        return ("document contains NUL bytes (non-UTF-8 encoding?) — "
                "refusing to parse")
    for marker in (b"<!DOCTYPE", b"<!ENTITY"):
        if marker in data:
            return ("document declares a DTD/entity — ASC MHL never does; "
                    "refusing to parse untrusted entity expansion")
    return None

# XSD sequence order (xsd/ASCMHL.xsd HashType): c4, md5, sha1, xxh128, xxh3, xxh64.
_HASH_FORMAT_ORDER = ("c4", "md5", "sha1", "xxh128", "xxh3", "xxh64")

# Statuses (per destination) that justify recording a hash in that
# destination's manifest. NEVER "size-only" (fast mode: destination bytes were
# never read — sealing a source hash there lets the next run inherit trust for
# unverified bytes; reproduced by the residual bug-hunt) and NEVER "trusted"
# (already sealed by the prior generation; this run read nothing).
_RECORDABLE = ("verified", "skipped")


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def _iso(dt) -> str:
    return dt.replace(microsecond=0).isoformat()


def _mtime_iso(mtime_ns: int) -> str:
    dt = datetime.datetime.fromtimestamp(mtime_ns / 1e9, datetime.timezone.utc)
    return _iso(dt)


def _indent(elem):
    ET.indent(elem, space="  ")


# ---------------------------------------------------------------------------
# Descriptor plumbing

def _open_dir_fd(name, dir_fd=None):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)


@contextlib.contextmanager
def _root_ctx(card_root, root_fd=None):
    """Yield a pinned card-root descriptor: the caller's, or one owned for the
    duration of this call (standalone tooling/tests)."""
    if root_fd is not None:
        yield root_fd
        return
    fd = _open_dir_fd(card_root)
    try:
        yield fd
    finally:
        os.close(fd)


def _open_mhl_fd(root_fd, create=False):
    """Descriptor for the ascmhl/ folder under a pinned root, or None when it
    does not exist. A symlinked ascmhl/ raises OSError — custody must be a
    self-contained directory, never a redirect."""
    if create:
        # Never return None on the create path: a caller about to take the
        # chain lock must have a real descriptor, or _ChainLock(None) would
        # fall back to dir_fd=None — the process CWD (round-13 finding 1).
        for _ in range(3):
            try:
                os.mkdir(ASCMHL_DIR, 0o755, dir_fd=root_fd)
            except FileExistsError:
                pass
            try:
                return _open_dir_fd(ASCMHL_DIR, dir_fd=root_fd)
            except FileNotFoundError:
                continue  # deleted between mkdir and open — retry
        raise OSError(errno.ENOENT,
                      f"{ASCMHL_DIR}/ keeps disappearing while being created "
                      "— the card folder is being interfered with")
    try:
        return _open_dir_fd(ASCMHL_DIR, dir_fd=root_fd)
    except FileNotFoundError:
        return None


def _mhl_still_bound(root_fd, mhl_fd):
    """True only if the name `ascmhl/` under the pinned root still resolves to
    the very directory inode mhl_fd was opened on. A rename-and-replace after
    the open would otherwise let custody reads/writes continue through the old
    fd while the canonical name points at an impostor (round-13 finding 1)."""
    try:
        cur = os.stat(ASCMHL_DIR, dir_fd=root_fd, follow_symlinks=False)
        pin = os.fstat(mhl_fd)
    except OSError:
        return False
    return (stat_mod.S_ISDIR(cur.st_mode)
            and (cur.st_dev, cur.st_ino) == (pin.st_dev, pin.st_ino))


@contextlib.contextmanager
def _mhl_ctx(card_root, root_fd=None, create=False):
    """Yield (root_fd, mhl_fd|None) with descriptor-only opens throughout."""
    with _root_ctx(card_root, root_fd) as rfd:
        mfd = _open_mhl_fd(rfd, create=create)
        try:
            yield rfd, mfd
        finally:
            if mfd is not None:
                os.close(mfd)


def _open_reg_fd(name, dir_fd=None):
    """Open a REGULAR file read-only relative to dir_fd. O_NONBLOCK makes the
    open itself non-hanging — a FIFO planted in place of a regular file would
    otherwise block open() forever before any fstat could reject it (round-13
    finding 4). The fd is switched back to blocking before it is returned."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        st = os.fstat(fd)
        if not stat_mod.S_ISREG(st.st_mode):
            raise OSError(errno.EINVAL, "custody file is not a regular file", name)
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _fdopen_read(name, dir_fd):
    """Binary reader for a REGULAR file relative to dir_fd; never follows a
    symlink, never hangs on a FIFO, refuses non-regular objects."""
    fd = _open_reg_fd(name, dir_fd=dir_fd)
    try:
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def _write_atomic(root, name, dir_fd):
    """Durable transactional commit relative to dir_fd: unique O_EXCL temp,
    full-fsync, atomic replace, directory full-fsync. A crash never leaves a
    truncated or missing seal, and no step can traverse a symlink."""
    tmp = f"{name}.{os.getpid()}.{uuid_mod.uuid4().hex[:8]}.tmp"
    try:
        wfd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                      0o644, dir_fd=dir_fd)
        try:
            with os.fdopen(wfd, "wb", closefd=False) as f:
                ET.ElementTree(root).write(f, encoding="UTF-8", xml_declaration=True)
                f.flush()
            macio.full_fsync(wfd)
        finally:
            os.close(wfd)
        os.replace(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        macio.full_fsync(dir_fd)
    finally:
        try:
            os.remove(tmp, dir_fd=dir_fd)
        except OSError:
            pass


class _ChainLock:
    """flock over ascmhl/.dumptruck-lock (opened relative to the ascmhl
    descriptor): serializes generation allocation and chain rewrites across
    concurrent jobs on one card folder."""

    def __init__(self, mhl_fd):
        if mhl_fd is None:
            # dir_fd=None means "relative to CWD" — a lock file dropped into
            # whatever directory the process happens to run from.
            raise ValueError("chain lock requires an open ascmhl/ descriptor")
        self._mhl_fd = mhl_fd
        self._fd = None

    def __enter__(self):
        fd = os.open(".dumptruck-lock",
                     os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o644,
                     dir_fd=self._mhl_fd)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except BaseException:
            # The flock failure is the story; a close failure on the way out
            # must never replace it (round-14 finding 6).
            try:
                os.close(fd)
            except OSError:
                pass
            raise
        self._fd = fd
        return self

    def __exit__(self, exc_type, exc, tb):
        fd, self._fd = self._fd, None
        cleanup_err = None
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError as e:
            cleanup_err = e
        try:
            os.close(fd)  # releases the flock even if explicit unlock failed
        except OSError as e:
            if cleanup_err is None:
                cleanup_err = e
        # A body exception outranks cleanup noise: raising here would REPLACE
        # the real failure (round-14 finding 6). Cleanup errors surface only
        # when the protected operation itself succeeded.
        if cleanup_err is not None and exc_type is None:
            raise cleanup_err
        return False


# ---------------------------------------------------------------------------
# Generations / chain primitives (fd-native; thin path wrappers for tooling)

def _generations_fd(mhl_fd):
    if mhl_fd is None:
        return []
    gens = []
    for name in os.listdir(mhl_fd):
        # 4+ digits: allocation zero-pads to a MINIMUM of four, so generation
        # 10000 is a real five-digit name the chain and verifier must not
        # silently ignore (a sealed-but-invisible generation breaks audits).
        m = re.match(r"^(\d{4,})_.*\.mhl$", name)
        if not m:
            continue
        try:
            # lstat + regular-file only: a SYMLINKED "generation" is not
            # self-contained custody evidence. It simply does not count as a
            # generation — if the chain references it, that surfaces as a
            # MISSING-from-disk problem (fail closed), never as valid custody.
            lst = os.lstat(name, dir_fd=mhl_fd)
            if not stat_mod.S_ISREG(lst.st_mode):
                continue
            if lst.st_size == 0:
                continue  # a claimed-but-never-written slot is not a generation
        except OSError:
            continue
        gens.append((int(m.group(1)), name))
    gens = sorted(gens)
    if len(gens) > MAX_GENERATIONS:
        raise RuntimeError(
            f"ascmhl/ contains {len(gens)} generations; safety limit is "
            f"{MAX_GENERATIONS}")
    return gens


def _generations(mhl_dir):
    """Path wrapper (tests/tooling); production callers hold descriptors."""
    try:
        fd = _open_dir_fd(mhl_dir)
    except OSError:
        return []
    try:
        return _generations_fd(fd)
    finally:
        os.close(fd)


def _read_chain_fd(mhl_fd):
    """{generation filename: recorded C4}, {} when absent, or None when the
    chain cannot be trusted structurally. STRICT: a symlinked chain file,
    duplicate rows for one generation, or empty path/C4 fields are custody
    corruption — collapsing duplicates silently laundered a malformed record
    (round-11 finding 6)."""
    if mhl_fd is None:
        return {}
    try:
        f = _fdopen_read(_CHAIN_NAME, mhl_fd)
    except FileNotFoundError:
        return {}
    except OSError:
        return None  # symlink/non-regular/unreadable: custody must be self-contained
    with f:
        try:
            data = f.read(MAX_CHAIN_BYTES + 1)
        except OSError:
            return None
    if len(data) > MAX_CHAIN_BYTES:
        return None
    if _reject_dtd(data):
        return None  # entity-bearing chain is a hard problem, not an empty chain
    try:
        tree = ET.ElementTree(ET.fromstring(data))
    except ET.ParseError:
        return None  # unparseable chain is a hard problem, not an empty chain
    ns = {"c": ASCMHL_CHAIN_NS}
    chain = {}
    for hl in tree.getroot().findall("c:hashlist", ns):
        path = hl.findtext("c:path", namespaces=ns)
        c4 = hl.findtext("c:c4", namespaces=ns)
        if (not path or not c4 or path in chain
                or len(path.encode("utf-8", "ignore")) > MAX_MANIFEST_PATH_BYTES
                or "/" in path or path in (".", "..")
                or any(ord(c) < 0x20 for c in path)
                or len(c4.encode("utf-8", "ignore")) > MAX_HASH_TEXT_BYTES
                or any(ord(c) < 0x20 for c in c4)):
            return None
        chain[path] = c4
        if len(chain) > MAX_GENERATIONS:
            return None
    return chain


def _read_chain(chain_path):
    """Path wrapper (tests/tooling); production callers hold descriptors."""
    mhl_dir = os.path.dirname(chain_path) or "."
    try:
        fd = _open_dir_fd(mhl_dir)
    except OSError:
        return None
    try:
        return _read_chain_fd(fd)
    finally:
        os.close(fd)


def _c4_pinned(name, dir_fd=None):
    """C4 of a file read through ONE O_NOFOLLOW descriptor, with the file's
    identity fstat'd before AND after the read. Returns (c4, sig) where sig is
    None unless: the fd is a regular file, its identity/size/times are
    IDENTICAL before and after hashing, and the name still resolves to that
    very inode afterward. A torn read, a mid-hash replacement, or a symlink
    can therefore never produce a reusable cache entry (round-11 finding 2).
    Raises OSError for unreadable/symlinked/non-regular paths."""
    fd = _open_reg_fd(name, dir_fd=dir_fd)
    try:
        pre = os.fstat(fd)
        h = hasher.make_hashers(["c4"])["c4"]
        while True:
            chunk = os.read(fd, hasher.CHUNK_SIZE)
            if not chunk:
                break
            h.update(chunk)
        post = os.fstat(fd)
        c4 = h.hexdigest()
        ident = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        stable = all(getattr(pre, a) == getattr(post, a) for a in ident)
        sig = None
        if stable:
            try:
                cur = os.lstat(name, dir_fd=dir_fd)
                if (cur.st_dev, cur.st_ino) == (post.st_dev, post.st_ino):
                    sig = (post.st_size, post.st_mtime_ns, post.st_ctime_ns, post.st_ino)
            except OSError:
                sig = None
        return c4, sig
    finally:
        os.close(fd)


def _quarantine_unchained_locked(mhl_fd, names, card_root):
    """Preserve unchained generation evidence under a non-generation name.

    The caller holds _ChainLock and has already proven that the committed
    chain itself is intact. O_EXCL reserves a fresh evidence name so recovery
    never overwrites an earlier quarantine. All I/O is descriptor-relative."""
    moved = []
    for name in sorted(names):
        st = os.lstat(name, dir_fd=mhl_fd)
        if not stat_mod.S_ISREG(st.st_mode) or st.st_size == 0:
            raise RuntimeError(
                f"unchained candidate {name} is not a non-empty regular file; "
                "refusing automatic recovery")
        suffix = 0
        while True:
            tail = ".unchained.quarantine" if suffix == 0 \
                else f".{suffix}.unchained.quarantine"
            target = name + tail
            try:
                os.close(os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY
                                 | os.O_NOFOLLOW, 0o444, dir_fd=mhl_fd))
                break
            except FileExistsError:
                suffix += 1
        try:
            # Replace only the empty name this transaction just claimed.
            os.replace(name, target, src_dir_fd=mhl_fd, dst_dir_fd=mhl_fd)
            macio.full_fsync(mhl_fd)
        except BaseException:
            try:
                tst = os.lstat(target, dir_fd=mhl_fd)
                if stat_mod.S_ISREG(tst.st_mode) and tst.st_size == 0:
                    os.remove(target, dir_fd=mhl_fd)
            except OSError:
                pass
            raise
        moved.append(os.path.join(card_root, ASCMHL_DIR, target))
    return moved


# ---------------------------------------------------------------------------
# ASC MHL v2.0

def write_ascmhl(card_root, file_results, action="original", author=None,
                 warnings=None, root_fd=None):
    """Path-only wrapper around write_ascmhl_bound (tests/standalone tooling
    that does not consume the binding identity)."""
    path, _ident = write_ascmhl_bound(card_root, file_results, action=action,
                                      author=author, warnings=warnings,
                                      root_fd=root_fd)
    return path


def write_ascmhl_bound(card_root, file_results, action="original", author=None,
                       warnings=None, root_fd=None):
    """Append one ASC MHL generation describing THIS card folder; update the
    chain. Only files with a recordable status at this destination (or with no
    per-destination status recorded, e.g. direct engine results) are included.
    Returns (generation_path, ident) — ident is the (st_dev, st_ino) of the
    ascmhl/ directory the generation was sealed into, captured UNDER the chain
    lock after the canonical-name binding check: a caller that samples the
    name AFTER this returns can pin an impostor planted in the gap (round-15
    PR review finding 1 — the same post-return flaw round 14 fixed for
    history loading). (None, None) when there is nothing to record
    (an empty <hashes> is XSD-invalid). All custody I/O runs relative to the
    (caller-pinned or self-opened) card-root descriptor."""
    recordable = []
    for fr in file_results:
        if not fr.hashes:
            continue
        st = fr.dest_status.get(card_root)
        if st is None and fr.dest_status:
            continue  # this file was never destined for this card root
        if st in ("size-only", "trusted"):
            # EXCLUDED, never recorded: size-only means the destination bytes
            # were never read (sealing a source hash would let the next run
            # inherit trust for unverified bytes — reproduced exploit), and
            # trusted means the prior generation already seals it.
            continue
        if st in ("failed", "conflict"):
            file_action = "failed"
        elif st == "skipped":
            # Content-adjudicated skip: we hashed the source AND matched the
            # existing destination copy. It is this history's FIRST record of
            # the path, so ASC semantics call it 'original' (the reference
            # implementation reserves 'verified' for re-checks of an existing
            # record).
            file_action = "original"
        else:
            file_action = action
        recordable.append((fr, file_action))
    if not recordable:
        return None, None

    now = _utc_now()
    folder_name = os.path.basename(os.path.normpath(card_root))

    with _mhl_ctx(card_root, root_fd, create=True) as (_rfd, mhl_fd):
        with _ChainLock(mhl_fd):
            gens = _generations_fd(mhl_fd)
            # A kill between a durable generation write and its chain update
            # leaves an orphan. Validate every COMMITTED chain member first;
            # only then may unreferenced regular generations be quarantined as
            # evidence. They are never read as history or added to the chain.
            # A missing chain means no generation was committed, so all
            # generation files are quarantined and a fresh chain may begin; an
            # unparseable chain still fails closed.
            chain_c4s = {}
            if gens:
                recorded = _read_chain_fd(mhl_fd)
                if recorded is None:
                    raise RuntimeError(
                        "existing ASC MHL custody is broken; refusing to append a new "
                        "generation: chain file unparseable")
                if recorded:
                    unchained = [name for _seq, name in gens if name not in recorded]
                    problems = _verify_chain_fd(mhl_fd, computed=chain_c4s)
                    orphan_problems = {
                        f"generation {name} not present in chain" for name in unchained
                    }
                    hard_problems = [p for p in problems if p not in orphan_problems]
                else:
                    # No committed chain exists: none of these generations can
                    # be trusted or adopted, but preserving them aside is safe.
                    unchained = [name for _seq, name in gens]
                    hard_problems = []
                if hard_problems:
                    raise RuntimeError(
                        "existing ASC MHL custody is broken; refusing to append a new "
                        f"generation: {'; '.join(hard_problems)}")
                if unchained:
                    quarantined = _quarantine_unchained_locked(mhl_fd, unchained,
                                                               card_root)
                    msg = (f"quarantined UNCHAINED generation evidence at {card_root}: "
                           f"{', '.join(os.path.basename(p) for p in quarantined)} "
                           "(interrupted seal; preserved, NOT trusted or blessed)")
                    if warnings is not None:
                        warnings.append(msg)
                    else:
                        warnings_mod.warn(msg, RuntimeWarning, stacklevel=2)
                    gens = _generations_fd(mhl_fd)
            gen = (gens[-1][0] + 1) if gens else 1
            # O_EXCL claim of the generation slot; bump on the (rare)
            # same-second race.
            while True:
                fname = f"{gen:04d}_{folder_name}_{now:%Y-%m-%d_%H%M%S}Z.mhl"
                try:
                    os.close(os.open(fname, os.O_CREAT | os.O_EXCL | os.O_WRONLY
                                     | os.O_NOFOLLOW, 0o644, dir_fd=mhl_fd))
                    break
                except FileExistsError:
                    gen += 1

            mhl_path = os.path.join(card_root, ASCMHL_DIR, fname)
            try:
                _write_generation_locked(mhl_fd, fname, now, recordable,
                                         author, chain_c4s)
                if not _mhl_still_bound(_rfd, mhl_fd):
                    raise RuntimeError(
                        f"{ASCMHL_DIR}/ was renamed or replaced during sealing "
                        "— the sealed generation is not reachable at its "
                        "canonical name")
                pin = os.fstat(mhl_fd)
                return mhl_path, (pin.st_dev, pin.st_ino)
            except BaseException:
                # Never leave a claimed generation behind when the seal did not
                # complete — but NEVER delete a generation the (possibly
                # already committed) chain references: that would manufacture a
                # permanent MISSING-from-disk custody break (round-9 finding 3,
                # inverse).
                try:
                    committed = _read_chain_fd(mhl_fd)
                except Exception:  # noqa: BLE001 — unreadable chain: keep the file
                    committed = None
                if committed is not None and fname not in committed:
                    try:
                        os.remove(fname, dir_fd=mhl_fd)
                    except OSError:
                        pass
                raise


def _write_generation_locked(mhl_fd, fname, now, recordable, author,
                             chain_c4s=None):
    ET.register_namespace("", ASCMHL_NS)
    root = ET.Element(f"{{{ASCMHL_NS}}}hashlist", {"version": "2.0"})

    creator = ET.SubElement(root, f"{{{ASCMHL_NS}}}creatorinfo")
    ET.SubElement(creator, f"{{{ASCMHL_NS}}}creationdate").text = _iso(now)
    ET.SubElement(creator, f"{{{ASCMHL_NS}}}hostname").text = socket.gethostname()
    ET.SubElement(creator, f"{{{ASCMHL_NS}}}tool", {"version": __version__}).text = TOOL_NAME
    a = ET.SubElement(creator, f"{{{ASCMHL_NS}}}author")
    a.text = author or getpass.getuser()

    proc = ET.SubElement(root, f"{{{ASCMHL_NS}}}processinfo")
    ET.SubElement(proc, f"{{{ASCMHL_NS}}}process").text = "transfer"
    ignore = ET.SubElement(proc, f"{{{ASCMHL_NS}}}ignore")
    for pat in MHL_IGNORE_PATTERNS:
        ET.SubElement(ignore, f"{{{ASCMHL_NS}}}pattern").text = pat

    hashes = ET.SubElement(root, f"{{{ASCMHL_NS}}}hashes")
    hashdate = _iso(now)
    for fr, file_action in recordable:
        h = ET.SubElement(hashes, f"{{{ASCMHL_NS}}}hash")
        p = ET.SubElement(
            h,
            f"{{{ASCMHL_NS}}}path",
            {"size": str(fr.size), "lastmodificationdate": _mtime_iso(fr.mtime_ns)},
        )
        p.text = fr.rel_path.replace(os.sep, "/")
        for fmt in _HASH_FORMAT_ORDER:
            if fmt in fr.hashes:
                ET.SubElement(
                    h, f"{{{ASCMHL_NS}}}{fmt}",
                    {"action": file_action, "hashdate": hashdate},
                ).text = fr.hashes[fmt]

    _indent(root)
    _write_atomic(root, fname, mhl_fd)
    _update_chain_locked(mhl_fd, fname, chain_c4s)
    return fname


def _update_chain_locked(mhl_fd, new_generation, precomputed=None):
    """APPEND-ONLY chain update. Existing generations' C4s are carried forward
    VERBATIM from the current chain, never recomputed — recomputing re-blessed
    tampered/rotted generations and permanently erased the evidence (round-3
    finding, reproduced). A generation whose on-disk C4 disagrees with its
    recorded chain entry REFUSES the update loudly. Caller holds the chain lock."""
    recorded = _read_chain_fd(mhl_fd)
    if recorded is None:
        raise RuntimeError(
            f"{_CHAIN_NAME} is unparseable — chain custody is broken; refusing to "
            "reseal. Investigate the card folder before offloading to it again.")
    generations = _generations_fd(mhl_fd)
    on_disk = {name for _seq, name in generations}
    recorded_names = set(recorded)
    unchained = on_disk - recorded_names
    if unchained != {new_generation}:
        unexpected = sorted(unchained - {new_generation})
        detail = (f"unexpected unchained generation(s): {unexpected}"
                  if unexpected else
                  f"new generation {new_generation} is missing from disk")
        raise RuntimeError(
            f"ASC MHL chain is not append-only ({detail}) — refusing to bless "
            "records that were not created by this transaction")
    missing = recorded_names - on_disk
    if missing:
        raise RuntimeError(
            f"ASC MHL chain references missing generation(s): {sorted(missing)} — "
            "refusing to rewrite the chain")

    ET.register_namespace("", ASCMHL_CHAIN_NS)
    root = ET.Element(f"{{{ASCMHL_CHAIN_NS}}}ascmhldirectory")
    for seq, name in generations:
        # Reuse the C4 verify_chain computed moments ago under the same lock
        # hold — but ONLY if the manifest's stat signature is unchanged. The
        # lock serializes cooperative writers, not the rest of the world; a
        # manifest rewritten by an external process between the verify pass
        # and this rewrite must be re-hashed, never re-blessed from cache
        # (round-10 finding 2, reproduced).
        actual = None
        cached = (precomputed or {}).get(name)
        if cached is not None:
            cached_c4, cached_sig = cached
            try:
                st = os.lstat(name, dir_fd=mhl_fd)
                if cached_sig is not None and stat_mod.S_ISREG(st.st_mode) and \
                        (st.st_size, st.st_mtime_ns, st.st_ctime_ns,
                         st.st_ino) == cached_sig:
                    actual = cached_c4
            except OSError:
                actual = None
        if actual is None:
            # Fresh fd-pinned hash; a symlinked/unreadable manifest refuses.
            actual, _sig = _c4_pinned(name, dir_fd=mhl_fd)
        prior = recorded.get(name)
        if prior is not None and prior != actual:
            raise RuntimeError(
                f"generation {name} no longer matches its sealed chain entry "
                "(manifest tampered or rotted) — REFUSING to reseal over the "
                "evidence. Run 'dumptruck verify' and investigate.")
        hl = ET.SubElement(root, f"{{{ASCMHL_CHAIN_NS}}}hashlist", {"sequencenr": str(seq)})
        ET.SubElement(hl, f"{{{ASCMHL_CHAIN_NS}}}path").text = name
        ET.SubElement(hl, f"{{{ASCMHL_CHAIN_NS}}}c4").text = prior if prior is not None else actual
    _indent(root)
    _write_atomic(root, _CHAIN_NAME, mhl_fd)
    return _CHAIN_NAME


# ---------------------------------------------------------------------------
# Legacy MHL v1.1

def write_mhl_v11(card_root, file_results, started_at, finished_at, root_fd=None):
    """Legacy MHL v1.1 sidecar inside the card folder, destination-specific:
    only files that actually succeeded at THIS destination are listed.
    Returns its path, or None with nothing to record. Descriptor-relative."""
    rows = [
        fr for fr in file_results
        if fr.hashes and "xxh64" in fr.hashes
        and (not fr.dest_status or fr.dest_status.get(card_root) in _RECORDABLE)
        # size-only (fast mode) and trusted are deliberately excluded: the
        # legacy manifest must carry the same trust semantics as the ASC one.
    ]
    if not rows:
        return None
    folder_name = os.path.basename(os.path.normpath(card_root))
    now = _utc_now()
    stem = f"{folder_name}_{now:%Y-%m-%d_%H%M%S}"

    with _root_ctx(card_root, root_fd) as rfd:
        suffix = 0
        while True:
            fname = f"{stem}{'' if suffix == 0 else f'_{suffix}'}.mhl"
            try:
                os.close(os.open(fname, os.O_CREAT | os.O_EXCL | os.O_WRONLY
                                 | os.O_NOFOLLOW, 0o644, dir_fd=rfd))
                break
            except FileExistsError:
                suffix += 1

        root = ET.Element("hashlist", {"version": "1.1"})
        creator = ET.SubElement(root, "creatorinfo")
        ET.SubElement(creator, "name").text = getpass.getuser()
        ET.SubElement(creator, "username").text = getpass.getuser()
        ET.SubElement(creator, "hostname").text = socket.gethostname()
        ET.SubElement(creator, "tool").text = f"{TOOL_NAME} {__version__}"
        ET.SubElement(creator, "startdate").text = _iso(
            datetime.datetime.fromtimestamp(started_at, datetime.timezone.utc)
        )
        ET.SubElement(creator, "finishdate").text = _iso(
            datetime.datetime.fromtimestamp(finished_at, datetime.timezone.utc)
        )
        hashdate = _iso(now)
        for fr in rows:
            h = ET.SubElement(root, "hash")
            ET.SubElement(h, "file").text = fr.rel_path.replace(os.sep, "/")
            ET.SubElement(h, "size").text = str(fr.size)
            ET.SubElement(h, "lastmodificationdate").text = _mtime_iso(fr.mtime_ns)
            ET.SubElement(h, "xxhash64be").text = fr.hashes["xxh64"]
            if "md5" in fr.hashes:
                ET.SubElement(h, "md5").text = fr.hashes["md5"]
            if "sha1" in fr.hashes:
                ET.SubElement(h, "sha1").text = fr.hashes["sha1"]
            ET.SubElement(h, "hashdate").text = hashdate

        _indent(root)
        try:
            _write_atomic(root, fname, rfd)
            return os.path.join(card_root, fname)
        except BaseException:
            try:
                os.remove(fname, dir_fd=rfd)
            except OSError:
                pass
            raise


# ---------------------------------------------------------------------------
# Validation / history

def load_validated_history(card_root, root_fd=None):
    """verify_chain + read_ascmhl_history as ONE atomic snapshot under the
    chain lock, all descriptor-relative.
    Returns (problems, history); history is {} whenever problems is non-empty."""
    problems, history, _ident = load_validated_history_bound(card_root,
                                                             root_fd=root_fd)
    return (problems, history)


def load_validated_history_bound(card_root, root_fd=None):
    """load_validated_history plus the validated ascmhl/ directory's identity.
    Taken separately, a concurrent writer can publish a generation between the
    validation and the read — handing the reader a merged history containing
    records the chain never blessed (and if that writer's chain update then
    fails, records that never WILL be).
    Returns (problems, history, ident): ident is the (st_dev, st_ino) of the
    VERY directory this trust was read from, captured under the same lock —
    the caller re-checks it before acting on the trust, because a token
    captured after this call returns could already name an impostor
    (round-14 finding 1). ident is None whenever problems is non-empty."""
    try:
        with _mhl_ctx(card_root, root_fd) as (_rfd, mhl_fd):
            if not _generations_fd(mhl_fd):
                return ([f"no {ASCMHL_DIR}/ generations found"], {}, None)
            with _ChainLock(mhl_fd):
                problems = _verify_chain_fd(mhl_fd)
                if problems:
                    return (problems, {}, None)
                try:
                    history = _read_history_fd(mhl_fd, card_root)
                except (FileNotFoundError, RuntimeError, OSError, ET.ParseError,
                        ValueError, TypeError, AttributeError, KeyError) as e:
                    return ([f"sealed history unreadable: {e}"], {}, None)
                if not _mhl_still_bound(_rfd, mhl_fd):
                    return ([f"{ASCMHL_DIR}/ was renamed or replaced while its "
                             "history was being read — not trusted"], {}, None)
                pin = os.fstat(mhl_fd)
                return ([], history, (pin.st_dev, pin.st_ino))
    except (RuntimeError, OSError) as e:
        return ([f"sealed history unreadable: {e}"], {}, None)


def _verify_chain_fd(mhl_fd, computed=None):
    gens = _generations_fd(mhl_fd)
    if not gens:
        return [f"no {ASCMHL_DIR}/ generations found"]
    chain = _read_chain_fd(mhl_fd)
    if chain is None:
        return ["chain file unparseable"]
    if not chain:
        return ["ascmhl_chain.xml missing — generation manifests cannot be trusted"]
    problems = []
    on_disk = {name for _seq, name in gens}
    for _seq, name in gens:
        expected = chain.get(name)
        if expected is None:
            problems.append(f"generation {name} not present in chain")
            continue
        try:
            # One O_NOFOLLOW fd, identity fstat'd before and after the read:
            # symlinked custody refuses, and a manifest replaced or rewritten
            # DURING hashing can never yield a reusable cache entry
            # (round-10 finding 2 + round-11 findings 2/4).
            actual, sig = _c4_pinned(name, dir_fd=mhl_fd)
        except OSError as e:
            problems.append(f"generation {name} unreadable as self-contained "
                            f"custody ({e}) — refused")
            continue
        if computed is not None:
            computed[name] = (actual, sig)
        if actual != expected:
            problems.append(f"generation {name} C4 MISMATCH — manifest tampered or rotted")
    # Reverse direction: every chain entry must still exist, non-truncated —
    # a deleted or zeroed generation (and the files only it sealed) must never
    # pass a completeness audit (round-3 finding).
    for name in chain:
        if name not in on_disk:
            try:
                lst = os.lstat(name, dir_fd=mhl_fd)
                if not stat_mod.S_ISREG(lst.st_mode):
                    problems.append(
                        f"generation {name} recorded in chain is NOT a regular file")
                else:
                    problems.append(
                        f"generation {name} recorded in chain is TRUNCATED/empty")
            except OSError:
                problems.append(
                    f"generation {name} recorded in chain is MISSING from disk")
    return problems


def verify_chain(card_root, computed=None, root_fd=None):
    """Validate every generation manifest's C4 against the chain file.
    Returns a list of problems (empty = chain intact). Missing chain with
    existing generations is itself a problem. If `computed` is a dict, it is
    filled with {generation_name: (c4, sig)} for every manifest hashed here so
    an appender can revalidate-and-reuse them instead of re-hashing the whole
    chain (round-9 finding 7, hardened in rounds 10-11)."""
    try:
        with _mhl_ctx(card_root, root_fd) as (_rfd, mhl_fd):
            if mhl_fd is None:
                return [f"no {ASCMHL_DIR}/ generations found"]
            problems = _verify_chain_fd(mhl_fd, computed=computed)
            if not _mhl_still_bound(_rfd, mhl_fd):
                problems = list(problems) + [
                    f"{ASCMHL_DIR}/ was renamed or replaced during verification"]
            return problems
    except (OSError, RuntimeError) as e:
        return [f"{ASCMHL_DIR}/ is not a self-contained directory ({e}) — refused"]


def _read_history_fd(mhl_fd, card_root):
    gens = _generations_fd(mhl_fd)
    if not gens:
        raise FileNotFoundError(f"no {ASCMHL_DIR}/ generations in {card_root}")
    ns = {"m": ASCMHL_NS}
    files = {}
    total_entries = 0
    for seq, name in gens:
        try:
            with _fdopen_read(name, mhl_fd) as f:
                data = f.read(MAX_MANIFEST_BYTES + 1)
        except ET.ParseError as e:
            raise RuntimeError(
                f"generation manifest {name} is unparseable — the card's history "
                f"is corrupt or tampered ({e}); refuse to trust it") from e
        except OSError as e:
            raise RuntimeError(
                f"generation manifest {name} could not be read — refuse to trust "
                f"the card's history ({e})") from e
        if len(data) > MAX_MANIFEST_BYTES:
            raise RuntimeError(
                f"generation manifest {name} exceeds the {MAX_MANIFEST_BYTES}-byte "
                "safety limit — refuse to trust the card's history")
        if (dtd_problem := _reject_dtd(data)):
            raise RuntimeError(
                f"generation manifest {name}: {dtd_problem}")
        try:
            tree = ET.ElementTree(ET.fromstring(data))
        except ET.ParseError as e:
            raise RuntimeError(
                f"generation manifest {name} is unparseable — the card's history "
                f"is corrupt or tampered ({e}); refuse to trust it") from e
        root = tree.getroot()
        if root.tag != f"{{{ASCMHL_NS}}}hashlist":
            raise RuntimeError(
                f"generation manifest {name} has an unexpected root element")
        hashes_el = root.find("m:hashes", ns)
        if hashes_el is None:
            raise RuntimeError(
                f"generation manifest {name} has no hashes element")
        for h in tree.getroot().findall("m:hashes/m:hash", ns):
            total_entries += 1
            if total_entries > MAX_MANIFEST_ENTRIES:
                raise RuntimeError(
                    f"sealed history exceeds the {MAX_MANIFEST_ENTRIES}-entry "
                    "safety limit")
            p = h.find("m:path", ns)
            if p is None or not p.text:
                raise RuntimeError(
                    f"generation manifest {name} contains a hash record without a path")
            rel = p.text
            try:
                encoded_rel = rel.encode("utf-8")
            except UnicodeEncodeError as e:
                raise RuntimeError(
                    f"generation manifest {name} has a non-UTF-8 path") from e
            norm = os.path.normpath(rel)
            components = rel.split("/")
            # A path that escapes (or merely normalizes to another spelling)
            # is manifest corruption.  Silently omitting it would make a
            # malicious manifest look like a smaller, complete card.
            if (len(encoded_rel) > MAX_MANIFEST_PATH_BYTES
                    or os.path.isabs(rel)
                    or norm != rel
                    or not components
                    or any(not c or c in (".", "..") for c in components)
                    or "\\" in rel
                    or "\x00" in rel
                    or any(ord(c) < 0x20 for c in rel)
                    or norm == "." or norm.startswith("../") or norm == ".."):
                raise RuntimeError(
                    f"generation manifest {name} contains an escaping or malformed "
                    f"path {rel!r}; refuse to trust the card's history")
            try:
                size = int(p.get("size", "-1"))
            except (TypeError, ValueError) as e:
                raise RuntimeError(
                    f"generation manifest {name} has an invalid size for {rel!r}") from e
            if size < 0:
                raise RuntimeError(
                    f"generation manifest {name} has a negative size for {rel!r}")
            entry = {"size": size, "hashes": {}, "generation": seq}
            failed = False
            for fmt in _HASH_FORMAT_ORDER:
                elements = h.findall(f"m:{fmt}", ns)
                if len(elements) > 1:
                    raise RuntimeError(
                        f"generation manifest {name} repeats {fmt} for {rel!r}")
                if not elements:
                    continue
                el = elements[0]
                if (not el.text or len(el.text.encode("utf-8", "ignore"))
                        > MAX_HASH_TEXT_BYTES
                        or any(ord(c) < 0x20 for c in el.text)):
                    raise RuntimeError(
                        f"generation manifest {name} has malformed {fmt} for {rel!r}")
                entry["hashes"][fmt] = el.text
                if el.get("action") == "failed":
                    failed = True
            if failed:
                continue
            files[rel] = entry
    if total_entries > 0 and not files:
        raise RuntimeError(
            "sealed history contains no usable hash records; refuse to trust it")
    return files


def read_ascmhl_history(card_root, root_fd=None):
    """Merge every generation, oldest to newest (later generations win per path)
    — but a 'failed' record never replaces a prior good one (a refused
    filename-reuse attempt must not poison the authoritative expected content).
    Rejects path traversal in manifest entries.
    Returns {rel_path: {"size": int, "hashes": {fmt: hex}, "generation": int}}."""
    with _mhl_ctx(card_root, root_fd) as (_rfd, mhl_fd):
        if mhl_fd is None:
            raise FileNotFoundError(f"no {ASCMHL_DIR}/ generations in {card_root}")
        return _read_history_fd(mhl_fd, card_root)
