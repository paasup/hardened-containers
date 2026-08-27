# infisical-secrets-operator — 자체 빌드

[English](README.md) · 한국어

Infisical Kubernetes Secrets Operator(`infisical/kubernetes-operator`) 바이너리를
업스트림 소스에서 직접 컴파일한다. 이 이미지가 어느 차트·환경에서 쓰이는지, 태그를
어떻게 반영하는지는 이 레포가 모른다 — 이 레포는 "이미지를 어떻게 만드는가"만 다룬다
(참고로 이 이미지는 형제 레포 `dip-catalog`의 `secrets-operator` 차트가 쓴다).

> 이 이미지는 Infisical Kubernetes Operator 를 재빌드한 **비공식 배포물**이며 업스트림
> 프로젝트와 제휴·보증 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 후보 비교·받아들인 비용은
[ADR 0010](../../docs/decisions/0010-infisical-secrets-operator-self-build.md), 이미지
선정 규칙과 빌드 프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md)
가 갖는다.

## 왜 자체 빌드하는가

업스트림 이미지가 최신 태그(`v0.11.8`)인데도, 게이트가 차단하는 CVE 전부가 OS 패키지가
아니라 바이너리에 **정적 링크된 Go 모듈·stdlib** 버전이 원인이다(stdlib,
`golang.org/x/net`, `golang.org/x/text`, `google.golang.org/grpc`). 상위 태그 교체로
해소할 수 없고(Docker Hub·업스트림 GitHub 태그 목록 모두 `v0.11.8`이 최신임을 확인),
업스트림 베이스가 `gcr.io/distroless/static:nonroot`(distroless 계열, OS 패키지가 거의
없음)라 베이스 OS 교체만으로도 해소되지 않는다 — 취약 모듈을 최소 호환 버전까지,
stdlib 은 빌더 Go 툴체인을 올려 끌어올리는 소스 재컴파일이 유일한 대응이다.

정확한 CVE 목록·건수는 `scan-image.sh`/`image-gate.py` 가 매 빌드마다 다시 낸다 — 아래
"빌드·검증" 절 참고.

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 애플리케이션 코드 | 릴리스 태그(`infisical-k8-operator/v0.11.8`) 그대로 | 동일(태그 그대로) | MIT 라이선스, 단일 모듈 프로젝트. 코드 변경 없이 의존성만 강제 업그레이드한다 |
| 전이 의존성 | go.mod 고정 버전(`x/net` 0.55.0 · `x/text` 0.37.0 · `grpc` 1.79.3) | `go get`+`go mod tidy` 로 최소 호환 버전까지 상향 | `go.work` 워크스페이스가 없는 단일 모듈 프로젝트라 전역 `replace` 한 줄로 끝나지 않는다 — 여러 모듈을 한 번에 지정해야 하고, `go get`이 나머지 호환 버전을 정리한다(apisix-ingress-controller, ADR 0006 과 같은 패턴) |
| Go 툴체인 | `golang:1.25` (go.mod `go 1.25.0`) | `GO_BUILDER_TAG`로 그 이상(stdlib CVE 수정 버전 이상) | stdlib CVE 는 모듈이 아니라 툴체인 문제라 별도 값으로 관리한다 |
| 최종 베이스 이미지 | `gcr.io/distroless/static:nonroot` | `registry.suse.com/bci/bci-micro:15.7` | 이미지들은 SUSE BCI 하나만 쓴다([docs/image-authoring/](../../docs/image-authoring/README.md) 원칙 2). 바이너리가 `CGO_ENABLED=0` 정적 링크라 glibc 를 포함하는 변형이 애초에 필요 없다 |

`SOURCE_COMMIT`, Go 툴체인 태그, 의존성 최소 버전은 자동 추적하지 않는다. 사람이
업스트림 새 태그(또는 해당 CVE 를 이미 해소한 커밋)를 보고 `source.build.env` 를 고쳐
PR 을 여는 것 자체가 갱신 트리거다. `GO_BUILDER_TAG` 후보는
`scripts/build/suggest-go-upgrades.py` 로 도출하되, 실제 반영은 사람이 검토 후
커밋한다. 업스트림이 이 CVE 들을 해소한 새 릴리스를 내놓으면, 자체 빌드를 유지하는
것보다 그쪽으로 갈아타는 것이 항상 우선이다.

현재 이 이미지를 겨냥한 `cve-exceptions.json` 항목은 없다 — 위 CVE 는 모두 예외 승인이
아니라 버전 상향으로 해소한다.

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=infisical-secrets-operator BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=infisical-secrets-operator BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**
`verify.sh` 는 바이너리가 실행 가능한지, ldflags 로 주입한 버전이 실제 바이너리에
반영됐는지(`--version` 플래그가 없어 대신 바이너리에 굳어 있는 HTTP User-Agent
토큰으로 확인), `--help` 가 정상 종료하는지, 이미지가 `65532:65532`(nonroot) 로
실행되는지를 확인한다. 이 오퍼레이터는 실제 기동·리컨실에 Kubernetes API 서버 접속이
필요한데, 그 부분은 이 스모크 테스트 범위 밖이다 — 배포 검증(`infisical-standalone` 과
함께 설치해 `InfisicalSecret` 이 실제로 동기화되는지 확인)은 별도 절차를 따른다.

결과는 `/tmp/out/cve-gate.md` 로 확인한다. 게이트가 PASS 여도 `/tmp/out/trivy-reports/*.json`
의 `CoverageProbe` 가 `ok` 인지 함께 확인한다 — `none` 이면 findings 0건이 진짜 0건이
아니라 스캐너에 해당 배포판 데이터가 없다는 뜻이다. 자세한 판정 로직은
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | pinned commit·버전·빌더 이미지 태그·취약 모듈 최소 버전. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 기능 검증. 호스트에서 bash 로 실행되며 `docker create`/`docker cp` 로 바이너리를 호스트로 꺼내 검사한다(`bci-micro` 에는 grep 이 없다) |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
<registry>/infisical-secrets-operator:v0.11.8-security-hardened-20260827
                                       └  app  ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

## 아직 안 된 것 — 배포 검증

`verify.sh` 는 바이너리 실행·ldflags 반영·nonroot 만 확인한다. 실제 Kubernetes 클러스터에
`infisical-standalone` 과 함께 설치해 `InfisicalSecret` CRD 가 실제로 시크릿을
동기화하는지는 아직 별도로 검증하지 않았다.
