# ---------------------------------------------------------------------------
# Execution Role과 Task Role 분리
#
#   Execution Role : ECS 에이전트가 사용. ECR 이미지 풀, 로그 스트림 생성
#   Task Role      : 컨테이너 내부 애플리케이션이 사용. MSK 접근, S3 쓰기
#
# 하나로 합치면 애플리케이션이 ECR 권한까지 갖게 되어 최소 권한 원칙에 어긋난다.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --------------------------- API Task Role ---------------------------
# produce 전용. consume 권한은 부여하지 않는다.
resource "aws_iam_role" "api_task" {
  name               = "${var.name}-api-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "api_task" {
  statement {
    sid       = "MskConnect"
    actions   = ["kafka-cluster:Connect"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    sid = "MskWrite"
    actions = [
      "kafka-cluster:WriteData",
      "kafka-cluster:DescribeTopic",
    ]
    resources = [var.msk_topic_arn_pattern]
  }
}

resource "aws_iam_role_policy" "api_task" {
  name   = "${var.name}-api-task-policy"
  role   = aws_iam_role.api_task.id
  policy = data.aws_iam_policy_document.api_task.json
}

# --------------------------- Consumer Task Role ---------------------------
resource "aws_iam_role" "consumer_task" {
  name               = "${var.name}-consumer-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "consumer_task" {
  statement {
    sid       = "MskConnect"
    actions   = ["kafka-cluster:Connect"]
    resources = [var.msk_cluster_arn]
  }

  statement {
    sid = "MskRead"
    actions = [
      "kafka-cluster:ReadData",
      "kafka-cluster:DescribeTopic",
    ]
    resources = [var.msk_topic_arn_pattern]
  }

  statement {
    sid = "MskConsumerGroup"
    actions = [
      "kafka-cluster:AlterGroup",
      "kafka-cluster:DescribeGroup",
    ]
    resources = [var.msk_group_arn_pattern]
  }

  # 적재 전용. 삭제 권한은 부여하지 않는다.
  statement {
    sid = "S3Write"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${var.s3_bucket_arn}/${var.s3_raw_prefix}/*"]
  }

  statement {
    sid       = "S3List"
    actions   = ["s3:ListBucket"]
    resources = [var.s3_bucket_arn]
  }

  # consumer lag을 CloudWatch 커스텀 지표로 발행 (오토스케일링 트리거)
  statement {
    sid       = "PublishLagMetric"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "consumer_task" {
  name   = "${var.name}-consumer-task-policy"
  role   = aws_iam_role.consumer_task.id
  policy = data.aws_iam_policy_document.consumer_task.json
}
