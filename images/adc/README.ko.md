# adc — 자체 빌드

[English](README.md) · 한국어

adc(APISIX/API7 관리 CLI, apisix-ingress-controller 의 사이드카) 를 업스트림 소스에서
SUSE BCI 위에 직접 빌드한다. apisix-ingress-controller 배포에서 사이드카 컨테이너로
쓰인다.

> 이 이미지는 api7/adc 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 후보 비교·받아들인 비용은 [ADR 0004](../../docs/decisions/0004-adc-self-build.md),
이미지 선정 규칙과 빌드 프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가
갖는다.

## 왜 자체 빌드하는가

업스트림은 distroless 이미지로 전환해 벤더 등급 기준 CRITICAL/HIGH 를 0건으로 줄였지만,
이 값은 벤더 등급만 반영한 결과다. 게이트는 `max(벤더, NVD)`로 재평가하는데, 이렇게
다시 보면 OS 패키지(glibc) CVE 몇 건이 실효 CRITICAL/HIGH 로 여전히 차단한다 —
배포판이 "영향 있음, 수정 버전 없음"으로 영구 고정해둔 사례라 상위 태그를 올려도
해소되지 않는다.

사전 검증 결과, 동일한 의존성을 SUSE BCI 환경(SUSE BCI + Node 패키지)에 올렸을 때는
이 OS 취약점들이 발생하지 않는다 — 배포판을 바꾸면 벤더 판정이 달라져 베이스 OS
교체만으로 해소되는 유형이다.

이 유형은 소스를 여러 모듈로 컴파일하는 자체 빌드보다 단순하다 — 애플리케이션 코드
(main.cjs 번들)는 업스트림과 100% 동일하고, 빌더 스테이지도 그대로 재사용한다. 바뀌는
건 최종 런타임 스테이지의 베이스 한 줄뿐이다. `cnpg-postgresql`(OS 패키지 재설치형)과
같은 패턴이다.

## 업스트림과의 차이

업스트림 Dockerfile(`libs/tools/src/docker/Dockerfile`, 태그 `v0.29.0`)은 2단계다:

```dockerfile
FROM node:lts-bookworm-slim AS builder      # pnpm+nx 로 main.cjs 하나로 번들
...
FROM gcr.io/distroless/nodejs24-debian13:nonroot
COPY --from=builder /build/dist/apps/cli/main.cjs .
ENTRYPOINT [ "/nodejs/bin/node", "main.cjs" ]
```

빌더 스테이지(pnpm/nx 빌드)는 정책 대상이 아니고([image-authoring/](../../docs/image-authoring/README.md)
원칙 2 — 빌더 스테이지는 스캔·배포 대상이 아니므로 베이스 OS 정책이 적용되지
않는다), 업스트림 그대로 재사용한다.

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 | `gcr.io/distroless/nodejs24-debian13:nonroot` | `registry.suse.com/bci/bci-base:15.7` + `zypper install nodejs24` | OS 패키지 CVE 회피, 이미지 간 베이스 OS 통일 (같은 Node 24 메이저 유지 — SUSE 표준 패키지라 distroless 전용 `-devel` 문제가 없다) |
| 엔트리포인트 경로 | `/nodejs/bin/node` | `/usr/bin/node` | zypper 가 설치하는 경로 |
| non-root 사용자 | distroless `:nonroot` 태그로 기본 적용 | 시스템 계정 `adc` 를 명시적으로 생성 | `bci-base` 에는 nonroot 변형 태그가 없다 |
| 빌더 스테이지 | `node:lts-bookworm-slim` (pnpm+nx 빌드) | 동일 — 정책 대상 아님 | 최종 스테이지만 스캔·배포 대상 |
| 애플리케이션 코드 | `main.cjs` 번들 | 동일 | 빌더 스테이지를 그대로 재사용하므로 diff 가 최소다 |

빌드 시간은 2분 이내다(대부분 pnpm install + nx build 시간).

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=adc BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=adc BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**
`verify.sh`는 non-root 실행 여부, `--version` 출력, `--help`의 커맨드 목록(dump/diff/
sync)을 확인한다 — **adc 는 실제 APISIX/API7 백엔드 접속이 필요한 명령이 대부분이라
그 연동 자체는 이 스모크 범위 밖**이다. 배포 검증은 별도 절차를 따른다.

빌드가 끝나면 `<OUT_DIR>/cve-gate.md`(요약)와 `cve-gate.json`이 남는다. 확인할 것은
둘이다: 실효 CRITICAL/HIGH 가 `0/0`인지, 그리고 `CoverageProbe`(SBOM 센티널 패키지
재스캔으로 trivy 가 이 베이스를 실제로 커버하는지 자가진단한 값)가 `ok`인지 —
`none`이면 findings 0 이 진짜 0 이 아니라 스캔이 이 베이스를 못 읽었다는 뜻이므로
게이트가 통과 판정을 보류한다.

### 소스·버전 관리

| 항목 | 값 |
| --- | --- |
| 소스 | `https://github.com/api7/adc.git` |
| pinned commit | `source.build.env` 의 `SOURCE_COMMIT` — `v0.29.0` 태그(lightweight, peeled 커밋 없음)가 가리키는 실제 커밋 |
| 빌더 | 업스트림과 동일한 `node:lts-bookworm-slim` — 정책 대상 아님(빌더 스테이지) |
| 최종 베이스 | `registry.suse.com/bci/bci-base:15.7` + `nodejs24` |

`SOURCE_COMMIT`은 **자동 추적하지 않는다.** 다른 자체 빌드 이미지와 동일하게, 사람이
업스트림 새 릴리스(또는 위 CVE 들을 이미 해소한 버전)를 보고 `source.build.env`를
고쳐 PR을 여는 것 자체가 갱신 트리거다.

**권장 점검 주기**: 게이트가 이 이미지의 차단 CVE를 다시 보고할 때, 또는 `api7/adc`가
다음 릴리스를 내놓았을 때 — 그 릴리스가 위 CVE 들을 이미 해소했다면, 자체 빌드를
유지하는 것보다 그쪽으로 갈아타는 것이 항상 우선이다.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 빌더 스테이지(업스트림 그대로) + SUSE BCI 최종 스테이지 |
| `source.build.env` | pinned commit·버전(`BUILD_ARGS`에 나열한 이름만 `--build-arg` 로 전달됨) |
| `verify.sh` | 기능 검증 — non-root·버전·--help 커맨드 확인 |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
docker.io/paasup/adc:0.29.0-security-hardened-20260812
                      └ app ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

같은 앱 버전이라도 재빌드 시점마다 베이스 패키지 상태가 다를 수 있다 — 롤링 태그를
피하고 빌드일을 태그에 포함한다.

## 아직 안 한 것 — 배포 검증

게이트 PASS·기능 스모크테스트(버전+help)까지만 확인했다. **apisix-ingress-controller
와 함께 실제 APISIX/API7 백엔드에 접속해 dump/diff/sync 가 정상 동작하는지는 아직
확인하지 않았다** — 별도 배포 검증 절차로 반드시 수행할 것(apisix-ingress-controller
자체 빌드는 같은 절차로 이미 배포 검증을 마쳤다 — 같은 방식으로 진행한다).
