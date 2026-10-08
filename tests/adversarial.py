"""Dumptruck adversarial self-test: prove the safety engine catches every case.

Run:  .venv/bin/python tests/adversarial.py
Each scenario deliberately sabotages an offload and asserts the engine screams.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import xml.etree.ElementTree as ET
from types import SimpleNamespace

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from dumptruck import PROTOCOL_VERSION, engine, hasher, media, mhl, report  # noqa: E402

PASS = []
FAIL = []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not cond else ""))


def make_card(root, files):
    for rel, size in files.items():
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(os.urandom(size))


def run_verify(card_root):
    """Returns (exit_code, summary_line)."""
    r = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "verify", card_root],
        capture_output=True, text=True, cwd=HERE,
    )
    return r.returncode, (r.stdout + r.stderr)



def scenario_mixed_trust_blocks_wipe(base):
    """[85] Desktop QA round 3, R3-06 (critical). A run that mixes a copy
    trusted from history on one destination with a fresh copy on the other
    must never say SAFE TO WIPE: the trusted bytes were not read this run,
    and the corrupt copy the reproduction plants is exactly what the verdict
    would have wiped the card over."""
    print("[85] history-trusted copy on one destination never earns a fresh wipe verdict")
    src85 = os.path.join(base, "CARD85")
    d85a, d85b = os.path.join(base, "D85A"), os.path.join(base, "D85B")
    os.makedirs(d85a), os.makedirs(d85b)
    make_card(src85, {"mixed_unique.txt": 35})
    # Whole-second source mtime, as the round-3 fixture had.
    whole = (int(time.time()) - 60) * 1_000_000_000
    os.utime(os.path.join(src85, "mixed_unique.txt"), ns=(whole, whole))
    real_stores85 = engine.macio.physical_stores

    def _stores85(path):
        if "D85A" in path:
            return frozenset({"disk85a"})
        if "D85B" in path:
            return frozenset({"disk85b"})
        return real_stores85(path)

    copy_a = os.path.join(d85a, "R3_MIXED_TRUST/mixed_unique.txt")
    copy_b = os.path.join(d85b, "R3_MIXED_TRUST/mixed_unique.txt")
    try:
        engine.macio.physical_stores = _stores85
        res85 = engine.offload(src85, [d85a, d85b], label="R3_MIXED_TRUST")
        att85 = res85.attestation()
        check("baseline two-device offload is SAFE", att85["safe_to_wipe_source"], str(att85))

        # Step 2: one byte flips on A, size and mtime intact; B's copy goes.
        st_a = os.stat(copy_a)
        with open(copy_a, "r+b") as f:
            f.seek(7)
            b = f.read(1)
            f.seek(7)
            f.write(bytes([b[0] ^ 0xFF]))
        os.utime(copy_a, ns=(st_a.st_mtime_ns, st_a.st_mtime_ns))
        os.remove(copy_b)

        # Step 3: one-file rerun. A trusts from history, B copies fresh.
        res85b = engine.offload(src85, [d85a, d85b], label="R3_MIXED_TRUST")
        att85b = res85b.attestation()
        check("one-file mixed run counts the history-trusted file",
              att85b["files_trusted_from_prior_generations"] == 1, str(att85b))
        check("one-file mixed run: only the fresh destination is independently verified",
              att85b["independently_verified_destinations"] == 1, str(att85b))
        check("one-file mixed run is not SAFE and names prior-history trust",
              not att85b["safe_to_wipe_source"]
              and any("prior-generation trust" in x for x in att85b["safe_to_wipe_blockers"]),
              str(att85b["safe_to_wipe_blockers"]))

        # Step 4: a second, new file on both; B's copy of the first goes again.
        make_card(src85, {"new_on_both.txt": 30})
        os.remove(copy_b)
        res85c = engine.offload(src85, [d85a, d85b], label="R3_MIXED_TRUST")
        att85c = res85c.attestation()
        statuses_a = sorted(f.dest_status.get(os.path.join(d85a, "R3_MIXED_TRUST"))
                            for f in res85c.files)
        check("two-file mixed run: A holds one trusted and one verified status",
              statuses_a == ["trusted", "verified"], str(statuses_a))
        check("two-file mixed run counts the trusted file (round-3 R3-06)",
              att85c["files_trusted_from_prior_generations"] == 1, str(att85c))
        check("two-file mixed run: A is not an independently verified destination",
              att85c["independently_verified_destinations"] == 1
              and att85c["distinct_physical_devices"] == 1, str(att85c))
        check("two-file mixed run is NOT SAFE TO WIPE over the corrupt trusted copy",
              not att85c["safe_to_wipe_source"], str(att85c))
        check("two-file mixed run names prior-history trust as a blocker",
              any("prior-generation trust" in x for x in att85c["safe_to_wipe_blockers"]),
              str(att85c["safe_to_wipe_blockers"]))
        src_hash85 = next(f for f in res85c.files
                          if f.rel_path == "mixed_unique.txt").hashes["xxh64"]
        check("the corrupt copy is still corrupt (trust read nothing)",
              hasher.hash_file(copy_a, ["xxh64"])["xxh64"] != src_hash85)
        check("receipt counts agree: trusted files and verified destinations are consistent",
              (att85c["files_trusted_from_prior_generations"] > 0)
              == (att85c["independently_verified_destinations"] < 2), str(att85c))

        # Re-verification must surface the damage explicitly, never SAFE.
        os.remove(copy_b)
        res85d = engine.offload(src85, [d85a, d85b], label="R3_MIXED_TRUST",
                                reverify_existing=True)
        att85d = res85d.attestation()
        check("--reverify-existing fails the damaged copy explicitly",
              not res85d.ok and not att85d["safe_to_wipe_source"]
              and any("mixed_unique.txt" in e for e in res85d.errors), str(res85d.errors))
        check("--reverify-existing trusts nothing",
              att85d["files_trusted_from_prior_generations"] == 0, str(att85d))

        # Interrupted-destination retry shape: A holds a verified subset from a
        # prior sealed run, B has nothing. Every file on A is trusted, every
        # file on B is fresh. Never SAFE, and A is not independently verified.
        src85e = os.path.join(base, "CARD85E")
        d85ea, d85eb = os.path.join(base, "D85A/RETRY"), os.path.join(base, "D85B/RETRY")
        os.makedirs(d85ea), os.makedirs(d85eb)
        make_card(src85e, {"one.mov": 4096, "two.mov": 4096, "three.mov": 4096})
        res85e = engine.offload(src85e, [d85ea], label="R3_RETRY")
        check("retry setup: single-destination run sealed", res85e.ok and res85e.manifests,
              str(res85e.manifests))
        res85f = engine.offload(src85e, [d85ea, d85eb], label="R3_RETRY")
        att85f = res85f.attestation()
        check("retry with one fully trusted destination counts every trusted file",
              att85f["files_trusted_from_prior_generations"] == 3, str(att85f))
        check("retry with one fully trusted destination is not SAFE",
              not att85f["safe_to_wipe_source"]
              and att85f["independently_verified_destinations"] == 1
              and any("prior-generation trust" in x for x in att85f["safe_to_wipe_blockers"]),
              str(att85f))
        res85g = engine.offload(src85e, [d85ea, d85eb], label="R3_RETRY", reverify_existing=True)
        att85g = res85g.attestation()
        check("retry re-verified on both devices earns SAFE honestly",
              res85g.ok and att85g["safe_to_wipe_source"]
              and att85g["files_trusted_from_prior_generations"] == 0
              and att85g["independently_verified_destinations"] == 2, str(att85g))
        # Source read failure on a file trusted on A and absent on B: the
        # run fails, and the trusted copy is still counted and recorded.
        os.remove(os.path.join(d85eb, "R3_RETRY/one.mov"))
        locked85 = os.path.join(src85e, "one.mov")
        os.chmod(locked85, 0)
        try:
            res85h = engine.offload(src85e, [d85ea, d85eb], label="R3_RETRY",
                                    source_reread=False)
        finally:
            os.chmod(locked85, 0o644)
        att85h = res85h.attestation()
        one85 = next(f for f in res85h.files if f.rel_path == "one.mov")
        check("source read failure still records the trusted destination status",
              not res85h.ok and one85.dest_status.get(os.path.join(d85ea, "R3_RETRY")) == "trusted"
              and one85.dest_status.get(os.path.join(d85eb, "R3_RETRY")) == "failed",
              str(one85.dest_status))
        # one.mov trusted on A only (counted in the failure path) plus
        # two.mov and three.mov trusted everywhere: three files on trust.
        check("source read failure still counts the file accepted on trust",
              att85h["files_trusted_from_prior_generations"] == 3
              and not att85h["safe_to_wipe_source"], str(att85h))
        # Pure continuation: the blocker says nothing was read, not "0 devices".
        res85i = engine.offload(src85e, [d85ea, d85eb], label="R3_RETRY")
        att85i = res85i.attestation()
        check("continuation blocker names the unread copies, not a device count",
              att85i["independently_verified_destinations"] == 0
              and any("no destination copy was fully read" in b for b in att85i["safe_to_wipe_blockers"])
              and not any("span only" in b for b in att85i["safe_to_wipe_blockers"]),
              str(att85i["safe_to_wipe_blockers"]))
        doc85, receipt85 = report.build_report(res85i, att85i, SimpleNamespace(format_name="Generic"), {})
        wrap85, _ = report.build_wrap_report([receipt85])
        wording85 = "none fully read this run, prior generations trusted"
        check("receipt explains why no whole copy was read", wording85 in doc85)
        check("wrap uses the same unread-copy wording", wording85 in wrap85)
        check("missing copy counts stay unknown", report._copies_devices_text({}) == "Not recorded / Not recorded")
    finally:
        engine.macio.physical_stores = real_stores85



def scenario_verify_normalizes_unicode_names(base):
    """[86] Desktop QA round 3, R3-02. Verify Existing Custody compares the
    on-disk listing with the manifest in NFC, so an untouched accented name
    on an HFS+ destination (which lists NFD) is not a phantom new file."""
    print("[86] later custody check compares names in NFC (HFS+ lists NFD)")
    from dumptruck import cli as _cli
    nfc_name = unicodedata.normalize("NFC", "café 日本語.txt")
    nfd_name = unicodedata.normalize("NFD", nfc_name)
    check("fixture: NFC and NFD spellings differ as strings", nfc_name != nfd_name)
    manifest = {"hello.txt": {}, nfc_name: {}, "CLIPS/" + nfc_name: {}}
    check("NFD listing of manifested names is not new",
          _cli._unmanifested_names({"hello.txt", nfd_name, "CLIPS/" + nfd_name}, manifest)
          == set())
    check("a genuinely new file is still new",
          _cli._unmanifested_names({"hello.txt", nfd_name, "extra.bin"}, manifest)
          == {"extra.bin"})
    both = _cli._unmanifested_names({nfc_name, nfd_name}, manifest)
    check("two on-disk spellings of one manifested name: exactly one stays new",
          len(both) == 1 and both <= {nfc_name, nfd_name}, str(both))
    check("NFC listing against an NFD-sealed manifest is not new either",
          _cli._unmanifested_names({nfc_name}, {nfd_name: {}}) == set())
    # Two manifest rows that differ only by normalization (a
    # normalization-sensitive share): each spelling claims its own row.
    check("two rows differing only by normalization, both present: nothing new",
          _cli._unmanifested_names({nfc_name, nfd_name}, {nfc_name: {}, nfd_name: {}}) == set())
    check("two such rows with a third spelling on disk: only the third is new",
          _cli._unmanifested_names({nfc_name, nfd_name, "x" + nfc_name},
                                   {nfc_name: {}, nfd_name: {}}) == {"x" + nfc_name})
    check("an exact spelling keeps its own row when a cross-spelling would steal it",
          _cli._unmanifested_names({nfc_name, nfd_name}, {nfc_name: {}}) in ({nfd_name},))

    # Round trip on a real HFS+ volume when hdiutil is available: offload an
    # NFC-named file, then run the CLI verify against the HFS+ copy.
    if os.environ.get("DUMPTRUCK_TEST_SKIP_DISK_IMAGE") == "1":
        print("  NOTE  HFS+ round trip skipped by test environment")
        return
    hdiutil = shutil.which("hdiutil")
    if not hdiutil:
        print("  NOTE  HFS+ round trip skipped (hdiutil unavailable)")
        return
    image = os.path.join(base, "hfs86.sparseimage")
    volname = f"DTR3_02_{os.getpid()}"
    mountpoint = os.path.join(base, "hfs86-mount")
    os.mkdir(mountpoint)
    attach_attempted = False
    try:
        # Sparse: the engine's free-space margin refuses tiny volumes.
        r = subprocess.run([hdiutil, "create", "-size", "1g", "-type", "SPARSE",
                            "-fs", "HFS+J", "-volname", volname, "-quiet", image],
                           capture_output=True, text=True, timeout=60)
        r.check_returncode()
        attach_attempted = True
        r = subprocess.run([hdiutil, "attach", "-nobrowse", "-mountpoint", mountpoint, "-plist", image],
                           capture_output=True, text=True, timeout=60)
        r.check_returncode()
        import plistlib
        plist = plistlib.loads(r.stdout.encode())
        check("HFS+ image mounted in local scratch", any(
            ent.get("mount-point") == mountpoint for ent in plist.get("system-entities", [])))
        src86 = os.path.join(base, "CARD86")
        make_card(src86, {"hello.txt": 64, nfc_name: 96, "CLIPS/" + nfc_name: 128})
        res86 = engine.offload(src86, [mountpoint], label="R3_LATER_VERIFY",
                               source_reread=False)
        check("offload to HFS+ sealed", res86.ok and res86.manifests, str(res86.errors))
        listed = os.listdir(os.path.join(mountpoint, "R3_LATER_VERIFY"))
        check("HFS+ lists the accented name decomposed",
              nfd_name in listed and nfc_name not in listed, str(listed))
        code, out = run_verify(os.path.join(mountpoint, "R3_LATER_VERIFY"))
        check("untouched HFS+ card passes a later custody check with zero new files",
              code == 0 and "0 new" in out and "3/3" in out, out.strip())
        with open(os.path.join(mountpoint, "R3_LATER_VERIFY/hello.txt"), "r+b") as f:
            f.seek(3)
            old_byte = f.read(1)
            f.seek(3)
            f.write(bytes([old_byte[0] ^ 0xff]))
        code, out = run_verify(os.path.join(mountpoint, "R3_LATER_VERIFY"))
        check("damage on the HFS+ card is still one checksum failure, zero new",
              code == 1 and "1 failed" in out and "0 new" in out, out.strip())
    finally:
        if attach_attempted:
            # Identify our image even if attach timed out or returned bad plist.
            # Never leave a mounted filesystem for the arena cleanup to recurse into.
            import plistlib
            info = subprocess.run([hdiutil, "info", "-plist"], capture_output=True,
                                  check=True, timeout=30)
            images = plistlib.loads(info.stdout).get("images", [])
            for mounted in images:
                if os.path.realpath(mounted.get("image-path", "")) != os.path.realpath(image):
                    continue
                devices = [e["dev-entry"] for e in mounted.get("system-entities", [])
                           if e.get("dev-entry")]
                if not devices:
                    raise RuntimeError("HFS+ test image is attached without a detachable device")
                subprocess.run([hdiutil, "detach", devices[0], "-force"],
                               capture_output=True, text=True, timeout=60, check=True)



def scenario_report_limits_and_pdf_failure(base):
    """[87] Desktop QA round 5, R5-03 and R5-04: a 60k-row receipt must stay
    inspectable, and a PDF that cannot be printed is reported, not dropped."""
    print("[87] receipt caps fit real cards; PDF failure is named")
    check("receipt byte cap fits a 60,001-file receipt with room",
          report.MAX_RECEIPT_BYTES >= 64 * 1024 * 1024
          and report.MAX_FILES_PER_RECEIPT >= 200_000)
    big_html = os.path.join(base, "big87.html")
    with open(big_html, "w") as f:
        f.write("<html><body>" + ("<p>row</p>\n" * (report.MAX_PDF_HTML_BYTES // 10 + 1)) + "</body></html>")
    ok, detail = report.html_to_pdf_detail(big_html, os.path.join(base, "big87.pdf"))
    check("oversized HTML skips the PDF with a named reason",
          not ok and "PDF limit" in detail and not os.path.exists(os.path.join(base, "big87.pdf")),
          detail)
    small_html = os.path.join(base, "small87.html")
    with open(small_html, "w") as f:
        f.write("<html><body><p>one row</p></body></html>")
    # An unwritable PDF path: Chrome cannot produce the file, so the print
    # fails and the reason must come back as text, never a silent False.
    ok2, detail2 = report.html_to_pdf_detail(small_html,
                                             os.path.join(base, "no_such_dir87/out.pdf"))
    check("a failed print returns a reason string", not ok2 and bool(detail2), detail2)

    # R6-01: --no-report still writes the checksum receipt and names it.
    src88 = os.path.join(base, "CARD88")
    d88 = os.path.join(base, "D88")
    os.makedirs(d88)
    make_card(src88, {"A001.mov": 4096, "B001.mov": 2048})
    p88 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src88, d88, "--label", "R6_NO_REPORT",
         "--no-report", "--no-source-verify", "--json"],
        capture_output=True, text=True, cwd=HERE,
        env=dict(os.environ, DUMPTRUCK_HOME=os.path.join(base, "HOME88")))
    events88 = [json.loads(l) for l in p88.stdout.splitlines() if l.startswith("{")]
    rw88 = next((e for e in events88 if e.get("event") == "report_written"), None)
    check("reports off still emits report_written with receipt paths",
          rw88 is not None and rw88.get("paths") == [] and rw88.get("receipt_paths"),
          str(rw88))
    receipts88 = (rw88 or {}).get("receipt_paths") or []
    check("the receipt exists on disk and parses as a receipt",
          all(os.path.isfile(r) and r.endswith(".receipt.json") for r in receipts88)
          and receipts88 and report.validate_receipt_dict(json.load(open(receipts88[0])), receipts88[0]) is not None,
          str(receipts88))
    check("reports off writes no HTML",
          not any(f.endswith(".html") for dp, _, fs in os.walk(d88) for f in fs))
    out88 = os.path.join(base, "WRAP88")
    w88 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "wrap-report", receipts88[0], "--out", out88,
         "--json", "--no-pdf"], capture_output=True, text=True, cwd=HERE,
        env=dict(os.environ, DUMPTRUCK_HOME=os.path.join(base, "HOME88"))) if receipts88 else None
    check("a reports-off receipt wraps",
          w88 is not None and w88.returncode == 0 and '"ok": true' in w88.stdout,
          (w88.stdout + w88.stderr)[-300:] if w88 else "no receipt")

    # R6-02: a wrap whose PDF cannot be printed carries the real reason.
    real_detail = report.html_to_pdf_detail
    try:
        report.html_to_pdf_detail = lambda h, p: (False, "HTML report is 12 MB, above the 8 MB PDF limit; open the HTML")
        w88b = subprocess.run(
            [sys.executable, "-c",
             "import json,sys; sys.path.insert(0, %r); from dumptruck import report\n"
             "report.html_to_pdf_detail = lambda h, p: (False, 'HTML report is 12 MB, above the 8 MB PDF limit; open the HTML')\n"
             "try:\n    report.write_wrap_report(receipt_paths=[%r], out_dir=%r, title=None, no_pdf=False)\n"
             "except report.WrapReportPDFUnavailable as e:\n    print(json.dumps({'reason': e.reason, 'html': e.html_path}))"
             % (HERE, receipts88[0], os.path.join(base, "WRAP88B"))],
            capture_output=True, text=True, cwd=HERE) if receipts88 else None
    finally:
        report.html_to_pdf_detail = real_detail
    got88 = json.loads(w88b.stdout.strip().splitlines()[-1]) if w88b and w88b.stdout.strip() else {}
    check("wrap PDF failure names the real reason and keeps the HTML",
          "8 MB PDF limit" in got88.get("reason", "") and os.path.isfile(got88.get("html", "")),
          (w88b.stdout + w88b.stderr)[-300:] if w88b else "no receipt")



def scenario_arri_sdk_helper_preferred(base):
    """[88] The ARRI Image SDK helper is preferred over the Reference Tool,
    its output is validated, and a helper failure falls back to art-cmd
    with both reasons reported. A fake helper stands in for the SDK."""
    print("[88] ARRI SDK helper: preferred, validated, falls back")
    fake = os.path.join(base, "fake-arri-probe")
    jpeg_src = os.path.join(base, "fake88.jpg")
    subprocess.run([sys.executable, "-c",
                    "import struct,zlib;"
                    "open(%r,'wb').write(bytes.fromhex('ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c231c1c2837292c30313434341f27393d38323c2e333432ffc0000b080001000101011100ffc4001f0000010501010101010100000000000000000102030405060708090a0bffc400b5100002010303020403050504040000017d01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffda0008010100003f00fbd0ffd9'))" % jpeg_src],
                   check=True)
    with open(fake, "w") as f:
        f.write("#!/bin/sh\n"
                "if [ \"$1\" = --version ]; then echo 'ARRI Image SDK Version 9.1.1 / ARRI MXF Library Version 4.4.16.0'; exit 0; fi\n"
                "case \"$1\" in *broken*) echo 'arri-probe: injected decode failure' >&2; exit 1;; esac\n"
                "[ \"$2\" = - ] || cp %r \"$2\"\n"
                "echo '{\"container\": \"mxf\", \"codec\": \"ARRIRAW\", \"resolution\": {\"width\": 3072, \"height\": 3072}, "
                "\"fps\": 24, \"frames\": 4, \"duration_s\": 0.1666, \"start_timecode\": \"10:10:36:01\", "
                "\"thumbnail\": null, \"sdk\": {\"image_sdk\": \"9.1.1\"}}'\n" % jpeg_src)
    os.chmod(fake, 0o755)
    clip = os.path.join(base, "clip88.mxf")
    open(clip, "wb").write(os.urandom(256))
    broken = os.path.join(base, "broken88.mxf")
    open(broken, "wb").write(os.urandom(256))
    real_probe_path, real_art = media.ARRI_PROBE, media.probe_art
    art_calls = []
    try:
        media.ARRI_PROBE = fake
        def _art(path, fallback_info=None, want_thumbnail=True):
            art_calls.append(path)
            return None, "injected Reference Tool failure"
        media.probe_art = _art
        entry, err = media.probe_arri(clip, want_thumbnail=True)
        check("SDK helper answers first: metadata parsed and thumbnail attached",
              err is None and entry["probe"]["video"]["width"] == 3072
              and entry["probe"]["video"]["fps"] == 24.0
              and entry["probe"]["timecode"] == "10:10:36:01"
              and entry["probe"]["container"] == "arriraw"
              and len(entry["thumbs"]) == 1 and not art_calls, str((entry, err)))
        entry2, err2 = media.probe_arri(clip, want_thumbnail=False)
        check("metadata-only mode skips the thumbnail and still parses",
              err2 is None and entry2["thumbs"] == [] and entry2["probe"]["arri"]["codec"] == "ARRIRAW",
              str((entry2, err2)))
        entry3, err3 = media.probe_arri(broken, want_thumbnail=True)
        check("helper failure falls back to the Reference Tool and reports both reasons",
              entry3 is None and art_calls == [broken]
              and "injected Reference Tool failure" in err3 and "injected decode failure" in err3,
              str((entry3, err3)))
        media.ARRI_PROBE = os.path.join(base, "missing-arri-probe")
        entry4, err4 = media.probe_arri(clip, want_thumbnail=True)
        check("a missing helper is reported and never blocks the fallback",
              entry4 is None and "not built" in err4, str(err4))
    finally:
        media.ARRI_PROBE, media.probe_art = real_probe_path, real_art
    check("the fake helper never counted as a copy verdict input",
          not hasattr(media, "safe_to_wipe"))


def scenario_source_reread_after_drain(base):
    """[85b] A source change after copy and destination verify must fail the
    final source read, even when size and mtime are unchanged."""
    from dumptruck import engine
    print("[85b] late source change remains visible to the final re-read")
    src = os.path.join(base, "CARD85B")
    make_card(src, {"A.braw": 4096})
    source_file = os.path.join(src, "A.braw")
    original_mtime = os.stat(source_file).st_mtime_ns
    real_cold, real_stores = engine._cold_hash, engine.macio.physical_stores
    worker_read = threading.Event()

    def observed_cold(*a, **k):
        digest = real_cold(*a, **k)
        if type(threading.current_thread()).__name__ == "_SourceRereadWorker":
            worker_read.set()
        return digest

    def change_after_drain(evt):
        if evt.get("event") == "finalizing" and hasattr(engine, "_SourceRereadWorker"):
            worker_read.wait(timeout=5)
        if evt.get("event") == "source_reread_started":
            with open(source_file, "r+b") as f:
                f.seek(0)
                f.write(b"changed after the early read")
            os.utime(source_file, ns=(original_mtime, original_mtime))

    try:
        engine.macio.physical_stores = lambda p: frozenset({"disk85b"})
        engine._cold_hash = observed_cold
        d = os.path.join(base, "D85B_LATE"); os.makedirs(d)
        res = engine.offload(src, [d], label="CARD85B", event=change_after_drain)
        check("late same-size source change fails the second read",
              res.source_reread_ok is False and not res.fully_verified
              and any("A.braw: SOURCE INCONSISTENT" in e for e in res.errors),
              f"worker_read={worker_read.is_set()} errors={res.errors[:3]}")
    finally:
        engine._cold_hash, engine.macio.physical_stores = real_cold, real_stores

    # A failing event sink after the verify drain must not return while the
    # source worker still holds its descriptor and reads the card.
    src2 = os.path.join(base, "CARD85B_EXIT")
    make_card(src2, {"B.braw": 4096})
    d2 = os.path.join(base, "D85B_EXIT"); os.makedirs(d2)
    worker_entered = threading.Event()

    def slow_worker_cold(*a, **k):
        if type(threading.current_thread()).__name__ == "_SourceRereadWorker":
            worker_entered.set()
            time.sleep(0.5)
        return real_cold(*a, **k)

    def dying_sink(evt):
        if evt.get("event") == "finalizing":
            if hasattr(engine, "_SourceRereadWorker"):
                worker_entered.wait(timeout=5)
            raise RuntimeError("event sink failed after drain")

    try:
        engine.macio.physical_stores = lambda p: frozenset({"disk85b"})
        engine._cold_hash = slow_worker_cold
        try:
            engine.offload(src2, [d2], label="CARD85B_EXIT", event=dying_sink)
        except RuntimeError as e:
            raised = "event sink failed after drain" in str(e)
        else:
            raised = False
        live = [t for t in threading.enumerate()
                if type(t).__name__ == "_SourceRereadWorker"]
        check("post-drain exception joins the source reader before returning",
              raised and not live, f"raised={raised} live={live}")
        for t in live:
            t.join(timeout=5)
    finally:
        engine._cold_hash, engine.macio.physical_stores = real_cold, real_stores


def scenario_verify_heartbeat(base):
    """[85c] Destination read-back emits verify_progress heartbeats. Source
    reads pause while the last copies are read back, and a GUI counting only
    source bytes called that healthy wait an I/O stall."""
    from dumptruck import engine
    print("[85c] destination verify emits a heartbeat that can never fail it")
    real_cold = engine._cold_hash

    def slow_verify_cold(*a, **k):
        # Hold each destination read-back past the 1s heartbeat interval.
        if (type(threading.current_thread()).__name__ == "_VerifyCommitWorker"
                and k.get("progress") is not None):
            time.sleep(1.1)
        return real_cold(*a, **k)

    src = os.path.join(base, "CARD85C")
    make_card(src, {"A.braw": 4096})
    d = os.path.join(base, "D85C"); os.makedirs(d)
    events = []
    try:
        engine._cold_hash = slow_verify_cold
        res = engine.offload(src, [d], label="CARD85C", event=events.append)
    finally:
        engine._cold_hash = real_cold
    beats = [e for e in events if e.get("event") == "verify_progress"]
    check("verify read-back emits verify_progress naming file and destination",
          res.fully_verified and bool(beats)
          and all(b.get("path") == "A.braw" and b.get("destination")
                  and b.get("done", 0) > 0 and b.get("size") == 4096 for b in beats),
          f"beats={beats[:2]} errors={res.errors[:2]}")

    src2 = os.path.join(base, "CARD85D")
    make_card(src2, {"B.braw": 4096})
    d2 = os.path.join(base, "D85D"); os.makedirs(d2)

    def broken_on_beat(evt):
        if evt.get("event") == "verify_progress":
            raise BrokenPipeError(32, "event sink went away")

    try:
        engine._cold_hash = slow_verify_cold
        res2 = engine.offload(src2, [d2], label="CARD85D", event=broken_on_beat)
    finally:
        engine._cold_hash = real_cold
    check("a failing heartbeat sink never fails the verify",
          res2.fully_verified and not res2.errors, f"errors={res2.errors[:2]}")


def scenario_source_watcher_junk_matches_engine():
    """[85e] The app's source watcher ignores exactly the engine's junk. A
    name the engine copies must never be ignorable by the watcher, and a
    name the engine skips should not fail an offload when Finder writes it
    (Joshua, 2026-09-28)."""
    from dumptruck import ignore
    print("[85e] source watcher junk list matches the engine's ignore list")
    swift = open(os.path.join(HERE, "DumptruckApp", "Sources", "Dumptruck",
                              "SourceMutationMonitor.swift"), encoding="utf-8").read()
    block = re.search(r"engineJunkNames: Set<String> = \[(.*?)\]", swift, re.S)
    names = set(re.findall(r'"([^"]+)"', block.group(1))) if block else set()
    check("watcher junk names equal the engine's IGNORE_NAMES",
          names == set(ignore.IGNORE_NAMES),
          f"only app={sorted(names - set(ignore.IGNORE_NAMES))} "
          f"only engine={sorted(set(ignore.IGNORE_NAMES) - names)}")
    mirrored = {"._*": 'hasPrefix("._")', ".dumptruck-*": 'hasPrefix(".dumptruck-")',
                "*.dumptruck-partial-*": 'contains(".dumptruck-partial-")',
                ".DocumentRevisions-V100*": 'hasPrefix(".DocumentRevisions-V100")',
                ".Spotlight-V100*": 'hasPrefix(".Spotlight-V100")',
                ".MobileBackups*": 'hasPrefix(".MobileBackups")'}
    check("every engine ignore pattern has a watcher counterpart",
          set(ignore.IGNORE_PATTERNS) == set(mirrored)
          and all(test in swift for test in mirrored.values()),
          f"patterns={ignore.IGNORE_PATTERNS}")


def scenario_final_verify_lifecycle(base):
    print("[90] final review: overlap and resource ownership on exceptional exits")
    real_classify = engine._device_is_solid_state
    try:
        engine._device_is_solid_state = lambda _: None
        governor = engine._VerifyAdmissionGovernor(["root"], {"root": frozenset({"disk"})})
        with governor.writes(["root"]):
            entered = threading.Event()
            def verify_unknown():
                with governor.verify("root"):
                    entered.set()
            thread = threading.Thread(target=verify_unknown)
            thread.start()
            concurrent = entered.wait(1)
        thread.join()
        check("unknown media preserve main's concurrent verify admission", concurrent)
    finally:
        engine._device_is_solid_state = real_classify

    first_lock = threading.Lock()
    def interrupted_acquire():
        raise KeyboardInterrupt()
    governor._locks_by_store = {
        "one": first_lock,
        "two": SimpleNamespace(acquire=interrupted_acquire),
    }
    try:
        with governor._admit(["one", "two"]):
            raise AssertionError("interrupted admission succeeded")
    except KeyboardInterrupt:
        pass
    released = first_lock.acquire(blocking=False)
    check("interrupted multi-store admission releases earlier locks", released)
    if released:
        first_lock.release()

    code = r'''
import contextlib
import fcntl
import inspect
import os
import queue
import signal
import sys
import threading
import time
from dumptruck import engine

base, fault, early_failure = sys.argv[1:]
src = os.path.join(base, 'src')
destinations = [os.path.join(base, name) for name in ('one', 'two')]
for path in [src, *destinations]:
    os.makedirs(path)
with open(os.path.join(src, 'A.mov'), 'wb') as f:
    f.write(b'a' * 4096)
workers, leaves, releases = [], set(), []
fault_hits, unlock_checks, ownership_errors, owner_closes = [], [], [], []
submitted_owners = {}
job_locks = set()
original_init = engine._VerifyCommitWorker.__init__
original_copy = engine._copy_one
original_process = engine._VerifyCommitWorker._process
original_finish = engine._VerifyCommitWorker.finish
original_flock = fcntl.flock
original_start = threading.Thread.start
original_put = queue.Queue.put
original_submit = engine._VerifyCommitWorker.submit
original_run = engine._VerifyCommitWorker.run
original_open, original_close = os.open, os.close
original_remove = os.remove
original_writes = engine._VerifyAdmissionGovernor.writes
started = []
drain_release = threading.Event()
submission_release = threading.Event()
target_copy = False
double_interrupts = ('writer_cleanup_interrupt', 'reader_cleanup_interrupt',
                     'camera_writer_cleanup_interrupt', 'camera_cleanup_interrupt')
copy_lines, copy_start = inspect.getsourcelines(original_copy)
return_boundary = copy_start + next(i for i, line in enumerate(copy_lines)
                                   if line.lstrip().startswith('hashes = None if source_error'))

def init(self, *args, **kwargs):
    original_init(self, *args, **kwargs)
    workers.append(self)
def copy(*args, **kwargs):
    global target_copy
    target_copy = bool(kwargs.get('src_rel')) == fault.startswith('camera_')
    previous_trace = sys.gettrace()
    def interrupt_return(frame, event, arg):
        if frame.f_code is original_copy.__code__ and event == 'line' and frame.f_lineno == return_boundary:
            sys.settrace(previous_trace)
            fault_hits.append(fault)
            os.kill(os.getpid(), signal.SIGINT)
        return interrupt_return
    if target_copy and fault in ('copy_return_interrupt', 'camera_copy_return_interrupt',
                                 'camera_cleanup_interrupt'):
        sys.settrace(interrupt_return)
    try:
        result = original_copy(*args, **kwargs)
    finally:
        sys.settrace(previous_trace)
        target_copy = False
    leaves.update(fd for err, tmp, fd in result[1].values() if fd is not None)
    return result
@contextlib.contextmanager
def writes(self, roots):
    with original_writes(self, roots):
        yield
    if fault in ('admission_exit_interrupt', 'reader_cleanup_interrupt'):
        fault_hits.append(fault)
        os.kill(os.getpid(), signal.SIGINT)
def process(self, task):
    if fault == 'submit_interrupt':
        assert submission_release.wait(5), 'submission worker was not released'
    if fault == 'drain_interrupt':
        time.sleep(0.3)
    original_process(self, task)
def start(self):
    selected = ((fault == 'verify_start' and isinstance(self, engine._VerifyCommitWorker))
                or (fault == 'writer_start' and isinstance(self, engine._DestWriter)))
    if selected:
        if started:
            fault_hits.append(fault)
            raise RuntimeError('injected thread start failure')
        started.append(self)
    original_start(self)
def put(self, item, *args, **kwargs):
    if fault in ('writer_drain_interrupt', 'writer_cleanup_interrupt',
                 'camera_writer_cleanup_interrupt') and target_copy and isinstance(item, engine._Commit) and not releases:
        releases.append(True)
        fault_hits.append(fault)
        os.kill(os.getpid(), signal.SIGINT)
    return original_put(self, item, *args, **kwargs)
def submit(self, task):
    original_submit(self, task)
    if fault in ('wait_exception', 'wait_interrupt'):
        def fail_wait(timeout=None):
            fault_hits.append(fault)
            if fault == 'wait_interrupt':
                raise KeyboardInterrupt()
            raise RuntimeError('injected boundary wait failure')
        task['pending']['done'].wait = fail_wait
    if fault == 'submit_interrupt' and not releases:
        submitted_owners[task['leaf_fd']] = self
        releases.append(True)
        fault_hits.append(fault)
        os.kill(os.getpid(), signal.SIGINT)
def finish(self):
    if fault == 'submit_interrupt':
        submission_release.set()
    if fault == 'full_drain' and not releases:
        assert self.q.full(), 'drain did not exercise a full queue'
        releases.append(True)
        fault_hits.append(fault)
        threading.Timer(0.2, drain_release.set).start()
    if fault == 'drain_interrupt' and not releases:
        releases.append(True)
        fault_hits.append(fault)
        os.kill(os.getpid(), signal.SIGINT)
    original_finish(self)
def run(self):
    if fault == 'worker_death':
        while not self.q.full():
            time.sleep(0.005)
        fault_hits.append(fault)
        return
    if fault == 'full_drain':
        assert drain_release.wait(5), 'drain failed to release worker'
    original_run(self)
def open_fd(path, *args, **kwargs):
    fd = original_open(path, *args, **kwargs)
    if path == '.dumptruck-job.lock':
        job_locks.add(fd)
    if '.dumptruck-partial-' in os.fsdecode(path):
        leaves.add(kwargs['dir_fd'])
    return fd
def close_fd(fd):
    owner = submitted_owners.pop(fd, None)
    if owner is not None:
        owner_closes.append(fd)
        if threading.current_thread() is not owner:
            ownership_errors.append('submitted leaf closed outside its verify worker')
    original_close(fd)
    leaves.discard(fd)
    job_locks.discard(fd)
def remove(path, *args, **kwargs):
    if fault in double_interrupts and fault_hits == [fault] \
            and threading.current_thread() is threading.main_thread() \
            and '.dumptruck-partial-' in os.fsdecode(path):
        fault_hits.append('cleanup_sigint')
        os.kill(os.getpid(), signal.SIGINT)
    return original_remove(path, *args, **kwargs)
def flock(fd, operation):
    if operation == fcntl.LOCK_UN and fd in job_locks:
        unlock_checks.append(fd)
        # Record at the actual ownership boundary, before any delayed worker
        # could hide an early unlock by finishing after offload returns.
        assert all(not w.is_alive() for w in workers), 'worker alive at job unlock'
        assert not any(isinstance(w, engine._DestWriter) for w in threading.enumerate()), 'writer alive at job unlock'
        assert not leaves, 'staged leaf fd open at job unlock'
        for dest in destinations:
            assert not any('.dumptruck-partial-' in name
                           for _, _, names in os.walk(dest) for name in names), 'staged temp at job unlock'
    return original_flock(fd, operation)
def event(evt):
    if fault == 'adjudication_sink' and evt['event'] == 'name_collision':
        fault_hits.append(fault)
        raise RuntimeError('injected adjudication sink failure')

engine._VerifyCommitWorker.__init__ = init
engine._VerifyCommitWorker._process = process
engine._VerifyCommitWorker.finish = finish
engine._VerifyCommitWorker.submit = submit
engine._VerifyCommitWorker.run = run
engine._VerifyCommitWorker.QUEUE_DEPTH = 1
engine._copy_one = copy
engine._VerifyAdmissionGovernor.writes = writes
threading.Thread.start = start
queue.Queue.put = put
fcntl.flock = flock
os.open, os.close = open_fd, close_fd
os.remove = remove
if fault.startswith('camera_'):
    os.makedirs(os.path.join(src, 'ascmhl'))
    with open(os.path.join(src, 'ascmhl', 'camera.mhl'), 'wb') as f:
        f.write(b'camera history fixture')
if fault == 'adjudication_sink':
    root = os.path.join(destinations[1], 'CARD')
    os.makedirs(root)
    with open(os.path.join(root, 'A.mov'), 'wb') as f:
        f.write(b'preserve me')
if early_failure == '1':
    def fail_early(*args, **kwargs):
        raise RuntimeError('unrelated early failure')
    engine.offload = fail_early
caught = None
try:
    result = engine.offload(src, destinations, label='CARD', source_reread=False, event=event)
except (KeyboardInterrupt, RuntimeError) as exc:
    caught = exc
assert fault_hits, 'intended fault did not fire'
if fault in double_interrupts:
    assert fault_hits == [fault, 'cleanup_sigint'], fault_hits
assert len(unlock_checks) == len(destinations), 'job unlock checks did not run'
assert not ownership_errors, ownership_errors
if fault == 'submit_interrupt':
    assert len(owner_closes) == 1 and not submitted_owners, 'submitted leaf ownership not observed'
if fault == 'full_drain':
    assert caught is None, repr(caught)
    assert result.ok, result.errors
elif fault == 'worker_death' and os.environ['DUMPTRUCK_VERIFY_PER_FILE'] == '0':
    assert caught is None, repr(caught)
    assert not result.ok and any('verify worker stopped' in e for e in result.errors), result.errors
else:
    expected = {
        'adjudication_sink': (RuntimeError, 'injected adjudication sink failure'),
        'verify_start': (RuntimeError, 'injected thread start failure'),
        'writer_start': (RuntimeError, 'injected thread start failure'),
        'wait_exception': (RuntimeError, 'injected boundary wait failure'),
        'worker_death': (RuntimeError, 'verify worker stopped while waiting for A.mov'),
    }.get(fault, (KeyboardInterrupt, ''))
    assert type(caught) is expected[0] and str(caught) == expected[1], (repr(caught), expected)
assert all(not w.is_alive() for w in workers), 'worker survived offload'
'''
    for fault in ("adjudication_sink", "drain_interrupt", "writer_drain_interrupt",
                  "verify_start", "writer_start", "submit_interrupt", "worker_death",
                  "wait_exception", "wait_interrupt", "full_drain", "admission_exit_interrupt",
                  "writer_cleanup_interrupt", "reader_cleanup_interrupt", "copy_return_interrupt",
                  "camera_writer_cleanup_interrupt", "camera_copy_return_interrupt", "camera_cleanup_interrupt"):
        for schedule in ("0", "1"):
            if fault.startswith("wait_") and schedule == "0":
                continue
            if fault == "full_drain" and schedule == "1":
                continue
            for early_failure in ("0", "1"):
                arena = os.path.join(base, "final-" + fault + schedule + early_failure)
                name = (f"{fault}, schedule={schedule}: " +
                        ("rejects unrelated early failure" if early_failure == "1"
                         else "resources released before flock"))
                try:
                    proc = subprocess.run(
                        [sys.executable, "-c", code, arena, fault, early_failure], cwd=HERE,
                        capture_output=True, text=True, timeout=10,
                        env=dict(os.environ, DUMPTRUCK_VERIFY_PER_FILE=schedule))
                    passed = (proc.returncode != 0 and 'intended fault did not fire' in proc.stderr
                              if early_failure == "1" else proc.returncode == 0)
                    check(name, passed, (proc.stdout + proc.stderr)[-1000:])
                except subprocess.TimeoutExpired:
                    check(name, False, "timed out")


def scenario_final_verify_topology():
    from unittest.mock import patch
    import plistlib
    print("[91] topology resolution and conservative schedule selection")
    mount = "/review-mount"
    cases = (
        ("APFS volume", {"APFSPhysicalStores": [{"APFSPhysicalStore": "disk4s2"}]},
         {"SolidState": True}, frozenset({"disk4"}), "per_file"),
        ("APFS multiple stores", {"APFSPhysicalStores": [
            {"APFSPhysicalStore": "disk4s2"}, {"APFSPhysicalStore": "disk5s2"}]},
         {"SolidState": True}, frozenset({"disk4", "disk5"}), "overlap"),
        ("disk image", {"ParentWholeDisk": "disk9", "VirtualOrPhysical": "Virtual"},
         {"VirtualOrPhysical": "Virtual"}, frozenset({"disk9"}), "overlap"),
        ("unknown device", {"Error": "not a disk"}, {}, engine.macio.UNKNOWN_DEVICE, "overlap"),
        ("unknown medium", {"ParentWholeDisk": "disk4"}, {}, frozenset({"disk4"}), "overlap"),
        ("rotational", {"ParentWholeDisk": "disk4"}, {"SolidState": False},
         frozenset({"disk4"}), "overlap"),
    )
    saved = os.environ.pop("DUMPTRUCK_VERIFY_PER_FILE", None)
    try:
        for name, info, medium, expected, schedule in cases:
            calls = []
            def diskutil(args, **kwargs):
                calls.append(args[-1])
                return SimpleNamespace(stdout=plistlib.dumps(info if args[-1] == mount else medium))
            with patch.object(engine.macio, "IS_MACOS", True), \
                    patch.object(engine.macio, "_device_cache", {}), \
                    patch("os.stat", return_value=SimpleNamespace(st_dev=123)), \
                    patch("os.path.realpath", side_effect=lambda path: path), \
                    patch("os.path.ismount", side_effect=lambda path: path == mount), \
                    patch("subprocess.run", side_effect=diskutil):
                roots = [mount + "/folder/one/CARD", mount + "/folder/two/CARD"]
                stores = {root: engine.macio.physical_stores(root) for root in roots}
                selected = engine._verify_schedule(roots, stores)
            check(f"{name}: folders resolve through mount, schedule={schedule}",
                  all(value == expected for value in stores.values())
                  and selected == schedule and calls.count(mount) == 1,
                  f"stores={stores} selected={selected} calls={calls}")
    finally:
        if saved is not None:
            os.environ["DUMPTRUCK_VERIFY_PER_FILE"] = saved


def main():
    # realpath: the engine pins destinations to REAL paths (macOS /var -> /private/var)
    base = os.path.realpath(tempfile.mkdtemp(prefix="dumptruck-adversarial-"))
    print(f"arena: {base}\n")
    src = os.path.join(base, "CARD")
    d1, d2 = os.path.join(base, "D1"), os.path.join(base, "D2")
    os.makedirs(d1), os.makedirs(d2)
    make_card(src, {
        "CLIPS/A001_C001.braw": 4 * 1024 * 1024,
        "CLIPS/A001_C002.braw": 2 * 1024 * 1024 + 777,
        "CLIPS/A001_C001.sidecar": 64,
        "AUDIO/SC01_T01.wav": 1 * 1024 * 1024,
    })
    os.makedirs(os.path.join(src, "EMPTY/NESTED"))
    open(os.path.join(src, ".DS_Store"), "w").write("junk")
    open(os.path.join(src, "CLIPS/._A001_C001.braw"), "w").write("junk")

    print("[1] clean offload to two destinations")
    res = engine.offload(src, [d1, d2], label="CARD")
    att = res.attestation()
    check("offload fully verified", res.fully_verified)
    check("4 files copied, junk excluded", sum(1 for f in res.files) == 4)
    check("empty dirs recreated", os.path.isdir(os.path.join(d1, "CARD/EMPTY/NESTED")))
    check("no junk at destination",
          not os.path.exists(os.path.join(d1, "CARD/.DS_Store"))
          and not os.path.exists(os.path.join(d1, "CARD/CLIPS/._A001_C001.braw")))
    # Round 12: the ENGINE seals manifests inside its pinned lifetime.
    check("engine sealed ASC + legacy manifests at both destinations",
          len(res.manifests) == 4, str(res.manifests))
    check("2 verified volume copies", att["independently_verified_destinations"] == 2)
    check("topology honesty: same physical device -> NOT safe to wipe",
          att["distinct_physical_devices"] <= 1 and not att["safe_to_wipe_source"],
          f"devices={att['distinct_physical_devices']}")

    print("[2] cold verify passes clean")
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("clean verify exit 0", code == 0, out.strip())

    print("[3] corrupt one byte mid-file")
    victim = os.path.join(d1, "CARD/CLIPS/A001_C001.braw")
    with open(victim, "r+b") as f:
        f.seek(1_000_000)
        b = f.read(1)
        f.seek(1_000_000)
        f.write(bytes([b[0] ^ 0xFF]))
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("single flipped byte detected", code == 1 and "1 failed" in out, out.strip())
    with open(victim, "r+b") as f:  # heal for later scenarios
        f.seek(1_000_000)
        f.write(b)

    print("[4] truncate a destination file")
    victim2 = os.path.join(d2, "CARD/AUDIO/SC01_T01.wav")
    with open(victim2, "r+b") as f:
        f.truncate(512 * 1024)
    code, out = run_verify(os.path.join(d2, "CARD"))
    check("truncation detected", code == 1 and "1 failed" in out, out.strip())
    shutil.copyfile(os.path.join(src, "AUDIO/SC01_T01.wav"), victim2)

    print("[5] delete + rename at destination")
    os.remove(os.path.join(d1, "CARD/CLIPS/A001_C002.braw"))
    os.rename(os.path.join(d1, "CARD/AUDIO/SC01_T01.wav"),
              os.path.join(d1, "CARD/AUDIO/RENAMED.wav"))
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("missing + renamed surfaced", code == 1 and "2 missing" in out and "1 new" in out, out.strip())
    shutil.copyfile(os.path.join(src, "CLIPS/A001_C002.braw"), os.path.join(d1, "CARD/CLIPS/A001_C002.braw"))
    os.rename(os.path.join(d1, "CARD/AUDIO/RENAMED.wav"), os.path.join(d1, "CARD/AUDIO/SC01_T01.wav"))
    # deleted-then-restored copy differs in mtime only; content matches manifest
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("restored copies verify clean again", code == 0, out.strip())

    print("[6] card continuation: only new clips copy, new MHL generation")
    make_card(src, {"CLIPS/A001_C003.braw": 3 * 1024 * 1024})
    res2 = engine.offload(src, [d1, d2], label="CARD")
    # Scenario 5's restore reset one file's mtime, so the engine must NOT fast-skip
    # it: it hash-adjudicates and skips on content match. Count both skip paths.
    effectively_skipped = sum(
        1 for f in res2.files
        if f.skipped or (f.dest_status
                         and all(s in ("skipped", "trusted") for s in f.dest_status.values()))
    )
    copied_new = [f for f in res2.files
                  if any(s == "verified" for s in f.dest_status.values())]
    check("4 old files skipped (incl. hash-adjudicated), only C003 copied",
          effectively_skipped == 4 and [f.rel_path for f in copied_new] == ["CLIPS/A001_C003.braw"])
    check("continuation fully verified", res2.fully_verified)
    gens = [n for n in os.listdir(os.path.join(d1, "CARD/ascmhl")) if n.endswith(".mhl")]
    check("second MHL generation appended", len(gens) == 2, str(gens))
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("merged-history verify covers all 5 files", code == 0 and "5/5" in out, out.strip())

    print("[7] in-camera filename reuse (same path, different content)")
    orig_hash = hasher.hash_file(os.path.join(d1, "CARD/CLIPS/A001_C002.braw"), ["xxh64"])["xxh64"]
    st = os.stat(os.path.join(src, "CLIPS/A001_C002.braw"))
    with open(os.path.join(src, "CLIPS/A001_C002.braw"), "wb") as f:
        f.write(os.urandom(2 * 1024 * 1024 + 777))  # same size, new content
    os.utime(os.path.join(src, "CLIPS/A001_C002.braw"), ns=(st.st_mtime_ns + 5_000_000_000,) * 2)
    res3 = engine.offload(src, [d1, d2], label="CARD")
    check("collision refused, job fails loudly",
          not res3.ok and any("NAME COLLISION" in e for e in res3.errors))
    after_hash = hasher.hash_file(os.path.join(d1, "CARD/CLIPS/A001_C002.braw"), ["xxh64"])["xxh64"]
    check("prior verified copy preserved bit-for-bit", after_hash == orig_hash)

    print("[8] fast mode is never 'fully verified'")
    d3 = os.path.join(base, "D3")
    os.makedirs(d3)
    res4 = engine.offload(src, [d3], label="CARD", verify_mode="fast", source_reread=False)
    check("fast mode ok but not fully verified", res4.ok and not res4.fully_verified)
    check("fast mode never safe-to-wipe", not res4.attestation()["safe_to_wipe_source"])

    print("[9] same metadata, different bytes, NO manifest backing -> conflict, never skip")
    d4 = os.path.join(base, "D4")
    os.makedirs(os.path.join(d4, "CARD", "CLIPS"))
    victim_rel = "CLIPS/A001_C001.braw"
    src_file = os.path.join(src, victim_rel)
    fake = os.path.join(d4, "CARD", victim_rel)
    st = os.stat(src_file)
    with open(fake, "wb") as f:
        f.write(os.urandom(st.st_size))  # same size, different bytes
    os.utime(fake, ns=(st.st_mtime_ns, st.st_mtime_ns))  # same mtime
    fake_hash = hasher.hash_file(fake, ["xxh64"])["xxh64"]
    res5 = engine.offload(src, [d4], label="CARD", source_reread=False)
    fr = next(f for f in res5.files if f.rel_path == victim_rel)
    check("metadata-twin without history is adjudicated, not trusted",
          fr.dest_status.get(os.path.join(d4, "CARD")) == "conflict" and not res5.ok)
    check("metadata-twin preserved untouched",
          hasher.hash_file(fake, ["xxh64"])["xxh64"] == fake_hash)

    print("[10] label traversal + containment + duplicate destinations refused")
    for bad in ("../ESCAPE", "/abs/path", "a/b", ".."):
        try:
            engine.offload(src, [d3], label=bad)
            check(f"label {bad!r} refused", False)
        except RuntimeError:
            check(f"label {bad!r} refused", True)
    try:
        engine.offload(src, [os.path.join(src, "NESTED_DEST")], label="CARD")
        check("destination inside source refused", False)
    except RuntimeError:
        check("destination inside source refused", True)
    res6 = engine.offload(src, [d3, d3], label="CARD", verify_mode="fast", source_reread=False)
    check("duplicate destinations counted once",
          res6.attestation()["independently_verified_destinations"] <= 1)

    print("[11] symlinks skipped loudly, never dereferenced")
    os.symlink("/etc/hosts", os.path.join(src, "sneaky_link"))
    os.makedirs(os.path.join(base, "D5"), exist_ok=True)
    res7 = engine.offload(src, [os.path.join(base, "D5")], label="CARD", source_reread=False)
    os.remove(os.path.join(src, "sneaky_link"))
    check("symlink not copied as a file",
          not os.path.exists(os.path.join(base, "D5", "CARD", "sneaky_link")))
    check("symlink surfaced as warning",
          any("symlink" in w for w in res7.warnings))

    print("[12] writer crash (non-OSError) fails cleanly, never deadlocks")
    from dumptruck import macio as _macio
    orig = _macio.setup_dest_write_fd
    _macio.setup_dest_write_fd = lambda fd: (_ for _ in ()).throw(ValueError("boom"))
    t0 = time.time()
    try:
        os.makedirs(os.path.join(base, "D6"), exist_ok=True)
        res8 = engine.offload(src, [os.path.join(base, "D6")], label="CARD", source_reread=False)
    finally:
        _macio.setup_dest_write_fd = orig
    check("writer crash -> job fails within 30s, no deadlock",
          time.time() - t0 < 30 and not res8.ok)

    print("[13] unmanifested new files fail verify (completeness)")
    with open(os.path.join(d1, "CARD/CLIPS/UNMANIFESTED.braw"), "wb") as f:
        f.write(os.urandom(1024))
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("new unmanifested file -> verify exit 1", code == 1 and "1 new" in out, out.strip())
    os.remove(os.path.join(d1, "CARD/CLIPS/UNMANIFESTED.braw"))

    print("[13b] Reports inside the sealed folder participates in completeness")
    reports13 = os.path.join(d1, "CARD/Reports")
    os.makedirs(reports13)
    with open(os.path.join(reports13, "UNMANIFESTED.braw"), "wb") as f:
        f.write(b"unmanifested footage")
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("unmanifested footage in Reports -> verify exit 1",
          code == 1 and "1 new" in out, out.strip())
    shutil.rmtree(reports13)
    external_reports13 = os.path.join(d1, "Reports/CARD")
    os.makedirs(external_reports13)
    with open(os.path.join(external_reports13, "report.html"), "w") as f:
        f.write("Generated report outside the sealed card folder")
    code, out = run_verify(os.path.join(d1, "CARD"))
    check("sibling generated reports do not affect card verification",
          code == 0, out.strip())

    print("[14] xxh128 manifest validates against the official XSD")
    d7 = os.path.join(base, "D7")
    os.makedirs(d7)
    res9 = engine.offload(src, [d7], label="CARD", hash_formats=("xxh64", "xxh128", "c4"),
                          source_reread=False)
    gen = mhl.write_ascmhl(os.path.join(d7, "CARD"), res9.files)
    r = subprocess.run(
        [os.path.join(HERE, ".venv/bin/ascmhl-debug"), "xsd-schema-check", gen],
        capture_output=True, text=True, cwd=HERE)
    check("multi-hash manifest is XSD-valid", r.returncode == 0, r.stdout + r.stderr)

    print("[15] fast-mode copies are never sealed, so trust can't be inherited")
    d8 = os.path.join(base, "D8")
    os.makedirs(d8)
    res10 = engine.offload(src, [d8], label="CARD", verify_mode="fast", source_reread=False)
    gen10 = mhl.write_ascmhl(os.path.join(d8, "CARD"), res10.files)
    v11 = mhl.write_mhl_v11(os.path.join(d8, "CARD"), res10.files, res10.started_at, res10.finished_at)
    check("fast-mode files not sealed into ASC MHL", gen10 is None, str(gen10))
    check("fast-mode files not sealed into legacy MHL", v11 is None, str(v11))
    rot = os.path.join(d8, "CARD/CLIPS/A001_C001.braw")
    st8 = os.stat(rot)
    with open(rot, "r+b") as f:
        f.seek(500)
        f.write(b"\x00" * 16)
    os.utime(rot, ns=(st8.st_mtime_ns, st8.st_mtime_ns))
    res11 = engine.offload(src, [d8], label="CARD", source_reread=False)
    check("post-fast corruption is caught, never inherited as trusted",
          not res11.ok and res11.attestation()["files_trusted_from_prior_generations"] == 0)

    print("[16] unreadable source file fails cleanly (writer-sentinel deadlock regression)")
    locked = os.path.join(src, "CLIPS/LOCKED.braw")
    with open(locked, "wb") as f:
        f.write(os.urandom(256 * 1024))
    os.chmod(locked, 0)
    d9 = os.path.join(base, "D9")
    os.makedirs(d9)
    t0 = time.time()
    res12 = engine.offload(src, [d9], label="CARD", source_reread=False)
    elapsed = time.time() - t0
    os.chmod(locked, 0o644)
    os.remove(locked)
    check("source-read failure completes within 30s (no deadlock)",
          elapsed < 30 and not res12.ok, f"{elapsed:.1f}s")
    check("no partial or final file committed for the unreadable source",
          not os.path.exists(os.path.join(d9, "CARD/CLIPS/LOCKED.braw")))

    print("[17] pure continuation attests honestly (no phantom re-read)")
    # Round-13 finding 7: the ENGINE must have sealed the successful rows of
    # the partially failed job itself — no manual write_ascmhl allowed here,
    # it would mask a regression in engine-side failed-job sealing.
    check("engine sealed the good rows of the partially failed job",
          any(os.sep + "ascmhl" + os.sep in m for m in res12.manifests),
          str(res12.manifests))
    res13 = engine.offload(src, [d9], label="CARD")
    att13 = res13.attestation()
    check("all files trusted, zero copied", all(f.skipped for f in res13.files) or
          att13["files_trusted_from_prior_generations"] > 0)
    check("pure-trust run honestly reports zero source reads",
          att13["source_read_count"] == 0, str(att13["source_read_count"]))
    check("pure continuation never grants safe-to-wipe", not att13["safe_to_wipe_source"])
    check("unverified trust is an explicit wipe blocker",
          any("prior-generation trust" in b for b in att13["safe_to_wipe_blockers"]),
          str(att13["safe_to_wipe_blockers"]))

    print("[17b] top-up run: trust blocks wipe until re-verified this run")
    make_card(src, {"CLIPS/TOPUP17.braw": 64 * 1024})
    res13b = engine.offload(src, [d9], label="CARD")
    att13b = res13b.attestation()
    check("top-up copies the new file and trusts the priors",
          res13b.ok and att13b["files_trusted_from_prior_generations"] > 0,
          str(att13b))
    check("mixed continuation still blocked from wipe by unverified trust",
          not att13b["safe_to_wipe_source"]
          and any("prior-generation trust" in b
                  for b in att13b["safe_to_wipe_blockers"]),
          str(att13b["safe_to_wipe_blockers"]))
    res13c = engine.offload(src, [d9], label="CARD", reverify_existing=True)
    att13c = res13c.attestation()
    check("reverify-existing re-reads priors and clears the trust blocker",
          att13c["files_trusted_from_prior_generations"] == 0
          and not any("prior-generation trust" in b
                      for b in att13c["safe_to_wipe_blockers"]),
          str(att13c["safe_to_wipe_blockers"]))

    print("[17d] macOS system litter at a volume root never blocks the scan")
    src17d = os.path.join(base, "CARD17D")
    make_card(src17d, {"CLIPS/A001.mov": 64 * 1024})
    sysdir = os.path.join(src17d, ".DocumentRevisions-V100")
    os.makedirs(sysdir)
    os.chmod(sysdir, 0)  # permission-protected, like the real thing
    try:
        entries17d, _dirs17d, _warn17d = engine.scan_source(src17d)
        check("protected OS system dir is pruned, not walked into",
              [e.rel_path for e in entries17d] == ["CLIPS/A001.mov"],
              str([e.rel_path for e in entries17d]))
    finally:
        os.chmod(sysdir, 0o755)

    print("[17e] an unreadable REAL directory refuses with its actual reason")
    realdir = os.path.join(src17d, "LOCKED_FOOTAGE")
    os.makedirs(realdir)
    os.chmod(realdir, 0)
    try:
        engine.scan_source(src17d)
        check("unreadable non-junk directory still fails closed", False)
    except RuntimeError as e:
        check("unreadable non-junk directory still fails closed",
              "LOCKED_FOOTAGE" in str(e), str(e))
    finally:
        os.chmod(realdir, 0o755)
    import subprocess as _sp
    r17e = _sp.run(
        [os.path.join(os.path.dirname(engine.__file__), "..", ".venv/bin/python"),
         "-m", "dumptruck.cli", "inspect", src17d],
        capture_output=True, text=True,
        cwd=os.path.join(os.path.dirname(engine.__file__), ".."))
    os.chmod(realdir, 0)
    try:
        r17e2 = _sp.run(
            [os.path.join(os.path.dirname(engine.__file__), "..", ".venv/bin/python"),
             "-m", "dumptruck.cli", "inspect", src17d],
            capture_output=True, text=True,
            cwd=os.path.join(os.path.dirname(engine.__file__), ".."))
        obj17e = json.loads(r17e2.stdout.strip().splitlines()[-1])
        check("inspect refusal is protocol JSON naming the real reason",
              r17e2.returncode == 1 and obj17e.get("protocol") == 3
              and "LOCKED_FOOTAGE" in obj17e.get("error", ""),
              r17e2.stdout[:200] + r17e2.stderr[:200])
    finally:
        os.chmod(realdir, 0o755)
    check("healthy source still inspects clean after the refusal",
          r17e.returncode == 0 and '"error"' not in r17e.stdout,
          r17e.stdout[:200])

    print("[17c] empty source refuses to report success")
    src_empty = os.path.join(base, "CARD_EMPTY17")
    os.makedirs(src_empty)
    try:
        engine.offload(src_empty, [d9], label="EMPTYCARD17")
        check("empty source refused, never a green job", False)
    except RuntimeError as e:
        check("empty source refused, never a green job",
              "no copyable files" in str(e), str(e))

    print("[18] chain laundering refused: tampered generation is never re-blessed")
    d10 = os.path.join(base, "D10")
    os.makedirs(d10)
    res14 = engine.offload(src, [d10], label="CARD", source_reread=False)
    mhl.write_ascmhl(os.path.join(d10, "CARD"), res14.files)
    mdir = os.path.join(d10, "CARD", "ascmhl")
    gen_file = next(os.path.join(mdir, n) for n in os.listdir(mdir) if n.endswith(".mhl"))
    with open(gen_file, "r+b") as f:
        f.seek(300)
        b = f.read(1)
        f.seek(300)
        f.write(b"Z" if b != b"Z" else b"Q")
    probs = mhl.verify_chain(os.path.join(d10, "CARD"))
    check("tamper detected by verify_chain", any("C4 MISMATCH" in p for p in probs), str(probs))
    make_card(src, {"CLIPS/A001_C009.braw": 128 * 1024})
    res15 = engine.offload(src, [d10], label="CARD", source_reread=False)
    check("tampered history grants ZERO trust",
          res15.attestation()["files_trusted_from_prior_generations"] == 0)
    try:
        mhl.write_ascmhl(os.path.join(d10, "CARD"), res15.files)
        check("resealing over tampered chain refused", False)
    except RuntimeError:
        check("resealing over tampered chain refused", True)
    probs2 = mhl.verify_chain(os.path.join(d10, "CARD"))
    check("tamper evidence PRESERVED after refused reseal",
          any("C4 MISMATCH" in p for p in probs2), str(probs2))
    os.remove(os.path.join(src, "CLIPS/A001_C009.braw"))

    print("[19] verify-before-commit: a failed checksum never reaches the final path")
    d11 = os.path.join(base, "D11")
    os.makedirs(d11)
    real_cold = engine._cold_hash
    engine._cold_hash = lambda path, result=None, **kw: "deadbeefdeadbeef"  # force mismatch
    try:
        res16 = engine.offload(src, [d11], label="CARD", source_reread=False)
    finally:
        engine._cold_hash = real_cold
    check("forced mismatch fails the job", not res16.ok)
    check("nothing committed to final paths, no partials left",
          not os.path.exists(os.path.join(d11, "CARD/CLIPS/A001_C001.braw"))
          and not any(".dumptruck-partial-" in n
                      for _d, _s, fs in os.walk(os.path.join(d11, "CARD")) for n in fs))

    print("[20] trusted copy diverging from current source is caught")
    d12, d13 = os.path.join(base, "D12"), os.path.join(base, "D13")
    os.makedirs(d12), os.makedirs(d13)
    res17 = engine.offload(src, [d12], label="CARD", source_reread=False)
    mhl.write_ascmhl(os.path.join(d12, "CARD"), res17.files)
    victim_src = os.path.join(src, "CLIPS/A001_C003.braw")
    stv = os.stat(victim_src)
    with open(victim_src, "r+b") as f:
        f.seek(100)
        f.write(b"\xff" * 8)  # same size, new content
    os.utime(victim_src, ns=(stv.st_mtime_ns, stv.st_mtime_ns))  # same mtime
    res18 = engine.offload(src, [d12, d13], label="CARD", source_reread=False)
    check("divergence between trusted copy and current source fails loudly",
          not res18.ok and any("DIVERGES" in e for e in res18.errors))

    print("[21] vanished destination root is refused (never recreated on the boot disk)")
    ghost = os.path.join(base, "GHOST_DEST")  # never created
    try:
        engine.offload(src, [ghost], label="CARD", source_reread=False)
        check("nonexistent dest root refused", False)
    except RuntimeError as e:
        check("nonexistent dest root refused", "does not exist" in str(e), str(e))
    check("refused root was not created", not os.path.exists(ghost))

    print("[22] a dying event sink mid-loop still drains the verify workers (no hang)")
    d14 = os.path.join(base, "D14")
    os.makedirs(d14)
    import threading as _threading
    before_threads = {t.ident for t in _threading.enumerate()}
    calls = {"n": 0}
    def _bomb(evt):
        if evt.get("event") == "file_started":
            calls["n"] += 1
            if calls["n"] >= 2:
                raise RuntimeError("sink died")
    try:
        engine.offload(src, [d14], label="CARD", source_reread=False, event=_bomb)
        check("dying sink propagates", False)
    except RuntimeError:
        check("dying sink propagates", True)
    time.sleep(0.5)
    leaked = [t for t in _threading.enumerate()
              if t.ident not in before_threads and t.is_alive()
              and "_VerifyCommitWorker" in type(t).__name__]
    check("no verify worker outlives the failed job", not leaked, str(leaked))

    print("[23] worker never demotes a committed copy when file_done emission dies")
    d15 = os.path.join(base, "D15")
    os.makedirs(d15)
    def _done_bomb(evt):
        if evt.get("event") == "file_done":
            raise RuntimeError("done sink died")
    res19 = engine.offload(src, [d15], label="CARD", source_reread=False, event=_done_bomb)
    check("job records the emission failures instead of dying",
          any("event emission failed" in e for e in res19.errors), str(res19.errors)[:300])
    check("committed copies stay verified on disk despite the dying sink",
          os.path.exists(os.path.join(d15, "CARD/CLIPS/A001_C001.braw"))
          and any(st == "verified"
                  for fr in res19.files for st in fr.dest_status.values()),
          str([fr.dest_status for fr in res19.files])[:300])

    print("[24] symlink planted inside a card folder is refused before any write")
    d16 = os.path.join(base, "D16")
    os.makedirs(os.path.join(d16, "CARD"))
    os.symlink(os.path.join(src, "CLIPS"), os.path.join(d16, "CARD", "CLIPS"))
    try:
        engine.offload(src, [d16], label="CARD", source_reread=False)
        check("dest symlink to source refused", False)
    except RuntimeError as e:
        check("dest symlink to source refused", "symlink inside the card folder" in str(e), str(e))
    check("source untouched by the refused job",
          not any(".dumptruck" in n for n in os.listdir(os.path.join(src, "CLIPS"))))

    print("[25] source names that collide on case-insensitive destinations are refused")
    real_scan = engine.scan_source
    def _colliding_scan(root):
        entries, dirs, warns = real_scan(root)
        if entries and root == os.path.abspath(src):
            import copy as _copy
            twin = _copy.copy(entries[0])
            twin.rel_path = entries[0].rel_path.swapcase()
            entries = entries + [twin]
        return entries, dirs, warns
    engine.scan_source = _colliding_scan
    d17 = os.path.join(base, "D17")
    os.makedirs(d17)
    try:
        engine.offload(src, [d17], label="CARD", source_reread=False)
        check("case-colliding source names refused", False)
    except RuntimeError as e:
        check("case-colliding source names refused", "collide" in str(e), str(e))
    finally:
        engine.scan_source = real_scan

    print("[26] destination volume swapped mid-job voids the whole destination")
    d18 = os.path.join(base, "D18")
    os.makedirs(d18)
    cr18 = os.path.join(d18, "CARD")
    swapped = {"done": False}
    def _swapper(evt):
        # After the first file finishes, replace the card root with a fresh
        # directory at the same path (new inode = a different mounted volume).
        if evt.get("event") == "file_done" and not swapped["done"]:
            swapped["done"] = True
            os.rename(cr18, cr18 + ".oldvol")
            for dp, _ds, _fs in os.walk(cr18 + ".oldvol"):
                os.makedirs(cr18 + os.path.relpath(dp, cr18 + ".oldvol").lstrip("."),
                            exist_ok=True)
            os.makedirs(os.path.join(cr18, "CLIPS"), exist_ok=True)
    res20 = engine.offload(src, [d18], label="CARD", source_reread=False, event=_swapper)
    check("mid-job root swap fails the job",
          not res20.ok and any("changed during the job" in e for e in res20.errors),
          str(res20.errors)[:300])
    check("swapped root recorded for manifest refusal",
          cr18 in res20.identity_failed_roots, str(res20.identity_failed_roots))
    check("swap can never be safe to wipe",
          not res20.attestation()["safe_to_wipe_source"])

    print("[27] overlapping multi-store devices never count as independent copies")
    d19a, d19b = os.path.join(base, "D19A"), os.path.join(base, "D19B")
    os.makedirs(d19a), os.makedirs(d19b)
    res21 = engine.offload(src, [d19a, d19b], label="CARD", source_reread=True)
    check("two-dest offload verified", res21.fully_verified, str(res21.errors)[:200])
    from dumptruck import macio as _macio
    # attestation() consumes the pinned-lifetime SNAPSHOT (round-10 fix), so
    # topology is simulated by editing the snapshot, not the live resolver.
    cr21a, cr21b = os.path.join(d19a, "CARD"), os.path.join(d19b, "CARD")
    res21.physical_stores_by_root = {cr21a: frozenset({"disk4", "disk5"}),
                                     cr21b: frozenset({"disk4", "disk6"})}
    att_overlap = res21.attestation()
    res21.physical_stores_by_root = {cr21a: frozenset({"disk4"}),
                                     cr21b: frozenset({"disk6"})}
    att_disjoint = res21.attestation()
    check("shared physical store collapses to ONE device (no wipe)",
          att_overlap["distinct_physical_devices"] == 1
          and not att_overlap["safe_to_wipe_source"], str(att_overlap))
    check("disjoint stores still count as two devices",
          att_disjoint["distinct_physical_devices"] == 2, str(att_disjoint))
    print("[27b] attestation never re-resolves live paths after the run")
    real_stores = _macio.physical_stores
    try:
        # A post-run mount swap changes what the PATH resolves to — the
        # attestation must not care (it reads only the pinned snapshot).
        _macio.physical_stores = lambda p: frozenset({"diskSWAPPED_A"}) \
            if "D19A" in p else frozenset({"diskSWAPPED_B"})
        att_swapped = res21.attestation()
    finally:
        _macio.physical_stores = real_stores
    check("post-run resolver changes cannot alter the attested topology",
          att_swapped["distinct_physical_devices"]
          == att_disjoint["distinct_physical_devices"], str(att_swapped))

    print("[28] verify: a directory symlink hiding content makes the card incomplete")
    mhl.write_ascmhl(os.path.join(d19a, "CARD"), res21.files)
    outside = os.path.join(base, "OUTSIDE_TREE")
    os.makedirs(outside)
    with open(os.path.join(outside, "UNSEALED.MOV"), "wb") as f:
        f.write(b"x" * 1024)
    os.symlink(outside, os.path.join(d19a, "CARD", "EXTRA_TREE"))
    code, out = run_verify(os.path.join(d19a, "CARD"))
    check("dir symlink fails cold verify completeness", code != 0, out.strip()[:300])
    os.remove(os.path.join(d19a, "CARD", "EXTRA_TREE"))
    code, out = run_verify(os.path.join(d19a, "CARD"))
    check("clean again after removing the symlink", code == 0, out.strip()[:300])

    print("[29] generation 10000 is a real generation, not an invisible one")
    gen_dir = os.path.join(base, "GEN10K", mhl.ASCMHL_DIR)
    os.makedirs(gen_dir)
    for name in ("0001_CARD_2026-01-01_000000Z.mhl", "10000_CARD_2026-01-01_000001Z.mhl"):
        with open(os.path.join(gen_dir, name), "w") as f:
            f.write("<hashlist/>")
    gens = mhl._generations(gen_dir)
    check("five-digit generation is seen by the chain/verifier",
          [g[0] for g in gens] == [1, 10000], str(gens))

    print("[30] file appearing at the final path AFTER adjudication is never overwritten")
    d20 = os.path.join(base, "D20")
    os.makedirs(d20)
    planted = {}
    def _planter(evt):
        if evt.get("event") == "file_started" and not planted:
            target = os.path.join(d20, "CARD", evt["path"])
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(b"PLANTED-DIFFERENT-CONTENT")
            planted["path"] = target
    res22 = engine.offload(src, [d20], label="CARD", source_reread=False, event=_planter)
    check("post-adjudication appearance fails the job as a collision",
          not res22.ok and any("appeared at the final path" in e for e in res22.errors),
          str(res22.errors)[:300])
    check("planted file preserved bit-for-bit",
          open(planted["path"], "rb").read() == b"PLANTED-DIFFERENT-CONTENT")

    print("[31] destination subdir swapped for a symlink MID-JOB fails loudly")
    d21 = os.path.join(base, "D21")
    os.makedirs(d21)
    swapped2 = {"done": False}
    def _mid_swapper(evt):
        # After preflight passed (first file streaming), redirect CLIPS/ back
        # at the source — the round-7 TOCTOU that manufactured fake copies.
        if evt.get("event") == "file_started" and not swapped2["done"]:
            swapped2["done"] = True
            victim_dir = os.path.join(d21, "CARD", "CLIPS")
            shutil.rmtree(victim_dir, ignore_errors=True)
            os.symlink(os.path.join(src, "CLIPS"), victim_dir)
    res23 = engine.offload(src, [d21], label="CARD", source_reread=False, event=_mid_swapper)
    check("mid-job symlink swap fails the job",
          not res23.ok and not res23.attestation()["safe_to_wipe_source"],
          str(res23.errors)[:300])
    check("no partials or writes leaked into the SOURCE through the link",
          not any("dumptruck-partial" in n for n in os.listdir(os.path.join(src, "CLIPS"))))

    print("[32] uncopyable object appearing mid-job blocks wipe authorization")
    d22 = os.path.join(base, "D22")
    os.makedirs(d22)
    late = {"done": False}
    def _late_symlink(evt):
        if evt.get("event") == "file_started" and not late["done"]:
            late["done"] = True
            os.symlink("/etc/hosts", os.path.join(src, "LATE_LINK"))
    try:
        res24 = engine.offload(src, [d22], label="CARD", source_reread=False,
                               event=_late_symlink)
        check("late uncopyable object flips source_grew_after_scan",
              res24.source_grew_after_scan
              and not res24.attestation()["safe_to_wipe_source"],
              str(res24.warnings)[:300])
    finally:
        os.remove(os.path.join(src, "LATE_LINK"))

    print("[33] source deletion during final-rescan window blocks wipe authorization")
    src33 = os.path.join(base, "CARD33")
    d33a, d33b = os.path.join(base, "D33A"), os.path.join(base, "D33B")
    os.makedirs(d33a), os.makedirs(d33b)
    make_card(src33, {"ONLY.mov": 256 * 1024})
    deleted33 = {"done": False}
    def _delete_after_reread(evt):
        if evt.get("event") == "source_reread_progress" and not deleted33["done"]:
            deleted33["done"] = True
            os.remove(os.path.join(src33, "ONLY.mov"))
    real_stores33 = _macio.physical_stores
    try:
        _macio.physical_stores = lambda p: (frozenset({"disk33a"})
                                             if "D33A" in p else frozenset({"disk33b"}))
        res33 = engine.offload(src33, [d33a, d33b], label="CARD33",
                               event=_delete_after_reread)
        att33 = res33.attestation()
    finally:
        _macio.physical_stores = real_stores33
    check("deleted source file marks the tree changed and refuses wipe",
          deleted33["done"] and res33.source_grew_after_scan
          and not att33["safe_to_wipe_source"], str(res33.warnings)[:300])

    print("[34] an unchained generation is QUARANTINED, never blessed; sealing resumes")
    src34, d34 = os.path.join(base, "CARD34"), os.path.join(base, "D34")
    os.makedirs(d34)
    make_card(src34, {"A.mov": 64 * 1024})
    res34a = engine.offload(src34, [d34], label="CARD34", source_reread=False)
    cr34 = os.path.join(d34, "CARD34")
    gen34 = next(m for m in res34a.manifests if "/ascmhl/" in m)
    rogue34 = os.path.join(os.path.dirname(gen34),
                           "9999_CARD34_2026-08-19_000000Z.mhl")
    shutil.copyfile(gen34, rogue34)
    make_card(src34, {"B.mov": 64 * 1024})
    # The ENGINE's in-lifetime seal must quarantine the orphan and resume.
    res34b = engine.offload(src34, [d34], label="CARD34", source_reread=False)
    gen34b = next((m for m in res34b.manifests if "/ascmhl/" in m), None)
    check("sealing resumes after quarantining the orphan (was: refused forever)",
          gen34b is not None
          and any("quarantined UNCHAINED" in w for w in res34b.warnings),
          str(res34b.warnings)[:300])
    mhl_dir34 = os.path.dirname(gen34)
    check("orphan preserved as evidence, never blessed, chain stays clean",
          any(".unchained.quarantine" in n for n in os.listdir(mhl_dir34))
          and mhl.verify_chain(cr34) == [],
          str(mhl.verify_chain(cr34)) + " / " + str(os.listdir(mhl_dir34)))

    print("[35] only root ascmhl is quarantined; nested media folders are copied")
    src35, d35 = os.path.join(base, "CARD35"), os.path.join(base, "D35")
    os.makedirs(d35)
    make_card(src35, {"MEDIA/ascmhl/payload.bin": 4096})
    res35 = engine.offload(src35, [d35], label="CARD35", source_reread=False)
    check("nested ascmhl payload is copied and represented as media",
          any(f.rel_path == "MEDIA/ascmhl/payload.bin" for f in res35.files)
          and os.path.isfile(os.path.join(d35, "CARD35/MEDIA/ascmhl/payload.bin")))

    print("[36] camera history preservation never overwrites divergent evidence")
    src36, d36 = os.path.join(base, "CARD36"), os.path.join(base, "D36")
    os.makedirs(d36)
    make_card(src36, {"CLIP.mov": 4096, "ascmhl/camera.mhl": 1024})
    res36a = engine.offload(src36, [d36], label="CARD36", source_reread=False)
    preserved36 = os.path.join(d36, "CARD36", engine.CAMERA_MHL_QUARANTINE,
                               "camera.mhl")
    before36 = open(preserved36, "rb").read()
    with open(os.path.join(src36, "ascmhl/camera.mhl"), "wb") as f:
        f.write(os.urandom(1024))
    res36b = engine.offload(src36, [d36], label="CARD36", source_reread=False)
    check("divergent camera history fails closed and preserves prior bytes",
          res36a.camera_history_failed is False and res36b.camera_history_failed
          and open(preserved36, "rb").read() == before36
          and not res36b.attestation()["safe_to_wipe_source"])

    print("[37] same-second legacy manifests never overwrite a prior delivery")
    v37a = mhl.write_mhl_v11(os.path.join(d35, "CARD35"), res35.files,
                             res35.started_at, res35.finished_at)
    v37b = mhl.write_mhl_v11(os.path.join(d35, "CARD35"), res35.files,
                             res35.started_at, res35.finished_at)
    check("legacy manifest allocator chooses a fresh path",
          v37a != v37b and os.path.isfile(v37a) and os.path.isfile(v37b),
          f"{v37a} vs {v37b}")

    print("[38] chain-valid but malformed history fails closed without escaping")
    src38, d38 = os.path.join(base, "CARD38"), os.path.join(base, "D38")
    os.makedirs(d38)
    make_card(src38, {"A.mov": 4096})
    res38 = engine.offload(src38, [d38], label="CARD38", source_reread=False)
    cr38 = os.path.join(d38, "CARD38")
    gen38 = mhl.write_ascmhl(cr38, res38.files)
    gt38 = ET.parse(gen38)
    ns38 = {"m": mhl.ASCMHL_NS}
    hash38 = gt38.getroot().find("m:hashes/m:hash", ns38)
    hash38.remove(hash38.find("m:path", ns38))
    gt38.write(gen38, encoding="UTF-8", xml_declaration=True)
    chain38 = os.path.join(cr38, mhl.ASCMHL_DIR, "ascmhl_chain.xml")
    ct38 = ET.parse(chain38)
    cns38 = {"c": mhl.ASCMHL_CHAIN_NS}
    for row in ct38.getroot().findall("c:hashlist", cns38):
        if row.findtext("c:path", namespaces=cns38) == os.path.basename(gen38):
            row.find("c:c4", cns38).text = hasher.c4_of_file(gen38)
    ct38.write(chain38, encoding="UTF-8", xml_declaration=True)
    problems38, history38 = mhl.load_validated_history(cr38)
    check("malformed sealed record grants no trust and returns a clean problem",
          bool(problems38) and history38 == {}, str(problems38))

    print("[39] JSON protocol is framed by hello and terminal events")
    src39, d39 = os.path.join(base, "CARD39"), os.path.join(base, "D39")
    home39 = os.path.join(base, "HOME39")
    os.makedirs(d39)
    make_card(src39, {"A.mov": 4096})
    env39 = dict(os.environ, DUMPTRUCK_HOME=home39)
    p39 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src39, d39,
         "--label", "CARD39", "--json", "--no-report", "--no-source-verify"],
        capture_output=True, text=True, cwd=HERE, env=env39)
    events39 = [json.loads(line) for line in p39.stdout.splitlines() if line.strip()]
    check("protocol 3 hello is first and matching offload_complete is last",
          p39.returncode == 0 and events39[0].get("event") == "engine_hello"
          and events39[0].get("protocol") == 3
          and events39[-1].get("event") == "offload_complete"
          and events39[-1].get("protocol") == 3,
          (p39.stdout + p39.stderr)[-500:])
    # Round-13 finding 7: lock down the full intermediate ordering, not just
    # the frame — a reorder of sealing/attestation must fail loudly.
    kinds39 = [e.get("event") for e in events39]
    def _idx39(k):
        return kinds39.index(k) if k in kinds39 else -1
    check("job_done -> attestation -> manifests_written -> offload_complete order",
          0 <= _idx39("job_done") < _idx39("attestation")
          < _idx39("manifests_written") < _idx39("offload_complete"),
          str(kinds39))
    # Uniqueness: first-occurrence indexing alone would tolerate duplicated
    # framing/terminal events (round-14 finding 7).
    check("framing and terminal events occur exactly once",
          all(kinds39.count(k) == 1 for k in
              ("engine_hello", "job_done", "attestation",
               "manifests_written", "offload_complete")),
          str(kinds39))

    print("[40] camera-history writer failure degrades and never removes from CWD")
    src40, d40 = os.path.join(base, "CARD40"), os.path.join(base, "D40")
    os.makedirs(d40)
    make_card(src40, {"CLIP.mov": 64 * 1024, "ascmhl/camera.mhl": 2048})
    canary40 = os.path.join(base, "camera-history-cwd-canary")
    open(canary40, "wb").write(b"must survive")
    real_copy_one40 = engine._copy_one
    old_cwd40 = os.getcwd()
    def _fail_camera_writer40(source_file, entry, dest_specs, hash_formats, progress,
                              source_fd=None, src_rel=None, staged_out=None):
        if source_file.startswith(os.path.join(src40, "ascmhl") + os.sep):
            staged = {dest_specs[0][0]:
                      (OSError(5, "injected writer failure"),
                       os.path.basename(canary40), None)}
            return None, staged, OSError(5, "injected source failure"), {
                "writers_nocache": True, "writers_flush": True}
        return real_copy_one40(source_file, entry, dest_specs, hash_formats, progress,
                               source_fd=source_fd, src_rel=src_rel, staged_out=staged_out)
    try:
        engine._copy_one = _fail_camera_writer40
        os.chdir(base)
        res40 = engine.offload(src40, [d40], label="CARD40", source_reread=False)
    finally:
        os.chdir(old_cwd40)
        engine._copy_one = real_copy_one40
    check("media verified ok despite camera-history failure (no TypeError crash)",
          res40.ok and res40.camera_history_failed
          and any("could not preserve camera MHL history" in w for w in res40.warnings),
          str(res40.errors)[:200] + str(res40.warnings)[:200])
    check("failed camera-history cleanup never resolves a relative temp against CWD",
          open(canary40, "rb").read() == b"must survive")
    check("camera-history failure still blocks wipe",
          not res40.attestation()["safe_to_wipe_source"])

    print("[41] append hashes each generation once; committed rollback is preserved")
    make_card(src34, {"C.mov": 16 * 1024})
    res41 = engine.offload(src34, [d34], label="CARD34", source_reread=False)
    # Custody hashing now flows through mhl._c4_pinned (fd-pinned, round-11
    # finding 2) — count THAT to prove each generation is hashed exactly once.
    real_c4_41 = mhl._c4_pinned
    c4_calls41 = []
    def _count_c4_41(name, dir_fd=None):
        c4_calls41.append(os.path.basename(name))
        return real_c4_41(name, dir_fd=dir_fd)
    try:
        mhl._c4_pinned = _count_c4_41
        mhl.write_ascmhl(cr34, res41.files)
    finally:
        mhl._c4_pinned = real_c4_41
    gens41 = [name for _seq, name in mhl._generations(mhl_dir34)]
    check("C4 append reads every existing generation and the new one exactly once",
          len(c4_calls41) == len(gens41) and sorted(c4_calls41) == sorted(gens41),
          f"calls={c4_calls41}, gens={gens41}")

    make_card(src34, {"D.mov": 16 * 1024})
    res41b = engine.offload(src34, [d34], label="CARD34", source_reread=False)
    real_write_generation41 = mhl._write_generation_locked
    def _raise_after_commit41(*args, **kwargs):
        real_write_generation41(*args, **kwargs)
        raise RuntimeError("injected exception after committed chain update")
    try:
        mhl._write_generation_locked = _raise_after_commit41
        try:
            mhl.write_ascmhl(cr34, res41b.files)
            raised41 = False
        except RuntimeError:
            raised41 = True
    finally:
        mhl._write_generation_locked = real_write_generation41
    chain_names41 = set(mhl._read_chain(os.path.join(mhl_dir34, "ascmhl_chain.xml")))
    check("rollback never deletes a generation already referenced by the committed chain",
          raised41 and chain_names41
          and all(os.path.isfile(os.path.join(mhl_dir34, n)) for n in chain_names41)
          and mhl.verify_chain(cr34) == [], str(mhl.verify_chain(cr34)))

    print("[42] path-based history and free-space reads are identity-bracketed")
    src42, d42 = os.path.join(base, "CARD42"), os.path.join(base, "D42")
    os.makedirs(d42)
    make_card(src42, {"A.mov": 32 * 1024})
    res42a = engine.offload(src42, [d42], label="CARD42", source_reread=False)
    cr42 = os.path.join(d42, "CARD42")
    mhl.write_ascmhl(cr42, res42a.files)
    parked42 = cr42 + ".pinned"
    real_load42 = engine._load_history
    def _swap_after_history42(path, warn=None, root_fd=None):
        history = real_load42(path, warn=warn, root_fd=root_fd)
        os.rename(cr42, parked42)
        os.mkdir(cr42)
        return history
    try:
        engine._load_history = _swap_after_history42
        try:
            engine.offload(src42, [d42], label="CARD42", source_reread=False)
            refused_history42 = False
        except RuntimeError as e:
            refused_history42 = "after reading sealed history" in str(e)
    finally:
        engine._load_history = real_load42
        if os.path.isdir(cr42):
            os.rmdir(cr42)
        if os.path.isdir(parked42):
            os.rename(parked42, cr42)
    check("history path swap is refused after the read; no trusted skip can proceed",
          refused_history42)

    parked42b = cr42 + ".pinned-space"
    real_statvfs42 = engine.os.statvfs
    swapped42 = {"done": False}
    def _swap_during_space42(path):
        out = real_statvfs42(path)
        if path == cr42 and not swapped42["done"]:
            swapped42["done"] = True
            os.rename(cr42, parked42b)
            os.mkdir(cr42)
        return out
    try:
        engine.os.statvfs = _swap_during_space42
        try:
            engine.offload(src42, [d42], label="CARD42", source_reread=False)
            refused_space42 = False
        except RuntimeError as e:
            refused_space42 = "after free-space preflight" in str(e)
    finally:
        engine.os.statvfs = real_statvfs42
        if os.path.isdir(cr42):
            os.rmdir(cr42)
        if os.path.isdir(parked42b):
            os.rename(parked42b, cr42)
    check("free-space path swap is refused after the stats return",
          swapped42["done"] and refused_space42)

    print("[43] destination walkers tolerate per-entry disappearance")
    churn43 = os.path.join(base, "CHURN43")
    os.makedirs(os.path.join(churn43, "gone-dir"))
    open(os.path.join(churn43, ".gone-file"), "wb").write(b"x")
    fd43 = os.open(churn43, os.O_RDONLY | os.O_DIRECTORY)
    real_stat43 = engine.os.stat
    def _vanish_stat43(path, *args, **kwargs):
        if path == ".gone-file" and kwargs.get("dir_fd") == fd43:
            try:
                os.remove(os.path.join(churn43, path))
            except FileNotFoundError:
                pass
            raise FileNotFoundError(path)
        return real_stat43(path, *args, **kwargs)
    try:
        engine.os.stat = _vanish_stat43
        engine._assert_no_symlinks_fd(fd43)
        audit_stat_ok43 = True
    except Exception:
        audit_stat_ok43 = False
    finally:
        engine.os.stat = real_stat43
    real_open43 = engine._open_dir_nofollow
    def _vanish_open43(name, dir_fd=None):
        if name == "gone-dir" and dir_fd == fd43:
            try:
                os.rmdir(os.path.join(churn43, name))
            except FileNotFoundError:
                pass
            raise FileNotFoundError(name)
        return real_open43(name, dir_fd=dir_fd)
    try:
        engine._open_dir_nofollow = _vanish_open43
        engine._remove_stale_partials_fd(fd43, re.compile(r"\.dumptruck-partial-\d+-\d+$"),
                                         res40)
        stale_open_ok43 = True
    except Exception:
        stale_open_ok43 = False
    finally:
        engine._open_dir_nofollow = real_open43
        os.close(fd43)
    check("symlink audit skips a file vanished after listdir", audit_stat_ok43)
    check("stale-partial walker skips a directory vanished before recursive open",
          stale_open_ok43)

    print("[44] inspect is protocol-versioned; finalization phase is emitted")
    inspect44 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "inspect", src39],
        capture_output=True, text=True, cwd=HERE, env=env39)
    inspect_obj44 = json.loads(inspect44.stdout)
    check("inspect output requires protocol 3", inspect_obj44.get("protocol") == 3)
    check("post-drain finalizing event is visible to the GUI",
          any(e.get("event") == "finalizing" for e in events39))

    print("[43] source swapped for a symlink to a verified copy voids the re-read proof")
    src43, d43 = os.path.join(base, "CARD43"), os.path.join(base, "D43")
    os.makedirs(d43)
    make_card(src43, {"CLIPS/A.mov": 256 * 1024})
    swapped43 = {"done": False}
    def _swap_source(evt):
        if evt.get("event") == "source_reread_started" and not swapped43["done"]:
            swapped43["done"] = True
            os.rename(src43, src43 + ".real")
            os.symlink(os.path.join(d43, "CARD43"), src43)
    res43 = engine.offload(src43, [d43], label="CARD43", event=_swap_source)
    try:
        check("re-read against a swapped source fails the job",
              swapped43["done"] and not res43.ok
              and any("source changed identity" in e for e in res43.errors),
              str(res43.errors)[:300])
        check("swapped source can never be safe to wipe",
              not res43.attestation()["safe_to_wipe_source"])
    finally:
        os.remove(src43)
        os.rename(src43 + ".real", src43)

    print("[44] symlinked custody files are refused")
    src44, d44 = os.path.join(base, "CARD44"), os.path.join(base, "D44")
    os.makedirs(d44)
    make_card(src44, {"A.mov": 64 * 1024})
    res44 = engine.offload(src44, [d44], label="CARD44", source_reread=False)
    cr44 = os.path.join(d44, "CARD44")
    gen44 = mhl.write_ascmhl(cr44, res44.files)
    aside44 = os.path.join(base, "EXTERNAL_COPY.mhl")
    shutil.copyfile(gen44, aside44)
    os.remove(gen44)
    os.symlink(aside44, gen44)
    probs44 = mhl.verify_chain(cr44)
    check("a symlinked generation is never valid custody",
          probs44 != [], str(probs44)[:200])
    os.remove(gen44)
    shutil.copyfile(aside44, gen44)
    check("restored regular file verifies clean again", mhl.verify_chain(cr44) == [])

    print("[45] duplicate chain rows are custody corruption, not a merge")
    chain44 = os.path.join(cr44, mhl.ASCMHL_DIR, "ascmhl_chain.xml")
    ct45 = ET.parse(chain44)
    root45 = ct45.getroot()
    ns45 = {"c": mhl.ASCMHL_CHAIN_NS}
    row45 = root45.find("c:hashlist", ns45)
    root45.append(row45)  # exact duplicate row
    ct45.write(chain44, encoding="UTF-8", xml_declaration=True)
    probs45 = mhl.verify_chain(cr44)
    check("duplicate chain rows refuse validation",
          any("unparseable" in p for p in probs45), str(probs45)[:200])

    print("[46] camera history vanishing mid-job closes both wipe gates")
    src46, d46 = os.path.join(base, "CARD46"), os.path.join(base, "D46")
    os.makedirs(d46)
    make_card(src46, {"CLIP.mov": 64 * 1024, "ascmhl/camera.mhl": 512})
    gone46 = {"done": False}
    def _vanish_history(evt):
        if evt.get("event") == "file_done" and not gone46["done"]:
            gone46["done"] = True
            shutil.rmtree(os.path.join(src46, "ascmhl"))
    res46 = engine.offload(src46, [d46], label="CARD46", source_reread=False,
                           event=_vanish_history)
    check("vanished camera history sets BOTH gates",
          gone46["done"] and res46.camera_history_failed
          and res46.source_grew_after_scan
          and not res46.attestation()["safe_to_wipe_source"],
          f"cam_failed={res46.camera_history_failed} grew={res46.source_grew_after_scan}")

    print("[47] a FIFO planted mid-job fails the copy instead of hanging forever")
    # Runs in a KILLABLE child with a hard timeout (round-14: an in-process
    # regression would block this very test before its <30s assertion could
    # execute). The child plants the FIFO inside _copy_one — the pipelined
    # reader outruns event-driven sabotage — then attacks the chain file and
    # the cli-verify hash path, so no blocking open can pass vacuously.
    src47, d47 = os.path.join(base, "CARD47"), os.path.join(base, "D47")
    os.makedirs(d47)
    make_card(src47, {"A.mov": 32 * 1024, "B.mov": 32 * 1024})
    script47 = f'''
import os, sys
sys.path.insert(0, {HERE!r})
from dumptruck import engine, mhl, hasher
src, dst = {src47!r}, {d47!r}
real = engine._copy_one
state = {{"planted": False}}
def plant(source_file, entry, *a, **kw):
    if entry.rel_path == "B.mov" and not state["planted"]:
        state["planted"] = True
        t = os.path.join(src, "B.mov")
        os.remove(t); os.mkfifo(t)
    return real(source_file, entry, *a, **kw)
engine._copy_one = plant
res = engine.offload(src, [dst], label="CARD47", source_reread=False)
print("PLANTED" if state["planted"] else "NOT_PLANTED")
print("OFFLOAD_FAILED_CLOSED" if not res.ok else "OFFLOAD_OK")
card = os.path.join(dst, "CARD47")
chain = os.path.join(card, "ascmhl", "ascmhl_chain.xml")
print("CHAIN_EXISTS" if os.path.isfile(chain) else "NO_CHAIN")
if os.path.isfile(chain):
    os.remove(chain); os.mkfifo(chain)
    print("CHAIN_PROBLEMS" if mhl.verify_chain(card) else "CHAIN_CLEAN")
    os.remove(chain)
media = os.path.join(card, "A.mov")
os.remove(media); os.mkfifo(media)
try:
    hasher.hash_file(media, ["xxh64"])
    print("HASHFILE_ACCEPTED_FIFO")
except OSError:
    print("HASHFILE_REFUSED_FIFO")
'''
    try:
        p47 = subprocess.run([sys.executable, "-c", script47],
                             capture_output=True, text=True, cwd=HERE, timeout=90)
        out47 = p47.stdout
    except subprocess.TimeoutExpired:
        out47 = "TIMEOUT — a blocking open hung the child"
    check("FIFO source fails closed (killable child, hard timeout)",
          "PLANTED" in out47 and "OFFLOAD_FAILED_CLOSED" in out47, out47[:300])
    check("FIFO custody file is a chain problem, not a hang",
          "CHAIN_EXISTS" in out47 and "CHAIN_PROBLEMS" in out47, out47[:300])
    check("cli-verify hash path refuses a FIFO instead of blocking",
          "HASHFILE_REFUSED_FIFO" in out47, out47[:300])

    print("[48] ascmhl/ renamed-and-replaced during sealing voids the seal")
    src48, d48 = os.path.join(base, "CARD48"), os.path.join(base, "D48")
    os.makedirs(d48)
    make_card(src48, {"A.mov": 16 * 1024})
    mdir48 = os.path.join(d48, "CARD48", "ascmhl")
    real_write_gen48 = mhl._write_generation_locked
    def _hijack48(mhl_fd, fname, now, recordable, author, chain_c4s):
        real_write_gen48(mhl_fd, fname, now, recordable, author, chain_c4s)
        # After the seal lands, swap the canonical name to an impostor dir.
        os.rename(mdir48, mdir48 + ".hijacked")
        os.mkdir(mdir48)
    try:
        mhl._write_generation_locked = _hijack48
        res48 = engine.offload(src48, [d48], label="CARD48", source_reread=False)
    finally:
        mhl._write_generation_locked = real_write_gen48
    check("replaced ascmhl/ fails the seal and the job",
          not res48.ok and any("renamed or replaced" in e for e in res48.errors),
          str(res48.errors))
    check("no manifest path reported for the hijacked root",
          not any("CARD48" in m for m in res48.manifests), str(res48.manifests))

    print("[49] chain lock refuses a missing ascmhl descriptor (no CWD lock file)")
    canary49 = os.path.join(base, "CWD49")
    os.makedirs(canary49)
    old_cwd49 = os.getcwd()
    try:
        os.chdir(canary49)
        try:
            mhl._ChainLock(None)
            check("ChainLock(None) raises", False)
        except ValueError:
            check("ChainLock(None) raises", True)
    finally:
        os.chdir(old_cwd49)
    check("no lock file leaked into the CWD",
          not os.path.exists(os.path.join(canary49, ".dumptruck-lock")))

    print("[50] same-size camera-history rewrite between destinations is caught")
    src50 = os.path.join(base, "CARD50")
    d50a, d50b = os.path.join(base, "D50A"), os.path.join(base, "D50B")
    os.makedirs(d50a), os.makedirs(d50b)
    make_card(src50, {"CLIP.mov": 32 * 1024, "ascmhl/camera.mhl": 1024})
    hist50 = os.path.join(src50, "ascmhl", "camera.mhl")
    st50 = os.lstat(hist50)
    real_preserve50 = engine._preserve_camera_history
    calls50 = {"n": 0}
    def _mutating_preserve50(src_history, card_root, root_fd, result, source_fd=None):
        snap = real_preserve50(src_history, card_root, root_fd, result,
                               source_fd=source_fd)
        calls50["n"] += 1
        if calls50["n"] == 1:
            # Rewrite with DIFFERENT bytes, same size, restored mtime — the
            # metadata-only snapshot missed this entirely (round-13 finding 2).
            with open(hist50, "r+b") as f:
                f.write(b"X" * st50.st_size)
            os.utime(hist50, ns=(st50.st_atime_ns, st50.st_mtime_ns))
        return snap
    try:
        engine._preserve_camera_history = _mutating_preserve50
        res50 = engine.offload(src50, [d50a, d50b], label="CARD50",
                               source_reread=False)
    finally:
        engine._preserve_camera_history = real_preserve50
    check("divergent same-metadata camera history closes the wipe gate",
          calls50["n"] == 2 and res50.camera_history_failed
          and not res50.attestation()["safe_to_wipe_source"],
          f"calls={calls50['n']} cam_failed={res50.camera_history_failed}")

    print("[51] the pinned source descriptor is closed by offload()")
    # Deterministic: capture the EXACT fd the engine pins for the source and
    # assert it is invalid (EBADF) the moment offload() returns. Net
    # /dev/fd counting was environment-dependent (round-14 finding 7).
    src51, d51 = os.path.join(base, "CARD51"), os.path.join(base, "D51")
    os.makedirs(d51)
    make_card(src51, {"A.mov": 8 * 1024})
    captured51 = {}
    real_open_dir51 = engine._open_dir_nofollow
    def _capture51(path, dir_fd=None):
        fd = real_open_dir51(path, dir_fd=dir_fd)
        if dir_fd is None and path == os.path.realpath(src51):
            captured51["fd"] = fd
        return fd
    try:
        engine._open_dir_nofollow = _capture51
        engine.offload(src51, [d51], label="CARD51", source_reread=False)
    finally:
        engine._open_dir_nofollow = real_open_dir51
    closed51 = False
    if "fd" in captured51:
        try:
            os.fstat(captured51["fd"])
        except OSError:
            closed51 = True
    check("source pin fd is EBADF after offload returns",
          "fd" in captured51 and closed51, str(captured51))

    print("[52] a committed ASC generation survives a legacy-manifest failure")
    src52, d52 = os.path.join(base, "CARD52"), os.path.join(base, "D52")
    os.makedirs(d52)
    make_card(src52, {"A.mov": 8 * 1024})
    real_v11_52 = mhl.write_mhl_v11
    def _fail_v11_52(*a, **kw):
        raise OSError(28, "injected ENOSPC during legacy manifest write")
    try:
        mhl.write_mhl_v11 = _fail_v11_52
        res52 = engine.offload(src52, [d52], label="CARD52", source_reread=False)
    finally:
        mhl.write_mhl_v11 = real_v11_52
    check("job fails closed on the legacy write failure",
          not res52.ok and any("manifest write failed" in e for e in res52.errors),
          str(res52.errors))
    check("the sealed ASC generation is still reported in result.manifests",
          any(os.sep + "ascmhl" + os.sep in m for m in res52.manifests),
          str(res52.manifests))
    asc52 = next((m for m in res52.manifests if os.sep + "ascmhl" + os.sep in m), None)
    check("the reported ASC path exists on disk and its chain validates",
          asc52 is not None and os.path.isfile(asc52)
          and mhl.verify_chain(os.path.join(d52, "CARD52")) == [],
          str(asc52))

    print("[53] ascmhl/ swapped after history load voids a pure continuation")
    src53, d53 = os.path.join(base, "CARD53"), os.path.join(base, "D53")
    os.makedirs(d53)
    make_card(src53, {"A.mov": 16 * 1024})
    res53a = engine.offload(src53, [d53], label="CARD53", source_reread=False)
    card53 = os.path.join(d53, "CARD53")
    mdir53 = os.path.join(card53, "ascmhl")
    real_lvh53 = mhl.load_validated_history_bound
    def _swap_after_load53(card_root, root_fd=None):
        out = real_lvh53(card_root, root_fd=root_fd)
        # Trust has been granted from the loaded history; now replace the
        # custody directory at its canonical name (round-14 finding 1: no
        # recordable rows on a pure continuation meant NO later binding
        # check ever ran).
        if os.path.isdir(mdir53) and not os.path.isdir(mdir53 + ".hijack"):
            os.rename(mdir53, mdir53 + ".hijack")
            os.mkdir(mdir53)
        return out
    try:
        mhl.load_validated_history_bound = _swap_after_load53
        res53b = engine.offload(src53, [d53], label="CARD53", source_reread=False)
    finally:
        mhl.load_validated_history_bound = real_lvh53
    check("pure continuation over a swapped ascmhl/ fails the seal",
          res53a.ok and not res53b.ok
          and any("voided" in e or "replaced" in e for e in res53b.errors),
          str(res53b.errors))
    check("swapped-custody continuation never grants safe-to-wipe",
          not res53b.attestation()["safe_to_wipe_source"])

    print("[54] ascmhl/ swapped between the ASC and legacy writers is caught")
    src54, d54 = os.path.join(base, "CARD54"), os.path.join(base, "D54")
    os.makedirs(d54)
    make_card(src54, {"A.mov": 16 * 1024})
    card54 = os.path.join(d54, "CARD54")
    mdir54 = os.path.join(card54, "ascmhl")
    real_v11_54b = mhl.write_mhl_v11
    def _swap_then_v11_54(card_root, *a, **kw):
        if os.path.isdir(mdir54) and not os.path.isdir(mdir54 + ".hijack"):
            os.rename(mdir54, mdir54 + ".hijack")
            os.mkdir(mdir54)
        return real_v11_54b(card_root, *a, **kw)
    try:
        mhl.write_mhl_v11 = _swap_then_v11_54
        res54 = engine.offload(src54, [d54], label="CARD54", source_reread=False)
    finally:
        mhl.write_mhl_v11 = real_v11_54b
    check("mid-seal ascmhl/ swap fails the job and retracts its manifests",
          not res54.ok and not any("CARD54" in m for m in res54.manifests)
          and any("voided" in e or "replaced" in e for e in res54.errors),
          f"manifests={res54.manifests} errors={res54.errors[:2]}")

    print("[55] report manifest grouping is exact for nested destination roots")
    parent55 = os.path.join(base, "D55")
    child55 = os.path.join(parent55, "nested")
    fake55 = engine.OffloadResult(
        label="CARD55", source=os.path.join(base, "SRC55"),
        destinations=[parent55, child55], started_at=0.0,
        finished_at=1.0, verify_mode="full")
    fake55.manifests = [
        os.path.join(parent55, "CARD55", "ascmhl", "parent_asc.mhl"),
        os.path.join(parent55, "CARD55", "parent_legacy.mhl"),
        os.path.join(child55, "CARD55", "ascmhl", "child_asc.mhl"),
        os.path.join(child55, "CARD55", "child_legacy.mhl"),
    ]
    card55 = type("Card", (), {"format_name": "Generic"})()
    att55 = fake55.attestation()
    doc55, _receipt55 = report.build_report(fake55, att55, card55, {})
    footer55 = doc55.split("manifests sealed this job — ", 1)[1].split("</div>", 1)[0]
    parent_part55, child_part55 = footer55.split(" · ", 1)
    check("parent footer excludes child manifests",
          "parent_asc.mhl" in parent_part55
          and "parent_legacy.mhl" in parent_part55
          and "child_asc.mhl" not in parent_part55
          and "child_legacy.mhl" not in parent_part55,
          parent_part55)
    check("child footer lists only child manifests",
          "child_asc.mhl" in child_part55
          and "child_legacy.mhl" in child_part55
          and "parent_asc.mhl" not in child_part55,
          child_part55)

    print("[56] hash_file closes its raw fd when fdopen construction fails")
    raw56 = os.path.join(base, "hash56.bin")
    with open(raw56, "wb") as f:
        f.write(b"hash me")
    real_fdopen56 = hasher.os.fdopen
    captured56 = {}
    def _fail_fdopen56(fd, *a, **kw):
        captured56["fd"] = fd
        raise RuntimeError("injected fdopen failure")
    try:
        hasher.os.fdopen = _fail_fdopen56
        try:
            hasher.hash_file(raw56, ["xxh64"])
        except RuntimeError:
            pass
    finally:
        hasher.os.fdopen = real_fdopen56
    closed56 = False
    try:
        os.fstat(captured56["fd"])
    except OSError:
        closed56 = True
    check("hash_file fd is EBADF after fdopen failure", closed56,
          str(captured56))

    print("[57] protocol epoch and wipe-blocker reasons are authoritative")
    check("post-fix engine protocol epoch is 3", PROTOCOL_VERSION == 3,
          str(PROTOCOL_VERSION))
    blockers57 = res53b.attestation().get("safe_to_wipe_blockers", [])
    check("unsafe attestation supplies concrete blocker reasons",
          bool(blockers57) and not res53b.attestation()["safe_to_wipe_source"],
          str(blockers57))

    print("[58] fresh-card ascmhl swap right after the ASC writer returns")
    # Round-15 PR review finding 1: with no trusted history (expected=None),
    # the engine used to establish the binding reference by sampling the
    # canonical name AFTER write_ascmhl returned — a swap in that gap made it
    # adopt the impostor's identity. The identity now comes from INSIDE the
    # chain lock, so the same swap must void the seal.
    src58, d58 = os.path.join(base, "CARD58"), os.path.join(base, "D58")
    os.makedirs(d58)
    make_card(src58, {"A.mov": 16 * 1024})
    card58 = os.path.join(d58, "CARD58")
    mdir58 = os.path.join(card58, "ascmhl")
    real_wab58 = mhl.write_ascmhl_bound
    def _swap_after_write58(card_root, *a, **kw):
        out = real_wab58(card_root, *a, **kw)
        if os.path.isdir(mdir58) and not os.path.isdir(mdir58 + ".hijack"):
            os.rename(mdir58, mdir58 + ".hijack")
            os.mkdir(mdir58)
        return out
    try:
        mhl.write_ascmhl_bound = _swap_after_write58
        res58 = engine.offload(src58, [d58], label="CARD58", source_reread=False)
    finally:
        mhl.write_ascmhl_bound = real_wab58
    check("post-return swap on a FRESH card voids the seal and retracts manifests",
          not res58.ok and not any("CARD58" in m for m in res58.manifests)
          and any("voided" in e or "replaced" in e for e in res58.errors),
          f"ok={res58.ok} manifests={res58.manifests} errors={res58.errors[:2]}")
    check("fresh-card swap never grants safe-to-wipe",
          not res58.attestation()["safe_to_wipe_source"])

    print("[59] every JSON pre-engine refusal ends with a strict v3 terminal")
    src59, d59 = os.path.join(base, "CARD59"), os.path.join(base, "D59")
    os.makedirs(src59), os.makedirs(d59)
    env59 = dict(os.environ)
    env59["DUMPTRUCK_HOME"] = os.path.join(base, "state59")
    p59 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src59, d59,
         "--label", "../BAD", "--json"],
        capture_output=True, text=True, cwd=HERE, env=env59,
    )
    events59 = [json.loads(line) for line in p59.stdout.splitlines() if line.strip()]
    terminal59 = events59[-1] if events59 else {}
    check("invalid-label refusal emits exactly one all-false v3 terminal",
          p59.returncode == 2
          and sum(e.get("event") == "offload_complete" for e in events59) == 1
          and terminal59 == {"event": "offload_complete", "ok": False,
                             "protocol": PROTOCOL_VERSION,
                             "fully_verified": False,
                             "safe_to_wipe_source": False},
          f"exit={p59.returncode} events={events59}")

    print("[60] rotational admission preserves complete verification and attestation")
    src60 = os.path.join(base, "CARD60")
    d60sa, d60sb = os.path.join(base, "D60SA"), os.path.join(base, "D60SB")
    d60ra, d60rb = os.path.join(base, "D60RA"), os.path.join(base, "D60RB")
    for d in (d60sa, d60sb, d60ra, d60rb):
        os.makedirs(d)
    make_card(src60, {"A.mov": 256 * 1024, "B.mov": 192 * 1024})
    real_stores60 = engine.macio.physical_stores
    real_classify60 = engine._device_is_solid_state
    def _stores60(path):
        if "D60SA" in path or "D60RA" in path:
            return frozenset({"disk60a"})
        if "D60SB" in path or "D60RB" in path:
            return frozenset({"disk60b"})
        return real_stores60(path)
    try:
        engine.macio.physical_stores = _stores60
        engine._device_is_solid_state = lambda _device: True
        res60s = engine.offload(src60, [d60sa, d60sb], label="CARD60")
        engine._device_is_solid_state = lambda _device: False
        res60r = engine.offload(src60, [d60ra, d60rb], label="CARD60")
    finally:
        engine.macio.physical_stores = real_stores60
        engine._device_is_solid_state = real_classify60
    proof60s = [(f.rel_path, sorted(f.dest_status.values()), f.hashes)
                for f in res60s.files]
    proof60r = [(f.rel_path, sorted(f.dest_status.values()), f.hashes)
                for f in res60r.files]
    check("rotational deferral produces the same complete wipe-safe attestation",
          res60s.fully_verified and res60r.fully_verified
          and proof60s == proof60r
          and {k: v for k, v in res60s.attestation().items() if k != "verify_schedule"}
          == {k: v for k, v in res60r.attestation().items() if k != "verify_schedule"}
          and res60r.attestation()["safe_to_wipe_source"],
          f"ssd={res60s.attestation()} rotational={res60r.attestation()}")

    print("[61] one rotational device never mixes copy writes and verify reads")
    src61 = os.path.join(base, "CARD61")
    d61a, d61b = os.path.join(base, "D61A"), os.path.join(base, "D61B")
    os.makedirs(d61a), os.makedirs(d61b)
    make_card(src61, {"A.mov": 256 * 1024, "B.mov": 256 * 1024,
                      "C.mov": 256 * 1024})
    real_stores61 = engine.macio.physical_stores
    real_classify61 = engine._device_is_solid_state
    real_copy61 = engine._copy_one
    real_cold61 = engine._cold_hash
    observed61 = {"writes": 0, "verify": 0, "max_verify": 0,
                  "reads": 0, "overlaps": 0}
    observed_lock61 = threading.Lock()
    def _copy_observed61(*args, **kwargs):
        with observed_lock61:
            observed61["writes"] += 1
        try:
            return real_copy61(*args, **kwargs)
        finally:
            with observed_lock61:
                observed61["writes"] -= 1
    def _cold_observed61(path, *args, **kwargs):
        staged = ".dumptruck-partial-" in os.fsdecode(path)
        if not staged:
            return real_cold61(path, *args, **kwargs)
        with observed_lock61:
            observed61["reads"] += 1
            observed61["overlaps"] += int(observed61["writes"] > 0)
            observed61["verify"] += 1
            observed61["max_verify"] = max(
                observed61["max_verify"], observed61["verify"])
        try:
            time.sleep(0.01)
            return real_cold61(path, *args, **kwargs)
        finally:
            with observed_lock61:
                observed61["verify"] -= 1
    try:
        engine.macio.physical_stores = lambda _path: frozenset({"disk61"})
        engine._device_is_solid_state = lambda _device: False
        engine._copy_one = _copy_observed61
        engine._cold_hash = _cold_observed61
        res61 = engine.offload(src61, [d61a, d61b], label="CARD61",
                               source_reread=False)
    finally:
        engine.macio.physical_stores = real_stores61
        engine._device_is_solid_state = real_classify61
        engine._copy_one = real_copy61
        engine._cold_hash = real_cold61
    check("shared rotational governor defers and serializes every verify read",
          res61.fully_verified and observed61["reads"] == 6
          and observed61["overlaps"] == 0 and observed61["max_verify"] == 1,
          str(observed61))

    print("[62] classification failure retains solid-state overlap")
    src62, d62 = os.path.join(base, "CARD62"), os.path.join(base, "D62")
    os.makedirs(d62)
    make_card(src62, {"A.mov": 256 * 1024, "B.mov": 256 * 1024})
    real_stores62 = engine.macio.physical_stores
    real_classify62 = engine._device_is_solid_state
    def _classification_fails62(_device):
        raise OSError(5, "injected diskutil failure")
    try:
        engine.macio.physical_stores = lambda _path: frozenset({"disk62"})
        engine._device_is_solid_state = _classification_fails62
        probe_root62 = os.path.join(d62, "CARD62")
        governor62 = engine._VerifyAdmissionGovernor(
            [probe_root62], {probe_root62: frozenset({"disk62"})})
        fallback_ssd62 = (governor62._stores_by_root[probe_root62] == ()
                          and governor62._locks_by_store == {})
        res62 = engine.offload(src62, [d62], label="CARD62",
                               source_reread=False)
    finally:
        engine.macio.physical_stores = real_stores62
        engine._device_is_solid_state = real_classify62
    check("classification failure falls back to fully overlapped SSD scheduling",
          res62.fully_verified and fallback_ssd62,
          f"fully_verified={res62.fully_verified} fallback_ssd={fallback_ssd62}")

    print("[63] verify terminal is strict v3 and discloses cache-bypass status")
    src63, d63 = os.path.join(base, "CARD63"), os.path.join(base, "D63")
    os.makedirs(d63)
    make_card(src63, {"A.mov": 4096})
    res63 = engine.offload(src63, [d63], label="CARD63", source_reread=False)
    p63 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "verify",
         os.path.join(d63, "CARD63"), "--json"],
        capture_output=True, text=True, cwd=HERE)
    terminal63 = json.loads(p63.stdout.strip().splitlines()[-1])
    check("verify JSON terminal carries exact protocol 3",
          p63.returncode == 0 and terminal63.get("event") == "verify_done"
          and terminal63.get("protocol") == PROTOCOL_VERSION,
          str(terminal63))
    check("verify JSON terminal carries boolean F_NOCACHE status",
          isinstance(terminal63.get("f_nocache"), bool), str(terminal63))

    print("[64] escaping manifest paths are rejected, never omitted")
    cr64 = os.path.join(d63, "CARD63")
    gen64 = next(m for m in res63.manifests if "/ascmhl/" in m)
    gt64 = ET.parse(gen64)
    path64 = gt64.getroot().find("m:hashes/m:hash", {"m": mhl.ASCMHL_NS})
    path64.find("m:path", {"m": mhl.ASCMHL_NS}).text = "../ESCAPE.mov"
    gt64.write(gen64, encoding="UTF-8", xml_declaration=True)
    chain64 = os.path.join(cr64, mhl.ASCMHL_DIR, "ascmhl_chain.xml")
    ct64 = ET.parse(chain64)
    cns64 = {"c": mhl.ASCMHL_CHAIN_NS}
    for row64 in ct64.getroot().findall("c:hashlist", cns64):
        if row64.findtext("c:path", namespaces=cns64) == os.path.basename(gen64):
            row64.find("c:c4", cns64).text = hasher.c4_of_file(gen64)
    ct64.write(chain64, encoding="UTF-8", xml_declaration=True)
    p64 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "verify", cr64, "--json"],
        capture_output=True, text=True, cwd=HERE)
    terminal64 = json.loads(p64.stdout.strip().splitlines()[-1])
    check("escaping manifest path fails verification with a visible problem",
          p64.returncode == 1 and terminal64.get("protocol") == PROTOCOL_VERSION
          and terminal64.get("passed") == 0
          and any("escaping or malformed" in p for p in terminal64.get("chain_problems", [])),
          str(terminal64))

    print("[65] nested directory replacement during checksum read fails closed")
    nested65 = os.path.join(base, "PIN65")
    os.makedirs(os.path.join(nested65, "N"))
    with open(os.path.join(nested65, "N", "A.mov"), "wb") as f:
        f.write(os.urandom(64 * 1024))
    rootfd65 = os.open(nested65, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    real_hash65 = hasher._hash_open_fd
    swapped65 = {"done": False}
    def swap_nested65(*args, **kwargs):
        if not swapped65["done"]:
            swapped65["done"] = True
            os.rename(os.path.join(nested65, "N"), os.path.join(nested65, "N.real"))
            os.mkdir(os.path.join(nested65, "N"))
            with open(os.path.join(nested65, "N", "A.mov"), "wb") as f:
                f.write(b"replacement")
        return real_hash65(*args, **kwargs)
    try:
        hasher._hash_open_fd = swap_nested65
        try:
            hasher.hash_file_at(rootfd65, "N/A.mov", ["xxh64"])
            nested_failed65 = False
        except OSError:
            nested_failed65 = True
    finally:
        hasher._hash_open_fd = real_hash65
        os.close(rootfd65)
    check("nested replacement is detected after descriptor-pinned read",
          swapped65["done"] and nested_failed65)

    print("[66] wrap report rejects malformed receipt files and schemas")
    wr66 = os.path.join(base, "WRAP66")
    os.makedirs(wr66)
    # Corrupt JSON
    bad_json66 = os.path.join(wr66, "bad_syntax.receipt.json")
    with open(bad_json66, "w") as f:
        f.write("{ invalid json")
    try:
        report.load_and_validate_receipt(bad_json66)
        bad_json_caught = False
    except ValueError:
        bad_json_caught = True
    check("corrupted JSON receipt is rejected", bad_json_caught)

    # Missing required keys (missing job_id / label / verdict / attestation)
    missing_keys66 = os.path.join(wr66, "missing_keys.receipt.json")
    with open(missing_keys66, "w") as f:
        json.dump({"label": "CARD_A"}, f)
    try:
        report.load_and_validate_receipt(missing_keys66)
        missing_keys_caught = False
    except ValueError:
        missing_keys_caught = True
    check("receipt missing required fields is rejected", missing_keys_caught)

    # Empty file
    empty66 = os.path.join(wr66, "empty.receipt.json")
    with open(empty66, "w") as f:
        pass
    try:
        report.load_and_validate_receipt(empty66)
        empty_caught = False
    except ValueError:
        empty_caught = True
    check("empty receipt file is rejected", empty_caught)

    # Directory passed instead of file
    try:
        report.load_and_validate_receipt(wr66)
        dir_caught = False
    except ValueError:
        dir_caught = True
    check("directory path as receipt is rejected", dir_caught)

    print("[67] wrap report neutralizes HTML injection across all metadata fields")
    wr67 = os.path.join(base, "WRAP67")
    os.makedirs(wr67)
    xss_payload = "<script>alert('pwned')</script><img src=x onerror=alert(1)>"
    xss_receipt67 = {
        "job_id": "XSS-JOB-001",
        "label": f"CARD_XSS_{xss_payload}",
        "source": f"/Volumes/SRC_{xss_payload}",
        "destinations": [f"/Volumes/DEST_{xss_payload}"],
        "verdict": f"FULLY VERIFIED_{xss_payload}",
        "attestation": {
            "safe_to_wipe_source": True,
            "distinct_physical_devices": 2,
            "independently_verified_destinations": 1,
            "source_read_count": 2,
            "source_reread_consistent": True,
            "write_fd_nocache": True,
            "verify_fd_nocache": True,
            "full_flush_before_close": True,
            "destination_readback": True,
        },
        "files_total": 1,
        "files_copied": 1,
        "bytes_copied": 1024,
        "errors": [f"Error with payload {xss_payload}"],
        "files": [
            {
                "path": f"Clips/{xss_payload}.mov",
                "size": 1024,
                "outcome": "verified",
                "hashes": {"xxh64": "0123456789abcdef"},
                "status": {},
            }
        ],
    }
    xss_path67 = os.path.join(wr67, "xss.receipt.json")
    with open(xss_path67, "w") as f:
        json.dump(xss_receipt67, f)

    doc67, _ = report.build_wrap_report([report.load_and_validate_receipt(xss_path67)])
    check("HTML injection is escaped in output",
          "<script>" not in doc67 and "<img" not in doc67
          and "&lt;script&gt;" in doc67 and "&lt;img" in doc67 and "CARD_XSS_" in doc67)


    print("[68] wrap report rejects duplicate receipts and duplicate job IDs")
    wr68 = os.path.join(base, "WRAP68")
    os.makedirs(wr68)
    valid_receipt68_a = {
        "job_id": "JOB-68-DUP",
        "label": "CARD_68_A",
        "source": "/Volumes/CARD_A",
        "destinations": ["/Volumes/DEST_1"],
        "verdict": "FULLY VERIFIED",
        "attestation": {"safe_to_wipe_source": True},
        "files_total": 1, "files_copied": 1, "bytes_copied": 2048,
        "files": [{"path": "A.mov", "size": 2048, "outcome": "verified", "hashes": {"xxh64": "1111111111111111"}}],
    }
    valid_receipt68_b = {
        "job_id": "JOB-68-DUP",
        "label": "CARD_68_B",
        "source": "/Volumes/CARD_B",
        "destinations": ["/Volumes/DEST_1"],
        "verdict": "FULLY VERIFIED",
        "attestation": {"safe_to_wipe_source": True},
        "files_total": 1, "files_copied": 1, "bytes_copied": 4096,
        "files": [{"path": "B.mov", "size": 4096, "outcome": "verified", "hashes": {"xxh64": "2222222222222222"}}],
    }
    path68_a = os.path.join(wr68, "a.receipt.json")
    path68_b = os.path.join(wr68, "b.receipt.json")
    with open(path68_a, "w") as f:
        json.dump(valid_receipt68_a, f)
    with open(path68_b, "w") as f:
        json.dump(valid_receipt68_b, f)

    try:
        report.write_wrap_report([path68_a, path68_a], out_dir=wr68, no_pdf=True)
        dup_path_caught = False
    except ValueError:
        dup_path_caught = True
    check("duplicate receipt paths are rejected", dup_path_caught)

    try:
        report.write_wrap_report([path68_a, path68_b], out_dir=wr68, no_pdf=True)
        dup_id_caught = False
    except ValueError:
        dup_id_caught = True
    check("duplicate job_id across receipts is rejected", dup_id_caught)

    print("[69] wrap report guarantees fresh, never-overwritten output names")
    wr69 = os.path.join(base, "WRAP69")
    os.makedirs(wr69)
    valid_receipt69 = {
        "job_id": "JOB-69-FRESH",
        "label": "CARD_69",
        "source": "/Volumes/CARD_69",
        "destinations": ["/Volumes/DEST_1"],
        "verdict": "FULLY VERIFIED",
        "attestation": {"safe_to_wipe_source": True},
        "files_total": 1, "files_copied": 1, "bytes_copied": 1024,
        "files": [{"path": "A.mov", "size": 1024, "outcome": "verified", "hashes": {"xxh64": "3333333333333333"}}],
    }
    path69 = os.path.join(wr69, "card69.receipt.json")
    with open(path69, "w") as f:
        json.dump(valid_receipt69, f)

    res69_1 = report.write_wrap_report([path69], out_dir=wr69, no_pdf=True)
    res69_2 = report.write_wrap_report([path69], out_dir=wr69, no_pdf=True)
    check("sequential wrap reports produce distinct filenames",
          res69_1["html_path"] != res69_2["html_path"] and os.path.exists(res69_1["html_path"]) and os.path.exists(res69_2["html_path"]))

    print("[70] wrap report truth aggregation preserves mixed verdicts without recomputing")
    wr70 = os.path.join(base, "WRAP70")
    os.makedirs(wr70)
    # Card 1: fully verified & safe to wipe
    r70_1 = {
        "job_id": "JOB-70-1",
        "label": "CARD_70_SAFE",
        "source": "/Volumes/CARD_70_1",
        "destinations": ["/Volumes/DEST_1", "/Volumes/DEST_2"],
        "verdict": "FULLY VERIFIED",
        "attestation": {
            "safe_to_wipe_source": True,
            "distinct_physical_devices": 2,
            "independently_verified_destinations": 2,
            "source_reread_consistent": True,
            "destination_readback": True,
        },
        "files_total": 2, "files_copied": 2, "bytes_copied": 10000,
        "files": [
            {"path": "A001.mov", "size": 5000, "outcome": "verified", "hashes": {"xxh64": "aaaaaaaaaaaaaaaa"}},
            {"path": "A002.mov", "size": 5000, "outcome": "verified", "hashes": {"xxh64": "bbbbbbbbbbbbbbbb"}},
        ],
    }
    # Card 2: fast mode / unverified
    r70_2 = {
        "job_id": "JOB-70-2",
        "label": "CARD_70_FAST",
        "source": "/Volumes/CARD_70_2",
        "destinations": ["/Volumes/DEST_1"],
        "verdict": "DESTINATION NOT VERIFIED (fast mode)",
        "attestation": {
            "safe_to_wipe_source": False,
            "distinct_physical_devices": 1,
            "independently_verified_destinations": 1,
            "source_reread_consistent": None,
            "destination_readback": False,
        },
        "files_total": 1, "files_copied": 1, "bytes_copied": 2000,
        "files": [{"path": "B001.mov", "size": 2000, "outcome": "size-only", "hashes": {}}],
    }
    # Card 3: failed copy
    r70_3 = {
        "job_id": "JOB-70-3",
        "label": "CARD_70_FAILED",
        "source": "/Volumes/CARD_70_3",
        "destinations": ["/Volumes/DEST_1"],
        "verdict": "FAILED",
        "attestation": {
            "safe_to_wipe_source": False,
            "distinct_physical_devices": 1,
            "independently_verified_destinations": 0,
            "source_reread_consistent": False,
            "destination_readback": True,
        },
        "files_total": 1, "files_copied": 0, "bytes_copied": 0,
        "errors": ["Checksum mismatch on C001.mov"],
        "files": [{"path": "C001.mov", "size": 3000, "outcome": "failed", "hashes": {}}],
    }
    p70_1 = os.path.join(wr70, "r1.receipt.json")
    p70_2 = os.path.join(wr70, "r2.receipt.json")
    p70_3 = os.path.join(wr70, "r3.receipt.json")
    for p, r in [(p70_1, r70_1), (p70_2, r70_2), (p70_3, r70_3)]:
        with open(p, "w") as f:
            json.dump(r, f)

    res70 = report.write_wrap_report([p70_1, p70_2, p70_3], out_dir=wr70, no_pdf=True)
    check("mixed verdicts truthfully aggregated",
          res70["total_cards"] == 3 and res70["safe_cards"] == 1 and not res70["all_safe"]
          and res70["total_files"] == 3 and res70["total_bytes"] == 12000)
    with open(res70["html_path"]) as f:
        h70 = f.read()
    check("mixed verdict report highlights attention and card errors",
          "RECORDED RECEIPTS · SAFETY NOT RECOMPUTED" in h70
          and "Checksum mismatch on C001.mov" in h70
          and "CARD_70_SAFE" in h70 and "CARD_70_FAST" in h70 and "CARD_70_FAILED" in h70)

    print("[71] wrap report enforces size bounds and DOS limits")
    wr71 = os.path.join(base, "WRAP71")
    os.makedirs(wr71)
    oversized71 = os.path.join(wr71, "oversized.receipt.json")
    with open(oversized71, "wb") as f:
        f.write(b"{" + b" " * (17 * 1024 * 1024) + b"}")
    try:
        report.load_and_validate_receipt(oversized71)
        oversized_caught = False
    except ValueError:
        oversized_caught = True
    check("oversized receipt file (>16MB) is rejected", oversized_caught)

    print("[72] wrap report CLI integration and PDF fallback")
    p72_cli = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "wrap-report", p70_1, p70_2, "--out", wr70, "--json", "--no-pdf"],
        capture_output=True, text=True, cwd=HERE)
    term72 = json.loads(p72_cli.stdout.strip().splitlines()[-1])
    check("wrap-report CLI succeeds with JSON output",
          p72_cli.returncode == 0 and term72.get("event") == "wrap_report_complete"
          and term72.get("ok") is True and term72.get("pdf_generated") is False
          and term72.get("pdf_path") is None and os.path.exists(term72.get("html_path", "")))

    p72_err = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "wrap-report", bad_json66, "--json"],
        capture_output=True, text=True, cwd=HERE)
    term72_err = json.loads(p72_err.stdout.strip().splitlines()[-1])
    check("wrap-report CLI fails closed with JSON error for malformed receipt",
          p72_err.returncode == 1 and term72_err.get("event") == "wrap_report_complete"
          and term72_err.get("ok") is False and "invalid" in term72_err.get("error", "").lower())

    print("[73] unavailable PDF is a visible failure, never a claimed artifact")
    old_html_to_pdf73 = report.html_to_pdf_detail
    report.html_to_pdf_detail = lambda _html, _pdf: (False, "Chrome exited 1: renderer stub")
    try:
        pdf_failure73 = None
        try:
            report.write_wrap_report([p70_1], out_dir=wr70)
        except report.WrapReportPDFUnavailable as exc:
            pdf_failure73 = exc
    finally:
        report.html_to_pdf_detail = old_html_to_pdf73
    check("PDF renderer failure is visible and HTML remains available",
          pdf_failure73 is not None
          and os.path.exists(pdf_failure73.html_path)
          and "no PDF was claimed" in str(pdf_failure73)
          and "renderer stub" in pdf_failure73.reason
          and not os.path.exists(os.path.splitext(pdf_failure73.html_path)[0] + ".pdf"))

    print("[74] strict receipt bounds reject booleans, traversal, duplicate rows, and byte overflow")
    base74 = json.loads(json.dumps(r70_1))
    cases74 = []
    bool_size74 = json.loads(json.dumps(base74))
    bool_size74["files"][0]["size"] = True
    cases74.append((bool_size74, "boolean file size"))
    traversal74 = json.loads(json.dumps(base74))
    traversal74["files"][0]["path"] = "../escape.mov"
    cases74.append((traversal74, "relative path traversal"))
    duplicate_file74 = json.loads(json.dumps(base74))
    duplicate_file74["files"].append(dict(duplicate_file74["files"][0]))
    duplicate_file74["files_total"] = 2
    duplicate_file74["files_copied"] = 2
    cases74.append((duplicate_file74, "duplicate clip path"))
    overflow74 = json.loads(json.dumps(base74))
    overflow74["bytes_copied"] = 10**30
    cases74.append((overflow74, "byte bound"))
    strict_pass74 = True
    for candidate74, _label74 in cases74:
        try:
            report.validate_receipt_dict(candidate74)
            strict_pass74 = False
        except ValueError:
            pass
    check("malformed bounded fields are rejected", strict_pass74)

    print("[75] DTD/entity-bearing manifests and chains are refused before parse")
    src75, d75 = os.path.join(base, "CARD75"), os.path.join(base, "D75")
    os.makedirs(d75)
    make_card(src75, {"A.mov": 4096})
    res75 = engine.offload(src75, [d75], label="CARD75", source_reread=False)
    cr75 = os.path.join(d75, "CARD75")
    gen75 = mhl.write_ascmhl(cr75, res75.files)
    with open(gen75, "r", encoding="utf-8") as f:
        doc75 = f.read()
    # Keep the manifest well-formed and re-sign its chain row so only the
    # DTD gate can refuse it (a c4 mismatch would mask the finding).
    with open(gen75, "w", encoding="utf-8") as f:
        f.write(doc75.replace(
            "?>", "?>\n<!DOCTYPE hashlist [<!ENTITY a \"aaaaaaaa\">]>", 1))
    chain75 = os.path.join(cr75, mhl.ASCMHL_DIR, "ascmhl_chain.xml")
    ct75 = ET.parse(chain75)
    cns75 = {"c": mhl.ASCMHL_CHAIN_NS}
    for row in ct75.getroot().findall("c:hashlist", cns75):
        if row.findtext("c:path", namespaces=cns75) == os.path.basename(gen75):
            row.find("c:c4", cns75).text = hasher.c4_of_file(gen75)
    ct75.write(chain75, encoding="UTF-8", xml_declaration=True)
    problems75, history75 = mhl.load_validated_history(cr75)
    check("DTD-bearing generation manifest is refused with no trust",
          bool(problems75) and history75 == {}
          and any("DTD" in p or "entity" in p for p in problems75),
          str(problems75))
    rc75, _out75 = run_verify(cr75)
    check("verify exits nonzero on a DTD-bearing generation", rc75 != 0)
    with open(chain75, "r", encoding="utf-8") as f:
        cdoc75 = f.read()
    with open(chain75, "w", encoding="utf-8") as f:
        f.write(cdoc75.replace(
            "?>", "?>\n<!DOCTYPE hashlists [<!ENTITY b \"bbbbbbbb\">]>", 1))
    problems75c, history75c = mhl.load_validated_history(cr75)
    check("DTD-bearing chain file is refused with no trust",
          bool(problems75c) and history75c == {}, str(problems75c))

    print("[76] a sealed history with zero hash entries never verifies clean")
    src76, d76 = os.path.join(base, "CARD76"), os.path.join(base, "D76")
    os.makedirs(d76)
    make_card(src76, {"A.mov": 4096})
    res76 = engine.offload(src76, [d76], label="CARD76", source_reread=False)
    cr76 = os.path.join(d76, "CARD76")
    gen76 = mhl.write_ascmhl(cr76, res76.files)
    gt76 = ET.parse(gen76)
    ns76 = {"m": mhl.ASCMHL_NS}
    hashes76 = gt76.getroot().find("m:hashes", ns76)
    for h76 in list(hashes76):
        hashes76.remove(h76)
    gt76.write(gen76, encoding="UTF-8", xml_declaration=True)
    chain76 = os.path.join(cr76, mhl.ASCMHL_DIR, "ascmhl_chain.xml")
    ct76 = ET.parse(chain76)
    cns76 = {"c": mhl.ASCMHL_CHAIN_NS}
    for row in ct76.getroot().findall("c:hashlist", cns76):
        if row.findtext("c:path", namespaces=cns76) == os.path.basename(gen76):
            row.find("c:c4", cns76).text = hasher.c4_of_file(gen76)
    ct76.write(chain76, encoding="UTF-8", xml_declaration=True)
    os.remove(os.path.join(cr76, "A.mov"))
    rc76, out76 = run_verify(cr76)
    check("zero-entry history exits nonzero even with nothing contradicting it",
          rc76 != 0, out76[-300:])

    print("[77] wrap report never creates directories at bare receipt-controlled paths")
    home77 = os.path.join(base, "HOME77")
    attacker77 = os.path.join(base, "ATTACK77")
    legit77 = os.path.join(base, "LEGIT77")
    os.makedirs(attacker77)
    man77 = os.path.join(legit77, "CARD77", mhl.ASCMHL_DIR, "0001_CARD77.mhl")
    os.makedirs(os.path.dirname(man77))
    with open(man77, "w") as f:
        f.write("sealed")
    evil77 = json.loads(json.dumps(r70_1))
    evil77["destinations"] = [attacker77]
    evil77["manifests"] = []
    good77 = json.loads(json.dumps(r70_1))
    good77["job_id"] = "JOB-77-G"
    good77["destinations"] = [legit77]
    good77["manifests"] = [man77]
    p77_e = os.path.join(base, "evil77.receipt.json")
    p77_g = os.path.join(base, "good77.receipt.json")
    for p77, r77 in [(p77_e, evil77), (p77_g, good77)]:
        with open(p77, "w") as f:
            json.dump(r77, f)
    old_home77 = os.environ.get("DUMPTRUCK_HOME")
    os.environ["DUMPTRUCK_HOME"] = home77
    try:
        report.write_wrap_report([p77_e], no_pdf=True)
        report.write_wrap_report([p77_g], no_pdf=True)
    finally:
        if old_home77 is None:
            os.environ.pop("DUMPTRUCK_HOME", None)
        else:
            os.environ["DUMPTRUCK_HOME"] = old_home77
    wrap_local77 = os.path.join(home77, "reports", "wrap")
    check("receipt-controlled destination with no evidence is never created into",
          not os.path.exists(os.path.join(attacker77, "Reports")))
    check("unevidenced destinations fall back to the local reports home",
          os.path.isdir(wrap_local77)
          and any(n.startswith("wrap_report_") for n in os.listdir(wrap_local77)))
    check("a destination actually holding the receipt's manifest is auto-targeted",
          os.path.isdir(os.path.join(legit77, "Reports", "Wrap")))

    print("[78] corrupt BRAW thumbnail failure cannot affect verified-copy state")
    src78 = os.path.join(base, "CARD78")
    d78a, d78b = os.path.join(base, "D78A"), os.path.join(base, "D78B")
    os.makedirs(d78a), os.makedirs(d78b)
    make_card(src78, {"CLIPS/CORRUPT.braw": 4096})
    res78 = engine.offload(src78, [d78a, d78b], label="CARD78")
    att78_before = res78.attestation()
    media78 = media.analyze_card(
        os.path.join(d78a, "CARD78"), ["CLIPS/CORRUPT.braw"])
    att78_after = res78.attestation()
    doc78, _receipt78 = report.build_report(
        res78, att78_after,
        SimpleNamespace(format_name="BRAW test", reel_name=None), media78)
    check("corrupt BRAW still offloads and verifies normally",
          res78.ok and res78.fully_verified
          and att78_before == att78_after)
    check("corrupt BRAW report states thumbnail unavailable",
          "thumbnail unavailable" in doc78
          and not media78["CLIPS/CORRUPT.braw"]["thumbs"])

    print("[79] corrupt registered RAW probes degrade reports, never verdicts")
    src79 = os.path.join(base, "CARD79")
    d79a, d79b = os.path.join(base, "D79A"), os.path.join(base, "D79B")
    os.makedirs(d79a), os.makedirs(d79b)
    raw79 = ["CLIPS/CORRUPT.r3d", "CLIPS/CORRUPT.ari"]
    make_card(src79, {rel: 4096 for rel in raw79})
    res79 = engine.offload(src79, [d79a, d79b], label="CARD79")
    att79_before = res79.attestation()
    media79 = media.analyze_card(os.path.join(d79a, "CARD79"), raw79)
    att79_after = res79.attestation()
    doc79, _receipt79 = report.build_report(
        res79, att79_after,
        SimpleNamespace(format_name="registered RAW test", reel_name=None), media79)
    check("corrupt R3D and ARI still offload and verify normally",
          res79.ok and res79.fully_verified and att79_before == att79_after)
    check("corrupt R3D and ARI each retain an honest report placeholder",
          all(rel in media79 and media79[rel].get("thumbnail_unavailable")
              and not media79[rel]["thumbs"] for rel in raw79), str(media79)[:500])
    check("corrupt registered RAW report states both degradations",
          doc79.count("thumbnail unavailable") >= 2)
    report_verdicts79 = report.verdict_display_line
    check("reports use the app's one exact terminal verdict vocabulary",
          report_verdicts79(ok=True, fully_verified=True, safe_to_wipe=True)[0]
          == "SAFE TO WIPE"
          and report_verdicts79(ok=True, fully_verified=True,
                                safe_to_wipe=False)[0]
          == "VERIFIED · KEEP CARD"
          and report_verdicts79(ok=True, fully_verified=False,
                                safe_to_wipe=False)[0]
          == "UNVERIFIED — KEEP CARD"
          and report_verdicts79(ok=False, fully_verified=False,
                                safe_to_wipe=False)[0]
          == "FAILED — DO NOT WIPE")

    print("[80] registry and ARRI MXF fallback are explicit and fail honestly")
    check("RAW probe registry covers BRAW, R3D, ARI, ARX, and ARRI",
          set((".braw", ".r3d", ".ari", ".arx", ".arri"))
          <= set(media.PROBE_REGISTRY), str(sorted(media.PROBE_REGISTRY)))
    real_find_art80 = media._find_art_cmd
    try:
        media._find_art_cmd = lambda: None
        missing80, reason80 = media.probe_art(
            os.path.join(d79a, "CARD79", "CLIPS/CORRUPT.ari"))
    finally:
        media._find_art_cmd = real_find_art80
    check("missing ART requests the real vendor tool, never a substitute",
          missing80 is None and "install ARRI Reference Tool" in reason80,
          str(reason80))
    real_redline80 = media.REDLINE_PROBE
    try:
        media.REDLINE_PROBE = os.path.join(base, "missing-redline")
        missing_red80, reason_red80 = media.probe_redline(
            os.path.join(d79a, "CARD79", "CLIPS/CORRUPT.r3d"))
    finally:
        media.REDLINE_PROBE = real_redline80
    check("missing REDline requests REDCINE-X PRO, never a substitute",
          missing_red80 is None and "install REDCINE-X PRO" in reason_red80,
          str(reason_red80))

    fake_mxf80 = os.path.join(src79, "CLIPS/UNSUPPORTED.mxf")
    touch80 = open(fake_mxf80, "wb")
    try:
        touch80.write(os.urandom(512))
    finally:
        touch80.close()
    real_probe80, real_art80 = media.probe, media.probe_art
    called80 = []
    try:
        media.probe = lambda _path: {
            "duration_s": 1.0, "container": "mxf", "timecode": None,
            "video": {"codec": "?", "width": 0, "height": 0, "fps": 24.0},
            "audio": None,
        }
        def _art80(path, fallback_info=None, want_thumbnail=True):
            called80.append((path, fallback_info, want_thumbnail))
            return None, "injected unsupported ARRIRAW essence"
        media.probe_art = _art80
        mxf80 = media.analyze_card(src79, ["CLIPS/UNSUPPORTED.mxf"])
    finally:
        media.probe, media.probe_art = real_probe80, real_art80
    check("unsupported MXF video essence falls through from ffmpeg to ART",
          len(called80) == 1
          and "injected unsupported ARRIRAW essence" in
          mxf80["CLIPS/UNSUPPORTED.mxf"]["thumbnail_unavailable"])

    print("[81] R3D analysis orders native SDK, REDline, then placeholder")
    corrupt_r3d81 = os.path.join(
        d79a, "CARD79", "CLIPS/CORRUPT.r3d")
    real_sdk81, real_redline81 = media.probe_r3d_sdk, media.probe_redline
    calls81 = []
    try:
        def _sdk81(_path, want_thumbnail=True):
            calls81.append(("r3d-sdk", want_thumbnail))
            return None, "injected corrupt native decode"
        def _redline81(_path, want_thumbnail=True):
            calls81.append(("redline", want_thumbnail))
            return ({
                "probe": media._placeholder_probe(".r3d"),
                "thumbs": [],
            }, None)
        media.probe_r3d_sdk, media.probe_redline = _sdk81, _redline81
        tiered81, error81 = media.probe_r3d(corrupt_r3d81)
    finally:
        media.probe_r3d_sdk, media.probe_redline = real_sdk81, real_redline81
    check("corrupt R3D falls from native SDK to REDline in that order",
          calls81 == [("r3d-sdk", True), ("redline", True)]
          and error81 is None
          and tiered81["probe"].get("probe_backend") == "redline")
    check("successful REDline fallback records the native failure reason",
          tiered81["probe"].get("probe_fallbacks") == [{
              "backend": "r3d-sdk",
              "reason": "injected corrupt native decode",
          }], str(tiered81))

    native_note81 = {
        "probe": {
            **media._placeholder_probe(".r3d"),
            "probe_backend": "r3d-sdk",
        },
        "thumbs": [],
    }
    native_doc81, _native_receipt81 = report.build_report(
        res79, att79_after,
        SimpleNamespace(format_name="native R3D test", reel_name=None),
        {"CLIPS/CORRUPT.r3d": native_note81})
    fallback_doc81, _fallback_receipt81 = report.build_report(
        res79, att79_after,
        SimpleNamespace(format_name="fallback R3D test", reel_name=None),
        {"CLIPS/CORRUPT.r3d": tiered81})
    check("report discloses native R3D use and any REDline fallback",
          "R3D probe: native SDK (REDline not used)" in native_doc81
          and "R3D probe: REDline fallback" in fallback_doc81
          and "injected corrupt native decode" in fallback_doc81)

    real_r3d_path81, real_redline81 = media.R3D_PROBE, media.probe_redline
    called_redline81 = []
    try:
        media.R3D_PROBE = os.path.join(base, "missing-r3d-probe")
        def _present_redline81(_path, want_thumbnail=True):
            called_redline81.append(want_thumbnail)
            return ({
                "probe": media._placeholder_probe(".r3d"),
                "thumbs": [],
            }, None)
        media.probe_redline = _present_redline81
        missing_native81, missing_native_error81 = media.probe_r3d(
            corrupt_r3d81)
    finally:
        media.R3D_PROBE, media.probe_redline = (
            real_r3d_path81, real_redline81)
    check("missing native helper falls through to REDline",
          called_redline81 == [True] and missing_native_error81 is None
          and missing_native81["probe"].get("probe_backend") == "redline")
    check("missing native helper reason remains attached to REDline output",
          "not built or executable" in
          missing_native81["probe"]["probe_fallbacks"][0]["reason"])

    real_r3d_path81, real_redline_path81 = (
        media.R3D_PROBE, media.REDLINE_PROBE)
    try:
        media.R3D_PROBE = os.path.join(base, "missing-r3d-probe")
        media.REDLINE_PROBE = os.path.join(base, "missing-redline")
        missing_both81 = media.analyze_card(
            os.path.join(d79a, "CARD79"), ["CLIPS/CORRUPT.r3d"])
    finally:
        media.R3D_PROBE, media.REDLINE_PROBE = (
            real_r3d_path81, real_redline_path81)
    missing_both_reason81 = missing_both81[
        "CLIPS/CORRUPT.r3d"]["thumbnail_unavailable"]
    check("missing native helper and REDline end in the honest placeholder",
          not missing_both81["CLIPS/CORRUPT.r3d"]["thumbs"]
          and "r3d-sdk: native R3D helper is not built or executable" in
          missing_both_reason81
          and "redline: install REDCINE-X PRO" in missing_both_reason81,
          missing_both_reason81)

    print("[82] --loose-files: no card identity, no label memory, never wipe-authorized")
    src82 = os.path.join(base, "LOOSE82-STAGE")
    d82a, d82b = os.path.join(base, "D82A"), os.path.join(base, "D82B")
    home82 = os.path.join(base, "HOME82")
    os.makedirs(d82a), os.makedirs(d82b), os.makedirs(home82)
    make_card(src82, {"clip one.mov": 96 * 1024, "notes.txt": 512})
    # Another dataset owns the label OWNED82. Neither a card offload nor a
    # loose-files offload may file into its folder; LOOSE82 is free.
    with open(os.path.join(home82, "datasets.json"), "w") as f:
        json.dump({"datasets": [{"id": "owner-82", "label": "OWNED82",
                                 "format_name": "Generic data", "last_seen": 0,
                                 "anchors": [["never/present.mov", 1, 1]],
                                 "destinations": [], "mounts": 1}]}, f)
    env82 = dict(os.environ, DUMPTRUCK_HOME=home82)
    p82 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src82, d82a, d82b,
         "--label", "LOOSE82", "--json", "--no-report", "--loose-files"],
        capture_output=True, text=True, cwd=HERE, env=env82)
    events82 = [json.loads(line) for line in p82.stdout.splitlines() if line.strip()]
    kinds82 = [e.get("event") for e in events82]
    recognized82 = next((e for e in events82 if e.get("event") == "card_recognized"), {})
    att82 = next((e for e in events82 if e.get("event") == "attestation"), {})
    done82 = events82[-1] if events82 else {}
    check("loose offload completes verified without a label-collision refusal",
          p82.returncode == 0 and "refused_label_collision" not in kinds82
          and done82.get("event") == "offload_complete"
          and done82.get("fully_verified") is True,
          (p82.stdout + p82.stderr)[-600:])
    check("loose source is recognized as 'Loose files', never a known card",
          recognized82.get("format") == "Loose files"
          and recognized82.get("known") is False and recognized82.get("mounts") == 0,
          str(recognized82))
    check("loose offload is never wipe-authorized and says why",
          att82.get("safe_to_wipe_source") is False
          and any(b.startswith("loose files:") for b in att82.get("safe_to_wipe_blockers", []))
          and done82.get("safe_to_wipe_source") is False,
          str(att82.get("safe_to_wipe_blockers")))
    with open(os.path.join(home82, "datasets.json")) as f:
        registry82 = json.load(f)["datasets"]
    check("loose offload leaves the card registry untouched",
          [r["id"] for r in registry82] == ["owner-82"], str(registry82))
    for root in (d82a, d82b):
        check(f"loose files landed flat under the label at {os.path.basename(root)}",
              os.path.isfile(os.path.join(root, "LOOSE82", "clip one.mov"))
              and os.path.isfile(os.path.join(root, "LOOSE82", "notes.txt")))
    # The owner's footage is at D82A, so the name is taken there in both modes.
    os.makedirs(os.path.join(d82a, "OWNED82"))
    with open(os.path.join(d82a, "OWNED82", "old.mov"), "wb") as f:
        f.write(b"x" * 1024)
    for flag_desc, extra in (("with --loose-files", ["--loose-files"]), ("without the flag", [])):
        p82c = subprocess.run(
            [sys.executable, "-m", "dumptruck.cli", "offload", src82, d82a,
             "--label", "OWNED82", "--json", "--no-report"] + extra,
            capture_output=True, text=True, cwd=HERE, env=env82)
        kinds82c = [json.loads(line).get("event") for line in p82c.stdout.splitlines() if line.strip()]
        check(f"a label another card owns is refused {flag_desc}",
              p82c.returncode != 0 and "refused_label_collision" in kinds82c
              and os.listdir(os.path.join(d82a, "OWNED82")) == ["old.mov"], str(kinds82c))
    # At D82B the owner has no footage. Loose files still may not take a
    # real card's name (the card, re-inserted, would land on top of them),
    # but a card may: the name passes to it and both records keep the name
    # (Joshua 2026-09-21: a blank card folder must not block a real card).
    p82d = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src82, d82b,
         "--label", "OWNED82", "--json", "--no-report", "--loose-files"],
        capture_output=True, text=True, cwd=HERE, env=env82)
    kinds82d = [json.loads(line).get("event") for line in p82d.stdout.splitlines() if line.strip()]
    check("loose files never take a remembered card name, even with nothing at the destination",
          p82d.returncode != 0 and "refused_label_collision" in kinds82d
          and not os.path.exists(os.path.join(d82b, "OWNED82")), str(kinds82d))
    p82e = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src82, d82b,
         "--label", "OWNED82", "--json", "--no-report"],
        capture_output=True, text=True, cwd=HERE, env=env82)
    events82e = [json.loads(line) for line in p82e.stdout.splitlines() if line.strip()]
    kinds82e = [e.get("event") for e in events82e]
    warnings82e = [e.get("message", "") for e in events82e if e.get("event") == "source_warning"]
    check("a card takes a remembered name whose owner has no footage here",
          p82e.returncode == 0 and "refused_label_collision" not in kinds82e
          and os.path.isfile(os.path.join(d82b, "OWNED82", "clip one.mov")),
          (p82e.stdout + p82e.stderr)[-600:])
    check("the pass-through is silent (every project reuses A001/B001)",
          not any("card name" in w for w in warnings82e), str(warnings82e))
    with open(os.path.join(home82, "datasets.json")) as f:
        registry82e = {r["id"]: r for r in json.load(f)["datasets"]}
    check("both cards keep the name; the folder each wrote is what it owns",
          registry82e["owner-82"]["label"] == "OWNED82"
          and any(r["label"] == "OWNED82" and os.path.join(d82b, "OWNED82") in r["destinations"]
                  for r in registry82e.values() if r["id"] != "owner-82"),
          str(registry82e))
    # ...and that new owner is still refused at D82A, where owner-82's
    # footage sits (Codex review 2026-09-21, P1).
    with open(os.path.join(home82, "datasets.json")) as f:
        db82 = json.load(f)
    for r in db82["datasets"]:
        if r["id"] == "owner-82":
            r["destinations"] = [os.path.join(d82a, "OWNED82")]
    with open(os.path.join(home82, "datasets.json"), "w") as f:
        json.dump(db82, f)
    p82f = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src82, d82a,
         "--label", "OWNED82", "--json", "--no-report"],
        capture_output=True, text=True, cwd=HERE, env=env82)
    kinds82f = [json.loads(line).get("event") for line in p82f.stdout.splitlines() if line.strip()]
    check("a card that shares a name is refused at the folder the other card wrote",
          p82f.returncode != 0 and "refused_label_collision" in kinds82f
          and os.listdir(os.path.join(d82a, "OWNED82")) == ["old.mov"], str(kinds82f))

    print("[83] root-locked macOS system folders with a -bad-N suffix are pruned, not fatal")
    src83 = os.path.join(base, "DRIVE83")
    make_card(src83, {"CLIP.mov": 4096})
    locked83 = [os.path.join(src83, ".DocumentRevisions-V100-bad-1"),
                os.path.join(src83, ".Spotlight-V100-bad-2")]
    for d in locked83:
        os.makedirs(d)
        os.chmod(d, 0o111)  # search-only, like macOS leaves them: listing is EACCES
    try:
        entries83, _dirs83, warn83 = engine.scan_source(src83)
        check("scan prunes the locked stores and keeps the footage",
              [e.rel_path for e in entries83] == ["CLIP.mov"] and not warn83,
              str([e.rel_path for e in entries83]) + str(warn83))
        p83 = subprocess.run(
            [sys.executable, "-m", "dumptruck.cli", "inspect", src83],
            capture_output=True, text=True, cwd=HERE,
            env=dict(os.environ, DUMPTRUCK_HOME=os.path.join(base, "HOME83")))
        info83 = json.loads(p83.stdout or "{}")
        check("inspect succeeds on a drive that carries a locked -bad-1 store",
              p83.returncode == 0 and info83.get("files") == 1 and not info83.get("error"),
              (p83.stdout + p83.stderr)[-400:])
    finally:
        for d in locked83:
            os.chmod(d, 0o755)

    print("[84] wrap report keeps long lane paths and every card column on the printed page")
    src84 = os.path.join(base, "CARD84")
    d84 = os.path.join(base, "D84", "A_VERY_LONG_PROJECT_NAME_FOR_THE_WRAP_REPORT", "Raws", "SHOOT_DAY_ONE")
    os.makedirs(d84)
    make_card(src84, {"CLIP.mov": 4096})
    p84 = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", "offload", src84, d84,
         "--label", "R2_WRAP_CARD_WITH_A_LONG_LABEL", "--json", "--no-thumbs"],
        capture_output=True, text=True, cwd=HERE,
        env=dict(os.environ, DUMPTRUCK_HOME=os.path.join(base, "HOME84")))
    receipts84 = [p for p in
                  (json.loads(l).get("paths", []) for l in p84.stdout.splitlines()
                   if l.strip() and json.loads(l).get("event") == "report_written")
                  for p in p for p in ([p] if p.endswith(".receipt.json") else [])]
    receipts84 = [p for p in receipts84 if p.endswith(".receipt.json")]
    if not receipts84:
        receipts84 = [os.path.join(dp, f) for dp, _, fs in os.walk(os.path.join(base, "D84"))
                      for f in fs if f.endswith(".receipt.json")]
    check("offload for the wrap test produced a receipt", bool(receipts84), (p84.stdout + p84.stderr)[-400:])
    out84 = os.path.join(base, "WRAP84")
    wrap_args84 = [sys.executable, "-m", "dumptruck.cli", "wrap-report",
                   *receipts84, "--out", out84, "--json"]
    if os.environ.get("DUMPTRUCK_TEST_NO_PDF") == "1":
        wrap_args84.append("--no-pdf")
    w84 = subprocess.run(
        wrap_args84,
        capture_output=True, text=True, cwd=HERE)
    html84 = [os.path.join(out84, f) for f in os.listdir(out84)] if os.path.isdir(out84) else []
    html_file84 = next((f for f in html84 if f.endswith(".html")), None)
    pdf_file84 = next((f for f in html84 if f.endswith(".pdf")), None)
    check("wrap report wrote HTML", w84.returncode == 0 and html_file84 is not None, (w84.stdout + w84.stderr)[-400:])
    if html_file84:
        css84 = open(html_file84).read()
        check("wrap CSS wraps long paths and prints landscape",
              "table-layout:fixed" in css84 and "overflow-wrap:anywhere" in css84
              and "size:A4 landscape" in css84)
    pdftotext = shutil.which("pdftotext")
    if pdf_file84 and pdftotext:
        # Reading order (no -layout): a wrapped cell comes out as one run of
        # text, so the whole path must be contiguous once whitespace goes.
        text84 = subprocess.run([pdftotext, pdf_file84, "-"],
                                capture_output=True, text=True).stdout
        flat84 = "".join(text84.split())
        check("PDF text keeps the whole destination path, not a clipped prefix",
              "A_VERY_LONG_PROJECT_NAME_FOR_THE_WRAP_REPORT/Raws/SHOOT_DAY_ONE" in flat84, flat84[:800])
        check("PDF text keeps the label, verdict, wipe and runtime columns",
              "R2_WRAP_CARD_WITH_A_LONG_LABEL" in flat84 and "safe_to_wipe_source=false" in flat84
              and "KEEPCARD" in flat84 and "RUNTIME" in flat84.upper(), flat84[:800])
    else:
        print("  NOTE  wrap PDF text check skipped (chrome or pdftotext unavailable)")

    scenario_mixed_trust_blocks_wipe(base)
    scenario_verify_normalizes_unicode_names(base)
    scenario_report_limits_and_pdf_failure(base)
    scenario_arri_sdk_helper_preferred(base)
    scenario_source_reread_after_drain(base)
    scenario_verify_heartbeat(base)
    scenario_source_watcher_junk_matches_engine()

    print("[87] a failed completion callback cannot strand a per-file reader")
    src86, dst86 = os.path.join(base, "CARD86"), os.path.join(base, "D86")
    os.makedirs(dst86)
    make_card(src86, {"A.mov": 4096, "B.mov": 4096})
    code86 = """
import sys
from dumptruck import engine
def die(self, task):
    raise RuntimeError('injected worker death')
engine._VerifyCommitWorker._maybe_done = die
try:
    engine.offload(sys.argv[1], [sys.argv[2]], label='CARD86', source_reread=False)
except RuntimeError as exc:
    assert 'verify task completion failed' in str(exc), str(exc)
else:
    raise AssertionError('completion failure was accepted')
"""
    try:
        p86 = subprocess.run([sys.executable, "-c", code86, src86, dst86],
                             capture_output=True, text=True, cwd=HERE, timeout=5,
                             env=dict(os.environ, DUMPTRUCK_VERIFY_PER_FILE="1"))
        check("failed completion callback exits without a stranded wait",
              p86.returncode == 0, (p86.stdout + p86.stderr)[-500:])
    except subprocess.TimeoutExpired:
        check("failed completion callback exits without a stranded wait", False, "timed out")

    code86_dead = """
import sys
from dumptruck import engine
engine._VerifyCommitWorker.run = lambda self: None
try:
    engine.offload(sys.argv[1], [sys.argv[2]], label='CARD86', source_reread=False)
except RuntimeError as exc:
    assert 'verify worker stopped' in str(exc), str(exc)
else:
    raise AssertionError('dead worker was accepted')
"""
    dead_dst86 = os.path.join(base, "D86dead")
    os.makedirs(dead_dst86)
    try:
        p86dead = subprocess.run([sys.executable, "-c", code86_dead, src86, dead_dst86],
                                 capture_output=True, text=True, cwd=HERE, timeout=5,
                                 env=dict(os.environ, DUMPTRUCK_VERIFY_PER_FILE="1"))
        check("dead worker fails the job without hanging",
              p86dead.returncode == 0, (p86dead.stdout + p86dead.stderr)[-500:])
    except subprocess.TimeoutExpired:
        check("dead worker fails the job without hanging", False, "timed out")

    print("[88] pinned topology selects a schedule only for one known SSD")
    roots87 = ["one", "two"]
    stores87 = {"one": frozenset({"ssd"}), "two": frozenset({"ssd"})}
    real_classify87 = engine._device_is_solid_state
    saved_override87 = os.environ.pop("DUMPTRUCK_VERIFY_PER_FILE", None)
    try:
        engine._device_is_solid_state = lambda _store: True
        check("one SSD, including two roots on it, selects per-file",
              engine._verify_schedule(roots87, stores87) == "per_file")
        check("distinct stores retain overlap",
              engine._verify_schedule(roots87, dict(stores87, two=frozenset({"other"})))
              == "overlap")
        check("unknown topology retains overlap",
              engine._verify_schedule(roots87, dict(stores87, two=engine.macio.UNKNOWN_DEVICE))
              == "overlap")
        engine._device_is_solid_state = lambda _store: False
        check("rotational media retain governor scheduling",
              engine._verify_schedule(roots87, stores87) == "overlap")
        engine._device_is_solid_state = lambda _store: None
        check("unknown media retain overlap",
              engine._verify_schedule(roots87, stores87) == "overlap")
        os.environ["DUMPTRUCK_VERIFY_PER_FILE"] = "1"
        check("benchmark override forces per-file",
              engine._verify_schedule(roots87, {}) == "per_file")
        os.environ["DUMPTRUCK_VERIFY_PER_FILE"] = "0"
        check("benchmark override forces overlap",
              engine._verify_schedule(roots87, stores87) == "overlap")
    finally:
        engine._device_is_solid_state = real_classify87
        if saved_override87 is None:
            os.environ.pop("DUMPTRUCK_VERIFY_PER_FILE", None)
        else:
            os.environ["DUMPTRUCK_VERIFY_PER_FILE"] = saved_override87

    print("[89] per-file boundary survives write, verify, and event failures")
    real_stores88 = engine.macio.physical_stores
    real_classify88 = engine._device_is_solid_state
    real_write88 = engine._DestWriter._write_all
    real_hash88 = engine._cold_hash
    try:
        engine.macio.physical_stores = lambda _path: frozenset({"disk88"})
        engine._device_is_solid_state = lambda _store: True
        for fault in ("none", "write", "verify", "event"):
            src88 = os.path.join(base, "CARD88" + fault)
            dst88 = os.path.join(base, "D88" + fault)
            os.makedirs(dst88)
            dst88other = os.path.join(base, "D88" + fault + "OTHER")
            if fault == "write":
                os.makedirs(dst88other)
            make_card(src88, {"A.mov": 4096, "B.mov": 4096})
            events88 = []
            def _sink88(evt):
                events88.append((evt["event"], evt.get("path")))
                if fault == "event" and evt["event"] == "file_done" and evt.get("path") == "A.mov":
                    raise RuntimeError("injected file_done sink failure")
            def _write88(self, fd, chunk):
                if (fault == "write" and self.entry.rel_path == "A.mov"
                        and self.dest_file.startswith(dst88 + os.sep)):
                    raise OSError(28, "injected write failure")
                return real_write88(self, fd, chunk)
            def _hash88(path, *args, **kwargs):
                if fault == "verify" and ".dumptruck-partial-" in os.fsdecode(path) \
                        and os.fsdecode(path).startswith("A.mov"):
                    return "bad digest"
                return real_hash88(path, *args, **kwargs)
            engine._DestWriter._write_all = _write88
            engine._cold_hash = _hash88
            dests88 = [dst88, dst88other] if fault == "write" else [dst88]
            result88 = engine.offload(src88, dests88, label="CARD88",
                                      source_reread=False, event=_sink88)
            cr88 = os.path.join(dst88, "CARD88")
            i_done88 = events88.index(("file_done", "A.mov"))
            i_next88 = events88.index(("file_started", "B.mov"))
            check(f"{fault} path waits for A before starting B",
                  result88.verify_schedule == "per_file" and i_done88 < i_next88,
                  str(events88))
            check(f"{fault} path records honest result and commits B",
                  result88.ok == (fault == "none")
                  and os.path.isfile(os.path.join(cr88, "B.mov"))
                  and (fault == "none" or not os.path.exists(os.path.join(cr88, "A.mov"))
                       or fault == "event")
                  and (fault != "write" or os.path.isfile(
                      os.path.join(dst88other, "CARD88", "A.mov"))), str(result88.errors))
            check(f"{fault} schedule appears in attestation",
                  result88.attestation()["verify_schedule"] == "per_file")
            _, receipt88 = report.build_report(
                result88, result88.attestation(), SimpleNamespace(format_name="Generic"), {})
            report.validate_receipt_dict(receipt88)
            wrap88, _ = report.build_wrap_report([receipt88])
            check(f"{fault} receipt and wrap accept the added schedule field",
                  receipt88["attestation"]["verify_schedule"] == "per_file" and bool(wrap88))
    finally:
        engine.macio.physical_stores = real_stores88
        engine._device_is_solid_state = real_classify88
        engine._DestWriter._write_all = real_write88
        engine._cold_hash = real_hash88

    scenario_final_verify_lifecycle(base)
    scenario_final_verify_topology()

    print(f"\n{'='*50}\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("FAILED:", *FAIL, sep="\n  - ")
    shutil.rmtree(base, ignore_errors=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
