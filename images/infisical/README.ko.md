# infisical — 자체 빌드

[English](README.md) · 한국어

Infisical 백엔드(`infisical/infisical`, secrets-operator 와 짝을 이루는 standalone 서버)
바이너리를 업스트림 소스에서 직접 컴파일한다. 이 이미지가 어느 차트·환경에서 쓰이는지,
태그를 어떻게 반영하는지는 이 레포가 모른다 — 이 레포는 "이미지를 어떻게 만드는가"만
다룬다(참고로 이 이미지는 형제 레포 `dip-catalog`의 `infisical-standalone` 차트가 쓴다).

> 이 이미지는 Infisical 을 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 후보 비교·받아들인 비용은
[ADR 0011](../../docs/decisions/0011-infisical-self-build.md), 이미지 선정 규칙과 빌드
프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가 갖는다.

## 왜 자체 빌드하는가

`infisical/infisical` 은 dip-catalog 에 `v0.158.0` 으로 고정돼 있었는데, 이는 업스트림
최신(`v0.164.1`)보다 6개 마이너 버전 뒤처져 있었다 — 상위 태그 교체만으로도 효과가 크다는
뜻이다. 이 이미지는 최신 태그(`v0.164.1`)를 기준으로 잡았다.

최신 태그 기준으로 실측한 CVE 는 두 층으로 나뉜다.

- **OS 패키지 층(Debian 13.3, `node:22.22.0-trixie-slim`) — 실효 HIGH/CRITICAL 273건.**
  업스트림 스스로도 `Dockerfile.standalone-infisical` 안에서 특정 Debian 패키지를
  수동으로 핀 업그레이드하며 이 문제와 싸우고 있다(`apt-get install --only-upgrade
  libgnutls30t64=... libc6=... ...`). 베이스를 SUSE BCI 로 교체하는 것만으로 이 층
  전체가 해소된다 — Debian 패키지 자체가 이미지에 존재하지 않게 되기 때문이다.
- **애플리케이션 의존성 층(Node/Go/Rust) — 실효 HIGH/CRITICAL 81건.** 대부분(node-pkg
  26개 패키지)은 npm `overrides` 로 최소 수정 버전까지 강제 상향해 해소했다(아래
  "업스트림과의 차이" 표). Go 사이드카·Rust 네이티브 애드온에서 나온 CVE 는 그 두
  컴포넌트를 아예 빼면서 함께 없어졌다(아래 참고) — 단 `@infisical/quic` 는 예외다.

정확한 CVE 목록·건수는 `scan-image.sh`/`image-gate.py` 가 매 빌드마다 다시 낸다 — 아래
"빌드·검증" 절 참고.

## 업스트림과의 차이

### 뺀 것 — 각각 업스트림 소스로 직접 확인 후 결정

| 항목 | 왜 빼도 되는지 |
| --- | --- |
| Oracle Instant Client | `oracledb` ^6.4.0 는 기본이 thin 모드(순수 JS, 클라이언트 불필요). `initOracleClient()` 는 OracleDB wallet mTLS 연결일 때만 호출되고, 실패해도 catch 되어 그 기능만 못 쓴다(`sql-connection-fns.ts`) |
| smbclient | npm 의존성이 아니다 — `child_process`로 그 기능이 실제 호출될 때만 spawn 된다(`lib/smb-rpc/smb-rpc-client.ts`). 서버 부팅과 무관 |
| 번들 `infisical` CLI | 업스트림이 원격 설치 스크립트를 셸로 바로 파이프해 설치(이 레포 규칙 7 위반). 서버 프로세스와 무관한 별도 도구 |
| PQC(post-quantum) OpenSSL 자체 빌드 | `pqc-openssl.ts` 가 `/opt/openssl-pqc/bin/openssl` 를 lazy `spawn()`으로만 호출 — 부팅과 무관, 그 기능만 못 씀 |
| Go 사이드카(`backend-go/`, Gateway 온프렘 릴레이) | `go-sidecar.ts` 플러그인이 `if (!opts.enabled) return`로 게이트돼 있다 — Gateway 를 설정하지 않으면 바이너리 경로 자체가 안 닿는다 |

### 못 뺀 것 — unixODBC 런타임 라이브러리

동적 시크릿 프로바이더 레지스트리(`providers/index.ts`)가 부팅 시점에 `sap-ase.ts`·
`sap-hana.ts` 를 정적 import 하고, 둘 다 `import odbc from "odbc"` 를 최상단에서 한다.
즉 SAP ASE/HANA 동적 시크릿을 설정하지 않아도 **서버가 뜨는 것만으로** `odbc` 네이티브
애드온이 로드되며 `libodbc.so.2` 를 찾는다 — 이게 없으면 서버 자체가 부팅 실패한다.
그래서 unixODBC 런타임(`libodbc2`)만은 최종 이미지에 남겼다. 반대로 FreeTDS(실제 TDS
드라이버, `odbcinst.ini` 가 가리키는 대상)는 실제 연결 시도 시점에만 필요해 뺐다.

### 빌더 스테이지 — 백엔드만 SUSE BCI

| 스테이지 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 프론트엔드 빌더 | 공식 `node` 이미지 | 동일(공식 `node` 이미지, 업스트림과 같은 태그) | 산출물이 정적 Vite 에셋뿐이라 네이티브 바이너리·ABI 문제가 없다 — 평소 기본값(공식 언어 이미지) 그대로 |
| 백엔드 빌더 | 공식 `node` 이미지(Debian) | `registry.suse.com/bci/bci-base`(최종 스테이지와 동일 베이스) | 백엔드 프로덕션 의존성에 네이티브 Node 애드온(`argon2`·`bcrypt`·`odbc`)이 있다. Debian 에서 컴파일해 SUSE BCI 에서 실행하면 glibc ABI 불일치 위험이 있다 — [builder-languages.md](../../docs/image-authoring/builder-languages.md) 의 C/Lua 규칙("빌더와 최종 스테이지를 같은 베이스로 유지하고 동적 링크")을 네이티브 Node 애드온에도 그대로 적용했다 |

### 강제 상향한 Node 의존성(26개, `NPM_DIRECT_UPGRADES` + `NPM_OVERRIDES`)

`golang.org/x/*`류 Go 모듈처럼, `node-pkg` 취약점은 대부분 **전이 의존성**이다. `go
get` 의 npm 대응이 `overrides` 필드다(`npm pkg set overrides[<pkg>]=<version>` 후
`npm install`). 값은 하나하나 손으로 고른 게 아니라 trivy 리포트의 `FixedVersion` 에서
뽑았고 — 원칙은 **설치된 버전과 같은 메이저 라인 안에서** 고치는 최소 버전(같은
메이저에 수정 버전이 없는 두 건, `ip-address`→10.x·`sigstore`→4.x 만 메이저를
올렸다). 정확한 값과 CVE 는 `source.build.env`에 있다.

Go 쪽 강제 업그레이드에는 없는, 이번에 실제 빌드 실패로 실측한 두 가지 함정이 있다.

- **npm 은 직접 의존성(direct dependency)인 패키지를 `overrides` 로 덮어쓰는 걸
  거부한다**(`npm error EOVERRIDE`). 26개 중 8개(`@fastify/static`·`axios`·
  `dd-trace`·`nanoid`·`nodemailer`·`oci-common`·`scim-patch`·`uuid`)는
  `backend/package.json`의 직접 의존성이라 `NPM_DIRECT_UPGRADES` 로 별도 처리한다
  (`dependencies` 자체를 올리고, 다른 패키지가 끌어오는 *중첩* 사본까지 한 번에
  맞추기 위해 자기 참조 `overrides[pkg]["."]` 항목도 같이 넣는다 — npm 의 EOVERRIDE
  검사는 semver 만족 여부가 아니라 `dependencies` 값과의 **문자열 일치** 여부를 보므로
  `^` 까지 포함해 두 값이 글자 그대로 같아야 한다). `npm ci` 는 두 빌드 스테이지 모두
  `npm install` 로 바꿨다 — `npm pkg set` 이 `package.json` 을 커밋된
  `package-lock.json` 과 어긋나게 만든 뒤에는 `npm ci` 가 설계상 진행을 거부하기
  때문이다.
- **중첩 의존성 하나를 강제로 올리면, 그걸 일부러 낮춰 쓰던 다른 패키지가 깨질 수
  있다.** `oci-common@2.108.0`(직접 의존성, OCI Vault 연동)은 `uuid@3.3.3` 을 고정해
  쓰면서 uuid 의 옛날 서브패스 API `uuid/v1` 을 쓰는데, 이 서브패스는 uuid 9 부터
  `package.json` 의 `exports` 맵에서 아예 빠졌다. `oci-common` 을 같이 안 올리고
  `uuid` 만 11.1.1 로 강제하면 서버가 부팅 중 크래시한다(`ERR_PACKAGE_PATH_NOT_EXPORTED`
  — 게이트가 아니라 `verify.sh` 가 잡아냈다). `oci-common` 을 자기 자신의 최신
  버전(2.140.0, 이미 최신 `uuid` 를 쓰도록 마이그레이션됨)으로 올리니 크래시와 중첩
  CVE 가 한 번에 해소됐다 — `oci-common` 이 직접 스캔 대상이 아니었는데도
  `NPM_DIRECT_UPGRADES` 에 들어있는 이유다.
- **SLE_BCI 의 `python3` 패키지(3.6.15)는 `node-gyp` 를 돌리기엔 너무 오래됐다** —
  네이티브 애드온(`odbc`·`argon2`·`bcrypt`) 컴파일에는 Python 3.8 이상이 필요한데, 3.6
  에서는 `node-gyp` 가 내장한 `gyp` 가 walrus 연산자에서 `SyntaxError` 로 죽는다.
  `source.Dockerfile` 의 백엔드 빌더는 `python313` 을 설치하고 `/usr/bin/python3` 로
  심볼릭 링크한다(SLE_BCI 에는 이를 자동으로 해줄 `update-alternatives` 가 없다).

### 예외 — `@infisical/quic` (Rust 네이티브 애드온)

Gateway/QUIC 전송에 실제로 필요한 프로덕션 의존성이고, 미리 컴파일된 플랫폼별 바이너리로
npm `optionalDependencies` 를 통해 배포된다(Rust 툴체인 불필요). 문제는 이미 **가장 최신
공개 버전(1.0.8, 2025-03 배포)에 고정돼 있는데 그 버전 자체가 CVE 3건(CRITICAL 1·HIGH
2, `shlex`·`quiche`)을 여전히 갖고 있다는 것** — 올릴 상위 버전이 없다. 실제로 고치려면
Infisical 자신의 Rust 소스에서 이 애드온을 재빌드해야 하는데, 이 레포에는 아직 Rust/
napi-rs 빌드 패턴이 없다. `cve-exceptions.json` 에 예외로 등록했다 — 근거: 업스트림 자체
패키지, 새 버전 없음, 재빌드하려면 이 레포에 없는 새 툴체인이 필요함.

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=infisical BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=infisical BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

이 이미지의 `verify.sh` 는 이 레포의 다른 단일 바이너리 자체 빌드들과 다르다 — 앱이
필요로 하는 것이 Postgres·Redis 뿐이라 실제로 그 둘을 임시 컨테이너로 띄우고 이미지를
그 위에서 실제로 기동해, 업스트림 Helm 차트의 readiness probe 가 쓰는 것과 같은
`/api/status` 엔드포인트가 200 을 낼 때까지 기다린다. 부팅 시 자동 실행되는 마이그레이션
(`auto-start-migrations.ts`)이 실제 Postgres 를 상대로 끝까지 도는 것 자체가 npm
`overrides` 강제 상향이 의존성 해석이나 런타임을 깨지 않았다는 실질적 검증이다.

결과는 `/tmp/out/cve-gate.md` 로 확인한다. 게이트가 PASS 여도 `/tmp/out/trivy-reports/*.json`
의 `CoverageProbe` 가 `ok` 인지 함께 확인한다. 자세한 판정 로직은
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 프론트엔드(공식 node) + 백엔드(SUSE BCI) 빌더, SUSE BCI(`bci-base`) 최종 스테이지 |
| `source.build.env` | pinned commit·버전·빌더 이미지 태그·npm `NPM_DIRECT_UPGRADES`/`NPM_OVERRIDES` 목록. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 실제 Postgres+Redis 를 띄워 이미지를 기동하고 `/api/status` 를 폴링하는 기능 검증 |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
<registry>/infisical:v0.164.1-security-hardened-20260831
                      └  app  ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

## 아직 안 된 것 — 배포 검증

`verify.sh` 는 독립된 Postgres/Redis 를 상대로 서버가 뜨고 마이그레이션이 도는 것까지
확인하지만, `infisical-secrets-operator` 와 함께 실제 Kubernetes 클러스터에 설치해
`InfisicalSecret` 이 실제로 시크릿을 동기화하는지는 아직 별도로 검증하지 않았다.
