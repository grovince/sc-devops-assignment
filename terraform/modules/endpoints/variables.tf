variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "region" {
  type = string
}

variable "app_subnet_ids" {
  description = "Interface Endpoint ENI가 생성될 서브넷. Fargate 태스크와 동일한 계층"
  type        = list(string)
}

variable "private_route_table_ids" {
  description = "S3 Gateway Endpoint 경로를 등록할 라우팅 테이블"
  type        = list(string)
}

variable "security_group_id" {
  description = "Interface Endpoint ENI에 적용할 보안 그룹"
  type        = string
}

variable "interface_services" {
  description = <<-EOT
    생성할 Interface Endpoint 서비스 목록.

    AZ당 ENI 1개씩 생성되어 시간당 요금이 AZ 수만큼 곱해지므로 필요한 것만 선별한다.
      ecr.api        : 인증 토큰, 매니페스트 조회
      ecr.dkr        : Docker 레지스트리 프로토콜
      logs           : awslogs 드라이버. 누락 시 태스크 기동 실패
      secretsmanager : 자격증명 조회
      sts            : MSK IAM 인증 토큰 발급
      kafka          : MSK 컨트롤 플레인. SASL/SCRAM 사용 시 불필요
      ssmmessages    : ECS Exec 디버깅용. 서비스 운영에는 불필요
  EOT
  type        = map(string)
  default = {
    ecr_api        = "ecr.api"
    ecr_dkr        = "ecr.dkr"
    logs           = "logs"
    secretsmanager = "secretsmanager"
    sts            = "sts"
    kafka          = "kafka"
  }
}

variable "restrict_ecr_to_account" {
  description = "ECR 엔드포인트 정책으로 자기 계정 리포지토리만 허용할지 여부"
  type        = bool
  default     = true
}

variable "account_id" {
  type    = string
  default = ""
}
