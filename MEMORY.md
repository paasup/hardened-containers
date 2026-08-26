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

- **`cnpg-postgresql` 이 18.4 로, 유지보수 라인 안에서 18.6 보다 뒤진다.** 라인 자체는
  2030-11-14 까지 유지되므로 급하지 않다(support-line 검사에서 notice, 실패 아님). 올릴
  때 메이저가 `APP_VERSION`·`PG_VERSION`(EVR)·`EXTENSIONS` 세 곳에 중복돼 있는 것을 함께
  정리한다 — 이는 PG 17 병행 발행의 선행 조건이기도 하다
  ([support-policy.md](docs/image-authoring/support-policy.md) 참고).
