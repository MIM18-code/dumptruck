"""Offload report: dense internal-records HTML + PDF.

Structure modeled on Pomfort Offload Manager's Offloads Report (the research
pick): summary box, formats box, offload/verification box, then the clip table
with thumbnails. Provenance block makes the report usable as evidence.
Reports live in <dest>/Reports/<label>/ — NEVER inside the sealed card folder.
PDF renders via headless Chrome when present; HTML is the canonical artifact.
"""

import datetime
import getpass
import html
import json
import math
import os
import platform
import socket
import stat
import subprocess
import uuid as uuid_mod

from . import TOOL_NAME, __version__

CHROME_PATHS = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
)

# A 60,001-file card writes a 21 MB receipt (desktop QA round 5, R5-03);
# the caps are denial-of-service bounds, not workload limits, and must sit
# well above any card a camera can fill. JobEvidence.swift carries the
# same numbers for the app-side parser.
MAX_RECEIPT_BYTES = 128 * 1024 * 1024  # 128 MiB per receipt
MAX_RECEIPTS_PER_WRAP = 256
MAX_FILES_PER_RECEIPT = 400_000
MAX_TOTAL_FILES_PER_WRAP = 1_000_000
MAX_STRING_BYTES = 8 * 1024
MAX_DESTINATIONS_PER_RECEIPT = 64
MAX_ERRORS_PER_RECEIPT = 10_000
MAX_MANIFESTS_PER_RECEIPT = 256
MAX_HASHES_PER_FILE = 8
MAX_STATUS_ENTRIES_PER_FILE = 64
MAX_RUNTIME_SECONDS = 366 * 24 * 60 * 60
MAX_INTEGER = (1 << 63) - 1

_FILE_OUTCOMES = {"verified", "skipped", "size-only", "failed", "conflict"}
_DESTINATION_STATUSES = {
    "verified", "skipped", "trusted", "size-only", "failed", "conflict",
}
_HASH_LENGTHS = {
    "xxh64": 16, "xxh3": 16, "xxh128": 32,
    "md5": 32, "sha1": 40, "sha256": 64, "sha512": 128,
}
_HASH_ALGORITHMS = set(_HASH_LENGTHS) | {"c4"}
_ATTESTATION_BOOL_FIELDS = {
    "destination_readback", "write_fd_nocache", "verify_fd_nocache",
    "full_flush_before_close", "source_grew_after_scan", "safe_to_wipe_source",
    "camera_history_failed",
}
_ATTESTATION_INT_FIELDS = {
    "source_read_count", "independently_verified_destinations",
    "distinct_physical_devices", "files_trusted_from_prior_generations",
    "uncopied_source_objects",
}


class WrapReportPDFUnavailable(OSError):
    """HTML exists, but the operator-requested PDF could not be rendered."""

    def __init__(self, html_path, reason="headless PDF renderer unavailable"):
        self.html_path = html_path
        self.reason = reason
        super().__init__(f"{reason}; HTML was written but no PDF was claimed (HTML: {html_path})")


def _esc(s):
    return html.escape(str(s if s is not None else ""))


def _string_bytes(value):
    """Return UTF-8 byte length without accepting non-string values."""
    return len(value.encode("utf-8")) if isinstance(value, str) else None


def _validate_text(value, field, *, maximum=MAX_STRING_BYTES, allow_empty=False):
    if not isinstance(value, str):
        raise ValueError(f"Malformed receipt: '{field}' must be a string")
    size = _string_bytes(value)
    if size is None or size > maximum or (not allow_empty and not value):
        raise ValueError(f"Malformed receipt: '{field}' exceeds its size bound or is empty")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        raise ValueError(f"Malformed receipt: '{field}' contains a control character")
    return value


def _bounded_integer(value, field, *, maximum=MAX_INTEGER, default=None):
    if value is None:
        if default is not None:
            return default
        raise ValueError(f"Malformed receipt: '{field}' is missing")
    # bool is an int subclass, but a JSON boolean is never a byte/file count.
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > maximum:
        raise ValueError(f"Malformed receipt: '{field}' must be a bounded non-negative integer")
    return value


def _optional_runtime(value, field):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"Malformed receipt: '{field}' must be a finite runtime number")
    if not math.isfinite(value) or value < 0 or value > MAX_RUNTIME_SECONDS:
        raise ValueError(f"Malformed receipt: '{field}' is outside its runtime bound")
    return float(value)


def _format_runtime(seconds):
    if seconds is None:
        return "Not recorded"
    return _dur(seconds) or "00:00:00"


def _copies_devices_text(att, labeled=False):
    """Render the verified-copy pair consistently in receipts and wraps."""
    verified = att.get("independently_verified_destinations")
    if verified == 0 and att.get("files_trusted_from_prior_generations"):
        return "none fully read this run, prior generations trusted"
    copies = _attestation_text(att, "independently_verified_destinations")
    devices = _attestation_text(att, "distinct_physical_devices")
    return (f"verified destinations={copies} / physical devices={devices}"
            if labeled else f"{copies} / {devices}")


def _attestation_text(attestation, field):
    """Render an attestation value without supplying an optimistic default."""
    if field not in attestation:
        return "Not recorded"
    value = attestation[field]
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "Not recorded"
    return str(value)


def _human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n} B" if unit == "B" else f"{n:.2f} {unit}"
        n /= 1024


def _dur(seconds):
    if not seconds:
        return ""
    s = int(round(seconds))
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


_CSS = """
body{font-family:-apple-system,'Helvetica Neue',sans-serif;font-size:12px;color:#1a1a1a;
     background:#fff;margin:24px;max-width:1080px}
h1{font-size:19px;margin:0 0 2px}h2{font-size:13px;margin:22px 0 6px;text-transform:uppercase;
   letter-spacing:.06em;color:#555;border-bottom:1px solid #ddd;padding-bottom:3px}
.sub{color:#666;margin-bottom:14px}
table{border-collapse:collapse;width:100%}
th{text-align:left;font-size:10px;text-transform:uppercase;letter-spacing:.05em;color:#777;
   padding:4px 8px;border-bottom:1px solid #ccc}
td{padding:4px 8px;border-bottom:1px solid #eee;vertical-align:top}
.mono{font-family:'SF Mono',Menlo,monospace;font-size:11px}
.kv td:first-child{color:#666;width:220px}
.ok{color:#0a7a2f;font-weight:600}.bad{color:#b3261e;font-weight:700}.warn{color:#9a6700;font-weight:600}
.thumbs img{height:64px;margin-right:4px;border:1px solid #ddd;border-radius:2px}
.badge{display:inline-block;padding:2px 8px;border-radius:3px;font-weight:700;font-size:11px}
.badge.ok{background:#e6f4ea;color:#0a7a2f}.badge.bad{background:#fdecea;color:#b3261e}
.badge.warn{background:#fff4d6;color:#9a6700}
.footer{margin-top:26px;color:#999;font-size:10px}
@media print{body{margin:8mm}.thumbs img{height:52px}}
"""

_WRAP_CSS = """
body{font-family:-apple-system,'Helvetica Neue',sans-serif;font-size:12px;color:#1a1a1a;
     background:#fff;margin:28px;max-width:1120px;line-height:1.4}
h1{font-size:22px;margin:0 0 4px;font-weight:700}
h2{font-size:13px;margin:24px 0 8px;text-transform:uppercase;
   letter-spacing:.06em;color:#444;border-bottom:1px solid #ccc;padding-bottom:4px}
.sub{color:#666;margin-bottom:18px;font-size:12px}
table{border-collapse:collapse;width:100%;margin-bottom:16px}
th{text-align:left;font-size:10px;text-transform:uppercase;letter-spacing:.05em;color:#666;
   padding:6px 8px;border-bottom:2px solid #bbb;background:#f8f9fa}
td{padding:6px 8px;border-bottom:1px solid #eee;vertical-align:top}
tr:nth-child(even) td{background:#fafbfc}
.mono{font-family:'SF Mono',Menlo,monospace;font-size:11px}
.kv td:first-child{color:#555;width:240px;font-weight:500}
.ok{color:#0a7a2f;font-weight:600}.bad{color:#b3261e;font-weight:700}.warn{color:#9a6700;font-weight:600}
.badge{display:inline-block;padding:3px 9px;border-radius:4px;font-weight:700;font-size:11px}
.badge.ok{background:#e6f4ea;color:#0a7a2f}.badge.bad{background:#fdecea;color:#b3261e}
.badge.warn{background:#fff4d6;color:#9a6700}
.summary-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:20px}
.summary-card{background:#f8f9fa;border:1px solid #e2e4e7;border-radius:6px;padding:12px}
.summary-card .val{font-size:20px;font-weight:700;margin-top:4px;font-family:'SF Mono',Menlo,monospace}
.summary-card .lbl{font-size:10px;text-transform:uppercase;letter-spacing:.05em;color:#666}
ul.err-list{margin:0;padding-left:20px}
ul.err-list li{margin-bottom:4px}
.footer{margin-top:32px;color:#888;font-size:10px;border-top:1px solid #e0e0e0;padding-top:10px}
/* Long lane paths must wrap inside their cell, never push the table off the
   page: a 9-column card table printed to PDF lost its verdict and wipe
   columns and cut destinations at "DUMPTRUCK_TES" (Codex desktop QA round 2,
   2026-09-15, R2-04). Fixed layout + anywhere-wrap keeps every column on
   the page; landscape gives the card table room. */
table{table-layout:fixed}
td,th{overflow-wrap:anywhere;word-break:break-word}
.mono{overflow-wrap:anywhere;word-break:break-all}
@page{size:A4 landscape;margin:10mm}
@media print{body{margin:0;max-width:none}.summary-grid{gap:8px}.summary-card{padding:8px}
             table{font-size:10px}.mono{font-size:9.5px}}
"""


def verdict_display_line(*, ok, fully_verified, safe_to_wipe):
    """The report's single terminal verdict vocabulary.

    This mirrors Job.Verdict.displayLine in the Swift app. Verification and
    attestation facts remain separately disclosed below the headline; they may
    not form a second, competing verdict badge.
    """
    if not ok:
        return "FAILED — DO NOT WIPE", "bad"
    if not fully_verified:
        return "UNVERIFIED — KEEP CARD", "bad"
    if safe_to_wipe:
        return "SAFE TO WIPE", "ok"
    return "VERIFIED · KEEP CARD", "warn"


def build_report(result, att, card_info, media_info, dataset=None):
    """Returns (html_string, receipt_dict)."""
    now = datetime.datetime.now().astimezone()
    job_id = str(uuid_mod.uuid4())
    files = result.files
    copied = [f for f in files if f.outcome() in ("verified", "size-only")]
    skipped = [f for f in files if f.outcome() == "skipped"]
    total_bytes = sum(f.size for f in files)
    copied_bytes = sum(f.size for f in copied)

    n_video = sum(1 for rel, m in media_info.items() if m["probe"].get("video"))
    n_audio = sum(1 for rel, m in media_info.items()
                  if m["probe"].get("audio") and not m["probe"].get("video"))
    total_dur = sum(m["probe"].get("duration_s") or 0 for m in media_info.values())

    formats = {}
    for m in media_info.values():
        v, p = m["probe"].get("video"), m["probe"]
        if v:
            key = (v["codec"], f'{v["width"]}x{v["height"]}', v["fps"])
        elif p.get("audio"):
            a = p["audio"]
            key = (a["codec"], f'{a["channels"]}ch {a["sample_rate"]}Hz {a["bits"]}bit', "")
        else:
            continue
        formats[key] = formats.get(key, 0) + 1

    verdict, vclass = verdict_display_line(
        ok=result.ok,
        fully_verified=result.fully_verified,
        safe_to_wipe=att["safe_to_wipe_source"])

    rows = []
    for f in sorted(files, key=lambda f: f.rel_path):
        m = media_info.get(f.rel_path, {})
        p = m.get("probe", {})
        v, a = p.get("video"), p.get("audio")
        tech = ""
        if v:
            tech = f'{v["codec"]} {v["width"]}x{v["height"]} @ {v["fps"]:g}fps'
            if a:
                tech += f' + {a["channels"]}ch audio'
        elif a:
            tech = f'{a["codec"]} {a["channels"]}ch {a["sample_rate"]}Hz {a["bits"]}bit'
        outcome = f.outcome()
        if outcome == "skipped":
            st = '<span class="warn">skipped (already offloaded)</span>'
        elif outcome in ("failed", "conflict"):
            st = '<span class="bad">FAILED / CONFLICT</span>'
        elif outcome == "size-only":
            st = '<span class="warn">size-only</span>'
        elif outcome == "verified":
            st = '<span class="ok">verified</span>'
        else:
            st = '<span class="bad">NOT COPIED</span>'
        thumbs = "".join(f'<img src="data:image/jpeg;base64,{b64}" title="{lbl}">'
                         for lbl, b64 in m.get("thumbs", []))
        thumbnail_note = ""
        if m.get("thumbnail_unavailable"):
            thumbnail_note = ("<span class=\"warn\">thumbnail unavailable: "
                              f"{_esc(m['thumbnail_unavailable'])}</span>")
        probe_note = ""
        backend = p.get("probe_backend")
        if backend == "r3d-sdk":
            probe_note = ('<span class="ok">R3D probe: native SDK '
                          '(REDline not used)</span>')
        elif backend == "redline":
            fallback_reasons = "; ".join(
                f"{item.get('backend', 'prior backend')}: "
                f"{item.get('reason', 'unavailable')}"
                for item in p.get("probe_fallbacks", [])
                if isinstance(item, dict))
            probe_note = '<span class="warn">R3D probe: REDline fallback'
            if fallback_reasons:
                probe_note += f" — {_esc(fallback_reasons)}"
            probe_note += "</span>"
        rows.append(f"""<tr>
<td class="mono">{_esc(f.rel_path)}</td>
<td>{_human(f.size)}</td>
<td>{_esc(p.get('timecode') or '')}</td>
<td>{_dur(p.get('duration_s'))}</td>
<td>{_esc(tech)}</td>
<td class="mono">{_esc(f.hashes.get('xxh64', ''))}</td>
<td>{st}</td>
</tr>""" + (f'<tr><td colspan="7" class="thumbs">'
             f'{thumbs}{thumbnail_note}{probe_note}</td></tr>'
             if thumbs or thumbnail_note or probe_note else ""))

    fmt_rows = "".join(
        f"<tr><td>{_esc(c)}</td><td>{_esc(r)}</td><td>{_esc(fps) if fps else ''}</td><td>{n}</td></tr>"
        for (c, r, fps), n in sorted(formats.items(), key=lambda kv: -kv[1]))

    dest_rows = "".join(
        f'<tr><td class="mono">{_esc(os.path.join(d, result.label))}</td></tr>'
        for d in result.destinations)

    seen = ""
    if dataset:
        seen = (f' · card seen {dataset.get("mounts", "?")}x since '
                f'{datetime.datetime.fromtimestamp(dataset.get("first_seen", 0)).strftime("%Y-%m-%d")}')

    # Truthful per-destination manifest inventory (round-14 finding 5): one
    # report document lands on EVERY destination, so "manifests on card" must
    # never claim a file that only exists on the other drive. Group the
    # actually-sealed paths by the destination that holds them.
    sealed = list(getattr(result, "manifests", []))
    manifest_bits = []
    for d in result.destinations:
        # Scope to this destination's exact card folder, not the destination
        # root. With nested CLI roots (/D and /D/nested), a raw string-prefix
        # test attributed the child's manifests to both destinations.
        card_root = os.path.abspath(os.path.join(d, result.label))

        def _belongs_to_card(manifest_path):
            try:
                return os.path.commonpath(
                    [os.path.abspath(manifest_path), card_root]) == card_root
            except ValueError:
                return False

        names = sorted(os.path.basename(m) for m in sealed
                       if _belongs_to_card(m))
        shown = d[len("/Volumes/"):] if d.startswith("/Volumes/") else d
        manifest_bits.append(f"{shown}: " + (", ".join(names) if names else "NONE"))
    manifest_footer = ("manifests sealed this job — "
                       + " · ".join(manifest_bits)) if manifest_bits else \
        "manifests: NONE — not written (see errors)"

    doc = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<title>{_esc(result.label)} offload report</title><style>{_CSS}</style></head><body>
<h1>{_esc(result.label)} — offload report
 <span class="badge {vclass}">{verdict}</span></h1>
<div class="sub">{_esc(card_info.format_name)} card · {now.strftime('%Y-%m-%d %H:%M %Z')}
 · {TOOL_NAME} {__version__}{seen}</div>

<h2>Summary</h2>
<table class="kv">
<tr><td>Files on card / copied this run</td><td>{len(files)} / {len(copied)}
 ({len(skipped)} previously offloaded)</td></tr>
<tr><td>Bytes on card / copied this run</td><td>{_human(total_bytes)} / {_human(copied_bytes)}</td></tr>
<tr><td>Video / audio clips analyzed</td><td>{n_video} / {n_audio}</td></tr>
<tr><td>Total media duration</td><td>{_dur(total_dur)}</td></tr>
<tr><td>Job duration</td><td>{result.finished_at - result.started_at:.1f}s</td></tr>
</table>

<h2>Verification attestation</h2>
<table class="kv">
<tr><td>Verification mode</td><td>{'full destination readback' if result.verify_mode == 'full'
 else '<span class="warn">FAST — size check only, DESTINATION NOT VERIFIED</span>'}</td></tr>
<tr><td>Source read passes</td><td>{att['source_read_count']}
 {'(re-read consistent)' if att['source_reread_consistent'] else ''}</td></tr>
<tr><td>Cache-bypass policy</td><td>{'F_NOCACHE succeeded on all destination writes and verify reads (data never entered the buffer cache)'
 if att['write_fd_nocache'] and att['verify_fd_nocache']
 else '<span class="warn">DEGRADED — F_NOCACHE failed on at least one descriptor; some verify reads may have been cache-served</span>'}</td></tr>
<tr><td>Durability</td><td>{'F_FULLFSYNC succeeded per file before close'
 if att['full_flush_before_close']
 else '<span class="warn">DEGRADED — full flush-to-media failed on at least one file (plain fsync fallback)</span>'}</td></tr>
<tr><td>Verified copies / physical devices</td><td>{_copies_devices_text(att)}</td></tr>
<tr><td>Codec/media validation</td><td class="warn">NOT PERFORMED — copy integrity only</td></tr>
</table>

<h2>Destinations</h2>
<table>{dest_rows}</table>

<h2>Formats</h2>
<table><tr><th>Codec</th><th>Format</th><th>FPS</th><th>Clips</th></tr>{fmt_rows or
 '<tr><td colspan="4">no decodable media metadata available; copy integrity unaffected</td></tr>'}</table>

<h2>Files</h2>
<table><tr><th>File</th><th>Size</th><th>TC</th><th>Duration</th><th>Format</th>
<th>xxHash64</th><th>Status</th></tr>
{''.join(rows)}</table>

{'<h2 class="bad">Errors</h2><ul>' + ''.join(f'<li class="bad">{_esc(e)}</li>' for e in result.errors) + '</ul>'
 if result.errors else ''}

{'<h2>Warnings and omissions</h2><ul>' + ''.join(f'<li class="warn">{_esc(w)}</li>' for w in result.warnings) + '</ul>'
 if result.warnings else ''}

<div class="footer">Job {job_id} · {_esc(getpass.getuser())}@{_esc(socket.gethostname())}
 · {_esc(platform.platform())} · report generated AFTER verification settled
 · {_esc(manifest_footer)}</div>
</body></html>"""

    receipt = {
        "job_id": job_id,
        "tool": f"{TOOL_NAME} {__version__}",
        "generated": now.isoformat(),
        "operator": getpass.getuser(),
        "host": socket.gethostname(),
        "label": result.label,
        # These are source facts captured at the time of the immutable
        # receipt.  Reel is camera-reported when available; it is never
        # guessed from a path or label.
        "reel": getattr(card_info, "reel_name", None),
        "runtime_seconds": max(0.0, float(result.finished_at - result.started_at)),
        "source": result.source,
        "destinations": result.destinations,
        "verdict": verdict,
        "attestation": att,
        # The manifests that were ACTUALLY sealed — never assume both formats
        # exist (a legacy-write failure can leave ASC-only; round-13).
        "manifests": list(getattr(result, "manifests", [])),
        "files_total": len(files),
        "files_copied": len(copied),
        "bytes_copied": copied_bytes,
        "errors": result.errors,
        # Per-file hash table: this is where requested extra checksums
        # (sha256/md5/sha1/c4) actually ship — manifests seal xxh64 only.
        "files": [
            {"path": f.rel_path, "size": f.size, "outcome": f.outcome(),
             "hashes": f.hashes or {}, "status": f.dest_status}
            for f in result.files
        ],
    }
    return doc, receipt


# Chrome needs minutes and gigabytes to print a report this large, and the
# 120 s timeout then hides the failure (desktop QA round 5, R5-04). The
# HTML and the receipt are the complete evidence; the PDF is a convenience.
MAX_PDF_HTML_BYTES = 8 * 1024 * 1024


def html_to_pdf_detail(html_path, pdf_path):
    """Headless Chrome render. Returns (ok, detail); detail names the reason
    when the PDF was not produced so it can be reported, never swallowed."""
    chrome = next((p for p in CHROME_PATHS if os.path.exists(p)), None)
    if not chrome:
        return False, "no Chrome or Chromium installed"
    try:
        size = os.path.getsize(html_path)
    except OSError:
        size = 0
    if size > MAX_PDF_HTML_BYTES:
        return False, (f"HTML report is {size // (1024 * 1024)} MB, above the "
                       f"{MAX_PDF_HTML_BYTES // (1024 * 1024)} MB PDF limit; open the HTML")
    try:
        r = subprocess.run(
            [chrome, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
             f"--print-to-pdf={pdf_path}", f"file://{os.path.abspath(html_path)}"],
            capture_output=True, timeout=120,
        )
    except subprocess.TimeoutExpired:
        return False, "Chrome did not finish printing within 120 s"
    except (subprocess.SubprocessError, OSError) as e:
        return False, f"Chrome could not be run: {e}"
    if r.returncode == 0 and os.path.exists(pdf_path):
        return True, ""
    tail = (r.stderr or b"").decode("utf-8", "replace").strip().splitlines()
    return False, (f"Chrome exited {r.returncode}"
                   + (f": {tail[-1][:200]}" if tail else ""))


def html_to_pdf(html_path, pdf_path):
    """Headless Chrome render; returns True on success, False otherwise."""
    return html_to_pdf_detail(html_path, pdf_path)[0]


def write_report(result, att, card_info, media_info, dataset=None, html=True):
    """Write HTML (+PDF +receipt JSON) into <dest>/Reports/<label>/ for every
    destination, plus a local library copy. Returns list of written HTML and
    PDF paths; see write_receipts_and_report for the receipt paths too."""
    return write_receipts_and_report(result, att, card_info, media_info, dataset,
                                     html=html)[0]


def write_receipts_and_report(result, att, card_info, media_info, dataset=None,
                              html=True):
    """Returns (report_paths, receipt_paths). The checksum receipt is the
    evidence the app inspects and the wrap report aggregates, so it is
    written whether or not the operator wants an HTML/PDF report (desktop
    QA round 6, R6-01: reports off left no receipt at all)."""
    doc, receipt = build_report(result, att, card_info, media_info, dataset)
    # Job UUID + microseconds makes every delivery name fresh; exclusive opens
    # enforce the rule even if clocks repeat or an orphaned artifact exists.
    stamp = (datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
             + "_" + receipt["job_id"][:8])
    written = []

    targets = [os.path.join(d, "Reports", result.label) for d in result.destinations]
    local = os.path.join(
        os.environ.get("DUMPTRUCK_HOME")
        or os.path.expanduser("~/Library/Application Support/Dumptruck"),
        "reports", result.label)
    receipts = []
    for tdir in targets + [local]:
        try:
            os.makedirs(tdir, exist_ok=True)
            rpath = os.path.join(tdir, f"{result.label}_offload_{stamp}.receipt.json")
            with open(rpath, "x") as f:
                json.dump(receipt, f, indent=2)
            receipts.append(rpath)
            if html:
                hpath = os.path.join(tdir, f"{result.label}_offload_{stamp}.html")
                with open(hpath, "x") as f:
                    f.write(doc)
                written.append(hpath)
        except OSError:
            continue  # report failure never affects copy state
    if written:
        base, _ext = os.path.splitext(written[0])
        pdf = base + ".pdf"
        ok, detail = html_to_pdf_detail(written[0], pdf)
        if not ok:
            result.warnings.append(
                f"PDF report not generated ({detail}); the HTML report and the "
                "receipt are complete")
        if ok:
            written.append(pdf)
            # copy the pdf to the other targets cheaply
            for other in list(written):
                if other.endswith(".html") and other != written[0]:
                    try:
                        import shutil
                        obase, _ = os.path.splitext(other)
                        shutil.copyfile(pdf, obase + ".pdf")
                    except OSError:
                        pass
    return written, receipts


def validate_receipt_dict(d, filepath="<memory>"):
    """Strictly validate an engine receipt without deriving any verdict.

    Validation is intentionally independent of the safety engine.  It checks
    shape, types, duplicate rows, and bounded values only; it never turns a
    combination of fields into a new safety decision.
    """
    if not isinstance(d, dict):
        raise ValueError(f"Malformed receipt '{filepath}': top-level JSON must be an object")

    for field in ("job_id", "label", "source", "verdict"):
        if field not in d:
            raise ValueError(f"Malformed receipt '{filepath}': missing required field '{field}'")
    _validate_text(d["job_id"], "job_id", maximum=256)
    _validate_text(d["label"], "label", maximum=512)
    _validate_text(d["source"], "source", allow_empty=True)
    _validate_text(d["verdict"], "verdict", maximum=512)

    for field in ("generated", "operator", "host", "tool", "reel", "reel_name"):
        if field in d and d[field] is not None:
            _validate_text(d[field], field, allow_empty=True)
    if "runtime_seconds" in d:
        _optional_runtime(d["runtime_seconds"], "runtime_seconds")

    destinations = d.get("destinations")
    if not isinstance(destinations, list) or not (1 <= len(destinations) <= MAX_DESTINATIONS_PER_RECEIPT):
        raise ValueError(f"Malformed receipt '{filepath}': invalid or missing 'destinations'")
    seen_destinations = set()
    for index, dst in enumerate(destinations):
        _validate_text(dst, f"destinations[{index}]")
        if dst in seen_destinations:
            raise ValueError(f"Malformed receipt '{filepath}': duplicate destination '{dst}'")
        seen_destinations.add(dst)

    att = d.get("attestation")
    if not isinstance(att, dict):
        raise ValueError(f"Malformed receipt '{filepath}': missing or invalid 'attestation' dictionary")
    if "safe_to_wipe_source" not in att or not isinstance(att["safe_to_wipe_source"], bool):
        raise ValueError(f"Malformed receipt '{filepath}': 'attestation.safe_to_wipe_source' must be a boolean")
    for field in _ATTESTATION_BOOL_FIELDS:
        if field in att and not isinstance(att[field], bool):
            # source_reread_consistent is tri-state in the engine when a
            # second read was skipped; preserve that recorded value exactly.
            if field == "source_reread_consistent" and att[field] is None:
                continue
            raise ValueError(f"Malformed receipt '{filepath}': attestation.{field} must be boolean")
    if "source_reread_consistent" in att and att["source_reread_consistent"] is not None \
            and not isinstance(att["source_reread_consistent"], bool):
        raise ValueError(f"Malformed receipt '{filepath}': attestation.source_reread_consistent must be boolean or null")
    for field in _ATTESTATION_INT_FIELDS:
        if field in att:
            _bounded_integer(att[field], f"attestation.{field}", maximum=MAX_FILES_PER_RECEIPT)
    if "safe_to_wipe_blockers" in att:
        blockers = att["safe_to_wipe_blockers"]
        if not isinstance(blockers, list) or len(blockers) > MAX_ERRORS_PER_RECEIPT:
            raise ValueError(f"Malformed receipt '{filepath}': invalid attestation.safe_to_wipe_blockers")
        for index, blocker in enumerate(blockers):
            _validate_text(blocker, f"attestation.safe_to_wipe_blockers[{index}]")

    manifests = d.get("manifests", [])
    if not isinstance(manifests, list) or len(manifests) > MAX_MANIFESTS_PER_RECEIPT:
        raise ValueError(f"Malformed receipt '{filepath}': invalid 'manifests' list")
    seen_manifests = set()
    for index, manifest in enumerate(manifests):
        _validate_text(manifest, f"manifests[{index}]")
        if manifest in seen_manifests:
            raise ValueError(f"Malformed receipt '{filepath}': duplicate manifest '{manifest}'")
        seen_manifests.add(manifest)

    files = d.get("files")
    if not isinstance(files, list) or len(files) > MAX_FILES_PER_RECEIPT:
        raise ValueError(f"Malformed receipt '{filepath}': 'files' must be a list with <= {MAX_FILES_PER_RECEIPT} items")
    seen_file_paths = set()
    total_file_bytes = 0
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            raise ValueError(f"Malformed receipt '{filepath}': file entry must be a dictionary")
        path = item.get("path")
        _validate_text(path, f"files[{index}].path", maximum=4096)
        # Receipt paths are card-relative.  Reject absolute paths, backslash
        # aliases, and dot components before the value reaches HTML.
        if path.startswith("/") or "\\" in path:
            raise ValueError(f"Malformed receipt '{filepath}': files[{index}].path is not relative")
        components = path.split("/")
        if any(component in ("", ".", "..") for component in components):
            raise ValueError(f"Malformed receipt '{filepath}': files[{index}].path contains traversal")
        if path in seen_file_paths:
            raise ValueError(f"Malformed receipt '{filepath}': duplicate file path '{path}'")
        seen_file_paths.add(path)

        size = _bounded_integer(item.get("size"), f"files[{index}].size")
        total_file_bytes += size
        if total_file_bytes > MAX_INTEGER:
            raise ValueError(f"Malformed receipt '{filepath}': aggregate file sizes exceed bound")

        outcome = item.get("outcome")
        if outcome not in _FILE_OUTCOMES:
            raise ValueError(f"Malformed receipt '{filepath}': files[{index}].outcome is invalid")

        hashes = item.get("hashes", {})
        if not isinstance(hashes, dict) or len(hashes) > MAX_HASHES_PER_FILE:
            raise ValueError(f"Malformed receipt '{filepath}': files[{index}].hashes is invalid")
        for algorithm, digest in hashes.items():
            if algorithm not in _HASH_ALGORITHMS:
                raise ValueError(f"Malformed receipt '{filepath}': unsupported hash algorithm '{algorithm}'")
            _validate_text(digest, f"files[{index}].hashes.{algorithm}", maximum=256)
            if algorithm == "c4":
                if len(digest) != 90 or not digest.startswith("c4"):
                    raise ValueError(f"Malformed receipt '{filepath}': invalid c4 checksum")
            elif len(digest) != _HASH_LENGTHS[algorithm] \
                    or digest != digest.lower() \
                    or any(char not in "0123456789abcdef" for char in digest):
                raise ValueError(f"Malformed receipt '{filepath}': invalid {algorithm} checksum")

        status = item.get("status", {})
        if not isinstance(status, dict) or len(status) > MAX_STATUS_ENTRIES_PER_FILE:
            raise ValueError(f"Malformed receipt '{filepath}': files[{index}].status is invalid")
        for destination, state in status.items():
            _validate_text(destination, f"files[{index}].status destination")
            if state not in _DESTINATION_STATUSES:
                raise ValueError(f"Malformed receipt '{filepath}': files[{index}].status value is invalid")

    files_total = _bounded_integer(d.get("files_total", len(files)), "files_total",
                                   maximum=MAX_FILES_PER_RECEIPT)
    files_copied = _bounded_integer(d.get("files_copied", len(files)), "files_copied",
                                    maximum=MAX_FILES_PER_RECEIPT)
    if files_total < len(files) or files_copied > files_total:
        raise ValueError(f"Malformed receipt '{filepath}': file counts are inconsistent")
    bytes_copied = _bounded_integer(d.get("bytes_copied", 0), "bytes_copied")
    if bytes_copied > total_file_bytes:
        raise ValueError(f"Malformed receipt '{filepath}': bytes_copied exceeds listed file bytes")

    errors = d.get("errors", [])
    if not isinstance(errors, list) or len(errors) > MAX_ERRORS_PER_RECEIPT:
        raise ValueError(f"Malformed receipt '{filepath}': invalid 'errors' list")
    for index, error in enumerate(errors):
        _validate_text(error, f"errors[{index}]")

    return d


def load_and_validate_receipt(filepath):
    """Read and strictly validate one immutable receipt JSON file.

    The descriptor and pathname are compared before and after the read.  A
    receipt replaced or modified while being loaded is rejected instead of
    becoming a mixed-generation wrap report.
    """
    if not isinstance(filepath, (str, os.PathLike)):
        raise ValueError("Receipt path must be a string or PathLike")
    path_str = os.fspath(filepath)
    if not path_str or len(path_str.encode("utf-8")) > MAX_STRING_BYTES:
        raise ValueError("Receipt path is invalid or too long")

    norm_path = os.path.abspath(path_str)
    if not norm_path.lower().endswith(".receipt.json"):
        raise ValueError(f"Receipt path must end with '.receipt.json': '{path_str}'")

    try:
        named_before = os.lstat(norm_path)
    except FileNotFoundError as e:
        raise FileNotFoundError(f"Receipt file not found: '{path_str}'") from e
    except OSError as e:
        raise ValueError(f"Cannot inspect receipt file '{path_str}': {e}") from e
    if not stat.S_ISREG(named_before.st_mode):
        raise ValueError(f"Receipt path is not a regular file: '{path_str}'")

    fd = -1
    try:
        fd = os.open(norm_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened_before = os.fstat(fd)
        if not stat.S_ISREG(opened_before.st_mode):
            raise ValueError(f"Receipt path is not a regular file: '{path_str}'")
        if (named_before.st_dev, named_before.st_ino) != (opened_before.st_dev, opened_before.st_ino):
            raise ValueError(f"Receipt file changed while opening: '{path_str}'")
        if opened_before.st_size <= 0:
            raise ValueError(f"Receipt file '{path_str}' is empty")
        if opened_before.st_size > MAX_RECEIPT_BYTES:
            raise ValueError(f"Receipt file '{path_str}' exceeds maximum allowed size ({opened_before.st_size} > {MAX_RECEIPT_BYTES} bytes)")

        chunks = []
        remaining = MAX_RECEIPT_BYTES + 1
        while remaining:
            chunk = os.read(fd, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > MAX_RECEIPT_BYTES:
            raise ValueError(f"Receipt file '{path_str}' exceeds maximum allowed size")

        opened_after = os.fstat(fd)
        named_after = os.lstat(norm_path)
        before_identity = (opened_before.st_dev, opened_before.st_ino,
                           opened_before.st_size, opened_before.st_mtime_ns,
                           opened_before.st_ctime_ns)
        after_identity = (opened_after.st_dev, opened_after.st_ino,
                          opened_after.st_size, opened_after.st_mtime_ns,
                          opened_after.st_ctime_ns)
        named_identity = (named_after.st_dev, named_after.st_ino,
                          named_after.st_size, named_after.st_mtime_ns,
                          named_after.st_ctime_ns)
        if before_identity != after_identity or before_identity != named_identity \
                or len(raw) != opened_before.st_size:
            raise ValueError(f"Receipt file changed during read: '{path_str}'")
    except ValueError:
        raise
    except OSError as e:
        raise ValueError(f"Failed to read receipt file '{path_str}': {e}") from e
    finally:
        if fd >= 0:
            os.close(fd)

    try:
        data = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        raise ValueError(f"Receipt file '{path_str}' contains invalid JSON: {e}") from e
    return validate_receipt_dict(data, filepath=norm_path)


def build_wrap_report(receipts, title=None):
    """Build aggregated shoot-day wrap report HTML from a list of validated receipts.

    INVARIANTS:
    1. Strictly validates schemas and bounds.
    2. Rejects duplicate receipts (duplicate job_id).
    3. Never recomputes safety verdicts; presents recorded verdicts and attestations faithfully.
    4. Escapes all strings for HTML safety (anti-XSS).
    5. Includes cards, reels, bytes, runtime, destinations, verification attestations, and a clip index.
    """
    if not receipts:
        raise ValueError("Cannot build wrap report: receipts list is empty")
    if len(receipts) > MAX_RECEIPTS_PER_WRAP:
        raise ValueError(f"Too many receipts for wrap report ({len(receipts)} > {MAX_RECEIPTS_PER_WRAP})")

    total_files_in_wrap = sum(len(r.get("files", [])) for r in receipts)
    if total_files_in_wrap > MAX_TOTAL_FILES_PER_WRAP:
        raise ValueError(f"Total files across receipts ({total_files_in_wrap}) exceeds maximum bound of {MAX_TOTAL_FILES_PER_WRAP}")

    seen_ids = set()
    for r in receipts:
        jid = r["job_id"]
        if jid in seen_ids:
            raise ValueError(f"Duplicate receipt with job_id '{jid}' for card '{r.get('label')}'")
        seen_ids.add(jid)

    now = datetime.datetime.now().astimezone()
    wrap_id = str(uuid_mod.uuid4())
    report_title = title or "Shoot Day Wrap Report"

    total_cards = len(receipts)
    total_files = sum(r.get("files_total", len(r.get("files", []))) for r in receipts)
    total_copied_files = sum(r.get("files_copied", len(r.get("files", []))) for r in receipts)
    total_bytes = sum(r.get("bytes_copied", sum(f.get("size", 0) for f in r.get("files", []))) for r in receipts)
    all_errors = [(r.get("label", "Unknown"), err) for r in receipts for err in r.get("errors", [])]

    # A wrap report is a consolidation of immutable evidence, not another
    # safety adjudicator.  Keep the header deliberately neutral and show each
    # receipt's recorded verdict/attestation below without deriving an
    # aggregate "safe" or "verified" result.
    recorded_safe_attestations = sum(
        1 for r in receipts
        if r.get("attestation", {}).get("safe_to_wipe_source") is True
    )
    verdict_text = "RECORDED RECEIPTS · SAFETY NOT RECOMPUTED"
    vclass = "warn"

    # Card rows for Cards Table
    card_rows = []
    for r in receipts:
        label = r.get("label", "")
        reel = r.get("reel") or r.get("reel_name") or "Not recorded"
        src = r.get("source", "")
        dests = r.get("destinations", [])
        dest_str = "\n".join(dests)   # one lane per line; escaped and broken below
        fc = r.get("files_copied", 0)
        ft = r.get("files_total", len(r.get("files", [])))
        bc = r.get("bytes_copied", sum(f.get("size", 0) for f in r.get("files", [])))
        v = r.get("verdict", "")

        att = r.get("attestation", {})
        wipe_safe = att["safe_to_wipe_source"]
        wipe_text = ("Recorded safe_to_wipe_source=true" if wipe_safe
                     else "Recorded safe_to_wipe_source=false")

        card_rows.append(f"""<tr>
<td class="mono"><strong>{_esc(label)}</strong></td>
<td class="mono">{_esc(reel)}</td>
<td class="mono">{_esc(src)}</td>
<td class="mono">{_esc(dest_str).replace(chr(10), "<br>")}</td>
<td>{fc} / {ft}</td>
<td class="mono">{_human(bc)}</td>
<td><span class="badge warn">{_esc(v)}</span></td>
<td>{_esc(wipe_text)}</td>
<td>{_esc(_format_runtime(r.get("runtime_seconds")))}</td>
</tr>""")

    # Verification Attestations Breakdown Table
    att_rows = []
    for r in receipts:
        label = r.get("label", "")
        att = r.get("attestation", {})
        vmode = _attestation_text(att, "destination_readback")
        nocache = ("write=" + _attestation_text(att, "write_fd_nocache")
                   + ", verify=" + _attestation_text(att, "verify_fd_nocache"))
        flush = _attestation_text(att, "full_flush_before_close")
        copies_devs = _copies_devices_text(att, labeled=True)
        reread = (f"passes={_attestation_text(att, 'source_read_count')}, "
                  f"consistent={_attestation_text(att, 'source_reread_consistent')}")
        blockers_value = att.get("safe_to_wipe_blockers")
        if blockers_value is None:
            blocker_str = "Not recorded"
        elif blockers_value:
            blocker_str = "; ".join(blockers_value)
        else:
            blocker_str = "Recorded empty blocker list"

        att_rows.append(f"""<tr>
<td class="mono"><strong>{_esc(label)}</strong></td>
<td>{_esc(vmode)}</td>
<td>{_esc(nocache)}</td>
<td>{_esc(flush)}</td>
<td class="mono">{_esc(copies_devs)}</td>
<td>{_esc(reread)}</td>
<td>{_esc(blocker_str)}</td>
</tr>""")

    # Aggregated Clip Index Table
    clip_rows = []
    all_clips = []
    for r in receipts:
        card_lbl = r.get("label", "")
        for f in r.get("files", []):
            all_clips.append((card_lbl, f))

    all_clips.sort(key=lambda item: (item[0], item[1].get("path", "")))

    for card_lbl, f in all_clips:
        rel_path = f.get("path", "")
        size = f.get("size", 0)
        outcome = f.get("outcome", "")
        if outcome == "verified":
            st = '<span class="ok">verified</span>'
        elif outcome == "skipped":
            st = '<span class="warn">skipped</span>'
        elif outcome in ("failed", "conflict"):
            st = '<span class="bad">FAILED</span>'
        elif outcome == "size-only":
            st = '<span class="warn">size-only</span>'
        else:
            st = f'<span class="bad">{_esc(outcome)}</span>'

        hashes = f.get("hashes", {})
        primary_hash = hashes.get("xxh64") or hashes.get("sha256") or hashes.get("md5") or (next(iter(hashes.values())) if hashes else "")

        clip_rows.append(f"""<tr>
<td class="mono"><strong>{_esc(card_lbl)}</strong></td>
<td class="mono">{_esc(rel_path)}</td>
<td class="mono">{_human(size)}</td>
<td class="mono">{_esc(primary_hash)}</td>
<td>{st}</td>
</tr>""")

    error_section = ""
    if all_errors:
        err_items = "".join(f'<li class="bad"><strong>{_esc(lbl)}:</strong> {_esc(err)}</li>' for lbl, err in all_errors)
        error_section = f"""<h2 class="bad">Errors & Anomalies</h2>
<ul class="err-list">{err_items}</ul>"""

    doc = f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<title>{_esc(report_title)}</title><style>{_WRAP_CSS}</style></head><body>
<h1>{_esc(report_title)} <span class="badge {vclass}">{_esc(verdict_text)}</span></h1>
<div class="sub">{total_cards} card(s) aggregated · {now.strftime('%Y-%m-%d %H:%M %Z')} · {TOOL_NAME} {__version__}</div>

<div class="summary-grid">
  <div class="summary-card">
    <div class="lbl">Cards Offloaded</div>
    <div class="val">{total_cards}</div>
  </div>
  <div class="summary-card">
    <div class="lbl">Total Data Copied</div>
    <div class="val">{_human(total_bytes)}</div>
  </div>
  <div class="summary-card">
    <div class="lbl">Files Copied / Total</div>
    <div class="val">{total_copied_files} / {total_files}</div>
  </div>
  <div class="summary-card">
    <div class="lbl">Recorded Safe Attestations</div>
    <div class="val warn">{recorded_safe_attestations} of {total_cards}</div>
  </div>
</div>

<h2>Cards & Reels Overview</h2>
<table>
<tr>
  <th>Card</th>
  <th>Reel</th>
  <th>Source</th>
  <th>Destinations</th>
  <th>Files</th>
  <th>Data Copied</th>
  <th>Verdict</th>
  <th>Recorded Wipe Attestation</th>
  <th>Runtime</th>
</tr>
{''.join(card_rows)}
</table>

<h2>Verification & Attestation Audit</h2>
<table>
<tr>
  <th>Card</th>
  <th>Verification Mode</th>
  <th>Cache Bypass</th>
  <th>Durability</th>
  <th>Copies & Hardware</th>
  <th>Source Re-read</th>
  <th>Wipe Gate / Notes</th>
</tr>
{''.join(att_rows)}
</table>

<h2>Aggregated Clip Index ({len(all_clips)} files)</h2>
<table>
<tr>
  <th>Card</th>
  <th>Relative Path</th>
  <th>Size</th>
  <th>Checksum (Primary)</th>
  <th>Outcome</th>
</tr>
{''.join(clip_rows)}
</table>

{error_section}

<div class="footer">Wrap Report {wrap_id} · {_esc(getpass.getuser())}@{_esc(socket.gethostname())}
 · {_esc(platform.platform())} · generated AFTER verification settled</div>
</body></html>"""

    return doc, wrap_id


def write_wrap_report(receipt_paths, out_dir=None, title=None, no_pdf=False):
    """Load, validate, and write a wrap report from selected receipt paths.
    Returns dictionary with report metadata and written paths."""
    if not receipt_paths:
        raise ValueError("No receipt paths provided for wrap report")
    if len(receipt_paths) > MAX_RECEIPTS_PER_WRAP:
        raise ValueError(f"Too many receipt paths ({len(receipt_paths)} > {MAX_RECEIPTS_PER_WRAP})")

    norm_paths = [os.path.abspath(os.fspath(p)) for p in receipt_paths]
    if len(norm_paths) != len(set(norm_paths)):
        raise ValueError("Duplicate receipt paths provided in arguments")

    receipts = [load_and_validate_receipt(p) for p in norm_paths]
    doc, wrap_id = build_wrap_report(receipts, title=title)

    if out_dir:
        target_dir = os.path.abspath(out_dir)
        os.makedirs(target_dir, exist_ok=True)
    else:
        def _destination_holds_receipt_evidence(dest, receipt):
            # Receipts are unsigned JSON from anywhere: a destination string
            # may only auto-target a directory that ALREADY exists and holds
            # at least one manifest this receipt actually references (Ox L1).
            # Never create directory trees at bare receipt-controlled paths;
            # anything else needs an explicit --out from the operator.
            if os.path.islink(dest) or not os.path.isdir(dest):
                return False
            dest_abs = os.path.abspath(dest)
            for m in receipt.get("manifests", []):
                try:
                    m_abs = os.path.abspath(os.fspath(m))
                    inside = os.path.commonpath([m_abs, dest_abs]) == dest_abs
                except (ValueError, TypeError):
                    continue
                if inside and os.path.isfile(m_abs):
                    return True
            return False

        target_dir = None
        for r in receipts:
            for d in r.get("destinations", []):
                if not _destination_holds_receipt_evidence(d, r):
                    continue
                cand = os.path.join(d, "Reports", "Wrap")
                try:
                    os.makedirs(cand, exist_ok=True)
                    target_dir = cand
                    break
                except OSError:
                    continue
            if target_dir:
                break
        if not target_dir:
            local = os.path.join(
                os.environ.get("DUMPTRUCK_HOME")
                or os.path.expanduser("~/Library/Application Support/Dumptruck"),
                "reports", "wrap")
            try:
                os.makedirs(local, exist_ok=True)
                target_dir = local
            except OSError:
                target_dir = os.getcwd()

    for attempt in range(100):
        stamp = (datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                 + "_" + wrap_id[:8] + (f"_{attempt}" if attempt > 0 else ""))
        html_path = os.path.join(target_dir, f"wrap_report_{stamp}.html")
        try:
            with open(html_path, "x", encoding="utf-8") as f:
                f.write(doc)
            break
        except FileExistsError:
            continue
    else:
        raise OSError("Failed to create unique fresh wrap report filename")

    written = [html_path]
    pdf_path = None
    pdf_generated = False

    if not no_pdf:
        candidate_pdf = os.path.splitext(html_path)[0] + ".pdf"
        if os.path.lexists(candidate_pdf):
            raise OSError(f"refusing to overwrite existing PDF output: {candidate_pdf}")
        # Chrome writes to its target path.  Give it a fresh throwaway name,
        # then reserve the final name with an exclusive hard-link so a race
        # cannot overwrite another operator's report.
        temporary_pdf = candidate_pdf + ".tmp-" + uuid_mod.uuid4().hex
        try:
            pdf_ok, pdf_reason = html_to_pdf_detail(html_path, temporary_pdf)
            if not pdf_ok:
                # The real reason (size limit, timeout, no Chrome) travels
                # to the operator; "renderer unavailable" was wrong for a
                # 12 MB wrap that simply exceeded the PDF limit (round 6, R6-02).
                raise WrapReportPDFUnavailable(html_path, reason=pdf_reason)
            os.link(temporary_pdf, candidate_pdf)
            pdf_path = candidate_pdf
            pdf_generated = True
            written.append(pdf_path)
        except FileExistsError as e:
            raise OSError(f"refusing to overwrite existing PDF output: {candidate_pdf}") from e
        finally:
            try:
                os.unlink(temporary_pdf)
            except FileNotFoundError:
                pass

    total_bytes = sum(r.get("bytes_copied", sum(f.get("size", 0) for f in r.get("files", []))) for r in receipts)
    total_files = sum(r.get("files_copied", len(r.get("files", []))) for r in receipts)
    recorded_safe_attestations = sum(
        1 for r in receipts
        if r.get("attestation", {}).get("safe_to_wipe_source") is True
    )

    return {
        "wrap_id": wrap_id,
        "html_path": html_path,
        "pdf_path": pdf_path,
        "pdf_generated": pdf_generated,
        "written": written,
        "cards": [r.get("label", "") for r in receipts],
        "total_cards": len(receipts),
        "total_bytes": total_bytes,
        "total_files": total_files,
        "safe_cards": recorded_safe_attestations,
        # Retained as an explicit non-authoritative field for older GUI
        # callers.  It is never used to grant wipe/eject authority and is
        # deliberately false: safety verdicts belong to each receipt.
        "all_safe": False,
    }
