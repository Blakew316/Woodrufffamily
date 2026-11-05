"""Tests for the parts of scripts/signing.py that need no certificates: the shared-build manifest and its check,
and the build.json deploy.sh keeps next to a signed iPhone app.

Run from the repository root: python3 -m unittest discover -s scripts/tests -p 'test_*.py'
"""

import hashlib
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("woodruff_signing", os.path.join(SCRIPTS, "signing.py"))
signing = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(signing)

COMMIT = hashlib.sha1(b"a commit").hexdigest()
NOW = datetime(2026, 11, 4, 12, 0, tzinfo=timezone.utc)
SIGNER = {"sha1": "AB" * 20, "cn": "Apple Development: Blake Woodruff (AAAAAAAAAA)", "team": "D8D94SXAG6",
          "not_after": datetime(2027, 11, 4, 5, 0, tzinfo=timezone.utc)}


class ShareManifest(unittest.TestCase):
    def manifest(self, **change):
        manifest = signing.share_manifest(COMMIT.upper() + "  ", "Pictures load once", "f" * 64, 1234, SIGNER,
                                          "com.woodruff.family.mac", "Mac Studio", NOW)
        manifest.update(change)
        return manifest

    def test_fields(self):
        manifest = self.manifest()
        self.assertEqual(manifest, {
            "format": 1, "commit": COMMIT, "subject": "Pictures load once", "sha256": "f" * 64, "bytes": 1234,
            "bundle_id": "com.woodruff.family.mac", "signer_sha1": "AB" * 20,
            "signer_cn": "Apple Development: Blake Woodruff (AAAAAAAAAA)", "signer_team": "D8D94SXAG6",
            "signer_expires": SIGNER["not_after"], "built_on": "Mac Studio", "shared_at": NOW})
        self.assertIsNone(signing.share_manifest(COMMIT, "", "0", 0, None, None, "x", NOW)["signer_cn"])

    def test_the_build_wanted(self):
        self.assertIsNone(signing.share_problem(self.manifest(), "f" * 64, 1234, COMMIT, "D8D94SXAG6"))
        self.assertEqual(signing.share_verdict(self.manifest(), "f" * 64, 1234, COMMIT.upper(), "D8D94SXAG6"),
                         (None, False))

    def test_still_arriving_is_worth_waiting_for(self):
        problem, final = signing.share_verdict(self.manifest(), "f" * 64, 99, COMMIT)
        self.assertEqual((problem, final), ("the zip has 99 bytes, not the 1234 its manifest says (still arriving?)",
                                            False))
        problem, final = signing.share_verdict(self.manifest(), "e" * 64, 1234, COMMIT)
        self.assertIn("SHA-256", problem)
        self.assertFalse(final)
        problem, final = signing.share_verdict(self.manifest(commit="0" * 40), "f" * 64, 1234, COMMIT)
        self.assertEqual(problem, "it's the build of 000000000000, not %s" % COMMIT[:12])
        self.assertFalse(final)
        self.assertEqual(signing.share_verdict([], "f" * 64, 1234, COMMIT), ("its manifest isn't a JSON object", False))

    def test_another_team_never_works(self):
        problem, final = signing.share_verdict(self.manifest(signer_team="ZZZZZZZZZZ"), "f" * 64, 1234, COMMIT,
                                               "D8D94SXAG6")
        self.assertEqual((problem, final), ("it was signed for team ZZZZZZZZZZ, not D8D94SXAG6", True))
        self.assertEqual(signing.share_problem(self.manifest(signer_team="ZZZZZZZZZZ"), "f" * 64, 1234, COMMIT,
                                               "D8D94SXAG6"), problem)
        # without a team to compare with, or a manifest that doesn't say, there's nothing to refuse
        self.assertIsNone(signing.share_problem(self.manifest(signer_team="ZZZZZZZZZZ"), "f" * 64, 1234, COMMIT))
        self.assertIsNone(signing.share_problem(self.manifest(signer_team=None), "f" * 64, 1234, COMMIT, "D8D94SXAG6"))


class Commands(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="signing-test.")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = signing.main(list(argv))
        return status, out.getvalue(), err.getvalue()

    def test_check_share_exit_codes(self):
        zip_path = os.path.join(self.tmp, "Woodruff Family %s.zip" % COMMIT[:12])
        with open(zip_path, "wb") as handle:
            handle.write(b"PK zip bytes")
        digest, size = signing.file_digest(zip_path)
        manifest = signing.share_manifest(COMMIT, "s", digest, size, SIGNER, "com.woodruff.family.mac", "Mac", NOW)
        path = os.path.join(self.tmp, "m.json")

        def check(**change):
            with open(path, "w") as handle:
                handle.write(json.dumps(dict(manifest, **change), default=signing._json_default))
            return self.main("check-share", "--manifest", path, "--zip", zip_path, "--commit", COMMIT,
                             "--team", "D8D94SXAG6")

        status, out, err = check()
        self.assertEqual(status, 0, err)
        self.assertEqual(json.loads(out)["commit"], COMMIT)
        status, out, err = check(bytes=size + 1)
        self.assertEqual(status, 2)
        self.assertIn("The shared build isn't usable yet: the zip has", err)
        status, out, err = check(signer_team="ZZZZZZZZZZ")
        self.assertEqual(status, 3)
        self.assertEqual(err.strip(),
                         "The shared build can't be used: it was signed for team ZZZZZZZZZZ, not D8D94SXAG6.")
        with open(path, "w") as handle:
            handle.write("{not json")
        status, _, err = self.main("check-share", "--manifest", path, "--zip", zip_path, "--commit", COMMIT)
        self.assertEqual(status, 2)

    def test_kept_build(self):
        devices = os.path.join(self.tmp, "iphones.json")
        with open(devices, "w") as handle:
            json.dump([{"udid": "P1", "name": "Blake’s iPhone"}, {"udid": "P2", "name": "Mia's iPhone"},
                       {"udid": "P9", "name": "Not signed for"}], handle)
        out_path = os.path.join(self.tmp, "build.json")
        status, out, err = self.main("kept-build", "--commit", COMMIT.upper(), "--build", "1234", "--identity",
                                     "ab" * 20, "--app-profile-uuid", "19912ee9", "--app-profile-expires",
                                     "2027-11-04T05:00:00Z", "--devices", devices, "--device", "P1", "P2", "P1",
                                     "--device", "P3", "--out", out_path)
        self.assertEqual(status, 0, err)
        with open(out_path, encoding="utf-8") as handle:
            record = json.load(handle)
        self.assertEqual(sorted(record), ["app_profile_expires", "app_profile_uuid", "build", "commit", "devices",
                                          "identity", "signed_at"])
        self.assertEqual(record["commit"], COMMIT)
        self.assertEqual(record["build"], 1234)
        self.assertEqual(record["identity"], "AB" * 20)
        self.assertEqual(record["app_profile_uuid"], "19912ee9")
        self.assertEqual(record["app_profile_expires"], "2027-11-04T05:00:00Z")
        self.assertRegex(record["signed_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(record["devices"], [{"udid": "P1", "name": "Blake’s iPhone"},
                                             {"udid": "P2", "name": "Mia's iPhone"}, {"udid": "P3", "name": "P3"}])
        self.assertEqual([n for n in os.listdir(self.tmp) if n.startswith(".build.")], [])

    def test_kept_build_record(self):
        record = signing.kept_build(COMMIT, "not a number", "2026-11-04T12:00:00Z", "ab", "", "", [" P1 ", "", None])
        self.assertIsNone(record["build"])
        self.assertEqual(record["devices"], [{"udid": "P1", "name": "P1"}])


class AppGroup(unittest.TestCase):
    """The widgets' app group is signed in only when the profile allows it."""

    def profile(self, extra):
        ents = {"application-identifier": "D8D94SXAG6.com.blakew316.woodruff",
                "com.apple.developer.team-identifier": "D8D94SXAG6",
                "get-task-allow": True, "com.apple.developer.homekit": True}
        ents.update(extra)
        return {"entitlements": ents}

    def test_without_group(self):
        ents, problems = signing.build_entitlements(self.profile({}), "app")
        self.assertEqual(problems, [])
        self.assertNotIn("com.apple.security.application-groups", ents)

    def test_with_group(self):
        p = self.profile({"com.apple.security.application-groups": ["group.com.woodruff.family"]})
        ents, problems = signing.build_entitlements(p, "app")
        self.assertEqual(problems, [])
        self.assertEqual(ents["com.apple.security.application-groups"], ["group.com.woodruff.family"])

    def test_other_group(self):
        p = self.profile({"com.apple.security.application-groups": ["group.other"]})
        ents, problems = signing.build_entitlements(p, "app")
        self.assertEqual(problems, [])
        self.assertNotIn("com.apple.security.application-groups", ents)


class Push(unittest.TestCase):
    """Push is signed in with the profile's own aps-environment, only for the app."""

    def profile(self, extra):
        ents = {"application-identifier": "D8D94SXAG6.com.blakew316.woodruff",
                "com.apple.developer.team-identifier": "D8D94SXAG6",
                "get-task-allow": True, "com.apple.developer.homekit": True}
        ents.update(extra)
        return {"entitlements": ents}

    def test_profile_with_push(self):
        ents, _ = signing.build_entitlements(self.profile({"aps-environment": "development"}), "app")
        self.assertEqual(ents["aps-environment"], "development")

    def test_profile_without_push(self):
        ents, _ = signing.build_entitlements(self.profile({}), "app")
        self.assertNotIn("aps-environment", ents)

    def test_not_for_widgets(self):
        ents, _ = signing.build_entitlements(self.profile({"aps-environment": "development"}), "widget")
        self.assertNotIn("aps-environment", ents)


if __name__ == "__main__":
    unittest.main()
