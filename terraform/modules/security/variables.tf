variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "region" {
  description = "S3 prefix list 조회용"
  type        = string
}

variable "api_container_port" {
  type    = number
  default = 8000
}

variable "msk_port" {
  description = "MSK 인증 포트. IAM=9098, SASL/SCRAM=9096, TLS=9094"
  type        = number
  default     = 9098
}
