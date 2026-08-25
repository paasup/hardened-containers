# cnpg-postgresql — CloudNativePG PostgreSQL 자체 빌드

[English](README.md) · 한국어

CNPG 오퍼레이터가 관리하는 PostgreSQL 인스턴스 이미지를 자체 빌드한다. 채택 결정과 후보
비교·받아들인 비용은 [ADR 0001](../../docs/decisions/0001-cnpg-postgresql-image.md), 이미지
선정 규칙과 빌드 프레임워크 전반은 [image-authoring/](../../docs/image-authoring/README.md) 가
갖는다.

> 이 이미지는 PostgreSQL / CloudNativePG 를 재빌드한 **비공식 배포물**이며 업스트림 프로젝트와 제휴·보증
> 관계가 없다. 상표·라이선스 고지는 [NOTICE](../../NOTICE) 참고.

## 왜 자체 빌드하는가

업스트림 `system` 태그 계열은 deprecated 됐다(in-core barman phase-out 대상). 대체 후보인
`standard` 계열은 게이트가 차단하는 CRITICAL/HIGH 를 다수 갖고 있고, 그중 다수가 배포판
차원에서 수정 버전이 없는 상태다(`unimportant`/`no-dsa`/`postponed`/미분류로 분류) — 상위
태그 교체만으로는 해소되지 않는다.

베이스 OS 를 SUSE BCI 로 바꾸면 같은 CVE 들에 대해 벤더 판정이 달라진다(SUSE 가 이미
백포트했다). 다만 findings 가 0건이라는 사실만으로는 "실제로 깨끗한지"와 "그 배포판을
스캐너가 커버하지 않는지"를 구분할 수 없다 — 이 게이트는 매 스캔마다 커버리지
자가진단(`CoverageProbe`)으로 이를 확인한다. 자가진단이 `ok` 가 아니면 findings 0건은
근거가 되지 않는다.

Ubuntu 기반 자체 빌드도 후보였으나 gid 26 이 `tape` 그룹에 선점돼 있어 `postgres` 가 그
그룹으로 동작했다 — 기능은 동작하지만 위생 문제가 있었고, 채택되지 않아 재빌드 주기 밖에
남으면서 findings 도 빠르게 늘었다. SUSE BCI 는 이 문제가 없다.

## 업스트림과의 차이

`suse.Dockerfile` 은 업스트림 CNPG(Debian/apt/PGDG-deb)를 SUSE(zypper/PGDG-rpm)로 이식한
것이다. 상세 대응 관계는 파일 상단 주석에 있다.

| 항목 | 업스트림(Debian) | 이 이미지(SUSE) | 이유 |
| --- | --- | --- | --- |
| 베이스 | `standard-trixie` 계열 (Debian) | `registry.suse.com/bci/bci-base:15.7` | 벤더 CVE 판정 차이 + gid 위생 |
| 패키지 관리자 | apt + PGDG deb | zypper + PGDG rpm | 베이스 OS 전환에 따른 필연적 차이 |
| `pg-failover-slots` 확장 | 포함 | 제외 | PGDG zypp 저장소에 패키지가 없음 |
| uid/gid | 26 (`usermod` 로 강제) | 26 (PGDG RPM 이 기본 생성) | RPM 계열 관례 — 별도 조정 불필요 |
| 바이너리 경로 | `/usr/lib/postgresql/18/bin` | `/usr/pgsql-18/bin` (호환용 심볼릭 링크 병행) | 경로를 하드코딩하는 코드가 있을 경우를 대비 |

**원칙: 업스트림 Dockerfile 과의 차이를 최소로 유지한다.** 패키지 구성·uid·확장 목록을
임의로 줄이면 오퍼레이터가 이미지에 기대하는 조건이 깨진다.

`patched` 스테이지의 `zypper update` 는 Debian 판의 `apt-get upgrade` 에 대응한다 — 베이스
이미지는 주기적으로만 재빌드되므로 배포판 아카이브보다 뒤처져 있고, 이 단계가 없으면 그
시점의 미패치 취약점이 그대로 남는다.

### 업스트림 빌드 레시피 변경 점검 (수동, 자동화 대상 아님)

`cloudnative-pg/postgres-containers` 저장소가 자체 Dockerfile 구조를 바꾸면(새 확장, 새
하드닝 단계 등) 이 포트도 따라가야 한다. 배포판이 달라(Debian vs SUSE) CI 로 의미 있는
diff 를 낼 수 없다 — **권장 점검 주기는 CNPG 마이너 릴리스마다** 업스트림 Dockerfile 을
훑어보고, 구조가 바뀌었으면 `suse.Dockerfile` 을 손으로 다시 이식하는 것이다.

## 버전 관리

`APP_VERSION`·`PG_VERSION`(PGDG 패키지의 정확한 EVR 문자열)·`BASE`·`EXTENSIONS` 는
**자동 추적하지 않는다.** 사람이 PGDG 저장소의 새 릴리스를 보고 `suse.build.env` 를
고쳐 PR 을 여는 것 자체가 갱신 트리거다. `PG_VERSION` 은 메이저.마이너만 보고 올리면
안 된다 — EVR 전체(예: `18.4-4200001PGDG.sles15.7`)가 PGDG 저장소가 실제로 배포한
값과 정확히 일치해야 `zypper install` 이 그 버전을 받는다.

업스트림 빌드 레시피 자체의 변경(새 확장, 새 하드닝 단계)을 따라가야 하는지는 위
"업스트림 빌드 레시피 변경 점검" 절 참고 — 그건 값이 아니라 `suse.Dockerfile` 구조
자체를 다시 이식해야 하는 경우다.

---

## 빌드·검증 방법

```sh
IMAGE=cnpg-postgresql BASE_OS=suse bash scripts/build/build-hardened-image.sh /tmp/out
```

수행 순서: **빌드 → 기능 검증(`verify.sh`) → SBOM → 전 심각도 스캔 → 게이트 판정.** 기능
검증을 통과하지 못하면 스캔으로 넘어가지 않는다 — CVE 0건이어도 동작하지 않는 이미지는
결과물로 인정하지 않는다.

결과는 출력 디렉토리(`/tmp/out`)의 `cve-gate.md` 로 읽는다. 확인할 것 두 가지:

- **실효 CRITICAL/HIGH 가 0인가.**
- **커버리지 자가진단(`CoverageProbe`)이 `ok` 인가.** `none` 이면 findings 0건이 진짜
  0건이 아니라 스캐너에 이 배포판 데이터가 없다는 뜻이고, 그 경우 게이트가 차단한다.

두 조건과 게이트 메커니즘 전반은 [image-authoring/](../../docs/image-authoring/README.md) 에
있다.

레지스트리에 push 하려면 `REGISTRY` 를 지정한다. 태그에는 빌드일을 넣는다 — 같은 앱
버전이라도 `zypper update` 결과가 시점마다 다르므로 롤링 태그를 피하고 빌드일을 포함한
고정 태그를 쓴다.

```
docker.io/paasup/cnpg-postgresql:18.4-bci15.7-hardened-20260729
                                   └ 앱 ─┘└ 베이스 ─┘└ 하드닝 ┘└ 빌드일 ┘
```

### 파일 구성

| 파일 | 역할 |
| --- | --- |
| `<base-os>.Dockerfile` | 빌드 정의 |
| `<base-os>.build.env` | 베이스·앱 버전·확장 목록. `BUILD_ARGS` 에 나열한 이름만 `--build-arg` 로 전달된다 |
| `verify.sh` | 기능 검증. 베이스 OS 공통 — CNPG 요구사항은 베이스와 무관하다 |
| `image.env` | 기본 베이스 OS 변종(`DEFAULT_BASE_OS`) |

베이스 OS 가 늘어도 이 구조는 그대로다 — `build-hardened-image.sh` 는 `BASE_OS` 환경변수로
`<base-os>.build.env` 를 고른다.

실제 배포 검증(클러스터에 올려 동작을 확인하는 것)은 별도 절차를 따른다.
