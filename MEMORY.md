# 현재 상태 · 미결

작업을 이어받을 때 여기서 시작한다.

- 구조·설계 원칙 → [CLAUDE.md](CLAUDE.md)
- 이미지 작성 규칙 → [docs/image-authoring/](docs/image-authoring/README.md)
- CI 동작 → [docs/image-authoring/ci.md](docs/image-authoring/ci.md)

---

## 이 파일의 유지 규칙

**지금 시점의 상태와 다음에 할 일만 담는다.** 완료된 작업의 경위는 담지 않는다 — 커밋
메시지·`images/<image>/README.md` 가 이미 권위 있는 기록이다.

항목이 "다음에 할 일" 이 아니게 되면 다음 중 하나로 내보내고 여기서 지운다.

| 성격 | 목적지 |
|---|---|
| 재발 방지 교훈 | [docs/image-authoring/](docs/image-authoring/README.md) |
| 후보를 비교해 하나를 고른 근거 | [docs/decisions/](docs/decisions/) |
| 시스템이 어떻게 동작하는지 | [docs/image-authoring/ci.md](docs/image-authoring/ci.md) 등 해당 문서 |
| 단순 완료 기록 | 삭제 |

공개 저장소가 된 뒤로는 **추적이 필요한 항목은 GitHub Issue 로 올린다** — 이 파일은
이슈로 만들기 전 단계의 작업 메모용으로만 쓴다.

## 열린 항목

- **Go 모듈 CVE 두 건(CVE-2026-56854 `x/crypto` CRITICAL, CVE-2026-84304 `grpc` HIGH)이
  게시된 이미지들을 막고 있고, 자동 수정 배관을 2026-09-04에 수동 `workflow_dispatch`로
  실전 테스트했다** ([ADR 0012](docs/decisions/0012-go-cve-autofix-pr.md)).
  결과: `argocd`·`kyverno`·`kyverno-cli`·`kyvernopre`·`background-controller`·
  `cleanup-controller`·`reports-controller` 7개가 `autofix/go-cves` 브랜치로 올바르게
  라우팅됐고, 그중 6개(`argocd` 제외)는 검증 빌드에서 바로 게이트 PASS. `argocd`는
  `x/crypto`→`x/net`→`x/text` 로 이어지는 3단 버전 제약이 걸려 로컬에서 직접
  `x/net@0.57.0`·`x/text@0.41.0`까지 추가로 올려 PASS 확인, `main`에 반영함(자동
  파생값은 최소치라 이런 연쇄가 나올 수 있다는 것을 실측으로 확인 — README에 이미
  일반 패턴으로 기록돼 있었음). `etcd`·`apisix-ingress-controller`·`cloudnative-pg`
  3개는 이전에 이미 게이트 PASS 확인해 `main`에 반영돼 있었고, 오늘 rescan이 이 셋을
  "핀은 맞고 빌드만 낡음"으로 정확히 재분류해 리빌드 대상으로 잡았다.

  **버그 두 개를 이 실행에서 찾아 고쳤다**: (1) org 정책("Allow GitHub Actions to create
  and approve pull requests")이 꺼져 있어 `gh pr create`가 실패 — PR은 사람이 직접 열어야
  한다(org admin이 Settings → Actions → General → Workflow permissions 에서 켤 수 있으면
  자동화됨). (2) 그 PR 생성 실패가 `set -e` 기본 동작으로 뒤에 있던 리빌드 dispatch
  스텝까지 통째로 건너뛰게 만들었음 — `continue-on-error`/`if: always()`로 두 경로를
  독립시킴.

  **다음 할 일**: `gh pr create --base main --head autofix/go-cves` 로 PR을 사람이 직접
  연다(브랜치·검증 빌드는 이미 존재). 남은 이미지(`kyverno` 5종·`infisical-secrets-operator`)
  는 다음 rescan(자동 03:00 KST, 또는 수동 dispatch)이 이번에 고친 배관으로 리빌드
  dispatch를 실제로 낼지 확인. PR 머지 후 `workflow_dispatch(push=true)` 로 재게시.

- **`infisical` 은 게시 완료됐다** — `docker.io/paasup/infisical:v0.164.1-security-hardened-20260903`
  (digest `sha256:144b06c8f2437c9a2afcde8677e9b9395797ce8e3b255af47fa36b8fa4520853`),
  `published.json`·`sboms/infisical.cdx.json` 반영 확인됨. 근거는
  [ADR 0011](docs/decisions/0011-infisical-self-build.md). 남은 다음 할 일: dip-catalog 쪽에서
  `catalog/image-map/infisical.env`를 추가해 `infisical-standalone` 차트의 태그를 반영한다
  (현재 v0.158.0 고정 — 이 이미지는 v0.164.1 기준이라 차트 쪽도 같이 올려야 함, 6개 마이너
  차이라 브레이킹 체인지 여부 검토 필요). 배포 검증(`infisical-secrets-operator`와 함께 실제
  클러스터에 설치해 `InfisicalSecret` 동기화 확인)도 아직 별도로 하지 않았다.
- **`infisical-secrets-operator` 자체 빌드 레시피가 로컬에서 게이트 PASS(0/0 effective
  C/H)·`CoverageProbe: ok`까지 확인됐고 아직 커밋·PR 전이다.** 근거는
  [ADR 0010](docs/decisions/0010-infisical-secrets-operator-self-build.md). 다음 할 일:
  PR 열기 → 머지 → `workflow_dispatch(push=true)`로 실제 게시 → `published.json`에 반영
  확인. 게시되면 dip-catalog 쪽에서 `catalog/image-map/infisical-secrets-operator.env`를
  추가해 `secrets-operator` 차트(`manifests/helm/secrets-operator/0.11.8/`)의 태그를
  반영한다. 배포 검증(실제 클러스터에 `infisical-standalone`과 함께 설치해
  `InfisicalSecret` 동기화 확인)도 아직 별도로 하지 않았다.
- **kyverno 7개 이미지(`kyverno`·`kyverno-cli`·`kyvernopre`·`background-controller`·
  `cleanup-controller`·`reports-controller`·`readiness-checker`) 자체 빌드 레시피가
  로컬에서 전부 게이트 PASS·`CoverageProbe: ok`까지 확인됐고 아직 커밋·PR 전이다.**
  근거는 [ADR 0009](docs/decisions/0009-kyverno-self-build.md). 다음 할 일: PR 열기 →
  머지 → `workflow_dispatch(push=true)`로 실제 게시 → `published.json`에 7개 항목
  반영 확인. 게시되면 dip-catalog 쪽에서 `catalog/image-map/`에 7개 매핑을 추가해
  카탈로그 태그를 반영한다.
- **`cnpg-postgresql` 이 18.4 로, 유지보수 라인 안에서 18.6 보다 뒤진다.** 라인 자체는
  2030-11-14 까지 유지되므로 급하지 않다(support-line 검사에서 notice, 실패 아님). 올릴
  때 메이저가 `APP_VERSION`·`PG_VERSION`(EVR)·`EXTENSIONS` 세 곳에 중복돼 있는 것을 함께
  정리한다 — 이는 PG 17 병행 발행의 선행 조건이기도 하다
  ([support-policy.md](docs/image-authoring/support-policy.md) 참고).
