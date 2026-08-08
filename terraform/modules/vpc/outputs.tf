output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "Fargate 태스크와 Interface Endpoint가 배치되는 서브넷"
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "MSK 브로커가 배치되는 서브넷"
  value       = aws_subnet.data[*].id
}

output "private_route_table_ids" {
  description = "S3 Gateway Endpoint를 연결할 라우팅 테이블"
  value       = aws_route_table.private[*].id
}

output "subnet_layout" {
  description = "계층별 AZ 배치 요약"
  value = {
    public = { for i, s in aws_subnet.public : var.azs[i] => s.cidr_block }
    app    = { for i, s in aws_subnet.app : var.azs[i] => s.cidr_block }
    data   = { for i, s in aws_subnet.data : var.azs[i] => s.cidr_block }
  }
}
