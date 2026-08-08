# ---------------------------------------------------------------------------
# 브로커 설정
#
# replication.factor=3 만으로는 무손실이 보장되지 않는다.
# RF는 복제본의 존재를 의미할 뿐이며, 프로듀서가 acks=1이면
# 리더 브로커만 수신한 상태에서 성공 응답이 반환되어 리더 장애 시 유실된다.
#
# min.insync.replicas=2 + 프로듀서 acks=all 조합이어야
# 최소 2개 복제본의 수신을 확인한 후 응답한다.
#   브로커 1대(AZ 1개) 장애 : 무손실로 정상 동작
#   브로커 2대 장애         : 쓰기 거부. 조용한 유실 대신 명시적 실패
#
# unclean.leader.election.enable=false 는 뒤처진 복제본이 리더가 되는 것을 막는다.
# true면 가용성은 올라가지만 데이터가 유실된다.
# ---------------------------------------------------------------------------
resource "aws_msk_configuration" "this" {
  name           = "${var.name}-config"
  kafka_versions = [var.kafka_version]

  server_properties = <<-EOT
    default.replication.factor=3
    min.insync.replicas=2
    unclean.leader.election.enable=false
    num.partitions=${var.partitions}
    log.retention.hours=${var.retention_hours}
    auto.create.topics.enable=false
    compression.type=producer
    num.replica.fetchers=4
  EOT

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_kms_key" "this" {
  description             = "${var.name} MSK 저장 데이터 암호화"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = { Name = "${var.name}-msk-key" }
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-msk"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_cloudwatch_log_group" "broker" {
  name              = "/aws/msk/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_msk_cluster" "this" {
  cluster_name  = "${var.name}-cluster"
  kafka_version = var.kafka_version

  # client_subnets 개수의 배수여야 한다. 3 AZ이므로 3, 6, 9...
  number_of_broker_nodes = var.broker_count

  broker_node_group_info {
    instance_type   = var.instance_type
    client_subnets  = var.subnet_ids
    security_groups = [var.security_group_id]

    storage_info {
      ebs_storage_info {
        volume_size = var.volume_size_gb

        provisioned_throughput {
          enabled           = true
          volume_throughput = 250
        }
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.this.arn

    encryption_in_transit {
      client_broker = "TLS" # 평문 연결 차단
      in_cluster    = true  # 브로커 간 복제도 암호화
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  # consumer lag 기반 오토스케일링을 위해 Prometheus 지표를 노출한다
  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = true
      }
      node_exporter {
        enabled_in_broker = true
      }
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.broker.name
      }
    }
  }

  tags = { Name = "${var.name}-cluster" }
}

# ---------------------------------------------------------------------------
# 브로커 스토리지 오토스케일링
#
# 컨슈머 지연으로 미소비 메시지가 쌓일 때 디스크 고갈을 방지한다.
# 브로커 수 자체의 오토스케일링은 MSK가 지원하지 않으며,
# 파티션 재분배가 필요하므로 사전 오버프로비저닝으로 대응한다.
# ---------------------------------------------------------------------------
resource "aws_appautoscaling_target" "storage" {
  service_namespace  = "kafka"
  resource_id        = aws_msk_cluster.this.arn
  scalable_dimension = "kafka:broker-storage:VolumeSize"
  min_capacity       = var.volume_size_gb
  max_capacity       = var.volume_size_gb * 4
}

resource "aws_appautoscaling_policy" "storage" {
  name               = "${var.name}-msk-storage"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.storage.service_namespace
  resource_id        = aws_appautoscaling_target.storage.resource_id
  scalable_dimension = aws_appautoscaling_target.storage.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "KafkaBrokerStorageUtilization"
    }
    target_value = 70
  }
}

resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "${var.name}-msk-disk-usage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "KafkaDataLogsDiskUsed"
  namespace           = "AWS/Kafka"
  period              = 300
  statistic           = "Maximum"
  threshold           = 80

  dimensions = {
    "Cluster Name" = aws_msk_cluster.this.cluster_name
  }
}
