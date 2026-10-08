"""Dataset identity: the core object is NOT a mounted volume.

A SourceDataset persists across insertions of the same physical media: its
fingerprint, label, pinned destination roots, mount history, and offload
history. This is what powers "A001 — previously offloaded, continue?" and the
collision warning when a DIFFERENT card would land in an existing card folder.

Volume label is display metadata, never the identity key (duplicate UNTITLED
cards are normal). Identity = volume UUID when available, else a structure
fingerprint over the OLDEST files (appending new clips doesn't change it;
formatting the card does — which is exactly the desired boundary).
"""

import json
import os
import plistlib
import subprocess
import time
import uuid

from .engine import scan_source

_HOME_ENV = "DUMPTRUCK_HOME"


def _db_path():
    home = os.environ.get(_HOME_ENV) or os.path.expanduser(
        "~/Library/Application Support/Dumptruck"
    )
    os.makedirs(home, exist_ok=True)
    return os.path.join(home, "datasets.json")


def _load():
    path = _db_path()
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"datasets": []}
    except (OSError, json.JSONDecodeError) as e:
        # A corrupt registry must never be silently discarded and overwritten:
        # quarantine it loudly so history/collision guards can be recovered.
        import sys
        import time as _t
        quarantine = f"{path}.corrupt-{int(_t.time())}"
        try:
            os.replace(path, quarantine)
        except OSError:
            pass
        print(f"WARNING: card registry was unreadable ({e}); moved to {quarantine}. "
              "Label memory and collision protection start fresh — review that file.",
              file=sys.stderr)
        return {"datasets": [], "_recovered": True}


def _save(db):
    tmp = f"{_db_path()}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(db, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, _db_path())
    # Flush the directory too, or a crash can silently revert the registry
    # to the previous generation after the rename.
    try:
        dfd = os.open(os.path.dirname(_db_path()) or ".", os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def volume_uuid(path) -> str | None:
    try:
        out = subprocess.run(
            ["diskutil", "info", "-plist", path],
            capture_output=True, timeout=15, check=True,
        ).stdout
        info = plistlib.loads(out)
        return info.get("VolumeUUID") or info.get("DiskUUID")
    except (subprocess.SubprocessError, plistlib.InvalidFileException, OSError):
        return None


def anchors(source_root, entries=None):
    """The up-to-16 OLDEST files as [rel_path, size, mtime_s] tuples.

    Identity is subset-based: a card matches a record when every recorded
    anchor is still present. Appending new clips never breaks identity
    (anchors stay, and get refreshed each offload so the set only deepens);
    a format destroys the anchors — exactly the intended identity boundary.
    Content is deliberately not read: this is identity, not integrity.
    """
    if entries is None:
        entries, _dirs, _warn = scan_source(source_root)
    oldest = sorted(entries, key=lambda e: (e.mtime_ns, e.rel_path))[:16]
    return [[e.rel_path, e.size, e.mtime_ns // 1_000_000_000] for e in oldest]


def _source_index(source_root, entries=None):
    if entries is None:
        entries, _dirs, _warn = scan_source(source_root)
    return {e.rel_path: (e.size, e.mtime_ns // 1_000_000_000) for e in entries}, entries


def identify(source_root, entries=None):
    """Match a mounted source against known datasets.
    Returns (record | None, vol_uuid, source_anchors, ambiguous: bool).

    Hardened (bug-hunt findings): a record whose stored volume UUID disagrees
    with the source's UUID is DISQUALIFIED, not merely uncorroborated — a card
    carrying a copied folder from another card must not inherit its identity.
    Multiple surviving matches are ambiguous and treated as no-match by
    callers, loudly."""
    vol = volume_uuid(source_root)
    index, entries = _source_index(source_root, entries)
    src_anchors = anchors(source_root, entries)
    matches = []
    for rec in _load()["datasets"]:
        rec_anchors = rec.get("anchors") or []
        if not rec_anchors:
            continue
        if not all(index.get(rel) == (size, mtime_s) for rel, size, mtime_s in rec_anchors):
            continue
        rec_vol = rec.get("volume_uuid")
        if vol and rec_vol and rec_vol != vol:
            continue  # anchors match but the physical volume differs: different card
        matches.append(rec)
    if len(matches) == 1:
        return matches[0], vol, src_anchors, False
    return None, vol, src_anchors, len(matches) > 1


import unicodedata


def _label_key(label: str) -> str:
    """Case-insensitive + Unicode-normalized: 'A001' and 'a001' are ONE folder
    on APFS/exFAT, so they are one label."""
    return unicodedata.normalize("NFC", label).casefold()


def label_collision(label, dataset_id=None):
    """A DIFFERENT dataset already owns this label -> its card folder would be
    invaded. Returns the offending record or None."""
    key = _label_key(label)
    for rec in _load()["datasets"]:
        if _label_key(rec["label"]) == key and rec["id"] != dataset_id:
            return rec
    return None


def _path_key(path):
    """One spelling per folder: symlinks resolved, case folded (APFS and
    exFAT are case-insensitive), Unicode normalized."""
    return unicodedata.normalize("NFC", os.path.normpath(os.path.realpath(path))).casefold()


def folder_owner(card_root):
    """The dataset that wrote this card folder before, or None. Ownership of
    a FOLDER is what protects footage: a name is only a hint, and two cards
    may carry the same reel name on different drives (Codex review
    2026-09-21, P1: a name-based check let the second card into the first
    card's folder on the first card's drive)."""
    key = _path_key(card_root)
    for rec in _load()["datasets"]:
        if any(_path_key(d) == key for d in rec.get("destinations", [])):
            return rec
    return None


def record_offload(source_root, label, card_info, result, known_id=None, vol=None):
    """Create/update the dataset record after an offload attempt."""
    db = _load()
    if vol is None:
        vol = volume_uuid(source_root)
    rec = None
    if known_id:
        rec = next((r for r in db["datasets"] if r["id"] == known_id), None)
    now = time.time()
    if rec is None:
        rec = {"id": str(uuid.uuid4()), "first_seen": now, "mounts": 0,
               "destinations": []}
        db["datasets"].append(rec)
    rec.update({
        "label": label,
        "format": card_info.format_id,
        "format_name": card_info.format_name,
        "reel_name": card_info.reel_name,
        "volume_uuid": vol,
        "volume_name": os.path.basename(os.path.normpath(source_root)),
        "anchors": anchors(source_root),
        "last_seen": now,
        "mounts": rec.get("mounts", 0) + 1,
    })
    for dest in result.destinations:
        card_root = os.path.join(dest, label)
        if card_root not in rec["destinations"]:
            rec["destinations"].append(card_root)
    copied = [f for f in result.files if f.outcome() in ("verified", "size-only")]
    rec["last_offload"] = {
        "when": now,
        "files_total": len(result.files),
        "files_copied": len(copied),
        "bytes_copied": sum(f.size for f in copied),
        "fully_verified": result.fully_verified,
    }
    _save(db)
    return rec


def all_datasets():
    return _load()["datasets"]
