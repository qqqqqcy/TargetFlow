#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

# Python owns the child process group and handles signals while waiting for Xcode.
exec /usr/bin/python3 - "$repo_dir" "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

repo = Path(sys.argv[1])
run_id = str(uuid.uuid4())
# Do not depend on TMPDIR being inherited by an Xcode test host.
root = Path(tempfile.mkdtemp(prefix=f"TargetFlowTests-{run_id}-", dir="/tmp"))
host_pattern = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
domain_pattern = re.compile(r"local\.targetflow\.tests\." + re.escape(run_id) + r"\." + host_pattern)
child = None
interrupted = 0


def interrupt(signum, _frame):
    global interrupted
    if not interrupted:
        interrupted = 128 + signum
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass


signal.signal(signal.SIGINT, interrupt)
signal.signal(signal.SIGTERM, interrupt)


def registrations():
    hosts = []
    for path in sorted(root.glob("*/host.json")):
        host = json.loads(path.read_text())
        if (not re.fullmatch(host_pattern, path.parent.name)
                or host.get("hostID") != path.parent.name
                or host.get("runID") != run_id
                or host.get("defaultsDomain") != f"local.targetflow.tests.{run_id}.{path.parent.name}"
                or not isinstance(host.get("pid"), int) or host["pid"] <= 1
                or not (path.parent / "data").is_dir()):
            raise RuntimeError("Invalid test host registration; refusing unverified cleanup")
        hosts.append(host)
    return hosts


def registered_host_alive(pid):
    # Xcode can launch hosts outside its process group. Verify the exact PID's
    # run ID before sending any signal, including after a possible PID reuse.
    result = subprocess.run(["/bin/ps", "eww", "-p", str(pid), "-o", "command="],
                            capture_output=True, text=True)
    return result.returncode == 0 and re.search(
        r"(?:^|\s)TARGETFLOW_TEST_RUN_ID=" + re.escape(run_id) + r"(?:\s|$)", result.stdout)


def stop_hosts(hosts):
    for host in hosts:
        pid = host["pid"]
        for signum, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 2)):
            if not registered_host_alive(pid):
                break
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + grace
            while registered_host_alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
        if registered_host_alive(pid):
            raise RuntimeError("A test host is still running; refusing to remove its storage")


def defaults(*args):
    return subprocess.run(["/usr/bin/defaults", *args], capture_output=True, text=True)


def run_domains():
    result = defaults("domains")
    if result.returncode:
        raise RuntimeError("Cannot enumerate defaults domains")
    return {name.strip() for name in result.stdout.split(",") if domain_pattern.fullmatch(name.strip())}


def cleanup():
    hosts = registrations()
    stop_hosts(hosts)
    # Include registered suites even if cfprefsd has not listed them yet, and
    # match every listed domain against this run ID plus one complete host UUID.
    domains = run_domains() | {host["defaultsDomain"] for host in hosts}
    for domain in sorted(domains):
        print(f"Cleaning defaults domain: {domain}", flush=True)
        defaults("delete", domain)
        # macOS may leave an empty plist after deleting the suite. Remove only
        # the exact file for this registered run/domain, never a wildcard.
        preference_file = Path.home() / "Library/Preferences" / f"{domain}.plist"
        preference_file.unlink(missing_ok=True)
        if defaults("read", domain).returncode == 0 or preference_file.exists():
            raise RuntimeError(f"Defaults domain remains: {domain}")
    if run_domains():
        raise RuntimeError("Defaults domains remain for this run")
    shutil.rmtree(root)
    if root.exists():
        raise RuntimeError("Test directory remains")
    print(f"Cleanup complete: run {run_id}, {len(hosts)} registered host(s); no run directory or defaults domains remain.", flush=True)
    return hosts


status = 1
hosts = []
try:
    print(f"Test run: {run_id}\nTest root: {root}", flush=True)
    environment = os.environ.copy()
    # These must arrive through scheme build-setting expansion, not inheritance.
    for key in ("TARGETFLOW_TEST_RUN_ID", "TARGETFLOW_TEST_ROOT", "TARGETFLOW_TEST_MODE"):
        environment.pop(key, None)
    command = [
        "/usr/bin/xcodebuild", "-project", str(repo / "Dayflow/Dayflow.xcodeproj"),
        "-scheme", "Dayflow", "-destination", "platform=macOS",
        "-parallel-testing-enabled", "YES", "-parallel-testing-worker-count", "2",
        *([] if any(arg.startswith("-only-testing:") for arg in sys.argv[2:])
          else ["-only-testing:DayflowTests"]), *sys.argv[2:],
        "CODE_SIGNING_ALLOWED=NO", f"TARGETFLOW_TEST_RUN_ID={run_id}",
        f"TARGETFLOW_TEST_ROOT={root}", "test",
    ]
    if not interrupted:
        child = subprocess.Popen(command, env=environment, start_new_session=True)
        while child.poll() is None and not interrupted:
            time.sleep(0.1)
        if interrupted:
            # Give Xcode time to stop its runners, then kill only our process group.
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        status = interrupted or child.returncode
        if status < 0:
            status = 128 - status
        if status == 0 and not registrations():
            raise RuntimeError("No test host received the scheme run ID/root")
    else:
        status = interrupted
except Exception as error:
    print(f"Test runner failed: {error}", file=sys.stderr)
    # Keep Xcode's original failure code when cleanup or verification also fails.
    status = interrupted or status or 1
finally:
    try:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        cleanup()
    except Exception as error:
        print(f"Test cleanup failed: {error}", file=sys.stderr)
        status = status or 1
sys.exit(interrupted or status)
PY
