# apisix-ingress-controller — 자체 빌드

[English](README.md) · 한국어

apisix-ingress-controller 바이너리를 업스트림 소스에서 직접 컴파일한다. 이 이미지가
어느 차트·환경에서 쓰이는지, 태그를 어떻게 반영하는지는 이 레포가 모른다 —
이 레포는 "이미지를 어떻게 만드는가"만 다룬다.

> 이 이미지는 Apache APISIX Ingress Controller 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 후보 비교·받아들인 비용은 [ADR 0006](../../docs/decisions/0006-apisix-ingress-controller-self-build.md), 이미지 선정 규칙과 빌드 프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가 갖는다.

## 왜 자체 빌드하는가

업스트림 이미지가 최신 태그인데도, 게이트가 차단하는 CVE 대부분이 OS 패키지가 아니라
바이너리에 **정적 링크된 Go 모듈** 버전이 원인이다(stdlib, `golang.org/x/net`,
`golang.org/x/text`, `google.golang.org/grpc`, `go.opentelemetry.io/otel`/`otel/sdk`).
상위 태그 교체로 해소할 수 없고, 업스트림 베이스가 distroless 계열(OS 패키지가 거의
없음)이라 베이스 OS 교체만으로도 해소되지 않는다 — 취약 모듈을 최소 호환 버전까지
끌어올리는 소스 재컴파일이 유일한 대응이다.

정확한 CVE 목록·건수는 `scan-image.sh`/`image-gate.py` 가 매 빌드마다 다시 낸다 —
아래 "빌드·검증" 절 참고.

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 애플리케이션 코드 | 릴리스 태그 그대로 | 동일(태그 그대로) | 이 프로젝트는 유지보수 브랜치가 없고 `master` 하나뿐이라, `master` HEAD 로 옮기면 신규 기능 커밋까지 섞여 최소 diff 원칙에 맞지 않는다. 태그는 유지하고 취약 모듈만 강제 업그레이드한다 |
| 전이 의존성 | go.mod 고정 버전 | `GO_MODULE_UPGRADES` 목록을 `go get`+`go mod tidy` 로 최소 호환 버전까지 상향 | `go.work` 워크스페이스가 없는 단일 모듈 프로젝트라 전역 `replace` 한 줄로 끝나지 않는다 — 여러 모듈을 한 번에 지정해야 하며(otel 코어/sdk 는 버전이 서로 맞아야 해서 반드시 함께 지정), `go get`이 나머지 호환 버전을 정리한다. 모듈별 `<LIB>_FIX_VERSION` ARG 를 쓰다가 이 키 하나로 바꿨다 — `suggest-go-upgrades.py --apply` 가 없는 키는 만들지 않아서, 그대로 뒀다면 이 이미지만 자동 수정에서 빠진다 |
| 최종 베이스 이미지 | `gcr.io/distroless/cc-debian12` | `registry.suse.com/bci/bci-micro:15.7` | 이미지들은 SUSE BCI 하나만 쓴다([docs/image-authoring/](../../docs/image-authoring/README.md) 원칙 2). 바이너리가 `CGO_ENABLED=0` 정적 링크라 glibc 를 포함하는 `cc` 변형이 애초에 필요 없다 — `static` 대비 이점이 없어 `bci-micro` 로 통일한다 |

`SOURCE_COMMIT`과 의존성 최소 버전은 자동 추적하지 않는다. 사람이 업스트림 새 태그(또는
해당 CVE 를 이미 해소한 커밋)를 보고 `source.build.env` 를 고쳐 PR 을 여는 것 자체가
갱신 트리거다. 업스트림이 이 CVE 들을 해소한 새 릴리스나 유지보수 브랜치를 내놓으면,
자체 빌드를 유지하는 것보다 그쪽으로 갈아타는 것이 항상 우선이다.

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=apisix-ingress-controller BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=apisix-ingress-controller BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**
`verify.sh` 는 바이너리가 실행 가능한지, `version --long` 출력에 pinned commit 이 실제로
반영됐는지(ldflags 주입 확인), `--help` 가 정상 종료하는지, 이미지가 `65532:65532`
(nonroot) 로 실행되는지를 확인한다. 이 컨트롤러는 실제 기동에 Kubernetes API 서버
접속이 필요한데, 그 부분은 이 스모크 테스트 범위 밖이다 — 배포 검증은 별도 절차를
따른다.

결과는 `/tmp/out/cve-gate.md` 로 확인한다. 게이트가 PASS 여도 `/tmp/out/trivy-reports/*.json`
의 `CoverageProbe` 가 `ok` 인지 함께 확인한다 — `none` 이면 findings 0건이 진짜 0건이
아니라 스캐너에 해당 배포판 데이터가 없다는 뜻이다. 자세한 판정 로직은
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | pinned commit·버전·빌더 이미지 태그·취약 모듈 최소 버전. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 기능 검증. 호스트에서 bash 로 실행되며 `docker run --entrypoint sh` 로 게스트 셸 스크립트를 주입한다(`bci-micro` 는 bash·coreutils 가 있다) |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
docker.io/paasup/apisix-ingress-controller:2.1.0-security-hardened-20260811
                                            └ app ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```
