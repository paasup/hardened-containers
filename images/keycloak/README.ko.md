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

Keycloak 은 업스트림 배포본에 jar 를 정적으로 실어 내보내고, 그 버전은 Keycloak 이 따르는
Quarkus BOM 이 고정한다. 그래서 차단 CVE 가 나오면 **계층마다 해결 수단이 다르다.**

| 계층 | 해결 수단 | 상위 태그·베이스 OS 교체로 풀리나 |
| --- | --- | --- |
| OS 패키지(JDK·glibc 등) | 재빌드 시 zypper 가 최신 패치를 설치 | 예 — 베이스 OS 쪽 문제 |
| Keycloak 자체 코드(`keycloak-services` 등) | `KEYCLOAK_VERSION` 상향 | 예 — 상위 태그 |
| Quarkus BOM 이 고정한 번들 jar | 다음 Keycloak 릴리스가 BOM 을 올릴 때까지 **없음** | **아니다** |

세 번째 계층이 이 이미지를 직접 빌드하는 이유다. 베이스 OS 교체는 jar 를 건드리지 못하고
(`cloudnative-pg`/`etcd` 의 정적 링크 Go 모듈과 같은 구조), 상위 태그는 BOM 이 올라올
때만 통한다. 그 사이를 메우는 것이 jar 오버레이 — `etcd` 이미지가 `go.work` 에
`replace` 한 줄을 넣는 것과 같은 성격의 의존성 override 이며, 오케스트레이션은 동일한
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh)
하나를 공유한다. 처음 이 결론에 이른 측정(26.6.4 / 26.7.1 의 Quarkus BOM 비교)은
[ADR 0008](../../docs/decisions/0008-keycloak-self-build.md) 에 있다.

### 26.8 라인으로 옮긴다

Keycloak 은 현재 마이너 하나만 유지한다(`image.env` 의 `SUPPORT_NOTE`). 26.8.0 이
나온 2026-10-01 에 26.7 이 EOL 이 됐고 `check-support-line.py` 가 매일 실패했다.
라인 이동이므로 "핀 상향" 이 아니라 마이그레이션으로 다뤘다 — 업스트림 기준으로 실제로
바뀐 것을 먼저 확인했다.

- **컨테이너 계약은 그대로다.** 업스트림 `quarkus/container/Dockerfile` 과
  `ubi-null.sh` 는 26.7.2 와 26.8.2 사이에 한 줄도 바뀌지 않았다(여전히
  `java-21-openjdk-headless`). `bin/kc.sh` 도 바이트 단위로 같다. 따라서
  `RUNTIME_PACKAGES`·`USER`·`ENTRYPOINT` 는 손대지 않았다.
- **Quarkus 가 `3.33.3.1` → `3.40.1.1` 로 올라가면서** 기존 오버레이 대상과 rescan
  에서 새로 잡힌 jar 대부분이 base 에서 해소됐다(26.8.2 배포본 `lib/lib/main` 실측):

  | jar | 26.7.2 | 26.8.2 | 결과 |
  | --- | --- | --- | --- |
  | netty 패밀리 | `4.1.136.Final`(오버레이로 `4.1.137.Final`) | `4.1.139.Final` | 오버레이 제거 |
  | jackson-core/databind | `2.21.5` | `2.21.7` | 해소 |
  | bcprov-jdk18on | `1.84` | `1.86` | 해소 |
  | freemarker | `2.3.32` | `2.3.35` | 해소 |
  | mssql-jdbc | `13.2.1.jre11` | `13.4.0.jre11` | 아래 "버전 관리" 참고 |
  | opentelemetry-api | `1.57.0`(오버레이로 `1.62.0`) | `1.62.0` | 수정 버전 `1.67.0` 미달 — 오버레이 제거, **보류** (아래 "업스트림과 다른 부분") |
  | guava | `33.5.0-jre` | `33.6.0-jre` | 수정 버전 `33.7.2-jre` 미달 — **새 오버레이** |
  | mariadb-java-client | `3.5.9` | `3.5.10` | 수정 버전 `3.5.11` 미달 — **새 오버레이** |

- **26.8.2 자체가 Keycloak 코드 CVE 를 대량으로 고친다**(릴리스 노트의 Security fixes
  — SAML 파서 DoS, 계정 탈취, DCR 클레임 위조 등). 이 CVE 들은 trivy DB 대상이 아니라
  게이트에 잡히지 않지만 실제 위험이며, 26.7 라인에는 더 이상 백포트되지 않는다.

guava 는 차단(HIGH) 대상이고 mariadb 는 MEDIUM/LOW 지만, 차단 CVE 로 재빌드를 하는
김에 수정 가능한 항목을 함께 가져간다
([remediation-priority.md](../../docs/image-authoring/remediation-priority.md) "재빌드
단위로 비용을 센다"). opentelemetry-api(MEDIUM)도 같은 이유로 시도했지만 실기동이 깨져
보류했다 — 아래 참고.

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

**BCI 16.0 이 나와 있지만 15.7 을 쓴다.** 채택 당시 16.0 의 `java-21-openjdk-headless`
가 15.7 보다 뒤처져 있었다(비교는 ADR 0008). 2026-11 재측정에서는 둘 다
`21.0.12.1`(15.7: `21.0.12.1-150600.3.32.1`, 16.0: `21.0.12.1-160000.1.1`)로
따라잡았으므로, **16.0 으로의 이동은 이제 검토 대상이다** — 다만 이 마이그레이션에는
섞지 않았다. 베이스 OS 이동은 나머지 패키지 이름·태그 슬러그(`TAG_SLUG`)·ADR 0008 갱신을
함께 수반하는 별도 결정이다. 재측정 방법은 `suse.build.env` 주석에 있다.

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
대비 차이는 셋뿐이다. (배포본 tar.gz 를 업스트림처럼 `ADD` 로 바로 받지 않고
`suse.build.env` 에 커밋한 `KEYCLOAK_SHA256` 로 `sha256sum -c` 검증한 뒤 푸는 것은 공급망
규칙(CLAUDE.md 설계 원칙 7)에 따른 것으로, 결과물은 같다.)

1. **런타임 rootfs 가 SUSE BCI** — 위 참조. 패키지 목록(`RUNTIME_PACKAGES`)은 업스트림
   이미지 SBOM 의 rpm 44종을 근거로 정했다. `sed`·`grep` 은 **없으면 안 된다** —
   `bin/kc.sh` 가 `/bin/sh` 스크립트로 `esceval()` 에서 `sed`, 인자 파싱에서 `grep` 을
   쓰는데 `bci-micro` 에는 `sed` 가 없다.
2. **취약 jar 오버레이** (`overlay-jars.sh`) — `lib/lib/main/` 의 jar 를 **파일명은
   유지하고 내용만** 수정 버전으로 바꾼다. Quarkus fast-jar 의 클래스패스가 파일명을
   그대로 참조하기 때문이다. 대상은 `suse.build.env` 의 `*_OLD`/`*_VERSION` 이 정의한다:

   | 그룹 | 대상 | 버전 |
   | --- | --- | --- |
   | `com.google.guava` | `guava` | `33.6.0-jre` → `33.7.2-jre` |
   | `org.mariadb.jdbc` | `mariadb-java-client` | `3.5.10` → `3.5.11` |

   둘 다 단일 아티팩트이고 같은 메이저 안의 상향이다 — guava `33.7.2-jre` 가 요구하는
   `failureaccess` 는 `33.6.0-jre` 와 같은 `1.0.3` 이다.

   **opentelemetry 는 오버레이하지 않는다(보류).** `opentelemetry-api` 의 수정 버전은
   `1.67.0` 이고, 그 POM 이 `context 1.67.0` 을, `context` 가 `common 1.67.0` 을 요구해
   세 개를 함께 올려 빌드했다. augmentation(`kc.sh build`)은 통과했지만 **tracing 을 켠
   실기동이 `io/opentelemetry/api/internal/ConfigUtil` 을 찾지 못해 죽었다** — 1.67 에서
   이 클래스는 `io.opentelemetry.common.impl` 로 옮겨졌고 `InstrumentationUtil` 도
   `api.internal` 에서 빠졌는데, Quarkus 3.40.1.1 이 배포한 SDK·exporter(`1.62.0`)와
   `opentelemetry-instrumentation-api 2.28.1` 이 바로 이 `api.internal` 클래스들에 링크돼
   있다(배포본 jar 바이트코드 실측). 고치려면 SDK·exporter·instrumentation 스택 전체를
   Quarkus 확장이 빌드된 기준보다 올려야 하는데, MEDIUM 하나를 위해 그 위험을 지는 것은
   맞지 않다 — "차단 수정은 인질로 잡히지 않는다"(remediation-priority.md)에 따라 차단
   수정만으로 내보내고 이 CVE 는 **보류**한다. 다음 Keycloak 릴리스가 Quarkus BOM 으로
   OpenTelemetry 를 `1.67.0` 이상으로 올리면 해소된다. (26.7.x 의 `api` 단독 오버레이는
   tracing 을 끈 기동으로만 검증됐다 — 그래서 `verify.sh` 가 이제 tracing 을 켜고
   기동한다.)

   netty·jackson-core/jackson-databind·postgresql-jdbc·micrometer 는 한때 여기서
   오버레이 대상이었지만 Keycloak 이 Quarkus BOM 을 올리면서 base 배포본이 이미 수정
   버전을 싣게 돼 제거됐다(netty 는 26.8.2 에서, 나머지는 26.7.2 에서).

   위장이 아니다 — trivy 는 jar 내부 `META-INF/maven/**/pom.properties`(없으면 sha1↔GAV
   인덱스)로 버전을 판정하므로 SBOM 에는 새 버전이 정확히 잡히고, 실제 내용도 새 버전이다.
3. **`bin/client/` 제거** — `keycloak-admin-cli-<ver>.jar` 는 의존성(jackson 등)을
   shade 로 품은 uber-jar 라 jar 교체로 고칠 수 없다(채택 당시 SBOM 실측:
   `jackson-databind@2.21.2` 의 FilePath 가 이 파일). 서버 JVM 이 로드하지 않는 독립 CLI(`kcadm.sh`/`kcreg.sh`)이므로
   하드닝 이미지에서는 제거했다. **업스트림 대비 유일한 기능적 차이다** — 운영에서
   `kcadm` 이 필요하면 업스트림 이미지를 별도 컨테이너로 쓴다.

`kc.sh build` 를 최종 스테이지에서 한 번 돌리는 것은 차이가 아니다 — 옵션 없는 build 는
릴리스 tar 의 사전 augmentation 상태를 그대로 재현하며, 오버레이한 jar 로 augmentation 이
실제로 통과하는지 빌드 시점에 확인하기 위한 것이다(최적화 이미지로 만드는 것이 아니다).

## 버전 관리

다음 값은 **자동 추적하지 않는다** — 사람이 업스트림 릴리스를 보고 `suse.build.env` 를
고쳐 PR 을 여는 것 자체가 갱신 트리거다.

| 값 | 비고 |
| --- | --- |
| `APP_VERSION`·`KEYCLOAK_VERSION` | 둘은 항상 같다. 라인은 `image.env` 의 `SUPPORT_LINE`(`26.8`)과 맞아야 한다 |
| `KEYCLOAK_SHA256` | 버전을 올릴 때 함께 바꾼다. 내려받은 tar.gz 로 계산하고 업스트림 릴리스의 `.sha1` 자산과 교차 확인한다 |
| `GUAVA_OLD`/`GUAVA_VERSION`, `MARIADB_OLD`/`MARIADB_VERSION` | 오버레이 쌍 |
| `BUILDER_BASE`·`MICRO_BASE` | BCI 버전 — 위 "베이스 OS 결정 배경" |

`check-support-line.py` 는 라인이 EOL 인지(종료 코드 2), 라인 안에서 뒤처졌는지(1)만
알려준다. 라인 안의 패치 릴리스를 따라가는 것도 사람이 한다.

`overlay-jars.sh` 는 `*_OLD` 버전 jar 를 하나도 못 찾으면 **빌드를 실패시킨다.**
업스트림이 의존성을 올렸는데 스크립트가 조용히 아무것도 안 해서 "CVE 는 그대로인데
빌드는 성공" 하는 상태를 막기 위함이다. `KEYCLOAK_VERSION` 을 올리면 대개 이 실패가 먼저
난다 — 그때 해당 jar 의 새 base 버전이 수정 버전 이상이면 spec 을 지우고, 아니면 `*_OLD`
만 옮긴다.

**조치 내역을 섞지 않는다.** 이 이미지의 CVE 는 네 갈래로 처리된다.

- **오버레이로 고친 것** — 위 "업스트림과 다른 부분" 표의 jar.
- **Keycloak 버전 상향으로 고친 것** — 위 "26.8 라인으로 옮긴다" 표에서 base 가 해소한
  jar 와 Keycloak 자체 코드 CVE.
- **보류한 것** — opentelemetry-api 의 MEDIUM(수정 버전 `1.67.0`). 위 "업스트림과 다른
  부분" 에 이유가 있다. 다음 Keycloak 릴리스로 BOM 이 올라올 때 회수한다.
- **예외로 위험을 수용한 것** — `cve-exceptions.json` 의 `CVE-2025-59250`(mssql-jdbc).
  **자체 빌드로 고친 것이 아니다.** 트리비가 `mssql-jdbc-13.2.1.jre11.jar` 하나를
  파일명 잘림으로 컴포넌트 두 개(`13.2.1.jre11` / `13.2.1`)로 분해한 오탐이었다 —
  설치본은 이미 수정 버전이었다. 26.8.2 는 `13.4.0.jre11` 을 싣고, 26.8.2 빌드의
  게이트에서 이 CVE 는 **더 이상 매칭되지 않는다** — 트리비는 여전히 컴포넌트 두 개
  (`13.4.0.jre11` / `13.4.0`)로 분해하지만 둘 다 취약 범위 밖이다. 따라서 이 이미지에는
  예외가 필요 없다(예외 항목 정리는 예외 관리 절차의 몫이다). 분해 버릇 자체는 남아 있으니
  mssql-jdbc 버전이 바뀌면 다시 확인한다.

**자체 빌드를 그만둘 조건**: Keycloak 릴리스의 Quarkus BOM 이 모든 오버레이 대상을 수정
버전 이상으로 올리면 오버레이가 비고, 남는 차이는 SUSE BCI rootfs 와 `bin/client`
제거뿐이다. **BOM 이 올라가 오버레이가 불필요해지면 해당 spec 을 지우는 것이 이 자체
빌드를 유지하는 것보다 항상 우선이다.** 점검 시점은 게이트가 이 이미지의 차단 CVE 를
다시 보고할 때, 또는 Keycloak 이 Quarkus BOM 을 올린 릴리스를 낼 때다.

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
`pom.properties` 버전**(파일명이 아니라 내용 — trivy 와 같은 근거), 그리고
`--tracing-enabled=true` 로 실제 `start-dev` 기동 후 OIDC discovery 응답·admin 토큰
발급·`GET /admin/realms` 까지. tracing 을 켜 두므로 기동과 이 요청들이 OpenTelemetry
스택을 실제로 로드하며, 마지막에 서버 로그에 클래스 링크 오류(`NoSuchMethodError`·
`NoClassDefFoundError` 등)가 없는지 확인한다 — tracing 이 꺼진 기동은 이 스택을 건드리지
않아, 위 opentelemetry 오버레이 같은 비호환을 놓친다.
OTLP 수집기는 띄우지 않는다 — 내보내기 실패 경고는 정상이다.

확인하지 **않는** 것: mariadb 드라이버로 실제 DB 에 연결하는 경로(dev-file DB 로
기동하므로 mariadb 드라이버는 로드되지 않는다 — 오버레이한 jar 의 내용 버전과
augmentation 통과까지만 확인한다), 외부 postgres·ingress·클러스터링. 실제 배포 검증은
별도 절차를 따른다.

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `suse.Dockerfile` | 빌드 정의 — bci-base 빌더(rootfs 구성 + 배포본 전개 + jar 오버레이) + `FROM scratch` 최종 |
| `suse.build.env` | keycloak 버전·베이스 이미지·런타임 패키지·jar 오버레이 버전. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `overlay-jars.sh` | 취약 jar 교체 + `bin/client` 제거. builder 스테이지 전용(호스트에서 직접 쓰지 않는다) |
| `verify.sh` | 기능 검증. 호스트에서 bash 로 실행되며 게스트 셸 주입 + 호스트 python3 jar 검사 + 실기동을 조합한다 |
| `image.env` | 빌드 기본 변종(`DEFAULT_BASE_OS=suse`)·루트 README 분류(`CATEGORY`)·업스트림 지원 라인(`SUPPORT_*`) |

베이스 변종이 하나뿐이라 파일명이 `suse.*` 로 고정돼 있다.

### 태그

```
<registry>/keycloak:26.8.2-bci15.7-hardened-20261117
                     └ app ┘└ 슬러그 ┘└ 하드닝 ┘└ 빌드일 ┘
```
