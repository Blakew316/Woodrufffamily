#!/usr/bin/python3
"""Fills in TestFlight's "What to Test" for a build just uploaded, from the commits since the last build noted.

Run by deploy.sh in the background after a TestFlight upload (the Mac Studio only). It waits for App Store Connect to
list the build (up to an hour), then sets the notes. Anything that goes wrong is only logged: the build and its upload
never depend on this.

Apple's /usr/bin/python3 (3.9), standard library only. The App Store Connect key is the one deploy.sh uploads with
(AuthKey_<id>.p8 and issuer.txt in ~/Library/Application Support/Woodruff Family/AppStoreConnect); its signature is
made with /usr/bin/openssl.

    testflight_notes.py --build 324 --bundle-id com.blakew316.woodruff --repo <repository folder>
"""

import argparse
import base64
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
ASC_DIR = os.path.expanduser("~/Library/Application Support/Woodruff Family/AppStoreConnect")
LAST_NOTED = "notes-last-commit.txt"
MAX_NOTES = 3900   # Apple allows 4000 characters


def log(msg):
    sys.stdout.write("%s testflight-notes: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stdout.flush()


# MARK: The notes

def tidy_subject(subject):
    """A commit subject as a line of notes: without the ship marker, the attribution or a trailing full stop."""
    s = re.sub(r"\s*\[release\]\s*", " ", subject, flags=re.IGNORECASE).strip()
    return s.rstrip(".").strip()


def notes_from_subjects(subjects):
    """The notes for a build: one line per commit (newest first), without merges or repeats, cut to Apple's limit."""
    lines = []
    for raw in subjects:
        s = tidy_subject(raw)
        if not s or s.lower().startswith("merge ") or ("- " + s) in lines:
            continue
        lines.append("- " + s)
    text = "\n".join(lines) if lines else "Fixes and improvements."
    if len(text) > MAX_NOTES:
        text = text[:MAX_NOTES - 1].rsplit("\n", 1)[0] + "\n…"
    return text


def commit_subjects(repo, since, head="HEAD"):
    """The subjects of the commits after [since] up to [head] (the last 10 when [since] is unknown)."""
    if since:
        rng = ["%s..%s" % (since, head)]
    else:
        rng = ["-n", "10", head]
    out = subprocess.run(["git", "-C", repo, "log", "--no-merges", "--format=%s"] + rng,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    if out.returncode != 0:
        if since:
            return commit_subjects(repo, None, head)
        return []
    return [l for l in out.stdout.splitlines() if l.strip()]


# MARK: Signing in to App Store Connect

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw(der, size=32):
    """An ECDSA signature as openssl writes it (DER: SEQUENCE of two INTEGERs) as JWT wants it (r and s, 32 bytes each)."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        if len(value) > size:
            raise ValueError("integer too long")
        parts.append(value.rjust(size, b"\x00"))
        i += 2 + n
    return parts[0] + parts[1]


def find_key():
    """(key file, key id, issuer id) from ASC_DIR, or None."""
    issuer_file = os.path.join(ASC_DIR, "issuer.txt")
    try:
        with open(issuer_file) as f:
            issuer = "".join(f.read().split())
    except OSError:
        return None
    for path in sorted(glob.glob(os.path.join(ASC_DIR, "AuthKey_*.p8"))):
        kid = os.path.basename(path)[len("AuthKey_"):-len(".p8")]
        if kid and issuer:
            return path, kid, issuer
    return None


def token(key):
    path, kid, issuer = key
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": kid, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = ("%s.%s" % (header, payload)).encode()
    out = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", path], input=signing_input,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if out.returncode != 0:
        raise RuntimeError("openssl couldn't sign: %s" % out.stderr.decode(errors="replace").strip())
    return "%s.%s" % (signing_input.decode(), b64url(der_to_raw(out.stdout)))


def call(key, method, path, body=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token(key))
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise RuntimeError("%s %s: HTTP %s %s" % (method, path.split("?")[0], e.code, detail))


# MARK: Setting the notes

def set_notes(key, bundle_id, build, notes, wait_minutes=60):
    apps = call(key, "GET", "/apps?" + urllib.parse.urlencode({"filter[bundleId]": bundle_id, "limit": 1}))
    if not apps.get("data"):
        log("no app for %s in App Store Connect" % bundle_id)
        return False
    app = apps["data"][0]["id"]
    build_id = None
    deadline = time.time() + wait_minutes * 60
    while time.time() < deadline:
        found = call(key, "GET", "/builds?" + urllib.parse.urlencode(
            {"filter[app]": app, "filter[version]": str(build), "limit": 1}))
        if found.get("data"):
            build_id = found["data"][0]["id"]
            break
        time.sleep(60)
    if not build_id:
        log("build %s didn't show up in App Store Connect within %d minutes" % (build, wait_minutes))
        return False
    existing = call(key, "GET", "/builds/%s/betaBuildLocalizations" % build_id).get("data") or []
    mine = [l for l in existing if (l.get("attributes") or {}).get("locale") == "en-US"] or existing
    if mine:
        call(key, "PATCH", "/betaBuildLocalizations/%s" % mine[0]["id"],
             {"data": {"type": "betaBuildLocalizations", "id": mine[0]["id"], "attributes": {"whatsNew": notes}}})
    else:
        call(key, "POST", "/betaBuildLocalizations",
             {"data": {"type": "betaBuildLocalizations", "attributes": {"whatsNew": notes, "locale": "en-US"},
                       "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    log("build %s: What to Test set (%d lines)" % (build, notes.count("\n") + 1))
    return True


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--build", required=True)
    p.add_argument("--bundle-id", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--wait-minutes", type=int, default=60)
    a = p.parse_args(argv)
    key = find_key()
    if not key:
        log("no App Store Connect key in %s: notes not set" % ASC_DIR)
        return 0
    last_file = os.path.join(ASC_DIR, LAST_NOTED)
    try:
        with open(last_file) as f:
            since = f.read().strip() or None
    except OSError:
        since = None
    head = subprocess.run(["git", "-C", a.repo, "rev-parse", "HEAD"], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30).stdout.strip()
    notes = notes_from_subjects(commit_subjects(a.repo, since))
    try:
        if set_notes(key, a.bundle_id, a.build, notes, a.wait_minutes) and head:
            with open(last_file, "w") as f:
                f.write(head + "\n")
    except Exception as e:   # only ever logged: nothing waits on this
        log("notes not set: %s" % e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
