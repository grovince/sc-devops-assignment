variable "name_prefix" {
  description = "리소스 이름에 붙일 접두사."
  type        = string
}

variable "vpc_id" {
  description = "VPC의 ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB가 걸쳐 배치될 퍼블릭 서브넷 ID 목록 (AZ별 1개)."
  type        = list(string)
}

variable "alb_sg_id" {
  description = "ALB에 부착할 보안 그룹 ID."
  type        = string
}

variable "container_port" {
  description = "API 서버가 listen하는 포트."
  type        = number
}

variable "health_check_path" {
  description = "타깃 그룹 헬스체크 경로."
  type        = string
}

variable "web_acl_arn" {
  description = "이 ALB에 연결할 WAFv2 Web ACL의 ARN."
  type        = string
}
