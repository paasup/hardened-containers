# kyverno — 자체 빌드

[English](README.md) · 한국어

kyverno 메인 컨트롤러 바이너리, 업스트림 소스에서 직접 컴파일한 것. 어느 차트가 이
이미지를 쓰는지, 태그가 어떻게 배포되는지는 이 레포가 모른다 — 이미지를 어떻게
만드는지만 다룬다.

> 이 이미지는 kyverno의 **비공식 재빌드**다. 업스트림 프로젝트와 제휴·보증·지원
> 관계가 없다. 상표·라이선스 관련 고지는 [NOTICE](../../NOTICE) 참고.

결정 배경·비교한 후보·감수한 비용은
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)에 있다. 이미지 선택
규칙과 빌드 프레임워크 자체는 [image-authoring/](../../docs/image-authoring/README.md)
가 소유한다.

## 왜 우리가 직접 빌드하는가

kyverno는 Dockerfile이 없다 — 7개 이미지 전부 `ko`가 `.ko.yaml`의
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`로 빌드한다. 이 값은 **다이제스트가
아니라 플로팅 태그**이고, 그 이미지 자체가 특정 Alpine 릴리스를 고정하지 않아 기본으로
**Alpine의 롤링 `edge` 브랜치**를 추적한다. trivy의 공식 Alpine 보안 DB는 번호 붙은
정식 릴리스만 다루고 `edge`는 다루지 않는다.

추측이 아니라 실측으로 확인했다:

- `.ko.yaml`은 kyverno v1.18.2(정상 스캔)와 v1.19.0(차단)에서 바이트 단위로 동일하다 —
  차이는 kyverno 저장소가 아니라 그 빌드 시점에 플로팅 태그가 무엇을 가리켰는지뿐이다.
- `ghcr.io/wolfi-dev/static:alpine`을 직접 받아 `/etc/os-release`를 읽으면
  `VERSION_ID=3.25.0_alpha20260805` — 손상된 값이 아니라 진짜 Alpine edge 사전 릴리스
  마커다.
- 이 이미지는 매일 재빌드되는데도(wolfi-dev/tools의 `release.yaml`, 01:00 UTC cron)
  그 `VERSION_ID`는 7일간(2026-08-20~08-27) 그대로였다 — 패키지는 매일 갱신되지만
  사전 릴리스 버전 마커 자체는 Alpine 코어가 올릴 때만 바뀐다.
- 이 저장소의 커버리지 자가진단(`scripts/gate/scan-image.sh`의 프로브, dip-catalog의
  `sbom.yml`이 쓰는 것과 같은 기법)을 그 베이스 이미지에 직접 돌려도 여전히
  `CoverageProbe: none`이다.

apko 설정에 Alpine 브랜치 고정이 없어 이 베이스는 계속 `edge`를 쫓는다 — 즉 "다음
kyverno 릴리스를 기다리면 풀린다"는 보장이 없다. 새 태그로 옮겨도(v1.19.0이 이미
최신) 안 풀리고, 베이스만 바꿔도(모든 버전이 같은 미고정 베이스를 참조) 안 풀린다.
직접 컴파일이 유일한 즉답이다.

원인이 OS 패키지가 아니라 베이스 이미지 자체이므로(kyverno 바이너리는 정적 링크,
`CGO_ENABLED=0`), 직접 컴파일하면 완전히 해소된다 — 정확한 CVE 목록·건수는 매 빌드마다
`scan-image.sh`/`image-gate.py`가 다시 측정한다("빌드와 검증" 참고).

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 이미지 | `ghcr.io/wolfi-dev/static:alpine`(ko 기본값, 미고정 Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | 이 저장소는 SUSE BCI만 쓴다(rule 2). 바이너리가 정적 링크(`CGO_ENABLED=0`)라 셸·패키지 매니저가 필요 없다 |
| `golang.org/x/mod` | go.mod에 핀된 버전 | `v0.40.0`으로 강제 업그레이드 | CVE-2026-56864, CVE-2026-56865 — 실효 등급 HIGH |
| 진입점 경로 | `ko`의 내부 경로(`/ko-app/kyverno`류) | `/app/kyverno` | kyverno 차트가 `command:`를 하드코딩하지 않고 `args:`만 쓰므로 차트 동작에 영향 없다 |

`SOURCE_COMMIT`과 `GO_MODULE_UPGRADES`는 자동 추적되지 않는다 — 새 kyverno 태그를
확인하고 `source.build.env`를 고쳐 PR을 여는 사람이 곧 갱신 트리거다. 이 문제는
kyverno의 릴리스가 아니라 wolfi-dev 쪽 베이스 문제이므로, "업스트림이 다음 버전에서
고쳤을 것"이라는 통상적인 재검토 조건이 적용되지 않는다 — `ghcr.io/wolfi-dev/static:alpine`이
번호 붙은, trivy가 커버하는 Alpine 릴리스로 안정적으로 고정되는지가 재검토 조건이다.

현재 `cve-exceptions.json`에 이 이미지를 겨냥한 예외는 없다 — 위 표의 강제 업그레이드
하나로 게이트가 통과한다.

## 빌드와 검증

```sh
IMAGE=kyverno BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

순서: 빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.
`verify.sh`는 바이너리가 존재·실행 가능한지, nonroot(`65532:65532`)로 도는지,
`--help`가 정상 종료(0)하는지를 확인한다. 실제 컨트롤러 기동은 Kubernetes API 서버
연결이 필요해 이 스모크 테스트 범위 밖이다 — 배포 검증은 별도 절차.

**빌드 중 실측한 함정 — Go 모듈 버전 자가 스탬핑 오탐**: 처음에는 kyverno 자체의
`pkg/version.Hash()`/`Time()`(Go의 `runtime/debug.ReadBuildInfo` VCS 스탬핑을 읽음)을
살리려고 git ADD에 `--keep-git-dir=true`를 썼다. 그런데 BuildKit의 git 컨텍스트는
지정한 커밋만 체크아웃하고 태그 ref는 안 가져와서, 컨테이너 안 `git describe`가
`v1.19.0` 태그를 못 찾았고 Go가 메인 모듈 버전을 `v0.0.0-20260820085256-ee97ce09538b`
같은 낮은 pseudo-version으로 자동 스탬핑했다. trivy의 Go 바이너리 스캔은 이 pseudo
버전을 기준으로 semver 비교를 하므로, `github.com/kyverno/kyverno` 자체에 대해 과거
버전(1.17.0 이전)에서 이미 고쳐진 CVE까지 전부 "아직 미해결"로 오판해 **15건이 차단**됐다
(실측 — `CVE-2026-22039` 등, 전부 fixed version이 1.10.x~1.17.0 사이였다). `.git`
디렉터리를 남기지 않는 것(`docs/image-authoring/builder-languages.md`의 Go 절이 이미
권장하는 방식 — "우리는 `.git` 없이 빌드하므로 `SOURCE_COMMIT`을 명시적으로 전달한다")
으로 되돌리자 **진짜 CVE 2건**(`golang.org/x/mod`)만 남았다. 이 저장소의 다른 Go 자체
빌드가 전부 `.git`을 안 남기는 이유가 바로 이거였다 — kyverno에서 편의상 벗어났다가
직접 걸렸다. `pkg/version.Hash()`/`Time()`은 그 대가로 `"---"`를 반환하지만,
`pkg/version.BuildVersion`(ldflags로 설정, `verify.sh`와 차트에 보이는 버전 문자열이
실제로 쓰는 값)에는 영향이 없다.

`cve-gate.md`에서 결과를 읽는다. 게이트가 통과해도 `trivy-reports/*.json`의
`CoverageProbe`가 `ok`인지 확인한다 — `none`이면 0건이 측정 결과가 아니라 그 배포판
데이터 부재다(이번 건은 정확히 이 커버리지 확보가 목적이었다 — 실측: `sles 15.7`,
`CoverageProbe: ok`).

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | 핀된 커밋, 버전, 빌더 이미지 태그, 취약 모듈 최소 버전. `BUILD_ARGS`에 나열된 이름만 `--build-arg`로 전달됨 |
| `verify.sh` | 기능 검증. 호스트에서 bash로 실행되며 `docker run --entrypoint bash`로 게스트 셸 스크립트를 주입한다(`bci-micro`엔 bash·coreutils 있음) |

베이스 변형이 하나뿐이라 파일명이 `source.*`로 고정돼 있다.

### 태그

```
<registry>/kyverno:v1.19.0-security-hardened-20260827
                    └ app  ┘└ slug  ┘└hardened┘└ 빌드 날짜 ┘
```
