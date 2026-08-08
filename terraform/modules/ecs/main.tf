resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.name}-ecs" }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # 컨슈머는 중단되어도 커밋된 오프셋부터 재개되므로 Spot 활용 여지가 있으나,
  # API는 중단이 요청 유실로 직결되므로 온디맨드만 사용한다.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}/api"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "consumer" {
  name              = "/ecs/${var.name}/consumer"
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# API 태스크
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.api_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.api_image
      essential = true

      portMappings = [
        {
          containerPort = var.api_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "KAFKA_BOOTSTRAP_SERVERS", value = var.bootstrap_brokers },
        { name = "KAFKA_TOPIC", value = var.kafka_topic },
        { name = "KAFKA_SECURITY_PROTOCOL", value = "SASL_SSL" },
        { name = "KAFKA_SASL_MECHANISM", value = "AWS_MSK_IAM" },

        # 무손실 프로듀서 설정.
        # 브로커의 min.insync.replicas=2와 짝을 이루어야 의미가 있다.
        { name = "KAFKA_ACKS", value = "all" },
        { name = "KAFKA_ENABLE_IDEMPOTENCE", value = "true" },

        # 처리량 최적화. 로그 수집은 수십 ms 지연이 문제되지 않으므로
        # 배치를 모아 압축 효율과 throughput을 높인다.
        { name = "KAFKA_LINGER_MS", value = "20" },
        { name = "KAFKA_BATCH_SIZE", value = "65536" },
        { name = "KAFKA_COMPRESSION_TYPE", value = "lz4" },

        # 브로커 지연 시 버퍼에 축적하고, 초과하면 5초 후 예외를 던진다.
        # 무한 대기로 헬스체크가 실패해 태스크가 죽는 것보다 낫다.
        { name = "KAFKA_BUFFER_MEMORY", value = "134217728" },
        { name = "KAFKA_MAX_BLOCK_MS", value = "5000" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.api_container_port}/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = { Name = "${var.name}-api-task" }
}

resource "aws_ecs_service" "api" {
  name            = "${var.name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_min_capacity
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.api_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "api"
    container_port   = var.api_container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 배포 중에도 기존 용량을 유지하여 처리 능력이 떨어지지 않게 한다
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  health_check_grace_period_seconds = 60

  lifecycle {
    # 오토스케일링이 조정한 태스크 수를 terraform이 되돌리지 않도록 제외
    ignore_changes = [desired_count]
  }

  # https_listener_arn을 태그로 참조하여 리스너 생성 완료 후 서비스가 만들어지도록 한다.
  # depends_on에는 변수를 직접 넣을 수 없으므로 암묵적 의존성을 활용한다.
  tags = {
    Name        = "${var.name}-api-svc"
    ListenerRef = var.https_listener_arn
  }
}

# ---------------------------------------------------------------------------
# 컨슈머 태스크
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "consumer" {
  family                   = "${var.name}-consumer"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 4096 # 배치 버퍼링을 위해 API보다 넉넉하게

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.consumer_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "consumer"
      image     = var.consumer_image
      essential = true

      environment = [
        { name = "KAFKA_BOOTSTRAP_SERVERS", value = var.bootstrap_brokers },
        { name = "KAFKA_TOPIC", value = var.kafka_topic },
        { name = "KAFKA_GROUP_ID", value = var.consumer_group_id },
        { name = "KAFKA_SECURITY_PROTOCOL", value = "SASL_SSL" },
        { name = "KAFKA_SASL_MECHANISM", value = "AWS_MSK_IAM" },

        # auto commit을 비활성화하고 S3 적재 성공 후 수동 커밋한다.
        # 순서가 반대면 커밋 후 적재 실패 시 해당 배치가 유실된다.
        # at-least-once가 되므로 중복은 오프셋 기반 오브젝트 키로 멱등 처리한다.
        { name = "KAFKA_ENABLE_AUTO_COMMIT", value = "false" },
        { name = "KAFKA_MAX_POLL_RECORDS", value = "1000" },

        { name = "S3_BUCKET", value = var.s3_bucket_id },
        { name = "S3_PREFIX", value = var.s3_raw_prefix },
        { name = "S3_FORMAT", value = "parquet" },
        { name = "S3_COMPRESSION", value = "snappy" },

        { name = "METRIC_NAMESPACE", value = var.metric_namespace },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.consumer.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "consumer"
        }
      }
    }
  ])

  tags = { Name = "${var.name}-consumer-task" }
}

resource "aws_ecs_service" "consumer" {
  name            = "${var.name}-consumer"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.consumer.arn
  desired_count   = var.consumer_min_capacity
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.consumer_security_group_id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Name = "${var.name}-consumer-svc" }
}
