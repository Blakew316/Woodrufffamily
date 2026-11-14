"""Runs scripts/deploy.sh with /bin/bash (macOS's bash 3.2 on CI) against stand-in tools, for its options and
--results lines on the way that ends before anything is built, for the iPhone build's and the TestFlight
archive's retries when Apple refuses an entitlement (a stand-in xcodebuild that refuses the one asked), and for the
Apple TV part from the build to the kept copy or the installs. Nothing real is built, signed or installed: every tool
it would call first in PATH is a stand-in in a temporary folder, and the checkout is a copy.

Run from the repository root: python3 -m unittest discover -s scripts/tests -p 'test_*.py'
"""

import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.dirname(SCRIPTS)   # the checkout these tests are in
BASH = os.environ.get("WOODRUFF_TEST_BASH", "/bin/bash")   # macOS's is 3.2, like the family's Macs
HEAD = hashlib.sha1(b"checked out").hexdigest()
WANT = hashlib.sha1(b"asked for").hexdigest()

LOG = '_l=$(basename "$0"); for a in "$@"; do _l="$_l [$a]"; done; printf \'%s\\n\' "$_l" >>"$FAKE/calls.log"\n'

FAKES = {
    # Fetching a branch origin doesn't have fails like git does; with $FAKE/has-branch it works and HEAD is $HEAD.
    "git": LOG + r'''
case "$1" in
  config) exit 1 ;;
  fetch)
    case "$*" in
      *refs/heads/*) [ -f "$FAKE/has-branch" ] || { echo "fatal: couldn't find remote ref refs/heads/release" >&2; exit 128; } ;;
    esac
    exit 0 ;;
  checkout) exit 0 ;;
  rev-parse) echo "$HEAD" ;;
  rev-list) echo 412 ;;
  log) echo "abc1234 Weather on the Mac" ;;
  status) exit 0 ;;
  *) echo "unexpected git $*" >&2; exit 99 ;;
esac
''',
    "security": LOG + 'echo "     0 valid identities found"\n',
}
STUBS = ("xcodebuild", "codesign", "ditto", "osascript", "pgrep", "open", "xcrun", "xcodegen", "notifyutil", "pkill")


class DeployHarness(unittest.TestCase):
    """The stand-in tools and the copy of the checkout, for the tests below (it has none of its own)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="deploy-test.")
        self.repo = os.path.join(self.tmp, "repo")
        self.fake = os.path.join(self.tmp, "fake")
        self.bin = os.path.join(self.tmp, "bin")
        for folder in (os.path.join(self.repo, "scripts"), self.fake, self.bin, os.path.join(self.tmp, "home"),
                       os.path.join(self.tmp, "t"), os.path.join(self.tmp, "elsewhere")):
            os.makedirs(folder)
        for name in ("deploy.sh", "signing.py"):
            shutil.copy2(os.path.join(SCRIPTS, name), os.path.join(self.repo, "scripts", name))
        with open(os.path.join(self.repo, "project.yml"), "w") as handle:
            handle.write("name: WoodruffFamily\n")
        for name, body in FAKES.items():
            self.tool(name, body)
        for name in STUBS:
            self.tool(name, LOG + 'echo "VIOLATION $(basename "$0") ran" >>"$FAKE/violations"; exit 1\n')
        self.tool("python3", 'exec "%s" "$@"\n' % sys.executable)   # the python3 deploy.sh finds: this one

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def tool(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w") as handle:
            handle.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def deploy(self, *args, **kw):
        env = {"PATH": self.bin + ":/usr/bin:/bin", "HOME": os.path.join(self.tmp, "home"), "FAKE": self.fake,
               "TMPDIR": os.path.join(self.tmp, "t"), "HEAD": HEAD, "LANG": "C"}
        proc = subprocess.run([BASH, os.path.join(self.repo, "scripts", "deploy.sh")] + list(args),
                              cwd=kw.get("cwd", self.tmp), env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        out = proc.stdout.decode("utf-8", "replace")
        self.assertFalse(os.path.exists(os.path.join(self.fake, "violations")),
                         open(os.path.join(self.fake, "violations")).read() if os.path.exists(
                             os.path.join(self.fake, "violations")) else "")
        return proc.returncode, out

    def calls(self):
        path = os.path.join(self.fake, "calls.log")
        if not os.path.exists(path):
            return []
        with open(path) as handle:
            return handle.read().splitlines()

    def rows(self, path):
        with open(path, encoding="utf-8") as handle:
            return [line.rstrip("\n").split("\t") for line in handle if line.strip()]


@unittest.skipUnless(os.path.exists(BASH), "needs " + BASH)
class DeployOptions(DeployHarness):
    def test_branch_origin_doesnt_have(self):
        results = os.path.join(self.tmp, "results.tsv")
        status, out = self.deploy("--branch", "release", "--expect", WANT, "mac", "share", "iphone", "--keep-iphone",
                                  os.path.join(self.tmp, "kept"), "--no-launch", "--results", results)
        self.assertEqual(status, 1, out)
        why = "origin has no branch release (--branch release), so nothing was built"
        self.assertIn("PROBLEM: " + why, out)
        self.assertEqual(self.rows(results), [["mac", "failed", WANT, why], ["share", "failed", WANT, why],
                                              ["iphone-build", "failed", WANT, why]])
        self.assertIn("git [fetch] [origin] [+refs/heads/release:refs/remotes/origin/release]", self.calls())
        self.assertFalse(any(line.startswith("git [checkout]") for line in self.calls()))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "kept")))

    def test_nothing_built_says_so_for_the_apple_tvs_too(self):
        results = os.path.join(self.tmp, "results.tsv")
        status, out = self.deploy("--branch", "release", "--expect", WANT, "--xcode-signing", "tv", "--keep-tv",
                                  os.path.join(self.tmp, "kept-tv"), "--results", results)
        self.assertEqual(status, 1, out)
        why = "origin has no branch release (--branch release), so nothing was built"
        self.assertEqual(self.rows(results), [["tv-build", "failed", WANT, why]])
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "kept-tv")))

    def test_expect_mismatch_after_a_detached_checkout(self):
        open(os.path.join(self.fake, "has-branch"), "w").close()
        status, out = self.deploy("--branch", "release", "--expect", WANT, "mac-shared", "--wait", "0", "--results",
                                  "r.tsv", cwd=os.path.join(self.tmp, "elsewhere"))
        self.assertEqual(status, 1, out)
        self.assertIn("at abc1234 Weather on the Mac (build 412)", out)
        rows = self.rows(os.path.join(self.tmp, "elsewhere", "r.tsv"))   # a relative path is from where it ran
        self.assertEqual(rows, [["mac-shared", "failed", HEAD, "the checkout is at %s, not %s (--expect), so nothing "
                                                               "was built" % (HEAD, WANT)]])
        self.assertIn("git [checkout] [--detach] [refs/remotes/origin/release]", self.calls())
        self.assertFalse(any(line.startswith("git [pull]") for line in self.calls()))

    def test_appends_to_results(self):
        results = os.path.join(self.tmp, "results.tsv")
        with open(results, "w") as handle:
            handle.write("earlier\tline\n")
        self.deploy("--branch", "release", "--expect", WANT, "--results=" + results)
        self.assertEqual([r[0] for r in self.rows(results)], ["earlier", "mac"])

    def test_bad_options(self):
        for args in (["--wait", "soon", "mac-shared"], ["--wait"], ["--branch", "-x"], ["--branch", "a b"],
                     ["--branch", "a..b"], ["--keep-iphone="], ["--expect", "xyz!"], ["frobnicate"],
                     ["--keep-tv="], ["--keep-tv"], ["tv"], ["tv", "--keep-tv", "kept"],   # tv needs --xcode-signing
                     ["--results", os.path.join(self.tmp, "no", "such", "folder", "r.tsv")],
                     ["mac", "mac-shared"]):
            status, out = self.deploy(*args)
            self.assertEqual(status, 2, (args, out))
        self.assertEqual(self.calls(), [])   # nothing ran for any of them

    def test_help(self):
        status, out = self.deploy("--help")
        self.assertEqual(status, 0)
        for option in ("--branch <name>", "--wait <seconds>", "--keep-iphone <dir>", "--no-launch",
                       "--results <file>", "--expect <commit>", "--keep-tv <dir>", "[tv]"):
            self.assertIn(option, out)

    def test_syntax(self):
        proc = subprocess.run([BASH, "-n", os.path.join(SCRIPTS, "deploy.sh")], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT)
        self.assertEqual(proc.returncode, 0, proc.stdout)


APP = "App/iOS/WoodruffFamily.entitlements"
APP_PUSH = "App/iOS/WoodruffFamilyPush.entitlements"
APP_BASIC = "App/iOS/WoodruffFamilyBasic.entitlements"
APP_NO_PUSH = "App/iOS/WoodruffFamily-NoPush.entitlements"
WIDGETS = "App/Widgets/WoodruffWidgets.entitlements"
WIDGETS_PUSH = "App/Widgets/WoodruffWidgetsPush.entitlements"
NOTIFY = "App/NotificationService/WoodruffNotifications.entitlements"
APP_GROUP = "com.apple.security.application-groups"
TIME_SENSITIVE = "com.apple.developer.usernotifications.time-sensitive"
UDID = "00008110-001A2B3C4D5E801E"
TS_REFUSED = "Apple refused Time Sensitive Notifications for com.blakew316.woodruff (camera alerts through Sleep and Focus)"

# Builds and archives like xcodebuild, signing with the entitlements files it's given (else project.yml's; the
# checkout's own copies) and refusing what $FAKE/refuse names: "widgets-push" (push in the widgets' entitlements),
# "notify-group" (the notification extension's app group), "time-sensitive" (Time Sensitive in the app's: the error
# names the app group too, as Xcode's does for a profile that has neither), "app-group" (the app group in the app's),
# "compile-error" (every build, a compile error that names timeSensitive). $FAKE/flaky: how many more builds fail as
# Apple's servers sometimes make them, naming no entitlement. Like xcodebuild, it prints every target's entitlements, so
# push, the app group and Time Sensitive are named in every log.
XCODEBUILD = LOG + r'''
ents=App/iOS/WoodruffFamily.entitlements
wents=App/Widgets/WoodruffWidgetsPush.entitlements
nents=App/NotificationService/WoodruffNotifications.entitlements
action=build
archive=""
prev=""
for a in "$@"; do
  case "$a" in
    WOODRUFF_ENTITLEMENTS=*) ents=${a#*=} ;;
    WOODRUFF_WIDGET_ENTITLEMENTS=*) wents=${a#*=} ;;
    WOODRUFF_NOTIFY_ENTITLEMENTS=*) nents=${a#*=} ;;
    archive) action=archive ;;
    -exportArchive) action=export ;;
  esac
  if [ "$prev" = -archivePath ]; then archive=$a; fi
  prev=$a
done
if [ "$action" = export ]; then echo "** EXPORT SUCCEEDED **"; exit 0; fi
echo "ProcessProductPackaging $ents"
echo 'Entitlements:'
echo '    "aps-environment" = development;'
echo '    "com.apple.security.application-groups" = ("group.com.woodruff.family");'
echo '    "com.apple.developer.usernotifications.time-sensitive" = 1;'
refused=""
if grep -q widgets-push "$FAKE/refuse" 2>/dev/null && [ "$wents" = App/Widgets/WoodruffWidgetsPush.entitlements ]; then
  echo "error: Provisioning profile \"iOS Team Provisioning Profile: com.blakew316.woodruff.widgets\" doesn't include the aps-environment entitlement. (in target 'WoodruffWidgets' from project 'WoodruffFamily')"
  refused=1
fi
if grep -q notify-group "$FAKE/refuse" 2>/dev/null && [ -n "$nents" ]; then
  echo "error: Provisioning profile \"iOS Team Provisioning Profile: com.blakew316.woodruff.notifications\" doesn't include the com.apple.security.application-groups entitlement. (in target 'WoodruffNotifications' from project 'WoodruffFamily')"
  refused=1
fi
if grep -q time-sensitive "$FAKE/refuse" 2>/dev/null && grep -q usernotifications.time-sensitive "$ents" 2>/dev/null; then
  echo "error: Provisioning profile \"iOS Team Provisioning Profile: com.blakew316.woodruff\" doesn't include the com.apple.developer.usernotifications.time-sensitive and com.apple.security.application-groups entitlements. (in target 'WoodruffFamily' from project 'WoodruffFamily')"
  refused=1
fi
if grep -q app-group "$FAKE/refuse" 2>/dev/null && grep -q application-groups "$ents" 2>/dev/null; then
  echo "error: Provisioning profile \"iOS Team Provisioning Profile: com.blakew316.woodruff\" doesn't include the com.apple.security.application-groups entitlement. (in target 'WoodruffFamily' from project 'WoodruffFamily')"
  refused=1
fi
if grep -q compile-error "$FAKE/refuse" 2>/dev/null; then
  echo "/repo/App/Shared/NestAlerts.swift:555:42: error: type 'UNNotificationInterruptionLevel' has no member 'timeSensitive'"
  refused=1
fi
if [ -f "$FAKE/flaky" ] && [ "$(cat "$FAKE/flaky")" -gt 0 ]; then
  echo $(($(cat "$FAKE/flaky") - 1)) >"$FAKE/flaky"
  echo "error: Communication with Apple failed: the request timed out, so automatic signing couldn't update the provisioning profile. (in target 'WoodruffFamily' from project 'WoodruffFamily')"
  refused=1
fi
word=BUILD
if [ "$action" = archive ]; then word=ARCHIVE; fi
if [ -n "$refused" ]; then echo "** $word FAILED **"; exit 65; fi
if [ "$action" = archive ]; then mkdir -p "$archive"; else mkdir -p "build/Build/Products/Release-iphoneos/Woodruff Family.app"; fi
echo "** $word SUCCEEDED **"
'''

# One iPhone paired, and every install works.
XCRUN = LOG + r'''
case "$1 $2 $3" in
  "devicectl list devices")
    out=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = --json-output ]; then out=$a; fi
      prev=$a
    done
    printf '%s\n' '{"result": {"devices": [{"hardwareProperties": {"udid": "''' + UDID + r'''", "platform": "iOS", "reality": "physical"}, "deviceProperties": {"name": "Family iPhone"}, "connectionProperties": {}}]}}' >"$out"
    ;;
  "devicectl device install") ;;
  *) echo "unexpected xcrun $*" >&2; exit 99 ;;
esac
'''


@unittest.skipUnless(os.path.exists(BASH), "needs " + BASH)
class SigningRetries(DeployHarness):
    """With --xcode-signing, a build or archive Apple won't sign with everything is tried again without only what it
    refused: the widgets' push, the notification extension's app group, or both; the app group everywhere only once
    Apple refused it. Never without Time Sensitive: when Apple refuses that, nothing is built without it or the app
    group, and nothing is installed or uploaded."""

    def setUp(self):
        super().setUp()
        open(os.path.join(self.fake, "has-branch"), "w").close()
        self.tool("xcodebuild", XCODEBUILD)
        self.tool("xcrun", XCRUN)
        self.tool("xcodegen", LOG)
        self.tool("codesign", LOG)
        webrtc = os.path.join(self.repo, "scripts", "fetch_webrtc.sh")
        with open(webrtc, "w") as handle:
            handle.write('#!/bin/sh\necho "WebRTC already here"\n')
        os.chmod(webrtc, 0o755)
        # The checkout's own entitlements files: the stand-in xcodebuild refuses what they carry.
        for folder in ("App/iOS", "App/Widgets", "App/NotificationService"):
            os.makedirs(os.path.join(self.repo, folder))
            for name in os.listdir(os.path.join(SOURCE, folder)):
                if name.endswith(".entitlements"):
                    shutil.copy2(os.path.join(SOURCE, folder, name), os.path.join(self.repo, folder, name))
        self.results = os.path.join(self.tmp, "results.tsv")

    def refuse(self, *what):
        with open(os.path.join(self.fake, "refuse"), "w") as handle:
            handle.write("\n".join(what) + "\n")

    def flaky(self, builds):
        with open(os.path.join(self.fake, "flaky"), "w") as handle:
            handle.write("%d\n" % builds)

    def failed(self, *part):
        """deploy.sh with --xcode-signing and part, which fails: its output."""
        status, out = self.deploy("--branch", "release", "--xcode-signing", *(part + ("--results", self.results)))
        self.assertEqual(status, 1, out)
        return out

    def xcodebuilds(self):
        """Each xcodebuild run: what it did, and the app's, the widgets' and the notification extension's
        entitlements it was given (None: project.yml's)."""
        out = []
        for line in self.calls():
            if not line.startswith("xcodebuild "):
                continue
            args = line[len("xcodebuild "):][1:-1].split("] [")
            given = dict(a.split("=", 1) for a in args if a.startswith("WOODRUFF_") and "=" in a)
            action = "export" if "-exportArchive" in args else args[-1]
            out.append((action, given.get("WOODRUFF_ENTITLEMENTS"), given.get("WOODRUFF_WIDGET_ENTITLEMENTS"),
                        given.get("WOODRUFF_NOTIFY_ENTITLEMENTS")))
        return out

    def iphone(self):
        status, out = self.deploy("--branch", "release", "--xcode-signing", "iphone", "--no-launch",
                                  "--results", self.results)
        self.assertEqual(status, 0, out)
        self.assertEqual([r[:3] for r in self.rows(self.results)], [["iphone-build", "ok", HEAD],
                                                                    ["iphone", "installed", UDID]])
        return out

    def upload(self):
        status, out = self.deploy("--branch", "release", "--xcode-signing", "testflight", "--results", self.results)
        self.assertEqual(status, 0, out)
        self.assertEqual([r[:2] for r in self.rows(self.results)], [["testflight", "ok"]])
        return out

    def test_iphone_without_the_widgets_push(self):
        self.refuse("widgets-push")
        self.iphone()
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None), ("build", APP, WIDGETS, NOTIFY)])

    def test_iphone_without_the_notification_group_keeps_the_widgets_push(self):
        self.refuse("notify-group")
        self.iphone()
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None), ("build", APP, WIDGETS, NOTIFY),
                                              ("build", APP, WIDGETS_PUSH, "")])

    def test_iphone_without_either(self):
        self.refuse("widgets-push", "notify-group")
        self.iphone()
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None), ("build", APP, WIDGETS, NOTIFY),
                                              ("build", APP, WIDGETS_PUSH, ""), ("build", APP, WIDGETS, "")])

    def test_testflight_without_the_widgets_push(self):
        self.refuse("widgets-push")
        out = self.upload()
        self.assertIn("archiving again without it", out)
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None), ("archive", None, WIDGETS, None),
                                              ("export", None, None, None)])

    def test_testflight_without_the_notification_group_keeps_the_widgets_push(self):
        # Every log names aps-environment (the entitlements it prints): only an error about the widgets' push counts.
        self.refuse("notify-group")
        out = self.upload()
        self.assertNotIn("archiving again without it", out)
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None), ("archive", None, WIDGETS_PUSH, ""),
                                              ("export", None, None, None)])

    def test_testflight_without_either(self):
        self.refuse("widgets-push", "notify-group")
        self.upload()
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None), ("archive", None, WIDGETS, None),
                                              ("archive", None, WIDGETS, ""), ("export", None, None, None)])

    def test_iphone_time_sensitive_refused(self):
        # Its error names the app group too: no build goes without it or without Time Sensitive, and the Mac's own
        # profiles aren't tried either (that copy would go without the camera add-on). The iPhones keep their build.
        self.refuse("time-sensitive")
        out = self.failed("iphone", "--no-launch")
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None)])
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["iphone-build", "failed", HEAD]])
        self.assertTrue(rows[0][3].startswith(TS_REFUSED + ", so the iPhones keep the build they have (log "), rows)
        self.assertIn("hint: turn on Time Sensitive Notifications for com.blakew316.woodruff at developer.apple.com", out)
        self.assertNotIn("choosing the signing identity and profiles", out)
        self.assertFalse(any(line.startswith("xcrun [devicectl] [device]") for line in self.calls()))

    def test_iphone_without_the_app_group_once_apple_refused_it(self):
        self.refuse("app-group")
        self.iphone()
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None), ("build", APP, WIDGETS, NOTIFY),
                                              ("build", APP, WIDGETS_PUSH, ""), ("build", APP, WIDGETS, ""),
                                              ("build", APP_PUSH, "", "")])

    def test_iphone_never_without_an_app_group_for_another_failure(self):
        # Two builds fail as Apple's servers can make them fail, and the log names the app group only among the
        # entitlements it prints: nothing is built without one. Xcode's signing failed, so the Mac's own profiles are
        # tried next (there are none here).
        self.flaky(2)
        out = self.failed("iphone", "--no-launch")
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None), ("build", APP, WIDGETS, NOTIFY)])
        self.assertIn("signing it with this Mac's own certificate and profiles instead", out)
        self.assertEqual([r[:2] for r in self.rows(self.results)], [["iphone-build", "failed"]])

    def test_iphone_compile_error_isnt_a_refusal(self):
        # It names timeSensitive, but it's no signing error: not said to be Apple's refusal.
        self.refuse("compile-error")
        out = self.failed("iphone", "--no-launch")
        self.assertEqual(self.xcodebuilds(), [("build", None, None, None), ("build", APP, WIDGETS, NOTIFY)])
        self.assertNotIn("Apple refused", out)
        self.assertNotIn("Apple refused", self.rows(self.results)[0][3])

    def test_testflight_time_sensitive_refused(self):
        self.refuse("time-sensitive")
        out = self.failed("testflight")
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None)])
        rows = self.rows(self.results)
        self.assertEqual([r[:2] for r in rows], [["testflight", "failed"]])
        self.assertTrue(rows[0][3].startswith(TS_REFUSED + ", so nothing was uploaded (log "), rows)
        self.assertIn("hint: turn on Time Sensitive Notifications", out)

    def test_testflight_time_sensitive_refused_with_the_widgets_push(self):
        self.refuse("widgets-push", "time-sensitive")
        self.failed("testflight")
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None)])
        self.assertTrue(self.rows(self.results)[0][3].startswith(TS_REFUSED))

    def test_testflight_without_the_app_group_once_apple_refused_it(self):
        self.refuse("app-group")
        self.upload()
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None), ("archive", None, WIDGETS_PUSH, ""),
                                              ("archive", APP_PUSH, "", ""), ("export", None, None, None)])

    def test_testflight_never_without_an_app_group_for_another_failure(self):
        # The archive named the app group only among the entitlements it prints: it isn't archived without one.
        self.flaky(1)
        self.failed("testflight")
        self.assertEqual(self.xcodebuilds(), [("archive", None, None, None)])
        self.assertEqual([r[:2] for r in self.rows(self.results)], [["testflight", "failed"]])


class EntitlementFiles(unittest.TestCase):
    """The iPhone app's entitlements files deploy.sh signs with: each has Time Sensitive (the camera alerts through
    Sleep and Focus), so a build without the app group or push still has it, and each goes without only what it's
    for."""

    @staticmethod
    def load(name):
        with open(os.path.join(SOURCE, name), "rb") as handle:
            return plistlib.load(handle)

    def test_each_has_time_sensitive_and_goes_without_only_its_own(self):
        full = self.load(APP)
        self.assertIs(full.get(TIME_SENSITIVE), True)
        for name, without in ((APP_PUSH, (APP_GROUP,)), (APP_BASIC, (APP_GROUP, "aps-environment")),
                              (APP_NO_PUSH, (APP_GROUP, "aps-environment"))):
            self.assertEqual(self.load(name), dict((k, v) for k, v in full.items() if k not in without), name)


TV1 = "00008110-000131602193801E"
TV2 = "00008110-000E418C1E39801E"

# Builds the Apple TV app like xcodebuild with Xcode's signing: the app, its Info.plist and the profile it was signed
# with (listing the Apple TVs named in $FAKE/profile-devices, one per line). With $FAKE/tv-fails, the build fails.
TV_XCODEBUILD = LOG + r"""
case "$*" in
  *"-scheme WoodruffFamilyTV "*) ;;
  *) echo "unexpected xcodebuild $*" >&2; exit 99 ;;
esac
if [ -f "$FAKE/tv-fails" ]; then
  echo "/repo/App/TV/TVFilmScreen.swift:12:8: error: no such module 'Missing'"
  echo "** BUILD FAILED **"
  exit 65
fi
app="build/Build/Products/Release-appletvos/Woodruff Family.app"
mkdir -p "$app"
id=com.blakew316.woodruff.tv
if [ -f "$FAKE/tv-bundle-id" ]; then id=$(cat "$FAKE/tv-bundle-id"); fi
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<plist version="1.0"><dict>'
  echo "<key>CFBundleIdentifier</key><string>$id</string>"
  echo '<key>CFBundleVersion</key><string>412</string>'
  echo '</dict></plist>'
} >"$app/Info.plist"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<plist version="1.0"><dict>'
  echo '<key>Name</key><string>tvOS Team Provisioning Profile: *</string>'
  echo '<key>UUID</key><string>5e0f1c2d-0000-4000-8000-000000000000</string>'
  echo '<key>ExpirationDate</key><date>2027-11-04T05:00:00Z</date>'
  echo '<key>ProvisionedDevices</key><array>'
  while read -r udid; do
    if [ -n "$udid" ]; then echo "<string>$udid</string>"; fi
  done <"$FAKE/profile-devices"
  echo '</array></dict></plist>'
} >"$app/embedded.mobileprovision"
echo "** BUILD SUCCEEDED **"
"""

# The Apple TVs named in $FAKE/paired ("udid name" lines) are paired, next to an iPhone; an install works unless the
# Apple TV is named in $FAKE/install-fails.
TV_XCRUN = LOG + r"""
case "$1 $2 $3" in
  "devicectl list devices")
    out=""
    prev=""
    for a in "$@"; do
      if [ "$prev" = --json-output ]; then out=$a; fi
      prev=$a
    done
    {
      printf '{"result": {"devices": [{"hardwareProperties": {"udid": "00008150-001E68E80A32401C", "platform": "iOS", "reality": "physical"}, "deviceProperties": {"name": "Family iPhone"}}'
      while read -r udid name; do
        if [ -n "$udid" ]; then
          printf ', {"hardwareProperties": {"udid": "%s", "platform": "tvOS", "reality": "physical"}, "deviceProperties": {"name": "%s"}, "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"}}' "$udid" "$name"
        fi
      done <"$FAKE/paired"
      printf ']}}\n'
    } >"$out"
    ;;
  "devicectl device install")
    for a in "$@"; do
      if grep -q "^$a\$" "$FAKE/install-fails" 2>/dev/null; then echo "ERROR: The device is unavailable."; exit 1; fi
    done
    echo "App installed:"
    ;;
  "devicectl device process") ;;
  *) echo "unexpected xcrun $*" >&2; exit 99 ;;
esac
"""


@unittest.skipUnless(os.path.exists(BASH), "needs " + BASH)
class AppleTV(DeployHarness):
    """The Apple TV part: built with Xcode's signing, then kept for the updater (installed nowhere) or installed on
    every Apple TV the profile lists."""

    def setUp(self):
        super().setUp()
        open(os.path.join(self.fake, "has-branch"), "w").close()
        self.tool("xcodebuild", TV_XCODEBUILD)
        self.tool("xcrun", TV_XCRUN)
        self.tool("xcodegen", LOG)
        self.tool("codesign", LOG)
        self.tool("ditto", LOG + 'cp -R "$1" "$2"\n')
        webrtc = os.path.join(self.repo, "scripts", "fetch_webrtc.sh")
        with open(webrtc, "w") as handle:
            handle.write('#!/bin/sh\necho "WebRTC already here"\n')
        os.chmod(webrtc, 0o755)
        self.results = os.path.join(self.tmp, "results.tsv")
        self.kept = os.path.join(self.tmp, "kept-tv")
        self.paired("%s Living Room" % TV1, "%s Extra Apple TV" % TV2)
        self.listed(TV1, TV2)

    def paired(self, *lines):
        with open(os.path.join(self.fake, "paired"), "w") as handle:
            handle.write("".join(line + "\n" for line in lines))

    def listed(self, *udids):
        with open(os.path.join(self.fake, "profile-devices"), "w") as handle:
            handle.write("".join(udid + "\n" for udid in udids))

    def tv(self, *more):
        return self.deploy("--branch", "release", "--xcode-signing", "tv", "--results", self.results, *more)

    def installs(self):
        return [line for line in self.calls() if line.startswith("xcrun [devicectl] [device] [install]")]

    def launches(self):
        return [line for line in self.calls() if line.startswith("xcrun [devicectl] [device] [process] [launch]")]

    def kept_build(self):
        with open(os.path.join(self.kept, "build.json")) as handle:
            return json.load(handle)

    def test_kept_for_the_updater_and_installed_nowhere(self):
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 0, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "ok", HEAD]])
        self.assertEqual(rows[0][3], "signed by Xcode (team D8D94SXAG6), profile tvOS Team Provisioning Profile: * "
                                     "(expires 2027-11-04), kept in " + self.kept)
        self.assertEqual(self.installs(), [])
        self.assertEqual(self.launches(), [])
        self.assertTrue(os.path.isfile(os.path.join(self.kept, "Woodruff Family.app", "Info.plist")))
        meta = self.kept_build()
        self.assertEqual((meta["commit"], meta["build"]), (HEAD, 412))
        self.assertEqual(meta["devices"], [{"udid": TV1, "name": "Living Room"},
                                           {"udid": TV2, "name": "Extra Apple TV"}])
        self.assertEqual(meta["app_profile_expires"], "2027-11-04T05:00:00Z")
        # Built for any Apple TV, signed by Xcode's account, with this commit's build number.
        build = [line for line in self.calls() if line.startswith("xcodebuild ")]
        self.assertEqual(len(build), 1)
        for arg in ("[-scheme] [WoodruffFamilyTV]", "[-destination] [generic/platform=tvOS]",
                    "[-configuration] [Release]", "[DEVELOPMENT_TEAM=D8D94SXAG6]", "[CODE_SIGN_STYLE=Automatic]",
                    "[-allowProvisioningUpdates]", "[CURRENT_PROJECT_VERSION=412]", "[WOODRUFF_COMMIT=%s]" % HEAD,
                    "[build]"):
            self.assertIn(arg, build[0])
        self.assertIn("Apple TV: built and kept in", out)

    def test_installed_on_each_apple_tv_and_opened(self):
        # (What CoreDevice keeps on this Mac of the apps it installs is left alone.)
        deltas = os.path.join(self.tmp, "home", "Library", "Containers", "com.apple.CoreDevice.CoreDeviceService",
                              "Data", "Library", "Caches", "AppInstallationBinaryDeltas", "com.blakew316.woodruff.tv")
        os.makedirs(os.path.join(deltas, "22785a11", "Stashed"))
        status, out = self.tv()
        self.assertEqual(status, 0, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "ok", HEAD], ["tv", "installed", TV1],
                                                 ["tv", "installed", TV2]])
        self.assertEqual(rows[1][3], "Living Room: installed and opened")
        self.assertEqual(len(self.installs()), 2)
        self.assertIn("[--device] [%s] [--timeout] [300]" % TV1, self.installs()[0])
        self.assertTrue(self.installs()[0].endswith("/build/Build/Products/Release-appletvos/Woodruff Family.app]"))
        self.assertEqual(len(self.launches()), 2)
        self.assertTrue(self.launches()[1].endswith("[--device] [%s] [--timeout] [45] [com.blakew316.woodruff.tv]"
                                                     % TV2))
        self.assertTrue(os.path.isdir(os.path.join(deltas, "22785a11", "Stashed")))

    def test_not_opened_with_no_launch(self):
        status, out = self.tv("--no-launch")
        self.assertEqual(status, 0, out)
        self.assertEqual(len(self.installs()), 2)
        self.assertEqual(self.launches(), [])
        self.assertEqual(self.rows(self.results)[2][3], "Extra Apple TV: installed")

    def test_an_install_that_fails(self):
        with open(os.path.join(self.fake, "install-fails"), "w") as handle:
            handle.write(TV1 + "\n")
        status, out = self.tv()
        self.assertEqual(status, 1, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "ok", HEAD], ["tv", "failed", TV1],
                                                 ["tv", "installed", TV2]])
        self.assertIn("Living Room: the install failed: ERROR: The device is unavailable.", rows[1][3])

    def test_an_apple_tv_the_profile_doesnt_list(self):
        self.listed(TV1)
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 0, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv", "skipped", TV2], ["tv-build", "ok", HEAD]])
        self.assertEqual(rows[0][3], "Extra Apple TV: not installed, Xcode's profile doesn't list it")
        self.assertEqual(self.kept_build()["devices"], [{"udid": TV1, "name": "Living Room"}])

    def test_a_profile_that_lists_none_of_them(self):
        self.listed("00008110-0000000000000000")
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 1, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "failed", HEAD]])
        self.assertIn("lists none of the Apple TVs paired with this Mac", rows[0][3])
        self.assertFalse(os.path.exists(self.kept))

    def test_no_apple_tv_paired(self):
        self.paired()
        status, out = self.tv("--keep-tv", self.kept)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "skipped", HEAD]])
        self.assertIn("no Apple TV is paired with this Mac", rows[0][3])
        self.assertFalse(any(line.startswith("xcodebuild ") for line in self.calls()))   # nothing is built for none

    def test_a_build_that_fails(self):
        open(os.path.join(self.fake, "tv-fails"), "w").close()
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 1, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "failed", HEAD]])
        self.assertIn("the Apple TV app didn't build: /repo/App/TV/TVFilmScreen.swift:12:8: error: no such module",
                      rows[0][3])
        self.assertEqual(self.installs(), [])
        self.assertFalse(os.path.exists(self.kept))

    def test_another_apps_build_is_refused(self):
        with open(os.path.join(self.fake, "tv-bundle-id"), "w") as handle:
            handle.write("com.blakew316.woodruff")
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 1, out)
        rows = self.rows(self.results)
        self.assertEqual([r[:3] for r in rows], [["tv-build", "failed", HEAD]])
        self.assertIn("the built app is 'com.blakew316.woodruff', not com.blakew316.woodruff.tv", rows[0][3])

    def test_the_copy_kept_before_is_replaced(self):
        os.makedirs(os.path.join(self.kept, "Woodruff Family.app", "Old"))
        with open(os.path.join(self.kept, "build.json"), "w") as handle:
            handle.write("{}")
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 0, out)
        self.assertFalse(os.path.exists(os.path.join(self.kept, "Woodruff Family.app", "Old")))
        self.assertTrue(os.path.isfile(os.path.join(self.kept, "Woodruff Family.app", "embedded.mobileprovision")))
        self.assertEqual(self.kept_build()["build"], 412)

    def test_only_the_apple_tv_app_is_built(self):
        status, out = self.tv("--keep-tv", self.kept)
        self.assertEqual(status, 0, out)
        self.assertEqual([line for line in self.calls()
                          if line.startswith("xcodebuild ") and "WoodruffFamilyTV" not in line], [])


if __name__ == "__main__":
    unittest.main()
