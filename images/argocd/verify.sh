#!/usr/bin/env bash
# Functional verification for the argocd image — runs on the host under bash
# (build-hardened-image.sh invokes it as
# `env TAG=... PLATFORM=... <build.env variables> bash verify.sh`). Scope and background:
# README.md.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
APP_VERSION="${APP_VERSION:?APP_VERSION environment variable is required (passed from build.env)}"
SOURCE_COMMIT="${SOURCE_COMMIT:?SOURCE_COMMIT environment variable is required}"
HELM_VERSION="${HELM_VERSION:?HELM_VERSION environment variable is required}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:?KUSTOMIZE_VERSION environment variable is required}"
GIT_LFS_VERSION="${GIT_LFS_VERSION:?GIT_LFS_VERSION environment variable is required}"

echo "== image metadata =="
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "999" ] || { echo "FAIL: Config.User is not 999 (actual: $USER_CFG) — upstream ARGOCD_USER_ID"; exit 1; }
ENTRY="$(docker inspect --format '{{json .Config.Entrypoint}}' "$TAG")"
case "$ENTRY" in
  *tini*) ;;
  *) echo "FAIL: ENTRYPOINT does not contain tini (actual: $ENTRY)"; exit 1 ;;
esac
echo "   Config.User=$USER_CFG  Entrypoint=$ENTRY"

docker run --rm -i --platform "$PLATFORM" \
  -e APP_VERSION="$APP_VERSION" \
  -e SOURCE_COMMIT="$SOURCE_COMMIT" \
  -e HELM_VERSION="$HELM_VERSION" \
  -e KUSTOMIZE_VERSION="$KUSTOMIZE_VERSION" \
  -e GIT_LFS_VERSION="$GIT_LFS_VERSION" \
  --entrypoint sh "$TAG" <<'GUEST'
set -e

echo "== argocd itself =="
OUT="$(argocd version --client --short)"
echo "   $OUT"
case "$OUT" in
  *"v$APP_VERSION"*) ;;
  *) echo "FAIL: version output lacks v$APP_VERSION — check the Makefile ldflags injection"; exit 1 ;;
esac
case "$OUT" in
  *"$SOURCE_COMMIT"*) ;;
  *) echo "WARN: the pinned commit is not visible in the version output (it may be elided in short form)" ;;
esac

echo "== the nine upstream symlinks =="
for n in argocd-server argocd-repo-server argocd-cmp-server argocd-application-controller \
         argocd-dex argocd-notifications argocd-applicationset-controller argocd-k8s-auth \
         argocd-commit-server; do
  [ -x "/usr/local/bin/$n" ] || { echo "FAIL: /usr/local/bin/$n is missing"; exit 1; }
done
echo "   all nine present and executable"

echo "== bundled tools (replaced by source compilation) =="
H="$(helm version --short)"
echo "   helm      $H"
case "$H" in *"$HELM_VERSION"*) ;; *) echo "FAIL: helm version is not $HELM_VERSION"; exit 1 ;; esac

K="$(kustomize version)"
echo "   kustomize $K"
case "$K" in *"$KUSTOMIZE_VERSION"*) ;; *) echo "FAIL: kustomize version is not $KUSTOMIZE_VERSION"; exit 1 ;; esac

L="$(git-lfs version)"
echo "   git-lfs   $L"
case "$L" in *"$GIT_LFS_VERSION"*) ;; *) echo "FAIL: git-lfs version is not $GIT_LFS_VERSION"; exit 1 ;; esac

echo "== C tools built from source (absent from SLE_BCI) =="
[ -x /usr/bin/tini ] || { echo "FAIL: /usr/bin/tini is missing"; exit 1; }
/usr/bin/tini --version
[ -x /usr/bin/connect-proxy ] || { echo "FAIL: /usr/bin/connect-proxy is missing"; exit 1; }
# connect prints usage and exits non-zero when called with no arguments — only check that it runs.
/usr/bin/connect-proxy >/dev/null 2>&1 || true
echo "   tini and connect-proxy are runnable"

echo "== required runtime tools (matching upstream's apt list) =="
git --version >/dev/null       || { echo "FAIL: git is missing"; exit 1; }
gpg --version >/dev/null       || { echo "FAIL: gpg is missing"; exit 1; }
ssh -V 2>/dev/null || ssh -V   || { echo "FAIL: ssh is missing"; exit 1; }
echo "   git, gpg, and ssh are present"

echo "== the commands the chart actually runs (reproducing the argo-cd chart repo-server init container) =="
# Reproduces the coreutils 9.3+ requirement — details: README.md.
: > /tmp/_vsrc
if ! /bin/cp --update=none /tmp/_vsrc /tmp/_vdst 2>/dev/null; then
  echo "FAIL: 'cp --update=none' does not work — the base OS coreutils is older than 9.3."
  echo "      The argo-cd chart's repo-server init container uses this form, so deployment would fail."
  cp --version 2>/dev/null | head -1
  exit 1
fi
echo "   cp --update=none works ($(cp --version 2>/dev/null | head -1))"

# Reproduces the flow that copies the argocd binary into a shared volume.
mkdir -p /tmp/_vrun
/bin/cp --update=none /usr/local/bin/argocd /tmp/_vrun/argocd || { echo "FAIL: copying argocd failed"; exit 1; }
/bin/ln -sf /tmp/_vrun/argocd /tmp/_vrun/argocd-cmp-server || { echo "FAIL: creating the cmp-server symlink failed"; exit 1; }
[ -x /tmp/_vrun/argocd-cmp-server ] || { echo "FAIL: the copied argocd is not executable"; exit 1; }
echo "   copyutil flow reproduced (copy + cmp-server link)"

echo "== git-lfs system configuration (upstream git lfs install --system) =="
git config --system --get filter.lfs.clean >/dev/null || { echo "FAIL: /etc/gitconfig has no LFS filter"; exit 1; }
echo "   filter.lfs.clean is registered"

echo "== upstream runtime directory structure =="
[ -L /etc/ssh/ssh_known_hosts ] || { echo "FAIL: the /etc/ssh/ssh_known_hosts symlink is missing"; exit 1; }
[ -d /app/config/tls ]          || { echo "FAIL: /app/config/tls is missing"; exit 1; }
[ -d /app/config/gpg/keys ]     || { echo "FAIL: /app/config/gpg/keys is missing"; exit 1; }
[ -x /usr/local/bin/entrypoint.sh ]     || { echo "FAIL: entrypoint.sh is missing"; exit 1; }
[ -x /usr/local/bin/uid_entrypoint.sh ] || { echo "FAIL: uid_entrypoint.sh is missing"; exit 1; }
[ -x /usr/local/bin/gpg-wrapper.sh ]    || { echo "FAIL: gpg-wrapper.sh is missing"; exit 1; }
echo "   ssh_known_hosts link, /app/config/{tls,gpg/keys}, and wrapper scripts are in place"

echo "VERIFY-OK"
GUEST
