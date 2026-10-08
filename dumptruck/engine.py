"""Fan-out offload engine: read the source once, write to N destinations,
hash on the fly, verify with cache-honest re-reads.

Per file:

    reader thread ──> per-destination bounded queues ──> writer threads
         └─> hashers (xxh64 always; extras on the same buffer)

Writers set F_NOCACHE before the first byte so the verify re-read is a real
device read, and F_FULLFSYNC before close so bytes reach media, not the drive
cache. Writers commit (rename into place) ONLY on an explicit commit sentinel
carrying the expected byte count; any abort removes the partial. Verification
re-reads each destination copy and compares hashes.

Duplicate policy (bug-hunt hardened): size+mtime is only a prefilter. A file
is skipped as "already offloaded" only when the destination's own ASC MHL
history records that exact path+size — i.e. it was hash-verified by a prior
sealed generation. Anything else with a same-name file at the destination is
adjudicated by content hash and NEVER overwritten.
"""

import ctypes
import contextlib
import errno
import fcntl
import os
import queue
import signal
import stat as stat_mod
import threading
import time
import unicodedata
from dataclasses import dataclass, field

from . import hasher, macio
from .ignore import is_junk

# Chunks in flight per destination. 32 x 4 MiB = 128 MiB of write buffer per
# drive: enough to ride out transient destination hiccups (exFAT metadata
# flushes, drive-cache stalls) without pausing the shared card read — the
# reader stalling on a full queue is the #1 avoidable throughput loss in the
# fan-out design (Joshua's speed pass, 2026-08-21). Memory stays bounded:
# 2 dests = 256 MiB peak.
QUEUE_DEPTH = 32

ASCMHL_DIRNAME = "ascmhl"
CAMERA_MHL_QUARANTINE = "ascmhl_camera"


class _Commit:
    def __init__(self, expected_bytes):
        self.expected_bytes = expected_bytes


_ABORT = object()


@dataclass
class FileEntry:
    rel_path: str
    size: int
    mtime_ns: int


@dataclass
class FileResult:
    rel_path: str
    size: int
    mtime_ns: int
    hashes: dict = field(default_factory=dict)  # fmt -> hex (from source read)
    skipped: bool = False  # trusted from a prior verified generation everywhere
    dest_status: dict = field(default_factory=dict)  # card_root -> status
    errors: list = field(default_factory=list)

    def outcome(self) -> str:
        if self.skipped:
            return "skipped"
        if not self.dest_status:
            return "failed"
        statuses = set(self.dest_status.values())
        if "failed" in statuses:
            return "failed"
        if "conflict" in statuses:
            return "conflict"
        if "size-only" in statuses:
            return "size-only"
        if statuses <= {"skipped", "trusted"}:
            return "skipped"
        return "verified"


@dataclass
class OffloadResult:
    label: str
    source: str
    destinations: list
    files: list = field(default_factory=list)  # FileResult
    started_at: float = 0.0
    finished_at: float = 0.0
    verify_mode: str = "full"
    verify_schedule: str = "overlap"
    source_reread_ok: bool | None = None
    errors: list = field(default_factory=list)
    warnings: list = field(default_factory=list)
    trusted_prior_files: int = 0
    io_nocache_all: bool = True   # every write fd got F_NOCACHE(_EXT)
    io_flush_all: bool = True     # every write fd got F_FULLFSYNC
    io_verify_nocache_all: bool = True
    source_grew_after_scan: bool = False  # new files appeared mid-job
    uncopied_source_objects: int = 0      # symlinks etc. deliberately not copied
    camera_history_failed: bool = False   # camera ascmhl/ preservation failed
    identity_failed_roots: list = field(default_factory=list)  # mount swapped mid-job
    # Physical topology SNAPSHOT, taken while the root descriptors were pinned:
    # {card_root: frozenset(disks) | UNKNOWN_DEVICE}. attestation() consumes
    # ONLY this — re-resolving live paths after the pinned lifetime let a
    # post-run volume swap fabricate a second "independent device"
    # (round-10 CRITICAL, reproduced).
    physical_stores_by_root: dict = field(default_factory=dict)
    manifests: list = field(default_factory=list)  # sealed inside the pinned lifetime
    # ascmhl/ (dev, ino) per root, captured when trusted history was loaded:
    # sealing re-checks it so the custody directory consumed for trust is
    # PROVABLY the one still at the canonical name when success is reported
    # (round-14 finding 1 — the in-call binding checks did not span the
    # engine's consumption of what they validated).
    history_binding_by_root: dict = field(default_factory=dict)
    # Loose files staged by the GUI as a folder of clones. The originals are
    # not a card and stay where they are, so the wipe verdict is never
    # authorized no matter how clean the copy was.
    loose_files: bool = False

    @property
    def ok(self) -> bool:
        if self.errors:
            return False
        return all(
            f.outcome() in ("verified", "size-only", "skipped") for f in self.files
        )

    @property
    def fully_verified(self) -> bool:
        return self.ok and self.verify_mode == "full" and self.source_reread_ok is not False

    def attestation(self) -> dict:
        """Machine-readable record of exactly what was proven — never one green
        word. (Copy integrity only; codec validity is a different layer.)"""
        verified_roots = []
        card_roots = []
        seen = set()
        for d in self.destinations:
            cr = os.path.join(d, self.label)
            if cr in seen:
                continue  # duplicate destination is not a second copy
            seen.add(cr)
            card_roots.append(cr)
        # A destination is an independently verified copy only when EVERY
        # file on it was read this run: 'verified' (written + read back) or
        # 'skipped' (content-adjudicated: cold read + hash match). A single
        # 'trusted' status means bytes on that destination were accepted
        # from recorded history without being read, and the R3-06 round-3
        # reproduction planted a corrupt copy exactly there. One trusted
        # file therefore disqualifies the whole destination, and a pure
        # continuation (everything trusted) verifies nothing.
        for cr in card_roots:
            statuses = [f.dest_status.get(cr) for f in self.files if not f.skipped]
            if (statuses and not any(f.skipped for f in self.files)
                    and all(s in ("verified", "skipped") for s in statuses)):
                verified_roots.append(cr)
        # Two volumes on one SSD/RAID are ONE copy: count PHYSICAL devices,
        # and unknown topology counts as zero (fail closed). Fused/RAID
        # containers report SETS of member disks — destinations whose store
        # sets intersect at all share hardware and merge into one group
        # (pairwise-disjoint groups are the only independent copies).
        groups: list[set] = []
        for cr in verified_roots:
            # ONLY the pinned-lifetime snapshot: a live re-resolve here would
            # attest whatever volume sits at the path NOW, not the one that
            # received the verified bytes. Missing snapshot = fail closed.
            stores = self.physical_stores_by_root.get(cr, macio.UNKNOWN_DEVICE)
            if stores == macio.UNKNOWN_DEVICE or not stores:
                continue  # unverifiable topology earns zero independence
            merged = set(stores)
            keep = []
            for g in groups:
                if g & merged:
                    merged |= g
                else:
                    keep.append(g)
            keep.append(merged)
            groups = keep
        devices = groups
        # Wipe authorization demands MAXIMUM evidence (coverage-audit gaps):
        # a consistent SECOND source read, honest cache/flush syscalls, a
        # source tree that did not grow after scanning, and 2+ real devices.
        safe = (
            self.fully_verified
            and len(devices) >= 2
            and self.source_reread_ok is True
            and self.io_nocache_all
            and self.io_flush_all
            and self.io_verify_nocache_all
            and not self.source_grew_after_scan
            and self.uncopied_source_objects == 0
            and not self.camera_history_failed
            and self.trusted_prior_files == 0
            and not self.loose_files
        )
        blockers = []
        if self.loose_files:
            blockers.append("loose files: the originals are not a card, nothing to wipe")
        if not self.fully_verified:
            blockers.append("copy is not fully verified")
        if len(devices) < 2:
            if not verified_roots and self.trusted_prior_files:
                # Nothing was fully read: say that, not "0 devices", which
                # reads as unknown topology (round-3 fix review, R3-06-B).
                blockers.append("no destination copy was fully read this run")
            else:
                blockers.append(
                    f"copies span only {len(devices)} known physical device(s); 2+ required")
        if self.source_reread_ok is not True:
            blockers.append("no consistent second source read this run")
        if not self.io_nocache_all:
            blockers.append("cache bypass failed on at least one destination write")
        if not self.io_verify_nocache_all:
            blockers.append("cache bypass failed on at least one destination verify read")
        if not self.io_flush_all:
            blockers.append("full flush-to-media failed on at least one destination file")
        if self.source_grew_after_scan:
            blockers.append("source tree changed after the initial scan")
        if self.uncopied_source_objects:
            blockers.append(
                f"{self.uncopied_source_objects} source object(s) were not copied")
        if self.camera_history_failed:
            blockers.append("camera-written MHL custody was not preserved consistently")
        if self.trusted_prior_files:
            # Trusted-prior files were accepted on metadata + recorded history
            # alone: zero bytes of them were read this run, and the recorded
            # hash was never compared against anything. That is honest evidence
            # for "the copy exists" but NOT for wipe authorization — the core
            # promise is byte-verified copies. Counted per file when ANY
            # destination trusted it (round-3 R3-06: a file trusted on one
            # drive and freshly copied to the other was counted nowhere).
            blockers.append(
                f"{self.trusted_prior_files} file(s) accepted on prior-"
                "generation trust on at least one destination without "
                "re-verification this run (--reverify-existing re-reads them)")
        # Honest read count: 2 only when the second full pass ran, 1 when at
        # least one source byte was hashed this run, 0 for pure-trust runs
        # in which the source was never read at all.
        hashed_any = any(f.hashes for f in self.files)
        return {
            "source_read_count": (2 if self.source_reread_ok is not None
                                  else (1 if hashed_any else 0)),
            "destination_readback": self.verify_mode == "full",
            "verify_schedule": self.verify_schedule,
            "write_fd_nocache": self.io_nocache_all,
            "verify_fd_nocache": self.io_verify_nocache_all,
            "full_flush_before_close": self.io_flush_all,
            "source_reread_consistent": self.source_reread_ok,
            "source_grew_after_scan": self.source_grew_after_scan,
            "uncopied_source_objects": self.uncopied_source_objects,
            "codec_validation": "not performed",
            "files_trusted_from_prior_generations": self.trusted_prior_files,
            "independently_verified_destinations": len(verified_roots),
            "distinct_physical_devices": len(devices),
            "safe_to_wipe_source": safe,
            "safe_to_wipe_blockers": blockers,
        }


def scan_source(source_root):
    """Walk the source, junk-filtered, deterministic order.
    Returns ([FileEntry], [dir rel paths], [warnings]).
    - Raises on a missing/unreadable root or any traversal error (a vanished
      card must never look like an empty, fully-verified one).
    - Symlinks are skipped LOUDLY via warnings, never silently pruned or
      dereferenced (type changes falsify the tree).
    - ascmhl/ history folders are pruned here; the engine quarantine-copies
      them separately (they are history, not media)."""
    source_root = os.path.abspath(source_root)
    if not os.path.isdir(source_root):
        raise RuntimeError(f"source is not a readable directory: {source_root}")

    def _onerror(err):
        raise RuntimeError(f"source traversal failed at {getattr(err, 'filename', '?')}: {err}")

    entries, dirs, warnings = [], [], []
    for dirpath, dirnames, filenames in os.walk(source_root, onerror=_onerror):
        at_root = os.path.normpath(dirpath) == os.path.normpath(source_root)
        kept = []
        for d in sorted(dirnames):
            full = os.path.join(dirpath, d)
            if is_junk(d):
                continue
            if os.path.islink(full):
                warnings.append(f"symlinked directory skipped (not followed): "
                                f"{os.path.relpath(full, source_root)}")
                continue
            if at_root and d == ASCMHL_DIRNAME:
                continue  # root camera history is quarantined separately
            kept.append(d)
        dirnames[:] = kept
        for d in kept:
            dirs.append(os.path.relpath(os.path.join(dirpath, d), source_root))
        for name in sorted(filenames):
            if is_junk(name):
                continue
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                warnings.append(f"symlink skipped (would change type if copied): "
                                f"{os.path.relpath(full, source_root)}")
                continue
            try:
                st = os.stat(full)
            except OSError as e:
                raise RuntimeError(f"cannot stat source file {full}: {e}") from e
            rel = os.path.relpath(full, source_root)
            import stat as _stat
            if not _stat.S_ISREG(st.st_mode):
                warnings.append(f"non-regular file skipped (FIFO/socket/device): {rel}")
                continue
            if any(ord(c) < 32 for c in rel):
                warnings.append(f"file skipped: name contains control characters "
                                f"(unsealable in XML manifests): {rel!r}")
                continue
            entries.append(FileEntry(rel_path=rel, size=st.st_size, mtime_ns=st.st_mtime_ns))
    return entries, dirs, warnings


def _load_history(card_root, warn=None, root_fd=None):
    """Load the sealed history a trusted skip may rest on — but ONLY after the
    chain validates, and only as ONE atomic snapshot under the chain lock
    (validate-then-read as two unlocked steps let a concurrent writer slip an
    un-blessed generation into trusted history), and — round 12 — only through
    the caller's PINNED root descriptor. A tampered/rotted/incomplete chain
    grants zero trust."""
    from . import mhl
    try:
        problems, history, ident = mhl.load_validated_history_bound(
            card_root, root_fd=root_fd)
    except OSError as e:
        problems, history, ident = [f"chain unreadable: {e}"], {}, None
    if problems:
        real = [p for p in problems if "no ascmhl/ generations" not in p]
        if real and warn:
            warn(f"{card_root}: sealed history NOT trusted this run: {'; '.join(real)}")
        return {}, None
    return history, ident


# ---------------------------------------------------------------------------
# Descriptor-pinned destination I/O.
#
# Path-based writes are open to a TOCTOU attack the preflight walk cannot
# close: a directory inside the card folder is swapped for a symlink AFTER
# preflight, and every subsequent open/verify/rename follows it — two
# "verified copies" that are really the source itself (round-7 reproduced).
# Every destination open, verify read, and commit therefore goes through
# directory descriptors walked one component at a time with O_NOFOLLOW.

def _open_dir_nofollow(name, dir_fd=None):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dir_fd)


def _secure_leaf_fd(root_fd, rel_dir):
    """Walk rel_dir from root_fd one component at a time (O_NOFOLLOW at every
    step) and return a descriptor for the leaf directory; caller closes it.
    Raises OSError if any component is a symlink, not a directory, or gone."""
    components = [c for c in rel_dir.split(os.sep) if c and c != "."]
    if any(c == ".." for c in components):
        raise OSError(errno.EINVAL, "destination path escapes its pinned root", rel_dir)
    fd = os.dup(root_fd)
    try:
        for comp in components:
            nfd = _open_dir_nofollow(comp, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _ensure_dir_tree(root_fd, rel_dir):
    """Create/open a relative directory tree without following a symlink at
    any component. Returns an owned descriptor for the leaf."""
    components = [c for c in rel_dir.split(os.sep) if c and c != "."]
    if any(c == ".." for c in components):
        raise OSError(errno.EINVAL, "destination path escapes its pinned root", rel_dir)
    fd = os.dup(root_fd)
    try:
        for comp in components:
            try:
                os.mkdir(comp, dir_fd=fd)
            except FileExistsError:
                pass
            nfd = _open_dir_nofollow(comp, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def _assert_no_symlinks_fd(root_fd, rel="", subtree=None):
    """Fail closed if a pinned destination tree contains any symlink.
    Traversal itself is descriptor-relative so a path swap cannot redirect the
    audit outside the card root. An entry that VANISHES between listdir and
    stat is skipped — a gone entry cannot be a symlink, and third-party churn
    (Spotlight, Finder dotfiles) must not abort a job (round-9 finding 5).
    subtree, if given, restricts the audit to that top-level directory."""
    for name in sorted(os.listdir(root_fd)):
        if subtree is not None and not rel and name != subtree:
            continue
        try:
            st = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        child = os.path.join(rel, name) if rel else name
        if stat_mod.S_ISLNK(st.st_mode):
            raise RuntimeError(
                f"symlink inside the card folder: {child} — a link here can "
                "redirect verified copies outside the destination. Refused.")
        if stat_mod.S_ISDIR(st.st_mode):
            try:
                child_fd = _open_dir_nofollow(name, dir_fd=root_fd)
            except FileNotFoundError:
                continue
            try:
                _assert_no_symlinks_fd(child_fd, child)
            finally:
                os.close(child_fd)


def _remove_stale_partials_fd(root_fd, partial_re, result, rel=""):
    """Remove only Dumptruck's exact partial suffixes beneath a pinned root."""
    for name in sorted(os.listdir(root_fd)):
        try:
            st = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue  # vanished mid-walk: nothing to clean
        child = os.path.join(rel, name) if rel else name
        if stat_mod.S_ISDIR(st.st_mode):
            try:
                child_fd = _open_dir_nofollow(name, dir_fd=root_fd)
            except FileNotFoundError:
                continue
            try:
                _remove_stale_partials_fd(child_fd, partial_re, result, child)
            finally:
                os.close(child_fd)
        elif stat_mod.S_ISREG(st.st_mode) and partial_re.search(name):
            try:
                os.remove(name, dir_fd=root_fd)
                result.warnings.append(
                    f"removed stale partial from an interrupted run: {child}")
            except OSError:
                pass


def _metadata_match_at(dir_fd, name, entry):
    """Descriptor-relative metadata prefilter; never follows the final name."""
    try:
        st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    if not stat_mod.S_ISREG(st.st_mode) or st.st_size != entry.size:
        return False
    return abs(st.st_mtime_ns - entry.mtime_ns) < 10_000_000


_RENAME_EXCL = 0x4  # sys/stdio.h RENAME_EXCL
_libc = ctypes.CDLL(None, use_errno=True) if macio.IS_MACOS else None


def _commit_noreplace(dir_fd, tmp_name, final_name):
    """Rename tmp -> final REFUSING to replace an existing file. A file that
    appears at the final path after adjudication must surface as a collision,
    never be silently clobbered (round-7 reproduced). renameatx_np(RENAME_EXCL)
    where the filesystem supports it; elsewhere (e.g. exFAT) a NOFOLLOW
    existence check narrows the window — exFAT cannot hold symlinks, and
    adjudication has already run, so the residue is a benign moment."""
    if _libc is not None:
        ctypes.set_errno(0)
        r = _libc.renameatx_np(dir_fd, os.fsencode(tmp_name),
                               dir_fd, os.fsencode(final_name), _RENAME_EXCL)
        if r == 0:
            return
        err = ctypes.get_errno()
        if err == errno.EEXIST:
            raise FileExistsError(errno.EEXIST,
                                  "file appeared at the final path after adjudication",
                                  final_name)
        if err not in (errno.ENOTSUP, errno.EINVAL):
            raise OSError(err, os.strerror(err), final_name)
    try:
        os.stat(final_name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise FileExistsError(errno.EEXIST,
                              "file appeared at the final path after adjudication",
                              final_name)
    os.rename(tmp_name, final_name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)


class _DestWriter(threading.Thread):
    def __init__(self, dest_file, entry, root_fd, rel_path):
        super().__init__(daemon=True)
        self.dest_file = dest_file  # absolute, for reporting only
        self.entry = entry
        self.root_fd = root_fd      # pinned card-root descriptor (shared, dir_fd use only)
        self.rel_dir = os.path.dirname(rel_path)
        self.final_name = os.path.basename(rel_path)
        self.q = queue.Queue(maxsize=QUEUE_DEPTH)
        self.error = None
        self.got_sentinel = False  # drain must not wait for a sentinel already consumed
        self.tmp_path = None       # absolute, for reporting only
        self.tmp_name = None       # basename, valid relative to leaf_fd
        self.leaf_fd = None        # ownership passes to the verify task on success
        self.nocache_ok = False
        self.flush_ok = False

    def _write_all(self, fd, chunk):
        mv = memoryview(chunk)
        while mv:
            n = os.write(fd, mv)
            if n <= 0:
                raise OSError(28, "zero-length write (destination full?)")
            mv = mv[n:]

    def run(self):
        # The writer STAGES the file: it never renames into place. The engine
        # verifies the staged temp and only then commits it — a copy that fails
        # its checksum must never exist at the final path (round-3 finding:
        # post-rename verification left dumptruck's own bad copies looking like
        # name collisions on the next run).
        self.tmp_name = (f"{self.final_name}.dumptruck-partial-"
                         f"{os.getpid()}-{threading.get_ident()}")
        self.tmp_path = f"{self.dest_file}.dumptruck-partial-{os.getpid()}-{threading.get_ident()}"
        fd = None
        written = 0
        staged = False
        try:
            # Descriptor-pinned: every component NOFOLLOW-walked from the
            # pinned card root. The tree was created at preflight — a missing
            # or symlinked component here is tampering, and fails loudly.
            self.leaf_fd = _secure_leaf_fd(self.root_fd, self.rel_dir)
            fd = os.open(self.tmp_name,
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o644, dir_fd=self.leaf_fd)
            self.nocache_ok = macio.setup_dest_write_fd(fd)
            while True:
                item = self.q.get()
                if item is _ABORT:
                    self.got_sentinel = True
                    raise OSError(5, "aborted: source read failed or changed mid-copy")
                if isinstance(item, _Commit):
                    self.got_sentinel = True
                    if written != item.expected_bytes:
                        raise OSError(5, f"short write: {written} of {item.expected_bytes} bytes")
                    break
                self._write_all(fd, item)
                written += len(item)
            self.flush_ok = macio.full_fsync(fd)
            os.close(fd)
            fd = None
            os.utime(self.tmp_name, ns=(self.entry.mtime_ns, self.entry.mtime_ns),
                     dir_fd=self.leaf_fd)
            staged = True
        except BaseException as e:  # noqa: BLE001 — a dead writer must never deadlock the reader
            self.error = e
        finally:
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
            if not staged and self.leaf_fd is not None:
                try:
                    os.remove(self.tmp_name, dir_fd=self.leaf_fd)
                except OSError:
                    pass
                try:
                    os.close(self.leaf_fd)
                except OSError:
                    pass
                self.leaf_fd = None
            # Drain so the reader never blocks on a dead writer — but ONLY
            # until the sentinel we have NOT yet consumed. A writer whose
            # error was raised BY the sentinel must never wait for a second
            # one that will never come (reproduced deadlock).
            if self.error is not None and not self.got_sentinel:
                while True:
                    try:
                        item = self.q.get_nowait()
                        if item is _ABORT or isinstance(item, _Commit):
                            break
                    except queue.Empty:
                        if not threading.main_thread().is_alive():
                            break
                        time.sleep(0.005)


@contextlib.contextmanager
def _defer_sigint():
    """Finish thread cleanup before delivering Ctrl-C on the main thread."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = signal.getsignal(signal.SIGINT)
    if not callable(previous):
        yield
        return
    pending = []
    signal.signal(signal.SIGINT, lambda signum, frame: pending.append((signum, frame)))
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, previous)
        if pending:
            previous(*pending[0])


def _copy_one(source_file, entry, dest_specs, hash_formats, progress,
              source_fd=None, src_rel=None, staged_out=None):
    """Read source once; hash + fan out. dest_specs = [(dest_file, root_fd)].
    Commits writers only when the byte count matches the scan snapshot and the
    source stayed stable. Returns (hashes|None,
    {dest_file: (error, tmp_name, leaf_fd)}, source_error|None, io_flags).
    With source_fd, the source opens through a NOFOLLOW component walk from
    that pinned descriptor (src_rel relative to it; defaults to
    entry.rel_path) — a path swapped mid-job can never redirect the read
    (round-12 structural pass). staged_out, if supplied, receives ownership
    before the writer drain delivers any deferred interrupt."""
    hashers = hasher.make_hashers(hash_formats)  # may raise: BEFORE writers start
    writers = [_DestWriter(df, entry, root_fd, entry.rel_path)
               for df, root_fd in dest_specs]
    read = 0
    source_error = None
    reraise = None
    clean_read = False  # commit only after EVERY source invariant passed
    try:
        with _defer_sigint():
            for w in writers:
                w.start()
        if source_fd is not None:
            _sr = src_rel if src_rel is not None else entry.rel_path
            _sleaf = _secure_leaf_fd(source_fd, os.path.dirname(_sr))
            try:
                _sfd = _open_reg_nofollow(os.path.basename(_sr), dir_fd=_sleaf)
            finally:
                os.close(_sleaf)
        else:
            _sfd = _open_reg_nofollow(source_file)
        try:
            _f_ctx = os.fdopen(_sfd, "rb", buffering=0)
        except BaseException:
            os.close(_sfd)
            raise
        with _f_ctx as f:
            macio.setup_source_fd(f.fileno())
            pre = os.fstat(f.fileno())
            if pre.st_size != entry.size or abs(pre.st_mtime_ns - entry.mtime_ns) >= 10_000_000:
                raise OSError(5, "source changed between scan and copy")
            while True:
                chunk = f.read(hasher.CHUNK_SIZE)
                if not chunk:
                    break
                for h in hashers.values():
                    h.update(chunk)
                for w in writers:
                    if w.error is None and w.is_alive():
                        w.q.put(chunk)
                read += len(chunk)
                if progress:
                    progress(entry.rel_path, read, entry.size)
            post = os.fstat(f.fileno())
            if read != entry.size or post.st_size != entry.size \
                    or abs(post.st_mtime_ns - entry.mtime_ns) >= 10_000_000:
                raise OSError(5, f"source unstable during copy "
                                 f"(read {read}, expected {entry.size})")
            clean_read = True
    except OSError as e:
        source_error = e
    except BaseException as e:  # noqa: BLE001 — e.g. a progress callback dying:
        # writers must ABORT (never commit on an incomplete validation), and
        # the exception still propagates after they are safely joined.
        source_error = OSError(5, f"aborted by unexpected error: {e}")
        reraise = e
    finally:
        sentinel = _Commit(entry.size) if clean_read else _ABORT
        try:
            with _defer_sigint():
                for w in writers:
                    if w.ident is not None:
                        w.q.put(sentinel)
                for w in writers:
                    if w.ident is not None:
                        w.join()
                if staged_out is not None:
                    staged_out.update({w.dest_file: (w.error, w.tmp_name, w.leaf_fd)
                                       for w in writers})
        except BaseException:
            # A deferred interrupt can arrive after writers have staged data
            # but before the reader receives ownership of their descriptors.
            with _defer_sigint():
                for w in writers:
                    if w.leaf_fd is not None:
                        try:
                            os.remove(w.tmp_name, dir_fd=w.leaf_fd)
                        except OSError:
                            pass
                        try:
                            os.close(w.leaf_fd)
                        except OSError:
                            pass
                if staged_out is not None:
                    staged_out.clear()
            raise
    if reraise is not None:
        raise reraise
    hashes = None if source_error else {fmt: h.hexdigest() for fmt, h in hashers.items()}
    live = [w for w in writers if w.error is None]
    flags = {
        "writers_nocache": all(w.nocache_ok for w in live) if live else True,
        "writers_flush": all(w.flush_ok for w in live) if live else True,
    }
    staged = {w.dest_file: (w.error, w.tmp_name, w.leaf_fd) for w in writers}
    return hashes, staged, source_error, flags


def _open_reg_nofollow(path, dir_fd=None):
    """Open a REGULAR file read-only such that the open itself cannot hang:
    a FIFO planted in place of a media or custody file blocks a plain
    O_RDONLY open forever, before any fstat could reject it (round-13
    finding 4). O_NONBLOCK makes the open return immediately; the fd is
    verified S_ISREG and switched back to blocking before it is returned."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        if not stat_mod.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(errno.EINVAL, "not a regular file", path)
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags & ~os.O_NONBLOCK)
    except BaseException:
        os.close(fd)
        raise
    return fd


def _cold_hash(path, result=None, progress=None, dir_fd=None):
    """Cold xxh64 of a file; tracks whether F_NOCACHE actually took on EVERY
    verification read (conflict adjudication and source re-reads included —
    the attestation must never overstate the cache-bypass guarantee).
    progress, if given, is called with the byte count of each chunk read.
    dir_fd, if given, opens `path` relative to that descriptor with O_NOFOLLOW
    (destination reads must never traverse a planted symlink)."""
    fd = _open_reg_nofollow(path, dir_fd=dir_fd)
    try:
        f_ctx = os.fdopen(fd, "rb", buffering=0)
    except BaseException:
        os.close(fd)
        raise
    with f_ctx as f:
        flag = macio.setup_verify_fd(f.fileno())
        # Monotonic write-only-on-failure: concurrent verify workers share this
        # flag, and a read-modify-write (&=) can resurrect True over a False.
        if result is not None and macio.IS_MACOS and not flag:
            result.io_verify_nocache_all = False
        h = hasher.make_hashers(["xxh64"])["xxh64"]
        while True:
            chunk = f.read(hasher.CHUNK_SIZE)
            if not chunk:
                break
            h.update(chunk)
            if progress is not None:
                progress(len(chunk))
    return h.hexdigest()


def _camera_history_inventory(src_history, hash_fn=None):
    """Inventory camera-written ASC MHL without following links. Camera
    history is evidence, so unsupported objects fail preservation rather than
    being silently dereferenced or omitted. With hash_fn, each file row also
    carries hash_fn(rel) — size+mtime alone cannot catch a same-size rewrite
    under coarse timestamps (round-13 finding 2)."""
    files, dirs = [], []

    def _onerror(err):
        raise RuntimeError(f"camera history traversal failed: {err}")

    for dirpath, dirnames, filenames in os.walk(src_history, onerror=_onerror):
        kept = []
        for name in sorted(dirnames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, src_history)
            if os.path.islink(full):
                raise RuntimeError(f"camera history contains a directory symlink: {rel}")
            kept.append(name)
            dirs.append(rel)
        dirnames[:] = kept
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, src_history)
            st = os.lstat(full)
            if stat_mod.S_ISLNK(st.st_mode):
                raise RuntimeError(f"camera history contains a file symlink: {rel}")
            if not stat_mod.S_ISREG(st.st_mode):
                raise RuntimeError(f"camera history contains a non-regular object: {rel}")
            if hash_fn is not None:
                files.append((rel, st.st_size, st.st_mtime_ns, hash_fn(rel)))
            else:
                files.append((rel, st.st_size, st.st_mtime_ns))
    return files, dirs


def _preserve_camera_history(src_history, card_root, root_fd, result,
                             source_fd=None):
    """Verified, no-overwrite preservation into ascmhl_camera/ through the
    pinned destination descriptor. Existing identical files are retained;
    divergent files are evidence of a custody conflict and fail closed."""
    initial_files, dirs = _camera_history_inventory(src_history)
    hist_hashes = {}  # rel -> verified source content hash (round-13 finding 2)
    qfd = _ensure_dir_tree(root_fd, CAMERA_MHL_QUARANTINE)
    os.close(qfd)
    for rel_dir in dirs:
        fd = _ensure_dir_tree(root_fd, os.path.join(CAMERA_MHL_QUARANTINE, rel_dir))
        os.close(fd)

    def _hist_hash(rel):
        """Hash a camera-history source file through the pinned source
        descriptor (round-12: path-based source reads are gone)."""
        hist_rel = os.path.join(ASCMHL_DIRNAME, rel)
        if source_fd is None:
            return _cold_hash(os.path.join(src_history, rel), result)
        leaf = _secure_leaf_fd(source_fd, os.path.dirname(hist_rel))
        try:
            return _cold_hash(os.path.basename(hist_rel), result, dir_fd=leaf)
        finally:
            os.close(leaf)

    for rel, size, mtime_ns in initial_files:
        source_file = os.path.join(src_history, rel)
        dest_rel = os.path.join(CAMERA_MHL_QUARANTINE, rel)
        leaf_fd = _secure_leaf_fd(root_fd, os.path.dirname(dest_rel))
        name = os.path.basename(dest_rel)
        try:
            try:
                st = os.stat(name, dir_fd=leaf_fd, follow_symlinks=False)
            except FileNotFoundError:
                st = None
            if st is not None:
                if not stat_mod.S_ISREG(st.st_mode) or st.st_size != size:
                    raise RuntimeError(
                        f"camera history conflict at {card_root}/{dest_rel}")
                source_hash = _hist_hash(rel)
                if _cold_hash(name, result, dir_fd=leaf_fd) != source_hash:
                    raise RuntimeError(
                        f"camera history differs from the preserved copy at "
                        f"{card_root}/{dest_rel}; existing evidence was not overwritten")
                if _hist_hash(rel) != source_hash:
                    raise RuntimeError(
                        f"camera history changed while verifying: {rel}")
                hist_hashes[rel] = source_hash
                continue
        finally:
            os.close(leaf_fd)

        entry = FileEntry(dest_rel, size, mtime_ns)
        staged = {}
        try:
            hashes, staged, source_error, flags = _copy_one(
                source_file, entry, [(os.path.join(card_root, dest_rel), root_fd)],
                ("xxh64",), None, source_fd=source_fd,
                src_rel=os.path.join(ASCMHL_DIRNAME, rel), staged_out=staged)
            if macio.IS_MACOS:
                result.io_nocache_all &= flags["writers_nocache"]
                result.io_flush_all &= flags["writers_flush"]
            err, tmp, staged_leaf = staged[os.path.join(card_root, dest_rel)]
            if source_error is not None or err is not None:
                raise RuntimeError(
                    f"camera history copy failed for {rel}: {source_error or err}")
            if _cold_hash(tmp, result, dir_fd=staged_leaf) != hashes["xxh64"]:
                raise RuntimeError(f"camera history verify mismatch for {rel}")
            _commit_noreplace(staged_leaf, tmp, os.path.basename(dest_rel))
            macio.full_fsync(staged_leaf)
            if _hist_hash(rel) != hashes["xxh64"]:
                raise RuntimeError(f"camera history changed during preservation: {rel}")
            hist_hashes[rel] = hashes["xxh64"]
        finally:
            # Failed writers clean themselves; successful staging is owned
            # here even if the copy call is interrupted before returning.
            with _defer_sigint():
                for _err, tmp, staged_leaf in staged.values():
                    if staged_leaf is not None:
                        try:
                            os.remove(tmp, dir_fd=staged_leaf)
                        except OSError:
                            pass
                        try:
                            os.close(staged_leaf)
                        except OSError:
                            pass

    final_files, final_dirs = _camera_history_inventory(src_history)
    if (initial_files, dirs) != (final_files, final_dirs):
        raise RuntimeError("camera history tree changed during preservation")
    # The returned snapshot carries the VERIFIED content hash per file: two
    # destinations that each preserved self-consistent but different bytes
    # (same-size rewrite, restored mtime) must compare unequal (round-13
    # finding 2).
    return [(rel, size, mt, hist_hashes[rel])
            for rel, size, mt in initial_files], dirs


def _reject_containment(source_root, dest_roots):
    src = os.path.realpath(source_root)
    for d in dest_roots:
        dr = os.path.realpath(d)
        common = os.path.commonpath([src, dr])
        if common == src or common == dr:
            raise RuntimeError(
                f"destination {d} and source {source_root} overlap — "
                "a destination inside the source recursively self-copies; "
                "a source inside a destination invites overwrites. Refused.")


def _ascmhl_ident(root_fd):
    """(st_dev, st_ino) of the ascmhl/ DIRECTORY at its canonical name under
    the pinned root, or None when absent/non-directory. Appending generations
    never changes the directory's own inode, so an ident change means the
    custody directory itself was renamed, removed, or replaced."""
    try:
        st = os.stat(ASCMHL_DIRNAME, dir_fd=root_fd, follow_symlinks=False)
    except OSError:
        return None
    return (st.st_dev, st.st_ino) if stat_mod.S_ISDIR(st.st_mode) else None


class _SealBindingError(RuntimeError):
    """ascmhl/ stopped being the directory trust/sealing ran against — every
    manifest path reported for that root is unreliable."""


def _seal_manifests(result, card_roots, root_fds, root_pins, ev):
    """Seal ASC MHL + legacy manifests INSIDE the pinned-root/job-lock
    lifetime (round-12 structural pass): sealing in the CLI after the engine
    closed its descriptors left a window where a swapped namespace could
    receive manifests describing another volume's files. Every write here
    flows through the SAME pinned descriptor the copies were verified under,
    re-checked against its identity pin immediately before sealing."""
    from . import mhl
    for cr in card_roots:
        if cr in result.identity_failed_roots:
            result.errors.append(
                f"{cr}: manifests NOT written — destination volume changed "
                "during the job")
            continue
        warn_before = len(result.warnings)
        m_before = len(result.manifests)
        try:
            st = os.lstat(cr)
            if (st.st_dev, st.st_ino) != root_pins[cr]:
                raise RuntimeError("destination changed identity at sealing time")
            # Binding reference: the ascmhl/ identity trusted history was
            # loaded from (round-14 finding 1). A fresh card has none yet —
            # the identity write_ascmhl creates becomes the reference.
            expected = result.history_binding_by_root.get(cr)
            # Record each manifest the moment ITS writer returns: a legacy
            # failure after a committed ASC generation must not erase the ASC
            # path from the result (round-13 finding 5 — the report and
            # receipt enumerate what actually exists on the card).
            gen, gen_ident = mhl.write_ascmhl_bound(
                cr, result.files, warnings=result.warnings,
                root_fd=root_fds[cr])
            if gen:
                result.manifests.append(gen)
                # gen_ident was captured UNDER the chain lock — sampling the
                # canonical name here instead would adopt an impostor planted
                # after write_ascmhl returned (round-15 PR review finding 1).
                if expected is not None and gen_ident != expected:
                    raise _SealBindingError(
                        f"{ASCMHL_DIRNAME}/ was replaced between trust and "
                        "sealing — the generation did not land in the trusted "
                        "custody directory")
                expected = gen_ident
            legacy = mhl.write_mhl_v11(cr, result.files, result.started_at,
                                       result.finished_at, root_fd=root_fds[cr])
            if legacy:
                result.manifests.append(legacy)
            # End-of-sealing recheck closes the whole span: history load ->
            # trusted-skip consumption -> both writers. A pure continuation
            # (nothing recordable, gen is None) is covered by the history
            # token alone.
            if expected is not None and _ascmhl_ident(root_fds[cr]) != expected:
                raise _SealBindingError(
                    f"{ASCMHL_DIRNAME}/ was renamed or replaced during "
                    "sealing — custody at the canonical name is not what "
                    "this run verified")
        except _SealBindingError as e:
            # Nothing reported for this root can be trusted to exist at its
            # canonical path — retract, fail, never attest.
            del result.manifests[m_before:]
            result.errors.append(f"{cr}: manifest sealing voided: {e}")
            ev({"event": "file_failed", "path": "(manifest)", "error": str(e)})
        except (OSError, RuntimeError) as e:
            result.errors.append(f"{cr}: manifest write failed: {e}")
            ev({"event": "file_failed", "path": "(manifest)", "error": str(e)})
        finally:
            # Quarantine and custody warnings must reach the live stream even
            # when a later writer failed (round-13 finding 5).
            for w in result.warnings[warn_before:]:
                ev({"event": "source_warning", "message": w})


def offload(
    source_root,
    dest_roots,
    label,
    hash_formats=("xxh64",),
    verify_mode="full",  # "full" | "fast"
    source_reread=True,
    reverify_existing=False,  # re-hash trusted-prior files at the destinations
    event=None,  # callback(dict) for progress/JSON-lines
    loose_files=False,  # GUI-staged clones of loose files: never wipe-authorized
):
    """Offload source_root into <dest_root>/<label>/ for each destination.
    Returns OffloadResult."""
    ev = event or (lambda d: None)
    if "xxh64" not in hash_formats:
        hash_formats = ("xxh64", *hash_formats)
    if label != os.path.basename(label) or os.path.isabs(label) or label in ("", ".", ".."):
        raise RuntimeError(f"invalid card name {label!r}: must be a single folder name")

    # Duplicate destinations are one copy; overlapping roles are refused.
    # Roots are pinned to their REAL paths: a symlinked root must never let
    # the containment/eject/identity logic reason about a different location
    # than the one actually written.
    deduped, seen_real = [], set()
    for d in dest_roots:
        rp = os.path.realpath(d)
        if rp not in seen_real:
            seen_real.add(rp)
            deduped.append(rp)
    dest_roots = deduped
    # Destination roots must pre-exist: creating a vanished /Volumes/<name>
    # root would silently write the "backup" onto the boot disk.
    for d in dest_roots:
        if not os.path.isdir(d):
            raise RuntimeError(f"destination root does not exist: {d} — "
                               "is the drive still mounted? Refused.")
    # The SOURCE gets the same identity discipline as destinations: pin its
    # real path now; the reread and final-scan phases are bracketed against
    # this pin (a source swapped for a symlink to a verified destination
    # would otherwise forge the second-read proof — round-11 CRITICAL).
    source_root = os.path.realpath(source_root)
    _reject_containment(source_root, dest_roots)

    result = OffloadResult(
        label=label,
        source=os.path.abspath(source_root),
        destinations=[os.path.abspath(d) for d in dest_roots],
        started_at=time.time(),
        verify_mode=verify_mode,
        loose_files=bool(loose_files),
    )
    card_roots = [os.path.join(d, label) for d in result.destinations]
    # The initial scan is the copy PLAN — tie its identity to the pin taken
    # moments later: a source swapped between scan and pin must refuse.
    _scan_st = os.lstat(source_root)
    if not stat_mod.S_ISDIR(_scan_st.st_mode):
        raise RuntimeError(f"source is not a directory: {source_root}")
    _scan_pin = (_scan_st.st_dev, _scan_st.st_ino)
    entries, source_dirs, scan_warnings = scan_source(source_root)
    if not entries:
        # A wrong mount point, failed automount, or already-wiped card scans
        # empty. all([]) is True, so letting this continue would report a
        # green fully-verified job in which nothing was read or written.
        raise RuntimeError(
            f"source contains no copyable files: {source_root} — wrong "
            "volume, unmounted card, or empty card. Refusing to report "
            "success for a job that would copy nothing.")
    # Camera-history is source inventory too: snapshot its existence and
    # contents BEFORE copying, so its disappearance/mutation mid-job can
    # never escape both the source-change and camera-history gates
    # (round-11 finding 3).
    _early_hist_dir = os.path.join(source_root, ASCMHL_DIRNAME)
    early_camera_inventory = None
    if os.path.isdir(_early_hist_dir) and not os.path.islink(_early_hist_dir):
        # Content-hashed baseline (round-13 finding 2): size+mtime rows let a
        # same-size rewrite with a restored timestamp impersonate the
        # scan-time evidence at every later comparison.
        early_camera_inventory = _camera_history_inventory(
            _early_hist_dir,
            hash_fn=lambda rel: _cold_hash(os.path.join(_early_hist_dir, rel)))

    # Distinct source paths that alias one name on a case-insensitive or
    # Unicode-normalizing destination (macOS APFS default, exFAT cards) would
    # silently collapse into one destination file — and identical content
    # would even pass adjudication. Refuse before writing anything.
    # Case-ONLY collisions are legal when every destination is genuinely
    # case-sensitive (probed, fail-closed); normalization collisions are
    # always refused (even case-sensitive APFS is normalization-insensitive).
    def _dest_case_sensitive(path):
        try:
            return os.pathconf(path, 11) == 1  # _PC_CASE_SENSITIVE (macOS)
        except (OSError, ValueError):
            return False  # unknown filesystem behavior = assume it collapses
    all_dests_case_sensitive = all(_dest_case_sensitive(d) for d in dest_roots)
    seen_names: dict = {}
    for e in entries:
        nfc = unicodedata.normalize("NFC", e.rel_path)
        key = nfc.casefold()
        prior = seen_names.get(key)
        if prior is not None and prior[1] != e.rel_path:
            prior_nfc, prior_raw = prior
            # Same NFC form = normalization-only collision: ALWAYS refused.
            # Different NFC form = case-only collision: legal only when every
            # destination is probed case-sensitive.
            if prior_nfc == nfc or not all_dests_case_sensitive:
                raise RuntimeError(
                    f"source contains files that collide on this destination's "
                    f"filesystem: {prior_raw!r} vs {e.rel_path!r} — one would "
                    "silently shadow the other. Rename one, or use a fully "
                    "case-sensitive destination. Refused.")
        seen_names[key] = (nfc, e.rel_path)
    result.warnings.extend(scan_warnings)
    result.uncopied_source_objects = sum(1 for w in scan_warnings if "skipped" in w)
    for w in scan_warnings:
        ev({"event": "source_warning", "message": w})
    total_bytes = sum(e.size for e in entries)
    ev({"event": "job_started", "label": label, "files": len(entries), "bytes": total_bytes,
        "destinations": card_roots, "verify_mode": verify_mode})

    # Pin the pre-existing destination roots, create/open the card folders and
    # every source directory through dirfds, then take the per-card locks
    # through those same descriptors. Path-based makedirs/open here would sit
    # outside the round-7 NOFOLLOW boundary and could create folders or a lock
    # file through a directory swapped to a symlink after preflight.
    import fcntl as _fcntl
    root_fds = {}
    root_pins = {}
    job_locks = []
    source_fd = None
    verify_admission = None
    try:
        source_fd = _open_dir_nofollow(source_root)
        _sst = os.fstat(source_fd)
        source_pin = (_sst.st_dev, _sst.st_ino)
        if source_pin != _scan_pin:
            raise RuntimeError(
                "source changed identity between the initial scan and pinning "
                "— refused before writing anything")
        for dest, cr in zip(result.destinations, card_roots):
            dest_fd = _open_dir_nofollow(dest)
            try:
                card_fd = _ensure_dir_tree(dest_fd, label)
            finally:
                os.close(dest_fd)
            root_fds[cr] = card_fd
            st = os.fstat(card_fd)
            root_pins[cr] = (st.st_dev, st.st_ino)

        # Snapshot the physical topology NOW, bracketed by pin checks —
        # attestation() must consume this snapshot, never re-resolve live
        # paths after the pinned lifetime (a post-run mount swap fabricated
        # a second "independent device"; round-10 CRITICAL, reproduced).
        def _pinned_now(cr):
            try:
                pst = os.lstat(cr)
                return (pst.st_dev, pst.st_ino) == root_pins[cr]
            except OSError:
                return False
        for cr in card_roots:
            stores = macio.UNKNOWN_DEVICE
            if _pinned_now(cr):
                probed = macio.physical_stores(cr)
                if _pinned_now(cr):
                    stores = probed
            result.physical_stores_by_root[cr] = stores
        result.verify_schedule = _verify_schedule(
            card_roots, result.physical_stores_by_root)
        verify_admission = _VerifyAdmissionGovernor(
            card_roots, result.physical_stores_by_root)

        for cr in card_roots:
            lfd = os.open(".dumptruck-job.lock",
                          os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o644,
                          dir_fd=root_fds[cr])
            job_locks.append(lfd)  # tracked BEFORE flock: any failure releases all
            try:
                _fcntl.flock(lfd, _fcntl.LOCK_EX | _fcntl.LOCK_NB)
            except OSError:
                raise RuntimeError(f"another offload is already writing {cr} — refused")

        # Camera offload folders never legitimately contain symlinks. Audit the
        # pinned tree BEFORE creating anything below it, then create empty
        # source folders descriptor-relatively (directory structure is data).
        for cr in card_roots:
            _assert_no_symlinks_fd(root_fds[cr])
            for d in source_dirs:
                leaf = _ensure_dir_tree(root_fds[cr], d)
                os.close(leaf)
    except BaseException:
        for held in job_locks:
            try:
                os.close(held)
            except OSError:
                pass
        for fd in root_fds.values():
            try:
                os.close(fd)
            except OSError:
                pass
        if source_fd is not None:
            try:
                os.close(source_fd)
            except OSError:
                pass
        raise

    try:
        result = _offload_locked(source_root, result, card_roots, entries, hash_formats,
                               verify_mode, source_reread, reverify_existing, ev,
                               source_dirs, scan_warnings, root_fds, root_pins,
                               source_pin, early_camera_inventory, source_fd,
                               verify_admission)
        # Manifests seal HERE — descriptors and job flocks still held.
        _seal_manifests(result, card_roots, root_fds, root_pins, ev)
        return result
    finally:
        for lfd in job_locks:
            # Nested finally: a failing explicit unlock must never leak the
            # descriptor (closing releases the flock anyway; round-13).
            try:
                try:
                    _fcntl.flock(lfd, _fcntl.LOCK_UN)
                finally:
                    os.close(lfd)
            except OSError:
                pass
        for fd in root_fds.values():
            try:
                os.close(fd)
            except OSError:
                pass
        # The pinned source descriptor was leaked on every successful job
        # (round-13 finding 3): harmless under one-process-per-job, EMFILE
        # and a busy volume for any long-lived caller.
        if source_fd is not None:
            try:
                os.close(source_fd)
            except OSError:
                pass



def _device_is_solid_state(device_or_mount):
    """Return True/False for a known medium, None when diskutil cannot tell."""
    if not macio.IS_MACOS:
        return True
    import plistlib
    import subprocess

    try:
        out = subprocess.run(
            ["diskutil", "info", "-plist", device_or_mount],
            capture_output=True, timeout=15, check=True,
        ).stdout
        info = plistlib.loads(out)
        solid_state = info.get("SolidState")
        return solid_state if isinstance(solid_state, bool) else None
    except (subprocess.SubprocessError, plistlib.InvalidFileException, OSError):
        return None


def _verify_schedule(card_roots, physical_stores_by_root):
    """Choose once from the pinned topology. Unknown media retain overlap."""
    override = os.environ.get("DUMPTRUCK_VERIFY_PER_FILE")
    if override == "1":
        return "per_file"
    if override == "0":
        return "overlap"
    stores = set()
    for cr in card_roots:
        root_stores = physical_stores_by_root.get(cr, macio.UNKNOWN_DEVICE)
        if root_stores == macio.UNKNOWN_DEVICE or not root_stores:
            return "overlap"
        stores.update(root_stores)
    if len(stores) != 1:
        return "overlap"
    try:
        return "per_file" if _device_is_solid_state(next(iter(stores))) is True else "overlap"
    except Exception:
        return "overlap"


class _VerifyAdmissionGovernor:
    """Exclude rotational destination reads from writes on the same device."""

    def __init__(self, card_roots, physical_stores_by_root):
        solid_state_by_store = {}
        locks_by_store = {}
        self._stores_by_root = {}
        for cr in card_roots:
            stores = physical_stores_by_root.get(cr, macio.UNKNOWN_DEVICE)
            if stores == macio.UNKNOWN_DEVICE or not stores:
                self._stores_by_root[cr] = ()
                continue
            rotational = []
            for store in sorted(stores):
                if store not in solid_state_by_store:
                    try:
                        solid_state_by_store[store] = _device_is_solid_state(store)
                    except Exception:  # classification failure preserves SSD scheduling
                        solid_state_by_store[store] = True
                if solid_state_by_store[store] is False:
                    locks_by_store.setdefault(store, threading.Lock())
                    rotational.append(store)
            self._stores_by_root[cr] = tuple(rotational)
        self._locks_by_store = locks_by_store

    @contextlib.contextmanager
    def _admit(self, stores):
        held = []
        try:
            for store in sorted(set(stores)):
                lock = self._locks_by_store[store]
                with _defer_sigint():
                    lock.acquire()
                    held.append(lock)
            yield
        finally:
            with _defer_sigint():
                for lock in reversed(held):
                    lock.release()

    def writes(self, card_roots):
        stores = []
        for cr in card_roots:
            stores.extend(self._stores_by_root.get(cr, ()))
        return self._admit(stores)

    def verify(self, card_root):
        return self._admit(self._stores_by_root.get(card_root, ()))


class _VerifyCommitWorker(threading.Thread):
    """Per-destination verify+commit pipeline. SSD readback remains fully
    overlapped; the admission governor serializes rotational readback against
    writes and other reads on the same device. All fr/result mutation happens
    under the shared lock; verify-before-commit semantics are unchanged."""

    # Bounded: a kill/power loss discards staged-but-unverified partials, so
    # never let an arbitrarily deep backlog of fsynced temps pile up ahead of
    # verification (backpressure on the reader is the correct behavior).
    QUEUE_DEPTH = 8

    def __init__(self, result, lock, ev, card_root, pin, admission):
        super().__init__(daemon=True)
        self.q = queue.Queue(maxsize=self.QUEUE_DEPTH)
        self.result = result
        self.lock = lock
        self.ev = ev
        self.card_root = card_root
        self.pin = pin  # (st_dev, st_ino) of the card root at job start
        self.admission = admission
        self.normal_exit = False

    def _root_intact(self):
        """The card root must still be the SAME directory it was at preflight —
        a volume that vanished and was replaced by another mount at the same
        path must never receive commits attributed to the original."""
        try:
            st = os.lstat(self.card_root)
        except OSError:
            return False
        return stat_mod.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) == self.pin

    def submit(self, task):
        while self.is_alive():
            try:
                self.q.put(task, timeout=0.1)
                return
            except queue.Full:
                pass
        raise RuntimeError(f"verify worker stopped: {self.card_root}")

    def finish(self):
        while self.is_alive():
            try:
                self.q.put(None, timeout=0.1)
                return
            except queue.Full:
                pass
        self.discard_queued()

    def discard_queued(self):
        # A dead worker cannot consume its queue. Discard every staged task
        # before the pinned descriptors and job lock are released.
        while True:
            try:
                task = self.q.get_nowait()
            except queue.Empty:
                break
            if task is None:
                continue
            try:
                os.remove(task["tmp"], dir_fd=task["leaf_fd"])
            except OSError:
                pass
            try:
                os.close(task["leaf_fd"])
            except OSError:
                pass
            with self.lock:
                task["fr"].dest_status[task["cr"]] = "failed"
                self.result.errors.append(
                    f"{task['entry'].rel_path} -> {task['cr']}: verify worker stopped")
            task["pending"]["failed"].set()
            task["pending"]["done"].set()

    def run(self):
        while True:
            task = self.q.get()
            if task is None:
                self.normal_exit = True
                return
            try:
                self._process(task)
            except BaseException as e:  # noqa: BLE001 — a dead worker must fail files, not vanish
                fr, entry, cr = task["fr"], task["entry"], task["cr"]
                with self.lock:
                    # Never demote a copy that already verified and committed
                    # (the exception can come from event emission AFTER commit).
                    if fr.dest_status.get(cr) not in ("verified", "size-only"):
                        fr.dest_status[cr] = "failed"
                    self.result.errors.append(
                        f"{entry.rel_path} -> {cr}: verify worker error: {e}")
            finally:
                # Per-task invariants hold on EVERY exit path: the staged temp
                # never outlives its task uncommitted, the pending counter
                # decrements exactly once, and the leaf descriptor closes.
                if not task.get("committed"):
                    try:
                        os.remove(task["tmp"], dir_fd=task["leaf_fd"])
                    except OSError:
                        pass
                try:
                    os.close(task["leaf_fd"])
                except OSError:
                    pass
                if not task.get("done_called"):
                    task["done_called"] = True
                    try:
                        self._maybe_done(task)
                    except BaseException as e:
                        with self.lock:
                            self.result.errors.append(
                                f"{task['entry'].rel_path}: verify task completion failed: {e}")
                        task["pending"]["failed"].set()
                        task["pending"]["done"].set()

    def _commit(self, task):
        """No-replace commit through the pinned leaf descriptor, then durably
        flush the directory. Returns None on success, the error otherwise."""
        try:
            _commit_noreplace(task["leaf_fd"], task["tmp"], task["final"])
            if not macio.full_fsync(task["leaf_fd"]):
                # The rename itself is not durably on media: a power cut can
                # roll the committed name back even though the file data
                # flushed. That must degrade the flush attestation, not pass.
                with self.lock:
                    self.result.io_flush_all = False
            return None
        except FileExistsError:
            return FileExistsError(
                errno.EEXIST,
                "NAME COLLISION: a file appeared at the final path after "
                "adjudication. Existing file preserved; staged copy discarded.")
        except OSError as e:
            return e

    def _process(self, task):
        fr, entry, cr = task["fr"], task["entry"], task["cr"]
        tmp, verify_mode = task["tmp"], task["verify_mode"]
        if verify_mode == "full":
            read_error = None
            ok = False
            beat = {"done": 0, "last_emit_time": time.monotonic()}

            def _verify_progress(n):
                # A heartbeat, not evidence. Source reads pause while the last
                # copies are read back, and without this the GUI saw zero
                # bytes and called a healthy verify an I/O stall. Advisory
                # only: a failing event sink must never fail the verify.
                beat["done"] += n
                now = time.monotonic()
                if now - beat["last_emit_time"] < 1.0:
                    return
                beat["last_emit_time"] = now
                try:
                    self.ev({"event": "verify_progress", "path": entry.rel_path,
                             "destination": cr, "done": beat["done"],
                             "size": entry.size})
                except Exception:  # noqa: BLE001
                    pass

            try:
                with self.admission.verify(cr):
                    ok = _cold_hash(tmp, self.result, progress=_verify_progress,
                                    dir_fd=task["leaf_fd"]) == fr.hashes["xxh64"]
            except OSError as e:
                read_error = e
                with self.lock:
                    fr.errors.append(f"verify read failed at {cr}: {e}")
            if ok and not self._root_intact():
                ok = False
                read_error = OSError(5, "destination volume changed mid-job "
                                        "(mount replaced?)")
                with self.lock:
                    fr.errors.append(f"commit refused at {cr}: {read_error}")
            if ok:
                commit_error = self._commit(task)
                if commit_error is None:
                    with self.lock:
                        fr.dest_status[cr] = "verified"
                    task["committed"] = True
                else:
                    with self.lock:
                        fr.dest_status[cr] = ("conflict"
                                              if isinstance(commit_error, FileExistsError)
                                              else "failed")
                        self.result.errors.append(
                            f"{entry.rel_path} -> {cr}: commit failed: {commit_error}")
                    if isinstance(commit_error, FileExistsError):
                        self.ev({"event": "name_collision", "path": entry.rel_path,
                                 "destination": cr})
            else:
                with self.lock:
                    fr.dest_status[cr] = "failed"
                    reason = (f"VERIFY READ FAILED ({read_error})" if read_error
                              else "CHECKSUM MISMATCH (staged copy discarded, "
                                   "nothing committed)")
                    self.result.errors.append(f"{entry.rel_path} -> {cr}: {reason}")
                self.ev({"event": "verification_failed", "path": entry.rel_path,
                         "destination": cr,
                         "error": str(read_error) if read_error else None})
        else:
            try:
                st = os.stat(tmp, dir_fd=task["leaf_fd"], follow_symlinks=False)
                if st.st_size != entry.size:
                    with self.lock:
                        fr.dest_status[cr] = "failed"
                        self.result.errors.append(
                            f"{entry.rel_path} -> {cr}: size mismatch")
                elif not self._root_intact():
                    with self.lock:
                        fr.dest_status[cr] = "failed"
                        self.result.errors.append(
                            f"{entry.rel_path} -> {cr}: commit refused: destination "
                            "volume changed mid-job (mount replaced?)")
                else:
                    commit_error = self._commit(task)
                    if commit_error is None:
                        with self.lock:
                            fr.dest_status[cr] = "size-only"
                        task["committed"] = True
                    else:
                        with self.lock:
                            fr.dest_status[cr] = ("conflict"
                                                  if isinstance(commit_error, FileExistsError)
                                                  else "failed")
                            self.result.errors.append(
                                f"{entry.rel_path} -> {cr}: commit failed: {commit_error}")
                        if isinstance(commit_error, FileExistsError):
                            self.ev({"event": "name_collision", "path": entry.rel_path,
                                     "destination": cr})
            except OSError as e:
                with self.lock:
                    fr.dest_status[cr] = "failed"
                    self.result.errors.append(f"{entry.rel_path} -> {cr}: {e}")

    def _maybe_done(self, task):
        pending = task["pending"]
        with self.lock:
            pending["remaining"] -= 1
            last = pending["remaining"] == 0
        if last:
            fr, entry = task["fr"], task["entry"]
            try:
                self.ev({"event": "file_done", "path": entry.rel_path, "bytes": entry.size,
                         "outcome": fr.outcome(), "xxh64": fr.hashes.get("xxh64"),
                         "status": fr.dest_status})
            except BaseException as e:  # noqa: BLE001 — a dying event sink must
                # never kill the worker (an unjoined worker hangs the drain).
                with self.lock:
                    self.result.errors.append(
                        f"{entry.rel_path}: event emission failed: {e}")
            finally:
                # Releases a reader waiting at the file boundary (per-file
                # verify scheduling); set on every path so it can never hang.
                pending["done"].set()


def _reader_loop(source_root, result, card_roots, entries, hash_formats,
                 verify_mode, reverify_existing, history, verify_workers,
                 iolock, ev, root_fds, source_fd, verify_admission):
    """The card-reader producer: one sequential pass over the source, staging
    writes and handing verify/commit to the per-destination pipeline workers.
    All destination I/O flows through the pinned root descriptors in root_fds."""
    for entry in entries:
        source_file = os.path.join(source_root, entry.rel_path)
        fr = FileResult(rel_path=entry.rel_path, size=entry.size, mtime_ns=entry.mtime_ns)
        result.files.append(fr)
        dest_files = {cr: os.path.join(cr, entry.rel_path) for cr in card_roots}
        histkey = entry.rel_path.replace(os.sep, "/")

        # Per destination: trusted-prior (metadata match AND recorded in the
        # destination's own verified history), conflict (exists otherwise), absent.
        state = {}
        state_errors = {}
        for cr in dest_files:
            hist = history[cr].get(histkey)
            leaf_fd = None
            try:
                leaf_fd = _secure_leaf_fd(root_fds[cr], os.path.dirname(entry.rel_path))
                try:
                    st = os.stat(os.path.basename(entry.rel_path), dir_fd=leaf_fd,
                                 follow_symlinks=False)
                    exists = True
                except FileNotFoundError:
                    st = None
                    exists = False
                if (exists and _metadata_match_at(
                        leaf_fd, os.path.basename(entry.rel_path), entry)
                        and hist and hist.get("size") == entry.size
                        and not reverify_existing):
                    state[cr] = "trusted"
                elif exists:
                    state[cr] = "conflict"
                else:
                    state[cr] = "absent"
            except OSError as e:
                # A vanished/non-directory/symlinked parent is destination
                # tampering, not an absent file that may be recreated through
                # a path. Hash the source as usual but fail this destination.
                state[cr] = "unreadable"
                state_errors[cr] = e
            finally:
                if leaf_fd is not None:
                    os.close(leaf_fd)

        if state and all(s == "trusted" for s in state.values()):
            fr.skipped = True
            result.trusted_prior_files += 1
            # 'trusted' is a DISTINCT status: these bytes were NOT read this
            # run and must never be re-sealed into a new manifest generation.
            fr.dest_status = {cr: "trusted" for cr in card_roots}
            ev({"event": "file_skipped_duplicate", "path": entry.rel_path,
                "bytes": entry.size, "basis": "prior verified generation"})
            continue

        to_write = {cr: dest_files[cr] for cr, s in state.items() if s == "absent"}
        ev({"event": "file_started", "path": entry.rel_path, "bytes": entry.size})

        def _progress(rel, done, size):
            ev({"event": "file_progress", "path": rel, "done": done, "size": size})

        write_errors = {}
        try:
            with verify_admission.writes(to_write):
                fr_hashes, write_errors, source_error, io_flags = _copy_one(
                    source_file, entry,
                    [(df, root_fds[cr]) for cr, df in to_write.items()],
                    hash_formats, _progress, source_fd=source_fd,
                    staged_out=write_errors)
            if macio.IS_MACOS and to_write:
                result.io_nocache_all &= io_flags["writers_nocache"]
                result.io_flush_all &= io_flags["writers_flush"]
            if source_error is not None:
                fr.errors.append(f"source read failed: {source_error}")
                result.errors.append(f"{entry.rel_path}: source read failed: {source_error}")
                for cr in to_write:
                    fr.dest_status[cr] = "failed"
                # The non-write destinations were adjudicated before the read:
                # record them so the receipt and file_done status are complete
                # and a trusted copy still counts as accepted on trust (review
                # of the round-3 R3-06 fix, finding A). The run is failed
                # regardless; this keeps the counts honest.
                for cr, s in state.items():
                    if s == "trusted":
                        fr.dest_status[cr] = "trusted"
                    elif s == "unreadable":
                        fr.dest_status[cr] = "failed"
                if any(s == "trusted" for s in state.values()):
                    result.trusted_prior_files += 1
                ev({"event": "file_failed", "path": entry.rel_path, "error": str(source_error)})
                ev({"event": "file_done", "path": entry.rel_path, "bytes": entry.size,
                    "outcome": "failed", "xxh64": None, "status": fr.dest_status})
                continue
            fr.hashes = fr_hashes

            # Trusted/conflict adjudication FIRST (workers must see final statuses
            # for every non-write destination before they compute the outcome).
            for cr, st_ in state.items():
                if st_ == "unreadable":
                    fr.dest_status[cr] = "failed"
                    err = state_errors[cr]
                    fr.errors.append(f"destination path changed at {cr}: {err}")
                    with iolock:
                        result.errors.append(
                            f"{entry.rel_path} -> {cr}: destination path changed or "
                            f"became a symlink mid-job: {err}")
                elif st_ == "trusted":
                    hist_hash = (history[cr].get(histkey) or {}).get("hashes", {}).get("xxh64")
                    if fr.hashes and hist_hash and hist_hash != fr.hashes.get("xxh64"):
                        fr.dest_status[cr] = "failed"
                        with iolock:
                            result.errors.append(
                                f"{entry.rel_path} -> {cr}: TRUSTED COPY DIVERGES from current "
                                "source (source changed in place, or the sealed history no "
                                "longer matches). Nothing skipped; resolve manually.")
                        ev({"event": "trusted_divergence", "path": entry.rel_path,
                            "destination": cr})
                        continue
                    fr.dest_status[cr] = "trusted"
                elif st_ == "conflict":
                    # Same path at destination but NOT backed by verified history
                    # with matching metadata: content decides, never timestamps.
                    # Read through a NOFOLLOW-walked descriptor: a symlink planted
                    # after preflight must never adjudicate as "matching content".
                    try:
                        _adj_leaf = _secure_leaf_fd(root_fds[cr],
                                                    os.path.dirname(entry.rel_path))
                        try:
                            existing = _cold_hash(os.path.basename(entry.rel_path),
                                                  result, dir_fd=_adj_leaf)
                        finally:
                            os.close(_adj_leaf)
                    except OSError as e:
                        existing = None
                        fr.errors.append(f"conflict read failed at {cr}: {e}")
                    if existing == fr.hashes.get("xxh64"):
                        fr.dest_status[cr] = "skipped"
                        ev({"event": "file_skipped_content_match", "path": entry.rel_path,
                            "bytes": entry.size, "destination": cr})
                    else:
                        fr.dest_status[cr] = "conflict"
                        with iolock:
                            result.errors.append(
                                f"{entry.rel_path} -> {cr}: NAME COLLISION with different content "
                                "(possible in-camera filename reuse). Existing copy preserved; "
                                "new file NOT written. Resolve manually or offload under a new card name."
                            )
                        ev({"event": "name_collision", "path": entry.rel_path, "destination": cr})
            if any(s == "trusted" for s in fr.dest_status.values()):
                # Mixed run: trusted on some destinations, written or adjudicated
                # on the rest. The trusted copies were still never read, so the
                # file counts against wipe authorization exactly like a file
                # trusted everywhere (round-3 R3-06).
                result.trusted_prior_files += 1

            # Hand staged temps to the per-destination verify pipeline. SSD roots
            # remain overlapped; rotational roots may consume the natural gap.
            tasks = []
            for cr, df in to_write.items():
                err, tmp, leaf_fd = write_errors[df]
                if err is not None:
                    fr.dest_status[cr] = "failed"
                    fr.errors.append(f"write failed at {cr}: {err}")
                    with iolock:
                        result.errors.append(f"{entry.rel_path} -> {cr}: {err}")
                    continue
                tasks.append((cr, tmp, leaf_fd))
            if tasks:
                pending = {"remaining": len(tasks), "done": threading.Event(),
                           "failed": threading.Event()}
                for cr, tmp, leaf_fd in tasks:
                    with _defer_sigint():
                        verify_workers[cr].submit({
                            "fr": fr, "entry": entry, "cr": cr,
                            "tmp": tmp, "leaf_fd": leaf_fd,
                            "final": os.path.basename(entry.rel_path),
                            "verify_mode": verify_mode, "pending": pending})
                        # The worker now owns this temp and descriptor.
                        write_errors[to_write[cr]] = (None, tmp, None)
                if result.verify_schedule == "per_file":
                    while not pending["done"].wait(0.1):
                        if any(not verify_workers[cr].is_alive() for cr, _, _ in tasks):
                            raise RuntimeError(
                                f"verify worker stopped while waiting for {entry.rel_path}")
                    if pending["failed"].is_set():
                        raise RuntimeError(
                            f"verify task completion failed for {entry.rel_path}")
            else:
                ev({"event": "file_done", "path": entry.rel_path, "bytes": entry.size,
                    "outcome": fr.outcome(), "xxh64": fr.hashes.get("xxh64"),
                    "status": fr.dest_status})
        finally:
            # Adjudication and task submission can both raise after staging.
            # Release only copies whose ownership never reached a worker.
            with _defer_sigint():
                for _err, tmp, leaf_fd in write_errors.values():
                    if leaf_fd is not None:
                        try:
                            os.remove(tmp, dir_fd=leaf_fd)
                        except OSError:
                            pass
                        try:
                            os.close(leaf_fd)
                        except OSError:
                            pass



def _offload_locked(source_root, result, card_roots, entries, hash_formats,
                    verify_mode, source_reread, reverify_existing, ev,
                    initial_dirs, initial_warnings, root_fds, root_pins,
                    source_pin, early_camera_inventory, source_fd,
                    verify_admission):
    label = result.label

    def _source_intact(when):
        """The source path must still be the SAME directory it was at pin time
        — a source swapped for a symlink to a verified destination would let
        the re-read 'prove' the copy against itself (round-11 CRITICAL)."""
        try:
            st = os.lstat(source_root)
            ok = (stat_mod.S_ISDIR(st.st_mode)
                  and (st.st_dev, st.st_ino) == source_pin
                  and os.path.realpath(source_root) == source_root)
        except OSError:
            ok = False
        if not ok:
            result.errors.append(
                f"source changed identity {when} — the source-read proof is "
                "void; re-run the offload from the real card")
        return ok
    iolock = threading.Lock()
    _raw_ev = ev
    _ev_lock = threading.Lock()

    def ev(d):  # noqa: A001 — thread-safe event emission (workers + reader)
        with _ev_lock:
            _raw_ev(d)

    # Reconcile stale partials from a previous kill/power loss (ours alone —
    # match the exact generated suffix, never a legitimate filename that merely
    # contains the substring).
    import re as _re
    _partial_re = _re.compile(r"\.dumptruck-partial-\d+-\d+$")
    for cr in card_roots:
        _remove_stale_partials_fd(root_fds[cr], _partial_re, result)

    # Prior sealed generations are the ONLY basis for skipping a file — and
    # only when their chain validates end-to-end. mhl's history API is
    # path-based (dirfd-native mhl I/O is the structural backlog item), so
    # every path-based read inside the pinned lifetime is BRACKETED by
    # identity checks: trust must never be granted from a directory that is
    # not the pinned destination (round-9 finding 4).
    def _require_pinned(cr, when):
        try:
            st = os.lstat(cr)
            ok = (stat_mod.S_ISDIR(st.st_mode)
                  and (st.st_dev, st.st_ino) == root_pins[cr]
                  and os.path.realpath(cr) == cr)
        except OSError:
            ok = False
        if not ok:
            raise RuntimeError(
                f"{cr}: destination changed identity {when} — refused before "
                "granting trust or writing bytes")

    def _hist_warn(msg):
        result.warnings.append(msg)
        ev({"event": "source_warning", "message": msg})
    history = {}
    for cr in card_roots:
        _require_pinned(cr, "before reading sealed history")
        history[cr], _hist_ident = _load_history(cr, warn=_hist_warn,
                                                 root_fd=root_fds[cr])
        _require_pinned(cr, "after reading sealed history")
        if history[cr]:
            # Custody identity captured UNDER the validation lock, for the
            # sealing-time binding recheck (round-14 finding 1): trust
            # granted from this history is void if ascmhl/ is renamed and
            # replaced at any point before sealing completes. A post-return
            # stat here would already be too late — it could pin an impostor.
            result.history_binding_by_root[cr] = _hist_ident

    # Free-space preflight: refuse before the first byte, not at ENOSPC.
    # Only ABSENT files consume space (conflicts/trusted/reverify are hashed,
    # never written), and destinations sharing one filesystem share one pool.
    needed_by_dev, free_by_dev, roots_by_dev = {}, {}, {}
    for cr in card_roots:
        _require_pinned(cr, "before free-space preflight")
        try:
            dev = os.stat(cr).st_dev
            st = os.statvfs(cr)
            free_by_dev[dev] = st.f_bavail * st.f_frsize
            roots_by_dev.setdefault(dev, []).append(cr)
            needed = sum(e.size for e in entries
                         if not os.path.exists(os.path.join(cr, e.rel_path)))
            needed_by_dev[dev] = needed_by_dev.get(dev, 0) + needed
        except OSError as e:
            raise RuntimeError(
                f"{cr}: free-space preflight could not inspect the pinned "
                f"destination: {e}") from e
        finally:
            _require_pinned(cr, "after free-space preflight")
    for dev, needed in needed_by_dev.items():
        free = free_by_dev[dev]
        if needed and free < needed * 1.02 + 64 * 1024 * 1024:
            raise RuntimeError(
                f"not enough space on the volume holding {roots_by_dev[dev]}: "
                f"need ~{needed // (1024*1024)} MB (+margin), have "
                f"{free // (1024*1024)} MB free — refused before writing")

    # Workers start only after every preflight refusal point has passed, and
    # the drain lives in a finally: no exit path — ENOSPC mid-loop, a dying
    # event sink, a source that vanishes — may release the job flock while
    # worker threads are still renaming files into the card folder.
    verify_workers = {cr: _VerifyCommitWorker(result, iolock, ev, cr, root_pins[cr],
                                               verify_admission)
                      for cr in card_roots}
    try:
        with _defer_sigint():
            for _w in verify_workers.values():
                _w.start()
        _reader_loop(source_root, result, card_roots, entries, hash_formats,
                     verify_mode, reverify_existing, history, verify_workers,
                     iolock, ev, root_fds, source_fd, verify_admission)
    finally:
        with _defer_sigint():
            for w in verify_workers.values():
                if w.ident is not None:
                    w.finish()
            for w in verify_workers.values():
                if w.ident is not None:
                    w.join()
                w.discard_queued()
                if not w.normal_exit:
                    result.errors.append(f"verify worker stopped: {w.card_root}")

    # Post-drain audits + camera history can take minutes on a large
    # accumulated card folder — tell the GUI a phase is running (round-9
    # finding 8: a silent stretch reads as a hang).
    ev({"event": "finalizing"})

    # Final identity check: if ANY card root was swapped at any point, the
    # per-file "verified" statuses may be split across two different volumes —
    # neither holds the complete tree. Fail the whole job for that root and
    # keep its manifests unwritten (cli honors identity_failed_roots).
    for cr in card_roots:
        try:
            st = os.lstat(cr)
            intact = (stat_mod.S_ISDIR(st.st_mode)
                      and (st.st_dev, st.st_ino) == root_pins[cr])
            if intact:
                _assert_no_symlinks_fd(root_fds[cr])
        except OSError:
            intact = False
        except RuntimeError:
            intact = False
        if not intact:
            result.identity_failed_roots.append(cr)
            result.errors.append(
                f"{cr}: destination volume changed during the job (unmounted or "
                "replaced) — the verified set may be split across two volumes. "
                "Nothing at this destination can be attested; re-run the offload.")

    # Preserve camera-written ASC MHL history: copied verbatim into a
    # quarantine folder so OUR chain in ascmhl/ never mutates verified bytes.
    src_history = os.path.join(result.source, ASCMHL_DIRNAME)
    camera_history_snapshot = None
    _hist_now = os.path.isdir(src_history) and not os.path.islink(src_history)
    if early_camera_inventory is not None and not _hist_now:
        # Camera history existed at scan time and is GONE (or a link) now:
        # source custody evidence was lost mid-job — close BOTH gates
        # (round-11 finding 3: this previously escaped every gate).
        result.camera_history_failed = True
        result.source_grew_after_scan = True
        result.warnings.append(
            f"camera-written {ASCMHL_DIRNAME}/ disappeared from the source "
            "during the offload — custody evidence lost; do not wipe.")
    elif early_camera_inventory is None and _hist_now:
        result.source_grew_after_scan = True
        result.warnings.append(
            f"camera-written {ASCMHL_DIRNAME}/ appeared on the source during "
            "the offload — the source tree changed; re-run the offload.")
    if _hist_now and not _source_intact("before camera-history preservation"):
        result.camera_history_failed = True
        _hist_now = False
    if _hist_now:
        for cr in card_roots:
            if cr in result.identity_failed_roots:
                result.camera_history_failed = True
                continue
            try:
                snapshot = _preserve_camera_history(src_history, cr, root_fds[cr],
                                                    result, source_fd=source_fd)
                if camera_history_snapshot is None:
                    camera_history_snapshot = snapshot
                elif camera_history_snapshot != snapshot:
                    raise RuntimeError("camera history changed between destinations")
                if early_camera_inventory is not None \
                        and snapshot != early_camera_inventory:
                    # Preserved bytes exist, but they are NOT what the source
                    # held at scan time: the tree mutated mid-job.
                    result.source_grew_after_scan = True
                    result.camera_history_failed = True
                    result.warnings.append(
                        f"camera-written {ASCMHL_DIRNAME}/ changed between the "
                        "initial scan and preservation — custody evidence is "
                        "not the scan-time evidence; do not wipe.")
                result.warnings.append(
                    f"camera-written {ASCMHL_DIRNAME}/ preserved as {CAMERA_MHL_QUARANTINE}/ at {cr}")
            except (OSError, RuntimeError) as e:
                result.camera_history_failed = True
                result.warnings.append(f"could not preserve camera MHL history at {cr}: {e}")
        ev({"event": "camera_history_preserved", "destinations": card_roots})

        # Camera-history preservation is destination I/O too. Re-check the
        # visible root and symlink-free tree after it, not only after media
        # commits, before any result can be attested.
        for cr in card_roots:
            if cr in result.identity_failed_roots:
                continue
            try:
                st = os.lstat(cr)
                intact = (stat_mod.S_ISDIR(st.st_mode)
                          and (st.st_dev, st.st_ino) == root_pins[cr])
                if intact:
                    # Only ascmhl_camera/ changed since the full post-drain
                    # audit — scope the re-walk to it (round-9 finding 8).
                    _assert_no_symlinks_fd(root_fds[cr],
                                           subtree=CAMERA_MHL_QUARANTINE)
            except (OSError, RuntimeError):
                intact = False
            if not intact:
                result.identity_failed_roots.append(cr)
                result.errors.append(
                    f"{cr}: destination changed during camera-history preservation; "
                    "manifests will not be written")

    if source_reread and verify_mode == "full" and not result.errors \
            and _source_intact("before the source re-read"):
        # The re-read pass covers every byte hashed this run — feed the GUI a
        # determinate progress stream (a minutes-long silent phase reads as a
        # hang to the operator).
        reread_total = sum(fr.size for fr in result.files
                           if not fr.skipped and fr.hashes)
        ev({"event": "source_reread_started", "total": reread_total})
        _rr = {"done": 0, "last_emit_time": time.monotonic()}

        def _reread_progress(n):
            _rr["done"] += n
            now = time.monotonic()
            if now - _rr["last_emit_time"] >= 1.0 \
                    or _rr["done"] == reread_total:
                _rr["last_emit_time"] = now
                ev({"event": "source_reread_progress",
                    "done": _rr["done"], "total": reread_total})

        result.source_reread_ok = None  # only claim a re-read that happened
        for fr in result.files:
            if fr.skipped or not fr.hashes:
                continue
            if result.source_reread_ok is None:
                result.source_reread_ok = True
            try:
                _rleaf = _secure_leaf_fd(source_fd, os.path.dirname(fr.rel_path))
                try:
                    again = _cold_hash(os.path.basename(fr.rel_path), result,
                                       progress=_reread_progress, dir_fd=_rleaf)
                finally:
                    os.close(_rleaf)
            except OSError as e:
                result.source_reread_ok = False
                result.errors.append(f"{fr.rel_path}: source re-read failed: {e}")
                continue
            if again != fr.hashes["xxh64"]:
                result.source_reread_ok = False
                result.errors.append(
                    f"{fr.rel_path}: SOURCE INCONSISTENT between reads "
                    "(card or reader may be failing)"
                )
                ev({"event": "source_inconsistent", "path": fr.rel_path})

    if result.source_reread_ok is True and not _source_intact("after the source re-read"):
        # The path stopped being the pinned card at some point around the
        # re-read: the second-read proof cannot be attributed to the source.
        result.source_reread_ok = False

    # Final source-tree rescan: a clip recorded OR APPENDED-TO mid-job must
    # never be silently absent from a card that then gets wipe authorization.
    # Compare metadata, not just path sets (round-3: a grown clip slipped by).
    try:
        if not _source_intact("before the final source rescan"):
            raise RuntimeError("source identity lost before the final rescan")
        final_entries, final_dirs, final_warnings = scan_source(source_root)
        if not _source_intact("after the final source rescan"):
            raise RuntimeError("source identity lost during the final rescan")
        initial = {e.rel_path: (e.size, e.mtime_ns) for e in entries}
        changed, appeared, removed = [], [], []
        final_map = {e.rel_path: (e.size, e.mtime_ns) for e in final_entries}
        for rel, meta in final_map.items():
            if rel not in initial:
                appeared.append(rel)
            elif meta != initial[rel]:
                changed.append(rel)
        removed = sorted(set(initial) - set(final_map))
        # Warnings and directories are source inventory too: an uncopyable
        # object (bad name, symlink, FIFO) that appears mid-job carries bytes
        # the destinations do NOT have — it must block wipe authorization just
        # as a new regular file would (round-7 reproduced). New empty dirs
        # likewise falsify the "tree unchanged" claim.
        new_warnings = sorted(set(final_warnings) - set(initial_warnings))
        dir_changes = sorted(set(final_dirs) ^ set(initial_dirs))
        if new_warnings:
            result.source_grew_after_scan = True
            result.uncopied_source_objects += len(new_warnings)
            result.warnings.append(
                f"{len(new_warnings)} uncopyable object(s) appeared on the source "
                f"DURING the offload (e.g. {new_warnings[0]}) — their content is "
                "NOT at the destinations. Resolve and run the offload again.")
        if dir_changes:
            result.source_grew_after_scan = True
            result.warnings.append(
                f"the source directory tree changed during the offload "
                f"(e.g. {dir_changes[0]}) — run the offload again.")
        if appeared or changed:
            result.source_grew_after_scan = True
            examples = (appeared + changed)[0]
            msg = (f"{len(appeared)} file(s) appeared and {len(changed)} changed on the "
                   f"source DURING the offload (e.g. {examples}) — those bytes were NOT "
                   "copied. Run the offload again.")
            result.warnings.append(msg)
            ev({"event": "source_changed_after_scan",
                "appeared": sorted(appeared)[:20], "changed": sorted(changed)[:20]})
        if removed:
            # "Tree unchanged" is load-bearing. A deletion is still a source
            # mutation during the proof window, even when the already-verified
            # destination bytes remain useful; never authorize wiping on it.
            result.source_grew_after_scan = True
            result.warnings.append(
                f"{len(removed)} file(s) were deleted from the source during the offload "
                f"(e.g. {removed[0]}); destination copies are preserved, but this run "
                "cannot prove an unchanged source tree. Run the offload again.")
            ev({"event": "source_changed_after_scan", "appeared": [],
                "changed": [], "removed": removed[:20]})
        if camera_history_snapshot is not None:
            # Rehash through the pinned source descriptor: the final rescan
            # must prove the preserved BYTES are still on the card, not just
            # matching sizes and timestamps (round-13 finding 2).
            def _final_hist_hash(rel):
                if source_fd is None:
                    return _cold_hash(os.path.join(src_history, rel), result)
                hist_rel = os.path.join(ASCMHL_DIRNAME, rel)
                leaf = _secure_leaf_fd(source_fd, os.path.dirname(hist_rel))
                try:
                    return _cold_hash(os.path.basename(hist_rel), result,
                                      dir_fd=leaf)
                finally:
                    os.close(leaf)
            try:
                camera_history_final = _camera_history_inventory(
                    src_history, hash_fn=_final_hist_hash)
            except (RuntimeError, OSError) as e:
                camera_history_final = None
                result.warnings.append(f"final camera-history rescan failed: {e}")
            if camera_history_final != camera_history_snapshot:
                result.source_grew_after_scan = True
                result.camera_history_failed = True
                result.warnings.append(
                    "camera-written ascmhl/ changed after it was preserved — "
                    "run the offload again before wiping the source")
    except RuntimeError as e:
        result.source_grew_after_scan = True
        result.warnings.append(f"final source rescan failed: {e}")

    result.finished_at = time.time()
    ev({"event": "job_done", "label": label, "ok": result.ok,
        "fully_verified": result.fully_verified, "errors": result.errors,
        "warnings": result.warnings,
        "seconds": round(result.finished_at - result.started_at, 3)})
    return result
