#!/usr/bin/env python3
"""
render-published-images-table.py — regenerates the published-images table in README.md
and README.ko.md from published.json (images.<name>.{tag,ref}), every images/*/image.env's
CATEGORY field, and cve-exceptions.json.

Category *group* order is alphabetical by display name, case-insensitively (str.lower) —
plain ASCII sort puts "etcd" after every all-caps name (I < e in ASCII), which does not
match this repository's intended order. Row order within a category is plain alphabetical
by image directory name.

The Critical/High columns are NOT the gate's blocking count (always zero for a published
image — that is the definition of passing). They are the count of currently-active
approved exceptions (cve-exceptions.json) by severity, matched against the image's ref the
same way scripts/gate/image-gate.py itself matches them (substring against --image-ref, or
"*"). A published image with an accepted CRITICAL/HIGH exception is not CVE-free — showing
0/0 for it would hide that; showing the real count does not.

Usage
-----
    python3 scripts/build/render-published-images-table.py            # regenerate + write
    python3 scripts/build/render-published-images-table.py --check    # no write; report only

Exit codes
    0  README.md/README.ko.md are (now) in sync with published.json + image.env CATEGORY
       + cve-exceptions.json
    1  an image in published.json has no CATEGORY declared (fix images/<image>/image.env),
       or a still-active exception has no `severity` (fix cve-exceptions.json)
    2  published.json/cve-exceptions.json is missing/malformed, a `severity` value isn't
       CRITICAL/HIGH/MEDIUM/LOW, an `expires` date is malformed, or a README is missing the
       marker pair
    3  --check only: the checked-in READMEs differ from what would be generated
"""
import argparse
import datetime
import html
import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
PUBLISHED_JSON = REPO_ROOT / "published.json"
CVE_EXCEPTIONS_JSON = REPO_ROOT / "cve-exceptions.json"
IMAGES_DIR = REPO_ROOT / "images"

BEGIN_MARKER = (
    "<!-- BEGIN GENERATED TABLE: published images — do not edit by hand, "
    "run scripts/build/render-published-images-table.py -->"
)
END_MARKER = "<!-- END GENERATED TABLE: published images -->"
MARKER_RE = re.compile(re.escape(BEGIN_MARKER) + r"\n.*?\n" + re.escape(END_MARKER), re.S)

# (Category, Image, Latest tag, CVE-group, Critical, High)
HEADERS = {
    "README.md":    ("Category", "Image", "Latest tag", "CVE", "Critical", "High"),
    "README.ko.md": ("분류", "이미지", "최신 태그", "CVE", "Critical", "High"),
}

VALID_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW"}


def read_env(path):
    kv = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", k):
            kv[k] = v.strip().strip('"').strip("'")
    return kv


def load_categories():
    """image name -> CATEGORY. Also returns which images/*/ have no image.env at all, and
    which have an image.env but no CATEGORY — used only to word the error precisely."""
    categories, missing_env, missing_category = {}, set(), set()
    for d in sorted(p for p in IMAGES_DIR.iterdir() if p.is_dir()):
        env = d / "image.env"
        if not env.exists():
            missing_env.add(d.name)
            continue
        cat = read_env(env).get("CATEGORY")
        if not cat:
            missing_category.add(d.name)
            continue
        categories[d.name] = cat
    return categories, missing_env, missing_category


def load_published():
    if not PUBLISHED_JSON.exists():
        print(f"error: {PUBLISHED_JSON} does not exist", file=sys.stderr)
        sys.exit(2)
    try:
        doc = json.loads(PUBLISHED_JSON.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"error: {PUBLISHED_JSON} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)
    return {
        name: {"tag": rec["tag"], "ref": rec["ref"]}
        for name, rec in doc.get("images", {}).items()
    }


def load_active_exceptions():
    """Active (non-expired) exceptions, same rule as image-gate.py's load_exceptions:
    an entry whose `expires` date has passed is not honoured. Fails loudly (exit 1) if a
    still-active exception has no `severity`, and (exit 2) if `severity` or `expires` is
    malformed — this data feeds the Critical/High counts, so it cannot be silently wrong."""
    if not CVE_EXCEPTIONS_JSON.exists():
        return []
    try:
        doc = json.loads(CVE_EXCEPTIONS_JSON.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"error: {CVE_EXCEPTIONS_JSON} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)

    today = datetime.date.today()
    active, no_severity, bad_severity, bad_expires = [], [], [], []
    for exc in doc.get("exceptions") or []:
        exp = exc.get("expires")
        if exp:
            try:
                if datetime.datetime.strptime(exp, "%Y-%m-%d").date() < today:
                    continue  # expired — image-gate.py stops honouring it too
            except ValueError:
                bad_expires.append(exc.get("id", "<no id>"))
                continue
        sev = exc.get("severity")
        if not sev:
            no_severity.append(exc.get("id", "<no id>"))
            continue
        if sev not in VALID_SEVERITIES:
            bad_severity.append((exc.get("id", "<no id>"), sev))
            continue
        active.append(exc)

    if bad_expires:
        print(
            "error: cve-exceptions.json has entries with a malformed `expires` "
            f"(want YYYY-MM-DD): {', '.join(bad_expires)}",
            file=sys.stderr,
        )
        sys.exit(2)
    if bad_severity:
        joined = ", ".join(f"{cid}: {sev!r}" for cid, sev in bad_severity)
        print(
            f"error: cve-exceptions.json has entries with an unrecognized `severity` "
            f"(want one of {sorted(VALID_SEVERITIES)}): {joined}",
            file=sys.stderr,
        )
        sys.exit(2)
    if no_severity:
        print(
            "error: cve-exceptions.json has still-active exceptions with no `severity`: "
            + ", ".join(no_severity)
            + "\nAdd `\"severity\": \"CRITICAL\"` or `\"HIGH\"` (the CVE's effective_sev "
              "from cve-gate.json) — see .claude/skills/cve-exception-review/SKILL.md.",
            file=sys.stderr,
        )
        sys.exit(1)
    return active


def exception_applies(exc, image_ref):
    """Same matching rule as image-gate.py's exception_applies: a substring match against
    the full image ref, or '*' for everything."""
    pats = exc.get("images") or ["*"]
    return any(p == "*" or p in image_ref for p in pats)


def count_exceptions(published, exceptions):
    """image name -> {"CRITICAL": n, "HIGH": n} from active exceptions matching its ref."""
    counts = {name: {"CRITICAL": 0, "HIGH": 0} for name in published}
    for name, rec in published.items():
        for exc in exceptions:
            if exc["severity"] in ("CRITICAL", "HIGH") and exception_applies(exc, rec["ref"]):
                counts[name][exc["severity"]] += 1
    return counts


def build_rows(published, categories, missing_env, missing_category, cve_counts):
    """category -> [(image, tag, critical, high), ...], sorted. Fails loudly if any
    published image has no declared CATEGORY — this is the whole point of this script."""
    missing = sorted(name for name in published if name not in categories)
    if missing:
        lines = []
        for name in missing:
            if name in missing_category:
                reason = f"images/{name}/image.env has no CATEGORY line"
            elif name in missing_env:
                reason = f"images/{name}/ has no image.env"
            else:
                reason = f"no images/{name}/ directory at all (orphaned published.json entry?)"
            lines.append(f"  {name}: {reason}")
        print(
            "error: published.json lists images with no usable CATEGORY:\n"
            + "\n".join(lines)
            + "\nAdd `CATEGORY=<Display Name>` to the image's image.env — see "
              "docs/image-authoring/README.md, \"Checklist for adding an image\".",
            file=sys.stderr,
        )
        sys.exit(1)

    grouped = {}
    for name, rec in published.items():
        c = cve_counts[name]
        grouped.setdefault(categories[name], []).append(
            (name, rec["tag"], c["CRITICAL"], c["HIGH"])
        )
    for rows in grouped.values():
        rows.sort(key=lambda r: r[0])
    return grouped


def render_table(grouped, headers):
    th_cat, th_img, th_tag, th_cve, th_crit, th_high = headers
    lines = [
        "<table>", "<thead>",
        f"<tr><th rowspan=\"2\">{th_cat}</th><th rowspan=\"2\">{th_img}</th>"
        f"<th rowspan=\"2\">{th_tag}</th><th colspan=\"2\">{th_cve}</th></tr>",
        f"<tr><th>{th_crit}</th><th>{th_high}</th></tr>",
        "</thead>", "<tbody>",
    ]
    # Case-insensitive: plain ASCII sort puts "etcd" after every all-caps category name.
    for cat in sorted(grouped, key=str.lower):
        rows = grouped[cat]
        for i, (name, tag, critical, high) in enumerate(rows):
            if i != 0:
                cat_cell = ""
            elif len(rows) > 1:
                cat_cell = f'<td rowspan="{len(rows)}">{html.escape(cat)}</td>'
            else:
                cat_cell = f"<td>{html.escape(cat)}</td>"
            lines.append(
                f"<tr>{cat_cell}<td><code>{html.escape(name)}</code></td>"
                f"<td><code>{html.escape(tag)}</code></td>"
                f"<td>{critical}</td><td>{high}</td></tr>"
            )
    lines += ["</tbody>", "</table>"]
    return "\n".join(lines)


def apply_to_file(path, table_html, check_only):
    text = path.read_text(encoding="utf-8")
    if not MARKER_RE.search(text):
        print(
            f"error: {path} has no BEGIN/END GENERATED TABLE marker pair — "
            "insert it once, by hand, around the existing <table>",
            file=sys.stderr,
        )
        sys.exit(2)
    new_block = f"{BEGIN_MARKER}\n{table_html}\n{END_MARKER}"
    new_text = MARKER_RE.sub(lambda _m: new_block, text, count=1)
    if new_text == text:
        print(f"   OK — {path.name} already matches")
        return False
    if check_only:
        print(f"   FAIL — {path.name} is stale (run "
              "scripts/build/render-published-images-table.py)")
        return True
    path.write_text(new_text, encoding="utf-8")
    print(f"   updated {path.name}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                         help="do not write; exit 3 if README.md/README.ko.md would change")
    args = parser.parse_args()

    published = load_published()
    categories, missing_env, missing_category = load_categories()
    exceptions = load_active_exceptions()
    cve_counts = count_exceptions(published, exceptions)
    grouped = build_rows(published, categories, missing_env, missing_category, cve_counts)

    changed = False
    for relpath in ("README.md", "README.ko.md"):
        table_html = render_table(grouped, HEADERS[relpath])
        changed |= apply_to_file(REPO_ROOT / relpath, table_html, args.check)

    sys.exit((3 if changed else 0) if args.check else 0)


if __name__ == "__main__":
    main()
