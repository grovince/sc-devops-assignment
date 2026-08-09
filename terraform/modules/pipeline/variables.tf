variable "name_prefix" {
  description = "리소스 이름에 붙일 접두사."
  type        = string
}

variable "retention_hours" {
  description = "Kinesis Data Streams 보존 기간 (시간)."
  type        = number
}

variable "buffer_size_mb" {
  description = "Firehose 버퍼 크기 (MiB)."
  type        = number
}

variable "buffer_interval_sec" {
  description = "Firehose 버퍼 시간 (초)."
  type        = number
}

variable "log_expiration_days" {
  description = "로그 객체 만료 기간 (일). 0이면 만료를 적용하지 않는다."
  type        = number
}
