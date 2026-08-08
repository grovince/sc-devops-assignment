output "s3_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "s3_prefix_list_id" {
  description = "보안 그룹 egress를 S3 대역으로 한정할 때 사용"
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

output "interface_endpoint_ids" {
  value = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "interface_endpoint_count" {
  description = "AZ당 ENI 1개씩 생성되므로 실제 과금 단위는 이 값 x AZ 수"
  value       = length(aws_vpc_endpoint.interface)
}
