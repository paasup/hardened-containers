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

- **`infisical` 은 게시 완료됐다** — `docker.io/paasup/infisical:v0.164.1-security-hardened-20260907`
  (digest `sha256:f07030a677064f682187204a8f9267d9b7288e12d15f0104f5b246599367d2b3`),
  `published.json`·`sboms/infisical.cdx.json` 반영 확인됨(이전 `...-20260903` 태그가
  npm 전이 의존성 `toml` 등의 신규 CVE로 2026-09-06 rescan에서 drift 처리되어 이 태그로
  리빌드·재게시됨 — 핀 변경 근거는 README.md/README.ko.md "강제 상향한 Node 의존성"
  절). 근거는 [ADR 0011](docs/decisions/0011-infisical-self-build.md). 남은 다음 할 일:
  이 이미지는 v0.164.1 기준인데 이전에 쓰이던 v0.158.0 과 6개 마이너 차이라 브레이킹
  체인지 여부를 검토해야 한다. 배포 검증(`infisical-secrets-operator`와 함께 실제
  클러스터에 설치해 `InfisicalSecret` 동기화 확인)도 아직 하지 않았다.
- **`infisical-secrets-operator` 자체 빌드 레시피가 로컬에서 게이트 PASS(0/0 effective
  C/H)·`CoverageProbe: ok`까지 확인됐고 아직 커밋·PR 전이다.** 근거는
  [ADR 0010](docs/decisions/0010-infisical-secrets-operator-self-build.md). 다음 할 일:
  PR 열기 → 머지 → `workflow_dispatch(push=true)`로 실제 게시 → `published.json`에 반영
  확인. 배포 검증(실제 클러스터에 Infisical 서버와 함께 설치해 `InfisicalSecret` 동기화
  확인)도 아직 별도로 하지 않았다.
- **kyverno 7개 이미지(`kyverno`·`kyverno-cli`·`kyvernopre`·`background-controller`·
  `cleanup-controller`·`reports-controller`·`readiness-checker`) 자체 빌드 레시피가
  로컬에서 전부 게이트 PASS·`CoverageProbe: ok`까지 확인됐고 아직 커밋·PR 전이다.**
  근거는 [ADR 0009](docs/decisions/0009-kyverno-self-build.md). 다음 할 일: PR 열기 →
  머지 → `workflow_dispatch(push=true)`로 실제 게시 → `published.json`에 7개 항목
  반영 확인.
- **CVE 조치 파이프라인에 구멍 4개가 남아 있다** (2026-09-08 스킬·에이전트 정비 중 코드를
  훑어 확인한 것들이다). 지금 당장 무엇을 막고 있지는 않아 여기 메모로 둔다 — 착수가
  계속 미뤄지면 이 파일의 유지 규칙대로 GitHub Issue 로 올린다.
  1. `suggest-go-upgrades.py` 가 `cve-exceptions.json` 을 읽지 않는다. 이미 승인된 예외까지
     drift 로 잡아 불필요한 autofix PR 을 낼 수 있다
     ([ADR 0012](docs/decisions/0012-go-cve-autofix-pr.md)가 한계로 적어둔 항목이고, Go
     예외가 아직 하나도 없어서 실제로 터진 적은 없다).
  2. non-Go 수동 핀(`SOURCE_COMMIT`·jar 버전·`XTEXT_FIX_VERSION`)에는 제안 스크립트가 없다.
     지금은 `pin-freshness-check` 가 `image-author` 에게 넘겨 매번 손으로 조사한다 —
     `suggest-*-upgrades.py` 형태의 두 번째 스크립트가 자연스러운 다음 단계.
  3. red 오토픽스 빌드의 제약 실패가 재제안으로 피드백되지 않는다. 빌드 로그의
     `requires X@vY` 를 사람이 읽고 다시 돌리는 수밖에 없다(연쇄 제약은 ADR 0012 에서
     실측됨).
  4. 만료된 예외의 재검토를 넛지하는 장치가 없다. `cve-gate.md` 에 한 줄 뜨는 것이 전부라
     아무도 안 보면 그대로 지나간다.

- **`cnpg-postgresql` 이 18.4 로, 유지보수 라인 안에서 18.6 보다 뒤진다.** 라인 자체는
  2030-11-14 까지 유지되므로 급하지 않다(support-line 검사에서 notice, 실패 아님). 올릴
  때 메이저가 `APP_VERSION`·`PG_VERSION`(EVR)·`EXTENSIONS` 세 곳에 중복돼 있는 것을 함께
  정리한다 — 이는 PG 17 병행 발행의 선행 조건이기도 하다
  ([support-policy.md](docs/image-authoring/support-policy.md) 참고).
