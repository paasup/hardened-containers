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

- **상위 태그 교체 불가** — 이미 최신 릴리스다. 번들 도구도 각각 최신이고, 낡은 Go 는
  각 업스트림 프로젝트의 선택이라 버전을 올려도 바뀌지 않는다.
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
| helm 버전 | 업스트림 pin | 최신 | kustomize·git-lfs 는 pin 이 이미 최신이라 그대로 |
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
| `HELM_VERSION` · `KUSTOMIZE_VERSION` · `GIT_LFS_VERSION` | 번들 도구 버전 |
| `TINI_VERSION` · `SSH_CONNECT_VERSION` | SLE_BCI 에 없어 소스 빌드하는 컴포넌트 버전 |
| `NODE_BUILDER_TAG` | UI 빌더 Node 버전 — 업스트림 Dockerfile 의 pin 과 맞춘다 |

`GO_BUILDER_TAG`·`GO_MODULE_UPGRADES` 는 다르다 — 완전 수동이 아니라
`suggest-go-upgrades.py` 가 게이트 리포트에서 후보값을 산출해준다(아래 "다음 CVE 조치"
참고). 값 산출은 반자동이지만 반영은 여전히 사람이 PR 로 한다.

**권장 점검 주기**: 게이트가 이 이미지의 차단 CVE 를 다시 보고할 때, 또는
argo-cd·helm·kustomize·git-lfs 가 각각 새 릴리스에서 이 모듈들을 해소하면 — 상위 태그
교체가 다시 가능해지므로 자체 빌드를 유지하는 것보다 항상 우선이다.

## 빌드·검증 방법

```sh
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

`cve-gate.md` 로 실효 C/H 0 확인. 커버리지 자가진단(`CoverageProbe`)이 `ok` 인지도
확인한다 — `none` 이면 findings 0건이 진짜 0건이 아니라 스캐너에 그 배포판 데이터가
없다는 뜻이다.

`verify.sh` 가 보는 것 — argocd 버전 문자열, 업스트림 심볼릭 링크 9개, 번들 도구 3개의
버전, tini·connect-proxy 실행 가능, git/gpg/ssh 존재, `/etc/gitconfig` 의 LFS 필터,
`/app/config` 디렉토리 구조와 래퍼 스크립트. 그리고 argo-cd 차트의 repo-server init
컨테이너가 실제로 쓰는 `cp --update=none` 명령을 재현해 GNU coreutils 9.3+ 요구사항을
직접 확인한다 — 베이스 OS 를 바꿀 때 이 검사가 걸러준다.

**게이트 PASS 는 "동작한다" 를 증명하지 않는다.** 실제 기동은 Kubernetes API 가 필요해
스모크 범위 밖이다 — 배포 검증은 별도 절차를 따른다.

### 다음 CVE 조치 — Dockerfile 은 건드리지 않는다

버전도 모듈 목록도 Dockerfile 에 박혀 있지 않다. 새 차단 CVE 가 나오면 **`source.build.env`
한 곳만** 바뀐다.

```sh
# 1) 게이트 리포트에서 업그레이드 값을 산출한다 (손으로 찾지 않는다)
python3 scripts/build/suggest-go-upgrades.py --reports sbom-out/trivy-reports --image argocd

# 2) 출력된 GO_MODULE_UPGRADES / GO_BUILDER_TAG 를 source.build.env 에 반영

# 3) 재빌드 — 게이트까지 한 번에 돈다
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

| 새 CVE 유형 | 바꾸는 값 |
|---|---|
| Go `stdlib` | `GO_BUILDER_TAG` |
| Go 모듈 | `GO_MODULE_UPGRADES` 에 `<module>@<version>` 추가 |
| OS 패키지 | `RUNTIME_BASE` 또는 `RUNTIME_PACKAGES` |
| 구성요소 새 릴리스 | 해당 `*_VERSION` |

`GO_MODULE_UPGRADES` 는 argocd·helm·kustomize·git-lfs **네 프로젝트에 공통 적용**된다.
[go-mod-upgrade.sh](go-mod-upgrade.sh) 가 각 프로젝트의 의존성 그래프에 있는 것만 골라
적용하므로 목록 하나를 그대로 재사용한다 — `go get` 은 의존성에 없는 모듈도 `go.mod` 에
추가해버리기 때문에 필요한 필터다.

> 제안값은 CVE 요건의 **최소치**다. 모듈 간 제약으로 더 올려야 할 수 있다 — 빌드가
> `requires <module>@vX, not @vY` 로 실패하면 그 버전으로 올린다.
