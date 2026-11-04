"""Tests for scripts/updater.py. Every command it runs goes to FakeEnv, which plays git, deploy.sh, devicectl,
lsappinfo, ioreg, pmset and launchctl; files go to a temporary folder. Nothing touches this Mac's ~/Library,
/Applications, launchd or the network.

Run from the repository root: python3 -m unittest discover -s scripts/tests -p 'test_*.py'
"""

import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import sys
import tempfile
import unittest
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
T0 = datetime(2026, 11, 4, 12, 0, tzinfo=timezone.utc)
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
BUSY_ASN = "ASN:0x0-0x2b02b:"


def parse_deploy_args(args):
    opts = {"parts": [], "branch": None, "expect": None, "wait": None, "keep": None, "no_launch": False,
            "results": None}
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("--branch", "--expect", "--wait", "--keep-iphone", "--results"):
            opts[{"--keep-iphone": "keep"}.get(arg, arg[2:])] = args[i + 1]
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
    return rows


class FakeEnv(updater.Env):
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
            assert argv[-1] == "devices" and "-I" in argv, argv
            return self.devices_status, json.dumps(self.devices), "" if self.devices_status == 0 else "devicectl failed"
        if name == "xcrun":
            assert argv[1:6] == ["devicectl", "device", "install", "app", "--device"], argv
            assert argv[7:9] == ["--timeout", "240"], argv
            status, out = self.install.get(argv[6], (0, "App installed:\n  bundleID: com.blakew316.woodruff\n"))
            return status, out, ""
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

    def configure(self, role="hub", fallback=False):
        updater.write_json(os.path.join(self.support, "config.json"), {
            "role": role, "build_fallback": fallback, "repo": self.env.repo,
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
        # until 30 minutes after it first saw the release, deploy.sh waits while the app is in use before quitting it
        self.assertEqual(call["env"]["WOODRUFF_DEPLOY_IDLE_UNTIL"], str(int((T0 + timedelta(minutes=30)).timestamp())))
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
        # The share is tried again (with the Mac app) after 15 minutes; until then nothing is built.
        self.env.deploy = all_ok
        self.run_once(10)
        self.assertEqual(len(self.env.deploys), 1)
        doc = self.run_once(15)
        self.assertEqual(self.env.deploys[-1], self.hub_args(iphone=False))
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


# -------------------------------------------------------------------------------------------- the followers


class Follower(UpdaterTest):
    def waiting(self, env, opts):
        assert opts["parts"] == ["mac-shared"], opts
        return [("mac-shared", "waiting", opts["expect"], "no complete build of %s is in iCloud Drive yet"
                 % opts["expect"][:12])]

    def shared_args(self, commit=NEW):
        return self.deploy_args("--branch", "release", "--expect", commit, "mac-shared", "--wait", "0")

    def build_args(self, commit=NEW):
        return self.deploy_args("--branch", "release", "--expect", commit, "mac")

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

    def test_courtesy_postpones_for_at_most_30_minutes(self):
        self.configure("follower")
        self.env.install_mac(OLD)
        self.busy(idle_seconds=10)
        for minute in (0, 15, 29):
            doc = self.run_once(minute)
            self.assertEqual(doc["mac"]["state"], "postponed")
            self.assertEqual(doc["mac"]["detail"], "Waiting until Woodruff Family isn't in use (by %s)."
                             % updater.clock(T0 + timedelta(minutes=30)))
        self.assertEqual(self.env.deploys, [])
        doc = self.run_once(30)   # still in use, but it's been 30 minutes
        self.assertEqual(self.env.deploys, [self.shared_args()])
        call = [c for c in self.env.calls if c["argv"][0] == self.deploy_sh][0]
        self.assertNotIn("WOODRUFF_DEPLOY_IDLE_UNTIL", call["env"])
        self.assertEqual(doc["mac"]["state"], "current")

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
                                              "share", "last_check", "last_error"]))
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
        self.assertEqual(sorted(doc["share"]), ["commit", "detail", "state"])
        self.check_sha(doc["share"]["commit"])
        self.assertIn(doc["share"]["state"], ("ok", "failed", None))
        self.assertIsInstance(doc["share"]["detail"], str)
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


class Helpers(unittest.TestCase):
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
