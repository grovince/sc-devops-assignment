variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  description = "가용영역 목록. MSK RF=3을 AZ 단위로 만족시키기 위해 3개"
  type        = list(string)

  validation {
    condition     = length(var.azs) == 3
    error_message = "MSK RF=3 구성을 위해 정확히 3개의 AZ가 필요합니다."
  }
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR. ALB만 배치된다"
  type        = list(string)
}

variable "app_subnet_cidrs" {
  description = "프라이빗 앱 서브넷 CIDR. Fargate 태스크와 Interface Endpoint ENI가 배치된다"
  type        = list(string)
}

variable "data_subnet_cidrs" {
  description = "프라이빗 데이터 서브넷 CIDR. MSK 브로커가 배치된다"
  type        = list(string)
}

variable "flow_log_bucket_arn" {
  description = "VPC Flow Logs 저장 버킷 ARN. 빈 문자열이면 flow log를 생성하지 않는다"
  type        = string
  default     = ""
}
