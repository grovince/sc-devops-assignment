variable "name_prefix" {
  description = "리소스 이름에 붙일 접두사."
  type        = string
}

variable "region" {
  description = "AWS 리전. VPC 엔드포인트 서비스 이름을 구성하는 데 사용된다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC의 CIDR 블록."
  type        = string
}

variable "az_count" {
  description = "사용할 가용 영역 수."
  type        = number
}
