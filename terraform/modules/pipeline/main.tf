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

# 서버 측 암호화(SSE-S3, AES256)를 적용한다.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 적재 후 조회 빈도가 급격히 떨어지는 데이터 특성에 맞춰 계층을 전환한다.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

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

    expiration {
      days = var.log_expiration_days
    }
  }
}

# ---------------------------------------------------------------------------
# Kinesis Data Streams
#
# On-Demand 모드를 사용해 샤드 수를 직접 산정하지 않는다.
# 게임 로그는 시간대별 트래픽 편차가 커서 고정 샤드로는
# 피크에 스로틀링이 발생하거나 평시에 용량이 낭비된다.
# ---------------------------------------------------------------------------

resource "aws_kinesis_stream" "logs" {
  name             = "${var.name_prefix}-stream"
  retention_period = var.retention_hours

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  tags = {
    Name = "${var.name_prefix}-stream"
  }
}

# ---------------------------------------------------------------------------
# Firehose IAM 역할
#
# 스트림에서 읽어 S3에 쓰고, 전송 로그를 CloudWatch에 남긴다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
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
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.logs.arn]
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
    buffering_size     = var.buffer_size_mb
    buffering_interval = var.buffer_interval_sec

    compression_format = "GZIP"

    # 시간 단위 파티셔닝. 조회 시 전체 버킷을 스캔하지 않아도 된다.
    prefix              = "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    # S3 전송에 실패한 레코드를 별도 경로에 남겨 유실을 방지한다.
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
