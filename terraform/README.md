# AWS 로그 수집 파이프라인 - Terraform

`ALB → ECS Fargate(API) → MSK → ECS Fargate(컨슈머) → S3` 구조를 모듈 단위로 정의한다.
실제 프로비저닝은 수행하지 않으며 설계안과 코드만 제출한다.

## 디렉터리 구조

```
.
├── main.tf                  # 모듈 호출 (진입점)
├── variables.tf
├── outputs.tf
├── versions.tf
├── terraform.tfvars.example
└── modules/
    ├── vpc/          VPC, 3계층 서브넷 x 3AZ, IGW, 라우팅, Flow Logs
    ├── security/     보안 그룹 5종 (SG ID 참조 체인)
    ├── endpoints/    S3 Gateway + Interface Endpoint
    ├── storage/      S3 버킷, 암호화, 라이프사이클
    ├── msk/          MSK 클러스터, 무손실 브로커 설정, 스토리지 스케일링
    ├── alb/          ALB, 타깃 그룹, 리스너, WAF
    └── ecs/          클러스터, 태스크 정의, 서비스, IAM, 오토스케일링
```

## 모듈 의존 관계

순환 참조를 피하기 위해 의존 방향이 한쪽으로만 흐르도록 설계했다.

```
storage ─┐
vpc ─────┼─→ security ─→ endpoints
         │              ─→ msk ─────┐
         └──────────────→ alb ──────┼─→ ecs
```

VPC 엔드포인트를 `vpc` 모듈에 넣지 않고 분리한 이유가 여기 있다.
엔드포인트는 보안 그룹을 필요로 하고 보안 그룹은 VPC ID를 필요로 하므로,
한 모듈에 합치면 `vpc ↔ security` 순환이 발생한다.

## CIDR 설계

VPC: `10.0.0.0/16`

| 계층 | 2a | 2b | 2c | 배치 리소스 |
|---|---|---|---|---|
| 퍼블릭 | 10.0.0.0/24 | 10.0.1.0/24 | 10.0.2.0/24 | ALB |
| 앱 (프라이빗) | 10.0.10.0/23 | 10.0.12.0/23 | 10.0.14.0/23 | Fargate, Interface Endpoint ENI |
| 데이터 (프라이빗) | 10.0.20.0/24 | 10.0.21.0/24 | 10.0.22.0/24 | MSK 브로커 |

앱 서브넷만 `/23`(510 IP)으로 할당했다. Fargate는 awsvpc 모드에서 태스크당 ENI 1개를
점유하고 Interface Endpoint ENI도 같은 서브넷 IP를 소비하므로, 스파이크 시 태스크를
수십~수백 개로 확장하면 `/24`(251 IP)로는 IP 고갈로 스케일아웃이 실패한다.

## 주요 설계 결정

### NAT Gateway 미사용

프라이빗 서브넷의 아웃바운드 요구사항을 분석한 결과 ECR 이미지 풀, CloudWatch Logs
전송, Secrets Manager 조회, MSK IAM 인증으로 한정되며 모두 VPC Endpoint로 대체
가능하다. 고정비는 유사하나(NAT 3개 약 $97/월 vs Interface Endpoint 6종 × 3AZ)
처리 요금이 GB당 $0.045에서 $0.01로 낮아진다.

더 중요한 이점은 보안이다. 프라이빗 라우팅 테이블에 `0.0.0.0/0` 경로가 존재하지 않아
컨테이너가 침해되어도 외부 유출 경로가 물리적으로 차단되며, 엔드포인트 정책으로
자기 계정 ECR 리포지토리만 허용하는 통제가 가능하다.

단, ECR 이미지 레이어는 S3에 저장되므로 `ecr.api`·`ecr.dkr`만으로는 이미지 풀이
실패하며 S3 Gateway Endpoint가 반드시 함께 필요하다. 향후 외부 퍼블릭 API 연동이
추가될 경우 NAT 재도입을 검토한다.

### RF=3만으로는 무손실이 아니다

`replication.factor=3`은 복제본의 존재를 의미할 뿐이다. 프로듀서가 `acks=1`이면
리더 브로커만 수신한 상태에서 성공 응답이 반환되어 리더 장애 시 유실된다.

`min.insync.replicas=2` + 프로듀서 `acks=all` 조합이어야 최소 2개 복제본의 수신을
확인한 후 응답한다. 브로커 1대(AZ 1개) 장애 시 무손실로 동작하고, 2대 장애 시에는
쓰기를 거부하여 조용한 유실 대신 명시적 실패를 택한다.

애플리케이션 계층에도 유실 지점이 있다. API 서버가 produce 완료 전에 200을 응답하면
태스크 종료 시 버퍼의 메시지가 유실되므로, SIGTERM 수신 시 `flush()`를 수행하는
graceful shutdown이 필요하다. 컨슈머는 auto commit을 비활성화하고 S3 적재 성공 후
오프셋을 커밋하여 at-least-once를 보장하며, 중복은 오프셋 기반 오브젝트 키로 멱등 처리한다.

### 오토스케일링 기준

API는 `ALBRequestCountPerTarget`을 사용한다. Kafka produce가 주 작업인 I/O 바운드
워크로드라 요청량이 5배가 되어도 CPU가 비례하여 상승하지 않으므로, CPU 기반 정책은
트리거가 지연되고 응답 지연만 누적된다.

컨슈머는 consumer lag 기반 step scaling이며 `max_capacity`를 파티션 수로 제한한다.
Kafka는 파티션 하나를 컨슈머 그룹 내 단일 컨슈머에만 할당하므로 초과 태스크는
유휴 상태로 요금만 발생한다. 즉 파티션 수 설계가 곧 컨슈머 확장 상한 설계다.

Fargate 태스크 기동과 지표 수집 지연으로 스파이크 대응에 3~5분이 소요된다.
게임 업데이트와 이벤트는 시각이 사전에 알려진 트래픽이므로 scheduled scaling으로
사전 확장하는 것을 기본 전략으로 두고, target tracking은 예측 실패 시의 보완 수단이다.

### 보안 그룹은 CIDR이 아닌 SG ID 참조

Fargate는 IP가 동적으로 변경되고, 대역 기반 규칙은 동일 서브넷의 무관한 리소스까지
허용한다. 컨슈머 SG는 인바운드 규칙이 없다 — Kafka 컨슈머는 브로커로 폴링하므로
외부 접근이 불필요하기 때문이다.

S3 Gateway Endpoint는 보안 그룹이 존재하지 않아 아웃바운드 제어가 불가능한데,
관리형 prefix list를 참조하여 대상 대역을 한정했다. 결과적으로 인터넷 전체를 향한
아웃바운드 규칙이 하나도 없다.

### 자체 모듈 작성

`terraform-aws-modules/vpc`를 사용하면 서브넷 계층 분리와 CIDR 할당 근거가 모듈
내부로 숨어 코드에서 드러나지 않는다. 본 과제는 설계 의도 표현을 우선하여 네트워크
계층을 자체 작성했다. 실제 운영 환경에서는 검증된 커뮤니티 모듈을 사용하는 것이
유지보수 측면에서 유리하다.

## 사용법

```bash
cp terraform.tfvars.example terraform.tfvars
# api_image, consumer_image, certificate_arn 값 입력

terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

## 조정이 필요한 값

| 변수 | 현재값 | 비고 |
|---|---|---|
| `api_target_request_count` | 3000 | 부하 테스트로 태스크당 처리 rps 측정 후 그 70%로 설정 |
| `msk_instance_type` | m5.xlarge | 실제 처리량 측정 후 조정 |
| `log_topic_partitions` | 60 | 늘릴 수는 있으나 줄일 수 없으므로 여유 있게 |
| `waf_rate_limit` | 20000 | 정상 클라이언트 전송 빈도 측정 후 조정 |
| `cpu_architecture` | ARM64 | 이미지가 arm64로 빌드되지 않으면 X86_64로 변경 |

## 범위상 제외한 항목

- API 인증 (프로덕션에서는 게임 클라이언트 세션 토큰 검증 또는 mTLS 필요)
- Route 53 latency-based routing 기반 멀티 리전 수집
- Glue Data Catalog / Athena 테이블 정의
- ECR 리포지토리 및 CI/CD 파이프라인
- PII 필드 해싱 및 GDPR 삭제 요청 대응
- Kafka 토픽 생성 (`auto.create.topics.enable=false`이므로 초기화 잡에서 RF=3 명시 생성)
