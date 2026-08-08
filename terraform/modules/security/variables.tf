variable "name_prefix" {
  description = "리소스 이름에 붙일 접두사."
  type        = string
}

variable "vpc_id" {
  description = "보안 그룹이 속할 VPC의 ID."
  type        = string
}

variable "container_port" {
  description = "API 서버가 listen하는 포트."
  type        = number
}

variable "alb_ingress_cidrs" {
  description = "ALB 접근을 허용할 CIDR 블록 목록."
  type        = list(string)
}

variable "s3_prefix_list_id" {
  description = "S3 Gateway Endpoint의 관리형 prefix list ID. 이그레스 규칙에 사용된다."
  type        = string
}

variable "vpc_endpoints_sg_id" {
  description = "network 모듈이 생성한 Interface Endpoint용 보안 그룹 ID."
  type        = string
}

variable "rate_limit" {
  description = "단일 IP의 5분 윈도우당 최대 요청 수."
  type        = number
}
