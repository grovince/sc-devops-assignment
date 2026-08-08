# ---------------------------------------------------------------------------
# 보안 그룹 체인
#
# 모든 규칙은 CIDR이 아닌 보안 그룹 ID 참조로 구성한다.
# Fargate 태스크는 IP가 동적으로 변경되므로 대역 기반 규칙은 관리가 어렵고,
# 동일 서브넷 내 무관한 리소스까지 허용하는 과도한 권한이 된다.
#
# 규칙은 인라인 블록 대신 별도 리소스로 분리한다.
# SG끼리 상호 참조할 때 인라인 블록은 순환 의존을 유발한다.
#
#   0.0.0.0/0 --443--> ALB SG
#                        | 8000
#                        v
#                      API SG --9098--> MSK SG <--9098-- Consumer SG
#                        |                                   |
#                        +--443--> VPCE SG <--443------------+
#                                                            |
#                                          443 (S3 prefix list)
#                                                            v
#                                                 S3 Gateway Endpoint
# ---------------------------------------------------------------------------

# Gateway Endpoint에는 보안 그룹이 존재하지 않아 아웃바운드 제어가 불가능하다.
# egress를 0.0.0.0/0 대신 S3 대역으로 한정하기 위해 관리형 prefix list를 참조한다.
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

# ------------------------------- ALB -------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB. 인터넷에 노출되는 유일한 지점"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "인터넷에서 HTTPS 수신"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS 리다이렉트 전용"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "API 태스크로 전달"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = var.api_container_port
  to_port                      = var.api_container_port
  ip_protocol                  = "tcp"
}

# ------------------------------- API 태스크 -------------------------------
resource "aws_security_group" "api" {
  name        = "${var.name}-api-sg"
  description = "Fargate API 태스크"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-api-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "ALB에서만 수신. 인터넷 및 동일 서브넷 타 리소스 접근 불가"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.api_container_port
  to_port                      = var.api_container_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_to_msk" {
  security_group_id            = aws_security_group.api.id
  description                  = "MSK produce"
  referenced_security_group_id = aws_security_group.msk.id
  from_port                    = var.msk_port
  to_port                      = var.msk_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_to_vpce" {
  security_group_id            = aws_security_group.api.id
  description                  = "ECR 이미지 풀, CloudWatch Logs 전송"
  referenced_security_group_id = aws_security_group.vpce.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_to_s3" {
  security_group_id = aws_security_group.api.id
  description       = "ECR 이미지 레이어는 S3에 저장되므로 필요"
  prefix_list_id    = data.aws_prefix_list.s3.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ------------------------------- 컨슈머 태스크 -------------------------------
resource "aws_security_group" "consumer" {
  name        = "${var.name}-consumer-sg"
  description = "Fargate 컨슈머 태스크. 인바운드 규칙 없음"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-consumer-sg" }
}

# 인바운드 규칙을 의도적으로 정의하지 않는다.
# Kafka 컨슈머는 브로커로 폴링하는 방식이므로 외부에서 접근할 필요가 없다.

resource "aws_vpc_security_group_egress_rule" "consumer_to_msk" {
  security_group_id            = aws_security_group.consumer.id
  description                  = "MSK consume"
  referenced_security_group_id = aws_security_group.msk.id
  from_port                    = var.msk_port
  to_port                      = var.msk_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "consumer_to_msk_prometheus" {
  security_group_id            = aws_security_group.consumer.id
  description                  = "consumer lag 지표 수집"
  referenced_security_group_id = aws_security_group.msk.id
  from_port                    = 11001
  to_port                      = 11002
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "consumer_to_vpce" {
  security_group_id            = aws_security_group.consumer.id
  description                  = "ECR 이미지 풀, CloudWatch Logs 전송"
  referenced_security_group_id = aws_security_group.vpce.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "consumer_to_s3" {
  security_group_id = aws_security_group.consumer.id
  description       = "S3 적재. Gateway Endpoint는 SG가 없어 prefix list로 대상 한정"
  prefix_list_id    = data.aws_prefix_list.s3.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ------------------------------- MSK -------------------------------
resource "aws_security_group" "msk" {
  name        = "${var.name}-msk-sg"
  description = "MSK 브로커"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-msk-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_api" {
  security_group_id            = aws_security_group.msk.id
  description                  = "API 태스크의 produce"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = var.msk_port
  to_port                      = var.msk_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "msk_from_consumer" {
  security_group_id            = aws_security_group.msk.id
  description                  = "컨슈머 태스크의 consume"
  referenced_security_group_id = aws_security_group.consumer.id
  from_port                    = var.msk_port
  to_port                      = var.msk_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "msk_prometheus" {
  security_group_id            = aws_security_group.msk.id
  description                  = "Prometheus 오픈 모니터링. consumer lag 오토스케일링에 사용"
  referenced_security_group_id = aws_security_group.consumer.id
  from_port                    = 11001
  to_port                      = 11002
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "msk_internal" {
  security_group_id            = aws_security_group.msk.id
  description                  = "브로커 간 replication"
  referenced_security_group_id = aws_security_group.msk.id
  from_port                    = 9090
  to_port                      = 9098
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "msk_internal_out" {
  security_group_id            = aws_security_group.msk.id
  description                  = "브로커 간 replication"
  referenced_security_group_id = aws_security_group.msk.id
  ip_protocol                  = "-1"
}

# ------------------------- Interface Endpoint ENI -------------------------
resource "aws_security_group" "vpce" {
  name        = "${var.name}-vpce-sg"
  description = "Interface Endpoint ENI. 누락 시 ECR 풀이 조용히 실패한다"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-vpce-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_api" {
  security_group_id            = aws_security_group.vpce.id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_consumer" {
  security_group_id            = aws_security_group.vpce.id
  referenced_security_group_id = aws_security_group.consumer.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}
