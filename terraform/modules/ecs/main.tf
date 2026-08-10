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
# 클러스터 및 컨테이너 로그 그룹
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  tags = {
    Name = "${var.name_prefix}-cluster"
  }
}

# 컨테이너의 stdout / stderr를 받는다.
# 이것은 애플리케이션 운영 로그이며, S3로 적재되는 게임 로그와는
# 목적지도 성격도 의도적으로 분리했다.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.name_prefix}-api-logs"
  }
}

# ---------------------------------------------------------------------------
# 태스크 실행 역할 (Task Execution Role)
#
# 애플리케이션 코드가 아니라 ECS 에이전트가 사용하는 역할이다.
# 이미지를 pull하고 로그 스트림을 생성하는 데 쓰인다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json #위에 만든 aws_iam_policy_document 정책을 Role에 설정
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------
# 태스크 역할 (Task Role)
#
# 애플리케이션 컨테이너가 직접 사용하는 역할이다.
# 권한은 지정된 Kinesis 스트림에 레코드를 쓰는 것으로만 한정한다.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid    = "PutLogRecords"
    effect = "Allow"
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords",
      "kinesis:DescribeStreamSummary",
    ]
    resources = [var.kinesis_stream_arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.name_prefix}-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ---------------------------------------------------------------------------
# 태스크 정의
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "KINESIS_STREAM_NAME", value = var.kinesis_stream_name },
        { name = "AWS_REGION", value = var.region },
        { name = "PORT", value = tostring(var.container_port) },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = {
    Name = "${var.name_prefix}-api-task"
  }
}

# ---------------------------------------------------------------------------
# 서비스
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "api" {
  name            = "${var.name_prefix}-api-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    # 가용 영역별 프라이빗 서브넷에 태스크를 분산 배치한다.
    subnets = var.private_subnet_ids

    security_groups = [var.ecs_tasks_sg_id]

    # NAT Gateway가 없는 프라이빗 서브넷이므로 퍼블릭 IP를 부여하지 않는다.
    # 외부 통신은 VPC 엔드포인트를 통해서만 이루어진다.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = var.container_port
  }

  # 배포 중에도 현재 태스크 수 아래로 내려가지 않는 롤링 배포.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # 배포가 실패하면 자동으로 이전 리비전으로 되돌린다.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 태스크가 등록되고 헬스체크를 통과할 시간을 준다.
  health_check_grace_period_seconds = 60

  tags = {
    Name = "${var.name_prefix}-api-svc"
  }

  # 오토스케일링이 조정한 태스크 수가 다음 plan에서 diff로 잡히지 않도록 한다.
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ---------------------------------------------------------------------------
# 서비스 오토스케일링
#
# CPU가 아니라 타깃당 요청 수를 기준으로 삼는다.
# 로그 수집은 I/O 바운드 작업이라 프로세서 사용률보다 요청률이 실제 부하를
# 더 정확히 반영하기 때문이다.
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.desired_count
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "${var.name_prefix}-scale-on-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.requests_per_target

    # 스케일 인은 느리게, 스케일 아웃은 빠르게. 트래픽 급증 시 유실 위험을
    # 줄이는 방향으로 비대칭하게 설정한다.
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = var.alb_target_group_label
    }
  }
}
