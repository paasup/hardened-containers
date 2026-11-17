# infisical — 자체 빌드

[English](README.md) · 한국어

Infisical 백엔드(`infisical/infisical`, secrets-operator 와 짝을 이루는 standalone 서버)
바이너리를 업스트림 소스에서 직접 컴파일한다. 이 이미지가 어느 차트·환경에서 쓰이는지,
태그를 어떻게 반영하는지는 이 레포가 모른다 — 이 레포는 "이미지를 어떻게 만드는가"만
다룬다.

> 이 이미지는 Infisical 을 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 후보 비교·받아들인 비용은
[ADR 0011](../../docs/decisions/0011-infisical-self-build.md), 이미지 선정 규칙과 빌드
프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가 갖는다.

## 왜 자체 빌드하는가

`infisical/infisical` 은 `v0.158.0` 으로 쓰이고 있었고, 자체 빌드를 시작한 시점의 업스트림
최신은 `v0.164.1` 이었다. 그때 최신 태그 기준으로 실측한 차단 CVE 는 두 층으로 나뉘었고,
이 구조는 지금도 그대로다.

- **OS 패키지 층(Debian, `node:*-trixie-slim`).** 업스트림 스스로도
  `Dockerfile.standalone-infisical` 안에서 특정 Debian 패키지를 버전 핀으로 수동
  업그레이드하며 이 문제와 싸우고 있다(`apt-get install ... libc6=... libssl3t64=...`,
  릴리스마다 목록이 늘어난다). 베이스를 SUSE BCI 로 교체하면 이 층 전체가 해소된다 — Debian
  패키지 자체가 이미지에 존재하지 않게 되기 때문이다.
- **애플리케이션 의존성 층(Node/Go/Rust).** 상위 태그를 따라가는 것이 가장 큰 지렛대다 —
  업스트림이 의존성을 자주 올리므로, 남는 것만 npm 강제 상향으로 막는다(아래 "업스트림과의
  차이"). Go 사이드카는 빼서 없앴다(아래 표).

이 이미지는 지원 라인의 최신 태그(`APP_VERSION`, 지금은 `v0.167.11`)를 따라간다 — 업스트림은
유지보수 브랜치 없이 최신 태그 하나만 지원한다(`image.env` 의 `SUPPORT_NOTE`).

정확한 CVE 목록·건수는 `scan-image.sh`/`image-gate.py` 가 매 빌드마다 다시 낸다 — 아래
"빌드·검증" 절 참고.

## 업스트림과의 차이

### 뺀 것 — 각각 업스트림 소스로 직접 확인 후 결정

| 항목 | 왜 빼도 되는지 |
| --- | --- |
| Oracle Instant Client | `oracledb` 는 기본이 thin 모드(순수 JS, 클라이언트 불필요). `initOracleClient()` 는 OracleDB wallet mTLS 연결일 때만 호출되고, 실패해도 catch 되어 그 기능만 못 쓴다(`sql-connection-fns.ts`) |
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

Go 사이드카는 업스트림도 `v0.167.0` 부터 이미지에 넣지 않는다 — 위 표의 그 행은 이제
업스트림과의 차이가 아니라 같은 상태다.

### 런타임 Node — 업스트림은 26, 이 이미지는 SLE `nodejs24`

| 항목 | 업스트림 | 이 이미지 |
| --- | --- | --- |
| 런타임 Node | `node:26.12.1-trixie-slim` 의 Node 26 (`backend/package.json` 이 `engines.node >=26.0.0` 선언) | SLE_BCI 15.7 의 OS 패키지 `nodejs24` (24.22.1) |
| 백엔드 빌드의 `npm` | Node 26 번들 npm | SLE 의 `npm24` (11.19.1 — 업스트림의 `engines.npm >=11.10.0` 충족) |

업스트림은 `v0.166.1` 부터 Node 26 으로 올라갔지만, **SLE_BCI 는 15.7 에도 16.0 에도
`nodejs26` 패키지가 없다**(둘 다 `nodejs22`·`nodejs24` 까지, 2026-11-17 실측). 비교한 후보:

- **SLE `nodejs24` 로 실행 — 채택.** 런타임 Node 를 벤더가 패치하는 OS 패키지 경로에 두는
  규칙([builder-languages.md](../../docs/image-authoring/builder-languages.md) "Node")을
  지킨다. `engines` 불일치는 `npm install` 에서 `EBADENGINE` 경고만 내고 막지 않는다.
  Node 26 업그레이드 커밋(`6409dce`)의 런타임 코드 변경은 빌드 도구 교체(tsup→tsdown,
  ts-node→tsx)와 타입 정리였고 Node 26 전용 런타임 API 도입은 보이지 않았다 — 다만 이건
  읽어서 확인한 것이고, 실제 근거는 `verify.sh` 가 이 이미지로 관리자 부트스트랩부터 시크릿
  쓰기·읽기까지 돌려 통과한다는 것이다.
- **nodejs.org 의 Node 26 tarball 을 BCI 위에 직접 설치 — 기각.** 체크섬 검증은 가능하지만
  런타임 Node 가 OS 패키지 갱신 경로를 벗어나 핀을 사람이 계속 올려야 하고, 스캐너가 이를
  OS 패키지가 아닌 바이너리로 본다.
- **Node 22 시절 태그(`v0.164.1`)에 머물기 — 기각.** 지원 라인(최신 태그)을 벗어나고,
  `@infisical/quic` 의 수정 불가 CVE 3건(아래)을 예외로 계속 끌고 가야 한다.

**전환 조건**: SLE_BCI 가 `nodejs26` 을 내면 `NODEJS_PKG`·`NODEJS_DEVEL_PKG`·`NPM_PKG` 를
그쪽으로 옮긴다. 그 전에 업스트림이 Node 24 에 없는 API 를 쓰기 시작하면 `verify.sh` 가
잡아야 한다 — 거기서 깨지면 이 결정을 다시 연다. 결정 기록: [ADR 0013](../../docs/decisions/0013-infisical-runtime-node24.md).

### 빌더 스테이지 — 백엔드만 SUSE BCI

| 스테이지 | 업스트림 | 이 이미지 | 이유 |
| --- | --- | --- | --- |
| 프론트엔드 빌더 | 공식 `node` 이미지 | 동일(공식 `node` 이미지, 업스트림과 같은 태그) | 산출물이 정적 Vite 에셋뿐이라 네이티브 바이너리·ABI 문제가 없다 — 평소 기본값(공식 언어 이미지) 그대로 |
| 백엔드 빌더 | 공식 `node` 이미지(Debian) | `registry.suse.com/bci/bci-base`(최종 스테이지와 동일 베이스) + `gcc14-c++` | 백엔드 프로덕션 의존성에 네이티브 Node 애드온(`argon2`·`bcrypt`·`odbc`·`pkcs11js`)이 있다. Debian 에서 컴파일해 SUSE BCI 에서 실행하면 glibc ABI 불일치 위험이 있다 — [builder-languages.md](../../docs/image-authoring/builder-languages.md) 의 C/Lua 규칙("빌더와 최종 스테이지를 같은 베이스로 유지하고 동적 링크")을 네이티브 Node 애드온에도 적용했다 |

백엔드 빌더에서 실측한 함정 두 가지:

- **SLE_BCI 의 `python3` 패키지(3.6.15)는 `node-gyp` 를 돌리기엔 너무 오래됐다** — 3.6 에서는
  `node-gyp` 가 내장한 `gyp` 가 walrus 연산자에서 `SyntaxError` 로 죽는다. `python313` 을
  설치하고 `/usr/bin/python3` 로 심볼릭 링크한다(SLE_BCI 에는 `update-alternatives` 가 없다).
- **SLE 15 의 기본 `gcc-c++` 는 GCC 7 이라 Node 24 헤더가 요구하는 `-std=gnu++20` 을 모른다**
  (`pkcs11js` 컴파일이 `unrecognized command line option '-std=gnu++20'` 로 실패). Node 22
  시절엔 드러나지 않던 문제다. `gcc14-c++` 를 설치하고 `CC`/`CXX` 로 지정한다
  (`BUILDER_GCC_VERSION`). 런타임의 `libstdc++6` 는 16.x 라 GCC 14 로 만든 애드온의 심볼을
  그대로 해석한다.

### 강제 상향한 Node 의존성(`NPM_DIRECT_UPGRADES` + `NPM_OVERRIDES`)

`v0.167.11` 은 업스트림 자신의 lockfile 이 이전에 강제 상향하던 패키지 대부분을 이미 수정
버전으로 올려 두었다. 그래서 목록을 빈 상태에서 다시 실측해 쌓았다 — 옛 목록을 그대로 두면
`NPM_OVERRIDES` 가 정확한 버전으로 고정하는 탓에 업스트림이 이미 올린 패키지를 **도리어
내린다**(예: 옛 핀 `undici@7.29.0` vs 업스트림 lockfile `7.30.1`). 지금 남은 건 MEDIUM/LOW 를
같은 메이저 안에서 고치는 세 개뿐이다(값과 이유는 `source.build.env`).

| 패키지 | 업스트림 lockfile | 이 이미지 |
| --- | --- | --- |
| `node-forge` | 1.4.2 | 1.4.3 |
| `fast-xml-parser` | 5.7.2 | 5.12.x |
| `@opentelemetry/instrumentation-http` | 0.220.0 | 0.222.0 |

값은 trivy 의 `FixedVersion` 에서, **설치된 메이저 라인 안의** 최소 수정 버전으로 뽑는다.
Go 쪽 강제 업그레이드에는 없는, 실제 빌드 실패로 실측한 npm 함정들:

- **npm 은 직접 의존성인 패키지를 `overrides` 로 덮어쓰는 걸 거부한다**(`npm error
  EOVERRIDE`). 그래서 목록이 둘이다 — `NPM_DIRECT_UPGRADES` 는 `dependencies` 자체를 올리고
  다른 패키지가 끌어오는 *중첩* 사본까지 맞추려 자기 참조 `overrides[pkg]["."]` 도 같은
  범위로 넣는다(EOVERRIDE 검사는 semver 가 아니라 **문자열 일치**라 `^` 까지 같아야 한다).
  `npm pkg set` 뒤에는 `npm ci` 가 lockfile 불일치로 거부하므로(`EUSAGE`) `npm install` 을 쓴다.
- **업스트림 `package.json` 이 이미 그 패키지를 문자열로 override 하고 있으면
  `overrides[pkg]["."]` 를 넣을 수 없다**(`npm error EOVERRIDEVALUE` — `fast-xml-parser` 가
  그렇다). 이때는 그 문자열 override 를 같은 범위로 교체한다. 루프는 `set -e` 로 돈다 — 전에는
  루프 중간의 `npm pkg set` 실패가 조용히 삼켜질 수 있었다.
- **중첩 의존성 하나를 강제로 올리면, 그걸 일부러 낮춰 쓰던 다른 패키지가 깨질 수 있다**
  (실측: 이전 태그에서 `uuid` 만 올렸더니 `oci-common` 의 옛 `uuid/v1` 서브패스 import 가
  `ERR_PACKAGE_PATH_NOT_EXPORTED` 로 부팅을 깨뜨렸다 — `verify.sh` 가 잡았다).
- 두 목록은 **백엔드 두 스테이지에만** 적용된다. 프론트엔드는 업스트림 lockfile 그대로
  `npm ci` 하며, 산출물이 정적 에셋뿐이라 최종 이미지 SBOM 에 잡히지 않는다.

### 해소된 예외 — `@infisical/quic` (Rust 네이티브 애드온)

`v0.164.1` 에서는 미리 컴파일된 `@infisical/quic` 1.0.8(Gateway v1 의 QUIC 전송)이 번들한
`quiche` 0.18.0·`shlex` 1.1.0 의 CVE 3건(CVE-2024-58266 CRITICAL, CVE-2025-7054·CVE-2024-1765
HIGH)을 고칠 수 없어 `cve-exceptions.json` 예외로 받아들였다(그 패키지의 최신 버전이었고,
`js-quic` 를 `quiche` 0.24 로 올리려면 Rust 소스 패치가 필요했다 — 조사 기록은
[ADR 0011](../../docs/decisions/0011-infisical-self-build.md) 과 이 파일의 git 이력).

**업스트림이 `v0.165.13` 에서 Gateway v1 을 폐기하며 이 의존성을 뺐다**("deprecate gateway
v1"). `v0.167.11` 의 lockfile 에도, 이 이미지의 SBOM 에도 `@infisical/quic`·`quiche`·
`shlex` 가 없다. 즉 이 세 건은 예외로 받아들인 것이 아니라 **릴리스 상향으로 실제 해소됐다**.
2026-11-07 에 만료된 해당 예외 항목은 갱신할 이유가 없다.

## 버전 관리

**자동 추적되지 않는 핀** — 사람이 `source.build.env` 를 고쳐 PR 을 여는 것 자체가 갱신
트리거다(`suggest-go-upgrades.py` 같은 반자동 도구도 없다).

| 키 | 무엇 | 언제 올리나 |
| --- | --- | --- |
| `APP_VERSION`·`SOURCE_COMMIT` | 업스트림 태그와 그 커밋 | 새 태그가 나오면 — 최신 태그만 지원되므로 미루면 지원 라인을 벗어난다 |
| `NODE_BUILDER_TAG` | 프론트엔드 빌더 | 업스트림 `Dockerfile.standalone-infisical` 의 `node:` 태그를 따른다 |
| `NODEJS_PKG`·`NODEJS_DEVEL_PKG`·`NPM_PKG` | 런타임/빌드 Node | SLE_BCI 에 `nodejs26` 이 생기면(위 "런타임 Node") |
| `BUILDER_GCC_VERSION` | 백엔드 애드온 컴파일러 | 빌드가 요구할 때만 |
| `NPM_DIRECT_UPGRADES`·`NPM_OVERRIDES` | 강제 상향 목록 | 태그를 올릴 때마다 **빈 목록에서 다시 실측** — 업스트림 lockfile 이 이미 앞섰는지 먼저 본다 |

**예외**: 지금 이 이미지에 적용되는 `cve-exceptions.json` 항목은 없다. 위 표의 상향과 태그
교체로 고친 것과, 예외로 받아들인 것은 다르다 — 이번 빌드 기준 후자는 0건이다.

**미룬 것(Deferred)**: `glob` 10.5.0(CVE-2026-118773)·`minimatch` 9.0.9(CVE-2026-118764),
둘 다 MEDIUM. 수정 버전이 `glob` 14·`minimatch` 11 뿐이라 메이저를 넘어야 하는데, 업스트림이
`overrides.glob = ^10.5.0` 으로 일부러 10 에 묶어 두었고 `rimraf@3`·`@octopusdeploy/api-client`
가 glob 7·8 API 를 쓴다. 업스트림이 이 override 를 풀면 다음 재빌드에 따라간다.

**자체 빌드를 그만두는 조건**: 업스트림 이미지가 Debian 베이스인 한 OS 패키지 층이 남으므로,
업스트림이 이 레포의 기준을 통과하는 베이스로 옮기기 전에는 해당하지 않는다.

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=infisical BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=infisical BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

이 이미지의 `verify.sh` 는 이 레포의 다른 단일 바이너리 자체 빌드들과 다르다 — 앱이 필요로
하는 것이 Postgres·Redis 뿐이라 그 둘을 임시 컨테이너로 띄우고 이미지를 실제로 기동한다.

1. 업스트림 Helm 차트의 readiness probe 와 같은 `/api/status` 가 200 을 낼 때까지 기다린다 —
   부팅 시 자동 마이그레이션이 실제 Postgres 를 상대로 끝까지 돌았다는 뜻이다.
2. 새 인스턴스에서 운영자가 처음 하는 일을 그대로 한다 — `/api/v1/admin/bootstrap` 으로 관리자·
   조직·머신 아이덴티티를 만들고(비밀번호 해시 — 네이티브 애드온), 그 토큰으로 프로젝트를
   만들고, 시크릿을 쓰고 다시 읽어 값이 같은지 본다(KMS 봉투 암호화 경로). Node 26 대신
   `nodejs24` 로 돌리는 결정(위)의 실질적 근거가 이 단계다.

결과는 `/tmp/out/cve-gate.md` 로 확인한다. 게이트가 PASS 여도 `/tmp/out/trivy-reports/*.json`
의 `CoverageProbe` 가 `ok` 인지 함께 확인한다. 자세한 판정 로직은
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 프론트엔드(공식 node) + 백엔드(SUSE BCI) 빌더, SUSE BCI(`bci-base`) 최종 스테이지 |
| `source.build.env` | pinned commit·버전·빌더 이미지 태그·npm `NPM_DIRECT_UPGRADES`/`NPM_OVERRIDES` 목록. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 실제 Postgres+Redis 를 띄워 이미지를 기동하고, `/api/status` 확인 뒤 관리자 부트스트랩→프로젝트 생성→시크릿 쓰기·읽기까지 도는 기능 검증 |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
<registry>/infisical:v0.167.11-security-hardened-20261117
                      └  app   ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```

## 아직 안 된 것 — 배포 검증

`verify.sh` 는 독립된 Postgres/Redis 를 상대로 서버가 뜨고 API 로 시크릿을 주고받는 것까지
확인하지만, `infisical-secrets-operator` 와 함께 실제 Kubernetes 클러스터에 설치해
`InfisicalSecret` 이 실제로 시크릿을 동기화하는지는 아직 별도로 검증하지 않았다.
