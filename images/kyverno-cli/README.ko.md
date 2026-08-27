# kyverno-cli — 자체 빌드

[English](README.md) · 한국어

kyverno CLI(`kubectl-kyverno` — `kyverno test`, `kyverno apply` 등), 업스트림 소스에서
직접 컴파일한 것. 어느 차트가 이 이미지를 쓰는지, 태그가 어떻게 배포되는지는 이 레포가
모른다 — 이미지를 어떻게 만드는지만 다룬다.

> 이 이미지는 kyverno의 **비공식 재빌드**다. 업스트림 프로젝트와 제휴·보증·지원
> 관계가 없다. 상표·라이선스 관련 고지는 [NOTICE](../../NOTICE) 참고.

결정 배경·비교한 후보·감수한 비용은
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)에 있다(7개 kyverno 이미지
전체를 하나의 결정으로 다룬다). 이미지 선택 규칙과 빌드 프레임워크 자체는
[image-authoring/](../../docs/image-authoring/README.md)가 소유한다.

## 왜 우리가 직접 빌드하는가

원인은 [images/kyverno/README.md](../kyverno/README.ko.md)의 "왜 우리가 직접
빌드하는가"와 완전히 같다 — kyverno의 7개 이미지 전부 `ko`가 `.ko.yaml`의
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`(다이제스트가 아닌 플로팅 태그, 미고정
Alpine `edge` 브랜치)로 빌드하고, trivy는 `edge`용 보안 DB가 없다. 이 CLI 이미지 자체의
의존성 문제가 아니다 — 근거·실측치는 [ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)
참고.

원인이 OS 패키지가 아니라 베이스 이미지 자체이므로(`kubectl-kyverno` 바이너리도 정적
링크, `CGO_ENABLED=0`), 직접 컴파일하면 완전히 해소된다. 정확한 CVE 목록·건수는 매
빌드마다 `scan-image.sh`/`image-gate.py`가 다시 측정한다("빌드와 검증" 참고).

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 이미지 | `ghcr.io/wolfi-dev/static:alpine`(ko 기본값, 미고정 Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | 이 저장소는 SUSE BCI만 쓴다(rule 2). 바이너리가 정적 링크(`CGO_ENABLED=0`)라 셸·패키지 매니저가 필요 없다 |
| `golang.org/x/mod` | go.mod에 핀된 버전 | `v0.40.0`으로 강제 업그레이드 | CVE-2026-56864, CVE-2026-56865 — images/kyverno/와 동일 go.mod(단일 모듈 저장소)라 같은 취약 모듈이 적용됨 |
| 소스 디렉터리 | `cmd/cli/kubectl-kyverno`(다른 6개 kyverno 바이너리보다 한 단계 더 깊음) | 동일 경로에서 빌드 | 업스트림 자체 구조 — Makefile `CLI_DIR` |
| 바이너리 이름 | `kubectl-kyverno`(kubectl 플러그인 관례) | 동일하게 유지 | Makefile `CLI_BIN := $(CLI_DIR)/kubectl-kyverno`를 그대로 재현 — `cli`나 `kyverno-cli`로 바꾸지 않음 |
| 진입점 경로 | `ko`의 내부 경로(`/ko-app/cli`류) | `/app/kubectl-kyverno` | 독립 실행 CLI라 컨트롤러 이미지들과 달리 차트 `command:`/`args:` 호환 문제 자체가 없음 |

`SOURCE_COMMIT`과 `GO_MODULE_UPGRADES`는 자동 추적되지 않는다 — 새 kyverno 태그를
확인하고 `source.build.env`를 고쳐 PR을 여는 사람이 곧 갱신 트리거다(7개 이미지 전부
동일 — [images/kyverno/README.ko.md](../kyverno/README.ko.md) 참고). 이 문제는
kyverno의 릴리스가 아니라 wolfi-dev 쪽 베이스 문제이므로, "업스트림이 다음 버전에서
고쳤을 것"이라는 통상적인 재검토 조건이 적용되지 않는다 — 재검토 조건은
`ghcr.io/wolfi-dev/static:alpine`이 번호 붙은, trivy가 커버하는 Alpine 릴리스로
안정적으로 고정되는지다.

현재 `cve-exceptions.json`에 이 이미지를 겨냥한 예외는 없다 — 위 표의 강제 업그레이드
하나로 게이트가 통과한다.

## 빌드와 검증

```sh
IMAGE=kyverno-cli BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

순서: 빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.

`verify.sh`는 images/kyverno/의 컨트롤러 이미지와 다르게 검증한다 — 컨트롤러는
Kubernetes API 서버 연결 없인 `--help` 외에 할 수 있는 게 없지만, 이 이미지는 cobra 기반
독립 CLI(`cmd/cli/kubectl-kyverno/commands/command.go`)라 부작용 없는 진짜 서브커맨드
`version`이 있다. 그래서 `verify.sh`는 바이너리 존재·실행 가능 여부, nonroot
(`65532:65532`) 실행, `--help` 정상 종료(0)에 더해 **`kubectl-kyverno version`이 실제로
0으로 종료하고 그 출력이 핀된 `APP_VERSION`을 반영하는지**(`pkg/version.BuildVersion` —
images/kyverno/가 쓰는 것과 같은 ldflags 심볼)까지 확인한다. `kyverno test`/
`kyverno apply`는 정책·리소스 입력이 있어야 의미가 있어 스모크 테스트 범위 밖이다.

**빌드 중 실측한 함정 — Go 모듈 버전 자가 스탬핑 오탐**: images/kyverno/와 근본 원인이
같다 — `--keep-git-dir=true`를 쓰면 BuildKit의 git 컨텍스트가 태그 ref를 안 가져와
Go가 낮은 pseudo-version을 자가 스탬핑하고, trivy가 과거 버전에서 이미 고쳐진
`github.com/kyverno/kyverno` CVE까지 오탐한다. 자세한 설명은
[images/kyverno/README.ko.md](../kyverno/README.ko.md)의 "빌드와 검증" 참고 — 여기서는
반복하지 않는다. 이 이미지의 `source.Dockerfile`도 처음부터 `--keep-git-dir=true`를 쓰지
않는다.

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
<registry>/kyverno-cli:v1.19.0-security-hardened-20260827
                       └ app  ┘└ slug  ┘└hardened┘└ 빌드 날짜 ┘
```
