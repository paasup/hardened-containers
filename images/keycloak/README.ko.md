# keycloak — 자체 빌드

[English](README.md) · 한국어

업스트림 Keycloak 배포본(tar.gz)을 SUSE BCI rootfs 위에 재패키징하고, 배포본에 정적으로
들어 있는 취약 jar 를 수정 버전으로 교체한다.

> 이 이미지는 Keycloak 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

신규 자체 빌드 이미지 추가 절차 전반은
[docs/image-authoring/](../../docs/image-authoring/README.md) 참고.

채택 결정과 후보 비교·받아들인 비용(BCI 버전 선택, rootfs 구성 방식 포함)은
[ADR 0008](../../docs/decisions/0008-keycloak-self-build.md), 이미지 선정 규칙과 빌드
프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가 갖는다.

## 왜 자체 빌드하나

업스트림 `quay.io/keycloak/keycloak:26.6.4` 는 게이트에서 **차단 17건(실효 HIGH 17,
CRITICAL 0)** 이다. 계층별로 성격이 전혀 다르다.

| 계층 | 건수 | 대표 CVE | 상위 태그·베이스 OS 교체로 풀리나 |
| --- | --- | --- | --- |
| UBI9 rpm | 5 | `java-21-openjdk-headless` ×3, `libacl`, `pcre2` | 일부. 3건은 rpm 최신화로 해소 |
| 번들 jar | 12 | netty ×6, jackson ×3, postgresql-jdbc, mssql-jdbc, keycloak-services | **아니다** |

이 12건은 조치 방식이 셋으로 갈린다 — 전부 자체 빌드가 "고친" 것은 아니다: netty·
jackson·postgresql-jdbc 는 아래 "업스트림과 다른 부분"의 jar 오버레이로 실제로
교체한다. keycloak-services 5건은 버전을 26.7.1 로 올려 해소한다(아래 "그래도 버전은
26.7.1 로 올린다" 참고). **mssql-jdbc 1건은 오버레이 대상이 아니다** — 실제로는 트리비
오탐이라 `cve-exceptions.json` 의 예외로 위험을 수용했다(아래 "버전 관리" 참고).

### 상위 태그 교체를 먼저 검토한 결과 (image-authoring/README.md 체크리스트 1)

**jar 12건은 keycloak 버전을 올려도 풀리지 않는다.** keycloak `26.6.4` 와 최신
`26.7.1` 의 `quarkus.version` 이 둘 다 `3.33.2.1` 이고, Quarkus 3.33.2.1 BOM 이
`netty 4.1.135.Final` / `jackson-bom 2.21.2` 를 고정한다(실측: keycloak `pom.xml` 두
태그 비교 + `quarkusio/quarkus` `bom/application/pom.xml@3.33.2.1`). 차단 CVE 의 수정
버전은 netty `4.1.136.Final`, jackson `2.21.4` 다 — 다음 Quarkus BOM 이 올라오기 전까지
업스트림 이미지로는 방법이 없다.

**베이스 OS 교체도 jar 에는 통하지 않는다.** CVE 가 OS 패키지가 아니라 배포본에 함께
실려 있는 jar 자체이기 때문이다 — `cloudnative-pg`/`etcd` 의 정적 링크 Go 모듈과 같은
구조다.

그래서 **jar 를 직접 교체하는 자체 빌드가 유일한 수단**이다. `etcd` 이미지가
`go.work` 에 `replace golang.org/x/text` 한 줄을 넣어 해결한 것과 같은 성격의 의존성
override 이며, 오케스트레이션은 동일한
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh)
하나를 공유한다.

### 그래도 버전은 26.7.1 로 올린다

`26.6.4` 는 `26.7.1`(및 `26.6.5`)에서만 패치된 `keycloak-services` HIGH 5건에
취약하다 — CVE-2026-16102 / 16442 / 16443 / 15572 / 15573 (+ MEDIUM 2건, GitHub
Security Advisory 실측). 스캔 시점 trivy DB 에 아직 없어 게이트에 잡히지 않았을 뿐이다.

차트(`keycloakx`)는 **7.2.2 가 최신이고 그대로 둔다.** 차트의 `appVersion: 26.6.4` 는
`image.tag` 미지정 시의 기본값일 뿐이고(`templates/statefulset.yaml`
— `.Values.image.tag | default .Chart.AppVersion`), 우리는 `custom-values.yaml` 에서
태그를 명시한다. appVersion 이 26.7.1 보다 낮은 것은 codecentric 차트의 릴리스 캐던스
지연이지 차트 결함이 아니다.

## 유형과 베이스 OS

**유형: "업스트림 산출물을 다른 배포판에 재설치"** (image-authoring/README.md 두 유형 중 첫
번째). Keycloak 을 소스에서 Maven 빌드하지 않는다 — 업스트림이 릴리스한 tar.gz 를
그대로 쓰고 런타임 rootfs 만 SUSE 로 바꾼다.

| 항목 | 값 |
| --- | --- |
| 배포본 | `github.com/keycloak/keycloak/releases/download/$KEYCLOAK_VERSION/keycloak-$KEYCLOAK_VERSION.tar.gz` |
| 빌더 | `registry.suse.com/bci/bci-base:15.7` (zypper 필요) |
| 최종 rootfs 씨앗 | `registry.suse.com/bci/bci-micro:15.7` |
| 최종 스테이지 | `FROM scratch` + 위 rootfs |

### 베이스 OS 결정 배경 (image-authoring/README.md 원칙 2)

업스트림은 `ubi9` 빌더 + `ubi9-micro` 최종이다. 이 레포의 다른 자체 빌드 이미지들이
전부 SUSE BCI 이고 trivy 의 SLES 15.7 커버리지가 게이트의 `CoverageProbe`(센티널
패키지 주입 재스캔)로 양성 대조 확인돼 있어, **"업스트림과 최대한 동일하게" 보다
이미지 간 일관성을 우선**했다.

**BCI 16.0 이 나와 있지만 15.7 을 쓴다 — 최신이 이 이미지에는 더 낡았다.** 필요한
나머지 패키지는 16.0 에도 전부 있지만 JDK 가 뒤처져 있다.

| BCI | `java-21-openjdk-headless` |
| --- | --- |
| 15.7 | `21.0.12.0-150600.3.29.1` |
| 16.0 | `21.0.11.0-160000.2.1` |

`21.0.12` 가 CVE-2026-41254·CVE-2026-47063 의 수정 버전이라, 16.0 으로 갔으면 이
이미지가 없애려는 차단 CVE 2건이 그대로 남았다. **16.0 의 JDK 가 15.7 을 따라잡으면
그때 올린다** — 재측정 방법은 `suse.build.env` 주석에 있다.

### rootfs 를 왜 "씨앗" 방식으로 만드나

업스트림 `ubi-null.sh` 는 빈 installroot 에 패키지를 깔고 그 rootfs 를 `ubi9-micro`
**위에 덮는다**. 이 구조를 SUSE 에 그대로 옮기면 `bci-micro` 의 rpmdb 가 새 rpmdb 로
가려져 **micro 자체 패키지가 SBOM 에서 통째로 사라진다** — CVE 가 줄어드는 게 아니라
스캔 사각지대가 생기는 것이고, 게이트가 경고하는 "베이스 OS 교체로 수치만 낮아진 것"의
전형이다.

그래서 `bci-micro` 파일시스템을 씨앗으로 깐 뒤 그 위에 `zypper --installroot` 로
설치한다. rpmdb 가 micro 것 위에 이어 써지므로 최종 이미지의 모든 OS 패키지가 SBOM 에
잡힌다. 빌드 후 이 점을 반드시 확인한다(아래 "빌드" 절).

## 업스트림과 다른 부분

업스트림 [`quarkus/container/Dockerfile`](https://github.com/keycloak/keycloak/blob/main/quarkus/container/Dockerfile)
대비 차이는 셋뿐이다.

1. **런타임 rootfs 가 SUSE BCI** — 위 참조. 패키지 목록(`RUNTIME_PACKAGES`)은 업스트림
   이미지 SBOM 의 rpm 44종을 근거로 정했다. `sed`·`grep` 은 **없으면 안 된다** —
   `bin/kc.sh` 가 `/bin/sh` 스크립트로 `esceval()` 에서 `sed`, 인자 파싱에서 `grep` 을
   쓰는데 `bci-micro` 에는 `sed` 가 없다.
2. **취약 jar 오버레이** (`overlay-jars.sh`) — `lib/lib/main/` 의 jar 를 **파일명은
   유지하고 내용만** 수정 버전으로 바꾼다. Quarkus fast-jar 의 클래스패스가 파일명을
   그대로 참조하기 때문이다. 대상은 `suse.build.env` 의 `*_OLD`/`*_VERSION` 이 정의한다:

   | 그룹 | 대상 | 버전 |
   | --- | --- | --- |
   | `io.netty` | 패밀리 전체 17종 | `4.1.135.Final` → `4.1.136.Final` |
   | `com.fasterxml.jackson.core` | `jackson-core`, `jackson-databind` | `2.21.2` → `2.21.4` |
   | `org.postgresql` | `postgresql` | `42.7.11` → `42.7.12` |
   | `io.micrometer` | 패밀리 전체 4종 | `1.16.3` → `1.16.6` |

   netty·micrometer 는 CVE 가 붙은 아티팩트만이 아니라 **패밀리 전체**를 함께 올린다 —
   둘 다 아티팩트 간 버전 혼용이 비지원이다. jackson 은 2.21.x 안에서 호환이 보장되고
   `jackson-annotations` 는 `2.21` 로 별도 버저닝돼 있어 CVE 있는 둘만 바꾼다.

   netty·jackson·postgresql-jdbc 는 위 "왜 자체 빌드하나"의 원래 12건 집계에 있던
   항목이다. **micrometer 는 이후 스캔에서 추가로 발견돼 오버레이 대상에 들어갔다** —
   집계표를 다시 셀 때는 이 항목도 포함해서 맞춘다(아래 "버전 관리"의 집계 재검산 참고).

   위장이 아니다 — trivy 는 jar 내부 `META-INF/maven/**/pom.properties`(없으면 sha1↔GAV
   인덱스)로 버전을 판정하므로 SBOM 에는 새 버전이 정확히 잡히고, 실제 내용도 새 버전이다.
3. **`bin/client/` 제거** — `keycloak-admin-cli-<ver>.jar` 는 jackson 을 shade 로 품은
   uber-jar 라 jar 교체로 고칠 수 없다(SBOM 실측: `jackson-databind@2.21.2` 의
   FilePath 가 이 파일). 서버 JVM 이 로드하지 않는 독립 CLI(`kcadm.sh`/`kcreg.sh`)이므로
   하드닝 이미지에서는 제거했다. **업스트림 대비 유일한 기능적 차이다** — 운영에서
   `kcadm` 이 필요하면 업스트림 이미지를 별도 컨테이너로 쓴다.

`kc.sh build` 를 최종 스테이지에서 한 번 돌리는 것은 차이가 아니다 — 옵션 없는 build 는
릴리스 tar 의 사전 augmentation 상태를 그대로 재현하며, 오버레이한 jar 로 augmentation 이
실제로 통과하는지 빌드 시점에 확인하기 위한 것이다(최적화 이미지로 만드는 것이 아니다).

## 버전 관리

`APP_VERSION`/`KEYCLOAK_VERSION` 과 `*_OLD`/`*_VERSION` jar 버전은 **자동 추적하지
않는다.** 사람이 업스트림 릴리스를 보고 `suse.build.env` 를 고쳐 PR 을 여는 것 자체가
갱신 트리거다.

`overlay-jars.sh` 는 `*_OLD` 버전 jar 를 하나도 못 찾으면 **빌드를 실패시킨다.**
업스트림이 의존성을 올렸는데 스크립트가 조용히 아무것도 안 해서 "CVE 는 그대로인데
빌드는 성공" 하는 상태를 막기 위함이다.

**mssql-jdbc CVE 는 이 오버레이 대상이 아니다.** 위 "왜 자체 빌드하나"의 12건 집계에
들어 있지만, 실제로는 트리비가 `mssql-jdbc-13.2.1.jre11.jar` 하나를 파일명 잘림으로
컴포넌트 두 개로 잘못 분해한 오탐이다 — 설치본은 이미 수정 버전이다. 이미지 쪽에서
없앨 방법이 없어(mssql 드라이버는 Quarkus augmentation 에 포함돼 파일을 지우면
클래스패스가 깨진다) 레포 루트 `cve-exceptions.json` 의 `CVE-2025-59250` 예외로 위험을
수용했다 — **자체 빌드로 고친 것이 아니다.** 이 예외는 만료일이 되면 게이트가 다시
막고 재검토를 강제한다.

집계표(위 "왜 자체 빌드하나")와 오버레이 대상(위 "업스트림과 다른 부분")의 합이 항상
맞아야 한다 — 새 CVE 를 막을 때마다 양쪽을 함께 갱신한다.

**권장 점검 주기**: 게이트가 이 이미지의 차단 CVE 를 다시 보고할 때, 또는 Keycloak 이
Quarkus BOM 을 올린 릴리스를 낼 때 — **BOM 이 올라가 오버레이가 불필요해지면 해당
spec 을 제거하는 것이 이 자체 빌드를 유지하는 것보다 항상 우선이다.**

## 빌드

```sh
# 로컬 빌드 (push 없음)
IMAGE=keycloak BASE_OS=suse bash scripts/build/build-hardened-image.sh /tmp/kc-out

# 레지스트리 push 까지
IMAGE=keycloak BASE_OS=suse REGISTRY=<나의-레지스트리> \
  bash scripts/build/build-hardened-image.sh /tmp/kc-out
```

> **arm64 호스트(Apple Silicon)에서 돌릴 때**: `linux/amd64` 를 QEMU 로 에뮬레이션하므로
> `verify.sh` 의 실기동이 매우 느리다 — Quarkus augmentation 만 ~100초, 기동 전체가
> 300초를 넘을 수 있다. `verify.sh` 의 기본 대기 시간은 600초이고
> `VERIFY_BOOT_TIMEOUT` 으로 조정한다. 네이티브 amd64 러너에서는 1~2분이면 끝난다.

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.**

빌드 후 확인할 것:

1. `verify.log` 마지막 줄이 `VERIFY-OK`
2. `cve-gate.md` 의 차단 항목 — 레포 루트 `cve-exceptions.json` 에 등록된 것 외에 없는지
3. **커버리지 자가진단이 `ok`** 인지 (`none` 이면 findings 0 이 진짜 0 이 아니다 —
   `docs/image-authoring/scanner-caveats.md` "스캐너 결과를 그대로 믿지 말 것")
4. **rpmdb 마스킹이 없는지** — SBOM 의 OS 패키지 수가 `bci-micro` 단독 + 설치분에
   해당하는지. 업스트림 UBI9 이미지의 OS 패키지는 44종이었다. 한 자릿수로 떨어졌다면
   씨앗 방식이 동작하지 않은 것이므로 설계를 재검토한다.

`verify.sh` 가 확인하는 것: kc.sh 가 쓰는 셸 도구·java 21·`en_US.UTF-8` 로케일·
`Asia/Seoul` 타임존, `bin/client` 제거, **오버레이한 jar 의 내부
`pom.properties` 버전**(파일명이 아니라 내용 — trivy 와 같은 근거), 그리고 실제
`start-dev` 기동 후 OIDC discovery 응답·admin 토큰 발급·`GET /admin/realms` 까지.
외부 postgres·ingress·클러스터링은 이 스모크 테스트 범위 밖이다 — 실제 배포 검증은
별도 절차를 따른다.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `suse.Dockerfile` | 빌드 정의 — bci-base 빌더(rootfs 구성 + 배포본 전개 + jar 오버레이) + `FROM scratch` 최종 |
| `suse.build.env` | keycloak 버전·베이스 이미지·런타임 패키지·jar 오버레이 버전. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `overlay-jars.sh` | 취약 jar 교체 + `bin/client` 제거. builder 스테이지 전용(호스트에서 직접 쓰지 않는다) |
| `verify.sh` | 기능 검증. 호스트에서 bash 로 실행되며 게스트 셸 주입 + 호스트 python3 jar 검사 + 실기동을 조합한다 |
| `image.env` | 빌드 기본 변종 — `DEFAULT_BASE_OS=suse` 하나만 담는다 |

베이스 변종이 하나뿐이라 파일명이 `suse.*` 로 고정돼 있다.

### 태그

```
docker.io/paasup/keycloak:26.7.1-bci15.7-hardened-20260807
                           └ app ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```
