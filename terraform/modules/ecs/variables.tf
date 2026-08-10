variable "name_prefix" {
  description = "리소스 이름에 붙일 접두사."
  type        = string
}

variable "region" {
  description = "AWS 리전."
  type        = string
}

variable "private_subnet_ids" {
  description = "Fargate 태스크가 실행될 프라이빗 서브넷 ID 목록."
  type        = list(string)
}

variable "ecs_tasks_sg_id" {
  description = "태스크에 부착할 보안 그룹 ID."
  type        = string
}

variable "target_group_arn" {
  description = "서비스가 등록될 ALB 타깃 그룹 ARN."
  type        = string
}

variable "alb_target_group_label" {
  description = "ALBRequestCountPerTarget 지표용 리소스 레이블"
  type        = string
}

variable "container_image" {
  description = "컨테이너 이미지 URI."
  type        = string
}

variable "container_port" {
  description = "API 서버가 listen하는 포트."
  type        = number
}

variable "task_cpu" {
  description = "Fargate 태스크의 CPU 유닛."
  type        = number
}

variable "task_memory" {
  description = "Fargate 태스크의 메모리 (MiB)."
  type        = number
}

variable "desired_count" {
  description = "기본 태스크 수. 오토스케일링의 최소값으로도 사용된다."
  type        = number
}

variable "max_capacity" {
  description = "오토스케일링 시 최대 태스크 수."
  type        = number
  default     = 30
}

variable "requests_per_target" {
  description = "태스크당 목표 요청 수(분당). 이 값을 넘으면 스케일 아웃한다."
  type        = number
  default     = 3000
}

variable "log_retention_days" {
  description = "컨테이너 로그의 CloudWatch Logs 보존 기간 (일)."
  type        = number
}

variable "kinesis_stream_arn" {
  description = "태스크 역할이 쓰기 권한을 가질 Kinesis 스트림의 ARN."
  type        = string
}

variable "kinesis_stream_name" {
  description = "컨테이너에 환경변수로 전달할 Kinesis 스트림 이름."
  type        = string
}
