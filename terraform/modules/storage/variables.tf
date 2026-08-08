variable "name" {
  type = string
}

variable "account_id" {
  description = "버킷 이름 전역 고유성 확보용 접미사"
  type        = string
}

variable "raw_prefix" {
  description = "원본 로그 적재 prefix"
  type        = string
  default     = "raw"
}
