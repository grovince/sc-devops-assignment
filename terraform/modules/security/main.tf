terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ===========================================================================
# 보안 그룹
#
# 최소 권한 원칙에 따라, 모든 규칙은 CIDR이 아니라 상대 보안 그룹을 참조한다.
# 예외는 두 가지다.
#   - ALB의 Public Ingress (외부 클라이언트라 참조할 SG가 없음)
#   - S3로의 Egress (Gateway Endpoint라 ENI가 없어 prefix list를 사용)
#
# 트래픽 체인:
#   인터넷 -> ALB :80/:443 -> ECS 태스크 :container_port -> 엔드포인트 :443
# ===========================================================================

# ---------------------------------------------------------------------------
# ALB 보안 그룹
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Internet-facing ALB for log collection API"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = length(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description = "HTTP from allowed clients"
  cidr_ipv4         = var.alb_ingress_cidrs[count.index]
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = length(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description = "HTTPS from allowed clients"
  cidr_ipv4         = var.alb_ingress_cidrs[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description = "Forward to ECS task container port"
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# ECS 태스크 보안 그룹
#
# 프라이빗 서브넷에 NAT Gateway가 없으므로, 아래 두 이그레스 규칙이
# 태스크가 가진 외부 통신 경로의 전부다.
# ---------------------------------------------------------------------------

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks-sg"
  description = "Fargate log API tasks in private subnets"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-ecs-tasks-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.ecs_tasks.id
  description = "Container port from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_endpoints" {
  security_group_id            = aws_security_group.ecs_tasks.id
  description = "HTTPS to VPC Interface Endpoints (Kinesis, ECR, Logs)"
  referenced_security_group_id = var.vpc_endpoints_sg_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# S3 Gateway Endpoint는 ENI가 아니라 라우트 테이블 항목으로 동작하므로
# 보안 그룹 참조 대신 관리형 prefix list를 사용해야 한다.
resource "aws_vpc_security_group_egress_rule" "tasks_to_s3" {
  security_group_id = aws_security_group.ecs_tasks.id
  description = "HTTPS to S3 via Gateway Endpoint for ECR image layers"
  prefix_list_id    = var.s3_prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# VPC 엔드포인트 인그레스
#
# 보안 그룹 자체는 network 모듈이 만든다. 엔드포인트가 생성 시점에 그 ID를
# 필요로 하기 때문이다. 여기서는 규칙만 붙여, 위에서 정의한 태스크 보안
# 그룹을 직접 참조할 수 있게 한다.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_tasks" {
  security_group_id            = var.vpc_endpoints_sg_id
  description = "HTTPS from ECS tasks"
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# ===========================================================================
# WAFv2
#
# ALB에 연결하므로 scope는 REGIONAL이다.
# WAF는 트래픽이 통과하는 네트워크 홉이 아니라 로드 밸런서에 부착되는
# 정책이다. 실제 연결(association)은 아래 ARN을 받아가는 alb 모듈이 수행한다.
# ===========================================================================

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name_prefix}-waf"
  description = "Rate limiting and managed rules for log collection ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # 5분 롤링 윈도우 안에서 제한을 초과한 출발지 IP를 차단한다.
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 기본 보호 규칙 세트. 실제 트래픽으로 튜닝하기 전까지는 count 모드로 둔다.
  # 오탐이 게임 로그를 조용히 버리는 상황을 막기 위함이다.
  rule {
    name     = "aws-common-rules"
    priority = 2

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.name_prefix}-waf"
  }
}
