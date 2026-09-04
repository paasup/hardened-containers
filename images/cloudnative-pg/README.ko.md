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

`SOURCE_COMMIT` 은 **자동 추적하지 않는다.** `cnpg-postgresql` 의 PGDG 버전처럼 사람이
업스트림 유지보수 브랜치(또는 그다음 패치 릴리스가 나오면 그 태그)를 보고
`source.build.env` 를 고쳐 PR 을 여는 것 자체가 갱신 트리거다.

`GO_MODULE_UPGRADES` 는 **평소 비어 있다.** 이 이미지는 유지보수 브랜치 HEAD 를 컴파일해
업스트림이 이미 백포트한 수정을 그대로 받으므로 강제 업그레이드할 것이 없었다. 그래도 키
자체는 선언해 둔다 — `suggest-go-upgrades.py --apply` 는 **없는 키를 새로 만들지 않기**
때문에, 선언이 없으면 업스트림이 백포트하지 않은 모듈 CVE 가 왔을 때 이 이미지만 자동
수정에서 조용히 빠진다(실제로 2026-09-03 CVE-2026-84304 이 그 상황이었다).

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

`verify.sh` 는 `manager version` 출력에 pinned commit 이 실제로 반영됐는지(ldflags 주입
확인), 이미지 `Config.User` 가 `65532:65532`(nonroot)인지, `--help` 가 정상 종료하는지를
확인한다 — 실제 컨트롤러 기동(k8s API 필요)은 이 스모크 테스트 범위 밖이다. 실제 배포
검증은 별도 절차를 따른다.

### 소스·버전 관리

| 항목 | 값 |
| --- | --- |
| 소스 | `https://github.com/cloudnative-pg/cloudnative-pg.git` |
| pinned commit | `source.build.env` 의 `SOURCE_COMMIT` (업스트림 유지보수 브랜치) |
| 빌더 | 공식 `golang` 이미지 (`source.build.env` 의 `GO_BUILDER_TAG`, go.mod 요구 버전과 일치) |
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
docker.io/paasup/cloudnative-pg:1.30.0-security-hardened-20260730
                                 └ app ─┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

빌드일(`20260730`)은 예시다 — 실제 값은 빌드 시점의 날짜로 채워진다.
