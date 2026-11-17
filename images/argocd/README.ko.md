# argocd (자체 빌드)

[English](README.md) · 한국어

`quay.io/argoproj/argocd` 를 대체하는 하드닝 이미지. 업스트림 소스를 pinned commit 으로
직접 컴파일하고, 업스트림이 릴리스 바이너리로 내려받던 번들 도구(helm·kustomize·git-lfs)까지
같은 Go 툴체인으로 다시 만든다.

> 이 이미지는 Argo CD 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

```sh
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

채택 결정과 후보 비교·받아들인 비용은 [ADR 0007](../../docs/decisions/0007-argocd-self-build.md), 이미지 선정 규칙과 빌드 프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가 갖는다.

## 왜 자체 빌드하는가

이 이미지의 차단 CVE 는 대부분 OS 패키지가 아니라 **바이너리에 정적 링크된 Go 모듈**이다.
그래서 앞선 두 레버가 모두 통하지 않는다.

- **상위 태그 교체 불가** — argo-cd 는 지원 라인(`SUPPORT_LINE`)의 최신 패치를 쓴다.
  업스트림 이미지에 들어가는 Go 툴체인·모듈과 번들 도구 바이너리는 각 업스트림
  프로젝트의 선택이라, 태그를 올려도 우리가 원하는 시점에 바뀌지 않는다.
- **베이스 OS 교체로는 거의 안 잡힌다** — 모듈은 컴파일된 바이너리 안에 있다.

업스트림 Dockerfile 은 helm/kustomize/git-lfs 를 `hack/install.sh` 로 **미리 빌드된 릴리스
바이너리를 내려받아** 넣는다. 그 바이너리의 Go 버전은 우리가 통제할 수 없어, 이 셋도
argocd 본체와 함께 소스에서 다시 컴파일한다.

부분 조치는 효과가 없다 — 같은 `stdlib`·`x/crypto` 취약점이 다섯 바이너리에 각각
들어있어서, 한 바이너리만 고치면 나머지에 그대로 남는다. 고유 CVE 는 소수이고 대부분이
공유분이라, 전부 다시 만들어야 게이트가 0 이 된다.

`pebble` 은 우리가 넣은 것이 아니라 ubuntu 베이스에 딸려온 것이다 — 베이스를 SUSE BCI 로
바꾸면 함께 사라진다.

## 업스트림과 다르게 한 부분

| 항목 | 업스트림 | 이 이미지 | 이유 |
|---|---|---|---|
| 최종 베이스 | `ubuntu` | `registry.suse.com/bci/bci-base` | 이미지들은 SUSE BCI 하나만 쓴다([docs/image-authoring/](../../docs/image-authoring/README.md) 원칙 2). `pebble` 도 함께 소멸 |
| helm / kustomize / git-lfs | 릴리스 바이너리 다운로드 | 소스 컴파일 | 다운로드 바이너리의 Go 를 통제할 수 없다 |
| helm 버전 | 업스트림 pin | 패치를 받는 최신 minor 의 최신 패치 | helm 은 최신 minor 에만 패치를 낸다 — 4.3.0 이후 4.2 줄은 패치가 없다. 업스트림 release-3.6 도 같은 helm 을 쓴다 |
| git-lfs 버전 | 업스트림 pin | 보안 수정이 들어간 릴리스 | 업스트림 v3.5.4 의 3.7.1 은 3.8.1 에서만 고쳐진 HIGH 보안 권고들에 해당한다(3.7.x 백포트 없음). 아래 "스캐너가 못 보는 것" 참고 |
| kustomize 버전 | 업스트림 pin | **동일** | 5.8.3 은 `go 1.27.0` 을 요구해 1.26 빌더로는 빌드되지 않고, 보안 수정도 없다("No functional changes"). Go 1.27 로 빌더를 옮길 때 함께 올린다 |
| git 소스 고정 | (태그) | 커밋 SHA (`*_COMMIT`) | argocd 본체뿐 아니라 helm·kustomize·git-lfs·tini·connect 모두 태그가 가리키는 커밋으로 받는다 — BuildKit git context 가 검증한다(원칙 7) |
| zypper 재시도 | — | refresh 부터 install 까지 트랜잭션 전체 재시도 | SLE_BCI 미러가 패키지 다운로드 중에도 끊긴다. RPM 서명 검증은 매 시도마다 그대로 |
| `tini` · `connect-proxy` | apt 패키지 | 소스 빌드 | SLE_BCI 에 둘 다 없다. 기능을 빼지 않기 위해 빌드 |
| Go 툴체인 | 업스트림 pin | `GO_BUILDER_TAG` | stdlib CVE 해소 |
| 취약 모듈 | 그대로 | `GO_MODULE_UPGRADES` 로 강제 업그레이드 | |
| `BUILD_DATE` | 빌드 시각 | 고정값 | 빌드 재현성 |
| UI | node 빌드 | **동일** | Go embed 로 바이너리에 들어가 생략 불가 |

애플리케이션 코드 자체는 pinned 태그 그대로다 — 최소 diff 원칙.

### SLE 패키지 매핑

업스트림 apt 목록을 SLE_BCI 이름으로 옮겼다([docs/image-authoring/](../../docs/image-authoring/README.md) 참고).
목록 자체는 `source.build.env` 의 `RUNTIME_PACKAGES` 에 있다.

| ubuntu | SLE_BCI |
|---|---|
| `git` | `git-core` |
| `tzdata` | `timezone` |
| `gpg` · `gpg-agent` | `gpg2` |
| `openssh-client` | `openssh-clients` |
| `ca-certificates` | `ca-certificates` (동일) |
| `tini` | **없음** → 소스 빌드 |
| `connect-proxy` | **없음** → 소스 빌드 |

## 버전 관리

다음은 **자동 추적하지 않는다** — 사람이 업스트림 릴리스를 보고 `source.build.env` 를
고쳐 PR 을 여는 것 자체가 갱신 트리거다.

| 값 | 무엇 |
| --- | --- |
| `SOURCE_COMMIT` | argocd pinned commit |
| `HELM_VERSION` · `KUSTOMIZE_VERSION` · `GIT_LFS_VERSION` | 번들 도구 버전 — ldflags 로 박히고 `verify.sh` 가 확인한다 |
| `TINI_VERSION` · `SSH_CONNECT_VERSION` | SLE_BCI 에 없어 소스 빌드하는 컴포넌트 버전 — 빌드 인자가 아니라 기록이다 (`TINI_VERSION` 은 `verify.sh` 가 확인) |
| `HELM_COMMIT` · `KUSTOMIZE_COMMIT` · `GIT_LFS_COMMIT` · `TINI_COMMIT` · `SSH_CONNECT_COMMIT` | 실제로 받는 커밋 — `*_VERSION` 과 **항상 함께** 올린다. `git ls-remote <repo> 'refs/tags/<tag>' 'refs/tags/<tag>^{}'` 로 확인하고, annotated 태그면 `^{}` 쪽 커밋을 쓴다 |
| `NODE_BUILDER_TAG` | UI 빌더 Node 버전 — 업스트림 Dockerfile 의 pin 과 맞춘다 |

`GO_BUILDER_TAG`·`GO_MODULE_UPGRADES` 는 다르다 — 완전 수동이 아니라
`suggest-go-upgrades.py` 가 게이트 리포트에서 후보값을 산출해준다(아래 "다음 CVE 조치"
참고). 값 산출은 반자동이지만 반영은 여전히 사람이 PR 로 한다.

`cve-exceptions.json` 에 이 이미지를 대상으로 하는 예외는 없다 — 게이트를 통과한 것은
모두 버전을 올려 고친 결과다.

### 스캐너가 못 보는 것 — 번들 도구 자체의 보안 권고

번들 도구 **자체 코드**의 취약점은 스캐너가 그 바이너리의 main 모듈 버전을 알아야만
잡힌다. SBOM 에서 argocd·helm·kustomize 는 main 모듈 버전이 나오지만 git-lfs
(`github.com/git-lfs/git-lfs/v3`) 는 **버전이 비어 있다** — git-lfs 의 버전은 상수
(`config.Version`)라 ldflags 로 넣을 변수가 없다. 그래서 git-lfs 3.7.1 에 해당하는 HIGH
권고들(3.8.1 에서 수정)이 게이트에도 일일 재스캔에도 나타나지 않았고, 앞으로 나올 git-lfs
권고도 마찬가지로 보이지 않는다.

그러므로 **git-lfs 는 사람이 GitHub 보안 권고(`gh api repos/git-lfs/git-lfs/security-advisories`)를
직접 확인해야 한다** — 이미지를 다시 빌드할 때마다, 그리고 다른 번들 도구를 올릴 때도 SBOM
만 믿지 않는다.

**권장 점검 주기**: 게이트가 이 이미지의 차단 CVE 를 다시 보고할 때, 그리고 argo-cd
업스트림의 같은 라인 브랜치(`release-<SUPPORT_LINE>` 이후)가 `hack/tool-versions.sh` 의
번들 도구 버전을 올릴 때 — 업스트림이 쓰는 버전은 호환성이 확인된 버전이다.

**자체 빌드를 그만두는 조건**: argo-cd 공식 이미지(`quay.io/argoproj/argocd`)를 그대로
스캔했을 때 게이트를 통과하면 — 상위 태그 교체가 다시 가능해지므로 자체 빌드를 유지하는
것보다 항상 우선이다.

## 빌드·검증 방법

```sh
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

`cve-gate.md` 로 실효 C/H 0 확인. 커버리지 자가진단(`CoverageProbe`)이 `ok` 인지도
확인한다 — `none` 이면 findings 0건이 진짜 0건이 아니라 스캐너에 그 배포판 데이터가
없다는 뜻이다.

`verify.sh` 가 보는 것 — argocd 버전 문자열과 pinned commit, 업스트림 심볼릭 링크 9개와
argv[0] 디스패치(`argocd-repo-server --help` 가 repo-server 로 동작), 번들 도구 3개의 버전,
그리고 repo-server 가 맡기는 일을 실제로 시킨다 — `helm template` 으로 차트 렌더링,
`kustomize build` 로 generator 와 prefix 적용, git 저장소에서 `git lfs track` 후 커밋해
파일이 LFS 포인터로 저장되는지. 이어서 tini 버전·connect-proxy 실행 가능, git/gpg/ssh
존재, `/etc/gitconfig` 의 LFS 필터, `/app/config` 디렉토리 구조와 래퍼 스크립트. 그리고 argo-cd 차트의 repo-server init
컨테이너가 실제로 쓰는 `cp --update=none` 명령을 재현해 GNU coreutils 9.3+ 요구사항을
직접 확인한다 — 베이스 OS 를 바꿀 때 이 검사가 걸러준다.

**게이트 PASS 는 "동작한다" 를 증명하지 않는다.** 실제 기동은 Kubernetes API 가 필요해
스모크 범위 밖이다 — 배포 검증은 별도 절차를 따른다.

### 다음 CVE 조치 — Dockerfile 은 건드리지 않는다

버전도 모듈 목록도 Dockerfile 에 박혀 있지 않다. 새 차단 CVE 가 나오면 **`source.build.env`
한 곳만** 바뀐다.

```sh
# 1) 게이트 리포트에서 업그레이드 값을 산출한다 (손으로 찾지 않는다).
#    재빌드를 하는 김에 MEDIUM·LOW·등급 없음까지 함께 거둔다 (remediation-priority.md)
python3 scripts/build/suggest-go-upgrades.py --reports sbom-out/trivy-reports --image argocd \
  --min-severity UNKNOWN --apply --dry-run

# 2) --dry-run 을 빼고 --apply 로 반영한다. 출력된 GO_MODULE_UPGRADES= 줄을 손으로 붙여넣지
#    않는다 — 이번에 산출된 모듈만 담겨 있어 기존 pin 이 빠진다

# 3) 재빌드 — 게이트까지 한 번에 돈다
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

| 새 CVE 유형 | 바꾸는 값 |
|---|---|
| Go `stdlib` | `GO_BUILDER_TAG` |
| Go 모듈 | `GO_MODULE_UPGRADES` 에 `<module>@<version>` 추가 |
| OS 패키지 | `RUNTIME_BASE` 또는 `RUNTIME_PACKAGES` |
| 구성요소 새 릴리스 | 해당 `*_VERSION` 과 `*_COMMIT` (함께) |
| argocd 자체 (`github.com/argoproj/argo-cd/v3`) | `SOURCE_COMMIT`·`APP_VERSION` — `GO_MODULE_UPGRADES` 로는 움직일 수 없다 |

`GO_MODULE_UPGRADES` 는 argocd·helm·kustomize·git-lfs **네 프로젝트에 공통 적용**된다.
[go-mod-upgrade.sh](go-mod-upgrade.sh) 가 각 프로젝트의 의존성 그래프에 있는 것만 골라
적용하므로 목록 하나를 그대로 재사용한다 — `go get` 은 의존성에 없는 모듈도 `go.mod` 에
추가해버리기 때문에 필요한 필터다.

> 제안값은 CVE 요건의 **최소치**다. 모듈 간 제약으로 더 올려야 할 수 있다 — 빌드가
> `requires <module>@vX, not @vY` 로 실패하면 그 버전으로 올린다. 이미 목록에 있는 모듈을
> 올릴 때는 그 모듈의 `go.mod` 가 요구하는 다른 모듈도 함께 확인한다 — `x/crypto` 를 올리면
> 목록의 `x/text` 가 그 요구치 아래에 남을 수 있다.
>
> 수정 버전이 의사 버전(`v0.58.1-0.2026…-<커밋>`)으로만 나온 경우, 스크립트는 "pre-release
> 에서만 수정" 이라며 건너뛴다. 그 커밋 **이후에 태그된 안정 릴리스**가 있으면 그것으로
> 고칠 수 있다 — `gh api repos/<owner>/<repo>/compare/<커밋>...<태그>` 가 `ahead`·`behind_by: 0`
> 이면 그 태그가 커밋을 포함한다.
