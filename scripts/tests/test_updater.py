"""Tests for scripts/updater.py. Every command it runs goes to FakeEnv, which plays git, deploy.sh, devicectl
(the iPhones and the Apple TVs), lsappinfo, ioreg, pmset and launchctl; files go to a temporary folder. Nothing
touches this Mac's ~/Library, /Applications, launchd or the network.

Run from the repository root: python3 -m unittest discover -s scripts/tests -p 'test_*.py'
"""

import hashlib
import importlib.util
import io
import json
import os
import subprocess
import plistlib
import re
import shutil
import stat
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("woodruff_updater", os.path.join(SCRIPTS, "updater.py"))
updater = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(updater)

NEW = hashlib.sha1(b"new release").hexdigest()
OLD = hashlib.sha1(b"old release").hexdigest()
NEWER = hashlib.sha1(b"newer release").hexdigest()
P1 = "00008150-001E68E80A32401C"
P2 = "00008150-0002615C3C87801C"
P3 = "00008110-000A1B2C3D4E5F60"
TV1 = "00008110-000131602193801E"
TV2 = "00008110-000E418C1E39801E"
T0 = datetime(2026, 11, 4, 12, 0, tzinfo=timezone.utc)
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
BUSY_ASN = "ASN:0x0-0x2b02b:"


def parse_deploy_args(args):
    opts = {"parts": [], "branch": None, "expect": None, "wait": None, "keep": None, "keep_tv": None,
            "no_launch": False, "results": None}
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("--branch", "--expect", "--wait", "--keep-iphone", "--keep-tv", "--results"):
            opts[{"--keep-iphone": "keep", "--keep-tv": "keep_tv"}.get(arg, arg[2:])] = args[i + 1]
            i += 2
            continue
        if arg == "--no-launch":
            opts["no_launch"] = True
        else:
            opts["parts"].append(arg)
        i += 1
    return opts


def all_ok(env, opts):
    """deploy.sh when everything works: what it would install, keep and report."""
    commit, rows, parts = opts["expect"], [], opts["parts"]
    if "mac" in parts:
        env.install_mac(commit)
        rows.append(("mac", "installed", commit, "installed and running, signed by ABCD (Apple Development: Blake)"))
    if "share" in parts:
        rows.append(("share", "ok", commit, "shared in iCloud Drive as Woodruff Family builds/Woodruff Family %s.zip"
                     % commit[:12]))
    if "mac-shared" in parts:
        env.install_mac(commit)
        rows.append(("mac-shared", "installed", commit, "installed and running, signed by ABCD on Mac Studio"))
    if "iphone" in parts:
        if opts["keep"]:
            env.keep_iphone(opts["keep"], commit)
        rows.append(("iphone-build", "ok", commit, "signed by ABCD (Apple Development: Blake), kept in %s"
                     % opts["keep"]))
        for device in env.devices:
            rows.append(("iphone", "installed", device["udid"], "%s: installed" % device["name"]))
    if "tv" in parts:
        env.keep_tv(opts["keep_tv"], commit)
        rows.append(("tv-build", "ok", commit, "signed by Xcode (team D8D94SXAG6), profile tvOS Team Provisioning "
                     "Profile: * (expires 2027-11-04), kept in %s" % opts["keep_tv"]))
    return rows


class FakeEnv(updater.Env):
    quick_looks = 0   # one check per run, as the tests expect

    def __init__(self, root, platform="darwin"):
        self.root = root
        self.repo = os.path.join(root, "repo")
        os.makedirs(os.path.join(self.repo, "scripts"))
        for name in ("deploy.sh", "signing.py", "updater.py"):
            with open(os.path.join(self.repo, "scripts", name), "w") as handle:
                handle.write("# stand-in\n")
        with open(os.path.join(self.repo, "project.yml"), "w") as handle:
            handle.write("name: WoodruffFamily\n")
        home, apps = os.path.join(root, "home"), os.path.join(root, "Applications")
        os.makedirs(home)
        os.makedirs(apps)
        updater.Env.__init__(self, home=home, applications=apps, platform=platform, uid=501,
                             script=os.path.join(self.repo, "scripts", "updater.py"),
                             environ={"PATH": "/usr/bin:/bin", "HOME": home}, launchctl="/bin/launchctl")
        self.gh = None                   # no GitHub tool unless a test gives one (the install link's)
        self.gh_view = 0                 # gh release view's status (not 0: the release isn't there yet)
        self.gh_fail = {}                # "create" or an uploaded file's name -> (status, output) to fail it
        self.gh_uploads = []             # each uploaded file's name and what was in it, in order
        self.clock = T0
        self.calls = []
        self.deploys = []
        self.slept = []
        self.release = NEW
        self.ls_remote = None            # (status, stderr) to fail; None: origin has self.release
        self.fetch_status = 0
        self.subjects = {NEW: "Pictures load once", OLD: "Settings in five categories", NEWER: "Weather on the Mac"}
        self.counts = {NEW: 1234, OLD: 1200, NEWER: 1240}
        self.tree = {"scripts/deploy.sh", "scripts/updater.py"}
        self.updater_source = "print('the released updater')\n"
        self.deploy = all_ok             # function(env, opts) -> rows
        self.deploy_status = 0
        self.devices = [{"udid": P1, "name": "Blake’s iPhone", "pairing": "paired", "tunnel": "connected"},
                        {"udid": P2, "name": "Mia's iPhone", "pairing": "paired", "tunnel": "connected"}]
        self.devices_status = 0
        self.install = {}                # UDID -> (status, output) for devicectl device install app
        self.tvs = [{"udid": TV1, "name": "Living Room", "pairing": "paired", "tunnel": "disconnected"},
                    {"udid": TV2, "name": "Extra Apple TV", "pairing": "paired", "tunnel": "disconnected"}]
        self.tvs_status = 0
        self.tv_has = {TV1: 1200, TV2: 1200}   # UDID -> the build of Woodruff Family there (None: not installed)
        self.tv_settings = {}            # UDID -> the app's settings there (where its film note is)
        self.tv_apps = {}                # UDID -> (status, output) to fail devicectl device info apps
        self.tv_copy = {}                # UDID -> (status, output) to fail devicectl device copy from every time,
                                         # or a list of them to fail that many tries (None: that try works)
        self.tv_files = {}               # UDID -> False: no settings file there; (status, output): the listing fails
        self.tv_installs = []            # (UDID, build) of each Apple TV install, in order
        self.tv_launches = []            # UDID of each Apple TV where Woodruff was opened again, in order
        self.tv_launch = {}              # UDID -> (status, output) for devicectl device process launch there
        self.front_bundle = "com.apple.finder"
        self.idle_ns = 600 * 10 ** 9
        self.lsappinfo_status = 0
        self.battery = "Now drawing from 'AC Power'\n"
        self.launchctl_status = {}       # subcommand -> status, or a list of statuses to give in turn

    # ------------------------------------------------------------------ the world

    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.clock += timedelta(seconds=seconds)

    def run(self, argv, timeout, cwd=None, env=None, output=None):
        if argv[-1] == "--help" and argv[1:2] == ["-I"] and os.path.basename(argv[2]) in ("updater.py", "signing.py"):
            # The release's scripts started, as the updater checks them: really run with this Python.
            r = subprocess.run([sys.executable] + argv[1:], capture_output=True, text=True, timeout=30)
            return r.returncode, r.stdout, r.stderr
        assert isinstance(argv, list) and argv and all(isinstance(a, str) for a in argv), argv
        assert timeout and timeout > 0, ("no timeout", argv)
        self.calls.append({"argv": list(argv), "timeout": timeout, "cwd": cwd, "env": dict(env or {}),
                           "output": output})
        name = os.path.basename(argv[0])
        if name == "git":
            return self.git(argv[1:])
        if name == "deploy.sh":
            return self.run_deploy(argv, output)
        if any(a.endswith("signing.py") for a in argv):
            assert "-I" in argv, argv
            if argv[-2:] == ["--platform", "tvOS"]:
                assert argv[-3] == "devices", argv
                return self.tvs_status, json.dumps(self.tvs), "" if self.tvs_status == 0 else "devicectl failed"
            assert argv[-1] == "devices", argv
            return self.devices_status, json.dumps(self.devices), "" if self.devices_status == 0 else "devicectl failed"
        if name == "xcrun" and argv[1:5] == ["devicectl", "device", "info", "apps"]:
            # Which build of the Apple TV app an Apple TV has.
            assert argv[5] == "--device" and argv[7:10] == ["--bundle-id", updater.TV_BUNDLE_ID, "--json-output"], argv
            if argv[6] in self.tv_apps:
                return self.tv_apps[argv[6]][0], self.tv_apps[argv[6]][1], ""
            build = self.tv_has.get(argv[6])
            apps = [] if build is None else [{"bundleIdentifier": updater.TV_BUNDLE_ID, "bundleVersion": str(build),
                                              "version": "1.0", "name": "Woodruff"}]
            with open(argv[10], "w") as handle:
                json.dump({"info": {"outcome": "success"}, "result": {"apps": apps, "deviceIdentifier": "x"}}, handle)
            return 0, "Apps installed:\n", ""
        if name == "xcrun" and argv[1:5] == ["devicectl", "device", "copy", "from"]:
            # The Apple TV app's settings file, copied off an Apple TV.
            assert argv[5] == "--device" and argv[7:13] == [
                "--domain-type", "appDataContainer", "--domain-identifier", updater.TV_BUNDLE_ID,
                "--source", "Library/Preferences/com.blakew316.woodruff.tv.plist"], argv
            assert argv[13] == "--destination" and not os.path.isdir(argv[14]), argv   # devicectl wants a file path
            failing = self.tv_copy.get(argv[6])
            if isinstance(failing, list):
                failing = failing.pop(0) if failing else None
            if failing is not None:
                return failing[0], failing[1], ""
            with open(argv[14], "wb") as handle:
                plistlib.dump(dict(self.tv_settings.get(argv[6], {}), **{"atv.name": "Apple TV"}), handle,
                              fmt=plistlib.FMT_BINARY)
            return 0, "File received from Device\n", ""
        if name == "xcrun" and argv[1:5] == ["devicectl", "device", "info", "files"]:
            # What's in the Apple TV app's own folder on an Apple TV.
            assert argv[5] == "--device" and argv[7:] == ["--domain-type", "appDataContainer", "--domain-identifier",
                                                           updater.TV_BUNDLE_ID, "--subdirectory", "Library"], argv
            listed = self.tv_files.get(argv[6])
            if isinstance(listed, tuple):
                return listed[0], listed[1], ""
            lines = ["Caches                                              Writable, Readable, Directory   96 bytes"]
            if listed is not False:
                lines.append("Preferences/com.blakew316.woodruff.tv.plist        Writable, Readable              55 KB")
            return 0, "\n".join(lines) + "\n", ""
        if name == "xcrun" and argv[1:5] == ["devicectl", "device", "process", "launch"]:
            # Woodruff opened again on an Apple TV.
            assert argv[5] == "--device" and argv[7:] == ["--timeout", "45", updater.TV_BUNDLE_ID], argv
            self.tv_launches.append(argv[6])
            status, out = self.tv_launch.get(argv[6], (0, "Launched application with com.blakew316.woodruff.tv\n"))
            return status, out, ""
        if name == "xcrun":
            assert argv[1:6] == ["devicectl", "device", "install", "app", "--device"], argv
            assert argv[7:9] == ["--timeout", "240"], argv
            status, out = self.install.get(argv[6], (0, "App installed:\n  bundleID: com.blakew316.woodruff\n"))
            if argv[6] in (TV1, TV2):
                with open(os.path.join(os.path.dirname(argv[9]), "build.json")) as handle:
                    build = json.load(handle)["build"]
                self.tv_installs.append((argv[6], build))
                if status == 0:
                    self.tv_has[argv[6]] = build
            return status, out, ""
        if self.gh and argv[0] == self.gh:
            assert argv[1] == "release" and argv[argv.index("--repo") + 1] == "Blakew316/Woodrufffamily", argv
            assert env == {"GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"}, env
            if argv[2] == "view":
                assert argv[3] == updater.LINK_TAG, argv
                return self.gh_view, "", "" if self.gh_view == 0 else "release not found"
            if argv[2] == "create":
                assert argv[3] == updater.LINK_TAG and "--latest=false" in argv, argv
                failing = self.gh_fail.get("create")
                return (failing[0], "", failing[1]) if failing else (0, "", "")
            assert argv[2:4] == ["upload", updater.LINK_TAG] and argv[5] == "--clobber", argv
            base = os.path.basename(argv[4])
            failing = self.gh_fail.get(base)
            if failing:
                return failing[0], "", failing[1]
            with open(argv[4], "rb") as handle:
                self.gh_uploads.append((base, handle.read()))
            return 0, "", ""
        if name == "lsappinfo":
            if self.lsappinfo_status:
                return self.lsappinfo_status, "", "lsappinfo: no connection"
            if argv[1] == "front":
                return 0, BUSY_ASN + "\n", ""
            assert argv[1:4] == ["info", "-only", "bundleid"] and argv[4] == BUSY_ASN, argv
            return 0, '"CFBundleIdentifier"="%s"\n' % self.front_bundle, ""
        if name == "ioreg":
            assert argv[1:] == ["-c", "IOHIDSystem"], argv
            return 0, '    | |   "HIDIdleTime" = %d\n' % self.idle_ns, ""
        if name == "pmset":
            assert argv[1:] == ["-g", "batt"], argv
            return 0, self.battery, ""
        if name == "launchctl":
            status = self.launchctl_status.get(argv[1], 0)
            if isinstance(status, list):
                status = status.pop(0) if len(status) > 1 else status[0]
            return status, "", "" if status == 0 else "Boot-out failed: 3: No such process"
        raise AssertionError("unexpected command %r" % argv)

    def git(self, args):
        if args[:1] == ["-C"]:
            args = args[2:]
        sub = args[0]
        if sub == "ls-remote":
            assert args == ["ls-remote", "--exit-code", "origin", "refs/heads/release"], args
            if self.ls_remote is not None:
                return self.ls_remote[0], "", self.ls_remote[1]
            return 0, "%s\trefs/heads/release\n" % self.release, ""
        if sub == "fetch":
            assert args == ["fetch", "--quiet", "origin", "+refs/heads/release:refs/remotes/origin/release"], args
            return self.fetch_status, "", "" if self.fetch_status == 0 else "fatal: unable to access origin"
        if sub == "rev-parse":
            return 0, self.release + "\n", ""
        if sub == "log":
            return 0, self.subjects.get(args[-1], "?") + "\n", ""
        if sub == "rev-list":
            return 0, "%d\n" % self.counts.get(args[-1], 1), ""
        if sub == "cat-file":
            return (0 if args[-1].split(":", 1)[1] in self.tree else 128), "", ""
        if sub == "show":
            return 0, self.updater_source, ""
        if sub == "remote":
            return 0, "https://github.com/Blakew316/Woodrufffamily.git\n", ""
        raise AssertionError(args)

    def run_deploy(self, argv, output):
        opts = parse_deploy_args(argv[1:])
        self.deploys.append(argv[1:])
        rows = self.deploy(self, opts)
        with open(opts["results"], "a", encoding="utf-8") as handle:
            for row in rows:
                handle.write("\t".join(row) + "\n")
        with open(output, "a") as handle:
            handle.write("fake deploy.sh %s\n" % " ".join(argv[1:]))
        return self.deploy_status, "", ""

    # ------------------------------------------------------------------ what deploy.sh leaves behind

    def install_mac(self, commit, count=None):
        contents = os.path.join(self.app, "Contents")
        os.makedirs(contents, exist_ok=True)
        info = {"CFBundleIdentifier": "com.woodruff.family.mac",
                "CFBundleVersion": str(count or self.counts.get(commit, 1))}
        if commit:
            info["WoodruffCommit"] = commit
        with open(os.path.join(contents, "Info.plist"), "wb") as handle:
            plistlib.dump(info, handle)

    def keep_iphone(self, folder, commit, devices=None, expires="2027-11-04T05:00:00Z"):
        os.makedirs(os.path.join(folder, "Woodruff Family.app"), exist_ok=True)
        meta = {"commit": commit, "build": self.counts.get(commit, 1), "signed_at": updater.iso(self.clock),
                "identity": "ABCD", "app_profile_uuid": "19912ee9", "app_profile_expires": expires,
                "devices": [{"udid": d["udid"], "name": d["name"]} for d in (devices or self.devices)]}
        with open(os.path.join(folder, "build.json"), "w") as handle:
            json.dump(meta, handle)

    def keep_tv(self, folder, commit, devices=None, expires="2027-11-04T05:00:00Z"):
        os.makedirs(os.path.join(folder, "Woodruff Family.app"), exist_ok=True)
        meta = {"commit": commit, "build": self.counts.get(commit, 1), "signed_at": updater.iso(self.clock),
                "identity": "XCODE AUTOMATIC SIGNING", "app_profile_uuid": "5e0f1c2d", "app_profile_expires": expires,
                "devices": [{"udid": d["udid"], "name": d["name"]} for d in (self.tvs if devices is None else devices)]}
        with open(os.path.join(folder, "build.json"), "w") as handle:
            json.dump(meta, handle)

    def on_screen(self, udid, seconds_ago):
        """The Apple TV app's note that Woodruff is the app on screen there, last written that long ago."""
        self.tv_settings.setdefault(udid, {})["open.crumb"] = {
            "build": "Build 1200", "at": (self.clock - timedelta(seconds=seconds_ago)).timestamp()}

    def film(self, udid, seconds_ago, stage="playing"):
        """The Apple TV app's note of a film open there, last written that long ago."""
        self.tv_settings[udid] = {"playing.crumb": {
            "title": "Avengers - Endgame", "stage": stage, "detail": "30 s in", "build": "Build 1200",
            "at": (self.clock - timedelta(seconds=seconds_ago)).timestamp()}}

    # ------------------------------------------------------------------ looking at it

    def names(self, since=0):
        return [os.path.basename(c["argv"][0]) for c in self.calls[since:]]


class UpdaterTest(unittest.TestCase):
    def setUp(self):
        # realpath: on macOS the temporary folder is under /var, a link to /private/var, and install resolves links
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="updater-test."))
        self.env = FakeEnv(self.tmp)
        self.support = self.env.support
        self.builds = os.path.join(self.support, "builds")
        self.results = os.path.join(self.support, "results.tsv")
        self.deploy_sh = os.path.join(self.env.repo, "scripts", "deploy.sh")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def configure(self, role="hub", fallback=False, testflight=False, appletv=False):
        updater.write_json(os.path.join(self.support, "config.json"), {
            "role": role, "build_fallback": fallback, "repo": self.env.repo, "testflight": testflight,
            "appletv": appletv,
            "remote": "https://github.com/Blakew316/Woodrufffamily.git", "branch": "release", "interval": 300})

    def main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = updater.main(list(argv), env=self.env)
        return status, out.getvalue(), err.getvalue()

    def run_once(self, minutes=None):
        if minutes is not None:
            self.env.clock = T0 + timedelta(minutes=minutes)
        status, out, err = self.main("run")
        self.assertEqual(status, 0, out + err)
        return self.status()

    def status(self):
        with open(os.path.join(self.support, "status.json")) as handle:
            return json.load(handle)

    def state(self):
        with open(os.path.join(self.support, "state.json")) as handle:
            return json.load(handle)

    def phone(self, doc, udid):
        for phone in doc["iphones"]:
            if phone["udid"] == udid:
                return phone
        self.fail("no iPhone %s in %s" % (udid, doc["iphones"]))

    def tv(self, doc, udid):
        for tv in doc["appletvs"]:
            if tv["udid"] == udid:
                return tv
        self.fail("no Apple TV %s in %s" % (udid, doc["appletvs"]))

    def tv_args(self, commit=NEW):
        return self.deploy_args("--branch", "release", "--expect", commit, "--xcode-signing", "tv", "--keep-tv",
                                os.path.join(self.support, "tv-builds", commit))

    def log_text(self):
        with open(os.path.join(self.env.logs, "updater.log"), encoding="utf-8") as handle:
            return handle.read()

    def deploy_args(self, *middle):
        return list(middle) + ["--results", self.results]

    def hub_args(self, commit=NEW, iphone=True):
        args = ["--branch", "release", "--expect", commit, "--xcode-signing", "mac", "share"]
        if iphone:
            args += ["iphone", "--keep-iphone", os.path.join(self.builds, commit), "--no-launch"]
        return self.deploy_args(*args)

    def busy(self, idle_seconds=10):
        self.env.front_bundle = "com.woodruff.family.mac"
        self.env.idle_ns = idle_seconds * 10 ** 9

    def at(self, minutes):
        return updater.iso(T0 + timedelta(minutes=minutes))


# ---------------------------------------------------------------------------------------------- run: basics


class Basics(UpdaterTest):
    def test_no_release_yet(self):
        self.configure("hub")
        self.env.ls_remote = (2, "")
        doc = self.run_once()
        self.assertIsNone(doc["release"])
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertEqual(doc["mac"]["detail"], "No release yet.")
        self.assertIsNone(doc["last_error"])
        self.assertFalse(doc["running"])
        self.assertEqual(self.env.deploys, [])
        self.assertEqual(self.env.names(), ["git"])

    def test_ls_remote_failure_is_the_last_error(self):
        self.configure("follower")
        self.env.ls_remote = (128, "fatal: unable to access 'https://github.com/': Could not resolve host")
        doc = self.run_once()
        self.assertIn("git ls-remote origin refs/heads/release failed (128)", doc["last_error"])
        self.assertIn("Could not resolve host", doc["last_error"])
        self.assertEqual(self.env.deploys, [])

    def test_fetch_failure_is_the_last_error(self):
        self.configure("hub")
        self.env.fetch_status = 128
        doc = self.run_once()
        self.assertIn("git fetch of the release branch failed", doc["last_error"])
        self.assertIsNone(doc["release"])
        self.assertEqual(self.env.deploys, [])

    def test_git_runs_in_the_checkout_without_prompts(self):
        self.configure("hub")
        self.run_once()
        gits = [c for c in self.env.calls if c["argv"][0] == "git"]
        self.assertTrue(gits)
        for call in gits:
            self.assertEqual(call["cwd"], self.env.repo)
            self.assertEqual(call["timeout"], 60)
        env = self.env.child_env()
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertTrue(env["PATH"].startswith("/usr/bin:/bin:"), env["PATH"])
        self.assertIn("/opt/homebrew/bin", env["PATH"].split(":"))

    def test_config_missing(self):
        status, out, err = self.main("run")
        self.assertEqual(status, 2)
        self.assertIn("isn't installed on this Mac", err)
        self.assertIn("updater.py install --role hub|follower", err)

    def test_held_lock(self):
        self.configure("hub")
        fd = updater.take_lock(os.path.join(self.support, "updater.lock"))
        self.assertIsNotNone(fd)
        try:
            status, out, err = self.main("run")
        finally:
            os.close(fd)
        self.assertEqual(status, 0)
        self.assertEqual(self.env.calls, [])
        self.assertFalse(os.path.exists(os.path.join(self.support, "status.json")))
        with open(os.path.join(self.env.logs, "updater.log")) as handle:
            self.assertIn("another check is still running", handle.read())
        # free again: the next one runs
        self.assertEqual(self.main("run")[0], 0)
        self.assertTrue(self.env.deploys)

    def test_unexpected_error_is_recorded(self):
        self.configure("hub")

        def boom(argv, timeout, **kw):
            raise RuntimeError("something odd")
        self.env.git = lambda args: boom(args, 1)
        status, out, err = self.main("run")
        self.assertEqual(status, 1)
        doc = self.status()
        self.assertEqual(doc["last_error"], "updater.py failed: RuntimeError: something odd")
        self.assertFalse(doc["running"])

    def test_release_without_an_updater_isnt_installed(self):
        self.configure("hub")
        self.env.tree = {"scripts/deploy.sh"}
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [])
        self.assertIn("it has no scripts/updater.py", doc["last_error"])
        self.assertEqual(doc["mac"]["state"], "failed")

    def test_release_whose_updater_doesnt_compile_isnt_installed(self):
        self.configure("follower")
        self.env.updater_source = "def broken(:\n    pass\n"
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [])
        self.assertIn("doesn't compile with this Mac's Python", doc["last_error"])
        # checked once per release
        before = len(self.env.calls)
        self.run_once(5)
        self.assertNotIn("show", [c["argv"][1] for c in self.env.calls[before:] if c["argv"][0] == "git"])

    def test_release_whose_updater_fails_when_it_runs_isnt_installed(self):
        # Compiles, but fails as soon as it runs: a newer Python's feature, or a missing import.
        self.configure("follower")
        self.env.updater_source = "import no_such_module_anywhere\n"
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [])
        self.assertIn("doesn't run with this Mac's Python", doc["last_error"])

    def test_rollback_is_installed_too(self):
        self.configure("hub")
        self.env.install_mac(NEW)     # what's installed is newer than the release
        self.env.release = OLD
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.hub_args(OLD)])
        self.assertEqual(doc["mac"]["commit"], OLD)
        self.assertEqual(doc["mac"]["build"], 1200)
        self.assertEqual(doc["mac"]["state"], "current")

    def test_new_release_starts_over(self):
        self.configure("hub")
        self.env.deploy = lambda env, opts: [("mac", "failed", opts["expect"], "the Mac app didn't build"),
                                             ("share", "skipped", opts["expect"], "not shared"),
                                             ("iphone-build", "failed", opts["expect"], "the iPhone app didn't build")]
        self.run_once()
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 1)        # waits 15 minutes
        self.env.release = NEWER
        self.env.deploy = all_ok
        doc = self.run_once(6)
        self.assertEqual(self.env.deploys[-1], self.hub_args(NEWER))
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertEqual(doc["release"]["seen_at"], self.at(6))


# ------------------------------------------------------------------------------------------------- the hub


class Hub(UpdaterTest):
    def test_testflight_uploads_each_release_once(self):
        self.configure("hub", testflight=True)

        def with_upload(env, opts):
            if opts["parts"] == ["--xcode-signing", "testflight"]:
                return [("testflight", "ok", opts["expect"], "Uploaded build 1234. Apple takes a few minutes to process it.")]
            return all_ok(env, opts)
        self.env.deploy = with_upload
        doc = self.run_once()
        self.assertEqual(self.env.deploys[-1], self.deploy_args("--branch", "release", "--expect", NEW,
                                                                "--xcode-signing", "testflight"))
        self.assertEqual(doc["testflight"]["state"], "ok")
        self.assertEqual(doc["testflight"]["commit"], NEW)
        before = len(self.env.deploys)
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), before)

    def test_testflight_without_an_app_looks_again_hours_later(self):
        self.configure("hub", testflight=True)

        def no_app(env, opts):
            if "testflight" in opts["parts"]:
                return [("testflight", "skipped", opts["expect"], "App Store Connect has no app for it yet")]
            return all_ok(env, opts)
        self.env.deploy = no_app
        doc = self.run_once()
        self.assertEqual(doc["testflight"]["state"], "skipped")
        before = len(self.env.deploys)
        self.run_once(60)
        self.assertEqual(len(self.env.deploys), before)
        self.run_once(6 * 60 + 1)
        self.assertEqual(len(self.env.deploys), before + 1)

    def test_testflight_failure_backs_off(self):
        self.configure("hub", testflight=True)

        def fails(env, opts):
            if "testflight" in opts["parts"]:
                return [("testflight", "failed", opts["expect"], "the upload failed: network")]
            return all_ok(env, opts)
        self.env.deploy = fails
        doc = self.run_once()
        self.assertEqual(doc["testflight"]["state"], "failed")
        self.assertIn("Next try at", doc["testflight"]["detail"])
        before = len(self.env.deploys)
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), before)
        self.run_once(16)
        self.assertEqual(len(self.env.deploys), before + 1)

    def test_new_release_runs_deploy_with_the_exact_arguments(self):
        self.configure("hub")
        doc = self.run_once()
        self.assertEqual(len(self.env.deploys), 1)
        call = [c for c in self.env.calls if c["argv"][0] == self.deploy_sh][0]
        self.assertEqual(call["argv"], [self.deploy_sh, "--branch", "release", "--expect", NEW, "--xcode-signing", "mac", "share",
                                        "iphone", "--keep-iphone", os.path.join(self.builds, NEW), "--no-launch",
                                        "--results", self.results])
        self.assertEqual(call["cwd"], self.env.repo)
        self.assertEqual(call["timeout"], 3 * 3600)
        self.assertRegex(call["output"], re.escape(self.env.logs) + r"/deploy-20261104T120000Z\.log$")
        # deploy.sh may wait up to 10 minutes, just before quitting the app, for it not to be in use
        self.assertEqual(call["env"]["WOODRUFF_DEPLOY_IDLE_UNTIL"], str(int((T0 + timedelta(minutes=10)).timestamp())))
        self.assertEqual(call["env"]["WOODRUFF_DEPLOY_BACKGROUND"], "1")
        self.assertEqual(doc["release"], {"commit": NEW, "build": 1234, "subject": "Pictures load once",
                                          "seen_at": self.at(0)})
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertEqual(doc["mac"]["commit"], NEW)
        self.assertEqual(doc["mac"]["build"], 1234)
        self.assertEqual(doc["mac"]["updated_at"], self.at(0))
        self.assertEqual(doc["share"], {"commit": NEW, "state": "ok", "detail": "Shared in iCloud Drive."})
        self.assertEqual([(p["udid"], p["state"], p["commit"]) for p in doc["iphones"]],
                         [(P1, "current", NEW), (P2, "current", NEW)])
        self.assertEqual(self.phone(doc, P1)["name"], "Blake’s iPhone")
        self.assertIsNone(self.phone(doc, P1)["next_try"])

    def test_nothing_runs_when_everything_is_current(self):
        self.configure("hub")
        self.run_once()
        before = len(self.env.calls)
        doc = self.run_once(5)
        later = self.env.calls[before:]
        self.assertEqual([c["argv"][:2] for c in later], [["git", "ls-remote"]])
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertIsNone(doc["last_error"])

    def test_results_go_into_the_status(self):
        self.configure("hub")
        self.env.devices.append({"udid": P3, "name": "Old iPad", "pairing": "paired", "tunnel": "connected"})

        def mixed(env, opts):
            commit = opts["expect"]
            env.install_mac(commit)
            env.keep_iphone(opts["keep"], commit, env.devices[:2])
            return [("iphone", "skipped", P3, "Old iPad: not installed, the provisioning profiles don't list it"),
                    ("mac", "installed", commit, "installed and running, signed by ABCD"),
                    ("share", "failed", commit, "not shared: iCloud Drive is off for this Mac's user"),
                    ("iphone-build", "ok", commit, "signed by ABCD, kept in %s" % opts["keep"]),
                    ("iphone", "installed", P1, "Blake’s iPhone: installed"),
                    ("iphone", "failed", P2, "Mia's iPhone: the install failed: ERROR: Developer Mode is disabled "
                                             "(log /tmp/x/iphone-install.log)")]
        self.env.deploy = mixed
        doc = self.run_once()
        later = updater.clock(T0 + timedelta(minutes=15))
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertEqual(doc["share"]["state"], "failed")
        self.assertEqual(doc["share"]["detail"],
                         "Not shared: iCloud Drive is off for this Mac's user. Next try at %s." % later)
        self.assertEqual(self.phone(doc, P1)["state"], "current")
        p2 = self.phone(doc, P2)
        self.assertEqual(p2["state"], "failed")
        self.assertEqual(p2["detail"], "The install failed: ERROR: Developer Mode is disabled "
                                       "(log /tmp/x/iphone-install.log). Next try at %s." % later)
        self.assertEqual(p2["next_try"], self.at(15))
        self.assertIsNone(p2["commit"])
        p3 = self.phone(doc, P3)
        self.assertEqual((p3["state"], p3["name"]), ("failed", "Old iPad"))
        self.assertEqual(p3["detail"], "Not installed, the provisioning profiles don't list it.")
        self.assertIsNone(p3["next_try"])
        # Only the share is tried again after 15 minutes, of the app already installed: nothing is rebuilt.
        self.env.deploy = all_ok
        self.run_once(10)
        self.assertEqual(len(self.env.deploys), 1)
        doc = self.run_once(15)
        self.assertEqual(self.env.deploys[-1], self.deploy_args("--branch", "release", "--expect", NEW, "share"))
        self.assertEqual(doc["share"]["state"], "ok")
        # The iPad the profiles don't list isn't tried again for this release.
        self.assertEqual(self.phone(doc, P3)["state"], "failed")

    def test_iphone_retries_backoff_and_unreachable(self):
        self.configure("hub")

        def first(env, opts):
            commit = opts["expect"]
            env.install_mac(commit)
            env.keep_iphone(opts["keep"], commit)
            return [("mac", "installed", commit, "installed and running"), ("share", "ok", commit, "shared"),
                    ("iphone-build", "ok", commit, "kept"),
                    ("iphone", "failed", P1, "Blake’s iPhone: the install failed: ERROR: Timed out waiting for the "
                                             "device to connect"),
                    ("iphone", "failed", P2, "Mia's iPhone: the install failed: ERROR: Developer Mode is disabled")]
        self.env.deploy = first
        doc = self.run_once()
        self.assertEqual((self.phone(doc, P1)["state"], self.phone(doc, P1)["next_try"]), ("unreachable", self.at(10)))
        self.assertEqual((self.phone(doc, P2)["state"], self.phone(doc, P2)["next_try"]), ("failed", self.at(15)))
        kept = os.path.join(self.builds, NEW, "Woodruff Family.app")

        def installs(since):
            return [c["argv"] for c in self.env.calls[since:] if c["argv"][0] == "xcrun"]

        # +5: nothing is due
        mark = len(self.env.calls)
        self.run_once(5)
        self.assertEqual(self.env.names(mark), ["git"])
        # +11: Blake's is due, but devicectl says it's away: no install tried
        self.env.devices[0]["tunnel"] = "unavailable"
        mark = len(self.env.calls)
        doc = self.run_once(11)
        self.assertEqual(installs(mark), [])
        self.assertIn("signing.py", " ".join(self.env.calls[mark + 1]["argv"]))
        self.assertEqual((self.phone(doc, P1)["state"], self.phone(doc, P1)["next_try"]), ("unreachable", self.at(21)))
        self.assertEqual(self.phone(doc, P1)["detail"], "Not reachable from this Mac. Next try at %s."
                         % updater.clock(T0 + timedelta(minutes=21)))
        # +16: Mia's is due and fails again: 30 minutes now
        self.env.install[P2] = (1, "ERROR: Failed to install the app on the device.\n  Developer Mode is disabled\n")
        mark = len(self.env.calls)
        doc = self.run_once(16)
        self.assertEqual(installs(mark), [["xcrun", "devicectl", "device", "install", "app", "--device", P2,
                                           "--timeout", "240", kept]])
        self.assertEqual(self.phone(doc, P2)["next_try"], self.at(46))
        self.assertIn("ERROR: Failed to install the app on the device", self.phone(doc, P2)["detail"])
        # +22: Blake's is back
        self.env.devices[0]["tunnel"] = "connected"
        mark = len(self.env.calls)
        doc = self.run_once(22)
        self.assertEqual([a[6] for a in installs(mark)], [P1])
        p1 = self.phone(doc, P1)
        self.assertEqual((p1["state"], p1["commit"], p1["updated_at"], p1["next_try"]),
                         ("current", NEW, self.at(22), None))
        # Mia's: 1 h, 2 h, 4 h, then every 8 h
        when = 46
        for wait in (60, 120, 240, 480, 480):
            doc = self.run_once(when)
            self.assertEqual(self.phone(doc, P2)["next_try"], self.at(when + wait))
            when += wait
        self.assertEqual(len(self.env.deploys), 1)     # never built again for this
        # Fixed on the phone: installed at the next try
        self.env.install.pop(P2)
        doc = self.run_once(when)
        self.assertEqual(self.phone(doc, P2)["state"], "current")

    def test_check_now_retries_an_iphone_still_waiting(self):
        self.configure("hub")

        def first(env, opts):
            commit = opts["expect"]
            env.install_mac(commit)
            env.keep_iphone(opts["keep"], commit)
            return [("mac", "installed", commit, "installed and running"), ("share", "ok", commit, "shared"),
                    ("iphone-build", "ok", commit, "kept"),
                    ("iphone", "installed", P1, "Blake’s iPhone: installed"),
                    ("iphone", "failed", P2, "Mia's iPhone: the install failed: ERROR: Developer Mode is disabled")]
        self.env.deploy = first
        doc = self.run_once()
        self.assertEqual(self.phone(doc, P2)["next_try"], self.at(15))
        # +5: not due yet, but Check for Updates Now was pressed: tried at once.
        request = updater.paths(self.env)["request"]
        os.makedirs(os.path.dirname(request), exist_ok=True)
        with open(request, "w"):
            pass
        stamp = (T0 + timedelta(minutes=5)).timestamp()
        os.utime(request, (stamp, stamp))
        mark = len(self.env.calls)
        doc = self.run_once(5)
        installs = [c["argv"] for c in self.env.calls[mark:] if c["argv"][0] == "xcrun"]
        self.assertEqual([a[6] for a in installs], [P2])
        self.assertEqual(self.phone(doc, P2)["state"], "current")

    def test_unpaired_iphone_is_skipped(self):
        self.configure("hub")

        def p2_fails(env, opts):
            rows = all_ok(env, opts)
            return [r if r[2] != P2 else ("iphone", "failed", P2, "Mia's iPhone: the install failed: ERROR: oops")
                    for r in rows]
        self.env.deploy = p2_fails
        self.run_once()
        self.env.devices = self.env.devices[:1]    # Mia's iPhone isn't paired any more
        mark = len(self.env.calls)
        doc = self.run_once(15)
        self.assertNotIn("xcrun", self.env.names(mark))
        p2 = self.phone(doc, P2)
        self.assertEqual((p2["state"], p2["detail"], p2["next_try"]), ("pending", "Not paired with this Mac.", self.at(25)))

    def test_kept_build_gone_builds_only_the_iphones(self):
        self.configure("hub")

        def p2_fails(env, opts):
            return [r if r[2] != P2 else ("iphone", "failed", P2, "Mia's iPhone: the install failed: ERROR: oops")
                    for r in all_ok(env, opts)]
        self.env.deploy = p2_fails
        self.run_once()
        shutil.rmtree(os.path.join(self.builds, NEW))
        self.env.deploy = all_ok
        doc = self.run_once(5)
        self.assertEqual(self.env.deploys[-1], self.deploy_args("--branch", "release", "--expect", NEW, "--xcode-signing", "iphone",
                                                                "--keep-iphone", os.path.join(self.builds, NEW),
                                                                "--no-launch"))
        self.assertEqual(self.phone(doc, P2)["state"], "current")

    def test_no_iphones_paired_isnt_built_again(self):
        self.configure("hub")
        self.env.deploy = lambda env, opts: [r for r in all_ok(env, dict(opts, parts=["mac", "share"]))] + [
            ("iphone-build", "skipped", opts["expect"], "no iPhone is paired with this Mac")]
        doc = self.run_once()
        self.assertEqual(doc["iphones"], [])
        self.run_once(5)
        self.run_once(60)
        self.assertEqual(len(self.env.deploys), 1)

    def test_iphone_build_failure_backs_off(self):
        self.configure("hub")
        self.env.deploy = lambda env, opts: [r for r in all_ok(env, dict(opts, parts=["mac", "share"]))] + [
            ("iphone-build", "failed", opts["expect"], "The iPhone app profile expired on 2027-11-04")]
        self.run_once()
        self.run_once(14)
        self.assertEqual(len(self.env.deploys), 1)
        self.run_once(15)
        self.assertEqual(self.env.deploys[-1][3:6], [NEW, "--xcode-signing", "iphone"])
        self.run_once(44)
        self.assertEqual(len(self.env.deploys), 2)
        self.run_once(45)
        self.assertEqual(len(self.env.deploys), 3)

    def test_deploy_that_says_nothing(self):
        self.configure("hub")
        self.env.deploy = lambda env, opts: []
        self.env.deploy_status = 2
        doc = self.run_once()
        self.assertEqual(doc["mac"]["state"], "failed")
        self.assertIn("Deploy.sh stopped (exit 2) without saying how it went; see %s" % self.env.logs,
                      doc["mac"]["detail"])
        self.assertEqual(doc["share"]["state"], "failed")
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 1)

    def test_installed_but_the_app_says_otherwise(self):
        self.configure("hub")
        self.env.install_mac(OLD)

        def claims(env, opts):   # says it installed, but the app in /Applications is still the old one
            return [("mac", "installed", opts["expect"], "installed and running"), ("share", "ok", opts["expect"], "")]
        self.env.deploy = claims
        doc = self.run_once()
        self.assertEqual(doc["mac"]["state"], "failed")
        self.assertIn("the app says it's %s" % OLD[:7], doc["mac"]["detail"])
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 1)    # no rebuilding in a loop

    def test_keeps_only_the_releases_build(self):
        self.configure("hub")
        os.makedirs(os.path.join(self.builds, OLD, "Woodruff Family.app"))
        with open(os.path.join(self.builds, "notes.txt"), "w") as handle:
            handle.write("not a build\n")
        self.run_once()
        self.assertEqual(sorted(os.listdir(self.builds)), sorted([NEW, "notes.txt"]))

    def test_courtesy_postpones_the_mac_but_not_the_iphones(self):
        self.configure("hub")
        self.busy()
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.deploy_args("--branch", "release", "--expect", NEW, "--xcode-signing", "iphone",
                                                             "--keep-iphone", os.path.join(self.builds, NEW),
                                                             "--no-launch")])
        self.assertEqual(doc["mac"]["state"], "postponed")
        self.assertIn("Woodruff Family isn't in use", doc["mac"]["detail"])
        self.assertEqual(self.phone(doc, P1)["state"], "current")
        self.env.idle_ns = 300 * 10 ** 9       # nobody touched it for 5 minutes
        doc = self.run_once(5)
        self.assertEqual(self.env.deploys[-1], self.hub_args(iphone=False))
        self.assertEqual(doc["mac"]["state"], "current")

    # ------------------------------------------------------------------ the install link

    def link_ready(self):
        """A hub with GitHub's tool, whose deploy.sh keeps an iPhone app that says which build it is."""
        self.configure("hub")
        self.env.gh = "/opt/homebrew/bin/gh"

        def deploy(env, opts):
            rows = all_ok(env, opts)
            if opts["keep"]:
                with open(os.path.join(opts["keep"], "Woodruff Family.app", "Info.plist"), "wb") as handle:
                    plistlib.dump({"CFBundleIdentifier": "com.blakew316.woodruff", "CFBundleVersion": "1234",
                                   "CFBundleShortVersionString": "1.0"}, handle)
            return rows
        self.env.deploy = deploy

    def gh_calls(self):
        return [c["argv"][2] for c in self.env.calls if c["argv"][0] == self.env.gh]

    def test_install_link_published(self):
        self.link_ready()
        self.env.gh_view = 1                      # its GitHub release isn't there yet: made first
        doc = self.run_once()
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertEqual(doc["link"], {"commit": NEW, "state": "ok", "detail": "Published."})
        # The app first, then what points at it, and last the note that says a newer build is there.
        self.assertEqual([name for name, _ in self.env.gh_uploads],
                         ["WoodruffFamily.ipa", "manifest.plist", "latest.json"])
        # The .ipa is the kept app under Payload and nothing else.
        with zipfile.ZipFile(io.BytesIO(self.env.gh_uploads[0][1])) as archive:
            self.assertEqual(sorted(archive.namelist()), ["Payload/Woodruff Family.app/",
                                                          "Payload/Woodruff Family.app/Info.plist"])
        self.assertEqual(self.gh_calls(), ["view", "create", "upload", "upload", "upload"])
        item = plistlib.loads(self.env.gh_uploads[1][1])["items"][0]
        self.assertEqual(item["assets"], [{
            "kind": "software-package",
            "url": "https://github.com/Blakew316/Woodrufffamily/releases/download/install-link/WoodruffFamily.ipa"}])
        self.assertEqual(item["metadata"], {"bundle-identifier": "com.blakew316.woodruff", "bundle-version": "1.0",
                                            "kind": "software", "title": "Woodruff Family"})
        latest = json.loads(self.env.gh_uploads[2][1].decode("utf-8"))
        self.assertEqual((latest["build"], latest["commit"], latest["subject"]), (1234, NEW, "Pictures load once"))
        self.assertEqual(latest["manifest"],
                         "https://github.com/Blakew316/Woodrufffamily/releases/download/install-link/manifest.plist")
        self.assertRegex(latest["published"], STAMP)
        self.assertIn("install link: published", self.log_text())
        self.assertIn("  Link:       ok", "\n".join(updater.describe(doc)))
        # Published once for a release: not again at the next check.
        self.run_once(5)
        self.assertEqual(len(self.env.gh_uploads), 3)

    def test_install_link_release_already_there(self):
        self.link_ready()
        self.run_once()
        self.assertEqual(self.gh_calls(), ["view", "upload", "upload", "upload"])

    def test_install_link_failure_doesnt_stop_the_update(self):
        self.link_ready()
        self.env.gh_fail["WoodruffFamily.ipa"] = (1, "HTTP 502: Bad Gateway")
        doc = self.run_once()
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertEqual(self.phone(doc, P1)["state"], "current")
        self.assertEqual(doc["link"]["state"], "failed")
        self.assertIn("Couldn't upload WoodruffFamily.ipa: HTTP 502", doc["link"]["detail"])
        self.assertIn("Next try at", doc["link"]["detail"])
        self.assertEqual(self.env.gh_uploads, [])
        self.assertIn("install link: failed", self.log_text())
        # Tried again once it's due, and published then.
        self.env.gh_fail = {}
        doc = self.run_once(120)
        self.assertEqual(doc["link"]["state"], "ok")
        self.assertEqual(len(self.env.gh_uploads), 3)

    def test_no_install_link_without_githubs_tool_or_when_turned_off(self):
        self.configure("hub")                     # no GitHub tool on this Mac
        doc = self.run_once()
        self.assertNotIn("link", doc)
        self.assertEqual(self.gh_calls(), [])
        self.assertNotIn("  Link:", "\n".join(updater.describe(doc)))

    def test_install_link_turned_off_in_config(self):
        self.link_ready()
        config = os.path.join(self.support, "config.json")
        with open(config) as handle:
            kept = json.load(handle)
        kept["install_link"] = False
        updater.write_json(config, kept)
        doc = self.run_once()
        self.assertNotIn("link", doc)
        self.assertEqual(self.gh_calls(), [])

    def test_battery_postpones_hub_builds(self):
        self.configure("hub")
        self.env.battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t22%; discharging; 1:02 remaining present: true\n"
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [])
        self.assertEqual(doc["mac"]["state"], "postponed")
        self.assertIn("battery", doc["mac"]["detail"])
        self.env.battery = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t23%; charging; present: true\n"
        self.run_once(5)
        self.assertEqual(self.env.deploys, [self.hub_args()])


# ------------------------------------------------------------------------------------------ the Apple TVs


class AppleTVs(UpdaterTest):
    """The hub keeps the Apple TVs paired with it on the release: the app is built once (deploy.sh tv, kept), then
    installed on each Apple TV over the network, never while a film is on screen there."""

    def setUp(self):
        super().setUp()
        self.configure("hub", appletv=True)
        self.tv_builds = os.path.join(self.support, "tv-builds")
        self.kept_app = os.path.join(self.tv_builds, NEW, "Woodruff Family.app")

    def tv_installs(self):
        return [c["argv"] for c in self.env.calls if c["argv"][:5] == ["xcrun", "devicectl", "device", "install", "app"]
                and c["argv"][6] in (TV1, TV2)]

    def asked(self, what, udid):
        """How many times that Apple TV was asked for its build ("info") or its settings ("copy")."""
        return len([c for c in self.env.calls if c["argv"][:4] == ["xcrun", "devicectl", "device", what]
                    and c["argv"][6] == udid])

    def test_built_once_and_installed_on_each_apple_tv(self):
        # What CoreDevice keeps on this Mac of the apps it installs (to send only the changes) is left alone: macOS
        # guards that folder, and nothing here may wait for a permission nobody is there to give.
        deltas = os.path.join(self.env.home, "Library", "Containers", "com.apple.CoreDevice.CoreDeviceService", "Data",
                              "Library", "Caches", "AppInstallationBinaryDeltas", "com.blakew316.woodruff.tv")
        os.makedirs(os.path.join(deltas, "22785a11", "Stashed"))
        doc = self.run_once()
        # The Mac and the iPhones first, then the Apple TV app: built with Xcode's signing, kept, installed nowhere.
        self.assertEqual(self.env.deploys, [self.hub_args(), self.tv_args()])
        self.assertEqual(self.tv_installs(), [
            ["xcrun", "devicectl", "device", "install", "app", "--device", TV1, "--timeout", "240", self.kept_app],
            ["xcrun", "devicectl", "device", "install", "app", "--device", TV2, "--timeout", "240", self.kept_app]])
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])
        for udid, name in ((TV1, "Living Room"), (TV2, "Extra Apple TV")):
            tv = self.tv(doc, udid)
            self.assertEqual((tv["name"], tv["state"], tv["commit"], tv["detail"]), (name, "current", NEW, "Up to date."))
            self.assertEqual(tv["updated_at"], self.at(0))
            self.assertIsNone(tv["next_try"])
        self.assertTrue(os.path.isdir(os.path.join(deltas, "22785a11", "Stashed")))
        # Never opened on the Apple TV afterwards (one that's asleep stays asleep).
        self.assertFalse([c for c in self.env.calls if "launch" in c["argv"]])
        log = self.log_text()
        self.assertIn("Apple TV Living Room: installing the kept build of %s" % NEW[:12], log)
        self.assertIn("Apple TV Extra Apple TV: installed %s" % NEW[:12], log)
        # Nothing more at the next check: everything is on the release.
        calls = len(self.env.calls)
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 2)
        self.assertEqual(self.env.names(calls), ["git"])
        self.assertIn("up to date: %s, build 1234" % NEW[:12], self.log_text())

    def test_woodruff_on_screen_is_opened_again_after_the_update(self):
        # Installing closes the app. Living Room had Woodruff on screen ten seconds ago: it's opened again there.
        # The other Apple TV has no such note (asleep, or on another app): nothing is opened on it.
        self.env.on_screen(TV1, 10)
        doc = self.run_once()
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])
        self.assertEqual(self.env.tv_launches, [TV1])
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.tv(doc, TV2)["state"], "current")
        log = self.log_text()
        self.assertIn("Apple TV Living Room: Woodruff was on screen, so it was opened again", log)
        self.assertNotIn("Apple TV Extra Apple TV: Woodruff was on screen", log)

    def test_woodruff_put_away_a_while_ago_is_not_opened(self):
        # A note that hasn't been renewed for two minutes: Woodruff isn't the app on screen any more.
        self.env.on_screen(TV1, 120)
        self.run_once()
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])
        self.assertEqual(self.env.tv_launches, [])

    def test_an_app_that_cant_be_opened_again_is_still_up_to_date(self):
        self.env.on_screen(TV1, 5)
        self.env.tv_launch[TV1] = (1, "ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002.)\n")
        doc = self.run_once()
        self.assertEqual(self.env.tv_launches, [TV1])
        tv = self.tv(doc, TV1)
        self.assertEqual((tv["state"], tv["commit"]), ("current", NEW))
        self.assertIn("Apple TV Living Room: Woodruff was on screen, but couldn't be opened again", self.log_text())

    def test_a_first_install_opens_nothing(self):
        # Never installed there: there was no Woodruff on screen to open again, whatever is read.
        self.env.tv_has[TV1] = None
        self.env.on_screen(TV1, 5)
        self.run_once()
        self.assertEqual(self.env.tv_launches, [])

    def test_left_alone_while_a_film_is_playing(self):
        self.env.film(TV1, 20)
        doc = self.run_once()
        tv = self.tv(doc, TV1)
        self.assertEqual(tv["state"], "waiting")
        self.assertEqual(tv["detail"], "A film is playing. It installs once the film is over.")
        self.assertEqual(tv["next_try"], self.at(4))
        self.assertIsNone(tv["commit"])
        # The other Apple TV isn't held up by it.
        self.assertEqual(self.tv(doc, TV2)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])
        self.assertIn("Apple TV Living Room: a film is playing", self.log_text())
        # Still playing five minutes on (the app renews its note every ten seconds): still left alone.
        self.env.clock = T0 + timedelta(minutes=5)
        self.env.film(TV1, 4)
        doc = self.run_once(5)
        self.assertEqual(self.tv(doc, TV1)["state"], "waiting")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])
        # The film was closed (the app removes its note): installed at the next check, without building again.
        self.env.tv_settings.pop(TV1)
        doc = self.run_once(10)
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234), (TV1, 1234)])
        self.assertEqual(len(self.env.deploys), 2)

    def test_check_now_doesnt_interrupt_a_film(self):
        self.env.film(TV1, 20)
        self.run_once()
        open(os.path.join(self.support, "check-now"), "w").close()
        self.env.clock = T0 + timedelta(minutes=1)
        self.env.film(TV1, 5)
        os.utime(os.path.join(self.support, "check-now"), (self.env.clock.timestamp(), self.env.clock.timestamp()))
        doc = self.run_once(1)
        # Asked again at once (its wait is skipped), and still left alone.
        self.assertEqual(self.asked("copy", TV1), 2)
        self.assertEqual(self.tv(doc, TV1)["state"], "waiting")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])

    def test_a_film_being_opened_counts(self):
        self.env.film(TV1, 2, stage="opening")
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "waiting")

    def test_a_film_left_open_in_an_app_put_away_doesnt_hold_it(self):
        # (The note stays in the settings when the app is put away with a film open, but is no longer renewed.)
        self.env.film(TV1, 2259)
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])

    def test_one_already_on_the_build_is_left_as_it_is(self):
        self.env.tv_has[TV1] = 1234   # installed by hand
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.tv(doc, TV1)["commit"], NEW)
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])
        self.assertEqual(self.asked("copy", TV1), 0)
        self.assertIn("Apple TV Living Room: already has %s" % NEW[:12], self.log_text())

    def test_one_without_the_app_gets_it(self):
        self.env.tv_has[TV1] = None
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])
        self.assertEqual(self.asked("copy", TV1), 0)   # no app there, so no film to ask about

    def test_one_that_cant_be_reached_is_tried_every_ten_minutes(self):
        self.env.tv_apps[TV1] = (1, "ERROR: The device is unavailable. (com.apple.dt.CoreDeviceError error 1.)")
        doc = self.run_once()
        tv = self.tv(doc, TV1)
        self.assertEqual(tv["state"], "unreachable")
        self.assertEqual(tv["next_try"], self.at(10))
        self.assertEqual(tv["detail"], "Not reachable from this Mac. Next try at %s." % updater.clock(T0 + timedelta(minutes=10)))
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])
        self.run_once(5)   # not due yet: not even asked
        self.assertEqual(self.asked("info", TV1), 1)
        self.env.tv_apps.clear()
        doc = self.run_once(10)
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(len(self.env.deploys), 2)

    def test_one_that_doesnt_answer_in_time(self):
        self.env.tv_apps[TV1] = (124, "")
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])

    TRANSFER = "ERROR: The specified file could not be transferred. (com.apple.dt.CoreDeviceError error 7000 (0x1B58))"

    def test_not_installed_when_it_cant_tell_whether_a_film_is_playing(self):
        self.env.tv_copy[TV1] = (1, self.TRANSFER)
        doc = self.run_once()
        tv = self.tv(doc, TV1)
        # Tried three times, two seconds apart; its settings file is there, so a film may be on: left alone, and
        # asked again at the next check (not a failure to wait longer and longer after).
        self.assertEqual(self.asked("copy", TV1), 3)
        self.assertEqual(self.env.slept, [2, 2])
        self.assertEqual(tv["state"], "unreachable")
        self.assertIn("Couldn't tell whether a film is playing there. Next try at ", tv["detail"])
        self.assertEqual(tv["next_try"], updater.iso(T0 + timedelta(seconds=4) + timedelta(minutes=4)))
        self.assertIsNone(tv["commit"])
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])
        self.assertIn("Apple TV Living Room: couldn't ask it whether a film is playing: ERROR: The specified file could "
                      "not be transferred.", self.log_text())
        # Still the same at the next check, and the one after: the wait doesn't grow.
        doc = self.run_once(5)
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        doc = self.run_once(10)
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])
        self.env.tv_copy.clear()
        doc = self.run_once(15)
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(len(self.env.deploys), 2)

    def test_a_copy_that_fails_once_is_tried_again_at_once(self):
        self.env.tv_copy[TV1] = [(1, self.TRANSFER)]
        doc = self.run_once()
        self.assertEqual(self.asked("copy", TV1), 2)
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])

    def test_a_copy_that_works_the_second_time_still_sees_the_film(self):
        self.env.tv_copy[TV1] = [(1, self.TRANSFER)]
        self.env.film(TV1, 5)
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "waiting")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])

    def test_an_apple_tv_where_the_app_was_never_opened_has_no_film(self):
        # No settings file to copy at all: nothing can be playing in an app that never ran.
        self.env.tv_copy[TV1] = (1, self.TRANSFER)
        self.env.tv_files[TV1] = False
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])

    def test_not_installed_when_its_folder_cant_be_listed_either(self):
        self.env.tv_copy[TV1] = (1, self.TRANSFER)
        self.env.tv_files[TV1] = (1, "ERROR: The operation couldn't be completed.")
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])

    def test_cant_tell_because_it_cant_be_reached(self):
        self.env.tv_copy[TV1] = (1, "ERROR: The device is unavailable. (com.apple.dt.CoreDeviceError error 1.)")
        doc = self.run_once()
        tv = self.tv(doc, TV1)
        self.assertEqual(tv["state"], "unreachable")
        self.assertIn("Not reachable from this Mac.", tv["detail"])
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])

    def test_settings_that_cant_be_read_mean_no_install(self):
        real = self.env.run

        def run(argv, timeout, cwd=None, env=None, output=None):
            if argv[1:5] == ["devicectl", "device", "copy", "from"] and argv[6] == TV1:
                self.env.calls.append({"argv": list(argv), "timeout": timeout, "cwd": cwd, "env": {}, "output": output})
                with open(argv[14], "w") as handle:
                    handle.write("not a settings file")
                return 0, "File received from Device\n", ""
            return real(argv, timeout, cwd=cwd, env=env, output=output)
        self.env.run = run
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        self.assertIn("Couldn't tell whether a film is playing there.", self.tv(doc, TV1)["detail"])
        self.assertIn("couldn't read its settings to see whether a film is playing", self.log_text())
        self.assertEqual(self.env.tv_installs, [(TV2, 1234)])

    def test_the_settings_copy_is_removed(self):
        seen = []
        real = self.env.run

        def run(argv, timeout, cwd=None, env=None, output=None):
            if argv[1:5] == ["devicectl", "device", "copy", "from"]:
                seen.append(argv[14])
            return real(argv, timeout, cwd=cwd, env=env, output=output)
        self.env.run = run
        self.run_once()
        self.assertEqual(len(seen), 2)
        for path in seen:
            self.assertFalse(os.path.exists(os.path.dirname(path)), path)

    def test_install_failure_backs_off(self):
        self.env.install[TV1] = (1, "ERROR: The application could not be installed: the signature is not valid")
        doc = self.run_once()
        tv = self.tv(doc, TV1)
        self.assertEqual(tv["state"], "failed")
        self.assertIn("The install failed: ERROR: The application could not be installed", tv["detail"])
        self.assertEqual(tv["next_try"], self.at(15))
        self.assertEqual(self.tv(doc, TV2)["state"], "current")
        self.env.install.clear()
        self.run_once(10)
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234)])   # not due yet
        doc = self.run_once(15)
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        self.assertEqual(self.env.tv_installs, [(TV1, 1234), (TV2, 1234), (TV1, 1234)])

    def test_up_to_date_only_once_the_apple_tv_says_so(self):
        real = self.env.run

        def run(argv, timeout, cwd=None, env=None, output=None):
            status, out, err = real(argv, timeout, cwd=cwd, env=env, output=output)
            if argv[1:5] == ["devicectl", "device", "install", "app"] and argv[6] == TV1:
                self.env.tv_has[TV1] = 1200   # devicectl says installed, the Apple TV still has the old build
            return status, out, err
        self.env.run = run
        doc = self.run_once()
        tv = self.tv(doc, TV1)
        self.assertEqual(tv["state"], "failed")
        self.assertIn("Devicectl installed it, but the Apple TV says it has build 1200", tv["detail"])
        self.assertIsNone(tv["commit"])
        self.assertEqual(self.tv(doc, TV2)["state"], "current")

    def test_installed_when_it_cant_be_asked_afterwards(self):
        real = self.env.run

        def run(argv, timeout, cwd=None, env=None, output=None):
            status, out, err = real(argv, timeout, cwd=cwd, env=env, output=output)
            if argv[1:5] == ["devicectl", "device", "install", "app"] and argv[6] == TV1:
                self.env.tv_apps[TV1] = (1, "ERROR: The device is unavailable.")
            return status, out, err
        self.env.run = run
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "current")

    def test_install_that_times_out_is_unreachable(self):
        self.env.install[TV1] = (124, "")
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        self.assertEqual(self.tv(doc, TV1)["next_try"], self.at(10))

    def test_no_apple_tv_paired(self):
        self.env.tvs = []
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.hub_args()])   # nothing is built for no Apple TV
        self.assertEqual(doc["appletvs"], [])
        self.assertIsNone(doc["last_error"])
        self.assertEqual(self.state()["tv_build"]["state"], "skipped")
        # Looked for again hours later, not at every check; meanwhile the hub is up to date.
        calls = len(self.env.calls)
        self.run_once(60)
        self.assertEqual(self.env.names(calls), ["git"])
        self.assertIn("up to date: %s" % NEW[:12], self.log_text())
        self.env.tvs = [{"udid": TV1, "name": "Living Room", "pairing": "paired", "tunnel": "disconnected"}]
        doc = self.run_once(6 * 60)
        self.assertEqual(self.env.deploys[-1], self.tv_args())
        self.assertEqual(self.tv(doc, TV1)["state"], "current")

    def test_the_apple_tvs_cant_be_listed(self):
        self.env.tvs_status = 1
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.hub_args()])
        self.assertEqual(doc["last_error"], "couldn't list the Apple TVs: devicectl failed")
        self.env.tvs_status = 0
        doc = self.run_once(5)
        self.assertEqual(self.tv(doc, TV1)["state"], "current")

    def test_build_failure_backs_off_and_shows_on_each_apple_tv(self):
        def failing(env, opts):
            if "tv" in opts["parts"]:
                return [("tv-build", "failed", opts["expect"], "the Apple TV app didn't build: error: no such module")]
            return all_ok(env, opts)
        self.env.deploy = failing
        doc = self.run_once()
        self.assertEqual(self.state()["tv_build"]["state"], "failed")
        for udid in (TV1, TV2):
            tv = self.tv(doc, udid)
            self.assertEqual(tv["state"], "failed")
            self.assertIn("The Apple TV build failed: The Apple TV app didn't build: error: no such module.", tv["detail"])
            self.assertEqual(tv["next_try"], self.at(15))
        self.assertEqual(self.env.tv_installs, [])
        self.run_once(10)
        self.assertEqual(len(self.env.deploys), 2)   # not built again before its wait is over
        self.env.deploy = all_ok
        doc = self.run_once(15)
        self.assertEqual(self.env.deploys[-1], self.tv_args())
        self.assertEqual(self.tv(doc, TV2)["state"], "current")

    def test_deploy_that_stops_without_a_result(self):
        def silent(env, opts):
            return [] if "tv" in opts["parts"] else all_ok(env, opts)
        self.env.deploy = silent
        self.env.deploy_status = 1
        doc = self.run_once()
        self.assertEqual(self.state()["tv_build"]["state"], "failed")
        self.assertIn("eploy.sh stopped (exit 1) without saying how it went", self.tv(doc, TV1)["detail"])

    def test_one_the_profile_doesnt_list(self):
        def partly(env, opts):
            if "tv" in opts["parts"]:
                env.keep_tv(opts["keep_tv"], opts["expect"], devices=[env.tvs[0]])
                return [("tv", "skipped", TV2, "Extra Apple TV: not installed, Xcode's profile doesn't list it"),
                        ("tv-build", "ok", opts["expect"], "signed by Xcode, kept")]
            return all_ok(env, opts)
        self.env.deploy = partly
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "current")
        tv = self.tv(doc, TV2)
        self.assertEqual((tv["state"], tv["detail"]), ("failed", "Not installed, Xcode's profile doesn't list it."))
        self.assertIsNone(tv["next_try"])
        self.assertEqual(self.env.tv_installs, [(TV1, 1234)])
        # It isn't tried again for this release, and doesn't keep the hub from being up to date.
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 2)

    def test_not_built_until_the_mac_app_built_here(self):
        def mac_fails(env, opts):
            if "mac" in opts["parts"]:
                return [("mac", "failed", opts["expect"], "the Mac app didn't build"),
                        ("share", "failed", opts["expect"], "nothing to share")]
            return all_ok(env, opts)
        self.env.deploy = mac_fails
        doc = self.run_once()
        self.assertEqual(len(self.env.deploys), 1)
        self.assertEqual(doc["appletvs"], [])
        self.assertEqual(self.env.tv_installs, [])

    def test_kept_build_whose_profile_expired_is_built_again(self):
        self.run_once()
        self.env.keep_tv(os.path.join(self.tv_builds, NEW), NEW, expires="2026-11-04T11:00:00Z")
        state = self.state()
        state["appletvs"][0].update(commit=OLD, state="pending")
        updater.write_json(os.path.join(self.support, "state.json"), state)
        self.run_once(5)
        self.assertEqual(self.env.deploys[-1], self.tv_args())
        self.assertEqual(len(self.env.deploys), 3)

    def test_a_new_release_is_built_again_and_the_old_build_removed(self):
        self.run_once()
        self.assertTrue(os.path.isdir(os.path.join(self.tv_builds, NEW)))
        self.env.release = NEWER
        doc = self.run_once(5)
        self.assertEqual(self.env.deploys[-1], self.tv_args(NEWER))
        self.assertEqual(self.env.tv_installs[-2:], [(TV1, 1240), (TV2, 1240)])
        self.assertEqual(self.tv(doc, TV1)["commit"], NEWER)
        self.assertFalse(os.path.exists(os.path.join(self.tv_builds, NEW)))
        self.assertTrue(os.path.isdir(os.path.join(self.tv_builds, NEWER)))
        self.assertIn("removed the kept Apple TV build %s" % NEW[:12], self.log_text())

    def test_a_new_release_while_one_waits_for_a_film(self):
        self.env.film(TV1, 20)
        self.run_once()
        self.env.release = NEWER
        self.env.clock = T0 + timedelta(minutes=5)
        self.env.film(TV1, 3)
        doc = self.run_once(5)
        tv = self.tv(doc, TV1)
        self.assertEqual(tv["state"], "waiting")
        self.assertEqual(self.env.tv_installs, [(TV2, 1234), (TV2, 1240)])
        self.env.tv_settings.clear()
        doc = self.run_once(10)
        self.assertEqual(self.env.tv_installs[-1], (TV1, 1240))   # straight to the newest
        self.assertEqual(self.tv(doc, TV1)["commit"], NEWER)

    def test_one_no_longer_paired_is_forgotten_at_the_next_build(self):
        self.run_once()
        self.env.tvs = [self.env.tvs[0]]
        self.env.release = NEWER
        doc = self.run_once(5)
        self.assertEqual([tv["udid"] for tv in doc["appletvs"]], [TV1])

    def test_one_unpaired_between_the_build_and_the_install(self):
        def unpair(env, opts):
            rows = all_ok(env, opts)
            if "tv" in opts["parts"]:
                env.tvs[1]["pairing"] = "unpaired"
            return rows
        self.env.deploy = unpair
        doc = self.run_once()
        tv = self.tv(doc, TV2)
        self.assertEqual((tv["state"], tv["detail"]), ("pending", "Not paired with this Mac."))
        self.assertEqual(self.env.tv_installs, [(TV1, 1234)])

    def test_tunnel_unavailable(self):
        self.env.tvs[0]["tunnel"] = "unavailable"
        doc = self.run_once()
        self.assertEqual(self.tv(doc, TV1)["state"], "unreachable")
        self.assertEqual(self.asked("info", TV1), 0)

    def test_off_in_config(self):
        self.configure("hub", appletv=False)
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.hub_args()])
        self.assertEqual(doc["appletvs"], [])

    def test_on_unless_config_says_otherwise(self):
        config = updater.read_json(os.path.join(self.support, "config.json"))
        del config["appletv"]   # as on a Mac Studio set up before the Apple TVs were kept current
        updater.write_json(os.path.join(self.support, "config.json"), config)
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.hub_args(), self.tv_args()])
        self.assertEqual(self.tv(doc, TV1)["state"], "current")

    def test_a_follower_has_no_apple_tvs(self):
        self.configure("follower", appletv=True)
        doc = self.run_once()
        self.assertEqual(doc["appletvs"], [])
        self.assertFalse([d for d in self.env.deploys if "tv" in d])

    def test_state_from_before_the_apple_tvs(self):
        self.configure("hub", appletv=False)
        self.run_once()
        state = self.state()
        del state["appletvs"], state["tv_build"]   # state.json as an older updater.py left it
        updater.write_json(os.path.join(self.support, "state.json"), state)
        self.configure("hub", appletv=True)
        doc = self.run_once(5)
        self.assertEqual(self.env.deploys[-1], self.tv_args())
        self.assertEqual(self.tv(doc, TV1)["state"], "current")

    def test_status_shows_the_apple_tvs(self):
        self.env.film(TV1, 20)
        self.run_once()
        status, out, _ = self.main("status")
        self.assertEqual(status, 0)
        self.assertIn("  Apple TVs:  Living Room: waiting. A film is playing. It installs once the film is over.", out)
        self.assertIn("              Extra Apple TV: current. Up to date.", out)


# -------------------------------------------------------------------------------------------- the followers


class Follower(UpdaterTest):
    def waiting(self, env, opts):
        assert opts["parts"] == ["mac-shared"], opts
        return [("mac-shared", "waiting", opts["expect"], "no complete build of %s is in iCloud Drive yet"
                 % opts["expect"][:12])]

    def shared_args(self, commit=NEW):
        return self.deploy_args("--branch", "release", "--expect", commit, "mac-shared", "--wait", "0")

    def build_args(self, commit=NEW):
        return self.deploy_args("--branch", "release", "--expect", commit, "mac", "share")

    def test_installs_the_shared_build(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.shared_args()])
        self.assertEqual((doc["mac"]["state"], doc["mac"]["commit"]), ("current", NEW))
        self.assertEqual(doc["iphones"], [])
        self.assertEqual(doc["share"], {"commit": None, "state": None, "detail": ""})
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 1)

    def test_waiting_then_builds_after_30_minutes_with_fallback(self):
        self.configure("follower", fallback=True)
        self.env.install_mac(OLD)
        self.env.deploy = self.waiting
        for minute in (0, 5, 10, 29):
            doc = self.run_once(minute)
            self.assertEqual(doc["mac"]["state"], "waiting")
            self.assertEqual(doc["mac"]["detail"], "Waiting for build 1234 to arrive in iCloud Drive.")
        self.assertEqual(self.env.deploys, [self.shared_args()] * 4)

        def waiting_then_build(env, opts):
            if opts["parts"] == ["mac-shared"]:
                return self.waiting(env, opts)
            return all_ok(env, opts)
        self.env.deploy = waiting_then_build
        doc = self.run_once(30)
        self.assertEqual(self.env.deploys[-2:], [self.shared_args(), self.build_args()])
        self.assertEqual((doc["mac"]["state"], doc["mac"]["commit"]), ("current", NEW))
        self.run_once(35)
        self.assertEqual(len(self.env.deploys), 6)

    def test_without_fallback_keeps_waiting(self):
        self.configure("follower", fallback=False)
        self.env.install_mac(OLD)
        self.env.deploy = self.waiting
        for minute in (0, 31, 120, 600):
            doc = self.run_once(minute)
            self.assertEqual(doc["mac"]["state"], "waiting")
        self.assertEqual(self.env.deploys, [self.shared_args()] * 4)

    def test_unusable_shared_build(self):
        self.configure("follower", fallback=False)
        self.env.install_mac(OLD)
        why = ("the shared build is signed by 'Apple Development: Someone (X)' but the installed app by "
               "'Apple Development: Blake (Y)', and installing it would sign this Mac out of the TVs")
        self.env.deploy = lambda env, opts: [("mac-shared", "failed", opts["expect"], why)]
        doc = self.run_once()
        self.assertEqual(doc["mac"]["state"], "failed")
        self.assertTrue(doc["mac"]["detail"].startswith("The shared build is signed by"), doc["mac"]["detail"])
        self.assertTrue(doc["mac"]["detail"].endswith("Next try at %s." % updater.clock(T0 + timedelta(minutes=15))))
        self.run_once(10)
        self.assertEqual(len(self.env.deploys), 1)
        self.run_once(15)
        self.assertEqual(len(self.env.deploys), 2)

    def test_unusable_shared_build_with_fallback_builds_here_at_once(self):
        self.configure("follower", fallback=True)
        self.env.install_mac(OLD)

        def unusable_then_build(env, opts):
            if opts["parts"] == ["mac-shared"]:
                return [("mac-shared", "failed", opts["expect"], "The shared build can't be used: it was signed for "
                                                                 "team ZZZZZZZZZZ, not D8D94SXAG6")]
            return all_ok(env, opts)
        self.env.deploy = unusable_then_build
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.shared_args(), self.build_args()])
        self.assertEqual(doc["mac"]["state"], "current")

    def test_failed_build_here_backs_off(self):
        self.configure("follower", fallback=True)
        self.env.install_mac(OLD)

        def nothing_works(env, opts):
            if opts["parts"] == ["mac-shared"]:
                return self.waiting(env, opts)
            return [("mac", "failed", opts["expect"], "the Mac app didn't build or verify")]
        self.env.deploy = nothing_works
        self.run_once(0)
        doc = self.run_once(30)
        self.assertEqual(self.env.deploys[-1], self.build_args())
        self.assertEqual(doc["mac"]["state"], "failed")
        self.run_once(35)
        self.assertEqual(self.env.deploys[-1], self.shared_args())   # still looks for the shared build
        self.run_once(45)
        self.assertEqual(self.env.deploys[-1], self.build_args())
        builds = [d for d in self.env.deploys if d == self.build_args()]
        self.assertEqual(len(builds), 2)

    def test_courtesy_postpones_for_at_most_6_checks_in_a_row(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        self.busy(idle_seconds=10)
        for minute in (0, 5, 10, 15, 20, 25):
            doc = self.run_once(minute)
            self.assertEqual(doc["mac"]["state"], "postponed")
            self.assertEqual(doc["mac"]["detail"], "Waiting until Woodruff Family isn't in use.")
        self.assertEqual(self.env.deploys, [])
        doc = self.run_once(30)   # still in use, but that was the 7th check in a row: no more waiting
        self.assertEqual(self.env.deploys, [self.shared_args()])
        call = [c for c in self.env.calls if c["argv"][0] == self.deploy_sh][0]
        self.assertNotIn("WOODRUFF_DEPLOY_IDLE_UNTIL", call["env"])
        self.assertEqual(doc["mac"]["state"], "current")

    def test_courtesy_counts_checks_not_time_asleep(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        self.busy(idle_seconds=10)
        self.run_once(0)
        doc = self.run_once(600)   # ten hours later (asleep in between): only its second check while in use
        self.assertEqual(doc["mac"]["state"], "postponed")
        self.assertEqual(self.env.deploys, [])

    def test_check_now_skips_the_courtesy_wait(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        self.busy(idle_seconds=10)
        request = updater.paths(self.env)["request"]
        os.makedirs(os.path.dirname(request), exist_ok=True)
        with open(request, "w"):
            pass
        os.utime(request, (T0.timestamp(), T0.timestamp()))
        doc = self.run_once(0)
        self.assertEqual(self.env.deploys, [self.shared_args()])
        call = [c for c in self.env.calls if c["argv"][0] == self.deploy_sh][0]
        self.assertNotIn("WOODRUFF_DEPLOY_IDLE_UNTIL", call["env"])
        self.assertEqual(doc["mac"]["state"], "current")
        self.assertFalse(os.path.exists(request))

    def test_idle_or_unknown_isnt_in_use(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        self.busy(idle_seconds=121)
        self.run_once()
        self.assertEqual(len(self.env.deploys), 1)
        self.env.install_mac(OLD)
        self.env.release = NEWER
        self.busy(idle_seconds=1)
        self.env.lsappinfo_status = 1    # lsappinfo can't tell: not in use
        self.run_once(5)
        self.assertEqual(len(self.env.deploys), 2)
        self.env.install_mac(OLD)
        self.env.release = NEW
        self.env.lsappinfo_status = 0
        self.env.front_bundle = "com.apple.Safari"
        self.run_once(10)
        self.assertEqual(len(self.env.deploys), 3)

    def test_battery_postpones_builds_but_not_shared_installs(self):
        self.configure("follower", fallback=True)
        self.env.install_mac(OLD)
        self.env.battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=99)\t12%; discharging;\n"
        self.env.deploy = self.waiting
        self.run_once(0)                                             # first sees the release
        doc = self.run_once(31)
        self.assertEqual(self.env.deploys, [self.shared_args()] * 2)   # looked for the shared build, didn't build
        self.assertEqual(doc["mac"]["state"], "postponed")
        self.assertIn("battery", doc["mac"]["detail"])
        self.env.deploy = all_ok                                     # the shared build arrives: installed on battery
        doc = self.run_once(36)
        self.assertEqual(self.env.deploys[-1], self.shared_args())
        self.assertEqual(doc["mac"]["state"], "current")

    def test_no_app_installed_at_all(self):
        self.configure("follower")
        doc = self.run_once()
        self.assertEqual(self.env.deploys, [self.shared_args()])
        self.assertEqual(doc["mac"]["commit"], NEW)

    def test_app_without_a_commit_uses_what_was_installed_last(self):
        self.configure("follower")
        self.env.install_mac(None)      # an app built before builds said their commit
        self.run_once()
        self.assertEqual(len(self.env.deploys), 1)
        self.env.deploy = lambda env, opts: (env.install_mac(None), [("mac-shared", "installed", NEW, "ok")])[1]
        self.env.release = NEWER
        doc = self.run_once(5)
        self.assertEqual((doc["mac"]["state"], doc["mac"]["commit"]), ("current", NEWER))
        self.run_once(10)
        self.assertEqual(len(self.env.deploys), 2)


# ------------------------------------------------------------------------------------------- status.json


class StatusFile(UpdaterTest):
    MAC_STATES = {"current", "updating", "waiting", "postponed", "failed"}
    PHONE_STATES = {"current", "pending", "unreachable", "failed"}
    TV_STATES = PHONE_STATES | {"waiting"}

    def check_time(self, value, nullable=True):
        if value is None and nullable:
            return
        self.assertIsInstance(value, str)
        self.assertRegex(value, STAMP)

    def check_sha(self, value):
        if value is not None:
            self.assertRegex(value, r"^[0-9a-f]{40}$")

    def check(self, doc):
        self.assertEqual(sorted(doc), sorted(["format", "updated_at", "role", "running", "release", "mac", "iphones",
                                              "appletvs", "share", "testflight", "last_check", "last_error"]))
        self.assertEqual(doc["format"], 1)
        self.check_time(doc["updated_at"], nullable=False)
        self.assertIn(doc["role"], ("hub", "follower"))
        self.assertIsInstance(doc["running"], bool)
        if doc["release"] is not None:
            self.assertEqual(sorted(doc["release"]), ["build", "commit", "seen_at", "subject"])
            self.check_sha(doc["release"]["commit"])
            self.assertIsInstance(doc["release"]["build"], int)
            self.assertIsInstance(doc["release"]["subject"], str)
            self.check_time(doc["release"]["seen_at"], nullable=False)
        mac = doc["mac"]
        self.assertEqual(sorted(mac), ["build", "commit", "detail", "state", "updated_at"])
        self.check_sha(mac["commit"])
        self.assertTrue(mac["build"] is None or isinstance(mac["build"], int))
        self.check_time(mac["updated_at"])
        self.assertIn(mac["state"], self.MAC_STATES)
        self.assertIsInstance(mac["detail"], str)
        self.assertIsInstance(doc["iphones"], list)
        for phone in doc["iphones"]:
            self.assertEqual(sorted(phone), ["commit", "detail", "name", "next_try", "state", "udid", "updated_at"])
            self.assertIsInstance(phone["udid"], str)
            self.assertIsInstance(phone["name"], str)
            self.check_sha(phone["commit"])
            self.check_time(phone["updated_at"])
            self.assertIn(phone["state"], self.PHONE_STATES)
            self.assertIsInstance(phone["detail"], str)
            self.check_time(phone["next_try"])
        self.assertIsInstance(doc["appletvs"], list)
        for tv in doc["appletvs"]:
            self.assertEqual(sorted(tv), ["commit", "detail", "name", "next_try", "state", "udid", "updated_at"])
            self.assertIsInstance(tv["udid"], str)
            self.assertIsInstance(tv["name"], str)
            self.check_sha(tv["commit"])
            self.check_time(tv["updated_at"])
            self.assertIn(tv["state"], self.TV_STATES)
            self.assertIsInstance(tv["detail"], str)
            self.assertNotIn("\n", tv["detail"])
            self.check_time(tv["next_try"])
        self.assertEqual(sorted(doc["share"]), ["commit", "detail", "state"])
        self.check_sha(doc["share"]["commit"])
        self.assertIn(doc["share"]["state"], ("ok", "failed", None))
        self.assertIsInstance(doc["share"]["detail"], str)
        self.assertEqual(sorted(doc["testflight"]), ["commit", "detail", "state"])
        self.check_sha(doc["testflight"]["commit"])
        self.assertIn(doc["testflight"]["state"], ("ok", "uploading", "skipped", "failed", None))
        self.assertIsInstance(doc["testflight"]["detail"], str)
        self.check_time(doc["last_check"], nullable=False)
        self.assertTrue(doc["last_error"] is None or isinstance(doc["last_error"], str))
        for text in [mac["detail"], doc["share"]["detail"]] + [p["detail"] for p in doc["iphones"]]:
            self.assertNotIn("\n", text)
            self.assertNotIn("\t", text)

    def test_matches_the_contract_in_every_situation(self):
        self.configure("hub")
        self.env.ls_remote = (2, "")
        self.check(self.run_once())
        self.env.ls_remote = None

        def mixed(env, opts):
            commit = opts["expect"]
            env.install_mac(commit)
            env.keep_iphone(opts["keep"], commit)
            return [("mac", "installed", commit, "installed and running"),
                    ("share", "failed", commit, "not shared:\tiCloud Drive is off"),
                    ("iphone-build", "ok", commit, "kept"),
                    ("iphone", "failed", P1, "Blake’s iPhone: the install failed: ERROR: device is locked"),
                    ("iphone", "installed", P2, "Mia's iPhone: installed")]
        self.env.deploy = mixed
        doc = self.run_once()
        self.check(doc)
        self.assertEqual(self.phone(doc, P1)["state"], "unreachable")
        self.assertEqual(doc["mac"]["updated_at"], self.at(0))
        self.assertEqual(doc["last_check"], self.at(0))
        self.assertEqual(doc["updated_at"], self.at(0))
        self.configure("follower")
        self.busy()
        self.env.release = NEWER
        self.check(self.run_once(5))

    def test_matches_the_contract_with_apple_tvs(self):
        self.configure("hub", appletv=True)
        self.env.film(TV1, 10)
        self.env.tv_apps[TV2] = (1, "ERROR: The device is unavailable.")
        doc = self.run_once()
        self.check(doc)
        self.assertEqual([tv["state"] for tv in doc["appletvs"]], ["waiting", "unreachable"])
        self.env.tv_settings.clear()
        self.env.tv_apps.clear()
        self.env.install[TV2] = (1, "ERROR: The application could not be installed.")
        doc = self.run_once(10)
        self.check(doc)
        self.assertEqual([tv["state"] for tv in doc["appletvs"]], ["current", "failed"])

    def test_running_while_deploying(self):
        self.configure("hub")
        seen = {}

        def look(env, opts):
            seen.update(json.load(open(os.path.join(self.support, "status.json"))))
            return all_ok(env, opts)
        self.env.deploy = look
        doc = self.run_once()
        self.assertTrue(seen["running"])
        self.assertEqual(seen["mac"]["state"], "updating")
        self.assertEqual(seen["mac"]["detail"], "Building and installing build 1234.")
        self.assertFalse(doc["running"])

    def test_written_atomically(self):
        self.configure("hub")
        self.run_once()
        leftovers = [n for n in os.listdir(self.support) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])


# ---------------------------------------------------------------------------------------- logs and builds


class Logs(UpdaterTest):
    def test_one_line_per_decision_and_rotation(self):
        self.configure("hub")
        log = os.path.join(self.env.logs, "updater.log")
        os.makedirs(self.env.logs)
        with open(log, "w") as handle:
            handle.write("x" * (2 * 1024 * 1024 + 10) + "\n")
        self.run_once()
        self.assertTrue(os.path.getsize(log + ".1") > 2 * 1024 * 1024)
        with open(log) as handle:
            lines = handle.read().splitlines()
        self.assertTrue(lines)
        for line in lines:
            self.assertRegex(line, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \S")
        text = "\n".join(lines)
        self.assertIn("new release %s (build 1234): Pictures load once" % NEW[:12], text)
        self.assertIn("running deploy.sh --branch release --expect %s --xcode-signing mac share iphone" % NEW, text)

    def test_keeps_the_newest_ten_deploy_logs(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        os.makedirs(self.env.logs)
        for n in range(12):
            path = os.path.join(self.env.logs, "deploy-20261101T0000%02dZ.log" % n)
            with open(path, "w") as handle:
                handle.write("old\n")
            os.utime(path, (1700000000 + n, 1700000000 + n))
        self.run_once()
        logs = sorted(n for n in os.listdir(self.env.logs) if n.startswith("deploy-"))
        self.assertEqual(len(logs), 10)
        self.assertIn("deploy-20261104T120000Z.log", logs)
        self.assertNotIn("deploy-20261101T000000Z.log", logs)
        self.assertNotIn("deploy-20261101T000002Z.log", logs)

    def test_two_deploys_in_one_second_get_two_logs(self):
        self.configure("follower", fallback=True)
        self.env.install_mac(OLD)
        self.env.deploy = lambda env, opts: ([("mac-shared", "waiting", NEW, "not yet")] if "mac-shared" in opts["parts"]
                                             else all_ok(env, opts))
        self.run_once(0)
        mark = len(self.env.calls)
        self.run_once(30)     # looks for the shared build, then builds: two deploy.sh runs in the same second
        outputs = [c["output"] for c in self.env.calls[mark:] if c["argv"][0] == self.deploy_sh]
        self.assertEqual(len(outputs), 2)
        self.assertEqual(len(set(outputs)), 2)
        self.assertTrue(outputs[1].endswith("deploy-20261104T123000Z-2.log"), outputs)


# ---------------------------------------------------------------------------------------------- commands


class Commands(UpdaterTest):
    def test_install_writes_config_and_plist(self):
        status, out, err = self.main("install", "--role", "follower", "--build-fallback", "--interval", "600")
        self.assertEqual(status, 0, out + err)
        with open(os.path.join(self.support, "config.json")) as handle:
            config = json.load(handle)
        self.assertEqual(config, {"role": "follower", "build_fallback": True, "repo": self.env.repo,
                                  "remote": "https://github.com/Blakew316/Woodrufffamily.git", "branch": "release",
                                  "interval": 600})
        plist_path = os.path.join(self.env.home, "Library/LaunchAgents/com.woodruff.family.updater.plist")
        with open(plist_path, "rb") as handle:
            plist = plistlib.load(handle)
        launchd_log = os.path.join(self.env.home, "Library/Logs/Woodruff Family/updater-launchd.log")
        self.assertEqual(plist, {
            "Label": "com.woodruff.family.updater",
            "ProgramArguments": ["/usr/bin/python3", "-I", os.path.join(self.env.repo, "scripts", "updater.py"), "run"],
            "StartInterval": 600,
            "RunAtLoad": True,
            "StandardOutPath": launchd_log,
            "StandardErrorPath": launchd_log,
            "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                     "LANG": "en_US.UTF-8"},
            "ProcessType": "Standard",
        })
        self.assertEqual([c["argv"] for c in self.env.calls if c["argv"][0] == "/bin/launchctl"], [
            ["/bin/launchctl", "bootout", "gui/501/com.woodruff.family.updater"],
            ["/bin/launchctl", "bootstrap", "gui/501", plist_path]])
        self.assertIn("Installed the Woodruff Family updater on this Mac.", out)
        self.assertIn("Role:     follower: installs the hub's shared build, or builds here", out)
        self.assertIn(self.env.repo, out)
        self.assertIn("every 10 minutes", out)
        self.assertIn(os.path.join(self.support, "status.json"), out)
        self.assertIn(os.path.join(self.env.logs, "updater.log"), out)
        self.assertIn("python3 scripts/updater.py uninstall", out)

    def test_install_defaults_and_hub(self):
        status, out, _ = self.main("install", "--role", "hub", "--build-fallback")
        self.assertEqual(status, 0)
        self.assertIn("--build-fallback is for a follower", out)
        with open(os.path.join(self.support, "config.json")) as handle:
            config = json.load(handle)
        self.assertEqual((config["role"], config["build_fallback"], config["interval"]), ("hub", False, 300))
        with open(os.path.join(self.env.agents, "com.woodruff.family.updater.plist"), "rb") as handle:
            self.assertEqual(plistlib.load(handle)["StartInterval"], 300)

    def test_install_retries_bootstrap_and_says_when_it_cant(self):
        self.env.launchctl_status = {"bootout": 3, "bootstrap": [5, 0]}
        status, out, _ = self.main("install", "--role", "hub")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.env.slept, [2])
        self.env.launchctl_status = {"bootstrap": [5]}
        status, out, _ = self.main("install", "--role", "hub")
        self.assertEqual(status, 1)
        self.assertIn("launchctl couldn't start it", out)
        self.assertIn("starts at the next login", out)

    def test_install_refuses_off_macos_and_while_updating(self):
        self.env.platform = "linux"
        status, out, _ = self.main("install", "--role", "hub")
        self.assertEqual(status, 1)
        self.assertIn("run it on one of the family's Macs", out)
        self.assertEqual(self.env.calls, [])
        self.env.environ[updater.TESTING] = "1"
        self.assertEqual(self.main("install", "--role", "hub")[0], 0)
        self.env.platform = "darwin"
        fd = updater.take_lock(os.path.join(self.support, "updater.lock"))
        try:
            status, out, _ = self.main("install", "--role", "hub")
        finally:
            os.close(fd)
        self.assertEqual(status, 1)
        self.assertIn("An update is running right now", out)
        self.assertEqual(self.main("install", "--role", "hub", "--interval", "5")[0], 2)

    def test_uninstall(self):
        self.main("install", "--role", "hub")
        self.configure("hub")
        self.run_once()
        plist = os.path.join(self.env.agents, "com.woodruff.family.updater.plist")
        status, out, _ = self.main("uninstall")
        self.assertEqual(status, 0)
        self.assertFalse(os.path.exists(plist))
        self.assertTrue(os.path.isdir(self.support))
        self.assertEqual(self.env.calls[-1]["argv"], ["/bin/launchctl", "bootout", "gui/501/com.woodruff.family.updater"])
        status, out, _ = self.main("uninstall", "--purge")
        self.assertEqual(status, 0)
        self.assertFalse(os.path.exists(self.support))
        self.assertFalse(os.path.exists(self.env.logs))
        self.assertTrue(os.path.isdir(os.path.dirname(self.support)))   # the app's own folder stays

    def test_now(self):
        status, out, _ = self.main("now")
        self.assertEqual(status, 0)
        self.assertEqual(self.env.calls[-1]["argv"], ["/bin/launchctl", "kickstart", "gui/501/com.woodruff.family.updater"])
        self.assertIn("Checking for an update now", out)
        self.env.launchctl_status = {"kickstart": 113, "print": 113}
        status, out, _ = self.main("now")
        self.assertEqual(status, 1)
        self.assertIn("isn't loaded on this Mac", out)
        self.assertNotIn("-k", [a for c in self.env.calls for a in c["argv"]])

    def test_status(self):
        status, out, _ = self.main("status")
        self.assertEqual(status, 1)
        self.assertIn("No status yet", out)
        self.configure("hub")

        def p2_away(env, opts):
            return [r if r[2] != P2 else ("iphone", "failed", P2, "Mia's iPhone: the install failed: ERROR: Timed out")
                    for r in all_ok(env, opts)]
        self.env.deploy = p2_away
        self.run_once()
        status, out, _ = self.main("status")
        self.assertEqual(status, 0)
        self.assertIn("Woodruff Family updater (hub)", out)
        self.assertIn('Release:    build 1234 (%s) "Pictures load once"' % NEW[:7], out)
        self.assertIn("This Mac:   current, build 1234 (%s)" % NEW[:7], out)
        self.assertIn("Shared:     ok. Shared in iCloud Drive.", out)
        self.assertIn("Blake’s iPhone: current. Up to date.", out)
        self.assertIn("Mia's iPhone: unreachable. Not reachable from this Mac.", out)
        self.assertIn("Last error: none", out)
        self.assertIn("Agent:      loaded", out)
        self.assertIn("lines of %s" % os.path.join(self.env.logs, "updater.log"), out)
        self.assertIn("new release %s" % NEW[:12], out)
        status, out, _ = self.main("status", "--json")
        self.assertEqual(json.loads(out), self.status())

    def test_wait_idle(self):
        self.busy(idle_seconds=5)
        until = int((T0 + timedelta(minutes=1)).timestamp())
        status, out, _ = self.main("wait-idle", "--until", str(until))
        self.assertEqual(status, 0)
        self.assertEqual(self.env.slept, [15, 15, 15, 15])
        self.assertIn("waiting while someone is using Woodruff Family", out)
        self.env.slept = []
        self.env.front_bundle = "com.apple.finder"
        self.assertEqual(self.main("wait-idle", "--until", str(until + 600))[0], 0)
        self.assertEqual(self.env.slept, [])


# ------------------------------------------------------------------------------------------------- helpers


class AppleTVAnswers(unittest.TestCase):
    """What an Apple TV says through devicectl, read."""

    APPS = {"info": {"outcome": "success"}, "result": {"apps": [{
        "appClip": False, "builtByDeveloper": True, "bundleIdentifier": "com.blakew316.woodruff.tv",
        "bundleVersion": "596", "containerAccessible": True, "defaultApp": False, "hidden": False, "internalApp": False,
        "name": "Woodruff", "removable": True, "url": "file:///private/var/containers/Bundle/Application/AA331B2F/",
        "version": "1.0"}], "deviceIdentifier": "6D6A", "matchingBundleIdentifier": "com.blakew316.woodruff.tv"}}
    TABLE = ("Apps installed:\nName       Bundle Identifier           Version   Bundle Version\n"
             "Woodruff   com.blakew316.woodruff.tv   1.0       596\n")

    def test_build_from_the_json(self):
        self.assertEqual(updater.tv_app_build(self.APPS), (True, 596))

    def test_build_from_the_table_when_the_json_says_nothing(self):
        self.assertEqual(updater.tv_app_build(None, self.TABLE), (True, 596))
        self.assertEqual(updater.tv_app_build({"result": {}}, self.TABLE), (True, 596))

    def test_not_installed(self):
        self.assertEqual(updater.tv_app_build({"result": {"apps": []}}, "Apps installed:\n"), (False, None))
        other = {"result": {"apps": [{"bundleIdentifier": "com.apple.TVWatchList", "bundleVersion": "9"}]}}
        self.assertEqual(updater.tv_app_build(other), (False, None))

    def test_a_build_that_isnt_a_number(self):
        doc = {"result": {"apps": [{"bundleIdentifier": "com.blakew316.woodruff.tv", "bundleVersion": "1.0b"}]}}
        self.assertEqual(updater.tv_app_build(doc), (True, None))
        self.assertEqual(updater.tv_app_build({"result": {"apps": [{"bundleIdentifier": "com.blakew316.woodruff.tv"}]}}),
                         (True, None))

    def note(self, seconds_ago, **more):
        note = {"title": "Avengers - Endgame", "stage": "playing", "detail": "", "build": "Build 596",
                "at": (T0 - timedelta(seconds=seconds_ago)).timestamp()}
        note.update(more)
        return {"playing.crumb": note, "atv.name": "Apple TV"}

    def test_app_on_screen(self):
        def open_note(seconds_ago):
            return {"open.crumb": {"build": "Build 655", "at": (T0 - timedelta(seconds=seconds_ago)).timestamp()}}
        self.assertTrue(updater.app_on_screen(open_note(0), T0))
        self.assertTrue(updater.app_on_screen(open_note(45), T0))
        self.assertTrue(updater.app_on_screen(open_note(-10), T0))     # the clocks a little apart
        self.assertFalse(updater.app_on_screen(open_note(61), T0))
        self.assertFalse(updater.app_on_screen(open_note(-120), T0))   # far ahead: not trusted
        self.assertFalse(updater.app_on_screen({}, T0))
        self.assertFalse(updater.app_on_screen(None, T0))
        self.assertFalse(updater.app_on_screen({"open.crumb": {"at": True}}, T0))
        self.assertFalse(updater.app_on_screen({"open.crumb": "yes"}, T0))
        self.assertFalse(updater.app_on_screen(self.note(0), T0))      # a film's note isn't this one

    def test_film_on_screen(self):
        self.assertTrue(updater.film_on_screen(self.note(0), T0))
        self.assertTrue(updater.film_on_screen(self.note(12), T0))
        self.assertTrue(updater.film_on_screen(self.note(89), T0))
        self.assertTrue(updater.film_on_screen(self.note(3, stage="opening"), T0))

    def test_film_left_open_in_an_app_put_away(self):
        self.assertFalse(updater.film_on_screen(self.note(90), T0))
        self.assertFalse(updater.film_on_screen(self.note(2259), T0))   # what an Apple TV really had

    def test_no_film(self):
        self.assertFalse(updater.film_on_screen({"atv.name": "Apple TV"}, T0))
        self.assertFalse(updater.film_on_screen({}, T0))
        self.assertFalse(updater.film_on_screen(None, T0))

    def test_a_note_from_a_clock_ahead_counts_as_on_screen(self):
        self.assertTrue(updater.film_on_screen(self.note(-400), T0))

    def test_a_note_without_a_time(self):
        self.assertFalse(updater.film_on_screen({"playing.crumb": {"title": "x"}}, T0))
        self.assertFalse(updater.film_on_screen({"playing.crumb": {"at": "soon"}}, T0))
        self.assertFalse(updater.film_on_screen({"playing.crumb": {"at": True}}, T0))
        self.assertFalse(updater.film_on_screen({"playing.crumb": "playing"}, T0))


class InstallLinkIpa(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="updater-ipa."))
        self.app = os.path.join(self.tmp, "Woodruff Family.app")
        os.makedirs(os.path.join(self.app, "PlugIns", "Widgets.appex"))
        os.makedirs(os.path.join(self.app, "Empty"))
        for name, text in (("Info.plist", "info"), ("Woodruff Family", "the program"), ("PlugIns/Widgets.appex/Info.plist", "w")):
            with open(os.path.join(self.app, name), "w") as handle:
                handle.write(text)
        os.chmod(os.path.join(self.app, "Woodruff Family"), 0o755)
        os.chmod(os.path.join(self.app, "Info.plist"), 0o644)
        os.symlink("Info.plist", os.path.join(self.app, "Link"))
        self.ipa = os.path.join(self.tmp, "app.ipa")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_ipa_is_the_app_and_nothing_else(self):
        updater.make_ipa(self.app, self.ipa)
        self.assertIsNone(updater.ipa_problem(self.ipa))
        with zipfile.ZipFile(self.ipa) as archive:
            self.assertIsNone(archive.testzip())
            infos = dict((i.filename, i) for i in archive.infolist())
            base = "Payload/Woodruff Family.app/"
            self.assertEqual(sorted(infos), sorted([
                base, base + "Empty/", base + "Info.plist", base + "Link", base + "PlugIns/",
                base + "PlugIns/Widgets.appex/", base + "PlugIns/Widgets.appex/Info.plist", base + "Woodruff Family"]))
            self.assertEqual(archive.read(base + "Woodruff Family"), b"the program")
            # The program stays a program, a link stays a link, and every entry says it's a Unix file.
            self.assertEqual(infos[base + "Woodruff Family"].external_attr >> 16, stat.S_IFREG | 0o755)
            self.assertEqual(infos[base + "Info.plist"].external_attr >> 16, stat.S_IFREG | 0o644)
            self.assertEqual(stat.S_IFMT(infos[base + "Link"].external_attr >> 16), stat.S_IFLNK)
            self.assertEqual(archive.read(base + "Link"), b"Info.plist")
            self.assertTrue(all(i.create_system == 3 for i in infos.values()))

    def test_a_macs_stray_files_are_refused(self):
        # What ditto and Archive Utility add: iOS unpacks them as files the app's signature doesn't cover.
        for stray in ("Payload/Woodruff Family.app/._Info.plist", "__MACOSX/Payload/._Woodruff Family.app"):
            with zipfile.ZipFile(self.ipa, "w") as archive:
                archive.writestr("Payload/Woodruff Family.app/Info.plist", "info")
                archive.writestr(stray, "x")
            self.assertIn("signature doesn't cover", updater.ipa_problem(self.ipa))

    def test_not_an_app(self):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Woodruff Family.app/Info.plist", "info")
        self.assertIn("one app under Payload", updater.ipa_problem(self.ipa))
        with open(self.ipa, "w") as handle:
            handle.write("not a zip")
        self.assertIn("can't be read", updater.ipa_problem(self.ipa))


class Helpers(unittest.TestCase):
    def test_repo_slug(self):
        self.assertEqual(updater.repo_slug("https://github.com/Blakew316/Woodrufffamily.git\n"), "Blakew316/Woodrufffamily")
        self.assertEqual(updater.repo_slug("https://github.com/Blakew316/Woodrufffamily"), "Blakew316/Woodrufffamily")
        self.assertEqual(updater.repo_slug("git@github.com:Blakew316/Woodrufffamily.git"), "Blakew316/Woodrufffamily")
        self.assertIsNone(updater.repo_slug("https://example.com/a/b.git"))
        self.assertIsNone(updater.repo_slug(""))

    def test_parse_results(self):
        rows = updater.parse_results("mac\tinstalled\t%s\tinstalled and running\n\nnonsense\n"
                                     "iphone\tfailed\t%s\tMia's iPhone: the install failed: x\ty\n"
                                     "share\tok\t%s\n" % (NEW, P2, NEW))
        self.assertEqual(rows, [
            {"part": "mac", "status": "installed", "target": NEW, "detail": "installed and running"},
            {"part": "iphone", "status": "failed", "target": P2, "detail": "Mia's iPhone: the install failed: x\ty"},
            {"part": "share", "status": "ok", "target": NEW, "detail": ""}])

    def test_iphone_name_in_details(self):
        self.assertEqual(updater.name_in("Mia's iPhone: installed"), "Mia's iPhone")
        self.assertIsNone(updater.name_in("installed"))
        self.assertEqual(updater.without_name("Blake: Pro: the install failed: x", "Blake: Pro"),
                         "the install failed: x")
        self.assertEqual(updater.without_name("Mia's iPhone: installed", None), "installed")
        self.assertEqual(updater.without_name("installed", "Mia's iPhone"), "installed")

    def test_backoff_ladder(self):
        self.assertEqual([updater.backoff(n) for n in range(1, 9)],
                         [900, 1800, 3600, 7200, 14400, 28800, 28800, 28800])

    def test_battery(self):
        self.assertTrue(updater.battery_is_low("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t29%; discharging;"))
        self.assertFalse(updater.battery_is_low("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t30%; discharging;"))
        self.assertFalse(updater.battery_is_low("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t5%; charging;"))
        self.assertFalse(updater.battery_is_low("Now drawing from 'AC Power'\n"))   # a Mac Studio: no battery
        self.assertFalse(updater.battery_is_low(""))

    def test_courtesy_parsing(self):
        self.assertEqual(updater.front_asn('"LSDisplayName"="x"\nASN:0x0-0x1d01d:\n'), "ASN:0x0-0x1d01d:")
        self.assertIsNone(updater.front_asn(""))
        self.assertEqual(updater.bundle_id_in('"CFBundleIdentifier"="com.woodruff.family.mac"'), "com.woodruff.family.mac")
        self.assertIsNone(updater.bundle_id_in("[ NULL ]"))
        self.assertEqual(updater.hid_idle_seconds('  |   "HIDIdleTime" = 2500000000\n'), 2.5)
        self.assertIsNone(updater.hid_idle_seconds("nothing"))

    def test_real_env_runs_without_stdin_and_stops_at_the_timeout(self):
        env = updater.Env(home=tempfile.gettempdir())
        status, out, err = env.run([sys.executable, "-c", "import sys; print(repr(sys.stdin.read()))"], 30)
        self.assertEqual((status, out.strip()), (0, "''"))
        status, out, err = env.run([sys.executable, "-c", "import time; time.sleep(60)"], 1)
        self.assertEqual(status, 124)
        status, out, err = env.run(["/nonexistent/tool"], 5)
        self.assertEqual(status, 127)
        with tempfile.TemporaryDirectory() as folder:
            log = os.path.join(folder, "out.log")
            status, _, _ = env.run([sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"],
                                   30, output=log)
            with open(log) as handle:
                self.assertEqual(sorted(handle.read().split()), ["err", "out"])

    def test_no_shell_anywhere(self):
        with open(os.path.join(SCRIPTS, "updater.py")) as handle:
            source = handle.read()
        self.assertNotIn("shell=True", source)
        self.assertNotIn("os.system(", source)
        self.assertNotIn("-allowProvisioningUpdates", source)   # only deploy.sh --xcode-signing, on the hub


if __name__ == "__main__":
    unittest.main()
