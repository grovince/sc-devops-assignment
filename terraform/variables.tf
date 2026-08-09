# ---------------------------------------------------------------------------
# 프로젝트 공통
# ---------------------------------------------------------------------------

variable "project" {
  description = "프로젝트 이름. 모든 리소스 이름의 접두사로 사용된다."
  type        = string
  default     = "game-log"
}

variable "environment" {
  description = "배포 환경 (dev, stg, prod)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "배포 대상 AWS 리전."
  type        = string
  default     = "ap-northeast-2"
}

# ---------------------------------------------------------------------------
# 네트워크
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC의 CIDR 블록."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr은 유효한 IPv4 CIDR 블록이어야 합니다."
  }
}

variable "az_count" {
  description = "서브넷을 분산 배치할 가용 영역 수. 최소 3개."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 3 && var.az_count <= 4
    error_message = "az_count는 3 이상 4 이하여야 합니다."
  }
}

# ---------------------------------------------------------------------------
# 애플리케이션
# ---------------------------------------------------------------------------

variable "container_image" {
  description = "로그 수집 API 서버의 컨테이너 이미지 URI."
  type        = string
  default     = "public.ecr.aws/docker/library/nginx:alpine"
}

variable "container_port" {
  description = "컨테이너 내부에서 API 서버가 listen하는 포트."
  type        = number
  default     = 8080
}

variable "task_cpu" {
  description = "Fargate 태스크의 CPU 유닛."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate 태스크의 메모리 (MiB)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "실행할 API 태스크 수."
  type        = number
  default     = 3
}

variable "health_check_path" {
  description = "타깃 그룹 헬스체크 경로."
  type        = string
  default     = "/health"
}

variable "log_retention_days" {
  description = "컨테이너 로그의 CloudWatch Logs 보존 기간 (일)."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# 보안
# ---------------------------------------------------------------------------

variable "alb_ingress_cidrs" {
  description = "ALB 접근을 허용할 CIDR 블록 목록."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "waf_rate_limit" {
  description = "단일 IP가 5분 윈도우 내에 보낼 수 있는 최대 요청 수. 초과 시 차단된다."
  type        = number
  default     = 2000
}

# ---------------------------------------------------------------------------
# 데이터 파이프라인
# ---------------------------------------------------------------------------

variable "kinesis_retention_hours" {
  description = "Kinesis Data Streams 보존 기간 (시간, 24~8760)."
  type        = number
  default     = 24

  validation {
    condition     = var.kinesis_retention_hours >= 24 && var.kinesis_retention_hours <= 8760
    error_message = "kinesis_retention_hours는 24 이상 8760 이하여야 합니다."
  }
}

variable "firehose_buffer_size_mb" {
  description = "Firehose가 S3로 flush하기 전까지 버퍼링할 크기 (MiB)."
  type        = number
  default     = 5
}

variable "firehose_buffer_interval_sec" {
  description = "Firehose가 S3로 flush하기 전까지 버퍼링할 시간 (초)."
  type        = number
  default     = 60
}

variable "log_expiration_days" {
  description = "게임 로그 객체의 만료 기간 (일)"
  type        = number
  default     = 365
}
