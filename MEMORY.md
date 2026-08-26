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

- **`apisix` 가 EOL 라인(3.17)에 앉아 있다 — 3.18 로 올려야 한다.** 2026-08-20 에 3.18.0
  이 나오면서 3.17 이 같은 날 EOL 됐다(APISIX 는 최신 마이너 하나만 유지). 게이트는 PASS
  이지만 이제 이 라인에는 보안 패치가 오지 않으므로 **리빌드로는 해소되지 않는다.**
  일간 rescan 의 support-line 스텝이 매일 이 job 을 실패시킨다.
  3.18.0 은 breaking change 를 동반하므로 단순 핀 교체가 아니다:
  - 플러그인의 요청/응답 body 버퍼 기본 상한 64MiB 신설 (초과 시 거부 또는 절단)
  - `openid-connect` 가 신뢰 issuer 미확정 시 토큰 거부, `audience` 클레임 필수화,
    authorization-code 세션에서 `required_scopes` 강제
  - `Apisix-Plugins` 응답 헤더가 중복 제거 목록에서 `plugin-name#phase` 순서 목록으로 변경
  번들 컴포넌트 핀 약 14개(OpenResty·OpenSSL·PCRE 등)도 함께 재조사하고, breaking change
  마다 `verify.sh` 케이스를 추가한 뒤 `images/apisix/README.md` 를 갱신한다. ADR 은 불필요
  하다 — "라인이 EOL 이라 올렸다"는 단방향 조치라 커밋 메시지가 기록이다.

- **`cnpg-postgresql` 이 18.4 로, 유지보수 라인 안에서 18.6 보다 뒤진다.** 라인 자체는
  2030-11-14 까지 유지되므로 급하지 않다(support-line 검사에서 notice, 실패 아님). 올릴
  때 메이저가 `APP_VERSION`·`PG_VERSION`(EVR)·`EXTENSIONS` 세 곳에 중복돼 있는 것을 함께
  정리한다 — 이는 PG 17 병행 발행의 선행 조건이기도 하다
  ([support-policy.md](docs/image-authoring/support-policy.md) 참고).
