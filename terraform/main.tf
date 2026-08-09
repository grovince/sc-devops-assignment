locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ---------------------------------------------------------------------------
# 1. 네트워크
#
# VPC, 가용 영역별 서브넷, 라우트 테이블, 그리고 NAT Gateway를 대체하는
# VPC 엔드포인트를 생성한다.
#
# Interface Endpoint용 보안 그룹도 이 모듈에서 만든다. 엔드포인트는 생성
# 시점에 보안 그룹 ID가 필요하고 security 모듈은 VPC ID가 필요하기 때문에,
# 한쪽에 몰면 모듈 간 순환 참조가 발생한다. 규칙만 security 모듈에서 붙인다.
# ---------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  name_prefix = local.name_prefix
  region      = var.region
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
}

# ---------------------------------------------------------------------------
# 2. 보안
#
# 모든 보안 그룹 규칙과 WAFv2 Web ACL을 생성한다.
# ALB가 보안 그룹과 Web ACL ARN을 모두 이 모듈에서 받아가므로 ALB보다 앞선다.
#
# S3 Gateway Endpoint는 ENI가 없어 보안 그룹으로 참조할 수 없다. 대신
# 엔드포인트가 노출하는 prefix list ID를 사용한다. 별도 데이터 소스를 두면
# plan 시점에 AWS API 호출이 발생하므로, 엔드포인트 속성을 그대로 넘긴다.
# ---------------------------------------------------------------------------

module "security" {
  source = "./modules/security"

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  container_port      = var.container_port
  alb_ingress_cidrs   = var.alb_ingress_cidrs
  s3_prefix_list_id   = module.network.s3_prefix_list_id
  vpc_endpoints_sg_id = module.network.vpc_endpoints_sg_id
  rate_limit          = var.waf_rate_limit
}

# ---------------------------------------------------------------------------
# 3. 데이터 파이프라인
#
# ECS 태스크 역할이 PutRecords 권한을 스트림 ARN으로 좁히기 때문에
# 컴퓨트 계층보다 먼저 선언한다.
# ---------------------------------------------------------------------------

module "pipeline" {
  source = "./modules/pipeline"

  name_prefix         = local.name_prefix
  retention_hours     = var.kinesis_retention_hours
  buffer_size_mb      = var.firehose_buffer_size_mb
  buffer_interval_sec = var.firehose_buffer_interval_sec
  log_expiration_days = var.log_expiration_days
}

# ---------------------------------------------------------------------------
# 4. 로드 밸런서
# ---------------------------------------------------------------------------

module "alb" {
  source = "./modules/alb"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  container_port    = var.container_port
  health_check_path = var.health_check_path
  web_acl_arn       = module.security.web_acl_arn
}

# ---------------------------------------------------------------------------
# 5. 컴퓨트
# ---------------------------------------------------------------------------

module "ecs" {
  source = "./modules/ecs"

  name_prefix        = local.name_prefix
  region             = var.region
  private_subnet_ids = module.network.private_subnet_ids
  ecs_tasks_sg_id    = module.security.ecs_tasks_sg_id

  target_group_arn = module.alb.target_group_arn

  # ALBRequestCountPerTarget 지표는 두 ARN suffix를 이어붙인
  # app/<alb>/<id>/targetgroup/<tg>/<id> 형식을 요구한다.
  alb_target_group_label = "${module.alb.alb_arn_suffix}/${module.alb.target_group_arn_suffix}"

  container_image    = var.container_image
  container_port     = var.container_port
  task_cpu           = var.task_cpu
  task_memory        = var.task_memory
  desired_count      = var.desired_count
  log_retention_days = var.log_retention_days

  kinesis_stream_arn  = module.pipeline.kinesis_stream_arn
  kinesis_stream_name = module.pipeline.kinesis_stream_name

  # 리스너가 있어야 타깃 등록이 가능하고, 엔드포인트와 그 인그레스 규칙이
  # 있어야 태스크가 이미지를 pull할 수 있다.
  depends_on = [
    module.alb,
    module.security,
  ]
}
