# 로그 수집 파이프라인

초당 수만 건의 인게임 로그를 유실 없이 받아내는 수집 파이프라인을, 로컬에서 그대로 재현 및 검증할 수 있도록 구성했습니다.

---

## 목차

- [1. 문제 정의](#1-문제-정의)
- [2. 서비스 흐름](#2-서비스-흐름)
- [3. Queue 선택 이유](#3-queue-선택-이유)
- [4. 유실 방지 설계](#4-유실-방지-설계)
- [5. 인프라 구성](#5-인프라-구성)
  - [5.1 Kafka 구성](#51-kafka-구성)
  - [5.2 API 수평 확장](#52-api-수평-확장)
  - [5.3 Docker 구성](#53-docker-구성)
- [6. 실행 가이드](#6-실행-가이드)
- [7. 검증](#7-검증)
  - [7.1 API → Kafka → 파일 적재](#71-api--kafka--파일-적재)
  - [7.2 API 수평 확장](#72-api-수평-확장)
  - [7.3 Consumer 장애 복구](#73-consumer-장애-복구)
- [8. AWS 아키텍처 (선택 과제)](#8-aws-아키텍처-선택-과제)
  - [8.1 설계 방향](#81-설계-방향)
  - [8.2 아키텍처 구성도](#82-아키텍처-구성도)
  - [8.3 네트워크 구성](#83-네트워크-구성)
  - [8.4 컴퓨팅 구성](#84-컴퓨팅-구성)
  - [8.5 로그 적재 구성](#85-로그-적재-구성)
  - [8.6 Terraform 구성](#86-terraform-구성)

---

## 1. 문제 정의

로그 수집 API는 짧은 시간에 대량의 쓰기 요청이 발생하고, 수집된 로그를 안정적으로 적재하는 것이 중요합니다.

| 요구사항 | 설계 방향 |
| --- | --- |
| 순간적인 트래픽 증가 | 수집과 적재를 분리할 버퍼 필요 |
| 적재 계층 장애 | API와 적재 계층 간 장애 격리 필요 |
| 로그 유실 방지 | 데이터가 실제로 적재된 시점을 성공 기준으로 정의 |
| 대량의 로그 처리 | 수평 확장 및 비동기 처리 |

이러한 요구사항을 고려해 **API → Kafka → Consumer → 파일** 구조를 선택했습니다.

---

## 2. 서비스 흐름

```
[ 게임 클라이언트 / curl ]
             │
             ▼
      ┌──────────────┐
      │ nginx :8000  │
      └──────┬───────┘
             │
      ┌──────┼──────┐
      ▼      ▼      ▼
    API #1 API #2 API #3
      └──────┼──────┘
             ▼
   ┌──────────────────────┐
   │ Kafka (KRaft 3 노드) │
   │ game-logs            │
   │ partitions=3, RF=3   │
   │ min.insync.replicas=2│
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐
   │ Consumer             │
   │ write → commit       │
   └──────────┬───────────┘
              ▼
       Named Volume
       JSONL 파일
```

모든 컴포넌트는 Docker Compose 네트워크 내부에서 통신하며, 외부에 노출되는 포트는 **Nginx의 8000 하나로 제한**했습니다.

---

## 3. Queue 선택 이유

### 3.1 Kafka를 선택한 이유

Queue 기반 구조를 선택한 이유는 **수집과 적재를 분리해 트래픽 변동과 장애를 흡수**하기 위해서입니다.

Kafka를 선택한 주요 이유는 다음과 같습니다.

- **피크 흡수** — 순간적으로 증가하는 로그를 Kafka가 버퍼링
- **장애 격리** — Consumer 장애가 API까지 직접 전파되지 않음
- **유실 방지** — Consumer 장애 발생 시에도 Kafka에 메시지가 남아 재처리 가능
- **수평 확장** — Partition 단위로 Consumer 처리량 확장 가능
- **순서 보장** — `user_id`를 Key로 사용해 동일 사용자의 이벤트를 동일 Partition에 전달

Redis Streams도 Consumer Group과 ACK를 지원하지만, 이 과제의 핵심 요구사항이 유실 방지와 메시지 보존이므로 **디스크 기반 로그 저장 구조를 사용하는 Kafka**를 선택했습니다.

Kafka는 최종 저장소가 아니라 버퍼로 사용하고, Consumer가 최종적으로 JSONL 파일에 적재하도록 역할을 분리했습니다.

---

## 4. 유실 방지 설계

로그 수집에서 중요한 것은 **어느 시점부터 로그가 유실되지 않았다고 판단할 것인지** 정의하는 것입니다.

### 📌 Producer

Kafka Producer는 다음 설정을 적용했습니다.

```
acks=all
enable_idempotence=true
```

Kafka의 복제본에 정상적으로 기록된 것을 확인한 후 API가 성공을 반환하도록 했으며, 전송 실패 시 `503`을 반환합니다. 또한 Producer를 요청마다 생성하지 않고 애플리케이션 생명주기 동안 재사용하며, 정상 종료 시 남아 있는 데이터를 flush한 후 종료하도록 구성했습니다.

### 📌 Consumer

Consumer는 **파일 저장 후 Kafka Offset을 Commit**하도록 구성했습니다.

```
Kafka → 파일 저장 → Commit
```

반대로 Commit을 먼저 수행하면 Consumer 장애 시 메시지가 재처리되지 않아 유실될 수 있습니다. 현재 구조에서는 저장 후 장애가 발생하면 동일 메시지가 다시 처리될 수 있으므로 **at-least-once** 방식으로 동작합니다. 중복 가능성은 `event_id`를 기준으로 후단에서 제거할 수 있도록 설계했습니다.

### 📌 Micro Batch

Consumer는 최대 500건 또는 1초 단위로 메시지를 묶어 파일에 기록합니다. 이를 통해 디스크 I/O와 Commit 횟수를 줄이면서, 낮은 트래픽에서는 최대 1초 수준으로 적재 지연을 제한했습니다.

---

## 5. 인프라 구성

### 5.1 Kafka 구성

Kafka Broker는 3개로 구성하고 다음과 같은 조건을 적용했습니다.

```
Partition = 3
Replication Factor = 3
min.insync.replicas = 2
acks = all
```

하나의 Broker에 장애가 발생해도 나머지 Broker로 수집을 계속할 수 있으며, **2개 이상의 Broker가 정상적으로 동기화된 경우에만 쓰기가 성공**하도록 구성했습니다.

### 5.2 API 수평 확장

API는 상태를 가지지 않는 구조로 구성해 Replica를 수평 확장할 수 있도록 했습니다. 호스트의 8000 포트는 Nginx만 사용하고 API 컨테이너는 외부에 포트를 노출하지 않습니다.

```
Host :8000
     ↓
   Nginx
  ┌──┼──┐
  ▼  ▼  ▼
 API API API
```

Nginx는 Docker 내장 DNS를 이용해 `api` 서비스의 Replica를 동적으로 조회하도록 구성했습니다.

따라서 다음과 같이 Replica를 추가해도 **Nginx를 재시작하지 않고** 새로운 컨테이너를 트래픽 분산 대상에 포함할 수 있습니다.

```bash
docker compose up -d --scale api=3
```

### 5.3 Docker 구성

API와 Consumer는 `python:3.12-slim`을 기반으로 이미지화하고, Docker Compose를 통해 전체 실행 환경을 재현할 수 있도록 구성했습니다.

#### 📌 이미지 구성

- `requirements.txt`를 소스 코드보다 먼저 복사해 의존성 설치 레이어를 캐시하도록 구성했습니다.
- `appuser`를 생성해 Non-root로 애플리케이션을 실행하도록 구성했습니다.
- `PYTHONUNBUFFERED=1`을 적용해 컨테이너 로그가 `docker logs`에 즉시 출력되도록 했습니다.
- Consumer가 생성하는 로그 파일은 Named Volume으로 분리해 컨테이너가 재생성되어도 데이터를 유지하도록 구성했습니다.

#### 📌 Docker Compose 구성

Kafka Broker 3대는 YAML Anchor로 공통 설정을 공유하고, Broker별 설정만 개별 지정했습니다. `depends_on`과 Health Check를 사용해 Kafka가 준비된 후 `kafka-init`이 Topic을 생성하고, 이어서 API와 Nginx가 기동되도록 구성했습니다.

---

## 6. 실행 가이드

### 📌 요구 환경

- Docker Desktop
- Docker Compose v2
- 메모리 4GB 이상 권장
- 호스트 포트 `8000` 사용 가능 상태

### 📌 실행

```bash
docker compose up -d --build
```

실행 상태 확인:

```bash
docker compose ps -a
```

API 확인:

```bash
curl http://localhost:8000/health
```

정상 응답:

```json
{"status":"ok","env":"local"}
```

환경 종료:

```bash
docker compose down
```

데이터까지 초기화:

```bash
docker compose down -v
```

---

## 7. 검증

### 7.1 API → Kafka → 파일 적재

게임 로그를 API로 전송했습니다.

> Windows Git Bash에서는 경로 변환 때문에 curl 경로가 깨질 수 있습니다.
>
> ```bash
> echo 'export MSYS_NO_PATHCONV=1' >> ~/.bashrc
> source ~/.bashrc
> ```

```bash
# (1) 로그 전송
curl -i -X POST http://localhost:8000/api/v1/logs \
  -H 'Content-Type: application/json' \
  -d '{"event_id":"evt-0001","user_id":"user-123","event_type":"item_purchase",
       "timestamp":"2026-08-11T12:00:00Z","payload":{"item":"sword","currency":"gem","amount":100}}'

# (2) Topic 구성 확인
docker exec log-kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --describe --topic game-logs

# (3) Kafka 도달 확인
docker exec log-kafka-1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic game-logs --from-beginning --timeout-ms 5000

# (4) 파일 적재 확인
docker exec log-consumer cat /data/logs/game-logs-2026-08-11.jsonl
```

**(1) 로그 전송 결과**

```
HTTP/1.1 200 OK
Content-Type: application/json

{"result":"ok","event_id":"evt-0001","topic":"game-logs","partition":2,"offset":0}
```

**(2) Topic 구성 확인 결과**

```
Topic: game-logs        TopicId: gRV14iJORcWjbLr1hudAOA PartitionCount: 3       ReplicationFactor: 3    Configs: min.insync.replicas=2
        Topic: game-logs        Partition: 0    Leader: 3       Replicas: 3,1,2 Isr: 3,1,2      Elr:    LastKnownElr:
        Topic: game-logs        Partition: 1    Leader: 1       Replicas: 1,2,3 Isr: 1,2,3      Elr:    LastKnownElr:
        Topic: game-logs        Partition: 2    Leader: 2       Replicas: 2,3,1 Isr: 2,3,1      Elr:    LastKnownElr:
```

**(3) Kafka 도달 확인 결과**

```json
{"event_id":"evt-0001","user_id":"user-123","event_type":"item_purchase","timestamp":"2026-08-11T12:00:00Z","payload":{"item":"sword","currency":"gem","amount":100},"ingested_at":"2026-08-11T08:35:57.955044+00:00"}
```

**(4) 파일 적재 확인**

```json
{"event_id":"evt-0001","user_id":"user-123","event_type":"item_purchase","timestamp":"2026-08-11T12:00:00Z","payload":{"item":"sword","currency":"gem","amount":100},"ingested_at":"2026-08-11T08:35:57.955044+00:00"}
```

따라서 **API → Kafka → Consumer → 파일**의 전체 파이프라인이 정상적으로 동작함을 확인했습니다.

### 7.2 API 수평 확장

API를 3개 Replica로 확장했습니다.

```bash
docker compose up -d --scale api=3

for i in $(seq 1 9); do
  curl -s -o /dev/null -X POST http://localhost:8000/api/v1/logs \
    -H 'Content-Type: application/json' \
    -d "{\"event_id\":\"evt-scale-$i\",\"user_id\":\"u$i\",\"event_type\":\"test\",\"timestamp\":\"2026-08-11T12:00:00Z\"}"
done

docker compose logs api | grep "POST /api/v1/logs" \
  | awk -F'|' '{print $1}' | sort | uniq -c
```

9건의 요청을 전송한 결과:

```
5 api-1
1 api-2
4 api-3
```

3개의 Replica에 요청이 분산되었으며, **추가된 Replica도 Nginx 재시작 없이 트래픽을 처리**하는 것을 확인했습니다.

### 7.3 Consumer 장애 복구

Consumer를 중단한 상태에서 API로 로그를 전송한 후 Consumer를 재기동했습니다.

```bash
docker compose stop consumer

# Consumer가 죽어 있는 상태에서 로그 전송
curl -s -X POST http://localhost:8000/api/v1/logs -H 'Content-Type: application/json' \
  -d '{"event_id":"evt-offline-1","user_id":"user-999","event_type":"test","timestamp":"2026-08-11T12:00:00Z"}'

docker compose start consumer
sleep 5

docker exec log-consumer grep -c "evt-offline-1" /data/logs/game-logs-2026-08-11.jsonl
```

**확인 결과**

```
{"result":"ok","event_id":"evt-offline-1","topic":"game-logs","partition":0,"offset":3}
```

Consumer 중단 중에도 API는 `200`을 반환했습니다.

```
1
```

재기동 후 해당 `event_id`가 파일에 **누락 없이 적재**된 것을 확인했습니다.

이를 통해 Consumer 장애가 발생해도 Kafka에 저장된 메시지가 재처리되는 구조를 검증했습니다.

---

## 8. AWS 아키텍처 (선택 과제)

### 8.1 설계 방향

로컬에서 검증한 구조를 유지하면서 직접 운영하는 컴포넌트를 AWS 관리형 서비스로 대체했습니다.

| 로컬 | AWS | 이유 |
| --- | --- | --- |
| Nginx | ALB | 헬스체크 및 부하 분산 관리 |
| FastAPI | ECS Fargate | 컨테이너 기반 수평 확장 |
| Kafka | Kinesis Data Stream | Broker 운영 없이 버퍼 구성 |
| Consumer | Data Firehose | 관리형 배치 적재 |
| Named Volume | S3 | 내구성 및 보관 관리 |

로컬에서 직접 구현한 Consumer의 배치 적재 역할은 Firehose의 버퍼 설정으로 대체했습니다.

### 8.2 아키텍처 구성도

![AWS 아키텍처](./aws-architecture.png)

### 8.3 네트워크 구성

#### 📌 Public / Private Subnet

ECS Fargate는 Private Subnet에 배치하고 Public Subnet에는 ALB만 배치했습니다.

외부에서 접근 가능한 진입점을 ALB 하나로 제한해 API가 직접 인터넷에 노출되지 않도록 했습니다. 이는 로컬 환경에서 Nginx만 호스트 포트를 개방한 것과 동일한 원칙입니다.

#### 📌 가용영역

ALB와 ECS를 3개 AZ에 분산해 특정 AZ 장애 발생 시에도 나머지 AZ에서 트래픽을 처리할 수 있도록 구성했습니다.

#### 📌 VPC Endpoint

NAT Gateway 대신 필요한 AWS 서비스에 VPC Endpoint를 사용했습니다.

- ECR
- CloudWatch Logs
- Kinesis
- S3 Gateway Endpoint

이를 통해 Private Subnet에서 인터넷으로 직접 나가는 경로를 두지 않고, 필요한 AWS 서비스에만 접근하도록 구성했습니다.

### 8.4 컴퓨팅 구성

API는 상태를 가지지 않는 컨테이너이므로 ECS Fargate를 사용했습니다.

EC2와 달리 서버 패치, AMI 관리 및 클러스터 용량 관리 부담을 줄이면서 Task 단위의 수평 확장이 가능합니다.

로컬에서 `docker compose --scale api=3`으로 검증한 구조를 ECS Service의 Replica 확장으로 대응시켰습니다.

### 8.5 로그 적재 구성

#### 📌 Kinesis Data Stream

로컬 Kafka의 버퍼 역할을 Kinesis Data Stream으로 대체했습니다.

Broker를 직접 운영하지 않고도 로그를 버퍼링할 수 있으며, Firehose와 연동해 별도의 Consumer 애플리케이션 없이 S3로 전달할 수 있습니다.

Retention은 24시간으로 설정해 다운스트림 장애 발생 시 복구할 시간을 확보했습니다.

#### 📌 Firehose → S3

Firehose는 버퍼링된 로그를 S3에 적재하며, 시간 기반 Prefix를 사용해 기간별 데이터를 분리했습니다.

S3에는 암호화와 Public Access Block을 적용하고, Lifecycle Rule을 통해 보관 기간을 관리하도록 구성했습니다.

### 8.6 Terraform 구성

Terraform은 변경 영역을 기준으로 다음과 같이 모듈을 분리했습니다.

```
network → security → pipeline → alb → ecs
```

| 모듈 | 주요 리소스 |
| --- | --- |
| `network` | VPC, Subnet, Route Table, VPC Endpoint |
| `security` | Security Group, WAFv2 |
| `pipeline` | Kinesis, Firehose, S3, IAM |
| `alb` | ALB, Target Group, Listener |
| `ecs` | ECS, IAM, Task Definition, Service, Auto Scaling |