# cloudnative-pg — CloudNativePG 오퍼레이터 자체 빌드

[English](README.md) · 한국어

CNPG 오퍼레이터(컨트롤러) 이미지를 업스트림 소스에서 직접 컴파일한다.

> 이 이미지는 CloudNativePG 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 받아들인 비용은
[ADR 0002](../../docs/decisions/0002-cloudnative-pg-operator-self-build.md), 신규 자체
빌드 이미지 추가 절차 전반은 [docs/image-authoring/](../../docs/image-authoring/README.md) 가
갖는다.

## 왜 자체 빌드하는가 — 그리고 왜 `cnpg-postgresql` 과 다른 방법인가

업스트림 배포 이미지가 게이트에서 차단하는 CVE 는 OS 패키지가 아니라 바이너리에 정적
링크된 Go 모듈 버전이 원인이다. 배포 이미지 베이스가 distroless(OS 패키지 사실상 0개)라
**베이스 OS 를 바꾸는 것만으로는 고쳐지지 않는다** — 소스를 다시 컴파일해야 CVE 가
포함된 모듈 버전 자체가 바뀐다. 자체 빌드(소스 컴파일)만 유효한 대응이다.

`cnpg-postgresql`(OS 베이스 교체 + zypper 패치)과 성격이 다르지만, **오케스트레이션은
동일한 [scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh)
하나를 공유한다.** 이 이미지가 그 스크립트의 계약(`build.env` 가 `DOCKERFILE`·`TARGET`·
`BUILD_ARGS`·`APP_VERSION` 선언, `verify.sh` 가 `VERIFY-OK` 로 종료)만 지키면, 이미지
종류(OS 패키지 설치형 vs 소스 컴파일형)는 스크립트가 몰라도 된다 — 근거는
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 빌드 방식 | goreleaser 로 사전 빌드된 바이너리를 Dockerfile 이 COPY 만 함 | `go build` 로 소스를 Dockerfile 안에서 직접 컴파일 | CVE 원인이 정적 링크된 Go 모듈 버전이라, 사전 빌드된 바이너리를 그대로 쓰면 해소되지 않는다 — 다시 컴파일해야 한다 |
| 아키텍처 파일 배치 | 멀티아치 바이너리 + 심볼릭 링크(`manager_amd64`/`manager_arm64`) | 단일 아키텍처 바이너리를 `/manager` 와 `/operator/manager_amd64` 두 경로에 직접 COPY | 오퍼레이터가 런타임에 `operator/manager_<GOARCH>` 파일 존재로 "가용 아키텍처" 목록을 만든다 — 이 파일이 없으면 `invalid architecture` 오류로 리컨실이 실패한다. 심볼릭 링크 자리를 동등한 파일 배치로 대체해 같은 효과를 낸다 |
| 최종 런타임 베이스 | `gcr.io/distroless/static-debian13:nonroot` | `registry.suse.com/bci/bci-micro` | 이 레포가 다루는 자체 빌드 이미지는 SUSE BCI 하나로 통일한다([ADR 0001](../../docs/decisions/0001-cnpg-postgresql-image.md)) |
| nonroot 계정 | 베이스 이미지가 미리 제공 | Dockerfile 이 `/etc/passwd`·`/etc/group` 에 직접 추가 | `bci-micro` 는 `bci-base` 와 달리 nonroot(uid 65532) 계정이 없다 |

빌더 스테이지(Go 컴파일)는 공식 `golang` 이미지를 그대로 쓴다 — 최종 이미지에 남는 것이
아니라 컴파일 산출물만 최종 스테이지로 넘어오므로 스캔·정책 대상이 아니다.

`SOURCE_COMMIT` 은 **자동 추적하지 않는다.** 현재 핀은 업스트림 릴리스 태그 `v1.30.1` 이
가리키는 커밋이고, `APP_VERSION` 은 그 태그와 같은 값이다 — `APP_VERSION` 이 ldflags 로
바이너리의 보고 버전에 주입되므로 둘은 항상 함께 옮긴다(`verify.sh` 는 보고 버전이
`APP_VERSION` 인지만 확인할 뿐, 커밋과의 짝은 확인하지 못한다). `cnpg-postgresql` 의
PGDG 버전처럼 사람이 다음 패치 릴리스 태그를 `git ls-remote --tags` 로 확인해 `source.build.env` 를 고쳐 PR 을 여는 것 자체가 갱신
트리거다. 릴리스 태그가 아직 담지 않은 수정이 필요할 때만 유지보수 브랜치 커밋으로
되돌아간다([ADR 0002](../../docs/decisions/0002-cloudnative-pg-operator-self-build.md)) —
그 경우 `APP_VERSION` 은 그 커밋이 아직 어떤 릴리스와도 같지 않다는 점을 숨기지 않도록
고른다.

`GO_MODULE_UPGRADES` 는 **릴리스 태그가 아직 담지 못한 수정만** 채운다 — 핀한 릴리스의
`go.mod` 가 이미 수정 버전을 요구하면 해당 항목은 지운다. `GO_BUILDER_TAG` 는 `go.mod` 요구
버전 이상에서 stdlib CVE 수정 버전까지 올린다. `v1.30.0` 이후
유지보수 브랜치 커밋을 핀하던 동안 강제한 `google.golang.org/grpc@v1.83.1`(2026-09-03
CVE-2026-84304)은 `v1.30.1` 의 `go.mod` 가 grpc `v1.84.0` 을 요구하므로 제거했다. 2026-11-17
`v1.30.1` 빌드 스캔에서 이 자체 빌드가 **실제로 고친** CVE 는 다음과 같다(이 이미지에 등록된
예외는 없다).

| 핀 | 해소한 CVE |
| --- | --- |
| `GO_MODULE_UPGRADES="golang.org/x/net@v0.62.0"` (`v1.30.1` 은 `v0.58.0`) | HIGH CVE-2026-78661 · CVE-2026-78669, MEDIUM CVE-2026-78659 · CVE-2026-78660 · CVE-2026-78663 · CVE-2026-97032 · CVE-2026-97045 |
| `GO_BUILDER_TAG=1.26.11-trixie` (기존 `1.26.6`) | stdlib HIGH CVE-2026-111943 · CVE-2026-78667 · CVE-2026-78669 · CVE-2026-97031, MEDIUM 9건, LOW CVE-2026-56857, 미평가 CVE-2026-97054 |

`suggest-go-upgrades.py` 는 HIGH 이상만 보고 `1.26.10` 을 제안했다. 미평가
CVE-2026-97054 는 `1.26.11` 에서만 고쳐지고, 수정 버전이 있는 미평가 CVE 는 처분 대상이므로
([remediation-priority.md](../../docs/image-authoring/remediation-priority.md)) 한 패치 더
올렸다. 키는 비어 있을 때도 선언해 둔다 — `suggest-go-upgrades.py --apply` 는 **없는 키를
새로 만들지 않기** 때문에, 선언이 없으면 이 이미지만 자동 수정에서 조용히 빠진다.

**권장 점검 주기**: 게이트가 이 이미지의 차단 CVE 를 다시 보고할 때, 또는 업스트림이 새
패치 릴리스를 내놓았을 때 — 그 릴리스가 위 CVE 들을 이미 해소했다면, 자체 빌드를
유지하는 것보다 그쪽으로 갈아타는 것이 항상 우선이다.

## 빌드·검증

```sh
# 로컬 빌드 (push 없음)
IMAGE=cloudnative-pg BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=cloudnative-pg BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**
결과는 `/tmp/out/cve-gate.md` 에 실효 C/H 요약으로 남는다. 게이트가 PASS 여도
`/tmp/out/trivy-reports/*.json` 의 `CoverageProbe` 가 `ok` 인지 함께 확인한다 — `none`
이면 findings 0 건이 진짜 0 건이 아니라 스캐너에 그 배포판 데이터가 없다는 뜻이다.

`verify.sh` 는 `manager version` 출력에 pinned commit 과 `APP_VERSION` 이 실제로
반영됐는지(ldflags 주입 확인), 이미지 `Config.User` 가 `65532:65532`(nonroot)인지,
`--help` 가 정상 종료하는지를 확인한다 — 실제 컨트롤러 기동(k8s API 필요)은 이 스모크 테스트 범위 밖이다. 실제 배포
검증은 별도 절차를 따른다.

### 소스·버전 관리

| 항목 | 값 |
| --- | --- |
| 소스 | `https://github.com/cloudnative-pg/cloudnative-pg.git` |
| pinned commit | `source.build.env` 의 `SOURCE_COMMIT` — 업스트림 릴리스 태그(`v${APP_VERSION}`)가 가리키는 커밋. **자동 추적하지 않음** |
| 강제 모듈 업그레이드 | `source.build.env` 의 `GO_MODULE_UPGRADES` — `suggest-go-upgrades.py` 로 도출. 핀이 릴리스를 앞서는 동안만 값이 있다 |
| 빌더 | 공식 `golang` 이미지 (`source.build.env` 의 `GO_BUILDER_TAG`, go.mod 요구 버전 이상 — `suggest-go-upgrades.py` 로 도출) |
| 최종 베이스 | `registry.suse.com/bci/bci-micro` |

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | pinned commit·버전·빌더 이미지 태그. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 기능 검증. 호스트에서 bash 로 실행되며 직접 `docker run --entrypoint /manager` 를 호출한다(게스트 스크립트 주입 방식보다 상위 호환 — 최종 이미지에 셸이 없는 경우에도 그대로 동작한다) |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다 — `cnpg-postgresql` 처럼
변종이 늘면 `<variant>.Dockerfile`/`<variant>.build.env` 로 분기한다.

### 태그

```
docker.io/paasup/cloudnative-pg:1.30.1-security-hardened-20260730
                                 └ app ─┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

빌드일(`20260730`)은 예시다 — 실제 값은 빌드 시점의 날짜로 채워진다.
