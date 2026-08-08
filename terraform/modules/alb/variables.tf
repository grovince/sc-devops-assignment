variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "ALB ENI가 생성될 서브넷. 지정한 서브넷마다 노드가 1개씩 생긴다"
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "certificate_arn" {
  description = "HTTPS 리스너용 ACM 인증서 ARN"
  type        = string
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "deregistration_delay" {
  description = "배포 시 인플라이트 요청 처리 유예. 컨테이너 graceful shutdown 시간보다 길어야 유실이 없다"
  type        = number
  default     = 30
}

variable "waf_rate_limit" {
  description = "IP당 5분 기준 요청 상한. 정상 클라이언트 전송 빈도를 측정해 조정 필요"
  type        = number
  default     = 20000
}

variable "access_logs_bucket" {
  type    = string
  default = ""
}

variable "enable_access_logs" {
  description = "초당 수만 건 환경에서는 액세스 로그 자체가 대용량이므로 기본 비활성"
  type        = bool
  default     = false
}
