# apisix — 자체 빌드

[English](README.md) · 한국어

apisix(APISIX-Runtime + APISIX 애플리케이션) 전체를 업스트림 소스에서 SUSE BCI 위에
직접 컴파일한다.

> 이 이미지는 Apache APISIX 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

채택 결정과 후보 비교·받아들인 비용은 [ADR 0005](../../docs/decisions/0005-apisix-self-build.md),
이미지 선정 규칙과 빌드 프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가
갖는다.

## 왜 자체 빌드하나

업스트림 `apache/apisix:3.17.0-debian`은 이미 최신 업스트림 태그인 채로도 차단 CVE 를
갖고 있다 — 그래서 상위 태그 교체로는 해소되지 않는다. 그 CVE 는 전부 Debian 베이스 OS
패키지(libc, perl, pcre 등) 쪽이라 애플리케이션 코드가 아니라 베이스 OS 를 통째로
바꿔야 해소된다.

## 업스트림과 다르게 하는 부분 — SUSE 에 이 이미지가 없는 이유

업스트림(`apache/apisix:3.17.0-debian`)은 vanilla OpenResty 가 아니라 **"APISIX-Runtime"**
이라는 커스텀 컴파일 nginx다 — OpenSSL 3.4.1·zlib·PCRE 를 직접 빌드해 넣고,
`apisix-nginx-module`·`wasm-nginx-module`(WASM, wasmtime)·`lua-var-nginx-module`·
`lua-resty-events`·`mod_dubbo`·`ngx_multi_upstream_module`을 `--add-module`로
**컴파일 타임에 정적으로** 얹는다(`openresty -V` 출력으로 확인 가능 — 정확한 버전은
아래 "소스·버전 관리" 표). 이 조합을 배포하는 apiseven 의 빌드 파이프라인
(`api7/apisix-build-tools`)은 **Debian/RHEL(UBI9) 용 사전 빌드 패키지만** 만든다 — SUSE
용은 없다.

| 차이 | 이유 |
| --- | --- |
| 베이스 OS: Debian → SUSE BCI | 이미지 간 일관성 우선(`docs/image-authoring/README.md` 원칙 2). vanilla OpenResty 로는 대체 불가 — openresty.org 는 SLES 15.x 를 지원하지만 그 빌드엔 위 커스텀 모듈이 하나도 없다. `--add-module`은 컴파일 타임에만 바이너리에 정적으로 박히는 옵션이라 이미 컴파일된 vanilla 바이너리에 나중에 모듈을 추가할 수 없고, nginx의 "동적 모듈" 메커니즘도 이 모듈들이 그 형태로 배포되지 않아 적용되지 않는다. 이 배포는 WASM 플러그인과 `http-dubbo` 관련 기능을 공식 지원해야 해서, 모듈을 뺀 축소판으로 타협하지 않고 업스트림과 동일한 모듈 구성을 재현했다. |
| Debian/RHEL 사전 빌드 RPM/DEB 를 SUSE 에 재설치하지 않고 소스 컴파일 | glibc/openssl 심볼 버전이 안 맞아 ABI 가 깨질 위험이 있고, SUSE 자체 저장소에 대응 패키지가 없어 "같은 배포판 계열 재설치"가 성립하지 않는다. |
| Rust 툴체인을 SLE_BCI 패키지(`rust`·`cargo`)로 설치 | 업스트림은 rustup 부트스트랩 스크립트를 파이프로 실행하지만, 그러면 매 빌드마다 검증되지 않은 원격 스크립트가 실행된다 — 배포판 패키지로 대체했다(설계 원칙 7). |
| cpanm 부트스트랩 제거 | 업스트림은 OpenSSL Configure 가 요구하는 `IPC::Cmd` 를 cpanm 으로 설치하지만, SLE_BCI 의 stock perl 에 이미 있다(5.26.1 / IPC::Cmd 0.96 — 코어 모듈). 불필요한 원격 실행을 없앴다. |
| 소스 tarball 무결성 검증 추가 | zlib·PCRE·OpenSSL·OpenResty·lua-resty-limit-traffic 과 luarocks 설치 스크립트를 SHA256 으로 검증한다(`source.build.env` 의 `*_SHA256`). 이 이미지만 tarball 을 받으므로 git 커밋 SHA 같은 보장이 없기 때문이다. |
| 애플리케이션 코드·모듈 버전 | 업스트림과 100% 동일(diff 최소화 원칙) — apiseven 의 공식 빌드 스크립트(`api7/apisix-build-tools`, 태그 `apisix-runtime/1.3.6`)를 그대로 재현했다. |

## 3단계 구성

| 단계 | 목표 |
| --- | --- |
| `runtime` | OpenSSL 3.4.1·zlib·PCRE 를 `$OR_PREFIX/{openssl3,zlib,pcre}`에 직접 빌드하고, OpenResty 소스에 위 커스텀 모듈 6종을 `--add-module`로 붙여 컴파일한다. openresty.org 의 SLES 전용 `-devel` 패키지가 없어 이 경로들을 소스 빌드로 채운다. |
| `apisix-app` | `runtime`이 만든 OpenResty/LuaJIT 위에 APISIX 애플리케이션(Lua 코드 + 일부 C 확장 rock)을 `luarocks make`로 설치한다. |
| `final` | 위 두 스테이지 산출물만 깨끗한 SUSE BCI 이미지로 옮기고, 런타임에 필요한 공유 라이브러리(libxml2·libxslt·libyaml·pcre·pcre2)만 추가, non-root(`apisix`, uid 636) 설정까지 마친다. |

## 빌드할 때 알아야 할 함정

- **빌드 순서 — zlib 을 OpenSSL 보다 먼저 빌드한다.** OpenSSL 의 `zlib` config 옵션이
  컴파일 타임에 `zlib.h` 를 요구한다 — 반대 순서로 두면 `zlib.h: No such file` 로
  실패한다.
- **`lua-resty-saml`(luarocks 가 자동으로 받는 의존 rock)이 SUSE 표준 `libxml2-devel`
  (2.12.10)의 `xmlSetStructuredErrorFunc` 시그니처(콜백 인자에 `const` 추가됨)와 안
  맞아 `-Werror=incompatible-pointer-types` 로 빌드 실패한다.** rock 자체의 Makefile 이
  `-Werror` 를 하드코딩해 환경변수 `CFLAGS` 로는 못 끈다 — `apisix-app` 스테이지 안에서만
  쓰는 `gcc` 래퍼(`-Wno-error=incompatible-pointer-types` 추가)로 그 진단 하나만
  경고로 낮추고, `luarocks make` 끝나면 즉시 원복한다(다른 빌드에 영향 안 줌).
  `source.Dockerfile` 의 해당 RUN 스텝 주석 참고.
- **`ui/`(Admin 대시보드 프론트엔드)는 `apache/apisix` 저장소 자체엔 없다.** apiseven
  의 패키징 파이프라인이 별도로(Node.js/yarn 빌드) 끼워 넣는 단계라 git clone 만으로는
  재현 안 된다 — 이 배포는 이 UI 를 쓰지 않아 없으면 빈 디렉터리로 대체하고 건너뛴다.
- **`/usr/bin/apisix` 래퍼 스크립트가 내부적으로 `awk` 를 쓴다.** OpenResty 버전 파싱에
  쓰는데, `final` 스테이지에 `gawk` 를 안 깔면 "awk: command not found" 로 `apisix
  version`부터 실패한다.
- **SUSE 공유 라이브러리 패키지명은 soname 이 붙는다.** `libxml2`/`libxslt`/`pcre` 같은
  이름 그대로는 없고 `libxml2-2`·`libxslt1`·`libpcre1`·`libpcre2-8-0`·`libyaml-0-2` 다
  — `libxml2-2`/`libpcre2-8-0`/`libldap-2_4-2` 는 `bci-base` 에 기본 포함이라 명시 안
  해도 되지만, 명확성을 위해 이름 그대로 적었다.
- **`docker build --pull` 은 베이스 이미지 digest 가 바뀌면 캐시를 전부 무효화한다.**
  `build-hardened-image.sh`가 항상 `--pull` 을 쓰므로(스케줄 재빌드가 최신 베이스를
  전제하기 때문), Dockerfile 을 안 고쳤어도 SUSE BCI 태그가 그 사이 갱신되면 전체
  재컴파일(약 35분)이 발생할 수 있다 — Dockerfile 반복 수정·테스트는 `--pull` 없는
  순수 `docker build` 로 하고, 최종 검증에서만 `build-hardened-image.sh` 를 쓴다.

## 소스·버전 관리

| 항목 | 값 |
| --- | --- |
| APISIX 소스 | `https://github.com/apache/apisix.git` (태그 `3.17.0`) |
| OpenResty | `1.29.2.4` |
| OpenSSL | `3.4.1` |
| zlib / PCRE | `1.3.1` / `8.45` |
| 커스텀 모듈 | `apisix-nginx-module 1.19.5`, `wasm-nginx-module 0.7.0`, `lua-var-nginx-module v0.5.3`, `lua-resty-events 0.2.0`, `ngx_multi_upstream_module 1.3.3`, `mod_dubbo 1.0.2` |
| APISIX_RUNTIME_VER | `1.3.6` (apiseven 빌드 스크립트 버전 태그) |
| 최종 베이스 | `registry.suse.com/bci/bci-base:15.7` |

전부 `source.build.env` 에서 관리하며 **자동 추적하지 않는다.** 다른 자체 빌드 이미지와
동일하게, 사람이 업스트림 새 릴리스(또는 위 CVE 세트를 이미 해소한 버전)를 보고
`source.build.env` 를 고쳐 PR 을 여는 것 자체가 갱신 트리거다.

**권장 점검 주기**: 게이트가 이 이미지의 차단 CVE 를 다시 보고할 때, 또는
`apache/apisix`가 `3.17.1`(혹은 그 이상)을 내놓았을 때 — 그 릴리스가 위 CVE 들을
이미 해소했다면, 자체 빌드를 유지하는 것보다 그쪽으로 갈아타는 것이 항상 우선이다.

## 빌드·검증 방법

```sh
# 로컬 빌드 (push 없음)
IMAGE=apisix BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# 레지스트리에 push 까지
IMAGE=apisix BASE_OS=source REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**
`verify.sh`는 `apisix version` 출력·nginx 설정 문법(`nginx -t`)뿐 아니라, standalone
YAML 설정으로 **실제 nginx worker 를 기동**해 APISIX 라우터가 HTTP 요청에 응답하는지
(라우트 없음 → 404)까지 확인한다 — 15개 커스텀 모듈 + ~90개 Lua 플러그인(lua-resty-saml
같은 C 확장 포함) 로딩까지 실제로 거치는 유일한 방법이다.

빌드 후 확인할 것:

1. `verify.log` 마지막 줄이 `VERIFY-OK`
2. `cve-gate.md` 의 차단 항목 — 이 레포의 `cve-exceptions.json` 에 등록된 것 외에 없는지
3. **커버리지 자가진단(`CoverageProbe`)이 `ok`** 인지 — `none` 이면 findings 0건이
   진짜 0건이 아니라 스캐너에 그 배포판 데이터가 없다는 뜻이므로 게이트가 차단한다

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `source.Dockerfile` | 빌드 정의 — 3단계(runtime/apisix-app/final) |
| `source.build.env` | pinned 버전 전체(`BUILD_ARGS`에 나열한 이름만 `--build-arg` 로 전달됨) |
| `verify.sh` | 기능 검증 — 실제 nginx 기동 + HTTP 요청까지 |
| `docker-entrypoint.sh` | 업스트림 `apache/apisix-docker`(`utils/docker-entrypoint.sh`)와 동일 |

베이스 변종이 하나뿐이라 파일명이 `source.*` 로 고정돼 있다.

### 태그

```
docker.io/paasup/apisix:3.17.0-security-hardened-20260811
                        └ app  ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```
