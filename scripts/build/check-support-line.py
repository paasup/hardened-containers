#!/usr/bin/env python3
"""
check-support-line.py — is our pin still on an upstream line that gets security patches?

The gate answers "does this image carry a known CVE right now". It cannot answer "will
anyone still publish a fix for this version" — an image sitting on an end-of-life line
passes the gate cleanly right up until the first CVE nobody is going to fix. This script
answers the second question.

Each image declares the line it tracks in `images/<image>/image.env`:

    SUPPORT_SOURCE=endoflife.date   # or: manual
    SUPPORT_PRODUCT=postgresql      # endoflife.date product slug
    SUPPORT_LINE=18                 # must equal a releases[].name
    SUPPORT_REF=https://…           # manual only — what a person reads instead
    SUPPORT_NOTE="…"                # optional prose

Why `manual` exists: endoflife.date has no entry for three of the projects built here, so
those declare where a person looks instead. They are reported and never fail — a check
that cannot measure something must not pretend it did (the same principle as the gate's
`CoverageProbe`).

**An EOL finding is not drift.** Drift means "a rebuild will fix this"; nothing about
rebuilding moves a pin onto a supported line, so this script is deliberately kept out of
`rescan-published.sh` (whose exit code triggers a rebuild) and out of `image-gate.py`
(design rule 5). Wiring it into either would rebuild the same EOL pin every day forever.
The remedy is a person raising the pin.

Usage
-----
    python3 scripts/build/check-support-line.py                 # every image
    python3 scripts/build/check-support-line.py --image apisix  # one image
    python3 scripts/build/check-support-line.py --format github # + workflow annotations

Exit codes
    0  every image checked is on a maintained line at its newest release (or was skipped)
    1  on a maintained line, but behind within it — a notice, not a failure
    2  at least one image is on an unmaintained line, or its line is unknown upstream
    3  execution error (network, malformed declaration)
"""

import argparse
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

API = "https://endoflife.date/api/v1/products/{product}/"
TIMEOUT = 30

# Exit codes, also used to rank per-image results — the worst result wins.
OK, BEHIND, UNMAINTAINED, ERROR = 0, 1, 2, 3


def read_env(path):
    """Parse a shell-style KEY=VALUE file. Only uppercase keys, comments ignored."""
    kv = {}
    for line in path.read_text(encoding="utf-8").split("\n"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", k):
            kv[k] = v.strip().strip('"').strip("'")
    return kv


def app_version(image_dir, env):
    """The pinned version, read from the default variant's build.env."""
    variant = env.get("DEFAULT_BASE_OS")
    if not variant:
        return None
    bench = image_dir / f"{variant}.build.env"
    return read_env(bench).get("APP_VERSION") if bench.exists() else None


def fetch(product):
    req = urllib.request.Request(
        API.format(product=product),
        headers={"Accept": "application/json", "User-Agent": "hardened-containers/support-line-check"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)["result"]


def check(image_dir):
    """Judge one image. Returns a row dict; `status` is one of the exit-code constants."""
    env = read_env(image_dir / "image.env")
    row = {
        "image": image_dir.name,
        "line": env.get("SUPPORT_LINE") or "-",
        "pin": app_version(image_dir, env) or "-",
        "latest": "-",
        "maintained": "-",
        "eol": "-",
        "status": OK,
        "detail": "",
    }

    source = env.get("SUPPORT_SOURCE")
    if source == "manual":
        row["maintained"] = "manual"
        row["detail"] = f"not on endoflife.date — judged by a person against {env.get('SUPPORT_REF', '(no ref)')}"
        return row
    if source != "endoflife.date":
        row["status"] = ERROR
        row["detail"] = f"SUPPORT_SOURCE={source!r} is not one of endoflife.date, manual"
        return row

    product, line = env.get("SUPPORT_PRODUCT"), env.get("SUPPORT_LINE")
    if not product or not line:
        row["status"] = ERROR
        row["detail"] = "SUPPORT_SOURCE=endoflife.date needs both SUPPORT_PRODUCT and SUPPORT_LINE"
        return row

    try:
        result = fetch(product)
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, KeyError) as e:
        row["status"] = ERROR
        row["detail"] = f"could not read endoflife.date for {product!r}: {e}"
        return row

    releases = {r.get("name"): r for r in result.get("releases") or []}
    rel = releases.get(line)
    if rel is None:
        # A line upstream does not list at all. Treated as unmaintained rather than an
        # error: upstream dropping a line from its own index is exactly the signal here.
        row["status"] = UNMAINTAINED
        row["detail"] = (
            f"upstream lists no line {line!r} for {product} "
            f"(known: {', '.join(sorted(releases)[:8]) or 'none'})"
        )
        return row

    row["latest"] = (rel.get("latest") or {}).get("name") or "-"
    row["eol"] = rel.get("eolFrom") or "-"
    row["maintained"] = "yes" if rel.get("isMaintained") else "NO"

    if not rel.get("isMaintained"):
        row["status"] = UNMAINTAINED
        alive = [n for n, r in releases.items() if r.get("isMaintained")]
        row["detail"] = (
            f"line {line} is end-of-life"
            + (f" since {rel['eolFrom']}" if rel.get("eolFrom") else "")
            + f" — still maintained: {', '.join(alive) if alive else 'none'}"
        )
    else:
        # Some projects' own APP_VERSION carries a "v" prefix (kyverno's v1.19.0) that
        # endoflife.date's release names never do — strip it for this comparison only,
        # so that being genuinely current does not get reported as BEHIND.
        pin_bare = row["pin"][1:] if row["pin"][:1] in ("v", "V") else row["pin"]
        if row["pin"] != "-" and row["latest"] != "-" and pin_bare != row["latest"]:
            row["status"] = BEHIND
            row["detail"] = f"line {line} is maintained, but {row['pin']} is behind {row['latest']}"
    return row


def render(rows, fmt):
    print("| image | line | our pin | latest in line | maintained | eol |")
    print("|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['image']} | {r['line']} | {r['pin']} | {r['latest']} | {r['maintained']} | {r['eol']} |")
    print()
    for r in rows:
        if not r["detail"]:
            continue
        print(f"{r['image']}: {r['detail']}")
        if fmt != "github":
            continue
        # ::error:: is deliberately not used — a red step is the signal, and reserving
        # ::error:: for the gate keeps the two apart in the run log.
        if r["status"] == UNMAINTAINED:
            print(f"::warning title=Unsupported upstream line::{r['image']}: {r['detail']}")
        elif r["status"] == ERROR:
            print(f"::warning title=Support line not measured::{r['image']}: {r['detail']}")
        elif r["status"] == BEHIND:
            print(f"::notice title=Behind within a maintained line::{r['image']}: {r['detail']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--image", default="", help="check one image (default: every image)")
    ap.add_argument("--format", choices=("plain", "github"), default="plain",
                    help="github adds ::warning::/::notice:: workflow annotations")
    ap.add_argument("--images-dir", default="images")
    args = ap.parse_args()

    root = pathlib.Path(args.images_dir)
    if args.image:
        dirs = [root / args.image]
        if not dirs[0].is_dir():
            print(f"::error::no such image directory: {dirs[0]}", file=sys.stderr)
            return ERROR
    else:
        dirs = sorted(d for d in root.iterdir() if (d / "image.env").is_file())

    rows = [check(d) for d in dirs]
    render(rows, args.format)

    worst = max((r["status"] for r in rows), default=OK)
    if worst == UNMAINTAINED:
        print("\nsupport line: FAILED — an image sits on a line upstream no longer patches. "
              "Rebuilding cannot fix this; raise the pin.", file=sys.stderr)
    elif worst == ERROR:
        print("\nsupport line: could not be measured for at least one image.", file=sys.stderr)
    elif worst == BEHIND:
        print("\nsupport line: every line is maintained; some pins are behind within their line.",
              file=sys.stderr)
    else:
        print("\nsupport line: every checked image is current on a maintained line.", file=sys.stderr)
    return worst


if __name__ == "__main__":
    sys.exit(main())
