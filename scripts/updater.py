#!/usr/bin/env python3
"""Keep this Mac, and on the hub the iPhones and Apple TVs paired with it, on the family's release of Woodruff Family.

The release is the branch "release" on origin. GitHub Actions moves it to a commit whose message says [release]
once every app built. Installed once per Mac with `install`, this runs as the LaunchAgent
com.woodruff.family.updater every 5 minutes (and at login), compares origin's release with what's installed,
and does every build and install with scripts/deploy.sh:

  hub       The Mac Studio the iPhones and Apple TVs are paired with. Builds and installs the Mac app and shares
            that build in iCloud Drive; builds and signs the iPhone app once per release, keeps that signed copy in
            builds/<commit>/, and installs it on each paired iPhone whenever it's reachable (it never opens the
            app there), until every iPhone has it. The Apple TV app the same way (tv-builds/<commit>/), over the
            home network: an install closes the app, so each Apple TV is asked first whether a film is on screen,
            and is left alone until it isn't.
  follower  Installs the build the hub shared (deploy.sh mac-shared). With --build-fallback (the MacBook) it builds
            here (deploy.sh mac) when no usable shared build arrived within 30 minutes of first seeing the release.

  updater.py install --role hub|follower [--build-fallback] [--interval SECONDS]
  updater.py uninstall [--purge]
  updater.py status [--json]
  updater.py now                  check now (launchctl kickstart without -k: never stops an update under way)
  updater.py run [--verbose]      one check, what the LaunchAgent runs

It never replaces the Mac app while someone is using it (Woodruff Family frontmost, input in the last 2 minutes),
for at most 30 minutes after first seeing the release, and a Mac on battery under 30% doesn't build. After a
failure a part waits 15 min, 30 min, 1 h, 2 h, 4 h, then 8 h between tries; a new release starts over. An iPhone
or Apple TV that isn't reachable is tried every 10 minutes, an Apple TV with a film playing at every check. A
rollback is a release older than what's installed: it's installed like any other.

Files: ~/Library/LaunchAgents/com.woodruff.family.updater.plist; ~/Library/Application Support/Woodruff Family/
Updater/ (config.json, status.json for the app, state.json for this script, updater.lock, results.tsv,
builds/<commit>/, tv-builds/<commit>/); ~/Library/Logs/Woodruff Family/ (updater.log, updater-launchd.log, and
deploy-<time>.log for each deploy.sh run, the newest 10 kept).

It signs nothing and never touches a certificate, key, profile or keychain item: deploy.sh does every build and
signature, and devicectl installs the copy deploy.sh kept. From an Apple TV it reads two things with devicectl:
which build of the app is there, and the app's own settings file, for the note it keeps while a film is open (the
copy is read and removed at once). Apple's /usr/bin/python3 (3.9), standard library only. Every effect on the world
goes through Env, so the tests can replace it.
"""

import argparse
import errno
import fcntl
import glob
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from datetime import datetime, timedelta, timezone

LABEL = "com.woodruff.family.updater"
APP_NAME = "Woodruff Family"
MAC_BUNDLE_ID = "com.woodruff.family.mac"
TV_BUNDLE_ID = "com.blakew316.woodruff.tv"
# The Apple TV app's settings, in its own folder on the Apple TV, and the note it keeps there while a film is open
# (PlayCrumb in App/Shared/PhonePlayer.swift: written as the film opens, again every ten seconds while it's on
# screen, removed as it closes).
TV_SETTINGS = "Library/Preferences/%s.plist" % TV_BUNDLE_ID
TV_FILM_NOTE = "playing.crumb"
RELEASE_BRANCH = "release"
ROLES = ("hub", "follower")
PYTHON = "/usr/bin/python3"
LAUNCHD_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TESTING = "WOODRUFF_UPDATER_TESTING"   # set by the tests: install works off macOS, launchctl comes from PATH
BUSY = "An update is running right now; run this again once it has finished (python3 scripts/updater.py status)."

DEFAULT_INTERVAL = 300
# Between the LaunchAgent's starts, a run looks again this often for a new release (a cheap ls-remote), this many
# times, so a release arrives within about a minute instead of up to five.
QUICK_LOOK_SECONDS = 60
QUICK_LOOKS = 3
BACKOFF = (15 * 60, 30 * 60, 60 * 60, 2 * 3600, 4 * 3600, 8 * 3600)   # after the 1st, 2nd, ... failure
UNREACHABLE_RETRY = 10 * 60
TV_FILM_FRESH = 90           # seconds: a film's note newer than this means the film is on screen now
TV_FILM_RETRY = 4 * 60       # a film is playing: asked again at the next check
NO_TV_WAIT = 6 * 3600        # no Apple TV is paired with this Mac: looked for again this often
COURTESY_IDLE = 120          # seconds without input before the app counts as not in use
COURTESY_RUNS = 6             # checks in a row the Mac app is left alone while in use (~30 minutes awake)
SKIPPED_TESTFLIGHT_WAIT = 6 * 3600   # how long the hub waits to look again when App Store Connect has no app yet
COURTESY_WAIT = 10 * 60       # how long deploy.sh may wait, just before quitting the app, for it to be put down
REQUEST_FRESH = 15 * 60       # a Check for Updates Now press counts for this long
FALLBACK_AFTER = 30 * 60     # a follower with --build-fallback builds when no shared build came by then
LOW_BATTERY = 30             # percent
GIT_TIMEOUT = 60
DEPLOY_TIMEOUT = 3 * 3600
INSTALL_TIMEOUT = 300        # for "devicectl device install app --timeout 240"
DEVICES_TIMEOUT = 240        # signing.py devices waits up to 180 s for devicectl
TV_ASK_TIMEOUT = 90          # asking an Apple TV for its build, or copying its settings file
SMALL_TIMEOUT = 20
LOG_LIMIT = 2 * 1024 * 1024
DEPLOY_LOGS_KEPT = 10
DETAIL_LIMIT = 400

SHA = re.compile(r"^[0-9a-f]{40}$")
UNREACHABLE = re.compile(
    r"not connected|unavailable|no longer available|timed? ?out|could(?: not|n't) (?:connect|establish|find|be found)|"
    r"unable to (?:connect|locate|find)|not (?:reachable|found)|disconnected|offline|tunnel|locked|passcode", re.I)
ERRORISH = re.compile(r"error|failed|unable|denied|locked|timed out|developer mode|not paired|not available", re.I)


# ------------------------------------------------------------------------------------------------- helpers


def iso(when):
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if when else None


def parse_iso(text):
    if not isinstance(text, str):
        return None
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def clock(when):
    """12:40 in this Mac's time zone."""
    return when.astimezone().strftime("%H:%M") if when else "?"


def local_time(text):
    when = parse_iso(text)
    return when.astimezone().strftime("%Y-%m-%d %H:%M") if when else "never"


def one_line(text, limit=DETAIL_LIMIT):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[:limit - 3].rstrip() + "..."


def sentence(text):
    text = one_line(text).rstrip()
    if not text:
        return ""
    text = text[0].upper() + text[1:]
    return text if text.endswith((".", "!", "?")) else text + "."


def short(commit):
    return (commit or "")[:7] or "?"


def backoff(attempts):
    """Seconds to wait after the attempts-th failure in a row."""
    return BACKOFF[min(max(attempts, 1), len(BACKOFF)) - 1]


def due(record, now):
    when = parse_iso((record or {}).get("next_try"))
    return when is None or when <= now


def testing(environ):
    return bool(environ.get(TESTING))


def write_json(path, value):
    """Writes value to a temporary file next to path, then renames it over path: readers never see half of it."""
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write_plist(path, value):
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix="." + os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            plistlib.dump(value, handle)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_json(path):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return None


def first_error(text):
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    for line in lines:
        if ERRORISH.search(line):
            return line
    return lines[-1] if lines else ""


def battery_is_low(text):
    """`pmset -g batt` says it's on battery power with under LOW_BATTERY percent."""
    if "Battery Power" not in (text or ""):
        return False
    match = re.search(r"(\d{1,3})%", text)
    return bool(match) and int(match.group(1)) < LOW_BATTERY


def front_asn(text):
    """The ASN in `lsappinfo front` output, like ASN:0x0-0x2b02b:."""
    match = re.search(r"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:?", text or "")
    return match.group(0) if match else None


def bundle_id_in(text):
    """The bundle id in `lsappinfo info -only bundleid ASN` output: "CFBundleIdentifier"="com.apple.Terminal"."""
    match = re.search(r'"(?:CFBundleIdentifier|bundleid|bundleID)"\s*=\s*"([^"]*)"', text or "")
    return match.group(1) if match else None


def hid_idle_seconds(text):
    """HIDIdleTime (nanoseconds) in `ioreg -c IOHIDSystem` output, in seconds; None if it isn't there."""
    match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', text or "")
    return int(match.group(1)) / 1e9 if match else None


def parse_results(text):
    """deploy.sh --results lines (part, status, target, detail; tab-separated) as dicts."""
    rows = []
    for line in (text or "").splitlines():
        fields = line.rstrip("\r").split("\t", 3)
        if len(fields) < 3 or not fields[0].strip():
            continue
        fields += [""] * (4 - len(fields))
        rows.append({"part": fields[0].strip(), "status": fields[1].strip(), "target": fields[2].strip(),
                     "detail": fields[3].strip()})
    return rows


def name_in(detail):
    """The iPhone's name at the start of a deploy.sh iphone detail ("Blake's iPhone: installed")."""
    name, sep, _ = (detail or "").partition(": ")
    return name.strip() if sep and name.strip() else None


def without_name(detail, name):
    """A deploy.sh iphone detail without the iPhone's name in front ("installed")."""
    detail = detail or ""
    if name and detail.startswith(name + ": "):
        return detail[len(name) + 2:]
    return detail.split(": ", 1)[1] if name_in(detail) else detail


def tv_app_build(doc, text=""):
    """What `devicectl device info apps --bundle-id` says of Woodruff Family on an Apple TV: (installed, build).
    From the JSON it writes (the object naming the app's bundle id), else from the table it prints, whose last
    column is the build. (False, None) when the app isn't there."""
    found = []

    def walk(value):
        if isinstance(value, dict):
            keys = dict((str(key).lower(), key) for key in value)
            if value.get(keys.get("bundleidentifier")) == TV_BUNDLE_ID:
                found.append(value.get(keys.get("bundleversion")))
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(doc)
    if found:
        version = str(found[0] if found[0] is not None else "").strip()
        return True, (int(version) if version.isdigit() else None)
    for line in (text or "").splitlines():
        fields = line.split()
        if TV_BUNDLE_ID in fields:
            return True, (int(fields[-1]) if fields[-1].isdigit() else None)
    return False, None


def film_on_screen(settings, now):
    """The Apple TV app's settings say a film is on screen now: its note (TV_FILM_NOTE) is there and was written in
    the last TV_FILM_FRESH seconds. The app writes it as a film opens, again every ten seconds while the film is on
    screen (playing or stopped), and removes it as the film closes; the note of an app that was put away or ended
    isn't renewed, so it stops counting. One stamped later than now (the clocks disagree) counts as on screen."""
    note = settings.get(TV_FILM_NOTE) if isinstance(settings, dict) else None
    at = note.get("at") if isinstance(note, dict) else None
    if isinstance(at, bool) or not isinstance(at, (int, float)):
        return False
    return now.timestamp() - float(at) < TV_FILM_FRESH


# --------------------------------------------------------------------------------------------- the world


class Env(object):
    """Every effect on the world: commands, the clock, sleeping and where files are. The tests replace it."""

    def __init__(self, home=None, applications="/Applications", platform=None, uid=None, script=None, environ=None,
                 launchctl=None):
        self.home = home or os.path.expanduser("~")
        self.applications = applications
        self.platform = platform or sys.platform
        self._uid = uid
        self.script = os.path.realpath(script or os.path.abspath(__file__))
        self.environ = dict(os.environ if environ is None else environ)
        self.launchctl = launchctl or ("launchctl" if testing(self.environ) else "/bin/launchctl")
        self.python = sys.executable or PYTHON
        self.child = None
        self.support = os.path.join(self.home, "Library", "Application Support", "Woodruff Family", "Updater")
        self.logs = os.path.join(self.home, "Library", "Logs", "Woodruff Family")
        self.agents = os.path.join(self.home, "Library", "LaunchAgents")
        self.app = os.path.join(self.applications, APP_NAME + ".app")

    def now(self):
        return datetime.now(timezone.utc).replace(microsecond=0)

    def sleep(self, seconds):
        time.sleep(seconds)

    # How many quick looks for a new release a run makes after its check (the tests make none).
    quick_looks = QUICK_LOOKS

    def uid(self):
        return os.getuid() if self._uid is None else self._uid

    def child_env(self, extra=None):
        env = dict(self.environ)
        env["GIT_TERMINAL_PROMPT"] = "0"
        parts = [part for part in env.get("PATH", "").split(":") if part]
        for folder in LAUNCHD_PATH.split(":"):
            if folder not in parts:
                parts.append(folder)
        env["PATH"] = ":".join(parts)
        env.update(extra or {})
        return env

    def run(self, argv, timeout, cwd=None, env=None, output=None):
        """(status, stdout, stderr) of argv: never a shell, stdin /dev/null, its own session (so no terminal to
        prompt on). output: a file for stdout and stderr instead. After timeout seconds it and everything it
        started are stopped (status 124); 127 if it can't start."""
        handle = None
        try:
            if output:
                handle = open(output, "ab")
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=handle or subprocess.PIPE,
                                    stderr=subprocess.STDOUT if handle else subprocess.PIPE, cwd=cwd,
                                    env=self.child_env(env), start_new_session=True)
        except OSError as exc:
            if handle:
                handle.close()
            return 127, "", str(exc)
        self.child = proc
        try:
            try:
                out, err = proc.communicate(timeout=timeout)
                status = proc.returncode
            except subprocess.TimeoutExpired:
                self.stop(proc)
                out, err = proc.communicate()
                status = 124
        finally:
            self.child = None
            if handle:
                handle.close()
        return status, _text(out), _text(err)

    def stop(self, proc, grace=10):
        """SIGTERM to the command and everything it started, then SIGKILL to whatever is left."""
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass


def _text(data):
    if data is None:
        return ""
    return data.decode("utf-8", "replace") if isinstance(data, bytes) else str(data)


def paths(env):
    support = env.support
    return {
        "config": os.path.join(support, "config.json"),
        "status": os.path.join(support, "status.json"),
        "state": os.path.join(support, "state.json"),
        "lock": os.path.join(support, "updater.lock"),
        "results": os.path.join(support, "results.tsv"),
        "request": os.path.join(support, "check-now"),   # Check for Updates Now (the Mac app): no courtesy wait
        "builds": os.path.join(support, "builds"),
        "tv_builds": os.path.join(support, "tv-builds"),
        "log": os.path.join(env.logs, "updater.log"),
        "launchd_log": os.path.join(env.logs, "updater-launchd.log"),
        "plist": os.path.join(env.agents, LABEL + ".plist"),
    }


def take_lock(path):
    """A file descriptor holding an exclusive flock on path, or None if another process holds it."""
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES):
            return None
        raise
    try:
        os.ftruncate(fd, 0)
        os.write(fd, ("%d\n" % os.getpid()).encode("ascii"))
    except OSError:
        pass
    return fd


def append_log(env, line):
    log = paths(env)["log"]
    try:
        os.makedirs(env.logs, exist_ok=True)
        if os.path.exists(log) and os.path.getsize(log) >= LOG_LIMIT:
            os.replace(log, log + ".1")
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def app_in_use(env):
    """Woodruff Family is frontmost and someone touched the keyboard or mouse in the last 2 minutes. A command
    that fails counts as not in use."""
    status, out, _ = env.run(["lsappinfo", "front"], SMALL_TIMEOUT)
    asn = front_asn(out) if status == 0 else None
    if not asn:
        return False
    status, out, _ = env.run(["lsappinfo", "info", "-only", "bundleid", asn], SMALL_TIMEOUT)
    if status != 0 or bundle_id_in(out) != MAC_BUNDLE_ID:
        return False
    status, out, _ = env.run(["ioreg", "-c", "IOHIDSystem"], SMALL_TIMEOUT)
    idle = hid_idle_seconds(out) if status == 0 else None
    return idle is not None and idle < COURTESY_IDLE


def repo_of(script):
    """The checkout this script is in (it has scripts/deploy.sh and project.yml), or None."""
    root = os.path.dirname(os.path.dirname(os.path.realpath(script)))
    if os.path.isfile(os.path.join(root, "scripts", "deploy.sh")) and os.path.isfile(os.path.join(root, "project.yml")):
        return root
    return None


def load_config(env):
    """(config, None) or (None, why)."""
    path = paths(env)["config"]
    if not os.path.exists(path):
        return None, ("isn't installed on this Mac (%s is missing). Install it with: python3 scripts/updater.py "
                      "install --role hub|follower" % path)
    config = read_json(path)
    if not isinstance(config, dict):
        return None, "can't read %s" % path
    if config.get("role") not in ROLES:
        return None, "%s has role %r, not hub or follower" % (path, config.get("role"))
    repo = config.get("repo")
    if not isinstance(repo, str) or not os.path.isfile(os.path.join(repo, "scripts", "deploy.sh")):
        return None, "%s names the checkout %r, which has no scripts/deploy.sh" % (path, repo)
    config.setdefault("branch", RELEASE_BRANCH)
    config["build_fallback"] = bool(config.get("build_fallback"))
    return config, None


def launchd_plist(env, repo, interval):
    launchd_log = paths(env)["launchd_log"]
    return {
        "Label": LABEL,
        "ProgramArguments": [PYTHON, "-I", os.path.join(repo, "scripts", "updater.py"), "run"],
        "StartInterval": int(interval),
        "RunAtLoad": True,
        "StandardOutPath": launchd_log,
        "StandardErrorPath": launchd_log,
        "EnvironmentVariables": {"PATH": LAUNCHD_PATH, "LANG": "en_US.UTF-8"},
        "ProcessType": "Standard",
    }


def service(env):
    return "gui/%d/%s" % (env.uid(), LABEL)


def agent_loaded(env):
    status, _, _ = env.run([env.launchctl, "print", service(env)], SMALL_TIMEOUT)
    return status == 0


# ------------------------------------------------------------------------------------------------- state


def unusable_share(detail):
    """A mac-shared failure that waiting can't fix: the build is signed for another team or under another
    certificate name (anything else, like a copy error, is tried again first)."""
    text = (detail or "").lower()
    return "can't be used" in text or "signed for team" in text or "but the installed app by" in text


def blank_state():
    return {
        "format": 1,
        "release": None,   # {"commit", "build", "subject", "seen_at"}
        # The installed Mac app; failed_commit: the release whose last install here failed.
        "mac": {"commit": None, "build": None, "updated_at": None, "state": "current", "detail": "",
                "attempts": 0, "next_try": None, "failed_commit": None},
        "share": {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None},   # hub
        "shared": {"attempts": 0, "next_try": None, "detail": ""},   # follower: mac-shared failures
        "build": {"attempts": 0, "next_try": None},                   # follower: builds here
        "iphone_build": {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None},
        # hub: the release uploaded to TestFlight (state ok, uploading, skipped, failed), so the iPhones and iPads
        # update on Wi-Fi or cellular, away from home too.
        "testflight": {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None},
        # [{"udid", "name", "commit", "updated_at", "state", "detail", "next_try", "attempts", "retry"}]
        "iphones": [],
        # hub: the Apple TV app built and kept for the release (state ok, skipped: no Apple TV is paired, failed).
        "tv_build": {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None},
        # The Apple TVs, like the iPhones; state is also "waiting" while a film is playing there.
        "appletvs": [],
        "busy_runs": 0,   # checks in a row the Mac app was in use
        "last_check": None,
        "last_error": None,
    }


def load_state(env):
    state = blank_state()
    saved = read_json(paths(env)["state"])
    if not isinstance(saved, dict):
        return state
    for key, value in saved.items():
        if key in state and isinstance(state[key], dict) and isinstance(value, dict):
            state[key].update(value)
        elif key in state:
            state[key] = value
    for key in ("iphones", "appletvs"):
        if not isinstance(state[key], list):
            state[key] = []
        state[key] = [d for d in state[key] if isinstance(d, dict) and isinstance(d.get("udid"), str)]
    if state["release"] is not None and not (isinstance(state["release"], dict) and
                                             SHA.match(str(state["release"].get("commit") or ""))):
        state["release"] = None
    return state


# ------------------------------------------------------------------------------------------------ the run


class Updater(object):
    def __init__(self, env, config, verbose=False):
        self.env = env
        self.config = config
        self.verbose = verbose
        self.role = config["role"]
        self.repo = config["repo"]
        self.branch = config.get("branch") or RELEASE_BRANCH
        self.fallback = bool(config.get("build_fallback")) and self.role == "follower"
        # The hub uploads each release to TestFlight unless config.json says "testflight": false.
        self.testflight = self.role == "hub" and config.get("testflight", True) is not False
        # The hub keeps the Apple TVs paired with it on the release unless config.json says "appletv": false.
        self.appletv = self.role == "hub" and config.get("appletv", True) is not False
        self.files = paths(env)
        self.deploy_sh = os.path.join(self.repo, "scripts", "deploy.sh")
        self.signing = os.path.join(self.repo, "scripts", "signing.py")
        self.state = load_state(env)
        self.running = False
        self.now = env.now()
        self._battery = None
        self._in_use = None
        self._requested = None
        self._waited_enough = False   # in use for COURTESY_RUNS checks in a row: no more waiting this run

    # ---------------------------------------------------------------- bookkeeping

    def tick(self):
        self.now = self.env.now()

    def log(self, message):
        line = "%s %s" % (iso(self.env.now()), one_line(message, 2000))
        append_log(self.env, line)
        if self.verbose:
            print(line)
            sys.stdout.flush()

    def save(self, running):
        self.running = running
        self.tick()
        write_json(self.files["state"], self.state)
        write_json(self.files["status"], self.status_doc())

    def status_doc(self):
        """status.json, format 1 (the Mac app shows it in Settings > General)."""
        st = self.state
        rel = st.get("release")
        mac = st["mac"]
        share = st["share"] if self.role == "hub" else {}
        tf = st["testflight"] if self.role == "hub" else {}
        phones, tvs = [], []
        for key, listed in (("iphones", phones), ("appletvs", tvs)):
            for d in st[key]:
                listed.append({
                    "udid": d["udid"],
                    "name": d.get("name") or d["udid"],
                    "commit": d.get("commit"),
                    "updated_at": d.get("updated_at"),
                    "state": d.get("state") or "pending",
                    "detail": d.get("detail") or "",
                    "next_try": None if d.get("state") == "current" else d.get("next_try"),
                })
        return {
            "format": 1,
            "updated_at": iso(self.env.now()),
            "role": self.role,
            "running": bool(self.running),
            "release": None if not rel else {"commit": rel["commit"], "build": rel.get("build"),
                                             "subject": rel.get("subject") or "", "seen_at": rel.get("seen_at")},
            "mac": {"commit": mac.get("commit"), "build": mac.get("build"), "updated_at": mac.get("updated_at"),
                    "state": mac.get("state") or "current", "detail": mac.get("detail") or ""},
            "iphones": phones,
            "appletvs": tvs,
            "share": {"commit": share.get("commit"), "state": share.get("state"), "detail": share.get("detail") or ""},
            "testflight": {"commit": tf.get("commit"), "state": tf.get("state"), "detail": tf.get("detail") or ""},
            "last_check": st.get("last_check"),
            "last_error": st.get("last_error"),
        }

    def set_mac(self, state, detail):
        self.state["mac"]["state"] = state
        self.state["mac"]["detail"] = sentence(detail)

    def release_build(self):
        rel = self.state.get("release") or {}
        return rel.get("build")

    def build_words(self):
        build = self.release_build()
        return "build %s" % build if build else "the release"

    # ---------------------------------------------------------------- the world, read

    def git(self, args, timeout=GIT_TIMEOUT):
        return self.env.run(["git"] + list(args), timeout, cwd=self.repo)

    def find_release(self):
        """(commit, None); (None, None) when origin has no release branch yet; (None, why) when it can't tell."""
        ref = "refs/heads/" + self.branch
        status, out, err = self.git(["ls-remote", "--exit-code", "origin", ref])
        if status == 2:
            return None, None
        if status != 0:
            return None, "git ls-remote origin %s failed (%s): %s" % (ref, status, one_line(err or out, 200))
        for line in out.splitlines():
            fields = line.split()
            if len(fields) == 2 and fields[1] == ref and SHA.match(fields[0].lower()):
                return fields[0].lower(), None
        return None, "git ls-remote origin %s gave no commit" % ref

    def learn_release(self, commit):
        """Records origin's release commit (fetching it when it's new). False if it couldn't be fetched."""
        st = self.state
        rel = st.get("release")
        if rel and rel.get("commit") == commit:
            return True
        ref = "refs/remotes/origin/" + self.branch
        status, out, err = self.git(["fetch", "--quiet", "origin", "+refs/heads/%s:%s" % (self.branch, ref)])
        if status != 0:
            st["last_error"] = "git fetch of the %s branch failed: %s" % (self.branch, one_line(err or out, 200))
            self.log(st["last_error"])
            return False
        status, out, _ = self.git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"])
        fetched = out.strip().lower()
        if status == 0 and SHA.match(fetched) and fetched != commit:
            self.log("the release moved to %s while it was being fetched" % fetched[:12])
            commit = fetched
            if rel and rel.get("commit") == commit:
                return True
        status, subject, _ = self.git(["log", "-1", "--format=%s", commit])
        subject = one_line(subject, 200) if status == 0 else ""
        status, count, _ = self.git(["rev-list", "--count", commit])
        count = count.strip()
        build = int(count) if status == 0 and count.isdigit() else None
        st["release"] = {"commit": commit, "build": build, "subject": subject, "seen_at": iso(self.now)}
        self.reset_for(commit)
        self.log("new release %s (build %s): %s" % (commit[:12], build if build else "?", subject))
        return True

    def reset_for(self, commit):
        """A new release: every part starts over."""
        st = self.state
        st["mac"].update(attempts=0, next_try=None, failed_commit=None)
        st["share"] = {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None}
        st["shared"] = {"attempts": 0, "next_try": None, "detail": ""}
        st["build"] = {"attempts": 0, "next_try": None}
        st["iphone_build"] = {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None}
        if st["testflight"].get("state") != "skipped":   # no app in App Store Connect yet: keeps its later look
            st["testflight"].update(attempts=0, next_try=None)
        for phone in st["iphones"]:
            phone.update(attempts=0, next_try=None, retry=True)
            if phone.get("commit") != commit:
                phone.update(state="pending", detail="Waiting for the iPhone build.")
        st["tv_build"] = {"commit": None, "state": None, "detail": "", "attempts": 0, "next_try": None}
        for tv in st["appletvs"]:
            tv.update(attempts=0, next_try=None, retry=True)
            if tv.get("commit") != commit:
                tv.update(state="pending", detail="Waiting for the Apple TV build.")

    def scripts_run(self, commit):
        """The release's updater.py and signing.py started with this Mac's Python (their imports and top level run,
        which compiling alone doesn't: "str | None" compiles on 3.9 but fails when it runs). None when both start."""
        tmp = tempfile.mkdtemp(prefix="woodruff-check.")
        try:
            for name in ("scripts/updater.py", "scripts/signing.py"):
                status, source, _ = self.git(["show", "%s:%s" % (commit, name)])
                if status != 0:
                    continue
                path = os.path.join(tmp, os.path.basename(name))
                with open(path, "w", encoding="utf-8") as f:
                    f.write(source)
                status, _, err = self.env.run([self.env.python, "-I", path, "--help"], SMALL_TIMEOUT)
                if status != 0:
                    return "its %s doesn't run with this Mac's Python %d.%d (%s)" % (
                        name, sys.version_info[0], sys.version_info[1], one_line(err or "exit %d" % status, 200))
            return None
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def release_problem(self, commit):
        """Why installing this release would leave this Mac unable to update again, or None: it has no
        scripts/deploy.sh or scripts/updater.py, or its updater.py doesn't compile with the Python running this
        (the LaunchAgent's /usr/bin/python3). Checked once per release."""
        rel = self.state.get("release") or {}
        if rel.get("commit") == commit and rel.get("checked"):
            return rel.get("problem")
        problem = None
        for name in ("scripts/deploy.sh", "scripts/updater.py"):
            status, _, _ = self.git(["cat-file", "-e", "%s:%s" % (commit, name)])
            if status != 0:
                problem = "it has no %s" % name
                break
        if problem is None:
            status, source, err = self.git(["show", "%s:scripts/updater.py" % commit])
            if status != 0:
                problem = None   # can't tell (git trouble): deploy.sh's own checkout will say what's wrong
            else:
                try:
                    compile(source, "scripts/updater.py", "exec")
                except (SyntaxError, ValueError) as exc:
                    problem = "its scripts/updater.py doesn't compile with this Mac's Python %d.%d (%s)" % (
                        sys.version_info[0], sys.version_info[1], one_line(exc, 200))
        if problem is None:
            problem = self.scripts_run(commit)
        if rel.get("commit") == commit:
            rel.update(checked=True, problem=problem)
        return problem

    def read_info_plist(self):
        """(WoodruffCommit, CFBundleVersion) of the installed Mac app; (None, None) for what it doesn't say."""
        try:
            with open(os.path.join(self.env.app, "Contents", "Info.plist"), "rb") as handle:
                info = plistlib.load(handle)
        except Exception:  # noqa: BLE001 - missing or unreadable
            return None, None
        if not isinstance(info, dict):
            return None, None
        commit = str(info.get("WoodruffCommit") or "").strip().lower()
        version = str(info.get("CFBundleVersion") or "").strip()
        return (commit if SHA.match(commit) else None), (int(version) if version.isdigit() else None)

    def refresh_mac(self):
        """What's installed: WoodruffCommit from the app's Info.plist, else the commit this script last installed
        (an app built before builds said their commit). No app, no commit."""
        mac = self.state["mac"]
        if not os.path.isdir(self.env.app):
            mac.update(commit=None, build=None)
            return
        commit, build = self.read_info_plist()
        if commit is None:
            return
        if commit != mac.get("commit"):
            try:
                mtime = os.path.getmtime(os.path.join(self.env.app, "Contents", "Info.plist"))
                mac["updated_at"] = iso(datetime.fromtimestamp(mtime, timezone.utc))
            except OSError:
                mac["updated_at"] = None
        mac.update(commit=commit, build=build if build is not None else mac.get("build"))

    def mac_current(self, release):
        mac = self.state["mac"]
        return mac.get("commit") == release and mac.get("failed_commit") != release

    def battery_low(self):
        if self._battery is None:
            status, out, _ = self.env.run(["pmset", "-g", "batt"], SMALL_TIMEOUT)
            self._battery = status == 0 and battery_is_low(out)
            if self._battery:
                self.log("on battery under %d%%: no builds now" % LOW_BATTERY)
        return self._battery

    def requested_now(self):
        """Someone pressed Check for Updates Now in the Mac app in the last 15 minutes."""
        if self._requested is None:
            try:
                age = self.now.timestamp() - os.path.getmtime(self.files["request"])
                self._requested = -60 < age < REQUEST_FRESH
            except OSError:
                self._requested = False
        return self._requested

    def shared_arrived(self, commit):
        """A follower waiting for [commit]'s shared build, and its manifest is now in iCloud Drive (not when macOS is
        keeping the updater out of iCloud Drive: looking again every minute changes nothing then)."""
        if self.role != "follower" or self.state["mac"].get("state") != "waiting":
            return False
        if "Full Disk Access" in (self.state.get("shared") or {}).get("detail", ""):
            return False
        share = os.path.join(self.env.home, "Library", "Mobile Documents", "com~apple~CloudDocs", "Woodruff Family builds")
        return os.path.exists(os.path.join(share, "Woodruff Family %s.json" % commit[:12]))

    def courtesy_deadline(self):
        """How long deploy.sh may wait, just before it quits the Mac app, for nobody to be using it."""
        if self.requested_now() or self._waited_enough:
            return None
        return self.now + timedelta(seconds=COURTESY_WAIT)

    def postponed_for_use(self):
        """Someone is using the Mac app: left alone for up to 6 checks in a row (counted while this Mac is awake, so
        sleep doesn't use them up), and not at all when they pressed Check for Updates Now."""
        st = self.state
        if self.requested_now():
            st["busy_runs"] = 0
            return False
        if self._in_use is None:
            self._in_use = app_in_use(self.env)
        if not self._in_use:
            st["busy_runs"] = 0
            return False
        runs = int(st.get("busy_runs") or 0) + 1
        if runs > COURTESY_RUNS:
            st["busy_runs"] = 0
            self._waited_enough = True
            self.log("Woodruff Family has been in use for %d checks in a row: updating anyway" % COURTESY_RUNS)
            return False
        st["busy_runs"] = runs
        self.log("Woodruff Family is in use: not replacing it yet (%d of %d)" % (runs, COURTESY_RUNS))
        self.set_mac("postponed", "Waiting until Woodruff Family isn't in use")
        return True

    def battery_hold(self):
        if self.battery_low():
            self.set_mac("postponed", "Waiting for this Mac to charge (the battery is under %d%%)" % LOW_BATTERY)
            return True
        return False

    # ---------------------------------------------------------------- deploy.sh

    def deploy(self, args, idle_until=None):
        """Runs deploy.sh with args and --results; (status, results, log)."""
        results = self.files["results"]
        os.makedirs(os.path.dirname(results), exist_ok=True)
        with open(results, "w"):
            pass
        log = self.new_deploy_log()
        extra = {"WOODRUFF_DEPLOY_BACKGROUND": "1"}   # reopen the app without bringing it to the front
        if idle_until is not None and idle_until > self.now:
            extra["WOODRUFF_DEPLOY_IDLE_UNTIL"] = str(int(idle_until.timestamp()))
        argv = [self.deploy_sh] + list(args) + ["--results", results]
        self.log("running deploy.sh %s (log %s)" % (" ".join(args), log))
        status, _, _ = self.env.run(argv, DEPLOY_TIMEOUT, cwd=self.repo, env=extra, output=log)
        try:
            with open(results, encoding="utf-8", errors="replace") as handle:
                rows = parse_results(handle.read())
        except OSError:
            rows = []
        self.tick()
        self.log("deploy.sh exited %d: %s" % (status, "; ".join("%s %s" % (r["part"], r["status"]) for r in rows)
                                                or "no results"))
        if status != 0 and rows and all(r["status"] in ("installed", "ok") for r in rows):
            self.state["last_error"] = "deploy.sh exited %d although every part worked; see %s" % (status, log)
        self.prune_deploy_logs()
        return status, rows, log

    def new_deploy_log(self):
        os.makedirs(self.env.logs, exist_ok=True)
        stamp = self.env.now().strftime("%Y%m%dT%H%M%SZ")
        path = os.path.join(self.env.logs, "deploy-%s.log" % stamp)
        n = 2
        while os.path.exists(path):
            path = os.path.join(self.env.logs, "deploy-%s-%d.log" % (stamp, n))
            n += 1
        with open(path, "w"):
            pass
        return path

    def prune_deploy_logs(self):
        logs = sorted(glob.glob(os.path.join(self.env.logs, "deploy-*.log")),
                      key=lambda p: (os.path.getmtime(p), p))
        for path in logs[:-DEPLOY_LOGS_KEPT]:
            try:
                os.remove(path)
            except OSError:
                pass

    @staticmethod
    def row(rows, part):
        found = None
        for row in rows:
            if row["part"] == part:
                found = row
        return found

    @staticmethod
    def stopped(status, log):
        return "deploy.sh stopped (exit %d) without saying how it went; see %s" % (status, log)

    def mac_installed(self, release, counter, detail):
        """deploy.sh installed the release here. False (and a failure) if the app says it's another commit."""
        mac = self.state["mac"]
        commit, build = self.read_info_plist()
        if commit is not None and commit != release:
            return self.mac_failed(release, counter, "deploy.sh installed it, but the app says it's %s" % short(commit))
        mac.update(commit=release, build=build if build is not None else self.release_build(),
                   updated_at=iso(self.now), failed_commit=None, attempts=0, next_try=None)
        counter.update(attempts=0, next_try=None)
        if "didn't start" in (detail or ""):
            self.set_mac("current", "Installed, but it didn't start")
        else:
            self.set_mac("current", "Up to date")
        self.log("Mac: installed %s" % release[:12])
        return True

    def mac_failed(self, release, counter, detail):
        counter["attempts"] = int(counter.get("attempts") or 0) + 1
        when = self.now + timedelta(seconds=backoff(counter["attempts"]))
        counter["next_try"] = iso(when)
        self.state["mac"]["failed_commit"] = release
        self.set_mac("failed", "%s. Next try at %s" % (sentence(detail).rstrip("."), clock(when)))
        self.log("Mac: failed (try %d, next at %s): %s" % (counter["attempts"], iso(when), one_line(detail, 300)))
        return False

    # ---------------------------------------------------------------- iPhones

    def phone(self, udid, name=None, key="iphones"):
        """The record kept of an iPhone (or, with key "appletvs", of an Apple TV), made when there's none."""
        for record in self.state[key]:
            if record["udid"] == udid:
                if name and (record.get("name") in (None, "", udid)):
                    record["name"] = name
                return record
        record = {"udid": udid, "name": name or udid, "commit": None, "updated_at": None, "state": "pending",
                  "detail": "", "next_try": None, "attempts": 0, "retry": True}
        self.state[key].append(record)
        return record

    def phone_installed(self, record, release, kind="iPhone", how="installed"):
        record.update(commit=release, updated_at=iso(self.now), state="current", detail="Up to date.",
                      next_try=None, attempts=0, retry=True)
        self.log("%s %s: %s %s" % (kind, record.get("name"), how, release[:12]))

    def phone_failed(self, record, detail, kind="iPhone"):
        if UNREACHABLE.search(detail or ""):
            when = self.now + timedelta(seconds=UNREACHABLE_RETRY)
            record.update(state="unreachable", next_try=iso(when),
                          detail="Not reachable from this Mac. Next try at %s." % clock(when))
            self.log("%s %s: not reachable (%s); next try at %s" % (kind, record.get("name"), one_line(detail, 200),
                                                                    iso(when)))
            return
        record["attempts"] = int(record.get("attempts") or 0) + 1
        when = self.now + timedelta(seconds=backoff(record["attempts"]))
        record.update(state="failed", next_try=iso(when),
                      detail="%s. Next try at %s." % (sentence(detail).rstrip("."), clock(when)))
        self.log("%s %s: failed (try %d, next at %s): %s" % (kind, record.get("name"), record["attempts"], iso(when),
                                                             one_line(detail, 300)))

    def kept_build(self, release, builds=None):
        """The signed iPhone app deploy.sh kept for this release (or, with the Apple TV builds' folder, the Apple TV
        app): {"app", "devices"}; None if there's none, it's for another commit, or its profile has expired."""
        folder = os.path.join(builds or self.files["builds"], release)
        app = os.path.join(folder, APP_NAME + ".app")
        meta = read_json(os.path.join(folder, "build.json"))
        if not isinstance(meta, dict) or str(meta.get("commit") or "").lower() != release or not os.path.isdir(app):
            return None
        expires = parse_iso(meta.get("app_profile_expires"))
        if expires is not None and expires <= self.now:
            return None
        devices = []
        for device in meta.get("devices") or []:
            if isinstance(device, dict) and isinstance(device.get("udid"), str) and device["udid"].strip():
                devices.append({"udid": device["udid"].strip(), "name": device.get("name") or device["udid"]})
        return {"app": app, "devices": devices}

    def iphone_build_needed(self, release):
        ib = self.state["iphone_build"]
        if ib.get("commit") == release and ib.get("state") == "skipped":
            return False
        phones = self.state["iphones"]
        if not phones:
            return not (ib.get("commit") == release and ib.get("state") == "ok")
        return any(p.get("commit") != release and p.get("retry", True) for p in phones)

    def apply_iphones(self, release, rows, status, log):
        """deploy.sh's iphone-build and iphone results."""
        st, now = self.state, self.now
        ib = st["iphone_build"]
        row = self.row(rows, "iphone-build")
        kept = self.kept_build(release)
        names = dict((d["udid"], d["name"]) for d in (kept or {}).get("devices", []))
        if row and row["status"] == "ok":
            ib.update(commit=release, state="ok", detail=sentence(row["detail"]))
            if kept is None:   # signed, but not kept: don't build again right away
                ib["attempts"] = int(ib.get("attempts") or 0) + 1
                ib["next_try"] = iso(now + timedelta(seconds=backoff(ib["attempts"])))
            else:
                ib.update(attempts=0, next_try=None)
        elif row and row["status"] == "skipped":
            ib.update(commit=release, state="skipped", detail=sentence(row["detail"]), attempts=0, next_try=None)
            st["iphones"] = []
            self.log("iPhones: none to update (%s)" % row["detail"])
        else:
            detail = row["detail"] if row else self.stopped(status, log)
            ib["attempts"] = int(ib.get("attempts") or 0) + 1
            when = now + timedelta(seconds=backoff(ib["attempts"]))
            ib.update(commit=release, state="failed", detail=sentence(detail), next_try=iso(when))
            for phone in st["iphones"]:
                if phone.get("commit") != release:
                    phone.update(state="failed", next_try=iso(when),
                                 detail="The iPhone build failed: %s Next try at %s." % (sentence(detail), clock(when)))
            self.log("iPhone build: failed (try %d, next at %s): %s" % (ib["attempts"], iso(when),
                                                                       one_line(detail, 300)))
        seen = []
        for row in rows:
            if row["part"] != "iphone" or not row["target"]:
                continue
            udid = row["target"]
            record = self.phone(udid, names.get(udid) or name_in(row["detail"]))
            seen.append(udid)
            if row["status"] == "installed":
                self.phone_installed(record, release)
            elif row["status"] == "skipped":
                record.update(state="failed", retry=False, next_try=None,
                              detail=sentence(without_name(row["detail"], record.get("name"))))
                self.log("iPhone %s: %s" % (record.get("name"), row["detail"]))
            else:
                self.phone_failed(record, without_name(row["detail"], record.get("name")))
        if ib.get("state") == "ok" and (seen or names):
            # The iPhones this build saw are the ones paired now: forget the rest.
            st["iphones"] = [p for p in st["iphones"] if p["udid"] in seen or p["udid"] in names]

    def list_devices(self, platform="iOS"):
        """({UDID: device}, None) from signing.py devices (the iPhones and iPads; with tvOS, the Apple TVs), or
        (None, why)."""
        argv = [self.env.python, "-I", self.signing, "devices"]
        if platform != "iOS":
            argv += ["--platform", platform]
        status, out, err = self.env.run(argv, DEVICES_TIMEOUT, cwd=self.repo)
        if status != 0:
            return None, one_line(err or out or "signing.py devices exited %d" % status, 200)
        try:
            listed = json.loads(out)
        except ValueError:
            return None, "signing.py devices didn't print JSON"
        devices = {}
        for device in listed if isinstance(listed, list) else []:
            if isinstance(device, dict) and isinstance(device.get("udid"), str):
                devices[device["udid"]] = device
        return devices, None

    def install_kept(self, release, kept):
        """Installs the kept iPhone app on each iPhone that doesn't have this release and whose next try is due."""
        now = self.now
        todo = []
        for device in kept["devices"]:
            record = self.phone(device["udid"], device["name"])
            if record.get("commit") == release and record.get("state") == "current":
                continue
            # Check for Updates Now tries every iPhone at once, whatever its wait after an earlier failure.
            if not record.get("retry", True) or not (due(record, now) or self.requested_now()):
                continue
            todo.append(record)
        if not todo:
            return
        listed, error = self.list_devices()
        if listed is None:
            self.state["last_error"] = "couldn't list the iPhones: %s" % error
            self.log(self.state["last_error"])
            for record in todo:
                record["next_try"] = iso(now + timedelta(seconds=UNREACHABLE_RETRY))
            return
        for record in todo:
            info = listed.get(record["udid"])
            if info is None or info.get("pairing") not in (None, "", "paired"):
                when = self.now + timedelta(seconds=UNREACHABLE_RETRY)
                record.update(state="pending", detail="Not paired with this Mac.", next_try=iso(when))
                self.log("iPhone %s: not paired with this Mac; skipped" % record.get("name"))
                continue
            if info.get("tunnel") == "unavailable":
                when = self.now + timedelta(seconds=UNREACHABLE_RETRY)
                record.update(state="unreachable", next_try=iso(when),
                              detail="Not reachable from this Mac. Next try at %s." % clock(when))
                self.log("iPhone %s: not reachable (tunnel unavailable); next try at %s" % (record.get("name"),
                                                                                         iso(when)))
                continue
            record.update(state="pending", detail="Installing.")
            self.save(True)
            self.log("iPhone %s: installing the kept build of %s" % (record.get("name"), release[:12]))
            status, out, err = self.env.run(["xcrun", "devicectl", "device", "install", "app", "--device",
                                             record["udid"], "--timeout", "240", kept["app"]], INSTALL_TIMEOUT)
            self.tick()
            if status == 0:
                self.phone_installed(record, release)
            elif status == 124:
                self.phone_failed(record, "the install timed out")
            else:
                self.phone_failed(record, "the install failed: %s" % (first_error(out + "\n" + err) or
                                                                       "devicectl exited %d" % status))
            self.save(True)

    def iphone_pass(self, release, built):
        """The iPhones that don't have the release yet: from the kept copy, else by building it (iphone part)."""
        kept = self.kept_build(release)
        if kept is not None:
            self.install_kept(release, kept)
            return
        if built or not self.iphone_build_needed(release) or not due(self.state["iphone_build"], self.now):
            return
        if self.battery_low():
            for phone in self.state["iphones"]:
                if phone.get("commit") != release:
                    phone.update(state="pending", detail="Waiting for the Mac to charge before building.")
            return
        folder = os.path.join(self.files["builds"], release)
        for phone in self.state["iphones"]:
            if phone.get("commit") != release and phone.get("retry", True):
                phone.update(state="pending", detail="Building the iPhone app.")
        self.save(True)
        status, rows, log = self.deploy(["--branch", self.branch, "--expect", release, "--xcode-signing", "iphone", "--keep-iphone",
                                         folder, "--no-launch"])
        self.apply_iphones(release, rows, status, log)

    # ---------------------------------------------------------------- Apple TVs

    def tv(self, udid, name=None):
        return self.phone(udid, name, "appletvs")

    def tv_build_there(self, udid):
        """(installed, build, None): whether Woodruff Family is on that Apple TV and which build of it; (False,
        None, why) when the Apple TV can't be asked."""
        tmp = tempfile.mkdtemp(prefix="woodruff-tv.")
        try:
            path = os.path.join(tmp, "apps.json")
            status, out, err = self.env.run(["xcrun", "devicectl", "device", "info", "apps", "--device", udid,
                                             "--bundle-id", TV_BUNDLE_ID, "--json-output", path], TV_ASK_TIMEOUT)
            doc = read_json(path)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        if status == 124:
            return False, None, "asking it which build it has timed out"
        if status != 0:
            return False, None, "couldn't ask it which build it has: %s" % (first_error(out + "\n" + err) or
                                                                             "devicectl exited %d" % status)
        installed, build = tv_app_build(doc, out)
        return installed, build, None

    def tv_film(self, udid):
        """(True or False, None): whether a film is on screen on that Apple TV now; (None, why) when it can't be
        told. The app keeps a note in its settings while a film is open (film_on_screen): the settings file is
        copied off the Apple TV, the note read, and the copy removed."""
        tmp = tempfile.mkdtemp(prefix="woodruff-tv.")
        try:
            path = os.path.join(tmp, "settings.plist")
            status, out, err = self.env.run(["xcrun", "devicectl", "device", "copy", "from", "--device", udid,
                                             "--domain-type", "appDataContainer", "--domain-identifier", TV_BUNDLE_ID,
                                             "--source", TV_SETTINGS, "--destination", path], TV_ASK_TIMEOUT)
            if status == 124:
                return None, "asking it whether a film is playing timed out"
            if status != 0:
                return None, "couldn't ask it whether a film is playing: %s" % (first_error(out + "\n" + err) or
                                                                                "devicectl exited %d" % status)
            # (devicectl has written the file itself, or a folder of that name with the file in it.)
            copies = [path] if os.path.isfile(path) else sorted(
                os.path.join(folder, name) for folder, _, names in os.walk(tmp) for name in names
                if name.endswith(".plist"))
            try:
                with open(copies[0], "rb") as handle:
                    settings = plistlib.load(handle)
            except Exception:  # noqa: BLE001 - nothing copied, or not a settings file
                return None, "couldn't read its settings to see whether a film is playing"
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return film_on_screen(settings, self.env.now()), None

    def tv_held(self, record, state, detail, seconds):
        when = self.now + timedelta(seconds=seconds)
        record.update(state=state, next_try=iso(when), detail=detail)
        return when

    def apply_tv_build(self, release, rows, status, log):
        """deploy.sh's tv-build result, and its tv rows for an Apple TV the profile doesn't list."""
        st, now = self.state, self.now
        tb = st["tv_build"]
        row = self.row(rows, "tv-build")
        kept = self.kept_build(release, self.files["tv_builds"])
        if row and row["status"] == "ok":
            tb.update(commit=release, state="ok", detail=sentence(row["detail"]))
            if kept is None:   # signed, but not kept: don't build again right away
                tb["attempts"] = int(tb.get("attempts") or 0) + 1
                tb["next_try"] = iso(now + timedelta(seconds=backoff(tb["attempts"])))
            else:
                tb.update(attempts=0, next_try=None)
                # The Apple TVs this build is for are the ones paired now: forget the rest.
                udids = [device["udid"] for device in kept["devices"]]
                st["appletvs"] = [t for t in st["appletvs"] if t["udid"] in udids]
                for device in kept["devices"]:
                    self.tv(device["udid"], device["name"])
        elif row and row["status"] == "skipped":
            when = now + timedelta(seconds=NO_TV_WAIT)
            tb.update(commit=release, state="skipped", detail=sentence(row["detail"]), attempts=0, next_try=iso(when))
            st["appletvs"] = []
            self.log("Apple TVs: none to update (%s)" % row["detail"])
        else:
            detail = row["detail"] if row else self.stopped(status, log)
            tb["attempts"] = int(tb.get("attempts") or 0) + 1
            when = now + timedelta(seconds=backoff(tb["attempts"]))
            tb.update(commit=release, state="failed", detail=sentence(detail), next_try=iso(when))
            for record in st["appletvs"]:
                if record.get("commit") != release:
                    record.update(state="failed", next_try=iso(when),
                                  detail="The Apple TV build failed: %s Next try at %s." % (sentence(detail),
                                                                                           clock(when)))
            self.log("Apple TV build: failed (try %d, next at %s): %s" % (tb["attempts"], iso(when),
                                                                         one_line(detail, 300)))
        for row in rows:
            if row["part"] == "tv" and row["target"] and row["status"] == "skipped":
                record = self.tv(row["target"], name_in(row["detail"]))
                record.update(state="failed", retry=False, next_try=None,
                              detail=sentence(without_name(row["detail"], record.get("name"))))
                self.log("Apple TV %s: %s" % (record.get("name"), row["detail"]))

    def install_tvs(self, release, kept):
        """Installs the kept Apple TV app on each Apple TV that doesn't have this release and whose next try is
        due: one that can be reached, isn't on this build already, and has no film on screen. The app isn't opened
        afterwards (an Apple TV that's asleep stays asleep)."""
        now = self.now
        todo = []
        for device in kept["devices"]:
            record = self.tv(device["udid"], device["name"])
            if record.get("commit") == release and record.get("state") == "current":
                continue
            # Check for Updates Now asks every Apple TV at once, whatever its wait (never past a film, though).
            if not record.get("retry", True) or not (due(record, now) or self.requested_now()):
                continue
            todo.append(record)
        if not todo:
            return
        listed, error = self.list_devices("tvOS")
        if listed is None:
            self.state["last_error"] = "couldn't list the Apple TVs: %s" % error
            self.log(self.state["last_error"])
            for record in todo:
                record["next_try"] = iso(now + timedelta(seconds=UNREACHABLE_RETRY))
            return
        build = self.release_build()
        for record in todo:
            name, udid = record.get("name"), record["udid"]
            info = listed.get(udid)
            if info is None or info.get("pairing") not in (None, "", "paired"):
                self.tv_held(record, "pending", "Not paired with this Mac.", UNREACHABLE_RETRY)
                self.log("Apple TV %s: not paired with this Mac; skipped" % name)
                continue
            if info.get("tunnel") == "unavailable":
                self.phone_failed(record, "tunnel unavailable", "Apple TV")
                continue
            installed, there, error = self.tv_build_there(udid)
            self.tick()
            if error:
                self.phone_failed(record, error, "Apple TV")
                self.save(True)
                continue
            if installed and build is not None and there == build:
                self.phone_installed(record, release, "Apple TV", "already has")   # put there by hand
                self.save(True)
                continue
            if installed:
                film, error = self.tv_film(udid)
                self.tick()
                if film is None:
                    # Can't tell: left alone rather than risk a film.
                    self.phone_failed(record, error, "Apple TV")
                    self.save(True)
                    continue
                if film:
                    when = self.tv_held(record, "waiting", "A film is playing. It installs once the film is over.",
                                        TV_FILM_RETRY)
                    self.log("Apple TV %s: a film is playing; asked again at %s" % (name, iso(when)))
                    self.save(True)
                    continue
            record.update(state="pending", detail="Installing.")
            self.save(True)
            self.log("Apple TV %s: installing the kept build of %s" % (name, release[:12]))
            status, out, err = self.env.run(["xcrun", "devicectl", "device", "install", "app", "--device", udid,
                                             "--timeout", "240", kept["app"]], INSTALL_TIMEOUT)
            self.tick()
            if status == 0:
                # Up to date once the Apple TV says so itself (one that can't be asked now is taken at devicectl's
                # word).
                _, there, error = self.tv_build_there(udid)
                self.tick()
                if error is None and build is not None and there != build:
                    self.phone_failed(record, "devicectl installed it, but the Apple TV says it has %s" % (
                        "build %d" % there if there is not None else "no build of it"), "Apple TV")
                else:
                    self.phone_installed(record, release, "Apple TV")
            elif status == 124:
                self.phone_failed(record, "the install timed out", "Apple TV")
            else:
                self.phone_failed(record, "the install failed: %s" % (first_error(out + "\n" + err) or
                                                                       "devicectl exited %d" % status), "Apple TV")
            self.save(True)

    def tv_pass(self, release):
        """The Apple TVs paired with this Mac: the app is built and signed once per release (deploy.sh tv, kept in
        tv-builds/<commit>/ and installed nowhere), once the Mac app built from that release here, then installed
        on each Apple TV as it can be (install_tvs)."""
        if not self.appletv:
            return
        st = self.state
        tb = st["tv_build"]
        folder = os.path.join(self.files["tv_builds"], release)
        kept = self.kept_build(release, self.files["tv_builds"])
        if kept is None:
            if not self.mac_current(release):
                return   # what doesn't build here isn't sent to the Apple TVs either
            if not (due(tb, self.now) or (tb.get("state") == "skipped" and self.requested_now())):
                return
            if self.battery_low():
                return
            listed, error = self.list_devices("tvOS")
            if listed is None:
                st["last_error"] = "couldn't list the Apple TVs: %s" % error
                self.log(st["last_error"])
                return
            if not listed:
                when = self.now + timedelta(seconds=NO_TV_WAIT)
                tb.update(commit=release, state="skipped", detail="No Apple TV is paired with this Mac.", attempts=0,
                          next_try=iso(when))
                if st["appletvs"]:
                    self.log("Apple TVs: none is paired with this Mac any more")
                st["appletvs"] = []
                return
            for udid in sorted(listed):
                record = self.tv(udid, listed[udid].get("name"))
                if record.get("commit") != release and record.get("retry", True):
                    record.update(state="pending", detail="Building the Apple TV app.")
            self.save(True)
            status, rows, log = self.deploy(["--branch", self.branch, "--expect", release, "--xcode-signing", "tv",
                                             "--keep-tv", folder])
            self.apply_tv_build(release, rows, status, log)
            self.save(True)
            kept = self.kept_build(release, self.files["tv_builds"])
        if kept is not None:
            self.install_tvs(release, kept)

    # ---------------------------------------------------------------- roles

    def hub(self, release):
        st, now = self.state, self.now
        mac, share = st["mac"], st["share"]
        mac_ok = self.mac_current(release)
        share_ok = share.get("commit") == release and share.get("state") == "ok"
        built = False
        if mac_ok:
            self.set_mac("current", "Up to date")
        if not (mac_ok and share_ok):
            if mac_ok:
                if due(share, now):
                    self.hub_share(release)   # only the iCloud copy is missing: no rebuild, the app isn't quit
            elif not due(mac, now):
                pass   # its failure detail stays, with the next try
            elif self.battery_hold() or self.postponed_for_use():
                pass
            else:
                built = self.hub_deploy(release)
        self.iphone_pass(release, built)
        self.tv_pass(release)
        self.testflight_pass(release)
        tf = st["testflight"]
        tf_ok = not self.testflight or (tf.get("commit") == release and tf.get("state") in ("ok", "skipped"))
        if mac_ok and share_ok and tf_ok and not any(p.get("commit") != release and p.get("retry", True)
                                           for p in st["iphones"] + st["appletvs"]):
            self.log("up to date: %s, build %s" % (release[:12], self.release_build() or "?"))

    def hub_deploy(self, release):
        """mac share, plus iphone when the iPhones need a build and it's due. True if the iPhones were built."""
        st = self.state
        with_iphone = (self.kept_build(release) is None and self.iphone_build_needed(release) and
                       due(st["iphone_build"], self.now))
        # The hub is the one Mac that signs: Xcode's automatic signing with the team's (paid) account.
        args = ["--branch", self.branch, "--expect", release, "--xcode-signing", "mac", "share"]
        if with_iphone:
            args += ["iphone", "--keep-iphone", os.path.join(self.files["builds"], release), "--no-launch"]
            for phone in st["iphones"]:
                if phone.get("commit") != release and phone.get("retry", True):
                    phone.update(state="pending", detail="Building the iPhone app.")
        self.set_mac("updating", "Building and installing %s" % self.build_words())
        self.save(True)
        status, rows, log = self.deploy(args, idle_until=self.courtesy_deadline())
        self.refresh_mac()
        mac, share = st["mac"], st["share"]
        row = self.row(rows, "mac")
        if row and row["status"] == "installed":
            self.mac_installed(release, mac, row["detail"])
        else:
            self.mac_failed(release, mac, row["detail"] if row else self.stopped(status, log))
        self.record_share(release, rows, status, log)
        if with_iphone:
            self.apply_iphones(release, rows, status, log)
        self.save(True)
        return with_iphone

    def testflight_pass(self, release):
        """Uploads the release to TestFlight once the Mac app built from it here (so it compiles)."""
        tf = self.state["testflight"]
        if not self.testflight or (tf.get("commit") == release and tf.get("state") == "ok"):
            return
        if not self.mac_current(release):
            return
        # Without an app in App Store Connect it says skipped: looked at again every few hours (or at Check Now), not
        # at every release, so a family that never sets TestFlight up doesn't archive every build for nothing.
        new_release = tf.get("commit") != release and tf.get("state") != "skipped"
        if not (new_release or due(tf, self.now) or self.requested_now()):
            return
        if self.battery_low():
            return
        tf.update(commit=release, state="uploading", detail="Uploading %s to TestFlight." % self.build_words())
        self.save(True)
        status, rows, log = self.deploy(["--branch", self.branch, "--expect", release, "--xcode-signing", "testflight"])
        row = self.row(rows, "testflight")
        if row and row["status"] == "ok":
            tf.update(state="ok", detail=sentence(row["detail"]), attempts=0, next_try=None)
            self.log("testflight: %s" % one_line(row["detail"], 300))
        elif row and row["status"] == "skipped":
            when = self.now + timedelta(seconds=SKIPPED_TESTFLIGHT_WAIT)
            tf.update(state="skipped", detail=sentence(row["detail"]), attempts=0, next_try=iso(when))
            self.log("testflight: skipped (next look at %s): %s" % (iso(when), one_line(row["detail"], 300)))
        else:
            tf["attempts"] = int(tf.get("attempts") or 0) + 1
            when = self.now + timedelta(seconds=backoff(tf["attempts"]))
            detail = row["detail"] if row else self.stopped(status, log)
            tf.update(state="failed", next_try=iso(when),
                      detail="%s. Next try at %s." % (sentence(detail).rstrip("."), clock(when)))
            self.log("testflight: failed (next at %s): %s" % (iso(when), one_line(detail, 300)))
        self.save(True)

    def record_share(self, release, rows, status, log):
        """deploy.sh's share result."""
        share = self.state["share"]
        row = self.row(rows, "share")
        if row and row["status"] == "ok":
            share.update(commit=release, state="ok", detail="Shared in iCloud Drive.", attempts=0, next_try=None)
        else:
            share["attempts"] = int(share.get("attempts") or 0) + 1
            when = self.now + timedelta(seconds=backoff(share["attempts"]))
            detail = row["detail"] if row else self.stopped(status, log)
            share.update(commit=release, state="failed" if not row or row["status"] == "failed" else None,
                         next_try=iso(when), detail="%s. Next try at %s." % (sentence(detail).rstrip("."), clock(when)))
            self.log("share: %s (next at %s): %s" % (row["status"] if row else "no result", iso(when),
                                                     one_line(detail, 300)))

    def hub_share(self, release):
        """Shares the Mac app installed here (it's this release's) without building it again."""
        self.save(True)
        status, rows, log = self.deploy(["--branch", self.branch, "--expect", release, "share"])
        self.record_share(release, rows, status, log)
        self.save(True)

    def follower(self, release):
        st, now = self.state, self.now
        if self.mac_current(release):
            self.set_mac("current", "Up to date")
            self.log("up to date: %s, build %s" % (release[:12], self.release_build() or "?"))
            return
        if self.postponed_for_use():
            return
        shared = st["shared"]
        if due(shared, now):
            self.set_mac("updating", "Looking for %s in iCloud Drive" % self.build_words())
            self.save(True)
            status, rows, log = self.deploy(["--branch", self.branch, "--expect", release, "mac-shared", "--wait", "0"],
                                            idle_until=self.courtesy_deadline())
            self.refresh_mac()
            row = self.row(rows, "mac-shared")
            if row and row["status"] == "installed":
                if self.mac_installed(release, shared, row["detail"]):
                    shared["detail"] = ""
                    return
            elif row and row["status"] == "waiting":
                shared["detail"] = row["detail"]
                self.set_mac("waiting", "Waiting for %s to arrive in iCloud Drive" % self.build_words())
                self.log("Mac: waiting for the shared build of %s" % release[:12])
            else:
                shared["detail"] = row["detail"] if row else self.stopped(status, log)
                self.mac_failed(release, shared, shared["detail"])
        if not self.fallback:
            return
        seen = parse_iso((st.get("release") or {}).get("seen_at")) or now
        attempts = int(shared.get("attempts") or 0)
        if attempts >= 3 or (attempts > 0 and unusable_share(shared.get("detail"))):
            why = "the shared build can't be used"
        elif self.now >= seen + timedelta(seconds=FALLBACK_AFTER):
            why = "no shared build arrived within %d minutes" % (FALLBACK_AFTER // 60)
        else:
            return
        build = st["build"]
        if not due(build, self.now) or self.battery_hold():
            return
        self.set_mac("updating", "Building %s on this Mac (%s)" % (self.build_words(), why))
        self.log("Mac: building here: %s" % why)
        self.save(True)
        # Shared too, so Mac Studio 2 isn't left waiting when the Mac Studio can't make one.
        status, rows, log = self.deploy(["--branch", self.branch, "--expect", release, "mac", "share"],
                                        idle_until=self.courtesy_deadline())
        self.refresh_mac()
        row = self.row(rows, "mac")
        if row and row["status"] == "installed":
            self.mac_installed(release, build, row["detail"])
        else:
            self.mac_failed(release, build, row["detail"] if row else self.stopped(status, log))

    # ---------------------------------------------------------------- one check

    def run(self):
        st = self.state
        st["last_check"] = iso(self.now)
        st["last_error"] = None
        self.refresh_mac()
        self.save(True)
        commit, error = self.find_release()
        if error:
            st["last_error"] = error
            self.log("couldn't check for a release: %s" % error)
            return self.finish()
        if commit is None:
            st["release"] = None
            self.set_mac("current", "No release yet")
            self.log("no release yet: origin has no %s branch" % self.branch)
            return self.finish()
        if not self.learn_release(commit):
            return self.finish()
        release = st["release"]["commit"]
        problem = self.release_problem(release)
        if problem:
            st["last_error"] = ("release %s isn't installed: %s, and installing it would stop this Mac updating"
                                % (release[:12], problem))
            self.set_mac("failed" if not self.mac_current(release) else "current", st["last_error"])
            self.log(st["last_error"])
            return self.finish()
        self.refresh_mac()
        if self.role == "hub":
            self.hub(release)
        else:
            self.follower(release)
        self.prune_builds(release)
        if self.requested_now():
            try:
                os.remove(self.files["request"])
            except OSError:
                pass
        return self.finish()

    def finish(self):
        self.save(False)
        return 0

    def prune_builds(self, release):
        """Keeps only builds/<the release> and tv-builds/<the release>: other folders in those two, and nothing
        outside them, are removed."""
        for folder, what in ((self.files["builds"], "build"), (self.files["tv_builds"], "Apple TV build")):
            try:
                names = os.listdir(folder)
            except OSError:
                continue
            for name in names:
                path = os.path.join(folder, name)
                if name == release or os.path.islink(path) or not os.path.isdir(path):
                    continue
                shutil.rmtree(path, ignore_errors=True)
                self.log("removed the kept %s %s" % (what, name[:12]))

    def interrupted(self):
        mac = self.state["mac"]
        if mac.get("state") == "updating":
            self.set_mac("waiting", "Interrupted; trying again at the next check")
        self.state["last_error"] = "stopped before it finished (logging out or shutting down?)"
        try:
            self.save(False)
        except Exception:  # noqa: BLE001 - nothing more to do while being stopped
            pass

    def crashed(self, text):
        last = [line for line in text.strip().splitlines() if line.strip()][-1:] or ["unknown error"]
        self.state["last_error"] = "updater.py failed: %s" % one_line(last[0], 300)
        append_log(self.env, "%s updater.py failed:\n%s" % (iso(self.env.now()), text.rstrip()))
        try:
            self.save(False)
        except Exception:  # noqa: BLE001
            pass

    def on_term(self, signum, frame):
        child = self.env.child
        if child is not None:
            self.env.stop(child, grace=5)
        raise SystemExit(128 + signum)


# ------------------------------------------------------------------------------------------------ commands


def cmd_run(env, args):
    files = paths(env)
    fd = take_lock(files["lock"])
    if fd is None:
        append_log(env, "%s another check is still running; this one stops here" % iso(env.now()))
        if args.verbose:
            print("Another check is still running; this one stops here.")
        return 0
    try:
        config, error = load_config(env)
        if config is None:
            sys.stderr.write("The Woodruff Family updater %s\n" % error)
            return 2
        updater = Updater(env, config, args.verbose)
        previous = signal.signal(signal.SIGTERM, updater.on_term)
        try:
            status = updater.run()
            for _ in range(env.quick_looks):
                env.sleep(QUICK_LOOK_SECONDS)
                commit, error = updater.find_release()
                known = (updater.state.get("release") or {}).get("commit")
                # Again for a new release, or (on a follower) for the shared build it's waiting for: it may have
                # arrived in iCloud Drive since.
                # Or someone pressed Check for Updates Now meanwhile.
                again = commit != known or updater.requested_now() or updater.shared_arrived(commit)
                if error or not commit or not again:
                    continue
                signal.signal(signal.SIGTERM, previous)
                updater = Updater(env, config, args.verbose)
                signal.signal(signal.SIGTERM, updater.on_term)
                status = updater.run()
            return status
        except SystemExit:
            updater.interrupted()
            raise
        except Exception:  # noqa: BLE001 - recorded in the status for the app, then the next check tries again
            updater.crashed(traceback.format_exc())
            sys.stderr.write(traceback.format_exc())
            return 1
        finally:
            signal.signal(signal.SIGTERM, previous)
    finally:
        os.close(fd)


def bootstrap(env, plist_path):
    """launchctl bootstrap, a few times: right after a bootout launchd may not have let go of the old one yet."""
    message = ""
    for attempt in range(3):
        status, out, err = env.run([env.launchctl, "bootstrap", "gui/%d" % env.uid(), plist_path], 60)
        if status == 0:
            return True, ""
        message = one_line(err or out or "exit %d" % status, 300)
        if attempt < 2:
            env.sleep(2)
    return False, message


def cmd_install(env, args):
    if env.platform != "darwin" and not testing(env.environ):
        print("updater.py install sets up a macOS LaunchAgent: run it on one of the family's Macs.")
        return 1
    repo = repo_of(env.script)
    if repo is None:
        print("Can't find the Woodrufffamily checkout around %s." % env.script)
        return 1
    if args.interval < 60 or args.interval > 86400:
        print("--interval wants 60 to 86400 seconds, not %d." % args.interval)
        return 2
    status, out, err = env.run(["git", "-C", repo, "remote", "get-url", "origin"], 30)
    remote = out.strip()
    if status != 0 or not remote:
        print("The checkout %s has no origin remote to update from (%s)." % (repo, one_line(err or out, 200)))
        return 1
    fallback = bool(args.build_fallback)
    if fallback and args.role == "hub":
        print("Note: --build-fallback is for a follower; the hub always builds.")
        fallback = False
    files = paths(env)
    fd = take_lock(files["lock"])
    if fd is None:
        print(BUSY)
        return 1
    try:
        write_json(files["config"], {"role": args.role, "build_fallback": fallback, "repo": repo, "remote": remote,
                                     "branch": RELEASE_BRANCH, "interval": args.interval})
        os.makedirs(env.logs, exist_ok=True)
        write_plist(files["plist"], launchd_plist(env, repo, args.interval))
        env.run([env.launchctl, "bootout", service(env)], 60)   # fails when it isn't loaded yet; that's fine
    finally:
        os.close(fd)   # before bootstrap: RunAtLoad starts the first check right away, and it needs the lock
    ok, message = bootstrap(env, files["plist"])
    if args.role == "hub":
        role = "hub: builds the Mac and iPhone apps, shares the Mac build in iCloud Drive, installs on the iPhones"
    elif fallback:
        role = "follower: installs the hub's shared build, or builds here if none arrives within 30 minutes"
    else:
        role = "follower: installs the build the hub shares in iCloud Drive"
    minutes = args.interval // 60
    every = "every %d minutes" % minutes if args.interval % 60 == 0 else "every %d seconds" % args.interval
    print("Installed the Woodruff Family updater on this Mac." if ok else
          "Set up the Woodruff Family updater, but launchctl couldn't start it: %s" % message)
    print("  Role:     %s" % role)
    print("  Checkout: %s (origin %s)" % (repo, remote))
    print("  Checks:   origin's %s branch %s%s" % (RELEASE_BRANCH, every, ", starting now" if ok else ""))
    print("  Status:   %s  (python3 scripts/updater.py status)" % files["status"])
    print("  Log:      %s" % files["log"])
    print("  Agent:    %s" % files["plist"])
    if not ok:
        print("It starts at the next login. To start it now, run this again in Terminal on this Mac while logged in.")
    print("To remove it: python3 scripts/updater.py uninstall  (add --purge to delete its status, builds and logs)")
    return 0 if ok else 1


def cmd_uninstall(env, args):
    files = paths(env)
    fd = None
    if os.path.isdir(env.support):
        fd = take_lock(files["lock"])
        if fd is None:
            print(BUSY)
            return 1
    try:
        status, _, _ = env.run([env.launchctl, "bootout", service(env)], 60)
        print("Stopped the updater." if status == 0 else "The updater wasn't running.")
        if os.path.exists(files["plist"]):
            os.remove(files["plist"])
            print("Removed %s" % files["plist"])
        if args.purge:
            if os.path.isdir(env.support):
                shutil.rmtree(env.support, ignore_errors=True)
                print("Removed %s" % env.support)
            removed = 0
            for path in [files["log"], files["log"] + ".1", files["launchd_log"]] + \
                    glob.glob(os.path.join(env.logs, "deploy-*.log")):
                if os.path.isfile(path):
                    os.remove(path)
                    removed += 1
            if removed:
                print("Removed the updater's %d log file%s in %s" % (removed, "" if removed == 1 else "s", env.logs))
            try:
                os.rmdir(env.logs)
            except OSError:
                pass
    finally:
        if fd is not None:
            os.close(fd)
    return 0


def describe(doc):
    """status.json for people."""
    lines = []
    rel = doc.get("release")
    mac = doc.get("mac") or {}
    lines.append("Woodruff Family updater (%s)%s" % (doc.get("role") or "?",
                                                     ", checking now" if doc.get("running") else ""))
    if rel:
        subject = json.dumps(rel.get("subject") or "", ensure_ascii=False)
        lines.append("  Release:    build %s (%s) %s, seen %s" % (rel.get("build") or "?", short(rel.get("commit")),
                                                                 subject, local_time(rel.get("seen_at"))))
    else:
        lines.append("  Release:    none yet")
    lines.append("  This Mac:   %s, build %s (%s), installed %s. %s" % (
        mac.get("state") or "?", mac.get("build") or "?", short(mac.get("commit")), local_time(mac.get("updated_at")),
        mac.get("detail") or ""))
    share = doc.get("share") or {}
    if doc.get("role") == "hub":
        lines.append("  Shared:     %s. %s" % (share.get("state") or "not yet", share.get("detail") or ""))
    phones = doc.get("iphones") or []
    if doc.get("role") == "hub":
        if not phones:
            lines.append("  iPhones:    none known yet")
        for n, phone in enumerate(phones):
            label = "iPhones:    " if n == 0 else " " * 12
            lines.append("  %s%s: %s. %s" % (label, phone.get("name") or phone.get("udid"), phone.get("state") or "?",
                                              phone.get("detail") or ""))
        for n, tv in enumerate(doc.get("appletvs") or []):
            label = "Apple TVs:  " if n == 0 else " " * 12
            lines.append("  %s%s: %s. %s" % (label, tv.get("name") or tv.get("udid"), tv.get("state") or "?",
                                              tv.get("detail") or ""))
    lines.append("  Last check: %s" % local_time(doc.get("last_check")))
    lines.append("  Last error: %s" % (doc.get("last_error") or "none"))
    return [line.rstrip() for line in lines]


def cmd_status(env, args):
    files = paths(env)
    try:
        with open(files["status"], "rb") as handle:
            raw = handle.read().decode("utf-8", "replace")
        doc = json.loads(raw)
    except FileNotFoundError:
        print("No status yet: the updater hasn't run on this Mac. Install it with: python3 scripts/updater.py "
              "install --role hub|follower")
        return 1
    except (OSError, ValueError) as exc:
        print("Can't read %s: %s" % (files["status"], exc))
        return 1
    if args.json:
        sys.stdout.write(raw if raw.endswith("\n") else raw + "\n")
        return 0
    for line in describe(doc if isinstance(doc, dict) else {}):
        print(line)
    loaded = agent_loaded(env)
    print("  Agent:      %s" % ("loaded" if loaded else "not loaded (python3 scripts/updater.py install ...)"))
    try:
        with open(files["log"], encoding="utf-8", errors="replace") as handle:
            tail = handle.read().splitlines()[-20:]
    except OSError:
        tail = []
    if tail:
        print("")
        print("Last %d lines of %s:" % (len(tail), files["log"]))
        for line in tail:
            print("  " + line)
    return 0


def cmd_now(env, args):
    status, out, err = env.run([env.launchctl, "kickstart", service(env)], 30)
    if status == 0:
        print("Checking for an update now. See: python3 scripts/updater.py status")
        return 0
    if not agent_loaded(env):
        print("The updater isn't loaded on this Mac. Install it with: python3 scripts/updater.py install "
              "--role hub|follower")
        return 1
    print("launchctl kickstart %s failed: %s" % (service(env), one_line(err or out or "exit %d" % status, 300)))
    return 1


def cmd_wait_idle(env, args):
    """For deploy.sh: returns once nobody is using the Mac app, or at the time given (seconds since 1970)."""
    until = datetime.fromtimestamp(args.until, timezone.utc)
    said = False
    while env.now() < until and app_in_use(env):
        if not said:
            print("waiting while someone is using %s (until %s at the latest)" % (APP_NAME, clock(until)))
            sys.stdout.flush()
            said = True
        env.sleep(15)
    return 0


def main(argv=None, env=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    parser = argparse.ArgumentParser(prog="updater.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True

    p = sub.add_parser("install", help="set up the LaunchAgent on this Mac")
    p.add_argument("--role", required=True, choices=ROLES)
    p.add_argument("--build-fallback", action="store_true",
                   help="follower: build here when no shared build arrived within 30 minutes")
    p.add_argument("--interval", type=int, default=DEFAULT_INTERVAL, metavar="SECONDS")
    p.set_defaults(func=cmd_install)

    p = sub.add_parser("uninstall", help="remove the LaunchAgent")
    p.add_argument("--purge", action="store_true", help="also delete the status, kept builds and logs")
    p.set_defaults(func=cmd_uninstall)

    p = sub.add_parser("status", help="what's installed here, and what's left to do")
    p.add_argument("--json", action="store_true", help="print status.json")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("now", help="check for an update now")
    p.set_defaults(func=cmd_now)

    p = sub.add_parser("run", help="one check (what the LaunchAgent runs)")
    p.add_argument("--verbose", action="store_true", help="also print each decision")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("wait-idle", help="for deploy.sh: wait while the Mac app is in use")
    p.add_argument("--until", type=int, required=True, metavar="UNIXTIME")
    p.set_defaults(func=cmd_wait_idle)

    args = parser.parse_args(argv)
    return args.func(env or Env(), args)


if __name__ == "__main__":
    sys.exit(main())
