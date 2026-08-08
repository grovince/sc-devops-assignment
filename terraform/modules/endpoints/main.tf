# ---------------------------------------------------------------------------
# S3 Gateway Endpoint
#
# ENI를 생성하지 않고 라우팅 테이블 항목으로만 동작하며 요금이 없다.
# 컨슈머의 S3 적재뿐 아니라 ECR 이미지 풀에도 필수다 —
# ECR은 메타데이터만 관리하고 레이어 바이너리는 S3에 저장되므로,
# ecr.api / ecr.dkr Interface Endpoint만으로는 이미지 풀이 실패한다.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = { Name = "${var.name}-vpce-s3" }
}

# ---------------------------------------------------------------------------
# Interface Endpoint
#
# 앱 서브넷에 AZ당 ENI 1개씩 생성되며 사설 IP를 점유한다.
# private_dns_enabled = true 이므로 애플리케이션은 기본 도메인
# (예: api.ecr.ap-northeast-2.amazonaws.com)을 그대로 사용하면 되고,
# DNS가 엔드포인트 사설 IP로 해석된다.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.app_subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  # NAT로는 불가능한 통제. 외부 이미지를 받아오는 것 자체를 차단한다.
  policy = (
    var.restrict_ecr_to_account && startswith(each.value, "ecr") && var.account_id != ""
    ? jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect    = "Allow"
          Principal = "*"
          Action    = "*"
          Resource  = "*"
          Condition = {
            StringEquals = { "aws:PrincipalAccount" = var.account_id }
          }
        }
      ]
    })
    : null
  )

  tags = { Name = "${var.name}-vpce-${each.key}" }
}
