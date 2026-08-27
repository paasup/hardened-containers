#!/usr/bin/env bash
# Functional verification for the readiness-checker image — runs on the host under bash
# (build-hardened-image.sh invokes it as `env TAG=... PLATFORM=... SOURCE_COMMIT=...
# APP_VERSION=... bash verify.sh`).
#
# Unlike images/kyverno/ (a cobra-based CLI with a top-level `--help` that exits 0), this
# binary is a thin dispatcher built on the plain `flag` package (see main.go — no cobra).
# It has no top-level --help: called bare it prints a usage banner and calls os.Exit(1);
# an unknown subcommand does the same. That exit-1-with-usage is this binary's own
# documented behaviour, not a failure, so it is asserted here rather than treated as one.
#
# The genuinely side-effect-free, zero-exit smoke test is a *subcommand's* `-h`: each
# subcommand builds its own `flag.NewFlagSet(..., flag.ExitOnError)` and calls fs.Parse()
# before doing anything else (before touching a Kubernetes client or the network) — Go's
# flag package special-cases ErrHelp under ExitOnError to `os.Exit(0)` (unlike any other
# parse error, which exits 2). Confirmed locally against the same flag-package version
# this binary uses: `check-endpoints -h` prints the flag usage and exits 0 without ever
# reaching `getKubernetesClient()`. Actually starting a check (which does need a
# Kubernetes API connection or a live HTTP endpoint) is outside this smoke test's scope,
# same as images/kyverno/README.md's "requires a Kubernetes API server" caveat.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
APP_VERSION="${APP_VERSION:?APP_VERSION environment variable is required (build-hardened-image.sh passes it from build.env)}"

echo "== run-as user (nonroot, from image metadata) =="
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "65532:65532" ] || { echo "FAIL: the image Config.User is not 65532:65532 (actual: $USER_CFG)"; exit 1; }
echo "   Config.User=$USER_CFG"

docker run --rm -i --platform "$PLATFORM" -e APP_VERSION="$APP_VERSION" --entrypoint bash "$TAG" <<'GUEST'
set -e

echo "== locating the binary =="
[ -x /app/readiness-checker ] || { echo "FAIL: /app/readiness-checker is missing or not executable"; exit 1; }
echo "   /app/readiness-checker present and executable"

echo "== bare invocation (own documented usage-and-exit-1 behaviour, no cluster contact) =="
set +e
/app/readiness-checker >/tmp/bare.out 2>&1
BARE_RC=$?
set -e
[ "$BARE_RC" -eq 1 ] || { echo "FAIL: bare invocation exited $BARE_RC, expected 1"; cat /tmp/bare.out; exit 1; }
BARE_FIRST_LINE="$(head -n1 /tmp/bare.out)"
case "$BARE_FIRST_LINE" in
  "Usage: readiness-checker <command>"*) ;;
  *) echo "FAIL: bare invocation did not print the expected usage banner"; cat /tmp/bare.out; exit 1 ;;
esac
echo "   exited 1 with usage banner, as expected (no subcommand given)"

echo "== 'check-endpoints -h' smoke test (side-effect-free: flag.Parse exits before any Kubernetes client is created) =="
set +e
/app/readiness-checker check-endpoints -h >/tmp/help.out 2>&1
HELP_RC=$?
set -e
[ "$HELP_RC" -eq 0 ] || { echo "FAIL: 'check-endpoints -h' exited $HELP_RC, expected 0"; cat /tmp/help.out; exit 1; }
[ -s /tmp/help.out ] || { echo "FAIL: 'check-endpoints -h' produced no output"; exit 1; }
case "$(cat /tmp/help.out)" in
  *service-name*) ;;
  *) echo "FAIL: 'check-endpoints -h' output did not list the expected flags"; cat /tmp/help.out; exit 1 ;;
esac
i=0
while IFS= read -r line; do echo "   $line"; i=$((i+1)); [ "$i" -ge 5 ] && break; done < /tmp/help.out
echo "   exited 0 with flag usage, as expected"

echo "VERIFY-OK"
GUEST
