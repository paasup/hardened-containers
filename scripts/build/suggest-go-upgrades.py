#!/usr/bin/env python3
"""
suggest-go-upgrades.py — derive updated Go toolchain and module pins from trivy reports,
print them, and with `--apply` write them straight into `<variant>.build.env`.

Input: the trivy JSON reports given by `--reports` (all-severity scans). `--image`
filters by filename.
Output: a `GO_BUILDER_TAG` candidate for stdlib CVEs and suggested `GO_MODULE_UPGRADES`
values per module, plus the rationale (CVEs, installed version → target version), on
stdout. Severity is judged by reusing `image-gate.py`'s
`effective_severity = max(vendor, NVD)` directly.

Why the latest is not pulled automatically at build time: see the "Go module CVEs"
section of docs/image-authoring/builder-languages.md.

Called by hand, and by rescan.yml — when the daily drift check finds a published image
blocked, it runs `--apply` here and collects whatever moved into the autofix pull request.
So `--apply` is no longer only a human action, but its output still reaches the default
branch only through a PR whose verify build passed. See docs/decisions/0012.

**The severity floor decides two different things, so it is used twice.** At the default
HIGH it answers "does this image need a rebuild at all" — the gate's blocking threshold.
Once the answer is yes, the rebuild should carry every other fixable module CVE with it, so
run it again with `--min-severity UNKNOWN` to collect those too (unrated findings included;
anything without a fixed version is skipped regardless). The reasoning is in
docs/image-authoring/remediation-priority.md — the cost is the rebuild, not the CVE.

Usage
-----
    python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir>
    python3 scripts/build/suggest-go-upgrades.py --reports out/trivy-reports \\
        --image etcd --min-severity HIGH        # does it need a rebuild?
    python3 scripts/build/suggest-go-upgrades.py --reports out/trivy-reports \\
        --image etcd --min-severity UNKNOWN     # it does — now take everything fixable
    python3 scripts/build/suggest-go-upgrades.py --reports out/trivy-reports \\
        --image etcd --apply --dry-run     # print what would be written, change nothing
    python3 scripts/build/suggest-go-upgrades.py --reports out/trivy-reports \\
        --image etcd --apply                # update images/etcd/<variant>.build.env

`--apply` reads `DEFAULT_BASE_OS` from the `image.env` of the image named by `--image`
to target `<variant>.build.env`. It substitutes only `KEY=value` lines in place
(preserving comments and ordering).

Exit codes
    0  suggestions printed (or a statement that there is nothing to do) — with --apply, written
    2  execution error
"""

import argparse
import functools
import glob
import importlib.util
import json
import os
import pathlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.join(HERE, "..", "gate", "image-gate.py")
IMAGES_DIR = os.path.join(HERE, "..", "..", "images")


def load_gate():
    """Load image-gate.py as a module to reuse its severity rules — keeping a single
    source of truth for those rules."""
    spec = importlib.util.spec_from_file_location("image_gate", GATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def version_tuple(v):
    """'0.56.0' → (0,56,0), for comparison. Any non-numeric tail is discarded."""
    nums = re.findall(r"\d+", v or "")
    return tuple(int(n) for n in nums) or (0,)


STABLE_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


def pick_fixed(raw, installed):
    """The fix point to move to, out of a FixedVersion string.

    Several comma-separated values are **per-branch alternatives**, exactly as for stdlib
    (see the "Go module CVEs" section of docs/image-authoring/builder-languages.md) —
    e.g. grpc's '1.82.2, 1.83.2, 1.84.0-dev.0.2026…-d5a4…'. Taking the overall maximum
    lands on a pre-release pseudo-version, which is neither a release nor the minimum.
    So: the smallest **stable** alternative above the installed version — for an install
    on a fixed branch that is the patch release on the same branch.

    Returns the version without the leading 'v', or None when no stable alternative
    is above the installed version (left to a person).
    """
    cands = []
    for c in re.split(r"[,\s]+", raw or ""):
        if STABLE_RE.match(c.strip()):
            cands.append(c.strip().lstrip("v"))
    floor = version_tuple(installed) if installed else (0,)
    above = [c for c in cands if version_tuple(c) > floor]
    if not above:
        return None
    return min(above, key=version_tuple)


# A Go pseudo-version as trivy prints it (the leading 'v' dropped): 'X.Y.Z-0.<ts>-<sha12>'
# or 'X.Y.Z-<pre>.0.<ts>-<sha12>'. Either way every stable release >= X.Y.Z sorts above it.
PSEUDO_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)-(?:[0-9A-Za-z.]+\.)?0\.(\d{14})-([0-9a-f]{12})$")

GOPROXY = (os.environ.get("GOPROXY") or "https://proxy.golang.org").split(",")[0].rstrip("/")
if GOPROXY in ("direct", "off"):
    GOPROXY = "https://proxy.golang.org"

_proxy_cache = {}


def proxy_get(module, suffix):
    """GET <GOPROXY>/<escaped module>/@v/<suffix> as text, or None on any failure.

    Network failures are never fatal here: every caller falls back to what this script did
    before it looked anything up — a note for a person."""
    import urllib.request
    esc = re.sub(r"[A-Z]", lambda m: "!" + m.group(0).lower(), module)
    url = f"{GOPROXY}/{esc}/@v/{suffix}"
    if url not in _proxy_cache:
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                _proxy_cache[url] = r.read().decode()
        except Exception:
            _proxy_cache[url] = None
    return _proxy_cache[url]


@functools.lru_cache(maxsize=None)
def commit_in_tag(url, tag_hash, sha12):
    """Is commit `sha12` an ancestor of `tag_hash` in the repository at `url`?

    A partial (blob-less) fetch of just that tag's history — about a second for x/crypto.
    Returns None when it cannot be determined (no git, fetch refused)."""
    import subprocess
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        def git(*a):
            return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True, timeout=180)
        try:
            if git("init", "-q", "--bare").returncode:
                return None
            if git("fetch", "-q", "--filter=blob:none", "--no-tags", url, tag_hash).returncode:
                return None
            if git("rev-parse", "--verify", "-q", f"{sha12}^{{commit}}").returncode:
                return False  # not in the tag's history at all
            return git("merge-base", "--is-ancestor", sha12, tag_hash).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return None


def resolve_pseudo(module, pseudo, installed):
    """The first stable release of `module` that contains the commit a pseudo-version
    FixedVersion names — e.g. x/crypto '0.58.1-0.2026…-2f1f834330b2' → '0.59.0'.

    Advisories sometimes record a fix only as the commit that landed it. That commit ships
    in some later tag, but which one cannot be read off the version string: on a repository
    with release branches, a patch release cut after the commit can still lack it. So each
    candidate's tag commit (Origin.Hash from the module proxy) is checked for ancestry with
    git rather than guessed from dates.

    Returns (version, None) or (None, reason)."""
    m = PSEUDO_RE.match(pseudo.strip())
    if not m:
        return None, "not a pseudo-version"
    base = tuple(int(x) for x in m.group(1, 2, 3))
    sha12 = m.group(5)
    listing = proxy_get(module, "list")
    if listing is None:
        return None, "module proxy unreachable"
    floor = version_tuple(installed) if installed else (0,)
    cands = sorted((v.lstrip("v") for v in listing.split() if STABLE_RE.match(v)), key=version_tuple)
    cands = [v for v in cands if version_tuple(v) >= base and version_tuple(v) > floor]
    for v in cands[:8]:
        info = proxy_get(module, f"v{v}.info")
        try:
            origin = json.loads(info or "{}").get("Origin") or {}
        except ValueError:
            origin = {}
        if not origin.get("URL") or not origin.get("Hash"):
            return None, f"the proxy gives no origin commit for v{v}"
        found = commit_in_tag(origin["URL"], origin["Hash"], sha12)
        if found is None:
            return None, f"could not check v{v} with git"
        if found:
            return v, None
    return None, f"no stable release yet contains {sha12}"


def module_requires(module, version):
    """{required module: version} from `module`@`version`'s go.mod, via the proxy, or
    None when it cannot be fetched."""
    text = proxy_get(module, f"v{version}.mod")
    if text is None:
        return None
    req = {}
    block = False
    for line in text.splitlines():
        line = line.split("//")[0].strip()
        if line.startswith("require ("):
            block = True
            continue
        if block and line == ")":
            block = False
            continue
        if line.startswith("require "):
            line = line[len("require "):].strip()
        elif not block:
            continue
        parts = line.split()
        if len(parts) >= 2:
            req[parts[0]] = parts[1].lstrip("v")
    return req


def close_constraints(spec):
    """Raise pins in `spec` ({module: version}) that another pin's go.mod requires higher.

    `go get a@X b@Y` fails outright when a@X requires b at more than Y — it does not raise
    an explicitly named module on its own ('x/net@v0.62.0 requires x/crypto@v0.58.0, not
    x/crypto@v0.55.0'). The CVE minimums are chosen per module, so this collision is the
    ordinary outcome, not an edge case. Iterated to a fixed point, since a raise can bring
    in a newer requirement of its own (x/crypto v0.59.0 → x/text v0.44.0).

    Returns (spec, notes). Modules that are not pinned are left to `go get`, which raises
    those by itself."""
    spec = dict(spec)
    notes = []
    for _ in range(10):
        raised = False
        for name in sorted(spec):
            req = module_requires(name, spec[name])
            if req is None:
                notes.append(f"could not read {name}@v{spec[name]}'s go.mod — inter-module "
                             "constraints not checked; the build will say if one is missed")
                continue
            for dep, need in req.items():
                if dep in spec and version_tuple(spec[dep]) < version_tuple(need):
                    notes.append(f"{dep} v{spec[dep]} → v{need}: required by {name}@v{spec[name]}")
                    spec[dep] = need
                    raised = True
        if not raised:
            break
    return spec, notes


def source_repos(image):
    """'host/owner/repo' of every git source the image's Dockerfiles fetch (ADD or git
    clone). Used to recognise a binary's own main module, which a `replace` in go.work
    cannot raise — that takes a SOURCE_COMMIT / version bump instead."""
    repos = set()
    if not image:
        return repos
    for df in glob.glob(os.path.join(IMAGES_DIR, image, "*.Dockerfile")):
        for m in re.finditer(r"https://([\w.-]+/[\w.-]+/[\w.-]+?)(?:\.git)?(?=[#\s\"']|$)",
                             pathlib.Path(df).read_text(), re.MULTILINE):
            repos.add(m.group(1).lower())
    return repos


def is_own_module(module, repos):
    """github.com/argoproj/argo-cd/v3 belongs to github.com/argoproj/argo-cd."""
    m = module.lower()
    base = re.sub(r"/v\d+$", "", m)
    return any(base == r or m.startswith(r + "/") for r in repos)


def collect_modules(paths, gate, rank, floor):
    """Statically linked Go modules carrying a blocking CVE at or above `floor`.

    Returns: `{module: {"fixed": target_version, "cves": {cve: effective_severity}, "installed": {installed_versions}}}`
    """
    mods = {}
    for p in paths:
        with open(p) as f:
            doc = json.load(f)
        for res in doc.get("Results") or []:
            # Only modules statically linked into a Go binary. OS packages belong to the
            # base-swap lever and are not handled here.
            if res.get("Class") != "lang-pkgs" or res.get("Type") != "gobinary":
                continue
            for v in res.get("Vulnerabilities") or []:
                pkg = v.get("PkgName") or ""
                if pkg == "stdlib":
                    # stdlib is resolved via GO_BUILDER_TAG, not a module upgrade.
                    continue
                eff = gate.effective_severity(v.get("Severity"),
                                               gate.nvd_severity(((v.get("CVSS") or {}).get("nvd") or {}).get("V3Score")))
                if rank.get(eff, 0) < floor:
                    continue
                fx = pick_fixed(v.get("FixedVersion"), v.get("InstalledVersion"))
                e = mods.setdefault(pkg, {"fixed": None, "cves": {}, "installed": set(),
                                          "unfixable": set(), "resolved": []})
                if v.get("InstalledVersion"):
                    e["installed"].add(v["InstalledVersion"])
                if not fx:
                    # No stable alternative above what is installed. If one alternative is a
                    # pseudo-version (the fix recorded only as a commit), find the release
                    # that contains it; otherwise it is left to a person.
                    for alt in re.split(r"[,\s]+", v.get("FixedVersion") or ""):
                        if PSEUDO_RE.match(alt.strip()):
                            fx, why = resolve_pseudo(pkg, alt, v.get("InstalledVersion"))
                            if fx:
                                e["resolved"].append(f"{v['VulnerabilityID']}: fixed at {alt}, "
                                                     f"first contained in v{fx}")
                                break
                    if not fx:
                        if v.get("FixedVersion"):
                            e["unfixable"].add(v["VulnerabilityID"])
                        continue
                if e["fixed"] is None or version_tuple(fx) > version_tuple(e["fixed"]):
                    e["fixed"] = fx
                e["cves"][v["VulnerabilityID"]] = eff
    return mods


def split_modules(mods, image):
    """Separate what GO_MODULE_UPGRADES can do from what it cannot.

    Returns (upgradable, notes): `upgradable` holds only modules with a stable target that
    are not the image's own main module."""
    repos = source_repos(image)
    upgradable, notes = {}, []
    for name in sorted(mods):
        e = mods[name]
        inst = ", ".join(sorted(e["installed"])) or "?"
        for r in e.get("resolved", []):
            notes.append(f"{name}: {r} (checked with git against the tag's commit)")
        if e["unfixable"]:
            notes.append(f"{name} {inst}: {', '.join(sorted(e['unfixable']))} fixed only in a "
                         "pre-release, or at a commit no stable tag could be confirmed to contain "
                         "— nothing to pin yet; see cve-exception-review")
        if e["fixed"] is None:
            continue
        if is_own_module(name, repos):
            notes.append(f"{name} {inst} → {e['fixed']}: this is the image's own source — "
                         "raise SOURCE_COMMIT/APP_VERSION, GO_MODULE_UPGRADES cannot move it")
            continue
        upgradable[name] = e
    return upgradable, notes


def collect_stdlib(paths, gate, rank, floor):
    """The `FixedVersion` alternatives for each blocking stdlib CVE.

    Returns: `{cve: [(major, minor, patch, is_prerelease), ...]}`
    """
    std_alts = {}
    for p in paths:
        with open(p) as f:
            doc = json.load(f)
        for res in doc.get("Results") or []:
            if res.get("Type") != "gobinary":
                continue
            for v in res.get("Vulnerabilities") or []:
                if v.get("PkgName") != "stdlib":
                    continue
                eff = gate.effective_severity(v.get("Severity"),
                                               gate.nvd_severity(((v.get("CVSS") or {}).get("nvd") or {}).get("V3Score")))
                if rank.get(eff, 0) < floor:
                    continue
                alts = []
                for tok in re.split(r"[,\s]+", v.get("FixedVersion") or ""):
                    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(\S*)$", tok.strip())
                    if m:
                        a, b, c, tail = m.groups()
                        alts.append((int(a), int(b), int(c), bool(tail)))
                if alts:
                    std_alts[v["VulnerabilityID"]] = alts
    return std_alts


def builder_candidates(std_alts):
    """From the stdlib alternatives, build the set of "this toolchain resolves them all"
    candidates.

    Why multiple `FixedVersion` values are per-branch alternatives: see the "Go module
    CVEs" section of docs/image-authoring/builder-languages.md. A toolchain T resolves a
    CVE if there is an alternative on the same minor whose patch is at or below T's, or
    if some alternative's minor is lower than T's (already fixed on an earlier branch).

    Returns: `[((major, minor), required_patch), ...]` — ascending by minor
    """
    # Build the candidate minors from stable-release alternatives only (a pre-release
    # cannot be used as a toolchain tag).
    cand = sorted({(a, b) for alts in std_alts.values() for a, b, _, pre in alts if not pre})
    rows = []
    for mm in cand:
        need = 0
        covered = True
        for cve, alts in std_alts.items():
            same = [c for a, b, c, pre in alts if (a, b) == mm and not pre]
            if same:
                need = max(need, max(same))
            elif not any((a, b) < mm for a, b, _, _ in alts):
                covered = False  # only fixed on a branch higher than this minor
                break
        if covered:
            rows.append((mm, need))
    return rows


def numeric_prefix(v):
    """'1.26.5-trixie' → ((1,26,5), '-trixie'). The suffix must be preserved as-is."""
    m = re.match(r"^(\d+(?:\.\d+)*)(.*)$", v or "")
    if not m:
        return (0,), ""
    return tuple(int(x) for x in m.group(1).split(".")), m.group(2)


# The builder image variant assumed when an image has no GO_BUILDER_TAG to copy a suffix
# from. Every Go image in this repository is on -trixie.
DEFAULT_BUILDER_SUFFIX = "-trixie"


def choose_builder_tag(rows, current):
    """The single GO_BUILDER_TAG value that resolves every blocking stdlib CVE.

    **Staying on the minor the image already pins is preferred.** A toolchain minor bump
    is a far bigger change than a patch bump — go.mod may not accept it, and it can move
    language semantics — so this climbs to the highest stable branch only when no
    candidate sits on the current minor. The existing suffix is preserved, since it names
    the builder image variant rather than the toolchain.

    This is the one place that decision is made: both the printed suggestion and `--apply`
    call it, so they can never recommend two different values for the same report.

    Returns `(tag, stayed_on_current_minor)`, or `(None, False)` when there is no
    stable candidate at all.
    """
    if not rows:
        return None, False
    cur_nums, suffix = numeric_prefix(current)
    same_minor = [r for r in rows if r[0] == cur_nums[:2]]
    (a, b), c = (same_minor or rows)[-1]
    return f"{a}.{b}.{c}{suffix or DEFAULT_BUILDER_SUFFIX}", bool(same_minor)


def parse_module_specs(raw):
    """'mod@v1.2.3 mod2@v0.4.0' → {mod: '1.2.3'} — kept as strings: rebuilding a version
    from a numeric tuple mangles anything that is not plain X.Y.Z."""
    out = {}
    for tok in (raw or "").split():
        if "@" not in tok:
            continue
        name, ver = tok.rsplit("@", 1)
        out[name] = ver.lstrip("v")
    return out


def read_env(path):
    """Read only `KEY=value` shell assignments. Quotes around the value are stripped."""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in pathlib.Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if not re.match(r"^[A-Z_][A-Z0-9_]*$", k):
            continue
        out[k] = v.strip().strip('"').strip("'")
    return out


def pin_changes(paths, pins, gate, rank, floor, image=""):
    """Pins that need raising. Returns: (changes, notes)."""
    changes, notes = [], []

    std_alts = collect_stdlib(paths, gate, rank, floor)
    if std_alts:
        rows = builder_candidates(std_alts)
        cur = pins.get("GO_BUILDER_TAG", "")
        if not rows:
            notes.append(f"{len(std_alts)} blocking stdlib CVEs — no stable-release alternative "
                         "(a pre-release toolchain may be required)")
        elif not cur:
            notes.append(f"{len(std_alts)} blocking stdlib CVEs — this image has no GO_BUILDER_TAG")
        else:
            tag, _ = choose_builder_tag(rows, cur)
            if numeric_prefix(cur)[0][:3] < numeric_prefix(tag)[0][:3]:
                changes.append({"key": "GO_BUILDER_TAG", "current": cur,
                                "required": tag,
                                "reason": f"{len(std_alts)} blocking stdlib CVEs", "appliable": True})

    mods, mod_notes = split_modules(collect_modules(paths, gate, rank, floor), image)
    notes.extend(mod_notes)
    if mods:
        cur_raw = pins.get("GO_MODULE_UPGRADES")
        cur_mods = parse_module_specs(cur_raw)
        behind = {n: e["fixed"] for n, e in mods.items()
                  if cur_mods.get(n) is None
                  or version_tuple(cur_mods[n]) < version_tuple(e["fixed"])}
        if behind:
            listing = " ".join(f"{n}@v{behind[n]}" for n in sorted(behind))
            if cur_raw is None:
                # This image does not consume GO_MODULE_UPGRADES (it uses per-image
                # FIX_VERSION ARGs instead). Writing a value would have no effect, so
                # leave it to a person.
                notes.append(f"{len(behind)} modules behind ({listing}) — this image does not "
                             "use GO_MODULE_UPGRADES. Check its per-image FIX_VERSION manually")
            else:
                merged = dict(cur_mods)
                merged.update(behind)
                merged, chain = close_constraints(merged)
                notes.extend(chain)
                spec = " ".join(f"{n}@v{merged[n]}" for n in sorted(merged))
                changes.append({"key": "GO_MODULE_UPGRADES", "current": cur_raw,
                                "required": spec,
                                "reason": f"{len(behind)} modules behind", "appliable": True})
    return changes, notes


def apply_changes(build_env_path, changes):
    """Substitute only the KEY=value lines in build.env, in place (preserving comments and
    ordering). Returns the list of keys applied."""
    p = pathlib.Path(build_env_path)
    text = p.read_text()
    applied = []
    for ch in changes:
        if not ch.get("appliable"):
            continue
        key = ch["key"]
        pattern = re.compile(rf'^({re.escape(key)}=)(")?.*?(")?$', re.MULTILINE)
        m = pattern.search(text)
        if not m:
            continue
        # Keep the quoting the line already had. Deciding it afresh from the new value
        # rewrites GO_MODULE_UPGRADES="one@v1.2.3" to the unquoted form the moment the
        # list drops to a single module — a diff that says nothing, on a file whose whole
        # point is that its diffs are the record of what changed.
        quote = '"' if (m.group(2) and m.group(3)) or " " in ch["required"] else ""
        text = pattern.sub(lambda _: f'{m.group(1)}{quote}{ch["required"]}{quote}', text, count=1)
        applied.append(key)
    if applied:
        p.write_text(text)
    return applied


def current_pins(image):
    """The pins already committed for `image`, so the printed suggestion can be phrased
    against them rather than in a vacuum.

    Returns `{}` when `--image` does not name an image directory — it is only a
    report-filename filter, so it is not required to.
    """
    if not image:
        return {}
    try:
        return read_env(resolve_build_env_path(image))
    except SystemExit:
        return {}


def resolve_build_env_path(image):
    """Determine the <variant>.build.env path from DEFAULT_BASE_OS in
    images/<image>/image.env."""
    idir = os.path.join(IMAGES_DIR, image)
    image_env = read_env(os.path.join(idir, "image.env"))
    variant = image_env.get("DEFAULT_BASE_OS") or ""
    if not variant:
        raise SystemExit(f"images/{image}/image.env has no DEFAULT_BASE_OS")
    return os.path.join(idir, f"{variant}.build.env")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reports", required=True, help="directory of trivy reports (JSON)")
    ap.add_argument("--image", default="", help="only reports whose filename contains this string")
    ap.add_argument("--min-severity", default="HIGH",
                    choices=["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"],
                    help="only suggest at or above this severity. Default HIGH — the gate's "
                         "blocking threshold, i.e. what decides whether a rebuild happens at "
                         "all. Once a rebuild is going to happen anyway, run it again with "
                         "UNKNOWN to collect every fixable module CVE in the image, unrated "
                         "ones included: findings without a fixed version are skipped either "
                         "way, so UNKNOWN means 'everything that can actually be fixed'. See "
                         "docs/image-authoring/remediation-priority.md")
    ap.add_argument("--apply", action="store_true",
                     help="write directly into images/<image>/<variant>.build.env. Requires --image")
    ap.add_argument("--dry-run", action="store_true",
                     help="use with --apply — print what would be written and leave the file untouched")
    args = ap.parse_args()

    gate = load_gate()
    rank = gate.RANK
    floor = rank[args.min_severity]

    paths = sorted(glob.glob(os.path.join(args.reports, "*.json")))
    if args.image:
        paths = [p for p in paths if args.image in os.path.basename(p)]
    if not paths:
        print(f"::error::no reports found: {args.reports} (--image={args.image or 'all'})", file=sys.stderr)
        return 2

    if args.apply and not args.image:
        print("::error::--apply requires --image (there is no way to know which build.env to target)",
              file=sys.stderr)
        return 2

    mods, mod_notes = split_modules(collect_modules(paths, gate, rank, floor), args.image)
    std_alts = collect_stdlib(paths, gate, rank, floor)
    pins = current_pins(args.image)

    if std_alts:
        rows = builder_candidates(std_alts)
        print("# There are blocking stdlib CVEs — resolve these with the toolchain, not GO_MODULE_UPGRADES.")
        print(f"#   {len(std_alts)} CVEs affected. Any of the following resolves all of them:")
        for (a, b), c in rows:
            print(f"#     go{a}.{b}.{c}")
        tag, on_current_minor = choose_builder_tag(rows, pins.get("GO_BUILDER_TAG", ""))
        if tag:
            why = ("staying on the minor this image already pins" if on_current_minor
                   else "the highest stable branch")
            print(f"# GO_BUILDER_TAG={tag}   # {why}")
        else:
            print("#   ::warning:: no stable-release alternative — a pre-release toolchain may be required")
        print()

    for n in mod_notes:
        print(f"# ::warning:: {n}")
    if not mods and not std_alts:
        print("# No Go module upgrades suggested (no findings at or above that severity)")
        return 0

    if mods:
        print(f"# Derived from Go module CVEs at {args.min_severity} or above — apply to GO_MODULE_UPGRADES in build.env.")
        for name in sorted(mods):
            e = mods[name]
            inst = ", ".join(sorted(e["installed"])) or "?"
            cves = ", ".join(sorted(e["cves"]))
            print(f"#   {name}  {inst} → {e['fixed']}")
            print(f"#     {cves}")
        specs = " ".join(f"{n}@v{mods[n]['fixed']}" for n in sorted(mods))
        print(f'GO_MODULE_UPGRADES="{specs}"')
        print()
        print("# Note — these are the minimum the CVEs require. Merged with the image's existing pins,")
        print("#   --apply also raises any pin another pin's go.mod requires higher (see its notes).")
        print("#   If the build still fails with 'requires ...@vX, not ...@vY', raise it to that version.")

    if not args.apply:
        return 0

    build_env_path = resolve_build_env_path(args.image)
    pins = read_env(build_env_path)
    changes, notes = pin_changes(paths, pins, gate, rank, floor, args.image)

    print()
    print(f"# --apply target: {os.path.relpath(build_env_path)}")
    for n in notes:
        print(f"#   note: {n}")
    if not changes:
        print("#   no changes — the pins already meet the required severity threshold")
        return 0
    for ch in changes:
        print(f"#   {ch['key']}: {ch['current']!r} → {ch['required']!r}  ({ch['reason']})")

    if args.dry_run:
        print("#   --dry-run — nothing written to the file")
        return 0

    applied = apply_changes(build_env_path, changes)
    print(f"#   applied: {', '.join(applied) if applied else '(target keys not found in the file)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
