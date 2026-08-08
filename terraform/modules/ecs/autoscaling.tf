# ---------------------------------------------------------------------------
# API 태스크 오토스케일링
#
# CPU가 아닌 ALBRequestCountPerTarget을 기준으로 삼는다.
# 로그 수집 API는 Kafka produce가 주 작업인 I/O 바운드 워크로드로,
# 요청량이 5배가 되어도 CPU 사용률이 비례하여 상승하지 않는다.
# CPU 기반 정책은 트리거가 지연되어 응답 지연만 누적된다.
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.api_min_capacity
  max_capacity       = var.api_max_capacity
}

resource "aws_appautoscaling_policy" "api_request_count" {
  name               = "${var.name}-api-request-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }

    target_value = var.api_target_request_count

    # cooldown 비대칭: 스케일아웃은 빠르게, 스케일인은 느리게.
    # 트래픽이 잠시 내려갔다고 태스크를 줄였다 늘리는 플래핑을 방지한다.
    # 스파이크 상황에서는 과잉 프로비저닝이 부족보다 안전하다.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

# ---------------------------------------------------------------------------
# 예약 스케일링
#
# 게임 업데이트와 이벤트 오픈은 시각이 사전에 알려진 트래픽이다.
# Fargate 태스크 기동(30초~2분)과 지표 수집 지연(1~3분)으로
# 반응형 스케일링은 3~5분의 공백이 발생하므로,
# 예측 가능한 스파이크는 사전 확장으로 대응하는 것을 기본 전략으로 한다.
# target tracking은 예측 실패 시의 보완 수단이다.
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_scheduled_action" "api_scale_out" {
  count = var.scheduled_scaling == null ? 0 : 1

  name               = "${var.name}-api-preheat"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  schedule           = var.scheduled_scaling.scale_out_cron

  scalable_target_action {
    min_capacity = var.scheduled_scaling.scale_out_min
    max_capacity = var.api_max_capacity
  }
}

resource "aws_appautoscaling_scheduled_action" "api_scale_in" {
  count = var.scheduled_scaling == null ? 0 : 1

  name               = "${var.name}-api-cooldown"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  schedule           = var.scheduled_scaling.scale_in_cron

  scalable_target_action {
    min_capacity = var.api_min_capacity
    max_capacity = var.api_max_capacity
  }
}

# ---------------------------------------------------------------------------
# 컨슈머 태스크 오토스케일링
#
# 컨슈머는 ALB 뒤에 없어 RequestCount 지표가 존재하지 않고,
# CPU 역시 부하를 정확히 반영하지 못한다.
# consumer lag(브로커에 쌓인 메시지와 소비 위치의 차이)이 유일하게 정확한 지표다.
#
# lag은 선형적으로 반응하지 않고 한번 밀리면 급격히 누적되므로
# target tracking보다 단계별로 공격적인 step scaling이 적합하다.
#
# max_capacity를 파티션 수로 제한하는 이유:
# Kafka는 파티션 하나를 컨슈머 그룹 내 단일 컨슈머에만 할당한다.
# 태스크 수가 파티션 수를 초과하면 초과분은 유휴 상태로 요금만 발생한다.
# 즉 파티션 수 설계가 곧 컨슈머 확장 상한 설계다.
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "consumer" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.consumer.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.consumer_min_capacity
  max_capacity       = var.msk_partitions
}

resource "aws_appautoscaling_policy" "consumer_lag_out" {
  name               = "${var.name}-consumer-lag-out"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.consumer.service_namespace
  resource_id        = aws_appautoscaling_target.consumer.resource_id
  scalable_dimension = aws_appautoscaling_target.consumer.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 120
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      metric_interval_upper_bound = 90000
      scaling_adjustment          = 2
    }

    step_adjustment {
      metric_interval_lower_bound = 90000
      scaling_adjustment          = 4
    }
  }
}

resource "aws_appautoscaling_policy" "consumer_lag_in" {
  name               = "${var.name}-consumer-lag-in"
  policy_type        = "StepScaling"
  service_namespace  = aws_appautoscaling_target.consumer.service_namespace
  resource_id        = aws_appautoscaling_target.consumer.resource_id
  scalable_dimension = aws_appautoscaling_target.consumer.scalable_dimension

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 300
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

# consumer lag은 MSK 오픈 모니터링(Prometheus)의 kafka_consumergroup_lag을
# 컨슈머 애플리케이션이 CloudWatch 커스텀 지표로 발행하는 것을 전제로 한다.
resource "aws_cloudwatch_metric_alarm" "lag_high" {
  alarm_name          = "${var.name}-consumer-lag-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ConsumerLag"
  namespace           = var.metric_namespace
  period              = 60
  statistic           = "Average"
  threshold           = 10000

  dimensions = {
    ConsumerGroup = var.consumer_group_id
    Topic         = var.kafka_topic
  }

  alarm_actions = [aws_appautoscaling_policy.consumer_lag_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "lag_low" {
  alarm_name          = "${var.name}-consumer-lag-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "ConsumerLag"
  namespace           = var.metric_namespace
  period              = 60
  statistic           = "Average"
  threshold           = 1000

  dimensions = {
    ConsumerGroup = var.consumer_group_id
    Topic         = var.kafka_topic
  }

  alarm_actions = [aws_appautoscaling_policy.consumer_lag_in.arn]
}

# lag이 지속 증가하면 retention 초과로 실제 유실이 발생한다.
# 브로커/프로듀서/컨슈머 설정이 모두 올바라도 유실될 수 있는 유일한 경로이므로
# 스케일링 트리거와 별개의 임계값으로 감시한다.
resource "aws_cloudwatch_metric_alarm" "lag_critical" {
  alarm_name          = "${var.name}-consumer-lag-critical"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ConsumerLag"
  namespace           = var.metric_namespace
  period              = 300
  statistic           = "Average"
  threshold           = 5000000
  alarm_description   = "컨슈머가 파티션 최대 확장으로도 따라가지 못함. retention 초과 유실 위험"

  dimensions = {
    ConsumerGroup = var.consumer_group_id
    Topic         = var.kafka_topic
  }
}
