# ---------------------------------------------------------------------------
# 로그 수집 파이프라인
#
#   ALB → ECS Fargate(API) → MSK → ECS Fargate(컨슈머) → S3
#
# 모듈 의존 방향을 한쪽으로만 흐르게 설계하여 순환 참조를 피한다.
#
#   storage ─┐
#   vpc ─────┼─→ security ─→ endpoints
#            │              ─→ msk ─────┐
#            └──────────────→ alb ──────┼─→ ecs
#
# 네트워크 계층을 자체 모듈로 작성한 이유:
# terraform-aws-modules/vpc를 쓰면 서브넷 3계층 분리와 CIDR 할당 근거가
# 모듈 내부로 숨어 코드에서 드러나지 않는다. 본 과제는 설계 의도 표현을 우선했다.
# ---------------------------------------------------------------------------

locals {
  name             = "${var.project}-${var.environment}"
  metric_namespace = "${var.project}/Kafka"
}

data "aws_caller_identity" "current" {}

module "storage" {
  source = "./modules/storage"

  name       = local.name
  account_id = data.aws_caller_identity.current.account_id
  raw_prefix = var.s3_raw_prefix
}

module "vpc" {
  source = "./modules/vpc"

  name                = local.name
  vpc_cidr            = var.vpc_cidr
  azs                 = var.azs
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  data_subnet_cidrs   = var.data_subnet_cidrs
  flow_log_bucket_arn = module.storage.bucket_arn
}

module "security" {
  source = "./modules/security"

  name               = local.name
  vpc_id             = module.vpc.vpc_id
  region             = var.region
  api_container_port = var.api_container_port
}

# NAT Gateway를 생성하지 않는다.
# 프라이빗 서브넷의 아웃바운드 요구사항(ECR 풀, CloudWatch Logs, Secrets, MSK IAM 인증)을
# 모두 VPC Endpoint로 대체하여 0.0.0.0/0 경로 자체를 제거했다.
module "endpoints" {
  source = "./modules/endpoints"

  name                    = local.name
  vpc_id                  = module.vpc.vpc_id
  region                  = var.region
  app_subnet_ids          = module.vpc.app_subnet_ids
  private_route_table_ids = module.vpc.private_route_table_ids
  security_group_id       = module.security.vpce_sg_id
  interface_services      = var.interface_endpoint_services
  account_id              = data.aws_caller_identity.current.account_id
}

module "msk" {
  source = "./modules/msk"

  name              = local.name
  kafka_version     = var.kafka_version
  subnet_ids        = module.vpc.data_subnet_ids
  security_group_id = module.security.msk_sg_id
  instance_type     = var.msk_instance_type
  broker_count      = var.msk_broker_count
  volume_size_gb    = var.msk_volume_size_gb
  partitions        = var.log_topic_partitions
  retention_hours   = var.log_retention_hours
}

module "alb" {
  source = "./modules/alb"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  security_group_id = module.security.alb_sg_id
  container_port    = var.api_container_port
  certificate_arn   = var.certificate_arn
  waf_rate_limit    = var.waf_rate_limit
}

module "ecs" {
  source = "./modules/ecs"

  name             = local.name
  region           = var.region
  metric_namespace = local.metric_namespace

  app_subnet_ids             = module.vpc.app_subnet_ids
  api_security_group_id      = module.security.api_sg_id
  consumer_security_group_id = module.security.consumer_sg_id

  target_group_arn        = module.alb.target_group_arn
  alb_arn_suffix          = module.alb.arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  https_listener_arn      = module.alb.https_listener_arn

  msk_cluster_arn       = module.msk.cluster_arn
  msk_topic_arn_pattern = module.msk.topic_arn_pattern
  msk_group_arn_pattern = module.msk.group_arn_pattern
  bootstrap_brokers     = module.msk.bootstrap_brokers_sasl_iam
  msk_partitions        = module.msk.partitions
  kafka_topic           = var.kafka_topic
  consumer_group_id     = var.consumer_group_id

  s3_bucket_id  = module.storage.bucket_id
  s3_bucket_arn = module.storage.bucket_arn
  s3_raw_prefix = module.storage.raw_prefix

  api_image                = var.api_image
  consumer_image           = var.consumer_image
  api_container_port       = var.api_container_port
  cpu_architecture         = var.cpu_architecture
  api_min_capacity         = var.api_min_capacity
  api_max_capacity         = var.api_max_capacity
  api_target_request_count = var.api_target_request_count
  consumer_min_capacity    = var.consumer_min_capacity
  scheduled_scaling        = var.scheduled_scaling

  # ALB 리스너와 MSK 클러스터가 완전히 생성된 후 서비스를 기동한다
  depends_on = [module.alb, module.msk, module.endpoints]
}
