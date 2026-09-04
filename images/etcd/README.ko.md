# etcd — 자체 빌드

[English](README.md) · 한국어

etcd 서버/`etcdctl`/`etcdutl` 바이너리를 업스트림 소스에서 직접 컴파일한다.

> 이 이미지는 etcd 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 받아들인 비용은 [ADR 0003](../../docs/decisions/0003-etcd-image-self-build.md),
신규 자체 빌드 이미지 추가 절차·게이트 메커니즘 전반은
[docs/image-authoring/](../../docs/image-authoring/README.md) 가 갖는다.

## 왜 자체 빌드하는가

업스트림 릴리스 이미지가 차단 등급 CVE 로 게이트에서 막힌다. 원인 모듈이
`golang.org/x/text` 처럼 **바이너리에 정적 링크된 Go 모듈**이고, 상위 태그도 유지보수
브랜치 백포트도 아직 없어 태그 교체로는 대응할 수 없다.

베이스 OS 교체도 통하지 않는다 — 업스트림 배포 이미지 베이스가 distroless 계열(OS
패키지가 사실상 없음)이라 CVE 가 OS 패키지가 아니라 바이너리 안에 있기 때문이다. 정적
링크 모듈의 버전 자체를 올리려면 소스를 다시 컴파일하는 것만이 유효한 대응이다.

이는 `cloudnative-pg` 오퍼레이터 자체 빌드와 같은 유형의 문제(같은 원인 모듈)이고
대응도 같다 — **오케스트레이션은 동일한
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh)
하나를 공유한다.**

## 업스트림과의 차이

| 항목 | 업스트림 | 여기 | 이유 |
| --- | --- | --- | --- |
| 빌드 방식 | 사전 빌드된 릴리스 바이너리를 이미지에 `ADD` | `source.build.env` 의 pinned commit 을 소스에서 직접 컴파일 | 정적 링크된 Go 모듈 버전을 올리려면 그 모듈을 강제로 업그레이드해 다시 빌드해야 한다 — 바이너리를 그대로 가져오는 방식으로는 고칠 수 없다 |
| 최종 베이스 | `gcr.io/distroless/static-debian12` | `registry.suse.com/bci/bci-micro` | 이미지들이 SUSE BCI 하나만 쓴다([docs/image-authoring/](../../docs/image-authoring/README.md) 원칙 2) — 정적 링크 바이너리라 런타임 의존성이 없어 패키지 매니저 없는 가장 가벼운 변종으로 충분하다 |
| 의존성 고정 | 각 모듈(`server`/`etcdctl`/`etcdutl`)의 `go.mod` 가 지정한 버전 그대로 | `GO_MODULE_UPGRADES` 의 각 항목을 `go.work` 워크스페이스 전역 `replace` 로 변환해 강제 업그레이드 | etcd 는 세 바이너리를 Go 워크스페이스로 함께 관리한다 — `go get` 은 실행한 모듈에만 적용돼 형제 모듈이 취약한 채로 남는다. 워크스페이스 전역 `replace` 는 세 모듈에 한 번에 걸리고 업스트림과의 차이도 최소로 유지된다 |
| 버전 문자열(ldflags) | `git rev-parse --short HEAD` 로 얻은 GitSHA 를 빌드 시점에 주입 | pinned commit 전체 해시를 직접 주입 | BuildKit 의 git context(`ADD ...#${SOURCE_COMMIT}`)로 체크아웃하므로 커밋을 이미 알고 있다 — 호스트의 `verify.sh` 가 컨테이너 안에서 git 을 실행하지 않고도 버전 문자열에 pinned commit 이 반영됐는지 확인할 수 있다 |

빌더 스테이지(Go 컴파일)는 공식 `golang` 이미지를 그대로 쓴다 — 최종 이미지에 남지
않고 컴파일 산출물만 최종 스테이지로 넘어오므로 스캔·정책 대상이 아니다. 그 외 빌드
절차(`server`/`etcdutl`/`etcdctl` 세 바이너리를 각각 컴파일, `CGO_ENABLED=0` 정적 링크)는
업스트림 저장소(etcd-io/etcd)의 `scripts/build_lib.sh` 안 `etcd_build()` 를 그대로 재현한다
(이 레포의 `scripts/` 와는 무관하다).

`SOURCE_COMMIT` 은 **자동 추적하지 않는다.** 사람이 업스트림 `release-3.7` 브랜치(또는
다음 패치 릴리스 태그)를 보고 `source.build.env` 를 고쳐 PR 을 여는 것 자체가 갱신
트리거다. 상위 릴리스가 이 CVE 를 포함해 나오면 그쪽으로 갈아타는 것이 이 자체 빌드를
유지하는 것보다 항상 우선한다.

`GO_MODULE_UPGRADES` 는 반대로 **자동 추적한다.** 일일 rescan 이 드리프트를 찾으면
`suggest-go-upgrades.py --apply` 가 값을 올려 `autofix/go-cves` PR 로 올린다. 워크스페이스
전역 `replace` 라는 적용 방식은 그대로지만, 값이 다른 Go 이미지와 같은 키에 담겨 있어야
자동 적용 대상이 된다 — `--apply` 는 없는 키를 새로 만들지 않기 때문이다. 예전의
`XTEXT_FIX_VERSION` 이 이 키로 바뀐 이유다.

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=etcd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=etcd BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**
`verify.sh` 는 `etcd`/`etcdctl`/`etcdutl` 이 PATH 에 있는지, `etcd --version` 출력에
pinned commit 이 실제로 반영됐는지(ldflags 주입 확인), 단일 노드로 기동해 `etcdctl`
put/get 왕복이 실제로 동작하는지를 확인한다 — 다중 노드 쿼럼·TLS 등은 이 스모크 테스트
범위 밖이며, 배포 검증은 별도 절차를 따른다.

게이트 판정 결과는 `cve-gate.md` 로 확인한다 — 실효 C/H 등급뿐 아니라 커버리지
자가진단(`CoverageProbe`)도 함께 봐야 한다. `CoverageProbe` 가 `none` 이면 스캐너가
이 이미지의 패키지를 제대로 인식하지 못했다는 뜻이라 findings 0 이 진짜 0 이 아니며,
그 경우 게이트가 막는다 — 자세한 판정 로직은
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 소스 컴파일(builder 스테이지) + SUSE BCI(`bci-micro`) 패키징(final 스테이지) |
| `source.build.env` | pinned commit·버전·빌더 이미지 태그. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 기능 검증. 호스트에서 bash 로 실행되며 `docker run --entrypoint sh` 로 게스트 셸 스크립트를 주입한다(`bci-micro` 는 bash·coreutils 가 있다 — `cnpg-postgresql/verify.sh` 와 같은 패턴, `cloudnative-pg` 의 셸 없는 distroless 와는 다르다) |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
docker.io/paasup/etcd:3.7.1-security-hardened-20260731
                       └ app ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

빌드·게이트 PASS·push 가 끝나면 `published.json` 이 이 태그를 기록한다 — 현재 상태는
`MEMORY.md` 참고.
