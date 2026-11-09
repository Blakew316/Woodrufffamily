#!/usr/bin/python3
"""Checks why TestFlight says Woodruff Family isn't available, and fixes what it can (the Mac Studio only).

TestFlight shows "this app doesn't exist / isn't available" on a phone when, for the Apple Account signed in there:
- no tester in a group that has a build: the internal group has no builds (automatic distribution off), or
- the address is an external tester: our uploads are "internal testing only", which external testers can't see, or
- the address isn't a user of the team (internal testers must be, in App Store Connect → Users and Access), or
- every build is expired or still processing.

    testflight_doctor.py                      report only (read only)
    testflight_doctor.py --fix                give the internal group every build, and add every team user to it
    testflight_doctor.py --fix --invite a@b   also invite a@b to the team (Developer) so it can be an internal tester

Uses the App Store Connect key deploy.sh uploads with (same folder as testflight_notes.py). Apple's /usr/bin/python3
(3.9), standard library only.
"""

import argparse
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testflight_notes as asc  # noqa: E402  (find_key, call)

BUNDLE = "com.blakew316.woodruff"
GROUP_NAME = "Family"


def q(params):
    return "?" + urllib.parse.urlencode(params)


def say(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def all_pages(key, path):
    out = []
    while path:
        page = asc.call(key, "GET", path)
        out.extend(page.get("data") or [])
        path = ((page.get("links") or {}).get("next")) or None
    return out


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--fix", action="store_true")
    p.add_argument("--invite", action="append", default=[], help="email to invite to the team (Developer)")
    args = p.parse_args(argv)

    key = asc.find_key()
    if not key:
        say("No App Store Connect key in %s: nothing can be checked." % asc.ASC_DIR)
        return 2

    apps = asc.call(key, "GET", "/apps" + q({"filter[bundleId]": BUNDLE, "limit": 1})).get("data") or []
    if not apps:
        say("PROBLEM: there is no app for %s in App Store Connect. Create it (Apps, +, New App, iOS)." % BUNDLE)
        return 1
    app = apps[0]["id"]
    say("App: %s (%s)" % ((apps[0].get("attributes") or {}).get("name"), app))

    # Builds.
    builds = asc.call(key, "GET", "/builds" + q({"filter[app]": app, "sort": "-uploadedDate", "limit": 5})).get("data") or []
    usable = []
    for b in builds:
        a = b.get("attributes") or {}
        d = asc.call(key, "GET", "/builds/%s/buildBetaDetail" % b["id"]).get("data") or {}
        da = d.get("attributes") or {}
        say("Build %s: %s, %s, internal %s, audience %s, min iOS %s" % (
            a.get("version"), a.get("processingState"), "EXPIRED" if a.get("expired") else "not expired",
            da.get("internalBuildState"), a.get("buildAudienceType"), a.get("minOsVersion")))
        if a.get("processingState") == "VALID" and not a.get("expired"):
            usable.append(b)
    if not usable:
        say("PROBLEM: no processed, unexpired build. The next release uploads one; Apple takes a few minutes.")

    # Team users (internal testers must be among them).
    users = all_pages(key, "/users" + q({"limit": 200}))
    emails = {}
    for u in users:
        a = u.get("attributes") or {}
        if a.get("username"):
            emails[a["username"].lower()] = (a.get("firstName") or "", a.get("lastName") or "")
    say("Team users: %s" % (", ".join(sorted(emails)) or "none"))

    # Groups and their testers.
    groups = all_pages(key, "/apps/%s/betaGroups" % app + q({"limit": 50}))
    internal = None
    for g in groups:
        a = g.get("attributes") or {}
        testers = all_pages(key, "/betaGroups/%s/betaTesters" % g["id"] + q({"limit": 200}))
        tlist = ["%s (%s, %s)" % ((t.get("attributes") or {}).get("email"), (t.get("attributes") or {}).get("state"),
                                  (t.get("attributes") or {}).get("inviteType")) for t in testers]
        gbuilds = asc.call(key, "GET", "/betaGroups/%s/builds" % g["id"] + q({"limit": 5})).get("data") or []
        say("Group \"%s\": %s, all builds %s, %d builds, testers: %s" % (
            a.get("name"), "internal" if a.get("isInternalGroup") else "EXTERNAL (can't see internal-only builds)",
            a.get("hasAccessToAllBuilds"), len(gbuilds), ", ".join(tlist) or "none"))
        if a.get("isInternalGroup") and internal is None:
            internal = (g, testers)
        if not a.get("isInternalGroup"):
            for t in testers:
                e = ((t.get("attributes") or {}).get("email") or "").lower()
                if e and e not in emails:
                    say("PROBLEM: %s is only an external tester: it can't see our builds. Invite it to the team "
                        "(--invite %s) and it becomes an internal tester." % (e, e))
    if internal is None:
        say("PROBLEM: no internal testing group.")
    elif not (internal[0].get("attributes") or {}).get("hasAccessToAllBuilds"):
        say("PROBLEM: the internal group doesn't get new builds by itself (automatic distribution off).")

    if not args.fix:
        say("Report only. Run again with --fix to repair.")
        return 0

    # Fix: an internal group that gets every build.
    if internal is None:
        g = asc.call(key, "POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}}}})["data"]
        internal = (g, [])
        say("FIXED: made the internal group \"%s\" with every build." % GROUP_NAME)
    elif not (internal[0].get("attributes") or {}).get("hasAccessToAllBuilds"):
        gid = internal[0]["id"]
        try:
            asc.call(key, "PATCH", "/betaGroups/%s" % gid, {"data": {
                "type": "betaGroups", "id": gid, "attributes": {"hasAccessToAllBuilds": True}}})
            say("FIXED: the internal group now gets every build.")
        except RuntimeError as e:
            say("Couldn't turn on automatic distribution (%s); adding the builds instead." % e)
        if usable:
            try:
                asc.call(key, "POST", "/betaGroups/%s/relationships/builds" % gid,
                         {"data": [{"type": "builds", "id": b["id"]} for b in usable]})
                say("FIXED: added %d builds to the internal group." % len(usable))
            except RuntimeError as e:
                say("Couldn't add the builds: %s" % e)

    gid = internal[0]["id"]
    have = {((t.get("attributes") or {}).get("email") or "").lower() for t in internal[1]}
    for e, (first, last) in sorted(emails.items()):
        if e in have:
            continue
        try:
            asc.call(key, "POST", "/betaTesters", {"data": {
                "type": "betaTesters", "attributes": {"email": e, "firstName": first, "lastName": last},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}}}})
            say("FIXED: %s added to the internal group (TestFlight sends an invite)." % e)
        except RuntimeError as err:
            say("Couldn't add %s: %s" % (e, err))

    for e in args.invite:
        e = e.strip().lower()
        if not e or e in emails:
            continue
        try:
            asc.call(key, "POST", "/userInvitations", {"data": {
                "type": "userInvitations",
                "attributes": {"email": e, "firstName": e.split("@")[0], "lastName": "Woodruff",
                               "roles": ["DEVELOPER"], "allAppsVisible": True}}})
            say("FIXED: invited %s to the team. Accept the email, then run --fix again to add it as a tester." % e)
        except RuntimeError as err:
            say("Couldn't invite %s (the key may need the Admin role; invite it in Users and Access): %s" % (e, err))
    return 0


if __name__ == "__main__":
    sys.exit(main())
