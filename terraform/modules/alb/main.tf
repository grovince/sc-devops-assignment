terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  # 가용 영역별 퍼블릭 서브넷에 걸쳐 배치되어 부하를 분산한다.
  subnets         = var.public_subnet_ids
  security_groups = [var.alb_sg_id]

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  # 로그 전송 클라이언트는 버스트 사이에도 연결을 유지하는 경우가 많다.
  idle_timeout = 60

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

# ---------------------------------------------------------------------------
# 타깃 그룹
#
# Fargate 태스크는 awsvpc 네트워크 모드를 사용해 ENI 주소로 등록되므로
# target_type은 반드시 "ip"여야 한다. "instance"는 사용할 수 없다.
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "api" {
  name        = "${var.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Fargate는 태스크를 오래 드레이닝하지 않고 교체한다. 값을 짧게 두면
  # 처리 중인 요청을 끊지 않으면서도 롤링 배포가 빨라진다.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-tg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# 로그 수집 경로에 대한 명시적 규칙. 현재 동작은 기본 액션과 동일하지만,
# 이후 경로별 처리(별도 타깃 그룹, 전용 WAF 규칙, 다른 스로틀링 정책)를
# 붙일 지점을 미리 확보해 둔다.
resource "aws_lb_listener_rule" "logs" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["/api/v1/logs", "/api/v1/logs/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# ---------------------------------------------------------------------------
# WAF 연결
#
# Web ACL 자체는 security 모듈에서 정의한다.
# WAF는 트래픽 경로상의 홉이 아니라 이 로드 밸런서에 부착되는 정책이다.
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = var.web_acl_arn
}
