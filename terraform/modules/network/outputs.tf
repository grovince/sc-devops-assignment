output "vpc_id" {
  description = "VPC의 ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC의 CIDR 블록"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록 (AZ별 1개)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID 목록 (AZ별 1개)"
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "실제로 사용 중인 가용 영역 목록."
  value       = local.azs
}

output "vpc_endpoints_sg_id" {
  description = "Interface Endpoint ENI에 부착된 보안 그룹 ID. 규칙은 security 모듈이 추가한다."
  value       = aws_security_group.vpc_endpoints.id
}

output "interface_endpoint_ids" {
  description = "서비스 이름을 키로 하는 Interface Endpoint ID 맵"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_gateway_endpoint_id" {
  description = "S3 Gateway Endpoint의 ID."
  value       = aws_vpc_endpoint.s3.id
}

output "s3_prefix_list_id" {
  description = "S3 Gateway Endpoint가 사용하는 관리형 prefix list ID. 보안 그룹 이그레스 규칙에 쓰인다."
  value       = aws_vpc_endpoint.s3.prefix_list_id
}
