variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "metric_namespace" {
  description = "consumer lag 커스텀 지표 네임스페이스"
  type        = string
}

# --- 네트워크 ---
variable "app_subnet_ids" {
  type = list(string)
}

variable "api_security_group_id" {
  type = string
}

variable "consumer_security_group_id" {
  type = string
}

# --- ALB 연동 ---
variable "target_group_arn" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "https_listener_arn" {
  description = "리스너 생성 완료 후 서비스를 만들기 위한 의존성"
  type        = string
}

# --- MSK 연동 ---
variable "msk_cluster_arn" {
  type = string
}

variable "msk_topic_arn_pattern" {
  type = string
}

variable "msk_group_arn_pattern" {
  type = string
}

variable "bootstrap_brokers" {
  type      = string
  sensitive = true
}

variable "kafka_topic" {
  type    = string
  default = "game-logs"
}

variable "consumer_group_id" {
  type    = string
  default = "s3-sink"
}

variable "msk_partitions" {
  description = "컨슈머 태스크 확장 상한. 초과 시 유휴 태스크가 발생한다"
  type        = number
}

# --- S3 연동 ---
variable "s3_bucket_id" {
  type = string
}

variable "s3_bucket_arn" {
  type = string
}

variable "s3_raw_prefix" {
  type    = string
  default = "raw"
}

# --- 컨테이너 ---
variable "api_image" {
  type = string
}

variable "consumer_image" {
  type = string
}

variable "api_container_port" {
  type    = number
  default = 8000
}

variable "cpu_architecture" {
  description = "ARM64는 Graviton으로 동일 성능 대비 약 20% 저렴. 이미지가 arm64로 빌드되어야 한다"
  type        = string
  default     = "ARM64"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# --- 스케일링 ---
variable "api_min_capacity" {
  description = "스케일아웃 지연(3~5분)을 흡수하기 위해 평상시 필요량보다 여유 있게 설정"
  type        = number
  default     = 6
}

variable "api_max_capacity" {
  type    = number
  default = 100
}

variable "api_target_request_count" {
  description = "태스크 1개가 처리 가능한 rps의 70% 수준. 부하 테스트로 측정 후 조정 필요"
  type        = number
  default     = 3000
}

variable "consumer_min_capacity" {
  type    = number
  default = 3
}

variable "scheduled_scaling" {
  description = "예약 스케일링 설정. null이면 생성하지 않는다"
  type = object({
    scale_out_cron = string
    scale_in_cron  = string
    scale_out_min  = number
  })
  default = null
}
