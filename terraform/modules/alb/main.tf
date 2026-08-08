# ---------------------------------------------------------------------------
# ALB
#
# ALB는 단일 장비가 아니라 지정한 서브넷마다 ENI를 1개씩 갖는 분산 시스템이다.
# public_subnet_ids에 3개를 지정하면 각 AZ에 노드가 생성되고,
# DNS 조회 시 해당 IP들이 반환된다.
#
# cross-zone load balancing은 ALB에서 항상 활성이며 비활성화할 수 없다.
# 특정 AZ로 유입된 요청도 타 AZ의 태스크로 분산된다.
# ---------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  idle_timeout               = 60
  enable_deletion_protection = false
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.enable_access_logs && var.access_logs_bucket != "" ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      prefix  = "alb-access-logs"
      enabled = true
    }
  }

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name}-api-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Fargate awsvpc 모드는 ip 타입 필수

  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = { Name = "${var.name}-api-tg" }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ---------------------------------------------------------------------------
# WAF
#
# 로그 수집 API의 현실적 위협은 데이터 유출이 아니라 오염과 비용이다.
# 가짜 로그를 대량 주입하면 분석 데이터가 왜곡되고 MSK/S3 비용이 그대로 청구된다.
# 애플리케이션 레벨 인증(API 키, 세션 토큰)과 함께 1차 방어선으로 둔다.
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common-rules"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.name}-waf" }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 100

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.api.arn_suffix
  }
}
