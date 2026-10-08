"""Media metadata + thumbnails for reports. STRICTLY non-authoritative:
any failure here degrades the report, never the verified-copy state.

Probing runs against the FIRST VERIFIED DESTINATION, never the source card
(reports must not extend card occupancy). Vendor RAW handlers are selected by
extension. Ordinary media stays on ffprobe/ffmpeg.
"""

import base64
import glob
import json
import os
import shutil
import subprocess
import tempfile

MEDIA_EXTS = {
    ".mov", ".mp4", ".mxf", ".mts", ".m2ts", ".avi", ".mkv", ".braw", ".r3d",
    ".ari", ".arx", ".arri", ".crm", ".nev", ".krw", ".insv", ".insp",
    ".wav", ".bwf", ".aif", ".aiff", ".mp3", ".m4a", ".flac",
}
VIDEO_THUMB_POSITIONS = (0.02, 0.5, 0.98)  # slate mode swaps the first for 0.0
BRAW_PROBE = os.path.abspath(os.path.join(
    os.path.dirname(__file__), os.pardir, "tools", "braw-probe"))
R3D_PROBE = os.path.abspath(os.path.join(
    os.path.dirname(__file__), os.pardir, "tools", "r3d-probe"))
# ARRI Image SDK helper (Partner Program build). Preferred over the separately
# installed Reference Tool when it is present and works; the Reference Tool
# stays as the fallback until the SDK build is approved for release.
ARRI_PROBE = os.path.abspath(os.path.join(
    os.path.dirname(__file__), os.pardir, "tools", "arri-probe"))


def camera_helpers_enabled():
    """False when the operator declined the camera component terms.

    The app sets DUMPTRUCK_CAMERA_HELPERS=0 until those terms are accepted.
    That switches off only the bundled RED, Blackmagic and ARRI helpers;
    REDline and the ARRI Reference Tool are the operator's own licensed
    installs and stay usable.
    """
    return os.environ.get("DUMPTRUCK_CAMERA_HELPERS", "1") != "0"


REDLINE_PROBE = ("/Applications/REDCINE-X Professional/REDCINE-X PRO.app/"
                 "Contents/MacOS/REDline")
ART_CMD_CANDIDATES = (
    "/Applications/ARRI Reference Tool/bin/art-cmd",
    "/Applications/ARRI Reference Tool.app/Contents/MacOS/art-cmd",
    "/usr/local/bin/art-cmd",
    "/opt/homebrew/bin/art-cmd",
    # Last resort only: a downloaded copy must never shadow a real install.
    os.path.expanduser(
        "~/Downloads/art-cmd_1.0.0_macos_universal/bin/art-cmd"),
)
SIPS = "/usr/bin/sips"


def _run(cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, timeout=timeout)


def _finite_float(value, default=0.0):
    try:
        number = float(value)
        return (number if number == number
                and number not in (float("inf"), float("-inf")) else default)
    except (TypeError, ValueError):
        return default


def probe(path):
    """ffprobe -> compact dict, or None on any failure."""
    if os.path.splitext(path)[1].lower() not in MEDIA_EXTS:
        return None
    try:
        r = _run(["ffprobe", "-v", "quiet", "-print_format", "json",
                  "-show_format", "-show_streams", path], timeout=30)
        if r.returncode != 0:
            return None
        data = json.loads(r.stdout.decode("utf-8", "replace"))
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return None

    fmt = data.get("format", {})
    out = {
        "duration_s": _finite_float(fmt.get("duration")),
        "container": fmt.get("format_name", ""),
        "timecode": (fmt.get("tags") or {}).get("timecode"),
        "video": None,
        "audio": None,
    }
    for s in data.get("streams", []):
        if s.get("codec_type") == "video" and out["video"] is None:
            num, _, den = (s.get("r_frame_rate") or "0/1").partition("/")
            try:
                fps = float(num) / float(den or 1)
            except (TypeError, ValueError, ZeroDivisionError):
                fps = 0.0
            out["video"] = {
                "codec": s.get("codec_name") or "?",
                "width": s.get("width", 0),
                "height": s.get("height", 0),
                "fps": round(fps, 3),
            }
            out["timecode"] = out["timecode"] or (s.get("tags") or {}).get("timecode")
        elif s.get("codec_type") == "audio" and out["audio"] is None:
            out["audio"] = {
                "codec": s.get("codec_name", "?"),
                "channels": s.get("channels", 0),
                "sample_rate": s.get("sample_rate", ""),
                "bits": s.get("bits_per_raw_sample") or s.get("bits_per_sample") or "",
            }
    return out


def thumbnails(path, duration_s, count=3, width=320, slate_first=False):
    """[(position_label, jpeg_base64), ...] — best effort, empty on failure."""
    if not duration_s or duration_s <= 0:
        positions = [0.0]
    else:
        positions = list(VIDEO_THUMB_POSITIONS[:count])
        if slate_first:
            positions[0] = 0.0
    thumbs = []
    for pos in positions:
        t = max(0.0, (duration_s or 0) * pos)
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
            tmp = tf.name
        try:
            r = _run(["ffmpeg", "-v", "quiet", "-ss", f"{t:.3f}", "-i", path,
                      "-frames:v", "1", "-vf", f"scale={width}:-2", "-q:v", "6",
                      "-y", tmp], timeout=45)
            if r.returncode == 0 and os.path.getsize(tmp) > 0:
                with open(tmp, "rb") as f:
                    thumbs.append((f"{int(pos * 100)}%", base64.b64encode(f.read()).decode()))
        except (subprocess.SubprocessError, OSError):
            pass
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
    return thumbs


def probe_braw(path):
    """Return one SDK-decoded thumbnail and BRAW metadata, or an error.

    This result is report decoration only. Callers must never turn a helper
    failure into a copy, verification, attestation, or process failure.
    """
    if not camera_helpers_enabled():
        return None, "camera component terms not accepted"
    if not os.path.isfile(BRAW_PROBE) or not os.access(BRAW_PROBE, os.X_OK):
        return None, "BRAW helper is not built or executable"

    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
        tmp = tf.name
    try:
        r = _run([BRAW_PROBE, path, tmp], timeout=120)
        if r.returncode != 0:
            reason = r.stderr.decode("utf-8", "replace").strip()
            return None, (reason[:500] or
                          f"BRAW helper exited with status {r.returncode}")
        try:
            metadata = json.loads(r.stdout.decode("utf-8", "strict"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            return None, f"BRAW helper returned invalid metadata JSON: {exc}"
        if not isinstance(metadata, dict):
            return None, "BRAW helper metadata JSON is not an object"
        resolution = metadata.get("resolution")
        if (not isinstance(resolution, dict)
                or not isinstance(resolution.get("width"), int)
                or not isinstance(resolution.get("height"), int)
                or resolution["width"] <= 0 or resolution["height"] <= 0
                or not isinstance(metadata.get("fps"), (int, float))
                or metadata["fps"] <= 0):
            return None, "BRAW helper returned incomplete metadata"
        try:
            jpeg = _read_jpeg(tmp)
        except (OSError, ValueError):
            return None, "BRAW helper did not write a valid JPEG"

        compression = metadata.get("compression_ratio")
        codec = metadata.get("codec") or "Blackmagic RAW"
        if compression:
            codec = f"{codec} {compression}"
        info = {
            "duration_s": metadata.get("duration_s") or 0.0,
            "container": "braw",
            "timecode": metadata.get("start_timecode"),
            "video": {
                "codec": codec,
                "width": resolution["width"],
                "height": resolution["height"],
                "fps": round(float(metadata["fps"]), 3),
            },
            "audio": None,
            "braw": metadata,
        }
        return {
            "probe": info,
            "thumbs": [("50%", base64.b64encode(jpeg).decode("ascii"))],
        }, None
    except (subprocess.SubprocessError, OSError) as exc:
        return None, f"BRAW helper failed: {exc}"
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def probe_r3d_sdk(path, want_thumbnail=True):
    """Return metadata and one frame from the native RED R3D SDK helper."""
    if not camera_helpers_enabled():
        return None, "camera component terms not accepted"
    if not os.path.isfile(R3D_PROBE) or not os.access(R3D_PROBE, os.X_OK):
        return None, "native R3D helper is not built or executable"

    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
        tmp = tf.name
    try:
        r = _run([R3D_PROBE, path, tmp], timeout=120)
        if r.returncode != 0:
            reason = r.stderr.decode("utf-8", "replace").strip()
            return None, (reason[:500] or
                          f"native R3D helper exited with status {r.returncode}")
        try:
            metadata = json.loads(r.stdout.decode("utf-8", "strict"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            return None, f"native R3D helper returned invalid metadata JSON: {exc}"
        if not isinstance(metadata, dict):
            return None, "native R3D helper metadata JSON is not an object"
        resolution = metadata.get("resolution")
        if (not isinstance(resolution, dict)
                or not isinstance(resolution.get("width"), int)
                or not isinstance(resolution.get("height"), int)
                or resolution["width"] <= 0 or resolution["height"] <= 0
                or not isinstance(metadata.get("fps"), (int, float))
                or metadata["fps"] <= 0):
            return None, "native R3D helper returned incomplete metadata"
        jpeg = _read_jpeg(tmp)

        codec = metadata.get("codec") or "REDCODE RAW"
        compression = metadata.get("compression")
        if compression:
            codec = f"{codec} {compression}"
        audio = metadata.get("audio")
        channels = int(_finite_float(
            audio.get("channels") if isinstance(audio, dict) else 0))
        info = {
            "duration_s": _finite_float(metadata.get("duration_s")),
            "container": "r3d",
            "timecode": metadata.get("start_timecode"),
            "video": {
                "codec": codec,
                "width": resolution["width"],
                "height": resolution["height"],
                "fps": round(float(metadata["fps"]), 3),
            },
            "audio": ({
                "codec": "PCM",
                "channels": channels,
                "sample_rate": audio.get("sample_rate", ""),
                "bits": audio.get("bits", ""),
            } if channels > 0 else None),
            "r3d": metadata,
            "probe_backend": "r3d-sdk",
        }
        return {
            "probe": info,
            "thumbs": ([('50%', base64.b64encode(jpeg).decode("ascii"))]
                       if want_thumbnail else []),
        }, None
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, f"native R3D helper failed: {exc}"
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _command_reason(result, tool):
    text = (result.stderr + b"\n" + result.stdout).decode(
        "utf-8", "replace").strip()
    if text:
        return text[-500:]
    return f"{tool} exited with status {result.returncode}"


def _read_jpeg(path):
    with open(path, "rb") as f:
        jpeg = f.read()
    if len(jpeg) < 4 or not jpeg.startswith(b"\xff\xd8"):
        raise ValueError("output is not a JPEG")
    return jpeg


def _parse_redline_metadata(raw):
    metadata = {}
    for line in raw.decode("utf-8", "replace").splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() and value.strip():
            metadata[key.strip()] = value.strip()
    return metadata


def probe_redline(path, want_thumbnail=True):
    """Return REDline metadata and one decoded JPEG, or an honest error."""
    if not os.path.isfile(REDLINE_PROBE) or not os.access(REDLINE_PROBE, os.X_OK):
        return None, "install REDCINE-X PRO to analyze R3D media"
    try:
        meta_result = _run(
            [REDLINE_PROBE, "--i", path, "--printMeta", "1"], timeout=60)
        metadata = _parse_redline_metadata(meta_result.stdout)
        width = int(_finite_float(metadata.get("Frame Width")))
        height = int(_finite_float(metadata.get("Frame Height")))
        fps = _finite_float(metadata.get("FPS"))
        total_frames = int(_finite_float(metadata.get("Total Frames")))
        if width <= 0 or height <= 0 or fps <= 0 or total_frames <= 0:
            return None, "REDline could not read clip metadata: " + _command_reason(
                meta_result, "REDline")

        audio_channels = int(_finite_float(metadata.get("Camera Audio Channels")))
        info = {
            "duration_s": total_frames / fps,
            "container": "r3d",
            "timecode": metadata.get("Abs TC") or metadata.get("Edge TC"),
            "video": {
                "codec": metadata.get("Codec") or "REDCODE RAW",
                "width": width,
                "height": height,
                "fps": round(fps, 3),
            },
            "audio": ({
                "codec": "PCM",
                "channels": audio_channels,
                "sample_rate": metadata.get("Audio Sample Rate", ""),
                "bits": metadata.get("Audio Bit Depth", ""),
            } if audio_channels > 0 else None),
            "redline": metadata,
        }
        if not want_thumbnail:
            return {"probe": info, "thumbs": []}, None

        with tempfile.TemporaryDirectory(prefix="dumptruck-redline-") as tmpdir:
            target_width = min(960, width)
            target_height = max(2, round(height * target_width / width))
            target_height -= target_height % 2
            frame = max(0, total_frames // 2)
            render = _run([
                REDLINE_PROBE, "--i", path, "--outDir", tmpdir, "--o", "thumb",
                "--format", "3", "--start", str(frame), "--frameCount", "1",
                "--resizeX", str(target_width), "--resizeY", str(target_height),
                "--fit", "3", "--useMeta",
            ], timeout=180)
            candidates = sorted(glob.glob(os.path.join(tmpdir, "thumb*.jpg")))
            if render.returncode != 0 or not candidates:
                return None, "REDline thumbnail export failed: " + _command_reason(
                    render, "REDline")
            jpeg = _read_jpeg(candidates[0])
        return {
            "probe": info,
            "thumbs": [("50%", base64.b64encode(jpeg).decode("ascii"))],
        }, None
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, f"REDline probe failed: {exc}"


def probe_r3d(path, want_thumbnail=True):
    """Try native R3D SDK, then REDline, preserving each fallback reason."""
    fallbacks = []
    entry, error = probe_r3d_sdk(path, want_thumbnail=want_thumbnail)
    if entry is not None:
        return entry, None
    fallbacks.append({"backend": "r3d-sdk", "reason": error})

    entry, error = probe_redline(path, want_thumbnail=want_thumbnail)
    if entry is not None:
        entry["probe"]["probe_backend"] = "redline"
        entry["probe"]["probe_fallbacks"] = fallbacks
        return entry, None
    fallbacks.append({"backend": "redline", "reason": error})
    reason = "; ".join(
        f"{item['backend']}: {item['reason']}" for item in fallbacks)
    return None, reason


def _find_art_cmd():
    configured = [p for p in os.environ.get(
        "DUMPTRUCK_ART_CMD_PATHS", "").split(os.pathsep) if p]
    path_hit = shutil.which("art-cmd")
    candidates = configured + list(ART_CMD_CANDIDATES)
    if path_hit:
        candidates.append(path_hit)
    for candidate in candidates:
        expanded = os.path.abspath(os.path.expanduser(candidate))
        if os.path.isfile(expanded) and os.access(expanded, os.X_OK):
            return expanded
    return None


def _art_metadata_sets(metadata):
    return {
        item.get("metadataSetName"): item.get("metadataSetPayload") or {}
        for item in metadata.get("clipBasedMetadataSets", [])
        if isinstance(item, dict) and isinstance(item.get("metadataSetName"), str)
    }


def _ratio(value):
    numerator, separator, denominator = str(value or "").partition("/")
    if not separator:
        return _finite_float(value)
    den = _finite_float(denominator)
    return _finite_float(numerator) / den if den else 0.0


def probe_art(path, fallback_info=None, want_thumbnail=True):
    """Return ARRI Reference Tool metadata and one decoded JPEG, or an error."""
    art_cmd = _find_art_cmd()
    if not art_cmd:
        return None, "install ARRI Reference Tool to analyze ARRIRAW/HDE media"
    try:
        with tempfile.TemporaryDirectory(prefix="dumptruck-art-") as tmpdir:
            metadata_path = os.path.join(tmpdir, "metadata.json")
            exported = _run([
                art_cmd, "export", "--input", path, "--duration", "1",
                "--output", metadata_path, "--skip-audio", "--skip-look",
                "--logpath", "",
            ], timeout=120)
            if exported.returncode != 0 or not os.path.isfile(metadata_path):
                return None, "ARRI metadata export failed: " + _command_reason(
                    exported, "art-cmd")
            with open(metadata_path, "r", encoding="utf-8") as f:
                metadata = json.load(f)
            if not isinstance(metadata, dict):
                return None, "ARRI Reference Tool metadata JSON is not an object"

            sets = _art_metadata_sets(metadata)
            clip = sets.get("Clip Info", {})
            image_size = sets.get("Image Size", {})
            project_rate = sets.get("Project Rate", {})
            audio_meta = sets.get("Audio", {})
            stored = image_size.get("storedSize") or image_size.get("displayRect") or {}
            width = int(_finite_float(stored.get("width")))
            height = int(_finite_float(stored.get("height")))
            fps = _ratio(project_rate.get("timebase"))
            if width <= 0 or height <= 0 or fps <= 0:
                return None, "ARRI Reference Tool returned incomplete clip metadata"
            duration = _finite_float((fallback_info or {}).get("duration_s"))
            if duration <= 0:
                # The metadata export is range-limited to one frame, so its
                # clipDuration reports the EXPORT range, not the clip. A bare
                # .ari really is a single frame, so 1/fps is the truth there;
                # for any multi-frame container with no ffmpeg fallback the
                # duration is unknown — show nothing rather than a wrong
                # number (a report may never display fabricated evidence).
                if path.lower().endswith(".ari"):
                    duration = 1.0 / fps
                else:
                    duration = 0.0
            frames = (metadata.get("frameBasedMetadata") or {}).get("frames") or []
            timecode = frames[0].get("timecode") if frames else None
            audio_channels = int(_finite_float(audio_meta.get("audioChannels")))
            info = {
                "duration_s": duration,
                "container": "arriraw",
                "timecode": timecode or (fallback_info or {}).get("timecode"),
                "video": {
                    "codec": clip.get("videoCodec") or "ARRIRAW",
                    "width": width,
                    "height": height,
                    "fps": round(fps, 3),
                },
                "audio": ({
                    "codec": audio_meta.get("audioCodec") or "PCM",
                    "channels": audio_channels,
                    "sample_rate": audio_meta.get("audioSampleRate", ""),
                    "bits": audio_meta.get("audioBitDepth", ""),
                } if audio_channels > 0 else (fallback_info or {}).get("audio")),
                "arri": metadata,
            }
            if not want_thumbnail:
                return {"probe": info, "thumbs": []}, None

            tiff_pattern = os.path.join(tmpdir, "frame.%07d.tif")
            rendered = _run([
                art_cmd, "process", "--input", path, "--start", "0",
                "--duration", "1", "--target-colorspace",
                "Rec.709/D65/BT.1886", "--output-width", "960",
                "--output", tiff_pattern, "--logpath", "",
            ], timeout=180)
            tiffs = sorted(glob.glob(os.path.join(tmpdir, "frame.*.tif")))
            if rendered.returncode != 0 or not tiffs:
                return None, "ARRI thumbnail decode failed: " + _command_reason(
                    rendered, "art-cmd")
            if not os.path.isfile(SIPS) or not os.access(SIPS, os.X_OK):
                return None, "ARRI thumbnail conversion failed: macOS sips is unavailable"
            jpeg_path = os.path.join(tmpdir, "frame.jpg")
            converted = _run(
                [SIPS, "-s", "format", "jpeg", tiffs[0], "--out", jpeg_path],
                timeout=60)
            if converted.returncode != 0 or not os.path.isfile(jpeg_path):
                return None, "ARRI thumbnail conversion failed: " + _command_reason(
                    converted, "sips")
            jpeg = _read_jpeg(jpeg_path)
        return {
            "probe": info,
            "thumbs": [("0%", base64.b64encode(jpeg).decode("ascii"))],
        }, None
    except (json.JSONDecodeError, OSError, ValueError,
            subprocess.SubprocessError) as exc:
        return None, f"ARRI Reference Tool probe failed: {exc}"


def _braw_handler(path, _fallback, want_thumbnail):
    if not want_thumbnail:
        return ({
            "probe": {
                "duration_s": 0.0, "container": "braw",
                "timecode": None, "video": None, "audio": None,
            },
            "thumbs": [],
        }, None)
    return probe_braw(path)


def _r3d_handler(path, _fallback, want_thumbnail):
    return probe_r3d(path, want_thumbnail=want_thumbnail)


def probe_arri_sdk(path, fallback_info=None, want_thumbnail=True):
    """Return ARRI Image SDK metadata and one Rec.709 JPEG from the native
    helper, or an error. Report decoration only, never a copy verdict."""
    if not camera_helpers_enabled():
        return None, "camera component terms not accepted"
    if not os.path.isfile(ARRI_PROBE) or not os.access(ARRI_PROBE, os.X_OK):
        return None, "ARRI SDK helper is not built or executable"
    tmp = None
    try:
        if want_thumbnail:
            with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
                tmp = tf.name
        r = _run([ARRI_PROBE, path, tmp or "-"], timeout=180)
        if r.returncode != 0:
            reason = r.stderr.decode("utf-8", "replace").strip()
            return None, (reason[:500] or
                          f"ARRI SDK helper exited with status {r.returncode}")
        try:
            metadata = json.loads(r.stdout.decode("utf-8", "strict"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            return None, f"ARRI SDK helper returned invalid metadata JSON: {exc}"
        if not isinstance(metadata, dict):
            return None, "ARRI SDK helper metadata JSON is not an object"
        resolution = metadata.get("resolution")
        if (not isinstance(resolution, dict)
                or not isinstance(resolution.get("width"), int)
                or not isinstance(resolution.get("height"), int)
                or resolution["width"] <= 0 or resolution["height"] <= 0):
            return None, "ARRI SDK helper returned incomplete metadata"
        fps = _finite_float(metadata.get("fps"))
        if fps <= 0:
            fps = _finite_float((fallback_info or {}).get("video", {}).get("fps")
                                if isinstance((fallback_info or {}).get("video"), dict) else 0)
        duration = _finite_float(metadata.get("duration_s"))
        if duration <= 0:
            duration = _finite_float((fallback_info or {}).get("duration_s"))
        info = {
            "duration_s": duration,
            "container": "arriraw" if metadata.get("container") == "mxf" else "ari",
            "timecode": metadata.get("start_timecode") or (fallback_info or {}).get("timecode"),
            "video": {
                "codec": metadata.get("codec") or "ARRIRAW",
                "width": resolution["width"],
                "height": resolution["height"],
                "fps": round(fps, 3) if fps > 0 else 0.0,
            },
            "audio": (fallback_info or {}).get("audio"),
            "arri": metadata,
        }
        if not want_thumbnail:
            return {"probe": info, "thumbs": []}, None
        try:
            jpeg = _read_jpeg(tmp)
        except (OSError, ValueError):
            return None, "ARRI SDK helper did not write a valid JPEG"
        return {
            "probe": info,
            "thumbs": [("50%", base64.b64encode(jpeg).decode("ascii"))],
        }, None
    except (subprocess.SubprocessError, OSError) as exc:
        return None, f"ARRI SDK helper failed: {exc}"
    finally:
        if tmp:
            try:
                os.remove(tmp)
            except OSError:
                pass


def probe_arri(path, fallback_info=None, want_thumbnail=True):
    """SDK helper first, Reference Tool second. Both errors are reported when
    neither works so the report says exactly what was tried."""
    entry, sdk_error = probe_arri_sdk(path, fallback_info=fallback_info,
                                      want_thumbnail=want_thumbnail)
    if entry is not None:
        return entry, None
    entry, art_error = probe_art(path, fallback_info=fallback_info,
                                 want_thumbnail=want_thumbnail)
    if entry is not None:
        return entry, None
    return None, f"{art_error}; SDK helper: {sdk_error}"


def _art_handler(path, fallback, want_thumbnail):
    return probe_arri(path, fallback_info=fallback, want_thumbnail=want_thumbnail)


PROBE_REGISTRY = {
    ".braw": _braw_handler,
    ".r3d": _r3d_handler,
    ".ari": _art_handler,
    ".arx": _art_handler,
    ".arri": _art_handler,
}


def _placeholder_probe(extension, fallback=None):
    fallback = fallback or {}
    return {
        "duration_s": fallback.get("duration_s", 0.0),
        "container": fallback.get("container") or extension.lstrip("."),
        "timecode": fallback.get("timecode"),
        "video": fallback.get("video"),
        "audio": fallback.get("audio"),
    }


def _needs_art_mxf(info):
    if not info or not info.get("video"):
        return False
    video = info["video"]
    return (str(video.get("codec") or "").lower() in ("", "?", "none", "unknown")
            or int(video.get("width") or 0) <= 0
            or int(video.get("height") or 0) <= 0)


def analyze_card(card_root, rel_paths, thumbs=True, slate_first=False, event=None):
    """Probe every media file (by rel path) under card_root.
    Returns {rel: {"probe":..., "thumbs":[...]}} — failures simply absent."""
    ev = event or (lambda d: None)
    out = {}
    for i, rel in enumerate(rel_paths):
        full = os.path.join(card_root, rel)
        extension = os.path.splitext(full)[1].lower()
        handler = PROBE_REGISTRY.get(extension)
        if handler:
            entry, error = handler(full, None, thumbs)
            if entry is None:
                entry = {
                    "probe": _placeholder_probe(extension),
                    "thumbs": [],
                    "thumbnail_unavailable": error,
                }
            out[rel] = entry
            ev({"event": "media_analyzed", "path": rel,
                "n": i + 1, "of": len(rel_paths)})
            continue
        info = probe(full)
        if info is None:
            # The file was copied and verified; omitting its row entirely
            # would hide that from the report. Same honesty as RAW failures.
            out[rel] = {
                "probe": _placeholder_probe(extension),
                "thumbs": [],
                "thumbnail_unavailable": "ffprobe could not read this file",
            }
            ev({"event": "media_analyzed", "path": rel,
                "n": i + 1, "of": len(rel_paths)})
            continue
        if extension == ".mxf" and _needs_art_mxf(info):
            entry, error = probe_arri(full, fallback_info=info,
                                      want_thumbnail=thumbs)
            if entry is None:
                entry = {
                    "probe": _placeholder_probe(extension, info),
                    "thumbs": [],
                    "thumbnail_unavailable": error,
                }
            out[rel] = entry
            ev({"event": "media_analyzed", "path": rel,
                "n": i + 1, "of": len(rel_paths)})
            continue
        entry = {"probe": info, "thumbs": []}
        if thumbs and info.get("video"):
            entry["thumbs"] = thumbnails(full, info["duration_s"], slate_first=slate_first)
        out[rel] = entry
        ev({"event": "media_analyzed", "path": rel, "n": i + 1, "of": len(rel_paths)})
    return out
