# background-controller — 자체 빌드

[English](README.md) · 한국어

kyverno background-controller 바이너리, 업스트림 소스에서 직접 컴파일한 것. 어느
차트가 이 이미지를 쓰는지, 태그가 어떻게 배포되는지는 이 레포가 모른다 — 이미지를
어떻게 만드는지만 다룬다.

> 이 이미지는 kyverno의 **비공식 재빌드**다. 업스트림 프로젝트와 제휴·보증·지원
> 관계가 없다. 상표·라이선스 관련 고지는 [NOTICE](../../NOTICE) 참고.

결정 배경·비교한 후보·감수한 비용은
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)에 있다 — kyverno 7개
이미지 전체를 하나의 결정으로 다루며, 이 이미지도 그중 하나다. 이미지 선택 규칙과
빌드 프레임워크 자체는 [image-authoring/](../../docs/image-authoring/README.md)가
소유한다.

## 왜 우리가 직접 빌드하는가

kyverno는 Dockerfile이 없다 — 7개 이미지 전부 `ko`가 `.ko.yaml`의
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`로 빌드한다. 이 값은 **다이제스트가
아니라 플로팅 태그**이고, 그 이미지 자체가 특정 Alpine 릴리스를 고정하지 않아 기본으로
**Alpine의 롤링 `edge` 브랜치**를 추적한다. trivy의 공식 Alpine 보안 DB는 번호 붙은
정식 릴리스만 다루고 `edge`는 다루지 않는다.

kyverno 이미지 계열 전체에 대해 이미 실측으로 확인했다(추측이 아니다) — 전체 측정
내용은 [images/kyverno/README.ko.md](../kyverno/README.ko.md#왜-우리가-직접-빌드하는가)
참고(`.ko.yaml`이 스캔 가능/불가능 태그 경계에서 바이트 단위로 동일, 베이스 이미지에서
직접 읽은 `VERSION_ID=3.25.0_alpha20260805`, 그 베이스에 대한
`CoverageProbe: none`). `background-controller`는 다른 모든 kyverno 이미지와 완전히
동일한 `.ko.yaml`/`defaultBaseImage`를 쓰므로, 같은 원인과 같은 해법이 그대로
적용된다 — 이 이미지만 따로 조사할 필요는 없다(ADR 0009).

원인이 OS 패키지가 아니라 베이스 이미지 자체이므로(이 바이너리는 kyverno 자체
Makefile 기준 정적 링크, `CGO_ENABLED=0`), 직접 컴파일하면 완전히 해소된다 — 정확한
CVE 목록·건수는 매 빌드마다 `scan-image.sh`/`image-gate.py`가 다시 측정한다("빌드와
검증" 참고).

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 이미지 | `ghcr.io/wolfi-dev/static:alpine`(ko 기본값, 미고정 Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | 이 저장소는 SUSE BCI만 쓴다(rule 2). 바이너리가 정적 링크(`CGO_ENABLED=0`)라 셸·패키지 매니저가 필요 없다 |
| `golang.org/x/mod` | go.mod에 핀된 버전 | `v0.40.0`으로 강제 업그레이드 | CVE-2026-56864, CVE-2026-56865 — 실효 등급 HIGH. `images/kyverno/`와 동일한 모듈 수정 — 두 바이너리가 같은 go.mod/의존성 그래프에서 빌드되기 때문 |
| 진입점 경로 | `ko`의 내부 경로(`/ko-app/background-controller`류) | `/app/background-controller` | kyverno 차트가 `command:`를 하드코딩하지 않고 `args:`만 쓰므로 차트 동작에 영향 없다 |

`SOURCE_COMMIT`과 `GO_MODULE_UPGRADES`는 자동 추적되지 않는다 — 새 kyverno 태그를
확인하고 `source.build.env`를 고쳐 PR을 여는 사람이 곧 갱신 트리거다(kyverno 7개
`build.env` 파일 전체에 대해, ADR 0009). 이 문제는 kyverno의 릴리스가 아니라
wolfi-dev 쪽 베이스 문제이므로, "업스트림이 다음 버전에서 고쳤을 것"이라는 통상적인
재검토 조건이 적용되지 않는다 — `ghcr.io/wolfi-dev/static:alpine`이 번호 붙은,
trivy가 커버하는 Alpine 릴리스로 안정적으로 고정되는지가 재검토 조건이다.

현재 `cve-exceptions.json`에 이 이미지를 겨냥한 예외는 없다 — 위 표의 강제 업그레이드
하나로 게이트가 통과한다.

## 빌드와 검증

```sh
IMAGE=background-controller BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

순서: 빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.
`verify.sh`는 바이너리가 존재·실행 가능한지, nonroot(`65532:65532`)로 도는지,
`--help`가 정상 종료(0)하는지를 확인한다. 실제 컨트롤러 기동은 Kubernetes API 서버
연결이 필요해 이 스모크 테스트 범위 밖이다 — 배포 검증은 별도 절차.

**`images/kyverno/`와 동일한 Go 모듈 버전 자가 스탬핑 오탐 함정이 여기도 적용된다** —
git ADD에 `--keep-git-dir=true`를 쓰지 않는다. BuildKit의 git 컨텍스트는 지정한
커밋만 체크아웃하고 태그 ref는 안 가져오므로, `.git`을 남기면 Go의 VCS 빌드 정보
스탬핑이 `v1.19.0` 태그를 못 찾고 대신 낮은 pseudo-version을 스탬핑한다. 그러면
trivy의 Go 바이너리 스캐너가 오래전에 고쳐진 `github.com/kyverno/kyverno`의 과거 CVE를
"아직 미해결"로 오판한다. 참조 Dockerfile(과 이 Dockerfile)은 이미 그 플래그를 빼고
있다. 전체 원인 분석은
[images/kyverno/README.ko.md](../kyverno/README.ko.md#빌드와-검증) 참고. 대가도
동일하다 — `pkg/version.Hash()`/`Time()`은 `"---"`를 반환하지만,
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
<registry>/background-controller:v1.19.0-security-hardened-20260827
                                  └ app  ┘└ slug  ┘└hardened┘└ 빌드 날짜 ┘
```
