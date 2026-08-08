# ---------------------------------------------------------------------------
# 공통
# ---------------------------------------------------------------------------
variable "project" {
  type    = string
  default = "supercent-log"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "azs" {
  description = "MSK replication.factor=3을 AZ 단위로 만족시키기 위해 3개 고정"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
}

# ---------------------------------------------------------------------------
# 네트워크 CIDR
#
# 앱 서브넷만 /23(510 IP)으로 할당한 이유:
# Fargate는 awsvpc 모드에서 태스크당 ENI 1개(=사설 IP 1개)를 점유하고,
# Interface Endpoint ENI도 같은 서브넷 IP를 소비한다.
# 스파이크 시 태스크를 수십~수백 개로 확장하면
# /24(251 IP)로는 IP 고갈로 스케일아웃이 실패한다.
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "ALB 전용"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "Fargate 태스크 + Interface Endpoint ENI"
  type        = list(string)
  default     = ["10.0.10.0/23", "10.0.12.0/23", "10.0.14.0/23"]
}

variable "data_subnet_cidrs" {
  description = "MSK 브로커"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
}

variable "interface_endpoint_services" {
  description = "AZ당 ENI 1개씩 생성되어 요금이 AZ 수만큼 곱해지므로 필요한 것만 선별한다"
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

# ---------------------------------------------------------------------------
# MSK
# ---------------------------------------------------------------------------
variable "kafka_version" {
  type    = string
  default = "3.6.0"
}

variable "msk_instance_type" {
  description = "평상시 30MB/s는 m5.large로 충분하나 5배 스파이크 여유를 위해 xlarge"
  type        = string
  default     = "kafka.m5.xlarge"
}

variable "msk_broker_count" {
  description = "AZ 수의 배수여야 한다"
  type        = number
  default     = 3
}

variable "msk_volume_size_gb" {
  description = "브로커당 EBS 용량. RF=3이므로 실제 저장량은 원본의 3배"
  type        = number
  default     = 1000
}

variable "log_topic_partitions" {
  description = "컨슈머 태스크 확장 상한을 결정한다. 늘릴 수는 있으나 줄일 수 없으므로 여유 있게"
  type        = number
  default     = 60
}

variable "log_retention_hours" {
  description = "컨슈머 장애 시 복구 가능 시간과 동일하다"
  type        = number
  default     = 168
}

variable "kafka_topic" {
  type    = string
  default = "game-logs"
}

variable "consumer_group_id" {
  type    = string
  default = "s3-sink"
}

# ---------------------------------------------------------------------------
# 컨테이너
# ---------------------------------------------------------------------------
variable "api_image" {
  description = "API 서버 ECR 이미지 URI"
  type        = string
}

variable "consumer_image" {
  description = "컨슈머 ECR 이미지 URI"
  type        = string
}

variable "api_container_port" {
  type    = number
  default = 8000
}

variable "cpu_architecture" {
  description = "ARM64는 Graviton으로 약 20% 저렴. 이미지가 arm64로 빌드되어야 한다"
  type        = string
  default     = "ARM64"
}

# ---------------------------------------------------------------------------
# 스케일링
# ---------------------------------------------------------------------------
variable "api_min_capacity" {
  type    = number
  default = 6
}

variable "api_max_capacity" {
  type    = number
  default = 100
}

variable "api_target_request_count" {
  description = "태스크 1개 처리 가능 rps의 70% 수준. 부하 테스트로 측정 후 조정 필요"
  type        = number
  default     = 3000
}

variable "consumer_min_capacity" {
  type    = number
  default = 3
}

variable "scheduled_scaling" {
  description = "게임 업데이트/이벤트처럼 시각이 알려진 트래픽에 대한 사전 확장"
  type = object({
    scale_out_cron = string
    scale_in_cron  = string
    scale_out_min  = number
  })
  default = {
    scale_out_cron = "cron(30 9 * * ? *)"
    scale_in_cron  = "cron(0 14 * * ? *)"
    scale_out_min  = 30
  }
}

# ---------------------------------------------------------------------------
# 기타
# ---------------------------------------------------------------------------
variable "certificate_arn" {
  description = "ALB HTTPS 리스너용 ACM 인증서 ARN"
  type        = string
}

variable "waf_rate_limit" {
  description = "IP당 5분 기준 요청 상한"
  type        = number
  default     = 20000
}

variable "s3_raw_prefix" {
  type    = string
  default = "raw"
}
