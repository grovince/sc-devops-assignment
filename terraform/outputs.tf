# ---------------------------------------------------------------------------
# 네트워크
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC의 ID."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록 (AZ별 1개)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록 (AZ별 1개)."
  value       = module.network.private_subnet_ids
}

output "availability_zones" {
  description = "실제로 사용 중인 가용 영역 목록."
  value       = module.network.availability_zones
}

output "interface_endpoint_ids" {
  description = "서비스별 Interface Endpoint ID."
  value       = module.network.interface_endpoint_ids
}

output "s3_gateway_endpoint_id" {
  description = "S3 Gateway Endpoint의 ID."
  value       = module.network.s3_gateway_endpoint_id
}

# ---------------------------------------------------------------------------
# 인그레스
# ---------------------------------------------------------------------------

output "api_endpoint" {
  description = "로그 수집 API의 기본 URL."
  value       = "http://${module.alb.alb_dns_name}"
}

output "log_ingest_url" {
  description = "게임 로그를 POST할 전체 URL."
  value       = "http://${module.alb.alb_dns_name}/api/v1/logs"
}

output "web_acl_arn" {
  description = "ALB에 연결된 WAFv2 Web ACL의 ARN."
  value       = module.security.web_acl_arn
}

# ---------------------------------------------------------------------------
# 컴퓨트
# ---------------------------------------------------------------------------

output "ecs_cluster_name" {
  description = "ECS 클러스터 이름."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS 서비스 이름."
  value       = module.ecs.service_name
}

output "container_log_group" {
  description = "컨테이너 로그가 적재되는 CloudWatch Logs 그룹."
  value       = module.ecs.log_group_name
}

# ---------------------------------------------------------------------------
# 데이터 파이프라인
# ---------------------------------------------------------------------------

output "kinesis_stream_name" {
  description = "Kinesis Data Stream의 이름."
  value       = module.pipeline.kinesis_stream_name
}

output "firehose_name" {
  description = "Firehose 전송 스트림의 이름."
  value       = module.pipeline.firehose_name
}

output "log_bucket_name" {
  description = "게임 로그가 적재되는 S3 버킷."
  value       = module.pipeline.log_bucket_name
}
