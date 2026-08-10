# 로그 수집 파이프라인

```
curl → nginx(:8000) → api (FastAPI, N replicas) → Kafka (KRaft)
```

---

## 1. 선택 이유 (Rationale)

### 요구 조건

- 초당 수만 건
- 글로벌 트래픽
- 유실 없이 적재

→ 세 조건을 동시에 만족하려면 수집과 적재를 분리해야 한다고 판단함. **큐 기반 시스템** 선택.

### 큐 기반 시스템의 장점

| 관점 | 내용 |
| --- | --- |
| **결합도 분리** | API는 큐에 위임하고 즉시 응답함. 적재 계층의 지연·장애가 클라이언트로 전파되지 않음 |
| **피크 흡수** | 업데이트·점검 종료 직후의 스파이크를 큐가 받아냄. 컨슈머는 자기 속도로 처리함 |
| **유실 방지** | Kafka는 디스크 기반 커밋 로그임. 소비 측이 죽어도 데이터는 브로커에 남고 오프셋부터 재개함 |
| **Fan-out** | 이상탐지·집계·아카이빙이 독립 컨슈머 그룹으로 소비함. 소비처 추가가 API 변경을 요구하지 않음 |
| **순서 보장** | `user_id`를 파티션 키로 사용해 유저 단위 이벤트 순서가 보장됨 |

### 타 방식을 단독 채택하지 않은 이유

**파일 기반 시스템**
- API를 replica로 확장하는 순간 로그가 인스턴스별로 파편화됨
- 인스턴스가 죽으면 아직 수집되지 않은 파일도 함께 사라짐

**DB 기반 시스템**
- API가 요청마다 직접 INSERT하면 DB 응답 시간이 곧 API 응답 시간이 됨
- DB가 죽으면 API도 함께 죽음
- 단, **큐 뒤에서 배치로 적재하는 싱크 역할로는 유효함** (4절 참고)

### 큐 중 Kafka를 택한 이유

- Redis Streams도 컨슈머 그룹·XACK을 지원하므로 정당한 대안임
- 다만 백로그가 메모리에 쌓여 트리밍 시 유실 위험이 있음
- "유실 없이"를 우선해 디스크 기반 Kafka를 택함

### 기술 선택

| 항목 | 선택 | 근거 |
| --- | --- | --- |
| 프레임워크 | FastAPI + uvicorn | ASGI 비동기. Kafka ack 대기 중에도 다른 요청을 처리함 |
| Kafka 클라이언트 | aiokafka | 동기식 kafka-python은 이벤트 루프를 블로킹함 |
| 프로세스 구조 | 1 Container = 1 Uvicorn | Gunicorn 마스터를 두면 SIGTERM 전달 경로가 길어짐. 확장은 replica로 처리함 |

---

## 2. 실행 가이드

### 사전 요구사항

- Docker Desktop (Compose v2 포함)
- 호스트에 별도 설치할 것 없음

### 명령어

```bash
docker compose up -d --build          # 기동
docker compose ps                     # 상태 확인
docker compose up -d --scale api=3    # 확장 시연
docker compose down                   # 종료 (Kafka 데이터 유지)
docker compose down -v                # 볼륨까지 삭제
```

- `kafka-init`은 토픽 생성 후 종료되는 1회성 컨테이너임. `Exited (0)`이 정상임

### 포트 구조

- api는 호스트 포트를 열지 않음 → `--scale api=N` 시 포트 충돌이 발생하지 않음
- nginx만 `8000:80`으로 노출함
- nginx가 Docker 내장 DNS(127.0.0.11)로 replica에 라운드로빈 분배함
- `proxy_pass`에 변수를 써서 요청마다 DNS를 재조회함 → 기동 후 replica를 늘려도 nginx 재시작이 불필요함

### 디렉토리 구조

```
.
├── docker-compose.yml
└── api/
    ├── Dockerfile / .dockerignore / requirements.txt
    ├── nginx/default.conf
    └── app/{main,producer,schemas,config}.py
```

---

## 3. 검증 결과

### 로그 전송

```bash
curl -i -X POST http://localhost:8000/api/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"evt-0001","user_id":"user-123","event_type":"item_purchase",
       "timestamp":"2026-08-06T12:00:00Z","payload":{"item":"sword","amount":100}}'
```

```
HTTP/1.1 200 OK
{"result":"ok","event_id":"evt-0001","topic":"game-logs","partition":2,"offset":0}
```

- 응답의 `partition`/`offset`은 브로커가 실제로 기록한 위치임
- 따라서 **200 응답 자체가 Kafka 적재 완료의 증거**임

### Kafka 도달 확인

```bash
docker exec log-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic game-logs --from-beginning --timeout-ms 5000
```

```json
{"event_id":"evt-0001","user_id":"user-123","event_type":"item_purchase","timestamp":"2026-08-06T12:00:00Z","payload":{"item":"sword","currency":"gem","amount":100},"ingested_at":"2026-08-06T10:53:05.312205+00:00"}
{"event_id":"evt-0002","user_id":"user-123","event_type":"item_purchase","timestamp":"2026-08-06T12:00:00Z","payload":{"item":"sword","currency":"gem","amount":100},"ingested_at":"2026-08-06T10:54:27.092811+00:00"}
```

- 클라이언트 `timestamp`와 별도로 서버 수신 시각 `ingested_at`이 부가됨
- 클라이언트 시계를 신뢰할 수 없으므로 지연 측정 기준은 서버 시각을 사용함

### 데이터 영속성

- `docker compose down` 후 재기동해도 위 메시지가 그대로 조회됨
- Kafka 데이터 디렉토리를 named volume(`kafka-data`)에 고정했기 때문임

### Graceful shutdown

```bash
docker compose stop api
docker compose logs api --tail 20
```

- 로그에 `kafka producer stopped (buffer flushed)`가 남음
- `docker compose ps -a`의 ExitCode가 `0`임
- → SIGTERM → lifespan shutdown → `producer.stop()` 경로가 정상 완주했음을 의미함

---

## 4. 설계 노트

### 유실 방지 장치

| 장치 | 목적 |
| --- | --- |
| `acks="all"` + `enable_idempotence=True` | 프로듀서에 고정함. 두 값은 세트 옵션이라 설정으로 열어두면 모순된 값이 주입될 수 있음 |
| `send_and_wait()` | ack 확인 후 200을 반환함. fire-and-forget보다 느리지만 전송 실패를 성공으로 오인하지 않음 |
| 전송 실패 시 **503** | 200을 주면 클라이언트가 재시도하지 않아 그 로그는 확정적으로 유실됨 |
| `/health` 503 | Producer 준비 전 503을 반환함 → nginx가 준비된 replica에만 트래픽을 보냄 |

### 파티션 설계

- auto-create를 끄고 파티션 3개로 명시적으로 생성함
- `user_id` 키 해싱으로 유저별 순서를 보장함
- 동시에 컨슈머를 3개까지 병렬로 붙일 수 있는 구조를 미리 갖춤

### 스코프 — 컨슈머·DB 적재 제외

- 과제 요구인 "큐로 받아내는 구조"는 토픽 도달로 충족되므로 의도적으로 제외함
- 확장 시 구조는 아래와 같음

| 항목 | 방식 | 효과 |
| --- | --- | --- |
| 오프셋 커밋 | `enable_auto_commit=False` → DB 적재 성공 후 수동 커밋 | 유실 방지 |
| 중복 처리 | `event_id` unique index로 중복 INSERT 무시 | 중복 방지 |

- `event_id`는 Kafka 전송 이전에 확정되므로 재소비해도 값이 동일함
- 두 장치를 합치면 at-least-once 위에서 최종 결과가 exactly-once에 준하게 됨

### 로컬 구성의 한계

- 단일 노드, RF=1, `min.insync.replicas=1`임
- 따라서 `acks=all`이 리더 확인과 동일하게 동작함
- 로컬에 브로커 3대를 띄울 수도 있으나, 동일 호스트 위의 복제는 장애 도메인이 분리되지 않아 실질 내구성을 주지 못하면서 재현 환경의 리소스 요구만 키움
- 로컬은 파이프라인과 유실 방지 계약 검증에 한정함
- 장애 도메인 분리는 프로덕션(MSK)의 **RF=3 + `min.insync.replicas=2` + `acks=all`** 조합에서 완성됨

### 그 밖의 타협점

- **`is_ready`** — start 성공 여부만 반영함. 헬스체크마다 브로커를 왕복하는 것은 그 자체로 부하이므로 택한 타협임
- **네트워크 분리** — 호스트 포트를 nginx 하나로 제한한 구성에서 추가 이득이 작아 기본 네트워크를 사용함. 프로덕션에서는 서브넷·보안 그룹으로 분리함
- **스키마 최소 검증** — 게임 로그는 업데이트마다 필드가 바뀌므로 전체 검증은 수집 서버 재배포를 강제함. 나머지는 `payload`로 통과시키고 스키마 강제는 분석 계층의 책임으로 둠

---

# AWS 구성
<img width="1212" height="1522" alt="슈퍼센트 사전과제 aws drawio (4)" src="https://github.com/user-attachments/assets/1413d949-b5c9-42f0-8e3a-73e996583871" />

