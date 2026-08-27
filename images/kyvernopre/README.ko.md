# kyvernopre — 자체 빌드

[English](README.md) · 한국어

kyverno의 초기화/마이그레이션 잡 바이너리(`kyvernopre`), 업스트림 소스에서 직접
컴파일한 것. Helm install/upgrade 시점에 한 번 실행되어 kyverno가 남긴 오래된
webhookconfiguration을 정리하고 종료한다. 어느 차트가 이 이미지를 쓰는지, 태그가
어떻게 배포되는지는 이 레포가 모른다 — 이미지를 어떻게 만드는지만 다룬다.

> 이 이미지는 kyverno의 **비공식 재빌드**다. 업스트림 프로젝트와 제휴·보증·지원
> 관계가 없다. 상표·라이선스 관련 고지는 [NOTICE](../../NOTICE) 참고.

결정 배경·비교한 후보·감수한 비용은
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md)(kyverno 7개 이미지를 하나의
결정으로 다룬다)에 있다. 이미지 선택 규칙과 빌드 프레임워크 자체는
[image-authoring/](../../docs/image-authoring/README.md)가 소유한다.

## 왜 우리가 직접 빌드하는가

[`images/kyverno/README.md`](../kyverno/README.md)와 원인이 같다: kyverno는
Dockerfile이 없다 — `kyvernopre`를 포함한 7개 이미지 전부 `ko`가 `.ko.yaml`의
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`로 빌드한다. 이 값은 **다이제스트가
아니라 플로팅 태그**이고 Alpine의 스캔 불가능한 롤링 `edge` 브랜치로 풀린다. trivy의
공식 Alpine 보안 DB는 번호 붙은 정식 릴리스만 다루고 `edge`는 다루지 않는다. 전체
조사 내용(버전 간 바이트 단위로 동일한 `.ko.yaml`, `VERSION_ID` 실측, 매일 재빌드되나
마커는 그대로였다는 관측, `CoverageProbe: none` 직접 측정)은
`images/kyverno/README.md`와 ADR 0009에 있다 — 7개 이미지가 완전히 같은 베이스
이미지와 `.ko.yaml`을 공유하므로 이미지별로 재조사하지 않는다.

원인은 이 바이너리 자체 코드나 OS 패키지가 아니라 베이스 이미지다 —
`kyvernopre`도 다른 모든 kyverno 바이너리처럼 정적 링크(`CGO_ENABLED=0`)이므로 직접
컴파일하면 완전히 해소된다. 정확한 CVE 건수는 매 빌드마다
`scan-image.sh`/`image-gate.py`가 다시 측정한다("빌드와 검증" 참고).

## 업스트림과의 차이

| 항목 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 최종 베이스 이미지 | `ghcr.io/wolfi-dev/static:alpine`(ko 기본값, 미고정 Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | 이 저장소는 SUSE BCI만 쓴다(rule 2). 바이너리가 정적 링크(`CGO_ENABLED=0`)라 셸·패키지 매니저가 필요 없다 |
| 소스 디렉터리 이름 | 바이너리/이미지 이름은 `kyvernopre`지만 소스는 업스트림 `cmd/kyverno-init`에 있다(`cmd/kyvernopre`가 아님) | 같은 소스 디렉터리(`./cmd/kyverno-init`)를 컴파일하고 결과물만 `kyvernopre`로 명명 — 업스트림 Makefile의 `KYVERNOPRE_BIN := $(KYVERNOPRE_DIR)/kyvernopre`와 정확히 일치 | 실제 차이가 아니라 이름 불일치일 뿐이지만, 존재하지 않는 `cmd/kyvernopre` 디렉터리를 찾아 헤매지 않도록 기록해둔다 |
| 진입점 경로 | `ko`의 내부 경로(`/ko-app/kyvernopre`류) | `/app/kyvernopre` | kyverno 차트가 init 컨테이너에 `command:`를 하드코딩하지 않고 `args:`만 쓰므로 차트 동작에 영향 없다 |
| `golang.org/x/mod` | go.mod에 핀된 버전 | `v0.40.0`으로 강제 업그레이드 | CVE-2026-56864, CVE-2026-56865 — 실효 등급 HIGH. `images/kyverno/`와 같은 수정이며, kyverno 결과를 그대로 가정한 게 아니라 이 바이너리 자체 SBOM에서 해당 모듈이 실제로 나타나는 것을 확인해 독립적으로 검증했다 |

`SOURCE_COMMIT`은 자동 추적되지 않는다 — 새 kyverno 태그를 확인하고
`source.build.env`를 고쳐 PR을 여는 사람이 곧 갱신 트리거다, 다른 모든 kyverno
이미지와 동일하다(`images/kyverno/README.md` 참고).

현재 `cve-exceptions.json`에 이 이미지를 겨냥한 예외는 없다 — 위 표의 강제 업그레이드
하나로 게이트가 통과한다, `images/kyverno/`와 동일하다.

## 빌드와 검증

```sh
IMAGE=kyvernopre BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

순서: 빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.
`verify.sh`는 바이너리가 존재·실행 가능한지, nonroot(`65532:65532`)로 도는지,
`--help`가 정상 종료(0)하는지를 확인한다. `kyvernopre`는 1회성 초기화 잡이다 — lease를
획득하고 오래된 kyverno webhookconfiguration을 정리하는데, 이는 Kubernetes API 서버
연결이 필요하다. kyverno 컨트롤러의 `verify.sh`와 마찬가지로 이 스모크 테스트 범위
밖이다 — 배포 검증은 별도 절차.

이 빌드도 다른 모든 kyverno 이미지와 동일하게 `.git` 디렉터리를 남기지 않는다
(`images/kyverno/README.md`의 "빌드와 검증" 절과 원인이 같다 — 핀된 커밋만 체크아웃하는
git 컨텍스트에서 `.git`을 남기면 Go가 낮은 pseudo-version을 자동 스탬핑하고, trivy가
그 값을 기준으로 `github.com/kyverno/kyverno`의 과거 CVE를 전부 오탐 처리한다).
`source.Dockerfile`이 이미 `--keep-git-dir=true`를 쓰지 않으므로 여기서 다시
겪지는 않았다.

`cve-gate.md`에서 결과를 읽는다. 게이트가 통과해도 `trivy-reports/*.json`의
`CoverageProbe`가 `ok`인지 확인한다 — `none`이면 0건이 측정 결과가 아니라 그 배포판
데이터 부재다.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | 핀된 커밋, 버전, 빌더 이미지 태그. `BUILD_ARGS`에 나열된 이름만 `--build-arg`로 전달됨 |
| `verify.sh` | 기능 검증. 호스트에서 bash로 실행되며 `docker run --entrypoint bash`로 게스트 셸 스크립트를 주입한다(`bci-micro`엔 bash·coreutils 있음) |

베이스 변형이 하나뿐이라 파일명이 `source.*`로 고정돼 있다.

### 태그

```
<registry>/kyvernopre:v1.19.0-security-hardened-20260827
                      └ app  ┘└ slug  ┘└hardened┘└ 빌드 날짜 ┘
```
