# cleanup-controller — 자체 빌드

[English](README.md) · 한국어

kyverno cleanup-controller 바이너리, 업스트림 소스에서 직접 컴파일한 것. 어느 차트가
이 이미지를 쓰는지, 태그가 어떻게 배포되는지는 이 레포가 모른다 — 이미지를 어떻게
만드는지만 다룬다.

> 이 이미지는 kyverno의 **비공식 재빌드**다. 업스트림 프로젝트와 제휴·보증·지원
> 관계가 없다. 상표·라이선스 관련 고지는 [NOTICE](../../NOTICE) 참고.

결정 배경·비교한 후보·감수한 비용은
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)에 있다. 이미지 선택
규칙과 빌드 프레임워크 자체는 [image-authoring/](../../docs/image-authoring/README.md)
가 소유한다.

## 왜 우리가 직접 빌드하는가

[images/kyverno/](../kyverno/README.ko.md)와 같은 원인이다 — kyverno가 배포하는 7개
이미지 전부 `ko`가 `.ko.yaml`의 `defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`로
빌드하는데, 이 값은 다이제스트가 아니라 플로팅 태그이고 Alpine 버전 고정이 없어
trivy가 스캔 못 하는 롤링 `edge` 브랜치를 추적한다. 이는 베이스 이미지 일반에 대해
확인된 것이지 이 바이너리 고유의 문제가 아니다 — 조사 배경은 ADR 0009, 실측치는
`images/kyverno/README.ko.md` 참고. 바이너리별 문제가 아니므로 바이너리마다
재조사하지 않는다.

원인이 OS 패키지가 아니라 베이스 이미지 자체이므로(이 바이너리는 정적 링크,
`CGO_ENABLED=0`), 직접 컴파일하면 완전히 해소된다 — 정확한 CVE 목록·건수는 매 빌드마다
`scan-image.sh`/`image-gate.py`가 다시 측정한다("빌드와 검증" 참고).

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 이미지 | `ghcr.io/wolfi-dev/static:alpine`(ko 기본값, 미고정 Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | 이 저장소는 SUSE BCI만 쓴다(rule 2). 바이너리가 정적 링크(`CGO_ENABLED=0`)라 셸·패키지 매니저가 필요 없다 |
| `golang.org/x/mod` | go.mod에 핀된 버전 | `v0.40.0`으로 강제 업그레이드 | CVE-2026-56864, CVE-2026-56865 — 실효 등급 HIGH (`images/kyverno/`와 go.mod을 공유하므로 동일한 발견) |
| 진입점 경로 | `ko`의 내부 경로(`/ko-app/cleanup-controller`류) | `/app/cleanup-controller` | kyverno 차트가 `command:`를 하드코딩하지 않고 `args:`만 쓰므로 차트 동작에 영향 없다 |

`SOURCE_COMMIT`과 `GO_MODULE_UPGRADES`는 자동 추적되지 않는다 — 새 kyverno 태그를
확인하고 `source.build.env`를 고쳐 PR을 여는 사람이 곧 갱신 트리거다. 이 문제는
kyverno의 릴리스가 아니라 wolfi-dev 쪽 베이스 문제이므로, "업스트림이 다음 버전에서
고쳤을 것"이라는 통상적인 재검토 조건이 적용되지 않는다 — `ghcr.io/wolfi-dev/static:alpine`이
번호 붙은, trivy가 커버하는 Alpine 릴리스로 안정적으로 고정되는지가 재검토 조건이다.

현재 `cve-exceptions.json`에 이 이미지를 겨냥한 예외는 없다 — 위 표의 강제 업그레이드
하나로 게이트가 통과한다.

## 빌드와 검증

```sh
IMAGE=cleanup-controller BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

순서: 빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.
`verify.sh`는 바이너리가 존재·실행 가능한지, nonroot(`65532:65532`)로 도는지,
`--help`가 정상 종료(0)하는지를 확인한다. 실제 컨트롤러 기동은 Kubernetes API 서버
연결이 필요해 이 스모크 테스트 범위 밖이다 — 배포 검증은 별도 절차.

**`--keep-git-dir=true` 함정**: [images/kyverno/README.ko.md](../kyverno/README.ko.md)의
"빌드와 검증" 절과 같은 원인이다 — git ADD에 `.git`을 남기면 BuildKit의 git 컨텍스트가
핀된 커밋 체크아웃에서 태그 ref를 안 가져오므로, Go의 VCS 빌드 정보 스탬핑이 `v1.19.0`
태그를 못 찾아 낮은 pseudo-version을 스탬핑하고, trivy가 이를 기준으로
`github.com/kyverno/kyverno`의 과거 CVE를 전부 미해결로 오판한다. 이 Dockerfile은
처음부터 `--keep-git-dir=true`를 쓰지 않는다(여기서 재발견한 게 아니다) —
`pkg/version.Hash()`/`Time()`은 그 대가로 `"---"`를 반환하지만,
`pkg/version.BuildVersion`(ldflags로 설정, `verify.sh`와 차트에 보이는 버전 문자열이
실제로 쓰는 값)에는 영향이 없다.

`cve-gate.md`에서 결과를 읽는다. 게이트가 통과해도 `trivy-reports/*.json`의
`CoverageProbe`가 `ok`인지 확인한다 — `none`이면 0건이 측정 결과가 아니라 그 배포판
데이터 부재다.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | 핀된 커밋, 버전, 빌더 이미지 태그, 취약 모듈 최소 버전. `BUILD_ARGS`에 나열된 이름만 `--build-arg`로 전달됨 |
| `verify.sh` | 기능 검증. 호스트에서 bash로 실행되며 `docker run --entrypoint bash`로 게스트 셸 스크립트를 주입한다(`bci-micro`엔 bash·coreutils 있음) |

베이스 변형이 하나뿐이라 파일명이 `source.*`로 고정돼 있다.

### 태그

```
<registry>/cleanup-controller:v1.19.0-security-hardened-20260827
                               └ app  ┘└ slug  ┘└hardened┘└ 빌드 날짜 ┘
```
