terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# 버킷 이름을 전역에서 고유하게 만들기 위해 계정 ID를 접미사로 붙인다.
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# S3 로그 버킷
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  bucket = "${var.name_prefix}-logs-${data.aws_caller_identity.current.account_id}"

  # 실수로 로그가 통째로 삭제되는 것을 막는다.
  force_destroy = false

  tags = {
    Name = "${var.name_prefix}-logs"
  }
}

# 퍼블릭 접근을 모든 경로에서 차단한다.
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACL을 비활성화하고 소유권을 버킷 소유자로 고정한다.
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 서버 측 암호화(AES256). bucket_key를 켜면 KMS 요청 비용을 줄일 수 있다.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 게임 로그는 한 번 적재되고 이후에는 드물게 조회된다.
# 계층 전환으로 데이터가 늘어도 스토리지 비용이 급격히 오르지 않게 하고,
# 실패한 멀티파트 업로드가 쌓이지 않도록 정리 규칙을 둔다.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  depends_on = [aws_s3_bucket_versioning.logs]

  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    # log_expiration_days가 0이면 만료 규칙 자체를 생성하지 않는다.
    dynamic "expiration" {
      for_each = var.log_expiration_days > 0 ? [1] : []
      content {
        days = var.log_expiration_days
      }
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Kinesis Data Streams
#
# On-Demand 모드를 사용해 샤드 수를 직접 산정하지 않는다.
# AWS가 직전 30일 최대 쓰기 처리량의 2배까지 용량을 자동 조정한다.
# ---------------------------------------------------------------------------

resource "aws_kinesis_stream" "logs" {
  name             = "${var.name_prefix}-stream"
  retention_period = var.retention_hours

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  encryption_type = "KMS"
  kms_key_id      = "alias/aws/kinesis"

  # 처리량 초과를 조기에 감지하기 위한 샤드 단위 지표.
  shard_level_metrics = [
    "IncomingBytes",
    "IncomingRecords",
    "WriteProvisionedThroughputExceeded",
  ]

  tags = {
    Name = "${var.name_prefix}-stream"
  }
}

# ---------------------------------------------------------------------------
# Firehose IAM 역할
#
# 스트림에서 읽고 S3에 쓴다. 스트림이 AWS 관리형 Kinesis 키로 암호화되어
# 있으므로 복호화 권한도 함께 필요하다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    # 혼동된 대리인(confused deputy) 문제를 막기 위한 계정 한정 조건.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "firehose" {
  name               = "${var.name_prefix}-firehose-role"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid    = "ReadKinesisStream"
    effect = "Allow"
    actions = [
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.logs.arn]
  }

  statement {
    sid    = "DecryptStream"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["kinesis.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "WriteLogBucket"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]
  }

  statement {
    sid       = "WriteDeliveryLogs"
    effect    = "Allow"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role_policy" "firehose" {
  name   = "${var.name_prefix}-firehose-policy"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

# ---------------------------------------------------------------------------
# Firehose 전송 스트림
# ---------------------------------------------------------------------------

# 전송 실패 원인을 추적하기 위한 로그 그룹.
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/${var.name_prefix}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_stream" "firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  name        = "${var.name_prefix}-firehose"
  destination = "extended_s3"

  # KDS를 소스로 지정한다. Firehose가 스스로 스트림을 읽어가므로
  # 애플리케이션은 Firehose API를 직접 호출하지 않는다.
  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.logs.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose.arn
    bucket_arn = aws_s3_bucket.logs.arn

    # 크기와 시간 중 먼저 도달하는 조건에서 S3로 flush한다.
    # 값을 키우면 객체가 커져 Athena 스캔 효율이 좋아지고,
    # 줄이면 데이터 신선도가 올라간다.
    buffering_size     = var.buffer_size_mb
    buffering_interval = var.buffer_interval_sec

    compression_format = "GZIP"

    # Hive 스타일 시간 파티셔닝. Athena가 전체 버킷을 스캔하지 않고
    # 시간 범위로 프루닝할 수 있게 한다.
    #
    # timestamp 네임스페이스는 Firehose가 자체적으로 평가하므로
    # 동적 파티셔닝(dynamic partitioning) 설정이 필요하지 않다.
    # 동적 파티셔닝은 64~128MiB 버퍼를 요구해 위 설정과 충돌한다.
    prefix              = "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose_s3.name
    }
  }

  tags = {
    Name = "${var.name_prefix}-firehose"
  }

  # 역할에 정책이 붙기 전에 스트림이 생성되면 첫 전송이 실패한다.
  depends_on = [aws_iam_role_policy.firehose]
}
