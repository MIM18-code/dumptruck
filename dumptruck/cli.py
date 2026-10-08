"""Dumptruck CLI — the engine's test harness and the GUI's pipe protocol.

    dumptruck offload SOURCE DEST [DEST...] --label CARD_A [--fast] [--json]
    dumptruck verify CARD_FOLDER [--json] [--allow-new]
    dumptruck inspect SOURCE
    dumptruck cards

JSON event protocol note: `job_done` means copy+verify settled; the single
terminal event is `offload_complete` (emitted only after manifests, identity,
and report handling) — GUIs must treat that, plus the exit code, as authority.
"""

import argparse
import collections
import json
import os
import stat
import sys
import time
import unicodedata

from . import PROTOCOL_VERSION, __version__, cards, engine, hasher, identity, macio, media, mhl, report
from .ignore import is_junk


def _human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


_RESERVED_LABELS = {"reports", "ascmhl", "ascmhl_camera"}  # the tool's own folders

# Verify output is consumed by a GUI and by audit tooling.  Keep both the
# protocol lists and the descriptor-relative completeness walk bounded.
_VERIFY_MAX_LIST_ITEMS = 1_000_000
_VERIFY_MAX_TREE_ENTRIES = 1_000_000
_VERIFY_MAX_DEPTH = 256


def _valid_label(label: str) -> bool:
    return (bool(label) and label not in (".", "..")
            and not os.path.isabs(label)
            and label == os.path.basename(label)
            and "/" not in label and os.sep not in label
            and label.casefold() not in _RESERVED_LABELS)


def _make_printer(as_json):
    if as_json:
        def ev(d):
            print(json.dumps(d), flush=True)
        return ev

    def ev(d):
        kind = d.get("event")
        if kind == "job_started":
            print(f"Offloading {d['files']} files ({_human(d['bytes'])}) "
                  f"to {len(d['destinations'])} destination(s) [{d['verify_mode']}]")
        elif kind == "file_started":
            print(f"  -> {d['path']} ({_human(d['bytes'])})")
        elif kind == "file_skipped_duplicate":
            print(f"  == {d['path']} (verified by a prior generation, skipped)")
        elif kind == "file_skipped_content_match":
            print(f"  == {d['path']} (content-identical at destination, skipped)")
        elif kind == "verification_failed":
            print(f"  !! CHECKSUM MISMATCH {d['path']} at {d['destination']}", file=sys.stderr)
        elif kind == "source_inconsistent":
            print(f"  !! SOURCE INCONSISTENT {d['path']}", file=sys.stderr)
        elif kind == "name_collision":
            print(f"  !! NAME COLLISION {d['path']} (existing copy preserved)", file=sys.stderr)
        elif kind == "file_failed":
            print(f"  !! FAILED {d['path']}: {d['error']}", file=sys.stderr)
        elif kind == "source_warning":
            print(f"  ~~ {d['message']}", file=sys.stderr)
        elif kind == "source_reread_started":
            print("Re-reading source to confirm card integrity...")
        elif kind == "job_done":
            state = ("FULLY VERIFIED" if d["fully_verified"]
                     else ("OK (not fully verified)" if d["ok"] else "FAILED"))
            print(f"Done in {d['seconds']}s: {state}")
            for e in d["errors"]:
                print(f"  error: {e}", file=sys.stderr)
    return ev


def _emit_failed_terminal():
    """Close a protocol-v3 JSON stream on any pre-engine refusal/failure.

    The GUI still fails closed on exit status, but a promised terminal frame
    must not disappear merely because validation failed before engine.offload.
    """
    print(json.dumps({"event": "offload_complete", "ok": False,
                      "protocol": PROTOCOL_VERSION,
                      "fully_verified": False,
                      "safe_to_wipe_source": False}), flush=True)


def _verify_done(*, passed=0, failed=None, missing=None, new=None,
                 unverifiable=None, chain_problems=None, seconds=0.0,
                 f_nocache=False):
    """Build the one strict terminal frame emitted by ``verify --json``."""
    return {
        "event": "verify_done",
        # Unlike the older optional offload handshake, every verify terminal
        # carries the exact protocol epoch.  GUI parsers must require it.
        "protocol": PROTOCOL_VERSION,
        "passed": int(passed),
        "failed": list(failed or []),
        "missing": list(missing or []),
        "new": list(new or []),
        "unverifiable": list(unverifiable or []),
        "chain_problems": list(chain_problems or []),
        "seconds": round(float(seconds), 3),
        # False means F_NOCACHE was not established for every checksum
        # re-read (including unsupported platforms/no files); it is an
        # attestation detail, never an authority grant.
        "f_nocache": bool(f_nocache),
    }


def _open_verify_root(card_root):
    """Open and pin the selected card root without following a symlink."""
    path = os.path.abspath(os.path.normpath(card_root))
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise OSError("selected verify root is not a directory")
        return path, fd, (st.st_dev, st.st_ino)
    except BaseException:
        os.close(fd)
        raise


def _verify_root_still_bound(path, root_fd, pin):
    """Check that the canonical selected path still names the pinned inode."""
    try:
        current = os.lstat(path)
    except OSError:
        return False
    return (stat.S_ISDIR(current.st_mode)
            and (current.st_dev, current.st_ino) == pin)


def _verify_history_still_bound(root_fd, pin):
    """Check that the ASC MHL directory read for history is still present."""
    if pin is None:
        return False
    try:
        current = os.stat(mhl.ASCMHL_DIR, dir_fd=root_fd, follow_symlinks=False)
    except OSError:
        return False
    return (stat.S_ISDIR(current.st_mode)
            and (current.st_dev, current.st_ino) == pin)


def _unmanifested_names(observed, manifest_names):
    """Observed relative paths with no manifest row, compared in NFC.

    HFS+ stores names decomposed (NFD) and lists them that way, while the
    manifest carries the source spelling (NFC on APFS and in the engine's
    own uniqueness rule). A raw set difference called an untouched
    ``café 日本語.txt`` a new file and revoked a verified card (desktop QA
    round 3, R3-02). Two on-disk spellings that collapse to one manifest
    name are still one manifest row: the second stays new, never hidden.
    """
    rows = [name for name in manifest_names if isinstance(name, str)]
    exact = set(rows)
    # One row, one claim. Exact spellings claim first, so a history that
    # legitimately holds two rows differing only by normalization (possible
    # on a normalization-sensitive network share) pairs each row with its
    # own spelling before any cross-spelling claim is allowed.
    counts = collections.Counter(unicodedata.normalize("NFC", name) for name in rows)
    leftover = []
    for name in sorted(observed):
        nfc = unicodedata.normalize("NFC", name)
        if name in exact and counts[nfc] > 0:
            counts[nfc] -= 1
        else:
            leftover.append(name)
    new = set()
    for name in leftover:
        nfc = unicodedata.normalize("NFC", name)
        if counts[nfc] > 0:
            counts[nfc] -= 1
        else:
            new.add(name)
    return new


def _walk_pinned_verify_tree(root_fd):
    """Return non-MHL relative files using descriptor-only traversal.

    ``os.walk(card_root)`` is not sufficient for verify: a nested directory
    can be swapped for a symlink after the history read, or a new file can
    appear after a directory was listed.  This walk holds every parent
    descriptor, opens every child directory with O_NOFOLLOW, and compares the
    directory entry set and inode at the end of each recursion.  Any race or
    unbounded tree raises and is represented as unverifiable by the caller.
    """
    files = set()
    entry_count = 0

    def recurse(dir_fd, prefix, depth, at_root):
        nonlocal entry_count
        if depth > _VERIFY_MAX_DEPTH:
            raise OSError("verification tree exceeds the maximum depth")
        try:
            names = sorted(os.listdir(dir_fd))
        except OSError as e:
            raise OSError(f"verification traversal failed at {prefix or '/'}: {e}") from e
        snapshot = {}
        for name in names:
            if not isinstance(name, str) or not name or "/" in name or "\x00" in name:
                raise OSError(f"verification traversal found an invalid name at {prefix!r}")
            if any(ord(c) < 0x20 for c in name):
                raise OSError(f"verification traversal found a control-character name at {prefix!r}")
            try:
                st = os.lstat(name, dir_fd=dir_fd)
            except OSError as e:
                raise OSError(f"verification traversal could not stat {prefix}/{name}: {e}") from e
            snapshot[name] = (st.st_dev, st.st_ino, st.st_mode)
            entry_count += 1
            if entry_count > _VERIFY_MAX_TREE_ENTRIES:
                raise OSError("verification tree exceeds the entry safety limit")

            rel = name if at_root else f"{prefix}/{name}"
            if stat.S_ISLNK(st.st_mode):
                # Junk filtering is allowed to omit normal OS litter, but a
                # symlink in a real custody path is never followed or hidden.
                if not is_junk(name):
                    raise OSError(f"symlink in verification tree: {rel}")
                continue
            if is_junk(name):
                continue
            if stat.S_ISDIR(st.st_mode):
                # Generated reports live outside the sealed card folder.
                # A Reports directory inside it is ordinary source inventory.
                if at_root and name in (mhl.ASCMHL_DIR,
                                         engine.CAMERA_MHL_QUARANTINE):
                    continue
                try:
                    child_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY
                                       | os.O_NOFOLLOW, dir_fd=dir_fd)
                except OSError as e:
                    raise OSError(f"verification traversal could not open {rel}: {e}") from e
                try:
                    child_st = os.fstat(child_fd)
                    if ((child_st.st_dev, child_st.st_ino)
                            != (st.st_dev, st.st_ino)):
                        raise OSError(f"directory replaced while opening {rel}")
                    recurse(child_fd, rel, depth + 1, False)
                finally:
                    try:
                        os.close(child_fd)
                    except OSError:
                        pass
                try:
                    after = os.lstat(name, dir_fd=dir_fd)
                except OSError as e:
                    raise OSError(f"directory disappeared during verification: {rel}") from e
                if ((after.st_dev, after.st_ino, after.st_mode)
                        != snapshot[name]):
                    raise OSError(f"directory replaced during verification: {rel}")
                continue
            if stat.S_ISREG(st.st_mode):
                if at_root and (name.endswith(".mhl")
                                or name.endswith(".receipt.json")):
                    continue
                files.add(rel)
                try:
                    after = os.lstat(name, dir_fd=dir_fd)
                except OSError as e:
                    raise OSError(f"file disappeared during verification: {rel}") from e
                if ((after.st_dev, after.st_ino, after.st_mode)
                        != snapshot[name]):
                    raise OSError(f"file replaced during verification: {rel}")
                continue
            raise OSError(f"non-regular object in verification tree: {rel}")

        try:
            after_names = sorted(os.listdir(dir_fd))
        except OSError as e:
            raise OSError(f"verification traversal failed at {prefix or '/'}: {e}") from e
        if after_names != names:
            raise OSError(f"directory changed during verification: {prefix or '/'}")

    recurse(root_fd, "", 0, True)
    return files


_FINDER_LITTER = {".DS_Store", ".localized"}


def _occupied_card_folders(destinations, label):
    """The card folders <dest>/<label> that already hold at least one file.
    Finder litter and AppleDouble shadows do not count; anything else does,
    manifests and reports included, because that is another card's custody
    chain. A missing or empty folder is not footage."""
    occupied = []
    for dest in destinations:
        card_root = os.path.join(dest, label)
        if not os.path.isdir(card_root):
            continue
        for _dirpath, _dirnames, filenames in os.walk(card_root):
            if any(n not in _FINDER_LITTER and not n.startswith("._") for n in filenames):
                occupied.append(card_root)
                break
    return occupied


def cmd_offload(args):
    if args.json:
        # Handshake FIRST: the GUI refuses engines speaking a different
        # protocol major (a configurable engineRoot makes skew reachable).
        print(json.dumps({"event": "engine_hello", "protocol": PROTOCOL_VERSION,
                          "version": __version__}), flush=True)
    loose = bool(getattr(args, "loose_files", False))
    try:
        if loose:
            # A GUI-staged folder of clones. It is not a card: no format
            # signature, no dataset identity, no label memory, no continuation.
            card = cards.CardInfo("loose", "Loose files")
            known, vol, ambiguous = None, None, False
        else:
            card = cards.detect(args.source)
            known, vol, _anchors, ambiguous = identity.identify(args.source)
    except Exception as e:  # noqa: BLE001 — even preflight owns a terminal frame
        if args.json:
            print(json.dumps({"event": "job_failed", "error": str(e)}), flush=True)
            _emit_failed_terminal()
        else:
            print(f"JOB FAILED: {e}", file=sys.stderr)
        return 1
    label = (args.label or (known and known["label"]) or card.reel_name
             or os.path.basename(os.path.normpath(args.source)))

    if not _valid_label(label):
        msg = (f"invalid card name {label!r}: must be a single folder name "
               "(no /, no .., not absolute)")
        if args.json:
            print(json.dumps({"event": "job_failed", "error": msg}), flush=True)
            _emit_failed_terminal()
        else:
            print(f"REFUSED: {msg}", file=sys.stderr)
        return 2

    if ambiguous and not args.json:
        print("WARNING: this card matches multiple known cards ambiguously — "
              "treating it as NEW. Verify the label before starting.", file=sys.stderr)
    if ambiguous and args.json:
        print(json.dumps({"event": "identity_ambiguous"}), flush=True)

    dataset_id = None if loose else (known["id"] if known else None)
    try:
        # Loose files own no dataset, so the collision check runs with no
        # exemption: a drop named after a real card must not be filed into
        # that card's folder (Opus review 2026-09-15, finding 2).
        offender = identity.label_collision(label, dataset_id=dataset_id)
        # What the refusal protects is FOOTAGE, and that lives in the card
        # folder at these destinations. A folder with files in it belongs
        # to whichever card wrote it (registry), or, when nothing claims
        # it, to the card that owns the name. A folder that is missing or
        # empty has nothing to invade (Joshua, 2026-09-21: a blank folder
        # blocked a real A001 because a test run had used the name weeks
        # earlier on another drive; Offshoot never would).
        taken = []
        for card_root in _occupied_card_folders(args.destinations, label):
            owner = identity.folder_owner(card_root) or offender
            if owner is not None and owner["id"] != dataset_id:
                taken.append((card_root, owner))
    except Exception as e:  # noqa: BLE001 — registry reads fail closed and terminate cleanly
        if args.json:
            print(json.dumps({"event": "job_failed", "error": str(e)}), flush=True)
            _emit_failed_terminal()
        else:
            print(f"JOB FAILED: {e}", file=sys.stderr)
        return 1
    def describe(rec):
        when = time.strftime('%Y-%m-%d', time.localtime(rec.get('last_seen', 0)))
        return f"a DIFFERENT card ('{rec.get('format_name', '?')}', last seen {when})"

    # Loose files never take a card's name, blank folder or not: they own
    # no dataset, so the name cannot pass to them, and the card,
    # re-inserted, would land on top of them (Opus review 2026-09-15,
    # finding 2).
    if taken or (loose and offender):
        if taken:
            card_root, owner = taken[0]
            msg = (f"REFUSED: {describe(owner)} already owns the card name '{label}' and "
                   f"its footage is in {card_root} — offloading would mix the two cards. "
                   f"Pick another name with --label, or pass --force-label to override.")
        else:
            msg = (f"REFUSED: {describe(offender)} already owns the card name '{label}' — "
                   f"offloading would invade its folder. "
                   f"Pick another name with --label, or pass --force-label to override.")
        if not args.force_label:
            if args.json:
                print(json.dumps({"event": "refused_label_collision", "label": label,
                                  "message": msg}), flush=True)
                _emit_failed_terminal()
            else:
                print(msg, file=sys.stderr)
            return 2
        note = f"--force-label: {msg[len('REFUSED: '):].split(' — ')[0]}; the two cards now share that folder."
        if args.json:
            print(json.dumps({"event": "source_warning", "message": note}), flush=True)
        else:
            print(f"WARNING: {note}", file=sys.stderr)
    # A new card taking a name another card used elsewhere, with none of
    # that card's footage here, passes silently: every project starts at
    # A001/B001, so a warning would fire on nearly every first card
    # (Joshua, 2026-09-23).

    if args.json:
        print(json.dumps({"event": "card_recognized", "format": card.format_name,
                          "label": label, "known": bool(known),
                          "mounts": known.get("mounts", 0) if known else 0}), flush=True)
    else:
        if known:
            lo = known.get("last_offload", {})
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(lo.get("when", 0)))
            print(f"{card.format_name} card '{label}' — seen {known.get('mounts', 0)}x, "
                  f"last offload {when} "
                  f"({'fully verified' if lo.get('fully_verified') else 'NOT fully verified'}). "
                  f"Continuing into existing card folder.")
        else:
            reel = f" (reel {card.reel_name})" if card.reel_name else ""
            print(f"New {card.format_name} card{reel} -> '{label}'")

    formats = tuple(f.strip() for f in args.hash.split(",") if f.strip()) if args.hash else ("xxh64",)
    ev = _make_printer(args.json)

    try:
        result = engine.offload(
            args.source,
            args.destinations,
            label=label,
            hash_formats=formats,
            verify_mode="fast" if args.fast else "full",
            source_reread=not args.no_source_verify,
            reverify_existing=args.reverify_existing,
            event=ev,
            loose_files=loose,
        )
    except Exception as e:  # noqa: BLE001 — the GUI must always get a reason
        if args.json:
            print(json.dumps({"event": "job_failed", "error": str(e)}), flush=True)
            # The terminal verdict fields are REQUIRED in protocol 3 even on
            # the early-failure path — the GUI strictly decodes them.
            _emit_failed_terminal()
        else:
            print(f"JOB FAILED: {e}", file=sys.stderr)
        return 1

    # Manifests are sealed by the ENGINE inside its pinned-root/job-lock
    # lifetime (round-12 structural pass) — the CLI only reports the outcome.
    manifests = list(result.manifests)

    # Post-copy bookkeeping must never turn a verified transfer into a silent
    # process failure: guard it, and ALWAYS reach the terminal event.
    dataset = None
    try:
        if not loose:
            dataset = identity.record_offload(args.source, label, card, result,
                                              known_id=known["id"] if known else None, vol=vol)
    except Exception as e:  # noqa: BLE001
        result.warnings.append(f"card registry update failed: {e} "
                               "(copy state unaffected; label memory not updated)")
        if args.json:
            print(json.dumps({"event": "source_warning",
                              "message": result.warnings[-1]}), flush=True)

    att = result.attestation()
    if args.json:
        print(json.dumps({"event": "attestation", **att}), flush=True)
        print(json.dumps({"event": "manifests_written", "paths": manifests}), flush=True)

    # Reports run AFTER the safety state settles, against the first destination,
    # and are strictly non-authoritative: any failure here is a warning only.
    # The checksum receipt is written on every run; only the HTML/PDF report
    # and its media analysis are optional (desktop QA round 6, R6-01).
    if True:
        try:
            first_card_root = os.path.join(result.destinations[0], label)
            rels = [f.rel_path for f in result.files]
            minfo = {}
            if not args.no_report:
                minfo = media.analyze_card(first_card_root, rels,
                                           thumbs=not args.no_thumbs,
                                           slate_first=args.slate_first)
            paths, receipts = report.write_receipts_and_report(
                result, att, card, minfo, dataset, html=not args.no_report)
            if not receipts:
                raise OSError("no receipt target was writable")
            if not args.no_report and not any(p.endswith(".html") for p in paths):
                raise OSError("no report target was writable")
            if args.json:
                print(json.dumps({"event": "report_written", "paths": paths,
                                  "receipt_paths": receipts}), flush=True)
                for w in result.warnings:
                    if w.startswith("PDF report not generated"):
                        print(json.dumps({"event": "source_warning", "message": w}), flush=True)
            else:
                for p in paths:
                    if p.endswith((".html", ".pdf")):
                        print(f"  report: {p}")
                for w in result.warnings:
                    if w.startswith("PDF report not generated"):
                        print(f"  WARNING: {w}", file=sys.stderr)
        except Exception as e:  # noqa: BLE001 — report failure never affects copy state
            if args.json:
                print(json.dumps({"event": "report_failed", "error": str(e)}), flush=True)
            else:
                print(f"  WARNING: report generation failed ({e}); "
                      "verified-copy state is unaffected.", file=sys.stderr)

    ok = result.ok
    if args.json:
        print(json.dumps({"event": "offload_complete", "ok": ok,
                          "protocol": PROTOCOL_VERSION,
                          "fully_verified": result.fully_verified and ok,
                          "safe_to_wipe_source": att["safe_to_wipe_source"] and ok}),
              flush=True)
    else:
        if not args.json:
            for m in manifests:
                print(f"  manifest: {m}")
        if result.verify_mode == "fast":
            print("  NOTE: fast mode — DESTINATION NOT VERIFIED (size check only) and "
                  "NOTHING was sealed into MHL manifests. Run a full offload of this "
                  "card (it will hash-adjudicate the existing copies and seal them).",
                  file=sys.stderr)
        trusted = att.get("files_trusted_from_prior_generations", 0)
        trusted_note = (f", {trusted} trusted from prior verified generations"
                        if trusted else "")
        print(f"Attestation: source reads={att['source_read_count']}, "
              f"destination readback={'yes' if att['destination_readback'] else 'NO'}, "
              f"cache-bypassed writes+verify={'yes' if att['write_fd_nocache'] and att['verify_fd_nocache'] else 'DEGRADED'}, "
              f"flushed to media={'yes' if att['full_flush_before_close'] else 'DEGRADED'}, "
              f"codec validation=not performed{trusted_note}")
        if att["safe_to_wipe_source"] and ok:
            print(f"SAFE TO WIPE SOURCE: yes ({att['independently_verified_destinations']} verified "
                  f"copies on {att['distinct_physical_devices']} separate physical devices)")
        else:
            reasons = att["safe_to_wipe_blockers"]
            print("SAFE TO WIPE SOURCE: NO — " + "; ".join(reasons or ["unknown"]))
    return 0 if ok else 1


def cmd_verify(args):
    """Re-read checksums against a card folder's ASC MHL history.

    The selected root is opened once with O_NOFOLLOW and all media reads and
    completeness traversal stay beneath that descriptor.  A path/root/nested
    replacement is reported as unverifiable; it can never produce authority
    for a source card or a Job verdict.
    """
    card_root = os.path.normpath(args.folder)
    t0 = time.time()
    passed, failed, missing, unverifiable = [], [], [], []
    chain_problems, new = [], []
    f_nocache_all = True
    hashed_count = 0
    root_fd = None
    root_pin = None
    history_pin = None
    root_path = os.path.abspath(card_root)

    def emit(summary, exit_code):
        if args.json:
            print(json.dumps(summary), flush=True)
        else:
            for p in summary["chain_problems"]:
                print(f"  !! CHAIN: {p}", file=sys.stderr)
            print(f"Checksum re-read {summary['passed']}/"
                  f"{summary['passed'] + len(summary['failed']) + len(summary['missing'])} files "
                  f"in {summary['seconds']}s; {len(summary['failed'])} failed, "
                  f"{len(summary['missing'])} missing, {len(summary['new'])} new"
                  f"{', ' + str(len(summary['unverifiable'])) + ' unverifiable' if summary['unverifiable'] else ''}; "
                  f"F_NOCACHE={'established' if summary['f_nocache'] else 'not established'}")
            if summary["new"] and not args.allow_new:
                print("  NOTE: unmanifested new files make this card INCOMPLETE as sealed "
                      "(--allow-new to accept)", file=sys.stderr)
            if summary["unverifiable"]:
                print("  NOTE: unverifiable evidence never grants source/eject authority",
                      file=sys.stderr)
        return exit_code

    try:
        try:
            root_path, root_fd, root_pin = _open_verify_root(card_root)
        except (OSError, ValueError) as e:
            msg = str(e)
            summary = _verify_done(chain_problems=[msg], seconds=time.time() - t0,
                                   f_nocache=False)
            return emit(summary, 1)

        try:
            # ONE locked snapshot: chain validation and history parsing stay
            # on the same pinned root and ascmhl descriptor.
            chain_problems, manifest, history_pin = mhl.load_validated_history_bound(
                root_path, root_fd=root_fd)
            if chain_problems:
                raise RuntimeError("; ".join(chain_problems))
            if not _verify_root_still_bound(root_path, root_fd, root_pin):
                raise RuntimeError("selected verify root was replaced while reading history")
            if not _verify_history_still_bound(root_fd, history_pin):
                raise RuntimeError("ASC MHL history directory was replaced while reading history")
        except (FileNotFoundError, RuntimeError, OSError, ValueError, TypeError) as e:
            chain_problems = [str(e)]
            summary = _verify_done(chain_problems=chain_problems,
                                   seconds=time.time() - t0, f_nocache=False)
            return emit(summary, 1)

        for rel, info in sorted(manifest.items()):
            if not isinstance(rel, str) or len(rel.encode("utf-8")) > hasher.MAX_RELATIVE_PATH_BYTES:
                unverifiable.append(str(rel))
                continue
            fmt = next((f for f in ("xxh128", "xxh3", "xxh64", "sha1", "md5", "c4")
                        if f in info["hashes"]), None)
            if fmt is None:
                unverifiable.append(rel)
                continue
            try:
                got, nocache = hasher.hash_file_at(
                    root_fd, rel, [fmt], fd_setup=macio.setup_verify_fd)
                hashed_count += 1
                f_nocache_all = f_nocache_all and nocache
            except (OSError, ValueError):
                # Missing is distinguished only when the descriptor-relative
                # open proves ENOENT.  Symlink, FIFO, nested swap, and other
                # read failures remain unverifiable, never a checksum pass.
                try:
                    os.stat(rel, dir_fd=root_fd, follow_symlinks=False)
                except FileNotFoundError:
                    missing.append(rel)
                except OSError:
                    unverifiable.append(rel)
                else:
                    unverifiable.append(rel)
                continue
            if got[fmt] == info["hashes"][fmt]:
                passed.append(rel)
            else:
                failed.append(rel)
                if not args.json:
                    print(f"  !! FAILED {rel}", file=sys.stderr)

        # Completeness is a second descriptor-relative snapshot.  It refuses
        # traversal races instead of accepting a partial os.walk result.
        try:
            observed = _walk_pinned_verify_tree(root_fd)
            unmanifested = _unmanifested_names(observed, manifest)
            if len(unmanifested) > _VERIFY_MAX_LIST_ITEMS:
                # Bound the frame BEFORE materializing the sorted list, and
                # never ship an oversized list alongside the refusal (Ox I1).
                raise OSError("verification new-file list exceeds safety limit")
            new = sorted(unmanifested)
        except OSError as e:
            unverifiable.append(f"(traversal failed: {e})")

        if not _verify_root_still_bound(root_path, root_fd, root_pin):
            unverifiable.append("(selected verify root was replaced during verification)")
        if not _verify_history_still_bound(root_fd, history_pin):
            unverifiable.append("(ASC MHL history directory was replaced during verification)")
    finally:
        if root_fd is not None:
            try:
                os.close(root_fd)
            except OSError:
                pass

    if hashed_count == 0:
        # No checksum read completed, so do not claim that cache bypass was
        # established merely because the empty conjunction is mathematically
        # true.
        f_nocache_all = False
        # And exit 0 is the GUI's authority signal: a history whose
        # generations carry zero hash entries (Dumptruck never writes one —
        # only damage or a crafted reseal produces it) must not read as a
        # verified card just because nothing contradicted it (Ox L4).
        if (not failed and not missing and not chain_problems
                and not unverifiable and (not new or args.allow_new)):
            chain_problems = ["sealed history contains no verifiable hash "
                              "entries — nothing was re-read, so nothing "
                              "is verified"]
    complete_ok = (not failed and not missing and not chain_problems
                   and not unverifiable and (not new or args.allow_new))
    summary = _verify_done(passed=len(passed), failed=failed, missing=missing,
                           new=new, unverifiable=unverifiable,
                           chain_problems=chain_problems,
                           seconds=time.time() - t0,
                           f_nocache=f_nocache_all)
    return emit(summary, 0 if complete_ok else 1)


def cmd_inspect(args):
    """One-shot JSON: detection + identity + inventory for a mounted source (GUI pre-start)."""
    try:
        card = cards.detect(args.source)
        known, _vol, _anchors, ambiguous = identity.identify(args.source)
        entries, _dirs, warnings = engine.scan_source(args.source)
    except (RuntimeError, OSError) as e:
        # A refusal must reach the GUI as its actual reason, not a traceback
        # on a discarded stderr and a generic "check the engine folder" hint
        # (alpha field report: a whole drive staged as source refused on an
        # unreadable directory, and the message blamed the engine install).
        print(json.dumps({"protocol": PROTOCOL_VERSION, "version": __version__,
                          "error": str(e)}))
        return 1
    out = {
        "protocol": PROTOCOL_VERSION,  # GUI refuses skewed engines here too:
        "version": __version__,
        # a wrong suggested_label is the continuation key, silently misfiled
        "format": card.format_id,
        "format_name": card.format_name,
        "reel_name": card.reel_name,
        "suggested_label": ((known and known["label"]) or card.reel_name
                            or os.path.basename(os.path.normpath(args.source))),
        "known": bool(known),
        "ambiguous": ambiguous,
        "mounts": known.get("mounts", 0) if known else 0,
        "last_offload": known.get("last_offload") if known else None,
        "previous_destinations": known.get("destinations", []) if known else [],
        "files": len(entries),
        "bytes": sum(e.size for e in entries),
        "warnings": warnings,
    }
    print(json.dumps(out))
    return 0


def cmd_cards(args):
    recs = identity.all_datasets()
    if args.json:
        print(json.dumps(recs, indent=2))
        return 0
    if not recs:
        print("No cards on record yet.")
        return 0
    for r in sorted(recs, key=lambda r: -r.get("last_seen", 0)):
        lo = r.get("last_offload", {})
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(r.get("last_seen", 0)))
        state = "verified" if lo.get("fully_verified") else "NOT fully verified"
        print(f"{r['label']:<20} {r.get('format_name', '?'):<18} seen {r.get('mounts', 0):>2}x  "
              f"last {when}  last offload: {lo.get('files_copied', 0)} new files, {state}")
        for d in r.get("destinations", []):
            print(f"{'':<20} -> {d}")
    return 0


def cmd_wrap_report(args):
    """Aggregate multiple offload receipts into a shoot-day wrap report."""
    try:
        res = report.write_wrap_report(
            receipt_paths=args.receipts,
            out_dir=args.out_dir,
            title=args.title,
            no_pdf=args.no_pdf,
        )
    except (ValueError, OSError) as e:
        if args.json:
            failed = {
                "event": "wrap_report_complete",
                "ok": False,
                "error": str(e),
                "written": [],
                # A failed PDF render must never be represented as a PDF
                # artifact.  Preserve the HTML path only when the report
                # writer explicitly says it exists.
                "pdf_generated": False,
                "pdf_path": None,
            }
            if isinstance(e, report.WrapReportPDFUnavailable):
                failed["html_path"] = e.html_path
                failed["written"] = [e.html_path]
                failed["pdf_unavailable"] = True
            print(json.dumps(failed), flush=True)
        else:
            print(f"Error generating wrap report: {e}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps({
            "event": "wrap_report_complete",
            "ok": True,
            "wrap_id": res["wrap_id"],
            "html_path": res["html_path"],
            "pdf_path": res["pdf_path"],
            "pdf_generated": res["pdf_generated"],
            "cards_count": res["total_cards"],
            "cards": res["cards"],
            "total_bytes": res["total_bytes"],
            "total_files": res["total_files"],
            "safe_cards": res["safe_cards"],
            "all_safe": res["all_safe"],
            "written": res["written"],
        }), flush=True)
    else:
        print("Shoot-day wrap report generated:")
        print(f"  HTML: {res['html_path']}")
        if res["pdf_generated"]:
            print(f"  PDF:  {res['pdf_path']}")
        elif not args.no_pdf:
            print("  PDF:  UNAVAILABLE (headless Chrome not found or render failed)")
        print(f"  Cards ({res['total_cards']}): {', '.join(res['cards'])}")
        print(f"  Total: {_human(res['total_bytes'])}, {res['total_files']} files copied")
        # A wrap report is evidence aggregation, never a new verdict source.
        # Name the exact recorded field instead of translating it back into
        # SAFE TO WIPE vocabulary outside Job.verdict.
        print("  Recorded safe_to_wipe_source=true attestations: "
              f"{res['safe_cards']}/{res['total_cards']} (not recomputed)")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="dumptruck", description="Media offload with honest verification")
    ap.add_argument("--version", action="version",
                    version=f"dumptruck {__version__} (protocol {PROTOCOL_VERSION})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    o = sub.add_parser("offload", help="offload a source to one or more destinations")
    o.add_argument("source")
    o.add_argument("destinations", nargs="+")
    o.add_argument("--label", help="card name (default: remembered/reel/source folder name)")
    o.add_argument("--force-label", action="store_true",
                   help="override the different-card-owns-this-name refusal")
    o.add_argument("--hash", help="comma list of extra hashes (md5,sha1,c4,xxh3,xxh128)")
    o.add_argument("--fast", action="store_true", help="size-only destination check (LOUDLY unverified)")
    o.add_argument("--no-source-verify", action="store_true", help="skip end-of-job source re-read")
    o.add_argument("--reverify-existing", action="store_true",
                   help="re-hash previously offloaded files at the destinations instead of trusting prior generations")
    o.add_argument("--no-report", action="store_true", help="skip HTML/PDF report generation")
    o.add_argument("--no-thumbs", action="store_true", help="report without clip thumbnails (faster)")
    o.add_argument("--slate-first", action="store_true",
                   help="first thumbnail from frame 0 (slate logging)")
    o.add_argument("--loose-files", action="store_true",
                   help="source is a GUI-staged folder of loose-file clones: no card identity, "
                        "no label memory, never wipe-authorized")
    o.add_argument("--json", action="store_true", help="JSON-lines events on stdout")
    # The GUI passes a unique token so a relaunch can identify and terminate
    # only its own orphan engine. The engine does not use the token for copy
    # semantics; its presence in argv is the identity proof.
    o.add_argument("--gui-run-id", help=argparse.SUPPRESS)
    o.set_defaults(fn=cmd_offload)

    v = sub.add_parser("verify", help="re-read checksums against a card folder's ASC MHL history")
    v.add_argument("folder")
    v.add_argument("--allow-new", action="store_true",
                   help="unmanifested new files don't fail the verify")
    v.add_argument("--json", action="store_true")
    v.set_defaults(fn=cmd_verify)

    c = sub.add_parser("cards", help="list known source datasets (cards)")
    c.add_argument("--json", action="store_true")
    c.set_defaults(fn=cmd_cards)

    i = sub.add_parser("inspect", help="JSON detection + identity + inventory for a source")
    i.add_argument("source")
    i.set_defaults(fn=cmd_inspect)

    w = sub.add_parser("wrap-report", help="aggregate multiple offload receipts into a shoot-day wrap report")
    w.add_argument("receipts", nargs="+", help="path(s) to .receipt.json file(s)")
    w.add_argument("--out", "--output", dest="out_dir", help="output directory for report files")
    w.add_argument("--title", help="report title (default: Shoot Day Wrap Report)")
    w.add_argument("--no-pdf", action="store_true", help="skip PDF generation")
    w.add_argument("--json", action="store_true", help="JSON output format")
    w.set_defaults(fn=cmd_wrap_report)

    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
