"""Camera-card detection by folder signature, most-specific-first.

Detection never requires parsing media; the folder structure is the signature.
Reel names: trust camera-embedded identity (ARRI/RED/BRAW), otherwise None and
the operator's label (default: volume name) wins.
"""

import os
import re
from dataclasses import dataclass


@dataclass
class CardInfo:
    format_id: str
    format_name: str
    reel_name: str | None = None  # camera-embedded only; never guessed


def _entries(root):
    try:
        return sorted(os.listdir(root))
    except OSError:
        return []


def _dirs(root):
    return [e for e in _entries(root) if os.path.isdir(os.path.join(root, e))]


def _has_ext(root, ext, depth=2):
    """Any file with ext within depth levels (case-insensitive)."""
    ext = ext.lower()
    base_depth = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath.rstrip(os.sep).count(os.sep) - base_depth >= depth:
            dirnames[:] = []
            continue
        for f in filenames:
            if f.lower().endswith(ext):
                return os.path.join(dirpath, f)
    return None


def _has_name(root, pattern, depth=2):
    """Any filename matching pattern within depth levels."""
    base_depth = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath.rstrip(os.sep).count(os.sep) - base_depth >= depth:
            dirnames[:] = []
            continue
        if any(pattern.match(f) for f in filenames):
            return True
    return False


_ARRI_REEL = re.compile(r"^[A-Z]\d{3}[A-Z0-9]{4}$")
_ATOMOS = re.compile(r"^.+_S\d{3}_S\d{3}_T\d{3}\.(mov|mp4)$", re.IGNORECASE)
_BRAW_REEL = re.compile(r"^([A-Z]\d{3})_\d+_C\d+", re.IGNORECASE)
_SONY_CINE_REEL = re.compile(r"^[A-Z]\d{3}[A-Z]{4}$")
_ZCAM_REEL = re.compile(r"^[A-Z]\d{3}$", re.IGNORECASE)
_ZCAM_CLIP = re.compile(r"^([A-Z]\d{3})C\d{4}.*\.(MOV|MP4)$", re.IGNORECASE)
_ZOOM_FOLDER = re.compile(r"^FOLDER\d{2}$", re.IGNORECASE)
_ZOOM_FILE = re.compile(r"^ZOOM\d{4}(?:[_-].*)?\.WAV$", re.IGNORECASE)
_TASCAM_FILE = re.compile(r"^TASCAM_\d{4}(?:S\d+)?\.WAV$", re.IGNORECASE)
_MIXPRE_FILE = re.compile(r"^MIXPRE-\d{3}(?:[_-].*)?\.WAV$", re.IGNORECASE)


def _real(root, upper_name, dirs):
    """Real dirname for a case-insensitive signature match (case-sensitive
    filesystems ship real camera cards too)."""
    for d in dirs:
        if d.upper() == upper_name:
            return d
    return None


def detect(root) -> CardInfo:
    entries = _entries(root)
    dirs = _dirs(root)
    files = [e for e in entries if os.path.isfile(os.path.join(root, e))]

    # 1. RED: reel.RDM/ -> clip.RDC/ -> .R3D
    rdms = [d for d in dirs if d.upper().endswith(".RDM")]
    for rdm in rdms:
        rdcs = [d for d in _dirs(os.path.join(root, rdm)) if d.upper().endswith(".RDC")]
        if rdcs:
            return CardInfo("red", "RED", reel_name=rdm.split("_")[0])

    # 2. ARRI: A001R2EC-style reel dir with .ari/.mxf (or camera-written ascmhl)
    for d in dirs:
        if _ARRI_REEL.match(d):
            sub = os.path.join(root, d)
            if (_has_ext(sub, ".ari", 1) or _has_ext(sub, ".mxf", 1)
                    or os.path.isdir(os.path.join(sub, "ascmhl"))):
                return CardInfo("arri", "ARRI", reel_name=d)

    # Sony VENICE 2 / BURANO X-OCN: CINEROOT (renamed to a camera/reel
    # identifier after first record) -> Clip -> one directory per MXF clip.
    # Older VENICE media can retain XDROOT, so require nested clip folders
    # there rather than reclassifying the flat XAVC layout below.
    sony_cine_roots = [d for d in dirs if d.upper() == "CINEROOT"
                       or _SONY_CINE_REEL.match(d)]
    root_xd = _real(root, "XDROOT", dirs)
    if root_xd:
        sony_cine_roots.append(root_xd)
    for cine_name in sony_cine_roots:
        cine_root = os.path.join(root, cine_name)
        clip_name = _real(cine_root, "CLIP", _dirs(cine_root))
        if not clip_name:
            continue
        clip_root = os.path.join(cine_root, clip_name)
        if any(_has_ext(os.path.join(clip_root, d), ".mxf", 1)
               for d in _dirs(clip_root)):
            reel = cine_name if _SONY_CINE_REEL.match(cine_name) else None
            return CardInfo("sony_xocn", "Sony VENICE / X-OCN", reel_name=reel)

    # 3. Panasonic P2: CONTENTS + LASTCLIP.TXT
    contents = _real(root, "CONTENTS", dirs)
    if contents and any(e.upper() == "LASTCLIP.TXT" for e in files):
        return CardInfo("p2", "Panasonic P2")

    # 4. Canon Cinema RAW Light. C200-era cards use the XF-style CONTENTS
    # tree; newer Cinema EOS bodies use CRM/REEL_###.
    if contents:
        crm = _has_ext(os.path.join(root, contents), ".crm", 3)
        if crm:
            return CardInfo("canon_crl", "Canon Cinema RAW Light")
        for clips in _dirs(os.path.join(root, contents)):
            if clips.upper().startswith("CLIPS") and any(
                e.upper() == "INDEX.MIF"
                for e in _entries(os.path.join(root, contents, clips))
            ):
                return CardInfo("canon_xf", "Canon XF")
    crm_root_name = _real(root, "CRM", dirs)
    if crm_root_name:
        crm_root = os.path.join(root, crm_root_name)
        for reel_dir in _dirs(crm_root):
            if reel_dir.upper().startswith("REEL_") and _has_ext(
                    os.path.join(crm_root, reel_dir), ".crm", 1):
                return CardInfo("canon_crl", "Canon Cinema RAW Light",
                                reel_name=reel_dir)

    # 5. Sony XAVC: PRIVATE/M4ROOT|XDROOT|PXROOT
    private = _real(root, "PRIVATE", dirs)
    if private and os.path.isdir(os.path.join(root, private)):
        sub = {d.upper() for d in _dirs(os.path.join(root, private))}
        if "M4ROOT" in sub:
            return CardInfo("sony_xavc_s", "Sony XAVC S")
        if "XDROOT" in sub or "PXROOT" in sub:
            return CardInfo("sony_xavc", "Sony XAVC-I/L")
        if "AVCHD" in sub:
            return CardInfo("avchd", "AVCHD")

    # 6. Sony XDCAM: BPAV
    if "BPAV" in (d.upper() for d in dirs):
        return CardInfo("sony_xdcam", "Sony XDCAM EX")

    # 7. Blackmagic BRAW: .braw at/near root, no RED wrapper
    braw = _has_ext(root, ".braw", 2)
    if braw and not rdms:
        m = _BRAW_REEL.match(os.path.basename(braw))
        return CardInfo("braw", "Blackmagic RAW", reel_name=m.group(1).upper() if m else None)

    # Kinefinity KineRAW clips are directories containing numbered .krw
    # frame sequences. The extension is vendor-specific, so it remains a
    # useful signature even when the operator has renamed the clip folder.
    if _has_ext(root, ".krw", 3):
        return CardInfo("kinefinity", "Kinefinity KineRAW")

    # Z CAM E2 media uses root reel folders (A001, A002, ...) and matching
    # A001C0004-style clip names. Do not infer Z CAM from a generic DCIM tree.
    for d in dirs:
        if not _ZCAM_REEL.match(d):
            continue
        reel_root = os.path.join(root, d)
        if any((match := _ZCAM_CLIP.match(f)) and match.group(1).upper() == d.upper()
               for f in _entries(reel_root)):
            return CardInfo("zcam", "Z CAM", reel_name=d.upper())

    # 8-11. DCIM families. Some Nikon media exposes DCIM below a NIKON
    # wrapper, so inspect that documented variant without treating NIKON
    # alone as proof of an N-RAW card.
    dcim_name = _real(root, "DCIM", dirs)
    dcim = os.path.join(root, dcim_name) if dcim_name else ""
    if not dcim:
        nikon_name = _real(root, "NIKON", dirs)
        if nikon_name:
            nikon_root = os.path.join(root, nikon_name)
            nested_dcim = _real(nikon_root, "DCIM", _dirs(nikon_root))
            if nested_dcim:
                dcim = os.path.join(nikon_root, nested_dcim)
    if dcim and os.path.isdir(dcim):
        sub = _dirs(dcim)
        if _has_ext(dcim, ".nev", 2):
            return CardInfo("nikon_nraw", "Nikon N-RAW")
        if any(d.upper().endswith("_FUJI") for d in sub):
            return CardInfo("fujifilm", "Fujifilm")
        camera01 = next((d for d in sub if d.upper() == "CAMERA01"), None)
        if camera01 and (_has_ext(os.path.join(dcim, camera01), ".insv", 2)
                         or _has_ext(os.path.join(dcim, camera01), ".insp", 2)):
            return CardInfo("insta360", "Insta360")
        if any(d.upper().endswith("GOPRO") for d in sub):
            return CardInfo("gopro", "GoPro")
        if any(re.match(r"^DJI_\d{3}$", d, re.IGNORECASE) for d in sub):
            return CardInfo("dji_osmo", "DJI Osmo / Action")
        if any(d.upper().endswith("MEDIA") for d in sub) or os.path.isdir(
            os.path.join(root, "MISC", "GIS")
        ):
            return CardInfo("dji", "DJI")
        if any(d.upper().endswith("CANON") for d in sub):
            return CardInfo("canon_dcim", "Canon (DCIM)")
        if any("_PANA" in d.upper() for d in sub):
            return CardInfo("lumix", "Panasonic Lumix")
        return CardInfo("dcim", "Generic camera (DCIM)")

    # 12. Atomos: flat UNIT_S001_S001_T001.MOV at root
    if any(_ATOMOS.match(f) for f in files):
        return CardInfo("atomos", "Atomos recorder")

    # Named audio recorders run before the broad WAV-dominant fallback.
    sounddev = _real(root, "SOUNDDEV", dirs)
    if sounddev:
        return CardInfo("sound_devices", "Sound Devices recorder")
    if _has_name(root, _MIXPRE_FILE, 3):
        return CardInfo("sound_devices", "Sound Devices recorder")
    for d in dirs:
        if _ZOOM_FOLDER.match(d) and any(
                _ZOOM_FILE.match(f) for f in _entries(os.path.join(root, d))):
            return CardInfo("zoom_f", "Zoom F-series recorder")
    if _has_name(root, _TASCAM_FILE, 3):
        return CardInfo("tascam", "Tascam recorder")

    # 13. Audio recorder: WAV-dominant tree with no video anywhere near the root
    wav = _has_ext(root, ".wav", 2)
    if wav and not any(
        _has_ext(root, ext, 2) for ext in (".mov", ".mp4", ".mxf", ".braw", ".mts")
    ):
        return CardInfo("audio", "Audio recorder")

    return CardInfo("generic", "Generic data")
