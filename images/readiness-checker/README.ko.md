# readiness-checker — 자체 빌드

[English](README.md) · 한국어

kyverno의 다른 컨트롤러들이 readiness/liveness 프로브 헬퍼로 쓰는 작은 보조
바이너리(업스트림 `kyverno/readiness-checker`)다 — 자체 컨트롤러 로직은 없고, Service에
ready 상태인 엔드포인트가 있는지 확인(`check-endpoints`), HTTP URL이 200을 반환할 때까지
폴링(`check-http`), 배포 그룹의 replica 수 조정(`scale-deploy`), kyverno가 관리하는
webhook 삭제(`delete-webhooks`) 중 하나를 수행하고 종료한다. 어느 차트가 이 이미지를
쓰는지, 태그가 어떻게 배포되는지는 이 레포가 모른다 — 이미지를 어떻게 만드는지만 다룬다.

> 이 이미지는 kyverno의 **비공식 재빌드**다. 업스트림 프로젝트와 제휴·보증·지원
> 관계가 없다. 상표·라이선스 관련 고지는 [NOTICE](../../NOTICE) 참고.

결정 배경·비교한 후보·감수한 비용은
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)에 있다 — 이 이미지는 그 ADR이
다루는 kyverno 자체 빌드 7개 중 하나다. 이미지 선택 규칙과 빌드 프레임워크 자체는
[image-authoring/](../../docs/image-authoring/README.md)가 소유한다.

## 왜 우리가 직접 빌드하는가

[images/kyverno/](../kyverno/README.ko.md#왜-우리가-직접-빌드하는가)와 원인이 같다 —
kyverno는 Dockerfile이 없어 이 이미지를 포함한 7개 전부 `ko`가 `.ko.yaml`의
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`로 빌드하는데, 이 값은 Alpine 버전
고정이 없는 플로팅 태그라 기본으로 Alpine의 롤링 `edge` 브랜치를 추적하며, trivy의 보안
DB는 이를 다루지 않는다(그 베이스 이미지에 직접 측정한 결과 `CoverageProbe: none`).
원인이 이 바이너리 자체의 의존성이 아니라 베이스 이미지이므로 — 이 바이너리는 정적
링크(`CGO_ENABLED=0`, 업스트림 자체 Makefile)라 — SUSE BCI 위에서 직접 컴파일하면
완전히 해소된다. 전체 근거(`.ko.yaml` 비교, `/etc/os-release` 확인, 재빌드 주기 확인)는
`images/kyverno/README.md`에 있고 이미지마다 반복하지 않는다.

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 이미지 | `ghcr.io/wolfi-dev/static:alpine`(ko 기본값, 미고정 Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | 이 저장소는 SUSE BCI만 쓴다(rule 2). 바이너리가 정적 링크(`CGO_ENABLED=0`)라 셸·패키지 매니저가 필요 없다 |
| 진입점 경로 | `ko`의 내부 경로(`/ko-app/readiness-checker`류) | `/app/readiness-checker` | kyverno 차트가 `command:`를 하드코딩하지 않고 `args:`만 쓰므로 차트 동작에 영향 없다 |

이 저장소가 빌드하는 다른 kyverno 컨트롤러 바이너리(`kyverno`, `background-controller`,
`cleanup-controller`, `reports-controller`, `kyverno-cli`, `kyvernopre`)와 달리, 이
이미지는 `GO_MODULE_UPGRADES`가 **필요 없었다** — "버전 관리" 참고.

## 버전 관리

- `SOURCE_COMMIT`은 자동 추적되지 않는다 — 새 kyverno 태그를 확인하고
  `source.build.env`를 고쳐 PR을 여는 사람이 곧 갱신 트리거다. 이 저장소의 다른 kyverno
  이미지 6개와 동일한 커밋을 고정하므로 함께 움직인다.
- `GO_BUILDER_TAG`는 반자동이다 — `scripts/build/suggest-go-upgrades.py`로 재도출하고
  손으로 고르지 않는다.
- `source.build.env`의 `GO_MODULE_UPGRADES`는 의도적으로 비어 있다. 이 바이너리의
  비표준 라이브러리 의존성은 `k8s.io/apimachinery`와 `k8s.io/client-go`뿐이라(업스트림
  `cmd/readiness-checker/main.go` 참고), 형제 kyverno 컨트롤러 바이너리들이
  강제 업그레이드하는 `golang.org/x/mod`에 닿지 않는다. 이는 업그레이드 없이 빌드해
  `gate: PASS`를 확인한 실측 결과이며, 형제 이미지들의 build.env를 보고 추정한 것이
  아니다. 이 이미지를 겨냥한 `cve-exceptions.json` 항목은 없다.
- **자체 빌드를 그만둘 조건**: `ghcr.io/wolfi-dev/static:alpine`이 번호 붙은, trivy가
  커버하는 Alpine 릴리스로 안정적으로 고정되는 것. 새 kyverno 태그만으로는 안 풀린다 —
  모든 kyverno 버전이 같은 미고정 베이스를 참조한다.

## 빌드와 검증

```sh
IMAGE=readiness-checker BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

순서: 빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.

`verify.sh`는 바이너리가 존재·실행 가능한지, nonroot(`65532:65532`)로 도는지, 서브커맨드
없이 실행했을 때 기대한 사용법 배너를 찍고 종료 코드 1로 끝나는지(이 바이너리 자체의
문서화된 동작이지 실패가 아니다), 그리고 서브커맨드의 `-h`(`check-endpoints -h`)가 그
서브커맨드의 플래그 사용법을 찍고 종료 코드 0으로 끝나는지를 확인한다.
`images/kyverno/`의 cobra 기반 CLI와 달리 이 바이너리는 최상위 `--help`가 없는 평범한
`flag` 패키지로 만들어졌다 — 각 서브커맨드 자신의 `flag.NewFlagSet(...,
flag.ExitOnError)`가 `-h`/`--help`를 그 서브커맨드가 Kubernetes API 서버나 네트워크에
닿기 전에 `os.Exit(0)`로 특별 처리해서, 부작용 없는 스모크 테스트로 쓸 수 있다. 실제
체크 실행(Kubernetes API 연결이나 도달 가능한 HTTP 엔드포인트가 필요)은 이 스모크
테스트 범위 밖이다 — `images/kyverno/`의 컨트롤러 기동 관련 범위 제한과 동일하다.

**이 저장소의 다른 모든 Go 자체 빌드와 같은 함정 — git ADD에
`--keep-git-dir=true`를 쓰지 않는다.**
[images/kyverno/README.md](../kyverno/README.ko.md#빌드와-검증)와 원인이 같다 —
BuildKit의 git 컨텍스트는 지정한 커밋만 체크아웃하고 태그 ref는 가져오지 않으므로,
`.git`을 남기면 Go의 VCS 빌드 정보 스탬핑이 `v1.19.0` 대신 낮은 pseudo-version으로
떨어져서, `kyverno` 이미지에서 이미 고쳐진 CVE 15건을 trivy가 여전히 존재하는 것으로
오판했던 적이 있다(그 플래그를 뺀 뒤 해소). 이 Dockerfile은 처음부터
`--keep-git-dir=true`를 쓰지 않으므로 그 함정을 다시 밟지 않았다 — 실측 설명 전문은 그
README에 있다.

`cve-gate.md`에서 결과를 읽는다. 게이트가 통과해도 `trivy-reports/*.json`의
`CoverageProbe`가 `ok`인지 확인한다 — `none`이면 0건이 측정 결과가 아니라 그 배포판
데이터 부재다.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | 핀된 커밋, 버전, 빌더 이미지 태그, 취약 모듈 최소 버전(현재 없음). `BUILD_ARGS`에 나열된 이름만 `--build-arg`로 전달됨 |
| `verify.sh` | 기능 검증. 호스트에서 bash로 실행되며 `docker run --entrypoint bash`로 게스트 셸 스크립트를 주입한다(`bci-micro`엔 bash·coreutils 있음) |

베이스 변형이 하나뿐이라 파일명이 `source.*`로 고정돼 있다.

### 태그

```
<registry>/readiness-checker:v1.19.0-security-hardened-20260827
                              └ app  ┘└ slug  ┘└hardened┘└ 빌드 날짜 ┘
```
