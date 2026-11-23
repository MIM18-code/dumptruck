"""dumptruck-ctl: drive the running Dumptruck app from a shell or an agent.

    dumptruck-ctl status [--all]
    dumptruck-ctl stage SOURCE [--label NAME]      volume name or absolute path
    dumptruck-ctl label NAME
    dumptruck-ctl reread | unstage
    dumptruck-ctl add-dest PATH | remove-dest PATH | clear-dests
    dumptruck-ctl mirror FOLDER | clear-mirror     /Volumes/X9/Raws, X9/Raws, or a folder in the staged drive
    dumptruck-ctl start [--wait SECONDS] [--verify fast|full]
    dumptruck-ctl job JOB | wait JOB [--timeout SECONDS] [--accept-copied]
    dumptruck-ctl pause JOB | resume JOB
    dumptruck-ctl stop JOB --confirm
    dumptruck-ctl retry JOB [--settings current|saved]
    dumptruck-ctl eject-check VOLUME
    dumptruck-ctl eject VOLUME [--confirm | --force]
    dumptruck-ctl raw '{"command": "status"}'

Every command goes through the same app code as the button it stands for,
so jobs started here show in the window, Job History and the verdicts, and
a refusal prints the reason the window would show. JOB is a job id (or its
first 8+ characters) or a card label.

Exit codes: 0 done, 1 refused (the reason is printed), 2 usage, 3 the app is
not answering, 4 `wait` timed out, 5 `wait` ended on a clean COPIED · NOT
VERIFIED (Fast mode; `--accept-copied` makes that 0). `--json` prints the
app's reply as is.

The socket: --socket, else $DUMPTRUCK_CONTROL_SOCKET, else
$DUMPTRUCK_HOME/control.sock, else
~/Library/Application Support/Dumptruck/control.sock. Standard library only,
so any python3 runs it.
"""

import argparse
import json
import os
import socket
import sys
import time

EXIT_OK, EXIT_REFUSED, EXIT_USAGE, EXIT_UNREACHABLE, EXIT_TIMEOUT, EXIT_COPIED = 0, 1, 2, 3, 4, 5


def default_socket_path(env=None):
    env = os.environ if env is None else env
    if env.get("DUMPTRUCK_CONTROL_SOCKET"):
        return env["DUMPTRUCK_CONTROL_SOCKET"]
    if env.get("DUMPTRUCK_HOME"):
        return os.path.join(env["DUMPTRUCK_HOME"], "control.sock")
    return os.path.expanduser("~/Library/Application Support/Dumptruck/control.sock")


class Unreachable(Exception):
    pass


def request(path, payload, timeout=90.0):
    """Send one request, return the reply as a dict."""
    data = (json.dumps(payload) + "\n").encode("utf-8")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        try:
            sock.connect(path)
        except (FileNotFoundError, ConnectionRefusedError) as exc:
            raise Unreachable(
                f"Dumptruck is not answering on {path} ({exc.strerror}). "
                "Is the app running? A QA copy listens under its DUMPTRUCK_HOME.") from exc
        sock.sendall(data)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if chunk.endswith(b"\n"):
                break
    except socket.timeout as exc:
        raise Unreachable(f"Dumptruck did not answer within {timeout:g} seconds.") from exc
    except (BrokenPipeError, ConnectionResetError) as exc:
        raise Unreachable("Dumptruck closed the connection before answering.") from exc
    finally:
        sock.close()
    raw = b"".join(chunks).strip()
    if not raw:
        raise Unreachable("Dumptruck closed the connection without answering.")
    return json.loads(raw.decode("utf-8"))


def path_arg(value):
    """Paths are resolved here, against the caller's directory; a bare word
    is a volume name ("B001") and goes to the app as is."""
    if value.startswith("~"):
        return os.path.expanduser(value)
    if value.startswith("/"):
        return value
    if "/" in value or value.startswith("."):
        return os.path.abspath(value)
    return value


def mirror_arg(value):
    """A mirrored folder: absolute and ~ paths as usual, ./ and ../ against
    the caller's directory, and anything else as typed. The app reads
    "X9/Raws/11232026" as a folder on the drive named X9, or
    "Raws/11232026" as a folder inside the one staged destination drive."""
    if value.startswith("~"):
        return os.path.expanduser(value)
    if value.startswith("/"):
        return value
    if value.startswith("./") or value.startswith("../") or value in (".", ".."):
        return os.path.abspath(value)
    return value


# ---------------------------------------------------------------- printing

def _size(n):
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000.0
    return str(n)


def job_line(job):
    head = f"{job['label']}  [{job['id'][:8]}]  "
    if job.get("running"):
        pct = int(round(100 * job.get("progress", 0)))
        line = (f"{head}{job['activity']}  {pct}%  "
                f"{_size(job.get('bytesDone'))} of {_size(job.get('bytesTotal'))}")
        speed = job.get("bytesPerSecond")
        if speed:
            line += f"  {_size(speed)}/s"
    else:
        line = head + job["verdictLine"]
        if job.get("verdictCurrent") is False:
            line += "  (no longer current)"
    if job.get("verifyMode") == "fast":
        line += "  [fast: size check only]"
    lanes = job.get("perDestination") or []
    if lanes:
        parts = []
        for lane in lanes:
            text = f"{lane['root']}: {lane['filesVerified']} verified"
            if lane.get("sizeOnly"):
                text += f", {lane['sizeOnly']} size-checked"
            if lane.get("filesTrusted"):
                text += f", {lane['filesTrusted']} trusted"
            if lane.get("filesFailed"):
                text += f", {lane['filesFailed']} FAILED"
            parts.append(text)
        line += "\n      " + "\n      ".join(parts)
    if job.get("retryRefusal"):
        line += f"\n      retry refused: {job['retryRefusal']}"
    return line


def print_status(state, show_all):
    app = state["app"]
    print(f"Dumptruck {app.get('version', '?')} (pid {app.get('pid')}, {app.get('bundleID')})")
    for key, label in (("journalError", "journal"), ("engineError", "engine"),
                       ("lastSetupError", "last refusal"), ("lastEjectError", "eject")):
        if app.get(key):
            print(f"  {label}: {app[key]}")
    print("\nVolumes")
    for vol in state["volumes"]:
        role = f"  <{vol['role']}>" if vol.get("role") else ""
        eject = vol["eject"]
        if not eject.get("offered"):
            ej = "no eject"
        elif eject.get("oneClick"):
            ej = "ejects on one click"
        else:
            hold = eject.get("hold") or {}
            needs = hold.get("needs")
            ej = f"eject asks first: {hold.get('summary', '')}" + (f"; needs --{needs}" if needs else "")
        print(f"  {vol['name']}  {vol['path']}  {_size(vol.get('freeBytes'))} free{role}  ({ej})")
    bench = state["bench"]
    print("\nBench")
    print(f"  source: {bench.get('source', '-')}")
    print(f"  card name: {bench.get('label') or '-'}")
    dests = bench.get("destinations") or []
    print(f"  destinations: {', '.join(dests) if dests else '-'}")
    if bench.get("mirrorFolder"):
        print(f"  mirrored folder: {bench['mirrorFolder']}")
    print_card_folders(bench)
    if bench.get("stagedRetry"):
        print(f"  staged retry: {bench['stagedRetry']} ({bench.get('retrySettings')} settings)")
    if bench.get("startBlockedReason"):
        print(f"  start: {bench['startBlockedReason']}")
    else:
        print("  start: ready")
    jobs = state["jobs"]
    shown = jobs if show_all else [j for j in jobs if j.get("running")] + \
        [j for j in jobs if not j.get("running")][:10]
    print(f"\nJobs ({len(jobs)})")
    for job in shown:
        print("  " + job_line(job))
    if len(shown) < len(jobs):
        print(f"  … {len(jobs) - len(shown)} older; --all lists them")


def print_card_folders(bench):
    folders = bench.get("cardFolders") or []
    if folders:
        head = "card lands in" if bench.get("cardFoldersResolved") else "card lands in (preview)"
        print(f"  {head}: " + folders[0])
        for folder in folders[1:]:
            print(" " * (len(head) + 4) + folder)
    if bench.get("cardFoldersNote"):
        print(f"  note: {bench['cardFoldersNote']}")


# ---------------------------------------------------------------- commands

def build_parser():
    parser = argparse.ArgumentParser(
        prog="dumptruck-ctl", description="Drive the running Dumptruck app.",
        epilog="Exit codes: 0 done, 1 refused, 2 usage, 3 app not answering, 4 wait timed out, "
        "5 wait ended COPIED · NOT VERIFIED (clean Fast-mode copy).")
    parser.add_argument("--socket", default=None, help="control socket path")
    parser.add_argument("--json", action="store_true", help="print the app's JSON reply")
    parser.add_argument("--timeout", type=float, default=90.0, help="seconds to wait for a reply")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("status", help="volumes, bench, jobs, eject answers")
    p.add_argument("--all", action="store_true", help="list every job, not the last 10")
    p = sub.add_parser("stage", help="stage a source card or folder")
    p.add_argument("source")
    p.add_argument("--label", help="card name")
    p = sub.add_parser("label", help="set the staged card's name")
    p.add_argument("name")
    sub.add_parser("reread", help="re-read the staged card")
    sub.add_parser("unstage", help="remove the staged source")
    p = sub.add_parser("add-dest", help="add a destination drive or folder")
    p.add_argument("path")
    p = sub.add_parser("remove-dest", help="remove a destination")
    p.add_argument("path")
    sub.add_parser("clear-dests", help="remove every destination")
    p = sub.add_parser("mirror", help="mirror this folder to every destination: /Volumes/X9/Raws, "
                       "X9/Raws (drive name first), or Raws (inside the one staged drive)")
    p.add_argument("folder")
    sub.add_parser("clear-mirror", help="copy to the top of each destination")
    p = sub.add_parser("start", help="press Start")
    p.add_argument("--wait", type=float, default=0.0, metavar="SECONDS",
                   help="keep trying while the card is still being read")
    p.add_argument("--verify", choices=["fast", "full"],
                   help="this job only: fast (size check, ends COPIED · NOT VERIFIED) or full; "
                   "the saved Verification setting is not changed")
    p = sub.add_parser("job", help="one job's state")
    p.add_argument("job")
    p = sub.add_parser("wait", help="wait for a job to finish; exit 0 when verified, "
                       "5 on a clean Fast-mode copy")
    p.add_argument("job")
    p.add_argument("--timeout", dest="wait_timeout", type=float, default=0.0,
                   help="give up after SECONDS (default: never)")
    p.add_argument("--interval", type=float, default=2.0)
    p.add_argument("--accept-copied", action="store_true",
                   help="exit 0 on a clean COPIED · NOT VERIFIED (Fast mode) too")
    for name in ("pause", "resume"):
        p = sub.add_parser(name, help=f"{name} a running transfer")
        p.add_argument("job")
    p = sub.add_parser("stop", help="stop a transfer (needs --confirm)")
    p.add_argument("job")
    p.add_argument("--confirm", action="store_true", help="yes, stop it")
    p = sub.add_parser("retry", help="Stage Retry for a finished job")
    p.add_argument("job")
    p.add_argument("--settings", choices=["current", "saved"])
    p = sub.add_parser("eject-check", help="what Eject would do, without ejecting")
    p.add_argument("volume")
    p = sub.add_parser("eject", help="eject a volume")
    p.add_argument("volume")
    p.add_argument("--confirm", action="store_true",
                   help="eject past a warning when no copy is in progress (a Fast-mode or "
                   "failed run, a card not SAFE TO CLEAR)")
    p.add_argument("--force", action="store_true",
                   help="eject while a transfer is reading or writing it, which can damage that copy")
    p = sub.add_parser("raw", help="send a raw JSON request")
    p.add_argument("payload")
    return parser


def payload_for(args):
    cmd = args.cmd
    simple = {
        "status": {"command": "status"},
        "reread": {"command": "reread-source"},
        "unstage": {"command": "clear-source"},
        "clear-dests": {"command": "clear-destinations"},
        "clear-mirror": {"command": "clear-mirror-folder"},
    }
    if cmd in simple:
        return simple[cmd]
    if cmd == "start":
        out = {"command": "start"}
        if args.verify:
            out["verify"] = args.verify
        return out
    if cmd == "stage":
        out = {"command": "stage-source", "path": path_arg(args.source)}
        if args.label is not None:
            out["label"] = args.label
        return out
    if cmd == "label":
        return {"command": "set-label", "label": args.name}
    if cmd == "add-dest":
        return {"command": "stage-destination", "path": path_arg(args.path)}
    if cmd == "remove-dest":
        return {"command": "remove-destination", "path": path_arg(args.path)}
    if cmd == "mirror":
        return {"command": "set-mirror-folder", "path": mirror_arg(args.folder)}
    if cmd in ("job", "pause", "resume"):
        return {"command": cmd, "job": args.job}
    if cmd == "stop":
        return {"command": "stop", "job": args.job, "confirm": args.confirm}
    if cmd == "retry":
        out = {"command": "stage-retry", "job": args.job}
        if args.settings:
            out["settings"] = args.settings
        return out
    if cmd == "eject-check":
        return {"command": "eject-check", "volume": args.volume}
    if cmd == "eject":
        return {"command": "eject", "volume": args.volume,
                "confirm": args.confirm, "force": args.force}
    if cmd == "raw":
        return json.loads(args.payload)
    raise SystemExit(f"unknown command {cmd}")


def report(args, reply):
    if args.json:
        print(json.dumps(reply, indent=2, sort_keys=True))
    elif not reply.get("ok"):
        print(f"refused: {reply.get('error')}", file=sys.stderr)
    elif args.cmd == "status":
        print_status(reply["state"], args.all)
    elif args.cmd == "job":
        print(job_line(reply["job"]))
    else:
        print(reply.get("message", "done"))
        if reply.get("note"):
            print(f"note: {reply['note']}")
        if args.cmd in ("add-dest", "stage", "label") and reply.get("bench"):
            print_card_folders(reply["bench"])
        for job in reply.get("jobs", []):
            print("  " + job_line(job))
    return EXIT_OK if reply.get("ok") else EXIT_REFUSED


def run_wait(args, path):
    deadline = time.monotonic() + args.wait_timeout if args.wait_timeout > 0 else None
    last = None
    # Resolve the label once: a retry shares its card label with the run it
    # replaces, and every later poll must read the same run.
    first = request(path, {"command": "job", "job": args.job}, args.timeout)
    if not first.get("ok"):
        return report(args, first)
    job_id = first["job"]["id"]
    while True:
        reply = request(path, {"command": "job", "job": job_id}, args.timeout)
        if not reply.get("ok"):
            return report(args, reply)
        job = reply["job"]
        if not job.get("running"):
            if args.json:
                print(json.dumps(reply, indent=2, sort_keys=True))
            else:
                print(job_line(job))
            if (job.get("verdict") in ("verified", "safe_to_clear")
                    and not job.get("needsAttention")
                    and not job.get("verdictWithdrawn")):
                return EXIT_OK
            if job.get("copiedClean"):
                if not args.accept_copied and not args.json:
                    print("copied, not verified (exit 5; --accept-copied counts this as done)",
                          file=sys.stderr)
                return EXIT_OK if args.accept_copied else EXIT_COPIED
            return EXIT_REFUSED
        line = job_line(job).split("\n")[0]
        if line != last and not args.json:
            print(line, flush=True)
            last = line
        if deadline is not None and time.monotonic() >= deadline:
            print(f"timed out; {job['label']} is still {job['activity']}", file=sys.stderr)
            return EXIT_TIMEOUT
        time.sleep(max(0.2, args.interval))


def main(argv=None):
    args = build_parser().parse_args(argv)
    path = args.socket or default_socket_path()
    try:
        if args.cmd == "wait":
            return run_wait(args, path)
        try:
            payload = payload_for(args)
        except json.JSONDecodeError as exc:
            print(f"raw: not JSON ({exc})", file=sys.stderr)
            return EXIT_USAGE
        reply = request(path, payload, args.timeout)
        if args.cmd == "start" and args.wait > 0:
            deadline = time.monotonic() + args.wait
            session = (reply.get("bench") or {}).get("session")
            if session:
                payload = dict(payload, expectSession=session)
            while not reply.get("ok") and reply.get("retryable") and time.monotonic() < deadline:
                time.sleep(1.0)
                reply = request(path, payload, args.timeout)
        return report(args, reply)
    except Unreachable as exc:
        print(str(exc), file=sys.stderr)
        return EXIT_UNREACHABLE


if __name__ == "__main__":
    sys.exit(main())
