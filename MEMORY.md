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

- **`published.json` 의 `digest` 가 비어 있다.** 기존 태그로 초기값을 채웠고, 이 레포가
  아직 그 이미지들을 다시 push 하지 않아 digest 를 확인하지 못했다. 다음 발행 빌드가
  채운다. (빈 digest 를 "발행됨"으로 기록하던 원인은 해소됐다 — 이제 push·digest 확인에
  실패하면 빌드가 비0으로 끝나고 발행 기록도 갱신되지 않는다.)

- **아직 발행된 이미지에 서명·attestation 이 없다.** 서명·SBOM·게이트 판정 증명을 붙이는
  경로는 들어갔지만(`build-hardened-image.sh` 푸시 블록), `published.json` 에 적힌 현재
  태그들은 그 경로가 생기기 전에 push 된 것이다. 다음 발행 빌드부터 붙는다.
