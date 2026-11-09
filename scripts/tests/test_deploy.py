"""Runs scripts/deploy.sh with /bin/bash (macOS's bash 3.2 on CI) against stand-in tools, for its options and
--results lines on the way that ends before anything is built, and for the iPhone build's and the TestFlight
archive's retries when Apple refuses an entitlement (a stand-in xcodebuild that refuses the one asked). Nothing real
is built, signed or installed: every tool it would call first in PATH is a stand-in in a temporary folder, and the
checkout is a copy.

Run from the repository root: python3 -m unittest discover -s scripts/tests -p 'test_*.py'
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
                     ["--results", os.path.join(self.tmp, "no", "such", "folder", "r.tsv")],
                     ["mac", "mac-shared"]):
            status, out = self.deploy(*args)
            self.assertEqual(status, 2, (args, out))
        self.assertEqual(self.calls(), [])   # nothing ran for any of them

    def test_help(self):
        status, out = self.deploy("--help")
        self.assertEqual(status, 0)
        for option in ("--branch <name>", "--wait <seconds>", "--keep-iphone <dir>", "--no-launch",
                       "--results <file>", "--expect <commit>"):
            self.assertIn(option, out)

    def test_syntax(self):
        proc = subprocess.run([BASH, "-n", os.path.join(SCRIPTS, "deploy.sh")], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT)
        self.assertEqual(proc.returncode, 0, proc.stdout)


APP = "App/iOS/WoodruffFamily.entitlements"
WIDGETS = "App/Widgets/WoodruffWidgets.entitlements"
WIDGETS_PUSH = "App/Widgets/WoodruffWidgetsPush.entitlements"
NOTIFY = "App/NotificationService/WoodruffNotifications.entitlements"
UDID = "00008110-001A2B3C4D5E801E"

# Builds and archives like xcodebuild, signing with the entitlements files it's given (else project.yml's) and refusing
# what $FAKE/refuse names: "widgets-push" (push in the widgets' entitlements), "notify-group" (the notification
# extension's app group). Like xcodebuild, it prints every target's entitlements, so push and the app group are named
# in every log.
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
refused=""
if grep -q widgets-push "$FAKE/refuse" 2>/dev/null && [ "$wents" = App/Widgets/WoodruffWidgetsPush.entitlements ]; then
  echo "error: Provisioning profile \"iOS Team Provisioning Profile: com.blakew316.woodruff.widgets\" doesn't include the aps-environment entitlement. (in target 'WoodruffWidgets' from project 'WoodruffFamily')"
  refused=1
fi
if grep -q notify-group "$FAKE/refuse" 2>/dev/null && [ -n "$nents" ]; then
  echo "error: Provisioning profile \"iOS Team Provisioning Profile: com.blakew316.woodruff.notifications\" doesn't include the com.apple.security.application-groups entitlement. (in target 'WoodruffNotifications' from project 'WoodruffFamily')"
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
    refused: the widgets' push, the notification extension's app group, or both."""

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
        self.results = os.path.join(self.tmp, "results.tsv")

    def refuse(self, *what):
        with open(os.path.join(self.fake, "refuse"), "w") as handle:
            handle.write("\n".join(what) + "\n")

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


if __name__ == "__main__":
    unittest.main()
