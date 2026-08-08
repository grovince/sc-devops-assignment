# 로그 수집 인프라 (Terraform)

게임 로그 수집 파이프라인의 AWS 구성을 정의한 Terraform 코드입니다.
실제 프로비저닝은 수행하지 않으며, 설계안과 코드만 제출합니다.

```
클라이언트 → ALB (+WAFv2) → ECS Fargate (API) → VPC Interface Endpoint
                                              → Kinesis Data Streams
                                              → Data Firehose → S3
```

## 디렉터리 구조

```
.
├── main.tf                 # 모듈 호출 및 연결
├── variables.tf            # 프로젝트 공통 변수
├── outputs.tf              # ALB DNS, 버킷 이름, 스트림 이름 등
├── terraform.tfvars        # 실제 변수 입력값
└── modules/
    ├── network/            # VPC, 서브넷, 라우트 테이블, VPC 엔드포인트
    ├── security/           # 보안 그룹, WAFv2 Web ACL
    ├── alb/                # ALB, 타깃 그룹, 리스너, WAF 연결
    ├── ecs/                # 클러스터, IAM 역할, 태스크 정의, 서비스
    └── pipeline/           # Kinesis, Firehose, S3
```

## 실행 방법

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

`plan`을 실행하기 전에 `terraform.tfvars`의 `container_image`를 필수 과제에서
빌드한 이미지의 ECR URI로 교체해야 합니다.

## 모듈 경계

적용 순서는 `network → security → pipeline → alb → ecs`입니다.
두 곳은 모듈 간 순환 참조를 피하기 위해 일반적이지 않은 위치에 배치했습니다.

**VPC 엔드포인트 보안 그룹은 `network`에, 그 규칙은 `security`에 있습니다.**
Interface Endpoint는 생성 시점에 보안 그룹 ID가 필요하고, `security` 모듈은
VPC ID가 필요합니다. 한쪽에 몰면 `network → security → network` 순환이
발생합니다. 규칙 없는 빈 보안 그룹을 엔드포인트와 함께 만들고 인그레스
규칙만 `security`에서 붙이면 이 순환이 끊어지며, 그 결과 규칙이 CIDR 대신
ECS 태스크 보안 그룹을 직접 참조할 수 있습니다.

**Web ACL은 `security`에, association은 `alb`에 있습니다.**
ALB는 이미 자신의 보안 그룹을 `security`에서 받아오므로 Web ACL ARN도 같은
방향으로 흐릅니다. WAF는 트래픽 경로상의 홉이 아니라 로드 밸런서에 부착되는
정책이라는 점이 코드 구조에도 드러납니다.

## 설계 근거

### NAT Gateway를 사용하지 않음

프라이빗 서브넷의 라우트 테이블에는 local 경로만 존재합니다. 모든 AWS 서비스
접근은 VPC 엔드포인트를 경유합니다. NAT Gateway의 시간당 요금과 GB당 처리
요금이 사라지고, API 태스크가 실행되는 서브넷에서 인터넷으로 나가는 경로
자체가 제거되어 보안 격리 수준도 올라갑니다.

S3 Gateway Endpoint는 장식이 아닙니다. ECR이 이미지 레이어를 S3에 저장하기
때문에, NAT가 없는 서브넷에서는 이 엔드포인트가 없으면 이미지 pull이
실패합니다. Kinesis, ECR, CloudWatch Logs는 Interface 방식으로만 제공됩니다.
Gateway Endpoint를 지원하는 서비스는 S3와 DynamoDB뿐입니다.

Firehose는 VPC 엔드포인트를 경유하지 않습니다. API 서버는 Kinesis에 대해
`PutRecords`만 호출하며, Firehose가 스트림을 읽고 S3에 쓰는 구간은 전부 AWS
서비스 영역 안에서 이루어집니다.

### 보안 그룹 체이닝

모든 규칙이 CIDR이 아니라 상대 보안 그룹을 참조합니다. 예외는 ALB의 퍼블릭
인그레스와 S3 prefix list 이그레스 두 가지뿐입니다.

```
인터넷 → ALB:80/443 → 태스크:8080 → 엔드포인트:443
```

S3 Gateway Endpoint는 ENI가 없어 보안 그룹으로 참조할 수 없으므로, 엔드포인트
리소스가 노출하는 `prefix_list_id` 속성을 사용합니다. 별도 데이터 소스를 두면
`plan` 시점에 AWS API 호출이 발생해 자격 증명이 필요해지므로, 엔드포인트
속성을 모듈 출력으로 넘기는 방식을 택했습니다.

### Firehose 버퍼 설정

5 MiB / 60초로 설정했습니다. 버퍼를 작게 잡으면 S3에 데이터가 빨리 도달하지만
객체 수가 늘어나 Athena 스캔 오버헤드와 S3 요청 비용이 함께 올라갑니다. 분석
성능이 더 중요해지면 128 MiB 방향으로 올리는 것이 조정 지점입니다.

동적 파티셔닝(dynamic partitioning)은 의도적으로 사용하지 않았습니다. 이
기능은 64~128 MiB 버퍼를 요구해 위 설정과 충돌합니다. 시간 기반 파티셔닝은
`prefix`의 `!{timestamp:...}` 네임스페이스로 구현했으며, 이 네임스페이스는
동적 파티셔닝 없이도 Firehose가 평가합니다.

Parquet 변환은 Glue Data Catalog 테이블로 스키마를 공급해야 하므로 과제
범위에서 제외했습니다. 로그 스키마가 확정되면
`data_format_conversion_configuration`으로 추가할 수 있습니다.

### 오토스케일링

CPU가 아니라 `ALBRequestCountPerTarget`을 기준으로 삼습니다. 로그 수집은 I/O
바운드 작업이라 프로세서 사용률보다 요청률이 실제 부하를 더 정확히
반영합니다. 스케일 아웃 쿨다운(60초)을 스케일 인(300초)보다 짧게 두어 트래픽
급증 시 유실 위험을 줄이는 방향으로 비대칭하게 설정했습니다.

`desired_count`는 `ignore_changes`로 관리 대상에서 제외했습니다. 오토스케일링이
조정한 태스크 수가 다음 `plan`에서 diff로 잡히는 것을 막기 위함입니다.

## 과제 범위에서 제외한 항목

- HTTPS 리스너 및 ACM 인증서. 현재 리스너는 HTTP/80입니다.
- ALB 액세스 로그.
- TLS 접근만 허용하는 S3 버킷 정책.
- Parquet 변환 및 Glue Data Catalog 연동.

`container_image`는 반드시 실제 ECR URI로 교체해야 합니다.
