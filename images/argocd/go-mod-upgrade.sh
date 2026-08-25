#!/usr/bin/env sh
# go-mod-upgrade — applies the list of Go modules to force-upgrade for CVEs to the current
# module. Called with no arguments from the builder stage, after cd-ing into each Go project.
#
# Why this is a separate script
# -----------------------------
# Listing the upgrade targets directly in the Dockerfile means editing four places for every
# new CVE:
#   1. add <MOD>_FIX_VERSION to build.env   2. add the ARG declaration (in every stage)
#   3. add it to the go get list (per build target)   4. add the name to BUILD_ARGS
# Taking the list as a single GO_MODULE_UPGRADES value means **one line of build.env** changes
# and the Dockerfile stays untouched — and this image will keep receiving CVE fixes.
#
# Modules in the list that this project does not use are skipped
# --------------------------------------------------------------
# One image builds several Go projects (argocd, helm, kustomize, git-lfs) with different
# dependencies. `go get` **adds** a requirement to go.mod even for a module absent from the
# dependency graph (a following go mod tidy removes it again), so not adding it in the first
# place states the intent more clearly — and lets one list be reused across all four projects.
#
# Format: a space-separated list of `<module path>@<version>`.
#   GO_MODULE_UPGRADES="golang.org/x/net@v0.56.0 google.golang.org/grpc@v1.82.1"
set -eu

if [ -z "${GO_MODULE_UPGRADES:-}" ]; then
  echo "go-mod-upgrade: GO_MODULE_UPGRADES is empty — continuing with no upgrades"
  exit 0
fi

targets=""
for spec in $GO_MODULE_UPGRADES; do
  path="${spec%@*}"
  if [ "$path" = "$spec" ]; then
    echo "go-mod-upgrade: ::error:: '$spec' has no @<version>"
    exit 2
  fi
  if go list -m "$path" >/dev/null 2>&1; then
    targets="$targets $spec"
    echo "go-mod-upgrade: applying $spec"
  else
    echo "go-mod-upgrade: skipping $path (not in this project's dependency graph)"
  fi
done

if [ -z "$targets" ]; then
  echo "go-mod-upgrade: nothing to apply"
  exit 0
fi

# shellcheck disable=SC2086  # targets is a space-separated list, split deliberately
go get $targets
go mod tidy
