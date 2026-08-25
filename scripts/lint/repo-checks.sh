#!/usr/bin/env bash
# =============================================================================
# repo-checks.sh
#   Static checks over the repository — reads files only. It never builds an image, never
#   runs verify.sh, and never touches a registry, so it is safe and fast (well under a
#   minute) both locally and on a pull request from a fork.
#
#   This is a checker, not an orchestrator — it does not conflict with design rule 1
#   ("one orchestrator, always"), which is about how images get built.
#
# Usage:
#   bash scripts/lint/repo-checks.sh
#
# Exit codes: 0 = every check passed. 1 = at least one failed.
#
# Every check here exists because the corresponding mistake was actually made in this
# repository at some point. Adding a check is how a class of mistake stops recurring —
# see "Where work gets recorded" in CLAUDE.md.
# =============================================================================
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

FAILED=0
section() { printf '\n== %s\n' "$1"; }
ok()      { printf '   OK — %s\n' "$1"; }
fail()    { printf '   FAIL — %s\n' "$1"; FAILED=1; }

# --- 1. Internal path references resolve -------------------------------------
# Moving or renumbering files silently breaks references. Lines that also mention
# "upstream" are skipped: they name a path in someone else's repository (etcd's
# `upstream scripts/build_lib.sh`, for instance), not one of ours.
section "internal path references"
broken="$(
  grep -rnE '(docs|images|scripts)/[A-Za-z0-9_./-]+\.(md|sh|py|env)' \
    --include='*.md' --include='*.sh' --include='*.py' --include='*.env' \
    --include='*Dockerfile' --include='*.yml' . 2>/dev/null \
  | grep -viE 'upstream|업스트림' \
  | grep -oE '(docs|images|scripts)/[A-Za-z0-9_./-]+\.(md|sh|py|env)' \
  | sort -u | while read -r p; do [ -e "$p" ] || echo "$p"; done
)"
if [ -n "$broken" ]; then
  while IFS= read -r p; do fail "referenced but missing: $p"; done <<<"$broken"
else
  ok "every referenced path exists"
fi

# --- 2. Supply-chain forbidden patterns --------------------------------------
# Design rule 7. Never disable TLS verification, never pipe a remote script into a shell.
# This file is excluded: it necessarily contains the patterns it searches for.
section "supply-chain forbidden patterns"
hits="$(grep -rnE 'no-check-certificate|curl -[A-Za-z]*k|curl [^|]*\| *(sh|bash|perl)|wget [^|]*\| *(sh|bash)' \
        --exclude='repo-checks.sh' \
        images/ scripts/ .github/ 2>/dev/null || true)"
if [ -n "$hits" ]; then
  while IFS= read -r l; do fail "$l"; done <<<"$hits"
else
  ok "no TLS-verification bypass, no pipe-to-shell"
fi

# --- 3. Every remote download is checksum-verified ---------------------------
# A tarball has no equivalent of a git commit SHA, so its SHA256 must be verified in the
# same RUN that fetches it (otherwise a later layer could be cached separately).
section "remote downloads are checksum-verified"
python3 - <<'PY' || FAILED=1
import re, pathlib, sys
bad = []
for p in sorted(pathlib.Path("images").glob("*/*Dockerfile")):
    joined, buf = [], ""
    for ln in p.read_text(encoding="utf-8").split("\n"):
        if ln.rstrip().endswith("\\"):
            buf += ln.rstrip()[:-1] + " "
        else:
            joined.append(buf + ln); buf = ""
    for block in joined:
        b = block.strip()
        if b.startswith("#") or not b.startswith("RUN"):
            continue
        if re.search(r"(wget|curl)\s+[\"']?http", b) and "sha256sum" not in b:
            bad.append(f"{p}: {b[:100]}")
for b in bad:
    print(f"   FAIL — unverified download: {b}")
if not bad:
    print("   OK — every remote download verifies a checksum in the same RUN")
sys.exit(1 if bad else 0)
PY

# --- 4. build.env declares the orchestrator contract -------------------------
# build-hardened-image.sh only passes names listed in BUILD_ARGS. A name listed there but
# never assigned builds silently with the Dockerfile default — the failure is invisible.
section "build.env contract"
python3 - <<'PY' || FAILED=1
import re, pathlib, sys
REQUIRED = ("DOCKERFILE", "TARGET", "BUILD_ARGS", "APP_VERSION")
bad = []
for p in sorted(pathlib.Path("images").glob("*/*.build.env")):
    kv = {}
    for line in p.read_text(encoding="utf-8").split("\n"):
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if re.fullmatch(r"[A-Z_][A-Z0-9_]*", k):
            kv[k] = v.strip().strip('"').strip("'")
    for key in REQUIRED:
        if key not in kv:
            bad.append(f"{p}: missing {key}")
    dockerfile = kv.get("DOCKERFILE")
    if dockerfile and not (p.parent / dockerfile).exists():
        bad.append(f"{p}: DOCKERFILE points at a missing file: {dockerfile}")
    for name in (kv.get("BUILD_ARGS") or "").split():
        if name not in kv:
            bad.append(f"{p}: BUILD_ARGS lists {name}, but it is never assigned")
    # image.env must name a variant that exists
for p in sorted(pathlib.Path("images").glob("*/image.env")):
    m = re.search(r"^DEFAULT_BASE_OS=(\S+)", p.read_text(encoding="utf-8"), re.M)
    if not m:
        bad.append(f"{p}: missing DEFAULT_BASE_OS")
    elif not (p.parent / f"{m.group(1)}.build.env").exists():
        bad.append(f"{p}: DEFAULT_BASE_OS={m.group(1)} has no matching .build.env")
for b in bad:
    print(f"   FAIL — {b}")
if not bad:
    print("   OK — every build.env declares the contract and resolves")
sys.exit(1 if bad else 0)
PY

# --- 5. The syntax directive is the first line -------------------------------
# A parser directive stops being one the moment any line precedes it — including a comment.
# It then silently has no effect and the pinned frontend is not used.
section "Dockerfile syntax directive placement"
python3 - <<'PY' || FAILED=1
import pathlib, sys
bad = []
for p in sorted(pathlib.Path("images").glob("*/*Dockerfile")):
    lines = p.read_text(encoding="utf-8").split("\n")
    idx = next((i for i, l in enumerate(lines) if l.strip().startswith("# syntax=")), None)
    if idx is not None and idx != 0:
        bad.append(f"{p}: '# syntax=' is on line {idx + 1}; it must be line 1 to take effect")
for b in bad:
    print(f"   FAIL — {b}")
if not bad:
    print("   OK — no misplaced syntax directive")
sys.exit(1 if bad else 0)
PY

# --- 6. READMEs are bilingual ------------------------------------------------
# Korean is the source of truth; both files must exist and link to each other.
section "bilingual READMEs"
python3 - <<'PY' || FAILED=1
import pathlib, sys
bad = []
targets = [pathlib.Path(".")] + sorted(p for p in pathlib.Path("images").iterdir() if p.is_dir())
for d in targets:
    en, ko = d / "README.md", d / "README.ko.md"
    if not en.exists():
        bad.append(f"{d}: no README.md"); continue
    if not ko.exists():
        bad.append(f"{d}: no README.ko.md (READMEs are bilingual)"); continue
    if "README.ko.md" not in en.read_text(encoding="utf-8")[:400]:
        bad.append(f"{en}: no link to README.ko.md near the top")
    if "README.md" not in ko.read_text(encoding="utf-8")[:400]:
        bad.append(f"{ko}: no link to README.md near the top")
for b in bad:
    print(f"   FAIL — {b}")
if not bad:
    print("   OK — every README has its Korean counterpart, cross-linked")
sys.exit(1 if bad else 0)
PY

# --- 7. Syntax ---------------------------------------------------------------
section "syntax"
syntax_bad=0
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || { fail "bash syntax: $f"; syntax_bad=1; }
done < <(find scripts images -name '*.sh' -type f)
while IFS= read -r f; do
  python3 -m py_compile "$f" 2>/dev/null || { fail "python syntax: $f"; syntax_bad=1; }
done < <(find scripts -name '*.py' -type f)
python3 - <<'PY' || { FAILED=1; syntax_bad=1; }
import json, pathlib, sys
bad = []
for name in ("cve-exceptions.json", "published.json"):
    p = pathlib.Path(name)
    if not p.exists():
        bad.append(f"{name}: missing"); continue
    try:
        json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        bad.append(f"{name}: {e}")
for b in bad:
    print(f"   FAIL — {b}")
sys.exit(1 if bad else 0)
PY
python3 - <<'PY' || { FAILED=1; syntax_bad=1; }
import pathlib, sys
try:
    import yaml
except ImportError:
    print("   SKIP — pyyaml not installed, workflow YAML not parsed")
    sys.exit(0)
bad = []
for p in sorted(pathlib.Path(".github/workflows").glob("*.yml")):
    try:
        d = yaml.safe_load(p.read_text(encoding="utf-8"))
        if not d or "jobs" not in d:
            bad.append(f"{p}: no jobs")
    except Exception as e:
        bad.append(f"{p}: {e}")
for b in bad:
    print(f"   FAIL — {b}")
sys.exit(1 if bad else 0)
PY
[ "$syntax_bad" = "0" ] && ok "bash, python, and json all parse"

# --- summary -----------------------------------------------------------------
echo
if [ "$FAILED" = "0" ]; then
  echo "repo-checks: all checks passed"
else
  echo "repo-checks: FAILED — see the entries above"
fi
exit "$FAILED"
