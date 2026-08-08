variable "name" {
  type = string
}

variable "kafka_version" {
  type    = string
  default = "3.6.0"
}

variable "subnet_ids" {
  description = "브로커가 배치될 데이터 서브넷. 개수가 AZ 수를 결정한다"
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "instance_type" {
  description = "평상시 30MB/s는 m5.large로 충분하나 5배 스파이크 여유를 위해 xlarge 기본값"
  type        = string
  default     = "kafka.m5.xlarge"
}

variable "broker_count" {
  description = "subnet_ids 개수의 배수여야 한다"
  type        = number
  default     = 3
}

variable "volume_size_gb" {
  description = "브로커당 EBS 용량. RF=3이므로 실제 저장량은 원본의 3배"
  type        = number
  default     = 1000
}

variable "partitions" {
  description = "기본 파티션 수. 컨슈머 태스크 확장 상한을 결정한다"
  type        = number
  default     = 60
}

variable "retention_hours" {
  description = "컨슈머 장애 시 복구 가능 시간과 동일하다"
  type        = number
  default     = 168
}

variable "log_retention_days" {
  type    = number
  default = 30
}
