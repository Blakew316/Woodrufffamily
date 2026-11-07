import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import testflight_notes as tn  # noqa: E402


class NotesTests(unittest.TestCase):
    def test_subjects_become_lines(self):
        text = tn.notes_from_subjects([
            "Speed: sooner launch steps [release]",
            "Merge branch 'x'",
            "Home: a sensor keeps its brightness.",
            "Speed: sooner launch steps",
        ])
        self.assertEqual(text, "- Speed: sooner launch steps\n- Home: a sensor keeps its brightness")

    def test_release_marker_removed_in_any_case(self):
        self.assertEqual(tn.tidy_subject("Fix [RELEASE] thing"), "Fix thing")

    def test_nothing_says_so(self):
        self.assertEqual(tn.notes_from_subjects([]), "Fixes and improvements.")

    def test_cut_to_apples_limit(self):
        text = tn.notes_from_subjects(["Change number %d with some words in it" % i for i in range(400)])
        self.assertLessEqual(len(text), 4000)
        self.assertTrue(text.endswith("…"))


class StateTests(unittest.TestCase):
    def test_state_line(self):
        b = {"attributes": {"version": "366", "processingState": "VALID", "expired": False}}
        d = {"attributes": {"internalBuildState": "IN_BETA_TESTING"}}
        self.assertEqual(tn.state_line(b, d), "build 366: VALID, not expired, internal IN_BETA_TESTING")

    def test_state_line_expired_without_detail(self):
        b = {"attributes": {"version": "365", "processingState": "VALID", "expired": True}}
        self.assertEqual(tn.state_line(b, None), "build 365: VALID, expired, internal ?")


class SignatureTests(unittest.TestCase):
    def test_der_to_raw(self):
        r = b"\x00" + b"\x81" * 32          # a leading zero (high bit set)
        s = b"\x05" * 31                    # shorter: padded
        der = b"\x30" + bytes([4 + len(r) + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        raw = tn.der_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x81" * 32)
        self.assertEqual(raw[32:], b"\x00" + b"\x05" * 31)

    def test_not_der(self):
        with self.assertRaises(ValueError):
            tn.der_to_raw(b"nope-not-der")

    def test_b64url(self):
        self.assertEqual(tn.b64url(b"\xff\xfe"), "__4")


if __name__ == "__main__":
    unittest.main()
