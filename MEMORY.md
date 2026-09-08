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

- **게시된 이미지들의 실배포 검증이 아직 없다.** 게이트 통과는 동작을 증명하지 않는다(설계
  규칙 6) — CVE 스캐너는 런타임 요구사항을 볼 수 없다. 특히 `infisical` 과
  `infisical-secrets-operator` 는 실제 클러스터에 함께 설치해 `InfisicalSecret` 동기화까지
  확인해야 하고, `infisical` 은 v0.164.1 기준이라 이전에 쓰이던 v0.158.0 과 6개 마이너
  차이가 있어 브레이킹 체인지 검토가 필요하다. 각 이미지를 자체 빌드하는 근거는
  [ADR 0009](docs/decisions/0009-kyverno-self-build.md)·
  [ADR 0010](docs/decisions/0010-infisical-secrets-operator-self-build.md)·
  [ADR 0011](docs/decisions/0011-infisical-self-build.md).
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
