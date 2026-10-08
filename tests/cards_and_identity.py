"""Phase 2 self-test: card-format detection + dataset identity/continuation.

Run:  .venv/bin/python tests/cards_and_identity.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)

from dumptruck import cards  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  ({detail})" if detail and not cond else ""))


def touch(base, rel, size=64):
    full = os.path.join(base, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(os.urandom(size))


def cli(env, *argv):
    r = subprocess.run(
        [sys.executable, "-m", "dumptruck.cli", *argv],
        capture_output=True, text=True, cwd=HERE, env={**os.environ, **env},
    )
    return r.returncode, r.stdout + r.stderr


def detection_tests(base):
    print("[detection]")
    layouts = {
        "braw": (lambda r: touch(r, "A001_08191412_C001.braw", 128), "braw"),
        "red": (lambda r: touch(r, "A001_C001_0819.RDM/A001_C001_08196M.RDC/A001_C001_001.R3D"), "red"),
        "arri": (lambda r: touch(r, "A001R2EC/A001C001_260819_R2EC.mxf"), "arri"),
        "sony_xocn": (lambda r: touch(
            r, "A001CRWE/Clip/A001C001_260822/A001C001_260822.mxf"), "sony_xocn"),
        "sony_xocn_xdroot": (lambda r: touch(
            r, "XDROOT/Clip/A001C002_260822/A001C002_260822.mxf"), "sony_xocn"),
        "p2": (lambda r: (touch(r, "CONTENTS/VIDEO/0001AB.MXF"), touch(r, "LASTCLIP.TXT", 8)), "p2"),
        "canon_crl": (lambda r: touch(
            r, "CONTENTS/CLIPS001/AA0001/AA000101.CRM"), "canon_crl"),
        "canon_crl_reel": (lambda r: touch(
            r, "CRM/REEL_007/A_0001C001_CANON.CRM"), "canon_crl"),
        "canon_xf": (lambda r: (touch(r, "CONTENTS/CLIPS001/INDEX.MIF", 8),
                                touch(r, "CONTENTS/CLIPS001/AA0001/AA000101.MXF")), "canon_xf"),
        "sony_xavc_s": (lambda r: touch(r, "PRIVATE/M4ROOT/CLIP/C0001.MP4"), "sony_xavc_s"),
        "sony_xavc": (lambda r: touch(r, "PRIVATE/XDROOT/Clip/A001C001.MXF"), "sony_xavc"),
        "gopro": (lambda r: touch(r, "DCIM/100GOPRO/GX010001.MP4"), "gopro"),
        "dji": (lambda r: (touch(r, "DCIM/100MEDIA/DJI_0001.MP4"), touch(r, "MISC/GIS/x.dat", 8)), "dji"),
        "dji_osmo": (lambda r: touch(r, "DCIM/DJI_001/DJI_0001.MP4"), "dji_osmo"),
        "canon_dcim": (lambda r: touch(r, "DCIM/100CANON/MVI_0001.MP4"), "canon_dcim"),
        "nikon_nraw": (lambda r: touch(r, "DCIM/100NCZ_9/DSC_0001.NEV"), "nikon_nraw"),
        "nikon_nraw_wrapped": (lambda r: touch(
            r, "NIKON/DCIM/100NCZ_9/DSC_0002.NEV"), "nikon_nraw"),
        "fujifilm": (lambda r: touch(r, "DCIM/100_FUJI/DSCF0001.MOV"), "fujifilm"),
        "kinefinity": (lambda r: touch(
            r, "PRJ-0002-003-A2_5D8B/PRJ-0002-003-A2_5D8B_0000001.krw"),
            "kinefinity"),
        "zcam": (lambda r: touch(r, "A001/A001C0004.MOV"), "zcam"),
        "insta360": (lambda r: touch(
            r, "DCIM/Camera01/VID_20260822_120000_00_001.insv"), "insta360"),
        "sound_devices": (lambda r: (touch(r, "SOUNDDEV/SDINFO.TXT"), touch(
            r, "09Y10M15/09Y10M15-001.WAV")), "sound_devices"),
        "sound_devices_mixpre": (lambda r: touch(
            r, "PROJECT/MixPre-032.wav"), "sound_devices"),
        "zoom_f": (lambda r: touch(r, "FOLDER01/ZOOM0001.WAV"), "zoom_f"),
        "tascam": (lambda r: touch(r, "AUDIO/TASCAM_0001S12.WAV"), "tascam"),
        "audio": (lambda r: (touch(r, "SC01/SC01_T01.wav"), touch(r, "SC01/SC01_T02.wav")), "audio"),
        "generic": (lambda r: touch(r, "random/stuff.bin"), "generic"),
    }
    for name, (builder, expect) in layouts.items():
        root = os.path.join(base, f"layout_{name}")
        os.makedirs(root)
        builder(root)
        got = cards.detect(root)
        check(f"detect {name}", got.format_id == expect, f"got {got.format_id}")
    braw = cards.detect(os.path.join(base, "layout_braw"))
    check("braw reel extracted", braw.reel_name == "A001", str(braw.reel_name))
    red = cards.detect(os.path.join(base, "layout_red"))
    check("red reel extracted", red.reel_name == "A001", str(red.reel_name))
    sony = cards.detect(os.path.join(base, "layout_sony_xocn"))
    check("Sony X-OCN reel extracted", sony.reel_name == "A001CRWE", str(sony.reel_name))
    canon_crl = cards.detect(os.path.join(base, "layout_canon_crl_reel"))
    check("Canon RAW Light reel extracted",
          canon_crl.reel_name == "REEL_007", str(canon_crl.reel_name))
    zcam = cards.detect(os.path.join(base, "layout_zcam"))
    check("Z CAM reel extracted", zcam.reel_name == "A001", str(zcam.reel_name))


def identity_tests(base):
    print("[identity + continuation]")
    env = {"DUMPTRUCK_HOME": os.path.join(base, "dthome")}
    src = os.path.join(base, "URSA_SSD")
    d1, d2 = os.path.join(base, "X9"), os.path.join(base, "BACKUP")
    os.makedirs(d1), os.makedirs(d2)
    touch(src, "A001_08191412_C001.braw", 512 * 1024)
    touch(src, "A001_08191412_C001.sidecar", 64)

    code, out = cli(env, "offload", src, d1, d2)
    check("first offload uses BRAW reel as label", code == 0 and "New Blackmagic RAW card (reel A001) -> 'A001'" in out, out[:200])
    check("card folder named by reel", os.path.isdir(os.path.join(d1, "A001")))

    touch(src, "A001_08201017_C002.braw", 256 * 1024)
    code, out = cli(env, "offload", src, d1, d2)
    check("re-insert recognized", code == 0 and "seen 1x" in out and "Continuing into existing card folder" in out, out[:300])
    check("continuation copied only the new clip", "C002.braw" in out and "== A001_08191412_C001.braw" in out, out[:400])

    code, out = cli(env, "cards")
    check("cards registry lists A001", "A001" in out and "Blackmagic RAW" in out, out[:200])

    # A DIFFERENT card whose label would collide with A001's folder
    src2 = os.path.join(base, "OTHER_CARD")
    touch(src2, "A001_09010900_C001.braw", 128 * 1024)  # also reel A001!
    code, out = cli(env, "offload", src2, d1, d2)
    check("different card, same reel name -> REFUSED", code == 2 and "REFUSED" in out, out[:300])
    code, out = cli(env, "offload", src2, d1, d2, "--label", "A001_CAM2")
    check("distinct label accepted", code == 0, out[:200])
    # The rename above is remembered, so forcing the collision needs the
    # name spelled out again.
    code, out = cli(env, "offload", src2, d1, d2, "--label", "A001", "--force-label")
    check("--force-label overrides (operator's call)", code in (0, 1), out[:200])
    check("--force-label says the two cards now share the folder",
          "now share that folder" in out, out[:400])

    # A remembered name is not a collision unless the other card's footage
    # is actually at these destinations (Joshua 2026-09-21: a blank or
    # missing card folder blocked a real A001 because a test run had used
    # the name weeks earlier on another drive). OTHER_CARD forced A001
    # above, so it owns the name now; fresh drives hold none of its files.
    d3, d4 = os.path.join(base, "FRESH_A"), os.path.join(base, "FRESH_B")
    os.makedirs(d3), os.makedirs(d4)
    src4 = os.path.join(base, "THIRD_CARD")
    touch(src4, "A001_09210900_C001.braw", 128 * 1024)  # reel A001 again
    code, out = cli(env, "offload", src4, d3, d4)
    check("remembered name with no footage at these destinations is accepted",
          code == 0 and "card name" not in out, out[:400])
    check("card folder created on the fresh drives", os.path.isdir(os.path.join(d3, "A001")))
    touch(src4, "A001_09210930_C002.braw", 64 * 1024)
    code, out = cli(env, "offload", src4, d3, d4)
    check("new owner continues on re-insert into its own folder",
          code == 0 and "Continuing into existing card folder" in out, out[:400])
    # Codex review 2026-09-21, P1: the name passing to THIRD_CARD on the
    # fresh drives must not open the other cards' A001 folder on the first
    # drives. Ownership is per folder, not per name.
    code, out = cli(env, "offload", src4, d1, d2)
    check("new owner of the name is still refused at the folder another card wrote",
          code == 2 and "REFUSED" in out and os.path.join(d1, "A001") in out, out[:400])
    code, out = cli(env, "offload", src, d1, d2)
    check("the original card still continues into its own folder",
          code == 0 and "Continuing into existing card folder" in out, out[:400])

    # An EMPTY card folder is blank too: nothing to invade.
    d5 = os.path.join(base, "FRESH_C")
    os.makedirs(os.path.join(d5, "A001"))
    src5 = os.path.join(base, "FOURTH_CARD")
    touch(src5, "A001_09211000_C001.braw", 128 * 1024)
    code, out = cli(env, "offload", src5, d5)
    check("empty card folder does not block", code == 0 and "REFUSED" not in out, out[:400])

    # A folder that holds another card's files still refuses.
    src6 = os.path.join(base, "FIFTH_CARD")
    touch(src6, "A001_09211100_C001.braw", 128 * 1024)
    code, out = cli(env, "offload", src6, d5)
    check("occupied card folder still refuses", code == 2 and "REFUSED" in out
          and "footage is in" in out, out[:400])
    check("refusal names the occupied folder", os.path.join(d5, "A001") in out, out[:400])
    code, out = cli(env, "offload", src6, d5, "--label", "A001_CAM3")
    check("distinct label still accepted", code == 0, out[:200])

    # Label memory: rename once, remembered next time
    src3 = os.path.join(base, "GOPRO_CARD")
    touch(src3, "DCIM/100GOPRO/GX010001.MP4", 128 * 1024)
    cli(env, "offload", src3, d1, "--label", "GOPRO_ROOF")
    touch(src3, "DCIM/100GOPRO/GX010002.MP4", 64 * 1024)
    code, out = cli(env, "offload", src3, d1)
    check("renamed label remembered on re-insert", code == 0 and "'GOPRO_ROOF'" in out, out[:300])


def main():
    base = os.path.realpath(tempfile.mkdtemp(prefix="dumptruck-cards-"))
    print(f"arena: {base}\n")
    detection_tests(base)
    identity_tests(base)
    print(f"\n{'='*50}\n{len(PASS)} passed, {len(FAIL)} failed")
    if FAIL:
        print("FAILED:", *FAIL, sep="\n  - ")
    shutil.rmtree(base, ignore_errors=True)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
