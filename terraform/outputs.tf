output "vpc_id" {
  value = module.vpc.vpc_id
}

output "subnet_layout" {
  description = "계층별 AZ 배치"
  value       = module.vpc.subnet_layout
}

output "log_endpoint" {
  description = "로그 수집 엔드포인트. POST https://<dns>/api/v1/logs"
  value       = module.alb.dns_name
}

output "msk_bootstrap_brokers" {
  value     = module.msk.bootstrap_brokers_sasl_iam
  sensitive = true
}

output "s3_bucket" {
  value = module.storage.bucket_id
}

output "consumer_max_capacity" {
  description = "파티션 수와 동일. 초과 태스크는 유휴 상태가 된다"
  value       = module.ecs.consumer_max_capacity
}

output "nat_gateway_count" {
  description = "NAT 미사용. 프라이빗 아웃바운드는 VPC Endpoint로 대체"
  value       = 0
}

output "interface_endpoint_count" {
  description = "실제 과금 단위는 이 값 x AZ 수"
  value       = module.endpoints.interface_endpoint_count
}
