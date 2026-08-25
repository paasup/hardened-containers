# hardened-containers

[English](README.md) · 한국어

## 구현 목적

상용 환경에 배포되는 주요 오픈소스 컨테이너 이미지의 취약점을 원천적으로 제거하여 **Zero-CVE** 상태를 달성하고, 안전하게 하드닝(Hardening)된 이미지를 생산·관리하기 위해 구축되었다.
- **Zero-CVE 보장**: 모든 이미지에 대해 알려진 취약점(CRITICAL, HIGH 등) 0건을 강제하는 게이트를 통과해야만 레지스트리에 푸시가 허용된다.
- **독립적인 완결성**: 외부 시스템 의존성 없이, 클론 후 `docker`와 `trivy`만 있으면 레포지토리 내부에서 빌드부터 기능 검증, SBOM 생성, 스캔, 게이트 판정까지 전부 끝난다.
- **결정론적 관리**: 일관된 베이스 OS(SUSE BCI) 적용 및 롤링 태그 배제를 통해, 언제든 추적 및 재현 가능한 무결점 이미지 빌드 환경을 제공한다.

## 개요

현재 8개 이미지를 다룬다: `adc`, `apisix`, `apisix-ingress-controller`, `argocd`,
`cloudnative-pg`, `cnpg-postgresql`, `etcd`, `keycloak`. 정확한 목록은 `images/` 디렉토리가
단일 출처다. 발행된 태그·다이제스트는 [published.json](published.json) 에 있다.

이 이미지들은 업스트림 프로젝트를 **비공식적으로 재빌드한 배포물**이며, 어떤 업스트림
프로젝트와도 제휴·보증 관계가 없다. 상표·라이선스 고지는 [NOTICE](NOTICE) 참고.

## 빠른 시작

```sh
git clone <이 레포>
cd hardened-containers

# 빌드 → 기능 검증 → SBOM → 스캔 → 게이트 (레지스트리 push 없음)
IMAGE=etcd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

cat /tmp/out/cve-gate.md
```

게이트가 PASS 면 `/tmp/out/trivy-reports/*.json` 의 `CoverageProbe` 가 `ok` 인지 함께
확인한다 — `none` 이면 findings 0건이 진짜 0건이 아니라 스캐너에 그 배포판 데이터가
없다는 뜻이다.

레지스트리에 push 하려면 (`REGISTRY` 를 자기 레지스트리로 바꾼다):

```sh
REGISTRY=<나의-레지스트리> IMAGE=etcd BASE_OS=source \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

## 발행된 이미지 검증

두 가지가 따로 있고, 수명과 목적이 다르다.

| | 어디에 있나 | 답하는 질문 | 조회에 서비스가 필요한가 |
|---|---|---|---|
| **SBOM** | 이 저장소의 `sboms/<image>.cdx.json` | 무엇이 들어 있는가 | 아니오 — 저장소 안에 있다 |
| **Attestation** | GitHub Artifact Attestations (다이제스트 기준) | 이 다이제스트를 정말 그 저장소의 워크플로가 만들었는가 | 예 — `gh attestation verify` |

**무엇이 들어 있는지**는 저장소에서 바로 읽는다. 만료되지 않고 diff 로 변화도 보인다.

```sh
jq '.components | length' sboms/etcd.cdx.json
```

**누가 만들었는지**는 `gh` CLI 로 확인한다. cosign 도, 공개키도 필요 없다.

```sh
REF=$(jq -r '.images.etcd.ref'    published.json)
DIG=$(jq -r '.images.etcd.digest' published.json)

gh attestation verify "oci://${REF%:*}@${DIG}" --repo paasup/hardened-containers
```

> **`--repo` 를 반드시 지정한다.** 이것이 "어느 저장소의 워크플로가 만들었는가"를 못박는
> 부분이다. 생략하면 "누군가 서명했다"까지만 확인된다.

빌드 provenance 는 SLSA 형식이고, SBOM attestation 도 함께 붙는다. 태그가 아니라
**다이제스트**에 붙는다 — 태그는 나중에 다른 이미지를 가리킬 수 있기 때문이다.

## 포크해서 쓰려면

이 저장소는 특정 레지스트리에 묶여 있지 않다. 포크한 뒤 다음을 설정한다.

1. **저장소 변수** (Settings → Secrets and variables → Actions → Variables)
   - `REGISTRY_HOST` — push 대상 (예: `docker.io/myorg`).
     **설정하지 않으면 CI 는 push 하지 않고 빌드·검증만 한다** — 설정 없이 돌렸을 때
     남의 레지스트리로 push 를 시도하지 않게 하는 안전장치다.
2. **저장소 시크릿**
   - `DOCKERHUB_USER` / `DOCKERHUB_TOKEN` — 레지스트리 인증.
3. **`published.json` 을 비운다.**
   ```sh
   echo '{"schemaVersion": 1, "images": {}}' > published.json
   ```
   `rescan.yml` 이 이 파일에 적힌 태그를 그대로 pull 해 재스캔하므로, 비우지 않으면
   포크가 원본 저장소의 이미지를 재스캔하게 된다.
4. **`cve-exceptions.json` 을 검토한다.** 예외는 "위험을 수용한다"는 기록이다. 남의
   판단을 그대로 물려받지 말고 자기 환경 기준으로 다시 판단한다.

## 알려진 한계

- **빌드는 재현 가능하지 않다.** 베이스 이미지를 다이제스트가 아니라 태그
  (`bci-base:15.7`, `golang:1.26.6-trixie`)로 참조하고 `docker build --pull` 을 쓴다.
  **의도적인 선택이다** — 매 빌드가 최신 보안 패치를 받아야 CVE 0건을 유지할 수 있고,
  다이제스트로 고정하면 그 목적과 정면으로 충돌한다. 대신 "무엇을 빌드했는가"는 발행된
  이미지의 다이제스트와 커밋된 SBOM 이 기록한다.
- **linux/amd64 전용.** 멀티아치 빌드는 아직 없다.
- **게이트 PASS 는 동작을 보증하지 않는다.** CVE 스캐너는 런타임 요구사항을 보지 못한다.
  배포 환경에서의 동작 확인은 별도로 필요하다.
- **발행 시점 판정이다.** 이후 공개된 취약점은 포함하지 않는다 — `rescan.yml` 이 매일
  재스캔하지만 시차가 있다.

## 문서

- **[docs/image-authoring/](docs/image-authoring/README.md) — 진입점**: 오케스트레이션 계약, `빌드 → 검증 → SBOM → 스캔 → 게이트 → 푸시` 파이프라인, 신규 이미지 추가 체크리스트, 두 가지 유형
  - [base-os-policy.md](docs/image-authoring/base-os-policy.md) — 베이스 OS(SUSE BCI) 선택 원칙
  - [builder-languages.md](docs/image-authoring/builder-languages.md) — 언어별 빌더 규칙 + Go 모듈 CVE
  - [scanner-caveats.md](docs/image-authoring/scanner-caveats.md) — 스캐너 결과·태그 신뢰 주의사항
  - [ci.md](docs/image-authoring/ci.md) — CI(`build-image.yml`·`rescan.yml`) 동작, 서명·증명
  - [readme-template.md](docs/image-authoring/readme-template.md) — 이미지 README.md 작성 템플릿
- [docs/architecture.md](docs/architecture.md) — 전체 파이프라인 흐름
- [docs/decisions/](docs/decisions/) — 이미지별 자체 빌드 결정 근거(ADR)
- [CONTRIBUTING.md](CONTRIBUTING.md) — 이 레포의 CI 동작(포크에서 전체 빌드가 돈다), PR 전에 돌릴 것
- [SECURITY.md](SECURITY.md) — 보장 범위, 취약점 신고
- [MEMORY.md](MEMORY.md) — 현재 상태·미결

## 라이선스

[Apache License 2.0](LICENSE) — **이 저장소의 빌드 정의·스크립트·문서**에 적용된다.

빌드 산출물 이미지에 포함된 서드파티 소프트웨어는 각자의 라이선스를 따른다. 각 이미지의
실제 구성은 그 이미지에 붙은 SBOM attestation 이 권위 있는 출처다. 상세는
[NOTICE](NOTICE) 참고.
