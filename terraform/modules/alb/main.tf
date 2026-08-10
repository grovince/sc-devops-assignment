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
