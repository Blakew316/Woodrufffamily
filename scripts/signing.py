#!/usr/bin/env python3
"""Choose the signing identity and provisioning profiles that are already on this Mac (for scripts/deploy.sh).

Read-only. It runs `security find-identity`, `security find-certificate`, `codesign -d` and
`xcrun devicectl list devices`, and reads the profiles in the two profile folders itself (a profile is a signed
CMS message whose content is a plist). It never runs `security cms -D`, which imports a profile's certificates
into the login keychain while it decodes it. It never creates, imports, revokes, deletes or changes a
certificate, key, profile, keychain or keychain search list, never writes into a profile folder, and never
contacts Apple. The only file it writes is the --out file of share-manifest and entitlements.

  signing.py identities [--team TEAM]          valid "Apple Development" identities (of one team)
  signing.py profiles                           every provisioning profile on this Mac, decoded
  signing.py pick-ios --team TEAM --app-id ID --widgets-id ID [--need-entitlement KEY]... --device UDID...
  signing.py entitlements --profile PATH --kind app|widget [--bundle-id ID] [--out FILE]
  signing.py pick-mac --team TEAM [--app PATH]
  signing.py signer [--app PATH]                the certificate that signed an app (SHA-1, CN, team)
  signing.py share-manifest --app PATH --zip ZIP --commit SHA [--subject TEXT] --out FILE
  signing.py check-share --manifest FILE --zip ZIP --commit SHA [--team TEAM]
  signing.py devices                            the iOS devices paired with this Mac
  signing.py bundle-id PATH                     CFBundleIdentifier of a .app or .appex
  signing.py get FILE KEY.PATH                  values from a JSON file, one per line ("*" walks a list)

pick-ios, pick-mac and entitlements exit 2, with the reason, when it can't be done. Python 3.7+, standard
library only. The choices are pure functions (pick_ios, pick_mac, build_entitlements, ...) so they can be
tested with made-up profiles.
"""

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

PROFILE_DIRS = (
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles",
    "~/Library/MobileDevice/Provisioning Profiles",
)
PROFILE_SUFFIXES = (".mobileprovision", ".provisionprofile")
DEVELOPMENT = "Apple Development:"
DEFAULT_MAC_APP = "/Applications/Woodruff Family.app"

# What the signed iPhone app and its widgets carry besides application-identifier and
# com.apple.developer.team-identifier (copied from their profile). Nothing else: in particular no
# keychain-access-groups, so the app's keychain items (the TVs' pairings) stay in its default group.
EXTRA_ENTITLEMENTS = {
    "app": {"get-task-allow": True, "com.apple.developer.homekit": True},
    "widget": {"get-task-allow": True},
}

NO_IDENTITY = "isn't for any valid signing identity on this Mac"
WIDGET_ROLES = ("widgets", "widgets-wildcard")

OID_CN = b"\x55\x04\x03"
OID_OU = b"\x55\x04\x0b"
OID_SIGNED_DATA = b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02"  # 1.2.840.113549.1.7.2


# ---------------------------------------------------------------------------------------------- helpers


def run(argv, input_bytes=None, timeout=120):
    """Run a read-only command: (status, stdout, stderr). Never raises; never reads the terminal."""
    try:
        proc = subprocess.run(
            argv,
            input=input_bytes,
            stdin=None if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, b"", str(exc).encode("utf-8", "replace")
    return proc.returncode, proc.stdout, proc.stderr


def _unique(items):
    seen, out = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def _aware(value):
    """plistlib's dates are naive UTC; make them aware (None for anything that isn't a date)."""
    if not isinstance(value, datetime):
        return None
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _iso(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _day(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d")


def _show(value):
    return json.dumps(value, default=_json_default)


def _json_default(value):
    if isinstance(value, datetime):
        return _iso(value)
    if isinstance(value, (bytes, bytearray)):
        return base64.b64encode(bytes(value)).decode("ascii")
    if isinstance(value, (set, tuple)):
        return list(value)
    return str(value)


def print_json(value):
    sys.stdout.write(json.dumps(value, indent=2, default=_json_default) + "\n")


def _fail(message, status=2):
    sys.stderr.write(message.rstrip() + "\n")
    return status


# ------------------------------------------------------------------------------------- certificates (DER)


def _tlv(data, pos, limit):
    """(tag, value start, value end) of the DER element at pos, which must end by limit."""
    if pos + 2 > limit:
        raise ValueError("truncated DER")
    tag = data[pos]
    pos += 1
    if tag & 0x1F == 0x1F:  # high tag number form
        while pos < limit and data[pos] & 0x80:
            pos += 1
        pos += 1
    if pos >= limit:
        raise ValueError("truncated DER")
    length = data[pos]
    pos += 1
    if length & 0x80:
        count = length & 0x7F
        if count == 0 or count > 4 or pos + count > limit:
            raise ValueError("unsupported DER length")
        length = int.from_bytes(data[pos:pos + count], "big")
        pos += count
    if pos + length > limit:
        raise ValueError("truncated DER")
    return tag, pos, pos + length


def _children(data, start, end):
    out, pos = [], start
    while pos < end:
        tag, value_start, value_end = _tlv(data, pos, end)
        out.append((tag, value_start, value_end))
        pos = value_end
    return out


def _der_string(tag, raw):
    try:
        if tag == 0x1E:  # BMPString
            return raw.decode("utf-16-be")
        if tag == 0x1C:  # UniversalString
            return raw.decode("utf-32-be")
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def _der_time(tag, raw):
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        return None
    formats = {0x17: ("%y%m%d%H%M%SZ", "%y%m%d%H%MZ"), 0x18: ("%Y%m%d%H%M%SZ",)}.get(tag, ())
    for fmt in formats:
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def certificate_info(der):
    """{"ou", "cn", "not_after"} read from an X.509 certificate's DER; None for whatever can't be read."""
    info = {"ou": None, "cn": None, "not_after": None}
    if not der:
        return info
    try:
        tag, start, end = _tlv(der, 0, len(der))  # Certificate
        if tag != 0x30:
            return info
        tag, start, end = _tlv(der, start, end)  # tbsCertificate
        if tag != 0x30:
            return info
        fields = _children(der, start, end)
        if fields and fields[0][0] == 0xA0:  # [0] version
            fields = fields[1:]
        # serialNumber, signature, issuer, validity, subject, ...
        if len(fields) < 5 or fields[3][0] != 0x30 or fields[4][0] != 0x30:
            return info
        times = _children(der, fields[3][1], fields[3][2])
        if len(times) == 2:
            info["not_after"] = _der_time(times[1][0], der[times[1][1]:times[1][2]])
        for _, set_start, set_end in _children(der, fields[4][1], fields[4][2]):  # each RDN (a SET)
            for _, atv_start, atv_end in _children(der, set_start, set_end):  # AttributeTypeAndValue
                parts = _children(der, atv_start, atv_end)
                if len(parts) != 2 or parts[0][0] != 0x06:
                    continue
                oid = der[parts[0][1]:parts[0][2]]
                value = _der_string(parts[1][0], der[parts[1][1]:parts[1][2]])
                if oid == OID_OU and info["ou"] is None:
                    info["ou"] = value
                elif oid == OID_CN and info["cn"] is None:
                    info["cn"] = value
    except (ValueError, IndexError):
        pass
    return info


def ou_from_subject(text):
    """The OU in `openssl x509 -subject` output (RFC 2253 "a=b,c=d" or the older "/a=b/c=d")."""
    text = text.strip()
    if text.startswith("subject="):
        text = text[len("subject="):].strip()
    if text.startswith("/"):
        match = re.search(r"/OU=((?:\\.|[^/\\])*)", text)
        return re.sub(r"\\(.)", r"\1", match.group(1)).strip() if match else None
    for part in re.split(r"(?<!\\),", text):
        key, sep, value = part.partition("=")
        if sep and key.strip().upper() == "OU":
            return re.sub(r"\\(.)", r"\1", value).strip()
    return None


def openssl_ou(der):
    """The certificate's OU by asking openssl (used only when the DER can't be read here)."""
    status, out, _ = run(["openssl", "x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253"],
                         input_bytes=der)
    return ou_from_subject(out.decode("utf-8", "replace")) if status == 0 else None


# ----------------------------------------------------------------------------------------- identities

_IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$')
_INVALID_IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s+\(([^()]+)\)\s*$')
_PEM = re.compile(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", re.S)


def parse_identities(text):
    """`security find-identity -v -p codesigning` -> [{"sha1", "name"}] (SHA-1 uppercase, no repeats)."""
    out, seen = [], set()
    for line in text.splitlines():
        match = _IDENTITY_LINE.match(line)
        if not match:
            continue
        sha1 = match.group(1).upper()
        if sha1 not in seen:
            seen.add(sha1)
            out.append({"sha1": sha1, "name": match.group(2)})
    return out


def parse_invalid_identities(text):
    """`security find-identity -p codesigning` (without -v) -> [{"sha1", "name", "reason"}] for the identities
    this Mac has but can't sign with: macOS prints why after the name, e.g. (CSSMERR_TP_CERT_REVOKED)."""
    out, seen = [], set()
    for line in text.splitlines():
        match = _INVALID_IDENTITY_LINE.match(line)
        if match and match.group(1).upper() not in seen:
            seen.add(match.group(1).upper())
            out.append({"sha1": match.group(1).upper(), "name": match.group(2), "reason": match.group(3).strip()})
    return out


def parse_pem_certificates(text):
    """{SHA-1: DER} for each PEM block in `security find-certificate -a -Z -p` output.

    The SHA-1 is computed from the DER itself, so it doesn't depend on how the "SHA-1 hash:" lines print.
    """
    certs = {}
    for match in _PEM.finditer(text):
        try:
            der = base64.b64decode("".join(match.group(1).split()), validate=True)
        except ValueError:
            continue
        if der:
            certs[hashlib.sha1(der).hexdigest().upper()] = der
    return certs


def team_identities(identities, certs, team=None, ou_reader=openssl_ou):
    """The "Apple Development:" identities whose certificate's OU is the team.

    An identity whose OU can't be read (no certificate found, unreadable) is kept rather than dropped.
    """
    kept = []
    for ident in identities:
        if not ident["name"].startswith(DEVELOPMENT):
            continue
        der = certs.get(ident["sha1"])
        info = certificate_info(der)
        ou = info["ou"]
        if ou is None and der and ou_reader is not None:
            ou = ou_reader(der)
        if team and ou is not None and ou != team:
            continue
        entry = dict(ident)
        entry.update(ou=ou, cn=info["cn"], not_after=info["not_after"])
        kept.append(entry)
    return kept


def read_identities():
    _, out, _ = run(["security", "find-identity", "-v", "-p", "codesigning"])
    return parse_identities(out.decode("utf-8", "replace"))


def read_invalid_identities():
    _, out, _ = run(["security", "find-identity", "-p", "codesigning"])
    return parse_invalid_identities(out.decode("utf-8", "replace"))


def read_certificates():
    _, out, _ = run(["security", "find-certificate", "-a", "-Z", "-p", "-c", "Apple Development"])
    return parse_pem_certificates(out.decode("utf-8", "replace"))


# ------------------------------------------------------------------------------------------- profiles


def profile_from_plist(plist, path=""):
    """A decoded profile's plist -> the fields the choices use."""
    ents = plist.get("Entitlements")
    if not isinstance(ents, dict):
        ents = {}
    app_id = ents.get("application-identifier") or ents.get("com.apple.application-identifier") or ""
    teams = plist.get("TeamIdentifier")
    team = teams[0] if isinstance(teams, list) and teams else ents.get("com.apple.developer.team-identifier", "")
    certificates, seen = [], set()
    for der in plist.get("DeveloperCertificates") or []:
        if not isinstance(der, (bytes, bytearray)):
            continue
        sha1 = hashlib.sha1(bytes(der)).hexdigest().upper()
        if sha1 not in seen:
            seen.add(sha1)
            info = certificate_info(bytes(der))
            certificates.append({"sha1": sha1, "cn": info["cn"], "not_after": info["not_after"]})
    devices = [str(udid).strip().upper() for udid in plist.get("ProvisionedDevices") or [] if isinstance(udid, str)]
    platforms = plist.get("Platform")
    return {
        "name": str(plist.get("Name") or ""),
        "uuid": str(plist.get("UUID") or ""),
        "path": path,
        "team": str(team or ""),
        "app_id": str(app_id),
        "entitlements": ents,
        "expires": _aware(plist.get("ExpirationDate")),
        "devices": devices,
        "all_devices": plist.get("ProvisionsAllDevices") is True,
        "cert_sha1s": [cert["sha1"] for cert in certificates],
        "certificates": certificates,
        "platforms": [str(p) for p in platforms] if isinstance(platforms, list) else [],
        "xcode_managed": plist.get("IsXcodeManaged") is True,
    }


def _ber(data, pos, limit, depth=0):
    """(tag, value start, value end, next element) of the BER element at pos, which must end by limit.

    DER's definite lengths and BER's indefinite ones (0x80: the value runs to its end-of-contents octets).
    """
    if depth > 32:
        raise ValueError("BER nested too deeply")
    if pos + 2 > limit:
        raise ValueError("truncated BER")
    tag = data[pos]
    pos += 1
    if tag & 0x1F == 0x1F:  # high tag number form
        while pos < limit and data[pos] & 0x80:
            pos += 1
        pos += 1
    if pos >= limit:
        raise ValueError("truncated BER")
    length = data[pos]
    pos += 1
    if length == 0x80:
        if not tag & 0x20:
            raise ValueError("indefinite length on a primitive element")
        start = pos
        while True:
            if pos + 2 > limit:
                raise ValueError("no end-of-contents octets")
            if data[pos] == 0 and data[pos + 1] == 0:
                return tag, start, pos, pos + 2
            pos = _ber(data, pos, limit, depth + 1)[3]
    if length & 0x80:
        count = length & 0x7F
        if count > 4 or pos + count > limit:
            raise ValueError("unsupported BER length")
        length = int.from_bytes(data[pos:pos + count], "big")
        pos += count
    if pos + length > limit:
        raise ValueError("truncated BER")
    return tag, pos, pos + length, pos + length


def _ber_children(data, start, end, depth=0):
    out, pos = [], start
    while pos < end:
        tag, value_start, value_end, pos = _ber(data, pos, end, depth)
        out.append((tag, value_start, value_end))
    return out


def _octet_string(data, tag, start, end, depth=0):
    """An OCTET STRING's bytes: primitive, or BER's constructed form (its pieces joined)."""
    if tag == 0x04:
        return bytes(data[start:end])
    if tag == 0x24 and depth < 32:
        return b"".join(_octet_string(data, t, s, e, depth + 1) for t, s, e in _ber_children(data, start, end))
    raise ValueError("not an OCTET STRING")


def cms_signed_content(data):
    """The content of a CMS SignedData message (DER or BER), read here without the Security framework.

    ContentInfo { contentType signedData, [0] SignedData { version, digestAlgorithms,
    encapContentInfo { eContentType, [0] OCTET STRING }, ... } }. Raises ValueError if it isn't one.
    """
    tag, start, end, _ = _ber(data, 0, len(data))
    if tag != 0x30:
        raise ValueError("not a CMS message")
    info = _ber_children(data, start, end)
    if len(info) < 2 or info[0][0] != 0x06 or data[info[0][1]:info[0][2]] != OID_SIGNED_DATA or info[1][0] != 0xA0:
        raise ValueError("not CMS SignedData")
    wrapper = _ber_children(data, info[1][1], info[1][2])
    if not wrapper or wrapper[0][0] != 0x30:
        raise ValueError("no SignedData")
    signed = _ber_children(data, wrapper[0][1], wrapper[0][2])
    if len(signed) < 3 or signed[2][0] != 0x30:
        raise ValueError("no encapsulated content")
    encap = _ber_children(data, signed[2][1], signed[2][2])
    if len(encap) < 2 or encap[1][0] != 0xA0:
        raise ValueError("the content isn't in the message")
    content = _ber_children(data, encap[1][1], encap[1][2])
    if len(content) != 1:
        raise ValueError("unexpected content")
    return _octet_string(data, *content[0])


def _load_plist(blob):
    """A plist dict from bytes that hold one (anything before "<?xml" is skipped), or None."""
    if not blob:
        return None
    start = blob.find(b"<?xml")
    if start > 0:
        blob = blob[start:]
    try:
        plist = plistlib.loads(blob)
    except Exception:  # noqa: BLE001 - anything that isn't a plist
        return None
    return plist if isinstance(plist, dict) else None


def profile_plist(raw, path=None):
    """A provisioning profile's plist from the file's bytes, or None if it can't be read.

    The CMS message is parsed here; failing that, the plist is looked for in the bytes as they are; failing
    that (and given the path), LibreSSL's `openssl smime` (which has no keychain) extracts it. Never
    `security cms -D`: it adds the message's certificates to the login keychain while decoding.
    """
    try:
        plist = _load_plist(cms_signed_content(raw))
    except (ValueError, IndexError):
        plist = None
    if plist is None:
        start = raw.find(b"<?xml")
        end = raw.find(b"</plist>", start) if start >= 0 else -1
        if end > start:
            plist = _load_plist(raw[start:end + len(b"</plist>")])
    if plist is None and path:
        status, out, _ = run(["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", path])
        if status == 0:
            plist = _load_plist(out)
    return plist


def decode_profile(path):
    """The profile at path read into a profile dict, or None if it can't be read."""
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return None
    plist = profile_plist(raw, path)
    return profile_from_plist(plist, path) if plist is not None else None


def profile_files(dirs=PROFILE_DIRS):
    files = []
    for folder in dirs:
        folder = os.path.expanduser(folder)
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for name in names:
            path = os.path.join(folder, name)
            if name.endswith(PROFILE_SUFFIXES) and os.path.isfile(path):
                files.append(path)
    return files


def load_profiles(dirs=PROFILE_DIRS):
    out, seen = [], set()
    for path in profile_files(dirs):
        profile = decode_profile(path)
        if profile is None:
            continue
        key = profile["uuid"] or path
        if key not in seen:
            seen.add(key)
            out.append(profile)
    return out


# --------------------------------------------------------------------------------------- entitlements


def wildcard_match(pattern, value):
    """A profile's value with "*" (like "TEAM.*") matches any run of characters there; else equal."""
    if not isinstance(pattern, str) or not isinstance(value, str):
        return False
    if "*" not in pattern:
        return pattern == value
    regex = ".*".join(re.escape(piece) for piece in pattern.split("*"))
    return re.fullmatch(regex, value, re.S) is not None


def value_allowed(want, have):
    """Is the entitlement value `want` allowed by the profile's value `have`?"""
    if isinstance(want, bool) or isinstance(have, bool):
        return isinstance(want, bool) and isinstance(have, bool) and want == have
    if isinstance(want, str):
        if isinstance(have, str):
            return wildcard_match(have, want)
        if isinstance(have, list):
            return any(wildcard_match(item, want) for item in have)
        return False
    if isinstance(want, list):
        return all(value_allowed(item, have) for item in want)
    return want == have


def subset_problems(wanted, profile_entitlements):
    """Why `wanted` isn't a subset of the profile's Entitlements (empty: it is)."""
    problems = []
    for key, want in wanted.items():
        if key not in profile_entitlements:
            problems.append("doesn't have %s" % key)
        elif not value_allowed(want, profile_entitlements[key]):
            problems.append("has %s %s, not %s" % (key, _show(profile_entitlements[key]), _show(want)))
    return problems


def build_entitlements(profile, kind, bundle_id=None):
    """(entitlements, problems) to sign the "app" or the "widget" with this profile.

    application-identifier and com.apple.developer.team-identifier come from the profile (with the bundle id
    filled in where the profile has a wildcard), plus EXTRA_ENTITLEMENTS[kind]; nothing else. The result
    must be a subset of the profile's Entitlements, else entitlements is None and problems says why.
    """
    if kind not in EXTRA_ENTITLEMENTS:
        raise ValueError("kind must be app or widget")
    ents = profile["entitlements"]
    have_id = ents.get("application-identifier")
    team_id = ents.get("com.apple.developer.team-identifier")
    problems = []
    if not isinstance(have_id, str) or not have_id:
        problems.append("doesn't have application-identifier")
    if not isinstance(team_id, str) or not team_id:
        problems.append("doesn't have com.apple.developer.team-identifier")
    if problems:
        return None, problems
    if bundle_id:
        app_identifier = have_id.split(".", 1)[0] + "." + bundle_id
    elif "*" in have_id:
        return None, ["has the wildcard application-identifier %s, so the bundle id is needed" % have_id]
    else:
        app_identifier = have_id
    wanted = {"application-identifier": app_identifier, "com.apple.developer.team-identifier": team_id}
    wanted.update(EXTRA_ENTITLEMENTS[kind])
    problems = subset_problems(wanted, ents)
    return (None if problems else wanted), problems


# ------------------------------------------------------------------------------------------- pick-ios


def missing_devices(profile, devices):
    """The devices this profile doesn't list (none when it provisions all devices)."""
    if profile["all_devices"]:
        return []
    listed = set(profile["devices"])
    return [udid for udid in devices if udid.upper() not in listed]


def profile_problems(profile, kind, team, bundle_id, now, need=()):
    """Why this profile can't sign bundle_id (the devices aside); empty when it can."""
    problems = []
    if profile["team"] and profile["team"] != team:
        problems.append("is for team %s, not %s" % (profile["team"], team))
    if profile["platforms"] and "iOS" not in profile["platforms"]:
        problems.append("is for %s, not iOS" % "/".join(profile["platforms"]))
    if profile["expires"] is None:
        problems.append("has no expiration date")
    elif profile["expires"] <= now:
        problems.append("expired on %s" % _day(profile["expires"]))
    for key in need:
        if not profile["entitlements"].get(key):
            problems.append("doesn't have %s" % key)
    problems.extend(build_entitlements(profile, kind, bundle_id)[1])
    return _unique(problems)


def _role(profile, team, app_id, widgets_id):
    full = profile["app_id"]
    if full == "%s.%s" % (team, app_id):
        return "app"
    if full == "%s.%s" % (team, widgets_id):
        return "widgets"
    if full == "%s.*" % team:
        return "widgets-wildcard"
    if full.partition(".")[2] in (app_id, widgets_id):
        return "other-team"
    return None


def _combinations(identities, cands, devices, allow_missing):
    def usable(cand, roles):
        return cand["role"] in roles and not cand["problems"] and (allow_missing or not cand["missing"])

    apps = [c for c in cands if usable(c, ("app",))]
    widgets = [c for c in cands if usable(c, WIDGET_ROLES)]
    out = []
    for ident in identities:
        for app in apps:
            if ident["sha1"] not in app["profile"]["cert_sha1s"]:
                continue
            for widget in widgets:
                if ident["sha1"] in widget["profile"]["cert_sha1s"]:
                    served = [d for d in devices if d not in app["missing"] and d not in widget["missing"]]
                    out.append((ident, app, widget, served))
    return out


def _rank(identities):
    """Most devices, then an exact widgets profile before the TEAM.* wildcard, then the latest expiry (of the
    profiles, then of the identity's certificate)."""
    order = {ident["sha1"]: n for n, ident in enumerate(identities)}

    def key(combo):
        ident, app, widget, served = combo
        app_expires, widget_expires = app["profile"]["expires"], widget["profile"]["expires"]
        cert_expires = _identity_expires(ident, app["profile"])
        return (-len(served), 0 if widget["role"] == "widgets" else 1,
                -min(app_expires, widget_expires).timestamp(), -app_expires.timestamp(),
                -widget_expires.timestamp(), -(cert_expires.timestamp() if cert_expires else 0),
                order.get(ident["sha1"], 0))

    return key


def _identity_expires(ident, profile=None):
    """When the identity's certificate expires: from the keychain's copy, else the profile's (or None)."""
    if ident.get("not_after"):
        return ident["not_after"]
    for cert in (profile or {}).get("certificates") or []:
        if cert["sha1"] == ident["sha1"]:
            return cert.get("not_after")
    return None


def _profile_choice(cand, kind, bundle_id, now):
    profile = cand["profile"]
    return {
        "uuid": profile["uuid"],
        "name": profile["name"],
        "path": profile["path"],
        "expires": profile["expires"],
        "days_left": int((profile["expires"] - now).total_seconds() // 86400),
        "app_id": profile["app_id"],
        "wildcard": "*" in profile["app_id"],
        "xcode_managed": profile["xcode_managed"],
        "entitlements": profile["entitlements"],
        "signs_with": build_entitlements(profile, kind, bundle_id)[0],
    }


def _days_left(when, now):
    return int((when - now).total_seconds() // 86400) if when is not None else None


def certificate_state(not_after, reason, now):
    """What's wrong with a signing certificate ("expired on 2027-11-04", "was revoked", "can't sign (...)"),
    from its expiry date and find-identity's reason (parse_invalid_identities); None if neither says."""
    reason = reason or ""
    if not_after is not None and not_after <= now:
        return "expired on %s" % _day(not_after)
    if "EXPIRED" in reason.upper():
        return "expired (%s)" % reason
    if "REVOKED" in reason.upper():
        return "was revoked"
    if reason:
        return "can't sign (%s)" % reason
    return None


RENEW = "someone needs to sign in to Xcode once on this Mac to get a new certificate"
RENEW_IOS = RENEW + " and profiles"


def _sentence(text):
    return text[0].upper() + text[1:]


def certificate_trouble(profile_certs, certs=None, invalid=None, now=None):
    """Why this Mac can sign with none of the profiles' certificates, and what to do about it.

    profile_certs: [{"sha1", "cn", "not_after"}] from the profiles (they carry each certificate whole);
    certs: {SHA-1: DER} from `security find-certificate -a`, which lists expired and revoked certificates too;
    invalid: parse_invalid_identities() (identities this Mac has but can't sign with, and why).
    """
    now = now or datetime.now(timezone.utc)
    certs = certs or {}
    reasons = {ident["sha1"]: ident["reason"] for ident in invalid or []}
    clauses, dead, keyless, elsewhere = [], [], [], []
    for cert in profile_certs:
        sha1 = cert["sha1"]
        not_after = cert.get("not_after") or certificate_info(certs.get(sha1))["not_after"]
        state = certificate_state(not_after, reasons.get(sha1), now)
        if state:
            dead.append(sha1)
        elif sha1 in certs:
            state = "is in this Mac's keychain but can't sign here (it was revoked, or its private key isn't on this Mac)"
            keyless.append(sha1)
        else:
            state = "isn't a valid identity in this Mac's keychain"
            elsewhere.append(sha1)
        clauses.append("%s%s, which %s" % (sha1, " (%s)" % cert["cn"] if cert.get("cn") else "", state))
    if not clauses:
        return "The iPhone profiles on this Mac list no signing certificate. %s; this script never does." % (
            _sentence(RENEW_IOS))
    text = "The iPhone profiles on this Mac are for signing certificate%s %s." % (
        "s" if len(clauses) > 1 else "", "; and ".join(clauses))
    if elsewhere and not (dead or keyless):
        advice = "Deploy the iPhones from the Mac that has %s." % ("it" if len(elsewhere) == 1 else "one of them")
    elif elsewhere:
        advice = "Deploy the iPhones from the Mac that has %s, or %s (this script never does)." % (
            " or ".join(elsewhere), RENEW_IOS)
    elif keyless and not dead:
        advice = "If %s revoked, %s (this script never does); if not, deploy the iPhones from the Mac that has %s." % (
            "it was" if len(keyless) == 1 else "they were", RENEW_IOS,
            "its private key" if len(keyless) == 1 else "their private keys")
    else:
        advice = "%s; this script never does." % _sentence(RENEW_IOS)
    return text + " " + advice


def _headline(team, app_id, widgets_id, identities, cands, now, certs=None, invalid=None):
    apps = [c for c in cands if c["role"] == "app"]
    widgets = [c for c in cands if c["role"] in WIDGET_ROLES]
    if not identities and not (apps and widgets):
        return ("No valid Apple Development signing identity for team %s is in this Mac's keychain, so nothing "
                "here can sign the iPhone app." % team)
    if not apps:
        return "No provisioning profile for %s.%s is on this Mac." % (team, app_id)
    if not widgets:
        return "No provisioning profile for %s.%s (or %s.*) is on this Mac." % (team, widgets_id, team)
    for group, what in ((apps, "app"), (widgets, "widgets")):
        if all(c["expired"] for c in group):
            last = max(c["profile"]["expires"] for c in group)
            return ("The iPhone %s profile expired on %s. Someone needs to sign in to Xcode once on this Mac to "
                    "renew the profiles; this script never does." % (what, _day(last)))
    live = [c for c in apps + widgets if not c["expired"]]
    if all(len(c["problems"]) == 1 and c["problems"][0].startswith(NO_IDENTITY) for c in live):
        profile_certs, seen = [], set()
        for cand in live:
            for cert in cand["profile"]["certificates"]:
                if cert["sha1"] not in seen:
                    seen.add(cert["sha1"])
                    profile_certs.append(cert)
        return certificate_trouble(profile_certs, certs, invalid, now)
    if not identities:
        return ("No valid Apple Development signing identity for team %s is in this Mac's keychain, so nothing "
                "here can sign the iPhone app." % team)
    if all(not c["problems"] for c in live):
        missing = _unique(udid for c in live for udid in c["missing"])
        if missing:
            return ("The provisioning profiles don't list %s. Adding an iPhone to them needs someone to sign in "
                    "to Xcode once on this Mac; this script never does." % ", ".join(missing))
    details = ["%s profile %s %s" % ("app" if c["role"] == "app" else "widgets", c["profile"]["uuid"],
                                     ", ".join(c["problems"] + ["doesn't list %s" % d for d in c["missing"]]))
               for c in live if c["problems"] or c["missing"]]
    return ("No app profile and widgets profile on this Mac share a valid signing identity and pass every check"
            + (": " + "; ".join(details[:4]) if details else " (see the candidates)") + ".")


def pick_ios(identities, profiles, team, app_id, widgets_id, devices=(), need=(), now=None, certs=None,
             invalid=None):
    """One identity that is in both an app profile and a widgets profile that can sign for every device.

    identities: the team's valid identities in `security find-identity` order (team_identities);
    profiles: decoded profiles (profile_from_plist). App profile: exactly TEAM.app_id, not expired, has every
    `need` entitlement, lists every device (or all devices). Widgets profile: exactly TEAM.widgets_id, else the
    TEAM.* wildcard, not expired, lists every device. Latest expiry first. certs ({SHA-1: DER}, every
    certificate in the keychain) and invalid (parse_invalid_identities) only make the problem clearer.

    Returns (choice, None) or (None, failure), both ready for JSON. A choice has the identity, its
    certificate's expiry and days left, and the two profiles. A failure has "problem", "identities" and
    "candidates" (each profile with why it was rejected) and, when some devices could still be served by one
    identity and pair of profiles, "usable_devices" and "unusable_devices".
    """
    now = now or datetime.now(timezone.utc)
    devices = _unique(udid.strip() for udid in devices if udid and udid.strip())
    valid = {ident["sha1"] for ident in identities}
    cands = []
    for profile in profiles:
        role = _role(profile, team, app_id, widgets_id)
        if role is None:
            continue
        if role == "other-team":
            problems = ["is for team %s, not %s" % (profile["team"] or profile["app_id"].partition(".")[0], team)]
        elif role == "app":
            problems = profile_problems(profile, "app", team, app_id, now, need)
        else:
            problems = profile_problems(profile, "widget", team, widgets_id, now)
        if not problems and not valid.intersection(profile["cert_sha1s"]):
            problems.append("%s (it's for certificate %s)" % (NO_IDENTITY, ", ".join(profile["cert_sha1s"]) or "none"))
        cands.append({
            "profile": profile,
            "role": role,
            "problems": problems,
            "missing": missing_devices(profile, devices),
            "expired": profile["expires"] is not None and profile["expires"] <= now,
        })

    full = _combinations(identities, cands, devices, allow_missing=False)
    if full:
        ident, app, widget, _ = min(full, key=_rank(identities))
        cert_expires = _identity_expires(ident, app["profile"])
        return {
            "identity": ident["sha1"],
            "identity_name": ident["name"],
            "identity_expires": cert_expires,
            "identity_days_left": _days_left(cert_expires, now),
            "app": _profile_choice(app, "app", app_id, now),
            "widgets": _profile_choice(widget, "widget", widgets_id, now),
            "devices": devices,
        }, None

    good_apps = [c for c in cands if c["role"] == "app" and not c["problems"] and not c["missing"]]
    good_widgets = [c for c in cands if c["role"] in WIDGET_ROLES and not c["problems"] and not c["missing"]]
    listing = []
    for cand in sorted(cands, key=lambda c: -(c["profile"]["expires"].timestamp() if c["profile"]["expires"] else 0)):
        reasons = cand["problems"] + ["doesn't list device %s" % udid for udid in cand["missing"]]
        if not reasons and cand["role"] != "other-team":
            other, what = (good_widgets, "widgets") if cand["role"] == "app" else (good_apps, "app")
            reasons = ["no usable %s profile is for the same signing identity" % what if other
                       else "there's no usable %s profile to go with it" % what]
        profile = cand["profile"]
        listing.append({
            "uuid": profile["uuid"],
            "name": profile["name"],
            "app_id": profile["app_id"],
            "expires": profile["expires"],
            "path": profile["path"],
            "certificates": profile["cert_sha1s"],
            "rejected_because": reasons,
        })
    failure = {
        "problem": _headline(team, app_id, widgets_id, identities, cands, now, certs, invalid),
        "identities": [{"sha1": i["sha1"], "name": i["name"], "ou": i.get("ou")} for i in identities],
        "candidates": listing,
    }
    partial = [combo for combo in _combinations(identities, cands, devices, allow_missing=True) if combo[3]]
    if partial:
        served = min(partial, key=_rank(identities))[3]
        failure["usable_devices"] = served
        failure["unusable_devices"] = [udid for udid in devices if udid not in served]
    return None, failure


# ------------------------------------------------------------------------------------------- pick-mac


def pick_mac(identities, signer_sha1=None, signer_cn=None, team="the team", unusable=()):
    """(identity, why) for the Mac app: the one that signed the installed app if it's still valid, else one
    with the same certificate name, else the one whose certificate lasts longest. (None, problem) if none;
    unusable (unusable_identities) says what happened to the ones this Mac had."""
    if not identities:
        return None, ("No valid Apple Development signing identity for team %s is in this Mac's keychain%s. %s; "
                      "this script never does." % (team, (": " + "; ".join(unusable)) if unusable else "",
                                                   _sentence(RENEW)))

    def longest(group):
        ranked = sorted(enumerate(group), key=lambda pair: (
            -(pair[1]["not_after"].timestamp() if pair[1].get("not_after") else 0), pair[0]))
        return ranked[0][1]

    if signer_sha1:
        for ident in identities:
            if ident["sha1"] == signer_sha1.upper():
                return ident, "it signed the installed app"
    if signer_cn:
        same = [i for i in identities if (i.get("cn") or i["name"]) == signer_cn]
        if same:
            return longest(same), "same name as the installed app's signer, which is no longer valid"
    if signer_sha1:
        return longest(identities), "the installed app's signer is no longer valid"
    return longest(identities), "valid for team %s" % team


def unusable_identities(invalid, certs, team=None, now=None):
    """["SHA-1 (name) was revoked", ...] for this Mac's "Apple Development" identities of the team that can't
    sign (invalid: parse_invalid_identities; certs: {SHA-1: DER} for each certificate's OU and expiry)."""
    now = now or datetime.now(timezone.utc)
    out = []
    for ident in invalid or []:
        if not ident["name"].startswith(DEVELOPMENT):
            continue
        info = certificate_info((certs or {}).get(ident["sha1"]))
        if team and info["ou"] is not None and info["ou"] != team:
            continue
        state = certificate_state(info["not_after"], ident["reason"], now) or "can't sign"
        out.append("%s (%s) %s" % (ident["sha1"], ident["name"], state))
    return out


def leaf_certificate(app_path):
    """DER of the leaf certificate that signed app_path, or None (not there, unsigned, or signed ad hoc)."""
    if not os.path.isdir(app_path):
        return None
    with tempfile.TemporaryDirectory(prefix="woodruff-signer.") as tmp:
        prefix = os.path.join(tmp, "c")
        run(["codesign", "-d", "--extract-certificates=" + prefix, app_path])
        try:
            with open(prefix + "0", "rb") as handle:
                return handle.read() or None
        except OSError:
            return None


def installed_signer(app_path):
    """(SHA-1, CN) of the leaf certificate that signed app_path, or (None, None)."""
    der = leaf_certificate(app_path)
    if not der:
        return None, None
    return hashlib.sha1(der).hexdigest().upper(), certificate_info(der)["cn"]


def app_signer(app_path):
    """{"sha1", "cn", "team", "not_after"} of the certificate that signed app_path, or None."""
    der = leaf_certificate(app_path)
    if not der:
        return None
    info = certificate_info(der)
    return {"sha1": hashlib.sha1(der).hexdigest().upper(), "cn": info["cn"], "team": info["ou"],
            "not_after": info["not_after"]}


# ------------------------------------------------------------------------------------------ shared builds
#
# A Mac whose own certificate Apple revoked can't sign a build, but it can run one another Mac signed: an
# "Apple Development" Mac app needs no profile. The Mac that built it shares a zip of it in iCloud Drive with a
# manifest; the other Mac checks the zip against the manifest before installing it. Its keychain items (the TVs'
# pairings) stay readable as long as the new app's certificate has the same name (CN) and team as the old one's,
# which is the case for every certificate of one Apple ID; deploy.sh refuses a build whose CN differs.


def file_digest(path, chunk=1 << 20):
    """(SHA-256 hex, size in bytes) of a file."""
    digest, size = hashlib.sha256(), 0
    with open(path, "rb") as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
            size += len(block)
    return digest.hexdigest(), size


def share_manifest(commit, subject, digest, size, signer, bundle, built_on, now):
    """The manifest saved next to a shared zip."""
    signer = signer or {}
    return {
        "format": 1,
        "commit": (commit or "").strip().lower(),
        "subject": subject or "",
        "sha256": digest,
        "bytes": size,
        "bundle_id": bundle,
        "signer_sha1": signer.get("sha1"),
        "signer_cn": signer.get("cn"),
        "signer_team": signer.get("team"),
        "signer_expires": signer.get("not_after"),
        "built_on": built_on,
        "shared_at": now,
    }


def share_problem(manifest, digest, size, commit, team=None):
    """Why a shared zip isn't the build wanted (None if it is): another commit, not all there yet, another team."""
    if not isinstance(manifest, dict):
        return "its manifest isn't a JSON object"
    want = (commit or "").strip().lower()
    have = str(manifest.get("commit") or "").strip().lower()
    if not want or have != want:
        return "it's the build of %s, not %s" % (have[:12] or "an unknown commit", want[:12] or "(none given)")
    if manifest.get("bytes") != size:
        return "the zip has %d bytes, not the %s its manifest says (still arriving?)" % (size, manifest.get("bytes"))
    if str(manifest.get("sha256") or "").lower() != digest:
        return "the zip's SHA-256 isn't the one its manifest says (still arriving, or damaged)"
    if team and manifest.get("signer_team") and manifest.get("signer_team") != team:
        return "it was signed for team %s, not %s" % (manifest.get("signer_team"), team)
    return None


def computer_name():
    status, out, _ = run(["scutil", "--get", "ComputerName"], timeout=10)
    name = out.decode("utf-8", "replace").strip() if status == 0 else ""
    if not name:
        import socket
        name = socket.gethostname()
    return name


# -------------------------------------------------------------------------------------------- devices


def _dict(value):
    return value if isinstance(value, dict) else {}


def parse_devices(doc):
    """`devicectl list devices --json-output` -> [{"udid", "name", ...}] for iOS devices (missing keys are fine)."""
    devices = _dict(_dict(doc).get("result")).get("devices")
    out, seen = [], set()
    for device in devices if isinstance(devices, list) else []:
        hardware = _dict(_dict(device).get("hardwareProperties"))
        props = _dict(_dict(device).get("deviceProperties"))
        connection = _dict(_dict(device).get("connectionProperties"))
        udid = hardware.get("udid")
        if hardware.get("platform") != "iOS" or not isinstance(udid, str) or not udid.strip():
            continue
        udid = udid.strip()
        if udid in seen:
            continue
        seen.add(udid)
        name = props.get("name")
        out.append({
            "udid": udid,
            "name": name.strip() if isinstance(name, str) and name.strip() else udid,
            "model": hardware.get("marketingName") or hardware.get("productType"),
            "pairing": connection.get("pairingState"),
            "tunnel": connection.get("tunnelState"),
            "developer_mode": props.get("developerModeStatus"),
        })
    return out


def read_devices():
    """(devices, None) or (None, error) from `xcrun devicectl list devices`."""
    with tempfile.TemporaryDirectory(prefix="woodruff-devices.") as tmp:
        path = os.path.join(tmp, "devices.json")
        status, _, err = run(["xcrun", "devicectl", "list", "devices", "--json-output", path], timeout=180)
        try:
            with open(path, "rb") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            message = err.decode("utf-8", "replace").strip()
            return None, message or "xcrun devicectl list devices wrote no JSON (status %d)" % status
    return parse_devices(doc), None


# ----------------------------------------------------------------------------------------------- misc


def bundle_id(path):
    for rel in ("Info.plist", os.path.join("Contents", "Info.plist")):
        info = os.path.join(path, rel)
        if os.path.isfile(info):
            with open(info, "rb") as handle:
                value = plistlib.load(handle).get("CFBundleIdentifier")
            return value if isinstance(value, str) else None
    return None


def json_values(doc, path):
    """Values at a dotted path; "*" takes every item of a list (or value of an object)."""
    values = [doc]
    for part in path.split(".") if path else []:
        found = []
        for value in values:
            if part == "*":
                if isinstance(value, list):
                    found.extend(value)
                elif isinstance(value, dict):
                    found.extend(value.values())
            elif isinstance(value, dict) and part in value:
                found.append(value[part])
            elif isinstance(value, list) and part.isdigit() and int(part) < len(value):
                found.append(value[int(part)])
        values = found
    return values


def _line(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return " ".join(str(value).splitlines())


# ------------------------------------------------------------------------------------------------ CLI


def cmd_identities(args):
    print_json(team_identities(read_identities(), read_certificates(), args.team))
    return 0


def cmd_profiles(args):
    profiles = load_profiles()
    profiles.sort(key=lambda p: -(p["expires"].timestamp() if p["expires"] else 0))
    print_json(profiles)
    return 0


def cmd_pick_ios(args):
    certs = read_certificates()
    identities = team_identities(read_identities(), certs, args.team)
    devices = [udid for group in args.device or [] for udid in group]
    profiles = load_profiles()
    choice, failure = pick_ios(identities, profiles, args.team, args.app_id, args.widgets_id,
                               devices, args.need_entitlement or [], certs=certs)
    if failure:  # find out why the identities this Mac has can't sign, for the message
        choice, failure = pick_ios(identities, profiles, args.team, args.app_id, args.widgets_id, devices,
                                   args.need_entitlement or [], certs=certs, invalid=read_invalid_identities())
    print_json(choice or failure)
    return 0 if choice else 2


def cmd_entitlements(args):
    profile = decode_profile(args.profile)
    if profile is None:
        return _fail("Couldn't read the provisioning profile %s." % args.profile)
    ents, problems = build_entitlements(profile, args.kind, args.bundle_id)
    if problems:
        return _fail("The %s entitlements aren't allowed by profile %s (%s): it %s."
                     % (args.kind, profile["name"] or args.profile, profile["uuid"], "; it ".join(problems)))
    data = plistlib.dumps(ents, fmt=plistlib.FMT_XML)
    if args.out:
        with open(args.out, "wb") as handle:
            handle.write(data)
    else:
        sys.stdout.flush()
        sys.stdout.buffer.write(data)
    return 0


def cmd_pick_mac(args):
    everyone = read_identities()
    certs = read_certificates()
    identities = team_identities(everyone, certs, args.team)
    signer_sha1, signer_cn = installed_signer(args.app)
    unusable = [] if identities else unusable_identities(read_invalid_identities(), certs, args.team)
    ident, why = pick_mac(identities, signer_sha1, signer_cn, args.team, unusable)
    if ident is None:
        print_json({"problem": why, "identities": everyone})
        return 2
    now = datetime.now(timezone.utc)
    print_json({"identity": ident["sha1"], "name": ident["name"], "reason": why, "installed_signer": signer_sha1,
                "identity_expires": ident.get("not_after"), "identity_days_left": _days_left(ident.get("not_after"), now)})
    return 0


def cmd_signer(args):
    signer = app_signer(args.app)
    if signer is None:
        return _fail("%s isn't there or isn't signed with a certificate." % args.app)
    print_json(signer)
    return 0


def cmd_share_manifest(args):
    signer = app_signer(args.app)
    if signer is None:
        return _fail("%s isn't there or isn't signed with a certificate, so it isn't shared." % args.app)
    try:
        digest, size = file_digest(args.zip)
    except OSError as exc:
        return _fail("Couldn't read %s: %s" % (args.zip, exc))
    try:
        bundle = bundle_id(args.app)
    except Exception:  # noqa: BLE001 - an unreadable Info.plist
        bundle = None
    manifest = share_manifest(args.commit, args.subject, digest, size, signer, bundle, computer_name(),
                              datetime.now(timezone.utc))
    try:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(manifest, indent=2, default=_json_default) + "\n")
    except OSError as exc:
        return _fail("Couldn't write %s: %s" % (args.out, exc))
    return 0


def cmd_check_share(args):
    try:
        with open(args.manifest, "rb") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as exc:
        return _fail("Couldn't read the manifest %s: %s" % (args.manifest, exc))
    try:
        digest, size = file_digest(args.zip)
    except OSError as exc:
        return _fail("Couldn't read %s: %s" % (args.zip, exc))
    problem = share_problem(manifest, digest, size, args.commit, args.team)
    if problem:
        return _fail("The shared build isn't usable yet: %s." % problem)
    print_json(manifest)
    return 0


def cmd_devices(args):
    devices, error = read_devices()
    if devices is None:
        return _fail("Couldn't list the devices: %s" % error, 1)
    print_json(devices)
    return 0


def cmd_bundle_id(args):
    try:
        value = bundle_id(args.path)
    except Exception as exc:  # noqa: BLE001 - an unreadable Info.plist
        return _fail("Couldn't read the Info.plist in %s: %s" % (args.path, exc), 1)
    if not value:
        return _fail("No CFBundleIdentifier in %s." % args.path, 1)
    print(value)
    return 0


def cmd_get(args):
    try:
        with open(args.file, "rb") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        return _fail("Couldn't read %s: %s" % (args.file, exc), 1)
    values = json_values(doc, args.key)
    if not values:
        return 1
    for value in values:
        print(_line(value))
    return 0


class _Parser(argparse.ArgumentParser):
    def error(self, message):  # exit 1, so that 2 always means "can't be done"
        self.print_usage(sys.stderr)
        self.exit(1, "%s: error: %s\n" % (self.prog, message))


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    parser = _Parser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True

    p = sub.add_parser("identities", help="valid Apple Development identities")
    p.add_argument("--team")
    p.set_defaults(func=cmd_identities)

    p = sub.add_parser("profiles", help="every provisioning profile on this Mac, decoded")
    p.set_defaults(func=cmd_profiles)

    p = sub.add_parser("pick-ios", help="identity + app profile + widgets profile for the iPhones")
    p.add_argument("--team", required=True)
    p.add_argument("--app-id", required=True)
    p.add_argument("--widgets-id", required=True)
    p.add_argument("--need-entitlement", action="append", metavar="KEY")
    p.add_argument("--device", action="append", nargs="+", metavar="UDID")
    p.set_defaults(func=cmd_pick_ios)

    p = sub.add_parser("entitlements", help="write the app's or widget's entitlements plist")
    p.add_argument("--profile", required=True)
    p.add_argument("--kind", required=True, choices=sorted(EXTRA_ENTITLEMENTS))
    p.add_argument("--bundle-id")
    p.add_argument("--out")
    p.set_defaults(func=cmd_entitlements)

    p = sub.add_parser("pick-mac", help="identity for the Mac app")
    p.add_argument("--team", required=True)
    p.add_argument("--app", default=DEFAULT_MAC_APP)
    p.set_defaults(func=cmd_pick_mac)

    p = sub.add_parser("signer", help="the certificate that signed an app")
    p.add_argument("--app", default=DEFAULT_MAC_APP)
    p.set_defaults(func=cmd_signer)

    p = sub.add_parser("share-manifest", help="write the manifest for a shared zip of the Mac app")
    p.add_argument("--app", required=True)
    p.add_argument("--zip", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--subject", default="")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_share_manifest)

    p = sub.add_parser("check-share", help="check a shared zip against its manifest")
    p.add_argument("--manifest", required=True)
    p.add_argument("--zip", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--team")
    p.set_defaults(func=cmd_check_share)

    p = sub.add_parser("devices", help="the iOS devices paired with this Mac")
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("bundle-id", help="CFBundleIdentifier of a .app or .appex")
    p.add_argument("path")
    p.set_defaults(func=cmd_bundle_id)

    p = sub.add_parser("get", help="values from a JSON file")
    p.add_argument("file")
    p.add_argument("key")
    p.set_defaults(func=cmd_get)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
